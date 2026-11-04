// 重复事件展开：源“墙上时间” + 时区解析 → 绝对 UTC 区间 → 按规划日拆分。
//
// 关键设计（合同 3.5）：
//   * RRULE 用 `package:rrule` 计算。rrule 明确“不关心时区”，要求 start/until
//     都是 `isUtc: true` 的 naive DateTime；这正好就是“墙上时间”的表示：我们
//     把源时区的墙上时刻（09:00 之类）原样喂给它，展开出的每个墙上时刻再用
//     [IcsTimeZoneResolver] 映射成 UTC。这样夏令时切换日也能保持“每天 09:00”
//     而不是“每 24 小时”。
//   * UNTIL 由 ics_recurrence.dart 摘出来单独比较：带 Z 的在 UTC 域比较，
//     不带 Z 的在源墙上时间域比较。
//   * RDATE 追加、EXDATE 排除、RECURRENCE-ID 覆盖（含单实例取消）、整系列取消
//     都在这里处理；`RANGE=THISANDFUTURE` 之类不支持的规则在提取阶段就整系列
//     拒绝，这里只做防御性检查。
//   * DST 缺失/重复的墙上时间**拒绝该实例并 warning**，绝不当成空闲。
//   * 资源限制（IcsLimits）触发时明确 warning 并置 `truncated = true`，不静默
//     截断后宣称完整。
//   * 秒精度：实例区间保留原始秒；输出到 [ExternalBusyInstance] 时起点
//     floor、终点 ceil 到分钟（保守外扩，宁可多占一分钟也不漏占）。

import '../../model/calendar.dart' show WallClock;
import '../../model/external_calendar.dart';
import 'ics_recurrence.dart';
import 'ics_timezones.dart';

/// 单次导入/展开的资源上限。
class IcsLimits {
  const IcsLimits({
    this.maxFileBytes = 8 * 1024 * 1024,
    this.maxEvents = 5000,
    this.maxInstances = 20000,
    this.maxRangeDays = 400,
  });

  /// ICS 文件字节数上限（超出直接失败，不读取）。
  final int maxFileBytes;

  /// 文件里 VEVENT 条数上限（超出部分明确 warning 并忽略）。
  final int maxEvents;

  /// 展开实例数上限（超出明确 warning 并停止，truncated=true）。
  final int maxInstances;

  /// 单次展开覆盖的自然日上限（超出时截断并明确 warning）。
  final int maxRangeDays;

  bool get isValid =>
      maxFileBytes > 0 &&
      maxEvents > 0 &&
      maxInstances > 0 &&
      maxRangeDays > 0;
}

/// 一次展开的结果。
class IcsExpansion {
  const IcsExpansion({
    this.instances = const <ExternalBusyInstance>[],
    this.warnings = const <ExtImportWarning>[],
    this.stats = const ExtImportStats(),
    this.truncated = false,
  });

  /// 展开后的占用实例（按规划日拆分，已按开始时间排序）。
  final List<ExternalBusyInstance> instances;

  final List<ExtImportWarning> warnings;

  /// 展开侧的统计：instances/busyMinutes/tentativeInstances 等由这里填；
  /// readEvents/unsupportedCount 由提取侧填（service 负责合并）。
  final ExtImportStats stats;

  /// 是否因资源上限被截断；为 true 时调用方必须提示“结果不完整”。
  final bool truncated;

  bool get isEmpty => instances.isEmpty;
}

