# Index Scan-Once Cache + Range Filter + Parallel Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the in-memory backup index fast at 50+ snapshots × 500k+ files: each snapshot is SSH-scanned at most once ever (persistent zlib cache), timeline range changes are instant (in-memory reclassification, no rescan), and the unavoidable cold scan runs on a parallel worker pool.

**Architecture:** New `engine/cache.c` persists per-snapshot `file_entry_t` listings under `~/Library/Caches/rsync-explorer/` (snapshots are immutable, so entries never expire; the newest snapshot is always rescanned). `engine/index.c` gains a `changed` bitmap per node and `rsyncx_index_set_range()`, which reclassifies all nodes for a sub-range with 128-bit mask ops; `rsyncx_build_index` keeps its signature but always indexes all snapshots (newest 128 max) and treats `from/to` as the initial filter. The build scans snapshots on a pthread pool (cache-read or scan), merging strictly in snapshot order. The app then calls `setRange` on timeline changes instead of rebuilding.

**Tech Stack:** C11 (pthreads, zlib via `dependency('zlib')`), Meson/Ninja, Swift/AppKit, GNU find over SSH (unchanged).

**Spec:** `docs/superpowers/specs/2026-06-12-index-cache-perf-design.md`

**Repo facts you need:**
- Build: `ninja -C build` (Meson; werror — zero warnings tolerated). Tests: `meson test -C build --print-errorlogs` (suites: `search`, `ssh`, `index`).
- `file_entry_t` / `file_entry_array_t` / `fe_array_*` / `str_copy` are in `engine/engine_internal.h` + `engine/util.c`.
- `engine/index.c` currently: `scan_tree_local` (fts), `scan_tree_remote` (SSH find), `rel_path_safe` (static, line ~62), node store with `present_lo/present_hi` bitmaps, `merge_snapshot`, `finalize` (classification + tree linking), public `rsyncx_build_index(src, snaps, snap_count, from_idx, to_idx, progress_cb, ctx)` which today *copies and scans only* `snaps[from_idx..to_idx]`.
- `engine/test_index.c` has `write_file`, `has_path`, `build_fixture` (2-snapshot fixture via `mkdtemp` + hard links), and tests run by `meson test`.
- Existing classification semantics (preserve exactly): UNCHANGED / MODIFIED (inode changed) / NEW (first appears in last snapshot of range) / DELETED (absent at range end; `deleted_in` = epoch of first absent snapshot) / DEL_NEW (presence gap).
- The Swift app calls the index via `app/EngineBridge.swift`; timeline handlers live in `app/MainWindowController.swift` (`timelineRangeChanged`, `toggleTimeline`, `rebuildIndex`).

---

### Task 1: Cache module (`engine/cache.c`)

**Files:**
- Create: `engine/cache.c`
- Modify: `engine/engine_internal.h` (declarations; move `rel_path_safe` here)
- Modify: `engine/util.c` (receive `rel_path_safe` from index.c)
- Modify: `engine/index.c` (remove the now-shared static `rel_path_safe`)
- Modify: `engine/meson.build` (add `cache.c`, zlib dep)
- Test: `engine/test_index.c`

- [ ] **Step 1: Move `rel_path_safe` from index.c to util.c**

Cut the entire static function `rel_path_safe` (engine/index.c, the block starting with the comment `/* Reject rel_paths that are empty ... */` through its closing brace) and paste it into `engine/util.c` (bottom of file), dropping `static`:

```c
/* Reject rel_paths that are empty (the snapshot root), absolute, contain a
   ".." path component, or contain control bytes — these are unsafe to build a
   real on-disk path from, or are the root entry the local scan also excludes. */
int rel_path_safe(const char *p)
{
    if (p[0] == '\0') return 0;       /* empty %P = the snapshot root itself */
    if (p[0] == '/')  return 0;       /* must be relative to the snapshot root */
    for (const char *c = p; *c; c++)
        if ((unsigned char)*c < 0x20) return 0;   /* control bytes (incl stray newline frags) */
    const char *s = p;
    while (s) {
        const char *slash = strchr(s, '/');
        size_t seg = slash ? (size_t)(slash - s) : strlen(s);
        if (seg == 2 && s[0] == '.' && s[1] == '.') return 0;  /* ".." component */
        s = slash ? slash + 1 : NULL;
    }
    return 1;
}
```

In `engine/engine_internal.h`, add under the "String helpers (util.c)" section:

```c
int  rel_path_safe(const char *p);
```

- [ ] **Step 2: Declare the cache API in `engine/engine_internal.h`**

Add after the "Whole-tree scan (index.c)" section:

```c
/* ── Per-snapshot scan cache (cache.c) ── */

/* Load a cached snapshot listing. Initializes *out itself. Returns 0 on a
   cache hit; -1 on any miss (absent, bad magic/version, truncation, zlib
   error, invalid record) with *out left empty-initialized. */
int  cache_read(const source_t *src, const snapshot_t *snap,
                file_entry_array_t *out);

/* Persist a snapshot listing atomically (tmp + rename). Returns 0/-1;
   failure is non-fatal for callers. */
int  cache_write(const source_t *src, const snapshot_t *snap,
                 const file_entry_array_t *a);

/* Delete cache files in this source's cache dir that don't belong to any
   snapshot in snaps[0..count-1] (stale .scan files, leftover .tmp files). */
void cache_housekeep(const source_t *src, const snapshot_t *snaps, int count);
```

- [ ] **Step 3: Write the failing tests**

Add to `engine/test_index.c` (after `build_fixture`; uses existing helpers). Also add `#include <stdlib.h>` if absent (for `setenv`) — check first; the file already includes engine_internal.h which pulls stdlib.

