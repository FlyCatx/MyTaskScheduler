#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

/*
 * 0.5.0 actionable Windows notifications - process-side wiring.
 *
 * 1) AUMID: an unpackaged desktop app must set the same AppUserModelID on the
 *    process as the Start Menu shortcut's System.AppUserModel.ID, otherwise the
 *    shell drops its toasts. Toast actions are activated through the
 *    taskscheduler:// URL protocol.
 * 2) Single-instance activation forwarding: while the app is already running,
 *    Windows starts a SECOND process for a toast click/button (its command line
 *    is the taskscheduler:// URI). That process hands the URI to the running
 *    instance through a named pipe served by ts_bridge.dll and exits without
 *    creating another window. If the pipe is not ready yet (app still starting)
 *    it falls back to %LOCALAPPDATA%\TaskScheduler\pending_activation.txt,
 *    which the running instance polls.
 * 3) App not running: the OS-started process IS the only instance. It appends
 *    the activation to the pending file and starts Flutter normally; when Dart
 *    calls ts_bridge_prepare_notifications the pending action is drained into
 *    the queue read by ts_bridge_take_execution_action.
 *
 * Pipe / pending-file / AUMID constants must stay in sync with
 * src/bridge/ts_activation.h and Dart's kExecutionAppUserModelId.
 */

namespace {

constexpr wchar_t kAppUserModelId[] = L"TaskScheduler.Desktop";
constexpr wchar_t kActivationPipeName[] =
    L"\\\\.\\pipe\\TaskScheduler.Activation";
constexpr wchar_t kRunningMutexName[] = L"Local\\TaskScheduler.App.Running";
constexpr wchar_t kPendingMutexName[] =
    L"Local\\TaskScheduler.Activation.Pending";
constexpr wchar_t kPendingFileName[] = L"pending_activation.txt";
constexpr char kActivationScheme[] = "taskscheduler://";

// True when a command-line argument is a protocol activation for this app
// (case-insensitive scheme comparison).
bool IsActivationUri(const std::string& value) {
  const size_t scheme_length = sizeof(kActivationScheme) - 1;
  if (value.size() < scheme_length) return false;
  for (size_t i = 0; i < scheme_length; ++i) {
    char actual = value[i];
    if (actual >= 'A' && actual <= 'Z') {
      actual = static_cast<char>(actual - 'A' + 'a');
    }
    if (actual != kActivationScheme[i]) return false;
  }
  return true;
}

// Returns <LOCALAPPDATA>\TaskScheduler\pending_activation.txt, creating the
// directory when needed. Falls back to the temp directory, then to ".".
std::wstring PendingFilePath() {
  wchar_t base[MAX_PATH] = {};
  DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
  std::wstring dir;
  if (length > 0 && length < MAX_PATH) {
    dir.assign(base, length);
  } else {
    wchar_t temp[MAX_PATH] = {};
    DWORD temp_length = ::GetTempPathW(MAX_PATH, temp);
    if (temp_length > 0 && temp_length < MAX_PATH) {
      dir.assign(temp, temp_length);
      if (!dir.empty() && dir.back() == L'\\') dir.pop_back();
    }
  }
  if (dir.empty()) dir = L".";
  dir += L"\\TaskScheduler";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\" + kPendingFileName;
}

// Appends one pending activation. Serialized across processes with the same
// named mutex used by ts_activation.c.
void AppendPendingActivation(const std::string& uri) {
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, kPendingMutexName);
  if (mutex != nullptr) {
    ::WaitForSingleObject(mutex, 3000);
  }
  const std::wstring path = PendingFilePath();
  HANDLE file = ::CreateFileW(
      path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    std::string line = uri;
    line.push_back('\n');
    DWORD written = 0;
    ::WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
                nullptr);
    ::CloseHandle(file);
  }
  if (mutex != nullptr) {
    ::ReleaseMutex(mutex);
    ::CloseHandle(mutex);
  }
}

// Hands the activation URI to the running instance's pipe server.
bool ForwardToRunningInstance(const std::string& uri) {
  HANDLE pipe = ::CreateFileW(kActivationPipeName, GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    // The server may be re-creating its instance: wait up to 1.5s and retry.
    if (::WaitNamedPipeW(kActivationPipeName, 1500)) {
      pipe = ::CreateFileW(kActivationPipeName, GENERIC_WRITE, 0, nullptr,
                           OPEN_EXISTING, 0, nullptr);
    }
  }
  if (pipe == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL ok =
      ::WriteFile(pipe, uri.data(), static_cast<DWORD>(uri.size()), &written,
                  nullptr);
  ::FlushFileBuffers(pipe);
  ::CloseHandle(pipe);
  return ok != FALSE && written == static_cast<DWORD>(uri.size());
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Set the process AUMID before any window exists: notification identity,
  // taskbar grouping and the Start Menu shortcut must all use the same id.
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  /*
   * Detect "another instance already owns the UI" before creating a window.
   *   - already running + activation URI: forward, then exit silently;
   *   - first instance + activation URI: persist it (Dart drains at prepare)
   *     and start normally.
   */
  HANDLE running_mutex = ::CreateMutexW(nullptr, FALSE, kRunningMutexName);
  const bool already_running =
      running_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;

  std::string activation_uri;
  for (const std::string& argument : command_line_arguments) {
    if (IsActivationUri(argument)) {
      activation_uri = argument;
      break;
    }
  }
  if (!activation_uri.empty()) {
    if (!ForwardToRunningInstance(activation_uri)) {
      AppendPendingActivation(activation_uri);
    }
    if (already_running) {
      if (running_mutex != nullptr) {
        ::CloseHandle(running_mutex);
      }
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // The three-pane layout (history / task list / chart) needs a wide window.
  // This is the *logical* size; win32_window scales it by the monitor DPI.
  Win32Window::Size size(1440, 900);
  if (!window.Create(L"TaskScheduler", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
