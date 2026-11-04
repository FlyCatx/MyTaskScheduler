// 存储测试：原子写 + .bak 回退、损坏留证、更新版本只读、内存模式、
// 多实例互斥只读、备份恢复按 recordId 幂等、检查点保存/清除。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_store.dart';

import 'execution_test_support.dart';

DateTime get _t0 => DateTime.utc(2026, 11, 4, 1);

ExecutionRecord _record(String id, {DateTime? end}) => recordWithInterval(
      recordId: id,
      startUtc: _t0,
      endUtc: end ?? _t0.add(const Duration(hours: 1)),
    );

void main() {
  test('原子写与 .bak 回退：主文件损坏时找回上一份完整账本', () async {
    final dir = newTempDir('store_bak');
    addTearDown(() => deleteDirQuietly(dir));
    final store = ExecutionStore(dir);
    await store.open();
    store.ledger.addRecord(_record('rec-1'));
    await store.persistLedger();
    store.ledger.addRecord(_record('rec-2'));
    await store.persistLedger();
    await store.close();

    final mainFile = File('${dir.path}${Platform.pathSeparator}execution'
        '${Platform.pathSeparator}ledger.json');
    final bakFile = File('${mainFile.path}.bak');
    expect(mainFile.existsSync(), true);
    expect(bakFile.existsSync(), true, reason: '第二次写入前要保留上一份副本');

    // 模拟崩溃/杀毒软件造成的半份文件。
    mainFile.writeAsStringSync('{"schemaVersion":1,"records":[');

    final reopened = ExecutionStore(dir);
    final result = await reopened.open();
    addTearDown(() async => reopened.close());
    expect(result.recoveredFromBackup, true);
    expect(result.notice, contains('.bak'));
    expect(reopened.ledger.records.length, 1,
        reason: '.bak 里是上一次成功写入的完整账本');
    expect(reopened.readOnly, false, reason: '能从 .bak 恢复就可以继续写入');
  });

  test('主文件与备份都损坏：保留损坏文件证据并使用空账本', () async {
    final dir = newTempDir('store_corrupt');
    addTearDown(() => deleteDirQuietly(dir));
    final store = ExecutionStore(dir);
    await store.open();
    store.ledger.addRecord(_record('rec-1'));
    await store.persistLedger();
    store.ledger.addRecord(_record('rec-2'));
    await store.persistLedger();
    await store.close();

    final executionDir = Directory('${dir.path}${Platform.pathSeparator}execution');
    File('${executionDir.path}${Platform.pathSeparator}ledger.json')
        .writeAsStringSync('not json at all');
    File('${executionDir.path}${Platform.pathSeparator}ledger.json.bak')
        .writeAsStringSync('also broken');

    final reopened = ExecutionStore(dir);
    final result = await reopened.open();
    addTearDown(() async => reopened.close());
    expect(result.corruptFallback, true);
    expect(result.notice, contains('损坏'));
    expect(reopened.ledger.records, isEmpty);
    expect(reopened.readOnly, false, reason: '损坏文件已另存，能继续记录新数据');
    final quarantined = executionDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(quarantined, isNotEmpty, reason: '损坏文件必须留证而不是直接覆盖');
  });

  test('账本来自更新版本：只读且拒绝覆盖', () async {
    final dir = newTempDir('store_newer');
    addTearDown(() => deleteDirQuietly(dir));
    final executionDir = Directory('${dir.path}${Platform.pathSeparator}execution');
    executionDir.createSync(recursive: true);
    File('${executionDir.path}${Platform.pathSeparator}ledger.json')
        .writeAsStringSync(jsonEncode(<String, dynamic>{
      'schemaVersion': 99,
      'records': <dynamic>[],
    }));

    final store = ExecutionStore(dir);
    final result = await store.open();
    addTearDown(() async => store.close());
    expect(result.readOnly, true);
    expect(result.newerSchema, true);
    expect(result.notice, contains('更新'));
    expect(
      () => store.persistLedger(),
      throwsA(isA<ExecutionReadOnlyException>()),
    );

    // 文件内容不能被旧版本改写。
    final raw = File('${executionDir.path}${Platform.pathSeparator}ledger.json')
        .readAsStringSync();
    expect(raw, contains('99'));
  });

  test('多实例同数据目录：第二实例只读，第一实例释放后可写', () async {
    final dir = newTempDir('store_lock');
    addTearDown(() => deleteDirQuietly(dir));
    final first = ExecutionStore(dir);
    await first.open();
    expect(first.readOnly, false);

    final second = ExecutionStore(dir);
    final secondResult = await second.open();
    expect(secondResult.readOnly, true);
    expect(secondResult.lockConflict, true);
    expect(secondResult.notice, contains('另一个'));
    expect(
      () => second.persistLedger(),
      throwsA(isA<ExecutionReadOnlyException>()),
    );
    // 只读实例仍可查看账本事实。
    expect(second.ledger.records, isEmpty);

    await first.close();
    final third = ExecutionStore(dir);
    final thirdResult = await third.open();
    addTearDown(() async => third.close());
    expect(thirdResult.readOnly, false);
    expect(thirdResult.lockConflict, false);
    await second.close();
  });

  test('内存模式：可读写但从不声称持久化', () async {
    final store = ExecutionStore.memory();
    final result = await store.open();
    expect(result.readOnly, false);
    store.ledger.addRecord(_record('rec-1'));
    await store.persistLedger();
    expect(store.ledger.records.length, 1);
    expect(store.isMemoryOnly, true);
    await store.saveCheckpoint(TimerCheckpoint(
      recordId: 'rec-1',
      conversationId: 'conv-1',
      taskId: 'task-a',
      taskName: '整理需求',
      planVersionId: 'ver-1',
      planRevision: 1,
      phase: TimerPhase.paused,
      sessionStartedAtUtc: _t0,
      checkpointUtc: _t0.add(const Duration(minutes: 5)),
      timeZoneName: 'Asia/Shanghai (UTC+08:00)',
      timeZoneOffsetMinutes: 480,
    ));
    expect(store.checkpoint, isNotNull);
    await store.clearCheckpoint();
    expect(store.checkpoint, isNull);
    await store.close();
  });

  test('检查点保存后重开可恢复，清除后不再恢复', () async {
    final dir = newTempDir('store_checkpoint');
    addTearDown(() => deleteDirQuietly(dir));
    final store = ExecutionStore(dir);
    await store.open();
    final checkpoint = TimerCheckpoint(
      recordId: 'rec-1',
      conversationId: 'conv-1',
      taskId: 'task-a',
      taskName: '整理需求',
      planVersionId: 'ver-1',
      planRevision: 1,
      phase: TimerPhase.running,
      sessionStartedAtUtc: _t0,
      checkpointUtc: _t0.add(const Duration(seconds: 15)),
      openIntervalStartUtc: _t0,
      timeZoneName: 'Asia/Shanghai (UTC+08:00)',
      timeZoneOffsetMinutes: 480,
    );
    await store.saveCheckpoint(checkpoint);
    await store.close();

    final reopened = ExecutionStore(dir);
    final result = await reopened.open();
    expect(result.checkpoint, isNotNull);
    expect(result.checkpoint!.phase, TimerPhase.running);
    expect(result.checkpoint!.openIntervalStartUtc, _t0);
    await reopened.clearCheckpoint();
    expect(reopened.checkpoint, isNull);
    await reopened.close();

    final again = ExecutionStore(dir);
    final resultAgain = await again.open();
    expect(resultAgain.checkpoint, isNull);
    await again.close();
  });

  test('恢复备份按 recordId 幂等合并并原子保存', () async {
    final dir = newTempDir('store_merge');
    addTearDown(() => deleteDirQuietly(dir));
    final store = ExecutionStore(dir);
    await store.open();
    store.ledger.addRecord(_record('rec-1',
        end: _t0.add(const Duration(hours: 2))));
    await store.persistLedger();

    final imported = ExecutionLedger(records: <ExecutionRecord>[
      // 同一 recordId、不同内容：本地事实优先。
      _record('rec-1', end: _t0.add(const Duration(hours: 9))),
      _record('rec-2'),
    ]);
    final merged = await store.mergeRestored(imported);
    expect(merged.addedRecords, 1);
    expect(merged.skippedRecords, 1);
    expect(store.ledger.recordById('rec-1')!.intervals.first.endUtc,
        _t0.add(const Duration(hours: 2)));

    final again = await store.mergeRestored(imported);
    expect(again.changed, false, reason: '重复恢复不重复累计');
    await store.close();

    final reopened = ExecutionStore(dir);
    final result = await reopened.open();
    expect(result.ledger.records.length, 2);
    await reopened.close();
  });
}
