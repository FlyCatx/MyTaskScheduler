/*
 * test_plan.c — plan.c 的**运行期**行为（真实 cJSON）。
 *
 * 重点覆盖校核报告发现 #2（P1）：
 *   早期实现把 depends_on / preconditions / steps 当成可选字段，
 *   缺失时默认成空数组，于是“模型没分析出来”和“确实没有依赖”无法区分，
 *   任务会被错误地判为可开始。修复后所有协议字段必须显式出现。
 *
 * 本文件用真实 cJSON 解析，因此可以真正验证运行期行为，
 * 而不是只做编译级检查（旧版 VERIFICATION.md 的空白点之一）。
 */

#include <stdio.h>
#include <string.h>

#include "../src/domain/plan/plan.h"
#include "../src/state/config.h"
#include "../src/util/mem.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

/* 失败时同时打印实际收到的错误信息，便于定位。 */
#define CHECK_ERR(cond, msg, err) do {                           \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n         错误信息：%s\n",         \
                  msg, (err) != NULL ? (err) : "(null)");        \
           g_fail++; }                                           \
} while (0)

/* 构造一行单任务 JSON，任务对象的内容由调用方给出。 */
static char *make_json(const char *task_body)
{
    size_t need = strlen(task_body) + 256;
    char *buf = (char *)malloc(need);
    if (buf == NULL) return NULL;
    snprintf(buf, need,
             "{\"schema_version\":\"1.0\",\"tasks\":[{\"id\":\"T1\",\"name\":\"任务一\",%s}]}",
             task_body);
    return buf;
}

/* 解析一段 JSON；返回 parse 的返回值，err 中带错误信息。 */
static int parse(const char *json, TsPlan *plan, char *err, size_t err_sz)
{
    TsConfig cfg;
    int rc;
    ts_config_init(&cfg);
    ts_plan_init(plan);
    rc = ts_plan_parse(json, strlen(json), &cfg, plan, err, err_sz);
    ts_config_free(&cfg);
    return rc;
}

/* ------------------------------------------------------------------ */
/* 必需字段清单：字段名 + 该字段的 JSON 成员文本（含键名）             */
/* ------------------------------------------------------------------ */

typedef struct FieldDef {
    const char *name;
    const char *member;
} FieldDef;

/*
 * 协议规定必须出现的字段。模板里每个成员都用同一段文本，
 * 便于“去掉其中一个字段”后重新拼出一份仍然合法的 JSON
 * （漏掉一个逗号会制造语法错误，从而把“字段缺失”误判成“JSON 非法”）。
 */
static const FieldDef kFields[] = {
    { "id",              "\"id\": \"T1\"" },
    { "name",            "\"name\": \"任务一\"" },
    { "depends_on",      "\"depends_on\": []" },
    { "preconditions",   "\"preconditions\": [{\"description\":\"已取得材料\",\"status\":\"met\"}]" },
    { "steps",           "\"steps\": [\"步骤一\"]" },
    { "urgency",         "\"urgency\": 3" },
    { "urgency_reason",  "\"urgency_reason\": \"一般\"" },
    { "impact",          "\"impact\": 4" },
    { "impact_reason",   "\"impact_reason\": \"影响后续\"" },
    { "estimated_hours", "\"estimated_hours\": 2.0" },
    { "estimate_reason", "\"estimate_reason\": \"经验估计\"" },
    { "deadline",        "\"deadline\": null" },
    { "source_refs",     "\"source_refs\": [\"文件1:段落1\"]" }
};

static const size_t kFieldCount = sizeof(kFields) / sizeof(kFields[0]);

/*
 * 构造任务对象 JSON：skip_name 为 NULL 时包含全部字段，
 * 否则跳过该字段（其余字段仍用合法的逗号分隔）。
 */
static char *make_task_json(const char *skip_name)
{
    size_t need = 64;
    char *buf;
    size_t i;
    size_t used = 0;
    int first = 1;

    for (i = 0; i < kFieldCount; i++) {
        if (skip_name != NULL && strcmp(kFields[i].name, skip_name) == 0) continue;
        need += strlen(kFields[i].member) + 4;
    }
    buf = (char *)malloc(need);
    if (buf == NULL) return NULL;
    buf[used++] = '{';
    for (i = 0; i < kFieldCount; i++) {
        size_t mlen;
        if (skip_name != NULL && strcmp(kFields[i].name, skip_name) == 0) continue;
        mlen = strlen(kFields[i].member);
        if (!first) {
            buf[used++] = ',';
            buf[used++] = ' ';
        }
        memcpy(buf + used, kFields[i].member, mlen);
        used += mlen;
        first = 0;
    }
    buf[used++] = '}';
    buf[used] = '\0';
    return buf;
}

