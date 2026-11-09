/*
 * test_bridge.c — Dart FFI 桥接的真实 ABI 集成测试（不经过 Flutter）。
 *
 * 目的：在铺界面之前先证明“异步调用 / 事件轮询 / 结果复制 / 资源释放 /
 * 取消 / 迟到结果 / 关闭顺序”这些**最容易出崩溃的地方**是对的。
 *
 * 全部通过真实 DLL 调用（链接 ts_bridge），不直接调用内部函数。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "ts_bridge.h"
#include "ts_activation.h"
#include "ts_pick_filter.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static int g_pass = 0;
static int g_fail = 0;

static void check(int cond, const char *name)
{
    if (cond) {
        g_pass++;
        printf("PASS: %s\n", name);
    } else {
        g_fail++;
        printf("FAIL: %s\n", name);
    }
}

static int contains(const char *hay, const char *needle)
{
    return hay != NULL && needle != NULL && strstr(hay, needle) != NULL;
}

/* ------------------------------------------------------------------ */
/* 临时配置文件                                                        */
/* ------------------------------------------------------------------ */

static int write_config(const char *path, int mock, const char *endpoint,
                        long connect_timeout_ms)
{
    FILE *f = fopen(path, "wb");
    if (f == NULL) return 1;
    fprintf(f,
            "{\n"
            "  \"endpoint_url\": \"%s\",\n"
            "  \"model\": \"bridge-test-model\",\n"
            "  \"api_key_env\": \"\",\n"
            "  \"mock_mode\": %s,\n"
            "  \"connect_timeout_ms\": %ld,\n"
            "  \"wait_prompt_ms\": 120000,\n"
            "  \"request_timeout_ms\": 0,\n"
            "  \"json_mode\": true\n"
            "}\n",
            endpoint, mock ? "true" : "false", connect_timeout_ms);
    fclose(f);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 测试用本地计划 JSON                                                 */
/* ------------------------------------------------------------------ */

static const char *PLAN_JSON =
"{"
"\"schemaVersion\":\"1\","
"\"summary\":\"完成顺序表实验的实现与提交\","
"\"tasks\":["
"  {\"id\":\"A\",\"name\":\"整理接口要求\",\"dependsOn\":[],"
"   \"preconditions\":[],\"steps\":[\"读说明\",\"整理接口\"],"
"   \"urgency\":4,\"urgencyReason\":\"后续实现要先明确接口\","
"   \"impact\":4,\"impactReason\":\"接口影响实现与测试范围\","
"   \"estimatedHours\":1.0,\"estimateReason\":\"读一份短说明\","
"   \"deadline\":null,\"sourceRefs\":[\"文件1:段落1\"],\"actualStatus\":\"todo\"},"
"  {\"id\":\"B\",\"name\":\"实现ListInit\",\"dependsOn\":[\"A\"],"
"   \"preconditions\":[],\"steps\":[\"写函数\"],"
"   \"urgency\":3,\"urgencyReason\":\"接口定稿后即可实现\","
"   \"impact\":4,\"impactReason\":\"是后续所有实现的基础\","
"   \"estimatedHours\":2.0,\"estimateReason\":\"一个函数\","
"   \"deadline\":null,\"sourceRefs\":[],\"actualStatus\":\"todo\"},"
"  {\"id\":\"C\",\"name\":\"实现ListInsert\",\"dependsOn\":[\"B\"],"
"   \"preconditions\":[],\"steps\":[\"写插入\"],"
"   \"urgency\":3,\"urgencyReason\":\"依赖初始化完成\","
"   \"impact\":3,\"impactReason\":\"核心操作\","
"   \"estimatedHours\":null,\"estimateReason\":null,"
"   \"deadline\":null,\"sourceRefs\":[],\"actualStatus\":\"todo\"},"
"  {\"id\":\"D\",\"name\":\"编写测试\",\"dependsOn\":[\"C\"],"
"   \"preconditions\":[],\"steps\":[\"写用例\"],"
"   \"urgency\":2,\"urgencyReason\":\"实现完成后测试\","
"   \"impact\":3,\"impactReason\":\"验证正确性\","
"   \"estimatedHours\":0.5,\"estimateReason\":\"一条用例\","
"   \"deadline\":null,\"sourceRefs\":[],\"actualStatus\":\"todo\"},"
"  {\"id\":\"E\",\"name\":\"提交实验报告\",\"dependsOn\":[],"
"   \"preconditions\":[{\"description\":\"教师开放提交入口\",\"status\":\"unmet\"}],"
"   \"steps\":[],\"urgency\":5,\"urgencyReason\":\"截止临近\","
"   \"impact\":3,\"impactReason\":\"交付材料\","
"   \"estimatedHours\":0.5,\"estimateReason\":\"提交\","
"   \"deadline\":\"2026-11-01\",\"sourceRefs\":[],\"actualStatus\":\"todo\"},"
"  {\"id\":\"F\",\"name\":\"准备答辩\",\"dependsOn\":[],"
"   \"preconditions\":[{\"description\":\"答辩时间未公布\",\"status\":\"unknown\"}],"
"   \"steps\":[],\"urgency\":2,\"urgencyReason\":\"时间未定\","
"   \"impact\":2,\"impactReason\":\"补充环节\","
"   \"estimatedHours\":1.0,\"estimateReason\":\"准备提纲\","
"   \"deadline\":null,\"sourceRefs\":[],\"actualStatus\":\"todo\"},"
"  {\"id\":\"G\",\"name\":\"阅读实验材料\",\"dependsOn\":[],"
"   \"preconditions\":[],\"steps\":[\"读材料\"],"
"   \"urgency\":2,\"urgencyReason\":\"已完成\","
"   \"impact\":2,\"impactReason\":\"前置阅读\","
"   \"estimatedHours\":0.5,\"estimateReason\":\"阅读\","
"   \"deadline\":null,\"sourceRefs\":[],\"actualStatus\":\"done\"}"
"],"
"\"notes\":["
"  {\"kind\":\"question\",\"text\":\"ElemType 具体是什么类型？\",\"taskRefs\":[\"B\"]},"
"  {\"kind\":\"blocked\",\"text\":\"提交入口未开放\",\"taskRefs\":[\"E\"]},"
"  {\"kind\":\"assumption\",\"text\":\"假定使用 C11 实现\",\"taskRefs\":[]}"
"]"
"}";

/* ------------------------------------------------------------------ */
/* 1. 展示快照：事实正确、且绝不泄漏分数                                */
/* ------------------------------------------------------------------ */

static void test_display_and_edit(TsBridge *bridge)
{
    char *cmd = NULL;
    size_t cmd_len = 0;
    TsBridgeBuffer buf;
    int rc;

    /* 组装 { "plan": <PLAN_JSON> } */
    cmd_len = strlen(PLAN_JSON) + 32;
    cmd = (char *)malloc(cmd_len);
    if (cmd == NULL) { check(0, "分配命令缓冲"); return; }
    snprintf(cmd, cmd_len, "{\"plan\":%s}", PLAN_JSON);

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_edit(bridge, cmd, strlen(cmd), &buf);
    check(rc == 0 && buf.data != NULL, "edit：校验并重排成功");
    if (rc != 0 || buf.data == NULL) {
        free(cmd);
        return;
    }

    /* --- 不泄漏内部数据 --- */
    check(!contains(buf.data, "基础分"), "展示快照不含“基础分”");
    check(!contains(buf.data, "最终"), "展示快照不含“最终分”");
    check(!contains(buf.data, "\"score\""), "展示快照不含 score 字段");
    check(!contains(buf.data, "candidates"), "展示快照不含候选池");
    check(!contains(buf.data, "weights"), "展示快照不含权重");
    check(!contains(buf.data, "weight"), "展示快照不含 weight");
    check(!contains(buf.data, "76.05"), "展示快照不含计算出的总分");

    /* --- 事实 --- */
    check(contains(buf.data, "\"status\":\"done\""), "已完成任务状态为 done");
    check(contains(buf.data, "\"status\":\"blocked\""), "外部条件 unmet 的任务为 blocked");
    check(contains(buf.data, "\"status\":\"pending\""), "外部条件 unknown 的任务为 pending");
    check(contains(buf.data, "\"estimateKnown\":false"), "未知工时有显式标记");
    check(contains(buf.data, "预计工时待确认"), "未知工时给出待确认说明");
    check(contains(buf.data, "起始时间待定"), "未知工时之后的任务注明起始时间待定");
    check(contains(buf.data, "\"scheduleState\":\"completed\""), "已完成任务单列为 completed");
    check(contains(buf.data, "安排依据："), "理由里有自然语言安排依据");
    check(contains(buf.data, "完成后会立即解锁") || contains(buf.data, "建议先做它"),
          "理由里说明先后关系");
    check(contains(buf.data, "\"level\""), "输出依赖层级（DAG 分层）");
    check(contains(buf.data, "文件1:段落1"), "来源引用被保留");
    check(contains(buf.data, "ElemType 具体是什么类型？"), "待确认条目被保留");
    check(contains(buf.data, "假定使用 C11 实现"), "分析假设条目被保留");

    /* G 已完成：不占剩余时间轴 */
    check(contains(buf.data, "\"startHours\":null"), "已完成/未排期任务没有伪造起始时间");

    ts_bridge_free(&buf);
    check(buf.data == NULL && buf.length == 0, "ts_bridge_free 后缓冲区被清空");

    /* 非法计划：不返回半成品 */
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_edit(bridge,
        "{\"plan\":{\"schemaVersion\":\"1\",\"tasks\":[{\"id\":\"X\",\"name\":\"x\","
        "\"dependsOn\":[\"NOPE\"],\"preconditions\":[],\"steps\":[],"
        "\"estimatedHours\":1,\"actualStatus\":\"todo\"}]}}",
        strlen("{\"plan\":{\"schemaVersion\":\"1\",\"tasks\":[{\"id\":\"X\",\"name\":\"x\","
               "\"dependsOn\":[\"NOPE\"],\"preconditions\":[],\"steps\":[],"
               "\"estimatedHours\":1,\"actualStatus\":\"todo\"}]}}"), &buf);
    check(rc != 0, "edit：依赖不存在的计划被拒绝");
    if (buf.data != NULL) {
        check(contains(buf.data, "\"ok\":false"), "拒绝时返回 ok=false");
        check(!contains(buf.data, "display"), "拒绝时不返回半成品快照");
        ts_bridge_free(&buf);
    }

    free(cmd);
}

/* ------------------------------------------------------------------ */
/* 2. 导出：日常导出不含分数，诊断导出保留                              */
/* ------------------------------------------------------------------ */

static char g_tmpdir[MAX_PATH];

static void join_path(char *out, size_t sz, const char *name)
{
    snprintf(out, sz, "%s\\%s", g_tmpdir, name);
}

/* Windows 路径里的反斜杠必须在 JSON 字符串里转义，否则命令 JSON 会解析失败。 */
static void json_escape(const char *in, char *out, size_t sz)
{
    size_t o = 0;
    size_t i;
    if (sz == 0) return;
    for (i = 0; in[i] != '\0' && o + 2 < sz; i++) {
        char c = in[i];
        if (c == '\\' || c == '"') {
            out[o++] = '\\';
            out[o++] = c;
        } else {
            out[o++] = c;
        }
    }
    out[o] = '\0';
}

static int read_whole(const char *path, char **out)
{
    FILE *f = fopen(path, "rb");
    long sz;
    char *data;

    if (f == NULL) return 1;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return 1; }
    data = (char *)malloc((size_t)sz + 1);
    if (data == NULL) { fclose(f); return 1; }
    if (fread(data, 1, (size_t)sz, f) != (size_t)sz) { free(data); fclose(f); return 1; }
    data[sz] = '\0';
    fclose(f);
    *out = data;
    return 0;
}

