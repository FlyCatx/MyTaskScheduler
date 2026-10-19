/*
 * model.c — 模型调用与响应解析（含离线 mock 响应）。
 *
 * 主要函数：ts_model_call、ts_model_http、ts_model_extract_content、ts_model_extract_content_usage、
 * ts_model_kind_retryable、ts_model_available。
 */

#include "model.h"
#include "mem.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"

#if defined(TS_HAVE_CURL)
#include <curl/curl.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

/* ------------------------------------------------------------------ */
/* 内置模拟分析响应（mock_mode = true）                                */
/* ------------------------------------------------------------------ */

static const char *const MOCK_JSON =
    "{\n"
    "  \"schema_version\": \"1.0\",\n"
    "  \"tasks\": [\n"
    "    {\n"
    "      \"id\": \"T1\",\n"
    "      \"name\": \"整理需求文档\",\n"
    "      \"depends_on\": [],\n"
    "      \"preconditions\": [\n"
    "        { \"description\": \"已获得原始需求材料\", \"status\": \"met\" }\n"
    "      ],\n"
    "      \"steps\": [\"通读需求材料\", \"列出任务与依赖清单\"],\n"
    "      \"urgency\": 3,\n"
    "      \"urgency_reason\": \"无外部截止压力，属于前期基础工作\",\n"
    "      \"impact\": 4,\n"
    "      \"impact_reason\": \"后续所有拆解都依赖清晰的文档\",\n"
    "      \"estimated_hours\": 2.0,\n"
    "      \"estimate_reason\": \"材料已齐备，整理约需 2 小时\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落1\"]\n"
    "    },\n"
    "    {\n"
    "      \"id\": \"T2\",\n"
    "      \"name\": \"搭建项目骨架\",\n"
    "      \"depends_on\": [\"T1\"],\n"
    "      \"preconditions\": [],\n"
    "      \"steps\": [\"创建目录结构\", \"编写 CMakeLists.txt\", \"接入 cJSON 与 libcurl\"],\n"
    "      \"urgency\": 4,\n"
    "      \"urgency_reason\": \"是多数后续模块的前置\",\n"
    "      \"impact\": 5,\n"
    "      \"impact_reason\": \"决定整体工程质量与构建方式\",\n"
    "      \"estimated_hours\": 4.0,\n"
    "      \"estimate_reason\": \"包含依赖接入与构建验证\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落2\"]\n"
    "    },\n"
    "    {\n"
    "      \"id\": \"T3\",\n"
    "      \"name\": \"实现配置模块\",\n"
    "      \"depends_on\": [\"T2\"],\n"
    "      \"preconditions\": [],\n"
    "      \"steps\": [\"定义配置结构\", \"用 cJSON 解析配置文件\", \"读取环境变量 API Key\"],\n"
    "      \"urgency\": 4,\n"
    "      \"urgency_reason\": \"后续通信与校验都依赖配置\",\n"
    "      \"impact\": 4,\n"
    "      \"impact_reason\": \"配置是云端/本地切换的开关\",\n"
    "      \"estimated_hours\": 3.0,\n"
    "      \"estimate_reason\": \"字段校验逻辑较多\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落3\"]\n"
    "    },\n"
    "    {\n"
    "      \"id\": \"T4\",\n"
    "      \"name\": \"实现输入模块\",\n"
    "      \"depends_on\": [\"T2\"],\n"
    "      \"preconditions\": [],\n"
    "      \"steps\": [\"文件读取与编码检查\", \"文段输入\", \"来源编号\"],\n"
    "      \"urgency\": 3,\n"
    "      \"urgency_reason\": \"可与配置模块并行\",\n"
    "      \"impact\": 3,\n"
    "      \"impact_reason\": \"决定输入数据的完整性\",\n"
    "      \"estimated_hours\": 2.0,\n"
    "      \"estimate_reason\": \"逻辑相对直接\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落4\"]\n"
    "    },\n"
    "    {\n"
    "      \"id\": \"T5\",\n"
    "      \"name\": \"实现评分与调度\",\n"
    "      \"depends_on\": [\"T3\", \"T4\"],\n"
    "      \"preconditions\": [],\n"
    "      \"steps\": [\"依赖图与分层\", \"五维评分\", \"带优先级拓扑调度\", \"生成解释\"],\n"
    "      \"urgency\": 5,\n"
    "      \"urgency_reason\": \"是整个工具的核心价值\",\n"
    "      \"impact\": 5,\n"
    "      \"impact_reason\": \"直接决定推荐顺序的质量\",\n"
    "      \"estimated_hours\": 6.0,\n"
    "      \"estimate_reason\": \"算法与可解释性实现工作量最大\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落5\"]\n"
    "    },\n"
    "    {\n"
    "      \"id\": \"T6\",\n"
    "      \"name\": \"云端 API 联调\",\n"
    "      \"depends_on\": [\"T2\"],\n"
    "      \"preconditions\": [\n"
    "        { \"description\": \"已取得可用的 API Key\", \"status\": \"unmet\" }\n"
    "      ],\n"
    "      \"steps\": [\"配置 endpoint 与密钥\", \"发起真实请求\", \"处理错误与重试\"],\n"
    "      \"urgency\": 2,\n"
    "      \"urgency_reason\": \"可在本地 mock 验证后延后\",\n"
    "      \"impact\": 3,\n"
    "      \"impact_reason\": \"真实模型结果仍需联调确认\",\n"
    "      \"estimated_hours\": null,\n"
    "      \"estimate_reason\": \"取决于网络与接口稳定性，暂无法估计\",\n"
    "      \"deadline\": null,\n"
    "      \"source_refs\": [\"文件1:段落6\"]\n"
    "    }\n"
    "  ],\n"
    "  \"assumptions\": [\n"
    "    \"假设材料中描述的即为全部待办任务\"\n"
    "  ],\n"
    "  \"questions\": [\n"
    "    \"API Key 何时能够就绪？\"\n"
    "  ],\n"
    "  \"suggested_order\": [\"T1\", \"T2\", \"T3\", \"T4\", \"T5\", \"T6\"]\n"
    "}\n";

/* ------------------------------------------------------------------ */
/* 错误分类                                                            */
/* ------------------------------------------------------------------ */

