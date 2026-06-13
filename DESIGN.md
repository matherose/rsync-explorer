# rsync-explorer — Design Document

> A macOS-native GUI file explorer for rsync incremental backups using `--link-dest`.
> Browses the full lifecycle of every file across all snapshots — current, modified, deleted, and re-created.

---

## 1. Problem Statement

rsync with `--link-dest` creates space-efficient incremental backups using hard links. Unchanged files share the same inode across snapshot directories. This structure is self-describing — but no existing tool lets you browse it as a unified view:

- **Finder** shows one snapshot at a time, with no awareness of the backup timeline
- **Back In Time** (Linux/Qt) is the closest tool but lacks snapshot comparison and deleted-file tracking (open feature request: issue #1101)
- **Command-line tools** (`find`, `stat`, `ls -i`) can inspect inodes but offer no unified view

rsync-explorer fills this gap: a macOS-native file explorer that overlays all snapshots, classifies every file's lifecycle, and presents the result in a familiar Finder-like interface.

---

## 2. Design Principles

| Principle | Implication |
|---|---|
| **Lazy indexing** | No cache, no database, no background daemon. Scan on navigation, classify in memory, discard on exit. |
| **Path-first (Model B)** | The user browses a path. Every file that *ever existed* at that path across all snapshots is visible. |
| **No external dependencies** | Engine uses only POSIX/BSD syscalls and standard tools (`ssh`, `find`). UI uses system frameworks (AppKit, Quartz). |
| **macOS-first** | Use `getattrlistbulk` for fast local scanning. Linux support is a future port using POSIX fallbacks. |
| **YAGNI** | No backup creation, no restore, no scheduling, no encryption. This is an *explorer*, not a backup manager. |

---

## 3. Architecture

```
┌──────────────────────────────────────┐
│         Swift / AppKit UI            │
│                                      │
│  NSOutlineView   (sidebar tree)      │
│  NSTableView     (file list)         │
│  NSSplitView     (layout)            │
│  QLPreviewPanel  (Spacebar preview)  │
│  TimelineView    (range selector)    │
│  NSSearchField   (global search)     │
│                                      │
│  talks to C engine via bridging hdr  │
├──────────────────────────────────────┤
│         C Engine  (libengine.a)      │
│                                      │
│  source_t        (parsed config)     │
│  snapshot_t      (discovered timeln) │
│  lifecycle_t     (classified result) │
│  dir_entry_t     (sidebar tree data) │
│                                      │
│  scan_dir()      → lifecycle_t[]     │
│  expand_tree()   → dir_entry_t[]     │
│  search()        → lifecycle_t[]     │
│  discover()      → snapshot_t[]      │
│  parse_config()  → source_t[]        │
└──────────────────────────────────────┘
```

The engine is a static C library (`libengine.a`), linked into the app bundle at compile time. Swift imports it via a bridging header. The boundary is pure request→response: Swift calls a C function with inputs, gets back an allocated array + count, reads it, calls `rsyncx_free()` when done. No shared state, no callbacks, no lifetime management across the boundary.

---

## 4. Configuration

### Format — INI file (`config.ini`)

```ini
[local.site1]
dest = /mnt/external_drive/here

[remote.server1]
host = 192.168.1.80
user = user
ssh_key = /var/ssh/id_server1
dest = /home/user/backup

[remote.server2]
host = 192.168.1.90
user = user
ssh_key = /var/ssh/id_server2
dest = /site/backup
```

### Parsing Rules

- Section prefix determines type: `[local.*]` → `SOURCE_LOCAL`, `[remote.*]` → `SOURCE_REMOTE`
- Everything after the dot is the source name (displayed in the UI)
- `dest` is the backup root directory — must contain a `latest` symlink and snapshot directories
- Remote sections require `host`, `user`, `ssh_key`, and `dest`
- Local sections require only `dest`
- Duplicate section names → parse error

### Data Structure

```c
typedef enum { SOURCE_LOCAL, SOURCE_REMOTE } source_type_t;

typedef struct {
    char            name[128];     /* "site1", "server1", etc.            */
    source_type_t   type;          /* LOCAL or REMOTE                     */
    char            dest[512];     /* backup root path                    */
    char            host[128];     /* NULL for local                      */
    char            user[64];      /* NULL for local                      */
    char            ssh_key[256];  /* NULL for local                      */
} source_t;
```

---

## 5. Snapshot Discovery

### The Anchor: `latest` Symlink

The backup root contains date-named snapshot directories and a `latest` symlink pointing to the most recent one:

```
/backup_root/
├── 2024-01-15/
├── 2024-02-20/
├── 2024-03-01/
└── latest → 2024-03-01/
```

### Discovery Algorithm

```
1. readlink("<dest>/latest") → confirm it's a symlink, get target name
2. opendir("<dest>") → iterate siblings
3. Filter: real directories (not symlinks, not files) → these are the snapshots
4. Parse each directory name as a date
5. Sort by date → timeline built
```

### Date Parsing

Three formats supported (all are common rsync conventions):

| Format | Example | Parser |
|---|---|---|
| `%Y-%m-%d` | `2024-01-15` | `strptime(name, "%Y-%m-%d", &tm)` |
| `%Y-%m-%d_%H-%M` | `2024-01-15_15-30` | `strptime(name, "%Y-%m-%d_%H-%M", &tm)` |
| `%Y-%m-%dT%H-%M-%S` | `2024-01-15T15-30-00` | `strptime(name, "%Y-%m-%dT%H-%M-%S", &tm)` |

If a directory name fails to parse, it is skipped (not a snapshot).

**Note**: The `latest` symlink may point to an absolute path (e.g., `/mnt/nas/BACK_EXT/2026-06-06_21-29`) rather than a relative one. The discovery algorithm must handle both cases.

### Data Structure

```c
typedef struct {
    char    name[128];      /* directory name, e.g. "2024-01-15"          */
    char    full_path[512]; /* absolute path to snapshot dir               */
    int64_t date_epoch;     /* parsed date as epoch seconds for sorting   */
} snapshot_t;
```

---

## 6. Scanning

### Three Scan Implementations

| Implementation | When Used | Method |
|---|---|---|
| `scan_dir_macos()` | Local source on macOS | `getattrlistbulk` — bulk BSD syscall |
| `scan_dir_posix()` | Local source on Linux (future) | `opendir`/`readdir`/`lstat` — POSIX fallback |
| `scan_dir_remote()` | Any remote source | SSH + `find -printf` via `popen` |

The dispatcher `rsyncx_scan_dir()` selects the implementation based on `source_type_t` and compile-time `#ifdef`.

### macOS Local Scan — `opendir`/`readdir`/`lstat`

Initially planned to use `getattrlistbulk` (a macOS BSD syscall that returns attributes for every entry in a directory in one call). However, research revealed that `getattrlistbulk` does **not** expose `ATTR_CMN_MODE` (file permission bits) — the attribute constant doesn't exist in macOS's `attr.h`. This means a separate `lstat` call would be needed anyway for permissions, negating the performance benefit.

The final implementation uses `opendir`/`readdir`/`lstat` for local scanning — simple, portable, and still fast for single-directory scans. `getattrlistbulk` optimization can be revisited if per-directory scan latency becomes noticeable.

### POSIX Fallback — `opendir`/`readdir`/`lstat`

For Linux (future port):

```c
dir = opendir(snapshot_path);
while ((entry = readdir(dir))) {
    lstat(full_path, &st);
    // populate file_entry_t from struct stat
}
closedir(dir);
```

User/group name resolution via `getpwuid()`/`getgrgid()` — C standard library, no external commands.

### Remote Scan — SSH + `find -printf`

Unavoidable for remote sources — can't call syscalls on a remote host:

```c
snprintf(cmd, sizeof(cmd),
    "ssh -i %s -o BatchMode=yes -o StrictHostKeyChecking=no %s@%s "
    "'find \"%s/%s\" -maxdepth 1 -printf \"%%i\\t%%m\\t%%u\\t%%g\\t%%s\\t%%T@\\t%%n\\t%%P\\n\"'",
    src->ssh_key, src->user, src->host,
    snap->full_path, rel_path);

FILE *fp = popen(cmd, "r");
// parse tab-delimited lines → file_entry_t
```

The `-printf` format string:

```
%i  inode
%m  mode (octal)
%u  user name
%g  group name
%s  size
%T@ mtime (epoch.fraction)
%n  hard link count
%P  relative path
```

Delimited by tabs, one line per entry.

### Scan Scope

`rsyncx_scan_dir()` scans a single directory level (`-maxdepth 1` equivalent) across all snapshots in the active timeline range. It does NOT recurse into subdirectories. Subdirectories are only scanned when the user navigates into them (lazy).

For `rsyncx_search()`, the scan is recursive (no `-maxdepth`) with a `-name` filter applied.

---

## 7. Classification

### File Lifecycle

For each relative path found across snapshots, the engine builds a lifecycle record:

```
snapshot_mask → bitmap of which snapshots contain this path
inode_map     → { snapshot_idx → inode } for each appearance
```

Classification rules (evaluated in priority order):

| Condition | Class | Color | Description |
|---|---|---|---|
| `snapshot_mask` has gaps (present, absent, present again) | `CLASS_DEL_NEW` | Yellow + "Re-added" badge | File was deleted then re-created |
| Highest set bit < last snapshot index | `CLASS_DELETED` | Red | File no longer exists in source |
| Lowest set bit == last snapshot index | `CLASS_NEW` | Green | File first appeared in latest snapshot |
| `inode_map` has >1 distinct inode values | `CLASS_MODIFIED` | Yellow | File content changed between snapshots |
| `inode_map` has 1 inode value, present in 2+ consecutive | `CLASS_UNCHANGED` | Cyan | Hard-linked, identical across snapshots |

### Data Structure

```c
typedef enum {
    CLASS_UNCHANGED,    /* hard-linked across snapshots — rsync doing its job */
    CLASS_MODIFIED,     /* inode changed — content differs */
    CLASS_NEW,          /* first appeared in the latest snapshot */
    CLASS_DELETED,      /* present in earlier snapshots, absent in latest */
    CLASS_DEL_NEW       /* deleted, then re-created */
} file_class_t;

typedef struct {
    char         rel_path[512];       /* path relative to snapshot root        */
    file_class_t class;               /* lifecycle classification              */
    uint32_t     mode;                /* st_mode (type + permissions)          */
    char         user[64];            /* owner name (from getpwuid)            */
    char         group[64];           /* group name (from getgrgid)            */
    uint64_t     size;                /* file size (bytes)                     */
    int64_t      mtime;               /* modification time (epoch)             */
    int64_t      first_backup;        /* epoch of earliest snapshot w/ file    */
    int64_t      last_backup;         /* epoch of latest snapshot w/ file      */
    int64_t      deleted_in;          /* epoch of first snapshot w/o file, -1  */
    char         last_real_path[512]; /* absolute path in last snapshot w/ it  */
    uint8_t      is_dir;              /* 1 if directory, 0 if file             */
    uint32_t     nlink;               /* hard link count                       */
} lifecycle_t;
```

The `last_real_path` field is critical: it tells the UI where to find the file on disk for Quick Look preview and double-click open, even for deleted files (which still exist in older snapshot directories).

### Deleted + Re-created (DEL→NEW)

When a path appears in snapshots [0,1] then is absent in [2,3] then appears again in [4,5]:

- Class: `CLASS_DEL_NEW`
- `deleted_in`: epoch of snapshot 2
- `last_backup`: epoch of snapshot 5 (the latest appearance)
- `last_real_path`: path within snapshot 5
- Display: yellow row with "Re-added in <snapshot_name>" badge

---

## 8. Sidebar Tree

### Data Structure

```c
typedef struct {
    char    name[256];          /* directory name                           */
    uint8_t is_dir;             /* always 1 for tree entries                */
    uint8_t exists_in_latest;   /* 0 = red badge, 1 = normal               */
} dir_entry_t;
```

### Construction

When the user expands a directory in the sidebar, the engine scans that path across all snapshots in the active timeline range and returns the **union** of all subdirectories ever seen:

```
for each snapshot in [from_idx, to_idx]:
  if local:  opendir + readdir (dirs only) via getattrlistbulk or readdir
  if remote: SSH + find -maxdepth 1 -type d
merge by name → dir_entry_t[]
exists_in_latest = is this dir present in the latest snapshot in range?
```

### Red Badge

Directories that no longer exist in the latest snapshot get `exists_in_latest = 0`. The Swift layer renders these with a red dot badge overlay on the folder icon, signaling that this directory was deleted (or renamed/moved) in the source.

### Timeline Filtering

When the user narrows the timeline range, directories that only exist outside the range **disappear from the sidebar**. This matches the "files outside range disappear" rule.

---

## 9. Search

### Behavior

- Global search across the entire backup tree, not just the current directory
- Triggered on Enter key press (not live/debounced — recursive find across 30 snapshots takes seconds)
- Spinner shown during search
- Results displayed in the same NSTableView format as directory browsing

### Implementation

```c
int rsyncx_search(const source_t *src,
                  const snapshot_t *snaps, int snap_count,
                  const char *query,
                  int from_idx, int to_idx,
                  lifecycle_t **out, int *count);
```

The search runs `find` recursively (no `-maxdepth`) with `-name '*query*'` across all snapshots in range. For local sources, this uses `fts_open` (POSIX traversal API, fast on both macOS and Linux). For remote sources, SSH + `find -name`.

Results are merged and classified using the same classification engine as `scan_dir`.

---

## 10. C Engine API — Complete Contract

```c
#pragma once
#include <stdint.h>
#include <stddef.h>

/* ── Types ── */

typedef enum { SOURCE_LOCAL, SOURCE_REMOTE } source_type_t;

typedef struct {
    char            name[128];
    source_type_t   type;
    char            dest[512];
    char            host[128];
    char            user[64];
    char            ssh_key[256];
} source_t;

typedef struct {
    char    name[128];
    char    full_path[512];
    int64_t date_epoch;
} snapshot_t;

typedef enum {
    CLASS_UNCHANGED,
    CLASS_MODIFIED,
    CLASS_NEW,
    CLASS_DELETED,
    CLASS_DEL_NEW
} file_class_t;

typedef struct {
    char         rel_path[512];
    file_class_t class;
    uint32_t     mode;
    char         user[64];
    char         group[64];
    uint64_t     size;
    int64_t      mtime;
    int64_t      first_backup;
    int64_t      last_backup;
    int64_t      deleted_in;
    char         last_real_path[512];
    uint8_t      is_dir;
    uint32_t     nlink;
} lifecycle_t;

typedef struct {
    char    name[256];
    uint8_t is_dir;
    uint8_t exists_in_latest;
} dir_entry_t;

/* ── Functions ── */

/*
 * Parse config.ini at the given path.
 * Returns 0 on success, -1 on error.
 * Caller must free *out via rsyncx_free().
 */
int  rsyncx_parse_config(const char *path, source_t **out, int *count);

/*
 * Discover snapshots for a source.
 * Resolves the "latest" symlink, lists sibling directories, parses dates.
 * Returns 0 on success, -1 on error.
 * Caller must free *out via rsyncx_free().
 */
int  rsyncx_discover(const source_t *src, snapshot_t **out, int *count);

/*
 * Scan a single directory across all snapshots in [from_idx, to_idx].
 * Returns classified lifecycle entries for every file that ever existed
 * at the given relative path.
 * Returns 0 on success, -1 on error.
 * Caller must free *out via rsyncx_free().
 */
int  rsyncx_scan_dir(const source_t *src,
                     const snapshot_t *snaps, int snap_count,
                     const char *rel_path,
                     int from_idx, int to_idx,
                     lifecycle_t **out, int *count);

/*
 * Expand a directory in the sidebar tree.
 * Returns the union of all subdirectories ever seen at rel_path
 * across snapshots in [from_idx, to_idx].
 * Returns 0 on success, -1 on error.
 * Caller must free *out via rsyncx_free().
 */
int  rsyncx_expand_tree(const source_t *src,
                        const snapshot_t *snaps, int snap_count,
                        const char *rel_path,
                        int from_idx, int to_idx,
                        dir_entry_t **out, int *count);

/*
 * Search for files by name across the entire backup tree.
 * Recursive scan across all snapshots in [from_idx, to_idx].
 * Returns classified lifecycle entries matching the query.
 * Returns 0 on success, -1 on error.
 * Caller must free *out via rsyncx_free().
 */
int  rsyncx_search(const source_t *src,
                   const snapshot_t *snaps, int snap_count,
                   const char *query,
                   int from_idx, int to_idx,
                   lifecycle_t **out, int *count);

/*
 * Free memory returned by any engine function.
 */
void rsyncx_free(void *ptr);
```

---

## 11. UI Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 🔍 Search...                                    Source: [local.site1 ▾] │
├──────────────┬───────────────────────────────────────────────────────────┤
│              │                                                           │
│  ◀ Jan15 ────┼──── Mar01 ▶                                             │
│    Feb20  ●──┼──●                                                       │
│              │                                                           │
├──────────────┼──────┬────────────────────────────────────────────────────┤
│              │  ▼ ↑ │ CLASS PERM   USR GRP SIZE  MODIFIED  FIRST LAST  │
│ 📁 docs      │  📁  │ ──── ────── ─── ─── ──── ──────── ───── ─────  │
│ 📁 img       │  📁  │ UNCH -rw-r-- joe stf 4.2K 01-10    Jan15 Mar01  │
│ 📁 src       │  📄  │ NEW  -rw-r-- joe stf 12K  02-28    Mar01 Mar01  │
│ 🔴 old       │  📄  │ DEL→ -rw-r-- joe stf 890  12-01    Jan15 Feb20  │
│   (red badge)│  📄  │  NEW                                DEL:Feb20  │
│              │  📄  │ UNCH -rw-r-- joe stf 256  11-20    Jan15 Mar01  │
│              │      │                                           │
│              │      │                                           │
├──────────────┴──────┴────────────────────────────────────────────────────┤
│ 5 files │ 1 DEL→NEW │ 1 new │ 2 unchanged                    ⏳ Ready │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 12. AppKit Widget Map

| UI Element | AppKit Class | Role |
|---|---|---|
| Window | `NSWindow` | Main application window |
| Root layout | `NSSplitView` (vertical) | Sidebar ↔ Content divider |
| Sidebar tree | `NSOutlineView` | Directory tree with red badges |
| File list | `NSTableView` + `NSScrollView` | Columns, sorting, row colors |
| Column headers | `NSTableHeaderView` | Drag-reorder, resize, right-click show/hide |
| Source selector | `NSPopUpButton` | Pick backup source from config |
| Search bar | `NSSearchField` | Global search (⌘F) |
| Timeline | Custom `NSView` (`TimelineView`) | Dual-handle range selector with date markers |
| Status bar | `NSTextField` + `NSProgressIndicator` | File counts + spinner |
| Quick Look | `QLPreviewPanel` | Spacebar preview (floats over window) |

### Widget Hierarchy

```
NSWindow (MainWindow)
└── NSSplitView (vertical: sidebar | content)
    ├── NSOutlineView (sidebar)
    │   └── Data source: dir_entry_t[] from rsyncx_expand_tree()
    │   └── Red badge: dir.exists_in_latest == false → red dot overlay
    └── NSStackView (vertical: toolbar + timeline + table + status)
        ├── NSStackView (horizontal: search + source selector)
        │   ├── NSSearchField
        │   └── NSPopUpButton
        ├── TimelineView (custom NSView)
        │   └── Dual-handle range slider with date markers
        ├── NSTableView (file list, inside NSScrollView)
        │   └── Columns from ColumnConfig, data from lifecycle_t[]
        │   └── Row colors: DEL/DEL→NEW=red, NEW=green, MOD/DEL→NEW=yellow, UNCH=cyan
        │   └── Subclass: QuickLookTableView (intercepts Space key)
        │   └── Conforms to: QLPreviewPanelDataSource, QLPreviewPanelDelegate
        └── NSStackView (horizontal: status text + spinner)
            ├── NSTextField (file counts)
            └── NSProgressIndicator (spinning, shown during scans)
```

---

## 13. Interaction Map

| User Action | What Happens | Engine Call | Thread |
|---|---|---|---|
| App launch | Parse config.ini | `rsyncx_parse_config` | Main |
| Select source | Discover snapshots, load root "/" | `rsyncx_discover` + `rsyncx_scan_dir("/")` | Background |
| Click sidebar dir | Navigate into it | `rsyncx_scan_dir` + `rsyncx_expand_tree` | Background |
| Expand sidebar dir (▶) | Load children | `rsyncx_expand_tree` | Background |
| Adjust timeline range | Re-scan current dir with new from/to | `rsyncx_scan_dir` + `rsyncx_expand_tree` | Background |
| Type search + Enter | Global search | `rsyncx_search` | Background |
| Click column header | Sort table | Pure Swift (sort lifecycle_t[]) | Main |
| Right-click column header | Show/hide columns menu | Pure Swift (ColumnConfig) | Main |
| Double-click file row | Open with default app | `NSWorkspace.open(URL(last_real_path))` | Main |
| Select file + Space | Quick Look preview | QLPreviewPanel API | Main |
| Select file + Space again | Close Quick Look | QLPreviewPanel API | Main |

### Threading Model

All engine calls run on `DispatchQueue.global(qos: .userInitiated)`. The flow:

```
Swift:  call engine on background queue
Swift:  show spinner on main thread (via DispatchAsync)
C:      scan completes, returns allocated results
Swift:  hide spinner, populate table on main thread
Swift:  call rsyncx_free() after table is populated
```

The engine is reentrant-safe: each call is self-contained with no shared mutable state. Concurrent calls from Swift are safe as long as they target different directories or use different output buffers.

---

## 14. Quick Look Integration

### Spacebar Preview — Floating Panel

macOS's `QLPreviewPanel` provides the same preview experience as Finder's Spacebar preview. It supports images, PDFs, text/code, audio, video, Pages/Numbers/Keynote, Office documents, and archives — zero implementation work on our side.

### Implementation

1. Subclass `NSTableView` as `QuickLookTableView`
2. Override `keyDown(with:)` → intercept Space → call `togglePreviewPanel()`
3. Conform to `QLPreviewPanelDataSource` + `QLPreviewPanelDelegate`
4. Provide `previewPanel(_:previewItemAt:)` → `URL` from `lifecycle_t.last_real_path`
5. Toggle: `QLPreviewPanel.shared().makeKeyAndOrderFront(nil)` / `orderOut(nil)`

### Deleted Files

For deleted files, `last_real_path` points at the file inside the last snapshot that contained it. The file still exists on disk in that snapshot directory — rsync `--link-dest` doesn't remove old snapshots. Quick Look handles the rest normally.

### Zoom Animation

Implement `previewPanel(_:sourceFrameOnScreenFor:)` to return the icon rect of the selected row. This gives the Finder-style "pop out of icon" zoom animation.

---

## 15. Column Configuration

### Like macOS Finder

- Right-click any column header → `NSMenu` with checkmarks per column
- Drag columns to reorder (built into `NSTableView`)
- Resize columns by dragging divider (built into `NSTableView`)
- Persist choices in `UserDefaults` (column order + visibility + width)

### Default Columns

| Column | Key | Visible by Default | Source |
|---|---|---|---|
| Class | `class` | Yes | `lifecycle_t.class` |
| Permissions | `perm` | Yes | `lifecycle_t.mode` |
| Owner | `user` | Yes | `lifecycle_t.user` |
| Group | `group` | No | `lifecycle_t.group` |
| Size | `size` | Yes | `lifecycle_t.size` |
| Modified | `mtime` | Yes | `lifecycle_t.mtime` |
| First Backup | `first_backup` | Yes | `lifecycle_t.first_backup` |
| Last Backup | `last_backup` | Yes | `lifecycle_t.last_backup` |
| Deleted In | `deleted_in` | Yes | `lifecycle_t.deleted_in` |
| Hard Links | `nlink` | No | `lifecycle_t.nlink` |
| Path | `path` | Yes | `lifecycle_t.rel_path` |

---

## 16. Timeline Range Selector

### Custom NSView (`TimelineView`)

`NSSlider` does not support dual-thumb range selection. A custom view is required.

### Design

- Horizontal track with date markers for each snapshot
- Two draggable handles (from / to) defining the active range
- Date labels below the track
- Snap to nearest snapshot date when dragging

### Behavior

- On range change → re-scan current directory with new `from_idx`/`to_idx`
- Files outside the range disappear from the file list
- Directories outside the range disappear from the sidebar tree
- Default: full range (oldest → newest)

### Approximate Size

~200 lines of Swift — override `draw()`, `mouseDown()`, `mouseDragged()`, track handle positions, call delegate on change.

---

## 17. Row Coloring

### Implementation

Override `tableView(_:rowViewForRow:)` to return a custom `NSTableRowView` with `backgroundColor` set based on `lifecycle_t.class`:

| Class | Background Color | Text Color |
|---|---|---|
| `CLASS_UNCHANGED` | Light cyan (#E0F7FA) | Default |
| `CLASS_MODIFIED` | Light yellow (#FFF9C4) | Default |
| `CLASS_NEW` | Light green (#E8F5E9) | Default |
| `CLASS_DELETED` | Light red (#FFEBEE) | Dark red (#C62828) |
| `CLASS_DEL_NEW` | Light yellow (#FFF9C4) | Default + "Re-added" badge |

### Empty Row Gotcha

When `NSTableView` has fewer data rows than visible rows, the empty rows below use default alternating colors, creating a visual inconsistency with custom-colored data rows. Fix: set the table's `backgroundColor` to match the base row color.

---

## 18. Project Structure

```
rsync-explorer/
├── engine/
│   ├── engine.h             ← public C API (Swift imports this)
│   ├── config.c             ← INI parser
│   ├── discover.c           ← snapshot discovery via latest symlink
│   ├── scan.c               ← scan dispatch (macOS/POSIX/remote)
│   ├── scan_macos.c         ← getattrlistbulk implementation
│   ├── scan_posix.c         ← opendir/readdir/lstat fallback
│   ├── scan_remote.c        ← SSH + find -printf via popen
│   ├── classify.c           ← lifecycle classification logic
│   ├── search.c             ← recursive search (fts_open / SSH find)
│   ├── tree.c               ← sidebar tree expansion
│   ├── ssh.c                ← SSH command builder
│   ├── util.c               ← string pool, bitmap, epoch→date helpers
│   ├── cache.c              ← per-snapshot zlib scan cache (atomic write)
│   ├── index.c              ← in-memory backup index (hash map + search)
│   ├── module.modulemap     ← exposes engine.h to Swift as `import engine`
│   ├── test_*.c             ← engine test programs (run via meson test)
│   └── meson.build          ← builds libengine.a + tests
├── app/
│   ├── AppDelegate.swift
│   ├── MainWindowController.swift
│   ├── SidebarViewController.swift        ← NSOutlineView data source
│   ├── FileListViewController.swift       ← NSTableView data source + delegate
│   ├── QuickLookTableView.swift           ← NSTableView subclass (Space key)
│   ├── TimelineView.swift                 ← custom dual-handle range selector
│   ├── StatusBarController.swift          ← file counts + spinner
│   ├── ColumnConfig.swift                 ← show/hide/reorder + UserDefaults
│   ├── LifecycleRow.swift                 ← custom NSTableRowView (row colors)
│   ├── EngineBridge.swift                 ← thin Swift wrappers around C API
│   └── meson.build                        ← builds the Swift executable
├── scripts/
│   └── make_bundle.sh       ← assembles build/rsync-explorer.app
├── meson.build              ← root project + .app bundle custom_target
├── Info.plist               ← bundle metadata (CFBundleExecutable)
├── config.ini               ← user config (untracked; holds NAS details)
└── DESIGN.md                ← this document
```

---

## 19. Build System

Meson + Ninja, out-of-tree in `build/`:

```sh
meson setup build        # once
ninja -C build           # engine + Swift app + build/rsync-explorer.app
meson test -C build      # engine tests (search, ssh, index)
open build/rsync-explorer.app
```

- Root `meson.build` — project (`c` + `swift`, `c_std=c11`, `warning_level=2`,
  `werror=true`, `buildtype=debugoptimized`) and the `.app` bundle
  `custom_target` (assembled by `scripts/make_bundle.sh`).
- `engine/meson.build` — `libengine.a` (with `-fvisibility=hidden`) and the
  three test executables registered with `meson test`.
- `app/meson.build` — the Swift executable; `import engine` resolves through
  `engine/module.modulemap` via the engine include dir.

---

## 20. Future (Out of Scope for v1)

| Feature | Notes |
|---|---|
| **Linux port** | Replace `getattrlistbulk` with POSIX fallback, replace AppKit with GTK3 |
| **Inline preview pane** | `QLPreviewView` embedded in a bottom pane, toggled with ⌘I |
| **Snapshot diff view** | Side-by-side comparison of a file between two snapshots |
| **Restore** | Copy file from a snapshot back to the original location |
| **Backup statistics** | Total size, dedup savings, per-snapshot size growth |
| **Dark mode colors** | Adjust row colors for macOS dark appearance |
