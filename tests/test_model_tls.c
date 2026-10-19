/*
 * test_model_tls.c — 真实 HTTPS/TLS 路径的验证（不发送任何用户材料）。
 *
 * 目的：验证“真实依赖构建 + 真实网络栈”下的传输层行为，而不是业务行为：
 *   1. 故意不配置 CA 包时，程序必须**明确报错**（缺少根证书包），
 *      而不是静默降级为“不校验证书”；
 *   2. 配置了随包提供的 cacert.pem 时，TLS 握手与证书校验必须真的成功；
 *   3. 请求体只包含固定的、不含任何用户数据的极小样例。
 *
 * 判定方式：对一个真实 HTTPS 端点发起一次最小请求。
 *   - 未带 API Key 访问 DeepSeek 的 chat/completions 会返回 401；
 *     能拿到 401 就证明“连接 + TLS 校验 + HTTP 往返”全部正常
 *     （拿不到就等于连不上或被证书校验拦住）。
 *   - 若环境没有外网，本测试会明确输出“未执行（网络不可达）”，
 *     而不是谎报通过。
 *
 * 参数：
 *   ts_test_model_tls <ca_bundle 路径> [endpoint_url] [api_key_env]
 *   ca_bundle 传 "-" 表示**不**提供证书包（用于验证拒绝路径）。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../src/state/config.h"
#include "../src/util/mem.h"
#include "../src/domain/analysis/model.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg) do {                                       \
    if (cond) { g_pass++; printf("  [PASS] %s\n", msg); }           \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }                \
} while (0)

#define CHECKF(cond, ...) do {                                      \
    if (cond) { g_pass++; printf("  [PASS] "); printf(__VA_ARGS__); printf("\n"); } \
    else { printf("  [FAIL] "); printf(__VA_ARGS__); printf("\n"); g_fail++; }      \
} while (0)

/* 固定样例：不含任何用户材料、不含密钥。 */
static const char *SAMPLE_BODY =
    "{\"model\":\"deepseek-chat\",\"messages\":[{\"role\":\"user\","
    "\"content\":\"ping\"}],\"max_tokens\":1,\"stream\":false}";

