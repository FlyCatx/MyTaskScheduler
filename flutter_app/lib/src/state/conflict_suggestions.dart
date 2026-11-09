// 冲突解释与可控调整建议（纯 Dart，无 I/O、无控件状态，时钟由调用方注入）。
//
// 设计目标（第一轮需求 R1-C）：
//  * 每条冲突都能说明：涉及任务、具体日期时刻、冲突区间、违反的约束类型与来源；
//    “剩余需求 / 可用容量”一律从同一份 CalendarSchedule 快照计算，不跨快照拼数字。
//  * 建议由本地确定性逻辑生成，并用**同一套** [detectConflicts] 重新校验候选结果，
//    [ConflictSuggestion.addedConflictCount] 如实统计候选引入的新冲突数。
//  * 手动固定（SegmentSource.manual）、已完成任务、用户占用与其他任务预留不会被自动
//    挪动；扩充可用时间/删除占用等“降低约束”的动作永远只留给用户明确操作。
//  * 无可行自动建议时返回 kind:none 并给出原因，绝不伪造一个违反占用/锁定的建议。
//
// 主要类型/函数：ConflictDetail、ConflictSuggestion、explainConflicts、suggestForConflict。

import 'dart:math' as math;

import '../model/calendar.dart';
import 'calendar_planner.dart';

// ConflictSource / ConflictSourceLabel 定义在冲突引擎 calendar_planner.dart 中
// （detectConflicts 直接填充来源），这里重新导出，解释层从本文件即可拿到完整 API。
export 'calendar_planner.dart' show ConflictSource, ConflictSourceLabel;

/// 一条冲突的结构化解释。[conflict] 的既有字段与 message 保持不变。
class ConflictDetail {
  final CalendarConflict conflict;

  /// 冲突来源（用户占用/默认不可用/任务预留/外部日历/…）。
  final ConflictSource source;
  final String sourceLabel;

  /// 外部日历来源 id（仅 [source] 为 `ConflictSource.externalCalendar` 时可得）。
  ///
  /// 可选字段：既有构造调用不受影响；UI 不需要显示原始 id，解释层/未来“定位到
  /// 来源”入口可以使用它。
  final String? sourceId;

  /// 涉及的任务：本任务 + 对方任务（去重、按出现顺序）。
  final List<String> taskIds;

  /// 冲突区间（UTC 瞬时，展示时用 settings.clock 转墙上时间）。
  final DateTime start;
  final DateTime end;
  final int conflictMinutes;

  /// 任务剩余需求（预计工时 − 已安排分钟，同一快照）；工时未知时为 null。
  final int? remainingNeedMinutes;

  /// 同一快照里仍可用的容量（可用窗口减去全部已排片段后的分钟数）。
  final int? availableCapacityMinutes;

  /// 中文解释，包含类型/来源/区间/任务与容量信息。
  final String explanation;

  const ConflictDetail({
    required this.conflict,
    required this.source,
    required this.sourceLabel,
    required this.taskIds,
    required this.start,
    required this.end,
    required this.conflictMinutes,
    required this.explanation,
    this.remainingNeedMinutes,
    this.availableCapacityMinutes,
    this.sourceId,
  });

  /// 剩余需求大于 0 时，说明这个计划还没有把所有工作排进去。
  bool get hasRemainingNeed => (remainingNeedMinutes ?? 0) > 0;

  @override
  String toString() =>
      'ConflictDetail(${conflict.kind.name}/${source.name}): $explanation';
}

enum SuggestionKind {
  moveToNextGap,
  splitTask,
  rescheduleUnlocked,
  openTimetable,
  none,
}

extension SuggestionKindLabel on SuggestionKind {
  String get label => switch (this) {
        SuggestionKind.moveToNextGap => '移动到下一个空档',
        SuggestionKind.splitTask => '拆分任务',
        SuggestionKind.rescheduleUnlocked => '重新安排未锁定任务',
        SuggestionKind.openTimetable => '打开时间表调整',
        SuggestionKind.none => '没有可行的自动建议',
      };

  /// 是否会在用户确认后直接改写排程（false = 只是给用户一个手动入口）。
  bool get appliesSchedule =>
      this == SuggestionKind.moveToNextGap ||
      this == SuggestionKind.splitTask ||
      this == SuggestionKind.rescheduleUnlocked;
}

