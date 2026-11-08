// 全局日程的持久化模型（与任务/计划版本无关）。
//
// 产品规则（01 框架 §3/§7）：
//   * 定时日程保存"本地墙钟 + IANA 时区"，全天日程保存
//     [startDate, endDateExclusive)；两套时间字段严格互斥，脏组合直接拒绝，
//     不默默补日期、不改时区；
//   * 重复只有 none/daily/weekly；每周的 weekdays 为 1..7、非空且唯一；
//     untilDate 是包含该日的最后一天；
//   * 例外按稳定 occurrenceKey（eventId + 原始发生日期）保存：exclusion 或
//     override（改到别的日期后 key 仍指向原始日期）；
//   * 文件里的数据只能通过 ScheduleEvent.tryParse 进入内存；任何一条不合法
//     整体判为不合法，由存储层决定只读/回退，绝不把半个库当完整数据。

import 'calendar.dart';

/// 标题/地点/备注长度上限（产品规则）。
const int kScheduleTitleMaxLength = 200;
const int kScheduleLocationMaxLength = 300;
const int kScheduleNotesMaxLength = 5000;

/// 分类固定为工作/学习/生活；空表示未分类。只映射现有主题色，不做自由配色。
enum ScheduleCategory {
  work('work'),
  study('study'),
  life('life');

  const ScheduleCategory(this.wireName);
  final String wireName;

  static ScheduleCategory? parse(Object? value) {
    switch (value is String ? value : '$value') {
      case 'work':
        return ScheduleCategory.work;
      case 'study':
        return ScheduleCategory.study;
      case 'life':
        return ScheduleCategory.life;
    }
    return null;
  }

  String get label {
    switch (this) {
      case ScheduleCategory.work:
        return '工作';
      case ScheduleCategory.study:
        return '学习';
      case ScheduleCategory.life:
        return '生活';
    }
  }
}

/// 重复类型：本轮只支持不重复/每天/每周指定星期。
enum ScheduleRepeatKind {
  none('none'),
  daily('daily'),
  weekly('weekly');

  const ScheduleRepeatKind(this.wireName);
  final String wireName;

  static ScheduleRepeatKind? parse(Object? value) {
    switch (value is String ? value : '$value') {
      case 'none':
        return ScheduleRepeatKind.none;
      case 'daily':
        return ScheduleRepeatKind.daily;
      case 'weekly':
        return ScheduleRepeatKind.weekly;
    }
    return null;
  }
}

/// 提醒类型：定时日程"开始时/提前 5/15/30 分钟/提前 1 天"；全天日程
/// "当天 09:00 / 前一天 09:00"。none 表示不提醒。
enum ScheduleReminderKind {
  none('none'),
  atStart('atStart'),
  minutes5('minutes5'),
  minutes15('minutes15'),
  minutes30('minutes30'),
  dayBefore('dayBefore'),
  allDaySameDay('allDaySameDay'),
  allDayPrevDay('allDayPrevDay');

  const ScheduleReminderKind(this.wireName);
  final String wireName;

  static ScheduleReminderKind? parse(Object? value) {
    switch (value is String ? value : '$value') {
      case 'none':
        return ScheduleReminderKind.none;
      case 'atStart':
        return ScheduleReminderKind.atStart;
      case 'minutes5':
        return ScheduleReminderKind.minutes5;
      case 'minutes15':
        return ScheduleReminderKind.minutes15;
      case 'minutes30':
        return ScheduleReminderKind.minutes30;
      case 'dayBefore':
        return ScheduleReminderKind.dayBefore;
      case 'allDaySameDay':
        return ScheduleReminderKind.allDaySameDay;
      case 'allDayPrevDay':
        return ScheduleReminderKind.allDayPrevDay;
    }
    return null;
  }

  bool get isAllDayOnly =>
      this == ScheduleReminderKind.allDaySameDay ||
      this == ScheduleReminderKind.allDayPrevDay;

