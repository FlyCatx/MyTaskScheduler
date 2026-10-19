/*
 * export_json.c — JSON 导出（cJSON 构造，不写入 API Key）。
 *
 * 主要函数：ts_export_json、ts_export_plan、ts_export_json_usage、ts_export_plan_usage。
 */


#include "export.h"
#include "export_internal.h"
#include "mem.h"
#include "runtime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"

/* ------------------------------------------------------------------ */
/* JSON 片段构造                                                       */
/* ------------------------------------------------------------------ */

/* 只写入环境变量名（api_key_env）与“是否存在”，绝不写入密钥本身。 */
static cJSON *json_config(const TsConfig *cfg)
{
    cJSON *o = cJSON_CreateObject();
    cJSON *w;
    if (o == NULL) return NULL;

    cJSON_AddStringToObject(o, "endpoint_url",
                            (cfg != NULL && cfg->endpoint_url != NULL) ? cfg->endpoint_url : "");
    cJSON_AddStringToObject(o, "model",
                            (cfg != NULL && cfg->model != NULL) ? cfg->model : "");
    cJSON_AddStringToObject(o, "api_key_env",
                            (cfg != NULL && cfg->api_key_env != NULL) ? cfg->api_key_env : "");
    cJSON_AddBoolToObject(o, "api_key_present",
                          (cfg != NULL && cfg->api_key != NULL && cfg->api_key[0] != '\0') ? 1 : 0);
    /* 只写“来源”（config_inline / env / none），绝不写入密钥内容 */
    if (cfg != NULL) {
        int src = ts_config_api_key_source(cfg);
        cJSON_AddStringToObject(o, "api_key_source",
                                (src == 1) ? "config_inline"
                                           : ((src == 2) ? "env" : "none"));
    } else {
        cJSON_AddStringToObject(o, "api_key_source", "none");
    }
    /* 只写入实际加载的配置路径，便于确认“程序读的是哪一份 config.json”。 */
    cJSON_AddStringToObject(o, "config_path",
                            (cfg != NULL && cfg->config_path != NULL) ? cfg->config_path : "");
    cJSON_AddStringToObject(o, "ca_bundle_path",
                            (cfg != NULL && cfg->ca_bundle_path != NULL) ? cfg->ca_bundle_path : "");
    cJSON_AddStringToObject(o, "reasoning_effort",
                            (cfg != NULL && cfg->reasoning_effort != NULL)
                                ? cfg->reasoning_effort : "(未发送)");
    cJSON_AddNumberToObject(o, "reference_hours", (cfg != NULL) ? cfg->reference_hours : 0.0);
    cJSON_AddBoolToObject(o, "json_mode", (cfg != NULL) ? cfg->json_mode : 0);
    cJSON_AddBoolToObject(o, "mock_mode", (cfg != NULL) ? cfg->mock_mode : 0);

    w = cJSON_CreateObject();
    if (w == NULL) return o;
    cJSON_AddNumberToObject(w, "urgency",   (cfg != NULL) ? cfg->w_urgency : 0.0);
    cJSON_AddNumberToObject(w, "impact",    (cfg != NULL) ? cfg->w_impact : 0.0);
    cJSON_AddNumberToObject(w, "blocking",  (cfg != NULL) ? cfg->w_blocking : 0.0);
    cJSON_AddNumberToObject(w, "quick_win", (cfg != NULL) ? cfg->w_quick_win : 0.0);
    cJSON_AddNumberToObject(w, "depth",     (cfg != NULL) ? cfg->w_depth : 0.0);
    if (!cJSON_AddItemToObject(o, "weights", w)) {
        cJSON_Delete(w);
    }
    return o;
}

static cJSON *json_str_array(char *const *items, size_t count)
{
    cJSON *arr = cJSON_CreateArray();
    size_t i;
    if (arr == NULL) return NULL;
    for (i = 0; i < count; i++) {
        cJSON *s = cJSON_CreateString((items[i] != NULL) ? items[i] : "");
        if (s == NULL || !cJSON_AddItemToArray(arr, s)) {
            if (s != NULL) cJSON_Delete(s);
            cJSON_Delete(arr);
            return NULL;
        }
    }
    return arr;
}

