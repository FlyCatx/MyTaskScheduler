/*
 * test_export_json.c — JSON 导出的**运行期**输出验证（真实 cJSON）。
 *
 * 旧版 VERIFICATION.md 把“JSON 导出的运行期输出”列为未验证项（当时没有 cJSON 实现）。
 * 本文件用真实 cJSON 导出到磁盘、读回、再用 cJSON 解析，逐项核对：
 *   - schema_version / algorithm_version / 时间戳 / 配置与权重；
 *   - 每个任务的完整数据、状态快照、排序依据与可复算的得分等式；
 *   - order 最终顺序；
 *   - 受阻 / 待确认 / 受影响清单；
 *   - **绝不含 API Key**（用真实 cJSON 遍历整棵输出树查找）；
 *   - 导出失败时内存中的计划不被修改。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#include "../src/domain/types.h"
#include "../src/state/config.h"
#include "../src/domain/schedule/scheduler.h"
#include "../src/domain/export/export.h"
#include "../src/util/mem.h"
#include "../src/platform/text.h"

#include "cJSON.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

/* ------------------------------------------------------------------ */
/* 计划构造                                                            */
/* ------------------------------------------------------------------ */

static void set_task(TsTask *t, const char *id, const char *name,
                     int urgency, int impact, int has_hours, double hours)
{
    ts_task_init(t);
    t->id = ts_strdup(id);
    t->name = ts_strdup(name);
    t->urgency = urgency;
    t->impact = impact;
    t->has_estimated_hours = has_hours;
    t->estimated_hours = hours;
    t->urgency_reason = ts_strdup("紧迫性理由");
    t->impact_reason = ts_strdup("影响力理由");
    t->actual_status = TS_ACTUAL_TODO;
}

static void add_dep(TsTask *t, const char *id)
{
    char **nv = (char **)ts_realloc(t->depends_on,
                                    (t->depends_on_count + 1) * sizeof(char *));
    if (nv == NULL) return;
    nv[t->depends_on_count++] = ts_strdup(id);
    t->depends_on = nv;
}

static void add_precond(TsTask *t, const char *desc, TsPrecondStatus st)
{
    TsPrecondition *nv = (TsPrecondition *)ts_realloc(
        t->preconditions, (t->preconditions_count + 1) * sizeof(TsPrecondition));
    if (nv == NULL) return;
    nv[t->preconditions_count].description = ts_strdup(desc);
    nv[t->preconditions_count].status = st;
    t->preconditions_count++;
    t->preconditions = nv;
}

static void add_step(TsTask *t, const char *s)
{
    char **nv = (char **)ts_realloc(t->steps, (t->steps_count + 1) * sizeof(char *));
    if (nv == NULL) return;
    nv[t->steps_count++] = ts_strdup(s);
    t->steps = nv;
}

static void add_ref(TsTask *t, const char *r)
{
    char **nv = (char **)ts_realloc(t->source_refs,
                                    (t->source_refs_count + 1) * sizeof(char *));
    if (nv == NULL) return;
    nv[t->source_refs_count++] = ts_strdup(r);
    t->source_refs = nv;
}

/* T1 （无依赖，已知工时）
 * T2  依赖 T1（未知工时）
 * T3  依赖 T1, T2（多前置）；外部条件 unmet => 受阻
 * T4  无依赖；外部条件 unknown => 待确认
 */
static void build_plan(TsPlan *plan)
{
    ts_plan_init(plan);
    plan->schema_major = 1;
    plan->schema_minor = 0;
    plan->task_count = 4;
    plan->tasks = (TsTask *)ts_calloc(4, sizeof(TsTask));
    if (plan->tasks == NULL) return;

    set_task(&plan->tasks[0], "T1", "整理需求", 4, 5, 1, 2.0);
    add_step(&plan->tasks[0], "通读材料");
    add_step(&plan->tasks[0], "列出清单");
    add_ref(&plan->tasks[0], "文件1:段落1");

    set_task(&plan->tasks[1], "T2", "搭建骨架", 3, 4, 0, 0.0); /* 工时未知 */
    add_dep(&plan->tasks[1], "T1");
    add_step(&plan->tasks[1], "创建目录");

    set_task(&plan->tasks[2], "T3", "联调接口", 2, 3, 1, 6.0);
    add_dep(&plan->tasks[2], "T1");
    add_dep(&plan->tasks[2], "T2");
    add_precond(&plan->tasks[2], "已取得 API Key", TS_PRECOND_UNMET);

    set_task(&plan->tasks[3], "T4", "写文档", 1, 2, 1, 1.0);
    add_precond(&plan->tasks[3], "等审批结果", TS_PRECOND_UNKNOWN);

    plan->assumptions_count = 1;
    plan->assumptions = (char **)ts_calloc(1, sizeof(char *));
    if (plan->assumptions != NULL) {
        plan->assumptions[0] = ts_strdup("假设材料已完整");
    }
    plan->questions_count = 1;
    plan->questions = (char **)ts_calloc(1, sizeof(char *));
    if (plan->questions != NULL) {
        plan->questions[0] = ts_strdup("API Key 何时就绪？");
    }
}

