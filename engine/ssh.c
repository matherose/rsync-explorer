/**
 * @file ssh.c
 * @brief SSH command builder for remote source scanning.
 */

#include "engine_internal.h"
#include <sys/wait.h>
#include <unistd.h>

/*
 * Shared ssh options. ControlMaster reuses a single TCP/SSH connection
 * across the per-snapshot searches; ControlPersist keeps the master alive
 * briefly so later invocations attach instead of re-handshaking.
 * %%C expands (via ssh) to a hash of the connection parameters — unique
 * per host, shared across our parallel children. (%% escapes % for snprintf.)
 */
#define SSH_OPTS \
    "-o BatchMode=yes -o StrictHostKeyChecking=no " \
    "-o ControlMaster=auto -o ControlPersist=60 " \
    "-o ControlPath=/tmp/rsyncx-ssh-%%C"

int ssh_build_find_cmd(const source_t *src,
                       const char *find_path,
                       int maxdepth,
                       const char *type_filter,
                       const char *name_filter,
                       char *cmd, size_t cmd_size)
{
    if (src->type != SOURCE_REMOTE) return -1;

    int written;
    size_t pos = 0;

    written = snprintf(cmd + pos, cmd_size - pos,
        "ssh -i %s " SSH_OPTS " %s@%s 'find \"%s\"",
        src->ssh_key, src->user, src->host, find_path);

    if (written < 0 || (size_t)written >= cmd_size - pos) return -1;
    pos += (size_t)written;

    if (maxdepth >= 0) {
        written = snprintf(cmd + pos, cmd_size - pos,
                           " -maxdepth %d", maxdepth);
        if (written < 0 || (size_t)written >= cmd_size - pos) return -1;
        pos += (size_t)written;
    }

    if (type_filter) {
        written = snprintf(cmd + pos, cmd_size - pos,
                           " -type %s", type_filter);
        if (written < 0 || (size_t)written >= cmd_size - pos) return -1;
        pos += (size_t)written;
    }

    if (name_filter) {
        written = snprintf(cmd + pos, cmd_size - pos,
                           " -name \"%s\"", name_filter);
        if (written < 0 || (size_t)written >= cmd_size - pos) return -1;
        pos += (size_t)written;
    }

    written = snprintf(cmd + pos, cmd_size - pos,
        " -printf \"%%i\\t%%m\\t%%u\\t%%g\\t%%s\\t%%T@\\t%%n\\t%%P\\n\"'");

    if (written < 0 || (size_t)written >= cmd_size - pos) return -1;

    return 0;
}

int ssh_build_ls_cmd(const source_t *src,
                     const char *path,
                     char *cmd, size_t cmd_size)
{
    if (src->type != SOURCE_REMOTE) return -1;

    int written = snprintf(cmd, cmd_size,
        "ssh -i %s " SSH_OPTS " %s@%s 'ls -1 \"%s\"'",
        src->ssh_key, src->user, src->host, path);

    if (written < 0 || (size_t)written >= cmd_size) return -1;
    return 0;
}

int ssh_build_readlink_cmd(const source_t *src,
                           const char *path,
                           char *cmd, size_t cmd_size)
{
    if (src->type != SOURCE_REMOTE) return -1;

    int written = snprintf(cmd, cmd_size,
        "ssh -i %s " SSH_OPTS " %s@%s 'readlink -f \"%s\"'",
        src->ssh_key, src->user, src->host, path);

    if (written < 0 || (size_t)written >= cmd_size) return -1;
    return 0;
}

int ssh_shell_quote(const char *in, char *out, size_t out_size)
{
    size_t o = 0;
    if (out_size == 0) return -1;

    if (o + 1 >= out_size) return -1;
    out[o++] = '\'';

    for (const char *p = in; *p; p++) {
        if (*p == '\'') {
            /* close ' , emit \' , reopen ' -> the sequence '\'' */
            if (o + 4 >= out_size) return -1;
            out[o++] = '\'';
            out[o++] = '\\';
            out[o++] = '\'';
            out[o++] = '\'';
        } else {
            if (o + 1 >= out_size) return -1;
            out[o++] = *p;
        }
    }

    if (o + 1 >= out_size) return -1;
    out[o++] = '\'';
    out[o] = '\0';
    return 0;
}

