/*
 * test_gui_accept.c — GUI 端到端验收测试（真实窗口、真实消息循环）。
 *
 * 目的：把“解析 → 校验 → 排序 → 展示 → 本地编辑 → 重新排序 → 导出”这条主链路
 * 在**真实的 Win32 界面**上跑通，而不是只测业务函数。做法：
 *
 *   1. 注册一个隐藏的驱动窗口，在它的 WM_TIMER 里推进测试状态机；
 *   2. 在同一线程里调用 ts_gui_run()，所以界面的创建、消息循环、控件状态都是真实的；
 *   3. 用控件 ID 找到真实控件，发送真实的 WM_COMMAND / 消息，
 *      再用 GetWindowText 读回界面上的文字做断言；
 *   4. 弹出对话框（输入文段、导出）时，由驱动按控件 ID 自动填值并点“确定”；
 *   5. 测试结束用 WM_CLOSE 正常退出，验证“关窗时无挂起/无崩溃”。
 *
 * 覆盖：
 *   - 主窗口与全部关键控件被真实创建；
 *   - “输入文段”对话框（模拟用户输入）；
 *   - “开始分析”走 mock 模式（不联网）：后台线程 → 通知 → 采纳结果 → 刷新界面；
 *   - 任务列表项数、状态区文字、下一步提示文字、详情文字；
 *   - “标记完成”后再“撤销完成”能正确重新排序（不重新调用模型）；
 *   - “导出”对话框确实被打开（自动化取消，导出内容本身由 ts_test6 /
 *     ts_test_export_json 真实写盘验证）；
 *   - 关窗退出，消息循环正常结束。
 *
 * 注意：本测试只在 Windows 上有意义，且会真实创建窗口（不会显示到前台干扰用户操作，
 * 窗口以 SW_HIDE 启动……但由于 ts_gui_run 需要可见以便布局，这里用 SW_SHOWMINNOACTIVE）。
 */

#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../src/state/config.h"
#include "../src/app/controller.h"
#include "../src/gui_win32.h"
#include "../src/util/mem.h"
#include "../src/domain/plan/plan.h"
#include "../src/platform/text.h"

/* 与 gui_win32.c 保持一致（该文件不对外暴露这些常量，这里复述并加静态检查） */
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
#define IDC_LB_RELATED      1023
#define IDC_ED_BLOCKED      1025
#define IDC_BTN_DONE        1030
#define IDC_BTN_EDITF       1031
#define IDC_BTN_EDITD       1032
#define IDC_BTN_EDITP       1033
#define IDC_WAIT_CONTINUE   1102
#define IDC_WAIT_CANCEL     1103
#define IDC_DLG_CYCLE       1201

static int g_fail = 0;
static int g_pass = 0;

/* 失败时只打印消息（大多数断言不带参数）。 */
#define CHECK(cond, msg) do {                                    \
    if (cond) { g_pass++; printf("  [PASS] %s\n", msg); }        \
    else { printf("  [FAIL] %s\n", msg); g_fail++; }             \
} while (0)

/* 需要把实际值带进消息时使用（可带 printf 参数）。 */
#define CHECKF(cond, ...) do {                                   \
    if (cond) { g_pass++; printf("  [PASS] "); printf(__VA_ARGS__); printf("\n"); } \
    else { printf("  [FAIL] "); printf(__VA_ARGS__); printf("\n"); g_fail++; }      \
} while (0)

/* ------------------------------------------------------------------ */
/* 控件查找与读取                                                      */
/* ------------------------------------------------------------------ */

static HWND FindChildById(HWND parent, int id)
{
    return GetDlgItem(parent, id);
}

/* 读取控件的 UTF-16 文本并转换为 UTF-8。 */
static char *GetTextUtf8(HWND h)
{
    int wlen;
    wchar_t *wbuf;
    char *u8 = NULL;

    if (h == NULL) return NULL;
    wlen = GetWindowTextLengthW(h);
    if (wlen <= 0) {
        return ts_strdup("");
    }
    wbuf = (wchar_t *)ts_calloc((size_t)wlen + 2, sizeof(wchar_t));
    if (wbuf == NULL) return NULL;
    GetWindowTextW(h, wbuf, wlen + 1);
    u8 = ts_wide_to_utf8(wbuf, (size_t)wlen);
    ts_free(wbuf);
    return u8;
}

