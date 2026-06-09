# Backup Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the whole backup tree into a compact in-memory C-engine index once per source/range so folder navigation, the sidebar, and search become instant in-memory queries.

**Architecture:** A new `engine/index.c` module scans every snapshot recursively (local `fts` / parallel remote SSH `find`), merges entries by path with a hash map (present-bitmap + incremental modified flag), classifies each path, and stores one compact node per unique path with parent/child links. Query functions return per-directory `lifecycle_t[]` / `dir_entry_t[]` and whole-tree search results. Swift builds the index on source-select/range-change (with a progress indicator) and routes the file list, sidebar, and search through it.

**Tech Stack:** C11 (`fts`, `pthread`, SSH argv/execvp helpers from `ssh.c`), Swift/AppKit. Build via `./build.sh`; engine via `make -C engine`; engine tests via `make -C engine test`.

**Branch:** `feature/ui-lightening-search-perf` (continues the current branch).

---

## File Structure

**Engine (C):**
- `engine/index.c` — new module: data structures, hash map, whole-tree scan, merge/classify, node store, query functions. One clear responsibility: the in-memory index.
- `engine/engine.h` — append the public index API (`rsyncx_index_t` + 5 functions).
- `engine/Makefile` — add `index.c` to `SRCS`; add a `test_index` target to `test`.
- `engine/test_index.c` — new: builds a local nested hard-linked fixture and exercises build + all queries.

**App (Swift):**
- `app/EngineBridge.swift` — index wrappers + progress-callback bridging.
- `app/MainWindowController.swift` — build index on discover/range-change with progress; route scan/expand/search through the index; free on rebuild/close.

The existing `rsyncx_scan_dir` / `rsyncx_expand_tree` / `rsyncx_search` stay in the engine (no longer called by the UI).

---

## Task 1: Whole-tree local scan helper

Recursively list **all** entries (files **and** directories) of one snapshot with full snapshot-root-relative paths. (`search_local` exists but skips directories and filters by query; the index needs directories and no filter.)

**Files:**
- Create: `engine/index.c`
- Create: `engine/test_index.c`
- Modify: `engine/Makefile`
- Modify: `engine/engine.h` (forward-declare the opaque type so the test/header compile)

- [ ] **Step 1: Add the opaque type + Task-1 helper declaration to engine.h**

Append to `engine/engine.h` just before the final accessor declarations (anywhere in the public section is fine):
```c
/* ── In-memory backup index ── */

/** Opaque whole-backup index handle (see index.c). */
typedef struct rsyncx_index rsyncx_index_t;
```
Add to `engine/engine_internal.h` in the scan section (near `scan_dir_remote_parallel`):
```c
/* ── Whole-tree scan (index.c) ── */

/* Recursively list every entry (files AND directories) under a local snapshot
   directory, with rel_path = path relative to snapshot_root. Returns 0/-1. */
int scan_tree_local(const char *snapshot_root, file_entry_array_t *out);
```

- [ ] **Step 2: Write the failing test**

Create `engine/test_index.c`:
```c
/**
 * @file test_index.c
 * @brief Tests for the in-memory backup index against a local hard-linked fixture.
 */
#include "engine_internal.h"
#include <assert.h>
#include <fcntl.h>

static void write_file(const char *path, const char *content)
{
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) { (void)write(fd, content, strlen(content)); close(fd); }
}

/* Returns 1 if the array has an entry whose rel_path equals `p`. */
static int has_path(const file_entry_array_t *a, const char *p)
{
    for (int i = 0; i < a->count; i++)
        if (strcmp(a->data[i].rel_path, p) == 0) return 1;
    return 0;
}

static void test_scan_tree_local(void)
{
    char tmpl[] = "/tmp/rsyncx_idx_XXXXXX";
    char *base = mkdtemp(tmpl);
    assert(base != NULL);

    char dir[1024], p[1100];
    snprintf(dir, sizeof dir, "%s/docs", base);
    assert(mkdir(dir, 0755) == 0);
    snprintf(p, sizeof p, "%s/alpha.txt", base); write_file(p, "A");
    snprintf(p, sizeof p, "%s/docs/readme.md", base); write_file(p, "R");

    file_entry_array_t a;
    fe_array_init(&a);
    assert(scan_tree_local(base, &a) == 0);

    assert(has_path(&a, "alpha.txt"));
    assert(has_path(&a, "docs"));            /* directory included */
    assert(has_path(&a, "docs/readme.md"));  /* full nested rel_path */

    /* docs is a directory, alpha.txt is not */
    for (int i = 0; i < a.count; i++) {
        if (strcmp(a.data[i].rel_path, "docs") == 0) assert(a.data[i].is_dir == 1);
        if (strcmp(a.data[i].rel_path, "alpha.txt") == 0) assert(a.data[i].is_dir == 0);
    }

    fe_array_free(&a);
    char rm[1200]; snprintf(rm, sizeof rm, "rm -rf \"%s\"", base); (void)system(rm);
    printf("PASS: scan_tree_local lists files + dirs with full rel_paths\n");
}

int main(void)
{
    test_scan_tree_local();
    return 0;
}
```

- [ ] **Step 3: Create index.c with scan_tree_local**

