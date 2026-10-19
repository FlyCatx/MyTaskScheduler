/*
 * test_auth_offline.c — 鉴权相关的**离线**单元测试（不需要网络、不需要真实密钥）。
 *
 * 覆盖本轮针对“HTTP 401 Authentication Fails(governor)”排查引入的能力：
 *
 *   A. 配置加载
 *      A1. api_key_env 指向不存在的环境变量 → api_key 为 NULL（不静默当成“无需鉴权”）；
 *      A2. 实际加载的配置路径被记录下来（多份 config.json 并存时可确认读了哪一份）。
 *
 *   B. 是否需要鉴权的判定（兼容无鉴权本地服务）
 *      B1. 配置里没有 api_key_env 字段        → 不要求鉴权；
 *      B2. api_key_env 显式写成空字符串        → 不要求鉴权（显式声明）；
 *      B3. api_key_env 写了变量名              → 要求鉴权。
 *
 *   C. 密钥格式检查（只检测，绝不修改密钥内容，也绝不回显密钥）
 *      C1. 正常密钥无告警；
 *      C2. 首尾空白、控制字符、成对引号各给出明确说明。
 *
 *   D. 诊断输出脱敏与端点摘要
 *      D1. 端点摘要丢弃 userinfo 与查询串（不泄露 ?api_key=...）；
 *      D2. Authorization / Bearer / 敏感 JSON 字段值被替换；
 *      D3. HTTP 状态码与普通错误描述被保留（诊断仍然有用）。
 *
 * 本文件全程使用**虚构**值，不读取也不使用任何真实密钥；
 * 断言输出中不会出现被测试的假密钥原文。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../src/state/config.h"
#include "../src/util/mem.h"
#include "../src/domain/analysis/model.h"
#include "../src/platform/text.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                        \
    if (cond) { g_pass++; printf("  [PASS] %s\n", msg); }            \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }                 \
} while (0)

/*
 * 输出是否包含某个子串。
 * 只用于“断言不包含密钥”，因此调用方传入的是本文件自己构造的假密钥；
 * 真正的密钥永远不会进入本测试。
 */
static int contains(const char *hay, const char *needle)
{
    return (hay != NULL && needle != NULL && strstr(hay, needle) != NULL);
}

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    if (f != NULL) {
        fwrite(text, 1, strlen(text), f);
        fclose(f);
    }
}

/* ------------------------------------------------------------------ */
/* A. 配置加载                                                        */
/* ------------------------------------------------------------------ */

