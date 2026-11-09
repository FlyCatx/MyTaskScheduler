/*
 * ts_toast.cpp — 可操作 Windows 通知的系统集成层（C++/WinRT，无第三方下载依赖）。
 *
 * 为什么需要这一层：0.4.0 的托盘气泡只能“点一下”，无法区分“延长时间/结束任务”，
 * 也无法携带任务身份。0.5.0 需要真正的 Toast：
 *   1) 桌面未打包应用要用 AUMID + 开始菜单快捷方式（System.AppUserModel.ID），
 *      否则系统会静默丢弃通知；
 *   2) 正文点击与两个按钮都用 activationType="protocol" +
 *      taskscheduler://<action>?taskId=…&executionId=…&deadline=… 激活，
 *      身份由 Dart 提供、原样带回，不猜“最后一次通知”；
 *   3) 应用已在运行时，系统会启动第二实例；第二实例（runner/main.cpp）把 URI
 *      经命名管道交给本文件的管道线程，运行实例入队后由 Dart 取走；
 *   4) 应用未运行时，第二实例把 URI 写进待处理文件；本文件在 prepare 及运行期
 *      轮询读取。
 *
 * 投递失败（系统通知关闭/策略禁用/注册失败/WinRT 异常）返回明确 JSON
 * （channel/detail/errorKind），由 Dart 用前台等价操作兜底。
 */

#include "ts_toast.h"

#include "mem.h"

#include "cJSON.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <knownfolders.h>
#include <objbase.h>
#include <propkey.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <winrt/base.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

/* ------------------------------------------------------------------ */
/* 状态                                                                */
/* ------------------------------------------------------------------ */

struct TsToastState {
    TsActivationQueue *queue = nullptr;

    std::mutex mutex;
    std::wstring aumid;
    std::wstring exe_path;
    std::wstring shortcut_path;
    std::wstring pending_path;

    HANDLE stop_event = nullptr;
    HANDLE thread = nullptr;
    HANDLE first_pipe = INVALID_HANDLE_VALUE;
    bool pipe_owner = false;

    bool prepared = false;
    bool shortcut_ready = false;
    bool protocol_ready = false;
    bool toast_supported = false;
    bool toast_enabled = false;
    std::string toast_setting;
    std::string toast_detail;
    std::string shortcut_error;
    std::string protocol_error;
    std::string pipe_error;
};

/* ------------------------------------------------------------------ */
/* 小工具                                                              */
/* ------------------------------------------------------------------ */

static std::wstring wide_from_utf8(const char *s)
{
    int n;
    std::wstring out;
    if (s == NULL || s[0] == '\0') return out;
    n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 1) return out;
    out.resize((size_t)n - 1);
    MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), n);
    return out;
}

static std::string utf8_from_wide(const std::wstring &s)
{
    int n;
    std::string out;
    if (s.empty()) return out;
    n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), NULL, 0, NULL, NULL);
    if (n <= 0) return out;
    out.resize((size_t)n);
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n, NULL, NULL);
    return out;
}

static winrt::hstring hstring_from_utf8(const std::string &s)
{
    if (s.empty()) return winrt::hstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), NULL, 0);
    if (n <= 0) return winrt::hstring();
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return winrt::hstring(w);
}

static std::string hresult_message(const winrt::hresult_error &e)
{
    try {
        return winrt::to_string(e.message());
    } catch (...) {
        return "WinRT 调用失败";
    }
}

static std::string hresult_code(const winrt::hresult_error &e)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "0x%08lX", (unsigned long)(uint32_t)e.code());
    return std::string(buf);
}

static std::string format_hresult(long hr)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "0x%08lX", (unsigned long)hr);
    return std::string(buf);
}

/*
 * Flutter runner 的主线程已经 CoInitializeEx(COINIT_APARTMENTTHREADED)，
 * 再次调用 RoInitialize(MULTITHREADED) 会返回 RPC_E_CHANGED_MODE。COM 已初始化
 * 时 WinRT 仍然可用，因此这里只做一次尝试并吞掉“已初始化”的错误。
 */
