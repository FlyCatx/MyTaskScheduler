// 日程忙碌/指纹/合成回归（task 3）：并集不重复扣、全天/关闭占用不扣、
// 指纹不含标题等元数据、不完整展开不伪造空集、请求时间表匿名。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_busy.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';
import 'package:taskscheduler_flutter/src/state/timetable_composition.dart';

import '../support/test_support.dart';

ScheduleEvent _event({
  String id = 'ev-1',
  String title = '私密标题',
  String startDate = '2026-11-10',
  int startMinute = 630,
  int endMinute = 690,
  bool allDay = false,
  bool blocks = true,
  String? endDateExclusive,
}) =>
    ScheduleEvent(
      id: id,
      revision: 1,
      title: title,
      timezoneId: 'Asia/Shanghai',
      allDay: allDay,
      startDate: startDate,
      startMinute: allDay ? null : startMinute,
      endMinute: allDay ? null : endMinute,
      endDateExclusive: endDateExclusive,
      blocksScheduling: blocks,
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    );

/// 2026-11-10 00:00—次日 00:00（Asia/Shanghai）的 UTC 范围。
final DateTime _dayFrom = DateTime.utc(2026, 11, 9, 16);
final DateTime _dayTo = DateTime.utc(2026, 11, 10, 16);

ScheduleBusySnapshot _busy(List<ScheduleEvent> events) => computeScheduleBusy(
      events: events,
      fromUtc: _dayFrom,
      toUtc: _dayTo,
      timezoneId: 'Asia/Shanghai',
    );

