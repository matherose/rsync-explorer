/**
 * @file search.c
 * @brief Global recursive search across all snapshots.
 *        Remote searches run in parallel via fork+pipe.
 */

#include "engine_internal.h"
#include <fts.h>
#include <pthread.h>
#include <sys/wait.h>

#define MAX_LOCAL_THREADS 64

static int parse_find_line(const char *line, file_entry_t *fe)
{
    char buf[2048];
    str_copy(buf, sizeof(buf), line);

    char *fields[8] = {0};
    int field_count = 0;
    char *tok = buf;
    for (int i = 0; i < 8; i++) {
        fields[i] = tok;
        char *tab = strchr(tok, '\t');
        if (tab) { *tab = '\0'; tok = tab + 1; field_count++; }
        else { str_trim(tok); field_count++; break; }
    }

    if (field_count < 8) return -1;
    if (fields[7][0] == '\0') return -1;

    memset(fe, 0, sizeof(*fe));
    fe->inode = (uint64_t)strtoull(fields[0], NULL, 10);
    fe->mode  = (uint32_t)strtoul(fields[1], NULL, 8);
    str_copy(fe->user, sizeof(fe->user), fields[2]);
    str_copy(fe->group, sizeof(fe->group), fields[3]);
    fe->size  = (uint64_t)strtoull(fields[4], NULL, 10);
    fe->mtime = (int64_t)strtoll(fields[5], NULL, 10);
    fe->nlink = (uint32_t)strtoul(fields[6], NULL, 10);
    str_copy(fe->rel_path, sizeof(fe->rel_path), fields[7]);

    fe->is_dir = S_ISDIR(fe->mode) ? 1 : 0;
    if (fe->is_dir) fe->size = 0;

    return 0;
}

static int search_local(const char *snapshot_path,
                        const char *query,
                        file_entry_array_t *out)
{
    char *paths[] = { (char *)snapshot_path, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) return -1;

    size_t base_len = strlen(snapshot_path);

    FTSENT *ent;
    while ((ent = fts_read(fts)) != NULL) {
        /* Skip directories (pre- and post-order) and unreadable entries. */
        if (ent->fts_info == FTS_D  || ent->fts_info == FTS_DP ||
            ent->fts_info == FTS_DNR || ent->fts_info == FTS_ERR ||
            ent->fts_info == FTS_NS)
            continue;

        /* Match the filename like `find -name "*query*"` (case-sensitive). */
        if (query[0] != '\0' && strstr(ent->fts_name, query) == NULL)
            continue;

        const struct stat *st = ent->fts_statp;
        if (S_ISDIR(st->st_mode)) continue;   /* -not -type d */

        file_entry_t fe;
        memset(&fe, 0, sizeof(fe));

        /* rel_path = path relative to the snapshot root (like find's %P). */
        const char *rel = ent->fts_path + base_len;
        while (*rel == '/') rel++;
        str_copy(fe.rel_path, sizeof(fe.rel_path), rel);

        fe.inode = (uint64_t)st->st_ino;
        fe.mode  = (uint32_t)st->st_mode;
        fe.size  = (uint64_t)st->st_size;
        fe.mtime = (int64_t)st->st_mtime;
        fe.nlink = (uint32_t)st->st_nlink;
        fe.is_dir = 0;

        resolve_user(st->st_uid, fe.user, sizeof(fe.user));
        resolve_group(st->st_gid, fe.group, sizeof(fe.group));

        if (fe_array_push(out, &fe) != 0) {
            fts_close(fts);
            return -1;
        }
    }

    fts_close(fts);
    return 0;
}

typedef struct {
    const char         *snapshot_path;
    const char         *query;
    file_entry_array_t *out;
    int                 rc;
} local_search_job_t;

static void *local_search_worker(void *arg)
{
    local_search_job_t *job = (local_search_job_t *)arg;
    job->rc = search_local(job->snapshot_path, job->query, job->out);
    return NULL;
}

/**
 * Parallel remote search: fork one child per snapshot, each runs
 * SSH find, parses results, writes binary file_entry_t to a pipe.
 * Parent reads all pipes concurrently.
 */
