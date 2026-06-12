/**
 * @file scan_posix.c
 * @brief Local directory scanning using POSIX opendir/readdir/lstat.
 */

#include "engine_internal.h"

int scan_dir_posix(const char *abs_path, file_entry_array_t *out)
{
    DIR *dir = opendir(abs_path);
    if (!dir) return -1;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' &&
            (entry->d_name[1] == '\0' ||
             (entry->d_name[1] == '.' && entry->d_name[2] == '\0')))
            continue;

        char full_path[PATH_MAX];
        snprintf(full_path, sizeof(full_path), "%s/%s", abs_path, entry->d_name);

        struct stat st;
        if (lstat(full_path, &st) != 0) continue;

        file_entry_t fe;
        memset(&fe, 0, sizeof(fe));

        str_copy(fe.rel_path, sizeof(fe.rel_path), entry->d_name);
        fe.inode = (uint64_t)st.st_ino;
        fe.mode  = (uint32_t)st.st_mode;
        fe.size  = (uint64_t)st.st_size;
        fe.mtime = (int64_t)st.st_mtime;
        fe.nlink = (uint32_t)st.st_nlink;
        fe.is_dir = S_ISDIR(st.st_mode) ? 1 : 0;

        if (fe.is_dir) fe.size = 0;

        resolve_user(st.st_uid, fe.user, sizeof(fe.user));
        resolve_group(st.st_gid, fe.group, sizeof(fe.group));

        if (fe_array_push(out, &fe) != 0) {
            closedir(dir);
            return -1;
        }
    }

    closedir(dir);
    return 0;
}