/// 一条本地生成的调整建议。
class ConflictSuggestion {
  final SuggestionKind kind;

  /// 面向用户的短标题（中文）。
  final String label;

  /// 建议应用后的完整排程；null 表示不能自动修复（[SuggestionKind.openTimetable] /
  /// [SuggestionKind.none]）。
  final CalendarSchedule? scheduleAfter;

  /// 会被改动的任务。
  final List<String> affectedTaskIds;

  /// 调整前后描述，例如 `任务A 11月18日 08:00-10:00 → 11月18日 12:00-14:00`。
  final List<String> changes;

  /// 用 [detectConflicts] 重算后，该建议引入的新冲突数（0 表示不新增冲突）。
  final int addedConflictCount;

  /// 调整后是否有任务会越过自己的截止时间。
  final bool deadlineRisk;

  /// kind == none 时的明确原因。
  final String? unavailableReason;

  const ConflictSuggestion({
    required this.kind,
    required this.label,
    required this.affectedTaskIds,
    required this.changes,
    required this.addedConflictCount,
    required this.deadlineRisk,
    this.scheduleAfter,
    this.unavailableReason,
  });

  bool get canApply => scheduleAfter != null && kind.appliesSchedule;

  @override
  String toString() =>
      'ConflictSuggestion(${kind.name}, +$addedConflictCount conflicts'
      '${deadlineRisk ? ', deadline risk' : ''})';
}

/// 是否同一条冲突（用于把 UI 上点击的行映射回最新计算出的解释）。
bool sameConflict(CalendarConflict a, CalendarConflict b) =>
    a.kind == b.kind &&
    a.taskId == b.taskId &&
    a.otherTaskId == b.otherTaskId &&
    a.segmentId == b.segmentId &&
    a.start.isAtSameMomentAs(b.start) &&
    a.end.isAtSameMomentAs(b.end);

/// 任务剩余需求（预计工时 − 已安排分钟），来自 [schedule] 同一快照；未知工时返回 null。
int? remainingNeedMinutesFor({
  required CalendarSchedule schedule,
  required SchedulingTask? task,
}) {
  if (task == null || !task.hoursKnown) return null;
  final remaining = task.estimatedMinutes - schedule.minutesForTask(task.id);
  return remaining < 0 ? 0 : remaining;
}

/// 同一快照里仍可用的容量：可用窗口减去全部已排片段后的分钟数。
int availableCapacityMinutesIn({
  required CalendarSchedule schedule,
  CalendarSettings? settings,
}) {
  final effective = settings ?? schedule.settings;
  final availability = buildAvailability(effective);
  final busy = <TimeInterval>[for (final s in schedule.segments) s.interval];
  final free = availability.freeFrom(
    busy,
    notBefore: effective.startInstant,
    notAfter: effective.endInstant,
  );
  return free.fold<int>(0, (sum, i) => sum + (i.minutes < 0 ? 0 : i.minutes));
}

/// 把每条 [CalendarConflict] 解释成结构化 [ConflictDetail]。
///
/// [settings] 允许调用方传入“同一快照”的设置对象做展示口径；不传时用
/// `schedule.settings`。冲突检测本身始终基于 [schedule]，不会跨快照。
List<ConflictDetail> explainConflicts({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required DateTime now,
  Map<String, String>? taskNames,
  CalendarSettings? settings,
}) {
  final effective = settings ?? schedule.settings;
  final conflicts = detectConflicts(
    schedule: schedule,
    tasks: tasks,
    now: now,
    taskNames: taskNames,
  );
  final taskById = <String, SchedulingTask>{for (final t in tasks) t.id: t};
  final capacity = availableCapacityMinutesIn(schedule: schedule, settings: effective);
  return <ConflictDetail>[
    for (final conflict in conflicts)
      _detailFor(
        conflict,
        schedule: schedule,
        taskById: taskById,
        settings: effective,
        capacity: capacity,
      ),
  ];
}

