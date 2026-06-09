# In-Memory Backup Index for Instant Navigation

**Date:** 2026-06-09
**Status:** Approved (design)

## 1. Problem

The browsed source is a remote NAS over SSH. Every folder change runs **two**
sets of per-snapshot remote `find` commands — `rsyncx_scan_dir` (file list) and
`rsyncx_expand_tree` (sidebar) — each spawning one `find -maxdepth 1` per
snapshot in range. A single navigation therefore costs `2 × N_snapshots` remote
command executions; at this backup's scale (>500k files, >40 snapshots) that is
several seconds per click. Search has the same cost (recursive remote find per
snapshot on every query).

## 2. Goal

Pay a **one-time** cost to read the whole backup, then serve all navigation,
the sidebar, and search from an in-memory structure so every interaction after
the initial build is instant.

## 3. Decisions (settled during brainstorming)

- **Where:** the index lives in the **C engine** (compact storage), with Swift
  querying it per directory. Swift never holds the whole tree.
- **Lifetime:** **in-memory only**, rebuilt per session / on source switch. No
  on-disk persistence in this iteration (possible future follow-up).
- **Timeline range:** the index is built over the full snapshot range. Changing
  the timeline range rebuilds the index (rare — the timeline is hidden by default).
- **Initial-load UX:** a blocking progress indicator ("Indexing backup… N files")
  while building; navigation is enabled once the index is ready.
- **Bonus:** search becomes an in-memory filter (instant), replacing remote find.

## 4. Non-Goals

- On-disk / persistent cache (future).
- Incremental refresh while the app is open (new snapshots appearing mid-session).
- Removing the existing live `rsyncx_scan_dir` / `rsyncx_expand_tree` /
  `rsyncx_search` functions — the UI stops calling them, but they remain in the
  engine (cleanup is a possible follow-up).

## 5. Architecture

```
Source selected / range changed
        │
        ▼
rsyncx_build_index()  ── one recursive find per snapshot (parallel SSH / fts) ──▶ raw entries
        │                                                                         │
        │   memory-efficient merge across snapshots (present bitmap + incremental │
        │   modification tracking), classify every path, build compact node array │
        ▼                                                                         ▼
   rsyncx_index_t  (opaque handle, ~80 B/path + string pool)
        │
        ├── rsyncx_index_children(path)  → file list   (lifecycle_t[], leaf rel_path)
        ├── rsyncx_index_dirs(path)      → sidebar      (dir_entry_t[])
        └── rsyncx_index_search(query)   → search       (lifecycle_t[], full rel_path)
```

### 5.1 New engine module: `engine/index.c` (+ public API in `engine/engine.h`)

**Opaque handle** `rsyncx_index_t` holds:
- `char *path_pool` — all unique rel-paths concatenated (NUL-separated). ~30 MB
  at 500k paths.
- `node_t *nodes` — one record per unique path (see below).
- A hash map `path → node index` (build-time merge + query lookup).
- Per-node child lists (built after merge) and a root child list.
- A copy of the `snapshot_t[]` range (to reconstruct absolute paths on demand).
- Small interned pools for `user`/`group` names (most files share a few owners),
  referenced by `uint16_t` ids.

**`node_t` (compact, ~80 bytes):**
```
uint32_t path_off;       // offset into path_pool (full rel_path)
uint16_t name_len;       // leaf name length (leaf = path_pool[path_off + ...])
int32_t  parent;         // parent node index, or -1 for root-level
uint32_t mode;
uint64_t size;
int64_t  mtime;
uint32_t nlink;
uint16_t user_id, group_id;   // into interned owner pools
uint8_t  is_dir;
uint8_t  klass;          // file_class_t
uint8_t  last_idx;       // snapshot index that last has it (≤128) → last_real_path
int64_t  first_backup, last_backup, deleted_in;
// children stored in a separate parent→children index structure
```
Estimated footprint: ~80 B/node + ~60 B/path pool ≈ 70 MB at 500k paths,
~140 MB at 1M. Bounded and Mac-friendly.

**Build (`rsyncx_build_index`):**
1. For each snapshot in `[from,to]`, run **one recursive** scan (no `-maxdepth`),
   **including directories**, returning `(inode, mode, user, group, size, mtime,
   nlink, rel_path)` per entry. Remote: parallel SSH find via the existing
   `ssh_build_find_argv` (maxdepth −1) + `ssh_spawn_capture`. Local: `fts` walk
   (reuse the `search_local` traversal with no name filter, but **not** skipping
   directories).
2. Stream-merge into the hash map keyed by `rel_path`. Per path, keep a
   **present bitmap** (1 bit/snapshot) + `first_idx`/`last_idx` + latest metadata
   + an incremental **modified** flag (set when the inode differs between
   snapshots where the path is present). This avoids the `inode[MAX_SNAPSHOTS]`
   array `classify_entries` uses, which would not scale to the whole tree.
3. Classify each path from `(present bitmap, modified flag)` →
   unchanged / modified / new / deleted / del→new; compute `first_backup`,
   `last_backup`, `deleted_in` from the snapshot dates.
