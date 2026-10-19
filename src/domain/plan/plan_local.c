/*
 * plan_local.c — 本地计划 JSON（lp 格式）编解码：稳定 ID、完成状态与排序输入。
 *
 * 主要函数：ts_local_plan_parse、ts_local_plan_to_json。
 */


#include "plan_local.h"
#include "plan.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

#include "cJSON.h"

static int oom(char *err, size_t err_sz)
{
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

static const char *json_str_or_empty(const cJSON *o, const char *key)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it != NULL && cJSON_IsString(it)) return cJSON_GetStringValue(it);
    return "";
}

static int dup_opt(const cJSON *o, const char *key, char **out,
                   char *err, size_t err_sz, int *empty)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    *out = NULL;
    if (empty != NULL) *empty = 1;
    if (it == NULL || cJSON_IsNull(it)) return 0;
    if (!cJSON_IsString(it)) {
        snprintf(err, err_sz, "%s 必须是字符串或 null", key);
        return 1;
    }
    {
        const char *s = cJSON_GetStringValue(it);
        if (s[0] == '\0') return 0;
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "%s 过长", key);
            return 1;
        }
        *out = ts_strdup(s);
        if (*out == NULL) return oom(err, err_sz);
        if (empty != NULL) *empty = 0;
    }
    return 0;
}

static int parse_str_list(const cJSON *o, const char *key, long max_count,
                          char ***out, size_t *out_count,
                          char *err, size_t err_sz)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    size_t n, i;
    char **v;

    *out = NULL;
    *out_count = 0;
    if (it == NULL || cJSON_IsNull(it)) return 0;
    if (!cJSON_IsArray(it)) {
        snprintf(err, err_sz, "%s 必须是数组", key);
        return 1;
    }
    n = cJSON_GetArraySize(it);
    if ((long)n > max_count) {
        snprintf(err, err_sz, "%s 数量超过上限(%ld)", key, max_count);
        return 1;
    }
    if (n == 0) return 0;
    v = (char **)ts_calloc(n, sizeof(char *));
    if (v == NULL) return oom(err, err_sz);
    for (i = 0; i < n; i++) {
        const cJSON *e = cJSON_GetArrayItem(it, (int)i);
        const char *s;
        if (e == NULL || !cJSON_IsString(e)) {
            size_t k;
            for (k = 0; k < i; k++) ts_free(v[k]);
            ts_free(v);
            snprintf(err, err_sz, "%s[%zu] 必须是字符串", key, i);
            return 1;
        }
        s = cJSON_GetStringValue(e);
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            size_t k;
            for (k = 0; k < i; k++) ts_free(v[k]);
            ts_free(v);
            snprintf(err, err_sz, "%s[%zu] 过长", key, i);
            return 1;
        }
        v[i] = ts_strdup(s);
        if (v[i] == NULL) {
            size_t k;
            for (k = 0; k < i; k++) ts_free(v[k]);
            ts_free(v);
            return oom(err, err_sz);
        }
    }
    *out = v;
    *out_count = n;
    return 0;
}

