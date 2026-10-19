/*
 * ts_bridge.c — Dart FFI ABI 实现：调用方线程只做有界拷贝，模型调用与文件读取在工作线程完成，
 * 进度由 Dart 侧轮询取回，事件与结果由本文件统一拥有。
 *
 * 主要函数：ts_bridge_create_ex、ts_bridge_analyze_async / constraints_async / probe_async、
 * ts_bridge_poll / result / release_job、ts_bridge_settings_get / save、ts_bridge_destroy。
 */


#include "ts_bridge.h"

#include "ts_file_list.h"
#include "../domain/analysis/analyze.h"
#include "../domain/analysis/constraints.h"
#include "../platform/credential.h"
#include "../domain/present/display.h"
#include "../domain/export/export.h"
#include "../domain/export/export_user.h"
#include "../domain/input/input.h"
#include "../util/mem.h"
#include "../domain/analysis/model.h"
#include "../domain/plan/plan.h"
#include "../domain/plan/plan_local.h"
#include "../state/profile.h"
#include "../state/profile_store.h"
#include "../domain/analysis/prompt.h"
#include "../platform/runtime.h"
#include "../domain/schedule/scheduler.h"
#include "../platform/text.h"

#include <stdio.h>
#include <string.h>

#include "cJSON.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>

/* 请求体上限：有界拷贝，避免一次 FFI 调用拷贝几百 MB。 */
#define TS_BRIDGE_MAX_REQUEST_BYTES (16u * 1024u * 1024u)
/* 关闭时等待工作线程的上限；超时宁可泄漏也不释放仍在使用的内存。 */
#define TS_BRIDGE_SHUTDOWN_WAIT_MS  10000
/* 进度事件节流：同一阶段 150ms 内只记一条，避免事件队列膨胀。 */
#define TS_BRIDGE_PROGRESS_MIN_MS   150

typedef enum BridgeJobState {
    TS_JOB_RUNNING = 0,
    TS_JOB_OK = 1,
    TS_JOB_FAILED = 2,
    TS_JOB_CANCELLED = 3
} BridgeJobState;

typedef enum BridgeJobKind {
    TS_JOBKIND_ANALYZE = 0,
    TS_JOBKIND_PROBE = 1,
    TS_JOBKIND_CONSTRAINTS = 2
} BridgeJobKind;

typedef enum BridgeProbeKind {
    TS_PROBE_MODELS = 0,
    TS_PROBE_CHAT = 1
} BridgeProbeKind;

/*
 * 本次 job 的**最终请求目标**：
 *   分析 / chat 探针 → chatUrl（cfg.endpoint_url）；
 *   models 探针      → modelsUrl。
 * 凭据的授权范围必须按这个**实际请求 URL** 校验，而不是只看 chatUrl。
 */
typedef enum BridgeTargetKind {
    TS_TARGET_CHAT = 0,
    TS_TARGET_MODELS = 1
} BridgeTargetKind;

typedef enum BridgeEventType {
    TS_EVT_STARTED = 1,
    TS_EVT_PROGRESS = 2,
    TS_EVT_SUCCEEDED = 3,
    TS_EVT_FAILED = 4,
    TS_EVT_CANCELLED = 5
} BridgeEventType;

typedef struct BridgeEvent {
    int type;
    char *stage;
    char *detail;
    char *error;
    long elapsed_ms;
    uint64_t at_ms;
} BridgeEvent;

typedef struct BridgeJob {
    TsJobId id;
    int kind;                /* BridgeJobKind */
    int state;
    int probe_kind;          /* BridgeProbeKind；仅探针 */

    char *conversation_id;
    char *request_id;
    char *base_version_id;
    int base_revision;

    char *request_json;      /* owned 拷贝；工作线程读它 */
    size_t request_len;

    /*
     * job 自有的配置快照：工作线程只读。
     * 它是 ts_config_copy(bridge->cfg) + 应用 profile + 解析凭据的结果。
     */
    TsConfig cfg_snapshot;
    int snapshot_ready;

    TsAnalyzeResult result;  /* 分析：仅工作线程写、终态后其它线程读（受锁保护） */
    char *probe_result;      /* 探针：终态结果 JSON（owned） */

    /* 约束识别 job 的终态（仅 TS_JOBKIND_CONSTRAINTS 使用）。 */
    TsConstraintsResult constraints;
    int constraints_ready;

    BridgeEvent *events;
    size_t event_count;
    size_t event_cap;
    int seq;

    uint64_t started_ms;
    uint64_t finished_ms;
    uint64_t last_progress_ms;

    /* 每个 job 独立的取消状态：探针可并发，不能共用 bridge 级别的代号。 */
    TsCancel cancel;
    int cancel_ready;

    HANDLE thread;
    DWORD thread_id;
    int thread_started;
} BridgeJob;

struct TsBridge {
    CRITICAL_SECTION lock;
    int lock_ready;
    TsConfig cfg;            /* 基础配置（只读；启动 job 时被深拷贝成快照） */
    int cfg_ready;
    char *config_path;
    char *data_dir;
    char *settings_path;
    char *settings_warning;  /* settings.json 损坏/不兼容时的可读说明（owned，可空） */
    /*
     * credential_space：由 data_dir 规范化后派生的数据空间标识
     * （见 credential.h）。凭据目标名带上它，两个便携副本 / 不同数据目录
     * 中同名的 profile 就不会共用或互相覆盖凭据。对外 ABI 不变：Dart 仍只传 profileId。
     */
    char credential_space[TS_CREDENTIAL_SPACE_MAX];
    TsProfileList profiles;  /* 权威设置状态（受锁保护） */
    int profiles_ready;
    int shutting_down;

    TsJobId next_job;
    BridgeJob *analyze_job;                       /* 单活动分析槽 */
    BridgeJob *probe_jobs[TS_BRIDGE_MAX_PROBE_JOBS]; /* 最多 4 个并发探针 */
};

typedef struct WorkerArg {
    TsBridge *b;
    BridgeJob *job;
} WorkerArg;

/* ------------------------------------------------------------------ */
/* 缓冲区                                                              */
/* ------------------------------------------------------------------ */

static int buf_set_json(TsBridgeBuffer *out, cJSON *root)
{
    char *printed;
    if (out == NULL) {
        if (root != NULL) cJSON_Delete(root);
        return 1;
    }
    out->data = NULL;
    out->length = 0;
    if (root == NULL) return 1;
    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (printed == NULL) return 1;
    out->data = printed;
    out->length = strlen(printed);
    return 0;
}

/*
 * 错误 JSON：{ "ok":false, "errorKind":…, "error":…, <extra 的成员> }
 * extra 的所有权被接管（会被删除）。
 */
static int error_json_extra(TsBridgeBuffer *out, const char *code, const char *message,
                            cJSON *extra)
{
    cJSON *root = cJSON_CreateObject();
    if (root == NULL) {
        if (extra != NULL) cJSON_Delete(extra);
        return 1;
    }
    if (cJSON_AddBoolToObject(root, "ok", 0) == NULL ||
        cJSON_AddStringToObject(root, "errorKind",
            (code != NULL) ? code : "internal") == NULL ||
        cJSON_AddStringToObject(root, "error",
            (message != NULL) ? message : "未知错误") == NULL) {
        cJSON_Delete(root);
        if (extra != NULL) cJSON_Delete(extra);
        return 1;
    }
    if (extra != NULL) {
        cJSON *item = extra->child;
        while (item != NULL) {
            cJSON *next = item->next;
            item->next = NULL;
            item->prev = NULL;
            if (!cJSON_AddItemToObject(root, item->string, item)) {
                cJSON_Delete(item);
            }
            item = next;
        }
        extra->child = NULL;
        cJSON_Delete(extra);
    }
    return buf_set_json(out, root);
}

static int error_json(TsBridgeBuffer *out, const char *code, const char *message)
{
    return error_json_extra(out, code, message, NULL);
}
/*
 * 失败入口：填错误 JSON 并**返回非 0**。
 * 注意 error_json 的返回值是“缓冲区是否写成功”（0 = 写成功），
 * 直接 `return error_json(...)` 会被调用方当成“调用成功”，这是曾经踩过的坑。
 */
static int fail_json(TsBridgeBuffer *out, const char *code, const char *message)
{
    (void)error_json(out, code, message);
    return 1;
}

static int fail_json_extra(TsBridgeBuffer *out, const char *code, const char *message,
                           cJSON *extra)
{
    (void)error_json_extra(out, code, message, extra);
    return 1;
}

void ts_bridge_free(TsBridgeBuffer *buffer)
{
    if (buffer == NULL) return;
    ts_free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0;
}

/* ------------------------------------------------------------------ */
/* 事件队列                                                            */
/* ------------------------------------------------------------------ */

static void event_free(BridgeEvent *e)
{
    ts_free(e->stage);
    ts_free(e->detail);
    ts_free(e->error);
    memset(e, 0, sizeof(*e));
}

static void job_clear_events(BridgeJob *job)
{
    size_t i;
    for (i = 0; i < job->event_count; i++) event_free(&job->events[i]);
    ts_free(job->events);
    job->events = NULL;
    job->event_count = 0;
    job->event_cap = 0;
}

/* 调用方必须已持有锁。 */
static int job_push_event(BridgeJob *job, int type, const char *stage,
                          const char *detail, const char *error, long elapsed_ms)
{
    BridgeEvent *e;
    if (job->event_count == job->event_cap) {
        size_t ncap = job->event_cap ? job->event_cap * 2 : 8;
        size_t bytes;
        BridgeEvent *ne;
        if (ts_mul_overflow(ncap, sizeof(BridgeEvent), &bytes)) return 1;
        ne = (BridgeEvent *)ts_realloc(job->events, bytes);
        if (ne == NULL) return 1;
        job->events = ne;
        job->event_cap = ncap;
    }
    e = &job->events[job->event_count];
    memset(e, 0, sizeof(*e));
    e->type = type;
    e->elapsed_ms = elapsed_ms;
    e->at_ms = ts_clock_elapsed_ms(job->started_ms);
    if (stage != NULL && stage[0] != '\0') {
        e->stage = ts_strdup(stage);
        if (e->stage == NULL) return 1;
    }
    if (detail != NULL && detail[0] != '\0') {
        e->detail = ts_strdup(detail);
        if (e->detail == NULL) { event_free(e); return 1; }
    }
    if (error != NULL && error[0] != '\0') {
        e->error = ts_strdup(error);
        if (e->error == NULL) { event_free(e); return 1; }
    }
    job->event_count++;
    job->seq++;
    return 0;
}

/* ------------------------------------------------------------------ */
/* job 生命周期（调用方必须已持有锁）                                   */
/* ------------------------------------------------------------------ */

static void job_free(BridgeJob *job)
{
    if (job == NULL) return;
    if (job->snapshot_ready) {
        ts_config_free(&job->cfg_snapshot);   /* 含安全擦除的密钥 */
        job->snapshot_ready = 0;
    }
    ts_analyze_result_free(&job->result);
    ts_free(job->probe_result);
    if (job->constraints_ready) {
        ts_constraints_result_free(&job->constraints);
        job->constraints_ready = 0;
    }
    ts_free(job->request_json);
    ts_free(job->conversation_id);
    ts_free(job->request_id);
    ts_free(job->base_version_id);
    job_clear_events(job);
    if (job->cancel_ready) {
        job->cancel_ready = 0;
    }
    ts_free(job);
}

static BridgeJob *job_find_locked(TsBridge *b, TsJobId id)
{
    size_t i;
    if (b == NULL || id == 0) return NULL;
    if (b->analyze_job != NULL && b->analyze_job->id == id) return b->analyze_job;
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (b->probe_jobs[i] != NULL && b->probe_jobs[i]->id == id) return b->probe_jobs[i];
    }
    return NULL;
}

static size_t probe_slot_count_locked(TsBridge *b)
{
    size_t i;
    size_t n = 0;
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (b->probe_jobs[i] != NULL) n++;
    }
    return n;
}

static int probe_slot_add_locked(TsBridge *b, BridgeJob *job)
{
    size_t i;
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (b->probe_jobs[i] == NULL) {
            b->probe_jobs[i] = job;
            return 0;
        }
    }
    return 1;
}

static void job_detach_locked(TsBridge *b, BridgeJob *job)
{
    size_t i;
    if (job == NULL) return;
    if (b->analyze_job == job) {
        b->analyze_job = NULL;
        return;
    }
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (b->probe_jobs[i] == job) {
            b->probe_jobs[i] = NULL;
            return;
        }
    }
}

static void job_finish_locked(BridgeJob *job)
{
    const TsAnalyzeResult *r = &job->result;
    int cancelled = job->cancel_ready ? ts_cancel_is_requested(&job->cancel) : 0;

    if (job->kind == TS_JOBKIND_PROBE) {
        if (cancelled) {
            job->state = TS_JOB_CANCELLED;
            job_push_event(job, TS_EVT_CANCELLED, "已取消", NULL, NULL, 0);
        } else if (job->state == TS_JOB_RUNNING) {
            job->state = TS_JOB_FAILED;
            job_push_event(job, TS_EVT_FAILED, "失败", NULL, "探针未产生结果", 0);
        } else if (job->state == TS_JOB_OK) {
            job_push_event(job, TS_EVT_SUCCEEDED, "完成", NULL, NULL, 0);
        } else {
            job_push_event(job, TS_EVT_FAILED, "失败", NULL, NULL, 0);
        }
        job->finished_ms = ts_clock_ms();
        return;
    }

    if (job->kind == TS_JOBKIND_CONSTRAINTS) {
        /* 约束识别的终态同样由工作线程写好的 constraints 结果决定。 */
        const TsConstraintsResult *cr = &job->constraints;
        if (cr->ok && !cancelled) {
            job->state = TS_JOB_OK;
            job_push_event(job, TS_EVT_SUCCEEDED, "完成", NULL, NULL, cr->elapsed_ms);
        } else if (cancelled || cr->error_kind == TS_MODEL_ERR_CANCELLED) {
            job->state = TS_JOB_CANCELLED;
            job_push_event(job, TS_EVT_CANCELLED, "已取消",
                           (cr->error != NULL) ? cr->error : NULL, NULL, cr->elapsed_ms);
        } else {
            job->state = TS_JOB_FAILED;
            job_push_event(job, TS_EVT_FAILED, "失败", NULL,
                           (cr->error != NULL) ? cr->error : "识别失败", cr->elapsed_ms);
        }
        job->finished_ms = ts_clock_ms();
        return;
    }

    if (r->ok && !cancelled) {
        job->state = TS_JOB_OK;
        job_push_event(job, TS_EVT_SUCCEEDED, "完成", NULL, NULL, r->elapsed_ms);
    } else if (cancelled || r->error_kind == TS_MODEL_ERR_CANCELLED) {
        job->state = TS_JOB_CANCELLED;
        job_push_event(job, TS_EVT_CANCELLED, "已取消",
                       (r->error != NULL) ? r->error : NULL, NULL, r->elapsed_ms);
    } else {
        job->state = TS_JOB_FAILED;
        job_push_event(job, TS_EVT_FAILED, "失败", NULL,
                       (r->error != NULL) ? r->error : "分析失败", r->elapsed_ms);
    }
    job->finished_ms = ts_clock_ms();
}

