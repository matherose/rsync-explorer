/**
 * @file discover.c
 * @brief Snapshot discovery via the "latest" symlink.
 */

#include "engine_internal.h"

/**
 * Parse a snapshot directory name as a date.
 * Supported: %Y-%m-%d, %Y-%m-%d_%H-%M, %Y-%m-%dT%H-%M-%S
 * Returns epoch seconds on success, or -1 on parse failure.
 */
static int64_t parse_snapshot_date(const char *name)
{
    struct tm tm_buf;

    const char *formats[] = {
        "%Y-%m-%d_%H-%M",
        "%Y-%m-%dT%H-%M-%S",
        "%Y-%m-%d",
        NULL
    };

    for (int i = 0; formats[i]; i++) {
        memset(&tm_buf, 0, sizeof(tm_buf));
        char *ret = strptime(name, formats[i], &tm_buf);
        if (ret && *ret == '\0') {
            time_t t = mktime(&tm_buf);
            if (t != (time_t)-1) return (int64_t)t;
        }
    }
    return -1;
}

static char *get_parent_dir(const char *path)
{
    char *tmp = strdup(path);
    if (!tmp) return NULL;

    size_t len = strlen(tmp);
    while (len > 1 && tmp[len - 1] == '/') tmp[--len] = '\0';

    char *last_slash = strrchr(tmp, '/');
    if (!last_slash) { free(tmp); return NULL; }

    *last_slash = '\0';
    char *result = strdup(tmp);
    free(tmp);
    return result;
}

static int compare_snapshots(const void *a, const void *b)
{
    const snapshot_t *sa = (const snapshot_t *)a;
    const snapshot_t *sb = (const snapshot_t *)b;
    if (sa->date_epoch < sb->date_epoch) return -1;
    if (sa->date_epoch > sb->date_epoch) return  1;
    return 0;
}

static int discover_local(const source_t *src,
                          snapshot_t **out, int *count)
{
    char latest_target[PATH_MAX];
    ssize_t len = readlink(src->dest, latest_target, sizeof(latest_target) - 1);
    if (len < 0) return -1;
    latest_target[len] = '\0';

    const char *resolved_path;
    char target_copy[PATH_MAX];

    if (latest_target[0] == '/') {
        resolved_path = latest_target;
    } else {
        char *parent = get_parent_dir(src->dest);
        if (!parent) return -1;
        snprintf(target_copy, sizeof(target_copy), "%s/%s", parent, latest_target);
        free(parent);
        resolved_path = target_copy;
    }

    char *backup_root = get_parent_dir(resolved_path);
    if (!backup_root) return -1;

    DIR *dir = opendir(backup_root);
    if (!dir) { free(backup_root); return -1; }

    int capacity = 32;
    int n = 0;
    snapshot_t *arr = malloc((size_t)capacity * sizeof(snapshot_t));
    if (!arr) { closedir(dir); free(backup_root); return -1; }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.' && (entry->d_name[1] == '\0' ||
            (entry->d_name[1] == '.' && entry->d_name[2] == '\0')))
            continue;
        if (strcmp(entry->d_name, "latest") == 0) continue;

        int64_t epoch = parse_snapshot_date(entry->d_name);
        if (epoch < 0) continue;

        char full_path[PATH_MAX];
        snprintf(full_path, sizeof(full_path), "%s/%s",
                 backup_root, entry->d_name);

        struct stat st;
        if (stat(full_path, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;

        if (n >= capacity) {
            capacity *= 2;
            snapshot_t *tmp = realloc(arr,
                                      (size_t)capacity * sizeof(snapshot_t));
            if (!tmp) { free(arr); closedir(dir); free(backup_root); return -1; }
            arr = tmp;
        }

        str_copy(arr[n].name, sizeof(arr[n].name), entry->d_name);
        str_copy(arr[n].full_path, sizeof(arr[n].full_path), full_path);
        arr[n].date_epoch = epoch;
        n++;
    }

    closedir(dir);
    free(backup_root);

    if (n > 0) qsort(arr, (size_t)n, sizeof(snapshot_t), compare_snapshots);

    *out   = arr;
    *count = n;
    return 0;
}

static int discover_remote(const source_t *src,
                           snapshot_t **out, int *count)
{
    char *rl_argv[24];
    char  rl_pool[SSH_CMD_MAX];
    pid_t rl_pid = -1;

    if (ssh_build_readlink_argv(src, src->dest, rl_argv, 24,
                                rl_pool, sizeof rl_pool) != 0)
        return -1;

    FILE *fp = ssh_spawn_capture(rl_argv, &rl_pid);
    if (!fp) return -1;

    char latest_target[PATH_MAX];
    if (!fgets(latest_target, sizeof(latest_target), fp)) {
        ssh_spawn_reap(fp, rl_pid);
        return -1;
    }
    ssh_spawn_reap(fp, rl_pid);
    str_trim(latest_target);

    char *backup_root = get_parent_dir(latest_target);
    if (!backup_root) return -1;

    char *ls_argv[24];
    char  ls_pool[SSH_CMD_MAX];
    pid_t ls_pid = -1;
    if (ssh_build_ls_argv(src, backup_root, ls_argv, 24,
                          ls_pool, sizeof ls_pool) != 0) {
        free(backup_root);
        return -1;
    }

    fp = ssh_spawn_capture(ls_argv, &ls_pid);
    if (!fp) { free(backup_root); return -1; }

    int capacity = 32;
    int n = 0;
    snapshot_t *arr = malloc((size_t)capacity * sizeof(snapshot_t));
    if (!arr) { ssh_spawn_reap(fp, ls_pid); free(backup_root); return -1; }

    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        str_trim(line);

        if (strcmp(line, "latest") == 0) continue;

        int64_t epoch = parse_snapshot_date(line);
        if (epoch < 0) continue;

        char full_path[PATH_MAX];
        snprintf(full_path, sizeof(full_path), "%s/%s", backup_root, line);

        if (n >= capacity) {
            capacity *= 2;
            snapshot_t *tmp = realloc(arr,
                                      (size_t)capacity * sizeof(snapshot_t));
            if (!tmp) { free(arr); ssh_spawn_reap(fp, ls_pid); free(backup_root); return -1; }
            arr = tmp;
        }

        str_copy(arr[n].name, sizeof(arr[n].name), line);
        str_copy(arr[n].full_path, sizeof(arr[n].full_path), full_path);
        arr[n].date_epoch = epoch;
        n++;
    }

    ssh_spawn_reap(fp, ls_pid);
    free(backup_root);

    if (n > 0) qsort(arr, (size_t)n, sizeof(snapshot_t), compare_snapshots);

    *out   = arr;
    *count = n;
    return 0;
}

int rsyncx_discover(const source_t *src, snapshot_t **out, int *count)
{
    if (!src || !out || !count) return -1;

    if (src->type == SOURCE_LOCAL) {
        return discover_local(src, out, count);
    } else {
        return discover_remote(src, out, count);
    }
}
