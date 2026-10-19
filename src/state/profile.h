#ifndef TS_PROFILE_H
#define TS_PROFILE_H

/*
 * profile.h — 供应商 profile（模型连接配置）的结构、枚举解析、JSON 编解码、校验与 TsConfig 互转。
 *
 * 主要函数：ts_profile_init / free / copy / validate / from_json、ts_profile_list_*、
 * ts_protocol_parse、ts_thinking_parse、ts_url_same_origin、ts_profile_apply_to_config。
 */
#include <stddef.h>

#include "cJSON.h"
#include "config.h"   /* TsConfig：profile ↔ config 互转需要完整类型 */

#ifdef __cplusplus
extern "C" {
#endif

/* 协议：模型请求体形状。0 = 0.0.3 旧行为（旧测试依赖）。 */
typedef enum TsProtocol {
    TS_PROTOCOL_LEGACY = 0,
    TS_PROTOCOL_DEEPSEEK_CHAT = 1,
    TS_PROTOCOL_OPENAI_CHAT = 2
} TsProtocol;

/* 思考模式：unsupported = 该协议不支持，disabled = 支持但关闭，enabled = 开启。 */
typedef enum TsThinking {
    TS_THINKING_UNSUPPORTED = 0,
    TS_THINKING_DISABLED = 1,
    TS_THINKING_ENABLED = 2
} TsThinking;

/* profile id 的合法字符集：1..64 个 [A-Za-z0-9_-]。 */
#define TS_PROFILE_ID_MAX 64
#define TS_PROFILE_NAME_MAX 128
#define TS_PROFILE_URL_MAX 2048
#define TS_PROFILE_MODEL_MAX 256
#define TS_PROFILE_HOST_MAX 256

typedef struct TsProfile {
    char *id;            /* 稳定不变，非空，[A-Za-z0-9_-]{1,64} */
    char *name;
    long revision;       /* >= 1；新建时为 1 */
    TsProtocol protocol;
    char *base_url;      /* 只用于展示/派生，不自动拼路径 */
    char *chat_url;      /* 完整 Chat Completions URL（请求实际使用） */
    char *models_url;    /* 完整列表 URL；可空 */
    char *auth_mode;     /* "bearer" | "none" */
    char *api_key_env;   /* 兼容旧配置：环境变量名，可空 */
    char *model_id;
    TsThinking thinking;
    char *reasoning_effort; /* enabled 时 low/high/max；否则 NULL */
    int json_mode;
    char *credential_host;  /* 凭据保存时的主机；空表示无凭据 */
    int credential_configured;
} TsProfile;

typedef struct TsProfileList {
    TsProfile *items;
    size_t count;
    char *default_profile_id;
    char *default_model_id;
    TsThinking default_thinking;
    char *default_reasoning_effort;
    int schema_version;   /* 2 */
    int migration_legacy; /* 本次运行从旧 config.json 迁移出 profile */
    char *migration_note;
} TsProfileList;

/* 当前 settings.json 的 schema 版本。 */
#define TS_SETTINGS_SCHEMA_VERSION 2

/* 默认探针总超时（毫秒），见规格 §6。 */
#define TS_PROBE_TIMEOUT_DEFAULT_MS 30000
#define TS_PROBE_TIMEOUT_MIN_MS     3000
#define TS_PROBE_TIMEOUT_MAX_MS     120000
#define TS_PROBE_CONNECT_MAX_MS     10000

/* ---------------- 枚举 <-> 字符串 ---------------- */

const char *ts_protocol_name(TsProtocol p);          /* "legacy"/"deepseek-chat"/"openai-chat" */
int ts_protocol_parse(const char *s, TsProtocol *out); /* 成功 0；未知 1（不修改 *out） */

const char *ts_thinking_name(TsThinking t);          /* "unsupported"/"disabled"/"enabled" */
int ts_thinking_parse(const char *s, TsThinking *out);

const char *ts_auth_mode_bearer(void);               /* "bearer" */
const char *ts_auth_mode_none(void);                 /* "none" */

/* ---------------- 生命周期 ---------------- */

void ts_profile_init(TsProfile *p);
void ts_profile_free(TsProfile *p);
/* 深拷贝。成功 0；失败非 0，且 dst 已初始化（可直接 free）。 */
int ts_profile_copy(TsProfile *dst, const TsProfile *src);

void ts_profile_list_init(TsProfileList *l);
void ts_profile_list_free(TsProfileList *l);
/* 深拷贝（整体替换 dst）。失败非 0 时 dst 已初始化并清空。 */
int ts_profile_list_copy(TsProfileList *dst, const TsProfileList *src);

/* 查找（只读）。找不到返回 NULL。 */
const TsProfile *ts_profile_list_find(const TsProfileList *l, const char *id);
/* 查找（可写）。找不到返回 NULL。 */
TsProfile *ts_profile_list_find_mut(TsProfileList *l, const char *id);

/* 追加一个深拷贝；成功 0。 */
int ts_profile_list_append(TsProfileList *l, const TsProfile *p);
/* 按 id 删除；返回 1 表示删除成功，0 表示不存在，-1 表示内部错误。 */
int ts_profile_list_remove(TsProfileList *l, const char *id);

/* ---------------- 校验 ---------------- */

/*
 * 校验单个 profile。成功 0；失败非 0 并把可读原因写 err。
 * 规则（规格 §2/§3）：
 *   - id 非空且只含 [A-Za-z0-9_-]，长度 1..64；
 *   - name 非空；
 *   - revision >= 1；
 *   - chat_url 必须是 http:// 或 https:// 开头的完整 URL（不接受只写主机名）；
 *   - models_url 可空，非空时同样必须是 http(s) 完整 URL；
 *   - **配置了凭据来源时（authMode=bearer 或 apiKeyEnv 非空），
 *     models_url 必须与 chat_url 同源**（scheme + host + 有效端口）：
 *     凭据只允许发往 chatUrl 的 origin，跨源的模型列表地址会拿到对话密钥，
 *     必须拒绝并提示“需要跨源请新建独立连接”。
 *     authMode=none 允许跨源（运行时也绝不带凭据）；
 *   - auth_mode 只能是 bearer / none；
 *   - model_id 非空；
 *   - thinking = enabled 时 reasoning_effort 必须是 low/high/max；
 *   - thinking != enabled 时 reasoning_effort 必须为空（不允许残留 effort）；
 *   - openai-chat 协议不允许 thinking=enabled（能力未知不假装已验证）。
 */
int ts_profile_validate(const TsProfile *p, char *err, size_t err_sz);

/*
 * 校验整份列表：
 *   - 每个 profile 单独合法；
 *   - id 不重复；
 *   - 列表非空时 default_profile_id 必须指向存在的 profile，default_model_id 非空；
 *     列表为空时这两个默认值必须为空（避免指向已删除的 profile）。
 */
int ts_profile_list_validate(const TsProfileList *l, char *err, size_t err_sz);

/* ---------------- JSON ---------------- */

/*
 * 解析单个 profile 对象（cJSON object）。成功 0。
 * 字段名对齐规格 §3 的 settings.json 写法（驼峰）。
 * 不接受也不解析任何密钥字段（出现也忽略）。
 */
int ts_profile_from_json(const cJSON *obj, TsProfile *out, char *err, size_t err_sz);

/* 序列化单个 profile 为 cJSON object（调用方负责挂到父节点或删除）。 */
cJSON *ts_profile_to_json(const TsProfile *p);

/* 解析整份 settings 对象。未知 schemaVersion 视为不兼容（返回非 0）。 */
int ts_profile_list_from_json(const cJSON *root, TsProfileList *out,
                              char *err, size_t err_sz);

/* 解析 settings JSON 文本（UTF-8）。 */
int ts_profile_list_parse(const char *json, size_t len, TsProfileList *out,
                          char *err, size_t err_sz);

/* 序列化整份 settings（不含 abiVersion / settingsPath 这类桥接元信息）。 */
cJSON *ts_profile_list_to_json(const TsProfileList *l);

/* 序列化并打印为紧凑 JSON 字符串（owned，调用方 ts_free）。失败返回 NULL。 */
char *ts_profile_list_print(const TsProfileList *l);

/* ---------------- URL 辅助 ---------------- */

/*
 * 取 URL 的主机（小写，不含端口与 userinfo）。out 始终以 NUL 结尾。
 * 解析失败返回 ""（绝不返回 NULL）。
 */
const char *ts_url_host(const char *url, char *out, size_t out_sz);

/*
 * 取 URL 的 scheme://host[:port]（用于 profile.base_url 的展示/派生派生）。
 * 绝不补 /v1 之类的路径。
 */
const char *ts_url_origin(const char *url, char *out, size_t out_sz);

/*
 * 取 URL 的**规范化 origin**：scheme://host[:有效端口]。
 *   - scheme / host 统一小写（大小写不敏感）；
 *   - 默认端口省略：http:80 / https:443，因此
 *     "https://A.Example:443/x" 与 "https://a.example" 被视为同一个 origin；
 *   - userinfo（user:pass@）被丢弃：凭证绝不参与 origin 判定；
 *   - 非 http(s) 或无法解析时返回 ""（绝不猜）。
 * 用于“凭据只允许发往同源地址”的判定。
 */
const char *ts_url_normalized_origin(const char *url, char *out, size_t out_sz);

/*
 * 两个 URL 是否**同源**（scheme + host + 有效端口；大小写不敏感、默认端口等价）。
 * 任一无法解析为 http(s) URL 时返回 0 —— **无法证明同源即视为不同源**。
 * 注意：scheme 从 https 降到 http 属于不同源（不允许无提示降级）。
 */
int ts_url_same_origin(const char *a, const char *b);

/*
 * 由 chat_url 派生 models_url：仅当路径以 "/chat/completions" 结尾时，
 * 把这一段换成 "/models"；否则返回 NULL（不猜测）。
 * 返回 owned 字符串（调用方 ts_free）。
 */
char *ts_url_derive_models(const char *chat_url);

/* ---------------- 与 TsConfig 的互转 ---------------- */

/*
 * 把 profile 应用到一个**已经初始化/拷贝好的** TsConfig 上：
 *   - endpoint_url = chat_url；model = model_id；
 *   - profile_id / profile_revision / protocol / thinking / thinking_effort /
 *     models_url / auth_mode / credential_host / api_key_env / json_mode；
 *   - reasoning_effort 与 thinking_effort 保持同步（thinking!=enabled 时为 NULL），
 *     这样 legacy 协议（0）的既有请求构造行为完全不变。
 * 不触碰 api_key（由调用方按凭据解析结果写入）。
 * 成功 0；失败非 0（内存不足）。
 */
int ts_profile_apply_to_config(const TsProfile *p, TsConfig *cfg);

/*
 * 从旧 config.json 的内容构造一个 legacy profile（迁移用）。
 * 迁移出来的 profile 使用 deepseek-chat / openai-chat 协议（规格 §5），
 * 不再使用 legacy(0)。
 * 成功 0；失败非 0 并把原因写 err。
 */
int ts_profile_from_legacy_config(const TsConfig *cfg, const char *profile_id,
                                  TsProfile *out, char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_PROFILE_H */