Create `engine/index.c`:
```c
/**
 * @file index.c
 * @brief In-memory whole-backup index: build, classify, and query.
 */
#include "engine_internal.h"
#include <fts.h>

/* ── Whole-tree local scan (files AND directories, full rel_paths) ── */

int scan_tree_local(const char *snapshot_root, file_entry_array_t *out)
{
    char *paths[] = { (char *)snapshot_root, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return -1;

    size_t base_len = strlen(snapshot_root);

    FTSENT *ent;
    while ((ent = fts_read(fts)) != NULL) {
        /* Visit each directory once (pre-order) and every file; skip the
           snapshot root itself and unreadable entries. */
        if (ent->fts_info == FTS_DP) continue;                 /* dir post-order */
        if (ent->fts_info == FTS_DNR || ent->fts_info == FTS_ERR ||
            ent->fts_info == FTS_NS) continue;
        if (ent->fts_level == 0) continue;                     /* the root dir */

        const struct stat *st = ent->fts_statp;

        file_entry_t fe;
        memset(&fe, 0, sizeof(fe));

        const char *rel = ent->fts_path + base_len;
        while (*rel == '/') rel++;
        str_copy(fe.rel_path, sizeof(fe.rel_path), rel);

        fe.inode = (uint64_t)st->st_ino;
        fe.mode  = (uint32_t)st->st_mode;
        fe.size  = (uint64_t)st->st_size;
        fe.mtime = (int64_t)st->st_mtime;
        fe.nlink = (uint32_t)st->st_nlink;
        fe.is_dir = S_ISDIR(st->st_mode) ? 1 : 0;
        if (fe.is_dir) fe.size = 0;

        resolve_user(st->st_uid, fe.user, sizeof(fe.user));
        resolve_group(st->st_gid, fe.group, sizeof(fe.group));

        if (fe_array_push(out, &fe) != 0) { fts_close(fts); return -1; }
    }

    fts_close(fts);
    return 0;
}
```

- [ ] **Step 4: Wire index.c + test_index into the Makefile**

In `engine/Makefile`, add `index.c` to `SRCS`:
```make
SRCS    = config.c discover.c scan.c scan_macos.c scan_posix.c \
          scan_remote.c classify.c search.c tree.c ssh.c util.c index.c
```
Add a `test_index` target after the `test_ssh` target:
```make
test_index: test_index.c libengine.a engine.h engine_internal.h
	$(CC) $(CFLAGS) -I. test_index.c libengine.a -o test_index
	./test_index
```
Change the aggregate `test` target to include it:
```make
test: test_search test_ssh test_index
```
Add `test_index` to the `clean` rule's `rm -f` list.

- [ ] **Step 5: Build and run — verify pass**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine clean && make -C engine && make -C engine test
```
Expected: clean build under `-Werror`; three PASS lines including `PASS: scan_tree_local lists files + dirs with full rel_paths`; exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/index.c engine/test_index.c engine/Makefile engine/engine.h engine/engine_internal.h
git commit -m "feat(engine): whole-tree local scan helper for the index"
```

---

## Task 2: Index build + free + children query

Build the compact index from per-snapshot whole-tree scans (local sources), classify every path, and answer `rsyncx_index_children`.

**Files:**
- Modify: `engine/index.c`
- Modify: `engine/engine.h`
- Modify: `engine/test_index.c`

- [ ] **Step 1: Declare the public API in engine.h**

Append to `engine/engine.h` after the `rsyncx_index_t` typedef:
```c
/**
 * Build the in-memory index over snapshots [from_idx, to_idx].
 * One recursive scan per snapshot (local fts / parallel remote SSH).
 * progress_cb (nullable) is called as snapshots complete:
 *   progress_cb(done_snapshots, total_snapshots, files_so_far, ctx).
 * Returns an index handle (free with rsyncx_index_free), or NULL on error.
 */
rsyncx_index_t *rsyncx_build_index(const source_t *src,
                                   const snapshot_t *snaps, int snap_count,
                                   int from_idx, int to_idx,
                                   void (*progress_cb)(int, int, long, void *),
                                   void *ctx);

/** Free an index built by rsyncx_build_index. */
void rsyncx_index_free(rsyncx_index_t *idx);

/**
 * Children (files AND directories) of directory rel_path ("" = root).
 * Output lifecycle_t[] carry the LEAF name in rel_path. Caller frees via rsyncx_free.
 * Returns 0/-1.
 */
int rsyncx_index_children(const rsyncx_index_t *idx, const char *rel_path,
                          lifecycle_t **out, int *count);
```

- [ ] **Step 2: Write the failing test (extend test_index.c)**

