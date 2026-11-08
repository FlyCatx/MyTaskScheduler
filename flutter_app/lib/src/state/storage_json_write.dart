// 原子写入 JSON 文件的共享实现。
//
// 会话、外部日历和执行记录这三种不可再生数据依赖同一套落盘协议：
//   1. 新内容先写唯一临时文件 `<file>.<token>.tmp` 并 flush；
//   2. 旧主文件改名 `<file>.bak`；
//   3. 临时文件改名为主文件。
// 失败时只清理临时文件，保留主文件与 `.bak`。不能在 rename 失败时直接覆盖主
// 文件：杀毒软件/索引器短暂占用文件时，那样会把唯一的好副本换成半份数据。
//
// 同路径写入串行化，避免两次保存在 rename 之间交错。调用方负责把异常转成
// 用户提示；本函数只抛出原始错误。
//
// 差异只保留在 [writeJsonAtomically.keepBackup]：计时检查点允许丢一个写入周期，
// 因此直接替换而不留 `.bak`。需要“失败后把旧文件放回原位”的 SettingsStore 有
// 不同的回滚语义，OCR 缓存可重新生成，二者都不使用本协议。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'storage_migration.dart';

final Map<String, Future<void>> _writeQueues = <String, Future<void>>{};
int _writeSequence = 0;

/// 把 [data] 原子写入 [file]。
///
/// [prepareDirectory] 在写临时文件前执行，用于创建该存储自己的目录布局
/// （默认创建 [file] 的父目录）。[keepBackup] 为 false 时删除旧文件而不是改名
/// 成 `.bak`。
Future<void> writeJsonAtomically(
  File file,
  Map<String, dynamic> data, {
  bool keepBackup = true,
  Future<void> Function()? prepareDirectory,
}) {
  final previous = _writeQueues[file.path] ?? Future<void>.value();
  late final Future<void> next;
  next = previous
      .catchError((Object _) {})
      .then((_) => _writeJsonNow(
            file,
            data,
            keepBackup: keepBackup,
            prepareDirectory: prepareDirectory,
          ))
      .whenComplete(() {
    if (identical(_writeQueues[file.path], next)) {
      _writeQueues.remove(file.path);
    }
  });
  _writeQueues[file.path] = next;
  return next;
}

Future<void> _writeJsonNow(
  File file,
  Map<String, dynamic> data, {
  required bool keepBackup,
  Future<void> Function()? prepareDirectory,
}) async {
  StorageWriteGate.beginOperation();
  try {
    final token =
        '${DateTime.now().microsecondsSinceEpoch}-${_writeSequence++}';
    final tmp = File('${file.path}.$token.tmp');
    final bak = File('${file.path}.bak');
    final payload = const JsonEncoder.withIndent('  ').convert(data);
    if (prepareDirectory != null) {
      await prepareDirectory();
    } else {
      await file.parent.create(recursive: true);
    }
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await file.exists()) {
        if (keepBackup) {
          if (await bak.exists()) await bak.delete();
          await file.rename(bak.path);
        } else {
          await file.delete();
        }
      }
      await tmp.rename(file.path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  } finally {
    StorageWriteGate.endOperation();
  }
}