int ssh_build_find_argv(const source_t *src, const char *find_path,
                        int maxdepth, const char *type_filter,
                        const char *name_filter,
                        char **argv, int argv_max,
                        char *pool, size_t pool_size)
{
    if (src->type != SOURCE_REMOTE) return -1;
    if (argv_max < 18) return -1;

    /* pool layout: "user@host\0 remote-command\0" */
    char *userhost = pool;
    int uh = snprintf(userhost, pool_size, "%s@%s", src->user, src->host);
    if (uh < 0 || (size_t)uh >= pool_size) return -1;

    char  *remote     = userhost + uh + 1;
    size_t rem_size   = pool_size - (size_t)(uh + 1);
    size_t pos        = 0;
    int    n;
    char   q[1100];

    if (ssh_shell_quote(find_path, q, sizeof q) != 0) return -1;
    n = snprintf(remote + pos, rem_size - pos, "find %s", q);
    if (n < 0 || (size_t)n >= rem_size - pos) return -1;
    pos += (size_t)n;

    if (maxdepth >= 0) {
        n = snprintf(remote + pos, rem_size - pos, " -maxdepth %d", maxdepth);
        if (n < 0 || (size_t)n >= rem_size - pos) return -1;
        pos += (size_t)n;
    }
    if (type_filter) {
        if (ssh_shell_quote(type_filter, q, sizeof q) != 0) return -1;
        n = snprintf(remote + pos, rem_size - pos, " -type %s", q);
        if (n < 0 || (size_t)n >= rem_size - pos) return -1;
        pos += (size_t)n;
    }
    if (name_filter) {
        if (ssh_shell_quote(name_filter, q, sizeof q) != 0) return -1;
        n = snprintf(remote + pos, rem_size - pos, " -name %s", q);
        if (n < 0 || (size_t)n >= rem_size - pos) return -1;
        pos += (size_t)n;
    }
    if (ssh_shell_quote("%i\\t%m\\t%u\\t%g\\t%s\\t%T@\\t%n\\t%P\\n",
                        q, sizeof q) != 0) return -1;
    n = snprintf(remote + pos, rem_size - pos, " -printf %s", q);
    if (n < 0 || (size_t)n >= rem_size - pos) return -1;
    pos += (size_t)n;

    int k = 0;
    argv[k++] = (char *)"ssh";
    argv[k++] = (char *)"-i";
    argv[k++] = (char *)src->ssh_key;
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"BatchMode=yes";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"StrictHostKeyChecking=no";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlMaster=auto";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPersist=60";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPath=/tmp/rsyncx-ssh-%C";
    argv[k++] = userhost;
    argv[k++] = remote;
    argv[k]   = NULL;
    return 0;
}

int ssh_build_ls_argv(const source_t *src, const char *path,
                      char **argv, int argv_max,
                      char *pool, size_t pool_size)
{
    if (src->type != SOURCE_REMOTE) return -1;
    if (argv_max < 18) return -1;

    char *userhost = pool;
    int uh = snprintf(userhost, pool_size, "%s@%s", src->user, src->host);
    if (uh < 0 || (size_t)uh >= pool_size) return -1;

    char  *remote   = userhost + uh + 1;
    size_t rem_size = pool_size - (size_t)(uh + 1);
    char   q[1100];

    if (ssh_shell_quote(path, q, sizeof q) != 0) return -1;
    int n = snprintf(remote, rem_size, "ls -1 %s", q);
    if (n < 0 || (size_t)n >= rem_size) return -1;

    int k = 0;
    argv[k++] = (char *)"ssh";
    argv[k++] = (char *)"-i";
    argv[k++] = (char *)src->ssh_key;
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"BatchMode=yes";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"StrictHostKeyChecking=no";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlMaster=auto";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPersist=60";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPath=/tmp/rsyncx-ssh-%C";
    argv[k++] = userhost;
    argv[k++] = remote;
    argv[k]   = NULL;
    return 0;
}

int ssh_build_readlink_argv(const source_t *src, const char *path,
                            char **argv, int argv_max,
                            char *pool, size_t pool_size)
{
    if (src->type != SOURCE_REMOTE) return -1;
    if (argv_max < 18) return -1;

    char *userhost = pool;
    int uh = snprintf(userhost, pool_size, "%s@%s", src->user, src->host);
    if (uh < 0 || (size_t)uh >= pool_size) return -1;

    char  *remote   = userhost + uh + 1;
    size_t rem_size = pool_size - (size_t)(uh + 1);
    char   q[1100];

    if (ssh_shell_quote(path, q, sizeof q) != 0) return -1;
    int n = snprintf(remote, rem_size, "readlink -f %s", q);
    if (n < 0 || (size_t)n >= rem_size) return -1;

    int k = 0;
    argv[k++] = (char *)"ssh";
    argv[k++] = (char *)"-i";
    argv[k++] = (char *)src->ssh_key;
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"BatchMode=yes";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"StrictHostKeyChecking=no";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlMaster=auto";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPersist=60";
    argv[k++] = (char *)"-o"; argv[k++] = (char *)"ControlPath=/tmp/rsyncx-ssh-%C";
    argv[k++] = userhost;
    argv[k++] = remote;
    argv[k]   = NULL;
    return 0;
}

FILE *ssh_spawn_capture(char *const argv[], pid_t *out_pid)
{
    int fds[2];
    if (pipe(fds) != 0) return NULL;

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        return NULL;
    }

    if (pid == 0) {
        /* child: redirect stdout to the pipe, exec ssh (no shell) */
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0) _exit(127);
        close(fds[1]);
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }

    /* parent */
    close(fds[1]);
    FILE *fp = fdopen(fds[0], "r");
    if (!fp) {
        close(fds[0]);
        waitpid(pid, NULL, 0);
        return NULL;
    }
    if (out_pid) *out_pid = pid;
    return fp;
}

int ssh_spawn_reap(FILE *fp, pid_t pid)
{
    if (fp) fclose(fp);
    int status = 0;
    if (pid > 0) waitpid(pid, &status, 0);
    return status;
}
