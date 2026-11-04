// VEVENT → ExternalEventRecord（标准化事件）。
//
// 这里负责 RFC 5545 的时间语义：
//   * DTSTART / DTEND / DURATION：DATE（全天）、带 Z 的 UTC、带 TZID 的本地时间、
//     以及既无 Z 也无 TZID 的 floating 时间；
//   * floating 必须由用户策略确认解释时区，否则**不应用**该事件并记 warning
//     （绝不猜 Asia/Shanghai）；
//   * TZID 必须能解析到 IANA 时区；VTIMEZONE 由 ics_timezones.dart 处理，
//     映射不到就拒绝受影响的事件并记 warning；
//   * RRULE / RDATE / EXDATE / RECURRENCE-ID：RRULE 只在这里做**合法性校验**
//     （不支持的规则整条事件拒绝），真正的展开在 ics_expander.dart；
//     RDATE/EXDATE 的每个值在这里解析成 UTC ISO（这样跨时区/跨 DST 也能对齐）；
//     `RANGE=THISANDFUTURE` 等不支持的覆盖规则整系列拒绝；
//   * STATUS / TRANSP / SEQUENCE / DTSTAMP / SUMMARY（SUMMARY 仅本地显示）；
//   * VTODO / VJOURNAL / VALARM / VFREEBUSY 只计数不导入。
//
// 未知但**不影响时间**的属性一律忽略；影响时间又不支持的属性/规则则
// warning + 拒绝该事件（进 unsupportedUids），不静默丢弃。

import '../../model/external_calendar.dart';
import 'ics_expander.dart' show IcsLimits;
import 'ics_parser.dart';
import 'ics_recurrence.dart';
import 'ics_timezones.dart';

/// 提取结果。
class IcsExtractResult {
  const IcsExtractResult({
    this.events = const <ExternalEventRecord>[],
    this.warnings = const <ExtImportWarning>[],
    this.partialStats = const ExtImportStats(),
    this.unsupportedUids = const <String>[],
    this.componentCounts = const <String, int>{},
    required this.zones,
  });

  /// 标准化事件（系列主体 + 单次覆盖），已去重、排序。
  final List<ExternalEventRecord> events;
  final List<ExtImportWarning> warnings;

  /// 只填事件级统计：readEvents/transparentEvents/cancelledEvents/
  /// warningCount/unsupportedCount/ignoredComponents；
  /// 展开级统计由 expander 填。
  final ExtImportStats partialStats;

  /// 因不支持/非法而被拒绝的事件 UID（去重、排序）。
  final List<String> unsupportedUids;

  /// 组件计数（VEVENT/VTODO/VJOURNAL/VALARM/VFREEBUSY/VTIMEZONE）。
  final Map<String, int> componentCounts;

  /// 提取时使用的时区解析器（含文件内 VTIMEZONE），展开时必须复用同一个。
  final IcsTimeZoneResolver zones;

  bool get isEmpty => events.isEmpty;
}