static cJSON *json_score(const TsScoreBreakdown *sc)
{
    cJSON *o = cJSON_CreateObject();
    if (o == NULL) return NULL;
    cJSON_AddNumberToObject(o, "u", sc->u);
    cJSON_AddNumberToObject(o, "i", sc->i);
    cJSON_AddNumberToObject(o, "b", sc->b);
    cJSON_AddNumberToObject(o, "q", sc->q);
    cJSON_AddNumberToObject(o, "d", sc->d);
    cJSON_AddNumberToObject(o, "base", sc->base);
    cJSON_AddNumberToObject(o, "c", sc->c);
    cJSON_AddNumberToObject(o, "r", sc->r);
    cJSON_AddNumberToObject(o, "w", sc->w);
    cJSON_AddNumberToObject(o, "c_weighted", 10.0 * sc->c);
    cJSON_AddNumberToObject(o, "r_weighted", 7.0 * sc->r);
    cJSON_AddNumberToObject(o, "w_weighted", 3.0 * sc->w);
    cJSON_AddNumberToObject(o, "final", sc->final);
    cJSON_AddBoolToObject(o, "hours_unknown", sc->hours_unknown);
    cJSON_AddBoolToObject(o, "chain_incomplete", sc->chain_incomplete);
    return o;
}

/* 受阻 / 待确认 / 受影响清单。 */
static int json_lists(const TsPlan *plan, const TsScheduleResult *sched,
                      const unsigned char *is_bp, cJSON *root)
{
    cJSON *blocked = cJSON_CreateArray();
    cJSON *pending = cJSON_CreateArray();
    cJSON *affected = cJSON_CreateArray();
    size_t i;

    if (blocked == NULL || pending == NULL || affected == NULL) {
        if (blocked) cJSON_Delete(blocked);
        if (pending) cJSON_Delete(pending);
        if (affected) cJSON_Delete(affected);
        return 1;
    }

    if (sched != NULL) {
        for (i = 0; i < sched->blocked_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->blocked_ids[i]);
            cJSON *e = cJSON_CreateObject();
            TsBuf r;
            if (e == NULL) goto fail;
            cJSON_AddStringToObject(e, "id", sched->blocked_ids[i]);
            cJSON_AddStringToObject(e, "name", (ti != SIZE_MAX) ? plan->tasks[ti].name : "");
            ts_buf_init(&r);
            if (ti != SIZE_MAX) {
                if (ts_export_join_preconds(&plan->tasks[ti], TS_PRECOND_UNMET, &r) == 0) {
                    ts_buf_puts(&r, "外部条件未满足");
                }
            }
            cJSON_AddStringToObject(e, "reason", (r.data != NULL) ? r.data : "");
            ts_buf_free(&r);
            if (!cJSON_AddItemToArray(blocked, e)) { cJSON_Delete(e); goto fail; }
        }
        for (i = 0; i < sched->pending_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->pending_ids[i]);
            cJSON *e = cJSON_CreateObject();
            TsBuf r;
            if (e == NULL) goto fail;
            cJSON_AddStringToObject(e, "id", sched->pending_ids[i]);
            cJSON_AddStringToObject(e, "name", (ti != SIZE_MAX) ? plan->tasks[ti].name : "");
            ts_buf_init(&r);
            if (ti != SIZE_MAX) {
                if (ts_export_join_preconds(&plan->tasks[ti], TS_PRECOND_UNKNOWN, &r) == 0) {
                    ts_buf_puts(&r, "外部条件状态未知");
                }
            }
            cJSON_AddStringToObject(e, "reason", (r.data != NULL) ? r.data : "");
            ts_buf_free(&r);
            if (!cJSON_AddItemToArray(pending, e)) { cJSON_Delete(e); goto fail; }
        }
        for (i = 0; i < sched->affected_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->affected_ids[i]);
            cJSON *e = cJSON_CreateObject();
            if (e == NULL) goto fail;
            cJSON_AddStringToObject(e, "id", sched->affected_ids[i]);
            cJSON_AddStringToObject(e, "name", (ti != SIZE_MAX) ? plan->tasks[ti].name : "");
            if (ti != SIZE_MAX && is_bp != NULL) {
                size_t anc = ts_export_find_blocking_ancestor(plan, ti, is_bp);
                if (anc != SIZE_MAX) {
                    cJSON_AddStringToObject(e, "blocked_by", plan->tasks[anc].id);
                } else {
                    cJSON_AddNullToObject(e, "blocked_by");
                }
            } else {
                cJSON_AddNullToObject(e, "blocked_by");
            }
            if (!cJSON_AddItemToArray(affected, e)) { cJSON_Delete(e); goto fail; }
        }
    }

    if (!cJSON_AddItemToObject(root, "blocked", blocked)) { cJSON_Delete(blocked); goto fail; }
    if (!cJSON_AddItemToObject(root, "pending", pending)) { cJSON_Delete(pending); goto fail; }
    if (!cJSON_AddItemToObject(root, "affected", affected)) { cJSON_Delete(affected); goto fail; }
    return 0;

