// Local application preferences store: `<dataRoot>/settings/app_prefs.json`.
//
// Why a separate file from `settings.json` (owned by the native layer): the UI
// preferences (theme, font scale, send mode …) must be readable and writable even when
// the native bridge is unavailable, and they never contain secrets.
//
// Durability rules (same idea as `SessionStore`):
//   * write `<file>.tmp`, move the old file to `<file>.bak`, then promote tmp;
//   * a failed save leaves the previous file untouched and rethrows, so the caller can
//     keep the old in-memory values and show a readable error;
//   * a corrupted/unknown-schema file is **never deleted or rewritten on load** — the
//     defaults are returned with a warning and the original bytes stay where they are.
//
// The root directory is injected, so tests use a throw-away folder.

import 'dart:convert';
import 'dart:io';

import '../model/settings.dart';

/// Result of [SettingsStore.load].
class SettingsPreferencesLoad {
  const SettingsPreferencesLoad({
    required this.prefs,
    this.warning,
    this.recoveredFromBackup = false,
    this.existed = false,
    this.path = '',
  });

  final AppPreferences prefs;

  /// Human readable explanation when the defaults were used (never contains data).
  final String? warning;

  /// True when the main file was unreadable and the `.bak` copy was used instead.
  final bool recoveredFromBackup;

  /// True when a preferences file (main or backup) existed.
  final bool existed;

  /// Absolute path of the main preferences file.
  final String path;
}

/// Atomic JSON store for [AppPreferences].
class SettingsStore {
  SettingsStore(this.root);

  /// Schema version written by this build. A newer number means "written by a newer
  /// app" and is handled as incompatible (defaults + warning, file preserved).
  static const int schemaVersion = 1;

  final Directory root;

  Directory get settingsDir =>
      Directory('${root.path}${Platform.pathSeparator}settings');

  File get prefsFile =>
      File('${settingsDir.path}${Platform.pathSeparator}app_prefs.json');

  File get backupFile => File('${prefsFile.path}.bak');

  String get prefsPath => prefsFile.path;

  /// Reads the preferences, falling back to defaults on any problem.
  Future<SettingsPreferencesLoad> load() async {
    final existed = await prefsFile.exists() || await backupFile.exists();
    final primary = await _read(prefsFile);
    if (primary.prefs != null) {
      return SettingsPreferencesLoad(
        prefs: primary.prefs!,
        warning: primary.warning,
        existed: existed,
        path: prefsPath,
      );
    }
    final backup = await _read(backupFile);
    if (backup.prefs != null) {
      return SettingsPreferencesLoad(
        prefs: backup.prefs!,
        warning: '设置文件已损坏，已从备份恢复应用偏好'
            '（原文件保留为 app_prefs.json，备份为 app_prefs.json.bak）',
        recoveredFromBackup: true,
        existed: true,
        path: prefsPath,
      );
    }
    final extra = primary.warning;
    return SettingsPreferencesLoad(
      prefs: const AppPreferences(),
      warning: existed
          ? (extra ?? '设置文件无法读取，本次使用默认设置；原文件未被修改')
          : null,
      existed: existed,
      path: prefsPath,
    );
  }

  /// Convenience wrapper for tests/diagnostics that only needs the values.
  Future<AppPreferences> loadPreferences() async => (await load()).prefs;

  /// Atomically writes [prefs]. Throws when the file system refuses the write; the
  /// previous file is restored in that case.
  Future<void> save(AppPreferences prefs) async {
    await settingsDir.create(recursive: true);
    final payload = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'schemaVersion': schemaVersion,
      'savedAt': DateTime.now().toIso8601String(),
      // Nested so future top-level metadata cannot collide with a preference key.
      'prefs': prefs.normalized().toJson(),
    });
    await _writeAtomic(prefsFile, payload);
  }

  // ------------------------------------------------------------- internals

  /// Decodes one file. Never throws and never modifies the file.
  Future<({AppPreferences? prefs, String? warning})> _read(File file) async {
    if (!await file.exists()) return (prefs: null, warning: null);
    String text;
    try {
      text = await file.readAsString();
    } catch (e) {
      return (prefs: null, warning: '设置文件无法读取：${_shortError(e)}');
    }
    if (text.trim().isEmpty) {
      return (prefs: null, warning: '设置文件为空');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return (prefs: null, warning: '设置文件不是有效的 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      return (prefs: null, warning: '设置文件结构不正确');
    }
    final version = (decoded['schemaVersion'] as num?)?.toInt() ?? schemaVersion;
    if (version > schemaVersion) {
      return (
        prefs: null,
        warning: '设置文件版本较新（schemaVersion=$version），本次使用默认设置；'
            '原文件未被修改',
      );
    }
    if (version < 1) {
      return (prefs: null, warning: '设置文件版本不受支持（schemaVersion=$version）');
    }
    final raw = decoded['prefs'] ?? decoded['preferences'];
    if (raw is! Map<String, dynamic>) {
      // Tolerate a flat file (older experiments wrote preferences at top level).
      final flat = Map<String, dynamic>.from(decoded)..remove('schemaVersion');
      if (flat.isEmpty) {
        return (prefs: null, warning: '设置文件缺少 preferences 字段');
      }
      return (prefs: AppPreferences.fromJson(flat), warning: null);
    }
    return (prefs: AppPreferences.fromJson(raw), warning: null);
  }

  Future<void> _writeAtomic(File file, String payload) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    await tmp.writeAsString(payload, flush: true);
    var movedOld = false;
    try {
      if (await file.exists()) {
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path);
        movedOld = true;
      }
      await tmp.rename(file.path);
    } catch (_) {
      // Put the previous file back: a failed save must never destroy the old values.
      if (movedOld && !await file.exists() && await bak.exists()) {
        try {
          await bak.rename(file.path);
        } catch (_) {
          // Best effort only; the caller reports the original failure.
        }
      }
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Leave the tmp file behind; the cache cleaner lists `*.tmp` explicitly.
      }
      rethrow;
    }
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}