Add to `engine/test_index.c` (a fixture builder + a children test, and call it from `main`):
```c
/* Build a 2-snapshot hard-linked fixture; returns the base temp dir.
   Layout:
     snap1: alpha.txt, gamma.txt, mod.txt(v1), docs/readme.md
     snap2: alpha.txt(hardlink), beta.txt, mod.txt(v2 distinct inode), docs/readme.md(hardlink)
   => alpha.txt UNCHANGED, gamma.txt DELETED, beta.txt NEW, mod.txt MODIFIED,
      docs UNCHANGED (dir), docs/readme.md UNCHANGED. */
static void build_fixture(char *base_out, size_t base_sz,
                          char *snap1_out, size_t s1_sz,
                          char *snap2_out, size_t s2_sz)
{
    char tmpl[] = "/tmp/rsyncx_idx2_XXXXXX";
    char *base = mkdtemp(tmpl);
    assert(base != NULL);
    str_copy(base_out, base_sz, base);

    char s1[1024], s2[1024], p[1100], q[1100];
    snprintf(s1, sizeof s1, "%s/snap1", base);
    snprintf(s2, sizeof s2, "%s/snap2", base);
    assert(mkdir(s1, 0755) == 0);
    assert(mkdir(s2, 0755) == 0);
    str_copy(snap1_out, s1_sz, s1);
    str_copy(snap2_out, s2_sz, s2);

    char d1[1100], d2[1100];
    snprintf(d1, sizeof d1, "%s/docs", s1); assert(mkdir(d1, 0755) == 0);
    snprintf(d2, sizeof d2, "%s/docs", s2); assert(mkdir(d2, 0755) == 0);

    /* alpha.txt: unchanged (hard-linked) */
    snprintf(p, sizeof p, "%s/alpha.txt", s1); write_file(p, "A");
    snprintf(q, sizeof q, "%s/alpha.txt", s2); assert(link(p, q) == 0);
    /* docs/readme.md: unchanged (hard-linked) */
    snprintf(p, sizeof p, "%s/docs/readme.md", s1); write_file(p, "R");
    snprintf(q, sizeof q, "%s/docs/readme.md", s2); assert(link(p, q) == 0);
    /* gamma.txt: deleted (snap1 only) */
    snprintf(p, sizeof p, "%s/gamma.txt", s1); write_file(p, "G");
    /* beta.txt: new (snap2 only) */
    snprintf(p, sizeof p, "%s/beta.txt", s2); write_file(p, "B");
    /* mod.txt: modified (both, distinct inodes) */
    snprintf(p, sizeof p, "%s/mod.txt", s1); write_file(p, "v1");
    snprintf(p, sizeof p, "%s/mod.txt", s2); write_file(p, "v2-different");
}

static lifecycle_t *find_lc(lifecycle_t *a, int n, const char *leaf)
{
    for (int i = 0; i < n; i++) if (strcmp(a[i].rel_path, leaf) == 0) return &a[i];
    return NULL;
}

static void test_index_children(void)
{
    char base[1024], s1[1024], s2[1024];
    build_fixture(base, sizeof base, s1, sizeof s1, s2, sizeof s2);

    source_t src = rsyncx_make_source("t", SOURCE_LOCAL, base, "", "", "");
    snapshot_t snaps[2] = {
        rsyncx_make_snapshot("snap1", s1, 1000),
        rsyncx_make_snapshot("snap2", s2, 2000),
    };

    rsyncx_index_t *idx = rsyncx_build_index(&src, snaps, 2, 0, 1, NULL, NULL);
    assert(idx != NULL);

    lifecycle_t *out = NULL; int n = 0;
    assert(rsyncx_index_children(idx, "", &out, &n) == 0);

    lifecycle_t *alpha = find_lc(out, n, "alpha.txt");
    lifecycle_t *gamma = find_lc(out, n, "gamma.txt");
    lifecycle_t *beta  = find_lc(out, n, "beta.txt");
    lifecycle_t *mod   = find_lc(out, n, "mod.txt");
    lifecycle_t *docs  = find_lc(out, n, "docs");
    assert(alpha && alpha->class == CLASS_UNCHANGED && alpha->is_dir == 0);
    assert(gamma && gamma->class == CLASS_DELETED);
    assert(beta  && beta->class  == CLASS_NEW);
    assert(mod   && mod->class   == CLASS_MODIFIED);
    assert(docs  && docs->is_dir == 1 && docs->class == CLASS_UNCHANGED);
    rsyncx_free(out);

    /* children of the subdirectory */
    assert(rsyncx_index_children(idx, "docs", &out, &n) == 0);
    lifecycle_t *readme = find_lc(out, n, "readme.md");
    assert(readme && readme->class == CLASS_UNCHANGED);
    rsyncx_free(out);

    rsyncx_index_free(idx);
    char rm[1200]; snprintf(rm, sizeof rm, "rm -rf \"%s\"", base); (void)system(rm);
    printf("PASS: index children + classification\n");
}
```
Add `test_index_children();` to `main` before `return 0;`.

- [ ] **Step 3: Implement the index structures, build, free, and children query**

