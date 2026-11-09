// 任务执行截止与提醒的数据模型（0.5.0 任务 13）。
//
// 设计口径（改动前先读）：
//   * **一次执行一个身份**：[ExecutionDeadlineSession.executionId] 在“开始任务”成功
//     后生成，暂停/继续/延长恢复都沿用同一身份；每次真正落盘的计时区间是账本里的
//     [ExecutionRecord]，会话保存 recordIds，便于跨重启核对。
//   * **有效截止只来自当前生效甘特排程**：会话保存解析到的最后一段结束时刻
//     （[deadlineUtc]）与期限版本 [deadlineVersion]；手动改排程会重新解析，旧期限失效。
//   * **两次提醒与自动完成都绑定“已投递”事实**：第一次在截止点，第二次在第一次
//     投递后 [secondReminderDelay]，自动完成在第二次投递后 [autoCompleteDelay]。
//     未成功投递的提醒不会开始响应窗口，重启后补发并留足完整窗口。
//   * **投递结果单独记账**：[ExecutionNotificationDelivery] 记录每次尝试的渠道、
//     是否被系统接受与失败原因；原生不可用时改由前台等价操作投递，绝不声称已投递。
//   * **等待时间不计工时**：等待阶段的 5＋5 分钟只是提醒状态机，不产生执行区间。
//
// JSON 一律 camelCase；读取旧/缺字段时给明确默认值，绝不编造截止或投递事实。

import 'execution_models.dart' show parseUtc;

/// 截止会话存储结构版本。读到更大版本时上层只读，不覆盖新数据。
const int kExecutionDeadlineSchemaVersion = 1;

/// 保留的历史会话上限（自动完成/已取消），防止文件无限增长。
const int kMaxRetainedDeadlineSessions = 80;

/// 执行截止的阶段。
///
/// [scheduled] 表示“已开始、还没到截止”的生命周期阶段（包含运行中与暂停中）；
/// [pending] = 到点已结算、任务待处理（第一次提醒）；[secondReminder] = 第二次提醒
/// 已投递、响应窗口进行中；[completed] = 已按到期/手动结束完成；
/// [cancelled] = 只停止计时/撤销完成/任务删除等，不再提醒。
enum ExecutionDeadlineStage {
  scheduled,
  pending,
  secondReminder,
  completed,
  cancelled,
}

/// 一次可操作通知的投递记录（原生或前台等价操作）。
class ExecutionNotificationDelivery {
  const ExecutionNotificationDelivery({
    required this.kind,
    required this.atUtc,
    required this.channel,
    required this.accepted,
    this.errorKind,
    this.error,
  });

  /// `started` / `deadline`（第一次提醒）/ `second`（第二次提醒）。
  final String kind;

  /// 尝试投递的时刻（UTC）。
  final DateTime atUtc;

  /// `native` = 系统通知；`foreground` = 应用内等价操作。
  final String channel;

  /// 系统/前台是否真正接受并显示。
  final bool accepted;

  final String? errorKind;
  final String? error;

  String get channelLabel => channel == 'foreground' ? '应用内' : '系统通知';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'atUtc': atUtc.toUtc().toIso8601String(),
        'channel': channel,
        'accepted': accepted,
        'errorKind': errorKind,
        'error': error,
      };

  static ExecutionNotificationDelivery? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final at = parseUtc(j['atUtc']);
    final kind = (j['kind'] as String?)?.trim() ?? '';
    if (at == null || kind.isEmpty) return null;
    return ExecutionNotificationDelivery(
      kind: kind,
      atUtc: at,
      channel: (j['channel'] as String?) == 'foreground' ? 'foreground' : 'native',
      accepted: j['accepted'] == true,
      errorKind: j['errorKind'] as String?,
      error: j['error'] as String?,
    );
  }
}

/// 一条执行截止会话。
///
/// 同一任务可以有多次“开始→（到期/结束）”，每次执行都有自己的 [executionId]；
/// 旧会话保留为 [ExecutionDeadlineStage.completed]/[cancelled] 历史，便于旧通知
/// 重放时识别“身份不存在”而不会误作用到别的任务。
class ExecutionDeadlineSession {
  const ExecutionDeadlineSession({
    required this.executionId,
    required this.conversationId,
    required this.taskId,
    required this.taskName,
    required this.stage,
    required this.startedAtUtc,
    required this.revision,
    this.deadlineUtc,
    this.deadlineVersion = 1,
    this.recordIds = const <String>[],
    this.settledAtUtc,
    this.firstDeliveredAtUtc,
    this.firstDeliveryChannel,
    this.secondDeliveredAtUtc,
    this.secondDeliveryChannel,
    this.responseWindowEndsAtUtc,
    this.responseDeadlineVersion,
    this.completedAtUtc,
    this.completionSource,
    this.completionError,
    this.autoCompleteAttemptedAtUtc,
    this.scheduleChanged = false,
    this.notice,
    this.deliveries = const <ExecutionNotificationDelivery>[],
  });

