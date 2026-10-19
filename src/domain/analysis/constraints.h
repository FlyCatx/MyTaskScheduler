#ifndef TS_CONSTRAINTS_H
#define TS_CONSTRAINTS_H

/*
 * constraints.h — 独立的日历约束识别请求，产出待用户逐条确认的提案（proposals / notes）。
 *
 * 主要函数：ts_constraints_run、ts_constraints_validate、
 * ts_constraints_result_init / ts_constraints_result_free。
 */
#include <stddef.h>

#include "analyze.h"   /* TsAnalyzeProgressFn / TsAnalyzeDiagnostics */
#include "config.h"
#include "input.h"
#include "runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TsConstraintsResult {
    int ok;                 /* 1 = 成功，proposals_json 有效 */
    int error_kind;         /* 失败时的 TsModelErrorKind */
    char *error;            /* owned：失败原因（中文、可展示） */
    long http_status;

    long usage_prompt_tokens;
    long usage_completion_tokens;
    long usage_reasoning_tokens;
    long usage_total_tokens;
    int  usage_present;

    /*
     * owned：规范化后的提案 JSON，形如
     *   {"schemaVersion":1,"proposals":[...],"notes":[...]}
     * 只保留校验通过的字段；模型多写的字段不会传出去。
     */
    char *proposals_json;

    TsAnalyzeDiagnostics diag;

    /* 本次请求**实际**使用的思考配置（如实上报，不做隐藏修改）。 */
    int  thinking_enabled;
    char *thinking_effort;  /* owned：low/high/max；未启用时为 NULL */

    long elapsed_ms;
} TsConstraintsResult;

void ts_constraints_result_init(TsConstraintsResult *r);
void ts_constraints_result_free(TsConstraintsResult *r);

/*
 * 执行一次约束识别。
 * - user_request 可为 NULL（材料本身就能构成上下文）。
 * - cancel / generation 用于取消；progress / progress_userdata 可为 NULL。
 * 返回 0 表示成功（out->ok == 1）。
 */
int ts_constraints_run(const TsConfig *cfg,
                       const char *user_request, const TsInputs *inputs,
                       const TsCancel *cancel, int generation,
                       TsAnalyzeProgressFn progress, void *progress_userdata,
                       TsConstraintsResult *out);

/*
 * 校验并规范化模型正文。成功返回 0，*out 为 owned 规范化 JSON。
 * 失败返回非 0，err 写入可展示原因（用于触发一次修复请求）。
 * 单独导出以便单元测试直接覆盖校验器。
 */
int ts_constraints_validate(const char *body, size_t len,
                            char **out, char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_CONSTRAINTS_H */

