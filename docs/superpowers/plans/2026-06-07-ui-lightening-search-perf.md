# UI Lightening + Search Performance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rsync-explorer's UI lighter and Finder-like (fewer columns, subtle marks, hideable timeline, light/dark themes) and make search fast and correct on macOS.

**Architecture:** A C engine (`engine/libengine.a`) does scanning/search; a Swift/AppKit app renders it. Engine search is fixed (portable `fts` instead of GNU `find -printf`) and parallelized (pthreads local, SSH `ControlMaster` multiplexing remote). The Swift layer trims columns, replaces full-row coloring with leading status dots + red deleted names, hides the timeline by default, adds a light/dark toggle, and discards stale search results.

**Tech Stack:** C11 (engine, `fts`, `pthread`), Swift + AppKit (Cocoa, Quartz). Build via `./build.sh`; engine via `make -C engine`. No Swift test target exists — Swift tasks verify by compiling and manual run. Engine tasks add real C tests.

**Branch:** `feature/ui-lightening-search-perf` (already created).

---

## File Structure

**Engine (C) — modify:**
- `engine/search.c` — replace `find -printf` local search with `fts`; parallelize local with pthreads.
- `engine/ssh.c` — add SSH `ControlMaster` multiplexing to all ssh command builders.
- `engine/search.c` adds `#include <fts.h>` and `#include <pthread.h>`.

**Engine (C) — create:**
- `engine/test_search.c` — standalone test: builds a hard-linked snapshot fixture in a temp dir, runs `rsyncx_search`, asserts classifications.
- `engine/test_ssh.c` — standalone test: asserts `ssh_build_find_cmd` emits multiplexing options.

**App (Swift) — modify:**
- `app/ColumnConfig.swift` — new default column set + bump UserDefaults keys to reset.
- `app/FileListViewController.swift` — leading status dot, red deleted name, remove badges.
- `app/LifecycleRow.swift` — remove full-row background coloring.
- `app/MainWindowController.swift` — toolbar toggle buttons + breadcrumb, hideable timeline, ⌘T, default search range, theme apply/toggle, search cancellation token.
- `app/AppDelegate.swift` — View-menu items (Show Timeline ⌘T, Toggle Theme).

---

## Phase 1 — Engine: correctness + performance

### Task 1: Fix local search (portable `fts` instead of `find -printf`)

**Files:**
- Create: `engine/test_search.c`
- Modify: `engine/search.c` (rewrite `search_local`, add `#include <fts.h>`)

- [ ] **Step 1: Write the failing test**

Create `engine/test_search.c`:

```c
/**
 * @file test_search.c
 * @brief Verifies rsyncx_search classifies files across a hard-linked
 *        snapshot fixture (unchanged / new / deleted).
 */
#include "engine_internal.h"
#include <assert.h>
#include <fcntl.h>

static void write_file(const char *path, const char *content)
{
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) { (void)write(fd, content, strlen(content)); close(fd); }
}

static lifecycle_t *find_entry(lifecycle_t *arr, int n, const char *name)
{
    for (int i = 0; i < n; i++)
        if (strstr(rsyncx_lc_rel_path(&arr[i]), name)) return &arr[i];
    return NULL;
}

int main(void)
{
    char tmpl[] = "/tmp/rsyncx_test_XXXXXX";
    char *base = mkdtemp(tmpl);
    assert(base != NULL);

    char snap1[512], snap2[512], p[1024], p2[1024];
    snprintf(snap1, sizeof snap1, "%s/snap1", base);
    snprintf(snap2, sizeof snap2, "%s/snap2", base);
    assert(mkdir(snap1, 0755) == 0);
    assert(mkdir(snap2, 0755) == 0);

    /* alpha.txt: unchanged — hard-linked across both snapshots */
    snprintf(p,  sizeof p,  "%s/alpha.txt", snap1); write_file(p, "A");
    snprintf(p2, sizeof p2, "%s/alpha.txt", snap2); assert(link(p, p2) == 0);

    /* gamma.txt: deleted — present only in the older snapshot */
    snprintf(p, sizeof p, "%s/gamma.txt", snap1); write_file(p, "G");

    /* beta.txt: new — present only in the latest snapshot */
    snprintf(p, sizeof p, "%s/beta.txt", snap2); write_file(p, "B");

    source_t src = rsyncx_make_source("test", SOURCE_LOCAL, base, "", "", "");
    snapshot_t snaps[2] = {
        rsyncx_make_snapshot("snap1", snap1, 1000),
        rsyncx_make_snapshot("snap2", snap2, 2000),
    };

    lifecycle_t *out = NULL;
    int count = 0;
    int rc = rsyncx_search(&src, snaps, 2, "txt", 0, 1, &out, &count);
    assert(rc == 0);

    lifecycle_t *a = find_entry(out, count, "alpha");
    lifecycle_t *b = find_entry(out, count, "beta");
    lifecycle_t *g = find_entry(out, count, "gamma");
    assert(a != NULL && a->class == CLASS_UNCHANGED);
    assert(b != NULL && b->class == CLASS_NEW);
    assert(g != NULL && g->class == CLASS_DELETED);

    printf("PASS: search returned %d entries; alpha=UNCH beta=NEW gamma=DEL\n", count);
    rsyncx_free(out);
    return 0;
}
```

