/// 应用身份常量：产品名称、展示版本与本地账户标签。
/// 版本需与 pubspec.yaml 保持一致；Flutter 不向框架暴露可执行文件的版本资源。

library;

const String kAppName = 'TaskScheduler';

/// Product version shown to users: 0.5.0.
const String kAppVersion = '0.5.0';

/// 与 pubspec 的三段式版本保持一致（不含构建号；构建号见 VERSION.txt）。
/// 发布目录与 pubspec 使用同一产品版本，不能把它们说成两个产品。
const String kAppVersionSemver = '0.5.0';

/// The single local account. There is deliberately no login system: this label only
/// exists as the entry point to the settings dialog.
const String kLocalUserName = 'admin';

/// Shown in the user menu as the secondary line (no real account data exists).
const String kLocalUserSubtitle = '本地账户 · 未登录云端';
