/*
 * analyze.c — 分析流程：组装提示词、调用模型、解析校验计划，带取消、退避重试与一次修复预算。
 *
 * 主要函数：ts_analyze_run、ts_analyze_run_ex、ts_analyze_result_init、ts_analyze_result_free。
 */

#include "analyze.h"
#include "prompt.h"
#include "model.h"
#include "plan.h"
#include "mem.h"

#include <stdio.h>
#include <string.h>

/* 重试退避：优先遵从服务器给出的 Retry-After，并设上限；等待期间可被取消。 */
#define TS_RETRY_MAX_WAIT_MS     30000
#define TS_RETRY_DEFAULT_WAIT_MS 500

void ts_analyze_result_init(TsAnalyzeResult *r)
{
    if (r == NULL) return;
    memset(r, 0, sizeof(*r));
    ts_plan_init(&r->plan);
}

void ts_analyze_result_free(TsAnalyzeResult *r)
{
    if (r == NULL) return;
    ts_plan_free(&r->plan);
    ts_free(r->error);
    ts_free(r->diag.last_error);
    memset(r, 0, sizeof(*r));
}

static void report(TsAnalyzeProgressFn fn, void *ud, const char *stage, const char *detail)
{
    if (fn != NULL) {
        fn(ud, stage, detail);
    }
}

static void set_error(TsAnalyzeResult *out, int kind, const char *msg)
{
    ts_free(out->error);
    out->error = ts_strdup((msg != NULL) ? msg : "未知错误");
    out->error_kind = kind;
    out->ok = 0;
}

static void set_diag_error(TsAnalyzeResult *out, int kind, const char *msg)
{
    ts_free(out->diag.last_error);
    out->diag.last_error = ts_strdup((msg != NULL) ? msg : "未知错误");
    out->diag.last_error_kind = kind;
}

/* 可取消的等待：返回非 0 表示等待期间被取消。 */
static int cancelable_wait(const TsCancel *cancel, int generation, long ms)
{
    long waited = 0;
    while (waited < ms) {
        long step = (ms - waited > 200) ? 200 : (ms - waited);
        if (ts_cancel_should_stop(cancel, generation)) return 1;
        ts_sleep_ms((unsigned)step);
        waited += step;
    }
    return ts_cancel_should_stop(cancel, generation) ? 1 : 0;
}

/* 模型正文为空 / 输出被截断，属于“可请求修复”的情况。 */
static int kind_repairable(int kind)
{
    return kind == TS_MODEL_ERR_EMPTY ||
           kind == TS_MODEL_ERR_TRUNCATED ||
           kind == TS_MODEL_ERR_PROTOCOL;
}

/* ------------------------------------------------------------------ */
/* 鉴权：请求前预检 + 失败后的诊断                                    */
/* ------------------------------------------------------------------ */

static const char *sys_str(const char *s, const char *fallback)
{
    return (s != NULL && s[0] != '\0') ? s : fallback;
}

/*
 * 组装“这次到底是按哪份配置、往哪个服务、用哪个环境变量发的请求”的摘要。
 *
 * 安全：只写端点摘要（已丢弃 userinfo 与查询串）与环境变量**名**，
 * 绝不写环境变量的值，也绝不写任何形式的密钥。
 * 进程是否有密钥只以“有/无”表示。
 */
static void build_auth_context(char *buf, size_t sz, const TsConfig *cfg, long http_status)
{
    char host[320];
    int has_key;
    int src;

    if (buf == NULL || sz == 0) return;
    ts_model_sanitize_endpoint(cfg->endpoint_url, host, sizeof(host));
    has_key = (cfg->api_key != NULL && cfg->api_key[0] != '\0') ? 1 : 0;
    src = ts_config_api_key_source(cfg);

    snprintf(buf, sz,
             "配置文件：%s\n"
             "接口主机：%s\n"
             "模型名称：%s\n"
             "密钥来源：%s\n"
             "密钥环境变量：%s\n"
             "当前进程是否读取到密钥：%s\n"
             "HTTP 状态码：%s",
             sys_str(cfg->config_path, "(未记录：配置不是从文件加载的)"),
             (host[0] != '\0') ? host : "(无法解析端点主机)",
             sys_str(cfg->model, "(未配置)"),
             (src == 1) ? "配置文件内联 api_key（明文，注意文件读取权限）"
                        : ((src == 2) ? "环境变量（推荐）"
                                      : "（当前没有可用密钥）"),
             sys_str(cfg->api_key_env, "(未配置)"),
             has_key ? "是" : "否",
             (http_status > 0) ? "见下方服务端返回" : "0（未发起请求）");
}

