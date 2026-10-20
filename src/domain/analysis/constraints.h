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
 * 协议 v2 入口：额外携带请求捕获的日期/时区与已提交的结构化时间表。
 *
 * - current_date 形如 "2026-10-20"；NULL 时回退到本机时间。
 * - timezone 形如 "Asia/Shanghai (+08:00)"；NULL 时回退到本机时区。
 * - timetable_json 是请求里的 timetable 对象原文；NULL/空表示没有时间表。
 *   非空时会被原样嵌入 user 提示词的【结构化时间表】区块（仍是数据，不是指令）。
 * - generation 之后所有相对日期都以 current_date 为准，不依赖运行当天。
 */
int ts_constraints_run_ex(const TsConfig *cfg,
                          const char *user_request, const TsInputs *inputs,
                          const char *current_date, const char *timezone,
                          const char *timetable_json,
                          const TsCancel *cancel, int generation,
                          TsAnalyzeProgressFn progress, void *progress_userdata,
                          TsConstraintsResult *out);

/*
 * 结构化时间表的可信语义（system 提示词共用）。返回静态字符串，调用方不得释放。
 * 正式分析与约束识别两条提示词路径都必须包含它。
 */
const char *ts_constraints_timetable_semantics(void);

/*
 * 把请求里的 timetable JSON 规范化成提示词区块文本（owned）。
 * 失败返回 NULL；用于约束识别与正式分析共用的输入边界。
 */
char *ts_constraints_timetable_block(const char *timetable_json);

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
