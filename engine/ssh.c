/**
 * @file ssh.c
 * @brief SSH command builder for remote source scanning.
 */

#include "engine_internal.h"

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