fail:
    cJSON_Delete(blocked);
    cJSON_Delete(pending);
    cJSON_Delete(affected);
    return 1;
}

static int build_json(const TsPlan *plan, const TsScheduleResult *sched,
                      const TsStatusView *status, const TsConfig *cfg,
                      const TsTokenUsageStat *usage,
                      cJSON **out_root, char *err, size_t err_sz)
{
    cJSON *root = NULL;
    cJSON *tasks = NULL;
    cJSON *order = NULL;
    cJSON *arr = NULL;
    unsigned char *is_bp = NULL;
    size_t i, k, n;
    char now[32];
    int rc = 1;

    n = plan->task_count;
    ts_clock_wall_iso(now, sizeof(now));

    root = cJSON_CreateObject();
    tasks = cJSON_CreateArray();
    order = cJSON_CreateArray();
    if (root == NULL || tasks == NULL || order == NULL) goto done;

    cJSON_AddStringToObject(root, "schema_version", TS_SCHEMA_VERSION);
    cJSON_AddStringToObject(root, "algorithm_version", TS_ALGORITHM_VERSION);
    cJSON_AddStringToObject(root, "exported_at", now);
    cJSON_AddStringToObject(root, "sorted_at",
                            (sched != NULL && sched->sorted_at[0] != '\0') ? sched->sorted_at : now);
    cJSON_AddStringToObject(root, "producer", "TaskScheduler (C, Win32)");
    {
        cJSON *co = json_config(cfg);
        if (co == NULL) co = cJSON_CreateObject();
        if (co == NULL) goto done;
        if (!cJSON_AddItemToObject(root, "config", co)) {
            cJSON_Delete(co);
            goto done;
        }
    }

    /* 受阻/待确认标记，用于受影响任务的溯源 */
    is_bp = (unsigned char *)ts_calloc((n > 0) ? n : 1, 1);
    if (is_bp == NULL) goto done;
    if (sched != NULL) {
        for (i = 0; i < sched->blocked_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->blocked_ids[i]);
            if (ti != SIZE_MAX) is_bp[ti] = 1;
        }
        for (i = 0; i < sched->pending_count; i++) {
            size_t ti = ts_export_find_task_index(plan, sched->pending_ids[i]);
            if (ti != SIZE_MAX) is_bp[ti] = 1;
        }
    }

    for (i = 0; i < n; i++) {
        const TsTask *t = &plan->tasks[i];
        cJSON *o = cJSON_CreateObject();
        cJSON *pre = cJSON_CreateArray();
        size_t step_index = SIZE_MAX;

        if (o == NULL || pre == NULL) {
            if (o != NULL) cJSON_Delete(o);
            if (pre != NULL) cJSON_Delete(pre);
            goto done;
        }

        cJSON_AddStringToObject(o, "id", (t->id != NULL) ? t->id : "");
        cJSON_AddStringToObject(o, "name", (t->name != NULL) ? t->name : "");

        arr = json_str_array(t->depends_on, t->depends_on_count);
        if (arr == NULL) { cJSON_Delete(o); cJSON_Delete(pre); goto done; }
        cJSON_AddItemToObject(o, "depends_on", arr);

        for (k = 0; k < t->preconditions_count; k++) {
            cJSON *p = cJSON_CreateObject();
            if (p == NULL) { cJSON_Delete(o); cJSON_Delete(pre); goto done; }
            cJSON_AddStringToObject(p, "description",
                                    (t->preconditions[k].description != NULL)
                                        ? t->preconditions[k].description : "");
            cJSON_AddStringToObject(p, "status", ts_export_precond_name(t->preconditions[k].status));
            if (!cJSON_AddItemToArray(pre, p)) {
                cJSON_Delete(p);
                cJSON_Delete(o);
                cJSON_Delete(pre);
                goto done;
            }
        }
        if (!cJSON_AddItemToObject(o, "preconditions", pre)) {
            cJSON_Delete(pre);
            cJSON_Delete(o);
            goto done;
        }

        arr = json_str_array(t->steps, t->steps_count);
        if (arr == NULL) { cJSON_Delete(o); goto done; }
        cJSON_AddItemToObject(o, "steps", arr);

        cJSON_AddNumberToObject(o, "urgency", (double)t->urgency);
        cJSON_AddStringToObject(o, "urgency_reason",
                                (t->urgency_reason != NULL) ? t->urgency_reason : "");
        cJSON_AddNumberToObject(o, "impact", (double)t->impact);
        cJSON_AddStringToObject(o, "impact_reason",
                                (t->impact_reason != NULL) ? t->impact_reason : "");

        if (t->has_estimated_hours) {
            cJSON_AddNumberToObject(o, "estimated_hours", t->estimated_hours);
        } else {
            cJSON_AddNullToObject(o, "estimated_hours");   /* 未知，绝不当作 0 */
        }
        if (t->estimate_reason != NULL) {
            cJSON_AddStringToObject(o, "estimate_reason", t->estimate_reason);
        } else {
            cJSON_AddNullToObject(o, "estimate_reason");
        }
        if (t->deadline != NULL) {
            cJSON_AddStringToObject(o, "deadline", t->deadline);
        } else {
            cJSON_AddNullToObject(o, "deadline");
        }

        arr = json_str_array(t->source_refs, t->source_refs_count);
        if (arr == NULL) { cJSON_Delete(o); goto done; }
        cJSON_AddItemToObject(o, "source_refs", arr);

        /* 任务状态快照 */
        cJSON_AddStringToObject(o, "actual_status",
                                (t->actual_status == TS_ACTUAL_DONE) ? "done" : "todo");
        if (status != NULL && status->states != NULL) {
            cJSON_AddStringToObject(o, "ready_state", ts_export_ready_state_name(status->states[i]));
        } else {
            cJSON_AddStringToObject(o, "ready_state", "unknown");
        }
        if (status != NULL && status->level != NULL && status->level[i] >= 0) {
            cJSON_AddNumberToObject(o, "level", (double)status->level[i]);
        } else {
            cJSON_AddNullToObject(o, "level");
        }
        {
            int aff = (status != NULL && status->affected != NULL && status->affected[i]) ? 1 : 0;
            cJSON_AddBoolToObject(o, "affected", aff);
            if (aff) {
                size_t anc = ts_export_find_blocking_ancestor(plan, i, is_bp);
                if (anc != SIZE_MAX) {
                    cJSON_AddStringToObject(o, "affected_by", plan->tasks[anc].id);
                } else {
                    cJSON_AddNullToObject(o, "affected_by");
                }
            } else {
                cJSON_AddNullToObject(o, "affected_by");
            }
        }

        /* 本地排序依据（未排入顺序时为 null） */
        if (sched != NULL) {
            for (k = 0; k < sched->step_count; k++) {
                if (sched->steps[k].task_index == i) { step_index = k; break; }
            }
        }
        if (step_index == SIZE_MAX) {
            cJSON_AddNullToObject(o, "schedule");
        } else {
            const TsScheduleStep *s = &sched->steps[step_index];
            cJSON *sco = cJSON_CreateObject();
            if (sco == NULL) { cJSON_Delete(o); goto done; }
            cJSON_AddNumberToObject(sco, "order", (double)(step_index + 1));
            {
                cJSON *sc = json_score(&s->score);
                if (sc != NULL) cJSON_AddItemToObject(sco, "score", sc);
            }
            arr = json_str_array(s->candidates, s->candidate_count);
            if (arr != NULL) cJSON_AddItemToObject(sco, "candidates", arr);
            arr = json_str_array(s->unlocked, s->unlocked_count);
            if (arr != NULL) cJSON_AddItemToObject(sco, "unlocked", arr);
            arr = json_str_array(s->still_waiting, s->still_waiting_count);
            if (arr != NULL) cJSON_AddItemToObject(sco, "still_waiting", arr);
            cJSON_AddStringToObject(sco, "reason", (s->reason != NULL) ? s->reason : "");
            if (!cJSON_AddItemToObject(o, "schedule", sco)) {
                cJSON_Delete(sco);
                cJSON_Delete(o);
                goto done;
            }
        }

        if (!cJSON_AddItemToArray(tasks, o)) {
            cJSON_Delete(o);
            goto done;
        }
    }

    if (!cJSON_AddItemToObject(root, "tasks", tasks)) goto done;
    tasks = NULL;

    if (sched != NULL) {
        for (i = 0; i < sched->step_count; i++) {
            cJSON *id = cJSON_CreateString((sched->steps[i].task_id != NULL)
                                               ? sched->steps[i].task_id : "");
            if (id == NULL || !cJSON_AddItemToArray(order, id)) {
                if (id != NULL) cJSON_Delete(id);
                goto done;
            }
        }
    }
    if (!cJSON_AddItemToObject(root, "order", order)) goto done;
    order = NULL;

    if (json_lists(plan, sched, is_bp, root) != 0) goto done;

    cJSON_AddStringToObject(root, "unresolvable_reason",
                            (sched != NULL && sched->unresolvable_reason != NULL)
                                ? sched->unresolvable_reason : "");

    arr = json_str_array(plan->assumptions, plan->assumptions_count);
    if (arr != NULL) cJSON_AddItemToObject(root, "assumptions", arr);
    arr = json_str_array(plan->questions, plan->questions_count);
    if (arr != NULL) cJSON_AddItemToObject(root, "questions", arr);

    {
        cJSON *s = cJSON_CreateObject();
        if (s != NULL) {
            double done = 0.0;
            for (i = 0; i < n; i++) {
                if (plan->tasks[i].actual_status == TS_ACTUAL_DONE) done += 1.0;
            }
            cJSON_AddNumberToObject(s, "task_count", (double)n);
            cJSON_AddNumberToObject(s, "scheduled_steps",
                                    (double)((sched != NULL) ? sched->step_count : 0));
            cJSON_AddNumberToObject(s, "blocked_count",
                                    (double)((sched != NULL) ? sched->blocked_count : 0));
            cJSON_AddNumberToObject(s, "pending_count",
                                    (double)((sched != NULL) ? sched->pending_count : 0));
            cJSON_AddNumberToObject(s, "affected_count",
                                    (double)((sched != NULL) ? sched->affected_count : 0));
            cJSON_AddNumberToObject(s, "done_count", done);
            if (!cJSON_AddItemToObject(root, "summary", s)) cJSON_Delete(s);
        }
    }

    /*
     * token 用量（可选）。思考模式下思考 token 与正文共用 max_tokens 预算，
     * 把 reasoning_tokens 写进导出，用户日后回看结果时才能解释“为什么被截断”。
     * 不含任何敏感内容（只有计数与是否命中 token 上限）。
     */
    if (usage != NULL && usage->present) {
        cJSON *u = cJSON_CreateObject();
        if (u != NULL) {
            cJSON_AddNumberToObject(u, "prompt_tokens",     (double)usage->prompt_tokens);
            cJSON_AddNumberToObject(u, "completion_tokens", (double)usage->completion_tokens);
            cJSON_AddNumberToObject(u, "reasoning_tokens",  (double)usage->reasoning_tokens);
            cJSON_AddNumberToObject(u, "total_tokens",      (double)usage->total_tokens);
            cJSON_AddStringToObject(u, "reasoning_effort",
                                    (cfg != NULL && cfg->reasoning_effort != NULL)
                                        ? cfg->reasoning_effort : "(未发送)");
            /* max_output_tokens = 0 表示请求里没有发送 max_tokens，由服务端取默认 */
            cJSON_AddNumberToObject(u, "max_output_tokens",
                                    (cfg != NULL) ? (double)cfg->max_output_tokens : 0.0);
            cJSON_AddBoolToObject(u, "max_tokens_sent",
                                  (cfg != NULL && cfg->max_output_tokens > 0) ? 1 : 0);
            cJSON_AddNumberToObject(u, "attempts", (double)usage->attempts);
            cJSON_AddBoolToObject(u, "truncated", usage->truncated ? 1 : 0);
            if (!cJSON_AddItemToObject(root, "token_usage", u)) cJSON_Delete(u);
        }
    }

    *out_root = root;
    root = NULL;
    rc = 0;

