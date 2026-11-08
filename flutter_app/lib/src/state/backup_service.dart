// Backup / restore / cache maintenance for the local data folder.
//
// Product rules encoded here:
//   * one single JSON file per backup, containing preferences, the sidebar index, the
//     conversations and the (key-less) connection list;
//   * **no secret ever leaves the machine**: keys live in Windows Credential Manager and
//     are neither readable from Dart nor written into the backup (defence in depth: a
//     recursive scrub drops any key-like field anyway);
//   * restore validates structure, size, ids **and conflicts** before touching anything,
//     rejects the whole import when an existing conversation with the same id has
//     different content (identical content is skipped, making a restore idempotent),
//     stages the payload in the app-owned cache directory, and only then commits — the
//     previous files are renamed to `.bak` first, and a commit failure is rolled back and
//     reported file by file;
//   * cache maintenance only ever looks at the app-owned cache directory
//     `<root>/cache`, which is a name we choose ourselves. It never scans
//     `conversations/`, `attachments/` or `settings/`, and never infers anything from a
//     file extension — an active `.tmp` write or a user-supplied `.tmp` in those folders
//     is never a cache file;
//   * restore and cache cleanup are mutually exclusive: one static in-process queue plus
//     a best-effort exclusive OS lock on `<root>/cache/.lock`. The lock file itself is
//     never deleted.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../model/external_calendar.dart' show kExternalCalendarDirName;
import '../model/schedule_event.dart';
import '../model/session.dart';
import '../model/settings.dart';
import 'execution/execution_ledger.dart';
import 'execution/execution_store.dart';
import 'schedule/schedule_store.dart';
import 'session_repository.dart';
import 'settings_controller.dart';
import 'settings_store.dart';

/// Result of a successful backup export.
class BackupExportResult {
  const BackupExportResult({
    required this.path,
    required this.conversationCount,
    required this.profileCount,
    required this.byteLength,
    this.ocrMaterialFileCount = 0,
    this.missingOcrMaterialPaths = const <String>[],
    this.unsafeOcrMaterialPaths = const <String>[],
    this.scheduleEventCount = 0,
    this.warning,
  });

  final String path;
  final int conversationCount;
  final int profileCount;
  final int byteLength;

  /// 备份里实际包含的 OCR 来源文件数（`ocr_materials/<attachmentId>.json`）。
  final int ocrMaterialFileCount;

  /// 会话引用了、但数据目录里已缺失（或不是普通文件）的 OCR 来源文件。
  ///
  /// 备份仍然写出其余数据，但这些附件的详细来源没有进入备份，必须如实报告，
  /// 不能把这份备份说成“完整成功”。
  final List<String> missingOcrMaterialPaths;

  /// 引用路径落在符号链接/联接点上而被拒绝读取的 OCR 来源文件（不跟随到目录外）。
  final List<String> unsafeOcrMaterialPaths;

  /// 备份里包含的全局日程记录数（含删除标记）。0 = 未启用日程服务或没有日程。
  final int scheduleEventCount;

  /// 非致命问题（OCR 来源文件缺失/被拒绝、日程内存模式等）；UI 应展示，
  /// 不能静默忽略。
  final String? warning;

  String get summary {
    final ocr = ocrMaterialFileCount > 0
        ? '、$ocrMaterialFileCount 个 OCR 来源文件'
        : '';
    final schedule =
        scheduleEventCount > 0 ? '、$scheduleEventCount 条日程' : '';
    final base = '已备份 $conversationCount 个会话、$profileCount 个连接$ocr$schedule'
        '（${formatByteCount(byteLength)}）：$path';
    final notice = warning;
    return notice == null ? base : '$base；$notice';
  }
}

/// Result of a restore attempt. [ok] false always leaves the previous data in place.
class BackupRestoreResult {
  const BackupRestoreResult({
    required this.ok,
    this.error,
    this.warning,
    this.conversationCount = 0,
    this.restoredConversationCount = 0,
    this.skippedConversationCount = 0,
    this.restoredPrefs = false,
    this.prefsReloaded = false,
    this.profileCount = 0,
    this.restoredProfileCount = 0,
    this.backupPaths = const <String>[],
    this.rolledBackPaths = const <String>[],
    this.rollbackFailedPaths = const <String>[],
    this.commitAttempted = false,
    this.conflictConversationIds = const <String>[],
    this.sessionsReloaded = false,
    this.requiresRestart = false,
    this.externalCalendarFileCount = 0,
    this.restoredExternalCalendarFileCount = 0,
    this.executionRecordCount = 0,
    this.restoredExecutionRecordCount = 0,
    this.ocrMaterialFileCount = 0,
    this.restoredOcrMaterialFileCount = 0,
    this.skippedOcrMaterialFileCount = 0,
    this.conflictOcrMaterialPaths = const <String>[],
    this.missingOcrMaterialReferenceCount = 0,
    this.scheduleSectionPresent = false,
    this.scheduleEventCount = 0,
    this.restoredScheduleEventCount = 0,
    this.skippedScheduleEventCount = 0,
    this.conflictScheduleEventIds = const <String>[],
    this.unlinkedScheduleEventIds = const <String>[],
    this.scheduleNotices = const <String>[],
    this.scheduleReloaded = false,
  });

  final bool ok;
  final String? error;

  /// Non-fatal problem, e.g. sessions restored but the model connections could not be
  /// written. Never silent: the storage page must show this.
  final String? warning;

  /// Conversations present in the backup file (informational).
  final int conversationCount;

  /// Conversations actually written (new ones; identical ones are skipped).
  final int restoredConversationCount;

  /// Conversations skipped because an identical copy already exists locally. A restore of
  /// the same backup twice therefore changes nothing the second time.
  final int skippedConversationCount;

  /// True when the preferences file was actually rewritten (different content).
  final bool restoredPrefs;

  /// True when the live controller re-read the restored preferences.
  final bool prefsReloaded;

  /// Number of connections present in the backup file (informational).
  final int profileCount;

  /// Number of connections actually re-created through the settings controller.
  final int restoredProfileCount;

  /// Files that were renamed to `.bak` before being replaced (recovery path).
  final List<String> backupPaths;

  /// Targets that were replaced and then put back by the rollback of a failed commit.
  final List<String> rolledBackPaths;

  /// Targets whose rollback failed: the user must be told those files were not restored.
  final List<String> rollbackFailedPaths;

  /// True once the commit phase started renaming files. A validation failure before this
  /// point is genuinely "nothing was touched"; a failed commit is not.
  final bool commitAttempted;

  /// Conversation ids that exist locally with different content; the restore was
  /// rejected as a whole (nothing was written).
  final List<String> conflictConversationIds;

  /// True when the session list was refreshed through the injected callback **and it
  /// succeeded**. Only then may the UI claim the list is up to date.
  final bool sessionsReloaded;

  /// True when a restart is genuinely required to see the restored data (no refresh
  /// callback was available, or the preferences could not be re-read in this run).
  final bool requiresRestart;

  /// 备份文件里包含的外部日历文件数（`<root>/external_calendar/` 下的文件）。
  final int externalCalendarFileCount;

  /// 实际写入的外部日历文件数（内容相同的会被跳过）。
  final int restoredExternalCalendarFileCount;

  /// 0.2.3（R3-E）：备份中包含/实际合并的执行记录条数。
  ///
  /// 同一份备份重复恢复时 [restoredExecutionRecordCount] 为 0 —— 记录已在本地，
  /// 按 recordId 幂等跳过，不会重复累计。
  final int executionRecordCount;
  final int restoredExecutionRecordCount;

  /// 备份里包含的 OCR 来源文件数（`ocr_materials/<attachmentId>.json`）。
  final int ocrMaterialFileCount;

  /// 实际写入的 OCR 来源文件数（同路径同内容的会跳过，重复恢复因此幂等）。
  final int restoredOcrMaterialFileCount;

  /// 本地已有相同内容、按幂等跳过写入的 OCR 来源文件数。
  final int skippedOcrMaterialFileCount;

  /// 本地同路径内容不同（或路径不可安全写入）而未覆盖的 OCR 来源文件。
  final List<String> conflictOcrMaterialPaths;

  /// 备份中被附件引用、但备份与本地都没有的来源文件数：恢复后详细来源缺失，
  /// 文字仍然有效。必须计数并作为 warning 报告。
  final int missingOcrMaterialReferenceCount;

  /// 备份里是否带全局日程段。旧备份没有该段 → false；此时绝不清空本地日程。
  final bool scheduleSectionPresent;

  /// 备份里的日程记录数（含删除标记）。
  final int scheduleEventCount;

  /// 实际新增到本地日程库的记录数。
  final int restoredScheduleEventCount;

  /// 本地已存在且内容相同、按幂等跳过的日程记录数。
  final int skippedScheduleEventCount;

  /// 本地同 ID 但内容不同、为避免覆盖而保留本地的日程记录 ID。
  final List<String> conflictScheduleEventIds;

  /// 恢复的日程中，关联会话在备份与本地都不存在、因而被解除关联的记录 ID。
  final List<String> unlinkedScheduleEventIds;

  /// 日程未恢复/未刷新等需要用户知道的原因；同时并入 [warning]，存储页单独展示。
  final List<String> scheduleNotices;

  /// 日程服务是否已在本次恢复后刷新成功。
  final bool scheduleReloaded;

  /// True only when no file was replaced, or every replaced file was verifiably put
  /// back. An empty rollback list after a partially attempted commit is *not* proof of
  /// "unchanged".
  bool get dataUnchanged =>
      ok ||
      !commitAttempted ||
      (rolledBackPaths.isNotEmpty && rollbackFailedPaths.isEmpty);

  String get summary {
    if (!ok) return error ?? '恢复失败';
    final applied = <String>[
      if (restoredConversationCount > 0) '$restoredConversationCount 个会话',
      if (restoredExternalCalendarFileCount > 0)
        '$restoredExternalCalendarFileCount 个外部日历文件',
      if (restoredOcrMaterialFileCount > 0)
        '$restoredOcrMaterialFileCount 个 OCR 来源文件',
      if (restoredScheduleEventCount > 0)
        '$restoredScheduleEventCount 条日程',
      if (restoredPrefs) '应用偏好',
      if (restoredProfileCount > 0)
        '$restoredProfileCount 个模型连接（密钥需重新输入）',
    ];
    final skipped = skippedConversationCount > 0
        ? '；$skippedConversationCount 个会话内容相同，已跳过'
        : '';
    // 部分恢复必须让用户看到：被跳过的来源文件、悬空引用与日程冲突不能只藏在
    // warning 字段里（存储页展示的是 summary）。
    final notesList = <String>[
      if (conflictOcrMaterialPaths.isNotEmpty)
        '${conflictOcrMaterialPaths.length} 个 OCR 来源文件与本地不同或不可安全写入，未覆盖',
      if (missingOcrMaterialReferenceCount > 0)
        '$missingOcrMaterialReferenceCount 个 OCR 附件的详细来源文件缺失（文字保留）',
      if (skippedScheduleEventCount > 0)
        '$skippedScheduleEventCount 条日程内容相同，已跳过',
      if (conflictScheduleEventIds.isNotEmpty)
        '${conflictScheduleEventIds.length} 条日程与本地同 ID 但内容不同，保留本地',
      if (unlinkedScheduleEventIds.isNotEmpty)
        '${unlinkedScheduleEventIds.length} 条日程的关联会话不存在，已解除关联',
    ];
    final notes = notesList.isEmpty ? '' : '；${notesList.join('；')}';
    if (applied.isEmpty) {
      return '备份内容与本地一致，未恢复任何数据$skipped$notes';
    }
    return '已恢复 ${applied.join('、')}$skipped$notes';
  }
}

/// One file inside the app-owned cache directory that [BackupService.clearCache] may
/// delete.
class CachePreviewEntry {
  const CachePreviewEntry({required this.name, required this.bytes});

  /// File name relative to `<root>/cache` (never a full path).
  final String name;

  final int bytes;
}

