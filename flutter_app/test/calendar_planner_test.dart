// Calendar engine tests (0.06).
//
// Everything runs on a fixed clock and a fixed +08:00 wall clock, so "今天/明天/跨天"
// cannot depend on when the suite runs. Expectations are written against wall-clock
// strings (`at('2026-11-18 08:00')`) which is much easier to audit than epoch numbers.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';

const int _offset = 480; // +08:00

/// Wall clock (+08:00) → UTC instant.
DateTime at(String wall) {
  final parts = wall.split(' ');
  final date = parts[0].split('-').map(int.parse).toList();
  final time = parts.length > 1 ? parts[1].split(':').map(int.parse).toList() : [0, 0];
  return DateTime.utc(date[0], date[1], date[2], time[0], time[1])
      .subtract(const Duration(minutes: _offset));
}

String wall(DateTime instant) {
  final w = const WallClock(_offset).toWall(instant);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${WallClock.formatDateKey(w.year, w.month, w.day)} '
      '${two(w.hour)}:${two(w.minute)}';
}

/// Weekly availability that is identical on every weekday.
CalendarSettings settingsWith(
  List<WallClockRange> ranges, {
  int days = 7,
  String start = '2026-11-18',
  List<CalendarDateException> exceptions = const [],
  List<CalendarOccupancy> occupancies = const [],
}) =>
    CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: start,
      planningDays: days,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: ranges,
      }),
      exceptions: exceptions,
      occupancies: occupancies,
      snapMinutes: 15,
      chunkMinutes: 120,
    );

SchedulingTask task(
  String id,
  double hours, {
  List<String> dependsOn = const [],
  String? deadline,
  bool done = false,
  bool blocked = false,
  bool pending = false,
  int order = 0,
}) =>
    SchedulingTask(
      id: id,
      name: id,
      estimatedHours: hours,
      dependsOn: dependsOn,
      deadline: deadline,
      isDone: done,
      isBlocked: blocked,
      isPending: pending,
      orderIndex: order,
    );

String Function() ids() {
  var n = 0;
  return () => 'seg-${n++}';
}