4. Build `parent` links (look up each path's dirname in the hash map) and
   per-parent child lists; collect root-level nodes.
5. Invoke an optional `progress_cb(done_snapshots, total, files_so_far, ctx)`
   during step 1 so the UI can show progress.

**Public API (`engine.h`):**
```c
typedef struct rsyncx_index rsyncx_index_t;

rsyncx_index_t *rsyncx_build_index(const source_t *src,
                                   const snapshot_t *snaps, int snap_count,
                                   int from_idx, int to_idx,
                                   void (*progress_cb)(int done, int total,
                                                       long files, void *ctx),
                                   void *ctx);

/* Children (files + dirs) of a directory; rel_path "" = root.
   Output lifecycle_t[] use the LEAF name in rel_path (matching the current
   per-dir scan contract). Caller frees via rsyncx_free. */
int rsyncx_index_children(const rsyncx_index_t *idx, const char *rel_path,
                          lifecycle_t **out, int *count);

/* Child directories only (for the sidebar). Caller frees via rsyncx_free. */
int rsyncx_index_dirs(const rsyncx_index_t *idx, const char *rel_path,
                      dir_entry_t **out, int *count);

/* Substring filename search across the whole tree, files only.
   Output lifecycle_t[] use the FULL rel_path (so results show location). */
int rsyncx_index_search(const rsyncx_index_t *idx, const char *query,
                        lifecycle_t **out, int *count);

void rsyncx_index_free(rsyncx_index_t *idx);
```
`rsyncx_index_children`/`_search` materialize `lifecycle_t` rows on demand from
the compact nodes (reconstructing `last_real_path` from `snaps[last_idx]`), so
the Swift side consumes exactly the same shape it does today.

### 5.2 Swift integration

**`EngineBridge`** gains:
- `buildIndex(source:snapshots:fromIdx:toIdx:progress:) -> OpaquePointer?`
  (wraps `rsyncx_build_index`; bridges the C progress callback to a Swift
  `(Int, Int, Int) -> Void` via an `Unmanaged` context box).
- `indexChildren(_ idx:relPath:) -> [FileEntry]`
- `indexDirs(_ idx:relPath:) -> [DirEntry]`
- `indexSearch(_ idx:query:) -> [FileEntry]`
- `freeIndex(_ idx:)`

**`MainWindowController`** holds `private var index: OpaquePointer?`.
- After `discoverSnapshots` (source select) or a timeline range change: free any
  existing index, then on a background queue call `buildIndex` with a progress
  closure that updates the status bar ("Indexing… N files") on the main thread.
  While building, show the spinner and ignore navigation input; on completion,
  load the root directory from the index.
- `scanCurrentDir()` → `EngineBridge.indexChildren(index, relPath: currentPath)`.
- `expandCurrentTree()` → `EngineBridge.indexDirs(index, relPath: currentPath)`.
- `searchSubmitted()` → `EngineBridge.indexSearch(index, query:)` (no range
  args; the index already reflects the active range). The existing
  generation-token cancellation still applies but searches are now instant.
- Free the index in `windowWillClose` / on rebuild.

Navigation semantics are unchanged: `rsyncx_index_children` returns leaf
`rel_path`, so the existing append-on-navigate and `displayName` logic keep
working without UI changes beyond swapping the data source.

## 6. Error Handling

- **Build failure** (e.g. SSH unreachable): `rsyncx_build_index` returns NULL →
  Swift shows an alert ("Couldn't index <source>") and leaves the list empty;
  the user can re-pick the source to retry.
- **Partial snapshot failure** during build: best-effort, matching current
  behavior — a snapshot whose scan fails contributes nothing; the index is built
  from the snapshots that succeeded.
- **Empty query** search: returns no rows (unchanged from today).
- **Allocation failure** at this scale: build returns NULL; handled as above.

## 7. Testing

- **Engine (`engine/test_index.c`, local fixture, no SSH):** extend the
  hard-linked fixture to a small nested tree across 2-3 snapshots (a subdir, an
  unchanged file, a new file, a deleted file, a modified file). Assert:
  - `rsyncx_index_children("")` returns the root entries with correct classes.
  - `rsyncx_index_children("<subdir>")` returns that subdir's entries.
  - `rsyncx_index_dirs("")` returns only the directories.
  - `rsyncx_index_search("<name>")` finds the file with its full path.
  - classifications match the lifecycle rules (unchanged/new/deleted/modified).
  Wire `test_index` into the Makefile `test` target.
- **Swift:** manual — the progress indicator appears on source select, then
  folder navigation, the sidebar, and search are instant; navigation depth and
  Back still behave correctly.

## 8. Affected Files

**Engine:**
- `engine/index.c` — new module (build + merge + classify + queries).
- `engine/engine.h` — public index API + `rsyncx_index_t`.
- `engine/engine_internal.h` — shared helpers if needed (recursive scan helper).
- `engine/Makefile` — add `index.c` to `SRCS`; add `test_index` target.
- `engine/test_index.c` — new tests.

**App:**
- `app/EngineBridge.swift` — index wrappers + progress-callback bridging.
- `app/MainWindowController.swift` — build index on source-select/range-change
  with progress; route scan/expand/search through the index; free on rebuild/close.

## 9. Risks

- **Build-time data volume:** with `--link-dest`, a recursive find per snapshot
  re-lists every unchanged file in every snapshot (≈ `files × snapshots` lines).
  Mitigation: stream-parse (never hold all raw text), keep only the compact
  merge record per unique path, and run the per-snapshot finds in parallel.
- **Memory at the top end (≈1M paths):** ~140 MB. Acceptable on a Mac; the
  compact `node_t` + pooled strings keep it bounded. If it ever needs trimming,
  owner interning and `last_idx` (instead of storing `last_real_path`) already
  remove the largest costs.
- **Progress-callback bridging** across the C/Swift boundary must use a retained
  context box and hop to the main thread for UI updates (standard pattern).
- **`rsyncx_index_t` lifetime:** Swift must free the old index before replacing
  it and on window close to avoid leaking tens-to-hundreds of MB.