/// 从解析好的组件树提取事件。
///
/// [sourceId] 只用于调用方关联（记录本身不带来源 id，快照按来源分文件保存）。
/// [timezoneId] 是应用/规划时区：全天事件、floating 时间以及 RDATE/EXDATE 的
/// 纯日期值都按它解释。
/// [zones] 是可选注入（测试可预注册时区）；不传时内部新建并注册文件内 VTIMEZONE。
IcsExtractResult extractIcsEvents(
  IcalComponent calendar, {
  required String sourceId,
  required String timezoneId,
  required ExternalCalendarPolicy policy,
  required IcsLimits limits,
  IcsTimeZoneResolver? zones,
}) {
  final resolver = zones ?? IcsTimeZoneResolver();
  resolver.addAllFromTree(calendar);

  final warnings = <ExtImportWarning>[];
  final componentCounts = <String, int>{};
  for (final name in const <String>[
    'VEVENT',
    'VTODO',
    'VJOURNAL',
    'VALARM',
    'VFREEBUSY',
    'VTIMEZONE',
  ]) {
    final count = calendar.allNamed(name).length;
    componentCounts[name] = count;
  }
  final vevents = calendar.allNamed('VEVENT');
  final ignoredComponents = (componentCounts['VTODO'] ?? 0) +
      (componentCounts['VJOURNAL'] ?? 0) +
      (componentCounts['VALARM'] ?? 0) +
      (componentCounts['VFREEBUSY'] ?? 0);
  if (ignoredComponents > 0) {
    warnings.add(ExtImportWarning(
      'ignored-components',
      '已忽略 ${componentCounts['VTODO'] ?? 0} 个待办、'
          '${componentCounts['VJOURNAL'] ?? 0} 个日记、'
          '${componentCounts['VALARM'] ?? 0} 个提醒、'
          '${componentCounts['VFREEBUSY'] ?? 0} 个忙闲组件（不导入）',
    ));
  }

  final planningKnown = resolver.isKnown(timezoneId);
  if (!planningKnown) {
    warnings.add(ExtImportWarning(
      'unknown-planning-timezone',
      '应用时区 $timezoneId 无法解析；全天事件与 floating 时间不会被导入',
    ));
  }

  // 资源上限：超出部分明确 warning 后不处理，不假装完整。
  var toProcess = vevents;
  if (vevents.length > limits.maxEvents) {
    toProcess = vevents.sublist(0, limits.maxEvents);
    warnings.add(ExtImportWarning(
      'event-limit',
      '文件有 ${vevents.length} 个事件，超过 ${limits.maxEvents} 个上限；'
          '只处理前 ${limits.maxEvents} 个，本次结果不完整',
    ));
  }

  final context = _ExtractContext(
    resolver: resolver,
    planningTimezoneId: timezoneId,
    planningKnown: planningKnown,
    policy: policy,
  );

  final extracted = <ExternalEventRecord>[];
  final rejectedUids = <String>{};
  final seriesRejected = <String, ExtImportWarning>{};
  for (final event in toProcess) {
    final result = _extractEvent(event, context);
    warnings.addAll(result.warnings);
    if (result.record != null) extracted.add(result.record!);
    if (result.rejected && result.uid.isNotEmpty) rejectedUids.add(result.uid);
    if (result.seriesRejection != null && result.uid.isNotEmpty) {
      seriesRejected[result.uid] = result.seriesRejection!;
    }
  }
  for (final entry in seriesRejected.entries) {
    warnings.add(entry.value);
  }

  // 整系列拒绝（例如 RECURRENCE-ID 的 RANGE=THISANDFUTURE）。
  final kept = extracted
      .where((e) => !seriesRejected.containsKey(e.uid))
      .toList(growable: false);

  // 同一 UID 的主体系列去重 + 单次覆盖去重（SEQUENCE 高者优先）。
  final mastersByUid = <String, ExternalEventRecord>{};
  final overridesByIdentity = <String, ExternalEventRecord>{};
  for (final record in kept) {
    if (!record.isOverride) {
      final existing = mastersByUid[record.uid];
      if (existing == null) {
        mastersByUid[record.uid] = record;
      } else {
        final keep = _preferRecord(record, existing) ? record : existing;
        mastersByUid[record.uid] = keep;
        warnings.add(ExtImportWarning(
          'duplicate-master',
          '同一 UID ${record.uid} 有多个系列主体，已保留 SEQUENCE 较大的一条',
          uid: record.uid,
        ));
      }
      continue;
    }
    final key = '${record.uid}|${record.recurrenceId}';
    final existing = overridesByIdentity[key];
    if (existing == null) {
      overridesByIdentity[key] = record;
    } else {
      overridesByIdentity[key] =
          _preferRecord(record, existing) ? record : existing;
      warnings.add(ExtImportWarning(
        'duplicate-override',
        '同一实例 ${record.uid}@${record.recurrenceId} 有多次修改，'
            '已保留 SEQUENCE 较大的一条',
        uid: record.uid,
      ));
    }
  }

  final records = <ExternalEventRecord>[
    ...mastersByUid.values,
    ...overridesByIdentity.values,
  ];
  records.sort((a, b) {
    final byUid = a.uid.compareTo(b.uid);
    if (byUid != 0) return byUid;
    if (a.isOverride != b.isOverride) return a.isOverride ? 1 : -1;
    final byRecurrenceId = (a.recurrenceId ?? '').compareTo(b.recurrenceId ?? '');
    if (byRecurrenceId != 0) return byRecurrenceId;
    return a.startUtc.compareTo(b.startUtc);
  });

  // 被拒绝的 UID：整系列拒绝，或该 UID 一条记录都没能保留下来。
  // 只是某条单次覆盖坏掉、系列主体仍在的情况不列进来（占用保持保守）。
  final keptUids = records.map((r) => r.uid).toSet();
  final unsupported = <String>{
    ...rejectedUids.where((uid) => !keptUids.contains(uid)),
    ...seriesRejected.keys,
  }.toList()
    ..sort();

  var transparentEvents = 0;
  var cancelledEvents = 0;
  for (final record in records) {
    if (record.isTransparent) transparentEvents++;
    if (record.isCancelled) cancelledEvents++;
  }

  return IcsExtractResult(
    events: List<ExternalEventRecord>.unmodifiable(records),
    warnings: List<ExtImportWarning>.unmodifiable(warnings),
    unsupportedUids: List<String>.unmodifiable(unsupported),
    componentCounts: Map<String, int>.unmodifiable(componentCounts),
    zones: resolver,
    partialStats: ExtImportStats(
      readEvents: vevents.length,
      transparentEvents: transparentEvents,
      cancelledEvents: cancelledEvents,
      warningCount: warnings.length,
      unsupportedCount: unsupported.length,
      ignoredComponents: ignoredComponents,
    ),
  );
}