done:
    ts_free(is_bp);
    if (tasks != NULL) cJSON_Delete(tasks);
    if (order != NULL) cJSON_Delete(order);
    if (root != NULL && rc != 0) cJSON_Delete(root);
    if (rc != 0) {
        snprintf(err, err_sz, "构造导出 JSON 失败（内存分配失败）");
    }
    return rc;
}

/* ------------------------------------------------------------------ */
/* 对外接口                                                            */
/* ------------------------------------------------------------------ */

int ts_export_json_usage(const TsPlan *plan, const TsScheduleResult *sched,
                         const TsStatusView *status, const TsConfig *cfg,
                         const TsTokenUsageStat *usage,
                         const char *path, char *err, size_t err_sz)
{
    cJSON *root = NULL;
    char *printed = NULL;
    int rc;

    if (plan == NULL) {
        snprintf(err, err_sz, "没有可导出的分析结果");
        return 1;
    }
    if (err != NULL && err_sz > 0) err[0] = '\0';

    if (build_json(plan, sched, status, cfg, usage, &root, err, err_sz) != 0) {
        return 1;
    }
    printed = cJSON_Print(root);
    cJSON_Delete(root);
    if (printed == NULL) {
        snprintf(err, err_sz, "序列化导出 JSON 失败（内存分配失败）");
        return 1;
    }
    rc = ts_export_write_file(path, printed, strlen(printed), 0, err, err_sz);
    cJSON_free(printed);
    return rc;
}

