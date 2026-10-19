/*
 * test_http_auth.c — 鉴权行为的**本地 HTTP** 集成测试（真实 libcurl，连本地模拟服务）。
 *
 * 与 test_auth_offline.c 的分工：
 *   - test_auth_offline.c 覆盖配置加载、是否要求鉴权、密钥格式检查、诊断脱敏（纯离线）；
 *   - 本文件覆盖“真的发出请求时”的行为，全部指向 tests/mock_server.py 启动的本地服务。
 *
 * 覆盖本轮排查所要求的验收项：
 *   1. 指定的密钥环境变量不存在 → 请求前明确报错，**不发出**无鉴权的云端请求；
 *   2. 环境变量为空或格式异常     → 清楚提示，且不泄露密钥；
 *   3. 显式未配置 api_key_env     → 无鉴权本地服务仍能正常请求；
 *   4. 正常鉴权                   → 请求包含且只包含**一个**正确的 Authorization 头
 *                                  （用虚构测试密钥验证，输出中不出现真实密钥）；
 *   5. HTTP 401/403               → 不自动重试，保留有效且已脱敏的诊断信息；
 *   6. 回归                       → 正常请求仍可用；取消仍能终止。
 *
 * 用法：ts_test_http_auth <base_url> <workdir> [scenario]
 *
 * 注意：本文件使用的密钥全部是**本文件自己构造的虚构值**，
 * 绝不读取环境里的真实 DEEPSEEK_API_KEY；断言里比较的也是这些虚构值。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#include "../src/domain/analysis/analyze.h"
#include "../src/state/config.h"
#include "../src/domain/input/input.h"
#include "../src/util/mem.h"
#include "../src/domain/analysis/model.h"
#include "../src/platform/runtime.h"
#include "../src/platform/text.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* 测试用虚构密钥（不是真实密钥，长度 32，符合“形如 sk- 的 token”但完全虚构）。 */
static const char *const FAKE_KEY = "sk-tslocaltest0000000000000000000000";

typedef struct Ctx {
    char base_url[256];
    char workdir[512];
    char count_path[640];
    char treq_path[640];
    char control_path[640];
    int  requests_baseline;
    int  fails;
    int  checks;
    TsAnalyzeResult last;
} Ctx;