  bool get isTimedOnly => !isAllDayOnly && this != ScheduleReminderKind.none;

  String get label {
    switch (this) {
      case ScheduleReminderKind.none:
        return '不提醒';
      case ScheduleReminderKind.atStart:
        return '开始时';
      case ScheduleReminderKind.minutes5:
        return '提前 5 分钟';
      case ScheduleReminderKind.minutes15:
        return '提前 15 分钟';
      case ScheduleReminderKind.minutes30:
        return '提前 30 分钟';
      case ScheduleReminderKind.dayBefore:
        return '提前 1 天';
      case ScheduleReminderKind.allDaySameDay:
        return '当天 09:00';
      case ScheduleReminderKind.allDayPrevDay:
        return '前一天 09:00';
    }
  }
}

/// 重复规则。none 不允许携带 weekdays/untilDate；daily 不允许 weekdays；
/// weekly 必须有非空且唯一的 weekdays。
class ScheduleRepeatRule {
  const ScheduleRepeatRule._({
    required this.kind,
    this.weekdays = const <int>[],
    this.untilDate,
  });

  const ScheduleRepeatRule.none() : this._(kind: ScheduleRepeatKind.none);

  const ScheduleRepeatRule.daily({String? untilDate})
      : this._(kind: ScheduleRepeatKind.daily, untilDate: untilDate);

  const ScheduleRepeatRule.weekly({
    required List<int> weekdays,
    String? untilDate,
  }) : this._(
          kind: ScheduleRepeatKind.weekly,
          weekdays: weekdays,
          untilDate: untilDate,
        );

  final ScheduleRepeatKind kind;

  /// 1 = 周一 … 7 = 周日；仅 weekly 使用。
  final List<int> weekdays;

  /// 包含该日的最后一天（yyyy-MM-dd）；null = 不设结束。
  final String? untilDate;

  bool get repeats => kind != ScheduleRepeatKind.none;

  bool get isValid {
    switch (kind) {
      case ScheduleRepeatKind.none:
        return weekdays.isEmpty && untilDate == null;
      case ScheduleRepeatKind.daily:
        return weekdays.isEmpty;
      case ScheduleRepeatKind.weekly:
        if (weekdays.isEmpty || weekdays.length > 7) return false;
        final unique = weekdays.toSet();
        if (unique.length != weekdays.length) return false;
        return weekdays.every((d) => d >= 1 && d <= 7);
    }
  }

  /// 该规则是否命中某个本地日期（yyyy-MM-dd）。untilDate 包含当天。
  bool matchesDate(String dateKey) {
    if (!isValid) return false;
    final until = untilDate;
    if (until != null && dateKey.compareTo(until) > 0) return false;
    switch (kind) {
      case ScheduleRepeatKind.none:
        return true; // 首个实例由事件 startDate 决定
      case ScheduleRepeatKind.daily:
        return true;
      case ScheduleRepeatKind.weekly:
        return weekdays.contains(weekdayOfDateKey(dateKey));
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.wireName,
        'weekdays': weekdays,
        'untilDate': untilDate,
      };

  static ScheduleRepeatRule? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final kind = ScheduleRepeatKind.parse(j['kind']);
    if (kind == null) return null;
    final weekdaysRaw = j['weekdays'];
    final weekdays = <int>[];
    if (weekdaysRaw != null) {
      if (weekdaysRaw is! List) return null;
      for (final value in weekdaysRaw) {
        if (value is! int) return null;
        weekdays.add(value);
      }
    }
    final untilRaw = (j['untilDate'] as String?)?.trim();
    final untilDate =
        (untilRaw == null || untilRaw.isEmpty) ? null : parseDateKey(untilRaw);
    if (untilRaw != null && untilRaw.isNotEmpty && untilDate == null) {
      return null;
    }
    final rule = ScheduleRepeatRule._(
      kind: kind,
      weekdays: List<int>.unmodifiable(weekdays),
      untilDate: untilDate,
    );
    if (!rule.isValid) return null;
    return rule;
  }
}

