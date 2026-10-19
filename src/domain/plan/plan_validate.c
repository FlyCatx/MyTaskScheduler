/*
 * plan_validate.c — 计划业务校验（不依赖 cJSON）：schema 版本、ID 唯一、依赖存在/自依赖/重复/循环、
 * 取值范围与枚举。
 *
 * 主要函数：ts_plan_validate。
 */


#include "plan.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

static int oom(char *err, size_t err_sz)
{
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

static size_t find_task(const TsPlan *p, const char *id)
{
    size_t i;
    if (p == NULL || id == NULL) return SIZE_MAX;
    for (i = 0; i < p->task_count; i++) {
        if (p->tasks[i].id != NULL && strcmp(p->tasks[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}

/* Kahn 拓扑排序检测循环（字符串 ID 版）。 */
static int check_cycle(const TsPlan *plan, char *err, size_t err_sz)
{
    size_t n = plan->task_count;
    int *indeg;
    unsigned char *done;
    size_t i, j, k;
    size_t processed = 0;
    int changed;

    indeg = (int *)ts_calloc(n, sizeof(int));
    done = (unsigned char *)ts_calloc(n, 1);
    if (indeg == NULL || done == NULL) {
        ts_free(indeg);
        ts_free(done);
        return oom(err, err_sz);
    }
    for (i = 0; i < n; i++) {
        indeg[i] = (int)plan->tasks[i].depends_on_count;
    }

    do {
        changed = 0;
        for (i = 0; i < n; i++) {
            if (done[i] || indeg[i] != 0) continue;
            done[i] = 1;
            processed++;
            changed = 1;
            /* 所有依赖本任务的后继入度减一 */
            for (j = 0; j < n; j++) {
                if (done[j]) continue;
                for (k = 0; k < plan->tasks[j].depends_on_count; k++) {
                    if (strcmp(plan->tasks[j].depends_on[k], plan->tasks[i].id) == 0) {
                        indeg[j]--;
                    }
                }
            }
        }
    } while (changed);

    ts_free(indeg);
    ts_free(done);

    if (processed < n) {
        snprintf(err, err_sz, "检测到循环依赖（%zu/%zu 个任务无法进入拓扑序）",
                 n - processed, n);
        return 1;
    }
    return 0;
}

int ts_plan_validate(const TsPlan *plan, const TsConfig *cfg, char *err, size_t err_sz)
{
    size_t i, j, k;

    if (plan == NULL || cfg == NULL) {
        snprintf(err, err_sz, "计划或配置为空");
        return 1;
    }
    /*
     * 兼容策略：
     *   1.0 —— 旧协议，全部字段向后兼容（summary / previous_task_id / notes 允许缺失）；
     *   2.x —— 当前协议，新增 summary / previous_task_id / notes[]。
     * 其它版本一律拒绝，避免把未知结构当成已知结构解析。
     */
    {
        int legacy_ok = (plan->schema_major == 1 && plan->schema_minor == 0);
        int current_ok = (plan->schema_major == 2);
        if (!legacy_ok && !current_ok) {
            snprintf(err, err_sz,
                     "不支持的 schema_version（需要 1.0 或 2.x，得到 %d.%d）",
                     plan->schema_major, plan->schema_minor);
            return 1;
        }
    }
    if (plan->task_count == 0) {
        snprintf(err, err_sz, "任务列表为空");
        return 1;
    }
    if ((long)plan->task_count > cfg->max_tasks) {
        snprintf(err, err_sz, "任务数量超过上限(%ld)", cfg->max_tasks);
        return 1;
    }

    for (i = 0; i < plan->task_count; i++) {
        const TsTask *t = &plan->tasks[i];

        if (t->id == NULL || t->id[0] == '\0') {
            snprintf(err, err_sz, "任务 #%zu 缺少 id", i);
            return 1;
        }
        if (t->name == NULL || t->name[0] == '\0') {
            snprintf(err, err_sz, "任务 %s 缺少 name", t->id);
            return 1;
        }
        /* ID 唯一 */
        for (j = 0; j < i; j++) {
            if (plan->tasks[j].id != NULL && strcmp(plan->tasks[j].id, t->id) == 0) {
                snprintf(err, err_sz, "任务 ID 重复：%s", t->id);
                return 1;
            }
        }
        /* 紧迫性 / 影响力范围 */
        if (t->urgency < 1 || t->urgency > 5) {
            snprintf(err, err_sz, "任务 %s 的 urgency 必须在 1..5（得到 %d）",
                     t->id, t->urgency);
            return 1;
        }
        if (t->impact < 1 || t->impact > 5) {
            snprintf(err, err_sz, "任务 %s 的 impact 必须在 1..5（得到 %d）",
                     t->id, t->impact);
            return 1;
        }
        /* 工时：正数或未知（未知绝不当作 0） */
        if (t->has_estimated_hours) {
            if (!isfinite(t->estimated_hours) || t->estimated_hours <= 0.0) {
                snprintf(err, err_sz, "任务 %s 的 estimated_hours 必须为正数（得到 %g）",
                         t->id, t->estimated_hours);
                return 1;
            }
        }
        /* 步骤数量 */
        if ((long)t->steps_count > cfg->max_steps_per_task) {
            snprintf(err, err_sz, "任务 %s 的步骤数量超过上限(%ld)",
                     t->id, cfg->max_steps_per_task);
            return 1;
        }
        /* 外部条件枚举（防御性：本地编辑可能写入非法值） */
        for (k = 0; k < t->preconditions_count; k++) {
            int st = (int)t->preconditions[k].status;
            if (st < 0 || st > 2) {
                snprintf(err, err_sz, "任务 %s 的外部条件状态非法", t->id);
                return 1;
            }
        }
        /* 依赖：存在性、自依赖、重复依赖 */
        for (k = 0; k < t->depends_on_count; k++) {
            const char *dep = t->depends_on[k];
            if (dep == NULL || dep[0] == '\0') {
                snprintf(err, err_sz, "任务 %s 存在空的前置任务 ID", t->id);
                return 1;
            }
            if (strcmp(dep, t->id) == 0) {
                snprintf(err, err_sz, "任务 %s 不能依赖自身", t->id);
                return 1;
            }
            for (j = 0; j < k; j++) {
                if (strcmp(t->depends_on[j], dep) == 0) {
                    snprintf(err, err_sz, "任务 %s 重复依赖 %s", t->id, dep);
                    return 1;
                }
            }
            if (find_task(plan, dep) == SIZE_MAX) {
                snprintf(err, err_sz, "任务 %s 依赖的 %s 不存在", t->id, dep);
                return 1;
            }
        }
    }

    /* notes：类型、文本非空、任务引用必须存在 */
    if (plan->note_count > (size_t)TS_MAX_NOTES) {
        snprintf(err, err_sz, "notes 数量超过上限(%d)", TS_MAX_NOTES);
        return 1;
    }
    for (i = 0; i < plan->note_count; i++) {
        const TsNote *note = &plan->notes[i];
        int nk = (int)note->kind;
        if (nk != TS_NOTE_QUESTION && nk != TS_NOTE_BLOCKED && nk != TS_NOTE_ASSUMPTION) {
            snprintf(err, err_sz, "notes[%zu].kind 非法", i);
            return 1;
        }
        if (note->text == NULL || note->text[0] == '\0') {
            snprintf(err, err_sz, "notes[%zu].text 为空", i);
            return 1;
        }
        for (j = 0; j < note->task_ref_count; j++) {
            if (note->task_refs[j] == NULL || note->task_refs[j][0] == '\0') {
                snprintf(err, err_sz, "notes[%zu] 存在空的任务引用", i);
                return 1;
            }
            if (find_task(plan, note->task_refs[j]) == SIZE_MAX) {
                snprintf(err, err_sz, "notes[%zu] 引用的任务 %s 不存在",
                         i, note->task_refs[j]);
                return 1;
            }
        }
    }

    /* 不擅自删除依赖边“修好”结果：发现循环直接报错 */
    return check_cycle(plan, err, err_sz);
}

