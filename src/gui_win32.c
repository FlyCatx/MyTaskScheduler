/*
 * gui_win32.c — Win32 Unicode 主界面：顶部操作区、状态区、下一步卡片、任务列表与详情；
 * 工作线程通过 PostMessage 通知主线程，不直接操作控件。
 *
 * 主要函数：ts_gui_run、ts_gui_run_ex。
 */


#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>

#include "gui_win32.h"
#include "controller.h"
#include "export.h"
#include "plan.h"
#include "mem.h"
#include "text.h"

#include <stdio.h>
#include <string.h>
#include <wchar.h>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' " \
                        "version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

/* ------------------------------------------------------------------ */
/* 常量与全局                                                          */
/* ------------------------------------------------------------------ */

#define TS_WM_NOTIFY        (WM_APP + 1)
/* 非交互验收模式：窗口与通知回调都就绪后再启动分析。 */
#define TS_WM_AUTOSTART     (WM_APP + 2)

#define IDC_BTN_ADDFILE     1001
#define IDC_BTN_ADDTEXT     1002
#define IDC_BTN_START       1003
#define IDC_BTN_CANCEL      1004
#define IDC_CHK_GROUP       1005
#define IDC_BTN_EXPORT      1006
#define IDC_ST_STATUS       1010
#define IDC_ST_NEXT1        1011
#define IDC_ST_NEXT2        1012
#define IDC_ST_NEXT3        1013
#define IDC_LV_TASKS        1020
#define IDC_ED_DETAIL       1021
#define IDC_ST_RELATED      1022
#define IDC_LB_RELATED      1023
#define IDC_ST_BLOCKED      1024
#define IDC_ED_BLOCKED      1025
#define IDC_BTN_DONE        1030
#define IDC_BTN_EDITF       1031
#define IDC_BTN_EDITD       1032
#define IDC_BTN_EDITP       1033

#define IDC_TIMER_STATUS    1

#define IDC_WAIT_TEXT       1101
#define IDC_WAIT_CONTINUE   1102
#define IDC_WAIT_CANCEL     1103

#define IDC_DLG_CYCLE       1201

#define DLG_FIELDS  1
#define DLG_DEPS    2
#define DLG_PREC    3
#define DLG_TEXTIN  4

typedef struct TsGui {
    HINSTANCE inst;
    HWND hwnd;
    const TsConfig *cfg;
    TsController *ctrl;

    HWND btn_addfile, btn_addtext, btn_start, btn_cancel, btn_export, chk_group;
    HWND st_status, st_next[3];
    HWND lv_tasks;
    HWND ed_detail, st_related, lb_related, st_blocked, ed_blocked;
    HWND btn_done, btn_editf, btn_editd, btn_editp;

    HFONT font_ui, font_bold;
    int dpi;

    size_t *row_task;   /* 列表行 -> 任务下标 */
    size_t row_count;
    size_t sel_task;    /* SIZE_MAX = 无选择 */
    int group_by_level;

    HWND wait_hwnd;
    int wait_prompt_gen;

    /*
     * 非交互验收模式（--input / --export）：启动时加载输入，分析完成后自动导出并退出。
     * 只影响这一条可选路径，交互式使用完全不受影响。
     */
    wchar_t init_input[1024];
    wchar_t init_export[1024];
    int auto_mode;
    int auto_export_done;
    int auto_debug;      /* 1 = 把验收模式的关键步骤写到 stderr（排查用） */

    /* 编辑对话框上下文（同一时刻只开一个） */
    int dlg_mode;
    int dlg_ok;
    int dlg_done;      /* 已点确定/取消：退出模态循环（窗口先隐藏，读完值再销毁） */
    size_t dlg_task;
    HWND dlg_hwnd;
    TsPrecondStatus *dlg_pre;
    size_t dlg_pre_count;
    int dlg_dep_sel;
} TsGui;

static TsGui g;

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static int S(int v)
{
    int dpi = (g.dpi > 0) ? g.dpi : 96;
    return (int)(((long)v * dpi + 48) / 96);
}

static void SetControlTextUtf8(HWND ctl, const char *utf8)
{
    wchar_t *w;
    if (ctl == NULL) return;
    if (utf8 == NULL) utf8 = "";
    w = ts_utf8_to_wide(utf8, strlen(utf8), NULL);
    SetWindowTextW(ctl, (w != NULL) ? w : L"");
    ts_free(w);
}

static void MessageBoxU8(HWND owner, const char *text, const char *title, UINT flags)
{
    wchar_t *m = ts_utf8_to_wide(text ? text : "", text ? strlen(text) : 0, NULL);
    wchar_t *t = ts_utf8_to_wide(title ? title : "", title ? strlen(title) : 0, NULL);
    MessageBoxW(owner, (m != NULL) ? m : L"", (t != NULL) ? t : L"TaskScheduler", flags);
    ts_free(m);
    ts_free(t);
}

static void SetFontTo(HWND ctl, HFONT f)
{
    if (ctl != NULL && f != NULL) {
        SendMessageW(ctl, WM_SETFONT, (WPARAM)f, TRUE);
    }
}

static void ApplyFontsRecursive(HWND parent)
{
    HWND child = GetWindow(parent, GW_CHILD);
    while (child != NULL) {
        SetFontTo(child, g.font_ui);
        child = GetWindow(child, GW_HWNDNEXT);
    }
}

static int GetWindowDpi(HWND hwnd)
{
    typedef UINT(WINAPI * PFN_GetDpiForWindow)(HWND);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 != NULL) {
        PFN_GetDpiForWindow p = (PFN_GetDpiForWindow)(void *)GetProcAddress(user32, "GetDpiForWindow");
        if (p != NULL) {
            UINT d = p(hwnd);
            if (d >= 72 && d <= 480) return (int)d;
        }
    }
    {
        HDC dc = GetDC(NULL);
        int d = 96;
        if (dc != NULL) {
            d = GetDeviceCaps(dc, LOGPIXELSX);
            ReleaseDC(NULL, dc);
        }
        return (d > 0) ? d : 96;
    }
}

static void RecreateFonts(void)
{
    LOGFONTW lf;
    if (g.font_ui != NULL) DeleteObject(g.font_ui);
    if (g.font_bold != NULL) DeleteObject(g.font_bold);

    memset(&lf, 0, sizeof(lf));
    lf.lfHeight = -MulDiv(10, (g.dpi > 0) ? g.dpi : 96, 72);
    lf.lfWeight = FW_NORMAL;
    lf.lfCharSet = DEFAULT_CHARSET;
    wcsncpy_s(lf.lfFaceName, LF_FACESIZE, L"Microsoft YaHei UI", _TRUNCATE);
    g.font_ui = CreateFontIndirectW(&lf);

    lf.lfWeight = FW_SEMIBOLD;
    wcsncpy_s(lf.lfFaceName, LF_FACESIZE, L"Microsoft YaHei UI", _TRUNCATE);
    g.font_bold = CreateFontIndirectW(&lf);
}

/* ------------------------------------------------------------------ */
/* ListView 辅助（显式使用 W 版本，避免 UNICODE 宏差异）               */
/* ------------------------------------------------------------------ */

static void LV_AddColumn(HWND lv, int idx, const wchar_t *text, int width, int fmt)
{
    LVCOLUMNW c;
    memset(&c, 0, sizeof(c));
    c.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM | LVCF_FMT;
    c.pszText = (LPWSTR)text;
    c.cchTextMax = (int)wcslen(text);
    c.cx = width;
    c.fmt = fmt;
    c.iSubItem = idx;
    SendMessageW(lv, LVM_INSERTCOLUMNW, (WPARAM)idx, (LPARAM)&c);
}

static int LV_AddItem(HWND lv, const wchar_t *text, LPARAM param)
{
    LVITEMW it;
    memset(&it, 0, sizeof(it));
    it.mask = LVIF_TEXT | LVIF_PARAM;
    it.iItem = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
    it.pszText = (LPWSTR)text;
    it.lParam = param;
    return (int)SendMessageW(lv, LVM_INSERTITEMW, 0, (LPARAM)&it);
}

static void LV_SetSubItem(HWND lv, int item, int sub, const wchar_t *text)
{
    LVITEMW it;
    memset(&it, 0, sizeof(it));
    it.mask = LVIF_TEXT;
    it.iItem = item;
    it.iSubItem = sub;
    it.pszText = (LPWSTR)text;
    SendMessageW(lv, LVM_SETITEMTEXTW, (WPARAM)item, (LPARAM)&it);
}

static void LV_SetGroup(HWND lv, int item, int group_id)
{
    LVITEMW it;
    memset(&it, 0, sizeof(it));
    it.mask = LVIF_GROUPID;
    it.iItem = item;
    it.iGroupId = group_id;
    SendMessageW(lv, LVM_SETITEMW, 0, (LPARAM)&it);
}

static int LV_AddGroupDef(HWND lv, int group_id, const wchar_t *header)
{
    LVGROUP grp;
    memset(&grp, 0, sizeof(grp));
    grp.cbSize = sizeof(grp);
    grp.mask = LVGF_HEADER | LVGF_GROUPID | LVGF_STATE;
    grp.pszHeader = (LPWSTR)header;
    grp.cchHeader = (int)wcslen(header);
    grp.iGroupId = group_id;
    grp.state = LVGS_COLLAPSIBLE;
    grp.stateMask = LVGS_COLLAPSIBLE;
    return (int)SendMessageW(lv, LVM_INSERTGROUP, (WPARAM)-1, (LPARAM)&grp);
}

/* ------------------------------------------------------------------ */
/* 状态文字与颜色                                                      */
/* ------------------------------------------------------------------ */

static const char *StateLabel(TsReadyState st)
{
    switch (st) {
    case TS_READY:           return "● 可开始";
    case TS_WAITING_DEP:     return "○ 等待前置任务";
    case TS_PENDING_CONFIRM: return "? 待确认";
    case TS_BLOCKED:         return "! 受阻";
    case TS_DONE:            return "√ 已完成";
    default:                 return "? 未知";
    }
}

static COLORREF StateColor(TsReadyState st, int affected)
{
    if (affected) return RGB(150, 60, 160);
    switch (st) {
    case TS_READY:           return RGB(0, 128, 0);
    case TS_WAITING_DEP:     return RGB(0, 64, 200);
    case TS_PENDING_CONFIRM: return RGB(200, 110, 0);
    case TS_BLOCKED:         return RGB(200, 0, 0);
    case TS_DONE:            return RGB(128, 128, 128);
    default:                 return RGB(0, 0, 0);
    }
}

static TsReadyState TaskState(size_t ti)
{
    const TsStatusView *sv = ts_controller_status(g.ctrl);
    if (sv == NULL || sv->states == NULL) return TS_WAITING_DEP;
    return sv->states[ti];
}

static int TaskAffected(size_t ti)
{
    const TsStatusView *sv = ts_controller_status(g.ctrl);
    if (sv == NULL || sv->affected == NULL) return 0;
    return sv->affected[ti];
}

/* ------------------------------------------------------------------ */
/* 文本构造                                                            */
/* ------------------------------------------------------------------ */

static void JoinIds(const char **ids, size_t count, TsBuf *b, const char *empty_text)
{
    size_t i;
    if (count == 0) {
        ts_buf_puts(b, empty_text);
        return;
    }
    for (i = 0; i < count; i++) {
        if (i > 0) ts_buf_puts(b, "、");
        ts_buf_puts(b, ids[i]);
    }
}

static void BuildDepSummary(const TsTask *t, TsBuf *b)
{
    size_t i;
    if (t->depends_on_count == 0) {
        ts_buf_puts(b, "无");
        return;
    }
    for (i = 0; i < t->depends_on_count; i++) {
        if (i > 0) ts_buf_puts(b, "、");
        ts_buf_puts(b, t->depends_on[i]);
        if (i >= 3) {
            ts_buf_puts(b, "…");
            break;
        }
    }
}

