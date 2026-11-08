// 汇总执行记录，生成按日期和任务查看的回顾报告。
//
// 职责：按“今日/本周/自定义日期”范围聚合执行事实，输出可追溯的回顾报告：
//   * 已确认投入（按范围裁剪，按日切片总和守恒）；
//   * 未知/待校正记录（未记录 ≠ 0，待校正不计入）；
//   * 完成任务数（完成时间取**完成事件**时间，不取当前读取时间）；
//   * 延期任务（截止日期早于今天且未完成）；
//   * 估计与实际差异（偏差 = 实际 − 开始执行时的基线；基线未知显示未知）；
//   * 未安排的剩余工作（“建议剩余”合计，仅建议，不自动完成任务）；
//   * 每个聚合值都能展开到任务与执行记录（[EffortReviewReport.recordsFor]）。
//
// 依赖注入：账本、本地时区、当前时间。本服务不读写文件、不调用模型，纯本地计算；
// 任务上下文（名称/完成状态/当前估计/截止日期）由接线方从当前计划版本构造传入。
// 所有时间范围都用“本地日期”表达，内部换算为 UTC 边界；跨午夜/夏令时按绝对时间
// 计算总时长，不假设一天 24 小时。

import 'effort_stats.dart';
import 'execution_ledger.dart';
import 'execution_models.dart';

/// 回顾范围预设。
enum EffortReviewPreset {
  today,
  thisWeek,
  custom,
}

/// 一个本地日期范围（含首尾两天）。内部换算成 `[fromUtc, toUtc)`。
class EffortReviewRange {
  const EffortReviewRange({
    required this.fromLocalDate,
    required this.toLocalDate,
    required this.label,
  });

  final DateTime fromLocalDate;
  final DateTime toLocalDate;
  final String label;

  int get dayCount =>
      DateTime.utc(toLocalDate.year, toLocalDate.month, toLocalDate.day)
          .difference(DateTime.utc(
              fromLocalDate.year, fromLocalDate.month, fromLocalDate.day))
          .inDays +
      1;
}

/// 回顾报告。
class EffortReviewReport {
  const EffortReviewReport({
    required this.fromUtc,
    required this.toUtc,
    required this.range,
    required this.timeZoneLabel,
    required this.caliberNote,
    required this.aggregate,
    required this.tasks,
    required this.daily,
    required this.completedTaskCount,
    required this.delayedTasks,
    required this.doneWithoutActual,
    required this.unestimatedTasks,
    required this.conversations,
    this.filterConversationId,
    this.filterTaskId,
    this.completionNote,
    this.rangeNote,
  });

  final DateTime fromUtc;
  final DateTime toUtc;
  final EffortReviewRange range;
  final String timeZoneLabel;
  final String caliberNote;

  /// 聚合（含范围内任务与未归属历史记录）。
  final EffortAggregate aggregate;

  /// 范围内出现的全部任务（含没有任何执行事实的当前任务，其实际为“未知”）。
  final List<TaskEffort> tasks;

  /// 按本地日期切片（总和与 [aggregate.confirmedTotal] 守恒）。
  final List<DailyEffortPoint> daily;

  /// 范围内完成事件数（完成时间取事件时间）。
  final int completedTaskCount;

  /// 延期任务（截止日期早于今天且未完成）。
  final List<TaskEffort> delayedTasks;

  /// 已完成但没有任何实际记录的当前任务（实际耗时未知，不是 0）。
  final List<TaskEffort> doneWithoutActual;

  /// 当前估计未知/无效且未完成的任务。
  final List<TaskEffort> unestimatedTasks;

  final List<ExecutionConversationInfo> conversations;
  final String? filterConversationId;
  final String? filterTaskId;

  /// 完成数口径说明（例如“本地尚未记录完成事件”）。
  final String? completionNote;

  /// 范围被调整的说明（超长范围被截断等）。
  final String? rangeNote;

  Duration get confirmedTotal => aggregate.confirmedTotal;

  Duration get pendingTotal => aggregate.pendingTotal;

  int get pendingCorrectionCount => aggregate.pendingCorrectionCount;

  int get taskCount => tasks.length;

  int get recordedZeroTaskCount => aggregate.recordedZeroTaskCount;

  int get unattributedTaskCount => aggregate.unattributedTasks.length;

  /// “未安排的剩余工作”建议合计（小时）；全部未知时 null。
  double? get remainingSuggestionHours {
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

  bool get isEmpty => tasks.isEmpty && aggregate.confirmedTotal == Duration.zero;

  /// 展开某个任务的执行记录。
  List<RecordEffort> recordsFor(String taskId) =>
      aggregate.recordsByTask[taskId] ?? const <RecordEffort>[];

  /// 导出 CSV（含时区/范围/口径/未知；公式注入防护；不含密钥或材料原文）。
  String buildCsv() => buildEffortCsv(
        aggregate: aggregate,
        fromUtc: fromUtc,
        toUtc: toUtc,
        rangeLabel: range.label,
        timeZoneLabel: timeZoneLabel,
        caliberNote: caliberNote,
      );

  /// 导出文件名建议（不含路径，由导出钩子决定实际目录）。
  String suggestedFileName() =>
      'effort-review-${formatLocalDate(range.fromLocalDate)}_'
      '${formatLocalDate(range.toLocalDate)}.csv';
}

/// 本地执行回顾服务。
class EffortReviewService {
  EffortReviewService({
    required this.ledger,
    EffortLocalTime? localTime,
    DateTime Function()? nowUtc,
    this.maxRangeDays = 366,
  })  : localTime = localTime ?? const SystemEffortLocalTime(),
        _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final ExecutionLedger ledger;
  final EffortLocalTime localTime;