static int parse_preconds(const cJSON *o, TsTask *t, char *err, size_t err_sz)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, "preconditions");
    size_t n, i;

    if (it == NULL || cJSON_IsNull(it)) return 0;
    if (!cJSON_IsArray(it)) {
        snprintf(err, err_sz, "preconditions 必须是数组");
        return 1;
    }
    n = cJSON_GetArraySize(it);
    if ((long)n > TS_MAX_PRECONDITIONS) {
        snprintf(err, err_sz, "preconditions 数量超过上限(%d)", TS_MAX_PRECONDITIONS);
        return 1;
    }
    if (n == 0) return 0;
    t->preconditions = (TsPrecondition *)ts_calloc(n, sizeof(TsPrecondition));
    if (t->preconditions == NULL) return oom(err, err_sz);
    t->preconditions_count = n;

    for (i = 0; i < n; i++) {
        const cJSON *e = cJSON_GetArrayItem(it, (int)i);
        const cJSON *desc, *st;
        const char *ss;
        if (e == NULL || !cJSON_IsObject(e)) {
            snprintf(err, err_sz, "preconditions[%zu] 必须是对象", i);
            return 1;
        }
        desc = cJSON_GetObjectItemCaseSensitive(e, "description");
        st = cJSON_GetObjectItemCaseSensitive(e, "status");
        if (desc == NULL || !cJSON_IsString(desc)) {
            snprintf(err, err_sz, "preconditions[%zu].description 必须是字符串", i);
            return 1;
        }
        t->preconditions[i].description =
            ts_strdup(cJSON_GetStringValue(desc));
        if (t->preconditions[i].description == NULL) return oom(err, err_sz);
        t->preconditions[i].status = TS_PRECOND_UNKNOWN;
        if (st != NULL && cJSON_IsString(st)) {
            ss = cJSON_GetStringValue(st);
            if (strcmp(ss, "met") == 0)          t->preconditions[i].status = TS_PRECOND_MET;
            else if (strcmp(ss, "unmet") == 0)   t->preconditions[i].status = TS_PRECOND_UNMET;
            else if (strcmp(ss, "unknown") == 0) t->preconditions[i].status = TS_PRECOND_UNKNOWN;
            else {
                snprintf(err, err_sz,
                         "preconditions[%zu].status 必须是 met/unmet/unknown", i);
                return 1;
            }
        }
    }
    return 0;
}

static int parse_task(const cJSON *o, TsTask *t, const TsConfig *cfg,
                      size_t index, char *err, size_t err_sz)
{
    const cJSON *it;
    char where[48];

    snprintf(where, sizeof(where), "tasks[%zu]", index);
    if (o == NULL || !cJSON_IsObject(o)) {
        snprintf(err, err_sz, "%s 必须是对象", where);
        return 1;
    }

    it = cJSON_GetObjectItemCaseSensitive(o, "id");
    if (it == NULL || !cJSON_IsString(it) || cJSON_GetStringValue(it)[0] == '\0') {
        snprintf(err, err_sz, "%s.id 缺失或为空", where);
        return 1;
    }
    t->id = ts_strdup(cJSON_GetStringValue(it));
    if (t->id == NULL) return oom(err, err_sz);

    it = cJSON_GetObjectItemCaseSensitive(o, "name");
    if (it == NULL || !cJSON_IsString(it) || cJSON_GetStringValue(it)[0] == '\0') {
        snprintf(err, err_sz, "%s.name 缺失或为空", where);
        return 1;
    }
    t->name = ts_strdup(cJSON_GetStringValue(it));
    if (t->name == NULL) return oom(err, err_sz);

    if (dup_opt(o, "previousTaskId", &t->previous_task_id, err, err_sz, NULL)) return 1;

    if (parse_str_list(o, "dependsOn", cfg->max_tasks,
                       &t->depends_on, &t->depends_on_count, err, err_sz)) return 1;
    if (parse_str_list(o, "steps", cfg->max_steps_per_task,
                       &t->steps, &t->steps_count, err, err_sz)) return 1;
    if (parse_str_list(o, "sourceRefs", TS_MAX_SOURCE_REFS,
                       &t->source_refs, &t->source_refs_count, err, err_sz)) return 1;
    if (parse_preconds(o, t, err, err_sz)) return 1;

    /* urgency / impact：可缺省（默认 3），必须在 1..5 */
    it = cJSON_GetObjectItemCaseSensitive(o, "urgency");
    t->urgency = (it != NULL && cJSON_IsNumber(it)) ? it->valueint : 3;
    it = cJSON_GetObjectItemCaseSensitive(o, "impact");
    t->impact = (it != NULL && cJSON_IsNumber(it)) ? it->valueint : 3;
    if (t->urgency < 1 || t->urgency > 5) {
        snprintf(err, err_sz, "%s.urgency 必须在 1..5", where);
        return 1;
    }
    if (t->impact < 1 || t->impact > 5) {
        snprintf(err, err_sz, "%s.impact 必须在 1..5", where);
        return 1;
    }

    if (dup_opt(o, "urgencyReason", &t->urgency_reason, err, err_sz, NULL)) return 1;
    if (dup_opt(o, "impactReason", &t->impact_reason, err, err_sz, NULL)) return 1;
    if (dup_opt(o, "estimateReason", &t->estimate_reason, err, err_sz, NULL)) return 1;
    if (dup_opt(o, "deadline", &t->deadline, err, err_sz, NULL)) return 1;

    /* estimatedHours：数字（正）或 null（未知，绝不当作 0） */
    it = cJSON_GetObjectItemCaseSensitive(o, "estimatedHours");
    if (it != NULL && !cJSON_IsNull(it)) {
        if (!cJSON_IsNumber(it)) {
            snprintf(err, err_sz, "%s.estimatedHours 必须是数字或 null", where);
            return 1;
        }
        t->estimated_hours = it->valuedouble;
        t->has_estimated_hours = 1;
    }

    t->actual_status = TS_ACTUAL_TODO;
    it = cJSON_GetObjectItemCaseSensitive(o, "actualStatus");
    if (it != NULL && cJSON_IsString(it)) {
        if (strcmp(cJSON_GetStringValue(it), "done") == 0) {
            t->actual_status = TS_ACTUAL_DONE;
        }
    }
    return 0;
}