  /// 稳定执行身份（与账本 recordId 不同：一次执行可含多条区间记录）。
  final String executionId;

  final String conversationId;
  final String taskId;

  /// 任务名快照（通知与顶部状态条显示）。
  final String taskName;

  final ExecutionDeadlineStage stage;

  /// 本次执行开始时刻（UTC）。
  final DateTime startedAtUtc;

  /// 会话修订号：每次状态变化 +1，用于“延长确认 vs 自动完成”的 CAS 校验。
  final int revision;

  /// 当前生效的有效截止（UTC）；null = 当前没有可用甘特排程，不安排提醒。
  final DateTime? deadlineUtc;

  /// 期限版本：每次根据排程重新解析（手动调整排程）时 +1；旧期限操作据此失效。
  final int deadlineVersion;

  /// 本次执行已写入账本的记录 id（延长后恢复计时会产生新记录）。
  final List<String> recordIds;

  /// 到截止点完成结算的时刻（进入待处理）。
  final DateTime? settledAtUtc;

  // ---- 第一次提醒（到点） ----
  final DateTime? firstDeliveredAtUtc;
  final String? firstDeliveryChannel;

  // ---- 第二次提醒（第一次投递 + 5 分钟）----
  final DateTime? secondDeliveredAtUtc;
  final String? secondDeliveryChannel;

  /// 第二次提醒的响应窗口结束时刻（= 自动完成时刻，UTC）。
  final DateTime? responseWindowEndsAtUtc;

  /// 第二次投递时的期限版本；自动完成必须仍匹配这个版本。
  final int? responseDeadlineVersion;

  final DateTime? completedAtUtc;

  /// `auto` = 到期自动完成；`manual` = 用户结束/勾选完成；`stop` = 仅停止计时。
  final String? completionSource;

  /// 最近一次完成尝试的失败原因（部分成功可重试；失败不重写工时）。
  final String? completionError;

  final DateTime? autoCompleteAttemptedAtUtc;

  /// 等待期间发现排程被手动改过（只提示，不自动延长）。
  final bool scheduleChanged;

  /// 最近一次写入状态时给用户看的一句话（不持久化展示，重启后由状态重新生成）。
  final String? notice;

  final List<ExecutionNotificationDelivery> deliveries;

  bool get isActive =>
      stage == ExecutionDeadlineStage.scheduled ||
      stage == ExecutionDeadlineStage.pending ||
      stage == ExecutionDeadlineStage.secondReminder;

  bool get hasDeadline => deadlineUtc != null;

  /// 第一次提醒是否已真正投递。
  bool get firstDelivered => firstDeliveredAtUtc != null;

  /// 第二次提醒是否已真正投递（响应窗口已开始）。
  bool get secondDelivered => secondDeliveredAtUtc != null;

  /// 第二次提醒的应投递时刻（第一次投递 + 5 分钟）。
  DateTime? get secondDueAtUtc => firstDeliveredAtUtc?.add(const Duration(minutes: 5));

  /// 自动完成时刻（第二次投递 + 5 分钟）。
  DateTime? get autoCompleteAtUtc => responseWindowEndsAtUtc;