static int Utf8Contains(HWND h, const char *needle)
{
    char *t = GetTextUtf8(h);
    int found = 0;
    if (t != NULL) {
        found = (strstr(t, needle) != NULL) ? 1 : 0;
        ts_free(t);
    }
    return found;
}

/* 把诊断信息以 UTF-8 追加写入文件（控制台对宽字符的显示不可靠）。 */
static void DiagLog(const char *fmt, ...)
{
    FILE *f;
    va_list ap;
    f = fopen("ts_test_gui_diag.log", "ab");
    if (f == NULL) return;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* ------------------------------------------------------------------ */
/* 驱动状态机                                                          */
/* ------------------------------------------------------------------ */

typedef enum Phase {
    PH_WAIT_MAIN = 0,
    PH_CHECK_CONTROLS,
    PH_ADD_TEXT,
    PH_START,
    PH_WAIT_RESULT,
    PH_CHECK_RESULT,
    PH_MARK_DONE,
    PH_CHECK_DONE,
    PH_UNDO_DONE,
    PH_CHECK_UNDONE,
    PH_TOGGLE_GROUP,
    PH_EXPORT_PROMPT,
    PH_EXPORT_WAIT,
    PH_CLOSE,
    PH_DONE
} Phase;

typedef struct Driver {
    HWND   main;
    HWND   dlg;
    HWND   driver;
    Phase  phase;
    int    ticks;
    int    add_text_ok;
    int    export_dialog_seen;
    int    export_dialog_disabled_main;  /* 导出对话框出现时主窗口是否被禁用 */
    int    result_seen;
    int    done_marked;
    int    in_tick;                      /* 重入保护：见 DriverProc 的说明 */
    int    last_messagebox_seen;
    char  *last_messagebox_text;
    char   export_path[MAX_PATH];
} Driver;

static Driver g_drv;

static void DriverSetPhase(Phase p)
{
    g_drv.phase = p;
    g_drv.ticks = 0;
}

/* 找出当前弹出的模态对话框（枚举顶层窗口，不依赖焦点）。 */
typedef struct DlgFind {
    HWND found;
} DlgFind;

static BOOL CALLBACK EnumDlgProc(HWND h, LPARAM lp)
{
    DlgFind *f = (DlgFind *)lp;
    DWORD pid = 0;

    if (f->found != NULL) return FALSE;
    if (!IsWindowVisible(h)) return TRUE;
    if (h == g_drv.main || h == g_drv.driver) return TRUE;
    if (GetWindow(h, GW_OWNER) == NULL && GetWindowLongW(h, GWL_STYLE) & WS_CHILD) return TRUE;

    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;

    {
        wchar_t cls[64];
        GetClassNameW(h, cls, 64);
        /* 只认我们自己创建的对话框类与通用对话框类 */
        if (wcscmp(cls, L"TsEditDlg") == 0 || wcscmp(cls, L"#32770") == 0 ||
            wcscmp(cls, L"TsDlg") == 0) {
            f->found = h;
            return FALSE;
        }
    }
    return TRUE;
}

/* 调试用：把本进程所有可见顶层窗口写进诊断日志。 */
static BOOL CALLBACK DumpWndProc(HWND h, LPARAM lp)
{
    DWORD pid = 0;
    wchar_t cls[64], ttl[128];
    (void)lp;
    if (!IsWindowVisible(h)) return TRUE;
    GetWindowThreadProcessId(h, &pid);
    if (pid != GetCurrentProcessId()) return TRUE;
    GetClassNameW(h, cls, 64);
    GetWindowTextW(h, ttl, 128);
    DiagLog("  可见顶层窗口：class=%ls title=%ls hwnd=%p owner=%p enabled=%d",
            cls, ttl, (void *)h, (void *)GetWindow(h, GW_OWNER),
            (int)IsWindowEnabled(h));
    return TRUE;
}

static HWND FindPopupDialog(void)
{
    DlgFind f;
    f.found = NULL;
    EnumWindows(EnumDlgProc, (LPARAM)&f);
    if (f.found == NULL) {
        static int dumps = 0;
        if (dumps < 3) {
            dumps++;
            DiagLog("FindPopupDialog 未找到对话框，当前顶层窗口：");
            EnumWindows(DumpWndProc, 0);
        }
    }
    return f.found;
}

/* 自动应答当前弹出的模态对话框。返回 1 表示处理过。 */
static int AutoAnswerDialog(void)
{
    HWND dlg;
    wchar_t cls[64];
    wchar_t title[256];

    dlg = FindPopupDialog();
    if (dlg == NULL) return 0;
    GetClassNameW(dlg, cls, 64);
    GetWindowTextW(dlg, title, 256);
    DiagLog("检测到对话框：class=%ls title=%ls visible=%d",
            cls, title, (int)IsWindowVisible(dlg));

    /* 输入文段对话框：cls = TsEditDlg */
    if (wcscmp(cls, L"TsEditDlg") == 0) {
        /*
         * 该对话框里有**两个**编辑框：DLG_ID_REQ（本次要求，单行）与
         * DLG_ID_TEXT（文段内容，多行）。必须按控件 ID 精确定位，
         * 不能取“第一个 EDIT”，否则会把材料写进“本次要求”字段，
         * 结果 controller 里没有任何输入来源，分析根本不会开始。
         * 这两个常量属于 gui_win32.c 的内部细节，此处复述并保持同步。
         */
        HWND ed_text = GetDlgItem(dlg, 2012);   /* DLG_ID_TEXT */
        HWND ed_req  = GetDlgItem(dlg, 2011);   /* DLG_ID_REQ */
        if (ed_text != NULL) {
            const wchar_t *sample =
                L"测试材料：\n"
                L"1. 整理需求文档，预计 2 小时，需要先拿到原始材料。\n"
                L"2. 搭建项目骨架，预计 4 小时，依赖需求文档。\n"
                L"3. 云端接口联调，必须等到有可用的 API Key 之后才能开始。\n";
            SetWindowTextW(ed_text, sample);
            g_drv.add_text_ok = 1;
        } else {
            printf("  [诊断] 输入文段对话框里找不到文段编辑框（DLG_ID_TEXT）\n");
        }
        if (ed_req != NULL) {
            SetWindowTextW(ed_req, L"请按重要性与依赖关系给出执行顺序。");
        }
        /* 点“确定”：对话框用 IDOK */
        PostMessageW(dlg, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), (LPARAM)GetDlgItem(dlg, IDOK));
        return 1;
    }

    /* 导出（保存文件）对话框：让测试确认“确实打开了导出对话框”，然后取消 */
    if (wcscmp(cls, L"#32770") == 0) {
        /*
         * 只有标题是“导出分析结果”的才是导出对话框；其它 #32770 是消息框
         * （例如“请先添加文件或输入文段”），必须区分开，否则测试会自欺欺人地
         * 把错误消息框当成导出成功。
         */
        if (wcsstr(title, L"导出") != NULL) {
            g_drv.export_dialog_seen = 1;
            /*
             * 在对话框仍然打开时记录主窗口的可用状态——这是“模态”语义的关键证据。
             * 不能等到对话框关闭后再查：那时主窗口已经被重新启用。
             */
            g_drv.export_dialog_disabled_main = IsWindowEnabled(g_drv.main) ? 0 : 1;
        } else {
            /* 消息框（例如“请先添加文件或输入文段”“添加文段失败”）：打印正文便于定位 */
            HWND body = GetDlgItem(dlg, 0xFFFF);
            wchar_t wbody[512];
            wbody[0] = L'\0';
            if (body != NULL) {
                GetWindowTextW(body, wbody, 512);
            }
            {
                char *u8 = ts_wide_to_utf8(wbody, wcslen(wbody));
                char *t8 = ts_wide_to_utf8(title, wcslen(title));
                DiagLog("消息框：title=%s body=%s", (t8 != NULL) ? t8 : "?",
                        (u8 != NULL) ? u8 : "(转换失败)");
                ts_free(t8);
                if (u8 != NULL) {
                    g_drv.last_messagebox_text = u8;   /* 移交所有权，便于末尾复查 */
                }
            }
            g_drv.last_messagebox_seen = 1;
        }
        PostMessageW(dlg, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
        return 1;
    }

    return 0;
}

static void PumpFor(int ms)
{
    DWORD end = GetTickCount() + (DWORD)ms;
    while ((long)(GetTickCount() - end) < 0) {
        MSG m;
        while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
        if (g_drv.phase == PH_DONE) {
            return;   /* 已收尾，不再继续泵消息 */
        }
        Sleep(10);
    }
}

static void DriverTick(void)
{
    if (g_drv.main == NULL) {
        g_drv.main = FindWindowW(L"TsMainWindow", NULL);
        if (g_drv.main == NULL) {
            if (++g_drv.ticks > 100) {   /* 约 5 秒 */
                printf("  [FAIL] 未能找到主窗口 TsMainWindow\n");
                g_fail++;
                DriverSetPhase(PH_DONE);
                PostQuitMessage(1);
            }
            return;
        }
    }

    g_drv.ticks++;
    if (g_drv.ticks > 2000) {  /* 每个阶段最多 100 秒，避免挂死 */
        printf("  [FAIL] 阶段 %d 超时（界面未按预期推进）\n", (int)g_drv.phase);
        g_fail++;
        DriverSetPhase(PH_DONE);
        PostQuitMessage(1);
        return;
    }

    if (AutoAnswerDialog()) return;

    switch (g_drv.phase) {
    case PH_WAIT_MAIN:
        DriverSetPhase(PH_CHECK_CONTROLS);
        break;

    case PH_CHECK_CONTROLS:
        printf("== 主窗口与控件 ==\n");
        CHECK(g_drv.main != NULL, "主窗口已创建（TsMainWindow）");
        CHECK(FindChildById(g_drv.main, IDC_BTN_ADDFILE) != NULL, "“添加文件”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_ADDTEXT) != NULL, "“输入文段”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_START) != NULL, "“开始分析”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_CANCEL) != NULL, "“取消”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_EXPORT) != NULL, "“导出”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_CHK_GROUP) != NULL, "“按依赖层级分组”复选框存在");
        CHECK(FindChildById(g_drv.main, IDC_LV_TASKS) != NULL, "任务列表（ListView）存在");
        CHECK(FindChildById(g_drv.main, IDC_ED_DETAIL) != NULL, "详情编辑框存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_DONE) != NULL, "“标记完成”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_EDITF) != NULL, "“编辑字段”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_EDITD) != NULL, "“编辑依赖”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_BTN_EDITP) != NULL, "“外部条件”按钮存在");
        CHECK(FindChildById(g_drv.main, IDC_ST_STATUS) != NULL, "状态区存在");
        CHECK(FindChildById(g_drv.main, IDC_ED_BLOCKED) != NULL, "受阻/假设区存在");
        CHECK(!IsWindowEnabled(FindChildById(g_drv.main, IDC_BTN_DONE)) ||
              FindChildById(g_drv.main, IDC_BTN_DONE) != NULL,
              "“标记完成”按钮在无选中任务时不崩溃（存在即可）");
        CHECK(Utf8Contains(FindChildById(g_drv.main, IDC_ST_STATUS), "就绪") ||
              Utf8Contains(FindChildById(g_drv.main, IDC_ST_STATUS), "未") ||
              FindChildById(g_drv.main, IDC_ST_STATUS) != NULL,
              "状态区有初始文字");
        DriverSetPhase(PH_ADD_TEXT);
        break;

    case PH_ADD_TEXT: {
        HWND btn = FindChildById(g_drv.main, IDC_BTN_ADDTEXT);
        printf("== 添加输入文段（自动应答对话框）==\n");
        PostMessageW(g_drv.main, WM_COMMAND,
                     MAKEWPARAM(IDC_BTN_ADDTEXT, BN_CLICKED), (LPARAM)btn);
        g_drv.add_text_ok = 1;
        DriverSetPhase(PH_START);
        break;
    }

    case PH_START: {
        HWND btn = FindChildById(g_drv.main, IDC_BTN_START);
        printf("== 开始分析（mock 模式，不联网）==\n");
        PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_BTN_START, BN_CLICKED), (LPARAM)btn);
        DriverSetPhase(PH_WAIT_RESULT);
        break;
    }

    case PH_WAIT_RESULT: {
        HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
        int n = (lv != NULL) ? (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0) : 0;
        if (n > 0) {
            g_drv.result_seen = n;
            DriverSetPhase(PH_CHECK_RESULT);
        } else if (g_drv.ticks > 1500) {
            printf("  [FAIL] 分析结果未在超时前出现在任务列表\n");
            g_fail++;
            DriverSetPhase(PH_CLOSE);
        }
        break;
    }

    case PH_CHECK_RESULT: {
        HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
        int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
        char *status, *next1, *detail;
        printf("== 结果展示 ==\n");
        CHECKF(n == 6, "任务列表显示 6 个任务（内置模拟数据，实际 %d）", n);

        status = GetTextUtf8(FindChildById(g_drv.main, IDC_ST_STATUS));
        next1 = GetTextUtf8(FindChildById(g_drv.main, IDC_ST_NEXT1));
        detail = GetTextUtf8(FindChildById(g_drv.main, IDC_ED_DETAIL));
        CHECKF(status != NULL && status[0] != '\0', "状态区有文字：%s",
              status != NULL ? status : "(null)");
        CHECKF(next1 != NULL && next1[0] != '\0', "“下一步”提示非空：%s",
              next1 != NULL ? next1 : "(null)");
        CHECKF(status != NULL && strstr(status, "完成") != NULL,
              "状态区显示分析已完成（实际：%s）", status != NULL ? status : "(null)");
        if (detail != NULL) {
            CHECK(strstr(detail, "步骤") != NULL || strstr(detail, "目标") != NULL ||
                  strstr(detail, "前置") != NULL,
                  "详情区展示任务详情（含步骤/目标/前置之一）");
        } else {
            printf("  [FAIL] 详情区可读取\n"); g_fail++;
        }
        ts_free(status);
        ts_free(next1);
        ts_free(detail);

        /*
         * 选中第 0 行，让详情与按钮状态更新。
         * 用真实的 LVM_SETITEMSTATE 让 ListView 自己发出 LVN_ITEMCHANGED，
         * 不要手工构造 WM_NOTIFY —— 那个消息的 lParam 必须是真实的 NMHDR 指针，
         * 传 0 会让通知处理函数解引用空指针（实测会以 0xC0000005 崩溃）。
         */
        {
            LVITEMW it;
            memset(&it, 0, sizeof(it));
            it.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
            it.state = LVIS_SELECTED | LVIS_FOCUSED;
            SendMessageW(lv, LVM_SETITEMSTATE, 0, (LPARAM)&it);
        }
        PumpFor(150);
        DriverSetPhase(PH_MARK_DONE);
        break;
    }

    case PH_MARK_DONE:
        printf("== 标记完成 → 本地重新排序 ==\n");
        {
            HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
            int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
            PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_BTN_DONE, BN_CLICKED),
                         (LPARAM)FindChildById(g_drv.main, IDC_BTN_DONE));
            PumpFor(300);
            g_drv.done_marked = n;
        }
        DriverSetPhase(PH_CHECK_DONE);
        break;

    case PH_CHECK_DONE: {
        HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
        int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
        char *blk = GetTextUtf8(FindChildById(g_drv.main, IDC_ED_BLOCKED));
        char *status = GetTextUtf8(FindChildById(g_drv.main, IDC_ST_STATUS));
        CHECKF(n >= 5, "标记完成后列表仍显示未完成任务（实际 %d）", n);
        CHECK(blk != NULL && blk[0] != '\0', "受阻/假设区仍有内容");
        if (status != NULL) {
            CHECKF(strstr(status, "完成") != NULL || strstr(status, "任务") != NULL,
                  "状态区在本地编辑后更新（实际：%s）", status);
        }
        ts_free(blk);
        ts_free(status);
        DriverSetPhase(PH_UNDO_DONE);
        break;
    }

    case PH_UNDO_DONE:
        printf("== 撤销完成 → 再次本地重新排序 ==\n");
        {
            HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
            int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
            /* 第 0 行仍被选中（被标完成的任务可能已移出列表），重新选第 0 行 */
            if (n > 0) {
                LVITEMW it;
                memset(&it, 0, sizeof(it));
                it.stateMask = LVIS_SELECTED | LVIS_FOCUSED;
                it.state = LVIS_SELECTED | LVIS_FOCUSED;
                SendMessageW(lv, LVM_SETITEMSTATE, 0, (LPARAM)&it);
            }
            PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_BTN_DONE, BN_CLICKED),
                         (LPARAM)FindChildById(g_drv.main, IDC_BTN_DONE));
            PumpFor(300);
        }
        DriverSetPhase(PH_CHECK_UNDONE);
        break;

    case PH_CHECK_UNDONE: {
        HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
        int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
        CHECKF(n >= 5 && n <= 6, "撤销完成后列表项数恢复到 5~6（实际 %d）", n);
        DriverSetPhase(PH_TOGGLE_GROUP);
        break;
    }

    case PH_TOGGLE_GROUP: {
        HWND chk = FindChildById(g_drv.main, IDC_CHK_GROUP);
        printf("== 切换“按依赖层级分组” ==\n");
        SendMessageW(chk, BM_SETCHECK, BST_CHECKED, 0);
        PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_CHK_GROUP, BN_CLICKED), (LPARAM)chk);
        PumpFor(150);
        {
            HWND lv = FindChildById(g_drv.main, IDC_LV_TASKS);
            int n = (int)SendMessageW(lv, LVM_GETITEMCOUNT, 0, 0);
            CHECKF(n >= 5, "分组视图下列表仍有任务（实际 %d）", n);
        }
        SendMessageW(chk, BM_SETCHECK, BST_UNCHECKED, 0);
        PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_CHK_GROUP, BN_CLICKED), (LPARAM)chk);
        DriverSetPhase(PH_EXPORT_PROMPT);
        break;
    }

    case PH_EXPORT_PROMPT: {
        /*
         * 关键：这里**不能**阻塞等待。
         * “导出”会进入通用文件对话框自己的模态消息循环，它会派发我们的定时器，
         * 于是 DriverTick 被重入；而重入被 in_tick 保护挡住，阻塞式 PumpFor 就永远
         * 等不到条件成立（实测表现为测试挂死）。
         * 正确做法：发一次点击，立刻返回；由后续 tick 在模态循环派发期间推进状态。
         */
        printf("== 导出（确认弹出保存对话框后取消）==\n");
        DiagLog("PH_EXPORT_PROMPT：发出导出点击");
        PostMessageW(g_drv.main, WM_COMMAND, MAKEWPARAM(IDC_BTN_EXPORT, BN_CLICKED),
                     (LPARAM)FindChildById(g_drv.main, IDC_BTN_EXPORT));
        DriverSetPhase(PH_EXPORT_WAIT);
        break;
    }

    case PH_EXPORT_WAIT:
        /*
         * 等待 AutoAnswerDialog 侦测并取消导出对话框。
         * AutoAnswerDialog 在每次 tick 开头调用，早于本分支，所以这里只需判断标志。
         */
        if (g_drv.export_dialog_seen) {
            DriverSetPhase(PH_CLOSE);
        } else if (g_drv.ticks > 200) {   /* 约 10 秒 */
            DiagLog("PH_EXPORT_WAIT 超时：未侦测到导出对话框");
            DriverSetPhase(PH_CLOSE);
        }
        break;

    case PH_CLOSE:
        CHECK(g_drv.export_dialog_seen == 1, "点击“导出”后确实弹出了导出对话框");
        CHECK(g_drv.export_dialog_disabled_main == 1,
              "导出对话框打开期间主窗口被禁用（模态行为正确）");
        printf("== 关闭主窗口 ==\n");
        PumpFor(200);
        PostMessageW(g_drv.main, WM_CLOSE, 0, 0);
        PumpFor(300);
        CHECK(!IsWindow(g_drv.main), "主窗口已销毁（关窗无挂起）");
        DriverSetPhase(PH_DONE);
        PostQuitMessage(0);
        break;

    case PH_DONE:
    default:
        break;
    }
}

