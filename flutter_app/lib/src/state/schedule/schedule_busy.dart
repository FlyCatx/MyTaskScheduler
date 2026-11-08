// 日程忙碌计算（task 3）：实例 → 规划时区的忙碌区间并集 + 指纹。
//
// 规则：
//   * 只有 blocksScheduling=true 的**定时**实例占用排程时间；全天日程不扣容量；
//   * 跨日按显示时区的午夜拆成多段，绝不出现负时长；
//   * 指纹只包含"最终有效忙碌区间并集 + 范围 + 时区"，按稳定顺序编码后
//     用 SHA-256；不含标题、备注、地点、关联、提醒或当前时间；
//   * 展开不完整（时区/DST/超限）时 fingerprint 为 null，调用方必须阻断或
//     提示不可用，不能把它当成"没有忙碌"。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../model/calendar.dart';
import '../../model/schedule_event.dart';
import '../ics/ics_timezones.dart';
import 'schedule_expander.dart';

/// 某本地日期上的一段忙碌（用于合成运行时时间表）。
class ScheduleBusyWallRange {
  const ScheduleBusyWallRange({
    required this.date,
    required this.start,
    required this.end,
  });

  final String date;
  final int start;
  final int end;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'start': start,
        'end': end,
      };
}

class ScheduleBusySnapshot {
  const ScheduleBusySnapshot({
    required this.fromUtc,
    required this.toUtc,
    required this.timezoneId,
    required this.intervals,
    required this.wallRanges,
    required this.fingerprint,
    required this.complete,
    required this.warnings,
  });

  final DateTime fromUtc;
  final DateTime toUtc;
  final String timezoneId;

  /// 合并后的 UTC 半开忙碌区间（规划范围）。
  final List<TimeInterval> intervals;

  /// 按显示时区拆好的本地日忙碌段（合成时间表/甘特用）。
  final List<ScheduleBusyWallRange> wallRanges;

  /// 完整时为 SHA-256；展开不完整/不可用时为 null。
  final String? fingerprint;

  final bool complete;
  final List<String> warnings;

  bool get available => complete && fingerprint != null;

  static ScheduleBusySnapshot unavailable({
    required DateTime fromUtc,
    required DateTime toUtc,
    required String timezoneId,
    required List<String> warnings,
  }) =>
      ScheduleBusySnapshot(
        fromUtc: fromUtc,
        toUtc: toUtc,
        timezoneId: timezoneId,
        intervals: const <TimeInterval>[],
        wallRanges: const <ScheduleBusyWallRange>[],
        fingerprint: null,
        complete: false,
        warnings: List<String>.unmodifiable(warnings),
      );
}

/// 计算 [fromUtc, toUtc) 范围内本地日程的忙碌并集与指纹。
ScheduleBusySnapshot computeScheduleBusy({
  required List<ScheduleEvent> events,
  required DateTime fromUtc,
  required DateTime toUtc,
  required String timezoneId,
  IcsTimeZoneResolver? resolver,
}) {
  if (!fromUtc.isBefore(toUtc) || timezoneId.trim().isEmpty) {
    return ScheduleBusySnapshot.unavailable(
      fromUtc: fromUtc,
      toUtc: toUtc,
      timezoneId: timezoneId,
      warnings: <String>['日程忙碌查询范围或时区不合法'],
    );
  }
  final expansion = expandScheduleEvents(
    events: events,
    query: ScheduleQuery(
      fromUtc: fromUtc,
      toUtc: toUtc,
      timezoneId: timezoneId,
    ),
  );
  final warnings = <String>[...expansion.warnings];
  final busy = <TimeInterval>[];
  for (final occurrence in expansion.occurrences) {
    if (!occurrence.blocksScheduling) continue;
    if (occurrence.allDay) continue;
    final start = occurrence.startUtc;
    final end = occurrence.endUtc;
    if (start == null || end == null || !end.isAfter(start)) continue;
    busy.add(TimeInterval(start, end));
  }
  final merged = mergeIntervals(busy);
  final tzResolver = resolver ?? IcsTimeZoneResolver();
  final wallRanges = <ScheduleBusyWallRange>[];
  for (final interval in merged) {
    final split = _splitWall(
      interval: interval,
      timezoneId: timezoneId,
      resolver: tzResolver,
      warnings: warnings,
    );
    if (split == null) {
      return ScheduleBusySnapshot.unavailable(
        fromUtc: fromUtc,
        toUtc: toUtc,
        timezoneId: timezoneId,
        warnings: warnings,
      );
    }
    wallRanges.addAll(split);
  }
  final complete = expansion.complete && !warnings.any(_isBlockingWarning);
  if (!complete) {
    return ScheduleBusySnapshot.unavailable(
      fromUtc: fromUtc,
      toUtc: toUtc,
      timezoneId: timezoneId,
      warnings: warnings,
    );
  }
  return ScheduleBusySnapshot(
    fromUtc: fromUtc,
    toUtc: toUtc,
    timezoneId: timezoneId,
    intervals: List<TimeInterval>.unmodifiable(merged),
    wallRanges: List<ScheduleBusyWallRange>.unmodifiable(wallRanges),
    fingerprint: scheduleBusyFingerprint(
      intervals: merged,
      fromUtc: fromUtc,
      toUtc: toUtc,
      timezoneId: timezoneId,
    ),
    complete: true,
    warnings: List<String>.unmodifiable(warnings),
  );
}

