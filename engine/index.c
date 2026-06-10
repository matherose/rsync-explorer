/**
 * @file index.c
 * @brief In-memory whole-backup index: build, classify, and query.
 */
#include "engine_internal.h"
#include <errno.h>
#include <fts.h>

/* ── Whole-tree local scan (files AND directories, full rel_paths) ── */

int scan_tree_local(const char *snapshot_root, file_entry_array_t *out)
{
    char *paths[] = { (char *)snapshot_root, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return -1;

    size_t base_len = strlen(snapshot_root);

    errno = 0;
    FTSENT *ent;
    while ((ent = fts_read(fts)) != NULL) {
        /* Visit each directory once (pre-order) and every file and symlink; skip
           the snapshot root itself and unreadable entries. */
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

    int saved_errno = errno;
    fts_close(fts);
    if (saved_errno != 0) return -1;   /* fts_read I/O error, not just end-of-tree */
    return 0;
}

/* Remote scan is implemented in a later task; stub returns -1 for now so a
   remote build simply yields an empty index until then. */
static int scan_tree_remote(const source_t *src, const char *root,
                            file_entry_array_t *out)
{
    (void)src; (void)root; (void)out;
    return -1;
}

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
    uint64_t present_lo, present_hi;  /* presence bitmap over <=128 snapshots */
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

static int merge_snapshot(rsyncx_index_t *ix, int s, const file_entry_array_t *a)
{
    for (int e = 0; e < a->count; e++) {
        const file_entry_t *fe = &a->data[e];
        int node = idx_intern(ix, fe->rel_path);
        if (node == IDX_NONE) return -1;
        idx_node_t *nd = &ix->nodes[node];

        present_set(nd, s);
        if (nd->first_idx < 0) { nd->first_idx = s; nd->first_inode = fe->inode; }
        else if (!fe->is_dir && fe->inode != 0 && nd->first_inode != 0 &&
                 fe->inode != nd->first_inode) nd->modified = 1;

        /* Snapshots are merged in ascending index order (see rsyncx_build_index),
           so the highest s seen is the latest present snapshot — its metadata wins. */
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

static void finalize(rsyncx_index_t *ix)
{
    int sc = ix->snap_count;
    ix->root_child = IDX_NONE;

    for (int i = 0; i < ix->node_count; i++) {
        idx_node_t *nd = &ix->nodes[i];

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