static void BuildDetailText(size_t ti, TsBuf *b)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsTask *t;
    size_t step, k;
    TsReadyState st;
    int affected = TaskAffected(ti);
    const TsStatusView *sv = ts_controller_status(g.ctrl);

    if (plan == NULL || ti >= plan->task_count) {
        ts_buf_puts(b, "请选择左侧任务查看详情。");
        return;
    }
    t = &plan->tasks[ti];
    st = TaskState(ti);
    step = ts_controller_step_index_of(g.ctrl, ti);

    ts_buf_printf(b, "【%s】%s\n", t->id, t->name);
    ts_buf_printf(b, "状态：%s%s", StateLabel(st), affected ? "（受上游受阻/待确认影响）" : "");
    if (sv != NULL && sv->level != NULL) {
        if (sv->level[ti] >= 0) ts_buf_printf(b, "    依赖层级：第 %d 层", sv->level[ti]);
        else ts_buf_puts(b, "    依赖层级：存在循环依赖");
    }
    if (step != SIZE_MAX) ts_buf_printf(b, "    建议序号：第 %zu 步", step + 1);
    else ts_buf_puts(b, "    建议序号：未排入建议顺序");
    ts_buf_puts(b, "\n");

    ts_buf_printf(b, "紧迫性：%d／5 — %s\n", t->urgency,
                  (t->urgency_reason != NULL) ? t->urgency_reason : "（未提供理由）");
    ts_buf_printf(b, "影响力：%d／5 — %s\n", t->impact,
                  (t->impact_reason != NULL) ? t->impact_reason : "（未提供理由）");
    if (t->has_estimated_hours) {
        ts_buf_printf(b, "预计工时：%.2f 小时 — %s\n", t->estimated_hours,
                      (t->estimate_reason != NULL) ? t->estimate_reason : "（未提供理由）");
    } else {
        ts_buf_puts(b, "预计工时：未知（待确认）");
        if (t->estimate_reason != NULL) ts_buf_printf(b, " — %s", t->estimate_reason);
        ts_buf_puts(b, "\n");
    }
    ts_buf_printf(b, "截止时间：%s\n", (t->deadline != NULL) ? t->deadline : "未知");

    ts_buf_puts(b, "\n执行步骤：\n");
    if (t->steps_count == 0) {
        ts_buf_puts(b, "  （模型未给出步骤）\n");
    } else {
        for (k = 0; k < t->steps_count; k++) {
            ts_buf_printf(b, "  %zu. %s\n", k + 1, t->steps[k]);
        }
    }

    ts_buf_puts(b, "\n前置任务：");
    if (t->depends_on_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        for (k = 0; k < t->depends_on_count; k++) {
            size_t j;
            const char *name = NULL;
            for (j = 0; j < plan->task_count; j++) {
                if (strcmp(plan->tasks[j].id, t->depends_on[k]) == 0) { name = plan->tasks[j].name; break; }
            }
            ts_buf_printf(b, "%s%s（%s）", (k > 0) ? "、" : "", t->depends_on[k],
                          (name != NULL) ? name : "?");
        }
        ts_buf_puts(b, "\n");
    }

    ts_buf_puts(b, "\n外部条件：");
    if (t->preconditions_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        ts_buf_puts(b, "\n");
        for (k = 0; k < t->preconditions_count; k++) {
            const char *s = "未知";
            if (t->preconditions[k].status == TS_PRECOND_MET) s = "已满足";
            else if (t->preconditions[k].status == TS_PRECOND_UNMET) s = "未满足";
            ts_buf_printf(b, "  [%s] %s\n", s, t->preconditions[k].description);
        }
    }

    ts_buf_puts(b, "\n来源引用：");
    if (t->source_refs_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        for (k = 0; k < t->source_refs_count; k++) {
            ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", t->source_refs[k]);
        }
        ts_buf_puts(b, "\n");
    }

    /* 排序理由与得分分解 */
    if (step != SIZE_MAX) {
        const TsScheduleResult *sr = ts_controller_schedule(g.ctrl);
        const TsScheduleStep *ss = &sr->steps[step];
        ts_buf_puts(b, "\n排序理由（本地计算）：\n  ");
        if (ss->reason != NULL) ts_buf_puts(b, ss->reason);
        /*
         * 得分分解必须能按等式复算：基础分是加权和，因此把权重与乘积累写出来，
         * 不能用“基础分 + C + R + W = 最终”这种对不上的写法（审查报告 P2）。
         */
        {
            const TsConfig *cfg = ts_controller_config(g.ctrl);
            double wu = (cfg != NULL) ? cfg->w_urgency : 0.35;
            double wi = (cfg != NULL) ? cfg->w_impact : 0.30;
            double wb = (cfg != NULL) ? cfg->w_blocking : 0.20;
            double wq = (cfg != NULL) ? cfg->w_quick_win : 0.10;
            double wd = (cfg != NULL) ? cfg->w_depth : 0.05;
            ts_buf_puts(b, "\n得分分解（可按下面等式复算）：\n");
            ts_buf_printf(b, "  归一化维度：U=%.3f  I=%.3f  B=%.3f  Q=%.3f  D=%.3f\n",
                          ss->score.u, ss->score.i, ss->score.b, ss->score.q, ss->score.d);
            ts_buf_printf(b, "  基础分 = 100×（%.2f×U + %.2f×I + %.2f×B + %.2f×Q + %.2f×D）= %.2f\n",
                          wu, wi, wb, wq, wd, ss->score.base);
            ts_buf_printf(b, "  全局加分 = 10×C(%.3f)=%.2f + 7×R(%.3f)=%.2f + 3×W(%.3f)=%.2f = %.2f\n",
                          ss->score.c, 10.0 * ss->score.c,
                          ss->score.r, 7.0 * ss->score.r,
                          ss->score.w, 3.0 * ss->score.w,
                          10.0 * ss->score.c + 7.0 * ss->score.r + 3.0 * ss->score.w);
            ts_buf_printf(b, "  最终得分 = 基础分 + 全局加分 = %.2f\n", ss->score.final);
        }
        if (ss->score.hours_unknown) ts_buf_puts(b, "  备注：工时未知，工时优势按 0.5 计算，并标记为待确认。\n");
        if (ss->score.chain_incomplete) ts_buf_puts(b, "  备注：关键链涉及未知工时，未提供确定的关键链加分。\n");

        ts_buf_puts(b, "\n完成后立即解锁：");
        if (ss->unlocked_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < ss->unlocked_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", ss->unlocked[k]);
            }
            ts_buf_puts(b, "\n");
        }
        ts_buf_puts(b, "仍需其他前置：");
        if (ss->still_waiting_count == 0) {
            ts_buf_puts(b, "无\n");
        } else {
            for (k = 0; k < ss->still_waiting_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", ss->still_waiting[k]);
            }
            ts_buf_puts(b, "\n");
        }
        if (ss->candidate_count > 0) {
            ts_buf_printf(b, "选择时的候选任务（%zu 个）：", ss->candidate_count);
            for (k = 0; k < ss->candidate_count; k++) {
                ts_buf_printf(b, "%s%s", (k > 0) ? "、" : "", ss->candidates[k]);
            }
            ts_buf_puts(b, "\n");
        }
    } else {
        ts_buf_puts(b, "\n排序理由：该任务未排入建议顺序（受阻、待确认或已完成）。\n");
    }
}

static void BuildBlockedText(TsBuf *b)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsScheduleResult *sr = ts_controller_schedule(g.ctrl);
    size_t i;

    if (plan == NULL) {
        ts_buf_puts(b, "尚未分析：没有受阻或待确认任务。\n");
        return;
    }
    if (sr == NULL) {
        ts_buf_puts(b, "当前计划校验/排序未通过，请检查下方提示。\n");
        ts_buf_printf(b, "提示：%s\n", ts_controller_plan_message(g.ctrl));
        return;
    }

    ts_buf_puts(b, "受阻任务（外部条件未满足）：");
    if (sr->blocked_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        ts_buf_puts(b, "\n");
        for (i = 0; i < sr->blocked_count; i++) {
            ts_buf_printf(b, "  %s\n", sr->blocked_ids[i]);
        }
    }

    ts_buf_puts(b, "待确认任务（外部条件未知）：");
    if (sr->pending_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        ts_buf_puts(b, "\n");
        for (i = 0; i < sr->pending_count; i++) {
            ts_buf_printf(b, "  %s\n", sr->pending_ids[i]);
        }
    }

    ts_buf_puts(b, "受影响任务（上游受阻或待确认）：");
    if (sr->affected_count == 0) {
        ts_buf_puts(b, "无\n");
    } else {
        ts_buf_puts(b, "\n");
        for (i = 0; i < sr->affected_count; i++) {
            ts_buf_printf(b, "  %s\n", sr->affected_ids[i]);
        }
    }

    if (sr->unresolvable_reason != NULL) {
        ts_buf_printf(b, "无任务可立即执行的原因：%s\n", sr->unresolvable_reason);
    }

    if (plan->assumptions_count > 0) {
        ts_buf_puts(b, "模型假设：\n");
        for (i = 0; i < plan->assumptions_count; i++) {
            ts_buf_printf(b, "  · %s\n", plan->assumptions[i]);
        }
    }
    if (plan->questions_count > 0) {
        ts_buf_puts(b, "待确认问题：\n");
        for (i = 0; i < plan->questions_count; i++) {
            ts_buf_printf(b, "  · %s\n", plan->questions[i]);
        }
    }
    if (ts_controller_plan_message(g.ctrl)[0] != '\0') {
        ts_buf_printf(b, "最近提示：%s\n", ts_controller_plan_message(g.ctrl));
    }
}

/* ------------------------------------------------------------------ */
/* 刷新界面                                                            */
/* ------------------------------------------------------------------ */

static void RefreshStatus(void)
{
    char stage[64], detail[256], buf[1024];
    int running = ts_controller_is_running(g.ctrl);
    long ms;
    size_t ns = ts_controller_source_count(g.ctrl);
    size_t bytes = ts_controller_input_bytes(g.ctrl);

    ts_controller_stage_text(g.ctrl, stage, sizeof(stage));
    ts_controller_stage_detail_text(g.ctrl, detail, sizeof(detail));

    if (running) {
        ms = ts_controller_elapsed_ms(g.ctrl);
        if (detail[0] != '\0') {
            snprintf(buf, sizeof(buf), "分析中… ｜ 当前阶段：%s ｜ 已等待 %.1f 秒 ｜ 重试/修复：%s",
                     stage, (double)ms / 1000.0, detail);
        } else {
            snprintf(buf, sizeof(buf), "分析中… ｜ 当前阶段：%s ｜ 已等待 %.1f 秒",
                     stage, (double)ms / 1000.0);
        }
    } else {
        const TsAnalyzeResult *r = ts_controller_last_analyze(g.ctrl);
        if (r != NULL && !r->ok && r->error_kind != TS_MODEL_ERR_CANCELLED) {
            snprintf(buf, sizeof(buf), "分析失败：%s",
                     (r->error != NULL) ? r->error : "未知错误");
        } else if (r != NULL && r->error_kind == TS_MODEL_ERR_CANCELLED) {
            snprintf(buf, sizeof(buf), "已取消本次分析 ｜ 已等待 %.1f 秒 ｜ 不会自动重试",
                     (double)ts_controller_elapsed_ms(g.ctrl) / 1000.0);
        } else if (ts_controller_has_plan(g.ctrl)) {
            const TsPlan *p = ts_controller_plan(g.ctrl);
            const TsScheduleResult *s = ts_controller_schedule(g.ctrl);
            snprintf(buf, sizeof(buf),
                     "分析完成：%zu 个任务，建议执行 %zu 步 ｜ 用时 %.1f 秒 ｜ 来源 %zu 个（%zu 字节）",
                     p->task_count, (s != NULL) ? s->step_count : 0,
                     (double)ts_controller_elapsed_ms(g.ctrl) / 1000.0, ns, bytes);
        } else {
            snprintf(buf, sizeof(buf),
                     "就绪：请添加文件或输入文段，然后点击“开始分析”。已添加 %zu 个来源（%zu 字节）",
                     ns, bytes);
        }
    }
    SetControlTextUtf8(g.st_status, buf);
}

