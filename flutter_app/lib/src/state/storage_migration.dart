// Validated copy-based migration of the whole data directory.
//
// A migration never deletes or moves the source. It copies into a staging folder inside
// the target, verifies every file (size + real SHA-256), then promotes the staging folder
// and writes the persistent location pointer. While the copy runs, all new writes are
// frozen so the source cannot change halfway through; on success the freeze stays in
// place until the next restart (the process keeps reading the old directory). A failure
// unfreezes both and leaves the pointer untouched.
//
// Credentials are namespaced by data directory, so a moved data set cannot read the old
// CredMan entries — the UI must ask the user to re-enter keys.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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

/// 全局写入闸门：迁移期间暂停所有本地写入，避免复制到一半源数据又变化。
abstract final class StorageWriteGate {
  static bool _frozen = false;
  static String _reason = '';
  static int _active = 0;

  static bool get frozen => _frozen;
  static String get reason => _reason;

  /// 冻结新写入；[reason] 只用于界面说明。
  static void freeze(String reason) {
    _frozen = true;
    _reason = reason;
  }

  static void unfreeze() {
    _frozen = false;
    _reason = '';
  }

  /// 写入方在真正落盘前调用；冻结时抛 [StorageFrozenException]。
  static void ensureWritable() {
    if (_frozen) throw StorageFrozenException(_reason);
  }

  /// 标记一个正在进行中的写入；迁移会等待它结束。
  static int beginOperation() {
    ensureWritable();
    return ++_active;
  }

  static void endOperation() {
    if (_active > 0) _active--;
  }

  static Future<void> drain({Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_active > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_active > 0) {
      throw TimeoutException('仍有 $_active 个写入未完成；为避免数据分叉，已取消迁移');
    }
  }
}

class StorageFrozenException implements Exception {
  final String reason;
  const StorageFrozenException(this.reason);

  @override
  String toString() =>
      '数据目录迁移期间已暂停写入${reason.isEmpty ? '' : '（$reason）'}；请重启后继续';
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
    if (StorageWriteGate.frozen) {
      // 上一次迁移成功后闸门保持关闭，直到重启。显式再次执行迁移视为管理员操作：
      // 先恢复写入，再重新走完整的冻结/校验流程；失败时指针不变。
      StorageWriteGate.unfreeze();
    }
    if (sourcePath.trim().isEmpty) {
      return const MigrationResult(ok: false, error: '当前没有可迁移的数据目录');
    }
    if (targetPath.trim().isEmpty) {
      return const MigrationResult(ok: false, error: '请填写长期保存位置');
    }
    String sourceAbs;
    String targetAbs;
    try {
      sourceAbs = _normalize(await source.absolute.resolveSymbolicLinks());
      targetAbs = _normalize(await target.absolute.resolveSymbolicLinks()
          .catchError((_) async => target.absolute.path));
    } catch (e) {
      return MigrationResult(ok: false, error: '无法解析数据目录路径：${_short(e)}');
    }
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
    var frozen = false;
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      // 冻结新写入，并等待已经开始的写入结束，保证复制期间源目录不再变化。
      StorageWriteGate.freeze('正在迁移到 ${target.path}');
      frozen = true;
      await StorageWriteGate.drain();
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
        warning: '数据已复制并逐文件校验（SHA-256）；写入已冻结，'
            '下次启动后使用新目录。凭据按数据目录命名空间保存，'
            '请在新目录中重新输入 API Key（不会读取/导出旧密钥）。',
      );
    } catch (e) {
      if (frozen) StorageWriteGate.unfreeze();
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
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'schemaVersion': 1,
        'dataDir': target,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    // 可恢复替换：先把旧指针改名保留，再提升新指针；中途失败仍可回到旧指针。
    final old = File('${f.path}.old');
    try {
      if (await old.exists()) await old.delete();
      if (await f.exists()) await f.rename(old.path);
      await tmp.rename(f.path);
      if (await old.exists()) await old.delete();
    } catch (e) {
      try {
        if (!await f.exists() && await old.exists()) {
          await old.rename(f.path);
        }
      } catch (_) {}
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
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
