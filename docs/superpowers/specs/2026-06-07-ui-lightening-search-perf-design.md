# rsync-explorer — UI Lightening + Search Performance

**Date:** 2026-06-07
**Status:** Approved (design)

## 1. Problem Statement

Two user-reported problems with the current rsync-explorer:

1. **The UI is too heavy and not obvious to navigate.** The window shows a two-row
   chrome, an always-visible timeline range selector, an 8-column table
   (CLASS / PERM / USR / GRP / SIZE / MODIFIED / FIRST / LAST / Name), and loud
   full-row coloring on every row. The goal is a lighter, Finder-like interface.

2. **Search is very slow.** Investigation revealed two distinct issues:
   - **Correctness bug:** local search calls `find … -printf …` (a GNU extension)
     via `popen`. macOS BSD `find` rejects `-printf`
     (`find: -printf: unknown primary or operator`) and no `gfind` is installed,
     so **local search currently returns zero results**.
   - **Performance:** remote search forks one child *per snapshot*, each opening
     its **own SSH connection** (no multiplexing). With N snapshots that is N SSH
     handshakes plus N full recursive remote `find` walks. The handshake overhead
     dominates. Local search (once fixed) walks snapshots sequentially.

## 2. Goals

- Lighter, Finder-style layout that is obvious to navigate.
- Light/dark theme support that follows the system appearance with a manual override.
- Fix the macOS local-search correctness bug.
- Make search substantially faster for both local and remote sources.
- Keep changes contained and low-risk; no persistent on-disk index in this iteration.

## 3. Non-Goals (Future Work)

- **Persistent path index** (Approach B): a background-built index mapping
  `rel_path → snapshots present + metadata` for near-instant repeated searches.
  Deferred to a later iteration.
- **Engine-side hard cancellation** of in-flight `find`/ssh processes. This
  iteration discards stale results client-side instead.

---

## Part 1 — UI: Finder-style, Lighter

### 1.1 Table columns

**Files:** `app/FileListViewController.swift`, `app/ColumnConfig.swift`

Reduce the default column set to four, in this order:

| Column | Notes |
|---|---|
| **Name** | Icon + small leading status dot (see 1.2) + filename |
| **Size** | Right-aligned, human-readable (e.g. `4.2 KB`), `—` for directories |
| **Date Modified** | File mtime |
| **Last Backup** | Date the file last appeared in a snapshot |

Removed columns: **CLASS, PERM, USR, GRP, FIRST**. The underlying data
(classification, permissions, user/group, first-backup) remains available in the
engine structs; it is simply not shown by default. `ColumnConfig` defaults are
updated accordingly; users may still re-add hidden columns via the columns menu
if that mechanism is retained.

### 1.2 Lifecycle marks (replace full-row coloring)

**Files:** `app/LifecycleRow.swift`, `app/FileListViewController.swift`

Remove full-row background coloring. Replace with subtle indicators in the Name column:

| Lifecycle | Indicator |
|---|---|
| **new** | green dot (8×8, perfectly round) before the name |
| **modified** | amber dot before the name |
| **deleted** | filename text drawn in **red**, no dot |
| **unchanged** | no indicator |

Dot colors should have light/dark variants (e.g. deleted red `#e53935` light /
`#ff6b6b` dark). The dot is a fixed-size circle that never inherits cell padding
(the prototype bug that made it an oval).

The status bar keeps a quiet lifecycle summary (e.g. "1 new · 1 modified · 1 deleted").

### 1.3 Single toolbar

**File:** `app/MainWindowController.swift` (`buildUI`)

Collapse the current two-row chrome into a single toolbar:

- **Left:** back / forward, then a breadcrumb of the current path.
- **Right:** theme toggle (1.5), timeline toggle (1.4), columns menu, search
  field, source selector.

### 1.4 Timeline hidden by default

**Files:** `app/TimelineView.swift`, `app/MainWindowController.swift`

- The `TimelineView` is **hidden by default**.
- Toggle via a toolbar button **and** a `View ▸ Show Timeline` menu item bound to **⌘T**.
- Visibility state persists in `UserDefaults`.
- When the timeline is hidden, search covers **all snapshots** (see Part 2).

### 1.5 Light / dark theme

**Files:** `app/MainWindowController.swift`, `app/AppDelegate.swift`, view controllers using colors

- A round **sun/moon pill toggle** in the toolbar (slider knob moves between a
  sun icon and a crescent-moon icon; maps to SF Symbols `sun.max` / `moon.fill`).
- Default behavior **follows the macOS system appearance** via `NSAppearance` /
  `NSApp.appearance`.
