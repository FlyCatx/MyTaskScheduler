// 回顾展示层的五种数据状态（只改展示，不改聚合/CSV 空值语义）。
//
//   1. 无记录：折叠行「暂无执行记录 / 实际 —」，展开区「暂无执行记录」；
//   2. 范围外有记录：范围投入 0 分钟，实际仍显示已知总量；
//   3. 已确认零投入：范围投入 0 分钟 + 实际 0 分钟（不是“未知”）；
//   4. 已确认投入：范围投入 30 分钟、实际 0.50 小时；
//   5. 待校正：标题旁「待校正」标记，展开区列出待校正时长，且不计入合计。
//
// CSV 保持既有语义：未知值仍写“未知”，不会因为界面改成“—”而变成 0 或空。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_review_service.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/ui/execution/effort_review_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../execution/execution_test_support.dart';

ExecutionRecord _record({
  required String recordId,
  required String taskId,
  required String taskName,
  double? estimateBaselineHours,
  DateTime? startUtc,
  DateTime? endUtc,
  List<ManualEntry> manualEntries = const <ManualEntry>[],
  List<PendingCorrection> pendingCorrections = const <PendingCorrection>[],
  ExecutionRecordState state = ExecutionRecordState.confirmed,
}) {
  final DateTime created;
  if (startUtc != null) {
    created = startUtc;
  } else if (manualEntries.isNotEmpty) {
    created = manualEntries.first.createdAtUtc;
  } else {
    created = shanghaiUtc(2026, 11, 4, 8);
  }
  return ExecutionRecord(
    recordId: recordId,
    conversationId: 'conv-1',
    taskId: taskId,
    taskName: taskName,
    lineageRootId: taskId,
    planVersionId: 'ver-1',
    planRevision: 1,
    estimateBaselineHours: estimateBaselineHours,
    createdAtUtc: created,
    timeZoneName: 'Asia/Shanghai (UTC+08:00)',
    timeZoneOffsetMinutes: 480,
    state: state,
    intervals: <ExecutionInterval>[
      if (startUtc != null && endUtc != null)
        ExecutionInterval(startUtc: startUtc, endUtc: endUtc),
    ],
    manualEntries: manualEntries,
    pendingCorrections: pendingCorrections,
  );
}

({
  EffortReviewService service,
  List<ExecutionTaskInfo> tasks,
}) _fixture() {
  final records = <ExecutionRecord>[
    // 范围外：10-01 的记录，今天（11-04）范围里没有。
    _record(
      recordId: 'r-outside',
      taskId: 'task-outside',
      taskName: '范围外有记录',
      estimateBaselineHours: 2,
      startUtc: shanghaiUtc(2026, 10, 1, 9),
      endUtc: shanghaiUtc(2026, 10, 1, 9, 30),
    ),
    // 已确认零投入：0 秒的手工补记（有事实、确认时长为 0）。
    _record(
      recordId: 'r-zero',
      taskId: 'task-zero',
      taskName: '零值记录',
      manualEntries: <ManualEntry>[
        ManualEntry(
          entryId: 'm-zero',
          mode: ManualEntryMode.duration,
          durationSeconds: 0,
          localDate: '2026-11-04',
          createdAtUtc: shanghaiUtc(2026, 11, 4, 9),
        ),
      ],
    ),
    // 已确认投入：今天 30 分钟。
    _record(
      recordId: 'r-confirmed',
      taskId: 'task-confirmed',
      taskName: '已确认投入',
      estimateBaselineHours: 2,
      startUtc: shanghaiUtc(2026, 11, 4, 9),
      endUtc: shanghaiUtc(2026, 11, 4, 9, 30),
    ),
    // 待校正：有 30 分钟计时 + 20 分钟未处理待校正（不计入合计）。
    _record(
      recordId: 'r-pending',
      taskId: 'task-pending',
      taskName: '待校正记录',
      startUtc: shanghaiUtc(2026, 11, 4, 10),
      endUtc: shanghaiUtc(2026, 11, 4, 10, 30),
      state: ExecutionRecordState.pendingCorrection,
      pendingCorrections: <PendingCorrection>[
        PendingCorrection(
          correctionId: 'c1',
          observedStartUtc: shanghaiUtc(2026, 11, 4, 10, 5),
          observedEndUtc: shanghaiUtc(2026, 11, 4, 10, 25),
          wallDeltaSeconds: 1200,
          monotonicDeltaSeconds: 1200,
          reason: CorrectionReason.suspend,
          detectedAtUtc: shanghaiUtc(2026, 11, 4, 10, 30),
        ),
      ],
    ),
  ];
  final tasks = <ExecutionTaskInfo>[
    taskInfo(
        taskId: 'task-no-record',
        name: '无记录任务',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-outside',
        name: '范围外有记录',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-zero',
        name: '零值记录',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-confirmed',
        name: '已确认投入',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-pending',
        name: '待校正记录',
        currentEstimateHours: 2,
        completion: Completion.todo),
  ];
  final service = EffortReviewService(
    ledger: ExecutionLedger(records: records),
    localTime: shanghaiLocalTime,
    nowUtc: () => testStartUtc,
  );
  return (service: service, tasks: tasks);
}

