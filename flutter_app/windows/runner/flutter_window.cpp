#include "flutter_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <cstdio>
#include <cstdlib>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_geometry.h"
#include "window_region.h"

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

/*
 * Optional window-message diagnostics for acceptance evidence (R2-W2).
 *
 * Set TASKSCHEDULER_WINDOW_LOG=<file> before starting the executable and every
 * state-transition related message is appended with the current window style and
 * rectangle. The acceptance report uses it to prove that no transition brings
 * WS_CAPTION / WS_BORDER back or triggers non-client painting. It is off in
 * normal runs and never contains user data.
 */
void WindowLog(const char* message, HWND window, WPARAM wparam, LPARAM lparam) {
  static FILE* log = nullptr;
  static bool initialised = false;
  if (!initialised) {
    initialised = true;
    char path[1024] = {0};
    const DWORD length = GetEnvironmentVariableA(
        "TASKSCHEDULER_WINDOW_LOG", path, static_cast<DWORD>(sizeof(path)));
    if (length > 0 && length < sizeof(path) && path[0] != '\0') {
      log = nullptr;
      fopen_s(&log, path, "a");
    }
  }
  if (log == nullptr || window == nullptr) return;
  LONG style = GetWindowLong(window, GWL_STYLE);
  LONG ex_style = GetWindowLong(window, GWL_EXSTYLE);
  RECT rect = {0, 0, 0, 0};
  GetWindowRect(window, &rect);
  std::fprintf(log,
               "%s style=0x%08lX ex=0x%08lX rect=(%ld,%ld,%ld,%ld) "
               "zoomed=%d iconic=%d wp=%llX lp=%llX\n",
               message, static_cast<unsigned long>(style),
               static_cast<unsigned long>(ex_style), rect.left, rect.top,
               rect.right, rect.bottom, IsZoomed(window) ? 1 : 0,
               IsIconic(window) ? 1 : 0,
               static_cast<unsigned long long>(wparam),
               static_cast<unsigned long long>(lparam));
  std::fflush(log);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  /*
   * Acceptance experiment only: TASKSCHEDULER_DISABLE_REGION=1 starts the app
   * without the native window region. The probe then captures what the Flutter
   * GPU surface itself presents at the corners, which is the evidence for
   * "the embedder's HWND surface has no per-pixel alpha, so a ClipPath cannot
   * make the native window edge transparent". Normal runs never set this.
   */
  char disable_region[8] = {0};
  const DWORD disabled = GetEnvironmentVariableA(
      "TASKSCHEDULER_DISABLE_REGION", disable_region,
      static_cast<DWORD>(sizeof(disable_region)));
  if (disabled > 0 && disable_region[0] == '1') {
    region_diagnostics_enabled_ = false;
  }
}

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

  // Establish the rounded outline before the first frame is shown, so the
  // window never flashes its square corners on startup. WM_NCCALCSIZE keeps the
  // client rectangle equal to the window rectangle here, so the region
  // coordinates and Flutter's rendering surface share one origin.
  UpdateWindowRegion(/*force=*/true);

  /*
   * Once the window is non-rectangular, DWM falls back to painting its own
   * window frame inside the window bounds: without this the rounded outline is
   * surrounded by a thick gray system band instead of Flutter's 1 px hairline.
   *
   * The frame extension used by most borderless-window apps is NOT usable here:
   * it makes DWM ignore the window region for compositing, so the cut corners
   * fill with the frame brush and the outline stops being a true window cut.
   * Disabling non-client rendering keeps the region authoritative and stops the
   * system from painting a second frame.
   */
  const DWMNCRENDERINGPOLICY nc_policy = DWMNCRP_DISABLED;
  DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY, &nc_policy,
                        sizeof(nc_policy));
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWCP_DONOTROUND
#define DWMWCP_DONOTROUND 1
#endif
  // The outline is an explicit cubic Bezier path; the system corner style must
  // not add a second, slightly different rounding on top of it.
  const DWORD corner_preference = DWMWCP_DONOTROUND;
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));

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
  } else if (method == "windowShape") {
    // Current window state for Dart: shape (state/radius), real size and DPI.
    // Dart uses it once on startup; events carry the same map afterwards.
    result->Success(WindowShapeInfo(shape_sequence_));
  } else if (method == "setRegionEnabled") {
    /*
     * Diagnostics only (acceptance evidence for the anti-aliasing section):
     * turning the native region off lets a probe capture what the GPU surface
     * actually presents at the corners, proving whether the top-level surface
     * carries per-pixel alpha or is opaque (in which case a ClipPath cannot
     * produce a transparent native edge).
     */
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    bool enabled = true;
    if (arguments != nullptr) {
      auto it = arguments->find(flutter::EncodableValue("enabled"));
      if (it != arguments->end()) {
        if (const bool* value = std::get_if<bool>(&it->second)) {
          enabled = *value;
        }
      }
    }
    region_diagnostics_enabled_ = enabled;
    if (!enabled) {
      region_updating_ = true;
      SetWindowRgn(window, nullptr, TRUE);
      region_applied_ = false;
      region_updating_ = false;
    } else {
      UpdateWindowRegion(/*force=*/true);
      NotifyWindowShape(window);
    }
    result->Success(WindowShapeInfo(shape_sequence_));
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

void FlutterWindow::UpdateWindowRegion(bool force) {
  HWND window = GetHandle();
  if (window == nullptr) return;

  // A minimized window has no meaningful client rectangle; skipping keeps the
  // last real region instead of replacing it with a degenerate one.
  if (IsIconic(window) != 0) return;

  // Diagnostics mode: the region was deliberately cleared by the probe.
  if (!region_diagnostics_enabled_) return;

  /*
   * Re-entrancy: SetWindowRgn sends WM_WINDOWPOSCHANGING/WM_WINDOWPOSCHANGED and
   * can synchronously re-enter the message handler. The flag (not the cache)
   * is what prevents recursion; the cache keeps resize drags from rebuilding an
   * identical HRGN for every intermediate size it already handled.
   */
  if (region_updating_) return;

  RECT rect = {0, 0, 0, 0};
  if (GetWindowRect(window, &rect) == FALSE) {
    ++region_failures_;
    region_last_error_ = GetLastError();
    return;
  }
  const int width = static_cast<int>(rect.right - rect.left);
  const int height = static_cast<int>(rect.bottom - rect.top);
  if (width <= 0 || height <= 0) return;

  /*
   * Always the window's own DPI, resolved after the new rectangle was applied:
   * a WM_DPICHANGED / cross-monitor move must not reuse the previous value.
   */
  const UINT dpi = FlutterDesktopGetDpiForHWND(window);
  if (dpi == 0) {
    ++region_failures_;
    region_last_error_ = ERROR_INVALID_PARAMETER;
    return;
  }
  const double radius_dip = CurrentCornerRadiusDip(window);
  const int radius_px =
      ts_window_region_radius_px(width, height, dpi, radius_dip);
  const bool maximized = IsWindowMaximized(window);
  const bool snapped = IsWindowSnappedToWorkArea(window);

  if (!force && region_applied_ == (radius_px > 0) &&
      width == region_width_ && height == region_height_ &&
      dpi == region_dpi_ && radius_px == region_radius_px_ &&
      radius_dip == region_radius_dip_ && maximized == region_maximized_ &&
      snapped == region_snapped_) {
    return;
  }

  TsWindowRegionPoint points[TS_WINDOW_REGION_MAX_POINTS];
  const int count = ts_window_region_build(width, height,
                                           static_cast<double>(radius_px),
                                           points, TS_WINDOW_REGION_MAX_POINTS);
  if (count < 0) {
    ++region_failures_;
    region_last_error_ = ERROR_INVALID_PARAMETER;
    return;
  }

  region_updating_ = true;
  HRGN region = nullptr;
  if (count == 0) {
    // Radius 0 (maximized / snapped): clear the region so the window is a plain
    // rectangle that fills the work area without cut corners. SetWindowRgn with
    // NULL removes any previous region; the system releases the old HRGN.
    if (SetWindowRgn(window, nullptr, TRUE) == 0) {
      ++region_failures_;
      region_last_error_ = GetLastError();
      region_updating_ = false;
      return;
    }
    region_applied_ = false;
  } else {
    POINT polygon[TS_WINDOW_REGION_MAX_POINTS];
    for (int i = 0; i < count; ++i) {
      polygon[i].x = points[i].x;
      polygon[i].y = points[i].y;
    }
    region = CreatePolygonRgn(polygon, count, WINDING);
    if (region == nullptr) {
      ++region_failures_;
      region_last_error_ = GetLastError();
      region_updating_ = false;
      return;
    }
    if (SetWindowRgn(window, region, TRUE) == 0) {
      // On failure the HRGN is still ours; on success the system owns it and it
      // must never be deleted or used again.
      DeleteObject(region);
      ++region_failures_;
      region_last_error_ = GetLastError();
      region_updating_ = false;
      return;
    }
    region_applied_ = true;
  }

  region_width_ = width;
  region_height_ = height;
  region_dpi_ = dpi;
  region_radius_px_ = radius_px;
  region_radius_dip_ = radius_dip;
  region_maximized_ = maximized;
  region_snapped_ = snapped;
  ++region_updates_;
  region_updating_ = false;
}

bool FlutterWindow::IsWindowSnappedToWorkArea(HWND window) const {
  /*
   * Windows has no public "is this window snapped" API. A window that covers
   * the full work-area height and touches the left or right work-area edge is
   * the shape the OS produces for half/quarter Snap layouts; a maximized window
   * is handled separately by IsZoomed and never reaches this test with a
   * matching rectangle.
   *
   * A normal window moved/resized by hand to exactly those coordinates is
   * indistinguishable from a snapped one; treating it as snapped only changes
   * the corner style (square), never the geometry, and the radius is frozen
   * during a sizing loop so the shape cannot flicker while dragging.
   */
  if (IsIconic(window) != 0) return false;
  if (IsWindowMaximized(window)) return false;
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (GetMonitorInfo(monitor, &info) == FALSE) return false;
  RECT rect = {0, 0, 0, 0};
  if (GetWindowRect(window, &rect) == FALSE) return false;
  const RECT& work = info.rcWork;
  const bool within_work = rect.left >= work.left && rect.top >= work.top &&
                           rect.right <= work.right &&
                           rect.bottom <= work.bottom;
  if (!within_work) return false;
  const bool full_height = rect.top == work.top && rect.bottom == work.bottom;
  const bool touches_side = rect.left == work.left || rect.right == work.right;
  return full_height && touches_side;
}

double FlutterWindow::CurrentCornerRadiusDip(HWND window) const {
  if (window == nullptr) return kWindowCornerRadiusDip;
  if (IsIconic(window) != 0) {
    // Keep the last applied radius while minimized: there is nothing to clip.
    return region_radius_dip_;
  }
  if (IsWindowMaximized(window)) return 0.0;
  if (IsWindowSnappedToWorkArea(window)) return 0.0;
  if (in_sizing_loop_) {
    // Freeze during the interactive resize so dragging through a snap-sized
    // rectangle does not flip the corners back and forth.
    return region_radius_dip_ > 0.0 ? region_radius_dip_ : kWindowCornerRadiusDip;
  }
  return kWindowCornerRadiusDip;
}

void FlutterWindow::NotifyWindowShape(HWND window) {
  if (!window_channel_ || window == nullptr) return;
  const int sequence = ++shape_sequence_;
  last_pushed_sequence_ = sequence;
  window_channel_->InvokeMethod(
      "windowShapeChanged",
      std::make_unique<flutter::EncodableValue>(WindowShapeInfo(sequence)));
}

flutter::EncodableValue FlutterWindow::WindowShapeInfo(int sequence) const {
  flutter::EncodableMap map;
  const bool minimized = false;
  map[flutter::EncodableValue("sequence")] = flutter::EncodableValue(sequence);
  map[flutter::EncodableValue("radiusDip")] =
      flutter::EncodableValue(region_radius_dip_);
  map[flutter::EncodableValue("radiusPx")] =
      flutter::EncodableValue(region_radius_px_);
  map[flutter::EncodableValue("cornerRadiusConfigDip")] =
      flutter::EncodableValue(kWindowCornerRadiusDip);
  map[flutter::EncodableValue("maximized")] =
      flutter::EncodableValue(region_maximized_);
  map[flutter::EncodableValue("snapped")] =
      flutter::EncodableValue(region_snapped_);
  map[flutter::EncodableValue("width")] = flutter::EncodableValue(region_width_);
  map[flutter::EncodableValue("height")] =
      flutter::EncodableValue(region_height_);
  map[flutter::EncodableValue("dpi")] =
      flutter::EncodableValue(static_cast<int>(region_dpi_));
  map[flutter::EncodableValue("applied")] =
      flutter::EncodableValue(region_applied_);
  map[flutter::EncodableValue("updates")] =
      flutter::EncodableValue(region_updates_);
  map[flutter::EncodableValue("failures")] =
      flutter::EncodableValue(region_failures_);
  map[flutter::EncodableValue("lastError")] =
      flutter::EncodableValue(static_cast<int>(region_last_error_));
  map[flutter::EncodableValue("minimized")] =
      flutter::EncodableValue(minimized);
  map[flutter::EncodableValue("regionDiagnosticsEnabled")] =
      flutter::EncodableValue(region_diagnostics_enabled_);
  return flutter::EncodableValue(map);
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
    case WM_STYLECHANGED:
      WindowLog("WM_STYLECHANGED", hwnd, wparam, lparam);
      break;




    case WM_SYSCOMMAND:
      WindowLog("WM_SYSCOMMAND", hwnd, wparam, lparam);
      break;

    case WM_SHOWWINDOW:
      WindowLog("WM_SHOWWINDOW", hwnd, wparam, lparam);
      break;

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
      WindowLog("WM_NCCALCSIZE", hwnd, wparam, lparam);
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

    case WM_ENTERSIZEMOVE:
      WindowLog("WM_ENTERSIZEMOVE", hwnd, wparam, lparam);
      // Interactive move/resize loop: freeze the corner radius so dragging the
      // frame through a snap-sized rectangle cannot flip the shape back and
      // forth. The shape is re-evaluated in WM_EXITSIZEMOVE.
      in_sizing_loop_ = true;
      break;

    case WM_EXITSIZEMOVE:
      WindowLog("WM_EXITSIZEMOVE", hwnd, wparam, lparam);
      in_sizing_loop_ = false;
      // The window may now be snapped (or no longer snapped); re-evaluate.
      UpdateWindowRegion(/*force=*/true);
      NotifyWindowShape(hwnd);
      break;

    case WM_NCPAINT:
      WindowLog("WM_NCPAINT", hwnd, wparam, lparam);
      /*
       * The window has no native non-client area (WM_NCCALCSIZE claims the whole
       * rectangle), so any system non-client painting would draw a stray border
       * or caption strip over Flutter's surface during state transitions. The
       * chrome is fully owned by Flutter; treat it as handled.
       */
      return 0;

    case WM_NCACTIVATE:
      WindowLog("WM_NCACTIVATE", hwnd, wparam, lparam);
      /*
       * Returning TRUE tells the system the activation change was handled, so
       * DefWindowProc does not repaint a (non-existent) NC caption on
       * activate/deactivate. Activation behaviour itself is unchanged.
       */
      return TRUE;
  }

  const LRESULT handled =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);

  /*
   * Outline refresh happens after the base handler so the new window rectangle
   * is already applied: WM_DPICHANGED applies the suggested rect, and the WM_SIZE
   * it causes arrives with the new DPI active. Both messages may fire for one
   * change; UpdateWindowRegion's cache makes the second call a no-op.
   *
   * The shape is pushed to Dart only after the native region was refreshed, so
   * Flutter's clip/stroke and the real window shape always describe the same
   * state (maximized -> square corners in both layers at the same frame).
   */
  switch (message) {
    case WM_SIZE:
    case WM_DPICHANGED:
    case WM_SHOWWINDOW:
      UpdateWindowRegion();
      NotifyWindowShape(hwnd);
      break;
    case WM_ACTIVATE:
      // Activation only changes the hairline colour on the Flutter side; the
      // geometry does not change, so no region rebuild is needed.
      break;
    default:
      break;
  }
  return handled;
}
