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
    CHECK(contains(out, "\"schemaVersion\":1"), "输出应带 schemaVersion 1");
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
    test_missing_proposals_is_empty_not_error();
    test_notes_objects_compat();
    test_broken_json_rejected();

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

