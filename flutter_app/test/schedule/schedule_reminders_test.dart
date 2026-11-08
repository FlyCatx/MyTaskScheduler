// 应用运行期间日程提醒的定向回归（任务 6）：
// 提前量/全天/时区、同轮合并与去重、启动补报窗口、重启不洪泛、仅改备注、
// 改期/删除、时钟前跳与回拨、只读实例、发送拒绝、发送异常、去重保存失败、
// stop 后不再发送、内存模式与备份恢复抑制补报。
//
// 全部用注入的可变 clock + 手动 tick 推进，不等待真实分钟。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_reminders.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';

import '../support/test_support.dart';

int _idSeed = 0;

class _SentNotification {
  const _SentNotification(this.title, this.body);

  final String title;
  final String body;
}

class _TestClock {
  _TestClock(this.utc);

  DateTime utc;

  DateTime now() => utc;
}

ScheduleDraft _timedDraft({
  String title = '会议',
  String timezoneId = 'Asia/Shanghai',
  String startDate = '2026-11-09',
  int startMinute = 14 * 60,
  int endMinute = 15 * 60,
  ScheduleReminderKind reminder = ScheduleReminderKind.atStart,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  String? notes,
}) =>
    ScheduleDraft(
      title: title,
      timezoneId: timezoneId,
      startDate: startDate,
      startMinute: startMinute,
      endMinute: endMinute,
      repeat: repeat,
      reminder: reminder,
      notes: notes,
    );

ScheduleDraft _allDayDraft({
  String title = '纪念日',
  String timezoneId = 'Asia/Shanghai',
  String startDate = '2026-11-09',
  String endDateExclusive = '2026-11-10',
  ScheduleReminderKind reminder = ScheduleReminderKind.allDaySameDay,
}) =>
    ScheduleDraft(
      title: title,
      timezoneId: timezoneId,
      startDate: startDate,
      allDay: true,
      endDateExclusive: endDateExclusive,
      reminder: reminder,
    );

/// 从已有事件生成编辑草稿（只覆盖本次要改的字段）。
ScheduleDraft _draftFromEvent(
  ScheduleEvent event, {
  String? title,
  String? notes,
  String? startDate,
  int? startMinute,
  int? endMinute,
  ScheduleReminderKind? reminder,
}) =>
    ScheduleDraft(
      title: title ?? event.title,
      location: event.location,
      notes: notes ?? event.notes,
      category: event.category,
      timezoneId: event.timezoneId,
      allDay: event.allDay,
      startDate: startDate ?? event.startDate,
      startMinute: event.allDay ? null : (startMinute ?? event.startMinute),
      endMinute: event.allDay ? null : (endMinute ?? event.endMinute),
      endDateExclusive: event.allDay ? event.endDateExclusive : null,
      blocksScheduling: event.blocksScheduling,
      linkedConversationId: event.linkedConversationId,
      repeat: event.repeat,
      reminder: reminder ?? event.reminder,
    );

class _FailingReminderSaveStore extends ScheduleStore {
  _FailingReminderSaveStore(super.root);

  @override
  Future<void> saveReminderState(Map<String, dynamic> state) async {
    throw StateError('disk full');
  }
}

class _Harness {
  _Harness(
      {required DateTime now, ScheduleStore Function(Directory)? storeFactory})
      : clock = _TestClock(now) {
    dir = createTempDataDir('schedule_reminders');
    store = storeFactory?.call(dir) ?? ScheduleStore(dir);
    controller = ScheduleController(
      store: store,
      clock: clock.now,
      idFactory: (prefix) => '$prefix-${_idSeed++}',
    );
  }

  final _TestClock clock;
  late final Directory dir;
  late final ScheduleStore store;
  late final ScheduleController controller;

  final List<_SentNotification> attempts = <_SentNotification>[];
  final List<_SentNotification> accepted = <_SentNotification>[];
  final List<String> notices = <String>[];
  final List<ScheduleReminderService> _services = <ScheduleReminderService>[];

