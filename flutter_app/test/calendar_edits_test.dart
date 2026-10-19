// Calendar edit rules (0.06): moving / resizing / splitting / adding / cancelling a
// segment, and how the estimated hours must follow.
//
// The product decision is explicit: the estimate changes by the *delta* of the edited
// segment, never by the earliest-start-to-latest-end span, and cancelling an
// arrangement must not delete work.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';

const int _offset = 480;

DateTime at(String wall) {
  final parts = wall.split(' ');
  final date = parts[0].split('-').map(int.parse).toList();
  final time =
      parts.length > 1 ? parts[1].split(':').map(int.parse).toList() : [0, 0];
  return DateTime.utc(date[0], date[1], date[2], time[0], time[1])
      .subtract(const Duration(minutes: _offset));
}

CalendarSettings get _settings => CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-18',
      planningDays: 14,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(0, 1440)],
      }),
    );

TaskRecord task(String id, double? hours) =>
    TaskRecord(id: id, name: id, estimatedHours: hours);

ScheduleSegment segment(
  String id,
  String taskId,
  String start,
  String end, {
  SegmentSource source = SegmentSource.manual,
  bool tentative = false,
}) =>
    ScheduleSegment(
      id: id,
      taskId: taskId,
      start: at(start),
      end: at(end),
      source: source,
      tentative: tentative,
    );

CalendarSchedule scheduleWith(List<ScheduleSegment> segments) =>
    CalendarSchedule(settings: _settings, segments: segments);

void main() {
  test('moving a segment keeps its duration and the estimate', () {
    final tasks = [task('t', 1.5)];
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:30'),
    ]);
    final outcome = moveSegment(
      schedule: schedule,
      tasks: tasks,
      segmentId: 's1',
      newStart: at('2026-11-19 14:00'),
    );
    expect(outcome.error, isNull);
    final moved = outcome.schedule!.forTask('t').single;
    expect(moved.minutes, 90);
    expect(moved.start, at('2026-11-19 14:00'));
    expect(moved.end, at('2026-11-19 15:30'));
    expect(outcome.tasks!.single.estimatedHours, 1.5);
    // Any manual move marks the segment as hand-made so "重新安排" keeps it.
    expect(moved.source, SegmentSource.manual);
  });

  test('a fully scheduled task follows the sum of its segments', () {
    final tasks = [task('t', 3)];
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:00'),
      segment('s2', 't', '2026-11-19 08:00', '2026-11-19 10:00'),
    ]);
    final outcome = resizeSegment(
      schedule: schedule,
      tasks: tasks,
      segmentId: 's2',
      newEnd: at('2026-11-19 10:30'),
    );
    expect(outcome.tasks!.single.estimatedHours, 3.5);
    expect(outcome.schedule!.minutesForTask('t'), 210);
  });

  test('a partially scheduled task keeps its unallocated balance', () {
    // Estimate 3h, only 1h placed => 2h still unallocated.
    final tasks = [task('t', 3)];
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:00'),
    ]);
    final outcome = resizeSegment(
      schedule: schedule,
      tasks: tasks,
      segmentId: 's1',
      newEnd: at('2026-11-18 09:30'),
    );
    expect(outcome.tasks!.single.estimatedHours, 3.5,
        reason: 'estimate = old + delta, not the sum of segments');
    final allocated = outcome.schedule!.minutesForTask('t');
    expect(allocated, 90);
    expect(outcome.tasks!.single.estimatedHours! * 60 - allocated, 120,
        reason: 'the 2h unallocated balance must survive the drag');
  });

  test('a zero or negative duration is refused, not saved', () {
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:00'),
    ]);
    final outcome = resizeSegment(
      schedule: schedule,
      tasks: [task('t', 1)],
      segmentId: 's1',
      newEnd: at('2026-11-18 08:00'),
    );
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('结束时间'));
    expect(outcome.schedule, isNull);
  });

  test('cancelling an arrangement returns the work to the balance', () {
    final tasks = [task('t', 3)];
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 10:00'),
    ]);
    final outcome = cancelSegment(
      schedule: schedule,
      tasks: tasks,
      segmentId: 's1',
    );
    expect(outcome.schedule!.segments, isEmpty);
    expect(outcome.tasks!.single.estimatedHours, 3,
        reason: 'cancelling an arrangement is not a reduction of work');
    expect(outcome.message, contains('未安排余额'));
  });

  test('adding a segment raises the estimate by exactly its duration', () {
    final outcome = addSegment(
      schedule: scheduleWith(const []),
      tasks: [task('t', 1.5)],
      taskId: 't',
      start: at('2026-11-18 08:00'),
      end: at('2026-11-18 08:45'),
      newId: 's-new',
    );
    expect(outcome.tasks!.single.estimatedHours, 2.25);
    expect(outcome.schedule!.segments.single.id, 's-new');
  });

  test('splitting keeps the total duration (3h => 1h + 2h across days)', () {
    final tasks = [task('t', 3)];
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 23:00', '2026-11-19 02:00'),
    ]);
    final outcome = splitSegment(
      schedule: schedule,
      tasks: tasks,
      segmentId: 's1',
      at: at('2026-11-19 00:00'),
      newId: 's2',
    );
    final pieces = outcome.schedule!.forTask('t');
    expect(pieces.length, 2);
    expect(pieces.map((p) => p.minutes), [60, 120]);
    expect(pieces.fold<int>(0, (s, p) => s + p.minutes), 180);
    expect(outcome.tasks!.single.estimatedHours, 3);
  });

  test('a split point outside the segment is refused', () {
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:00'),
    ]);
    for (final bad in ['2026-11-18 08:00', '2026-11-18 09:00']) {
      final outcome = splitSegment(
        schedule: schedule,
        tasks: [task('t', 1)],
        segmentId: 's1',
        at: at(bad),
      );
      expect(outcome.ok, isFalse);
    }
  });

  test('an unknown segment id is a structural error, not a silent no-op', () {
    final outcome = moveSegment(
      schedule: scheduleWith(const []),
      tasks: [task('t', 1)],
      segmentId: 'missing',
      newStart: at('2026-11-18 08:00'),
    );
    expect(outcome.ok, isFalse);
    expect(outcome.error, isNotNull);
  });

  test('tentative segments keep the flag across edits', () {
    final schedule = scheduleWith([
      segment('s1', 't', '2026-11-18 08:00', '2026-11-18 09:00',
          tentative: true),
    ]);
    final moved = moveSegment(
      schedule: schedule,
      tasks: [task('t', 1)],
      segmentId: 's1',
      newStart: at('2026-11-18 10:00'),
    );
    expect(moved.schedule!.segments.single.tentative, isTrue);
  });
}