ConflictDetail _detailFor(
  CalendarConflict conflict, {
  required CalendarSchedule schedule,
  required Map<String, SchedulingTask> taskById,
  required CalendarSettings settings,
  required int capacity,
}) {
  final source = conflictSourceOf(conflict, schedule: schedule, settings: settings);
  final clock = settings.clock;
  final minutes = conflict.end.difference(conflict.start).inMinutes;
  final taskIds = <String>[
    conflict.taskId,
    if (conflict.otherTaskId != null &&
        conflict.otherTaskId!.isNotEmpty &&
        conflict.otherTaskId != conflict.taskId)
      conflict.otherTaskId!,
  ];
  final remaining =
      remainingNeedMinutesFor(schedule: schedule, task: taskById[conflict.taskId]);
  final range = instantRangeLabel(clock, conflict.start, conflict.end);
  // 外部日历来源：从同一份 settings 快照里取出具体占用，拿 sourceId 并解释
  // “只读、不会自动移动”。非外部来源不改变既有解释。
  final blocking = conflict.kind == ConflictKind.unavailable
      ? occupancyBlockingInterval(
          settings,
          TimeInterval(conflict.start, conflict.end),
        )
      : null;
  final externalSourceId =
      source == ConflictSource.externalCalendar ? blocking?.sourceId : null;
  final buffer = StringBuffer()
    ..write('${conflict.kind.label}：${conflict.message}')
    ..write('；来源：${source.label}')
    ..write('；区间：$range（${formatDurationMinutes(minutes < 0 ? 0 : minutes)}）');
  if (source == ConflictSource.externalCalendar) {
    buffer.write('；说明：该时段来自只读外部日历，外部事件本身不会被程序移动或删除，'
        '只能由你调整自己的安排、停用该来源或重新导入');
  }
  if (remaining != null) {
    final scheduled = schedule.minutesForTask(conflict.taskId);
    buffer.write('；剩余需求：${formatDurationMinutes(remaining)}'
        '（预计 ${formatDurationMinutes(taskById[conflict.taskId]!.estimatedMinutes)}'
        ' − 已安排 ${formatDurationMinutes(scheduled)}）');
  }
  buffer.write('；同快照可用容量：${formatDurationMinutes(capacity)}');
  return ConflictDetail(
    conflict: conflict,
    source: source,
    sourceLabel: source.label,
    taskIds: List<String>.unmodifiable(taskIds),
    start: conflict.start,
    end: conflict.end,
    conflictMinutes: minutes < 0 ? 0 : minutes,
    remainingNeedMinutes: remaining,
    availableCapacityMinutes: capacity,
    explanation: buffer.toString(),
    sourceId: externalSourceId,
  );
}

/// 墙上时间区间标签，例如 `11月18日 周三 08:00–10:00`（跨日会写出两个日期）。
String instantRangeLabel(WallClock clock, DateTime start, DateTime end) {
  final startWall = clock.toWall(start);
  final endWall = clock.toWall(end);
  final sameDay = clock.dateKey(start) == clock.dateKey(end);
  final startLabel = '${wallDateLabel(startWall)} ${_minuteLabel(startWall)}';
  final endLabel = sameDay
      ? _minuteLabel(endWall)
      : '${wallDateLabel(endWall)} ${_minuteLabel(endWall)}';
  return '$startLabel–$endLabel';
}

String _minuteLabel(DateTime wall) =>
    WallClockRange.formatMinute(wall.hour * 60 + wall.minute);