Add to `engine/index.c` (after `scan_tree_local`):
```c
/* ── Compact node store + open-addressing path→node hash map ── */

#define IDX_NONE (-1)

typedef struct {
    uint32_t path_off;     /* offset of full rel_path in path_pool */
    uint32_t name_off;     /* offset of leaf name within path_pool */
    int32_t  parent;       /* node index or IDX_NONE */
    int32_t  first_child;  /* head of children list, or IDX_NONE */
    int32_t  next_sibling; /* next child of the same parent, or IDX_NONE */

    uint32_t mode;
    uint64_t size;
    int64_t  mtime;
    uint32_t nlink;
    int      user_id, group_id;

    int      first_idx, last_idx;
    uint64_t present_lo, present_hi;  /* presence bitmap over ≤128 snapshots */
    uint64_t first_inode;             /* inode in first present snapshot */
    uint8_t  modified;                /* inode changed across present snapshots */
    uint8_t  is_dir;
    uint8_t  klass;                   /* file_class_t, set in finalize */
    int64_t  deleted_in;              /* epoch or -1, set in finalize */
} idx_node_t;

struct rsyncx_index {
    char       *pool;       /* path string pool */
    size_t      pool_len, pool_cap;

    idx_node_t *nodes;
    int         node_count, node_cap;

    int32_t    *buckets;    /* node index + 1, 0 = empty */
    int         bucket_cap;

    int32_t     root_child; /* head of root-level children list */

    char      **owners;     /* interned user/group names */
    int         owner_count, owner_cap;

    int         snap_count;       /* range length */
    snapshot_t *snaps;            /* copy of snaps[from_idx..to_idx] */
};

static uint32_t fnv1a(const char *s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

static int pool_add(rsyncx_index_t *ix, const char *s, uint32_t *off)
{
    size_t len = strlen(s) + 1;
    if (ix->pool_len + len > ix->pool_cap) {
        size_t cap = ix->pool_cap ? ix->pool_cap * 2 : 1 << 20;
        while (cap < ix->pool_len + len) cap *= 2;
        char *p = realloc(ix->pool, cap);
        if (!p) return -1;
        ix->pool = p; ix->pool_cap = cap;
    }
    *off = (uint32_t)ix->pool_len;
    memcpy(ix->pool + ix->pool_len, s, len);
    ix->pool_len += len;
    return 0;
}

static int intern_owner(rsyncx_index_t *ix, const char *name)
{
    for (int i = 0; i < ix->owner_count; i++)
        if (strcmp(ix->owners[i], name) == 0) return i;
    if (ix->owner_count >= ix->owner_cap) {
        int cap = ix->owner_cap ? ix->owner_cap * 2 : 16;
        char **o = realloc(ix->owners, (size_t)cap * sizeof(char *));
        if (!o) return 0;
        ix->owners = o; ix->owner_cap = cap;
    }
    ix->owners[ix->owner_count] = strdup(name);
    return ix->owner_count++;
}

static void buckets_insert(rsyncx_index_t *ix, int node);

static int buckets_grow(rsyncx_index_t *ix)
{
    int newcap = ix->bucket_cap ? ix->bucket_cap * 2 : 1 << 16;
    int32_t *b = calloc((size_t)newcap, sizeof(int32_t));
    if (!b) return -1;
    int32_t *old = ix->buckets; int oldcap = ix->bucket_cap;
    ix->buckets = b; ix->bucket_cap = newcap;
    for (int i = 0; i < oldcap; i++)
        if (old[i]) buckets_insert(ix, old[i] - 1);
    free(old);
    return 0;
}

static void buckets_insert(rsyncx_index_t *ix, int node)
{
    uint32_t mask = (uint32_t)ix->bucket_cap - 1;
    uint32_t i = fnv1a(ix->pool + ix->nodes[node].path_off) & mask;
    while (ix->buckets[i]) i = (i + 1) & mask;
    ix->buckets[i] = node + 1;
}

/* Find node index for `path`, or IDX_NONE. */
static int idx_find(const rsyncx_index_t *ix, const char *path)
{
    if (ix->bucket_cap == 0) return IDX_NONE;
    uint32_t mask = (uint32_t)ix->bucket_cap - 1;
    uint32_t i = fnv1a(path) & mask;
    while (ix->buckets[i]) {
        int node = ix->buckets[i] - 1;
        if (strcmp(ix->pool + ix->nodes[node].path_off, path) == 0) return node;
        i = (i + 1) & mask;
    }
    return IDX_NONE;
}

/* Get or create the node for `path`; returns node index or IDX_NONE on OOM. */
static int idx_intern(rsyncx_index_t *ix, const char *path)
{
    int existing = idx_find(ix, path);
    if (existing != IDX_NONE) return existing;

    if (ix->node_count + 1 > (ix->bucket_cap * 3) / 4)
        if (buckets_grow(ix) != 0) return IDX_NONE;

    if (ix->node_count >= ix->node_cap) {
        int cap = ix->node_cap ? ix->node_cap * 2 : 1 << 16;
        idx_node_t *n = realloc(ix->nodes, (size_t)cap * sizeof(idx_node_t));
        if (!n) return IDX_NONE;
        ix->nodes = n; ix->node_cap = cap;
    }

    int node = ix->node_count++;
    idx_node_t *nd = &ix->nodes[node];
    memset(nd, 0, sizeof(*nd));
    nd->parent = nd->first_child = nd->next_sibling = IDX_NONE;
    nd->first_idx = -1; nd->last_idx = -1;
    nd->deleted_in = -1;
    if (pool_add(ix, path, &nd->path_off) != 0) { ix->node_count--; return IDX_NONE; }
    /* leaf name offset = after the last '/' */
    const char *full = ix->pool + nd->path_off;
    const char *slash = strrchr(full, '/');
    nd->name_off = nd->path_off + (uint32_t)(slash ? (slash - full + 1) : 0);

    buckets_insert(ix, node);
    return node;
}

static void present_set(idx_node_t *nd, int s)
{
    if (s < 64) nd->present_lo |= (uint64_t)1 << s;
    else        nd->present_hi |= (uint64_t)1 << (s - 64);
}
static int present_get(const idx_node_t *nd, int s)
{
    return s < 64 ? (int)((nd->present_lo >> s) & 1)
                  : (int)((nd->present_hi >> (s - 64)) & 1);
}

/* Merge one snapshot's entries (snapshot index s within the range). */
static int merge_snapshot(rsyncx_index_t *ix, int s, const file_entry_array_t *a)
{
    for (int e = 0; e < a->count; e++) {
        const file_entry_t *fe = &a->data[e];
        int node = idx_intern(ix, fe->rel_path);
        if (node == IDX_NONE) return -1;
        idx_node_t *nd = &ix->nodes[node];

        present_set(nd, s);
        if (nd->first_idx < 0) { nd->first_idx = s; nd->first_inode = fe->inode; }
        else if (fe->inode != 0 && nd->first_inode != 0 &&
                 fe->inode != nd->first_inode) nd->modified = 1;

        if (s >= nd->last_idx) {
            nd->last_idx = s;
            nd->mode = fe->mode; nd->size = fe->size; nd->mtime = fe->mtime;
            nd->nlink = fe->nlink; nd->is_dir = fe->is_dir;
            nd->user_id = intern_owner(ix, fe->user);
            nd->group_id = intern_owner(ix, fe->group);
        }
    }
    return 0;
}

/* Classify every node and link children to parents. */
static void finalize(rsyncx_index_t *ix)
{
    int sc = ix->snap_count;
    ix->root_child = IDX_NONE;

    for (int i = 0; i < ix->node_count; i++) {
        idx_node_t *nd = &ix->nodes[i];

        /* classification (mirrors classify_merge_entry) */
        int had_absence = 0, last_present = -1;
        file_class_t cls = CLASS_UNCHANGED;
        int del_at = -1, decided = 0;
        for (int s = 0; s < sc; s++) {
            if (present_get(nd, s)) {
                if (had_absence && last_present >= 0) { cls = CLASS_DEL_NEW; decided = 1; break; }
                last_present = s;
            } else if (last_present >= 0) had_absence = 1;
        }
        if (!decided) {
            if (!present_get(nd, sc - 1)) {
                if (nd->last_idx + 1 < sc) del_at = nd->last_idx + 1;
                cls = CLASS_DELETED;
            } else if (nd->first_idx == sc - 1) {
                cls = CLASS_NEW;
            } else if (nd->modified) {
                cls = CLASS_MODIFIED;
            } else {
                cls = CLASS_UNCHANGED;
            }
        }
        nd->klass = (uint8_t)cls;
        nd->deleted_in = (del_at >= 0) ? ix->snaps[del_at].date_epoch : -1;

        /* link to parent (dirname lookup) */
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
                /* orphan (parent dir absent in scans) — attach to root */
                nd->next_sibling = ix->root_child;
                ix->root_child = i;
            }
        }
    }
}

rsyncx_index_t *rsyncx_build_index(const source_t *src,
                                   const snapshot_t *snaps, int snap_count,
                                   int from_idx, int to_idx,
                                   void (*progress_cb)(int, int, long, void *),
                                   void *ctx)
{
    if (!src || !snaps) return NULL;
    if (from_idx < 0) from_idx = 0;
    if (to_idx >= snap_count) to_idx = snap_count - 1;
    if (from_idx > to_idx) return NULL;
    int range = to_idx - from_idx + 1;
    if (range > 128) return NULL;

    rsyncx_index_t *ix = calloc(1, sizeof(*ix));
    if (!ix) return NULL;
    ix->snap_count = range;
    ix->snaps = malloc((size_t)range * sizeof(snapshot_t));
    if (!ix->snaps) { free(ix); return NULL; }
    for (int i = 0; i < range; i++) ix->snaps[i] = snaps[from_idx + i];

    long files_so_far = 0;
    for (int i = 0; i < range; i++) {
        file_entry_array_t a;
        fe_array_init(&a);

        int rc;
        if (src->type == SOURCE_REMOTE) {
            rc = scan_tree_remote(src, snaps[from_idx + i].full_path, &a);
        } else {
            rc = scan_tree_local(snaps[from_idx + i].full_path, &a);
        }
        if (rc == 0) {
            if (merge_snapshot(ix, i, &a) != 0) { fe_array_free(&a); rsyncx_index_free(ix); return NULL; }
            files_so_far += a.count;
        }
        fe_array_free(&a);
        if (progress_cb) progress_cb(i + 1, range, files_so_far, ctx);
    }

    finalize(ix);
    return ix;
}

void rsyncx_index_free(rsyncx_index_t *ix)
{
    if (!ix) return;
    free(ix->pool);
    free(ix->nodes);
    free(ix->buckets);
    free(ix->snaps);
    for (int i = 0; i < ix->owner_count; i++) free(ix->owners[i]);
    free(ix->owners);
    free(ix);
}

/* Materialize a lifecycle_t from a node. use_full_path: rel_path is the full
   path (search) vs the leaf name (children). */
static void node_to_lifecycle(const rsyncx_index_t *ix, int node,
                              int use_full_path, lifecycle_t *lc)
{
    const idx_node_t *nd = &ix->nodes[node];
    memset(lc, 0, sizeof(*lc));
    const char *full = ix->pool + nd->path_off;
    str_copy(lc->rel_path, sizeof(lc->rel_path),
             use_full_path ? full : ix->pool + nd->name_off);
    lc->class = (file_class_t)nd->klass;
    lc->mode = nd->mode; lc->size = nd->size; lc->mtime = nd->mtime;
    lc->nlink = nd->nlink; lc->is_dir = nd->is_dir;
    if (nd->user_id < ix->owner_count)  str_copy(lc->user,  sizeof(lc->user),  ix->owners[nd->user_id]);
    if (nd->group_id < ix->owner_count) str_copy(lc->group, sizeof(lc->group), ix->owners[nd->group_id]);
    lc->first_backup = ix->snaps[nd->first_idx].date_epoch;
    lc->last_backup  = ix->snaps[nd->last_idx].date_epoch;
    lc->deleted_in   = nd->deleted_in;
    snprintf(lc->last_real_path, sizeof(lc->last_real_path), "%s/%s",
             ix->snaps[nd->last_idx].full_path, full);
}

int rsyncx_index_children(const rsyncx_index_t *ix, const char *rel_path,
                          lifecycle_t **out, int *count)
{
    if (!ix || !out || !count) return -1;
    int head;
    if (rel_path[0] == '\0' || strcmp(rel_path, "/") == 0) {
        head = ix->root_child;
    } else {
        int dir = idx_find(ix, rel_path);
        head = (dir == IDX_NONE) ? IDX_NONE : ix->nodes[dir].first_child;
    }

    int n = 0;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) n++;
    lifecycle_t *arr = (n > 0) ? malloc((size_t)n * sizeof(lifecycle_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int i = 0;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling)
        node_to_lifecycle(ix, c, 0, &arr[i++]);

    *out = arr; *count = n;
    return 0;
}
```
Also add the remote scan declaration near the top of `index.c` (implemented in Task 4; declared now so the build references resolve — provide a temporary stub so Task 2 links):
```c
/* Implemented in Task 4. Stub returns -1 (no remote entries) until then. */
static int scan_tree_remote(const source_t *src, const char *root,
                            file_entry_array_t *out)
{
    (void)src; (void)root; (void)out;
    return -1;
}
```

