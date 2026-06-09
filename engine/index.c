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