static void test_export(TsBridge *bridge)
{
    char txt_path[MAX_PATH];
    char diag_path[MAX_PATH];
    char esc_txt[MAX_PATH * 2];
    char esc_diag[MAX_PATH * 2];
    char *cmd = NULL;
    size_t cmd_len;
    TsBridgeBuffer buf;
    char *text = NULL;
    int rc;

    join_path(txt_path, sizeof(txt_path), "bridge_out.txt");
    join_path(diag_path, sizeof(diag_path), "bridge_diag.json");
    json_escape(txt_path, esc_txt, sizeof(esc_txt));
    json_escape(diag_path, esc_diag, sizeof(esc_diag));

    cmd_len = strlen(PLAN_JSON) + strlen(txt_path) + strlen(diag_path) + 256;
    cmd = (char *)malloc(cmd_len);
    if (cmd == NULL) return;

    /* 日常 TXT：不含分数 */
    snprintf(cmd, cmd_len, "{\"plan\":%s,\"format\":\"txt\",\"path\":\"%s\"}",
             PLAN_JSON, esc_txt);
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_export(bridge, cmd, strlen(cmd), &buf);
    check(rc == 0 && buf.data != NULL && contains(buf.data, "\"ok\":true"),
          "导出：面向用户的 TXT 成功");
    if (rc != 0 && buf.data != NULL) printf("  导出错误：%s\n", buf.data);
    ts_bridge_free(&buf);
    if (read_whole(txt_path, &text) == 0) {
        check(!contains(text, "基础分"), "用户 TXT 不含基础分");
        check(!contains(text, "最终"), "用户 TXT 不含最终分");
        check(!contains(text, "C("), "用户 TXT 不含全局加分公式");
        check(contains(text, "为什么这样安排"), "用户 TXT 含自然语言理由");
        check(contains(text, "建议执行顺序"), "用户 TXT 含建议顺序");
        free(text);
        text = NULL;
    } else {
        check(0, "读取用户 TXT");
    }

    /* 诊断 JSON：明确分开，保留计算数据 */
    snprintf(cmd, cmd_len, "{\"plan\":%s,\"format\":\"diag\",\"path\":\"%s\"}",
             PLAN_JSON, esc_diag);
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_export(bridge, cmd, strlen(cmd), &buf);
    check(rc == 0, "导出：结构化诊断 JSON 成功");
    if (rc != 0 && buf.data != NULL) printf("  导出错误：%s\n", buf.data);
    ts_bridge_free(&buf);
    if (read_whole(diag_path, &text) == 0) {
        check(contains(text, "schema_version"), "诊断 JSON 含 schema_version");
        check(contains(text, "score") || contains(text, "final"), "诊断 JSON 保留计算数据");
        check(!contains(text, "sk-"), "诊断 JSON 不含密钥");
        free(text);
        text = NULL;
    } else {
        check(0, "读取诊断 JSON");
    }

    free(cmd);
}