/* ------------------------------------------------------------------ */
/* 读回文件                                                            */
/* ------------------------------------------------------------------ */

static char *read_file_utf8(const char *path, size_t *out_len, int *has_bom)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    long sz;
    char *buf;

    *out_len = 0;
    *has_bom = 0;
    if (wp == NULL) return NULL;
    f = _wfopen(wp, L"rb");
    ts_free(wp);
    if (f == NULL) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    rewind(f);
    buf = (char *)malloc((size_t)sz + 1);
    if (buf == NULL) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    buf[sz] = '\0';
    *out_len = (size_t)sz;
    if ((size_t)sz >= 3 && (unsigned char)buf[0] == 0xEF &&
        (unsigned char)buf[1] == 0xBB && (unsigned char)buf[2] == 0xBF) {
        *has_bom = 1;
    }
    return buf;
}

/* 在整棵 JSON 树里查找“键名或字符串值”是否包含 needle。 */
static int tree_contains(const cJSON *item, const char *needle, int check_keys)
{
    for (; item != NULL; item = item->next) {
        if (check_keys && item->string != NULL && strstr(item->string, needle) != NULL) {
            return 1;
        }
        if (cJSON_IsString(item) && item->valuestring != NULL &&
            strstr(item->valuestring, needle) != NULL) {
            return 1;
        }
        if (cJSON_IsObject(item) || cJSON_IsArray(item)) {
            if (tree_contains(item->child, needle, check_keys)) return 1;
        }
    }
    return 0;
}

static const cJSON *obj(const cJSON *o, const char *k)
{
    return cJSON_GetObjectItemCaseSensitive(o, k);
}

