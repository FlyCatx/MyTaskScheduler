// ICS 时区解析：IANA 时区数据库 + 文件内 VTIMEZONE。
//
// 选型：用 `package:timezone`（Dart 官方、BSD-3），数据来自 bundled IANA tzdb。
// 为什么不自己按 VTIMEZONE 里的 STANDARD/DAYLIGHT 规则算：
//   * 文件内规则只能描述“某年”的偏移，跨年/跨 DST 的重复展开很容易算错；
//   * IANA 数据库已经处理了历史变更、半小时时区与政治性变更；
//   * 但**绝不猜**：文件里的 TZID 如果映射不到 IANA（或只给出了无法映射的
//     自定义规则），就明确标记不支持，让提取阶段拒绝受影响的事件，而不是
//     悄悄按 Asia/Shanghai 解释。
//
// VTIMEZONE 的处理策略（合同 3.4）：
//   1. TZID 本身是 IANA 名（`Asia/Shanghai`）→ 直接用；
//   2. 带前缀的 IANA 名（`/freeassociation.sourceforge.net/America/New_York`）
//      → 去掉前缀后按后缀匹配；
//   3. 常见 Windows 时区名（`China Standard Time`）→ 用内置别名表映射；
//   4. 只有 STANDARD 的**整小时**固定偏移 → 映射到 `Etc/GMT±N`（可持久化、
//      之后在没有原文件的情况下也能解析）；
//   5. 其余（自定义 DST 规则、非整小时固定偏移）→ 标记不支持并记录原因。
//
// DST 语义（合同 3.4 / 3.5）：
//   * 缺失的墙上时间（spring-forward 的 02:30）→ 解析失败，调用方拒绝该实例并
//     记 warning，绝不把它当成空闲；
//   * 重复的墙上时间（fall-back 出现两次的 01:30）→ 同样拒绝并记 warning，
//     因为无法判断用户指的是哪一次。

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ics_parser.dart';

/// 墙上时间 → UTC 的失败原因。
enum IcsWallError {
  /// TZID 未知，或文件内 VTIMEZONE 无法映射到 IANA。
  unknownZone,

  /// 该墙上时间因 DST 前跳而不存在。
  nonexistent,

  /// 该墙上时间因 DST 回拨而出现两次。
  ambiguous,
}

/// `wallToUtc` 的完整结果（供调用方生成精确 warning）。
class IcsWallConversion {
  const IcsWallConversion.ok(DateTime this.utc)
      : error = null,
        detail = '';

  const IcsWallConversion.failed(this.error, this.detail) : utc = null;

  final DateTime? utc;
  final IcsWallError? error;
  final String detail;

  bool get isOk => utc != null;

  /// 稳定的 warning code。
  String get warningCode => switch (error) {
        IcsWallError.unknownZone => 'unknown-timezone',
        IcsWallError.nonexistent => 'dst-gap',
        IcsWallError.ambiguous => 'dst-ambiguous',
        null => '',
      };

  @override
  String toString() =>
      isOk ? 'IcsWallConversion(${utc!.toIso8601String()})' : 'IcsWallConversion(${error?.name}: $detail)';
}

/// 解析 TZID。
class IcsTimeZoneResolver {
  /// [initializeDatabase] 只在测试里关掉（默认确保 IANA 数据已载入）。
  IcsTimeZoneResolver({bool initializeDatabase = true}) {
    if (initializeDatabase) ensureDatabase();
  }

  static bool _databaseReady = false;

  /// 幂等初始化 IANA 数据库（`package:timezone/data/latest.dart`）。
  static void ensureDatabase() {
    if (_databaseReady) return;
    tzdata.initializeTimeZones();
    _databaseReady = true;
  }

  /// 文件里的 TZID → 规范 IANA 名（来自 VTIMEZONE 或内置别名）。
  final Map<String, String> _aliases = <String, String>{};

  /// 无法映射的 TZID → 原因（用于 warning 文案）。
  final Map<String, String> _unsupported = <String, String>{};

  static final Map<String, String> _windowsAliases = <String, String>{
    'china standard time': 'Asia/Shanghai',
    'taipei standard time': 'Asia/Taipei',
    'tokyo standard time': 'Asia/Tokyo',
    'korea standard time': 'Asia/Seoul',
    'singapore standard time': 'Asia/Singapore',
    'india standard time': 'Asia/Kolkata',
    'utc': 'UTC',
    'co-ordinated universal time': 'UTC',
    'gmt standard time': 'Europe/London',
    'w. europe standard time': 'Europe/Berlin',
    'central europe standard time': 'Europe/Budapest',
    'central european standard time': 'Europe/Warsaw',
    'romance standard time': 'Europe/Paris',
    'e. europe standard time': 'Europe/Chisinau',
    'eastern standard time': 'America/New_York',
    'central standard time': 'America/Chicago',
    'mountain standard time': 'America/Denver',
    'pacific standard time': 'America/Los_Angeles',
    'aus eastern standard time': 'Australia/Sydney',
  };

