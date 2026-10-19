#ifndef TS_EXPORT_USER_H
#define TS_EXPORT_USER_H

/*
 * export_user.h — 面向用户的 TXT 导出：只写任务事实、步骤、前置、外部条件与安排原因。
 *
 * 主要函数：ts_export_user_txt。
 */
#include <stddef.h>
#include "config.h"
#include "scheduler.h"
#include "types.h"

#ifdef __cplusplus
extern "C" {
#endif

int ts_export_user_txt(const TsPlan *plan,
                       const TsScheduleResult *sched,
                       const TsStatusView *status,
                       const char *path,
                       char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_EXPORT_USER_H */