/// What a cache scan found: the exact set [BackupService.clearCache] would delete.
///
/// The storage page shows this before asking for confirmation, and both operations share
/// one implementation, so the preview can never describe a different set.
class CachePreview {
  const CachePreview({
    this.entries = const <CachePreviewEntry>[],
    this.directory = '',
    this.skippedReason,
  });

  final List<CachePreviewEntry> entries;

  /// Absolute path of the app-owned cache directory (`<root>/cache`).
  final String directory;

  /// Non-null when the directory could not be read at all.
  final String? skippedReason;

  int get fileCount => entries.length;

  int get bytes {
    var total = 0;
    for (final entry in entries) {
      total += entry.bytes;
    }
    return total;
  }

  bool get isEmpty => entries.isEmpty;

  List<String> get names =>
      entries.map((entry) => entry.name).toList(growable: false);

  String get summary => skippedReason != null
      ? '无法读取应用缓存目录：$skippedReason'
      : (isEmpty
          ? '没有可清理的应用缓存文件'
          : '应用缓存：$fileCount 个文件（${formatByteCount(bytes)}）');
}

/// Result of a cache cleanup.
class CacheClearResult {
  const CacheClearResult({
    required this.deletedFiles,
    required this.bytes,
    this.paths = const <String>[],
    this.failedPaths = const <String>[],
    this.skippedReason,
  });

  final int deletedFiles;
  final int bytes;

  /// File names (not full paths) that were deleted.
  final List<String> paths;

  /// Cache files that existed but could not be deleted (locked by another process).
  final List<String> failedPaths;

  /// Set when the cleanup did not run at all (cache directory or lock unavailable).
  /// Reported to the user instead of pretending something was cleaned.
  final String? skippedReason;

  bool get skipped => skippedReason != null;

  String get summary {
    if (skippedReason != null) return '未清理任何文件：$skippedReason';
    if (deletedFiles == 0) {
      if (failedPaths.isNotEmpty) {
        return '没有文件被删除（${failedPaths.length} 个缓存文件被占用）';
      }
      return '没有可清理的应用缓存文件';
    }
    final partial = failedPaths.isEmpty
        ? ''
        : '；${failedPaths.length} 个文件被占用未删除';
    return '已清理 $deletedFiles 个缓存文件（${formatByteCount(bytes)}）$partial';
  }
}

/// Size of the data directory, for the storage page.
class DirectoryUsage {
  const DirectoryUsage({required this.bytes, required this.files});

  final int bytes;
  final int files;

  String get formatted => formatByteCount(bytes);
}