/// 单次例外：按原始 occurrenceKey 保存。excluded=true 表示本次删除；
/// 否则是 override（改时间/改日期），key 仍指向原始发生日期。
class ScheduleException {
  const ScheduleException.excluded({required this.occurrenceKey})
      : excluded = true,
        startDate = null,
        startMinute = null,
        endMinute = null,
        endDateExclusive = null;

  const ScheduleException.override({
    required this.occurrenceKey,
    required this.startDate,
    this.startMinute,
    this.endMinute,
    this.endDateExclusive,
  }) : excluded = false;

  final String occurrenceKey;
  final bool excluded;

  /// override：定时日程的本地日期/分钟（结束分钟可 >= 1440 表示跨日）。
  final String? startDate;
  final int? startMinute;
  final int? endMinute;

  /// override：全天日程的排他结束日期。
  final String? endDateExclusive;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': occurrenceKey,
        'excluded': excluded,
        if (!excluded) ...<String, dynamic>{
          'startDate': startDate,
          if (startMinute != null) 'startMinute': startMinute,
          if (endMinute != null) 'endMinute': endMinute,
          if (endDateExclusive != null) 'endDateExclusive': endDateExclusive,
        },
      };

  /// 严格解析；[allDay] 决定允许哪套 override 字段。
  static ScheduleException? tryParse(Object? raw, {required bool allDay}) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final key = (j['key'] as String?)?.trim() ?? '';
    if (!isValidOccurrenceKey(key)) return null;
    final excludedRaw = j['excluded'];
    if (excludedRaw is! bool) return null;
    if (excludedRaw) return ScheduleException.excluded(occurrenceKey: key);
    final startDate = parseDateKey(asText(j['startDate']));
    if (startDate == null) return null;
    if (allDay) {
      final endExclusive = parseDateKey(asText(j['endDateExclusive']));
      if (endExclusive == null) return null;
      if (endExclusive.compareTo(startDate) <= 0) return null;
      return ScheduleException.override(
        occurrenceKey: key,
        startDate: startDate,
        endDateExclusive: endExclusive,
      );
    }
    final startMinute = j['startMinute'];
    final endMinute = j['endMinute'];
    if (startMinute is! int || endMinute is! int) return null;
    if (startMinute < 0 || startMinute > 1439) return null;
    if (endMinute <= startMinute || endMinute > 1439 + 1440) return null;
    return ScheduleException.override(
      occurrenceKey: key,
      startDate: startDate,
      startMinute: startMinute,
      endMinute: endMinute,
    );
  }
}

/// 一条全局日程（系列）。删除 = deletedAtUtc 非空；存储层保留删除标记用于
/// 撤销与备份，查询时过滤。
class ScheduleEvent {
  const ScheduleEvent({
    required this.id,
    required this.revision,
    required this.title,
    required this.timezoneId,
    required this.startDate,
    this.location,
    this.notes,
    this.category,
    this.allDay = false,
    this.startMinute,
    this.endMinute,
    this.endDateExclusive,
    this.blocksScheduling = true,
    this.linkedConversationId,
    this.repeat = const ScheduleRepeatRule.none(),
    this.reminder = ScheduleReminderKind.none,
    this.exceptions = const <ScheduleException>[],
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.deletedAtUtc,
  });

  final String id;
  final int revision;
  final String title;
  final String? location;
  final String? notes;
  final ScheduleCategory? category;

  /// IANA 时区（例如 Asia/Shanghai）；展开时按该时区的当地钟点计算。
  final String timezoneId;

  final bool allDay;

  /// 定时日程：首个发生日的本地日期（yyyy-MM-dd）。
  final String startDate;

  /// 定时日程：本地开始/结束分钟，endMinute 可 > 1440 表示跨日。
  final int? startMinute;
  final int? endMinute;