static void RefreshNextStep(void)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsScheduleResult *sr = ts_controller_schedule(g.ctrl);
    TsBuf b;

    if (plan == NULL || sr == NULL) {
        if (plan != NULL) {
            SetControlTextUtf8(g.st_next[0], "当前计划校验/排序未通过，无法给出下一步建议。");
            SetControlTextUtf8(g.st_next[1], ts_controller_plan_message(g.ctrl));
        } else {
            SetControlTextUtf8(g.st_next[0], "尚未分析：添加文件或输入文段后点击“开始分析”。");
            SetControlTextUtf8(g.st_next[1], "");
        }
        SetControlTextUtf8(g.st_next[2], "");
        return;
    }

    if (sr->step_count == 0) {
        ts_buf_init(&b);
        ts_buf_puts(&b, "当前没有可开始的任务。");
        SetControlTextUtf8(g.st_next[0], b.data);
        ts_buf_free(&b);

        ts_buf_init(&b);
        ts_buf_puts(&b, "原因：");
        ts_buf_puts(&b, (sr->unresolvable_reason != NULL) ? sr->unresolvable_reason
                                                          : "剩余任务均依赖尚未满足的前置或外部条件。");
        SetControlTextUtf8(g.st_next[1], b.data);
        ts_buf_free(&b);

        ts_buf_init(&b);
        ts_buf_puts(&b, "受阻：");
        JoinIds((const char **)sr->blocked_ids, sr->blocked_count, &b, "无");
        ts_buf_puts(&b, "    待确认：");
        JoinIds((const char **)sr->pending_ids, sr->pending_count, &b, "无");
        SetControlTextUtf8(g.st_next[2], b.data);
        ts_buf_free(&b);
        return;
    }

    {
        const TsScheduleStep *s0 = &sr->steps[0];
        size_t ti = s0->task_index;
        const TsTask *t = &plan->tasks[ti];

        ts_buf_init(&b);
        ts_buf_printf(&b, "建议现在做：第 1 步「%s %s」（%s）",
                      t->id, t->name, StateLabel(TaskState(ti)));
        SetControlTextUtf8(g.st_next[0], b.data);
        ts_buf_free(&b);

        ts_buf_init(&b);
        ts_buf_printf(&b,
                      "为什么先做：基础分 %.2f，关键链 +%.2f、解锁 +%.2f、快速见效 +%.2f，最终 %.2f%s",
                      s0->score.base, 10.0 * s0->score.c, 7.0 * s0->score.r,
                      3.0 * s0->score.w, s0->score.final,
                      s0->score.hours_unknown ? "（工时待确认）" : "");
        SetControlTextUtf8(g.st_next[1], b.data);
        ts_buf_free(&b);

        ts_buf_init(&b);
        if (s0->unlocked_count > 0) {
            ts_buf_puts(&b, "完成后立即解锁：");
            JoinIds((const char **)s0->unlocked, s0->unlocked_count, &b, "无");
        } else {
            ts_buf_puts(&b, "完成后立即解锁：无");
        }
        if (s0->still_waiting_count > 0) {
            ts_buf_puts(&b, "    仍需其他前置：");
            JoinIds((const char **)s0->still_waiting, s0->still_waiting_count, &b, "无");
        }
        SetControlTextUtf8(g.st_next[2], b.data);
        ts_buf_free(&b);
    }
}

static void ApplyGrouping(void)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsStatusView *sv = ts_controller_status(g.ctrl);
    size_t i;
    int maxlvl = -1;

    SendMessageW(g.lv_tasks, LVM_REMOVEALLGROUPS, 0, 0);

    if (!g.group_by_level || plan == NULL || sv == NULL || sv->level == NULL) {
        SendMessageW(g.lv_tasks, LVM_ENABLEGROUPVIEW, FALSE, 0);
        return;
    }

    for (i = 0; i < plan->task_count; i++) {
        if (sv->level[i] > maxlvl) maxlvl = sv->level[i];
    }
    if (maxlvl < 0) {
        SendMessageW(g.lv_tasks, LVM_ENABLEGROUPVIEW, FALSE, 0);
        return;
    }

    SendMessageW(g.lv_tasks, LVM_ENABLEGROUPVIEW, TRUE, 0);
    for (i = 0; i <= (size_t)maxlvl; i++) {
        wchar_t hdr[64];
        _snwprintf_s(hdr, _countof(hdr), _TRUNCATE, L"第 %d 层", (int)i);
        LV_AddGroupDef(g.lv_tasks, (int)i + 1, hdr);
    }
    for (i = 0; i < g.row_count; i++) {
        int lvl = sv->level[g.row_task[i]];
        LV_SetGroup(g.lv_tasks, (int)i, (lvl >= 0) ? (lvl + 1) : 1);
    }
}

static void RefreshTaskList(void)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsScheduleResult *sr = ts_controller_schedule(g.ctrl);
    size_t i, n;
    unsigned char *placed = NULL;

    SendMessageW(g.lv_tasks, LVM_DELETEALLITEMS, 0, 0);
    ts_free(g.row_task);
    g.row_task = NULL;
    g.row_count = 0;

    if (plan == NULL) return;
    n = plan->task_count;
    if (n == 0) return;

    g.row_task = (size_t *)ts_calloc(n, sizeof(size_t));
    if (g.row_task == NULL) return;
    placed = (unsigned char *)ts_calloc(n, 1);
    if (placed == NULL) {
        ts_free(g.row_task);
        g.row_task = NULL;
        return;
    }

    /* 先按建议顺序，再补上未排入的任务（未完成在前，已完成在后） */
    if (sr != NULL) {
        for (i = 0; i < sr->step_count; i++) {
            size_t ti = sr->steps[i].task_index;
            if (ti < n && !placed[ti]) {
                placed[ti] = 1;
                g.row_task[g.row_count++] = ti;
            }
        }
    }
    {
        int pass;
        for (pass = 0; pass < 2; pass++) {
            for (i = 0; i < n; i++) {
                int is_done = (plan->tasks[i].actual_status == TS_ACTUAL_DONE);
                if (placed[i]) continue;
                if ((pass == 0 && !is_done) || (pass == 1 && is_done)) {
                    placed[i] = 1;
                    g.row_task[g.row_count++] = i;
                }
            }
        }
    }
    ts_free(placed);

    for (i = 0; i < g.row_count; i++) {
        size_t ti = g.row_task[i];
        const TsTask *t = &plan->tasks[ti];
        TsReadyState st = TaskState(ti);
        int affected = TaskAffected(ti);
        size_t step = ts_controller_step_index_of(g.ctrl, ti);
        wchar_t wbuf[64];
        int row;
        TsBuf b;
        wchar_t *wname;
        wchar_t *wstate;
        wchar_t *wdead;
        wchar_t *whours;
        wchar_t *wdep;

        if (step != SIZE_MAX) _snwprintf_s(wbuf, _countof(wbuf), _TRUNCATE, L"%zu", step + 1);
        else wcsncpy_s(wbuf, _countof(wbuf), L"-", _TRUNCATE);

        row = LV_AddItem(g.lv_tasks, wbuf, (LPARAM)ti);
        if (row < 0) {
            continue;
        }

        wname = ts_utf8_to_wide(t->name ? t->name : "", t->name ? strlen(t->name) : 0, NULL);

        ts_buf_init(&b);
        ts_buf_puts(&b, StateLabel(st));
        if (affected && st != TS_BLOCKED && st != TS_PENDING_CONFIRM && st != TS_DONE) {
            ts_buf_puts(&b, "(受影响)");
        }
        wstate = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);

        wdead = ts_utf8_to_wide(t->deadline ? t->deadline : "未知",
                               t->deadline ? strlen(t->deadline) : strlen("未知"), NULL);

        ts_buf_init(&b);
        if (t->has_estimated_hours) ts_buf_printf(&b, "%.1f h", t->estimated_hours);
        else ts_buf_puts(&b, "未知");
        whours = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);

        ts_buf_init(&b);
        BuildDepSummary(t, &b);
        wdep = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);

        LV_SetSubItem(g.lv_tasks, row, 1, wname ? wname : L"");
        LV_SetSubItem(g.lv_tasks, row, 2, wstate ? wstate : L"");
        LV_SetSubItem(g.lv_tasks, row, 3, wdead ? wdead : L"");
        LV_SetSubItem(g.lv_tasks, row, 4, whours ? whours : L"");
        LV_SetSubItem(g.lv_tasks, row, 5, wdep ? wdep : L"");

        ts_free(wname);
        ts_free(wstate);
        ts_free(wdead);
        ts_free(whours);
        ts_free(wdep);
    }

    ApplyGrouping();

    /* 恢复或初始化选择 */
    {
        int sel = -1;
        if (g.sel_task != SIZE_MAX) {
            for (i = 0; i < g.row_count; i++) {
                if (g.row_task[i] == g.sel_task) { sel = (int)i; break; }
            }
        }
        if (sel < 0 && g.row_count > 0) {
            sel = 0;
            g.sel_task = g.row_task[0];
        }
        if (sel >= 0) {
            LVITEMW it;
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_STATE;
            it.state = LVIS_SELECTED | LVIS_FOCUSED;
            it.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
            SendMessageW(g.lv_tasks, LVM_SETITEMSTATE, (WPARAM)sel, (LPARAM)&it);
            SendMessageW(g.lv_tasks, LVM_ENSUREVISIBLE, (WPARAM)sel, FALSE);
        } else {
            g.sel_task = SIZE_MAX;
        }
    }
}

static void RefreshRelated(void)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    size_t i;

    SendMessageW(g.lb_related, LB_RESETCONTENT, 0, 0);
    if (plan == NULL || g.sel_task == SIZE_MAX || g.sel_task >= plan->task_count) {
        return;
    }
    {
        const TsTask *t = &plan->tasks[g.sel_task];
        for (i = 0; i < t->depends_on_count; i++) {
            size_t j;
            const char *nm = "?";
            for (j = 0; j < plan->task_count; j++) {
                if (strcmp(plan->tasks[j].id, t->depends_on[i]) == 0) { nm = plan->tasks[j].name; break; }
            }
            {
                TsBuf b;
                wchar_t *w;
                int idx;
                ts_buf_init(&b);
                ts_buf_printf(&b, "前置：%s %s", t->depends_on[i], nm);
                w = ts_utf8_to_wide(b.data, b.len, NULL);
                ts_buf_free(&b);
                idx = (int)SendMessageW(g.lb_related, LB_ADDSTRING, 0, (LPARAM)(w ? w : L""));
                ts_free(w);
                if (idx >= 0) {
                    size_t target;
                    for (target = 0; target < plan->task_count; target++) {
                        if (strcmp(plan->tasks[target].id, t->depends_on[i]) == 0) break;
                    }
                    if (target < plan->task_count) {
                        SendMessageW(g.lb_related, LB_SETITEMDATA, (WPARAM)idx, (LPARAM)target);
                    }
                }
            }
        }
    }
    /* 后继（解锁相关） */
    {
        const TsTask *t = &plan->tasks[g.sel_task];
        for (i = 0; i < plan->task_count; i++) {
            size_t k;
            for (k = 0; k < plan->tasks[i].depends_on_count; k++) {
                if (strcmp(plan->tasks[i].depends_on[k], t->id) == 0) {
                    TsBuf b;
                    wchar_t *w;
                    int idx;
                    ts_buf_init(&b);
                    ts_buf_printf(&b, "后继：%s %s", plan->tasks[i].id, plan->tasks[i].name);
                    w = ts_utf8_to_wide(b.data, b.len, NULL);
                    ts_buf_free(&b);
                    idx = (int)SendMessageW(g.lb_related, LB_ADDSTRING, 0, (LPARAM)(w ? w : L""));
                    ts_free(w);
                    if (idx >= 0) {
                        SendMessageW(g.lb_related, LB_SETITEMDATA, (WPARAM)idx, (LPARAM)i);
                    }
                    break;
                }
            }
        }
    }
}

