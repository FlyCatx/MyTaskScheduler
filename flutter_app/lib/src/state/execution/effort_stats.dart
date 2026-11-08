// 根据执行事实计算实际耗时与估计偏差。
//
// 统计口径（所有函数共享，禁止在别处另写一套）：
//   * **实际耗时** = 计时区间 + 手工补记（默认扣除重叠部分）+ 用户已确认的校正时长。
//     任务完成状态、计划排程、外部日历事件都不算实际工时。
//   * **未知 ≠ 0**：任务从未有任何执行事实时，实际耗时是“未知”；存在事实但时长为 0
//     时显示“已记录 0 分钟”。没有任何执行事实的已完成任务不生成 0% 精准率。
//   * **偏差 = 实际耗时 − 基线估计**。基线固定为“开始执行时的有效估计”并记录版本，
//     同一 taskId 跨版本只取最早一条记录作为基线；百分比只在基线与实际都已知且
//     基线 > 0 时显示。
//   * **剩余是建议**：`max(基线 − 实际, 0)`，不自动完成任务，也不自动移动排程。
//   * **跨版本同一 taskId 只累计一次**：记录按 recordId 去重；同一 taskId 的记录全部
//     属于同一个任务，但绝不会把同一条记录重复计入。
//   * **按日切片总和守恒**：一个区间跨午夜/夏令时（DST）时按绝对时间切分，日边界
//     用本地时区换算，切片之和恒等于区间总时长；总时长从不假设一天 24 小时。
//
// 本地时区通过 [EffortLocalTime] 注入：生产用 [SystemEffortLocalTime]，测试可注入
// 固定偏移或带 DST 规则的实现。`toLocal` 的契约：返回 `isUtc == true` 的
// “本地墙钟值”（字段即本地年月日时分），这样日期切片与真实时区解耦。

import 'dart:math' as math;

import '../../model/plan.dart' show Completion;
import 'execution_models.dart';

/// 未知值的统一展示文案（导出/界面共用，避免出现 0 冒充未知）。
const String kEffortUnknownLabel = '未知';

/// 默认统计口径说明。报告与 CSV 必须带上它，用户才知道数字怎么来的。
const String kDefaultEffortCaliberNote =
    '实际耗时=计时区间+手工补记（默认不计重叠部分）+已确认校正；'
    '偏差=实际−开始执行时的估算基线（基线>0 才显示百分比）；'
    '剩余为建议值，不自动完成任务；完成但无记录显示未知，不等于 0。';

/// 本地时区抽象。实现见 [SystemEffortLocalTime] / [FixedOffsetEffortLocalTime]。
abstract class EffortLocalTime {
  /// 把 UTC 时刻映射为“本地墙钟值”（返回对象 `isUtc == true`，字段即本地时间）。
  DateTime toLocal(DateTime utc);

  /// 把“本地墙钟值”解释回 UTC 时刻（用于按本地日边界切片）。
  DateTime localToUtc(DateTime localWall);

  /// 人类可读时区名，例如 `中国标准时间 (UTC+08:00)`。
  String get timeZoneLabel;

  /// 某 UTC 时刻的本地偏移（分钟），用于记录创建时的时区快照。
  int offsetMinutesAt(DateTime utc);
}

/// 生产环境：跟随操作系统时区与 DST 规则。
class SystemEffortLocalTime implements EffortLocalTime {
  const SystemEffortLocalTime();

  @override
  DateTime toLocal(DateTime utc) {
    final l = utc.toUtc().toLocal();
    return DateTime.utc(l.year, l.month, l.day, l.hour, l.minute, l.second,
        l.millisecond, l.microsecond);
  }

  @override
  DateTime localToUtc(DateTime localWall) {
    // 解释为系统本地时区；DST 不存在的墙钟时间由平台向前归一化，重复时间取较早
    // 的偏移。日切片只用本地午夜，实际时区里极少落在跳变点上；即使落在跳变点，
    // 相邻日边界仍然首尾相接，总和守恒。
    final local = DateTime(localWall.year, localWall.month, localWall.day,
        localWall.hour, localWall.minute, localWall.second,
        localWall.millisecond, localWall.microsecond);
    return local.toUtc();
  }

  @override
  String get timeZoneLabel {
    final now = DateTime.now();
    return '${now.timeZoneName} (UTC${_formatOffset(now.timeZoneOffset)})';
  }

  @override
  int offsetMinutesAt(DateTime utc) => utc.toUtc().toLocal().timeZoneOffset.inMinutes;
}

/// 固定偏移时区（测试/无时区数据库环境）。
class FixedOffsetEffortLocalTime implements EffortLocalTime {
  const FixedOffsetEffortLocalTime({required this.offset, this.label = ''});

  /// 例如 `Duration(hours: 8)`。
  final Duration offset;
  final String label;

  @override
  DateTime toLocal(DateTime utc) {
    final wall = utc.toUtc().add(offset);
    return DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute,
        wall.second, wall.millisecond, wall.microsecond);
  }

  @override
  DateTime localToUtc(DateTime localWall) {
    final naive = DateTime.utc(localWall.year, localWall.month, localWall.day,
        localWall.hour, localWall.minute, localWall.second,
        localWall.millisecond, localWall.microsecond);
    return naive.subtract(offset);
  }

  @override
  String get timeZoneLabel =>
      label.isNotEmpty ? label : 'UTC${_formatOffset(offset)}';

  @override
  int offsetMinutesAt(DateTime utc) => offset.inMinutes;
}