// ------------------------------------------------------------------ internals

class _ExtractContext {
  const _ExtractContext({
    required this.resolver,
    required this.planningTimezoneId,
    required this.planningKnown,
    required this.policy,
  });

  final IcsTimeZoneResolver resolver;
  final String planningTimezoneId;
  final bool planningKnown;
  final ExternalCalendarPolicy policy;
}

enum _TimeKind { date, dateTimeUtc, dateTimeZoned, floating }

class _ParsedTime {
  const _ParsedTime({
    required this.kind,
    required this.wall,
    required this.utc,
    required this.tzid,
    this.errorCode,
    this.error,
  });

  final _TimeKind kind;

  /// 墙上时间（naive，字段有效；`isUtc` 标志无意义）。
  final DateTime wall;

  /// 解析出的 UTC 时刻；date/floating 在后续阶段补算，这里可能为 null。
  final DateTime? utc;

  /// 规范 IANA 时区（UTC 事件为 'UTC'；date/floating 为空）。
  final String tzid;

  final String? errorCode;
  final String? error;

  bool get isOk => error == null;
  bool get isDate => kind == _TimeKind.date;
  bool get isFloating => kind == _TimeKind.floating;
}

class _EventResult {
  const _EventResult({
    this.record,
    this.warnings = const <ExtImportWarning>[],
    this.uid = '',
    this.rejected = false,
    this.seriesRejection,
  });

  final ExternalEventRecord? record;
  final List<ExtImportWarning> warnings;
  final String uid;
  final bool rejected;
  final ExtImportWarning? seriesRejection;
}