/// 只把会影响排程有效性的警告当阻塞；普通提示（例如某实例被跳过）也阻塞。
bool _isBlockingWarning(String warning) =>
    warning.contains('无法确定') ||
    warning.contains('无法解析') ||
    warning.contains('不合法') ||
    warning.contains('不晚于');

/// 稳定指纹：区间并集 + 范围 + 时区。
String scheduleBusyFingerprint({
  required List<TimeInterval> intervals,
  required DateTime fromUtc,
  required DateTime toUtc,
  required String timezoneId,
}) {
  final canonical = <String>[
    for (final interval in intervals)
      '${interval.start.toUtc().toIso8601String()}/${interval.end.toUtc().toIso8601String()}',
  ].join(';');
  final payload = <String>[
    fromUtc.toUtc().toIso8601String(),
    toUtc.toUtc().toIso8601String(),
    timezoneId,
    canonical,
  ].join('|');
  return sha256.convert(utf8.encode(payload)).toString();
}

List<ScheduleBusyWallRange>? _splitWall({
  required TimeInterval interval,
  required String timezoneId,
  required IcsTimeZoneResolver resolver,
  required List<String> warnings,
}) {
  final out = <ScheduleBusyWallRange>[];
  var cursor = interval.start.toUtc();
  final end = interval.end.toUtc();
  var guard = 0;
  while (cursor.isBefore(end) && guard < 400) {
    guard++;
    final wall = resolver.utcToWall(timezoneId, cursor);
    if (wall == null) {
      warnings.add('日程忙碌的显示时区无法解析：$timezoneId');
      return null;
    }
    final date = formatWallDate(wall);
    final startMinute = wall.hour * 60 + wall.minute;
    final nextDayMidnight = resolver.resolveWall(
      timezoneId,
      DateTime.utc(wall.year, wall.month, wall.day + 1),
    );
    final nextMidnightUtc = nextDayMidnight.utc;
    if (nextMidnightUtc == null) {
      warnings.add('日程忙碌的次日边界无法确定：${nextDayMidnight.detail}');
      return null;
    }
    final segmentEnd =
        nextMidnightUtc.isBefore(end) ? nextMidnightUtc : end;
    final endWall = resolver.utcToWall(timezoneId, segmentEnd);
    int endMinute;
    if (endWall == null) {
      endMinute = 1440;
    } else if (formatWallDate(endWall) != date) {
      endMinute = 1440;
    } else {
      endMinute = endWall.hour * 60 + endWall.minute;
    }
    if (endMinute <= startMinute) {
      // DST 边界造成的非正段：明确不完整，不静默丢弃。
      warnings.add('日程忙碌在 $date 的本地区间不合法');
      return null;
    }
    out.add(ScheduleBusyWallRange(
      date: date,
      start: startMinute,
      end: endMinute > 1440 ? 1440 : endMinute,
    ));
    cursor = segmentEnd;
  }
  return out;
}

/// 显示时区的本地日期键。
String formatWallDate(DateTime wall) {
  final y = wall.year.toString().padLeft(4, '0');
  final m = wall.month.toString().padLeft(2, '0');
  final d = wall.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
