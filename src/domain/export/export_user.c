/*
 * export_user.c — 面向用户的 TXT 导出（UTF-8 带 BOM），不写分数、权重与公式。
 *
 * 主要函数：ts_export_user_txt。
 */


#include "export_user.h"
#include "export.h"
#include "export_internal.h"
#include "display.h"
#include "mem.h"
#include "runtime.h"

#include <stdio.h>
#include <string.h>

static size_t find_index(const TsPlan *p, const char *id)
{
    size_t i;
    if (id == NULL) return SIZE_MAX;
    for (i = 0; i < p->task_count; i++) {
        if (p->tasks[i].id != NULL && strcmp(p->tasks[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}

static int put_estimate(TsBuf *b, const TsTask *t)
{
    if (!t->has_estimated_hours) return ts_buf_puts(b, "预计工时：待确认");
    return ts_buf_printf(b, "预计工时：%g 小时", t->estimated_hours);
}

static int write_task_block(TsBuf *b, const TsPlan *plan,
                            const TsScheduleResult *sched,
                            const TsStatusView *status, size_t idx)
{
    const TsTask *t = &plan->tasks[idx];
    TsReadyState st = (status != NULL && status->states != NULL)
                          ? status->states[idx]
                          : ((t->actual_status == TS_ACTUAL_DONE) ? TS_DONE : TS_READY);
    char *reasons = NULL;
    char reason_err[128];
    size_t i;

    reason_err[0] = '\0';

    if (ts_buf_printf(b, "■ %s\n", (t->name != NULL) ? t->name : "(未命名)") != 0) return 1;
    if (ts_buf_printf(b, "   状态：%s%s\n", ts_display_status_text(st),
                      (status != NULL && status->affected != NULL && status->affected[idx])
                          ? "（受上游影响）" : "") != 0) return 1;
    if (ts_buf_puts(b, "   ") != 0) return 1;
    if (put_estimate(b, t) != 0) return 1;
    if (t->deadline != NULL && t->deadline[0] != '\0') {
        if (ts_buf_printf(b, "    截止：%s", t->deadline) != 0) return 1;
    }
    if (ts_buf_puts(b, "\n") != 0) return 1;

    if (t->depends_on_count > 0) {
        if (ts_buf_puts(b, "   前置任务：") != 0) return 1;
        for (i = 0; i < t->depends_on_count; i++) {
            size_t pi = find_index(plan, t->depends_on[i]);
            if (i > 0 && ts_buf_puts(b, "、") != 0) return 1;
            if (ts_buf_puts(b, (pi != SIZE_MAX && plan->tasks[pi].name != NULL)
                                   ? plan->tasks[pi].name : t->depends_on[i]) != 0) return 1;
        }
        if (ts_buf_puts(b, "\n") != 0) return 1;
    }
    if (t->preconditions_count > 0) {
        if (ts_buf_puts(b, "   外部条件：\n") != 0) return 1;
        for (i = 0; i < t->preconditions_count; i++) {
            const char *s =
                (t->preconditions[i].status == TS_PRECOND_MET) ? "已满足" :
                (t->preconditions[i].status == TS_PRECOND_UNMET) ? "未满足" : "待确认";
            if (ts_buf_printf(b, "     - %s（%s）\n",
                              t->preconditions[i].description, s) != 0) return 1;
        }
    }
    if (t->steps_count > 0) {
        if (ts_buf_puts(b, "   执行步骤：\n") != 0) return 1;
        for (i = 0; i < t->steps_count; i++) {
            if (ts_buf_printf(b, "     %zu) %s\n", i + 1, t->steps[i]) != 0) return 1;
        }
    }

    if (ts_display_task_reasons(plan, sched, status, idx, &reasons,
                                reason_err, sizeof(reason_err)) == 0 && reasons != NULL) {
        if (ts_buf_puts(b, "   为什么这样安排：\n") != 0) { ts_free(reasons); return 1; }
        {
            const char *p = reasons;
            while (*p != '\0') {
                const char *nl = strchr(p, '\n');
                size_t len = (nl != NULL) ? (size_t)(nl - p) : strlen(p);
                if (len > 0 && ts_buf_printf(b, "     %.*s\n", (int)len, p) != 0) {
                    ts_free(reasons);
                    return 1;
                }
                if (nl == NULL) break;
                p = nl + 1;
            }
        }
        ts_free(reasons);
    }

    if (t->source_refs_count > 0) {
        if (ts_buf_puts(b, "   来源：") != 0) return 1;
        for (i = 0; i < t->source_refs_count; i++) {
            if (i > 0 && ts_buf_puts(b, "；") != 0) return 1;
            if (ts_buf_puts(b, t->source_refs[i]) != 0) return 1;
        }
        if (ts_buf_puts(b, "\n") != 0) return 1;
    }
    if (ts_buf_puts(b, "\n") != 0) return 1;
    return 0;
}

static const char *note_kind_text(TsNoteKind k)
{
    switch (k) {
        case TS_NOTE_BLOCKED:    return "受阻";
        case TS_NOTE_ASSUMPTION: return "分析假设";
        default:                 return "待确认";
    }
}

int ts_export_user_txt(const TsPlan *plan,
                       const TsScheduleResult *sched,
                       const TsStatusView *status,
                       const char *path,
                       char *err, size_t err_sz)
{
    TsBuf b;
    size_t i;
    int rc = 1;

    if (plan == NULL || path == NULL) {
        snprintf(err, err_sz, "导出参数为空");
        return 1;
    }
    ts_buf_init(&b);

    if (ts_buf_puts(&b, "任务计划\n") != 0 ||
        ts_buf_puts(&b, "========================================\n") != 0) goto oom;
    if (plan->summary != NULL && plan->summary[0] != '\0') {
        if (ts_buf_printf(&b, "总结：%s\n", plan->summary) != 0) goto oom;
    }
    {
        char ts[32];
        ts_clock_wall_iso(ts, sizeof(ts));
        if (ts_buf_printf(&b, "导出时间：%s\n", ts) != 0) goto oom;
    }
    if (ts_buf_puts(&b, "说明：本文件只包含任务事实与自然语言安排原因；"
                        "排序内部的评分与权重不出现在这里。\n\n") != 0) goto oom;

    /* 建议顺序 */
    if (ts_buf_puts(&b, "【建议执行顺序】\n\n") != 0) goto oom;
    if (sched == NULL || sched->step_count == 0) {
        if (ts_buf_puts(&b, "（当前没有可执行的任务，详见下方分组）\n\n") != 0) goto oom;
    } else {
        for (i = 0; i < sched->step_count; i++) {
            size_t idx = find_index(plan, sched->steps[i].task_id);
            if (idx == SIZE_MAX) continue;
            if (ts_buf_printf(&b, "第 %zu 步\n", i + 1) != 0) goto oom;
            if (write_task_block(&b, plan, sched, status, idx) != 0) goto oom;
        }
    }
    if (sched != NULL && sched->unresolvable_reason != NULL) {
        if (ts_buf_printf(&b, "提示：%s\n\n", sched->unresolvable_reason) != 0) goto oom;
    }

    /* 受阻 / 待确认 / 已完成 */
    if (ts_buf_puts(&b, "【受阻任务】\n") != 0) goto oom;
    {
        int any = 0;
        for (i = 0; i < plan->task_count; i++) {
            TsReadyState st = (status != NULL && status->states != NULL)
                                  ? status->states[i] : TS_READY;
            if (st != TS_BLOCKED) continue;
            if (ts_buf_printf(&b, " - %s\n", plan->tasks[i].name) != 0) goto oom;
            any = 1;
        }
        if (!any && ts_buf_puts(&b, "（无）\n") != 0) goto oom;
    }
    if (ts_buf_puts(&b, "\n【待确认任务】\n") != 0) goto oom;
    {
        int any = 0;
        for (i = 0; i < plan->task_count; i++) {
            TsReadyState st = (status != NULL && status->states != NULL)
                                  ? status->states[i] : TS_READY;
            if (st != TS_PENDING_CONFIRM) continue;
            if (ts_buf_printf(&b, " - %s\n", plan->tasks[i].name) != 0) goto oom;
            any = 1;
        }
        if (!any && ts_buf_puts(&b, "（无）\n") != 0) goto oom;
    }
    if (ts_buf_puts(&b, "\n【已完成任务】\n") != 0) goto oom;
    {
        int any = 0;
        for (i = 0; i < plan->task_count; i++) {
            if (plan->tasks[i].actual_status != TS_ACTUAL_DONE) continue;
            if (ts_buf_printf(&b, " - %s\n", plan->tasks[i].name) != 0) goto oom;
            any = 1;
        }
        if (!any && ts_buf_puts(&b, "（无）\n") != 0) goto oom;
    }

    /* 待确认 / 受阻 / 假设 */
    if (ts_buf_puts(&b, "\n【待确认 · 受阻 · 分析假设】\n") != 0) goto oom;
    if (plan->note_count == 0) {
        if (ts_buf_puts(&b, "（无）\n") != 0) goto oom;
    } else {
        size_t k;
        for (i = 0; i < plan->note_count; i++) {
            if (ts_buf_printf(&b, " - [%s] %s", note_kind_text(plan->notes[i].kind),
                              plan->notes[i].text) != 0) goto oom;
            for (k = 0; k < plan->notes[i].task_ref_count; k++) {
                size_t ti = find_index(plan, plan->notes[i].task_refs[k]);
                if (ts_buf_printf(&b, "%s%s", (k == 0) ? "（关联：" : "、",
                                  (ti != SIZE_MAX) ? plan->tasks[ti].name
                                                   : plan->notes[i].task_refs[k]) != 0) goto oom;
            }
            if (plan->notes[i].task_ref_count > 0 && ts_buf_puts(&b, "）") != 0) goto oom;
            if (ts_buf_puts(&b, "\n") != 0) goto oom;
        }
    }

    if (ts_buf_puts(&b, "\n") != 0) goto oom;

    /* 写盘：与 export.c 共用同一实现（UTF-8 BOM、失败时删除半成品）。 */
    if (ts_export_write_file(path, b.data, b.len, 1, err, err_sz) != 0) {
        goto done;
    }
    rc = 0;

oom:
    if (rc != 0 && (err == NULL || err[0] == '\0')) {
        if (err != NULL && err_sz > 0) snprintf(err, err_sz, "内存分配失败");
    }
done:
    ts_buf_free(&b);
    return rc;
}