  ExecutionDeadlineSession copyWith({
    String? taskName,
    ExecutionDeadlineStage? stage,
    DateTime? deadlineUtc,
    bool clearDeadline = false,
    int? deadlineVersion,
    List<String>? recordIds,
    DateTime? settledAtUtc,
    bool clearSettled = false,
    DateTime? firstDeliveredAtUtc,
    String? firstDeliveryChannel,
    bool clearFirstDelivery = false,
    DateTime? secondDeliveredAtUtc,
    String? secondDeliveryChannel,
    bool clearSecondDelivery = false,
    DateTime? responseWindowEndsAtUtc,
    bool clearResponseWindow = false,
    int? responseDeadlineVersion,
    DateTime? completedAtUtc,
    String? completionSource,
    String? completionError,
    bool clearCompletionError = false,
    DateTime? autoCompleteAttemptedAtUtc,
    bool? scheduleChanged,
    String? notice,
    bool clearNotice = false,
    List<ExecutionNotificationDelivery>? deliveries,
  }) =>
      ExecutionDeadlineSession(
        executionId: executionId,
        conversationId: conversationId,
        taskId: taskId,
        taskName: taskName ?? this.taskName,
        stage: stage ?? this.stage,
        startedAtUtc: startedAtUtc,
        revision: revision + 1,
        deadlineUtc:
            clearDeadline ? null : (deadlineUtc ?? this.deadlineUtc),
        deadlineVersion: deadlineVersion ?? this.deadlineVersion,
        recordIds: recordIds ?? this.recordIds,
        settledAtUtc:
            clearSettled ? null : (settledAtUtc ?? this.settledAtUtc),
        firstDeliveredAtUtc: clearFirstDelivery
            ? null
            : (firstDeliveredAtUtc ?? this.firstDeliveredAtUtc),
        firstDeliveryChannel: clearFirstDelivery
            ? null
            : (firstDeliveryChannel ?? this.firstDeliveryChannel),
        secondDeliveredAtUtc: clearSecondDelivery
            ? null
            : (secondDeliveredAtUtc ?? this.secondDeliveredAtUtc),
        secondDeliveryChannel: clearSecondDelivery
            ? null
            : (secondDeliveryChannel ?? this.secondDeliveryChannel),
        responseWindowEndsAtUtc: clearResponseWindow
            ? null
            : (responseWindowEndsAtUtc ?? this.responseWindowEndsAtUtc),
        responseDeadlineVersion:
            responseDeadlineVersion ?? this.responseDeadlineVersion,
        completedAtUtc: completedAtUtc ?? this.completedAtUtc,
        completionSource: completionSource ?? this.completionSource,
        completionError: clearCompletionError
            ? null
            : (completionError ?? this.completionError),
        autoCompleteAttemptedAtUtc:
            autoCompleteAttemptedAtUtc ?? this.autoCompleteAttemptedAtUtc,
        scheduleChanged: scheduleChanged ?? this.scheduleChanged,
        notice: clearNotice ? null : (notice ?? this.notice),
        deliveries: deliveries ?? this.deliveries,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'executionId': executionId,
        'conversationId': conversationId,
        'taskId': taskId,
        'taskName': taskName,
        'stage': stage.name,
        'startedAtUtc': startedAtUtc.toUtc().toIso8601String(),
        'revision': revision,
        'deadlineUtc': deadlineUtc?.toUtc().toIso8601String(),
        'deadlineVersion': deadlineVersion,
        'recordIds': recordIds,
        'settledAtUtc': settledAtUtc?.toUtc().toIso8601String(),
        'firstDeliveredAtUtc': firstDeliveredAtUtc?.toUtc().toIso8601String(),
        'firstDeliveryChannel': firstDeliveryChannel,
        'secondDeliveredAtUtc': secondDeliveredAtUtc?.toUtc().toIso8601String(),
        'secondDeliveryChannel': secondDeliveryChannel,
        'responseWindowEndsAtUtc':
            responseWindowEndsAtUtc?.toUtc().toIso8601String(),
        'responseDeadlineVersion': responseDeadlineVersion,
        'completedAtUtc': completedAtUtc?.toUtc().toIso8601String(),
        'completionSource': completionSource,
        'completionError': completionError,
        'autoCompleteAttemptedAtUtc':
            autoCompleteAttemptedAtUtc?.toUtc().toIso8601String(),
        'scheduleChanged': scheduleChanged,
        'notice': notice,
        'deliveries': deliveries.map((d) => d.toJson()).toList(growable: false),
      };

