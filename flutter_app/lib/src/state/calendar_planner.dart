// 日历排程引擎：可用时间展开、确定性自动排程、冲突识别与“工时保持一致”的编辑规则。
// 纯计算，无 I/O、无控件状态；时钟由调用方注入，便于用固定时钟与时区测试。
// 排程是启发式：先满足依赖，再按截止时间、C 内核建议顺序与稳定 ID 排序；
// 不存在的容量如实报“还差 N”，不虚构未来时段。
//
// 主要类型：ParsedDeadline、AvailabilityCalendar、CalendarConflict、CalendarAutoPlan、
// CalendarEditOutcome。

import 'dart:math' as math;

import '../model/calendar.dart';
import '../model/plan.dart';

// ---------------------------------------------------------------- deadlines

/// Result of reading the free-text deadline the model produced.
class ParsedDeadline {
  final DateTime? at; // UTC instant
  final bool dateOnly;
  final bool inferred; // year / month / day had to be guessed
  final String? problem;

  const ParsedDeadline({
    this.at,
    this.dateOnly = false,
    this.inferred = false,
    this.problem,
  });

  static const ParsedDeadline none = ParsedDeadline();

  bool get known => at != null;

  String get label {
    final t = at;
    if (t == null) return '未提供';
    return t.toIso8601String();
  }
}

/// Parses the deadline strings the model is told to emit ("ISO 日期（YYYY-MM-DD）或带时间")
/// but tolerates the shapes that also appear in practice: `11-20 23:00`,
/// `20日23:00`, `11月20日`, `23:00`.
///
/// Ambiguity is never silently resolved into a precise instant: a missing year or month
/// is guessed from [now] and flagged [ParsedDeadline.inferred]; a missing time becomes
/// the end of that day and is flagged [ParsedDeadline.dateOnly].
ParsedDeadline parseDeadlineText(
  String? text, {
  required DateTime now,
  int offsetMinutes = kDefaultTimezoneOffsetMinutes,
}) {
  final raw = (text ?? '').trim();
  if (raw.isEmpty) return ParsedDeadline.none;
  final clock = WallClock(offsetMinutes);
  final wallNow = clock.toWall(now);

  // A complete ISO timestamp that carries its own zone (Z / +08:00) must keep that
  // zone. Re-applying the user's fixed offset here would move the instant.
  final zoned = RegExp(
    r'(\d{4})-(\d{1,2})-(\d{1,2})[T ](\d{1,2}):(\d{2})(?::(\d{2}))?\s*(Z|[+-]\d{2}:?\d{2})',
    caseSensitive: false,
  ).firstMatch(raw);
  if (zoned != null) {
    final y = int.parse(zoned.group(1)!);
    final m = int.parse(zoned.group(2)!);
    final d = int.parse(zoned.group(3)!);
    final h = int.parse(zoned.group(4)!);
    final min = int.parse(zoned.group(5)!);
    final sec = zoned.group(6) == null ? 0 : int.parse(zoned.group(6)!);
    final zone = zoned.group(7)!;
    if (!_validDate(y, m, d) || h > 23 || min > 59 || sec > 59) {
      return ParsedDeadline(problem: '截止时间不存在：$raw');
    }
    var zoneMinutes = 0;
    if (zone.toUpperCase() != 'Z') {
      final sign = zone.startsWith('-') ? -1 : 1;
      final digits = zone.substring(1).replaceAll(':', '');
      zoneMinutes = sign *
          (int.parse(digits.substring(0, 2)) * 60 +
              int.parse(digits.substring(2)));
    }
    final utc = DateTime.utc(y, m, d, h, min, sec)
        .subtract(Duration(minutes: zoneMinutes));
    return ParsedDeadline(at: utc, inferred: false);
  }

  final hhmm = RegExp(r'(\d{1,2})\s*[:：]\s*(\d{2})(?!\d)');
  final timeMatch = hhmm.firstMatch(raw);
  int? hour = timeMatch == null ? null : int.parse(timeMatch.group(1)!);
  int? minute = timeMatch == null ? null : int.parse(timeMatch.group(2)!);
  if (hour != null && (hour > 23 || minute! > 59)) {
    hour = null;
    minute = null;
  }

  // yyyy-M-d  (optionally followed by the time we already found)
  final iso = RegExp(r'(\d{4})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})')
      .firstMatch(raw);
  if (iso != null) {
    final y = int.parse(iso.group(1)!);
    final m = int.parse(iso.group(2)!);
    final d = int.parse(iso.group(3)!);
    if (!_validDate(y, m, d)) {
      return ParsedDeadline(problem: '截止日期不存在：$raw');
    }
    return _build(clock, y, m, d, hour, minute, inferred: false);
  }

  // M月D日 / M-D / M/D (no year)
  final cn = RegExp(r'(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]').firstMatch(raw);
  final slash = RegExp(r'(?:^|[^\d])(\d{1,2})\s*[-/]\s*(\d{1,2})(?!\d)')
      .firstMatch(raw);
  var month = cn != null
      ? int.parse(cn.group(1)!)
      : (slash != null ? int.parse(slash.group(1)!) : null);
  var day = cn != null
      ? int.parse(cn.group(2)!)
      : (slash != null ? int.parse(slash.group(2)!) : null);

  // "20日" / "20号" — day only, month inferred from now.
  if (day == null) {
    final dayOnly = RegExp(r'(\d{1,2})\s*[日号]').firstMatch(raw);
    if (dayOnly != null) {
      day = int.parse(dayOnly.group(1)!);
      month = wallNow.month;
    }
  }

  if (day != null) {
    var m = month ?? wallNow.month;
    var y = wallNow.year;
    if (m < 1 || m > 12 || day < 1 || !_validDate(y, m, day)) {
      // 2月30日 / 4月31日 等不能被静默归一化成下个月。
      return ParsedDeadline(problem: '截止日期不存在：$raw');
    }
    // A month/day that already looks like it passed refers to the next occurrence —
    // still flagged as inferred, because the text itself did not say which year.
    var candidate = DateTime.utc(y, m, day);
    if (candidate.isBefore(DateTime.utc(wallNow.year, wallNow.month, wallNow.day))) {
      if (cn == null && slash == null) {
        // day only: roll to the next month
        m = m + 1;
        if (m > 12) {
          m = 1;
          y += 1;
        }
      } else {
        y += 1;
      }
      if (!_validDate(y, m, day)) {
        return ParsedDeadline(problem: '截止日期不存在：$raw');
      }
      candidate = DateTime.utc(y, m, day);
    }
    return _build(clock, y, m, day, hour, minute, inferred: true);
  }

  // Time only: today at that time, or tomorrow when that time already passed.
  if (hour != null) {
    var day =
        DateTime.utc(wallNow.year, wallNow.month, wallNow.day, hour, minute!);
    if (clock.fromWall(day).isBefore(now)) {
      day = day.add(const Duration(days: 1));
    }
    return ParsedDeadline(at: clock.fromWall(day), inferred: true);
  }

  return ParsedDeadline(
    problem: '无法解析截止时间「$raw」，不计入日历约束',
  );
}