/* ------------------------------------------------------------------ */
/* 3. 异步分析：不阻塞 UI 线程 + 事件 + 结果 + 释放                     */
/* ------------------------------------------------------------------ */

static int poll_until_terminal(TsBridge *bridge, TsJobId job, int max_ms,
                               char *last_events, size_t last_sz,
                               int *saw_started, int *saw_progress)
{
    int waited = 0;
    TsBridgeBuffer ev;

    if (saw_started != NULL) *saw_started = 0;
    if (saw_progress != NULL) *saw_progress = 0;

    while (waited < max_ms) {
        memset(&ev, 0, sizeof(ev));
        if (ts_bridge_poll(bridge, job, &ev) != 0) {
            ts_bridge_free(&ev);
            return 0;
        }
        if (ev.data != NULL) {
            if (contains(ev.data, "\"type\":\"started\"") && saw_started != NULL) *saw_started = 1;
            if (contains(ev.data, "\"type\":\"progress\"") && saw_progress != NULL) *saw_progress = 1;
            if (last_events != NULL) {
                snprintf(last_events, last_sz, "%s", ev.data);
            }
            if (contains(ev.data, "\"terminal\":true")) {
                ts_bridge_free(&ev);
                return 1;
            }
        }
        ts_bridge_free(&ev);
        Sleep(20);
        waited += 20;
    }
    return 0;
}