/// 展开 [events] 在 `[fromUtc, toUtc)` 内的全部占用实例。
///
/// * [sourceId]：可选（合同签名之外的新增可选参数）。实例上的 sourceId 由来源
///   决定；service 逐来源展开时传入。为空时实例 sourceId 为空串。
/// * [planningTimezoneId]：可选（合同签名之外的新增可选参数）。`dayKey/
///   startMinute/endMinute` 用的规划时区；为空时退化为第一条事件的源时区，
///   再退化为 `UTC`。service.busyFor 会传入真实规划时区。
/// * [newId]：合同保留参数；[ExternalBusyInstance] 目前没有 id 字段，暂不使用。
IcsExpansion expandIcsEvents(
  List<ExternalEventRecord> events, {
  required DateTime fromUtc,
  required DateTime toUtc,
  required IcsTimeZoneResolver zones,
  required ExternalCalendarPolicy policy,
  required IcsLimits limits,
  String Function()? newId,
  String sourceId = '',
  String planningTimezoneId = '',
}) {
  final warnings = <ExtImportWarning>[];
  var truncated = false;
  final instances = <ExternalBusyInstance>[];
  var expandedInstances = 0;
  var busyMinutes = 0;
  var tentativeInstances = 0;
  var transparentEvents = 0;
  var cancelledEvents = 0;
  for (final event in events) {
    if (event.isTransparent) transparentEvents++;
    if (event.isCancelled) cancelledEvents++;
  }

  if (!toUtc.isAfter(fromUtc)) {
    warnings.add(const ExtImportWarning(
        'empty-range', '展开范围为空（结束不晚于开始），未产生任何占用'));
    return IcsExpansion(
      warnings: warnings,
      stats: ExtImportStats(
        transparentEvents: transparentEvents,
        cancelledEvents: cancelledEvents,
        warningCount: warnings.length,
      ),
    );
  }

  var effectiveTo = toUtc;
  final maxSpan = Duration(days: limits.maxRangeDays);
  if (toUtc.difference(fromUtc) > maxSpan) {
    effectiveTo = fromUtc.add(maxSpan);
    truncated = true;
    warnings.add(ExtImportWarning(
      'range-clamped',
      '展开范围超过 ${limits.maxRangeDays} 天上限，只展开前 ${limits.maxRangeDays} 天；'
          '本次结果不完整',
    ));
  }

  // 规划时区：决定 dayKey / 分钟切分，必须能解析。
  var planningTz = planningTimezoneId.trim();
  if (planningTz.isEmpty && events.isNotEmpty) {
    planningTz = events.first.timezoneId;
  }
  if (planningTz.isEmpty) planningTz = 'UTC';
  if (!zones.isKnown(planningTz)) {
    warnings.add(ExtImportWarning(
      'unknown-planning-timezone',
      '规划时区 $planningTz 无法解析，占用按 UTC 自然日切分',
    ));
    planningTz = 'UTC';
  }

  // 按 UID 分组：系列主体 + 单次覆盖。保持确定性顺序。
  final byUid = <String, List<ExternalEventRecord>>{};
  for (final event in events) {
    byUid.putIfAbsent(event.uid, () => <ExternalEventRecord>[]).add(event);
  }
  final uids = byUid.keys.toList()..sort();

  final startFrom = fromUtc.toUtc();
  final startTo = effectiveTo.toUtc();
  final budget = _GenerationBudget(limits.maxInstances * 2);
  var limitHit = false;
  final warnedDst = <String>{};

  void addWarning(String code, String message, String uid) {
    // 同一个 UID 的同一种 DST 问题只报一次，避免 400 天 × 每天一条。
    if (!warnedDst.add('$uid|$code')) return;
    warnings.add(ExtImportWarning(code, message, uid: uid));
  }

  void emit(_Occurrence occurrence) {
    if (limitHit) return;
    if (occurrence.record.isCancelled) return;
    final rawStart = occurrence.startUtc;
    final rawEnd = occurrence.endUtc;
    if (!rawEnd.isAfter(rawStart)) return; // 零长度事件不占时间
    final clippedStart = rawStart.isBefore(startFrom) ? startFrom : rawStart;
    final clippedEnd = rawEnd.isAfter(startTo) ? startTo : rawEnd;
    if (!clippedEnd.isAfter(clippedStart)) return;
    if (expandedInstances >= limits.maxInstances) {
      limitHit = true;
      truncated = true;
      warnings.add(ExtImportWarning(
        'instance-limit',
        '展开实例数超过 ${limits.maxInstances} 上限，结果被截断；本次结果不完整',
        uid: occurrence.record.uid,
      ));
      return;
    }
    expandedInstances++;
    final busy = _countsAsBusy(occurrence.record, policy);
    if (busy) {
      busyMinutes += clippedEnd.difference(clippedStart).inMinutes;
    }
    if (occurrence.record.isTentative) tentativeInstances++;
    final parts = _splitByPlanningDay(
      occurrence: occurrence,
      busy: busy,
      planningTz: planningTz,
      zones: zones,
      sourceId: sourceId,
      from: clippedStart,
      to: clippedEnd,
    );
    instances.addAll(parts);
  }

  for (final uid in uids) {
    if (limitHit) break;
    final group = byUid[uid]!;
    final masters = group.where((e) => !e.isOverride).toList();
    final overrides = group.where((e) => e.isOverride).toList();
    final master = _pickMaster(masters);
    final overrideByOriginal = <String, ExternalEventRecord>{};
    for (final override in overrides) {
      final key = _normalizeInstant(override.recurrenceId);
      if (key == null) continue;
      final existing = overrideByOriginal[key];
      if (existing == null || _preferOverride(override, existing)) {
        overrideByOriginal[key] = override;
      }
    }

    // 1) 系列主体展开（整系列取消时不展开）。
    final baseOccurrences = <_Occurrence>[];
    if (master != null && !master.isCancelled) {
      baseOccurrences.addAll(_expandRecord(
        master,
        zones: zones,
        fromUtc: startFrom,
        toUtc: startTo,
        limits: limits,
        addWarning: addWarning,
        budget: budget,
      ));
    }

    // 2) RECURRENCE-ID 覆盖：命中原始实例的替换/取消，其余覆盖单独成实例。
    final consumed = <String>{};
    for (final occurrence in baseOccurrences) {
      final key = isoUtcOf(occurrence.startUtc);
      final override = overrideByOriginal[key];
      if (override == null) {
        emit(occurrence);
        continue;
      }
      consumed.add(key);
      if (override.isCancelled) continue;
      emit(_Occurrence(
        record: override,
        startUtc: override.startUtcInstant,
        endUtc: override.endUtcInstant,
      ));
    }
    for (final entry in overrideByOriginal.entries) {
      if (consumed.contains(entry.key)) continue;
      final override = entry.value;
      if (override.isCancelled) continue;
      emit(_Occurrence(
        record: override,
        startUtc: override.startUtcInstant,
        endUtc: override.endUtcInstant,
      ));
    }
  }

  // 稳定排序：开始时间升序，再按 uid / 来源。
  instances.sort((a, b) {
    final byStart = a.startUtc.compareTo(b.startUtc);
    if (byStart != 0) return byStart;
    final byUid = a.uid.compareTo(b.uid);
    if (byUid != 0) return byUid;
    return a.dayKey.compareTo(b.dayKey);
  });

  return IcsExpansion(
    instances: List<ExternalBusyInstance>.unmodifiable(instances),
    warnings: List<ExtImportWarning>.unmodifiable(warnings),
    truncated: truncated,
    stats: ExtImportStats(
      expandedInstances: expandedInstances,
      busyMinutes: busyMinutes,
      transparentEvents: transparentEvents,
      cancelledEvents: cancelledEvents,
      tentativeInstances: tentativeInstances,
      warningCount: warnings.length,
    ),
  );
}

