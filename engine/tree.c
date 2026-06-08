/**
 * @file tree.c
 * @brief Sidebar tree expansion — union of directories across snapshots.
 */

#include "engine_internal.h"

int rsyncx_expand_tree(const source_t *src,
                       const snapshot_t *snaps, int snap_count,
                       const char *rel_path,
                       int from_idx, int to_idx,
                       dir_entry_t **out, int *out_count)
{
    if (!src || !snaps || !out || !out_count) return -1;
    if (from_idx < 0) from_idx = 0;
    if (to_idx >= snap_count) to_idx = snap_count - 1;
    if (from_idx > to_idx) { *out = NULL; *out_count = 0; return 0; }

    int range_len = to_idx - from_idx + 1;

    /* Scan each snapshot for directories */
    file_entry_array_t *snap_arrays = calloc((size_t)range_len,
                                              sizeof(file_entry_array_t));
    if (!snap_arrays) return -1;

    int result = 0;
    for (int i = 0; i < range_len; i++) {
        if (fe_array_init(&snap_arrays[i]) != 0) {
            result = -1;
            break;
        }

        char abs_path[2048];
        if (rel_path[0] != '\0' && strcmp(rel_path, "/") != 0) {
            snprintf(abs_path, sizeof(abs_path), "%s/%s",
                     snaps[from_idx + i].full_path, rel_path);
        } else {
            str_copy(abs_path, sizeof(abs_path), snaps[from_idx + i].full_path);
        }

        /* Scan for directories only */
        if (src->type == SOURCE_REMOTE) {
            char *argv[24];
            char  pool[SSH_CMD_MAX];
            pid_t pid = -1;
            if (ssh_build_find_argv(src, abs_path, 1, "d", NULL,
                                    argv, 24, pool, sizeof pool) != 0) {
                snap_arrays[i].count = 0;
                continue;
            }
            FILE *fp = ssh_spawn_capture(argv, &pid);
            if (!fp) { snap_arrays[i].count = 0; continue; }

            char line[2048];
            while (fgets(line, sizeof(line), fp)) {
                str_trim(line);
                if (line[0] == '\0') continue;

                /* Parse the same tab-delimited format */
                char *fields[8] = {0};
                int fc = 0;
                char *tok = line;
                for (int j = 0; j < 8; j++) {
                    fields[j] = tok;
                    char *tab = strchr(tok, '\t');
                    if (tab) { *tab = '\0'; tok = tab + 1; fc++; }
                    else { str_trim(tok); fc++; break; }
                }

                if (fc < 8 || fields[7][0] == '\0') continue;

                file_entry_t fe;
                memset(&fe, 0, sizeof(fe));
                fe.inode = strtoull(fields[0], NULL, 10);
                fe.mode  = (uint32_t)strtoul(fields[1], NULL, 8);
                str_copy(fe.user, sizeof(fe.user), fields[2]);
                str_copy(fe.group, sizeof(fe.group), fields[3]);
                fe.size  = 0;  /* dir */
                fe.mtime = strtoll(fields[5], NULL, 10);
                fe.nlink = (uint32_t)strtoul(fields[6], NULL, 10);
                str_copy(fe.rel_path, sizeof(fe.rel_path), fields[7]);
                fe.is_dir = 1;

                fe_array_push(&snap_arrays[i], &fe);
            }
            ssh_spawn_reap(fp, pid);
        } else {
#ifdef __APPLE__
            if (scan_dir_macos(abs_path, &snap_arrays[i]) != 0) {
                snap_arrays[i].count = 0;
            }
#else
            if (scan_dir_posix(abs_path, &snap_arrays[i]) != 0) {
                snap_arrays[i].count = 0;
            }
#endif
        }
    }

    if (result != 0) {
        for (int i = 0; i < range_len; i++) fe_array_free(&snap_arrays[i]);
        free(snap_arrays);
        return -1;
    }

    /* Merge unique directory names */
    int capacity = 64;
    int n = 0;
    dir_entry_t *arr = malloc((size_t)capacity * sizeof(dir_entry_t));
    if (!arr) {
        for (int i = 0; i < range_len; i++) fe_array_free(&snap_arrays[i]);
        free(snap_arrays);
        return -1;
    }

    int last_snap = range_len - 1;

    for (int s = 0; s < range_len; s++) {
        for (int e = 0; e < snap_arrays[s].count; e++) {
            const file_entry_t *fe = &snap_arrays[s].data[e];

            int found = -1;
            for (int i = 0; i < n; i++) {
                if (strcmp(arr[i].name, fe->rel_path) == 0) {
                    found = i;
                    break;
                }
            }

            if (found < 0) {
                if (n >= capacity) {
                    capacity *= 2;
                    dir_entry_t *tmp = realloc(arr,
                                               (size_t)capacity * sizeof(dir_entry_t));
                    if (!tmp) {
                        free(arr);
                        for (int j = 0; j < range_len; j++)
                            fe_array_free(&snap_arrays[j]);
                        free(snap_arrays);
                        *out = NULL; *out_count = 0;
                        return -1;
                    }
                    arr = tmp;
                }
                str_copy(arr[n].name, sizeof(arr[n].name), fe->rel_path);
                arr[n].is_dir           = 1;
                arr[n].exists_in_latest = (s == last_snap) ? 1 : 0;
                n++;
            } else {
                if (s == last_snap) {
                    arr[found].exists_in_latest = 1;
                }
            }
        }
    }

    for (int i = 0; i < range_len; i++) fe_array_free(&snap_arrays[i]);
    free(snap_arrays);

    *out       = arr;
    *out_count = n;
    return 0;
}