/* 进度回调：在工作线程内被调用。 */
static void job_progress(void *userdata, const char *stage, const char *detail)
{
    WorkerArg *arg = (WorkerArg *)userdata;
    TsBridge *b;
    BridgeJob *job;
    uint64_t now;

    if (arg == NULL || arg->b == NULL || arg->job == NULL) return;
    b = arg->b;
    job = arg->job;

    EnterCriticalSection(&b->lock);
    if (job->state == TS_JOB_RUNNING) {
        now = ts_clock_ms();
        if (now - job->last_progress_ms >= TS_BRIDGE_PROGRESS_MIN_MS) {
            job->last_progress_ms = now;
            job_push_event(job, TS_EVT_PROGRESS, stage, detail, NULL,
                           (long)ts_clock_elapsed_ms(job->started_ms));
        }
    }
    LeaveCriticalSection(&b->lock);
}

/* ------------------------------------------------------------------ */
/* 凭据解析（主机校验）与配置快照                                       */
/* ------------------------------------------------------------------ */

/* 调用方必须已持有锁。err_kind 为静态字符串。 */
static int resolve_key_for_profile_locked(const TsProfile *p, const char *space,
                                          const char *target_url,
                                          TsConfig *cfg, const char **err_kind,
                                          char *err, size_t err_sz)
{
    char target_host[TS_PROFILE_HOST_MAX];
    char chat_origin[TS_PROFILE_HOST_MAX + 32];
    char target_origin[TS_PROFILE_HOST_MAX + 32];
    const char *target;
    char *key = NULL;
    char *stored_host = NULL;
    int migrated = 0;
    char cerr[512];
    const char *fmt_err;
    int rc;

    *err_kind = "config";

    if (p->auth_mode == NULL || strcmp(p->auth_mode, ts_auth_mode_none()) == 0) {
        /* 显式无需鉴权：不发送 Authorization，也不用去找凭据（允许跨源）。 */
        return 0;
    }

    /*
     * 最终目标 = 本次**实际请求**的 URL（分析/chat 探针 → chatUrl，
     * models 探针 → modelsUrl）。凭据只允许发往 chatUrl 的 origin。
     *
     * 这一步必须发生在任何凭据来源之前：
     *   - 旧 settings.json 里可能存着跨源的 modelsUrl（旧版本写入的），
     *     只在保存时校验是拦不住的；
     *   - 环境变量凭据同样受限；
     *   - scheme 从 https 降到 http 也算不同源（不得无提示降级）。
     * 判定失败时既不发送请求，也不使用环境变量，更不回退旧密钥。
     */
    target = (target_url != NULL && target_url[0] != '\0') ? target_url : p->chat_url;
    ts_url_normalized_origin(p->chat_url, chat_origin, sizeof(chat_origin));
    ts_url_normalized_origin(target, target_origin, sizeof(target_origin));
    if (chat_origin[0] == '\0' || target_origin[0] == '\0') {
        snprintf(err, err_sz,
                 "无法确认请求目标与对话地址是否同源（对话地址：%s；请求目标：%s）："
                 "为避免把凭据发到未确认的地址，已在请求前停止",
                 (p->chat_url != NULL) ? p->chat_url : "",
                 (target != NULL) ? target : "");
        return 1;
    }
    if (strcmp(chat_origin, target_origin) != 0) {
        snprintf(err, err_sz,
                 "请求目标与对话地址不同源（本次是 %s → %s）："
                 "为避免把凭据发到未确认的地址，已在请求前停止；需要跨源请新建独立连接",
                 chat_origin, target_origin);
        return 1;
    }

    ts_url_host(target, target_host, sizeof(target_host));

    cerr[0] = '\0';
    rc = ts_credential_load_scoped(space, p->id, &key, &stored_host,
                                   &migrated, cerr, sizeof(cerr));
    (void)migrated;
    if (rc == 0) {
        /*
         * 主机绑定校验：凭据保存时的主机与当前请求目标的主机不一致时，
         * **绝不**把旧密钥发到新地址去。
         */
        const char *old_host = (stored_host != NULL && stored_host[0] != '\0')
                                   ? stored_host
                                   : ((p->credential_host != NULL) ? p->credential_host : "");
        if (old_host[0] != '\0' && target_host[0] != '\0' &&
            strcmp(old_host, target_host) != 0) {
            snprintf(err, err_sz,
                     "连接地址已更换（旧 host：%s → 新 host：%s），"
                     "请重新确认认证方式并重新输入 API Key（不会把旧密钥发到新地址）",
                     old_host, target_host);
            ts_secure_free(&key);
            ts_free(stored_host);
            return 1;
        }
        fmt_err = ts_config_api_key_format_error(key);
        if (fmt_err != NULL) {
            snprintf(err, err_sz,
                     "已保存的 API Key 存在可疑格式——%s。请在“模型”页重新输入一次"
                     "（程序不会自动截断或改写密钥）", fmt_err);
            ts_secure_free(&key);
            ts_free(stored_host);
            return 1;
        }
        ts_secure_free(&cfg->api_key);
        cfg->api_key = key;    /* 所有权移交 */
        key = NULL;
        ts_free(stored_host);
        ts_free(cfg->credential_host);
        cfg->credential_host = ts_strdup(target_host);
        ts_free(cfg->auth_mode);
        cfg->auth_mode = ts_strdup(ts_auth_mode_bearer());
        return 0;
    }

    /*
     * 没有已存凭据：退回环境变量方式（兼容旧配置）。
     * 注意这里已经过了上面的同源校验，所以环境变量凭据也不会被发往
     * chatUrl 之外的 origin。
     */
    if (p->api_key_env != NULL && p->api_key_env[0] != '\0') {
        const char *val = getenv(p->api_key_env);
        if (val != NULL && val[0] != '\0') {
            fmt_err = ts_config_api_key_format_error(val);
            if (fmt_err != NULL) {
                snprintf(err, err_sz,
                         "环境变量 %s 的值存在可疑格式——%s。为避免把格式错误的凭证"
                         "发出去，已在请求前停止", p->api_key_env, fmt_err);
                return 1;
            }
            ts_secure_free(&cfg->api_key);
            cfg->api_key = ts_strdup(val);
            return (cfg->api_key != NULL) ? 0 : 1;
        }
        snprintf(err, err_sz,
                 "连接 %s 要求从环境变量 %s 读取 API Key，但当前进程取不到该变量"
                 "（设置后需要重新启动程序）。也可在“模型”页直接输入 API Key",
                 p->id, p->api_key_env);
        return 1;
    }

    snprintf(err, err_sz,
             "连接 %s 需要鉴权，但既没有已保存的 API Key，也没有配置环境变量。"
             "请在“模型”页输入 API Key —— 不会发送无鉴权的请求", p->id);
    return 1;
}

typedef struct SelectionOverride {
    const char *profile_id;
    int has_profile;
    int has_revision;
    long revision;
    const char *model_id;
    int has_thinking;
    TsThinking thinking;
    const char *effort;      /* 非空 = 覆盖 */
} SelectionOverride;

/*
 * 构造 job 自有的配置快照（调用方必须已持有锁）。
 *   base = bridge->cfg（深拷贝） → 应用 profile → 应用选择覆盖 → 解析凭据。
 *   target_kind 决定凭据按哪个**实际请求 URL** 校验授权范围
 *   （分析/chat 探针 = chatUrl，models 探针 = modelsUrl）。
 * 失败时清空 *out，并写 err_kind / err。
 */
