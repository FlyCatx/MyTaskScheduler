/*
 * config.c — 配置文件（JSON + 环境变量）载入、校验、深拷贝与鉴权判定。
 *
 * 主要函数：ts_config_load、ts_config_validate、ts_config_copy、ts_config_move、ts_config_requires_auth。
 */

#include "config.h"
#include "file_io.h"
#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "cJSON.h"

/* 配置文件本身的读取上限：在分配缓冲之前生效，避免误选大文件时占用内存。 */
#define TS_MAX_CONFIG_BYTES (4u * 1024u * 1024u)

/* ---------- 读取辅助 ---------- */

static const char *json_string(const cJSON *o, const char *key)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsString(it)) {
        return NULL;
    }
    return cJSON_GetStringValue(it);
}

static long json_long(const cJSON *o, const char *key, long def)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsNumber(it)) {
        return def;
    }
    return (long)it->valueint;
}

static int json_num(const cJSON *o, const char *key, double *out)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsNumber(it)) {
        return 0;
    }
    *out = it->valuedouble;
    return 1;
}

static int json_bool(const cJSON *o, const char *key, int def)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsBool(it)) {
        return def;
    }
    return cJSON_IsTrue(it) ? 1 : 0;
}

/* ---------- 生命周期 ---------- */

void ts_config_init(TsConfig *c)
{
    if (c == NULL) {
        return;
    }
    memset(c, 0, sizeof(*c));
    c->connect_timeout_ms   = TS_DEFAULT_CONNECT_TIMEOUT_MS;
    c->wait_prompt_ms       = TS_DEFAULT_WAIT_PROMPT_MS;
    c->request_timeout_ms   = TS_DEFAULT_REQUEST_TIMEOUT_MS;
    c->max_output_tokens    = TS_DEFAULT_MAX_OUTPUT_TOKENS;
    c->max_input_bytes      = TS_DEFAULT_MAX_INPUT_BYTES;
    c->max_response_bytes   = TS_DEFAULT_MAX_RESPONSE_BYTES;
    c->json_mode            = 1;
    c->temperature          = TS_DEFAULT_TEMPERATURE;
    c->reference_hours      = TS_DEFAULT_REFERENCE_HOURS;
    c->w_urgency            = TS_DEFAULT_W_URGENCY;
    c->w_impact             = TS_DEFAULT_W_IMPACT;
    c->w_blocking           = TS_DEFAULT_W_BLOCKING;
    c->w_quick_win          = TS_DEFAULT_W_QUICK_WIN;
    c->w_depth              = TS_DEFAULT_W_DEPTH;
    c->max_tasks            = TS_DEFAULT_MAX_TASKS;
    c->max_steps_per_task   = TS_DEFAULT_MAX_STEPS_PER_TASK;
    c->max_retry_attempts   = TS_DEFAULT_MAX_RETRY_ATTEMPTS;
    c->reasoning_effort     = ts_strdup(TS_DEFAULT_REASONING_EFFORT);
    c->mock_mode            = 0;
    c->protocol             = 0;   /* TS_PROTOCOL_LEGACY：保持 0.0.3 行为 */
    c->thinking             = 0;   /* TS_THINKING_UNSUPPORTED */
    c->profile_revision     = 0;
    c->probe_timeout_ms     = TS_DEFAULT_PROBE_TIMEOUT_MS;
}

void ts_config_free(TsConfig *c)
{
    if (c == NULL) {
        return;
    }
    ts_free(c->endpoint_url);
    ts_free(c->model);
    ts_free(c->api_key_env);
    ts_secure_free(&c->api_key);      /* 密钥：先擦除再释放 */
    ts_free(c->config_path);
    ts_free(c->ca_bundle_path);
    ts_free(c->reasoning_effort);
    ts_free(c->profile_id);
    ts_free(c->thinking_effort);
    ts_free(c->models_url);
    ts_free(c->auth_mode);
    ts_free(c->credential_host);
    memset(c, 0, sizeof(*c));
}

/* 复制一个 owned 字符串字段：src 为 NULL → dst 为 NULL。 */
static int copy_str_field(char **dst, const char *src)
{
    *dst = NULL;
    if (src == NULL) {
        return 0;
    }
    *dst = ts_strdup(src);
    return (*dst != NULL) ? 0 : 1;
}