int rsyncx_search(const source_t *src,
                  const snapshot_t *snaps, int snap_count,
                  const char *query,
                  int from_idx, int to_idx,
                  lifecycle_t **out, int *count)
{
    if (!src || !snaps || !out || !count || !query) return -1;
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

    for (int i = 0; i < range_len; i++) {
        fe_array_init(&snap_arrays[i]);
    }

    int result = 0;

    if (src->type == SOURCE_REMOTE) {
        /* ── PARALLEL REMOTE SEARCH ── */
        int   ok[64];
        int   pipes[64][2];
        pid_t pids[64];
        int   n = range_len > 64 ? 64 : range_len;

        for (int i = 0; i < n; i++) {
            ok[i] = (pipe(pipes[i]) == 0);
        }

        for (int i = 0; i < n; i++) {
            if (!ok[i]) {
                pids[i] = -1;
                continue;
            }

            pids[i] = fork();
            if (pids[i] < 0) {
                close(pipes[i][0]);
                close(pipes[i][1]);
                pids[i] = -1;
                continue;
            }

            if (pids[i] == 0) {
                /* ── CHILD ── */
                close(pipes[i][0]);

                char *argv[24];
                char  pool[SSH_CMD_MAX];
                pid_t gpid = -1;
                if (ssh_build_find_argv(src, snaps[from_idx + i].full_path,
                                        -1, NULL, query,
                                        argv, 24, pool, sizeof pool) != 0) {
                    close(pipes[i][1]);
                    _exit(1);
                }

                FILE *fp = ssh_spawn_capture(argv, &gpid);
                if (!fp) {
                    close(pipes[i][1]);
                    _exit(1);
                }

                char line[2048];
                while (fgets(line, sizeof(line), fp)) {
                    str_trim(line);
                    if (line[0] == '\0') continue;

                    file_entry_t fe;
                    if (parse_find_line(line, &fe) != 0) continue;
                    if (fe.is_dir) continue;

                    write(pipes[i][1], &fe, sizeof(fe));
                }

                ssh_spawn_reap(fp, gpid);
                close(pipes[i][1]);
                _exit(0);
            }

            /* ── PARENT ── */
            close(pipes[i][1]);
        }

        /* Read binary records from each child */
        for (int i = 0; i < n; i++) {
            if (pids[i] < 0) continue;

            FILE *fp = fdopen(pipes[i][0], "r");
            if (fp) {
                file_entry_t fe;
                while (fread(&fe, sizeof(fe), 1, fp) == 1) {
                    fe_array_push(&snap_arrays[i], &fe);
                }
                fclose(fp);
            }
        }

        /* Reap children */
        for (int i = 0; i < n; i++) {
            if (pids[i] > 0) {
                int status = 0;
                waitpid(pids[i], &status, 0);
            }
        }
    } else {
        /* ── PARALLEL LOCAL SEARCH (bounded concurrency) ── */
        int max_threads = range_len < MAX_LOCAL_THREADS
                        ? range_len : MAX_LOCAL_THREADS;
        pthread_t          *threads = malloc((size_t)max_threads * sizeof(pthread_t));
        local_search_job_t *jobs    = malloc((size_t)range_len   * sizeof(local_search_job_t));

        if (!threads || !jobs) {
            free(threads); free(jobs);
            for (int i = 0; i < range_len; i++) snap_arrays[i].count = 0;
        } else {
            for (int base = 0; base < range_len; base += max_threads) {
                int batch = range_len - base;
                if (batch > max_threads) batch = max_threads;

                /* Launch this wave. threads[j] indexes within the wave;
                   jobs[i] is indexed globally so results land in the right array. */
                for (int j = 0; j < batch; j++) {
                    int i = base + j;
                    jobs[i].snapshot_path = snaps[from_idx + i].full_path;
                    jobs[i].query         = query;
                    jobs[i].out           = &snap_arrays[i];
                    jobs[i].rc            = 0;
                    if (pthread_create(&threads[j], NULL,
                                       local_search_worker, &jobs[i]) != 0) {
                        /* Fall back to running this snapshot inline. */
                        jobs[i].rc = search_local(jobs[i].snapshot_path,
                                                  jobs[i].query, jobs[i].out);
                        threads[j] = 0;
                    }
                }

                /* Join this wave before starting the next. */
                for (int j = 0; j < batch; j++) {
                    if (threads[j] != 0) pthread_join(threads[j], NULL);
                }
            }

            for (int i = 0; i < range_len; i++) {
                if (jobs[i].rc != 0) snap_arrays[i].count = 0;
            }
            free(threads);
            free(jobs);
        }
    }

    if (result == 0) {
        for (int i = 0; i < range_len; i++) {
            snap_entries[i] = snap_arrays[i].data;
            snap_counts[i]  = snap_arrays[i].count;
        }

        classify_entries(snap_entries, snap_counts, range_len,
                         &snaps[from_idx], "", out, count);
    }

    for (int i = 0; i < range_len; i++) {
        fe_array_free(&snap_arrays[i]);
    }
    free(snap_arrays);
    free(snap_entries);
    free(snap_counts);

    return result;
}
