/*
 * test_settings.c — 0.0.4 设置功能的离线测试（不联网、不需要真实密钥）。
 *
 * 覆盖 docs/SETTINGS_0_0_4_SPEC.md §11 的第 1、6 组，以及 §2/§3/§4/§5 的规则：
 *   A. TsConfig 深拷贝 / 安全擦除 / profile ↔ config 互转
 *   B. profile JSON 往返与校验（id 字符集、revision、effort 残留、URL 必填）
 *   C. 请求体形状（legacy / deepseek-chat / openai-chat × thinking / effort / json_mode）
 *   D. settings.json 原子保存、.bak、乐观 revision、删除、损坏与版本不兼容
 *   E. 旧 config.json 迁移（legacy profile + 内联密钥一次性导入凭据，旧文件不改）
 *   F. Windows 凭据 set / load / delete 往返（测试后删除测试条目）
 *
 * 所有密钥都是明显虚构的 `sk-test-…`，且不会被打印。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../src/state/config.h"
#include "../src/platform/credential.h"
#include "../src/util/mem.h"
#include "../src/domain/analysis/model.h"
#include "../src/state/profile.h"
#include "../src/state/profile_store.h"
#include "../src/domain/analysis/prompt.h"
#include "../src/platform/text.h"

#include "cJSON.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg) do {                                          \
    if (cond) { g_pass++; printf("  [PASS] %s\n", msg); }               \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }                    \
} while (0)

static int contains(const char *hay, const char *needle)
{
    return hay != NULL && needle != NULL && strstr(hay, needle) != NULL;
}

static void write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    if (f != NULL) {
        fwrite(text, 1, strlen(text), f);
        fclose(f);
    }
}

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    long sz;
    char *data;
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    data = (char *)malloc((size_t)sz + 1);
    if (data == NULL) { fclose(f); return NULL; }
    if (fread(data, 1, (size_t)sz, f) != (size_t)sz) { free(data); fclose(f); return NULL; }
    data[sz] = '\0';
    fclose(f);
    return data;
}

static int file_exists(const char *path)
{
    DWORD a = GetFileAttributesA(path);
    return (a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0) ? 1 : 0;
}

static const char *g_dir = ".";

static void join(char *out, size_t sz, const char *name)
{
    snprintf(out, sz, "%s\\%s", g_dir, name);
}

/* ------------------------------------------------------------------ */
/* profile 构造辅助                                                    */
/* ------------------------------------------------------------------ */

static void fill_profile(TsProfile *p, const char *id, TsProtocol proto,
                         TsThinking think, const char *effort)
{
    ts_profile_init(p);
    p->id = ts_strdup(id);
    p->name = ts_strdup("测试连接");
    p->revision = 1;
    p->protocol = proto;
    p->base_url = ts_strdup("https://api.example.invalid");
    p->chat_url = ts_strdup("https://api.example.invalid/chat/completions");
    p->models_url = ts_strdup("https://api.example.invalid/models");
    p->auth_mode = ts_strdup(ts_auth_mode_bearer());
    p->model_id = ts_strdup("deepseek-chat");
    p->thinking = think;
    p->reasoning_effort = effort != NULL ? ts_strdup(effort) : NULL;
    p->json_mode = 1;
}

/* ------------------------------------------------------------------ */
/* A. 深拷贝与安全擦除                                                 */
/* ------------------------------------------------------------------ */

static void test_config_copy(void)
{
    TsConfig a, b;

    printf("== A. TsConfig 深拷贝 / 安全擦除 ==\n");

    ts_config_init(&a);
    a.endpoint_url = ts_strdup("https://api.example.invalid/chat/completions");
    a.model = ts_strdup("m-1");
    a.api_key = ts_strdup("sk-test-copy-0123456789");
    a.profile_id = ts_strdup("p-1");
    a.models_url = ts_strdup("https://api.example.invalid/models");
    a.auth_mode = ts_strdup("bearer");
    a.thinking_effort = ts_strdup("high");
    a.protocol = (int)TS_PROTOCOL_DEEPSEEK_CHAT;
    a.thinking = (int)TS_THINKING_ENABLED;
    a.profile_revision = 7;
    a.probe_timeout_ms = 12000;

    CHECK(ts_config_copy(&b, &a) == 0, "ts_config_copy 成功");
    CHECK(b.endpoint_url != a.endpoint_url && b.model != a.model &&
          b.api_key != a.api_key && b.profile_id != a.profile_id &&
          b.thinking_effort != a.thinking_effort,
          "拷贝后所有 owned 字段都是独立分配（不是浅拷贝）");
    CHECK(b.api_key != NULL && strcmp(b.api_key, a.api_key) == 0, "密钥内容被复制");
    CHECK(b.profile_revision == 7 && b.protocol == (int)TS_PROTOCOL_DEEPSEEK_CHAT &&
          b.thinking == (int)TS_THINKING_ENABLED && b.probe_timeout_ms == 12000,
          "标量字段被复制");

    /* 修改源不应影响副本 */
    b.model[0] = 'X';
    CHECK(a.model[0] == 'm', "副本与源不共享内存");

    ts_config_free(&a);
    ts_config_free(&b);

    {
        char *k = ts_strdup("sk-test-secure-free");
        ts_secure_free(&k);
        CHECK(k == NULL, "ts_secure_free 释放后把指针置 NULL");
        ts_secure_free(&k);
        ts_secure_free(NULL);
        CHECK(1, "ts_secure_free 对 NULL 安全");
    }

    /* move：指针交换，不重新分配 */
    {
        TsConfig x, y;
        char *orig;
        ts_config_init(&x);
        ts_config_init(&y);
        x.model = ts_strdup("from-x");
        orig = x.model;
        ts_config_move(&y, &x);
        CHECK(y.model == orig && x.model == NULL, "ts_config_move 用指针交换移交所有权");
        ts_config_free(&x);
        ts_config_free(&y);
    }
}

/* ------------------------------------------------------------------ */
/* B. profile JSON 与校验                                              */
/* ------------------------------------------------------------------ */

