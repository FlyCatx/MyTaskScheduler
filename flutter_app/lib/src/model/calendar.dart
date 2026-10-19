// 日历排程数据模型：墙钟时间区间、每周可用时间、日期例外、占用/休息时段与排程片段。
//
// 时间语义：持久化的时刻统一用 UTC ISO-8601；可复用规则用固定时区偏移
// （timezoneOffsetMinutes）下的墙钟值表达。
// 与 display.dart 的相对工时模型相互独立：本文件只描述真实墙钟时间。
//
// 主要类型：WallClockRange、TimeInterval、WallClock、WeeklyAvailability、
// CalendarDateException、CalendarOccupancy、CalendarSettings、ScheduleSegment、
// CalendarSchedule、SchedulingTask。

import 'dart:math' as math;

import 'plan.dart';

/// Default offset for Asia/Shanghai (+08:00).
const int kDefaultTimezoneOffsetMinutes = 480;
const String kDefaultTimezoneId = 'Asia/Shanghai';
const int kDefaultSnapMinutes = 15;
const int kDefaultPlanningDays = 14;
const int kDefaultChunkMinutes = 120;

/// Half-open wall-clock minute range inside one day (0 = local midnight).
///
/// `endMinute` may exceed 1440 to describe a window that runs past midnight.
class WallClockRange {
  final int startMinute;
  final int endMinute;

  const WallClockRange(this.startMinute, this.endMinute);

  bool get isValid => startMinute >= 0 && endMinute > startMinute;

  int get durationMinutes => math.max(0, endMinute - startMinute);

  bool overlaps(WallClockRange other) =>
      startMinute < other.endMinute && other.startMinute < endMinute;

  WallClockRange copyWith({int? startMinute, int? endMinute}) => WallClockRange(
        startMinute ?? this.startMinute,
        endMinute ?? this.endMinute,
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'start': startMinute, 'end': endMinute};

  factory WallClockRange.fromJson(Map<String, dynamic> j) => WallClockRange(
        (j['start'] as num?)?.toInt() ?? 0,
        (j['end'] as num?)?.toInt() ?? 0,
      );

  /// `08:00-12:00`, or `08:00-24:00` for a window that ends at midnight.
  ///
  /// Minute 1440 is written as "24:00" (not "00:00"): a window that ends at the end of
  /// the day must not look like it ends at the start of it. Minutes **beyond** 1440 mean
  /// "crosses midnight" and are written with the wrapped clock time (`22:00-02:00` for
  /// start 1320 / end 1560), because that is what the user typed and what the shared
  /// parser reads back: end < start is exactly the cross-midnight notation.
  static String format(WallClockRange r) =>
      '${_hourMinute(r.startMinute)}-${_hourMinuteEnd(r.endMinute)}';

  static String _hourMinuteEnd(int minute) {
    if (minute > 1440) return _hourMinute(minute % 1440);
    return _hourMinute(minute);
  }

  /// True when the range covers the whole wall-clock day (`00:00-24:00`).
  bool get isFullDay => startMinute == 0 && endMinute == 1440;

  /// True when [endMinute] is past midnight (minute 1440+).
  bool get crossesMidnight => endMinute > 1440;

  static String _hourMinute(int minute) {
    final h = minute ~/ 60;
    final m = minute % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  static String formatMinute(int minute) {
    final m = minute % 1440;
    final h = m ~/ 60;
    final mm = m % 60;
    return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  }

  String get label => format(this);

  @override
  bool operator ==(Object other) =>
      other is WallClockRange &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);

  @override
  String toString() => label;
}

/// A closed absolute time range. Always UTC internally.
class TimeInterval {
  final DateTime start;
  final DateTime end;

  TimeInterval(this.start, this.end);

  Duration get duration => end.difference(start);
  int get minutes => duration.inMinutes;
  bool get isEmpty => !end.isAfter(start);

  bool overlaps(TimeInterval other) =>
      start.isBefore(other.end) && other.start.isBefore(end);

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  TimeInterval? intersect(TimeInterval other) {
    final s = start.isAfter(other.start) ? start : other.start;
    final e = end.isBefore(other.end) ? end : other.end;
    if (!e.isAfter(s)) return null;
    return TimeInterval(s, e);
  }

