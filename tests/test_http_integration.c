/*
 * test_http_integration.c — 阶段 2：本地模拟 HTTP 服务的集成测试驱动程序。
 *
 * 目的：在与真实云端完全隔离的前提下，用本地回环地址上的 OpenAI 兼容模拟服务
 * 验证 HTTP 层、错误分类、限流退避、修复/重试预算、取消语义与「等待提醒」行为。
 *
 * 设计要点：
 *   - 本程序**只**面向模拟服务（由 tests/run_http_tests.ps1 启动并传入 base_url），
 *     不使用真实 API Key；请求里也不会带 Authorization（api_key 留空）。
 *   - 判定「发生了几次请求」一律读取模拟服务的**请求计数文件**，
 *     不根据界面或错误文字猜测。
 *   - 每个场景的行为（状态码、延迟、正文）由模拟服务的控制文件驱动；
 *     本程序在每次调用前重写控制文件。
 *
 * 用法：
 *   ts_test_http <base_url> <workdir> <fixturedir> [scenario]
 *   base_url 形如 http://127.0.0.1:PORT ；scenario 省略时按顺序执行全部场景。
 *
 * 退出码：0 = 选定场景全部通过；1 = 有失败；2 = 参数/环境错误。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#include "../src/domain/analysis/analyze.h"
#include "../src/domain/analysis/constraints.h"
#include "../src/state/config.h"
#include "../src/app/controller.h"
#include "../src/domain/export/export.h"
#include "../src/domain/input/input.h"
#include "../src/util/mem.h"
#include "../src/domain/analysis/model.h"
#include "../src/domain/plan/plan.h"
#include "../src/platform/runtime.h"
#include "../src/platform/text.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* ================================================================== */
/* 小型测试框架                                                        */
/* ================================================================== */

typedef struct Ctx {
    char base_url[256];
    char workdir[512];
    char fixture_dir[512];
    char control_path[640];
    char count_path[640];
    int  requests_baseline;   /* 场景开始前的服务端累计请求数 */
    int  fails;
    int  checks;
} Ctx;

