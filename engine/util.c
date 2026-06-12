/**
 * @file util.c
 * @brief Internal utility functions: dynamic arrays, string duplication,
 *        bitmap operations, and epoch-to-date formatting.
 */

#include "engine_internal.h"

/* ── file_entry_array functions ── */

int fe_array_init(file_entry_array_t *arr)
{
    arr->capacity = 128;
    arr->count    = 0;
    arr->data     = malloc((size_t)arr->capacity * sizeof(file_entry_t));
    return arr->data ? 0 : -1;
}

int fe_array_push(file_entry_array_t *arr, const file_entry_t *item)
{
    if (arr->count >= arr->capacity) {
        arr->capacity *= 2;
        file_entry_t *tmp = realloc(arr->data,
                                    (size_t)arr->capacity * sizeof(file_entry_t));
        if (!tmp) return -1;
        arr->data = tmp;
    }
    arr->data[arr->count++] = *item;
    return 0;
}

void fe_array_free(file_entry_array_t *arr)
{
    free(arr->data);
    arr->data     = NULL;
    arr->count    = 0;
    arr->capacity = 0;
}

/* ── String helpers ── */

void str_copy(char *dst, size_t dst_size, const char *src)
{
    if (!src || !dst || dst_size == 0) return;
    strncpy(dst, src, dst_size - 1);
    dst[dst_size - 1] = '\0';
}

void str_trim(char *s)
{
    if (!s) return;
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' ||
                       s[len - 1] == ' '  || s[len - 1] == '\t')) {
        s[--len] = '\0';
    }
}

/* ── Epoch formatting ── */

int epoch_to_str(int64_t epoch, char *out, size_t out_size)
{
    if (epoch < 0) {
        str_copy(out, out_size, "—");
        return 0;
    }
    time_t t = (time_t)epoch;
    struct tm tm_buf;
    if (!localtime_r(&t, &tm_buf)) return -1;
    strftime(out, out_size, "%Y-%m-%d %H:%M", &tm_buf);
    return 0;
}

void mode_to_str(uint32_t mode, char *out, size_t out_size)
{
    if (out_size < 11) return;

    out[0] = S_ISDIR(mode) ? 'd' :
             S_ISLNK(mode) ? 'l' : '-';

    out[1] = (mode & S_IRUSR) ? 'r' : '-';
    out[2] = (mode & S_IWUSR) ? 'w' : '-';
    out[3] = (mode & S_IXUSR) ? 'x' : '-';
    out[4] = (mode & S_IRGRP) ? 'r' : '-';
    out[5] = (mode & S_IWGRP) ? 'w' : '-';
    out[6] = (mode & S_IXGRP) ? 'x' : '-';
    out[7] = (mode & S_IROTH) ? 'r' : '-';
    out[8] = (mode & S_IWOTH) ? 'w' : '-';
    out[9] = (mode & S_IXOTH) ? 'x' : '-';
    out[10] = '\0';

    if (mode & S_ISUID) out[3] = (mode & S_IXUSR) ? 's' : 'S';
    if (mode & S_ISGID) out[6] = (mode & S_IXGRP) ? 's' : 'S';
    if (mode & S_ISVTX) out[9] = (mode & S_IXOTH) ? 't' : 'T';
}

/* ── rsyncx_free ── */

const char *rsyncx_source_name(const source_t *s)    { return s->name; }
const char *rsyncx_source_dest(const source_t *s)    { return s->dest; }
const char *rsyncx_source_host(const source_t *s)    { return s->host; }
const char *rsyncx_source_user(const source_t *s)    { return s->user; }
const char *rsyncx_source_ssh_key(const source_t *s) { return s->ssh_key; }

const char *rsyncx_snapshot_name(const snapshot_t *s)      { return s->name; }
const char *rsyncx_snapshot_full_path(const snapshot_t *s) { return s->full_path; }

const char *rsyncx_lc_rel_path(const lifecycle_t *lc)       { return lc->rel_path; }
const char *rsyncx_lc_user(const lifecycle_t *lc)            { return lc->user; }
const char *rsyncx_lc_group(const lifecycle_t *lc)           { return lc->group; }
const char *rsyncx_lc_last_real_path(const lifecycle_t *lc)  { return lc->last_real_path; }

const char *rsyncx_dir_name(const dir_entry_t *d) { return d->name; }

source_t rsyncx_make_source(const char *name, int type,
                            const char *dest, const char *host,
                            const char *user, const char *ssh_key)
{
    source_t s;
    memset(&s, 0, sizeof(s));
    snprintf(s.name,    sizeof(s.name),    "%s", name    ? name    : "");
    snprintf(s.dest,    sizeof(s.dest),    "%s", dest    ? dest    : "");
    snprintf(s.host,    sizeof(s.host),    "%s", host    ? host    : "");
    snprintf(s.user,    sizeof(s.user),    "%s", user    ? user    : "");
    snprintf(s.ssh_key, sizeof(s.ssh_key), "%s", ssh_key ? ssh_key : "");
    s.type = (source_type_t)type;
    return s;
}

snapshot_t rsyncx_make_snapshot(const char *name, const char *full_path,
                                int64_t date_epoch)
{
    snapshot_t s;
    memset(&s, 0, sizeof(s));
    snprintf(s.name,      sizeof(s.name),      "%s", name      ? name      : "");
    snprintf(s.full_path, sizeof(s.full_path), "%s", full_path ? full_path : "");
    s.date_epoch = date_epoch;
    return s;
}

void rsyncx_free(void *ptr)
{
    free(ptr);
}