  /// 注册文件内 VTIMEZONE（可多次调用）。无法映射时记录原因，不抛异常。
  void addFromVtimezone(IcalComponent vtimezone) {
    if (vtimezone.name != 'VTIMEZONE') return;
    final raw = vtimezone.property('TZID')?.value;
    if (raw == null) return;
    final tzid = unescapeText(raw).trim();
    if (tzid.isEmpty) return;
    if (isKnown(tzid)) return;
    final canonical = _lookupIana(tzid);
    if (canonical != null) {
      _aliases[tzid] = canonical;
      return;
    }
    // 只有 STANDARD、整小时固定偏移 → Etc/GMT±N。
    final fixed = _fixedOffsetEtc(tzid, vtimezone);
    if (fixed != null) {
      _aliases[tzid] = fixed;
      return;
    }
    final hasDaylight = vtimezone.children.any((c) => c.name == 'DAYLIGHT');
    _unsupported[tzid] = hasDaylight
        ? '文件内 VTIMEZONE 使用了自定义夏令时规则，无法映射到 IANA 时区'
        : '文件内 VTIMEZONE 的固定偏移不是整小时，无法映射到 Etc/GMT 时区';
  }

  /// 一次性注册树里的所有 VTIMEZONE。
  void addAllFromTree(IcalComponent calendar) {
    for (final component in calendar.allNamed('VTIMEZONE')) {
      addFromVtimezone(component);
    }
  }

  /// 该 TZID 能否解析（`UTC` 与 IANA 名都算已知）。
  bool isKnown(String tzid) => _locationOf(tzid) != null;

  /// 规范 IANA 名；未知返回 null。持久化时应当保存这个值。
  String? canonicalIdOf(String tzid) {
    final text = tzid.trim();
    if (text.isEmpty) return null;
    final alias = _aliases[text];
    if (alias != null) return alias;
    if (_isUtcAlias(text)) return 'UTC';
    final direct = _lookupIana(text);
    if (direct != null) return direct;
    return null;
  }

  /// 已知但无法映射的 TZID 的原因。
  String? unsupportedReason(String tzid) => _unsupported[tzid.trim()];

  /// 解析墙上时间 → UTC。失败返回 null（详见 [resolveWall]）。
  DateTime? wallToUtc(String tzid, DateTime wall) => resolveWall(tzid, wall).utc;

