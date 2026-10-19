#ifndef TS_PLAN_LOCAL_H
#define TS_PLAN_LOCAL_H

/*
 * plan_local.h — 本地计划 JSON（lp 格式）与 TsPlan 之间的编解码。
 *
 * 主要函数：ts_local_plan_parse、ts_local_plan_to_json。
 */
#include <stddef.h>
#include "config.h"
#include "types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 本地计划协议版本（与模型 schema_version 独立演进）。 */
#define TS_LOCAL_PLAN_VERSION "1"

/*
 * 解析本地计划 JSON 为 TsPlan。
 * 成功返回 0；失败返回非 0 并写 err。parse 前会 ts_plan_init，
 * 无论成败调用方都应 ts_plan_free。
 */
int ts_local_plan_parse(const char *json, size_t json_len, const TsConfig *cfg,
                        TsPlan *out, char *err, size_t err_sz);

/*
 * 把 TsPlan 序列化为本地计划 JSON（owned，UTF-8）。
 * 包含完成任务所需的全部事实（含 actual_status），不含任何分数、权重、
 * 候选快照或诊断信息。
 */
int ts_local_plan_to_json(const TsPlan *plan, char **out, size_t *out_len,
                          char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_PLAN_LOCAL_H */

