// 日程存储回归：原子保存、备份回退、坏文件/未来 schema 只读、实例锁、内存模式。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';

import '../support/test_support.dart';

Directory _tempDir(String name) {
  final dir = createTempDataDir(name);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上实例锁句柄释放可能滞后；测试目录残留不阻塞断言。
    }
  });
  return dir;
}

Directory _schedulesDir(Directory root) =>
    Directory('${root.path}${Platform.pathSeparator}schedules');

File _eventsFileOf(Directory root) => File(
    '${_schedulesDir(root).path}${Platform.pathSeparator}events.json');

ScheduleEvent _event(String id, {bool deleted = false}) => ScheduleEvent(
      id: id,
      revision: 1,
      title: '会议 $id',
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-09',
      startMinute: 540,
      endMinute: 600,
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 1),
      deletedAtUtc: deleted ? DateTime.utc(2026, 11, 2) : null,
    );

ScheduleSnapshot _snapshot(int revision, List<ScheduleEvent> events) =>
    ScheduleSnapshot(
      revision: revision,
      events: <String, ScheduleEvent>{
        for (final event in events) event.id: event,
      },
    );

void main() {
  setUp(ScheduleStore.resetInstanceLocksForTest);
  tearDown(ScheduleStore.resetInstanceLocksForTest);

  test('保存后重开仍是同一快照（含删除标记）', () async {
    final dir = _tempDir('schedule_store_roundtrip');
    final store = ScheduleStore(dir);
    final opened = await store.open();
    expect(opened.readOnly, isFalse);
    await store.saveSnapshot(_snapshot(3, <ScheduleEvent>[
      _event('ev-1'),
      _event('ev-2', deleted: true),
    ]));
    await store.close();

    final reopened = ScheduleStore(dir);
    final result = await reopened.open();
    expect(result.snapshot.revision, 3);
    expect(result.snapshot.events.keys, containsAll(<String>['ev-1', 'ev-2']));
    expect(result.snapshot.events['ev-2']!.isDeleted, isTrue);
    await reopened.close();
  });

  test('主文件损坏时回退 .bak', () async {
    final dir = _tempDir('schedule_store_backup');
    final store = ScheduleStore(dir);
    await store.open();
    await store.saveSnapshot(_snapshot(1, <ScheduleEvent>[_event('ev-1')]));
    await store.saveSnapshot(_snapshot(2, <ScheduleEvent>[_event('ev-1'), _event('ev-2')]));
    await store.close();

    // 主文件写坏，.bak 仍是上一份完整快照。
    await _eventsFileOf(dir).writeAsString('{broken');
    final reopened = ScheduleStore(dir);
    final result = await reopened.open();
    expect(result.recoveredFromBackup, isTrue);
    expect(result.snapshot.revision, 1);
    expect(result.snapshot.events.keys, <String>['ev-1']);
    expect(result.readOnly, isFalse);
    await reopened.close();
  });

  test('主文件与备份都坏：只读、保留文件、不写空库', () async {
    final dir = _tempDir('schedule_store_corrupt');
    final store = ScheduleStore(dir);
    await store.open();
    await store.saveSnapshot(_snapshot(1, <ScheduleEvent>[_event('ev-1')]));
    await store.close();
    final main = _eventsFileOf(dir);
    await main.writeAsString('{broken');
    await File('${main.path}.bak').writeAsString('also broken');

    final reopened = ScheduleStore(dir);
    final result = await reopened.open();
    expect(result.readOnly, isTrue);
    expect(result.corruptFallback, isTrue);
    expect(result.notice, isNotNull);
    expect(await main.exists(), isTrue);
    await expectLater(
      reopened.saveSnapshot(_snapshot(2, <ScheduleEvent>[_event('ev-1')])),
      throwsA(isA<ScheduleReadOnlyException>()),
    );
    await reopened.close();
  });

  test('更新版本的 schema：只读，不降级覆盖', () async {
    final dir = _tempDir('schedule_store_future');
    final schedules = _schedulesDir(dir);
    await schedules.create(recursive: true);
    final main = _eventsFileOf(dir);
    await main.writeAsString(jsonEncode(<String, dynamic>{
      'schemaVersion': kScheduleSchemaVersion + 1,
      'revision': 9,
      'events': <dynamic>[],
    }));

    final store = ScheduleStore(dir);
    final result = await store.open();
    expect(result.readOnly, isTrue);
    expect(result.newerSchema, isTrue);
    await expectLater(
      store.saveSnapshot(_snapshot(10, <ScheduleEvent>[])),
      throwsA(isA<ScheduleReadOnlyException>()),
    );
    await store.close();
  });

  test('第二个实例只读并提示锁冲突', () async {
    final dir = createTempDataDir('schedule_store_lock');
    addTearDown(() => dir.delete(recursive: true));
    final first = ScheduleStore(dir);
    final firstResult = await first.open();
    expect(firstResult.readOnly, isFalse);
    final second = ScheduleStore(dir);
    final secondResult = await second.open();
    expect(secondResult.lockConflict, isTrue);
    expect(secondResult.readOnly, isTrue);
    expect(secondResult.notice, contains('另一个'));
    await second.close();
    await first.close();
  });

  test('内存模式只保存在内存，重开为空', () async {
    final store = ScheduleStore.memory();
    final result = await store.open();
    expect(result.memoryOnly, isTrue);
    expect(result.notice, contains('关闭后丢失'));
    await store.saveSnapshot(_snapshot(1, <ScheduleEvent>[_event('ev-1')]));
    expect(store.snapshot.events, hasLength(1));

    final reopened = ScheduleStore.memory();
    final again = await reopened.open();
    expect(again.snapshot.events, isEmpty);
    await reopened.close();
  });

  test('单条事件不合法时整库判为损坏（不读取半个库）', () async {
    final dir = createTempDataDir('schedule_store_bad_event');
    addTearDown(() => dir.delete(recursive: true));
    final schedules = _schedulesDir(dir);
    await schedules.create(recursive: true);
    final main = _eventsFileOf(dir);
    final badEvent = _event('ev-1').toJson()..['startMinute'] = 700;
    await main.writeAsString(jsonEncode(<String, dynamic>{
      'schemaVersion': kScheduleSchemaVersion,
      'revision': 1,
      'events': <dynamic>[
        _event('ev-0').toJson(),
        badEvent,
      ],
    }));
    final store = ScheduleStore(dir);
    final result = await store.open();
    expect(result.readOnly, isTrue);
    expect(result.corruptFallback, isTrue);
    await store.close();
  });
}