  /// 单次回顾允许的最大天数（防止误输入超大范围导致卡顿）。
  final int maxRangeDays;

  final DateTime Function() _nowUtc;

  DateTime get nowUtc => _nowUtc().toUtc();

  /// 今日。
  EffortReviewReport today({
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    String? conversationId,
    String? taskId,
  }) {
    final date = todayLocalDate(nowUtc, localTime);
    return build(
      tasks: tasks,
      conversations: conversations,
      range: EffortReviewRange(
        fromLocalDate: date,
        toLocalDate: date,
        label: '今日 ${formatLocalDate(date)}',
      ),
      conversationId: conversationId,
      taskId: taskId,
    );
  }

  /// 本周（周一到周日）。
  EffortReviewReport thisWeek({
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    String? conversationId,
    String? taskId,
  }) {
    final range = weekLocalDates(nowUtc, localTime);
    return build(
      tasks: tasks,
      conversations: conversations,
      range: EffortReviewRange(
        fromLocalDate: range.from,
        toLocalDate: range.to,
        label: '本周 ${formatLocalDate(range.from)} ~ ${formatLocalDate(range.to)}',
      ),
      conversationId: conversationId,
      taskId: taskId,
    );
  }

  /// 自定义本地日期范围（含首尾）。
  EffortReviewReport custom({
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    required DateTime fromLocalDate,
    required DateTime toLocalDate,
    String? conversationId,
    String? taskId,
  }) {
    return build(
      tasks: tasks,
      conversations: conversations,
      range: EffortReviewRange(
        fromLocalDate: fromLocalDate,
        toLocalDate: toLocalDate,
        label: '自定义 ${formatLocalDate(fromLocalDate)} ~ ${formatLocalDate(toLocalDate)}',
      ),
      conversationId: conversationId,
      taskId: taskId,
    );
  }

