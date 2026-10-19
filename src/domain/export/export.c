/*
 * export.c — TXT 导出与导出格式分派（不依赖 cJSON）。
 *
 * 主要函数：ts_export_txt、ts_export_write_file、ts_export_format_from_path、
 * ts_export_state_label、ts_export_find_blocking_ancestor。
 */


#include "export.h"
#include "export_internal.h"
#include "mem.h"
#include "text.h"
#include "runtime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* 公共小工具（供 export_json.c 复用）                                 */
/* ------------------------------------------------------------------ */

const char *ts_export_state_label(TsReadyState st)
{
    switch (st) {
    case TS_READY:           return "可开始";
    case TS_WAITING_DEP:     return "等待前置任务";
    case TS_PENDING_CONFIRM: return "待确认";
    case TS_BLOCKED:         return "受阻";
    case TS_DONE:            return "已完成";
    default:                 return "未知";
    }
}

const char *ts_export_ready_state_name(TsReadyState st)
{
    switch (st) {
    case TS_READY:           return "ready";
    case TS_WAITING_DEP:     return "waiting_dep";
    case TS_PENDING_CONFIRM: return "pending_confirm";
    case TS_BLOCKED:         return "blocked";
    case TS_DONE:            return "done";
    default:                 return "unknown";
    }
}

const char *ts_export_precond_label(TsPrecondStatus st)
{
    switch (st) {
    case TS_PRECOND_MET:     return "已满足";
    case TS_PRECOND_UNMET:   return "未满足";
    case TS_PRECOND_UNKNOWN: return "未知";
    default:                 return "未知";
    }
}

const char *ts_export_precond_name(TsPrecondStatus st)
{
    switch (st) {
    case TS_PRECOND_MET:     return "met";
    case TS_PRECOND_UNMET:   return "unmet";
    case TS_PRECOND_UNKNOWN: return "unknown";
    default:                 return "unknown";
    }
}