static void test_profile_json_and_validate(void)
{
    TsProfile p;
    TsProfile back;
    cJSON *o;
    char err[512];

    printf("\n== B. profile JSON 往返与校验 ==\n");

    fill_profile(&p, "deepseek-official", TS_PROTOCOL_DEEPSEEK_CHAT,
                 TS_THINKING_ENABLED, "high");
    p.json_mode = 1;
    p.credential_configured = 1;
    ts_free(p.credential_host);
    p.credential_host = ts_strdup("api.example.invalid");

    err[0] = '\0';
    CHECK(ts_profile_validate(&p, err, sizeof(err)) == 0, "合法 profile 通过校验");

    o = ts_profile_to_json(&p);
    CHECK(o != NULL, "profile 序列化为 cJSON 对象");
    ts_profile_init(&back);
    err[0] = '\0';
    CHECK(o != NULL && ts_profile_from_json(o, &back, err, sizeof(err)) == 0,
          "profile JSON 可被解析回来");
    if (o != NULL) cJSON_Delete(o);

    CHECK(back.id != NULL && strcmp(back.id, "deepseek-official") == 0, "id 往返一致");
    CHECK(back.revision == 1, "revision 往返一致");
    CHECK(back.protocol == TS_PROTOCOL_DEEPSEEK_CHAT, "protocol 往返一致");
    CHECK(back.thinking == TS_THINKING_ENABLED && back.reasoning_effort != NULL &&
          strcmp(back.reasoning_effort, "high") == 0, "thinking / effort 往返一致");
    CHECK(back.credential_configured == 1 && back.credential_host != NULL,
          "凭据元信息往返一致");
    CHECK(back.json_mode == 1, "jsonMode 往返一致");

    /* --- 拒绝路径 --- */
    {
        TsProfile bad;
        fill_profile(&bad, "has space", TS_PROTOCOL_DEEPSEEK_CHAT,
                     TS_THINKING_DISABLED, NULL);
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "id 含空格被拒绝（无法作为凭据目标名）");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        bad.revision = 0;
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0, "revision=0 被拒绝");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        ts_free(bad.chat_url);
        bad.chat_url = ts_strdup("api.example.invalid/chat/completions");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "chatUrl 缺少 http(s):// 前缀被拒绝（不猜路径也不补 /v1）");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_OPENAI_CHAT, TS_THINKING_ENABLED, "high");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "openai-chat 协议声称开启思考被拒绝（能力未知不假装已验证）");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, "high");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "关闭思考时残留 reasoningEffort 被拒绝");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_ENABLED, "none");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "开启思考时 effort=none 被拒绝（只能是 low/high/max）");
        ts_profile_free(&bad);
    }

    /*
     * 凭据授权范围（0.0.4 验收修复 1）：配置了凭据来源时，
     * modelsUrl 必须与 chatUrl 同源，否则模型发现请求会把对话密钥发到别的 origin。
     */
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        ts_free(bad.models_url);
        bad.models_url = ts_strdup("https://other.example.invalid/models");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "bearer + 跨源 modelsUrl 被拒绝（凭据只允许发往 chatUrl 的 origin）");
        CHECK(contains(err, "同源") && contains(err, "需要跨源请新建独立连接"),
              "拒绝原因说明必须同源并给出处理建议");
        CHECK(contains(err, "https://api.example.invalid") &&
              contains(err, "https://other.example.invalid"),
              "拒绝原因带出 A → B 两个 origin");

        /* authMode=none：允许跨源（运行时也绝不带凭据）。 */
        ts_free(bad.auth_mode);
        bad.auth_mode = ts_strdup(ts_auth_mode_none());
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) == 0,
              "authMode=none 允许跨源 modelsUrl");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        /* scheme 从 https 降到 http：同一个主机也算跨源。 */
        ts_free(bad.models_url);
        bad.models_url = ts_strdup("http://api.example.invalid/models");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "bearer + modelsUrl 从 https 降到 http 也视为跨源（不得无提示降级）");
        ts_profile_free(&bad);
    }
    {
        TsProfile bad;
        fill_profile(&bad, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        /* apiKeyEnv 非空同样算“配置了凭据来源”。 */
        ts_free(bad.auth_mode);
        bad.auth_mode = ts_strdup(ts_auth_mode_none());
        bad.api_key_env = ts_strdup("TS_TEST_SOME_ENV");
        ts_free(bad.models_url);
        bad.models_url = ts_strdup("https://other.example.invalid/models");
        err[0] = '\0';
        CHECK(ts_profile_validate(&bad, err, sizeof(err)) != 0,
              "apiKeyEnv 非空（环境变量凭据）同样要求 modelsUrl 同源");
        ts_profile_free(&bad);
    }
    {
        TsProfile ok;
        fill_profile(&ok, "ok-id", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        ts_free(ok.models_url);
        ok.models_url = ts_strdup("HTTPS://API.Example.Invalid:443/models");
        err[0] = '\0';
        CHECK(ts_profile_validate(&ok, err, sizeof(err)) == 0,
              "大小写不同 + 显式默认端口的同源 modelsUrl 允许（大小写不敏感/默认端口等价）");
        ts_profile_free(&ok);
    }

    ts_profile_free(&p);
    ts_profile_free(&back);

    /* 列表校验：默认值必须指向存在的连接 */
    {
        TsProfileList l;
        ts_profile_list_init(&l);
        l.default_profile_id = ts_strdup("nope");
        l.default_model_id = ts_strdup("m");
        err[0] = '\0';
        CHECK(ts_profile_list_validate(&l, err, sizeof(err)) != 0,
              "defaultProfileId 指向不存在的连接被拒绝");
        ts_profile_list_free(&l);
    }
}

/* ------------------------------------------------------------------ */
/* C. 请求体形状                                                        */
/* ------------------------------------------------------------------ */

static char *build_request(TsConfig *cfg)
{
    char *json = NULL;
    char err[256];
    err[0] = '\0';
    cfg->model = ts_strdup("m-1");
    if (ts_prompt_build_request(cfg, "sys", "user", &json, NULL, err, sizeof(err)) != 0) {
        printf("    构造请求失败：%s\n", err);
        return NULL;
    }
    return json;
}

static void test_prompt_shapes(void)
{
    printf("\n== C. 请求体形状（§5）==\n");

    /* C1. legacy(0)：0.0.3 行为不变 —— 只发 reasoning_effort */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.protocol = (int)TS_PROTOCOL_LEGACY;
        json = build_request(&cfg);
        CHECK(json != NULL && contains(json, "\"reasoning_effort\":\"none\""),
              "legacy：仍发送配置里的 reasoning_effort（0.0.3 行为）");
        CHECK(json != NULL && !contains(json, "\"thinking\""),
              "legacy：不发送 thinking 字段");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C2. deepseek-chat + enabled：thinking.type=enabled + effort */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.protocol = (int)TS_PROTOCOL_DEEPSEEK_CHAT;
        cfg.thinking = (int)TS_THINKING_ENABLED;
        ts_free(cfg.reasoning_effort);
        cfg.reasoning_effort = ts_strdup("high");
        cfg.thinking_effort = ts_strdup("high");
        json = build_request(&cfg);
        CHECK(json != NULL && contains(json, "\"thinking\":{\"type\":\"enabled\"}"),
              "deepseek-chat：顶层 thinking.type=enabled");
        CHECK(json != NULL && contains(json, "\"reasoning_effort\":\"high\""),
              "deepseek-chat：开启思考时发送 reasoning_effort=high");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C3. deepseek-chat + disabled：不得残留 effort */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.protocol = (int)TS_PROTOCOL_DEEPSEEK_CHAT;
        cfg.thinking = (int)TS_THINKING_DISABLED;
        json = build_request(&cfg);
        CHECK(json != NULL && contains(json, "\"thinking\":{\"type\":\"disabled\"}"),
              "deepseek-chat：关闭思考时 thinking.type=disabled");
        CHECK(json != NULL && !contains(json, "reasoning_effort"),
              "deepseek-chat：关闭思考时**不**发送 reasoning_effort（无残留）");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C4. openai-chat：thinking / effort 一律不发送（即使配置里残留） */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.protocol = (int)TS_PROTOCOL_OPENAI_CHAT;
        cfg.thinking = (int)TS_THINKING_ENABLED;
        ts_free(cfg.reasoning_effort);
        cfg.reasoning_effort = ts_strdup("high");
        cfg.thinking_effort = ts_strdup("high");
        json = build_request(&cfg);
        CHECK(json != NULL && !contains(json, "thinking"),
              "openai-chat：绝不发送 thinking");
        CHECK(json != NULL && !contains(json, "reasoning_effort"),
              "openai-chat：绝不发送 reasoning_effort");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C5. response_format 按 json_mode */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.protocol = (int)TS_PROTOCOL_DEEPSEEK_CHAT;
        cfg.thinking = (int)TS_THINKING_DISABLED;
        cfg.json_mode = 0;
        json = build_request(&cfg);
        CHECK(json != NULL && !contains(json, "response_format"),
              "json_mode=false：不发送 response_format");
        ts_free(json);
        ts_free(cfg.model);
        cfg.model = NULL;
        cfg.json_mode = 1;
        json = build_request(&cfg);
        CHECK(json != NULL && contains(json, "\"response_format\":{\"type\":\"json_object\"}"),
              "json_mode=true：发送 response_format=json_object");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C6. max_tokens 规则不变（0 = 省略） */
    {
        TsConfig cfg;
        char *json;
        ts_config_init(&cfg);
        cfg.max_output_tokens = 0;
        json = build_request(&cfg);
        CHECK(json != NULL && !contains(json, "max_tokens"),
              "max_output_tokens=0：不发送 max_tokens");
        ts_free(json);
        ts_free(cfg.model);
        cfg.model = NULL;
        cfg.max_output_tokens = 1234;
        json = build_request(&cfg);
        CHECK(json != NULL && contains(json, "\"max_tokens\":1234"),
              "max_output_tokens>0：发送 max_tokens");
        ts_free(json);
        ts_config_free(&cfg);
    }

    /* C7. profile → config 应用后 effort 与 reasoning_effort 同步 */
    {
        TsProfile p;
        TsConfig cfg;
        fill_profile(&p, "p-eff", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_ENABLED, "max");
        ts_config_init(&cfg);
        CHECK(ts_profile_apply_to_config(&p, &cfg) == 0, "profile 可应用到 TsConfig");
        CHECK(cfg.endpoint_url != NULL && strcmp(cfg.endpoint_url, p.chat_url) == 0,
              "应用后 endpoint_url = chatUrl（不自动拼 /v1）");
        CHECK(cfg.model != NULL && strcmp(cfg.model, p.model_id) == 0,
              "应用后 model = modelId");
        CHECK(cfg.protocol == (int)TS_PROTOCOL_DEEPSEEK_CHAT &&
              cfg.thinking == (int)TS_THINKING_ENABLED, "应用后协议/思考模式一致");
        CHECK(cfg.thinking_effort != NULL && cfg.reasoning_effort != NULL &&
              strcmp(cfg.thinking_effort, "max") == 0 &&
              strcmp(cfg.reasoning_effort, "max") == 0,
              "thinking_effort 与 reasoning_effort 保持同步（legacy 行为不变）");
        ts_config_free(&cfg);
        ts_profile_free(&p);

        fill_profile(&p, "p-off", TS_PROTOCOL_DEEPSEEK_CHAT, TS_THINKING_DISABLED, NULL);
        ts_config_init(&cfg);
        CHECK(ts_profile_apply_to_config(&p, &cfg) == 0, "关闭思考的 profile 可应用");
        CHECK(cfg.thinking_effort == NULL && cfg.reasoning_effort == NULL,
              "关闭思考时 effort 字段为空（不向请求体残留）");
        ts_config_free(&cfg);
        ts_profile_free(&p);
    }

    /* C8. URL 辅助 */
    {
        char host[256];
        char origin[512];
        char *models;
        CHECK(strcmp(ts_url_host("https://api.deepseek.com/v1/chat/completions",
                                 host, sizeof(host)), "api.deepseek.com") == 0,
              "ts_url_host 取主机");
        CHECK(strcmp(ts_url_origin("https://api.deepseek.com/v1/chat/completions",
                                   origin, sizeof(origin)),
                     "https://api.deepseek.com") == 0,
              "ts_url_origin 只保留 scheme://host");
        models = ts_url_derive_models("https://api.deepseek.com/chat/completions");
        CHECK(models != NULL && strcmp(models, "https://api.deepseek.com/models") == 0,
              "models_url 只在 /chat/completions 结尾时派生（不额外拼 /v1）");
        ts_free(models);
        models = ts_url_derive_models("https://api.example.invalid/custom/endpoint");
        CHECK(models == NULL, "非标准路径不猜 models URL");
        ts_free(models);
    }

    /* C9. 规范化 origin / 同源判定（凭据授权范围的基础） */
    {
        char o[512];
        CHECK(ts_url_same_origin("https://api.deepseek.com/v1/chat/completions",
                                 "https://api.deepseek.com/models") == 1,
              "同源：scheme+host 相同（路径不同不影响）");
        CHECK(ts_url_same_origin("https://API.DeepSeek.com/v1/chat",
                                 "https://api.deepseek.com:443/models") == 1,
              "同源：host 大小写不敏感 + 显式默认端口等价");
        CHECK(ts_url_same_origin("http://api.deepseek.com:80/x",
                                 "http://api.deepseek.com/y") == 1,
              "同源：http 默认端口 80 等价");
        CHECK(ts_url_same_origin("https://api.deepseek.com/chat",
                                 "http://api.deepseek.com/chat") == 0,
              "不同源：scheme 从 https 降到 http");
        CHECK(ts_url_same_origin("https://api.deepseek.com/chat",
                                 "https://api.deepseek.com:8443/chat") == 0,
              "不同源：端口不同");
        CHECK(ts_url_same_origin("https://api.deepseek.com/chat",
                                 "https://other.example.invalid/chat") == 0,
              "不同源：host 不同");
        CHECK(ts_url_same_origin("api.deepseek.com/chat",
                                 "https://api.deepseek.com/chat") == 0,
              "缺 scheme 无法证明同源 → 视为不同源");
        CHECK(strcmp(ts_url_normalized_origin("HTTPS://API.DeepSeek.com:443/v1/x",
                                              o, sizeof(o)),
                     "https://api.deepseek.com") == 0,
              "ts_url_normalized_origin 规范化 scheme/host 并省略默认端口");
        CHECK(strcmp(ts_url_normalized_origin("http://api.deepseek.com:8080/x",
                                              o, sizeof(o)),
                     "http://api.deepseek.com:8080") == 0,
              "ts_url_normalized_origin 保留非默认端口");
        CHECK(strcmp(ts_url_normalized_origin("user:pw@api.deepseek.com/x",
                                              o, sizeof(o)), "") == 0,
              "缺 scheme 的 URL 不参与同源判定（返回空串，绝不猜）");
        CHECK(strcmp(ts_url_normalized_origin("https://user:pw@api.deepseek.com/x",
                                              o, sizeof(o)),
                     "https://api.deepseek.com") == 0,
              "userinfo 被丢弃（凭证不参与 origin）");
        CHECK(strcmp(ts_url_normalized_origin("http://[::1]:8080/v1/chat", o, sizeof(o)),
                     "http://[::1]:8080") == 0,
              "IPv6 字面量按整体解析（方括号里的冒号不是端口分隔符）");
        CHECK(ts_url_same_origin("http://[::1]:8080/v1/chat",
                                 "http://[::1]:8080/models") == 1,
              "IPv6 同源判定正确");
    }
}

/* ------------------------------------------------------------------ */
/* D. settings.json 原子保存 / revision / 损坏处理                     */
/* ------------------------------------------------------------------ */

static int save_request(const char *json, TsProfileList *cur, TsProfileList *out,
                        char *err, size_t err_sz, const char **kind,
                        char *conflict, size_t conflict_sz)
{
    TsSettingsRequest req;
    int rc;
    ts_settings_request_init(&req);
    if (ts_settings_request_parse(json, strlen(json), &req, err, err_sz) != TS_SETTINGS_OK) {
        ts_settings_request_free(&req);
        return TS_SETTINGS_ERR;
    }
    rc = ts_settings_merge(cur, &req, out, conflict, conflict_sz, err, err_sz, kind);
    ts_settings_request_free(&req);
    return rc;
}

static void test_settings_store(void)
{
    char dir[1024];
    char path[1200];
    char bak[1200];
    char tmp[1200];
    char err[1024];
    const char *kind = "";
    TsProfileList list;
    TsProfileList loaded;
    int loaded_from_disk = 0;
    char warning[512];

    printf("\n== D. settings.json 保存 / 重载 / revision ==\n");

    snprintf(dir, sizeof(dir), "%s\\ts_settings_store", g_dir);
    CreateDirectoryA(dir, NULL);
    snprintf(path, sizeof(path), "%s\\settings.json", dir);
    snprintf(bak, sizeof(bak), "%s\\settings.json.bak", dir);
    snprintf(tmp, sizeof(tmp), "%s\\settings.json.tmp", dir);
    DeleteFileA(path);
    DeleteFileA(bak);
    DeleteFileA(tmp);

    ts_profile_list_init(&list);
    ts_profile_list_init(&loaded);

    /* D1. 新建（revision 传 0 → 保存后 1）并写盘 */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p1\",\"defaultModelId\":\"m-1\","
            "\"defaultThinking\":\"enabled\",\"defaultReasoningEffort\":\"high\","
            "\"profiles\":[{\"id\":\"p1\",\"name\":\"连接一\",\"revision\":0,"
            "\"protocol\":\"deepseek-chat\",\"baseUrl\":\"https://api.example.invalid\","
            "\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"modelsUrl\":\"https://api.example.invalid/models\","
            "\"authMode\":\"bearer\",\"apiKeyEnv\":\"\",\"modelId\":\"m-1\","
            "\"thinking\":\"enabled\",\"reasoningEffort\":\"high\",\"jsonMode\":true}]}";
        err[0] = '\0';
        ts_profile_list_init(&merged);
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_OK,
              "D1 新建设置合并成功");
        CHECK(merged.count == 1 && merged.items[0].revision == 1,
              "D1 新建 profile 的 revision 保存后为 1");
        err[0] = '\0';
        CHECK(ts_settings_write_atomic(dir, &merged, err, sizeof(err)) == TS_SETTINGS_OK,
              "D1 原子写盘成功");
        CHECK(file_exists(path), "D1 settings.json 已生成");
        CHECK(!file_exists(tmp), "D1 临时文件已被提升（不残留 .tmp）");
        ts_profile_list_free(&list);
        list = merged;
        ts_profile_list_init(&merged);
    }

    /* D2. 重载：内容与 revision 一致 */
    err[0] = '\0';
    warning[0] = '\0';
    CHECK(ts_settings_load(dir, &loaded, &loaded_from_disk,
                           warning, sizeof(warning), err, sizeof(err)) == TS_SETTINGS_OK,
          "D2 重新加载成功");
    CHECK(loaded_from_disk == 1, "D2 报告“来自磁盘”");
    CHECK(loaded.count == 1 && loaded.items[0].revision == 1, "D2 revision 保持为 1");
    CHECK(loaded.default_profile_id != NULL &&
          strcmp(loaded.default_profile_id, "p1") == 0, "D2 默认连接被保留");
    ts_profile_list_free(&loaded);
    ts_profile_list_init(&loaded);

    /* D3. 无变化：revision 不变 */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p1\",\"defaultModelId\":\"m-1\","
            "\"profiles\":[{\"id\":\"p1\",\"name\":\"连接一\",\"revision\":1,"
            "\"protocol\":\"deepseek-chat\",\"baseUrl\":\"https://api.example.invalid\","
            "\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"modelsUrl\":\"https://api.example.invalid/models\","
            "\"authMode\":\"bearer\",\"modelId\":\"m-1\",\"thinking\":\"enabled\","
            "\"reasoningEffort\":\"high\",\"jsonMode\":true}]}";
        ts_profile_list_init(&merged);
        err[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_OK, "D3 相同内容保存成功");
        CHECK(merged.count == 1 && merged.items[0].revision == 1,
              "D3 字段无变化时 revision 保持不变");
        ts_profile_list_free(&merged);
    }

    /* D4. 字段变化：revision +1，并产生 .bak */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p1\",\"defaultModelId\":\"m-2\","
            "\"profiles\":[{\"id\":\"p1\",\"name\":\"连接一（改）\",\"revision\":1,"
            "\"protocol\":\"deepseek-chat\",\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"authMode\":\"bearer\",\"modelId\":\"m-2\",\"thinking\":\"enabled\","
            "\"reasoningEffort\":\"max\",\"jsonMode\":true}]}";
        ts_profile_list_init(&merged);
        err[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_OK, "D4 修改内容合并成功");
        CHECK(merged.items[0].revision == 2, "D4 字段实际变化时 revision +1");
        err[0] = '\0';
        CHECK(ts_settings_write_atomic(dir, &merged, err, sizeof(err)) == TS_SETTINGS_OK,
              "D4 第二次写盘成功");
        CHECK(file_exists(bak), "D4 旧文件被保留为 .bak");
        ts_profile_list_free(&list);
        list = merged;
        ts_profile_list_init(&merged);
    }

    /* D5. 过期 revision → conflict，且不写盘 */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p1\",\"defaultModelId\":\"m-2\","
            "\"profiles\":[{\"id\":\"p1\",\"name\":\"并发修改\",\"revision\":1,"
            "\"protocol\":\"deepseek-chat\",\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"authMode\":\"bearer\",\"modelId\":\"m-2\",\"thinking\":\"disabled\","
            "\"jsonMode\":true}]}";
        char conflict[128];
        char *before;
        char *after;
        ts_profile_list_init(&merged);
        err[0] = '\0';
        conflict[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           conflict, sizeof(conflict)) == TS_SETTINGS_CONFLICT,
              "D5 revision 过期被拒绝（conflict）");
        CHECK(strcmp(conflict, "p1") == 0, "D5 冲突的 profile id 被回带");
        CHECK(kind != NULL && strcmp(kind, "conflict") == 0, "D5 错误分类为 conflict");
        before = read_file(path);
        after = read_file(path);
        CHECK(before != NULL && after != NULL && strcmp(before, after) == 0,
              "D5 冲突时磁盘文件未被修改");
        free(before);
        free(after);
        ts_profile_list_free(&merged);
    }

    /* D6. 缺失 revision → 明确失败（不是静默用最新配置） */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p1\",\"defaultModelId\":\"m-2\","
            "\"profiles\":[{\"id\":\"p1\",\"name\":\"连接一\","
            "\"protocol\":\"deepseek-chat\",\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"authMode\":\"bearer\",\"modelId\":\"m-2\",\"thinking\":\"disabled\","
            "\"jsonMode\":true}]}";
        ts_profile_list_init(&merged);
        err[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_ERR,
              "D6 缺失 revision 明确失败");
        CHECK(kind != NULL && strcmp(kind, "invalidRevision") == 0,
              "D6 错误分类为 invalidRevision");
        ts_profile_list_free(&merged);
    }

    /* D7. 对磁盘上不存在的 id 带非 0 revision → invalidRevision */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p2\",\"defaultModelId\":\"m-3\","
            "\"profiles\":[{\"id\":\"p2\",\"name\":\"新连接\",\"revision\":5,"
            "\"protocol\":\"openai-chat\",\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"authMode\":\"none\",\"modelId\":\"m-3\",\"thinking\":\"unsupported\","
            "\"jsonMode\":false}]}";
        ts_profile_list_init(&merged);
        err[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_ERR,
              "D7 新建却带非 0 revision 被拒绝");
        ts_profile_list_free(&merged);
    }

    /* D8. 新增 + 删除 一起提交 */
    {
        TsProfileList merged;
        const char *json =
            "{\"schemaVersion\":2,\"defaultProfileId\":\"p2\",\"defaultModelId\":\"m-3\","
            "\"deletedProfileIds\":[\"p1\"],"
            "\"profiles\":[{\"id\":\"p2\",\"name\":\"新连接\",\"revision\":0,"
            "\"protocol\":\"openai-chat\",\"chatUrl\":\"https://api.example.invalid/chat/completions\","
            "\"authMode\":\"none\",\"modelId\":\"m-3\",\"thinking\":\"unsupported\","
            "\"jsonMode\":false}]}";
        ts_profile_list_init(&merged);
        err[0] = '\0';
        CHECK(save_request(json, &list, &merged, err, sizeof(err), &kind,
                           NULL, 0) == TS_SETTINGS_OK, "D8 删除+新增合并成功");
        CHECK(merged.count == 1 && strcmp(merged.items[0].id, "p2") == 0,
              "D8 被删除的 profile 不再存在");
        CHECK(merged.items[0].revision == 1, "D8 新 profile 的 revision 为 1");
        ts_profile_list_free(&merged);
    }

    /* D9. settings.json 里绝不含密钥 */
    {
        char *text = read_file(path);
        CHECK(text != NULL && !contains(text, "sk-"), "D9 settings.json 不含任何 sk- 形式的密钥");
        CHECK(text != NULL && !contains(text, "api_key"), "D9 settings.json 没有 api_key 字段");
        free(text);
    }

    /* D10. 损坏文件：保留原文件、返回空列表 + warning */
    {
        char *orig;
        char *after;
        write_file(path, "{ this is not json ");
        orig = read_file(path);
        err[0] = '\0';
        warning[0] = '\0';
        loaded_from_disk = 0;
        CHECK(ts_settings_load(dir, &loaded, &loaded_from_disk,
                               warning, sizeof(warning), err, sizeof(err)) == TS_SETTINGS_OK,
              "D10 损坏文件不会让加载“失败”，而是用默认空列表");
        CHECK(loaded.count == 0, "D10 损坏时返回内置默认空列表");
        CHECK(warning[0] != '\0', "D10 返回可读 warning");
        after = read_file(path);
        CHECK(orig != NULL && after != NULL && strcmp(orig, after) == 0,
              "D10 损坏的原文件保持不动（未被覆盖）");
        free(orig);
        free(after);
        ts_profile_list_free(&loaded);
        ts_profile_list_init(&loaded);
    }

    /* D11. 版本不兼容：保留原文件 */
    {
        char *orig;
        char *after;
        write_file(path,
                   "{\"schemaVersion\":99,\"profiles\":[],\"defaultProfileId\":\"\"}");
        orig = read_file(path);
        warning[0] = '\0';
        CHECK(ts_settings_load(dir, &loaded, &loaded_from_disk,
                               warning, sizeof(warning), err, sizeof(err)) == TS_SETTINGS_OK,
              "D11 版本不兼容时仍可启动");
        CHECK(loaded.count == 0 && warning[0] != '\0',
              "D11 版本不兼容：空列表 + warning");
        after = read_file(path);
        CHECK(orig != NULL && after != NULL && strcmp(orig, after) == 0,
              "D11 版本不兼容的原文件未被覆盖");
        free(orig);
        free(after);
        ts_profile_list_free(&loaded);
        ts_profile_list_init(&loaded);
    }

    ts_profile_list_free(&list);
    ts_profile_list_free(&loaded);
    DeleteFileA(path);
    DeleteFileA(bak);
    DeleteFileA(tmp);
    RemoveDirectoryA(dir);
}

