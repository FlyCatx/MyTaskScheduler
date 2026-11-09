// 无 I/O 的日程实例展开（任务 1）：把一个有限范围查询变成发生实例。
//
// 规则（01 框架 §7）：
//   * 定时日程保存本地墙钟 + IANA 时区；重复保持当地钟点，DST 前跳/回拨
//     的墙上时间明确失败并返回警告，绝不静默归一化；
//   * 全天日程按 [startDate, endDateExclusive) 展开，结束日排他；
//   * occurrenceKey 一律是 eventId + 原始发生日期；本次 override 改到别的
//     日期后 key 不变，跨窗口也要能按覆盖时间找到该实例；
//   * 展开设置实例/范围上限，超限返回 complete=false 与警告，调用方不得把
//     截断结果当成完整数据继续排程。

import 'package:timezone/timezone.dart' as tz;

import '../../model/schedule_event.dart';
import '../ics/ics_timezones.dart';

/// 单次查询最多跨度（天）。与现有时间表 400 天上限一致，避免启动时展开
/// 永久重复。
const int kScheduleMaxQueryDays = 400;

/// 单次查询最多实例数；超过返回 complete=false。
const int kScheduleMaxOccurrences = 2000;

/// 范围查询：固定 from/to、显示时区与实例上限。
class ScheduleQuery {
  const ScheduleQuery({
    required this.fromUtc,
    required this.toUtc,
    required this.timezoneId,
    this.maxOccurrences = kScheduleMaxOccurrences,
    this.maxDays = kScheduleMaxQueryDays,
  });

  final DateTime fromUtc;
  final DateTime toUtc;
  final String timezoneId;
  final int maxOccurrences;
  final int maxDays;

  bool get isValid =>
      fromUtc.isBefore(toUtc) &&
      timezoneId.trim().isNotEmpty &&
      maxOccurrences > 0 &&
      maxDays > 0;

  ScheduleQuery copyWith({
    DateTime? fromUtc,
    DateTime? toUtc,
    String? timezoneId,
    int? maxOccurrences,
    int? maxDays,
  }) =>
      ScheduleQuery(
        fromUtc: fromUtc ?? this.fromUtc,
        toUtc: toUtc ?? this.toUtc,
        timezoneId: timezoneId ?? this.timezoneId,
        maxOccurrences: maxOccurrences ?? this.maxOccurrences,
        maxDays: maxDays ?? this.maxDays,
      );
}

/// 一个发生实例（只存在于查询结果，不持久化、不预生成永久表）。
class ScheduleOccurrence {
  const ScheduleOccurrence({
    required this.eventId,
    required this.occurrenceKey,
    required this.originalDate,
    required this.title,
    required this.timezoneId,
    required this.allDay,
    required this.blocksScheduling,
    required this.reminder,
    this.category,
    this.linkedConversationId,
    this.linkedTaskId,
    this.startUtc,
    this.endUtc,
    this.startDate,
    this.endDateExclusive,
    this.isOverride = false,
  });

  final String eventId;
  final String occurrenceKey;

  /// 原始发生日期（yyyy-MM-dd），不含 override 后的新日期。
  final String originalDate;
  final String title;
  final String? category;

  /// 事件自身时区（展示/提醒按它计算，不是设备当前固定偏移）。
  final String timezoneId;
  final bool allDay;
  final bool blocksScheduling;
  final ScheduleReminderKind reminder;
  final String? linkedConversationId;

  /// 稳定关联任务 ID（可空）；详情/周视图按 ID 解析标题，不做同名猜想。
  final String? linkedTaskId;
  final bool isOverride;

  /// 定时实例：绝对 UTC 起止（半开区间）。
  final DateTime? startUtc;
  final DateTime? endUtc;

  /// 全天实例：本地日期区间 [startDate, endDateExclusive)。
  final String? startDate;
  final String? endDateExclusive;

  bool get isTimed => !allDay;