_EventResult _extractEvent(IcalComponent event, _ExtractContext context) {
  final warnings = <ExtImportWarning>[];
  final uidProperty = event.property('UID');
  final uid = uidProperty == null ? '' : unescapeText(uidProperty.value).trim();
  if (uid.isEmpty) {
    return const _EventResult(
      warnings: <ExtImportWarning>[
        ExtImportWarning('missing-uid', '事件缺少 UID，已跳过'),
      ],
      rejected: true,
    );
  }

  ExtImportWarning warn(String code, String message) {
    final warning = ExtImportWarning(code, message, uid: uid);
    warnings.add(warning);
    return warning;
  }

  _EventResult reject(String code, String message) => _EventResult(
        warnings: <ExtImportWarning>[...warnings, warn(code, message)],
        uid: uid,
        rejected: true,
      );

  final dtstartProperty = event.property('DTSTART');
  if (dtstartProperty == null) {
    return reject('missing-dtstart', '事件 $uid 缺少 DTSTART，已跳过');
  }
  final startTime = _parseTimeProperty(dtstartProperty, context, allowDate: true);
  if (!startTime.isOk) {
    return reject(
      startTime.errorCode ?? 'invalid-datetime',
      '事件 $uid 的 DTSTART 无法解析：${startTime.error}',
    );
  }

  final allDay = startTime.isDate;
  // 源时区：UTC → UTC；带 TZID → 该时区；DATE/floating → 规划时区。
  String recordTz = startTime.tzid;
  if (allDay || startTime.isFloating) {
    if (!context.planningKnown) {
      return reject(
        'unknown-planning-timezone',
        '事件 $uid 是${allDay ? '全天' : 'floating'}事件，但应用时区无效，已跳过',
      );
    }
    if (startTime.isFloating && !context.policy.hasFloatingTimezone) {
      return reject(
        'floating-unconfirmed',
        '事件 $uid 使用 floating 时间（无 TZID 无 Z），'
            '尚未确认解释时区，已跳过该事件',
      );
    }
    final floatingTz = startTime.isFloating
        ? context.policy.floatingTimezoneId.trim()
        : context.planningTimezoneId;
    final canonical = context.resolver.canonicalIdOf(floatingTz);
    if (canonical == null) {
      return reject(
        'unknown-timezone',
        '事件 $uid 的${allDay ? '应用' : 'floating'}时区 $floatingTz 无法解析，已跳过',
      );
    }
    recordTz = canonical;
  }
  if (!context.resolver.isKnown(recordTz)) {
    return reject(
      'unknown-timezone',
      '事件 $uid 的时区 $recordTz 无法解析，已跳过',
    );
  }

  DateTime startUtc;
  if (allDay) {
    final conversion = context.resolver.resolveWall(
        recordTz, DateTime.utc(startTime.wall.year, startTime.wall.month, startTime.wall.day));
    if (!conversion.isOk) {
      return reject(
        conversion.warningCode,
        '事件 $uid 的日期无法解析：${conversion.detail}',
      );
    }
    startUtc = conversion.utc!;
  } else if (startTime.utc != null) {
    startUtc = startTime.utc!;
  } else {
    // floating：按确认过的时区解释墙上时间。
    final conversion = context.resolver.resolveWall(recordTz, startTime.wall);
    if (!conversion.isOk) {
      return reject(
        conversion.warningCode,
        '事件 $uid 的 floating 时间无法解析：${conversion.detail}',
      );
    }
    startUtc = conversion.utc!;
  }

  // ---- 结束时间（DTEND / DURATION / 全天默认 1 天 / 定时默认 0 秒）----
  final dtendProperty = event.property('DTEND');
  final durationProperty = event.property('DURATION');
  if (dtendProperty != null && durationProperty != null) {
    warn('dtend-and-duration',
        '事件 $uid 同时有 DTEND 与 DURATION（违反 RFC 5545），已按 DTEND 处理');
  }

  DateTime endUtc;
  var endSecond = 0;
  if (allDay) {
    final startDate = DateTime.utc(
        startTime.wall.year, startTime.wall.month, startTime.wall.day);
    DateTime endDate;
    if (dtendProperty != null) {
      final endTime = _parseTimeProperty(dtendProperty, context, allowDate: true);
      if (!endTime.isOk) {
        return reject(
          endTime.errorCode ?? 'invalid-datetime',
          '事件 $uid 的 DTEND 无法解析：${endTime.error}',
        );
      }
      if (!endTime.isDate) {
        warn('invalid-dtend', '事件 $uid 是全天事件但 DTEND 不是日期，已取日期部分');
      }
      endDate = DateTime.utc(
          endTime.wall.year, endTime.wall.month, endTime.wall.day);
    } else if (durationProperty != null) {
      final parsed = _parseIcalDuration(durationProperty.value);
      if (parsed == null || parsed.isNegative) {
        return reject('invalid-duration', '事件 $uid 的 DURATION 无法解析');
      }
      var days = parsed.inDays;
      if (days <= 0) {
        warn('invalid-duration', '事件 $uid 的 DURATION 不足 1 天，已按 1 天处理');
        days = 1;
      }
      endDate = startDate.add(Duration(days: days));
    } else {
      endDate = startDate.add(const Duration(days: 1));
    }
    if (!endDate.isAfter(startDate)) {
      warn('end-before-start', '事件 $uid 的全天结束日期不晚于开始日期，已按 1 天处理');
      endDate = startDate.add(const Duration(days: 1));
    }
    final endConversion = context.resolver.resolveWall(recordTz, endDate);
    if (!endConversion.isOk) {
      return reject(
        endConversion.warningCode,
        '事件 $uid 的全天结束日期无法解析：${endConversion.detail}',
      );
    }
    endUtc = endConversion.utc!;
    endSecond = endDate.difference(startDate).inDays * 86400;
  } else {
    Duration duration;
    if (dtendProperty != null) {
      final endTime = _parseTimeProperty(dtendProperty, context, allowDate: false);
      if (!endTime.isOk) {
        return reject(
          endTime.errorCode ?? 'invalid-datetime',
          '事件 $uid 的 DTEND 无法解析：${endTime.error}',
        );
      }
      DateTime? endInstant = endTime.utc;
      if (endInstant == null) {
        // DTEND 是 floating：与 DTSTART 同一解释时区。
        final conversion = context.resolver.resolveWall(recordTz, endTime.wall);
        if (!conversion.isOk) {
          return reject(
            conversion.warningCode,
            '事件 $uid 的 DTEND 无法解析：${conversion.detail}',
          );
        }
        endInstant = conversion.utc!;
      }
      if (endInstant.isBefore(startUtc)) {
        return reject('end-before-start', '事件 $uid 的结束时间早于开始时间，已跳过');
      }
      endUtc = endInstant;
      duration = endUtc.difference(startUtc);
      if (duration == Duration.zero) {
        warn('zero-duration', '事件 $uid 的开始与结束相同，不占用任何时间');
      }
    } else if (durationProperty != null) {
      final parsed = _parseIcalDuration(durationProperty.value);
      if (parsed == null || parsed.isNegative) {
        return reject('invalid-duration', '事件 $uid 的 DURATION 无法解析');
      }
      duration = parsed;
      endUtc = startUtc.add(duration);
    } else {
      duration = Duration.zero;
      endUtc = startUtc;
    }
    final endWall = context.resolver.utcToWall(recordTz, endUtc);
    if (endWall != null) {
      endSecond =
          endWall.hour * 3600 + endWall.minute * 60 + endWall.second;
    }
  }

  final startSecond = allDay
      ? 0
      : startTime.wall.hour * 3600 +
          startTime.wall.minute * 60 +
          startTime.wall.second;

  // ---- 状态 / 透明度 / 序号 / 摘要 ----
  final statusRaw = (event.valueOf('STATUS') ?? '').trim().toUpperCase();
  var status = kExtStatusConfirmed;
  switch (statusRaw) {
    case '':
    case 'CONFIRMED':
      status = kExtStatusConfirmed;
    case 'TENTATIVE':
      status = kExtStatusTentative;
    case 'CANCELLED':
      status = kExtStatusCancelled;
    default:
      warn('unknown-status', '事件 $uid 的 STATUS=$statusRaw 不认识，按已确认处理');
  }

  final transpRaw = (event.valueOf('TRANSP') ?? '').trim().toUpperCase();
  var transparency = kExtTransparencyOpaque;
  switch (transpRaw) {
    case '':
    case 'OPAQUE':
      transparency = kExtTransparencyOpaque;
    case 'TRANSPARENT':
      transparency = kExtTransparencyTransparent;
    default:
      warn('unknown-transp', '事件 $uid 的 TRANSP=$transpRaw 不认识，按占用处理');
  }

  var sequence = 0;
  final sequenceRaw = event.valueOf('SEQUENCE');
  if (sequenceRaw != null && sequenceRaw.trim().isNotEmpty) {
    final parsed = int.tryParse(sequenceRaw.trim());
    if (parsed == null || parsed < 0) {
      warn('invalid-sequence', '事件 $uid 的 SEQUENCE 不合法，按 0 处理');
    } else {
      sequence = parsed;
    }
  }
  final dtstamp = (event.valueOf('DTSTAMP') ?? '').trim();
  final summaryProperty = event.property('SUMMARY');
  final summary = summaryProperty == null
      ? ''
      : unescapeText(summaryProperty.value).trim();

  // ---- RECURRENCE-ID（单次覆盖 / 单实例取消）----
  String? recurrenceId;
  final recurrenceProperty = event.property('RECURRENCE-ID');
  if (recurrenceProperty != null) {
    final range = recurrenceProperty.parameter('RANGE');
    if (range != null && range.trim().isNotEmpty) {
      // RANGE=THISANDFUTURE 等不支持的规则：整系列拒绝，绝不部分应用。
      // warning 由调用方在系列拒绝时统一登记，这里只登记一次，避免重复提示。
      return _EventResult(
        uid: uid,
        rejected: true,
        warnings: warnings,
        seriesRejection: ExtImportWarning(
          'unsupported-recurrence-range',
          '事件 $uid 使用了不支持的 RECURRENCE-ID;RANGE=$range，'
              '为避免只改一半，已拒绝该系列的全部实例',
          uid: uid,
        ),
      );
    }
    final recurrenceTime =
        _parseTimeProperty(recurrenceProperty, context, allowDate: true);
    if (!recurrenceTime.isOk) {
      // 单条覆盖坏了就丢掉这条覆盖：基础实例保留为占用（保守）。
      warnings.add(ExtImportWarning(
        recurrenceTime.errorCode ?? 'invalid-recurrence-id',
        '事件 $uid 的 RECURRENCE-ID 无法解析，已忽略这条修改：'
            '${recurrenceTime.error}',
        uid: uid,
      ));
      return _EventResult(warnings: warnings, uid: uid, rejected: true);
    }
    if (recurrenceTime.isDate) {
      final conversion = context.resolver.resolveWall(
          recordTz,
          DateTime.utc(recurrenceTime.wall.year, recurrenceTime.wall.month,
              recurrenceTime.wall.day));
      if (!conversion.isOk) {
        return _EventResult(
          warnings: <ExtImportWarning>[
            ...warnings,
            ExtImportWarning(
              conversion.warningCode,
              '事件 $uid 的 RECURRENCE-ID 日期无法解析，已忽略这条修改',
              uid: uid,
            ),
          ],
          uid: uid,
          rejected: true,
        );
      }
      recurrenceId = isoUtcOf(conversion.utc!);
    } else {
      final instant = recurrenceTime.utc ??
          context.resolver.wallToUtc(recordTz, recurrenceTime.wall);
      if (instant == null) {
        return _EventResult(
          warnings: <ExtImportWarning>[
            ...warnings,
            ExtImportWarning(
              'invalid-recurrence-id',
              '事件 $uid 的 RECURRENCE-ID 无法换算到 UTC，已忽略这条修改',
              uid: uid,
            ),
          ],
          uid: uid,
          rejected: true,
        );
      }
      recurrenceId = isoUtcOf(instant);
    }
  }

  // ---- RRULE（只校验；展开在 expander）----
  final rruleProperties = event.propertiesNamed('RRULE');
  if (rruleProperties.length > 1) {
    warn('duplicate-rrule', '事件 $uid 有多个 RRULE，只使用第一条');
  }
  String? rruleValue;
  if (rruleProperties.isNotEmpty) {
    final parsed = IcsRecurrenceRule.parse(rruleProperties.first.value);
    if (parsed == null) {
      warn('unsupported-rrule', '事件 $uid 的 RRULE 为空，已忽略');
    } else if (!parsed.isSupported) {
      return reject(
        parsed.errorCode ?? 'unsupported-rrule',
        '事件 $uid 的重复规则不受支持：${parsed.error}',
      );
    } else {
      rruleValue = rruleProperties.first.value.trim();
      if (rruleValue.toUpperCase().startsWith('RRULE:')) {
        rruleValue = rruleValue.substring(6).trim();
      }
      if (recurrenceId != null) {
        // 单次覆盖上带 RRULE 在 RFC 里是非法组合，会影响时间语义 → 拒绝。
        return reject(
          'unsupported-override-rrule',
          '事件 $uid 的单次覆盖（RECURRENCE-ID）同时带有 RRULE，已跳过',
        );
      }
    }
  }

  // ---- RDATE / EXDATE ----
  final rdates = <String>[];
  final exdates = <String>[];
  var invalidRdate = false;
  for (final property in event.propertiesNamed('RDATE')) {
    final parsed = _parseDateList(property, context, recordTz,
        allDay: allDay, warnings: warnings, uid: uid, isExdate: false);
    if (parsed == null) {
      invalidRdate = true;
      continue;
    }
    rdates.addAll(parsed);
  }
  if (invalidRdate) {
    return reject('unsupported-rdate', '事件 $uid 的 RDATE 使用了不支持的形式，已跳过');
  }
  for (final property in event.propertiesNamed('EXDATE')) {
    final parsed = _parseDateList(property, context, recordTz,
        allDay: allDay, warnings: warnings, uid: uid, isExdate: true);
    if (parsed != null) exdates.addAll(parsed);
  }

  final record = ExternalEventRecord(
    uid: uid,
    recurrenceId: recurrenceId,
    startUtc: isoUtcOf(startUtc),
    endUtc: isoUtcOf(endUtc),
    allDay: allDay,
    startSecond: startSecond,
    endSecond: endSecond,
    summary: summary,
    status: status,
    transparency: transparency,
    sequence: sequence,
    dtstamp: dtstamp,
    rrule: rruleValue,
    rdateUtc: List<String>.unmodifiable(rdates),
    exdateUtc: List<String>.unmodifiable(exdates),
    timezoneId: recordTz,
  );
  return _EventResult(record: record, warnings: warnings, uid: uid);
}

