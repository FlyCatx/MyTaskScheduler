/*
 * test_validate.c — ts_plan_validate() 行为测试（不依赖 cJSON）。
 *
 * 覆盖需求明确要求的校验项：schema 版本、ID 唯一、自依赖、缺失依赖、
 * 重复依赖、循环依赖、紧迫性/影响力范围、工时为正或未知、外部条件枚举、
 * 字符串与数量上限。
 */

#include "../src/domain/types.h"
#include "../src/state/config.h"
#include "../src/domain/plan/plan.h"
#include "../src/util/mem.h"

#include <stdio.h>
#include <string.h>

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

static TsConfig make_cfg(void)
{
    TsConfig c;
    memset(&c, 0, sizeof(c));
    c.reference_hours = 2.0;
    c.w_urgency = 0.35;
    c.w_impact = 0.30;
    c.w_blocking = 0.20;
    c.w_quick_win = 0.10;
    c.w_depth = 0.05;
    c.max_tasks = 200;
    c.max_steps_per_task = 50;
    return c;
}

static TsPlan plan_new(size_t n)
{
    TsPlan p;
    ts_plan_init(&p);
    p.schema_major = 1;
    p.schema_minor = 0;
    if (n > 0) {
        p.task_count = n;
        p.tasks = (TsTask *)ts_calloc(n, sizeof(TsTask));
    }
    return p;
}

static void task_set(TsTask *t, const char *id, const char *name,
                     int urgency, int impact, int has_hours, double hours)
{
    ts_task_init(t);
    t->id = ts_strdup(id);
    t->name = ts_strdup(name);
    t->urgency = urgency;
    t->impact = impact;
    t->has_estimated_hours = has_hours;
    t->estimated_hours = has_hours ? hours : 0.0;
    t->actual_status = TS_ACTUAL_TODO;
}

static void task_dep(TsTask *t, const char *id)
{
    char **nv = (char **)ts_realloc(t->depends_on, (t->depends_on_count + 1) * sizeof(char *));
    nv[t->depends_on_count++] = ts_strdup(id);
    t->depends_on = nv;
}

static void task_pre(TsTask *t, const char *desc, TsPrecondStatus st)
{
    TsPrecondition *nv = (TsPrecondition *)ts_realloc(
        t->preconditions, (t->preconditions_count + 1) * sizeof(TsPrecondition));
    nv[t->preconditions_count].description = ts_strdup(desc);
    nv[t->preconditions_count].status = st;
    t->preconditions_count++;
    t->preconditions = nv;
}

/* 期望校验失败，并且错误信息包含关键字。 */
static void expect_bad(TsPlan *p, const TsConfig *cfg, const char *keyword, const char *what)
{
    char err[512];
    int rc;
    err[0] = '\0';
    rc = ts_plan_validate(p, cfg, err, sizeof(err));
    if (rc == 0) {
        printf("  [FAIL] %s（本应失败却通过）\n", what);
        g_fail++;
        return;
    }
    if (keyword != NULL && strstr(err, keyword) == NULL) {
        printf("  [FAIL] %s（错误信息未包含“%s”：%s）\n", what, keyword, err);
        g_fail++;
        return;
    }
    printf("  [PASS] %s\n", what);
}

static void expect_ok(TsPlan *p, const TsConfig *cfg, const char *what)
{
    char err[512];
    int rc;
    err[0] = '\0';
    rc = ts_plan_validate(p, cfg, err, sizeof(err));
    if (rc != 0) {
        printf("  [FAIL] %s（本应通过却失败：%s）\n", what, err);
        g_fail++;
        return;
    }
    printf("  [PASS] %s\n", what);
}

