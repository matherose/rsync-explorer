/**
 * @file engine.h
 * @brief Public C API for the rsync-explorer scanning engine.
 *
 * This header defines the complete contract between the C engine
 * and the Swift/AppKit UI layer. All functions return allocated
 * arrays that the caller must free via rsyncx_free().
 */
#pragma once

#include <stdint.h>
#include <stddef.h>

/* ── Source types ── */

/** Source type, inferred from INI section prefix. */
typedef enum {
    SOURCE_LOCAL,   /**< [local.*] section */
    SOURCE_REMOTE   /**< [remote.*] section */
} source_type_t;

/** Parsed source entry from config.ini. */
typedef struct {
    char            name[128];      /**< Name after the dot (e.g. "site1") */
    source_type_t   type;           /**< LOCAL or REMOTE */
    char            dest[512];      /**< Backup root path (contains "latest") */
    char            host[128];      /**< Remote hostname (empty for local) */
    char            user[64];       /**< Remote username (empty for local) */
    char            ssh_key[256];   /**< Path to SSH private key (empty for local) */
} source_t;

/* ── Snapshot types ── */

/** Discovered snapshot directory. */
typedef struct {
    char    name[128];      /**< Directory name, e.g. "2026-06-06_21-29" */
    char    full_path[512]; /**< Absolute path to snapshot directory */
    int64_t date_epoch;     /**< Parsed date as epoch seconds (for sorting) */
} snapshot_t;

/* ── Classification types ── */

/** File lifecycle classification. */
typedef enum {
    CLASS_UNCHANGED,   /**< Hard-linked across snapshots — same inode */
    CLASS_MODIFIED,    /**< Inode changed between snapshots — content differs */
    CLASS_NEW,         /**< First appeared in the latest snapshot */
    CLASS_DELETED,     /**< Present earlier, absent in latest */
    CLASS_DEL_NEW      /**< Deleted then re-created (snapshot mask has gaps) */
} file_class_t;

/** Classified file lifecycle entry. */
typedef struct {
    char         rel_path[512];    /**< Path relative to snapshot root */
    file_class_t class;            /**< Lifecycle classification */
    uint32_t     mode;             /**< st_mode (type + permissions) */
    char         user[64];         /**< Owner name */
    char         group[64];        /**< Group name */
    uint64_t     size;             /**< File size in bytes */
    int64_t      mtime;            /**< Modification time (epoch seconds) */
    int64_t      first_backup;     /**< Epoch of earliest snapshot containing file */
    int64_t      last_backup;      /**< Epoch of latest snapshot containing file */
    int64_t      deleted_in;       /**< Epoch of first snapshot without file, or -1 */
    char         last_real_path[512]; /**< Absolute path in last snapshot that has it */
    uint8_t      is_dir;           /**< 1 if directory, 0 if regular file */
    uint32_t     nlink;            /**< Hard link count */
} lifecycle_t;

/* ── Sidebar tree types ── */

/** Directory entry for the sidebar tree. */
typedef struct {
    char    name[256];          /**< Directory name */
    uint8_t is_dir;             /**< Always 1 for tree entries */
    uint8_t exists_in_latest;   /**< 0 = red badge (deleted), 1 = normal */
} dir_entry_t;

/* ── Engine functions ── */

/**
 * Parse config.ini at the given path.
 *
 * @param path   Path to config.ini.
 * @param out    Output array of source_t (caller frees via rsyncx_free).
 * @param count  Output count of entries.
 * @return 0 on success, -1 on error.
 */
int  rsyncx_parse_config(const char *path, source_t **out, int *count);

/**
 * Discover snapshots for a source.
 *
 * Resolves the "latest" symlink, lists sibling directories,
 * parses date names, and sorts chronologically.
 *
 * @param src    Source to discover snapshots for.
 * @param out    Output array of snapshot_t (caller frees via rsyncx_free).
 * @param count  Output count of entries.
 * @return 0 on success, -1 on error.
 */
int  rsyncx_discover(const source_t *src, snapshot_t **out, int *count);

/**
 * Scan a single directory across snapshots in [from_idx, to_idx].
 *
 * Returns classified lifecycle entries for every file that ever existed
 * at the given relative path within the timeline range.
 *
 * @param src        Source to scan.
 * @param snaps      Snapshot array from rsyncx_discover().
 * @param snap_count Total number of snapshots.
 * @param rel_path   Relative path within snapshot (e.g. "MEDIAS/PHOTO").
 * @param from_idx   Start index in snaps[] (inclusive).
 * @param to_idx     End index in snaps[] (inclusive).
 * @param out        Output array of lifecycle_t (caller frees via rsyncx_free).
 * @param count      Output count of entries.
 * @return 0 on success, -1 on error.
 */
