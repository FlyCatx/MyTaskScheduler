/*
 * types.c — 核心数据结构的初始化与释放。
 *
 * 主要函数：ts_task_init、ts_task_free、ts_plan_init、ts_plan_free。
 */

#include "types.h"
#include "mem.h"

#include <string.h>

/* 释放 char** 字符串数组。所有元素和数组本身都必须是 malloc/calloc 分配的。 */
static void free_str_array(char **arr, size_t count)
{
    size_t i;
    if (arr == NULL) {
        return;
    }
    for (i = 0; i < count; i++) {
        ts_free(arr[i]);
    }
    ts_free(arr);
}

void ts_task_init(TsTask *t)
{
    if (t != NULL) {
        memset(t, 0, sizeof(*t));
    }
}

void ts_task_free(TsTask *t)
{
    size_t i;
    if (t == NULL) {
        return;
    }
    ts_free(t->id);
    ts_free(t->name);
    ts_free(t->previous_task_id);
    free_str_array(t->depends_on, t->depends_on_count);
    for (i = 0; i < t->preconditions_count; i++) {
        ts_free(t->preconditions[i].description);
    }
    ts_free(t->preconditions);
    free_str_array(t->steps, t->steps_count);
    ts_free(t->urgency_reason);
    ts_free(t->impact_reason);
    ts_free(t->estimate_reason);
    ts_free(t->deadline);
    free_str_array(t->source_refs, t->source_refs_count);
    memset(t, 0, sizeof(*t));
}

void ts_plan_init(TsPlan *p)
{
    if (p != NULL) {
        memset(p, 0, sizeof(*p));
    }
}

void ts_plan_free(TsPlan *p)
{
    size_t i;
    if (p == NULL) {
        return;
    }
    for (i = 0; i < p->task_count; i++) {
        ts_task_free(&p->tasks[i]);
    }
    ts_free(p->tasks);
    for (i = 0; i < p->note_count; i++) {
        ts_free(p->notes[i].text);
        free_str_array(p->notes[i].task_refs, p->notes[i].task_ref_count);
    }
    ts_free(p->notes);
    ts_free(p->summary);
    free_str_array(p->assumptions, p->assumptions_count);
    free_str_array(p->questions, p->questions_count);
    free_str_array(p->suggested_order, p->suggested_order_count);
    memset(p, 0, sizeof(*p));
}

