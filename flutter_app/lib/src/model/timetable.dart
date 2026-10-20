// 结构化周时间表（协议 v2）。
//
// 本文件是“手动填写 / 手动绘制 / 模型识别”三种来源共用的数据模型：
//   * 7 天 × 96 个 15 分钟格只是显示粒度，底层始终保存整分钟的半开区间；
//   * 每个区间有 state（0 占用 / 1 空闲 / 2 任务预留或安排）、来源和可选的
//     日期、星期、任务绑定与预留身份；
//   * 具体日期规则覆盖周模板；同一层内不允许互相矛盾的区间；
//   * 跨午夜在规范化时拆成当日 [23:00,24:00) 与次日 [00:00,08:00)。
//
// 主要类型：TimetableState、TimetableOrigin、TimetableEntry、TimetableInterval、
// Timetable、TimetableDraft。
//
// 与 calendar.dart 的关系：CalendarSettings 仍是排程器的输入；Timetable 是编辑器
// 与模型请求的输入。两者通过 fromSchedule / toCalendarSettings 双向转换，转换时
// 不丢失精确分钟、预留身份和任务绑定。

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'calendar.dart';

/// 一个 15 分钟格包含的分钟数。
const int kTimetableSlotMinutes = 15;
const int kTimetableSlotsPerDay = 24 * 60 ~/ kTimetableSlotMinutes;
const int kTimetableMinutesPerDay = 24 * 60;

/// 格子状态。数值与用户给定的 0/1 编码一致。
enum TimetableState {
  occupied(0, '占用'),
  free(1, '空闲'),
  task(2, '任务');

  const TimetableState(this.code, this.label);

  final int code;
  final String label;

  static TimetableState? tryParse(Object? value) {
    if (value is TimetableState) return value;
    if (value is num && value == value.roundToDouble()) {
      for (final s in values) {
        if (s.code == value.toInt()) return s;
      }
    }
    return null;
  }

  static TimetableState fromCode(int code) => switch (code) {
        0 => TimetableState.occupied,
        1 => TimetableState.free,
        _ => TimetableState.task,
      };
}

/// 区间来源。模型不能自称 manual；入库时由程序赋值。
enum TimetableOrigin {
  defaultRule('default'),
  manual('manual'),
  model('model');

  const TimetableOrigin(this.wireName);

  final String wireName;

  static TimetableOrigin parse(Object? value) => switch ('$value') {
        'default' => TimetableOrigin.defaultRule,
        'model' => TimetableOrigin.model,
        _ => TimetableOrigin.manual,
      };
}

/// 一条规则：要么是每周规则（weekdays 非空、date 为空），要么是具体日期规则。
class TimetableEntry {
  final String id;
  final TimetableState state;
  final int start;
  final int end;

  /// yyyy-MM-dd；与 [weekdays] 二选一。
  final String? date;
  final List<int> weekdays;

  final TimetableOrigin origin;
  final String? title;

  /// 已绑定的真实任务 ID；只有 state=task 时允许非空。
  final String? taskId;

  /// 蓝色预留的稳定身份；绑定前后保持不变。未绑定时 taskId 为 null。
  final String? reservationId;

  const TimetableEntry({
    required this.id,
    required this.state,
    required this.start,
    required this.end,
    this.date,
    this.weekdays = const <int>[],
    this.origin = TimetableOrigin.manual,
    this.title,
    this.taskId,
    this.reservationId,
  });

  bool get isWeekly => date == null || date!.isEmpty;
  bool get isTask => state == TimetableState.task;

  int get minutes => end - start;

  bool coversMinute(int minute) => minute >= start && minute < end;

  bool overlaps(int from, int to) => start < to && from < end;

  TimetableEntry copyWith({
    String? id,
    TimetableState? state,
    int? start,
    int? end,
    String? date,
    bool clearDate = false,
    List<int>? weekdays,
    TimetableOrigin? origin,
    String? title,
    bool clearTitle = false,
    String? taskId,
    bool clearTaskId = false,
    String? reservationId,
    bool clearReservationId = false,
  }) =>
      TimetableEntry(
        id: id ?? this.id,
        state: state ?? this.state,
        start: start ?? this.start,
        end: end ?? this.end,
        date: clearDate ? null : (date ?? this.date),
        weekdays: weekdays ?? this.weekdays,
        origin: origin ?? this.origin,
        title: clearTitle ? null : (title ?? this.title),
        taskId: clearTaskId ? null : (taskId ?? this.taskId),
        reservationId:
            clearReservationId ? null : (reservationId ?? this.reservationId),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'state': state.code,
        'start': start,
        'end': end,
        'date': isWeekly ? null : date,
        'weekdays': isWeekly ? weekdays : const <int>[],
        'origin': origin.wireName,
        'title': title,
        'taskId': taskId,
        'reservationId': reservationId,
      };

  /// 严格解析：类型、整数、范围、星期和 state/taskId 一致性都检查。
  static TimetableEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final start = Timetable._intOf(j['start']);
    final end = Timetable._intOf(j['end']);
    if (start == null || end == null) return null;
    if (start < 0 || end <= start || end > kTimetableMinutesPerDay) return null;
    final state = TimetableState.tryParse(j['state']);
    if (state == null) return null;
    final date = (j['date'] as String?)?.trim();
    final weekdaysRaw = j['weekdays'];
    final weekdays = <int>[];
    if (weekdaysRaw is List) {
      for (final d in weekdaysRaw) {
        final day = Timetable._intOf(d);
        if (day == null || day < 1 || day > 7) return null;
        if (!weekdays.contains(day)) weekdays.add(day);
      }
    } else if (weekdaysRaw != null) {
      return null;
    }
    weekdays.sort();
    final hasDate = date != null && date.isNotEmpty;
    if (hasDate == weekdays.isNotEmpty) return null; // 必须二选一
    if (hasDate && parseDateKey(date) == null) return null;

