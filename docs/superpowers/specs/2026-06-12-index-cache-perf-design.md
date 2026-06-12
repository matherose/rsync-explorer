# Index Performance: Scan-Once Cache, Range Filter, Parallel Cold Scan

**Date:** 2026-06-12
**Status:** Approved (design)

## 1. Problem

At the user's scale (50+ snapshots, 500k+ files each) the in-memory index is
too expensive to build the way it is built today:

- `rsyncx_build_index` (engine/index.c) scans snapshots **sequentially** — one
  SSH session + one full `find` walk per snapshot, back to back.
- The app rebuilds the index from scratch on **every timeline range change**
  and on **every launch**, even though nothing on the NAS changed.
- A full rebuild is therefore 50+ SSH handshakes and 25M+ remote `lstat`
  calls, repeated constantly.

`fd` was considered as a faster `find`: rejected. Its `--format` emits only
path variants, not the 8 metadata fields the index needs (inode, mode, user,
group, size, mtime, nlink, type), so it would require a second stat pass that
cancels its traversal speedup. GNU `find -printf` stays.

## 2. Goal

- Each snapshot directory is scanned over SSH **at most once in its
  lifetime** (rsync `--link-dest` snapshots are immutable once written).
- Timeline range changes are **instant** (no SSH, no index rebuild).
- The one unavoidable full scan (first launch, empty cache) is parallelized.

Target steady state: launch = N−1 local cache loads + 1 SSH scan of the
newest snapshot; timeline drag = an in-memory pass, milliseconds.

## 3. Decisions (settled during brainstorming)

- **Approach:** C — persistent per-snapshot cache + index-all-with-range-filter
  + parallel cold scan (combined; chosen over cache-only and
  faster-traversal-only).
- **Cache medium:** local disk, `~/Library/Caches/rsync-explorer/`; a few
  hundred MB is acceptable.
- **Remote side:** Linux box where tools could be installed, but no remote
  tooling is required by this design.

## 4. Non-Goals

- Replacing `find` on the remote (fd, custom scanner binaries).
- Caching for local sources (fts scans are already disk-speed; cache applies
  to remote sources only).
- New UI beyond the existing indexing progress display.
- Watching the NAS for new snapshots (discovery still happens at launch /
  source switch).

## 5. Architecture

```
engine/cache.c        per-snapshot scan cache: write/read/housekeep (zlib)
engine/index.c        build = cache-or-scan per snapshot, parallel workers,
                      ordered merge; new rsyncx_index_set_range()
app/EngineBridge.swift  wrapper for set_range
app/MainWindowController.swift  timeline handlers call setRange, not rebuild
```

### 5.1 Per-snapshot scan cache (`engine/cache.c`)

- **Path:** `~/Library/Caches/rsync-explorer/<source-id>/<snapshot-name>.scan`
  - `<source-id>`: sanitized `host_basepath` (non-alphanumerics → `_`);
    local sources do not use the cache.
  - `<snapshot-name>`: the snapshot directory's basename.
- **Format:** zlib-compressed (`dependency('zlib')` in Meson) stream of:
  - header: magic `RXSC` (4 bytes), format version (u32), entry count (u64);
  - one record per entry: fixed numeric fields of `file_entry_t`
    (inode u64, size u64, mtime i64, mode u32, nlink u32, is_dir u8) +
    length-prefixed strings (user, group, rel_path).
- **API:**
  - `cache_write(source, snap, const file_entry_array_t *)` — atomic:
    write to `<file>.tmp`, `rename()` into place. Failure is non-fatal
    (caller proceeds; snapshot rescans next launch).
  - `cache_read(source, snap, file_entry_array_t *out)` — returns miss on
    any defect (absent, bad magic, version mismatch, truncation, zlib error,
    record that fails the same validation as `parse_index_find_line`,
    including `rel_path_safe`). A miss is silent; caller falls back to SSH.
  - `cache_housekeep(source, snaps, count)` — deletes `.scan`/`.tmp` files in
    the source dir not matching a current snapshot name.
- **Lifecycle rules:**
  - A snapshot is cacheable **iff it is not the newest** in the discovered
    list (the newest may have been mid-backup; it is always rescanned and is
    written to cache only once a newer snapshot exists above it).
  - Cache entries never expire otherwise (snapshot immutability).

### 5.2 Index over all snapshots + range filter (`engine/index.c`)

