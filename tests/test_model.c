/*
 * test_model.c — 响应外壳解析、错误分类与限流重试策略的**离线**回归测试。
 *
 * 覆盖此前校核报告的三项发现：
 *   #2 模型必需字段缺失被当作空值（解析层，见 test_plan.c）
 *   #3 取消后仍可能接纳成功结果（取消是终态；本文件覆盖“取消标志”的语义，
 *      端到端的取消/迟到结果窗口由 test_http_integration.c 用本地服务验证）
 *   #8 限流重试忽略 Retry-After
 *
 * 本文件使用**真实 cJSON**（随源码一起编译），不需要网络。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../src/domain/analysis/model.h"
#include "../src/platform/runtime.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; }                                      \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

#define CHECK_STR(actual, expect, msg) do {                      \
    const char *_a = (actual);                                   \
    if (_a != NULL && strcmp(_a, (expect)) == 0) { g_pass++; }   \
    else {                                                       \
        printf("  [FAIL] %s\n         期望：%s\n         实际：%s\n", \
               msg, (expect), _a != NULL ? _a : "(null)");       \
        g_fail++;                                                \
    }                                                            \
} while (0)

/* ------------------------------------------------------------------ */
/* 1. 响应外壳解析                                                     */
/* ------------------------------------------------------------------ */

static void test_extract(void)
{
    char err[512];
    char *content = NULL;
    size_t len = 0;
    int kind = -1;

    printf("== 响应外壳解析 ==\n");

    /* 正常响应 */
    {
        const char *body =
            "{\"choices\":[{\"message\":{\"role\":\"assistant\","
            "\"content\":\"{\\\"schema_version\\\":\\\"1.0\\\"}\"},"
            "\"finish_reason\":\"stop\"}]}";
        content = NULL; len = 0; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) == 0,
              "正常响应解析成功");
        CHECK_STR(content, "{\"schema_version\":\"1.0\"}", "正文被原样取出");
        CHECK(len == strlen("{\"schema_version\":\"1.0\"}"), "正文长度正确");
        CHECK(kind == TS_MODEL_OK, "分类为成功");
        free(content);
    }

    /* 空正文（response_len = 0） */
    {
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content("", 0, &content, &len, &kind, err, sizeof(err)) != 0,
              "零长度响应被拒绝");
        CHECK(kind == TS_MODEL_ERR_EMPTY, "零长度响应分类为“正文为空”");
    }

    /* content 为 null */
    {
        const char *body = "{\"choices\":[{\"message\":{\"content\":null}}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "content=null 被拒绝");
        CHECK(kind == TS_MODEL_ERR_EMPTY, "content=null 分类为“正文为空”");
    }

    /* content 为空串 */
    {
        const char *body = "{\"choices\":[{\"message\":{\"content\":\"\"}}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "content=\"\" 被拒绝");
        CHECK(kind == TS_MODEL_ERR_EMPTY, "空串分类为“正文为空”");
    }

    /* 非法 JSON */
    {
        const char *body = "{\"choices\":[";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "非法 JSON 被拒绝");
        CHECK(kind == TS_MODEL_ERR_PROTOCOL, "非法 JSON 分类为“协议错误”");
        CHECK(strstr(err, "合法 JSON") != NULL, "错误信息说明 JSON 不合法");
    }

    /* 缺少 choices */
    {
        const char *body = "{\"id\":\"x\"}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "缺少 choices 被拒绝");
        CHECK(strstr(err, "choices") != NULL, "错误信息指出缺少 choices");
    }

    /* choices 为空数组 */
    {
        const char *body = "{\"choices\":[]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "choices 空数组被拒绝");
    }

    /* choices[0] 不是对象 */
    {
        const char *body = "{\"choices\":[\"nope\"]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "choices[0] 非对象被拒绝");
    }

    /* 缺少 message */
    {
        const char *body = "{\"choices\":[{\"finish_reason\":\"stop\"}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "缺少 message 被拒绝");
        CHECK(strstr(err, "message") != NULL, "错误信息指出缺少 message");
    }

    /* content 不是字符串 */
    {
        const char *body = "{\"choices\":[{\"message\":{\"content\":42}}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "content 非字符串被拒绝");
        CHECK(strstr(err, "字符串") != NULL, "错误信息指出类型不对");
    }

    /* finish_reason = length（输出被截断）：不能当成成功 */
    {
        const char *body =
            "{\"choices\":[{\"message\":{\"content\":\"{\\\"tasks\\\":[]}\"},"
            "\"finish_reason\":\"length\"}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) != 0,
              "finish_reason=length 被拒绝（不当作成功）");
        CHECK(kind == TS_MODEL_ERR_TRUNCATED, "分类为“输出被截断”");
        CHECK(content == NULL, "截断时不返回正文（避免上层误用半截 JSON）");
        CHECK(strstr(err, "截断") != NULL, "错误信息说明被截断");
    }

    /* finish_reason = stop 时正常放行 */
    {
        const char *body =
            "{\"choices\":[{\"message\":{\"content\":\"ok\"},"
            "\"finish_reason\":\"stop\"}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) == 0,
              "finish_reason=stop 正常放行");
        free(content);
    }

    /* 出参为 NULL：必须被拒绝而不是崩溃（校核修复项） */
    {
        const char *body = "{\"choices\":[{\"message\":{\"content\":\"x\"}}]}";
        err[0] = '\0';
        kind = -1;
        CHECK(ts_model_extract_content(body, strlen(body), NULL, &len, &kind,
                                       err, sizeof(err)) != 0,
              "out_content 为 NULL 时安全返回错误（不解引用空指针）");
        CHECK(kind == TS_MODEL_ERR_CONFIG, "out_content 为 NULL 分类为内部调用错误");
    }

    /* 正文里的 Unicode 中文应完整保留 */
    {
        const char *body =
            "{\"choices\":[{\"message\":{\"content\":\"\\u4efb\\u52a1\"}}]}";
        content = NULL; kind = -1; err[0] = '\0';
        CHECK(ts_model_extract_content(body, strlen(body), &content, &len, &kind,
                                       err, sizeof(err)) == 0,
              "含 \\u 转义的响应可解析");
        CHECK_STR(content, "任务", "\\u 转义被解码为 UTF-8 中文");
        free(content);
    }
}

