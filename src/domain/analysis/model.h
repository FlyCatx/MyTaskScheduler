#ifndef TS_MODEL_H
#define TS_MODEL_H

/*
 * model.h — 模型调用：HTTP 请求、响应外壳解析、正文与用量提取、错误分类与重试判定。
 *
 * 主要函数：ts_model_call / ts_model_http、ts_model_extract_content / ts_model_extract_content_usage、
 * ts_model_kind_retryable、ts_model_available、ts_model_result_init / ts_model_result_free。
 */
#include <stddef.h>
#include "config.h"
#include "runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TsModelErrorKind {
    TS_MODEL_OK = 0,
    TS_MODEL_ERR_CANCELLED,   /* 用户取消（不重试） */
    TS_MODEL_ERR_AUTH,        /* 401/403 鉴权/权限（不重试） */
    TS_MODEL_ERR_CONFIG,      /* 400/404/422、URL 或配置错误（不重试） */
    TS_MODEL_ERR_RATE_LIMIT,  /* 429（可重试） */
    TS_MODEL_ERR_SERVER,      /* 5xx（部分可重试） */
    TS_MODEL_ERR_NETWORK,     /* 连接/超时/DNS 等（可重试） */
    TS_MODEL_ERR_TLS,         /* TLS 校验失败（不重试，属配置问题） */
    TS_MODEL_ERR_TOO_LARGE,   /* 响应超过大小上限（不重试） */
    TS_MODEL_ERR_EMPTY,       /* 正文为空（可请求修复） */
    TS_MODEL_ERR_TRUNCATED,   /* 输出被 max_tokens 截断（可请求修复） */
    TS_MODEL_ERR_PROTOCOL,    /* 响应外壳不符合约定（不重试） */
    TS_MODEL_ERR_MEMORY       /* 内存分配失败 */
} TsModelErrorKind;

typedef struct TsModelResult {
    int ok;              /* 1 = 成功拿到完整 JSON 正文 */
    char *body;          /* owned：成功时为模型输出的 JSON 正文 */
    size_t body_len;
    long http_status;    /* HTTP 状态码；mock 模式为 0 */
    long elapsed_ms;
    char *error;         /* owned 错误消息，成功时为 NULL */
    int error_kind;      /* TsModelErrorKind */
    int retryable;       /* 1 = 属于可重试的网络/服务端类错误 */
    long retry_after_ms; /* 429 的 Retry-After（毫秒）；0 表示未知 */

    /*
     * token 用量（来自响应的 usage 段；缺失时 usage_present = 0）。
     *
     * 为什么必须记录：思考模式下**思考 token 与正文共用 max_tokens 预算**，
     * 只看“输出被截断”这句话无法判断究竟是预算太小、还是材料本身太长。
     * reasoning_tokens 能把这件事从“猜”变成“量”。
     */
    long usage_prompt_tokens;      /* 输入 token = 缓存命中 + 未命中 */
    long usage_completion_tokens;  /* 输出 token 总数（**含**思考 token） */
    long usage_reasoning_tokens;   /* 其中“思考”消耗的 token */
    long usage_total_tokens;       /* 本次请求总 token */
    int  usage_present;            /* 1 = 响应里确实带了 usage 段 */
    int  finish_length;            /* 1 = finish_reason=length（被 token 上限截断） */
} TsModelResult;

const char *ts_model_error_kind_name(int kind);
int ts_model_kind_retryable(int kind);

/* 1 = 已编译 libcurl，可发起真实 HTTP；0 = 仅 mock 模式。 */
int ts_model_available(void);

void ts_model_result_init(TsModelResult *r);
void ts_model_result_free(TsModelResult *r);

/*
 * 调用模型。
 * - request_body / request_len：调用方拥有、构造好的 JSON 请求体，本函数不修改、不持有。
 * - cancel / generation：用于后台线程轮询取消；generation 由 ts_cancel_begin 产生。
 * - out：输出；无论成功失败都可用 ts_model_result_free 释放。
 * 返回 0 表示成功（out->ok == 1），非 0 表示失败（原因在 out->error）。
 */
int ts_model_call(const TsConfig *cfg,
                  const char *request_body, size_t request_len,
                  const TsCancel *cancel, int generation,
                  TsModelResult *out);

/* ------------------------------------------------------------------ */
/* 通用 HTTP 调用（供探针：模型发现 GET / 连通性测试 POST 使用）        */
/* ------------------------------------------------------------------ */

/*
 * 一个可以直接指定完整 URL、方法、超时覆盖的请求描述。
 *
 * 为什么需要它：探针要打的是 **完整的 models URL / chat URL**（不是固定的
 * endpoint_url），而且需要**独立的短超时**与可取消能力；正式分析的总超时
 * 策略（默认 0 = 不设）绝不能因此被改动。
 *
 * 安全约定（与 ts_model_call 完全一致，不因为是探针就放松）：
 *   - TLS 证书校验永不关闭；
 *   - api_key 为 NULL 时**不发送** Authorization 头（authMode=none 走这条）；
 *   - 响应大小上限、取消、错误分类、401/403 脱敏全部保留。
 */
