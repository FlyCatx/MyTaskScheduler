#ifndef TS_CONTROLLER_H
#define TS_CONTROLLER_H

/*
 * controller.h — 后台分析任务的生命周期、请求代号、取消、结果通知与本地编辑。
 *
 * 主要函数：ts_controller_create / destroy、ts_controller_start_analyze、ts_controller_cancel、
 * ts_controller_recompute / adopt_result、ts_controller_edit_task 与 set_*（名称、评分、工时、截止、完成、依赖、外部条件）。
 */
#include <stddef.h>
#include "config.h"
#include "input.h"
#include "types.h"
#include "scheduler.h"
#include "analyze.h"
#include "runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TsControllerEvent {
    TS_EVT_STARTED = 1,   /* 已开始一次分析 */
    TS_EVT_PROGRESS = 2,  /* 阶段/重试信息更新 */
    TS_EVT_FINISHED = 3   /* 分析结束（成功或失败） */
} TsControllerEvent;

/* 通知回调：可能在【工作线程】中被调用，实现方不得直接操作 GUI 控件。 */
typedef void (*TsControllerNotifyFn)(void *userdata, int event);

typedef struct TsController TsController;

/* cfg 由调用方拥有，必须比 controller 存活更久。 */
TsController *ts_controller_create(const TsConfig *cfg);
void ts_controller_destroy(TsController *c);

void ts_controller_set_notify(TsController *c, TsControllerNotifyFn fn, void *userdata);

/* ---- 只读访问 ---- */
const TsConfig *ts_controller_config(const TsController *c);
size_t ts_controller_source_count(const TsController *c);
const TsInputSource *ts_controller_source(const TsController *c, size_t index);
size_t ts_controller_input_bytes(const TsController *c);

int ts_controller_has_plan(const TsController *c);
const TsPlan *ts_controller_plan(const TsController *c);
const TsScheduleResult *ts_controller_schedule(const TsController *c);
const TsStatusView *ts_controller_status(const TsController *c);
/* 最近一次校验/排序提示（成功时为空字符串） */
const char *ts_controller_plan_message(const TsController *c);
/* 任务在建议顺序中的位置；返回 SIZE_MAX 表示未排入 */
size_t ts_controller_step_index_of(const TsController *c, size_t task_index);

/* ---- 输入（仅空闲时可调用） ---- */
int ts_controller_add_file(TsController *c, const char *path, char *err, size_t err_sz);
int ts_controller_add_text(TsController *c, const char *text, const char *detail,
                           char *err, size_t err_sz);
void ts_controller_clear_inputs(TsController *c);
void ts_controller_set_user_request(TsController *c, const char *request);
const char *ts_controller_user_request(const TsController *c);

/* ---- 分析 ---- */
int  ts_controller_start_analyze(TsController *c, char *err, size_t err_sz);
void ts_controller_cancel(TsController *c);
int  ts_controller_is_running(const TsController *c);
int  ts_controller_generation(const TsController *c);
long ts_controller_elapsed_ms(const TsController *c);
/* 阶段与重试信息：写入调用方缓冲区（内部加锁，避免与工作线程竞争）。 */
void ts_controller_stage_text(TsController *c, char *buf, size_t size);
void ts_controller_stage_detail_text(TsController *c, char *buf, size_t size);
/* 最近一次分析结果（可能为空）；成功后需调用 adopt_result 才会成为当前计划 */
const TsAnalyzeResult *ts_controller_last_analyze(const TsController *c);
int ts_controller_adopt_result(TsController *c, char *err, size_t err_sz);

/* ---- 本地编辑（不调用模型） ---- */
int ts_controller_recompute(TsController *c);

/* 一次性编辑任务的多个字段，只在最后重新校验与排序一次。 */
typedef struct TsTaskEdit {
    const char *name;      /* 非空 */
    int urgency;           /* 1..5 */
    int impact;            /* 1..5 */
    int has_hours;         /* 0 = 工时未知 */
    double hours;          /* > 0 当 has_hours 为真 */
    const char *deadline;  /* NULL 或空串 = 未知 */
} TsTaskEdit;

int ts_controller_edit_task(TsController *c, size_t task_index, const TsTaskEdit *edit);
int ts_controller_set_name(TsController *c, size_t task_index, const char *name);
int ts_controller_set_urgency(TsController *c, size_t task_index, int urgency);
int ts_controller_set_impact(TsController *c, size_t task_index, int impact);
int ts_controller_set_hours(TsController *c, size_t task_index, int has_hours, double hours);
int ts_controller_set_deadline(TsController *c, size_t task_index, const char *deadline);
int ts_controller_set_actual(TsController *c, size_t task_index, int done);
int ts_controller_set_deps(TsController *c, size_t task_index,
                           const char *const *ids, size_t count);
int ts_controller_set_precond_status(TsController *c, size_t task_index,
                                     size_t precond_index, TsPrecondStatus status);

/* 离线演示：直接加载内置模拟计划（不需要网络）。 */
int ts_controller_load_mock(TsController *c, char *err, size_t err_sz);

#ifdef __cplusplus
}
#endif

#endif /* TS_CONTROLLER_H */