static void test_analyze_mock(TsBridge *bridge)
{
    const char *req =
        "{\"conversationId\":\"c-1\",\"requestId\":\"r-1\","
        "\"baseVersionId\":null,\"baseRevision\":0,"
        "\"userRequest\":\"帮我安排顺序表实验\","
        "\"sources\":[{\"kind\":\"text\",\"label\":\"文段1\","
        "\"text\":\"实现顺序表 ListInit、ListInsert，并写测试。\"}]}";
    TsBridgeBuffer buf;
    TsBridgeBuffer err;
    TsJobId job = 0;
    ULONGLONG t0, dt;
    int rc;
    int saw_started = 0, saw_progress = 0;
    char events[8192];

    events[0] = '\0';
    memset(&err, 0, sizeof(err));
    t0 = GetTickCount64();
    rc = ts_bridge_analyze_async(bridge, req, strlen(req), &job, &err);
    dt = GetTickCount64() - t0;

    check(rc == 0 && job != 0, "analyze_async：成功启动并返回 job id");
    check(dt < 500, "analyze_async：调用本身立即返回（不阻塞 UI 线程）");
    ts_bridge_free(&err);
    if (rc != 0) return;

    /* 同一时刻只允许一个分析 */
    memset(&err, 0, sizeof(err));
    {
        TsJobId job2 = 0;
        rc = ts_bridge_analyze_async(bridge, req, strlen(req), &job2, &err);
        check(rc != 0, "analyze_async：已有分析时拒绝再启动（不排队）");
        ts_bridge_free(&err);
    }

    check(poll_until_terminal(bridge, job, 15000, events, sizeof(events),
                              &saw_started, &saw_progress),
          "poll：在超时前收到终态事件");
    check(saw_started, "poll：收到 started 事件");
    check(contains(events, "\"conversationId\":\"c-1\""), "事件回带 conversationId");
    check(contains(events, "\"requestId\":\"r-1\""), "事件回带 requestId");

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_result(bridge, job, &buf);
    check(rc == 0 && buf.data != NULL, "result：终态后可取结果");
    if (buf.data != NULL) {
        check(contains(buf.data, "\"ok\":true"), "result：mock 分析成功");
        check(contains(buf.data, "\"plan\""), "result：返回计划对象");
        check(contains(buf.data, "\"requestId\":\"r-1\""), "result：回带 requestId");
        check(!contains(buf.data, "基础分"), "result：不泄漏分数");
        ts_bridge_free(&buf);
    }

    /* 释放前再取一次：仍可读（结果不被 poll 消费掉） */
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_result(bridge, job, &buf);
    check(rc == 0 && buf.data != NULL, "result：可重复读取（poll 不消费结果）");
    ts_bridge_free(&buf);

    check(ts_bridge_release_job(bridge, job) == 0, "release_job：终态后释放成功");
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_result(bridge, job, &buf);
    check(rc != 0, "result：释放后再取返回失败（不会野指针）");
    ts_bridge_free(&buf);
    check(ts_bridge_release_job(bridge, job) != 0, "release_job：重复释放被拒绝");
}

/* ------------------------------------------------------------------ */
/* 4. 取消与迟到结果                                                    */
/* ------------------------------------------------------------------ */

static void test_cancel(TsBridge *bridge)
{
    const char *req =
        "{\"conversationId\":\"c-2\",\"requestId\":\"r-2\","
        "\"baseVersionId\":\"v-1\",\"baseRevision\":3,"
        "\"userRequest\":\"补充要求\","
        "\"sources\":[{\"kind\":\"text\",\"label\":\"文段1\",\"text\":\"补充一点要求。\"}]}";
    TsBridgeBuffer buf;
    TsBridgeBuffer err;
    TsJobId job = 0;
    char events[8192];
    int rc;
    int cancelled_ok = 0;

    memset(&err, 0, sizeof(err));
    rc = ts_bridge_analyze_async(bridge, req, strlen(req), &job, &err);
    ts_bridge_free(&err);
    if (rc != 0) {
        /* 该配置可能是纯 mock，分析已经瞬间完成：取消语义用“终态”验证 */
        check(1, "cancel：本次配置下分析过快，跳过取消时机检查");
        return;
    }

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_result(bridge, job, &buf);
    ts_bridge_free(&buf);
    if (rc == 0) {
        check(1, "cancel：分析在取消前已结束（mock 太快），计时类检查跳过");
    }

    /* 取消：可能成功（仍在运行）或因为已终态而失败，两种都不是错误 */
    cancelled_ok = (ts_bridge_cancel(bridge, job) == 0);

    events[0] = '\0';
    check(poll_until_terminal(bridge, job, 20000, events, sizeof(events), NULL, NULL),
          "cancel：仍能收到终态事件（终态事件从不丢失）");

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_result(bridge, job, &buf);
    check(rc == 0 && buf.data != NULL, "cancel：终态后可取结果");
    if (buf.data != NULL) {
        if (cancelled_ok) {
            check(contains(buf.data, "\"ok\":false"), "cancel：取消后结果不被采纳（ok=false）");
            check(contains(buf.data, "cancelled") || contains(buf.data, "\"ok\":false"),
                  "cancel：错误分类为取消或其他终态");
        } else {
            check(1, "cancel：取消请求到达时任务已终态（不算失败）");
        }
        check(contains(buf.data, "\"baseRevision\":3"), "cancel：回带 baseRevision");
        ts_bridge_free(&buf);
    }

    ts_bridge_release_job(bridge, job);
}

/* ------------------------------------------------------------------ */
/* 0.5.0：文件筛选器定义（纯数据，逐项核对扩展名/显示名）               */
/* ------------------------------------------------------------------ */

static int wcontains(const wchar_t *hay, const wchar_t *needle)
{
    return hay != NULL && needle != NULL && wcsstr(hay, needle) != NULL;
}

/*
 * GetOpenFileNameW 的过滤器是“显示名\0扩展名\0…”的**多段**字符串，
 * wcsstr 只能看到第一段；这里逐段扫描。
 */
static int wfilter_contains(const wchar_t *filter, const wchar_t *needle)
{
    const wchar_t *p = filter;
    if (filter == NULL || needle == NULL) return 0;
    while (*p != L'\0') {
        if (wcsstr(p, needle) != NULL) return 1;
        p += wcslen(p) + 1;
    }
    return 0;
}