static int parse_notes_local(const cJSON *arr, TsPlan *plan, char *err, size_t err_sz)
{
    size_t n, i;

    if (!cJSON_IsArray(arr)) {
        snprintf(err, err_sz, "notes 必须是数组");
        return 1;
    }
    n = cJSON_GetArraySize(arr);
    if (n > (size_t)TS_MAX_NOTES) {
        snprintf(err, err_sz, "notes 数量超过上限(%d)", TS_MAX_NOTES);
        return 1;
    }
    if (n == 0) return 0;
    plan->notes = (TsNote *)ts_calloc(n, sizeof(TsNote));
    if (plan->notes == NULL) return oom(err, err_sz);
    plan->note_count = n;

    for (i = 0; i < n; i++) {
        const cJSON *e = cJSON_GetArrayItem(arr, (int)i);
        const cJSON *text, *kind, *refs;
        if (e == NULL || !cJSON_IsObject(e)) {
            snprintf(err, err_sz, "notes[%zu] 必须是对象", i);
            return 1;
        }
        text = cJSON_GetObjectItemCaseSensitive(e, "text");
        if (text == NULL || !cJSON_IsString(text)) {
            snprintf(err, err_sz, "notes[%zu].text 必须是字符串", i);
            return 1;
        }
        plan->notes[i].text = ts_strdup(cJSON_GetStringValue(text));
        if (plan->notes[i].text == NULL) return oom(err, err_sz);

        plan->notes[i].kind = TS_NOTE_QUESTION;
        kind = cJSON_GetObjectItemCaseSensitive(e, "kind");
        if (kind != NULL && cJSON_IsString(kind)) {
            const char *s = cJSON_GetStringValue(kind);
            if (strcmp(s, "blocked") == 0)         plan->notes[i].kind = TS_NOTE_BLOCKED;
            else if (strcmp(s, "assumption") == 0) plan->notes[i].kind = TS_NOTE_ASSUMPTION;
            else if (strcmp(s, "question") == 0)   plan->notes[i].kind = TS_NOTE_QUESTION;
            else {
                snprintf(err, err_sz,
                         "notes[%zu].kind 必须是 question/blocked/assumption", i);
                return 1;
            }
        }
        refs = cJSON_GetObjectItemCaseSensitive(e, "taskRefs");
        if (refs != NULL && !cJSON_IsNull(refs)) {
            if (parse_str_list(e, "taskRefs", TS_MAX_NOTES,
                               &plan->notes[i].task_refs,
                               &plan->notes[i].task_ref_count,
                               err, err_sz)) {
                return 1;
            }
        }
    }
    return 0;
}