/// Human byte count (1024-based, one decimal above 1 KB).
String formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class BackupService {
  BackupService({
    required this.store,
    required this.root,
    this.settings,
    SettingsStore? settingsStore,
    this.execution,
    this.maxImportBytesLimit = maxImportBytes,
    this.maxOcrMaterialBytesLimit = maxOcrMaterialBytes,
    this.maxOcrMaterialsTotalBytesLimit = maxOcrMaterialsTotalBytes,
    this.maxScheduleEventsLimit = maxScheduleEvents,
    this.maxScheduleSectionBytesLimit = maxScheduleSectionBytes,
    this.scheduleStore,
    this.isBusy,
    this.reloadSessions,
    this.reloadExternalCalendar,
    this.reloadSchedule,
  }) : settingsStore = settingsStore ?? SettingsStore(root);

  /// Backup schema version written by this build.
  static const int schemaVersion = 1;

  /// 外部日历数据目录名：`<root>/external_calendar/`。
  ///
  /// 备份把它作为**数据**一起保存（base64 文件内容），恢复后不依赖原 .ics 文件；
  /// 外部日历快照本身已经包含标准化事件时间，所以重新导入源文件并不必要。
  static const String externalCalendarDirectoryName = kExternalCalendarDirName;

  /// 外部日历在备份文档里的结构版本。
  static const int externalCalendarSchemaVersion = 1;

  /// OCR 页级来源数据目录名：`<root>/ocr_materials/`。
  ///
  /// `AppController.addOcrMaterial` 把每份 OCR 材料的页级来源、校对记录与引擎信息
  /// 写成 `<attachmentId>.json`；附件只保存摘要与相对路径。备份按会话实际引用收集
  /// 这些文件（base64 内容 + 长度 + SHA-256），**不含原始页图、密钥或任意原路径文件**。
  static const String ocrMaterialsDirectoryName = 'ocr_materials';

  /// OCR 来源数据在备份文档里的结构版本。
  static const int ocrMaterialsSchemaVersion = 1;

  /// Hard limit for an import file (a backup is text; 32 MB is generous). Overridable
  /// through [maxImportBytesLimit] so tests do not have to write 32 MB.
  static const int maxImportBytes = 32 * 1024 * 1024;

  /// 单个 OCR 来源文件的上限（解码后字节）。正常页级 JSON 每页只有几百字节到几 KB。
  ///
  /// 备份是单个 JSON 文本，恢复上限仍受 [maxImportBytesLimit] 约束；两个 OCR 上限
  /// 一起保证导出的备份不会大到本程序自己无法导入。可用构造参数在测试中收紧。
  static const int maxOcrMaterialBytes = 4 * 1024 * 1024;

  /// 一次备份/恢复中所有 OCR 来源文件的总字节上限（解码后）。
  static const int maxOcrMaterialsTotalBytes = 8 * 1024 * 1024;

  /// 全局日程数据在备份文档里的结构版本（与 `schedules/events.json` 相同）。
  static const int scheduleSchemaVersion = kScheduleSchemaVersion;

  /// 单次备份/恢复允许的日程记录上限（含删除标记）；超出整份拒绝。
  ///
  /// 正常本地日程远小于该值；上限只用于阻止恶意/损坏备份撑爆内存。可用构造
  /// 参数在测试中收紧。
  static const int maxScheduleEvents = 20000;

  /// 日程段序列化后的字节上限（备份是单个 JSON，仍受 [maxImportBytesLimit] 约束）。
  static const int maxScheduleSectionBytes = 8 * 1024 * 1024;

  /// Name of the app-owned cache directory (`<root>/cache`).
  static const String cacheDirectoryName = 'cache';

  /// Restore staging subdirectory inside the cache directory. It is **excluded** from
  /// cache scans and deletions: a restore in progress must never lose its staged files.
  static const String restoreStagingName = 'restore';

  /// Best-effort cross-process lock file inside the cache directory. Never deleted.
  static const String cacheLockFileName = '.lock';

  /// Cache files are named by this program with this prefix; anything else in the cache
  /// directory (a user's file, a dot-file, the lock) is never deleted.
  static const String cacheFilePrefix = 'tsc-';

  final int maxImportBytesLimit;

  /// 见 [maxOcrMaterialBytes]；测试用较小值验证解码前后的总量限额。
  final int maxOcrMaterialBytesLimit;

  /// 见 [maxOcrMaterialsTotalBytes]；测试用较小值验证总量限额。
  final int maxOcrMaterialsTotalBytesLimit;

  /// 见 [maxScheduleEvents]；测试用较小值验证日程数量限额。
  final int maxScheduleEventsLimit;

  /// 见 [maxScheduleSectionBytes]；测试用较小值验证日程段大小限额。
  final int maxScheduleSectionBytesLimit;

  static const String backupKind = 'taskscheduler-backup';

  final SessionRepository store;
  final Directory root;
  final SettingsController? settings;
  final SettingsStore settingsStore;

  /// 执行计时账本（0.2.3 R3-E）。可空 = 本次运行未启用执行计时：
  /// 备份里不带执行记录，恢复时如实提示，而不是假装已经恢复。
  ///
  /// 必须复用运行中的 [ExecutionStore]（它持有实例写锁）；另外 new 一个同目录的
  /// store 会变成只读实例，无法合并。
  final ExecutionStore? execution;

  /// Reports whether an analysis is in progress. A restore while a request is running
  /// could replace conversations the request is about to commit into, so it is refused
  /// before any file is touched. Defaults to "not busy".
  final bool Function()? isBusy;

  /// Refreshes the live session list after a successful restore. When absent (or when it
  /// throws) the result reports [BackupRestoreResult.requiresRestart] instead of claiming
  /// that the UI is up to date.
  final Future<void> Function()? reloadSessions;

  /// 恢复外部日历文件后让内存里的服务重新加载。缺失时可报告“重启后生效”。
  final Future<void> Function()? reloadExternalCalendar;

  /// 全局日程权威库（0.4.0）。null = 本次运行未启用日程：导出不带日程段，
  /// 恢复遇到日程段时如实提示未恢复，而不是假装成功。
  ///
  /// 必须复用运行中的 [ScheduleStore]（它持有实例锁并缓存快照）；另外 new 一个
  /// 同目录的 store 会变成只读实例，无法写回。
  final ScheduleStore? scheduleStore;

  /// 备份恢复后刷新日程服务：生产接线为 `ScheduleController.reloadFromDisk`，
  /// 它会重新读盘并通知日历叠层。缺失时退回 `ScheduleStore.reload()` 并报告
  /// 界面需重启/重新打开日程列表后才一致。
  final Future<void> Function()? reloadSchedule;

  static const Set<String> _sensitiveKeys = <String>{
    'apikey',
    'key',
    'token',
    'accesstoken',
    'secret',
    'clientsecret',
    'password',
    'authorization',
    'credential',
    'bearertoken',
    'bearer',
  };

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  // ---------------------------------------------------------------- paths

  File _file(String relative) =>
      File('${root.path}${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}');

  File _conversationFile(String id) => _file('conversations/$id.json');

  File get _indexFile => _file('index.json');

  File get _prefsFile => _file('settings/app_prefs.json');

  /// The one directory this program is allowed to clean.
  Directory get cacheDirectory =>
      Directory('${root.path}${Platform.pathSeparator}$cacheDirectoryName');

  /// Staging area for a restore: `<root>/cache/restore/`.
  Directory get restoreStagingDirectory =>
      Directory('${cacheDirectory.path}${Platform.pathSeparator}'
          '$restoreStagingName');

  File get cacheLockFile =>
      File('${cacheDirectory.path}${Platform.pathSeparator}$cacheLockFileName');

  File _stagedFile(String name) =>
      File('${restoreStagingDirectory.path}${Platform.pathSeparator}$name');

  /// `<root>/external_calendar/`（外部日历快照目录，由 ExternalCalendarStore 写入）。
  Directory get externalCalendarDirectory => Directory(
      '${root.path}${Platform.pathSeparator}$externalCalendarDirectoryName');

  File _externalCalendarFile(String relativePosix) => File(
      '${externalCalendarDirectory.path}${Platform.pathSeparator}'
      '${relativePosix.replaceAll('/', Platform.pathSeparator)}');

  /// `<root>/ocr_materials/`（OCR 页级来源数据目录，由 `addOcrMaterial` 写入）。
  Directory get ocrMaterialsDirectory => Directory(
      '${root.path}${Platform.pathSeparator}$ocrMaterialsDirectoryName');

  File _ocrMaterialFile(String relativePosix) => File(
      '${root.path}${Platform.pathSeparator}'
      '${relativePosix.replaceAll('/', Platform.pathSeparator)}');

  /// `<root>/schedules/`（全局日程权威目录，由 ScheduleStore 写入）。
  Directory get schedulesDirectory =>
      Directory('${root.path}${Platform.pathSeparator}schedules');

  /// `<root>/schedules/events.json`（全局日程权威文件）。
  File get scheduleEventsFile => File(
      '${schedulesDirectory.path}${Platform.pathSeparator}events.json');

  // --------------------------------------------------------------- export

  /// Writes one key-less backup JSON to [path].
  Future<BackupExportResult> exportBackup(String path) async {
    final index = await store.loadIndex();
    final conversations = <Map<String, dynamic>>[];
    final referencedOcrPaths = <String>{};
    for (final summary in index) {
      final conversation = await store.loadConversation(summary.id);
      if (conversation == null) continue;
      conversations.add(conversation.toJson());
      // 只收集会话实际引用、且路径通过 `ocr_materials/<id>.json` 白名单的来源文件。
      for (final attachment in conversation.attachments) {
        final relative = _ocrMaterialPathOf(attachment);
        if (relative != null) referencedOcrPaths.add(relative);
      }
    }
    final externalCalendarFiles = await _readExternalCalendarFiles();
    final ocrRead = await _readOcrMaterialFiles(referencedOcrPaths);
    final scheduleRead = await _readScheduleForExport();
    final controller = settings;
    AppPreferences prefs;
    List<ProviderProfile> profiles;
    ModelSelection? selection;
    if (controller != null) {
      prefs = controller.prefs;
      profiles = controller.profiles;
      selection = controller.defaultSelection;
    } else {
      prefs = await settingsStore.loadPreferences();
      profiles = const <ProviderProfile>[];
    }
    final document = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'kind': backupKind,
      'exportedAt': DateTime.now().toIso8601String(),
      'appPrefs': prefs.toJson(),
      'index': index.map((s) => _scrub(s.toJson())).toList(growable: false),
      'conversations':
          conversations.map((c) => _scrub(c) as Map<String, dynamic>).toList(growable: false),
      // 外部日历：保存标准化后的来源/快照文件本身（base64），恢复后不依赖原 .ics。
      'externalCalendar': <String, dynamic>{
        'schemaVersion': externalCalendarSchemaVersion,
        'files': externalCalendarFiles,
      },
      // OCR 来源数据：保存会话引用到的页级来源/校对/引擎 JSON（base64 + 长度 +
      // SHA-256），不含原始页图、密钥或任意原路径文件。旧备份没有该键，读取兼容。
      'ocrMaterials': <String, dynamic>{
        'schemaVersion': ocrMaterialsSchemaVersion,
        'files': ocrRead.files,
      },
      // 全局日程：含重复/例外/删除标记/会话关联身份；不含提醒运行记录（提醒去重
      // 不跨目录，恢复后由新快照重建）。旧备份没有该键，读取兼容。
      if (scheduleRead.section != null) 'schedules': scheduleRead.section!,
      'settings': <String, dynamic>{
        'schemaVersion': SettingsSnapshot.profilesSchemaVersion,
        'defaultProfileId': selection?.profileId ?? '',
        'defaultModelId': selection?.modelId ?? '',
        'defaultThinking':
            (selection?.thinking ?? ThinkingMode.unsupported).wireName,
        'defaultReasoningEffort': selection?.reasoningEffort,
        'profiles': profiles
            .map((p) => _scrub(p.toJson()) as Map<String, dynamic>)
            .toList(growable: false),
        'note': 'API Key 保存在 Windows 凭据管理器，备份中不含密钥',
      },
      // 0.2.3（R3-E）：执行记录单独一段。不含活动计时检查点（恢复时不会自动继续计时），
      // 也不含任何材料原文/密钥；恢复按 recordId 幂等合并。
      'executionLedger': execution?.ledger.toJson(),
    };
    final payload = const JsonEncoder.withIndent('  ').convert(document);
    final target = File(path);
    if (target.parent.path.isNotEmpty) {
      await target.parent.create(recursive: true);
    }
    // The staging file must live on the same volume as the user-chosen target, so it is
    // written next to it (the cache directory may be on another drive). A leftover is
    // NOT treated as cache: cache cleanup only looks inside `<root>/cache`.
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Leftover next to the user's own backup file; never auto-deleted.
      }
      throw BackupException('写入备份文件失败：${_shortError(e)}');
    }
    final exportWarnings = <String>[
      if (ocrRead.missing.isNotEmpty)
        '${ocrRead.missing.length} 个 OCR 来源文件缺失，备份不含其详细来源',
      if (ocrRead.unsafe.isNotEmpty)
        '${ocrRead.unsafe.length} 个 OCR 来源文件是符号链接/联接点，已拒绝读取',
      if (scheduleRead.warning != null) scheduleRead.warning!,
    ];
    return BackupExportResult(
      path: target.path,
      conversationCount: conversations.length,
      profileCount: profiles.length,
      byteLength: utf8.encode(payload).length,
      ocrMaterialFileCount: ocrRead.files.length,
      missingOcrMaterialPaths: List<String>.unmodifiable(ocrRead.missing),
      unsafeOcrMaterialPaths: List<String>.unmodifiable(ocrRead.unsafe),
      scheduleEventCount: scheduleRead.eventCount,
      warning: exportWarnings.isEmpty ? null : exportWarnings.join('；'),
    );
  }

  // -------------------------------------------------------- external calendar

  /// 读取 `<root>/external_calendar/` 下的所有文件（相对路径 + base64 内容）。
  ///
  /// 只读取该目录内的普通文件；符号链接不跟随。读取失败时明确报错，绝不静默
  /// 导出一份缺了外部日历的“成功”备份。
  Future<List<Map<String, dynamic>>> _readExternalCalendarFiles() async {
    final dir = externalCalendarDirectory;
    final out = <Map<String, dynamic>>[];
    try {
      if (!await dir.exists()) return out;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = _relativeInside(dir, entity);
        if (relative == null) continue;
        out.add(<String, dynamic>{
          'path': relative,
          'content': base64Encode(await entity.readAsBytes()),
        });
      }
    } catch (e) {
      throw BackupException('读取外部日历数据失败：${_shortError(e)}');
    }
    out.sort(
        (a, b) => (a['path'] as String).compareTo(b['path'] as String));
    return out;
  }

  /// 计划外部日历恢复：只有在本地不存在同名文件（或内容相同）时才写入。
  ///
  /// 本地已有**不同内容**的外部日历文件时不覆盖（与“恢复不静默覆盖会话”同一
  /// 原则）：返回冲突列表，由调用方作为 warning 报告并保持本地数据不变。
  Future<_ExternalCalendarRestorePlan> _planExternalCalendarRestore(
      List<_ExternalCalendarBackupFile> files) async {
    if (files.isEmpty) return const _ExternalCalendarRestorePlan();
    final toWrite = <_ExternalCalendarBackupFile>[];
    final conflicts = <String>[];
    for (final file in files) {
      final target = _externalCalendarFile(file.relativePath);
      if (!await target.exists()) {
        toWrite.add(file);
        continue;
      }
      try {
        final existing = await target.readAsBytes();
        if (_sameBytes(existing, file.bytes)) continue;
        conflicts.add(file.relativePath);
      } catch (_) {
        conflicts.add(file.relativePath);
      }
    }
    if (conflicts.isNotEmpty) {
      return _ExternalCalendarRestorePlan(
        conflicts: List<String>.unmodifiable(conflicts),
        total: files.length,
      );
    }
    return _ExternalCalendarRestorePlan(
      toWrite: List<_ExternalCalendarBackupFile>.unmodifiable(toWrite),
      total: files.length,
    );
  }

  // ---------------------------------------------------------- ocr materials

  /// 会话实际引用的 OCR 来源文件路径（只接受 `ocr_materials/<id>.json` 白名单）。
  ///
  /// 旧数据、非 OCR 附件或没有 `provenance.materialFile` 的附件返回 null。
  static String? _ocrMaterialPathOf(Attachment attachment) {
    final provenance = attachment.provenance;
    if (provenance == null) return null;
    final raw = provenance['materialFile'];
    return raw is String ? _safeOcrMaterialPath(raw) : null;
  }

  /// 读取被会话引用的 OCR 来源文件（相对路径 + 长度 + SHA-256 + base64 内容）。
  ///
  /// 只读 `<root>/ocr_materials/` 里的普通文件：目录或文件本身是符号链接/联接点时
  /// 拒绝读取（不跟随到数据目录之外）。引用文件缺失时如实收集到 `missing`，
  /// 由导出结果报告——不静默导出一份“完整”备份。
  Future<
      ({
        List<Map<String, dynamic>> files,
        List<String> missing,
        List<String> unsafe,
      })> _readOcrMaterialFiles(Set<String> referenced) async {
    final files = <Map<String, dynamic>>[];
    final missing = <String>[];
    final unsafe = <String>[];
    if (referenced.isEmpty) {
      return (files: files, missing: missing, unsafe: unsafe);
    }
    final sorted = referenced.toList()..sort();
    if (await _isReparsePoint(ocrMaterialsDirectory.path)) {
      unsafe.addAll(sorted);
      return (files: files, missing: missing, unsafe: unsafe);
    }
    var totalBytes = 0;
    for (final relative in sorted) {
      final target = _ocrMaterialFile(relative);
      if (await _isReparsePoint(target.path)) {
        unsafe.add(relative);
        continue;
      }
      if (!await target.exists()) {
        missing.add(relative);
        continue;
      }
      List<int> bytes;
      try {
        bytes = await target.readAsBytes();
      } catch (e) {
        throw BackupException('读取 OCR 来源数据失败（$relative）：${_shortError(e)}');
      }
      if (bytes.length > maxOcrMaterialBytesLimit) {
        throw BackupException('OCR 来源数据过大（$relative，'
            '上限 ${formatByteCount(maxOcrMaterialBytesLimit)}），无法写入单文件备份');
      }
      totalBytes += bytes.length;
      if (totalBytes > maxOcrMaterialsTotalBytesLimit) {
        throw BackupException('OCR 来源数据总量过大'
            '（上限 ${formatByteCount(maxOcrMaterialsTotalBytesLimit)}），'
            '无法写入单文件备份');
      }
      // 损坏的来源文件不能被写进“可恢复”的备份：结构/JSON 校验失败直接报错。
      _validateOcrMaterialJson(relative, bytes);
      files.add(<String, dynamic>{
        'path': relative,
        'byteLength': bytes.length,
        'sha256': _sha256Hex(bytes),
        'content': base64Encode(bytes),
      });
    }
    return (files: files, missing: missing, unsafe: unsafe);
  }

  /// 计划 OCR 来源文件恢复：同路径同内容跳过（幂等），不同内容不覆盖，链接不跟随。
  ///
  /// 附件引用但备份与本地都没有的来源文件计入 [missingReferenceCount]：恢复后文字
  /// 仍然有效，但详细来源缺失，必须计数并提示（旧备份没有 OCR 段时就是这种情况）。
  Future<_OcrMaterialRestorePlan> _planOcrMaterialRestore(
      _ParsedBackup parsed) async {
    final files = parsed.ocrMaterialFiles;
    final toWrite = <_OcrMaterialBackupFile>[];
    final identical = <String>[];
    final conflicts = <String>[];
    final directoryIsLink =
        await _isReparsePoint(ocrMaterialsDirectory.path);
    for (final file in files) {
      final target = _ocrMaterialFile(file.relativePath);
      if (directoryIsLink || await _isReparsePoint(target.path)) {
        conflicts.add(file.relativePath);
        continue;
      }
      if (!await target.exists()) {
        toWrite.add(file);
        continue;
      }
      try {
        final existing = await target.readAsBytes();
        if (_sameBytes(existing, file.bytes)) {
          identical.add(file.relativePath);
          continue;
        }
      } catch (_) {
        // 读不出来的本地文件按冲突处理：不覆盖、不删除。
      }
      conflicts.add(file.relativePath);
    }

    final inBackup = files.map((file) => file.relativePath).toSet();
    var missingReferences = 0;
    for (final conversation in parsed.conversations) {
      for (final attachment in conversation.attachments) {
        final relative = _ocrMaterialPathOf(attachment);
        if (relative == null || inBackup.contains(relative)) continue;
        final target = _ocrMaterialFile(relative);
        if (directoryIsLink || await _isReparsePoint(target.path)) {
          missingReferences++;
          continue;
        }
        if (!await target.exists()) missingReferences++;
      }
    }
    return _OcrMaterialRestorePlan(
      toWrite: List<_OcrMaterialBackupFile>.unmodifiable(toWrite),
      identical: List<String>.unmodifiable(identical),
      conflicts: List<String>.unmodifiable(conflicts),
      total: files.length,
      directoryIsLink: directoryIsLink,
      missingReferenceCount: missingReferences,
    );
  }

  // ------------------------------------------------------------ schedules

  /// 导出全局日程快照（含删除标记）；不含提醒运行记录。
  ///
  /// 未启用日程服务（[scheduleStore] 为 null）→ 不写该段（返回 null section）。
  /// 日程服务尚未打开时先尝试打开；仍不可读则明确报错，绝不导出一份缺日程的
  /// “成功”备份。
  Future<
      ({
        int eventCount,
        Map<String, dynamic>? section,
        String? warning,
      })> _readScheduleForExport() async {
    final store = scheduleStore;
    if (store == null) {
      return (eventCount: 0, section: null, warning: null);
    }
    if (!store.opened) {
      try {
        await store.open();
      } catch (e) {
        throw BackupException('读取日程数据失败：${_shortError(e)}');
      }
    }
    if (!store.opened) {
      throw BackupException('日程数据尚未加载（${store.notice ?? '日程库未打开'}），'
          '已拒绝导出不完整备份');
    }
    final snapshot = store.snapshot;
    final events = snapshot.events.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    if (events.length > maxScheduleEventsLimit) {
      throw BackupException('日程记录过多（${events.length} 条，'
          '上限 $maxScheduleEventsLimit），已拒绝导出不完整备份');
    }
    final section = <String, dynamic>{
      'schemaVersion': scheduleSchemaVersion,
      'revision': snapshot.revision,
      'events': events.map((event) => event.toJson()).toList(growable: false),
    };
    final sectionBytes = utf8.encode(jsonEncode(section)).length;
    if (sectionBytes > maxScheduleSectionBytesLimit) {
      throw BackupException('日程数据过大（${formatByteCount(sectionBytes)}，'
          '上限 ${formatByteCount(maxScheduleSectionBytesLimit)}），'
          '已拒绝导出不完整备份');
    }
    return (
      eventCount: events.length,
      section: section,
      warning: store.isMemoryOnly
          ? '日程服务为内存模式，备份只包含当前内存中的日程，重启后可能丢失'
          : null,
    );
  }

  /// 计划合并备份里的全局日程。
  ///
  /// 规则：同 ID 同内容幂等跳过；同 ID 不同内容保留本地并计数；只把新增记录
  /// 写入合并快照，并按备份内会话映射重写关联、无匹配则解除。提醒运行记录不
  /// 随备份恢复（由提醒服务按新快照重建）。
  Future<_ScheduleRestorePlan> _planScheduleRestore(
      _ParsedBackup parsed, List<ConversationSummary> localIndex) async {
    final section = parsed.schedule;
    if (section == null) return const _ScheduleRestorePlan();
    final store = scheduleStore;
    if (store == null) {
      return _ScheduleRestorePlan(
        present: true,
        total: section.events.length,
        skipReason: '本次运行未启用日程服务',
      );
    }
    if (!store.opened) {
      try {
        await store.open();
      } catch (e) {
        return _ScheduleRestorePlan(
          present: true,
          total: section.events.length,
          skipReason: '日程服务无法打开（${_shortError(e)}）',
        );
      }
    }
    if (!store.opened) {
      return _ScheduleRestorePlan(
        present: true,
        total: section.events.length,
        skipReason: '日程数据未加载（${store.notice ?? '日程库未打开'}）',
      );
    }
    if (store.readOnly) {
      return _ScheduleRestorePlan(
        present: true,
        total: section.events.length,
        skipReason: '日程处于只读状态（${store.notice ?? '另一个实例正在使用该数据目录'}）',
      );
    }
    if (!_sameAbsolutePath(store.eventsFile.path, scheduleEventsFile.path)) {
      return _ScheduleRestorePlan(
        present: true,
        total: section.events.length,
        skipReason: '日程服务的数据目录与恢复目标不一致',
      );
    }

    final local = store.snapshot;
    // 当前恢复不重命名会话 ID，因此映射是恒等的；保留这层映射，未来若加入会话
    // ID 重命名，只需在这里给出真实映射即可同步日程关联。
    final conversationIdMap = <String, String>{
      for (final conversation in parsed.conversations)
        conversation.id: conversation.id,
    };
    final validConversationIds = <String>{
      ...conversationIdMap.values,
      ...localIndex.map((summary) => summary.id),
    };

    final merged = Map<String, ScheduleEvent>.from(local.events);
    final conflicts = <String>[];
    final unlinked = <String>[];
    var added = 0;
    var skipped = 0;
    for (final incoming in section.events) {
      final existing = local.events[incoming.id];
      if (existing != null) {
        if (_canonicalJson(existing.toJson()) ==
            _canonicalJson(incoming.toJson())) {
          skipped++;
        } else {
          conflicts.add(incoming.id);
        }
        continue;
      }
      var event = incoming;
      final linked = incoming.linkedConversationId;
      if (linked != null && linked.isNotEmpty) {
        final mapped = conversationIdMap[linked] ??
            (validConversationIds.contains(linked) ? linked : null);
        if (mapped == null) {
          event = _withLinkedConversation(incoming, null);
          unlinked.add(incoming.id);
        } else if (mapped != linked) {
          event = _withLinkedConversation(incoming, mapped);
        }
      }
      merged[incoming.id] = event;
      added++;
    }

    if (added == 0) {
      return _ScheduleRestorePlan(
        present: true,
        total: section.events.length,
        skipped: skipped,
        conflicts: List<String>.unmodifiable(conflicts),
        unlinkedEventIds: List<String>.unmodifiable(unlinked),
      );
    }
    final localRevision = local.revision;
    final revision =
        (localRevision > section.revision ? localRevision : section.revision) + 1;
    return _ScheduleRestorePlan(
      present: true,
      total: section.events.length,
      restored: added,
      skipped: skipped,
      conflicts: List<String>.unmodifiable(conflicts),
      unlinkedEventIds: List<String>.unmodifiable(unlinked),
      merged: ScheduleSnapshot(
        revision: revision,
        events: Map<String, ScheduleEvent>.unmodifiable(merged),
      ),
    );
  }

  /// 复制一条日程并替换其会话关联（模型是不可变值，没有通用的关联 copyWith）。
  static ScheduleEvent _withLinkedConversation(
    ScheduleEvent event,
    String? linkedConversationId,
  ) =>
      ScheduleEvent(
        id: event.id,
        revision: event.revision,
        title: event.title,
        location: event.location,
        notes: event.notes,
        category: event.category,
        timezoneId: event.timezoneId,
        allDay: event.allDay,
        startDate: event.startDate,
        startMinute: event.startMinute,
        endMinute: event.endMinute,
        endDateExclusive: event.endDateExclusive,
        blocksScheduling: event.blocksScheduling,
        linkedConversationId: linkedConversationId,
        repeat: event.repeat,
        reminder: event.reminder,
        exceptions: event.exceptions,
        createdAtUtc: event.createdAtUtc,
        updatedAtUtc: event.updatedAtUtc,
        deletedAtUtc: event.deletedAtUtc,
      );

  /// Windows 盘符不区分大小写；比较日程服务文件与恢复目标是否同一路径。
  static bool _sameAbsolutePath(String a, String b) {
    String normalize(String path) {
      final absolute =
          File(path).absolute.path.replaceAll(Platform.pathSeparator, '/');
      return Platform.isWindows ? absolute.toLowerCase() : absolute;
    }

    return normalize(a) == normalize(b);
  }

  // -------------------------------------------------------------- restore

  /// Validates [path], then stages and commits its contents.
  ///
  /// Refused before any write (readable error, no file modified):
  ///   * [isBusy] reports an analysis in flight;
  ///   * the settings controller has unsaved edits ([SettingsController.dirty]);
  ///   * an existing conversation with the same id has **different** content (the whole
  ///     import is rejected so nothing can be silently overwritten; identical content is
  ///     skipped and counts as already restored).
  ///
  /// Existing conversations that are not part of the backup are kept (and stay listed in
  /// the merged index), so a restore can never silently delete history.
  Future<BackupRestoreResult> restoreBackup(String path) =>
      _serialize(() => _restoreBackup(path));

  Future<BackupRestoreResult> _restoreBackup(String path) async {
    // ---- preconditions: nothing below this block touches the file system ----
    if (isBusy?.call() ?? false) {
      return const BackupRestoreResult(
        ok: false,
        error: '正在分析中，无法恢复：请等待当前分析结束或取消后再恢复',
      );
    }
    final controller = settings;
    if (controller != null && controller.dirty) {
      return const BackupRestoreResult(
        ok: false,
        error: '请先保存或放弃设置修改再恢复（设置窗口有未保存的修改）',
      );
    }

    final file = File(path);
    _ParsedBackup parsed;
    try {
      if (!await file.exists()) {
        return const BackupRestoreResult(
            ok: false, error: '备份文件不存在，请重新选择');
      }
      final length = await file.length();
      if (length == 0) {
        return const BackupRestoreResult(ok: false, error: '备份文件是空的');
      }
      if (length > maxImportBytesLimit) {
        return BackupRestoreResult(
          ok: false,
          error: '备份文件过大（${formatByteCount(length)}，'
              '上限 ${formatByteCount(maxImportBytesLimit)}），已拒绝导入',
        );
      }
      parsed = _parse(await file.readAsString());
    } on BackupException catch (e) {
      return BackupRestoreResult(ok: false, error: e.message);
    } catch (e) {
      return BackupRestoreResult(
          ok: false, error: '读取备份文件失败：${_shortError(e)}');
    }

    // ---- cross-process guard + staging/commit ------------------------------
    final acquired = await _acquireCacheLock();
    final lock = acquired.lock;
    if (lock == null) {
      return BackupRestoreResult(
        ok: false,
        error: '无法开始恢复：${acquired.reason ?? '应用缓存目录被占用'}；未修改任何数据',
      );
    }
    try {
      return await _commitRestore(parsed);
    } finally {
      await lock.release();
    }
  }

  Future<BackupRestoreResult> _commitRestore(_ParsedBackup parsed) async {
    // ---- conflict detection (read-only) --------------------------------
    final conflicting = <String>[];
    final identicalIds = <String>{};
    for (final conversation in parsed.conversations) {
      final target = _conversationFile(conversation.id);
      if (!await target.exists()) continue;
      final local = await store.loadConversation(conversation.id);
      if (local != null && _sameConversation(local, conversation)) {
        identicalIds.add(conversation.id);
      } else {
        conflicting.add(conversation.id);
      }
    }
    if (conflicting.isNotEmpty) {
      final shown = conflicting.take(3).join('、');
      final rest = conflicting.length > 3
          ? ' 等共 ${conflicting.length} 个'
          : '';
      return BackupRestoreResult(
        ok: false,
        error: '备份中的会话与本地同 ID 会话内容不同：$shown$rest。'
            '为避免覆盖，未恢复任何数据',
        conflictConversationIds: List<String>.unmodifiable(conflicting),
      );
    }

    final toWrite = parsed.conversations
        .where((c) => !identicalIds.contains(c.id))
        .toList(growable: false);
    final localIndex = await store.loadIndex();
    final externalPlan =
        await _planExternalCalendarRestore(parsed.externalCalendarFiles);
    final ocrPlan = await _planOcrMaterialRestore(parsed);
    final schedulePlan = await _planScheduleRestore(parsed, localIndex);
    final mergedIndex = <ConversationSummary>[
      ...parsed.index,
      ...localIndex.where((s) => !parsed.index.any((r) => r.id == s.id)),
    ];
    final indexChanged = !_sameSummaryList(localIndex, mergedIndex);
    final prefsToWrite = await _shouldWritePreferences(parsed.prefs);

    // ---- stage: everything goes to <root>/cache/restore/ ---------------
    final staged = <_StagedFile>[];
    try {
      await store.ensureLayout();
      await _resetRestoreStaging();
      await restoreStagingDirectory.create(recursive: true);
      for (final conversation in toWrite) {
        final tmp =
            _stagedFile('tsc-restore-conversation-${conversation.id}.json');
        await tmp.writeAsString(
            const JsonEncoder.withIndent('  ').convert(conversation.toJson()),
            flush: true);
        staged.add(_StagedFile(
            tmp: tmp, target: _conversationFile(conversation.id)));
      }
      for (var i = 0; i < externalPlan.toWrite.length; i++) {
        final external = externalPlan.toWrite[i];
        final tmp = _stagedFile('tsc-restore-external-$i.bin');
        await tmp.writeAsBytes(external.bytes, flush: true);
        staged.add(_StagedFile(
          tmp: tmp,
          target: _externalCalendarFile(external.relativePath),
        ));
      }
      // OCR 来源文件与其余恢复文件走同一套暂存/提交/回滚：任一步磁盘失败都不会
      // 留下“会话已恢复、来源文件却被覆盖/未落盘”的混合状态。
      for (var i = 0; i < ocrPlan.toWrite.length; i++) {
        final ocr = ocrPlan.toWrite[i];
        final tmp = _stagedFile('tsc-restore-ocr-$i.json');
        await tmp.writeAsBytes(ocr.bytes, flush: true);
        staged.add(_StagedFile(
          tmp: tmp,
          target: _ocrMaterialFile(ocr.relativePath),
        ));
      }
      // 全局日程与其余数据同一暂存/提交/回滚边界：写失败会整体回滚，不会留下
      // “会话/偏好已恢复、日程却是半份”的状态。
      final mergedSchedule = schedulePlan.merged;
      if (mergedSchedule != null) {
        final scheduleTmp = _stagedFile('tsc-restore-schedules.json');
        await scheduleTmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(mergedSchedule.toJson()),
          flush: true,
        );
        await scheduleEventsFile.parent.create(recursive: true);
        staged.add(_StagedFile(
          tmp: scheduleTmp,
          target: scheduleEventsFile,
        ));
      }
      if (indexChanged) {
        final indexTmp = _stagedFile('tsc-restore-index.json');
        await indexTmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
            'schemaVersion': 1,
            'conversations':
                mergedIndex.map((s) => s.toJson()).toList(growable: false),
          }),
          flush: true,
        );
        await _indexFile.parent.create(recursive: true);
        staged.add(_StagedFile(tmp: indexTmp, target: _indexFile));
      }
      final prefs = parsed.prefs;
      if (prefs != null && prefsToWrite) {
        final prefsTmp = _stagedFile('tsc-restore-app-prefs.json');
        await prefsTmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
            'schemaVersion': SettingsStore.schemaVersion,
            'savedAt': DateTime.now().toIso8601String(),
            'prefs': prefs.toJson(),
          }),
          flush: true,
        );
        await _prefsFile.parent.create(recursive: true);
        staged.add(_StagedFile(tmp: prefsTmp, target: _prefsFile));
      }
    } catch (e) {
      await _discardStaged(staged);
      return BackupRestoreResult(
        ok: false,
        error: '恢复准备失败，原有数据未改动：${_shortError(e)}',
      );
    }

    // ---- commit: previous file to .bak, then promote the staged file ----
    final committed = <_CommitEntry>[];
    try {
      for (final item in staged) {
        File? backup;
        await item.target.parent.create(recursive: true);
        if (await item.target.exists()) {
          backup = File('${item.target.path}.bak');
          if (await backup.exists()) await backup.delete();
          await item.target.rename(backup.path);
          // Record the moved-aside file *before* the promotion: if the promotion fails,
          // the rollback still has to put this copy back.
          committed.add(_CommitEntry(item.target, backup));
        }
        await item.tmp.rename(item.target.path);
        if (backup == null) {
          committed.add(_CommitEntry(item.target, null)..promoted = true);
        } else {
          committed.last.promoted = true;
        }
      }
    } catch (e) {
      final rollback = await _rollback(committed);
      await _discardStaged(staged);
      final names = rollback.restored.map(_basenameOf).toList(growable: false);
      final failed = rollback.failed.map(_basenameOf).toList(growable: false);
      final detail = rollback.restored.isEmpty && rollback.failed.isEmpty
          ? '没有文件被替换，原有数据未改动'
          : (rollback.failed.isEmpty
              ? '已回滚 ${rollback.restored.length} 个文件（${names.join('、')}），原有数据已恢复'
              : '已回滚 ${rollback.restored.length} 个文件，'
                  '但 ${rollback.failed.length} 个文件未能恢复（${failed.join('、')}）；'
                  '请从 .bak 或备份文件人工恢复，不要继续覆盖');
      return BackupRestoreResult(
        ok: false,
        error: '恢复提交失败：${_shortError(e)}；$detail',
        rolledBackPaths: rollback.restored,
        rollbackFailedPaths: rollback.failed,
        commitAttempted: true,
      );
    }

    // ---- post-commit: make the live application see the restored data ---
    final warnings = <String>[];
    var prefsReloaded = false;
    final controller = settings;
    if (parsed.prefs != null && prefsToWrite) {
      if (controller != null) {
        // `load()` is defensive and never throws; it also rebuilds the draft baseline.
        await controller.load();
        prefsReloaded = true;
      } else {
        warnings.add('应用偏好已写入，但本次运行没有可用的设置控制器，重启后生效');
      }
    }

    // Model connections are restored through the settings controller (revision rules are
    // owned by the native layer). A failure here is reported, never hidden: sessions are
    // already safe, but the user must know the connections were not recreated.
    var restoredProfiles = 0;
    if (parsed.profiles.isNotEmpty) {
      final outcome = await _restoreConnections(parsed);
      restoredProfiles = outcome.count;
      final warning = outcome.warning;
      if (warning != null) warnings.add(warning);
    }

    // The in-memory conversation cache is only refreshed when the caller supplied a
    // callback; otherwise the result says a restart is required.
    var sessionsReloaded = false;
    if (parsed.conversations.isNotEmpty) {
      final reload = reloadSessions;
      if (reload != null) {
        try {
          await reload();
          sessionsReloaded = true;
        } catch (e) {
          warnings.add('会话数据已恢复，但刷新会话列表失败：${_shortError(e)}');
        }
      }
    }

    // 外部日历文件已经写入磁盘；让内存里的服务重新加载，否则界面仍旧是旧来源。
    var restoredExternalFiles = 0;
    if (externalPlan.conflicts.isNotEmpty) {
      warnings.add('本地已有不同的外部日历数据（${externalPlan.conflicts.length} 个文件），'
          '为避免覆盖未恢复；如需替换请先导出/删除本地外部日历');
    } else if (externalPlan.toWrite.isNotEmpty) {
      restoredExternalFiles = externalPlan.toWrite.length;
      final reload = reloadExternalCalendar;
      if (reload != null) {
        try {
          await reload();
        } catch (e) {
          warnings.add('外部日历已恢复，但重新加载失败：${_shortError(e)}');
        }
      } else {
        warnings.add('外部日历数据已恢复，重启后生效');
      }
    }

    // OCR 来源文件：冲突/链接不覆盖（本地数据优先），缺失引用与部分恢复都要计数并
    // 明确提示，不能让用户以为详细来源已经完整恢复。
    if (ocrPlan.directoryIsLink && ocrPlan.conflicts.isNotEmpty) {
      warnings.add('本地 ocr_materials 目录是符号链接/联接点，已跳过 ${ocrPlan.conflicts.length} 个 OCR 来源文件（避免写到数据目录之外）');
    } else if (ocrPlan.conflicts.isNotEmpty) {
      warnings.add('本地已有不同的 OCR 来源数据（${ocrPlan.conflicts.length} 个文件），'
          '为避免覆盖未恢复；如需替换请先导出/删除本地 OCR 来源数据');
    }
    if (ocrPlan.missingReferenceCount > 0) {
      warnings.add('${ocrPlan.missingReferenceCount} 个 OCR 附件的详细来源文件不在备份中，'
          '文字已恢复但详细来源缺失');
    }
    final restoredOcrFiles = ocrPlan.toWrite.length;

    // 全局日程：提醒运行记录不随备份恢复（提醒服务按新快照重建）；冲突保留本地，
    // 关联无匹配则解除，全部计数并提示。
    final scheduleNotices = <String>[];
    var scheduleReloaded = false;
    if (schedulePlan.skipReason != null) {
      final notice = '备份包含日程，但未恢复：${schedulePlan.skipReason}';
      scheduleNotices.add(notice);
      warnings.add(notice);
    }
    if (schedulePlan.conflicts.isNotEmpty) {
      final notice = '本地已有不同的日程（${schedulePlan.conflicts.length} 条同 ID），'
          '为避免覆盖保留本地';
      scheduleNotices.add(notice);
      warnings.add(notice);
    }
    if (schedulePlan.unlinkedEventIds.isNotEmpty) {
      final notice = '${schedulePlan.unlinkedEventIds.length} 条恢复的日程关联会话'
          '在本地不存在，已解除关联';
      scheduleNotices.add(notice);
      warnings.add(notice);
    }
    if (schedulePlan.merged != null) {
      final reload = reloadSchedule;
      if (reload != null) {
        try {
          await reload();
          scheduleReloaded = true;
        } catch (e) {
          final notice = '日程已恢复，但刷新日程服务失败：${_shortError(e)}';
          scheduleNotices.add(notice);
          warnings.add(notice);
        }
      } else {
        final schedule = scheduleStore;
        if (schedule != null) {
          try {
            await schedule.reload();
          } catch (e) {
            final notice = '日程已恢复，但重新读取日程失败：${_shortError(e)}';
            scheduleNotices.add(notice);
            warnings.add(notice);
          }
        }
        final notice = '日程数据已恢复，但未提供日程刷新回调，'
            '界面需重启或重新打开日程列表后才一致';
        scheduleNotices.add(notice);
        warnings.add(notice);
      }
    }

    final requiresRestart = (parsed.conversations.isNotEmpty && !sessionsReloaded) ||
        ((parsed.prefs != null && prefsToWrite) && !prefsReloaded) ||
        (externalPlan.toWrite.isNotEmpty && reloadExternalCalendar == null) ||
        (schedulePlan.merged != null && !scheduleReloaded);

    // 0.2.3（R3-E）：合并执行记录。按 recordId 幂等去重，重复恢复不重复累计；
    // 已存在的本地记录一律保留（不覆盖）。合并失败只作为 warning，不影响会话恢复。
    var restoredExecutionRecords = 0;
    final importedLedger = parsed.executionLedger;
    if (importedLedger != null) {
      final executionStore = execution;
      if (executionStore == null) {
        warnings.add('备份包含执行记录，但本次运行未启用执行计时，未合并执行记录');
      } else {
        try {
          final merge = await executionStore.mergeRestored(importedLedger);
          restoredExecutionRecords = merge.addedRecords;
        } on ExecutionReadOnlyException catch (e) {
          warnings.add('执行记录未合并：${e.message}');
        } catch (e) {
          warnings.add('执行记录合并失败：${_shortError(e)}');
        }
      }
    }

    return BackupRestoreResult(
      ok: true,
      warning: warnings.isEmpty ? null : warnings.join('；'),
      conversationCount: parsed.conversations.length,
      restoredConversationCount: toWrite.length,
      skippedConversationCount: identicalIds.length,
      restoredPrefs: parsed.prefs != null && prefsToWrite,
      prefsReloaded: prefsReloaded,
      profileCount: parsed.profiles.length,
      restoredProfileCount: restoredProfiles,
      externalCalendarFileCount: parsed.externalCalendarFiles.length,
      restoredExternalCalendarFileCount: restoredExternalFiles,
      executionRecordCount: importedLedger?.records.length ?? 0,
      restoredExecutionRecordCount: restoredExecutionRecords,
      ocrMaterialFileCount: parsed.ocrMaterialFiles.length,
      restoredOcrMaterialFileCount: restoredOcrFiles,
      skippedOcrMaterialFileCount: ocrPlan.identical.length,
      conflictOcrMaterialPaths:
          List<String>.unmodifiable(ocrPlan.conflicts),
      missingOcrMaterialReferenceCount: ocrPlan.missingReferenceCount,
      scheduleSectionPresent: parsed.schedule != null,
      scheduleEventCount: parsed.schedule?.events.length ?? 0,
      restoredScheduleEventCount: schedulePlan.restored,
      skippedScheduleEventCount: schedulePlan.skipped,
      conflictScheduleEventIds:
          List<String>.unmodifiable(schedulePlan.conflicts),
      unlinkedScheduleEventIds:
          List<String>.unmodifiable(schedulePlan.unlinkedEventIds),
      scheduleNotices: List<String>.unmodifiable(scheduleNotices),
      scheduleReloaded: scheduleReloaded,
      backupPaths: committed
          .where((c) => c.promoted && c.backup != null)
          .map((c) => c.backup!.path)
          .toList(growable: false),
      sessionsReloaded: sessionsReloaded,
      requiresRestart: requiresRestart,
    );
  }

  /// Re-creates the backed-up model connections through the settings controller.
  ///
  /// Rules:
  ///   * the caller already rejected a dirty settings draft, so the user's work is safe;
  ///   * a connection that does not exist locally is handed over with revision 0 (the
  ///     native layer turns that into 1); an id that already exists keeps its stored
  ///     revision so the restore is not rejected as a conflict;
  ///   * connections and the default selection are committed by **one**
  ///     [SettingsController.restoreProfiles] call, because the controller requires a
  ///     draft with connections to name a default connection;
  ///   * `credentialConfigured` is reset there too: keys live in Windows Credential
  ///     Manager and are deliberately absent from every backup, so they have to be typed
  ///     again;
  ///   * a backup without a usable default falls back to the first restored connection
  ///     (some default has to exist), and the model id stays the connection's own;
  ///   * every failure is reported as a readable warning instead of being swallowed.
  Future<({int count, String? warning})> _restoreConnections(
      _ParsedBackup parsed) async {
    final controller = settings;
    if (controller == null) {
      return (count: 0, warning: '模型连接未恢复（本次运行没有可用的设置控制器）');
    }
    controller.discard();
    final incoming = parsed.profiles.map((profile) {
      final existing = controller.profileById(profile.id);
      return profile.copyWith(revision: existing?.revision ?? 0);
    }).toList(growable: false);
    ProviderProfile? defaultProfile;
    for (final profile in incoming) {
      if (profile.id == parsed.defaultProfileId) {
        defaultProfile = profile;
        break;
      }
    }
    defaultProfile ??= incoming.isEmpty ? null : incoming.first;
    ModelSelection? defaultSelection;
    if (defaultProfile != null) {
      defaultSelection = ModelSelection(
        profileId: defaultProfile.id,
        // 0 for a brand-new connection: `restoreProfiles` raises it to the revision the
        // connection will have after the save (1).
        profileRevision: defaultProfile.revision,
        modelId: parsed.defaultModelId.isEmpty
            ? defaultProfile.modelId
            : parsed.defaultModelId,
        thinking: defaultProfile.effectiveThinking,
        reasoningEffort: defaultProfile.effectiveReasoningEffort,
      );
    }
    final saveError = await controller.restoreProfiles(
      incoming,
      defaultSelection: defaultSelection,
    );
    if (saveError != null) {
      controller.discard();
      return (count: 0, warning: '模型连接未恢复（$saveError）');
    }
    final count =
        incoming.where((p) => controller.profileById(p.id) != null).length;
    return (count: count, warning: null);
  }

  // -------------------------------------------------------------- cache
  //
  // The app owns exactly one cache directory: `<root>/cache`. Only files this program
  // named with [cacheFilePrefix] are considered cache. The `restore/` subtree is staging
  // for an in-flight restore and is never scanned or deleted.

  /// Lists the files [clearCache] would delete, using the very same scan.
  Future<CachePreview> scanCache() => _serialize(_scanCacheEntries);

  /// Deletes the app-owned cache files listed by [scanCache].
  ///
  /// Returns a result that carries the skip reason when the cleanup could not run (cache
  /// directory or lock unavailable) — it never reports a silent success.
  Future<CacheClearResult> clearCache() => _serialize(_clearCache);

  Future<CachePreview> _scanCacheEntries() async {
    final dir = cacheDirectory;
    if (!await dir.exists()) {
      return CachePreview(directory: dir.path);
    }
    final entries = <CachePreviewEntry>[];
    String? skipped;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        // Directories (including `restore/`) are never treated as cache entries.
        if (entity is! File) continue;
        final name = _basenameOf(entity.path);
        if (!_isOwnedCacheFile(name)) continue;
        try {
          entries.add(
              CachePreviewEntry(name: name, bytes: await entity.length()));
        } catch (_) {
          // The file vanished between listing and sizing: ignore it.
        }
      }
    } catch (e) {
      skipped = _shortError(e);
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return CachePreview(
      entries: List<CachePreviewEntry>.unmodifiable(entries),
      directory: dir.path,
      skippedReason: skipped,
    );
  }

  Future<CacheClearResult> _clearCache() async {
    final acquired = await _acquireCacheLock();
    final lock = acquired.lock;
    if (lock == null) {
      return CacheClearResult(
        deletedFiles: 0,
        bytes: 0,
        skippedReason: acquired.reason ?? '应用缓存目录被占用',
      );
    }
    try {
      final preview = await _scanCacheEntries();
      if (preview.skippedReason != null) {
        return CacheClearResult(
          deletedFiles: 0,
          bytes: 0,
          skippedReason: preview.skippedReason,
        );
      }
      var deleted = 0;
      var bytes = 0;
      final names = <String>[];
      final failed = <String>[];
      for (final entry in preview.entries) {
        final file =
            File('${cacheDirectory.path}${Platform.pathSeparator}${entry.name}');
        try {
          final length = await file.length();
          await file.delete();
          deleted++;
          bytes += length;
          names.add(entry.name);
        } catch (_) {
          // Locked by another process: report it instead of failing the whole run.
          failed.add(entry.name);
        }
      }
      return CacheClearResult(
        deletedFiles: deleted,
        bytes: bytes,
        paths: List<String>.unmodifiable(names),
        failedPaths: List<String>.unmodifiable(failed),
      );
    } finally {
      await lock.release();
    }
  }

  /// True only for files written by this program into its own cache directory.
  static bool _isOwnedCacheFile(String name) =>
      name.startsWith(cacheFilePrefix) && name != cacheLockFileName;

  /// Removes leftovers of a previous (crashed) restore. Only ever called while holding
  /// the cache lock, and never touches anything outside `cache/restore/`.
  Future<void> _resetRestoreStaging() async {
    final dir = restoreStagingDirectory;
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // Best effort; the staged file is rewritten before the commit.
        }
      }
    } catch (_) {
      // An unreadable staging directory is recreated when the files are written.
    }
  }

  /// Total size of the data directory (recursive, symlinks not followed).
  Future<DirectoryUsage> directorySize() async {
    var bytes = 0;
    var files = 0;
    try {
      if (!await root.exists()) {
        return const DirectoryUsage(bytes: 0, files: 0);
      }
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          bytes += await entity.length();
          files++;
        } catch (_) {
          // A file may disappear while scanning; ignore it.
        }
      }
    } catch (_) {
      // An unreadable folder must not break the storage page.
    }
    return DirectoryUsage(bytes: bytes, files: files);
  }

  // ------------------------------------------------------- mutual exclusion

  /// One in-process queue for restore + cache cleanup, so a cleanup can never observe a
  /// half-staged restore (and vice versa). Static on purpose: several [BackupService]
  /// instances in the same process must not overlap either.
  static Future<void> _queueTail = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _queueTail;
    final done = Completer<void>();
    _queueTail = done.future;
    try {
      await previous;
    } catch (_) {
      // A previous operation failed; the queue must continue.
    }
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  /// Best-effort exclusive lock on `<root>/cache/.lock` for cross-process exclusion.
  ///
  /// The file is created when missing and **never deleted** (deleting it would break the
  /// lock for every other instance). When the lock cannot be taken the caller must skip
  /// its operation and say so, instead of cleaning while another instance is restoring.
  Future<({_CacheLock? lock, String? reason})> _acquireCacheLock() async {
    try {
      final dir = cacheDirectory;
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e) {
      return (lock: null, reason: '应用缓存目录不可写（${_shortError(e)}）');
    }
    RandomAccessFile handle;
    try {
      handle = await cacheLockFile.open(mode: FileMode.append);
    } catch (e) {
      return (lock: null, reason: '无法打开缓存锁文件（${_shortError(e)}）');
    }
    try {
      await handle
          .lock(FileLock.exclusive)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      try {
        await handle.close();
      } catch (_) {
        // Ignore: the lock was never taken.
      }
      return (
        lock: null,
        reason: '缓存目录正被另一个程序实例使用（锁不可用：${_shortError(e)}）',
      );
    }
    return (lock: _CacheLock(handle), reason: null);
  }

  // ----------------------------------------------------------- validation

  _ParsedBackup _parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw BackupException('备份文件不是有效的 JSON，已拒绝导入');
    }
    if (decoded is! Map<String, dynamic>) {
      throw BackupException('备份文件结构不正确（顶层必须是对象），已拒绝导入');
    }
    final version = (decoded['schemaVersion'] as num?)?.toInt() ?? 0;
    if (version != schemaVersion) {
      throw BackupException('备份版本不受支持（schemaVersion=$version，'
          '本程序支持 $schemaVersion），已拒绝导入');
    }
    final kind = (decoded['kind'] as String?)?.trim() ?? '';
    if (kind.isNotEmpty && kind != backupKind) {
      throw BackupException('这不是 TaskScheduler 的备份文件（kind=$kind）');
    }

    final rawConversations = decoded['conversations'];
    if (rawConversations is! List) {
      throw BackupException('备份文件缺少会话列表，已拒绝导入');
    }
    final conversations = <Conversation>[];
    final ids = <String>{};
    for (var i = 0; i < rawConversations.length; i++) {
      final raw = rawConversations[i];
      if (raw is! Map<String, dynamic>) {
        throw BackupException('第 ${i + 1} 个会话结构不正确，已拒绝导入');
      }
      final id = (raw['id'] as String?)?.trim() ?? '';
      if (!_idPattern.hasMatch(id)) {
        throw BackupException('第 ${i + 1} 个会话的 ID 不合法，已拒绝导入');
      }
      if (!ids.add(id)) {
        throw BackupException('备份中存在重复的会话 ID：$id');
      }
      final versionIds = <String>{};
      for (final rawVersion in (raw['versions'] as List<dynamic>?) ?? const []) {
        if (rawVersion is! Map<String, dynamic>) {
          throw BackupException('会话 $id 中存在结构不正确的版本，已拒绝导入');
        }
        final versionId = (rawVersion['id'] as String?)?.trim() ?? '';
        if (!_idPattern.hasMatch(versionId)) {
          throw BackupException('会话 $id 中存在不合法的版本 ID，已拒绝导入');
        }
        if (!versionIds.add(versionId)) {
          throw BackupException('会话 $id 中存在重复的版本 ID：$versionId');
        }
      }
      try {
        final conversation = Conversation.fromJson(raw);
        if (conversation.id.isEmpty) {
          throw BackupException('会话 $id 解析后 ID 为空');
        }
        conversations.add(conversation);
      } on BackupException {
        rethrow;
      } catch (e) {
        throw BackupException('会话 $id 的数据无法解析：${_shortError(e)}');
      }
    }

    // The index is optional; when present it must not point at unknown conversations.
    final rawIndex = decoded['index'];
    final index = <ConversationSummary>[];
    if (rawIndex != null && rawIndex is! List) {
      throw BackupException('备份文件的索引结构不正确，已拒绝导入');
    }
    for (final raw in (rawIndex as List<dynamic>?) ?? const []) {
      if (raw is! Map<String, dynamic>) {
        throw BackupException('备份文件的索引条目结构不正确，已拒绝导入');
      }
      final id = (raw['id'] as String?)?.trim() ?? '';
      if (!_idPattern.hasMatch(id)) {
        throw BackupException('备份文件的索引中存在不合法的会话 ID，已拒绝导入');
      }
      if (!ids.contains(id)) {
        throw BackupException('备份文件的索引引用了不存在的会话：$id');
      }
      index.add(ConversationSummary.fromJson(raw));
    }
    if (index.isEmpty) {
      index.addAll(conversations.map(ConversationSummary.of));
    }

    final rawPrefs = decoded['appPrefs'];
    final prefs = rawPrefs is Map<String, dynamic>
        ? AppPreferences.fromJson(rawPrefs)
        : null;

    final profiles = <ProviderProfile>[];
    final rawSettings = decoded['settings'];
    var defaultProfileId = '';
    var defaultModelId = '';
    if (rawSettings != null && rawSettings is! Map<String, dynamic>) {
      throw BackupException('备份文件的模型设置结构不正确，已拒绝导入');
    }
    if (rawSettings is Map<String, dynamic>) {
      final rawProfiles = rawSettings['profiles'];
      if (rawProfiles != null && rawProfiles is! List) {
        throw BackupException('备份文件的连接列表结构不正确，已拒绝导入');
      }
      final profileIds = <String>{};
      for (final raw in (rawProfiles as List<dynamic>?) ?? const []) {
        if (raw is! Map<String, dynamic>) {
          throw BackupException('备份文件中存在结构不正确的连接，已拒绝导入');
        }
        final profile = ProviderProfile.fromJson(raw);
        if (!_idPattern.hasMatch(profile.id)) {
          throw BackupException('备份文件中存在不合法的连接 ID，已拒绝导入');
        }
        if (!profileIds.add(profile.id)) {
          throw BackupException('备份文件中存在重复的连接 ID：${profile.id}');
        }
        if (profile.firstError != null) {
          throw BackupException(
              '连接「${profile.name.isEmpty ? profile.id : profile.name}」'
              '配置不完整：${profile.firstError}');
        }
        profiles.add(profile);
      }
      defaultProfileId =
          (rawSettings['defaultProfileId'] as String?)?.trim() ?? '';
      defaultModelId = (rawSettings['defaultModelId'] as String?)?.trim() ?? '';
      if (defaultProfileId.isNotEmpty && !profileIds.contains(defaultProfileId)) {
        throw BackupException('备份文件中的默认连接不存在：$defaultProfileId');
      }
    }

    return _ParsedBackup(
      conversations: conversations,
      index: index,
      prefs: prefs,
      profiles: profiles,
      defaultProfileId: defaultProfileId,
      defaultModelId: defaultModelId,
      externalCalendarFiles:
          _parseExternalCalendarFiles(decoded['externalCalendar']),
      ocrMaterialFiles: _parseOcrMaterialFiles(decoded['ocrMaterials']),
      schedule: _parseSchedule(decoded['schedules']),
      executionLedger: _parseExecutionLedger(decoded['executionLedger']),
    );
  }

  /// 解析备份里的 OCR 来源数据段；旧备份没有该键 → 空列表（不恢复来源文件）。
  ///
  /// 逐项校验：路径白名单（`ocr_materials/<id>.json`）、长度、SHA-256、UTF-8 JSON
  /// 结构；解码前先按 base64 长度估算总量，避免先解出巨量内存再拒绝。任何一项不符
  /// 都整份拒绝导入（不留下“会话恢复、来源损坏”的混合状态）。
  List<_OcrMaterialBackupFile> _parseOcrMaterialFiles(Object? raw) {
    if (raw == null) return const <_OcrMaterialBackupFile>[];
    if (raw is! Map) {
      throw BackupException('备份文件的 OCR 来源数据结构不正确，已拒绝导入');
    }
    final j = Map<String, dynamic>.from(raw);
    final version = (j['schemaVersion'] as num?)?.toInt() ?? 0;
    if (version != ocrMaterialsSchemaVersion) {
      throw BackupException('备份文件的 OCR 来源数据版本不受支持'
          '（schemaVersion=$version，本程序支持 $ocrMaterialsSchemaVersion）');
    }
    final rawFiles = j['files'];
    if (rawFiles == null) return const <_OcrMaterialBackupFile>[];
    if (rawFiles is! List) {
      throw BackupException('备份文件的 OCR 来源文件列表结构不正确，已拒绝导入');
    }
    final out = <_OcrMaterialBackupFile>[];
    final seen = <String>{};
    // base64 编码后长度的保守上限（4 字节/3 字节 + 填充），用于解码前限额。
    final maxBase64Length = (maxOcrMaterialBytesLimit * 4) ~/ 3 + 8;
    final maxBase64Total = (maxOcrMaterialsTotalBytesLimit * 4) ~/ 3 + 8;
    var encodedTotal = 0;
    var decodedTotal = 0;
    for (final item in rawFiles) {
      if (item is! Map) {
        throw BackupException('备份文件的 OCR 来源条目结构不正确，已拒绝导入');
      }
      final entry = Map<String, dynamic>.from(item);
      final path = entry['path'];
      final content = entry['content'];
      final rawLength = entry['byteLength'];
      final digest = entry['sha256'];
      if (path is! String || content is! String || digest is! String) {
        throw BackupException('备份文件的 OCR 来源条目缺少路径、内容或校验值，已拒绝导入');
      }
      if (rawLength is! num) {
        throw BackupException('备份文件的 OCR 来源条目缺少长度，已拒绝导入');
      }
      final relative = _safeOcrMaterialPath(path);
      if (relative == null) {
        throw BackupException('备份文件的 OCR 来源数据路径不合法：$path');
      }
      if (!seen.add(relative)) {
        throw BackupException('备份文件中存在重复的 OCR 来源数据路径：$relative');
      }
      // 解码前限额（不先解出巨量内存）：base64 长度必须落在上限对应的范围内；
      // 解码后再按真实字节数精确校验一次。
      if (content.length > maxBase64Length) {
        throw BackupException('备份文件中的 OCR 来源数据过大（$relative，'
            '上限 ${formatByteCount(maxOcrMaterialBytesLimit)}），已拒绝导入');
      }
      encodedTotal += content.length;
      if (encodedTotal > maxBase64Total) {
        throw BackupException('备份文件中的 OCR 来源数据总量过大'
            '（上限 ${formatByteCount(maxOcrMaterialsTotalBytesLimit)}），已拒绝导入');
      }
      List<int> bytes;
      try {
        bytes = base64Decode(content);
      } catch (_) {
        throw BackupException('备份文件的 OCR 来源内容损坏：$relative');
      }
      if (bytes.length != rawLength.toInt()) {
        throw BackupException('备份文件的 OCR 来源数据大小不符（$relative）：'
            '记录 ${rawLength.toInt()} 字节，实际 ${bytes.length} 字节，已拒绝导入');
      }
      if (bytes.length > maxOcrMaterialBytesLimit) {
        throw BackupException('备份文件中的 OCR 来源数据过大（$relative），已拒绝导入');
      }
      decodedTotal += bytes.length;
      if (decodedTotal > maxOcrMaterialsTotalBytesLimit) {
        throw BackupException('备份文件中的 OCR 来源数据总量过大，已拒绝导入');
      }
      if (_sha256Hex(bytes) != digest.trim().toLowerCase()) {
        throw BackupException('备份文件的 OCR 来源数据校验失败（SHA-256 不符）：$relative');
      }
      _validateOcrMaterialJson(relative, bytes);
      out.add(_OcrMaterialBackupFile(relative, bytes));
    }
    return List<_OcrMaterialBackupFile>.unmodifiable(out);
  }

  /// 恢复前校验 OCR 来源文件本身是可解析、带页列表的来源 JSON（不判断语义）。
  static void _validateOcrMaterialJson(String relative, List<int> bytes) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      throw BackupException('OCR 来源数据不是有效的 UTF-8 JSON：$relative');
    }
    if (decoded is! Map) {
      throw BackupException('OCR 来源数据顶层不是对象：$relative');
    }
    final map = Map<String, dynamic>.from(decoded);
    final pages = map['pages'];
    if (pages is! List) {
      throw BackupException('OCR 来源数据缺少页列表：$relative');
    }
    for (final page in pages) {
      if (page is! Map) {
        throw BackupException('OCR 来源数据中存在结构不正确的页：$relative');
      }
    }
    if (map['fileLabel'] is! String) {
      throw BackupException('OCR 来源数据缺少文件标识：$relative');
    }
    // 纵深防御：来源文件由本程序写入，正常不含任何密钥字段；一旦出现就拒绝，
    // 不让密钥有机会随备份离开本机（与会话段 `_scrub` 同一原则）。
    _rejectSensitiveOcrFields(map, relative);
  }

  /// 递归拒绝键名命中 [_sensitiveKeys] 的字段（值不参与判断）。
  static void _rejectSensitiveOcrFields(Object? value, String relative) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (_isSensitive(entry.key.toString())) {
          throw BackupException('OCR 来源数据包含疑似密钥字段（${entry.key}）：$relative');
        }
        _rejectSensitiveOcrFields(entry.value, relative);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectSensitiveOcrFields(item, relative);
      }
    }
  }

  /// 解析备份里的全局日程段；旧备份没有该键 → null（绝不清空本地日程）。
  ///
  /// 严格校验段版本、大小、记录数、每条记录字段与重复 ID；任何一项不合法都整份
  /// 拒绝导入，避免出现“会话已恢复、日程半份”的状态。
  _ScheduleBackup? _parseSchedule(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw BackupException('备份文件的日程数据结构不正确，已拒绝导入');
    }
    final j = Map<String, dynamic>.from(raw);
    final sectionBytes = utf8.encode(jsonEncode(j)).length;
    if (sectionBytes > maxScheduleSectionBytesLimit) {
      throw BackupException('备份文件中的日程数据过大（${formatByteCount(sectionBytes)}，'
          '上限 ${formatByteCount(maxScheduleSectionBytesLimit)}），已拒绝导入');
    }
    final version = (j['schemaVersion'] as num?)?.toInt() ?? 0;
    if (version != scheduleSchemaVersion) {
      throw BackupException('备份文件的日程数据版本不受支持'
          '（schemaVersion=$version，本程序支持 $scheduleSchemaVersion），已拒绝导入');
    }
    final revision = j['revision'];
    if (revision is! int || revision < 0) {
      throw BackupException('备份文件的日程 revision 不合法，已拒绝导入');
    }
    final rawEvents = j['events'];
    if (rawEvents is! List) {
      throw BackupException('备份文件的日程事件列表结构不正确，已拒绝导入');
    }
    if (rawEvents.length > maxScheduleEventsLimit) {
      throw BackupException('备份文件中的日程记录过多（${rawEvents.length} 条，'
          '上限 $maxScheduleEventsLimit），已拒绝导入');
    }
    final events = <ScheduleEvent>[];
    final ids = <String>{};
    for (var i = 0; i < rawEvents.length; i++) {
      final event = ScheduleEvent.tryParse(rawEvents[i]);
      if (event == null) {
        throw BackupException('备份文件中第 ${i + 1} 条日程数据不合法，已拒绝导入');
      }
      if (!ids.add(event.id)) {
        throw BackupException('备份文件中存在重复的日程 ID：${event.id}，已拒绝导入');
      }
      events.add(event);
    }
    return _ScheduleBackup(
      revision: revision,
      events: List<ScheduleEvent>.unmodifiable(events),
    );
  }

  /// 解析备份里的执行记录段；旧备份/未启用计时的备份没有该键 → null（不合并）。
  ExecutionLedger? _parseExecutionLedger(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw BackupException('备份文件的执行记录结构不正确，已拒绝导入');
    }
    final map = Map<String, dynamic>.from(raw);
    // 严格校验结构：坏条目不能悄悄丢掉（否则会得到一份"看起来恢复成功"的残缺账本）。
    for (final key in <String>['records', 'completionEvents']) {
      final value = map[key];
      if (value == null) continue;
      if (value is! List) {
        throw BackupException('备份文件的执行记录结构不正确（$key 不是列表），已拒绝导入');
      }
      for (final item in value) {
        if (item is! Map) {
          throw BackupException('备份文件的执行记录结构不正确（$key 存在非对象条目），已拒绝导入');
        }
      }
    }
    try {
      return ExecutionLedger.fromJson(map);
    } catch (e) {
      throw BackupException('备份文件的执行记录无法解析：${_shortError(e)}');
    }
  }

  /// 解析备份文档里的外部日历段；旧备份没有该键 → 空列表（不恢复外部日历）。
  List<_ExternalCalendarBackupFile> _parseExternalCalendarFiles(Object? raw) {
    if (raw == null) return const <_ExternalCalendarBackupFile>[];
    if (raw is! Map) {
      throw BackupException('备份文件的外部日历结构不正确，已拒绝导入');
    }
    final j = Map<String, dynamic>.from(raw);
    final version = (j['schemaVersion'] as num?)?.toInt() ?? 0;
    if (version != externalCalendarSchemaVersion) {
      throw BackupException('备份文件的外部日历版本不受支持'
          '（schemaVersion=$version，本程序支持 $externalCalendarSchemaVersion）');
    }
    final rawFiles = j['files'];
    if (rawFiles == null) return const <_ExternalCalendarBackupFile>[];
    if (rawFiles is! List) {
      throw BackupException('备份文件的外部日历文件列表结构不正确，已拒绝导入');
    }
    final out = <_ExternalCalendarBackupFile>[];
    final seen = <String>{};
    for (final item in rawFiles) {
      if (item is! Map) {
        throw BackupException('备份文件的外部日历条目结构不正确，已拒绝导入');
      }
      final entry = Map<String, dynamic>.from(item);
      final path = entry['path'];
      final content = entry['content'];
      if (path is! String || content is! String) {
        throw BackupException('备份文件的外部日历条目缺少路径或内容，已拒绝导入');
      }
      final relative = _safeRelativePath(path);
      if (relative == null) {
        throw BackupException('备份文件的外部日历路径不合法：$path');
      }
      if (!seen.add(relative)) {
        throw BackupException('备份文件中存在重复的外部日历路径：$relative');
      }
      List<int> bytes;
      try {
        bytes = base64Decode(content);
      } catch (_) {
        throw BackupException('备份文件的外部日历内容损坏：$relative');
      }
      out.add(_ExternalCalendarBackupFile(relative, bytes));
    }
    return List<_ExternalCalendarBackupFile>.unmodifiable(out);
  }

  // ------------------------------------------------------------ internals

  /// True when the preferences file already holds exactly these values, so a restore must
  /// not rewrite it (an identical backup is a no-op). A missing, unreadable or recovered
  /// file always counts as "needs a write".
  Future<bool> _shouldWritePreferences(AppPreferences? prefs) async {
    if (prefs == null) return false;
    final loaded = await settingsStore.load();
    if (!loaded.existed || loaded.warning != null) return true;
    return loaded.prefs.normalized() != prefs.normalized();
  }

  Future<void> _discardStaged(List<_StagedFile> staged) async {
    for (final item in staged) {
      try {
        if (await item.tmp.exists()) await item.tmp.delete();
      } catch (_) {
        // Leftover in `cache/restore/`; the next restore clears the staging directory.
      }
    }
  }

  /// Puts every replaced file back. Reports exactly what was restored and what failed;
  /// a swallowed exception must never be presented as “original data restored”.
  Future<({List<String> restored, List<String> failed})> _rollback(
      List<_CommitEntry> committed) async {
    final restored = <String>[];
    final failed = <String>[];
    for (final item in committed.reversed) {
      try {
        // A promoted target holds the restored bytes; the previous ones are in `.bak`.
        if (item.promoted && await item.target.exists()) {
          await item.target.delete();
        }
        final backup = item.backup;
        if (backup != null && await backup.exists()) {
          if (!await item.target.exists()) {
            await backup.rename(item.target.path);
          }
        }
        if (backup != null && !await item.target.exists()) {
          failed.add(item.target.path);
        } else {
          restored.add(item.target.path);
        }
      } catch (_) {
        failed.add(item.target.path);
      }
    }
    return (
      restored: List<String>.unmodifiable(restored),
      failed: List<String>.unmodifiable(failed),
    );
  }

  /// Recursively drops key-like fields. The model already never stores a key; this is
  /// a second line of defence so no future field can leak one into a backup.
  static Object? _scrub(Object? value) {
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final name = entry.key.toString();
        if (_isSensitive(name)) continue;
        out[name] = _scrub(entry.value);
      }
      return out;
    }
    if (value is List) return value.map(_scrub).toList(growable: false);
    return value;
  }

  static bool _isSensitive(String key) {
    final normalized =
        key.replaceAll('_', '').replaceAll('-', '').toLowerCase();
    return _sensitiveKeys.contains(normalized);
  }

  /// Content equality for two conversations, independent of map ordering.
  static bool _sameConversation(Conversation a, Conversation b) =>
      _canonicalJson(a.toJson()) == _canonicalJson(b.toJson());

  static bool _sameSummaryList(
      List<ConversationSummary> a, List<ConversationSummary> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_canonicalJson(a[i].toJson()) != _canonicalJson(b[i].toJson())) {
        return false;
      }
    }
    return true;
  }

  static String _canonicalJson(Object? value) => jsonEncode(_sorted(value));

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      final out = <String, dynamic>{};
      for (final key in keys) {
        out[key] = _sorted(value[key]);
      }
      return out;
    }
    if (value is List) return value.map(_sorted).toList(growable: false);
    return value;
  }

  static String _basenameOf(String path) {
    final segments = path.split(Platform.pathSeparator);
    return segments.isEmpty ? path : segments.last;
  }

  /// 备份/恢复只接受目录内的相对路径：拒绝绝对路径、盘符和 `..`。
  static String? _safeRelativePath(String raw) {
    final normalized = raw.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.length > 512) return null;
    if (normalized.startsWith('/') || normalized.contains(':')) return null;
    final segments = normalized.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') return null;
    }
    return normalized;
  }

  /// OCR 来源数据的路径白名单：只允许 `ocr_materials/<id>.json`。
  ///
  /// 拒绝绝对路径、盘符、`..`、多级子目录、非 JSON 文件名，以及反斜杠/混合分隔符
  /// （本程序导出的备份固定使用 `/`）。目录外内容与任意原路径文件都不会被读写。
  static String? _safeOcrMaterialPath(String raw) {
    if (raw.isEmpty || raw.length > 512) return null;
    if (raw.contains('\\')) return null;
    final safe = _safeRelativePath(raw);
    if (safe == null) return null;
    final parts = safe.split('/');
    if (parts.length != 2 || parts.first != ocrMaterialsDirectoryName) {
      return null;
    }
    final name = parts.last;
    if (name.length <= 5 || !name.endsWith('.json')) return null;
    if (!_idPattern.hasMatch(name.substring(0, name.length - 5))) return null;
    return safe;
  }

  /// 符号链接 / Windows 联接点（junction）：`followLinks: false` 会把两者都报告为 link。
  ///
  /// 用于拒绝跟随重解析点读取或写入数据目录之外的内容。
  static Future<bool> _isReparsePoint(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.link;

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// `<root>/external_calendar/` 内的文件 → 相对路径（posix 分隔符）；不在目录内返回 null。
  static String? _relativeInside(Directory dir, File file) {
    final base = dir.path.endsWith(Platform.pathSeparator)
        ? dir.path
        : '${dir.path}${Platform.pathSeparator}';
    if (!file.path.startsWith(base)) return null;
    final relative = file.path
        .substring(base.length)
        .replaceAll(Platform.pathSeparator, '/');
    return _safeRelativePath(relative);
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}

/// Holds an exclusive OS lock on `<root>/cache/.lock` for the duration of an operation.
class _CacheLock {
  _CacheLock(this._handle);

  final RandomAccessFile _handle;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } catch (_) {
      // The handle may already be gone; closing is what matters.
    }
    try {
      await _handle.close();
    } catch (_) {
      // Ignore: the lock is released either way.
    }
  }
}