bool _validDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return false;
  final date = DateTime.utc(year, month, day);
  // DateTime normalizes impossible dates (2/30 -> 3/2); compare back.
  return date.year == year && date.month == month && date.day == day;
}

ParsedDeadline _build(
  WallClock clock,
  int y,
  int m,
  int d,
  int? hour,
  int? minute, {
  required bool inferred,
}) {
  final dateOnly = hour == null;
  final wall = DateTime.utc(y, m, d, hour ?? 23, dateOnly ? 59 : minute!);
  return ParsedDeadline(
    at: clock.fromWall(wall),
    dateOnly: dateOnly,
    inferred: inferred,
  );
}

// ------------------------------------------------------------- availability

/// Expanded availability for one planning range.
class AvailabilityCalendar {
  /// Open windows, merged and sorted. Empty means "the user has not told us when they
  /// can work" — it must never be treated as 24/7.
  final List<TimeInterval> open;

  /// Everything that was subtracted (courses / activities / rest / closed days).
  final List<TimeInterval> occupied;

  const AvailabilityCalendar(this.open, this.occupied);

  int get totalMinutes =>
      open.fold<int>(0, (sum, i) => sum + math.max(0, i.minutes));

  List<TimeInterval> freeFrom(
    List<TimeInterval> busy, {
    required DateTime notBefore,
    DateTime? notAfter,
  }) {
    final free =
        subtractIntervals(open, busy).where((i) => i.end.isAfter(notBefore));
    final out = <TimeInterval>[];
    for (final i in free) {
      final start = i.start.isBefore(notBefore) ? notBefore : i.start;
      var end = i.end;
      if (notAfter != null && end.isAfter(notAfter)) end = notAfter;
      if (end.isAfter(start)) out.add(TimeInterval(start, end));
    }
    return out;
  }
}

/// Expands [settings] into concrete UTC windows for its planning range.
AvailabilityCalendar buildAvailability(CalendarSettings settings) {
  final clock = settings.clock;
  final open = <TimeInterval>[];
  final occupied = <TimeInterval>[];
  final days = math.max(1, settings.planningDays);
  final start = settings.startInstant;

  final exceptionsByDate = <String, CalendarDateException>{
    for (final e in settings.exceptions) e.date: e,
  };

  for (var i = 0; i < days; i++) {
    final dayStart = start.add(Duration(days: i));
    final wall = clock.toWall(dayStart);
    final dateKey = WallClock.formatDateKey(wall.year, wall.month, wall.day);
    final exception = exceptionsByDate[dateKey];
    List<WallClockRange> ranges;
    if (exception != null) {
      ranges = exception.closed ? const [] : exception.ranges;
    } else {
      ranges = settings.weekly.forWeekday(wall.weekday);
    }
    final windows = mergeIntervals(<TimeInterval>[
      for (final r in ranges)
        if (r.isValid)
          TimeInterval(
            dayStart.add(Duration(minutes: r.startMinute)),
            dayStart.add(Duration(minutes: r.endMinute)),
          ),
    ]);
    final cuts = <TimeInterval>[];
    for (final o in settings.occupancies) {
      final matches =
          o.isWeekly ? o.weekday == wall.weekday : o.date == dateKey;
      if (!matches) continue;
      for (final r in o.ranges) {
        if (!r.isValid) continue;
        cuts.add(TimeInterval(
          dayStart.add(Duration(minutes: r.startMinute)),
          dayStart.add(Duration(minutes: r.endMinute)),
        ));
      }
    }
    occupied.addAll(cuts);
    open.addAll(subtractIntervals(windows, cuts));
  }

  return AvailabilityCalendar(mergeIntervals(open), mergeIntervals(occupied));
}

