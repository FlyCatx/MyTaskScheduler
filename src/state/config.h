#ifndef TS_CONFIG_H
#define TS_CONFIG_H

/*
 * config.h — 运行时配置：类型、默认值、JSON 载入、校验、深拷贝与鉴权判定。
 *
 * 主要函数：ts_config_init / free / copy / move / load / validate、
 * ts_config_requires_auth、ts_config_api_key_source。
 */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 默认值（单位：毫秒 / 字节 / 小时）。 */
#define TS_DEFAULT_CONNECT_TIMEOUT_MS   15000
#define TS_DEFAULT_WAIT_PROMPT_MS       120000
#define TS_DEFAULT_REQUEST_TIMEOUT_MS   0        /* 0 = 云端默认禁用总超时 */
#define TS_DEFAULT_MAX_OUTPUT_TOKENS    0        /* 0 = 不发送 max_tokens，由服务端按模式取默认 */
#define TS_DEFAULT_MAX_INPUT_BYTES      (256 * 1024)
#define TS_DEFAULT_MAX_RESPONSE_BYTES   (2 * 1024 * 1024)
#define TS_DEFAULT_TEMPERATURE          0.2
#define TS_DEFAULT_REFERENCE_HOURS      2.0
#define TS_DEFAULT_MAX_TASKS            200
#define TS_DEFAULT_MAX_STEPS_PER_TASK   50
#define TS_DEFAULT_MAX_RETRY_ATTEMPTS   1        /* 0 或 1 */

/*
 * 默认推理强度：none = 关闭思考模式。
 *
 * 【重要】思考模式下**思考 token 与正文共用 max_tokens 预算**，
 * 因此开启思考时必须同时保证预算充足：默认 max_output_tokens = 0
 * （即不发送 max_tokens，由服务端给思考模式默认的 64K），
 * 否则思考会吃掉大半预算、正文被截断（finish_reason=length）。
 * 取值为 none / low / high / max；留空字符串则不发送该参数。
 */
#define TS_DEFAULT_REASONING_EFFORT     "none"

/* 探针（模型发现 / 连通性测试）的默认总超时；不进入正式分析请求策略。 */
#define TS_DEFAULT_PROBE_TIMEOUT_MS     30000

/* 排序权重默认值（五维基础分，和为 1.0）。 */
#define TS_DEFAULT_W_URGENCY    0.35
#define TS_DEFAULT_W_IMPACT     0.30
#define TS_DEFAULT_W_BLOCKING   0.20
#define TS_DEFAULT_W_QUICK_WIN  0.10
#define TS_DEFAULT_W_DEPTH      0.05

typedef struct TsConfig {
    char *endpoint_url;          /* 完整的 Chat Completions 接口地址（owned） */
    char *model;                 /* 模型名称（owned） */
    char *api_key_env;           /* 保存 API Key 的环境变量名（owned，可为空） */
    char *api_key;               /* 从环境变量解析出的 Key（owned，可为 NULL） */
    /*
     * config_path：本次实际加载的配置文件绝对路径（owned，可为 NULL）。
     * 只用于诊断与错误提示——多份 config.json 并存时，
     * 必须能一眼看出程序到底读了哪一份。
     */
    char *config_path;
    char *ca_bundle_path;        /* TLS 根证书包（PEM）路径（owned，可为空） */
    /*
     * reasoning_effort：推理强度（owned，可为 NULL = 不发送该参数）。
     * 取值 none / low / high / max（DeepSeek 官方文档）。
     * 默认 "none"：本程序要求模型直接输出 JSON，思考模式下思考 token 会占用
     * max_tokens 预算，可能导致 JSON 被截断；且官方明确 JSON 模式下
     * 思考模式可能让 content 被部分截断。留空则不发送该参数，
     * 以兼容不识别它的其它 OpenAI 兼容服务。
     */
    char *reasoning_effort;
    long connect_timeout_ms;     /* 连接超时 */
    long wait_prompt_ms;         /* 120 秒提醒阈值 */
    long request_timeout_ms;     /* 总超时；0 = 禁用（云端默认禁用） */
    long max_output_tokens;
    long max_input_bytes;
    long max_response_bytes;
    int  json_mode;              /* 是否发送 JSON 模式参数 */
    double temperature;
    double reference_hours;      /* 工时优势归一化参考（小时） */
    double w_urgency;
    double w_impact;
    double w_blocking;
    double w_quick_win;
    double w_depth;
    long max_tasks;
    long max_steps_per_task;
    int  max_retry_attempts;     /* 0 或 1 */
    int  mock_mode;              /* 1 = 使用内置模拟响应，不发起网络请求 */

    /*
     * ---- 0.0.4 新增：供应商 profile 投影 ----
     *
     * 这些字段是“本次请求实际使用的连接”的快照。它们由 profile 应用而来
     * （ts_profile_apply_to_config），也可以完全不设置（保持 0.0.3 行为）。
     * profile_revision / auth_mode / credential_host 只用于诊断与来源回带，
     * **绝不包含密钥本身**。
     */
    char *profile_id;            /* 本次请求使用的 profile id（owned，可空） */
    long profile_revision;       /* 该 profile 的版本号；0 = 未使用 profile */
    int  protocol;               /* TsProtocol；0 = legacy（0.0.3 行为） */
    int  thinking;               /* TsThinking；见 profile.h */
    char *thinking_effort;       /* 思考强度 low/high/max；未开启思考时为 NULL */
    char *models_url;            /* 完整模型列表 URL（owned，可空） */
    char *auth_mode;             /* "bearer" / "none"（owned，可空 = 未声明） */
    char *credential_host;       /* 凭据绑定时的主机（owned，可空） */
    /*
     * probe_timeout_ms：探针（模型发现 / 连通性测试）的总超时。
     * 只对探针生效，**不进入正式分析请求策略**（正式分析默认仍无总超时）。
     */
    long probe_timeout_ms;
} TsConfig;