/// Raised for validation problems; converted to [BackupRestoreResult.error].
class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => 'BackupException: $message';
}

class _ParsedBackup {
  const _ParsedBackup({
    required this.conversations,
    required this.index,
    required this.prefs,
    required this.profiles,
    this.defaultProfileId = '',
    this.defaultModelId = '',
    this.externalCalendarFiles = const <_ExternalCalendarBackupFile>[],
    this.ocrMaterialFiles = const <_OcrMaterialBackupFile>[],
    this.schedule,
    this.executionLedger,
  });

  final List<Conversation> conversations;
  final List<ConversationSummary> index;
  final AppPreferences? prefs;
  final List<ProviderProfile> profiles;
  final String defaultProfileId;
  final String defaultModelId;

  /// 备份文档里的外部日历文件（相对路径 + 原始字节）。
  final List<_ExternalCalendarBackupFile> externalCalendarFiles;

  /// 备份文档里的 OCR 来源文件（相对路径 + 原始字节）；旧备份没有该段 → 空列表。
  final List<_OcrMaterialBackupFile> ocrMaterialFiles;

  /// 备份文档里的全局日程段；旧备份没有该键 → null（绝不清空本地日程）。
  final _ScheduleBackup? schedule;

  /// 0.2.3（R3-E）：备份文档里的执行记录账本；旧备份没有该键 → null（不合并）。
  final ExecutionLedger? executionLedger;
}

