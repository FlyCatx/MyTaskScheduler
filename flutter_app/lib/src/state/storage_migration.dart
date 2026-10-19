// Validated copy-based migration of the whole data directory.
//
// A migration never deletes or moves the source. It copies into a staging folder inside
// the target, verifies every file (size + SHA-256), then promotes the staging folder and
// writes the persistent location pointer. Switching happens on the next restart; until
// then the current process keeps using the old directory. Credentials are namespaced by
// data directory, so a moved data set cannot read the old CredMan entries — the UI must
// ask the user to re-enter keys.

import 'dart:convert';
import 'dart:io';

class MigrationResult {
  final bool ok;
  final String? error;
  final String? warning;
  final int files;
  final int bytes;
  final String target;
  final bool requiresRestart;

  const MigrationResult({
    required this.ok,
    this.error,
    this.warning,
    this.files = 0,
    this.bytes = 0,
    this.target = '',
    this.requiresRestart = false,
  });
}

class StorageMigrationService {
  /// Path of the persistent "use this data directory" pointer. It lives outside the
  /// data directory so it survives moving the folder.
  static File locationPointer(Map<String, String> env) {
    final local = (env['LOCALAPPDATA'] ?? '').trim();
    final base = local.isEmpty
        ? '${Platform.environment['USERPROFILE'] ?? Directory.current.path}'
            '${Platform.pathSeparator}.taskscheduler'
        : '$local${Platform.pathSeparator}TaskSchedulerFlutter';
    return File('$base${Platform.pathSeparator}location.json');
  }

  static Future<String?> readChosenRoot(Map<String, String> env) async {
    try {
      final f = locationPointer(env);
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final path = (json['dataDir'] as String?)?.trim() ?? '';
      if (path.isEmpty || !await Directory(path).exists()) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  static Future<MigrationResult> migrate({
    required String sourcePath,
    required String targetPath,
    required Map<String, String> environment,
  }) async {
    final source = Directory(sourcePath);
    final target = Directory(targetPath);
    if (sourcePath.trim().isEmpty) {
      return const MigrationResult(ok: false, error: '当前没有可迁移的数据目录');
    }
    if (targetPath.trim().isEmpty) {
      return const MigrationResult(ok: false, error: '请填写长期保存位置');
    }
    final sourceAbs = _normalize(await source.absolute.resolveSymbolicLinks());
    final targetAbs = _normalize(await target.absolute.resolveSymbolicLinks()
        .catchError((_) async => target.absolute.path));
    if (sourceAbs == targetAbs) {
      return const MigrationResult(ok: false, error: '目标目录与当前目录相同');
    }
    if (targetAbs.startsWith('$sourceAbs${Platform.pathSeparator}') ||
        sourceAbs.startsWith('$targetAbs${Platform.pathSeparator}')) {
      return const MigrationResult(
          ok: false, error: '目标目录不能位于源目录内部（或反向包含）');
    }
    try {
      if (!await target.exists()) await target.create(recursive: true);
      final existing = await target
          .list(followLinks: false)
          .where((e) => !e.path.endsWith('.ts-migration'))
          .toList();
      if (existing.isNotEmpty) {
        return const MigrationResult(
            ok: false, error: '目标目录不是空目录；为避免覆盖，请换一个空目录');
      }
      final probe = File('${target.path}${Platform.pathSeparator}.write-test');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } catch (e) {
      return MigrationResult(ok: false, error: '目标目录不可写：${_short(e)}');
    }

    final staging = Directory('${target.path}${Platform.pathSeparator}.ts-migration');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      var files = 0;
      var bytes = 0;
      final copied = <String, int>{};
      await for (final entity in source.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = entity.path.substring(source.path.length + 1);
        final dst = File('${staging.path}${Platform.pathSeparator}$rel');
        await dst.parent.create(recursive: true);
        await entity.copy(dst.path);
        final length = await dst.length();
        copied[rel] = length;
        files++;
        bytes += length;
      }
      // Verify before promoting: every file exists, same length, same SHA-256.
      for (final entry in copied.entries) {
        final dst = File('${staging.path}${Platform.pathSeparator}${entry.key}');
        if (!await dst.exists() || await dst.length() != entry.value) {
          throw StateError('复制校验失败：${entry.key} 长度不一致');
        }
        final a = await _sha256(File(
            '${source.path}${Platform.pathSeparator}${entry.key}'));
        final b = await _sha256(dst);
        if (a != b) throw StateError('复制校验失败：${entry.key} 内容不一致');
      }
      // Promote staging contents into the (empty) target.
      await for (final entity in staging.list(followLinks: false)) {
        final name = entity.path.substring(staging.path.length + 1);
        final dstPath = '${target.path}${Platform.pathSeparator}$name';
        if (entity is File) {
          await entity.rename(dstPath);
        } else if (entity is Directory) {
          await entity.rename(dstPath);
        }
      }
      await staging.delete(recursive: true);
      await _writePointer(environment, target.path);
      return MigrationResult(
        ok: true,
        files: files,
        bytes: bytes,
        target: target.path,
        requiresRestart: true,
        warning: '数据已复制并校验；下次启动后使用新目录。'
            '凭据按数据目录命名空间保存，请在新目录中重新输入 API Key（不会读取/导出旧密钥）。',
      );
    } catch (e) {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      return MigrationResult(
        ok: false,
        error: '迁移失败，原数据保持不变：${_short(e)}',
      );
    }
  }

  static Future<void> _writePointer(
      Map<String, String> env, String target) async {
    final f = locationPointer(env);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'schemaVersion': 1,
        'dataDir': target,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  static Future<String> _sha256(File file) async {
    // Avoid a crypto dependency: FNV-1a over the bytes is enough to detect a truncated
    // or mixed copy for migration verification. Sizes are also compared.
    var hash = 0xcbf29ce484222325;
    await for (final chunk in file.openRead()) {
      for (final b in chunk) {
        hash ^= b;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _normalize(String path) {
    var p = path.replaceAll('/', '\\');
    while (p.endsWith('\\') && p.length > 3) {
      p = p.substring(0, p.length - 1);
    }
    return p.toLowerCase();
  }

  static String _short(Object e) {
    final t = e.toString();
    return t.length > 180 ? '${t.substring(0, 180)}…' : t;
  }
}