  @override
  String toString() => '${start.toIso8601String()}..${end.toIso8601String()}';
}

/// Sorts and merges overlapping or touching intervals.
List<TimeInterval> mergeIntervals(Iterable<TimeInterval> input) {
  final sorted = input.where((i) => !i.isEmpty).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final out = <TimeInterval>[];
  for (final i in sorted) {
    if (out.isEmpty) {
      out.add(i);
      continue;
    }
    final last = out.last;
    if (!i.start.isAfter(last.end)) {
      out[out.length - 1] = TimeInterval(
        last.start,
        i.end.isAfter(last.end) ? i.end : last.end,
      );
    } else {
      out.add(i);
    }
  }
  return out;
}

/// `base` minus every interval in [cuts].
List<TimeInterval> subtractIntervals(
  List<TimeInterval> base,
  Iterable<TimeInterval> cuts,
) {
  final merged = mergeIntervals(cuts);
  var current = mergeIntervals(base);
  for (final cut in merged) {
    final next = <TimeInterval>[];
    for (final piece in current) {
      final overlap = piece.intersect(cut);
      if (overlap == null) {
        next.add(piece);
        continue;
      }
      if (overlap.start.isAfter(piece.start)) {
        next.add(TimeInterval(piece.start, overlap.start));
      }
      if (overlap.end.isBefore(piece.end)) {
        next.add(TimeInterval(overlap.end, piece.end));
      }
    }
    current = next;
  }
  return current;
}

/// Converts between UTC instants and the schedule's wall clock.
class WallClock {
  final int offsetMinutes;
  const WallClock(this.offsetMinutes);

  DateTime toWall(DateTime instant) =>
      instant.toUtc().add(Duration(minutes: offsetMinutes));

  DateTime fromWall(DateTime wall) =>
      wall.toUtc().subtract(Duration(minutes: offsetMinutes));

  /// Local midnight of the wall-clock day containing [instant], as UTC.
  DateTime dayStartUtc(DateTime instant) {
    final w = toWall(instant);
    return fromWall(DateTime.utc(w.year, w.month, w.day));
  }

  /// `yyyy-MM-dd` of the wall-clock day containing [instant].
  String dateKey(DateTime instant) {
    final w = toWall(instant);
    return formatDateKey(w.year, w.month, w.day);
  }

  DateTime dayStartUtcForDateKey(String dateKey) {
    final parts = dateKey.split('-');
    if (parts.length != 3) return DateTime.utc(1970);
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return DateTime.utc(1970);
    return fromWall(DateTime.utc(y, m, d));
  }

  static String formatDateKey(int y, int m, int d) =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-'
      '${d.toString().padLeft(2, '0')}';
}

/// `yyyy-MM-dd` in the schedule's wall clock.
String dateKeyOf(DateTime instant, int offsetMinutes) =>
    WallClock(offsetMinutes).dateKey(instant);

/// Parses `yyyy-MM-dd` / `yyyy/MM/dd` into a date key, or null.
String? parseDateKey(String text) {
  final m = RegExp(r'^\s*(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\s*$')
      .firstMatch(text);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  return WallClock.formatDateKey(y, mo, d);
}

/// Weekly availability keyed by ISO weekday (1 = Monday … 7 = Sunday).
class WeeklyAvailability {
  final Map<int, List<WallClockRange>> byWeekday;

  const WeeklyAvailability(this.byWeekday);

  static const WeeklyAvailability empty = WeeklyAvailability({});

  bool get isEmpty => byWeekday.values.every((r) => r.isEmpty);

  List<WallClockRange> forWeekday(int weekday) =>
      byWeekday[weekday] ?? const <WallClockRange>[];

  WeeklyAvailability withWeekday(int weekday, List<WallClockRange> ranges) {
    final next = Map<int, List<WallClockRange>>.from(byWeekday);
    if (ranges.isEmpty) {
      next.remove(weekday);
    } else {
      next[weekday] = List<WallClockRange>.unmodifiable(ranges);
    }
    return WeeklyAvailability(next);
  }