    final origin = TimetableOrigin.parse(j['origin']);
    final taskId = (j['taskId'] as String?)?.trim();
    final reservationId = (j['reservationId'] as String?)?.trim();
    if (taskId != null && taskId.isNotEmpty && state != TimetableState.task) {
      return null;
    }
    final title = (j['title'] as String?)?.trim();
    final id = (j['id'] as String?)?.trim();

    return TimetableEntry(
      id: (id != null && id.isNotEmpty) ? id : timetableEntryId(
        state: state,
        start: start,
        end: end,
        date: hasDate ? date : null,
        weekdays: weekdays,
        title: title,
      ),
      state: state,
      start: start,
      end: end,
      date: hasDate ? date : null,
      weekdays: weekdays,
      origin: origin,
      title: (title == null || title.isEmpty) ? null : title,
      taskId: (taskId == null || taskId.isEmpty) ? null : taskId,
      reservationId: (reservationId == null || reservationId.isEmpty)
          ? null
          : reservationId,
    );
  }
}

/// 展开后的一段有效状态，用于渲染与排程。
class TimetableInterval {
  final TimetableState state;
  final int start;
  final int end;
  final TimetableOrigin origin;
  final String? title;
  final String? taskId;
  final String? reservationId;

  const TimetableInterval({
    required this.state,
    required this.start,
    required this.end,
    this.origin = TimetableOrigin.manual,
    this.title,
    this.taskId,
    this.reservationId,
  });

  int get minutes => end - start;

  bool get isPartialCell => start % kTimetableSlotMinutes != 0 ||
      end % kTimetableSlotMinutes != 0;

  bool overlaps(int from, int to) => start < to && from < end;

  @override
  String toString() => '${state.name} $start-$end';
}

/// 一天的展开结果。
class TimetableDay {
  final String date;
  final int weekday;
  final List<TimetableInterval> intervals;

  const TimetableDay({
    required this.date,
    required this.weekday,
    required this.intervals,
  });

  int get freeMinutes => intervals
      .where((i) => i.state == TimetableState.free)
      .fold<int>(0, (sum, i) => sum + i.minutes);

  /// 某分钟的状态；没有显式区间时返回 null（调用方决定默认值）。
  TimetableInterval? at(int minute) {
    for (final i in intervals) {
      if (minute >= i.start && minute < i.end) return i;
    }
    return null;
  }

  /// 一个格子被哪个状态覆盖得最多。部分覆盖时返回占优状态。
  TimetableState stateOfSlot(int slot) {
    final from = slot * kTimetableSlotMinutes;
    final to = from + kTimetableSlotMinutes;
    var best = TimetableState.free;
    var bestMinutes = -1;
    for (final state in TimetableState.values) {
      var total = 0;
      for (final i in intervals) {
        if (i.state != state) continue;
        final overlap =
            math.min<int>(to, i.end) - math.max<int>(from, i.start);
        if (overlap > 0) total += overlap;
      }
      if (total > bestMinutes) {
        best = state;
        bestMinutes = total;
      }
    }
    return best;
  }

  /// True when the 15-minute slot is not uniformly one state (09:05 之类).
  bool slotIsPartial(int slot) {
    final from = slot * kTimetableSlotMinutes;
    final to = from + kTimetableSlotMinutes;
    final states = <int>{};
    var covered = 0;
    for (final i in intervals) {
      final overlap =
          math.min<int>(to, i.end) - math.max<int>(from, i.start);
      if (overlap <= 0) continue;
      covered += overlap;
      states.add(i.state.code);
    }
    if (covered < kTimetableSlotMinutes) return true;
    return states.length > 1;
  }
}

/// 周时间表。不可变；编辑通过 [TimetableDraft]。
class Timetable {
  static const int schemaVersion = 2;

  final int revision;
  final String timezoneId;
  final int timezoneOffsetMinutes;
  final String dateFrom; // yyyy-MM-dd，包含
  final String dateTo; // yyyy-MM-dd，包含
  final int defaultState;
  final List<TimetableEntry> weekly;
  final List<TimetableEntry> dates;

  const Timetable({
    this.revision = 0,
    this.timezoneId = kDefaultTimezoneId,
    this.timezoneOffsetMinutes = kDefaultTimezoneOffsetMinutes,
    required this.dateFrom,
    required this.dateTo,
    this.defaultState = 1,
    this.weekly = const <TimetableEntry>[],
    this.dates = const <TimetableEntry>[],
  });

  bool get hasEntries => weekly.isNotEmpty || dates.isNotEmpty;

  List<TimetableEntry> get all => <TimetableEntry>[...weekly, ...dates];

  Timetable copyWith({
    int? revision,
    String? timezoneId,
    int? timezoneOffsetMinutes,
    String? dateFrom,
    String? dateTo,
    int? defaultState,
    List<TimetableEntry>? weekly,
    List<TimetableEntry>? dates,
  }) =>
      Timetable(
        revision: revision ?? this.revision,
        timezoneId: timezoneId ?? this.timezoneId,
        timezoneOffsetMinutes:
            timezoneOffsetMinutes ?? this.timezoneOffsetMinutes,
        dateFrom: dateFrom ?? this.dateFrom,
        dateTo: dateTo ?? this.dateTo,
        defaultState: defaultState ?? this.defaultState,
        weekly: weekly ?? this.weekly,
        dates: dates ?? this.dates,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'revision': revision,
        'timezoneId': timezoneId,
        'timezoneOffsetMinutes': timezoneOffsetMinutes,
        'coverage': <String, dynamic>{
          'dateFrom': dateFrom,
          'dateTo': dateTo,
          'defaultState': defaultState,
        },
        'weekly': weekly.map((e) => e.toJson()).toList(growable: false),
        'dates': dates.map((e) => e.toJson()).toList(growable: false),
      };

  /// 宽松但严格的读取：任何一条不合法都整体返回 null，避免半份时间表被当成完整数据。
  static Timetable? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final version = _intOf(j['schemaVersion']);
    if (version != schemaVersion) return null;
    final coverage = j['coverage'];
    if (coverage is! Map) return null;
    final dateFrom = parseDateKey('${coverage['dateFrom'] ?? ''}');
    final dateTo = parseDateKey('${coverage['dateTo'] ?? ''}');
    if (dateFrom == null || dateTo == null) return null;
    if (dateTo.compareTo(dateFrom) < 0) return null;
    final defaultState = _intOf(coverage['defaultState']) ?? 1;
    if (defaultState < 0 || defaultState > 2) return null;

