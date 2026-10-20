#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
       * Maximize to the exact monitor work area. The client area is clamped in
       * WM_NCCALCSIZE as well, so the title bar never covers the taskbar.
       */
      MONITORINFO monitor_info = {};
      monitor_info.cbSize = sizeof(monitor_info);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (GetMonitorInfo(monitor, &monitor_info)) {
        const RECT& work = monitor_info.rcWork;
        info->ptMaxPosition.x = work.left;
        info->ptMaxPosition.y = work.top;
        info->ptMaxSize.x = work.right - work.left;
        info->ptMaxSize.y = work.bottom - work.top;
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
       * no longer reports the sizing border. Re-create the resize hit targets
       * explicitly, otherwise "hide the title bar" would also remove resizing.
       */
      RECT client = {0, 0, 0, 0};
      GetClientRect(hwnd, &client);
      const int width = client.right - client.left;
      const int height = client.bottom - client.top;
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      POINT origin = {0, 0};
      ClientToScreen(hwnd, &origin);
      const int x = point.x - origin.x;
      const int y = point.y - origin.y;

      if (!IsZoomed(hwnd) && width > 0 && height > 0) {
        const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
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

      // Report the blank title-bar strip as caption so Windows itself handles
      // dragging, double-click maximize/restore and Aero Snap. Menus, buttons
      // and the resize border are not part of this rectangle.
      if (has_drag_region_) {
        if (x >= drag_region_.left && x < drag_region_.right &&
            y >= drag_region_.top && y < drag_region_.bottom) {
          return HTCAPTION;
        }
      }
      break;
    }

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