/* ------------------------------------------------------------------ */
/* E. 旧 config.json 迁移                                              */
/* ------------------------------------------------------------------ */

static void test_migration(void)
{
    char dir[1024];
    char cfg_path[1200];
    char *before;
    char *after;
    TsConfig cfg;
    TsProfileList list;
    char err[1024];
    char *key = NULL;
    char *host = NULL;

    printf("\n== E. 旧 config.json 迁移 ==\n");

    snprintf(dir, sizeof(dir), "%s\\ts_settings_migrate", g_dir);
    CreateDirectoryA(dir, NULL);
    snprintf(cfg_path, sizeof(cfg_path), "%s\\config.json", dir);

    write_file(cfg_path,
               "{\n"
               "  \"endpoint_url\": \"https://api.example.invalid/chat/completions\",\n"
               "  \"model\": \"legacy-model\",\n"
               "  \"api_key\": \"sk-test-migrate-0123456789\",\n"
               "  \"api_key_env\": \"TS_TEST_ABSENT_ENV_FOR_MIGRATION\",\n"
               "  \"connect_timeout_ms\": 5000,\n"
               "  \"wait_prompt_ms\": 120000,\n"
               "  \"request_timeout_ms\": 0,\n"
               "  \"json_mode\": true,\n"
               "  \"reasoning_effort\": \"high\"\n"
               "}\n");
    before = read_file(cfg_path);
    CHECK(before != NULL, "E 写入旧 config.json");

    err[0] = '\0';
    CHECK(ts_config_load(cfg_path, &cfg, err, sizeof(err)) == 0, "E 旧配置可加载");
    CHECK(cfg.api_key != NULL, "E 旧配置里读到内联密钥（虚构值）");

    ts_profile_list_init(&list);
    err[0] = '\0';
    CHECK(ts_settings_migrate_legacy(&list, &cfg, err, sizeof(err)) == TS_SETTINGS_OK,
          "E 迁移成功");
    CHECK(list.count == 1 && strcmp(list.items[0].id, TS_LEGACY_PROFILE_ID) == 0,
          "E 生成 1 个 legacy profile");
    CHECK(list.migration_legacy == 1, "E 标记本次运行发生过迁移");
    CHECK(list.migration_note != NULL && list.migration_note[0] != '\0',
          "E 写入 migration_note");
    CHECK(list.default_profile_id != NULL &&
          strcmp(list.default_profile_id, TS_LEGACY_PROFILE_ID) == 0,
          "E 迁移后默认连接指向它");
    CHECK(list.items[0].protocol == TS_PROTOCOL_OPENAI_CHAT,
          "E 迁移出的 profile 使用 1/2 协议（不是 legacy=0）");
    CHECK(list.items[0].chat_url != NULL &&
          strcmp(list.items[0].chat_url, "https://api.example.invalid/chat/completions") == 0,
          "E 迁移后 chatUrl 就是旧 endpoint_url（不自动拼 /v1）");
    CHECK(list.items[0].credential_configured == 1,
          "E 内联密钥已一次性导入凭据管理器");
    CHECK(!contains(list.migration_note, "sk-test-migrate"),
          "E migration_note 不含密钥内容");

    /* 凭据里确实能读到，且绑定到旧 endpoint 的主机 */
    err[0] = '\0';
    CHECK(ts_credential_load(TS_LEGACY_PROFILE_ID, &key, &host, err, sizeof(err)) == 0,
          "E 凭据管理器里能读到迁移的密钥");
    CHECK(key != NULL && strcmp(key, "sk-test-migrate-0123456789") == 0,
          "E 迁移的密钥内容正确");
    CHECK(host != NULL && strcmp(host, "api.example.invalid") == 0,
          "E 凭据绑定到旧端点主机");
    ts_secure_free(&key);
    ts_free(host);

    /* 旧 config.json 不删除、不修改 */
    CHECK(file_exists(cfg_path), "E 旧 config.json 仍然存在（不删除）");
    after = read_file(cfg_path);
    CHECK(before != NULL && after != NULL && strcmp(before, after) == 0,
          "E 旧 config.json 内容未被修改");
    free(before);
    free(after);

    /* 写出的 settings.json 不含密钥 */
    {
        char settings_path[1200];
        char *text;
        snprintf(settings_path, sizeof(settings_path), "%s\\settings.json", dir);
        err[0] = '\0';
        CHECK(ts_settings_write_atomic(dir, &list, err, sizeof(err)) == TS_SETTINGS_OK,
              "E 迁移结果可原子写盘");
        text = read_file(settings_path);
        CHECK(text != NULL && !contains(text, "sk-test-migrate"),
              "E settings.json 不含迁移进来的密钥");
        free(text);
        DeleteFileA(settings_path);
        {
            char bak[1200];
            snprintf(bak, sizeof(bak), "%s\\settings.json.bak", dir);
            DeleteFileA(bak);
        }
        {
            char tmp[1200];
            snprintf(tmp, sizeof(tmp), "%s\\settings.json.tmp", dir);
            DeleteFileA(tmp);
        }
    }

    ts_profile_list_free(&list);
    ts_config_free(&cfg);
    (void)ts_credential_delete(TS_LEGACY_PROFILE_ID, err, sizeof(err));
    DeleteFileA(cfg_path);
    RemoveDirectoryA(dir);
}