/// Human explanation for why [interval] is not fully available.
String describeUnavailable(
  CalendarSettings settings,
  TimeInterval interval,
) {
  final clock = settings.clock;
  final dateKey = clock.dateKey(interval.start);
  for (final e in settings.exceptions) {
    if (e.date == dateKey && e.closed) {
      final note = (e.note ?? '').trim();
      return note.isEmpty ? '当天被标记为不可用（$dateKey）' : '当天不可用：$note';
    }
  }
  final wall = clock.toWall(interval.start);
  final minute = WallClockRange.formatMinute(wall.hour * 60 + wall.minute);
  for (final o in settings.occupancies) {
    final matches =
        o.isWeekly ? o.weekday == wall.weekday : o.date == dateKey;
    if (!matches) continue;
    final dayStart = clock.dayStartUtc(interval.start);
    for (final r in o.ranges) {
      final blocked = TimeInterval(
        dayStart.add(Duration(minutes: r.startMinute)),
        dayStart.add(Duration(minutes: r.endMinute)),
      );
      if (blocked.overlaps(interval)) {
        // 外部日历是只读来源：说清楚它不会被程序改动，避免用户以为可以在这里删除。
        if (o.external) {
          return '外部日历占用 ${WallClockRange.format(r)}'
              '（只读外部忙碌，程序不会自动移动或删除）';
        }
        return '${o.kindLabel}「${o.title}」占用 ${WallClockRange.format(r)}';
      }
    }
  }
  return '不在可用时间内（$dateKey $minute）';
}

// --------------------------------------------------------------- conflicts

enum ConflictKind {
  selfOverlap,
  taskOverlap,
  unavailable,
  dependencyOrder,
  pastDeadline,
  uncertainDependency,
  outsideRange,
}

extension ConflictKindLabel on ConflictKind {
  String get label => switch (this) {
        ConflictKind.selfOverlap => '自身重叠',
        ConflictKind.taskOverlap => '任务重叠',
        ConflictKind.unavailable => '不可用时段',
        ConflictKind.dependencyOrder => '依赖顺序',
        ConflictKind.pastDeadline => '超过截止',
        ConflictKind.uncertainDependency => '依赖不确定',
        ConflictKind.outsideRange => '超出规划范围',
      };

  bool get isBlocking => switch (this) {
        ConflictKind.selfOverlap || ConflictKind.taskOverlap => true,
        ConflictKind.dependencyOrder || ConflictKind.pastDeadline => true,
        _ => false,
      };
}

/// 冲突的结构化来源：解释层用它说明“这条冲突是为什么出现的”。
///
/// 这是一个**旁路**字段：不参与既有的 [CalendarConflict.message] 展示，也不改变
/// “允许保存冲突、不自动顺延其他任务”的产品策略。它区分“用户时间表造成的不可用”
/// 与“程序可以给出建议的移动/拆分”，供本文件之外的解释层与建议层使用。
enum ConflictSource {
  /// 时间表里的课程/活动/休息占用。
  userOccupancy,

  /// 周可用范围外、日期关闭、规划范围外等“默认不可用”。
  defaultUnavailable,

  /// 其他任务已经占住的时间（已绑定的任务预留/已排片段）。
  taskReservation,

  /// 未绑定任务的蓝色预留：只占容量，不属于任何任务。
  taskReservationUnbound,

  /// 只读外部日历（ICS 导入）造成的忙碌。
  ///
  /// 外部事件在本程序里只读：解释层必须说明“来自只读外部日历，不会自动移动”，
  /// 建议只能落在用户自己的安排/时间表一侧（或停用/更新该外部来源）。
  externalCalendar,

  /// 任务之间的前后依赖顺序。
  dependency,

  /// 超过截止时间。
  deadline,

  /// 规划范围内可用容量不足（例如片段超出规划范围）。
  capacity,

  /// 同一任务的两个片段互相重叠。
  selfOverlap,
}

extension ConflictSourceLabel on ConflictSource {
  String get label => switch (this) {
        ConflictSource.userOccupancy => '用户占用',
        ConflictSource.defaultUnavailable => '默认不可用',
        ConflictSource.taskReservation => '任务预留',
        ConflictSource.taskReservationUnbound => '未绑定预留',
        ConflictSource.externalCalendar => '外部日历',
        ConflictSource.dependency => '前置依赖',
        ConflictSource.deadline => '截止时间',
        ConflictSource.capacity => '容量不足',
        ConflictSource.selfOverlap => '自身重叠',
      };

  /// 这类来源只能由用户在时间表/任务上明确调整，程序不得自动挪动或删除。
  bool get requiresUserAction => switch (this) {
        ConflictSource.userOccupancy ||
        ConflictSource.defaultUnavailable ||
        ConflictSource.taskReservation ||
        ConflictSource.taskReservationUnbound ||
        ConflictSource.externalCalendar =>
          true,
        _ => false,
      };
}

/// One detected problem. These are *allowed* to exist — the user explicitly chose
/// "允许保存冲突，但必须可见" — so they never block a save; they are listed and marked.
class CalendarConflict {
  final ConflictKind kind;
  final String taskId;
  final String? otherTaskId;
  final String? segmentId;
  final DateTime start;
  final DateTime end;
  final String message;

  /// 结构化来源判定（旁路，不参与 [message]）。旧调用方/手工构造时可为 null，
  /// 此时解释层可用 [conflictSourceOf] 重新判定。
  final ConflictSource? source;

  const CalendarConflict({
    required this.kind,
    required this.taskId,
    required this.start,
    required this.end,
    required this.message,
    this.otherTaskId,
    this.segmentId,
    this.source,
  });

  @override
  String toString() => '$kind($taskId): $message';
}