/*
 * 请求前鉴权预检。
 *
 * 目的：把“配置要求带密钥、但当前进程取不到密钥”这种情况在**发起请求之前**
 * 就变成明确的配置错误，而不是发一个不带 Authorization 的请求、
 * 再让服务端用 401 告诉我们“鉴权失败”。
 *
 * 兼容性：以下两种情况都视为“本服务无需鉴权”，一律放行——
 *   1) 配置里没有 api_key_env 字段（未声明）；
 *   2) 配置里 api_key_env 显式写成空字符串。
 * 只有“明确写了环境变量名”时才会要求密钥存在。
 */
static int auth_precheck(const TsConfig *cfg, TsAnalyzeResult *out)
{
    const char *fmt_err;

    if (!ts_config_requires_auth(cfg)) {
        return 0;   /* 未声明 / 显式声明无需鉴权：保持本地无鉴权服务可用 */
    }

    if (cfg->api_key == NULL || cfg->api_key[0] == '\0') {
        char detail[1400];
        build_auth_context(detail, sizeof(detail), cfg, 0);
        {
            char msg[1900];
            snprintf(msg, sizeof(msg),
                     "%s：配置要求提供密钥，但当前既没有内联 api_key，也读取不到环境变量 %s"
                     "（不存在或为空），因此在发出请求前就停止——不会发送无鉴权的云端请求。\n"
                     "%s\n"
                     "两种设置方式（任选其一）：\n"
                     "  1) 在配置文件的 \"api_key\" 字段直接填写（简单，但明文落盘）；\n"
                     "  2) 设置环境变量 %s（推荐），然后**重新启动本程序**"
                     "（Windows 上运行中的进程不会自动继承新变量）。",
                     ts_model_error_kind_name(TS_MODEL_ERR_CONFIG),
                     sys_str(cfg->api_key_env, "(未配置)"), detail,
                     sys_str(cfg->api_key_env, "(未配置)"));
            set_error(out, TS_MODEL_ERR_CONFIG, msg);
        }
        set_diag_error(out, TS_MODEL_ERR_CONFIG, "没有可用密钥（请求前预检拦截）");
        return 1;
    }

    /*
     * 密钥存在但格式可疑（首尾空白 / 控制字符 / 成对引号）：
     * 同样在请求前停下并说明原因。只报告“第几个位置的哪一类字符”，
     * 不截断、不替换、不修改密钥内容，也不回显密钥。
     */
    fmt_err = ts_config_api_key_format_error(cfg->api_key);
    if (fmt_err != NULL) {
        char detail[1400];
        build_auth_context(detail, sizeof(detail), cfg, 0);
        {
            char msg[1900];
            snprintf(msg, sizeof(msg),
                     "%s：环境变量 %s 的值存在可疑格式——%s。\n"
                     "为避免把格式错误的凭证发出去，已在请求前停止。\n"
                     "%s\n"
                     "请在本机核对并重新设置该环境变量，然后重新启动本程序。",
                     ts_model_error_kind_name(TS_MODEL_ERR_CONFIG),
                     cfg->api_key_env, fmt_err, detail);
            set_error(out, TS_MODEL_ERR_CONFIG, msg);
        }
        set_diag_error(out, TS_MODEL_ERR_CONFIG, "密钥格式可疑（请求前预检拦截）");
        return 1;
    }

    return 0;
}

/*
 * 服务端拒绝鉴权（401/403）时的最终提示。
 *
 * 措辞纪律：只陈述**已经证实**的事实（服务端返回了 401/403、我们确实带了密钥、
 * 环境变量名、目标主机），并列出可能原因；在没有更多证据前，
 * 不写成“密钥无效”这种结论性判断。
 * 同时明确说明不会自动重试，避免用户以为程序在反复消耗额度。
 */
