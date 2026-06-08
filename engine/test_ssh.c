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

    /* ── ssh_shell_quote ── */
    char q[256];
    assert(ssh_shell_quote("abc", q, sizeof q) == 0);
    assert(strcmp(q, "'abc'") == 0);
    assert(ssh_shell_quote("a'b", q, sizeof q) == 0);
    assert(strcmp(q, "'a'\\''b'") == 0);
    assert(ssh_shell_quote("x; rm -rf ~", q, sizeof q) == 0);
    assert(strcmp(q, "'x; rm -rf ~'") == 0);
    /* tiny buffer must fail, not overflow */
    char tiny[2];
    assert(ssh_shell_quote("abc", tiny, sizeof tiny) == -1);

    /* ── ssh_build_find_argv ── */
    char *av[24];
    char pool[SSH_CMD_MAX];
    assert(ssh_build_find_argv(&src, "/backup/snap1", 1, NULL, "nee'dle",
                               av, 24, pool, sizeof pool) == 0);
    assert(strcmp(av[0], "ssh") == 0);
    /* find the NULL terminator; last two real args are user@host then remote-cmd */
    int kk = 0; while (av[kk]) kk++;
    const char *remote = av[kk - 1];
    const char *uhost  = av[kk - 2];
    assert(strstr(uhost, "user@host.example") != NULL);
    assert(strstr(remote, "find '/backup/snap1'") != NULL);
    /* the single quote in the query is escaped as '\'' */
    assert(strstr(remote, "-name 'nee'\\''dle'") != NULL);
    /* multiplexing option present as a discrete argv element */
    int has_cm = 0;
    for (int j = 0; j < kk; j++)
        if (strstr(av[j], "ControlMaster=auto")) has_cm = 1;
    assert(has_cm == 1);
    /* the ssh OPTIONS must NOT have leaked into the remote command string */
    assert(strstr(remote, "ControlMaster") == NULL);
    assert(strstr(remote, "ssh ") == NULL);

    /* ── ssh_build_ls_argv ── */
    char *lv[24];
    char lpool[SSH_CMD_MAX];
    assert(ssh_build_ls_argv(&src, "/backup/la'test", lv, 24, lpool, sizeof lpool) == 0);
    assert(strcmp(lv[0], "ssh") == 0);
    int lk = 0; while (lv[lk]) lk++;
    assert(strstr(lv[lk - 1], "ls -1 '/backup/la'\\''test'") != NULL);
    assert(strstr(lv[lk - 1], "ControlMaster") == NULL);

    /* ── ssh_build_readlink_argv ── */
    char *rv[24];
    char rpool[SSH_CMD_MAX];
    assert(ssh_build_readlink_argv(&src, "/backup/latest", rv, 24, rpool, sizeof rpool) == 0);
    assert(strcmp(rv[0], "ssh") == 0);
    int rk = 0; while (rv[rk]) rk++;
    assert(strstr(rv[rk - 1], "readlink -f '/backup/latest'") != NULL);

    printf("PASS: ssh builders + argv + quoting\n");
    return 0;
}