const char *ts_model_error_kind_name(int kind)
{
    switch (kind) {
    case TS_MODEL_OK:             return "成功";
    case TS_MODEL_ERR_CANCELLED:  return "已取消";
    case TS_MODEL_ERR_AUTH:       return "鉴权失败";
    case TS_MODEL_ERR_CONFIG:     return "请求或配置错误";
    case TS_MODEL_ERR_RATE_LIMIT: return "触发限流(429)";
    case TS_MODEL_ERR_SERVER:     return "服务端错误(5xx)";
    case TS_MODEL_ERR_NETWORK:    return "网络错误";
    case TS_MODEL_ERR_TLS:        return "TLS 校验失败";
    case TS_MODEL_ERR_TOO_LARGE:  return "响应超过大小上限";
    case TS_MODEL_ERR_EMPTY:      return "模型正文为空";
    case TS_MODEL_ERR_TRUNCATED:  return "模型输出被截断";
    case TS_MODEL_ERR_PROTOCOL:   return "响应结构不符合约定";
    case TS_MODEL_ERR_MEMORY:     return "内存分配失败";
    default:                      return "未知错误";
    }
}

int ts_model_kind_retryable(int kind)
{
    return kind == TS_MODEL_ERR_RATE_LIMIT ||
           kind == TS_MODEL_ERR_SERVER ||
           kind == TS_MODEL_ERR_NETWORK;
}

int ts_model_available(void)
{
#if defined(TS_HAVE_CURL)
    return 1;
#else
    return 0;
#endif
}

/* ------------------------------------------------------------------ */
/* 诊断输出脱敏与端点摘要                                              */
/* ------------------------------------------------------------------ */

/*
 * 端点摘要：只保留 scheme://host[:port]/path。
 *
 * 明确丢弃：
 *   - userinfo（user:password@）；
 *   - 查询串（可能是 ?api_key=... 之类的敏感参数）；
 *   - fragment。
 * 因此本函数的结果可以安全地写进界面、导出与日志。
 * 缓冲区过小或参数为空时返回 ""（绝不返回 NULL，调用方可直接格式化）。
 */
const char *ts_model_sanitize_endpoint(const char *url, char *out, size_t out_sz)
{
    const char *p;
    const char *q;
    size_t n;

    if (out == NULL || out_sz == 0) return "";
    out[0] = '\0';
    if (url == NULL || url[0] == '\0') return out;

    p = strstr(url, "://");
    p = (p != NULL) ? (p + 3) : url;

    /* 丢弃 userinfo：最后一段 '@' 之前的部分 */
    {
        const char *at = NULL;
        const char *r;
        for (r = p; *r != '\0'; r++) {
            if (*r == '@') { at = r; continue; }
            if (*r == '/' || *r == '?' || *r == '#') break;
        }
        if (at != NULL) p = at + 1;
    }

    /* 只取到 path 结束（丢弃查询串与 fragment） */
    q = p;
    while (*q != '\0' && *q != '?' && *q != '#') q++;
    n = (size_t)(q - p);
    if (n >= out_sz) n = out_sz - 1;
    memcpy(out, p, n);
    out[n] = '\0';
    return out;
}

/* 密钥名（出现在 JSON 里的敏感字段）：命中后其字符串值整体替换。 */
static int diag_sensitive_key(const char *k, size_t n)
{
    static const char *const names[] = {
        "api_key", "apikey", "api-key", "authorization", "auth",
        "key", "token", "access_token", "secret", "password", "bearer"
    };
    size_t i;
    size_t j;
    if (n == 0) return 0;
    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        size_t m = strlen(names[i]);
        if (m != n) continue;
        for (j = 0; j < n; j++) {
            char a = k[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (a != names[i][j]) break;
        }
        if (j == n) return 1;
    }
    return 0;
}

/* 形如 sk-xxxx / 很长的无空白 token：长度达到阈值才整体脱敏。 */
static int diag_token_like(const char *t, size_t n)
{
    size_t i;
    if (n >= 6 && t[0] == 's' && t[1] == 'k' && t[2] == '-') return 1;
    if (n < 20) return 0;
    for (i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)t[i];
        int ok = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') ||
                 (ch >= 'A' && ch <= 'Z') ||
                 ch == '-' || ch == '_' || ch == '.' || ch == '~' ||
                 ch == '+' || ch == '/' || ch == '=';
        if (!ok) return 0;
    }
    return 1;
}

static int diag_token_char(unsigned char ch)
{
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') ||
           (ch >= 'A' && ch <= 'Z') ||
           ch == '-' || ch == '_' || ch == '.' || ch == '~' ||
           ch == '+' || ch == '/' || ch == '=';
}

/*
 * 诊断文本脱敏（就地，缓冲区必须可写且以 NUL 结尾）。
 *
 * 处理三类敏感内容，其余文字（HTTP 状态码、错误码、请求 ID、普通错误描述）
 * 原样保留，确保诊断信息仍然有用：
 *   1. "Authorization: ..." 或 "Bearer <token>" 之后的凭证；
 *   2. 敏感 JSON 字段（api_key / token / password ...）的字符串值；
 *   3. 仍然长得像凭证的独立 token（sk- 前缀，或 ≥20 位的长串）。
 * 被替换的部分统一用占位串替代，绝不回显原文。
 *
 * 长度安全：输出缓冲区按“原长度 + 每处替换可能增加的上限”分配，
 * 且写入前逐一检查剩余空间；最坏情况只是少替换一处，
 * 绝不会写越界，也不会因为替换把文本变得更长而截断诊断。
 */
