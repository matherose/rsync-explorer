/**
 * @file test_ssh.c
 * @brief Verifies ssh command builders enable connection multiplexing.
 */
#include "engine_internal.h"
#include <assert.h>

int main(void)
{
    source_t src = rsyncx_make_source("r", SOURCE_REMOTE,
                                      "/backup", "host.example", "user",
                                      "/home/user/.ssh/id_ed25519");
    char cmd[SSH_CMD_MAX];

    /* find: multiplexing options + the exact ControlPath literal (guards %%C) + the name filter */
    assert(ssh_build_find_cmd(&src, "/backup/snap1", -1, NULL, "needle",
                              cmd, sizeof cmd) == 0);
    assert(strstr(cmd, "ControlMaster=auto") != NULL);
    assert(strstr(cmd, "ControlPersist=")    != NULL);
    assert(strstr(cmd, "ControlPath=/tmp/rsyncx-ssh-%C") != NULL);
    assert(strstr(cmd, "-name \"needle\"")   != NULL);

    /* ls: same multiplexing options */
    assert(ssh_build_ls_cmd(&src, "/backup/snap1", cmd, sizeof cmd) == 0);
    assert(strstr(cmd, "ControlMaster=auto") != NULL);
    assert(strstr(cmd, "ControlPath=/tmp/rsyncx-ssh-%C") != NULL);

    /* readlink: same multiplexing options */
    assert(ssh_build_readlink_cmd(&src, "/backup/latest", cmd, sizeof cmd) == 0);
    assert(strstr(cmd, "ControlMaster=auto") != NULL);
    assert(strstr(cmd, "ControlPath=/tmp/rsyncx-ssh-%C") != NULL);

    printf("PASS: ssh builders enable multiplexing\n");
    return 0;
}