    List<TimetableEntry> parseList(Object? value) {
      if (value == null) return const <TimetableEntry>[];
      if (value is! List) throw const FormatException('规则必须是数组');
      final out = <TimetableEntry>[];
      for (final item in value) {
        final entry = TimetableEntry.tryParse(item);
        if (entry == null) throw const FormatException('时间表规则不合法');
        out.add(entry);
      }
      return List<TimetableEntry>.unmodifiable(out);
    }

    try {
      final weekly = parseList(j['weekly']);
      final dates = parseList(j['dates']);
      final timetable = Timetable(
        revision: _intOf(j['revision']) ?? 0,
        timezoneId: (j['timezoneId'] as String?)?.trim().isNotEmpty == true
            ? (j['timezoneId'] as String).trim()
            : kDefaultTimezoneId,
        timezoneOffsetMinutes: _intOf(j['timezoneOffsetMinutes']) ??
            kDefaultTimezoneOffsetMinutes,
        dateFrom: dateFrom,
        dateTo: dateTo,
        defaultState: defaultState,
        weekly: weekly,
        dates: dates,
      );
      if (!timetable.isConsistent) return null;
      return timetable;
    } on FormatException {
      return null;
    }
  }

  /// 同一层里同一个星期/日期上的有效区间不得互相重叠。
  bool get isConsistent {
    for (var day = 1; day <= 7; day++) {
      if (_hasOverlap(weekly.where((e) => e.weekdays.contains(day)))) {
        return false;
      }
    }
    final byDate = <String, List<TimetableEntry>>{};
    for (final e in dates) {
      byDate.putIfAbsent(e.date!, () => <TimetableEntry>[]).add(e);
    }
    for (final list in byDate.values) {
      if (_hasOverlap(list)) return false;
    }
    return true;
  }

  static bool _hasOverlap(Iterable<TimetableEntry> entries) {
    final sorted = entries.toList()..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].start < sorted[i - 1].end) return true;
    }
    return false;
  }

  /// 一周 7 天的展开结果，按 [weekStart] 起连续 7 天。
  List<TimetableDay> weekDays({required String weekStart}) {
    final start = parseDateKey(weekStart);
    if (start == null) return const <TimetableDay>[];
    final base = _dateOf(start);
    final out = <TimetableDay>[];
    for (var i = 0; i < 7; i++) {
      final date = base.add(Duration(days: i));
      final key = WallClock.formatDateKey(date.year, date.month, date.day);
      out.add(day(key, date.weekday));
    }
    return out;
  }

  TimetableDay day(String date, int weekday) => TimetableDay(
        date: date,
        weekday: weekday,
        intervals: dayIntervals(date, weekday),
      );

  /// 展开某一天：默认状态 → 周规则 → 具体日期规则（后者覆盖前者）。
  List<TimetableInterval> dayIntervals(String date, int weekday) {
    var layers = <TimetableInterval>[
      TimetableInterval(
        state: TimetableState.fromCode(defaultState),
        start: 0,
        end: kTimetableMinutesPerDay,
        origin: TimetableOrigin.defaultRule,
        title: '默认',
      ),
    ];
    for (final e in weekly) {
      if (!e.weekdays.contains(weekday)) continue;
      layers = _overlay(layers, e);
    }
    for (final e in dates) {
      if (e.date != date) continue;
      layers = _overlay(layers, e);
    }
    return _coalesce(layers);
  }

  /// 版本继承：删除已不存在的任务对应的蓝色绑定，其他规则原样保留。
  Timetable inheritedBy(Set<String> liveTaskIds) => copyWith(
        dates: dates
            .where((e) =>
                !e.isTask ||
                e.taskId == null ||
                e.taskId!.isEmpty ||
                liveTaskIds.contains(e.taskId))
            .toList(growable: false),
      );

  /// 某分钟的有效状态。
  TimetableState stateAt(String date, int weekday, int minute) {
    final intervals = dayIntervals(date, weekday);
    for (final i in intervals) {
      if (minute >= i.start && minute < i.end) return i.state;
    }
    return TimetableState.fromCode(defaultState);
  }

  /// 所有已绑定/未绑定的任务区间（只来自具体日期）。
  List<TimetableEntry> get taskEntries =>
      dates.where((e) => e.isTask).toList(growable: false);

  /// True when the date has any explicit override.
  bool hasDateOverride(String date) => dates.any((e) => e.date == date);

  /// 把一条区间画进周模板或具体日期，保留整分钟。
  ///
  /// [date] 与 [weekday] 二选一：给 date 表示覆盖那一天；给 weekday 表示改周模板。
  Timetable paint({
    String? date,
    int? weekday,
    required int start,
    required int end,
    required TimetableState state,
    TimetableOrigin origin = TimetableOrigin.manual,
    String? title,
    String? taskId,
    String? reservationId,
  }) {
    if (start < 0 || end <= start || end > kTimetableMinutesPerDay) return this;
    if (date == null && (weekday == null || weekday < 1 || weekday > 7)) {
      return this;
    }
    final isDate = date != null;
    final list = isDate ? dates : weekly;
    final kept = <TimetableEntry>[];
    for (final e in list) {
      final matches =
          isDate ? e.date == date : e.weekdays.contains(weekday);
      if (!matches || !e.overlaps(start, end)) {
        kept.add(e);
        continue;
      }
      if (e.start < start) {
        kept.add(e.copyWith(id: '${e.id}-a', end: start));
      }
      if (e.end > end) {
        kept.add(e.copyWith(id: '${e.id}-b', start: end));
      }
    }
    kept.add(TimetableEntry(
      id: timetableEntryId(
        state: state,
        start: start,
        end: end,
        date: isDate ? date : null,
        weekdays: isDate ? const <int>[] : <int>[weekday!],
        title: title,
      ),
      state: state,
      start: start,
      end: end,
      date: isDate ? date : null,
      weekdays: isDate ? const <int>[] : <int>[weekday!],
      origin: origin,
      title: title,
      taskId: state == TimetableState.task ? taskId : null,
      reservationId:
          state == TimetableState.task ? reservationId : null,
    ));
    final sorted = isDate ? _normalizeLayer(kept) : _normalizeWeekly(kept);
    return isDate
        ? copyWith(dates: sorted)
        : copyWith(weekly: sorted);
  }

  /// 按格子（15 分钟）绘制；连续格子会合并成一条整分钟区间。
  Timetable paintSlots({
    String? date,
    int? weekday,
    required Iterable<int> slots,
    required TimetableState state,
    TimetableOrigin origin = TimetableOrigin.manual,
    String? title,
    String? taskId,
    String? reservationId,
  }) {
    final sorted = slots.where((s) => s >= 0 && s < kTimetableSlotsPerDay).toSet().toList()
      ..sort();
    if (sorted.isEmpty) return this;
    var next = this;
    var runStart = sorted.first;
    var previous = sorted.first;
    for (final slot in sorted.skip(1)) {
      if (slot != previous + 1) {
        next = next.paint(
          date: date,
          weekday: weekday,
          start: runStart * kTimetableSlotMinutes,
          end: (previous + 1) * kTimetableSlotMinutes,
          state: state,
          origin: origin,
          title: title,
          taskId: taskId,
          reservationId: reservationId,
        );
        runStart = slot;
      }
      previous = slot;
    }
    return next.paint(
      date: date,
      weekday: weekday,
      start: runStart * kTimetableSlotMinutes,
      end: (previous + 1) * kTimetableSlotMinutes,
      state: state,
      origin: origin,
      title: title,
      taskId: taskId,
      reservationId: reservationId,
    );
  }

  /// 删除某天/某星期的整段覆盖，恢复为下层规则。
  Timetable erase({
    String? date,
    int? weekday,
    required int start,
    required int end,
  }) {
    if (start < 0 || end <= start || end > kTimetableMinutesPerDay) return this;
    final isDate = date != null;
    final list = isDate ? dates : weekly;
    final kept = <TimetableEntry>[];
    for (final e in list) {
      final matches =
          isDate ? e.date == date : e.weekdays.contains(weekday);
      if (!matches || !e.overlaps(start, end)) {
        kept.add(e);
        continue;
      }
      if (e.start < start) kept.add(e.copyWith(id: '${e.id}-a', end: start));
      if (e.end > end) kept.add(e.copyWith(id: '${e.id}-b', start: end));
    }
    return isDate
        ? copyWith(dates: _normalizeLayer(kept))
        : copyWith(weekly: _normalizeWeekly(kept));
  }

  /// 新会话的默认时间表：非占用区间为白格，默认占用见 [unavailable]。
  factory Timetable.withDefaults({
    required String weekStart,
    int timezoneOffsetMinutes = kDefaultTimezoneOffsetMinutes,
    String timezoneId = kDefaultTimezoneId,
    List<WallClockRange> unavailable = kDefaultUnavailableRanges,
    int revision = 0,
  }) {
    final weekly = <TimetableEntry>[];
    for (final range in unavailable) {
      for (final split in _splitDayRange(range)) {
        weekly.add(TimetableEntry(
          id: timetableEntryId(
            state: TimetableState.occupied,
            start: split.startMinute,
            end: split.endMinute,
            weekdays: const <int>[1, 2, 3, 4, 5, 6, 7],
            title: '默认不可用',
          ),
          state: TimetableState.occupied,
          start: split.startMinute,
          end: split.endMinute,
          weekdays: const <int>[1, 2, 3, 4, 5, 6, 7],
          origin: TimetableOrigin.defaultRule,
          title: '默认不可用',
        ));
      }
    }
    final start = parseDateKey(weekStart) ?? '1970-01-05';
    final end = _addDays(start, 6);
    return Timetable(
      revision: revision,
      timezoneId: timezoneId,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
      dateFrom: start,
      dateTo: end,
      defaultState: TimetableState.free.code,
      weekly: _normalizeWeekly(weekly),
    );
  }

  /// 从旧版 CalendarSchedule 迁移：显式空可用范围保持为空，不变成全天可用。
  factory Timetable.fromSchedule(
    CalendarSchedule schedule, {
    required String weekStart,
  }) {
    final settings = schedule.settings;
    final clock = settings.clock;
    final weekly = <TimetableEntry>[];
    for (var day = 1; day <= 7; day++) {
      for (final r in settings.weekly.forWeekday(day)) {
        for (final split in _splitDayRange(r)) {
          weekly.add(TimetableEntry(
            id: timetableEntryId(
              state: TimetableState.free,
              start: split.startMinute,
              end: split.endMinute,
              weekdays: <int>[day],
              title: '每周可用',
            ),
            state: TimetableState.free,
            start: split.startMinute,
            end: split.endMinute,
            weekdays: <int>[day],
            origin: TimetableOrigin.manual,
            title: '每周可用',
          ));
        }
      }
    }
    for (final o in settings.occupancies) {
      for (final r in o.ranges) {
        for (final split in _splitDayRange(r)) {
          weekly.add(TimetableEntry(
            id: timetableEntryId(
              state: TimetableState.occupied,
              start: split.startMinute,
              end: split.endMinute,
              date: o.isWeekly ? null : o.date,
              weekdays: o.isWeekly ? <int>[o.weekday] : const <int>[],
              title: o.title,
            ),
            state: TimetableState.occupied,
            start: split.startMinute,
            end: split.endMinute,
            date: o.isWeekly ? null : o.date,
            weekdays: o.isWeekly ? <int>[o.weekday] : const <int>[],
            origin: TimetableOrigin.manual,
            title: o.title,
          ));
        }
      }
    }
    final dates = <TimetableEntry>[];
    for (final e in settings.exceptions) {
      if (e.closed) {
        dates.add(TimetableEntry(
          id: timetableEntryId(
            state: TimetableState.occupied,
            start: 0,
            end: kTimetableMinutesPerDay,
            date: e.date,
            title: '日期例外',
          ),
          state: TimetableState.occupied,
          start: 0,
          end: kTimetableMinutesPerDay,
          date: e.date,
          origin: TimetableOrigin.manual,
          title: '日期例外',
        ));
      } else {
        for (final r in e.ranges) {
          for (final split in _splitDayRange(r)) {
            dates.add(TimetableEntry(
              id: timetableEntryId(
                state: TimetableState.free,
                start: split.startMinute,
                end: split.endMinute,
                date: e.date,
                title: '日期可用',
              ),
              state: TimetableState.free,
              start: split.startMinute,
              end: split.endMinute,
              date: e.date,
              origin: TimetableOrigin.manual,
              title: '日期可用',
            ));
          }
        }
      }
    }
    for (final s in schedule.segments) {
      final wall = clock.toWall(s.start);
      final endWall = clock.toWall(s.end);
      final date = WallClock.formatDateKey(wall.year, wall.month, wall.day);
      final startMinute = wall.hour * 60 + wall.minute;
      final endMinute = endWall.hour * 60 + endWall.minute;
      final sameDay = wall.year == endWall.year &&
          wall.month == endWall.month &&
          wall.day == endWall.day;
      if (sameDay && endMinute > startMinute) {
        dates.add(TimetableEntry(
          id: s.id,
          state: TimetableState.task,
          start: startMinute,
          end: endMinute,
          date: date,
          origin: s.source == SegmentSource.auto
              ? TimetableOrigin.manual
              : TimetableOrigin.manual,
          title: s.tentative ? '暂定安排' : '任务安排',
          taskId: s.taskId.isEmpty ? null : s.taskId,
          reservationId: s.id,
        ));
      }
    }
    final start = parseDateKey(weekStart) ?? '1970-01-05';
    return Timetable(
      revision: schedule.segments.isEmpty ? 0 : 1,
      timezoneId: settings.timezoneId,
      timezoneOffsetMinutes: settings.timezoneOffsetMinutes,
      dateFrom: start,
      dateTo: _addDays(start, 6),
      defaultState: TimetableState.occupied.code,
      weekly: _normalizeWeekly(weekly),
      dates: _normalizeDates(dates),
    );
  }

  /// 转回排程器使用的 CalendarSettings：周可用范围与日期例外由时间表推导。
  ///
  /// [base] 提供时区、规划范围、吸附步长和原占用名称；被擦除的占用不会再回来。
  CalendarSettings toCalendarSettings(CalendarSettings base,
      {Set<String>? boundReservationIds}) {
    final weeklyMap = <int, List<WallClockRange>>{};
    for (var day = 1; day <= 7; day++) {
      final ranges = _freeRangesForWeekday(day);
      if (ranges.isNotEmpty) weeklyMap[day] = ranges;
    }

    final exceptions = <CalendarDateException>[];
    final seenDates = <String>{};
    for (final entry in dates) {
      final date = entry.date;
      if (date == null || !seenDates.add(date)) continue;
      final free = _freeRangesForDate(date);
      exceptions.add(CalendarDateException(
        date: date,
        closed: free.isEmpty,
        ranges: free,
        note: entry.title,
      ));
    }

    final occupancies = <CalendarOccupancy>[];
    for (final o in base.occupancies) {
      if (_occupancyStillPresent(o)) occupancies.add(o);
    }
    for (final entry in dates) {
      if (entry.state != TimetableState.task) continue;
      if (entry.taskId != null && entry.taskId!.isNotEmpty) continue;
      occupancies.add(CalendarOccupancy(
        id: entry.reservationId ?? entry.id,
        title: (entry.title == null || entry.title!.isEmpty)
            ? '任务预留'
            : entry.title!,
        kind: 'activity',
        date: entry.date,
        ranges: <WallClockRange>[WallClockRange(entry.start, entry.end)],
        provisional: false,
      ));
    }

    return base.copyWith(
      timezoneId: timezoneId,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
      weekly: WeeklyAvailability(weeklyMap),
      exceptions: exceptions,
      occupancies: occupancies,
    );
  }

  /// 已绑定的蓝色区间对应的排程片段；auto 片段由调用方原样保留。
  List<ScheduleSegment> taskSegments(WallClock clock) {
    final out = <ScheduleSegment>[];
    for (final entry in dates) {
      if (entry.state != TimetableState.task) continue;
      final taskId = entry.taskId;
      if (taskId == null || taskId.isEmpty) continue;
      final dayStart = clock.dayStartUtcForDateKey(entry.date!);
      out.add(ScheduleSegment(
        id: entry.reservationId ?? entry.id,
        taskId: taskId,
        start: dayStart.add(Duration(minutes: entry.start)),
        end: dayStart.add(Duration(minutes: entry.end)),
        source: SegmentSource.manual,
      ));
    }
    return out;
  }

  /// 任务区间总分钟数按任务聚合；未绑定预留只占容量，不计入任何任务。
  Map<String, int> boundMinutesByTask() {
    final out = <String, int>{};
    for (final entry in taskEntries) {
      final taskId = entry.taskId;
      if (taskId == null || taskId.isEmpty) continue;
      out[taskId] = (out[taskId] ?? 0) + entry.minutes;
    }
    return out;
  }

  int get freeMinutesPerWeek {
    var total = 0;
    for (var day = 1; day <= 7; day++) {
      for (final r in _freeRangesForWeekday(day)) {
        total += r.durationMinutes;
      }
    }
    return total;
  }

  /// 某个星期的默认可用分钟数（不含具体日期覆盖）。
  int dailyFreeMinutes(int weekday) => _freeRangesForWeekday(weekday)
      .fold<int>(0, (sum, r) => sum + r.durationMinutes);

  bool _occupancyStillPresent(CalendarOccupancy o) {
    final ranges = o.isWeekly
        ? weekly.where((e) => e.weekdays.contains(o.weekday))
        : dates.where((e) => e.date == o.date);
    final occupied = ranges.where((e) => e.state == TimetableState.occupied);
    return o.ranges.every((want) => occupied.any(
        (e) => e.start <= want.startMinute && e.end >= want.endMinute));
  }

  List<WallClockRange> _freeRangesForWeekday(int weekday) {
    final day = dayIntervals('0000-00-00', weekday)
        .where(_countsAsCapacity)
        .map((i) => WallClockRange(i.start, i.end))
        .toList(growable: false);
    return _mergeRanges(day);
  }

  List<WallClockRange> _freeRangesForDate(String date) {
    final parsed = parseDateKey(date);
    if (parsed == null) return const <WallClockRange>[];
    final weekday = _dateOf(parsed).weekday;
    final day = dayIntervals(date, weekday)
        .where(_countsAsCapacity)
        .map((i) => WallClockRange(i.start, i.end))
        .toList(growable: false);
    return _mergeRanges(day);
  }

  /// 已绑定的任务区间仍然算“可用容量”（它会被对应片段占住），未绑定的蓝色
  /// 预留不进入可用范围，从而只扣容量、不算任何任务工时。
  static bool _countsAsCapacity(TimetableInterval i) =>
      i.state == TimetableState.free ||
      (i.state == TimetableState.task &&
          i.taskId != null &&
          i.taskId!.isNotEmpty);

  static List<WallClockRange> _mergeRanges(List<WallClockRange> input) {
    if (input.isEmpty) return const <WallClockRange>[];
    final sorted = <WallClockRange>[...input]
      ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
    final out = <WallClockRange>[sorted.first];
    for (final r in sorted.skip(1)) {
      final last = out.last;
      if (r.startMinute <= last.endMinute) {
        if (r.endMinute > last.endMinute) {
          out[out.length - 1] = WallClockRange(last.startMinute, r.endMinute);
        }
      } else {
        out.add(r);
      }
    }
    return out;
  }

  static List<TimetableInterval> _overlay(
      List<TimetableInterval> layers, TimetableEntry e) {
    final out = <TimetableInterval>[];
    for (final i in layers) {
      if (i.end <= e.start || i.start >= e.end) {
        out.add(i);
        continue;
      }
      if (i.start < e.start) {
        out.add(TimetableInterval(
          state: i.state,
          start: i.start,
          end: e.start,
          origin: i.origin,
          title: i.title,
          taskId: i.taskId,
          reservationId: i.reservationId,
        ));
      }
      if (i.end > e.end) {
        out.add(TimetableInterval(
          state: i.state,
          start: e.end,
          end: i.end,
          origin: i.origin,
          title: i.title,
          taskId: i.taskId,
          reservationId: i.reservationId,
        ));
      }
    }
    out.add(TimetableInterval(
      state: e.state,
      start: e.start,
      end: e.end,
      origin: e.origin,
      title: e.title,
      taskId: e.taskId,
      reservationId: e.reservationId,
    ));
    return out;
  }

  static List<TimetableInterval> _coalesce(List<TimetableInterval> input) {
    final sorted = <TimetableInterval>[...input]
      ..sort((a, b) => a.start.compareTo(b.start));
    final out = <TimetableInterval>[];
    for (final i in sorted) {
      if (i.end <= i.start) continue;
      if (out.isNotEmpty) {
        final last = out.last;
        if (last.end == i.start &&
            last.state == i.state &&
            last.title == i.title &&
            last.taskId == i.taskId &&
            last.reservationId == i.reservationId) {
          out[out.length - 1] = TimetableInterval(
            state: last.state,
            start: last.start,
            end: i.end,
            origin: last.origin,
            title: last.title,
            taskId: last.taskId,
            reservationId: last.reservationId,
          );
          continue;
        }
      }
      out.add(i);
    }
    return out;
  }

  /// 周规则按“每个星期各自成层”规范化：不同星期的相同时间不是冲突。
  static List<TimetableEntry> _normalizeWeekly(List<TimetableEntry> input) {
    final perDay = <int, List<TimetableEntry>>{};
    for (final e in input) {
      for (final day in e.weekdays) {
        perDay.putIfAbsent(day, () => <TimetableEntry>[]).add(
          e.copyWith(id: '${e.id}-d$day', weekdays: <int>[day]),
        );
      }
    }
    final normalized = <TimetableEntry>[];
    for (var day = 1; day <= 7; day++) {
      normalized.addAll(_normalizeLayer(perDay[day] ?? const <TimetableEntry>[]));
    }
    // 把完全相同的规则重新合并成多星期条目，避免请求体积膨胀。
    final groups = <String, List<TimetableEntry>>{};
    for (final e in normalized) {
      final key = <String>[
        '${e.state.code}',
        '${e.start}',
        '${e.end}',
        e.origin.wireName,
        e.title ?? '',
        e.taskId ?? '',
        e.reservationId ?? '',
      ].join('|');
      groups.putIfAbsent(key, () => <TimetableEntry>[]).add(e);
    }
    final out = <TimetableEntry>[];
    for (final list in groups.values) {
      final days = list
          .expand((e) => e.weekdays)
          .toSet()
          .toList()
        ..sort();
      final base = list.first;
      out.add(base.copyWith(
        id: timetableEntryId(
          state: base.state,
          start: base.start,
          end: base.end,
          weekdays: days,
          title: base.title,
        ),
        weekdays: days,
      ));
    }
    out.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byDay = a.weekdays.first.compareTo(b.weekdays.first);
      return byDay != 0 ? byDay : a.end.compareTo(b.end);
    });
    return List<TimetableEntry>.unmodifiable(out);
  }

  static List<TimetableEntry> _normalizeLayer(List<TimetableEntry> input) {
    final sorted = <TimetableEntry>[...input]
      ..sort((a, b) {
        final byStart = a.start.compareTo(b.start);
        return byStart != 0 ? byStart : a.end.compareTo(b.end);
      });
    final out = <TimetableEntry>[];
    for (final e in sorted) {
      // 后出现的一条覆盖先出现的：保留它左右两侧的旧区间。
      final kept = <TimetableEntry>[];
      for (final current in out) {
        if (current.end <= e.start || current.start >= e.end) {
          kept.add(current);
          continue;
        }
        if (current.start < e.start) {
          kept.add(current.copyWith(id: '${current.id}-a', end: e.start));
        }
        if (current.end > e.end) {
          kept.add(current.copyWith(id: '${current.id}-b', start: e.end));
        }
      }
      kept.add(e);
      out
        ..clear()
        ..addAll(kept);
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    final merged = <TimetableEntry>[];
    for (final e in out) {
      if (merged.isNotEmpty) {
        final last = merged.last;
        if (last.end == e.start &&
            last.state == e.state &&
            last.title == e.title &&
            last.taskId == e.taskId &&
            last.reservationId == e.reservationId &&
            last.origin == e.origin &&
            _sameWeekdays(last.weekdays, e.weekdays)) {
          merged[merged.length - 1] = last.copyWith(end: e.end);
          continue;
        }
      }
      merged.add(e);
    }
    return List<TimetableEntry>.unmodifiable(merged);
  }

  static List<TimetableEntry> _normalizeDates(List<TimetableEntry> input) {
    final byDate = <String, List<TimetableEntry>>{};
    for (final e in input) {
      byDate.putIfAbsent(e.date!, () => <TimetableEntry>[]).add(e);
    }
    final out = <TimetableEntry>[];
    for (final list in byDate.values) {
      out.addAll(_normalizeLayer(list));
    }
    out.sort((a, b) {
      final byDate = (a.date ?? '').compareTo(b.date ?? '');
      if (byDate != 0) return byDate;
      return a.start.compareTo(b.start);
    });
    return List<TimetableEntry>.unmodifiable(out);
  }

  static bool _sameWeekdays(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<WallClockRange> _splitDayRange(WallClockRange r) {
    if (!r.isValid) return const <WallClockRange>[];
    if (r.endMinute <= kTimetableMinutesPerDay) {
      return <WallClockRange>[r];
    }
    final out = <WallClockRange>[
      WallClockRange(r.startMinute, kTimetableMinutesPerDay),
    ];
    final overflow = r.endMinute - kTimetableMinutesPerDay;
    if (overflow > 0) out.add(WallClockRange(0, overflow));
    return out;
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is double && value == value.roundToDouble()) return value.toInt();
    return null;
  }

  static DateTime _dateOf(String dateKey) {
    final parts = dateKey.split('-');
    return DateTime.utc(int.parse(parts[0]), int.parse(parts[1]),
        int.parse(parts[2]));
  }

  static String _addDays(String dateKey, int days) {
    final d = _dateOf(dateKey).add(Duration(days: days));
    return WallClock.formatDateKey(d.year, d.month, d.day);
  }
}

