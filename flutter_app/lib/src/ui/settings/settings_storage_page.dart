// 「设置 → 存储」页（0.0.4）。
//
// 页面只报告真实状态，不做任何“看起来成功了”的提示：
//   * 数据目录取自 [SettingsController.dataRootPath]；来源优先用调用方传入的
//     `storageSource`（AppController 有权威值），否则按环境变量/程序路径推断，
//     并把“由程序路径推断”写在界面上，不让用户以为这是权威结果；
//   * 「打开目录」调用系统 explorer，失败时给出原因，不假装成功；
//   * 备份由 [BackupService] 生成单个 JSON（不含 API Key）；
//   * 恢复先校验（schemaVersion/结构/大小/同 ID 冲突），校验失败不覆盖任何数据；
//     同 ID 且内容相同视为已恢复（幂等）。恢复前若正在分析或设置窗口有未保存修改，
//     直接拒绝。成功后通过 [SettingsStoragePage.onDataRestored] 刷新会话列表，
//     并在结果里如实说明“已刷新 / 需重启”；
//   * 缓存清理只碰程序自有的 `<root>/cache` 目录（`tsc-` 前缀文件），不扫描
//     conversations/attachments/settings，也不按扩展名推断用户文件；预览与清理
//     共用 [BackupService.scanCache]，不会出现“看得见却删不到”。
//
// 与 settings_dialog 的契约：构造签名 `({super.key, required controller})`，
// 页面自己负责纵向滚动（小窗口 / 1.3 倍字号下不溢出）。

import 'dart:io';

import 'package:flutter/material.dart';

import '../../state/backup_service.dart';
import '../../state/session_store.dart';
import '../../state/storage_migration.dart';
import '../../state/settings_controller.dart';
import '../widgets/bezier_ui.dart';
import '../theme.dart';

/// 数据目录来源（与 `state/storage_root.dart` 的候选顺序一致）。
class StorageSourceInfo {
  const StorageSourceInfo({required this.source, required this.label});

  /// 机器可读标识：env / portable / localAppData / appData / temp / memory / unknown。
  final String source;

  /// 界面上显示的中文说明。
  final String label;
}

/// 把来源标识翻译成界面文案。
String storageSourceLabel(String source) {
  switch (source) {
    case 'env':
      return 'env（环境变量 TASKSCHEDULER_DATA_DIR）';
    case 'portable':
      return 'portable（程序目录下的 TaskSchedulerData）';
    case 'localAppData':
      return 'localAppData（%LOCALAPPDATA%）';
    case 'appData':
      return 'appData（%APPDATA%）';
    case 'temp':
      return 'temp（%TEMP%）';
    case 'memory':
      return 'memory（内存，未写入磁盘）';
    default:
      return '未知来源';
  }
}

String _normalizePath(String path) {
  var text = path.trim();
  if (text.isEmpty) return '';
  text = text.replaceAll('/', '\\');
  while (text.length > 1 && text.endsWith('\\')) {
    text = text.substring(0, text.length - 1);
  }
  return text.toLowerCase();
}

/// 从路径推断数据目录来源。
///
/// [environment] / [exeDirectory] 可注入，测试因此不依赖真实环境变量。
StorageSourceInfo inferStorageSource(
  String path, {
  Map<String, String>? environment,
  String? exeDirectory,
}) {
  final env = environment ?? Platform.environment;
  final target = _normalizePath(path);
  if (target.isEmpty) {
    return const StorageSourceInfo(source: 'memory', label: 'memory（内存）');
  }

  bool same(String candidate) =>
      candidate.trim().isNotEmpty && _normalizePath(candidate) == target;

  bool under(String parent) {
    final root = _normalizePath(parent);
    if (root.isEmpty) return false;
    return target == root || target.startsWith('$root\\');
  }

  if (same(env['TASKSCHEDULER_DATA_DIR'] ?? '')) {
    return const StorageSourceInfo(
      source: 'env',
      label: 'env（环境变量 TASKSCHEDULER_DATA_DIR）',
    );
  }

  final exeDir = (exeDirectory ??
          (Platform.resolvedExecutable.isEmpty
              ? ''
              : File(Platform.resolvedExecutable).parent.path))
      .trim();
  if (exeDir.isNotEmpty &&
      same('$exeDir${Platform.pathSeparator}TaskSchedulerData')) {
    return const StorageSourceInfo(
      source: 'portable',
      label: 'portable（程序目录下的 TaskSchedulerData）',
    );
  }

  if (under(env['LOCALAPPDATA'] ?? '') &&
      target.contains('taskschedulerflutter')) {
    return const StorageSourceInfo(
      source: 'localAppData',
      label: 'localAppData（%LOCALAPPDATA%）',
    );
  }

  if (under(env['APPDATA'] ?? '') && target.contains('taskschedulerflutter')) {
    return const StorageSourceInfo(
      source: 'appData',
      label: 'appData（%APPDATA%）',
    );
  }

  final temp = (env['TEMP'] ?? env['TMP'] ?? '').trim();
  if (under(temp)) {
    return const StorageSourceInfo(source: 'temp', label: 'temp（%TEMP%）');
  }

  return const StorageSourceInfo(source: 'unknown', label: '未知来源');
}

