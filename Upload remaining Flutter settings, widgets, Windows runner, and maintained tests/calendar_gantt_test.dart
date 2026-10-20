// Calendar Gantt widget behaviour (0.06).
//
// Covers: real dates on the axis, day/week scale, the 日历排程 / 相对工时 sub-switch, a
// body drag that keeps the duration, an edge drag that changes it, Esc cancelling a drag,
// conflict marking for an allowed-but-visible overlap, and the "no availability" guidance.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_gantt.dart';
import 'package:taskscheduler_flutter/src/ui/gantt_chart.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

const int _offset = 480;

DateTime at(String wall) {
  final parts = wall.split(' ');
  final date = parts[0].split('-').map(int.parse).toList();
  final time =
      parts.length > 1 ? parts[1].split(':').map(int.parse).toList() : [0, 0];
  return DateTime.utc(date[0], date[1], date[2], time[0], time[1])
      .subtract(const Duration(minutes: _offset));
}

CalendarSettings settings({bool available = true}) => CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-18',
      planningDays: 7,
      weekly: available
          ? WeeklyAvailability({
              for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 1080)],
            })
          : WeeklyAvailability.empty,
    );

class Recorded {
  final List<CalendarEditOutcome> commits = <CalendarEditOutcome>[];
  int autoRuns = 0;
  int readyCalls = 0;
}

CalendarActions actions(Recorded record, {bool canEdit = true}) => CalendarActions(
      canEdit: canEdit,
      commit: (outcome) async {
        record.commits.add(outcome);
        return true;
      },
      autoSchedule: ({required bool keepManual}) async {
        record.autoRuns++;
        return null;
      },
      applySettings: (settings, {required bool reschedule}) async => true,
      ensureReady: () async {
        record.readyCalls++;
        return null;
      },
    );