static void ensure_winrt_apartment()
{
    static std::once_flag once;
    std::call_once(once, []() {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (const winrt::hresult_error &) {
            /* RPC_E_CHANGED_MODE / 已初始化：继续使用宿主线程的 COM apartment。 */
        } catch (...) {
            /* 其它失败在后续 CreateToastNotifier 处会给出明确错误。 */
        }
    });
}

/*
 * COM 初始化（经典 COM + WinRT 共用 apartment）。
 * prepare 里要先用 IShellLink/IPropertyStore；如果宿主（例如测试探针）还没
 * 初始化 COM，必须自己初始化，否则 CoCreateInstance 返回 CO_E_NOTINITIALIZED，
 * 快捷方式创建失败后 Toast 也会因“找不到 AUMID”而失败。
 */
static void ensure_com_initialized()
{
    static std::once_flag once;
    std::call_once(once, []() {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            return;
        } catch (...) {
            /* 落到经典 COM 初始化（已初始化时返回 S_FALSE / RPC_E_CHANGED_MODE，都可用）。 */
        }
        (void)CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    });
}

/* cJSON 输出 → TsBridgeBuffer（cJSON 的 malloc 与 ts_free/free 兼容）。 */
static int buffer_set_json(TsBridgeBuffer *out, cJSON *root)
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

static void buffer_reset(TsBridgeBuffer *out)
{
    if (out != NULL) {
        out->data = NULL;
        out->length = 0;
    }
}

/* 失败结果 JSON：{ok:false, accepted:false, errorKind, error, channel, ...} */
static int failure_json(TsBridgeBuffer *out, const char *error_kind,
                        const char *message, const char *channel)
{
    cJSON *root = cJSON_CreateObject();
    if (root == NULL) return 1;
    cJSON_AddBoolToObject(root, "ok", 0);
    cJSON_AddBoolToObject(root, "accepted", 0);
    cJSON_AddStringToObject(root, "errorKind", error_kind != NULL ? error_kind : "winrt");
    cJSON_AddStringToObject(root, "error", message != NULL ? message : "通知投递失败");
    cJSON_AddStringToObject(root, "channel", channel != NULL ? channel : "winrt");
    buffer_set_json(out, root);
    return 0;   /* 返回值由调用方决定（show 失败返回 0） */
}

/* ------------------------------------------------------------------ */
/* 开始菜单快捷方式（AUMID）                                            */
/* ------------------------------------------------------------------ */

static bool ensure_start_menu_shortcut(TsToastState *state, const std::wstring &aumid,
                                       const std::wstring &exe, std::string &err)
{
    PWSTR programs = nullptr;
    std::wstring lnk;
    HRESULT hr;
    winrt::com_ptr<IShellLinkW> link;
    winrt::com_ptr<IPropertyStore> store;
    winrt::com_ptr<IPersistFile> file;
    PROPVARIANT pv;

    hr = SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE, nullptr, &programs);
    if (FAILED(hr) || programs == nullptr) {
        char buf[96];
        snprintf(buf, sizeof(buf), "无法定位开始菜单目录（HRESULT=0x%08lX）",
                 (unsigned long)hr);
        err = buf;
        if (programs != nullptr) CoTaskMemFree(programs);
        return false;
    }
    lnk = std::wstring(programs) + L"\\TaskScheduler.lnk";
    CoTaskMemFree(programs);

    hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(link.put()));
    if (FAILED(hr) || !link) {
        err = "无法创建 IShellLink（HRESULT=" + format_hresult(hr) + "）";
        return false;
    }
    link->SetPath(exe.c_str());
    link->SetDescription(L"TaskScheduler");
    link->SetIconLocation(exe.c_str(), 0);

    hr = link->QueryInterface(IID_PPV_ARGS(store.put()));
    if (FAILED(hr) || !store) {
        err = "无法读取快捷方式属性存储";
        return false;
    }
    PropVariantInit(&pv);
    hr = InitPropVariantFromString(aumid.c_str(), &pv);
    if (FAILED(hr)) {
        err = "无法构造 AUMID 属性值";
        return false;
    }
    /* System.AppUserModel.ID：Toast 与开始菜单/任务栏身份必须一致。 */
    hr = store->SetValue(PKEY_AppUserModel_ID, pv);
    PropVariantClear(&pv);
    if (FAILED(hr)) {
        err = "无法写入 System.AppUserModel.ID";
        return false;
    }
    hr = store->Commit();
    if (FAILED(hr)) {
        err = "快捷方式属性提交失败";
        return false;
    }

    hr = link->QueryInterface(IID_PPV_ARGS(file.put()));
    if (FAILED(hr) || !file) {
        err = "无法保存快捷方式";
        return false;
    }
    hr = file->Save(lnk.c_str(), TRUE);
    if (FAILED(hr)) {
        err = "快捷方式写入失败（HRESULT=" + format_hresult(hr) + "，路径=" +
              utf8_from_wide(lnk) + "）";
        return false;
    }
    state->shortcut_path = lnk;
    /*
     * 通知平台会缓存“已安装 AUMID”列表；新建快捷方式后主动通知 Shell 重新扫描，
     * 否则同一进程里紧接着 CreateToastNotifier 可能得到 0x80070490（找不到元素）。
     */
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    return true;
}