// ------------------------------------------------------------------ internals

class _Occurrence {
  const _Occurrence({
    required this.record,
    required this.startUtc,
    required this.endUtc,
  });

  final ExternalEventRecord record;
  final DateTime startUtc;
  final DateTime endUtc;
}

/// 生成阶段的全局预算：防止“很多条无界 SECONDLY 规则”把 CPU/内存打满。
class _GenerationBudget {
  _GenerationBudget(this.remaining);

  int remaining;
}

/// 系列主体：SEQUENCE 高者优先，其次 DTSTAMP 新者优先。
ExternalEventRecord? _pickMaster(List<ExternalEventRecord> masters) {
  if (masters.isEmpty) return null;
  final sorted = masters.toList()
    ..sort((a, b) {
      final bySequence = b.sequence.compareTo(a.sequence);
      if (bySequence != 0) return bySequence;
      final byStamp = b.dtstamp.compareTo(a.dtstamp);
      if (byStamp != 0) return byStamp;
      return a.startUtc.compareTo(b.startUtc);
    });
  return sorted.first;
}

bool _preferOverride(ExternalEventRecord candidate, ExternalEventRecord current) {
  if (candidate.sequence != current.sequence) {
    return candidate.sequence > current.sequence;
  }
  return candidate.dtstamp.compareTo(current.dtstamp) >= 0;
}

/// 按来源策略判断该事件是否算占用。
bool _countsAsBusy(
    ExternalEventRecord record, ExternalCalendarPolicy policy) {
  if (record.isCancelled) return false;
  switch (policy.busyPolicy) {
    case ExternalBusyPolicy.opaqueOnly:
      if (record.isTransparent || record.isTentative) return false;
      return true;
    case ExternalBusyPolicy.tentativeCountsAsBusy:
      if (record.isTransparent) return false;
      return true;
    case ExternalBusyPolicy.allCountsAsBusy:
      return true;
  }
}