/// 「设置 → 存储」：数据目录、打开目录、备份、恢复、缓存清理。
///
/// [backupService] / [openDirectory] 是测试注入口；生产环境不传，走真实实现
/// （[BackupService] + `explorer.exe`）。
///
/// [onDataRestored] 由主界面传入：恢复成功后用来重新加载会话列表（AppController）。
/// 只有它真正执行成功，恢复结果才会显示“会话列表已刷新”，否则如实提示需要重启。
/// [isAnalysisRunning] 用来在分析进行中禁用恢复（恢复会覆盖正在使用的会话文件）。
class SettingsStoragePage extends StatefulWidget {
  final SettingsController controller;

  /// 权威来源标识（`AppController.storageSource`）。为空时按路径推断。
  final String? storageSource;

  /// 是否内存模式（`!AppController.storageIsPersistent`）。为空时按路径推断。
  final bool? memoryOnly;

  final BackupService? backupService;
  final Future<String?> Function(String path)? openDirectory;

  /// 恢复成功后的刷新回调（主代理在 app_shell 接线到 AppController）。
  final Future<void> Function()? onDataRestored;

  /// 分析是否进行中（`AppController.isRunning`）；为 true 时不允许恢复。
  final bool Function()? isAnalysisRunning;

  const SettingsStoragePage({
    super.key,
    required this.controller,
    this.storageSource,
    this.memoryOnly,
    this.backupService,
    this.openDirectory,
    this.onDataRestored,
    this.isAnalysisRunning,
  });

  @override
  State<SettingsStoragePage> createState() => _SettingsStoragePageState();
}

class _SettingsStoragePageState extends State<SettingsStoragePage> {
  late final BackupService _backup;
  final TextEditingController _backupPath = TextEditingController();
  final TextEditingController _restorePath = TextEditingController();
  final TextEditingController _migrationPath = TextEditingController();
  bool _migrateBusy = false;
  String? _migrateMessage;
  String? _migrateError;

  DirectoryUsage? _usage;
  bool _usageLoading = true;
  String? _usageError;

  String? _openError;
  bool _openBusy = false;

  bool _backupBusy = false;
  String? _backupMessage;
  String? _backupError;

  bool _restoreBusy = false;
  String? _restoreMessage;
  String? _restoreError;

  /// 上一次恢复失败时是否保证未改动任何文件（用于附加说明，不猜测）。
  bool _restoreDataUnchanged = true;

  bool _cleanBusy = false;
  String? _cleanMessage;
  String? _cleanError;

  @override
  void initState() {
    super.initState();
    _backup = widget.backupService ??
        BackupService(
          store: SessionStore(widget.controller.dataRoot),
          root: widget.controller.dataRoot,
          settings: widget.controller,
          // The page owns both hooks, so the service can report the truth about the
          // session list and about an analysis in flight.
          isBusy: _analysisRunning,
          reloadSessions:
              widget.onDataRestored == null ? null : _notifyDataRestored,
        );
    _backupPath.text = _defaultBackupPath();
    _loadUsage();
  }