/// 解析 DTSTART/DTEND/RECURRENCE-ID 这类单个时间属性。
_ParsedTime _parseTimeProperty(
  IcalProperty property,
  _ExtractContext context, {
  required bool allowDate,
}) {
  final raw = property.value.trim();
  final valueType = (property.parameter('VALUE') ?? '').trim().toUpperCase();
  if (raw.isEmpty) {
    return _ParsedTime(
      kind: _TimeKind.dateTimeZoned,
      wall: _emptyWallDate(),
      utc: null,
      tzid: '',
      errorCode: 'invalid-datetime',
      error: '值为空',
    );
  }
  // 去掉小数秒（部分导出器会带 `.000`）。
  var text = raw;
  final dot = text.indexOf('.');
  if (dot > 0) text = text.substring(0, dot);

  final looksLikeDate =
      valueType == 'DATE' || (text.length == 8 && !text.contains('T'));
  if (looksLikeDate) {
    if (!allowDate) {
      return _ParsedTime(
        kind: _TimeKind.date,
        wall: _emptyWallDate(),
        utc: null,
        tzid: '',
        errorCode: 'invalid-datetime',
        error: '这里不允许 DATE 值',
      );
    }
    final parsed = _parseDateValue(text);
    if (parsed == null) {
      return _ParsedTime(
        kind: _TimeKind.date,
        wall: _emptyWallDate(),
        utc: null,
        tzid: '',
        errorCode: 'invalid-datetime',
        error: '日期格式不合法',
      );
    }
    return _ParsedTime(
      kind: _TimeKind.date,
      wall: parsed,
      utc: null,
      tzid: '',
    );
  }

  final isUtc = text.endsWith('Z') || text.endsWith('z');
  final body = isUtc ? text.substring(0, text.length - 1) : text;
  final wall = _parseDateTimeValue(body);
  if (wall == null) {
    return _ParsedTime(
      kind: _TimeKind.dateTimeZoned,
      wall: _emptyWallDate(),
      utc: null,
      tzid: '',
      errorCode: 'invalid-datetime',
      error: '日期时间格式不合法',
    );
  }
  if (isUtc) {
    return _ParsedTime(
      kind: _TimeKind.dateTimeUtc,
      wall: wall,
      utc: DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
          wall.minute, wall.second),
      tzid: 'UTC',
    );
  }
  final tzidRaw = property.parameter('TZID');
  if (tzidRaw == null || tzidRaw.trim().isEmpty) {
    return _ParsedTime(
      kind: _TimeKind.floating,
      wall: wall,
      utc: null,
      tzid: '',
    );
  }
  final canonical = context.resolver.canonicalIdOf(tzidRaw);
  if (canonical == null) {
    final reason = context.resolver.unsupportedReason(tzidRaw) ??
        '未知时区 TZID：$tzidRaw';
    return _ParsedTime(
      kind: _TimeKind.dateTimeZoned,
      wall: wall,
      utc: null,
      tzid: '',
      errorCode: 'unknown-timezone',
      error: reason,
    );
  }
  final conversion = context.resolver.resolveWall(canonical, wall);
  if (!conversion.isOk) {
    return _ParsedTime(
      kind: _TimeKind.dateTimeZoned,
      wall: wall,
      utc: null,
      tzid: canonical,
      errorCode: conversion.warningCode,
      error: conversion.detail,
    );
  }
  return _ParsedTime(
    kind: _TimeKind.dateTimeZoned,
    wall: wall,
    utc: conversion.utc,
    tzid: canonical,
  );
}