/* ------------------------------------------------------------------ */
/* HKCU URL 协议注册                                                   */
/* ------------------------------------------------------------------ */

static bool reg_set_string(HKEY key, const wchar_t *name, const wchar_t *value,
                           std::string &err)
{
    LONG rc = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value,
                             (DWORD)((wcslen(value) + 1) * sizeof(wchar_t)));
    if (rc != ERROR_SUCCESS) {
        char buf[96];
        snprintf(buf, sizeof(buf), "写入注册表失败（Win32 错误 %ld）", (long)rc);
        err = buf;
        return false;
    }
    return true;
}

static bool ensure_url_protocol(const std::wstring &exe, std::string &err)
{
    HKEY root = nullptr;
    HKEY cmd_key = nullptr;
    LONG rc;
    bool ok = false;
    std::wstring command;

    rc = RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\taskscheduler", 0,
                         nullptr, 0, KEY_WRITE, nullptr, &root, nullptr);
    if (rc != ERROR_SUCCESS) {
        char buf[96];
        snprintf(buf, sizeof(buf), "无法打开 HKCU\\Software\\Classes\\taskscheduler（%ld）",
                 (long)rc);
        err = buf;
        return false;
    }
    if (!reg_set_string(root, L"", L"URL:TaskScheduler Protocol", err)) goto done;
    if (!reg_set_string(root, L"URL Protocol", L"", err)) goto done;
    if (!reg_set_string(root, L"DefaultIcon", (exe + L",0").c_str(), err)) goto done;

    rc = RegCreateKeyExW(root, L"shell\\open\\command", 0, nullptr, 0, KEY_WRITE,
                         nullptr, &cmd_key, nullptr);
    if (rc != ERROR_SUCCESS) {
        char buf[96];
        snprintf(buf, sizeof(buf), "无法写入协议命令键（%ld）", (long)rc);
        err = buf;
        goto done;
    }
    /* 关键：把系统激活参数 "%1" 原样作为唯一命令行参数交给 exe。 */
    command = L"\"" + exe + L"\" \"%1\"";
    if (!reg_set_string(cmd_key, L"", command.c_str(), err)) goto done;
    ok = true;

done:
    if (cmd_key != nullptr) RegCloseKey(cmd_key);
    if (root != nullptr) RegCloseKey(root);
    return ok;
}

/* ------------------------------------------------------------------ */
/* WinRT Toast 能力探测 / 投递                                         */
/* ------------------------------------------------------------------ */