void ts_model_diag_redact(char *text)
{
    static const char MARK_AUTH[] = "<<已脱敏>>";  /* 9 字节 */
    static const char MARK_VAL[] = "\"***\"";       /* 5 字节，用于 JSON 值 */
    char *buf;
    size_t len;
    size_t cap;
    size_t i = 0;
    size_t o = 0;

    if (text == NULL || text[0] == '\0') return;
    len = strlen(text);
    cap = len * 2 + 16;   /* 替换只会发生在“有内容”的位置，2 倍余量足够 */
    buf = (char *)malloc(cap);
    if (buf == NULL) {
        /* 分配失败时宁可丢掉整段而不冒险泄露 */
        strcpy(text, "<诊断文本因内存不足已省略>");
        return;
    }

    while (i < len) {
        unsigned char ch = (unsigned char)text[i];
        int started = 0;

        /* --- Authorization 头：整段值替换 --- */
        if ((ch == 'A' || ch == 'a') && i + 13 <= len) {
            static const char an[] = "authorization";
            size_t k = 0;
            while (k < 13 && i + k < len) {
                char a = text[i + k];
                if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
                if (a != an[k]) break;
                k++;
            }
            if (k == 13) {
                size_t j = i + 13;
                size_t m = 0;
                /* 跳过冒号与空白，定位凭证本身 */
                while (j < len && (text[j] == ':' || text[j] == ' ' || text[j] == '\t')) j++;
                if (j < len && text[j] == '"') {
                    /* 引号包裹的凭证：整段字符串替换 */
                    size_t ve = j + 1;
                    while (ve < len && text[ve] != '"' && text[ve] != '\n' && text[ve] != '\r') ve++;
                    if (ve < len && text[ve] == '"') ve++;
                    j = ve;
                } else {
                    /*
                     * 只吃掉凭证 token 本身（含 Bearer 前缀），
                     * 不要吞掉同一行后面的普通文字——否则诊断信息会被破坏。
                     */
                    size_t ve = j;
                    while (ve < len && diag_token_char((unsigned char)text[ve])) ve++;
                    j = ve;
                }
                if (o + sizeof(MARK_AUTH) <= cap) {
                    while (m < sizeof(MARK_AUTH) - 1) buf[o++] = MARK_AUTH[m++];
                    i = j;
                    continue;
                }
            }
        }

        /* --- 值引导符：根据前面的 JSON 键或 Bearer 决定是否替换值 --- */
        if (ch == ':' || ch == '=' || ch == ' ' || ch == '\t') {
            size_t j = i + 1;
            while (j < len && (text[j] == ' ' || text[j] == '\t')) j++;
            if (j < len && text[j] == '"') {
                size_t vs = j + 1;
                size_t ve = vs;
                int sens = 0;
                while (ve < len && text[ve] != '"' && text[ve] != '\n' && text[ve] != '\r') ve++;
                if (ve > vs) {
                    size_t ke = i;
                    size_t ks;
                    while (ke > 0 && (text[ke - 1] == ' ' || text[ke - 1] == '\t')) ke--;
                    if (ke > 0 && text[ke - 1] == '"') {
                        ke--;
                        ks = ke;
                        while (ks > 0 && text[ks - 1] != '"') ks--;
                        if (ks < ke) sens = diag_sensitive_key(text + ks, ke - ks);
                    }
                    if (!sens && j >= 6) {
                        static const char be[] = "bearer";
                        size_t q = 0;
                        while (q < 6) {
                            char a = text[j - 6 + q];
                            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
                            if (a != be[q]) break;
                            q++;
                        }
                        if (q == 6) sens = 1;
                    }
                    if (sens && o + sizeof(MARK_VAL) <= cap) {
                        /* 保留外层引号：输出 "***" 而不是裸占位符 */
                        size_t m = 0;
                        while (m < sizeof(MARK_VAL) - 1) buf[o++] = MARK_VAL[m++];
                        i = ve + 1;
                        continue;
                    }
                }
            }
        }

        /* --- 裸 token：sk- 前缀，或很长的无空白串 --- */
        if (diag_token_char(ch)) {
            size_t j = i;
            while (j < len && diag_token_char((unsigned char)text[j])) j++;
            if (i > 0) {
                char prev = text[i - 1];
                if (prev == ':' || prev == '=' || prev == ' ' || prev == '"' ||
                    prev == '\'' || prev == '/') {
                    started = 1;
                }
            }
            if (started && diag_token_like(text + i, j - i) &&
                o + sizeof(MARK_AUTH) <= cap) {
                size_t m = 0;
                while (m < sizeof(MARK_AUTH) - 1) buf[o++] = MARK_AUTH[m++];
                i = j;
                continue;
            }
        }

        buf[o++] = (char)ch;
        i++;
    }

    buf[o] = '\0';
    memcpy(text, buf, o + 1);
    free(buf);
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

void ts_model_result_init(TsModelResult *r)
{
    if (r != NULL) {
        memset(r, 0, sizeof(*r));
    }
}

void ts_model_result_free(TsModelResult *r)
{
    if (r == NULL) {
        return;
    }
    ts_free(r->body);
    ts_free(r->error);
    memset(r, 0, sizeof(*r));
}

/* ------------------------------------------------------------------ */
/* 响应外壳解析                                                        */
/* ------------------------------------------------------------------ */

/* 读一个整数型 JSON 字段；不是数字时返回 def。 */
static long usage_long(const cJSON *o, const char *key, long def)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsNumber(it)) return def;
    return (long)it->valuedouble;
}

/*
 * 解析响应的 usage 段（含 completion_tokens_details.reasoning_tokens）。
 * 缺字段一律留 0，不报错——usage 属于可选的诊断信息，不能因为缺少它就让请求失败。
 */
static void parse_usage(const cJSON *root, TsTokenUsage *u)
{
    const cJSON *usage;
    const cJSON *details;

    if (u == NULL) return;
    memset(u, 0, sizeof(*u));
    if (root == NULL) return;

    usage = cJSON_GetObjectItemCaseSensitive(root, "usage");
    if (usage == NULL || !cJSON_IsObject(usage)) return;

    u->present = 1;
    u->prompt_tokens     = usage_long(usage, "prompt_tokens", 0);
    u->completion_tokens = usage_long(usage, "completion_tokens", 0);
    u->total_tokens      = usage_long(usage, "total_tokens", 0);

    details = cJSON_GetObjectItemCaseSensitive(usage, "completion_tokens_details");
    if (details != NULL && cJSON_IsObject(details)) {
        u->reasoning_tokens = usage_long(details, "reasoning_tokens", 0);
    }
}

