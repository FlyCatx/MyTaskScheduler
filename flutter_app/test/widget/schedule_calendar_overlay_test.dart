// 日历 / 甘特日程叠层的 widget 回归（0.4.0 任务 5）。
//
// 覆盖：
//   * 无日程时新增参数不改变任何渲染（逐像素零回归）；
//   * 同一时段两条日程各占半列 / 各行，能分别命中，点击只回调；
//   * 点击日程不写 TimetableDraft、不产生撤销事务、不选中任务、不提交计划；
//   * 跨日日程按自然日拆成两段（网格与甘特）；
//   * 全天日程显示在日期表头 / 甘特日程带；
//   * “不占用”日程有明确文字标注，占用日程没有；
//   * 设置弹窗与 CalendarActions（生产接线通道）都能把叠层传到控件。

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_gantt.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_grid.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

const String _week = '2026-11-09';
const String _tz = 'Asia/Shanghai';
const int _offset = 480;

/// 本地墙钟（固定 +08 的 Asia/Shanghai）→ UTC。
DateTime _wallUtc(String dateKey, int minute) {
  final base = DateTime.utc(
    int.parse(dateKey.substring(0, 4)),
    int.parse(dateKey.substring(5, 7)),
    int.parse(dateKey.substring(8)),
  );
  return base.add(Duration(minutes: minute)).subtract(
        const Duration(minutes: _offset),
      );
}

ScheduleOccurrence _timed({
  required String id,
  required String date,
  required int startMinute,
  required int endMinute,
  required String title,
  bool blocks = true,
}) =>
    ScheduleOccurrence(
      eventId: id,
      occurrenceKey: '$id@$date',
      originalDate: date,
      title: title,
      timezoneId: _tz,
      allDay: false,
      blocksScheduling: blocks,
      reminder: ScheduleReminderKind.none,
      startUtc: _wallUtc(date, startMinute),
      endUtc: _wallUtc(date, endMinute),
    );

ScheduleOccurrence _allDay({
  required String id,
  required String startDate,
  required String endExclusive,
  required String title,
  bool blocks = false,
}) =>
    ScheduleOccurrence(
      eventId: id,
      occurrenceKey: '$id@$startDate',
      originalDate: startDate,
      title: title,
      timezoneId: _tz,
      allDay: true,
      blocksScheduling: blocks,
      reminder: ScheduleReminderKind.none,
      startDate: startDate,
      endDateExclusive: endExclusive,
    );

Key _timedBlockKey(String occurrenceKey, String dateKey) =>
    Key('timetable-schedule-$occurrenceKey@$dateKey');

Key _allDayChipKey(String occurrenceKey, String dateKey) =>
    Key('timetable-schedule-allday-$occurrenceKey-$dateKey');

Key _ganttBarKey(String occurrenceKey, String dateKey) =>
    Key('gantt-schedule-$occurrenceKey@$dateKey');

// --------------------------------------------------------------- 网格测试

class _GridHarness {
  _GridHarness(this.controller);

  final TimetableGridController controller;
}

Timetable _timetable() => Timetable.withDefaults(weekStart: _week);

Future<_GridHarness> _pumpGrid(
  WidgetTester tester, {
  List<ScheduleOccurrence> occurrences = const <ScheduleOccurrence>[],
  ValueChanged<ScheduleOccurrence>? onScheduleTap,
  VoidCallback? onAddSchedule,
  bool withBoundary = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));

  final controller = TimetableGridController(draft: TimetableDraft(_timetable()));
  final grid = TimetableGrid(
    key: const Key('grid'),
    controller: controller,
    weekStart: _week,
    weekStartsOn: 1,
    weeklyMode: false,
    scheduleOccurrences: occurrences,
    onScheduleTap: onScheduleTap,
    onAddSchedule: onAddSchedule,
  );
  final child = withBoundary
      ? RepaintBoundary(key: const Key('grid-boundary'), child: grid)
      : grid;
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 1000, height: 700, child: child),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return _GridHarness(controller);
}

Offset _cellCenter(WidgetTester tester, int day, int slot) {
  final box = tester.getRect(find.byKey(const Key('grid')));
  final gridWidth =
      box.width - TimetableGrid.timeAxisWidth - TimetableGrid.scrollbarGutter;
  final dayWidth = gridWidth / 7;
  return Offset(
    box.left + TimetableGrid.timeAxisWidth + dayWidth * (day + 0.5),
    box.top +
        TimetableGrid.headerHeight +
        TimetableGrid.topInset +
        TimetableGrid.rowHeight * (slot + 0.5),
  );
}

Future<Uint8List> _pngOf(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('grid-boundary')),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

// --------------------------------------------------------------- 甘特测试

