#ifndef TS_SCHEDULER_H
#define TS_SCHEDULER_H

/*
 * scheduler.h — 依赖图、分层、就绪状态、评分与建议顺序。
 *
 * 主要函数：ts_schedule_build / ts_schedule_result_free（构建与释放建议顺序）、
 * ts_schedule_status / ts_status_view_free（按实际完成状态计算就绪状态）。
 */
#include "types.h"
#include "config.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 当前就绪状态（用于展示着色与详情）。 */
typedef enum TsReadyState {
    TS_READY = 0,          /* 可开始（绿色） */
    TS_WAITING_DEP = 1,    /* 待前置（蓝色） */
    TS_PENDING_CONFIRM = 2,/* 待确认（橙色，外部条件 unknown） */
    TS_BLOCKED = 3,        /* 受阻（红色，外部条件 unmet 或依赖冲突） */
    TS_DONE = 4            /* 已完成（灰色） */
} TsReadyState;

typedef struct TsScoreBreakdown {
    double u, i, b, q, d;   /* 归一化后的五维值 */
    double base;            /* 基础分（0..100） */
    double c, r, w;         /* 全局加分项（归一化） */
    double final;           /* FinalScore = base + 10C + 7R + 3W */
    int hours_unknown;      /* Q 强制取 0.5 */
    int chain_incomplete;   /* 关键链含未知工时，C 不计 */
} TsScoreBreakdown;

typedef struct TsScheduleStep {
    char *task_id;              /* owned */
    size_t task_index;          /* 在 plan->tasks 中的下标 */
    TsScoreBreakdown score;
    char **candidates;          /* 选中时的候选快照（owned 字符串数组） */
    size_t candidate_count;
    char **unlocked;            /* 本步完成后立即解锁的任务 ID */
    size_t unlocked_count;
    char **still_waiting;       /* 仍待其它前置/条件的直接后继 ID */
    size_t still_waiting_count;
    char *reason;               /* 本地生成的可解释性说明（owned） */
} TsScheduleStep;

typedef struct TsScheduleResult {
    char sorted_at[32];         /* 生成本次排序结果的本地时间（"YYYY-MM-DD HH:MM:SS"） */
    TsScheduleStep *steps;
    size_t step_count;
    char **blocked_ids;         /* 受阻（外部条件 unmet / 循环） */
    size_t blocked_count;
    char **pending_ids;         /* 待确认（外部条件 unknown） */
    size_t pending_count;
    char **affected_ids;        /* 受阻/待确认任务的下游受影响任务 */
    size_t affected_count;
    char *unresolvable_reason;  /* 无候选可执行时的原因；NULL 表示已全部排完 */
} TsScheduleResult;

typedef struct TsStatusView {
    TsReadyState *states;       /* 长度 task_count */
    int *affected;              /* 长度 task_count：1 = 下游受影响 */
    int *level;                 /* 长度 task_count：依赖层级（循环时为 -1） */
    char **cycle_ids;           /* 循环中的任务 ID */
    size_t cycle_count;
} TsStatusView;

/* 生成建议顺序。成功返回 0，失败返回非 0 并写 err。out 需 ts_schedule_result_free。 */
int ts_schedule_build(const TsPlan *plan, const TsConfig *cfg,
                      TsScheduleResult *out, char *err, size_t err_sz);
void ts_schedule_result_free(TsScheduleResult *r);

/* 计算当前就绪状态视图。成功返回 0，失败返回非 0 并写 err。 */
int ts_schedule_status(const TsPlan *plan, TsStatusView *out, char *err, size_t err_sz);
void ts_status_view_free(TsStatusView *v);

#ifdef __cplusplus
}
#endif

#endif /* TS_SCHEDULER_H */