- [ ] **Step 4: Build and run — verify pass**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine clean && make -C engine && make -C engine test
```
Expected: clean build under `-Werror`; `PASS: index children + classification` printed; exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/index.c engine/engine.h engine/test_index.c
git commit -m "feat(engine): build/classify in-memory index + children query (local)"
```

---

## Task 3: Sidebar dirs query + whole-tree search

**Files:**
- Modify: `engine/index.c`, `engine/engine.h`, `engine/test_index.c`

- [ ] **Step 1: Declare the two queries in engine.h**

Append after `rsyncx_index_children`:
```c
/** Child directories of rel_path (for the sidebar). Caller frees via rsyncx_free. */
int rsyncx_index_dirs(const rsyncx_index_t *idx, const char *rel_path,
                      dir_entry_t **out, int *count);

/** Substring filename search across the whole tree, files only.
    Output lifecycle_t[] carry the FULL rel_path. Caller frees via rsyncx_free. */
int rsyncx_index_search(const rsyncx_index_t *idx, const char *query,
                        lifecycle_t **out, int *count);
```

- [ ] **Step 2: Write the failing test (extend test_index.c)**

Add to `engine/test_index.c` and call from `main`:
```c
static void test_index_dirs_and_search(void)
{
    char base[1024], s1[1024], s2[1024];
    build_fixture(base, sizeof base, s1, sizeof s1, s2, sizeof s2);
    source_t src = rsyncx_make_source("t", SOURCE_LOCAL, base, "", "", "");
    snapshot_t snaps[2] = {
        rsyncx_make_snapshot("snap1", s1, 1000),
        rsyncx_make_snapshot("snap2", s2, 2000),
    };
    rsyncx_index_t *idx = rsyncx_build_index(&src, snaps, 2, 0, 1, NULL, NULL);
    assert(idx != NULL);

    /* dirs of root → only "docs" */
    dir_entry_t *dirs = NULL; int dn = 0;
    assert(rsyncx_index_dirs(idx, "", &dirs, &dn) == 0);
    int found_docs = 0;
    for (int i = 0; i < dn; i++) if (strcmp(rsyncx_dir_name(&dirs[i]), "docs") == 0) found_docs = 1;
    assert(found_docs == 1);
    /* no regular files in the dirs list */
    for (int i = 0; i < dn; i++) assert(dirs[i].is_dir == 1);
    rsyncx_free(dirs);

    /* search "readme" → docs/readme.md (full path), files only */
    lifecycle_t *res = NULL; int rn = 0;
    assert(rsyncx_index_search(idx, "readme", &res, &rn) == 0);
    int found = 0;
    for (int i = 0; i < rn; i++) {
        if (strcmp(res[i].rel_path, "docs/readme.md") == 0) { found = 1; assert(res[i].is_dir == 0); }
    }
    assert(found == 1);
    rsyncx_free(res);

    rsyncx_index_free(idx);
    char rm[1200]; snprintf(rm, sizeof rm, "rm -rf \"%s\"", base); (void)system(rm);
    printf("PASS: index dirs + search\n");
}
```

