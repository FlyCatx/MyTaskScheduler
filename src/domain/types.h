#ifndef TS_TYPES_H
#define TS_TYPES_H

/*
 * types.h — 核心公共数据结构（任务、计划、外部条件与完成状态），不依赖 GUI。
 *
 * 主要函数：ts_task_init / ts_task_free、ts_plan_init / ts_plan_free。
 */
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 外部条件（前置条件）状态，对应协议中的 preconditions[].status。 */
typedef enum TsPrecondStatus {
    TS_PRECOND_UNKNOWN = 0, /* unknown */
    TS_PRECOND_MET     = 1, /* met */
    TS_PRECOND_UNMET   = 2  /* unmet */
} TsPrecondStatus;

/* 用户实际完成状态（由用户操作维护，模型不得擅自标记完成）。 */
typedef enum TsActualStatus {
    TS_ACTUAL_TODO = 0, /* 未完成 */
    TS_ACTUAL_DONE = 1  /* 已完成 */
} TsActualStatus;

typedef struct TsPrecondition {
    char *description;         /* owned UTF-8，非空 */
    TsPrecondStatus status;
} TsPrecondition;

/*
 * 需要用户注意的条目（schema 2.0 的 notes[]）。
 *
 * 为什么单独建结构，而不复用 assumptions/questions 字符串数组：
 * 界面要求“分节的待确认/受阻/假设卡片，具体问题可跳转到关联任务”，
 * 而纯字符串无法携带任务引用。task_refs 使用**模型本轮的 id**，
 * 本地再映射为稳定任务 ID（模型 id 不能跨版本当作真实身份）。
 */
typedef enum TsNoteKind {
    TS_NOTE_QUESTION   = 1, /* 待确认 */
    TS_NOTE_BLOCKED    = 2, /* 受阻 */
    TS_NOTE_ASSUMPTION = 3  /* 分析假设 */
} TsNoteKind;

typedef struct TsNote {
    char *text;                /* owned，非空 */
    TsNoteKind kind;
    char **task_refs;          /* owned 数组，元素为 owned 字符串（模型 id） */
    size_t task_ref_count;
} TsNote;

typedef struct TsTask {
    char *id;                  /* owned，唯一，非空 */
    char *name;                /* owned，非空 */
    /*
     * previous_task_id：模型对“本任务承接上一版哪个任务”的**建议**（可为 NULL）。
     * 只是建议：本地必须校验归属（确属基准版本）、不重复匹配、内容是否一致，
     * 不得直接据此继承完成状态。
     */
    char *previous_task_id;
    char **depends_on;         /* owned 数组，元素为 owned 字符串（任务 ID） */
    size_t depends_on_count;
    TsPrecondition *preconditions; /* owned 数组 */
    size_t preconditions_count;
    char **steps;              /* owned 数组，元素为 owned 字符串 */
    size_t steps_count;
    int urgency;               /* 1..5；0 表示未设置 */
    char *urgency_reason;      /* owned */
    int impact;                /* 1..5；0 表示未设置 */
    char *impact_reason;       /* owned */
    int has_estimated_hours;   /* 1 表示 estimated_hours 有效 */
    double estimated_hours;    /* >0 当 has_estimated_hours 为真 */
    char *estimate_reason;     /* owned，可为 NULL */
    char *deadline;            /* owned，可为 NULL（未知） */
    char **source_refs;        /* owned 数组，元素为 owned 字符串 */
    size_t source_refs_count;
    TsActualStatus actual_status; /* 用户维护的实际完成状态 */
} TsTask;

typedef struct TsPlan {
    int schema_major;          /* schema_version "major.minor" 的 major */
    int schema_minor;
    /*
     * summary：模型给出的一句话总结（schema 2.0 起）。
     * 缺失时保持 NULL，由使用方用输入摘要兜底——不因缺少标题丢弃有效任务。
     */
    char *summary;
    TsTask *tasks;             /* owned 数组 */
    size_t task_count;
    TsNote *notes;             /* owned 数组（schema 2.0 起；可为空） */
    size_t note_count;
    char **assumptions;        /* owned 数组，元素为 owned 字符串 */
    size_t assumptions_count;
    char **questions;          /* owned 数组，元素为 owned 字符串 */
    size_t questions_count;
    char **suggested_order;    /* 模型给出的参考顺序（可忽略），owned */
    size_t suggested_order_count;
} TsPlan;

/* 生命周期：init 置零，free 释放所有嵌套内存；均为 NULL 安全。 */
void ts_task_init(TsTask *t);
void ts_task_free(TsTask *t);
void ts_plan_init(TsPlan *p);
void ts_plan_free(TsPlan *p);

#ifdef __cplusplus
}
#endif

#endif /* TS_TYPES_H */