static void probe_toast_capability(TsToastState *state)
{
    using namespace winrt::Windows::UI::Notifications;
    state->toast_supported = false;
    state->toast_enabled = false;
    state->toast_setting = "unknown";
    state->toast_detail.clear();
    try {
        ensure_winrt_apartment();
    } catch (const winrt::hresult_error &e) {
        state->toast_detail = "WinRT apartment 初始化失败：" + hresult_message(e);
        return;
    }
    std::optional<ToastNotifier> notifier;
    try {
        notifier.emplace(
            ToastNotificationManager::CreateToastNotifier(winrt::hstring(state->aumid)));
    } catch (const winrt::hresult_error &e) {
        state->toast_detail = "CreateToastNotifier 失败：" + hresult_message(e) +
                              "（" + hresult_code(e) + "）";
        return;
    } catch (...) {
        state->toast_detail = "CreateToastNotifier 失败（未知异常）";
        return;
    }
    state->toast_supported = true;
    NotificationSetting setting = NotificationSetting::Enabled;
    try {
        setting = notifier->Setting();
    } catch (const winrt::hresult_error &e) {
        /* 部分系统上通知平台会在此返回 0x80070490；这不代表无法投递，
         * 以实际 Show 的结果为准，因此把“开关未知”记录下来继续。 */
        state->toast_setting = "unknown";
        state->toast_detail = "读取通知开关失败（不阻断投递）：" + hresult_message(e) +
                              "（" + hresult_code(e) + "）";
        state->toast_enabled = true;
        return;
    } catch (...) {
        state->toast_setting = "unknown";
        state->toast_detail = "读取通知开关失败（未知异常，不阻断投递）";
        state->toast_enabled = true;
        return;
    }
    {
        state->toast_enabled = (setting == NotificationSetting::Enabled);
        switch (setting) {
        case NotificationSetting::Enabled:
            state->toast_setting = "enabled";
            break;
        case NotificationSetting::DisabledForApplication:
            state->toast_setting = "disabledForApplication";
            state->toast_detail = "系统通知中已关闭本应用的通知";
            break;
        case NotificationSetting::DisabledForUser:
            state->toast_setting = "disabledForUser";
            state->toast_detail = "系统通知已对当前用户关闭";
            break;
        case NotificationSetting::DisabledByGroupPolicy:
            state->toast_setting = "disabledByGroupPolicy";
            state->toast_detail = "组策略已禁用通知";
            break;
        case NotificationSetting::DisabledByManifest:
            state->toast_setting = "disabledByManifest";
            state->toast_detail = "应用清单禁用了通知";
            break;
        default:
            state->toast_setting = "unknown";
            state->toast_detail = "系统通知设置未知";
            break;
        }
    }
}

/* ------------------------------------------------------------------ */
/* 命名管道服务线程                                                    */
/* ------------------------------------------------------------------ */

/* 把管道里收到的 UTF-8 文本按行解析入队。 */
static void queue_pipe_payload(TsToastState *state, const char *buf, size_t len)
{
    size_t pos = 0;
    while (pos < len) {
        size_t start = pos;
        size_t end;
        while (pos < len && buf[pos] != '\n' && buf[pos] != '\r') pos++;
        end = pos;
        while (pos < len && (buf[pos] == '\n' || buf[pos] == '\r')) pos++;
        if (end > start) {
            std::string line(buf + start, end - start);
            ts_activation_queue_push_uri(state->queue, line.c_str());
        }
    }
}

/* 取出待处理激活文件里的动作入队（运行期兜底；失败静默）。 */
static void drain_pending_once(TsToastState *state)
{
    std::string pending;
    if (state == nullptr || state->pending_path.empty()) return;
    pending = utf8_from_wide(state->pending_path);
    if (pending.empty()) return;
    ts_activation_drain_pending(state->queue, pending.c_str());
}