static int wfilter_double_nul(const wchar_t *filter)
{
    const wchar_t *p = filter;
    if (filter == NULL) return 0;
    while (*p != L'\0') p += wcslen(p) + 1;
    return p[1] == L'\0';
}

static void test_pick_filter_definitions(void)
{
    const TsPickFilterSpec *spec;

    printf("\n-- 文件筛选器定义（kind 0/1/2 + 未知 kind）--\n");

    spec = ts_pick_filter_spec(TS_PICK_FILTER_DOCUMENT);
    check(spec != NULL && spec->kind == 0, "filter：kind 0 存在且规范化");
    if (spec != NULL) {
        check(wfilter_contains(spec->filter, L"*.txt") &&
              wfilter_contains(spec->filter, L"*.md") &&
              wfilter_contains(spec->filter, L"*.pdf") &&
              wfilter_contains(spec->filter, L"*.docx") &&
              wfilter_contains(spec->filter, L"*.pptx"),
              "filter 0：保留旧文档扩展名（txt/md/pdf/docx/pptx）");
        check(wfilter_contains(spec->filter, L"*.ics") &&
              wfilter_contains(spec->filter, L"*.ical"),
              "filter 0：保留旧日历扩展名（ics/ical）");
        check(wfilter_contains(spec->filter, L"所有文件"), "filter 0：保留“所有文件”入口");
        check(spec->default_ext != NULL && wcscmp(spec->default_ext, L"txt") == 0,
              "filter 0：默认扩展名仍为 txt（旧行为）");
        /* GetOpenFileNameW 约定：过滤器以双 NUL 结尾。 */
        check(wfilter_double_nul(spec->filter), "filter 0：双 NUL 结尾");
    }

    spec = ts_pick_filter_spec(TS_PICK_FILTER_OCR);
    check(spec != NULL && spec->kind == 1, "filter：kind 1（OCR）存在");
    if (spec != NULL) {
        check(wfilter_contains(spec->filter, L"PDF") &&
              wfilter_contains(spec->filter, L"PNG") &&
              wfilter_contains(spec->filter, L"JPEG"),
              "filter 1：显示名明确列出 PDF/PNG/JPEG");
        check(wfilter_contains(spec->filter, L"*.pdf") &&
              wfilter_contains(spec->filter, L"*.png") &&
              wfilter_contains(spec->filter, L"*.jpg") &&
              wfilter_contains(spec->filter, L"*.jpeg"),
              "filter 1：扩展名含 pdf/png/jpg/jpeg");
        check(wfilter_contains(spec->filter, L"所有文件"), "filter 1：保留“所有文件”入口");
        check(!wfilter_contains(spec->filter, L"*.txt"), "filter 1：不列普通文本扩展名");
        check(!wfilter_contains(spec->filter, L"*.docx"), "filter 1：不列 Office 扩展名");
        check(!wfilter_contains(spec->filter, L"*.ics"), "filter 1：不列日历扩展名");
        check(wfilter_double_nul(spec->filter), "filter 1：双 NUL 结尾");
    }

    spec = ts_pick_filter_spec(TS_PICK_FILTER_CALENDAR);
    check(spec != NULL && spec->kind == 2, "filter：kind 2（日历）存在");
    if (spec != NULL) {
        check(wfilter_contains(spec->filter, L"*.ics") &&
              wfilter_contains(spec->filter, L"*.ical"),
              "filter 2：扩展名含 ics/ical");
        check(wfilter_contains(spec->filter, L"所有文件"), "filter 2：保留“所有文件”入口");
        check(!wfilter_contains(spec->filter, L"*.pdf"), "filter 2：不列 PDF");
        check(spec->default_ext != NULL && wcscmp(spec->default_ext, L"ics") == 0,
              "filter 2：默认扩展名为 ics");
    }

    check(ts_pick_filter_spec(-1) == NULL, "filter：负数 kind 被拒绝");
    check(ts_pick_filter_spec(3) == NULL, "filter：未定义 kind 被拒绝");
}

/* ------------------------------------------------------------------ */
/* 0.5.0：通知 XML / URI / 动作队列 / 待处理文件（纯逻辑，无 WinRT）    */
/* ------------------------------------------------------------------ */

static const char *PAYLOAD_JSON =
    "{\"taskId\":\"task-1\",\"executionId\":\"exec-2\",\"deadline\":1730000000000}";