  int sendAttempts = 0;
  bool accept = true;
  Object? sendError;

  DateTime get now => clock.utc;
  set now(DateTime value) => clock.utc = value;

  Future<void> initialize() => controller.initialize();

  ScheduleReminderService makeService({
    Duration tickInterval = const Duration(hours: 1),
    Duration catchUpWindow = const Duration(minutes: 15),
    Duration retryDelay = Duration.zero,
    int maxSendAttempts = 3,
  }) {
    final service = ScheduleReminderService(
      controller: controller,
      store: store,
      send: (title, body) async {
        sendAttempts++;
        final notification = _SentNotification(title, body);
        attempts.add(notification);
        final error = sendError;
        if (error != null) throw error;
        if (!accept) return false;
        accepted.add(notification);
        return true;
      },
      clock: clock.now,
      tickInterval: tickInterval,
      catchUpWindow: catchUpWindow,
      retryDelay: retryDelay,
      maxSendAttempts: maxSendAttempts,
      onNotice: notices.add,
    );
    _services.add(service);
    return service;
  }

  Future<String> create(ScheduleDraft draft) async {
    final result = await controller.createEvent(draft);
    expect(result.ok, isTrue, reason: result.message);
    return result.eventId!;
  }

  Future<void> disposeAll() async {
    for (final service in _services.reversed) {
      await service.dispose();
    }
    await controller.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上锁句柄释放可能滞后；测试目录残留不阻塞断言。
    }
  }
}