static void check(Ctx *ctx, int cond, const char *fmt, ...)
{
    va_list ap;
    ctx->checks++;
    if (cond) {
        return;
    }
    ctx->fails++;
    printf("    [FAIL] ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

static void ok(Ctx *ctx, const char *fmt, ...)
{
    va_list ap;
    ctx->checks++;
    printf("    [PASS] ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

#define CHECK(ctx, cond, ...) check((ctx), (cond), __VA_ARGS__)

/* ================================================================== */
/* 文件与 JSON 辅助                                                    */
/* ================================================================== */

static char *read_file_utf8(const char *path)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    long sz;
    char *buf;

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
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    buf[sz] = '\0';
    return buf;
}

static int write_file_utf8(const char *path, const char *data, size_t len)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    FILE *f;
    int okw;

    if (wp == NULL) return 0;
    f = _wfopen(wp, L"wb");
    ts_free(wp);
    if (f == NULL) return 0;
    okw = (len == 0) || (fwrite(data, 1, len, f) == len);
    fclose(f);
    return okw;
}

static void RemoveFileIfExists(const char *path)
{
    wchar_t *wp = ts_utf8_to_wide(path, strlen(path), NULL);
    if (wp == NULL) return;
    _wremove(wp);
    ts_free(wp);
}

/* JSON 字符串转义（含 UTF-8 原样透传、控制字符转义）。 */
static void json_escape_into(TsBuf *b, const char *s)
{
    const unsigned char *p;
    if (s == NULL) return;
    for (p = (const unsigned char *)s; *p != '\0'; p++) {
        switch (*p) {
        case '"':  ts_buf_puts(b, "\\\""); break;
        case '\\': ts_buf_puts(b, "\\\\"); break;
        case '\n': ts_buf_puts(b, "\\n"); break;
        case '\r': ts_buf_puts(b, "\\r"); break;
        case '\t': ts_buf_puts(b, "\\t"); break;
        case '\b': ts_buf_puts(b, "\\b"); break;
        case '\f': ts_buf_puts(b, "\\f"); break;
        default:
            if (*p < 0x20) {
                ts_buf_printf(b, "\\u%04x", (unsigned)*p);
            } else {
                ts_buf_append(b, (const char *)p, 1);
            }
            break;
        }
    }
}

/* 组装 OpenAI 兼容响应外壳；content 为模型「输出正文」。 */
static char *make_envelope(const char *content, const char *finish_reason)
{
    TsBuf b;
    ts_buf_init(&b);
    ts_buf_puts(&b, "{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\","
                    "\"model\":\"mock-model\",\"choices\":[{\"index\":0,"
                    "\"message\":{\"role\":\"assistant\",\"content\":\"");
    json_escape_into(&b, content);
    ts_buf_puts(&b, "\"},\"finish_reason\":\"");
    json_escape_into(&b, finish_reason);
    ts_buf_puts(&b, "\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,"
                    "\"total_tokens\":30}}");
    return b.data;
}

/*
 * 把响应正文写到磁盘，并返回一个「唯一文件名」（调用方负责释放）。
 *
 * 为什么要写文件而不是塞进控制文件的 JSON 字符串：
 * 「模型输出」本身是 JSON，再嵌进控制文件 JSON，就会出现
 * C 字面量 → 控制文件 JSON → 外壳 content 三层转义，
 * 极易出错且难以排查。改成写原始字节后，正文一个转义层都不需要。
 */
static char *write_body_file(Ctx *ctx, const char *name, const char *body)
{
    char path[800];
    char *copy;
    snprintf(path, sizeof(path), "%s\\resp_%s.json", ctx->workdir, name);
    if (!write_file_utf8(path, body, strlen(body))) {
        return NULL;
    }
    copy = ts_strdup(path);
    return copy;
}

/* 再用一次 JSON 转义，把外壳文本放进控制文件的 body 字段。 */
static void control_write(Ctx *ctx, const char *envelope_or_null,
                          int status, const char *extra_json_fields)
{
    TsBuf b;
    ts_buf_init(&b);
    ts_buf_puts(&b, "{\n  \"seq_offset\": ");
    ts_buf_printf(&b, "%d", ctx->requests_baseline);
    ts_buf_puts(&b, ",\n  \"status\": ");
    ts_buf_printf(&b, "%d", status);
    ts_buf_puts(&b, ",\n  \"headers\": {\"Content-Type\": \"application/json\"}");
    if (envelope_or_null != NULL) {
        ts_buf_puts(&b, ",\n  \"body\": \"");
        json_escape_into(&b, envelope_or_null);
        ts_buf_puts(&b, "\"");
    }
    if (extra_json_fields != NULL && extra_json_fields[0] != '\0') {
        ts_buf_puts(&b, ",\n  ");
        ts_buf_puts(&b, extra_json_fields);
    }
    ts_buf_puts(&b, "\n}\n");
    write_file_utf8(ctx->control_path, b.data != NULL ? b.data : "{}",
                    b.data != NULL ? b.len : 2);
    ts_buf_free(&b);
}

/*
 * 写法二：按「第几次请求」给出不同的响应（用原始正文文件，避免多层转义）。
 * body_files[i] 对应第 i+1 次请求；为 NULL 时该次请求使用默认正文。
 */
static void control_write_seq(Ctx *ctx, const char *const *body_files,
                              const int *statuses, size_t n)
{
    TsBuf b;
    size_t i;
    ts_buf_init(&b);
    ts_buf_puts(&b, "{\n");
    ts_buf_printf(&b, "  \"seq_offset\": %d,\n", ctx->requests_baseline);
    for (i = 0; i < n; i++) {
        char key[32];
        int st = (statuses != NULL) ? statuses[i] : 200;
        snprintf(key, sizeof(key), "r%u_status", (unsigned)(i + 1));
        ts_buf_printf(&b, "  \"%s\": %d,\n", key, st);
        if (body_files[i] != NULL) {
            snprintf(key, sizeof(key), "r%u_body_file", (unsigned)(i + 1));
            ts_buf_puts(&b, "  \"");
            ts_buf_puts(&b, key);
            ts_buf_puts(&b, "\": \"");
            json_escape_into(&b, body_files[i]);   /* 只转义文件路径本身 */
            ts_buf_puts(&b, "\",\n");
        }
    }
    ts_buf_puts(&b, "  \"status\": 200\n}\n");
    write_file_utf8(ctx->control_path, b.data != NULL ? b.data : "{}",
                    b.data != NULL ? b.len : 2);
    ts_buf_free(&b);
}

/*
 * 稳定的请求计数读取。
 *
 * 服务端在**返回响应之前**已经写好计数文件，但上一个场景的 TCP 关闭与服务端线程
 * 收尾之间仍有一小段窗口；紧接着开始下一个场景时，直接读文件可能读到还没更新的旧值，
 * 于是“本场景基线”偏小、差值偏大（实测会出现“本场景=10”这种假失败）。
 * 做法：连续读两次，要求值一致且文件可解析，最多等 2 秒。
 */
static int read_request_count(Ctx *ctx);

/* 供 reset_request_count 与汇总使用：等计数文件稳定后再读。 */
static int read_request_count_stable(Ctx *ctx)
{
    int i;
    for (i = 0; i < 20; i++) {
        int a = read_request_count(ctx);
        ts_sleep_ms(100);
        {
            int b = read_request_count(ctx);
            if (a >= 0 && a == b) {
                return b;
            }
        }
    }
    return read_request_count(ctx);
}

static int read_request_count(Ctx *ctx)
{
    char *s = read_file_utf8(ctx->count_path);
    const char *p;
    int n = -1;
    if (s == NULL) {
        printf("    [诊断] 读不到计数文件：%s\n", ctx->count_path);
        return -1;
    }
    p = strstr(s, "\"count\"");
    if (p != NULL) {
        p = strchr(p, ':');
        if (p != NULL) n = atoi(p + 1);
    }
    if (n < 0) {
        printf("    [诊断] 计数文件内容异常：%s\n", s);
    }
    free(s);
    return n;
}

/* 自本场景开始以来，服务端累计收到的请求数。 */
static int requests_since_reset(Ctx *ctx)
{
    int total = read_request_count(ctx);
    if (total < 0) return -1;
    return total - ctx->requests_baseline;
}

/*
 * 请求计数与「第几次请求」的定位。
 *
 * 模拟服务的请求序号是单调累计的（跨场景不重置），因为让测试去重置服务端状态
 * 会引入竞态。因此：
 *   - 计数断言使用「本场景基线 -> 当前」的差值；
 *   - 需要按序覆盖（r1_x 与 r2_x 这类字段）时，由本程序把基线写进控制文件的
 *     seq_offset，服务端据此换算出「本场景的第 N 次请求」。
 *
 * 注意：这里刻意不写「r1_ 加斜杠加星号」那种字面量——斜杠加星号会提前结束
 * 这段块注释，把后面的中文注释当成代码，从而产生难以定位的语法错误。
 */
static void reset_request_count(Ctx *ctx)
{
    char path[800];
    int cur;
    /* 清掉上一次场景留下的旁路文件，避免读到过期内容造成假通过/假失败 */
    snprintf(path, sizeof(path), "%s\\mock_last_response.json", ctx->workdir);
    RemoveFileIfExists(path);
    snprintf(path, sizeof(path), "%s\\mock_last_request.json", ctx->workdir);
    RemoveFileIfExists(path);
    /* 记录基线（不清空任何服务端文件，避免竞态） */
    cur = read_request_count_stable(ctx);
    ctx->requests_baseline = (cur > 0) ? cur : 0;
}

/* ================================================================== */
/* 被测调用：配置 + 输入                                                */
/* ================================================================== */

static void cfg_init(Ctx *ctx, TsConfig *cfg, long wait_prompt_ms,
                     long max_response_bytes, int max_retry_attempts)
{
    ts_config_init(cfg);
    cfg->endpoint_url = ts_strdup(ctx->base_url);
    cfg->model = ts_strdup("mock-model");
    cfg->api_key_env = NULL;
    cfg->api_key = NULL;                 /* 模拟服务不需要鉴权 */
    cfg->connect_timeout_ms = 5000;
    cfg->wait_prompt_ms = wait_prompt_ms;
    cfg->request_timeout_ms = 0;         /* 云端默认禁用总超时，本地同样不禁用 */
    cfg->max_output_tokens = 4000;
    cfg->max_input_bytes = 262144;
    cfg->max_response_bytes = max_response_bytes;
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
    cfg->max_retry_attempts = max_retry_attempts;
    cfg->mock_mode = 0;
}

static void inputs_init(TsInputs *in)
{
    char err[256];
    ts_inputs_init(in);
    err[0] = '\0';
    ts_inputs_add_text(in, "这是一段用于集成测试的示例材料，不含任何真实业务数据或密钥。",
                       "集成测试样例", 262144, err, sizeof(err));
}

/* ================================================================== */
/* 分析调用 + 「等待提醒」驱动                                            */
/* ================================================================== */

typedef struct RunOutcome {
    int reminder_fired;      /* 提醒是否出现过 */
    int reminder_count;      /* 提醒出现次数（必须 <= 1） */
    int cancelled;           /* 是否由本程序发起了取消 */
    long elapsed_ms;
} RunOutcome;

typedef struct WorkerArgs {
    const TsConfig *cfg;
    const TsInputs *inputs;
    const TsCancel *cancel;
    int generation;
    TsAnalyzeResult *out;
    volatile LONG done;
} WorkerArgs;

/* 最近一次分析结果（由 run_analyze 填充；所有权归本文件）。 */
static TsAnalyzeResult g_last_storage;
static TsAnalyzeResult *g_last_result = &g_last_storage;

static DWORD WINAPI analyze_thread(LPVOID param)
{
    WorkerArgs *wa = (WorkerArgs *)param;
    ts_analyze_run(wa->cfg, "请分析这些材料", wa->inputs,
                   wa->cancel, wa->generation, NULL, NULL, wa->out);
    InterlockedExchange(&wa->done, 1);
    return 0;
}

typedef struct CancelArgs {
    TsCancel *cancel;
    unsigned delay_ms;
} CancelArgs;

static DWORD WINAPI cancel_thread(LPVOID param)
{
    CancelArgs *ca = (CancelArgs *)param;
    ts_sleep_ms(ca->delay_ms);
    ts_cancel_request(ca->cancel);
    return 0;
}

/*
 * 运行一次分析，并模拟 GUI 的「等待提醒」定时器：
 * 后台线程跑分析，主循环每 50ms 检查一次已等待时间；
 * 超过 wait_prompt_ms 只触发**一次**提醒标记（不重复、不重发请求），
 * 然后继续等待——与真实界面的语义一致（不操作提醒框等于继续等待）。
 */
static void run_analyze(Ctx *ctx, const TsConfig *cfg, const TsInputs *inputs,
                        unsigned cancel_after_ms, RunOutcome *out)
{
    TsAnalyzeResult res;
    TsCancel cancel;
    WorkerArgs wa;
    HANDLE th;
    HANDLE cth = NULL;
    CancelArgs ca;
    uint64_t start;
    int generation;

    memset(out, 0, sizeof(*out));
    ts_analyze_result_init(&res);
    ts_cancel_init(&cancel);
    generation = ts_cancel_begin(&cancel);

    wa.cfg = cfg;
    wa.inputs = inputs;
    wa.cancel = &cancel;
    wa.generation = generation;
    wa.out = &res;
    InterlockedExchange(&wa.done, 0);

    start = ts_clock_ms();
    th = CreateThread(NULL, 0, analyze_thread, &wa, 0, NULL);
    if (th == NULL) {
        out->elapsed_ms = 0;
        check(ctx, 0, "创建分析线程失败");
        return;
    }

    if (cancel_after_ms > 0) {
        ca.cancel = &cancel;
        ca.delay_ms = cancel_after_ms;
        cth = CreateThread(NULL, 0, cancel_thread, &ca, 0, NULL);
    }

    for (;;) {
        long waited = (long)ts_clock_elapsed_ms(start);
        if (wa.done) break;
        if (!out->reminder_fired && cfg->wait_prompt_ms > 0 &&
            waited >= cfg->wait_prompt_ms) {
            out->reminder_fired = 1;
            out->reminder_count++;
        }
        if (cancel_after_ms > 0 && waited >= (long)cancel_after_ms) {
            out->cancelled = 1;
        }
        ts_sleep_ms(20);
    }

    out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
    if (cth != NULL) {
        WaitForSingleObject(cth, 5000);
        CloseHandle(cth);
    }
    WaitForSingleObject(th, 5000);
    CloseHandle(th);

    /* 把结果所有权移交给全局槽位，供各场景断言 */
    ts_analyze_result_free(g_last_result);
    *g_last_result = res;
}

static void last_result_init(void)
{
    ts_analyze_result_init(g_last_result);
}

static void last_result_free(void)
{
    ts_analyze_result_free(g_last_result);
}

/* ================================================================== */
/* 场景                                                               */
/* ================================================================== */

typedef int (*ScenarioFn)(Ctx *ctx);

typedef struct Scenario {
    const char *name;
    const char *desc;
    ScenarioFn fn;
} Scenario;

static char *load_fixture(Ctx *ctx, const char *name)
{
    char path[800];
    snprintf(path, sizeof(path), "%s\\%s", ctx->fixture_dir, name);
    return read_file_utf8(path);
}

/* --- 1. 正常返回合法任务 JSON --- */
static int sc_normal(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    if (content == NULL) { CHECK(ctx, 0, "读取夹具失败"); return 1; }
    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1, "分析成功（ok=1）");
    CHECK(ctx, g_last_result->error == NULL || g_last_result->error[0] == '\0',
          "成功时没有错误信息");
    CHECK(ctx, g_last_result->plan.task_count == 2, "解析出 2 个任务（实际 %zu）",
          g_last_result->plan.task_count);
    CHECK(ctx, g_last_result->diag.attempts == 1, "模型只被调用 1 次（diag.attempts=%d）",
          g_last_result->diag.attempts);
    CHECK(ctx, g_last_result->diag.used_repair == 0, "未使用修复请求");
    CHECK(ctx, g_last_result->diag.network_retried == 0, "未发生网络重试");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_OK, "错误分类为成功");
    CHECK(ctx, requests_since_reset(ctx) == 1, "模拟服务收到的请求数为 1（实际 %d）",
          requests_since_reset(ctx));
    if (g_last_result->plan.task_count == 2) {
        CHECK(ctx, strcmp(g_last_result->plan.tasks[0].id, "M1") == 0, "任务 ID 正确");
        CHECK(ctx, g_last_result->plan.tasks[1].depends_on_count == 1 &&
                   strcmp(g_last_result->plan.tasks[1].depends_on[0], "M1") == 0,
              "依赖关系正确解析");
    }
    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 2. 完整响应时间超过提醒阈值（提醒触发且只触发一次） --- */
static int sc_slow_reminder(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 3000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"delay_ms\": 6000");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, ro.reminder_fired == 1, "等待超过阈值后提醒出现");
    CHECK(ctx, ro.reminder_count <= 1, "提醒只出现一次（不重复弹窗）");
    CHECK(ctx, g_last_result->ok == 1, "最终仍成功取得结果");
    CHECK(ctx, ro.elapsed_ms >= 5500, "确实等了约 6 秒（实际 %ld ms）", ro.elapsed_ms);
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "全程只发送了 1 次请求（未因提醒重发，实际 %d）", requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.attempts == 1, "调用次数为 1");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 3. 提醒出现后用户选择继续等待，随后正常返回 --- */
static int sc_reminder_then_continue(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 2000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"delay_ms\": 7000");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, ro.reminder_fired == 1, "提醒触发（用户在阈值后继续等待）");
    CHECK(ctx, g_last_result->ok == 1, "继续等待后仍拿到结果");
    CHECK(ctx, g_last_result->diag.attempts == 1, "继续等待不会重新发送请求");
    CHECK(ctx, requests_since_reset(ctx) == 1, "服务端只看到 1 次请求（实际 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->plan.task_count == 2, "结果完整（未被截断）");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 4. 用户在等待期间取消 --- */
static int sc_cancel_during_wait(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"delay_ms\": 15000");

    run_analyze(ctx, &cfg, &in, 1000, &ro);

    CHECK(ctx, g_last_result->ok == 0, "取消后不采纳为成功结果");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_CANCELLED,
          "错误分类为「已取消」（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, ro.elapsed_ms < 3000, "取消响应及时（%ld ms，未等到服务端返回）",
          ro.elapsed_ms);
    CHECK(ctx, g_last_result->diag.attempts == 1, "取消后不自动重试（调用次数 1）");
    CHECK(ctx, requests_since_reset(ctx) == 1, "服务端只收到 1 次请求（实际 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 5. 用户取消后才返回（迟到结果不得被采纳） --- */
static int sc_late_result_after_cancel(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    /* 服务端 2 秒后返回「成功」，但客户端 200ms 就取消：迟到结果必须被丢弃 */
    control_write(ctx, env, 200, "\"delay_ms\": 2000");

    run_analyze(ctx, &cfg, &in, 200, &ro);

    CHECK(ctx, g_last_result->ok == 0, "迟到的成功结果未被采纳");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_CANCELLED, "分类为「已取消」");
    CHECK(ctx, g_last_result->plan.task_count == 0, "未把迟到计划写入结果");
    CHECK(ctx, requests_since_reset(ctx) == 1, "迟到结果不触发重发（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 6. 提示框显示期间完整响应到达（提醒结束后结果一并到达） --- */
static int sc_response_during_prompt(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env;
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    env = make_envelope(content, "stop");
    cfg_init(ctx, &cfg, 1500, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"delay_ms\": 3000");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, ro.reminder_fired == 1, "提醒在响应到达之前触发");
    CHECK(ctx, g_last_result->ok == 1, "响应到达后正常采纳");
    CHECK(ctx, ro.reminder_count <= 1, "过期提醒只出现一次（结果到达后不应再弹）");
    CHECK(ctx, requests_since_reset(ctx) == 1, "提醒期间原请求没有被重发（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 7. 401 / 403：鉴权失败不得重试 --- */
static int sc_auth_no_retry(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    int codes[2] = { 401, 403 };
    int i;

    for (i = 0; i < 2; i++) {
        cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
        inputs_init(&in);
        reset_request_count(ctx);
        control_write(ctx, "{\"error\":{\"message\":\"invalid api key\"}}", codes[i], NULL);

        run_analyze(ctx, &cfg, &in, 0, &ro);

        CHECK(ctx, g_last_result->ok == 0, "HTTP %d 视为失败", codes[i]);
        CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_AUTH,
              "HTTP %d 分类为鉴权失败（实际 %s）", codes[i],
              ts_model_error_kind_name(g_last_result->error_kind));
        CHECK(ctx, g_last_result->diag.attempts == 1,
              "HTTP %d 不自动重试（调用次数 %d）", codes[i],
              g_last_result->diag.attempts);
        CHECK(ctx, requests_since_reset(ctx) == 1,
              "HTTP %d 服务端只收到 1 次请求（实际 %d）", codes[i],
              requests_since_reset(ctx));
        CHECK(ctx, g_last_result->error != NULL && g_last_result->error[0] != '\0',
              "HTTP %d 给出明确错误信息", codes[i]);

        ts_config_free(&cfg);
        ts_inputs_free(&in);
    }
    return 0;
}

/* --- 8. 429 + Retry-After：按提示等待后重试一次 --- */
static int sc_rate_limit_retry_after(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    int r1;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "{\"error\":{\"message\":\"rate limited\"}}", 429,
                  "\"extra_headers\": {\"Retry-After\": \"2\"}");

    run_analyze(ctx, &cfg, &in, 0, &ro);
    /* 用“本场景相对基线”的差值，而不是累计值（服务端序号跨场景不重置）。 */
    r1 = requests_since_reset(ctx);

    CHECK(ctx, g_last_result->ok == 0, "持续 429 时最终仍失败");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_RATE_LIMIT,
          "分类为限流（实际 %s）", ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, r1 == 2, "429 触发一次重试（本场景服务端收到 %d 次请求）", r1);
    CHECK(ctx, g_last_result->diag.network_retried == 1, "诊断标记为发生过网络重试");
    CHECK(ctx, ro.elapsed_ms >= 2000,
          "等待时长遵循 Retry-After: 2（实测 %ld ms >= 2000）", ro.elapsed_ms);
    CHECK(ctx, ro.elapsed_ms < 12000, "等待时长在上限内（%ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 8b. 429 退避期间取消：不再发起第二次请求 --- */
static int sc_cancel_during_retry_wait(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    /* Retry-After 给 5 秒；取消安排在 700ms，应落在退避等待中 */
    control_write(ctx, "{\"error\":{\"message\":\"rate limited\"}}", 429,
                  "\"extra_headers\": {\"Retry-After\": \"5\"}");

    run_analyze(ctx, &cfg, &in, 700, &ro);

    CHECK(ctx, g_last_result->ok == 0, "取消后不成功");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_CANCELLED,
          "分类为「已取消」（实际 %s）", ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "退避等待中取消后不再重试（请求数 %d，应为 1）", requests_since_reset(ctx));
    CHECK(ctx, ro.elapsed_ms < 5000, "取消立即结束等待（%ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 9. 可重试的 5xx（502） --- */
static int sc_server_error_retry(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "{\"error\":\"bad gateway\"}", 502, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "持续 502 最终失败");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_SERVER,
          "分类为服务端错误（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 2, "502 重试一次（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.network_retried == 1, "诊断标记网络重试");
    CHECK(ctx, ro.elapsed_ms >= 500, "默认退避至少 500ms（实测 %ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 9b. 不可重试的 4xx（404） --- */
static int sc_client_error_no_retry(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "{\"error\":\"not found\"}", 404, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "404 失败");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_CONFIG,
          "404 分类为请求/配置错误（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 1, "404 不重试（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 10. 空正文 --- */
static int sc_empty_body(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "", 200, NULL);   /* 完全空的响应体 */

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "空正文不被当成成功");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_EMPTY ||
              g_last_result->error_kind == TS_MODEL_ERR_PROTOCOL,
          "空正文分类为「正文为空/协议错误」（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 2,
          "空正文消耗修复预算（请求数 %d，应为 2）", requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.used_repair == 1, "诊断标记使用了修复请求");
    CHECK(ctx, g_last_result->error != NULL && g_last_result->error[0] != '\0',
          "给出明确错误信息");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 10b. content 为空串的合法外壳 --- */
static int sc_empty_content_field(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "", 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "content 为空串时失败");
    CHECK(ctx, g_last_result->diag.attempts == 2, "触发了一次修复调用（attempts=%d）",
          g_last_result->diag.attempts);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 11. 非法 JSON --- */
static int sc_invalid_json(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    /* 外壳合法，但 content 不是合法 JSON */
    {
        char *env = make_envelope("{\"schema_version\": \"1.0\", \"tasks\": [{\"id\"",
                                  "stop");
        control_write(ctx, env, 200, NULL);
        free(env);
    }

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "非法 JSON 不被采纳");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_PROTOCOL,
          "分类为协议错误（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 2, "非法 JSON 触发一次修复（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.used_repair == 1, "标记使用了修复请求");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 12. 缺失必需字段（校核发现 #2 的端到端回归） --- */
