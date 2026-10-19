/*
 * profile.c — 供应商 profile 的 JSON 编解码、校验与 TsConfig 互转。
 *
 * 主要函数：ts_profile_from_json、ts_profile_list_parse、ts_profile_list_validate、
 * ts_profile_apply_to_config、ts_profile_from_legacy_config。
 */

#include "profile.h"

#include "config.h"
#include "mem.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static char *dup_or_null(const char *s)
{
    if (s == NULL) return NULL;
    return ts_strdup(s);
}

/* 取字符串字段；不存在/不是字符串时返回 NULL。空串原样返回空串。 */
static const char *jstr(const cJSON *o, const char *key)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsString(it)) return NULL;
    return cJSON_GetStringValue(it);
}

static int jbool(const cJSON *o, const char *key, int def)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsBool(it)) return def;
    return cJSON_IsTrue(it) ? 1 : 0;
}

static long jlong(const cJSON *o, const char *key, long def)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    if (it == NULL || !cJSON_IsNumber(it)) return def;
    return (long)it->valuedouble;
}

/* 字段是否存在（用于区分“缺失”与“显式 null/空串”）。 */
static int jhas(const cJSON *o, const char *key)
{
    return cJSON_GetObjectItemCaseSensitive(o, key) != NULL ? 1 : 0;
}

static int fail(char *err, size_t err_sz, const char *msg)
{
    if (err != NULL && err_sz > 0) {
        snprintf(err, err_sz, "%s", msg);
    }
    return 1;
}