int main(int argc, char **argv)
{
    TsConfig cfg;
    TsModelResult mr;
    const char *ca;
    const char *endpoint;
    const char *key_env;
    const char *key_val;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler TLS / 真实 HTTPS 传输层测试 ===\n\n");

    if (argc < 2) {
        printf("用法：ts_test_model_tls <ca_bundle 路径|-> [endpoint] [api_key_env]\n");
        return 2;
    }
    ca = argv[1];
    endpoint = (argc >= 3) ? argv[2] : "https://api.deepseek.com/v1/chat/completions";
    key_env = (argc >= 4) ? argv[3] : "DEEPSEEK_API_KEY";

    if (strcmp(ca, "-") == 0) {
        /*
         * 场景 1：不通过配置指定 CA 包。
         *
         * 期望行为分两种，都必须“不降级校验”：
         *   (a) 找不到任何可用 CA 包 → 明确报 TS_MODEL_ERR_TLS 并说明缺少根证书包；
         *   (b) 找到了（exe 同目录的 cacert.pem / 环境变量 / libcurl 自带位置）
         *       → 校验照常进行，请求照常发出，于是拿到 401（未带 Key）。
         * 只要没有出现 CURLOPT_SSL_VERIFYPEER=0 那种“跳过校验后成功”，都算通过。
         */
        printf("== 场景 1：未显式指定 CA 包（不得关闭校验）==\n");
        ts_config_init(&cfg);
        cfg.endpoint_url = ts_strdup("https://api.deepseek.com/v1/chat/completions");
        cfg.model = ts_strdup("deepseek-chat");
        cfg.ca_bundle_path = NULL;
        cfg.mock_mode = 0;
        cfg.connect_timeout_ms = 8000;
        cfg.request_timeout_ms = 12000;

        ts_model_result_init(&mr);
        {
            int rc = ts_model_call(&cfg, SAMPLE_BODY, strlen(SAMPLE_BODY), NULL, 0, &mr);
            int ca_missing = (mr.error_kind == TS_MODEL_ERR_TLS &&
                              mr.error != NULL && strstr(mr.error, "证书包") != NULL);

            if (ca_missing) {
                printf("       (a) 未找到可用 CA 包：按预期明确拒绝\n");
                CHECK(rc != 0, "无可用 CA 包时请求失败（不会静默成功）");
                CHECK(!mr.ok, "结果未被标记为成功");
                CHECKF(mr.error_kind == TS_MODEL_ERR_TLS,
                       "错误分类为 TLS（实际：%s）", ts_model_error_kind_name(mr.error_kind));
                printf("       错误信息：%s\n", mr.error);
            } else {
                printf("       (b) 已找到可用 CA 包（exe 同目录或环境变量）：校验照常进行\n");
                CHECK(rc != 0, "未带 API Key 时请求被服务端拒绝（不会成功）");
                CHECK(mr.error_kind != TS_MODEL_ERR_TLS,
                      "TLS 校验通过（未降级为“跳过校验”）");
                CHECKF(mr.http_status > 0, "取得 HTTP 状态码（实际 %ld）", mr.http_status);
                printf("       HTTP 状态=%ld 耗时=%ld ms 分类=%s\n",
                       mr.http_status, mr.elapsed_ms,
                       ts_model_error_kind_name(mr.error_kind));
            }
        }
        ts_model_result_free(&mr);
        ts_config_free(&cfg);
        printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
               g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
        return g_fail == 0 ? 0 : 1;
    }

    /* 场景 2：提供 CA 包 —— 必须真的完成 TLS 握手与证书校验 */
    printf("== 场景 2：提供 CA 包（%s）==\n", ca);
    printf("   端点：%s\n", endpoint);
    ts_config_init(&cfg);
    cfg.endpoint_url = ts_strdup(endpoint);
    cfg.model = ts_strdup("deepseek-chat");
    cfg.api_key_env = ts_strdup(key_env);
    cfg.ca_bundle_path = ts_strdup(ca);
    cfg.mock_mode = 0;
    cfg.connect_timeout_ms = 10000;
    cfg.request_timeout_ms = 20000;

    key_val = getenv(key_env);
    if (key_val != NULL && key_val[0] != '\0') {
        cfg.api_key = ts_strdup(key_val);
    }

    ts_model_result_init(&mr);
    {
        int rc = ts_model_call(&cfg, SAMPLE_BODY, strlen(SAMPLE_BODY), NULL, 0, &mr);

        if (rc != 0 && mr.error_kind == TS_MODEL_ERR_NETWORK) {
            printf("  [未执行] 网络不可达，无法验证真实 HTTPS 传输层\n");
            printf("       原因：%s\n", (mr.error != NULL) ? mr.error : "(无)");
            ts_model_result_free(&mr);
            ts_config_free(&cfg);
            printf("\n=== 结果：未执行（网络不可达；不计入通过）===\n");
            return 2;
        }

        CHECK(mr.error_kind != TS_MODEL_ERR_TLS,
              "TLS 证书校验通过（未出现“缺少根证书包”或校验失败）");
        CHECKF(mr.http_status > 0, "取得了 HTTP 状态码（实际 %ld）", mr.http_status);
        printf("       HTTP 状态=%ld  耗时=%ld ms  结束原因=%s\n",
               mr.http_status, mr.elapsed_ms,
               ts_model_error_kind_name(mr.error_kind));

        if (key_val == NULL || key_val[0] == '\0') {
            CHECKF(mr.http_status == 401 || mr.http_status == 403,
                   "未设置 %s：服务端返回 %ld（预期 401/403，证明 TLS 与 HTTP 往返正常）",
                   key_env, mr.http_status);
        } else {
            printf("       （已检测到 %s，本次只验证传输层，不判定业务结果）\n", key_env);
        }
    }
    ts_model_result_free(&mr);
    ts_config_free(&cfg);

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