  @override
  void dispose() {
    _backupPath.dispose();
    _restorePath.dispose();
    _migrationPath.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ paths

  String get _rootPath => widget.controller.dataRootPath;

  /// 分析是否进行中（由主界面注入的 `AppController.isRunning` 决定）。
  bool _analysisRunning() => widget.isAnalysisRunning?.call() ?? false;

  bool _memoryMode() =>
      widget.memoryOnly ?? widget.controller.dataRootPath.trim().isEmpty;

  /// 恢复成功后刷新会话列表；未接线时视为“没有刷新能力”。
  Future<void> _notifyDataRestored() async {
    final callback = widget.onDataRestored;
    if (callback != null) await callback();
  }

  bool get _memoryOnly =>
      widget.memoryOnly ??
      (widget.storageSource?.trim() == 'memory' ||
          widget.controller.dataRootPath.trim().isEmpty);

  StorageSourceInfo get _source {
    if (_memoryOnly) {
      return const StorageSourceInfo(
        source: 'memory',
        label: 'memory（内存，未写入磁盘）',
      );
    }
    final declared = widget.storageSource?.trim() ?? '';
    if (declared.isNotEmpty) {
      return StorageSourceInfo(
        source: declared,
        label: storageSourceLabel(declared),
      );
    }
    return inferStorageSource(_rootPath);
  }

  /// 默认备份名：`文档\TaskScheduler-backup-YYYYMMDD-HHmm.json`。
  String _defaultBackupPath() {
    final env = Platform.environment;
    final profile = (env['USERPROFILE'] ?? '').trim();
    final separator = Platform.pathSeparator;
    final base = profile.isNotEmpty
        ? '$profile${separator}Documents'
        : (env['APPDATA'] ?? _rootPath).trim();
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}';
    return '$base${separator}TaskScheduler-backup-$stamp.json';
  }

  // -------------------------------------------------------------- directory