/// 判定一条冲突的结构化来源。已带 [CalendarConflict.source] 时原样返回；
/// 否则按 [schedule] 的同一份设置快照重新判定（不修改任何数据）。
ConflictSource conflictSourceOf(
  CalendarConflict conflict, {
  required CalendarSchedule schedule,
  CalendarSettings? settings,
}) {
  final carried = conflict.source;
  if (carried != null) return carried;
  final effective = settings ?? schedule.settings;
  final clock = effective.clock;
  switch (conflict.kind) {
    case ConflictKind.selfOverlap:
      return ConflictSource.selfOverlap;
    case ConflictKind.taskOverlap:
      return ConflictSource.taskReservation;
    case ConflictKind.dependencyOrder:
    case ConflictKind.uncertainDependency:
      return ConflictSource.dependency;
    case ConflictKind.pastDeadline:
      return ConflictSource.deadline;
    case ConflictKind.outsideRange:
      return ConflictSource.capacity;
    case ConflictKind.unavailable:
      return _unavailableSource(
        effective,
        clock,
        TimeInterval(conflict.start, conflict.end),
      );
  }
}

/// 解释一个“不可用区间”到底是被什么挡住的（同 [CalendarSettings] 快照）。
ConflictSource _unavailableSource(
  CalendarSettings settings,
  WallClock clock,
  TimeInterval gap,
) {
  final blocker = occupancyBlockingInterval(settings, gap);
  if (blocker != null) {
    if (blocker.external) return ConflictSource.externalCalendar;
    if (blocker.taskId != null && blocker.taskId!.isNotEmpty) {
      return ConflictSource.taskReservation;
    }
    if ((blocker.reservationId != null &&
            blocker.reservationId!.isNotEmpty) ||
        _looksLikeUnboundReservation(blocker)) {
      return ConflictSource.taskReservationUnbound;
    }
    return ConflictSource.userOccupancy;
  }
  return ConflictSource.defaultUnavailable;
}

/// 命中 [interval] 的具体占用（与 [describeUnavailable] 的检查顺序一致）。
///
/// 返回 null 表示该区间属于“默认不可用”（日期闭日、该星期没有可用范围，或
/// 根本没有占用与之重叠），而不是某一条具体占用。外部日历占用带
/// `external == true` 与 `sourceId`，解释层据此显示“外部日历”来源。
CalendarOccupancy? occupancyBlockingInterval(
  CalendarSettings settings,
  TimeInterval interval,
) {
  final clock = settings.clock;
  final dateKey = clock.dateKey(interval.start);
  for (final e in settings.exceptions) {
    if (e.date == dateKey && e.closed) return null;
  }
  final wall = clock.toWall(interval.start);
  if (settings.weekly.forWeekday(wall.weekday).isEmpty) return null;
  final dayStart = clock.dayStartUtc(interval.start);
  for (final o in settings.occupancies) {
    final matches =
        o.isWeekly ? o.weekday == wall.weekday : o.date == dateKey;
    if (!matches) continue;
    for (final r in o.ranges) {
      if (!r.isValid) continue;
      final blocked = TimeInterval(
        dayStart.add(Duration(minutes: r.startMinute)),
        dayStart.add(Duration(minutes: r.endMinute)),
      );
      if (blocked.overlaps(interval)) return o;
    }
  }
  return null;
}

/// 未绑定的蓝色预留由 `Timetable.toCalendarSettings` 转成一条 `activity` 占用，
/// 标题缺省为「任务预留」；它没有 taskId/reservationId，因此仍可被识别出来。
bool _looksLikeUnboundReservation(CalendarOccupancy o) {
  if (o.taskId != null && o.taskId!.isNotEmpty) return false;
  if (o.reservationId != null && o.reservationId!.isNotEmpty) return false;
  return o.title.trim().startsWith('任务预留');
}

String formatDurationMinutes(int minutes) {
  final m = math.max(0, minutes);
  final h = m ~/ 60;
  final rest = m % 60;
  if (h == 0) return '$rest 分钟';
  if (rest == 0) return '$h 小时';
  return '$h 小时 $rest 分';
}

double hoursFromMinutes(int minutes) => minutes / 60.0;

String formatHours(double? hours) {
  if (hours == null) return '待确认';
  final minutes = (hours * 60).round();
  return formatDurationMinutes(minutes);
}