  /// 全天日程：排他结束日期（yyyy-MM-dd）。
  final String? endDateExclusive;

  /// 是否占用排程时间（默认开启）；关闭后仍展示、仍可提醒。
  final bool blocksScheduling;

  /// 系列级单值关联（可空）；不决定日程作用域。
  final String? linkedConversationId;

  final ScheduleRepeatRule repeat;
  final ScheduleReminderKind reminder;
  final List<ScheduleException> exceptions;

  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? deletedAtUtc;

  bool get isDeleted => deletedAtUtc != null;

  /// 全天日程的持续天数（含首日）。
  int get allDayDayCount {
    final end = endDateExclusive;
    if (!allDay || end == null) return 1;
    final start = dateKeyToUtc(startDate);
    final stop = dateKeyToUtc(end);
    if (start == null || stop == null) return 1;
    return stop.difference(start).inDays;
  }

  ScheduleException? exceptionFor(String occurrenceKey) {
    for (final e in exceptions) {
      if (e.occurrenceKey == occurrenceKey) return e;
    }
    return null;
  }

  /// 修改序列规则后，哪些已保存例外不再命中新规则（需要用户确认，不默默删除）。
  List<String> exceptionsNoLongerMatching(ScheduleRepeatRule nextRule) {
    final out = <String>[];
    for (final exception in exceptions) {
      final originalDate = originalDateOfOccurrenceKey(exception.occurrenceKey);
      if (originalDate == null) continue;
      if (!nextRule.repeats) {
        if (originalDate != startDate) out.add(exception.occurrenceKey);
        continue;
      }
      if (!nextRule.matchesDate(originalDate)) {
        out.add(exception.occurrenceKey);
      }
    }
    return out;
  }

  /// 应用一份通过校验的编辑草稿（保留 id/createdAt/例外，除非显式替换）。
  ScheduleEvent appliedDraft(
    ScheduleDraft draft, {
    required int revision,
    required DateTime updatedAtUtc,
    List<ScheduleException>? exceptions,
  }) =>
      ScheduleEvent(
        id: id,
        revision: revision,
        title: draft.title.trim(),
        location: trimOrNull(draft.location),
        notes: trimOrNull(draft.notes),
        category: draft.category,
        timezoneId: draft.timezoneId.trim(),
        allDay: draft.allDay,
        startDate: draft.startDate,
        startMinute: draft.allDay ? null : draft.startMinute,
        endMinute: draft.allDay ? null : draft.endMinute,
        endDateExclusive: draft.allDay ? draft.endDateExclusive : null,
        blocksScheduling: draft.blocksScheduling,
        linkedConversationId: trimOrNull(draft.linkedConversationId),
        repeat: draft.repeat,
        reminder: draft.reminder,
        exceptions: exceptions ?? this.exceptions,
        createdAtUtc: createdAtUtc,
        updatedAtUtc: updatedAtUtc,
      );

  ScheduleEvent copyWith({
    int? revision,
    DateTime? updatedAtUtc,
    DateTime? deletedAtUtc,
    bool clearDeleted = false,
    List<ScheduleException>? exceptions,
  }) =>
      ScheduleEvent(
        id: id,
        revision: revision ?? this.revision,
        title: title,
        location: location,
        notes: notes,
        category: category,
        timezoneId: timezoneId,
        allDay: allDay,
        startDate: startDate,
        startMinute: startMinute,
        endMinute: endMinute,
        endDateExclusive: endDateExclusive,
        blocksScheduling: blocksScheduling,
        linkedConversationId: linkedConversationId,
        repeat: repeat,
        reminder: reminder,
        exceptions: exceptions ?? this.exceptions,
        createdAtUtc: createdAtUtc,
        updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
        deletedAtUtc: clearDeleted ? null : (deletedAtUtc ?? this.deletedAtUtc),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'revision': revision,
        'title': title,
        'location': location,
        'notes': notes,
        'category': category?.wireName,
        'timezoneId': timezoneId,
        'allDay': allDay,
        'startDate': startDate,
        if (!allDay) ...<String, dynamic>{
          'startMinute': startMinute,
          'endMinute': endMinute,
        },
        if (allDay) 'endDateExclusive': endDateExclusive,
        'blocksScheduling': blocksScheduling,
        'linkedConversationId': linkedConversationId,
        'repeat': repeat.toJson(),
        'reminder': reminder.wireName,
        'exceptions': exceptions.map((e) => e.toJson()).toList(growable: false),
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
        'deletedAtUtc': deletedAtUtc?.toUtc().toIso8601String(),
      };