int main(void)
{
    TsConfig cfg = make_cfg();
    TsPlan p;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 计划校验测试 ===\n\n");

    /* 1. 合法：单链 */
    p = plan_new(2);
    task_set(&p.tasks[0], "T1", "任务一", 3, 4, 1, 2.0);
    task_set(&p.tasks[1], "T2", "任务二", 4, 5, 1, 3.0);
    task_dep(&p.tasks[1], "T1");
    expect_ok(&p, &cfg, "合法：单链依赖");
    ts_plan_free(&p);

    /* 2. 合法：菱形 + 未知工时 + 外部条件 */
    p = plan_new(4);
    task_set(&p.tasks[0], "A", "A", 3, 3, 1, 1.0);
    task_set(&p.tasks[1], "B", "B", 3, 3, 0, 0.0);          /* 工时未知 */
    task_dep(&p.tasks[1], "A");
    task_set(&p.tasks[2], "C", "C", 3, 3, 1, 1.0);
    task_dep(&p.tasks[2], "A");
    task_pre(&p.tasks[2], "需要许可", TS_PRECOND_UNKNOWN);
    task_set(&p.tasks[3], "D", "D", 3, 3, 1, 1.0);
    task_dep(&p.tasks[3], "B");
    task_dep(&p.tasks[3], "C");
    expect_ok(&p, &cfg, "合法：菱形依赖 + 未知工时 + 未知条件");
    ts_plan_free(&p);

    /* 3. schema 版本：1.0 与 2.x 兼容，其它拒绝 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    p.schema_major = 3;
    expect_bad(&p, &cfg, "schema_version", "拒绝不支持的 schema_version");
    ts_plan_free(&p);

    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    p.schema_major = 2;
    p.schema_minor = 0;
    expect_ok(&p, &cfg, "合法：schema_version 2.0（新增 summary/notes）");
    ts_plan_free(&p);

    /* 4. 空任务列表 */
    p = plan_new(0);
    expect_bad(&p, &cfg, "为空", "拒绝空任务列表");
    ts_plan_free(&p);

    /* 5. ID 重复 */
    p = plan_new(2);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    task_set(&p.tasks[1], "T1", "任务二", 3, 3, 1, 1.0);
    expect_bad(&p, &cfg, "重复", "拒绝重复的任务 ID");
    ts_plan_free(&p);

    /* 6. 自依赖 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    task_dep(&p.tasks[0], "T1");
    expect_bad(&p, &cfg, "自身", "拒绝自依赖");
    ts_plan_free(&p);

    /* 7. 缺失依赖 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    task_dep(&p.tasks[0], "NOPE");
    expect_bad(&p, &cfg, "不存在", "拒绝依赖不存在的任务");
    ts_plan_free(&p);

    /* 8. 重复依赖 */
    p = plan_new(2);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    task_set(&p.tasks[1], "T2", "任务二", 3, 3, 1, 1.0);
    task_dep(&p.tasks[1], "T1");
    task_dep(&p.tasks[1], "T1");
    expect_bad(&p, &cfg, "重复依赖", "拒绝重复依赖");
    ts_plan_free(&p);

    /* 9. 循环依赖 */
    p = plan_new(2);
    task_set(&p.tasks[0], "X", "X", 3, 3, 1, 1.0);
    task_set(&p.tasks[1], "Y", "Y", 3, 3, 1, 1.0);
    task_dep(&p.tasks[0], "Y");
    task_dep(&p.tasks[1], "X");
    expect_bad(&p, &cfg, "循环", "拒绝循环依赖（不擅自删边）");
    ts_plan_free(&p);

    /* 10. 三节点循环 */
    p = plan_new(3);
    task_set(&p.tasks[0], "X", "X", 3, 3, 1, 1.0);
    task_set(&p.tasks[1], "Y", "Y", 3, 3, 1, 1.0);
    task_set(&p.tasks[2], "Z", "Z", 3, 3, 1, 1.0);
    task_dep(&p.tasks[0], "Z");
    task_dep(&p.tasks[1], "X");
    task_dep(&p.tasks[2], "Y");
    expect_bad(&p, &cfg, "循环", "拒绝三节点循环");
    ts_plan_free(&p);

    /* 11. 紧迫性范围 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 0, 3, 1, 1.0);
    expect_bad(&p, &cfg, "urgency", "拒绝 urgency=0");
    ts_plan_free(&p);

    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 6, 3, 1, 1.0);
    expect_bad(&p, &cfg, "urgency", "拒绝 urgency=6");
    ts_plan_free(&p);

    /* 12. 影响力范围 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 6, 1, 1.0);
    expect_bad(&p, &cfg, "impact", "拒绝 impact=6");
    ts_plan_free(&p);

    /* 13. 工时非法 */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 0.0);
    expect_bad(&p, &cfg, "estimated_hours", "拒绝 estimated_hours=0");
    ts_plan_free(&p);

    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, -2.0);
    expect_bad(&p, &cfg, "estimated_hours", "拒绝负工时");
    ts_plan_free(&p);

    /* 14. 工时未知合法（不得当作 0） */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 0, 0.0);
    expect_ok(&p, &cfg, "接受未知工时（has_estimated_hours=0）");
    ts_plan_free(&p);

    /* 15. 缺少 name / id */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    ts_free(p.tasks[0].name);
    p.tasks[0].name = NULL;
    expect_bad(&p, &cfg, "name", "拒绝缺少 name");
    ts_plan_free(&p);

    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    ts_free(p.tasks[0].id);
    p.tasks[0].id = NULL;
    expect_bad(&p, &cfg, "id", "拒绝缺少 id");
    ts_plan_free(&p);

    /* 16. 外部条件枚举（本地编辑可能写入非法值） */
    p = plan_new(1);
    task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
    task_pre(&p.tasks[0], "条件", TS_PRECOND_MET);
    p.tasks[0].preconditions[0].status = (TsPrecondStatus)5;
    expect_bad(&p, &cfg, "外部条件", "拒绝非法外部条件状态");
    ts_plan_free(&p);

    /* 17. 数量上限 */
    {
        TsConfig small = make_cfg();
        small.max_tasks = 1;
        p = plan_new(2);
        task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
        task_set(&p.tasks[1], "T2", "任务二", 3, 3, 1, 1.0);
        expect_bad(&p, &small, "上限", "拒绝超过 max_tasks");
        ts_plan_free(&p);
    }
    {
        TsConfig small = make_cfg();
        small.max_steps_per_task = 1;
        p = plan_new(1);
        task_set(&p.tasks[0], "T1", "任务一", 3, 3, 1, 1.0);
        p.tasks[0].steps = (char **)ts_calloc(2, sizeof(char *));
        p.tasks[0].steps[0] = ts_strdup("步骤1");
        p.tasks[0].steps[1] = ts_strdup("步骤2");
        p.tasks[0].steps_count = 2;
        expect_bad(&p, &small, "步骤", "拒绝超过 max_steps_per_task");
        ts_plan_free(&p);
    }

    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