  /// Total open minutes per week — shown in the editor so "no availability" is visible
  /// instead of being silently treated as 24/7.
  int get weeklyMinutes => byWeekday.values
      .expand((r) => r)
      .fold<int>(0, (sum, r) => sum + math.max(0, r.durationMinutes));

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final entry in byWeekday.entries)
          '${entry.key}': entry.value.map((r) => r.toJson()).toList(),
      };

  factory WeeklyAvailability.fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final out = <int, List<WallClockRange>>{};
    raw.forEach((key, value) {
      final weekday = int.tryParse('$key');
      if (weekday == null || weekday < 1 || weekday > 7) return;
      final ranges = (value is List ? value : const [])
          .whereType<Map>()
          .map((e) => WallClockRange.fromJson(Map<String, dynamic>.from(e)))
          .where((r) => r.isValid)
          .toList(growable: false);
      if (ranges.isNotEmpty) out[weekday] = ranges;
    });
    return WeeklyAvailability(out);
  }
}

/// A single date that does not follow the weekly rule.
class CalendarDateException {
  final String date; // yyyy-MM-dd wall clock
  final bool closed;
  final List<WallClockRange> ranges;
  final String? note;

  const CalendarDateException({
    required this.date,
    this.closed = false,
    this.ranges = const [],
    this.note,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'closed': closed,
        'ranges': ranges.map((r) => r.toJson()).toList(),
        'note': note,
      };

  factory CalendarDateException.fromJson(Map<String, dynamic> j) =>
      CalendarDateException(
        date: (j['date'] as String?) ?? '',
        closed: j['closed'] == true,
        ranges: ((j['ranges'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) => WallClockRange.fromJson(Map<String, dynamic>.from(e)))
            .where((r) => r.isValid)
            .toList(growable: false),
        note: j['note'] as String?,
      );
}

/// Course / activity / rest that reduces the available time.
///
/// Either a one-off block ([date] set) or a weekly rule ([weekday] 1..7). A rest window
/// ("中午休息半小时") that has no position must NOT be turned into a block — the editor
/// keeps it as a pending note instead.
class CalendarOccupancy {
  final String id;
  final String title;

  /// `course` | `activity` | `rest`
  final String kind;

  /// yyyy-MM-dd for a one-off block; null for a weekly rule.
  final String? date;
  final int weekday; // 1..7, ignored when [date] is set
  final List<WallClockRange> ranges;

  /// Inferred / not confirmed by the user yet.
  final bool provisional;

  const CalendarOccupancy({
    required this.id,
    required this.title,
    this.kind = 'activity',
    this.date,
    this.weekday = 0,
    this.ranges = const [],
    this.provisional = false,
  });

  bool get isWeekly => date == null || date!.isEmpty;

  String get kindLabel => switch (kind) {
        'course' => '课程',
        'rest' => '休息',
        _ => '占用',
      };

  String get scheduleLabel {
    final when = isWeekly ? _weekdayLabel(weekday) : date!;
    final span =
        ranges.map((r) => WallClockRange.format(r)).join('、');
    return '$when $span';
  }

  static String _weekdayLabel(int weekday) => switch (weekday) {
        1 => '每周一',
        2 => '每周二',
        3 => '每周三',
        4 => '每周四',
        5 => '每周五',
        6 => '每周六',
        7 => '每周日',
        _ => '每周?',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'kind': kind,
        'date': date,
        'weekday': weekday,
        'ranges': ranges.map((r) => r.toJson()).toList(),
        'provisional': provisional,
      };

  factory CalendarOccupancy.fromJson(Map<String, dynamic> j) => CalendarOccupancy(
        id: (j['id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'activity',
        date: j['date'] as String?,
        weekday: (j['weekday'] as num?)?.toInt() ?? 0,
        ranges: ((j['ranges'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) => WallClockRange.fromJson(Map<String, dynamic>.from(e)))
            .where((r) => r.isValid)
            .toList(growable: false),
        provisional: j['provisional'] == true,
      );
}

/// Everything about *when* work may happen. Persisted with the version.
class CalendarSettings {
  final String timezoneId;
  final int timezoneOffsetMinutes;
  final String planningStartDate; // yyyy-MM-dd wall clock
  final int planningDays;
  final WeeklyAvailability weekly;
  final List<CalendarDateException> exceptions;
  final List<CalendarOccupancy> occupancies;
  final int snapMinutes;
  final int chunkMinutes;

  /// Free-text notes that could not be structured (e.g. "午休半小时" without a position).
  /// They are shown as 待确认 and never silently converted into rules.
  final List<String> pendingNotes;

  const CalendarSettings({
    this.timezoneId = kDefaultTimezoneId,
    this.timezoneOffsetMinutes = kDefaultTimezoneOffsetMinutes,
    this.planningStartDate = '',
    this.planningDays = kDefaultPlanningDays,
    this.weekly = WeeklyAvailability.empty,
    this.exceptions = const [],
    this.occupancies = const [],
    this.snapMinutes = kDefaultSnapMinutes,
    this.chunkMinutes = kDefaultChunkMinutes,
    this.pendingNotes = const [],
  });

  /// A settings object with *no* availability: the honest start when nothing is known.
  /// It must not be treated as "24 hours a day".
  factory CalendarSettings.blank({required DateTime now, int offsetMinutes = kDefaultTimezoneOffsetMinutes}) {
    final wall = WallClock(offsetMinutes);
    final today = wall.toWall(now);
    return CalendarSettings(
      timezoneOffsetMinutes: offsetMinutes,
      planningStartDate: WallClock.formatDateKey(
        today.year,
        today.month,
        today.day,
      ),
    );
  }

  WallClock get clock => WallClock(timezoneOffsetMinutes);

  bool get hasAvailability =>
      !weekly.isEmpty || exceptions.any((e) => !e.closed && e.ranges.isNotEmpty);

  /// True when the start date parses; otherwise the caller must fix it instead of
  /// inventing one.
  bool get hasValidStart => parseDateKey(planningStartDate) != null;

  DateTime get startInstant {
    final key = parseDateKey(planningStartDate);
    if (key == null) return clock.fromWall(DateTime.utc(1970));
    return clock.dayStartUtcForDateKey(key);
  }

  DateTime get endInstant =>
      startInstant.add(Duration(days: math.max(1, planningDays)));

  CalendarSettings copyWith({
    String? timezoneId,
    int? timezoneOffsetMinutes,
    String? planningStartDate,
    int? planningDays,
    WeeklyAvailability? weekly,
    List<CalendarDateException>? exceptions,
    List<CalendarOccupancy>? occupancies,
    int? snapMinutes,
    int? chunkMinutes,
    List<String>? pendingNotes,
  }) =>
      CalendarSettings(
        timezoneId: timezoneId ?? this.timezoneId,
        timezoneOffsetMinutes:
            timezoneOffsetMinutes ?? this.timezoneOffsetMinutes,
        planningStartDate: planningStartDate ?? this.planningStartDate,
        planningDays: planningDays ?? this.planningDays,
        weekly: weekly ?? this.weekly,
        exceptions: exceptions ?? this.exceptions,
        occupancies: occupancies ?? this.occupancies,
        snapMinutes: snapMinutes ?? this.snapMinutes,
        chunkMinutes: chunkMinutes ?? this.chunkMinutes,
        pendingNotes: pendingNotes ?? this.pendingNotes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timezoneId': timezoneId,
        'timezoneOffsetMinutes': timezoneOffsetMinutes,
        'planningStartDate': planningStartDate,
        'planningDays': planningDays,
        'weekly': weekly.toJson(),
        'exceptions': exceptions.map((e) => e.toJson()).toList(),
        'occupancies': occupancies.map((o) => o.toJson()).toList(),
        'snapMinutes': snapMinutes,
        'chunkMinutes': chunkMinutes,
        'pendingNotes': pendingNotes,
      };

  factory CalendarSettings.fromJson(Map<String, dynamic> j) => CalendarSettings(
        timezoneId: (j['timezoneId'] as String?) ?? kDefaultTimezoneId,
        timezoneOffsetMinutes:
            (j['timezoneOffsetMinutes'] as num?)?.toInt() ??
                kDefaultTimezoneOffsetMinutes,
        planningStartDate: (j['planningStartDate'] as String?) ?? '',
        planningDays:
            ((j['planningDays'] as num?)?.toInt() ?? kDefaultPlanningDays)
                .clamp(1, 366),
        weekly: WeeklyAvailability.fromJson(j['weekly']),
        exceptions: ((j['exceptions'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) => CalendarDateException.fromJson(
                Map<String, dynamic>.from(e)))
            .toList(growable: false),
        occupancies: ((j['occupancies'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) =>
                CalendarOccupancy.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false),
        snapMinutes:
            ((j['snapMinutes'] as num?)?.toInt() ?? kDefaultSnapMinutes)
                .clamp(1, 120),
        chunkMinutes:
            ((j['chunkMinutes'] as num?)?.toInt() ?? kDefaultChunkMinutes)
                .clamp(15, 720),
        pendingNotes: ((j['pendingNotes'] as List<dynamic>?) ?? const [])
            .map((e) => '$e')
            .where((s) => s.trim().isNotEmpty)
            .toList(growable: false),
      );
}

enum SegmentSource { auto, manual }

/// One concrete scheduled piece of a task. A task may have several (split across days
/// or around an occupied window).
class ScheduleSegment {
  final String id;
  final String taskId;
  final DateTime start; // UTC
  final DateTime end; // UTC
  final SegmentSource source;

  /// 暂定: the task is 待确认/受阻 but the user may still sketch time for it. A
  /// tentative segment never makes the task "ready" and never proves that its
  /// preconditions were met.
  final bool tentative;

  /// Bumped on every local edit of this segment (cheap revision trail / undo helper).
  final int revision;

  ScheduleSegment({
    required this.id,
    required this.taskId,
    required DateTime start,
    required DateTime end,
    this.source = SegmentSource.manual,
    this.tentative = false,
    this.revision = 0,
  })  : start = start.toUtc(),
        end = end.toUtc();

  Duration get duration => end.difference(start);
  int get minutes => duration.inMinutes;
  bool get isPositive => end.isAfter(start);
  TimeInterval get interval => TimeInterval(start, end);

  ScheduleSegment copyWith({
    String? id,
    String? taskId,
    DateTime? start,
    DateTime? end,
    SegmentSource? source,
    bool? tentative,
    int? revision,
  }) =>
      ScheduleSegment(
        id: id ?? this.id,
        taskId: taskId ?? this.taskId,
        start: start ?? this.start,
        end: end ?? this.end,
        source: source ?? this.source,
        tentative: tentative ?? this.tentative,
        revision: revision ?? this.revision,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'taskId': taskId,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'source': source.name,
        'tentative': tentative,
        'revision': revision,
      };

  factory ScheduleSegment.fromJson(Map<String, dynamic> j) => ScheduleSegment(
        id: (j['id'] as String?) ?? '',
        taskId: (j['taskId'] as String?) ?? '',
        start: DateTime.tryParse((j['start'] as String?) ?? '') ??
            DateTime.utc(1970),
        end: DateTime.tryParse((j['end'] as String?) ?? '') ??
            DateTime.utc(1970),
        source: j['source'] == 'auto'
            ? SegmentSource.auto
            : SegmentSource.manual,
        tentative: j['tentative'] == true,
        revision: (j['revision'] as num?)?.toInt() ?? 0,
      );
}

/// The calendar half of one plan version: settings + every task's segments.
class CalendarSchedule {
  final CalendarSettings settings;
  final List<ScheduleSegment> segments;

  /// Whether an automatic pass has run at least once (so re-entering the mode does not
  /// silently re-run it, and the UI can say "尚未生成安排").
  final bool autoGenerated;
  final String? note;

  const CalendarSchedule({
    this.settings = const CalendarSettings(),
    this.segments = const [],
    this.autoGenerated = false,
    this.note,
  });

  factory CalendarSchedule.blank({
    required DateTime now,
    int offsetMinutes = kDefaultTimezoneOffsetMinutes,
  }) =>
      CalendarSchedule(
        settings: CalendarSettings.blank(now: now, offsetMinutes: offsetMinutes),
      );

  bool get isEmpty => segments.isEmpty;

  bool get hasAvailability => settings.hasAvailability;

  List<ScheduleSegment> forTask(String taskId) =>
      segments.where((s) => s.taskId == taskId).toList(growable: false)
        ..sort((a, b) => a.start.compareTo(b.start));

  int minutesForTask(String taskId) =>
      forTask(taskId).fold<int>(0, (sum, s) => sum + math.max(0, s.minutes));

  ScheduleSegment? segmentById(String id) {
    for (final s in segments) {
      if (s.id == id) return s;
    }
    return null;
  }

  CalendarSchedule copyWith({
    CalendarSettings? settings,
    List<ScheduleSegment>? segments,
    bool? autoGenerated,
    String? note,
    bool clearNote = false,
  }) =>
      CalendarSchedule(
        settings: settings ?? this.settings,
        segments: segments ?? this.segments,
        autoGenerated: autoGenerated ?? this.autoGenerated,
        note: clearNote ? null : (note ?? this.note),
      );

  /// Version inheritance: keep only segments whose task still exists, and drop
  /// segments for tasks the new version removed.
  CalendarSchedule inheritedBy(Set<String> liveTaskIds) => copyWith(
        segments: segments
            .where((s) => liveTaskIds.contains(s.taskId))
            .toList(growable: false),
      );

  int get scheduledMinutes =>
      segments.fold<int>(0, (sum, s) => sum + math.max(0, s.minutes));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': 1,
        'settings': settings.toJson(),
        'segments': segments.map((s) => s.toJson()).toList(),
        'autoGenerated': autoGenerated,
        'note': note,
      };

  factory CalendarSchedule.fromJson(Object? raw, {required DateTime now}) {
    if (raw is! Map) return CalendarSchedule.blank(now: now);
    final j = Map<String, dynamic>.from(raw);
    return CalendarSchedule(
      settings: j['settings'] is Map
          ? CalendarSettings.fromJson(
              Map<String, dynamic>.from(j['settings'] as Map))
          : CalendarSettings.blank(now: now),
      segments: ((j['segments'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => ScheduleSegment.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.id.isNotEmpty && s.taskId.isNotEmpty)
          .toList(growable: false),
      autoGenerated: j['autoGenerated'] == true,
      note: j['note'] as String?,
    );
  }
}

/// Extra per-task facts the planner needs, derived from [TaskRecord] + the display
/// snapshot. Keeping it separate means the planner never reads UI state.
class SchedulingTask {
  final String id;
  final String name;
  final double? estimatedHours;
  final List<String> dependsOn;
  final String? deadline;
  final bool isDone;
  final bool isBlocked;
  final bool isPending;

  /// Position in the C core's suggested order (0 = first); used only as a tie-break.
  final int orderIndex;

  const SchedulingTask({
    required this.id,
    required this.name,
    this.estimatedHours,
    this.dependsOn = const [],
    this.deadline,
    this.isDone = false,
    this.isBlocked = false,
    this.isPending = false,
    this.orderIndex = 0,
  });

  bool get hoursKnown => estimatedHours != null && estimatedHours! > 0;

  int get estimatedMinutes => ((estimatedHours ?? 0) * 60).round();

  /// 待确认 / 受阻 tasks may only get 暂定 segments.
  bool get needsTentative => isBlocked || isPending;

  factory SchedulingTask.fromRecord(
    TaskRecord task, {
    String status = 'unknown',
    int orderIndex = 0,
  }) =>
      SchedulingTask(
        id: task.id,
        name: task.name,
        estimatedHours: task.estimatedHours,
        dependsOn: task.dependsOn,
        deadline: task.deadline,
        isDone: task.isDone,
        isBlocked: status == 'blocked',
        isPending: status == 'pending',
        orderIndex: orderIndex,
      );
}

