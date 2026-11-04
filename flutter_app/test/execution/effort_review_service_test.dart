// 执行回顾服务测试（R3-R）：今日/本周/自定义范围、会话/任务过滤、完成事件时间、
// 延期任务、完成但未记录=未知、未归属历史记录、按日守恒、CSV 导出。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_review_service.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';

import 'execution_test_support.dart';

/// 固定“现在”：2026-11-04（周三）本地 09:00 / UTC 01:00。
final DateTime _now = testStartUtc;

ExecutionRecord _record({
  required String recordId,
  required String taskId,
  required String taskName,
  String conversationId = 'conv-1',
  double? baseline,
  required DateTime startLocal,
  required Duration duration,
}) {
  return recordWithInterval(
    recordId: recordId,
    conversationId: conversationId,
    taskId: taskId,
    taskName: taskName,
    estimateBaselineHours: baseline,
    startUtc: shanghaiUtc(startLocal.year, startLocal.month, startLocal.day,
        startLocal.hour, startLocal.minute),
    endUtc: shanghaiUtc(startLocal.year, startLocal.month, startLocal.day,
            startLocal.hour, startLocal.minute)
        .add(duration),
  );
}

({ExecutionLedger ledger, List<ExecutionTaskInfo> tasks,
    List<ExecutionConversationInfo> conversations}) _fixture() {
  final ledger = ExecutionLedger(
    records: <ExecutionRecord>[
      // task-a：今日 30 分钟 + 本周一 1 小时 + 上周 2 小时 + 跨午夜 1 小时。
      _record(
        recordId: 'r1',
        taskId: 'task-a',
        taskName: '任务A',
        baseline: 2,
        startLocal: DateTime(2026, 11, 4, 9),
        duration: const Duration(minutes: 30),
      ),
      _record(
        recordId: 'r2',
        taskId: 'task-a',
        taskName: '任务A',
        baseline: 2,
        startLocal: DateTime(2026, 11, 2, 10),
        duration: const Duration(hours: 1),
      ),
      _record(
        recordId: 'r3',
        taskId: 'task-a',
        taskName: '任务A',
        baseline: 2,
        startLocal: DateTime(2026, 10, 30, 10),
        duration: const Duration(hours: 2),
      ),
      _record(
        recordId: 'r4',
        taskId: 'task-a',
        taskName: '任务A',
        baseline: 2,
        startLocal: DateTime(2026, 11, 3, 23, 30),
        duration: const Duration(hours: 1),
      ),
      // task-d：今日 1 小时，基线 3 小时 → 建议剩余 2 小时。
      _record(
        recordId: 'r5',
        taskId: 'task-d',
        taskName: '任务D',
        baseline: 3,
        startLocal: DateTime(2026, 11, 4, 14),
        duration: const Duration(hours: 1),
      ),
      // 未归属历史记录（当前计划里没有 task-ghost）。
      _record(
        recordId: 'r6',
        taskId: 'task-ghost',
        taskName: '旧任务',
        conversationId: 'conv-2',
        startLocal: DateTime(2026, 11, 4, 12),
        duration: const Duration(minutes: 20),
      ),
    ],
    completionEvents: <CompletionEvent>[
      CompletionEvent(
        eventId: 'done-today',
        conversationId: 'conv-1',
        taskId: 'task-b',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: shanghaiUtc(2026, 11, 4, 10, 30),
      ),
      CompletionEvent(
        eventId: 'done-old',
        conversationId: 'conv-1',
        taskId: 'task-a',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: shanghaiUtc(2026, 10, 20, 10),
      ),
      CompletionEvent(
        eventId: 'done-undone',
        conversationId: 'conv-1',
        taskId: 'task-x',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: shanghaiUtc(2026, 11, 4, 11),
        undoneAtUtc: shanghaiUtc(2026, 11, 4, 12),
      ),
    ],
  );
  final tasks = <ExecutionTaskInfo>[
    taskInfo(
        taskId: 'task-a',
        name: '任务A',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-b',
        name: '任务B',
        completion: Completion.done,
        deadline: '2026-10-01'),
    taskInfo(
        taskId: 'task-c',
        name: '任务C',
        completion: Completion.todo,
        deadline: '2026-10-30'),
    taskInfo(
        taskId: 'task-d',
        name: '任务D',
        currentEstimateHours: 3,
        completion: Completion.todo),
    taskInfo(taskId: 'task-unestimated', name: '没估算的任务'),
  ];
  final conversations = <ExecutionConversationInfo>[
    conversationInfo(id: 'conv-1', title: '顺序表实验'),
    conversationInfo(id: 'conv-2', title: '另一个会话'),
  ];
  return (ledger: ledger, tasks: tasks, conversations: conversations);
}