  /// 严格解析：任何字段不合法都返回 null（由调用方决定只读/丢弃整库）。
  static ScheduleEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);

    final id = (j['id'] as String?)?.trim() ?? '';
    if (id.isEmpty || id.length > 80 || id.contains(RegExp(r'\s'))) {
      return null;
    }
    final revision = j['revision'];
    if (revision is! int || revision < 0) return null;

    final title = (j['title'] as String?)?.trim() ?? '';
    if (title.isEmpty || title.length > kScheduleTitleMaxLength) return null;

    final location = optionalText(j['location'], kScheduleLocationMaxLength);
    if (location == invalidText) return null;
    final notes = optionalText(j['notes'], kScheduleNotesMaxLength);
    if (notes == invalidText) return null;

    ScheduleCategory? category;
    final categoryRaw = j['category'];
    if (categoryRaw != null && '$categoryRaw'.isNotEmpty) {
      category = ScheduleCategory.parse(categoryRaw);
      if (category == null) return null;
    }

    final timezoneId = (j['timezoneId'] as String?)?.trim() ?? '';
    if (timezoneId.isEmpty || timezoneId.length > 64) return null;

    final allDayRaw = j['allDay'];
    if (allDayRaw is! bool) return null;
    final allDay = allDayRaw;

    final startDate = parseDateKey(asText(j['startDate']));
    if (startDate == null) return null;

    int? startMinute;
    int? endMinute;
    String? endDateExclusive;
    if (allDay) {
      if (j.containsKey('startMinute') || j.containsKey('endMinute')) {
        return null;
      }
      final end = parseDateKey(asText(j['endDateExclusive']));
      if (end == null || end.compareTo(startDate) <= 0) return null;
      endDateExclusive = end;
    } else {
      final sm = j['startMinute'];
      final em = j['endMinute'];
      if (sm is! int || em is! int) return null;
      if (sm < 0 || sm > 1439) return null;
      if (em <= sm || em > 1439 + 1440) return null;
      if (j.containsKey('endDateExclusive')) return null;
      startMinute = sm;
      endMinute = em;
    }

    final blocksRaw = j['blocksScheduling'];
    if (blocksRaw is! bool) return null;

    String? linkedConversationId;
    final linkedRaw = j['linkedConversationId'];
    if (linkedRaw != null && '$linkedRaw'.trim().isNotEmpty) {
      linkedConversationId = '$linkedRaw'.trim();
      if (linkedConversationId.length > 80 ||
          linkedConversationId.contains(RegExp(r'\s'))) {
        return null;
      }
    }

    final repeat = ScheduleRepeatRule.tryParse(j['repeat']);
    if (repeat == null) return null;
    final until = repeat.untilDate;
    if (until != null && until.compareTo(startDate) < 0) return null;

    final reminder = ScheduleReminderKind.parse(j['reminder']);
    if (reminder == null) return null;
    if (allDay && reminder.isTimedOnly) return null;
    if (!allDay && reminder.isAllDayOnly) return null;

    final exceptionsRaw = j['exceptions'];
    final exceptions = <ScheduleException>[];
    if (exceptionsRaw != null) {
      if (exceptionsRaw is! List) return null;
      final keys = <String>{};
      for (final item in exceptionsRaw) {
        final parsed = ScheduleException.tryParse(item, allDay: allDay);
        if (parsed == null) return null;
        if (parsed.occurrenceKey.split('@').first != id) return null;
        if (!keys.add(parsed.occurrenceKey)) return null;
        exceptions.add(parsed);
      }
    }

    final created = parseUtc(j['createdAtUtc']);
    final updated = parseUtc(j['updatedAtUtc']);
    if (created == null || updated == null) return null;
    DateTime? deleted;
    final deletedRaw = j['deletedAtUtc'];
    if (deletedRaw != null && '$deletedRaw'.isNotEmpty) {
      deleted = parseUtc(deletedRaw);
      if (deleted == null) return null;
    }

    return ScheduleEvent(
      id: id,
      revision: revision,
      title: title,
      location: location as String?,
      notes: notes as String?,
      category: category,
      timezoneId: timezoneId,
      allDay: allDay,
      startDate: startDate,
      startMinute: startMinute,
      endMinute: endMinute,
      endDateExclusive: endDateExclusive,
      blocksScheduling: blocksRaw,
      linkedConversationId: linkedConversationId,
      repeat: repeat,
      reminder: reminder,
      exceptions: List<ScheduleException>.unmodifiable(exceptions),
      createdAtUtc: created,
      updatedAtUtc: updated,
      deletedAtUtc: deleted,
    );
  }
}