int ts_model_extract_content_usage(const char *response_json, size_t response_len,
                                   char **out_content, size_t *out_len,
                                   int *out_kind, char *err, size_t err_sz,
                                   TsTokenUsage *out_usage)
{
    cJSON *root = NULL;
    const cJSON *choices;
    const cJSON *c0;
    const cJSON *msg;
    const cJSON *content;
    const cJSON *finish;
    const char *s;
    int rc = 1;

    if (out_usage != NULL) memset(out_usage, 0, sizeof(*out_usage));
    if (out_content == NULL) {           /* 出参必须有地方放正文 */
        if (out_kind != NULL) *out_kind = TS_MODEL_ERR_CONFIG;
        snprintf(err, err_sz, "内部调用错误：out_content 为空");
        return 1;
    }
    *out_content = NULL;
    if (out_len != NULL) *out_len = 0;
    if (out_kind != NULL) *out_kind = TS_MODEL_ERR_PROTOCOL;

    if (response_json == NULL || response_len == 0) {
        if (out_kind != NULL) *out_kind = TS_MODEL_ERR_EMPTY;
        snprintf(err, err_sz, "模型响应正文为空");
        return 1;
    }

    root = cJSON_Parse(response_json);
    if (root == NULL) {
        snprintf(err, err_sz, "模型响应不是合法 JSON：%s",
                 cJSON_GetErrorPtr() != NULL ? cJSON_GetErrorPtr() : "未知错误");
        goto done;
    }

    /* usage 与 choices 无关，先解析：后面报错时也要能带上 token 用量 */
    parse_usage(root, out_usage);

    choices = cJSON_GetObjectItemCaseSensitive(root, "choices");
    if (choices == NULL || !cJSON_IsArray(choices) || cJSON_GetArraySize(choices) < 1) {
        snprintf(err, err_sz, "响应缺少 choices 数组");
        goto done;
    }
    c0 = cJSON_GetArrayItem(choices, 0);
    if (c0 == NULL || !cJSON_IsObject(c0)) {
        snprintf(err, err_sz, "响应 choices[0] 不是对象");
        goto done;
    }
    msg = cJSON_GetObjectItemCaseSensitive(c0, "message");
    if (msg == NULL || !cJSON_IsObject(msg)) {
        snprintf(err, err_sz, "响应缺少 choices[0].message");
        goto done;
    }
    content = cJSON_GetObjectItemCaseSensitive(msg, "content");
    if (content == NULL || cJSON_IsNull(content)) {
        if (out_kind != NULL) *out_kind = TS_MODEL_ERR_EMPTY;
        snprintf(err, err_sz, "模型返回正文为空");
        goto done;
    }
    if (!cJSON_IsString(content)) {
        snprintf(err, err_sz, "choices[0].message.content 不是字符串");
        goto done;
    }
    s = cJSON_GetStringValue(content);
    if (s == NULL || s[0] == '\0') {
        if (out_kind != NULL) *out_kind = TS_MODEL_ERR_EMPTY;
        snprintf(err, err_sz, "模型返回正文为空");
        goto done;
    }

    finish = cJSON_GetObjectItemCaseSensitive(c0, "finish_reason");
    if (finish != NULL && cJSON_IsString(finish)) {
        const char *fr = cJSON_GetStringValue(finish);
        if (fr != NULL && strcmp(fr, "length") == 0) {
            if (out_kind != NULL) *out_kind = TS_MODEL_ERR_TRUNCATED;
            /*
             * 报错信息必须带上 token 用量：思考模式下思考 token 与正文共用
             * max_tokens 预算，只有把“思考用了多少”写出来，用户才能判断
             * 究竟是预算太小、还是材料本身太长。没有 usage 时退回通用说明。
             */
            if (out_usage != NULL && out_usage->present) {
                snprintf(err, err_sz,
                         "模型输出被截断（finish_reason=length）：输出共 %ld token，"
                         "其中思考 %ld token；输入 %ld token。思考 token 与正文共用 "
                         "max_tokens 预算，请提高 max_output_tokens（或减少输入）",
                         out_usage->completion_tokens,
                         out_usage->reasoning_tokens,
                         out_usage->prompt_tokens);
            } else {
                snprintf(err, err_sz,
                         "模型输出被截断（finish_reason=length，可能达到 max_tokens；"
                         "响应未提供 usage，无法给出 token 明细）");
            }
            goto done;
        }
    }

    *out_content = ts_strdup(s);
    if (*out_content == NULL) {
        if (out_kind != NULL) *out_kind = TS_MODEL_ERR_MEMORY;
        snprintf(err, err_sz, "内存分配失败");
        goto done;
    }
    if (out_len != NULL) *out_len = strlen(*out_content);
    if (out_kind != NULL) *out_kind = TS_MODEL_OK;
    rc = 0;

done:
    if (root != NULL) cJSON_Delete(root);
    return rc;
}

/* 兼容入口：只要正文，不要 token 用量。 */
int ts_model_extract_content(const char *response_json, size_t response_len,
                             char **out_content, size_t *out_len,
                             int *out_kind, char *err, size_t err_sz)
{
    return ts_model_extract_content_usage(response_json, response_len,
                                          out_content, out_len,
                                          out_kind, err, err_sz, NULL);
}

/* ------------------------------------------------------------------ */
/* 真实 HTTP（libcurl multi）                                          */
/* ------------------------------------------------------------------ */

#if defined(TS_HAVE_CURL)

typedef struct HttpCtx {
    char *data;
    size_t len;
    size_t cap;
    size_t limit;
    int too_large;
    long retry_after_ms;
} HttpCtx;

/*
 * libcurl 全局初始化必须在使用任何 curl 函数之前完成，且在多线程下只能执行一次。
 * 用 Windows 的 InitOnce 保证线程安全（工作线程可能并发调用）。
 *
 * 重要：InitOnceExecuteOnce 的 *Context 低 INIT_ONCE_CTX_RESERVED_BITS(=2) 位由系统保留，
 * 不能用来存放小整数——实测向 *Context 写入 1/2/3 会直接以 0xC00000F1 终止进程
 * （写入 4/8/16 等低两位为零的值才安全）。
 * 因此这里【不写 *Context】，改用【回调返回值】报告初始化成功与否：
 * 回调返回 FALSE 时 InitOnceExecuteOnce 返回 FALSE，且该次初始化视为失败、允许重试。
 */
static BOOL CALLBACK curl_init_once_cb(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    (void)once;
    (void)param;
    (void)ctx;  /* 绝不写入：低位保留位必须保持为零 */
    return (curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK) ? TRUE : FALSE;
}

/* ------------------------------------------------------------------ */
/* TLS 根证书包解析（只做一次，线程安全）                              */
/* ------------------------------------------------------------------ */