static void RefreshDetail(void)
{
    TsBuf b;
    ts_buf_init(&b);
    if (g.sel_task == SIZE_MAX) {
        ts_buf_puts(&b, "请选择左侧任务查看详情。");
    } else {
        BuildDetailText(g.sel_task, &b);
    }
    SetControlTextUtf8(g.ed_detail, b.data ? b.data : "");
    ts_buf_free(&b);
    SendMessageW(g.ed_detail, EM_SETSEL, 0, 0);
    SendMessageW(g.ed_detail, EM_SCROLLCARET, 0, 0);
}

static void RefreshBlocked(void)
{
    TsBuf b;
    ts_buf_init(&b);
    BuildBlockedText(&b);
    SetControlTextUtf8(g.ed_blocked, b.data ? b.data : "");
    ts_buf_free(&b);
}

static void RefreshToolbar(void)
{
    int running = ts_controller_is_running(g.ctrl);
    int has_sel = (g.sel_task != SIZE_MAX);
    int have_plan = ts_controller_has_plan(g.ctrl);
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    int done = 0;

    if (have_plan && has_sel && plan != NULL && g.sel_task < plan->task_count) {
        done = (plan->tasks[g.sel_task].actual_status == TS_ACTUAL_DONE);
    }

    EnableWindow(g.btn_addfile, !running);
    EnableWindow(g.btn_addtext, !running);
    EnableWindow(g.btn_start, !running);
    EnableWindow(g.btn_cancel, running);
    EnableWindow(g.btn_export, !running && have_plan);
    EnableWindow(g.chk_group, !running);

    EnableWindow(g.btn_done, !running && has_sel);
    EnableWindow(g.btn_editf, !running && has_sel);
    EnableWindow(g.btn_editd, !running && has_sel);
    EnableWindow(g.btn_editp, !running && has_sel);

    SetWindowTextW(g.btn_done, done ? L"撤销完成" : L"标记完成");
}

static void RefreshAll(void)
{
    RefreshTaskList();
    RefreshDetail();
    RefreshRelated();
    RefreshNextStep();
    RefreshBlocked();
    RefreshStatus();
    RefreshToolbar();
}

/* ------------------------------------------------------------------ */
/* 布局                                                                */
/* ------------------------------------------------------------------ */

static void LayoutControls(void)
{
    RECT rc;
    int W, H, pad, bh, gap, x, y;
    int bottom_h, content_h, left_w, right_w, rel_h, btn_h, btn_row_h;

    if (g.hwnd == NULL) return;
    GetClientRect(g.hwnd, &rc);
    W = rc.right;
    H = rc.bottom;

    pad = S(8);
    bh = S(26);
    gap = S(6);

    x = pad;
    y = pad;
    MoveWindow(g.btn_addfile, x, y, S(96), bh, TRUE); x += S(96) + gap;
    MoveWindow(g.btn_addtext, x, y, S(96), bh, TRUE); x += S(96) + gap;
    MoveWindow(g.btn_start,  x, y, S(96), bh, TRUE); x += S(96) + gap;
    MoveWindow(g.btn_cancel, x, y, S(96), bh, TRUE); x += S(96) + gap;
    MoveWindow(g.btn_export, x, y, S(96), bh, TRUE); x += S(96) + gap;
    MoveWindow(g.chk_group,  x, y + S(4), S(140), bh, TRUE);
    y += bh + S(6);

    MoveWindow(g.st_status, pad, y, W - 2 * pad, S(20), TRUE);
    y += S(20) + S(4);

    MoveWindow(g.st_next[0], pad + S(4), y, W - 2 * pad - S(8), S(20), TRUE);
    MoveWindow(g.st_next[1], pad + S(4), y + S(20), W - 2 * pad - S(8), S(20), TRUE);
    MoveWindow(g.st_next[2], pad + S(4), y + S(40), W - 2 * pad - S(8), S(20), TRUE);
    y += S(60) + S(8);

    bottom_h = S(140);
    content_h = H - y - bottom_h - pad;
    if (content_h < S(160)) content_h = S(160);

    left_w = (W - 3 * pad) * 56 / 100;
    if (left_w < S(360)) left_w = S(360);
    if (left_w > W - 3 * pad - S(280)) left_w = W - 3 * pad - S(280);
    if (left_w < S(200)) left_w = S(200);
    right_w = W - 3 * pad - left_w;
    if (right_w < S(200)) right_w = S(200);

    MoveWindow(g.lv_tasks, pad, y, left_w, content_h, TRUE);

    rel_h = S(64);
    btn_h = S(24);
    btn_row_h = btn_h * 2 + S(4);
    MoveWindow(g.ed_detail, pad * 2 + left_w, y,
               right_w, content_h - rel_h - btn_row_h - S(50), TRUE);
    MoveWindow(g.st_related, pad * 2 + left_w, y + content_h - rel_h - btn_row_h - S(44),
               right_w, S(16), TRUE);
    MoveWindow(g.lb_related, pad * 2 + left_w, y + content_h - rel_h - btn_row_h - S(26),
               right_w, rel_h - S(10), TRUE);

    {
        int bx = pad * 2 + left_w;
        int by = y + content_h - btn_row_h + S(2);
        int half = (right_w - gap) / 2;
        MoveWindow(g.btn_done,  bx, by, half, btn_h, TRUE);
        MoveWindow(g.btn_editf, bx + half + gap, by, half, btn_h, TRUE);
        MoveWindow(g.btn_editd, bx, by + btn_h + S(4), half, btn_h, TRUE);
        MoveWindow(g.btn_editp, bx + half + gap, by + btn_h + S(4), half, btn_h, TRUE);
    }

    {
        int by = y + content_h + S(6);
        MoveWindow(g.st_blocked, pad, by, W - 2 * pad, S(16), TRUE);
        MoveWindow(g.ed_blocked, pad, by + S(18), W - 2 * pad,
                   H - (by + S(18)) - pad, TRUE);
    }
}

/* ------------------------------------------------------------------ */
/* 模态编辑对话框                                                      */
/* ------------------------------------------------------------------ */

#define DLG_ID_NAME   2001
#define DLG_ID_URG    2002
#define DLG_ID_IMP    2003
#define DLG_ID_HOURS  2004
#define DLG_ID_DEAD   2005
#define DLG_ID_LIST   2010
#define DLG_ID_REQ    2011
#define DLG_ID_TEXT   2012
#define DLG_ID_HINT   2020

static LRESULT CALLBACK EditDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

static void RegisterDialogClass(HINSTANCE inst, const wchar_t *name, WNDPROC proc)
{
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = name;
    RegisterClassExW(&wc);
}

static HWND CreatePopup(HINSTANCE inst, const wchar_t *cls, const wchar_t *title,
                        HWND owner, int w, int h)
{
    RECT ro;
    int x = CW_USEDEFAULT, y = CW_USEDEFAULT;
    if (owner != NULL && GetWindowRect(owner, &ro)) {
        x = ro.left + ((ro.right - ro.left) - w) / 2;
        y = ro.top + ((ro.bottom - ro.top) - h) / 2;
    }
    return CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, cls, title,
                           WS_POPUP | WS_CAPTION | WS_SYSMENU,
                           x, y, w, h, owner, NULL, inst, NULL);
}

static int RunModal(HWND dlg, HWND owner)
{
    EnableWindow(owner, FALSE);
    g.dlg_done = 0;
    ShowWindow(dlg, SW_SHOW);
    SetForegroundWindow(dlg);

    for (;;) {
        MSG msg;
        BOOL r = GetMessageW(&msg, NULL, 0, 0);
        if (r == 0) {
            PostQuitMessage((int)msg.wParam);
            break;
        }
        if (r == (BOOL)-1) {
            break;
        }
        if (!IsDialogMessageW(dlg, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (g.dlg_done || !IsWindow(dlg)) {
            break;
        }
    }
    EnableWindow(owner, TRUE);
    SetForegroundWindow(owner);
    return g.dlg_ok;
}

static HWND DlgAddStatic(HWND dlg, const wchar_t *text, int x, int y, int w, int h)
{
    HWND c = CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | SS_LEFT,
                             x, y, w, h, dlg, NULL, g.inst, NULL);
    SetFontTo(c, g.font_ui);
    return c;
}

static HWND DlgAddEdit(HWND dlg, int id, const wchar_t *text, int x, int y, int w, int h, DWORD extra)
{
    HWND c = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", text,
                             WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_LEFT | extra,
                             x, y, w, h, dlg, (HMENU)(INT_PTR)id, g.inst, NULL);
    SetFontTo(c, g.font_ui);
    return c;
}

static HWND DlgAddButton(HWND dlg, int id, const wchar_t *text, int x, int y, int w, int h)
{
    HWND c = CreateWindowExW(0, L"BUTTON", text, WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                             x, y, w, h, dlg, (HMENU)(INT_PTR)id, g.inst, NULL);
    SetFontTo(c, g.font_ui);
    return c;
}

static HWND DlgAddList(HWND dlg, int id, int x, int y, int w, int h, DWORD style)
{
    HWND c = CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", L"",
                             WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | style,
                             x, y, w, h, dlg, (HMENU)(INT_PTR)id, g.inst, NULL);
    SetFontTo(c, g.font_ui);
    return c;
}

