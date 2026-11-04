// 统计纯函数测试（R01/R02）：未知≠0、基线与偏差、剩余建议、跨版本累计、
// 按日切片守恒（跨午夜/夏令时）、手工重叠口径、CSV 导出与注入防护。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';

import 'execution_test_support.dart';

/// 美东 2026-03-08 02:00 进入夏令时（-05:00 → -04:00），当天只有 23 小时。
class _UseDstLocalTime implements EffortLocalTime {
  static final DateTime _transitionUtc = DateTime.utc(2026, 3, 8, 7);

  @override
  DateTime toLocal(DateTime utc) {
    final u = utc.toUtc();
    final offset = u.isBefore(_transitionUtc)
        ? const Duration(hours: -5)
        : const Duration(hours: -4);
    final wall = u.add(offset);
    return DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute,
        wall.second, wall.millisecond, wall.microsecond);
  }

  @override
  DateTime localToUtc(DateTime localWall) {
    final naive = DateTime.utc(localWall.year, localWall.month, localWall.day,
        localWall.hour, localWall.minute, localWall.second,
        localWall.millisecond, localWall.microsecond);
    final transitionLocal = DateTime.utc(2026, 3, 8, 2);
    return naive.isBefore(transitionLocal)
        ? naive.add(const Duration(hours: 5))
        : naive.add(const Duration(hours: 4));
  }

  @override
  String get timeZoneLabel => 'US Eastern (DST test)';

  @override
  int offsetMinutesAt(DateTime utc) =>
      utc.toUtc().isBefore(_transitionUtc) ? -300 : -240;
}

ExecutionRecord _record({
  String recordId = 'rec-1',
  String taskId = 'task-a',
  String taskName = '任务 A',
  String planVersionId = 'ver-1',
  double? baseline,
  DateTime? startUtc,
  DateTime? endUtc,
  List<ManualEntry> manualEntries = const <ManualEntry>[],
  List<PendingCorrection> pending = const <PendingCorrection>[],
  DateTime? deletedAtUtc,
}) {
  final start = startUtc ?? DateTime.utc(2026, 11, 4, 1);
  final end = endUtc ?? start.add(const Duration(hours: 1));
  return ExecutionRecord(
    recordId: recordId,
    conversationId: 'conv-1',
    taskId: taskId,
    taskName: taskName,
    planVersionId: planVersionId,
    planRevision: 1,
    estimateBaselineHours: baseline,
    createdAtUtc: start,
    timeZoneName: 'Asia/Shanghai (UTC+08:00)',
    timeZoneOffsetMinutes: 480,
    intervals: <ExecutionInterval>[
      ExecutionInterval(startUtc: start, endUtc: end),
    ],
    manualEntries: manualEntries,
    pendingCorrections: pending,
    deletedAtUtc: deletedAtUtc,
  );
}

ManualEntry _manual({
  String entryId = 'm1',
  DateTime? startUtc,
  DateTime? endUtc,
  int durationSeconds = 3600,
  OverlapPolicy policy = OverlapPolicy.excludeOverlap,
  List<TimeSpan> overlapSpans = const <TimeSpan>[],
}) {
  return ManualEntry(
    entryId: entryId,
    mode: startUtc != null ? ManualEntryMode.startEnd : ManualEntryMode.duration,
    startUtc: startUtc,
    endUtc: endUtc,
    durationSeconds: durationSeconds,
    localDate: '2026-11-04',
    createdAtUtc: DateTime.utc(2026, 11, 4, 5),
    overlapSpans: overlapSpans,
    overlapPolicy: policy,
  );
}