void main() {
  setUp(ScheduleStore.resetInstanceLocksForTest);

  test('定时提醒按提前量计算触发 UTC；无提醒日程不进入计划', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 8, 0, 0));
    addTearDown(h.disposeAll);
    await h.initialize();
    // 本地 2026-11-09 14:00（Asia/Shanghai）= 2026-11-09 06:00Z。
    await h
        .create(_timedDraft(title: '无提醒', reminder: ScheduleReminderKind.none));
    for (final kind in <ScheduleReminderKind>[
      ScheduleReminderKind.atStart,
      ScheduleReminderKind.minutes5,
      ScheduleReminderKind.minutes15,
      ScheduleReminderKind.minutes30,
      ScheduleReminderKind.dayBefore,
    ]) {
      await h.create(_timedDraft(title: kind.label, reminder: kind));
    }
    final service = h.makeService();
    await service.start();

    expect(service.plan, hasLength(5));
    expect(service.plan.any((item) => item.title == '无提醒'), isFalse);
    final triggers = <ScheduleReminderKind, DateTime>{
      for (final item in service.plan) item.reminder: item.triggerUtc,
    };
    expect(
        triggers[ScheduleReminderKind.atStart], DateTime.utc(2026, 11, 9, 6));
    expect(triggers[ScheduleReminderKind.minutes5],
        DateTime.utc(2026, 11, 9, 5, 55));
    expect(triggers[ScheduleReminderKind.minutes15],
        DateTime.utc(2026, 11, 9, 5, 45));
    expect(triggers[ScheduleReminderKind.minutes30],
        DateTime.utc(2026, 11, 9, 5, 30));
    expect(
        triggers[ScheduleReminderKind.dayBefore], DateTime.utc(2026, 11, 8, 6));

    Future<void> expectSendAt(DateTime when, String titlePart) async {
      h.now = when;
      final before = h.accepted.length;
      await service.tick();
      expect(h.accepted, hasLength(before + 1), reason: 'trigger $when');
      expect(h.accepted.last.body, contains(titlePart));
    }

    await expectSendAt(DateTime.utc(2026, 11, 8, 6), '提前 1 天');
    await expectSendAt(DateTime.utc(2026, 11, 9, 5, 30), '提前 30 分钟');
    await expectSendAt(DateTime.utc(2026, 11, 9, 5, 45), '提前 15 分钟');
    await expectSendAt(DateTime.utc(2026, 11, 9, 5, 55), '提前 5 分钟');
    await expectSendAt(DateTime.utc(2026, 11, 9, 6), '开始时');
    expect(h.sendAttempts, 5);
  });

  test('全天提醒：当天/前一天按事件时区 09:00', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 8, 0, 0));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_allDayDraft(
      title: '当天纪念日',
      reminder: ScheduleReminderKind.allDaySameDay,
    ));
    await h.create(_allDayDraft(
      title: '前一天纪念日',
      reminder: ScheduleReminderKind.allDayPrevDay,
    ));
    final service = h.makeService();
    await service.start();
    final triggers = <ScheduleReminderKind, DateTime>{
      for (final item in service.plan) item.reminder: item.triggerUtc,
    };
    // Asia/Shanghai 09:00 = 01:00Z。
    expect(triggers[ScheduleReminderKind.allDayPrevDay],
        DateTime.utc(2026, 11, 8, 1));
    expect(triggers[ScheduleReminderKind.allDaySameDay],
        DateTime.utc(2026, 11, 9, 1));

    h.now = DateTime.utc(2026, 11, 8, 1);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.accepted.last.body, contains('前一天纪念日'));
    expect(h.accepted.last.body, contains('全天日程'));

    h.now = DateTime.utc(2026, 11, 9, 1);
    await service.tick();
    expect(h.accepted, hasLength(2));
    expect(h.accepted.last.body, contains('当天纪念日'));
  });

  test('时区：纽约日程的定时提醒与全天 09:00 按事件时区换算', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 8, 0, 0));
    addTearDown(h.disposeAll);
    await h.initialize();
    // 2026-11-09 纽约是 EST（UTC-5）：14:00 本地 = 19:00Z；09:00 本地 = 14:00Z。
    await h.create(_timedDraft(
      title: '纽约会议',
      timezoneId: 'America/New_York',
      startMinute: 14 * 60,
      endMinute: 15 * 60,
      reminder: ScheduleReminderKind.atStart,
    ));
    await h.create(_allDayDraft(
      title: '纽约纪念日',
      timezoneId: 'America/New_York',
      reminder: ScheduleReminderKind.allDaySameDay,
    ));
    final service = h.makeService();
    await service.start();
    final triggers = <String, DateTime>{
      for (final item in service.plan) item.title: item.triggerUtc,
    };
    expect(triggers['纽约会议'], DateTime.utc(2026, 11, 9, 19));
    expect(triggers['纽约纪念日'], DateTime.utc(2026, 11, 9, 14));

    h.now = DateTime.utc(2026, 11, 9, 14);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.accepted.last.body, contains('纽约纪念日'));

    h.now = DateTime.utc(2026, 11, 9, 19);
    await service.tick();
    expect(h.accepted, hasLength(2));
    expect(h.accepted.last.body, contains('纽约会议'));
    expect(h.accepted.last.body, contains('14:00'));
    expect(h.accepted.last.body, contains('America/New_York'));
  });

  test('同一轮多条到期合并为一条；重启不重复提醒', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 59));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '会议甲'));
    await h.create(_timedDraft(title: '会议乙'));
    final service = h.makeService();
    await service.start();
    expect(h.sendAttempts, 0);

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.sendAttempts, 1);
    expect(h.accepted, hasLength(1));
    expect(h.accepted.single.title, contains('2 条'));
    expect(h.accepted.single.body, contains('会议甲'));
    expect(h.accepted.single.body, contains('会议乙'));
    expect(h.store.reminderStateFile.existsSync(), isTrue);

    // 同一时刻重复 tick 不重发。
    await service.tick();
    expect(h.sendAttempts, 1);

    // 模拟重启：新服务读同一份去重状态，不因 15 分钟补报窗口再弹一次。
    await service.stop();
    final restarted = h.makeService();
    h.now = DateTime.utc(2026, 11, 9, 6, 1);
    await restarted.start();
    await restarted.tick();
    expect(h.sendAttempts, 1);
  });

  test('启动只补报过去 15 分钟内到期项并合并；更早不逐条', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 6, 10));
    addTearDown(h.disposeAll);
    await h.initialize();
    // 06:00Z / 06:05Z 到期，距 now 分别 10/5 分钟，都在补报窗口内。
    await h.create(_timedDraft(title: '迟到甲'));
    await h.create(_timedDraft(
        title: '迟到乙', startMinute: 14 * 60 + 5, endMinute: 15 * 60 + 5));
    final service = h.makeService();
    await service.start();
    expect(h.sendAttempts, 1);
    expect(h.accepted.single.title, contains('2 条'));
    expect(h.accepted.single.body, contains('迟到甲'));
    expect(h.accepted.single.body, contains('迟到乙'));

    // 超过补报窗口的到期项不逐条弹出。
    final older = _Harness(now: DateTime.utc(2026, 11, 9, 6, 20));
    addTearDown(older.disposeAll);
    await older.initialize();
    await older.create(_timedDraft(title: '太早了'));
    final olderService = older.makeService();
    await olderService.start();
    expect(older.sendAttempts, 0);
  });

  test('仅改备注/标题不重发', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 50));
    addTearDown(h.disposeAll);
    await h.initialize();
    final id = await h.create(_timedDraft(title: '会议'));
    final service = h.makeService();
    await service.start();

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.accepted, hasLength(1));

    final event = h.controller.eventById(id)!;
    final notesChanged = await h.controller.updateEvent(
      id,
      event.revision,
      _draftFromEvent(event, notes: '只改备注，不应重发'),
    );
    expect(notesChanged.ok, isTrue, reason: notesChanged.message);
    await service.tick();
    expect(h.accepted, hasLength(1), reason: '仅改备注不得重发');
    expect(h.sendAttempts, 1);

    final renamed = h.controller.eventById(id)!;
    final titleChanged = await h.controller.updateEvent(
      id,
      renamed.revision,
      _draftFromEvent(renamed, title: '改名也不重发'),
    );
    expect(titleChanged.ok, isTrue, reason: titleChanged.message);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.sendAttempts, 1);
  });

  test('改期清理旧触发项，删除清理对应计划', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 50));
    addTearDown(h.disposeAll);
    await h.initialize();
    final id = await h.create(_timedDraft(title: '会议'));
    final service = h.makeService();
    await service.start();

    // 05:52 把 14:00 改到 15:00（07:00Z）：旧 06:00Z 触发项必须消失。
    h.now = DateTime.utc(2026, 11, 9, 5, 52);
    final event = h.controller.eventById(id)!;
    final moved = await h.controller.updateEvent(
      id,
      event.revision,
      _draftFromEvent(event, startMinute: 15 * 60, endMinute: 16 * 60),
    );
    expect(moved.ok, isTrue, reason: moved.message);
    await service.tick();

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.accepted, isEmpty, reason: '旧触发项已清理');

    h.now = DateTime.utc(2026, 11, 9, 7);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.accepted.last.body, contains('15:00'));

    // 新增一个未来日程再删除：到点不得发送。
    final deletedId = await h.create(_timedDraft(
      title: '将被删除',
      startMinute: 16 * 60,
      endMinute: 17 * 60,
    ));
    final beforeDelete = h.controller.eventById(deletedId)!;
    final deleted = await h.controller.deleteEvent(
      deletedId,
      beforeDelete.revision,
    );
    expect(deleted.ok, isTrue, reason: deleted.message);
    h.now = DateTime.utc(2026, 11, 9, 8);
    await service.tick();
    expect(h.sendAttempts, 1);
    expect(h.accepted, hasLength(1));
  });

  test('时钟前跳只补一次、回拨不重发、大幅前跳不洪泛', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 50));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '会议'));
    await h.create(_timedDraft(
      title: '后一场',
      startMinute: 15 * 60,
      endMinute: 16 * 60,
    ));
    final service = h.makeService();
    await service.start();

    // 前跳 5 分钟：仍在补报窗口内，补发一次。
    h.now = DateTime.utc(2026, 11, 9, 6, 5);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.accepted.single.body, contains('会议'));

    // 回拨 10 分钟：已接受的触发项不重发。
    h.now = DateTime.utc(2026, 11, 9, 5, 55);
    await service.tick();
    expect(h.accepted, hasLength(1));

    // 再次前跳到已接受时刻：仍不重发。
    h.now = DateTime.utc(2026, 11, 9, 6, 10);
    await service.tick();
    expect(h.accepted, hasLength(1));

    // 大幅前跳 2 小时：07:00Z 已过期 60 分钟，超过补报窗口，不逐条弹。
    h.now = DateTime.utc(2026, 11, 9, 8);
    await service.tick();
    expect(h.accepted, hasLength(1));
    expect(h.sendAttempts, 1);
  });

  test('只读第二实例不发送提醒、不写去重状态', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 59));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '只读日程'));

    final secondStore = ScheduleStore(h.dir);
    final secondController =
        ScheduleController(store: secondStore, clock: h.clock.now);
    final opened = await secondController.initialize();
    addTearDown(secondController.close);
    expect(opened.readOnly, isTrue);

    final service = ScheduleReminderService(
      controller: secondController,
      store: secondStore,
      send: (title, body) async {
        h.sendAttempts++;
        h.accepted.add(_SentNotification(title, body));
        return true;
      },
      clock: h.clock.now,
      tickInterval: const Duration(hours: 1),
      retryDelay: Duration.zero,
    );
    addTearDown(service.dispose);
    await service.start();
    expect(service.deliversNotifications, isFalse);

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.sendAttempts, 0);
    expect(secondStore.reminderStateFile.existsSync(), isFalse);
  });

  test('发送被 OS 拒绝：当前进程有限重试并提示，重启不重复', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 59));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '会议'));
    h.accept = false;
    final service = h.makeService(maxSendAttempts: 3);
    await service.start();

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.sendAttempts, 3, reason: '有限重试');
    expect(h.accepted, isEmpty);
    expect(service.dispatchHalted, isFalse);
    expect(service.lastNotice, contains('系统通知'));

    await service.tick();
    expect(h.sendAttempts, 3, reason: '拒绝后不无界重试');

    await service.stop();
    final restarted = h.makeService();
    h.now = DateTime.utc(2026, 11, 9, 6, 1);
    await restarted.start();
    await restarted.tick();
    expect(h.sendAttempts, 3, reason: 'rejected 已持久化，重启不重复');
  });

  test('发送回调抛出（通知不可用）：按失败处理并提示', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 59));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '会议'));
    h.sendError = StateError('bridge down');
    final service = h.makeService(maxSendAttempts: 2);
    await service.start();

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.sendAttempts, 2);
    expect(h.accepted, isEmpty);
    expect(service.lastSendError, contains('bridge down'));
    expect(service.lastNotice, contains('发送失败'));
  });

  test('去重状态保存失败：不发送并停止后续自动派发', () async {
    var now = DateTime.utc(2026, 11, 9, 5, 59);
    final dir = createTempDataDir('schedule_reminders_save_fail');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 忽略测试目录清理失败。
      }
    });
    final store = _FailingReminderSaveStore(dir);
    final controller = ScheduleController(store: store, clock: () => now);
    await controller.initialize();
    addTearDown(controller.close);
    final created = await controller.createEvent(_timedDraft(title: '会议'));
    expect(created.ok, isTrue, reason: created.message);

    final attempts = <String>[];
    final notices = <String>[];
    final service = ScheduleReminderService(
      controller: controller,
      store: store,
      send: (title, body) async {
        attempts.add(title);
        return true;
      },
      clock: () => now,
      tickInterval: const Duration(hours: 1),
      retryDelay: Duration.zero,
      onNotice: notices.add,
    );
    addTearDown(service.dispose);
    await service.start();

    now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(attempts, isEmpty, reason: '没有去重依据时不发送');
    expect(service.dispatchHalted, isTrue);
    expect(notices.any((message) => message.contains('保存失败')), isTrue);

    now = DateTime.utc(2026, 11, 9, 7);
    await service.tick();
    expect(attempts, isEmpty, reason: '停止后不再自动派发');
  });

  test('stop 后不再发送', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 50));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(title: '会议'));
    final service = h.makeService();
    await service.start();
    await service.stop();
    expect(service.isRunning, isFalse);

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.sendAttempts, 0);
  });

  test('内存模式：可提醒并明确“重启可能重复”的限制', () async {
    var now = DateTime.utc(2026, 11, 9, 5, 59);
    final store = ScheduleStore.memory();
    final controller = ScheduleController(store: store, clock: () => now);
    await controller.initialize();
    addTearDown(controller.close);
    final created = await controller.createEvent(_timedDraft(title: '会议'));
    expect(created.ok, isTrue, reason: created.message);

    final accepted = <String>[];
    final service = ScheduleReminderService(
      controller: controller,
      store: store,
      send: (title, body) async {
        accepted.add(body);
        return true;
      },
      clock: () => now,
      tickInterval: const Duration(hours: 1),
      retryDelay: Duration.zero,
    );
    addTearDown(service.dispose);
    await service.start();
    expect(service.statePersistent, isFalse);
    expect(service.lastNotice, contains('内存'));

    now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(accepted, hasLength(1));
    await service.tick();
    expect(accepted, hasLength(1));
  });

  test('备份恢复抑制：旧补报标记 skipped，之后不回弹', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 6, 10));
    addTearDown(h.disposeAll);
    await h.initialize();
    // 10 分钟前到期：正常情况下会被补报。
    await h.create(_timedDraft(title: '旧提醒'));
    final service = h.makeService();
    service.suppressNextCatchUp();
    await service.start();
    expect(h.sendAttempts, 0, reason: '恢复时抑制旧补报');
    expect(service.retainedStateEntries, 1);

    // 后续 tick 与再次重算也不回弹。
    await service.tick();
    await service.tick();
    expect(h.sendAttempts, 0);

    // 正常未来触发不受抑制影响。
    await h.create(_timedDraft(
      title: '未来会议',
      startMinute: 15 * 60,
      endMinute: 16 * 60,
    ));
    h.now = DateTime.utc(2026, 11, 9, 7);
    await service.tick();
    expect(h.sendAttempts, 1);
    expect(h.accepted.single.body, contains('未来会议'));

    // 去重文件确实记录了 skipped。
    final raw = jsonDecode(h.store.reminderStateFile.readAsStringSync()) as Map;
    final entries = (raw['entries'] as List).cast<Map>();
    expect(
      entries.any((entry) => entry['status'] == 'skipped'),
      isTrue,
    );
  });

  test('重复日程每个实例各自提醒，occurrenceKey 保留原始日期', () async {
    final h = _Harness(now: DateTime.utc(2026, 11, 9, 5, 0));
    addTearDown(h.disposeAll);
    await h.initialize();
    await h.create(_timedDraft(
      title: '每日站会',
      repeat: const ScheduleRepeatRule.daily(),
    ));
    final service = h.makeService();
    await service.start();
    expect(service.plan, hasLength(2));
    final eventId = service.plan.first.eventId;
    expect(
      service.plan.map((item) => item.occurrenceKey).toList(),
      <String>[
        '$eventId@2026-11-09',
        '$eventId@2026-11-10',
      ],
    );

    h.now = DateTime.utc(2026, 11, 9, 6);
    await service.tick();
    expect(h.accepted, hasLength(1));
    h.now = DateTime.utc(2026, 11, 10, 6);
    await service.tick();
    expect(h.accepted, hasLength(2));
    expect(h.accepted.last.body, contains('每日站会'));
  });
}
