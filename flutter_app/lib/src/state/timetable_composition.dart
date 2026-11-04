// 运行时“合成时间表”：手工权威时间表 + 外部日历忙碌（只读）。
//
// 产品规则（第二轮 P1）：
//   * 外部日历只做**只读**约束。合成结果只存在于内存/请求负载里，绝不写回
//     `conversation.calendarDraft` 或 `version.timetable`；
//   * 合成条目的 `state=occupied`、`origin=external`、标题固定为匿名串
//     「外部日历」——外部事件标题/文件路径/UID 一律不进入时间表，更不会进入
//     模型请求；
//   * 合成条目 `taskId`/`reservationId` 恒为 null：外部事件不可绘制、擦除或
//     绑定任务；
//   * 外部忙碌优先于手工日期层（包括用户手画的“这一天可用”例外）：同一分钟
//     外部占用判定优先。手工时间表本身不被修改，因此“例外”在忙碌时段之外
//     仍然生效；
//   * coverage 取手工覆盖范围与忙碌日期的并集，保证外部忙碌日期也能被请求的
//     effectiveTimetable 展开。
//
// 本文件是纯计算：不依赖 Widget / Win32 / I/O，可在 `flutter test` 里直接断言。

import '../model/calendar.dart';
import '../model/external_calendar.dart';
import '../model/timetable.dart';

/// 合成条目固定使用的匿名标题：不含任何真实外部事件标题。
const String kExternalCalendarAnonymousTitle = '外部日历';

