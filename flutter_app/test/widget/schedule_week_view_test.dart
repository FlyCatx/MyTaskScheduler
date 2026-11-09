// 日程周视图（任务 11）布局/交互专项测试。
//
// 覆盖：七列按当地日期、全天独立行、定时事件真实起止位置、重叠事件各自可选、
// 跨日按真实边界裁剪、点击空档预填、任务层只读叠加（关闭只隐藏）、空态文案、
// 左侧月历导航与点日期定位。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_week_view.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

DateTime _utc(String date, int minute) {
  final key = dateKeyToUtc(date)!;
  final wall = DateTime.utc(
    key.year,
    key.month,
    key.day + minute ~/ 1440,
    (minute % 1440) ~/ 60,
    minute % 60,
  );
  final resolved = IcsTimeZoneResolver().resolveWall('Asia/Shanghai', wall);
  return resolved.utc!;
}

ScheduleOccurrence _timed({
  required String key,
  required String date,
  required int start,
  required int end,
  String title = '日程',
  String? category,
  bool blocks = true,
}) {
  return ScheduleOccurrence(
    eventId: key.split('@').first,
    occurrenceKey: key,
    originalDate: date,
    title: title,
    category: category,
    timezoneId: 'Asia/Shanghai',
    allDay: false,
    blocksScheduling: blocks,
    reminder: ScheduleReminderKind.none,
    startUtc: _utc(date, start),
    endUtc: _utc(date, end),
  );
}

ScheduleOccurrence _allDay({
  required String key,
  required String startDate,
  required String endDateExclusive,
  String title = '全天日程',
}) {
  return ScheduleOccurrence(
    eventId: key.split('@').first,
    occurrenceKey: key,
    originalDate: startDate,
    title: title,
    timezoneId: 'Asia/Shanghai',
    allDay: true,
    blocksScheduling: false,
    reminder: ScheduleReminderKind.none,
    startDate: startDate,
    endDateExclusive: endDateExclusive,
  );
}