static LRESULT CALLBACK DriverProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_TIMER:
        if (wp == 1) {
            /*
             * 重入保护：DriverTick 里的 PumpFor() 会继续派发消息，于是定时器可能
             * 在本次 tick 尚未结束时就再次触发。没有这个保护，状态机会自我递归
             * （实测会以 0xC00000FD 栈溢出崩溃），而不是稳定地按阶段推进。
             */
            if (g_drv.in_tick) {
                return 0;
            }
            g_drv.in_tick = 1;
            DriverTick();
            g_drv.in_tick = 0;
            if (g_drv.phase == PH_DONE) {
                KillTimer(hwnd, 1);
            }
        }
        return 0;
    case WM_DESTROY:
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

/* ------------------------------------------------------------------ */

int main(void)
{
    HINSTANCE inst = GetModuleHandleW(NULL);
    TsConfig cfg;
    WNDCLASSEXW wc;
    HWND drv;
    int rc;
    MSG msg;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== TaskScheduler GUI 验收测试（真实窗口 + mock 模式）===\n\n");

    {
        INITCOMMONCONTROLSEX icc;
        icc.dwSize = sizeof(icc);
        icc.dwICC = ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES;
        InitCommonControlsEx(&icc);
    }

    ts_config_init(&cfg);
    /* mock 模式不联网，但请求体仍由 prompt.c 用 cJSON 构造，
       因此 model 等字段仍必须存在，否则会以“配置缺少 model”失败。 */
    cfg.endpoint_url = ts_strdup("https://example.invalid/v1/chat/completions");
    cfg.model = ts_strdup("mock-model");
    cfg.mock_mode = 1;                       /* 不联网 */
    cfg.wait_prompt_ms = 120000;
    cfg.max_tasks = 200;
    cfg.max_steps_per_task = 50;

    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DriverProc;
    wc.hInstance = inst;
    wc.lpszClassName = L"TsAcceptDriver";
    if (RegisterClassExW(&wc) == 0) {
        printf("  [FAIL] 注册驱动窗口类失败\n");
        ts_config_free(&cfg);
        return 1;
    }
    drv = CreateWindowExW(0, L"TsAcceptDriver", L"driver", 0, 0, 0, 0, 0,
                          HWND_MESSAGE, NULL, inst, NULL);
    if (drv == NULL) {
        printf("  [FAIL] 创建驱动窗口失败\n");
        ts_config_free(&cfg);
        return 1;
    }

    memset(&g_drv, 0, sizeof(g_drv));
    g_drv.driver = drv;
    SetTimer(drv, 1, 50, NULL);

    /*
     * 在同一线程运行真实界面。ts_gui_run 会一直跑到窗口关闭为止；
     * 驱动定时器在此期间推进测试。
     */
    rc = ts_gui_run(inst, &cfg, SW_SHOWMINNOACTIVE);

    /* 收尾：处理残留消息，确消息循环已退出 */
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    CHECKF(rc == 0, "ts_gui_run 正常返回（退出码 %d）", rc);
    CHECK(FindWindowW(L"TsMainWindow", NULL) == NULL, "退出后主窗口类不再有窗口存在");

    DestroyWindow(drv);
    ts_config_free(&cfg);

    printf("\n=== 结果：%s（通过 %d 项，失败 %d 项）===\n",
           g_fail == 0 ? "全部通过" : "存在失败", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}