static int build_job_config_locked(TsBridge *b, const SelectionOverride *sel,
                                   int target_kind, TsConfig *out,
                                   const char **err_kind,
                                   char *err, size_t err_sz)
{
    TsConfig base;
    const TsProfile *p = NULL;

    ts_config_init(out);
    *err_kind = "config";

    ts_config_init(&base);
    if (ts_config_copy(&base, &b->cfg) != 0) {
        *err_kind = "memory";
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    ts_config_free(out);
    *out = base;

    if (sel != NULL && sel->has_profile) {
        if (!sel->has_revision) {
            /* 未知版本：绝不用“最新配置”静默替代。 */
            *err_kind = "invalidRevision";
            snprintf(err, err_sz,
                     "模型选择缺少 profileRevision，无法确认版本；请刷新设置后重试");
            ts_config_free(out);
            ts_config_init(out);
            return 1;
        }
        p = ts_profile_list_find(&b->profiles, sel->profile_id);
        if (p == NULL) {
            *err_kind = "profileDeleted";
            snprintf(err, err_sz,
                     "模型连接 %s 不存在或已被删除；请在设置里重新选择模型",
                     sel->profile_id);
            ts_config_free(out);
            ts_config_init(out);
            return 1;
        }
        if (sel->has_revision && sel->revision != p->revision) {
            *err_kind = "conflict";
            snprintf(err, err_sz,
                     "模型连接 %s 的配置版本已变化（当前 revision=%ld，请求 revision=%ld）；"
                     "请刷新设置后重试", sel->profile_id, p->revision, sel->revision);
            ts_config_free(out);
            ts_config_init(out);
            return 1;
        }
    } else if (b->profiles.default_profile_id != NULL &&
               b->profiles.default_profile_id[0] != '\0') {
        /* 缺省 = 全局默认连接。 */
        p = ts_profile_list_find(&b->profiles, b->profiles.default_profile_id);
    }

    if (p != NULL) {
        if (ts_profile_apply_to_config(p, out) != 0) {
            *err_kind = "memory";
            snprintf(err, err_sz, "内存分配失败");
            ts_config_free(out);
            ts_config_init(out);
            return 1;
        }
        /*
         * 关键：profile 的 authMode 决定鉴权方式，因此必须**丢掉**基础配置里
         * 可能存在的旧内联密钥，再由凭据解析重新填。
         */
        ts_secure_free(&out->api_key);

        if (sel != NULL) {
            if (sel->has_revision) out->profile_revision = sel->revision;
            if (sel->model_id != NULL && sel->model_id[0] != '\0') {
                char *m = ts_strdup(sel->model_id);
                if (m == NULL) {
                    *err_kind = "memory";
                    ts_config_free(out);
                    ts_config_init(out);
                    return 1;
                }
                ts_free(out->model);
                out->model = m;
            }
            if (sel->has_thinking) {
                out->thinking = (int)sel->thinking;
            }
            if (sel->effort != NULL && sel->effort[0] != '\0') {
                char *e = ts_strdup(sel->effort);
                char *e2 = ts_strdup(sel->effort);
                if (e == NULL || e2 == NULL) {
                    ts_free(e);
                    ts_free(e2);
                    *err_kind = "memory";
                    ts_config_free(out);
                    ts_config_init(out);
                    return 1;
                }
                ts_free(out->thinking_effort);
                out->thinking_effort = e;
                ts_free(out->reasoning_effort);
                out->reasoning_effort = e2;
            } else if (out->thinking != (int)TS_THINKING_ENABLED) {
                /* 关闭/不支持思考时绝不残留 effort。 */
                ts_free(out->thinking_effort);
                out->thinking_effort = NULL;
                ts_free(out->reasoning_effort);
                out->reasoning_effort = NULL;
            }
        }

        if (resolve_key_for_profile_locked(
                p, b->credential_space,
                (target_kind == TS_TARGET_MODELS) ? out->models_url : out->endpoint_url,
                out, err_kind, err, err_sz) != 0) {
            char msg[1400];
            snprintf(msg, sizeof(msg), "%s", err);
            snprintf(err, err_sz, "%s", msg);
            ts_config_free(out);
            ts_config_init(out);
            return 1;
        }
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* 工作线程：分析                                                      */
/* ------------------------------------------------------------------ */

/* 解析 sources 数组，构建 TsInputs。只在工作线程调用（会读文件）。 */
static int build_inputs(const cJSON *root, const TsConfig *cfg, TsInputs *out,
                        char *err, size_t err_sz)
{
    const cJSON *sources = cJSON_GetObjectItemCaseSensitive(root, "sources");
    int n, i;

    ts_inputs_init(out);
    if (sources == NULL || cJSON_IsNull(sources)) return 0;
    if (!cJSON_IsArray(sources)) {
        snprintf(err, err_sz, "sources 必须是数组");
        return 1;
    }
    n = cJSON_GetArraySize(sources);
    for (i = 0; i < n; i++) {
        const cJSON *s = cJSON_GetArrayItem(sources, i);
        const cJSON *kind, *path, *text, *label;
        const char *ks;
        if (s == NULL || !cJSON_IsObject(s)) {
            snprintf(err, err_sz, "sources[%d] 必须是对象", i);
            return 1;
        }
        kind = cJSON_GetObjectItemCaseSensitive(s, "kind");
        ks = (kind != NULL && cJSON_IsString(kind)) ? cJSON_GetStringValue(kind) : "text";
        label = cJSON_GetObjectItemCaseSensitive(s, "label");
        if (strcmp(ks, "file") == 0) {
            path = cJSON_GetObjectItemCaseSensitive(s, "path");
            if (path == NULL || !cJSON_IsString(path)) {
                snprintf(err, err_sz, "sources[%d] 缺少 path", i);
                return 1;
            }
            if (ts_inputs_add_file(out, cJSON_GetStringValue(path),
                                   cfg->max_input_bytes, err, err_sz) != 0) {
                return 1;
            }
        } else {
            text = cJSON_GetObjectItemCaseSensitive(s, "text");
            if (text == NULL || !cJSON_IsString(text)) {
                snprintf(err, err_sz, "sources[%d] 缺少 text", i);
                return 1;
            }
            if (ts_inputs_add_text(out, cJSON_GetStringValue(text),
                                   (label != NULL && cJSON_IsString(label))
                                       ? cJSON_GetStringValue(label) : NULL,
                                   cfg->max_input_bytes, err, err_sz) != 0) {
                return 1;
            }
        }
    }
    return 0;
}

static DWORD WINAPI analyze_worker(LPVOID param)
{
    WorkerArg *arg = (WorkerArg *)param;
    TsBridge *b = arg->b;
    BridgeJob *job = arg->job;
    cJSON *root = NULL;
    TsInputs inputs;
    char errbuf[768];
    const cJSON *item;
    char *user_request = NULL;
    char *plan_context = NULL;
    int gen = 0;
    int have_inputs = 0;

    ts_inputs_init(&inputs);
    errbuf[0] = '\0';

    /* 请求 JSON 与代号都是 job 自有的，读它们不需要锁。 */
    root = cJSON_ParseWithLength(job->request_json, job->request_len);
    gen = ts_cancel_gen(&job->cancel);

    if (root == NULL) {
        EnterCriticalSection(&b->lock);
        job->result.error_kind = TS_MODEL_ERR_PROTOCOL;
        job->result.error = ts_strdup("请求 JSON 解析失败");
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
        ts_free(arg);
        return 0;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "userRequest");
    if (item != NULL && cJSON_IsString(item)) {
        user_request = ts_strdup(cJSON_GetStringValue(item));
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "planContext");
    if (item != NULL && cJSON_IsString(item)) {
        plan_context = ts_strdup(cJSON_GetStringValue(item));
    }

    if (build_inputs(root, &job->cfg_snapshot, &inputs, errbuf, sizeof(errbuf)) == 0) {
        have_inputs = 1;
    }

    if (!have_inputs) {
        EnterCriticalSection(&b->lock);
        job->result.error_kind = TS_MODEL_ERR_CONFIG;
        job->result.error = ts_strdup(errbuf[0] != '\0' ? errbuf : "输入构建失败");
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
    } else {
        TsAnalyzeResult local;
        ts_analyze_result_init(&local);
        /* 工作线程**只读** job->cfg_snapshot：保存/删除/切换模型都不影响它。 */
        (void)ts_analyze_run_ex(&job->cfg_snapshot, user_request, plan_context, &inputs,
                                &job->cancel, gen, job_progress, arg, &local);
        EnterCriticalSection(&b->lock);
        ts_analyze_result_free(&job->result);
        job->result = local;   /* 所有权移交 */
        memset(&local, 0, sizeof(local));
        ts_plan_init(&local.plan);
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
    }

    ts_inputs_free(&inputs);
    ts_free(user_request);
    ts_free(plan_context);
    cJSON_Delete(root);
    ts_free(arg);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 工作线程：日历约束识别                                              */
/* ------------------------------------------------------------------ */

/*
 * 约束识别与任务分析共用同一套配置快照、取消机制与进度回调，但结果走
 * constraints（proposals/notes）而不是 plan。这样“分析失败”与“识别失败”
 * 永远互不污染，界面也能分别重试。
 */
static DWORD WINAPI constraints_worker(LPVOID param)
{
    WorkerArg *arg = (WorkerArg *)param;
    TsBridge *b = arg->b;
    BridgeJob *job = arg->job;
    cJSON *root = NULL;
    TsInputs inputs;
    char errbuf[768];
    const cJSON *item;
    char *user_request = NULL;
    int gen = 0;
    int have_inputs = 0;

    ts_inputs_init(&inputs);
    errbuf[0] = '\0';

    root = cJSON_ParseWithLength(job->request_json, job->request_len);
    gen = ts_cancel_gen(&job->cancel);

    if (root == NULL) {
        EnterCriticalSection(&b->lock);
        job->constraints.error_kind = TS_MODEL_ERR_PROTOCOL;
        job->constraints.error = ts_strdup("请求 JSON 解析失败");
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
        ts_free(arg);
        return 0;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "userRequest");
    if (item != NULL && cJSON_IsString(item)) {
        user_request = ts_strdup(cJSON_GetStringValue(item));
    }

    if (build_inputs(root, &job->cfg_snapshot, &inputs, errbuf, sizeof(errbuf)) == 0) {
        have_inputs = 1;
    }

    if (!have_inputs) {
        EnterCriticalSection(&b->lock);
        job->constraints.error_kind = TS_MODEL_ERR_CONFIG;
        job->constraints.error =
            ts_strdup(errbuf[0] != '\0' ? errbuf : "输入构建失败");
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
    } else {
        TsConstraintsResult local;
        ts_constraints_result_init(&local);
        (void)ts_constraints_run(&job->cfg_snapshot, user_request, &inputs,
                                 &job->cancel, gen, job_progress, arg, &local);
        EnterCriticalSection(&b->lock);
        if (job->constraints_ready) {
            ts_constraints_result_free(&job->constraints);
        }
        job->constraints = local;   /* 所有权移交 */
        job->constraints_ready = 1;
        memset(&local, 0, sizeof(local));
        job_finish_locked(job);
        LeaveCriticalSection(&b->lock);
    }

    ts_inputs_free(&inputs);
    ts_free(user_request);
    cJSON_Delete(root);
    ts_free(arg);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 工作线程：探针                                                      */
/* ------------------------------------------------------------------ */

static const char *probe_kind_name(int kind)
{
    return (kind == TS_PROBE_CHAT) ? "chat" : "models";
}

/* 从模型列表响应里提取模型 id 数组。失败返回 NULL 并写 err。 */
static cJSON *parse_models_response(const char *body, size_t len,
                                    char *err, size_t err_sz)
{
    cJSON *root;
    cJSON *arr;
    const cJSON *list;
    int n;
    int i;

    root = cJSON_ParseWithLength(body, len);
    if (root == NULL) {
        snprintf(err, err_sz, "模型列表不是合法 JSON（服务端返回的内容无法解析）");
        return NULL;
    }

    list = NULL;
    if (cJSON_IsArray(root)) {
        list = root;
    } else {
        list = cJSON_GetObjectItemCaseSensitive(root, "data");
        if (list == NULL || !cJSON_IsArray(list)) {
            list = cJSON_GetObjectItemCaseSensitive(root, "models");
        }
    }
    if (list == NULL || !cJSON_IsArray(list)) {
        snprintf(err, err_sz, "模型列表 JSON 缺少 data/models 数组");
        cJSON_Delete(root);
        return NULL;
    }

    arr = cJSON_CreateArray();
    if (arr == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        cJSON_Delete(root);
        return NULL;
    }
    n = cJSON_GetArraySize(list);
    for (i = 0; i < n; i++) {
        const cJSON *item = cJSON_GetArrayItem(list, i);
        const char *id = NULL;
        if (item == NULL) continue;
        if (cJSON_IsString(item)) {
            id = cJSON_GetStringValue(item);
        } else if (cJSON_IsObject(item)) {
            const cJSON *idf = cJSON_GetObjectItemCaseSensitive(item, "id");
            if (idf != NULL && cJSON_IsString(idf)) id = cJSON_GetStringValue(idf);
        }
        if (id != NULL && id[0] != '\0') {
            cJSON_AddItemToArray(arr, cJSON_CreateString(id));
        }
    }
    cJSON_Delete(root);
    return arr;
}

static int content_is_json(const char *content)
{
    cJSON *root;
    if (content == NULL || content[0] == '\0') return 0;
    root = cJSON_Parse(content);
    if (root == NULL) return 0;
    cJSON_Delete(root);
    return 1;
}

static const char *model_kind_name_public(int kind);

static char *probe_result_build(int ok, int kind, long http_status, long elapsed_ms,
                                const char *err_kind, const char *error,
                                cJSON *extra)
{
    cJSON *root = cJSON_CreateObject();
    char *printed;
    if (root == NULL) {
        if (extra != NULL) cJSON_Delete(extra);
        return NULL;
    }
    cJSON_AddBoolToObject(root, "ok", ok ? 1 : 0);
    cJSON_AddNumberToObject(root, "httpStatus", (double)http_status);
    cJSON_AddNumberToObject(root, "elapsedMs", (double)elapsed_ms);
    cJSON_AddStringToObject(root, "jobType", "probe");
    cJSON_AddStringToObject(root, "kind", probe_kind_name(kind));
    if (!ok) {
        cJSON_AddStringToObject(root, "errorKind",
                                err_kind != NULL ? err_kind : "unknown");
        cJSON_AddStringToObject(root, "error", error != NULL ? error : "探针失败");
    }
    if (extra != NULL) {
        cJSON *item = extra->child;
        while (item != NULL) {
            cJSON *next = item->next;
            item->next = NULL;
            item->prev = NULL;
            if (!cJSON_AddItemToObject(root, item->string, item)) {
                cJSON_Delete(item);
            }
            item = next;
        }
        extra->child = NULL;
        cJSON_Delete(extra);
    }
    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return printed;
}

/* 构造探针 chat 请求体：固定、小型、不包含任何用户数据。 */
static int build_probe_chat_body(const TsConfig *cfg,
                                 char **out, size_t *out_len,
                                 char *err, size_t err_sz)
{
    cJSON *root;
    cJSON *messages;
    cJSON *m;
    char *printed;

    root = cJSON_CreateObject();
    messages = cJSON_CreateArray();
    if (root == NULL || messages == NULL) {
        if (root != NULL) cJSON_Delete(root);
        if (messages != NULL) cJSON_Delete(messages);
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    if (cJSON_AddStringToObject(root, "model",
                                cfg->model != NULL ? cfg->model : "") == NULL) {
        goto oom;
    }

    m = cJSON_CreateObject();
    if (m == NULL) goto oom;
    cJSON_AddStringToObject(m, "role", "system");
    cJSON_AddStringToObject(m, "content", "你是连通性测试助手，只输出 JSON。");
    if (!cJSON_AddItemToArray(messages, m)) { cJSON_Delete(m); goto oom; }

    m = cJSON_CreateObject();
    if (m == NULL) goto oom;
    cJSON_AddStringToObject(m, "role", "user");
    cJSON_AddStringToObject(m, "content", "{\"task\":\"connectivity\",\"probe\":true}");
    if (!cJSON_AddItemToArray(messages, m)) { cJSON_Delete(m); goto oom; }

    if (!cJSON_AddItemToObject(root, "messages", messages)) {
        cJSON_Delete(messages);
        messages = NULL;
        goto oom;
    }
    messages = NULL;

    cJSON_AddNumberToObject(root, "temperature", 0);
    cJSON_AddBoolToObject(root, "stream", 0);

    /* 与正式请求一致：按协议决定 thinking / reasoning_effort / response_format。 */
    if (cfg->protocol == (int)TS_PROTOCOL_DEEPSEEK_CHAT) {
        int enabled = (cfg->thinking == (int)TS_THINKING_ENABLED) ? 1 : 0;
        cJSON *thinking = cJSON_CreateObject();
        if (thinking == NULL) goto oom;
        if (cJSON_AddStringToObject(thinking, "type",
                                    enabled ? "enabled" : "disabled") == NULL) {
            cJSON_Delete(thinking);
            goto oom;
        }
        if (!cJSON_AddItemToObject(root, "thinking", thinking)) {
            cJSON_Delete(thinking);
            goto oom;
        }
        if (enabled) {
            cJSON_AddStringToObject(root, "reasoning_effort",
                                    ts_prompt_effective_effort(cfg));
        }
    } else if (cfg->protocol == (int)TS_PROTOCOL_OPENAI_CHAT) {
        /* 不发 thinking / reasoning_effort。 */
    } else if (cfg->reasoning_effort != NULL && cfg->reasoning_effort[0] != '\0') {
        cJSON_AddStringToObject(root, "reasoning_effort", cfg->reasoning_effort);
    }

    if (cfg->json_mode) {
        cJSON *rf = cJSON_CreateObject();
        if (rf == NULL) goto oom;
        if (cJSON_AddStringToObject(rf, "type", "json_object") == NULL) {
            cJSON_Delete(rf);
            goto oom;
        }
        if (!cJSON_AddItemToObject(root, "response_format", rf)) {
            cJSON_Delete(rf);
            goto oom;
        }
    }

    printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (printed == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    *out = printed;
    if (out_len != NULL) *out_len = strlen(printed);
    return 0;

oom:
    if (messages != NULL) cJSON_Delete(messages);
    if (root != NULL) cJSON_Delete(root);
    snprintf(err, err_sz, "构造探针请求失败（内存分配失败）");
    return 1;
}

static DWORD WINAPI probe_worker(LPVOID param)
{
    WorkerArg *arg = (WorkerArg *)param;
    TsBridge *b = arg->b;
    BridgeJob *job = arg->job;
    TsHttpRequest req;
    TsModelResult mr;
    char errbuf[768];
    char *body = NULL;
    size_t body_len = 0;
    cJSON *extra = NULL;
    char *result_json = NULL;
    int ok = 0;
    int gen = ts_cancel_gen(&job->cancel);
    const char *err_kind = "unknown";
    const char *err_msg = NULL;
    char local_err[768];
    int probe_kind = job->probe_kind;
    long connect_ms;

    local_err[0] = '\0';
    errbuf[0] = '\0';
    ts_model_result_init(&mr);

    /* 连接超时：min(cfg.connect_timeout_ms, 10000) —— 探针必须短。 */
    connect_ms = job->cfg_snapshot.connect_timeout_ms;
    if (connect_ms <= 0 || connect_ms > TS_PROBE_CONNECT_MAX_MS) {
        connect_ms = TS_PROBE_CONNECT_MAX_MS;
    }

    memset(&req, 0, sizeof(req));
    req.api_key = job->cfg_snapshot.api_key;
    req.ca_bundle_path = job->cfg_snapshot.ca_bundle_path;
    req.connect_timeout_ms = connect_ms;
    req.timeout_ms = (job->cfg_snapshot.probe_timeout_ms > 0)
                         ? job->cfg_snapshot.probe_timeout_ms
                         : TS_PROBE_TIMEOUT_DEFAULT_MS;

    if (probe_kind == TS_PROBE_MODELS) {
        if (job->cfg_snapshot.models_url == NULL ||
            job->cfg_snapshot.models_url[0] == '\0') {
            err_kind = "config";
            err_msg = "该连接没有配置模型列表地址（modelsUrl），无法获取模型列表";
            goto finish;
        }
        req.url = job->cfg_snapshot.models_url;
        req.method = "GET";
    } else {
        if (job->cfg_snapshot.endpoint_url == NULL ||
            job->cfg_snapshot.endpoint_url[0] == '\0') {
            err_kind = "config";
            err_msg = "该连接没有配置对话地址（chatUrl），无法测试模型响应";
            goto finish;
        }
        if (build_probe_chat_body(&job->cfg_snapshot, &body, &body_len,
                                  errbuf, sizeof(errbuf)) != 0) {
            err_kind = "config";
            err_msg = errbuf[0] != '\0' ? errbuf : "构造探针请求失败";
            goto finish;
        }
        req.url = job->cfg_snapshot.endpoint_url;
        req.method = "POST";
        req.body = body;
        req.body_len = body_len;
    }

    if (ts_model_http(&job->cfg_snapshot, &req, &job->cancel, gen, &mr) != 0) {
        err_kind = (mr.error_kind == TS_MODEL_ERR_CANCELLED) ? "cancelled"
                   : model_kind_name_public(mr.error_kind);
        err_msg = (mr.error != NULL) ? mr.error : "探针失败";
        goto finish;
    }

    if (probe_kind == TS_PROBE_MODELS) {
        cJSON *models = parse_models_response(mr.body, mr.body_len,
                                              local_err, sizeof(local_err));
        if (models == NULL) {
            err_kind = "protocol";
            err_msg = local_err[0] != '\0' ? local_err : "模型列表解析失败";
            goto finish;
        }
        extra = cJSON_CreateObject();
        if (extra == NULL) {
            cJSON_Delete(models);
            err_kind = "memory";
            err_msg = "内存分配失败";
            goto finish;
        }
        if (!cJSON_AddItemToObject(extra, "models", models)) {
            cJSON_Delete(models);
        }
    } else {
        char *content = NULL;
        size_t content_len = 0;
        int kind = TS_MODEL_ERR_PROTOCOL;
        TsTokenUsage usage;

        errbuf[0] = '\0';
        if (ts_model_extract_content_usage(mr.body, mr.body_len, &content, &content_len,
                                           &kind, errbuf, sizeof(errbuf), &usage) != 0) {
            err_kind = model_kind_name_public(kind);
            err_msg = errbuf[0] != '\0' ? errbuf : "模型响应无法解析";
            ts_free(content);
            goto finish;
        }
        extra = cJSON_CreateObject();
        if (extra == NULL) {
            ts_free(content);
            err_kind = "memory";
            err_msg = "内存分配失败";
            goto finish;
        }
        cJSON_AddStringToObject(extra, "model",
                                job->cfg_snapshot.model != NULL
                                    ? job->cfg_snapshot.model : "");
        cJSON_AddBoolToObject(extra, "contentIsJson", content_is_json(content) ? 1 : 0);
        {
            cJSON *u = cJSON_CreateObject();
            if (u != NULL) {
                cJSON_AddBoolToObject(u, "present", usage.present ? 1 : 0);
                cJSON_AddNumberToObject(u, "promptTokens", (double)usage.prompt_tokens);
                cJSON_AddNumberToObject(u, "completionTokens",
                                        (double)usage.completion_tokens);
                cJSON_AddNumberToObject(u, "reasoningTokens",
                                        (double)usage.reasoning_tokens);
                cJSON_AddNumberToObject(u, "totalTokens", (double)usage.total_tokens);
                cJSON_AddItemToObject(extra, "usage", u);
            }
        }
        ts_free(content);
    }
    ok = 1;

finish:
    result_json = probe_result_build(ok, probe_kind, mr.http_status, mr.elapsed_ms,
                                     err_kind, err_msg, extra);
    ts_model_result_free(&mr);
    ts_free(body);

    EnterCriticalSection(&b->lock);
    if (ok && result_json != NULL) {
        job->state = TS_JOB_OK;
    } else {
        job->state = (err_kind != NULL && strcmp(err_kind, "cancelled") == 0)
                         ? TS_JOB_CANCELLED : TS_JOB_FAILED;
    }
    ts_free(job->probe_result);
    job->probe_result = result_json;
    job_finish_locked(job);
    LeaveCriticalSection(&b->lock);

    ts_free(arg);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 创建 / 信息                                                         */
/* ------------------------------------------------------------------ */

static const char *error_kind_name_public(int kind)
{
    switch (kind) {
        case TS_MODEL_OK:               return "ok";
        case TS_MODEL_ERR_CANCELLED:    return "cancelled";
        case TS_MODEL_ERR_AUTH:         return "auth";
        case TS_MODEL_ERR_CONFIG:       return "config";
        case TS_MODEL_ERR_RATE_LIMIT:   return "rateLimit";
        case TS_MODEL_ERR_SERVER:       return "server";
        case TS_MODEL_ERR_NETWORK:      return "network";
        case TS_MODEL_ERR_TLS:          return "tls";
        case TS_MODEL_ERR_TOO_LARGE:    return "tooLarge";
        case TS_MODEL_ERR_EMPTY:        return "empty";
        case TS_MODEL_ERR_TRUNCATED:    return "truncated";
        case TS_MODEL_ERR_PROTOCOL:     return "protocol";
        case TS_MODEL_ERR_MEMORY:       return "memory";
        default:                        return "unknown";
    }
}

static const char *model_kind_name_public(int kind)
{
    return error_kind_name_public(kind);
}

/* 取目录部分；没有反斜杠/斜杠时返回 "."。 */
static char *dir_of(const char *path)
{
    const char *p;
    if (path == NULL || path[0] == '\0') return ts_strdup(".");
    p = path + strlen(path);
    while (p > path && *p != '\\' && *p != '/') p--;
    if (p == path) return ts_strdup(".");
    return ts_strndup(path, (size_t)(p - path));
}

static int ensure_dir_exists(const char *dir)
{
    wchar_t *w;
    DWORD attr;
    if (dir == NULL || dir[0] == '\0') return 1;
    w = ts_utf8_to_wide(dir, strlen(dir), NULL);
    if (w == NULL) return 1;
    attr = GetFileAttributesW(w);
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY) == 0) {
        CreateDirectoryW(w, NULL);
    }
    ts_free(w);
    return 1;
}

static void bridge_lock_init(TsBridge *b)
{
    InitializeCriticalSection(&b->lock);
    b->lock_ready = 1;
}

int ts_bridge_create_ex(const char *config_path_utf8,
                        const char *data_dir_utf8,
                        TsBridge **out_bridge,
                        TsBridgeBuffer *out_error)
{
    TsBridge *b;
    char errbuf[768];
    char *derived_dir = NULL;
    int loaded_from_disk = 0;
    char warning[512];

    if (out_error != NULL) {
        out_error->data = NULL;
        out_error->length = 0;
    }
    if (out_bridge == NULL) return 1;
    *out_bridge = NULL;

    b = (TsBridge *)ts_calloc(1, sizeof(TsBridge));
    if (b == NULL) {
        error_json(out_error, "memory", "内存分配失败");
        return 1;
    }
    ts_config_init(&b->cfg);
    b->cfg_ready = 1;
    ts_profile_list_init(&b->profiles);
    b->profiles_ready = 1;

    bridge_lock_init(b);

    errbuf[0] = '\0';
    if (config_path_utf8 != NULL && config_path_utf8[0] != '\0') {
        if (ts_config_load(config_path_utf8, &b->cfg, errbuf, sizeof(errbuf)) != 0) {
            error_json(out_error, "config", errbuf[0] != '\0' ? errbuf : "配置加载失败");
            goto failed;
        }
        b->config_path = ts_strdup(config_path_utf8);
        if (b->config_path == NULL) {
            error_json(out_error, "memory", "内存分配失败");
            goto failed;
        }
    } else {
        /* 未提供路径：保持默认配置（仅 mock 模式可用） */
        b->cfg.mock_mode = 1;
    }

    /*
     * data_dir 决定 settings.json 的位置：
     *   显式传入 → 用它；否则 = 配置文件所在目录；再退化 = 当前目录。
     */
    if (data_dir_utf8 != NULL && data_dir_utf8[0] != '\0') {
        b->data_dir = ts_strdup(data_dir_utf8);
    } else {
        derived_dir = dir_of(b->config_path);
        b->data_dir = derived_dir;
        derived_dir = NULL;
    }
    if (b->data_dir == NULL) {
        error_json(out_error, "memory", "内存分配失败");
        goto failed;
    }
    ensure_dir_exists(b->data_dir);

    /*
     * 数据空间：由 data_dir 规范化后派生，用于凭据目标名隔离。
     * 两个便携副本 / 不同数据目录里同名的 profile 因此不会共用密钥。
     * 对外 API 不变（Dart 仍只传 profileId）。
     */
    ts_credential_space_id(b->data_dir, b->credential_space,
                           sizeof(b->credential_space));

    {
        char path[2048];
        if (ts_settings_path(b->data_dir, 0, path, sizeof(path)) == 0) {
            b->settings_path = ts_strdup(path);
        } else {
            b->settings_path = ts_strdup("");
        }
        if (b->settings_path == NULL) {
            error_json(out_error, "memory", "内存分配失败");
            goto failed;
        }
    }

    /* 加载设置（损坏时保留原文件、用空列表 + warning，不阻断启动）。 */
    warning[0] = '\0';
    if (ts_settings_load(b->data_dir, &b->profiles, &loaded_from_disk,
                         warning, sizeof(warning), errbuf, sizeof(errbuf)) != TS_SETTINGS_OK) {
        warning[0] = '\0';
        /* 连路径都无法构造等硬错误：仍允许以“无设置”的方式启动。 */
        ts_profile_list_free(&b->profiles);
        ts_profile_list_init(&b->profiles);
    }
    if (warning[0] != '\0') {
        b->settings_warning = ts_strdup(warning);
    }

    /*
     * 旧 config.json 迁移：只在“还没有 settings.json”时做一次。
     * 迁移会新建一个 legacy profile；内联 api_key 一次性导入凭据管理器；
     * 旧文件**不删除、不修改**。迁移结果立即落盘，保证“仅此一次”。
     */
    if (!loaded_from_disk && b->cfg.endpoint_url != NULL && b->cfg.endpoint_url[0] != '\0' &&
        b->cfg.model != NULL && b->cfg.model[0] != '\0') {
        char mnote[768];
        mnote[0] = '\0';
        if (ts_settings_migrate_legacy(&b->profiles, &b->cfg,
                                       mnote, sizeof(mnote)) == TS_SETTINGS_OK) {
            char werr[512];
            werr[0] = '\0';
            (void)ts_settings_write_atomic(b->data_dir, &b->profiles,
                                           werr, sizeof(werr));
        }
    }

    *out_bridge = b;
    return 0;

failed:
    ts_free(derived_dir);
    if (b->profiles_ready) ts_profile_list_free(&b->profiles);
    if (b->cfg_ready) ts_config_free(&b->cfg);
    ts_free(b->config_path);
    ts_free(b->data_dir);
    ts_free(b->settings_path);
    ts_free(b->settings_warning);
    if (b->lock_ready) DeleteCriticalSection(&b->lock);
    ts_free(b);
    return 1;
}

int ts_bridge_create(const char *config_path_utf8,
                     TsBridge **out_bridge,
                     TsBridgeBuffer *out_error)
{
    /* data_dir = NULL：create_ex 会退化为“配置文件所在目录”（无配置时 = 当前目录）。 */
    return ts_bridge_create_ex(config_path_utf8, NULL, out_bridge, out_error);
}

int ts_bridge_info(TsBridge *bridge, TsBridgeBuffer *out_info)
{
    cJSON *root;
    char endpoint[512];
    if (bridge == NULL) return 1;
    if (out_info != NULL) { out_info->data = NULL; out_info->length = 0; }

    ts_model_sanitize_endpoint(bridge->cfg.endpoint_url, endpoint, sizeof(endpoint));
    root = cJSON_CreateObject();
    if (root == NULL) return 1;
    if (cJSON_AddNumberToObject(root, "abiVersion", (double)TS_BRIDGE_ABI_VERSION) == NULL ||
        cJSON_AddStringToObject(root, "model",
            bridge->cfg.model != NULL ? bridge->cfg.model : "") == NULL ||
        cJSON_AddStringToObject(root, "endpoint", endpoint) == NULL ||
        cJSON_AddStringToObject(root, "configPath",
            bridge->config_path != NULL ? bridge->config_path : "") == NULL ||
        cJSON_AddStringToObject(root, "dataDir",
            bridge->data_dir != NULL ? bridge->data_dir : "") == NULL ||
        cJSON_AddStringToObject(root, "settingsPath",
            bridge->settings_path != NULL ? bridge->settings_path : "") == NULL ||
        cJSON_AddBoolToObject(root, "mockMode", bridge->cfg.mock_mode ? 1 : 0) == NULL ||
        cJSON_AddBoolToObject(root, "hasApiKey",
            (bridge->cfg.api_key != NULL && bridge->cfg.api_key[0] != '\0') ? 1 : 0) == NULL ||
        cJSON_AddBoolToObject(root, "requiresAuth",
            ts_config_requires_auth(&bridge->cfg) ? 1 : 0) == NULL ||
        cJSON_AddNumberToObject(root, "waitPromptMs",
            (double)bridge->cfg.wait_prompt_ms) == NULL ||
        cJSON_AddNumberToObject(root, "maxInputBytes",
            (double)bridge->cfg.max_input_bytes) == NULL ||
        cJSON_AddBoolToObject(root, "httpAvailable",
            ts_model_available() ? 1 : 0) == NULL) {
        cJSON_Delete(root);
        return 1;
    }
    /* 设置摘要：只给数量与默认 id，不含密钥。 */
    EnterCriticalSection(&bridge->lock);
    cJSON_AddNumberToObject(root, "profileCount",
                            (double)bridge->profiles.count);
    cJSON_AddStringToObject(root, "defaultProfileId",
        bridge->profiles.default_profile_id != NULL
            ? bridge->profiles.default_profile_id : "");
    LeaveCriticalSection(&bridge->lock);
    return buf_set_json(out_info, root);
}

/* ------------------------------------------------------------------ */
/* 设置                                                                */
/* ------------------------------------------------------------------ */

/* 调用方必须已持有锁。返回带 ok/abiVersion/settingsPath 的完整设置对象。 */
static cJSON *settings_root_locked(TsBridge *b)
{
    cJSON *root = ts_profile_list_to_json(&b->profiles);
    if (root == NULL) return NULL;
    if (cJSON_AddBoolToObject(root, "ok", 1) == NULL ||
        cJSON_AddNumberToObject(root, "abiVersion",
                                (double)TS_BRIDGE_ABI_VERSION) == NULL ||
        cJSON_AddStringToObject(root, "settingsPath",
            b->settings_path != NULL ? b->settings_path : "") == NULL ||
        cJSON_AddStringToObject(root, "migrationNote",
            b->profiles.migration_note != NULL ? b->profiles.migration_note : "") == NULL ||
        cJSON_AddStringToObject(root, "warning",
            b->settings_warning != NULL ? b->settings_warning : "") == NULL) {
        cJSON_Delete(root);
        return NULL;
    }
    return root;
}

int ts_bridge_settings_get(TsBridge *bridge, TsBridgeBuffer *out_json)
{
    cJSON *root;
    if (out_json != NULL) { out_json->data = NULL; out_json->length = 0; }
    if (bridge == NULL) return 1;

    EnterCriticalSection(&bridge->lock);
    root = settings_root_locked(bridge);
    LeaveCriticalSection(&bridge->lock);

    if (root == NULL) {
        return fail_json(out_json, "memory", "内存分配失败");
    }
    return buf_set_json(out_json, root);
}

int ts_bridge_settings_save(TsBridge *bridge,
                            const char *settings_json, size_t length,
                            TsBridgeBuffer *out_json_or_error)
{
    TsSettingsRequest req;
    TsProfileList merged;
    char errbuf[1024];
    char conflict_id[TS_PROFILE_ID_MAX + 2];
    const char *err_kind = "invalidRequest";
    int rc;

    if (out_json_or_error != NULL) { out_json_or_error->data = NULL; out_json_or_error->length = 0; }
    if (bridge == NULL) return 1;
    if (settings_json == NULL || length == 0 || length > TS_BRIDGE_MAX_REQUEST_BYTES) {
        return fail_json(out_json_or_error, "requestInvalid",
                          "设置 JSON 为空或超过 16MB 上限");
    }

    ts_settings_request_init(&req);
    errbuf[0] = '\0';
    conflict_id[0] = '\0';
    if (ts_settings_request_parse(settings_json, length, &req,
                                  errbuf, sizeof(errbuf)) != TS_SETTINGS_OK) {
        ts_settings_request_free(&req);
        return fail_json(out_json_or_error, "invalidRequest",
                          errbuf[0] != '\0' ? errbuf : "设置请求无法解析");
    }

    ts_profile_list_init(&merged);
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        ts_settings_request_free(&req);
        return fail_json(out_json_or_error, "shuttingDown", "正在关闭，不能保存设置");
    }

    rc = ts_settings_merge(&bridge->profiles, &req, &merged,
                           conflict_id, sizeof(conflict_id),
                           errbuf, sizeof(errbuf), &err_kind);
    if (rc == TS_SETTINGS_CONFLICT) {
        cJSON *cur = ts_profile_list_to_json(&bridge->profiles);
        cJSON *extra = cJSON_CreateObject();
        LeaveCriticalSection(&bridge->lock);
        ts_settings_request_free(&req);
        ts_profile_list_free(&merged);
        if (extra != NULL && cur != NULL) {
            if (!cJSON_AddItemToObject(extra, "current", cur)) {
                cJSON_Delete(cur);
            }
            cur = NULL;
        } else {
            if (cur != NULL) cJSON_Delete(cur);
        }
        if (extra != NULL) {
            cJSON_AddStringToObject(extra, "conflictProfileId", conflict_id);
        }
        return fail_json_extra(out_json_or_error, "conflict",
                                errbuf[0] != '\0'
                                    ? errbuf
                                    : "模型配置已被修改，请刷新后重试", extra);
    }
    if (rc != TS_SETTINGS_OK) {
        LeaveCriticalSection(&bridge->lock);
        ts_settings_request_free(&req);
        ts_profile_list_free(&merged);
        return fail_json(out_json_or_error,
                          (err_kind != NULL) ? err_kind : "validation",
                          errbuf[0] != '\0' ? errbuf : "设置校验失败");
    }

    /* 原子写盘：失败时**不**替换内存态（内存与磁盘保持一致）。 */
    {
        char werr[1024];
        werr[0] = '\0';
        if (ts_settings_write_atomic(bridge->data_dir, &merged,
                                     werr, sizeof(werr)) != TS_SETTINGS_OK) {
            LeaveCriticalSection(&bridge->lock);
            ts_settings_request_free(&req);
            ts_profile_list_free(&merged);
            return fail_json(out_json_or_error, "writeFailed",
                              werr[0] != '\0' ? werr : "无法写入 settings.json");
        }
    }

    /* 保存成功后内存列表整体替换；运行中的 job 用各自快照，不受影响。 */
    ts_profile_list_free(&bridge->profiles);
    bridge->profiles = merged;   /* 所有权移交 */
    ts_profile_list_init(&merged);
    {
        cJSON *root = settings_root_locked(bridge);
        LeaveCriticalSection(&bridge->lock);
        ts_settings_request_free(&req);
        ts_profile_list_free(&merged);
        if (root == NULL) {
            return fail_json(out_json_or_error, "memory", "内存分配失败");
        }
        return buf_set_json(out_json_or_error, root);
    }
}

/* ------------------------------------------------------------------ */
/* 凭据                                                                */
/* ------------------------------------------------------------------ */

/* 把凭据元信息写回设置文件；失败时把内存改动回滚。调用方必须已持有锁。 */
static int persist_credential_state_locked(TsBridge *b, char *err, size_t err_sz)
{
    if (ts_settings_write_atomic(b->data_dir, &b->profiles, err, err_sz) != TS_SETTINGS_OK) {
        return 1;
    }
    return 0;
}

/*
 * “凭据已生效，但元数据落盘失败”的结构化错误。
 *
 * 纯文本错误会让 Dart 无法区分“完全失败”（凭据没写入）和
 * “凭据已生效、只是 settings.json 没写成”——后者重试保存即可修复，
 * 不应该让用户以为密钥丢了而重新输入。字段：
 *   errorKind         = "writeFailed"
 *   partial           = true
 *   credentialConfigured = 凭据当前是否已配置（set → true / delete → false）
 *   credentialHost    = 凭据绑定的主机（**不含密钥**）
 */
static int partial_credential_fail(TsBridgeBuffer *out, const char *message,
                                   int configured, const char *host)
{
    cJSON *extra = cJSON_CreateObject();
    if (extra == NULL) {
        return fail_json(out, "writeFailed", message);
    }
    cJSON_AddBoolToObject(extra, "partial", 1);
    cJSON_AddBoolToObject(extra, "credentialConfigured", configured ? 1 : 0);
    cJSON_AddStringToObject(extra, "credentialHost",
                            (host != NULL) ? host : "");
    return fail_json_extra(out, "writeFailed", message, extra);
}

int ts_bridge_credential_set(TsBridge *bridge, const char *profile_id,
                             const char *key_utf8, size_t key_len,
                             TsBridgeBuffer *out_error)
{
    TsProfile *p;
    char host[TS_PROFILE_HOST_MAX];
    char errbuf[768];
    int old_configured;
    char *old_host = NULL;
    const char *fmt_err;

    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (bridge == NULL) return 1;
    if (profile_id == NULL || profile_id[0] == '\0') {
        return fail_json(out_error, "invalidArgument", "profile id 为空");
    }
    if (key_utf8 == NULL || key_len == 0) {
        return fail_json(out_error, "invalidArgument", "API Key 为空");
    }
    fmt_err = ts_config_api_key_format_error(key_utf8);
    if (fmt_err != NULL) {
        char msg[512];
        snprintf(msg, sizeof(msg),
                 "API Key 存在可疑格式——%s。请重新粘贴（不要带上引号或多余空白）", fmt_err);
        return fail_json(out_error, "invalidArgument", msg);
    }

    errbuf[0] = '\0';
    host[0] = '\0';
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "shuttingDown", "正在关闭，不能保存密钥");
    }
    p = ts_profile_list_find_mut(&bridge->profiles, profile_id);
    if (p == NULL) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "profileNotFound", "该模型连接不存在或已被删除");
    }
    ts_url_host(p->chat_url, host, sizeof(host));
    if (ts_credential_set_scoped(bridge->credential_space, p->id, host,
                                 key_utf8, key_len,
                                 errbuf, sizeof(errbuf)) != 0) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "credentialWriteFailed",
                          errbuf[0] != '\0' ? errbuf : "无法写入 Windows 凭据管理器");
    }

    old_configured = p->credential_configured;
    old_host = p->credential_host;
    p->credential_configured = 1;
    p->credential_host = ts_strdup(host);
    if (p->credential_host == NULL) {
        p->credential_configured = old_configured;
        p->credential_host = old_host;
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    ts_free(old_host);

    errbuf[0] = '\0';
    if (persist_credential_state_locked(bridge, errbuf, sizeof(errbuf)) != 0) {
        /*
         * 凭据**已经**写进凭据管理器并已在内存生效（不回滚），
         * 只有 settings.json 没写成：用结构化错误告诉 Dart “部分成功”。
         */
        char msg[1200];
        snprintf(msg, sizeof(msg),
                 "凭据已生效，但 settings.json 写入失败，请重新保存设置"
                 "（无需重新输入 API Key；原因：%s）",
                 errbuf[0] != '\0' ? errbuf : "无法写入 settings.json");
        LeaveCriticalSection(&bridge->lock);
        return partial_credential_fail(out_error, msg, 1, host);
    }
    LeaveCriticalSection(&bridge->lock);

    {
        cJSON *root = cJSON_CreateObject();
        if (root == NULL) return 1;
        cJSON_AddBoolToObject(root, "ok", 1);
        return buf_set_json(out_error, root);
    }
}