```c
/* ── Cache tests ── */

static source_t local_source(const char *dest)
{
    return rsyncx_make_source("test", 0 /* SOURCE_LOCAL */, dest, "", "", "");
}

static void test_cache_roundtrip(void)
{
    char tmpl[] = "/tmp/rsyncx_cache_XXXXXX";
    char *cache_dir = mkdtemp(tmpl);
    assert(cache_dir != NULL);
    setenv("RSYNCX_CACHE_DIR", cache_dir, 1);

    source_t src = local_source("/tmp/some_dest");
    snapshot_t snap = rsyncx_make_snapshot("2026-01-01_00-00", "/tmp/x", 1000);

    file_entry_array_t in;
    fe_array_init(&in);
    file_entry_t fe;
    memset(&fe, 0, sizeof fe);
    str_copy(fe.rel_path, sizeof fe.rel_path, "docs/readme.md");
    str_copy(fe.user, sizeof fe.user, "joel");
    str_copy(fe.group, sizeof fe.group, "staff");
    fe.inode = 42; fe.size = 1234; fe.mtime = 1700000000;
    fe.mode = 0100644; fe.nlink = 3; fe.is_dir = 0;
    assert(fe_array_push(&in, &fe) == 0);
    str_copy(fe.rel_path, sizeof fe.rel_path, "docs");
    fe.is_dir = 1; fe.size = 0;
    assert(fe_array_push(&in, &fe) == 0);

    assert(cache_write(&src, &snap, &in) == 0);

    file_entry_array_t out;
    assert(cache_read(&src, &snap, &out) == 0);
    assert(out.count == 2);
    assert(strcmp(out.data[0].rel_path, "docs/readme.md") == 0);
    assert(strcmp(out.data[0].user, "joel") == 0);
    assert(strcmp(out.data[0].group, "staff") == 0);
    assert(out.data[0].inode == 42 && out.data[0].size == 1234);
    assert(out.data[0].mtime == 1700000000 && out.data[0].mode == 0100644);
    assert(out.data[0].nlink == 3 && out.data[0].is_dir == 0);
    assert(out.data[1].is_dir == 1);

    fe_array_free(&in);
    fe_array_free(&out);
    printf("PASS: cache round-trip\n");
}

static void test_cache_robustness(void)
{
    char tmpl[] = "/tmp/rsyncx_cache_XXXXXX";
    char *cache_dir = mkdtemp(tmpl);
    assert(cache_dir != NULL);
    setenv("RSYNCX_CACHE_DIR", cache_dir, 1);

    source_t src = local_source("/tmp/other_dest");
    snapshot_t snap = rsyncx_make_snapshot("2026-01-02_00-00", "/tmp/x", 2000);
    file_entry_array_t out;

    /* absent file → miss */
    assert(cache_read(&src, &snap, &out) == -1);
    fe_array_free(&out);

    /* write a valid entry, then corrupt it in various ways */
    file_entry_array_t in;
    fe_array_init(&in);
    file_entry_t fe;
    memset(&fe, 0, sizeof fe);
    str_copy(fe.rel_path, sizeof fe.rel_path, "a.txt");
    assert(fe_array_push(&in, &fe) == 0);
    assert(cache_write(&src, &snap, &in) == 0);
    fe_array_free(&in);

    char path[1200];
    /* locate the .scan file (single file in the source subdir) */
    {
        char dir1[1100];
        snprintf(dir1, sizeof dir1, "%s", cache_dir);
        DIR *d1 = opendir(dir1);
        assert(d1);
        struct dirent *e1;
        char sub[1100] = "";
        while ((e1 = readdir(d1)) != NULL)
            if (e1->d_name[0] != '.') snprintf(sub, sizeof sub, "%s/%s", dir1, e1->d_name);
        closedir(d1);
        assert(sub[0]);
        snprintf(path, sizeof path, "%s/%s.scan", sub, "2026-01-02_00-00");
    }

    /* sanity: valid file is a hit */
    assert(cache_read(&src, &snap, &out) == 0);
    assert(out.count == 1);
    fe_array_free(&out);

    /* truncated → miss */
    truncate(path, 8);
    assert(cache_read(&src, &snap, &out) == -1);
    fe_array_free(&out);

    /* bad magic → miss */
    {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        assert(fd >= 0);
        assert(write(fd, "NOPE", 4) == 4);
        close(fd);
    }
    assert(cache_read(&src, &snap, &out) == -1);
    fe_array_free(&out);

    printf("PASS: cache robustness\n");
}
```

Wire both into `main()` in `engine/test_index.c` (add the two calls alongside the existing ones). Also add `#include <fcntl.h>` at the top of test_index.c if not already present (for `open`).

**IMPORTANT:** at the very top of `main()` in `engine/test_index.c`, before any test runs, add a default hermetic cache dir so later tasks' index builds never write to the real `~/Library/Caches`:

```c
    char cache_tmpl[] = "/tmp/rsyncx_cache_main_XXXXXX";
    assert(mkdtemp(cache_tmpl) != NULL);
    setenv("RSYNCX_CACHE_DIR", cache_tmpl, 1);
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `ninja -C build 2>&1 | tail -3`
Expected: FAIL to link/compile — `cache_read`/`cache_write` undefined.

- [ ] **Step 5: Implement `engine/cache.c`**

```c
/**
 * @file cache.c
 * @brief Per-snapshot scan cache: persists file_entry_t listings to disk.
 *
 * rsync --link-dest snapshots are immutable once written, so a snapshot's
 * listing is scanned at most once and then served from this cache forever.
 * Format: zlib (gzFile) stream — magic "RXSC", u32 version, u64 count, then
 * per record: u16 path_len + bytes, u8 user_len + bytes, u8 group_len +
 * bytes, u64 inode, u64 size, i64 mtime, u32 mode, u32 nlink, u8 is_dir.
 * Native endianness: the cache is machine-local, not a portable format.
 */

#include "engine_internal.h"
#include <zlib.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>

#define CACHE_MAGIC   "RXSC"
#define CACHE_VERSION 1u