/// 展开一条事件（系列主体）在范围内的候选实例。
///
/// 返回的候选尚未做范围裁剪（由 [expandIcsEvents] 的 emit 统一裁剪）。
List<_Occurrence> _expandRecord(
  ExternalEventRecord record, {
  required IcsTimeZoneResolver zones,
  required DateTime fromUtc,
  required DateTime toUtc,
  required IcsLimits limits,
  required void Function(String code, String message, String uid) addWarning,
  required _GenerationBudget budget,
}) {
  final tzid = record.timezoneId;
  if (!zones.isKnown(tzid)) {
    addWarning(
      'unknown-timezone',
      '事件 ${record.uid} 的时区 $tzid 无法解析，已跳过该事件',
      record.uid,
    );
    return const <_Occurrence>[];
  }
  final wallOfStart = zones.utcToWall(tzid, record.startUtcInstant);
  if (wallOfStart == null) {
    addWarning(
      'unknown-timezone',
      '事件 ${record.uid} 的时区 $tzid 无法解析，已跳过该事件',
      record.uid,
    );
    return const <_Occurrence>[];
  }
  final wallStart = _naiveWall(wallOfStart);
  final duration = record.duration;
  final excluded = <String>{};
  for (final raw in record.exdateUtc) {
    final key = _normalizeInstant(raw);
    if (key != null) excluded.add(key);
  }

  final occurrences = <_Occurrence>[];
  final seenStarts = <String>{};
  void addAt(DateTime startUtc) {
    final key = isoUtcOf(startUtc);
    if (!seenStarts.add(key)) return;
    occurrences.add(_Occurrence(
      record: record,
      startUtc: startUtc,
      endUtc: startUtc.add(duration),
    ));
  }

  if (record.rrule != null) {
    final parsed = IcsRecurrenceRule.parse(record.rrule);
    if (parsed == null || !parsed.isSupported) {
      addWarning(
        parsed?.errorCode ?? 'unsupported-rrule',
        parsed?.error ?? '不支持的重复规则，已跳过该事件',
        record.uid,
      );
      return const <_Occurrence>[];
    }
    final rule = parsed.rule!;
    final wallFrom = zones.utcToWall(tzid, fromUtc);
    final wallTo = zones.utcToWall(tzid, toUtc);
    if (wallFrom == null || wallTo == null) return const <_Occurrence>[];
    final lowerBound = _naiveWall(wallFrom)
        .subtract(duration)
        .subtract(const Duration(days: 1));
    final upperBound = _naiveWall(wallTo).add(const Duration(days: 2));
    if (upperBound.isBefore(wallStart)) return const <_Occurrence>[];

    final after = lowerBound.isAfter(wallStart) ? lowerBound : null;
    final generated = rule.getInstances(
      start: wallStart,
      after: after,
      before: upperBound,
    );
    var produced = 0;
    final takeLimit = limits.maxInstances + 1;
    for (final wall in generated) {
      if (produced++ > takeLimit) break;
      if (budget.remaining <= 0) break;
      if (_isAfterUntil(wall, parsed, record.allDay)) break;
      final conversion = zones.resolveWall(tzid, wall);
      if (!conversion.isOk) {
        final message = conversion.error == IcsWallError.nonexistent
            ? '事件 ${record.uid} 的实例 ${_formatWall(wall)} 因夏令时前跳不存在，'
                '已跳过该实例（未按空闲处理）'
            : '事件 ${record.uid} 的实例 ${_formatWall(wall)} 因夏令时回拨出现两次，'
                '无法确定是哪一次，已跳过该实例（未按空闲处理）';
        addWarning(conversion.warningCode, message, record.uid);
        continue;
      }
      final startUtc = conversion.utc!;
      if (parsed.untilUtc != null && startUtc.isAfter(parsed.untilUtc!)) break;
      budget.remaining--;
      if (excluded.contains(isoUtcOf(startUtc))) continue;
      addAt(startUtc);
    }
  } else {
    final startUtc = record.startUtcInstant;
    if (!excluded.contains(isoUtcOf(startUtc))) addAt(startUtc);
  }

  // RDATE 追加。
  for (final raw in record.rdateUtc) {
    final instant = _instantFromStoredValue(raw, record, zones);
    if (instant == null) {
      addWarning(
        'unsupported-rdate',
        '事件 ${record.uid} 的 RDATE $raw 无法解析，已忽略该补充时间',
        record.uid,
      );
      continue;
    }
    if (excluded.contains(isoUtcOf(instant))) continue;
    addAt(instant);
  }
  return occurrences;
}

