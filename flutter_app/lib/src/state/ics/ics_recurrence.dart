// RRULE 属性值的解析与校验（内部共用文件）。
//
// 为什么不用 `RecurrenceRule.fromString` 直接吃整串：
//   * 它把 `UNTIL=...Z` 的 `Z` 去掉后当成“墙上时间”，而 RFC 规定带 Z 的 UNTIL
//     是 UTC 时刻；对 America/New_York 这类时区，直接交给它会在换季前后多/少
//     展开一次。这里把 UNTIL 摘出来，在展开时用正确的域（UTC 或源墙上时间）
//     比较；其余参数原样交给 rrule 包计算。
//   * 它遇到不认识的参数名会**静默忽略**；对我们来说“影响时间但不支持的规则”
//     必须显式拒绝，所以在交给它之前先检查参数名白名单。
//
// 支持的范围：FREQ=SECONDLY/MINUTELY/HOURLY/DAILY/WEEKLY/MONTHLY/YEARLY，
// INTERVAL/COUNT/BYDAY/BYMONTHDAY/BYMONTH/BYYEARDAY/BYWEEKNO/BYSETPOS/BYSECOND/
// BYMINUTE/BYHOUR/BYSETPOS，WKST=MO（其他 WKST 由 rrule 抛错 → 拒绝）。

import 'package:rrule/rrule.dart';

/// 允许出现在 RRULE 里的参数名（其余一律视为不支持）。
const Set<String> _allowedParts = <String>{
  'FREQ',
  'UNTIL',
  'COUNT',
  'INTERVAL',
  'BYSECOND',
  'BYMINUTE',
  'BYHOUR',
  'BYDAY',
  'BYMONTHDAY',
  'BYYEARDAY',
  'BYWEEKNO',
  'BYMONTH',
  'BYSETPOS',
  'WKST',
};

/// RRULE 的解析结果。`rule == null` 表示不支持/非法，[error] 给出中文原因。
class IcsRecurrenceRule {
  const IcsRecurrenceRule._({
    this.rule,
    this.untilUtc,
    this.untilWall,
    this.untilDateOnly = false,
    this.errorCode,
    this.error,
  });

  /// 交给 rrule 包计算的部分（UNTIL 已被摘除）。
  final RecurrenceRule? rule;

  /// `UNTIL=...Z`：UTC 时刻（含）。
  final DateTime? untilUtc;

  /// `UNTIL=...`（不带 Z）：源墙上时间/日期（含）。
  final DateTime? untilWall;

  /// UNTIL 是纯日期（VALUE=DATE 语义）。
  final bool untilDateOnly;

  final String? errorCode;
  final String? error;

  bool get isSupported => rule != null;

  static IcsRecurrenceRule unsupported(String code, String message) =>
      IcsRecurrenceRule._(errorCode: code, error: message);

  /// 解析 RRULE 属性值（允许带 `RRULE:` 前缀）。空值返回 null。
  static IcsRecurrenceRule? parse(String? rawValue) {
    if (rawValue == null) return null;
    var text = rawValue.trim();
    if (text.isEmpty) return null;
    if (text.length >= 6 && text.substring(0, 6).toUpperCase() == 'RRULE:') {
      text = text.substring(6);
    }
    if (text.trim().isEmpty) {
      return unsupported('unsupported-rrule', '重复规则缺少内容');
    }

    final kept = <String>[];
    String? untilRaw;
    var countSeen = false;
    for (final part in text.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) {
        return unsupported(
            'unsupported-rrule', '重复规则参数不合法：$part');
      }
      final name = trimmed.substring(0, eq).trim().toUpperCase();
      final value = trimmed.substring(eq + 1).trim();
      if (!_allowedParts.contains(name)) {
        return unsupported(
            'unsupported-rrule-part', '不支持的重复规则参数 $name');
      }
      if (name == 'UNTIL') {
        untilRaw = value;
        continue;
      }
      if (name == 'COUNT') countSeen = true;
      kept.add('$name=$value');
    }
    if (untilRaw != null && countSeen) {
      return unsupported(
          'unsupported-rrule', '重复规则同时指定了 UNTIL 与 COUNT');
    }

    DateTime? untilUtc;
    DateTime? untilWall;
    var untilDateOnly = false;
    if (untilRaw != null) {
      final parsed = _parseUntil(untilRaw);
      if (parsed == null) {
        return unsupported(
            'unsupported-rrule', '重复规则的 UNTIL 不是合法时间：$untilRaw');
      }
      untilUtc = parsed.utc;
      untilWall = parsed.wall;
      untilDateOnly = parsed.dateOnly;
    }

    final RecurrenceRule rule;
    try {
      rule = RecurrenceRule.fromString('RRULE:${kept.join(';')}');
    } on FormatException catch (e) {
      return unsupported(
          'unsupported-rrule', '不支持的重复规则（${e.message}）');
    } on Object catch (e) {
      return unsupported('unsupported-rrule', '不支持的重复规则（$e）');
    }
    return IcsRecurrenceRule._(
      rule: rule,
      untilUtc: untilUtc,
      untilWall: untilWall,
      untilDateOnly: untilDateOnly,
    );
  }

  /// 是否无界（既没有 COUNT 也没有 UNTIL）。
  bool get isUnbounded => rule != null && rule!.count == null && untilUtc == null && untilWall == null;

  static ({DateTime? utc, DateTime? wall, bool dateOnly})? _parseUntil(
      String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final isUtc = text.endsWith('Z') || text.endsWith('z');
    final body = isUtc ? text.substring(0, text.length - 1) : text;
    if (body.length == 8) {
      final date = _parseDate(body);
      if (date == null) return null;
      final wall = DateTime.utc(date.year, date.month, date.day);
      if (isUtc) {
        return (utc: wall, wall: null, dateOnly: true);
      }
      return (utc: null, wall: wall, dateOnly: true);
    }
    final wall = _parseDateTime(body);
    if (wall == null) return null;
    if (isUtc) {
      return (utc: DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
          wall.minute, wall.second), wall: null, dateOnly: false);
    }
    return (utc: null, wall: wall, dateOnly: false);
  }

  static DateTime? _parseDate(String text) {
    if (text.length != 8) return null;
    final year = int.tryParse(text.substring(0, 4));
    final month = int.tryParse(text.substring(4, 6));
    final day = int.tryParse(text.substring(6, 8));
    if (year == null || month == null || day == null) return null;
    final value = DateTime.utc(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    return value;
  }

  static DateTime? _parseDateTime(String text) {
    if (text.length != 15 || text[8] != 'T') return null;
    final date = _parseDate(text.substring(0, 8));
    if (date == null) return null;
    final hour = int.tryParse(text.substring(9, 11));
    final minute = int.tryParse(text.substring(11, 13));
    final second = int.tryParse(text.substring(13, 15));
    if (hour == null || minute == null || second == null) return null;
    if (hour > 23 || minute > 59 || second > 60) return null;
    return DateTime.utc(
        date.year, date.month, date.day, hour, minute, second > 59 ? 59 : second);
  }

  @override
  String toString() => isSupported
      ? 'IcsRecurrenceRule(${rule.toString()})'
      : 'IcsRecurrenceRule(error=$errorCode: $error)';
}