int ts_bridge_credential_delete(TsBridge *bridge, const char *profile_id,
                                TsBridgeBuffer *out_error)
{
    TsProfile *p;
    char errbuf[768];
    char host[TS_PROFILE_HOST_MAX];

    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (bridge == NULL) return 1;
    if (profile_id == NULL || profile_id[0] == '\0') {
        return fail_json(out_error, "invalidArgument", "profile id 为空");
    }

    errbuf[0] = '\0';
    host[0] = '\0';
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "shuttingDown", "正在关闭，不能删除密钥");
    }
    p = ts_profile_list_find_mut(&bridge->profiles, profile_id);
    if (p == NULL) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "profileNotFound", "该模型连接不存在或已被删除");
    }
    ts_url_host(p->chat_url, host, sizeof(host));
    if (ts_credential_delete_scoped(bridge->credential_space, p->id,
                                    errbuf, sizeof(errbuf)) != 0) {
        LeaveCriticalSection(&bridge->lock);
        return fail_json(out_error, "credentialDeleteFailed",
                          errbuf[0] != '\0' ? errbuf : "无法删除 Windows 凭据");
    }
    p->credential_configured = 0;
    ts_free(p->credential_host);
    p->credential_host = NULL;

    errbuf[0] = '\0';
    if (persist_credential_state_locked(bridge, errbuf, sizeof(errbuf)) != 0) {
        char msg[1200];
        snprintf(msg, sizeof(msg),
                 "凭据已删除，但 settings.json 写入失败，请重新保存设置"
                 "（原因：%s）",
                 errbuf[0] != '\0' ? errbuf : "无法写入 settings.json");
        LeaveCriticalSection(&bridge->lock);
        return partial_credential_fail(out_error, msg, 0, host);
    }
    LeaveCriticalSection(&bridge->lock);

    {
        cJSON *root = cJSON_CreateObject();
        if (root == NULL) return 1;
        cJSON_AddBoolToObject(root, "ok", 1);
        return buf_set_json(out_error, root);
    }
}