int ts_config_copy(TsConfig *dst, const TsConfig *src)
{
    if (dst == NULL) {
        return 1;
    }
    ts_config_init(dst);
    if (src == NULL) {
        return 0;
    }

    dst->connect_timeout_ms   = src->connect_timeout_ms;
    dst->wait_prompt_ms       = src->wait_prompt_ms;
    dst->request_timeout_ms   = src->request_timeout_ms;
    dst->max_output_tokens    = src->max_output_tokens;
    dst->max_input_bytes      = src->max_input_bytes;
    dst->max_response_bytes   = src->max_response_bytes;
    dst->json_mode            = src->json_mode;
    dst->temperature          = src->temperature;
    dst->reference_hours      = src->reference_hours;
    dst->w_urgency            = src->w_urgency;
    dst->w_impact             = src->w_impact;
    dst->w_blocking           = src->w_blocking;
    dst->w_quick_win          = src->w_quick_win;
    dst->w_depth              = src->w_depth;
    dst->max_tasks            = src->max_tasks;
    dst->max_steps_per_task   = src->max_steps_per_task;
    dst->max_retry_attempts   = src->max_retry_attempts;
    dst->mock_mode            = src->mock_mode;
    dst->profile_revision     = src->profile_revision;
    dst->protocol             = src->protocol;
    dst->thinking             = src->thinking;
    dst->probe_timeout_ms     = src->probe_timeout_ms;

    if (copy_str_field(&dst->endpoint_url, src->endpoint_url) != 0 ||
        copy_str_field(&dst->model, src->model) != 0 ||
        copy_str_field(&dst->api_key_env, src->api_key_env) != 0 ||
        copy_str_field(&dst->api_key, src->api_key) != 0 ||
        copy_str_field(&dst->config_path, src->config_path) != 0 ||
        copy_str_field(&dst->ca_bundle_path, src->ca_bundle_path) != 0 ||
        copy_str_field(&dst->reasoning_effort, src->reasoning_effort) != 0 ||
        copy_str_field(&dst->profile_id, src->profile_id) != 0 ||
        copy_str_field(&dst->thinking_effort, src->thinking_effort) != 0 ||
        copy_str_field(&dst->models_url, src->models_url) != 0 ||
        copy_str_field(&dst->auth_mode, src->auth_mode) != 0 ||
        copy_str_field(&dst->credential_host, src->credential_host) != 0) {
        ts_config_free(dst);
        ts_config_init(dst);
        return 1;
    }
    return 0;
}

void ts_config_move(TsConfig *dst, TsConfig *src)
{
    TsConfig tmp;
    if (dst == NULL || src == NULL || dst == src) {
        return;
    }
    tmp = *dst;    /* 浅拷贝：指针所有权的临时中转 */
    *dst = *src;
    *src = tmp;
    ts_config_free(src);   /* 释放 dst 原来的内容 */
    ts_config_init(src);
}

/* ---------- API Key 状态与格式检查 ---------- */

int ts_config_requires_auth(const TsConfig *cfg)
{
    if (cfg == NULL) return 0;
    /* 已提供内联密钥：要求鉴权，且密钥已就绪 */
    if (cfg->api_key != NULL && cfg->api_key[0] != '\0') return 1;
    if (cfg->api_key_env == NULL) return 0;      /* 配置未声明该字段 */
    if (cfg->api_key_env[0] == '\0') return 0;   /* 显式声明无需鉴权 */
    return 1;
}

/*
 * 只报告密钥**来源**（不涉及密钥内容），用于诊断与 JSON 导出：
 *   0 = 没有可用密钥
 *   1 = 来自配置文件的内联 api_key
 *   2 = 来自环境变量 api_key_env
 * 判定方式：重新查一次环境变量——若当前值与环境变量一致，则视为来自环境变量。
 * 这样不需要在结构体里额外保存来源，也不会把密钥写进任何输出。
 */
int ts_config_api_key_source(const TsConfig *cfg)
{
    const char *env;
    if (cfg == NULL || cfg->api_key == NULL || cfg->api_key[0] == '\0') {
        return 0;
    }
    if (cfg->api_key_env != NULL && cfg->api_key_env[0] != '\0') {
        env = getenv(cfg->api_key_env);
        if (env != NULL && env[0] != '\0' && strcmp(env, cfg->api_key) == 0) {
            return 2;
        }
    }
    return 1;
}

/*
 * 只检查“格式类”问题，不做任何清理或改写。
 * 判定项：
 *   - 前导/尾随空白（含空格、制表符、换行、回车、垂直制表、换页）；
 *   - ASCII 控制字符（< 0x20 或 == 0x7F）；
 *   - 首尾成对的双引号或单引号（例如从文档复制时把引号一起带进环境变量）。
 * 说明文字里只出现“位置 + 类别”，绝不出现密钥字符本身。
 */
