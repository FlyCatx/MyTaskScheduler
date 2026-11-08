// 执行记录账本的数据模型。
//
// 设计口径与不变量（改动前请先读）：
//
//   * **实际耗时只来自两类事实**：计时区间 [ExecutionInterval] 与手工补记
//     [ManualEntry]。任务的 `estimatedHours` 与 `Completion` 都不在这里被改写——
//     停止计时≠完成任务，完成任务也不会把预估抄成实际。
//   * **未知 ≠ 0**：记录从未产生过任何事实（[ExecutionRecord.hasRecordedFacts]
//     为 false）时，统计显示“未知”；存在事实但确认时长为 0 时显示“已记录 0 分钟”。
//   * **单调时钟算时长，UTC 持久化**：计时区间保存绝对 UTC 起止；进程内经过时长
//     由注入的 EffortClock 单调读数决定，系统时间回拨/跳变不会产生负值或巨额。
//   * **待校正区间默认不计入**：[PendingCorrection] 在用户明确处理（折扣 / 全额 /
//     自定义）前不进入已确认时长；崩溃恢复后 [checkpoint, 重启] 的时间永远先进
//     待校正，不会自动算成工作。
//   * **recordId 稳定且全局唯一**：恢复备份按 recordId 去重，重复恢复不重复累计；
//     任务改名/拆分/合并/删除都不改写已有记录，只让归属（taskId/lineageRootId）
//     保持不变，报告把找不到当前任务的记录列为“未归属”。
//   * **修订历史**：记录的软删除、手工补记的增删都会留下 [ExecutionRevision] 快照，
//     支持撤销；超过 [kMaxRecordRevisions] 条时丢最旧的。
//
// JSON 一律使用 camelCase 键；读取旧/缺字段数据时给明确默认值，绝不编造事实。

import '../../model/plan.dart' show IdGenerator;

/// 账本文件结构版本。读到更大的版本时上层必须只读，不能用旧结构覆盖。
const int kExecutionLedgerSchemaVersion = 1;

/// 单个记录保留的修订快照上限（防止账本无限增长）。
const int kMaxRecordRevisions = 20;

/// 单条待校正区间“全额计入”时的上限。睡眠/锁屏后的墙钟跨度可能非常长，
/// 用户选择“全部计入”也只按一个工作日的上限截断，避免把巨额时间写成实际工时。
const int kMaxPendingCorrectionSeconds = 12 * 60 * 60;

/// 计时阶段。`idle` 表示没有活动计时任务。
enum TimerPhase {
  idle,
  running,
  paused,
}

/// 一条执行记录的确认状态。
enum ExecutionRecordState {
  /// 所有时间段都已确认。
  confirmed,

  /// 存在尚未由用户处理的待校正区间；统计里单独列出，不混入已确认时长。
  pendingCorrection,
}

/// 有效区间来源。
enum IntervalSource {
  /// 计时器在单调时钟下测得的区间。
  timer,

  /// 由用户校正待校正区间后，确认为“这段时间确实在工作”的区间。
  correction,
}

/// 手工补记的模式。
enum ManualEntryMode {
  /// 已知起止时间；可以检测与已有记录的重叠。
  startEnd,

  /// 只知道时长（例如“昨天写报告约 40 分钟”）；无法检测重叠，按锚定日期整天归属。
  duration,
}

/// 与已有记录重叠时用户选择的计入口径。
enum OverlapPolicy {
  /// 默认：重叠部分保留在记录里以便追溯，但**不计入**统计。
  excludeOverlap,

  /// 用户明确保留：重叠部分计入统计，报告必须标注该口径。
  includeOverlap,
}

/// 待校正区间的检测原因。
enum CorrectionReason {
  /// 墙钟与单调时钟不一致（系统时间回拨 / 跳变）。
  clockJump,

  /// 睡眠 / 锁屏等离开场景（默认暂停 + 待校正，不伪造精确值）。
  suspend,

  /// 崩溃恢复：最后检查点到重启之间无法确定是否在工作。
  crashRecovery,

  /// 其他需要用户确认的情况。
  manual,
}

/// 用户对待校正区间的处理方式。
enum CorrectionDecision {
  /// 折扣为 0：这段时间不算工作。
  discount,

  /// 全额计入（按墙钟跨度，且不超过 [kMaxPendingCorrectionSeconds]）。
  countFull,

