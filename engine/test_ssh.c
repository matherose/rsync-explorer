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

    assert(ssh_build_find_cmd(&src, "/backup/snap1", -1, NULL, "needle",
                              cmd, sizeof cmd) == 0);
    assert(strstr(cmd, "ControlMaster=auto") != NULL);
    assert(strstr(cmd, "ControlPath=")       != NULL);
    assert(strstr(cmd, "ControlPersist=")    != NULL);
    assert(strstr(cmd, "-name \"needle\"")   != NULL);

    printf("PASS: ssh find cmd enables multiplexing\n");
    return 0;
}