- Manual override (force light / force dark) persisted in `UserDefaults`.
- Replace hardcoded gray text/background values with appearance-aware semantic
  `NSColor`s (e.g. `labelColor`, `secondaryLabelColor`,
  `controlBackgroundColor`) so both modes read well. Lifecycle dot/red colors get
  explicit light/dark values.

---

## Part 2 — Search Performance (Approach A)

### 2.1 Local search: portable + parallel

**File:** `engine/search.c` (`search_local`, `rsyncx_search`)

- Replace the `popen("find … -printf …")` implementation with **in-process
  `fts` traversal** (`fts_open`/`fts_read`/`fts_close`), reading each entry's
  metadata via the `FTSENT`/`lstat` data. This is portable (macOS + Linux),
  requires no shell, and **fixes the macOS `-printf` bug**.
- Run the per-snapshot walks **in parallel** using a **pthread pool**, mirroring
  the structure already used for the parallel remote path. Each worker fills its
  own `file_entry_array_t`; results are merged and classified exactly as today
  via `classify_entries`.

### 2.2 Remote search: SSH connection multiplexing

**File:** `engine/ssh.c` (`ssh_build_find_cmd`, and the other ssh command builders)

- Add SSH **connection multiplexing** options to ssh invocations:
  `-o ControlMaster=auto -o ControlPersist=<short timeout> -o ControlPath=<socket path>`.
- A single master connection is established (once per search), and the N parallel
  per-snapshot `find` children reuse it — **one handshake instead of N**.
- The `ControlPath` socket lives in a temp location unique to the source/run and
  is cleaned up after the search. Keep `BatchMode=yes` and existing options.
- The per-snapshot fork+parallel structure in `rsyncx_search` is retained; only
  the connection cost changes.

### 2.3 Default search range

**File:** `app/MainWindowController.swift`

- When the timeline is hidden (the new default), a search covers **all
  snapshots**: `fromIdx = 0`, `toIdx = count - 1`.
- When the timeline is shown, its handles continue to define `fromIdx`/`toIdx` as today.

### 2.4 Cancellation (discard stale results)

**Files:** `app/MainWindowController.swift`, `app/EngineBridge.swift`

- Maintain a monotonic **search generation token**. Each `searchSubmitted`
  increments it and captures the value.
- When a background search completes, it only applies its results to the UI if
  its captured token still matches the current one; otherwise the results are
  discarded. This prevents stale/slow searches from overwriting newer ones.
- Engine-side hard-abort of running `find`/ssh processes is **out of scope** for
  this iteration (listed in Non-Goals).

---

## 4. Affected Files Summary

**Engine (C):**
- `engine/search.c` — fts-based local search; pthread parallelism.
- `engine/ssh.c` — ControlMaster multiplexing options.
- `engine/engine_internal.h` / `Makefile` — pthread linkage if needed.

**App (Swift):**
- `app/MainWindowController.swift` — single toolbar, timeline toggle (⌘T),
  theme toggle, default search range, cancellation token.
- `app/FileListViewController.swift` — column set, status-dot rendering.
- `app/ColumnConfig.swift` — new default columns.
- `app/LifecycleRow.swift` — remove row coloring; dots + red deleted name.
- `app/TimelineView.swift` — hidden by default.
- `app/AppDelegate.swift` — appearance handling / View menu items.
- `app/EngineBridge.swift` — search generation glue if needed.

## 5. Testing

- **Engine:** unit/integration test of `rsyncx_search` against a synthetic
  `--link-dest`-style fixture (multiple snapshots, a deleted file, a new file, a
  modified file) — verify local search now returns correct classified results on
  macOS, and that parallel results match a sequential reference.
- **Remote:** verify multiplexed search returns the same results as the
  pre-change per-connection path (where a test host is available); confirm a
  single master socket is created and removed.
- **UI:** manual verification — columns correct, dots/red-name correct in both
  light and dark mode, timeline hidden by default and toggles with ⌘T, theme
  toggle follows system and honors manual override, search covers all snapshots
  by default, rapid re-search does not show stale results.

## 6. Risks

- `fts` metadata vs the previous `find -printf` fields must map exactly to
  `file_entry_t` (inode, mode, uid/gid names, size, mtime, nlink, rel_path).
  User/group **names** require `getpwuid`/`getgrgid` resolution (cached).
- ControlMaster socket path length limits (`ControlPath` must stay within
  `sun_path` limits) — use a short temp path.
- Parallel local walks on a slow spinning disk could contend; acceptable given
  the target is local SSD / the primary slowness is remote.