- [ ] **Step 2: Build the engine and run the test to verify it fails**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine
clang -std=c11 -I engine -o engine/test_search engine/test_search.c engine/libengine.a
./engine/test_search
```
Expected: assertion failure (e.g. `Assertion failed: (a != NULL ...)`) and non-zero exit — because macOS `find` rejects `-printf`, so `search_local` returns no entries.

- [ ] **Step 3: Rewrite `search_local` to use `fts`**

In `engine/search.c`, add near the top with the other includes:
```c
#include <fts.h>
```

Replace the entire existing `search_local` function (the one that builds a `find … -printf` command and calls `popen`) with:
```c
static int search_local(const char *snapshot_path,
                        const char *query,
                        file_entry_array_t *out)
{
    char *paths[] = { (char *)snapshot_path, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return -1;

    size_t base_len = strlen(snapshot_path);

    FTSENT *ent;
    while ((ent = fts_read(fts)) != NULL) {
        /* Skip directories (pre- and post-order) and unreadable entries. */
        if (ent->fts_info == FTS_D  || ent->fts_info == FTS_DP ||
            ent->fts_info == FTS_DNR || ent->fts_info == FTS_ERR ||
            ent->fts_info == FTS_NS)
            continue;

        /* Match the filename like `find -name "*query*"` (case-sensitive). */
        if (query[0] != '\0' && strstr(ent->fts_name, query) == NULL)
            continue;

        const struct stat *st = ent->fts_statp;
        if (S_ISDIR(st->st_mode)) continue;   /* -not -type d */

        file_entry_t fe;
        memset(&fe, 0, sizeof(fe));

        /* rel_path = path relative to the snapshot root (like find's %P). */
        const char *rel = ent->fts_path + base_len;
        while (*rel == '/') rel++;
        str_copy(fe.rel_path, sizeof(fe.rel_path), rel);

        fe.inode = (uint64_t)st->st_ino;
        fe.mode  = (uint32_t)st->st_mode;
        fe.size  = (uint64_t)st->st_size;
        fe.mtime = (int64_t)st->st_mtime;
        fe.nlink = (uint32_t)st->st_nlink;
        fe.is_dir = 0;

        resolve_user(st->st_uid, fe.user, sizeof(fe.user));
        resolve_group(st->st_gid, fe.group, sizeof(fe.group));

        if (fe_array_push(out, &fe) != 0) {
            fts_close(fts);
            return -1;
        }
    }

    fts_close(fts);
    return 0;
}
```

- [ ] **Step 4: Rebuild and run the test to verify it passes**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine
clang -std=c11 -I engine -o engine/test_search engine/test_search.c engine/libengine.a
./engine/test_search
```
Expected: `PASS: search returned 3 entries; alpha=UNCH beta=NEW gamma=DEL` and exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/search.c engine/test_search.c
git commit -m "fix(engine): portable fts-based local search (fixes macOS -printf bug)"
```

---

### Task 2: Parallelize local search with pthreads

**Files:**
- Modify: `engine/search.c` (add `#include <pthread.h>`, worker, replace sequential local loop)
- Test: reuse `engine/test_search.c`

- [ ] **Step 1: Confirm the existing test still represents desired behavior**

Run (should already PASS from Task 1):
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine && clang -std=c11 -I engine -o engine/test_search engine/test_search.c engine/libengine.a && ./engine/test_search
```
Expected: `PASS: search returned 3 entries; ...`. This test also guards Task 2 (parallel results must match).

- [ ] **Step 2: Add the pthread include and a worker**

In `engine/search.c`, add with the other includes:
```c
#include <pthread.h>
```

Add this above `rsyncx_search`:
```c
typedef struct {
    const char         *snapshot_path;
    const char         *query;
    file_entry_array_t *out;
    int                 rc;
} local_search_job_t;

static void *local_search_worker(void *arg)
{
    local_search_job_t *job = (local_search_job_t *)arg;
    job->rc = search_local(job->snapshot_path, job->query, job->out);
    return NULL;
}
```

- [ ] **Step 3: Replace the sequential local loop with a parallel one**

In `rsyncx_search`, find the `else` branch labeled `/* ── SEQUENTIAL LOCAL SEARCH ── */` containing the `for` loop that calls `search_local(...)` sequentially. Replace that whole `else { ... }` body with:
```c
    } else {
        /* ── PARALLEL LOCAL SEARCH ── */
        pthread_t          *threads = malloc((size_t)range_len * sizeof(pthread_t));
        local_search_job_t *jobs    = malloc((size_t)range_len * sizeof(local_search_job_t));

        if (!threads || !jobs) {
            free(threads); free(jobs);
            for (int i = 0; i < range_len; i++) snap_arrays[i].count = 0;
        } else {
            for (int i = 0; i < range_len; i++) {
                jobs[i].snapshot_path = snaps[from_idx + i].full_path;
                jobs[i].query         = query;
                jobs[i].out           = &snap_arrays[i];
                jobs[i].rc            = 0;
                if (pthread_create(&threads[i], NULL,
                                   local_search_worker, &jobs[i]) != 0) {
                    /* Fall back to running this snapshot inline. */
                    jobs[i].rc = search_local(jobs[i].snapshot_path,
                                              jobs[i].query, jobs[i].out);
                    threads[i] = 0;
                }
            }
            for (int i = 0; i < range_len; i++) {
                if (threads[i] != 0) pthread_join(threads[i], NULL);
                if (jobs[i].rc != 0) snap_arrays[i].count = 0;
            }
            free(threads);
            free(jobs);
        }
    }
