// 执行 UI 组件测试：常驻状态条、操作按钮、手工补记对话框。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/state/execution/timer_controller.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_actions.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_status_strip.dart';
import 'package:taskscheduler_flutter/src/ui/execution/manual_entry_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';

import 'execution_test_support.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ExecutionStatusStrip', () {
    testWidgets('空闲时隐藏；计时中显示任务名/时长；暂停与停止可用', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);

      await tester.pumpWidget(
          _wrap(ExecutionStatusStrip(controller: fixture.timer)));
      expect(find.byKey(const Key('execution-status-strip')), findsNothing);

      await fixture.timer.start(taskRef(name: '整理需求'));
      fixture.clock.advance(const Duration(seconds: 65));
      await fixture.timer.tick();
      await tester.pumpWidget(
          _wrap(ExecutionStatusStrip(controller: fixture.timer)));
      await tester.pump();

      expect(find.text('整理需求'), findsOneWidget);
      expect(find.text('计时中'), findsOneWidget);
      expect(find.text('01:05'), findsOneWidget,
          reason: '显示此次已记录时间，分钟取整只影响显示');

      await tester.tap(find.byKey(const Key('execution-status-toggle')));
      await tester.pumpAndSettle();
      expect(fixture.timer.isPaused, true);
      expect(find.text('已暂停'), findsOneWidget);

      await tester.tap(find.byKey(const Key('execution-status-stop')));
      await tester.pumpAndSettle();
      expect(fixture.timer.hasActive, false);
      await tester.pump();
      expect(find.byKey(const Key('execution-status-strip')), findsNothing);
    });

    testWidgets('只读实例即使空闲也显示锁与明确提示', (tester) async {
      final dir = newTempDir('widget_multi');
      TimerFixture? first;
      TimerFixture? second;
      try {
        // 真实文件锁需要真实 IO：必须放在 runAsync 里，否则 widget 测试的
        // 伪异步时钟会让 Future 永远不完成。
        await tester.runAsync(() async {
          first = await TimerFixture.create(directory: dir);
          second = await TimerFixture.create(directory: dir);
        });
        expect(second!.timer.readOnly, true);

        await tester.pumpWidget(
            _wrap(ExecutionStatusStrip(controller: second!.timer)));
        await tester.pump();
        expect(find.byIcon(Icons.lock_outline), findsOneWidget);
        expect(find.textContaining('另一个 TaskScheduler 实例'), findsOneWidget);
      } finally {
        await tester.runAsync(() async {
          await second?.close();
          await first?.close();
        });
        deleteDirQuietly(dir);
      }
    });
  });

  group('ExecutionActions', () {
    testWidgets('开始→暂停→停止，完成任务是独立按钮', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      var completed = 0;

      await tester.pumpWidget(_wrap(ExecutionActions(
        controller: fixture.timer,
        taskRef: taskRef(name: '任务 A'),
        onToggleCompletion: () async => completed++,
      )));
      await tester.pump();
      expect(find.byKey(const Key('execution-action-start')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-complete')), findsOneWidget);

      await tester.tap(find.byKey(const Key('execution-action-start')));
      await tester.pumpAndSettle();
      expect(fixture.timer.isRunning, true);
      expect(find.byKey(const Key('execution-action-pause')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-stop')), findsOneWidget);

      // “完成任务”是独立动作：只回调接线方，不停止计时、不写实际耗时。
      await tester.tap(find.byKey(const Key('execution-action-complete')));
      await tester.pumpAndSettle();
      expect(completed, 1);
      expect(fixture.timer.isRunning, true);

      await tester.tap(find.byKey(const Key('execution-action-stop')));
      await tester.pumpAndSettle();
      expect(fixture.timer.hasActive, false);
      expect(find.byKey(const Key('execution-action-start')), findsOneWidget);
    });

    testWidgets('撤销完成时按钮文案变化', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      await tester.pumpWidget(_wrap(ExecutionActions(
        controller: fixture.timer,
        taskRef: taskRef(),
        done: true,
        onToggleCompletion: () async {},
      )));
      await tester.pump();
      expect(find.text('撤销完成'), findsOneWidget);
    });
  });

  group('ManualEntryDialog', () {
    Future<List<ManualEntryOutcome?>> openDialog(
      WidgetTester tester,
      TimerFixture fixture, {
      ExecutionTaskRef? ref,
    }) async {
      final holder = <ManualEntryOutcome?>[null];
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  holder[0] = await ManualEntryDialog.show(
                    context,
                    controller: fixture.timer,
                    taskRef: ref ?? taskRef(),
                  );
                },
                child: const Text('打开补记'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开补记'));
      await tester.pumpAndSettle();
      return holder;
    }

    testWidgets('标题栏右上角关闭；模式切换改主题分段控件且校验保留', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      final holder = await openDialog(tester, fixture);

      expect(find.byKey(const Key('manual-entry-dialog')), findsOneWidget);
      // 与执行回顾一致的右上角关闭入口。
      expect(find.byKey(const Key('manual-close')), findsOneWidget);
      // 起止时间/仅时长不再是 Material SegmentedButton。
      expect(find.byType(BezierSegments), findsOneWidget);
      expect(
        find.byType(SegmentedButton<ManualEntryMode>),
        findsNothing,
        reason: '统一主题分段控件',
      );
      expect(find.byKey(const Key('manual-mode')), findsOneWidget);

      // 切换模式后字段与校验仍生效。
      await tester.tap(find.byKey(const Key('manual-mode-duration')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manual-minutes')), findsOneWidget);
      expect(find.byKey(const Key('manual-start')), findsNothing);
      await tester.enterText(find.byKey(const Key('manual-minutes')), 'abc');
      await tester.tap(find.byKey(const Key('manual-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manual-error')), findsOneWidget);
      expect(find.byKey(const Key('manual-entry-dialog')), findsOneWidget);

      // 关闭按钮返回 null，不写入记录。
      await tester.tap(find.byKey(const Key('manual-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('manual-entry-dialog')), findsNothing);
      expect(holder[0], isNull);
      expect(fixture.timer.ledger.records, isEmpty);
    });

    testWidgets('未来时间被拒绝，对话框保持打开并显示原因', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      await openDialog(tester, fixture);

      expect(find.byKey(const Key('manual-entry-dialog')), findsOneWidget);
      // 测试时钟是本地 2026-11-04 09:00，10:00 属于未来。
      await tester.enterText(
          find.byKey(const Key('manual-end')), '2026-11-04 10:00');
      await tester.tap(find.byKey(const Key('manual-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('manual-entry-dialog')), findsOneWidget);
      expect(find.byKey(const Key('manual-error')), findsOneWidget);
      expect(find.textContaining('未来'), findsOneWidget);
      expect(fixture.timer.ledger.records, isEmpty);
    });

    testWidgets('仅时长模式保存 25 分钟并写入执行记录', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      final holder = await openDialog(tester, fixture);

      await tester.tap(find.text('仅时长'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('manual-minutes')), '25');
      await tester.tap(find.byKey(const Key('manual-save')));
      await tester.pumpAndSettle();

      final outcome = holder[0];
      expect(outcome, isNotNull);
      expect(outcome!.ok, true);
      final record = fixture.timer.ledger.recordsForTask('task-a').single;
      expect(record.manualEntries.single.durationSeconds, 25 * 60);
      expect(outcome.entry!.durationSeconds, 25 * 60);
    });

    testWidgets('重叠时先展示区间，默认不计入；明确保留后计入并标注', (tester) async {      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      final now = fixture.clock.nowUtc;
      fixture.store.ledger.addRecord(recordWithInterval(
        recordId: 'existing',
        startUtc: now.subtract(const Duration(minutes: 20)),
        endUtc: now,
      ));

      final holder = await openDialog(tester, fixture);
      await tester.tap(find.byKey(const Key('manual-save')));
      await tester.pumpAndSettle();
      // 第一次保存只展开重叠提示与口径选择。
      expect(find.byKey(const Key('manual-overlap-panel')), findsOneWidget);
      expect(find.textContaining('与已有记录重叠'), findsWidgets);

      await tester.tap(find.byKey(const Key('manual-overlap-include')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('manual-save')));
      await tester.pumpAndSettle();

      final outcome = holder[0];
      expect(outcome, isNotNull);
      expect(outcome!.ok, true);
      final saved = outcome.entry!;
      expect(saved.overlapPolicy, OverlapPolicy.includeOverlap);
      expect(saved.overlapSeconds, greaterThan(0));
    });
  });
}
