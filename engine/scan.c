/**
 * @file scan.c
 * @brief Scan dispatcher — orchestrates per-snapshot scans and classification.
 *        Remote scans run in parallel via fork+pipe.
 */

#include "engine_internal.h"

static void build_scan_path(const snapshot_t *snap,
                            const char *rel_path,
                            char *out, size_t out_size)
{
    if (rel_path[0] == '\0' || strcmp(rel_path, "/") == 0) {
        str_copy(out, out_size, snap->full_path);
    } else {
        snprintf(out, out_size, "%s/%s", snap->full_path, rel_path);
    }
}

static int scan_one_dir(const source_t *src,
                        const snapshot_t *snap,
                        const char *rel_path,
                        file_entry_array_t *out)
{
    char abs_path[2048];
    build_scan_path(snap, rel_path, abs_path, sizeof(abs_path));

    if (src->type == SOURCE_REMOTE) {
        return scan_dir_remote(src, abs_path, out);
    }

#ifdef __APPLE__
    return scan_dir_macos(abs_path, out);
#else
    return scan_dir_posix(abs_path, out);
#endif
}

int rsyncx_scan_dir(const source_t *src,
                    const snapshot_t *snaps, int snap_count,
                    const char *rel_path,
                    int from_idx, int to_idx,
                    lifecycle_t **out, int *count)
{
    if (!src || !snaps || !out || !count) return -1;
    if (from_idx < 0) from_idx = 0;
    if (to_idx >= snap_count) to_idx = snap_count - 1;
    if (from_idx > to_idx) { *out = NULL; *count = 0; return 0; }

    int range_len = to_idx - from_idx + 1;

    file_entry_array_t *snap_arrays = calloc((size_t)range_len,
                                              sizeof(file_entry_array_t));
    file_entry_t      **snap_entries = malloc((size_t)range_len * sizeof(file_entry_t *));
    int                *snap_counts  = malloc((size_t)range_len * sizeof(int));
    if (!snap_arrays || !snap_entries || !snap_counts) {
        free(snap_arrays); free(snap_entries); free(snap_counts);
        return -1;
    }

    /* Initialize all arrays */
    for (int i = 0; i < range_len; i++) {
        fe_array_init(&snap_arrays[i]);
    }

    int result = 0;

    if (src->type == SOURCE_REMOTE && range_len > 1) {
        /* ── PARALLEL REMOTE SCAN ── */
        result = scan_dir_remote_parallel(src, &snaps[from_idx],
                                           range_len, rel_path,
                                           snap_arrays);
    } else {
        /* ── SEQUENTIAL SCAN (local or single snapshot) ── */
        for (int i = 0; i < range_len; i++) {
            int rc = scan_one_dir(src, &snaps[from_idx + i],
                                  rel_path, &snap_arrays[i]);
            if (rc != 0) {
                snap_arrays[i].count = 0;
            }
        }
    }

    if (result == 0) {
        for (int i = 0; i < range_len; i++) {
            snap_entries[i] = snap_arrays[i].data;
            snap_counts[i]  = snap_arrays[i].count;
        }

        classify_entries(snap_entries, snap_counts, range_len,
                         &snaps[from_idx], rel_path, out, count);
    }

    for (int i = 0; i < range_len; i++) {
        fe_array_free(&snap_arrays[i]);
    }
    free(snap_arrays);
    free(snap_entries);
    free(snap_counts);

    return result;
}