static void check(Ctx *ctx, int cond, const char *fmt, ...)
{
    va_list ap;
    ctx->checks++;
    if (cond) return;
    ctx->fails++;
    printf("    [FAIL] ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

#define CHECK(ctx, cond, ...) check((ctx), (cond), __VA_ARGS__)

/* ------------------------------------------------------------------ */
/* 文件与 JSON 辅助                                                    */
/* ------------------------------------------------------------------ */

static int ReadFileRaw(const char *path, char *buf, size_t sz)
{
    FILE *f = fopen(path, "rb");
    size_t n;
    if (f == NULL) return 0;
    n = fread(buf, 1, sz - 1, f);
    fclose(f);
    buf[n] = '\0';
    return 1;
}

static int WriteFileRaw(const char *path, const char *data)
{
    FILE *f = fopen(path, "wb");
    size_t len = strlen(data);
    if (f == NULL) return 0;
    fwrite(data, 1, len, f);
    fclose(f);
    return 1;
}

static void RemoveFileIfExists(const char *path)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    if (wp == NULL) return;
    _wremove(wp);
    ts_free(wp);
}

static int read_count(Ctx *ctx)
{
    char buf[1024];
    const char *p;
    int n = -1;
    if (!ReadFileRaw(ctx->count_path, buf, sizeof(buf))) return -1;
    p = strstr(buf, "\"count\"");
    if (p != NULL) {
        p = strchr(p, ':');
        if (p != NULL) n = atoi(p + 1);
    }
    return n;
}

static int read_count_stable(Ctx *ctx)
{
    int i;
    for (i = 0; i < 20; i++) {
        int a = read_count(ctx);
        ts_sleep_ms(100);
        {
            int b = read_count(ctx);
            if (a >= 0 && a == b) return b;
        }
    }
    return read_count(ctx);
}

static void reset_request_count(Ctx *ctx)
{
    char path[800];
    snprintf(path, sizeof(path), "%s\\mock_last_request.json", ctx->workdir);
    RemoveFileIfExists(path);
    snprintf(path, sizeof(path), "%s\\mock_last_response.json", ctx->workdir);
    RemoveFileIfExists(path);
    {
        int cur = read_count_stable(ctx);
        ctx->requests_baseline = (cur > 0) ? cur : 0;
    }
}

static int requests_since_reset(Ctx *ctx)
{
    int total = read_count(ctx);
    if (total < 0) return -1;
    return total - ctx->requests_baseline;
}

/*
 * 读取模拟服务记录的**上一次请求**旁的旁路文件。
 * 该文件只包含计数与布尔标记（auth_header_count / auth_bearer_shape_ok），
 * 绝不包含 Authorization 或密钥的值。
 */
static int last_request_has(Ctx *ctx, const char *needle)
{
    char buf[2048];
    if (!ReadFileRaw(ctx->treq_path, buf, sizeof(buf))) return 0;
    return strstr(buf, needle) != NULL;
}

static void control_write(Ctx *ctx, const char *envelope, int status,
                          const char *extra_json)
{
    TsBuf b;
    ts_buf_init(&b);
    ts_buf_printf(&b, "{\n  \"seq_offset\": %d,\n  \"status\": %d,\n"
                      "  \"headers\": {\"Content-Type\": \"application/json\"}",
                  ctx->requests_baseline, status);
    if (envelope != NULL) {
        ts_buf_puts(&b, ",\n  \"body\": \"");
        /* 最小转义：本文件只用固定外壳，内含双引号 */
        {
            const char *p;
            for (p = envelope; *p != '\0'; p++) {
                switch (*p) {
                case '"':  ts_buf_puts(&b, "\\\""); break;
                case '\\': ts_buf_puts(&b, "\\\\"); break;
                case '\n': ts_buf_puts(&b, "\\n"); break;
                case '\r': ts_buf_puts(&b, "\\r"); break;
                case '\t': ts_buf_puts(&b, "\\t"); break;
                default:   ts_buf_append(&b, p, 1); break;
                }
            }
        }
        ts_buf_puts(&b, "\"");
    }
    if (extra_json != NULL && extra_json[0] != '\0') {
        ts_buf_puts(&b, ",\n  ");
        ts_buf_puts(&b, extra_json);
    }
    ts_buf_puts(&b, "\n}\n");
    WriteFileRaw(ctx->control_path, (b.data != NULL) ? b.data : "{}");
    ts_buf_free(&b);
}

/* ------------------------------------------------------------------ */
/* 配置与运行                                                          */
/* ------------------------------------------------------------------ */

static void cfg_base(Ctx *ctx, TsConfig *cfg)
{
    ts_config_init(cfg);
    cfg->endpoint_url = ts_strdup(ctx->base_url);
    cfg->model = ts_strdup("mock-model");
    cfg->api_key_env = NULL;
    cfg->api_key = NULL;
    cfg->connect_timeout_ms = 5000;
    cfg->wait_prompt_ms = 120000;
    cfg->request_timeout_ms = 0;
    cfg->max_output_tokens = 4000;
    cfg->max_input_bytes = 262144;
    cfg->max_response_bytes = 2 * 1024 * 1024;
    cfg->json_mode = 1;
    cfg->temperature = 0.2;
    cfg->reference_hours = 2.0;
    cfg->w_urgency = 0.35;
    cfg->w_impact = 0.30;
    cfg->w_blocking = 0.20;
    cfg->w_quick_win = 0.10;
    cfg->w_depth = 0.05;
    cfg->max_tasks = 200;
    cfg->max_steps_per_task = 50;
    cfg->max_retry_attempts = 1;
    cfg->mock_mode = 0;
}

static const char *MINIMAL_PLAN =
    "{\"schema_version\":\"1.0\",\"tasks\":[{\"id\":\"T1\",\"name\":\"任务一\","
    "\"depends_on\":[],\"preconditions\":[],\"steps\":[\"做点事\"],"
    "\"urgency\":3,\"urgency_reason\":\"原因\",\"impact\":3,\"impact_reason\":\"原因\","
    "\"estimated_hours\":1.0,\"estimate_reason\":\"原因\",\"deadline\":null,"
    "\"source_refs\":[]}],\"assumptions\":[],\"questions\":[],\"suggested_order\":[\"T1\"]}";

static char *make_envelope(const char *content)
{
    TsBuf b;
    ts_buf_init(&b);
    ts_buf_puts(&b, "{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\","
                    "\"model\":\"mock-model\",\"choices\":[{\"index\":0,"
                    "\"message\":{\"role\":\"assistant\",\"content\":\"");
    {
        const char *p;
        for (p = content; *p != '\0'; p++) {
            switch (*p) {
            case '"':  ts_buf_puts(&b, "\\\""); break;
            case '\\': ts_buf_puts(&b, "\\\\"); break;
            default:   ts_buf_append(&b, p, 1); break;
            }
        }
    }
    ts_buf_puts(&b, "\"},\"finish_reason\":\"stop\"}]}");
    return b.data;
}

static void inputs_init(TsInputs *in)
{
    char err[256];
    ts_inputs_init(in);
    err[0] = '\0';
    ts_inputs_add_text(in, "鉴权集成测试材料，不含任何真实业务数据或密钥。",
                       "鉴权测试样例", 262144, err, sizeof(err));
}

/* 同步跑一次分析（本文件不需要并发；取消场景用独立线程）。 */
static void run_analyze(Ctx *ctx, const TsConfig *cfg, const TsInputs *inputs)
{
    TsCancel cancel;
    int gen;
    ts_cancel_init(&cancel);
    gen = ts_cancel_begin(&cancel);
    ts_analyze_result_free(&ctx->last);
    ts_analyze_result_init(&ctx->last);
    ts_analyze_run(cfg, "请分析这些材料", inputs, &cancel, gen, NULL, NULL, &ctx->last);
}

/* 取消计时线程：只负责“等一会儿然后发出取消”，不碰分析结果。 */
typedef struct CancelTimer {
    TsCancel *cancel;
    unsigned delay_ms;
    volatile LONG done;
} CancelTimer;

static DWORD WINAPI cancel_after_delay(LPVOID param)
{
    CancelTimer *ct = (CancelTimer *)param;
    ts_sleep_ms(ct->delay_ms);
    ts_cancel_request(ct->cancel);
    InterlockedExchange(&ct->done, 1);
    return 0;
}

/* ================================================================== */
/* 场景                                                                */
/* ================================================================== */

/* 1. 密钥环境变量不存在 → 请求前拦下，不发出任何请求 */
static void sc_env_missing(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;

    printf("    (环境变量 TS_AUTH_HTTP_ABSENT 不存在)\n");
    _putenv_s("TS_AUTH_HTTP_ABSENT", "");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_ABSENT");
    cfg.config_path = ts_strdup("C:\\path\\to\\config.json");
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, make_envelope(MINIMAL_PLAN), 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 0, "分析失败（不会当成成功）");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_CONFIG,
          "分类为配置错误（实际 %s），而不是让服务端回 401",
          ts_model_error_kind_name(ctx->last.error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 0,
          "**没有**发出任何 HTTP 请求（本场景服务端收到 %d 次）",
          requests_since_reset(ctx));
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "TS_AUTH_HTTP_ABSENT") != NULL,
          "错误信息里明确指出缺失的环境变量名");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "重新启动") != NULL,
          "错误信息提醒需要重新启动程序");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "C:\\path\\to\\config.json") != NULL,
          "错误信息里给出实际配置文件路径");
    CHECK(ctx, ctx->last.http_status == 0, "未取得 HTTP 状态码（因为没发请求）");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 2. 环境变量存在但为空 → 同样在请求前拦下 */