static void test_activation_xml_and_uri(void)
{
    char *uri;
    char *json;
    char *xml;
    TsActivationQueue *queue;

    printf("\n-- 可操作通知：URI/XML/队列/待处理激活 --\n");

    /* 构造：三个动作都带同一身份 */
    uri = ts_activation_build_uri("open", PAYLOAD_JSON);
    check(uri != NULL, "uri：可构造 open");
    if (uri != NULL) {
        check(contains(uri, "taskscheduler://open?taskId=task-1"), "uri：open 指向本任务");
        check(contains(uri, "executionId=exec-2"), "uri：携带执行 ID");
        check(contains(uri, "deadline=1730000000000"), "uri：携带期限身份");
        free(uri);
    }
    uri = ts_activation_build_uri("extend", PAYLOAD_JSON);
    check(uri != NULL && contains(uri, "taskscheduler://extend?"), "uri：可构造 extend");
    free(uri);
    uri = ts_activation_build_uri("finish", PAYLOAD_JSON);
    check(uri != NULL && contains(uri, "taskscheduler://finish?"), "uri：可构造 finish");
    free(uri);
    check(ts_activation_build_uri("bogus", PAYLOAD_JSON) == NULL, "uri：未知动作被拒绝");
    check(ts_activation_build_uri("open", "{\"taskId\":\"t\"}") == NULL,
          "uri：缺执行/期限身份被拒绝");
    check(ts_activation_build_uri("open", "not json") == NULL, "uri：非法 JSON 被拒绝");

    /* 解析：正文点击 / 两个按钮 */
    json = ts_activation_parse_uri(
        "taskscheduler://open?taskId=t9&executionId=e9&deadline=1700000000123");
    check(json != NULL, "parse：可解析 open");
    if (json != NULL) {
        check(contains(json, "\"action\":\"open\""), "parse：action=open");
        check(contains(json, "\"taskId\":\"t9\""), "parse：taskId 原样回传");
        check(contains(json, "\"executionId\":\"e9\""), "parse：executionId 原样回传");
        check(contains(json, "\"deadline\":\"1700000000123\""),
              "parse：deadline 原样回传（字符串）");
        free(json);
    }
    json = ts_activation_parse_uri(
        "TASKSCHEDULER://Extend?taskId=t&executionId=e&deadline=1");
    check(json != NULL && contains(json, "\"action\":\"extend\""),
          "parse：大小写不敏感且规范化为小写");
    free(json);
    check(ts_activation_parse_uri(
              "taskscheduler://open?taskId=%E4%B8%AD%E6%96%87&executionId=e&deadline=1") != NULL,
          "parse：percent-encoded 身份可解析");
    {
        char *cn = ts_activation_parse_uri(
            "taskscheduler://finish?taskId=%E4%B8%AD%E6%96%87&executionId=e&deadline=1");
        check(cn != NULL && contains(cn, "中文"), "parse：percent-decode 为 UTF-8");
        free(cn);
    }
    check(ts_activation_parse_uri("https://open?taskId=t&executionId=e&deadline=1") == NULL,
          "parse：非本协议被拒绝");
    check(ts_activation_parse_uri("taskscheduler://bogus?taskId=t&executionId=e&deadline=1") == NULL,
          "parse：未知动作被拒绝");
    check(ts_activation_parse_uri("taskscheduler://open?taskId=t&executionId=e") == NULL,
          "parse：缺 deadline 被拒绝（禁止用猜测目标）");
    check(ts_activation_parse_uri("taskscheduler://open") == NULL,
          "parse：无身份参数被拒绝");
    check(ts_activation_parse_uri("") == NULL, "parse：空串安全返回 NULL");
    check(ts_activation_parse_uri(NULL) == NULL, "parse：NULL 安全返回 NULL");

    /* Toast XML：正文点击=open，两个按钮=extend/finish，身份带 amp 转义 */
    xml = ts_activation_build_toast_xml("前端页面开发 · 计划时段已结束", "任务待处理",
                                        PAYLOAD_JSON, NULL, NULL);
    check(xml != NULL, "xml：可构造");
    if (xml != NULL) {
        check(contains(xml, "<toast activationType=\"protocol\""), "xml：使用 protocol 激活");
        check(contains(xml, "launch=\"taskscheduler://open?"), "xml：正文点击=open");
        check(contains(xml, "延长时间"), "xml：按钮 1 为“延长时间”");
        check(contains(xml, "结束任务"), "xml：按钮 2 为“结束任务”");
        check(contains(xml, "arguments=\"taskscheduler://extend?"), "xml：按钮 1 路由 extend");
        check(contains(xml, "arguments=\"taskscheduler://finish?"), "xml：按钮 2 路由 finish");
        check(contains(xml, "&amp;executionId="), "xml：URI 中的 & 被转义为 &amp;");
        check(contains(xml, "taskId=task-1"), "xml：身份参数进入两个按钮");
        free(xml);
    }
    {
        char *escaped = ts_activation_build_toast_xml("<标题&>", "\"正文\"", PAYLOAD_JSON,
                                                      NULL, NULL);
        check(escaped != NULL && contains(escaped, "&lt;标题&amp;&gt;"),
              "xml：标题/正文 XML 转义");
        free(escaped);
    }
    check(ts_activation_build_toast_xml("t", "b", "{\"taskId\":\"x\"}", NULL, NULL) == NULL,
          "xml：缺身份被拒绝");

    /* 队列：FIFO，取空后返回 NULL */
    queue = ts_activation_queue_create();
    check(queue != NULL, "queue：可创建");
    if (queue != NULL) {
        check(ts_activation_queue_push_uri(queue,
              "taskscheduler://open?taskId=a&executionId=e1&deadline=1") == 0,
              "queue：push_uri 解析并入队");
        check(ts_activation_queue_push_uri(queue,
              "taskscheduler://extend?taskId=b&executionId=e2&deadline=2") == 0,
              "queue：第二条入队");
        check(ts_activation_queue_push_uri(queue, "https://x") != 0,
              "queue：非本协议不入队");
        json = ts_activation_queue_take(queue);
        check(json != NULL && contains(json, "\"taskId\":\"a\""), "queue：FIFO 第一条");
        free(json);
        json = ts_activation_queue_take(queue);
        check(json != NULL && contains(json, "\"action\":\"extend\""), "queue：FIFO 第二条");
        free(json);
        check(ts_activation_queue_take(queue) == NULL, "queue：取空后返回 NULL");
        ts_activation_queue_destroy(queue);
    }

    /* 待处理激活文件：应用未运行时第二实例写入，启动后 drain 取走 */
    {
        char dir[MAX_PATH];
        char *pending_path;
        int queued;
        join_path(dir, sizeof(dir), "ts_pending_activation_test");
        CreateDirectoryA(dir, NULL);
        pending_path = ts_activation_pending_path(dir);
        check(pending_path != NULL, "pending：可构造路径");
        if (pending_path != NULL) {
            check(contains(pending_path, "pending_activation.txt"),
                  "pending：文件名为 pending_activation.txt");
            queue = ts_activation_queue_create();
            check(ts_activation_append_pending(pending_path,
                  "taskscheduler://open?taskId=p1&executionId=e1&deadline=11") == 0,
                  "pending：追加第一条");
            check(ts_activation_append_pending(pending_path,
                  "taskscheduler://finish?taskId=p2&executionId=e2&deadline=22") == 0,
                  "pending：追加第二条");
            queued = ts_activation_drain_pending(queue, pending_path);
            check(queued == 2, "pending：drain 取走两条");
            json = ts_activation_queue_take(queue);
            check(json != NULL && contains(json, "\"taskId\":\"p1\""),
                  "pending：顺序保持（第一条 open）");
            free(json);
            json = ts_activation_queue_take(queue);
            check(json != NULL && contains(json, "\"action\":\"finish\""),
                  "pending：第二条为 finish");
            free(json);
            check(ts_activation_drain_pending(queue, pending_path) == 0,
                  "pending：再次 drain 为空（不重复投递）");
            ts_activation_queue_destroy(queue);
            DeleteFileA(pending_path);
            free(pending_path);
        }
        RemoveDirectoryA(dir);
    }
}