/// 把外部忙碌实例合成为“运行时时间表”。
///
/// [manual] 是唯一权威来源（不会被修改）；[busy] 是 [ExternalBusyInstance] 列表
/// （由 `ExternalCalendarService.busyFor` 按规划时区/日期范围展开）。没有忙碌时
/// 原样返回 [manual]（同一对象），保证“未启用外部日历”的行为与 0.2.1 完全一致。
Timetable composeExternalBusy({
  required Timetable manual,
  required List<ExternalBusyInstance> busy,
  required String timezoneId,
  String title = kExternalCalendarAnonymousTitle,
}) {
  final records = <_BusyRecord>[];
  for (final instance in busy) {
    final record = _recordOf(instance, title);
    if (record != null) records.add(record);
  }
  if (records.isEmpty) return manual;

  // 稳定顺序：按日期、开始、结束、来源 id 排序，保证抖动仅由内容决定。
  records.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    final byEnd = a.end.compareTo(b.end);
    return byEnd != 0
        ? byEnd
        : (a.sourceId ?? '').compareTo(b.sourceId ?? '');
  });

  // 同一区间重复（同一来源重复展开或两个来源完全重合）只保留一条。
  final unique = <_BusyRecord>[];
  for (final record in records) {
    final duplicate = unique.any((e) =>
        e.date == record.date &&
        e.start == record.start &&
        e.end == record.end &&
        e.sourceId == record.sourceId);
    if (!duplicate) unique.add(record);
  }

  // 手工日期层按日期分组；外部占用优先，逐条切掉被覆盖的手工片段。
  final manualByDate = <String, List<_BusyRecord>>{};
  for (final entry in manual.dates) {
    final date = entry.date;
    if (date == null || date.isEmpty) continue;
    manualByDate
        .putIfAbsent(date, () => <_BusyRecord>[])
        .add(_BusyRecord(
          sourceId: null,
          date: date,
          start: entry.start,
          end: entry.end,
          entry: entry,
        ));
  }

  final externalByDate = <String, List<_BusyRecord>>{};
  for (final record in unique) {
    final list = manualByDate[record.date];
    if (list == null) {
      externalByDate.putIfAbsent(record.date, () => <_BusyRecord>[]).add(record);
      continue;
    }
    // 外部忙碌覆盖手工日期层：先切掉被覆盖部分，再把外部条目追加到该日。
    final cut = <_BusyRecord>[];
    for (final manualRecord in list) {
      cut.addAll(_cutRecord(manualRecord, record.start, record.end));
    }
    manualByDate[record.date] = cut;
    externalByDate.putIfAbsent(record.date, () => <_BusyRecord>[]).add(record);
  }

  // 不同来源的外部忙碌相互重叠时，后加入者覆盖先加入者（状态都是占用，
  // 语义不变），保证合成结果仍然“同一层不重叠”。
  for (final list in externalByDate.values) {
    list.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.sourceId!.compareTo(b.sourceId!);
    });
  }

  final dates = <TimetableEntry>[];
  final sourceByEntryId = <String, String>{};
  final allDates = <String>{
    ...manualByDate.keys,
    ...externalByDate.keys,
  };
  final sortedDates = allDates.toList()..sort();
  for (final date in sortedDates) {
    final dayRecords = <_BusyRecord>[
      ...?manualByDate[date],
      ..._nonOverlappingExternal(externalByDate[date]),
    ];
    dayRecords.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return a.end.compareTo(b.end);
    });
    for (final record in dayRecords) {
      if (record.entry != null) {
        dates.add(record.entry!);
        continue;
      }
      final sourceId = record.sourceId!;
      final id = externalBusyEntryId(
        sourceId: sourceId,
        date: date,
        start: record.start,
        end: record.end,
      );
      dates.add(TimetableEntry(
        id: id,
        state: TimetableState.occupied,
        start: record.start,
        end: record.end,
        date: date,
        origin: TimetableOrigin.external,
        title: record.title,
        // 只读标记绝不进入 taskId / reservationId。
        taskId: null,
        reservationId: null,
      ));
      sourceByEntryId[id] = sourceId;
    }
  }

  // coverage：手工覆盖范围 ∪ 忙碌日期。
  var dateFrom = manual.dateFrom;
  var dateTo = manual.dateTo;
  for (final record in unique) {
    if (record.date.compareTo(dateFrom) < 0) dateFrom = record.date;
    if (record.date.compareTo(dateTo) > 0) dateTo = record.date;
  }

  final tz = timezoneId.trim();
  return manual.copyWith(
    timezoneId: tz.isEmpty ? manual.timezoneId : tz,
    dateFrom: dateFrom,
    dateTo: dateTo,
    dates: List<TimetableEntry>.unmodifiable(dates),
    externalEntrySources: Map<String, String>.unmodifiable(sourceByEntryId),
  );
}

/// 外部忙碌条目 id（契约格式）：`ext-<sourceId>-<yyyymmdd>-<start>-<end>`。
String externalBusyEntryId({
  required String sourceId,
  required String date,
  required int start,
  required int end,
}) {
  final compactDate = date.replaceAll('-', '');
  return 'ext-$sourceId-$compactDate-$start-$end';
}

/// 把外部忙碌合成为排程/冲突用的 [CalendarSettings]（运行时，**不落盘**）。
///
/// 在 [base] 的 occupancies 后追加带 `external: true` / `sourceId` 的日期层占用，
/// 使 [buildAvailability] 扣除外部占用，并使冲突解释能说明“外部日历”来源。
/// 没有可用忙碌时原样返回 [base]（同一对象）。
CalendarSettings composeExternalSettings({
  required CalendarSettings base,
  required List<ExternalBusyInstance> busy,
  String title = kExternalCalendarAnonymousTitle,
}) {
  if (busy.isEmpty) return base;
  final extras = <CalendarOccupancy>[];
  final seen = <String>{};
  for (final instance in busy) {
    final record = _recordOf(instance, title);
    if (record == null) continue;
    final id = externalBusyEntryId(
      sourceId: record.sourceId!,
      date: record.date,
      start: record.start,
      end: record.end,
    );
    if (!seen.add(id)) continue;
    extras.add(CalendarOccupancy(
      id: id,
      title: record.title ?? kExternalCalendarAnonymousTitle,
      kind: 'activity',
      date: record.date,
      ranges: <WallClockRange>[WallClockRange(record.start, record.end)],
      provisional: false,
      external: true,
      sourceId: record.sourceId,
    ));
  }
  if (extras.isEmpty) return base;
  return base.copyWith(
    occupancies: List<CalendarOccupancy>.unmodifiable(
      <CalendarOccupancy>[...base.occupancies, ...extras],
    ),
  );
}