- [ ] **Step 3: Implement the two queries in index.c**

Add to `engine/index.c`:
```c
int rsyncx_index_dirs(const rsyncx_index_t *ix, const char *rel_path,
                      dir_entry_t **out, int *count)
{
    if (!ix || !out || !count) return -1;
    int head;
    if (rel_path[0] == '\0' || strcmp(rel_path, "/") == 0) head = ix->root_child;
    else {
        int dir = idx_find(ix, rel_path);
        head = (dir == IDX_NONE) ? IDX_NONE : ix->nodes[dir].first_child;
    }

    int n = 0;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling)
        if (ix->nodes[c].is_dir) n++;
    dir_entry_t *arr = (n > 0) ? malloc((size_t)n * sizeof(dir_entry_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int i = 0, last = ix->snap_count - 1;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) {
        const idx_node_t *nd = &ix->nodes[c];
        if (!nd->is_dir) continue;
        dir_entry_t d; memset(&d, 0, sizeof d);
        str_copy(d.name, sizeof d.name, ix->pool + nd->name_off);
        d.is_dir = 1;
        d.exists_in_latest = present_get(nd, last) ? 1 : 0;
        arr[i++] = d;
    }
    *out = arr; *count = n;
    return 0;
}

int rsyncx_index_search(const rsyncx_index_t *ix, const char *query,
                        lifecycle_t **out, int *count)
{
    if (!ix || !out || !count || !query) return -1;
    if (query[0] == '\0') { *out = NULL; *count = 0; return 0; }

    int n = 0;
    for (int i = 0; i < ix->node_count; i++) {
        const idx_node_t *nd = &ix->nodes[i];
        if (nd->is_dir) continue;
        if (strstr(ix->pool + nd->name_off, query)) n++;
    }
    lifecycle_t *arr = (n > 0) ? malloc((size_t)n * sizeof(lifecycle_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int k = 0;
    for (int i = 0; i < ix->node_count; i++) {
        const idx_node_t *nd = &ix->nodes[i];
        if (nd->is_dir) continue;
        if (strstr(ix->pool + nd->name_off, query)) node_to_lifecycle(ix, i, 1, &arr[k++]);
    }
    *out = arr; *count = n;
    return 0;
}
```

- [ ] **Step 4: Build and run — verify pass**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine clean && make -C engine && make -C engine test
```
Expected: `PASS: index dirs + search` printed; all index/search/ssh tests pass; exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/index.c engine/engine.h engine/test_index.c
git commit -m "feat(engine): sidebar dirs + whole-tree search queries on the index"
```

---

## Task 4: Remote whole-tree scan (replace the stub)

Implement `scan_tree_remote` so remote sources build the index over SSH. No automated test (needs a live server); correctness rests on reusing the proven argv/spawn path with the same find arguments as a recursive scan including directories.

**Files:**
- Modify: `engine/index.c`

- [ ] **Step 1: Replace the stub with a real recursive SSH scan**

In `engine/index.c`, replace the temporary `scan_tree_remote` stub with:
```c
#include <sys/wait.h>

/* Recursive remote scan of one snapshot: ssh ... find <root> -printf ... (no
   -maxdepth, no -type filter → files AND directories). Parses %P rel_paths. */
static int scan_tree_remote(const source_t *src, const char *root,
                            file_entry_array_t *out)
{
    char *argv[24];
    char  pool[SSH_CMD_MAX];
    pid_t pid = -1;
    if (ssh_build_find_argv(src, root, -1, NULL, NULL,
                            argv, 24, pool, sizeof pool) != 0)
        return -1;

    FILE *fp = ssh_spawn_capture(argv, &pid);
    if (!fp) return -1;

    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        str_trim(line);
        if (line[0] == '\0') continue;
        file_entry_t fe;
        if (parse_index_find_line(line, &fe) != 0) continue;
        if (fe_array_push(out, &fe) != 0) { ssh_spawn_reap(fp, pid); return -1; }
    }
    ssh_spawn_reap(fp, pid);
    return 0;
}
```
And add a tab-delimited parser above it (the `-printf` format is
`%i\t%m\t%u\t%g\t%s\t%T@\t%n\t%P` — inode, mode(octal), user, group, size, mtime, nlink, rel_path). This mirrors `parse_find_line` in `scan_remote.c` but is local to `index.c`:
```c
static int parse_index_find_line(const char *line, file_entry_t *fe)
{
    char buf[4096];
    str_copy(buf, sizeof(buf), line);

    char *fields[8] = {0};
    char *tok = buf;
    for (int i = 0; i < 8; i++) {
        fields[i] = tok;
        char *tab = strchr(tok, '\t');
        if (tab) { *tab = '\0'; tok = tab + 1; }
        else if (i < 7) return -1;
    }

    memset(fe, 0, sizeof(*fe));
    fe->inode = (uint64_t)strtoull(fields[0], NULL, 10);
    fe->mode  = (uint32_t)strtoul(fields[1], NULL, 8);   /* %m is octal */
    str_copy(fe->user,  sizeof(fe->user),  fields[2]);
    str_copy(fe->group, sizeof(fe->group), fields[3]);
    fe->size  = (uint64_t)strtoull(fields[4], NULL, 10);
    fe->mtime = (int64_t)strtoll(fields[5], NULL, 10);
    fe->nlink = (uint32_t)strtoul(fields[6], NULL, 10);
    str_copy(fe->rel_path, sizeof(fe->rel_path), fields[7]);
    fe->is_dir = S_ISDIR(fe->mode) ? 1 : 0;
    if (fe->is_dir) fe->size = 0;
    return 0;
}
```
Move the `parse_index_find_line` definition ABOVE `scan_tree_remote`, and place both ABOVE `rsyncx_build_index`. Remove the old stub. (`ssh_build_find_argv`, `ssh_spawn_capture`, `ssh_spawn_reap`, `str_trim`, `SSH_CMD_MAX` are all declared in `engine_internal.h`.)