  static ExecutionDeadlineSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final executionId = (j['executionId'] as String?)?.trim() ?? '';
    final conversationId = (j['conversationId'] as String?)?.trim() ?? '';
    final taskId = (j['taskId'] as String?)?.trim() ?? '';
    if (executionId.isEmpty || conversationId.isEmpty || taskId.isEmpty) {
      return null;
    }
    final stage = switch (j['stage']) {
      'scheduled' => ExecutionDeadlineStage.scheduled,
      'pending' => ExecutionDeadlineStage.pending,
      'secondReminder' => ExecutionDeadlineStage.secondReminder,
      'completed' => ExecutionDeadlineStage.completed,
      'cancelled' => ExecutionDeadlineStage.cancelled,
      // 未知阶段不能猜成“活跃”：按取消处理，宁可少提醒也不误完成。
      _ => ExecutionDeadlineStage.cancelled,
    };
    final rawRecords = j['recordIds'];
    final records = <String>[
      if (rawRecords is List)
        for (final item in rawRecords)
          if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    final deliveries = <ExecutionNotificationDelivery>[];
    final rawDeliveries = j['deliveries'];
    if (rawDeliveries is List) {
      for (final item in rawDeliveries) {
        final delivery = ExecutionNotificationDelivery.fromJson(item);
        if (delivery != null) deliveries.add(delivery);
      }
    }
    return ExecutionDeadlineSession(
      executionId: executionId,
      conversationId: conversationId,
      taskId: taskId,
      taskName: (j['taskName'] as String?)?.trim().isNotEmpty == true
          ? (j['taskName'] as String).trim()
          : taskId,
      stage: stage,
      startedAtUtc:
          parseUtc(j['startedAtUtc']) ?? DateTime.now().toUtc(),
      revision: (j['revision'] as num?)?.toInt() ?? 1,
      deadlineUtc: parseUtc(j['deadlineUtc']),
      deadlineVersion: (j['deadlineVersion'] as num?)?.toInt() ?? 1,
      recordIds: List<String>.unmodifiable(records),
      settledAtUtc: parseUtc(j['settledAtUtc']),
      firstDeliveredAtUtc: parseUtc(j['firstDeliveredAtUtc']),
      firstDeliveryChannel: j['firstDeliveryChannel'] as String?,
      secondDeliveredAtUtc: parseUtc(j['secondDeliveredAtUtc']),
      secondDeliveryChannel: j['secondDeliveryChannel'] as String?,
      responseWindowEndsAtUtc: parseUtc(j['responseWindowEndsAtUtc']),
      responseDeadlineVersion: (j['responseDeadlineVersion'] as num?)?.toInt(),
      completedAtUtc: parseUtc(j['completedAtUtc']),
      completionSource: j['completionSource'] as String?,
      completionError: j['completionError'] as String?,
      autoCompleteAttemptedAtUtc: parseUtc(j['autoCompleteAttemptedAtUtc']),
      scheduleChanged: j['scheduleChanged'] == true,
      notice: j['notice'] as String?,
      deliveries: List<ExecutionNotificationDelivery>.unmodifiable(deliveries),
    );
  }
}

/// 从甘特排程解析出的“任务有效截止”目标。
///
/// [endUtc] 为当前生效任务最后一个排程段的结束时刻；只有日期、尚无排程时为 null
/// （不猜午夜）。[plannedStartUtc] 仅用于“已开始”通知里的计划时段文案。
class ExecutionDeadlineTarget {
  const ExecutionDeadlineTarget({
    required this.taskName,
    required this.planVersionId,
    required this.planRevision,
    this.plannedStartUtc,
    this.plannedEndUtc,
    this.isDone = false,
    this.isPending = false,
    this.isBlocked = false,
  });

  final String taskName;
  final String planVersionId;
  final int planRevision;
  final DateTime? plannedStartUtc;
  final DateTime? plannedEndUtc;
  final bool isDone;
  final bool isPending;
  final bool isBlocked;

  DateTime? get effectiveDeadlineUtc => plannedEndUtc;
}

/// 延长截止前的预览：当前/新截止与潜在重叠。只读，不写任何数据。
class ExecutionExtensionPreview {
  const ExecutionExtensionPreview({
    required this.currentDeadlineUtc,
    required this.newDeadlineUtc,
    this.conflicts = const <String>[],
    this.otherTaskNames = const <String>[],
    this.error,
  });

  final DateTime? currentDeadlineUtc;
  final DateTime newDeadlineUtc;

  /// 新截止造成的冲突（与既有排程重叠等），展示给用户确认。
  final List<String> conflicts;

  /// 受影响的其它任务名（只提示，不自动搬动）。
  final List<String> otherTaskNames;

  /// 无法预览/无法延长时的原因（例如任务没有甘特片段）。
  final String? error;
}

/// 截止会话的一次操作结果。
class ExecutionDeadlineAction {
  const ExecutionDeadlineAction({
    required this.ok,
    required this.message,
    this.session,
    this.completed = false,
  });

  final bool ok;
  final String message;
  final ExecutionDeadlineSession? session;

  /// 是否已把任务标记为完成（用于 UI 决定刷新/撤销入口）。
  final bool completed;
}

/// 本地 HH:mm 显示（通知正文里的“请在 16:10 前选择”）。
String formatWallClockLabel(DateTime localWall) {
  final h = localWall.hour.toString().padLeft(2, '0');
  final m = localWall.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
