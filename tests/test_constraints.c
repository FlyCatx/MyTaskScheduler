/*
 * test_constraints.c — 日历约束识别的结果校验器（src/constraints.c）。
 *
 * 这一层是"模型返回的提案"与"界面能勾选的数据"之间唯一的关口，所以必须离线可测：
 *   - 合法提案被规范化（只保留已知字段，多写的字段不传出去）；
 *   - 未知 kind / 非法时段 / 缺 evidence / 没有时段也没有时长 → 报错（触发一次修复），
 *     绝不允许"降级成全部可用"；
 *   - 全天不可用的日期例外没有时段也是合法的；
 *   - notes 既支持字符串数组，也兼容 [{text: "..."}]。
 *
 * 不联网：只调用校验器，不发起请求。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/domain/analysis/constraints.h"
#include "../src/domain/analysis/prompt.h"
#include "../src/util/mem.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

static int contains(const char *hay, const char *needle)
{
    return (hay != NULL) && (strstr(hay, needle) != NULL);
}

/* 对一段模型正文执行校验；成功时返回规范化 JSON（调用方 free），失败返回 NULL。 */
static char *validate(const char *body, char *err, size_t err_sz)
{
    char *out = NULL;
    if (ts_constraints_validate(body, strlen(body), &out, err, err_sz) != 0) {
        return NULL;
    }
    return out;
}

static const char *VALID_BODY =
    "{"
    "  \"schemaVersion\": 1,"
    "  \"summary\": \"识别到上课与一个不可用日期\","
    "  \"proposals\": ["
    "    { \"kind\": \"occupancy\", \"title\": \"上课\", \"occupancyKind\": \"course\","
    "      \"weekdays\": [2, 4], \"date\": null, \"closed\": false,"
    "      \"ranges\": [{ \"start\": 480, \"end\": 600 }],"
    "      \"durationMinutes\": null, \"evidence\": \"每周二和周四08-10上课\","
    "      \"source\": \"材料1:第1段\", \"needsTime\": false, \"question\": null },"
    "    { \"kind\": \"exception\", \"title\": \"全天不可用\", \"occupancyKind\": null,"
    "      \"weekdays\": [], \"date\": \"2026-10-22\", \"closed\": true,"
    "      \"ranges\": [], \"durationMinutes\": null, \"evidence\": \"2026-10-22全天不可用\","
    "      \"source\": \"材料1:第1段\", \"needsTime\": false, \"question\": null }"
    "  ],"
    "  \"notes\": [\"中午和晚上各吃饭30分钟：只给了时长\"]"
    "}";

static void test_valid_payload(void)
{
    char err[512];
    char *out;
    printf("valid payload\n");
    err[0] = '\0';
    out = validate(VALID_BODY, err, sizeof(err));
    CHECK(out != NULL, "合法提案应通过校验");
    if (out == NULL) {
        printf("         错误信息：%s\n", err);
        return;
    }
    CHECK(contains(out, "\"schemaVersion\":2"), "输出应带 schemaVersion 2");
    CHECK(contains(out, "\"calendar\":{"), "输出应带 calendar 对象");
    CHECK(contains(out, "\"proposals\":["), "输出应带 proposals 数组");
    CHECK(contains(out, "\"kind\":\"occupancy\""), "应保留 kind");
    CHECK(contains(out, "\"occupancyKind\":\"course\""), "应保留 occupancyKind");
    CHECK(contains(out, "\"graph\":") == 0, "不应透传无关字段");
    CHECK(contains(out, "\"notes\":[\"中午和晚上各吃饭30分钟：只给了时长\"]"),
          "notes 应保留");
    ts_free(out);
}

static void test_unknown_field_is_dropped(void)
{
    char err[512];
    char *out;
    char body[1400];
    printf("unknown field dropped\n");
    snprintf(body, sizeof(body),
             "{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
             "\"occupancyKind\":\"course\",\"weekdays\":[2],\"ranges\":"
             "[{\"start\":480,\"end\":600}],\"evidence\":\"周二8-10上课\","
             "\"source\":\"文件1:第1段\",\"thinking\":\"chain-of-thought\"}],"
             "\"notes\":[]}");
    err[0] = '\0';
    out = validate(body, err, sizeof(err));
    CHECK(out != NULL, "多写字段不应导致失败");
    if (out != NULL) {
        CHECK(contains(out, "chain-of-thought") == 0, "多写的字段不得透传");
        ts_free(out);
    }
}