/// A real pointer drag produces many move events; a single `tester.drag` can be
/// consumed entirely by the touch slop and then delivers no `onPanUpdate` at all, which
/// would make these tests pass vacuously.
Future<void> dragInSteps(
  WidgetTester tester,
  Offset start,
  Offset total, {
  int steps = 6,
}) async {
  final gesture = await tester.startGesture(start);
  await tester.pump();
  final step = total / steps.toDouble();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step);
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  final plan = samplePlan();
  final snapshot = FakeScheduleEngine.buildSnapshotFor(plan);
  final version = PlanVersion(
    id: 'ver-calendar',
    conversationId: 'conv-1',
    createdAt: at('2026-11-18 07:00'),
    summary: plan.summary,
    tasks: plan.tasks,
    calendar: CalendarSchedule(
      settings: settings(),
      segments: [
        ScheduleSegment(
          id: 's1',
          taskId: 'task-a',
          start: at('2026-11-18 08:00'),
          end: at('2026-11-18 08:30'),
        ),
        // task-b is estimated at 2h and split 1h + 1h across two days.
        ScheduleSegment(
          id: 's2',
          taskId: 'task-b',
          start: at('2026-11-18 14:00'),
          end: at('2026-11-18 15:00'),
        ),
        ScheduleSegment(
          id: 's3',
          taskId: 'task-b',
          start: at('2026-11-19 08:00'),
          end: at('2026-11-19 09:00'),
        ),
      ],
    ),
  );

  Future<void> pumpCalendar(
    WidgetTester tester, {
    required CalendarSchedule schedule,
    required CalendarActions calendarActions,
    PlanVersion? versionOverride,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 700,
          child: CalendarGanttView(
            snapshot: snapshot,
            version: versionOverride ?? version,
            schedule: schedule,
            interaction: TaskInteraction(),
            actions: calendarActions,
            clock: at('2026-11-17 23:00'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the axis shows real dates and hours', (tester) async {
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded()),
    );
    expect(find.textContaining('11月18日'), findsWidgets);
    expect(find.textContaining('周三'), findsWidgets);
    // Hour ticks are real clock hours, not cumulative work hours.
    expect(find.text('08:00'), findsWidgets);
    expect(find.text('小时').evaluate().length, 0,
        reason: 'the calendar axis must not show a relative-hour label');
  });

  testWidgets('a task with two segments renders both of them', (tester) async {
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded()),
    );
    // task-b is split across two days: one bar per segment.
    expect(find.byKey(const Key('calendar-segment-s2')), findsOneWidget);
    expect(find.byKey(const Key('calendar-segment-s3')), findsOneWidget);
    // A 1h bar cannot fit "14:00–15:00", so it shows the start time only.
    expect(find.text('14:00'), findsWidgets);
    // Per-task summary: 2h placed of an estimated 2h => fully scheduled.
    expect(find.textContaining('已安排 2 小时'), findsWidgets);
  });

  testWidgets('dragging a segment body keeps its duration', (tester) async {
    final record = Recorded();
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(record),
    );
    final bar = find.byKey(const Key('calendar-segment-s2'));
    expect(bar, findsOneWidget);
    await dragInSteps(tester, tester.getCenter(bar), const Offset(60, 0));

    expect(record.commits, hasLength(1));
    final outcome = record.commits.single;
    expect(outcome.ok, isTrue);
    final moved = outcome.schedule!.segmentById('s2')!;
    expect(moved.minutes, 60, reason: 'a body drag must not change the duration');
    expect(moved.start.isAfter(at('2026-11-18 14:00')), isTrue);
    // The estimate is untouched because the duration is untouched.
    expect(outcome.tasks!.firstWhere((t) => t.id == 'task-b').estimatedHours, 2);
  });

  testWidgets('dragging blank timeline pans; dragging a bar still edits it',
      (tester) async {
    final record = Recorded();
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(record),
    );
    final horizontal = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    expect(horizontal, findsOneWidget);
    final scroll = tester.state<ScrollableState>(horizontal);
    scroll.position.jumpTo(400);
    await tester.pump();
    final before = scroll.position.pixels;

    // 时间轴右半段没有任务条：按住空白向左拖 → 内容左移、offset 增大。
    final body = tester.getRect(horizontal);
    final blank = Offset(body.right - 60, body.top + 90);
    final gesture =
        await tester.startGesture(blank, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-16, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(before + 80, 3),
        reason: '空白拖动应平移时间轴（向右拖时 offset 减小）');

    // 任务条上的手势仍归任务编辑，不触发背景平移。
    final afterPan = scroll.position.pixels;
    await dragInSteps(tester, tester.getCenter(find.byKey(const Key('calendar-segment-s2'))),
        const Offset(40, 0));
    expect(record.commits, hasLength(1));
    expect(scroll.position.pixels, closeTo(afterPan, 0.5),
        reason: '从任务条开始的手势不能同时平移画布');
  });

  testWidgets('周模式下的空白时间轴同样可以平移', (tester) async {
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded()),
    );
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();

    final horizontal = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    final scroll = tester.state<ScrollableState>(horizontal);
    scroll.position.jumpTo(300);
    await tester.pump();
    final before = scroll.position.pixels;
    final body = tester.getRect(horizontal);
    final gesture = await tester.startGesture(
        Offset(body.right - 80, body.top + 90),
        kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(before + 100, 3));
  });

  testWidgets('dragging the right edge changes the duration and the estimate',
      (tester) async {
    final record = Recorded();
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(record),
    );
    final rect = tester.getRect(find.byKey(const Key('calendar-segment-s2')));
    // Grab the right edge from *inside* the segment (its 7px edge zone).
    await dragInSteps(
      tester,
      Offset(rect.right - 3, rect.center.dy),
      const Offset(64, 0),
    );

    expect(record.commits, hasLength(1));
    final outcome = record.commits.single;
    final resized = outcome.schedule!.segmentById('s2')!;
    expect(resized.minutes, greaterThan(60),
        reason: 'dragging the right edge must extend the segment');
    expect(resized.start, at('2026-11-18 14:00'),
        reason: 'the left edge stays put when resizing the right one');
    // task-b was fully scheduled (2h of a 2h estimate), so the estimate follows the sum
    // of *all* its segments (135 + 60 = 195), not just the edited one.
    final updated = outcome.tasks!.firstWhere((t) => t.id == 'task-b');
    expect((updated.estimatedHours! * 60).round(),
        outcome.schedule!.minutesForTask('task-b'));
  });

  testWidgets('Esc cancels a drag without committing anything', (tester) async {
    final record = Recorded();
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(record),
    );
    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const Key('calendar-segment-s2'))));
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    // The live preview bar is shown while dragging.
    expect(find.textContaining('松手保存'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(record.commits, isEmpty);
    expect(find.textContaining('松手保存'), findsNothing);
  });

  testWidgets('an overlapping drag is allowed, saved, and marked as a conflict',
      (tester) async {
    // task-a and task-b overlapping on purpose: allowed to exist, must be visible.
    final schedule = version.calendar.copyWith(segments: [
      ...version.calendar.segments,
      ScheduleSegment(
        id: 's4',
        taskId: 'task-a',
        start: at('2026-11-18 14:30'),
        end: at('2026-11-18 15:30'),
      ),
    ]);
    await pumpCalendar(
      tester,
      schedule: schedule,
      calendarActions: actions(Recorded()),
    );
    expect(find.textContaining('冲突'), findsWidgets);
    expect(find.textContaining('重叠'), findsWidgets);
    // The save path is never blocked by a conflict.
    expect(find.textContaining('允许保存'), findsWidgets);
  });

  testWidgets('without availability the view asks for it instead of inventing time',
      (tester) async {
    await pumpCalendar(
      tester,
      schedule: CalendarSchedule(settings: settings(available: false)),
      calendarActions: actions(Recorded()),
    );
    expect(find.textContaining('还没有设置可用时间'), findsOneWidget);
    expect(find.textContaining('不会假设你每天 24 小时'), findsOneWidget);
    expect(find.textContaining('未排期'), findsWidgets);
  });

  testWidgets('read-only history disables the calendar editing affordances',
      (tester) async {
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded(), canEdit: false),
    );
    expect(find.text('历史版本只读'), findsOneWidget);
  });

  testWidgets('the auto-schedule explanation strip is not drawn', (tester) async {
    // 0.09：删除了“已根据可用时间自动安排…N 个任务未排期”的说明条；
    // 没有冲突也没有排程说明时，这条横幅不再出现（冲突仍由下方的冲突条呈现）。
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded()),
    );
    expect(find.textContaining('已根据可用时间自动安排'), findsNothing);
    expect(find.textContaining('个任务未排期'), findsNothing);
    // 轴标题只保留功能名，不再带括号说明。
    expect(find.textContaining('真实日期时间'), findsNothing);
    expect(find.text('任务 · 已安排/预计'), findsOneWidget);
  });

  testWidgets('the gantt sub-switch keeps 相对工时 as the old default', (tester) async {
    final modes = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 700,
          child: GanttPanel(
            snapshot: snapshot,
            interaction: TaskInteraction(),
            version: version,
            calendar: version.calendar,
            actions: actions(Recorded()),
            initialMode: 'relative',
            onModeChanged: modes.add,
            clock: at('2026-11-17 23:00'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(GanttChartView), findsOneWidget,
        reason: 'a conversation that never used the calendar keeps 相对工时');
    expect(find.byType(CalendarGanttView), findsNothing);

    await tester.tap(find.text('日历排程'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarGanttView), findsOneWidget);
    expect(find.byType(GanttChartView), findsNothing);
    expect(modes, ['calendar']);

    await tester.tap(find.text('相对工时'));
    await tester.pumpAndSettle();
    expect(find.byType(GanttChartView), findsOneWidget);
    expect(modes, ['calendar', 'relative']);

    // 0.09：相对工时视图顶部的两条说明条与轴标题的括号行已删除。
    expect(find.textContaining('时间轴是相对累计工时'), findsNothing);
    expect(find.textContaining('预计工时未知，时间轴上不给'), findsNothing);
    expect(find.text('任务 · 相对累计工时'), findsOneWidget);
    expect(find.textContaining('单人串行，不是日历排程'), findsNothing);
  });

  testWidgets('day/week scale and the today button stay available', (tester) async {
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(Recorded()),
    );
    expect(find.byKey(const Key('calendar-scale')), findsOneWidget);
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    // Week scale still shows real dates.
    expect(find.textContaining('11月18日'), findsWidgets);
    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