static int FieldsDialog(HWND owner, size_t ti)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsTask *t = &plan->tasks[ti];
    HWND dlg;
    wchar_t buf[512];
    TsTaskEdit edit;
    int ok;

    dlg = CreatePopup(g.inst, L"TsEditDlg", L"编辑任务字段", owner, S(420), S(268));
    if (dlg == NULL) return 0;
    g.dlg_mode = DLG_FIELDS;
    g.dlg_task = ti;
    g.dlg_ok = 0;
    g.dlg_hwnd = dlg;

    DlgAddStatic(dlg, L"任务名称：", S(12), S(14), S(80), S(20));
    {
        wchar_t *w = ts_utf8_to_wide(t->name ? t->name : "", t->name ? strlen(t->name) : 0, NULL);
        DlgAddEdit(dlg, DLG_ID_NAME, (w != NULL) ? w : L"", S(96), S(12), S(300), S(22), ES_AUTOHSCROLL);
        ts_free(w);
    }
    DlgAddStatic(dlg, L"紧迫性 (1~5)：", S(12), S(46), S(80), S(20));
    _snwprintf_s(buf, _countof(buf), _TRUNCATE, L"%d", t->urgency);
    DlgAddEdit(dlg, DLG_ID_URG, buf, S(96), S(44), S(60), S(22), ES_NUMBER);

    DlgAddStatic(dlg, L"影响力 (1~5)：", S(176), S(46), S(80), S(20));
    _snwprintf_s(buf, _countof(buf), _TRUNCATE, L"%d", t->impact);
    DlgAddEdit(dlg, DLG_ID_IMP, buf, S(260), S(44), S(60), S(22), ES_NUMBER);

    DlgAddStatic(dlg, L"预计工时 (小时，留空=未知)：", S(12), S(78), S(220), S(20));
    if (t->has_estimated_hours) _snwprintf_s(buf, _countof(buf), _TRUNCATE, L"%.2f", t->estimated_hours);
    else buf[0] = L'\0';
    DlgAddEdit(dlg, DLG_ID_HOURS, buf, S(236), S(76), S(80), S(22), ES_AUTOHSCROLL);

    DlgAddStatic(dlg, L"截止时间 (留空=未知)：", S(12), S(110), S(140), S(20));
    {
        wchar_t *w = ts_utf8_to_wide(t->deadline ? t->deadline : "",
                                     t->deadline ? strlen(t->deadline) : 0, NULL);
        DlgAddEdit(dlg, DLG_ID_DEAD, (w != NULL) ? w : L"", S(156), S(108), S(240), S(22), ES_AUTOHSCROLL);
        ts_free(w);
    }
    DlgAddStatic(dlg, L"修改后本地立即校验并重新排序，不会重新调用模型。",
                 S(12), S(142), S(384), S(20));

    DlgAddButton(dlg, IDOK, L"确定", S(214), S(186), S(88), S(26));
    DlgAddButton(dlg, IDCANCEL, L"取消", S(308), S(186), S(88), S(26));

    ok = RunModal(dlg, owner);
    if (ok) {
        wchar_t wname[512], wur[32], wim[32], wh[64], wd[512];
        double hours = 0.0;
        int has_hours = 0;
        char *name_u8, *dead_u8;
        wchar_t *dp;

        GetWindowTextW(GetDlgItem(dlg, DLG_ID_NAME), wname, _countof(wname));
        GetWindowTextW(GetDlgItem(dlg, DLG_ID_URG), wur, _countof(wur));
        GetWindowTextW(GetDlgItem(dlg, DLG_ID_IMP), wim, _countof(wim));
        GetWindowTextW(GetDlgItem(dlg, DLG_ID_HOURS), wh, _countof(wh));
        GetWindowTextW(GetDlgItem(dlg, DLG_ID_DEAD), wd, _countof(wd));

        /* 去掉名称首尾空白与尾部空白 */
        dp = wh;
        while (*dp == L' ') dp++;
        if (*dp != L'\0') {
            hours = _wtof(dp);
            has_hours = 1;
        }

        {
            wchar_t *p = wname + wcslen(wname);
            while (p > wname && (p[-1] == L' ' || p[-1] == L'\t')) *--p = L'\0';
        }
        {
            wchar_t *p = wd + wcslen(wd);
            while (p > wd && (p[-1] == L' ' || p[-1] == L'\t')) *--p = L'\0';
        }

        name_u8 = ts_wide_to_utf8(wname, wcslen(wname));
        dead_u8 = ts_wide_to_utf8(wd, wcslen(wd));
        edit.name = (name_u8 != NULL) ? name_u8 : "";
        edit.urgency = _wtoi(wur);
        edit.impact = _wtoi(wim);
        edit.has_hours = has_hours;
        edit.hours = hours;
        edit.deadline = (dead_u8 != NULL) ? dead_u8 : "";

        if (edit.name[0] == '\0') {
            MessageBoxU8(g.hwnd, "任务名称不能为空。", "输入无效", MB_ICONWARNING);
            ok = 0;
        } else if (edit.urgency < 1 || edit.urgency > 5 || edit.impact < 1 || edit.impact > 5) {
            MessageBoxU8(g.hwnd, "紧迫性与影响力必须是 1~5 的整数。", "输入无效", MB_ICONWARNING);
            ok = 0;
        } else if (has_hours && !(hours > 0.0)) {
            MessageBoxU8(g.hwnd, "预计工时必须为正数，或留空表示未知。", "输入无效", MB_ICONWARNING);
            ok = 0;
        } else if (ts_controller_edit_task(g.ctrl, ti, &edit) != 0) {
            MessageBoxU8(g.hwnd, ts_controller_plan_message(g.ctrl), "校验失败", MB_ICONWARNING);
            ok = 0;
        }
        ts_free(name_u8);
        ts_free(dead_u8);
    }
    DestroyWindow(dlg);
    return ok;
}

static int DepsDialog(HWND owner, size_t ti)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsTask *t = &plan->tasks[ti];
    HWND dlg;
    HWND lb;
    size_t i;
    int ok;

    dlg = CreatePopup(g.inst, L"TsEditDlg", L"编辑前置依赖（可多选）", owner, S(460), S(420));
    if (dlg == NULL) return 0;
    g.dlg_mode = DLG_DEPS;
    g.dlg_task = ti;
    g.dlg_ok = 0;
    g.dlg_hwnd = dlg;

    DlgAddStatic(dlg, L"勾选该任务的所有前置任务（可多选，按住 Ctrl/Shift）：",
                 S(12), S(12), S(430), S(20));
    lb = DlgAddList(dlg, DLG_ID_LIST, S(12), S(36), S(430), S(300),
                    LBS_EXTENDEDSEL | LBS_NOINTEGRALHEIGHT);

    for (i = 0; i < plan->task_count; i++) {
        size_t k;
        int is_dep = 0;
        TsBuf b;
        wchar_t *w;
        int idx;

        if (i == ti) continue;
        for (k = 0; k < t->depends_on_count; k++) {
            if (strcmp(t->depends_on[k], plan->tasks[i].id) == 0) { is_dep = 1; break; }
        }
        ts_buf_init(&b);
        ts_buf_printf(&b, "%s  %s", plan->tasks[i].id, plan->tasks[i].name);
        w = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);
        idx = (int)SendMessageW(lb, LB_ADDSTRING, 0, (LPARAM)(w ? w : L""));
        ts_free(w);
        if (idx >= 0) {
            SendMessageW(lb, LB_SETITEMDATA, (WPARAM)idx, (LPARAM)i);
            if (is_dep) SendMessageW(lb, LB_SETSEL, TRUE, (WPARAM)idx);
        }
    }
    DlgAddStatic(dlg, L"注意：不允许自依赖、重复依赖或循环依赖；保存后会立即校验。",
                 S(12), S(342), S(430), S(20));
    DlgAddButton(dlg, IDOK, L"确定", S(256), S(366), S(88), S(26));
    DlgAddButton(dlg, IDCANCEL, L"取消", S(352), S(366), S(88), S(26));

    ok = RunModal(dlg, owner);
    if (ok) {
        int count = (int)SendMessageW(lb, LB_GETSELCOUNT, 0, 0);
        const char **ids = NULL;
        size_t n = 0;
        if (count > 0) {
            int *sel = (int *)ts_malloc((size_t)count * sizeof(int));
            ids = (const char **)ts_calloc((size_t)count, sizeof(char *));
            if (sel == NULL || ids == NULL) {
                ts_free(sel);
                ts_free(ids);
                MessageBoxU8(g.hwnd, "内存分配失败。", "错误", MB_ICONERROR);
                return 0;
            }
            SendMessageW(lb, LB_GETSELITEMS, (WPARAM)count, (LPARAM)sel);
            {
                int k;
                for (k = 0; k < count; k++) {
                    LRESULT data = SendMessageW(lb, LB_GETITEMDATA, (WPARAM)sel[k], 0);
                    if (data >= 0 && (size_t)data < plan->task_count) {
                        ids[n++] = plan->tasks[data].id;
                    }
                }
            }
            ts_free(sel);
        }
        if (ts_controller_set_deps(g.ctrl, ti, ids, n) != 0) {
            MessageBoxU8(g.hwnd, ts_controller_plan_message(g.ctrl), "依赖无效", MB_ICONWARNING);
            ok = 0;
        }
        ts_free((void *)ids);
    }
    DestroyWindow(dlg);
    return ok;
}

static int PrecondDialog(HWND owner, size_t ti)
{
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    const TsTask *t = &plan->tasks[ti];
    HWND dlg;
    HWND lb;
    size_t i;
    int ok;

    dlg = CreatePopup(g.inst, L"TsEditDlg", L"外部条件状态", owner, S(460), S(340));
    if (dlg == NULL) return 0;
    g.dlg_mode = DLG_PREC;
    g.dlg_task = ti;
    g.dlg_ok = 0;
    g.dlg_hwnd = dlg;
    g.dlg_pre_count = t->preconditions_count;
    g.dlg_pre = NULL;
    if (t->preconditions_count > 0) {
        g.dlg_pre = (TsPrecondStatus *)ts_calloc(t->preconditions_count, sizeof(TsPrecondStatus));
        if (g.dlg_pre == NULL) {
            DestroyWindow(dlg);
            return 0;
        }
        for (i = 0; i < t->preconditions_count; i++) {
            g.dlg_pre[i] = t->preconditions[i].status;
        }
    }

    DlgAddStatic(dlg, L"选择条件后点击“切换状态”（已满足 → 未满足 → 未知）：",
                 S(12), S(12), S(430), S(20));
    lb = DlgAddList(dlg, DLG_ID_LIST, S(12), S(36), S(430), S(210), LBS_NOTIFY | LBS_NOINTEGRALHEIGHT);
    for (i = 0; i < t->preconditions_count; i++) {
        TsBuf b;
        wchar_t *w;
        const char *s = "未知";
        if (t->preconditions[i].status == TS_PRECOND_MET) s = "已满足";
        else if (t->preconditions[i].status == TS_PRECOND_UNMET) s = "未满足";
        ts_buf_init(&b);
        ts_buf_printf(&b, "[%s] %s", s, t->preconditions[i].description);
        w = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);
        SendMessageW(lb, LB_ADDSTRING, 0, (LPARAM)(w ? w : L""));
        ts_free(w);
    }
    if (t->preconditions_count == 0) {
        SendMessageW(lb, LB_ADDSTRING, 0, (LPARAM)L"（该任务没有外部条件）");
    }
    DlgAddButton(dlg, IDC_DLG_CYCLE, L"切换状态", S(12), S(256), S(100), S(26));
    DlgAddButton(dlg, IDOK, L"确定", S(256), S(256), S(88), S(26));
    DlgAddButton(dlg, IDCANCEL, L"取消", S(352), S(256), S(88), S(26));

    ok = RunModal(dlg, owner);
    if (ok) {
        for (i = 0; i < t->preconditions_count; i++) {
            if (g.dlg_pre != NULL && g.dlg_pre[i] != t->preconditions[i].status) {
                if (ts_controller_set_precond_status(g.ctrl, ti, i, g.dlg_pre[i]) != 0) {
                    MessageBoxU8(g.hwnd, ts_controller_plan_message(g.ctrl), "更新失败", MB_ICONWARNING);
                    break;
                }
            }
        }
    }
    ts_free(g.dlg_pre);
    g.dlg_pre = NULL;
    g.dlg_pre_count = 0;
    DestroyWindow(dlg);
    return ok;
}