/* ------------------------------------------------------------------ */
/* 2. Retry-After 解析（修复 8）                                        */
/* ------------------------------------------------------------------ */

static void test_retry_after(void)
{
    printf("== Retry-After 解析（修复 8）==\n");

    CHECK(ts_model_parse_retry_after("Retry-After: 5\r\n", 16) == 5000,
          "标准小写值 \"Retry-After: 5\" -> 5000ms");
    CHECK(ts_model_parse_retry_after("retry-after: 5\r\n", 16) == 5000,
          "头部名大小写不敏感");
    CHECK(ts_model_parse_retry_after("RETRY-AFTER:5\r\n", 15) == 5000,
          "全大写且无空格可解析");
    CHECK(ts_model_parse_retry_after("Retry-After:   12\r\n", 19) == 12000,
          "冒号后多个空格可解析");
    CHECK(ts_model_parse_retry_after("Retry-After:\t7\r\n", 16) == 7000,
          "制表符分隔可解析");
    CHECK(ts_model_parse_retry_after("Retry-After: 3600\r\n", 19) == 3600000,
          "上界 3600 秒被接受");
    CHECK(ts_model_parse_retry_after("Retry-After: 3601\r\n", 19) == 0,
          "超出 3600 秒被拒绝（退回默认退避）");
    CHECK(ts_model_parse_retry_after("Retry-After: 0\r\n", 16) == 0,
          "0 秒被拒绝（不作为“立即重试”信号）");
    CHECK(ts_model_parse_retry_after("Retry-After: -5\r\n", 17) == 0,
          "负数被拒绝");
    CHECK(ts_model_parse_retry_after("Retry-After: abc\r\n", 18) == 0,
          "非数字被拒绝");
    CHECK(ts_model_parse_retry_after("Retry-After: \r\n", 15) == 0,
          "空值被拒绝");
    CHECK(ts_model_parse_retry_after(
              "Retry-After: Wed, 21 Oct 2015 07:28:00 GMT\r\n", 42) == 0,
          "HTTP-date 形式被拒绝（不把绝对时间误当秒数）");
    CHECK(ts_model_parse_retry_after("Re\r\n", 4) == 0, "截断的头部名被拒绝");
    CHECK(ts_model_parse_retry_after("Retry-After 5\r\n", 16) == 0,
          "缺少冒号被拒绝");
    CHECK(ts_model_parse_retry_after("X-Retry-After: 5\r\n", 18) == 0,
          "前缀不匹配的头部被拒绝");
    CHECK(ts_model_parse_retry_after("Retry-After: 5x\r\n", 17) == 0,
          "数字后跟垃圾字符被拒绝");
    CHECK(ts_model_parse_retry_after(NULL, 0) == 0, "NULL 安全");
    CHECK(ts_model_parse_retry_after("", 0) == 0, "零长度安全");
    /* 超长数字不应溢出成正数 */
    CHECK(ts_model_parse_retry_after(
              "Retry-After: 99999999999999999999\r\n", 32) == 0,
          "超长数字因溢出保护被拒绝");
}