void main() {
  group('未知 ≠ 0', () {
    test('从未记录的任务：实际耗时未知，不给 0 或 0%', () {
      final notRecorded = ExecutionRecord(
        recordId: 'empty',
        conversationId: 'conv-1',
        taskId: 'task-empty',
        taskName: '没记过的任务',
        planVersionId: 'ver-1',
        planRevision: 1,
        createdAtUtc: DateTime.utc(2026, 11, 4, 1),
        timeZoneName: '',
        timeZoneOffsetMinutes: 0,
      );
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[notRecorded],
        taskContext: <String, ExecutionTaskInfo>{
          'task-empty': taskInfo(
            taskId: 'task-empty',
            name: '没记过的任务',
            currentEstimateHours: 2,
          ),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.factsKnown, false);
      expect(task.actualHours, isNull);
      expect(task.deviationHours, isNull);
      expect(task.deviationPercent, isNull);
      expect(task.suggestedRemainingHours, isNull);
      expect(task.unknownIndicators, contains('无实际工时记录'));
    });

    test('显式补记 0 分钟 = 已记录 0 分钟（与未知不同）', () {
      final record = ExecutionRecord(
        recordId: 'zero',
        conversationId: 'conv-1',
        taskId: 'task-a',
        taskName: '任务 A',
        planVersionId: 'ver-1',
        planRevision: 1,
        estimateBaselineHours: 1,
        createdAtUtc: DateTime.utc(2026, 11, 4, 1),
        timeZoneName: '',
        timeZoneOffsetMinutes: 0,
        manualEntries: <ManualEntry>[_manual(durationSeconds: 0)],
      );
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[record],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(currentEstimateHours: 1),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.factsKnown, true);
      expect(task.actualHours, 0);
      expect(task.deviationHours, -1);
      expect(task.deviationPercent, -100);
      expect(task.unknownIndicators, contains('已记录 0 分钟'));
    });

    test('没有估算基线：偏差/百分比/剩余都未知', () {
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[_record(baseline: null)],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(currentEstimateHours: 2),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.actualHours, 1);
      expect(task.baselineHours, isNull);
      expect(task.deviationHours, isNull);
      expect(task.deviationPercent, isNull);
      expect(task.suggestedRemainingHours, isNull);
      expect(task.currentEstimateHours, 2,
          reason: '当前估计可以另列，但不能冒充历史基线');
    });

    test('基线为 0 或负数不产生偏差百分比', () {
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[_record(baseline: 0)],
        taskContext: <String, ExecutionTaskInfo>{'task-a': taskInfo()},
      );
      expect(aggregate.tasks.single.baselineHours, isNull);
      expect(aggregate.tasks.single.deviationPercent, isNull);
    });
  });

  group('基线与偏差', () {
    test('基线取开始执行时的第一条记录；后续版本/估计变化不改写历史', () {
      final first = _record(
        recordId: 'r1',
        planVersionId: 'ver-1',
        baseline: 2,
        startUtc: DateTime.utc(2026, 11, 4, 1),
        endUtc: DateTime.utc(2026, 11, 4, 2),
      );
      final second = _record(
        recordId: 'r2',
        planVersionId: 'ver-2',
        baseline: 3,
        startUtc: DateTime.utc(2026, 11, 5, 1),
        endUtc: DateTime.utc(2026, 11, 5, 1, 30),
      );
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[second, first],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(
              currentEstimateHours: 10,
              planVersionId: 'ver-9',
              planRevision: 9),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.baselineHours, 2, reason: '历史基线固定在开始执行时');
      expect(task.baselinePlanVersionId, 'ver-1');
      expect(task.currentEstimateHours, 10);
      expect(task.actualHours, 1.5);
      expect(task.deviationHours, closeTo(-0.5, 1e-9));
      expect(task.deviationPercent, closeTo(-25, 1e-9));
      expect(task.suggestedRemainingHours, closeTo(0.5, 1e-9));
      expect(task.overEstimate, false);
    });

    test('实际超过估计：偏差为正、剩余建议为 0，但不自动完成', () {
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[
          _record(baseline: 1, endUtc: DateTime.utc(2026, 11, 4, 2, 30)),
        ],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(completion: Completion.todo),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.actualHours, 1.5);
      expect(task.deviationHours, closeTo(0.5, 1e-9));
      expect(task.deviationPercent, closeTo(50, 1e-9));
      expect(task.suggestedRemainingHours, 0);
      expect(task.overEstimate, true);
      expect(task.completion, Completion.todo, reason: '剩余归零不等于自动完成');
    });

    test('第一条记录没有有效估计时基线保持未知（不回溯用后来的估计）', () {
      final first = _record(recordId: 'r1', baseline: null);
      final second = _record(recordId: 'r2', baseline: 3);
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[first, second],
        taskContext: <String, ExecutionTaskInfo>{'task-a': taskInfo()},
      );
      expect(aggregate.tasks.single.baselineHours, isNull);
      expect(aggregate.tasks.single.deviationHours, isNull);
    });

    test('跨版本同 taskId 只累计一次；重复 recordId 不重复计入', () {
      final first = _record(
        recordId: 'r1',
        planVersionId: 'ver-1',
        baseline: 2,
        endUtc: DateTime.utc(2026, 11, 4, 2),
      );
      final second = _record(
        recordId: 'r2',
        planVersionId: 'ver-2',
        baseline: 2,
        endUtc: DateTime.utc(2026, 11, 4, 1, 30),
      );
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[first, second, first],
        taskContext: <String, ExecutionTaskInfo>{'task-a': taskInfo()},
      );
      expect(aggregate.tasks.length, 1);
      expect(aggregate.tasks.single.records.length, 2);
      expectDuration(aggregate.confirmedTotal, const Duration(minutes: 90));
      expect(aggregate.recordsByTask['task-a']!.length, 2);
    });

    test('重新分析后任务改名：沿用任务 id 归属，保留历史名称说明', () {
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[_record(taskName: '旧标题')],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(name: '新标题'),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.displayName, '新标题');
      expect(task.attributed, true);
      expect(task.historicalNames, contains('旧标题'),
          reason: '改名不丢历史说明，也不搬移工时');
    });

    test('任务拆分：不按比例分摊；无法可靠归属的列为未归属', () {
      // 旧 taskId 没有出现在当前计划里；拆分后的两个子任务都指向旧 id 作为谱系根：
      // 归属存在歧义时不得自动摊派。
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[_record(taskId: 'old-task')],
        taskContext: <String, ExecutionTaskInfo>{
          'child-1': taskInfo(taskId: 'child-1', lineageRootId: 'old-task'),
          'child-2': taskInfo(taskId: 'child-2', lineageRootId: 'old-task'),
        },
      );
      expect(aggregate.unattributedTasks.length, 1);
      expect(aggregate.unattributedTasks.single.taskId, 'old-task');
      expectDuration(aggregate.confirmedTotal, const Duration(hours: 1),
          reason: '未归属记录仍保留在历史与总投入中，不丢失');
    });

    test('唯一可靠谱系映射可以继承归属', () {
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[_record(taskId: 'old-task')],
        taskContext: <String, ExecutionTaskInfo>{
          'new-task': taskInfo(
              taskId: 'new-task',
              name: '新任务',
              lineageRootId: 'old-task'),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.attributed, true);
      expect(task.taskId, 'old-task');
      expect(task.displayName, '新任务');
    });

    test('计划偏差使用固定计划基线；没有真实开始时间时为未知', () {
      final actualStart = DateTime.utc(2026, 11, 4, 3);
      final record = _record(
        startUtc: actualStart,
        endUtc: actualStart.add(const Duration(hours: 1)),
      );
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[record],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(
            plannedStartUtc: actualStart.subtract(const Duration(hours: 2)),
            plannedEndUtc: actualStart.add(const Duration(hours: 3)),
          ),
        },
      );
      final task = aggregate.tasks.single;
      expect(task.startDeviationHours, closeTo(2, 1e-9));
      expect(task.endDeviationHours, closeTo(-2, 1e-9));

      // 没有执行事实：不伪造开工延误指标。
      final noFacts = aggregateEffort(
        records: <ExecutionRecord>[
          ExecutionRecord(
            recordId: 'empty',
            conversationId: 'conv-1',
            taskId: 'task-a',
            taskName: '任务 A',
            planVersionId: 'ver-1',
            planRevision: 1,
            createdAtUtc: DateTime.utc(2026, 11, 4),
            timeZoneName: '',
            timeZoneOffsetMinutes: 0,
          ),
        ],
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(
            plannedStartUtc: DateTime.utc(2026, 11, 4, 1),
            plannedEndUtc: DateTime.utc(2026, 11, 4, 5),
          ),
        },
      );
      expect(noFacts.tasks.single.startDeviationHours, isNull);
      expect(noFacts.tasks.single.endDeviationHours, isNull);
    });
  });

  group('按日切片守恒', () {
    test('跨午夜按绝对时间分摊', () {
      final record = _record(
        startUtc: shanghaiUtc(2026, 11, 4, 22, 30),
        endUtc: shanghaiUtc(2026, 11, 5, 1, 30),
      );
      final days = dailyEffort(
        records: <ExecutionRecord>[record],
        fromLocalDate: DateTime.utc(2026, 11, 4),
        toLocalDate: DateTime.utc(2026, 11, 5),
      );
      expect(days.length, 2);
      expectDuration(days[0].confirmed, const Duration(minutes: 90));
      expectDuration(days[1].confirmed, const Duration(minutes: 90));
      expectDuration(
        days.fold(Duration.zero, (sum, day) => sum + day.confirmed),
        const Duration(hours: 3),
      );
    });

    test('夏令时当天 23 小时，切片总和仍等于绝对时长', () {
      final local = _UseDstLocalTime();
      final record = _record(
        startUtc: local.localToUtc(DateTime.utc(2026, 3, 7, 22)),
        endUtc: local.localToUtc(DateTime.utc(2026, 3, 9, 2)),
      );
      final days = dailyEffort(
        records: <ExecutionRecord>[record],
        fromLocalDate: DateTime.utc(2026, 3, 7),
        toLocalDate: DateTime.utc(2026, 3, 9),
        localTime: local,
      );
      expect(days.map((d) => d.localDate).toList(),
          ['2026-03-07', '2026-03-08', '2026-03-09']);
      expectDuration(days[0].confirmed, const Duration(hours: 2));
      expectDuration(days[1].confirmed, const Duration(hours: 23),
          reason: '夏令时当天只有 23 小时，不能按固定 24 小时摊');
      expectDuration(days[2].confirmed, const Duration(hours: 2));
      expectDuration(
        days.fold(Duration.zero, (sum, day) => sum + day.confirmed),
        const Duration(hours: 27),
      );
      // 与范围内总时长一致（守恒）。
      expectDuration(
        confirmedWithin(
          RecordEffort(record),
          fromUtc: local.localToUtc(DateTime.utc(2026, 3, 7)),
          toUtc: local.localToUtc(DateTime.utc(2026, 3, 10)),
          localTime: local,
        ),
        const Duration(hours: 27),
      );
    });

    test('范围裁剪与切片一致；只时长补记按锚定日期归属', () {
      final record = _record(
        startUtc: shanghaiUtc(2026, 11, 4, 23),
        endUtc: shanghaiUtc(2026, 11, 5, 1),
        manualEntries: <ManualEntry>[
          _manual(
            entryId: 'm-yesterday',
            durationSeconds: 1800,
          ),
        ],
      );
      final effort = RecordEffort(record);
      expectDuration(
        confirmedWithin(
          effort,
          fromUtc: shanghaiUtc(2026, 11, 4),
          toUtc: shanghaiUtc(2026, 11, 5),
          localTime: shanghaiLocalTime,
        ),
        const Duration(hours: 1) + const Duration(minutes: 30),
      );
      final days = dailyEffort(
        records: <ExecutionRecord>[record],
        fromLocalDate: DateTime.utc(2026, 11, 4),
        toLocalDate: DateTime.utc(2026, 11, 5),
      );
      expectDuration(
        days.fold(Duration.zero, (sum, day) => sum + day.confirmed),
        const Duration(hours: 2) + const Duration(minutes: 30),
        reason: '切片覆盖两天，总和 = 区间 2 小时 + 补记 30 分钟',
      );
      expectDuration(
        confirmedWithin(
          RecordEffort(record),
          fromUtc: shanghaiUtc(2026, 11, 4),
          toUtc: shanghaiUtc(2026, 11, 6),
          localTime: shanghaiLocalTime,
        ),
        const Duration(hours: 2) + const Duration(minutes: 30),
      );
    });
  });

  group('手工重叠与待校正统计口径', () {
    test('默认排除重叠；明确保留才计入并标记', () {
      final overlapSpan = TimeSpan(
        startUtc: DateTime.utc(2026, 11, 4, 1, 30),
        endUtc: DateTime.utc(2026, 11, 4, 2),
      );
      final excluded = _record(
        recordId: 'excluded',
        manualEntries: <ManualEntry>[
          _manual(
            startUtc: DateTime.utc(2026, 11, 4, 1),
            endUtc: DateTime.utc(2026, 11, 4, 2),
            overlapSpans: <TimeSpan>[overlapSpan],
          ),
        ],
      );
      final included = _record(
        recordId: 'included',
        manualEntries: <ManualEntry>[
          _manual(
            entryId: 'm2',
            startUtc: DateTime.utc(2026, 11, 4, 1),
            endUtc: DateTime.utc(2026, 11, 4, 2),
            overlapSpans: <TimeSpan>[overlapSpan],
            policy: OverlapPolicy.includeOverlap,
          ),
        ],
      );

      final excludedEffort = RecordEffort(excluded);
      expectDuration(excludedEffort.confirmedDuration,
          const Duration(hours: 1) + const Duration(minutes: 30));
      expectDuration(excludedEffort.overlapExcludedDuration,
          const Duration(minutes: 30));
      expectDuration(excludedEffort.overlapIncludedDuration, Duration.zero);

      final includedEffort = RecordEffort(included);
      expectDuration(includedEffort.confirmedDuration,
          const Duration(hours: 2));
      expectDuration(includedEffort.overlapIncludedDuration,
          const Duration(minutes: 30));
    });

    test('待校正默认不计入；处理后按用户口径进入统计', () {
      PendingCorrection correction({CorrectionDecision? decision, int? seconds}) {
        final base = PendingCorrection(
          correctionId: 'cor',
          observedStartUtc: DateTime.utc(2026, 11, 4, 2),
          observedEndUtc: DateTime.utc(2026, 11, 4, 4),
          wallDeltaSeconds: 7200,
          monotonicDeltaSeconds: 0,
          reason: CorrectionReason.suspend,
          detectedAtUtc: DateTime.utc(2026, 11, 4, 4),
        );
        if (decision == null) return base;
        return base.resolved(
          decision: decision,
          seconds: seconds ?? 0,
          atUtc: DateTime.utc(2026, 11, 4, 5),
        );
      }

      final open = _record(pending: <PendingCorrection>[correction()]);
      final openEffort = RecordEffort(open);
      expectDuration(openEffort.confirmedDuration, const Duration(hours: 1));
      expectDuration(openEffort.pendingDuration, const Duration(hours: 2));
      expect(openEffort.openCorrectionCount, 1);

      final discounted = _record(
        pending: <PendingCorrection>[
          correction(decision: CorrectionDecision.discount),
        ],
      );
      expectDuration(RecordEffort(discounted).confirmedDuration,
          const Duration(hours: 1));
      expectDuration(RecordEffort(discounted).pendingDuration, Duration.zero);

      final counted = _record(
        pending: <PendingCorrection>[
          correction(decision: CorrectionDecision.custom, seconds: 600),
        ],
      );
      expectDuration(RecordEffort(counted).confirmedDuration,
          const Duration(hours: 1) + const Duration(minutes: 10));
      expectDuration(RecordEffort(counted).correctionDuration,
          const Duration(minutes: 10));
    });

    test('软删除记录默认不进统计，显式包含时可追溯', () {
      final deleted = _record(
        recordId: 'deleted',
        deletedAtUtc: DateTime.utc(2026, 11, 4, 6),
      );
      final live = _record(recordId: 'live');
      final aggregate = aggregateEffort(
        records: <ExecutionRecord>[deleted, live],
        taskContext: <String, ExecutionTaskInfo>{'task-a': taskInfo()},
      );
      expectDuration(aggregate.confirmedTotal, const Duration(hours: 1));
      expect(aggregate.tasks.single.records.length, 1);

      final all = aggregateEffort(
        records: <ExecutionRecord>[deleted, live],
        taskContext: <String, ExecutionTaskInfo>{'task-a': taskInfo()},
        includeDeleted: true,
      );
      expectDuration(all.confirmedTotal, const Duration(hours: 2));
    });
  });

  group('CSV 导出', () {
    (EffortAggregate, String) buildCsvCase() {
      final records = <ExecutionRecord>[
        _record(
          recordId: 'r1',
          taskId: 'task-a',
          taskName: '普通任务',
          baseline: 2,
          endUtc: DateTime.utc(2026, 11, 4, 1, 30),
        ),
        _record(
          recordId: 'r2',
          taskId: 'task-b',
          taskName: '=1+1',
          baseline: 1,
          startUtc: DateTime.utc(2026, 11, 4, 3),
          endUtc: DateTime.utc(2026, 11, 4, 4),
        ),
      ];
      final aggregate = aggregateEffort(
        records: records,
        taskContext: <String, ExecutionTaskInfo>{
          'task-a': taskInfo(name: '普通任务', currentEstimateHours: 2),
          'task-b': taskInfo(
              taskId: 'task-b', name: '=1+1', currentEstimateHours: 1),
          // 只有计划、没有执行事实的任务（用于展示未知口径）。
          'task-c': taskInfo(taskId: 'task-c', name: '没有记录的任务'),
        },
        fromUtc: shanghaiUtc(2026, 11, 4),
        toUtc: shanghaiUtc(2026, 11, 5),
      );
      // 模拟回顾报告把“计划里有但没有执行事实”的任务补进聚合。
      final enriched = EffortAggregate(
        tasks: <TaskEffort>[
          ...aggregate.tasks,
          const TaskEffort(
            taskId: 'task-c',
            displayName: '没有记录的任务',
            conversationIds: <String>{'conv-1'},
            records: <RecordEffort>[],
            totalConfirmed: Duration.zero,
            rangeConfirmed: Duration.zero,
            totalPending: Duration.zero,
            openCorrectionCount: 0,
            factsKnown: false,
            attributed: true,
          ),
        ],
        recordsByTask: aggregate.recordsByTask,
        confirmedTotal: aggregate.confirmedTotal,
        pendingTotal: aggregate.pendingTotal,
        pendingCorrectionCount: aggregate.pendingCorrectionCount,
        confirmedByConversation: aggregate.confirmedByConversation,
      );
      final csv = buildEffortCsv(
        aggregate: enriched,
        fromUtc: shanghaiUtc(2026, 11, 4),
        toUtc: shanghaiUtc(2026, 11, 5),
        rangeLabel: '今日 2026-11-04',
        timeZoneLabel: 'Asia/Shanghai (UTC+08:00)',
      );
      return (enriched, csv);
    }

    test('含 BOM、时区、范围、口径与未知值，不含密钥', () {
      final (_, csv) = buildCsvCase();
      expect(csv.startsWith('\uFEFF'), true);
      expect(csv.contains('时区'), true);
      expect(csv.contains('Asia/Shanghai (UTC+08:00)'), true);
      expect(csv.contains('今日 2026-11-04'), true);
      expect(csv.contains('实际耗时='), true,
          reason: '必须写明统计口径');
      expect(csv.contains('未知'), true, reason: '没有记录的实际耗时显示未知');
      expect(csv.contains('apiKey'), false);
      expect(csv.contains('Bearer'), false);
      expect(csv.contains('secret'), false);
      expect(csv.contains('\r\n'), true);
      // 任务行 + 记录行 + 总计行。
      expect(csv.contains('任务合计'), true);
      expect(csv.contains('总计'), true);
      expect(csv.contains('1.5'), true);
    });

    test('公式注入防护：= + - @ 开头的任务名被转义', () {
      final (_, csv) = buildCsvCase();
      expect(csv.contains("'=1+1"), true);

      final injected = buildEffortCsv(
        aggregate: const EffortAggregate(
          tasks: <TaskEffort>[
            TaskEffort(
              taskId: 'task-inject',
              displayName: '-2+3',
              conversationIds: <String>{'conv-1'},
              records: <RecordEffort>[],
              totalConfirmed: Duration.zero,
              rangeConfirmed: Duration.zero,
              totalPending: Duration.zero,
              openCorrectionCount: 0,
              factsKnown: false,
              attributed: true,
            ),
          ],
          recordsByTask: <String, List<RecordEffort>>{},
          confirmedTotal: Duration.zero,
          pendingTotal: Duration.zero,
          pendingCorrectionCount: 0,
          confirmedByConversation: <String, Duration>{},
        ),
        fromUtc: shanghaiUtc(2026, 11, 4),
        toUtc: shanghaiUtc(2026, 11, 5),
        rangeLabel: '今日',
        timeZoneLabel: 'Asia/Shanghai (UTC+08:00)',
      );
      expect(injected.contains("'-2+3"), true);
    });
  });

  group('格式化文案', () {
    test('未知与 0 不混淆，时钟格式正确', () {
      expect(formatEffortHours(null), kEffortUnknownLabel);
      expect(formatEffortHours(0), contains('0.00'));
      expect(formatEffortPercent(null), kEffortUnknownLabel);
      expect(formatEffortPercent(25), '+25%');
      expect(formatEffortPercent(-12.4), '-12%');
      expect(formatElapsedClock(const Duration(seconds: 5)), '00:05');
      expect(formatElapsedClock(const Duration(minutes: 2, seconds: 3)), '02:03');
      expect(formatElapsedClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
      expect(formatElapsedClock(const Duration(seconds: -5)), '00:00');
      expect(formatEffortDuration(Duration.zero), '0 分钟');
      expect(formatEffortDuration(const Duration(hours: 1, minutes: 5)),
          '1 小时 5 分钟');
    });
  });
}