const char *ts_config_api_key_format_error(const char *key)
{
    size_t len;
    size_t i;

    if (key == NULL || key[0] == '\0') {
        return "密钥为空";
    }
    len = strlen(key);

    if (key[0] == ' ' || key[0] == '\t' || key[0] == '\r' || key[0] == '\n') {
        return "密钥开头是空白字符（可能是复制时把空格或换行一起带进来了）";
    }
    if (key[len - 1] == ' ' || key[len - 1] == '\t' ||
        key[len - 1] == '\r' || key[len - 1] == '\n') {
        return "密钥结尾是空白字符（可能是复制时把空格或换行一起带进来了）";
    }

    for (i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)key[i];
        if (ch < 0x20 || ch == 0x7F) {
            return "密钥中间包含 ASCII 控制字符（环境变量里不应当出现控制字符）";
        }
    }

    if (len >= 2 &&
        ((key[0] == '"' && key[len - 1] == '"') ||
         (key[0] == '\'' && key[len - 1] == '\''))) {
        return "密钥被一对引号包住（设置环境变量时不要带上引号本身）";
    }

    return NULL;
}

/* ---------- 校验 ---------- */

static int cfg_fail(char *err, size_t err_sz, const char *msg)
{
    if (err != NULL && err_sz > 0) {
        snprintf(err, err_sz, "%s", msg);
    }
    return 1;
}

int ts_config_validate(const TsConfig *cfg, char *err, size_t err_sz)
{
    double wsum;

    if (cfg->endpoint_url == NULL || cfg->endpoint_url[0] == '\0')
        return cfg_fail(err, err_sz, "endpoint_url 不能为空");
    if (cfg->model == NULL || cfg->model[0] == '\0')
        return cfg_fail(err, err_sz, "model 不能为空");
    if (cfg->connect_timeout_ms < 1000 || cfg->connect_timeout_ms > 600000)
        return cfg_fail(err, err_sz, "connect_timeout_ms 超出范围 [1000, 600000]");
    if (cfg->wait_prompt_ms < 1000 || cfg->wait_prompt_ms > 3600000)
        return cfg_fail(err, err_sz, "wait_prompt_ms 超出范围 [1000, 3600000]");
    if (cfg->request_timeout_ms != 0 &&
        (cfg->request_timeout_ms < 1000 || cfg->request_timeout_ms > 86400000))
        return cfg_fail(err, err_sz, "request_timeout_ms 必须为 0（禁用）或 [1000, 86400000]");
    /*
     * max_output_tokens：0 = **不发送 max_tokens**，由服务端按模式取默认值
     * （官方：非思考 8K / 思考 64K / reasoning_effort=max 时 128K）。
     * 正数 = 显式指定该上限。上限取 384K（393216）为官方允许的最大值。
     */
    if (cfg->max_output_tokens < 0 || cfg->max_output_tokens > 393216)
        return cfg_fail(err, err_sz,
                        "max_output_tokens 必须为 0（不发送，由服务端取默认）"
                        "或 [1, 393216]（官方上限 384K）");
    if (cfg->max_input_bytes < 1024)
        return cfg_fail(err, err_sz, "max_input_bytes 必须 >= 1024");
    if (cfg->max_response_bytes < 1024)
        return cfg_fail(err, err_sz, "max_response_bytes 必须 >= 1024");
    if (cfg->temperature < 0.0 || cfg->temperature > 2.0)
        return cfg_fail(err, err_sz, "temperature 超出范围 [0, 2]");
    if (cfg->reference_hours <= 0.0 || cfg->reference_hours > 1000000.0)
        return cfg_fail(err, err_sz, "reference_hours 必须 > 0");
    if (cfg->max_tasks < 1 || cfg->max_tasks > 100000)
        return cfg_fail(err, err_sz, "max_tasks 超出范围 [1, 100000]");
    if (cfg->max_steps_per_task < 1 || cfg->max_steps_per_task > 100000)
        return cfg_fail(err, err_sz, "max_steps_per_task 超出范围 [1, 100000]");
    if (cfg->max_retry_attempts < 0 || cfg->max_retry_attempts > 1)
        return cfg_fail(err, err_sz, "max_retry_attempts 只能为 0 或 1");
    if (cfg->probe_timeout_ms != 0 &&
        (cfg->probe_timeout_ms < 3000 || cfg->probe_timeout_ms > 120000))
        return cfg_fail(err, err_sz, "probe_timeout_ms 必须是 0（用默认 30000）或 [3000, 120000]");
    if (cfg->reasoning_effort != NULL &&
        strcmp(cfg->reasoning_effort, "none") != 0 &&
        strcmp(cfg->reasoning_effort, "low") != 0 &&
        strcmp(cfg->reasoning_effort, "high") != 0 &&
        strcmp(cfg->reasoning_effort, "max") != 0)
        return cfg_fail(err, err_sz,
                        "reasoning_effort 只能是 none/low/high/max 或 null（不发送）");

    if (cfg->w_urgency  < 0.0 || cfg->w_urgency  > 1.0 ||
        cfg->w_impact   < 0.0 || cfg->w_impact   > 1.0 ||
        cfg->w_blocking < 0.0 || cfg->w_blocking > 1.0 ||
        cfg->w_quick_win < 0.0 || cfg->w_quick_win > 1.0 ||
        cfg->w_depth    < 0.0 || cfg->w_depth    > 1.0)
        return cfg_fail(err, err_sz, "排序权重必须在 [0, 1] 内");

    wsum = cfg->w_urgency + cfg->w_impact + cfg->w_blocking +
           cfg->w_quick_win + cfg->w_depth;
    if (fabs(wsum - 1.0) > 1e-9)
        return cfg_fail(err, err_sz, "排序权重之和必须等于 1");

    return 0;
}