/// Detects every conflict kind the product decided to surface.
List<CalendarConflict> detectConflicts({
  required CalendarSchedule schedule,
  required List<SchedulingTask> tasks,
  required DateTime now,
  Map<String, String>? taskNames,
}) {
  final settings = schedule.settings;
  final clock = settings.clock;
  final availability = buildAvailability(settings);
  final byTask = <String, List<ScheduleSegment>>{};
  for (final s in schedule.segments) {
    byTask.putIfAbsent(s.taskId, () => <ScheduleSegment>[]).add(s);
  }
  for (final list in byTask.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }
  String nameOf(String id) => taskNames?[id] ?? id;
  final out = <CalendarConflict>[];
  final segments = schedule.segments;

  // Pairwise overlaps.
  for (var i = 0; i < segments.length; i++) {
    for (var j = i + 1; j < segments.length; j++) {
      final a = segments[i];
      final b = segments[j];
      if (!a.interval.overlaps(b.interval)) continue;
      final overlap = a.interval.intersect(b.interval)!;
      final sameTask = a.taskId == b.taskId;
      out.add(CalendarConflict(
        kind: sameTask ? ConflictKind.selfOverlap : ConflictKind.taskOverlap,
        taskId: a.taskId,
        otherTaskId: sameTask ? null : b.taskId,
        segmentId: a.id,
        start: overlap.start,
        end: overlap.end,
        message: sameTask
            ? '${nameOf(a.taskId)} 的两个片段重叠 '
                '${formatDurationMinutes(overlap.minutes)}'
            : '${nameOf(a.taskId)} 与 ${nameOf(b.taskId)} 重叠 '
                '${formatDurationMinutes(overlap.minutes)}',
        source: sameTask
            ? ConflictSource.selfOverlap
            : ConflictSource.taskReservation,
      ));
    }
  }

  // Each segment must lie inside an open window.
  for (final s in segments) {
    final covered = subtractIntervals(
      <TimeInterval>[s.interval],
      availability.open,
    );
    for (final gap in covered) {
      out.add(CalendarConflict(
        kind: ConflictKind.unavailable,
        taskId: s.taskId,
        segmentId: s.id,
        start: gap.start,
        end: gap.end,
        message: '${nameOf(s.taskId)} 落在不可用时段：'
            '${describeUnavailable(settings, gap)}',
        source: _unavailableSource(settings, clock, gap),
      ));
    }
    if (s.start.isBefore(settings.startInstant) ||
        s.end.isAfter(settings.endInstant)) {
      out.add(CalendarConflict(
        kind: ConflictKind.outsideRange,
        taskId: s.taskId,
        segmentId: s.id,
        start: s.start,
        end: s.end,
        message: '${nameOf(s.taskId)} 超出规划范围 '
            '${settings.planningStartDate} 起 ${settings.planningDays} 天',
        source: ConflictSource.capacity,
      ));
    }
  }

  // Dependencies and deadlines.
  final taskById = <String, SchedulingTask>{
    for (final t in tasks) t.id: t,
  };
  for (final task in tasks) {
    final own = byTask[task.id];
    if (own == null || own.isEmpty) continue;
    final first = own.first.start;
    final last = own.last.end;
    for (final depId in task.dependsOn) {
      final dep = byTask[depId];
      if (dep == null || dep.isEmpty) {
        final depTask = taskById[depId];
        if (depTask != null && !depTask.isDone) {
          out.add(CalendarConflict(
            kind: ConflictKind.uncertainDependency,
            taskId: task.id,
            otherTaskId: depId,
            segmentId: own.first.id,
            start: own.first.start,
            end: own.first.end,
            message: '${nameOf(task.id)} 的前置 ${nameOf(depId)} 尚未安排，'
                '这里的时间只是暂定',
            source: ConflictSource.dependency,
          ));
        }
        continue;
      }
      final depEnd = dep.last.end;
      if (first.isBefore(depEnd)) {
        out.add(CalendarConflict(
          kind: ConflictKind.dependencyOrder,
          taskId: task.id,
          otherTaskId: depId,
          segmentId: own.first.id,
          start: first,
          end: depEnd.isBefore(last) ? depEnd : last,
          message: '${nameOf(task.id)} 在前置 ${nameOf(depId)} 完成前就开始了',
          source: ConflictSource.dependency,
        ));
      }
    }
    final deadline =
        parseDeadlineText(task.deadline, now: now, offsetMinutes: settings.timezoneOffsetMinutes);
    if (deadline.at != null && last.isAfter(deadline.at!)) {
      out.add(CalendarConflict(
        kind: ConflictKind.pastDeadline,
        taskId: task.id,
        segmentId: own.last.id,
        start: deadline.at!,
        end: last,
        message: '${nameOf(task.id)} 的安排晚于截止 '
            '${_formatInstant(deadline.at!, clock)}',
        source: ConflictSource.deadline,
      ));
    }
  }

  out.sort((a, b) {
    final c = a.start.compareTo(b.start);
    if (c != 0) return c;
    return a.taskId.compareTo(b.taskId);
  });
  return out;
}

String _formatInstant(DateTime instant, WallClock clock) {
  final w = clock.toWall(instant);
  return '${wallDateLabel(w)} ${WallClockRange.formatMinute(w.hour * 60 + w.minute)}';
}

String wallDateLabel(DateTime wall) =>
    '${wall.month}月${wall.day}日 ${_weekdayShort(wall.weekday)}';

String _weekdayShort(int weekday) => switch (weekday) {
      1 => '周一',
      2 => '周二',
      3 => '周三',
      4 => '周四',
      5 => '周五',
      6 => '周六',
      _ => '周日',
    };

// ---------------------------------------------------------- auto scheduling

/// Outcome of an automatic pass. Segments are the *complete* new set.
class CalendarAutoPlan {
  final CalendarSchedule schedule;
  final List<String> notes;
  final Map<String, String> taskNotes;

  const CalendarAutoPlan({
    required this.schedule,
    this.notes = const <String>[],
    this.taskNotes = const <String, String>{},
  });
}

