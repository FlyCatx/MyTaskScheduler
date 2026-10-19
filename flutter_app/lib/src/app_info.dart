/// 应用身份常量：名称、产品版本、构建版本与本地账户标签（设置 → 关于 使用）。
/// 需与 pubspec.yaml 的 version 保持同步；Flutter 不向框架暴露可执行文件的版本资源。

library;

const String kAppName = 'TaskScheduler';

/// Product version shown to users: 0.1.0.
const String kAppVersion = '0.1.0';

/// Three-part build/pubspec version. The release folder and pubspec use the same
/// 0.1.0; never present them as different products.
const String kAppVersionSemver = '0.1.0';

/// The single local account. There is deliberately no login system: this label only
/// exists as the entry point to the settings dialog.
const String kLocalUserName = 'admin';

/// Shown in the user menu as the secondary line (no real account data exists).
const String kLocalUserSubtitle = '本地账户 · 未登录云端';

