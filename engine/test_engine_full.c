/**
 * @file test_engine_full.c
 * @brief Comprehensive ASan/UBSan test covering all engine code paths.
 *
 * Tests: config parse, discover, scan_dir (full range + narrow range),
 *         expand_tree, scan deep subdirectory, and search.
 */

#include "engine_internal.h"

static const char *class_str(file_class_t cls)
{
    switch (cls) {
        case CLASS_UNCHANGED: return "UNCH";
        case CLASS_MODIFIED:  return "MOD ";
        case CLASS_NEW:       return "NEW ";
        case CLASS_DELETED:   return "DEL ";
        case CLASS_DEL_NEW:   return "D→N ";
    }
    return "????";
}

static void print_lifecycle(const lifecycle_t *lc)
{
    char perm[12], mtime_s[64], first_s[64], last_s[64], del_s[64];
    mode_to_str(lc->mode, perm, sizeof(perm));
    epoch_to_str(lc->mtime, mtime_s, sizeof(mtime_s));
    epoch_to_str(lc->first_backup, first_s, sizeof(first_s));
    epoch_to_str(lc->last_backup, last_s, sizeof(last_s));
    epoch_to_str(lc->deleted_in, del_s, sizeof(del_s));

    printf("  %-5s %-11s %-8s %-8s %8llu %-18s %-18s %-18s %-18s %s\n",
           class_str(lc->class), perm, lc->user, lc->group,
           (unsigned long long)lc->size,
           mtime_s, first_s, last_s, del_s,
           lc->rel_path);
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <config.ini>\n", argv[0]);
        return 1;
    }

    /* ── 1. Parse config ── */
    source_t *sources = NULL;
    int src_count = 0;

    printf("=== TEST 1: Parse config ===\n");
    if (rsyncx_parse_config(argv[1], &sources, &src_count) != 0) {
        fprintf(stderr, "FAIL: config parse\n");
        return 1;
    }
    printf("PASS: %d source(s)\n", src_count);

    /* ── 2. Discover snapshots ── */
    snapshot_t *snaps = NULL;
    int snap_count = 0;

    printf("\n=== TEST 2: Discover snapshots ===\n");
    if (rsyncx_discover(&sources[0], &snaps, &snap_count) != 0) {
        fprintf(stderr, "FAIL: discover\n");
        rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d snapshot(s) found\n", snap_count);

    /* ── 3. Scan root — full range ── */
    lifecycle_t *files = NULL;
    int file_count = 0;

    printf("\n=== TEST 3: Scan root (full range) ===\n");
    if (rsyncx_scan_dir(&sources[0], snaps, snap_count, "",
                        0, snap_count - 1,
                        &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: scan root\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d entries\n", file_count);
    rsyncx_free(files);
    files = NULL;

    /* ── 4. Scan root — narrow range (last 3 snapshots only) ── */
    printf("\n=== TEST 4: Scan root (narrow range: last 3) ===\n");
    if (rsyncx_scan_dir(&sources[0], snaps, snap_count, "",
                        snap_count - 3, snap_count - 1,
                        &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: scan narrow\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d entries in range\n", file_count);
    for (int i = 0; i < file_count; i++) print_lifecycle(&files[i]);
    rsyncx_free(files);
    files = NULL;

    /* ── 5. Scan subdirectory MEDIAS ── */
    printf("\n=== TEST 5: Scan MEDIAS (deep) ===\n");
    if (rsyncx_scan_dir(&sources[0], snaps, snap_count, "MEDIAS",
                        0, snap_count - 1,
                        &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: scan MEDIAS\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d entries\n", file_count);
    for (int i = 0; i < file_count; i++) print_lifecycle(&files[i]);
    rsyncx_free(files);
    files = NULL;

    /* ── 6. Expand tree — root ── */
    dir_entry_t *dirs = NULL;
    int dir_count = 0;

    printf("\n=== TEST 6: Expand tree (root) ===\n");
    if (rsyncx_expand_tree(&sources[0], snaps, snap_count, "",
                           0, snap_count - 1,
                           &dirs, &dir_count) != 0) {
        fprintf(stderr, "FAIL: expand tree root\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d dirs\n", dir_count);
    for (int i = 0; i < dir_count; i++) {
        printf("  📁 %-30s  %s\n", dirs[i].name,
               dirs[i].exists_in_latest ? "current" : "DELETED");
    }
    rsyncx_free(dirs);
    dirs = NULL;

    /* ── 7. Expand tree — subdirectory ── */
    printf("\n=== TEST 7: Expand tree (MEDIAS) ===\n");
    if (rsyncx_expand_tree(&sources[0], snaps, snap_count, "MEDIAS",
                           0, snap_count - 1,
                           &dirs, &dir_count) != 0) {
        fprintf(stderr, "FAIL: expand tree MEDIAS\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d dirs\n", dir_count);
    for (int i = 0; i < dir_count; i++) {
        printf("  📁 %-30s  %s\n", dirs[i].name,
               dirs[i].exists_in_latest ? "current" : "DELETED");
    }
    rsyncx_free(dirs);
    dirs = NULL;

    /* ── 8. Search ── */
    printf("\n=== TEST 8: Search for 'script' ===\n");
    if (rsyncx_search(&sources[0], snaps, snap_count, "script",
                      0, snap_count - 1,
                      &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: search\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d results\n", file_count);
    for (int i = 0; i < file_count; i++) print_lifecycle(&files[i]);
    rsyncx_free(files);

    /* ── 9. Edge case: single-snapshot range ── */
    printf("\n=== TEST 9: Scan root (single snapshot) ===\n");
    if (rsyncx_scan_dir(&sources[0], snaps, snap_count, "",
                        snap_count - 1, snap_count - 1,
                        &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: single snapshot\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d entries (all should be NEW)\n", file_count);
    for (int i = 0; i < file_count; i++) print_lifecycle(&files[i]);
    rsyncx_free(files);

    /* ── 10. Edge case: empty range ── */
    printf("\n=== TEST 10: Scan root (empty range: from > to) ===\n");
    if (rsyncx_scan_dir(&sources[0], snaps, snap_count, "",
                        5, 3,  /* from > to */
                        &files, &file_count) != 0) {
        fprintf(stderr, "FAIL: empty range returned error\n");
        rsyncx_free(snaps); rsyncx_free(sources);
        return 1;
    }
    printf("PASS: %d entries (should be 0)\n", file_count);
    rsyncx_free(files);

    /* ── Cleanup ── */
    rsyncx_free(snaps);
    rsyncx_free(sources);

    printf("\n=== ALL TESTS PASSED ===\n");
    return 0;
}