/* ------------------------------------------------------------------ */
/* 分析 / 探针启动                                                     */
/* ------------------------------------------------------------------ */

/* 解析 modelSelection 对象为覆盖项。成功 0；失败非 0（写 err）。 */
static int parse_selection(const cJSON *sel, SelectionOverride *out,
                           char *err, size_t err_sz)
{
    const cJSON *item;
    const char *s;
    int has_revision = 0;
    long revision = 0;

    memset(out, 0, sizeof(*out));
    if (sel == NULL || !cJSON_IsObject(sel)) {
        snprintf(err, err_sz, "modelSelection 必须是对象");
        return 1;
    }
    item = cJSON_GetObjectItemCaseSensitive(sel, "profileId");
    if (item == NULL || !cJSON_IsString(item) ||
        cJSON_GetStringValue(item)[0] == '\0') {
        snprintf(err, err_sz, "modelSelection 缺少 profileId");
        return 1;
    }
    out->profile_id = cJSON_GetStringValue(item);
    out->has_profile = 1;

    item = cJSON_GetObjectItemCaseSensitive(sel, "profileRevision");
    if (item != NULL) {
        if (!cJSON_IsNumber(item)) {
            snprintf(err, err_sz, "modelSelection.profileRevision 必须是数字");
            return 1;
        }
        has_revision = 1;
        revision = (long)item->valuedouble;
    }
    out->has_revision = has_revision;
    out->revision = revision;

    item = cJSON_GetObjectItemCaseSensitive(sel, "modelId");
    if (item != NULL && cJSON_IsString(item)) {
        out->model_id = cJSON_GetStringValue(item);
    }

    s = NULL;
    item = cJSON_GetObjectItemCaseSensitive(sel, "thinking");
    if (item != NULL && cJSON_IsString(item)) {
        TsThinking t = TS_THINKING_UNSUPPORTED;
        s = cJSON_GetStringValue(item);
        if (ts_thinking_parse(s, &t) == 0) {
            out->has_thinking = 1;
            out->thinking = t;
        } else {
            snprintf(err, err_sz, "modelSelection.thinking 无法识别：%s", s);
            return 1;
        }
    }

    item = cJSON_GetObjectItemCaseSensitive(sel, "reasoningEffort");
    if (item != NULL && cJSON_IsString(item)) {
        s = cJSON_GetStringValue(item);
        if (s != NULL && s[0] != '\0') out->effort = s;
    }
    return 0;
}

int ts_bridge_analyze_async(TsBridge *bridge,
                            const char *request_json, size_t length,
                            TsJobId *out_job,
                            TsBridgeBuffer *out_error)
{
    cJSON *root;
    const cJSON *item;
    BridgeJob *job;
    TsJobId id;
    TsConfig snapshot;
    const char *err_kind = "config";
    char errbuf[1024];
    SelectionOverride sel;
    int has_sel = 0;
    WorkerArg *arg;

    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (out_job != NULL) *out_job = 0;
    if (bridge == NULL || request_json == NULL) return 1;

    if (length == 0 || length > TS_BRIDGE_MAX_REQUEST_BYTES) {
        error_json(out_error, "requestTooLarge", "请求体为空或超过 16MB 上限");
        return 1;
    }

    root = cJSON_ParseWithLength(request_json, length);
    if (root == NULL) {
        error_json(out_error, "requestInvalid", "请求 JSON 解析失败");
        return 1;
    }

    errbuf[0] = '\0';
    item = cJSON_GetObjectItemCaseSensitive(root, "modelSelection");
    if (item != NULL && !cJSON_IsNull(item)) {
        if (parse_selection(item, &sel, errbuf, sizeof(errbuf)) != 0) {
            cJSON_Delete(root);
            return fail_json(out_error, "requestInvalid", errbuf);
        }
        has_sel = 1;
    }

    ts_config_init(&snapshot);
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "shuttingDown", "正在关闭，不能开始新的分析");
    }
    if (bridge->analyze_job != NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "busy", "已有正在进行的分析，请先等待或取消");
    }

    /*
     * 锁内校验并深拷贝：任何“profile 已删除 / revision 不匹配 / 没有密钥”
     * 都在这里变成明确错误，且**不创建 job**。
     */
    if (build_job_config_locked(bridge, has_sel ? &sel : NULL, TS_TARGET_CHAT,
                                &snapshot,
                                &err_kind, errbuf, sizeof(errbuf)) != 0) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, err_kind,
                          errbuf[0] != '\0' ? errbuf : "无法准备本次分析的配置");
    }

    job = (BridgeJob *)ts_calloc(1, sizeof(BridgeJob));
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    id = ++bridge->next_job;
    job->id = id;
    job->kind = TS_JOBKIND_ANALYZE;
    job->state = TS_JOB_RUNNING;
    job->started_ms = ts_clock_ms();
    ts_analyze_result_init(&job->result);
    ts_cancel_init(&job->cancel);
    job->cancel_ready = 1;
    job->cfg_snapshot = snapshot;   /* 所有权移交 */
    memset(&snapshot, 0, sizeof(snapshot));
    job->snapshot_ready = 1;

    item = cJSON_GetObjectItemCaseSensitive(root, "conversationId");
    if (item != NULL && cJSON_IsString(item)) {
        job->conversation_id = ts_strdup(cJSON_GetStringValue(item));
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "requestId");
    if (item != NULL && cJSON_IsString(item)) {
        job->request_id = ts_strdup(cJSON_GetStringValue(item));
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "baseVersionId");
    if (item != NULL && cJSON_IsString(item)) {
        job->base_version_id = ts_strdup(cJSON_GetStringValue(item));
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "baseRevision");
    if (item != NULL && cJSON_IsNumber(item)) {
        job->base_revision = item->valueint;
    }

    job->request_json = ts_strndup(request_json, length);
    job->request_len = length;
    if (job->request_json == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }

    arg = (WorkerArg *)ts_calloc(1, sizeof(WorkerArg));
    if (arg == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    arg->b = bridge;
    arg->job = job;

    bridge->analyze_job = job;
    /* 启动前先开新代号并清取消标志：工作线程立刻就能拿到正确的代号。 */
    ts_cancel_begin(&job->cancel);
    job_push_event(job, TS_EVT_STARTED, "开始分析", NULL, NULL, 0);

    job->thread = CreateThread(NULL, 0, analyze_worker, arg, 0, &job->thread_id);
    if (job->thread == NULL) {
        bridge->analyze_job = NULL;
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_free(arg);
        job_free(job);
        return fail_json(out_error, "thread", "无法创建工作线程");
    }
    job->thread_started = 1;
    LeaveCriticalSection(&bridge->lock);

    cJSON_Delete(root);
    if (out_job != NULL) *out_job = id;
    return 0;
}