/// 为 [detail] 生成确定性建议列表（自动建议在前，手动入口在后，无解时含 none 原因）。
///
/// 所有 [ConflictSuggestion.scheduleAfter] 都用 [detectConflicts] 在同一份任务/
/// 设置快照上重新校验过：原冲突必须消失，且不得引入新冲突；否则该候选被丢弃。
List<ConflictSuggestion> suggestForConflict({
  required ConflictDetail detail,
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required DateTime now,
  Map<String, String>? taskNames,
}) {
  final settings = schedule.settings;
  final names = <String, String>{
    for (final t in tasks) t.id: t.name,
    ...?taskNames,
  };
  final taskById = <String, SchedulingTask>{for (final t in tasks) t.id: t};
  final original = detail.conflict;
  final baseline = detectConflicts(
    schedule: schedule,
    tasks: tasks,
    now: now,
    taskNames: names,
  );
  final baselineKeys = <String>{for (final c in baseline) _pairKey(c)};

  final segment = original.segmentId == null
      ? null
      : schedule.segmentById(original.segmentId!);
  final task = taskById[original.taskId];
  final movable = segment != null &&
      segment.source != SegmentSource.manual &&
      !(task?.isDone ?? false);

  final out = <ConflictSuggestion>[];
  if (movable) {
    final move = _moveSuggestion(
      schedule: schedule,
      tasks: tasks,
      task: task!,
      segment: segment,
      detail: detail,
      now: now,
      names: names,
      baselineKeys: baselineKeys,
    );
    if (move != null) out.add(move);
    if (_canSplit(segment, settings)) {
      final split = _splitSuggestion(
        schedule: schedule,
        tasks: tasks,
        segment: segment,
        detail: detail,
        now: now,
        names: names,
        baselineKeys: baselineKeys,
      );
      if (split != null) out.add(split);
    }
  }

  final reschedule = _rescheduleSuggestion(
    schedule: schedule,
    tasks: tasks,
    taskById: taskById,
    detail: detail,
    now: now,
    names: names,
    baselineKeys: baselineKeys,
  );
  if (reschedule != null) out.add(reschedule);

  if (out.isEmpty) {
    out.add(ConflictSuggestion(
      kind: SuggestionKind.none,
      label: SuggestionKind.none.label,
      affectedTaskIds: detail.taskIds,
      changes: const <String>[],
      addedConflictCount: 0,
      deadlineRisk: false,
      unavailableReason: _noSuggestionReason(
        original: original,
        segment: segment,
        task: task,
      ),
    ));
  }

  out.add(ConflictSuggestion(
    kind: SuggestionKind.openTimetable,
    label: SuggestionKind.openTimetable.label,
    affectedTaskIds: detail.taskIds,
    changes: <String>[
      '打开时间表调整可用范围、日期例外或课程占用。',
      // 外部日历只读：时间表里删不掉，必须停用/更新来源或调整自己的安排。
      if (detail.source == ConflictSource.externalCalendar)
        '外部日历是只读来源：请停用/更新来源，或调整自己的安排。',
    ],
    addedConflictCount: 0,
    deadlineRisk: false,
  ));
  return List<ConflictSuggestion>.unmodifiable(out);
}

// --------------------------------------------------------------- candidates

/// 移动整个片段到下一个满足约束的空档。
ConflictSuggestion? _moveSuggestion({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required SchedulingTask task,
  required ScheduleSegment segment,
  required ConflictDetail detail,
  required DateTime now,
  required Map<String, String> names,
  required Set<String> baselineKeys,
}) {
  final settings = schedule.settings;
  final duration = segment.minutes;
  if (duration <= 0) return null;
  final clock = settings.clock;

  DateTime notBefore;
  DateTime? notAfter;
  switch (detail.conflict.kind) {
    case ConflictKind.outsideRange:
      notBefore = settings.startInstant;
      notAfter = settings.endInstant;
      break;
    case ConflictKind.pastDeadline:
      final deadline = parseDeadlineText(
        task.deadline,
        now: now,
        offsetMinutes: settings.timezoneOffsetMinutes,
      ).at;
      if (deadline == null) return null;
      notBefore = settings.startInstant;
      notAfter = deadline;
      break;
    case ConflictKind.selfOverlap:
    case ConflictKind.taskOverlap:
    case ConflictKind.unavailable:
    case ConflictKind.dependencyOrder:
    case ConflictKind.uncertainDependency:
      notBefore = segment.start;
      notAfter = settings.endInstant;
      break;
  }

  final availability = buildAvailability(settings);
  final busy = <TimeInterval>[
    for (final s in schedule.segments)
      if (s.id != segment.id) s.interval,
  ];
  final windows = availability.freeFrom(
    busy,
    notBefore: notBefore,
    notAfter: notAfter,
  );

  // 候选起点：空档起点、以及本冲突区间的结束点（“下一个空档”），都做确定性校验。
  final starts = <DateTime>[];
  for (final window in windows) {
    final candidates = <DateTime>[
      window.start.isBefore(notBefore) ? notBefore : window.start,
      detail.conflict.end,
    ];
    for (final raw in candidates) {
      final start = raw.isBefore(notBefore) ? notBefore : raw;
      if (start.isAtSameMomentAs(segment.start)) continue;
      if (start.add(Duration(minutes: duration)).isAfter(window.end)) continue;
      starts.add(start);
    }
    if (starts.length > 64) break;
  }
  starts.sort();

  for (final start in starts) {
    final moved = segment.copyWith(
      start: start,
      end: start.add(Duration(minutes: duration)),
      source: SegmentSource.manual,
      revision: segment.revision + 1,
    );
    final candidate = _withSegments(
      schedule,
      schedule.segments.map((s) => s.id == segment.id ? moved : s),
    );
    final introduced = _introducedConflicts(
      candidate,
      tasks: tasks,
      now: now,
      names: names,
      baselineKeys: baselineKeys,
      original: detail.conflict,
    );
    if (introduced == null) continue;
    return ConflictSuggestion(
      kind: SuggestionKind.moveToNextGap,
      label: SuggestionKind.moveToNextGap.label,
      scheduleAfter: candidate,
      affectedTaskIds: <String>[segment.taskId],
      changes: <String>[
        '${names[segment.taskId] ?? segment.taskId}：'
            '${instantRangeLabel(clock, segment.start, segment.end)} → '
            '${instantRangeLabel(clock, moved.start, moved.end)}',
      ],
      addedConflictCount: introduced.length,
      deadlineRisk: _deadlineRisk(
        candidate: candidate,
        affected: <String>[segment.taskId],
        tasks: tasks,
        now: now,
        settings: settings,
      ),
    );
  }
  return null;
}