static void sc_env_empty(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;

    printf("    (环境变量 TS_AUTH_HTTP_EMPTY 显式设为空)\n");
    _putenv_s("TS_AUTH_HTTP_EMPTY", "");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_EMPTY");
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, make_envelope(MINIMAL_PLAN), 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 0, "空密钥时分析失败");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_CONFIG, "分类为配置错误");
    CHECK(ctx, requests_since_reset(ctx) == 0,
          "没有发出 HTTP 请求（%d 次）", requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 3. 密钥格式异常（尾随空白）→ 请求前拦下，且提示不泄露密钥 */
static void sc_key_bad_format(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char with_space[64];

    snprintf(with_space, sizeof(with_space), "%s ", FAKE_KEY);
    printf("    (进程内已读到密钥，但值带尾随空白)\n");
    _putenv_s("TS_AUTH_HTTP_BADFMT", with_space);

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_BADFMT");
    /* 与 ts_config_load 的结果一致：值确实从环境变量读到了（带尾随空白） */
    cfg.api_key = ts_strdup(with_space);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, make_envelope(MINIMAL_PLAN), 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 0, "格式可疑的密钥导致请求前失败");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_CONFIG, "分类为配置错误");
    CHECK(ctx, requests_since_reset(ctx) == 0,
          "没有发出 HTTP 请求（%d 次）", requests_since_reset(ctx));
    CHECK(ctx, ctx->last.error != NULL && strstr(ctx->last.error, "空白") != NULL,
          "提示说明了具体问题是“空白字符”");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "TS_AUTH_HTTP_BADFMT") != NULL,
          "提示中包含环境变量名");
    CHECK(ctx, ctx->last.error != NULL && strstr(ctx->last.error, FAKE_KEY) == NULL,
          "提示中**不包含**密钥内容（已脱敏）");

    _putenv_s("TS_AUTH_HTTP_BADFMT", "");
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 4. 无鉴权本地服务：显式声明无需鉴权时不发送 Authorization，请求照常成功 */
static void sc_local_no_auth(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char *env = make_envelope(MINIMAL_PLAN);

    printf("    (api_key_env 显式留空 = 声明无需鉴权)\n");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("");     /* 显式空串：无需鉴权 */
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 1, "无鉴权本地服务请求成功");
    CHECK(ctx, ctx->last.plan.task_count == 1, "解析出 1 个任务");
    CHECK(ctx, requests_since_reset(ctx) == 1, "服务端收到 1 次请求（%d）",
          requests_since_reset(ctx));
    CHECK(ctx, last_request_has(ctx, "\"auth_header_count\": 0"),
          "请求里**没有** Authorization 头（显式声明无需鉴权）");
    CHECK(ctx, last_request_has(ctx, "\"auth_present\": false") ||
               last_request_has(ctx, "\"auth_header_count\": 0"),
          "服务端侧记录 auth 缺失");

    free(env);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 4b. 未声明 api_key_env（配置里根本没有该字段）同样不发 Authorization */
