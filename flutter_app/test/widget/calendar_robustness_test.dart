// Robustness of the calendar surfaces (0.06): dark theme, enlarged text, odd window
// widths and a scaled device pixel ratio. None of these may throw, overflow or lose the
// real-date axis — a desktop app is used at 100/125/150% scaling and with larger fonts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_gantt.dart';
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

void main() {
  final plan = samplePlan();
  final snapshot = FakeScheduleEngine.buildSnapshotFor(plan);
  final schedule = CalendarSchedule(
    settings: CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-18',
      planningDays: 5,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 1080)],
      }),
      occupancies: const [
        CalendarOccupancy(
          id: 'occ-1',
          title: '大学物理',
          kind: 'course',
          weekday: 3,
          ranges: [WallClockRange(540, 600)],
        ),
      ],
    ),
    segments: [
      ScheduleSegment(
        id: 's1',
        taskId: 'task-a',
        start: at('2026-11-18 08:00'),
        end: at('2026-11-18 08:30'),
      ),
      ScheduleSegment(
        id: 's2',
        taskId: 'task-b',
        start: at('2026-11-18 14:00'),
        end: at('2026-11-18 16:00'),
      ),
    ],
  );
  final version = PlanVersion(
    id: 'ver-1',
    conversationId: 'conv-1',
    createdAt: at('2026-11-18 07:00'),
    summary: plan.summary,
    tasks: plan.tasks,
    calendar: schedule,
  );

  CalendarActions readOnly() => CalendarActions.readOnly();

  Future<void> pumpAt(
    WidgetTester tester, {
    required Brightness brightness,
    required double textScale,
    required double dpr,
    required Size size,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = size * dpr;
    addTearDown(tester.view.reset);
    TsColors.apply(brightness);
    addTearDown(() => TsColors.apply(Brightness.light));
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Sizedbox966(
          child: CalendarGanttView(
            snapshot: snapshot,
            version: version,
            schedule: schedule,
            interaction: TaskInteraction(),
            actions: readOnly(),
            clock: at('2026-11-17 23:00'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets('renders without overflow in ${brightness.name} theme',
        (tester) async {
      await pumpAt(tester,
          brightness: brightness,
          textScale: 1,
          dpr: 1,
          size: const Size(1000, 680));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('11月18日'), findsWidgets);
      expect(find.byKey(const Key('calendar-segment-s2')), findsOneWidget);
    });
  }

  testWidgets('survives enlarged text (1.5x) without exceptions', (tester) async {
    await pumpAt(tester,
        brightness: Brightness.light,
        textScale: 1.5,
        dpr: 1,
        size: const Size(1100, 720));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('calendar-segment-s2')), findsOneWidget);
  });

  testWidgets('survives a 150% device pixel ratio and a narrow window',
      (tester) async {
    await pumpAt(tester,
        brightness: Brightness.light,
        textScale: 1,
        dpr: 1.5,
        size: const Size(720, 520));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('calendar-segment-s2')), findsOneWidget);
  });

  testWidgets('a very narrow window still keeps the axis and the bars usable',
      (tester) async {
    await pumpAt(tester,
        brightness: Brightness.light,
        textScale: 1,
        dpr: 1,
        size: const Size(560, 480));
    expect(tester.takeException(), isNull);
    // The toolbar wraps instead of overflowing; the bars are still rendered.
    expect(find.byKey(const Key('calendar-segment-s2')), findsOneWidget);
  });
}

/// Small helper so the calendar always gets a bounded box in these tests.
class Sizedbox966 extends StatelessWidget {
  final Widget child;
  const Sizedbox966({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}