String _formatOffset(Duration offset) {
  final total = offset.inMinutes;
  final sign = total < 0 ? '-' : '+';
  final abs = total.abs();
  final h = (abs ~/ 60).toString().padLeft(2, '0');
  final m = (abs % 60).toString().padLeft(2, '0');
  return '$sign$h:$m';
}

// ------------------------------------------------------------------ 格式化

/// `yyyy-MM-dd`（本地墙钟值）。
String formatLocalDate(DateTime localWall) {
  final y = localWall.year.toString().padLeft(4, '0');
  final m = localWall.month.toString().padLeft(2, '0');
  final d = localWall.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 解析 `yyyy-MM-dd` 为本地墙钟值；非法返回 null。
DateTime? parseLocalDate(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// 计时器/状态条的时钟文案：`H:MM:SS` 或 `MM:SS`。
String formatElapsedClock(Duration duration) {
  final total = duration.inSeconds;
  final safe = total < 0 ? 0 : total;
  final h = safe ~/ 3600;
  final m = (safe % 3600) ~/ 60;
  final s = safe % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 人读时长（分钟精度）：`1 小时 5 分钟` / `40 分钟` / `0 分钟`。
String formatEffortDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  if (totalSeconds <= 0) return '0 分钟';
  final minutes = (totalSeconds / 60).ceil();
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
}

/// 小时数文案；null → 未知（绝不显示 0）。
String formatEffortHours(double? hours) {
  if (hours == null) return kEffortUnknownLabel;
  if (hours.abs() >= 10) return '${hours.toStringAsFixed(1)} 小时';
  return '${hours.toStringAsFixed(2)} 小时';
}

/// 百分比文案；null → 未知。
String formatEffortPercent(double? percent) {
  if (percent == null) return kEffortUnknownLabel;
  final rounded = percent.round();
  final sign = rounded > 0 ? '+' : '';
  return '$sign$rounded%';
}

// ------------------------------------------------------------- 记录级口径

/// 一条执行记录的统计口径。
class RecordEffort {
  RecordEffort(this.record);

  final ExecutionRecord record;

  bool get isDeleted => record.isDeleted;

  bool get isPendingCorrection =>
      record.state == ExecutionRecordState.pendingCorrection;

  /// 计时区间总时长（不含手工补记与校正）。
  Duration get timerDuration {
    var micros = 0;
    for (final interval in record.intervals) {
      micros += interval.duration.inMicroseconds;
    }
    return Duration(microseconds: micros);
  }

  /// 用户已确认计入的校正时长。
  Duration get correctionDuration {
    var micros = 0;
    for (final correction in record.pendingCorrections) {
      micros += correction.decidedDuration.inMicroseconds;
    }
    return Duration(microseconds: micros);
  }

  /// 手工补记原始时长（未扣重叠）。
  Duration get manualRawDuration {
    var micros = 0;
    for (final entry in record.manualEntries) {
      micros += entry.durationSeconds * Duration.microsecondsPerSecond;
    }
    return Duration(microseconds: micros);
  }

  /// 按口径计入的手工补记时长（默认扣除重叠部分）。
  Duration get manualCountedDuration {
    var micros = 0;
    for (final entry in record.manualEntries) {
      micros += entry.countedSeconds * Duration.microsecondsPerSecond;
    }
    return Duration(microseconds: micros);
  }

  /// 默认排除、未计入统计的重叠时长。
  Duration get overlapExcludedDuration {
    var micros = 0;
    for (final entry in record.manualEntries) {
      if (entry.overlapPolicy != OverlapPolicy.excludeOverlap) continue;
      final excluded = entry.durationSeconds - entry.countedSeconds;
      if (excluded > 0) {
        micros += excluded * Duration.microsecondsPerSecond;
      }
    }
    return Duration(microseconds: micros);
  }

  /// 用户明确保留并计入统计的重叠时长（报告必须标注）。
  Duration get overlapIncludedDuration {
    var micros = 0;
    for (final entry in record.manualEntries) {
      if (!entry.overlapIncluded) continue;
      micros += entry.overlapSeconds * Duration.microsecondsPerSecond;
    }
    return Duration(microseconds: micros);
  }

  bool get hasOverlap =>
      record.manualEntries.any((e) => e.hasOverlap);

  /// 未处理的待校正区间（展示口径，不进入确认时长）。
  Duration get pendingDuration {
    var micros = 0;
    for (final correction in record.pendingCorrections) {
      if (!correction.isOpen) continue;
      micros += correction.observedDuration.inMicroseconds;
    }
    return Duration(microseconds: micros);
  }

  int get openCorrectionCount => record.openCorrectionCount;

  /// 已确认实际耗时（统计口径）。
  Duration get confirmedDuration => Duration(
        microseconds: timerDuration.inMicroseconds +
            manualCountedDuration.inMicroseconds +
            correctionDuration.inMicroseconds,
      );

  /// 是否产生过任何事实（区分“未知”与“已记录 0 分钟”）。
  bool get hasFacts => record.hasRecordedFacts;

  bool get hasConfirmedTime => confirmedDuration > Duration.zero;

  DateTime? get firstConfirmedStartUtc {
    DateTime? best;
    for (final interval in record.intervals) {
      if (!interval.isValid) continue;
      final start = interval.startUtc;
      if (best == null || start.isBefore(best)) best = start;
    }
    for (final entry in record.manualEntries) {
      final start = entry.startUtc;
      if (start == null) continue;
      if (best == null || start.isBefore(best)) best = start;
    }
    return best;
  }

  DateTime? get lastConfirmedEndUtc {
    DateTime? best;
    for (final interval in record.intervals) {
      if (!interval.isValid) continue;
      final end = interval.endUtc;
      if (best == null || end.isAfter(best)) best = end;
    }
    for (final entry in record.manualEntries) {
      final end = entry.endUtc;
      if (end == null) continue;
      if (best == null || end.isAfter(best)) best = end;
    }
    return best;
  }

  /// 最近一次事实的发生时间（排序/报告展开用）。
  DateTime get latestFactAtUtc {
    final last = lastConfirmedEndUtc;
    if (last != null) return last;
    return record.createdAtUtc;
  }

  String get sourceSummary {
    if (timerDuration > Duration.zero &&
        (manualRawDuration > Duration.zero || correctionDuration > Duration.zero)) {
      return '计时 + 手工补记';
    }
    if (manualRawDuration > Duration.zero) return '手工补记';
    if (correctionDuration > Duration.zero) return '校正确认';
    if (timerDuration > Duration.zero) return '计时';
    return '无记录';
  }
}

/// 任务上下文（由接线方从当前计划版本构造）。
class ExecutionTaskInfo {
  const ExecutionTaskInfo({
    required this.conversationId,
    required this.taskId,
    required this.name,
    required this.planVersionId,
    required this.planRevision,
    this.currentEstimateHours,
    this.completion,
    this.deadline,
    this.lineageRootId,
    this.plannedStartUtc,
    this.plannedEndUtc,
  });

  final String conversationId;
  final String taskId;
  final String name;
  final String planVersionId;
  final int planRevision;

  /// 当前计划里的估计（可另列；历史基线不因它改变）。
  final double? currentEstimateHours;
  final Completion? completion;

  /// 截止日期（`yyyy-MM-dd`，本地日期），用于“延期任务”。
  final String? deadline;

  /// 任务谱系根 id（拆分/合并后的可靠映射）；默认等于 taskId。
  final String? lineageRootId;

  /// 选定固定计划基线里的计划开始/结束（UTC）。用于计划偏差；缺失时报告显示未知。
  final DateTime? plannedStartUtc;
  final DateTime? plannedEndUtc;

  bool get isDone => completion == Completion.done;
}

/// 会话信息（报告/下拉过滤用）。
class ExecutionConversationInfo {
  const ExecutionConversationInfo({required this.id, required this.title});

  final String id;
  final String title;
}

/// 一个任务的执行事实汇总。
class TaskEffort {
  const TaskEffort({
    required this.taskId,
    required this.displayName,
    required this.conversationIds,
    required this.records,
    required this.totalConfirmed,
    required this.rangeConfirmed,
    required this.totalPending,
    required this.openCorrectionCount,
    required this.factsKnown,
    required this.attributed,
    this.historicalNames = const <String>[],
    this.baselineHours,
    this.baselinePlanVersionId,
    this.baselinePlanRevision,
    this.currentEstimateHours,
    this.completion,
    this.deadline,
    this.plannedStartUtc,
    this.plannedEndUtc,
  });

  final String taskId;
  final String displayName;
  final Set<String> conversationIds;
  final List<RecordEffort> records;

  /// 全历史已确认时长（跨版本同一 taskId 只累计一次）。
  final Duration totalConfirmed;

  /// 报告范围内的已确认时长（按绝对时间裁剪）。
  final Duration rangeConfirmed;

  /// 未处理的待校正时长（只展示，不进入任何确认合计）。
  final Duration totalPending;
  final int openCorrectionCount;

  /// 是否产生过执行事实；false = 实际耗时未知（不是 0）。
  final bool factsKnown;

  /// 是否能归属到当前计划里的任务；false = 未归属历史记录。
  final bool attributed;

  /// 记录里出现过的历史任务名（任务改名/重新分析后仍可追溯）。
  final List<String> historicalNames;

  /// 开始执行时的有效估算基线（小时，仅 >0 视为有效）；null = 未知。
  final double? baselineHours;
  final String? baselinePlanVersionId;
  final int? baselinePlanRevision;

  /// 当前计划里的最新估计（另列，不参与历史偏差）。
  final double? currentEstimateHours;

  final Completion? completion;

  /// 截止日期（`yyyy-MM-dd` 本地日期）。
  final String? deadline;

  final DateTime? plannedStartUtc;
  final DateTime? plannedEndUtc;

  bool get isDone => completion == Completion.done;

  /// 实际耗时（小时）。未知时返回 null——调用方必须显示“未知”。
  double? get actualHours => factsKnown
      ? totalConfirmed.inMicroseconds /
          Duration.microsecondsPerHour
      : null;

  double? get rangeActualHours => factsKnown
      ? rangeConfirmed.inMicroseconds / Duration.microsecondsPerHour
      : null;

  /// 偏差（小时）= 实际 − 基线；任一未知则 null。
  double? get deviationHours {
    final baseline = baselineHours;
    final actual = actualHours;
    if (baseline == null || actual == null) return null;
    return actual - baseline;
  }

  /// 偏差百分比；仅基线与实际已知且基线 > 0 时非 null。
  double? get deviationPercent {
    final baseline = baselineHours;
    final deviation = deviationHours;
    if (baseline == null || baseline <= 0 || deviation == null) return null;
    return deviation / baseline * 100;
  }

  /// 建议剩余工时（小时）= max(基线 − 实际, 0)；只是建议，不自动完成任务。
  double? get suggestedRemainingHours {
    final baseline = baselineHours;
    final actual = actualHours;
    if (baseline == null || actual == null) return null;
    final remaining = baseline - actual;
    return remaining > 0 ? remaining : 0;
  }

  bool get overEstimate {
    final deviation = deviationHours;
    return deviation != null && deviation > 0;
  }

  /// 计划开始偏差（实际开始 − 计划开始，小时）；没有实际开始时间时未知，
  /// “手工完成但没记录真实开始时间”不生成开工延误指标。
  double? get startDeviationHours {
    final planned = plannedStartUtc;
    final actualStart = _firstActualStartUtc;
    if (planned == null || actualStart == null) return null;
    return actualStart.difference(planned).inMicroseconds /
        Duration.microsecondsPerHour;
  }

  /// 计划结束偏差（实际最后结束 − 计划结束，小时）；没有实际结束时间时未知。
  ///
  /// 使用记录里的最后确认结束时刻，与 [startDeviationHours] 一样属于“计划偏差”，
  /// 与“估计偏差”（[deviationHours]）分开显示，口径不混用。
  double? get endDeviationHours {
    final planned = plannedEndUtc;
    final actualEnd = _lastActualEndUtc;
    if (planned == null || actualEnd == null) return null;
    return actualEnd.difference(planned).inMicroseconds /
        Duration.microsecondsPerHour;
  }

  DateTime? get _firstActualStartUtc {
    DateTime? best;
    for (final effort in records) {
      final start = effort.firstConfirmedStartUtc;
      if (start == null) continue;
      if (best == null || start.isBefore(best)) best = start;
    }
    return best;
  }

  DateTime? get _lastActualEndUtc {
    DateTime? best;
    for (final effort in records) {
      final end = effort.lastConfirmedEndUtc;
      if (end == null) continue;
      if (best == null || end.isAfter(best)) best = end;
    }
    return best;
  }

  /// 未知项说明（报告/CSV 的“未知”列）。
  List<String> get unknownIndicators => <String>[
        if (baselineHours == null) '无有效估算基线',
        if (!factsKnown) '无实际工时记录',
        if (factsKnown && totalConfirmed == Duration.zero) '已记录 0 分钟',
        if (openCorrectionCount > 0) '存在待校正区间（未计入）',
        if (!attributed) '当前计划中找不到该任务（未归属历史记录）',
      ];
}

/// 报告范围内的聚合结果。
class EffortAggregate {
  const EffortAggregate({
    required this.tasks,
    required this.recordsByTask,
    required this.confirmedTotal,
    required this.pendingTotal,
    required this.pendingCorrectionCount,
    required this.confirmedByConversation,
  });

  final List<TaskEffort> tasks;
  final Map<String, List<RecordEffort>> recordsByTask;

  /// 范围内已确认总时长。
  final Duration confirmedTotal;

  /// 所有未处理待校正时长（不进入 [confirmedTotal]）。
  final Duration pendingTotal;
  final int pendingCorrectionCount;

  /// 范围内确认时长按会话汇总。
  final Map<String, Duration> confirmedByConversation;

  int get taskCount => tasks.length;

  List<TaskEffort> get unattributedTasks =>
      tasks.where((t) => !t.attributed).toList(growable: false);

  List<RecordEffort> get allRecords =>
      recordsByTask.values.expand((r) => r).toList(growable: false);

  List<RecordEffort> get pendingRecords => allRecords
      .where((r) => r.openCorrectionCount > 0)
      .toList(growable: false);

  /// 范围确认时长为 0 但存在“已记录 0 分钟”事实的任务数（与未知区分）。
  int get recordedZeroTaskCount => tasks
      .where((t) => t.factsKnown && t.totalConfirmed == Duration.zero)
      .length;

  /// 剩余建议合计（仅包含已知剩余的任务）；未知任务数单独计数。
  double? get suggestedRemainingTotalHours {
    var total = 0.0;
    var known = 0;
    for (final task in tasks) {
      if (task.isDone) continue;
      final remaining = task.suggestedRemainingHours;
      if (remaining == null) continue;
      total += remaining;
      known++;
    }
    return known == 0 ? null : total;
  }

  int get remainingUnknownTaskCount => tasks
      .where((t) => !t.isDone && t.suggestedRemainingHours == null)
      .length;
}

/// 按 taskId 汇总（跨版本同一 taskId 只累计一次；重复 recordId 只算一次）。
EffortAggregate aggregateEffort({
  required Iterable<ExecutionRecord> records,
  required Map<String, ExecutionTaskInfo> taskContext,
  DateTime? fromUtc,
  DateTime? toUtc,
  EffortLocalTime localTime = const SystemEffortLocalTime(),
  bool includeDeleted = false,
}) {
  final from = fromUtc?.toUtc();
  final to = toUtc?.toUtc();
  if (from != null && to != null && !to.isAfter(from)) {
    return const EffortAggregate(
      tasks: <TaskEffort>[],
      recordsByTask: <String, List<RecordEffort>>{},
      confirmedTotal: Duration.zero,
      pendingTotal: Duration.zero,
      pendingCorrectionCount: 0,
      confirmedByConversation: <String, Duration>{},
    );
  }

  // recordId 去重：同一份数据被多个版本/备份重复引用时只算一次。
  final deduped = <String, ExecutionRecord>{};
  for (final record in records) {
    if (!includeDeleted && record.isDeleted) continue;
    deduped.putIfAbsent(record.recordId, () => record);
  }

  final byTask = <String, List<RecordEffort>>{};
  for (final record in deduped.values) {
    byTask.putIfAbsent(record.taskId, () => <RecordEffort>[]).add(
          RecordEffort(record),
        );
  }

  // 谱系映射：找不到同名 taskId 时，若当前计划里**恰好有一个**任务的谱系根等于
  // 旧 taskId，则视为可靠继承；有多个候选（拆分）时属于歧义，不自动分摊，记录
  // 保留为“未归属历史记录”。绝不按标题相似搬移工时。
  final lineageToTask = <String, String>{};
  final ambiguousRoots = <String>{};
  taskContext.forEach((taskId, info) {
    final root = (info.lineageRootId ?? taskId).trim();
    if (root.isEmpty || root == taskId) return;
    if (lineageToTask.containsKey(root)) {
      ambiguousRoots.add(root);
    } else {
      lineageToTask[root] = taskId;
    }
  });
  final uniqueLineage = <String, String>{
    for (final entry in lineageToTask.entries)
      if (!ambiguousRoots.contains(entry.key)) entry.key: entry.value,
  };

  final tasks = <TaskEffort>[];
  final recordsByTask = <String, List<RecordEffort>>{};
  var confirmedMicros = 0;
  var pendingMicros = 0;
  var pendingCount = 0;
  final byConversation = <String, int>{};

  for (final entry in byTask.entries) {
    final taskId = entry.key;
    final recordEfforts = entry.value
      ..sort((a, b) => a.record.createdAtUtc.compareTo(b.record.createdAtUtc));
    final inheritedTaskId = uniqueLineage[taskId];
    final info = taskContext[taskId] ??
        (inheritedTaskId == null ? null : taskContext[inheritedTaskId]);
    final attributed = taskContext.containsKey(taskId) || info != null;

    final name = info?.name ??
        recordEfforts.last.record.taskName;

    // 基线：按开始时间最早的一条记录（记录创建时的有效估计），历史不漂移。
    final baselineRecord = recordEfforts.first.record;
    final rawBaseline = baselineRecord.estimateBaselineHours;
    final baseline = rawBaseline != null && rawBaseline > 0 ? rawBaseline : null;

    var totalMicros = 0;
    var rangeMicros = 0;
    var taskPendingMicros = 0;
    var taskPendingCount = 0;
    final conversationIds = <String>{};
    final names = <String>{};
    for (final effort in recordEfforts) {
      final record = effort.record;
      conversationIds.add(record.conversationId);
      if (record.taskName.trim().isNotEmpty) names.add(record.taskName.trim());
      totalMicros += effort.confirmedDuration.inMicroseconds;
      if (from == null && to == null) {
        rangeMicros += effort.confirmedDuration.inMicroseconds;
      } else {
        rangeMicros += confirmedWithin(
          effort,
          fromUtc: from,
          toUtc: to,
          localTime: localTime,
        ).inMicroseconds;
      }
      taskPendingMicros += effort.pendingDuration.inMicroseconds;
      taskPendingCount += effort.openCorrectionCount;
      final key = record.conversationId;
      byConversation[key] =
          (byConversation[key] ?? 0) + confirmedWithin(
                effort,
                fromUtc: from,
                toUtc: to,
                localTime: localTime,
              ).inMicroseconds;
    }
    names.remove(name);

    final taskEffort = TaskEffort(
      taskId: taskId,
      displayName: name,
      conversationIds: conversationIds,
      records: recordEfforts,
      totalConfirmed: Duration(microseconds: totalMicros),
      rangeConfirmed: Duration(microseconds: rangeMicros),
      totalPending: Duration(microseconds: taskPendingMicros),
      openCorrectionCount: taskPendingCount,
      factsKnown: recordEfforts.any((r) => r.hasFacts),
      attributed: attributed,
      historicalNames: names.toList(growable: false)..sort(),
      baselineHours: baseline,
      baselinePlanVersionId: baseline != null ? baselineRecord.planVersionId : null,
      baselinePlanRevision: baseline != null ? baselineRecord.planRevision : null,
      currentEstimateHours: info?.currentEstimateHours,
      completion: info?.completion,
      deadline: info?.deadline,
      plannedStartUtc: info?.plannedStartUtc,
      plannedEndUtc: info?.plannedEndUtc,
    );
    tasks.add(taskEffort);
    recordsByTask[taskId] = List<RecordEffort>.unmodifiable(recordEfforts);
    confirmedMicros += rangeMicros;
    pendingMicros += taskPendingMicros;
    pendingCount += taskPendingCount;
  }

  tasks.sort((a, b) {
    if (a.attributed != b.attributed) return a.attributed ? -1 : 1;
    final byName = a.displayName.compareTo(b.displayName);
    if (byName != 0) return byName;
    return a.taskId.compareTo(b.taskId);
  });

  return EffortAggregate(
    tasks: List<TaskEffort>.unmodifiable(tasks),
    recordsByTask: Map<String, List<RecordEffort>>.unmodifiable(recordsByTask),
    confirmedTotal: Duration(microseconds: confirmedMicros),
    pendingTotal: Duration(microseconds: pendingMicros),
    pendingCorrectionCount: pendingCount,
    confirmedByConversation: Map<String, Duration>.unmodifiable(
      byConversation.map(
        (key, micros) => MapEntry(key, Duration(microseconds: micros)),
      ),
    ),
  );
}

/// 一条记录在给定范围内确认的时长（按绝对时间裁剪）。
///
/// 仅时长模式的手工补记按锚定本地日期整天归属；已确认校正按检测时刻归属。
Duration confirmedWithin(
  RecordEffort effort, {
  DateTime? fromUtc,
  DateTime? toUtc,
  EffortLocalTime localTime = const SystemEffortLocalTime(),
}) {
  final from = fromUtc?.toUtc();
  final to = toUtc?.toUtc();
  final record = effort.record;
  var micros = 0;

  for (final interval in record.intervals) {
    if (!interval.isValid) continue;
    micros += _clippedMicros(interval.startUtc, interval.endUtc, from, to);
  }

  for (final entry in record.manualEntries) {
    if (entry.mode == ManualEntryMode.startEnd &&
        entry.startUtc != null &&
        entry.endUtc != null &&
        entry.endUtc!.isAfter(entry.startUtc!)) {
      var entryMicros = _clippedMicros(
        entry.startUtc!,
        entry.endUtc!,
        from,
        to,
      );
      if (entry.overlapPolicy == OverlapPolicy.excludeOverlap) {
        for (final overlap in entry.overlapSpans) {
          if (!overlap.isValid) continue;
          entryMicros -=
              _clippedMicros(overlap.startUtc, overlap.endUtc, from, to);
        }
      }
      if (entryMicros > 0) micros += entryMicros;
    } else {
      // 仅时长模式：只有锚定本地日期落在范围内的天时整段计入。
      if (_localDateInRange(entry.localDate, from, to, localTime)) {
        micros += entry.countedSeconds * Duration.microsecondsPerSecond;
      }
    }
  }

  for (final correction in record.pendingCorrections) {
    final decided = correction.decidedSeconds;
    if (decided == null || decided <= 0) continue;
    final at = correction.detectedAtUtc;
    if (from != null && at.isBefore(from)) continue;
    if (to != null && !at.isBefore(to)) continue;
    micros += decided * Duration.microsecondsPerSecond;
  }
  return Duration(microseconds: micros);
}

/// 一条记录在给定范围内的待校正时长（按检测时刻归属；只展示不计入）。
Duration pendingWithin(
  RecordEffort effort, {
  DateTime? fromUtc,
  DateTime? toUtc,
}) {
  final from = fromUtc?.toUtc();
  final to = toUtc?.toUtc();
  var micros = 0;
  for (final correction in effort.record.pendingCorrections) {
    if (!correction.isOpen) continue;
    final at = correction.detectedAtUtc;
    if (from != null && at.isBefore(from)) continue;
    if (to != null && !at.isBefore(to)) continue;
    micros += correction.observedDuration.inMicroseconds;
  }
  return Duration(microseconds: micros);
}

/// 按本地日期切片的范围统计。
class DailyEffortPoint {
  const DailyEffortPoint({
    required this.localDate,
    required this.confirmed,
    required this.pending,
  });

  final String localDate;
  final Duration confirmed;
  final Duration pending;
}

/// 按本地日期切片；各切片之和恒等于同一天边界范围内的 [confirmedWithin] 总和。
///
/// 跨午夜/跨 DST：日边界由 [EffortLocalTime.localToUtc] 换算，绝对时长不变，
/// 因此 DST 当天可以只有 23 或 25 小时，但切片总和仍然精确。
List<DailyEffortPoint> dailyEffort({
  required Iterable<ExecutionRecord> records,
  required DateTime fromLocalDate,
  required DateTime toLocalDate,
  EffortLocalTime localTime = const SystemEffortLocalTime(),
  bool includeDeleted = false,
}) {
  final first = DateTime.utc(
      fromLocalDate.year, fromLocalDate.month, fromLocalDate.day);
  final last =
      DateTime.utc(toLocalDate.year, toLocalDate.month, toLocalDate.day);
  if (last.isBefore(first)) return const <DailyEffortPoint>[];

  final efforts = <RecordEffort>[];
  final seen = <String>{};
  for (final record in records) {
    if (!includeDeleted && record.isDeleted) continue;
    if (!seen.add(record.recordId)) continue;
    efforts.add(RecordEffort(record));
  }

  final out = <DailyEffortPoint>[];
  var cursor = first;
  // 一次最多切 5 年，防止非法范围造成长时间循环。
  for (var guard = 0; guard < 366 * 5; guard++) {
    final next = DateTime.utc(cursor.year, cursor.month, cursor.day + 1);
    final dayStartUtc = localTime.localToUtc(cursor);
    var dayEndUtc = localTime.localToUtc(next);
    if (!dayEndUtc.isAfter(dayStartUtc)) {
      // 极端时区数据异常时退回绝对 24 小时，保证总和守恒且不死循环。
      dayEndUtc = dayStartUtc.add(const Duration(hours: 24));
    }
    var confirmedMicros = 0;
    var pendingMicros = 0;
    for (final effort in efforts) {
      confirmedMicros += confirmedWithin(
        effort,
        fromUtc: dayStartUtc,
        toUtc: dayEndUtc,
        localTime: localTime,
      ).inMicroseconds;
      pendingMicros += pendingWithin(
        effort,
        fromUtc: dayStartUtc,
        toUtc: dayEndUtc,
      ).inMicroseconds;
    }
    out.add(DailyEffortPoint(
      localDate: formatLocalDate(cursor),
      confirmed: Duration(microseconds: confirmedMicros),
      pending: Duration(microseconds: pendingMicros),
    ));
    if (!next.isAfter(last)) {
      cursor = next;
    } else {
      break;
    }
  }
  return out;
}

// -------------------------------------------------------------------- CSV

/// 生成可读的 CSV 导出（UTF-8 BOM、CRLF）。
///
/// 内容包含：统计范围、时区、指标口径、每条记录、每个任务汇总、总计、未知值。
/// 安全约定：
///   * 只导出任务名/ID/会话 ID/计划版本等本应用自己的数据，**不导出 API Key**，
///     也不导出材料原文；
///   * 以 `= + - @` 等开头的用户文本在导出时加 `'` 前缀，避免被表格软件当公式执行；
///   * 未知值写“未知”，绝不写 0。
String buildEffortCsv({
  required EffortAggregate aggregate,
  required DateTime fromUtc,
  required DateTime toUtc,
  required String rangeLabel,
  EffortLocalTime localTime = const SystemEffortLocalTime(),
  String? timeZoneLabel,
  String caliberNote = kDefaultEffortCaliberNote,
}) {
  final zone = timeZoneLabel ?? localTime.timeZoneLabel;
  final lines = <String>[];
  lines.add(<String>[
    '类型',
    '记录ID',
    '任务ID',
    '任务名称',
    '会话ID',
    '计划版本',
    '计划修订',
    '开始(本地)',
    '结束(本地)',
    '范围确认时长(分钟)',
    '待校正(分钟)',
    '来源',
    '估算基线(小时)',
    '任务累计实际(小时)',
    '偏差(小时)',
    '偏差百分比',
    '时区',
    '统计范围',
    '未知项',
    '计入口径',
  ].map(_csvText).join(','));

  for (final task in aggregate.tasks) {
    final records = aggregate.recordsByTask[task.taskId] ?? const <RecordEffort>[];
    for (final effort in records) {
      final displayStart = _displayStartUtc(effort, localTime);
      final end = effort.lastConfirmedEndUtc;
      final rangeMinutes =
          (confirmedWithin(effort, fromUtc: fromUtc, toUtc: toUtc, localTime: localTime)
                      .inSeconds /
                  60)
              .toStringAsFixed(1);
      final pendingMinutes =
          (pendingWithin(effort, fromUtc: fromUtc, toUtc: toUtc).inSeconds / 60)
              .toStringAsFixed(1);
      lines.add(<String>[
        _csvText(task.attributed ? '记录' : '未归属记录'),
        _csvText(effort.record.recordId),
        _csvText(task.taskId),
        _csvText(effort.record.taskName),
        _csvText(effort.record.conversationId),
        _csvText(effort.record.planVersionId),
        _csvText('${effort.record.planRevision}'),
        _csvText(_formatLocalDateTime(displayStart, localTime)),
        _csvText(end == null ? kEffortUnknownLabel : _formatLocalDateTime(end, localTime)),
        _csvNumber(rangeMinutes),
        _csvNumber(pendingMinutes),
        _csvText(effort.sourceSummary),
        _csvText(''),
        _csvText(''),
        _csvText(''),
        _csvText(''),
        _csvText(zone),
        _csvText(rangeLabel),
        _csvText(effort.hasFacts ? '' : '无实际工时记录'),
        _csvText(_caliberFor(effort, caliberNote)),
      ].join(','));
    }

    final unknown = task.unknownIndicators;
    lines.add(<String>[
      _csvText(task.attributed ? '任务合计' : '未归属合计'),
      _csvText(''),
      _csvText(task.taskId),
      _csvText(task.displayName),
      _csvText(task.conversationIds.join(' ')),
      _csvText(task.baselinePlanVersionId ?? ''),
      _csvText(task.baselinePlanRevision?.toString() ?? ''),
      _csvText(''),
      _csvText(''),
      _csvNumber((task.rangeConfirmed.inSeconds / 60).toStringAsFixed(1)),
      _csvNumber((task.totalPending.inSeconds / 60).toStringAsFixed(1)),
      _csvText(''),
      _csvText(''),
      _csvHours(task.baselineHours),
      _csvHours(task.actualHours),
      _csvHours(task.deviationHours),
      _csvPercent(task.deviationPercent),
      _csvText(zone),
      _csvText(rangeLabel),
      _csvText(unknown.join('；')),
      _csvText(caliberNote),
    ].join(','));
  }

  lines.add(<String>[
    _csvText('总计'),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvNumber((aggregate.confirmedTotal.inSeconds / 60).toStringAsFixed(1)),
    _csvNumber((aggregate.pendingTotal.inSeconds / 60).toStringAsFixed(1)),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(''),
    _csvText(zone),
    _csvText(rangeLabel),
    _csvText(aggregate.tasks
        .expand((t) => t.unknownIndicators)
        .toSet()
        .join('；')),
    _csvText(caliberNote),
  ].join(','));

  return '\uFEFF${lines.join('\r\n')}\r\n';
}

String _caliberFor(RecordEffort effort, String caliberNote) {
  if (effort.overlapIncludedDuration > Duration.zero) {
    return '$caliberNote（本记录含用户明确保留的重叠 '
        '${formatEffortDuration(effort.overlapIncludedDuration)}，已计入）';
  }
  if (effort.overlapExcludedDuration > Duration.zero) {
    return '$caliberNote（本记录重叠 '
        '${formatEffortDuration(effort.overlapExcludedDuration)} 默认未计入）';
  }
  return caliberNote;
}

/// 记录在 CSV 里的展示开始时间：优先第一条确认事实；仅时长补记用锚定日期。
DateTime? _displayStartUtc(RecordEffort effort, EffortLocalTime localTime) {
  final first = effort.firstConfirmedStartUtc;
  if (first != null) return first;
  for (final entry in effort.record.manualEntries) {
    final anchor = parseLocalDate(entry.localDate);
    if (anchor != null) return localTime.localToUtc(anchor);
  }
  return effort.record.createdAtUtc;
}

String _csvHours(double? value) =>
    value == null ? _csvText(kEffortUnknownLabel) : _csvNumber(_trimNumber(value));

String _csvPercent(double? value) => value == null
    ? _csvText(kEffortUnknownLabel)
    : _csvNumber('${value.toStringAsFixed(0)}%');

String _formatLocalDateTime(DateTime? utc, EffortLocalTime localTime) {
  if (utc == null) return kEffortUnknownLabel;
  final wall = localTime.toLocal(utc);
  final date = formatLocalDate(wall);
  final hh = wall.hour.toString().padLeft(2, '0');
  final mm = wall.minute.toString().padLeft(2, '0');
  return '$date $hh:$mm';
}

String _trimNumber(double value) {
  final fixed = value.toStringAsFixed(2);
  if (fixed.endsWith('.00')) return fixed.substring(0, fixed.length - 3);
  if (fixed.endsWith('0')) return fixed.substring(0, fixed.length - 1);
  return fixed;
}

/// CSV 文本单元格：公式注入防护 + 引号转义。仅用于用户可控文本。
String _csvText(String value) {
  var text = value;
  if (text.isNotEmpty) {
    final first = text.codeUnitAt(0);
    // = + - @ 以及制表符/回车开头都可能被表格软件当公式或换行注入。
    if (first == 0x3D || // =
        first == 0x2B || // +
        first == 0x2D || // -
        first == 0x40 || // @
        first == 0x09 ||
        first == 0x0D) {
      text = "'$text";
    }
  }
  return _quoteCsv(text);
}

/// CSV 数字单元格：保持数字语义（负数不会被当成公式转义）。
String _csvNumber(String value) => _quoteCsv(value);

String _quoteCsv(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

int _clippedMicros(
  DateTime start,
  DateTime end,
  DateTime? from,
  DateTime? to,
) {
  final lo = from != null && start.isBefore(from) ? from : start;
  final hi = to != null && end.isAfter(to) ? to : end;
  if (!hi.isAfter(lo)) return 0;
  return hi.difference(lo).inMicroseconds;
}

bool _localDateInRange(
  String localDate,
  DateTime? fromUtc,
  DateTime? toUtc,
  EffortLocalTime localTime,
) {
  if (localDate.trim().isEmpty) return false;
  final from = fromUtc;
  final to = toUtc;
  if (from == null && to == null) return true;
  final fromDate = from == null ? null : formatLocalDate(localTime.toLocal(from));
  final toWall = to == null ? null : localTime.toLocal(to);
  // 范围 [from, to) 的结束边界通常是本地午夜，因此“最后一天”要用 to 前一刻判断。
  final toDate = toWall == null
      ? null
      : formatLocalDate(toWall.subtract(const Duration(microseconds: 1)));
  if (fromDate != null && localDate.compareTo(fromDate) < 0) return false;
  if (toDate != null && localDate.compareTo(toDate) > 0) return false;
  return true;
}

/// 一天内的时间窗口，供测试与未来图表使用。
DateTime localDateStartUtc(DateTime localDate, EffortLocalTime localTime) =>
    localTime.localToUtc(localDate);

Duration maxDuration(Duration a, Duration b) =>
    a.inMicroseconds >= b.inMicroseconds ? a : b;

Duration minDuration(Duration a, Duration b) =>
    a.inMicroseconds <= b.inMicroseconds ? a : b;

/// 仅用于测试/内部计算的辅助：把秒数安全转换为 Duration。
Duration secondsToDuration(int seconds) => Duration(
    microseconds:
        math.max(0, seconds) * Duration.microsecondsPerSecond);