```

- [ ] **Step 4: Rebuild and run the test to verify it still passes**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine && clang -std=c11 -I engine -o engine/test_search engine/test_search.c engine/libengine.a && ./engine/test_search
```
Expected: `PASS: search returned 3 entries; alpha=UNCH beta=NEW gamma=DEL` and exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/search.c
git commit -m "perf(engine): parallelize local search across snapshots with pthreads"
```

---

### Task 3: SSH connection multiplexing for remote search

**Files:**
- Modify: `engine/ssh.c` (add a shared options macro; use it in all three builders)
- Create: `engine/test_ssh.c`

- [ ] **Step 1: Write the failing test**

Create `engine/test_ssh.c`:
```c
/**
 * @file test_ssh.c
 * @brief Verifies ssh command builders enable connection multiplexing.
 */
#include "engine_internal.h"
#include <assert.h>

int main(void)
{
    source_t src = rsyncx_make_source("r", SOURCE_REMOTE,
                                      "/backup", "host.example", "user",
                                      "/home/user/.ssh/id_ed25519");
    char cmd[SSH_CMD_MAX];

    assert(ssh_build_find_cmd(&src, "/backup/snap1", -1, NULL, "needle",
                              cmd, sizeof cmd) == 0);
    assert(strstr(cmd, "ControlMaster=auto") != NULL);
    assert(strstr(cmd, "ControlPath=")       != NULL);
    assert(strstr(cmd, "ControlPersist=")    != NULL);
    assert(strstr(cmd, "-name \"needle\"")   != NULL);

    printf("PASS: ssh find cmd enables multiplexing\n");
    return 0;
}
```

- [ ] **Step 2: Build and run the test to verify it fails**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine
clang -std=c11 -I engine -o engine/test_ssh engine/test_ssh.c engine/libengine.a
./engine/test_ssh
```
Expected: assertion failure on `ControlMaster=auto` (multiplexing not yet present); non-zero exit.

- [ ] **Step 3: Add a shared SSH options macro and use it**

In `engine/ssh.c`, add directly under `#include "engine_internal.h"`:
```c
/*
 * Shared ssh options. ControlMaster reuses a single TCP/SSH connection
 * across the per-snapshot searches; ControlPersist keeps the master alive
 * briefly so later invocations attach instead of re-handshaking.
 * %%C expands (via ssh) to a hash of the connection parameters — unique
 * per host, shared across our parallel children. (%% escapes % for snprintf.)
 */
#define SSH_OPTS \
    "-o BatchMode=yes -o StrictHostKeyChecking=no " \
    "-o ControlMaster=auto -o ControlPersist=60 " \
    "-o ControlPath=/tmp/rsyncx-ssh-%%C"
```