int ts_local_plan_parse(const char *json, size_t json_len, const TsConfig *cfg,
                        TsPlan *out, char *err, size_t err_sz)
{
    cJSON *root = NULL;
    const cJSON *tasks;
    const cJSON *version;
    size_t n, i;
    int rc = 1;

    if (out == NULL || cfg == NULL) return 1;
    ts_plan_init(out);

    if (json == NULL || json_len == 0) {
        snprintf(err, err_sz, "本地计划为空");
        return 1;
    }
    root = cJSON_ParseWithLength(json, json_len);
    if (root == NULL) {
        snprintf(err, err_sz, "本地计划 JSON 解析失败");
        return 1;
    }
    if (!cJSON_IsObject(root)) {
        snprintf(err, err_sz, "本地计划顶层必须是对象");
        goto done;
    }

    /* schemaVersion：本地协议版本（与模型 schema_version 无关） */
    version = cJSON_GetObjectItemCaseSensitive(root, "schemaVersion");
    if (version != NULL && cJSON_IsString(version)) {
        if (strcmp(cJSON_GetStringValue(version), TS_LOCAL_PLAN_VERSION) != 0) {
            snprintf(err, err_sz, "不支持的本地计划版本（需要 %s，得到 %s）",
                     TS_LOCAL_PLAN_VERSION, cJSON_GetStringValue(version));
            goto done;
        }
    }

    /* 本地计划的 schema_major/minor：用于 TsPlan 校验的兼容位。
     * 写成 2.0，表示它已经带有 summary / previous_task_id / notes 语义。 */
    out->schema_major = 2;
    out->schema_minor = 0;

    if (dup_opt(root, "summary", &out->summary, err, err_sz, NULL)) goto done;

    tasks = cJSON_GetObjectItemCaseSensitive(root, "tasks");
    if (tasks == NULL || !cJSON_IsArray(tasks)) {
        snprintf(err, err_sz, "缺少或无效的 tasks 数组");
        goto done;
    }
    n = cJSON_GetArraySize(tasks);
    if (n == 0) {
        snprintf(err, err_sz, "任务列表为空");
        goto done;
    }
    if ((long)n > cfg->max_tasks) {
        snprintf(err, err_sz, "任务数量超过上限(%ld)", cfg->max_tasks);
        goto done;
    }
    out->tasks = (TsTask *)ts_calloc(n, sizeof(TsTask));
    if (out->tasks == NULL) { oom(err, err_sz); goto done; }
    out->task_count = n;
    for (i = 0; i < n; i++) {
        if (parse_task(cJSON_GetArrayItem(tasks, (int)i), &out->tasks[i],
                       cfg, i, err, err_sz)) {
            goto done;
        }
    }

    {
        const cJSON *notes = cJSON_GetObjectItemCaseSensitive(root, "notes");
        if (notes != NULL && !cJSON_IsNull(notes)) {
            if (parse_notes_local(notes, out, err, err_sz)) goto done;
        }
    }

    /* 复用现有业务校验（ID 唯一、依赖存在、无环、范围、枚举） */
    if (ts_plan_validate(out, cfg, err, err_sz) != 0) goto done;

    rc = 0;
done:
    cJSON_Delete(root);
    return rc;
}

/* ------------------------------------------------------------------ */
/* 序列化                                                              */
/* ------------------------------------------------------------------ */

static int add_opt_str(cJSON *o, const char *key, const char *v)
{
    if (v == NULL || v[0] == '\0') {
        return (cJSON_AddNullToObject(o, key) != NULL) ? 0 : 1;
    }
    return (cJSON_AddStringToObject(o, key, v) != NULL) ? 0 : 1;
}

static int add_str_list(cJSON *o, const char *key, char *const *v, size_t n)
{
    cJSON *arr = cJSON_AddArrayToObject(o, key);
    size_t i;
    if (arr == NULL) return 1;
    for (i = 0; i < n; i++) {
        if (cJSON_AddItemToArray(arr, cJSON_CreateString(v[i])) == 0) return 1;
    }
    return 0;
}

static const char *precond_status_text(TsPrecondStatus s)
{
    switch (s) {
        case TS_PRECOND_MET:   return "met";
        case TS_PRECOND_UNMET: return "unmet";
        default:               return "unknown";
    }
}

static const char *note_kind_text(TsNoteKind k)
{
    switch (k) {
        case TS_NOTE_BLOCKED:    return "blocked";
        case TS_NOTE_ASSUMPTION: return "assumption";
        default:                 return "question";
    }
}

