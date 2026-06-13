/**
 * @file index.c
 * @brief In-memory whole-backup index: build, classify, and query.
 */
#include "engine_internal.h"
#include <errno.h>
#include <fts.h>
#include <pthread.h>
#include <sys/wait.h>

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

/* Parse one `find -printf "%i\t%m\t%u\t%g\t%s\t%T@\t%n\t%y\t%P"` line into fe.
   %m is octal (find prints mode in octal), so st_mode is parsed base 8. */
static int parse_index_find_line(const char *line, file_entry_t *fe)
{
    char buf[4096];
    str_copy(buf, sizeof(buf), line);

    char *fields[9] = {0};
    char *tok = buf;
    for (int i = 0; i < 9; i++) {
        fields[i] = tok;
        if (i == 8) break;   /* %P is last and may itself contain tabs */
        char *tab = strchr(tok, '\t');
        if (!tab) return -1;
        *tab = '\0'; tok = tab + 1;
    }

    memset(fe, 0, sizeof(*fe));
    fe->inode = (uint64_t)strtoull(fields[0], NULL, 10);
    fe->mode  = (uint32_t)strtoul(fields[1], NULL, 8);   /* %m is octal */
    str_copy(fe->user,  sizeof(fe->user),  fields[2]);
    str_copy(fe->group, sizeof(fe->group), fields[3]);
    fe->size  = (uint64_t)strtoull(fields[4], NULL, 10);
    fe->mtime = (int64_t)strtoll(fields[5], NULL, 10);
    fe->nlink = (uint32_t)strtoul(fields[6], NULL, 10);
    fe->is_dir = (fields[7][0] == 'd') ? 1 : 0;   /* %y type letter */
    if (strlen(fields[8]) >= sizeof(fe->rel_path)) return -1;   /* would truncate */
    str_copy(fe->rel_path, sizeof(fe->rel_path), fields[8]);
    if (!rel_path_safe(fe->rel_path)) return -1;
    if (fe->is_dir) fe->size = 0;
    return 0;
}

/* Recursive remote scan of one snapshot: ssh ... 'find <root> -printf ...'
   with no -maxdepth and no -type filter, so files AND directories are listed. */
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
    int status = ssh_spawn_reap(fp, pid);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return -1;   /* SSH/find failed or was signaled — treat as scan failure */
    return 0;
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

    int      first_idx, last_idx;     /* first/last present IN CURRENT RANGE (set_range) */
    uint64_t present_lo, present_hi;  /* presence bitmap over <=128 snapshots */
    uint64_t changed_lo, changed_hi;  /* inode differed from previous present snapshot */
    uint64_t last_seen_inode;         /* inode at the latest merged present snapshot */
    uint8_t  in_range;                /* visible in the current range (set_range) */
    int      merge_last_idx;          /* latest snapshot merged so far (build only) */
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
    int         snap_base;        /* offset of snaps[0] in the caller's array */
    int         range_from, range_to;  /* current range, ix-relative */
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
    nd->first_idx = -1; nd->last_idx = -1; nd->merge_last_idx = -1;
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

/* mask lo/hi down to bits [from, to] (0..127). */
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

static int merge_snapshot(rsyncx_index_t *ix, int s, const file_entry_array_t *a)
{
    for (int e = 0; e < a->count; e++) {
        const file_entry_t *fe = &a->data[e];
        int node = idx_intern(ix, fe->rel_path);
        if (node == IDX_NONE) return -1;
        idx_node_t *nd = &ix->nodes[node];

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
    }
    return 0;
}

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
            mask_range(&clo, &chi, first + 1, to);
            cls = (clo | chi) ? CLASS_MODIFIED : CLASS_UNCHANGED;
        }
        nd->klass = (uint8_t)cls;
        nd->deleted_in = (cls == CLASS_DELETED)
                         ? ix->snaps[last + 1].date_epoch : -1;
    }
    return 0;
}

/* ── Parallel snapshot scanning ── */

typedef struct {
    const source_t   *src;
    const snapshot_t *snaps;
    int  range;
    int  next;
    int  stop;
    file_entry_array_t *results;
    uint8_t *done;
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

        int cacheable = (i < p->range - 1);

        file_entry_array_t a;
        int rc;
        if (cacheable && cache_read(p->src, &p->snaps[i], &a) == 0) {
            rc = 0;
        } else {
            if (!cacheable) fe_array_init(&a);
            rc = (p->src->type == SOURCE_REMOTE)
                   ? scan_tree_remote(p->src, p->snaps[i].full_path, &a)
                   : scan_tree_local(p->snaps[i].full_path, &a);
            if (rc == 0 && cacheable)
                (void)cache_write(p->src, &p->snaps[i], &a);
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

rsyncx_index_t *rsyncx_build_index(const source_t *src,
                                   const snapshot_t *snaps, int snap_count,
                                   int from_idx, int to_idx,
                                   void (*progress_cb)(int, int, long, void *),
                                   void *ctx)
{
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
        pool.done[i] = 2;
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

    link_tree(ix);
    if (rsyncx_index_set_range(ix, from_idx, to_idx) != 0)
        (void)rsyncx_index_set_range(ix, base, base + range - 1);
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
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) {
        if (!ix->nodes[c].in_range) continue;
        n++;
    }
    lifecycle_t *arr = (n > 0) ? malloc((size_t)n * sizeof(lifecycle_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int i = 0;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) {
        if (!ix->nodes[c].in_range) continue;
        node_to_lifecycle(ix, c, 0, &arr[i++]);
    }

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
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) {
        if (!ix->nodes[c].in_range) continue;
        if (ix->nodes[c].is_dir) n++;
    }
    dir_entry_t *arr = (n > 0) ? malloc((size_t)n * sizeof(dir_entry_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int i = 0, last = ix->range_to;
    for (int c = head; c != IDX_NONE; c = ix->nodes[c].next_sibling) {
        const idx_node_t *nd = &ix->nodes[c];
        if (!nd->in_range) continue;
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
        if (!nd->in_range) continue;
        if (nd->is_dir) continue;
        if (strstr(ix->pool + nd->name_off, query)) n++;
    }
    lifecycle_t *arr = (n > 0) ? malloc((size_t)n * sizeof(lifecycle_t)) : NULL;
    if (n > 0 && !arr) return -1;

    int k = 0;
    for (int i = 0; i < ix->node_count; i++) {
        const idx_node_t *nd = &ix->nodes[i];
        if (!nd->in_range) continue;
        if (nd->is_dir) continue;
        if (strstr(ix->pool + nd->name_off, query)) node_to_lifecycle(ix, i, 1, &arr[k++]);
    }
    *out = arr; *count = n;
    return 0;
}
