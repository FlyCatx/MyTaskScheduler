// Resolves where session data may be written.
//
// Why this exists: the previous build hard-coded %LOCALAPPDATA%\TaskSchedulerFlutter.
// On locked-down Windows accounts (Low-integrity tokens, AppData\Local with
// ReadAndExecute-only ACLs, redirected profiles, Program Files installs) creating that
// folder fails with "OS Error 5: 拒绝访问" and the whole app refused to start.
//
// Rules, in priority order:
//   1. TASKSCHEDULER_DATA_DIR, if it is actually writable;
//   2. <exe>\TaskSchedulerData — the portable folder next to the executable. This is
//      the DEFAULT: the app ships as a portable package, so all state lives with it
//      and the whole folder can be moved/copied as one unit;
//   3. %LOCALAPPDATA%\TaskSchedulerFlutter — used when the program folder is read-only
//      (e.g. installed under Program Files);
//   4. %APPDATA%\TaskSchedulerFlutter;
//   5. %TEMP%\TaskSchedulerFlutter;
//   6. in-memory only (app still runs, but nothing is persisted).
//
// Every candidate is *probed* by creating the directory and writing/deleting a file,
// because "directory exists" does not imply "this process may write into it".
//
// Note: falling back is NOT reported in the UI. The location is an implementation
// detail unless nothing at all is writable (see [StorageRoot.notice]).

import 'dart:io';

import 'storage_migration.dart';

class RejectedRoot {
  final String label;
  final String path;
  final String reason;

  const RejectedRoot(this.label, this.path, this.reason);

  @override
  String toString() => '$label ($path): $reason';
}

class StorageRoot {
  /// Null means "no writable location found": the app runs with an in-memory store.
  final Directory? directory;
  final String source;
  final String path;
  final bool memoryOnly;
  final List<RejectedRoot> rejected;

  const StorageRoot({
    required this.directory,
    required this.source,
    required this.path,
    required this.rejected,
    this.memoryOnly = false,
  });

  /// Human sentence for diagnostics (not shown in the UI any more).
  String get describe {
    if (memoryOnly || directory == null) {
      return '找不到可写的数据目录：本次运行的会话不会被保存';
    }
    return path;
  }

  /// Only a genuinely broken situation is surfaced: no writable directory at all,
  /// which means the session will not be saved. Location fallbacks stay silent.
  String? get notice {
    if (memoryOnly || directory == null) {
      return '没有可写的数据目录，本次运行的会话与版本不会被保存。'
          '请把程序放到可写目录，或设置环境变量 TASKSCHEDULER_DATA_DIR 指向一个可写文件夹。';
    }
    return null;
  }
}

/// Ordered candidate list, exposed for tests.
List<({String label, String path})> storageCandidates({
  required Map<String, String> env,
  required String exeDir,
}) {
  final out = <({String label, String path})>[];

  final override = env['TASKSCHEDULER_DATA_DIR']?.trim() ?? '';
  if (override.isNotEmpty) {
    out.add((label: 'env', path: override));
  }
  // Portable folder first: this is a portable package, state lives with the program.
  if (exeDir.isNotEmpty) {
    out.add((
      label: 'portable',
      path: '$exeDir${Platform.pathSeparator}TaskSchedulerData',
    ));
  }
  final localAppData = env['LOCALAPPDATA']?.trim() ?? '';
  if (localAppData.isNotEmpty) {
    out.add((
      label: 'localAppData',
      path: '$localAppData${Platform.pathSeparator}TaskSchedulerFlutter',
    ));
  }
  final appData = env['APPDATA']?.trim() ?? '';
  if (appData.isNotEmpty) {
    out.add((
      label: 'appData',
      path: '$appData${Platform.pathSeparator}TaskSchedulerFlutter',
    ));
  }
  final temp = (env['TEMP'] ?? env['TMP'] ?? '').trim();
  if (temp.isNotEmpty) {
    out.add((
      label: 'temp',
      path: '$temp${Platform.pathSeparator}TaskSchedulerFlutter',
    ));
  }
  return out;
}

/// True when [dir] can be created and written by this process right now.
Future<({bool ok, String reason})> probeWritable(Directory dir) async {
  try {
    await dir.create(recursive: true);
  } catch (e) {
    return (ok: false, reason: _shortError(e));
  }
  final probe = File('${dir.path}${Platform.pathSeparator}.write-test');
  try {
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return (ok: true, reason: '');
  } catch (e) {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
    return (ok: false, reason: _shortError(e));
  }
}

String _shortError(Object e) {
  final text = e.toString();
  if (text.contains('拒绝访问') || text.contains('Access is denied')) {
    return '拒绝访问，OS Error 5';
  }
  if (text.contains('errno = 5')) return '拒绝访问，OS Error 5';
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}

  /// Picks the first writable candidate. Never throws: worst case it returns a
  /// memory-only root so the app still starts.
  Future<StorageRoot> resolveStorageRoot({
    Map<String, String>? environment,
    String? exeDirectory,
  }) async {
    final env = environment ?? Platform.environment;
    final exeDir = exeDirectory ?? File(Platform.resolvedExecutable).parent.path;

    final rejected = <RejectedRoot>[];
    final candidates = storageCandidates(env: env, exeDir: exeDir);
    final override = (env['TASKSCHEDULER_DATA_DIR'] ?? '').trim();
    if (override.isEmpty) {
      // A previously completed migration wins over the portable default, but an
      // explicit environment variable still has the highest priority.
      final chosen = await StorageMigrationService.readChosenRoot(env);
      if (chosen != null) {
        candidates.insert(0, (label: 'chosen', path: chosen));
      }
    }

    for (final c in candidates) {
      final dir = Directory(c.path);
      final probe = await probeWritable(dir);
      if (probe.ok) {
        return StorageRoot(
          directory: dir,
          source: c.label,
          path: c.path,
          rejected: rejected,
        );
      }
      rejected.add(RejectedRoot(c.label, c.path, probe.reason));
    }

    return StorageRoot(
      directory: null,
      source: 'memory',
      path: '',
      rejected: rejected,
      memoryOnly: true,
    );
  }

