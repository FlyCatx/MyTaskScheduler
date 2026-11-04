#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <memory>

#include "win32_window.h"

// A window that hosts a Flutter view.
//
// The native caption is removed so the Dart side can draw its own title bar.
// The sizing frame, workspace-aware maximize, edge resizing, Alt+F4 and Windows
// Snap stay native: the drag region reported by Dart is reported as HTCAPTION
// from WM_NCHITTEST, and everything else falls through to DefWindowProc.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Handles `taskscheduler/window` calls from Dart.
  void HandleWindowMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Sends the real maximize state to Dart after a WM_SIZE.
  void NotifyMaximizedState(HWND window);

  bool IsWindowMaximized(HWND window) const;

  /*
   * Shape state (second round): normal restored windows are rounded, maximized
   * and system-snapped windows are plain rectangles.
   *
   * The window state is the *real* platform state (IsZoomed / applied window
   * rectangle vs. monitor work area), never a locally flipped flag.
   */
  bool IsWindowSnappedToWorkArea(HWND window) const;

  // Corner radius in DIPs that currently applies: 18 for a normal window, 0 for
  // maximized / snapped / while a manual sizing loop is in progress (so a drag
  // through snap-like sizes does not flicker the shape).
  double CurrentCornerRadiusDip(HWND window) const;

  // Pushes the shape state (state, radius, dpi, size, sequence) to Dart. Called
  // after the region was applied so Dart never sees a state the native window
  // has not adopted yet.
  void NotifyWindowShape(HWND window);

  /*
   * Rebuilds the top-level window's rounded outline (cubic Bezier corners) from
   * the *applied* window rectangle and the window's current DPI, then hands the
   * region to the system with SetWindowRgn.
   *
   * The region is the native half of the window shape: Flutter clips and
   * strokes the same path, but a ClipPath alone cannot change the shape of an
   * opaque Win32 window, so the four cut-away corners have to be removed here.
   *
   * Cached on (width, height, dpi, radius, maximized): repeated WM_SIZE /
   * WM_DPICHANGED messages, and the position messages SetWindowRgn itself
   * triggers, do not rebuild the HRGN. Re-entrancy is guarded with
   * |region_updating_|. On success the system owns the HRGN (never deleted
   * here); on failure we keep the previous region and record the error.
   */
  void UpdateWindowRegion(bool force = false);

  // Snapshot of the outline state for the `windowShape` channel call and for
  // the acceptance probe (proves the region was applied and how often).
  flutter::EncodableValue WindowShapeInfo(int sequence) const;

  // One hit-test result for the whole borderless frame. Used by the parent's
  // WM_NCHITTEST and by the Flutter view's subclass so both agree on which
  // client points belong to the native caption/resize borders.
  // Returns HTCLIENT for ordinary client points.
  int ComputeHitTest(int x, int y);
  // The Flutter view is a child HWND covering the client area, so Windows sends
  // WM_NCHITTEST to it first. Return HTTRANSPARENT for caption/resize points so
  // the parent (this window) receives the real mouse and starts the native
  // move/resize loop; ordinary points keep going to Flutter.
  static LRESULT CALLBACK ChildHitTestProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           UINT_PTR subclass_id,
                                           DWORD_PTR ref_data);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // When true, WM_CLOSE is handed to Dart first (save pending drafts). Dart
  // calls confirmClose() to let the window actually close.
  bool close_guard_ = false;
  bool allow_close_ = false;

  // Client-area rectangle (physical pixels) that Windows treats as the caption,
  // reported by Dart after layout. Excludes menus and caption buttons.
  RECT drag_region_ = {0, 0, 0, 0};
  bool has_drag_region_ = false;

  // ---- window outline (rounded corners + Flutter-drawn gray border) --------
  // Must stay in sync with TsWindowShape.radius in
  // flutter_app/lib/src/ui/theme/values.dart; the geometry itself is shared with
  // the C tests through window_region.h.
  static constexpr double kWindowCornerRadiusDip = 18.0;

  // True only after SetWindowRgn accepted the region; a failure must never be
  // cached as success.
  bool region_applied_ = false;
  bool region_updating_ = false;
  int region_width_ = 0;
  int region_height_ = 0;
  unsigned int region_dpi_ = 0;
  int region_radius_px_ = 0;
  double region_radius_dip_ = 0.0;
  bool region_maximized_ = false;
  bool region_snapped_ = false;
  int region_updates_ = 0;
  int region_failures_ = 0;
  long region_last_error_ = 0;

  // True while the user is dragging/resizing the frame (WM_ENTERSIZEMOVE ..=
  // WM_EXITSIZEMOVE). The radius is frozen during the loop so passing through a
  // snap-sized rectangle does not toggle the shape mid-drag.
  bool in_sizing_loop_ = false;

  // Monotonic counter for shape notifications so Dart can drop a late reply to
  // the initial `windowShape` query that is older than an event it already saw.
  int shape_sequence_ = 0;
  int last_pushed_sequence_ = 0;

  // Diagnostics switch (`setRegionEnabled`): when false the native region is
  // cleared and not rebuilt, so the acceptance probe can capture what the GPU
  // surface itself presents at the corners. Never used in normal operation.
  bool region_diagnostics_enabled_ = true;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
