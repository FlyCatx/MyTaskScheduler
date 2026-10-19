#ifndef TS_PROMPT_H
#define TS_PROMPT_H

/*
 * prompt.h — 分析用的 system / user / 修复提示词与请求体构造。
 *
 * 主要函数：ts_prompt_build_system、ts_prompt_build_user / ts_prompt_build_user_ex、
 * ts_prompt_build_repair_user、ts_prompt_build_request、ts_prompt_current_datetime、ts_prompt_timezone_name。
 */
#include <stddef.h>
#include "config.h"
#include "input.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 当前本地日期时间（"YYYY-MM-DD HH:MM"）与时区名（含 UTC 偏移）；均为 owned。 */
char *ts_prompt_current_datetime(void);
char *ts_prompt_timezone_name(void);

/* system 提示词（owned）。 */
char *ts_prompt_build_system(void);

/*
 * user 提示词（owned）：用户要求 + 附件材料（含来源/段落编号）+ 当前日期与时区。
 * user_request 可为 NULL。max_bytes 为整体上限，超出报错（不截断）。
 */
int ts_prompt_build_user(const char *user_request, const TsInputs *inputs,
                         const char *current_datetime, const char *timezone,
                         long max_bytes, char **out, size_t *out_len,
                         char *err, size_t err_sz);

/*
 * 带“当前计划”上下文的 user 提示词（schema 2.0 的补充要求场景）。
 *
 * plan_context 为本地生成的紧凑计划快照文本（含稳定任务 ID、名称、依赖、
 * 工时、完成状态），会作为独立的【当前计划】区块附在材料之后。
 * 传 NULL 等价于 ts_prompt_build_user。
 *
 * 之所以把计划上下文放在**材料之外**：它是本地事实，不是用户材料，
 * 模型不应把它当作用户原文引用（source_refs 只应引用文件/文段）。
 */
int ts_prompt_build_user_ex(const char *user_request, const char *plan_context,
                            const TsInputs *inputs,
                            const char *current_datetime, const char *timezone,
                            long max_bytes, char **out, size_t *out_len,
                            char *err, size_t err_sz);

/*
 * 修复用 user 提示词（owned）：附带校验错误与上次输出，要求只返回修正后的 JSON。
 *
 * truncated = 1 表示上次是**因为 token 上限被截断**（finish_reason=length）。
 * 这种失败的成因与“格式不对”不同：输出是被预算砍断的，所以修复提示词里
 * 必须额外要求模型**精简表达**（减少步骤/理由的文字量），
 * 否则用同样的预算重发一次通常还是会被截断，等于白花一次调用。
 */
int ts_prompt_build_repair_user(const char *user_prompt,
                                const char *previous_output,
                                const char *validation_error,
                                int truncated,
                                char **out, size_t *out_len,
                                char *err, size_t err_sz);

/* 用 cJSON 构造 OpenAI 兼容 Chat Completions 请求体（紧凑 JSON，owned）。 */
int ts_prompt_build_request(const TsConfig *cfg,
                            const char *system_prompt, const char *user_prompt,
                            char **out_json, size_t *out_len,
                            char *err, size_t err_sz);

/*
 * 本次请求实际发送的思考强度（low/high/max）。
 *
 * 顺序：cfg->thinking_effort → cfg->reasoning_effort → "high"。
 * 只有 protocol=deepseek-chat 且 thinking=enabled 时才会被写进请求体；
 * openai-chat 与 legacy 协议都不会用它（见 ts_prompt_build_request）。
 * 返回值永不为 NULL，且只可能是 low/high/max。
 */
const char *ts_prompt_effective_effort(const TsConfig *cfg);

#ifdef __cplusplus
}
#endif

#endif /* TS_PROMPT_H */

