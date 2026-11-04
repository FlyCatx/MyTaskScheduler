// 蓝色任务预留绑定面板的界面回归测试。
//
// 覆盖第一轮需求里的绑定要求：完整日期时间、块数/总分钟、目标任务、预估时长
//（未知就是未知，不按 0）、已有预留总量、超额预留非阻断提示、原绑定列表、
// 已删除任务的残留引用提示，以及“绑定 / 解除绑定 / 释放时段”三个明确动作。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/task_binding_panel.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

TaskBindingSelection _block({
  String reservationId = 'res-1',
  String date = '2026-11-09',
  int start = 9 * 60,
  int end = 10 * 60,
  String? taskId,
}) =>
    TaskBindingSelection(
      reservationId: reservationId,
      date: date,
      start: start,
      end: end,
      taskId: taskId,
      title: '任务预留',
    );

TaskBindingPanelResult? lastResult;

Future<void> _open(
  WidgetTester tester, {
  required List<TaskBindingSelection> selection,
  Map<String, String> taskNames = const {'t1': '写报告', 't2': '复习'},
  Map<String, double?> estimates = const {'t1': 2.0, 't2': 1.0},
  Map<String, int> reserved = const {},
}) async {
  lastResult = null;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 800);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(900, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              lastResult = await showTaskBindingPanel(
                context,
                selection: selection,
                taskNames: taskNames,
                taskEstimatedHours: estimates,
                reservedMinutesByTask: reserved,
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('显示完整日期时间、块数、总分钟与原绑定', (tester) async {
    await _open(tester, selection: [
      _block(reservationId: 'res-1', date: '2026-11-09', taskId: 't1'),
      _block(
        reservationId: 'res-2',
        date: '2026-11-10',
        start: 14 * 60,
        end: 15 * 60 + 30,
      ),
    ]);
    expect(find.byKey(const Key('task-binding-panel')), findsOneWidget);
    expect(find.textContaining('已选 2 块任务预留 · 共 150 分钟'), findsOneWidget);
    // 每块都写完整日期与时间，跨日期也不会只显示 HH:mm。
    expect(find.text('2026-11-09 09:00-10:00'), findsOneWidget);
    expect(find.text('2026-11-10 14:00-15:30'), findsOneWidget);
    // 原绑定：一条已绑定、一条未绑定。
    expect(find.textContaining('写报告：1 块 · 60 分钟'), findsOneWidget);
    expect(find.textContaining('未绑定：1 块 · 90 分钟'), findsOneWidget);
  });

  testWidgets('工时未知显示未知，不按 0 处理也不报超额', (tester) async {
    await _open(
      tester,
      selection: [_block(taskId: 't1')],
      estimates: const {'t1': null},
      reserved: const {'t1': 90},
    );
    expect(find.text('预估时长：未知'), findsOneWidget);
    expect(find.text('已有预留总量：90 分钟'), findsOneWidget);
    expect(find.textContaining('工时未知，不按 0 判断'), findsOneWidget);
    expect(find.byKey(const Key('task-binding-over-warning')), findsNothing);
    // 未知工时不能被写成“0 分钟”。
    expect(find.text('预估时长：0 分钟'), findsNothing);
  });

  testWidgets('超额预留给出非阻断提示，仍可绑定', (tester) async {
    await _open(
      tester,
      selection: [_block()],
      estimates: const {'t1': 2.0},
      reserved: const {'t1': 90},
    );
    // 90（已有）+ 60（本次）= 150 > 120（预估）→ 超出 30 分钟。
    expect(find.text('预留超出预估工时 30 分钟（不阻止保存）'), findsOneWidget);
    expect(find.text('本次操作后合计：150 分钟'), findsOneWidget);
    final bind = tester
        .widget<FilledButton>(find.byKey(const Key('task-binding-bind')));
    expect(bind.onPressed, isNotNull, reason: '超额提示不得阻断绑定');
  });

  testWidgets('改绑时扣除这些块已属于目标任务的分钟，避免重复累计', (tester) async {
    await _open(
      tester,
      selection: [
        _block(
            reservationId: 'res-1', start: 9 * 60, end: 10 * 60, taskId: 't1'),
        _block(reservationId: 'res-2', start: 11 * 60, end: 12 * 60),
      ],
      reserved: const {'t1': 120},
    );
    // 默认选中“写报告”（已有绑定）。90 分钟已含其中 60 分钟。
    expect(find.text('本次操作后合计：180 分钟'), findsOneWidget,
        reason: '120 已有 − 60 已在目标上 + 120 本次 = 180');
  });

  testWidgets('绑定动作返回目标任务 ID', (tester) async {
    await _open(tester, selection: [_block()]);
    await tester.tap(find.byKey(const Key('task-binding-task-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复习').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-binding-bind')));
    await tester.pumpAndSettle();
    expect(lastResult, isNotNull);
    expect(lastResult!.action, TaskBindingAction.bind);
    expect(lastResult!.taskId, 't2');
  });

  testWidgets('解除绑定返回 unbind 动作（保留为未绑定预留）', (tester) async {
    await _open(tester, selection: [_block(taskId: 't1')]);
    await tester.tap(find.byKey(const Key('task-binding-unbind')));
    await tester.pumpAndSettle();
    expect(lastResult!.action, TaskBindingAction.unbind);
    expect(lastResult!.taskId, isNull);
  });

  testWidgets('释放时段是独立动作，必须先确认；取消不返回结果', (tester) async {
    await _open(tester, selection: [_block(taskId: 't1')]);
    await tester.tap(find.byKey(const Key('task-binding-release')));
    await tester.pumpAndSettle();
    expect(find.text('释放这些时段？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-binding-release-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-binding-panel')), findsOneWidget);
    expect(lastResult, isNull);

    await tester.tap(find.byKey(const Key('task-binding-release')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-binding-release-confirm')));
    await tester.pumpAndSettle();
    expect(lastResult!.action, TaskBindingAction.release);
  });

  testWidgets('已删除任务的残留引用明确提示，仍可解除或释放', (tester) async {
    await _open(tester, selection: [
      _block(reservationId: 'res-1', taskId: 'gone-task'),
    ]);
    expect(find.byKey(const Key('task-binding-orphan-warning')), findsOneWidget);
    expect(find.textContaining('已删除任务（gone-task）'), findsOneWidget);
    // 解除绑定不依赖目标任务是否仍存在。
    await tester.tap(find.byKey(const Key('task-binding-unbind')));
    await tester.pumpAndSettle();
    expect(lastResult!.action, TaskBindingAction.unbind);
  });

  testWidgets('没有可绑定任务时给出说明，绑定按钮禁用', (tester) async {
    await _open(tester, selection: [_block()], taskNames: const {});
    expect(find.byKey(const Key('task-binding-no-tasks')), findsOneWidget);
    final bind = tester
        .widget<FilledButton>(find.byKey(const Key('task-binding-bind')));
    expect(bind.onPressed, isNull);
    // 取消仍可用，不制造新的绑定。
    await tester.tap(find.byKey(const Key('task-binding-cancel')));
    await tester.pumpAndSettle();
    expect(lastResult, isNull);
  });
}
