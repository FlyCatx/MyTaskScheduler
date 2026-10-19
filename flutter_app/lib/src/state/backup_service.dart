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

import '../model/session.dart';
import '../model/settings.dart';
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
  });

  final String path;
  final int conversationCount;
  final int profileCount;
  final int byteLength;

  String get summary => '已备份 $conversationCount 个会话、$profileCount 个连接'
      '（${formatByteCount(byteLength)}）：$path';
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
    this.conflictConversationIds = const <String>[],
    this.sessionsReloaded = false,
    this.requiresRestart = false,
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

  /// Conversation ids that exist locally with different content; the restore was
  /// rejected as a whole (nothing was written).
  final List<String> conflictConversationIds;

  /// True when the session list was refreshed through the injected callback **and it
  /// succeeded**. Only then may the UI claim the list is up to date.
  final bool sessionsReloaded;

  /// True when a restart is genuinely required to see the restored data (no refresh
  /// callback was available, or the preferences could not be re-read in this run).
  final bool requiresRestart;

  /// True when no file was replaced, so an error message may promise "nothing changed".
  bool get dataUnchanged => ok || rolledBackPaths.isEmpty;

  String get summary {
    if (!ok) return error ?? '恢复失败';
    final applied = <String>[
      if (restoredConversationCount > 0) '$restoredConversationCount 个会话',
      if (restoredPrefs) '应用偏好',
      if (restoredProfileCount > 0)
        '$restoredProfileCount 个模型连接（密钥需重新输入）',
    ];
    final skipped = skippedConversationCount > 0
        ? '；$skippedConversationCount 个会话内容相同，已跳过'
        : '';
    if (applied.isEmpty) return '备份内容与本地一致，未恢复任何数据$skipped';
    return '已恢复 ${applied.join('、')}$skipped';
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
    this.maxImportBytesLimit = maxImportBytes,
    this.isBusy,
    this.reloadSessions,
  }) : settingsStore = settingsStore ?? SettingsStore(root);

  /// Backup schema version written by this build.
  static const int schemaVersion = 1;

  /// Hard limit for an import file (a backup is text; 32 MB is generous). Overridable
  /// through [maxImportBytesLimit] so tests do not have to write 32 MB.
  static const int maxImportBytes = 32 * 1024 * 1024;

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

  static const String backupKind = 'taskscheduler-backup';

  final SessionRepository store;
  final Directory root;
  final SettingsController? settings;
  final SettingsStore settingsStore;

  /// Reports whether an analysis is in progress. A restore while a request is running
  /// could replace conversations the request is about to commit into, so it is refused
  /// before any file is touched. Defaults to "not busy".
  final bool Function()? isBusy;

  /// Refreshes the live session list after a successful restore. When absent (or when it
  /// throws) the result reports [BackupRestoreResult.requiresRestart] instead of claiming
  /// that the UI is up to date.
  final Future<void> Function()? reloadSessions;

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

  // --------------------------------------------------------------- export

  /// Writes one key-less backup JSON to [path].
  Future<BackupExportResult> exportBackup(String path) async {
    final index = await store.loadIndex();
    final conversations = <Map<String, dynamic>>[];
    for (final summary in index) {
      final conversation = await store.loadConversation(summary.id);
      if (conversation != null) conversations.add(conversation.toJson());
    }
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
    return BackupExportResult(
      path: target.path,
      conversationCount: conversations.length,
      profileCount: profiles.length,
      byteLength: utf8.encode(payload).length,
    );
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
      final rolledBack = await _rollback(committed);
      await _discardStaged(staged);
      final names = rolledBack.map(_basenameOf).toList(growable: false);
      final detail = rolledBack.isEmpty
          ? '没有文件被替换，原有数据未改动'
          : '已回滚 ${rolledBack.length} 个文件（${names.join('、')}），原有数据已恢复';
      return BackupRestoreResult(
        ok: false,
        error: '恢复提交失败：${_shortError(e)}；$detail',
        rolledBackPaths: rolledBack,
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
    final requiresRestart =
        (parsed.conversations.isNotEmpty && !sessionsReloaded) ||
            ((parsed.prefs != null && prefsToWrite) && !prefsReloaded);

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
    );
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

  /// Puts every replaced file back. Returns the target paths that were restored.
  Future<List<String>> _rollback(List<_CommitEntry> committed) async {
    final restored = <String>[];
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
        restored.add(item.target.path);
      } catch (_) {
        // Best effort: the caller reports the original failure.
      }
    }
    return List<String>.unmodifiable(restored);
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
  });

  final List<Conversation> conversations;
  final List<ConversationSummary> index;
  final AppPreferences? prefs;
  final List<ProviderProfile> profiles;
  final String defaultProfileId;
  final String defaultModelId;
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