  Future<void> _loadUsage() async {
    try {
      final usage = await _backup.directorySize();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _usageLoading = false;
        _usageError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usageLoading = false;
        _usageError = '统计目录大小失败：${_short(e)}';
      });
    }
  }

  void _refreshUsage() {
    setState(() {
      _usageLoading = true;
      _usageError = null;
    });
    _loadUsage();
  }

  Future<void> _openDirectory() async {
    setState(() {
      _openBusy = true;
      _openError = null;
    });
    final path = _rootPath;
    String? error;
    final custom = widget.openDirectory;
    try {
      if (custom != null) {
        error = await custom(path);
      } else if (path.trim().isEmpty) {
        error = '没有可打开的数据目录：当前是内存模式。';
      } else if (!await Directory(path).exists()) {
        error = '数据目录还不存在（可能尚未写入任何数据）：$path';
      } else {
        // Windows 上 explorer.exe 常常返回 1（把请求交给已有实例），
        // 因此 0 与 1 都视为已交给系统；其它退出码才报告失败。
        final result = await Process.run('explorer', <String>[path]);
        if (result.exitCode != 0 && result.exitCode != 1) {
          error = '打开目录失败：explorer 退出码 ${result.exitCode}';
        }
      }
    } catch (e) {
      error = '打开目录失败：${_short(e)}';
    }
    if (!mounted) return;
    setState(() {
      _openBusy = false;
      _openError = error;
    });
  }

  // ----------------------------------------------------------------- backup

  Future<void> _runBackup() async {
    final path = _backupPath.text.trim();
    if (path.isEmpty) {
      setState(() {
        _backupError = '请填写备份文件路径';
        _backupMessage = null;
      });
      return;
    }
    setState(() {
      _backupBusy = true;
      _backupError = null;
      _backupMessage = null;
    });
    try {
      final result = await _backup.exportBackup(path);
      if (!mounted) return;
      setState(() {
        _backupBusy = false;
        _backupMessage = '备份完成：${result.path}\n'
            '大小 ${formatByteCount(result.byteLength)} · '
            '${result.conversationCount} 个会话 · ${result.profileCount} 个连接';
      });
      _refreshUsage();
    } on BackupException catch (e) {
      if (!mounted) return;
      setState(() {
        _backupBusy = false;
        _backupError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backupBusy = false;
        _backupError = '备份失败：${_short(e)}';
      });
    }
  }

  // ---------------------------------------------------------------- restore

  Future<void> _runRestore() async {
    final path = _restorePath.text.trim();
    if (path.isEmpty) {
      setState(() {
        _restoreError = '请填写备份文件路径';
        _restoreMessage = null;
      });
      return;
    }
    // 恢复会覆盖会话文件，正在分析时不得进行（服务的 isBusy 也会再拒绝一次）。
    if (_analysisRunning()) {
      setState(() {
        _restoreError = '分析进行中：请等待当前分析结束或取消后再恢复';
        _restoreMessage = null;
      });
      return;
    }
    final confirmed = await _confirm(
      title: '从备份恢复？',
      message: '恢复前会校验版本、结构与同 ID 会话：内容不同则整体拒绝（不覆盖），'
          '内容相同则跳过。被替换的文件会先改名为 .bak，校验失败时不会修改任何数据。',
      confirmLabel: '恢复',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _restoreBusy = true;
      _restoreError = null;
      _restoreMessage = null;
    });
    try {
      final result = await _backup.restoreBackup(path);
      if (!mounted) return;
      var refreshed = result.sessionsReloaded;
      String? refreshError;
      if (result.ok && !refreshed) {
        // An injected service may not own the refresh hook, so the page performs the
        // refresh itself. Production also passes the hook into the service, so exactly
        // one refresh happens; the message below only claims what really happened.
        final callback = widget.onDataRestored;
        if (callback != null) {
          try {
            await callback();
            refreshed = true;
          } catch (e) {
            refreshError = '恢复已完成，但刷新会话列表失败：${_short(e)}';
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _restoreBusy = false;
        _restoreDataUnchanged = result.dataUnchanged;
        if (result.ok) {
          _restoreMessage = _restoreSuccessText(result, refreshed: refreshed);
          _restoreError = refreshError;
        } else {
          _restoreError = result.error ?? '恢复失败';
          _restoreMessage = null;
        }
      });
      if (result.ok) _refreshUsage();
    } on BackupException catch (e) {
      if (!mounted) return;
      setState(() {
        _restoreBusy = false;
        _restoreDataUnchanged = true;
        _restoreError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _restoreBusy = false;
        _restoreDataUnchanged = true;
        _restoreError = '恢复失败：${_short(e)}';
      });
    }
  }

  /// 恢复成功后的说明：只承诺真实发生的事（已刷新 / 需重启 / 偏好需下次启动后生效）。
  String _restoreSuccessText(
    BackupRestoreResult result, {
    required bool refreshed,
  }) {
    final lines = <String>[result.summary];
    if (refreshed) {
      lines.add('会话列表已刷新。');
    } else if (result.requiresRestart) {
      lines.add('请重启程序，以看到恢复后的会话列表。');
    }
    if (result.restoredPrefs && !result.prefsReloaded) {
      lines.add('应用偏好已写入，下次启动后生效。');
    }
    if (result.restoredProfileCount > 0) {
      lines.add('备份不含 API Key：恢复后的模型连接需要重新输入密钥。');
    }
    return lines.join('\n');
  }

  // ---------------------------------------------------------------- cleanup

  Future<void> _runCleanup() async {
    setState(() {
      _cleanBusy = true;
      _cleanError = null;
      _cleanMessage = null;
    });
    // 预览与清理共用 [BackupService.scanCache]，不存在第二套扫描逻辑。
    CachePreview preview;
    try {
      preview = await _backup.scanCache();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cleanBusy = false;
        _cleanError = '检查应用缓存失败：${_short(e)}';
      });
      return;
    }
    if (!mounted) return;
    if (preview.skippedReason != null) {
      setState(() {
        _cleanBusy = false;
        _cleanError = '无法读取应用缓存目录：${preview.skippedReason}';
      });
      return;
    }
    if (preview.isEmpty) {
      setState(() {
        _cleanBusy = false;
        _cleanMessage = '没有发现可清理的应用缓存文件。';
      });
      return;
    }
    setState(() => _cleanBusy = false);
    final shown = preview.names.take(5).join('、');
    final more = preview.names.length > 5 ? ' 等' : '';
    final confirmed = await _confirm(
      title: '清理应用缓存？',
      message: '将删除 ${preview.fileCount} 个应用缓存文件'
          '（${formatByteCount(preview.bytes)}）：$shown$more。\n'
          '只清理程序自有缓存目录（${preview.directory}）中的 tsc- 文件；'
          '历史会话、附件与你上传的原文件不会被删除。',
      confirmLabel: '清理',
    );
    if (!confirmed || !mounted) return;
    setState(() => _cleanBusy = true);
    try {
      final result = await _backup.clearCache();
      if (!mounted) return;
      setState(() {
        _cleanBusy = false;
        if (result.skipped) {
          _cleanError = result.summary;
        } else {
          _cleanError = result.failedPaths.isEmpty
              ? null
              : '${result.failedPaths.length} 个缓存文件被占用，未删除：'
                  '${result.failedPaths.take(3).join('、')}';
          _cleanMessage = result.deletedFiles == 0
              ? result.summary
              : '${result.summary}。历史、附件与用户文件未改动。';
        }
      });
      _refreshUsage();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cleanBusy = false;
        _cleanError = '清理失败：${_short(e)}';
      });
    }
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _directoryCard(),
          const SizedBox(height: 10),
          _migrationCard(),
          const SizedBox(height: 10),
          _backupCard(),
          const SizedBox(height: 10),
          _restoreCard(),
          const SizedBox(height: 10),
          _cleanupCard(),
        ],
      ),
    );
  }

  Widget _directoryCard() {
    final source = _source;
    final usage = _usage;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('数据目录'),
          const SizedBox(height: 4),
          // The full local path, the "来源 portable …" line and the "持久化 可写 …" line
          // are deliberately NOT shown: they were permanent implementation details.
          // The path is still reachable through 打开目录, and the storage layer is
          // untouched. 占用 (usage) is real information and stays.
          _infoRow('占用', _usageText(usage)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('settings-storage-open'),
                onPressed: _openBusy || _memoryOnly ? null : _openDirectory,
                icon: const Icon(Icons.folder_open, size: 15),
                label: Text(
                  _openBusy ? '正在打开…' : '打开目录',
                  style: const TextStyle(fontSize: 11.5),
                ),
                style: _buttonStyle(),
              ),
              OutlinedButton.icon(
                key: const Key('settings-storage-refresh'),
                onPressed: _usageLoading ? null : _refreshUsage,
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('刷新占用', style: TextStyle(fontSize: 11.5)),
                style: _buttonStyle(),
              ),
            ],
          ),
          if (_openError != null) _errorBox(_openError!),
          if (_usageError != null) _errorBox(_usageError!),
          if (_memoryOnly)
            _warn('内存模式：本次运行的会话与设置都不会写入磁盘，关闭程序即丢失。'
                '请把程序放到可写目录，或设置环境变量 TASKSCHEDULER_DATA_DIR。')
          else if (source.source == 'temp')
            _warn('这个目录位于系统临时区：Windows 可能随时清理，'
                '长期使用请把程序放到可写目录或设置 TASKSCHEDULER_DATA_DIR。'),
        ],
      ),
    );
  }

  String _usageText(DirectoryUsage? usage) {
    if (_usageLoading && usage == null) return '正在统计…';
    if (usage == null) return '未知（统计失败）';
    final text = '${usage.formatted} · ${usage.files} 个文件';
    return _usageLoading ? '$text（正在刷新…）' : text;
  }

  Widget _migrationCard() {
    final memory = _memoryMode();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('迁移到长期位置'),
          if (memory)
            _warn('当前是内存模式（没有可写目录），无法迁移；请先放到可写目录。'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('settings-storage-migration-path'),
            controller: _migrationPath,
            enabled: !memory,
            style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
            decoration: InputDecoration(
              labelText: '新的数据目录（必须是空目录）',
              isDense: true,
              labelStyle:
                  TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
              hintText: '例如 D:\\TaskSchedulerData',
              hintStyle: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('settings-storage-migrate-run'),
              onPressed: memory || _migrateBusy ? null : _runMigration,
              icon: const Icon(Icons.drive_file_move_outline, size: 15),
              label: Text(_migrateBusy ? '正在复制并校验…' : '迁移到该目录',
                  style: const TextStyle(fontSize: 11.5)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                textStyle: const TextStyle(fontSize: 11.5),
              ),
            ),
          ),
          if (memory)
            _note('当前是内存模式（没有可写目录），无法迁移；请先放到可写目录。'),
          if (_migrateError != null) _errorBox(_migrateError!),
          if (_migrateMessage != null) _successBox(_migrateMessage!),
        ],
      ),
    );
  }

  Future<void> _runMigration() async {
    final target = _migrationPath.text.trim();
    final current = widget.controller.dataRootPath;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移数据目录？', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: Text(
            '将把\n$current\n\n复制并校验到\n$target\n\n'
            '成功后重启程序才会切换；旧目录不会删除。',
            style: const TextStyle(fontSize: 12, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('开始迁移')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _migrateBusy = true;
      _migrateError = null;
      _migrateMessage = null;
    });
    final result = await StorageMigrationService.migrate(
      sourcePath: current,
      targetPath: target,
      environment: Platform.environment,
    );
    if (!mounted) return;
    setState(() {
      _migrateBusy = false;
      if (result.ok) {
        _migrateMessage = '已复制 ${result.files} 个文件（${result.bytes} 字节）并校验通过，'
            '目标：${result.target}。下次启动后生效。${result.warning ?? ''}';
      } else {
        _migrateError = result.error;
      }
    });
  }

  Widget _backupCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('备份'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('settings-storage-backup-path'),
            controller: _backupPath,
            style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
            decoration: InputDecoration(
              labelText: '备份文件路径（保存到）',
              isDense: true,
              labelStyle:
                  TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
              hintStyle: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('settings-storage-backup-run'),
              onPressed: _backupBusy ? null : _runBackup,
              icon: const Icon(Icons.save_alt, size: 15),
              label: Text(
                _backupBusy ? '正在备份…' : '生成备份',
                style: const TextStyle(fontSize: 11.5),
              ),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                textStyle: const TextStyle(fontSize: 11.5),
              ),
            ),
          ),
          if (_backupError != null) _errorBox(_backupError!),
          if (_backupMessage != null) _successBox(_backupMessage!),
        ],
      ),
    );
  }

  Widget _restoreCard() {
    final running = _analysisRunning();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('恢复'),
          if (running)
            _warn('分析进行中：恢复会覆盖会话文件，请等待当前分析结束或取消后再恢复。'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('settings-storage-restore-path'),
            controller: _restorePath,
            style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
            decoration: InputDecoration(
              labelText: '备份文件路径（从何处恢复）',
              isDense: true,
              labelStyle:
                  TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
              hintStyle: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('settings-storage-restore-run'),
              onPressed: _restoreBusy || running ? null : _runRestore,
              icon: const Icon(Icons.restore, size: 15),
              label: Text(
                _restoreBusy ? '正在恢复…' : '从备份恢复',
                style: const TextStyle(fontSize: 11.5),
              ),
              style: _buttonStyle(),
            ),
          ),
          if (_restoreError != null)
            _errorBox(
              '${_restoreError!}'
              '${_restoreDataUnchanged ? '\n原有数据未被修改。' : ''}',
            ),
          if (_restoreMessage != null) _successBox(_restoreMessage!),
        ],
      ),
    );
  }

  Widget _cleanupCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionTitle('清理缓存'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('settings-storage-clean-run'),
              onPressed: _cleanBusy ? null : _runCleanup,
              icon: const Icon(Icons.cleaning_services_outlined, size: 15),
              label: Text(
                _cleanBusy ? '正在检查…' : '检查并清理缓存',
                style: const TextStyle(fontSize: 11.5),
              ),
              style: _buttonStyle(),
            ),
          ),
          if (_cleanError != null) _errorBox(_cleanError!),
          if (_cleanMessage != null) _successBox(_cleanMessage!),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- primitives

  Widget _sectionTitle(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: TsColors.textPrimary,
        ),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                label,
                style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: TsColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: bezierDecoration(
          color: TsColors.surface,
          radius: 12,
          border: Border.all(color: TsColors.border),
        ),
        child: child,
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.info_outline,
                size: 13,
                color: TsColors.textFaint,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: TsColors.textFaint,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _warn(String text) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.pendingSoft,
          radius: 8,
          border: Border.all(color: TsColors.pending),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.pending),
        ),
      );

  Widget _errorBox(String text) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.blockedSoft,
          radius: 8,
          border: Border.all(color: TsColors.blocked),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.blocked),
        ),
      );

  Widget _successBox(String text) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.readySoft,
          radius: 8,
          border: Border.all(color: TsColors.ready),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: TsColors.ready),
        ),
      );

  ButtonStyle _buttonStyle() =>
      TsButtons.filled(radius: 8, minimumSize: const Size(0, 32));

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TsColors.surface,
        title: Text(
          title,
          style: TextStyle(fontSize: 14.5, color: TsColors.textPrimary),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            message,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: TsColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: const Key('settings-storage-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TsButtons.filled(radius: 8),
            child: Text(confirmLabel, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static String _short(Object e) {
    final text = e.toString().replaceAll('\n', ' ');
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}