static void PrecondCycle(HWND dlg)
{
    HWND lb = GetDlgItem(dlg, DLG_ID_LIST);
    int sel = (int)SendMessageW(lb, LB_GETCURSEL, 0, 0);
    const TsPlan *plan = ts_controller_plan(g.ctrl);

    if (sel < 0 || g.dlg_pre == NULL || plan == NULL) return;
    if ((size_t)sel >= g.dlg_pre_count) return;

    if (g.dlg_pre[sel] == TS_PRECOND_MET) g.dlg_pre[sel] = TS_PRECOND_UNMET;
    else if (g.dlg_pre[sel] == TS_PRECOND_UNMET) g.dlg_pre[sel] = TS_PRECOND_UNKNOWN;
    else g.dlg_pre[sel] = TS_PRECOND_MET;

    {
        const char *s = "未知";
        TsBuf b;
        wchar_t *w;
        if (g.dlg_pre[sel] == TS_PRECOND_MET) s = "已满足";
        else if (g.dlg_pre[sel] == TS_PRECOND_UNMET) s = "未满足";
        ts_buf_init(&b);
        ts_buf_printf(&b, "[%s] %s", s,
                      plan->tasks[g.dlg_task].preconditions[sel].description);
        w = ts_utf8_to_wide(b.data, b.len, NULL);
        ts_buf_free(&b);
        SendMessageW(lb, LB_DELETESTRING, (WPARAM)sel, 0);
        SendMessageW(lb, LB_INSERTSTRING, (WPARAM)sel, (LPARAM)(w ? w : L""));
        SendMessageW(lb, LB_SETCURSEL, (WPARAM)sel, 0);
        ts_free(w);
    }
}

static int TextInputDialog(HWND owner)
{
    HWND dlg;
    HWND ed_text;
    int ok;

    dlg = CreatePopup(g.inst, L"TsEditDlg", L"输入文段与本次要求", owner, S(560), S(420));
    if (dlg == NULL) return 0;
    g.dlg_mode = DLG_TEXTIN;
    g.dlg_ok = 0;
    g.dlg_hwnd = dlg;

    DlgAddStatic(dlg, L"本次要求（可选，会与附件材料分开提供给模型）：", S(12), S(12), S(520), S(20));
    {
        wchar_t *w = ts_utf8_to_wide(ts_controller_user_request(g.ctrl),
                                     strlen(ts_controller_user_request(g.ctrl)), NULL);
        DlgAddEdit(dlg, DLG_ID_REQ, (w != NULL) ? w : L"", S(12), S(34), S(520), S(22), ES_AUTOHSCROLL);
        ts_free(w);
    }
    DlgAddStatic(dlg, L"文段内容（UTF-8 文本，将作为新的输入来源）：", S(12), S(68), S(520), S(20));
    ed_text = DlgAddEdit(dlg, DLG_ID_TEXT, L"", S(12), S(90), S(520), S(240),
                         ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL);
    DlgAddStatic(dlg, L"提示：PDF / DOCX / 图片请先转换为 UTF-8 文本。",
                 S(12), S(336), S(520), S(20));
    DlgAddButton(dlg, IDOK, L"确定", S(356), S(362), S(88), S(26));
    DlgAddButton(dlg, IDCANCEL, L"取消", S(450), S(362), S(88), S(26));

    ok = RunModal(dlg, owner);
    if (ok) {
        wchar_t wreq[512];
        int tlen;
        char err[512];

        GetWindowTextW(GetDlgItem(dlg, DLG_ID_REQ), wreq, _countof(wreq));
        {
            char *u8 = ts_wide_to_utf8(wreq, wcslen(wreq));
            ts_controller_set_user_request(g.ctrl, (u8 != NULL) ? u8 : "");
            ts_free(u8);
        }

        tlen = GetWindowTextLengthW(ed_text);
        if (tlen > 0) {
            wchar_t *wt = (wchar_t *)ts_malloc(((size_t)tlen + 1) * sizeof(wchar_t));
            if (wt != NULL) {
                GetWindowTextW(ed_text, wt, tlen + 1);
                {
                    char *u8 = ts_wide_to_utf8(wt, wcslen(wt));
                    if (u8 != NULL) {
                        if (ts_controller_add_text(g.ctrl, u8, NULL, err, sizeof(err)) != 0) {
                            MessageBoxU8(g.hwnd, err, "添加文段失败", MB_ICONWARNING);
                            ok = 0;
                        }
                        ts_free(u8);
                    }
                }
                ts_free(wt);
            }
        }
    }
    DestroyWindow(dlg);
    return ok;
}

static LRESULT CALLBACK EditDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    (void)lp;
    switch (msg) {
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDOK:
            g.dlg_ok = 1;
            g.dlg_done = 1;
            ShowWindow(hwnd, SW_HIDE);   /* 先隐藏，调用方读完控件值后再销毁 */
            return 0;
        case IDCANCEL:
            g.dlg_ok = 0;
            g.dlg_done = 1;
            ShowWindow(hwnd, SW_HIDE);
            return 0;
        case IDC_DLG_CYCLE:
            PrecondCycle(hwnd);
            return 0;
        default:
            return 0;
        }
    case WM_CLOSE:
        g.dlg_ok = 0;
        g.dlg_done = 1;
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------------ */
/* 120 秒提醒窗口（非模态：原请求继续运行）                            */
/* ------------------------------------------------------------------ */