/// 可校验的编辑输入（不含 id/revision/时间戳/删除标记）。
class ScheduleDraft {
  const ScheduleDraft({
    required this.title,
    required this.timezoneId,
    required this.startDate,
    this.location,
    this.notes,
    this.category,
    this.allDay = false,
    this.startMinute,
    this.endMinute,
    this.endDateExclusive,
    this.blocksScheduling = true,
    this.linkedConversationId,
    this.repeat = const ScheduleRepeatRule.none(),
    this.reminder = ScheduleReminderKind.none,
  });

  final String title;
  final String? location;
  final String? notes;
  final ScheduleCategory? category;
  final String timezoneId;
  final bool allDay;
  final String startDate;
  final int? startMinute;
  final int? endMinute;
  final String? endDateExclusive;
  final bool blocksScheduling;
  final String? linkedConversationId;
  final ScheduleRepeatRule repeat;
  final ScheduleReminderKind reminder;

  /// 校验草稿并返回用户可读原因；null = 合法。
  String? validate() {
    final t = title.trim();
    if (t.isEmpty) return '标题不能为空';
    if (t.length > kScheduleTitleMaxLength) {
      return '标题不能超过 $kScheduleTitleMaxLength 个字符';
    }
    final loc = location?.trim();
    if (loc != null && loc.length > kScheduleLocationMaxLength) {
      return '地点不能超过 $kScheduleLocationMaxLength 个字符';
    }
    final note = notes?.trim();
    if (note != null && note.length > kScheduleNotesMaxLength) {
      return '备注不能超过 $kScheduleNotesMaxLength 个字符';
    }
    if (timezoneId.trim().isEmpty) return '时区不能为空';
    if (parseDateKey(startDate) == null) return '开始日期不合法';
    if (allDay) {
      if (startMinute != null || endMinute != null) {
        return '全天日程不能带具体时刻';
      }
      final endRaw = endDateExclusive;
      final end = endRaw == null ? null : parseDateKey(endRaw);
      if (end == null || end.compareTo(startDate) <= 0) {
        return '全天日程的结束日期必须晚于开始日期';
      }
    } else {
      final sm = startMinute;
      final em = endMinute;
      if (sm == null || em == null) return '缺少开始或结束时间';
      if (sm < 0 || sm > 1439) return '开始时间不合法';
      if (em <= sm) return '结束时间必须晚于开始时间';
      if (em > 1439 + 1440) return '单次日程不能超过 24 小时';
      if (endDateExclusive != null) return '定时日程不能带全天结束日期';
    }
    if (!repeat.isValid) return '重复规则不合法';
    final until = repeat.untilDate;
    if (until != null && until.compareTo(startDate) < 0) {
      return '重复结束日期不能早于开始日期';
    }
    if (allDay && reminder.isTimedOnly) return '全天日程不能选择定时提醒';
    if (!allDay && reminder.isAllDayOnly) return '定时日程不能选择全天提醒';
    return null;
  }