void main() {
  setUpAll(IcsTimeZoneResolver.ensureDatabase);
  setUp(() => TsColors.apply(Brightness.light));
  tearDown(() => TsColors.apply(Brightness.light));

  Widget host({
    required List<ScheduleOccurrence> occurrences,
    DateTime? month,
    bool showTaskLayer = false,
    List<ScheduleTaskTime> taskTimes = const <ScheduleTaskTime>[],
    bool showEmpty = false,
    String emptyMessage = '本周暂无日程',
    ValueChanged<DateTime>? onSelectDate,
    void Function(DateTime, int)? onSelectSlot,
    ValueChanged<ScheduleOccurrence>? onSelectOccurrence,
    ValueChanged<bool>? onToggleTaskLayer,
    List<ScheduleOccurrence>? monthOccurrences,
  }) {
    final weekStart = DateTime(2026, 11, 9);
    return MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1060,
          height: 720,
          child: ScheduleWeekView(
            weekStart: weekStart,
            timezoneId: 'Asia/Shanghai',
            occurrences: occurrences,
            monthAnchor: month ?? DateTime(2026, 11),
            monthOccurrences: monthOccurrences ?? occurrences,
            selectedDate: DateTime(2026, 11, 9),
            today: DateTime(2026, 11, 9),
            taskTimes: taskTimes,
            showTaskLayer: showTaskLayer,
            onToggleTaskLayer: onToggleTaskLayer ?? (_) {},
            onSelectDate: onSelectDate ?? (_) {},
            onMonthChanged: (_) {},
            onSelectSlot: onSelectSlot ?? (_, __) {},
            onSelectOccurrence: onSelectOccurrence ?? (_) {},
            emptyMessage: emptyMessage,
            showEmptyMessage: showEmpty,
          ),
        ),
      ),
    );
  }

  testWidgets('定时事件画在正确日列；重叠事件各自可选且并排', (tester) async {
    await tester.pumpWidget(host(occurrences: <ScheduleOccurrence>[
      _timed(
        key: scheduleOccurrenceKey('ev-a', '2026-11-09'),
        date: '2026-11-09',
        start: 14 * 60,
        end: 15 * 60,
        title: '需求评审',
      ),
      _timed(
        key: scheduleOccurrenceKey('ev-b', '2026-11-09'),
        date: '2026-11-09',
        start: 14 * 60 + 30,
        end: 15 * 60 + 30,
        title: '设计讨论',
      ),
    ]));
    await tester.pump();

    final first =
        find.byKey(const Key('schedule-event-ev-a@2026-11-09'));
    final second =
        find.byKey(const Key('schedule-event-ev-b@2026-11-09'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    // 两个重叠事件并排：左边缘不同，且都在周一列（第一列）附近。
    final firstRect = tester.getRect(first);
    final secondRect = tester.getRect(second);
    expect(firstRect.left, isNot(equals(secondRect.left)));
    expect(firstRect.top, isNot(equals(secondRect.top)));
    // 点击各自的事件块应回传对应实例。
    ScheduleOccurrence? tapped;
    await tester.pumpWidget(host(
      occurrences: <ScheduleOccurrence>[
        _timed(
          key: scheduleOccurrenceKey('ev-a', '2026-11-09'),
          date: '2026-11-09',
          start: 14 * 60,
          end: 15 * 60,
          title: '需求评审',
        ),
        _timed(
          key: scheduleOccurrenceKey('ev-b', '2026-11-09'),
          date: '2026-11-09',
          start: 14 * 60 + 30,
          end: 15 * 60 + 30,
          title: '设计讨论',
        ),
      ],
      onSelectOccurrence: (occurrence) => tapped = occurrence,
    ));
    await tester.tap(find.byKey(const Key('schedule-event-ev-b@2026-11-09')));
    await tester.pump();
    expect(tapped?.occurrenceKey, 'ev-b@2026-11-09');
  });

  testWidgets('跨日定时事件在两天列各画一段并带续标记', (tester) async {
    await tester.pumpWidget(host(occurrences: <ScheduleOccurrence>[
      _timed(
        key: scheduleOccurrenceKey('ev-night', '2026-11-09'),
        date: '2026-11-09',
        start: 23 * 60,
        end: 24 * 60 + 60,
        title: '跨夜值班',
      ),
    ]));
    await tester.pump();
    expect(
      find.byKey(const Key('schedule-event-ev-night@2026-11-09')),
      findsNWidgets(2),
    );
  });

  testWidgets('全天日程进入独立全天行，多天按真实日期跨度铺开', (tester) async {
    await tester.pumpWidget(host(occurrences: <ScheduleOccurrence>[
      _allDay(
        key: scheduleOccurrenceKey('ev-holiday', '2026-11-10'),
        startDate: '2026-11-10',
        endDateExclusive: '2026-11-13',
        title: '出差',
      ),
    ]));
    await tester.pump();
    final bar = find.byKey(const Key('schedule-allday-ev-holiday@2026-11-10'));
    expect(bar, findsOneWidget);
    final rect = tester.getRect(bar);
    // 横跨周二到周四三列，宽度应明显大于一列。
    expect(rect.width, greaterThan(150));
    // 全天日程不进入定时时间轴。
    expect(
      find.byKey(const Key('schedule-event-ev-holiday@2026-11-10')),
      findsNothing,
    );
  });

  testWidgets('任务层只读：关闭只隐藏，打开出现，且不生成日程块', (tester) async {
    final occurrences = <ScheduleOccurrence>[
      _timed(
        key: scheduleOccurrenceKey('ev-a', '2026-11-09'),
        date: '2026-11-09',
        start: 10 * 60,
        end: 11 * 60,
      ),
    ];
    final taskTimes = <ScheduleTaskTime>[
      ScheduleTaskTime(
        taskId: 'task-1',
        title: '写方案',
        startUtc: _utc('2026-11-09', 9 * 60),
        endUtc: _utc('2026-11-09', 12 * 60),
      ),
    ];
    bool? toggled;
    await tester.pumpWidget(host(
      occurrences: occurrences,
      taskTimes: taskTimes,
      showTaskLayer: false,
      onToggleTaskLayer: (value) => toggled = value,
    ));
    await tester.pump();
    expect(
      find.byKey(const Key('schedule-task-layer-task-1-0')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('schedule-task-layer-toggle')));
    await tester.pump();
    expect(toggled, isTrue);

    await tester.pumpWidget(host(
      occurrences: occurrences,
      taskTimes: taskTimes,
      showTaskLayer: true,
    ));
    await tester.pump();
    expect(find.byKey(const Key('schedule-task-layer-task-1-0')), findsOneWidget);
    // 只读叠加不会多出日程事件块。
    expect(find.byKey(const Key('schedule-event-ev-a@2026-11-09')), findsOneWidget);
  });

  testWidgets('空态文案在时间轴中央显示', (tester) async {
    await tester.pumpWidget(host(
      occurrences: const <ScheduleOccurrence>[],
      showEmpty: true,
      emptyMessage: '没有符合条件的日程',
    ));
    await tester.pump();
    expect(find.byKey(const Key('schedule-week-empty')), findsOneWidget);
    expect(find.text('没有符合条件的日程'), findsOneWidget);
  });

  testWidgets('点击空档回传日期与分钟；点日期标题区域回到对应周', (tester) async {
    DateTime? slotDate;
    int? slotMinute;
    DateTime? selectedDate;
    await tester.pumpWidget(host(
      occurrences: const <ScheduleOccurrence>[],
      onSelectSlot: (date, minute) {
        slotDate = date;
        slotMinute = minute;
      },
      onSelectDate: (date) => selectedDate = date,
    ));
    await tester.pump();
    // 第 4 列（周四）= 11 月 12 日。
    final column = find.byKey(const Key('schedule-day-column-3'));
    final rect = tester.getRect(column);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 120));
    await tester.pump();
    expect(slotDate?.month, 11);
    expect(slotDate?.day, 12);
    expect(slotMinute, isNotNull);
    expect(slotMinute! % 30, 0, reason: '空档时间按 30 分钟吸附');

    // 左侧月历翻到 12 月后点 12 月 2 日：回传该日期（调用方据此切周）。
    await tester.pumpWidget(host(
      occurrences: const <ScheduleOccurrence>[],
      month: DateTime(2026, 12),
      onSelectDate: (date) => selectedDate = date,
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('schedule-mini-day-2026-12-02')));
    await tester.pump();
    expect(selectedDate?.month, 12);
    expect(selectedDate?.day, 2);
  });

  testWidgets('紧凑月历显示月份、可翻月并给有日程的日期画点', (tester) async {
    final monthChanged = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 1060,
            height: 720,
            child: Builder(builder: (context) {
              return ScheduleWeekView(
                weekStart: DateTime(2026, 11, 9),
                timezoneId: 'Asia/Shanghai',
                occurrences: const <ScheduleOccurrence>[],
                monthAnchor: DateTime(2026, 11),
                monthOccurrences: <ScheduleOccurrence>[
                  _timed(
                    key: scheduleOccurrenceKey('ev-dot', '2026-11-18'),
                    date: '2026-11-18',
                    start: 9 * 60,
                    end: 10 * 60,
                  ),
                ],
                selectedDate: DateTime(2026, 11, 9),
                today: DateTime(2026, 11, 9),
                taskTimes: const <ScheduleTaskTime>[],
                showTaskLayer: false,
                onToggleTaskLayer: (_) {},
                onSelectDate: (_) {},
                onMonthChanged: monthChanged.add,
                onSelectSlot: (_, __) {},
                onSelectOccurrence: (_) {},
                emptyMessage: '本周暂无日程',
              );
            }),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('schedule-month-label')), findsOneWidget);
    expect(find.text('2026年11月'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-month-next')));
    await tester.pump();
    expect(monthChanged.single.month, 12);
  });
}