static LRESULT CALLBACK WaitPromptProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    (void)lp;
    switch (msg) {
    case WM_CREATE:
        SetFontTo(CreateWindowExW(0, L"STATIC",
                                  L"本次请求已等待超过 120 秒，模型尚未返回完整结果。\r\n"
                                  L"是否取消本次请求？\r\n\r\n"
                                  L"· 选择“继续等待”后不会再重复提示；\r\n"
                                  L"· 关闭本窗口等同继续等待；\r\n"
                                  L"· 你随时可以点击主界面的“取消”按钮。",
                                  WS_CHILD | WS_VISIBLE | SS_LEFT,
                                  S(16), S(14), S(388), S(110), hwnd, NULL, g.inst, NULL),
                  g.font_ui);
        SetFontTo(CreateWindowExW(0, L"BUTTON", L"继续等待",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                                  S(190), S(136), S(100), S(28), hwnd,
                                  (HMENU)(INT_PTR)IDC_WAIT_CONTINUE, g.inst, NULL),
                  g.font_ui);
        SetFontTo(CreateWindowExW(0, L"BUTTON", L"取消请求",
                                  WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
                                  S(300), S(136), S(100), S(28), hwnd,
                                  (HMENU)(INT_PTR)IDC_WAIT_CANCEL, g.inst, NULL),
                  g.font_ui);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wp) == IDC_WAIT_CANCEL) {
            ts_controller_cancel(g.ctrl);   /* 只是请求取消，不强制终止线程 */
            DestroyWindow(hwnd);
            return 0;
        }
        if (LOWORD(wp) == IDC_WAIT_CONTINUE) {
            DestroyWindow(hwnd);            /* 继续等待：不重发、不重复提示 */
            return 0;
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(hwnd);                /* 关闭提示框 = 继续等待 */
        return 0;
    case WM_DESTROY:
        g.wait_hwnd = NULL;
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void ShowWaitPrompt(void)
{
    HWND h;
    if (g.wait_hwnd != NULL) return;
    h = CreatePopup(g.inst, L"TsWaitPrompt", L"请求仍在进行", g.hwnd, S(430), S(214));
    if (h == NULL) return;
    g.wait_hwnd = h;
    ShowWindow(h, SW_SHOW);
    SetForegroundWindow(h);
}

static void MaybeShowWaitPrompt(void)
{
    int gen;
    if (g.cfg == NULL) return;
    if (!ts_controller_is_running(g.ctrl)) return;
    if (g.wait_hwnd != NULL) return;
    if (g.cfg->wait_prompt_ms <= 0) return;

    gen = ts_controller_generation(g.ctrl);
    if (g.wait_prompt_gen == gen) return;   /* 本次请求已提示过 */
    if (ts_controller_elapsed_ms(g.ctrl) < g.cfg->wait_prompt_ms) return;

    g.wait_prompt_gen = gen;                /* 先记账，保证不重复弹窗 */
    ShowWaitPrompt();
}

static void CloseWaitPrompt(void)
{
    if (g.wait_hwnd != NULL) {
        HWND h = g.wait_hwnd;
        g.wait_hwnd = NULL;
        DestroyWindow(h);
    }
}

/* ------------------------------------------------------------------ */
/* 操作                                                                */
/* ------------------------------------------------------------------ */

static void AddFileFromWide(const wchar_t *w)
{
    char *u8 = ts_wide_to_utf8(w, wcslen(w));
    char err[512];
    if (u8 == NULL) return;
    if (ts_controller_add_file(g.ctrl, u8, err, sizeof(err)) != 0) {
        MessageBoxU8(g.hwnd, err, "添加文件失败", MB_ICONWARNING);
    }
    ts_free(u8);
}

static void OnAddFile(void)
{
    wchar_t *buf;
    OPENFILENAMEW ofn;
    const DWORD bufsize = 65536;
    static const wchar_t filter[] =
        L"文本文件 (*.txt;*.md)\0*.txt;*.md\0所有文件 (*.*)\0*.*\0\0";

    buf = (wchar_t *)ts_calloc(bufsize, sizeof(wchar_t));
    if (buf == NULL) return;

    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g.hwnd;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = buf;
    ofn.nMaxFile = bufsize;
    ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_ALLOWMULTISELECT | OFN_PATHMUSTEXIST;
    ofn.lpstrTitle = L"选择要分析的文本文件（可多选）";

    if (GetOpenFileNameW(&ofn)) {
        size_t len = wcslen(buf);
        if (len + 1 >= bufsize || buf[len + 1] == L'\0') {
            AddFileFromWide(buf);   /* 单选：整个缓冲区就是完整路径 */
        } else {
            const wchar_t *dir = buf;
            const wchar_t *f = buf + len + 1;
            while (*f != L'\0') {
                wchar_t full[2048];
                _snwprintf_s(full, _countof(full), _TRUNCATE, L"%s\\%s", dir, f);
                AddFileFromWide(full);
                f += wcslen(f) + 1;
            }
        }
        RefreshAll();
    }
    ts_free(buf);
}

static void SelectTaskInList(size_t task_index)
{
    size_t i;
    for (i = 0; i < g.row_count; i++) {
        if (g.row_task[i] == task_index) {
            LVITEMW it;
            memset(&it, 0, sizeof(it));
            it.mask = LVIF_STATE;
            it.state = LVIS_SELECTED | LVIS_FOCUSED;
            it.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
            SendMessageW(g.lv_tasks, LVM_SETITEMSTATE, (WPARAM)i, (LPARAM)&it);
            SendMessageW(g.lv_tasks, LVM_ENSUREVISIBLE, (WPARAM)i, FALSE);
            g.sel_task = task_index;
            RefreshDetail();
            RefreshRelated();
            RefreshToolbar();
            return;
        }
    }
}

static void OnStartAnalyze(void)
{
    char err[512];
    if (ts_controller_start_analyze(g.ctrl, err, sizeof(err)) != 0) {
        MessageBoxU8(g.hwnd, err, "无法开始分析", MB_ICONWARNING);
        return;
    }
    RefreshAll();
}

static void OnExport(void)
{
    static const wchar_t filter[] =
        L"文本文件 (*.txt)\0*.txt\0JSON 文件 (*.json)\0*.json\0\0";
    wchar_t path[MAX_PATH];
    OPENFILENAMEW ofn;
    const TsPlan *plan = ts_controller_plan(g.ctrl);
    char *path_u8;
    char err[1024];
    TsExportFormat fmt;

    if (plan == NULL) {
        MessageBoxU8(g.hwnd, "尚无可导出的分析结果，请先执行一次分析（或使用 --mock 离线演示）。",
                     "无法导出", MB_ICONINFORMATION);
        return;
    }

    path[0] = L'\0';
    if (g.auto_mode && g.init_export[0] != L'\0') {
        /* 非交互验收模式：直接使用命令行给出的路径，不弹文件对话框 */
        wcsncpy_s(path, _countof(path), g.init_export, _TRUNCATE);
    }

    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = g.hwnd;
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = path;
    ofn.nMaxFile = _countof(path);
    ofn.lpstrTitle = L"导出分析结果";
    ofn.lpstrDefExt = L"txt";
    ofn.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
    if (!(g.auto_mode && g.init_export[0] != L'\0')) {
        if (!GetSaveFileNameW(&ofn)) {
            return;   /* 用户取消：不改变任何界面状态 */
        }
    }

    /*
     * 格式判定：
     *   - 非交互验收模式：按**扩展名**推断（与 ts_export_format_from_path 的规则一致），
     *     否则 --export out.json 会被写成 TXT（含 BOM），与文件名不符；
     *   - 交互模式：按用户在保存对话框里选择的文件类型下拉框判定。
     */
    if (g.auto_mode && g.init_export[0] != L'\0') {
        size_t n = wcslen(path);
        if (n >= 5 && _wcsicmp(path + n - 5, L".json") == 0) {
            fmt = TS_EXPORT_JSON;
        } else {
            fmt = TS_EXPORT_TXT;
        }
    } else {
        fmt = (ofn.nFilterIndex == 2) ? TS_EXPORT_JSON : TS_EXPORT_TXT;
    }
    path_u8 = ts_wide_to_utf8(path, wcslen(path));
    if (path_u8 == NULL) {
        MessageBoxU8(g.hwnd, "导出路径编码转换失败。", "导出失败", MB_ICONERROR);
        return;
    }

    /*
     * 把最近一次分析的 token 用量带进导出：思考模式下思考 token 与正文共用
     * max_tokens 预算，导出里留下 reasoning_tokens，日后才能解释“为什么被截断”。
     * 结果可能为空（例如从 mock 载入的计划），此时 usage 传 NULL 即可。
     */
    {
        TsTokenUsageStat usage;
        const TsAnalyzeResult *r = ts_controller_last_analyze(g.ctrl);
        const TsTokenUsageStat *up = NULL;

        memset(&usage, 0, sizeof(usage));
        if (r != NULL && r->usage_present) {
            usage.present           = 1;
            usage.prompt_tokens     = r->usage_prompt_tokens;
            usage.completion_tokens = r->usage_completion_tokens;
            usage.reasoning_tokens  = r->usage_reasoning_tokens;
            usage.total_tokens      = r->usage_total_tokens;
            usage.attempts          = r->diag.attempts;
            usage.truncated         = (r->error_kind == TS_MODEL_ERR_TRUNCATED) ? 1 : 0;
            up = &usage;
        }

        if (ts_export_plan_usage(fmt, plan, ts_controller_schedule(g.ctrl),
                                 ts_controller_status(g.ctrl),
                                 ts_controller_config(g.ctrl), up,
                                 path_u8, err, sizeof(err)) != 0) {
            /* 导出失败：内存与界面中的分析结果保持原样 */
            if (!g.auto_mode) {
                MessageBoxU8(g.hwnd, err, "导出失败（分析结果已保留）", MB_ICONERROR);
            } else {
                printf("[auto] export failed: %s\n", err);
            }
        } else {
            if (g.auto_mode) {
                printf("[auto] exported: %s\n", path_u8);
                g.auto_export_done = 1;
            } else {
                TsBuf b;
                ts_buf_init(&b);
                ts_buf_printf(&b, "已导出到：\n%s", path_u8);
                MessageBoxU8(g.hwnd, b.data, "导出成功", MB_ICONINFORMATION);
                ts_buf_free(&b);
            }
        }
    }
    ts_free(path_u8);
}

/* ------------------------------------------------------------------ */
/* 主窗口                                                              */
/* ------------------------------------------------------------------ */

static void CreateControls(HWND hwnd)
{
    DWORD st = WS_CHILD | WS_VISIBLE;

    g.btn_addfile = CreateWindowExW(0, L"BUTTON", L"添加文件",
                                    st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                    hwnd, (HMENU)(INT_PTR)IDC_BTN_ADDFILE, g.inst, NULL);
    g.btn_addtext = CreateWindowExW(0, L"BUTTON", L"输入文段",
                                    st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                    hwnd, (HMENU)(INT_PTR)IDC_BTN_ADDTEXT, g.inst, NULL);
    g.btn_start = CreateWindowExW(0, L"BUTTON", L"开始分析",
                                  st | WS_TABSTOP | BS_DEFPUSHBUTTON, 0, 0, 10, 10,
                                  hwnd, (HMENU)(INT_PTR)IDC_BTN_START, g.inst, NULL);
    g.btn_cancel = CreateWindowExW(0, L"BUTTON", L"取消",
                                   st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                   hwnd, (HMENU)(INT_PTR)IDC_BTN_CANCEL, g.inst, NULL);
    g.btn_export = CreateWindowExW(0, L"BUTTON", L"导出",
                                   st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                   hwnd, (HMENU)(INT_PTR)IDC_BTN_EXPORT, g.inst, NULL);
    g.chk_group = CreateWindowExW(0, L"BUTTON", L"按依赖层级分组",
                                  st | WS_TABSTOP | BS_AUTOCHECKBOX, 0, 0, 10, 10,
                                  hwnd, (HMENU)(INT_PTR)IDC_CHK_GROUP, g.inst, NULL);

    g.st_status = CreateWindowExW(0, L"STATIC", L"", st | SS_LEFT | SS_ENDELLIPSIS,
                                  0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ST_STATUS, g.inst, NULL);
    g.st_next[0] = CreateWindowExW(0, L"STATIC", L"", st | SS_LEFT | SS_ENDELLIPSIS,
                                   0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ST_NEXT1, g.inst, NULL);
    g.st_next[1] = CreateWindowExW(0, L"STATIC", L"", st | SS_LEFT | SS_ENDELLIPSIS,
                                   0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ST_NEXT2, g.inst, NULL);
    g.st_next[2] = CreateWindowExW(0, L"STATIC", L"", st | SS_LEFT | SS_ENDELLIPSIS,
                                   0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ST_NEXT3, g.inst, NULL);

    g.lv_tasks = CreateWindowExW(WS_EX_CLIENTEDGE, WC_LISTVIEWW, L"",
                                 st | WS_TABSTOP | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
                                 0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_LV_TASKS, g.inst, NULL);
    SendMessageW(g.lv_tasks, LVM_SETEXTENDEDLISTVIEWSTYLE, 0,
                 LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES | LVS_EX_DOUBLEBUFFER);
    LV_AddColumn(g.lv_tasks, 0, L"序号", S(48), LVCFMT_RIGHT);
    LV_AddColumn(g.lv_tasks, 1, L"名称", S(200), LVCFMT_LEFT);
    LV_AddColumn(g.lv_tasks, 2, L"状态", S(96), LVCFMT_LEFT);
    LV_AddColumn(g.lv_tasks, 3, L"截止", S(96), LVCFMT_LEFT);
    LV_AddColumn(g.lv_tasks, 4, L"工时", S(64), LVCFMT_RIGHT);
    LV_AddColumn(g.lv_tasks, 5, L"前置摘要", S(140), LVCFMT_LEFT);

    g.ed_detail = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                  st | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL,
                                  0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ED_DETAIL, g.inst, NULL);
    g.st_related = CreateWindowExW(0, L"STATIC", L"关联任务（双击跳转）：",
                                   st | SS_LEFT, 0, 0, 10, 10, hwnd,
                                   (HMENU)(INT_PTR)IDC_ST_RELATED, g.inst, NULL);
    g.lb_related = CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", L"",
                                   st | WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY,
                                   0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_LB_RELATED, g.inst, NULL);

    g.btn_done = CreateWindowExW(0, L"BUTTON", L"标记完成",
                                 st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                 hwnd, (HMENU)(INT_PTR)IDC_BTN_DONE, g.inst, NULL);
    g.btn_editf = CreateWindowExW(0, L"BUTTON", L"编辑字段…",
                                  st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                  hwnd, (HMENU)(INT_PTR)IDC_BTN_EDITF, g.inst, NULL);
    g.btn_editd = CreateWindowExW(0, L"BUTTON", L"编辑依赖…",
                                  st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                  hwnd, (HMENU)(INT_PTR)IDC_BTN_EDITD, g.inst, NULL);
    g.btn_editp = CreateWindowExW(0, L"BUTTON", L"外部条件…",
                                  st | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 10, 10,
                                  hwnd, (HMENU)(INT_PTR)IDC_BTN_EDITP, g.inst, NULL);

    g.st_blocked = CreateWindowExW(0, L"STATIC", L"受阻 / 待确认 / 受影响 / 假设与问题：",
                                   st | SS_LEFT, 0, 0, 10, 10, hwnd,
                                   (HMENU)(INT_PTR)IDC_ST_BLOCKED, g.inst, NULL);
    g.ed_blocked = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                   st | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL,
                                   0, 0, 10, 10, hwnd, (HMENU)(INT_PTR)IDC_ED_BLOCKED, g.inst, NULL);

    ApplyFontsRecursive(hwnd);
}

static LRESULT CALLBACK MainWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

static LRESULT HandleNotify(LPARAM lp)
{
    LPNMHDR nh = (LPNMHDR)lp;
    if (nh->idFrom == IDC_LV_TASKS) {
        if (nh->code == LVN_ITEMCHANGED) {
            LPNMLISTVIEW nv = (LPNMLISTVIEW)lp;
            if ((nv->uNewState & LVIS_SELECTED) && !(nv->uOldState & LVIS_SELECTED)) {
                if (nv->iItem >= 0 && (size_t)nv->iItem < g.row_count) {
                    g.sel_task = g.row_task[nv->iItem];
                    RefreshDetail();
                    RefreshRelated();
                    RefreshToolbar();
                }
            }
            return 0;
        }
        if (nh->code == NM_CUSTOMDRAW) {
            LPNMLVCUSTOMDRAW cd = (LPNMLVCUSTOMDRAW)lp;
            switch (cd->nmcd.dwDrawStage) {
            case CDDS_PREPAINT:
                return CDRF_NOTIFYITEMDRAW;
            case CDDS_ITEMPREPAINT: {
                size_t ti = (size_t)cd->nmcd.lItemlParam;
                if (!(cd->nmcd.uItemState & CDIS_SELECTED)) {
                    cd->clrText = StateColor(TaskState(ti), TaskAffected(ti));
                }
                return CDRF_DODEFAULT;
            }
            default:
                return CDRF_DODEFAULT;
            }
        }
        return 0;
    }
    if (nh->idFrom == IDC_LB_RELATED && nh->code == LBN_DBLCLK) {
        int sel = (int)SendMessageW(g.lb_related, LB_GETCURSEL, 0, 0);
        if (sel >= 0) {
            LRESULT data = SendMessageW(g.lb_related, LB_GETITEMDATA, (WPARAM)sel, 0);
            if (data >= 0) {
                SelectTaskInList((size_t)data);
            }
        }
        return 0;
    }
    return 0;
}