final _plan = samplePlan();
final _snapshot = FakeScheduleEngine.buildSnapshotFor(_plan);

CalendarSettings _ganttSettings() => CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-18',
      planningDays: 7,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 1080)],
      }),
    );

final _version = PlanVersion(
  id: 'ver-overlay',
  conversationId: 'conv-1',
  createdAt: _wallUtc('2026-11-18', 7 * 60),
  summary: _plan.summary,
  tasks: _plan.tasks,
  calendar: CalendarSchedule(settings: _ganttSettings(), segments: const []),
);

class _GanttRecord {
  final List<CalendarEditOutcome> commits = <CalendarEditOutcome>[];
  int autoRuns = 0;
  int addCalls = 0;
  final List<ScheduleOccurrence> taps = <ScheduleOccurrence>[];
}

Future<TaskInteraction> _pumpGantt(
  WidgetTester tester,
  _GanttRecord record, {
  List<ScheduleOccurrence> direct = const <ScheduleOccurrence>[],
  List<ScheduleOccurrence> fromActions = const <ScheduleOccurrence>[],
  ValueChanged<ScheduleOccurrence>? onScheduleTap,
  VoidCallback? onAddSchedule,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 720);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1200, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  final interaction = TaskInteraction();
  final actions = CalendarActions(
    commit: (outcome) async {
      record.commits.add(outcome);
      return true;
    },
    autoSchedule: ({required bool keepManual}) async => null,
    applySettings: (settings, {required bool reschedule}) async => true,
    ensureReady: () async => null,
    scheduleOccurrences: fromActions,
    onScheduleTap: fromActions.isEmpty ? null : (occurrence) {
      record.taps.add(occurrence);
    },
    onAddSchedule: fromActions.isEmpty
        ? null
        : () {
            record.addCalls++;
          },
  );
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 1200,
        height: 720,
        child: CalendarGanttView(
          snapshot: _snapshot,
          version: _version,
          schedule: _version.calendar,
          interaction: interaction,
          actions: actions,
          clock: _wallUtc('2026-11-17', 23 * 60),
          scheduleOccurrences: direct,
          onScheduleTap: onScheduleTap,
          onAddSchedule: onAddSchedule,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return interaction;
}

// ------------------------------------------------------------ 设置弹窗测试

Future<void> _openEditor(
  WidgetTester tester, {
  required List<ScheduleOccurrence> occurrences,
  required ValueChanged<ScheduleOccurrence> onScheduleTap,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1300, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1300, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open-editor'),
            onPressed: () => showCalendarSettingsDialog(
              context,
              settings: const CalendarSettings(
                timezoneOffsetMinutes: _offset,
                planningStartDate: _week,
                planningDays: 7,
                weekly: WeeklyAvailability({
                  1: [WallClockRange(480, 720)],
                }),
              ),
              now: _wallUtc(_week, 2 * 60),
              timetable: _timetable(),
              weekStartsOn: 1,
              initialMode: CalendarEditorMode.drawing,
              scheduleOccurrences: occurrences,
              onScheduleTap: onScheduleTap,
            ),
            child: const Text('编辑'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pumpAndSettle();
}

void main() {
  group('TimetableGrid 日程叠层', () {
    testWidgets('无日程时新增参数不改变渲染（逐像素零回归）', (tester) async {
      await _pumpGrid(tester, withBoundary: true);
      final baseline = await _pngOf(tester);
      await _pumpGrid(
        tester,
        occurrences: const <ScheduleOccurrence>[],
        withBoundary: true,
      );
      final explicitEmpty = await _pngOf(tester);
      expect(baseline, equals(explicitEmpty),
          reason: '空日程参数不能改变任何像素');
    });

    testWidgets('同一时段两条日程各占半列、分别可点且不写入手工时间表', (tester) async {
      final taps = <String>[];
      final a = _timed(
        id: 'ev-a',
        date: _week,
        startMinute: 8 * 60,
        endMinute: 9 * 60,
        title: '评审会议',
      );
      final b = _timed(
        id: 'ev-b',
        date: _week,
        startMinute: 8 * 60,
        endMinute: 9 * 60,
        title: '周会',
      );
      final harness = await _pumpGrid(
        tester,
        occurrences: [a, b],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      final before = jsonEncode(harness.controller.draft.timetable.toJson());

      // 两条都在控件树里：重叠不能被最后一条覆盖。
      expect(find.textContaining('评审会议'), findsOneWidget);
      expect(find.textContaining('周会'), findsOneWidget);
      final blockA = find.byKey(_timedBlockKey('ev-a@$_week', _week));
      final blockB = find.byKey(_timedBlockKey('ev-b@$_week', _week));
      expect(blockA, findsOneWidget);
      expect(blockB, findsOneWidget);
      expect(
        tester.getCenter(blockA).dx,
        lessThan(tester.getCenter(blockB).dx),
        reason: '两条日程必须在同一列里左右错开（各占半列）',
      );

      await tester.tap(blockA);
      await tester.pump();
      await tester.tap(blockB);
      await tester.pump();
      expect(taps, ['ev-a', 'ev-b'], reason: '两条日程必须能分别命中');
      expect(jsonEncode(harness.controller.draft.timetable.toJson()), before,
          reason: '点击日程不能写入手工时间表');
      expect(harness.controller.undoDepth, 0, reason: '点击日程不产生撤销事务');

      // 日程之外仍可正常绘制：叠层只是局部拦截。
      await tester.tapAt(_cellCenter(tester, 0, 10));
      await tester.pump();
      expect(harness.controller.draft.timetable.hasEntries, isTrue);
    });

    testWidgets('选择模式下点日程只回调，不选中蓝块', (tester) async {
      final taps = <String>[];
      final harness = await _pumpGrid(
        tester,
        occurrences: [
          _timed(
            id: 'ev-a',
            date: _week,
            startMinute: 8 * 60,
            endMinute: 9 * 60,
            title: '评审会议',
          ),
        ],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      harness.controller.setSelectionMode(true);
      await tester.pump();
      await tester.tap(find.byKey(_timedBlockKey('ev-a@$_week', _week)));
      await tester.pump();
      expect(taps, ['ev-a']);
      expect(harness.controller.selectedReservationIds, isEmpty);
      expect(harness.controller.undoDepth, 0);
    });

    testWidgets('跨日日程拆成两天显示段，次日段可点', (tester) async {
      final taps = <String>[];
      final overnight = _timed(
        id: 'ev-night',
        date: _week,
        startMinute: 23 * 60 + 30,
        endMinute: 24 * 60 + 30,
        title: '跨日凌晨班',
      );
      await _pumpGrid(
        tester,
        occurrences: [overnight],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      final first = find.byKey(_timedBlockKey('ev-night@$_week', _week));
      final second = find.byKey(
        _timedBlockKey('ev-night@$_week', '2026-11-10'),
      );
      expect(first, findsOneWidget);
      expect(second, findsOneWidget,
          reason: '跨日日程必须在次日也有独立显示段');
      expect(find.textContaining('23:30-24:00'), findsOneWidget);
      expect(find.textContaining('00:00-00:30'), findsOneWidget);
      await tester.tap(second);
      await tester.pump();
      expect(taps, ['ev-night']);
    });

    testWidgets('全天日程显示在日期表头，标注不占用且点击只回调', (tester) async {
      final taps = <String>[];
      final allDay = _allDay(
        id: 'ev-holiday',
        startDate: _week,
        endExclusive: '2026-11-11',
        title: '纪念日',
      );
      final harness = await _pumpGrid(
        tester,
        occurrences: [allDay],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      final before = jsonEncode(harness.controller.draft.timetable.toJson());
      final chipDay0 = find.byKey(_allDayChipKey('ev-holiday@$_week', _week));
      final chipDay1 = find.byKey(
        _allDayChipKey('ev-holiday@$_week', '2026-11-10'),
      );
      expect(chipDay0, findsOneWidget);
      expect(chipDay1, findsOneWidget,
          reason: '全天日程按日期区间覆盖到每一天');
      expect(find.textContaining('纪念日'), findsNWidgets(2));
      expect(find.textContaining('不占用'), findsWidgets);
      await tester.tap(chipDay1);
      await tester.pump();
      expect(taps, ['ev-holiday']);
      expect(jsonEncode(harness.controller.draft.timetable.toJson()), before);
    });

    testWidgets('不占用定时日程有明确标注，占用日程没有', (tester) async {
      await _pumpGrid(
        tester,
        occurrences: [
          _timed(
            id: 'ev-busy',
            date: _week,
            startMinute: 10 * 60,
            endMinute: 11 * 60,
            title: '站会',
          ),
          _timed(
            id: 'ev-remind',
            date: _week,
            startMinute: 13 * 60,
            endMinute: 14 * 60,
            title: '提醒交费',
            blocks: false,
          ),
        ],
      );
      expect(find.text('站会 10:00-11:00'), findsOneWidget);
      expect(find.text('提醒交费 13:00-14:00 · 不占用'), findsOneWidget);
    });

    testWidgets('注入 onAddSchedule 时状态条才有“添加日程”按钮', (tester) async {
      var added = 0;
      await _pumpGrid(tester);
      expect(find.byKey(const Key('timetable-add-schedule')), findsNothing,
          reason: '未注入回调时状态条与旧版一致');
      await _pumpGrid(tester, onAddSchedule: () => added++);
      await tester.tap(find.byKey(const Key('timetable-add-schedule')));
      await tester.pump();
      expect(added, 1);
    });

    testWidgets('设置弹窗把日程叠层接到网格并只回调', (tester) async {
      final taps = <String>[];
      await _openEditor(
        tester,
        occurrences: [
          _timed(
            id: 'ev-dialog',
            date: _week,
            startMinute: 3 * 60,
            endMinute: 4 * 60,
            title: '弹窗日程',
          ),
        ],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      final block = find.byKey(_timedBlockKey('ev-dialog@$_week', _week));
      expect(block, findsOneWidget);
      await tester.ensureVisible(block);
      await tester.pumpAndSettle();
      await tester.tap(block);
      await tester.pump();
      expect(taps, ['ev-dialog']);
      expect(find.byType(TimetableGrid), findsOneWidget,
          reason: '点击日程不关闭编辑弹窗');
    });
  });

  group('CalendarGanttView 日程叠层', () {
    testWidgets('同一时段两条日程分行显示，分别可点且不提交计划', (tester) async {
      final record = _GanttRecord();
      final taps = <String>[];
      final a = _timed(
        id: 'ev-a',
        date: '2026-11-18',
        startMinute: 30,
        endMinute: 90,
        title: '评审会议',
      );
      final b = _timed(
        id: 'ev-b',
        date: '2026-11-18',
        startMinute: 30,
        endMinute: 90,
        title: '周会',
      );
      final interaction = await _pumpGantt(
        tester,
        record,
        direct: [a, b],
        onScheduleTap: (occurrence) => taps.add(occurrence.eventId),
      );
      expect(find.textContaining('日程 · 全局叠层'), findsOneWidget);
      final barA = find.byKey(_ganttBarKey('ev-a@2026-11-18', '2026-11-18'));
      final barB = find.byKey(_ganttBarKey('ev-b@2026-11-18', '2026-11-18'));
      expect(barA, findsOneWidget);
      expect(barB, findsOneWidget);
      await tester.tap(barA);
      await tester.pump();
      await tester.tap(barB);
      await tester.pump();
      expect(taps, ['ev-a', 'ev-b'], reason: '重叠日程必须分别命中');
      expect(record.commits, isEmpty, reason: '点击日程不能提交任何计划编辑');
      expect(interaction.selectedTaskId, isNull,
          reason: '点击日程不能进入任务选择/计时');
    });

    testWidgets('CalendarActions 可承载叠层（生产接线通道）与添加日程入口', (tester) async {
      final record = _GanttRecord();
      final occurrence = _timed(
        id: 'ev-action',
        date: '2026-11-18',
        startMinute: 60,
        endMinute: 120,
        title: '动作通道日程',
      );
      await _pumpGantt(tester, record, fromActions: [occurrence]);
      expect(
        find.byKey(_ganttBarKey('ev-action@2026-11-18', '2026-11-18')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(_ganttBarKey('ev-action@2026-11-18', '2026-11-18')),
      );
      await tester.pump();
      expect(record.taps.map((o) => o.eventId), ['ev-action']);
      await tester.tap(find.byKey(const Key('gantt-add-schedule')));
      await tester.pump();
      expect(record.addCalls, 1);
      expect(record.commits, isEmpty);
    });

    testWidgets('跨日与全天日程在甘特图按自然日拆段', (tester) async {
      final record = _GanttRecord();
      final overnight = _timed(
        id: 'ev-night',
        date: '2026-11-18',
        startMinute: 23 * 60 + 30,
        endMinute: 24 * 60 + 30,
        title: '跨日凌晨班',
      );
      final allDay = _allDay(
        id: 'ev-holiday',
        startDate: '2026-11-19',
        endExclusive: '2026-11-21',
        title: '纪念日',
      );
      await _pumpGantt(tester, record, direct: [overnight, allDay]);
      // 跨日定时：18 日与 19 日各一段。
      expect(
        find.byKey(_ganttBarKey('ev-night@2026-11-18', '2026-11-18')),
        findsOneWidget,
      );
      expect(
        find.byKey(_ganttBarKey('ev-night@2026-11-18', '2026-11-19')),
        findsOneWidget,
      );
      // 全天 19—20 日：两天各一段，并标注「全天 / 不占用」。
      expect(
        find.byKey(_ganttBarKey('ev-holiday@2026-11-19', '2026-11-19')),
        findsOneWidget,
      );
      expect(
        find.byKey(_ganttBarKey('ev-holiday@2026-11-19', '2026-11-20')),
        findsOneWidget,
      );
      expect(find.textContaining('全天'), findsNWidgets(2));
      expect(find.textContaining('不占用'), findsWidgets);
    });
  });
}