/// 在不改变总时长的前提下，从冲突起点把片段拆成两段并把后半段移到空档。
ConflictSuggestion? _splitSuggestion({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required ScheduleSegment segment,
  required ConflictDetail detail,
  required DateTime now,
  required Map<String, String> names,
  required Set<String> baselineKeys,
}) {
  final settings = schedule.settings;
  final clock = settings.clock;
  final duration = segment.minutes;
  if (duration <= 0) return null;

  var cut = detail.conflict.start;
  if (!cut.isAfter(segment.start) || !cut.isBefore(segment.end)) {
    cut = segment.start.add(Duration(minutes: duration ~/ 2));
  }
  final firstMinutes = cut.difference(segment.start).inMinutes;
  final secondMinutes = segment.end.difference(cut).inMinutes;
  if (firstMinutes <= 0 || secondMinutes <= 0) return null;

  final first = segment.copyWith(
    end: cut,
    source: SegmentSource.manual,
    revision: segment.revision + 1,
  );
  final availability = buildAvailability(settings);
  final busy = <TimeInterval>[
    for (final s in schedule.segments)
      if (s.id != segment.id) s.interval,
    first.interval,
  ];
  final notBefore =
      detail.conflict.end.isAfter(cut) ? detail.conflict.end : cut;
  final windows = availability.freeFrom(busy, notBefore: notBefore);
  DateTime? placed;
  for (final window in windows) {
    final start = window.start.isBefore(notBefore) ? notBefore : window.start;
    if (start.add(Duration(minutes: secondMinutes)).isAfter(window.end)) {
      continue;
    }
    placed = start;
    break;
  }
  if (placed == null) return null;

  final second = ScheduleSegment(
    id: _uniqueSegmentId(schedule, '${segment.id}-split'),
    taskId: segment.taskId,
    start: placed,
    end: placed.add(Duration(minutes: secondMinutes)),
    source: SegmentSource.manual,
    tentative: segment.tentative,
    revision: segment.revision + 1,
  );
  final candidate = _withSegments(schedule, <ScheduleSegment>[
    for (final s in schedule.segments)
      if (s.id != segment.id) s,
    first,
    second,
  ]);
  final introduced = _introducedConflicts(
    candidate,
    tasks: tasks,
    now: now,
    names: names,
    baselineKeys: baselineKeys,
    original: detail.conflict,
  );
  if (introduced == null) return null;
  return ConflictSuggestion(
    kind: SuggestionKind.splitTask,
    label: SuggestionKind.splitTask.label,
    scheduleAfter: candidate,
    affectedTaskIds: <String>[segment.taskId],
    changes: <String>[
      '${names[segment.taskId] ?? segment.taskId}：'
          '${instantRangeLabel(clock, segment.start, segment.end)} → 拆分到 '
          '${instantRangeLabel(clock, first.start, first.end)} 与 '
          '${instantRangeLabel(clock, second.start, second.end)}（总时长不变）',
    ],
    addedConflictCount: introduced.length,
    deadlineRisk: _deadlineRisk(
      candidate: candidate,
      affected: <String>[segment.taskId],
      tasks: tasks,
      now: now,
      settings: settings,
    ),
  );
}