  /// 构建报告。
  EffortReviewReport build({
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    required EffortReviewRange range,
    String? conversationId,
    String? taskId,
  }) {
    var fromDate = _naiveDate(range.fromLocalDate);
    var toDate = _naiveDate(range.toLocalDate);
    String? rangeNote;
    if (toDate.isBefore(fromDate)) {
      final tmp = fromDate;
      fromDate = toDate;
      toDate = tmp;
      rangeNote = '起止日期顺序颠倒，已按时间先后调整';
    }
    if (maxRangeDays > 0 && range.dayCount > maxRangeDays) {
      toDate = fromDate.add(Duration(days: maxRangeDays - 1));
      rangeNote = '范围超过 $maxRangeDays 天，已截断到 ${formatLocalDate(toDate)}';
    }
    final fromUtc = localTime.localToUtc(fromDate);
    final toUtc = localTime.localToUtc(toDate.add(const Duration(days: 1)));

    final filterConversation = conversationId?.trim();
    final filterTask = taskId?.trim();

    final filteredRecords = <ExecutionRecord>[];
    for (final record in ledger.activeRecords) {
      if (filterConversation != null &&
          filterConversation.isNotEmpty &&
          record.conversationId != filterConversation) {
        continue;
      }
      if (filterTask != null && filterTask.isNotEmpty && record.taskId != filterTask) {
        continue;
      }
      filteredRecords.add(record);
    }

    final contextMap = <String, ExecutionTaskInfo>{};
    for (final info in tasks) {
      if (filterConversation != null &&
          filterConversation.isNotEmpty &&
          info.conversationId != filterConversation) {
        continue;
      }
      if (filterTask != null && filterTask.isNotEmpty && info.taskId != filterTask) {
        continue;
      }
      contextMap[info.taskId] = info;
    }

    final aggregate = aggregateEffort(
      records: filteredRecords,
      taskContext: contextMap,
      fromUtc: fromUtc,
      toUtc: toUtc,
      localTime: localTime,
    );

    final allTasks = <TaskEffort>[...aggregate.tasks];
    final aggregateTaskIds = aggregate.tasks.map((t) => t.taskId).toSet();
    for (final info in contextMap.values) {
      if (aggregateTaskIds.contains(info.taskId)) continue;
      // 当前计划里有、但没有执行事实的任务：实际耗时未知（不是 0）。
      allTasks.add(TaskEffort(
        taskId: info.taskId,
        displayName: info.name,
        conversationIds: <String>{info.conversationId},
        records: const <RecordEffort>[],
        totalConfirmed: Duration.zero,
        rangeConfirmed: Duration.zero,
        totalPending: Duration.zero,
        openCorrectionCount: 0,
        factsKnown: false,
        attributed: true,
        baselineHours: null,
        currentEstimateHours: info.currentEstimateHours,
        completion: info.completion,
        deadline: info.deadline,
        plannedStartUtc: info.plannedStartUtc,
        plannedEndUtc: info.plannedEndUtc,
      ));
    }
    allTasks.sort((a, b) {
      if (a.attributed != b.attributed) return a.attributed ? -1 : 1;
      final byName = a.displayName.compareTo(b.displayName);
      if (byName != 0) return byName;
      return a.taskId.compareTo(b.taskId);
    });

    final enrichedAggregate = EffortAggregate(
      tasks: List<TaskEffort>.unmodifiable(allTasks),
      recordsByTask: aggregate.recordsByTask,
      confirmedTotal: aggregate.confirmedTotal,
      pendingTotal: aggregate.pendingTotal,
      pendingCorrectionCount: aggregate.pendingCorrectionCount,
      confirmedByConversation: aggregate.confirmedByConversation,
    );

    final daily = dailyEffort(
      records: filteredRecords,
      fromLocalDate: fromDate,
      toLocalDate: toDate,
      localTime: localTime,
    );

    final todayDate = todayLocalDate(nowUtc, localTime);
    final delayed = <TaskEffort>[];
    final doneWithoutActual = <TaskEffort>[];
    final unestimated = <TaskEffort>[];
    for (final task in allTasks) {
      if (!task.attributed) continue;
      final deadline = parseLocalDate(task.deadline ?? '');
      if (!task.isDone && deadline != null && deadline.isBefore(todayDate)) {
        delayed.add(task);
      }
      if (task.isDone && !task.factsKnown) {
        doneWithoutActual.add(task);
      }
      final estimate = task.currentEstimateHours;
      if (!task.isDone && (estimate == null || estimate <= 0)) {
        unestimated.add(task);
      }
    }

    // 完成任务数取完成事件时间；过滤条件与范围一致。
    var completedCount = 0;
    for (final event in ledger.completionEvents) {
      if (!event.isActive) continue;
      if (filterConversation != null &&
          filterConversation.isNotEmpty &&
          event.conversationId != filterConversation) {
        continue;
      }
      if (filterTask != null && filterTask.isNotEmpty && event.taskId != filterTask) {
        continue;
      }
      final at = event.completedAtUtc;
      if (at.isBefore(fromUtc) || !at.isBefore(toUtc)) continue;
      completedCount++;
    }
    final hasDoneContext =
        allTasks.any((t) => t.isDone) || ledger.activeRecords.isNotEmpty;
    final completionNote = completedCount == 0 && hasDoneContext
        ? '本次范围内没有完成事件记录；完成任务数按事件时间统计，未用当前状态倒推完成时间。'
        : null;

    final filteredConversations = conversations
        .where((c) =>
            (filterConversation == null ||
                filterConversation.isEmpty ||
                c.id == filterConversation) &&
            (filterTask == null ||
                filterTask.isEmpty ||
                contextMap.values.any(
                    (info) => info.conversationId == c.id && info.taskId == filterTask)))
        .toList(growable: false);

    return EffortReviewReport(
      fromUtc: fromUtc,
      toUtc: toUtc,
      range: EffortReviewRange(
        fromLocalDate: fromDate,
        toLocalDate: toDate,
        label: range.label,
      ),
      timeZoneLabel: localTime.timeZoneLabel,
      caliberNote: kDefaultEffortCaliberNote,
      aggregate: enrichedAggregate,
      tasks: List<TaskEffort>.unmodifiable(allTasks),
      daily: List<DailyEffortPoint>.unmodifiable(daily),
      completedTaskCount: completedCount,
      delayedTasks: List<TaskEffort>.unmodifiable(delayed),
      doneWithoutActual: List<TaskEffort>.unmodifiable(doneWithoutActual),
      unestimatedTasks: List<TaskEffort>.unmodifiable(unestimated),
      conversations: List<ExecutionConversationInfo>.unmodifiable(
          filteredConversations),
      filterConversationId: filterConversation,
      filterTaskId: filterTask,
      completionNote: completionNote,
      rangeNote: rangeNote,
    );
  }

  /// 今天的本地日期（naive，字段含义为本地年月日）。
  static DateTime todayLocalDate(DateTime nowUtc, EffortLocalTime localTime) {
    final wall = localTime.toLocal(nowUtc.toUtc());
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  /// 本周范围（周一到周日，本地日期）。
  static ({DateTime from, DateTime to}) weekLocalDates(
    DateTime nowUtc,
    EffortLocalTime localTime,
  ) {
    final today = todayLocalDate(nowUtc, localTime);
    // DateTime.weekday: 周一=1 … 周日=7。
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    return (from: _naiveDate(monday), to: _naiveDate(sunday));
  }

  static DateTime _naiveDate(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
}