int ts_local_plan_to_json(const TsPlan *plan, char **out, size_t *out_len,
                          char *err, size_t err_sz)
{
    cJSON *root = NULL;
    cJSON *tasks = NULL;
    char *printed = NULL;
    size_t i, k;

    if (out == NULL || plan == NULL) return 1;
    *out = NULL;
    if (out_len != NULL) *out_len = 0;

    root = cJSON_CreateObject();
    if (root == NULL) return oom(err, err_sz);
    if (cJSON_AddStringToObject(root, "schemaVersion", TS_LOCAL_PLAN_VERSION) == NULL) goto oom;
    if (add_opt_str(root, "summary", plan->summary)) goto oom;

    tasks = cJSON_AddArrayToObject(root, "tasks");
    if (tasks == NULL) goto oom;
    for (i = 0; i < plan->task_count; i++) {
        const TsTask *t = &plan->tasks[i];
        cJSON *o = cJSON_CreateObject();
        if (o == NULL) goto oom;
        if (cJSON_AddStringToObject(o, "id", t->id) == NULL ||
            cJSON_AddStringToObject(o, "name", t->name) == NULL ||
            add_opt_str(o, "previousTaskId", t->previous_task_id) ||
            add_str_list(o, "dependsOn", t->depends_on, t->depends_on_count) ||
            add_str_list(o, "steps", t->steps, t->steps_count) ||
            add_str_list(o, "sourceRefs", t->source_refs, t->source_refs_count)) {
            cJSON_Delete(o);
            goto oom;
        }
        {
            cJSON *pc = cJSON_AddArrayToObject(o, "preconditions");
            if (pc == NULL) { cJSON_Delete(o); goto oom; }
            for (k = 0; k < t->preconditions_count; k++) {
                cJSON *e = cJSON_CreateObject();
                if (e == NULL ||
                    cJSON_AddStringToObject(e, "description",
                                            t->preconditions[k].description) == NULL ||
                    cJSON_AddStringToObject(e, "status",
                        precond_status_text(t->preconditions[k].status)) == NULL) {
                    if (e != NULL) cJSON_Delete(e);
                    cJSON_Delete(o);
                    goto oom;
                }
                cJSON_AddItemToArray(pc, e);
            }
        }
        if (cJSON_AddNumberToObject(o, "urgency", (double)t->urgency) == NULL ||
            cJSON_AddNumberToObject(o, "impact", (double)t->impact) == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (add_opt_str(o, "urgencyReason", t->urgency_reason) ||
            add_opt_str(o, "impactReason", t->impact_reason) ||
            add_opt_str(o, "estimateReason", t->estimate_reason) ||
            add_opt_str(o, "deadline", t->deadline)) {
            cJSON_Delete(o);
            goto oom;
        }
        if (t->has_estimated_hours) {
            if (cJSON_AddNumberToObject(o, "estimatedHours", t->estimated_hours) == NULL) {
                cJSON_Delete(o);
                goto oom;
            }
        } else if (cJSON_AddNullToObject(o, "estimatedHours") == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        if (cJSON_AddStringToObject(o, "actualStatus",
                (t->actual_status == TS_ACTUAL_DONE) ? "done" : "todo") == NULL) {
            cJSON_Delete(o);
            goto oom;
        }
        cJSON_AddItemToArray(tasks, o);
    }

    {
        cJSON *notes = cJSON_AddArrayToObject(root, "notes");
        if (notes == NULL) goto oom;
        for (i = 0; i < plan->note_count; i++) {
            cJSON *o = cJSON_CreateObject();
            if (o == NULL ||
                cJSON_AddStringToObject(o, "kind", note_kind_text(plan->notes[i].kind)) == NULL ||
                cJSON_AddStringToObject(o, "text", plan->notes[i].text) == NULL ||
                add_str_list(o, "taskRefs", plan->notes[i].task_refs,
                             plan->notes[i].task_ref_count)) {
                if (o != NULL) cJSON_Delete(o);
                goto oom;
            }
            cJSON_AddItemToArray(notes, o);
        }
    }

    printed = cJSON_PrintUnformatted(root);
    if (printed == NULL) goto oom;
    cJSON_Delete(root);
    *out = printed;
    if (out_len != NULL) *out_len = strlen(printed);
    return 0;

oom:
    if (root != NULL) cJSON_Delete(root);
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

