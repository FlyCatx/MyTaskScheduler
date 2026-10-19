/*
 * display.c — 展示快照生成：把计划、调度结果与状态视图收敛成用户可见事实与自然语言理由。
 *
 * 主要函数：ts_display_build、ts_display_task_reasons。
 */


#include "display.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

#include "cJSON.h"

#define TS_DISP_STR    512
#define TS_DISP_LONG   1024

/* ------------------------------------------------------------------ */
/* 状态文本                                                            */
/* ------------------------------------------------------------------ */

const char *ts_display_status_key(TsReadyState s)
{
    switch (s) {
        case TS_READY:           return "ready";
        case TS_WAITING_DEP:     return "waiting";
        case TS_PENDING_CONFIRM: return "pending";
        case TS_BLOCKED:         return "blocked";
        case TS_DONE:            return "done";
        default:                 return "unknown";
    }
}

const char *ts_display_status_text(TsReadyState s)
{
    switch (s) {
        case TS_READY:           return "可开始";
        case TS_WAITING_DEP:     return "等待前置任务";
        case TS_PENDING_CONFIRM: return "待确认";
        case TS_BLOCKED:         return "受阻";
        case TS_DONE:            return "已完成";
        default:                 return "未知";
    }
}

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static int oom(char *err, size_t err_sz)
{
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

static size_t find_index(const TsPlan *p, const char *id)
{
    size_t i;
    if (id == NULL) return SIZE_MAX;
    for (i = 0; i < p->task_count; i++) {
        if (p->tasks[i].id != NULL && strcmp(p->tasks[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}

static const char *safe(const char *s)
{
    return (s != NULL) ? s : "";
}

/* 追加“、”分隔的列表；返回 0 成功。 */
static int append_names(TsBuf *b, const TsPlan *plan, char *const *ids, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) {
        size_t idx = find_index(plan, ids[i]);
        const char *name = (idx != SIZE_MAX) ? plan->tasks[idx].name : ids[i];
        if (i > 0 && ts_buf_puts(b, "、") != 0) return 1;
        if (ts_buf_puts(b, safe(name)) != 0) return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 自然语言理由                                                        */
/* ------------------------------------------------------------------ */

/*
 * 依据**实际事实**生成安排理由（不使用 TsScheduleStep.reason 里的公式文本）。
 *
 * 依据顺序：
 *   1) 当前就绪状态（前置是否齐、外部条件是否确认）；
 *   2) 它在建议顺序里的位置，以及做完会解锁什么；
 *   3) 模型给出的紧迫性/影响力说明（自然语言，不含数字）。
 * 数字（紧迫性分值、权重、最终分）一概不进入这些句子。
 */
static char *build_user_reasons(const TsPlan *plan, const TsScheduleResult *sched,
                                const TsStatusView *status,
                                size_t task_index)
{
    TsBuf b;
    const TsTask *t = &plan->tasks[task_index];
    const TsScheduleStep *step = NULL;
    TsReadyState st;
    size_t i, k;

    ts_buf_init(&b);

    /* 找到该任务的调度步骤（若已排入顺序） */
    for (i = 0; sched != NULL && i < sched->step_count; i++) {
        if (strcmp(sched->steps[i].task_id, t->id) == 0) { step = &sched->steps[i]; break; }
    }

    st = (status != NULL && status->states != NULL)
             ? status->states[task_index] : TS_READY;

    /* 1) 状态 / 前置 */
    switch (st) {
        case TS_DONE:
            ts_buf_puts(&b, "你已标记为完成；它不再占用剩余时间。");
            break;
        case TS_BLOCKED:
            ts_buf_puts(&b, "现在还不能开始：外部条件未满足。");
            break;
        case TS_PENDING_CONFIRM:
            ts_buf_puts(&b, "开始前需要先确认外部条件是否具备。");
            break;
        case TS_WAITING_DEP: {
            int first = 1;
            ts_buf_puts(&b, "需要等这些前置任务完成后才能开始：");
            for (k = 0; k < t->depends_on_count; k++) {
                size_t pi = find_index(plan, t->depends_on[k]);
                int done = (pi != SIZE_MAX &&
                            plan->tasks[pi].actual_status == TS_ACTUAL_DONE);
                if (done) continue;
                if (!first && ts_buf_puts(&b, "、") != 0) goto fail;
                if (ts_buf_puts(&b, safe((pi != SIZE_MAX) ? plan->tasks[pi].name
                                                         : t->depends_on[k])) != 0) goto fail;
                first = 0;
            }
            if (first) ts_buf_puts(&b, "（已无未完成前置，可刷新查看）");
            break;
        }
        default:
            if (t->depends_on_count == 0) {
                ts_buf_puts(&b, "没有前置任务，现在就可以开始。");
            } else {
                ts_buf_puts(&b, "前置任务都已完成，现在就可以开始。");
            }
            break;
    }

    /* 2) 顺序位置与解锁关系 */
    if (step != NULL) {
        int placed = 0;
        for (i = 0; sched != NULL && i < sched->step_count; i++) {
            if (&sched->steps[i] == step) { placed = (int)i + 1; break; }
        }
        if (placed == 1) {
            if (ts_buf_puts(&b, "\n建议先做它：当前可开始的任务里它排在第一位。") != 0) goto fail;
        } else if (placed > 1) {
            if (ts_buf_printf(&b, "\n建议第 %d 个做：前面的任务完成后才轮到它。", placed) != 0) {
                goto fail;
            }
        }
        if (step->unlocked_count > 0) {
            if (ts_buf_puts(&b, "\n做完它会立即解锁：") != 0) goto fail;
            if (append_names(&b, plan, step->unlocked, step->unlocked_count) != 0) goto fail;
            if (ts_buf_puts(&b, "。") != 0) goto fail;
        } else if (st == TS_READY && t->id != NULL) {
            /* 只有确实没有直接后继解锁时才这么说，避免与解锁信息矛盾 */
            size_t direct_succ = 0;
            for (i = 0; i < plan->task_count; i++) {
                for (k = 0; k < plan->tasks[i].depends_on_count; k++) {
                    if (strcmp(plan->tasks[i].depends_on[k], t->id) == 0) { direct_succ++; break; }
                }
            }
            if (direct_succ == 0) {
                if (ts_buf_puts(&b, "\n它是收尾任务，完成后没有其它任务依赖它。") != 0) goto fail;
            }
        }
    }

    /* 3) 模型给出的说明（自然语言） */
    if (t->urgency_reason != NULL && t->urgency_reason[0] != '\0') {
        if (ts_buf_puts(&b, "\n安排依据：") != 0) goto fail;
        if (ts_buf_puts(&b, t->urgency_reason) != 0) goto fail;
        if (t->urgency_reason[strlen(t->urgency_reason) - 1] != '。' &&
            t->urgency_reason[strlen(t->urgency_reason) - 1] != '.') {
            if (ts_buf_puts(&b, "。") != 0) goto fail;
        }
    }
    if (t->impact_reason != NULL && t->impact_reason[0] != '\0' &&
        (t->urgency_reason == NULL || strcmp(t->impact_reason, t->urgency_reason) != 0)) {
        if (ts_buf_puts(&b, "\n影响范围：") != 0) goto fail;
        if (ts_buf_puts(&b, t->impact_reason) != 0) goto fail;
    }

    return b.data;

fail:
    ts_buf_free(&b);
    return NULL;
}

int ts_display_task_reasons(const TsPlan *plan,
                            const TsScheduleResult *sched,
                            const TsStatusView *status,
                            size_t task_index,
                            char **out, char *err, size_t err_sz)
{
    char *text;
    if (out == NULL || plan == NULL || task_index >= plan->task_count) return 1;
    *out = NULL;
    text = build_user_reasons(plan, sched, status, task_index);
    if (text == NULL) return oom(err, err_sz);
    *out = text;
    return 0;
}

/* 把多行理由拆成字符串数组（界面按段落渲染）。 */static int add_reason_lines(cJSON *arr, const char *text)
{
    const char *p = text;
    if (text == NULL) return 0;
    while (*p != '\0') {
        const char *nl = strchr(p, '\n');
        size_t len = (nl != NULL) ? (size_t)(nl - p) : strlen(p);
        if (len > 0) {
            char *line = ts_strndup(p, len);
            if (line == NULL) return 1;
            if (cJSON_AddItemToArray(arr, cJSON_CreateString(line)) == 0) {
                ts_free(line);
                return 1;
            }
            ts_free(line);
        }
        if (nl == NULL) break;
        p = nl + 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 相对工时时间轴                                                      */
/* ------------------------------------------------------------------ */
typedef struct DispBar {
    double start;
    double end;
    int scheduled;              /* 1 = 有确定起止 */
    const char *note;           /* scheduled=0 时的原因（指向静态字符串） */
} DispBar;

/*
 * 单人串行、相对工时轴：
 *   严格按 C 核心给出的建议顺序累计，绝不依据依赖图自行并行。
 *   未知工时之后的任务即使工时已知，也只标“起始时间待定”。
 *   已完成任务不占剩余时间轴。
 *   受阻/待确认及其受影响任务不排期，并说明原因。
 */
static int compute_timeline(const TsPlan *plan, const TsScheduleResult *sched,
                            const TsStatusView *status,
                            DispBar **out, char *err, size_t err_sz)
{
    size_t n = plan->task_count;
    DispBar *bars;
    unsigned char *seen;
    double cursor = 0.0;
    int cursor_known = 1;
    size_t i;

    *out = NULL;
    bars = (DispBar *)ts_calloc(n, sizeof(DispBar));
    seen = (unsigned char *)ts_calloc(n, 1);
    if (bars == NULL || seen == NULL) {
        ts_free(bars);
        ts_free(seen);
        return oom(err, err_sz);
    }

    for (i = 0; i < n; i++) {
        bars[i].scheduled = 0;
        bars[i].note = NULL;
    }

    if (sched == NULL) {
        for (i = 0; i < n; i++) {
            if (plan->tasks[i].actual_status == TS_ACTUAL_DONE) {
                bars[i].note = "已完成";
            } else {
                bars[i].note = "尚未生成建议顺序";
            }
        }
        ts_free(seen);
        *out = bars;
        return 0;
    }

    for (i = 0; i < sched->step_count; i++) {
        size_t idx = find_index(plan, sched->steps[i].task_id);
        const TsTask *t;
        if (idx == SIZE_MAX || idx >= n) continue;
        seen[idx] = 1;
        t = &plan->tasks[idx];

        if (t->actual_status == TS_ACTUAL_DONE) {
            bars[idx].note = "已完成";
            continue;
        }
        if (!t->has_estimated_hours) {
            bars[idx].note = "预计工时待确认";
            cursor_known = 0;
            continue;
        }
        if (!cursor_known) {
            bars[idx].note = "前序任务工时未知，起始时间待定";
            continue;
        }
        {
            double h = t->estimated_hours;
            if (!isfinite(h) || h <= 0.0) {
                bars[idx].note = "预计工时无效";
                cursor_known = 0;
                continue;
            }
            bars[idx].start = cursor;
            bars[idx].end = cursor + h;
            bars[idx].scheduled = 1;
            cursor = bars[idx].end;
        }
    }

    /* 未进入建议顺序的任务：按状态说明原因，不伪造起止时间 */
    for (i = 0; i < n; i++) {
        TsReadyState st;
        if (seen[i]) continue;
        if (plan->tasks[i].actual_status == TS_ACTUAL_DONE) {
            bars[i].note = "已完成";
            continue;
        }
        st = (status != NULL && status->states != NULL) ? status->states[i] : TS_READY;
        if (st == TS_BLOCKED) {
            bars[i].note = "受阻，未排期";
        } else if (st == TS_PENDING_CONFIRM) {
            bars[i].note = "外部条件待确认，未排期";
        } else if (status != NULL && status->affected != NULL && status->affected[i]) {
            bars[i].note = "受上游受阻影响，未排期";
        } else {
            bars[i].note = "未列入建议顺序，请核查计划";
        }
    }

    ts_free(seen);
    *out = bars;
    return 0;
}

/* ------------------------------------------------------------------ */
/* 主函数                                                              */
/* ------------------------------------------------------------------ */

static int add_related(cJSON *parent, const char *key,
                       const TsPlan *plan, char *const *ids, size_t n)
{
    cJSON *arr = cJSON_AddArrayToObject(parent, key);
    size_t i;
    if (arr == NULL) return 1;
    for (i = 0; i < n; i++) {
        size_t idx = find_index(plan, ids[i]);
        cJSON *o = cJSON_CreateObject();
        if (o == NULL) return 1;
        if (cJSON_AddStringToObject(o, "id", ids[i]) == NULL ||
            cJSON_AddStringToObject(o, "name",
                (idx != SIZE_MAX) ? plan->tasks[idx].name : ids[i]) == NULL) {
            cJSON_Delete(o);
            return 1;
        }
        cJSON_AddItemToArray(arr, o);
    }
    return 0;
}

static int add_string_array(cJSON *parent, const char *key,
                            char *const *v, size_t n)
{
    cJSON *arr = cJSON_AddArrayToObject(parent, key);
    size_t i;
    if (arr == NULL) return 1;
    for (i = 0; i < n; i++) {
        if (cJSON_AddItemToArray(arr, cJSON_CreateString(v[i])) == 0) return 1;
    }
    return 0;
}

/* 可选字符串：为空时写 null（界面据此显示“未指定”）。 */
static int add_opt_string(cJSON *parent, const char *key, const char *v)
{
    if (v == NULL || v[0] == '\0') {
        return (cJSON_AddNullToObject(parent, key) != NULL) ? 0 : 1;
    }
    return (cJSON_AddStringToObject(parent, key, v) != NULL) ? 0 : 1;
}

static int add_id_array(cJSON *parent, const char *key,
                        char *const *v, size_t n)
{
    return add_string_array(parent, key, v, n);
}

int ts_display_build(const TsPlan *plan,
                     const TsScheduleResult *sched,
                     const TsStatusView *status,
                     char **out, size_t *out_len,
                     char *err, size_t err_sz)
{
    cJSON *root = NULL;
    cJSON *tasks = NULL;
    DispBar *bars = NULL;
    char *printed = NULL;
    size_t i, k;
    int rc = 1;

    if (out == NULL || plan == NULL) return 1;
    *out = NULL;
    if (out_len != NULL) *out_len = 0;

    if (compute_timeline(plan, sched, status, &bars, err, err_sz) != 0) return 1;

    root = cJSON_CreateObject();
    if (root == NULL) { oom(err, err_sz); goto done; }
    if (cJSON_AddBoolToObject(root, "ok", 1) == NULL) goto oom;
    if (cJSON_AddStringToObject(root, "formatVersion", TS_DISPLAY_FORMAT_VERSION) == NULL) goto oom;
    if (cJSON_AddStringToObject(root, "summary", safe(plan->summary)) == NULL) goto oom;
    if (cJSON_AddStringToObject(root, "sortedAt",
            (sched != NULL) ? sched->sorted_at : "") == NULL) goto oom;
    if (sched != NULL && sched->unresolvable_reason != NULL) {
        if (cJSON_AddStringToObject(root, "unresolvableReason",
                                    sched->unresolvable_reason) == NULL) goto oom;
    } else if (cJSON_AddNullToObject(root, "unresolvableReason") == NULL) {
        goto oom;
    }

    tasks = cJSON_AddArrayToObject(root, "tasks");
    if (tasks == NULL) goto oom;

    for (i = 0; i < plan->task_count; i++) {
        const TsTask *t = &plan->tasks[i];
        const TsScheduleStep *step = NULL;
        char *reasons = NULL;
        TsReadyState st;
        cJSON *o = cJSON_CreateObject();
        if (o == NULL) goto oom;

        for (k = 0; sched != NULL && k < sched->step_count; k++) {
            if (strcmp(sched->steps[k].task_id, t->id) == 0) {
                step = &sched->steps[k];
                break;
            }
        }
        st = (status != NULL && status->states != NULL)
                 ? status->states[i]
                 : ((t->actual_status == TS_ACTUAL_DONE) ? TS_DONE : TS_READY);

        if (cJSON_AddStringToObject(o, "id", t->id) == NULL ||
            cJSON_AddStringToObject(o, "name", t->name) == NULL ||
            cJSON_AddStringToObject(o, "status", ts_display_status_key(st)) == NULL ||
            cJSON_AddStringToObject(o, "statusText", ts_display_status_text(st)) == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (cJSON_AddNumberToObject(o, "level",
                (status != NULL && status->level != NULL) ? (double)status->level[i] : 0.0) == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (cJSON_AddBoolToObject(o, "affected",
                (status != NULL && status->affected != NULL && status->affected[i]) ? 1 : 0) == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (cJSON_AddBoolToObject(o, "estimateKnown", t->has_estimated_hours ? 1 : 0) == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (t->has_estimated_hours) {
            if (cJSON_AddNumberToObject(o, "estimateHours", t->estimated_hours) == NULL) {
                cJSON_Delete(o); goto oom;
            }
        } else if (cJSON_AddNullToObject(o, "estimateHours") == NULL) {
            cJSON_Delete(o); goto oom;
        }
        if (add_opt_string(o, "deadline", t->deadline)) { cJSON_Delete(o); goto oom; }
        if (add_opt_string(o, "estimateReason", t->estimate_reason)) { cJSON_Delete(o); goto oom; }

        /* 步骤 / 来源 / 外部条件 */
        if (add_string_array(o, "steps", t->steps, t->steps_count)) { cJSON_Delete(o); goto oom; }
        if (add_string_array(o, "sources", t->source_refs, t->source_refs_count)) {
            cJSON_Delete(o); goto oom;
        }
        {
            cJSON *conds = cJSON_AddArrayToObject(o, "conditions");
            if (conds == NULL) { cJSON_Delete(o); goto oom; }
            for (k = 0; k < t->preconditions_count; k++) {
                cJSON *c = cJSON_CreateObject();
                const char *stxt =
                    (t->preconditions[k].status == TS_PRECOND_MET) ? "met" :
                    (t->preconditions[k].status == TS_PRECOND_UNMET) ? "unmet" : "unknown";
                if (c == NULL ||
                    cJSON_AddStringToObject(c, "text",
                        t->preconditions[k].description) == NULL ||
                    cJSON_AddStringToObject(c, "status", stxt) == NULL) {
                    if (c != NULL) cJSON_Delete(c);
                    cJSON_Delete(o);
                    goto oom;
                }
                cJSON_AddItemToArray(conds, c);
            }
        }

        /* 前置 / 后继 / 解锁 / 仍等待 */
        if (add_related(o, "predecessors", plan, t->depends_on, t->depends_on_count)) {
            cJSON_Delete(o); goto oom;
        }
        if (step != NULL) {
            if (add_related(o, "unlocks", plan, step->unlocked, step->unlocked_count) ||
                add_related(o, "stillWaiting", plan, step->still_waiting,
                            step->still_waiting_count)) {
                cJSON_Delete(o); goto oom;
            }
        } else {
            if (add_related(o, "unlocks", plan, NULL, 0) ||
                add_related(o, "stillWaiting", plan, NULL, 0)) {
                cJSON_Delete(o); goto oom;
            }
        }

        /* 自然语言理由 */
        reasons = build_user_reasons(plan, sched, status, i);
        {
            cJSON *ra = cJSON_AddArrayToObject(o, "reasons");
            if (ra == NULL) { ts_free(reasons); cJSON_Delete(o); goto oom; }
            if (add_reason_lines(ra, reasons)) {
                ts_free(reasons);
                cJSON_Delete(o);
                goto oom;
            }
        }
        ts_free(reasons);

        /* 时间轴 */
        if (bars[i].scheduled) {
            if (cJSON_AddStringToObject(o, "scheduleState", "scheduled") == NULL ||
                cJSON_AddNumberToObject(o, "startHours", bars[i].start) == NULL ||
                cJSON_AddNumberToObject(o, "endHours", bars[i].end) == NULL ||
                cJSON_AddNullToObject(o, "scheduleNote") == NULL) {
                cJSON_Delete(o); goto oom;
            }
        } else {
            const char *note = (bars[i].note != NULL) ? bars[i].note : "未排期";
            const char *state = "unscheduled";
            if (t->actual_status == TS_ACTUAL_DONE) state = "completed";
            else if (st == TS_BLOCKED) state = "blocked";
            else if (st == TS_PENDING_CONFIRM) state = "pending";
            else if (!t->has_estimated_hours) state = "unknownHours";
            if (cJSON_AddStringToObject(o, "scheduleState", state) == NULL ||
                cJSON_AddNullToObject(o, "startHours") == NULL ||
                cJSON_AddNullToObject(o, "endHours") == NULL ||
                cJSON_AddStringToObject(o, "scheduleNote", note) == NULL) {
                cJSON_Delete(o); goto oom;
            }
        }
        if (t->previous_task_id != NULL) {
            if (cJSON_AddStringToObject(o, "previousTaskId", t->previous_task_id) == NULL) {
                cJSON_Delete(o); goto oom;
            }
        }

        cJSON_AddItemToArray(tasks, o);
    }

    /* 顺序、分组清单 */
    if (sched != NULL) {
        cJSON *order = cJSON_AddArrayToObject(root, "order");
        if (order == NULL) goto oom;
        for (i = 0; i < sched->step_count; i++) {
            if (cJSON_AddItemToArray(order,
                    cJSON_CreateString(sched->steps[i].task_id)) == 0) goto oom;
        }
        if (add_id_array(root, "blocked", sched->blocked_ids, sched->blocked_count)) goto oom;
        if (add_id_array(root, "pending", sched->pending_ids, sched->pending_count)) goto oom;
        if (add_id_array(root, "affected", sched->affected_ids, sched->affected_count)) goto oom;
    } else {
        if (cJSON_AddArrayToObject(root, "order") == NULL ||
            cJSON_AddArrayToObject(root, "blocked") == NULL ||
            cJSON_AddArrayToObject(root, "pending") == NULL ||
            cJSON_AddArrayToObject(root, "affected") == NULL) goto oom;
    }

    /* 待确认 / 受阻 / 假设（带任务引用，可跳转） */
    {
        cJSON *notes = cJSON_AddArrayToObject(root, "notes");
        if (notes == NULL) goto oom;
        for (i = 0; i < plan->note_count; i++) {
            cJSON *o = cJSON_CreateObject();
            const char *kind =
                (plan->notes[i].kind == TS_NOTE_BLOCKED) ? "blocked" :
                (plan->notes[i].kind == TS_NOTE_ASSUMPTION) ? "assumption" : "question";
            if (o == NULL ||
                cJSON_AddStringToObject(o, "kind", kind) == NULL ||
                cJSON_AddStringToObject(o, "text", plan->notes[i].text) == NULL) {
                if (o != NULL) cJSON_Delete(o);
                goto oom;
            }
            if (add_related(o, "tasks", plan, plan->notes[i].task_refs,
                            plan->notes[i].task_ref_count)) {
                cJSON_Delete(o);
                goto oom;
            }
            cJSON_AddItemToArray(notes, o);
        }
    }

    /* 汇总计数（界面角标） */
    {
        cJSON *counts = cJSON_AddObjectToObject(root, "counts");
        int ready = 0, waiting = 0, blocked = 0, pending = 0, done = 0, unknown_hours = 0;
        if (counts == NULL) goto oom;
        for (i = 0; i < plan->task_count; i++) {
            TsReadyState st = (status != NULL && status->states != NULL)
                                  ? status->states[i]
                                  : ((plan->tasks[i].actual_status == TS_ACTUAL_DONE)
                                        ? TS_DONE : TS_READY);
            TsReadyState raw = st;
            if (raw == TS_DONE) done++;
            else if (raw == TS_READY) ready++;
            else if (raw == TS_WAITING_DEP) waiting++;
            else if (raw == TS_PENDING_CONFIRM) pending++;
            else if (raw == TS_BLOCKED) blocked++;
            if (!plan->tasks[i].has_estimated_hours &&
                plan->tasks[i].actual_status != TS_ACTUAL_DONE) unknown_hours++;
        }
        if (cJSON_AddNumberToObject(counts, "total", (double)plan->task_count) == NULL ||
            cJSON_AddNumberToObject(counts, "ready", (double)ready) == NULL ||
            cJSON_AddNumberToObject(counts, "waiting", (double)waiting) == NULL ||
            cJSON_AddNumberToObject(counts, "blocked", (double)blocked) == NULL ||
            cJSON_AddNumberToObject(counts, "pending", (double)pending) == NULL ||
            cJSON_AddNumberToObject(counts, "done", (double)done) == NULL ||
            cJSON_AddNumberToObject(counts, "unknownHours", (double)unknown_hours) == NULL) {
            goto oom;
        }
    }

    printed = cJSON_PrintUnformatted(root);
    if (printed == NULL) goto oom;
    *out = printed;
    if (out_len != NULL) *out_len = strlen(printed);
    rc = 0;
    goto done;

oom:
    oom(err, err_sz);
done:
    ts_free(bars);
    if (root != NULL) cJSON_Delete(root);
    return rc;
}