void main() {
  setUp(ScheduleStore.resetInstanceLocksForTest);

  test('重叠日程按并集扣一次：10:00-11:00 + 10:30-11:30 = 90 分钟', () {
    final snapshot = _busy(<ScheduleEvent>[
      _event(id: 'a', startMinute: 600, endMinute: 660),
      _event(id: 'b', startMinute: 630, endMinute: 690),
    ]);
    expect(snapshot.complete, isTrue);
    expect(snapshot.intervals, hasLength(1));
    expect(snapshot.intervals.single.minutes, 90);
    expect(snapshot.available, isTrue);
  });

  test('全天与关闭占用的日程不扣容量', () {
    final snapshot = _busy(<ScheduleEvent>[
      _event(
        id: 'all',
        allDay: true,
        startMinute: 0,
        endMinute: 0,
        endDateExclusive: '2026-11-11',
      ),
      _event(id: 'free', blocks: false),
    ]);
    expect(snapshot.available, isTrue);
    expect(snapshot.intervals, isEmpty);
    expect(snapshot.wallRanges, isEmpty);
  });

  test('指纹只含区间并集+范围+时区，不含标题/备注/关联', () {
    final a = _busy(<ScheduleEvent>[_event(title: '会议A')]);
    final b = _busy(<ScheduleEvent>[_event(title: '会议B')]);
    expect(a.fingerprint, isNotNull);
    expect(b.fingerprint, a.fingerprint);
    // 改时间 → 指纹变化。
    final c = _busy(<ScheduleEvent>[_event(startMinute: 600, endMinute: 660)]);
    expect(c.fingerprint, isNot(a.fingerprint));
    // 空集的指纹稳定且非空（不能伪装成“服务不可用”）。
    final empty1 = _busy(const <ScheduleEvent>[]);
    final empty2 = _busy(const <ScheduleEvent>[]);
    expect(empty1.fingerprint, isNotNull);
    expect(empty2.fingerprint, empty1.fingerprint);
  });

  test('跨日事件拆成两个本地日区间', () {
    final snapshot = computeScheduleBusy(
      events: <ScheduleEvent>[
        _event(startMinute: 23 * 60 + 30, endMinute: 24 * 60 + 30),
      ],
      fromUtc: DateTime.utc(2026, 11, 9, 16),
      toUtc: DateTime.utc(2026, 11, 10, 16),
      timezoneId: 'Asia/Shanghai',
    );
    expect(snapshot.available, isTrue);
    expect(snapshot.wallRanges, hasLength(2));
    expect(snapshot.wallRanges[0].date, '2026-11-10');
    expect(snapshot.wallRanges[0].start, 23 * 60 + 30);
    expect(snapshot.wallRanges[0].end, 1440);
    expect(snapshot.wallRanges[1].date, '2026-11-11');
    expect(snapshot.wallRanges[1].start, 0);
    expect(snapshot.wallRanges[1].end, 30);
  });

  test('DST 不存在时刻：available=false，fingerprint=null（不伪造空集）', () {
    final snapshot = computeScheduleBusy(
      events: <ScheduleEvent>[
        ScheduleEvent(
          id: 'dst',
          revision: 1,
          title: 'DST 会议',
          timezoneId: 'America/New_York',
          startDate: '2026-03-08',
          startMinute: 2 * 60 + 30,
          endMinute: 3 * 60 + 30,
          createdAtUtc: DateTime.utc(2026, 3, 1),
          updatedAtUtc: DateTime.utc(2026, 3, 1),
        ),
      ],
      fromUtc: DateTime.utc(2026, 3, 7),
      toUtc: DateTime.utc(2026, 3, 10),
      timezoneId: 'America/New_York',
    );
    expect(snapshot.complete, isFalse);
    expect(snapshot.available, isFalse);
    expect(snapshot.fingerprint, isNull);
    expect(snapshot.warnings, isNotEmpty);
  });

  test('合成时间表：日程占用匿名、不写回手工条目、与外部区分', () {
    final manual = const Timetable(
      revision: 1,
      timezoneId: 'Asia/Shanghai',
      timezoneOffsetMinutes: 480,
      dateFrom: '2026-11-10',
      dateTo: '2026-11-10',
      dates: <TimetableEntry>[
        TimetableEntry(
          id: 'free',
          state: TimetableState.free,
          start: 540,
          end: 720,
          date: '2026-11-10',
        ),
      ],
    );
    final snapshot = _busy(<ScheduleEvent>[
      _event(title: '绝不能进入请求的私密标题'),
    ]);
    final composed = composeScheduleBusy(
      manual: manual,
      busy: snapshot.wallRanges,
      timezoneId: manual.timezoneId,
    );
    final scheduleEntries = composed.dates
        .where((e) => e.origin == TimetableOrigin.schedule)
        .toList();
    expect(scheduleEntries, hasLength(1));
    expect(scheduleEntries.single.title, kLocalScheduleAnonymousTitle);
    expect(scheduleEntries.single.start, 630);
    expect(scheduleEntries.single.end, 690);
    expect(
      composed.dates.any((e) => e.title == '绝不能进入请求的私密标题'),
      isFalse,
    );
    // 手工可用条目仍保留未被占用的两段（09:00-10:30、11:30-12:00）。
    final free = composed.dates
        .where((e) => e.state == TimetableState.free)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    expect(free.map((e) => e.start), <int>[540, 690]);
    expect(free.map((e) => e.end), <int>[630, 720]);
  });

  test('合成 settings：占用标记为 localSchedule，不是 external', () {
    final base = CalendarSettings.blank(now: DateTime(2026, 11, 10));
    final snapshot = _busy(<ScheduleEvent>[_event()]);
    final settings = composeScheduleSettings(
      base: base,
      busy: snapshot.wallRanges,
    );
    expect(settings.occupancies, hasLength(1));
    expect(settings.occupancies.single.localSchedule, isTrue);
    expect(settings.occupancies.single.external, isFalse);
    expect(settings.occupancies.single.title, kLocalScheduleAnonymousTitle);
  });

  test('requestTimetableFor 携带匿名日程占用；无版本计划也能工作', () async {
    final schedule = ScheduleController(store: ScheduleStore.memory());
    final created = await schedule.createEvent(const ScheduleDraft(
      title: '私密标题',
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-10',
      startMinute: 630,
      endMinute: 690,
    ));
    expect(created.ok, isTrue, reason: created.message);
    final store = InMemorySessionRepository();
    final app = AppController(
      engine: FakeScheduleEngine(),
      store: store,
      schedule: schedule,
    );
    final manual = const Timetable(
      revision: 1,
      timezoneId: 'Asia/Shanghai',
      timezoneOffsetMinutes: 480,
      dateFrom: '2026-11-10',
      dateTo: '2026-11-10',
      dates: <TimetableEntry>[
        TimetableEntry(
          id: 'free',
          state: TimetableState.free,
          start: 540,
          end: 720,
          date: '2026-11-10',
        ),
      ],
    );
    final version = PlanVersion(
      id: 'ver-1',
      conversationId: 'conv-1',
      revision: 0,
      createdAt: DateTime(2026, 11, 10),
      summary: '',
      tasks: const <TaskRecord>[],
      notes: const <PlanNote>[],
      timetable: manual,
      calendar: CalendarSchedule.blank(now: DateTime(2026, 11, 10)),
    );
    final conversation = Conversation(
      id: 'conv-1',
      title: '会话',
      createdAt: DateTime(2026, 11, 10),
      updatedAt: DateTime(2026, 11, 10),
      versions: <PlanVersion>[version],
      currentVersionId: 'ver-1',
      includeTimetable: true,
    );
    addTearDown(schedule.close);

    final composed = app.requestTimetableFor(conversation, version);
    expect(composed, isNotNull);
    final scheduleEntries = composed!.dates
        .where((e) => e.origin == TimetableOrigin.schedule)
        .toList();
    expect(scheduleEntries, hasLength(1));
    expect(scheduleEntries.single.title, kLocalScheduleAnonymousTitle);
    expect(
      composed.dates.any((e) => (e.title ?? '').contains('私密')),
      isFalse,
    );
  });

  test('日程指纹变化使迟到结果失效；只改标题不失效', () async {
    final schedule = ScheduleController(store: ScheduleStore.memory());
    await schedule.initialize();
    addTearDown(schedule.close);
    final created = await schedule.createEvent(const ScheduleDraft(
      title: '会议',
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-10',
      startMinute: 600,
      endMinute: 660,
    ));
    expect(created.ok, isTrue);
    final app = AppController(
      engine: FakeScheduleEngine(),
      store: InMemorySessionRepository(),
      schedule: schedule,
    );
    final manual = const Timetable(
      revision: 1,
      timezoneId: 'Asia/Shanghai',
      timezoneOffsetMinutes: 480,
      dateFrom: '2026-11-10',
      dateTo: '2026-11-10',
    );
    final version = PlanVersion(
      id: 'ver-1',
      conversationId: 'conv-1',
      revision: 0,
      createdAt: DateTime(2026, 11, 10),
      summary: '',
      tasks: const <TaskRecord>[],
      notes: const <PlanNote>[],
      timetable: manual,
    );
    final conversation = Conversation(
      id: 'conv-1',
      title: '会话',
      createdAt: DateTime(2026, 11, 10),
      updatedAt: DateTime(2026, 11, 10),
      includeTimetable: true,
    );
    final before = app.captureScheduleRequestBaseline(conversation, version);
    expect(before, isNotNull);
    final event = schedule.events.single;
    await schedule.updateEvent(
      event.id,
      event.revision,
      ScheduleDraft(
        title: '只改标题',
        timezoneId: event.timezoneId,
        startDate: event.startDate,
        startMinute: event.startMinute,
        endMinute: event.endMinute,
        repeat: event.repeat,
      ),
    );
    final afterTitle = app.captureScheduleRequestBaseline(conversation, version);
    expect(afterTitle!.fingerprint, before!.fingerprint);

    expect(
      AppController.staleResultMessage(
        requestedTimetableRevision: -1,
        currentTimetableRevision: 0,
        requestedExternalFingerprint: '',
        currentExternalFingerprint: '',
        requestedScheduleFingerprint: 'a',
        currentScheduleFingerprint: 'b',
      ),
      contains('本地日程'),
    );
  });
}