/// Deterministic heuristic auto-scheduler. See the file header for the rules.
CalendarAutoPlan autoSchedule({
  required CalendarSchedule current,
  required List<SchedulingTask> tasks,
  List<String> suggestedOrder = const [],
  required DateTime now,
  bool keepManual = true,
  String Function()? newId,
}) {
  final settings = current.settings;
  final notes = <String>[];
  final taskNotes = <String, String>{};
  final generator = newId ?? () => IdGenerator.next('seg');

  if (!settings.hasValidStart) {
    return CalendarAutoPlan(
      schedule: current,
      notes: const ['排程起始日期无效：请先在“可用时间”里设置为 yyyy-MM-dd。'],
    );
  }
  final availability = buildAvailability(settings);
  if (availability.open.isEmpty) {
    return CalendarAutoPlan(
      schedule: current,
      notes: const [
        '没有可用时间，无法自动安排。请先在“可用时间与占用时间”里设置每周可用时间、'
            '日期例外和课程占用；程序不会假设你每天 24 小时都能工作。',
      ],
    );
  }

  final kept = keepManual
      ? current.segments
          .where((s) => s.source == SegmentSource.manual)
          .toList(growable: false)
      : const <ScheduleSegment>[];
  final out = <ScheduleSegment>[...kept];
  final busy = <TimeInterval>[for (final s in kept) s.interval];
  final keptMinutes = <String, int>{};
  for (final s in kept) {
    keptMinutes[s.taskId] = (keptMinutes[s.taskId] ?? 0) + math.max(0, s.minutes);
  }

  final taskById = <String, SchedulingTask>{for (final t in tasks) t.id: t};
  final doneIds = <String>{
    for (final t in tasks)
      if (t.isDone) t.id,
  };
  final candidates = tasks
      .where((t) => !t.isDone)
      .toList(growable: false);

  for (final t in candidates) {
    if (!t.hoursKnown) {
      taskNotes[t.id] = '预计工时未知，无法自动安排（请在任务详情补充工时）';
    }
  }

  final ordered = _orderTasks(
    candidates.where((t) => t.hoursKnown).toList(growable: false),
    suggestedOrder,
    notes,
    now: now,
    offsetMinutes: settings.timezoneOffsetMinutes,
  );

  for (final task in ordered) {
    var remaining = task.estimatedMinutes - (keptMinutes[task.id] ?? 0);
    if (remaining <= 0) continue;

    // Never start before now, nor before every predecessor's last scheduled segment.
    var notBefore = now;
    final unresolved = <String>[];
    for (final depId in task.dependsOn) {
      final own = out.where((s) => s.taskId == depId).toList(growable: false);
      if (own.isEmpty) {
        if (!doneIds.contains(depId) && taskById.containsKey(depId)) {
          unresolved.add(depId);
        }
        continue;
      }
      final depEnd = own
          .map((s) => s.end)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (depEnd.isAfter(notBefore)) notBefore = depEnd;
    }
    if (unresolved.isNotEmpty) {
      taskNotes[task.id] =
          '前置 ${unresolved.map((id) => taskById[id]?.name ?? id).join('、')} '
          '还没有安排，这里只是暂定时间';
    }

    final tentative = task.needsTentative;
    final deadline = parseDeadlineText(
      task.deadline,
      now: now,
      offsetMinutes: settings.timezoneOffsetMinutes,
    );
    final deadlineAt = deadline.at;
    final cursor = notBefore;

    // Pass 1: fit as much as possible before the deadline.
    if (deadlineAt != null && deadlineAt.isAfter(cursor)) {
      final placed = _place(
        availability: availability,
        busy: busy,
        out: out,
        taskId: task.id,
        from: cursor,
        until: deadlineAt,
        minutes: remaining,
        chunkMinutes: settings.chunkMinutes,
        tentative: tentative,
        newId: generator,
      );
      remaining -= placed;
    }
    // Pass 2: whatever is left continues after the deadline and is flagged as overdue
    // by the conflict detector — the deadline itself is never modified.
    if (remaining > 0) {
      final from = out
              .where((s) => s.taskId == task.id)
              .fold<DateTime?>(null, (latest, s) {
            final e = s.end;
            if (latest == null || e.isAfter(latest)) return e;
            return latest;
          }) ??
          cursor;
      final startFrom = from.isAfter(cursor) ? from : cursor;
      _place(
        availability: availability,
        busy: busy,
        out: out,
        taskId: task.id,
        from: startFrom,
        until: null,
        minutes: remaining,
        chunkMinutes: settings.chunkMinutes,
        tentative: tentative,
        newId: generator,
      );
    }

    final placedMinutes =
        out.where((s) => s.taskId == task.id).fold<int>(0, (sum, s) => sum + s.minutes);
    final needed = math.max(0, task.estimatedMinutes - placedMinutes);
    if (needed > 0) {
      taskNotes[task.id] =
          '容量不足：已安排 ${formatDurationMinutes(placedMinutes)}，'
          '仍需 ${formatDurationMinutes(needed)}（规划范围内没有更多可用时段）';
    }
  }

  _mergeContiguous(out);

  return CalendarAutoPlan(
    schedule: current.copyWith(
      segments: List<ScheduleSegment>.unmodifiable(out),
      autoGenerated: true,
      note: notes.isEmpty ? null : notes.join(' '),
    ),
    notes: notes,
    taskNotes: taskNotes,
  );
}

/// Kahn topological order with a deterministic priority: earliest deadline, then the
/// C core's suggested order, then the stable id. Nodes left over form a cycle; they are
/// reported and skipped instead of being scheduled in an arbitrary order.
List<SchedulingTask> _orderTasks(
  List<SchedulingTask> candidates,
  List<String> suggestedOrder,
  List<String> notes, {
  required DateTime now,
  required int offsetMinutes,
}) {
  final byId = <String, SchedulingTask>{for (final t in candidates) t.id: t};
  final orderIndex = <String, int>{
    for (var i = 0; i < suggestedOrder.length; i++) suggestedOrder[i]: i,
  };
  int deadlineRank(SchedulingTask t) {
    final at = parseDeadlineText(
      t.deadline,
      now: now,
      offsetMinutes: offsetMinutes,
    ).at;
    // No deadline sorts last, but deterministically.
    if (at == null) return 1 << 40;
    return at.millisecondsSinceEpoch ~/ 60000;
  }

  final indegree = <String, int>{for (final t in byId.keys) t: 0};
  final children = <String, List<String>>{};
  for (final t in candidates) {
    for (final dep in t.dependsOn) {
      if (!byId.containsKey(dep)) continue; // done or not a candidate
      indegree[t.id] = (indegree[t.id] ?? 0) + 1;
      children.putIfAbsent(dep, () => <String>[]).add(t.id);
    }
  }
  int compare(SchedulingTask a, SchedulingTask b) {
    final da = deadlineRank(a);
    final db = deadlineRank(b);
    if (da != db) return da.compareTo(db);
    final oa = orderIndex[a.id] ?? 1 << 30;
    final ob = orderIndex[b.id] ?? 1 << 30;
    if (oa != ob) return oa.compareTo(ob);
    return a.id.compareTo(b.id);
  }

  final ready = candidates.where((t) => (indegree[t.id] ?? 0) == 0).toList()
    ..sort(compare);
  final scheduled = <String>{};
  final out = <SchedulingTask>[];
  while (ready.isNotEmpty) {
    final t = ready.removeAt(0);
    out.add(t);
    scheduled.add(t.id);
    for (final child in children[t.id] ?? const <String>[]) {
      indegree[child] = (indegree[child] ?? 1) - 1;
      if (indegree[child] == 0) {
        ready.add(byId[child]!);
        ready.sort(compare);
      }
    }
  }
  final leftover =
      candidates.where((t) => !scheduled.contains(t.id)).toList();
  if (leftover.isNotEmpty) {
    notes.add('以下任务依赖成环，未自动安排：'
        '${leftover.map((t) => t.name).join('、')}');
  }
  return out;
}