  /// 应用到新事件（由控制器分配 id/revision/时间戳）。
  ScheduleEvent toEvent({
    required String id,
    required int revision,
    required DateTime nowUtc,
    List<ScheduleException> exceptions = const <ScheduleException>[],
  }) {
    final error = validate();
    if (error != null) throw ScheduleValidationException(error);
    return ScheduleEvent(
      id: id,
      revision: revision,
      title: title.trim(),
      location: trimOrNull(location),
      notes: trimOrNull(notes),
      category: category,
      timezoneId: timezoneId.trim(),
      allDay: allDay,
      startDate: startDate,
      startMinute: allDay ? null : startMinute,
      endMinute: allDay ? null : endMinute,
      endDateExclusive: allDay ? endDateExclusive : null,
      blocksScheduling: blocksScheduling,
      linkedConversationId: trimOrNull(linkedConversationId),
      repeat: repeat,
      reminder: reminder,
      exceptions: exceptions,
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
  }

  /// 从已有事件生成草稿（编辑弹窗初值）。
  factory ScheduleDraft.fromEvent(ScheduleEvent event) => ScheduleDraft(
        title: event.title,
        location: event.location,
        notes: event.notes,
        category: event.category,
        timezoneId: event.timezoneId,
        allDay: event.allDay,
        startDate: event.startDate,
        startMinute: event.startMinute,
        endMinute: event.endMinute,
        endDateExclusive: event.endDateExclusive,
        blocksScheduling: event.blocksScheduling,
        linkedConversationId: event.linkedConversationId,
        repeat: event.repeat,
        reminder: event.reminder,
      );
}

class ScheduleValidationException implements Exception {
  const ScheduleValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// occurrenceKey = eventId@原始发生日期。
String scheduleOccurrenceKey(String eventId, String originalDate) =>
    '$eventId@$originalDate';

bool isValidOccurrenceKey(String key) {
  final at = key.lastIndexOf('@');
  if (at <= 0 || at == key.length - 1) return false;
  return parseDateKey(key.substring(at + 1)) != null;
}

String? originalDateOfOccurrenceKey(String key) {
  final at = key.lastIndexOf('@');
  if (at <= 0 || at == key.length - 1) return null;
  return parseDateKey(key.substring(at + 1));
}

String? eventIdOfOccurrenceKey(String key) {
  final at = key.lastIndexOf('@');
  if (at <= 0) return null;
  return key.substring(0, at);
}

/// 周二=2 … 周日=7（与 ScheduleRepeatRule.weekdays 一致；DateTime.weekday 同义）。
int weekdayOfDateKey(String dateKey) {
  final date = dateKeyToUtc(dateKey);
  if (date == null) return 0;
  return date.weekday;
}

DateTime? dateKeyToUtc(String dateKey) {
  final parts = dateKey.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  final value = DateTime.utc(y, m, d);
  if (value.year != y || value.month != m || value.day != d) return null;
  return value;
}

/// 把任意 JSON 值转成字符串（缺省为空串），供严格解析读取日期字段。
String asText(Object? raw) => raw == null ? '' : '$raw';

Object? optionalText(Object? raw, int maxLength) {
  if (raw == null) return null;
  if (raw is! String) return invalidText;
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (value.length > maxLength) return invalidText;
  return value;
}

String? trimOrNull(String? value) {
  final v = value?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

DateTime? parseUtc(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim())?.toUtc();
}

/// [optionalText] 的非法哨兵（与合法 null/文本区分）。
const Object invalidText = _InvalidText();

class _InvalidText {
  const _InvalidText();
}
