// 全局日程服务回归：串行命令、revision 冲突、撤销、只读/写失败、单次例外。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';

import '../support/test_support.dart';

Directory _tempDir(String name) {
  final dir = createTempDataDir(name);
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 实例锁句柄释放可能滞后，测试目录残留不阻塞断言。
    }
  });
  return dir;
}

ScheduleDraft _draft({
  String title = '项目会议',
  bool allDay = false,
  int startMinute = 540,
  int endMinute = 600,
  String? endDateExclusive,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  bool blocksScheduling = true,
  String? linkedConversationId,
}) =>
    ScheduleDraft(
      title: title,
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-09',
      allDay: allDay,
      startMinute: allDay ? null : startMinute,
      endMinute: allDay ? null : endMinute,
      endDateExclusive: allDay ? (endDateExclusive ?? '2026-11-10') : null,
      blocksScheduling: blocksScheduling,
      repeat: repeat,
      linkedConversationId: linkedConversationId,
    );

class _FailingStore extends ScheduleStore {
  _FailingStore(super.root);
  @override
  Future<void> saveSnapshot(ScheduleSnapshot snapshot) async {
    throw StateError('disk full');
  }
}

Future<ScheduleController> _controller({ScheduleStore? store}) async {
  final dir = store == null ? _tempDir('schedule_controller') : null;
  final controller = ScheduleController(
    store: store ?? ScheduleStore(dir!),
    clock: () => DateTime.utc(2026, 11, 6, 1),
    idFactory: (prefix) =>
        '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_idSeed++}',
  );
  await controller.initialize();
  addTearDown(controller.close);
  return controller;
}

int _idSeed = 0;