static void build_auth_diag(char *buf, size_t sz, const TsConfig *cfg,
                            const char *server_msg, long http_status)
{
    char detail[1400];
    int has_key = (cfg->api_key != NULL && cfg->api_key[0] != '\0') ? 1 : 0;
    int src = ts_config_api_key_source(cfg);

    build_auth_context(detail, sizeof(detail), cfg, http_status);
    snprintf(buf, sz,
             "%s：服务端返回 HTTP %ld，鉴权未通过。\n"
             "%s\n"
             "服务端返回：%s\n"
             "请核对密钥与服务地址是否匹配：%s 里的密钥必须属于 %s 对应的账号，"
             "不能是其它服务的密钥。\n"
             "%s"
             "本次不会自动重试（401/403 属于终态错误，重试没有意义且会重复计费）。",
             ts_model_error_kind_name(TS_MODEL_ERR_AUTH),
             http_status, detail,
             sys_str(server_msg, "(无正文)"),
             (src == 1) ? "配置文件内联的 api_key"
                        : sys_str(cfg->api_key_env, "(未配置)"),
             sys_str(cfg->endpoint_url, "(未配置)"),
             has_key ? ""
                     : "注意：本次请求实际上没有带上 Authorization 头（当前没有可用密钥）。\n");
}

int ts_analyze_run(const TsConfig *cfg,
                   const char *user_request, const TsInputs *inputs,
                   const TsCancel *cancel, int generation,
                   TsAnalyzeProgressFn progress, void *progress_userdata,
                   TsAnalyzeResult *out)
{
    return ts_analyze_run_ex(cfg, user_request, NULL, inputs, cancel, generation,
                             progress, progress_userdata, out);
}