static void test_config_load(const char *workdir)
{
    char path[1024];
    char err[1024];
    TsConfig cfg;

    printf("== A. 配置加载 ==\n");

    /*
     * 使用一个**几乎不可能存在**的环境变量名，验证“取不到密钥”时
     * api_key 保持 NULL，而不是被替换成环境变量名或空串。
     */
    _putenv_s("TS_AUTH_OFFLINE_ABSENT_VAR", "");

    snprintf(path, sizeof(path), "%s\\ts_auth_offline_cfg.json", workdir);
    write_file(path,
               "{\n"
               "  \"endpoint_url\": \"https://api.example.invalid/chat/completions\",\n"
               "  \"model\": \"ts-auth-offline-model\",\n"
               "  \"api_key_env\": \"TS_AUTH_OFFLINE_ABSENT_VAR\",\n"
               "  \"ca_bundle_path\": \"cacert.pem\",\n"
               "  \"connect_timeout_ms\": 5000,\n"
               "  \"wait_prompt_ms\": 120000,\n"
               "  \"request_timeout_ms\": 0,\n"
               "  \"max_output_tokens\": 1000,\n"
               "  \"max_input_bytes\": 262144,\n"
               "  \"max_response_bytes\": 2097152,\n"
               "  \"json_mode\": true,\n"
               "  \"temperature\": 0.2,\n"
               "  \"reference_hours\": 2.0,\n"
               "  \"weights\": { \"urgency\": 0.35, \"impact\": 0.30, \"blocking\": 0.20,"
               " \"quick_win\": 0.10, \"depth\": 0.05 },\n"
               "  \"max_tasks\": 200,\n"
               "  \"max_steps_per_task\": 50,\n"
               "  \"max_retry_attempts\": 1,\n"
               "  \"mock_mode\": false\n"
               "}\n");

    err[0] = '\0';
    CHECK(ts_config_load(path, &cfg, err, sizeof(err)) == 0,
          "配置加载成功（密钥缺失不影响加载）");
    CHECK(cfg.api_key == NULL,
          "环境变量不存在时 api_key 保持 NULL（不会把变量名当成密钥）");
    CHECK(cfg.api_key_env != NULL &&
          strcmp(cfg.api_key_env, "TS_AUTH_OFFLINE_ABSENT_VAR") == 0,
          "api_key_env 被原样保留（用于错误提示）");
    CHECK(cfg.config_path != NULL && strcmp(cfg.config_path, path) == 0,
          "记录下实际加载的配置文件路径（可确认程序读的是哪一份 config.json）");
    ts_config_free(&cfg);

    /* 环境变量存在时，密钥被正确读入（用虚构值）。 */
    _putenv_s("TS_AUTH_OFFLINE_PRESENT_VAR", "sk-test-offline-fake-value");
    {
        char path2[1024];
        snprintf(path2, sizeof(path2), "%s\\ts_auth_offline_cfg2.json", workdir);
        write_file(path2,
                   "{\n"
                   "  \"endpoint_url\": \"https://api.example.invalid/chat/completions\",\n"
                   "  \"model\": \"ts-auth-offline-model\",\n"
                   "  \"api_key_env\": \"TS_AUTH_OFFLINE_PRESENT_VAR\",\n"
                   "  \"connect_timeout_ms\": 5000,\n"
                   "  \"wait_prompt_ms\": 120000,\n"
                   "  \"request_timeout_ms\": 0,\n"
                   "  \"max_output_tokens\": 1000,\n"
                   "  \"max_input_bytes\": 262144,\n"
                   "  \"max_response_bytes\": 2097152,\n"
                   "  \"json_mode\": true,\n"
                   "  \"temperature\": 0.2,\n"
                   "  \"reference_hours\": 2.0,\n"
                   "  \"weights\": { \"urgency\": 0.35, \"impact\": 0.30, \"blocking\": 0.20,"
                   " \"quick_win\": 0.10, \"depth\": 0.05 },\n"
                   "  \"max_tasks\": 200,\n"
                   "  \"max_steps_per_task\": 50,\n"
                   "  \"max_retry_attempts\": 1,\n"
                   "  \"mock_mode\": false\n"
                   "}\n");
        err[0] = '\0';
        CHECK(ts_config_load(path2, &cfg, err, sizeof(err)) == 0, "带密钥的配置加载成功");
        CHECK(cfg.api_key != NULL && strcmp(cfg.api_key, "sk-test-offline-fake-value") == 0,
              "环境变量存在时密钥被原样读入（不做任何改写）");
        ts_config_free(&cfg);
        DeleteFileA(path2);
    }
    _putenv_s("TS_AUTH_OFFLINE_PRESENT_VAR", "");

    DeleteFileA(path);
}

/* ------------------------------------------------------------------ */
/* B. 是否需要鉴权                                                     */
/* ------------------------------------------------------------------ */

static void test_requires_auth(void)
{
    TsConfig cfg;

    printf("\n== B. 是否需要鉴权 ==\n");

    ts_config_init(&cfg);
    cfg.api_key_env = NULL;
    CHECK(ts_config_requires_auth(&cfg) == 0,
          "未配置 api_key_env：不要求鉴权（无鉴权本地服务可用）");

    ts_free(cfg.api_key_env);
    cfg.api_key_env = ts_strdup("");
    CHECK(ts_config_requires_auth(&cfg) == 0,
          "api_key_env 显式为空串：视为显式声明“无需鉴权”");

    ts_free(cfg.api_key_env);
    cfg.api_key_env = ts_strdup("SOME_KEY_ENV");
    CHECK(ts_config_requires_auth(&cfg) == 1,
          "api_key_env 写了变量名：明确要求鉴权（缺失即报错，不静默放行）");

    ts_config_free(&cfg);
    ts_config_init(&cfg);
    ts_config_free(&cfg);
}

/* ------------------------------------------------------------------ */
/* C. 密钥格式检查                                                     */
/* ------------------------------------------------------------------ */

