#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_geometry.h"

namespace {

// Minimum window size in logical pixels, scaled by the current DPI. The shell
// needs enough width for the sidebar + task list + chart.
constexpr int kMinWidth = 960;
constexpr int kMinHeight = 640;

int ScaleForDpi(int value, UINT dpi) {
  return MulDiv(value, static_cast<int>(dpi), 96);
}

// Reads an integer out of an EncodableValue that may be int32 or int64.
int64_t ReadInt(const flutter::EncodableValue& value) {
  if (const int32_t* v = std::get_if<int32_t>(&value)) return *v;
  if (const int64_t* v = std::get_if<int64_t>(&value)) return *v;
  if (const double* v = std::get_if<double>(&value)) {
    return static_cast<int64_t>(*v);
  }
  return 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Remove the native caption but keep WS_THICKFRAME / WS_MAXIMIZEBOX etc.
  // The client area therefore starts inside the sizing border: edge resizing,
  // the work-area-aware maximized rect, Alt+F4 and the DWM shadow all stay
  // native, while the title bar itself is drawn by Flutter.
  HWND window = GetHandle();
  LONG style = GetWindowLong(window, GWL_STYLE);
  style &= ~WS_CAPTION;
  SetWindowLong(window, GWL_STYLE, style);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "taskscheduler/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowMethod(call, std::move(result)); });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The Flutter view covers the client area; without this subclass Windows would
  // send WM_NCHITTEST to the child and the parent's caption hit-test would never
  // run. The subclass forwards caption/resize points to the parent.
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    &FlutterWindow::ChildHitTestProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND window = GetHandle();
  const std::string& method = call.method_name();

  if (method == "minimize") {
    ShowWindow(window, SW_MINIMIZE);
    result->Success();
  } else if (method == "maximize") {
    ShowWindow(window, SW_MAXIMIZE);
    result->Success();
  } else if (method == "restore") {
    ShowWindow(window, SW_RESTORE);
    result->Success();
  } else if (method == "toggleMaximize") {
    ShowWindow(window, IsWindowMaximized(window) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success();
  } else if (method == "isMaximized") {
    result->Success(flutter::EncodableValue(IsWindowMaximized(window)));
  } else if (method == "setCloseGuard") {
    const bool enabled =
        call.arguments() != nullptr &&
        std::get_if<bool>(call.arguments()) != nullptr &&
        *std::get_if<bool>(call.arguments());
    close_guard_ = enabled;
    if (enabled) allow_close_ = false;
    result->Success();
  } else if (method == "requestClose") {
    PostMessage(window, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "confirmClose") {
    allow_close_ = true;
    PostMessage(window, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "setDragRegion") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments != nullptr) {
      auto read = [arguments](const char* key) -> int {
        auto it = arguments->find(flutter::EncodableValue(key));
        if (it == arguments->end()) return 0;
        return static_cast<int>(ReadInt(it->second));
      };
      RECT region = {read("left"), read("top"), read("right"), read("bottom")};
      if (region.right > region.left && region.bottom > region.top) {
        drag_region_ = region;
        has_drag_region_ = true;
      } else {
        has_drag_region_ = false;
      }
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::NotifyMaximizedState(HWND window) {
  if (!window_channel_) return;
  window_channel_->InvokeMethod(
      "maximizedChanged",
      std::make_unique<flutter::EncodableValue>(IsWindowMaximized(window)));
}

bool FlutterWindow::IsWindowMaximized(HWND window) const {
  return window != nullptr && IsZoomed(window) != 0;
}

int FlutterWindow::ComputeHitTest(int x, int y) {
  HWND window = GetHandle();
  RECT client = {0, 0, 0, 0};
  GetClientRect(window, &client);
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;

  if (!IsZoomed(window) && width > 0 && height > 0) {
    const UINT dpi = FlutterDesktopGetDpiForHWND(window);
    const int border_x = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const int border_y = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    const bool left = x < border_x;
    const bool right = x >= width - border_x;
    const bool top = y < border_y;
    const bool bottom = y >= height - border_y;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }

  if (has_drag_region_ && x >= drag_region_.left && x < drag_region_.right &&
      y >= drag_region_.top && y < drag_region_.bottom) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

LRESULT CALLBACK FlutterWindow::ChildHitTestProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR ref_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
  if (message == WM_NCHITTEST && self != nullptr) {
    HWND parent = GetParent(hwnd);
    if (parent != nullptr) {
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(parent, &point);
      // HTTRANSPARENT makes the system continue with the parent window, whose
      // WM_NCHITTEST returns HTCAPTION / HTLEFT / ... and drives the native
      // move-resize loop. Plain client points stay with Flutter.
      if (self->ComputeHitTest(point.x, point.y) != HTCLIENT) {
        return HTTRANSPARENT;
      }
    }
  } else if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(hwnd, &FlutterWindow::ChildHitTestProc, subclass_id);
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_SIZE:
      // Real state, not a locally flipped bool: Win+arrow, double-click on the
      // caption area and system commands all end up here.
      NotifyMaximizedState(hwnd);
      break;

    case WM_GETMINMAXINFO: {
      UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = ScaleForDpi(kMinWidth, dpi);
      info->ptMinTrackSize.y = ScaleForDpi(kMinHeight, dpi);

      /*
       * Maximize to the exact monitor work area. ptMaxPosition is relative to the
       * monitor origin (not the virtual desktop), so a secondary or negative
       * origin monitor still lands on its own taskbar-aware work area.
       */
      MONITORINFO monitor_info = {};
      monitor_info.cbSize = sizeof(monitor_info);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (GetMonitorInfo(monitor, &monitor_info)) {
        const RECT& work = monitor_info.rcWork;
        const RECT& screen = monitor_info.rcMonitor;
        TsPixelRect monitor_rect = {screen.left, screen.top, screen.right,
                                    screen.bottom};
        TsPixelRect work_rect = {work.left, work.top, work.right, work.bottom};
        const TsMaximizePlacement placement =
            ts_maximize_placement(monitor_rect, work_rect);
        info->ptMaxPosition.x = placement.x;
        info->ptMaxPosition.y = placement.y;
        info->ptMaxSize.x = placement.width;
        info->ptMaxSize.y = placement.height;
      }
      return 0;
    }

    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        /*
         * Borderless frame: for a normal window the client covers the whole
         * window rect (the sizing border stays active through WM_NCHITTEST).
         * When maximized, clamp the client to the work area so the window never
         * covers the taskbar.
         */
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        if (IsZoomed(hwnd)) {
          MONITORINFO monitor_info = {};
          monitor_info.cbSize = sizeof(monitor_info);
          HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
          if (GetMonitorInfo(monitor, &monitor_info)) {
            params->rgrc[0] = monitor_info.rcWork;
          }
        }
        return 0;
      }
      break;

    case WM_NCHITTEST: {
      /*
       * The client covers the whole window rect (WM_NCCALCSIZE), so DefWindowProc
       * no longer reports the sizing border. Re-create the resize hit targets in
       * one place (ComputeHitTest) shared with the Flutter view's subclass.
       */
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      POINT origin = {0, 0};
      ClientToScreen(hwnd, &origin);
      return ComputeHitTest(point.x - origin.x, point.y - origin.y);
    }

    case WM_SETCURSOR:
      // The blank caption area is native (Flutter does not receive hover there),
      // so show a move cursor explicitly; borders keep their sizing cursors.
      if (LOWORD(lparam) == HTCLIENT) {
        POINT point = {0, 0};
        GetCursorPos(&point);
        ScreenToClient(hwnd, &point);
        if (ComputeHitTest(point.x, point.y) == HTCAPTION) {
          SetCursor(LoadCursor(nullptr, IDC_SIZEALL));
          return TRUE;
        }
      }
      break;

    case WM_CLOSE:
      // Closing from the title bar, the app menu, Alt+F4 or the taskbar all
      // funnel through one flow: ask Dart to flush, then destroy on confirm.
      if (close_guard_ && !allow_close_) {
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "closeRequested",
              std::make_unique<flutter::EncodableValue>(true));
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
