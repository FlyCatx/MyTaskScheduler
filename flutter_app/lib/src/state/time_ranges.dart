// The one and only "08:00-12:00, 14:00-18:00" parser.
//
// Weekly availability, date exceptions and course/activity/rest occupancy all call this
// file. If they each parsed their own way, the same text would mean different things in
// three places of the same dialog — that used to happen (`:` only, no `：`; `\d{2}`
// minutes only; `24:00` accepted as a start…).
//
// Grammar (accepted, in any combination):
//
//   separator between segments : `,`  `，`  `、`  `;`  `；`
//   separator between times    : `-`  `–`  `—`  `~`  `〜`  `至`  `到`
//   clock                      : `8`  `08`  `8:00`  `08：00`  `8： 00`
//   allowed whitespace         : around the clock parts and the dash
//
// Semantics:
//   * `8` and `08` both mean 08:00 (an hour without minutes is o'clock);
//   * empty text means "no window at all" — for a weekday that is "unavailable", never
//     24 hours;
//   * `24:00` is allowed as an **end** only (`08:00-24:00` = whole evening). `24:30`,
//     `25:00`, `8:60`, negative numbers and `24:00-…` starts are rejected;
//   * `00:00` as an end keeps its historical meaning of "end of day" (1440), so
//     `22:00-00:00` is 22:00→24:00 and not a negative window;
//   * an end earlier than the start is a cross-midnight window and is expressed in the
//     project's existing minute model: `22:00-02:00` becomes end minute **1560** (the
//     same model the planner and storage already use). It is never dropped;
//   * `08:00-08:00` (equal start and end) is rejected instead of guessed;
//   * `00:00-24:00` is a whole day (`isFullDay`);
//   * segments are sorted and overlapping/duplicate ones are merged, and the total is
//     computed from the merged list, so `8-12, 10-14` totals 6 hours, not 8.
//
// No I/O, no widgets: this file is pure and unit-tested directly.

import '../model/calendar.dart';

/// Outcome of [parseTimeRanges]. Exactly one of [ranges] / [error] is meaningful.
class TimeRangeParseResult {
  /// Normalized (sorted, merged) ranges. Empty means "no window".
  final List<WallClockRange> ranges;

  /// Human-readable reason the text was rejected, or null when it parsed.
  final String? error;

  const TimeRangeParseResult.ok(this.ranges) : error = null;
  const TimeRangeParseResult.failure(this.error) : ranges = const [];

  bool get ok => error == null;

  /// Merged duration in minutes (0 for an empty/unavailable day).
  int get totalMinutes =>
      ranges.fold<int>(0, (sum, r) => sum + r.durationMinutes);

  @override
  String toString() => ok
      ? 'TimeRangeParseResult(${formatTimeRanges(ranges)} / $totalMinutes min)'
      : 'TimeRangeParseResult.error($error)';
}

/// Segment separator: ASCII/full-width comma, ideographic comma, ASCII/full-width
/// semicolon.
final RegExp _segmentSplit = RegExp(r'[,，、;；]');

/// One `start-end` pair. Groups: 1 startH, 2 startM, 3 endH, 4 endM.
///
/// `^...$` with [RegExpMatch] only (no searching) is deliberate: a half-understood
/// string like `8-12xyz` must fail instead of yielding a made-up window.
final RegExp _rangePattern = RegExp(
  r'^\s*(\d{1,2})\s*(?:[:：]\s*(\d{1,2}))?\s*[-–—~〜至到]\s*'
  r'(\d{1,2})\s*(?:[:：]\s*(\d{1,2}))?\s*$',
);

/// Parses [text] into normalized wall-clock ranges.
///
/// Blank text is a valid empty result ("unavailable"), not an error.
TimeRangeParseResult parseTimeRanges(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const TimeRangeParseResult.ok(<WallClockRange>[]);
  }
  final parsed = <WallClockRange>[];
  for (final part in trimmed.split(_segmentSplit)) {
    final item = part.trim();
    if (item.isEmpty) continue;
    final m = _rangePattern.firstMatch(item);
    if (m == null) {
      return TimeRangeParseResult.failure(
        '无法识别的时段「$item」，请写成 08:00-12:00',
      );
    }
    final startHour = int.parse(m.group(1)!);
    final startMinute = m.group(2) == null ? 0 : int.parse(m.group(2)!);
    final endHour = int.parse(m.group(3)!);
    final endMinute = m.group(4) == null ? 0 : int.parse(m.group(4)!);

    if (startMinute > 59 || endMinute > 59) {
      return TimeRangeParseResult.failure('时间超出范围：「$item」');
    }
    // 24:00 is a legal *end* (end of day). 24:30 is not a time.
    if (startHour > 23 || endHour > 24 || (endHour == 24 && endMinute != 0)) {
      return TimeRangeParseResult.failure('时间超出范围：「$item」');
    }

    final start = startHour * 60 + startMinute;
    var end = endHour * 60 + endMinute;
    // Historical compatibility: an end of 00:00 means "end of day".
    if (end == 0) end = 1440;
    // Cross-midnight: `22:00-02:00` is start 1320 → end 1560 in the shared model.
    if (end < start) end += 1440;
    if (end == start) {
      return TimeRangeParseResult.failure('结束必须晚于开始：「$item」');
    }
    if (end - start > 1440) {
      return TimeRangeParseResult.failure('单个时段不能超过 24 小时：「$item」');
    }
    parsed.add(WallClockRange(start, end));
  }
  return TimeRangeParseResult.ok(mergeTimeRanges(parsed));
}

/// Convenience wrapper for the editor's `onError` callback style.
///
/// Returns null after calling [onError] when the text is invalid.
List<WallClockRange>? parseTimeRangesOrError(
  String text, {
  required void Function(String) onError,
}) {
  final result = parseTimeRanges(text);
  if (!result.ok) {
    onError(result.error!);
    return null;
  }
  return result.ranges;
}

/// Sorts and merges overlapping or touching ranges.
///
/// A merged range keeps its own start and the latest end. `8-12` + `10-14` becomes
/// `08:00-14:00`; duplicates collapse.
List<WallClockRange> mergeTimeRanges(List<WallClockRange> input) {
  if (input.isEmpty) return const <WallClockRange>[];
  final sorted = <WallClockRange>[...input]
    ..sort((a, b) {
      final byStart = a.startMinute.compareTo(b.startMinute);
      return byStart != 0 ? byStart : a.endMinute.compareTo(b.endMinute);
    });
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

/// Canonical display form: `08:00-12:00, 14:00-18:00`.
String formatTimeRanges(Iterable<WallClockRange> ranges) =>
    ranges.map(WallClockRange.format).join(', ');

/// Total (merged) minutes of [ranges].
int totalTimeRangeMinutes(Iterable<WallClockRange> ranges) =>
    mergeTimeRanges(ranges.toList(growable: false))
        .fold<int>(0, (sum, r) => sum + r.durationMinutes);

/// Human label for a duration, e.g. `112.0 小时` / `30 分钟`.
String formatTimeRangeTotal(int minutes) => minutes % 60 == 0
    ? '$minutes 分钟（${(minutes / 60).toStringAsFixed(1)} 小时）'
    : '$minutes 分钟';

