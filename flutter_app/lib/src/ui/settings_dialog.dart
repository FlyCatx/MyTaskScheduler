// Backwards-compatible entry point for the settings window.
//
// The 0.0.4 settings UI lives in `ui/settings/` (one file per page, plus the dialog and
// shared widgets). This library re-exports the public names so existing imports —
// `package:taskscheduler_flutter/src/ui/settings_dialog.dart` — keep working:
//
//   * `SettingsSection`  — the seven rail categories, unchanged names and order;
//   * `SettingsDialog`   — the dialog itself (now requires a `SettingsController`);
//   * `showSettingsDialog` — opener (now requires a `SettingsController`).
//
// There is deliberately no duplicated UI code here: a second copy would drift and could
// reintroduce hard-coded light colours that break the dark theme.
export 'settings/settings_dialog.dart';

