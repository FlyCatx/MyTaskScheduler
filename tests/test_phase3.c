/*
 * test_phase3.c — 阶段 3 控制台测试（调度算法，不依赖 cJSON）。
 *
 * 手工构造 TsPlan 验证：无依赖/单链/菱形依赖、未知工时、外部条件受阻/待确认、
 * 受影响传播、层级、评分、确定性排序、循环检测、状态视图、不改用户实际状态。
 */

#include "../src/domain/types.h"
#include "../src/state/config.h"
#include "../src/domain/schedule/scheduler.h"
#include "../src/util/mem.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

/* ---- 手工构造任务 ---- */
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
    t->actual_status = TS_ACTUAL_TODO;
}

static void add_dep(TsTask *t, const char *id)
{
    char **nv = (char **)ts_realloc(t->depends_on, (t->depends_on_count + 1) * sizeof(char *));
    nv[t->depends_on_count++] = ts_strdup(id);
    t->depends_on = nv;
}

static void add_precond(TsTask *t, const char *desc, TsPrecondStatus st)
{
    TsPrecondition *nv = (TsPrecondition *)ts_realloc(
        t->preconditions, (t->preconditions_count + 1) * sizeof(TsPrecondition));
    nv[t->preconditions_count].description = ts_strdup(desc);
    nv[t->preconditions_count].status = st;
    t->preconditions_count++;
    t->preconditions = nv;
}

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

static const char *id_at(const TsPlan *p, size_t i)
{
    return p->tasks[i].id;
}

static void test_build_schedule(void)
{
    printf("== 调度：顺序 / 受阻 / 待确认 / 受影响 / 未知工时 ==\n");
    TsPlan plan;
    TsConfig cfg = make_cfg();
    TsScheduleResult res;
    char err[256];
    size_t i;
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1;
    plan.schema_minor = 0;
    plan.task_count = 8;
    plan.tasks = (TsTask *)ts_calloc(8, sizeof(TsTask));

    /* T1 无依赖 */
    set_task(&plan.tasks[0], "T1", "整理需求", 3, 4, 1, 2.0);
    /* T2 依赖 T1 */
    set_task(&plan.tasks[1], "T2", "搭建骨架", 4, 5, 1, 4.0);
    add_dep(&plan.tasks[1], "T1");
    /* T3 依赖 T2 */
    set_task(&plan.tasks[2], "T3", "配置模块", 4, 4, 1, 3.0);
    add_dep(&plan.tasks[2], "T2");
    /* T4 依赖 T2，未知工时 */
    set_task(&plan.tasks[3], "T4", "输入模块", 3, 3, 0, 0.0);
    add_dep(&plan.tasks[3], "T2");
    /* T5 依赖 T3、T4（菱形） */
    set_task(&plan.tasks[4], "T5", "评分调度", 5, 5, 1, 6.0);
    add_dep(&plan.tasks[4], "T3");
    add_dep(&plan.tasks[4], "T4");
    /* T6 外部条件 unmet */
    set_task(&plan.tasks[5], "T6", "云端联调", 2, 3, 0, 0.0);
    add_dep(&plan.tasks[5], "T2");
    add_precond(&plan.tasks[5], "已取得 API Key", TS_PRECOND_UNMET);
    /* T7 依赖 T6（受影响） */
    set_task(&plan.tasks[6], "T7", "云端验收", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[6], "T6");
    /* T8 外部条件 unknown（待确认） */
    set_task(&plan.tasks[7], "T8", "性能调优", 2, 2, 1, 2.0);
    add_precond(&plan.tasks[7], "确认预算", TS_PRECOND_UNKNOWN);

    memset(&res, 0, sizeof(res));
    rc = ts_schedule_build(&plan, &cfg, &res, err, sizeof(err));
    CHECK(rc == 0, "build_schedule 成功");
    CHECK(res.step_count == 5, "可执行任务数为 5");
    if (res.step_count == 5) {
        CHECK(strcmp(id_at(&plan, res.steps[0].task_index), "T1") == 0, "第 1 步为 T1");
        CHECK(strcmp(id_at(&plan, res.steps[1].task_index), "T2") == 0, "第 2 步为 T2");
        CHECK(strcmp(id_at(&plan, res.steps[2].task_index), "T3") == 0, "第 3 步为 T3");
        CHECK(strcmp(id_at(&plan, res.steps[3].task_index), "T4") == 0, "第 4 步为 T4");
        CHECK(strcmp(id_at(&plan, res.steps[4].task_index), "T5") == 0, "第 5 步为 T5");
    }

    /* T4 未知工时标记 */
    {
        size_t t4i = SIZE_MAX;
        for (i = 0; i < res.step_count; i++) if (strcmp(res.steps[i].task_id, "T4") == 0) t4i = i;
        CHECK(t4i != SIZE_MAX, "T4 在顺序中");
        if (t4i != SIZE_MAX) {
            CHECK(res.steps[t4i].score.hours_unknown == 1, "T4 工时未知标记");
            CHECK(res.steps[t4i].score.chain_incomplete == 1, "T4 关键链不完整标记");
        }
    }

    CHECK(res.blocked_count == 1 && strcmp(res.blocked_ids[0], "T6") == 0, "受阻清单含 T6");
    CHECK(res.pending_count == 1 && strcmp(res.pending_ids[0], "T8") == 0, "待确认清单含 T8");
    CHECK(res.affected_count == 1 && strcmp(res.affected_ids[0], "T7") == 0, "受影响清单含 T7");
    CHECK(res.unresolvable_reason != NULL, "有无法执行的原因说明");

    /* 不改用户实际状态 */
    {
        int all_todo = 1;
        for (i = 0; i < plan.task_count; i++) {
            if (plan.tasks[i].actual_status != TS_ACTUAL_TODO) all_todo = 0;
        }
        CHECK(all_todo, "build_schedule 未修改用户实际状态");
    }

    ts_schedule_result_free(&res);
    ts_plan_free(&plan);
}

