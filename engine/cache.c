/**
 * @file cache.c
 * @brief Per-snapshot scan cache: persists file_entry_t listings to disk.
 *
 * rsync --link-dest snapshots are immutable once written, so a snapshot's
 * listing is scanned at most once and then served from this cache forever.
 * Format: zlib (gzFile) stream — magic "RXSC", u32 version, u64 count, then
 * per record: u16 path_len + bytes, u8 user_len + bytes, u8 group_len +
 * bytes, u64 inode, u64 size, i64 mtime, u32 mode, u32 nlink, u8 is_dir.
 * Native endianness: the cache is machine-local, not a portable format.
 */

#include "engine_internal.h"
#include <zlib.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>

#define CACHE_MAGIC   "RXSC"
#define CACHE_VERSION 1u

static int cache_root(char *out, size_t out_size)
{
    const char *env = getenv("RSYNCX_CACHE_DIR");
    if (env && env[0]) { str_copy(out, out_size, env); return 0; }
    const char *home = getenv("HOME");
    if (!home || !home[0]) return -1;
    int n = snprintf(out, out_size, "%s/Library/Caches/rsync-explorer", home);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

static void sanitize(const char *in, char *out, size_t out_size)
{
    size_t i = 0;
    for (; in[i] && i + 1 < out_size; i++) {
        unsigned char c = (unsigned char)in[i];
        out[i] = (isalnum(c) || c == '-' || c == '.') ? (char)c : '_';
    }
    out[i] = '\0';
}

static int cache_source_dir(const source_t *src, char *out, size_t out_size)
{
    char root[768], host[128], dest[512];
    if (cache_root(root, sizeof root) != 0) return -1;
    sanitize(src->host[0] ? src->host : "local", host, sizeof host);
    sanitize(src->dest, dest, sizeof dest);
    int n = snprintf(out, out_size, "%s/%s_%s", root, host, dest);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

static int mkdir_ok(const char *path)
{
    return (mkdir(path, 0755) == 0 || errno == EEXIST) ? 0 : -1;
}

static int cache_mkdirs(const source_t *src, char *dir, size_t dir_size)
{
    char root[768];
    if (cache_root(root, sizeof root) != 0) return -1;
    if (mkdir_ok(root) != 0) return -1;
    if (cache_source_dir(src, dir, dir_size) != 0) return -1;
    return mkdir_ok(dir);
}

static int cache_file_path(const source_t *src, const snapshot_t *snap,
                           char *out, size_t out_size)
{
    char dir[1024];
    if (cache_source_dir(src, dir, sizeof dir) != 0) return -1;
    int n = snprintf(out, out_size, "%s/%s.scan", dir, snap->name);
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

int cache_write(const source_t *src, const snapshot_t *snap,
                const file_entry_array_t *a)
{
    char dir[1024], path[1200], tmp[1240];
    if (cache_mkdirs(src, dir, sizeof dir) != 0) return -1;
    if (cache_file_path(src, snap, path, sizeof path) != 0) return -1;
    int n = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (n <= 0 || (size_t)n >= sizeof tmp) return -1;

    gzFile gz = gzopen(tmp, "wb6");
    if (!gz) return -1;

    uint32_t version = CACHE_VERSION;
    uint64_t count = (uint64_t)a->count;
    int ok = gzwrite(gz, CACHE_MAGIC, 4) == 4 &&
             gzwrite(gz, &version, sizeof version) == (int)sizeof version &&
             gzwrite(gz, &count, sizeof count) == (int)sizeof count;

    for (int i = 0; ok && i < a->count; i++) {
        const file_entry_t *fe = &a->data[i];
        uint16_t plen = (uint16_t)strlen(fe->rel_path);
        uint8_t  ulen = (uint8_t)strlen(fe->user);
        uint8_t  glen = (uint8_t)strlen(fe->group);
        ok = gzwrite(gz, &plen, 2) == 2 &&
             gzwrite(gz, fe->rel_path, plen) == (int)plen &&
             gzwrite(gz, &ulen, 1) == 1 &&
             (ulen == 0 || gzwrite(gz, fe->user, ulen) == (int)ulen) &&
             gzwrite(gz, &glen, 1) == 1 &&
             (glen == 0 || gzwrite(gz, fe->group, glen) == (int)glen) &&
             gzwrite(gz, &fe->inode, 8) == 8 &&
             gzwrite(gz, &fe->size, 8) == 8 &&
             gzwrite(gz, &fe->mtime, 8) == 8 &&
             gzwrite(gz, &fe->mode, 4) == 4 &&
             gzwrite(gz, &fe->nlink, 4) == 4 &&
             gzwrite(gz, &fe->is_dir, 1) == 1;
    }

    if (gzclose(gz) != Z_OK) ok = 0;
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int gzread_exact(gzFile gz, void *buf, unsigned len)
{
    return gzread(gz, buf, len) == (int)len ? 0 : -1;
}

int cache_read(const source_t *src, const snapshot_t *snap,
               file_entry_array_t *out)
{
    if (fe_array_init(out) != 0) return -1;

    char path[1200];
    if (cache_file_path(src, snap, path, sizeof path) != 0) return -1;

    gzFile gz = gzopen(path, "rb");
    if (!gz) return -1;

    char magic[4];
    uint32_t version = 0;
    uint64_t count = 0;
    if (gzread_exact(gz, magic, 4) != 0 || memcmp(magic, CACHE_MAGIC, 4) != 0 ||
        gzread_exact(gz, &version, sizeof version) != 0 || version != CACHE_VERSION ||
        gzread_exact(gz, &count, sizeof count) != 0 || count > (uint64_t)1 << 31)
        goto fail;

    for (uint64_t i = 0; i < count; i++) {
        file_entry_t fe;
        memset(&fe, 0, sizeof fe);
        uint16_t plen; uint8_t ulen, glen;
        if (gzread_exact(gz, &plen, 2) != 0 || plen == 0 ||
            plen >= sizeof fe.rel_path) goto fail;
        if (gzread_exact(gz, fe.rel_path, plen) != 0) goto fail;
        if (gzread_exact(gz, &ulen, 1) != 0 || ulen >= sizeof fe.user) goto fail;
        if (ulen && gzread_exact(gz, fe.user, ulen) != 0) goto fail;
        if (gzread_exact(gz, &glen, 1) != 0 || glen >= sizeof fe.group) goto fail;
        if (glen && gzread_exact(gz, fe.group, glen) != 0) goto fail;
        if (gzread_exact(gz, &fe.inode, 8) != 0 ||
            gzread_exact(gz, &fe.size, 8) != 0 ||
            gzread_exact(gz, &fe.mtime, 8) != 0 ||
            gzread_exact(gz, &fe.mode, 4) != 0 ||
            gzread_exact(gz, &fe.nlink, 4) != 0 ||
            gzread_exact(gz, &fe.is_dir, 1) != 0) goto fail;
        if (!rel_path_safe(fe.rel_path)) goto fail;
        if (fe_array_push(out, &fe) != 0) goto fail;
    }

    /* must be exactly at EOF */
    { char extra; if (gzread(gz, &extra, 1) != 0) goto fail; }
    gzclose(gz);
    return 0;

fail:
    gzclose(gz);
    fe_array_free(out);
    fe_array_init(out);
    return -1;
}

void cache_housekeep(const source_t *src, const snapshot_t *snaps, int count)
{
    char dir[1024];
    if (cache_source_dir(src, dir, sizeof dir) != 0) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        const char *dot = strrchr(e->d_name, '.');
        int live = 0;
        if (dot && strcmp(dot, ".scan") == 0) {
            size_t stem = (size_t)(dot - e->d_name);
            for (int i = 0; i < count; i++) {
                if (strlen(snaps[i].name) == stem &&
                    strncmp(e->d_name, snaps[i].name, stem) == 0) { live = 1; break; }
            }
        }
        if (!live) {
            char p[1300];
            int n = snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
            if (n > 0 && (size_t)n < sizeof p) unlink(p);
        }
    }
    closedir(d);
}
