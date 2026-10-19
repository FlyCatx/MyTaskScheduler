#ifndef TS_EXPORT_INTERNAL_H
#define TS_EXPORT_INTERNAL_H

/*
 * export_internal.h — 导出模块内部共享的工具（export.c / export_json.c / export_user.c）。
 *
 * 主要函数：ts_export_state_label / ready_state_name、ts_export_precond_label / precond_name、
 * ts_export_find_task_index、ts_export_task_name_by_id、ts_export_join_preconds、
 * ts_export_find_blocking_ancestor、ts_export_write_file（唯一的写盘实现）。
 */
#include <stddef.h>
#include "export.h"
#include "mem.h"

const char *ts_export_state_label(TsReadyState st);
const char *ts_export_ready_state_name(TsReadyState st);
const char *ts_export_precond_label(TsPrecondStatus st);
const char *ts_export_precond_name(TsPrecondStatus st);

size_t ts_export_find_task_index(const TsPlan *plan, const char *id);
const char *ts_export_task_name_by_id(const TsPlan *plan, const char *id);

/* 拼接具有指定状态的外部条件描述（返回命中数量）。 */
int ts_export_join_preconds(const TsTask *t, TsPrecondStatus want, TsBuf *b);

/* 沿 depends_on 向上游找到第一个“受阻或待确认”的祖先；找不到返回 SIZE_MAX。 */
size_t ts_export_find_blocking_ancestor(const TsPlan *plan, size_t task_index,
                                        const unsigned char *is_blocked_or_pending);

/* 以 UTF-8 路径写文件；with_bom 为真时写入 UTF-8 BOM。失败时删除半成品文件。 */
int ts_export_write_file(const char *path, const char *data, size_t len,
                         int with_bom, char *err, size_t err_sz);

#endif /* TS_EXPORT_INTERNAL_H */