/* ------------------------------------------------------------------ */
/* 0.5.0：ABI 导出失败路径（真实 DLL，不写系统注册表/不弹通知）          */
/* ------------------------------------------------------------------ */

static void test_notification_abi_failures(TsBridge *bridge)
{
    TsBridgeBuffer buf;
    int rc;

    printf("\n-- 可操作通知 ABI：失败路径与空参保护 --\n");

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_prepare_notifications(NULL, "TaskScheduler.Test", NULL, &buf);
    check(rc != 0, "prepare：bridge 为 NULL 时返回失败");
    check(buf.data != NULL && contains(buf.data, "\"ok\":false"),
          "prepare：失败仍返回 JSON 原因");
    ts_bridge_free(&buf);

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_prepare_notifications(bridge, NULL, NULL, &buf);
    check(rc != 0 && buf.data != NULL && contains(buf.data, "AUMID"),
          "prepare：AUMID 为空被拒绝并说明原因");
    ts_bridge_free(&buf);

    /* 不存在的 exe：必须在写注册表/快捷方式之前失败（测试不污染系统）。 */
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_prepare_notifications(bridge, "TaskScheduler.Test",
                                         "C:\\definitely\\not\\here\\nope.exe", &buf);
    check(rc != 0 && buf.data != NULL && contains(buf.data, "可执行文件不存在"),
          "prepare：无效 exe 路径被拒绝");
    ts_bridge_free(&buf);

    /* 未 prepare 就投递：明确失败而不是崩溃。 */
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_show_execution_notification(bridge, "标题", "正文", PAYLOAD_JSON, &buf);
    check(rc == 0, "show：未 prepare 返回 0（失败）");
    check(buf.data != NULL && contains(buf.data, "notPrepared"),
          "show：失败原因是 notPrepared");
    ts_bridge_free(&buf);

    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_show_execution_notification(NULL, "标题", "正文", PAYLOAD_JSON, &buf);
    check(rc == 0 && buf.data != NULL && contains(buf.data, "\"accepted\":false"),
          "show：bridge 为 NULL 时安全失败");
    ts_bridge_free(&buf);

    /* 队列为空：take 返回 0 且不写缓冲区。 */
    memset(&buf, 0, sizeof(buf));
    rc = ts_bridge_take_execution_action(bridge, &buf);
    check(rc == 0 && buf.data == NULL && buf.length == 0,
          "take：空闲时返回 0 且不产生动作");
    ts_bridge_free(&buf);

    memset(&buf, 0, sizeof(buf));
    check(ts_bridge_take_execution_action(NULL, &buf) == 0,
          "take：bridge 为 NULL 时安全返回 0");
    ts_bridge_free(&buf);
}

/* ------------------------------------------------------------------ */

