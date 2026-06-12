/**
 * @file test_engine.c
 * @brief Quick CLI test for the C engine against a real rsync backup.
 *
 * Usage: ./test_engine path/to/config.ini [rel_path]
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

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <config.ini> [rel_path]\n", argv[0]);
        return 1;
    }

    const char *scan_path = (argc >= 3) ? argv[2] : "";

    /* ── Parse config ── */
    source_t *sources = NULL;
    int src_count = 0;

    printf("=== Parsing config: %s ===\n", argv[1]);
    if (rsyncx_parse_config(argv[1], &sources, &src_count) != 0) {
        fprintf(stderr, "ERROR: Failed to parse config\n");
        return 1;
    }
    printf("Found %d source(s):\n", src_count);
    for (int i = 0; i < src_count; i++) {
        printf("  [%s.%s] dest=%s",
               sources[i].type == SOURCE_LOCAL ? "local" : "remote",
               sources[i].name, sources[i].dest);
        if (sources[i].type == SOURCE_REMOTE) {
            printf(" host=%s user=%s key=%s",
                   sources[i].host, sources[i].user, sources[i].ssh_key);
        }
        printf("\n");
    }

    /* ── Discover snapshots ── */
    const source_t *src = &sources[0];
    snapshot_t *snaps = NULL;
    int snap_count = 0;

    printf("\n=== Discovering snapshots for %s ===\n", src->name);
    if (rsyncx_discover(src, &snaps, &snap_count) != 0) {
        fprintf(stderr, "ERROR: Failed to discover snapshots\n");
        rsyncx_free(sources);
        return 1;
    }
    printf("Found %d snapshot(s):\n", snap_count);
    for (int i = 0; i < snap_count; i++) {
        char date_str[64];
        epoch_to_str(snaps[i].date_epoch, date_str, sizeof(date_str));
        printf("  [%2d] %-25s  %s  %s\n",
               i, snaps[i].name, date_str, snaps[i].full_path);
    }

    /* ── Scan directory ── */
    lifecycle_t *files = NULL;
    int file_count = 0;

    printf("\n=== Scanning directory '%s' across all snapshots ===\n",
           scan_path[0] ? scan_path : "/");
    if (rsyncx_scan_dir(src, snaps, snap_count, scan_path,
                        0, snap_count - 1,
                        &files, &file_count) != 0) {
        fprintf(stderr, "ERROR: Failed to scan directory\n");
        rsyncx_free(snaps);
        rsyncx_free(sources);
        return 1;
    }

    printf("Found %d entries:\n", file_count);
    printf("%-5s %-11s %-8s %-8s %8s %-18s %-18s %-18s %-18s %s\n",
           "CLASS", "PERM", "USER", "GROUP", "SIZE",
           "MODIFIED", "FIRST_BACKUP", "LAST_BACKUP", "DELETED_IN", "PATH");
    printf("───── ─────────── ──────── ──────── ──────── "
           "────────────────── ────────────────── ────────────────── "
           "────────────────── ──────\n");

    for (int i = 0; i < file_count; i++) {
        const lifecycle_t *lc = &files[i];
        char perm[12], mtime_s[64], first_s[64], last_s[64], del_s[64];

        mode_to_str(lc->mode, perm, sizeof(perm));
        epoch_to_str(lc->mtime, mtime_s, sizeof(mtime_s));
        epoch_to_str(lc->first_backup, first_s, sizeof(first_s));
        epoch_to_str(lc->last_backup, last_s, sizeof(last_s));
        epoch_to_str(lc->deleted_in, del_s, sizeof(del_s));

        printf("%-5s %-11s %-8s %-8s %8llu %-18s %-18s %-18s %-18s %s\n",
               class_str(lc->class), perm, lc->user, lc->group,
               (unsigned long long)lc->size,
               mtime_s, first_s, last_s, del_s,
               lc->rel_path);
    }

    /* ── Sidebar tree ── */
    dir_entry_t *dirs = NULL;
    int dir_count = 0;

    printf("\n=== Sidebar tree ('%s') ===\n",
           scan_path[0] ? scan_path : "/");
    if (rsyncx_expand_tree(src, snaps, snap_count, scan_path,
                           0, snap_count - 1,
                           &dirs, &dir_count) != 0) {
        fprintf(stderr, "ERROR: Failed to expand tree\n");
    } else {
        for (int i = 0; i < dir_count; i++) {
            printf("  📁 %-30s  %s\n",
                   dirs[i].name,
                   dirs[i].exists_in_latest ? "✓ current" : "🔴 deleted");
        }
    }

    rsyncx_free(dirs);
    rsyncx_free(files);
    rsyncx_free(snaps);
    rsyncx_free(sources);

    printf("\nDone.\n");
    return 0;
}