typedef struct CaSearch {
    const TsConfig *cfg;
} CaSearch;

/* 检查给定路径存在且是普通文件。 */
static int ca_file_usable(const char *path)
{
    DWORD a;
    if (path == NULL || path[0] == '\0') return 0;
    a = GetFileAttributesA(path);
    return (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0) ? 1 : 0;
}

/* 把 exe 同目录的 cacert.pem 写进 out。 */
static int ca_default_next_to_exe(char *out, size_t out_sz)
{
    char exe[MAX_PATH * 2];
    char *p;
    DWORD n = GetModuleFileNameA(NULL, exe, (DWORD)sizeof(exe));
    if (n == 0 || n >= sizeof(exe)) return 0;
    p = strrchr(exe, '\\');
    if (p == NULL) return 0;
    *(p + 1) = '\0';
    if (snprintf(out, out_sz, "%scacert.pem", exe) < 0) return 0;
    return 1;
}

/*
 * 解析 TLS 根证书包路径（只在首次使用时做一次，结果缓存）。
 *
 * 为什么需要它：本项目自带的是 curl.se 官方 MinGW 构建（LibreSSL）。LibreSSL 不会
 * 自动使用 Windows 证书存储，若没有 CA 包，任何 HTTPS 都会以
 * “unable to get local issuer certificate”失败。**解决办法是配置证书包，
 * 绝不通过 CURLOPT_SSL_VERIFYPEER=0 绕过校验。**
 *
 * 查找顺序：
 *   1) 配置里的 ca_bundle_path；
 *   2) 环境变量 CURL_CA_BUNDLE / SSL_CERT_FILE；
 *   3) 可执行文件同目录的 cacert.pem（随发布包提供）。
 * 都找不到时返回 NULL，由调用方给出可执行的错误提示。
 */
static char g_ca_chosen[MAX_PATH * 2];
static const char *g_ca_result = NULL;

static BOOL CALLBACK ca_bundle_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    const CaSearch *s = (const CaSearch *)param;
    const char *env;

    (void)once;
    (void)ctx;

    if (s != NULL && s->cfg != NULL && ca_file_usable(s->cfg->ca_bundle_path)) {
        snprintf(g_ca_chosen, sizeof(g_ca_chosen), "%s", s->cfg->ca_bundle_path);
        g_ca_result = g_ca_chosen;
        return TRUE;
    }
    env = getenv("CURL_CA_BUNDLE");
    if (ca_file_usable(env)) {
        snprintf(g_ca_chosen, sizeof(g_ca_chosen), "%s", env);
        g_ca_result = g_ca_chosen;
        return TRUE;
    }
    env = getenv("SSL_CERT_FILE");
    if (ca_file_usable(env)) {
        snprintf(g_ca_chosen, sizeof(g_ca_chosen), "%s", env);
        g_ca_result = g_ca_chosen;
        return TRUE;
    }
    if (ca_default_next_to_exe(g_ca_chosen, sizeof(g_ca_chosen)) &&
        ca_file_usable(g_ca_chosen)) {
        g_ca_result = g_ca_chosen;
        return TRUE;
    }
    g_ca_chosen[0] = '\0';
    g_ca_result = NULL;
    return TRUE;   /* 回调成功：只是“没找到”，不是“初始化失败” */
}

static const char *resolve_ca_bundle(const TsConfig *cfg)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    CaSearch search;
    search.cfg = cfg;
    InitOnceExecuteOnce(&once, ca_bundle_init_cb, &search, NULL);
    return g_ca_result;
}

static int curl_ensure_global(void)
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    PVOID context = NULL;
    if (!InitOnceExecuteOnce(&once, curl_init_once_cb, NULL, &context)) {
        return 1;   /* 回调返回 FALSE：初始化失败 */
    }
    return 0;
}

static size_t http_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    HttpCtx *c = (HttpCtx *)userdata;
    size_t n;
    if (size != 0 && nmemb > (size_t)-1 / size) {
        return 0; /* 溢出：中止传输 */
    }
    n = size * nmemb;
    if (c->len > c->limit || n > c->limit - c->len) {
        c->too_large = 1;
        return 0; /* 超过响应大小上限：中止传输 */
    }
    if (c->len + n + 1 > c->cap) {
        size_t ncap = c->cap ? c->cap : 4096;
        char *nd;
        while (ncap < c->len + n + 1) {
            if (ncap > (size_t)-1 / 2) return 0;
            ncap *= 2;
        }
        nd = (char *)realloc(c->data, ncap);
        if (nd == NULL) return 0;
        c->data = nd;
        c->cap = ncap;
    }
    if (n > 0) {
        memcpy(c->data + c->len, ptr, n);
        c->len += n;
    }
    if (c->data == NULL) return 0;
    c->data[c->len] = '\0';
    return n;
}

static size_t http_header_cb(char *buffer, size_t size, size_t nitems, void *userdata)
{
    HttpCtx *c = (HttpCtx *)userdata;
    size_t n;
    long ms;

    if (size != 0 && nitems > (size_t)-1 / size) {
        return 0;
    }
    n = size * nitems;
    ms = ts_model_parse_retry_after(buffer, n);
    if (ms > 0) {
        c->retry_after_ms = ms;
    }
    return n;
}

static int classify_curl_error(CURLcode c)
{
    if (c == CURLE_PEER_FAILED_VERIFICATION ||
        c == CURLE_SSL_CONNECT_ERROR ||
        c == CURLE_SSL_CERTPROBLEM ||
        c == CURLE_SSL_CIPHER ||
        c == CURLE_SSL_CACERT_BADFILE) {
        return TS_MODEL_ERR_TLS;
    }
    return TS_MODEL_ERR_NETWORK;
}

static int classify_http_status(long code)
{
    if (code == 401 || code == 403) return TS_MODEL_ERR_AUTH;
    if (code == 429) return TS_MODEL_ERR_RATE_LIMIT;
    if (code >= 500 && code <= 599) return TS_MODEL_ERR_SERVER;
    if (code >= 400 && code <= 499) return TS_MODEL_ERR_CONFIG;
    return TS_MODEL_ERR_PROTOCOL;
}

/* 只有部分 5xx 与 429 适合有限重试。 */
static int http_status_retryable(long code)
{
    return ts_model_http_status_retryable(code);
}