/// 把受影响任务里所有“未锁定”（非 manual、非已完成）的片段整体重排到空档。
ConflictSuggestion? _rescheduleSuggestion({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required Map<String, SchedulingTask> taskById,
  required ConflictDetail detail,
  required DateTime now,
  required Map<String, String> names,
  required Set<String> baselineKeys,
}) {
  final original = detail.conflict;
  final affected = <String>[
    original.taskId,
    if (original.otherTaskId != null &&
        original.otherTaskId!.isNotEmpty &&
        original.otherTaskId != original.taskId)
      original.otherTaskId!,
  ];
  final movable = schedule.segments
      .where((s) =>
          affected.contains(s.taskId) &&
          s.source == SegmentSource.auto &&
          !(taskById[s.taskId]?.isDone ?? false))
      .toList();
  if (movable.isEmpty) return null;

  final settings = schedule.settings;
  final clock = settings.clock;
  final movableIds = <String>{for (final s in movable) s.id};
  final kept = schedule.segments
      .where((s) => !movableIds.contains(s.id))
      .toList(growable: true);
  final availability = buildAvailability(settings);
  final busy = <TimeInterval>[for (final s in kept) s.interval];
  final placed = <ScheduleSegment>[...kept];
  final changes = <String>[];
  var generated = 0;

  for (final taskId in affected) {
    final list = movable.where((s) => s.taskId == taskId).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (list.isEmpty) continue;
    final before = list
        .map((s) => instantRangeLabel(clock, s.start, s.end))
        .join('、');
    final afterLabels = <String>[];
    for (final s in list) {
      var remaining = s.minutes;
      if (remaining <= 0) continue;
      final windows =
          availability.freeFrom(busy, notBefore: settings.startInstant);
      var firstChunk = true;
      for (final window in windows) {
        var cursor = window.start.isBefore(settings.startInstant)
            ? settings.startInstant
            : window.start;
        if (remaining <= 0) break;
        while (remaining > 0 && cursor.isBefore(window.end)) {
          final take = math.min(
            remaining,
            window.end.difference(cursor).inMinutes,
          );
          if (take <= 0) break;
          final id = firstChunk
              ? s.id
              : _uniqueSegmentId(
                  schedule,
                  '${s.id}-r$generated',
                  also: <String>{for (final p in placed) p.id},
                );
          final chunk = ScheduleSegment(
            id: id,
            taskId: s.taskId,
            start: cursor,
            end: cursor.add(Duration(minutes: take)),
            source: SegmentSource.manual,
            tentative: s.tentative,
            revision: s.revision + 1,
          );
          generated++;
          firstChunk = false;
          placed.add(chunk);
          busy.add(chunk.interval);
          afterLabels.add(instantRangeLabel(clock, chunk.start, chunk.end));
          remaining -= take;
          cursor = chunk.end;
        }
        if (remaining <= 0) break;
      }
      if (remaining > 0) return null; // 规划范围内放不下，不伪造时间
    }
    changes.add('${names[taskId] ?? taskId}：$before → '
        '${afterLabels.isEmpty ? '（未排）' : afterLabels.join('、')}');
  }
  if (changes.isEmpty) return null;

  final candidate = _withSegments(schedule, placed);
  final introduced = _introducedConflicts(
    candidate,
    tasks: tasks,
    now: now,
    names: names,
    baselineKeys: baselineKeys,
    original: original,
  );
  if (introduced == null) return null;
  return ConflictSuggestion(
    kind: SuggestionKind.rescheduleUnlocked,
    label: SuggestionKind.rescheduleUnlocked.label,
    scheduleAfter: candidate,
    affectedTaskIds: List<String>.unmodifiable(affected),
    changes: changes,
    addedConflictCount: introduced.length,
    deadlineRisk: _deadlineRisk(
      candidate: candidate,
      affected: affected,
      tasks: tasks,
      now: now,
      settings: settings,
    ),
  );
}