Note: the remote `%m` is printed by `find -printf "%m"` in octal, so it is parsed with base 8 to reconstruct `st_mode`; `S_ISDIR` then works. (The local `fts` path already has the real `st_mode`.)

- [ ] **Step 2: Build — verify it compiles and local tests still pass**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine clean && make -C engine && make -C engine test
```
Expected: clean build under `-Werror`; all three PASS lines (the local index tests are unaffected); exit 0. (The remote path has no automated test.)

- [ ] **Step 3: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add engine/index.c
git commit -m "feat(engine): remote whole-tree scan via SSH argv for index build"
```

---

## Task 5: Swift bridge for the index

**Files:**
- Modify: `app/EngineBridge.swift`

- [ ] **Step 1: Add index wrappers + progress bridging**

In `app/EngineBridge.swift`, inside `enum EngineBridge` (next to `scanDir`/`search`), add:
```swift
    // MARK: - In-memory index

    /// Box that carries a Swift progress closure across the C callback boundary.
    private final class ProgressBox {
        let cb: (Int, Int, Int) -> Void
        init(_ cb: @escaping (Int, Int, Int) -> Void) { self.cb = cb }
    }

    /// Build the whole-backup index. `progress(done, total, files)` is invoked on
    /// the calling (background) thread. Returns an opaque index handle or nil.
    static func buildIndex(source: Source, snapshots: [Snapshot],
                           fromIdx: Int, toIdx: Int,
                           progress: @escaping (Int, Int, Int) -> Void) -> OpaquePointer? {
        var cSourceCopy = source.toC()
        let cSnaps = snapshots.map { $0.toC() }

        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }

        let cb: @convention(c) (Int32, Int32, Int, UnsafeMutableRawPointer?) -> Void = {
            done, total, files, ctx in
            guard let ctx = ctx else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            box.cb(Int(done), Int(total), files)
        }

        return rsyncx_build_index(&cSourceCopy, cSnaps, Int32(snapshots.count),
                                  Int32(fromIdx), Int32(toIdx), cb, ctx)
    }

    static func freeIndex(_ idx: OpaquePointer) {
        rsyncx_index_free(idx)
    }

    static func indexChildren(_ idx: OpaquePointer, relPath: String) -> [FileEntry] {
        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0
        guard rsyncx_index_children(idx, relPath, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { makeFileEntry(ptr + $0) }
    }

    static func indexDirs(_ idx: OpaquePointer, relPath: String) -> [DirEntry] {
        var out: UnsafeMutablePointer<dir_entry_t>?
        var count: Int32 = 0
        guard rsyncx_index_dirs(idx, relPath, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { i -> DirEntry in
            let d = ptr + i
            return DirEntry(id: String(cString: rsyncx_dir_name(d)),
                            name: String(cString: rsyncx_dir_name(d)),
                            existsInLatest: d.pointee.exists_in_latest != 0)
        }
    }

    static func indexSearch(_ idx: OpaquePointer, query: String) -> [FileEntry] {
        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0
        guard rsyncx_index_search(idx, query, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { makeFileEntry(ptr + $0) }
    }
```
Note: if `EngineBridge` is declared as `class`/`enum` and `makeFileEntry` is `private static`, these methods can call it directly. If `rsyncx_build_index`'s imported Swift type for the callback differs (e.g. expects `Int` vs `Int32` for the `files` param — it is C `long`, imported as `Int`), match the imported signature exactly; build errors will show the expected type. The `@convention(c)` closure captures nothing (state travels through `ctx`), which is required.

- [ ] **Step 2: Build — verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh 2>&1 | tail -4
```
Expected: `✓ Done: rsync-explorer.app`, no Swift errors. If the callback parameter types mismatch the imported C signature, adjust the `@convention(c)` closure's parameter types to match (the C prototype is `void (*)(int, int, long, void *)`).

- [ ] **Step 3: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/EngineBridge.swift
git commit -m "feat(app): EngineBridge wrappers for the index with progress bridging"
```

---

## Task 6: Route navigation/sidebar/search through the index

Build the index on source-select / range-change with a progress indicator; serve the file list, sidebar, and search from it; free on rebuild/close.

**Files:**
- Modify: `app/MainWindowController.swift`

- [ ] **Step 1: Add the index property and a builder**

In `app/MainWindowController.swift`, add a stored property near `snapshots`:
```swift
    private var index: OpaquePointer?
```
Add a build method near `discoverSnapshots`:
```swift
    private func rebuildIndex() {
        guard let source = currentSource, !snapshots.isEmpty else { return }
        if let old = index { EngineBridge.freeIndex(old); index = nil }

        let snaps = snapshots
        let from = timelineVisible ? fromIdx : 0
        let to   = timelineVisible ? toIdx   : max(0, snaps.count - 1)
        statusBar.startLoading()
        statusBar.update(files: 0, deleted: 0, modified: 0, new: 0, unchanged: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let idx = EngineBridge.buildIndex(source: source, snapshots: snaps,
                                              fromIdx: from, toIdx: to) { done, total, files in
                DispatchQueue.main.async {
                    self?.statusBar.update(files: files, deleted: 0, modified: 0,
                                           new: 0, unchanged: 0)
                }
            }
            DispatchQueue.main.async {
                guard let self = self else {
                    if let idx = idx { EngineBridge.freeIndex(idx) }
                    return
                }
                self.statusBar.stopLoading()
                guard let idx = idx else {
                    self.showAlert(title: "Indexing Failed",
                                   message: "Couldn't index \(source.name).")
                    return
                }
                self.index = idx
                self.scanCurrentDir()
                self.expandCurrentTree()
            }
        }
    }
```