/* ------------------------------------------------------------------ */
/* F. 凭据往返                                                         */
/* ------------------------------------------------------------------ */

static void test_credentials(void)
{
    char err[512];
    char *key = NULL;
    char *host = NULL;
    const char *id = "ts-test-cred-roundtrip";

    printf("\n== F. Windows 凭据 set / load / delete ==\n");

    err[0] = '\0';
    (void)ts_credential_delete(id, err, sizeof(err));

    err[0] = '\0';
    CHECK(ts_credential_set(id, "api.example.invalid", "sk-test-cred-abcdef", 20,
                            err, sizeof(err)) == 0, "F 写入凭据成功");
    CHECK(ts_credential_exists(id) == 1, "F 凭据存在");

    err[0] = '\0';
    CHECK(ts_credential_load(id, &key, &host, err, sizeof(err)) == 0, "F 读取凭据成功");
    CHECK(key != NULL && strcmp(key, "sk-test-cred-abcdef") == 0, "F 密钥内容往返一致");
    CHECK(host != NULL && strcmp(host, "api.example.invalid") == 0, "F 主机往返一致");
    ts_secure_free(&key);
    ts_free(host);

    /* 覆盖写：同一 profile 只保留一份 */
    err[0] = '\0';
    CHECK(ts_credential_set(id, "api2.example.invalid", "sk-test-cred-replaced", 21,
                            err, sizeof(err)) == 0, "F 覆盖写成功");
    err[0] = '\0';
    CHECK(ts_credential_load(id, &key, &host, err, sizeof(err)) == 0, "F 覆盖后可读");
    CHECK(key != NULL && strcmp(key, "sk-test-cred-replaced") == 0, "F 覆盖后的值正确");
    CHECK(host != NULL && strcmp(host, "api2.example.invalid") == 0,
          "F 覆盖后的主机正确");
    ts_secure_free(&key);
    ts_free(host);

    CHECK(ts_credential_delete(id, err, sizeof(err)) == 0, "F 删除凭据成功");
    CHECK(ts_credential_exists(id) == 0, "F 删除后不存在");
    CHECK(ts_credential_delete(id, err, sizeof(err)) == 0, "F 重复删除幂等（成功）");
    CHECK(ts_credential_load(id, &key, &host, err, sizeof(err)) != 0,
          "F 删除后读取明确失败");
    ts_secure_free(&key);
    ts_free(host);

    /* 错误信息不泄露密钥 */
    err[0] = '\0';
    (void)ts_credential_set(id, "h", "sk-test-leak-check-value", 24, err, sizeof(err));
    (void)ts_credential_delete(id, err, sizeof(err));
    CHECK(!contains(err, "sk-test-leak-check-value"), "F 错误信息不含密钥内容");
}