// ------------------------------------------------------------------ helpers

/// 候选排程校验：原冲突必须消失，且不得引入新冲突。
/// 返回“引入的新冲突”列表；候选不可接受时返回 null。
List<CalendarConflict>? _introducedConflicts(
  CalendarSchedule candidate, {
  required List<SchedulingTask> tasks,
  required DateTime now,
  required Map<String, String> names,
  required Set<String> baselineKeys,
  required CalendarConflict original,
}) {
  final conflicts = detectConflicts(
    schedule: candidate,
    tasks: tasks,
    now: now,
    taskNames: names,
  );
  final originalKey = _pairKey(original);
  if (conflicts.any((c) => _pairKey(c) == originalKey)) return null;
  final introduced = conflicts
      .where((c) => !baselineKeys.contains(_pairKey(c)))
      .toList(growable: false);
  if (introduced.isNotEmpty) return null;
  return introduced;
}

/// 任务对级别的冲突身份：类型 + 本任务 + 对方任务。
/// 候选里的片段 id/时间会变，用对级别比较才能判断“是否新增冲突”而不是“是否同一片段”。
String _pairKey(CalendarConflict conflict) => <String>[
      conflict.kind.name,
      conflict.taskId,
      conflict.otherTaskId ?? '',
    ].join('|');

bool _canSplit(ScheduleSegment segment, CalendarSettings settings) {
  if (segment.source != SegmentSource.auto) return false;
  final snap = math.max(1, settings.snapMinutes);
  return segment.minutes >= 2 * snap;
}

CalendarSchedule _withSegments(
  CalendarSchedule schedule,
  Iterable<ScheduleSegment> segments,
) =>
    schedule.copyWith(
      segments: List<ScheduleSegment>.unmodifiable(
        segments.toList()..sort((a, b) => a.start.compareTo(b.start)),
      ),
    );

String _uniqueSegmentId(
  CalendarSchedule schedule,
  String base, {
  Set<String> also = const <String>{},
}) {
  var id = base;
  var n = 1;
  while (schedule.segments.any((s) => s.id == id) || also.contains(id)) {
    id = '$base-${n++}';
  }
  return id;
}

bool _deadlineRisk({
  required CalendarSchedule candidate,
  required Iterable<String> affected,
  required List<SchedulingTask> tasks,
  required DateTime now,
  required CalendarSettings settings,
}) {
  final byId = <String, SchedulingTask>{for (final t in tasks) t.id: t};
  for (final id in affected) {
    final task = byId[id];
    if (task == null) continue;
    final at = parseDeadlineText(
      task.deadline,
      now: now,
      offsetMinutes: settings.timezoneOffsetMinutes,
    ).at;
    if (at == null) continue;
    final own = candidate.forTask(id);
    if (own.isEmpty) continue;
    final last = own
        .map((s) => s.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    if (last.isAfter(at)) return true;
  }
  return false;
}

String _noSuggestionReason({
  required CalendarConflict original,
  required ScheduleSegment? segment,
  required SchedulingTask? task,
}) {
  if (segment != null && segment.source == SegmentSource.manual) {
    return '该时段已手动固定';
  }
  if (task != null && task.isDone) {
    return '该任务已完成，历史安排只读';
  }
  switch (original.kind) {
    case ConflictKind.selfOverlap:
      return '同一任务两段时间重叠，且没有可用空档';
    case ConflictKind.taskOverlap:
      return '与其他任务重叠，且没有不引入新冲突的空档';
    case ConflictKind.unavailable:
      return '可用时间内没有足够空档';
    case ConflictKind.dependencyOrder:
      return '任务先后顺序冲突，需要调整依赖';
    case ConflictKind.uncertainDependency:
      return '前置任务还没有安排，无法自动排期';
    case ConflictKind.pastDeadline:
      return '截止时间前没有足够空档';
    case ConflictKind.outsideRange:
      return '片段超出规划范围';
  }
}
