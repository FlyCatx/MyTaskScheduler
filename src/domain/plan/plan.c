/*
 * plan.c — 模型输出 JSON 到 TsPlan 的结构与类型转换。
 *
 * 主要函数：ts_plan_parse。
 */


#include "plan.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

#include "cJSON.h"

/* ------------------------------------------------------------------ */
/* 内部辅助                                                            */
/* ------------------------------------------------------------------ */

static void free_str_arr(char **v, size_t n)
{
    size_t i;
    if (v == NULL) return;
    for (i = 0; i < n; i++) ts_free(v[i]);
    ts_free(v);
}

static int oom(char *err, size_t err_sz)
{
    snprintf(err, err_sz, "内存分配失败");
    return 1;
}

/*
 * 取“必需字段”。
 *
 * 协议规定这些字段必须出现：“没有内容”必须显式写成 [] 或 null。
 * 若把缺失当成空值，就无法区分“确实没有依赖/条件/步骤”与“模型没有分析出来”，
 * 后者会让任务被错误地判为可开始。因此缺失一律视为协议错误（会触发一次修复请求）。
 */
static const cJSON *require_field(const cJSON *o, const char *key,
                                  char *err, size_t err_sz, const char *where)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL) {
        snprintf(err, err_sz,
                 "%s.%s 字段缺失：没有内容时必须显式返回 [] 或 null，不得省略该字段",
                 where, key);
        return NULL;
    }
    return it;
}

static void parse_schema_version(const char *s, int *maj, int *min)
{
    int a = -1, b = 0;
    if (s != NULL && sscanf(s, "%d.%d", &a, &b) < 1) {
        a = -1;
    }
    *maj = a;
    *min = b;
}

static int map_precond_status(const char *s)
{
    if (s == NULL) return -1;
    if (strcmp(s, "met") == 0)     return TS_PRECOND_MET;
    if (strcmp(s, "unmet") == 0)   return TS_PRECOND_UNMET;
    if (strcmp(s, "unknown") == 0) return TS_PRECOND_UNKNOWN;
    return -1;
}

/* 解析字符串数组。成功时 *out 为 owned 数组（元素 owned），*out_count 为数量。 */
static int parse_str_array(const cJSON *arr, char ***out, size_t *out_count,
                           long max_count, char *err, size_t err_sz, const char *what)
{
    size_t i, n;
    char **v = NULL;

    *out = NULL;
    *out_count = 0;
    if (!cJSON_IsArray(arr)) {
        snprintf(err, err_sz, "%s 必须是数组", what);
        return 1;
    }
    n = cJSON_GetArraySize(arr);
    if ((long)n > max_count) {
        snprintf(err, err_sz, "%s 数量超过上限(%ld)", what, max_count);
        return 1;
    }
    if (n == 0) return 0;

    v = (char **)ts_calloc(n, sizeof(char *));
    if (v == NULL) return oom(err, err_sz);

    for (i = 0; i < n; i++) {
        const cJSON *it = cJSON_GetArrayItem(arr, (int)i);
        const char *s;
        if (it == NULL || !cJSON_IsString(it)) {
            snprintf(err, err_sz, "%s[%zu] 必须是字符串", what, i);
            free_str_arr(v, i);
            return 1;
        }
        s = cJSON_GetStringValue(it);
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "%s[%zu] 字符串过长", what, i);
            free_str_arr(v, i);
            return 1;
        }
        v[i] = ts_strdup(s);
        if (v[i] == NULL) {
            free_str_arr(v, i);
            return oom(err, err_sz);
        }
    }
    *out = v;
    *out_count = n;
    return 0;
}

