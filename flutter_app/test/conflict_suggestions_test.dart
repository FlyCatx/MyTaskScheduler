// 冲突解释与建议（第一轮 R1-C）的纯 Dart 单元测试。
//
// 固定时钟 + 固定 +08:00 墙上时间；断言尽量写成 “11月18日 周三 08:00” 形式，
// 以便审计“涉及任务 / 日期时刻 / 区间 / 来源 / 剩余需求 / 可用容量”是否真的来自
// 同一份 CalendarSchedule 快照。
//
// 覆盖：
//  * ConflictSource 判定（用户占用/默认不可用/任务预留/未绑定预留/前置依赖/截止/容量/自身重叠）
//  * 剩余需求与可用容量同快照
//  * 建议：移动、拆分、重排未锁定任务、打开时间表、无解原因
//  * 手动/已完成/其他任务预留不自动挪动
//  * 建议候选复用 detectConflicts 校验，addedConflictCount 如实为 0
//  * 确定性

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/conflict_suggestions.dart';
import 'package:taskscheduler_flutter/src/state/timetable_composition.dart';

const int _offset = 480; // +08:00

DateTime at(String wall) {
  final parts = wall.split(' ');
  final date = parts[0].split('-').map(int.parse).toList();
  final time =
      parts.length > 1 ? parts[1].split(':').map(int.parse).toList() : [0, 0];
  return DateTime.utc(date[0], date[1], date[2], time[0], time[1])
      .subtract(const Duration(minutes: _offset));
}

String wall(DateTime instant) {
  final w = const WallClock(_offset).toWall(instant);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${WallClock.formatDateKey(w.year, w.month, w.day)} '
      '${two(w.hour)}:${two(w.minute)}';
}

CalendarSettings settingsWith(
  List<WallClockRange> ranges, {
  int days = 3,
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
}) =>
    SchedulingTask(
      id: id,
      name: id,
      estimatedHours: hours,
      dependsOn: dependsOn,
      deadline: deadline,
      isDone: done,
    );