/*
 * Retry-After 解析（修复 8）。
 *
 * 只接受十进制“秒”（RFC 9110 的 delay-seconds 形式）。HTTP-date 形式返回 0，
 * 由调用方退回默认短退避，避免把绝对时间误当秒数而产生超长等待。
 * 合法范围限定为 1..3600 秒；0、负数、溢出、非数字一律返回 0。
 */
long ts_model_parse_retry_after(const char *header_line, size_t len)
{
    size_t i;
    long secs = 0;
    int digits = 0;

    if (header_line == NULL || len == 0) {
        return 0;
    }
    /* 头部名大小写不敏感：retry-after: */
    {
        static const char name[] = "retry-after";
        size_t k = 0;
        for (i = 0; i < len && k < sizeof(name) - 1; i++, k++) {
            char ch = header_line[i];
            if (ch >= 'A' && ch <= 'Z') ch = (char)(ch - 'A' + 'a');
            if (ch != name[k]) {
                return 0;
            }
        }
        if (k != sizeof(name) - 1 || i >= len || header_line[i] != ':') {
            return 0;
        }
        i++; /* 跳过冒号 */
    }
    while (i < len && (header_line[i] == ' ' || header_line[i] == '\t')) i++;
    while (i < len && header_line[i] >= '0' && header_line[i] <= '9') {
        if (secs > 3600) {          /* 提前饱和，避免溢出 */
            secs = 3601;
            digits = 1;
        } else {
            secs = secs * 10 + (header_line[i] - '0');
        }
        digits = 1;
        i++;
    }
    if (!digits || secs < 1 || secs > 3600) {
        return 0;
    }
    /* 数字之后只允许空白（含行尾 CRLF）；出现其它内容视为畸形头部 */
    for (; i < len; i++) {
        char ch = header_line[i];
        if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') {
            return 0;
        }
    }
    return secs * 1000;
}

int ts_model_http_status_retryable(long http_status)
{
    return http_status == 429 ||
           http_status == 500 ||
           http_status == 502 ||
           http_status == 503 ||
           http_status == 504;
}