/// Places up to [minutes] of work, returns how many minutes were placed.
int _place({
  required AvailabilityCalendar availability,
  required List<TimeInterval> busy,
  required List<ScheduleSegment> out,
  required String taskId,
  required DateTime from,
  required DateTime? until,
  required int minutes,
  required int chunkMinutes,
  required bool tentative,
  required String Function() newId,
}) {
  if (minutes <= 0) return 0;
  final free = availability.freeFrom(busy, notBefore: from, notAfter: until);
  var remaining = minutes;
  var placed = 0;
  for (final window in free) {
    if (remaining <= 0) break;
    var cursor = window.start;
    while (remaining > 0 && cursor.isBefore(window.end)) {
      final available = window.end.difference(cursor).inMinutes;
      final take = math.min(remaining, math.min(chunkMinutes, available));
      if (take <= 0) break;
      final end = cursor.add(Duration(minutes: take));
      out.add(ScheduleSegment(
        id: newId(),
        taskId: taskId,
        start: cursor,
        end: end,
        source: SegmentSource.auto,
        tentative: tentative,
      ));
      busy.add(TimeInterval(cursor, end));
      remaining -= take;
      placed += take;
      cursor = end;
    }
  }
  return placed;
}

/// Joins adjacent chunks of the same task so the chart does not show a dashed line for
/// work that is actually continuous. Only exact contiguity (same task, same source,
/// same tentative flag, `end == next.start`) is merged — never overlapping work, which
/// must stay visible as a self-conflict.
void _mergeContiguous(List<ScheduleSegment> segments) {
  final byTask = <String, List<ScheduleSegment>>{};
  for (final s in segments) {
    byTask.putIfAbsent(s.taskId, () => <ScheduleSegment>[]).add(s);
  }
  final merged = <ScheduleSegment>[];
  for (final list in byTask.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
    var current = list.first;
    for (final s in list.skip(1)) {
      if (current.source == s.source &&
          current.tentative == s.tentative &&
          current.end.isAtSameMomentAs(s.start)) {
        current = current.copyWith(end: s.end);
      } else {
        merged.add(current);
        current = s;
      }
    }
    merged.add(current);
  }
  merged.sort((a, b) => a.start.compareTo(b.start));
  segments
    ..clear()
    ..addAll(merged);
}

// ------------------------------------------------------------- edit rules

/// A single atomic calendar edit: new segments **and** the task records whose
/// estimated hours changed. `error` means the input was structurally invalid and
/// nothing may be applied.
class CalendarEditOutcome {
  final CalendarSchedule? schedule;
  final List<TaskRecord>? tasks;
  final String label;
  final String? error;
  final String? message;

  const CalendarEditOutcome({
    this.schedule,
    this.tasks,
    this.label = '调整安排',
    this.error,
    this.message,
  });

  bool get ok => error == null && schedule != null;

  static CalendarEditOutcome failure(String error) =>
      CalendarEditOutcome(error: error);
}

double _hoursOf(TaskRecord t) => t.estimatedHours ?? 0;
int _estimateMinutes(TaskRecord t) => (_hoursOf(t) * 60).round();

CalendarSchedule _withSegments(
  CalendarSchedule schedule,
  Iterable<ScheduleSegment> segments,
) =>
    schedule.copyWith(
      segments: List<ScheduleSegment>.unmodifiable(
        segments.toList()..sort((a, b) => a.start.compareTo(b.start)),
      ),
    );

/// Moves a segment to a new start, keeping its duration (so the estimate never
/// changes because of a move).
CalendarEditOutcome moveSegment({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String segmentId,
  required DateTime newStart,
}) {
  final segment = schedule.segmentById(segmentId);
  if (segment == null) {
    return CalendarEditOutcome.failure('找不到要移动的安排片段');
  }
  if (!segment.isPositive) {
    return CalendarEditOutcome.failure('片段时长必须大于 0');
  }
  final duration = segment.duration;
  final next = segment.copyWith(
    start: newStart,
    end: newStart.add(duration),
    source: SegmentSource.manual,
    revision: segment.revision + 1,
  );
  return CalendarEditOutcome(
    schedule: _withSegments(
      schedule,
      schedule.segments.map((s) => s.id == segmentId ? next : s),
    ),
    tasks: tasks,
    label: '移动安排片段',
  );
}