Future<void> _openDialog(
  WidgetTester tester, {
  required EffortReviewService service,
  required List<ExecutionTaskInfo> tasks,
  Future<bool> Function(String name, String csv, String suggestedPath)? onExport,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 760);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1000, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open-review'),
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
  await tester.tap(find.byKey(const Key('open-review')));
  await tester.pumpAndSettle();
}

/// 一条任务折叠/展开内容里的全部文字（标题、标签、副标题、展开区）。
String _tileText(WidgetTester tester, String taskId) {
  final texts = tester.widgetList<Text>(find.descendant(
    of: find.byKey(Key('effort-review-task-$taskId')),
    matching: find.byType(Text),
  ));
  return texts.map((t) => t.data ?? '').join('\n');
}

/// 展开一条任务（先滚到可见，避免长列表里点到视口外的行）。
Future<void> _expandTask(WidgetTester tester, String taskId) async {
  final tile = find.byKey(Key('effort-review-task-$taskId'));
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('五种数据状态在折叠行/展开区/汇总里分别可辨', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);

    // 1) 无记录：暂无执行记录 + 实际 —，展开区同样写“暂无执行记录”。
    final noRecord = _tileText(tester, 'task-no-record');
    expect(noRecord, contains('暂无执行记录'));
    expect(noRecord, contains('实际 —'));
    expect(noRecord, isNot(contains('实际 0')));
    await _expandTask(tester, 'task-no-record');
    expect(
      find.byKey(const Key('effort-review-no-record-task-no-record')),
      findsOneWidget,
    );

    // 2) 范围外有记录：范围投入 0 分钟，实际总量仍可见（0.50 小时）。
    final outside = _tileText(tester, 'task-outside');
    expect(outside, contains('范围投入 0 分钟'));
    expect(outside, contains('实际 0.50 小时'));

    // 3) 已确认零投入：范围投入 0 分钟 + 实际 0 分钟（真实的零值保留）。
    final zero = _tileText(tester, 'task-zero');
    expect(zero, contains('范围投入 0 分钟'));
    expect(zero, contains('实际 0 分钟'));
    await _expandTask(tester, 'task-zero');
    final zeroRecord = tester.widgetList<Text>(find.descendant(
      of: find.byKey(const Key('effort-record-r-zero')),
      matching: find.byType(Text),
    ));
    final zeroRecordText = zeroRecord.map((t) => t.data ?? '').join('\n');
    expect(zeroRecordText, contains('范围 0 分钟'));
    expect(zeroRecordText, contains('累计 0 分钟'));

    // 4) 已确认投入：范围投入 30 分钟、实际 0.50 小时。
    final confirmed = _tileText(tester, 'task-confirmed');
    expect(confirmed, contains('范围投入 30 分钟'));
    expect(confirmed, contains('实际 0.50 小时'));

    // 5) 待校正：标题旁有标记，副标题与展开区都保留待校正时长（不计入合计）。
    expect(find.text('待校正'), findsWidgets);
    final pending = _tileText(tester, 'task-pending');
    expect(pending, contains('待校正 20 分钟'));
    await _expandTask(tester, 'task-pending');
    final pendingRecord = tester.widgetList<Text>(find.descendant(
      of: find.byKey(const Key('effort-record-r-pending')),
      matching: find.byType(Text),
    ));
    expect(
      pendingRecord.map((t) => t.data ?? '').join('\n'),
      contains('待校正 20 分钟'),
    );
    // 汇总：待校正 20 分钟（1 段），已确认投入 = 30 + 30 = 60 分钟。
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-pending'))).data,
      '20 分钟（1 段）',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('effort-review-confirmed'))).data,
      '1 小时',
    );
    // 每个任务只出现一次“实际”数值，没有“（不是 0 分钟）”这类解释。
    expect(find.textContaining('不是 0 分钟'), findsNothing);
    expect(find.textContaining('未知 ≠ 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CSV 保持既有空值语义：未知仍写“未知”，不从界面文案变成 0/空',
      (tester) async {
    final f = _fixture();
    String? csv;
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      onExport: (name, content, path) async {
        csv = content;
        return true;
      },
    );
    expect(csv, isNull);
    await tester.tap(find.byKey(const Key('effort-review-export')));
    await tester.pumpAndSettle();
    expect(csv, isNotNull);
    final content = csv!;
    // 未知值仍写“未知”，不是“—”，也不是 0。
    expect(content, contains('未知'));
    expect(content, isNot(contains('（不是 0 分钟）')));
    // 无记录任务的未知项列保留“无实际工时记录”。
    expect(content, contains('无实际工时记录'));
    // 零值记录任务的范围确认分钟数导出为 0.0（真实的 0 仍可核对）。
    expect(content, contains('0.0'));
    // 导出仍带统计范围/时区/口径三件套。
    expect(content, contains('统计范围'));
    expect(content, contains('Asia/Shanghai'));
    expect(content, contains('实际耗时='));
  });
}