/// RDATE/EXDATE 解析成 UTC ISO 列表；返回 null 表示该属性形式不支持。
List<String>? _parseDateList(
  IcalProperty property,
  _ExtractContext context,
  String recordTz, {
  required bool allDay,
  required List<ExtImportWarning> warnings,
  required String uid,
  required bool isExdate,
}) {
  final valueType = (property.parameter('VALUE') ?? '').trim().toUpperCase();
  final kindLabel = isExdate ? 'EXDATE' : 'RDATE';
  if (valueType == 'PERIOD') {
    if (!isExdate) return null; // 影响时间又不支持 → 由调用方拒绝整条事件
    warnings.add(ExtImportWarning(
      'unsupported-exdate-period',
      '事件 $uid 的 EXDATE 使用了 PERIOD（不合法），已忽略该排除时间',
      uid: uid,
    ));
    return const <String>[];
  }
  final tzidRaw = property.parameter('TZID');
  final propertyTz = (tzidRaw != null && tzidRaw.trim().isNotEmpty)
      ? (context.resolver.canonicalIdOf(tzidRaw) ?? '')
      : '';
  if (tzidRaw != null && tzidRaw.trim().isNotEmpty && propertyTz.isEmpty) {
    warnings.add(ExtImportWarning(
      'unknown-timezone',
      '事件 $uid 的 $kindLabel 时区 $tzidRaw 无法解析，已忽略该时间',
      uid: uid,
    ));
    return const <String>[];
  }

  final out = <String>[];
  for (final raw in _splitComma(property.value)) {
    final text = raw.trim();
    if (text.isEmpty) continue;
    final isDate = valueType == 'DATE' || (text.length == 8 && !text.contains('T'));
    if (isDate) {
      if (!allDay) {
        // RFC 要求 EXDATE/RDATE 与 DTSTART 同类型；不匹配时保守处理：
        // RDATE 丢掉补进来的时间、EXDATE 不排除（保持占用），并明确提示。
        warnings.add(ExtImportWarning(
          'date-type-mismatch',
          isExdate
              ? '事件 $uid 的 $kindLabel 是纯日期但事件是定时事件，已忽略该排除时间'
                  '（该实例仍按占用处理）'
              : '事件 $uid 的 $kindLabel 是纯日期但事件是定时事件，已忽略该补充时间',
          uid: uid,
        ));
        continue;
      }
      final parsed = _parseDateValue(text);
      if (parsed == null) {
        warnings.add(ExtImportWarning(
          'invalid-datetime',
          '事件 $uid 的 $kindLabel 日期 $text 不合法，已忽略',
          uid: uid,
        ));
        continue;
      }
      final conversion = context.resolver.resolveWall(recordTz, parsed);
      if (!conversion.isOk) {
        warnings.add(ExtImportWarning(
          conversion.warningCode,
          '事件 $uid 的 $kindLabel 日期 $text 无法解析：${conversion.detail}',
          uid: uid,
        ));
        continue;
      }
      out.add(isoUtcOf(conversion.utc!));
      continue;
    }

    var datetimeText = text;
    final isUtc = datetimeText.endsWith('Z') || datetimeText.endsWith('z');
    if (isUtc) datetimeText = datetimeText.substring(0, datetimeText.length - 1);
    final dot = datetimeText.indexOf('.');
    if (dot > 0) datetimeText = datetimeText.substring(0, dot);
    final wall = _parseDateTimeValue(datetimeText);
    if (wall == null) {
      warnings.add(ExtImportWarning(
        'invalid-datetime',
        '事件 $uid 的 $kindLabel 时间 $text 不合法，已忽略',
        uid: uid,
      ));
      continue;
    }
    if (isUtc) {
      out.add(isoUtcOf(DateTime.utc(wall.year, wall.month, wall.day, wall.hour,
          wall.minute, wall.second)));
      continue;
    }
    final tz = propertyTz.isNotEmpty ? propertyTz : recordTz;
    final conversion = context.resolver.resolveWall(tz, wall);
    if (!conversion.isOk) {
      warnings.add(ExtImportWarning(
        conversion.warningCode,
        '事件 $uid 的 $kindLabel 时间 $text 无法解析：${conversion.detail}',
        uid: uid,
      ));
      continue;
    }
    out.add(isoUtcOf(conversion.utc!));
  }
  return out;
}