/// 备份/恢复中的一个外部日历文件（路径为 `<root>/external_calendar/` 下的相对路径）。
class _ExternalCalendarBackupFile {
  const _ExternalCalendarBackupFile(this.relativePath, this.bytes);

  final String relativePath;
  final List<int> bytes;
}

/// 外部日历恢复计划：要么写入 [toWrite]，要么因本地内容不同而报告 [conflicts]。
class _ExternalCalendarRestorePlan {
  const _ExternalCalendarRestorePlan({
    this.toWrite = const <_ExternalCalendarBackupFile>[],
    this.conflicts = const <String>[],
    this.total = 0,
  });

  final List<_ExternalCalendarBackupFile> toWrite;
  final List<String> conflicts;
  final int total;
}

/// 备份/恢复中的一个 OCR 来源文件（路径为 `<root>/ocr_materials/` 下的相对路径）。
class _OcrMaterialBackupFile {
  const _OcrMaterialBackupFile(this.relativePath, this.bytes);

  final String relativePath;
  final List<int> bytes;
}

/// OCR 来源文件恢复计划：写入、幂等跳过、冲突（不覆盖）分别计数。
class _OcrMaterialRestorePlan {
  const _OcrMaterialRestorePlan({
    this.toWrite = const <_OcrMaterialBackupFile>[],
    this.identical = const <String>[],
    this.conflicts = const <String>[],
    this.total = 0,
    this.directoryIsLink = false,
    this.missingReferenceCount = 0,
  });