static void sc_undeclared_no_auth(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char *env = make_envelope(MINIMAL_PLAN);

    printf("    (api_key_env 字段缺失 = 未声明)\n");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = NULL;
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 1, "未声明 api_key_env 时请求成功（本地服务兼容）");
    CHECK(ctx, last_request_has(ctx, "\"auth_header_count\": 0"),
          "请求里没有 Authorization 头");

    free(env);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 5. 正常鉴权：恰好一个 Authorization: Bearer <虚构密钥> */
static void sc_auth_exactly_one_header(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char *env = make_envelope(MINIMAL_PLAN);

    printf("    (使用虚构测试密钥，验证 Authorization 头的数量与形状)\n");
    _putenv_s("TS_AUTH_HTTP_PRESENT", FAKE_KEY);

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_PRESENT");
    cfg.api_key = ts_strdup(FAKE_KEY);   /* 与 load 的行为一致：值来自环境变量 */
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 1, "带密钥时请求成功");
    CHECK(ctx, requests_since_reset(ctx) == 1, "只发出 1 次请求（%d）",
          requests_since_reset(ctx));
    CHECK(ctx, last_request_has(ctx, "\"auth_header_count\": 1"),
          "请求恰好包含 **1 个** Authorization 头（不重复、不叠加）");
    CHECK(ctx, last_request_has(ctx, "\"auth_bearer_shape_ok\": true"),
          "Authorization 形如 “Bearer <密钥>”（Bearer 后恰好一个空格、无换行）");

    _putenv_s("TS_AUTH_HTTP_PRESENT", "");
    free(env);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 6. HTTP 401（带密钥）：不重试、诊断完整且已脱敏 */