DateTime _emptyWallDate() => DateTime.utc(1970);

DateTime? _parseDateValue(String text) {
  final digits = text.trim();
  if (digits.length != 8) return null;
  final year = int.tryParse(digits.substring(0, 4));
  final month = int.tryParse(digits.substring(4, 6));
  final day = int.tryParse(digits.substring(6, 8));
  if (year == null || month == null || day == null) return null;
  final value = DateTime.utc(year, month, day);
  if (value.year != year || value.month != month || value.day != day) {
    return null;
  }
  return value;
}

DateTime? _parseDateTimeValue(String text) {
  if (text.length < 13 || text[8] != 'T') return null;
  final date = _parseDateValue(text.substring(0, 8));
  if (date == null) return null;
  final hour = int.tryParse(text.substring(9, 11));
  final minute = int.tryParse(text.substring(11, 13));
  if (hour == null || minute == null) return null;
  var second = 0;
  if (text.length >= 15) {
    final parsed = int.tryParse(text.substring(13, 15));
    if (parsed == null) return null;
    second = parsed;
  }
  if (hour > 23 || minute > 59 || second > 60) return null;
  return DateTime.utc(
      date.year, date.month, date.day, hour, minute, second > 59 ? 59 : second);
}

Duration? _parseIcalDuration(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  var sign = 1;
  if (text.startsWith('-')) {
    sign = -1;
    text = text.substring(1);
  } else if (text.startsWith('+')) {
    text = text.substring(1);
  }
  if (!text.startsWith('P')) return null;
  text = text.substring(1);
  final weeks = <int>[];
  final days = <int>[];
  final hours = <int>[];
  final minutes = <int>[];
  final seconds = <int>[];
  var index = 0;
  var inTime = false;
  while (index < text.length) {
    if (text[index] == 'T') {
      inTime = true;
      index++;
      continue;
    }
    final start = index;
    while (index < text.length && _isDigit(text.codeUnitAt(index))) {
      index++;
    }
    if (index == start || index >= text.length) return null;
    final number = int.tryParse(text.substring(start, index));
    if (number == null) return null;
    final unit = text[index].toUpperCase();
    index++;
    switch (unit) {
      case 'W':
        if (inTime) return null;
        weeks.add(number);
      case 'D':
        if (inTime) return null;
        days.add(number);
      case 'H':
        if (!inTime) return null;
        hours.add(number);
      case 'M':
        if (!inTime) return null;
        minutes.add(number);
      case 'S':
        if (!inTime) return null;
        seconds.add(number);
      default:
        return null;
    }
  }
  final total = Duration(
    days: _sum(weeks) * 7 + _sum(days),
    hours: _sum(hours),
    minutes: _sum(minutes),
    seconds: _sum(seconds),
  );
  return sign < 0 ? -total : total;
}

int _sum(List<int> values) => values.fold<int>(0, (a, b) => a + b);

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

List<String> _splitComma(String value) {
  // DATE-TIME / PERIOD 值里没有转义逗号（TEXT 才有），直接按逗号切。
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) == 0x2C) {
      out.add(value.substring(start, i));
      start = i + 1;
    }
  }
  out.add(value.substring(start));
  return out;
}

bool _preferRecord(ExternalEventRecord candidate, ExternalEventRecord current) {
  if (candidate.sequence != current.sequence) {
    return candidate.sequence > current.sequence;
  }
  return candidate.dtstamp.compareTo(current.dtstamp) >= 0;
}
