// 执行截止相关 UI 组件测试（0.5.0 任务 13）：
//   * 详情浮窗底栏按钮按阶段切换（开始任务/暂停/继续任务/延长时间 + 结束任务）；
//   * “延长时间”对话框：打开/取消不算延期成功，确认后保存新截止并重排提醒；
//   * 顶部状态条展示待处理/二次提醒与操作，前台等价提醒“显示后”才回报投递。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_controller.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_notification.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/timer_controller.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_actions.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_extension_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_status_strip.dart';
import 'package:taskscheduler_flutter/src/ui/task_list.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

import 'execution_test_support.dart';
import 'fake_effort_clock.dart';

class _FakeNotifications implements ExecutionNotificationPort {
  _FakeNotifications({this.accept = true});

  bool accept;

  @override
  bool get supported => true;

  @override
  ExecutionNotificationPreparation prepare() =>
      const ExecutionNotificationPreparation(ok: true, channel: 'fake');

  @override
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) {
    if (!accept) {
      return const ExecutionNotificationAttempt(
        accepted: false,
        errorKind: 'policy',
        error: '系统通知被策略关闭',
      );
    }
    return const ExecutionNotificationAttempt(accepted: true, channel: 'fake');
  }

  @override
  String? takeActionJson() => null;
}

class _Harness {
  _Harness({
    required this.clock,
    required this.timer,
    required this.store,
    required this.notifications,
  });

  final FakeEffortClock clock;
  final TimerController timer;
  final ExecutionStore store;
  final _FakeNotifications notifications;

  late final ExecutionDeadlineController controller;
  late ExecutionDeadlineTarget target;
  bool visible = true;
  int completionCalls = 0;
  int extensionApplyCalls = 0;

  static Future<_Harness> create({
    bool visible = true,
    bool acceptNative = true,
    DateTime? clockStart,
  }) async {
    final clock = FakeEffortClock(startUtc: clockStart ?? startAt);
    final fixture = await TimerFixture.create(memory: true, clock: clock);
    return _Harness(
      clock: clock,
      timer: fixture.timer,
      store: fixture.store,
      notifications: _FakeNotifications(accept: acceptNative),
    )..visible = visible;
  }

  static final DateTime startAt = shanghaiUtc(2026, 11, 4, 14, 0);
  static final DateTime deadlineAt = shanghaiUtc(2026, 11, 4, 16, 0);

  Future<void> attach() async {
    target = ExecutionDeadlineTarget(
      taskName: '前端页面开发',
      planVersionId: 'ver-1',
      planRevision: 1,
      plannedStartUtc: startAt,
      plannedEndUtc: deadlineAt,
    );
    controller = ExecutionDeadlineController(
      timer: timer,
      store: ExecutionDeadlineStore(store),
      clock: clock,
      localTime: shanghaiLocalTime,
      notifications: notifications,
      resolveTarget: (conversationId, taskId) async => target,
      taskRefFor: (conversationId, taskId) async =>
          taskRef(name: '前端页面开发'),
      completeTask: (conversationId, taskId, atUtc, source) async {
        completionCalls++;
        return const ExecutionCompletionOutcome(ok: true, message: '已完成');
      },
      previewExtensionFor: (conversationId, taskId, newEndUtc) async =>
          ExecutionExtensionPreview(
        currentDeadlineUtc: target.plannedEndUtc,
        newDeadlineUtc: newEndUtc,
        conflicts: const <String>['任务重叠：16:00–16:30'],
        otherTaskNames: const <String>['做实验'],
      ),
      applyExtensionFor: (conversationId, taskId, newEndUtc) async {
        extensionApplyCalls++;
        target = ExecutionDeadlineTarget(
          taskName: target.taskName,
          planVersionId: target.planVersionId,
          planRevision: target.planRevision + 1,
          plannedStartUtc: target.plannedStartUtc,
          plannedEndUtc: newEndUtc,
        );
        return true;
      },
      openTask: (conversationId, taskId) async {},
      isAppVisible: () => visible,
      autoTick: false,
      deliveryRetryInterval: Duration.zero,
    );
    await controller.load();
  }