  /// 墙上时间 → UTC 的完整结果，含失败原因。
  ///
  /// [wall] 只取 year/month/day/hour/minute/second 字段，`isUtc` 标志无意义。
  IcsWallConversion resolveWall(String tzid, DateTime wall) {
    final location = _locationOf(tzid);
    if (location == null) {
      final reason = _unsupported[tzid.trim()] ?? '未知时区 TZID：$tzid';
      return IcsWallConversion.failed(IcsWallError.unknownZone, reason);
    }
    final wallUtcMs = DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
            wall.minute, wall.second)
        .millisecondsSinceEpoch;
    final offsets = <int>{};
    for (final probeHours in const <int>[-26, -13, 0, 13, 26]) {
      offsets.add(
          location.timeZone(wallUtcMs + probeHours * 3600 * 1000).offset.inMilliseconds);
    }
    final candidates = <int>{};
    for (final offset in offsets) {
      final instant = wallUtcMs - offset;
      final back = location.timeZone(instant).offset.inMilliseconds;
      if (instant + back == wallUtcMs) candidates.add(instant);
    }
    final label = _formatWall(wall);
    if (candidates.isEmpty) {
      return IcsWallConversion.failed(
        IcsWallError.nonexistent,
        '时区 $tzid 在 $label 因夏令时前跳不存在',
      );
    }
    if (candidates.length > 1) {
      return IcsWallConversion.failed(
        IcsWallError.ambiguous,
        '时区 $tzid 的 $label 因夏令时回拨出现两次，无法确定指哪一次',
      );
    }
    return IcsWallConversion.ok(
      DateTime.fromMillisecondsSinceEpoch(candidates.first, isUtc: true),
    );
  }

  /// UTC → 墙上时间（带 location 的 TZDateTime；读取 year/month/day/hour/minute
  /// 得到的是该时区的墙上值）。未知时区返回 null。
  DateTime? utcToWall(String tzid, DateTime utc) {
    final location = _locationOf(tzid);
    if (location == null) return null;
    return tz.TZDateTime.from(utc.toUtc(), location);
  }

  /// 某时刻在该时区的偏移（分钟）；未知时区返回 null。
  int? offsetMinutesAt(String tzid, DateTime utc) {
    final location = _locationOf(tzid);
    if (location == null) return null;
    return location.timeZone(utc.toUtc().millisecondsSinceEpoch).offset.inMinutes;
  }

  /// `yyyy-MM-dd` 形式，仅用于文案。
  static String _formatWall(DateTime wall) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${wall.year.toString().padLeft(4, '0')}-${two(wall.month)}-'
        '${two(wall.day)} ${two(wall.hour)}:${two(wall.minute)}:${two(wall.second)}';
  }

  // ------------------------------------------------------------- internals

  tz.Location? _locationOf(String tzid) {
    final text = tzid.trim();
    if (text.isEmpty) return null;
    final alias = _aliases[text];
    if (alias != null) return _tryLocation(alias);
    if (_isUtcAlias(text)) return tz.UTC;
    final direct = _lookupIana(text);
    if (direct == null) return null;
    return _tryLocation(direct);
  }

  static bool _isUtcAlias(String text) {
    final upper = text.toUpperCase();
    return upper == 'UTC' || upper == 'Z' || upper == 'GMT' || upper == 'ETC/UTC';
  }

  static tz.Location? _tryLocation(String name) {
    try {
      return tz.getLocation(name);
    } catch (_) {
      return null;
    }
  }

  static Map<String, String>? _lowercaseIndex;

  /// 直接名、去前缀后的后缀、大小写不敏感、Windows 别名。
  static String? _lookupIana(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (_tryLocation(text) != null) return text;
    // 去掉前导 '/' 后重试（`/Europe/Berlin`）。
    var trimmed = text;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    if (trimmed.isNotEmpty && trimmed != text && _tryLocation(trimmed) != null) {
      return trimmed;
    }
    // 逐段后缀匹配：`/freeassociation.sourceforge.net/America/New_York`
    // → `America/New_York`。
    final parts = trimmed.split('/');
    for (var i = 1; i < parts.length; i++) {
      final candidate = parts.sublist(i).join('/');
      if (candidate.isEmpty) continue;
      if (_tryLocation(candidate) != null) return candidate;
    }
    // Windows 时区名。
    final windows = _windowsAliases[trimmed.toLowerCase()];
    if (windows != null && _tryLocation(windows) != null) return windows;
    // 大小写不敏感的最后尝试。
    _lowercaseIndex ??= <String, String>{
      for (final name in tz.timeZoneDatabase.locations.keys)
        name.toLowerCase(): name,
    };
    final lower = _lowercaseIndex![trimmed.toLowerCase()];
    if (lower != null && _tryLocation(lower) != null) return lower;
    return null;
  }

  /// 只含 STANDARD 且偏移为整小时的 VTIMEZONE → `Etc/GMT±N`。
  static String? _fixedOffsetEtc(String tzid, IcalComponent vtimezone) {
    if (vtimezone.children.any((c) => c.name == 'DAYLIGHT')) return null;
    final standard = vtimezone.childrenNamed('STANDARD');
    if (standard.isEmpty) return null;
    final offsets = <int>{};
    for (final block in standard) {
      final minutes = _parseUtcOffset(block.property('TZOFFSETTO')?.value);
      if (minutes == null) return null;
      offsets.add(minutes);
    }
    if (offsets.length != 1) return null;
    final minutes = offsets.first;
    if (minutes % 60 != 0) return null;
    final hours = minutes ~/ 60;
    if (hours < -14 || hours > 12) return null;
    // IANA 的 Etc/GMT 符号与直觉相反：`Etc/GMT-8` 是 UTC+8。
    final name = hours == 0 ? 'Etc/GMT' : 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}';
    if (_tryLocation(name) != null) return name;
    if (hours == 0 && _tryLocation('Etc/UTC') != null) return 'Etc/UTC';
    return null;
  }

  /// RFC 5545 UTC-OFFSET：`±HHMM[SS]`。
  static int? _parseUtcOffset(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.length != 5 && text.length != 7) return null;
    final signChar = text[0];
    if (signChar != '+' && signChar != '-') return null;
    final body = text.substring(1);
    for (var i = 0; i < body.length; i++) {
      final code = body.codeUnitAt(i);
      if (code < 0x30 || code > 0x39) return null;
    }
    final hours = int.parse(body.substring(0, 2));
    final minutes = int.parse(body.substring(2, 4));
    final seconds = text.length == 7 ? int.parse(body.substring(4, 6)) : 0;
    if (hours > 23 || minutes > 59 || seconds > 59) return null;
    final total = hours * 60 + minutes + (seconds > 0 ? 1 : 0);
    return signChar == '-' ? -total : total;
  }
}
