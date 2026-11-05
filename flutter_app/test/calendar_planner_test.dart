// Calendar engine tests (0.06).
//
// Everything runs on a fixed clock and a fixed +08:00 wall clock, so "今天/明天/跨天"
// cannot depend on when the suite runs. Expectations are written against wall-clock
// strings (`at('2026-11-18 08:00')`) which is much easier to audit than epoch numbers.

import 'dart:io';

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

  group('conflict sources（R1-C 结构化来源旁路）', () {
    CalendarSchedule scheduleWith(
      List<ScheduleSegment> segments, {
      List<CalendarOccupancy> occupancies = const [],
      List<CalendarDateException> exceptions = const [],
      int days = 3,
    }) =>
        CalendarSchedule(
          settings: settingsWith(
            const [WallClockRange(8 * 60, 12 * 60)],
            days: days,
            occupancies: occupancies,
            exceptions: exceptions,
          ),
          segments: segments,
        );

    test('detectConflicts 给重叠/自身重叠填充来源，既有字段不变', () {
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
          ScheduleSegment(
            id: 's3',
            taskId: 'a',
            start: at('2026-11-18 09:30'),
            end: at('2026-11-18 10:30'),
          ),
        ]),
        tasks: [task('a', 3), task('b', 2)],
        now: now,
      );
      final overlap =
          conflicts.firstWhere((c) => c.kind == ConflictKind.taskOverlap);
      expect(overlap.source, ConflictSource.taskReservation);
      expect(overlap.message, contains('重叠'));
      final self =
          conflicts.firstWhere((c) => c.kind == ConflictKind.selfOverlap);
      expect(self.source, ConflictSource.selfOverlap);
    });

    test('不可用来源区分用户占用/未绑定预留/日期关闭/默认不可用', () {
      ConflictSource sourceFor(CalendarSchedule schedule) {
        final conflict = detectConflicts(
          schedule: schedule,
          tasks: [task('a', 2)],
          now: now,
        ).firstWhere((c) => c.kind == ConflictKind.unavailable);
        return conflict.source!;
      }

      final segment = ScheduleSegment(
        id: 's1',
        taskId: 'a',
        start: at('2026-11-18 08:00'),
        end: at('2026-11-18 10:00'),
      );
      expect(
        sourceFor(scheduleWith(
          [segment],
          occupancies: const [
            CalendarOccupancy(
              id: 'occ',
              title: '线性代数',
              kind: 'course',
              weekday: 3,
              ranges: [WallClockRange(9 * 60, 10 * 60)],
            ),
          ],
        )),
        ConflictSource.userOccupancy,
      );
      expect(
        sourceFor(scheduleWith(
          [segment],
          occupancies: const [
            CalendarOccupancy(
              id: 'res-1',
              title: '任务预留',
              kind: 'activity',
              weekday: 3,
              ranges: [WallClockRange(9 * 60, 10 * 60)],
            ),
          ],
        )),
        ConflictSource.taskReservationUnbound,
      );
      expect(
        sourceFor(scheduleWith(
          [segment],
          exceptions: const [
            CalendarDateException(date: '2026-11-18', closed: true),
          ],
        )),
        ConflictSource.defaultUnavailable,
      );
      // 落在两个可用窗口之间的缝隙。
      expect(
        sourceFor(CalendarSchedule(
          settings: settingsWith(
            const [
              WallClockRange(8 * 60, 9 * 60),
              WallClockRange(10 * 60, 12 * 60),
            ],
            days: 1,
          ),
          segments: [segment],
        )),
        ConflictSource.defaultUnavailable,
      );
    });

    test('依赖/截止/超出规划范围映射到 dependency/deadline/capacity', () {
      final conflicts = detectConflicts(
        schedule: scheduleWith(
          [
            ScheduleSegment(
              id: 's1',
              taskId: 'a',
              start: at('2026-11-18 08:00'),
              end: at('2026-11-18 10:00'),
            ),
            ScheduleSegment(
              id: 's2',
              taskId: 'b',
              start: at('2026-11-18 08:00'),
              end: at('2026-11-18 09:00'),
            ),
            ScheduleSegment(
              id: 's3',
              taskId: 'c',
              start: at('2026-11-21 08:00'),
              end: at('2026-11-21 09:00'),
            ),
          ],
          days: 2,
        ),
        tasks: [
          task('a', 2),
          task('b', 1, dependsOn: ['a'], deadline: '2026-11-18 08:30'),
          task('c', 1),
        ],
        now: now,
      );
      ConflictSource? sourceOf(ConflictKind kind) {
        for (final conflict in conflicts) {
          if (conflict.kind == kind) return conflict.source;
        }
        return null;
      }

      expect(sourceOf(ConflictKind.dependencyOrder), ConflictSource.dependency);
      expect(sourceOf(ConflictKind.pastDeadline), ConflictSource.deadline);
      expect(sourceOf(ConflictKind.outsideRange), ConflictSource.capacity);
    });

    test('conflictSourceOf 可用同一设置快照重新判定旧冲突', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ',
            title: '班会',
            kind: 'activity',
            weekday: 3,
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      );
      final conflict = CalendarConflict(
        kind: ConflictKind.unavailable,
        taskId: 'a',
        start: at('2026-11-18 09:00'),
        end: at('2026-11-18 10:00'),
        message: '旧冲突没有 source',
      );
      expect(conflict.source, isNull);
      expect(
        conflictSourceOf(
          conflict,
          schedule: CalendarSchedule(settings: settings),
        ),
        ConflictSource.userOccupancy,
      );
    });
  });

  // -------------------------------------------------------------------------
  // R3+ task 06 B: scheduling quality.
  // -------------------------------------------------------------------------

  group('auto schedule quality (R3+ task 06 B)', () {
    /// Every generated plan must satisfy the structural constraints, no matter
    /// which heuristic/local-search candidate won.
    void expectFeasiblePlan(CalendarAutoPlan plan, List<SchedulingTask> tasks) {
      final settings = plan.schedule.settings;
      final availability = buildAvailability(settings);
      final segments = List<ScheduleSegment>.from(plan.schedule.segments)
        ..sort((a, b) => a.start.compareTo(b.start));
      for (var i = 0; i < segments.length; i++) {
        final s = segments[i];
        expect(
          subtractIntervals([s.interval], availability.open),
          isEmpty,
          reason: '${s.taskId} 落在可用时间之外：${wall(s.start)}-${wall(s.end)}',
        );
        expect(s.start.isBefore(settings.startInstant), isFalse);
        expect(s.end.isAfter(settings.endInstant), isFalse);
        if (i > 0) {
          expect(
            segments[i - 1].end.isAfter(s.start),
            isFalse,
            reason: '${segments[i - 1].taskId} 与 ${s.taskId} 重叠',
          );
        }
      }
      // Dependencies are respected; never more minutes than the estimate.
      for (final task in tasks) {
        if (task.isDone) continue;
        final own = plan.schedule.forTask(task.id);
        final placed = own.fold<int>(0, (sum, s) => sum + s.minutes);
        expect(placed, lessThanOrEqualTo(task.estimatedMinutes),
            reason: '${task.id} 被安排了超过预计工时的分钟数');
        for (final dep in task.dependsOn) {
          final depSegments = plan.schedule.forTask(dep);
          if (own.isEmpty || depSegments.isEmpty) continue;
          expect(
            own.first.start.isBefore(depSegments.last.end),
            isFalse,
            reason: '${task.id} 在前置 $dep 完成前开始',
          );
        }
      }
    }

    List<int> minutesPerTask(CalendarAutoPlan plan, List<SchedulingTask> tasks) =>
        [
          for (final t in tasks) plan.schedule.minutesForTask(t.id),
        ];

    test('反例：A→B(11:00)→C(13:00) 在 09:00–13:00 内全部按时', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 13 * 60)], days: 1);
      final tasks = [
        task('A', 1),
        task('B', 1, dependsOn: ['A'], deadline: '2026-11-18 11:00'),
        task('C', 2, deadline: '2026-11-18 13:00'),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      final a = plan.schedule.forTask('A');
      final b = plan.schedule.forTask('B');
      final c = plan.schedule.forTask('C');
      // Feasible solution A→B→C; the old order scheduled C first and made B
      // finish at 13:00 (1 overdue task / 120 overdue minutes).
      expect([wall(a.single.start), wall(a.single.end)],
          ['2026-11-18 09:00', '2026-11-18 10:00']);
      expect([wall(b.single.start), wall(b.single.end)],
          ['2026-11-18 10:00', '2026-11-18 11:00']);
      expect([wall(c.single.start), wall(c.single.end)],
          ['2026-11-18 11:00', '2026-11-18 13:00']);
      expect(plan.metrics.overdueTaskCount, 0);
      expect(plan.metrics.overdueMinutes, 0);
      expect(plan.metrics.unplacedMinutes, 0);
      expect(
        detectConflicts(
          schedule: plan.schedule,
          tasks: tasks,
          now: now,
        ),
        isEmpty,
      );
    });

    test('容量本就不足：不吞工时、不虚构时段，剩余量如实报告', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 12 * 60)], days: 1);
      final tasks = [
        task('A', 3, deadline: '2026-11-18 11:00'),
        task('B', 2, deadline: '2026-11-18 12:00'),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      // 180 minutes of capacity exist; demand is 300. The plan must place
      // exactly the capacity (no invented time) and report the rest.
      final placed = minutesPerTask(plan, tasks);
      expect(placed.reduce((a, b) => a + b), 180);
      expect(plan.metrics.unplacedMinutes, 120);
      expect(plan.metrics.overdueTaskCount, 1); // A ends after its deadline
      expect(plan.metrics.overdueMinutes, 60);
      expect(plan.taskNotes['B'], contains('容量不足'));
      expect(plan.taskNotes['B'], contains('2 小时'));
      // The unplaced remainder is visible in the task note and no segment
      // pretends the missing work happened.
      expect(plan.schedule.minutesForTask('B'), 0);
    });

    test('独立任务按截止时间先后安排，全部按时', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 12 * 60)], days: 1);
      final tasks = [
        task('P', 1, order: 2),
        task('Q', 1, deadline: '2026-11-18 11:00', order: 0),
        task('R', 1, deadline: '2026-11-18 12:00', order: 1),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      expect(wall(plan.schedule.forTask('Q').single.start), '2026-11-18 09:00');
      expect(wall(plan.schedule.forTask('R').single.start), '2026-11-18 10:00');
      expect(wall(plan.schedule.forTask('P').single.start), '2026-11-18 11:00');
      expect(plan.metrics.overdueTaskCount, 0);
      expect(plan.metrics.unplacedMinutes, 0);
    });

    test('跨日占用：课程时段不可用，容量不足部分如实报告', () {
      final settings = settingsWith(
        const [WallClockRange(9 * 60, 12 * 60)],
        days: 2,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ',
            title: '课程',
            kind: 'course',
            weekday: 3,
            ranges: [WallClockRange(10 * 60, 11 * 60)],
          ),
        ],
      );
      final tasks = [
        task('X', 2),
        task('Y', 3, deadline: '2026-11-19 11:00'),
        task('Z', 1),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      // Y must stay inside its deadline; total capacity (300 min) < demand (360).
      expect(
        plan.schedule.forTask('Y').last.end.isAfter(at('2026-11-19 11:00')),
        isFalse,
      );
      expect(plan.metrics.overdueTaskCount, 0);
      expect(plan.metrics.unplacedMinutes, 60);
      // The course window is never used for work.
      for (final segment in plan.schedule.segments) {
        final overlap = TimeInterval(
          at('2026-11-18 10:00'),
          at('2026-11-18 11:00'),
        ).overlaps(segment.interval);
        expect(overlap, isFalse);
      }
    });

    test('部分完成：手工片段保留，剩余工时按新范围安排', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 13 * 60)], days: 1);
      final manual = ScheduleSegment(
        id: 'manual-1',
        taskId: 'B',
        start: at('2026-11-18 09:00'),
        end: at('2026-11-18 10:00'),
        source: SegmentSource.manual,
      );
      final current = CalendarSchedule(settings: settings, segments: [manual]);
      final tasks = [
        task('B', 2, deadline: '2026-11-18 12:00'),
        task('C', 1),
      ];
      final plan = autoSchedule(
        current: current,
        tasks: tasks,
        now: now,
        keepManual: true,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      final b = plan.schedule.forTask('B');
      expect(b.any((s) => s.id == 'manual-1'), isTrue, reason: '手工片段必须保留');
      expect(plan.schedule.minutesForTask('B'), 120);
      expect(plan.metrics.overdueTaskCount, 0);
      expect(plan.metrics.unplacedMinutes, 0);
      // Locked segments are never counted as moved.
      expect(plan.metrics.movedExistingSegments, 0);
    });

    test('相同截止时间：稳定平局规则，容量不足时只报未安排', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 11 * 60)], days: 1);
      final tasks = [
        task('a', 1, deadline: '2026-11-18 11:00', order: 0),
        task('b', 1, deadline: '2026-11-18 11:00', order: 1),
        task('c', 1, deadline: '2026-11-18 11:00', order: 2),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      expect(plan.schedule.minutesForTask('a'), 60);
      expect(plan.schedule.minutesForTask('b'), 60);
      expect(plan.schedule.minutesForTask('c'), 0);
      expect(plan.metrics.overdueTaskCount, 0);
      expect(plan.metrics.unplacedMinutes, 60);
      expect(plan.taskNotes['c'], contains('容量不足'));
    });

    test('依赖环：成环任务不安排且报告，独立任务照常安排', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 12 * 60)], days: 1);
      final tasks = [
        task('x', 1, dependsOn: ['y']),
        task('y', 1, dependsOn: ['x']),
        task('z', 1),
      ];
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      expect(plan.notes.join(), contains('依赖成环'));
      expect(plan.schedule.forTask('x'), isEmpty);
      expect(plan.schedule.forTask('y'), isEmpty);
      expect(plan.schedule.minutesForTask('z'), 60);
    });

    test('局部搜索：消除可避免逾期，预算为 0 时退回基线并记录', () {
      // X cannot meet 11:00 (3h of work before 11:00 is impossible), but the
      // base order delays Y unnecessarily: Y first keeps only X overdue.
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 13 * 60)], days: 1);
      final tasks = [
        task('X', 3, deadline: '2026-11-18 11:00', order: 0),
        task('Y', 1, deadline: '2026-11-18 12:00', order: 1),
      ];
      final improved = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      final disabled = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
        localSearchTimeBudget: Duration.zero,
      );
      expectFeasiblePlan(improved, tasks);
      expectFeasiblePlan(disabled, tasks);
      // Baseline: X first → both tasks overdue.
      expect(disabled.metrics.overdueTaskCount, 2);
      expect(disabled.metrics.overdueMinutes, 120);
      expect(disabled.localSearchCandidates, 0);
      expect(disabled.localSearchBudgetExhausted, isTrue);
      // Local search moves Y before X: only X is overdue.
      expect(improved.metrics.overdueTaskCount, 1);
      expect(improved.metrics.overdueMinutes, 120);
      expect(improved.localSearchCandidates, greaterThan(0));
      expect(improved.localSearchBudgetExhausted, isFalse);
      expect(
        improved.metrics.compareTo(disabled.metrics),
        lessThan(0),
        reason: '只接受字典序严格更好的候选',
      );
      // Y is the task that got moved on time.
      expect(wall(improved.schedule.forTask('Y').single.start),
          '2026-11-18 09:00');
      final yDeadline = at('2026-11-18 12:00');
      expect(
        improved.schedule.forTask('Y').last.end.isAfter(yDeadline),
        isFalse,
      );
    });

    test('重排全部：既有自动片段计入移动数，手工片段被重建', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1);
      final current = CalendarSchedule(
        settings: settings,
        segments: [
          ScheduleSegment(
            id: 'manual-1',
            taskId: 't1',
            start: at('2026-11-18 08:00'),
            end: at('2026-11-18 09:00'),
            source: SegmentSource.manual,
          ),
          ScheduleSegment(
            id: 'auto-1',
            taskId: 't1',
            start: at('2026-11-18 10:00'),
            end: at('2026-11-18 11:00'),
            source: SegmentSource.auto,
          ),
        ],
      );
      final tasks = [task('t1', 3)];
      final keepManualPlan = autoSchedule(
        current: current,
        tasks: tasks,
        now: now,
        keepManual: true,
        newId: ids(),
      );
      expectFeasiblePlan(keepManualPlan, tasks);
      expect(keepManualPlan.schedule.segments.any((s) => s.id == 'manual-1'),
          isTrue);
      // The old auto segment is rebuilt from scratch → counted as moved.
      expect(keepManualPlan.metrics.movedExistingSegments, 1);

      final fullRebuild = autoSchedule(
        current: current,
        tasks: tasks,
        now: now,
        keepManual: false,
        newId: ids(),
      );
      expectFeasiblePlan(fullRebuild, tasks);
      expect(fullRebuild.schedule.segments.any((s) => s.id == 'manual-1'),
          isFalse);
      expect(fullRebuild.schedule.segments.any((s) => s.id == 'auto-1'),
          isFalse);
      expect(fullRebuild.metrics.movedExistingSegments, 2);
    });

    test('大任务集：60 个任务/5 天，约束全部通过且不劣于旧启发式', () {
      final settings =
          settingsWith(const [WallClockRange(9 * 60, 17 * 60)], days: 5);
      // Deterministic pseudo-random set with chains and deadlines (same shape
      // as the manual comparison run recorded in docs/task06/scheduling.md).
      var seed = 123456789;
      int nextInt(int max) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % max;
      }

      final tasks = <SchedulingTask>[];
      for (var i = 0; i < 60; i++) {
        final hours = [0.5, 1.0, 1.5, 2.0, 3.0][nextInt(5)];
        final deps = <String>[];
        if (i > 0 && nextInt(3) == 0) deps.add('t${i - 1}');
        final hasDeadline = nextInt(3) == 0;
        final day = 18 + nextInt(5);
        final hour = 9 + nextInt(9);
        tasks.add(task(
          't$i',
          hours,
          dependsOn: deps,
          deadline: hasDeadline
              ? '2026-11-${day.toString().padLeft(2, '0')} '
                  '${hour.toString().padLeft(2, '0')}:00'
              : null,
          order: i,
        ));
      }
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
      );
      expectFeasiblePlan(plan, tasks);
      // No work may be swallowed: placed + reported-unplaced == estimates.
      final totalEstimate = tasks.fold<int>(
          0, (sum, task) => sum + task.estimatedMinutes);
      final placedMinutes = plan.schedule.segments
          .fold<int>(0, (sum, segment) => sum + segment.minutes);
      expect(placedMinutes + plan.metrics.unplacedMinutes, totalEstimate);

      // Legacy baseline (the previous heuristic, measured before the
      // improvement): 10 overdue tasks / 10,500 overdue minutes / 3,690
      // unplaced minutes / 31 segments. Running with the search disabled must
      // still reproduce it; the improved plan may not be worse.
      final baseline = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: tasks,
        now: now,
        newId: ids(),
        maxLocalSearchCandidates: 0,
      );
      expect(baseline.metrics.overdueTaskCount, 10);
      expect(baseline.metrics.overdueMinutes, 10500);
      expect(baseline.metrics.unplacedMinutes, 3690);
      expect(baseline.metrics.segmentCount, 31);
      expect(plan.metrics.compareTo(baseline.metrics), lessThanOrEqualTo(0));
      expect(plan.elapsedMicroseconds, lessThan(5 * 1000 * 1000));
      stdout.writeln('[scheduling] large set metrics=${plan.metrics} '
          'baseline=${baseline.metrics} '
          'candidates=${plan.localSearchCandidates} '
          'elapsedUs=${plan.elapsedMicroseconds}');
    });
  });
}
