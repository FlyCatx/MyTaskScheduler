#ifndef TS_EXPORT_H
#define TS_EXPORT_H

/*
 * export.h — 导出建议顺序与任务数据（TXT / JSON）并分派格式。
 *
 * 主要函数：ts_export_txt、ts_export_write_file、ts_export_format_from_path。
 */
#include <stddef.h>
#include "config.h"
#include "types.h"
#include "scheduler.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TS_ALGORITHM_VERSION "1.0"
#define TS_SCHEMA_VERSION    "1.0"

typedef enum TsExportFormat {
    TS_EXPORT_TXT = 1,
    TS_EXPORT_JSON = 2
} TsExportFormat;

/*
 * 导出为 UTF-8 TXT：
 *   建议顺序（含步骤、前置条件、理由、完成后解锁）、受阻任务、待确认事项等。
 *   sched / status 可以为 NULL（此时只导出任务清单）。
 * 成功返回 0，失败返回非 0 并写 err。
 */
int ts_export_txt(const TsPlan *plan, const TsScheduleResult *sched,
                  const TsStatusView *status, const TsConfig *cfg,
                  const char *path, char *err, size_t err_sz);

/*
 * token 用量（可选，仅用于诊断展示与导出；不含任何敏感内容）。
 * 思考模式下思考 token 与正文共用 max_tokens 预算，
 * 所以 reasoning_tokens 是解释“为什么输出被截断”的关键数字。
 */
typedef struct TsTokenUsageStat {
    int  present;              /* 0 = 服务端未提供 usage，其余字段无意义 */
    long prompt_tokens;
    long completion_tokens;    /* 含思考 token */
    long reasoning_tokens;
    long total_tokens;
    int  attempts;             /* 实际调用模型的次数 */
    int  truncated;            /* 1 = 曾因 token 上限被截断（finish_reason=length） */
} TsTokenUsageStat;

/*
 * 导出为 JSON：完整任务数据、依赖、评分依据、权重、算法版本、schema_version、
 * 排序时间、任务状态快照与最终顺序。绝不写入 API Key。
 */
int ts_export_json(const TsPlan *plan, const TsScheduleResult *sched,
                   const TsStatusView *status, const TsConfig *cfg,
                   const char *path, char *err, size_t err_sz);

/* 同上，但额外写入 token_usage 段（usage 可为 NULL）。 */
int ts_export_json_usage(const TsPlan *plan, const TsScheduleResult *sched,
                         const TsStatusView *status, const TsConfig *cfg,
                         const TsTokenUsageStat *usage,
                         const char *path, char *err, size_t err_sz);

/* 按格式分派。 */
int ts_export_plan(TsExportFormat format, const TsPlan *plan,
                   const TsScheduleResult *sched, const TsStatusView *status,
                   const TsConfig *cfg, const char *path, char *err, size_t err_sz);

/* 按格式分派，并把 token 用量带进 JSON 导出（usage 可为 NULL）。 */
int ts_export_plan_usage(TsExportFormat format, const TsPlan *plan,
                         const TsScheduleResult *sched, const TsStatusView *status,
                         const TsConfig *cfg, const TsTokenUsageStat *usage,
                         const char *path, char *err, size_t err_sz);

/* 依据扩展名推断格式：.json → JSON，其它 → TXT。 */
TsExportFormat ts_export_format_from_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* TS_EXPORT_H */