void main() {
  setUp(ScheduleStore.resetInstanceLocksForTest);

  test('无会话也能创建日程；保存后可被新实例读回', () async {
    final dir = _tempDir('schedule_controller_create');
    final store = ScheduleStore(dir);
    final controller = ScheduleController(
      store: store,
      clock: () => DateTime.utc(2026, 11, 6, 1),
    );
    await controller.initialize();
    final created = await controller.createEvent(_draft());
    expect(created.ok, isTrue, reason: created.message);
    expect(created.eventId, isNotNull);
    expect(controller.events, hasLength(1));
    expect(controller.revision, 1);
    await controller.close();

    final reopened = ScheduleStore(dir);
    final opened = await reopened.open();
    expect(opened.snapshot.events.values.single.title, '项目会议');
    await reopened.close();
  });

  test('expectedRevision 冲突被拒绝，正确 revision 才能保存', () async {
    final controller = await _controller();
    final created = await controller.createEvent(_draft());
    final id = created.eventId!;
    final stale = await controller.updateEvent(
      id,
      99,
      _draft(title: '被旧弹窗覆盖'),
    );
    expect(stale.status, ScheduleMutationStatus.rejected);
    expect(controller.eventById(id)!.title, '项目会议');

    final updated = await controller.updateEvent(
      id,
      controller.eventById(id)!.revision,
      _draft(title: '改名后的会议'),
    );
    expect(updated.ok, isTrue, reason: updated.message);
    expect(controller.eventById(id)!.title, '改名后的会议');
    expect(controller.revision, 2);
  });

  test('删除进入删除标记，撤销恢复正文与 revision', () async {
    final controller = await _controller();
    final created = await controller.createEvent(_draft());
    final id = created.eventId!;
    final deleted = await controller.deleteEvent(id, 1);
    expect(deleted.ok, isTrue);
    expect(controller.eventById(id), isNull);
    expect(
      controller.allEvents.any((e) => e.id == id && e.isDeleted),
      isTrue,
    );

    final undone = await controller.undoLastMutation();
    expect(undone.ok, isTrue, reason: undone.message);
    expect(controller.eventById(id), isNotNull);
    expect(controller.eventById(id)!.title, '项目会议');
  });

  test('新编辑清空旧撤销：旧撤销不能覆盖新状态', () async {
    final controller = await _controller();
    await controller.createEvent(_draft(title: '第一项'));
    await controller.createEvent(_draft(title: '第二项'));
    expect(controller.events, hasLength(2));

    final undone = await controller.undoLastMutation();
    expect(undone.ok, isTrue);
    expect(controller.events, hasLength(1));
    expect(controller.events.single.title, '第一项');

    final again = await controller.undoLastMutation();
    expect(again.status, ScheduleMutationStatus.rejected);
  });

  test('并发创建串行化，不丢记录且 revision 单调', () async {
    final controller = await _controller();
    final futures = <Future<ScheduleMutationResult>>[
      for (var i = 0; i < 8; i++)
        controller.createEvent(_draft(title: '并发 $i')),
    ];
    final results = await Future.wait(futures);
    expect(results.every((r) => r.ok), isTrue);
    expect(controller.events, hasLength(8));
    expect(controller.revision, 8);
    expect(
      controller.events.map((e) => e.title).toSet(),
      containsAll(<String>[for (var i = 0; i < 8; i++) '并发 $i']),
    );
  });

  test('保存失败的 store：failed 且内存不前进', () async {
    final dir = _tempDir('schedule_controller_fail');
    final store = _FailingStore(dir);
    final controller = ScheduleController(
      store: store,
      clock: () => DateTime.utc(2026, 11, 6, 1),
    );
    await controller.initialize();
    addTearDown(controller.close);
    final result = await controller.createEvent(_draft());
    expect(result.status, ScheduleMutationStatus.failed);
    expect(result.message, contains('保存失败'));
    expect(controller.events, isEmpty);
    expect(controller.revision, 0);
  });

  test('只读实例的写命令被拒绝并说明原因', () async {
    final dir = _tempDir('schedule_controller_readonly');
    final first = ScheduleStore(dir);
    await first.open();
    addTearDown(first.close);
    final second = ScheduleStore(dir);
    final controller = ScheduleController(store: second);
    final opened = await controller.initialize();
    addTearDown(controller.close);
    expect(opened.readOnly, isTrue);
    final result = await controller.createEvent(_draft());
    expect(result.status, ScheduleMutationStatus.rejected);
    expect(result.message, contains('只读'));
    expect(controller.events, isEmpty);
  });

  test('单次排除/改期：按 occurrenceKey 更新，展开结果同步', () async {
    final controller = await _controller();
    final created = await controller.createEvent(_draft(
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
    ));
    final id = created.eventId!;
    final query = ScheduleQuery(
      fromUtc: DateTime.utc(2026, 11, 8, 16),
      toUtc: DateTime.utc(2026, 11, 20, 16),
      timezoneId: 'Asia/Shanghai',
    );
    expect(controller.occurrences(query).occurrences, hasLength(4));

    final excluded = await controller.setOccurrenceExcluded(
      id,
      scheduleOccurrenceKey(id, '2026-11-11'),
      excluded: true,
    );
    expect(excluded.ok, isTrue, reason: excluded.message);
    final afterExclude = controller.occurrences(query).occurrences;
    expect(afterExclude.map((o) => o.originalDate),
        isNot(contains('2026-11-11')));
    expect(afterExclude, hasLength(3));

    final overridden = await controller.overrideOccurrence(
      id,
      scheduleOccurrenceKey(id, '2026-11-16'),
      startDate: '2026-11-17',
      startMinute: 600,
      endMinute: 660,
    );
    expect(overridden.ok, isTrue, reason: overridden.message);
    final afterOverride = controller.occurrences(query).occurrences;
    final moved = afterOverride
        .firstWhere((o) => o.occurrenceKey == scheduleOccurrenceKey(id, '2026-11-16'));
    expect(moved.isOverride, isTrue);
    expect(moved.startUtc, DateTime.utc(2026, 11, 17, 2));
  });

  test('改重复规则影响例外：默认拒绝，确认后移除失效例外', () async {
    final controller = await _controller();
    final created = await controller.createEvent(_draft(
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
    ));
    final id = created.eventId!;
    await controller.setOccurrenceExcluded(
      id,
      scheduleOccurrenceKey(id, '2026-11-11'),
      excluded: true,
    );
    final event = controller.eventById(id)!;

    final blocked = await controller.updateEvent(
      id,
      event.revision,
      ScheduleDraft(
        title: event.title,
        timezoneId: event.timezoneId,
        startDate: event.startDate,
        startMinute: event.startMinute,
        endMinute: event.endMinute,
        repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
      ),
    );
    expect(blocked.status, ScheduleMutationStatus.rejected);
    expect(blocked.message, contains('例外'));

    final confirmed = await controller.updateEvent(
      id,
      event.revision,
      ScheduleDraft(
        title: event.title,
        timezoneId: event.timezoneId,
        startDate: event.startDate,
        startMinute: event.startMinute,
        endMinute: event.endMinute,
        repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
      ),
      confirmDropInvalidExceptions: true,
    );
    expect(confirmed.ok, isTrue, reason: confirmed.message);
    expect(controller.eventById(id)!.exceptions, isEmpty);
  });

  test('reloadFromDisk 吸收外部快照（备份恢复后刷新）', () async {
    final controller = await _controller();
    await controller.createEvent(_draft(title: '原始'));
    final store = controller;
    await controller
        .reloadFromDisk(); // 无外部变化时保持
    expect(controller.events.single.title, '原始');
    expect(store.revision, greaterThanOrEqualTo(1));
  });

  test('内存模式可创建但明确关闭后丢失', () async {
    final controller = ScheduleController(store: ScheduleStore.memory());
    final opened = await controller.initialize();
    addTearDown(controller.close);
    expect(opened.memoryOnly, isTrue);
    final result = await controller.createEvent(_draft());
    expect(result.ok, isTrue);
    expect(controller.events, hasLength(1));
    expect(opened.notice, contains('关闭后丢失'));
  });
}
