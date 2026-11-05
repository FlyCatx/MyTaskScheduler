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

  testWidgets('edge auto-scroll follows the real pointer without double delta',
      (tester) async {
    final record = Recorded();
    await pumpCalendar(
      tester,
      schedule: version.calendar,
      calendarActions: actions(record),
    );
    final horizontal = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    final scroll = tester.state<ScrollableState>(horizontal);
    await tester.pump();

    final bar = find.byKey(const Key('calendar-segment-s2'));
    final start = tester.getCenter(bar);
    final gesture = await tester.startGesture(start);
    await tester.pump();
    for (var i = 0; i < 18; i++) {
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
    }
    final beforeOffset = scroll.position.pixels;

    String preview() =>
        tester.widget<Text>(find.textContaining('→').first).data!;
    int startMinutes(String text) {
      final m = RegExp(r'(\d{2}):(\d{2}) →').firstMatch(text)!;
      return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
    }

    final beforeMinutes = startMinutes(preview());
    // Five 40 ms auto-scroll ticks: 60 px of scroll = 60 / 0.8 = 75 minutes.
    await tester.pump(const Duration(milliseconds: 200));
    final afterOffset = scroll.position.pixels;
    final afterMinutes = startMinutes(preview());
    expect(afterOffset, greaterThan(beforeOffset), reason: '边缘应持续滚动');
    final expected = (afterOffset - beforeOffset) / 0.8;
    expect(afterMinutes - beforeMinutes, closeTo(expected, 6),
        reason: '只按真实滚动量移动，不能把鼠标位置再伪造一次（双倍位移）');

    // Move the same pointer to the left edge: direction must reverse immediately.
    final leftEdge = Offset(220, tester.getCenter(bar).dy);
    await gesture.moveTo(leftEdge);
    await tester.pump(const Duration(milliseconds: 200));
    expect(scroll.position.pixels, lessThan(afterOffset),
        reason: '移到左侧后应反向滚动，不能沿用旧方向');

    await gesture.up();
    await tester.pumpAndSettle();
    final stopped = scroll.position.pixels;
    await tester.pump(const Duration(milliseconds: 300));
    expect(scroll.position.pixels, closeTo(stopped, 0.5),
        reason: '释放后不能残留自动滚动计时器');
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

  // ---------------------------------------------------------------- 0.3.0 新增

  Future<void> resizeTo(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 用生产里的 [GanttPanel] 打开展示（模式选择器由它注入日历工具带）。
  Future<List<String>> pumpPanel(
    WidgetTester tester, {
    String initialMode = 'calendar',
    Size size = const Size(1200, 700),
    CalendarSchedule? schedule,
    bool canEdit = true,
    double textScale = 1.0,
  }) async {
    await resizeTo(tester, size);
    final modes = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: GanttPanel(
          snapshot: snapshot,
          interaction: TaskInteraction(),
          version: version,
          calendar: schedule ?? version.calendar,
          actions: actions(Recorded(), canEdit: canEdit),
          initialMode: initialMode,
          onModeChanged: modes.add,
          clock: at('2026-11-17 23:00'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return modes;
  }

  Finder horizontalScrollable() => find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.right);

  ScrollPosition horizontalPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(horizontalScrollable()).position;

  Future<void> scrollTo(WidgetTester tester, double target) async {
    horizontalPosition(tester).jumpTo(target);
    await tester.pumpAndSettle();
  }

  String zoomPercent(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('calendar-zoom-percent'))).data!;

  /// 表头文字左边缘（只考虑落在 [nearX] 附近 220 px 内的同一条标签）。
  double? headerLabelNear(WidgetTester tester, String label, double nearX) {
    for (final element in find.text(label).evaluate()) {
      final box = element.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      if ((left - nearX).abs() < 220) return left;
    }
    return null;
  }

  /// 唯一表头标签的左边缘（不要求当前滚动位置可见）。
  double labelLeft(WidgetTester tester, String label) {
    final elements = find.text(label).evaluate().toList(growable: false);
    expect(elements, hasLength(1), reason: '表头应只有一个“$label”');
    final box = elements.single.renderObject as RenderBox?;
    expect(box, isNotNull);
    return box!.localToGlobal(Offset.zero).dx;
  }

  testWidgets('模式选择并入日历工具带：与日/周/今天同一行，没有独立空行', (tester) async {
    await pumpPanel(tester);
    expect(find.byKey(const Key('gantt-submode')), findsOneWidget);
    expect(find.byKey(const Key('calendar-scale')), findsOneWidget);
    // 模式选择（日历排程/相对工时）与日/周、今天在同一条工具带里。
    final modeY = tester.getCenter(find.text('日历排程')).dy;
    for (final label in <String>['周', '今天', '可用时间', '自动安排', '重排全部']) {
      expect((tester.getCenter(find.text(label)).dy - modeY).abs(),
          lessThanOrEqualTo(1.0),
          reason: '“$label”必须与模式选择同处一条工具带（宽度足够时同处一行）');
    }
    // 视图顶部就是工具带：父级不再单独保留一行“日历视图 …”的空行。
    final viewTop = tester.getTopLeft(find.byType(CalendarGanttView)).dy;
    final modeTop = tester.getTopLeft(find.byKey(const Key('gantt-submode'))).dy;
    expect(modeTop - viewTop, lessThanOrEqualTo(1.0),
        reason: '工具带之后不能再有下面那样的独立模式行（0.3.0 去掉了红框空行）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('相对工时只保留模式选择 + 返回日历，切回仍写回 setGanttMode',
      (tester) async {
    final modes = await pumpPanel(tester, initialMode: 'relative');
    expect(find.byType(GanttChartView), findsOneWidget);
    expect(find.byKey(const Key('gantt-back-to-calendar')), findsOneWidget);
    // 仅对日历有效的操作在相对工时视图里不出现。
    expect(find.text('自动安排'), findsNothing);
    expect(find.text('重排全部'), findsNothing);
    expect(find.text('可用时间'), findsNothing);
    expect(find.text('周'), findsNothing);

    await tester.tap(find.byKey(const Key('gantt-back-to-calendar')));
    await tester.pumpAndSettle();
    expect(modes, <String>['calendar'], reason: '模式切换必须经 onModeChanged 写回');
    expect(find.byType(CalendarGanttView), findsOneWidget);
    // 日历模式下选择器已在工具带里，日/周等操作也回来了。
    expect(find.text('日历排程'), findsOneWidget);
    expect(find.text('自动安排'), findsOneWidget);

    await tester.tap(find.text('相对工时'));
    await tester.pumpAndSettle();
    expect(modes, <String>['calendar', 'relative']);
    expect(find.byType(GanttChartView), findsOneWidget);
  });

  testWidgets('窄窗只整组换行、不溢出，工具仍然可达', (tester) async {
    await pumpPanel(tester, size: const Size(560, 620));
    expect(tester.takeException(), isNull);
    for (final key in <Key>[
      const Key('gantt-submode'),
      const Key('calendar-scale'),
      const Key('calendar-zoom-in'),
      const Key('calendar-zoom-out'),
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }
    expect(find.text('自动安排'), findsOneWidget);
    // 换行后工具带更高；关键是控件彼此不重叠、都仍在视口内。
    final rects = <Rect>[
      tester.getRect(find.byKey(const Key('gantt-submode'))),
      tester.getRect(find.byKey(const Key('calendar-scale'))),
      tester.getRect(find.text('今天')),
      tester.getRect(find.text('可用时间')),
      tester.getRect(find.text('自动安排')),
      tester.getRect(find.text('重排全部')),
    ];
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(rects[i].overlaps(rects[j]), isFalse,
            reason: '窄窗下工具带控件不得互相覆盖（$i vs $j）');
      }
    }
  });

  testWidgets('右下角缩放条：百分比、上下限禁用、锚点时刻不跳', (tester) async {
    await pumpPanel(tester);
    expect(zoomPercent(tester), '100%');
    // 缩放条浮在图表视口右下角：不压住底部水平滚动条，也不在左侧任务名列上。
    final percentRect = tester.getRect(find.byKey(const Key('calendar-zoom-percent')));
    final viewRect = tester.getRect(find.byType(CalendarGanttView));
    expect(percentRect.right, lessThan(viewRect.right));
    expect(percentRect.bottom, lessThan(viewRect.bottom));
    expect(percentRect.left, greaterThan(viewRect.left + 300));

    await scrollTo(tester, 600);
    final position = horizontalPosition(tester);
    final viewport = position.viewportDimension;
    final beforeOffset = position.pixels;
    final centerMinutes = (beforeOffset + viewport / 2) / 0.8; // 日视图 48 px/小时
    await tester.tap(find.byKey(const Key('calendar-zoom-in')));
    await tester.pumpAndSettle();
    expect(zoomPercent(tester), '125%');
    expect(position.pixels,
        closeTo(centerMinutes * (0.8 * 1.25) - viewport / 2, 2.0),
        reason: '缩放后视口中心代表的时刻必须保持不变（用日历自己的滚动控制器换算）');

    await tester.tap(find.byKey(const Key('calendar-zoom-out')));
    await tester.pumpAndSettle();
    expect(zoomPercent(tester), '100%');

    // 一直放大到上限：按钮禁用，百分比停在 400%。
    for (var i = 0; i < 12; i++) {
      final button = tester.widget<InkWell>(find.descendant(
        of: find.byKey(const Key('calendar-zoom-in')),
        matching: find.byType(InkWell),
      ));
      if (button.onTap == null) break;
      await tester.tap(find.byKey(const Key('calendar-zoom-in')));
      await tester.pumpAndSettle();
    }
    expect(zoomPercent(tester), '400%');
    expect(
      tester
          .widget<InkWell>(find.descendant(
            of: find.byKey(const Key('calendar-zoom-in')),
            matching: find.byType(InkWell),
          ))
          .onTap,
      isNull,
      reason: '到上限必须禁用放大',
    );
    // 下限同理（400% → 50% 需要 8 次 −25%…这里只验证能到下限并禁用）。
    for (var i = 0; i < 20; i++) {
      final button = tester.widget<InkWell>(find.descendant(
        of: find.byKey(const Key('calendar-zoom-out')),
        matching: find.byType(InkWell),
      ));
      if (button.onTap == null) break;
      await tester.tap(find.byKey(const Key('calendar-zoom-out')));
      await tester.pumpAndSettle();
    }
    expect(zoomPercent(tester), '50%');
    expect(
      tester
          .widget<InkWell>(find.descendant(
            of: find.byKey(const Key('calendar-zoom-out')),
            matching: find.byType(InkWell),
          ))
          .onTap,
      isNull,
      reason: '到下限必须禁用缩小',
    );
  });

  testWidgets('缩放后同一时刻的表头与任务块仍然对齐（日/周两种刻度）', (tester) async {
    await pumpPanel(tester);
    await scrollTo(tester, 300);

    double dayAlignmentDelta() {
      final seg = tester.getTopLeft(find.byKey(const Key('calendar-segment-s1'))).dx;
      final tick = headerLabelNear(tester, '08:00', seg);
      expect(tick, isNotNull, reason: '日视图应能看到 08:00 时刻刻度');
      // 表头小时文字左侧有 4 px 内边距，任务块从精确时刻开始。
      return tick! - seg;
    }

    for (var i = 0; i < 2; i++) {
      final delta = dayAlignmentDelta();
      expect(delta, inInclusiveRange(2.5, 6.0),
          reason: '表头 08:00 与 08:00 开始的任务块必须对在同一时刻（第 $i 次）');
      if (i == 0) {
        await tester.tap(find.byKey(const Key('calendar-zoom-in')));
      } else {
        await tester.tap(find.byKey(const Key('calendar-zoom-out')));
      }
      await tester.pumpAndSettle();
    }

    // 周视图：用两天表头实测“每天宽度”，再验证同一时刻的偏移比例不变。
    await tester.tap(find.text('周'));
    await tester.pumpAndSettle();
    await scrollTo(tester, 200);
    final day0 = labelLeft(tester, '11月18日 周三');
    final day1 = labelLeft(tester, '11月19日 周四');
    final dayWidth = day1 - day0;
    expect(dayWidth, greaterThan(100));
    // s3 = 2026-11-19 08:00 → 距范围起点 32 小时（1 天 + 8 小时）。
    final s3 = tester.getTopLeft(find.byKey(const Key('calendar-segment-s3'))).dx;
    final expected = day0 + dayWidth + dayWidth / 24 * 8 - 5;
    expect(s3, closeTo(expected, 2.5),
        reason: '周视图表头日期与任务块必须用同一套每小时宽度');

    await tester.tap(find.byKey(const Key('calendar-zoom-in')));
    await tester.pumpAndSettle();
    final day0b = labelLeft(tester, '11月18日 周三');
    final day1b = labelLeft(tester, '11月19日 周四');
    final dayWidthB = day1b - day0b;
    final s3b = tester.getTopLeft(find.byKey(const Key('calendar-segment-s3'))).dx;
    expect(s3b, closeTo(day0b + dayWidthB + dayWidthB / 24 * 8 - 5, 2.5),
        reason: '缩放后表头与任务块仍对齐');
  });

  testWidgets('只读历史版本仍可缩放，编辑禁用逻辑不变', (tester) async {
    await pumpPanel(tester, canEdit: false);
    expect(find.text('历史版本只读'), findsOneWidget);
    expect(zoomPercent(tester), '100%');
    await tester.tap(find.byKey(const Key('calendar-zoom-in')));
    await tester.pumpAndSettle();
    expect(zoomPercent(tester), '125%');
    expect(tester.takeException(), isNull);
    // 日历工具带里的编辑动作仍禁用（仅有日历有效的动作按原条件显示）。
    final auto = tester.widget<FilledButton>(find.ancestor(
      of: find.text('自动安排'),
      matching: find.byType(FilledButton),
    ));
    expect(auto.onPressed, isNull);
  });
}