int ts_analyze_run_ex(const TsConfig *cfg,
                      const char *user_request, const char *plan_context,
                      const TsInputs *inputs,
                      const TsCancel *cancel, int generation,
                      TsAnalyzeProgressFn progress, void *progress_userdata,
                      TsAnalyzeResult *out)
{
    char errbuf[768];
    char *system_prompt = NULL;
    char *user_prompt = NULL;
    char *request = NULL;
    char *datetime = NULL;
    char *timezone = NULL;
    size_t request_len = 0;
    int budget;
    int rc = 1;
    int truncated_last = 0;   /* 上次输出是否因 token 上限被截断 */
    uint64_t start;

    if (out == NULL) return 1;
    ts_analyze_result_init(out);
    start = ts_clock_ms();

    if (cfg == NULL) {
        set_error(out, TS_MODEL_ERR_CONFIG, "配置为空");
        out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
        return 1;
    }

    /* 额外调用预算：网络重试与模型修复共用，最多一次。 */
    budget = (cfg->max_retry_attempts > 0) ? 1 : 0;

    /*
     * 请求前鉴权预检（mock 模式不需要密钥，直接跳过）。
     * 放在构建提示词之前：配置层面就发不出去的请求，不必先做无用功。
     */
    if (!cfg->mock_mode && auth_precheck(cfg, out) != 0) {
        out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
        return 1;
    }

    /* ---- 组装提示词与请求 ---- */
    report(progress, progress_userdata, "构建提示词", NULL);
    system_prompt = ts_prompt_build_system();
    datetime = ts_prompt_current_datetime();
    timezone = ts_prompt_timezone_name();
    if (system_prompt == NULL || datetime == NULL || timezone == NULL) {
        set_error(out, TS_MODEL_ERR_MEMORY, "内存分配失败");
        goto done;
    }

    if (ts_prompt_build_user_ex(user_request, plan_context, inputs, datetime, timezone,
                                cfg->max_input_bytes, &user_prompt, NULL,
                                errbuf, sizeof(errbuf)) != 0) {
        set_error(out, TS_MODEL_ERR_CONFIG, errbuf);
        goto done;
    }

    if (ts_prompt_build_request(cfg, system_prompt, user_prompt,
                                &request, &request_len,
                                errbuf, sizeof(errbuf)) != 0) {
        set_error(out, TS_MODEL_ERR_CONFIG, errbuf);
        goto done;
    }

    /* ---- 调用 → 解析 → （可选）修复/重试 循环 ---- */
    for (;;) {
        TsModelResult mr;
        char perr[512];
        int want_repair = 0;
        const char *repair_reason = NULL;

        if (ts_cancel_should_stop(cancel, generation)) {
            set_error(out, TS_MODEL_ERR_CANCELLED, "已取消本次分析（不会自动重试）");
            goto done;
        }

        perr[0] = '\0';
        report(progress, progress_userdata, "调用模型", NULL);
        ts_model_result_init(&mr);
        out->diag.attempts++;

        /*
         * 上次输出是否因 token 上限被截断。
         * 修复提示词要据此附加“精简表达”的指令——同样的预算原样重发，
         * 通常只会再被截断一次。
         */
        truncated_last = 0;

        if (ts_model_call(cfg, request, request_len, cancel, generation, &mr) != 0) {
            set_diag_error(out, mr.error_kind, mr.error);
            out->http_status = mr.http_status;
            if (mr.usage_present) {
                out->usage_present = 1;
                out->usage_prompt_tokens     = mr.usage_prompt_tokens;
                out->usage_completion_tokens = mr.usage_completion_tokens;
                out->usage_reasoning_tokens  = mr.usage_reasoning_tokens;
                out->usage_total_tokens      = mr.usage_total_tokens;
            }

            if (mr.error_kind == TS_MODEL_ERR_CANCELLED) {
                set_error(out, TS_MODEL_ERR_CANCELLED,
                          (mr.error != NULL) ? mr.error : "已取消");
                ts_model_result_free(&mr);
                goto done;
            }
            if (mr.error_kind == TS_MODEL_ERR_AUTH) {
                /*
                 * 鉴权失败是终态：给出“配置路径 + 主机 + 环境变量名 + 进程是否有密钥”
                 * 的完整诊断，并明确不重试。这里不接受任何“自动换地址/自动换密钥”的做法。
                 */
                char msg[2400];
                build_auth_diag(msg, sizeof(msg), cfg, mr.error, mr.http_status);
                set_error(out, TS_MODEL_ERR_AUTH, msg);
                ts_model_result_free(&mr);
                goto done;
            }
            if (mr.retryable && budget > 0 &&
                !ts_cancel_should_stop(cancel, generation)) {
                /*
                 * 退避后再重试：429 优先遵从服务器给出的 Retry-After，
                 * 否则用短暂退避。等待过程可被取消，且仍然只消耗那一次预算。
                 */
                long wait_ms = TS_RETRY_DEFAULT_WAIT_MS;
                char detail[192];
                if (mr.error_kind == TS_MODEL_ERR_RATE_LIMIT && mr.retry_after_ms > 0) {
                    wait_ms = mr.retry_after_ms;
                }
                if (wait_ms > TS_RETRY_MAX_WAIT_MS) wait_ms = TS_RETRY_MAX_WAIT_MS;
                budget--;
                /*
                 * 诊断必须记录“决定重试”这件事本身，而不是等重试再次失败才记录：
                 * 否则“第一次失败、第二次成功”的请求在诊断里看起来像一次成功调用，
                 * 无法解释服务端为何收到两次请求。
                 */
                out->diag.network_retried = 1;
                snprintf(detail, sizeof(detail), "%s（等待 %ld 毫秒后重试一次）",
                         (mr.error != NULL) ? mr.error : "可重试错误", wait_ms);
                report(progress, progress_userdata, "等待重试", detail);
                ts_model_result_free(&mr);
                if (cancelable_wait(cancel, generation, wait_ms)) {
                    set_error(out, TS_MODEL_ERR_CANCELLED, "已取消本次分析（等待重试期间）");
                    goto done;
                }
                continue;
            }
            if (kind_repairable(mr.error_kind) && budget > 0 &&
                !ts_cancel_should_stop(cancel, generation)) {
                want_repair = 1;
                truncated_last = (mr.error_kind == TS_MODEL_ERR_TRUNCATED) ? 1 : 0;
                snprintf(perr, sizeof(perr), "%s",
                         (mr.error != NULL) ? mr.error : "模型输出不可用");
                repair_reason = perr;
            } else {
                char msg[768];
                snprintf(msg, sizeof(msg), "%s：%s",
                         ts_model_error_kind_name(mr.error_kind),
                         (mr.error != NULL) ? mr.error : "未知错误");
                set_error(out, mr.error_kind, msg);
                ts_model_result_free(&mr);
                goto done;
            }
        } else {
            TsPlan plan;
            /* 成功拿到正文：先记下 token 用量，无论后面解析是否通过都要带出去 */
            if (mr.usage_present) {
                out->usage_present = 1;
                out->usage_prompt_tokens     = mr.usage_prompt_tokens;
                out->usage_completion_tokens = mr.usage_completion_tokens;
                out->usage_reasoning_tokens  = mr.usage_reasoning_tokens;
                out->usage_total_tokens      = mr.usage_total_tokens;
            }
            /*
             * 响应已完整到达，但用户在等待期间已经取消：不再解析、不采纳为成功结果。
             * 取消是终态；否则“接收完成 → 结果提交”这段窗口里的取消会被忽略，
             * 结果仍可能覆盖已有计划（审查报告 P2）。
             */
            if (ts_cancel_should_stop(cancel, generation)) {
                set_error(out, TS_MODEL_ERR_CANCELLED, "已取消本次分析（结果到达时已取消，未采纳）");
                ts_model_result_free(&mr);
                goto done;
            }
            ts_plan_init(&plan);
            if (ts_plan_parse(mr.body, mr.body_len, cfg, &plan,
                              perr, sizeof(perr)) == 0) {
                /* 提交前最后一道取消检查，确保取消与完成的竞争有明确边界 */
                if (ts_cancel_should_stop(cancel, generation)) {
                    ts_plan_free(&plan);
                    set_error(out, TS_MODEL_ERR_CANCELLED,
                              "已取消本次分析（解析完成时已取消，未采纳）");
                    ts_model_result_free(&mr);
                    goto done;
                }
                ts_plan_free(&out->plan);
                out->plan = plan; /* 所有权移交 */
                out->ok = 1;
                out->error_kind = TS_MODEL_OK;
                ts_model_result_free(&mr);
                report(progress, progress_userdata, "完成", NULL);
                rc = 0;
                goto done;
            }
            ts_plan_free(&plan);
            set_diag_error(out, TS_MODEL_ERR_PROTOCOL, perr);

            if (budget > 0 && !ts_cancel_should_stop(cancel, generation)) {
                want_repair = 1;
                repair_reason = perr;
            } else {
                char msg[768];
                snprintf(msg, sizeof(msg),
                         "模型输出校验失败（修复后仍不合格）：%s", perr);
                set_error(out, TS_MODEL_ERR_PROTOCOL, msg);
                ts_model_result_free(&mr);
                goto done;
            }
        }

        /* 针对性修复：附带错误说明与上次输出，要求只返回修正后的 JSON。 */
        if (want_repair) {
            char *repair_user = NULL;
            char *new_request = NULL;
            size_t new_request_len = 0;
            const char *previous_output = (mr.body != NULL) ? mr.body : "";

            budget--;
            out->diag.used_repair = 1;
            report(progress, progress_userdata, "修复", repair_reason);

            if (ts_prompt_build_repair_user(user_prompt, previous_output, repair_reason,
                                            truncated_last,
                                            &repair_user, NULL,
                                            errbuf, sizeof(errbuf)) != 0 ||
                ts_prompt_build_request(cfg, system_prompt, repair_user,
                                        &new_request, &new_request_len,
                                        errbuf, sizeof(errbuf)) != 0) {
                ts_free(repair_user);
                ts_free(new_request);
                ts_model_result_free(&mr);
                set_error(out, TS_MODEL_ERR_MEMORY, errbuf);
                goto done;
            }
            ts_free(repair_user);
            ts_free(request);
            request = new_request;
            request_len = new_request_len;
            ts_model_result_free(&mr);
            continue;
        }
    }

done:
    out->elapsed_ms = (long)ts_clock_elapsed_ms(start);
    ts_free(system_prompt);
    ts_free(user_prompt);
    ts_free(request);
    ts_free(datetime);
    ts_free(timezone);
    return rc;
}