In `ssh_build_find_cmd`, replace the first `snprintf` (the one that writes
`"ssh -i %s -o BatchMode=yes -o StrictHostKeyChecking=no %s@%s 'find \"%s\""`) with:
```c
    written = snprintf(cmd + pos, cmd_size - pos,
        "ssh -i %s " SSH_OPTS " %s@%s 'find \"%s\"",
        src->ssh_key, src->user, src->host, find_path);
```

In `ssh_build_ls_cmd`, replace its `snprintf` with:
```c
    int written = snprintf(cmd, cmd_size,
        "ssh -i %s " SSH_OPTS " %s@%s 'ls -1 \"%s\"'",
        src->ssh_key, src->user, src->host, path);
```

In `ssh_build_readlink_cmd`, replace its `snprintf` with:
```c
    int written = snprintf(cmd, cmd_size,
        "ssh -i %s " SSH_OPTS " %s@%s 'readlink -f \"%s\"'",
        src->ssh_key, src->user, src->host, path);
```

- [ ] **Step 4: Rebuild and run the test to verify it passes**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine
clang -std=c11 -I engine -o engine/test_ssh engine/test_ssh.c engine/libengine.a
./engine/test_ssh
```
Expected: `PASS: ssh find cmd enables multiplexing` and exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/ssh.c engine/test_ssh.c
git commit -m "perf(engine): enable SSH ControlMaster multiplexing for remote ops"
```

---

## Phase 2 — App: lighter Finder-style UI

> Swift tasks verify by building (`./build.sh` rebuilds the engine then the app) and a manual run (`open rsync-explorer.app`). There is no Swift test target.

### Task 4: New default column set

**Files:**
- Modify: `app/ColumnConfig.swift`

- [ ] **Step 1: Replace the column definitions**

In `app/ColumnConfig.swift`, replace the entire `static let all: [ColumnDef] = [ ... ]` array with:
```swift
    static let all: [ColumnDef] = [
        ColumnDef(id: "path",        title: "Name",          minWidth: 200, defaultVisible: true),
        ColumnDef(id: "size",        title: "Size",          minWidth: 70,  defaultVisible: true),
        ColumnDef(id: "mtime",       title: "Date Modified", minWidth: 130, defaultVisible: true),
        ColumnDef(id: "lastBackup",  title: "Last Backup",   minWidth: 110, defaultVisible: true),
        ColumnDef(id: "firstBackup", title: "First Backup",  minWidth: 110, defaultVisible: false),
        ColumnDef(id: "class",       title: "Class",         minWidth: 50,  defaultVisible: false),
        ColumnDef(id: "perm",        title: "Permissions",   minWidth: 95,  defaultVisible: false),
        ColumnDef(id: "user",        title: "User",          minWidth: 60,  defaultVisible: false),
        ColumnDef(id: "group",       title: "Group",         minWidth: 60,  defaultVisible: false),
        ColumnDef(id: "deletedIn",   title: "Deleted In",    minWidth: 130, defaultVisible: false),
        ColumnDef(id: "nlink",       title: "Hard Links",    minWidth: 70,  defaultVisible: false),
    ]
```

- [ ] **Step 2: Bump the UserDefaults keys so the new defaults take effect**

In `app/ColumnConfig.swift`, in `class ColumnConfig`, replace the three key constants:
```swift
    private let keyOrder    = "rsyncx.column.order"
    private let keyVisible  = "rsyncx.column.visible"
    private let keyWidth    = "rsyncx.column.width"
```
with:
```swift
    private let keyOrder    = "rsyncx.column.order.v2"
    private let keyVisible  = "rsyncx.column.visible.v2"
    private let keyWidth    = "rsyncx.column.width.v2"
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 4: Manual verification**

Run `open rsync-explorer.app`, pick a source. Expected: table shows exactly four columns — **Name, Size, Date Modified, Last Backup** — in that order.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/ColumnConfig.swift
git commit -m "feat(ui): default to Name/Size/Date Modified/Last Backup columns"
```

---

### Task 5: Leading status dot + red deleted name (remove badges)

**Files:**
- Modify: `app/FileListViewController.swift`

- [ ] **Step 1: Add a status-dot helper**

In `app/FileListViewController.swift`, in the `// MARK: - File icon (like Finder)` area (just above `iconForFile`), add:
```swift
    /// Small leading dot: green = new, amber = modified/recreated, none otherwise.
    private func statusDot(for cls: FileClass) -> NSView? {
        let color: NSColor
        switch cls {
        case .isNew:             color = .systemGreen
        case .modified, .delNew: color = .systemOrange
        default:                 return nil   // deleted shows as red name; unchanged shows nothing
        }
        let dot = NSView(frame: NSRect(x: 6, y: 8, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        return dot
    }
```