int ts_bridge_probe_async(TsBridge *bridge,
                          const char *probe_json, size_t length,
                          TsJobId *out_job,
                          TsBridgeBuffer *out_error)
{
    cJSON *root;
    const cJSON *item;
    BridgeJob *job;
    TsJobId id;
    TsConfig snapshot;
    const char *err_kind = "config";
    char errbuf[1024];
    SelectionOverride sel;
    WorkerArg *arg;
    int probe_kind = TS_PROBE_MODELS;
    long timeout_ms = 0;

    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (out_job != NULL) *out_job = 0;
    if (bridge == NULL || probe_json == NULL) return 1;
    if (length == 0 || length > TS_BRIDGE_MAX_REQUEST_BYTES) {
        return fail_json(out_error, "requestInvalid", "探针请求为空或超过 16MB 上限");
    }

    root = cJSON_ParseWithLength(probe_json, length);
    if (root == NULL) {
        return fail_json(out_error, "requestInvalid", "探针请求不是合法 JSON");
    }
    errbuf[0] = '\0';

    item = cJSON_GetObjectItemCaseSensitive(root, "kind");
    if (item == NULL || !cJSON_IsString(item)) {
        cJSON_Delete(root);
        return fail_json(out_error, "requestInvalid", "探针请求缺少 kind（models 或 chat）");
    }
    if (strcmp(cJSON_GetStringValue(item), "models") == 0) {
        probe_kind = TS_PROBE_MODELS;
    } else if (strcmp(cJSON_GetStringValue(item), "chat") == 0) {
        probe_kind = TS_PROBE_CHAT;
    } else {
        cJSON_Delete(root);
        return fail_json(out_error, "requestInvalid", "探针 kind 只能是 models 或 chat");
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "timeoutMs");
    if (item != NULL && cJSON_IsNumber(item)) {
        timeout_ms = (long)item->valuedouble;
        if (timeout_ms < TS_PROBE_TIMEOUT_MIN_MS) timeout_ms = TS_PROBE_TIMEOUT_MIN_MS;
        if (timeout_ms > TS_PROBE_TIMEOUT_MAX_MS) timeout_ms = TS_PROBE_TIMEOUT_MAX_MS;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "profileId");
    if (item == NULL || !cJSON_IsString(item) ||
        cJSON_GetStringValue(item)[0] == '\0') {
        cJSON_Delete(root);
        return fail_json(out_error, "requestInvalid", "探针请求缺少 profileId");
    }
    memset(&sel, 0, sizeof(sel));
    sel.profile_id = cJSON_GetStringValue(item);
    sel.has_profile = 1;

    item = cJSON_GetObjectItemCaseSensitive(root, "profileRevision");
    if (item != NULL && cJSON_IsNumber(item)) {
        sel.has_revision = 1;
        sel.revision = (long)item->valuedouble;
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "modelId");
    if (item != NULL && cJSON_IsString(item)) {
        sel.model_id = cJSON_GetStringValue(item);
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "thinking");
    if (item != NULL && cJSON_IsString(item)) {
        TsThinking t = TS_THINKING_UNSUPPORTED;
        if (ts_thinking_parse(cJSON_GetStringValue(item), &t) == 0) {
            sel.has_thinking = 1;
            sel.thinking = t;
        }
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "reasoningEffort");
    if (item != NULL && cJSON_IsString(item)) {
        const char *s = cJSON_GetStringValue(item);
        if (s != NULL && s[0] != '\0') sel.effort = s;
    }

    ts_config_init(&snapshot);
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "shuttingDown", "正在关闭，不能开始新的探针");
    }
    if (probe_slot_count_locked(bridge) >= TS_BRIDGE_MAX_PROBE_JOBS) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "busy",
                          "同时进行的探针已达上限（4 个），请等待或取消");
    }

    if (build_job_config_locked(bridge, &sel,
                                (probe_kind == TS_PROBE_MODELS) ? TS_TARGET_MODELS
                                                                : TS_TARGET_CHAT,
                                &snapshot,
                                &err_kind, errbuf, sizeof(errbuf)) != 0) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, err_kind,
                          errbuf[0] != '\0' ? errbuf : "无法准备探针配置");
    }
    snapshot.probe_timeout_ms = (timeout_ms > 0) ? timeout_ms
                                                 : TS_PROBE_TIMEOUT_DEFAULT_MS;

    job = (BridgeJob *)ts_calloc(1, sizeof(BridgeJob));
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    id = ++bridge->next_job;
    job->id = id;
    job->kind = TS_JOBKIND_PROBE;
    job->probe_kind = probe_kind;
    job->state = TS_JOB_RUNNING;
    job->started_ms = ts_clock_ms();
    ts_analyze_result_init(&job->result);
    ts_cancel_init(&job->cancel);
    job->cancel_ready = 1;
    job->cfg_snapshot = snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    job->snapshot_ready = 1;

    job->request_json = ts_strndup(probe_json, length);
    job->request_len = length;
    if (job->request_json == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }

    arg = (WorkerArg *)ts_calloc(1, sizeof(WorkerArg));
    if (arg == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    arg->b = bridge;
    arg->job = job;

    if (probe_slot_add_locked(bridge, job) != 0) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_free(arg);
        job_free(job);
        return fail_json(out_error, "busy", "同时进行的探针已达上限");
    }

    ts_cancel_begin(&job->cancel);
    job_push_event(job, TS_EVT_STARTED, "开始连通性测试", NULL, NULL, 0);

    job->thread = CreateThread(NULL, 0, probe_worker, arg, 0, &job->thread_id);
    if (job->thread == NULL) {
        job_detach_locked(bridge, job);
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_free(arg);
        job_free(job);
        return fail_json(out_error, "thread", "无法创建工作线程");
    }
    job->thread_started = 1;
    LeaveCriticalSection(&bridge->lock);

    cJSON_Delete(root);
    if (out_job != NULL) *out_job = id;
    return 0;
}

/*
 * 启动一次“日历约束识别”。
 *
 * 请求体：{"userRequest": "...", "sources": [...], "modelSelection": {...},
 *          "conversationId": "...", "requestId": "..."}
 * 与 analyze 完全一致的材料结构：界面把已提交的用户补充与已上传附件的提取文本
 * 一起传进来，因此模型看到的是全部材料，而不只是输入框里的新文本。
 */
int ts_bridge_constraints_async(TsBridge *bridge,
                                const char *request_json, size_t length,
                                TsJobId *out_job,
                                TsBridgeBuffer *out_error)
{
    cJSON *root = NULL;
    const cJSON *item;
    SelectionOverride sel;
    int has_sel = 0;
    TsConfig snapshot;
    const char *err_kind = NULL;
    char errbuf[768];
    BridgeJob *job = NULL;
    WorkerArg *arg = NULL;
    TsJobId id;

    memset(&sel, 0, sizeof(sel));
    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (out_job != NULL) *out_job = 0;
    if (bridge == NULL || request_json == NULL) return 1;

    if (length == 0 || length > TS_BRIDGE_MAX_REQUEST_BYTES) {
        error_json(out_error, "requestTooLarge", "请求体为空或超过 16MB 上限");
        return 1;
    }

    root = cJSON_ParseWithLength(request_json, length);
    if (root == NULL) {
        error_json(out_error, "requestInvalid", "请求 JSON 解析失败");
        return 1;
    }

    errbuf[0] = '\0';
    item = cJSON_GetObjectItemCaseSensitive(root, "modelSelection");
    if (item != NULL && !cJSON_IsNull(item)) {
        if (parse_selection(item, &sel, errbuf, sizeof(errbuf)) != 0) {
            cJSON_Delete(root);
            return fail_json(out_error, "requestInvalid", errbuf);
        }
        has_sel = 1;
    }

    ts_config_init(&snapshot);
    EnterCriticalSection(&bridge->lock);
    if (bridge->shutting_down) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "shuttingDown", "正在关闭，不能开始新的约束识别");
    }
    if (probe_slot_count_locked(bridge) >= TS_BRIDGE_MAX_PROBE_JOBS) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        return fail_json(out_error, "busy",
                         "同时进行的后台请求已达上限（4 个），请等待或取消");
    }

    if (build_job_config_locked(bridge, has_sel ? &sel : NULL, TS_TARGET_CHAT,
                                &snapshot,
                                &err_kind, errbuf, sizeof(errbuf)) != 0) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, err_kind,
                         errbuf[0] != '\0' ? errbuf : "无法准备本次识别的配置");
    }

    job = (BridgeJob *)ts_calloc(1, sizeof(BridgeJob));
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_config_free(&snapshot);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    id = ++bridge->next_job;
    job->id = id;
    job->kind = TS_JOBKIND_CONSTRAINTS;
    job->state = TS_JOB_RUNNING;
    job->started_ms = ts_clock_ms();
    ts_analyze_result_init(&job->result);
    ts_constraints_result_init(&job->constraints);
    ts_cancel_init(&job->cancel);
    job->cancel_ready = 1;
    job->cfg_snapshot = snapshot;   /* 所有权移交 */
    memset(&snapshot, 0, sizeof(snapshot));
    job->snapshot_ready = 1;

    item = cJSON_GetObjectItemCaseSensitive(root, "conversationId");
    if (item != NULL && cJSON_IsString(item)) {
        job->conversation_id = ts_strdup(cJSON_GetStringValue(item));
    }
    item = cJSON_GetObjectItemCaseSensitive(root, "requestId");
    if (item != NULL && cJSON_IsString(item)) {
        job->request_id = ts_strdup(cJSON_GetStringValue(item));
    }

    job->request_json = ts_strndup(request_json, length);
    job->request_len = length;
    if (job->request_json == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }

    arg = (WorkerArg *)ts_calloc(1, sizeof(WorkerArg));
    if (arg == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        job_free(job);
        return fail_json(out_error, "memory", "内存分配失败");
    }
    arg->b = bridge;
    arg->job = job;

    if (probe_slot_add_locked(bridge, job) != 0) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_free(arg);
        job_free(job);
        return fail_json(out_error, "busy", "同时进行的后台请求已达上限");
    }

    ts_cancel_begin(&job->cancel);
    job_push_event(job, TS_EVT_STARTED, "开始识别时间约束", NULL, NULL, 0);

    job->thread = CreateThread(NULL, 0, constraints_worker, arg, 0, &job->thread_id);
    if (job->thread == NULL) {
        job_detach_locked(bridge, job);
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        ts_free(arg);
        job_free(job);
        return fail_json(out_error, "thread", "无法创建工作线程");
    }
    job->thread_started = 1;
    LeaveCriticalSection(&bridge->lock);

    cJSON_Delete(root);
    if (out_job != NULL) *out_job = id;
    return 0;
}

/* ------------------------------------------------------------------ */
/* poll / cancel / result / release                                     */
/* ------------------------------------------------------------------ */

int ts_bridge_poll(TsBridge *bridge, TsJobId job_id, TsBridgeBuffer *out_events_json)
{
    BridgeJob *job;
    cJSON *root = NULL;
    cJSON *events = NULL;
    size_t i;

    if (out_events_json != NULL) {
        out_events_json->data = NULL;
        out_events_json->length = 0;
    }
    if (bridge == NULL) return 1;

    root = cJSON_CreateObject();
    events = cJSON_CreateArray();
    if (root == NULL || events == NULL) {
        if (root != NULL) cJSON_Delete(root);
        if (events != NULL) cJSON_Delete(events);
        return 1;
    }

    EnterCriticalSection(&bridge->lock);
    job = job_find_locked(bridge, job_id);
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        cJSON_Delete(events);
        error_json(out_events_json, "noSuchJob", "job 不存在或已释放");
        return 1;
    }

    if (cJSON_AddNumberToObject(root, "job", (double)job->id) == NULL ||
        cJSON_AddStringToObject(root, "jobType",
            (job->kind == TS_JOBKIND_PROBE)
                ? "probe"
                : ((job->kind == TS_JOBKIND_CONSTRAINTS) ? "constraints"
                                                        : "analyze")) == NULL ||
        cJSON_AddBoolToObject(root, "terminal",
            (job->state != TS_JOB_RUNNING) ? 1 : 0) == NULL) {
        LeaveCriticalSection(&bridge->lock);
        cJSON_Delete(root);
        cJSON_Delete(events);
        return 1;
    }

    for (i = 0; i < job->event_count; i++) {
        const BridgeEvent *e = &job->events[i];
        cJSON *o = cJSON_CreateObject();
        const char *type =
            (e->type == TS_EVT_STARTED) ? "started" :
            (e->type == TS_EVT_PROGRESS) ? "progress" :
            (e->type == TS_EVT_SUCCEEDED) ? "succeeded" :
            (e->type == TS_EVT_FAILED) ? "failed" : "cancelled";
        if (o == NULL ||
            cJSON_AddNumberToObject(o, "seq", (double)(i + 1)) == NULL ||
            cJSON_AddStringToObject(o, "type", type) == NULL ||
            cJSON_AddStringToObject(o, "stage", e->stage != NULL ? e->stage : "") == NULL ||
            cJSON_AddStringToObject(o, "detail", e->detail != NULL ? e->detail : "") == NULL ||
            cJSON_AddStringToObject(o, "error", e->error != NULL ? e->error : "") == NULL ||
            cJSON_AddNumberToObject(o, "elapsedMs", (double)e->elapsed_ms) == NULL ||
            cJSON_AddNumberToObject(o, "atMs", (double)e->at_ms) == NULL ||
            cJSON_AddStringToObject(o, "conversationId",
                job->conversation_id != NULL ? job->conversation_id : "") == NULL ||
            cJSON_AddStringToObject(o, "requestId",
                job->request_id != NULL ? job->request_id : "") == NULL ||
            cJSON_AddNumberToObject(o, "baseRevision", (double)job->base_revision) == NULL ||
            (job->base_version_id != NULL
                ? cJSON_AddStringToObject(o, "baseVersionId", job->base_version_id)
                : cJSON_AddNullToObject(o, "baseVersionId")) == NULL) {
            if (o != NULL) cJSON_Delete(o);
            LeaveCriticalSection(&bridge->lock);
            cJSON_Delete(root);
            cJSON_Delete(events);
            return 1;
        }
        cJSON_AddItemToArray(events, o);
    }
    job_clear_events(job);
    LeaveCriticalSection(&bridge->lock);

    cJSON_AddItemToObject(root, "events", events);
    return buf_set_json(out_events_json, root);
}

int ts_bridge_cancel(TsBridge *bridge, TsJobId job_id)
{
    BridgeJob *job;
    if (bridge == NULL) return 1;
    EnterCriticalSection(&bridge->lock);
    job = job_find_locked(bridge, job_id);
    if (job == NULL || job->state != TS_JOB_RUNNING) {
        LeaveCriticalSection(&bridge->lock);
        return 1;
    }
    ts_cancel_request(&job->cancel);
    LeaveCriticalSection(&bridge->lock);
    return 0;
}

/* 把 job 的配置快照摘要写进 root["source"]（不含密钥）。 */
static int add_source_object(cJSON *root, const TsConfig *cfg)
{
    cJSON *src;
    char host[TS_PROFILE_HOST_MAX];

    if (cfg->profile_id == NULL || cfg->profile_id[0] == '\0') {
        return 0;   /* 没有使用 profile：不写 source，Dart 记“来源未知” */
    }
    src = cJSON_CreateObject();
    if (src == NULL) return 1;
    ts_url_host(cfg->endpoint_url, host, sizeof(host));
    cJSON_AddStringToObject(src, "profileId", cfg->profile_id);
    cJSON_AddNumberToObject(src, "profileRevision", (double)cfg->profile_revision);
    cJSON_AddStringToObject(src, "modelId",
                            cfg->model != NULL ? cfg->model : "");
    cJSON_AddStringToObject(src, "protocol", ts_protocol_name((TsProtocol)cfg->protocol));
    cJSON_AddStringToObject(src, "thinking", ts_thinking_name((TsThinking)cfg->thinking));
    if (cfg->thinking_effort != NULL && cfg->thinking_effort[0] != '\0') {
        cJSON_AddStringToObject(src, "reasoningEffort", cfg->thinking_effort);
    } else {
        cJSON_AddNullToObject(src, "reasoningEffort");
    }
    cJSON_AddStringToObject(src, "endpointHost", host);
    if (!cJSON_AddItemToObject(root, "source", src)) {
        cJSON_Delete(src);
        return 1;
    }
    return 0;
}