ScheduleSegment seg(
  String id,
  String taskId,
  String start,
  String end, {
  SegmentSource source = SegmentSource.auto,
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

CalendarSchedule scheduleWith(
  List<ScheduleSegment> segments, {
  required CalendarSettings settings,
}) =>
    CalendarSchedule(settings: settings, segments: segments);

List<ConflictDetail> detailsOf({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  DateTime? now,
}) =>
    explainConflicts(
      schedule: schedule,
      tasks: tasks,
      now: now ?? DateTime.utc(2026, 11, 17, 23),
      taskNames: {for (final t in tasks) t.id: t.name},
    );

ConflictDetail? firstOfKind(List<ConflictDetail> details, ConflictKind kind) {
  for (final detail in details) {
    if (detail.conflict.kind == kind) return detail;
  }
  return null;
}

ConflictSuggestion? suggestionOfKind(
  List<ConflictSuggestion> suggestions,
  SuggestionKind kind,
) {
  for (final suggestion in suggestions) {
    if (suggestion.kind == kind) return suggestion;
  }
  return null;
}

void main() {
  final now = DateTime.utc(2026, 11, 17, 23); // 2026-11-18 07:00 +08:00

  group('explainConflicts · 来源与同快照数字', () {
    test('课程占用 → 用户占用，并给出区间/任务/剩余需求/可用容量', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-1',
            title: '线性代数',
            kind: 'course',
            weekday: 3,
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final details = detailsOf(schedule: schedule, tasks: [task('a', 3)]);
      expect(details, hasLength(1));
      final detail = details.single;
      expect(detail.conflict.kind, ConflictKind.unavailable);
      expect(detail.source, ConflictSource.userOccupancy);
      expect(detail.sourceLabel, '用户占用');
      expect(detail.taskIds, ['a']);
      expect(wall(detail.start), '2026-11-18 09:00');
      expect(wall(detail.end), '2026-11-18 10:00');
      expect(detail.conflictMinutes, 60);
      // 预计 3h − 已安排 2h = 剩余 1h；可用容量 = 4h（可用窗口）− 2h（已排）= 2h。
      expect(detail.remainingNeedMinutes, 60);
      expect(detail.availableCapacityMinutes, 120);
      expect(detail.explanation, contains('用户占用'));
      expect(detail.explanation, contains('线性代数'));
      expect(detail.explanation, contains('剩余需求'));
      expect(detail.explanation, contains('同快照可用容量'));
    });

    test('日期关闭 → 默认不可用', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 2,
        exceptions: const [
          CalendarDateException(date: '2026-11-18', closed: true, note: '看巡演'),
        ],
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final detail =
          firstOfKind(detailsOf(schedule: schedule, tasks: [task('a', 2)]),
              ConflictKind.unavailable);
      expect(detail, isNotNull);
      expect(detail!.source, ConflictSource.defaultUnavailable);
      expect(detail.sourceLabel, '默认不可用');
    });

    test('用户占用/未绑定预留可以区分', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          // 由 Timetable.toCalendarSettings 从“未绑定蓝块”转出来的形状。
          CalendarOccupancy(
            id: 'res-1',
            title: '任务预留',
            kind: 'activity',
            weekday: 3,
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final detail =
          firstOfKind(detailsOf(schedule: schedule, tasks: [task('a', 2)]),
              ConflictKind.unavailable);
      expect(detail!.source, ConflictSource.taskReservationUnbound);
      expect(detail.sourceLabel, '未绑定预留');
    });

    test('任务重叠 → 任务预留；自身重叠 → 自身重叠', () {
      final settings = settingsWith(const [WallClockRange(8 * 60, 12 * 60)]);
      final overlap = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final taskOverlap = firstOfKind(
        detailsOf(schedule: overlap, tasks: [task('a', 2), task('b', 2)]),
        ConflictKind.taskOverlap,
      );
      expect(taskOverlap, isNotNull);
      expect(taskOverlap!.source, ConflictSource.taskReservation);
      expect(taskOverlap.taskIds, ['a', 'b']);
      expect(wall(taskOverlap.start), '2026-11-18 09:00');
      expect(wall(taskOverlap.end), '2026-11-18 10:00');

      final selfOverlap = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'a', '2026-11-18 09:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final detail = firstOfKind(
        detailsOf(schedule: selfOverlap, tasks: [task('a', 4)]),
        ConflictKind.selfOverlap,
      );
      expect(detail!.source, ConflictSource.selfOverlap);
      expect(detail.taskIds, ['a']);
    });

    test('依赖/截止/超出规划范围分别映射到前置依赖/截止时间/容量不足', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
      );
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 08:00', '2026-11-18 09:00'),
          // 第二天不在规划范围内（days:1）。
          seg('s3', 'c', '2026-11-19 08:00', '2026-11-19 09:00'),
        ],
        settings: settings,
      );
      final details = detailsOf(
        schedule: schedule,
        tasks: [
          task('a', 2),
          task('b', 1, dependsOn: ['a'], deadline: '2026-11-18 08:30'),
          task('c', 1),
        ],
      );
      final dependency =
          firstOfKind(details, ConflictKind.dependencyOrder)!;
      expect(dependency.source, ConflictSource.dependency);
      expect(dependency.sourceLabel, '前置依赖');
      final deadline = firstOfKind(details, ConflictKind.pastDeadline)!;
      expect(deadline.source, ConflictSource.deadline);
      expect(deadline.sourceLabel, '截止时间');
      final outside = firstOfKind(details, ConflictKind.outsideRange)!;
      expect(outside.source, ConflictSource.capacity);
      expect(outside.sourceLabel, '容量不足');
    });

    test('手工构造的旧冲突可用 conflictSourceOf 重新判定', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-1',
            title: '班会',
            kind: 'activity',
            weekday: 3,
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      );
      final schedule = CalendarSchedule(settings: settings);
      final conflict = CalendarConflict(
        kind: ConflictKind.unavailable,
        taskId: 'a',
        start: at('2026-11-18 09:00'),
        end: at('2026-11-18 10:00'),
        message: '旧数据没有 source',
      );
      expect(
        conflictSourceOf(conflict, schedule: schedule),
        ConflictSource.userOccupancy,
      );
    });
  });

  group('suggestForConflict · 可控调整建议', () {
    test('任务重叠：移动到下一个空档，调整前后与新增冲突数如实', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 13 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final tasks = [task('a', 2), task('b', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
        taskNames: {for (final t in tasks) t.id: t.name},
      );
      final move = suggestionOfKind(suggestions, SuggestionKind.moveToNextGap);
      expect(move, isNotNull);
      expect(move!.canApply, isTrue);
      expect(move.addedConflictCount, 0);
      expect(move.affectedTaskIds, ['a']);
      expect(move.changes.single, contains('→'));
      expect(move.changes.single, contains('a：'));

      // 候选必须真的消掉原冲突，并且用同一套 detectConflicts 复算没有新增冲突。
      final after = move.scheduleAfter!;
      final conflictsAfter = detectConflicts(
        schedule: after,
        tasks: tasks,
        now: now,
        taskNames: {for (final t in tasks) t.id: t.name},
      );
      expect(conflictsAfter, isEmpty);
      expect(after.segmentById('s1')!.start, at('2026-11-18 11:00'));
      expect(after.segmentById('s1')!.minutes, 120);
      expect(after.segmentById('s1')!.source, SegmentSource.manual);
    });

    test('不可用（课程占用）也会给出移动到空档的建议且不覆盖占用', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-1',
            title: '线性代数',
            kind: 'course',
            weekday: 3,
            ranges: [WallClockRange(9 * 60, 10 * 60)],
          ),
        ],
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final tasks = [task('a', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.unavailable,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      final move = suggestionOfKind(suggestions, SuggestionKind.moveToNextGap);
      expect(move, isNotNull);
      final moved = move!.scheduleAfter!;
      final segment = moved.segmentById('s1')!;
      expect(segment.start, at('2026-11-18 10:00'));
      expect(
        detectConflicts(schedule: moved, tasks: tasks, now: now),
        isEmpty,
      );
    });

    test('整段放不下时给出拆分建议（总时长不变）', () {
      // 三个 1 小时窗口：整段 2 小时放不进任何一个，拆成两段则可以。
      final settings = settingsWith(
        const [
          WallClockRange(8 * 60, 9 * 60),
          WallClockRange(10 * 60, 11 * 60),
          WallClockRange(12 * 60, 13 * 60),
        ],
        days: 1,
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final tasks = [task('a', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.unavailable,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      expect(
        suggestionOfKind(suggestions, SuggestionKind.moveToNextGap),
        isNull,
        reason: '没有任何一个空档能容下完整的 2 小时',
      );
      final split = suggestionOfKind(suggestions, SuggestionKind.splitTask);
      expect(split, isNotNull);
      final after = split!.scheduleAfter!;
      final own = after.forTask('a');
      expect(own.length, 2);
      expect(own.fold<int>(0, (sum, s) => sum + s.minutes), 120);
      expect(split.addedConflictCount, 0);
      expect(split.changes.single, contains('拆分'));
      expect(detectConflicts(schedule: after, tasks: tasks, now: now), isEmpty);
    });

    test('重新安排受影响的未锁定任务：两个 auto 片段不再重叠', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 13 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final tasks = [task('a', 2), task('b', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
        taskNames: {for (final t in tasks) t.id: t.name},
      );
      final reschedule =
          suggestionOfKind(suggestions, SuggestionKind.rescheduleUnlocked);
      expect(reschedule, isNotNull);
      final after = reschedule!.scheduleAfter!;
      expect(after.forTask('a').fold<int>(0, (s, x) => s + x.minutes), 120);
      expect(after.forTask('b').fold<int>(0, (s, x) => s + x.minutes), 120);
      expect(reschedule.affectedTaskIds.toSet(), {'a', 'b'});
      expect(detectConflicts(
        schedule: after,
        tasks: tasks,
        now: now,
        taskNames: {for (final t in tasks) t.id: t.name},
      ), isEmpty);
    });

    test('手动锁定片段与已完成任务不会被自动挪动，并给出明确原因', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 12 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00',
              source: SegmentSource.manual),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00',
              source: SegmentSource.manual),
        ],
        settings: settings,
      );
      final tasks = [task('a', 2), task('b', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      expect(
        suggestionOfKind(suggestions, SuggestionKind.moveToNextGap),
        isNull,
      );
      expect(suggestionOfKind(suggestions, SuggestionKind.splitTask), isNull);
      expect(
        suggestionOfKind(suggestions, SuggestionKind.rescheduleUnlocked),
        isNull,
      );
      final none = suggestionOfKind(suggestions, SuggestionKind.none);
      expect(none, isNotNull);
      expect(none!.unavailableReason, contains('手动'));
      expect(none.scheduleAfter, isNull);
      // 手动入口始终存在，但不会自动改数据。
      final open =
          suggestionOfKind(suggestions, SuggestionKind.openTimetable)!;
      expect(open.scheduleAfter, isNull);
    });

    test('已完成任务即使 auto 也不会被自动移动', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 13 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'done', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final tasks = [task('done', 2, done: true), task('b', 2)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      expect(
        suggestionOfKind(suggestions, SuggestionKind.moveToNextGap),
        isNull,
      );
      // 若重排其他任务，已完成的 s1 必须原样保留。
      final reschedule =
          suggestionOfKind(suggestions, SuggestionKind.rescheduleUnlocked);
      if (reschedule != null) {
        final kept = reschedule.scheduleAfter!.segmentById('s1')!;
        expect(kept.start, at('2026-11-18 08:00'));
        expect(kept.end, at('2026-11-18 10:00'));
      }
      // 未锁定任务 b 可以移动；这不是在挪动已完成的片段。
      expect(
        suggestions.any((s) =>
            s.scheduleAfter != null &&
            (s.scheduleAfter!.segmentById('s1')?.start !=
                at('2026-11-18 08:00'))),
        isFalse,
      );
    });

    test('没有空档时不伪造建议，none 说明原因', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 9 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 09:00'),
          seg('s2', 'b', '2026-11-18 08:00', '2026-11-18 09:00'),
        ],
        settings: settings,
      );
      final tasks = [task('a', 1), task('b', 1)];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      final auto = suggestions.where((s) => s.canApply).toList();
      expect(auto, isEmpty);
      final none = suggestionOfKind(suggestions, SuggestionKind.none)!;
      expect(none.unavailableReason, isNotNull);
      expect(none.unavailableReason, contains('空档'));
    });

    test('建议是确定性的，且都通过 detectConflicts 复算（新增冲突为 0）', () {
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 13 * 60)], days: 2);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00'),
          seg('s2', 'b', '2026-11-18 09:00', '2026-11-18 11:00'),
          seg('s3', 'c', '2026-11-18 10:00', '2026-11-18 12:00'),
        ],
        settings: settings,
      );
      final tasks = [task('a', 2), task('b', 2), task('c', 2)];
      final names = {for (final t in tasks) t.id: t.name};
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.taskOverlap,
      )!;
      final first = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
        taskNames: names,
      );
      final second = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
        taskNames: names,
      );
      String digest(List<ConflictSuggestion> list) => list
          .map((s) =>
              '${s.kind.name}|${s.label}|${s.changes.join(';')}|'
              '${s.addedConflictCount}|${s.deadlineRisk}')
          .join('||');
      expect(digest(first), digest(second));

      for (final suggestion in first) {
        if (suggestion.scheduleAfter == null) continue;
        final conflicts = detectConflicts(
          schedule: suggestion.scheduleAfter!,
          tasks: tasks,
          now: now,
          taskNames: names,
        );
        final baseline = detectConflicts(
          schedule: schedule,
          tasks: tasks,
          now: now,
          taskNames: names,
        );
        final baselineKeys = {
          for (final c in baseline)
            '${c.kind.name}|${c.taskId}|${c.otherTaskId ?? ''}',
        };
        final introduced = conflicts
            .where((c) =>
                !baselineKeys
                    .contains('${c.kind.name}|${c.taskId}|${c.otherTaskId ?? ''}'))
            .toList();
        expect(introduced.length, suggestion.addedConflictCount);
        expect(suggestion.addedConflictCount, 0,
            reason: '不满足约束（会新增冲突）的候选不应作为建议出现');
      }
    });

    test('截止风险会如实标记', () {
      // a 的原片段晚于截止；把整段挪到别处也不会改变“晚于截止”的事实。
      final settings =
          settingsWith(const [WallClockRange(8 * 60, 13 * 60)], days: 1);
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 12:00', '2026-11-18 13:00'),
          seg('s2', 'b', '2026-11-18 08:00', '2026-11-18 09:00'),
        ],
        settings: settings,
      );
      final tasks = [
        task('a', 1, deadline: '2026-11-18 11:00'),
        task('b', 1),
      ];
      final detail = firstOfKind(
        detailsOf(schedule: schedule, tasks: tasks),
        ConflictKind.pastDeadline,
      )!;
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: tasks,
        now: now,
      );
      for (final suggestion in suggestions) {
        final after = suggestion.scheduleAfter;
        if (after == null) continue;
        final last = after
            .forTask('a')
            .map((s) => s.end)
            .fold<DateTime?>(null, (m, e) => m == null || e.isAfter(m) ? e : m);
        expect(suggestion.deadlineRisk, last != null && last.isAfter(at('2026-11-18 11:00')));
      }
    });
  });

  group('外部日历来源（T-D 合成快照 → 冲突解释）', () {
    const externalSourceId = 'ext-aabbccddeeff';
    const externalOccupancy = CalendarOccupancy(
      id: 'ext-$externalSourceId-20261118-540-600',
      title: '外部日历',
      kind: 'activity',
      weekday: 3,
      ranges: [WallClockRange(9 * 60, 10 * 60)],
      external: true,
      sourceId: externalSourceId,
    );

    test('外部占用导致的 unavailable 冲突：来源为“外部日历”，可拿 sourceId', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [externalOccupancy],
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 10:00')],
        settings: settings,
      );
      final detail =
          firstOfKind(detailsOf(schedule: schedule, tasks: [task('a', 3)]),
              ConflictKind.unavailable)!;
      expect(detail.source, ConflictSource.externalCalendar);
      expect(detail.sourceLabel, '外部日历');
      expect(detail.source.requiresUserAction, isTrue,
          reason: '外部事件只能由用户处理（调整安排/停用来源），程序不得自动挪动');
      expect(detail.sourceId, externalSourceId);
      // 既有字段保持原语义：区间/剩余需求/容量仍来自同一快照。
      expect(wall(detail.start), '2026-11-18 09:00');
      expect(wall(detail.end), '2026-11-18 10:00');
      expect(detail.remainingNeedMinutes, 60);
      // 解释里说明“只读外部日历，不会自动移动”。
      expect(detail.explanation, contains('来源：外部日历'));
      expect(detail.explanation, contains('只读外部日历'));
      expect(detail.explanation, contains('不会被程序移动或删除'));
      // detectConflicts 的 message 也直接点明外部日历占用。
      expect(detail.conflict.message, contains('外部日历占用'));
      // 手动入口说明外部来源只读：不能靠在时间表里删除占用来解决。
      final suggestions = suggestForConflict(
        detail: detail,
        schedule: schedule,
        tasks: [task('a', 3)],
        now: now,
      );
      final open = suggestionOfKind(suggestions, SuggestionKind.openTimetable)!;
      expect(open.scheduleAfter, isNull);
      expect(open.changes.join(' '), contains('只读'));
    });

    test('普通用户占用与外部占用并存时来源各自判定（既有语义不变）', () {
      final settings = settingsWith(
        const [WallClockRange(8 * 60, 12 * 60)],
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-course',
            title: '线性代数',
            kind: 'course',
            weekday: 3,
            ranges: [WallClockRange(8 * 60, 9 * 60)],
          ),
          CalendarOccupancy(
            id: 'ext-$externalSourceId-20261118-600-660',
            title: '外部日历',
            kind: 'activity',
            weekday: 3,
            ranges: [WallClockRange(10 * 60, 11 * 60)],
            external: true,
            sourceId: externalSourceId,
          ),
        ],
      );
      final schedule = scheduleWith(
        [
          seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 09:00'),
          seg('s2', 'a', '2026-11-18 10:00', '2026-11-18 11:00'),
        ],
        settings: settings,
      );
      final details = detailsOf(schedule: schedule, tasks: [task('a', 2)]);
      final unavailable =
          details.where((d) => d.conflict.kind == ConflictKind.unavailable);
      final userDetail =
          unavailable.firstWhere((d) => wall(d.start) == '2026-11-18 08:00');
      final externalDetail =
          unavailable.firstWhere((d) => wall(d.start) == '2026-11-18 10:00');
      expect(userDetail.source, ConflictSource.userOccupancy);
      expect(userDetail.sourceLabel, '用户占用');
      expect(userDetail.sourceId, isNull);
      expect(externalDetail.source, ConflictSource.externalCalendar);
      expect(externalDetail.sourceLabel, '外部日历');
      expect(externalDetail.sourceId, externalSourceId);
    });

    test('手工日期“可用”例外被外部忙碌覆盖时仍判外部日历占用（不是默认不可用）', () {
      // 真实数据链路：手工时间表（11-18 08:00-12:00 手画可用）+ 外部忙碌 10:00-11:00
      // → composeExternalBusy → toCalendarSettings，再解释冲突。
      final manual = Timetable.withDefaults(
        weekStart: '2026-11-16',
        revision: 2,
      ).paint(
        date: '2026-11-18',
        start: 8 * 60,
        end: 12 * 60,
        state: TimetableState.free,
        title: '手动可用',
      );
      final composed = composeExternalBusy(
        manual: manual,
        busy: [
          ExternalBusyInstance(
            sourceId: externalSourceId,
            uid: 'uid-ext-1',
            startUtc: at('2026-11-18 10:00'),
            endUtc: at('2026-11-18 11:00'),
            dayKey: '2026-11-18',
            startMinute: 10 * 60,
            endMinute: 11 * 60,
          ),
        ],
        timezoneId: 'Asia/Shanghai',
      );
      final derived = composed.toCalendarSettings(
        settingsWith(
          const [WallClockRange(8 * 60, 12 * 60)],
          days: 3,
          start: '2026-11-16',
        ),
      );
      final schedule = scheduleWith(
        [seg('s1', 'a', '2026-11-18 08:00', '2026-11-18 12:00')],
        settings: derived,
      );
      final detail =
          firstOfKind(detailsOf(schedule: schedule, tasks: [task('a', 4)]),
              ConflictKind.unavailable)!;
      expect(detail.source, ConflictSource.externalCalendar);
      expect(detail.sourceLabel, '外部日历');
      expect(detail.sourceId, externalSourceId);
      expect(detail.conflict.message, contains('外部日历占用'));
      // 忙碌之外的手工可用仍被当作可用（没有多出额外冲突）。
      expect(
        detailsOf(schedule: schedule, tasks: [task('a', 4)])
            .where((d) => d.conflict.kind == ConflictKind.unavailable)
            .length,
        1,
      );
    });
  });
}