/* 处理一个已连接（或刚创建）的管道实例：等连接 → 读 → 入队。 */
static void serve_pipe_instance(TsToastState *state, HANDLE pipe)
{
    OVERLAPPED ov;
    HANDLE connect_event = nullptr;
    char buffer[TS_ACTIVATION_MAX_URI_BYTES + 1];
    size_t total = 0;

    ZeroMemory(&ov, sizeof(ov));
    connect_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (connect_event == nullptr) {
        CloseHandle(pipe);
        return;
    }
    ov.hEvent = connect_event;

    /* 等连接；同时每 500ms 扫一次待处理激活文件（应用启动早期的兜底）。 */
    {
        BOOL ok = ConnectNamedPipe(pipe, &ov);
        DWORD err = ok ? ERROR_SUCCESS : GetLastError();
        bool connected = (ok != FALSE) || err == ERROR_PIPE_CONNECTED;
        if (!connected && err == ERROR_IO_PENDING) {
            for (;;) {
                HANDLE waits[2] = {state->stop_event, connect_event};
                DWORD w = WaitForMultipleObjects(2, waits, FALSE, 500);
                if (w == WAIT_OBJECT_0) {
                    CancelIoEx(pipe, &ov);
                    WaitForSingleObject(connect_event, INFINITE);
                    connected = false;
                    break;
                }
                if (w == WAIT_OBJECT_0 + 1) {
                    DWORD got = 0;
                    connected = GetOverlappedResult(pipe, &ov, &got, FALSE) != FALSE;
                    break;
                }
                drain_pending_once(state);
            }
        }
        if (!connected) {
            CloseHandle(connect_event);
            CloseHandle(pipe);
            return;
        }
        ResetEvent(connect_event);
    }

    /* 读：overlapped，stop_event 可随时打断（Ctrl 关闭/退出）。 */
    for (;;) {
        DWORD got = 0;
        BOOL ok;
        if (total >= TS_ACTIVATION_MAX_URI_BYTES) break;
        ZeroMemory(&ov, sizeof(ov));
        ov.hEvent = connect_event;
        ok = ReadFile(pipe, buffer + total, (DWORD)(TS_ACTIVATION_MAX_URI_BYTES - total),
                      &got, &ov);
        if (ok) {
            total += got;
            break;
        }
        {
            DWORD err = GetLastError();
            if (err == ERROR_IO_PENDING) {
                HANDLE waits[2] = {state->stop_event, connect_event};
                DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                if (w == WAIT_OBJECT_0) {
                    CancelIoEx(pipe, &ov);
                    WaitForSingleObject(connect_event, INFINITE);
                    break;
                }
                if (GetOverlappedResult(pipe, &ov, &got, FALSE)) {
                    total += got;
                    if (got == 0) break;
                    continue;
                }
                if (GetLastError() == ERROR_MORE_DATA) {
                    total += got;
                    continue;
                }
                break;
            }
            if (err == ERROR_MORE_DATA) {
                total += got;
                continue;
            }
            break;
        }
    }
    if (total > 0) {
        buffer[total] = '\0';
        queue_pipe_payload(state, buffer, total);
    }
    DisconnectNamedPipe(pipe);
    CloseHandle(connect_event);
    CloseHandle(pipe);
}

static DWORD WINAPI pipe_thread_proc(LPVOID param)
{
    TsToastState *state = (TsToastState *)param;
    HANDLE first = state->first_pipe;

    state->first_pipe = INVALID_HANDLE_VALUE;
    if (first != INVALID_HANDLE_VALUE) {
        serve_pipe_instance(state, first);
    }

    for (;;) {
        HANDLE pipe;
        if (WaitForSingleObject(state->stop_event, 0) == WAIT_OBJECT_0) break;
        /* 运行期也轮询待处理文件（主实例启动前的激活、转发失败时的兜底）。 */
        drain_pending_once(state);
        pipe = CreateNamedPipeW(
            TS_ACTIVATION_PIPE_NAME,
            PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1, 0, TS_ACTIVATION_MAX_URI_BYTES, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            DWORD err = GetLastError();
            if (err == ERROR_ACCESS_DENIED) {
                /* 另一个实例已经拥有管道：本实例不抢，等待退出即可。 */
                WaitForSingleObject(state->stop_event, 1000);
                continue;
            }
            WaitForSingleObject(state->stop_event, 500);
            continue;
        }
        serve_pipe_instance(state, pipe);
    }
    return 0;
}

/* 启动管道线程。首个管道实例在调用线程创建，保证 prepare 返回时已可接收。 */
static bool start_pipe_server(TsToastState *state, std::string &err)
{
    state->stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (state->stop_event == nullptr) {
        err = "无法创建管道停止事件";
        return false;
    }
    state->first_pipe = CreateNamedPipeW(
        TS_ACTIVATION_PIPE_NAME,
        PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        1, 0, TS_ACTIVATION_MAX_URI_BYTES, 0, nullptr);
    if (state->first_pipe == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        if (e == ERROR_ACCESS_DENIED) {
            /* 已有另一个 TaskScheduler 实例在服务管道（应用允许多开时的已知限制）。 */
            state->pipe_owner = false;
            return true;
        }
        {
            char buf[80];
            snprintf(buf, sizeof(buf), "无法创建命名管道（Win32 错误 %ld）", (long)e);
            err = buf;
        }
        CloseHandle(state->stop_event);
        state->stop_event = nullptr;
        return false;
    }
    state->pipe_owner = true;
    state->thread = CreateThread(nullptr, 0, pipe_thread_proc, state, 0, nullptr);
    if (state->thread == nullptr) {
        CloseHandle(state->first_pipe);
        state->first_pipe = INVALID_HANDLE_VALUE;
        CloseHandle(state->stop_event);
        state->stop_event = nullptr;
        err = "无法创建管道线程";
        state->pipe_owner = false;
        return false;
    }
    return true;
}

