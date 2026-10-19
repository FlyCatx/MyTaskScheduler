/*
 * test_phase6.c — 阶段 6 控制台测试：TXT 导出内容与失败路径。
 *
 * 只测试不依赖 cJSON 的 TXT 导出（JSON 导出由 cJSON 构造，
 * 在离线环境用 tests/validate_export.py 做静态校验）。
 */

#include "../src/domain/types.h"
#include "../src/state/config.h"
#include "../src/domain/schedule/scheduler.h"
#include "../src/domain/export/export.h"
#include "../src/util/mem.h"
#include "../src/platform/text.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

static int g_fail = 0;

#define CHECK(cond, msg) do {                                   \
    if (cond) { printf("  [PASS] %s\n", msg); }                 \
    else      { printf("  [FAIL] %s\n", msg); g_fail++; }       \
} while (0)

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

static void add_ref(TsTask *t, const char *ref)
{
    char **nv = (char **)ts_realloc(t->source_refs, (t->source_refs_count + 1) * sizeof(char *));
    nv[t->source_refs_count++] = ts_strdup(ref);
    t->source_refs = nv;
}

static int read_all(const char *path, unsigned char **out, size_t *out_len)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    long sz;
    unsigned char *buf;

    *out = NULL;
    *out_len = 0;
    if (wp == NULL) return 0;
    f = _wfopen(wp, L"rb");
    ts_free(wp);
    if (f == NULL) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return 0; }
    rewind(f);
    buf = (unsigned char *)ts_malloc((size_t)sz + 1);
    if (buf == NULL) { fclose(f); return 0; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return 0;
    }
    fclose(f);
    buf[sz] = '\0';
    *out = buf;
    *out_len = (size_t)sz;
    return 1;
}