- `rsyncx_build_index` drops its `from_idx`/`to_idx` build semantics and
  always indexes the full discovered snapshot list. If the list exceeds the
  128-snapshot presence-bitmap cap, the **newest 128** are indexed
  (documented limit; presence bitmap stays `present_lo/present_hi`).
- New API: `rsyncx_index_set_range(rsyncx_index_t *ix, int from, int to)` —
  re-runs only the finalize pass: for each node, `klass`, `deleted_in`,
  `first_backup`/`last_backup` are recomputed from the presence bitmap
  restricted to `[from, to]`. Nodes with no presence in the range are marked
  absent; `rsyncx_index_children` / `_dirs` / `_search` skip absent nodes.
- `rsyncx_build_index` ends with `set_range(0, count-1)` so the index is
  immediately queryable.

### 5.3 Parallel cold scan (`engine/index.c`)

- Worker pool of `min(6, snapshots_to_scan)` pthreads. Workers pull snapshot
  indices from a shared atomic counter; each does cache-read, falling back to
  `scan_tree_remote` (then `cache_write` if cacheable), into a private
  `file_entry_array_t`.
- **Merge is strictly sequential and in snapshot order** on the coordinating
  thread: `merge_snapshot(ix, i, ...)` semantics (`first_idx`, `first_inode`,
  `modified`) require oldest→newest processing. Workers deposit finished
  arrays into per-snapshot completion slots; the merger consumes slot `i`
  only when ready, freeing each array after merge (bounded transient memory:
  up to ~6 in-flight arrays).
- On any scan failure: an error flag stops workers from starting new
  snapshots; the build returns NULL as today.
- Progress callback reports completed-snapshot count and cumulative files;
  existing UI is unchanged.
- Local sources use the same machinery with `scan_tree_local` and no cache
  (worker count still applies).

### 5.4 App changes

- `MainWindowController.timelineRangeChanged` and `toggleTimeline` call a new
  `EngineBridge.setRange(index, from, to)` on the engine queue, then reload
  the file list / sidebar — no `rebuildIndex()`. Full rebuild remains only in
  the `discoverSnapshots` completion (launch and source switch).
- `rebuildIndex()` keeps the existing generation-token protocol; `setRange`
  reuses it (a stale generation aborts before reload).
- `cache_housekeep` is invoked by the engine at the end of a successful
  build.

## 6. Error Handling

- **Cache read defects** → treated as miss, transparent SSH rescan, cache
  rewritten. Never fatal, never user-visible.
- **Cache write failure** (disk full, permissions) → ignored; index continues
  in memory.
- **SSH scan failure** → whole build fails (current semantics), workers
  cancel, existing error surface in the app.
- **Snapshot list > 128** → newest 128 indexed; older snapshots invisible to
  the index (and to the timeline filter).
- **Concurrency:** `set_range` mutates per-node classification fields; all
  index calls (build, set_range, queries) stay serialized on the app's single
  engine dispatch queue — no engine-side locking added.

## 7. Testing / Acceptance

Unit tests (extend `engine/test_index.c`, local synthetic snapshot trees,
run via `meson test`):

1. **Cache round-trip:** scan → `cache_write` → `cache_read` → entry array
   compares equal field-by-field.
2. **Cache robustness:** truncated file, bad magic, wrong version, unsafe
   rel_path inside a record → `cache_read` misses; build still succeeds.
3. **Range equivalence:** index 3 synthetic snapshots; for every sub-range
   `[a,b]`, `set_range(a,b)` classifications equal a from-scratch build over
   only those snapshots.
4. **Parallel determinism:** parallel build result identical to serial
   (force worker count 1 vs 6 over the same trees).
5. **Housekeeping:** stale `.scan` files for removed snapshots are deleted;
   live ones survive.

Acceptance (manual, user):
- First launch with empty cache: noticeably faster than today (parallel),
  populates the cache.
- Second launch: index ready in seconds (only newest snapshot scanned).
- Timeline drag: file list updates instantly, no "Indexing…" phase, no SSH
  traffic.

## 8. Affected Files

- **New:** `engine/cache.c` (+ declarations in `engine/engine.h`),
  cache tests in `engine/test_index.c`.
- **Modified:** `engine/index.c` (parallel build, cache integration,
  `set_range`), `engine/engine.h`, `engine/meson.build` (add cache.c, zlib),
  `app/EngineBridge.swift`, `app/MainWindowController.swift`.