static int sc_missing_required_fields(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "missing_required_fields.json");
    char *env = make_envelope(content, "stop");

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "缺字段的 JSON 不被采纳（不默认成空值）");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_PROTOCOL,
          "分类为协议错误（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, g_last_result->error != NULL &&
              (strstr(g_last_result->error, "depends_on") != NULL ||
               strstr(g_last_result->error, "preconditions") != NULL ||
               strstr(g_last_result->error, "steps") != NULL),
          "错误信息指出缺失的字段名");
    CHECK(ctx, requests_since_reset(ctx) == 2, "缺字段触发一次针对性修复（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 13. finish_reason = length（输出被截断） --- */
static int sc_truncated(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env = make_envelope(content, "length");

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "finish_reason=length 不被当作成功");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_PROTOCOL ||
              g_last_result->diag.last_error_kind == TS_MODEL_ERR_TRUNCATED,
          "截断被识别（最终分类 %s，最近错误 %s）",
          ts_model_error_kind_name(g_last_result->error_kind),
          ts_model_error_kind_name(g_last_result->diag.last_error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 2, "截断触发一次修复（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* 读取模拟服务记录的「最后一次响应正文」，用于确认修复请求确实发出。 */
static int trace_contains(Ctx *ctx, const char *needle)
{
    char path[800];
    char *s;
    int found = 0;
    snprintf(path, sizeof(path), "%s\\mock_last_request.json", ctx->workdir);
    s = read_file_utf8(path);
    if (s == NULL) {
        printf("    [诊断] 读不到请求追踪文件：%s\n", path);
        return 0;
    }
    found = (strstr(s, needle) != NULL) ? 1 : 0;
    if (!found) {
        printf("    [诊断] 追踪文件内容：%s\n", s);
    }
    free(s);
    return found;
}

/* --- 13b. 第一次可重试失败、重试后成功（验证重试确实能救回请求） --- */
static int sc_retry_then_success(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *err_env = make_envelope("{\"error\":\"temporarily unavailable\"}", "stop");
    char *good_env = make_envelope(content, "stop");
    char *f_err = write_body_file(ctx, "retry1", err_env);
    char *f_good = write_body_file(ctx, "retry2", good_env);
    const char *envs[2];
    int stats[2];

    envs[0] = f_err;
    envs[1] = f_good;
    stats[0] = 503;                  /* 第 1 次：可重试的服务端错误 */
    stats[1] = 200;                  /* 第 2 次：正常 */

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write_seq(ctx, envs, stats, 2);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1, "重试后取得成功结果");
    CHECK(ctx, requests_since_reset(ctx) == 2, "恰好两次调用（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.network_retried == 1,
          "诊断标记发生了网络重试（attempts=%d retried=%d repair=%d kind=%s）",
          g_last_result->diag.attempts, g_last_result->diag.network_retried,
          g_last_result->diag.used_repair,
          ts_model_error_kind_name(g_last_result->diag.last_error_kind));
    CHECK(ctx, g_last_result->diag.attempts == 2, "调用次数为 2（实际 %d）",
          g_last_result->diag.attempts);
    CHECK(ctx, g_last_result->plan.task_count == 2, "重试结果被完整解析");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(f_err);
    free(f_good);
    free(err_env);
    free(good_env);
    free(content);
    return 0;
}

/* --- 13c. 第一次输出截断、修复后成功（验证修复确实能救回请求） --- */
static int sc_repair_then_success(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *trunc_env = make_envelope(content, "length");
    char *good_env = make_envelope(content, "stop");
    char *f_trunc = write_body_file(ctx, "repair1", trunc_env);
    char *f_good = write_body_file(ctx, "repair2", good_env);
    const char *envs[2];
    int stats[2] = { 200, 200 };

    envs[0] = f_trunc;
    envs[1] = f_good;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write_seq(ctx, envs, stats, 2);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1, "修复后取得成功结果");
    CHECK(ctx, requests_since_reset(ctx) == 2, "恰好两次调用（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.used_repair == 1, "诊断标记使用了修复请求");
    CHECK(ctx, g_last_result->diag.network_retried == 0, "未发生网络重试");
    CHECK(ctx, g_last_result->plan.task_count == 2, "修复结果被完整解析");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(f_trunc);
    free(f_good);
    free(trunc_env);
    free(good_env);
    free(content);
    return 0;
}

/* --- 13d. 缺字段 -> 修复成功（校核发现 #2 的完整闭环） --- */
static int sc_missing_then_repaired(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *bad_content = load_fixture(ctx, "missing_required_fields.json");
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *bad_env = make_envelope(bad_content, "stop");
    char *good_env = make_envelope(content, "stop");
    char *f_bad = write_body_file(ctx, "missing1", bad_env);
    char *f_good = write_body_file(ctx, "missing2", good_env);
    const char *envs[2];
    int stats[2] = { 200, 200 };

    envs[0] = f_bad;
    envs[1] = f_good;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write_seq(ctx, envs, stats, 2);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1, "缺字段经一次修复后成功");
    CHECK(ctx, requests_since_reset(ctx) == 2, "只多用了一次调用（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.used_repair == 1, "标记使用了修复");
    CHECK(ctx, g_last_result->plan.task_count == 2, "修复后的任务完整");
    /* 修复请求本身必须带上「上次输出存在问题」与校验错误说明 */
    CHECK(ctx, trace_contains(ctx, "\"has_repair_marker\": true"),
          "服务端确认第二次请求是修复请求（含【上次输出存在问题】标记）");
    CHECK(ctx, trace_contains(ctx, "\"has_error_marker\": true"),
          "修复请求包含校验错误说明");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(f_bad);
    free(f_good);
    free(bad_env);
    free(good_env);
    free(bad_content);
    free(content);
    return 0;
}

/* --- 14. 超过响应大小上限 --- */
static int sc_too_large(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "large_body.txt");
    char *env;

    if (content == NULL) { CHECK(ctx, 0, "读取大正文夹具失败"); return 1; }
    env = make_envelope(content, "stop");
    /* 把上限压到 4096 字节，便于用 512 KiB 正文触发 */
    cfg_init(ctx, &cfg, 120000, 4096, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "超过大小上限的响应被拒绝");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_TOO_LARGE,
          "分类为「超过大小上限」（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, g_last_result->error != NULL &&
              strstr(g_last_result->error, "4096") != NULL,
          "错误信息给出具体上限");
    CHECK(ctx, requests_since_reset(ctx) == 1, "超限不重试（请求数 %d）",
          requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 15. 关闭窗口时请求仍在进行（快速取消且不留后台请求） --- */
static int sc_close_window_active_request(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env = make_envelope(content, "stop");
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    uint64_t t0;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"delay_ms\": 20000");

    t0 = ts_clock_ms();
    run_analyze(ctx, &cfg, &in, 500, &ro);
    t0 = ts_clock_elapsed_ms(t0);

    CHECK(ctx, g_last_result->ok == 0, "关窗前的取消使请求不成功");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_CANCELLED, "分类为已取消");
    CHECK(ctx, t0 < 3000, "从发出取消到分析返回不超过 3 秒（实测 %llu ms）",
          (unsigned long long)t0);
    CHECK(ctx, requests_since_reset(ctx) == 1, "没有遗留的重复请求（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.attempts == 1, "没有额外调用");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 16. 网络中断（连接被直接关闭） --- */
static int sc_network_drop(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, NULL, 200, "\"drop\": true");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "连接被切断时不成功");
    CHECK(ctx, g_last_result->error_kind == TS_MODEL_ERR_NETWORK ||
              g_last_result->error_kind == TS_MODEL_ERR_PROTOCOL,
          "分类为网络错误（实际 %s）",
          ts_model_error_kind_name(g_last_result->error_kind));
    CHECK(ctx, requests_since_reset(ctx) == 2, "网络错误重试一次（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, g_last_result->error != NULL, "给出错误信息");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 17. 重试与修复共用同一份额外调用预算（max_retry_attempts = 0） --- */
static int sc_budget_zero(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    /* max_retry_attempts = 0：即使返回可重试的 503，也不得重试 */
    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 0);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "{\"error\":\"unavailable\"}", 503, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 0, "预算为 0 时失败");
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "预算为 0 时不得重试（请求数 %d）", requests_since_reset(ctx));
    CHECK(ctx, g_last_result->diag.network_retried == 0, "诊断未标记重试");

    /* 同一预算下的修复：非法 JSON 也不得修复 */
    reset_request_count(ctx);
    {
        char *env = make_envelope("{ not json", "stop");
        control_write(ctx, env, 200, NULL);
        free(env);
    }
    run_analyze(ctx, &cfg, &in, 0, &ro);
    CHECK(ctx, requests_since_reset(ctx) == 1,
          "预算为 0 时不得发起修复（请求数 %d）", requests_since_reset(ctx));

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 18. 请求头与正文：不带 Authorization、按 OpenAI 约定构造 --- */
static int sc_request_shape(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "minimal_tasks.json");
    char *env = make_envelope(content, "stop");
    int count_before;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);
    count_before = requests_since_reset(ctx);

    CHECK(ctx, g_last_result->ok == 1, "最小合法计划可成功解析");
    CHECK(ctx, count_before == 1, "只调用一次");
    /* 模拟服务记录了 auth_present；api_key 为空时必须为 false */
    {
        char *s = read_file_utf8(ctx->count_path);
        CHECK(ctx, s != NULL && strstr(s, "\"auth_present\": false") != NULL,
              "未配置 API Key 时不发送 Authorization 头");
        free(s);
    }

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 19. 总超时禁用时长请求仍能完成 --- */
static int sc_no_total_timeout(Ctx *ctx)
{
    char *content = load_fixture(ctx, "minimal_tasks.json");
    char *env = make_envelope(content, "stop");
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    cfg.request_timeout_ms = 0;          /* 显式禁用总超时 */
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"total_ms\": 4000");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1,
          "request_timeout_ms=0 时慢响应（4 秒）仍能完成");
    CHECK(ctx, ro.elapsed_ms >= 3500, "确实等了约 4 秒（%ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 20. 分块到达的响应可被完整拼接 --- */
static int sc_chunked_response(Ctx *ctx)
{
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env = make_envelope(content, "stop");
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, "\"chunks\": 8, \"total_ms\": 1500");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, g_last_result->ok == 1, "分 8 段到达的响应仍被完整接收");
    CHECK(ctx, g_last_result->plan.task_count == 2, "分块响应内容完整（2 个任务）");

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 21. 429 无 Retry-After：使用默认退避 --- */
static int sc_rate_limit_default_backoff(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, "{\"error\":\"rate limited\"}", 429, NULL);

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, requests_since_reset(ctx) == 2, "无 Retry-After 时仍重试一次（请求数 %d）",
          requests_since_reset(ctx));
    CHECK(ctx, ro.elapsed_ms >= 400, "使用默认退避（>=400ms，实测 %ld ms）", ro.elapsed_ms);
    CHECK(ctx, ro.elapsed_ms < 5000, "默认退避不会过长（%ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 22. 畸形 Retry-After 不被采信（不得长时间等待） --- */
static int sc_malformed_retry_after(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    /* HTTP-date 形式：客户端必须忽略并退回默认退避 */
    control_write(ctx, "{\"error\":\"rate limited\"}", 429,
                  "\"extra_headers\": {\"Retry-After\": "
                  "\"Wed, 21 Oct 2015 07:28:00 GMT\"}");

    run_analyze(ctx, &cfg, &in, 0, &ro);

    CHECK(ctx, requests_since_reset(ctx) == 2, "畸形 Retry-After 仍按默认退避重试");
    CHECK(ctx, ro.elapsed_ms < 5000,
          "不按 HTTP-date 长时间等待（实测 %ld ms）", ro.elapsed_ms);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    return 0;
}

/* --- 23. 本地编辑不重新调用模型（依赖/评分/工时/外部条件/完成状态） --- */
static int sc_local_edits_offline(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    RunOutcome ro;
    char *content = load_fixture(ctx, "valid_tasks.json");
    char *env = make_envelope(content, "stop");
    int before;

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    cfg.mock_mode = 1;              /* 刻意用 mock：本场景只验证“本地编辑不发请求” */
    inputs_init(&in);

    /*
     * 第一步：先经真实 HTTP 路径拿到一个计划，让后续编辑有对象可改。
     * （一个场景内先跑一次网络调用，再用 mock 配置做编辑；编辑路径本身与网络无关。）
     */
    reset_request_count(ctx);
    {
        TsConfig net = cfg;
        net.mock_mode = 0;
        net.endpoint_url = ts_strdup(cfg.endpoint_url);
        net.model = ts_strdup(cfg.model);
        control_write(ctx, env, 200, NULL);
        run_analyze(ctx, &net, &in, 0, &ro);
        CHECK(ctx, g_last_result->ok == 1, "先取得一个真实计划（供本地编辑）");
        before = requests_since_reset(ctx);
        CHECK(ctx, before == 1, "取得计划用了 1 次调用（实际 %d）", before);
        ts_free(net.endpoint_url);
        ts_free(net.model);
    }

    /* 把计划装进 controller，模拟“界面里已有一份计划” */
    {
        TsController *c = ts_controller_create(&cfg);
        char err[512];
        int rc;

        CHECK(ctx, c != NULL, "创建控制器成功");
        if (c == NULL) { ts_config_free(&cfg); ts_inputs_free(&in); free(env); free(content); return 0; }

        ts_controller_set_user_request(c, "本地编辑测试");
        err[0] = '\0';
        CHECK(ctx, ts_controller_add_text(c, "本地编辑测试材料", NULL, err, sizeof(err)) == 0,
              "向控制器添加输入文段");

        /* 用 controller 的 mock 载入路径拿到计划（不发真实请求） */
        err[0] = '\0';
        CHECK(ctx, ts_controller_load_mock(c, err, sizeof(err)) == 0,
              "载入内置模拟计划（离线）");
        CHECK(ctx, ts_controller_plan(c) != NULL, "controller 中已有计划");
        ts_controller_recompute(c);

        /* 依赖、评分、工时、外部条件、完成状态：全部本地重算 */
        rc = ts_controller_set_impact(c, 0, 5);
        CHECK(ctx, rc == 0, "修改影响力（本地重算）成功");
        rc = ts_controller_set_urgency(c, 0, 5);
        CHECK(ctx, rc == 0, "修改紧迫性（本地重算）成功");
        rc = ts_controller_set_hours(c, 0, 1, 1.5);
        CHECK(ctx, rc == 0, "修改工时（本地重算）成功");
        rc = ts_controller_set_hours(c, 0, 0, 0.0);
        CHECK(ctx, rc == 0, "把工时改为未知（本地重算）成功");
        rc = ts_controller_set_name(c, 0, "改名后的任务");
        CHECK(ctx, rc == 0, "修改名称（本地重算）成功");
        rc = ts_controller_set_deadline(c, 0, "2026-12-31");
        CHECK(ctx, rc == 0, "修改截止时间（本地重算）成功");
        {
            const char *d[1];
            d[0] = "T2";
            rc = ts_controller_set_deps(c, 2, d, 1);
            CHECK(ctx, rc == 0, "修改依赖（本地重算）成功");
        }
        rc = ts_controller_set_precond_status(c, 5, 0, TS_PRECOND_MET);
        CHECK(ctx, rc == 0, "切换外部条件为已满足（本地重算）成功");
        rc = ts_controller_set_actual(c, 0, 1);
        CHECK(ctx, rc == 0, "标记完成（本地重算）成功");
        CHECK(ctx, ts_controller_schedule(c) != NULL, "标记完成后仍有排序结果");
        rc = ts_controller_set_actual(c, 0, 0);
        CHECK(ctx, rc == 0, "撤销完成（本地重算）成功");

        /* 导出也走本地路径 */
        {
            char err2[512];
            const char *p = "ts_test_http_edit.json";
            err2[0] = '\0';
            CHECK(ctx, ts_export_json(ts_controller_plan(c), ts_controller_schedule(c),
                                      ts_controller_status(c), ts_controller_config(c),
                                      p, err2, sizeof(err2)) == 0,
                  "编辑后导出 JSON 成功（本地）");
            _wremove(L"ts_test_http_edit.json");
        }

        ts_controller_destroy(c);
    }

    /* 关键断言：以上全部本地操作之后，服务端请求数没有增加 */
    CHECK(ctx, requests_since_reset(ctx) == before,
          "本地编辑与导出**没有**产生新的模型调用（请求数仍为 %d）", before);

    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* --- 24. 结构化时间表真正进入最终 HTTP messages（含派生视图与语义） --- */
static int sc_timetable_in_messages(Ctx *ctx)
{
    TsConfig cfg;
    TsInputs in;
    TsAnalyzeResult res;
    TsCancel cancel;
    char *content = load_fixture(ctx, "minimal_tasks.json");
    char *env = make_envelope(content, "stop");
    char *block;
    char path[800];
    char *trace;
    int generation;

    /*
     * 2026-10-20 周二：09:00–10:00 占用，其中 09:15–09:30 通过日期例外恢复可用。
     * 期望有效区间：[540,555) 占用、[555,570) 空闲、[570,600) 占用。
     */
    const char *payload =
        "{\"timetable\":{\"schemaVersion\":2,\"revision\":7,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"coverage\":{\"dateFrom\":\"2026-10-20\",\"dateTo\":\"2026-10-20\","
        "\"defaultState\":1},\"weekly\":[],"
        "\"dates\":[{\"state\":0,\"start\":540,\"end\":600,"
        "\"date\":\"2026-10-20\",\"title\":\"占用\"}]},"
        "\"effectiveTimetable\":{\"sourceRevision\":7,"
        "\"timezoneId\":\"Asia/Shanghai\",\"timezoneOffsetMinutes\":480,"
        "\"dateFrom\":\"2026-10-20\",\"dateTo\":\"2026-10-20\","
        "\"intervalSemantics\":\"[start,end), minutes since local midnight\","
        "\"days\":[{\"date\":\"2026-10-20\",\"intervals\":["
        "{\"start\":0,\"end\":540,\"state\":1,\"meaning\":\"free\"},"
        "{\"start\":540,\"end\":555,\"state\":0,\"meaning\":\"occupied\"},"
        "{\"start\":555,\"end\":570,\"state\":1,\"meaning\":\"free\"},"
        "{\"start\":570,\"end\":600,\"state\":0,\"meaning\":\"occupied\"},"
        "{\"start\":600,\"end\":1440,\"state\":1,\"meaning\":\"free\"}]}]}}";

    cfg_init(ctx, &cfg, 120000, 2 * 1024 * 1024, 1);
    inputs_init(&in);
    reset_request_count(ctx);
    control_write(ctx, env, 200, NULL);

    block = ts_constraints_timetable_block(payload);
    CHECK(ctx, block != NULL,
          "同源 timetable + effectiveTimetable 生成提示词区块");
    if (block == NULL) {
        ts_config_free(&cfg);
        ts_inputs_free(&in);
        free(env);
        free(content);
        return 0;
    }

    ts_analyze_result_init(&res);
    ts_cancel_init(&cancel);
    generation = ts_cancel_begin(&cancel);
    (void)ts_analyze_run_ex(&cfg, "请按本地时间表安排", block, &in, &cancel,
                            generation, NULL, NULL, &res);
    CHECK(ctx, res.ok == 1, "带结构化时间表的分析请求成功");
    CHECK(ctx, requests_since_reset(ctx) == 1, "只调用一次（实际 %d）",
          requests_since_reset(ctx));

    snprintf(path, sizeof(path), "%s\\mock_last_request.json", ctx->workdir);
    trace = read_file_utf8(path);
    CHECK(ctx, trace != NULL, "可读取模拟服务记录的最终请求摘要");
    if (trace != NULL) {
        CHECK(ctx, strstr(trace, "\"has_timetable_block\": true") != NULL,
              "最终 HTTP messages 含结构化时间表区块");
        CHECK(ctx, strstr(trace, "\"has_effective_timetable\": true") != NULL,
              "最终 HTTP messages 含派生 effectiveTimetable");
        CHECK(ctx, strstr(trace, "\"has_timetable_semantics\": true") != NULL,
              "最终 HTTP messages 的系统提示含时间表语义");
        CHECK(ctx, strstr(trace, "\"has_occupied_state\": true") != NULL,
              "state=0（占用）没有被当作空值过滤");
        CHECK(ctx, strstr(trace, "\"has_exact_minutes\": true") != NULL,
              "09:15 的精确分钟（555）保留，没有被 15 分钟格子取整");
        CHECK(ctx, strstr(trace, "\"has_override_free\": true") != NULL,
              "日期例外恢复的 free 进入最终 messages");
        free(trace);
    }

    ts_analyze_result_free(&res);
    ts_free(block);
    ts_config_free(&cfg);
    ts_inputs_free(&in);
    free(env);
    free(content);
    return 0;
}

/* ================================================================== */

static const Scenario kScenarios[] = {
    { "normal",                  "正常返回合法任务 JSON",              sc_normal },
    { "slow_reminder",           "超过提醒阈值仍未返回",               sc_slow_reminder },
    { "reminder_then_continue",  "选择继续等待后正常返回",             sc_reminder_then_continue },
    { "cancel_during_wait",      "等待期间取消",                       sc_cancel_during_wait },
    { "late_result_after_cancel","取消后服务端才返回",                 sc_late_result_after_cancel },
    { "response_during_prompt",  "提示框显示期间完整响应到达",         sc_response_during_prompt },
    { "auth_no_retry",           "401/403 不重试",                     sc_auth_no_retry },
    { "rate_limit_retry_after",  "429 + Retry-After",                  sc_rate_limit_retry_after },
    { "cancel_during_retry",     "429 退避期间取消",                   sc_cancel_during_retry_wait },
    { "server_error_retry",      "可重试的 5xx",                       sc_server_error_retry },
    { "client_error_no_retry",   "不可重试的 4xx",                     sc_client_error_no_retry },
    { "empty_body",              "空正文",                             sc_empty_body },
    { "empty_content_field",     "content 为空串",                     sc_empty_content_field },
    { "invalid_json",            "非法 JSON",                          sc_invalid_json },
    { "missing_required_fields", "缺失必需字段",                       sc_missing_required_fields },
    { "truncated",               "finish_reason=length",               sc_truncated },
    { "retry_then_success",      "可重试错误后重试成功",               sc_retry_then_success },
    { "repair_then_success",     "截断经一次修复解决",                 sc_repair_then_success },
    { "missing_then_repaired",   "缺字段经一次修复解决",               sc_missing_then_repaired },
    { "too_large",               "超过响应大小上限",                   sc_too_large },
    { "close_window_active",     "关闭窗口时请求仍在进行",             sc_close_window_active_request },
    { "network_drop",            "网络连接被切断",                     sc_network_drop },
    { "budget_zero",             "重试/修复预算为 0",                  sc_budget_zero },
    { "request_shape",           "请求构造与鉴权头",                   sc_request_shape },
    { "no_total_timeout",        "禁用总超时下的慢响应",               sc_no_total_timeout },
    { "chunked_response",        "响应分块到达",                       sc_chunked_response },
    { "rate_limit_default",      "429 无 Retry-After 的默认退避",      sc_rate_limit_default_backoff },
    { "malformed_retry_after",   "畸形 Retry-After 不被采信",          sc_malformed_retry_after },
    { "local_edits_offline",     "本地编辑/导出不再调用模型",          sc_local_edits_offline },
    { "timetable_in_messages",   "结构化时间表进入最终 messages",      sc_timetable_in_messages }
};

static const size_t kScenarioCount = sizeof(kScenarios) / sizeof(kScenarios[0]);

int main(int argc, char **argv)
{
    Ctx ctx;
    size_t i;
    int ran = 0;
    int failed_scenarios = 0;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 4) {
        printf("用法：ts_test_http <base_url> <workdir> <fixturedir> [scenario]\n");
        return 2;
    }
    memset(&ctx, 0, sizeof(ctx));
    snprintf(ctx.base_url, sizeof(ctx.base_url), "%s/v1/chat/completions", argv[1]);
    snprintf(ctx.workdir, sizeof(ctx.workdir), "%s", argv[2]);
    snprintf(ctx.fixture_dir, sizeof(ctx.fixture_dir), "%s", argv[3]);
    snprintf(ctx.control_path, sizeof(ctx.control_path), "%s\\mock_control.json", argv[2]);
    snprintf(ctx.count_path, sizeof(ctx.count_path), "%s\\mock_count.json", argv[2]);

    last_result_init();

    printf("=== TaskScheduler 本地 HTTP 集成测试 ===\n");
    printf("端点：%s\n", ctx.base_url);
    printf("工作目录：%s\n", ctx.workdir);
    printf("夹具目录：%s\n\n", ctx.fixture_dir);

    for (i = 0; i < kScenarioCount; i++) {
        int before;
        if (argc >= 5 && _stricmp(argv[4], kScenarios[i].name) != 0) {
            continue;
        }
        printf("-- 场景 %s：%s\n", kScenarios[i].name, kScenarios[i].desc);
        before = ctx.fails;
        kScenarios[i].fn(&ctx);
        ran++;
        printf("   [计数] 基线=%d 累计=%d 本场景=%d\n",
               ctx.requests_baseline, read_request_count_stable(&ctx),
               read_request_count_stable(&ctx) - ctx.requests_baseline);
        if (ctx.fails > before) {
            failed_scenarios++;
            printf("   => 场景失败\n");
        } else {
            printf("   => 场景通过\n");
        }
        printf("\n");
    }

    if (ran == 0) {
        printf("没有匹配的场景：%s\n", (argc >= 5) ? argv[4] : "(空)");
        last_result_free();
        return 2;
    }
    printf("=== 汇总：%d 个场景，%d 个场景失败，%d 项断言，%d 项失败 ===\n",
           ran, failed_scenarios, ctx.checks, ctx.fails);

    last_result_free();

    printf("=== 汇总：%d 个场景，%d 个场景失败，%d 项断言，%d 项失败 ===\n",
           ran, failed_scenarios, ctx.checks, ctx.fails);

    return (ctx.fails == 0) ? 0 : 1;
}
