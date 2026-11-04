// 外部日历（本地 ICS 只读导入）的纯数据模型。
//
// 这一层只做“数据形状 + 序列化”，不读文件、不碰 UI、不发网络请求：
//   * [ExternalCalendarSource] 是用户管理的一个来源（一个本地 .ics 文件）；
//   * [ExternalSourceSnapshot] 是某个来源最近一次成功导入的标准化结果，
//     每个来源一份，独立落盘；来源之间互不影响（同一 UID 出现在两个来源里也
//     各自独立，见 U01）；
//   * [ExternalEventRecord] 是标准化后的事件（系列主体或单次覆盖），时间一律
//     以 UTC 保存，另存原始秒精度；
//   * [ExternalBusyInstance] 是展开后的占用实例，按规划时区的自然日拆分，
//     供“运行时合成时间表”使用（见 T-D 的 timetable_composition.dart）。
//
// 隐私约定：importedAt / summary / filePath 只用于本地显示，绝不进入模型请求；
// 外部日历的标题与路径不得写进任何请求体。
//
// 序列化是“严格但可回退”的：任何一份不合法的事件都让整份快照返回 null，
// 由存储层回退到 .bak；绝不把半份 JSON 当成成功的数据。

import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'calendar.dart' show WallClock, parseDateKey;

/// 来源类型。0.2.2 只有“本地文件”一种；CalDAV 只做设计文档，不在此实现。
const String kExternalCalendarTypeLocalFile = 'localFile';

/// 数据目录下的子目录名：`<dataRoot>/external_calendar/`。
const String kExternalCalendarDirName = 'external_calendar';

/// 快照文件 schema 版本。写入方与读取方必须一致，否则按损坏处理并回退 .bak。
const int kExternalSnapshotSchemaVersion = 1;

/// 来源索引文件 schema 版本。
const int kExternalSourcesSchemaVersion = 1;

/// 外部占用如何计入“忙”。
///
/// 默认 [tentativeCountsAsBusy]：暂定事件保守地算占用（宁可少排，不可撞车）。
enum ExternalBusyPolicy {
  /// 只有 TRANSP!=TRANSPARENT 且未取消的事件算占用；暂定/透明都不算。
  opaqueOnly('opaqueOnly'),

  /// 暂定也占用（默认）；透明不算。
  tentativeCountsAsBusy('tentativeCountsAsBusy'),

  /// 透明也占用（用户显式选择）。
  allCountsAsBusy('allCountsAsBusy');

  const ExternalBusyPolicy(this.wireName);

  final String wireName;

  static ExternalBusyPolicy parse(Object? value) {
    final text = value is String ? value.trim() : '';
    for (final policy in values) {
      if (policy.wireName == text) return policy;
    }
    return ExternalBusyPolicy.tentativeCountsAsBusy;
  }
}

/// 一个来源的导入策略。
class ExternalCalendarPolicy {
  const ExternalCalendarPolicy({
    this.busyPolicy = ExternalBusyPolicy.tentativeCountsAsBusy,
    this.floatingTimezoneId = '',
    this.floatingConfirmed = false,
  });

  final ExternalBusyPolicy busyPolicy;

  /// floating 时间（无 TZID 无 Z）解释成哪个 IANA 时区；空 = 未决。
  final String floatingTimezoneId;

  /// 用户是否确认过 floating 的解释方式；未确认时 floating 事件不应用。
  final bool floatingConfirmed;

  bool get hasFloatingTimezone =>
      floatingConfirmed && floatingTimezoneId.trim().isNotEmpty;

  ExternalCalendarPolicy copyWith({
    ExternalBusyPolicy? busyPolicy,
    String? floatingTimezoneId,
    bool? floatingConfirmed,
  }) =>
      ExternalCalendarPolicy(
        busyPolicy: busyPolicy ?? this.busyPolicy,
        floatingTimezoneId: floatingTimezoneId ?? this.floatingTimezoneId,
        floatingConfirmed: floatingConfirmed ?? this.floatingConfirmed,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'busyPolicy': busyPolicy.wireName,
        'floatingTimezoneId': floatingTimezoneId,
        'floatingConfirmed': floatingConfirmed,
      };

