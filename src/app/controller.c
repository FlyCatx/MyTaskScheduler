/*
 * controller.c — 后台分析任务的生命周期、请求代号、取消、通知与本地编辑；工作线程只运行 ts_analyze_run。
 *
 * 主要函数：ts_controller_start_analyze、ts_controller_cancel、ts_controller_recompute、
 * ts_controller_adopt_result、ts_controller_edit_task / set_*、ts_controller_destroy。
 */

#include "controller.h"
#include "model.h"
#include "plan.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

struct TsController {
    const TsConfig *cfg;      /* 借用，调用方拥有 */

    TsInputs inputs;
    char *user_request;

    /* 最近一次分析结果（工作线程写入，主线程读取） */
    TsAnalyzeResult result;
    int has_result;

    /* 当前计划与派生结果（仅主线程访问） */
    TsPlan plan;
    int has_plan;
    TsScheduleResult sched;
    int has_sched;
    TsStatusView status;
    int has_status;
    char plan_message[512];

    /* 取消与线程 */
    TsCancel cancel;
    int current_gen;
    int running;
    HANDLE thread;
    DWORD thread_id;
    uint64_t started_ms;
    long last_elapsed_ms;

    CRITICAL_SECTION cs;

    /* 进度（工作线程写，主线程读） */
    char stage[64];
    char stage_detail[256];

    TsControllerNotifyFn notify;
    void *notify_userdata;
};

/* ------------------------------------------------------------------ */
/* 通知                                                                */
/* ------------------------------------------------------------------ */