typedef struct TsHttpRequest {
    const char *url;            /* 必填：完整 URL（不会被自动拼 /v1） */
    const char *method;         /* "GET" / "POST"；NULL = "GET" */
    const char *body;           /* POST 时的请求体；NULL = 无 */
    size_t body_len;
    const char *api_key;        /* NULL/空 = 不发送 Authorization */
    const char *ca_bundle_path; /* NULL = 按 cfg → 环境变量 → exe 同目录 解析 */
    long connect_timeout_ms;    /* 0 = 用 cfg->connect_timeout_ms */
    /*
     * 总超时覆盖：0 = 用 cfg->request_timeout_ms（正式分析默认 0 = 不设），
     * >0 = 本次覆盖为该值（探针使用）。
     */
    long timeout_ms;
    long max_response_bytes;    /* 0 = 用 cfg->max_response_bytes */
} TsHttpRequest;

/*
 * 执行一次通用 HTTP 调用。
 * cfg 必须非 NULL（用于默认超时/上限/CA 路径）。
 * 成功（HTTP 2xx）返回 0，out->body 为**原始响应体**（未做外壳解析），
 * out->http_status / elapsed_ms / retry_after_ms 可用。
 * 失败返回非 0，out->error_kind 为 TsModelErrorKind 分类。
 */
int ts_model_http(const TsConfig *cfg, const TsHttpRequest *req,
                  const TsCancel *cancel, int generation,
                  TsModelResult *out);

/*
 * 响应 usage 段的解析结果（可选出参，见 ts_model_extract_content）。
 * 全部字段在缺失时保持 0，present 表示响应里确实带了 usage。
 */
typedef struct TsTokenUsage {
    long prompt_tokens;
    long completion_tokens;   /* 含思考 token */
    long reasoning_tokens;
    long total_tokens;
    int  present;
} TsTokenUsage;

/*
 * 从 OpenAI 兼容 Chat Completions 响应外壳中提取正文。
 * 成功返回 0，写 *out_content（owned）与 *out_len。
 * 失败返回非 0，写 err，并通过 *out_kind 给出分类
 * （TS_MODEL_ERR_EMPTY / TS_MODEL_ERR_TRUNCATED / TS_MODEL_ERR_PROTOCOL 等）。
 * out_usage 可为 NULL；非 NULL 时无论成败都会填好（含 finish_reason=length 的情况），
 * 便于调用方在报错时给出“思考 token 用了多少”这类可执行信息。
 */
int ts_model_extract_content_usage(const char *response_json, size_t response_len,
                                   char **out_content, size_t *out_len,
                                   int *out_kind, char *err, size_t err_sz,
                                   TsTokenUsage *out_usage);

/*
 * 只要正文、不需要 token 用量的兼容入口（与上述函数同样语义）。
 */
int ts_model_extract_content(const char *response_json, size_t response_len,
                             char **out_content, size_t *out_len,
                             int *out_kind, char *err, size_t err_sz);

/*
 * Retry-After 响应头的解析（修复 8 的可离线测试入口）。
 *
 * 只接受“秒”形式的十进制整数（HTTP-date 形式返回 0，交由默认退避处理）。
 * 合法范围 1..3600 秒；其余（0、负数、非数字、超出范围）一律返回 0，
 * 由调用方退回默认退避，绝不因为一个畸形头部而无限等待。
 *
 * header_line / len 为 libcurl HEADERFUNCTION 收到的**单行**原始字节
 * （含行尾 CRLF，允许大小写任意、冒号后允许空白）。
 * 返回毫秒数；0 表示“无可用的 Retry-After”。
 */
long ts_model_parse_retry_after(const char *header_line, size_t len);

/*
 * HTTP 状态码是否属于“值得重试一次”的范围：
 * 429、500、502、503、504。其余 4xx/5xx 与 2xx/3xx 都返回 0。
 */
int ts_model_http_status_retryable(long http_status);

/*
 * 端点摘要：只保留 scheme://host[:port]/path，
 * 丢弃 userinfo、查询串与 fragment（可能是 ?api_key=... 之类的敏感参数）。
 * 结果可安全写入界面、导出与日志。out 始终以 NUL 结尾，绝不返回 NULL。
 */
const char *ts_model_sanitize_endpoint(const char *url, char *out, size_t out_sz);

/*
 * 诊断文本脱敏（就地修改 text，缓冲区必须可写）。
 * 替换 Authorization/Bearer 凭证、敏感 JSON 字段值，以及仍然长得像凭证的长 token；
 * HTTP 状态码、错误码、请求 ID 与普通描述原样保留。
 * 绝不回显密钥原文；内存不足时整段省略而不是冒险泄露。
 */
void ts_model_diag_redact(char *text);

#ifdef __cplusplus
}
#endif

#endif /* TS_MODEL_H */