int ts_export_json(const TsPlan *plan, const TsScheduleResult *sched,
                   const TsStatusView *status, const TsConfig *cfg,
                   const char *path, char *err, size_t err_sz)
{
    return ts_export_json_usage(plan, sched, status, cfg, NULL, path, err, err_sz);
}

int ts_export_plan(TsExportFormat format, const TsPlan *plan,
                   const TsScheduleResult *sched, const TsStatusView *status,
                   const TsConfig *cfg, const char *path, char *err, size_t err_sz)
{
    if (format == TS_EXPORT_JSON) {
        return ts_export_json(plan, sched, status, cfg, path, err, err_sz);
    }
    return ts_export_txt(plan, sched, status, cfg, path, err, err_sz);
}

int ts_export_plan_usage(TsExportFormat format, const TsPlan *plan,
                         const TsScheduleResult *sched, const TsStatusView *status,
                         const TsConfig *cfg, const TsTokenUsageStat *usage,
                         const char *path, char *err, size_t err_sz)
{
    if (format == TS_EXPORT_JSON) {
        return ts_export_json_usage(plan, sched, status, cfg, usage, path, err, err_sz);
    }
    /* TXT 导出暂不含 token 用量：用量是诊断信息，JSON 侧已完整记录 */
    return ts_export_txt(plan, sched, status, cfg, path, err, err_sz);
}