/* ------------------------------------------------------------------ */

static void test_required_fields(void)
{
    size_t i;

    printf("== 必需字段缺失必须报错（修复 #2）==\n");

    for (i = 0; i < kFieldCount; i++) {
        const char *field = kFields[i].name;
        char *task = make_task_json(field);
        char *json = NULL;
        char err[512];
        TsPlan plan;
        int rc;
        char msg[160];

        if (task == NULL) { g_fail++; continue; }
        {
            size_t nn = strlen(task) + 128;
            json = (char *)malloc(nn);
            if (json != NULL) {
                snprintf(json, nn,
                         "{\"schema_version\":\"1.0\",\"tasks\":[%s]}", task);
            }
        }
        free(task);
        if (json == NULL) { g_fail++; continue; }

        err[0] = '\0';
        rc = parse(json, &plan, err, sizeof(err));
        ts_plan_free(&plan);
        free(json);

        snprintf(msg, sizeof(msg), "缺少 %s 时解析失败（不默认成空值）", field);
        CHECK_ERR(rc != 0, msg, err);
        snprintf(msg, sizeof(msg), "缺少 %s 时错误信息指出该字段", field);
        CHECK_ERR(strstr(err, field) != NULL, msg, err);
    }

    /* 顶层必需字段 */
    {
        char err[512];
        TsPlan plan;
        const char *no_schema = "{\"tasks\":[{\"id\":\"T1\",\"name\":\"n\"}]}";
        err[0] = '\0';
        CHECK(parse(no_schema, &plan, err, sizeof(err)) != 0, "缺少 schema_version 被拒绝");
        ts_plan_free(&plan);

        err[0] = '\0';
        CHECK(parse("{\"schema_version\":\"1.0\"}", &plan, err, sizeof(err)) != 0,
              "缺少 tasks 被拒绝");
        ts_plan_free(&plan);

        err[0] = '\0';
        CHECK(parse("{\"schema_version\":\"1.0\",\"tasks\":[]}", &plan, err, sizeof(err)) != 0,
              "tasks 为空数组被拒绝");
        ts_plan_free(&plan);
    }
}

static void test_explicit_empty_is_accepted(void)
{
    char err[512];
    TsPlan plan;
    char *json;
    const char *body =
        "\"depends_on\": [],"
        "\"preconditions\": [],"
        "\"steps\": [\"唯一一步\"],"
        "\"urgency\": 1,"
        "\"urgency_reason\": \"不急\","
        "\"impact\": 2,"
        "\"impact_reason\": \"中等\","
        "\"estimated_hours\": null,"
        "\"estimate_reason\": null,"
        "\"deadline\": null,"
        "\"source_refs\": []";

    printf("== 显式空值必须被接受（与缺失区分开）==\n");

    json = make_json(body);
    if (json == NULL) { g_fail++; return; }
    err[0] = '\0';
    CHECK(parse(json, &plan, err, sizeof(err)) == 0, "显式 [] 与 null 可正常解析");
    if (plan.task_count == 1) {
        CHECK(plan.tasks[0].depends_on_count == 0, "depends_on: [] 解析为 0 个依赖");
        CHECK(plan.tasks[0].preconditions_count == 0, "preconditions: [] 解析为 0 个条件");
        CHECK(plan.tasks[0].source_refs_count == 0, "source_refs: [] 解析为 0 个来源");
        CHECK(plan.tasks[0].steps_count == 1, "steps 正常解析");
        CHECK(plan.tasks[0].has_estimated_hours == 0,
              "estimated_hours: null 解析为“未知”，而不是 0");
        CHECK(plan.tasks[0].estimate_reason == NULL, "estimate_reason: null 解析为 NULL");
        CHECK(plan.tasks[0].deadline == NULL, "deadline: null 解析为 NULL");
        CHECK(plan.tasks[0].actual_status == TS_ACTUAL_TODO,
              "模型输出不得擅自标记任务为已完成");
    } else {
        printf("  [FAIL] 任务数量应为 1\n");
        g_fail++;
    }
    ts_plan_free(&plan);
    free(json);

    /* 空 steps 数组 + 显式空依赖：应被接受（业务校验另有规则） */
    {
        const char *body2 =
            "\"depends_on\": [],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1.5,"
            "\"estimate_reason\": \"c\",\"deadline\": \"2026-12-31\","
            "\"source_refs\": [\"文件1:段落2\"]";
        json = make_json(body2);
        if (json == NULL) { g_fail++; return; }
        err[0] = '\0';
        CHECK(parse(json, &plan, err, sizeof(err)) == 0, "空 steps 与空依赖仍可解析");
        ts_plan_free(&plan);
        free(json);
    }
}