static int parse_preconditions(const cJSON *arr, TsTask *t,
                               char *err, size_t err_sz, const char *where)
{
    size_t i, n;
    if (!cJSON_IsArray(arr)) {
        snprintf(err, err_sz, "%s.preconditions 必须是数组", where);
        return 1;
    }
    n = cJSON_GetArraySize(arr);
    if ((long)n > TS_MAX_PRECONDITIONS) {
        snprintf(err, err_sz, "%s.preconditions 数量超过上限(%d)", where, TS_MAX_PRECONDITIONS);
        return 1;
    }
    if (n == 0) return 0;

    t->preconditions = (TsPrecondition *)ts_calloc(n, sizeof(TsPrecondition));
    if (t->preconditions == NULL) return oom(err, err_sz);
    t->preconditions_count = n;

    for (i = 0; i < n; i++) {
        const cJSON *it = cJSON_GetArrayItem(arr, (int)i);
        const cJSON *desc;
        const cJSON *status;
        const char *ds, *ss;
        int st;
        if (it == NULL || !cJSON_IsObject(it)) {
            snprintf(err, err_sz, "%s.preconditions[%zu] 必须是对象", where, i);
            return 1;
        }
        desc = cJSON_GetObjectItemCaseSensitive(it, "description");
        status = cJSON_GetObjectItemCaseSensitive(it, "status");
        if (desc == NULL || !cJSON_IsString(desc)) {
            snprintf(err, err_sz, "%s.preconditions[%zu].description 必须是字符串", where, i);
            return 1;
        }
        ds = cJSON_GetStringValue(desc);
        if (ds[0] == '\0') {
            snprintf(err, err_sz, "%s.preconditions[%zu].description 不能为空", where, i);
            return 1;
        }
        if (status == NULL || !cJSON_IsString(status)) {
            snprintf(err, err_sz, "%s.preconditions[%zu].status 必须是字符串", where, i);
            return 1;
        }
        ss = cJSON_GetStringValue(status);
        st = map_precond_status(ss);
        if (st < 0) {
            snprintf(err, err_sz, "%s.preconditions[%zu].status 必须是 met/unmet/unknown", where, i);
            return 1;
        }
        t->preconditions[i].description = ts_strdup(ds);
        if (t->preconditions[i].description == NULL) return oom(err, err_sz);
        t->preconditions[i].status = (TsPrecondStatus)st;
    }
    return 0;
}

/* 读取必需的整型字段（1..5 范围由校验负责，此处校验类型与整数性）。 */
static int parse_int_field(const cJSON *o, const char *key, int *out,
                           char *err, size_t err_sz, const char *where)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    double d;
    if (it == NULL || !cJSON_IsNumber(it)) {
        snprintf(err, err_sz, "%s.%s 缺失或不是数字", where, key);
        return 1;
    }
    d = it->valuedouble;
    if (d != floor(d)) {
        snprintf(err, err_sz, "%s.%s 必须是整数", where, key);
        return 1;
    }
    *out = (int)it->valueint;
    return 0;
}

/* 读取必需的字符串字段（允许空串，但字段必须存在且为字符串）。 */
static int parse_req_string(const cJSON *o, const char *key, char **out,
                            char *err, size_t err_sz, const char *where)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    const char *s;
    if (it == NULL || !cJSON_IsString(it)) {
        snprintf(err, err_sz, "%s.%s 缺失或不是字符串", where, key);
        return 1;
    }
    s = cJSON_GetStringValue(it);
    if (strlen(s) > TS_MAX_STRING_BYTES) {
        snprintf(err, err_sz, "%s.%s 字符串过长", where, key);
        return 1;
    }
    *out = ts_strdup(s);
    if (*out == NULL) return oom(err, err_sz);
    return 0;
}