static LRESULT CALLBACK MainWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE:
        g.hwnd = hwnd;
        g.dpi = GetWindowDpi(hwnd);
        RecreateFonts();
        CreateControls(hwnd);
        LayoutControls();
        SetTimer(hwnd, IDC_TIMER_STATUS, 200, NULL);
        RefreshAll();
        /*
         * 注意：非交互验收模式**不能**在这里启动分析。
         * ts_gui_run_ex 是在 CreateWindowExW 返回之后才把通知回调绑定到窗口句柄的，
         * 而 WM_CREATE 发生在 CreateWindowExW 内部；此时 PostMessage 也没有目标窗口，
         * 后台线程的“开始/进度/完成”通知会被全部丢弃——分析其实跑完了，
         * 界面却永远不知道，表现为启动即挂起（实测现象）。
         * 因此这里只发一个自定义消息，等窗口创建完成、回调绑定好之后再启动。
         */
        if (g.auto_mode && g.init_input[0] != L'\0') {
            PostMessageW(hwnd, TS_WM_AUTOSTART, 0, 0);
        }
        return 0;

    case TS_WM_AUTOSTART:
        if (g.auto_mode && g.init_input[0] != L'\0') {
            if (g.auto_debug) {
                fprintf(stderr, "[auto] autostart: adding input\n");
                fflush(stderr);
            }
            AddFileFromWide(g.init_input);
            if (g.auto_debug) {
                fprintf(stderr, "[auto] autostart: sources=%zu\n",
                        ts_controller_source_count(g.ctrl));
                fflush(stderr);
            }
            RefreshAll();
            OnStartAnalyze();
            if (g.auto_debug) {
                fprintf(stderr, "[auto] autostart: running=%d\n",
                        ts_controller_is_running(g.ctrl));
                fflush(stderr);
            }
        }
        return 0;

    case WM_SIZE:
        LayoutControls();
        return 0;

    case WM_GETMINMAXINFO:
        ((MINMAXINFO *)lp)->ptMinTrackSize.x = S(900);
        ((MINMAXINFO *)lp)->ptMinTrackSize.y = S(620);
        return 0;

    case WM_DPICHANGED: {
        RECT *r = (RECT *)lp;
        g.dpi = HIWORD(wp);
        if (g.dpi <= 0) g.dpi = 96;
        RecreateFonts();
        SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        ApplyFontsRecursive(hwnd);
        LayoutControls();
        return 0;
    }

    case WM_TIMER:
        if (wp == IDC_TIMER_STATUS) {
            if (ts_controller_is_running(g.ctrl)) {
                RefreshStatus();
                MaybeShowWaitPrompt();
            }
        }
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case IDC_BTN_ADDFILE: OnAddFile(); return 0;
        case IDC_BTN_ADDTEXT:
            if (TextInputDialog(hwnd)) RefreshAll();
            return 0;
        case IDC_BTN_START: OnStartAnalyze(); return 0;
        case IDC_BTN_CANCEL:
            ts_controller_cancel(g.ctrl);
            SetControlTextUtf8(g.st_status, "已请求取消…（客户端取消不保证服务端停止推理）");
            return 0;
        case IDC_BTN_EXPORT: OnExport(); return 0;
        case IDC_CHK_GROUP:
            g.group_by_level = (SendMessageW(g.chk_group, BM_GETCHECK, 0, 0) == BST_CHECKED);
            ApplyGrouping();
            return 0;
        case IDC_BTN_DONE: {
            const TsPlan *plan = ts_controller_plan(g.ctrl);
            if (plan != NULL && g.sel_task != SIZE_MAX && g.sel_task < plan->task_count) {
                int done = (plan->tasks[g.sel_task].actual_status == TS_ACTUAL_DONE);
                ts_controller_set_actual(g.ctrl, g.sel_task, !done);
                RefreshAll();
            }
            return 0;
        }
        case IDC_BTN_EDITF:
            if (FieldsDialog(hwnd, g.sel_task)) RefreshAll();
            return 0;
        case IDC_BTN_EDITD:
            if (DepsDialog(hwnd, g.sel_task)) RefreshAll();
            return 0;
        case IDC_BTN_EDITP:
            if (PrecondDialog(hwnd, g.sel_task)) RefreshAll();
            return 0;
        default:
            return 0;
        }

    case WM_NOTIFY:
        return HandleNotify(lp);

    case TS_WM_NOTIFY: {
        int ev = (int)wp;
        if (g.auto_mode) {
            char stage[128];
            ts_controller_stage_text(g.ctrl, stage, sizeof(stage));
            fprintf(stderr, "[auto] notify ev=%d stage=%s running=%d\n",
                    ev, stage, ts_controller_is_running(g.ctrl));
            fflush(stderr);
        }
        if (ev == TS_EVT_FINISHED) {
            /* 结果（或取消）已到：关闭过期的 120 秒提示，再展示结果 */
            CloseWaitPrompt();
            {
                const TsAnalyzeResult *r = ts_controller_last_analyze(g.ctrl);
                char err[512];
                if (r != NULL && r->ok) {
                    if (ts_controller_adopt_result(g.ctrl, err, sizeof(err)) != 0) {
                        if (g.auto_mode) {
                            printf("[auto] adopt failed: %s\n", err);
                        } else {
                            MessageBoxU8(hwnd, err, "未能采纳分析结果", MB_ICONWARNING);
                        }
                    }
                } else if (r != NULL && r->error_kind != TS_MODEL_ERR_CANCELLED) {
                    if (g.auto_mode) {
                        printf("[auto] analyze failed: kind=%s error=%s\n",
                               ts_model_error_kind_name(r->error_kind),
                               (r->error != NULL) ? r->error : "(无)");
                    } else {
                        MessageBoxU8(hwnd, (r->error != NULL) ? r->error : "分析失败",
                                     "分析失败", MB_ICONERROR);
                    }
                }
            }
        }
        RefreshAll();
        /*
         * 非交互验收模式：分析结束后导出到命令行给定的路径，然后关闭窗口。
         * 放在 RefreshAll 之后，保证导出的是已经采纳并排序好的结果。
         */
        if (ev == TS_EVT_FINISHED && g.auto_mode && !g.auto_export_done) {
            g.auto_export_done = 1;   /* 只尝试一次 */
            if (ts_controller_has_plan(g.ctrl)) {
                fprintf(stderr, "[auto] TS_EVT_FINISHED: exporting\n");
                fflush(stderr);
                OnExport();
            } else {
                /*
                 * 分析失败（如请求前鉴权预检拦下、网络错误等）时没有可导出的计划。
                 * 这里绝不能停在“窗口还在、却什么都不说”的状态：把失败原因写到
                 * 标准输出（上面的分支已打印 kind/error），然后关窗退出。
                 */
                printf("[auto] 分析未成功，未生成导出文件。\n");
                fflush(stdout);
            }
            DestroyWindow(hwnd);
            return 0;
        }
        return 0;
    }

    case WM_CLOSE:
        if (ts_controller_is_running(g.ctrl)) {
            int r = MessageBoxW(hwnd, L"分析仍在进行。是否取消本次请求并退出？",
                                L"TaskScheduler", MB_YESNO | MB_ICONQUESTION);
            if (r != IDYES) return 0;
            ts_controller_cancel(g.ctrl);
        }
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        KillTimer(hwnd, IDC_TIMER_STATUS);
        CloseWaitPrompt();
        if (g.ctrl != NULL) {
            ts_controller_destroy(g.ctrl);
            g.ctrl = NULL;
        }
        if (g.font_ui != NULL) { DeleteObject(g.font_ui); g.font_ui = NULL; }
        if (g.font_bold != NULL) { DeleteObject(g.font_bold); g.font_bold = NULL; }
        PostQuitMessage(0);
        return 0;

    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------------ */
/* 入口                                                                */
/* ------------------------------------------------------------------ */

static void EnableDpiAwareness(void)
{
    typedef BOOL(WINAPI * PFN_SetProcessDpiAwarenessContext)(void *);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 != NULL) {
        PFN_SetProcessDpiAwarenessContext p =
            (PFN_SetProcessDpiAwarenessContext)(void *)GetProcAddress(
                user32, "SetProcessDpiAwarenessContext");
        if (p != NULL) {
            /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4 */
            if (p((void *)(INT_PTR)-4)) return;
        }
    }
    SetProcessDPIAware();
}

static void OnControllerNotify(void *userdata, int event)
{
    HWND hwnd = (HWND)userdata;
    /* 在工作线程中被调用：只投递消息，绝不直接操作控件。 */
    if (hwnd != NULL) {
        PostMessageW(hwnd, TS_WM_NOTIFY, (WPARAM)event, 0);
    }
}

int ts_gui_run(HINSTANCE instance, const TsConfig *cfg, int n_cmd_show)
{
    return ts_gui_run_ex(instance, cfg, n_cmd_show, NULL, NULL);
}

int ts_gui_run_ex(HINSTANCE instance, const TsConfig *cfg, int n_cmd_show,
                  const wchar_t *auto_input_path, const wchar_t *auto_export_path)
{
    WNDCLASSEXW wc;
    HWND hwnd;
    MSG msg;
    RECT rc;
    int width, height;

    EnableDpiAwareness();

    {
        INITCOMMONCONTROLSEX icc;
        icc.dwSize = sizeof(icc);
        icc.dwICC = ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES;
        InitCommonControlsEx(&icc);
    }

    memset(&g, 0, sizeof(g));
    g.inst = instance;
    g.cfg = cfg;
    g.sel_task = SIZE_MAX;
    if (auto_input_path != NULL) {
        wcsncpy_s(g.init_input, _countof(g.init_input), auto_input_path, _TRUNCATE);
    }
    if (auto_export_path != NULL) {
        wcsncpy_s(g.init_export, _countof(g.init_export), auto_export_path, _TRUNCATE);
    }
    g.auto_mode = (g.init_input[0] != L'\0') ? 1 : 0;
    g.auto_debug = g.auto_mode;

    if (g.auto_mode) {
        /*
         * 非交互验收模式：把关键步骤写到 stderr（GUI 子系统下由调用方重定向捕获），
         * 便于 CI/验收脚本判断卡在哪一步；交互式使用不会走到这里。
         */
        fprintf(stderr, "[auto] input=%ls export=%ls mock=%d\n",
                g.init_input, g.init_export, (cfg != NULL) ? cfg->mock_mode : -1);
        fflush(stderr);
    }

    g.ctrl = ts_controller_create(cfg);
    if (g.ctrl == NULL) {
        MessageBoxW(NULL, L"创建控制器失败（内存不足）。", L"TaskScheduler", MB_ICONERROR);
        return 1;
    }
    ts_controller_set_notify(g.ctrl, OnControllerNotify, NULL);

    RegisterDialogClass(instance, L"TsEditDlg", EditDlgProc);
    RegisterDialogClass(instance, L"TsWaitPrompt", WaitPromptProc);

    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = MainWndProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"TsMainWindow";
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    if (RegisterClassExW(&wc) == 0) {
        ts_controller_destroy(g.ctrl);
        g.ctrl = NULL;
        MessageBoxW(NULL, L"注册窗口类失败。", L"TaskScheduler", MB_ICONERROR);
        return 1;
    }

    {
        HDC dc = GetDC(NULL);
        int dpi = (dc != NULL) ? GetDeviceCaps(dc, LOGPIXELSX) : 96;
        if (dc != NULL) ReleaseDC(NULL, dc);
        if (dpi <= 0) dpi = 96;
        width = MulDiv(1280, dpi, 96);
        height = MulDiv(860, dpi, 96);
    }
    rc.left = 0; rc.top = 0; rc.right = width; rc.bottom = height;
    AdjustWindowRectEx(&rc, WS_OVERLAPPEDWINDOW, FALSE, 0);

    hwnd = CreateWindowExW(0, L"TsMainWindow",
                           L"TaskScheduler — 任务分析器（模型只分析，程序只规划与展示）",
                           WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT,
                           rc.right - rc.left, rc.bottom - rc.top,
                           NULL, NULL, instance, NULL);
    if (hwnd == NULL) {
        ts_controller_destroy(g.ctrl);
        g.ctrl = NULL;
        MessageBoxW(NULL, L"创建主窗口失败。", L"TaskScheduler", MB_ICONERROR);
        return 1;
    }

    ShowWindow(hwnd, n_cmd_show);
    UpdateWindow(hwnd);

    /* 通知回调需要 hwnd，此处补上（工作线程尚未启动）。 */
    ts_controller_set_notify(g.ctrl, OnControllerNotify, (void *)hwnd);

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return (int)msg.wParam;
}

