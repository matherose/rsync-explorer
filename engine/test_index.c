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
    assert(fd >= 0);
    (void)write(fd, content, strlen(content));
    close(fd);
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
    assert(a.count == 3);   /* exactly the 3 fixture entries, root excluded */

    for (int i = 0; i < a.count; i++) {
        if (strcmp(a.data[i].rel_path, "docs") == 0) assert(a.data[i].is_dir == 1);
        if (strcmp(a.data[i].rel_path, "alpha.txt") == 0) assert(a.data[i].is_dir == 0);
    }

    fe_array_free(&a);
    char rm[1200]; snprintf(rm, sizeof rm, "rm -rf \"%s\"", base); (void)system(rm);
    printf("PASS: scan_tree_local lists files + dirs with full rel_paths\n");
}

/* Build a 2-snapshot hard-linked fixture; fills base/snap1/snap2 paths.
   alpha.txt UNCHANGED (hardlinked), gamma.txt DELETED (snap1 only),
   beta.txt NEW (snap2 only), mod.txt MODIFIED (both, distinct inodes),
   docs UNCHANGED dir, docs/readme.md UNCHANGED (hardlinked). */
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

    snprintf(p, sizeof p, "%s/alpha.txt", s1); write_file(p, "A");
    snprintf(q, sizeof q, "%s/alpha.txt", s2); assert(link(p, q) == 0);
    snprintf(p, sizeof p, "%s/docs/readme.md", s1); write_file(p, "R");
    snprintf(q, sizeof q, "%s/docs/readme.md", s2); assert(link(p, q) == 0);
    snprintf(p, sizeof p, "%s/gamma.txt", s1); write_file(p, "G");
    snprintf(p, sizeof p, "%s/beta.txt", s2); write_file(p, "B");
    snprintf(p, sizeof p, "%s/mod.txt", s1); write_file(p, "v1");
    snprintf(p, sizeof p, "%s/mod.txt", s2); write_file(p, "v2-different");
}

static lifecycle_t *find_lc(lifecycle_t *a, int n, const char *leaf)
{
    for (int i = 0; i < n; i++) if (strcmp(a[i].rel_path, leaf) == 0) return &a[i];
    return NULL;
}

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

    assert(rsyncx_index_children(idx, "docs", &out, &n) == 0);
    lifecycle_t *readme = find_lc(out, n, "readme.md");
    assert(readme && readme->class == CLASS_UNCHANGED);
    rsyncx_free(out);

    rsyncx_index_free(idx);
    char rm[1200]; snprintf(rm, sizeof rm, "rm -rf \"%s\"", base); (void)system(rm);
    printf("PASS: index children + classification\n");
}

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

    /* dirs of root -> only "docs" */
    dir_entry_t *dirs = NULL; int dn = 0;
    assert(rsyncx_index_dirs(idx, "", &dirs, &dn) == 0);
    int found_docs = 0;
    for (int i = 0; i < dn; i++) if (strcmp(rsyncx_dir_name(&dirs[i]), "docs") == 0) found_docs = 1;
    assert(found_docs == 1);
    for (int i = 0; i < dn; i++) assert(dirs[i].is_dir == 1);
    rsyncx_free(dirs);

    /* search "readme" -> docs/readme.md (full path), files only */
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

int main(void)
{
    char cache_tmpl[] = "/tmp/rsyncx_cache_main_XXXXXX";
    assert(mkdtemp(cache_tmpl) != NULL);
    setenv("RSYNCX_CACHE_DIR", cache_tmpl, 1);

    test_scan_tree_local();
    test_index_children();
    test_index_dirs_and_search();
    test_cache_roundtrip();
    test_cache_robustness();
    return 0;
}