static void sc_auth_401(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    /* 服务端正文里故意带一个疑似密钥片段，用来验证脱敏确实生效 */
    const char *body =
        "{\"error\":{\"message\":\"Authentication Fails(governor)\","
        "\"type\":\"authentication_error\",\"request_id\":\"req-abcd-1234\","
        "\"api_key\":\"sk-should-never-be-printed-0001\"}}";

    printf("    (服务端返回 401，正文含疑似密钥片段以验证脱敏)\n");
    _putenv_s("TS_AUTH_HTTP_401", FAKE_KEY);

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_401");
    cfg.api_key = ts_strdup(FAKE_KEY);
    cfg.config_path = ts_strdup("C:\\cfg\\config.json");
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, body, 401, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 0, "401 判定为失败");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_AUTH,
          "分类为鉴权失败（实际 %s）",
          ts_model_error_kind_name(ctx->last.error_kind));
    CHECK(ctx, ctx->last.diag.attempts == 1, "不自动重试（调用次数 %d）",
          ctx->last.diag.attempts);
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "服务端只收到 1 次请求（%d）", requests_since_reset(ctx));
    CHECK(ctx, ctx->last.http_status == 401, "记录到 HTTP 状态码 401（实际 %ld）",
          ctx->last.http_status);

    /* 诊断必须包含可执行的信息 */
    CHECK(ctx, ctx->last.error != NULL && strstr(ctx->last.error, "401") != NULL,
          "提示中包含 HTTP 状态码");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "C:\\cfg\\config.json") != NULL,
          "提示中包含实际配置文件路径");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "TS_AUTH_HTTP_401") != NULL,
          "提示中包含密钥环境变量名");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "当前进程是否读取到密钥：是") != NULL,
          "提示中明确进程**读取到了**密钥");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "Authentication Fails") != NULL,
          "保留服务端错误正文（便于排查）");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "req-abcd-1234") != NULL,
          "保留服务端请求 ID");
    CHECK(ctx, ctx->last.error != NULL &&
          strstr(ctx->last.error, "不会自动重试") != NULL,
          "明确说明不会自动重试");

    /* 脱敏：不得出现任何形式的密钥 */
    {
        char full_header[128];
        snprintf(full_header, sizeof(full_header), "Bearer %s", FAKE_KEY);
        CHECK(ctx, ctx->last.error != NULL &&
              strstr(ctx->last.error, FAKE_KEY) == NULL,
              "提示中不包含我们发出的密钥");
        CHECK(ctx, ctx->last.error != NULL &&
              strstr(ctx->last.error, "sk-should-never-be-printed-0001") == NULL,
              "服务端正文中的疑似密钥已被脱敏");
        CHECK(ctx, ctx->last.error != NULL &&
              strstr(ctx->last.error, full_header) == NULL,
              "提示中不包含完整鉴权头");
    }

    _putenv_s("TS_AUTH_HTTP_401", "");
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 7. HTTP 403：同样不重试 */
static void sc_auth_403(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    const char *body = "{\"error\":{\"message\":\"Forbidden\",\"type\":\"permission_error\"}}";

    printf("    (服务端返回 403)\n");
    _putenv_s("TS_AUTH_HTTP_403", FAKE_KEY);

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("TS_AUTH_HTTP_403");
    cfg.api_key = ts_strdup(FAKE_KEY);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, body, 403, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 0, "403 判定为失败");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_AUTH, "分类为鉴权失败");
    CHECK(ctx, ctx->last.diag.attempts == 1, "403 不自动重试（%d 次）",
          ctx->last.diag.attempts);
    CHECK(ctx, requests_since_reset(ctx) == 1, "服务端只收到 1 次请求（%d）",
          requests_since_reset(ctx));
    CHECK(ctx, ctx->last.error != NULL && strstr(ctx->last.error, FAKE_KEY) == NULL,
          "403 的诊断同样不泄露密钥");

    _putenv_s("TS_AUTH_HTTP_403", "");
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 8. 回归：无鉴权下取消仍能终止请求 */
static void sc_cancel_regression(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char *env = make_envelope(MINIMAL_PLAN);
    TsCancel cancel;
    CancelTimer ct;
    HANDLE th;
    int gen;
    uint64_t t0;

    printf("    (无鉴权下请求进行中取消)\n");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("");
    inputs_init(&in);
    reset_request_count(ctx);
    /* 服务端 15 秒后才回；客户端约 0.8 秒就取消 → 必须及时终止且不采纳结果 */
    control_write(ctx, env, 200, "\"delay_ms\": 15000");

    ts_cancel_init(&cancel);
    gen = ts_cancel_begin(&cancel);
    ts_analyze_result_free(&ctx->last);
    ts_analyze_result_init(&ctx->last);

    /* 计时线程只负责发取消；分析在主线程跑（与既有集成测试同一模式）。 */
    ct.cancel = &cancel;
    ct.delay_ms = 800;
    ct.done = 0;
    th = CreateThread(NULL, 0, cancel_after_delay, &ct, 0, NULL);
    CHECK(ctx, th != NULL, "创建取消计时线程成功");

    t0 = ts_clock_ms();
    ts_analyze_run(&cfg, "请分析这些材料", &in, &cancel, gen, NULL, NULL, &ctx->last);
    {
        long elapsed = (long)ts_clock_elapsed_ms(t0);
        CHECK(ctx, elapsed < 5000,
              "取消及时生效（%ld ms，远小于服务端 15000ms 延迟）", elapsed);
    }

    if (th != NULL) {
        WaitForSingleObject(th, 5000);
        CloseHandle(th);
    }

    CHECK(ctx, ctx->last.ok == 0, "取消后不采纳结果");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_ERR_CANCELLED,
          "分类为已取消（实际 %s）",
          ts_model_error_kind_name(ctx->last.error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "取消不会引发额外请求（%d 次）", requests_since_reset(ctx));

    free(env);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* 9. 回归：无鉴权正常请求（含排序）仍然工作 */
static void sc_normal_regression(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    char *env = make_envelope(MINIMAL_PLAN);

    printf("    (无鉴权正常请求回归)\n");

    cfg_base(ctx, &cfg);
    cfg.api_key_env = ts_strdup("");
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in);

    CHECK(ctx, ctx->last.ok == 1, "正常请求成功");
    CHECK(ctx, ctx->last.plan.task_count == 1, "计划解析正确");
    CHECK(ctx, ctx->last.error_kind == TS_MODEL_OK, "分类为成功");
    CHECK(ctx, requests_since_reset(ctx) == 1, "只调用一次（%d）",
          requests_since_reset(ctx));

    free(env);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
}