/* 置零 + 填充默认值；api_key 由 load 从环境变量解析。 */
void ts_config_init(TsConfig *c);

/* 释放所有堆内存；NULL 安全。密钥字段走安全擦除。 */
void ts_config_free(TsConfig *c);

/*
 * 深拷贝：dst 的全部 owned 字段都重新分配，与 src 不共享任何指针。
 * 调用前 dst 必须已 ts_config_init（失败时 dst 仍是可安全 free 的已初始化状态）。
 * 成功返回 0；失败返回非 0（dst 会被清理成已初始化状态）。
 */
int ts_config_copy(TsConfig *dst, const TsConfig *src);

/*
 * 用指针交换把 src 的内容移交给 dst（src 变成已初始化状态）。
 * 用于“把快照交给 job 拥有”这类场景，避免再分配一次。
 * 调用前 dst 必须已初始化；dst 原有内容会先被释放。
 */
void ts_config_move(TsConfig *dst, TsConfig *src);

/* 从 JSON 文件加载并解析配置。成功返回 0，失败返回非 0 并写 err。 */
int ts_config_load(const char *path, TsConfig *cfg, char *err, size_t err_sz);

/* 校验一个已填充配置（字段范围、权重和为 1）。成功返回 0，失败写 err。 */
int ts_config_validate(const TsConfig *cfg, char *err, size_t err_sz);

/*
 * ts_config_requires_auth：
 * 配置是否**明确要求**鉴权。语义：
 *   - 配置里已提供内联 api_key（非空）→ 要求鉴权，且密钥已就绪；
 *   - api_key_env == NULL（配置里没有该字段）→ 未声明，不要求鉴权
 *     （用于无需鉴权的本地服务，保持兼容）；
 *   - api_key_env 为空字符串（配置里显式写了 ""）→ 显式声明“无需鉴权”；
 *   - 其它非空字符串 → 明确要求从该环境变量取密钥。
 * 这样把“配置里根本没写”和“显式留空”区分开，
 * 避免“写了环境变量名但取不到值”被静默当成“无需鉴权”。
 */
int ts_config_requires_auth(const TsConfig *cfg);

/*
 * ts_config_api_key_source：
 * 只报告密钥**来源**，绝不涉及密钥内容。取值：
 *   0 = 没有可用密钥
 *   1 = 来自配置文件的内联 api_key
 *   2 = 来自环境变量 api_key_env
 * 用于诊断与 JSON 导出（让用户能一眼看出程序到底用了哪一种来源）。
 */
int ts_config_api_key_source(const TsConfig *cfg);

/*
 * ts_config_api_key_format_error：
 * 检查“已经取到的”密钥文本是否存在明显格式问题（无论来自内联还是环境变量）。
 * 只做**检测与拒发**，绝不修改、截断或替换密钥内容。
 * 返回指向静态说明字符串的指针；NULL 表示没有发现格式问题。
 * 注意：返回的说明只描述“哪个位置是什么类别的字符”，绝不回显密钥内容。
 */
const char *ts_config_api_key_format_error(const char *key);

#ifdef __cplusplus
}
#endif

#endif /* TS_CONFIG_H */