static int http_request(const TsConfig *cfg, const TsHttpRequest *req,
                        const TsCancel *cancel, int generation,
                        TsModelResult *out)
{
    CURL *easy = NULL;
    CURLM *multi = NULL;
    struct curl_slist *headers = NULL;
    HttpCtx ctx;
    char errbuf[CURL_ERROR_SIZE];
    CURLcode cres = CURLE_OK;
    long http_code = 0;
    int still_running = 0;
    int have_result = 0;
    int added = 0;
    int rc = 1;
    uint64_t start = ts_clock_ms();
    char msg[768];
    int is_post;
    const char *url;
    long connect_ms;
    long total_ms;
    long cap_bytes;

    memset(&ctx, 0, sizeof(ctx));
    errbuf[0] = '\0';

    if (req == NULL || req->url == NULL || req->url[0] == '\0') {
        out->error = ts_strdup("请求地址为空");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }
    url = req->url;
    is_post = (req->method != NULL && _stricmp(req->method, "POST") == 0) ? 1 : 0;

    cap_bytes = (req->max_response_bytes > 0) ? req->max_response_bytes
                : ((cfg != NULL && cfg->max_response_bytes > 0)
                       ? cfg->max_response_bytes
                       : (long)(2 * 1024 * 1024));
    ctx.limit = (size_t)cap_bytes;

    connect_ms = (req->connect_timeout_ms > 0)
                     ? req->connect_timeout_ms
                     : ((cfg != NULL) ? cfg->connect_timeout_ms : 0);
    if (connect_ms <= 0) connect_ms = 15000;

    total_ms = (req->timeout_ms > 0) ? req->timeout_ms
               : ((cfg != NULL) ? cfg->request_timeout_ms : 0);

    if (curl_ensure_global() != 0) {
        out->error = ts_strdup("libcurl 全局初始化失败");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }

    easy = curl_easy_init();
    if (easy == NULL) {
        out->error = ts_strdup("curl_easy_init 失败");
        out->error_kind = TS_MODEL_ERR_MEMORY;
        return 1;
    }
    multi = curl_multi_init();
    if (multi == NULL) {
        curl_easy_cleanup(easy);
        out->error = ts_strdup("curl_multi_init 失败");
        out->error_kind = TS_MODEL_ERR_MEMORY;
        return 1;
    }

    headers = curl_slist_append(headers, "Accept: application/json");
    if (is_post && req->body != NULL) {
        headers = curl_slist_append(headers, "Content-Type: application/json");
    }
    headers = curl_slist_append(headers, "Expect:");
    /*
     * 认证头：只有确实拿到密钥时才发送。
     * authMode=none（或没有凭据）时必须**不带** Authorization ——
     * 否则等于向无鉴权的本地服务泄露一个空/错的凭据。
     */
    if (req->api_key != NULL && req->api_key[0] != '\0') {
        size_t need = strlen(req->api_key) + 32;
        char *h = (char *)malloc(need);
        if (h != NULL) {
            snprintf(h, need, "Authorization: Bearer %s", req->api_key);
            headers = curl_slist_append(headers, h);
            memset(h, 0, strlen(h)); /* 不在内存中残留明文密钥 */
            free(h);
        }
    }

    curl_easy_setopt(easy, CURLOPT_URL, url);
    if (is_post) {
        curl_easy_setopt(easy, CURLOPT_POST, 1L);
        curl_easy_setopt(easy, CURLOPT_POSTFIELDS,
                         (req->body != NULL) ? req->body : "");
        curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE,
                         (curl_off_t)req->body_len);
    } else {
        curl_easy_setopt(easy, CURLOPT_HTTPGET, 1L);
    }
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, http_write_cb);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, http_header_cb);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &ctx);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, connect_ms);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L); /* 不关闭证书校验 */
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    /*
     * 提供 CA 证书包。找不到时**不**降级为“跳过校验”，而是让请求失败，
     * 并在错误信息里告诉用户缺什么（见下面的 TLS 分支）。
     */
    {
        int is_https = (strncmp(url, "https:", 6) == 0) ? 1 : 0;
        const char *ca = NULL;
        if (is_https) {
            if (req->ca_bundle_path != NULL && ca_file_usable(req->ca_bundle_path)) {
                ca = req->ca_bundle_path;
            } else {
                ca = resolve_ca_bundle(cfg);
            }
        }
        if (ca != NULL) {
            curl_easy_setopt(easy, CURLOPT_CAINFO, ca);
        } else if (is_https) {
            /*
             * HTTPS 但没有可用 CA 包：直接给出可执行的提示，而不是让 libcurl
             * 抛出一句难以理解的 “unable to get local issuer certificate”。
             * 错误信息保持单行（界面与 TXT 导出按行展示）。
             */
            out->error = ts_strdup(
                "缺少 TLS 根证书包（PEM），无法校验 HTTPS 服务器证书。请把 cacert.pem "
                "放在本程序同目录，或在配置里设置 ca_bundle_path 指向它，"
                "或设置环境变量 CURL_CA_BUNDLE；出于安全考虑本程序不会关闭证书校验。");
            out->error_kind = TS_MODEL_ERR_TLS;
            out->retryable = 0;
            goto cleanup;
        }
    }
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "TaskScheduler/1.0");
    /* 正式分析默认不设总超时；探针会通过 req->timeout_ms 显式覆盖。
       不设置 LOW_SPEED_LIMIT / LOW_SPEED_TIME，避免变相终止模型等待。 */
    if (total_ms > 0) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, total_ms);
    }

    if (curl_multi_add_handle(multi, easy) != CURLM_OK) {
        out->error = ts_strdup("curl_multi_add_handle 失败");
        out->error_kind = TS_MODEL_ERR_MEMORY;
        goto cleanup;
    }
    added = 1;

    for (;;) {
        CURLMcode mres;
        int numfds = 0;

        if (ts_cancel_should_stop(cancel, generation)) {
            out->error = ts_strdup("用户取消了本次请求");
            out->error_kind = TS_MODEL_ERR_CANCELLED;
            out->retryable = 0;
            goto cleanup;
        }

        mres = curl_multi_perform(multi, &still_running);
        if (mres != CURLM_OK) {
            snprintf(msg, sizeof(msg), "curl_multi_perform 失败：%s", curl_multi_strerror(mres));
            out->error = ts_strdup(msg);
            out->error_kind = TS_MODEL_ERR_NETWORK;
            out->retryable = 1;
            goto cleanup;
        }
        if (still_running == 0) {
            break;
        }
        /* 最多等待 200ms，以便及时响应取消。 */
        mres = curl_multi_wait(multi, NULL, 0, 200, &numfds);
        if (mres != CURLM_OK) {
            snprintf(msg, sizeof(msg), "curl_multi_wait 失败：%s", curl_multi_strerror(mres));
            out->error = ts_strdup(msg);
            out->error_kind = TS_MODEL_ERR_NETWORK;
            out->retryable = 1;
            goto cleanup;
        }
    }

    {
        int msgs_left = 0;
        CURLMsg *m;
        while ((m = curl_multi_info_read(multi, &msgs_left)) != NULL) {
            if (m->msg == CURLMSG_DONE) {
                cres = m->data.result;
                have_result = 1;
            }
        }
    }

    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);
    out->http_status = http_code;
    out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
    out->retry_after_ms = ctx.retry_after_ms;

    if (!have_result) {
        out->error = ts_strdup("未取得传输结果（内部协议错误）");
        out->error_kind = TS_MODEL_ERR_PROTOCOL;
        goto cleanup;
    }

    if (cres != CURLE_OK) {
        int kind;
        if (ctx.too_large) {
            kind = TS_MODEL_ERR_TOO_LARGE;
            snprintf(msg, sizeof(msg), "响应超过大小上限（%zu 字节），已中止接收", ctx.limit);
        } else if (cres == CURLE_WRITE_ERROR) {
            kind = TS_MODEL_ERR_MEMORY;
            snprintf(msg, sizeof(msg), "接收响应时内存分配失败");
        } else if (cres == CURLE_OPERATION_TIMEDOUT) {
            /* 探针的短超时：必须与“网络不可达”区分开，否则用户不知道是超时。 */
            kind = TS_MODEL_ERR_NETWORK;
            snprintf(msg, sizeof(msg), "请求超时（超过 %ld 毫秒未完成）", total_ms);
        } else {
            kind = classify_curl_error(cres);
            snprintf(msg, sizeof(msg), "网络请求失败：%s",
                     errbuf[0] != '\0' ? errbuf : curl_easy_strerror(cres));
        }
        out->error = ts_strdup(msg);
        out->error_kind = kind;
        out->retryable = (kind == TS_MODEL_ERR_NETWORK) ? 1 : 0;
        goto cleanup;
    }

    if (http_code < 200 || http_code >= 300) {
        int kind = classify_http_status(http_code);
        out->error_kind = kind;
        out->retryable = http_status_retryable(http_code) ? 1 : 0;
        if (kind == TS_MODEL_ERR_AUTH) {
            /*
             * 401/403 的正文先脱敏再截断：服务端回显里可能带上我们发出的
             * 凭证片段或其它敏感串，绝不能原样进入界面、导出或日志。
             * 保留错误码、错误类型与请求 ID 等可用于排查的信息。
             */
            char body[512];
            size_t bn = (ctx.data != NULL) ? strlen(ctx.data) : 0;
            if (bn >= sizeof(body)) bn = sizeof(body) - 1;
            if (ctx.data != NULL) {
                memcpy(body, ctx.data, bn);
            }
            body[bn] = '\0';
            ts_model_diag_redact(body);
            snprintf(msg, sizeof(msg), "服务端返回 HTTP %ld（鉴权未通过）：%.300s",
                     http_code, (bn > 0) ? body : "(无正文)");
        } else {
            /*
             * 非鉴权错误也做脱敏：服务端错误正文可能回显请求内容，
             * 而探针是用真实密钥发出去的请求。
             */
            char body[512];
            size_t bn = (ctx.data != NULL) ? strlen(ctx.data) : 0;
            if (bn >= sizeof(body)) bn = sizeof(body) - 1;
            if (ctx.data != NULL) memcpy(body, ctx.data, bn);
            body[bn] = '\0';
            ts_model_diag_redact(body);
            snprintf(msg, sizeof(msg), "服务端返回 HTTP %ld：%.400s",
                     http_code, (bn > 0) ? body : "(无正文)");
        }
        out->error = ts_strdup(msg);
        goto cleanup;
    }

    /* 成功：把原始响应正文交给调用方做外壳解析 */
    out->body = ctx.data;
    out->body_len = ctx.len;
    out->ok = 1;
    out->error_kind = TS_MODEL_OK;
    ctx.data = NULL;
    rc = 0;

