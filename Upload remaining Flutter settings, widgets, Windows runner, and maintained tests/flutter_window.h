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
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