size_t ts_export_find_task_index(const TsPlan *plan, const char *id)
{
    size_t i;
    if (plan == NULL || id == NULL) return SIZE_MAX;
    for (i = 0; i < plan->task_count; i++) {
        if (plan->tasks[i].id != NULL && strcmp(plan->tasks[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}

const char *ts_export_task_name_by_id(const TsPlan *plan, const char *id)
{
    size_t i = ts_export_find_task_index(plan, id);
    if (i == SIZE_MAX) return "?";
    return (plan->tasks[i].name != NULL) ? plan->tasks[i].name : "?";
}

int ts_export_join_preconds(const TsTask *t, TsPrecondStatus want, TsBuf *b)
{
    size_t i;
    int n = 0;
    for (i = 0; i < t->preconditions_count; i++) {
        if (t->preconditions[i].status == want) {
            if (n > 0) ts_buf_puts(b, "；");
            ts_buf_printf(b, "%s（%s）", t->preconditions[i].description,
                          ts_export_precond_label(want));
            n++;
        }
    }
    return n;
}

size_t ts_export_find_blocking_ancestor(const TsPlan *plan, size_t task_index,
                                        const unsigned char *is_blocked_or_pending)
{
    size_t n;
    unsigned char *vis;
    size_t *q;
    size_t h = 0, t = 0, k;
    size_t found = SIZE_MAX;

    if (plan == NULL || is_blocked_or_pending == NULL) return SIZE_MAX;
    n = plan->task_count;
    if (n == 0 || task_index >= n) return SIZE_MAX;

    vis = (unsigned char *)ts_calloc(n, 1);
    q = (size_t *)ts_malloc(n * sizeof(size_t));
    if (vis == NULL || q == NULL) {
        ts_free(vis);
        ts_free(q);
        return SIZE_MAX;
    }
    vis[task_index] = 1;
    for (k = 0; k < plan->tasks[task_index].depends_on_count; k++) {
        size_t p = ts_export_find_task_index(plan, plan->tasks[task_index].depends_on[k]);
        if (p != SIZE_MAX && !vis[p]) { vis[p] = 1; q[t++] = p; }
    }
    while (h < t) {
        size_t u = q[h++];
        if (is_blocked_or_pending[u]) { found = u; break; }
        for (k = 0; k < plan->tasks[u].depends_on_count; k++) {
            size_t p = ts_export_find_task_index(plan, plan->tasks[u].depends_on[k]);
            if (p != SIZE_MAX && !vis[p]) { vis[p] = 1; q[t++] = p; }
        }
    }
    ts_free(vis);
    ts_free(q);
    return found;
}

int ts_export_write_file(const char *path, const char *data, size_t len,
                         int with_bom, char *err, size_t err_sz)
{
    static const unsigned char bom[3] = { 0xEF, 0xBB, 0xBF };
    wchar_t *wpath;
    FILE *f;
    int rc = 0;

    if (path == NULL || path[0] == '\0') {
        snprintf(err, err_sz, "导出路径为空");
        return 1;
    }
    wpath = ts_utf8_to_wide(path, strlen(path), NULL);
    if (wpath == NULL) {
        snprintf(err, err_sz, "导出路径编码转换失败：%s", path);
        return 1;
    }
    f = _wfopen(wpath, L"wb");
    if (f == NULL) {
        snprintf(err, err_sz, "无法创建导出文件：%s", path);
        ts_free(wpath);
        return 1;
    }
    if (with_bom && fwrite(bom, 1, sizeof(bom), f) != sizeof(bom)) {
        rc = 1;
    }
    if (rc == 0 && len > 0 && fwrite(data, 1, len, f) != len) {
        rc = 1;
    }
    if (fclose(f) != 0) {
        rc = 1;
    }
    if (rc != 0) {
        snprintf(err, err_sz, "写入导出文件失败（磁盘空间或权限？）：%s", path);
        _wremove(wpath);
    }
    ts_free(wpath);
    return rc;
}

/* ------------------------------------------------------------------ */
/* TXT 内容构造                                                        */
/* ------------------------------------------------------------------ */

static void txt_header(const TsPlan *plan, const TsScheduleResult *sched,
                       const TsConfig *cfg, TsBuf *b)
{
    char now[32];
    ts_clock_wall_iso(now, sizeof(now));

    ts_buf_puts(b, "TaskScheduler 任务分析结果\n");
    ts_buf_puts(b, "================================================================\n");
    ts_buf_printf(b, "导出时间：%s\n", now);
    if (sched != NULL && sched->sorted_at[0] != '\0') {
        ts_buf_printf(b, "排序时间：%s\n", sched->sorted_at);
    }
    ts_buf_printf(b, "算法版本：%s    协议版本（schema_version）：%s\n",
                  TS_ALGORITHM_VERSION, TS_SCHEMA_VERSION);
    if (plan != NULL) {
        ts_buf_printf(b, "任务数量：%zu\n", plan->task_count);
    }
    ts_buf_puts(b, "排序权重：");
    if (cfg == NULL) {
        ts_buf_puts(b, "（未提供配置）");
    } else {
        ts_buf_printf(b, "紧迫性 %.2f / 影响力 %.2f / 阻塞性 %.2f / 工时优势 %.2f / 依赖深度 %.2f",
                      cfg->w_urgency, cfg->w_impact, cfg->w_blocking,
                      cfg->w_quick_win, cfg->w_depth);
        ts_buf_printf(b, "    工时参考值：%.2f 小时", cfg->reference_hours);
    }
    ts_buf_puts(b, "\n");
    ts_buf_puts(b, "说明：模型只负责分析，本程序只负责规划与展示；任务完成状态由用户维护。\n\n");
}

static void txt_steps(const TsTask *t, TsBuf *b)
{
    size_t k;
    if (t->steps_count == 0) {
        ts_buf_puts(b, "        （模型未给出步骤）\n");
        return;
    }
    for (k = 0; k < t->steps_count; k++) {
        ts_buf_printf(b, "        %zu. %s\n", k + 1, t->steps[k]);
    }
}

static void txt_preconds(const TsTask *t, TsBuf *b)
{
    size_t k;
    if (t->preconditions_count == 0) {
        ts_buf_puts(b, "        无\n");
        return;
    }
    for (k = 0; k < t->preconditions_count; k++) {
        ts_buf_printf(b, "        [%s] %s\n",
                      ts_export_precond_label(t->preconditions[k].status),
                      t->preconditions[k].description);
    }
}

static void txt_order_section(const TsPlan *plan, const TsScheduleResult *sched,
                              const TsStatusView *status, const TsConfig *cfg, TsBuf *b)
{
    size_t i, k;

    ts_buf_puts(b, "================ 一、建议执行顺序 ================\n");
    if (sched == NULL || sched->step_count == 0) {
        ts_buf_puts(b, "（当前没有可立即执行的任务）\n");
        if (sched != NULL && sched->unresolvable_reason != NULL) {
            ts_buf_printf(b, "原因：%s\n", sched->unresolvable_reason);
        }
        ts_buf_puts(b, "\n");
        return;
    }

    for (i = 0; i < sched->step_count; i++) {
        const TsScheduleStep *s = &sched->steps[i];
        size_t ti = s->task_index;
        const TsTask *t;
        TsReadyState st = TS_READY;
        int lvl = -1;

        if (plan == NULL || ti >= plan->task_count) continue;
        t = &plan->tasks[ti];
        if (status != NULL && status->states != NULL) st = status->states[ti];
        if (status != NULL && status->level != NULL) lvl = status->level[ti];

        ts_buf_printf(b, "第 %zu 步    %s  %s\n", i + 1, t->id, t->name);
        ts_buf_printf(b, "    状态：%s", ts_export_state_label(st));
        if (lvl >= 0) ts_buf_printf(b, "        依赖层级：第 %d 层", lvl);
        if (status != NULL && status->affected != NULL && status->affected[ti]) {
            ts_buf_puts(b, "        （受上游受阻/待确认影响）");
        }
        ts_buf_puts(b, "\n");

        ts_buf_puts(b, "    前置任务：");
        if (t->depends_on_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < t->depends_on_count; k++) {
                ts_buf_printf(b, "%s%s（%s）", (k > 0) ? "、" : "",
                              t->depends_on[k], ts_export_task_name_by_id(plan, t->depends_on[k]));
            }
            ts_buf_puts(b, "\n");
        }

        ts_buf_printf(b, "    截止时间：%s", (t->deadline != NULL) ? t->deadline : "未知");
        if (t->has_estimated_hours) {
            ts_buf_printf(b, "        预计工时：%.2f 小时\n", t->estimated_hours);
        } else {
            ts_buf_puts(b, "        预计工时：未知（待确认）\n");
        }

        ts_buf_puts(b, "    执行步骤：\n");
        txt_steps(t, b);

        ts_buf_puts(b, "    外部条件：\n");
        txt_preconds(t, b);

        /* 等式必须能复算：基础分是加权和，因此写清权重与乘积 */
        {
            double wu = (cfg != NULL) ? cfg->w_urgency : 0.35;
            double wi = (cfg != NULL) ? cfg->w_impact : 0.30;
            double wb = (cfg != NULL) ? cfg->w_blocking : 0.20;
            double wq = (cfg != NULL) ? cfg->w_quick_win : 0.10;
            double wd = (cfg != NULL) ? cfg->w_depth : 0.05;
            ts_buf_puts(b, "    排序理由（可按等式复算）：\n");
            ts_buf_printf(b, "        归一化维度：U=%.3f  I=%.3f  B=%.3f  Q=%.3f  D=%.3f\n",
                          s->score.u, s->score.i, s->score.b, s->score.q, s->score.d);
            ts_buf_printf(b, "        基础分 = 100×（%.2f×U + %.2f×I + %.2f×B + %.2f×Q + %.2f×D）"
                             " = %.2f\n", wu, wi, wb, wq, wd, s->score.base);
            ts_buf_printf(b, "        全局加分 = 10×C(%.3f)=%.2f + 7×R(%.3f)=%.2f + 3×W(%.3f)=%.2f"
                             " = %.2f\n",
                          s->score.c, 10.0 * s->score.c,
                          s->score.r, 7.0 * s->score.r,
                          s->score.w, 3.0 * s->score.w,
                          10.0 * s->score.c + 7.0 * s->score.r + 3.0 * s->score.w);
            ts_buf_printf(b, "        最终得分 = 基础分 + 全局加分 = %.2f\n", s->score.final);
        }
        if (s->score.hours_unknown) {
            ts_buf_puts(b, "        备注：工时未知，工时优势按 0.5 计算，并标记为待确认。\n");
        }
        if (s->score.chain_incomplete) {
            ts_buf_puts(b, "        备注：关键链涉及未知工时，未提供确定的关键链加分。\n");
        }
        if (s->candidate_count > 0) {
            ts_buf_puts(b, "        选择时的候选任务：");
            for (k = 0; k < s->candidate_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", s->candidates[k]);
            }
            ts_buf_puts(b, "\n");
        }

        ts_buf_puts(b, "    完成后立即解锁：");
        if (s->unlocked_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < s->unlocked_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", s->unlocked[k]);
            }
            ts_buf_puts(b, "\n");
        }
        ts_buf_puts(b, "    仍需其他前置才能解锁：");
        if (s->still_waiting_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < s->still_waiting_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", s->still_waiting[k]);
            }
            ts_buf_puts(b, "\n");
        }

        ts_buf_puts(b, "    来源引用：");
        if (t->source_refs_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < t->source_refs_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", t->source_refs[k]);
            }
            ts_buf_puts(b, "\n");
        }
        ts_buf_puts(b, "\n");
    }
}