/* ---------- 加载 ---------- */

int ts_config_load(const char *path, TsConfig *cfg, char *err, size_t err_sz)
{
    unsigned char *raw = NULL;
    size_t raw_len = 0;
    size_t off = 0;
    cJSON *root = NULL;
    const cJSON *w = NULL;
    const char *s = NULL;
    double d;
    int rc = 1;

    if (cfg == NULL) {
        return 1;
    }
    ts_config_init(cfg);

    if (err != NULL && err_sz > 0) {
        err[0] = '\0';
    }

    if (path == NULL || path[0] == '\0') {
        snprintf(err, err_sz, "未提供配置文件路径");
        goto done;
    }

    /*
     * 记录实际加载的配置路径：多份 config.json 并存（源码目录 / 构建目录 /
     * 发布目录）时，错误提示里必须能直接看到程序到底读的是哪一份。
     */
    cfg->config_path = ts_strdup(path);
    if (cfg->config_path == NULL) goto oom;

    if (ts_file_read_raw(path, TS_MAX_CONFIG_BYTES, &raw, &raw_len,
                               err, err_sz) != 0) {
        goto done;
    }

    /* 去掉 UTF-8 BOM */
    if (raw_len >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
        off = 3;
    }

    if (!ts_utf8_valid(raw + off, raw_len - off)) {
        snprintf(err, err_sz, "配置文件不是合法的 UTF-8 编码");
        goto done;
    }

    root = cJSON_Parse((const char *)(raw + off));
    if (root == NULL) {
        snprintf(err, err_sz, "配置文件 JSON 解析失败：%s",
                 cJSON_GetErrorPtr() != NULL ? cJSON_GetErrorPtr() : "未知错误");
        goto done;
    }
    if (!cJSON_IsObject(root)) {
        snprintf(err, err_sz, "配置文件顶层必须是 JSON 对象");
        goto done;
    }

    s = json_string(root, "endpoint_url");
    if (s == NULL || s[0] == '\0') {
        snprintf(err, err_sz, "缺少或无效的 endpoint_url");
        goto done;
    }
    cfg->endpoint_url = ts_strdup(s);
    if (cfg->endpoint_url == NULL) goto oom;

    s = json_string(root, "model");
    if (s == NULL || s[0] == '\0') {
        snprintf(err, err_sz, "缺少或无效的 model");
        goto done;
    }
    cfg->model = ts_strdup(s);
    if (cfg->model == NULL) goto oom;

    s = json_string(root, "api_key_env");
    if (s != NULL) {
        cfg->api_key_env = ts_strdup(s);
        if (cfg->api_key_env == NULL) goto oom;
    }

    /*
     * ca_bundle_path：TLS 根证书包（PEM）。
     * 留空时使用 libcurl 的默认行为（本项目自带的 Windows 构建默认没有系统证书存储，
     * 因此实际使用云端时必须提供）。**绝不因为缺少证书包而关闭证书校验。**
     */
    s = json_string(root, "ca_bundle_path");
    if (s != NULL && s[0] != '\0') {
        cfg->ca_bundle_path = ts_strdup(s);
        if (cfg->ca_bundle_path == NULL) goto oom;
    }

    /*
     * reasoning_effort：显式写 null 表示“不发送该参数”（兼容不识别它的服务）。
     * 显式写空串按“不发送”处理。
     */
    {
        const cJSON *re = cJSON_GetObjectItemCaseSensitive(root, "reasoning_effort");
        if (re != NULL && cJSON_IsString(re)) {
            const char *v = cJSON_GetStringValue(re);
            ts_free(cfg->reasoning_effort);
            cfg->reasoning_effort = NULL;
            if (v != NULL && v[0] != '\0') {
                cfg->reasoning_effort = ts_strdup(v);
                if (cfg->reasoning_effort == NULL) goto oom;
            }
        } else if (re != NULL && cJSON_IsNull(re)) {
            ts_free(cfg->reasoning_effort);
            cfg->reasoning_effort = NULL;
        }
        /* 字段缺失时保留默认值（none） */
    }

    cfg->connect_timeout_ms = json_long(root, "connect_timeout_ms", cfg->connect_timeout_ms);
    cfg->wait_prompt_ms     = json_long(root, "wait_prompt_ms", cfg->wait_prompt_ms);
    cfg->request_timeout_ms = json_long(root, "request_timeout_ms", cfg->request_timeout_ms);
    cfg->max_output_tokens  = json_long(root, "max_output_tokens", cfg->max_output_tokens);
    cfg->max_input_bytes    = json_long(root, "max_input_bytes", cfg->max_input_bytes);
    cfg->max_response_bytes = json_long(root, "max_response_bytes", cfg->max_response_bytes);
    cfg->max_tasks          = json_long(root, "max_tasks", cfg->max_tasks);
    cfg->max_steps_per_task = json_long(root, "max_steps_per_task", cfg->max_steps_per_task);
    cfg->max_retry_attempts = (int)json_long(root, "max_retry_attempts", cfg->max_retry_attempts);
    /*
     * probe_timeout_ms：只影响探针（模型发现 / 连通性测试），
     * 不影响正式分析的总超时策略（正式分析默认仍为 0 = 不设总超时）。
     */
    cfg->probe_timeout_ms   = json_long(root, "probe_timeout_ms", cfg->probe_timeout_ms);

    cfg->json_mode = json_bool(root, "json_mode", cfg->json_mode);
    cfg->mock_mode = json_bool(root, "mock_mode", cfg->mock_mode);

    if (json_num(root, "temperature", &d))      cfg->temperature = d;
    if (json_num(root, "reference_hours", &d))  cfg->reference_hours = d;

    w = cJSON_GetObjectItemCaseSensitive(root, "weights");
    if (w != NULL && cJSON_IsObject(w)) {
        if (json_num(w, "urgency", &d))   cfg->w_urgency = d;
        if (json_num(w, "impact", &d))    cfg->w_impact = d;
        if (json_num(w, "blocking", &d))  cfg->w_blocking = d;
        if (json_num(w, "quick_win", &d)) cfg->w_quick_win = d;
        if (json_num(w, "depth", &d))     cfg->w_depth = d;
    }

    /*
     * 解析 API Key。优先级（高 → 低）：
     *
     *   1) 配置里的 "api_key"        —— 内联密钥，直接写在 config.json 里；
     *   2) 环境变量 api_key_env 指定的值 —— 不落盘，推荐做法。
     *
     * 【安全提示】内联密钥会把明文密钥写在配置文件里：任何能读到该文件的人
     * 都能拿到密钥，配置文件也可能被误提交到版本库或随发布包分发。
     * 因此内联方式只应在“本机自用、且明白风险”的前提下使用；
     * 生产/共享环境请改用 api_key_env。
     *
     * 本地无鉴权服务的兼容性规则（与 ts_config_requires_auth 一致）：
     *   - 两者都没有 / api_key_env 显式写 "" → 视为无需鉴权，不发送 Authorization；
     *   - api_key_env 写了变量名但环境变量不存在或为空
     *     → 这里**不报错、不静默通过**：保持 api_key == NULL，
     *       由请求前的鉴权预检（analyze.c）给出明确的配置错误提示，
     *       绝不把“取不到密钥”当成“无需鉴权”直接发出云端请求。
     */
    s = json_string(root, "api_key");
    if (s != NULL && s[0] != '\0') {
        cfg->api_key = ts_strdup(s);
        if (cfg->api_key == NULL) goto oom;
    } else if (cfg->api_key_env != NULL && cfg->api_key_env[0] != '\0') {
        const char *val = getenv(cfg->api_key_env);
        if (val != NULL && val[0] != '\0') {
            cfg->api_key = ts_strdup(val);
            if (cfg->api_key == NULL) goto oom;
        }
    }

    if (ts_config_validate(cfg, err, err_sz) != 0) {
        goto done;
    }

    rc = 0;
    goto done;

oom:
    snprintf(err, err_sz, "内存分配失败");
done:
    ts_free(raw);
    if (root != NULL) {
        cJSON_Delete(root);
    }
    return rc;
}