static void test_key_format(void)
{
    printf("\n== C. 密钥格式检查（只检测，不修改、不回显）==\n");

    CHECK(ts_config_api_key_format_error("sk-abcdef0123456789") == NULL,
          "正常密钥：没有格式告警");
    CHECK(ts_config_api_key_format_error("") != NULL,
          "空密钥：报告为空");
    CHECK(ts_config_api_key_format_error(NULL) != NULL,
          "NULL 密钥：报告为空");
    CHECK(ts_config_api_key_format_error(" sk-abcdef") != NULL,
          "前导空白：报告为可疑");
    CHECK(ts_config_api_key_format_error("sk-abcdef ") != NULL,
          "尾随空白：报告为可疑");
    CHECK(ts_config_api_key_format_error("sk-abc\tdef") != NULL,
          "中间制表符（控制字符）：报告为可疑");
    CHECK(ts_config_api_key_format_error("\"sk-abcdef\"") != NULL,
          "被一对双引号包住：报告为可疑");
    CHECK(ts_config_api_key_format_error("'sk-abcdef'") != NULL,
          "被一对单引号包住：报告为可疑");

    /* 说明文字本身绝不能包含被检查的密钥内容。 */
    {
        const char *m = ts_config_api_key_format_error(" sk-secret-probe-xyz ");
        CHECK(m != NULL && !contains(m, "secret-probe-xyz"),
              "格式问题的说明文字不回显密钥内容");
    }
}

/* ------------------------------------------------------------------ */
/* D. 诊断脱敏与端点摘要                                                */
/* ------------------------------------------------------------------ */

static void test_endpoint_sanitize(void)
{
    char buf[512];

    printf("\n== D1. 端点摘要 ==\n");

    CHECK(strcmp(ts_model_sanitize_endpoint(
                     "https://api.deepseek.com/chat/completions", buf, sizeof(buf)),
                 "api.deepseek.com/chat/completions") == 0,
          "普通 HTTPS 端点：保留 主机 + 路径");

    CHECK(strcmp(ts_model_sanitize_endpoint(
                     "https://user:pass@api.example.com/v1/chat/completions?api_key=leak",
                     buf, sizeof(buf)),
                 "api.example.com/v1/chat/completions") == 0,
          "丢弃 userinfo 与查询串（?api_key=... 不会泄露）");

    CHECK(!contains(ts_model_sanitize_endpoint(
                        "https://user:pass@api.example.com/v1/x?api_key=leak",
                        buf, sizeof(buf)),
                    "pass"),
          "用户口令不出现在端点摘要里");

    CHECK(strcmp(ts_model_sanitize_endpoint(NULL, buf, sizeof(buf)), "") == 0,
          "NULL 端点安全返回空串");
    CHECK(strcmp(ts_model_sanitize_endpoint("", buf, sizeof(buf)), "") == 0,
          "空端点安全返回空串");
}

static void test_diag_redact(void)
{
    char buf[1024];

    printf("\n== D2/D3. 诊断文本脱敏 ==\n");

    /* Authorization 头整体替换 */
    {
        strcpy(buf, "sent Authorization: Bearer sk-live-abcdefghijklmnop to server");
        ts_model_diag_redact(buf);
        CHECK(!contains(buf, "sk-live-abcdefghijklmnop") && !contains(buf, "Bearer sk-"),
              "Authorization/Bearer 之后的凭证被替换");
        CHECK(contains(buf, "sent") && contains(buf, "to server"),
              "无关文字被保留（诊断仍然可读）");
    }

    /* 服务端返回体里的敏感字段 */
    {
        strcpy(buf, "{\"error\":{\"message\":\"bad key\",\"api_key\":\"sk-leak-1234567890\"}}");
        ts_model_diag_redact(buf);
        CHECK(!contains(buf, "sk-leak-1234567890"), "响应体里的 api_key 值被替换");
        CHECK(contains(buf, "bad key"), "普通错误描述被保留");
    }

    /* HTTP 状态码与请求 ID 必须保留 */
    {
        strcpy(buf, "服务端返回 HTTP 401：Authentication Fails(governor) request_id=abc-123");
        ts_model_diag_redact(buf);
        CHECK(contains(buf, "HTTP 401") && contains(buf, "Authentication Fails(governor)"),
              "HTTP 状态码与服务端原文（无敏感内容时）被保留");
        CHECK(contains(buf, "request_id=abc-123"),
              "可用于排查的请求 ID 被保留");
    }

    /* 很长的裸 token */
    {
        strcpy(buf, "key=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789");
        ts_model_diag_redact(buf);
        CHECK(!contains(buf, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
              "超长裸 token 被替换");
    }

    /* 安全边界 */
    {
        char *p = ts_strdup("");
        ts_model_diag_redact(p);
        CHECK(p != NULL && p[0] == '\0', "空串安全");
        ts_free(p);
        ts_model_diag_redact(NULL);
        CHECK(1, "NULL 安全不崩溃");
    }
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    const char *workdir;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 鉴权（离线）测试 ===\n\n");

    if (argc < 2) {
        workdir = ".";
    } else {
        workdir = argv[1];
    }

    test_config_load(workdir);
    test_requires_auth();
    test_key_format();
    test_endpoint_sanitize();
    test_diag_redact();

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