  /// 用户自定义秒数（0 到 [kMaxPendingCorrectionSeconds]）。
  custom,
}

/// 一个绝对的 UTC 时间区间。用于重叠检测与手工补记的重叠追溯。
class TimeSpan {
  const TimeSpan({required this.startUtc, required this.endUtc});

  final DateTime startUtc;
  final DateTime endUtc;

  bool get isValid => endUtc.isAfter(startUtc);

  Duration get duration =>
      isValid ? endUtc.difference(startUtc) : Duration.zero;

  TimeSpan copyWith({DateTime? startUtc, DateTime? endUtc}) =>
      TimeSpan(startUtc: startUtc ?? this.startUtc, endUtc: endUtc ?? this.endUtc);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startUtc': startUtc.toUtc().toIso8601String(),
        'endUtc': endUtc.toUtc().toIso8601String(),
      };

  /// 缺字段/时序不合法时返回 null（不猜）。
  static TimeSpan? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final start = parseUtc(j['startUtc']);
    final end = parseUtc(j['endUtc']);
    if (start == null || end == null) return null;
    return TimeSpan(startUtc: start, endUtc: end);
  }
}

/// 一段已确认的计时区间。
///
/// 不变量：[startUtc] 与 [endUtc] 的差值等于“用单调时钟测到的时长”（由计时器保证），
/// 因此即使墙钟在区间内被修改，区间长度仍然是非负的合理值。
class ExecutionInterval {
  const ExecutionInterval({
    required this.startUtc,
    required this.endUtc,
    this.source = IntervalSource.timer,
    this.note,
  });

  final DateTime startUtc;
  final DateTime endUtc;
  final IntervalSource source;
  final String? note;

  bool get isValid => endUtc.isAfter(startUtc);

  Duration get duration =>
      isValid ? endUtc.difference(startUtc) : Duration.zero;

  ExecutionInterval copyWith({
    DateTime? startUtc,
    DateTime? endUtc,
    IntervalSource? source,
    String? note,
  }) =>
      ExecutionInterval(
        startUtc: startUtc ?? this.startUtc,
        endUtc: endUtc ?? this.endUtc,
        source: source ?? this.source,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startUtc': startUtc.toUtc().toIso8601String(),
        'endUtc': endUtc.toUtc().toIso8601String(),
        'source': source.name,
        'note': note,
      };

  static ExecutionInterval? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final start = parseUtc(j['startUtc']);
    final end = parseUtc(j['endUtc']);
    if (start == null || end == null) return null;
    final source = switch (j['source']) {
      'correction' => IntervalSource.correction,
      _ => IntervalSource.timer,
    };
    return ExecutionInterval(
      startUtc: start,
      endUtc: end,
      source: source,
      note: j['note'] as String?,
    );
  }
}

/// 一条手工补记。
///
/// [durationSeconds] 是用户输入/起止推导出的原始时长（非负）；[countedSeconds]
/// 扣除默认排除的重叠部分后才是统计口径。重叠区间 [overlapSpans] 在创建时快照，
/// 之后不会因为别的记录被删改而漂移。
class ManualEntry {
  const ManualEntry({
    required this.entryId,
    required this.mode,
    required this.durationSeconds,
    required this.localDate,
    required this.createdAtUtc,
    this.startUtc,
    this.endUtc,
    this.note,
    this.overlapSpans = const <TimeSpan>[],
    this.overlapPolicy = OverlapPolicy.excludeOverlap,
  });

  final String entryId;
  final ManualEntryMode mode;

  /// 起止模式下的开始时间；仅时长模式为 null。
  final DateTime? startUtc;

  /// 起止模式下的结束时间；仅时长模式为 null。
  final DateTime? endUtc;

  /// 原始时长（秒，非负）。
  final int durationSeconds;

  /// 归属的本地日期（`yyyy-MM-dd`）。仅时长模式按这一天整天归属；
  /// 起止模式也保存开始时刻所在本地日期，便于报告展开。
  final String localDate;

  final String? note;
  final DateTime createdAtUtc;

  /// 创建时与已有记录重叠的区间快照（仅起止模式能检测）。
  final List<TimeSpan> overlapSpans;

  /// 重叠部分是否计入。默认 [OverlapPolicy.excludeOverlap]。
  final OverlapPolicy overlapPolicy;