static void test_status(void)
{
    printf("== 状态视图 ==\n");
    TsPlan plan;
    TsStatusView v;
    char err[256];
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1; plan.schema_minor = 0;
    plan.task_count = 4;
    plan.tasks = (TsTask *)ts_calloc(4, sizeof(TsTask));

    set_task(&plan.tasks[0], "A", "任务A", 3, 3, 1, 1.0);
    set_task(&plan.tasks[1], "B", "任务B", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[1], "A");
    set_task(&plan.tasks[2], "C", "任务C", 3, 3, 1, 1.0);
    add_precond(&plan.tasks[2], "需要许可", TS_PRECOND_UNMET);
    set_task(&plan.tasks[3], "D", "任务D", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[3], "C");

    memset(&v, 0, sizeof(v));
    rc = ts_schedule_status(&plan, &v, err, sizeof(err));
    CHECK(rc == 0, "status 成功");
    if (rc == 0) {
        CHECK(v.states[0] == TS_READY, "A 可开始");
        CHECK(v.states[1] == TS_WAITING_DEP, "B 待前置");
        CHECK(v.states[2] == TS_BLOCKED, "C 受阻");
        CHECK(v.states[3] == TS_WAITING_DEP, "D 待前置");
        CHECK(v.affected[3] == 1, "D 被标记受影响");
        CHECK(v.affected[1] == 0, "B 不受影响");
    }
    ts_status_view_free(&v);

    /* 标记 A 完成 → B 变为可开始 */
    plan.tasks[0].actual_status = TS_ACTUAL_DONE;
    memset(&v, 0, sizeof(v));
    rc = ts_schedule_status(&plan, &v, err, sizeof(err));
    CHECK(rc == 0, "status(完成A后) 成功");
    if (rc == 0) {
        CHECK(v.states[0] == TS_DONE, "A 已完成");
        CHECK(v.states[1] == TS_READY, "B 变为可开始");
    }
    ts_status_view_free(&v);

    ts_plan_free(&plan);
}