  factory ExternalCalendarPolicy.fromJson(Object? raw) {
    if (raw is! Map) return const ExternalCalendarPolicy();
    final j = Map<String, dynamic>.from(raw);
    return ExternalCalendarPolicy(
      busyPolicy: ExternalBusyPolicy.parse(j['busyPolicy']),
      floatingTimezoneId: _text(j['floatingTimezoneId']) ?? '',
      floatingConfirmed: j['floatingConfirmed'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalCalendarPolicy &&
      other.busyPolicy == busyPolicy &&
      other.floatingTimezoneId == floatingTimezoneId &&
      other.floatingConfirmed == floatingConfirmed;

  @override
  int get hashCode =>
      Object.hash(busyPolicy, floatingTimezoneId, floatingConfirmed);

  @override
  String toString() =>
      'ExternalCalendarPolicy(${busyPolicy.wireName}, floating=$floatingTimezoneId)';
}

/// 一条导入警告。code 是稳定标识（UI 分类用），message 是中文说明。
class ExtImportWarning {
  const ExtImportWarning(this.code, this.message, {this.uid});

  final String code;
  final String message;
  final String? uid;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        'uid': uid,
      };

  static ExtImportWarning? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final code = _text(j['code']);
    final message = _text(j['message']);
    if (code == null || message == null) return null;
    return ExtImportWarning(code, message, uid: _text(j['uid']));
  }

  @override
  String toString() => uid == null ? '[$code] $message' : '[$code] $uid: $message';
}

/// 最近一次导入的统计（只读展示）。
class ExtImportStats {
  const ExtImportStats({
    this.readEvents = 0,
    this.expandedInstances = 0,
    this.busyMinutes = 0,
    this.transparentEvents = 0,
    this.cancelledEvents = 0,
    this.tentativeInstances = 0,
    this.warningCount = 0,
    this.unsupportedCount = 0,
    this.ignoredComponents = 0,
  });

  /// 文件里读到的 VEVENT 条数（含被拒绝的）。
  final int readEvents;

  /// 展开后的占用实例数（按次，不按天拆）。
  final int expandedInstances;

  /// 展开范围内被计为占用的分钟数（跨日按段累加）。
  final int busyMinutes;

  /// 透明事件条数。
  final int transparentEvents;

  /// 取消事件条数（整系列或单实例）。
  final int cancelledEvents;

  /// 暂定实例数。
  final int tentativeInstances;

  /// 警告条数。
  final int warningCount;

  /// 因不支持而被拒绝的事件数。
  final int unsupportedCount;

  /// 被忽略的非事件组件数（VTODO/VJOURNAL/VALARM/VFREEBUSY）。
  final int ignoredComponents;

  ExtImportStats copyWith({
    int? readEvents,
    int? expandedInstances,
    int? busyMinutes,
    int? transparentEvents,
    int? cancelledEvents,
    int? tentativeInstances,
    int? warningCount,
    int? unsupportedCount,
    int? ignoredComponents,
  }) =>
      ExtImportStats(
        readEvents: readEvents ?? this.readEvents,
        expandedInstances: expandedInstances ?? this.expandedInstances,
        busyMinutes: busyMinutes ?? this.busyMinutes,
        transparentEvents: transparentEvents ?? this.transparentEvents,
        cancelledEvents: cancelledEvents ?? this.cancelledEvents,
        tentativeInstances: tentativeInstances ?? this.tentativeInstances,
        warningCount: warningCount ?? this.warningCount,
        unsupportedCount: unsupportedCount ?? this.unsupportedCount,
        ignoredComponents: ignoredComponents ?? this.ignoredComponents,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'readEvents': readEvents,
        'expandedInstances': expandedInstances,
        'busyMinutes': busyMinutes,
        'transparentEvents': transparentEvents,
        'cancelledEvents': cancelledEvents,
        'tentativeInstances': tentativeInstances,
        'warningCount': warningCount,
        'unsupportedCount': unsupportedCount,
        'ignoredComponents': ignoredComponents,
      };