static void txt_id_list(const TsPlan *plan, char *const *ids, size_t count,
                        TsPrecondStatus want, TsBuf *b)
{
    size_t i;
    if (plan == NULL || count == 0) {
        ts_buf_puts(b, "无\n");
        return;
    }
    for (i = 0; i < count; i++) {
        size_t ti = ts_export_find_task_index(plan, ids[i]);
        ts_buf_printf(b, "  %s  %s\n", ids[i],
                      (ti != SIZE_MAX) ? plan->tasks[ti].name : "?");
        if (ti != SIZE_MAX) {
            TsBuf r;
            ts_buf_init(&r);
            if (ts_export_join_preconds(&plan->tasks[ti], want, &r) == 0) {
                ts_buf_puts(&r, (want == TS_PRECOND_UNMET) ? "外部条件未满足"
                                                           : "外部条件状态未知");
            }
            ts_buf_printf(b, "      原因：%s\n", r.data);
            ts_buf_free(&r);
        }
    }
}

static void build_txt(const TsPlan *plan, const TsScheduleResult *sched,
                      const TsStatusView *status, const TsConfig *cfg, TsBuf *b)
{
    size_t i;

    txt_header(plan, sched, cfg, b);
    txt_order_section(plan, sched, status, cfg, b);

    /* 受阻 / 待确认 / 受影响 —— 单独列出，绝不混入上面的可执行序列 */
    ts_buf_puts(b, "================ 二、受阻任务（外部条件未满足） ================\n");
    ts_buf_puts(b, "（注意：以下任务不具备可执行条件，未包含在上面的建议执行顺序中。）\n");
    if (sched == NULL) ts_buf_puts(b, "无\n");
    else txt_id_list(plan, sched->blocked_ids, sched->blocked_count, TS_PRECOND_UNMET, b);
    ts_buf_puts(b, "\n");

    ts_buf_puts(b, "================ 三、待确认任务（外部条件未知） ================\n");
    if (sched == NULL) ts_buf_puts(b, "无\n");
    else txt_id_list(plan, sched->pending_ids, sched->pending_count, TS_PRECOND_UNKNOWN, b);
    ts_buf_puts(b, "\n");

    ts_buf_puts(b, "================ 四、受影响任务（上游受阻或待确认） ================\n");
    /* 显式要求 plan 非空：下面的 plan->tasks[] 访问才有静态可证的安全性 */
    if (plan == NULL || sched == NULL || sched->affected_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        unsigned char *is_bp = (unsigned char *)ts_calloc(plan->task_count, 1);
        if (is_bp != NULL) {
            size_t k;
            for (k = 0; k < sched->blocked_count; k++) {
                size_t ti = ts_export_find_task_index(plan, sched->blocked_ids[k]);
                if (ti != SIZE_MAX) is_bp[ti] = 1;
            }
            for (k = 0; k < sched->pending_count; k++) {
                size_t ti = ts_export_find_task_index(plan, sched->pending_ids[k]);
                if (ti != SIZE_MAX) is_bp[ti] = 1;
            }
        }
        for (i = 0; i < sched->affected_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->affected_ids[i]);
            ts_buf_printf(b, "  %s  %s", sched->affected_ids[i],
                          (ti != SIZE_MAX) ? plan->tasks[ti].name : "?");
            if (ti != SIZE_MAX && is_bp != NULL) {
                size_t anc = ts_export_find_blocking_ancestor(plan, ti, is_bp);
                if (anc != SIZE_MAX) {
                    ts_buf_printf(b, "    ← 受 %s 影响", plan->tasks[anc].id);
                }
            }
            ts_buf_puts(b, "\n");
        }
        ts_free(is_bp);
    }
    if (sched != NULL && sched->unresolvable_reason != NULL) {
        ts_buf_printf(b, "\n无任务可立即执行的原因：%s\n", sched->unresolvable_reason);
    }
    ts_buf_puts(b, "\n");

    /* 未排入建议顺序的任务（例如已完成） */
    ts_buf_puts(b, "================ 五、未排入建议顺序的其他任务 ================\n");
    if (plan == NULL || plan->task_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        unsigned char *placed = (unsigned char *)ts_calloc(plan->task_count, 1);
        int any = 0;
        if (placed != NULL) {
            if (sched != NULL) {
                for (i = 0; i < sched->step_count; i++) {
                    if (sched->steps[i].task_index < plan->task_count) {
                        placed[sched->steps[i].task_index] = 1;
                    }
                }
            }
            for (i = 0; i < plan->task_count; i++) {
                if (!placed[i]) {
                    any = 1;
                    ts_buf_printf(b, "  %s  %s    状态：%s\n", plan->tasks[i].id,
                                  plan->tasks[i].name,
                                  (status != NULL && status->states != NULL)
                                      ? ts_export_state_label(status->states[i]) : "未知");
                }
            }
            ts_free(placed);
        }
        if (!any) ts_buf_puts(b, "无\n");
    }
    ts_buf_puts(b, "\n");

    /* 假设与待确认事项 */
    ts_buf_puts(b, "================ 六、模型的假设 ================\n");
    if (plan == NULL || plan->assumptions_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        for (i = 0; i < plan->assumptions_count; i++) {
            ts_buf_printf(b, "  · %s\n", plan->assumptions[i]);
        }
    }
    ts_buf_puts(b, "\n");

    ts_buf_puts(b, "================ 七、待确认事项 ================\n");
    if (plan == NULL || plan->questions_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        for (i = 0; i < plan->questions_count; i++) {
            ts_buf_printf(b, "  · %s\n", plan->questions[i]);
        }
    }
    ts_buf_puts(b, "\n");

    ts_buf_puts(b, "================================================================\n");
    ts_buf_puts(b, "说明：取消客户端请求不保证服务端停止推理；导出的时间戳为本地时间。\n");
}

/* ------------------------------------------------------------------ */
/* 对外接口                                                            */
/* ------------------------------------------------------------------ */

int ts_export_txt(const TsPlan *plan, const TsScheduleResult *sched,
                  const TsStatusView *status, const TsConfig *cfg,
                  const char *path, char *err, size_t err_sz)
{
    TsBuf b;
    int rc;

    if (plan == NULL) {
        snprintf(err, err_sz, "没有可导出的分析结果");
        return 1;
    }
    if (err != NULL && err_sz > 0) err[0] = '\0';

    ts_buf_init(&b);
    build_txt(plan, sched, status, cfg, &b);
    if (b.data == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    rc = ts_export_write_file(path, b.data, b.len, 1, err, err_sz);
    ts_buf_free(&b);
    return rc;
}

TsExportFormat ts_export_format_from_path(const char *path)
{
    size_t len;
    if (path == NULL) return TS_EXPORT_TXT;
    len = strlen(path);
    if (len >= 5 && _stricmp(path + len - 5, ".json") == 0) {
        return TS_EXPORT_JSON;
    }
    return TS_EXPORT_TXT;
}