cleanup:
    out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
    out->retry_after_ms = ctx.retry_after_ms;
    if (added && multi != NULL && easy != NULL) {
        curl_multi_remove_handle(multi, easy);
    }
    if (headers != NULL) curl_slist_free_all(headers);
    if (multi != NULL) curl_multi_cleanup(multi);
    if (easy != NULL) curl_easy_cleanup(easy);
    free(ctx.data);
    return rc;
}

static int http_post(const TsConfig *cfg,
                     const char *body, size_t body_len,
                     const TsCancel *cancel, int generation,
                     TsModelResult *out)
{
    TsHttpRequest req;
    memset(&req, 0, sizeof(req));
    req.url = cfg->endpoint_url;
    req.method = "POST";
    req.body = body;
    req.body_len = body_len;
    req.api_key = cfg->api_key;
    req.ca_bundle_path = cfg->ca_bundle_path;
    req.connect_timeout_ms = cfg->connect_timeout_ms;
    req.timeout_ms = cfg->request_timeout_ms;
    req.max_response_bytes = cfg->max_response_bytes;
    return http_request(cfg, &req, cancel, generation, out);
}

#endif /* TS_HAVE_CURL */

/* ------------------------------------------------------------------ */
/* 通用 HTTP 调用（探针用）                                            */
/* ------------------------------------------------------------------ */

int ts_model_http(const TsConfig *cfg, const TsHttpRequest *req,
                  const TsCancel *cancel, int generation,
                  TsModelResult *out)
{
    if (out == NULL) return 1;
    ts_model_result_init(out);
    if (cfg == NULL) {
        out->error = ts_strdup("配置为空");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }
    if (req == NULL || req->url == NULL || req->url[0] == '\0') {
        out->error = ts_strdup("请求地址为空（请先确认连接地址）");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }

#if defined(TS_HAVE_CURL)
    return http_request(cfg, req, cancel, generation, out);
#else
    (void)cancel;
    (void)generation;
    out->error = ts_strdup(
        "未启用 libcurl，无法发起真实请求：请安装 libcurl 后重新构建，"
        "或在配置中设置 mock_mode=true");
    out->error_kind = TS_MODEL_ERR_CONFIG;
    out->retryable = 0;
    return 1;
#endif
}


/* ------------------------------------------------------------------ */
/* 对外调用                                                            */
/* ------------------------------------------------------------------ */

static int model_call_mock(const TsConfig *cfg, TsModelResult *out)
{
    uint64_t start = ts_clock_ms();
    (void)cfg;

    out->body = ts_strdup(MOCK_JSON);
    if (out->body == NULL) {
        out->error = ts_strdup("内存分配失败");
        out->error_kind = TS_MODEL_ERR_MEMORY;
        out->retryable = 0;
        return 1;
    }
    out->body_len = strlen(out->body);
    out->http_status = 0;
    out->ok = 1;
    out->error_kind = TS_MODEL_OK;
    out->retryable = 0;
    out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
    return 0;
}

#if defined(TS_HAVE_CURL)
static int model_call_http(const TsConfig *cfg,
                           const char *request_body, size_t request_len,
                           const TsCancel *cancel, int generation,
                           TsModelResult *out)
{
    TsModelResult raw;
    TsTokenUsage usage;
    char err2[768];
    char *content = NULL;
    size_t content_len = 0;
    int kind = TS_MODEL_ERR_PROTOCOL;

    memset(&usage, 0, sizeof(usage));
    ts_model_result_init(&raw);
    if (http_post(cfg, request_body, request_len, cancel, generation, &raw) != 0) {
        *out = raw; /* 所有权移交 */
        return 1;
    }

    if (ts_model_extract_content_usage(raw.body, raw.body_len,
                                       &content, &content_len, &kind,
                                       err2, sizeof(err2), &usage) == 0) {
        out->body = content;
        out->body_len = content_len;
        out->ok = 1;
        out->http_status = raw.http_status;
        out->elapsed_ms = raw.elapsed_ms;
        out->error_kind = TS_MODEL_OK;
        out->retryable = 0;
    } else {
        out->error = ts_strdup(err2);
        out->error_kind = kind;
        out->http_status = raw.http_status;
        out->elapsed_ms = raw.elapsed_ms;
        out->retryable = 0;
    }

    /* token 用量无论成败都带出去：报错时也需要它来解释“为什么被截断” */
    out->usage_prompt_tokens     = usage.prompt_tokens;
    out->usage_completion_tokens = usage.completion_tokens;
    out->usage_reasoning_tokens  = usage.reasoning_tokens;
    out->usage_total_tokens      = usage.total_tokens;
    out->usage_present           = usage.present;
    out->finish_length           = (kind == TS_MODEL_ERR_TRUNCATED) ? 1 : 0;

    ts_model_result_free(&raw);
    return out->ok ? 0 : 1;
}
#endif

int ts_model_call(const TsConfig *cfg,
                  const char *request_body, size_t request_len,
                  const TsCancel *cancel, int generation,
                  TsModelResult *out)
{
    if (out == NULL) {
        return 1;
    }
    ts_model_result_init(out);
    if (cfg == NULL) {
        out->error = ts_strdup("配置为空");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }
    if (cfg->mock_mode) {
        return model_call_mock(cfg, out);
    }

#if defined(TS_HAVE_CURL)
    if (cfg->endpoint_url == NULL || cfg->endpoint_url[0] == '\0') {
        out->error = ts_strdup("配置缺少 endpoint_url");
        out->error_kind = TS_MODEL_ERR_CONFIG;
        return 1;
    }
    return model_call_http(cfg, request_body, request_len, cancel, generation, out);
#else
    (void)request_body;
    (void)request_len;
    (void)cancel;
    (void)generation;
    out->error = ts_strdup(
        "未启用 libcurl，无法发起真实请求：请安装 libcurl 后重新构建，或在配置中设置 mock_mode=true");
    out->error_kind = TS_MODEL_ERR_CONFIG;
    out->retryable = 0;
    return 1;
#endif
}