/// 旧版设置里“默认不可用”的示例值（占 720 分钟/天）。
const List<WallClockRange> kDefaultUnavailableRanges = <WallClockRange>[
  WallClockRange(0, 480),
  WallClockRange(720, 840),
  WallClockRange(1080, 1140),
  WallClockRange(1380, 1440),
];

/// 内容派生的稳定 ID：同样的状态/范围得到同样的 ID，便于去重与测试。
String timetableEntryId({
  required TimetableState state,
  required int start,
  required int end,
  String? date,
  Iterable<int> weekdays = const <int>[],
  String? title,
}) {
  final days = weekdays.toSet().toList()..sort();
  final canonical = <String>[
    'tt',
    '${state.code}',
    '$start',
    '$end',
    (date ?? '').trim(),
    days.join('+'),
    (title ?? '').trim(),
  ].join('|');
  final digest = sha1.convert(utf8.encode(canonical)).toString();
  return 'tt-${digest.substring(0, 12)}';
}

/// 计算某一周的第一天（按 [weekStartsOn] 1=周一…7=周日）。
String weekStartFor(String dateKey, int weekStartsOn) {
  final parsed = parseDateKey(dateKey);
  if (parsed == null) return dateKey;
  final date = DateTime.utc(
    int.parse(parsed.substring(0, 4)),
    int.parse(parsed.substring(5, 7)),
    int.parse(parsed.substring(8, 10)),
  );
  final startOn = weekStartsOn >= 1 && weekStartsOn <= 7 ? weekStartsOn : 1;
  final delta = (date.weekday - startOn + 7) % 7;
  final start = date.subtract(Duration(days: delta));
  return WallClock.formatDateKey(start.year, start.month, start.day);
}