static int parse_task(const cJSON *o, TsTask *t, const TsConfig *cfg,
                      char *err, size_t err_sz, const char *where)
{
    const cJSON *item;
    const char *s;

    /* id（必需，非空） */
    item = cJSON_GetObjectItemCaseSensitive(o, "id");
    if (item == NULL || !cJSON_IsString(item)) {
        snprintf(err, err_sz, "%s.id 缺失或不是字符串", where);
        return 1;
    }
    s = cJSON_GetStringValue(item);
    if (s[0] == '\0') { snprintf(err, err_sz, "%s.id 不能为空", where); return 1; }
    if (strlen(s) > TS_MAX_STRING_BYTES) { snprintf(err, err_sz, "%s.id 过长", where); return 1; }
    t->id = ts_strdup(s);
    if (t->id == NULL) return oom(err, err_sz);

    /* previous_task_id（可选）：模型对“承接上一版哪个任务”的建议，可为 null */
    item = cJSON_GetObjectItemCaseSensitive(o, "previous_task_id");
    if (item != NULL && !cJSON_IsNull(item)) {
        if (!cJSON_IsString(item)) {
            snprintf(err, err_sz, "%s.previous_task_id 必须是字符串或 null", where);
            return 1;
        }
        s = cJSON_GetStringValue(item);
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "%s.previous_task_id 过长", where);
            return 1;
        }
        if (s[0] != '\0') {
            t->previous_task_id = ts_strdup(s);
            if (t->previous_task_id == NULL) return oom(err, err_sz);
        }
    }

    /* name（必需，非空） */
    item = cJSON_GetObjectItemCaseSensitive(o, "name");
    if (item == NULL || !cJSON_IsString(item)) {
        snprintf(err, err_sz, "%s.name 缺失或不是字符串", where);
        return 1;
    }
    s = cJSON_GetStringValue(item);
    if (s[0] == '\0') { snprintf(err, err_sz, "%s.name 不能为空", where); return 1; }
    if (strlen(s) > TS_MAX_STRING_BYTES) { snprintf(err, err_sz, "%s.name 过长", where); return 1; }
    t->name = ts_strdup(s);
    if (t->name == NULL) return oom(err, err_sz);

    /* depends_on（必需数组；没有前置任务时必须显式返回 []） */
    item = require_field(o, "depends_on", err, err_sz, where);
    if (item == NULL) return 1;
    {
        char path[96];
        snprintf(path, sizeof(path), "%s.depends_on", where);
        if (parse_str_array(item, &t->depends_on, &t->depends_on_count,
                            cfg->max_tasks, err, err_sz, path)) {
            return 1;
        }
    }

    /* preconditions（必需数组；没有外部条件时必须显式返回 []） */
    item = require_field(o, "preconditions", err, err_sz, where);
    if (item == NULL) return 1;
    if (parse_preconditions(item, t, err, err_sz, where)) return 1;

    /* steps（必需数组；没有步骤时必须显式返回 []） */
    item = require_field(o, "steps", err, err_sz, where);
    if (item == NULL) return 1;
    {
        char path[96];
        snprintf(path, sizeof(path), "%s.steps", where);
        if (parse_str_array(item, &t->steps, &t->steps_count,
                            cfg->max_steps_per_task, err, err_sz, path)) {
            return 1;
        }
    }

    /* urgency / impact（必需，整数） */
    if (parse_int_field(o, "urgency", &t->urgency, err, err_sz, where)) return 1;
    if (parse_int_field(o, "impact", &t->impact, err, err_sz, where)) return 1;

    /* 理由（必需字符串） */
    if (parse_req_string(o, "urgency_reason", &t->urgency_reason, err, err_sz, where)) return 1;
    if (parse_req_string(o, "impact_reason", &t->impact_reason, err, err_sz, where)) return 1;

    /* estimated_hours（必需字段）：数字表示已知工时，null 表示未知（绝不当作 0） */
    item = require_field(o, "estimated_hours", err, err_sz, where);
    if (item == NULL) return 1;
    if (!cJSON_IsNull(item)) {
        double h;
        if (!cJSON_IsNumber(item)) {
            snprintf(err, err_sz, "%s.estimated_hours 必须是数字或 null", where);
            return 1;
        }
        h = item->valuedouble;
        t->estimated_hours = h;
        t->has_estimated_hours = 1;
    } else {
        t->estimated_hours = 0.0;
        t->has_estimated_hours = 0;
    }

    /* estimate_reason（必需字段）：字符串或 null */
    item = require_field(o, "estimate_reason", err, err_sz, where);
    if (item == NULL) return 1;
    if (!cJSON_IsNull(item)) {
        if (!cJSON_IsString(item)) {
            snprintf(err, err_sz, "%s.estimate_reason 必须是字符串或 null", where);
            return 1;
        }
        s = cJSON_GetStringValue(item);
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "%s.estimate_reason 过长", where);
            return 1;
        }
        t->estimate_reason = ts_strdup(s);
        if (t->estimate_reason == NULL) return oom(err, err_sz);
    }

    /* deadline（必需字段）：字符串或 null */
    item = require_field(o, "deadline", err, err_sz, where);
    if (item == NULL) return 1;
    if (!cJSON_IsNull(item)) {
        if (!cJSON_IsString(item)) {
            snprintf(err, err_sz, "%s.deadline 必须是字符串或 null", where);
            return 1;
        }
        s = cJSON_GetStringValue(item);
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "%s.deadline 过长", where);
            return 1;
        }
        t->deadline = ts_strdup(s);
        if (t->deadline == NULL) return oom(err, err_sz);
    }

    /* source_refs（必需数组；没有来源时必须显式返回 []） */
    item = require_field(o, "source_refs", err, err_sz, where);
    if (item == NULL) return 1;
    {
        char path[96];
        snprintf(path, sizeof(path), "%s.source_refs", where);
        if (parse_str_array(item, &t->source_refs, &t->source_refs_count,
                            TS_MAX_SOURCE_REFS, err, err_sz, path)) {
            return 1;
        }
    }

    t->actual_status = TS_ACTUAL_TODO;
    return 0;
}