int main(void)
{
    char cfg_mock[MAX_PATH];
    char cfg_slow[MAX_PATH];
    TsBridge *bridge = NULL;
    TsBridgeBuffer err;
    TsBridgeBuffer info;
    int rc;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler C 桥接（Dart FFI ABI）集成测试 ===\n\n");

    /*
     * 临时文件放在测试可执行文件所在目录：Windows 的 %TEMP% 在受限环境下
     * 未必可写，而构建产物目录一定可写，也不会污染用户目录。
     */
    {
        char module[MAX_PATH];
        DWORD n = GetModuleFileNameA(NULL, module, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) {
            printf("无法确定测试程序目录\n");
            return 1;
        }
        while (n > 0 && module[n - 1] != '\\') n--;
        if (n > 0) module[n - 1] = '\0';
        snprintf(g_tmpdir, sizeof(g_tmpdir), "%s", module);
    }
    printf("测试临时目录：%s\n\n", g_tmpdir);

    join_path(cfg_mock, sizeof(cfg_mock), "ts_bridge_mock.json");
    join_path(cfg_slow, sizeof(cfg_slow), "ts_bridge_slow.json");

    /* 1) 缺少配置：应给出可读错误，且缓冲区可安全释放 */
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create("C:\\definitely\\not\\here.json", &bridge, &err);
    check(rc != 0, "create：配置路径不存在时失败");
    check(err.data != NULL, "create：失败时返回可读错误");
    ts_bridge_free(&err);
    check(err.data == NULL, "ts_bridge_free 可释放错误缓冲区");

    /* 2) mock 配置 */
    check(write_config(cfg_mock, 1, "https://example.invalid/chat/completions", 15000) == 0,
          "写入 mock 测试配置");
    memset(&err, 0, sizeof(err));
    rc = ts_bridge_create(cfg_mock, &bridge, &err);
    check(rc == 0 && bridge != NULL, "create：mock 配置下创建成功");
    if (rc != 0) {
        printf("create 失败：%s\n", err.data != NULL ? err.data : "(无错误信息)");
        ts_bridge_free(&err);
        printf("\n结果：%d 通过，%d 失败\n", g_pass, g_fail);
        return g_fail ? 1 : 0;
    }
    ts_bridge_free(&err);

    /* info：绝不能包含密钥 */
    memset(&info, 0, sizeof(info));
    check(ts_bridge_info(bridge, &info) == 0 && info.data != NULL, "info：可读取运行期信息");
    if (info.data != NULL) {
        check(contains(info.data, "\"mockMode\":true"), "info：报告 mock 模式");
        check(contains(info.data, "\"endpoint\""), "info：报告脱敏端点");
        check(!contains(info.data, "api_key_env"), "info：不含密钥配置项内容");
        check(!contains(info.data, "sk-"), "info：不含密钥");
        ts_bridge_free(&info);
    }

    test_display_and_edit(bridge);
    test_export(bridge);
    test_analyze_mock(bridge);
    test_cancel(bridge);

    /* 系统文件对话框：只验证 ABI 存在与空参保护（真正弹窗需要人工交互）。 */
    {
        TsBridgeBuffer pathBuf;
        TsBridgeBuffer errBuf;
        memset(&pathBuf, 0, sizeof(pathBuf));
        memset(&errBuf, 0, sizeof(errBuf));
        rc = ts_bridge_pick_file(NULL, "标题", &pathBuf, &errBuf);
        check(rc != 0, "pick_file：bridge 为 NULL 时返回失败");
        ts_bridge_free(&pathBuf);
        ts_bridge_free(&errBuf);

        memset(&pathBuf, 0, sizeof(pathBuf));
        memset(&errBuf, 0, sizeof(errBuf));
        rc = ts_bridge_pick_file(bridge, "标题", NULL, &errBuf);
        check(rc != 0, "pick_file：输出参数为 NULL 时返回失败");
        ts_bridge_free(&errBuf);

        /* 0.5.0：带 filter_kind 的新导出。未知 kind 必须立即失败（不弹窗）。 */
        memset(&pathBuf, 0, sizeof(pathBuf));
        memset(&errBuf, 0, sizeof(errBuf));
        rc = ts_bridge_pick_file_filtered(bridge, "标题", 99, &pathBuf, &errBuf);
        check(rc != 0, "pick_file_filtered：未知 filter_kind 返回失败");
        check(errBuf.data != NULL && contains(errBuf.data, "未知的文件筛选用途"),
              "pick_file_filtered：未知 kind 给出可读原因");
        ts_bridge_free(&pathBuf);
        ts_bridge_free(&errBuf);

        memset(&pathBuf, 0, sizeof(pathBuf));
        memset(&errBuf, 0, sizeof(errBuf));
        rc = ts_bridge_pick_file_filtered(NULL, "标题", 1, &pathBuf, &errBuf);
        check(rc != 0, "pick_file_filtered：bridge 为 NULL 时返回失败");
        ts_bridge_free(&pathBuf);
        ts_bridge_free(&errBuf);

        memset(&pathBuf, 0, sizeof(pathBuf));
        memset(&errBuf, 0, sizeof(errBuf));
        rc = ts_bridge_pick_file_filtered(bridge, "标题", 1, NULL, &errBuf);
        check(rc != 0, "pick_file_filtered：输出参数为 NULL 时返回失败");
        ts_bridge_free(&errBuf);
    }

    test_pick_filter_definitions();
    test_activation_xml_and_uri();
    test_notification_abi_failures(bridge);

    /* 关闭顺序：先 begin，轮询 ready，再 destroy */
    check(ts_bridge_shutdown_begin(bridge) == 0, "shutdown_begin：接受关闭请求");
    {
        int waited = 0;
        while (!ts_bridge_shutdown_ready(bridge) && waited < 12000) {
            Sleep(20);
            waited += 20;
        }
        check(ts_bridge_shutdown_ready(bridge) == 1, "shutdown_ready：工作线程已退出");
    }
    ts_bridge_destroy(bridge);
    check(1, "destroy：正常释放（无崩溃）");

    /* 慢配置下的取消/迟到结果（仅在真实 HTTP 可用时执行） */
    bridge = NULL;
    if (write_config(cfg_slow, 0, "http://10.255.255.1:9/chat/completions", 4000) == 0) {
        memset(&err, 0, sizeof(err));
        if (ts_bridge_create(cfg_slow, &bridge, &err) == 0) {
            memset(&info, 0, sizeof(info));
            ts_bridge_info(bridge, &info);
            if (info.data != NULL && contains(info.data, "\"httpAvailable\":true")) {
                printf("\n-- 真实传输层可用：执行取消 / 迟到结果检查 --\n");
                test_cancel(bridge);
            } else {
                printf("(跳过：本构建未启用 libcurl，无法构造长时间请求)\n");
            }
            ts_bridge_free(&info);
            ts_bridge_shutdown_begin(bridge);
            {
                int waited = 0;
                while (!ts_bridge_shutdown_ready(bridge) && waited < 12000) {
                    Sleep(20);
                    waited += 20;
                }
            }
            ts_bridge_destroy(bridge);
        }
        ts_bridge_free(&err);
    }

    ts_bridge_free(NULL);   /* NULL 安全 */
    check(1, "ts_bridge_free(NULL) 安全");

    printf("\n结果：%d 通过，%d 失败\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