/* ------------------------------------------------------------------ */
/* 3. 可重试状态码（修复 8）                                            */
/* ------------------------------------------------------------------ */

static void test_status_retryable(void)
{
    printf("== 可重试状态码 ==\n");

    CHECK(ts_model_http_status_retryable(429) == 1, "429 可重试");
    CHECK(ts_model_http_status_retryable(500) == 1, "500 可重试");
    CHECK(ts_model_http_status_retryable(502) == 1, "502 可重试");
    CHECK(ts_model_http_status_retryable(503) == 1, "503 可重试");
    CHECK(ts_model_http_status_retryable(504) == 1, "504 可重试");
    CHECK(ts_model_http_status_retryable(501) == 0, "501 不可重试（非幂等语义）");
    CHECK(ts_model_http_status_retryable(505) == 0, "505 不可重试");
    CHECK(ts_model_http_status_retryable(400) == 0, "400 不可重试");
    CHECK(ts_model_http_status_retryable(401) == 0, "401 不可重试（鉴权）");
    CHECK(ts_model_http_status_retryable(403) == 0, "403 不可重试（鉴权）");
    CHECK(ts_model_http_status_retryable(404) == 0, "404 不可重试");
    CHECK(ts_model_http_status_retryable(422) == 0, "422 不可重试");
    CHECK(ts_model_http_status_retryable(200) == 0, "200 不属于可重试错误");
    CHECK(ts_model_http_status_retryable(0) == 0, "0（无响应）不属于可重试错误");
}

/* ------------------------------------------------------------------ */
/* 4. 取消是终态（修复 3 的基础语义）                                   */
/* ------------------------------------------------------------------ */

static void test_cancel_semantics(void)
{
    TsCancel c;
    int gen;

    printf("== 取消状态语义 ==\n");

    ts_cancel_init(&c);
    gen = ts_cancel_begin(&c);
    CHECK(gen > 0, "begin 返回递增的请求代号");
    CHECK(ts_cancel_should_stop(&c, gen) == 0, "新请求未被取消");

    ts_cancel_request(&c);
    CHECK(ts_cancel_is_requested(&c) == 1, "取消标志被置位");
    CHECK(ts_cancel_should_stop(&c, gen) == 1,
          "取消后 should_stop 立即为真（不依赖代号变化）");

    /*
     * 关键点：取消后即使拿到完整结果也必须丢弃——因此需要一个“只看取消标志”的
     * 判定（ts_cancel_is_requested），而不是只看代号。
     */
    CHECK(ts_cancel_is_requested(&c) == 1,
          "取消后 ts_cancel_is_requested 为真：结果不得被采纳");

    gen = ts_cancel_begin(&c);
    CHECK(ts_cancel_is_requested(&c) == 0, "新一代请求清除取消标志");
    CHECK(ts_cancel_should_stop(&c, gen) == 0, "新请求可正常进行");

    /* 旧代号必须被判定为“应停止”（用于丢弃迟到结果） */
    CHECK(ts_cancel_should_stop(&c, gen - 1) == 1,
          "旧代号的迟到结果被判定为应丢弃");

    CHECK(ts_cancel_should_stop(NULL, 1) == 0, "NULL 取消对象安全");
    CHECK(ts_cancel_is_requested(NULL) == 0, "NULL 取消对象安全");
    CHECK(ts_cancel_gen(NULL) == 0, "NULL 代号安全");
}

/* ------------------------------------------------------------------ */

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 模型层测试（真实 cJSON，离线）===\n\n");

    test_extract();
    test_retry_after();
    test_status_retryable();
    test_cancel_semantics();

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