  /// 重叠总秒数（快照）。
  int get overlapSeconds {
    var total = 0;
    for (final span in overlapSpans) {
      total += span.duration.inSeconds;
    }
    return total;
  }

  /// 按口径计入统计的秒数。
  int get countedSeconds {
    if (overlapPolicy == OverlapPolicy.includeOverlap) {
      return durationSeconds;
    }
    final excluded = overlapSeconds;
    if (excluded <= 0) return durationSeconds;
    return durationSeconds > excluded ? durationSeconds - excluded : 0;
  }

  bool get hasOverlap => overlapSpans.isNotEmpty;

  bool get overlapIncluded => hasOverlap &&
      overlapPolicy == OverlapPolicy.includeOverlap;

  ManualEntry copyWith({
    String? note,
    List<TimeSpan>? overlapSpans,
    OverlapPolicy? overlapPolicy,
  }) =>
      ManualEntry(
        entryId: entryId,
        mode: mode,
        startUtc: startUtc,
        endUtc: endUtc,
        durationSeconds: durationSeconds,
        localDate: localDate,
        createdAtUtc: createdAtUtc,
        note: note ?? this.note,
        overlapSpans: overlapSpans ?? this.overlapSpans,
        overlapPolicy: overlapPolicy ?? this.overlapPolicy,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'entryId': entryId,
        'mode': mode.name,
        'startUtc': startUtc?.toUtc().toIso8601String(),
        'endUtc': endUtc?.toUtc().toIso8601String(),
        'durationSeconds': durationSeconds,
        'localDate': localDate,
        'note': note,
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'overlapSpans': overlapSpans.map((s) => s.toJson()).toList(growable: false),
        'overlapPolicy': overlapPolicy.name,
      };

  static ManualEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final entryId = (j['entryId'] as String?)?.trim() ?? '';
    if (entryId.isEmpty) return null;
    final duration = (j['durationSeconds'] as num?)?.toInt() ?? 0;
    final spans = <TimeSpan>[];
    final rawSpans = j['overlapSpans'];
    if (rawSpans is List) {
      for (final item in rawSpans) {
        final span = TimeSpan.fromJson(item);
        if (span != null) spans.add(span);
      }
    }
    return ManualEntry(
      entryId: entryId,
      mode: j['mode'] == 'duration' ? ManualEntryMode.duration : ManualEntryMode.startEnd,
      startUtc: parseUtc(j['startUtc']),
      endUtc: parseUtc(j['endUtc']),
      durationSeconds: duration < 0 ? 0 : duration,
      localDate: (j['localDate'] as String?)?.trim() ?? '',
      createdAtUtc: parseUtc(j['createdAtUtc']) ?? DateTime.now().toUtc(),
      note: j['note'] as String?,
      overlapSpans: spans,
      overlapPolicy: j['overlapPolicy'] == 'includeOverlap'
          ? OverlapPolicy.includeOverlap
          : OverlapPolicy.excludeOverlap,
    );
  }
}

/// 一段“不确定是否在工作”的时间区间，必须由用户校正后才进入统计。
class PendingCorrection {
  const PendingCorrection({
    required this.correctionId,
    required this.observedStartUtc,
    required this.observedEndUtc,
    required this.wallDeltaSeconds,
    required this.monotonicDeltaSeconds,
    required this.reason,
    required this.detectedAtUtc,
    this.decision,
    this.decidedSeconds,
    this.decidedAtUtc,
  });

  final String correctionId;

  /// 墙钟观察到的起止。系统时间回拨时 [observedStartUtc] 可能晚于 [observedEndUtc]，
  /// 此时 [wallDeltaSeconds] 为负，仅用于展示“时间被改动过”，不参与统计。
  final DateTime observedStartUtc;
  final DateTime observedEndUtc;

  /// 墙钟跨度（秒，可为负）。
  final int wallDeltaSeconds;

  /// 单调时钟跨度（秒，可为负；跨进程恢复时不可知，记为 0）。
  final int monotonicDeltaSeconds;

  final CorrectionReason reason;
  final DateTime detectedAtUtc;

  /// null = 尚未处理（不计入任何统计）。
  final CorrectionDecision? decision;

  /// 用户确认计入的秒数；[CorrectionDecision.discount] 为 0。
  final int? decidedSeconds;

  final DateTime? decidedAtUtc;

  bool get isOpen => decision == null;