static void test_cycle(void)
{
    printf("== 循环检测 ==\n");
    TsPlan plan;
    TsConfig cfg = make_cfg();
    TsScheduleResult res;
    TsStatusView v;
    char err[256];
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1; plan.schema_minor = 0;
    plan.task_count = 2;
    plan.tasks = (TsTask *)ts_calloc(2, sizeof(TsTask));
    set_task(&plan.tasks[0], "X", "任务X", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[0], "Y");
    set_task(&plan.tasks[1], "Y", "任务Y", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[1], "X");

    memset(&res, 0, sizeof(res));
    rc = ts_schedule_build(&plan, &cfg, &res, err, sizeof(err));
    CHECK(rc != 0, "build_schedule 拒绝循环");
    CHECK(strstr(err, "循环") != NULL, "错误信息含“循环”");
    ts_schedule_result_free(&res);

    memset(&v, 0, sizeof(v));
    rc = ts_schedule_status(&plan, &v, err, sizeof(err));
    CHECK(rc == 0, "status 对循环不崩溃");
    if (rc == 0) {
        CHECK(v.cycle_count == 2, "循环成员数为 2");
        CHECK(v.states[0] == TS_BLOCKED && v.states[1] == TS_BLOCKED, "循环任务标受阻");
    }
    ts_status_view_free(&v);

    ts_plan_free(&plan);
}

static void test_tie_break(void)
{
    printf("== 同分确定性排序（稳定 ID 升序） ==\n");
    TsPlan plan;
    TsConfig cfg = make_cfg();
    TsScheduleResult res;
    char err[256];
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1; plan.schema_minor = 0;
    plan.task_count = 3;
    plan.tasks = (TsTask *)ts_calloc(3, sizeof(TsTask));
    set_task(&plan.tasks[0], "Z9", "任务Z9", 3, 3, 1, 1.0);
    set_task(&plan.tasks[1], "A1", "任务A1", 3, 3, 1, 1.0);
    set_task(&plan.tasks[2], "M5", "任务M5", 3, 3, 1, 1.0);

    memset(&res, 0, sizeof(res));
    rc = ts_schedule_build(&plan, &cfg, &res, err, sizeof(err));
    CHECK(rc == 0, "tie-break build 成功");
    if (rc == 0 && res.step_count == 3) {
        CHECK(strcmp(id_at(&plan, res.steps[0].task_index), "A1") == 0, "同分优先 A1");
        CHECK(strcmp(id_at(&plan, res.steps[1].task_index), "M5") == 0, "其次 M5");
        CHECK(strcmp(id_at(&plan, res.steps[2].task_index), "Z9") == 0, "最后 Z9");
    }
    ts_schedule_result_free(&res);
    ts_plan_free(&plan);
}

/* 展示的等式必须自洽：FinalScore = BaseScore + 10C + 7R + 3W，且各分项在合法区间内。 */
static void check_score_equations(const TsScheduleResult *sr, const char *what)
{
    size_t i;
    int bad = 0;
    for (i = 0; i < sr->step_count; i++) {
        const TsScoreBreakdown *s = &sr->steps[i].score;
        double expect = s->base + 10.0 * s->c + 7.0 * s->r + 3.0 * s->w;
        if (fabs(expect - s->final) > 1e-9) bad = 1;
        if (s->base < 0.0 || s->base > 100.0) bad = 1;
        if (s->c < 0.0 || s->c > 1.0 || s->r < 0.0 || s->r > 1.0 ||
            s->w < 0.0 || s->w > 1.0) bad = 1;
        if (s->final < 0.0) bad = 1;
        if (sr->steps[i].reason == NULL) bad = 1;
    }
    CHECK(!bad, what);
}

/*
 * 已完成任务不得污染剩余关键链（审查报告 P2）。
 * A(1h) 的后继 B(100h) 已完成；独立任务 Z(2h)。
 * 剩余工时只有 A=1h 与 Z=2h，因此 C(A)=1/2=0.5。
 * 若把已完成的 B 的 100h 计入，C(A) 会变成 101/101=1.0。
 */