static void test_unknown_kind_rejected(void)
{
    char err[512];
    char *out;
    printf("unknown kind rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"holiday\",\"evidence\":\"x\"}],"
                   "\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "未知 kind 必须报错");
    if (out != NULL) ts_free(out);
    CHECK(contains(err, "kind"), "错误信息应指出 kind");
}

static void test_missing_evidence_rejected(void)
{
    char err[512];
    char *out;
    printf("missing evidence rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
                   "\"ranges\":[{\"start\":480,\"end\":600}]}],\"notes\":[]}",
                   err, sizeof(err));
    CHECK(out == NULL, "没有 evidence 的提案必须报错");
    if (out != NULL) ts_free(out);
    CHECK(contains(err, "evidence"), "错误信息应指出 evidence");
}

static void test_bad_range_rejected(void)
{
    char err[512];
    char *out;
    printf("bad range rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
                   "\"ranges\":[{\"start\":600,\"end\":480}],"
                   "\"evidence\":\"x\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "结束早于开始的时段必须报错");
    if (out != NULL) ts_free(out);

    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
                   "\"ranges\":[{\"start\":480,\"end\":4000}],"
                   "\"evidence\":\"x\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "超过 2880 分钟的时段必须报错");
    if (out != NULL) ts_free(out);
}

static void test_bad_weekday_rejected(void)
{
    char err[512];
    char *out;
    printf("bad weekday rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
                   "\"weekdays\":[0],\"ranges\":[{\"start\":480,\"end\":600}],"
                   "\"evidence\":\"x\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "星期 0 必须报错");
    if (out != NULL) ts_free(out);
}

static void test_bad_date_rejected(void)
{
    char err[512];
    char *out;
    printf("bad date rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"exception\",\"title\":\"例外\","
                   "\"date\":\"2026-13-40\",\"closed\":true,"
                   "\"evidence\":\"x\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "非法日期必须报错");
    if (out != NULL) ts_free(out);
}

static void test_no_window_no_duration_rejected(void)
{
    char err[512];
    char *out;
    printf("proposal with no window and no duration rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"上课\","
                   "\"ranges\":[],\"evidence\":\"x\"}],\"notes\":[]}",
                   err, sizeof(err));
    CHECK(out == NULL, "既没有时段也没有时长的提案必须报错");
    if (out != NULL) ts_free(out);

    /* 但"只知道时长"是合法的：它会被界面当成待确认项。 */
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"title\":\"午饭\","
                   "\"occupancyKind\":\"rest\",\"ranges\":[],"
                   "\"durationMinutes\":30,\"needsTime\":true,"
                   "\"evidence\":\"各吃饭30分钟\"}],\"notes\":[]}",
                   err, sizeof(err));
    CHECK(out != NULL, "只知道时长（needsTime）应当是合法提案");
    if (out != NULL) {
        CHECK(contains(out, "\"needsTime\":true"), "应保留 needsTime");
        CHECK(contains(out, "\"durationMinutes\":30"), "应保留 durationMinutes");
        ts_free(out);
    }
}

static void test_missing_proposals_is_empty_not_error(void)
{
    char err[512];
    char *out;
    printf("missing proposals is an empty answer, not an error\n");
    err[0] = '\0';
    out = validate("{\"notes\":[\"材料里没有时间约束\"]}", err, sizeof(err));
    CHECK(out != NULL, "没有 proposals 字段不应报错");
    if (out != NULL) {
        CHECK(contains(out, "\"proposals\":[]"), "应规范化为空数组");
        ts_free(out);
    }
}

static void test_notes_objects_compat(void)
{
    char err[512];
    char *out;
    printf("notes accept objects with text\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[],\"notes\":[{\"text\":\"需要补充起点\"}]}",
                   err, sizeof(err));
    CHECK(out != NULL, "notes 对象形式应被接受");
    if (out != NULL) {
        CHECK(contains(out, "需要补充起点"), "notes 文本应保留");
        ts_free(out);
    }
}

static void test_broken_json_rejected(void)
{
    char err[512];
    char *out;
    printf("broken json rejected\n");
    err[0] = '\0';
    out = validate("{not json", err, sizeof(err));
    CHECK(out == NULL, "非法 JSON 必须报错");
    if (out != NULL) ts_free(out);
    CHECK(err[0] != '\0', "应给出可展示的错误原因");
}

static void test_unclear_without_time_is_legal(void)
{
    char err[512];
    char *out;
    printf("unclear without ranges is legal and keeps other proposals\n");
    err[0] = '\0';
    out = validate(
        "{\"schemaVersion\":2,\"proposals\":["
        "{\"kind\":\"unclear\",\"state\":null,\"title\":\"晚间事项\","
        "\"weekdays\":[],\"date\":null,\"closed\":false,\"ranges\":[],"
        "\"durationMinutes\":null,\"evidence\":\"晚上有事，时间未定\","
        "\"source\":{\"sourceId\":\"userRequest\",\"location\":\"第3句\"},"
        "\"needsTime\":true,\"question\":\"具体是哪一天、几点开始和结束？\"},"
        "{\"kind\":\"occupancy\",\"state\":0,\"title\":\"上课\","
        "\"occupancyKind\":\"course\",\"weekdays\":[2],"
        "\"ranges\":[{\"start\":540,\"end\":600}],\"evidence\":\"周二9-10上课\","
        "\"source\":{\"sourceId\":\"file-1\",\"location\":\"第1段\"}}"
        "],\"notes\":[]}",
        err,
        sizeof(err));
    CHECK(out != NULL, "unclear 没有时段不应让整次识别失败");
    if (out != NULL) {
        CHECK(contains(out, "\"kind\":\"unclear\""), "应保留 unclear");
        CHECK(contains(out, "\"kind\":\"occupancy\""), "明确项仍应保留");
        CHECK(contains(out, "\"sourceId\":\"userRequest\""), "source 应结构化输出");
        ts_free(out);
    }

    /* unclear 带 question 才合法；没有 question 必须报错。 */
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"unclear\",\"ranges\":[],"
                   "\"evidence\":\"晚上有事\"}],\"notes\":[]}",
                   err, sizeof(err));
    CHECK(out == NULL, "unclear 缺少 question 必须报错");
    if (out != NULL) ts_free(out);
}

static void test_state_consistency(void)
{
    char err[512];
    char *out;
    printf("state must agree with kind\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"state\":2,"
                   "\"ranges\":[{\"start\":480,\"end\":540}],"
                   "\"evidence\":\"上课\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "occupancy + state=2 必须报错");
    if (out != NULL) ts_free(out);

    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"task\",\"state\":2,"
                   "\"title\":\"写报告\",\"date\":\"2026-10-20\",\"weekdays\":[],"
                   "\"ranges\":[{\"start\":840,\"end\":900}],"
                   "\"taskId\":\"task-report\",\"taskTitleHint\":\"写报告\","
                   "\"evidence\":\"今天14:00-15:00写报告\"}],\"notes\":[]}",
                   err, sizeof(err));
    CHECK(out != NULL, "task/state=2 应通过");
    if (out != NULL) {
        CHECK(contains(out, "\"taskId\":\"task-report\""), "应保留 taskId");
        CHECK(contains(out, "\"state\":2"), "应保留 state");
        ts_free(out);
    }

    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\",\"taskId\":\"T1\","
                   "\"ranges\":[{\"start\":480,\"end\":540}],"
                   "\"evidence\":\"上课\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "非 task 不能带 taskId");
    if (out != NULL) ts_free(out);
}

static void test_fractional_minutes_rejected(void)
{
    char err[512];
    char *out;
    printf("fractional minutes rejected\n");
    err[0] = '\0';
    out = validate("{\"proposals\":[{\"kind\":\"occupancy\","
                   "\"ranges\":[{\"start\":480.5,\"end\":540}],"
                   "\"evidence\":\"上课\"}],\"notes\":[]}", err, sizeof(err));
    CHECK(out == NULL, "非整数分钟必须报错");
    if (out != NULL) ts_free(out);
}

static void test_timetable_block(void)
{
    char *block;
    const char *timetable =
        "{\"schemaVersion\":2,\"revision\":3,\"timezoneId\":\"Asia/Shanghai\","
        "\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-10-19\",\"dateTo\":\"2026-10-20\","
        "\"defaultState\":1},"
        "\"weekly\":[{\"id\":\"w1\",\"state\":0,\"start\":0,\"end\":480,"
        "\"weekdays\":[1,2,3,4,5,6,7],\"origin\":\"default\","
        "\"title\":\"默认不可用\"}],"
        "\"dates\":[{\"id\":\"d1\",\"state\":1,\"start\":540,\"end\":570,"
        "\"date\":\"2026-10-20\",\"weekdays\":[],\"origin\":\"manual\"}]}";
    const char *effective =
        "{\"sourceRevision\":3,\"timezoneId\":\"Asia/Shanghai\","
        "\"timezoneOffsetMinutes\":480,\"dateFrom\":\"2026-10-19\","
        "\"dateTo\":\"2026-10-20\","
        "\"intervalSemantics\":\"[start,end), minutes since local midnight\","
        "\"days\":["
        "{\"date\":\"2026-10-19\",\"intervals\":["
        "{\"start\":0,\"end\":480,\"state\":0,\"meaning\":\"occupied\"},"
        "{\"start\":480,\"end\":1440,\"state\":1,\"meaning\":\"free\"}]},"
        "{\"date\":\"2026-10-20\",\"intervals\":["
        "{\"start\":0,\"end\":480,\"state\":0,\"meaning\":\"occupied\"},"
        "{\"start\":480,\"end\":1440,\"state\":1,\"meaning\":\"free\"}]}]}";

    char payload[8192];
    snprintf(payload, sizeof(payload),
             "{\"timetable\":%s,\"effectiveTimetable\":%s}", timetable,
             effective);

    printf("timetable block is validated, normalized and carries the derived view\n");
    block = ts_constraints_timetable_block(timetable);
    CHECK(block != NULL, "v2 时间表应生成提示词区块");
    if (block != NULL) {
        CHECK(strstr(block, "结构化时间表") != NULL, "区块应有明确标题");
        CHECK(strstr(block, "\"revision\":3") != NULL, "区块应保留修订号");
        CHECK(strstr(block, "\"state\":0") != NULL, "state=0 必须保留，不能当 false");
        ts_free(block);
    }

    block = ts_constraints_timetable_block(payload);
    CHECK(block != NULL, "带派生视图的时间表应生成区块");
    if (block != NULL) {
        CHECK(strstr(block, "effectiveTimetable") != NULL,
              "C 侧必须真正消费 effectiveTimetable，而不是忽略");
        CHECK(strstr(block, "\"sourceRevision\":3") != NULL,
              "派生视图应保留同源修订号");
        ts_free(block);
    }

    /* 同层重叠：两条周规则在同一天重叠必须拒绝，不能让模型猜优先级。 */
    block = ts_constraints_timetable_block(
        "{\"schemaVersion\":2,\"revision\":1,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-10-19\",\"dateTo\":\"2026-10-19\","
        "\"defaultState\":1},\"weekly\":["
        "{\"state\":0,\"start\":0,\"end\":600,\"weekdays\":[1]},"
        "{\"state\":0,\"start\":540,\"end\":700,\"weekdays\":[1]}],\"dates\":[]}");
    CHECK(block == NULL, "同层重叠必须拒绝");
    if (block != NULL) ts_free(block);

    /* 不存在的日期（2 月 30 日）必须拒绝，不能只检查字符串长度。 */
    block = ts_constraints_timetable_block(
        "{\"schemaVersion\":2,\"revision\":1,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-02-30\",\"dateTo\":\"2026-02-30\","
        "\"defaultState\":1},\"weekly\":[],\"dates\":[]}");
    CHECK(block == NULL, "非法日期必须拒绝");
    if (block != NULL) ts_free(block);

    /* 小数分钟不能被 valueint 截断后接受。 */
    block = ts_constraints_timetable_block(
        "{\"schemaVersion\":2,\"revision\":1,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-10-19\",\"dateTo\":\"2026-10-19\","
        "\"defaultState\":1},\"weekly\":[{\"state\":0,\"start\":480.5,"
        "\"end\":540,\"weekdays\":[1]}],\"dates\":[]}");
    CHECK(block == NULL, "小数分钟必须拒绝");
    if (block != NULL) ts_free(block);

    /* 派生视图与权威规则不同源（revision 不同）必须拒绝整份发送。 */
    {
        char mismatch[8192];
        snprintf(mismatch, sizeof(mismatch),
                 "{\"timetable\":%s,\"effectiveTimetable\":"
                 "{\"sourceRevision\":4,\"timezoneId\":\"Asia/Shanghai\","
                 "\"timezoneOffsetMinutes\":480,\"dateFrom\":\"2026-10-19\","
                 "\"dateTo\":\"2026-10-20\",\"days\":[]}}",
                 timetable);
        block = ts_constraints_timetable_block(mismatch);
        CHECK(block == NULL, "派生视图修订号不一致必须拒绝");
        if (block != NULL) ts_free(block);
    }

    /* 派生视图只展开部分日期也必须拒绝：不能把缺天当成完整约束。 */
    {
        char partial[8192];
        snprintf(partial, sizeof(partial),
                 "{\"timetable\":%s,\"effectiveTimetable\":"
                 "{\"sourceRevision\":3,\"timezoneId\":\"Asia/Shanghai\","
                 "\"timezoneOffsetMinutes\":480,\"dateFrom\":\"2026-10-19\","
                 "\"dateTo\":\"2026-10-20\",\"days\":["
                 "{\"date\":\"2026-10-19\",\"intervals\":["
                 "{\"start\":0,\"end\":1440,\"state\":1}]}]}}",
                 timetable);
        block = ts_constraints_timetable_block(partial);
        CHECK(block == NULL, "派生视图缺日期必须拒绝");
        if (block != NULL) ts_free(block);
    }

    /* 闰日 2024-02-29 是合法日期，不能被日期校验误拒。 */
    block = ts_constraints_timetable_block(
        "{\"schemaVersion\":2,\"revision\":1,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2024-02-29\",\"dateTo\":\"2024-02-29\","
        "\"defaultState\":1},\"weekly\":[],\"dates\":[]}");
    CHECK(block != NULL, "闰日 2024-02-29 必须被接受");
    if (block != NULL) ts_free(block);

    /* 2026 不是闰年：2 月 29 日必须拒绝。 */
    block = ts_constraints_timetable_block(
        "{\"schemaVersion\":2,\"revision\":1,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-02-29\",\"dateTo\":\"2026-02-29\","
        "\"defaultState\":1},\"weekly\":[],\"dates\":[]}");
    CHECK(block == NULL, "非闰年的 2 月 29 日必须拒绝");
    if (block != NULL) ts_free(block);

    block = ts_constraints_timetable_block("{\"schemaVersion\":1}");
    CHECK(block == NULL, "v1 时间表必须被拒绝，不能假装兼容");
    if (block != NULL) ts_free(block);
    block = ts_constraints_timetable_block("{not json");
    CHECK(block == NULL, "非法 JSON 必须被拒绝");
    if (block != NULL) ts_free(block);
}

static void test_system_semantics(void)
{
    char *system_prompt;
    printf("timetable semantics live in the trusted system prompt\n");
    system_prompt = ts_prompt_build_system();
    CHECK(system_prompt != NULL, "正式分析 system 提示词应可构建");
    if (system_prompt != NULL) {
        CHECK(strstr(system_prompt, "state=0 表示占用") != NULL,
              "system 提示词应包含 state 语义");
        CHECK(strstr(system_prompt, "半开区间") != NULL,
              "system 提示词应说明半开区间");
        CHECK(strstr(system_prompt, "dates 只覆盖其自身区间") != NULL,
              "system 提示词应说明覆盖顺序");
        ts_free(system_prompt);
    }
    CHECK(strstr(ts_constraints_timetable_semantics(), "不得推定空闲") != NULL,
          "共用语义应说明 coverage 范围外未知");
}

int main(void)
{
    printf("== constraints validation ==\n");
    test_valid_payload();
    test_unknown_field_is_dropped();
    test_unknown_kind_rejected();
    test_missing_evidence_rejected();
    test_bad_range_rejected();
    test_bad_weekday_rejected();
    test_bad_date_rejected();
    test_no_window_no_duration_rejected();
    test_unclear_without_time_is_legal();
    test_state_consistency();
    test_fractional_minutes_rejected();
    test_timetable_block();
    test_system_semantics();
    test_missing_proposals_is_empty_not_error();
    test_notes_objects_compat();
    test_broken_json_rejected();

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