/// UNTIL 已过？（[wall] 为当前墙上时间，[startUtc] 为解析出的 UTC）
bool _isAfterUntil(
  DateTime wall,
  IcsRecurrenceRule parsed,
  bool allDay,
) {
  final untilUtc = parsed.untilUtc;
  if (untilUtc != null) {
    // UTC 域比较在调用方按 startUtc 做；这里只处理墙上域。
    return false;
  }
  final untilWall = parsed.untilWall;
  if (untilWall == null) return false;
  if (parsed.untilDateOnly && !allDay) {
    // 纯日期 UNTIL 用在定时事件上：按“含当天整天”的宽松解释。
    final wallDate = DateTime.utc(wall.year, wall.month, wall.day);
    final untilDate = DateTime.utc(untilWall.year, untilWall.month, untilWall.day);
    return wallDate.isAfter(untilDate);
  }
  return wall.isAfter(untilWall);
}

/// RDATE 条目：标准形是 UTC ISO；容忍 `yyyy-MM-dd`（全天）。
DateTime? _instantFromStoredValue(
  String raw,
  ExternalEventRecord record,
  IcsTimeZoneResolver zones,
) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.length == 10 && text[4] == '-' && text[7] == '-') {
    final parts = text.split('-');
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    final conversion = zones.resolveWall(
        record.timezoneId, DateTime.utc(year, month, day));
    return conversion.utc;
  }
  return parseIsoUtc(text);
}

/// 把覆盖区间按“规划时区自然日”拆段。
List<ExternalBusyInstance> _splitByPlanningDay({
  required _Occurrence occurrence,
  required bool busy,
  required String planningTz,
  required IcsTimeZoneResolver zones,
  required String sourceId,
  required DateTime from,
  required DateTime to,
}) {
  final out = <ExternalBusyInstance>[];
  var cursor = from;
  var guard = 0;
  while (cursor.isBefore(to) && guard++ < 400) {
    final wall = zones.utcToWall(planningTz, cursor);
    if (wall == null) break;
    final dayKey = WallClock.formatDateKey(wall.year, wall.month, wall.day);
    final startSeconds = wall.hour * 3600 + wall.minute * 60 + wall.second;
    final startMinute = startSeconds ~/ 60;

    // 下一个规划日零点（DST 在零点切换的少数时区需要兜底）。
    final nextDate =
        DateTime.utc(wall.year, wall.month, wall.day).add(const Duration(days: 1));
    DateTime boundary = zones
            .resolveWall(planningTz,
                DateTime.utc(nextDate.year, nextDate.month, nextDate.day))
            .utc ??
        cursor.add(Duration(seconds: 86400 - startSeconds));
    var attempts = 0;
    while (attempts++ < 4) {
      final boundaryWall = zones.utcToWall(planningTz, boundary);
      if (boundaryWall == null) break;
      final boundaryKey = WallClock.formatDateKey(
          boundaryWall.year, boundaryWall.month, boundaryWall.day);
      if (boundaryKey != dayKey) break;
      boundary = boundary.add(const Duration(minutes: 30));
    }
    if (!boundary.isAfter(cursor)) {
      boundary = cursor.add(const Duration(minutes: 1));
    }
    final partEnd = boundary.isBefore(to) ? boundary : to;
    if (!partEnd.isAfter(cursor)) break;

    final endWall = zones.utcToWall(planningTz, partEnd);
    if (endWall == null) break;
    final endKey =
        WallClock.formatDateKey(endWall.year, endWall.month, endWall.day);
    int endMinute;
    if (endKey != dayKey) {
      endMinute = 1440;
    } else {
      final endSeconds = endWall.hour * 3600 + endWall.minute * 60 + endWall.second;
      endMinute = (endSeconds + 59) ~/ 60; // ceil
      if (endMinute > 1440) endMinute = 1440;
    }
    if (endMinute <= startMinute) endMinute = startMinute + 1;
    if (endMinute > 1440) endMinute = 1440;
    if (endMinute > startMinute) {
      out.add(ExternalBusyInstance(
        sourceId: sourceId,
        uid: occurrence.record.uid,
        recurrenceId: occurrence.record.recurrenceId,
        startUtc: cursor,
        endUtc: partEnd,
        busy: busy,
        tentative: occurrence.record.isTentative,
        dayKey: dayKey,
        startMinute: startMinute,
        endMinute: endMinute,
      ));
    }
    cursor = partEnd;
  }
  return out;
}

DateTime _naiveWall(DateTime wall) => DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
    );

/// 把存储值（ISO UTC / 日期键）归一成 UTC ISO 字符串。
String? _normalizeInstant(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return isoUtcOf(parsed);
}

String _formatWall(DateTime wall) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${wall.year.toString().padLeft(4, '0')}-${two(wall.month)}-'
      '${two(wall.day)} ${two(wall.hour)}:${two(wall.minute)}:${two(wall.second)}';
}
