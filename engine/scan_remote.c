/**
 * @file scan_remote.c
 * @brief Remote directory scanning via SSH + find -printf.
 *        Uses parallel SSH connections for multi-snapshot scans.
 */

#include "engine_internal.h"
#include <sys/wait.h>

static int parse_find_line(const char *line, file_entry_t *fe)
{
    char buf[2048];
    str_copy(buf, sizeof(buf), line);

    char *fields[9] = {0};
    int field_count = 0;

    char *tok = buf;
    for (int i = 0; i < 9; i++) {
        fields[i] = tok;
        if (i == 8) {   /* %P is last and may itself contain tabs */
            str_trim(tok);
            field_count++;
            break;
        }
        char *tab = strchr(tok, '\t');
        if (!tab) break;
        *tab = '\0';
        tok = tab + 1;
        field_count++;
    }

    if (field_count < 9) return -1;
    if (fields[8][0] == '\0') return -1;

    memset(fe, 0, sizeof(*fe));

    fe->inode = (uint64_t)strtoull(fields[0], NULL, 10);
    fe->mode  = (uint32_t)strtoul(fields[1], NULL, 8);
    str_copy(fe->user, sizeof(fe->user), fields[2]);
    str_copy(fe->group, sizeof(fe->group), fields[3]);
    fe->size  = (uint64_t)strtoull(fields[4], NULL, 10);
    fe->mtime = (int64_t)strtoll(fields[5], NULL, 10);
    fe->nlink = (uint32_t)strtoul(fields[6], NULL, 10);
    str_copy(fe->rel_path, sizeof(fe->rel_path), fields[8]);

    fe->is_dir = (fields[7][0] == 'd') ? 1 : 0;   /* %y type letter */
    if (fe->is_dir) fe->size = 0;

    return 0;
}

/** Parse find output from a FILE* into a file_entry_array_t. */
static int parse_find_output(FILE *fp, file_entry_array_t *out)
{
    char line[2048];
    while (fgets(line, sizeof(line), fp)) {
        str_trim(line);
        if (line[0] == '\0') continue;

        file_entry_t fe;
        if (parse_find_line(line, &fe) != 0) continue;

        if (fe_array_push(out, &fe) != 0) {
            return -1;
        }
    }
    return 0;
}

int scan_dir_remote(const source_t *src, const char *abs_path,
                    file_entry_array_t *out)
{
    char *argv[24];
    char  pool[SSH_CMD_MAX];
    pid_t pid = -1;
    if (ssh_build_find_argv(src, abs_path, 1, NULL, NULL,
                            argv, 24, pool, sizeof pool) != 0)
        return -1;

    FILE *fp = ssh_spawn_capture(argv, &pid);
    if (!fp) return -1;

    int rc = parse_find_output(fp, out);
    ssh_spawn_reap(fp, pid);
    return rc;
}

/**
 * Scan multiple snapshots in parallel using fork + pipe.
 * Each snapshot gets its own SSH process; we fork children that
 * write parsed binary file_entry_t records to pipes.
 * The parent reads all pipes concurrently.
 */
int scan_dir_remote_parallel(const source_t *src,
                             const snapshot_t *snaps,
                             int snap_count,
                             const char *rel_path,
                             file_entry_array_t *out_arrays)
{
    /* Per-snapshot pipes; ok[i] tracks whether pipe() succeeded */
    int  ok[64];
    int  pipes[64][2];  /* pipe[i]: child writes, parent reads */
    pid_t pids[64];

    /* Cap parallelism to avoid overwhelming SSH */
    int max_parallel = snap_count;
    if (max_parallel > 64) max_parallel = 64;

    for (int i = 0; i < max_parallel; i++) {
        ok[i] = (pipe(pipes[i]) == 0);
    }

    /* Fork children — each builds its own SSH find argv, runs it (no shell),
       parses output, writes binary file_entry_t records to its pipe */
    for (int i = 0; i < max_parallel; i++) {
        if (!ok[i]) {
            /* pipe() failed — skip */
            pids[i] = -1;
            continue;
        }

        pids[i] = fork();
        if (pids[i] < 0) {
            /* Fork failed — skip this snapshot */
            close(pipes[i][0]);
            close(pipes[i][1]);
            pids[i] = -1;
            continue;
        }

        if (pids[i] == 0) {
            /* ── CHILD ── */
            close(pipes[i][0]);  /* close read end */

            char abs_path[2048];
            if (rel_path[0] == '\0' || strcmp(rel_path, "/") == 0) {
                str_copy(abs_path, sizeof(abs_path), snaps[i].full_path);
            } else {
                snprintf(abs_path, sizeof(abs_path), "%s/%s",
                         snaps[i].full_path, rel_path);
            }

            char *argv[24];
            char  pool[SSH_CMD_MAX];
            pid_t gpid = -1;
            if (ssh_build_find_argv(src, abs_path, 1, NULL, NULL,
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

                /* Write binary record to pipe */
                ssize_t w = write(pipes[i][1], &fe, sizeof(fe));
                (void)w;  /* best effort */
            }

            ssh_spawn_reap(fp, gpid);
            close(pipes[i][1]);
            _exit(0);
        }

        /* ── PARENT ── */
        close(pipes[i][1]);  /* close write end */
    }

    /* Parent: read binary records from each child pipe */
    for (int i = 0; i < max_parallel; i++) {
        if (pids[i] < 0) continue;

        FILE *fp = fdopen(pipes[i][0], "r");
        if (fp) {
            file_entry_t fe;
            while (fread(&fe, sizeof(fe), 1, fp) == 1) {
                fe_array_push(&out_arrays[i], &fe);
            }
            fclose(fp);
        }
    }

    /* Reap all children */
    for (int i = 0; i < max_parallel; i++) {
        if (pids[i] > 0) {
            int status = 0;
            waitpid(pids[i], &status, 0);
        }
    }

    return 0;
}