  /// 展示用的“疑似离开时长”：只有墙钟正跨度才有意义。
  Duration get observedDuration => wallDeltaSeconds > 0
      ? Duration(seconds: wallDeltaSeconds)
      : Duration.zero;

  /// 已确认计入的时长。
  Duration get decidedDuration =>
      decidedSeconds == null || decidedSeconds! <= 0
          ? Duration.zero
          : Duration(seconds: decidedSeconds!);

  PendingCorrection resolved({
    required CorrectionDecision decision,
    required int seconds,
    required DateTime atUtc,
  }) {
    final bounded = seconds < 0
        ? 0
        : (seconds > kMaxPendingCorrectionSeconds
            ? kMaxPendingCorrectionSeconds
            : seconds);
    return PendingCorrection(
      correctionId: correctionId,
      observedStartUtc: observedStartUtc,
      observedEndUtc: observedEndUtc,
      wallDeltaSeconds: wallDeltaSeconds,
      monotonicDeltaSeconds: monotonicDeltaSeconds,
      reason: reason,
      detectedAtUtc: detectedAtUtc,
      decision: decision,
      decidedSeconds: bounded,
      decidedAtUtc: atUtc,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'correctionId': correctionId,
        'observedStartUtc': observedStartUtc.toUtc().toIso8601String(),
        'observedEndUtc': observedEndUtc.toUtc().toIso8601String(),
        'wallDeltaSeconds': wallDeltaSeconds,
        'monotonicDeltaSeconds': monotonicDeltaSeconds,
        'reason': reason.name,
        'detectedAtUtc': detectedAtUtc.toUtc().toIso8601String(),
        'decision': decision?.name,
        'decidedSeconds': decidedSeconds,
        'decidedAtUtc': decidedAtUtc?.toUtc().toIso8601String(),
      };

  static PendingCorrection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final id = (j['correctionId'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final decision = switch (j['decision']) {
      'discount' => CorrectionDecision.discount,
      'countFull' => CorrectionDecision.countFull,
      'custom' => CorrectionDecision.custom,
      _ => null,
    };
    final reason = switch (j['reason']) {
      'suspend' => CorrectionReason.suspend,
      'crashRecovery' => CorrectionReason.crashRecovery,
      'manual' => CorrectionReason.manual,
      _ => CorrectionReason.clockJump,
    };
    return PendingCorrection(
      correctionId: id,
      observedStartUtc: parseUtc(j['observedStartUtc']) ?? DateTime.now().toUtc(),
      observedEndUtc: parseUtc(j['observedEndUtc']) ?? DateTime.now().toUtc(),
      wallDeltaSeconds: (j['wallDeltaSeconds'] as num?)?.toInt() ?? 0,
      monotonicDeltaSeconds: (j['monotonicDeltaSeconds'] as num?)?.toInt() ?? 0,
      reason: reason,
      detectedAtUtc: parseUtc(j['detectedAtUtc']) ?? DateTime.now().toUtc(),
      decision: decision,
      decidedSeconds: (j['decidedSeconds'] as num?)?.toInt(),
      decidedAtUtc: parseUtc(j['decidedAtUtc']),
    );
  }
}

/// 一条修订历史：记录改动前的完整快照，支持撤销与追溯。
class ExecutionRevision {
  const ExecutionRevision({
    required this.revisionId,
    required this.atUtc,
    required this.action,
    this.note,
    this.snapshot,
  });

  final String revisionId;
  final DateTime atUtc;

  /// `manualAdd` / `manualRemove` / `delete` / `restore` / `revise` 等动作名。
  final String action;
  final String? note;

  /// 改动前的记录快照；无快照的修订只用于追溯。
  final Map<String, dynamic>? snapshot;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'revisionId': revisionId,
        'atUtc': atUtc.toUtc().toIso8601String(),
        'action': action,
        'note': note,
        'snapshot': snapshot,
      };

  static ExecutionRevision? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final id = (j['revisionId'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    return ExecutionRevision(
      revisionId: id,
      atUtc: parseUtc(j['atUtc']) ?? DateTime.now().toUtc(),
      action: (j['action'] as String?) ?? 'revise',
      note: j['note'] as String?,
      snapshot: j['snapshot'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(j['snapshot'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// 一条执行记录：同一个任务的执行事实账本。
///
/// 每个任务（在同一会话内）可以有多条记录（每次“开始→停止”一条）；记录之间由
/// 稳定的 recordId 区分，跨计划版本通过 taskId / lineageRootId 归属。
class ExecutionRecord {
  const ExecutionRecord({
    required this.recordId,
    required this.conversationId,
    required this.taskId,
    required this.taskName,
    required this.planVersionId,
    required this.planRevision,
    required this.createdAtUtc,
    required this.timeZoneName,
    required this.timeZoneOffsetMinutes,
    this.lineageRootId = '',
    this.estimateBaselineHours,
    this.state = ExecutionRecordState.confirmed,
    this.intervals = const <ExecutionInterval>[],
    this.manualEntries = const <ManualEntry>[],
    this.pendingCorrections = const <PendingCorrection>[],
    this.revisions = const <ExecutionRevision>[],
    this.deletedAtUtc,
    this.deletedReason,
  });

  /// 新建一条计时记录时的工厂：捕获开始执行那一刻的估计与计划版本。
  factory ExecutionRecord.start({
    required String recordId,
    required String conversationId,
    required String taskId,
    required String taskName,
    required String planVersionId,
    required int planRevision,
    required DateTime startedAtUtc,
    required String timeZoneName,
    required int timeZoneOffsetMinutes,
    double? estimateBaselineHours,
    String? lineageRootId,
  }) =>
      ExecutionRecord(
        recordId: recordId,
        conversationId: conversationId,
        taskId: taskId,
        taskName: taskName,
        lineageRootId: (lineageRootId ?? taskId).trim().isEmpty
            ? taskId
            : (lineageRootId ?? taskId),
        planVersionId: planVersionId,
        planRevision: planRevision,
        estimateBaselineHours: estimateBaselineHours,
        createdAtUtc: startedAtUtc,
        timeZoneName: timeZoneName,
        timeZoneOffsetMinutes: timeZoneOffsetMinutes,
      );

  /// 稳定本地 id（不是任务标题、不是列表位置，也不随版本改变）。
  final String recordId;

  final String conversationId;
  final String taskId;

  /// 记录创建时的任务名快照。任务改名后报告仍能说明“这条记录当时叫什么”。
  final String taskName;

  /// 任务谱系根 id：拆分/合并后仍能找回同一条执行事实。默认等于 [taskId]。
  final String lineageRootId;

  /// 开始执行时的计划版本与本地修订号（基线所属版本）。
  final String planVersionId;
  final int planRevision;

  /// 开始执行时的有效预估（小时）。null = 当时没有有效估计，统计显示未知。
  final double? estimateBaselineHours;

  final DateTime createdAtUtc;

  /// 创建时区信息（仅用于显示与按本地日期分摊，总时长始终按绝对时间计算）。
  final String timeZoneName;
  final int timeZoneOffsetMinutes;

  final ExecutionRecordState state;
  final List<ExecutionInterval> intervals;
  final List<ManualEntry> manualEntries;
  final List<PendingCorrection> pendingCorrections;

  /// 含快照的修订历史（最多 [kMaxRecordRevisions] 条）。
  final List<ExecutionRevision> revisions;

  /// 软删除时间。删除记录不删除事实文件，历史报告仍可追溯；统计默认排除。
  final DateTime? deletedAtUtc;
  final String? deletedReason;

  bool get isDeleted => deletedAtUtc != null;

  bool get hasOpenCorrections =>
      pendingCorrections.any((c) => c.isOpen);

  int get openCorrectionCount =>
      pendingCorrections.where((c) => c.isOpen).length;

  /// 是否产生过任何执行事实。
  ///
  /// false 表示“从未记录”（统计必须显示未知，不能当 0）；true 且确认时长 0 表示
  /// “已记录 0 分钟”。计时区间为 0 长度不算事实（计时器不会写入空区间）。
  bool get hasRecordedFacts =>
      intervals.any((i) => i.isValid) ||
      manualEntries.isNotEmpty ||
      pendingCorrections.any((c) => c.decidedSeconds != null);

  /// 全部修订动作名（调试/测试用）。
  List<String> get revisionActions =>
      revisions.map((r) => r.action).toList(growable: false);

  ExecutionRecord copyWith({
    String? taskName,
    String? lineageRootId,
    String? planVersionId,
    int? planRevision,
    double? estimateBaselineHours,
    bool clearEstimateBaselineHours = false,
    ExecutionRecordState? state,
    List<ExecutionInterval>? intervals,
    List<ManualEntry>? manualEntries,
    List<PendingCorrection>? pendingCorrections,
    List<ExecutionRevision>? revisions,
    DateTime? deletedAtUtc,
    String? deletedReason,
    bool clearDeleted = false,
  }) =>
      ExecutionRecord(
        recordId: recordId,
        conversationId: conversationId,
        taskId: taskId,
        taskName: taskName ?? this.taskName,
        lineageRootId: lineageRootId ?? this.lineageRootId,
        planVersionId: planVersionId ?? this.planVersionId,
        planRevision: planRevision ?? this.planRevision,
        estimateBaselineHours: clearEstimateBaselineHours
            ? null
            : (estimateBaselineHours ?? this.estimateBaselineHours),
        createdAtUtc: createdAtUtc,
        timeZoneName: timeZoneName,
        timeZoneOffsetMinutes: timeZoneOffsetMinutes,
        state: state ?? this.state,
        intervals: intervals ?? this.intervals,
        manualEntries: manualEntries ?? this.manualEntries,
        pendingCorrections: pendingCorrections ?? this.pendingCorrections,
        revisions: revisions ?? this.revisions,
        deletedAtUtc: clearDeleted ? null : (deletedAtUtc ?? this.deletedAtUtc),
        deletedReason: clearDeleted ? null : (deletedReason ?? this.deletedReason),
      );

  /// 追加一条修订快照；超过上限时丢最旧的。
  ExecutionRecord withRevision(ExecutionRevision revision) {
    final next = <ExecutionRevision>[...revisions, revision];
    if (next.length > kMaxRecordRevisions) {
      next.removeRange(0, next.length - kMaxRecordRevisions);
    }
    return copyWith(revisions: next);
  }

  /// 最近一条带快照的修订（撤销用）。
  ExecutionRevision? get lastRevertibleRevision {
    for (var i = revisions.length - 1; i >= 0; i--) {
      if (revisions[i].snapshot != null) return revisions[i];
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordId': recordId,
        'conversationId': conversationId,
        'taskId': taskId,
        'taskName': taskName,
        'lineageRootId': lineageRootId,
        'planVersionId': planVersionId,
        'planRevision': planRevision,
        'estimateBaselineHours': estimateBaselineHours,
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'timeZoneName': timeZoneName,
        'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
        'state': state.name,
        'intervals': intervals.map((i) => i.toJson()).toList(growable: false),
        'manualEntries':
            manualEntries.map((m) => m.toJson()).toList(growable: false),
        'pendingCorrections': pendingCorrections
            .map((c) => c.toJson())
            .toList(growable: false),
        'revisions': revisions.map((r) => r.toJson()).toList(growable: false),
        'deletedAtUtc': deletedAtUtc?.toUtc().toIso8601String(),
        'deletedReason': deletedReason,
      };

  static ExecutionRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final recordId = (j['recordId'] as String?)?.trim() ?? '';
    final taskId = (j['taskId'] as String?)?.trim() ?? '';
    if (recordId.isEmpty || taskId.isEmpty) return null;

    final intervals = <ExecutionInterval>[];
    final rawIntervals = j['intervals'];
    if (rawIntervals is List) {
      for (final item in rawIntervals) {
        final interval = ExecutionInterval.fromJson(item);
        if (interval != null) intervals.add(interval);
      }
    }
    final manualEntries = <ManualEntry>[];
    final rawManual = j['manualEntries'];
    if (rawManual is List) {
      for (final item in rawManual) {
        final entry = ManualEntry.fromJson(item);
        if (entry != null) manualEntries.add(entry);
      }
    }
    final corrections = <PendingCorrection>[];
    final rawCorrections = j['pendingCorrections'];
    if (rawCorrections is List) {
      for (final item in rawCorrections) {
        final correction = PendingCorrection.fromJson(item);
        if (correction != null) corrections.add(correction);
      }
    }
    final revisions = <ExecutionRevision>[];
    final rawRevisions = j['revisions'];
    if (rawRevisions is List) {
      for (final item in rawRevisions) {
        final revision = ExecutionRevision.fromJson(item);
        if (revision != null) revisions.add(revision);
      }
    }
    final state = switch (j['state']) {
      'pendingCorrection' => ExecutionRecordState.pendingCorrection,
      'confirmed' => ExecutionRecordState.confirmed,
      // 旧数据没有 state 字段：按“是否有未处理校正”推导，绝不凭空升级状态。
      _ => corrections.any((c) => c.isOpen)
          ? ExecutionRecordState.pendingCorrection
          : ExecutionRecordState.confirmed,
    };
    return ExecutionRecord(
      recordId: recordId,
      conversationId: (j['conversationId'] as String?) ?? '',
      taskId: taskId,
      taskName: (j['taskName'] as String?) ?? taskId,
      lineageRootId: (j['lineageRootId'] as String?)?.trim().isNotEmpty == true
          ? (j['lineageRootId'] as String).trim()
          : taskId,
      planVersionId: (j['planVersionId'] as String?) ?? '',
      planRevision: (j['planRevision'] as num?)?.toInt() ?? 0,
      estimateBaselineHours: (j['estimateBaselineHours'] as num?)?.toDouble(),
      createdAtUtc: parseUtc(j['createdAtUtc']) ?? DateTime.now().toUtc(),
      timeZoneName: (j['timeZoneName'] as String?) ?? '',
      timeZoneOffsetMinutes: (j['timeZoneOffsetMinutes'] as num?)?.toInt() ?? 0,
      state: state,
      intervals: intervals,
      manualEntries: manualEntries,
      pendingCorrections: corrections,
      revisions: revisions,
      deletedAtUtc: parseUtc(j['deletedAtUtc']),
      deletedReason: j['deletedReason'] as String?,
    );
  }
}

/// 任务完成事件。完成时间来自该事件的时间，而不是“当前读取时间”。
class CompletionEvent {
  const CompletionEvent({
    required this.eventId,
    required this.conversationId,
    required this.taskId,
    required this.planVersionId,
    required this.planRevision,
    required this.completedAtUtc,
    this.undoneAtUtc,
  });

  final String eventId;
  final String conversationId;
  final String taskId;
  final String planVersionId;
  final int planRevision;
  final DateTime completedAtUtc;

  /// 撤销完成的时间；null 表示仍然完成。撤销不删除任何执行记录。
  final DateTime? undoneAtUtc;

  bool get isActive => undoneAtUtc == null;

  CompletionEvent undo(DateTime atUtc) => CompletionEvent(
        eventId: eventId,
        conversationId: conversationId,
        taskId: taskId,
        planVersionId: planVersionId,
        planRevision: planRevision,
        completedAtUtc: completedAtUtc,
        undoneAtUtc: atUtc,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'eventId': eventId,
        'conversationId': conversationId,
        'taskId': taskId,
        'planVersionId': planVersionId,
        'planRevision': planRevision,
        'completedAtUtc': completedAtUtc.toUtc().toIso8601String(),
        'undoneAtUtc': undoneAtUtc?.toUtc().toIso8601String(),
      };

  static CompletionEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final eventId = (j['eventId'] as String?)?.trim() ?? '';
    final taskId = (j['taskId'] as String?)?.trim() ?? '';
    if (eventId.isEmpty || taskId.isEmpty) return null;
    return CompletionEvent(
      eventId: eventId,
      conversationId: (j['conversationId'] as String?) ?? '',
      taskId: taskId,
      planVersionId: (j['planVersionId'] as String?) ?? '',
      planRevision: (j['planRevision'] as num?)?.toInt() ?? 0,
      completedAtUtc: parseUtc(j['completedAtUtc']) ?? DateTime.now().toUtc(),
      undoneAtUtc: parseUtc(j['undoneAtUtc']),
    );
  }
}

/// 计时器落盘的检查点。
///
/// 它是“有界间隔 + 关键点”持久化的核心：[checkpointUtc] 之前的时间已写进账本；
/// 之后到进程重启之间的时间只能进待校正区间，不会被默认算成工作。最大可丢失
/// 已确认时长 = 检查点间隔（见 TimerController 的 checkpointInterval），默认 15 秒。
class TimerCheckpoint {
  const TimerCheckpoint({
    required this.recordId,
    required this.conversationId,
    required this.taskId,
    required this.taskName,
    required this.planVersionId,
    required this.planRevision,
    required this.phase,
    required this.sessionStartedAtUtc,
    required this.checkpointUtc,
    required this.timeZoneName,
    required this.timeZoneOffsetMinutes,
    this.estimateBaselineHours,
    this.openIntervalStartUtc,
  });

  final String recordId;
  final String conversationId;
  final String taskId;
  final String taskName;
  final String planVersionId;
  final int planRevision;
  final double? estimateBaselineHours;
  final TimerPhase phase;

  /// 本次计时会话的开始时间（用于“此次已记录时间”的恢复）。
  final DateTime sessionStartedAtUtc;

  /// 检查点写入时刻；此前的时间已经进入账本。
  final DateTime checkpointUtc;

  /// running 时当前未闭合区间的开始时间；paused/idle 为 null。
  final DateTime? openIntervalStartUtc;

  final String timeZoneName;
  final int timeZoneOffsetMinutes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordId': recordId,
        'conversationId': conversationId,
        'taskId': taskId,
        'taskName': taskName,
        'planVersionId': planVersionId,
        'planRevision': planRevision,
        'estimateBaselineHours': estimateBaselineHours,
        'phase': phase.name,
        'sessionStartedAtUtc': sessionStartedAtUtc.toUtc().toIso8601String(),
        'checkpointUtc': checkpointUtc.toUtc().toIso8601String(),
        'openIntervalStartUtc': openIntervalStartUtc?.toUtc().toIso8601String(),
        'timeZoneName': timeZoneName,
        'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
      };

  static TimerCheckpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final recordId = (j['recordId'] as String?)?.trim() ?? '';
    if (recordId.isEmpty) return null;
    final phase = switch (j['phase']) {
      'running' => TimerPhase.running,
      'paused' => TimerPhase.paused,
      _ => TimerPhase.idle,
    };
    if (phase == TimerPhase.idle) return null;
    return TimerCheckpoint(
      recordId: recordId,
      conversationId: (j['conversationId'] as String?) ?? '',
      taskId: (j['taskId'] as String?) ?? '',
      taskName: (j['taskName'] as String?) ?? '',
      planVersionId: (j['planVersionId'] as String?) ?? '',
      planRevision: (j['planRevision'] as num?)?.toInt() ?? 0,
      estimateBaselineHours: (j['estimateBaselineHours'] as num?)?.toDouble(),
      phase: phase,
      sessionStartedAtUtc:
          parseUtc(j['sessionStartedAtUtc']) ?? parseUtc(j['checkpointUtc']) ?? DateTime.now().toUtc(),
      checkpointUtc: parseUtc(j['checkpointUtc']) ?? DateTime.now().toUtc(),
      openIntervalStartUtc: parseUtc(j['openIntervalStartUtc']),
      timeZoneName: (j['timeZoneName'] as String?) ?? '',
      timeZoneOffsetMinutes: (j['timeZoneOffsetMinutes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 开始计时/补记时描述目标任务的快照（由接线方从当前计划版本构造）。
class ExecutionTaskRef {
  const ExecutionTaskRef({
    required this.conversationId,
    required this.taskId,
    required this.taskName,
    required this.planVersionId,
    required this.planRevision,
    this.estimateHours,
    this.lineageRootId,
  });

  final String conversationId;
  final String taskId;
  final String taskName;
  final String planVersionId;
  final int planRevision;

  /// 当前计划里的有效预估（小时）；null/<=0 = 未知。
  final double? estimateHours;

  /// 任务谱系根 id；null 时默认等于 taskId。
  final String? lineageRootId;

  double? get effectiveEstimateHours =>
      estimateHours != null && estimateHours! > 0 ? estimateHours : null;
}

/// 手工补记草稿（UI → 控制器）。
class ManualEntryDraft {
  const ManualEntryDraft({
    required this.mode,
    this.startUtc,
    this.endUtc,
    this.duration,
    this.localDate,
    this.note,
    this.overlapPolicy = OverlapPolicy.excludeOverlap,
  });

  final ManualEntryMode mode;

  /// 起止模式必填（UTC）。
  final DateTime? startUtc;
  final DateTime? endUtc;

  /// 仅时长模式的时长（秒级精度）。
  final Duration? duration;

  /// 仅时长模式的归属本地日期（`yyyy-MM-dd`）；null = 今天。
  final String? localDate;
  final String? note;
  final OverlapPolicy overlapPolicy;
}

/// 解析 UTC ISO 字符串；非法/缺失返回 null（不猜时间）。
DateTime? parseUtc(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim())?.toUtc();
}

/// 生成本地唯一 id（沿用工程里的稳定 id 生成器）。
String newExecutionId(String prefix) => IdGenerator.next(prefix);
