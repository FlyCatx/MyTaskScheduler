#ifndef TS_PLAN_H
#define TS_PLAN_H

/*
 * plan.h — 模型输出 JSON 的解析与计划业务校验声明。
 *
 * 主要函数：ts_plan_parse（解析成功后自动调用 ts_plan_validate）、ts_plan_validate。
 */
#include "types.h"
#include "config.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TS_MAX_STRING_BYTES      8000  /* 单个字符串字段字节上限 */
#define TS_MAX_PRECONDITIONS     64    /* 单任务外部条件数量上限 */
#define TS_MAX_ASSUMPTIONS       256
#define TS_MAX_QUESTIONS         256
#define TS_MAX_NOTES             256   /* schema 2.0：待确认/受阻/假设条目上限 */
#define TS_MAX_SOURCE_REFS       512   /* 单任务来源引用数量上限 */

/*
 * 解析模型输出 JSON 为 TsPlan。
 * 成功返回 0（plan 已填充）；失败返回非 0 并写 err。
 * 无论成败，调用方都应 ts_plan_free（parse 前请先 ts_plan_init，parse 内部会重新 init）。
 */
int ts_plan_parse(const char *json, size_t json_len, const TsConfig *cfg,
                  TsPlan *plan, char *err, size_t err_sz);

/*
 * 业务校验。成功返回 0，失败返回非 0 并写 err。
 * 本地编辑任务/依赖/评分/工时/条件后应再次调用。
 */
int ts_plan_validate(const TsPlan *plan, const TsConfig *cfg, char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_PLAN_H */