- [ ] **Step 2: Rewrite the "path" cell branch (dot + icon + red-or-default name, no badge)**

In `tableView(_:viewFor:row:)`, replace the entire `if colId == "path" { ... }` block (icon + label + the `if file.classification != .unchanged { let badge ... }` badge block) with:
```swift
        if colId == "path" {
            if let dot = statusDot(for: file.classification) {
                cell.addSubview(dot)
            }

            let icon = NSImageView()
            icon.image = iconForFile(file)
            icon.imageScaling = .scaleProportionallyDown
            icon.frame = NSRect(x: 18, y: 2, width: 16, height: 16)
            cell.addSubview(icon)

            let label = NSTextField(labelWithString: displayName(file))
            label.font = NSFont.systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = NSRect(x: 38, y: 0, width: 400, height: 20)
            label.textColor = (file.classification == .deleted)
                ? .systemRed
                : .labelColor
            cell.addSubview(label)
        } else {
```
(Keep the existing `else { ... }` body that renders the other columns unchanged, including its closing brace and `return cell`.)

- [ ] **Step 3: Remove the now-unused badge helper**

In `app/FileListViewController.swift`, delete the entire `private func badgeLabel(for cls: FileClass) -> NSTextField { ... }` function and the `private func textColor(for cls: FileClass) -> NSColor { ... }` function. Leave `badgeColor(for:)` in place — it is still used by the `class` column in the `else` branch.

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors (no references to `badgeLabel`/`textColor(for:)` remain).

- [ ] **Step 5: Manual verification**

Run `open rsync-explorer.app`, browse to a folder with mixed lifecycle files. Expected: new files show a green dot before the name, modified/recreated show an amber dot, deleted files show their name in red, unchanged show no dot. No pill-shaped text badges appear.

- [ ] **Step 6: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/FileListViewController.swift
git commit -m "feat(ui): leading status dots + red deleted name, drop class badges"
```

---

### Task 6: Remove full-row coloring

**Files:**
- Modify: `app/LifecycleRow.swift`

- [ ] **Step 1: Strip the background fill**

Replace the entire contents of `app/LifecycleRow.swift` with:
```swift
/**
 * LifecycleRow.swift
 * Plain table row. Lifecycle is now conveyed by a leading dot / red name
 * in the Name cell (see FileListViewController), not by row background color.
 */

import Cocoa

class LifecycleRow: NSTableRowView {

    var classification: FileClass = .unchanged