/// Resizes one end of a segment.
///
/// Hours rule (0.06): `新预计工时 = 旧预计工时 + 本次片段时长变化量`, which keeps a
/// partial schedule's unallocated balance intact and, for a fully scheduled task,
/// collapses to "estimate = sum of segments".
CalendarEditOutcome resizeSegment({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String segmentId,
  DateTime? newStart,
  DateTime? newEnd,
}) {
  final segment = schedule.segmentById(segmentId);
  if (segment == null) {
    return CalendarEditOutcome.failure('找不到要调整的安排片段');
  }
  final start = newStart ?? segment.start;
  final end = newEnd ?? segment.end;
  if (!end.isAfter(start)) {
    return CalendarEditOutcome.failure('结束时间必须晚于开始时间');
  }
  final deltaMinutes = end.difference(start).inMinutes - segment.minutes;
  final next = segment.copyWith(
    start: start,
    end: end,
    source: SegmentSource.manual,
    revision: segment.revision + 1,
  );
  final taskIndex = tasks.indexWhere((t) => t.id == segment.taskId);
  if (taskIndex < 0) {
    return CalendarEditOutcome.failure('找不到该片段所属的任务');
  }
  final task = tasks[taskIndex];
  final newMinutes = math.max(1, _estimateMinutes(task) + deltaMinutes);
  final updatedTasks = List<TaskRecord>.from(tasks);
  updatedTasks[taskIndex] =
      task.copyWith(estimatedHours: hoursFromMinutes(newMinutes));
  return CalendarEditOutcome(
    schedule: _withSegments(
      schedule,
      schedule.segments.map((s) => s.id == segmentId ? next : s),
    ),
    tasks: updatedTasks,
    label: deltaMinutes >= 0 ? '延长安排片段' : '缩短安排片段',
    message: deltaMinutes == 0
        ? null
        : '预计工时已按片段变化量更新为 '
            '${formatHours(hoursFromMinutes(newMinutes))}',
  );
}

/// Adds a new segment and increases the estimate by exactly its duration.
CalendarEditOutcome addSegment({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String taskId,
  required DateTime start,
  required DateTime end,
  bool tentative = false,
  String? newId,
}) {
  if (!end.isAfter(start)) {
    return CalendarEditOutcome.failure('结束时间必须晚于开始时间');
  }
  final taskIndex = tasks.indexWhere((t) => t.id == taskId);
  if (taskIndex < 0) return CalendarEditOutcome.failure('找不到该任务');
  final minutes = end.difference(start).inMinutes;
  final task = tasks[taskIndex];
  final updatedTasks = List<TaskRecord>.from(tasks);
  updatedTasks[taskIndex] =
      task.copyWith(estimatedHours: hoursFromMinutes(_estimateMinutes(task) + minutes));
  final segment = ScheduleSegment(
    id: newId ?? IdGenerator.next('seg'),
    taskId: taskId,
    start: start,
    end: end,
    source: SegmentSource.manual,
    tentative: tentative,
  );
  return CalendarEditOutcome(
    schedule: _withSegments(schedule, [...schedule.segments, segment]),
    tasks: updatedTasks,
    label: '新增安排片段',
    message: '预计工时增加 ${formatDurationMinutes(minutes)}，'
        '变为 ${formatHours(hoursFromMinutes(_estimateMinutes(task) + minutes))}',
  );
}

/// Cancels a segment: the work goes back to the *unallocated* balance and the
/// estimated hours are **not** changed. Deliberately separate from [resizeSegment]
/// ("减少任务工作量"), so the two actions cannot be confused.
CalendarEditOutcome cancelSegment({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String segmentId,
}) {
  final segment = schedule.segmentById(segmentId);
  if (segment == null) {
    return CalendarEditOutcome.failure('找不到要取消的安排片段');
  }
  return CalendarEditOutcome(
    schedule: _withSegments(
      schedule,
      schedule.segments.where((s) => s.id != segmentId),
    ),
    tasks: tasks,
    label: '取消此段安排',
    message: '已取消 ${formatDurationMinutes(segment.minutes)} 的安排，'
        '工时回到未安排余额（预计工时不变）',
  );
}

/// Splits one segment into two positive-duration pieces at [at]. Total duration — and
/// therefore the estimate — stays the same.
CalendarEditOutcome splitSegment({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String segmentId,
  required DateTime at,
  String? newId,
}) {
  final segment = schedule.segmentById(segmentId);
  if (segment == null) {
    return CalendarEditOutcome.failure('找不到要拆分的安排片段');
  }
  if (!at.isAfter(segment.start) || !at.isBefore(segment.end)) {
    return CalendarEditOutcome.failure('拆分点必须严格落在片段内部');
  }
  final first = segment.copyWith(
    end: at,
    source: SegmentSource.manual,
    revision: segment.revision + 1,
  );
  final second = ScheduleSegment(
    id: newId ?? IdGenerator.next('seg'),
    taskId: segment.taskId,
    start: at,
    end: segment.end,
    source: SegmentSource.manual,
    tentative: segment.tentative,
    revision: segment.revision + 1,
  );
  return CalendarEditOutcome(
    schedule: _withSegments(
      schedule,
      schedule.segments
          .map((s) => s.id == segmentId ? first : s)
          .followedBy([second]),
    ),
    tasks: tasks,
    label: '拆分安排片段',
    message: '已拆成两段，总时长不变（${formatDurationMinutes(segment.minutes)}）',
  );
}

/// Full replacement used by the availability editor and "重新自动安排" — one atomic
/// commit, so a failed save cannot leave half of the schedule applied.
CalendarEditOutcome replaceSchedule({
  required CalendarSchedule schedule,
  required List<TaskRecord> tasks,
  required String label,
  String? message,
}) =>
    CalendarEditOutcome(
      schedule: schedule,
      tasks: tasks,
      label: label,
      message: message,
    );
