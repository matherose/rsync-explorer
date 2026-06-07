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

    char rmcmd[600];
    snprintf(rmcmd, sizeof rmcmd, "rm -rf \"%s\"", base);
    (void)system(rmcmd);

    return 0;
}