static int result_analyze_locked(TsBridge *bridge, BridgeJob *job,
                                TsBridgeBuffer *out_result_json)
{
    cJSON *root = NULL;
    char *plan_json = NULL;
    char errbuf[512];

    (void)bridge;
    errbuf[0] = '\0';
    root = cJSON_CreateObject();
    if (root == NULL) return 1;
    if (cJSON_AddNumberToObject(root, "job", (double)job->id) == NULL ||
        cJSON_AddStringToObject(root, "jobType", "analyze") == NULL ||
        cJSON_AddNumberToObject(root, "elapsedMs",
            (double)job->result.elapsed_ms) == NULL ||
        cJSON_AddStringToObject(root, "conversationId",
            job->conversation_id != NULL ? job->conversation_id : "") == NULL ||
        cJSON_AddStringToObject(root, "requestId",
            job->request_id != NULL ? job->request_id : "") == NULL ||
        cJSON_AddNumberToObject(root, "baseRevision", (double)job->base_revision) == NULL ||
        (job->base_version_id != NULL
            ? cJSON_AddStringToObject(root, "baseVersionId", job->base_version_id)
            : cJSON_AddNullToObject(root, "baseVersionId")) == NULL) {
        cJSON_Delete(root);
        return 1;
    }

    if (job->state == TS_JOB_OK) {
        if (ts_local_plan_to_json(&job->result.plan, &plan_json, NULL,
                                  errbuf, sizeof(errbuf)) != 0) {
            cJSON_Delete(root);
            error_json(out_result_json, "internal", errbuf);
            return 1;
        }
        if (cJSON_AddBoolToObject(root, "ok", 1) == NULL ||
            cJSON_AddStringToObject(root, "summary",
                job->result.plan.summary != NULL ? job->result.plan.summary : "") == NULL) {
            ts_free(plan_json);
            cJSON_Delete(root);
            return 1;
        }
        {
            cJSON *plan = cJSON_Parse(plan_json);
            ts_free(plan_json);
            if (plan == NULL) {
                cJSON_Delete(root);
                error_json(out_result_json, "internal", "计划序列化失败");
                return 1;
            }
            cJSON_AddItemToObject(root, "plan", plan);
        }
        {
            cJSON *usage = cJSON_CreateObject();
            if (usage != NULL) {
                cJSON_AddBoolToObject(usage, "present", job->result.usage_present ? 1 : 0);
                cJSON_AddNumberToObject(usage, "promptTokens",
                    (double)job->result.usage_prompt_tokens);
                cJSON_AddNumberToObject(usage, "completionTokens",
                    (double)job->result.usage_completion_tokens);
                cJSON_AddNumberToObject(usage, "reasoningTokens",
                    (double)job->result.usage_reasoning_tokens);
                cJSON_AddNumberToObject(usage, "totalTokens",
                    (double)job->result.usage_total_tokens);
                cJSON_AddItemToObject(root, "usage", usage);
            }
        }
        {
            /* 诊断：只给“尝试次数/是否修复/HTTP 状态”，不含模型思考正文 */
            cJSON *diag = cJSON_CreateObject();
            if (diag != NULL) {
                cJSON_AddNumberToObject(diag, "attempts", (double)job->result.diag.attempts);
                cJSON_AddBoolToObject(diag, "usedRepair",
                    job->result.diag.used_repair ? 1 : 0);
                cJSON_AddBoolToObject(diag, "networkRetried",
                    job->result.diag.network_retried ? 1 : 0);
                cJSON_AddNumberToObject(diag, "httpStatus",
                    (double)job->result.http_status);
                cJSON_AddItemToObject(root, "diagnostics", diag);
            }
        }
        /* 来源（无密钥）：用于把“这一版计划是谁生成的”记录到 PlanVersion。 */
        (void)add_source_object(root, &job->cfg_snapshot);
    } else {
        const char *kind = (job->state == TS_JOB_CANCELLED)
                               ? "cancelled"
                               : error_kind_name_public(job->result.error_kind);
        if (cJSON_AddBoolToObject(root, "ok", 0) == NULL ||
            cJSON_AddStringToObject(root, "errorKind", kind) == NULL ||
            cJSON_AddStringToObject(root, "error",
                job->result.error != NULL ? job->result.error : "分析失败") == NULL ||
            cJSON_AddNumberToObject(root, "httpStatus",
                (double)job->result.http_status) == NULL) {
            cJSON_Delete(root);
            return 1;
        }
    }

    return buf_set_json(out_result_json, root);
}

/* 约束识别 job 的终态 JSON（调用方已持有锁）。 */
static int result_constraints_locked(BridgeJob *job,
                                     TsBridgeBuffer *out_result_json)
{
    cJSON *root;
    const TsConstraintsResult *cr = &job->constraints;

    root = cJSON_CreateObject();
    if (root == NULL) return 1;
    if (cJSON_AddNumberToObject(root, "job", (double)job->id) == NULL ||
        cJSON_AddStringToObject(root, "jobType", "constraints") == NULL ||
        cJSON_AddNumberToObject(root, "elapsedMs", (double)cr->elapsed_ms) == NULL ||
        cJSON_AddStringToObject(root, "conversationId",
            job->conversation_id != NULL ? job->conversation_id : "") == NULL ||
        cJSON_AddStringToObject(root, "requestId",
            job->request_id != NULL ? job->request_id : "") == NULL) {
        cJSON_Delete(root);
        return 1;
    }

    /* 本次请求实际使用的思考配置：如实上报，不是对全局设置的声明。 */
    {
        cJSON *thinking = cJSON_CreateObject();
        if (thinking != NULL) {
            cJSON_AddBoolToObject(thinking, "enabled",
                                  cr->thinking_enabled ? 1 : 0);
            if (cr->thinking_effort != NULL && cr->thinking_effort[0] != '\0') {
                cJSON_AddStringToObject(thinking, "effort", cr->thinking_effort);
            } else {
                cJSON_AddNullToObject(thinking, "effort");
            }
            cJSON_AddStringToObject(thinking, "protocol",
                                    ts_protocol_name((TsProtocol)job->cfg_snapshot.protocol));
            cJSON_AddItemToObject(root, "thinking", thinking);
        }
    }

    if (job->state == TS_JOB_OK && cr->proposals_json != NULL) {
        cJSON *parsed = cJSON_Parse(cr->proposals_json);
        if (parsed == NULL) {
            cJSON_Delete(root);
            error_json(out_result_json, "internal", "约束序列化失败");
            return 1;
        }
        cJSON_AddBoolToObject(root, "ok", 1);
        cJSON_AddItemToObject(root, "constraints", parsed);
        (void)add_source_object(root, &job->cfg_snapshot);
    } else {
        const char *kind = (job->state == TS_JOB_CANCELLED ||
                            cr->error_kind == TS_MODEL_ERR_CANCELLED)
                               ? "cancelled"
                               : error_kind_name_public(cr->error_kind);
        if (cJSON_AddBoolToObject(root, "ok", 0) == NULL ||
            cJSON_AddStringToObject(root, "errorKind", kind) == NULL ||
            cJSON_AddStringToObject(root, "error",
                cr->error != NULL ? cr->error : "约束识别失败") == NULL ||
            cJSON_AddNumberToObject(root, "httpStatus",
                (double)cr->http_status) == NULL) {
            cJSON_Delete(root);
            return 1;
        }
    }
    return buf_set_json(out_result_json, root);
}

int ts_bridge_result(TsBridge *bridge, TsJobId job_id, TsBridgeBuffer *out_result_json)
{
    BridgeJob *job;
    int rc;

    if (out_result_json != NULL) {
        out_result_json->data = NULL;
        out_result_json->length = 0;
    }
    if (bridge == NULL) return 1;

    EnterCriticalSection(&bridge->lock);
    job = job_find_locked(bridge, job_id);
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        error_json(out_result_json, "noSuchJob", "job 不存在或已释放");
        return 1;
    }
    if (job->state == TS_JOB_RUNNING) {
        LeaveCriticalSection(&bridge->lock);
        error_json(out_result_json, "running", "任务尚未结束");
        return 1;
    }

    if (job->kind == TS_JOBKIND_PROBE) {
        char *copy = (job->probe_result != NULL) ? ts_strdup(job->probe_result) : NULL;
        LeaveCriticalSection(&bridge->lock);
        if (copy == NULL) {
            return fail_json(out_result_json, "internal", "探针结果为空");
        }
        if (out_result_json != NULL) {
            out_result_json->data = copy;
            out_result_json->length = strlen(copy);
        } else {
            ts_free(copy);
        }
        return 0;
    }

    if (job->kind == TS_JOBKIND_CONSTRAINTS) {
        rc = result_constraints_locked(job, out_result_json);
        LeaveCriticalSection(&bridge->lock);
        return rc;
    }

    rc = result_analyze_locked(bridge, job, out_result_json);
    LeaveCriticalSection(&bridge->lock);
    return rc;
}