static void notify(TsController *c, int event)
{
    TsControllerNotifyFn fn = c->notify;
    if (fn != NULL) {
        fn(c->notify_userdata, event);
    }
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                            */
/* ------------------------------------------------------------------ */

TsController *ts_controller_create(const TsConfig *cfg)
{
    TsController *c = (TsController *)ts_calloc(1, sizeof(TsController));
    if (c == NULL) {
        return NULL;
    }
    c->cfg = cfg;
    ts_inputs_init(&c->inputs);
    ts_plan_init(&c->plan);
    ts_analyze_result_init(&c->result);
    ts_cancel_init(&c->cancel);
    InitializeCriticalSection(&c->cs);
    snprintf(c->stage, sizeof(c->stage), "%s", "就绪");
    return c;
}

void ts_controller_destroy(TsController *c)
{
    if (c == NULL) {
        return;
    }

    ts_cancel_request(&c->cancel);
    if (c->thread != NULL) {
        DWORD w = WaitForSingleObject(c->thread, 10000);
        if (w != WAIT_OBJECT_0) {
            /*
             * 不强制终止工作线程（TerminateThread 会造成资源泄漏与死锁）。
             * 进程即将退出，交给操作系统回收；此处不释放内存，
             * 以免工作线程访问已释放对象。
             */
            return;
        }
        CloseHandle(c->thread);
        c->thread = NULL;
    }

    ts_inputs_free(&c->inputs);
    ts_free(c->user_request);
    ts_analyze_result_free(&c->result);
    ts_plan_free(&c->plan);
    if (c->has_sched) ts_schedule_result_free(&c->sched);
    if (c->has_status) ts_status_view_free(&c->status);
    DeleteCriticalSection(&c->cs);
    ts_free(c);
}

void ts_controller_set_notify(TsController *c, TsControllerNotifyFn fn, void *userdata)
{
    if (c == NULL) return;
    c->notify = fn;
    c->notify_userdata = userdata;
}

/* ------------------------------------------------------------------ */
/* 只读访问                                                            */
/* ------------------------------------------------------------------ */

const TsConfig *ts_controller_config(const TsController *c)
{
    return (c != NULL) ? c->cfg : NULL;
}

size_t ts_controller_source_count(const TsController *c)
{
    return (c != NULL) ? c->inputs.source_count : 0;
}

const TsInputSource *ts_controller_source(const TsController *c, size_t index)
{
    if (c == NULL || index >= c->inputs.source_count) return NULL;
    return &c->inputs.sources[index];
}

size_t ts_controller_input_bytes(const TsController *c)
{
    return (c != NULL) ? ts_inputs_total_bytes(&c->inputs) : 0;
}

int ts_controller_has_plan(const TsController *c)
{
    return (c != NULL && c->has_plan) ? 1 : 0;
}

const TsPlan *ts_controller_plan(const TsController *c)
{
    return (c != NULL && c->has_plan) ? &c->plan : NULL;
}

const TsScheduleResult *ts_controller_schedule(const TsController *c)
{
    return (c != NULL && c->has_sched) ? &c->sched : NULL;
}

const TsStatusView *ts_controller_status(const TsController *c)
{
    return (c != NULL && c->has_status) ? &c->status : NULL;
}

const char *ts_controller_plan_message(const TsController *c)
{
    return (c != NULL) ? c->plan_message : "";
}

size_t ts_controller_step_index_of(const TsController *c, size_t task_index)
{
    size_t i;
    if (c == NULL || !c->has_sched) return SIZE_MAX;
    for (i = 0; i < c->sched.step_count; i++) {
        if (c->sched.steps[i].task_index == task_index) return i;
    }
    return SIZE_MAX;
}

/* ------------------------------------------------------------------ */
/* 输入                                                                */
/* ------------------------------------------------------------------ */

static int require_idle(TsController *c, char *err, size_t err_sz)
{
    int busy;
    EnterCriticalSection(&c->cs);
    busy = c->running;
    LeaveCriticalSection(&c->cs);
    if (busy) {
        snprintf(err, err_sz, "分析进行中，请先取消或等待完成");
        return 1;
    }
    return 0;
}

int ts_controller_add_file(TsController *c, const char *path, char *err, size_t err_sz)
{
    long limit;
    if (c == NULL) return 1;
    if (require_idle(c, err, err_sz)) return 1;
    limit = (c->cfg != NULL) ? c->cfg->max_input_bytes : (long)TS_DEFAULT_MAX_INPUT_BYTES;
    return ts_inputs_add_file(&c->inputs, path, limit, err, err_sz);
}

int ts_controller_add_text(TsController *c, const char *text, const char *detail,
                           char *err, size_t err_sz)
{
    long limit;
    if (c == NULL) return 1;
    if (require_idle(c, err, err_sz)) return 1;
    limit = (c->cfg != NULL) ? c->cfg->max_input_bytes : (long)TS_DEFAULT_MAX_INPUT_BYTES;
    return ts_inputs_add_text(&c->inputs, text, detail, limit, err, err_sz);
}

void ts_controller_clear_inputs(TsController *c)
{
    if (c == NULL) return;
    ts_inputs_free(&c->inputs);
    ts_inputs_init(&c->inputs);
}

void ts_controller_set_user_request(TsController *c, const char *request)
{
    if (c == NULL) return;
    ts_free(c->user_request);
    c->user_request = (request != NULL) ? ts_strdup(request) : NULL;
}

const char *ts_controller_user_request(const TsController *c)
{
    return (c != NULL && c->user_request != NULL) ? c->user_request : "";
}

/* ------------------------------------------------------------------ */
/* 工作线程                                                            */
/* ------------------------------------------------------------------ */

static void progress_cb(void *userdata, const char *stage, const char *detail)
{
    TsController *c = (TsController *)userdata;
    EnterCriticalSection(&c->cs);
    if (stage != NULL) {
        snprintf(c->stage, sizeof(c->stage), "%s", stage);
    }
    if (detail != NULL) {
        snprintf(c->stage_detail, sizeof(c->stage_detail), "%s", detail);
    } else {
        c->stage_detail[0] = '\0';
    }
    LeaveCriticalSection(&c->cs);
    notify(c, TS_EVT_PROGRESS);
}

static DWORD WINAPI worker_proc(LPVOID param)
{
    TsController *c = (TsController *)param;
    TsAnalyzeResult local;
    int gen;

    ts_analyze_result_init(&local);

    EnterCriticalSection(&c->cs);
    gen = c->current_gen;
    LeaveCriticalSection(&c->cs);

    ts_analyze_run(c->cfg, c->user_request, &c->inputs,
                   &c->cancel, gen, progress_cb, c, &local);

    EnterCriticalSection(&c->cs);
    if (ts_cancel_gen(&c->cancel) == gen) {
        /*
         * 未被更新的请求取代时（迟到结果在此被丢弃）才考虑发布。
         * 并且：一旦该请求已被取消，即使拿到的是完整成功结果也不采纳——
         * 取消是终态，避免“取消与完成竞争”时结果被当成成功并覆盖已有计划。
         */
        if (local.ok && ts_cancel_is_requested(&c->cancel)) {
            ts_analyze_result_free(&c->result);
            ts_analyze_result_init(&c->result);
            c->result.ok = 0;
            c->result.error_kind = TS_MODEL_ERR_CANCELLED;
            c->result.error = ts_strdup("已取消本次分析（结果到达时已被取消，未采纳）");
            c->has_result = 1;
        } else {
            ts_analyze_result_free(&c->result);
            c->result = local;
            ts_analyze_result_init(&local);
            c->has_result = 1;
        }
    }
    c->last_elapsed_ms = (long)ts_clock_elapsed_ms(c->started_ms);
    c->running = 0;
    LeaveCriticalSection(&c->cs);

    ts_analyze_result_free(&local);
    notify(c, TS_EVT_FINISHED);
    return 0;
}

int ts_controller_start_analyze(TsController *c, char *err, size_t err_sz)
{
    if (c == NULL) return 1;
    if (c->running) {
        snprintf(err, err_sz, "已有分析在进行中");
        return 1;
    }
    if (c->inputs.source_count == 0) {
        snprintf(err, err_sz, "请先添加文件或输入文段");
        return 1;
    }
    if (c->thread != NULL) {
        CloseHandle(c->thread);
        c->thread = NULL;
    }

    EnterCriticalSection(&c->cs);
    c->current_gen = ts_cancel_begin(&c->cancel);
    c->started_ms = ts_clock_ms();
    c->last_elapsed_ms = 0;
    c->running = 1;
    c->has_result = 0;
    c->stage[0] = '\0';
    c->stage_detail[0] = '\0';
    LeaveCriticalSection(&c->cs);

    c->thread = CreateThread(NULL, 0, worker_proc, c, 0, &c->thread_id);
    if (c->thread == NULL) {
        EnterCriticalSection(&c->cs);
        c->running = 0;
        LeaveCriticalSection(&c->cs);
        snprintf(err, err_sz, "创建后台线程失败");
        return 1;
    }
    notify(c, TS_EVT_STARTED);
    return 0;
}

void ts_controller_cancel(TsController *c)
{
    if (c != NULL) {
        ts_cancel_request(&c->cancel);
    }
}

int ts_controller_is_running(const TsController *c)
{
    TsController *m = (TsController *)c;
    int busy;
    if (m == NULL) return 0;
    EnterCriticalSection(&m->cs);
    busy = m->running;
    LeaveCriticalSection(&m->cs);
    return busy ? 1 : 0;
}

int ts_controller_generation(const TsController *c)
{
    return (c != NULL) ? c->current_gen : 0;
}

long ts_controller_elapsed_ms(const TsController *c)
{
    TsController *m = (TsController *)c;
    int busy;
    uint64_t started;
    long last;
    if (m == NULL) return 0;
    EnterCriticalSection(&m->cs);
    busy = m->running;
    started = m->started_ms;
    last = m->last_elapsed_ms;
    LeaveCriticalSection(&m->cs);
    if (busy) {
        return (long)ts_clock_elapsed_ms(started);
    }
    return last;
}

void ts_controller_stage_text(TsController *c, char *buf, size_t size)
{
    if (buf == NULL || size == 0) return;
    if (c == NULL) { buf[0] = '\0'; return; }
    EnterCriticalSection(&c->cs);
    snprintf(buf, size, "%s", c->stage);
    LeaveCriticalSection(&c->cs);
}

void ts_controller_stage_detail_text(TsController *c, char *buf, size_t size)
{
    if (buf == NULL || size == 0) return;
    if (c == NULL) { buf[0] = '\0'; return; }
    EnterCriticalSection(&c->cs);
    snprintf(buf, size, "%s", c->stage_detail);
    LeaveCriticalSection(&c->cs);
}

const TsAnalyzeResult *ts_controller_last_analyze(const TsController *c)
{
    return (c != NULL && c->has_result) ? &c->result : NULL;
}

/* ------------------------------------------------------------------ */
/* 校验 / 调度 / 状态                                                  */
/* ------------------------------------------------------------------ */

int ts_controller_recompute(TsController *c)
{
    char err[512];
    TsScheduleResult ns;
    TsStatusView nv;

    if (c == NULL || !c->has_plan) {
        return 1;
    }
    memset(&ns, 0, sizeof(ns));
    memset(&nv, 0, sizeof(nv));

    if (ts_plan_validate(&c->plan, c->cfg, err, sizeof(err)) != 0) {
        snprintf(c->plan_message, sizeof(c->plan_message), "校验失败：%s", err);
        if (c->has_sched) { ts_schedule_result_free(&c->sched); c->has_sched = 0; }
        if (c->has_status) { ts_status_view_free(&c->status); c->has_status = 0; }
        return 1;
    }
    if (ts_schedule_build(&c->plan, c->cfg, &ns, err, sizeof(err)) != 0) {
        snprintf(c->plan_message, sizeof(c->plan_message), "排序失败：%s", err);
        if (c->has_sched) { ts_schedule_result_free(&c->sched); c->has_sched = 0; }
        if (c->has_status) { ts_status_view_free(&c->status); c->has_status = 0; }
        return 1;
    }
    if (ts_schedule_status(&c->plan, &nv, err, sizeof(err)) != 0) {
        ts_schedule_result_free(&ns);
        snprintf(c->plan_message, sizeof(c->plan_message), "状态计算失败：%s", err);
        if (c->has_sched) { ts_schedule_result_free(&c->sched); c->has_sched = 0; }
        if (c->has_status) { ts_status_view_free(&c->status); c->has_status = 0; }
        return 1;
    }

    if (c->has_sched) ts_schedule_result_free(&c->sched);
    if (c->has_status) ts_status_view_free(&c->status);
    c->sched = ns;
    c->has_sched = 1;
    c->status = nv;
    c->has_status = 1;
    c->plan_message[0] = '\0';
    return 0;
}

int ts_controller_adopt_result(TsController *c, char *err, size_t err_sz)
{
    if (c == NULL || !c->has_result) {
        snprintf(err, err_sz, "没有可用的分析结果");
        return 1;
    }
    if (!c->result.ok) {
        snprintf(err, err_sz, "%s",
                 c->result.error != NULL ? c->result.error : "分析失败");
        return 1;
    }
    /* 双重保险：结果已投递到主线程、但用户在这期间点了取消时同样不采纳。 */
    if (ts_cancel_is_requested(&c->cancel) && ts_cancel_gen(&c->cancel) == c->current_gen) {
        snprintf(err, err_sz, "本次分析已取消，结果未采纳");
        return 1;
    }

    ts_plan_free(&c->plan);
    c->plan = c->result.plan;         /* 所有权移交 */
    ts_plan_init(&c->result.plan);
    c->has_plan = 1;

    if (ts_controller_recompute(c) != 0) {
        snprintf(err, err_sz, "%s", c->plan_message);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 本地编辑                                                            */
/* ------------------------------------------------------------------ */

static int check_index(TsController *c, size_t idx)
{
    return (c != NULL && c->has_plan && idx < c->plan.task_count) ? 1 : 0;
}

int ts_controller_edit_task(TsController *c, size_t task_index, const TsTaskEdit *edit)
{
    TsTask *t;
    char *name_copy = NULL;
    char *deadline_copy = NULL;

    if (!check_index(c, task_index) || edit == NULL) return 1;
    if (edit->name == NULL || edit->name[0] == '\0') return 1;
    if (edit->urgency < 1 || edit->urgency > 5) return 1;
    if (edit->impact < 1 || edit->impact > 5) return 1;
    if (edit->has_hours && !(edit->hours > 0.0)) return 1;

    name_copy = ts_strdup(edit->name);
    if (name_copy == NULL) return 1;
    if (edit->deadline != NULL && edit->deadline[0] != '\0') {
        deadline_copy = ts_strdup(edit->deadline);
        if (deadline_copy == NULL) {
            ts_free(name_copy);
            return 1;
        }
    }

    t = &c->plan.tasks[task_index];
    ts_free(t->name);
    t->name = name_copy;
    t->urgency = edit->urgency;
    t->impact = edit->impact;
    t->has_estimated_hours = edit->has_hours ? 1 : 0;
    t->estimated_hours = edit->has_hours ? edit->hours : 0.0;
    ts_free(t->deadline);
    t->deadline = deadline_copy;

    return ts_controller_recompute(c);
}

int ts_controller_set_name(TsController *c, size_t task_index, const char *name)
{
    char *copy;
    if (!check_index(c, task_index) || name == NULL || name[0] == '\0') return 1;
    copy = ts_strdup(name);
    if (copy == NULL) return 1;
    ts_free(c->plan.tasks[task_index].name);
    c->plan.tasks[task_index].name = copy;
    return ts_controller_recompute(c);
}

int ts_controller_set_urgency(TsController *c, size_t task_index, int urgency)
{
    if (!check_index(c, task_index)) return 1;
    c->plan.tasks[task_index].urgency = urgency;
    return ts_controller_recompute(c);
}

int ts_controller_set_impact(TsController *c, size_t task_index, int impact)
{
    if (!check_index(c, task_index)) return 1;
    c->plan.tasks[task_index].impact = impact;
    return ts_controller_recompute(c);
}

int ts_controller_set_hours(TsController *c, size_t task_index, int has_hours, double hours)
{
    if (!check_index(c, task_index)) return 1;
    c->plan.tasks[task_index].has_estimated_hours = has_hours ? 1 : 0;
    c->plan.tasks[task_index].estimated_hours = has_hours ? hours : 0.0;
    return ts_controller_recompute(c);
}

int ts_controller_set_deadline(TsController *c, size_t task_index, const char *deadline)
{
    char *copy = NULL;
    if (!check_index(c, task_index)) return 1;
    if (deadline != NULL && deadline[0] != '\0') {
        copy = ts_strdup(deadline);
        if (copy == NULL) return 1;
    }
    ts_free(c->plan.tasks[task_index].deadline);
    c->plan.tasks[task_index].deadline = copy;
    return ts_controller_recompute(c);
}

int ts_controller_set_actual(TsController *c, size_t task_index, int done)
{
    if (!check_index(c, task_index)) return 1;
    c->plan.tasks[task_index].actual_status = done ? TS_ACTUAL_DONE : TS_ACTUAL_TODO;
    return ts_controller_recompute(c);
}

int ts_controller_set_deps(TsController *c, size_t task_index,
                           const char *const *ids, size_t count)
{
    char **arr = NULL;
    size_t i;
    TsTask *t;

    if (!check_index(c, task_index)) return 1;

    if (count > 0) {
        arr = (char **)ts_calloc(count, sizeof(char *));
        if (arr == NULL) return 1;
        for (i = 0; i < count; i++) {
            arr[i] = ts_strdup(ids[i]);
            if (arr[i] == NULL) {
                size_t k;
                for (k = 0; k < i; k++) ts_free(arr[k]);
                ts_free(arr);
                return 1;
            }
        }
    }

    t = &c->plan.tasks[task_index];
    for (i = 0; i < t->depends_on_count; i++) ts_free(t->depends_on[i]);
    ts_free(t->depends_on);
    t->depends_on = arr;
    t->depends_on_count = count;
    return ts_controller_recompute(c);
}

int ts_controller_set_precond_status(TsController *c, size_t task_index,
                                     size_t precond_index, TsPrecondStatus status)
{
    if (!check_index(c, task_index)) return 1;
    if (precond_index >= c->plan.tasks[task_index].preconditions_count) return 1;
    c->plan.tasks[task_index].preconditions[precond_index].status = status;
    return ts_controller_recompute(c);
}

/* ------------------------------------------------------------------ */
/* 离线模拟                                                            */
/* ------------------------------------------------------------------ */

int ts_controller_load_mock(TsController *c, char *err, size_t err_sz)
{
    TsConfig mock;
    TsModelResult mr;
    TsPlan plan;
    int rc = 1;

    if (c == NULL || c->cfg == NULL) {
        snprintf(err, err_sz, "配置为空");
        return 1;
    }
    if (require_idle(c, err, err_sz)) return 1;

    mock = *c->cfg;      /* 浅拷贝：仅用于把 mock_mode 打开 */
    mock.mock_mode = 1;

    ts_model_result_init(&mr);
    if (ts_model_call(&mock, NULL, 0, NULL, 0, &mr) != 0) {
        snprintf(err, err_sz, "%s", mr.error != NULL ? mr.error : "模拟响应失败");
        ts_model_result_free(&mr);
        return 1;
    }
    ts_plan_init(&plan);
    if (ts_plan_parse(mr.body, mr.body_len, c->cfg, &plan, err, err_sz) != 0) {
        ts_plan_free(&plan);
        ts_model_result_free(&mr);
        return 1;
    }
    ts_model_result_free(&mr);

    ts_plan_free(&c->plan);
    c->plan = plan;
    c->has_plan = 1;

    if (ts_controller_recompute(c) != 0) {
        snprintf(err, err_sz, "%s", c->plan_message);
        return 1;
    }
    rc = 0;
    return rc;
}