static const cJSON *task_by_id(const cJSON *root, const char *id)
{
    const cJSON *tasks = obj(root, "tasks");
    const cJSON *t;
    if (!cJSON_IsArray(tasks)) return NULL;
    for (t = tasks->child; t != NULL; t = t->next) {
        const cJSON *tid = obj(t, "id");
        if (cJSON_IsString(tid) && strcmp(tid->valuestring, id) == 0) return t;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */

int main(void)
{
    TsPlan plan;
    TsConfig cfg;
    TsScheduleResult sched;
    TsStatusView status;
    char err[512];
    const char *json_path = "ts_test_export_json_out.json";
    char *raw = NULL;
    size_t raw_len = 0;
    int has_bom = 0;
    cJSON *root = NULL;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler JSON 导出测试（真实 cJSON）===\n\n");

    ts_config_init(&cfg);
    cfg.endpoint_url = ts_strdup("https://api.deepseek.com/v1/chat/completions");
    cfg.model = ts_strdup("deepseek-chat");
    cfg.api_key_env = ts_strdup("DEEPSEEK_API_KEY");
    /* 故意放一个可识别的假密钥：导出绝不能把它写出去 */
    cfg.api_key = ts_strdup("sk-CANARY-MUST-NOT-APPEAR-1234567890");

    build_plan(&plan);
    if (plan.task_count != 4) {
        printf("  [FAIL] 计划构造失败\n");
        return 1;
    }

    err[0] = '\0';
    CHECK(ts_schedule_build(&plan, &cfg, &sched, err, sizeof(err)) == 0,
          "生成排序结果（前置步骤）");
    err[0] = '\0';
    CHECK(ts_schedule_status(&plan, &status, err, sizeof(err)) == 0,
          "生成状态视图（前置步骤）");

    printf("== 导出并读回 ==\n");
    err[0] = '\0';
    CHECK(ts_export_json(&plan, &sched, &status, &cfg, json_path, err, sizeof(err)) == 0,
          "JSON 导出成功写盘");
    raw = read_file_utf8(json_path, &raw_len, &has_bom);
    CHECK(raw != NULL, "导出的 JSON 文件可读回");
    CHECK(has_bom == 0, "JSON 导出不带 BOM（UTF-8 无 BOM）");

    if (raw == NULL) {
        printf("\n=== 结果：存在失败（无法读回导出文件）===\n");
        return 1;
    }

    root = cJSON_Parse(raw);
    CHECK(root != NULL, "导出的内容是合法 JSON（真实 cJSON 可解析）");
    if (root == NULL) {
        printf("  解析错误位置：%s\n", cJSON_GetErrorPtr());
        free(raw);
        return 1;
    }

    printf("== 顶层字段 ==\n");
    {
        const cJSON *v;
        v = obj(root, "schema_version");
        CHECK(cJSON_IsString(v) && strcmp(v->valuestring, TS_SCHEMA_VERSION) == 0,
              "schema_version 与协议常量一致");
        v = obj(root, "algorithm_version");
        CHECK(cJSON_IsString(v) && strcmp(v->valuestring, TS_ALGORITHM_VERSION) == 0,
              "algorithm_version 与算法常量一致");
        v = obj(root, "exported_at");
        CHECK(cJSON_IsString(v) && strlen(v->valuestring) == 19,
              "exported_at 为 \"YYYY-MM-DD HH:MM:SS\" 形式");
        v = obj(root, "sorted_at");
        CHECK(cJSON_IsString(v) && v->valuestring[0] != '\0', "sorted_at 非空");
        v = obj(root, "producer");
        CHECK(cJSON_IsString(v), "producer 存在");
        v = obj(root, "unresolvable_reason");
        CHECK(v != NULL, "unresolvable_reason 存在（已全部排完时为空串）");
    }

    printf("== 配置与权重 ==\n");
    {
        const cJSON *c = obj(root, "config");
        const cJSON *w;
        CHECK(cJSON_IsObject(c), "config 是对象");
        if (cJSON_IsObject(c)) {
            CHECK(cJSON_IsString(obj(c, "endpoint_url")), "config.endpoint_url 存在");
            CHECK(cJSON_IsString(obj(c, "model")), "config.model 存在");
            CHECK(cJSON_IsString(obj(c, "api_key_env")), "config.api_key_env 存在（只写变量名）");
            CHECK(cJSON_IsBool(obj(c, "api_key_present")), "config.api_key_present 是布尔值");
            CHECK(cJSON_IsTrue(obj(c, "api_key_present")),
                  "api_key 已设置时 api_key_present 为 true");
            w = obj(c, "weights");
            CHECK(cJSON_IsObject(w), "config.weights 存在");
            if (cJSON_IsObject(w)) {
                const cJSON *wu = obj(w, "urgency");
                const cJSON *wi = obj(w, "impact");
                const cJSON *wb = obj(w, "blocking");
                const cJSON *wq = obj(w, "quick_win");
                const cJSON *wd = obj(w, "depth");
                double sum = 0.0;
                int ok = cJSON_IsNumber(wu) && cJSON_IsNumber(wi) && cJSON_IsNumber(wb) &&
                         cJSON_IsNumber(wq) && cJSON_IsNumber(wd);
                CHECK(ok, "五个权重维度都存在且为数字");
                if (ok) {
                    sum = wu->valuedouble + wi->valuedouble + wb->valuedouble +
                          wq->valuedouble + wd->valuedouble;
                    CHECK(fabs(sum - 1.0) < 1e-9, "导出权重之和为 1");
                    CHECK(fabs(wu->valuedouble - cfg.w_urgency) < 1e-12,
                          "导出的 urgency 权重与实际配置一致");
                }
            }
        }
    }

    printf("== 任务数据 ==\n");
    {
        const cJSON *tasks = obj(root, "tasks");
        const cJSON *t1, *t2, *t3, *t4;
        CHECK(cJSON_IsArray(tasks) && cJSON_GetArraySize(tasks) == 4, "tasks 含 4 个任务");

        t1 = task_by_id(root, "T1");
        t2 = task_by_id(root, "T2");
        t3 = task_by_id(root, "T3");
        t4 = task_by_id(root, "T4");
        CHECK(t1 && t2 && t3 && t4, "四个任务 ID 都出现");

        if (t1 != NULL) {
            const cJSON *dep = obj(t1, "depends_on");
            const cJSON *steps = obj(t1, "steps");
            const cJSON *refs = obj(t1, "source_refs");
            const cJSON *h = obj(t1, "estimated_hours");
            const cJSON *dl = obj(t1, "deadline");
            const cJSON *st = obj(t1, "actual_status");
            CHECK(cJSON_IsArray(dep) && cJSON_GetArraySize(dep) == 0, "T1.depends_on 为空数组");
            CHECK(cJSON_IsArray(steps) && cJSON_GetArraySize(steps) == 2, "T1.steps 完整导出");
            CHECK(cJSON_IsArray(refs) && cJSON_GetArraySize(refs) == 1, "T1.source_refs 完整导出");
            CHECK(cJSON_IsNumber(h) && fabs(h->valuedouble - 2.0) < 1e-9, "T1 工时导出正确");
            CHECK(cJSON_IsNull(dl), "T1.deadline 为 null（未知）");
            CHECK(cJSON_IsString(st) && strcmp(st->valuestring, "todo") == 0,
                  "T1.actual_status 为 todo（模型不得擅自标记完成）");
        }

        if (t2 != NULL) {
            const cJSON *dep = obj(t2, "depends_on");
            const cJSON *h = obj(t2, "estimated_hours");
            CHECK(cJSON_IsArray(dep) && cJSON_GetArraySize(dep) == 1, "T2 有一个前置依赖");
            CHECK(cJSON_IsNull(h), "T2 未知工时导出为 null，而不是 0");
        }

        if (t3 != NULL) {
            const cJSON *dep = obj(t3, "depends_on");
            const cJSON *pre = obj(t3, "preconditions");
            const cJSON *sco = obj(t3, "schedule");
            CHECK(cJSON_IsArray(dep) && cJSON_GetArraySize(dep) == 2, "T3 有两个前置依赖（多前置）");
            CHECK(cJSON_IsArray(pre) && cJSON_GetArraySize(pre) == 1, "T3 外部条件被导出");
            if (cJSON_IsArray(pre) && pre->child != NULL) {
                const cJSON *s = obj(pre->child, "status");
                CHECK(cJSON_IsString(s) && strcmp(s->valuestring, "unmet") == 0,
                      "T3 外部条件状态 unmet 被如实导出");
            }
            CHECK(cJSON_IsNull(sco), "受阻任务没有 schedule 节点（未被排入顺序）");
        }

        if (t4 != NULL) {
            const cJSON *ready = obj(t4, "ready_state");
            const cJSON *aff = obj(t4, "affected");
            CHECK(cJSON_IsString(ready) && strcmp(ready->valuestring, "pending_confirm") == 0,
                  "T4（外部条件 unknown）状态为 pending_confirm");
            CHECK(cJSON_IsBool(aff), "T4.affected 为布尔值");
        }
    }

    printf("== 排序依据与得分等式 ==\n");
    {
        const cJSON *order = obj(root, "order");
        const cJSON *t1 = task_by_id(root, "T1");
        const cJSON *sc;
        CHECK(cJSON_IsArray(order), "order 是数组");
        CHECK(cJSON_GetArraySize(order) == (int)sched.step_count,
              "order 长度与本地排序步骤数一致");
        if (cJSON_IsArray(order) && order->child != NULL) {
            CHECK(cJSON_IsString(order->child) &&
                  strcmp(order->child->valuestring, sched.steps[0].task_id) == 0,
                  "order[0] 与本地算法第一个步骤一致（不用模型给的顺序）");
        }
        sc = (t1 != NULL) ? obj(t1, "schedule") : NULL;
        CHECK(cJSON_IsObject(sc), "T1 有 schedule 节点");
        if (cJSON_IsObject(sc)) {
            const cJSON *n = obj(sc, "order");
            const cJSON *score = obj(sc, "score");
            const cJSON *reason = obj(sc, "reason");
            CHECK(cJSON_IsNumber(n) && n->valueint == 1, "T1 的建议序号为 1");
            CHECK(cJSON_IsString(reason) && strlen(reason->valuestring) > 0,
                  "排序理由非空（可解释性）");
            CHECK(cJSON_IsObject(score), "schedule.score 存在");
            if (cJSON_IsObject(score)) {
                const cJSON *u = obj(score, "u");
                const cJSON *ii = obj(score, "i");
                const cJSON *b = obj(score, "b");
                const cJSON *q = obj(score, "q");
                const cJSON *d = obj(score, "d");
                const cJSON *base = obj(score, "base");
                const cJSON *c = obj(score, "c");
                const cJSON *r = obj(score, "r");
                const cJSON *w = obj(score, "w");
                const cJSON *fin = obj(score, "final");
                int allnum = cJSON_IsNumber(u) && cJSON_IsNumber(ii) && cJSON_IsNumber(b) &&
                             cJSON_IsNumber(q) && cJSON_IsNumber(d) && cJSON_IsNumber(base) &&
                             cJSON_IsNumber(c) && cJSON_IsNumber(r) && cJSON_IsNumber(w) &&
                             cJSON_IsNumber(fin);
                CHECK(allnum, "得分分解字段齐全且为数字");
                if (allnum) {
                    double expect_base =
                        100.0 * (cfg.w_urgency * u->valuedouble +
                                 cfg.w_impact * ii->valuedouble +
                                 cfg.w_blocking * b->valuedouble +
                                 cfg.w_quick_win * q->valuedouble +
                                 cfg.w_depth * d->valuedouble);
                    double expect_final =
                        expect_base + 10.0 * c->valuedouble +
                        7.0 * r->valuedouble + 3.0 * w->valuedouble;
                    CHECK(fabs(base->valuedouble - expect_base) < 1e-6,
                          "base 与“实际权重 × 五维值 × 100”一致（等式含权重）");
                    CHECK(fabs(fin->valuedouble - expect_final) < 1e-6,
                          "final = base + 10C + 7R + 3W 可复算");
                }
                CHECK(obj(score, "c_weighted") != NULL &&
                      obj(score, "r_weighted") != NULL &&
                      obj(score, "w_weighted") != NULL,
                      "导出含加权后的 10C/7R/3W 分项");
                CHECK(cJSON_IsBool(obj(score, "hours_unknown")),
                      "hours_unknown 标记被导出");
                CHECK(cJSON_IsBool(obj(score, "chain_incomplete")),
                      "chain_incomplete 标记被导出");
            }
        }
    }

    printf("== 受阻 / 待确认 / 受影响清单 ==\n");
    {
        const cJSON *blocked = obj(root, "blocked");
        const cJSON *pending = obj(root, "pending");
        const cJSON *affected = obj(root, "affected");
        const cJSON *summary = obj(root, "summary");
        CHECK(cJSON_IsArray(blocked) && cJSON_GetArraySize(blocked) == 1, "受阻清单含 1 项（T3）");
        CHECK(cJSON_IsArray(pending) && cJSON_GetArraySize(pending) == 1,
              "待确认清单含 1 项（T4）");
        CHECK(cJSON_IsArray(affected), "受影响清单存在");
        if (cJSON_IsArray(blocked) && blocked->child != NULL) {
            const cJSON *id = obj(blocked->child, "id");
            const cJSON *reason = obj(blocked->child, "reason");
            CHECK(cJSON_IsString(id) && strcmp(id->valuestring, "T3") == 0,
                  "受阻任务 ID 正确");
            CHECK(cJSON_IsString(reason) && strlen(reason->valuestring) > 0,
                  "受阻原因非空");
        }
        CHECK(cJSON_IsObject(summary), "summary 存在");
        if (cJSON_IsObject(summary)) {
            const cJSON *tc = obj(summary, "task_count");
            const cJSON *dc = obj(summary, "done_count");
            CHECK(cJSON_IsNumber(tc) && tc->valueint == 4, "summary.task_count = 4");
            CHECK(cJSON_IsNumber(dc) && dc->valueint == 0, "summary.done_count = 0");
        }
    }

    printf("== 假设与待确认事项 ==\n");
    {
        const cJSON *a = obj(root, "assumptions");
        const cJSON *q = obj(root, "questions");
        CHECK(cJSON_IsArray(a) && cJSON_GetArraySize(a) == 1, "assumptions 完整导出");
        CHECK(cJSON_IsArray(q) && cJSON_GetArraySize(q) == 1, "questions 完整导出");
        if (cJSON_IsArray(q) && q->child != NULL) {
            CHECK(cJSON_IsString(q->child) &&
                  strstr(q->child->valuestring, "API Key") != NULL,
                  "待确认事项内容正确（UTF-8 中文/英文均完整）");
        }
    }

    printf("== 安全：绝不写入 API Key ==\n");
    {
        CHECK(!tree_contains(root, "sk-CANARY", 1),
              "整棵输出树不含假密钥字面量（含键名与所有字符串值）");
        CHECK(!tree_contains(root, "MUST-NOT-APPEAR", 1),
              "整棵输出树不含假密钥的其余片段");
        CHECK(tree_contains(root, "DEEPSEEK_API_KEY", 1),
              "只写环境变量名（api_key_env），供排查配置来源");
        CHECK(!tree_contains(root, "api_key\"", 1),
              "不存在名为 api_key 的字段（只有 api_key_env / api_key_present）");
        /* 原始文本层面再确认一次 */
        CHECK(strstr(raw, "sk-CANARY") == NULL, "原始文件文本也不含假密钥");
    }

    printf("== 降级路径（无排序结果 / 无状态视图）==\n");
    {
        char err2[512];
        const char *p2 = "ts_test_export_json_bare.json";
        char *raw2;
        size_t len2 = 0;
        int bom2 = 0;
        err2[0] = '\0';
        CHECK(ts_export_json(&plan, NULL, NULL, &cfg, p2, err2, sizeof(err2)) == 0,
              "sched/status 为 NULL 时导出仍成功");
        raw2 = read_file_utf8(p2, &len2, &bom2);
        CHECK(raw2 != NULL, "降级导出文件可读回");
        if (raw2 != NULL) {
            cJSON *r2 = cJSON_Parse(raw2);
            CHECK(r2 != NULL, "降级导出仍是合法 JSON");
            if (r2 != NULL) {
                const cJSON *t1 = task_by_id(r2, "T1");
                CHECK(cJSON_IsArray(obj(r2, "order")) &&
                      cJSON_GetArraySize(obj(r2, "order")) == 0,
                      "无排序结果时 order 为空数组");
                CHECK(t1 != NULL && cJSON_IsNull(obj(t1, "schedule")),
                      "无排序结果时 schedule 为 null");
                cJSON_Delete(r2);
            } else {
                printf("  解析错误位置：%s\n", cJSON_GetErrorPtr());
            }
            free(raw2);
        }
        remove(p2);
    }

    printf("== 失败路径不改变内存状态 ==\n");
    {
        char err3[512];
        size_t before_count = plan.task_count;
        char *before_name = ts_strdup(plan.tasks[0].name);
        err3[0] = '\0';
        CHECK(ts_export_json(&plan, &sched, &status, &cfg,
                             "no_such_dir_ts/out.json", err3, sizeof(err3)) != 0,
              "写入不可用路径时导出失败");
        CHECK(err3[0] != '\0', "失败时给出错误信息");
        CHECK(plan.task_count == before_count, "失败后任务数量不变");
        CHECK(before_name != NULL && plan.tasks[0].name != NULL &&
              strcmp(before_name, plan.tasks[0].name) == 0,
              "失败后任务内容不变");
        ts_free(before_name);
    }

    printf("== 格式推断 ==\n");
    {
        CHECK(ts_export_format_from_path("a.json") == TS_EXPORT_JSON, ".json -> JSON");
        CHECK(ts_export_format_from_path("a.JSON") == TS_EXPORT_JSON, ".JSON 大小写不敏感");
        CHECK(ts_export_format_from_path("a.txt") == TS_EXPORT_TXT, ".txt -> TXT");
        CHECK(ts_export_format_from_path("无扩展名") == TS_EXPORT_TXT, "无扩展名 -> TXT");
        CHECK(ts_export_format_from_path("a.txt.json") == TS_EXPORT_JSON,
              "多重扩展名取最后一个");
    }

    cJSON_Delete(root);
    free(raw);
    remove(json_path);
    ts_schedule_result_free(&sched);
    ts_status_view_free(&status);
    ts_plan_free(&plan);
    ts_config_free(&cfg);

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