  factory ExtImportStats.fromJson(Object? raw) {
    if (raw is! Map) return const ExtImportStats();
    final j = Map<String, dynamic>.from(raw);
    int of(String key) => math.max(0, _int(j[key]) ?? 0);
    return ExtImportStats(
      readEvents: of('readEvents'),
      expandedInstances: of('expandedInstances'),
      busyMinutes: of('busyMinutes'),
      transparentEvents: of('transparentEvents'),
      cancelledEvents: of('cancelledEvents'),
      tentativeInstances: of('tentativeInstances'),
      warningCount: of('warningCount'),
      unsupportedCount: of('unsupportedCount'),
      ignoredComponents: of('ignoredComponents'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExtImportStats &&
      other.readEvents == readEvents &&
      other.expandedInstances == expandedInstances &&
      other.busyMinutes == busyMinutes &&
      other.transparentEvents == transparentEvents &&
      other.cancelledEvents == cancelledEvents &&
      other.tentativeInstances == tentativeInstances &&
      other.warningCount == warningCount &&
      other.unsupportedCount == unsupportedCount &&
      other.ignoredComponents == ignoredComponents;

  @override
  int get hashCode => Object.hash(
        readEvents,
        expandedInstances,
        busyMinutes,
        transparentEvents,
        cancelledEvents,
        tentativeInstances,
        warningCount,
        unsupportedCount,
        ignoredComponents,
      );

  @override
  String toString() => 'ExtImportStats(events=$readEvents, '
      'instances=$expandedInstances, busyMin=$busyMinutes, '
      'transparent=$transparentEvents, cancelled=$cancelledEvents, '
      'tentative=$tentativeInstances, warnings=$warningCount, '
      'unsupported=$unsupportedCount)';
}

/// 事件状态（RFC 5545 STATUS），小写归一。
const String kExtStatusConfirmed = 'confirmed';
const String kExtStatusTentative = 'tentative';
const String kExtStatusCancelled = 'cancelled';

/// 透明度（RFC 5545 TRANSP），小写归一。
const String kExtTransparencyOpaque = 'opaque';
const String kExtTransparencyTransparent = 'transparent';

/// 标准化事件（系列主体或单次覆盖），全部时间以 UTC 秒保存原始语义。
///
/// 额外保留 [timezoneId]：源事件的“墙上时间”应该按哪个 IANA 时区解释。
/// 展开 RRULE 时必须按源墙上时间进行（见 ics_expander.dart），因此这条信息
/// 必须随事件一起持久化；它不是给 UI 展示用的。
class ExternalEventRecord {
  const ExternalEventRecord({
    required this.uid,
    this.recurrenceId,
    required this.startUtc,
    required this.endUtc,
    this.allDay = false,
    this.startSecond = 0,
    this.endSecond = 0,
    this.summary = '',
    this.status = kExtStatusConfirmed,
    this.transparency = kExtTransparencyOpaque,
    this.sequence = 0,
    this.dtstamp = '',
    this.rrule,
    this.rdateUtc = const <String>[],
    this.exdateUtc = const <String>[],
    this.timezoneId = 'UTC',
  });

  final String uid;

  /// 原始 RECURRENCE-ID（UTC ISO）；null = 系列主体。
  final String? recurrenceId;

  /// 半开区间 [startUtc, endUtc)，ISO8601 UTC。系列主体 = 首实例。
  final String startUtc;
  final String endUtc;

  final bool allDay;

  /// 原始秒精度：源时区挂钟当日秒数（0..86399；全天事件终点可到 86400+）。
  /// 用于保守外扩（起点 floor、终点 ceil）与再导入核对。
  final int startSecond;
  final int endSecond;

  /// 仅本地显示，绝不进入模型请求。
  final String summary;

  /// 'confirmed' | 'tentative' | 'cancelled'
  final String status;

  /// 'opaque' | 'transparent'
  final String transparency;

  final int sequence;
  final String dtstamp;

  /// RRULE 的属性值（不含 `RRULE:` 前缀）；null = 不重复。
  final String? rrule;

  /// RDATE / EXDATE：DATE-TIME → UTC ISO；VALUE=DATE → `yyyy-MM-dd`。
  final List<String> rdateUtc;
  final List<String> exdateUtc;

  /// 源墙上时间所属 IANA 时区（UTC 事件为 'UTC'；全天/floating 为规划时区）。
  final String timezoneId;

  bool get isOverride => recurrenceId != null;
  bool get isCancelled => status == kExtStatusCancelled;
  bool get isTentative => status == kExtStatusTentative;
  bool get isTransparent => transparency == kExtTransparencyTransparent;

  DateTime get startUtcInstant => DateTime.parse(startUtc).toUtc();
  DateTime get endUtcInstant => DateTime.parse(endUtc).toUtc();
  Duration get duration => endUtcInstant.difference(startUtcInstant);

  /// 稳定身份：同一来源内 `uid|recurrenceId`。
  String get identityKey => recurrenceId == null ? uid : '$uid|$recurrenceId';

  ExternalEventRecord copyWith({
    String? uid,
    String? recurrenceId,
    bool clearRecurrenceId = false,
    String? startUtc,
    String? endUtc,
    bool? allDay,
    int? startSecond,
    int? endSecond,
    String? summary,
    String? status,
    String? transparency,
    int? sequence,
    String? dtstamp,
    String? rrule,
    bool clearRrule = false,
    List<String>? rdateUtc,
    List<String>? exdateUtc,
    String? timezoneId,
  }) =>
      ExternalEventRecord(
        uid: uid ?? this.uid,
        recurrenceId:
            clearRecurrenceId ? null : (recurrenceId ?? this.recurrenceId),
        startUtc: startUtc ?? this.startUtc,
        endUtc: endUtc ?? this.endUtc,
        allDay: allDay ?? this.allDay,
        startSecond: startSecond ?? this.startSecond,
        endSecond: endSecond ?? this.endSecond,
        summary: summary ?? this.summary,
        status: status ?? this.status,
        transparency: transparency ?? this.transparency,
        sequence: sequence ?? this.sequence,
        dtstamp: dtstamp ?? this.dtstamp,
        rrule: clearRrule ? null : (rrule ?? this.rrule),
        rdateUtc: rdateUtc ?? this.rdateUtc,
        exdateUtc: exdateUtc ?? this.exdateUtc,
        timezoneId: timezoneId ?? this.timezoneId,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'uid': uid,
        'recurrenceId': recurrenceId,
        'startUtc': startUtc,
        'endUtc': endUtc,
        'allDay': allDay,
        'startSecond': startSecond,
        'endSecond': endSecond,
        'summary': summary,
        'status': status,
        'transparency': transparency,
        'sequence': sequence,
        'dtstamp': dtstamp,
        'rrule': rrule,
        'rdateUtc': rdateUtc,
        'exdateUtc': exdateUtc,
        'timezoneId': timezoneId,
      };

  static ExternalEventRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final uid = _text(j['uid']);
    if (uid == null || uid.isEmpty) return null;
    final start = _utcInstant(j['startUtc']);
    final end = _utcInstant(j['endUtc']);
    if (start == null || end == null) return null;
    if (end.isBefore(start)) return null;
    final status = _text(j['status']) ?? kExtStatusConfirmed;
    final transparency = _text(j['transparency']) ?? kExtTransparencyOpaque;
    if (!_oneOf(status, const <String>[
      kExtStatusConfirmed,
      kExtStatusTentative,
      kExtStatusCancelled,
    ])) {
      return null;
    }
    if (!_oneOf(transparency, const <String>[
      kExtTransparencyOpaque,
      kExtTransparencyTransparent,
    ])) {
      return null;
    }
    final rrule = _text(j['rrule']);
    final rruleText =
        (rrule == null || rrule.trim().isEmpty) ? null : rrule.trim();
    final rdate = _stringList(j['rdateUtc']);
    final exdate = _stringList(j['exdateUtc']);
    if (rdate == null || exdate == null) return null;
    final tz = _text(j['timezoneId']);
    return ExternalEventRecord(
      uid: uid,
      recurrenceId: _utcInstant(j['recurrenceId'])?.toIso8601String(),
      startUtc: start.toIso8601String(),
      endUtc: end.toIso8601String(),
      allDay: j['allDay'] == true,
      startSecond: math.max(0, _int(j['startSecond']) ?? 0),
      // 全天事件终点可以等于 86400（次日零点），多日事件更大，不设上限。
      endSecond: math.max(0, _int(j['endSecond']) ?? 0),
      summary: _text(j['summary']) ?? '',
      status: status,
      transparency: transparency,
      sequence: math.max(0, _int(j['sequence']) ?? 0),
      dtstamp: _text(j['dtstamp']) ?? '',
      rrule: rruleText,
      rdateUtc: List<String>.unmodifiable(rdate),
      exdateUtc: List<String>.unmodifiable(exdate),
      timezoneId: (tz == null || tz.isEmpty) ? 'UTC' : tz,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalEventRecord &&
      other.uid == uid &&
      other.recurrenceId == recurrenceId &&
      other.startUtc == startUtc &&
      other.endUtc == endUtc &&
      other.allDay == allDay &&
      other.startSecond == startSecond &&
      other.endSecond == endSecond &&
      other.summary == summary &&
      other.status == status &&
      other.transparency == transparency &&
      other.sequence == sequence &&
      other.dtstamp == dtstamp &&
      other.rrule == rrule &&
      _listEq(other.rdateUtc, rdateUtc) &&
      _listEq(other.exdateUtc, exdateUtc) &&
      other.timezoneId == timezoneId;

  @override
  int get hashCode => Object.hash(
        uid,
        recurrenceId,
        startUtc,
        endUtc,
        allDay,
        status,
        transparency,
        sequence,
        rrule,
        Object.hashAll(rdateUtc),
        Object.hashAll(exdateUtc),
        timezoneId,
      );

  @override
  String toString() => 'ExternalEventRecord($identityKey, $startUtc-$endUtc, '
      'tz=$timezoneId, ${rrule == null ? 'single' : 'rrule'})';
}

/// 展开后的一个占用实例（已按规划时区按自然日拆分前的绝对区间）。
///
/// 同一实例跨 2 天以上时在结果里拆成多条（同一 uid/recurrenceId，不同 dayKey）。
class ExternalBusyInstance {
  const ExternalBusyInstance({
    required this.sourceId,
    required this.uid,
    this.recurrenceId,
    required this.startUtc,
    required this.endUtc,
    this.busy = true,
    this.tentative = false,
    required this.dayKey,
    required this.startMinute,
    required this.endMinute,
  });

  final String sourceId;
  final String uid;
  final String? recurrenceId;

  /// 半开区间（已按分钟保守外扩，但保留原秒信息由调用方按需使用）。
  final DateTime startUtc;
  final DateTime endUtc;

  /// 按来源策略是否计为占用。
  final bool busy;

  /// 是否暂定（STATUS:TENTATIVE）。
  final bool tentative;

  /// 规划时区 `yyyy-MM-dd`（该段起点所在日）。
  final String dayKey;

  /// 该 dayKey 当天内的分钟，[0,1440]；起点 floor、终点 ceil。
  final int startMinute;
  final int endMinute;

  int get minutes => endMinute - startMinute;

  /// 稳定身份（同一实例跨日拆段时共享）。
  String get identityKey =>
      recurrenceId == null ? uid : '$uid|$recurrenceId';

  @override
  String toString() => 'ExternalBusyInstance($sourceId/$identityKey '
      '$dayKey $startMinute-$endMinute busy=$busy)';
}

/// 用户管理的一个外部日历来源。
class ExternalCalendarSource {
  const ExternalCalendarSource({
    required this.id,
    required this.name,
    this.type = kExternalCalendarTypeLocalFile,
    this.filePath = '',
    this.contentHash = '',
    this.importedAt = '',
    this.revision = 0,
    this.dateFrom = '',
    this.dateTo = '',
    this.timezoneId = '',
    this.enabled = true,
    this.policy = const ExternalCalendarPolicy(),
    this.stats = const ExtImportStats(),
  });

  /// `ext-` + 12 位十六进制；创建时生成，与内容无关。
  final String id;
  final String name;
  final String type;
  final String filePath;
  final String contentHash;
  final String importedAt;

  /// 每次**成功提交**（内容或策略真正变化）后 +1。
  final int revision;

  /// 已导入覆盖范围 `yyyy-MM-dd`（规划时区）。
  final String dateFrom;
  final String dateTo;

  /// 导入时使用的应用时区。
  final String timezoneId;

  final bool enabled;
  final ExternalCalendarPolicy policy;
  final ExtImportStats stats;

  ExternalCalendarSource copyWith({
    String? id,
    String? name,
    String? type,
    String? filePath,
    String? contentHash,
    String? importedAt,
    int? revision,
    String? dateFrom,
    String? dateTo,
    String? timezoneId,
    bool? enabled,
    ExternalCalendarPolicy? policy,
    ExtImportStats? stats,
  }) =>
      ExternalCalendarSource(
        id: id ?? this.id,
        name: name ?? this.name,
        type: type ?? this.type,
        filePath: filePath ?? this.filePath,
        contentHash: contentHash ?? this.contentHash,
        importedAt: importedAt ?? this.importedAt,
        revision: revision ?? this.revision,
        dateFrom: dateFrom ?? this.dateFrom,
        dateTo: dateTo ?? this.dateTo,
        timezoneId: timezoneId ?? this.timezoneId,
        enabled: enabled ?? this.enabled,
        policy: policy ?? this.policy,
        stats: stats ?? this.stats,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'type': type,
        'filePath': filePath,
        'contentHash': contentHash,
        'importedAt': importedAt,
        'revision': revision,
        'dateFrom': dateFrom,
        'dateTo': dateTo,
        'timezoneId': timezoneId,
        'enabled': enabled,
        'policy': policy.toJson(),
        'stats': stats.toJson(),
      };

  static ExternalCalendarSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final id = _text(j['id']);
    if (id == null || id.isEmpty) return null;
    final name = _text(j['name']);
    final revision = _int(j['revision']);
    if (revision == null || revision < 0) return null;
    final type = _text(j['type']);
    return ExternalCalendarSource(
      id: id,
      name: (name == null || name.isEmpty) ? '外部日历' : name,
      type: (type == null || type.isEmpty)
          ? kExternalCalendarTypeLocalFile
          : type,
      filePath: _text(j['filePath']) ?? '',
      contentHash: _text(j['contentHash']) ?? '',
      importedAt: _text(j['importedAt']) ?? '',
      revision: revision,
      dateFrom: _text(j['dateFrom']) ?? '',
      dateTo: _text(j['dateTo']) ?? '',
      timezoneId: _text(j['timezoneId']) ?? '',
      enabled: j['enabled'] != false,
      policy: ExternalCalendarPolicy.fromJson(j['policy']),
      stats: ExtImportStats.fromJson(j['stats']),
    );
  }

  /// 展示用：内容哈希前 8 位。
  String get shortHash =>
      contentHash.length <= 8 ? contentHash : contentHash.substring(0, 8);

  /// 覆盖天数（含首尾）；非法范围返回 0。
  int get coveredDays {
    final from = parseDateKey(dateFrom);
    final to = parseDateKey(dateTo);
    if (from == null || to == null) return 0;
    final a = parseDateKeyUtc(from);
    final b = parseDateKeyUtc(to);
    if (a == null || b == null) return 0;
    final days = b.difference(a).inDays + 1;
    return days < 0 ? 0 : days;
  }

  ExternalCalendarSource withImportResult({
    required String contentHash,
    required String importedAt,
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
    required ExternalCalendarPolicy policy,
    required ExtImportStats stats,
    required bool contentChanged,
    String? filePath,
    String? name,
  }) =>
      copyWith(
        name: name,
        filePath: filePath ?? this.filePath,
        contentHash: contentHash,
        importedAt: importedAt,
        revision: contentChanged ? revision + 1 : revision,
        dateFrom: dateFrom,
        dateTo: dateTo,
        timezoneId: timezoneId,
        policy: policy,
        stats: stats,
      );

  @override
  bool operator ==(Object other) =>
      other is ExternalCalendarSource &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.filePath == filePath &&
      other.contentHash == contentHash &&
      other.importedAt == importedAt &&
      other.revision == revision &&
      other.dateFrom == dateFrom &&
      other.dateTo == dateTo &&
      other.timezoneId == timezoneId &&
      other.enabled == enabled &&
      other.policy == policy &&
      other.stats == stats;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        type,
        filePath,
        contentHash,
        importedAt,
        revision,
        dateFrom,
        dateTo,
        timezoneId,
        enabled,
        policy,
        stats,
      );

  @override
  String toString() => 'ExternalCalendarSource($id, $name, rev=$revision, '
      'enabled=$enabled, ${stats.readEvents} events)';
}

/// 一个来源最近一次成功导入的完整快照（持久化：每个来源一份）。
class ExternalSourceSnapshot {
  const ExternalSourceSnapshot({
    required this.sourceId,
    required this.revision,
    required this.contentHash,
    required this.timezoneId,
    required this.dateFrom,
    required this.dateTo,
    this.policy = const ExternalCalendarPolicy(),
    this.events = const <ExternalEventRecord>[],
    this.warnings = const <ExtImportWarning>[],
    this.stats = const ExtImportStats(),
  });

  final String sourceId;
  final int revision;
  final String contentHash;
  final String timezoneId;
  final String dateFrom;
  final String dateTo;
  final ExternalCalendarPolicy policy;
  final List<ExternalEventRecord> events;
  final List<ExtImportWarning> warnings;
  final ExtImportStats stats;

  int get schemaVersion => kExternalSnapshotSchemaVersion;

  ExternalSourceSnapshot copyWith({
    String? sourceId,
    int? revision,
    String? contentHash,
    String? timezoneId,
    String? dateFrom,
    String? dateTo,
    ExternalCalendarPolicy? policy,
    List<ExternalEventRecord>? events,
    List<ExtImportWarning>? warnings,
    ExtImportStats? stats,
  }) =>
      ExternalSourceSnapshot(
        sourceId: sourceId ?? this.sourceId,
        revision: revision ?? this.revision,
        contentHash: contentHash ?? this.contentHash,
        timezoneId: timezoneId ?? this.timezoneId,
        dateFrom: dateFrom ?? this.dateFrom,
        dateTo: dateTo ?? this.dateTo,
        policy: policy ?? this.policy,
        events: events ?? this.events,
        warnings: warnings ?? this.warnings,
        stats: stats ?? this.stats,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': kExternalSnapshotSchemaVersion,
        'sourceId': sourceId,
        'revision': revision,
        'contentHash': contentHash,
        'timezoneId': timezoneId,
        'dateFrom': dateFrom,
        'dateTo': dateTo,
        'policy': policy.toJson(),
        'events': events.map((e) => e.toJson()).toList(growable: false),
        'warnings': warnings.map((w) => w.toJson()).toList(growable: false),
        'stats': stats.toJson(),
      };

  /// 严格解析：任何一条事件/警告不合法都整体返回 null（回退 .bak）。
  static ExternalSourceSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final version = _int(j['schemaVersion']);
    if (version != kExternalSnapshotSchemaVersion) return null;
    final sourceId = _text(j['sourceId']);
    final revision = _int(j['revision']);
    if (sourceId == null || sourceId.isEmpty) return null;
    if (revision == null || revision < 0) return null;
    final dateFrom = parseDateKey(_text(j['dateFrom']) ?? '');
    final dateTo = parseDateKey(_text(j['dateTo']) ?? '');
    if (dateFrom == null || dateTo == null) return null;
    if (dateTo.compareTo(dateFrom) < 0) return null;
    final rawEvents = j['events'];
    final events = <ExternalEventRecord>[];
    if (rawEvents is List) {
      for (final item in rawEvents) {
        final record = ExternalEventRecord.fromJson(item);
        if (record == null) return null;
        events.add(record);
      }
    } else if (rawEvents != null) {
      return null;
    }
    final rawWarnings = j['warnings'];
    final warnings = <ExtImportWarning>[];
    if (rawWarnings is List) {
      for (final item in rawWarnings) {
        final warning = ExtImportWarning.fromJson(item);
        if (warning == null) return null;
        warnings.add(warning);
      }
    } else if (rawWarnings != null) {
      return null;
    }
    return ExternalSourceSnapshot(
      sourceId: sourceId,
      revision: revision,
      contentHash: _text(j['contentHash']) ?? '',
      timezoneId: _text(j['timezoneId']) ?? '',
      dateFrom: dateFrom,
      dateTo: dateTo,
      policy: ExternalCalendarPolicy.fromJson(j['policy']),
      events: List<ExternalEventRecord>.unmodifiable(events),
      warnings: List<ExtImportWarning>.unmodifiable(warnings),
      stats: ExtImportStats.fromJson(j['stats']),
    );
  }

  @override
  String toString() => 'ExternalSourceSnapshot($sourceId, rev=$revision, '
      '${events.length} events, ${warnings.length} warnings)';
}

// ------------------------------------------------------------------ helpers

/// 稳定的 UTC ISO 字符串（毫秒精度）。
String isoUtcOf(DateTime instant) => instant.toUtc().toIso8601String();

/// 解析 ISO8601 时刻；非法返回 null。
DateTime? parseIsoUtc(Object? value) => _utcInstant(value);

/// 生成来源 id：`ext-` + 12 位小写十六进制。
String newExternalSourceId([math.Random? random]) {
  final rng = random ?? math.Random.secure();
  final buffer = StringBuffer('ext-');
  for (var i = 0; i < 6; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 原始文件字节的 sha256（小写十六进制）。内容哈希是幂等判定的依据。
String sha256HexOfBytes(List<int> bytes) => sha256.convert(bytes).toString();

/// `yyyy-MM-dd` → UTC 零点 DateTime（只用于日期运算，不代表真实时刻）。
DateTime? parseDateKeyUtc(String text) {
  final key = parseDateKey(text);
  if (key == null) return null;
  final parts = key.split('-');
  return DateTime.utc(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

/// 日期运算：`yyyy-MM-dd` 加若干天。
String addDaysToDateKeyValue(String dateKey, int days) {
  final base = parseDateKeyUtc(dateKey);
  if (base == null) return dateKey;
  final next = base.add(Duration(days: days));
  return WallClock.formatDateKey(next.year, next.month, next.day);
}

/// 两个 `yyyy-MM-dd` 之间的自然日数（含首尾）。
int dateKeySpanDays(String from, String to) {
  final a = parseDateKeyUtc(from);
  final b = parseDateKeyUtc(to);
  if (a == null || b == null) return 0;
  final days = b.difference(a).inDays + 1;
  return days < 0 ? 0 : days;
}

String? _text(Object? value) {
  if (value is String) return value;
  if (value == null) return null;
  return '$value';
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool _oneOf(String value, List<String> options) => options.contains(value);

DateTime? _utcInstant(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return parsed.toUtc();
}

List<String>? _stringList(Object? value) {
  if (value == null) return <String>[];
  if (value is! List) return null;
  final out = <String>[];
  for (final item in value) {
    final text = _text(item);
    if (text == null) return null;
    out.add(text);
  }
  return out;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