  /// 定时实例的时长；全天实例按整天计。
  Duration get duration {
    if (allDay) {
      final start = startDate == null ? null : dateKeyToUtc(startDate!);
      final end =
          endDateExclusive == null ? null : dateKeyToUtc(endDateExclusive!);
      if (start != null && end != null) return end.difference(start);
      return const Duration(days: 1);
    }
    final s = startUtc;
    final e = endUtc;
    if (s == null || e == null) return Duration.zero;
    return e.difference(s);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'eventId': eventId,
        'key': occurrenceKey,
        'originalDate': originalDate,
        'title': title,
        'category': category,
        'timezoneId': timezoneId,
        'allDay': allDay,
        'blocksScheduling': blocksScheduling,
        'reminder': reminder.wireName,
        'linkedConversationId': linkedConversationId,
        'linkedTaskId': linkedTaskId,
        if (!allDay) ...<String, dynamic>{
          'startUtc': startUtc?.toUtc().toIso8601String(),
          'endUtc': endUtc?.toUtc().toIso8601String(),
        },
        if (allDay) ...<String, dynamic>{
          'startDate': startDate,
          'endDateExclusive': endDateExclusive,
        },
        'override': isOverride,
      };
}

/// 展开结果；incomplete 时不能把 occurrences 当成完整数据继续排程。
class ScheduleExpansionResult {
  const ScheduleExpansionResult({
    required this.occurrences,
    required this.warnings,
    required this.complete,
  });

  final List<ScheduleOccurrence> occurrences;
  final List<String> warnings;
  final bool complete;

  static const ScheduleExpansionResult empty = ScheduleExpansionResult(
    occurrences: <ScheduleOccurrence>[],
    warnings: <String>[],
    complete: true,
  );
}

/// 展开一个查询范围内的实例。
///
/// 同一个 event 的实例按 occurrenceKey 去重；override 会替换原始日期实例，
/// 即使它被移到原查询窗口之外，也会按覆盖后的时间参与窗口判断。
ScheduleExpansionResult expandScheduleEvents({
  required List<ScheduleEvent> events,
  required ScheduleQuery query,
}) {
  if (!query.isValid) {
    return const ScheduleExpansionResult(
      occurrences: <ScheduleOccurrence>[],
      warnings: <String>['日程查询范围不合法'],
      complete: false,
    );
  }
  final spanDays =
      query.toUtc.toUtc().difference(query.fromUtc.toUtc()).inMinutes / 1440.0;
  if (spanDays > query.maxDays) {
    return ScheduleExpansionResult(
      occurrences: const <ScheduleOccurrence>[],
      warnings: <String>[
        '日程查询范围超过 ${query.maxDays} 天，未展开',
      ],
      complete: false,
    );
  }

  final resolver = IcsTimeZoneResolver();
  final warnings = <String>[];
  final byKey = <String, ScheduleOccurrence>{};
  var complete = true;
  var overflow = false;

  bool addOccurrence(ScheduleOccurrence occurrence) {
    if (byKey.containsKey(occurrence.occurrenceKey)) return true;
    if (byKey.length >= query.maxOccurrences) {
      // 超限时不加入第 max+1 条，也不假装结果完整。
      overflow = true;
      complete = false;
      return false;
    }
    byKey[occurrence.occurrenceKey] = occurrence;
    return true;
  }

  for (final event in events) {
    if (event.isDeleted) continue;
    final wallFrom = resolver.utcToWall(event.timezoneId, query.fromUtc);
    final wallTo = resolver.utcToWall(event.timezoneId, query.toUtc);
    if (wallFrom == null || wallTo == null) {
      warnings.add('日程「${event.title}」的时区无法解析：${event.timezoneId}');
      complete = false;
      continue;
    }
    final queryFromDate = dateKeyOfWall(wallFrom);
    final queryToDate = dateKeyOfWall(wallTo);
    final dayBefore = addDaysToDateKey(queryFromDate, -1);
    final dayAfter = addDaysToDateKey(queryToDate, 1);

    // 迭代候选原始日期；重复或单次都由同一循环生成。
    var date = event.startDate;
    if (date.compareTo(dayBefore) < 0) date = dayBefore;
    var guard = 0;
    final lastCandidate = dayAfter;
    while (date.compareTo(lastCandidate) <= 0 && guard <= query.maxDays + 3) {
      guard++;
      final matches = _matchesSeriesDate(event, date);
      if (matches) {
        final key = scheduleOccurrenceKey(event.id, date);
        final exception = event.exceptionFor(key);
        if (exception == null || !exception.excluded) {
          final occurrence = _occurrenceFor(
            event: event,
            originalDate: date,
            exception: exception,
            query: query,
            resolver: resolver,
            warnings: warnings,
            onIncomplete: () => complete = false,
          );
          if (occurrence != null && !addOccurrence(occurrence)) break;
        }
      }
      final next = addDaysToDateKey(date, 1);
      if (next == date) break;
      date = next;
    }

    // override 移到原始窗口之外：按覆盖后的时间单独补一轮。
    for (final exception in event.exceptions) {
      if (exception.excluded) continue;
      final key = exception.occurrenceKey;
      if (byKey.containsKey(key)) continue;
      final originalDate = originalDateOfOccurrenceKey(key);
      if (originalDate == null) continue;
      final occurrence = _occurrenceFor(
        event: event,
        originalDate: originalDate,
        exception: exception,
        query: query,
        resolver: resolver,
        warnings: warnings,
        onIncomplete: () => complete = false,
      );
      if (occurrence != null && !addOccurrence(occurrence)) break;
    }
    if (overflow) break;
  }

  final occurrences = byKey.values.toList(growable: false)
    ..sort((a, b) {
      final byStart = _startSortKey(a).compareTo(_startSortKey(b));
      if (byStart != 0) return byStart;
      return a.occurrenceKey.compareTo(b.occurrenceKey);
    });
  if (overflow) {
    warnings.add(
      '日程实例超过上限 ${query.maxOccurrences}，结果不完整',
    );
  }
  return ScheduleExpansionResult(
    occurrences: List<ScheduleOccurrence>.unmodifiable(occurrences),
    warnings: List<String>.unmodifiable(warnings),
    complete: complete,
  );
}