/* ================================================================== */

typedef struct Scenario {
    const char *name;
    const char *desc;
    void (*fn)(Ctx *);
} Scenario;

static const Scenario kScenarios[] = {
    { "env_missing",        "密钥环境变量不存在：请求前报错、不发请求", sc_env_missing },
    { "env_empty",          "密钥环境变量为空：请求前报错、不发请求",   sc_env_empty },
    { "key_bad_format",     "密钥格式异常（尾随空白）：请求前报错、不泄露", sc_key_bad_format },
    { "local_no_auth",      "显式无需鉴权：不发 Authorization 且成功",  sc_local_no_auth },
    { "undeclared_no_auth", "未声明 api_key_env：不发 Authorization",   sc_undeclared_no_auth },
    { "auth_one_header",    "正常鉴权：恰好一个 Bearer 头",            sc_auth_exactly_one_header },
    { "auth_401",           "401：不重试 + 诊断完整且脱敏",            sc_auth_401 },
    { "auth_403",           "403：不重试 + 不泄露",                    sc_auth_403 },
    { "cancel_regression",  "回归：取消仍能终止请求",                  sc_cancel_regression },
    { "normal_regression",  "回归：正常请求仍可用",                    sc_normal_regression }
};

static const size_t kScenarioCount = sizeof(kScenarios) / sizeof(kScenarios[0]);

