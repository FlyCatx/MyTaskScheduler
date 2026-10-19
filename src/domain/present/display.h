#ifndef TS_DISPLAY_H
#define TS_DISPLAY_H

/*
 * display.h — 展示快照（ds JSON）生成：只保留界面需要的事实与自然语言理由，不含分数、权重与公式。
 *
 * 主要函数：ts_display_build、ts_display_task_reasons。
 */
#include <stddef.h>
#include "config.h"
#include "scheduler.h"
#include "types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TS_DISPLAY_FORMAT_VERSION "1"

/*
 * 生成展示快照 JSON（owned UTF-8）。
 * plan 必须已通过 ts_plan_validate。sched / status 可为 NULL（此时不输出顺序与时间轴）。
 * 成功返回 0；失败返回非 0 并写 err。
 */
int ts_display_build(const TsPlan *plan,
                     const TsScheduleResult *sched,
                     const TsStatusView *status,
                     char **out, size_t *out_len,
                     char *err, size_t err_sz);

/* 就绪状态的稳定文本标识与中文名（界面“颜色 + 文字”双通道表达）。 */
const char *ts_display_status_key(TsReadyState s);
const char *ts_display_status_text(TsReadyState s);

/*
 * 单个任务的自然语言安排原因（多行文本，owned）。
 * 供展示快照与“面向用户的 TXT 导出”共用，保证两处措辞一致。
 */
int ts_display_task_reasons(const TsPlan *plan,
                            const TsScheduleResult *sched,
                            const TsStatusView *status,
                            size_t task_index,
                            char **out, char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_DISPLAY_H */

