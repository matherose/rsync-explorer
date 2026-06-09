/**
 * @file engine_internal.h
 * @brief Internal shared types and functions for the engine.
 *
 * NOT part of the public API — only used between engine .c files.
 */

#pragma once

#include "engine.h"
#include <stdint.h>
#include <stddef.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <unistd.h>
#include <limits.h>

/* ── Internal per-snapshot file entry ── */

typedef struct {
    char     rel_path[512];
    uint64_t inode;
    uint32_t mode;
    char     user[64];
    char     group[64];
    uint64_t size;
    int64_t  mtime;
    uint32_t nlink;
    uint8_t  is_dir;
} file_entry_t;

/** Growable array of file_entry_t. */
typedef struct {
    file_entry_t *data;
    int           count;
    int           capacity;
} file_entry_array_t;

int  fe_array_init(file_entry_array_t *arr);
int  fe_array_push(file_entry_array_t *arr, const file_entry_t *item);
void fe_array_free(file_entry_array_t *arr);

/* ── String helpers (util.c) ── */

void str_copy(char *dst, size_t dst_size, const char *src);
void str_trim(char *s);
void mode_to_str(uint32_t mode, char *out, size_t out_size);
int  epoch_to_str(int64_t epoch, char *out, size_t out_size);

/* ── Scan implementations ── */

int  scan_dir_macos(const char *abs_path, file_entry_array_t *out);
int  scan_dir_posix(const char *abs_path, file_entry_array_t *out);
int  scan_dir_remote(const source_t *src, const char *abs_path,
                     file_entry_array_t *out);
int  scan_dir_remote_parallel(const source_t *src,
                             const snapshot_t *snaps, int snap_count,
                             const char *rel_path,
                             file_entry_array_t *out_arrays);

/* ── Whole-tree scan (index.c) ── */

/* Recursively list every entry (files AND directories) under a local snapshot
   directory, with rel_path = path relative to snapshot_root. Returns 0/-1. */
int scan_tree_local(const char *snapshot_root, file_entry_array_t *out);

/* ── Classify (classify.c) ── */

void classify_entries(file_entry_t **snap_entries,
                      int *snap_counts, int snap_count,
                      const snapshot_t *snaps,
                      const char *rel_path,
                      lifecycle_t **out, int *out_count);

/* ── Tree expansion (tree.c) ── */

int expand_tree_entries(file_entry_t **snap_entries,
                        int *snap_counts, int snap_count,
                        const snapshot_t *snaps,
                        int from_idx, int to_idx,
                        dir_entry_t **out, int *out_count);

/* ── SSH command builder (ssh.c) ── */

#define SSH_CMD_MAX 4096

/* ── Safe argv-based SSH execution (ssh.c) ── */

/* Single-quote-escape `in` for a POSIX shell into `out` (wraps in '...',
   rewriting each ' as '\''). Returns 0, or -1 if it does not fit. */
int ssh_shell_quote(const char *in, char *out, size_t out_size);

/* Build an argv vector (NULL-terminated) for running find/ls/readlink on the
   remote host via `ssh`, with all remote-shell data single-quote-escaped.
   argv[] entries point at string literals, into `src`, or into `pool`.
   `argv` needs >= 24 slots; `pool` should be >= SSH_CMD_MAX bytes.
   Returns 0 on success, -1 on error/overflow. */
int ssh_build_find_argv(const source_t *src, const char *find_path,
                        int maxdepth, const char *type_filter,
                        const char *name_filter,
                        char **argv, int argv_max,
                        char *pool, size_t pool_size);
int ssh_build_ls_argv(const source_t *src, const char *path,
                      char **argv, int argv_max,
                      char *pool, size_t pool_size);
int ssh_build_readlink_argv(const source_t *src, const char *path,
                            char **argv, int argv_max,
                            char *pool, size_t pool_size);

/* Spawn argv[0] with argv via fork+execvp (NO shell); parent reads the child's
   stdout through the returned FILE*. Sets *out_pid. Returns NULL on failure. */
FILE *ssh_spawn_capture(char *const argv[], pid_t *out_pid);
/* fclose(fp) + waitpid(pid). Returns the child's wait status, or -1. */
int ssh_spawn_reap(FILE *fp, pid_t pid);

/* ── User/group resolution ── */

static inline void resolve_user(uid_t uid, char *out, size_t out_size)
{
    struct passwd pwd;
    struct passwd *result = NULL;
    char buf[1024];
    if (getpwuid_r(uid, &pwd, buf, sizeof buf, &result) == 0 && result) {
        str_copy(out, out_size, pwd.pw_name);
    } else {
        snprintf(out, out_size, "%u", (unsigned)uid);
    }
}

static inline void resolve_group(gid_t gid, char *out, size_t out_size)
{
    struct group grp;
    struct group *result = NULL;
    char buf[1024];
    if (getgrgid_r(gid, &grp, buf, sizeof buf, &result) == 0 && result) {
        str_copy(out, out_size, grp.gr_name);
    } else {
        snprintf(out, out_size, "%u", (unsigned)gid);
    }
}