String addDaysToDateKey(String dateKey, int days) {
  final parsed = parseDateKey(dateKey);
  if (parsed == null) return dateKey;
  final date = DateTime.utc(
    int.parse(parsed.substring(0, 4)),
    int.parse(parsed.substring(5, 7)),
    int.parse(parsed.substring(8, 10)),
  ).add(Duration(days: days));
  return WallClock.formatDateKey(date.year, date.month, date.day);
}

int weekdayOfDateKey(String dateKey) {
  final parsed = parseDateKey(dateKey);
  if (parsed == null) return 1;
  return DateTime.utc(
    int.parse(parsed.substring(0, 4)),
    int.parse(parsed.substring(5, 7)),
    int.parse(parsed.substring(8, 10)),
  ).weekday;
}

/// 时间表无法作为请求发送时的明确原因（不是静默丢弃）。
class TimetableRequestException implements Exception {
  const TimetableRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把权威规则展开为“同一不可变快照”的按天有效区间。
///
/// 这是请求里的派生视图：`timetable` 仍是唯一权威规则，本视图只是用
/// [Timetable.dayIntervals] 逐天展开，便于模型看到 coverage → weekly → dates 的
/// 覆盖结果。任何不一致（同层重叠、日期反向、区间不连续、状态越界）都抛出
/// [TimetableRequestException]，由调用方中止发送，而不是让模型猜。
///
/// 区间按时间排序、不重叠并完整覆盖当天 [0,1440)；数值 0（占用）原样保留。
Map<String, dynamic> deriveEffectiveTimetable(Timetable snapshot) {
  if (!snapshot.isConsistent) {
    throw const TimetableRequestException('时间表同一层区间重叠');
  }
  if (snapshot.revision < 0) {
    throw const TimetableRequestException('时间表 revision 不合法');
  }
  if (snapshot.timezoneId.trim().isEmpty) {
    throw const TimetableRequestException('时间表缺少时区名');
  }
  if (snapshot.timezoneOffsetMinutes < -1440 ||
      snapshot.timezoneOffsetMinutes > 1440) {
    throw const TimetableRequestException('时间表时区偏移不合法');
  }
  if (snapshot.defaultState < 0 || snapshot.defaultState > 2) {
    throw const TimetableRequestException('时间表默认状态不合法');
  }
  final fromKey = parseDateKey(snapshot.dateFrom);
  final toKey = parseDateKey(snapshot.dateTo);
  if (fromKey == null || toKey == null) {
    throw const TimetableRequestException('时间表日期范围不是 yyyy-MM-dd');
  }
  final first = DateTime.utc(int.parse(fromKey.substring(0, 4)),
      int.parse(fromKey.substring(5, 7)), int.parse(fromKey.substring(8)));
  final last = DateTime.utc(int.parse(toKey.substring(0, 4)),
      int.parse(toKey.substring(5, 7)), int.parse(toKey.substring(8)));
  if (last.isBefore(first)) {
    throw const TimetableRequestException('时间表日期范围反向');
  }
  final dayCount = last.difference(first).inDays + 1;
  if (dayCount > 400) {
    // 不静默缩小用户排程范围：明确拒绝，让用户改小覆盖范围。
    throw const TimetableRequestException('时间表覆盖范围超过 400 天，未发送');
  }
  final days = <Map<String, dynamic>>[];
  for (var offset = 0; offset < dayCount; offset++) {
    final day = first.add(Duration(days: offset));
    final key = WallClock.formatDateKey(day.year, day.month, day.day);
    final intervals = snapshot.dayIntervals(key, day.weekday);
    var cursor = 0;
    final encoded = <Map<String, dynamic>>[];
    for (final interval in intervals) {
      if (interval.start != cursor || interval.end <= interval.start) {
        throw TimetableRequestException('$key 的有效区间不连续或重叠');
      }
      if (interval.end > kTimetableMinutesPerDay) {
        throw TimetableRequestException('$key 的有效区间超过 24:00');
      }
      cursor = interval.end;
      encoded.add(<String, dynamic>{
        'start': interval.start,
        'end': interval.end,
        'state': interval.state.code,
        'meaning': switch (interval.state) {
          TimetableState.occupied => 'occupied',
          TimetableState.free => 'free',
          TimetableState.task => 'task_reserved',
        },
        if (interval.state == TimetableState.task &&
            interval.taskId != null &&
            interval.taskId!.isNotEmpty)
          'taskId': interval.taskId,
      });
    }
    if (cursor != kTimetableMinutesPerDay) {
      throw TimetableRequestException('$key 的有效区间未覆盖到 24:00');
    }
    days.add(<String, dynamic>{'date': key, 'intervals': encoded});
  }
  return <String, dynamic>{
    'sourceRevision': snapshot.revision,
    'timezoneId': snapshot.timezoneId,
    'timezoneOffsetMinutes': snapshot.timezoneOffsetMinutes,
    'dateFrom': snapshot.dateFrom,
    'dateTo': snapshot.dateTo,
    'intervalSemantics': '[start,end), minutes since local midnight',
    'days': days,
  };
}

/// 编辑草稿：一次按下到抬起是一个撤销事务；重复经过同格不产生多条历史。
class TimetableDraft {
  Timetable _timetable;
  final List<Timetable> _undo = <Timetable>[];
  Timetable? _strokeBase;

