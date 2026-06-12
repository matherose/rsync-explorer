/**
 * @file config.c
 * @brief Minimal INI parser for rsync-explorer config.
 */

#include "engine_internal.h"

#define CFG_MAX_LINE 1024

static void cfg_set_value(source_t *src, const char *key, const char *value)
{
    if (strcmp(key, "dest") == 0) {
        str_copy(src->dest, sizeof(src->dest), value);
    } else if (strcmp(key, "host") == 0) {
        str_copy(src->host, sizeof(src->host), value);
    } else if (strcmp(key, "user") == 0) {
        str_copy(src->user, sizeof(src->user), value);
    } else if (strcmp(key, "ssh_key") == 0) {
        str_copy(src->ssh_key, sizeof(src->ssh_key), value);
    }
}

static int cfg_parse_section(const char *line, source_t *src)
{
    const char *open  = strchr(line, '[');
    const char *close = strchr(line, ']');
    if (!open || !close || close <= open + 1) return -1;

    size_t len = (size_t)(close - open - 1);
    if (len >= sizeof(src->name) + 8) return -1;

    char section[256];
    memcpy(section, open + 1, len);
    section[len] = '\0';

    const char *dot = strchr(section, '.');
    if (!dot) return -1;

    size_t prefix_len = (size_t)(dot - section);
    char prefix[64];
    memcpy(prefix, section, prefix_len);
    prefix[prefix_len] = '\0';

    const char *name = dot + 1;

    if (strcmp(prefix, "local") == 0) {
        src->type = SOURCE_LOCAL;
    } else if (strcmp(prefix, "remote") == 0) {
        src->type = SOURCE_REMOTE;
    } else {
        return -1;
    }

    str_copy(src->name, sizeof(src->name), name);
    src->dest[0]    = '\0';
    src->host[0]    = '\0';
    src->user[0]    = '\0';
    src->ssh_key[0] = '\0';

    return 0;
}

int rsyncx_parse_config(const char *path, source_t **out, int *count)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;

    int capacity = 16;
    int n        = 0;
    source_t *arr = malloc((size_t)capacity * sizeof(source_t));
    if (!arr) { fclose(fp); return -1; }

    source_t current;
    memset(&current, 0, sizeof(current));
    int in_section = 0;

    char line[CFG_MAX_LINE];
    while (fgets(line, sizeof(line), fp)) {
        str_trim(line);

        if (line[0] == '\0' || line[0] == '#' || line[0] == ';')
            continue;

        if (line[0] == '[') {
            if (in_section && current.dest[0] != '\0') {
                if (n >= capacity) {
                    capacity *= 2;
                    source_t *tmp = realloc(arr,
                                            (size_t)capacity * sizeof(source_t));
                    if (!tmp) { free(arr); fclose(fp); return -1; }
                    arr = tmp;
                }
                arr[n++] = current;
            }

            memset(&current, 0, sizeof(current));
            if (cfg_parse_section(line, &current) != 0) {
                in_section = 0;
                continue;
            }
            in_section = 1;
            continue;
        }

        if (!in_section) continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key   = line;
        char *value = eq + 1;
        /* Trim both sides of key and value */
        str_trim(key);
        char *k = key;
        while (*k == ' ' || *k == '\t') k++;
        str_trim(value);
        char *v = value;
        while (*v == ' ' || *v == '\t') v++;

        cfg_set_value(&current, k, v);
    }

    if (in_section && current.dest[0] != '\0') {
        if (n >= capacity) {
            capacity *= 2;
            source_t *tmp = realloc(arr, (size_t)capacity * sizeof(source_t));
            if (!tmp) { free(arr); fclose(fp); return -1; }
            arr = tmp;
        }
        arr[n++] = current;
    }

    fclose(fp);

    for (int i = 0; i < n; i++) {
        if (arr[i].type == SOURCE_REMOTE) {
            if (arr[i].host[0] == '\0' ||
                arr[i].user[0] == '\0' ||
                arr[i].ssh_key[0] == '\0') {
                free(arr);
                return -1;
            }
        }
    }

    *out   = arr;
    *count = n;
    return 0;
}
