#ifndef TS_ANALYZE_H
#define TS_ANALYZE_H

/*
 * analyze.h — 与 GUI 无关的分析流程编排：组装提示词、调用模型、解析并校验计划，
 * 全程轮询取消，失败时按重试与一次修复预算处理。
 *
 * 主要函数：ts_analyze_run / ts_analyze_run_ex、ts_analyze_result_init / ts_analyze_result_free。
 */
#include <stddef.h>
#include "config.h"
#include "input.h"
#include "runtime.h"
#include "types.h"
#include "model.h"   /* TsModelErrorKind：TsAnalyzeResult.error_kind 的取值 */

#ifdef __cplusplus
extern "C" {
#endif

/* 进度回调：stage 为阶段名（如“调用模型”“重试”“修复”），detail 可为 NULL。 */
typedef void (*TsAnalyzeProgressFn)(void *userdata, const char *stage, const char *detail);

typedef struct TsAnalyzeDiagnostics {
    int attempts;          /* 实际调用模型的次数（1 或 2） */
    int used_repair;       /* 是否使用了修复请求 */
    int network_retried;   /* 是否因网络/服务端错误重试过 */
    int last_error_kind;   /* 最近一次错误分类（TsModelErrorKind） */
    char *last_error;      /* owned：最近一次错误消息 */
} TsAnalyzeDiagnostics;

typedef struct TsAnalyzeResult {
    int ok;                /* 1 = 成功，plan 有效 */
    int error_kind;        /* 失败时的错误分类 */
    char *error;           /* owned：失败原因 */
    long http_status;      /* 失败时最近一次 HTTP 状态码；0 = 未取得（本地预检/网络层失败） */
    /*
     * 最近一次模型调用的 token 用量（来自响应 usage 段；未提供时 usage_present = 0）。
     * 思考模式下思考 token 与正文共用 max_tokens 预算，这组数字是判断
     * “为什么被截断”的唯一依据，因此必须带出来供界面与导出展示。
     */
    long usage_prompt_tokens;
    long usage_completion_tokens;
    long usage_reasoning_tokens;
    long usage_total_tokens;
    int  usage_present;
    TsPlan plan;           /* ok 时有效 */
    TsAnalyzeDiagnostics diag;
    long elapsed_ms;
} TsAnalyzeResult;

void ts_analyze_result_init(TsAnalyzeResult *r);
void ts_analyze_result_free(TsAnalyzeResult *r);

/*
 * 执行一次完整分析。
 * - user_request 可为 NULL。
 * - cancel / generation 用于取消；generation 由 ts_cancel_begin 产生。
 * - progress / progress_userdata 可为 NULL。
 * 返回 0 表示成功（out->ok == 1），非 0 表示失败（原因在 out->error）。
 * 无论成败，out 都可用 ts_analyze_result_free 释放。
 */
int ts_analyze_run(const TsConfig *cfg,
                   const char *user_request, const TsInputs *inputs,
                   const TsCancel *cancel, int generation,
                   TsAnalyzeProgressFn progress, void *progress_userdata,
                   TsAnalyzeResult *out);

/*
 * 与 ts_analyze_run 相同，但额外带上“当前计划”上下文（补充要求场景）。
 *
 * plan_context 为本地生成的紧凑计划快照文本；传 NULL 等价于 ts_analyze_run。
 * 计划上下文只用于让模型知道上一版计划，不参与校验，也不写入导出。
 */
int ts_analyze_run_ex(const TsConfig *cfg,
                      const char *user_request, const char *plan_context,
                      const TsInputs *inputs,
                      const TsCancel *cancel, int generation,
                      TsAnalyzeProgressFn progress, void *progress_userdata,
                      TsAnalyzeResult *out);

#ifdef __cplusplus
}
#endif

#endif /* TS_ANALYZE_H */