/* ------------------------------------------------------------------ */
/* notes（schema 2.0）：{kind, text, task_refs[]} 对象数组              */
/* ------------------------------------------------------------------ */

static int map_note_kind(const char *s)
{
    if (s == NULL) return -1;
    if (strcmp(s, "question") == 0)   return TS_NOTE_QUESTION;
    if (strcmp(s, "blocked") == 0)    return TS_NOTE_BLOCKED;
    if (strcmp(s, "assumption") == 0) return TS_NOTE_ASSUMPTION;
    return -1;
}

static int parse_notes(const cJSON *arr, TsPlan *plan, char *err, size_t err_sz)
{
    size_t i, n, cap;

    if (!cJSON_IsArray(arr)) {
        snprintf(err, err_sz, "notes 必须是数组");
        return 1;
    }
    n = cJSON_GetArraySize(arr);
    cap = (size_t)TS_MAX_NOTES;
    if (n > cap) {
        snprintf(err, err_sz, "notes 数量超过上限(%d)", TS_MAX_NOTES);
        return 1;
    }
    if (n == 0) return 0;

    plan->notes = (TsNote *)ts_calloc(n, sizeof(TsNote));
    if (plan->notes == NULL) return oom(err, err_sz);
    plan->note_count = n;

    for (i = 0; i < n; i++) {
        const cJSON *it = cJSON_GetArrayItem(arr, (int)i);
        const cJSON *kind, *text, *refs;
        const char *s;
        if (it == NULL || !cJSON_IsObject(it)) {
            snprintf(err, err_sz, "notes[%zu] 必须是对象", i);
            return 1;
        }
        kind = cJSON_GetObjectItemCaseSensitive(it, "kind");
        text = cJSON_GetObjectItemCaseSensitive(it, "text");
        if (text == NULL || !cJSON_IsString(text)) {
            snprintf(err, err_sz, "notes[%zu].text 必须是字符串", i);
            return 1;
        }
        s = cJSON_GetStringValue(text);
        if (s[0] == '\0') {
            snprintf(err, err_sz, "notes[%zu].text 不能为空", i);
            return 1;
        }
        if (strlen(s) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "notes[%zu].text 过长", i);
            return 1;
        }
        plan->notes[i].text = ts_strdup(s);
        if (plan->notes[i].text == NULL) return oom(err, err_sz);

        /* kind 缺省视为待确认（保守：宁可让用户复核，也不静默忽略） */
        if (kind == NULL || cJSON_IsNull(kind)) {
            plan->notes[i].kind = TS_NOTE_QUESTION;
        } else {
            int k;
            if (!cJSON_IsString(kind)) {
                snprintf(err, err_sz, "notes[%zu].kind 必须是字符串", i);
                return 1;
            }
            k = map_note_kind(cJSON_GetStringValue(kind));
            if (k < 0) {
                snprintf(err, err_sz,
                         "notes[%zu].kind 必须是 question/blocked/assumption", i);
                return 1;
            }
            plan->notes[i].kind = (TsNoteKind)k;
        }

        refs = cJSON_GetObjectItemCaseSensitive(it, "task_refs");
        if (refs != NULL && !cJSON_IsNull(refs)) {
            char path[64];
            snprintf(path, sizeof(path), "notes[%zu].task_refs", i);
            if (parse_str_array(refs, &plan->notes[i].task_refs,
                                &plan->notes[i].task_ref_count,
                                (long)n, err, err_sz, path)) {
                return 1;
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 解析入口                                                            */
/* ------------------------------------------------------------------ */

int ts_plan_parse(const char *json, size_t json_len, const TsConfig *cfg,
                  TsPlan *plan, char *err, size_t err_sz)
{
    cJSON *root = NULL;
    cJSON *tasks = NULL;
    cJSON *item = NULL;
    const char *sv;
    size_t i, n;
    int rc = 1;

    if (plan == NULL || cfg == NULL) return 1;
    ts_plan_init(plan);

    if (json == NULL || json_len == 0) {
        snprintf(err, err_sz, "模型返回正文为空");
        goto done;
    }

    root = cJSON_Parse(json);
    if (root == NULL) {
        snprintf(err, err_sz, "模型输出 JSON 解析失败：%s",
                 cJSON_GetErrorPtr() != NULL ? cJSON_GetErrorPtr() : "未知错误");
        goto done;
    }
    if (!cJSON_IsObject(root)) {
        snprintf(err, err_sz, "模型输出顶层必须是 JSON 对象");
        goto done;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "schema_version");
    if (item == NULL || !cJSON_IsString(item)) {
        snprintf(err, err_sz, "缺少或无效的 schema_version");
        goto done;
    }
    sv = cJSON_GetStringValue(item);
    parse_schema_version(sv, &plan->schema_major, &plan->schema_minor);

    /* summary（schema 2.0）：一句话总结；缺失不致命，用输入摘要兜底 */
    item = cJSON_GetObjectItemCaseSensitive(root, "summary");
    if (item != NULL && !cJSON_IsNull(item)) {
        if (!cJSON_IsString(item)) {
            snprintf(err, err_sz, "summary 必须是字符串或 null");
            goto done;
        }
        sv = cJSON_GetStringValue(item);
        if (strlen(sv) > TS_MAX_STRING_BYTES) {
            snprintf(err, err_sz, "summary 过长");
            goto done;
        }
        plan->summary = ts_strdup(sv);
        if (plan->summary == NULL) { oom(err, err_sz); goto done; }
    }

    tasks = cJSON_GetObjectItemCaseSensitive(root, "tasks");
    if (tasks == NULL || !cJSON_IsArray(tasks)) {
        snprintf(err, err_sz, "缺少或无效的 tasks 数组");
        goto done;
    }
    n = cJSON_GetArraySize(tasks);
    if (n == 0) {
        snprintf(err, err_sz, "tasks 数组为空");
        goto done;
    }
    if ((long)n > cfg->max_tasks) {
        snprintf(err, err_sz, "任务数量超过上限(%ld，实际 %zu)", cfg->max_tasks, n);
        goto done;
    }

    plan->tasks = (TsTask *)ts_calloc(n, sizeof(TsTask));
    if (plan->tasks == NULL) {
        oom(err, err_sz);
        goto done;
    }
    plan->task_count = n;

    for (i = 0; i < n; i++) {
        const cJSON *to = cJSON_GetArrayItem(tasks, (int)i);
        char where[64];
        if (to == NULL || !cJSON_IsObject(to)) {
            snprintf(err, err_sz, "tasks[%zu] 必须是对象", i);
            goto done;
        }
        snprintf(where, sizeof(where), "tasks[%zu]", i);
        if (parse_task(to, &plan->tasks[i], cfg, err, err_sz, where) != 0) {
            goto done;
        }
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "assumptions");
    if (item != NULL) {
        if (parse_str_array(item, &plan->assumptions, &plan->assumptions_count,
                            TS_MAX_ASSUMPTIONS, err, err_sz, "assumptions")) goto done;
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "questions");
    if (item != NULL) {
        if (parse_str_array(item, &plan->questions, &plan->questions_count,
                            TS_MAX_QUESTIONS, err, err_sz, "questions")) goto done;
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "notes");
    if (item != NULL && !cJSON_IsNull(item)) {
        if (parse_notes(item, plan, err, err_sz)) goto done;
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "suggested_order");
    if (item != NULL) {
        /* 仅作参考，最终顺序由本地算法产生 */
        if (parse_str_array(item, &plan->suggested_order, &plan->suggested_order_count,
                            (long)n, err, err_sz, "suggested_order")) goto done;
    }

    if (ts_plan_validate(plan, cfg, err, err_sz) != 0) {
        goto done;
    }

    rc = 0;
done:
    if (root != NULL) cJSON_Delete(root);
    return rc;
}