  final List<_OcrMaterialBackupFile> toWrite;
  final List<String> identical;
  final List<String> conflicts;
  final int total;

  /// 本地 `ocr_materials/` 目录是符号链接/联接点：拒绝任何写入，避免写到数据目录外。
  final bool directoryIsLink;

  /// 被附件引用、但备份与本地都没有的来源文件数。
  final int missingReferenceCount;
}

/// 备份文档里的全局日程段（含删除标记的记录 + 源数据 revision）。
class _ScheduleBackup {
  const _ScheduleBackup({required this.revision, required this.events});

  final int revision;
  final List<ScheduleEvent> events;
}

/// 日程恢复计划：present=备份带日程段；merged=需要写入的合并快照（null=无需写）。
class _ScheduleRestorePlan {
  const _ScheduleRestorePlan({
    this.present = false,
    this.total = 0,
    this.restored = 0,
    this.skipped = 0,
    this.conflicts = const <String>[],
    this.unlinkedEventIds = const <String>[],
    this.merged,
    this.skipReason,
  });

  final bool present;
  final int total;
  final int restored;
  final int skipped;
  final List<String> conflicts;
  final List<String> unlinkedEventIds;
  final ScheduleSnapshot? merged;

  /// 非空 = 本次无法合并日程（未启用日程服务/未打开/只读/数据目录不一致）。
  final String? skipReason;
}

class _StagedFile {
  const _StagedFile({required this.tmp, required this.target});

  final File tmp;
  final File target;
}

/// One file of the commit phase: the promoted target and the `.bak` copy of the file it
/// replaced (if any). [promoted] turns true once the staged bytes are in place.
class _CommitEntry {
  _CommitEntry(this.target, this.backup);

  final File target;
  final File? backup;
  bool promoted = false;
}