int ts_bridge_release_job(TsBridge *bridge, TsJobId job_id)
{
    BridgeJob *job;
    HANDLE thread = NULL;
    int stop_thread = 0;

    if (bridge == NULL) return 1;
    EnterCriticalSection(&bridge->lock);
    job = job_find_locked(bridge, job_id);
    if (job == NULL) {
        LeaveCriticalSection(&bridge->lock);
        return 1;
    }
    if (job->state == TS_JOB_RUNNING) {
        LeaveCriticalSection(&bridge->lock);
        return 1;      /* 工作线程仍在运行：不能释放 */
    }
    job_detach_locked(bridge, job);
    if (job->thread_started && job->thread != NULL) {
        thread = job->thread;
        job->thread = NULL;
        job->thread_started = 0;
        stop_thread = 1;
    }
    LeaveCriticalSection(&bridge->lock);

    /* 在锁外等待线程彻底退出：避免与工作线程的加锁顺序互相死等。 */
    if (stop_thread) {
        WaitForSingleObject(thread, 5000);
        CloseHandle(thread);
    }

    job_free(job);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 本地校验 / 重排                                                     */
/* ------------------------------------------------------------------ */

/* 解析 command_json 里的 plan 对象为字符串，交给 ts_local_plan_parse。 */
static int command_plan_string(const cJSON *root, char **out, char *err, size_t err_sz)
{
    const cJSON *plan = cJSON_GetObjectItemCaseSensitive(root, "plan");
    if (plan == NULL) {
        snprintf(err, err_sz, "缺少 plan");
        return 1;
    }
    *out = cJSON_PrintUnformatted(plan);
    if (*out == NULL) {
        snprintf(err, err_sz, "内存分配失败");
        return 1;
    }
    return 0;
}

/*
 * 校验 + 重排 + 生成展示快照。
 * 失败时不返回半成品：调用方保留原计划不动。
 */
static int build_snapshot(TsBridge *bridge, const char *plan_json,
                          cJSON **out_display, char *err, size_t err_sz)
{
    TsPlan plan;
    TsScheduleResult sched;
    TsStatusView status;
    char *display_json = NULL;
    char perr[512];
    int rc = 1;

    ts_plan_init(&plan);
    memset(&sched, 0, sizeof(sched));
    memset(&status, 0, sizeof(status));
    *out_display = NULL;
    perr[0] = '\0';

    if (ts_local_plan_parse(plan_json, strlen(plan_json), &bridge->cfg,
                            &plan, perr, sizeof(perr)) != 0) {
        snprintf(err, err_sz, "%s", perr[0] != '\0' ? perr : "计划校验失败");
        goto done;
    }
    if (ts_schedule_build(&plan, &bridge->cfg, &sched, perr, sizeof(perr)) != 0) {
        snprintf(err, err_sz, "%s", perr[0] != '\0' ? perr : "排序失败");
        goto done;
    }
    if (ts_schedule_status(&plan, &status, perr, sizeof(perr)) != 0) {
        snprintf(err, err_sz, "%s", perr[0] != '\0' ? perr : "状态计算失败");
        goto done;
    }
    if (ts_display_build(&plan, &sched, &status, &display_json, NULL,
                         perr, sizeof(perr)) != 0) {
        snprintf(err, err_sz, "%s", perr[0] != '\0' ? perr : "展示快照生成失败");
        goto done;
    }
    *out_display = cJSON_Parse(display_json);
    if (*out_display == NULL) {
        snprintf(err, err_sz, "展示快照序列化失败");
        goto done;
    }
    rc = 0;

done:
    ts_free(display_json);
    ts_plan_free(&plan);
    ts_schedule_result_free(&sched);
    ts_status_view_free(&status);
    return rc;
}

int ts_bridge_edit(TsBridge *bridge,
                   const char *command_json, size_t length,
                   TsBridgeBuffer *out_snapshot_or_error_json)
{
    cJSON *root = NULL;
    cJSON *display = NULL;
    cJSON *resp = NULL;
    char *plan_json = NULL;
    char errbuf[768];
    int rc = 1;

    if (out_snapshot_or_error_json != NULL) {
        out_snapshot_or_error_json->data = NULL;
        out_snapshot_or_error_json->length = 0;
    }
    if (bridge == NULL || command_json == NULL) return 1;
    errbuf[0] = '\0';

    root = cJSON_ParseWithLength(command_json, length);
    if (root == NULL) {
        error_json(out_snapshot_or_error_json, "requestInvalid", "命令 JSON 解析失败");
        return 1;
    }
    if (command_plan_string(root, &plan_json, errbuf, sizeof(errbuf)) != 0) {
        cJSON_Delete(root);
        error_json(out_snapshot_or_error_json, "requestInvalid", errbuf);
        return 1;
    }
    cJSON_Delete(root);

    if (build_snapshot(bridge, plan_json, &display, errbuf, sizeof(errbuf)) != 0) {
        ts_free(plan_json);
        error_json(out_snapshot_or_error_json, "validation", errbuf);
        return 1;
    }
    ts_free(plan_json);

    resp = cJSON_CreateObject();
    if (resp == NULL) {
        cJSON_Delete(display);
        return 1;
    }
    if (cJSON_AddBoolToObject(resp, "ok", 1) == NULL) {
        cJSON_Delete(display);
        cJSON_Delete(resp);
        return 1;
    }
    cJSON_AddItemToObject(resp, "display", display);
    rc = buf_set_json(out_snapshot_or_error_json, resp);
    return rc;
}

int ts_bridge_export(TsBridge *bridge,
                     const char *command_json, size_t length,
                     TsBridgeBuffer *out_result_json)
{
    cJSON *root = NULL;
    cJSON *resp = NULL;
    char *plan_json = NULL;
    char *path_copy = NULL;
    const cJSON *fmt, *path;
    char format_buf[16];
    const char *format = "txt";
    const char *path_utf8 = NULL;
    TsPlan plan;
    TsScheduleResult sched;
    TsStatusView status;
    char errbuf[768];
    int rc = 1;

    if (out_result_json != NULL) {
        out_result_json->data = NULL;
        out_result_json->length = 0;
    }
    if (bridge == NULL || command_json == NULL) return 1;
    errbuf[0] = '\0';
    ts_plan_init(&plan);
    memset(&sched, 0, sizeof(sched));
    memset(&status, 0, sizeof(status));

    root = cJSON_ParseWithLength(command_json, length);
    if (root == NULL) {
        error_json(out_result_json, "requestInvalid", "命令 JSON 解析失败");
        return 1;
    }
    fmt = cJSON_GetObjectItemCaseSensitive(root, "format");
    /*
     * 必须把 format 复制到本地缓冲：cJSON_Delete(root) 之后，
     * cJSON_GetStringValue 返回的指针就失效了（曾经因此把诊断导出写成日常 TXT）。
     */
    if (fmt != NULL && cJSON_IsString(fmt)) {
        snprintf(format_buf, sizeof(format_buf), "%s", cJSON_GetStringValue(fmt));
        format = format_buf;
    }
    path = cJSON_GetObjectItemCaseSensitive(root, "path");
    if (path == NULL || !cJSON_IsString(path)) {
        cJSON_Delete(root);
        error_json(out_result_json, "requestInvalid", "缺少导出路径");
        return 1;
    }
    path_utf8 = cJSON_GetStringValue(path);
    path_copy = ts_strdup(path_utf8);
    if (path_copy == NULL) {
        cJSON_Delete(root);
        return 1;
    }

    if (command_plan_string(root, &plan_json, errbuf, sizeof(errbuf)) != 0) {
        cJSON_Delete(root);
        ts_free(path_copy);
        error_json(out_result_json, "requestInvalid", errbuf);
        return 1;
    }
    cJSON_Delete(root);

    if (ts_local_plan_parse(plan_json, strlen(plan_json), &bridge->cfg,
                            &plan, errbuf, sizeof(errbuf)) != 0) {
        goto failed;
    }
    if (ts_schedule_build(&plan, &bridge->cfg, &sched, errbuf, sizeof(errbuf)) != 0) {
        goto failed;
    }
    if (ts_schedule_status(&plan, &status, errbuf, sizeof(errbuf)) != 0) {
        goto failed;
    }

    if (strcmp(format, "diag") == 0) {
        /* 结构化诊断导出：保留计算数据，与日常导出明确分开 */
        if (ts_export_json(&plan, &sched, &status, &bridge->cfg,
                           path_copy, errbuf, sizeof(errbuf)) != 0) {
            goto failed;
        }
    } else {
        if (ts_export_user_txt(&plan, &sched, &status, path_copy,
                               errbuf, sizeof(errbuf)) != 0) {
            goto failed;
        }
    }

    resp = cJSON_CreateObject();
    if (resp == NULL) goto failed;
    cJSON_AddBoolToObject(resp, "ok", 1);
    cJSON_AddStringToObject(resp, "format", format);
    rc = buf_set_json(out_result_json, resp);
    goto done;

failed:
    error_json(out_result_json, "export", errbuf[0] != '\0' ? errbuf : "导出失败");
done:
    ts_free(plan_json);
    ts_free(path_copy);
    ts_plan_free(&plan);
    ts_schedule_result_free(&sched);
    ts_status_view_free(&status);
    return rc;
}

/* ------------------------------------------------------------------ */
/* 系统文件选择对话框                                                  */
/* ------------------------------------------------------------------ */

/* Flutter Windows runner 的窗口类名（flutter_app/windows/runner/win32_window.cpp）。 */
#define TS_FLUTTER_WINDOW_CLASS L"FLUTTER_RUNNER_WIN32_WINDOW"

static HWND find_owner_window(void)
{
    HWND hwnd = GetActiveWindow();
    if (hwnd != NULL) return hwnd;
    /* 没有活动窗口时退回按类名查找 Flutter 主窗口。 */
    return FindWindowW(TS_FLUTTER_WINDOW_CLASS, NULL);
}

/* UTF-8 -> 宽字符（调用方 ts_free）。失败返回 NULL。 */
static wchar_t *dup_utf8_to_wide(const char *s)
{
    int n;
    wchar_t *w;
    if (s == NULL) return NULL;
    n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    w = (wchar_t *)ts_calloc((size_t)n, sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        ts_free(w);
        return NULL;
    }
    return w;
}

int ts_bridge_pick_file(TsBridge *bridge,
                        const char *title_utf8,
                        TsBridgeBuffer *out_path,
                        TsBridgeBuffer *out_error)
{
    OPENFILENAMEW ofn;
    /*
     * 多选时系统会把“目录 + 每个文件名”连续写进这个缓冲区，所以必须远大于单个路径。
     */
    static wchar_t file_buf[16384];
    wchar_t *title_wide = NULL;
    const wchar_t *title;
    char *utf8 = NULL;
    int ok;
    int join_rc;

    if (out_path != NULL) { out_path->data = NULL; out_path->length = 0; }
    if (out_error != NULL) { out_error->data = NULL; out_error->length = 0; }
    if (bridge == NULL || out_path == NULL) return 1;

    title_wide = dup_utf8_to_wide(title_utf8);
    /* 默认标题：未传或转换失败时使用。 */
    title = (title_wide != NULL) ? title_wide : L"选择文本文件";

    memset(file_buf, 0, sizeof(file_buf));
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = find_owner_window();
    /*
     * 过滤器：只列文本；同时保留“所有文件”，这样用户仍能看到 .log 等文件，
     * 真正的类型校验在 App 侧完成（会给出明确提示）。
     */
    ofn.lpstrFilter = L"文档 (*.txt;*.md;*.pdf;*.docx;*.pptx)\0*.txt;*.md;*.pdf;*.docx;*.pptx\0所有文件 (*.*)\0*.*\0\0";
    ofn.lpstrFile = file_buf;
    ofn.nMaxFile = (DWORD)(sizeof(file_buf) / sizeof(file_buf[0]));
    ofn.lpstrTitle = title;
    /* OFN_ALLOWMULTISELECT：允许一次选多个文件（配合 OFN_EXPLORER 才按目录+文件名返回）。 */
    ofn.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST |
                OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_HIDEREADONLY;
    ofn.lpstrDefExt = L"txt";

    ok = GetOpenFileNameW(&ofn);
    ts_free(title_wide);

    if (!ok) {
        DWORD err = CommDlgExtendedError();
        if (err == 0) {
            return 0;   /* 用户取消：out_path 保持为空 */
        }
        {
            char msg[128];
            snprintf(msg, sizeof(msg), "文件对话框失败（CommDlgExtendedError=0x%08lX）",
                     (unsigned long)err);
            error_json(out_error, "dialog", msg);
        }
        return 1;
    }

    /* 单选/多选的缓冲格式不同，统一还原成“每行一条路径”。 */
    join_rc = ts_file_list_join(file_buf, sizeof(file_buf) / sizeof(file_buf[0]), &utf8);
    if (join_rc != TS_FILE_LIST_OK || utf8 == NULL) {
        if (join_rc == TS_FILE_LIST_TOO_MANY) {
            error_json(out_error, "argument", "选择的文件过多或路径过长");
        } else {
            error_json(out_error, "encoding", "无法转换所选路径");
        }
        return 1;
    }

    out_path->data = utf8;
    out_path->length = strlen(utf8);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Windows 通知（托盘气泡，不依赖第三方插件）                            */
/* ------------------------------------------------------------------ */

static HWND g_notify_hwnd = NULL;
static volatile LONG g_notify_clicked = 0;
static const wchar_t *kNotifyClass = L"TaskSchedulerNotifyWindow";

static LRESULT CALLBACK notify_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_APP + 1) {
        if (lp == NIN_BALLOONUSERCLICK || lp == NIN_SELECT || lp == NIN_KEYSELECT) {
            InterlockedExchange(&g_notify_clicked, 1);
        }
        return 0;
    }
    if (msg == WM_TIMER && wp == 1) {
        NOTIFYICONDATAW nid;
        ZeroMemory(&nid, sizeof(nid));
        nid.cbSize = sizeof(nid);
        nid.hWnd = hwnd;
        nid.uID = 1;
        Shell_NotifyIconW(NIM_DELETE, &nid);
        KillTimer(hwnd, 1);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static HWND notify_window(void)
{
    WNDCLASSEXW wc;
    HINSTANCE inst;
    if (g_notify_hwnd != NULL) return g_notify_hwnd;
    inst = GetModuleHandleW(NULL);
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = notify_wndproc;
    wc.hInstance = inst;
    wc.lpszClassName = kNotifyClass;
    RegisterClassExW(&wc); /* already registered is fine */
    g_notify_hwnd = CreateWindowExW(0, kNotifyClass, L"TaskScheduler", 0, 0, 0, 0, 0,
                                    NULL, NULL, inst, NULL);
    return g_notify_hwnd;
}

int ts_bridge_show_notification(TsBridge *bridge, const char *title_utf8,
                                const char *body_utf8)
{
    HWND hwnd;
    NOTIFYICONDATAW nid;
    wchar_t *title;
    wchar_t *body;
    BOOL ok;
    (void)bridge;
    hwnd = notify_window();
    if (hwnd == NULL) return 0;
    title = dup_utf8_to_wide(title_utf8 == NULL ? "" : title_utf8);
    body = dup_utf8_to_wide(body_utf8 == NULL ? "" : body_utf8);
    if (title == NULL || body == NULL) {
        ts_free(title);
        ts_free(body);
        return 0;
    }
    ZeroMemory(&nid, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_INFO;
    nid.uCallbackMessage = WM_APP + 1;
    nid.hIcon = LoadIconW(NULL, IDI_INFORMATION);
    lstrcpynW(nid.szTip, L"TaskScheduler", (int)(sizeof(nid.szTip) / sizeof(wchar_t)));
    lstrcpynW(nid.szInfoTitle, title,
              (int)(sizeof(nid.szInfoTitle) / sizeof(wchar_t)));
    lstrcpynW(nid.szInfo, body, (int)(sizeof(nid.szInfo) / sizeof(wchar_t)));
    nid.dwInfoFlags = NIIF_INFO;
    ok = Shell_NotifyIconW(NIM_MODIFY, &nid);
    if (!ok) ok = Shell_NotifyIconW(NIM_ADD, &nid);
    if (ok) SetTimer(hwnd, 1, 15000, NULL);
    ts_free(title);
    ts_free(body);
    return ok ? 1 : 0;
}

int ts_bridge_notification_clicked(TsBridge *bridge)
{
    (void)bridge;
    return (int)InterlockedExchange(&g_notify_clicked, 0);
}

/* ------------------------------------------------------------------ */
/* 关闭                                                                */
/* ------------------------------------------------------------------ */

int ts_bridge_shutdown_begin(TsBridge *bridge)
{
    size_t i;
    if (bridge == NULL) return 1;
    EnterCriticalSection(&bridge->lock);
    bridge->shutting_down = 1;
    if (bridge->analyze_job != NULL && bridge->analyze_job->state == TS_JOB_RUNNING) {
        ts_cancel_request(&bridge->analyze_job->cancel);
    }
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (bridge->probe_jobs[i] != NULL &&
            bridge->probe_jobs[i]->state == TS_JOB_RUNNING) {
            ts_cancel_request(&bridge->probe_jobs[i]->cancel);
        }
    }
    LeaveCriticalSection(&bridge->lock);
    return 0;
}

int ts_bridge_shutdown_ready(TsBridge *bridge)
{
    int ready = 1;
    size_t i;
    BridgeJob *jobs[TS_BRIDGE_MAX_PROBE_JOBS + 1];
    size_t n = 0;

    if (bridge == NULL) return 1;
    EnterCriticalSection(&bridge->lock);
    if (bridge->analyze_job != NULL) {
        if (bridge->analyze_job->state == TS_JOB_RUNNING) ready = 0;
        jobs[n++] = bridge->analyze_job;
    }
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (bridge->probe_jobs[i] != NULL) {
            if (bridge->probe_jobs[i]->state == TS_JOB_RUNNING) ready = 0;
            jobs[n++] = bridge->probe_jobs[i];
        }
    }
    if (ready) {
        for (i = 0; i < n; i++) {
            if (jobs[i]->thread_started && jobs[i]->thread != NULL) {
                if (WaitForSingleObject(jobs[i]->thread, 0) != WAIT_OBJECT_0) {
                    ready = 0;
                    break;
                }
            }
        }
    }
    LeaveCriticalSection(&bridge->lock);
    return ready;
}

void ts_bridge_destroy(TsBridge *bridge)
{
    BridgeJob *all[TS_BRIDGE_MAX_PROBE_JOBS + 1];
    size_t n = 0;
    size_t i;
    int timed_out = 0;

    if (bridge == NULL) return;

    /* 先请求取消并收集线程句柄；等待在锁外进行。 */
    EnterCriticalSection(&bridge->lock);
    bridge->shutting_down = 1;
    if (bridge->analyze_job != NULL) {
        if (bridge->analyze_job->state == TS_JOB_RUNNING) {
            ts_cancel_request(&bridge->analyze_job->cancel);
        }
        all[n++] = bridge->analyze_job;
    }
    for (i = 0; i < TS_BRIDGE_MAX_PROBE_JOBS; i++) {
        if (bridge->probe_jobs[i] != NULL) {
            if (bridge->probe_jobs[i]->state == TS_JOB_RUNNING) {
                ts_cancel_request(&bridge->probe_jobs[i]->cancel);
            }
            all[n++] = bridge->probe_jobs[i];
        }
    }
    LeaveCriticalSection(&bridge->lock);

    for (i = 0; i < n; i++) {
        if (all[i]->thread_started && all[i]->thread != NULL) {
            HANDLE thread = all[i]->thread;
            DWORD w = WaitForSingleObject(thread, TS_BRIDGE_SHUTDOWN_WAIT_MS);
            if (w != WAIT_OBJECT_0) {
                /*
                 * 线程仍未退出：**放弃释放**。宁可泄漏一块内存，
                 * 也不能让仍在运行的工作线程访问已释放的 TsBridge。
                 * Dart 侧先 shutdown_begin + 轮询 shutdown_ready 再 destroy，
                 * 正常路径不会走到这里。
                 */
                timed_out = 1;
                break;
            }
            CloseHandle(thread);
            all[i]->thread = NULL;
            all[i]->thread_started = 0;
        }
    }
    if (timed_out) {
        return;
    }

    EnterCriticalSection(&bridge->lock);
    for (i = 0; i < n; i++) {
        job_detach_locked(bridge, all[i]);
    }
    LeaveCriticalSection(&bridge->lock);

    for (i = 0; i < n; i++) {
        job_free(all[i]);
    }

    if (bridge->profiles_ready) {
        ts_profile_list_free(&bridge->profiles);
        bridge->profiles_ready = 0;
    }
    if (bridge->cfg_ready) {
        ts_config_free(&bridge->cfg);
        bridge->cfg_ready = 0;
    }
    ts_free(bridge->config_path);
    ts_free(bridge->data_dir);
    ts_free(bridge->settings_path);
    ts_free(bridge->settings_warning);
    if (bridge->lock_ready) {
        DeleteCriticalSection(&bridge->lock);
        bridge->lock_ready = 0;
    }
    ts_free(bridge);
}