    override var isEmphasized: Bool {
        get { return false }
        set { }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 3: Manual verification**

Run `open rsync-explorer.app`. Expected: rows have the normal Finder background (alternating/none), no red/green/yellow/cyan row tints. Selection highlight still works.

- [ ] **Step 4: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/LifecycleRow.swift
git commit -m "feat(ui): remove full-row lifecycle coloring"
```

---

### Task 7: Hide the timeline by default + toggle (⌘T) + all-snapshots default range

**Files:**
- Modify: `app/MainWindowController.swift`
- Modify: `app/AppDelegate.swift`

- [ ] **Step 1: Add timeline-visibility state and a height constraint property**

In `app/MainWindowController.swift`, add these stored properties to the class (near the other `private let`/`private var` declarations such as `splitView`, `timelineView`):
```swift
    private let timelineToggleButton = NSButton()
    private var timelineHeightConstraint: NSLayoutConstraint!
    private let keyTimelineVisible = "rsyncx.timeline.visible"
    private var timelineVisible: Bool {
        get { UserDefaults.standard.bool(forKey: keyTimelineVisible) } // default false
        set { UserDefaults.standard.set(newValue, forKey: keyTimelineVisible) }
    }
```

- [ ] **Step 2: Capture the timeline height constraint and apply initial visibility**

In `buildUI()`, in the `NSLayoutConstraint.activate([...])` call, find the line:
```swift
            timelineView.heightAnchor.constraint(equalToConstant: 40),
```
Replace it with a placeholder that we keep a reference to. Just *above* the `NSLayoutConstraint.activate([` call, add:
```swift
        timelineHeightConstraint = timelineView.heightAnchor.constraint(equalToConstant: 40)
```
and in the array replace that line with:
```swift
            timelineHeightConstraint,
```

Then, immediately after the `NSLayoutConstraint.activate([...])` block in `buildUI()`, add:
```swift
        // Timeline hidden by default; user toggles it on.
        applyTimelineVisibility()
```

- [ ] **Step 3: Add the timeline toggle button to the toolbar**

In `buildUI()`, where the toolbar subviews are added (the block with `toolbar.addSubview(backButton)`, `toolbar.addSubview(sourcePopup)`, `toolbar.addSubview(searchField)`), add the toggle button. Insert after `searchField.contentType = .filename` (button config) and add it to the toolbar:
```swift
        timelineToggleButton.bezelStyle = .inline
        timelineToggleButton.image = NSImage(systemSymbolName: "clock",
                                             accessibilityDescription: "Toggle Timeline")
        timelineToggleButton.target = self
        timelineToggleButton.action = #selector(toggleTimeline(_:))
        timelineToggleButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(timelineToggleButton)
```
And in the `NSLayoutConstraint.activate([...])` block that positions the toolbar items (the one anchoring `searchField.trailingAnchor` to the toolbar trailing), add constraints to place the toggle just left of the search field. Change the search field's trailing constraint and add the button:
```swift
            timelineToggleButton.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            timelineToggleButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            timelineToggleButton.widthAnchor.constraint(equalToConstant: 28),
```

- [ ] **Step 4: Add the toggle action and the visibility applier**

In `app/MainWindowController.swift`, in the `// MARK: - TimelineViewDelegate` area (near `timelineRangeChanged`), add:
```swift
    @objc func toggleTimeline(_ sender: Any?) {
        timelineVisible.toggle()
        applyTimelineVisibility()
        if !timelineVisible {
            // Reset to the full range so a hidden timeline means "all snapshots".
            fromIdx = 0
            toIdx = max(0, snapshots.count - 1)
            timelineView.fromIdx = fromIdx
            timelineView.toIdx = toIdx
            scanCurrentDir()
            expandCurrentTree()
        }
    }

    private func applyTimelineVisibility() {
        timelineView.isHidden = !timelineVisible
        timelineHeightConstraint.constant = timelineVisible ? 40 : 0
        timelineToggleButton.state = timelineVisible ? .on : .off
    }
```

- [ ] **Step 5: Default the search range to all snapshots when the timeline is hidden**

In `searchSubmitted()`, replace:
```swift
        let from = fromIdx
        let to = toIdx
        let snaps = snapshots
```
with:
```swift
        let snaps = snapshots
        let from = timelineVisible ? fromIdx : 0
        let to   = timelineVisible ? toIdx   : max(0, snaps.count - 1)
```

- [ ] **Step 6: Add the View-menu item (⌘T)**

In `app/AppDelegate.swift`, in `setupMenuBar()`, find the View menu block:
```swift
        // View menu
        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: "View")
        viewItem.submenu?.addItem(NSMenuItem(title: "Enter Full Screen",
                                             action: #selector(NSWindow.toggleFullScreen(_:)),
                                             keyEquivalent: "f"))
        mainMenu.addItem(viewItem)
```
Replace it with:
```swift
        // View menu
        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: "View")
        let timelineMenuItem = NSMenuItem(
            title: "Show Timeline",
            action: #selector(MainWindowController.toggleTimeline(_:)),
            keyEquivalent: "t")
        timelineMenuItem.target = nil   // routed via the responder chain
        viewItem.submenu?.addItem(timelineMenuItem)
        viewItem.submenu?.addItem(NSMenuItem.separator())
        viewItem.submenu?.addItem(NSMenuItem(title: "Enter Full Screen",
                                             action: #selector(NSWindow.toggleFullScreen(_:)),
                                             keyEquivalent: "f"))
        mainMenu.addItem(viewItem)
```

- [ ] **Step 7: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 8: Manual verification**

Run `open rsync-explorer.app`. Expected: the timeline bar is **not** visible on launch; the split view sits directly under the toolbar. Press ⌘T (or click the clock button) → the timeline appears; press again → it collapses with no leftover gap. With the timeline hidden, typing a query and pressing Return searches across all snapshots (deleted/old files appear).

- [ ] **Step 9: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/MainWindowController.swift app/AppDelegate.swift
git commit -m "feat(ui): hide timeline by default, toggle via toolbar/⌘T, search all snapshots"
```

---

### Task 8: Breadcrumb + columns toolbar button

**Files:**
- Modify: `app/MainWindowController.swift`

- [ ] **Step 1: Add a breadcrumb label and a columns button property**

In `app/MainWindowController.swift`, add to the class properties:
```swift
    private let breadcrumbLabel = NSTextField(labelWithString: "/")
    private let columnsButton = NSButton()
```

- [ ] **Step 2: Configure and place the breadcrumb + columns button in the toolbar**

In `buildUI()`, after the back button is configured and added to the toolbar, add the breadcrumb next to it:
```swift
        breadcrumbLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        breadcrumbLabel.textColor = .secondaryLabelColor
        breadcrumbLabel.lineBreakMode = .byTruncatingHead
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(breadcrumbLabel)
```
Configure the columns button (place near the timeline toggle button setup):
```swift
        columnsButton.bezelStyle = .inline
        columnsButton.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                      accessibilityDescription: "Columns")
        columnsButton.target = self
        columnsButton.action = #selector(showColumnsMenu(_:))
        columnsButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(columnsButton)
```
Add layout constraints in the toolbar's `NSLayoutConstraint.activate([...])` block (breadcrumb after `sourcePopup`, columns button left of the timeline toggle):
```swift
            breadcrumbLabel.leadingAnchor.constraint(equalTo: sourcePopup.trailingAnchor, constant: 10),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            columnsButton.trailingAnchor.constraint(equalTo: timelineToggleButton.leadingAnchor, constant: -8),
            columnsButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            columnsButton.widthAnchor.constraint(equalToConstant: 28),
```

- [ ] **Step 3: Keep the breadcrumb in sync with the current path**

In `app/MainWindowController.swift`, add a helper and call it where the path changes. Add the helper near `// MARK: - Helpers`:
```swift
    private func updateBreadcrumb() {
        breadcrumbLabel.stringValue = currentPath.isEmpty ? "/" : "/" + currentPath
    }
```
Call `updateBreadcrumb()` at the end of `scanCurrentDir()` is too deep (background); instead call it from the navigation points. Add `updateBreadcrumb()` as the first line inside `scanCurrentDir()` (it runs on the main thread before dispatching):
```swift
    private func scanCurrentDir() {
        updateBreadcrumb()
        guard let source = currentSource, !snapshots.isEmpty else { return }
```

- [ ] **Step 4: Expose the columns menu from the file list**

The column show/hide menu already lives in `FileListViewController.showColumnMenu()`. Add a thin forwarding action in `app/MainWindowController.swift` near the search section:
```swift
    @objc private func showColumnsMenu(_ sender: Any?) {
        fileListVC.showColumnMenu()
    }
```
`showColumnMenu()` is already `func` (non-private) in `FileListViewController`, so it is callable.

- [ ] **Step 5: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 6: Manual verification**

Run `open rsync-explorer.app`. Expected: the toolbar shows back · source · breadcrumb (left) and columns · timeline-toggle · search (right). Navigating into a folder updates the breadcrumb. Clicking the columns button opens the show/hide column menu.

- [ ] **Step 7: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/MainWindowController.swift
git commit -m "feat(ui): single toolbar with breadcrumb and columns button"
```

---

### Task 9: Light/dark theme (system default + sun/moon toggle)

**Files:**
- Modify: `app/MainWindowController.swift`
- Modify: `app/AppDelegate.swift`

- [ ] **Step 1: Add theme state + a toggle button property**

In `app/MainWindowController.swift`, add to the class properties:
```swift
    private let themeToggleButton = NSButton()
    private let keyAppearance = "rsyncx.appearance" // "system" | "light" | "dark"
```

- [ ] **Step 2: Add apply/toggle logic**

In `app/MainWindowController.swift`, near `// MARK: - Helpers`, add:
```swift
    // MARK: - Theme

    private func storedAppearance() -> String {
        return UserDefaults.standard.string(forKey: keyAppearance) ?? "system"
    }

    private func applyStoredAppearance() {
        switch storedAppearance() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // follow the system
        }
        updateThemeButtonImage()
    }

    private func updateThemeButtonImage() {
        let dark = effectiveAppearanceIsDark()
        let symbol = dark ? "sun.max" : "moon.fill"
        themeToggleButton.image = NSImage(systemSymbolName: symbol,
                                          accessibilityDescription: "Toggle Theme")
    }

    private func effectiveAppearanceIsDark() -> Bool {
        let name = (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        return name == .darkAqua
    }

    @objc func toggleTheme(_ sender: Any?) {
        // First use overrides "system" with an explicit choice; thereafter flips.
        let nextDark = !effectiveAppearanceIsDark()
        UserDefaults.standard.set(nextDark ? "dark" : "light", forKey: keyAppearance)
        applyStoredAppearance()
    }
```

- [ ] **Step 3: Add the toggle button to the toolbar and apply the theme on launch**

In `buildUI()`, configure and add the theme button (place near the other toolbar buttons), positioned left of the columns button:
```swift
        themeToggleButton.bezelStyle = .inline
        themeToggleButton.target = self
        themeToggleButton.action = #selector(toggleTheme(_:))
        themeToggleButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(themeToggleButton)
```
Add its constraints in the toolbar `NSLayoutConstraint.activate([...])` block:
```swift
            themeToggleButton.trailingAnchor.constraint(equalTo: columnsButton.leadingAnchor, constant: -8),
            themeToggleButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            themeToggleButton.widthAnchor.constraint(equalToConstant: 28),
```
At the end of `buildUI()` (after `applyTimelineVisibility()`), add:
```swift
        applyStoredAppearance()
```

- [ ] **Step 4: Add a View-menu item for the theme**

In `app/AppDelegate.swift`, in `setupMenuBar()` View menu block (the one edited in Task 7), add after the timeline item separator and before "Enter Full Screen":
```swift
        let themeMenuItem = NSMenuItem(
            title: "Toggle Light/Dark",
            action: #selector(MainWindowController.toggleTheme(_:)),
            keyEquivalent: "")
        themeMenuItem.target = nil   // routed via the responder chain
        viewItem.submenu?.addItem(themeMenuItem)
        viewItem.submenu?.addItem(NSMenuItem.separator())
```

- [ ] **Step 5: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 6: Manual verification**

Run `open rsync-explorer.app`. Expected: on first launch the app matches the macOS system appearance. Clicking the sun/moon button (or View ▸ Toggle Light/Dark) flips between light and dark; the icon swaps (moon in light mode, sun in dark mode). Text and rows remain readable in both modes (no leftover hardcoded light backgrounds, since row coloring was removed in Task 6). Relaunching preserves the chosen mode.

- [ ] **Step 7: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/MainWindowController.swift app/AppDelegate.swift
git commit -m "feat(ui): light/dark theme following system with sun/moon toggle"
```

---

### Task 10: Search cancellation (discard stale results)

**Files:**
- Modify: `app/MainWindowController.swift`

- [ ] **Step 1: Add a generation counter**

In `app/MainWindowController.swift`, add to the class properties:
```swift
    private var searchGeneration = 0
```

- [ ] **Step 2: Stamp each search and ignore stale completions**

In `searchSubmitted()`, increment the generation before dispatching and capture it. Replace:
```swift
        guard !query.isEmpty, let source = currentSource else { return }
        statusBar.startLoading()
```
with:
```swift
        guard !query.isEmpty, let source = currentSource else { return }
        statusBar.startLoading()
        searchGeneration += 1
        let generation = searchGeneration
```
Then, inside the `DispatchQueue.main.async { ... }` completion, make the first line after `guard let self = self else { return }`:
```swift
                guard let self = self else { return }
                guard generation == self.searchGeneration else { return } // stale search; discard
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: ends with `✓ Done: rsync-explorer.app`, no Swift errors.

- [ ] **Step 4: Manual verification**

Run `open rsync-explorer.app`. Search for one term and quickly search for another before the first completes. Expected: the table ends on the **latest** query's results; the earlier (slower) search does not overwrite them.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/MainWindowController.swift
git commit -m "feat(ui): discard stale search results via generation token"
```

---

## Final Verification

- [ ] **Engine tests pass**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine
clang -std=c11 -I engine -o engine/test_search engine/test_search.c engine/libengine.a && ./engine/test_search
clang -std=c11 -I engine -o engine/test_ssh    engine/test_ssh.c    engine/libengine.a && ./engine/test_ssh
```
Expected: both print `PASS: ...` and exit 0.

- [ ] **Full app builds**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh
```
Expected: `✓ Done: rsync-explorer.app`.

- [ ] **End-to-end manual pass**

`open rsync-explorer.app`: four-column table; dots/red-name correct in light AND dark; timeline hidden by default, ⌘T toggles it; search across all snapshots is fast and returns results for a local source (previously empty); rapid re-search shows only the latest results.

---

## Notes & Risks

- **`fts` field mapping:** `search_local` maps `FTSENT->fts_statp` to `file_entry_t` exactly as `scan_posix.c` maps `lstat`; user/group names come from the existing `resolve_user`/`resolve_group` inline helpers.
- **SSH `ControlPath` length:** `/tmp/rsyncx-ssh-%C` stays well under the `sun_path` limit. `ControlPersist=60` auto-reaps the master, so no manual socket cleanup is needed.
- **Persistent search index (Approach B)** is intentionally out of scope (see the design spec).
- **Column UserDefaults reset:** keys are bumped to `*.v2` so existing users get the new default columns rather than their old persisted 8-column layout.