/* ------------------------------------------------------------------ */
/* 对外 API                                                            */
/* ------------------------------------------------------------------ */

TsToastState *ts_toast_create(TsActivationQueue *queue)
{
    if (queue == nullptr) return nullptr;
    try {
        TsToastState *state = new TsToastState();
        state->queue = queue;
        return state;
    } catch (...) {
        return nullptr;
    }
}

void ts_toast_destroy(TsToastState *state)
{
    if (state == nullptr) return;
    if (state->stop_event != nullptr) {
        SetEvent(state->stop_event);
    }
    if (state->thread != nullptr) {
        DWORD w = WaitForSingleObject(state->thread, 3000);
        if (w == WAIT_OBJECT_0) {
            CloseHandle(state->thread);
            state->thread = nullptr;
        } else {
            /*
             * 线程未退出（极端：外部进程连上管道后既不写也不关）。
             * 宁可泄漏状态也不释放其正在使用的内存——进程退出时由系统回收。
             */
            CloseHandle(state->stop_event);
            state->stop_event = nullptr;
            return;
        }
    }
    if (state->stop_event != nullptr) {
        CloseHandle(state->stop_event);
        state->stop_event = nullptr;
    }
    delete state;
}

int ts_toast_prepare(TsToastState *state, const char *aumid_utf8,
                     const char *exe_path_utf8, TsBridgeBuffer *out_status_json)
{
    buffer_reset(out_status_json);
    if (state == nullptr) {
        failure_json(out_status_json, "argument", "通知状态未初始化", "winrt");
        return 1;
    }

    std::lock_guard<std::mutex> guard(state->mutex);

    /* IShellLink / IPropertyStore / WinRT 都需要 COM apartment。 */
    ensure_com_initialized();

    if (aumid_utf8 == nullptr || aumid_utf8[0] == '\0') {
        failure_json(out_status_json, "argument", "AUMID 不能为空", "winrt");
        return 1;
    }
    state->aumid = wide_from_utf8(aumid_utf8);
    if (state->aumid.empty()) {
        failure_json(out_status_json, "argument", "AUMID 不是有效的 UTF-8", "winrt");
        return 1;
    }
    /*
     * 未打包桌面应用必须把进程 AUMID 设为与快捷方式一致，创建 ToastNotifier 时
     * 系统才会把通知归属到该应用（否则可能 0x80070490“找不到元素”）。
     */
    SetCurrentProcessExplicitAppUserModelID(state->aumid.c_str());

    if (exe_path_utf8 != nullptr && exe_path_utf8[0] != '\0') {
        state->exe_path = wide_from_utf8(exe_path_utf8);
    } else {
        wchar_t module[MAX_PATH];
        DWORD n = GetModuleFileNameW(nullptr, module, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) {
            failure_json(out_status_json, "argument", "无法确定应用可执行文件路径", "winrt");
            return 1;
        }
        state->exe_path = module;
    }
    if (GetFileAttributesW(state->exe_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        failure_json(out_status_json, "argument", "应用可执行文件不存在", "winrt");
        return 1;
    }

    /* 1) AUMID 快捷方式 */
    {
        std::string err;
        state->shortcut_ready =
            ensure_start_menu_shortcut(state, state->aumid, state->exe_path, err);
        state->shortcut_error = state->shortcut_ready ? "" : err;
    }
    /* 2) HKCU URL 协议（taskscheduler://） */
    {
        std::string err;
        state->protocol_ready = ensure_url_protocol(state->exe_path, err);
        state->protocol_error = state->protocol_ready ? "" : err;
    }
    /* 3) 命名管道 + 待处理激活文件 */
    if (state->pending_path.empty()) {
        char *pending = ts_activation_pending_path(nullptr);
        if (pending != nullptr) {
            state->pending_path = wide_from_utf8(pending);
            ts_free(pending);
        }
    }
    if (state->stop_event == nullptr) {
        std::string err;
        if (!start_pipe_server(state, err)) {
            state->pipe_error = err;
        }
    }
    if (!state->pending_path.empty()) {
        std::string pending = utf8_from_wide(state->pending_path);
        if (!pending.empty()) {
            ts_activation_drain_pending(state->queue, pending.c_str());
        }
    }
    /* 4) WinRT Toast 能力与系统开关 */
    probe_toast_capability(state);
    state->prepared = true;

    {
        cJSON *root = cJSON_CreateObject();
        if (root == nullptr) {
            failure_json(out_status_json, "internal", "无法构造准备状态 JSON", "winrt");
            return 1;
        }
        cJSON_AddBoolToObject(root, "ok",
            (state->shortcut_ready && state->protocol_ready &&
             state->toast_supported && state->toast_enabled) ? 1 : 0);
        cJSON_AddStringToObject(root, "aumid", aumid_utf8);
        cJSON_AddStringToObject(root, "exePath",
                                utf8_from_wide(state->exe_path).c_str());
        cJSON_AddBoolToObject(root, "shortcutReady", state->shortcut_ready ? 1 : 0);
        cJSON_AddStringToObject(root, "shortcutPath",
                                utf8_from_wide(state->shortcut_path).c_str());
        cJSON_AddStringToObject(root, "shortcutError", state->shortcut_error.c_str());
        cJSON_AddBoolToObject(root, "protocolReady", state->protocol_ready ? 1 : 0);
        cJSON_AddStringToObject(root, "protocolScheme", TS_ACTIVATION_SCHEME);
        cJSON_AddStringToObject(root, "protocolError", state->protocol_error.c_str());
        cJSON_AddBoolToObject(root, "toastSupported", state->toast_supported ? 1 : 0);
        cJSON_AddBoolToObject(root, "toastSettingEnabled", state->toast_enabled ? 1 : 0);
        cJSON_AddStringToObject(root, "toastSetting", state->toast_setting.c_str());
        cJSON_AddStringToObject(root, "toastDetail", state->toast_detail.c_str());
        cJSON_AddStringToObject(root, "channel",
                                state->toast_supported ? "winrt" : "");
        cJSON_AddBoolToObject(root, "pipeReady",
                              (state->pipe_owner || state->thread != nullptr ||
                               state->stop_event != nullptr) ? 1 : 0);
        cJSON_AddBoolToObject(root, "pipeOwner", state->pipe_owner ? 1 : 0);
        cJSON_AddStringToObject(root, "pipeName", "TaskScheduler.Activation");
        cJSON_AddStringToObject(root, "pipeError", state->pipe_error.c_str());
        cJSON_AddStringToObject(root, "pendingFile",
                                utf8_from_wide(state->pending_path).c_str());

        if (!state->toast_supported || !state->toast_enabled) {
            const char *kind = !state->toast_supported ? "winrt" : "disabled";
            std::string detail = state->toast_detail;
            if (detail.empty()) {
                detail = !state->toast_supported ? "WinRT Toast 不可用"
                                                 : "系统通知未开启";
            }
            cJSON_AddStringToObject(root, "errorKind", kind);
            cJSON_AddStringToObject(root, "error", detail.c_str());
        } else if (!state->shortcut_ready) {
            cJSON_AddStringToObject(root, "errorKind", "registration");
            cJSON_AddStringToObject(root, "error", "开始菜单 AUMID 快捷方式创建失败");
        } else if (!state->protocol_ready) {
            cJSON_AddStringToObject(root, "errorKind", "registration");
            cJSON_AddStringToObject(root, "error", "taskscheduler:// 协议注册失败");
        }
        buffer_set_json(out_status_json, root);
    }
    if (state->shortcut_ready && state->protocol_ready && state->toast_supported &&
        state->toast_enabled) {
        return 0;
    }
    return 1;
}

int ts_toast_show(TsToastState *state, const char *title_utf8,
                  const char *body_utf8, const char *payload_json,
                  TsBridgeBuffer *out_result_json)
{
    char *xml;

    buffer_reset(out_result_json);
    if (state == nullptr) {
        failure_json(out_result_json, "argument", "通知状态未初始化", "winrt");
        return 0;
    }

    std::lock_guard<std::mutex> guard(state->mutex);
    if (!state->prepared) {
        failure_json(out_result_json, "notPrepared",
                     "通知通道尚未初始化（请先调用 ts_bridge_prepare_notifications）",
                     "winrt");
        return 0;
    }
    if (payload_json == nullptr || payload_json[0] == '\0') {
        failure_json(out_result_json, "argument", "payload_json 不能为空", "winrt");
        return 0;
    }

    xml = ts_activation_build_toast_xml(title_utf8, body_utf8, payload_json,
                                        "延长时间", "结束任务");
    if (xml == nullptr) {
        failure_json(out_result_json, "argument",
                     "payload_json 缺少 taskId/executionId/deadline 或格式非法", "winrt");
        return 0;
    }

    {
        std::string xml_utf8(xml);
        ts_free(xml);
        try {
            using namespace winrt::Windows::UI::Notifications;
            ensure_winrt_apartment();

            ToastNotifier notifier = ToastNotificationManager::CreateToastNotifier(
                winrt::hstring(state->aumid));
            /*
             * 先看系统开关；个别系统上 Setting 会返回 0x80070490（通知平台尚未
             * 缓存该 AUMID），这并不代表无法投递——继续尝试 Show，以实际结果为准。
             */
            NotificationSetting setting = NotificationSetting::Enabled;
            bool setting_known = true;
            std::string setting_detail;
            try {
                setting = notifier.Setting();
            } catch (const winrt::hresult_error &e) {
                setting_known = false;
                setting_detail = "读取通知开关失败（不阻断投递）：" + hresult_message(e);
            } catch (...) {
                setting_known = false;
                setting_detail = "读取通知开关失败（不阻断投递）";
            }
            if (setting_known && setting != NotificationSetting::Enabled) {
                std::string detail;
                const char *kind = "disabled";
                switch (setting) {
                case NotificationSetting::DisabledForApplication:
                    detail = "系统通知中已关闭本应用的通知";
                    break;
                case NotificationSetting::DisabledForUser:
                    detail = "系统通知已对当前用户关闭";
                    break;
                case NotificationSetting::DisabledByGroupPolicy:
                    detail = "组策略已禁用通知";
                    kind = "policy";
                    break;
                case NotificationSetting::DisabledByManifest:
                    detail = "应用清单禁用了通知";
                    break;
                default:
                    detail = "系统通知不可用";
                    break;
                }
                failure_json(out_result_json, kind, detail.c_str(), "winrt");
                return 0;
            }

            winrt::Windows::Data::Xml::Dom::XmlDocument document;
            document.LoadXml(hstring_from_utf8(xml_utf8));
            ToastNotification toast(document);
            notifier.Show(toast);

            {
                cJSON *root = cJSON_CreateObject();
                if (root == nullptr) {
                    failure_json(out_result_json, "internal", "无法构造投递结果", "winrt");
                    return 0;
                }
                cJSON_AddBoolToObject(root, "ok", 1);
                cJSON_AddBoolToObject(root, "accepted", 1);
                cJSON_AddStringToObject(root, "channel", "winrt");
                cJSON_AddStringToObject(root, "aumid",
                                        utf8_from_wide(state->aumid).c_str());
                cJSON_AddNumberToObject(
                    root, "atMs", (double)(uint64_t)GetTickCount64());
                if (!setting_detail.empty()) {
                    cJSON_AddStringToObject(root, "warning", setting_detail.c_str());
                }
                buffer_set_json(out_result_json, root);
            }
            return 1;
        } catch (const winrt::hresult_error &e) {
            std::string message = "系统拒绝通知：" + hresult_message(e) + "（" +
                                  hresult_code(e) + "）";
            failure_json(out_result_json, "winrt", message.c_str(), "winrt");
            return 0;
        } catch (const std::exception &e) {
            std::string message = std::string("系统拒绝通知：") + e.what();
            failure_json(out_result_json, "winrt", message.c_str(), "winrt");
            return 0;
        } catch (...) {
            failure_json(out_result_json, "winrt", "系统拒绝通知（未知异常）", "winrt");
            return 0;
        }
    }
}