static int cache_root(char *out, size_t out_size)
{
    const char *env = getenv("RSYNCX_CACHE_DIR");
    if (env && env[0]) { str_copy(out, out_size, env); return 0; }
    const char *home = getenv("HOME");
    if (!home || !home[0]) return -1;
    int n = snprintf(out, out_size, "%s/Library/Caches/rsync-explorer", home);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

static void sanitize(const char *in, char *out, size_t out_size)
{
    size_t i = 0;
    for (; in[i] && i + 1 < out_size; i++) {
        unsigned char c = (unsigned char)in[i];
        out[i] = (isalnum(c) || c == '-' || c == '.') ? (char)c : '_';
    }
    out[i] = '\0';
}

static int cache_source_dir(const source_t *src, char *out, size_t out_size)
{
    char root[768], host[128], dest[512];
    if (cache_root(root, sizeof root) != 0) return -1;
    sanitize(src->host[0] ? src->host : "local", host, sizeof host);
    sanitize(src->dest, dest, sizeof dest);
    int n = snprintf(out, out_size, "%s/%s_%s", root, host, dest);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

static int mkdir_ok(const char *path)
{
    return (mkdir(path, 0755) == 0 || errno == EEXIST) ? 0 : -1;
}

static int cache_mkdirs(const source_t *src, char *dir, size_t dir_size)
{
    char root[768];
    if (cache_root(root, sizeof root) != 0) return -1;
    if (mkdir_ok(root) != 0) return -1;
    if (cache_source_dir(src, dir, dir_size) != 0) return -1;
    return mkdir_ok(dir);
}

static int cache_file_path(const source_t *src, const snapshot_t *snap,
                           char *out, size_t out_size)
{
    char dir[1024];
    if (cache_source_dir(src, dir, sizeof dir) != 0) return -1;
    int n = snprintf(out, out_size, "%s/%s.scan", dir, snap->name);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

int cache_write(const source_t *src, const snapshot_t *snap,
                const file_entry_array_t *a)
{
    char dir[1024], path[1200], tmp[1240];
    if (cache_mkdirs(src, dir, sizeof dir) != 0) return -1;
    if (cache_file_path(src, snap, path, sizeof path) != 0) return -1;
    int n = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (n <= 0 || (size_t)n >= sizeof tmp) return -1;

    gzFile gz = gzopen(tmp, "wb6");
    if (!gz) return -1;

    uint32_t version = CACHE_VERSION;
    uint64_t count = (uint64_t)a->count;
    int ok = gzwrite(gz, CACHE_MAGIC, 4) == 4 &&
             gzwrite(gz, &version, sizeof version) == (int)sizeof version &&
             gzwrite(gz, &count, sizeof count) == (int)sizeof count;

    for (int i = 0; ok && i < a->count; i++) {
        const file_entry_t *fe = &a->data[i];
        uint16_t plen = (uint16_t)strlen(fe->rel_path);
        uint8_t  ulen = (uint8_t)strlen(fe->user);
        uint8_t  glen = (uint8_t)strlen(fe->group);
        ok = gzwrite(gz, &plen, 2) == 2 &&
             gzwrite(gz, fe->rel_path, plen) == (int)plen &&
             gzwrite(gz, &ulen, 1) == 1 &&
             (ulen == 0 || gzwrite(gz, fe->user, ulen) == (int)ulen) &&
             gzwrite(gz, &glen, 1) == 1 &&
             (glen == 0 || gzwrite(gz, fe->group, glen) == (int)glen) &&
             gzwrite(gz, &fe->inode, 8) == 8 &&
             gzwrite(gz, &fe->size, 8) == 8 &&
             gzwrite(gz, &fe->mtime, 8) == 8 &&
             gzwrite(gz, &fe->mode, 4) == 4 &&
             gzwrite(gz, &fe->nlink, 4) == 4 &&
             gzwrite(gz, &fe->is_dir, 1) == 1;
    }

    if (gzclose(gz) != Z_OK) ok = 0;
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int gzread_exact(gzFile gz, void *buf, unsigned len)
{
    return gzread(gz, buf, len) == (int)len ? 0 : -1;
}

int cache_read(const source_t *src, const snapshot_t *snap,
               file_entry_array_t *out)
{
    if (fe_array_init(out) != 0) return -1;

    char path[1200];
    if (cache_file_path(src, snap, path, sizeof path) != 0) return -1;

    gzFile gz = gzopen(path, "rb");
    if (!gz) return -1;

    char magic[4];
    uint32_t version = 0;
    uint64_t count = 0;
    if (gzread_exact(gz, magic, 4) != 0 || memcmp(magic, CACHE_MAGIC, 4) != 0 ||
        gzread_exact(gz, &version, sizeof version) != 0 || version != CACHE_VERSION ||
        gzread_exact(gz, &count, sizeof count) != 0 || count > (uint64_t)1 << 31)
        goto fail;

    for (uint64_t i = 0; i < count; i++) {
        file_entry_t fe;
        memset(&fe, 0, sizeof fe);
        uint16_t plen; uint8_t ulen, glen;
        if (gzread_exact(gz, &plen, 2) != 0 || plen == 0 ||
            plen >= sizeof fe.rel_path) goto fail;
        if (gzread_exact(gz, fe.rel_path, plen) != 0) goto fail;
        if (gzread_exact(gz, &ulen, 1) != 0 || ulen >= sizeof fe.user) goto fail;
        if (ulen && gzread_exact(gz, fe.user, ulen) != 0) goto fail;
        if (gzread_exact(gz, &glen, 1) != 0 || glen >= sizeof fe.group) goto fail;
        if (glen && gzread_exact(gz, fe.group, glen) != 0) goto fail;
        if (gzread_exact(gz, &fe.inode, 8) != 0 ||
            gzread_exact(gz, &fe.size, 8) != 0 ||
            gzread_exact(gz, &fe.mtime, 8) != 0 ||
            gzread_exact(gz, &fe.mode, 4) != 0 ||
            gzread_exact(gz, &fe.nlink, 4) != 0 ||
            gzread_exact(gz, &fe.is_dir, 1) != 0) goto fail;
        if (!rel_path_safe(fe.rel_path)) goto fail;
        if (fe_array_push(out, &fe) != 0) goto fail;
    }

    /* must be exactly at EOF */
    { char extra; if (gzread(gz, &extra, 1) != 0) goto fail; }
    gzclose(gz);
    return 0;

fail:
    gzclose(gz);
    fe_array_free(out);
    fe_array_init(out);
    return -1;
}

void cache_housekeep(const source_t *src, const snapshot_t *snaps, int count)
{
    char dir[1024];
    if (cache_source_dir(src, dir, sizeof dir) != 0) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        const char *dot = strrchr(e->d_name, '.');
        int live = 0;
        if (dot && strcmp(dot, ".scan") == 0) {
            size_t stem = (size_t)(dot - e->d_name);
            for (int i = 0; i < count; i++) {
                if (strlen(snaps[i].name) == stem &&
                    strncmp(e->d_name, snaps[i].name, stem) == 0) { live = 1; break; }
            }
        }
        if (!live) {
            char p[1300];
            int n = snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
            if (n > 0 && (size_t)n < sizeof p) unlink(p);
        }
    }
    closedir(d);
}
```

Also remove the (now duplicate) static `rel_path_safe` definition from `engine/index.c` (the declaration in engine_internal.h covers it).

- [ ] **Step 6: Add cache.c + zlib to `engine/meson.build`**

```meson
threads_dep = dependency('threads')
zlib_dep = dependency('zlib')
```

Add `'cache.c',` to `engine_sources` (after `'util.c',`). Add `zlib_dep` to both the `static_library` and the test `executable` dependencies:

```meson
libengine = static_library('engine', engine_sources,
  c_args: ['-fvisibility=hidden'],
  dependencies: [threads_dep, zlib_dep],
)
```

and in the foreach:

```meson
    dependencies: [threads_dep, zlib_dep],
```

- [ ] **Step 7: Build and run the tests**

Run: `ninja -C build && meson test -C build --print-errorlogs`
Expected: zero warnings; `Ok: 3 Fail: 0`; the index test log shows `PASS: cache round-trip` and `PASS: cache robustness`.

- [ ] **Step 8: Commit**

```bash
git add engine/cache.c engine/engine_internal.h engine/util.c engine/index.c engine/meson.build engine/test_index.c
git commit -m "feat: per-snapshot scan cache (zlib, atomic, validated reads)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Range filter — `rsyncx_index_set_range`

**Files:**
- Modify: `engine/engine.h` (new public function)
- Modify: `engine/index.c` (changed bitmap, split finalize, set_range, query filtering)
- Test: `engine/test_index.c`

**Semantics being implemented (from the spec):** the build always indexes the full snapshot list (newest 128 if more, with `snap_base` offset; all public indices stay in the caller's array space) and applies `[from_idx, to_idx]` as the initial filter. `set_range` reclassifies in memory. A node is MODIFIED in a range iff its inode changed at some present snapshot *strictly after* its first present snapshot within the range.

- [ ] **Step 1: Write the failing test**

Add to `engine/test_index.c`. The fixture builds 3 snapshots with hard links (stable metadata):

```c
/* 3-snapshot fixture:
   alpha.txt : s0, s1, s2 hard-linked            → UNCHANGED in any range containing it
   beta.txt  : s2 only                           → NEW in [0,2]; absent in [0,1]
   gamma.txt : s0 only                           → DELETED in [0,2] and [0,1]; absent in [1,2]
   delta.txt : s0 and s2, DIFFERENT inodes       → DEL_NEW in [0,2]; DELETED in [0,1]; NEW in [1,2]
   mu.txt    : s0; rewritten in s1; s1≡s2 linked → MODIFIED in [0,2] and [0,1]; UNCHANGED in [1,2]
*/
static void build_fixture3(char *base_out, size_t base_sz, snapshot_t snaps_out[3])
{
    char tmpl[] = "/tmp/rsyncx_idx3_XXXXXX";
    char *base = mkdtemp(tmpl);
    assert(base != NULL);
    str_copy(base_out, base_sz, base);

    char s[3][1100];
    const char *names[3] = { "2026-01-01_00-00", "2026-01-02_00-00", "2026-01-03_00-00" };
    for (int i = 0; i < 3; i++) {
        snprintf(s[i], sizeof s[i], "%s/%s", base, names[i]);
        assert(mkdir(s[i], 0755) == 0);
        snaps_out[i] = rsyncx_make_snapshot(names[i], s[i], 1000 + i);
    }

    char p[1200], q[1200];

    /* alpha: all three, hard-linked */
    snprintf(p, sizeof p, "%s/alpha.txt", s[0]); write_file(p, "alpha");
    snprintf(q, sizeof q, "%s/alpha.txt", s[1]); assert(link(p, q) == 0);
    snprintf(q, sizeof q, "%s/alpha.txt", s[2]); assert(link(p, q) == 0);

    /* beta: s2 only */
    snprintf(p, sizeof p, "%s/beta.txt", s[2]); write_file(p, "beta");

    /* gamma: s0 only */
    snprintf(p, sizeof p, "%s/gamma.txt", s[0]); write_file(p, "gamma");

    /* delta: s0 and s2, different inodes */
    snprintf(p, sizeof p, "%s/delta.txt", s[0]); write_file(p, "delta-v1");
    snprintf(p, sizeof p, "%s/delta.txt", s[2]); write_file(p, "delta-v2");

    /* mu: s0; new inode in s1; s2 hard-links s1 */
    snprintf(p, sizeof p, "%s/mu.txt", s[0]); write_file(p, "mu-v1");
    snprintf(p, sizeof p, "%s/mu.txt", s[1]); write_file(p, "mu-v2");
    snprintf(q, sizeof q, "%s/mu.txt", s[2]); assert(link(p, q) == 0);
}

static void expect_class(lifecycle_t *arr, int n, const char *leaf,
                         file_class_t cls)
{
    lifecycle_t *lc = find_lc(arr, n, leaf);
    assert(lc != NULL);
    assert(lc->class == cls);
}

static void test_set_range(void)
{
    char base[1100];
    snapshot_t snaps[3];
    build_fixture3(base, sizeof base, snaps);
    source_t src = rsyncx_make_source("t3", 0, base, "", "", "");

    rsyncx_index_t *idx = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
    assert(idx != NULL);

    lifecycle_t *out = NULL; int n = 0;

    /* full range [0,2] */
    assert(rsyncx_index_children(idx, "", &out, &n) == 0);
    assert(n == 5);
    expect_class(out, n, "alpha.txt", CLASS_UNCHANGED);
    expect_class(out, n, "beta.txt",  CLASS_NEW);
    expect_class(out, n, "gamma.txt", CLASS_DELETED);
    expect_class(out, n, "delta.txt", CLASS_DEL_NEW);
    expect_class(out, n, "mu.txt",    CLASS_MODIFIED);
    /* gamma deleted_in = epoch of s1 */
    assert(find_lc(out, n, "gamma.txt")->deleted_in == 1001);
    rsyncx_free(out);

    /* sub-range [0,1] */
    assert(rsyncx_index_set_range(idx, 0, 1) == 0);
    assert(rsyncx_index_children(idx, "", &out, &n) == 0);
    assert(n == 4);   /* beta (s2-only) is filtered out */
    assert(find_lc(out, n, "beta.txt") == NULL);
    expect_class(out, n, "alpha.txt", CLASS_UNCHANGED);
    expect_class(out, n, "gamma.txt", CLASS_DELETED);
    expect_class(out, n, "delta.txt", CLASS_DELETED);   /* present only s0 in this range */
    expect_class(out, n, "mu.txt",    CLASS_MODIFIED);  /* inode changed at s1 */
    rsyncx_free(out);

    /* sub-range [1,2] */
    assert(rsyncx_index_set_range(idx, 1, 2) == 0);
    assert(rsyncx_index_children(idx, "", &out, &n) == 0);
    assert(n == 4);   /* gamma (s0-only) is filtered out */
    assert(find_lc(out, n, "gamma.txt") == NULL);
    expect_class(out, n, "alpha.txt", CLASS_UNCHANGED);
    expect_class(out, n, "beta.txt",  CLASS_NEW);
    expect_class(out, n, "delta.txt", CLASS_NEW);       /* appears at range end */
    expect_class(out, n, "mu.txt",    CLASS_UNCHANGED); /* change was AT range start, not after */
    rsyncx_free(out);

    /* search respects the range */
    assert(rsyncx_index_set_range(idx, 1, 2) == 0);
    assert(rsyncx_index_search(idx, "gamma", &out, &n) == 0);
    assert(n == 0);
    rsyncx_free(out);

    /* back to full range restores everything */
    assert(rsyncx_index_set_range(idx, 0, 2) == 0);
    assert(rsyncx_index_children(idx, "", &out, &n) == 0);
    assert(n == 5);
    rsyncx_free(out);

    rsyncx_index_free(idx);
    printf("PASS: set_range reclassification\n");
}
```

Wire `test_set_range()` into `main()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `ninja -C build 2>&1 | tail -3`
Expected: compile FAIL — `rsyncx_index_set_range` undeclared.

- [ ] **Step 3: Declare `rsyncx_index_set_range` in `engine/engine.h`**

After the `rsyncx_index_free` declaration:

```c
/**
 * Reclassify the index for snapshot range [from_idx, to_idx] (indices into
 * the ORIGINAL snapshot array passed to rsyncx_build_index). In-memory only:
 * no rescan. Nodes absent from the range become invisible to the index
 * queries. Returns 0, or -1 on invalid arguments.
 */
int rsyncx_index_set_range(rsyncx_index_t *idx, int from_idx, int to_idx);
```

- [ ] **Step 4: Implement in `engine/index.c`**

4a. In `idx_node_t`, replace

```c
    int      first_idx, last_idx;
    uint64_t present_lo, present_hi;  /* presence bitmap over <=128 snapshots */
    uint64_t first_inode;             /* inode in first present snapshot */
    uint8_t  modified;                /* inode changed across present snapshots */
```

with

```c
    int      first_idx, last_idx;     /* first/last present IN CURRENT RANGE (set_range) */
    uint64_t present_lo, present_hi;  /* presence bitmap over <=128 snapshots */
    uint64_t changed_lo, changed_hi;  /* inode differed from previous present snapshot */
    uint64_t last_seen_inode;         /* inode at the latest merged present snapshot */
    uint8_t  in_range;                /* visible in the current range (set_range) */
```

(`modified` is deleted; `merge_last_idx` below replaces merge's use of `last_idx`.) Add to the same struct, right after `in_range`:

```c
    int      merge_last_idx;          /* latest snapshot merged so far (build only) */
```

In `struct rsyncx_index` add:

```c
    int         snap_base;        /* offset of snaps[0] in the caller's array */
    int         range_from, range_to;  /* current range, ix-relative */
```

4b. In `idx_intern`, the initialization block becomes (note `merge_last_idx`):

```c
    nd->parent = nd->first_child = nd->next_sibling = IDX_NONE;
    nd->first_idx = -1; nd->last_idx = -1; nd->merge_last_idx = -1;
    nd->deleted_in = -1;
```

4c. Add bitmap helpers next to `present_set`/`present_get`:

```c
static void changed_set(idx_node_t *nd, int s)
{
    if (s < 64) nd->changed_lo |= (uint64_t)1 << s;
    else        nd->changed_hi |= (uint64_t)1 << (s - 64);
}

/* bits a..b within one 64-bit word; 0 if a > b. a,b in [0,63]. */
static uint64_t bit_run(int a, int b)
{
    if (a > b) return 0;
    uint64_t m = (b - a >= 63) ? ~UINT64_C(0) : ((UINT64_C(1) << (b - a + 1)) - 1);
    return m << a;
}

/* mask *lo/*hi down to bits [from, to] (0..127). */
static void mask_range(uint64_t *lo, uint64_t *hi, int from, int to)
{
    *lo &= (from <= 63) ? bit_run(from, to < 63 ? to : 63) : 0;
    *hi &= (to >= 64) ? bit_run(from >= 64 ? from - 64 : 0, to - 64) : 0;
}

static int bits_first(uint64_t lo, uint64_t hi)
{
    return lo ? __builtin_ctzll(lo) : 64 + __builtin_ctzll(hi);
}

static int bits_last(uint64_t lo, uint64_t hi)
{
    return hi ? 127 - __builtin_clzll(hi) : 63 - __builtin_clzll(lo);
}

/* presence (lo,hi) is exactly the solid run [first, last]? */
static int bits_contiguous(uint64_t lo, uint64_t hi, int first, int last)
{
    uint64_t elo = (first <= 63) ? bit_run(first, last < 63 ? last : 63) : 0;
    uint64_t ehi = (last >= 64) ? bit_run(first >= 64 ? first - 64 : 0, last - 64) : 0;
    return lo == elo && hi == ehi;
}
```

4d. Rewrite `merge_snapshot`'s per-entry body:

```c
        present_set(nd, s);
        if (nd->merge_last_idx >= 0 && !fe->is_dir && fe->inode != 0 &&
            nd->last_seen_inode != 0 && fe->inode != nd->last_seen_inode)
            changed_set(nd, s);
        if (fe->inode != 0) nd->last_seen_inode = fe->inode;

        /* Snapshots are merged in ascending index order (see rsyncx_build_index),
           so the highest s seen is the latest present snapshot — its metadata wins. */
        if (s >= nd->merge_last_idx) {
            nd->merge_last_idx = s;
            nd->mode = fe->mode; nd->size = fe->size; nd->mtime = fe->mtime;
            nd->nlink = fe->nlink; nd->is_dir = fe->is_dir;
            nd->user_id = intern_owner(ix, fe->user);
            nd->group_id = intern_owner(ix, fe->group);
        }
```

4e. Split `finalize`: keep ONLY the parent/child linking part and rename it `link_tree` (delete the whole classification block — the `had_absence` loop, `cls`, `del_at`, `nd->klass`, `nd->deleted_in` assignments):

```c
static void link_tree(rsyncx_index_t *ix)
{
    ix->root_child = IDX_NONE;
    for (int i = 0; i < ix->node_count; i++) {
        idx_node_t *nd = &ix->nodes[i];
        const char *full = ix->pool + nd->path_off;
        const char *slash = strrchr(full, '/');
        if (!slash) {
            nd->next_sibling = ix->root_child;
            ix->root_child = i;
            nd->parent = IDX_NONE;
        } else {
            char parent_path[512];
            size_t len = (size_t)(slash - full);
            if (len >= sizeof parent_path) len = sizeof parent_path - 1;
            memcpy(parent_path, full, len);
            parent_path[len] = '\0';
            int p = idx_find(ix, parent_path);
            nd->parent = p;
            if (p != IDX_NONE) {
                nd->next_sibling = ix->nodes[p].first_child;
                ix->nodes[p].first_child = i;
            } else {
                nd->next_sibling = ix->root_child;
                ix->root_child = i;
            }
        }
    }
}
```

4f. Add the new public function (classification semantics identical to the old finalize, expressed with bit ops):

```c
int rsyncx_index_set_range(rsyncx_index_t *ix, int from_idx, int to_idx)
{
    if (!ix) return -1;
    int from = from_idx - ix->snap_base;
    int to   = to_idx   - ix->snap_base;
    if (from < 0) from = 0;
    if (to >= ix->snap_count) to = ix->snap_count - 1;
    if (to < 0 || from > to) return -1;
    ix->range_from = from; ix->range_to = to;

    for (int i = 0; i < ix->node_count; i++) {
        idx_node_t *nd = &ix->nodes[i];

        uint64_t plo = nd->present_lo, phi = nd->present_hi;
        mask_range(&plo, &phi, from, to);
        if (plo == 0 && phi == 0) { nd->in_range = 0; continue; }
        nd->in_range = 1;

        int first = bits_first(plo, phi);
        int last  = bits_last(plo, phi);
        nd->first_idx = first;
        nd->last_idx  = last;

        file_class_t cls;
        if (!bits_contiguous(plo, phi, first, last)) {
            cls = CLASS_DEL_NEW;          /* gap: present, absent, present again */
        } else if (last < to) {
            cls = CLASS_DELETED;          /* absent at range end */
        } else if (first == to) {
            cls = CLASS_NEW;              /* first appeared at range end */
        } else {
            uint64_t clo = nd->changed_lo, chi = nd->changed_hi;
            mask_range(&clo, &chi, first + 1, to);   /* changes AFTER first-in-range */
            cls = (clo | chi) ? CLASS_MODIFIED : CLASS_UNCHANGED;
        }
        nd->klass = (uint8_t)cls;
        nd->deleted_in = (cls == CLASS_DELETED)
                         ? ix->snaps[last + 1].date_epoch : -1;
    }
    return 0;
}
```

4g. In `rsyncx_build_index`: replace the range/copy logic and the `finalize` call:

```c
    if (!src || !snaps || snap_count <= 0) return NULL;
    int base = (snap_count > 128) ? snap_count - 128 : 0;
    int range = snap_count - base;

    rsyncx_index_t *ix = calloc(1, sizeof(*ix));
    if (!ix) return NULL;
    ix->snap_base = base;
    ix->snap_count = range;
    ix->snaps = malloc((size_t)range * sizeof(snapshot_t));
    if (!ix->snaps) { free(ix); return NULL; }
    for (int i = 0; i < range; i++) ix->snaps[i] = snaps[base + i];
```

The scan loop stays serial in this task but iterates `i` over `0..range-1` scanning `ix->snaps[i].full_path` (no more `from_idx + i`). After the loop:

```c
    link_tree(ix);
    if (rsyncx_index_set_range(ix, from_idx, to_idx) != 0)
        (void)rsyncx_index_set_range(ix, base, base + range - 1);
    return ix;
```

4h. Query filtering — in `rsyncx_index_children`, `rsyncx_index_dirs`, and `rsyncx_index_search`, skip nodes with `!nd->in_range` in BOTH the counting and the emitting loop (children/dirs iterate siblings: `if (!ix->nodes[c].in_range) continue;`; search adds `if (!nd->in_range) continue;`). In `rsyncx_index_dirs`, replace `int last = ix->snap_count - 1;` with `int last = ix->range_to;`.

- [ ] **Step 5: Build and run the tests**

Run: `ninja -C build && meson test -C build --print-errorlogs`
Expected: zero warnings; `Ok: 3 Fail: 0`; log shows `PASS: set_range reclassification` plus all pre-existing PASS lines (the old 2-snapshot tests still pass — semantics for the full range are unchanged).

- [ ] **Step 6: Commit**

```bash
git add engine/engine.h engine/index.c engine/test_index.c
git commit -m "feat: instant range reclassification via rsyncx_index_set_range

The index now always covers all snapshots (newest 128 max); the
timeline range is applied as an in-memory classification pass over
presence/changed bitmaps instead of a rebuild.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Parallel build + cache integration + housekeeping

**Files:**
- Modify: `engine/index.c` (worker pool replaces the serial scan loop)
- Test: `engine/test_index.c`

- [ ] **Step 1: Write the failing tests**

Add to `engine/test_index.c`:

```c
/* Compare two children listings field-by-field (order-independent). */
static void assert_same_children(rsyncx_index_t *a, rsyncx_index_t *b)
{
    lifecycle_t *oa = NULL, *ob = NULL; int na = 0, nb = 0;
    assert(rsyncx_index_children(a, "", &oa, &na) == 0);
    assert(rsyncx_index_children(b, "", &ob, &nb) == 0);
    assert(na == nb);
    for (int i = 0; i < na; i++) {
        lifecycle_t *m = find_lc(ob, nb, oa[i].rel_path);
        assert(m != NULL);
        assert(m->class == oa[i].class);
        assert(m->deleted_in == oa[i].deleted_in);
        assert(m->first_backup == oa[i].first_backup);
        assert(m->last_backup == oa[i].last_backup);
    }
    rsyncx_free(oa);
    rsyncx_free(ob);
}

static void test_parallel_matches_serial(void)
{
    char base[1100];
    snapshot_t snaps[3];
    build_fixture3(base, sizeof base, snaps);
    source_t src = rsyncx_make_source("tp", 0, base, "", "", "");

    setenv("RSYNCX_INDEX_WORKERS", "1", 1);
    rsyncx_index_t *serial = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
    assert(serial != NULL);

    setenv("RSYNCX_INDEX_WORKERS", "6", 1);
    rsyncx_index_t *parallel = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
    assert(parallel != NULL);
    unsetenv("RSYNCX_INDEX_WORKERS");

    assert_same_children(serial, parallel);
    rsyncx_index_free(serial);
    rsyncx_index_free(parallel);
    printf("PASS: parallel build matches serial\n");
}

static void test_cache_serves_old_snapshots(void)
{
    char base[1100];
    snapshot_t snaps[3];
    build_fixture3(base, sizeof base, snaps);
    source_t src = rsyncx_make_source("tc", 0, base, "", "", "");

    /* fresh cache dir for a deterministic state */
    char tmpl[] = "/tmp/rsyncx_cache_XXXXXX";
    char *cache_dir = mkdtemp(tmpl);
    assert(cache_dir != NULL);
    setenv("RSYNCX_CACHE_DIR", cache_dir, 1);

    /* first build populates the cache for s0 and s1 (s2 is newest → never cached) */
    rsyncx_index_t *first = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
    assert(first != NULL);

    /* delete gamma.txt from the s0 directory ON DISK */
    char victim[1200];
    snprintf(victim, sizeof victim, "%s/gamma.txt", snaps[0].full_path);
    assert(unlink(victim) == 0);

    /* second build must still see gamma (served from cache, disk not re-read) */
    rsyncx_index_t *second = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
    assert(second != NULL);
    assert_same_children(first, second);

    lifecycle_t *out = NULL; int n = 0;
    assert(rsyncx_index_children(second, "", &out, &n) == 0);
    assert(find_lc(out, n, "gamma.txt") != NULL);
    rsyncx_free(out);

    /* and the newest snapshot must have NO cache file (always rescanned) */
    {
        DIR *d = opendir(cache_dir);
        assert(d);
        struct dirent *e;
        char sub[1100] = "";
        while ((e = readdir(d)) != NULL)
            if (e->d_name[0] != '.') snprintf(sub, sizeof sub, "%s/%s", cache_dir, e->d_name);
        closedir(d);
        assert(sub[0]);
        char f[1300];
        struct stat st;
        snprintf(f, sizeof f, "%s/%s.scan", sub, snaps[0].name);
        assert(stat(f, &st) == 0);   /* s0 cached */
        snprintf(f, sizeof f, "%s/%s.scan", sub, snaps[1].name);
        assert(stat(f, &st) == 0);   /* s1 cached */
        snprintf(f, sizeof f, "%s/%s.scan", sub, snaps[2].name);
        assert(stat(f, &st) != 0);   /* newest NOT cached */

        /* housekeeping: plant a stale file, rebuild, it must be gone */
        snprintf(f, sizeof f, "%s/2020-01-01_00-00.scan", sub);
        write_file(f, "stale");
        rsyncx_index_t *third = rsyncx_build_index(&src, snaps, 3, 0, 2, NULL, NULL);
        assert(third != NULL);
        assert(stat(f, &st) != 0);   /* stale entry removed */
        snprintf(f, sizeof f, "%s/%s.scan", sub, snaps[0].name);
        assert(stat(f, &st) == 0);   /* live entry survived */
        rsyncx_index_free(third);
    }

    rsyncx_index_free(first);
    rsyncx_index_free(second);
    printf("PASS: cache serves old snapshots + housekeeping\n");
}
```

Wire both into `main()`. NOTE: these tests depend on the hermetic `RSYNCX_CACHE_DIR` set at the top of `main()` (Task 1 Step 3) so earlier index tests don't pollute the real cache; `test_cache_serves_old_snapshots` then switches to its own fresh dir.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `ninja -C build && meson test -C build --print-errorlogs 2>&1 | tail -15`
Expected: the `index` suite FAILS — `test_cache_serves_old_snapshots` asserts on `assert_same_children` (gamma vanished because nothing reads the cache yet) or on the missing `.scan` files.
(`test_parallel_matches_serial` may pass trivially — the env var is read by code that doesn't exist yet, both builds are serial. That's fine; it becomes meaningful in Step 3.)

- [ ] **Step 3: Implement the worker pool in `engine/index.c`**

Add `#include <pthread.h>` at the top. Add above `rsyncx_build_index`:

```c
/* ── Parallel snapshot scanning ── */

typedef struct {
    const source_t   *src;
    const snapshot_t *snaps;        /* ix->snaps (base-adjusted) */
    int  range;
    int  next;                      /* next snapshot index to claim */
    int  stop;                      /* a scan failed — wind down */
    file_entry_array_t *results;    /* slot i: scan result for snapshot i */
    uint8_t *done;                  /* slot i: 1 = result ready */
    pthread_mutex_t mu;
    pthread_cond_t  cv;
} scan_pool_t;

static int scan_worker_count(int range)
{
    const char *env = getenv("RSYNCX_INDEX_WORKERS");
    int n = (env && env[0]) ? atoi(env) : 6;
    if (n < 1)  n = 1;
    if (n > 16) n = 16;
    return n < range ? n : range;
}

static void *scan_worker(void *arg)
{
    scan_pool_t *p = arg;
    for (;;) {
        pthread_mutex_lock(&p->mu);
        if (p->stop || p->next >= p->range) { pthread_mutex_unlock(&p->mu); return NULL; }
        int i = p->next++;
        pthread_mutex_unlock(&p->mu);

        /* The newest snapshot may have been mid-backup when last seen, so it
           is never served from (or written to) the cache. */
        int cacheable = (i < p->range - 1);

        file_entry_array_t a;
        int rc;
        if (cacheable && cache_read(p->src, &p->snaps[i], &a) == 0) {
            rc = 0;
        } else {
            /* cache_read left `a` empty-initialized on miss; on the
               non-cacheable path it was never touched. */
            if (!cacheable) fe_array_init(&a);
            rc = (p->src->type == SOURCE_REMOTE)
                   ? scan_tree_remote(p->src, p->snaps[i].full_path, &a)
                   : scan_tree_local(p->snaps[i].full_path, &a);
            if (rc == 0 && cacheable)
                (void)cache_write(p->src, &p->snaps[i], &a);  /* best effort */
        }

        pthread_mutex_lock(&p->mu);
        if (rc != 0) {
            p->stop = 1;
            fe_array_free(&a);
        } else {
            p->results[i] = a;
            p->done[i] = 1;
        }
        pthread_cond_broadcast(&p->cv);
        pthread_mutex_unlock(&p->mu);
        if (rc != 0) return NULL;
    }
}
```

Then replace the serial scan loop inside `rsyncx_build_index` (everything from `long files_so_far = 0;` through the end of the `for` loop) with:

```c
    scan_pool_t pool;
    memset(&pool, 0, sizeof pool);
    pool.src = src;
    pool.snaps = ix->snaps;
    pool.range = range;
    pool.results = calloc((size_t)range, sizeof(file_entry_array_t));
    pool.done    = calloc((size_t)range, 1);
    if (!pool.results || !pool.done) {
        free(pool.results); free(pool.done);
        rsyncx_index_free(ix); return NULL;
    }
    pthread_mutex_init(&pool.mu, NULL);
    pthread_cond_init(&pool.cv, NULL);

    int workers = scan_worker_count(range);
    pthread_t tid[16];
    int started = 0;
    for (int w = 0; w < workers; w++)
        if (pthread_create(&tid[w], NULL, scan_worker, &pool) == 0) started++;
        else break;

    /* Merge strictly in snapshot order: merge_snapshot/classification
       semantics depend on oldest→newest processing. */
    long files_so_far = 0;
    int failed = (started == 0);
    for (int i = 0; i < range && !failed; i++) {
        pthread_mutex_lock(&pool.mu);
        while (!pool.done[i] && !pool.stop)
            pthread_cond_wait(&pool.cv, &pool.mu);
        int ready = pool.done[i];
        pthread_mutex_unlock(&pool.mu);
        if (!ready) { failed = 1; break; }

        if (merge_snapshot(ix, i, &pool.results[i]) != 0) {
            pthread_mutex_lock(&pool.mu);
            pool.stop = 1;
            pthread_cond_broadcast(&pool.cv);
            pthread_mutex_unlock(&pool.mu);
            failed = 1;
        }
        files_so_far += pool.results[i].count;
        fe_array_free(&pool.results[i]);
        pool.done[i] = 2;   /* merged + freed (merger-only field past this point) */
        if (!failed && progress_cb) progress_cb(i + 1, range, files_so_far, ctx);
    }

    for (int w = 0; w < started; w++) pthread_join(tid[w], NULL);
    for (int i = 0; i < range; i++)
        if (pool.done[i] == 1) fe_array_free(&pool.results[i]);
    free(pool.results);
    free(pool.done);
    pthread_mutex_destroy(&pool.mu);
    pthread_cond_destroy(&pool.cv);
    if (failed) { rsyncx_index_free(ix); return NULL; }

    cache_housekeep(src, ix->snaps, range);
```

(then the existing `link_tree(ix);` + `rsyncx_index_set_range(...)` + `return ix;` from Task 2 follow).

NOTE: `pool.done[i] = 2` after merge happens outside the mutex — safe because once `done[i] == 1` no worker ever writes slot `i` again; only the merger reads it afterward (including the cleanup loop, which runs after all workers joined).

- [ ] **Step 4: Build and run the tests**

Run: `ninja -C build && meson test -C build --print-errorlogs`
Expected: zero warnings; `Ok: 3 Fail: 0`; log shows `PASS: parallel build matches serial` and `PASS: cache serves old snapshots + housekeeping` plus all previous PASS lines.

- [ ] **Step 5: Run the index test 5 times to shake out races**

Run: `for i in 1 2 3 4 5; do ./build/engine/test_index >/dev/null || echo "RUN $i FAILED"; done; echo done`
Expected: only `done` (no FAILED lines).

- [ ] **Step 6: Commit**

```bash
git add engine/index.c engine/test_index.c
git commit -m "feat: parallel snapshot scanning with scan-once cache integration

Index builds scan snapshots on a worker pool (cache-read or scan,
newest always rescanned), merge strictly in snapshot order, and
housekeep stale cache entries after success.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: App — instant timeline via setRange

**Files:**
- Modify: `app/EngineBridge.swift` (add `setRange`)
- Modify: `app/MainWindowController.swift` (timeline handlers stop rebuilding)

- [ ] **Step 1: Add the bridge wrapper**

In `app/EngineBridge.swift`, after `freeIndex`:

```swift
    @discardableResult
    static func setRange(_ idx: OpaquePointer, fromIdx: Int, toIdx: Int) -> Bool {
        return rsyncx_index_set_range(idx, Int32(fromIdx), Int32(toIdx)) == 0
    }
```

- [ ] **Step 2: Rewire the timeline handlers in `app/MainWindowController.swift`**

2a. Add next to `rebuildIndex()`:

```swift
    /// Apply the current fromIdx/toIdx to the live index — an in-memory
    /// reclassification, no rescan. Safe on the main thread (bitmap pass).
    private func applyRange() {
        guard let idx = index else { return }
        EngineBridge.setRange(idx, fromIdx: fromIdx, toIdx: toIdx)
        scanCurrentDir()
        expandCurrentTree()
    }
```

2b. Replace the body of `timelineRangeChanged(from:to:)`:

```swift
    func timelineRangeChanged(from: Int, to: Int) {
        fromIdx = from
        toIdx = to
        applyRange()
    }
```

2c. In `toggleTimeline(_:)`, replace the `rebuildIndex()` call with `applyRange()`:

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
            applyRange()
        }
    }
```

2d. In `rebuildIndex()`'s completion block, replace the two lines

```swift
                self.index = idx
                self.scanCurrentDir()
                self.expandCurrentTree()
```

with

```swift
                self.index = idx
                self.applyRange()
```

(`applyRange` re-applies the *current* `fromIdx/toIdx` — covering a drag that happened while the build was in flight — and then refreshes both views.)

- [ ] **Step 3: Build the app**

Run: `ninja -C build 2>&1 | tail -3`
Expected: swiftc compiles, zero warnings, bundle regenerated.

- [ ] **Step 4: Full from-scratch verification**

Run: `rm -rf build && meson setup build && ninja -C build && meson test -C build --print-errorlogs && ninja -C build`
Expected: setup OK; zero-warning build; `Ok: 3 Fail: 0`; second ninja `ninja: no work to do.`

- [ ] **Step 5: Commit**

```bash
git add app/EngineBridge.swift app/MainWindowController.swift
git commit -m "feat: instant timeline filtering via index setRange

Timeline drags and timeline hide now reclassify the in-memory index
instead of rebuilding it (which rescanned every snapshot over SSH).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Acceptance (matches spec §7)

Automated: `meson test -C build` → 3/3, including cache round-trip/robustness, set_range reclassification, parallel-matches-serial, cache-serves-old-snapshots + housekeeping.

Manual (user):
- First launch (empty cache): visibly faster than before (parallel scans); `~/Library/Caches/rsync-explorer/` populates.
- Second launch: index ready in seconds (only the newest snapshot is scanned).
- Timeline drag: file list/sidebar update instantly; no "Indexing…", no SSH traffic.
