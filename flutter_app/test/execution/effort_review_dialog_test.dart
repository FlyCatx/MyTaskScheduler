// 执行回顾对话框测试：范围预设、未知/待校正/完成/延期指标、展开到记录、
// CSV 导出钩子（含 BOM 与时区口径），以及未注入导出钩子时不伪造导出。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_review_service.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/ui/execution/effort_review_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import 'execution_test_support.dart';

({ExecutionLedger ledger, EffortReviewService service, List<ExecutionTaskInfo> tasks})
    _fixture() {
  final ledger = ExecutionLedger(
    records: <ExecutionRecord>[
      recordWithInterval(
        recordId: 'r1',
        taskId: 'task-a',
        taskName: '任务A',
        estimateBaselineHours: 2,
        startUtc: shanghaiUtc(2026, 11, 4, 9),
        endUtc: shanghaiUtc(2026, 11, 4, 9, 30),
      ),
    ],
    completionEvents: <CompletionEvent>[
      CompletionEvent(
        eventId: 'e1',
        conversationId: 'conv-1',
        taskId: 'task-b',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: shanghaiUtc(2026, 11, 4, 10, 30),
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
  ];
  final service = EffortReviewService(
    ledger: ledger,
    localTime: shanghaiLocalTime,
    nowUtc: () => testStartUtc,
  );
  return (ledger: ledger, service: service, tasks: tasks);
}

Future<void> _openDialog(
  WidgetTester tester, {
  required EffortReviewService service,
  required List<ExecutionTaskInfo> tasks,
  Future<bool> Function(String name, String csv, String suggestedPath)? onExport,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => EffortReviewDialog.show(
              context,
              service: service,
              tasks: tasks,
              conversations: <ExecutionConversationInfo>[
                conversationInfo(id: 'conv-1', title: '顺序表实验'),
              ],
              initialPreset: EffortReviewPreset.today,
              onExport: onExport,
            ),
            child: const Text('打开回顾'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开回顾'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('展示已确认投入、未知/待校正、完成数、延期与建议剩余', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);

    expect(find.byKey(const Key('effort-review-dialog')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-confirmed'))).data,
      '30 分钟',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-pending'))).data,
      '无',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-completed'))).data,
      '1',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-delayed'))).data,
      '1',
      reason: '截止日期早于今天且未完成',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('effort-review-done-no-actual')))
          .data,
      '1',
      reason: '已完成但无记录 = 未知，不是 0',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-unestimated'))).data,
      '1',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-remaining'))).data,
      contains('建议'),
    );
    // “已完成但未记录”的任务在任务行显示“实际 未知”。
    expect(find.textContaining('实际 未知'), findsWidgets);
  });

  testWidgets('任务可展开到原始执行记录', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    await tester.tap(find.byKey(const Key('effort-review-task-task-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-record-r1')), findsOneWidget);
    expect(find.textContaining('范围 30 分钟'), findsWidgets);
  });

  testWidgets('切换到自定义日期范围', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('effort-review-from')), '2026-10-30');
    await tester.enterText(
        find.byKey(const Key('effort-review-to')), '2026-11-04');
    await tester.tap(find.byKey(const Key('effort-review-apply')));
    await tester.pumpAndSettle();
    final rangeText =
        tester.widget<Text>(find.byKey(const Key('effort-review-range'))).data;
    expect(rangeText, contains('自定义'));
    expect(rangeText, contains('2026-10-30'));
    expect(rangeText, contains('2026-11-04'));
  });

  testWidgets('导出钩子收到 CSVBOM/时区/口径，成功后显示已导出', (tester) async {
    final f = _fixture();
    final captured = <List<String>>[];
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      onExport: (name, csv, suggestedPath) async {
        captured.add(<String>[name, csv, suggestedPath]);
        return true;
      },
    );
    await tester.tap(find.byKey(const Key('effort-review-export')));
    await tester.pumpAndSettle();

    expect(captured.length, 1);
    final (name, csv, suggestedPath) =
        (captured.first[0], captured.first[1], captured.first[2]);
    expect(name, contains('执行回顾'));
    expect(csv.startsWith('\uFEFF'), true);
    expect(csv.contains('Asia/Shanghai'), true);
    expect(csv.contains('实际耗时='), true);
    expect(suggestedPath.endsWith('.csv'), true);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('effort-review-export-message')))
          .data,
      contains('已导出'),
    );
  });

  testWidgets('未注入导出钩子时不显示导出按钮（不伪造成功）', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    expect(find.byKey(const Key('effort-review-export')), findsNothing);
  });

  testWidgets('范围内没有记录时明确提示未知≠0', (tester) async {
    final service = EffortReviewService(
      ledger: ExecutionLedger(),
      localTime: shanghaiLocalTime,
      nowUtc: () => testStartUtc,
    );
    await _openDialog(tester, service: service, tasks: const <ExecutionTaskInfo>[]);
    expect(find.byKey(const Key('effort-review-empty')), findsOneWidget);
    expect(find.textContaining('未知 ≠ 0'), findsOneWidget);
  });
}