int main(void)
{
    TsPlan plan;
    TsConfig cfg;
    TsScheduleResult sr;
    TsStatusView sv;
    char err[512];
    int rc;
    unsigned char *raw = NULL;
    size_t raw_len = 0;
    const char *body;
    const char *out_path = "ts_test_p6_out.txt";

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 阶段6 测试（TXT 导出） ===\n\n");

    memset(&cfg, 0, sizeof(cfg));
    cfg.reference_hours = 2.0;
    cfg.w_urgency = 0.35;
    cfg.w_impact = 0.30;
    cfg.w_blocking = 0.20;
    cfg.w_quick_win = 0.10;
    cfg.w_depth = 0.05;
    cfg.max_tasks = 200;
    cfg.max_steps_per_task = 50;

    ts_plan_init(&plan);
    plan.schema_major = 1;
    plan.schema_minor = 0;
    plan.task_count = 4;
    plan.tasks = (TsTask *)ts_calloc(4, sizeof(TsTask));

    set_task(&plan.tasks[0], "T1", "整理需求文档", 3, 4, 1, 2.0);
    add_precond(&plan.tasks[0], "已获得原始材料", TS_PRECOND_MET);
    add_ref(&plan.tasks[0], "文件1:段落1");
    {
        const char *steps1[] = { "通读材料", "列出清单" };
        plan.tasks[0].steps = (char **)ts_calloc(2, sizeof(char *));
        plan.tasks[0].steps[0] = ts_strdup(steps1[0]);
        plan.tasks[0].steps[1] = ts_strdup(steps1[1]);
        plan.tasks[0].steps_count = 2;
    }

    set_task(&plan.tasks[1], "T2", "搭建骨架", 4, 5, 0, 0.0);   /* 工时未知且会排入顺序 */
    add_dep(&plan.tasks[1], "T1");

    set_task(&plan.tasks[2], "T3", "云端联调", 2, 2, 0, 0.0);   /* 工时未知 */
    add_dep(&plan.tasks[2], "T1");
    add_precond(&plan.tasks[2], "已取得 API Key", TS_PRECOND_UNMET);

    set_task(&plan.tasks[3], "T4", "云端验收", 3, 3, 1, 1.0);
    add_dep(&plan.tasks[3], "T3");

    plan.assumptions_count = 1;
    plan.assumptions = (char **)ts_calloc(1, sizeof(char *));
    plan.assumptions[0] = ts_strdup("假设材料已完整");
    plan.questions_count = 1;
    plan.questions = (char **)ts_calloc(1, sizeof(char *));
    plan.questions[0] = ts_strdup("API Key 何时就绪？");

    memset(&sr, 0, sizeof(sr));
    memset(&sv, 0, sizeof(sv));

    rc = ts_schedule_build(&plan, &cfg, &sr, err, sizeof(err));
    CHECK(rc == 0, "生成调度结果成功");
    CHECK(sr.sorted_at[0] != '\0', "调度结果带排序时间");
    rc = ts_schedule_status(&plan, &sv, err, sizeof(err));
    CHECK(rc == 0, "生成状态视图成功");
    CHECK(sr.step_count == 2, "可执行任务为 2 个（T1、T2）");
    CHECK(sr.blocked_count == 1, "受阻任务为 1 个");
    CHECK(sr.affected_count == 1, "受影响任务为 1 个");

    /* ---- 正常导出 ---- */
    rc = ts_export_txt(&plan, &sr, &sv, &cfg, out_path, err, sizeof(err));
    CHECK(rc == 0, "TXT 导出成功");
    CHECK(read_all(out_path, &raw, &raw_len), "读回导出文件");
    if (raw != NULL) {
        CHECK(raw_len > 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF,
              "TXT 带 UTF-8 BOM");
        body = (const char *)(raw + 3);
        CHECK(strstr(body, "建议执行顺序") != NULL, "含“建议执行顺序”");
        CHECK(strstr(body, "第 1 步") != NULL && strstr(body, "T1") != NULL, "第 1 步为 T1");
        CHECK(strstr(body, "第 2 步") != NULL && strstr(body, "T2") != NULL, "第 2 步为 T2");
        CHECK(strstr(body, "第 3 步") == NULL, "受阻任务未混入可执行序列");
        CHECK(strstr(body, "受阻任务（外部条件未满足）") != NULL, "含受阻任务分区");
        CHECK(strstr(body, "已取得 API Key") != NULL, "受阻原因含未满足条件");
        CHECK(strstr(body, "待确认任务（外部条件未知）") != NULL, "含待确认任务分区");
        CHECK(strstr(body, "受影响任务（上游受阻或待确认）") != NULL, "含受影响任务分区");
        CHECK(strstr(body, "T4") != NULL, "受影响任务 T4 已列出");
        CHECK(strstr(body, "执行步骤") != NULL && strstr(body, "通读材料") != NULL, "含执行步骤");
        CHECK(strstr(body, "外部条件") != NULL && strstr(body, "已满足") != NULL, "含外部条件");
        CHECK(strstr(body, "排序理由") != NULL && strstr(body, "最终得分") != NULL, "含排序理由与得分");
        CHECK(strstr(body, "10×C") != NULL, "含可复算的全局加分等式（10×C/7×R/3×W）");
        CHECK(strstr(body, "0.35×U") != NULL, "基础分写明了实际权重（0.35×U）");
        CHECK(strstr(body, "完成后立即解锁") != NULL, "含解锁信息");
        CHECK(strstr(body, "来源引用") != NULL && strstr(body, "文件1:段落1") != NULL, "含来源引用");
        CHECK(strstr(body, "工时未知") != NULL || strstr(body, "预计工时：未知") != NULL,
              "未知工时有明确标注");
        CHECK(strstr(body, "模型的假设") != NULL && strstr(body, "假设材料已完整") != NULL, "含模型假设");
        CHECK(strstr(body, "待确认事项") != NULL && strstr(body, "API Key 何时就绪") != NULL, "含待确认事项");
        CHECK(strstr(body, "算法版本") != NULL, "含算法版本");
        ts_free(raw);
        raw = NULL;
    }

    /* ---- 扩展名推断 ---- */
    CHECK(ts_export_format_from_path("a.json") == TS_EXPORT_JSON, ".json 推断为 JSON");
    CHECK(ts_export_format_from_path("a.JSON") == TS_EXPORT_JSON, ".JSON 大小写不敏感");
    CHECK(ts_export_format_from_path("a.txt") == TS_EXPORT_TXT, ".txt 推断为 TXT");
    CHECK(ts_export_format_from_path("noext") == TS_EXPORT_TXT, "无扩展名默认 TXT");

    /* ---- 失败路径：目录不存在 ---- */
    rc = ts_export_txt(&plan, &sr, &sv, &cfg, "Z:\\__no_such_dir__\\x.txt", err, sizeof(err));
    CHECK(rc != 0, "无效路径导出失败");
    CHECK(err[0] != '\0', "失败时给出错误原因");
    CHECK(plan.task_count == 4, "导出失败后内存中的分析结果保持不变");
    CHECK(sr.step_count == 2, "导出失败后排序结果保持不变");

    /* ---- 空计划 ---- */
    rc = ts_export_txt(NULL, &sr, &sv, &cfg, out_path, err, sizeof(err));
    CHECK(rc != 0, "无结果时导出被拒绝");

    ts_schedule_result_free(&sr);
    ts_status_view_free(&sv);
    ts_plan_free(&plan);
    remove(out_path);

    printf("\n=== 结果：%s（失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_fail);
    return g_fail == 0 ? 0 : 1;
}

