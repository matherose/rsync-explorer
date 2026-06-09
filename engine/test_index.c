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