int  rsyncx_scan_dir(const source_t *src,
                     const snapshot_t *snaps, int snap_count,
                     const char *rel_path,
                     int from_idx, int to_idx,
                     lifecycle_t **out, int *count);

/**
 * Expand a directory in the sidebar tree.
 *
 * Returns the union of all subdirectories ever seen at rel_path
 * across snapshots in [from_idx, to_idx].
 *
 * @param src        Source to scan.
 * @param snaps      Snapshot array from rsyncx_discover().
 * @param snap_count Total number of snapshots.
 * @param rel_path   Relative path within snapshot.
 * @param from_idx   Start index in snaps[] (inclusive).
 * @param to_idx     End index in snaps[] (inclusive).
 * @param out        Output array of dir_entry_t (caller frees via rsyncx_free).
 * @param count      Output count of entries.
 * @return 0 on success, -1 on error.
 */
int  rsyncx_expand_tree(const source_t *src,
                        const snapshot_t *snaps, int snap_count,
                        const char *rel_path,
                        int from_idx, int to_idx,
                        dir_entry_t **out, int *count);

/**
 * Search for files by name across the entire backup tree.
 *
 * Recursive scan across all snapshots in [from_idx, to_idx].
 * Returns classified lifecycle entries matching the query.
 *
 * @param src        Source to search.
 * @param snaps      Snapshot array from rsyncx_discover().
 * @param snap_count Total number of snapshots.
 * @param query      Search string (matched against filenames).
 * @param from_idx   Start index in snaps[] (inclusive).
 * @param to_idx     End index in snaps[] (inclusive).
 * @param out        Output array of lifecycle_t (caller frees via rsyncx_free).
 * @param count      Output count of entries.
 * @return 0 on success, -1 on error.
 */
int  rsyncx_search(const source_t *src,
                   const snapshot_t *snaps, int snap_count,
                   const char *query,
                   int from_idx, int to_idx,
                   lifecycle_t **out, int *count);

/**
 * Free memory returned by any engine function.
 *
 * @param ptr Pointer previously returned by an engine function.
 */
/**
 * Get a C string pointer to a source_t field.
 * These are needed because Swift imports char[] as unnamed tuples.
 */
const char *rsyncx_source_name(const source_t *s);
const char *rsyncx_source_dest(const source_t *s);
const char *rsyncx_source_host(const source_t *s);
const char *rsyncx_source_user(const source_t *s);
const char *rsyncx_source_ssh_key(const source_t *s);

/**
 * Get a C string pointer to a snapshot_t field.
 */
const char *rsyncx_snapshot_name(const snapshot_t *s);
const char *rsyncx_snapshot_full_path(const snapshot_t *s);

/**
 * Get C string pointers to lifecycle_t fields.
 */
const char *rsyncx_lc_rel_path(const lifecycle_t *lc);
const char *rsyncx_lc_user(const lifecycle_t *lc);
const char *rsyncx_lc_group(const lifecycle_t *lc);
const char *rsyncx_lc_last_real_path(const lifecycle_t *lc);

/**
 * Get C string pointer to dir_entry_t name field.
 */
const char *rsyncx_dir_name(const dir_entry_t *d);

/**
 * Construct a source_t from individual string values.
 * Copies strings into the fixed-size char arrays safely.
 */
source_t rsyncx_make_source(const char *name, int type,
                            const char *dest, const char *host,
                            const char *user, const char *ssh_key);

/**
 * Construct a snapshot_t from individual string values.
 */
snapshot_t rsyncx_make_snapshot(const char *name, const char *full_path,
                                int64_t date_epoch);

void rsyncx_free(void *ptr);

/* ── In-memory backup index ── */

/** Opaque whole-backup index handle (see index.c). */
typedef struct rsyncx_index rsyncx_index_t;

/**
 * Build the in-memory index over snapshots [from_idx, to_idx].
 * One recursive scan per snapshot (local fts / parallel remote SSH).
 * progress_cb (nullable) is called as snapshots complete:
 *   progress_cb(done_snapshots, total_snapshots, files_so_far, ctx).
 * Returns an index handle (free with rsyncx_index_free), or NULL on error.
 */
rsyncx_index_t *rsyncx_build_index(const source_t *src,
                                   const snapshot_t *snaps, int snap_count,
                                   int from_idx, int to_idx,
                                   void (*progress_cb)(int, int, long, void *),
                                   void *ctx);

/** Free an index built by rsyncx_build_index. */
void rsyncx_index_free(rsyncx_index_t *idx);

/**
 * Children (files AND directories) of directory rel_path ("" = root).
 * Output lifecycle_t[] carry the LEAF name in rel_path. Caller frees via rsyncx_free.
 * Returns 0/-1.
 */
int rsyncx_index_children(const rsyncx_index_t *idx, const char *rel_path,
                          lifecycle_t **out, int *count);