- [ ] **Step 2: Build the index after snapshot discovery**

In `discoverSnapshots`, replace the success tail:
```swift
                self.scanCurrentDir()
                self.expandCurrentTree()
```
with:
```swift
                self.rebuildIndex()
```
(`rebuildIndex` builds the index and then calls `scanCurrentDir`/`expandCurrentTree` itself.)

- [ ] **Step 3: Rebuild on timeline range change**

In `timelineRangeChanged(from:to:)`, replace:
```swift
        fromIdx = from
        toIdx = to
        scanCurrentDir()
        expandCurrentTree()
```
with:
```swift
        fromIdx = from
        toIdx = to
        rebuildIndex()
```
And in `toggleTimeline(_:)`, in the `if !timelineVisible { ... }` block, replace its `scanCurrentDir()` + `expandCurrentTree()` calls with `rebuildIndex()` (hiding the timeline resets to the full range, which changes the index range).

- [ ] **Step 4: Serve the file list from the index**

Replace the body of `scanCurrentDir()` with an instant in-memory query:
```swift
    private func scanCurrentDir() {
        updateBreadcrumb()
        guard let idx = index else { return }
        let files = EngineBridge.indexChildren(idx, relPath: currentPath)
        fileListVC.updateFiles(files)
        let deleted   = files.filter { $0.classification == .deleted }.count
        let delNew    = files.filter { $0.classification == .delNew }.count
        let modified  = files.filter { $0.classification == .modified }.count
        let newFiles  = files.filter { $0.classification == .isNew }.count
        let unchanged = files.filter { $0.classification == .unchanged }.count
        statusBar.update(files: files.count, deleted: deleted + delNew,
                         modified: modified, new: newFiles, unchanged: unchanged)
    }
```

- [ ] **Step 5: Serve the sidebar from the index**

Replace the body of `expandCurrentTree()` with:
```swift
    private func expandCurrentTree() {
        guard let idx = index else { return }
        let dirs = EngineBridge.indexDirs(idx, relPath: currentPath)
        sidebarVC.updateEntries(dirs, currentPath: currentPath)
    }
```

- [ ] **Step 6: Serve search from the index**

In `searchSubmitted()`, replace the whole background-dispatch block that calls `EngineBridge.search(...)` with an instant query. The method becomes:
```swift
    @objc private func searchSubmitted() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let idx = index else { return }
        let results = EngineBridge.indexSearch(idx, query: query)
        fileListVC.updateFiles(results)
        let deleted   = results.filter { $0.classification == .deleted }.count
        let delNew    = results.filter { $0.classification == .delNew }.count
        let modified  = results.filter { $0.classification == .modified }.count
        let newFiles  = results.filter { $0.classification == .isNew }.count
        let unchanged = results.filter { $0.classification == .unchanged }.count
        statusBar.update(files: results.count, deleted: deleted + delNew,
                         modified: modified, new: newFiles, unchanged: unchanged)
    }
```
(The `searchGeneration` token is no longer needed for search since it is now synchronous and instant; leaving the property in place is harmless, but remove the `searchGeneration += 1` / capture / guard lines that referenced it inside `searchSubmitted` as part of this replacement.)

- [ ] **Step 7: Free the index on window close**

In `app/MainWindowController.swift`, find `func windowWillClose` (NSWindowDelegate). If it exists, add the free; if not, add the method:
```swift
    func windowWillClose(_ notification: Notification) {
        if let idx = index { EngineBridge.freeIndex(idx); index = nil }
    }
```
(If a `windowWillClose` already exists, just add the two index lines inside it.)

- [ ] **Step 8: Build — verify it compiles**

Run:
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh 2>&1 | tail -4
```
Expected: `✓ Done: rsync-explorer.app`, no Swift errors or unused-variable warnings.

- [ ] **Step 9: Commit**

```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
git add app/MainWindowController.swift
git commit -m "feat(app): serve navigation, sidebar, and search from the in-memory index"
```

- [ ] **Step 10: Manual verification**

Run `open rsync-explorer.app`, pick the remote source. Expected: a one-time "Indexing… N files" progress in the status bar, then **instant** folder navigation, sidebar expansion, and search (no multi-second waits). Navigation depth and Back still behave correctly; deleted/new/modified marks and the lifecycle status counts still appear.

---

## Final Verification

- [ ] **Engine tests pass**
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
make -C engine clean && make -C engine && make -C engine test
```
Expected: `PASS` for search, ssh, scan_tree_local, index children/classification, and index dirs/search; exit 0.

- [ ] **App builds**
```bash
cd /Users/joeltordjman/Documents/GIT/rsync-explorer
./build.sh 2>&1 | tail -2
```
Expected: `✓ Done: rsync-explorer.app`.

- [ ] **End-to-end manual pass** — remote source: progress on load, then instant nav/sidebar/search; correct classes; Back works; memory stays reasonable (Activity Monitor) for the backup size.

---

## Notes & Risks

- **Build data volume / time:** one recursive scan per snapshot streams entries (parsed line-by-line, never holding raw text); merge keeps one compact node per unique path. Remote scans currently run **sequentially** per snapshot in `rsyncx_build_index` — acceptable for a one-time build, and a later optimization could parallelize them with the existing fork/pipe pattern.
- **Memory:** ~80 B/node + pooled paths + interned owners; ~70-140 MB at 0.5-1M paths. Swift holds only the current directory's rows.
- **Classification fidelity:** the index's `finalize` mirrors `classify_merge_entry` exactly (del→new gaps, deleted-not-in-latest, new-only-in-latest, modified-on-inode-change, else unchanged), verified by `test_index.c` against the hard-linked fixture.
- **Lifetime:** Swift frees the old index before rebuilding and on window close; the C side frees pool/nodes/buckets/owners/snaps.
- **Range semantics:** the index reflects the active `[from,to]`; changing the timeline range rebuilds it. Search needs no range argument because the index already encodes it.