String _startSortKey(ScheduleOccurrence occurrence) {
  if (occurrence.allDay) {
    return occurrence.startDate ?? '';
  }
  return occurrence.startUtc?.toUtc().toIso8601String() ?? '';
}

bool _matchesSeriesDate(ScheduleEvent event, String date) {
  if (date.compareTo(event.startDate) < 0) return false;
  if (!event.repeat.repeats) return date == event.startDate;
  return event.repeat.matchesDate(date);
}

ScheduleOccurrence? _occurrenceFor({
  required ScheduleEvent event,
  required String originalDate,
  required ScheduleException? exception,
  required ScheduleQuery query,
  required IcsTimeZoneResolver resolver,
  required List<String> warnings,
  required void Function() onIncomplete,
}) {
  final key = scheduleOccurrenceKey(event.id, originalDate);
  final override = exception != null && !exception.excluded ? exception : null;
  if (event.allDay) {
    final startDate = override?.startDate ?? originalDate;
    final endDateExclusive =
        override?.endDateExclusive ?? _addDays(originalDate, event.allDayDayCount);
    final queryFrom = _dateKeyOfUtc(query.fromUtc, resolver, event.timezoneId);
    final queryTo = _dateKeyOfUtc(query.toUtc, resolver, event.timezoneId);
    if (queryFrom == null || queryTo == null) {
      warnings.add('日程「${event.title}」的查询时区无法解析');
      onIncomplete();
      return null;
    }
    // 全天实例与查询窗口按日期半开区间求交；queryTo 当日仍算可见。
    final queryToExclusive = _addDays(queryTo, 1);
    if (startDate.compareTo(queryToExclusive) >= 0) return null;
    if (endDateExclusive.compareTo(queryFrom) <= 0) return null;
    return ScheduleOccurrence(
      eventId: event.id,
      occurrenceKey: key,
      originalDate: originalDate,
      title: event.title,
      category: event.category?.wireName,
      timezoneId: event.timezoneId,
      allDay: true,
      blocksScheduling: event.blocksScheduling,
      reminder: event.reminder,
      linkedConversationId: event.linkedConversationId,
      linkedTaskId: event.linkedTaskId,
      startDate: startDate,
      endDateExclusive: endDateExclusive,
      isOverride: override != null,
    );
  }

  final baseDate = override?.startDate ?? originalDate;
  final startMinute = override?.startMinute ?? event.startMinute;
  final endMinute = override?.endMinute ?? event.endMinute;
  if (startMinute == null || endMinute == null) {
    warnings.add('日程「${event.title}」缺少定时时间');
    onIncomplete();
    return null;
  }
  final startWall = _wall(baseDate, startMinute);
  final endWall = _wall(baseDate, endMinute);
  final startResult = resolver.resolveWall(event.timezoneId, startWall);
  final endResult = resolver.resolveWall(event.timezoneId, endWall);
  final startUtc = startResult.utc;
  final endUtc = endResult.utc;
  if (!startResult.isOk || startUtc == null) {
    warnings.add(
      '日程「${event.title}」的本地开始时间无法确定：${startResult.detail}',
    );
    onIncomplete();
    return null;
  }
  if (!endResult.isOk || endUtc == null) {
    warnings.add(
      '日程「${event.title}」的本地结束时间无法确定：${endResult.detail}',
    );
    onIncomplete();
    return null;
  }
  if (!endUtc.isAfter(startUtc)) {
    warnings.add('日程「${event.title}」的结束时间不晚于开始时间');
    onIncomplete();
    return null;
  }
  // 定时实例与查询窗口是 UTC 半开区间求交。
  if (!startUtc.isBefore(query.toUtc) || !query.fromUtc.isBefore(endUtc)) {
    return null;
  }
  return ScheduleOccurrence(
    eventId: event.id,
    occurrenceKey: key,
    originalDate: originalDate,
    title: event.title,
    category: event.category?.wireName,
    timezoneId: event.timezoneId,
    allDay: false,
    blocksScheduling: event.blocksScheduling,
    reminder: event.reminder,
    linkedConversationId: event.linkedConversationId,
    linkedTaskId: event.linkedTaskId,
    startUtc: startUtc,
    endUtc: endUtc,
    isOverride: override != null,
  );
}