  Future<void> start() async {
    await timer.start(taskRef(name: '前端页面开发'));
    await controller.tick();
  }

  ExecutionDeadlineSession? get session => controller.primarySession;

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
    await timer.shutdown();
    timer.dispose();
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ExecutionActions 阶段按钮', () {
    testWidgets('待处理：主按钮延长时间、次按钮结束任务，结束后完成一次', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);

      await tester.pumpWidget(_wrap(ExecutionActions(
        controller: h.timer,
        taskRef: taskRef(name: '前端页面开发'),
        deadline: h.controller,
        onToggleCompletion: () async {},
      )));
      await tester.pump();
      expect(find.byKey(const Key('execution-action-extend')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-finish')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-start')), findsNothing);

      await tester.tap(find.byKey(const Key('execution-action-finish')));
      await tester.pumpAndSettle();
      expect(h.completionCalls, 1);
    });

    testWidgets('执行中：暂停 + 结束任务；只停止计时在次级入口', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();

      await tester.pumpWidget(_wrap(ExecutionActions(
        controller: h.timer,
        taskRef: taskRef(name: '前端页面开发'),
        deadline: h.controller,
        onToggleCompletion: () async {},
      )));
      await tester.pump();
      expect(find.byKey(const Key('execution-action-pause')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-finish')), findsOneWidget);
      expect(find.byKey(const Key('execution-action-stop')), findsOneWidget);
      expect(find.text('结束任务'), findsOneWidget);

      await tester.tap(find.byKey(const Key('execution-action-pause')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('execution-action-resume')), findsOneWidget);

      // 只停止计时：计时结束但任务未完成、提醒被撤销。
      await tester.tap(find.byKey(const Key('execution-action-stop')));
      await tester.pumpAndSettle();
      expect(h.timer.hasActive, isFalse);
      expect(h.completionCalls, 0);
    });
  });

  group('延长时间对话框', () {
    Future<void> openDialog(WidgetTester tester, _Harness h) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open-extension'),
                onPressed: () => showExecutionExtensionDialog(
                  context,
                  controller: h.controller,
                  session: h.session!,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open-extension')));
      await tester.pumpAndSettle();
    }

    testWidgets('取消不算延期成功；确认后保存新截止并恢复计时', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();

      await openDialog(tester, h);
      expect(find.byKey(const Key('execution-extension-dialog')), findsOneWidget);
      expect(find.textContaining('当前有效截止'), findsOneWidget);
      expect(find.byKey(const Key('execution-extension-overlaps')), findsOneWidget);
      expect(find.textContaining('16:30'), findsWidgets);

      await tester.tap(find.byKey(const Key('execution-extension-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('execution-extension-dialog')), findsNothing);
      expect(h.extensionApplyCalls, 0, reason: '取消不算延期成功');
      expect(h.session!.stage, ExecutionDeadlineStage.pending);

      // 重新打开并确认：保存新甘特结束时刻、重排提醒、恢复计时。
      await openDialog(tester, h);
      await tester.tap(find.byKey(const Key('execution-extension-confirm')));
      await tester.pumpAndSettle();
      expect(h.extensionApplyCalls, 1);
      expect(find.byKey(const Key('execution-extension-dialog')), findsNothing);
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);
      expect(h.session!.deadlineUtc, shanghaiUtc(2026, 11, 4, 16, 30));
      expect(h.timer.isRunning, isTrue, reason: '从确认时刻恢复计时');
    });

    testWidgets('确认失败保留原状态并可在对话框内重试', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();

      // 让保存失败一次：直接用过期 revision 提交模拟“期间状态变化”。
      final stale = h.session!.revision - 1;
      final result = await h.controller.confirmExtension(
        h.session!.executionId,
        shanghaiUtc(2026, 11, 4, 16, 30),
        expectedRevision: stale,
      );
      expect(result.ok, isFalse);
      expect(h.session!.stage, ExecutionDeadlineStage.pending,
          reason: '失败保留原状态');
      expect(h.extensionApplyCalls, 0);
    });
  });

  group('任务清单待处理角标', () {
    testWidgets('到点待处理的任务行显示“待处理”，行交互不变', (tester) async {
      final snapshot = FakeScheduleEngine.buildSnapshotFor(samplePlan());
      final task = snapshot.tasks.firstWhere((t) => t.id == 'task-a');
      final interaction = TaskInteraction();
      var tapped = 0;
      var toggled = 0;

      Widget row({required bool pending}) => _wrap(TaskRow(
            key: const ValueKey('task-row-task-a'),
            task: task,
            orderIndex: 1,
            selected: false,
            canEdit: true,
            reviewNote: null,
            executionPending: pending,
            onTap: () => tapped++,
            onToggle: () => toggled++,
            onConfirmReview: () {},
            interaction: interaction,
          ));

      await tester.pumpWidget(row(pending: true));
      await tester.pump();
      expect(find.byKey(const Key('task-execution-pending-task-a')),
          findsOneWidget);
      expect(find.text('待处理'), findsOneWidget);
      expect(task.isDone, isFalse, reason: '角标不改任务完成状态');

      await tester.tap(find.text(task.name));
      await tester.pump();
      expect(tapped, 1);

      await tester.pumpWidget(row(pending: false));
      await tester.pump();
      expect(find.byKey(const Key('task-execution-pending-task-a')),
          findsNothing);
    });
  });

  group('ExecutionStatusStrip 截止状态', () {
    testWidgets('待处理显示延长时间/结束任务与截止提示', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();

      await tester.pumpWidget(_wrap(ExecutionStatusStrip(
        controller: h.timer,
        deadline: h.controller,
        showWhenIdle: true,
      )));
      await tester.pump();
      expect(find.byKey(const Key('execution-status-task')), findsOneWidget);
      expect(find.text('待处理'), findsOneWidget);
      expect(find.byKey(const Key('execution-status-extend')), findsOneWidget);
      expect(find.byKey(const Key('execution-status-finish')), findsOneWidget);
      expect(find.byKey(const Key('execution-status-stop')), findsNothing);
      expect(find.byKey(const Key('execution-status-deadline')), findsOneWidget);
    });

    testWidgets('系统通知不可用时前台显示等价提醒，并回报投递确认', (tester) async {
      final h = await _Harness.create(visible: true, acceptNative: false);
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();
      expect(h.session!.firstDelivered, isFalse,
          reason: '前台还没真实显示前不能记投递');

      expect(h.controller.foregroundPendingFor(h.session!.executionId), isTrue,
          reason: '系统拒绝后应进入前台等价投递待显示状态');

      await tester.pumpWidget(_wrap(ExecutionStatusStrip(
        controller: h.timer,
        deadline: h.controller,
      )));
      await tester.pumpAndSettle();
      expect(h.controller.foregroundPendingFor(h.session!.executionId), isFalse);
      expect(h.session!.firstDelivered, isTrue);
      expect(h.session!.firstDeliveryChannel, 'foreground');
      expect(find.byKey(const Key('execution-status-foreground')), findsOneWidget,
          reason: '前台等价提醒保持可见，并明确说明系统通知不可用');
    });

    testWidgets('二次提醒显示 16:10 截止文案', (tester) async {
      final h = await _Harness.create();
      addTearDown(h.close);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.controller.tick();
      h.clock.advance(const Duration(minutes: 5));
      await h.controller.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);

      await tester.pumpWidget(_wrap(ExecutionStatusStrip(
        controller: h.timer,
        deadline: h.controller,
      )));
      await tester.pump();
      expect(find.text('等待回复'), findsOneWidget);
      expect(find.textContaining('请在 16:10 前选择，届时将自动完成'), findsOneWidget);
    });
  });
}