static void test_type_and_range_rejection(void)
{
    char err[512];
    TsPlan plan;
    char *json;

    printf("== 类型与取值拒绝路径 ==\n");

    /* depends_on 不是数组 */
    {
        const char *bad =
            "\"depends_on\": \"T1\",\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "depends_on 非数组被拒绝");
        CHECK(strstr(err, "必须是数组") != NULL, "错误信息说明必须是数组");
        ts_plan_free(&plan); free(json);
    }

    /* depends_on 元素不是字符串 */
    {
        const char *bad =
            "\"depends_on\": [123],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "depends_on 元素非字符串被拒绝");
        ts_plan_free(&plan); free(json);
    }

    /* urgency 超出 1..5 */
    {
        const char *bad =
            "\"depends_on\": [],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 9,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "urgency=9 被业务校验拒绝");
        ts_plan_free(&plan); free(json);
    }

    /* urgency 不是整数 */
    {
        const char *bad =
            "\"depends_on\": [],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 2.5,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "urgency=2.5 被拒绝");
        CHECK(strstr(err, "整数") != NULL, "错误信息说明必须是整数");
        ts_plan_free(&plan); free(json);
    }

    /* estimated_hours 为负数 */
    {
        const char *bad =
            "\"depends_on\": [],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": -2,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "负工时被拒绝");
        ts_plan_free(&plan); free(json);
    }

    /* 外部条件 status 非法 */
    {
        const char *bad =
            "\"depends_on\": [],\"preconditions\": [{\"description\":\"x\",\"status\":\"maybe\"}],"
            "\"steps\": [],\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "非法 status 被拒绝");
        CHECK(strstr(err, "met/unmet/unknown") != NULL, "错误信息给出合法枚举");
        ts_plan_free(&plan); free(json);
    }

    /* 依赖指向不存在的任务 */
    {
        const char *bad =
            "\"depends_on\": [\"NOPE\"],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "缺失依赖被拒绝");
        ts_plan_free(&plan); free(json);
    }

    /* 自依赖 */
    {
        const char *bad =
            "\"depends_on\": [\"T1\"],\"preconditions\": [],\"steps\": [],"
            "\"urgency\": 3,\"urgency_reason\": \"a\",\"impact\": 3,"
            "\"impact_reason\": \"b\",\"estimated_hours\": 1,"
            "\"estimate_reason\": \"c\",\"deadline\": null,\"source_refs\": []";
        json = make_json(bad);
        err[0] = '\0';
        CHECK(json && parse(json, &plan, err, sizeof(err)) != 0, "自依赖被拒绝");
        ts_plan_free(&plan); free(json);
    }

    /* 非法 JSON */
    {
        char err2[512];
        TsPlan p2;
        err2[0] = '\0';
        CHECK(parse("{\"schema_version\":", &p2, err2, sizeof(err2)) != 0,
              "非法 JSON 被拒绝");
        CHECK(strstr(err2, "JSON") != NULL, "错误信息说明 JSON 解析失败");
        ts_plan_free(&p2);
    }

    /* 空正文 */
    {
        char err2[512];
        TsPlan p2;
        TsConfig cfg;
        err2[0] = '\0';
        ts_config_init(&cfg);
        ts_plan_init(&p2);
        CHECK(ts_plan_parse("", 0, &cfg, &p2, err2, sizeof(err2)) != 0, "空正文被拒绝");
        ts_plan_free(&p2);
        ts_config_free(&cfg);
    }
}

/* ------------------------------------------------------------------ */

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler JSON 解析测试（真实 cJSON）===\n\n");

    test_required_fields();
    test_explicit_empty_is_accepted();
    test_type_and_range_rejection();

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