void main() {
  // Tuesday 2026-11-17 23:00 UTC == Wednesday 2026-11-18 07:00 +08:00.
  final now = DateTime.utc(2026, 11, 17, 23);

  group('availability', () {
    test('empty weekly availability is never treated as 24/7', () {
      const settings = CalendarSettings(
        timezoneOffsetMinutes: _offset,
        planningStartDate: '2026-11-18',
        planningDays: 3,
      );
      final calendar = buildAvailability(settings);
      expect(calendar.open, isEmpty);
      expect(calendar.totalMinutes, 0);
      expect(settings.hasAvailability, isFalse);
    });

    test('expands a weekly window for every day of the planning range', () {
      final calendar = buildAvailability(
        settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 3),
      );
      expect(calendar.open.length, 3);
      expect(wall(calendar.open.first.start), '2026-11-18 08:00');
      expect(wall(calendar.open.first.end), '2026-11-18 12:00');
      expect(calendar.totalMinutes, 3 * 4 * 60);
    });

    test('subtracts course occupancy and merges the remaining windows', () {
      final calendar = buildAvailability(settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-1',
            title: '线性代数',
            kind: 'course',
            weekday: 3, // 2026-11-18 is a Wednesday
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      ));
      expect(calendar.open.length, 2);
      expect(wall(calendar.open[0].start), '2026-11-18 08:00');
      expect(wall(calendar.open[0].end), '2026-11-18 09:00');
      expect(wall(calendar.open[1].start), '2026-11-18 10:00');
      expect(wall(calendar.open[1].end), '2026-11-18 12:00');
    });

    test('a closed date exception removes that day only', () {
      final calendar = buildAvailability(settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 2,
        exceptions: const [
          CalendarDateException(date: '2026-11-18', closed: true, note: '看巡演'),
        ],
      ));
      expect(calendar.open.length, 1);
      expect(wall(calendar.open.single.start), '2026-11-19 08:00');
    });

    test('a window that runs past midnight keeps both dates', () {
      final calendar = buildAvailability(settingsWith(
        const [WallClockRange(22 * 60, 24 * 60 + 2 * 60)],
        days: 2,
      ));
      // Two separate nights: 22:00-02:00, then 22:00-02:00 again. They must not be
      // merged into one continuous 28-hour block, and neither may lose its date.
      expect(calendar.open.length, 2);
      expect(wall(calendar.open[0].start), '2026-11-18 22:00');
      expect(wall(calendar.open[0].end), '2026-11-19 02:00');
      expect(wall(calendar.open[1].start), '2026-11-19 22:00');
      expect(wall(calendar.open[1].end), '2026-11-20 02:00');
    });
  });

  group('auto schedule', () {
    test('a task split across days never crosses an unavailable window', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 9 * 60)], days: 7),
        ),
        tasks: [task('t1', 3)],
        now: now,
        newId: ids(),
      );
      final segments = plan.schedule.forTask('t1');
      expect(segments.length, 3);
      expect(segments.map((s) => s.minutes), [60, 60, 60]);
      expect(segments.map((s) => wall(s.start)),
          ['2026-11-18 08:00', '2026-11-19 08:00', '2026-11-20 08:00']);
      expect(plan.taskNotes, isEmpty);
    });

    test('total allocated time equals the estimate exactly', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(
            const [WallClockRange(8 * 60, 12 * 60), WallClockRange(14 * 60, 18 * 60)],
            days: 3,
          ),
        ),
        tasks: [task('t1', 5)],
        now: now,
        newId: ids(),
      );
      final segments = plan.schedule.forTask('t1');
      expect(segments.fold<int>(0, (sum, s) => sum + s.minutes), 300);
      // 08:00–12:00 then 14:00–15:00: the 12:00–14:00 gap is never bridged.
      expect(wall(segments.first.start), '2026-11-18 08:00');
      expect(wall(segments.first.end), '2026-11-18 12:00');
      expect(wall(segments.last.start), '2026-11-18 14:00');
      expect(wall(segments.last.end), '2026-11-18 15:00');
      for (final s in segments) {
        expect(s.start.isBefore(s.end), isTrue);
      }
    });

    test('a successor never starts before its predecessor ends', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 2),
        ),
        tasks: [
          task('a', 2),
          task('b', 2, dependsOn: ['a']),
        ],
        now: now,
        newId: ids(),
      );
      final a = plan.schedule.forTask('a');
      final b = plan.schedule.forTask('b');
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(
        b.first.start.isBefore(a.last.end),
        isFalse,
        reason: 'b must start after a finished',
      );
    });

    test('earlier deadline wins, and the deadline itself is never rewritten', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 10 * 60)], days: 3),
        ),
        tasks: [
          task('late', 2, deadline: '2026-11-25 20:00'),
          task('early', 2, deadline: '2026-11-19 09:00'),
        ],
        now: now,
        newId: ids(),
      );
      expect(wall(plan.schedule.forTask('early').first.start), '2026-11-18 08:00');
      // The 18th only has 08:00-10:00, so the later task takes the next free window
      // instead of overlapping the earlier-deadline one.
      expect(wall(plan.schedule.forTask('late').first.start), '2026-11-19 08:00');
      expect(
        plan.schedule.segments.any((s) => s.start.isAfter(at('2026-11-25 20:00'))),
        isFalse,
      );
    });

    test('insufficient capacity reports the remainder instead of inventing time', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 9 * 60)], days: 2),
        ),
        tasks: [task('t1', 5)],
        now: now,
        newId: ids(),
      );
      final segments = plan.schedule.forTask('t1');
      expect(segments.fold<int>(0, (sum, s) => sum + s.minutes), 120);
      expect(plan.taskNotes['t1'], contains('容量不足'));
      // Nothing beyond the planning range was fabricated.
      expect(
        segments.every((s) => !s.start.isAfter(at('2026-11-20 00:00'))),
        isTrue,
      );
    });

    test('unknown hours and dependency cycles are reported, not scheduled', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 3),
        ),
        tasks: [
          task('unknown', 0),
          task('x', 1, dependsOn: ['y']),
          task('y', 1, dependsOn: ['x']),
        ],
        now: now,
        newId: ids(),
      );
      expect(plan.schedule.segments, isEmpty);
      expect(plan.taskNotes['unknown'], contains('工时未知'));
      expect(plan.notes.join(), contains('依赖成环'));
    });

    test('completed tasks do not consume future capacity', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1),
        ),
        tasks: [task('done', 2, done: true), task('todo', 1)],
        now: now,
        newId: ids(),
      );
      expect(plan.schedule.forTask('done'), isEmpty);
      expect(wall(plan.schedule.forTask('todo').single.start), '2026-11-18 08:00');
    });

    test('keepManual preserves hand-dragged segments and fills around them', () {
      final manual = ScheduleSegment(
        id: 'manual-1',
        taskId: 't1',
        start: at('2026-11-18 08:00'),
        end: at('2026-11-18 09:00'),
        source: SegmentSource.manual,
      );
      final current = CalendarSchedule(
        settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1),
        segments: [manual],
      );
      final plan = autoSchedule(
        current: current,
        tasks: [task('t1', 3)],
        now: now,
        keepManual: true,
        newId: ids(),
      );
      final segments = plan.schedule.forTask('t1');
      expect(segments.any((s) => s.id == 'manual-1'), isTrue);
      expect(segments.fold<int>(0, (sum, s) => sum + s.minutes), 180);
      expect(wall(segments.last.start), '2026-11-18 09:00');
    });

    test('rescheduling everything drops manual segments and rebuilds', () {
      final manual = ScheduleSegment(
        id: 'manual-1',
        taskId: 't1',
        start: at('2026-11-18 10:00'),
        end: at('2026-11-18 11:00'),
        source: SegmentSource.manual,
      );
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1),
          segments: [manual],
        ),
        tasks: [task('t1', 1)],
        now: now,
        keepManual: false,
        newId: ids(),
      );
      expect(plan.schedule.forTask('t1').single.id, isNot('manual-1'));
      expect(wall(plan.schedule.forTask('t1').single.start), '2026-11-18 08:00');
    });

    test('is deterministic for the same input and independent of task order', () {
      CalendarAutoPlan run(List<SchedulingTask> tasks) => autoSchedule(
            current: CalendarSchedule(
              settings:
                  settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 3),
            ),
            tasks: tasks,
            suggestedOrder: const ['a', 'b'],
            now: now,
            newId: ids(),
          );
      final first = run([task('a', 2), task('b', 1)]);
      final second = run([task('b', 1), task('a', 2)]);
      String digest(CalendarAutoPlan plan) => plan.schedule.segments
          .map((s) => '${s.taskId}:${wall(s.start)}-${wall(s.end)}')
          .join('|');
      expect(digest(first), digest(second));
    });

    test('blocked/pending tasks get tentative segments without changing status', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings: settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1),
        ),
        tasks: [task('blocked', 1, blocked: true)],
        now: now,
        newId: ids(),
      );
      expect(plan.schedule.forTask('blocked').single.tentative, isTrue);
    });

    test('without availability nothing is scheduled and the reason says why', () {
      final plan = autoSchedule(
        current: CalendarSchedule(settings: CalendarSettings.blank(now: now)),
        tasks: [task('t1', 1)],
        now: now,
        newId: ids(),
      );
      expect(plan.schedule.segments, isEmpty);
      expect(plan.notes.join(), contains('没有可用时间'));
    });
  });

  group('conflicts', () {
    CalendarSchedule scheduleWith(
      List<ScheduleSegment> segments, {
      List<CalendarOccupancy> occupancies = const [],
    }) =>
        CalendarSchedule(
          settings: settingsWith(
            const [WallClockRange(8 * 60, 12 * 60)],
            days: 3,
            occupancies: occupancies,
          ),
          segments: segments,
        );

    test('two tasks on the same window are reported as a task overlap', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith([
          ScheduleSegment(
            id: 's1',
            taskId: 'a',
            start: at('2026-11-18 08:00'),
            end: at('2026-11-18 10:00'),
          ),
          ScheduleSegment(
            id: 's2',
            taskId: 'b',
            start: at('2026-11-18 09:00'),
            end: at('2026-11-18 11:00'),
          ),
        ]),
        tasks: [task('a', 2), task('b', 2)],
        now: now,
      );
      expect(conflicts.map((c) => c.kind), contains(ConflictKind.taskOverlap));
      expect(conflicts.first.message, contains('重叠'));
    });

    test('one task overlapping itself is a self overlap, not a merge', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith([
          ScheduleSegment(
            id: 's1',
            taskId: 'a',
            start: at('2026-11-18 08:00'),
            end: at('2026-11-18 10:00'),
          ),
          ScheduleSegment(
            id: 's2',
            taskId: 'a',
            start: at('2026-11-18 09:00'),
            end: at('2026-11-18 11:00'),
          ),
        ]),
        tasks: [task('a', 4)],
        now: now,
      );
      expect(conflicts.map((c) => c.kind), contains(ConflictKind.selfOverlap));
    });

    test('work inside a course block is flagged as unavailable time', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith(
          [
            ScheduleSegment(
              id: 's1',
              taskId: 'a',
              start: at('2026-11-18 08:00'),
              end: at('2026-11-18 10:00'),
            ),
          ],
          occupancies: const [
            CalendarOccupancy(
              id: 'occ-1',
              title: '大学物理',
              kind: 'course',
              weekday: 3,
              ranges: [WallClockRange(9 * 60, 10 * 60)],
            ),
          ],
        ),
        tasks: [task('a', 2)],
        now: now,
      );
      final unavailable =
          conflicts.where((c) => c.kind == ConflictKind.unavailable).toList();
      expect(unavailable, isNotEmpty);
      expect(unavailable.first.message, contains('大学物理'));
    });

    test('a successor scheduled before its predecessor is a dependency conflict', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith([
          ScheduleSegment(
            id: 's1',
            taskId: 'a',
            start: at('2026-11-18 10:00'),
            end: at('2026-11-18 12:00'),
          ),
          ScheduleSegment(
            id: 's2',
            taskId: 'b',
            start: at('2026-11-18 08:00'),
            end: at('2026-11-18 09:00'),
          ),
        ]),
        tasks: [
          task('a', 2),
          task('b', 1, dependsOn: ['a']),
        ],
        now: now,
      );
      expect(conflicts.map((c) => c.kind),
          contains(ConflictKind.dependencyOrder));
    });

    test('past-deadline work and unscheduled predecessors are reported', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith([
          ScheduleSegment(
            id: 's1',
            taskId: 'b',
            start: at('2026-11-18 08:00'),
            end: at('2026-11-18 09:00'),
          ),
        ]),
        tasks: [
          task('b', 1, dependsOn: ['a'], deadline: '2026-11-18 08:30'),
          task('a', 1),
        ],
        now: now,
      );
      final kinds = conflicts.map((c) => c.kind).toSet();
      expect(kinds, contains(ConflictKind.pastDeadline));
      expect(kinds, contains(ConflictKind.uncertainDependency));
    });

    test('a clean automatic plan has no conflicts', () {
      final plan = autoSchedule(
        current: CalendarSchedule(
          settings:
              settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 3),
        ),
        tasks: [task('a', 2), task('b', 1, dependsOn: ['a'])],
        now: now,
        newId: ids(),
      );
      final conflicts = detectConflicts(
        schedule: plan.schedule,
        tasks: [task('a', 2), task('b', 1, dependsOn: ['a'])],
        now: now,
      );
      expect(conflicts, isEmpty);
    });
  });
}