/* UTF-8 安全的“是否以 prefix 开头（大小写不敏感）”。 */
static int starts_with_ci(const char *s, const char *prefix)
{
    size_t i;
    if (s == NULL || prefix == NULL) return 0;
    for (i = 0; prefix[i] != '\0'; i++) {
        char a = s[i];
        char b = prefix[i];
        if (a == '\0') return 0;
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* 枚举 <-> 字符串                                                     */
/* ------------------------------------------------------------------ */

const char *ts_protocol_name(TsProtocol p)
{
    switch (p) {
    case TS_PROTOCOL_DEEPSEEK_CHAT: return "deepseek-chat";
    case TS_PROTOCOL_OPENAI_CHAT:   return "openai-chat";
    case TS_PROTOCOL_LEGACY:
    default:                        return "legacy";
    }
}

int ts_protocol_parse(const char *s, TsProtocol *out)
{
    if (s == NULL) return 1;
    if (strcmp(s, "legacy") == 0) {
        if (out != NULL) *out = TS_PROTOCOL_LEGACY;
        return 0;
    }
    if (strcmp(s, "deepseek-chat") == 0) {
        if (out != NULL) *out = TS_PROTOCOL_DEEPSEEK_CHAT;
        return 0;
    }
    if (strcmp(s, "openai-chat") == 0) {
        if (out != NULL) *out = TS_PROTOCOL_OPENAI_CHAT;
        return 0;
    }
    return 1;
}

const char *ts_thinking_name(TsThinking t)
{
    switch (t) {
    case TS_THINKING_ENABLED:  return "enabled";
    case TS_THINKING_DISABLED: return "disabled";
    case TS_THINKING_UNSUPPORTED:
    default:                   return "unsupported";
    }
}

int ts_thinking_parse(const char *s, TsThinking *out)
{
    if (s == NULL) return 1;
    if (strcmp(s, "enabled") == 0) {
        if (out != NULL) *out = TS_THINKING_ENABLED;
        return 0;
    }
    if (strcmp(s, "disabled") == 0) {
        if (out != NULL) *out = TS_THINKING_DISABLED;
        return 0;
    }
    if (strcmp(s, "unsupported") == 0) {
        if (out != NULL) *out = TS_THINKING_UNSUPPORTED;
        return 0;
    }
    return 1;
}

const char *ts_auth_mode_bearer(void) { return "bearer"; }
const char *ts_auth_mode_none(void)   { return "none"; }

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

void ts_profile_init(TsProfile *p)
{
    if (p == NULL) return;
    memset(p, 0, sizeof(*p));
    p->protocol = TS_PROTOCOL_LEGACY;
    p->thinking = TS_THINKING_UNSUPPORTED;
    p->revision = 0;
    p->json_mode = 0;
}

void ts_profile_free(TsProfile *p)
{
    if (p == NULL) return;
    ts_free(p->id);
    ts_free(p->name);
    ts_free(p->base_url);
    ts_free(p->chat_url);
    ts_free(p->models_url);
    ts_free(p->auth_mode);
    ts_free(p->api_key_env);
    ts_free(p->model_id);
    ts_free(p->reasoning_effort);
    ts_free(p->credential_host);
    memset(p, 0, sizeof(*p));
}

int ts_profile_copy(TsProfile *dst, const TsProfile *src)
{
    if (dst == NULL) return 1;
    ts_profile_init(dst);
    if (src == NULL) return 0;

    dst->revision = src->revision;
    dst->protocol = src->protocol;
    dst->thinking = src->thinking;
    dst->json_mode = src->json_mode;
    dst->credential_configured = src->credential_configured;

    if ((dst->id = dup_or_null(src->id)) == NULL && src->id != NULL) goto oom;
    if ((dst->name = dup_or_null(src->name)) == NULL && src->name != NULL) goto oom;
    if ((dst->base_url = dup_or_null(src->base_url)) == NULL && src->base_url != NULL) goto oom;
    if ((dst->chat_url = dup_or_null(src->chat_url)) == NULL && src->chat_url != NULL) goto oom;
    if ((dst->models_url = dup_or_null(src->models_url)) == NULL && src->models_url != NULL) goto oom;
    if ((dst->auth_mode = dup_or_null(src->auth_mode)) == NULL && src->auth_mode != NULL) goto oom;
    if ((dst->api_key_env = dup_or_null(src->api_key_env)) == NULL && src->api_key_env != NULL) goto oom;
    if ((dst->model_id = dup_or_null(src->model_id)) == NULL && src->model_id != NULL) goto oom;
    if ((dst->reasoning_effort = dup_or_null(src->reasoning_effort)) == NULL &&
        src->reasoning_effort != NULL) goto oom;
    if ((dst->credential_host = dup_or_null(src->credential_host)) == NULL &&
        src->credential_host != NULL) goto oom;
    return 0;

oom:
    ts_profile_free(dst);
    return 1;
}

void ts_profile_list_init(TsProfileList *l)
{
    if (l == NULL) return;
    memset(l, 0, sizeof(*l));
    l->default_thinking = TS_THINKING_UNSUPPORTED;
    l->schema_version = TS_SETTINGS_SCHEMA_VERSION;
}

void ts_profile_list_free(TsProfileList *l)
{
    size_t i;
    if (l == NULL) return;
    for (i = 0; i < l->count; i++) {
        ts_profile_free(&l->items[i]);
    }
    ts_free(l->items);
    ts_free(l->default_profile_id);
    ts_free(l->default_model_id);
    ts_free(l->default_reasoning_effort);
    ts_free(l->migration_note);
    memset(l, 0, sizeof(*l));
    l->schema_version = TS_SETTINGS_SCHEMA_VERSION;
}

int ts_profile_list_copy(TsProfileList *dst, const TsProfileList *src)
{
    size_t i;
    if (dst == NULL) return 1;
    ts_profile_list_init(dst);
    if (src == NULL) return 0;

    dst->schema_version = src->schema_version;
    dst->migration_legacy = src->migration_legacy;
    dst->default_thinking = src->default_thinking;
    if ((dst->default_profile_id = dup_or_null(src->default_profile_id)) == NULL &&
        src->default_profile_id != NULL) goto oom;
    if ((dst->default_model_id = dup_or_null(src->default_model_id)) == NULL &&
        src->default_model_id != NULL) goto oom;
    if ((dst->default_reasoning_effort = dup_or_null(src->default_reasoning_effort)) == NULL &&
        src->default_reasoning_effort != NULL) goto oom;
    if ((dst->migration_note = dup_or_null(src->migration_note)) == NULL &&
        src->migration_note != NULL) goto oom;

    if (src->count > 0) {
        size_t bytes;
        if (ts_mul_overflow(src->count, sizeof(TsProfile), &bytes)) goto oom;
        dst->items = (TsProfile *)ts_calloc(src->count, sizeof(TsProfile));
        if (dst->items == NULL) goto oom;
        for (i = 0; i < src->count; i++) {
            ts_profile_init(&dst->items[i]);
            if (ts_profile_copy(&dst->items[i], &src->items[i]) != 0) goto oom;
            dst->count = i + 1;
        }
    }
    return 0;

oom:
    ts_profile_list_free(dst);
    return 1;
}

const TsProfile *ts_profile_list_find(const TsProfileList *l, const char *id)
{
    size_t i;
    if (l == NULL || id == NULL) return NULL;
    for (i = 0; i < l->count; i++) {
        if (l->items[i].id != NULL && strcmp(l->items[i].id, id) == 0) {
            return &l->items[i];
        }
    }
    return NULL;
}

TsProfile *ts_profile_list_find_mut(TsProfileList *l, const char *id)
{
    return (TsProfile *)ts_profile_list_find(l, id);
}

int ts_profile_list_append(TsProfileList *l, const TsProfile *p)
{
    size_t bytes;
    TsProfile *grown;
    TsProfile item;

    if (l == NULL || p == NULL) return 1;
    ts_profile_init(&item);
    if (ts_profile_copy(&item, p) != 0) return 1;

    if (ts_mul_overflow(l->count + 1, sizeof(TsProfile), &bytes)) {
        ts_profile_free(&item);
        return 1;
    }
    grown = (TsProfile *)ts_realloc(l->items, bytes);
    if (grown == NULL) {
        ts_profile_free(&item);
        return 1;
    }
    l->items = grown;
    l->items[l->count] = item;   /* 所有权移交 */
    memset(&item, 0, sizeof(item));
    l->count++;
    return 0;
}

int ts_profile_list_remove(TsProfileList *l, const char *id)
{
    size_t i;
    if (l == NULL || id == NULL) return 0;
    for (i = 0; i < l->count; i++) {
        if (l->items[i].id != NULL && strcmp(l->items[i].id, id) == 0) {
            size_t rest;
            ts_profile_free(&l->items[i]);
            rest = l->count - i - 1;
            if (rest > 0) {
                memmove(&l->items[i], &l->items[i + 1], rest * sizeof(TsProfile));
            }
            l->count--;
            if (l->count == 0) {
                ts_free(l->items);
                l->items = NULL;
            }
            return 1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 校验                                                                */
/* ------------------------------------------------------------------ */

static int id_chars_ok(const char *id)
{
    size_t i;
    size_t n;
    if (id == NULL) return 0;
    n = strlen(id);
    if (n < 1 || n > TS_PROFILE_ID_MAX) return 0;
    for (i = 0; i < n; i++) {
        char c = id[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static int url_ok(const char *url)
{
    if (url == NULL || url[0] == '\0') return 0;
    if (!starts_with_ci(url, "http://") && !starts_with_ci(url, "https://")) return 0;
    /* 必须真的带一个主机名：scheme:// 之后至少一个字符，且不是 '/'。 */
    {
        const char *p = strstr(url, "://");
        if (p == NULL) return 0;
        p += 3;
        if (*p == '\0' || *p == '/' || *p == '?' || *p == '#') return 0;
    }
    return 1;
}

static int effort_ok(const char *e)
{
    return e != NULL &&
           (strcmp(e, "low") == 0 || strcmp(e, "high") == 0 || strcmp(e, "max") == 0);
}

/*
 * 该 profile 是否配置了“凭据来源”：
 *   authMode=bearer，或者写了非空的 apiKeyEnv（环境变量方式也算凭据）。
 * 只要配置了，凭据就只允许发往 chatUrl 的 origin（见 ts_profile_validate）。
 */
static int profile_has_credential_source(const TsProfile *p)
{
    if (p == NULL) return 0;
    if (p->auth_mode != NULL && strcmp(p->auth_mode, ts_auth_mode_bearer()) == 0) return 1;
    if (p->api_key_env != NULL && p->api_key_env[0] != '\0') return 1;
    return 0;
}

int ts_profile_validate(const TsProfile *p, char *err, size_t err_sz)
{
    char msg[512];

    if (p == NULL) return fail(err, err_sz, "profile 为空");

    if (!id_chars_ok(p->id)) {
        return fail(err, err_sz,
                    "profile id 必须是非空的 1~64 位 [A-Za-z0-9_-] 字符"
                    "（不允许空格、斜杠或中文，否则无法作为凭据目标名）");
    }
    if (p->name == NULL || p->name[0] == '\0') {
        snprintf(msg, sizeof(msg), "profile %s 缺少名称", p->id);
        return fail(err, err_sz, msg);
    }
    if (strlen(p->name) > TS_PROFILE_NAME_MAX) {
        snprintf(msg, sizeof(msg), "profile %s 的名称过长（上限 %d 字节）",
                 p->id, TS_PROFILE_NAME_MAX);
        return fail(err, err_sz, msg);
    }
    if (p->revision < 1) {
        snprintf(msg, sizeof(msg), "profile %s 的 revision 必须 >= 1", p->id);
        return fail(err, err_sz, msg);
    }
    if (!url_ok(p->chat_url)) {
        snprintf(msg, sizeof(msg),
                 "profile %s 的 chatUrl 必须是完整的 http(s) 地址"
                 "（例如 https://api.deepseek.com/chat/completions，不会自动补 /v1）",
                 p->id);
        return fail(err, err_sz, msg);
    }
    if (strlen(p->chat_url) > TS_PROFILE_URL_MAX) {
        snprintf(msg, sizeof(msg), "profile %s 的 chatUrl 过长", p->id);
        return fail(err, err_sz, msg);
    }
    if (p->models_url != NULL && p->models_url[0] != '\0') {
        if (!url_ok(p->models_url)) {
            snprintf(msg, sizeof(msg),
                     "profile %s 的 modelsUrl 必须是完整的 http(s) 地址", p->id);
            return fail(err, err_sz, msg);
        }
        if (strlen(p->models_url) > TS_PROFILE_URL_MAX) {
            snprintf(msg, sizeof(msg), "profile %s 的 modelsUrl 过长", p->id);
            return fail(err, err_sz, msg);
        }
    }
    if (p->auth_mode == NULL ||
        (strcmp(p->auth_mode, ts_auth_mode_bearer()) != 0 &&
         strcmp(p->auth_mode, ts_auth_mode_none()) != 0)) {
        snprintf(msg, sizeof(msg), "profile %s 的 authMode 只能是 bearer 或 none", p->id);
        return fail(err, err_sz, msg);
    }
    /*
     * 凭据的授权范围 = chatUrl 的 origin。
     *
     * 模型发现请求实际发往 modelsUrl：如果它与 chatUrl 不同源，
     * 就相当于把对话密钥发给了另一个 origin（主机 / scheme / 端口任何一个不同都算）。
     * 因此只要配置了凭据来源（bearer 或 apiKeyEnv 非空），就要求两者同源；
     * authMode=none 允许跨源（运行时也绝不带凭据）。
     * 运行时还会用**实际请求 URL** 再校验一次（旧 settings.json 可能跨源）。
     */
    if (p->models_url != NULL && p->models_url[0] != '\0' &&
        profile_has_credential_source(p)) {
        char chat_origin[TS_PROFILE_HOST_MAX + 32];
        char models_origin[TS_PROFILE_HOST_MAX + 32];
        ts_url_normalized_origin(p->chat_url, chat_origin, sizeof(chat_origin));
        ts_url_normalized_origin(p->models_url, models_origin, sizeof(models_origin));
        if (chat_origin[0] != '\0' && models_origin[0] != '\0' &&
            strcmp(chat_origin, models_origin) != 0) {
            snprintf(msg, sizeof(msg),
                     "profile %s 的模型列表地址必须与对话地址同源（本次是 %s → %s）；"
                     "需要跨源请新建独立连接",
                     p->id, chat_origin, models_origin);
            return fail(err, err_sz, msg);
        }
    }
    if (p->model_id == NULL || p->model_id[0] == '\0') {
        snprintf(msg, sizeof(msg), "profile %s 缺少模型名称", p->id);
        return fail(err, err_sz, msg);
    }
    if (strlen(p->model_id) > TS_PROFILE_MODEL_MAX) {
        snprintf(msg, sizeof(msg), "profile %s 的模型名称过长", p->id);
        return fail(err, err_sz, msg);
    }
    if (p->protocol != TS_PROTOCOL_LEGACY &&
        p->protocol != TS_PROTOCOL_DEEPSEEK_CHAT &&
        p->protocol != TS_PROTOCOL_OPENAI_CHAT) {
        snprintf(msg, sizeof(msg), "profile %s 的 protocol 取值无效", p->id);
        return fail(err, err_sz, msg);
    }
    if (p->thinking != TS_THINKING_UNSUPPORTED &&
        p->thinking != TS_THINKING_DISABLED &&
        p->thinking != TS_THINKING_ENABLED) {
        snprintf(msg, sizeof(msg), "profile %s 的 thinking 取值无效", p->id);
        return fail(err, err_sz, msg);
    }
    /*
     * OpenAI 兼容协议：「能力未知不显示为已验证」，因此不允许声称开启思考。
     */
    if (p->protocol == TS_PROTOCOL_OPENAI_CHAT && p->thinking == TS_THINKING_ENABLED) {
        snprintf(msg, sizeof(msg),
                 "profile %s 使用 openai-chat 协议时不支持开启思考模式", p->id);
        return fail(err, err_sz, msg);
    }
    if (p->thinking == TS_THINKING_ENABLED) {
        if (!effort_ok(p->reasoning_effort)) {
            snprintf(msg, sizeof(msg),
                     "profile %s 开启思考模式时 reasoningEffort 必须是 low/high/max", p->id);
            return fail(err, err_sz, msg);
        }
    } else {
        /* 关闭/不支持时**不得残留** effort，否则请求体会带上无意义的参数。 */
        if (p->reasoning_effort != NULL && p->reasoning_effort[0] != '\0') {
            snprintf(msg, sizeof(msg),
                     "profile %s 未开启思考模式时不应保留 reasoningEffort（当前为 %s）",
                     p->id, p->reasoning_effort);
            return fail(err, err_sz, msg);
        }
    }
    return 0;
}

int ts_profile_list_validate(const TsProfileList *l, char *err, size_t err_sz)
{
    size_t i;
    size_t j;
    if (l == NULL) return fail(err, err_sz, "设置列表为空指针");

    if (l->schema_version != TS_SETTINGS_SCHEMA_VERSION) {
        char msg[160];
        snprintf(msg, sizeof(msg), "设置版本不兼容（期望 %d，实际 %d）",
                 TS_SETTINGS_SCHEMA_VERSION, l->schema_version);
        return fail(err, err_sz, msg);
    }

    for (i = 0; i < l->count; i++) {
        if (ts_profile_validate(&l->items[i], err, err_sz) != 0) return 1;
        for (j = 0; j < i; j++) {
            if (strcmp(l->items[i].id, l->items[j].id) == 0) {
                char msg[256];
                snprintf(msg, sizeof(msg), "profile id 重复：%s", l->items[i].id);
                return fail(err, err_sz, msg);
            }
        }
    }

    if (l->count == 0) {
        /*
         * 空列表：默认值也必须为空，否则会“指向一个已被删除的 profile”，
         * 让界面看起来有默认连接但实际不存在。
         */
        if (l->default_profile_id != NULL && l->default_profile_id[0] != '\0') {
            return fail(err, err_sz,
                        "没有任何连接时 defaultProfileId 必须为空（当前指向不存在的连接）");
        }
        return 0;
    }

    if (l->default_profile_id == NULL || l->default_profile_id[0] == '\0') {
        return fail(err, err_sz, "defaultProfileId 不能为空（必须指向一个存在的连接）");
    }
    if (ts_profile_list_find(l, l->default_profile_id) == NULL) {
        char msg[320];
        snprintf(msg, sizeof(msg),
                 "defaultProfileId 指向不存在的连接：%s", l->default_profile_id);
        return fail(err, err_sz, msg);
    }
    if (l->default_model_id == NULL || l->default_model_id[0] == '\0') {
        return fail(err, err_sz, "defaultModelId 不能为空");
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* JSON 解析                                                           */
/* ------------------------------------------------------------------ */

int ts_profile_from_json(const cJSON *obj, TsProfile *out, char *err, size_t err_sz)
{
    const char *s;
    TsProtocol proto = TS_PROTOCOL_LEGACY;
    TsThinking think = TS_THINKING_UNSUPPORTED;

    if (obj == NULL || !cJSON_IsObject(obj)) {
        return fail(err, err_sz, "profile 必须是 JSON 对象");
    }
    if (out == NULL) return fail(err, err_sz, "profile 输出参数为空");
    ts_profile_init(out);

    s = jstr(obj, "id");
    if (s == NULL) return fail(err, err_sz, "profile 缺少 id");
    out->id = ts_strdup(s);
    if (out->id == NULL) goto oom;

    s = jstr(obj, "name");
    if (s == NULL) return fail(err, err_sz, "profile 缺少 name");
    out->name = ts_strdup(s);
    if (out->name == NULL) goto oom;

    out->revision = jlong(obj, "revision", 0);

    s = jstr(obj, "protocol");
    if (s != NULL) {
        if (ts_protocol_parse(s, &proto) != 0) {
            snprintf(err, err_sz, "profile %s 的 protocol 无法识别：%s",
                     out->id != NULL ? out->id : "(无 id)", s);
            ts_profile_free(out);
            return 1;
        }
    }
    out->protocol = proto;

    s = jstr(obj, "baseUrl");
    if (s != NULL && s[0] != '\0') {
        out->base_url = ts_strdup(s);
        if (out->base_url == NULL) goto oom;
    }

    s = jstr(obj, "chatUrl");
    if (s == NULL || s[0] == '\0') {
        snprintf(err, err_sz, "profile %s 缺少 chatUrl",
                 out->id != NULL ? out->id : "(无 id)");
        ts_profile_free(out);
        return 1;
    }
    out->chat_url = ts_strdup(s);
    if (out->chat_url == NULL) goto oom;

    s = jstr(obj, "modelsUrl");
    if (s != NULL && s[0] != '\0') {
        out->models_url = ts_strdup(s);
        if (out->models_url == NULL) goto oom;
    }

    s = jstr(obj, "authMode");
    out->auth_mode = ts_strdup((s != NULL && s[0] != '\0') ? s : ts_auth_mode_bearer());
    if (out->auth_mode == NULL) goto oom;

    s = jstr(obj, "apiKeyEnv");
    if (s != NULL) {
        out->api_key_env = ts_strdup(s);
        if (out->api_key_env == NULL) goto oom;
    }

    s = jstr(obj, "modelId");
    if (s == NULL || s[0] == '\0') {
        snprintf(err, err_sz, "profile %s 缺少 modelId",
                 out->id != NULL ? out->id : "(无 id)");
        ts_profile_free(out);
        return 1;
    }
    out->model_id = ts_strdup(s);
    if (out->model_id == NULL) goto oom;

    s = jstr(obj, "thinking");
    if (s != NULL) {
        if (ts_thinking_parse(s, &think) != 0) {
            snprintf(err, err_sz, "profile %s 的 thinking 无法识别：%s",
                     out->id != NULL ? out->id : "(无 id)", s);
            ts_profile_free(out);
            return 1;
        }
    } else {
        think = (out->protocol == TS_PROTOCOL_OPENAI_CHAT)
                    ? TS_THINKING_UNSUPPORTED : TS_THINKING_DISABLED;
    }
    out->thinking = think;

    /*
     * reasoningEffort：显式 null / 缺失 / 空串都视为“不发送”。
     * 关闭思考时若调用方仍传了值，这里**保留**它，由 ts_profile_validate 报错，
     * 而不是悄悄丢掉——静默改写会让界面与实际请求不一致。
     */
    if (jhas(obj, "reasoningEffort")) {
        const cJSON *re = cJSON_GetObjectItemCaseSensitive(obj, "reasoningEffort");
        if (cJSON_IsString(re)) {
            const char *v = cJSON_GetStringValue(re);
            if (v != NULL && v[0] != '\0') {
                out->reasoning_effort = ts_strdup(v);
                if (out->reasoning_effort == NULL) goto oom;
            }
        }
    }

    out->json_mode = jbool(obj, "jsonMode", 0);
    out->credential_configured = jbool(obj, "credentialConfigured", 0);

    s = jstr(obj, "credentialHost");
    if (s != NULL && s[0] != '\0') {
        out->credential_host = ts_strdup(s);
        if (out->credential_host == NULL) goto oom;
    }
    if (!out->credential_configured) {
        /* 没有凭据时不应声称绑定到某个主机。 */
        ts_free(out->credential_host);
        out->credential_host = NULL;
    }

    return 0;

oom:
    ts_profile_free(out);
    return fail(err, err_sz, "内存分配失败");
}

int ts_profile_list_from_json(const cJSON *root, TsProfileList *out,
                              char *err, size_t err_sz)
{
    const cJSON *profiles;
    const cJSON *item;
    const char *s;
    int n;
    int i;

    if (root == NULL || !cJSON_IsObject(root)) {
        return fail(err, err_sz, "设置必须是 JSON 对象");
    }
    if (out == NULL) return fail(err, err_sz, "设置输出参数为空");
    ts_profile_list_init(out);

    out->schema_version = (int)jlong(root, "schemaVersion", TS_SETTINGS_SCHEMA_VERSION);
    if (out->schema_version != TS_SETTINGS_SCHEMA_VERSION) {
        char msg[192];
        snprintf(msg, sizeof(msg),
                 "设置文件版本不兼容（期望 schemaVersion=%d，实际 %d）；"
                 "为避免覆盖用户数据，本次不写入磁盘",
                 TS_SETTINGS_SCHEMA_VERSION, out->schema_version);
        return fail(err, err_sz, msg);
    }

    profiles = cJSON_GetObjectItemCaseSensitive(root, "profiles");
    if (profiles != NULL && !cJSON_IsNull(profiles)) {
        if (!cJSON_IsArray(profiles)) {
            return fail(err, err_sz, "profiles 必须是数组");
        }
        n = cJSON_GetArraySize(profiles);
        for (i = 0; i < n; i++) {
            item = cJSON_GetArrayItem(profiles, i);
            {
                TsProfile tmp;
                ts_profile_init(&tmp);
                if (ts_profile_from_json(item, &tmp, err, err_sz) != 0) {
                    ts_profile_free(&tmp);
                    return 1;
                }
                if (ts_profile_list_append(out, &tmp) != 0) {
                    ts_profile_free(&tmp);
                    return fail(err, err_sz, "内存分配失败");
                }
                ts_profile_free(&tmp);
            }
        }
    }

    s = jstr(root, "defaultProfileId");
    if (s != NULL && s[0] != '\0') {
        out->default_profile_id = ts_strdup(s);
        if (out->default_profile_id == NULL) goto oom;
    }

    s = jstr(root, "defaultModelId");
    if (s != NULL && s[0] != '\0') {
        out->default_model_id = ts_strdup(s);
        if (out->default_model_id == NULL) goto oom;
    }

    s = jstr(root, "defaultThinking");
    if (s != NULL) {
        TsThinking t = TS_THINKING_UNSUPPORTED;
        if (ts_thinking_parse(s, &t) == 0) {
            out->default_thinking = t;
        }
    }

    s = jstr(root, "defaultReasoningEffort");
    if (s != NULL && s[0] != '\0') {
        out->default_reasoning_effort = ts_strdup(s);
        if (out->default_reasoning_effort == NULL) goto oom;
    }

    return 0;

oom:
    ts_profile_list_free(out);
    return fail(err, err_sz, "内存分配失败");
}

int ts_profile_list_parse(const char *json, size_t len, TsProfileList *out,
                          char *err, size_t err_sz)
{
    cJSON *root;
    int rc;
    if (json == NULL || len == 0) {
        ts_profile_list_init(out);
        return fail(err, err_sz, "设置 JSON 为空");
    }
    root = cJSON_ParseWithLength(json, len);
    if (root == NULL) {
        ts_profile_list_init(out);
        return fail(err, err_sz, "设置 JSON 解析失败（文件可能已损坏）");
    }
    rc = ts_profile_list_from_json(root, out, err, err_sz);
    cJSON_Delete(root);
    return rc;
}

/* ------------------------------------------------------------------ */
/* JSON 序列化                                                         */
/* ------------------------------------------------------------------ */

static void add_str_or_null(cJSON *o, const char *key, const char *v)
{
    if (v != NULL) {
        cJSON_AddStringToObject(o, key, v);
    } else {
        cJSON_AddNullToObject(o, key);
    }
}

cJSON *ts_profile_to_json(const TsProfile *p)
{
    cJSON *o;
    if (p == NULL) return NULL;
    o = cJSON_CreateObject();
    if (o == NULL) return NULL;

    cJSON_AddStringToObject(o, "id", p->id != NULL ? p->id : "");
    cJSON_AddStringToObject(o, "name", p->name != NULL ? p->name : "");
    cJSON_AddNumberToObject(o, "revision", (double)p->revision);
    cJSON_AddStringToObject(o, "protocol", ts_protocol_name(p->protocol));
    add_str_or_null(o, "baseUrl", p->base_url);
    cJSON_AddStringToObject(o, "chatUrl", p->chat_url != NULL ? p->chat_url : "");
    add_str_or_null(o, "modelsUrl", p->models_url);
    cJSON_AddStringToObject(o, "authMode",
                            p->auth_mode != NULL ? p->auth_mode : ts_auth_mode_bearer());
    cJSON_AddStringToObject(o, "apiKeyEnv", p->api_key_env != NULL ? p->api_key_env : "");
    cJSON_AddStringToObject(o, "modelId", p->model_id != NULL ? p->model_id : "");
    cJSON_AddStringToObject(o, "thinking", ts_thinking_name(p->thinking));
    add_str_or_null(o, "reasoningEffort", p->reasoning_effort);
    cJSON_AddBoolToObject(o, "jsonMode", p->json_mode ? 1 : 0);
    cJSON_AddBoolToObject(o, "credentialConfigured", p->credential_configured ? 1 : 0);
    cJSON_AddStringToObject(o, "credentialHost",
                            p->credential_host != NULL ? p->credential_host : "");
    return o;
}

cJSON *ts_profile_list_to_json(const TsProfileList *l)
{
    cJSON *root;
    cJSON *arr;
    size_t i;

    if (l == NULL) return NULL;
    root = cJSON_CreateObject();
    if (root == NULL) return NULL;
    arr = cJSON_CreateArray();
    if (arr == NULL) {
        cJSON_Delete(root);
        return NULL;
    }

    cJSON_AddNumberToObject(root, "schemaVersion", (double)TS_SETTINGS_SCHEMA_VERSION);
    cJSON_AddStringToObject(root, "defaultProfileId",
                            l->default_profile_id != NULL ? l->default_profile_id : "");
    cJSON_AddStringToObject(root, "defaultModelId",
                            l->default_model_id != NULL ? l->default_model_id : "");
    cJSON_AddStringToObject(root, "defaultThinking",
                            ts_thinking_name(l->default_thinking));
    add_str_or_null(root, "defaultReasoningEffort", l->default_reasoning_effort);

    for (i = 0; i < l->count; i++) {
        cJSON *o = ts_profile_to_json(&l->items[i]);
        if (o == NULL || !cJSON_AddItemToArray(arr, o)) {
            if (o != NULL) cJSON_Delete(o);
            cJSON_Delete(arr);
            cJSON_Delete(root);
            return NULL;
        }
    }
    if (!cJSON_AddItemToObject(root, "profiles", arr)) {
        cJSON_Delete(arr);
        cJSON_Delete(root);
        return NULL;
    }
    return root;
}

char *ts_profile_list_print(const TsProfileList *l)
{
    cJSON *root = ts_profile_list_to_json(l);
    char *printed;
    if (root == NULL) return NULL;
    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return printed;
}

/* ------------------------------------------------------------------ */
/* URL 辅助                                                            */
/* ------------------------------------------------------------------ */

const char *ts_url_host(const char *url, char *out, size_t out_sz)
{
    const char *p;
    const char *q;
    const char *at = NULL;
    size_t n;
    size_t i;

    if (out == NULL || out_sz == 0) return "";
    out[0] = '\0';
    if (url == NULL || url[0] == '\0') return out;

    p = strstr(url, "://");
    p = (p != NULL) ? (p + 3) : url;

    /* 丢弃 userinfo（最后一段 '@' 之前）。 */
    for (q = p; *q != '\0'; q++) {
        if (*q == '@') { at = q; continue; }
        if (*q == '/' || *q == '?' || *q == '#') break;
    }
    if (at != NULL) p = at + 1;

    q = p;
    while (*q != '\0' && *q != '/' && *q != '?' && *q != '#' && *q != ':') q++;
    n = (size_t)(q - p);
    if (n >= out_sz) n = out_sz - 1;
    for (i = 0; i < n; i++) {
        char c = p[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        out[i] = c;
    }
    out[n] = '\0';
    return out;
}

const char *ts_url_origin(const char *url, char *out, size_t out_sz)
{
    const char *p;
    const char *q;
    size_t need;
    size_t n;

    if (out == NULL || out_sz == 0) return "";
    out[0] = '\0';
    if (url == NULL || url[0] == '\0') return out;

    q = strstr(url, "://");
    if (q == NULL) {
        /* 没有 scheme：不猜，直接返回原文的 authority 部分。 */
        q = url;
    } else {
        q += 3;
    }
    p = url;
    while (q > url && *q != '/' && *q != '?' && *q != '#') q++;
    need = (size_t)(q - p);
    n = need;
    if (n >= out_sz) n = out_sz - 1;
    memcpy(out, p, n);
    out[n] = '\0';
    return out;
}

/* ------------------------------------------------------------------ */
/* 规范化 origin（同源判定）                                           */
/* ------------------------------------------------------------------ */

static int url_split_origin(const char *url,
                            char *scheme, size_t scheme_sz,
                            char *host, size_t host_sz,
                            int *port)
{
    const char *sep;
    const char *auth_end;
    const char *p;
    const char *q;
    const char *at;
    size_t n;
    size_t i;
    int default_port = 0;

    if (scheme == NULL || host == NULL || port == NULL ||
        scheme_sz == 0 || host_sz == 0) {
        return 1;
    }
    scheme[0] = '\0';
    host[0] = '\0';
    *port = 0;
    if (url == NULL || url[0] == '\0') return 1;

    sep = strstr(url, "://");
    if (sep == NULL) return 1;
    n = (size_t)(sep - url);
    if (n == 0 || n + 1 > scheme_sz) return 1;
    for (i = 0; i < n; i++) {
        char c = url[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        scheme[i] = c;
    }
    scheme[n] = '\0';
    if (strcmp(scheme, "http") == 0) {
        default_port = 80;
    } else if (strcmp(scheme, "https") == 0) {
        default_port = 443;
    } else {
        scheme[0] = '\0';
        return 1;   /* 非 http(s)：不参与同源判定 */
    }

    p = sep + 3;
    auth_end = p;
    while (*auth_end != '\0' && *auth_end != '/' && *auth_end != '?' && *auth_end != '#') {
        auth_end++;
    }
    /* 丢弃 userinfo（最后一段 '@' 之前）。 */
    at = NULL;
    for (q = p; q < auth_end; q++) {
        if (*q == '@') at = q;
    }
    if (at != NULL) p = at + 1;

    q = p;
    if (q < auth_end && *q == '[') {
        /*
         * IPv6 字面量：[::1] 或 [::1]:8080。
         * 方括号里的冒号不是端口分隔符，必须整体当作 host，
         * 否则带 IPv6 地址的连接会被误判成“无法同源”。
         */
        const char *close = q + 1;
        while (close < auth_end && *close != ']') close++;
        if (close >= auth_end) {
            scheme[0] = '\0';
            return 1;
        }
        n = (size_t)(close - q) + 1;
        if (n + 1 > host_sz) {
            scheme[0] = '\0';
            return 1;
        }
        for (i = 0; i < n; i++) {
            char c = q[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            host[i] = c;
        }
        host[n] = '\0';
        q = close + 1;
        if (q < auth_end && *q != ':') {
            scheme[0] = '\0';
            host[0] = '\0';
            return 1;
        }
    } else {
        while (q < auth_end && *q != ':') q++;
        n = (size_t)(q - p);
        if (n == 0 || n + 1 > host_sz) {
            scheme[0] = '\0';
            return 1;
        }
        for (i = 0; i < n; i++) {
            char c = p[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            host[i] = c;
        }
        host[n] = '\0';
    }

    if (q < auth_end && *q == ':') {
        long v = 0;
        int digits = 0;
        const char *r = q + 1;
        while (r < auth_end) {
            if (*r < '0' || *r > '9') {
                scheme[0] = '\0';
                host[0] = '\0';
                return 1;
            }
            v = v * 10 + (*r - '0');
            if (v > 65535) {
                scheme[0] = '\0';
                host[0] = '\0';
                return 1;
            }
            digits++;
            r++;
        }
        if (digits == 0) {
            scheme[0] = '\0';
            host[0] = '\0';
            return 1;
        }
        /* 显式写出的默认端口与省略等价（同源比较必须如此）。 */
        *port = (v == (long)default_port) ? 0 : (int)v;
    }
    return 0;
}

const char *ts_url_normalized_origin(const char *url, char *out, size_t out_sz)
{
    char scheme[16];
    char host[TS_PROFILE_HOST_MAX];
    int port = 0;

    if (out == NULL || out_sz == 0) return "";
    out[0] = '\0';
    if (url_split_origin(url, scheme, sizeof(scheme), host, sizeof(host), &port) != 0) {
        return out;
    }
    if (port > 0) {
        snprintf(out, out_sz, "%s://%s:%d", scheme, host, port);
    } else {
        snprintf(out, out_sz, "%s://%s", scheme, host);
    }
    return out;
}

int ts_url_same_origin(const char *a, const char *b)
{
    char oa[TS_PROFILE_HOST_MAX + 32];
    char ob[TS_PROFILE_HOST_MAX + 32];

    if (a == NULL || b == NULL) return 0;
    ts_url_normalized_origin(a, oa, sizeof(oa));
    ts_url_normalized_origin(b, ob, sizeof(ob));
    /* 任一无法解析：无法证明同源 → 视为不同源（绝不静默放行）。 */
    if (oa[0] == '\0' || ob[0] == '\0') return 0;
    return strcmp(oa, ob) == 0 ? 1 : 0;
}

char *ts_url_derive_models(const char *chat_url)
{
    size_t n;
    size_t suffix;
    char *out;
    if (chat_url == NULL || chat_url[0] == '\0') return NULL;
    n = strlen(chat_url);
    suffix = strlen("/chat/completions");
    if (n < suffix) return NULL;
    if (_strnicmp(chat_url + n - suffix, "/chat/completions", suffix) != 0) return NULL;

    out = (char *)malloc(n - suffix + strlen("/models") + 1);
    if (out == NULL) return NULL;
    memcpy(out, chat_url, n - suffix);
    memcpy(out + (n - suffix), "/models", strlen("/models") + 1);
    return out;
}

/* ------------------------------------------------------------------ */
/* 与 TsConfig 的互转                                                  */
/* ------------------------------------------------------------------ */

int ts_profile_apply_to_config(const TsProfile *p, TsConfig *cfg)
{
    char *chat = NULL;
    char *model = NULL;
    char *models = NULL;
    char *auth = NULL;
    char *pid = NULL;
    char *effort = NULL;
    char *host = NULL;
    char *env = NULL;

    if (p == NULL || cfg == NULL) return 1;

    chat = ts_strdup(p->chat_url != NULL ? p->chat_url : "");
    model = ts_strdup(p->model_id != NULL ? p->model_id : "");
    auth = ts_strdup(p->auth_mode != NULL ? p->auth_mode : ts_auth_mode_bearer());
    pid = ts_strdup(p->id != NULL ? p->id : "");
    /*
     * thinking_effort / reasoning_effort 保持同步：legacy(0) 协议的请求构造
     * 仍然只看 reasoning_effort，这样旧测试与旧配置行为完全不变。
     */
    effort = (p->thinking == TS_THINKING_ENABLED)
                 ? ts_strdup(p->reasoning_effort) : NULL;
    if (p->models_url != NULL && p->models_url[0] != '\0') {
        models = ts_strdup(p->models_url);
    }
    if (p->credential_host != NULL && p->credential_host[0] != '\0') {
        host = ts_strdup(p->credential_host);
    }
    if (p->api_key_env != NULL) {
        env = ts_strdup(p->api_key_env);
    }

    if (chat == NULL || model == NULL || auth == NULL || pid == NULL ||
        (p->thinking == TS_THINKING_ENABLED && p->reasoning_effort != NULL && effort == NULL)) {
        ts_free(chat); ts_free(model); ts_free(auth); ts_free(pid);
        ts_free(models); ts_free(effort); ts_free(host); ts_free(env);
        return 1;
    }

    ts_free(cfg->endpoint_url);
    ts_free(cfg->model);
    ts_free(cfg->models_url);
    ts_free(cfg->auth_mode);
    ts_free(cfg->profile_id);
    ts_free(cfg->thinking_effort);
    ts_free(cfg->credential_host);
    ts_free(cfg->api_key_env);
    ts_free(cfg->reasoning_effort);

    cfg->endpoint_url = chat;
    cfg->model = model;
    cfg->models_url = models;
    cfg->auth_mode = auth;
    cfg->profile_id = pid;
    cfg->thinking_effort = effort;
    cfg->reasoning_effort = (effort != NULL) ? ts_strdup(effort) : NULL;
    cfg->credential_host = host;
    cfg->api_key_env = env;
    cfg->profile_revision = p->revision;
    cfg->protocol = (int)p->protocol;
    cfg->thinking = (int)p->thinking;
    cfg->json_mode = p->json_mode ? 1 : 0;
    return 0;
}

int ts_profile_from_legacy_config(const TsConfig *cfg, const char *profile_id,
                                  TsProfile *out, char *err, size_t err_sz)
{
    char host[TS_PROFILE_HOST_MAX];
    char origin[TS_PROFILE_URL_MAX + 16];
    const char *id;
    int deepseek;
    TsThinking think;

    if (cfg == NULL || out == NULL) return fail(err, err_sz, "迁移参数为空");
    ts_profile_init(out);

    if (cfg->endpoint_url == NULL || cfg->endpoint_url[0] == '\0') {
        return fail(err, err_sz, "旧配置缺少 endpoint_url，无法迁移");
    }
    if (cfg->model == NULL || cfg->model[0] == '\0') {
        return fail(err, err_sz, "旧配置缺少 model，无法迁移");
    }

    id = (profile_id != NULL && profile_id[0] != '\0') ? profile_id : "legacy";
    out->id = ts_strdup(id);
    if (out->id == NULL) goto oom;
    out->name = ts_strdup("旧配置 (config.json)");
    if (out->name == NULL) goto oom;
    out->revision = 1;

    ts_url_host(cfg->endpoint_url, host, sizeof(host));
    ts_url_origin(cfg->endpoint_url, origin, sizeof(origin));

    /*
     * 迁移出来的 profile 不使用 legacy(0)：规格 §5 要求旧测试继续依赖 0，
     * 而迁移结果走 1/2。是否 DeepSeek 官方按主机名判断（只用于选择协议形状）。
     */
    deepseek = (host[0] != '\0' && strstr(host, "deepseek.com") != NULL) ? 1 : 0;
    out->protocol = deepseek ? TS_PROTOCOL_DEEPSEEK_CHAT : TS_PROTOCOL_OPENAI_CHAT;

    out->base_url = ts_strdup(origin);
    if (out->base_url == NULL) goto oom;
    out->chat_url = ts_strdup(cfg->endpoint_url);
    if (out->chat_url == NULL) goto oom;
    out->models_url = ts_url_derive_models(cfg->endpoint_url);

    out->model_id = ts_strdup(cfg->model);
    if (out->model_id == NULL) goto oom;

    /*
     * 旧配置的语义：api_key 内联 或 api_key_env 非空 → 需要鉴权；
     * 两者都没有 / api_key_env 显式空串 → 无需鉴权。
     * 这里沿用 ts_config_requires_auth 的判定，避免把“没写”当成“要鉴权”。
     */
    {
        int needs_auth = (cfg->api_key != NULL && cfg->api_key[0] != '\0') ||
                         (cfg->api_key_env != NULL && cfg->api_key_env[0] != '\0');
        out->auth_mode = ts_strdup(needs_auth ? ts_auth_mode_bearer() : ts_auth_mode_none());
        if (out->auth_mode == NULL) goto oom;
        if (needs_auth) {
            out->credential_host = ts_strdup(host);
            if (out->credential_host == NULL) goto oom;
        }
    }

    if (cfg->api_key_env != NULL && cfg->api_key_env[0] != '\0') {
        out->api_key_env = ts_strdup(cfg->api_key_env);
        if (out->api_key_env == NULL) goto oom;
    }

    /*
     * thinking / reasoning_effort：
     *   - deepseek-chat：旧配置写了 low/high/max → enabled；否则 disabled
     *     （旧配置里 "none" 表示关闭思考）。
     *   - openai-chat：能力未知 → unsupported，且不保留 effort。
     */
    think = TS_THINKING_UNSUPPORTED;
    if (out->protocol == TS_PROTOCOL_DEEPSEEK_CHAT) {
        if (cfg->reasoning_effort != NULL &&
            (strcmp(cfg->reasoning_effort, "low") == 0 ||
             strcmp(cfg->reasoning_effort, "high") == 0 ||
             strcmp(cfg->reasoning_effort, "max") == 0)) {
            think = TS_THINKING_ENABLED;
            out->reasoning_effort = ts_strdup(cfg->reasoning_effort);
            if (out->reasoning_effort == NULL) goto oom;
        } else {
            think = TS_THINKING_DISABLED;
        }
    }
    out->thinking = think;

    out->json_mode = cfg->json_mode ? 1 : 0;

    if (ts_profile_validate(out, err, err_sz) != 0) {
        ts_profile_free(out);
        return 1;
    }
    return 0;

oom:
    ts_profile_free(out);
    return fail(err, err_sz, "内存分配失败");
}