int main(int argc, char **argv)
{
    Ctx ctx;
    size_t i;
    int ran = 0;
    int failed_scenarios = 0;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 3) {
        printf("用法：ts_test_http_auth <base_url> <workdir> [scenario]\n");
        return 2;
    }
    memset(&ctx, 0, sizeof(ctx));
    snprintf(ctx.base_url, sizeof(ctx.base_url), "%s/v1/chat/completions", argv[1]);
    snprintf(ctx.workdir, sizeof(ctx.workdir), "%s", argv[2]);
    snprintf(ctx.count_path, sizeof(ctx.count_path), "%s\\mock_count.json", argv[2]);
    snprintf(ctx.treq_path, sizeof(ctx.treq_path), "%s\\mock_last_request.json", argv[2]);
    snprintf(ctx.control_path, sizeof(ctx.control_path), "%s\\mock_control.json", argv[2]);
    ts_analyze_result_init(&ctx.last);

    printf("=== TaskScheduler 鉴权（本地 HTTP）集成测试 ===\n");
    printf("端点：%s\n", ctx.base_url);
    printf("工作目录：%s\n\n", ctx.workdir);
    printf("说明：本测试的密钥全部为虚构值，绝不读取真实 DEEPSEEK_API_KEY。\n\n");

    for (i = 0; i < kScenarioCount; i++) {
        int before;
        if (argc >= 4 && _stricmp(argv[3], kScenarios[i].name) != 0) {
            continue;
        }
        printf("-- 场景 %s：%s\n", kScenarios[i].name, kScenarios[i].desc);
        before = ctx.fails;
        kScenarios[i].fn(&ctx);
        ran++;
        printf("   [计数] 基线=%d 累计=%d 本场景=%d\n",
               ctx.requests_baseline, read_count_stable(&ctx),
               requests_since_reset(&ctx));
        if (ctx.fails > before) {
            failed_scenarios++;
            printf("   => 场景失败\n");
        } else {
            printf("   => 场景通过\n");
        }
        printf("\n");
    }

    if (ran == 0) {
        printf("没有匹配的场景：%s\n", (argc >= 4) ? argv[3] : "(空)");
        ts_analyze_result_free(&ctx.last);
        return 2;
    }

    printf("=== 汇总：%d 个场景，%d 个场景失败，%d 项断言，%d 项失败 ===\n",
           ran, failed_scenarios, ctx.checks, ctx.fails);

    ts_analyze_result_free(&ctx.last);
    return (ctx.fails == 0) ? 0 : 1;
}