String? _dateKeyOfUtc(
  DateTime utc,
  IcsTimeZoneResolver resolver,
  String timezoneId,
) {
  final wall = resolver.utcToWall(timezoneId, utc);
  return wall == null ? null : dateKeyOfWall(wall);
}

/// 本地日期键（只取 wall 的 year/month/day 字段）。
String dateKeyOfWall(DateTime wall) => WallClockDateKey.of(wall);

/// 把本地日期 + 分钟（可 >= 1440）转成墙上 DateTime（供 resolveWall）。
DateTime _wall(String dateKey, int minute) {
  final base = dateKeyToUtc(dateKey);
  if (base == null) return DateTime.utc(1970);
  final days = minute ~/ 1440;
  final rest = minute % 1440;
  return DateTime.utc(
    base.year,
    base.month,
    base.day + days,
    rest ~/ 60,
    rest % 60,
  );
}

String _addDays(String dateKey, int days) {
  final base = dateKeyToUtc(dateKey);
  if (base == null) return dateKey;
  return dateKeyOfWall(base.add(Duration(days: days)));
}

String addDaysToDateKey(String dateKey, int days) => _addDays(dateKey, days);

/// 复用 yyyy-MM-dd 格式化：只在 expander 内部读取墙钟日期字段。
abstract final class WallClockDateKey {
  static String of(DateTime wall) =>
      '${_pad(wall.year, 4)}-${_pad(wall.month, 2)}-${_pad(wall.day, 2)}';

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');
}

/// 供展示层复用：把 UTC 时刻换成事件时区的墙钟 DateTime；未知时区返回 null。
DateTime? wallOf(DateTime utc, String timezoneId) {
  try {
    final location = tz.getLocation(timezoneId);
    return tz.TZDateTime.from(utc.toUtc(), location);
  } catch (_) {
    return null;
  }
}