/* ------------------------------------------------------------------ */
/* G. 凭据数据空间隔离（scoped target）                                */
/* ------------------------------------------------------------------ */

static int is_lower_hex16(const char *s)
{
    size_t i;
    if (s == NULL || strlen(s) != 16) return 0;
    for (i = 0; i < 16; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

/*
 * 覆盖 0.0.4 验收修复 2：
 *   - space id 由数据目录绝对路径规范化后哈希（16 位小写十六进制，稳定）；
 *   - 同一 profileId 在不同 space 里互不覆盖、互不可见；
 *   - 旧目标（无 space）仍可被新 space 首次 load 迁移读取，且**不删除**旧目标；
 *   - 删除时新旧两个目标都删。
 * 测试结束删除自己写的凭据（全部是 sk-test-… 假值）。
 */
static void test_credential_spaces(void)
{
    char dir_a[1024];
    char dir_b[1024];
    char variant[1024];
    char space_a[TS_CREDENTIAL_SPACE_MAX];
    char space_b[TS_CREDENTIAL_SPACE_MAX];
    char vspace[TS_CREDENTIAL_SPACE_MAX];
    char err[512];
    char *key = NULL;
    char *host = NULL;
    int migrated = 0;
    const char *id = "ts-test-space";
    const char *id_legacy = "ts-test-space-legacy";

    printf("\n== G. 凭据数据空间隔离 ==\n");

    snprintf(dir_a, sizeof(dir_a), "%s\\ts_settings_space_a", g_dir);
    snprintf(dir_b, sizeof(dir_b), "%s\\ts_settings_space_b", g_dir);
    CreateDirectoryA(dir_a, NULL);
    CreateDirectoryA(dir_b, NULL);

    ts_credential_space_id(dir_a, space_a, sizeof(space_a));
    ts_credential_space_id(dir_b, space_b, sizeof(space_b));
    CHECK(is_lower_hex16(space_a) && is_lower_hex16(space_b),
          "G space id 是 16 位小写十六进制");
    CHECK(strcmp(space_a, space_b) != 0, "G 不同数据目录得到不同 space id");

    /* 同一个目录的不同写法必须得到同一个 space（大小写不敏感 + 分隔符统一）。 */
    snprintf(variant, sizeof(variant), "%s\\TS_SETTINGS_SPACE_A\\", g_dir);
    ts_credential_space_id(variant, vspace, sizeof(vspace));
    CHECK(strcmp(vspace, space_a) == 0,
          "G 大小写/结尾分隔符不影响 space id（路径已规范化）");

    /* 先清掉本测试可能残留的条目（旧目标 + 两个新目标）。 */
    err[0] = '\0';
    (void)ts_credential_delete(id, err, sizeof(err));
    (void)ts_credential_delete(id_legacy, err, sizeof(err));
    (void)ts_credential_delete_scoped(space_a, id, err, sizeof(err));
    (void)ts_credential_delete_scoped(space_b, id, err, sizeof(err));

    /* 同名 profileId，两个 space 各写一把不同的假密钥。 */
    err[0] = '\0';
    CHECK(ts_credential_set_scoped(space_a, id, "a.example.invalid",
                                   "sk-test-space-a-0001",
                                   strlen("sk-test-space-a-0001"),
                                   err, sizeof(err)) == 0,
          "G space A 写入成功");
    err[0] = '\0';
    CHECK(ts_credential_set_scoped(space_b, id, "b.example.invalid",
                                   "sk-test-space-b-0002",
                                   strlen("sk-test-space-b-0002"),
                                   err, sizeof(err)) == 0,
          "G space B 写入同名 profile 的另一把密钥成功");
    CHECK(ts_credential_exists_scoped(space_a, id) == 1, "G space A 报告已配置");
    CHECK(ts_credential_exists_scoped(space_b, id) == 1, "G space B 报告已配置");

    err[0] = '\0';
    CHECK(ts_credential_load_scoped(space_a, id, &key, &host, NULL,
                                    err, sizeof(err)) == 0,
          "G space A 可读");
    CHECK(key != NULL && strcmp(key, "sk-test-space-a-0001") == 0,
          "G space A 读到自己的密钥（没有被 B 覆盖）");
    CHECK(host != NULL && strcmp(host, "a.example.invalid") == 0,
          "G space A 的主机正确");
    ts_secure_free(&key);
    ts_free(host);

    err[0] = '\0';
    CHECK(ts_credential_load_scoped(space_b, id, &key, &host, NULL,
                                    err, sizeof(err)) == 0,
          "G space B 可读");
    CHECK(key != NULL && strcmp(key, "sk-test-space-b-0002") == 0,
          "G space B 读到的是自己的密钥（互不可见）");
    CHECK(host != NULL && strcmp(host, "b.example.invalid") == 0, "G space B 的主机正确");
    ts_secure_free(&key);
    ts_free(host);

    /* 删掉 A 不影响 B。 */
    err[0] = '\0';
    CHECK(ts_credential_delete_scoped(space_a, id, err, sizeof(err)) == 0,
          "G 删除 space A 的凭据成功");
    CHECK(ts_credential_exists_scoped(space_a, id) == 0, "G space A 已无凭据");
    CHECK(ts_credential_exists_scoped(space_b, id) == 1,
          "G 删除 space A 不影响 space B");

    /* 旧目标兼容：旧目标写入后，新 space 首次 load 能迁移读取且不删旧目标。 */
    err[0] = '\0';
    CHECK(ts_credential_set(id_legacy, "legacy.example.invalid",
                            "sk-test-space-legacy-0003",
                            strlen("sk-test-space-legacy-0003"),
                            err, sizeof(err)) == 0,
          "G 旧目标写入成功（模拟上一版本留下的凭据）");
    err[0] = '\0';
    CHECK(ts_credential_load_scoped(space_b, id_legacy, &key, &host, &migrated,
                                    err, sizeof(err)) == 0,
          "G 新 space 首次 load 可从旧目标读取（兼容）");
    CHECK(migrated == 1, "G 报告本次是从旧目标迁移读取");
    CHECK(key != NULL && strcmp(key, "sk-test-space-legacy-0003") == 0,
          "G 迁移读取到的密钥正确");
    ts_secure_free(&key);
    ts_free(host);

    CHECK(ts_credential_exists(id_legacy) == 1, "G 迁移后旧目标未被删除");

    /* 单独删掉旧目标后，新目标仍可读 → 说明是“复制”而不是“移动”。 */
    err[0] = '\0';
    CHECK(ts_credential_delete(id_legacy, err, sizeof(err)) == 0,
          "G 单独删除旧目标成功");
    err[0] = '\0';
    CHECK(ts_credential_load_scoped(space_b, id_legacy, &key, &host, NULL,
                                    err, sizeof(err)) == 0,
          "G 旧目标删掉后新目标仍可读（已复制到新目标）");
    ts_secure_free(&key);
    ts_free(host);

    /* scoped 删除把新旧两个目标都删掉。 */
    err[0] = '\0';
    CHECK(ts_credential_delete_scoped(space_b, id_legacy, err, sizeof(err)) == 0,
          "G scoped 删除成功");
    CHECK(!ts_credential_exists_scoped(space_b, id_legacy), "G 新目标已删除");
    CHECK(!ts_credential_exists(id_legacy), "G 旧目标也一并删除");

    /* 收尾：再确保一遍没有任何测试条目残留。 */
    err[0] = '\0';
    (void)ts_credential_delete(id, err, sizeof(err));
    (void)ts_credential_delete(id_legacy, err, sizeof(err));
    (void)ts_credential_delete_scoped(space_a, id, err, sizeof(err));
    (void)ts_credential_delete_scoped(space_b, id, err, sizeof(err));
    RemoveDirectoryA(dir_a);
    RemoveDirectoryA(dir_b);
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler 设置（离线）测试 ===\n\n");
    if (argc >= 2) {
        g_dir = argv[1];
    }

    test_config_copy();
    test_profile_json_and_validate();
    test_prompt_shapes();
    test_settings_store();
    test_migration();
    test_credentials();
    test_credential_spaces();

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