static void test_critical_chain_excludes_done(void)
{
    printf("== 关键链排除已完成任务 ==\n");
    TsPlan plan;
    TsConfig cfg = make_cfg();
    TsScheduleResult res;
    char err[256];
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1; plan.schema_minor = 0;
    plan.task_count = 3;
    plan.tasks = (TsTask *)ts_calloc(3, sizeof(TsTask));

    set_task(&plan.tasks[0], "A", "待做", 3, 3, 1, 1.0);
    set_task(&plan.tasks[1], "B", "已完成的大任务", 3, 3, 1, 100.0);
    add_dep(&plan.tasks[1], "A");
    plan.tasks[1].actual_status = TS_ACTUAL_DONE;      /* 已完成：其 100h 不应计入剩余链 */
    set_task(&plan.tasks[2], "Z", "独立的短任务", 3, 3, 1, 2.0);

    memset(&res, 0, sizeof(res));
    rc = ts_schedule_build(&plan, &cfg, &res, err, sizeof(err));
    CHECK(rc == 0, "build 成功");
    if (rc == 0 && res.step_count > 0) {
        CHECK(res.step_count == 2, "已完成任务不进入建议顺序（只剩 A、Z）");
        CHECK(res.steps[0].candidate_count == 2, "第 1 步候选为 A、Z");
        CHECK(fabs(res.steps[0].score.c - 0.5) < 1e-9,
              "C(A)=0.5（剩余 1h / 最大 2h）；若计入已完成的 100h 会是 1.0");
        CHECK(res.steps[0].score.chain_incomplete == 0, "工时均已知，关键链完整");
        check_score_equations(&res, "每一步的得分等式自洽");
        CHECK(strstr(res.steps[0].reason, "×U") != NULL &&
              strstr(res.steps[0].reason, "10×C") != NULL,
              "理由中显示实际权重与 10×C/7×R/3×W");
    }
    ts_schedule_result_free(&res);
    ts_plan_free(&plan);
}

/* 后代必须去重：R 经两条路径到达 L，L 只能计一次。 */
static void test_descendant_dedup(void)
{
    printf("== 后代去重（阻塞性 B） ==\n");
    TsPlan plan;
    TsConfig cfg = make_cfg();
    TsScheduleResult res;
    char err[256];
    int rc;

    ts_plan_init(&plan);
    plan.schema_major = 1; plan.schema_minor = 0;
    plan.task_count = 9;
    plan.tasks = (TsTask *)ts_calloc(9, sizeof(TsTask));

    /* R 的后代：M1、M2、L（3 个去重）；L 有两条路径可达 */
    set_task(&plan.tasks[0], "R", "根任务", 5, 3, 1, 2.0);
    set_task(&plan.tasks[1], "M1", "中间1", 3, 3, 1, 2.0); add_dep(&plan.tasks[1], "R");
    set_task(&plan.tasks[2], "M2", "中间2", 3, 3, 1, 2.0); add_dep(&plan.tasks[2], "R");
    set_task(&plan.tasks[3], "L", "汇合", 3, 3, 1, 2.0);
    add_dep(&plan.tasks[3], "M1"); add_dep(&plan.tasks[3], "M2");

    /* S 的后代：A、B、C、D（4 个） */
    set_task(&plan.tasks[4], "S", "另一根", 2, 3, 1, 2.0);
    set_task(&plan.tasks[5], "A", "A", 3, 3, 1, 2.0); add_dep(&plan.tasks[5], "S");
    set_task(&plan.tasks[6], "B", "B", 3, 3, 1, 2.0); add_dep(&plan.tasks[6], "S");
    set_task(&plan.tasks[7], "C", "C", 3, 3, 1, 2.0); add_dep(&plan.tasks[7], "S");
    set_task(&plan.tasks[8], "D", "D", 3, 3, 1, 2.0);
    add_dep(&plan.tasks[8], "A"); add_dep(&plan.tasks[8], "B");

    memset(&res, 0, sizeof(res));
    rc = ts_schedule_build(&plan, &cfg, &res, err, sizeof(err));
    CHECK(rc == 0, "dedup build 成功");
    if (rc == 0 && res.step_count > 0) {
        CHECK(strcmp(res.steps[0].task_id, "R") == 0, "R 因紧迫性更高而先被选中");
        CHECK(res.steps[0].candidate_count == 2, "第 1 步有 2 个候选（R、S）");
        CHECK(fabs(res.steps[0].score.b - 0.75) < 1e-9,
              "B(R)=0.75 = 3 个去重后代 / 最大值 4（未去重会是 1.0）");
    }
    ts_schedule_result_free(&res);
    ts_plan_free(&plan);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 阶段3 测试（调度算法） ===\n\n");
    test_build_schedule();
    test_status();
    test_cycle();
    test_tie_break();
    test_descendant_dedup();
    test_critical_chain_excludes_done();
    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

