// 数据可靠性回归：写入闸门、同文件并发写、回滚报告语义。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/backup_service.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/storage_migration.dart';

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('ts_reliability_');
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

Conversation _conversation(String id, String draft) => Conversation(
      id: id,
      title: '会话 $id',
      createdAt: DateTime.utc(2026, 10, 19),
      updatedAt: DateTime.utc(2026, 10, 19),
      draftText: draft,
    );

void main() {
  tearDown(() => StorageWriteGate.unfreeze());

  test('冻结期间拒绝新写入，解冻后恢复', () async {
    final dir = _tempDir();
    final store = SessionStore(dir);
    await store.saveConversation(_conversation('c1', 'before'));
    StorageWriteGate.freeze('迁移测试');
    await expectLater(
      store.saveConversation(_conversation('c1', 'during')),
      throwsA(isA<StorageFrozenException>()),
    );
    StorageWriteGate.unfreeze();
    await store.saveConversation(_conversation('c1', 'after'));
    final loaded = await store.loadConversation('c1');
    expect(loaded!.draftText, 'after');
  });

  test('同一文件并发写串行化，最终 JSON 可读且无残留 .tmp', () async {
    final dir = _tempDir();
    final store = SessionStore(dir);
    await Future.wait(<Future<void>>[
      for (var i = 0; i < 20; i++)
        store.saveConversation(_conversation('c1', 'draft-$i')),
    ]);
    final loaded = await store.loadConversation('c1');
    expect(loaded, isNotNull);
    expect(loaded!.draftText, startsWith('draft-'));
    final leftovers = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList(growable: false);
    expect(leftovers, isEmpty, reason: '唯一临时文件必须在成功后清理');
    final raw = jsonDecode(
            await File('${dir.path}${Platform.pathSeparator}conversations'
                    '${Platform.pathSeparator}c1.json')
                .readAsString())
        as Map<String, dynamic>;
    expect(raw['id'], 'c1');
  });

  test('dataUnchanged 只在未尝试提交或全部回滚成功时为 true', () {
    const notAttempted = BackupRestoreResult(
      ok: false,
      error: '校验失败',
    );
    expect(notAttempted.dataUnchanged, isTrue);

    const failedNoRollback = BackupRestoreResult(
      ok: false,
      error: '提交失败',
      commitAttempted: true,
    );
    expect(failedNoRollback.dataUnchanged, isFalse,
        reason: '空回滚列表不能等同于未写文件');

    const partial = BackupRestoreResult(
      ok: false,
      error: '提交失败',
      commitAttempted: true,
      rolledBackPaths: <String>['a.json'],
      rollbackFailedPaths: <String>['b.json'],
    );
    expect(partial.dataUnchanged, isFalse);

    const allRolledBack = BackupRestoreResult(
      ok: false,
      error: '提交失败',
      commitAttempted: true,
      rolledBackPaths: <String>['a.json'],
    );
    expect(allRolledBack.dataUnchanged, isTrue);
  });
}