/// 去掉 [settings] 里所有外部日历占用（用于“绝不把外部数据写回存储”的场合）。
CalendarSettings withoutExternalOccupancies(CalendarSettings settings) {
  if (!settings.occupancies.any((o) => o.external)) return settings;
  return settings.copyWith(
    occupancies: List<CalendarOccupancy>.unmodifiable(
      settings.occupancies.where((o) => !o.external),
    ),
  );
}

// --------------------------------------------------------------- internals

class _BusyRecord {
  _BusyRecord({
    required this.sourceId,
    required this.date,
    required this.start,
    required this.end,
    this.entry,
    this.title,
  });

  /// null = 手工条目；非 null = 外部忙碌。
  final String? sourceId;
  final String date;
  final int start;
  final int end;

  /// 手工条目原样保留引用（不改写 id）；外部条目为 null。
  final TimetableEntry? entry;
  final String? title;
}

/// 解析一条外部忙碌实例；非法数据直接跳过（不猜、不截断成别的时间）。
_BusyRecord? _recordOf(ExternalBusyInstance instance, String title) {
  // `busy=false`（透明/暂定按策略不计入占用）不进入合成时间表。
  if (!instance.busy) return null;
  final date = parseDateKey(instance.dayKey);
  if (date == null) return null;
  final start = instance.startMinute;
  final end = instance.endMinute;
  if (start < 0 || end <= start || end > kTimetableMinutesPerDay) return null;
  final sourceId = instance.sourceId.trim();
  if (sourceId.isEmpty) return null;
  return _BusyRecord(
    sourceId: sourceId,
    date: date,
    start: start,
    end: end,
    title: title,
  );
}

/// 用 [start,end) 切掉一条记录；保留左右两侧。
List<_BusyRecord> _cutRecord(_BusyRecord record, int start, int end) {
  if (record.end <= start || record.start >= end) return <_BusyRecord>[record];
  final out = <_BusyRecord>[];
  if (record.start < start) {
    out.add(record.entry != null
        ? _BusyRecord(
            sourceId: null,
            date: record.date,
            start: record.start,
            end: start,
            entry: record.entry!.copyWith(id: '${record.entry!.id}-a', end: start),
          )
        : _BusyRecord(
            sourceId: record.sourceId,
            date: record.date,
            start: record.start,
            end: start,
            title: record.title,
          ));
  }
  if (record.end > end) {
    out.add(record.entry != null
        ? _BusyRecord(
            sourceId: null,
            date: record.date,
            start: end,
            end: record.end,
            entry:
                record.entry!.copyWith(id: '${record.entry!.id}-b', start: end),
          )
        : _BusyRecord(
            sourceId: record.sourceId,
            date: record.date,
            start: end,
            end: record.end,
            title: record.title,
          ));
  }
  return out;
}

/// 让同一天内相互重叠的外部条目互不重叠：后加入者覆盖先加入者（都是占用）。
List<_BusyRecord> _nonOverlappingExternal(List<_BusyRecord>? input) {
  if (input == null || input.isEmpty) return const <_BusyRecord>[];
  final kept = <_BusyRecord>[];
  for (final record in input) {
    final next = <_BusyRecord>[];
    for (final existing in kept) {
      next.addAll(_cutRecord(existing, record.start, record.end));
    }
    kept
      ..clear()
      ..addAll(next)
      ..add(record);
  }
  return kept;
}