  TimetableDraft(this._timetable);

  Timetable get timetable => _timetable;
  bool get hasUndo => _undo.isNotEmpty || _strokeBase != null;
  int get undoDepth => _undo.length;

  void beginStroke() {
    if (_strokeBase != null) return;
    _strokeBase = _timetable;
  }

  /// 把当前周表替换掉（例如切换“每周重复”或导航后重建），不进入撤销栈。
  void reset(Timetable next) {
    _strokeBase = null;
    _undo.clear();
    _timetable = next;
  }

  void paintSlots({
    String? date,
    int? weekday,
    required Iterable<int> slots,
    required TimetableState state,
    TimetableOrigin origin = TimetableOrigin.manual,
    String? title,
    String? taskId,
    String? reservationId,
  }) {
    if (_strokeBase == null) beginStroke();
    _timetable = _timetable.paintSlots(
      date: date,
      weekday: weekday,
      slots: slots,
      state: state,
      origin: origin,
      title: title,
      taskId: taskId,
      reservationId: reservationId,
    );
  }

  void eraseSlots({String? date, int? weekday, required Iterable<int> slots}) {
    if (_strokeBase == null) beginStroke();
    // 右键的语义是“恢复可用”，不是“删掉覆盖后让下层灰块回来”。
    // 因此显式写一条 free 规则；这样默认休息格被擦除后重启仍是白的。
    for (final slot in slots) {
      _timetable = _timetable.paint(
        date: date,
        weekday: weekday,
        start: slot * kTimetableSlotMinutes,
        end: (slot + 1) * kTimetableSlotMinutes,
        state: TimetableState.free,
        origin: TimetableOrigin.manual,
        title: '手动可用',
      );
    }
  }

  void endStroke() {
    final before = _strokeBase;
    _strokeBase = null;
    if (before == null) return;
    if (!_sameTimetable(before, _timetable)) {
      _undo.add(before);
      if (_undo.length > 100) _undo.removeAt(0);
    }
  }

  void cancelStroke() {
    final before = _strokeBase;
    _strokeBase = null;
    if (before != null) _timetable = before;
  }

  bool undo() {
    if (_strokeBase != null) {
      cancelStroke();
      return true;
    }
    if (_undo.isEmpty) return false;
    _timetable = _undo.removeLast();
    return true;
  }

  /// 只有提交成功后才调用：已提交状态成为新的撤销基线。
  void markApplied() {
    _strokeBase = null;
    _undo.clear();
  }

  static bool _sameTimetable(Timetable a, Timetable b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());
}
