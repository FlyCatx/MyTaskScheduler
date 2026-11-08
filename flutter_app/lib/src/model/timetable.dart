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
import 'timetable_transactions.dart';

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
  model('model'),

  /// 外部日历忙碌（只读）。
  ///
  /// 只出现在「运行时合成时间表」里（见 state/timetable_composition.dart）：
  /// 合成结果**绝不落盘**，手工时间表（session/version.timetable）里永远没有
  /// 该来源。C 侧只校验 origin 是字符串，因此新增枚举值不改变协议。
  external('external'),

  /// 本地全局日程忙碌（只读，运行时合成）。
  ///
  /// 与 [external] 一样只出现在运行时合成时间表里，绝不写回手工时间表/版本；
  /// 与外部日历区分是为了冲突解释与隐私边界（日程标题不进请求）。
  schedule('schedule');

  const TimetableOrigin(this.wireName);

  final String wireName;

  static TimetableOrigin parse(Object? value) => switch ('$value') {
        'default' => TimetableOrigin.defaultRule,
        'model' => TimetableOrigin.model,
        'external' => TimetableOrigin.external,
        'schedule' => TimetableOrigin.schedule,
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

  /// 运行时合成快照专用：条目 id → 外部来源 id（[TimetableOrigin.external] 条目）。
  ///
  /// **不持久化**：[toJson] 不写、[tryParse] 读回为空，因此手工时间表与请求
  /// 负载都不受影响；合成之后由 [toCalendarSettings] 生成带 `external/sourceId`
  /// 的 [CalendarOccupancy]，供冲突解释说明“外部日历”来源。
  final Map<String, String> externalEntrySources;

  const Timetable({
    this.revision = 0,
    this.timezoneId = kDefaultTimezoneId,
    this.timezoneOffsetMinutes = kDefaultTimezoneOffsetMinutes,
    required this.dateFrom,
    required this.dateTo,
    this.defaultState = 1,
    this.weekly = const <TimetableEntry>[],
    this.dates = const <TimetableEntry>[],
    this.externalEntrySources = const <String, String>{},
  });

  bool get hasEntries => weekly.isNotEmpty || dates.isNotEmpty;

  /// 合成快照里是否含有外部日历占用（只读）。
  bool get hasExternalBusy =>
      dates.any((e) => e.origin == TimetableOrigin.external);

  /// 某个外部占用来源 id；非外部条目或未知条目返回 null。
  String? externalSourceIdOf(TimetableEntry entry) =>
      externalEntrySources[entry.id];

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
    Map<String, String>? externalEntrySources,
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
        externalEntrySources: externalEntrySources ?? this.externalEntrySources,
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
    // 日期层必须按“同一天”分组规范化：_normalizeLayer 只按分钟区间判断重叠，
    // 不区分 date；把整个 dates 列表交给它会让不同日期同一时刻的规则互相切掉，
    // 只有最后写入的那天存活（多天复制/跨日会直接踩中）。
    final sorted = isDate ? _normalizeDates(kept) : _normalizeWeekly(kept);
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
        ? copyWith(dates: _normalizeDates(kept))
        : copyWith(weekly: _normalizeWeekly(kept));
  }

  /// 跨日连续区间：按自然日拆分后逐日写入，整次调用返回一个新快照。
  ///
  /// [startDate] 与 [endDate] 均为 yyyy-MM-dd，结束必须晚于开始：跨日时
  /// `endDate > startDate` 即可；同一日期时必须 `endMinute > startMinute`。
  ///
  /// 跨午夜按**自然日**拆分，不做星期取模：周一 23:30 → 周二 00:30 写成
  /// 周一 `[1410,1440)` + 周二 `[0,30)`，既不会把周日→周一铺满整周，也不会
  /// 产生 end>1440 的非法规则。中间整天写成 `[0,1440)`。
  ///
  /// 端点必须都落在 `[coverageFrom, coverageTo]` 内；越界、日期非法或区间非法
  /// 时返回 null，由调用方明确报错，**不静默截断**。
  ///
  /// 这是一次纯计算：调用方应把返回值作为**一笔**事务提交
  /// （`TimetableDraft.recordTransaction`），而不是逐日多笔。
  Timetable? paintRange({
    required String startDate,
    required int startMinute,
    required String endDate,
    required int endMinute,
    required TimetableState state,
    TimetableOrigin origin = TimetableOrigin.manual,
    String? title,
    String? taskId,
    String? reservationId,
    required String coverageFrom,
    required String coverageTo,
  }) {
    final from = _validatedDateKey(startDate);
    final to = _validatedDateKey(endDate);
    final coverFrom = _validatedDateKey(coverageFrom);
    final coverTo = _validatedDateKey(coverageTo);
    if (from == null || to == null || coverFrom == null || coverTo == null) {
      return null;
    }
    if (coverFrom.compareTo(coverTo) > 0) return null;
    if (from.compareTo(to) > 0) return null;
    if (from.compareTo(coverFrom) < 0 || to.compareTo(coverTo) > 0) return null;
    if (startMinute < 0 || startMinute >= kTimetableMinutesPerDay) return null;
    if (endMinute < 0 || endMinute > kTimetableMinutesPerDay) return null;

    if (from == to) {
      if (endMinute <= startMinute) return null;
      return paint(
        date: from,
        start: startMinute,
        end: endMinute,
        state: state,
        origin: origin,
        title: title,
        taskId: taskId,
        reservationId: reservationId,
      );
    }

    // 跨日：枚举自然日（coverage 最多 400 天，这里同样设上限防止异常输入）。
    final dayKeys = <String>[];
    var cursor = from;
    var guard = 0;
    while (cursor != to && guard++ <= 400) {
      dayKeys.add(cursor);
      cursor = addDaysToDateKey(cursor, 1);
    }
    if (cursor != to) return null;
    dayKeys.add(to);

    final parts = <({String date, int start, int end})>[];
    for (var i = 0; i < dayKeys.length; i++) {
      final isFirst = i == 0;
      final isLast = i == dayKeys.length - 1;
      final partStart = isFirst ? startMinute : 0;
      final partEnd = isLast ? endMinute : kTimetableMinutesPerDay;
      if (partEnd <= partStart) continue;
      parts.add((date: dayKeys[i], start: partStart, end: partEnd));
    }
    if (parts.isEmpty) return null;

    var next = this;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      // 跨日蓝块不允许共享 reservationId：一个片段 id 只能对应一个已绑定片段，
      // 否则 taskSegments 会撞 id。拆分后按顺序加后缀，仍保持稳定。
      final partReservationId = (reservationId == null || reservationId.isEmpty)
          ? reservationId
          : (parts.length == 1 ? reservationId : '$reservationId-${i + 1}');
      next = next.paint(
        date: part.date,
        start: part.start,
        end: part.end,
        state: state,
        origin: origin,
        title: title,
        taskId: taskId,
        reservationId: partReservationId,
      );
    }
    return next;
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

    // 运行时合成快照里的外部忙碌同样要变成“日期层占用”，排程/冲突检测才会把
    // 它当作不可用。标记 external/sourceId 供解释层说明来源；标题固定为匿名串
    // （外部事件标题绝不进入时间表或请求）。
    for (final entry in dates) {
      if (entry.origin != TimetableOrigin.external) continue;
      if (entry.state != TimetableState.occupied) continue;
      final date = entry.date;
      if (date == null || date.isEmpty) continue;
      occupancies.add(CalendarOccupancy(
        id: entry.id,
        title: (entry.title == null || entry.title!.isEmpty)
            ? '外部日历'
            : entry.title!,
        kind: 'activity',
        date: date,
        ranges: <WallClockRange>[WallClockRange(entry.start, entry.end)],
        provisional: false,
        external: true,
        sourceId: externalEntrySources[entry.id],
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

  /// 周模板容量：只统计 weekly/default 的可用区间，不含具体日期覆盖。
  ///
  /// 这是“模板”口径，不能直接当作某一周的实际可用时间展示；界面必须标成
  /// “每周模板”。按实际周日期展开请用 [freeMinutesInWeek]。
  int get freeMinutesPerWeek {
    var total = 0;
    for (var day = 1; day <= 7; day++) {
      for (final r in _freeRangesForWeekday(day)) {
        total += r.durationMinutes;
      }
    }
    return total;
  }

  /// 按 [weekStart] 起的真实 7 个日期展开的本周可用分钟数。
  ///
  /// 逐日使用 [dayIntervals]（defaultState → weekly → dates），因此会扣除本周
  /// 单独画出的占用、日期例外和任务预留；只统计 state=free。显示“本周可用”
  /// 必须用这个口径，不能拿模板容量冒充。
  int freeMinutesInWeek(String weekStart) {
    final days = weekDays(weekStart: weekStart);
    if (days.isEmpty) return 0;
    var total = 0;
    for (final day in days) {
      for (final interval in day.intervals) {
        if (interval.state == TimetableState.free) total += interval.minutes;
      }
    }
    return total;
  }

  /// 整个 coverage 范围内按天展开的可用分钟数（用于输入框摘要）。
  int get freeMinutesInCoverage {
    final from = parseDateKey(dateFrom);
    if (from == null) return 0;
    final base = _dateOf(from);
    var total = 0;
    final days = coverageDays.clamp(0, 400);
    for (var i = 0; i < days; i++) {
      final date = base.add(Duration(days: i));
      final key = WallClock.formatDateKey(date.year, date.month, date.day);
      for (final interval in dayIntervals(key, date.weekday)) {
        if (interval.state == TimetableState.free) total += interval.minutes;
      }
    }
    return total;
  }

  /// coverage 包含的自然日数；日期非法时为 0。
  int get coverageDays {
    final from = parseDateKey(dateFrom);
    final to = parseDateKey(dateTo);
    if (from == null || to == null) return 0;
    final first = _dateOf(from);
    final last = _dateOf(to);
    final days = last.difference(first).inDays + 1;
    return days < 0 ? 0 : days;
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
    // 稳定排序：同一开始时间的条目保持输入顺序，后出现的覆盖先出现的。
    // 普通 sort 在相同 start 时可能把“周可用”排到“占用”之后，导致占用被整段
    // 可用覆盖（fromSchedule 中 08:00 开始的第一节课会因此消失）。
    final sorted = input
        .asMap()
        .entries
        .toList()
      ..sort((a, b) {
        final byStart = a.value.start.compareTo(b.value.start);
        if (byStart != 0) return byStart;
        return a.key.compareTo(b.key);
      });
    final out = <TimetableEntry>[];
    for (final entry in sorted) {
      final e = entry.value;
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

/// 复制到多天的策略。
enum CopyStrategy {
  /// 只填空闲：不覆盖占用(0)、已有任务预留(2)与目标日自己的显式规则（用户锁定）。
  fillFreeOnly('只填空闲'),

  /// 替换目标所选时段：用源日期的时段整体改写目标日对应时刻（需确认）。
  replaceSelection('替换所选时段');

  const CopyStrategy(this.label);

  final String label;
}

/// 一次“复制到多天”的预计结果，供预览与确认。
///
/// [result] 是应用后的完整时间表；[targetDates] 只含**实际发生写入**的目标日期
/// （去重、升序）；无任何写入时 [isEmpty] 为 true，调用方不应产生撤销记录。
class TimetableCopyPlan {
  const TimetableCopyPlan({
    required this.result,
    this.targetDates = const <String>[],
    this.changedMinutes = 0,
    this.removedRanges = const <String>[],
    this.affectedTaskIds = const <String>{},
    this.protectedSkippedMinutes = 0,
    this.warnings = const <String>[],
  });

  /// 应用后的时间表（复制一律写为日期例外，不改周模板）。
  final Timetable result;

  /// 实际发生写入的目标日期，去重升序；不含源日期与非法日期。
  final List<String> targetDates;

  /// 实际写入的分钟数。
  final int changedMinutes;

  /// 替换模式下会被移除/改写的目标区间，形如
  /// `2026-10-20 10:00-11:00 占用`（只统计真正被改写、且与原内容不同的区间）。
  final List<String> removedRanges;

  /// 被移除/改写区间上的任务引用（非空 taskId）。
  final Set<String> affectedTaskIds;

  /// 仅填充模式下因目标受保护（占用/任务预留/目标日显式规则）而跳过的分钟数。
  final int protectedSkippedMinutes;

  /// 明确提示：未绑定蓝块、保留任务绑定时时长增加、非法日期被忽略等。
  final List<String> warnings;

  /// 无任何实际写入（UI 据此不产生撤销记录）。
  bool get isEmpty => changedMinutes <= 0;
}

/// 应用预览：返回新 Timetable（纯函数，直接来自 [TimetableCopyPlan.result]）。
Timetable applyCopyPlan(TimetableCopyPlan plan) => plan.result;

/// 复制源日期的有效时段到多个目标日期（写为日期例外，不改周模板）。
///
/// * 源时段：`wholeDay == false`（默认）时只取源日期的**日期层显式规则**
///   （用户在那一天画过/改过的内容）；`wholeDay == true` 时取该日展开后的
///   完整 `0..1440` 有效区间，让目标日整体等于源日。
/// * [CopyStrategy.fillFreeOnly]（默认）：只写目标日“当前有效状态为 free 且没有被
///   目标日自己的显式日期规则覆盖”的分钟；占用(0)、任务预留(2)与目标日显式规则
///   （含手动锁定的可用）都跳过并计入 [TimetableCopyPlan.protectedSkippedMinutes]。
/// * [CopyStrategy.replaceSelection]：用源时段整体改写目标日对应时刻，并如实统计
///   将被移除/改写的区间与任务引用。
/// * [keepTaskBindings] 默认 false：复制的蓝块 taskId 置空（未绑定蓝块）；true 时
///   保留 taskId，并对每个任务给出“预留时长将增加 N 分钟”的提示。
/// * 目标日期去重升序；非法日期进 warnings 被忽略；源日期本身不作为目标。
/// * 无变化时 [TimetableCopyPlan.isEmpty] 为 true，调用方不应产生撤销记录。
TimetableCopyPlan planCopyDateRules({
  required Timetable source,
  required String sourceDate,
  required Iterable<String> targetDates,
  CopyStrategy strategy = CopyStrategy.fillFreeOnly,
  bool keepTaskBindings = false,
  bool wholeDay = false,
}) {
  final warnings = <String>[];
  final removedRanges = <String>[];
  final affectedTaskIds = <String>{};
  final writtenDates = <String>[];
  final addedBoundMinutes = <String, int>{};
  var changedMinutes = 0;
  var protectedSkippedMinutes = 0;

  final sourceKey = _validatedDateKey(sourceDate);
  if (sourceKey == null) {
    warnings.add('源日期不是有效日期：$sourceDate');
    return TimetableCopyPlan(result: source, warnings: warnings);
  }

  final targets = <String>{};
  final invalid = <String>[];
  for (final raw in targetDates) {
    final key = _validatedDateKey(raw);
    if (key == null) {
      invalid.add(raw);
      continue;
    }
    if (key == sourceKey) continue; // 源日期不需要复制给自己
    targets.add(key);
  }
  if (invalid.isNotEmpty) warnings.add('忽略非法日期：${invalid.join('、')}');
  final sortedTargets = targets.toList()..sort();

  // 源时段。
  final rules = <_CopyRule>[];
  if (wholeDay) {
    final weekday = weekdayOfDateKey(sourceKey);
    for (final interval in source.dayIntervals(sourceKey, weekday)) {
      if (interval.end <= interval.start) continue;
      rules.add(_CopyRule(
        start: interval.start,
        end: interval.end,
        state: interval.state,
        title: interval.title,
        taskId: interval.taskId,
        reservationId: interval.reservationId,
      ));
    }
  } else {
    final entries = source.dates
        .where((e) => e.date == sourceKey)
        .toList(growable: false)
      ..sort((a, b) => a.start.compareTo(b.start));
    for (final e in entries) {
      rules.add(_CopyRule(
        start: e.start,
        end: e.end,
        state: e.state,
        title: e.title,
        taskId: e.taskId,
        reservationId: e.reservationId,
      ));
    }
  }

  var unboundMinutes = 0;
  final boundSourceTasks = <String>{};
  for (final rule in rules) {
    if (rule.state != TimetableState.task) continue;
    if (rule.taskId == null || rule.taskId!.isEmpty) {
      unboundMinutes += rule.end - rule.start;
    } else {
      boundSourceTasks.add(rule.taskId!);
    }
  }
  if (unboundMinutes > 0) {
    warnings.add('源日期含 $unboundMinutes 分钟未绑定的蓝色预留，复制后仍未绑定');
  }
  if (!keepTaskBindings && boundSourceTasks.isNotEmpty) {
    warnings.add(
        '源日期的蓝色预留绑定了 ${boundSourceTasks.length} 个任务，默认不复制绑定关系');
  }

  if (rules.isEmpty || sortedTargets.isEmpty) {
    return TimetableCopyPlan(
      result: source,
      warnings: warnings,
      protectedSkippedMinutes: 0,
    );
  }

  var next = source;
  for (final targetDate in sortedTargets) {
    final weekday = weekdayOfDateKey(targetDate);
    // 目标日“复制前”的有效区间与显式规则：整段判断都基于复制前状态，
    // 这样 protectedSkippedMinutes / removedRanges 是“用户确认前看到的真实情况”。
    final targetIntervals = next.dayIntervals(targetDate, weekday);
    final targetExplicit =
        next.dates.where((e) => e.date == targetDate).toList(growable: false);
    final changedBefore = changedMinutes;

    for (final rule in rules) {
      final desiredTaskId = rule.state == TimetableState.task
          ? (keepTaskBindings ? rule.taskId : null)
          : null;

      if (strategy == CopyStrategy.fillFreeOnly) {
        // 源规则本身是“可用”时，填到目标的“可用”格上没有业务变化，直接跳过。
        if (rule.state == TimetableState.free) continue;
        final writable = _freeCopyRanges(
          targetIntervals,
          targetExplicit,
          rule.start,
          rule.end,
        );
        var writableMinutes = 0;
        for (final range in writable) {
          writableMinutes += range.end - range.start;
        }
        protectedSkippedMinutes +=
            (rule.end - rule.start) - writableMinutes;
        for (final range in writable) {
          final minutes = range.end - range.start;
          next = next.paint(
            date: targetDate,
            start: range.start,
            end: range.end,
            state: rule.state,
            origin: TimetableOrigin.manual,
            title: rule.title,
            taskId: desiredTaskId,
            reservationId: _copyReservationId(
              rule,
              targetDate,
              range.start,
              range.end,
            ),
          );
          changedMinutes += minutes;
          if (rule.state == TimetableState.task && desiredTaskId != null) {
            addedBoundMinutes[desiredTaskId] =
                (addedBoundMinutes[desiredTaskId] ?? 0) + minutes;
          }
        }
        continue;
      }

      // replaceSelection：按目标当前状态/绑定切分，只改写真正不同的区间；
      // 相同内容不写、不统计，确保无变化时 isEmpty 为 true。
      for (final range in _replacedRanges(
        targetIntervals,
        rule.start,
        rule.end,
        rule.state,
        desiredTaskId,
      )) {
        for (final interval in targetIntervals) {
          if (interval.end <= range.start || interval.start >= range.end) {
            continue;
          }
          final line = '$targetDate '
              '${WallClockRange.formatMinute(interval.start)}-'
              '${WallClockRange.formatMinute(interval.end)} '
              '${interval.state.label}';
          if (!removedRanges.contains(line)) removedRanges.add(line);
          final taskId = interval.taskId;
          if (interval.state == TimetableState.task &&
              taskId != null &&
              taskId.isNotEmpty) {
            affectedTaskIds.add(taskId);
          }
        }
        final minutes = range.end - range.start;
        next = next.paint(
          date: targetDate,
          start: range.start,
          end: range.end,
          state: rule.state,
          origin: TimetableOrigin.manual,
          title: rule.title,
          taskId: desiredTaskId,
          reservationId: _copyReservationId(
            rule,
            targetDate,
            range.start,
            range.end,
          ),
        );
        changedMinutes += minutes;
        if (rule.state == TimetableState.task && desiredTaskId != null) {
          addedBoundMinutes[desiredTaskId] =
              (addedBoundMinutes[desiredTaskId] ?? 0) + minutes;
        }
      }
    }

    if (changedMinutes > changedBefore) writtenDates.add(targetDate);
  }

  if (keepTaskBindings) {
    for (final entry in addedBoundMinutes.entries) {
      warnings.add('任务 ${entry.key} 的预留时长将增加 ${entry.value} 分钟（多日复制）');
    }
  }

  return TimetableCopyPlan(
    result: next,
    targetDates: writtenDates,
    changedMinutes: changedMinutes,
    removedRanges: removedRanges,
    affectedTaskIds: affectedTaskIds,
    protectedSkippedMinutes: protectedSkippedMinutes,
    warnings: warnings,
  );
}

/// 一条待复制的源时段（来自日期层规则或展开后的有效区间）。
class _CopyRule {
  const _CopyRule({
    required this.start,
    required this.end,
    required this.state,
    this.title,
    this.taskId,
    this.reservationId,
  });

  final int start;
  final int end;
  final TimetableState state;
  final String? title;
  final String? taskId;
  final String? reservationId;
}

/// 每份复制出来的蓝块必须有独立身份：同一个蓝块复制到多天/多段时不能共享
/// reservationId，否则 `taskSegments` 会撞 id。内容派生的 id 保证同一目标日期
/// 同一区间重复计算时稳定。
String? _copyReservationId(
    _CopyRule rule, String targetDate, int start, int end) {
  if (rule.state != TimetableState.task) return null;
  final base = rule.reservationId;
  if (base == null || base.isEmpty) {
    return timetableEntryId(
      state: TimetableState.task,
      start: start,
      end: end,
      date: targetDate,
      title: rule.title,
    );
  }
  return '$base@$targetDate#$start-$end';
}

/// 仅填充模式可写的分钟：目标有效 free 区间 ∩ 源区间，再排除目标日显式规则。
List<({int start, int end})> _freeCopyRanges(
  List<TimetableInterval> targetIntervals,
  List<TimetableEntry> targetExplicit,
  int from,
  int to,
) {
  final writable = <({int start, int end})>[];
  for (final interval in targetIntervals) {
    if (interval.state != TimetableState.free) continue;
    final start = math.max(from, interval.start);
    final end = math.min(to, interval.end);
    if (end <= start) continue;
    var pieces = <({int start, int end})>[(start: start, end: end)];
    for (final entry in targetExplicit) {
      if (entry.end <= from || entry.start >= to) continue;
      final nextPieces = <({int start, int end})>[];
      for (final piece in pieces) {
        if (entry.end <= piece.start || entry.start >= piece.end) {
          nextPieces.add(piece);
          continue;
        }
        if (entry.start > piece.start) {
          nextPieces.add(
              (start: piece.start, end: math.min(entry.start, piece.end)));
        }
        if (entry.end < piece.end) {
          nextPieces.add(
              (start: math.max(entry.end, piece.start), end: piece.end));
        }
      }
      pieces = nextPieces;
    }
    writable.addAll(pieces);
  }
  writable.sort((a, b) => a.start.compareTo(b.start));
  return writable;
}

/// 替换模式下真正需要改写的区间：目标当前状态/绑定与源内容不同的连续分钟。
List<({int start, int end})> _replacedRanges(
  List<TimetableInterval> targetIntervals,
  int from,
  int to,
  TimetableState state,
  String? taskId,
) {
  final out = <({int start, int end})>[];
  int? runStart;
  for (var minute = from; minute < to; minute++) {
    final current = _intervalAtMinute(targetIntervals, minute);
    final same = current != null &&
        current.state == state &&
        (state != TimetableState.task ||
            (current.taskId ?? '') == (taskId ?? ''));
    if (same) {
      if (runStart != null) {
        out.add((start: runStart, end: minute));
        runStart = null;
      }
    } else {
      runStart ??= minute;
    }
  }
  if (runStart != null) out.add((start: runStart, end: to));
  return out;
}

TimetableInterval? _intervalAtMinute(
    List<TimetableInterval> intervals, int minute) {
  for (final interval in intervals) {
    if (minute >= interval.start && minute < interval.end) return interval;
  }
  return null;
}

/// 严格日期键：必须能被 DateTime 原样回读（拒绝 2026-02-31 之类）。
String? _validatedDateKey(String text) {
  final key = parseDateKey(text);
  if (key == null) return null;
  final parts = key.split('-');
  final date = DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final roundTrip = WallClock.formatDateKey(date.year, date.month, date.day);
  return roundTrip == key ? key : null;
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

/// 编辑草稿：一次用户操作 = 一笔撤销事务；重复经过同格不产生多条历史。
///
/// 历史由 [TimetableHistory] 承载（past/present/future），容量上限
/// [historyCapacity] 笔，超出丢最旧；撤销/重做恢复的是完整 [Timetable] 快照，
/// 因此 state、taskId、reservationId、日期规则与周规则都会一起恢复，不是只恢复
/// 画布颜色。
///
/// 网格笔画仍走 [beginStroke]/[endStroke] 自动成笔；跨日、批量复制、批量绑定
/// 等非笔画操作由调用方用 [recordTransaction] 显式记一笔（一次调用 = 一笔事务）。
class TimetableDraft {
  TimetableDraft(Timetable timetable)
      : _history = TimetableHistory(initial: timetable);

  /// 历史容量上限：200 笔事务。
  static const int historyCapacity = TimetableHistory.defaultCapacity;

  final TimetableHistory _history;
  Timetable? _strokeBase;
  String _strokeLabel = '编辑时间表';

  Timetable get timetable => _history.timetable!;

  bool get hasUndo => _history.canUndo || _strokeBase != null;

  /// 与 [hasUndo] 等价的显式命名（工具栏/菜单读这个）。
  bool get canUndo => hasUndo;

  /// 进行中的笔画尚未提交，此时不提供重做。
  bool get canRedo => _strokeBase == null && _history.canRedo;

  int get undoDepth => _history.undoDepth;
  int get redoDepth => _history.redoDepth;

  /// 下一次撤销的动作名；没有可撤销事务时为 null。
  String? get lastActionLabel => _history.undoLabel;

  void beginStroke() {
    if (_strokeBase != null) return;
    _strokeBase = timetable;
    _strokeLabel = '编辑时间表';
  }

  /// 把当前周表替换掉（例如切换“每周重复”或导航后重建），不进入撤销栈，
  /// 并清空撤销/重做历史。
  void reset(Timetable next) {
    _strokeBase = null;
    _history.markApplied(next);
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
    final sorted = slots
        .where((s) => s >= 0 && s < kTimetableSlotsPerDay)
        .toSet()
        .toList()
      ..sort();
    if (sorted.isEmpty) return;
    _strokeLabel = '绘制${state.label} '
        '${WallClockRange.formatMinute(sorted.first * kTimetableSlotMinutes)}-'
        '${WallClockRange.formatMinute((sorted.last + 1) * kTimetableSlotMinutes)}';
    _history.setPresent(_history.timetable!.paintSlots(
      date: date,
      weekday: weekday,
      slots: sorted,
      state: state,
      origin: origin,
      title: title,
      taskId: taskId,
      reservationId: reservationId,
    ));
  }

  void eraseSlots({String? date, int? weekday, required Iterable<int> slots}) {
    if (_strokeBase == null) beginStroke();
    // 右键的语义是“恢复可用”，不是“删掉覆盖后让下层灰块回来”。
    // 因此显式写一条 free 规则；这样默认休息格被擦除后重启仍是白的。
    final sorted = slots
        .where((s) => s >= 0 && s < kTimetableSlotsPerDay)
        .toSet()
        .toList()
      ..sort();
    if (sorted.isEmpty) return;
    _strokeLabel = '擦除 '
        '${WallClockRange.formatMinute(sorted.first * kTimetableSlotMinutes)}-'
        '${WallClockRange.formatMinute((sorted.last + 1) * kTimetableSlotMinutes)}';
    var next = _history.timetable!;
    for (final slot in sorted) {
      next = next.paint(
        date: date,
        weekday: weekday,
        start: slot * kTimetableSlotMinutes,
        end: (slot + 1) * kTimetableSlotMinutes,
        state: TimetableState.free,
        origin: TimetableOrigin.manual,
        title: '手动可用',
      );
    }
    _history.setPresent(next);
  }

  void endStroke() {
    final before = _strokeBase;
    _strokeBase = null;
    if (before == null) return;
    _history.record(TimetableTransaction(
      label: _strokeLabel,
      before: before,
      after: _history.timetable!,
    ));
  }

  void cancelStroke() {
    final before = _strokeBase;
    _strokeBase = null;
    if (before != null) _history.setPresent(before);
  }

  bool undo() {
    if (_strokeBase != null) {
      cancelStroke();
      return true;
    }
    return _history.undo() != null;
  }

  /// 重做一笔；进行中的笔画未提交时返回 false（不丢弃用户正在画的内容）。
  bool redo() {
    if (_strokeBase != null) return false;
    return _history.redo() != null;
  }

  /// 记录一笔非笔画事务（跨日、批量复制、批量绑定等），返回是否真的入栈。
  ///
  /// 内部 `before = 当前时间表`、`after = next`；业务数据相同（忽略 revision）时
  /// 不入栈、不清空 redo，返回 false；有真实变化才清空 redo 并返回 true。调用方
  /// 可据此决定是否提示“无修改”，不要凭“调用过”就声称产生了撤销记录。
  /// 若此时还有未提交的笔画，它会被并入这一笔，不会额外多出一条历史。
  bool recordTransaction(
    Timetable next, {
    required String label,
    Set<String> affectedDates = const <String>{},
  }) {
    _strokeBase = null;
    final before = _history.timetable!;
    return _history.record(TimetableTransaction(
      label: label,
      before: before,
      after: next,
      affectedDates: affectedDates,
    ));
  }

  /// 只有提交成功后才调用：已提交状态成为新的撤销基线，清空两栈。
  void markApplied() {
    _strokeBase = null;
    _history.markApplied(_history.timetable!);
  }
}
