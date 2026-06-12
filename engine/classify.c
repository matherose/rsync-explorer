/**
 * @file classify.c
 * @brief Lifecycle classification engine.
 */

#include "engine_internal.h"

#define MAX_SNAPSHOTS 128

typedef struct {
    char     rel_path[512];
    int64_t  inodes[MAX_SNAPSHOTS];
    int      present_mask[MAX_SNAPSHOTS];
    int      first_idx;
    int      last_idx;

    uint32_t mode;
    char     user[64];
    char     group[64];
    uint64_t size;
    int64_t  mtime;
    uint32_t nlink;
    uint8_t  is_dir;
} merge_entry_t;

typedef struct {
    merge_entry_t *data;
    int            count;
    int            capacity;
} merge_array_t;

static int merge_array_init(merge_array_t *arr)
{
    arr->capacity = 128;
    arr->count    = 0;
    arr->data     = malloc((size_t)arr->capacity * sizeof(merge_entry_t));
    return arr->data ? 0 : -1;
}

static int merge_array_push(merge_array_t *arr, const merge_entry_t *item)
{
    if (arr->count >= arr->capacity) {
        arr->capacity *= 2;
        merge_entry_t *tmp = realloc(arr->data,
                                     (size_t)arr->capacity * sizeof(merge_entry_t));
        if (!tmp) return -1;
        arr->data = tmp;
    }
    arr->data[arr->count++] = *item;
    return 0;
}

static int merge_find(merge_array_t *arr, const char *rel_path)
{
    for (int i = 0; i < arr->count; i++) {
        if (strcmp(arr->data[i].rel_path, rel_path) == 0)
            return i;
    }
    return -1;
}

static file_class_t classify_merge_entry(const merge_entry_t *me,
                                         int snap_count,
                                         int *deleted_at_idx)
{
    *deleted_at_idx = -1;

    /* Check for gaps: present then absent then present again */
    int had_absence = 0;
    int last_present = -1;
    for (int i = 0; i < snap_count; i++) {
        if (me->present_mask[i]) {
            if (had_absence && last_present >= 0) {
                return CLASS_DEL_NEW;
            }
            last_present = i;
        } else {
            if (last_present >= 0) had_absence = 1;
        }
    }

    /* Not in the latest snapshot → DELETED */
    if (!me->present_mask[snap_count - 1]) {
        for (int i = me->last_idx + 1; i < snap_count; i++) {
            *deleted_at_idx = i;
            break;
        }
        return CLASS_DELETED;
    }

    /* Only in the latest snapshot → NEW */
    if (me->first_idx == snap_count - 1) {
        return CLASS_NEW;
    }

    /* Check if inode changed → MODIFIED */
    uint64_t first_inode = 0;
    int got_first = 0;
    for (int i = 0; i < snap_count; i++) {
        if (me->present_mask[i] && me->inodes[i] != 0) {
            if (!got_first) {
                first_inode = me->inodes[i];
                got_first = 1;
            } else if ((uint64_t)me->inodes[i] != first_inode) {
                return CLASS_MODIFIED;
            }
        }
    }

    return CLASS_UNCHANGED;
}

void classify_entries(file_entry_t **snap_entries,
                      int *snap_counts, int snap_count,
                      const snapshot_t *snaps,
                      const char *rel_path,
                      lifecycle_t **out, int *out_count)
{
    if (snap_count > MAX_SNAPSHOTS) snap_count = MAX_SNAPSHOTS;

    merge_array_t merged;
    if (merge_array_init(&merged) != 0) {
        *out = NULL; *out_count = 0; return;
    }

    /* Phase 1: Merge all per-snapshot entries into per-path records */
    for (int s = 0; s < snap_count; s++) {
        for (int e = 0; e < snap_counts[s]; e++) {
            const file_entry_t *fe = &snap_entries[s][e];
            int idx = merge_find(&merged, fe->rel_path);

            if (idx < 0) {
                merge_entry_t me;
                memset(&me, 0, sizeof(me));
                str_copy(me.rel_path, sizeof(me.rel_path), fe->rel_path);
                me.present_mask[s] = 1;
                me.inodes[s]       = fe->inode;
                me.first_idx       = s;
                me.last_idx        = s;
                me.mode   = fe->mode;
                str_copy(me.user, sizeof(me.user), fe->user);
                str_copy(me.group, sizeof(me.group), fe->group);
                me.size   = fe->size;
                me.mtime  = fe->mtime;
                me.nlink  = fe->nlink;
                me.is_dir = fe->is_dir;

                merge_array_push(&merged, &me);
            } else {
                merge_entry_t *me = &merged.data[idx];
                me->present_mask[s] = 1;
                me->inodes[s]       = fe->inode;
                if (s > me->last_idx) {
                    me->last_idx = s;
                    me->mode   = fe->mode;
                    str_copy(me->user, sizeof(me->user), fe->user);
                    str_copy(me->group, sizeof(me->group), fe->group);
                    me->size   = fe->size;
                    me->mtime  = fe->mtime;
                    me->nlink  = fe->nlink;
                    me->is_dir = fe->is_dir;
                }
                if (s < me->first_idx) {
                    me->first_idx = s;
                }
            }
        }
    }

    /* Phase 2: Classify and produce lifecycle_t */
    lifecycle_t *results = malloc((size_t)merged.count * sizeof(lifecycle_t));
    if (!results) { free(merged.data); *out = NULL; *out_count = 0; return; }

    int n = 0;
    for (int i = 0; i < merged.count; i++) {
        const merge_entry_t *me = &merged.data[i];

        int deleted_at_idx = -1;
        file_class_t cls = classify_merge_entry(me, snap_count, &deleted_at_idx);

        lifecycle_t lc;
        memset(&lc, 0, sizeof(lc));

        str_copy(lc.rel_path, sizeof(lc.rel_path), me->rel_path);
        lc.class   = cls;
        lc.mode    = me->mode;
        str_copy(lc.user, sizeof(lc.user), me->user);
        str_copy(lc.group, sizeof(lc.group), me->group);
        lc.size    = me->size;
        lc.mtime   = me->mtime;
        lc.nlink   = me->nlink;
        lc.is_dir  = me->is_dir;

        lc.first_backup = snaps[me->first_idx].date_epoch;
        lc.last_backup  = snaps[me->last_idx].date_epoch;

        if (deleted_at_idx >= 0) {
            lc.deleted_in = snaps[deleted_at_idx].date_epoch;
        } else {
            lc.deleted_in = -1;
        }

        /* Build last_real_path */
        if (rel_path[0] != '\0' && strcmp(rel_path, "/") != 0) {
            snprintf(lc.last_real_path, sizeof(lc.last_real_path),
                     "%s/%s/%s",
                     snaps[me->last_idx].full_path,
                     rel_path, me->rel_path);
        } else {
            snprintf(lc.last_real_path, sizeof(lc.last_real_path),
                     "%s/%s",
                     snaps[me->last_idx].full_path,
                     me->rel_path);
        }

        results[n++] = lc;
    }

    free(merged.data);

    *out       = results;
    *out_count = n;
}