EffortReviewService _service(ExecutionLedger ledger) => EffortReviewService(
      ledger: ledger,
      localTime: shanghaiLocalTime,
      nowUtc: () => _now,
    );

void main() {
  group('范围与合计', () {
    test('今日：只统计今天的事实，按绝对时间裁剪跨午夜区间', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      // 今日：r1 30 + r4 今天 30 + r5 60 + r6 20 = 140 分钟。
      expectDuration(report.confirmedTotal, const Duration(minutes: 140));
      expect(report.tasks.length, greaterThanOrEqualTo(6));
      final taskA = report.tasks.firstWhere((t) => t.taskId == 'task-a');
      expectDuration(taskA.rangeConfirmed, const Duration(minutes: 60));
      expectDuration(taskA.totalConfirmed, const Duration(minutes: 270));
      expect(report.recordsFor('task-a').length, 4);
      expect(report.completedTaskCount, 1,
          reason: '完成时间取事件时间；撤销的完成事件不计');
      expect(report.range.label, contains('今日'));
      expect(report.daily.length, 1);
      expectDuration(report.daily.first.confirmed, report.confirmedTotal);
    });

    test('本周：周一到周日；上周事实不计入，切片总和守恒', () {
      final f = _fixture();
      final report = _service(f.ledger).thisWeek(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      // 本周：今日 140 + 周一 60 + 周二跨午夜 30 = 230 分钟。
      expectDuration(report.confirmedTotal, const Duration(minutes: 230));
      expect(report.daily.length, 7);
      expectDuration(
        report.daily.fold(Duration.zero, (sum, d) => sum + d.confirmed),
        report.confirmedTotal,
      );
      expect(
        report.daily.every((d) => d.localDate.compareTo('2026-11-02') >= 0),
        true,
        reason: '本周从周一开始，上周事实不出现',
      );
    });

    test('自定义日期：只统计指定本地日期', () {
      final f = _fixture();
      final report = _service(f.ledger).custom(
        tasks: f.tasks,
        conversations: f.conversations,
        fromLocalDate: DateTime.utc(2026, 11, 3),
        toLocalDate: DateTime.utc(2026, 11, 3),
      );
      // 周二 23:30-24:00 的 30 分钟。
      expectDuration(report.confirmedTotal, const Duration(minutes: 30));
      expect(report.range.label, contains('自定义'));
    });

    test('范围颠倒会调整并说明；超长范围截断', () {
      final f = _fixture();
      final report = _service(f.ledger).build(
        tasks: f.tasks,
        conversations: f.conversations,
        range: EffortReviewRange(
          fromLocalDate: _nov5,
          toLocalDate: _nov3,
          label: '自定义',
        ),
      );
      expect(report.rangeNote, contains('顺序'));
      expect(report.range.fromLocalDate.isBefore(report.range.toLocalDate), true);
    });
  });

  group('任务口径', () {
    test('延期任务、完成但无实际、未估算分别列出', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      expect(report.delayedTasks.map((t) => t.taskId), contains('task-c'));
      expect(report.delayedTasks.map((t) => t.taskId), isNot(contains('task-b')),
          reason: '已完成任务不算延期');
      expect(report.doneWithoutActual.map((t) => t.taskId), contains('task-b'));
      expect(report.unestimatedTasks.map((t) => t.taskId),
          contains('task-unestimated'));
      final doneTask =
          report.tasks.firstWhere((t) => t.taskId == 'task-b');
      expect(doneTask.factsKnown, false);
      expect(doneTask.actualHours, isNull,
          reason: '已完成但未记录耗时 = 未知，不是 0');
    });

    test('未归属历史记录保留并计入总数，明确标记未归属', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      final ghost = report.tasks.firstWhere((t) => t.taskId == 'task-ghost');
      expect(ghost.attributed, false);
      expect(ghost.displayName, '旧任务');
      expectDuration(ghost.rangeConfirmed, const Duration(minutes: 20));
      expect(ghost.unknownIndicators, contains('当前计划中找不到该任务（未归属历史记录）'));
      expect(report.unattributedTaskCount, 1);
    });

    test('建议剩余只是建议，不自动完成', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      final taskD = report.tasks.firstWhere((t) => t.taskId == 'task-d');
      expect(taskD.suggestedRemainingHours, closeTo(2, 1e-9));
      expect(taskD.completion, Completion.todo);
      expect(report.remainingSuggestionHours, greaterThanOrEqualTo(2));
      expect(report.remainingUnknownTaskCount, greaterThan(0));
    });
  });

  group('过滤', () {
    test('按会话过滤：只保留该会话的记录与任务', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
        conversationId: 'conv-2',
      );
      expectDuration(report.confirmedTotal, const Duration(minutes: 20));
      expect(report.tasks.length, 1);
      expect(report.tasks.single.taskId, 'task-ghost');
      expect(report.conversations.length, 1);
    });

    test('按任务过滤：只统计指定 taskId', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
        taskId: 'task-a',
      );
      expectDuration(report.confirmedTotal, const Duration(minutes: 60));
      expect(report.tasks.length, 1);
      expect(report.recordsFor('task-a').length, 4);
    });
  });

  group('完成时间与未知口径', () {
    test('没有完成事件时不倒推完成时间，并给出说明', () {
      final f = _fixture();
      final ledger = ExecutionLedger(
        records: f.ledger.records,
        completionEvents: const <CompletionEvent>[],
      );
      final report = _service(ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      expect(report.completedTaskCount, 0);
      expect(report.completionNote, isNotNull);
      expect(report.doneWithoutActual.map((t) => t.taskId), contains('task-b'));
    });

    test('范围内没有执行事实：已确认 0，但任务实际显示未知', () {
      final empty = ExecutionLedger();
      final f = _fixture();
      final report = _service(empty).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      expectDuration(report.confirmedTotal, Duration.zero);
      expect(report.tasks, isNotEmpty);
      final taskA = report.tasks.firstWhere((t) => t.taskId == 'task-a');
      expect(taskA.factsKnown, false);
      expect(taskA.actualHours, isNull);
      expect(report.remainingSuggestionHours, isNull,
          reason: '没有任何实际/基线时剩余建议也是未知，不能给 0');
    });
  });

  group('CSV 导出', () {
    test('报告导出的 CSV 含时区、范围、口径、未归属与 BOM', () {
      final f = _fixture();
      final report = _service(f.ledger).today(
        tasks: f.tasks,
        conversations: f.conversations,
      );
      final csv = report.buildCsv();
      expect(csv.startsWith('\uFEFF'), true);
      expect(csv.contains('Asia/Shanghai'), true);
      expect(csv.contains('今日'), true);
      expect(csv.contains('实际耗时='), true);
      expect(csv.contains('未归属'), true);
      expect(csv.contains('完成但无实际'), false,
          reason: 'CSV 列里用“未知”而不是另造指标名');
      expect(csv.contains('未知'), true);
      expect(report.suggestedFileName(), contains('2026-11-04'));
      expect(report.suggestedFileName().endsWith('.csv'), true);
      // CSV 里的记录行数与任务记录数一致（每条记录一行，含未归属）。
      final recordRows = csv.split('\r\n').where((line) {
        final first = line.split(',').first;
        return first == '记录' || first == '未归属记录';
      }).length;
      expect(recordRows, 6);
    });
  });
}

final DateTime _nov3 = DateTime.utc(2026, 11, 3);
final DateTime _nov5 = DateTime.utc(2026, 11, 5);
