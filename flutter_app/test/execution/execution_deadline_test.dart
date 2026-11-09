// 任务执行截止/提醒状态机的可注入时钟测试（0.5.0 任务 13）。
//
// 场景锚点：本地 14:00 开始、甘特最后一段 16:00 结束（固定 +08:00 时区）。
// 断言重点：15:59:59 / 16:00 / 16:04:59 / 16:05 / 16:09:59 / 16:10 的状态、
// 累计工时、通知次数、依赖（完成命令）调用；以及暂停、延长、只停止计时、
// 重复开始、通知被拒、前台等价操作、重启恢复两种、延长 vs 自动完成竞态。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_controller.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_notification.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/timer_controller.dart';

import 'execution_test_support.dart';
import 'fake_effort_clock.dart';

// ---------------------------------------------------------------- 假通知端口

class _Shown {
  const _Shown({
    required this.kind,
    required this.title,
    required this.body,
    required this.payload,
  });

  final String kind;
  final String title;
  final String body;
  final Map<String, dynamic> payload;
}

class _FakeNotifications implements ExecutionNotificationPort {
  _FakeNotifications({this.accept = true});

  /// 系统是否接受可操作通知。
  bool accept;
  final List<_Shown> shown = <_Shown>[];
  final List<String> queuedActions = <String>[];

  @override
  bool get supported => true;

  @override
  ExecutionNotificationPreparation prepare() => const ExecutionNotificationPreparation(
        ok: true,
        channel: 'fake',
      );

  @override
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) {
    shown.add(_Shown(
      kind: '${payload['kind'] ?? ''}',
      title: title,
      body: body,
      payload: Map<String, dynamic>.from(payload),
    ));
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
  String? takeActionJson() =>
      queuedActions.isEmpty ? null : queuedActions.removeAt(0);

  List<_Shown> ofKind(String kind) =>
      shown.where((s) => s.kind == kind).toList(growable: false);

  void queueAction({
    required String action,
    required String taskId,
    required String executionId,
    required String deadline,
  }) {
    queuedActions.add(jsonEncode(<String, dynamic>{
      'action': action,
      'taskId': taskId,
      'executionId': executionId,
      'deadline': deadline,
    }));
  }
}

// ---------------------------------------------------------------- 测试夹具

ExecutionDeadlineTarget targetOf({
  required String name,
  DateTime? startUtc,
  DateTime? endUtc,
  bool isDone = false,
}) =>
    ExecutionDeadlineTarget(
      taskName: name,
      planVersionId: 'ver-1',
      planRevision: 1,
      plannedStartUtc: startUtc,
      plannedEndUtc: endUtc,
      isDone: isDone,
    );

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

  final Map<String, ExecutionDeadlineTarget> targets =
      <String, ExecutionDeadlineTarget>{};
  final List<String> opened = <String>[];
  int completionCalls = 0;
  DateTime? lastCompletionAt;
  String? lastCompletionSource;
  int extensionApplyCalls = 0;
  bool allowExtension = true;
  bool visible = true;

  static String key(String conversationId, String taskId) =>
      '$conversationId|$taskId';

  static Future<_Harness> create({
    required Directory directory,
    required FakeEffortClock clock,
    bool memory = false,
    _FakeNotifications? notifications,
  }) async {
    final fixture = await TimerFixture.create(
      directory: memory ? null : directory,
      clock: clock,
      memory: memory,
    );
    return _Harness(
      clock: clock,
      timer: fixture.timer,
      store: fixture.store,
      notifications: notifications ?? _FakeNotifications(),
    );
  }

  ExecutionDeadlineSession? get session => controller.primarySession;

  ExecutionDeadlineSession? get lastSession =>
      controller.sessions.isEmpty ? null : controller.sessions.last;

  ExecutionDeadlineTarget? targetFor(String conversationId, String taskId) =>
      targets[key(conversationId, taskId)];

  void setTarget({
    String conversationId = 'conv-1',
    String taskId = 'task-a',
    String name = '前端页面开发',
    DateTime? startUtc,
    DateTime? endUtc,
    bool isDone = false,
  }) {
    targets[key(conversationId, taskId)] = targetOf(
      name: name,
      startUtc: startUtc,
      endUtc: endUtc,
      isDone: isDone,
    );
  }

  Future<void> attach() async {
    controller = ExecutionDeadlineController(
      timer: timer,
      store: ExecutionDeadlineStore(store),
      clock: clock,
      localTime: shanghaiLocalTime,
      notifications: notifications,
      resolveTarget: (conversationId, taskId) async =>
          targets[key(conversationId, taskId)],
      taskRefFor: (conversationId, taskId) async => taskRef(
        conversationId: conversationId,
        taskId: taskId,
        name: targetFor(conversationId, taskId)?.taskName ?? taskId,
      ),
      completeTask: (conversationId, taskId, atUtc, source) async {
        completionCalls++;
        lastCompletionAt = atUtc;
        lastCompletionSource = source;
        final existing = targetFor(conversationId, taskId);
        if (existing != null) {
          targets[key(conversationId, taskId)] = ExecutionDeadlineTarget(
            taskName: existing.taskName,
            planVersionId: existing.planVersionId,
            planRevision: existing.planRevision + 1,
            plannedStartUtc: existing.plannedStartUtc,
            plannedEndUtc: existing.plannedEndUtc,
            isDone: true,
          );
        }
        return const ExecutionCompletionOutcome(ok: true, message: '已完成');
      },
      previewExtensionFor: (conversationId, taskId, newEndUtc) async {
        final existing = targetFor(conversationId, taskId);
        return ExecutionExtensionPreview(
          currentDeadlineUtc: existing?.plannedEndUtc,
          newDeadlineUtc: newEndUtc,
          conflicts: existing == null
              ? const <String>[]
              : const <String>['任务重叠：16:00–16:30'],
          otherTaskNames: existing == null
              ? const <String>[]
              : const <String>['做实验'],
        );
      },
      applyExtensionFor: (conversationId, taskId, newEndUtc) async {
        if (!allowExtension) return false;
        final existing = targetFor(conversationId, taskId);
        if (existing == null) return false;
        extensionApplyCalls++;
        targets[key(conversationId, taskId)] = ExecutionDeadlineTarget(
          taskName: existing.taskName,
          planVersionId: existing.planVersionId,
          planRevision: existing.planRevision + 1,
          plannedStartUtc: existing.plannedStartUtc,
          plannedEndUtc: newEndUtc,
          isDone: existing.isDone,
        );
        return true;
      },
      openTask: (conversationId, taskId) async {
        opened.add(key(conversationId, taskId));
      },
      isAppVisible: () => visible,
      autoTick: false,
      deliveryRetryInterval: Duration.zero,
    );
    await controller.load();
  }

  Future<void> start({
    String conversationId = 'conv-1',
    String taskId = 'task-a',
    String name = '前端页面开发',
    bool expectOk = true,
  }) async {
    final result = await timer.start(taskRef(
      conversationId: conversationId,
      taskId: taskId,
      name: name,
    ));
    if (expectOk) {
      expect(result.ok, isTrue, reason: result.message);
    }
    await controller.tick();
  }

  Future<void> tick() => controller.tick();

  int recordedSecondsFor(String taskId) {
    var seconds = 0;
    for (final record in timer.ledger.recordsForTask(taskId)) {
      for (final interval in record.intervals) {
        seconds += interval.duration.inSeconds;
      }
    }
    return seconds;
  }

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
    await timer.shutdown();
    timer.dispose();
  }
}

// ---------------------------------------------------------------- 时间锚点

DateTime wall(int hour, int minute) => shanghaiUtc(2026, 11, 4, hour, minute);

final DateTime startAt = wall(14, 0);
final DateTime deadlineAt = wall(16, 0);
final DateTime secondAt = wall(16, 5);
final DateTime autoAt = wall(16, 10);

void main() {
  Directory newDir(String label) => newTempDir('deadline_$label');

  Future<_Harness> harness({
    Directory? directory,
    bool memory = true,
    String label = 'h',
    DateTime? clockStart,
    FakeEffortClock? clock,
    _FakeNotifications? notifications,
    bool visible = true,
    bool acceptNative = true,
  }) async {
    final notificationsPort =
        notifications ?? _FakeNotifications(accept: acceptNative);
    final dir = directory ?? newDir(label);
    final effectiveClock = clock ?? FakeEffortClock(startUtc: clockStart ?? startAt);
    final h = await _Harness.create(
      directory: dir,
      clock: effectiveClock,
      memory: memory && directory == null,
      notifications: notificationsPort,
    );
    h.visible = visible;
    return h;
  }

  Future<void> settleAsync() async {
    // 让监听器里 unawaited 的异步链路（创建会话/投递/取消）跑到收敛。
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('正常时间线', () {
    test('14:00 开始→16:00 待处理→16:05 二次提醒→16:10 自动完成，等待不计工时', () async {
      final h = await harness(label: 'timeline');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      // 开始：先创建执行记录再通知一次“已开始”。
      expect(h.notifications.ofKind('started'), hasLength(1));
      expect(h.notifications.ofKind('started').single.title, '前端页面开发 已开始');
      expect(h.notifications.ofKind('started').single.body, '计划时段 14:00–16:00');
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);
      expect(h.session!.deadlineUtc, deadlineAt);

      // 15:59:59：仍在执行，没有任何到期提醒。
      h.clock.advance(const Duration(hours: 1, minutes: 59, seconds: 59));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);
      expect(h.notifications.ofKind('deadline'), isEmpty);
      expect(h.timer.isRunning, isTrue);

      // 16:00：结算到截止点，进入待处理，第一次提醒，依赖未释放。
      h.clock.advance(const Duration(seconds: 1));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.timer.hasActive, isFalse, reason: '到点先结算本次执行区间');
      expect(h.notifications.ofKind('deadline'), hasLength(1));
      expect(h.notifications.ofKind('deadline').single.title,
          '前端页面开发 · 计划时段已结束');
      expect(h.notifications.ofKind('deadline').single.body, contains('待处理'));
      expect(h.completionCalls, 0, reason: '待处理不释放依赖');
      expect(h.recordedSecondsFor('task-a'), 2 * 60 * 60,
          reason: '14:00–16:00 共 120 分钟');

      // 16:04:59：还没有第二次提醒。
      h.clock.advance(const Duration(minutes: 4, seconds: 59));
      await h.tick();
      expect(h.notifications.ofKind('second'), isEmpty);
      expect(h.session!.stage, ExecutionDeadlineStage.pending);

      // 16:05：第二次提醒，正文注明 16:10 前选择。
      h.clock.advance(const Duration(seconds: 1));
      await h.tick();
      expect(h.notifications.ofKind('second'), hasLength(1));
      expect(h.notifications.ofKind('second').single.body,
          contains('请在 16:10 前选择，届时将自动完成'));
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);
      expect(h.session!.responseWindowEndsAtUtc, autoAt);
      expect(h.completionCalls, 0);

      // 16:09:59：响应窗口内，不自动完成。
      h.clock.advance(const Duration(minutes: 4, seconds: 59));
      await h.tick();
      expect(h.completionCalls, 0);

      // 16:10：自动完成一次，且等待的 10 分钟不计工时。
      h.clock.advance(const Duration(seconds: 1));
      await h.tick();
      expect(h.completionCalls, 1);
      expect(h.lastCompletionSource, 'auto');
      expect(h.lastCompletionAt, autoAt);
      expect(h.lastSession!.stage, ExecutionDeadlineStage.completed);
      expect(h.recordedSecondsFor('task-a'), 2 * 60 * 60,
          reason: '16:00–16:10 等待不计入实际耗时');

      // 再 tick 不会重复提交完成。
      await h.tick();
      expect(h.completionCalls, 1);
    });

    test('16:03 手动结束：不再发第二次提醒，也不在 16:10 自动完成', () async {
      final h = await harness(label: 'early_finish');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(hours: 2, minutes: 3));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.notifications.ofKind('deadline'), hasLength(1));

      final finished = await h.controller.finishSession(h.session!.executionId);
      expect(finished.ok, isTrue);
      expect(finished.completed, isTrue);
      expect(h.completionCalls, 1);
      expect(h.lastCompletionSource, 'manual');

      // 16:10 不会再有自动完成，也不会再发第二次提醒。
      h.clock.advance(const Duration(minutes: 7));
      await h.tick();
      expect(h.notifications.ofKind('second'), isEmpty);
      expect(h.completionCalls, 1);
      expect(h.lastSession!.stage, ExecutionDeadlineStage.completed);
    });

    test('暂停 15 分钟继续：暂停不计时，截止保留', () async {
      final h = await harness(label: 'pause');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(minutes: 10));
      await h.tick();
      expect(h.timer.elapsed, const Duration(minutes: 10));
      await h.timer.pause();

      h.clock.advance(const Duration(minutes: 15));
      await h.tick();
      expect(h.session!.deadlineUtc, deadlineAt, reason: '暂停仍保留有效截止');
      expect(h.timer.elapsed, const Duration(minutes: 10));

      await h.timer.resume();
      h.clock.advance(const Duration(minutes: 95));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.recordedSecondsFor('task-a'), (10 + 95) * 60);
    });

    test('只停止计时：撤销未到期提醒，任务不完成', () async {
      final h = await harness(label: 'stop_only');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(minutes: 30));
      await h.timer.stopAndConfirm();
      await settleAsync();
      await h.tick();
      expect(h.lastSession!.stage, ExecutionDeadlineStage.cancelled);
      expect(h.lastSession!.completionSource, isNull);

      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      expect(h.notifications.ofKind('deadline'), isEmpty);
      expect(h.completionCalls, 0);
    });

    test('重复开始：同一执行只通知一次，不重复创建会话', () async {
      final h = await harness(label: 'duplicate_start');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      final again = await h.timer.start(taskRef(name: '前端页面开发'));
      expect(again.ok, isFalse);
      await h.tick();
      expect(h.notifications.ofKind('started'), hasLength(1));
      expect(h.controller.activeSessions, hasLength(1));
    });

    test('没有具体截止（只有日期/无排程）：不猜午夜、不安排提醒', () async {
      final h = await harness(label: 'no_deadline');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: null);
      await h.attach();
      await h.start();

      expect(h.session!.hasDeadline, isFalse);
      h.clock.advance(const Duration(days: 1));
      await h.tick();
      expect(h.notifications.ofKind('deadline'), isEmpty);
      expect(h.completionCalls, 0);
    });
  });

  group('延长', () {
    test('16:07 延长到 16:30：16:10 不自动完成，按新截止重新两次提醒', () async {
      final h = await harness(label: 'extend');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);

      h.clock.advance(const Duration(minutes: 7));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);
      expect(h.notifications.ofKind('second'), hasLength(1));

      // 预览显示当前/新截止与潜在重叠。
      final preview = await h.controller.previewExtension(
        h.session!.executionId,
        wall(16, 30),
      );
      expect(preview.currentDeadlineUtc, deadlineAt);
      expect(preview.newDeadlineUtc, wall(16, 30));
      expect(preview.conflicts, isNotEmpty);

      final revision = h.session!.revision;
      final extended = await h.controller.confirmExtension(
        h.session!.executionId,
        wall(16, 30),
        expectedRevision: revision,
      );
      expect(extended.ok, isTrue, reason: extended.message);
      expect(h.extensionApplyCalls, 1);
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);
      expect(h.session!.deadlineUtc, wall(16, 30));
      expect(h.notifications.ofKind('started'), hasLength(1),
          reason: '延长恢复计时不重发“已开始”');
      expect(h.timer.isRunning, isTrue, reason: '从确认时刻恢复计时');

      // 16:10 不自动完成。
      h.clock.advance(const Duration(minutes: 3));
      await h.tick();
      expect(h.completionCalls, 0);
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);

      // 新截止 16:30：重新走第一次提醒。
      h.clock.advance(const Duration(minutes: 20));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.notifications.ofKind('deadline'), hasLength(2));
      expect(h.completionCalls, 0);

      // 16:35 第二次提醒，16:40 自动完成。
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.notifications.ofKind('second'), hasLength(2));
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.completionCalls, 1);
      expect(h.lastCompletionSource, 'auto');

      // 14:00–16:00 + 16:07–16:30 = 143 分钟。
      expect(h.recordedSecondsFor('task-a'), 143 * 60);
    });

    test('延长保存失败：保留待处理状态可重试，不移动其它任务', () async {
      final h = await harness(label: 'extend_fail');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.tick();

      h.allowExtension = false;
      final revision = h.session!.revision;
      final failed = await h.controller.confirmExtension(
        h.session!.executionId,
        wall(16, 30),
        expectedRevision: revision,
      );
      expect(failed.ok, isFalse);
      expect(h.session!.stage, ExecutionDeadlineStage.pending,
          reason: '提交失败保留原状态');
      expect(h.session!.deadlineUtc, deadlineAt);

      // 重试成功。
      h.allowExtension = true;
      final retried = await h.controller.confirmExtension(
        h.session!.executionId,
        wall(16, 30),
        expectedRevision: h.session!.revision,
      );
      expect(retried.ok, isTrue);
    });

    test('旧通知点击无副作用：期限已变化的动作被忽略', () async {
      final h = await harness(label: 'stale_action');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.tick();

      final oldToken =
          '${h.notifications.ofKind('deadline').single.payload['deadline']}';
      final executionId = h.session!.executionId;
      expect(executionId, isNotEmpty);

      // 延长后旧期限作废。
      final revision = h.session!.revision;
      await h.controller.confirmExtension(
        h.session!.executionId,
        wall(16, 30),
        expectedRevision: revision,
      );

      h.notifications.queueAction(
        action: 'finish',
        taskId: 'task-a',
        executionId: executionId,
        deadline: oldToken,
      );
      await h.tick();
      expect(h.completionCalls, 0, reason: '旧通知不能作用到新期限');
      expect(h.session!.stage, ExecutionDeadlineStage.scheduled);
    });
  });

  group('通知降级与恢复', () {
    test('系统拒绝且应用不可见：保持待处理；恢复可见后补发并留满 5 分钟', () async {
      final h = await harness(
        label: 'invisible',
        visible: false,
        acceptNative: false,
      );
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.session!.firstDelivered, isFalse,
          reason: '未成功投递且不可见 → 不能记投递');
      expect(h.completionCalls, 0);

      // 16:10 仍未投递，不允许自动完成。
      h.clock.advance(const Duration(minutes: 10));
      await h.tick();
      expect(h.completionCalls, 0);
      expect(h.notifications.ofKind('second'), isEmpty);

      // 恢复可见：先补发第一次提醒（前台等价操作），响应窗口从显示起算。
      h.visible = true;
      await h.tick();
      expect(h.controller.foregroundPendingFor(h.session!.executionId), isTrue);
      await h.controller.ackForegroundDelivery(h.session!.executionId);
      expect(h.session!.firstDelivered, isTrue);
      expect(h.session!.firstDeliveryChannel, 'foreground');
      final firstAt = h.session!.firstDeliveredAtUtc!;

      // 补发后满 5 分钟才第二次提醒。
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.controller.foregroundPendingFor(h.session!.executionId), isTrue);
      await h.controller.ackForegroundDelivery(h.session!.executionId);
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);
      expect(
        h.session!.responseWindowEndsAtUtc,
        h.session!.secondDeliveredAtUtc!.add(const Duration(minutes: 5)),
      );
      expect(
        h.session!.secondDeliveredAtUtc!.difference(firstAt),
        greaterThanOrEqualTo(const Duration(minutes: 5)),
      );

      // 窗口过后补做一次完成。
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.completionCalls, 1);
      expect(h.lastCompletionSource, 'auto');
    });

    test('系统拒绝但应用可见：前台等价操作确认后才开始响应窗口', () async {
      final h = await harness(
        label: 'foreground',
        visible: true,
        acceptNative: false,
      );
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();

      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.pending);
      expect(h.session!.firstDelivered, isFalse);

      // 6 分钟后仍未确认显示：第二次提醒不能提前。
      h.clock.advance(const Duration(minutes: 6));
      await h.tick();
      expect(h.notifications.ofKind('second'), isEmpty);
      expect(h.session!.stage, ExecutionDeadlineStage.pending);

      await h.controller.ackForegroundDelivery(h.session!.executionId);
      expect(h.session!.firstDelivered, isTrue);
      final ackAt = h.session!.firstDeliveredAtUtc!;
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      await h.controller.ackForegroundDelivery(h.session!.executionId);
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);
      expect(h.session!.responseWindowEndsAtUtc,
          h.session!.secondDeliveredAtUtc!.add(const Duration(minutes: 5)));
      expect(h.session!.firstDeliveredAtUtc, ackAt);
    });

    test('重启恢复（二次提醒未送达）：补发并留满 5 分钟', () async {
      final dir = newDir('restart_second');
      final clock = FakeEffortClock(startUtc: startAt);
      final h1 = await harness(directory: dir, clock: clock);
      h1.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h1.attach();
      await h1.start();
      h1.clock.advance(const Duration(hours: 2));
      await h1.tick();
      expect(h1.notifications.ofKind('deadline'), hasLength(1));
      expect(h1.session!.firstDelivered, isTrue);

      // 模拟完全退出：截止记录已落盘，第二次提醒还没投递。
      await h1.close();

      // 16:06 重启：第二次提醒补发，响应窗口从 16:06 起算（不是 16:10）。
      clock.advance(const Duration(minutes: 6));
      final h2 = await harness(directory: dir, clock: clock);
      expect(h2.clock.nowUtc, wall(16, 6));
      h2.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h2.attach();
      expect(h2.notifications.ofKind('second'), hasLength(1));
      expect(h2.session!.responseWindowEndsAtUtc, wall(16, 11));

      h2.clock.advance(const Duration(minutes: 4, seconds: 59));
      await h2.tick();
      expect(h2.completionCalls, 0);
      h2.clock.advance(const Duration(seconds: 1));
      await h2.tick();
      expect(h2.completionCalls, 1);
      expect(h2.lastCompletionSource, 'auto');
      await h2.close();
      deleteDirQuietly(dir);
    });

    test('重启恢复（二次提醒已送达且响应期已过）：补做一次完成', () async {
      final dir = newDir('restart_complete');
      final clock = FakeEffortClock(startUtc: startAt);
      final h1 = await harness(directory: dir, clock: clock);
      h1.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h1.attach();
      await h1.start();
      h1.clock.advance(const Duration(hours: 2));
      await h1.tick();
      expect(h1.session!.stage, ExecutionDeadlineStage.pending);
      h1.clock.advance(const Duration(minutes: 5));
      await h1.tick();
      expect(h1.session!.stage, ExecutionDeadlineStage.secondReminder);
      expect(h1.session!.responseWindowEndsAtUtc, autoAt);
      await h1.close();

      // 16:30 重启：响应期已过，补做一次完成。
      clock.advance(const Duration(minutes: 25));
      final h2 = await harness(directory: dir, clock: clock);
      expect(h2.clock.nowUtc, wall(16, 30));
      h2.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h2.attach();
      expect(h2.completionCalls, 1);
      expect(h2.lastCompletionSource, 'auto');
      expect(h2.lastCompletionAt, autoAt, reason: '完成事实时间仍是响应窗口结束时刻');
      // 再 tick 不重复完成。
      await h2.tick();
      expect(h2.completionCalls, 1);
      await h2.close();
      deleteDirQuietly(dir);
    });

    test('延长确认与自动完成竞态：只能有一个有效', () async {
      final h = await harness(label: 'race');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.session!.stage, ExecutionDeadlineStage.secondReminder);

      // 16:10 同时发生：先启动自动完成轮询，再提交延长确认。
      h.clock.advance(const Duration(minutes: 5));
      final revision = h.session!.revision;
      final tickFuture = h.controller.tick();
      final extended = await h.controller.confirmExtension(
        h.session!.executionId,
        wall(16, 30),
        expectedRevision: revision,
      );
      await tickFuture;

      expect(extended.ok, isFalse, reason: '自动完成占位时延长必须被拒绝');
      expect(h.extensionApplyCalls, 0);
      expect(h.completionCalls, 1);
      expect(h.lastSession!.stage, ExecutionDeadlineStage.completed);
    });
  });

  group('身份与收敛', () {
    test('两个会话同名任务：动作身份不串任务，完成只释放对应任务', () async {
      final h = await harness(label: 'same_name');
      addTearDown(h.close);
      h.setTarget(
        conversationId: 'conv-1',
        taskId: 'task-a',
        name: '前端页面开发',
        startUtc: startAt,
        endUtc: deadlineAt,
      );
      h.setTarget(
        conversationId: 'conv-2',
        taskId: 'task-b',
        name: '前端页面开发',
        startUtc: startAt,
        endUtc: deadlineAt,
      );
      await h.attach();
      await h.start(conversationId: 'conv-1', taskId: 'task-a');
      h.clock.advance(const Duration(minutes: 5));
      await h.start(conversationId: 'conv-2', taskId: 'task-b');
      expect(h.notifications.ofKind('started'), hasLength(2));

      h.clock.advance(const Duration(minutes: 115));
      await h.tick();
      final sessions = h.controller.activeSessions;
      expect(sessions, hasLength(2));
      final first = sessions.firstWhere((s) => s.conversationId == 'conv-1');
      final second = sessions.firstWhere((s) => s.conversationId == 'conv-2');
      expect(first.stage, ExecutionDeadlineStage.pending);
      expect(second.stage, ExecutionDeadlineStage.pending);

      // 只结束 conv-1 的那次执行（投递时写入的身份令牌原样回传）。
      final token =
          '${first.deadlineVersion}:${first.deadlineUtc!.millisecondsSinceEpoch}';
      h.notifications.queueAction(
        action: 'finish',
        taskId: first.taskId,
        executionId: first.executionId,
        deadline: token,
      );
      await h.tick();
      expect(h.completionCalls, 1);
      expect(h.targetFor('conv-1', 'task-a')!.isDone, isTrue);
      expect(h.targetFor('conv-2', 'task-b')!.isDone, isFalse,
          reason: '同名任务不能被旧提醒误完成');
      expect(
        h.controller.sessionById(second.executionId)!.isActive,
        isTrue,
      );

      // conv-2 之后仍按自己的截止自动完成。
      h.clock.advance(const Duration(minutes: 10));
      await h.tick();
      expect(h.completionCalls, 1, reason: '第二次提醒已发出，尚未到自动完成');
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.completionCalls, 2);
      expect(h.targetFor('conv-2', 'task-b')!.isDone, isTrue);
    });

    test('已送达通知重放：操作被忽略，不重复释放依赖', () async {
      final h = await harness(label: 'replay');
      addTearDown(h.close);
      h.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h.attach();
      await h.start();
      h.clock.advance(const Duration(hours: 2));
      await h.tick();
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      h.clock.advance(const Duration(minutes: 5));
      await h.tick();
      expect(h.completionCalls, 1);
      final completedSession = h.lastSession!;
      final executionId = completedSession.executionId;
      final token =
          '${completedSession.deadlineVersion}:${deadlineAt.millisecondsSinceEpoch}';

      h.notifications.queueAction(
        action: 'finish',
        taskId: 'task-a',
        executionId: executionId,
        deadline: token,
      );
      await h.tick();
      expect(h.completionCalls, 1, reason: '已完成的旧通知重放无副作用');
    });
  });

  group('到期自动完成来源（回顾徽标数据）', () {
    test('自动完成的任务进入集合；手动结束与旧数据不误报', () async {
      // 1) 到期自动完成 → 进入集合。
      final auto = await harness(label: 'auto_source');
      addTearDown(auto.close);
      auto.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await auto.attach();
      await auto.start();
      auto.clock.advance(const Duration(hours: 2));
      await auto.tick();
      auto.clock.advance(const Duration(minutes: 5));
      await auto.tick();
      auto.clock.advance(const Duration(minutes: 5));
      await auto.tick();
      expect(auto.lastSession!.completionSource, 'auto');
      expect(auto.controller.autoCompletedTaskIds, contains('task-a'));

      // 2) 手动结束 → 不进集合。
      final manual = await harness(label: 'manual_source');
      addTearDown(manual.close);
      manual.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await manual.attach();
      await manual.start();
      manual.clock.advance(const Duration(hours: 2, minutes: 3));
      await manual.tick();
      await manual.controller.finishSession(manual.session!.executionId);
      expect(manual.lastSession!.completionSource, 'manual');
      expect(manual.controller.autoCompletedTaskIds, isEmpty);

      // 3) 旧数据（无 completionSource 字段）视为 manual，不误报。
      final legacyDir = newDir('legacy_source');
      final legacyClock = FakeEffortClock(startUtc: startAt);
      final legacyFixture =
          await TimerFixture.create(directory: legacyDir, clock: legacyClock);
      final legacyStore = ExecutionDeadlineStore(legacyFixture.store);
      await legacyStore.save(<ExecutionDeadlineSession>[
        ExecutionDeadlineSession(
          executionId: 'legacy-exec',
          conversationId: 'conv-1',
          taskId: 'task-legacy',
          taskName: '历史任务',
          stage: ExecutionDeadlineStage.completed,
          startedAtUtc: startAt,
          revision: 1,
          completedAtUtc: deadlineAt,
          // completionSource 缺失 → manual 语义。
        ),
      ]);
      final legacyNotifications = _FakeNotifications();
      final reloaded = ExecutionDeadlineController(
        timer: legacyFixture.timer,
        store: legacyStore,
        clock: legacyClock,
        localTime: shanghaiLocalTime,
        notifications: legacyNotifications,
        resolveTarget: (conversationId, taskId) async =>
            targetOf(name: taskId, endUtc: deadlineAt),
        taskRefFor: (conversationId, taskId) async =>
            taskRef(taskId: taskId),
        completeTask: (conversationId, taskId, atUtc, source) async =>
            const ExecutionCompletionOutcome(ok: true, message: '已完成'),
        previewExtensionFor: (conversationId, taskId, newEndUtc) async =>
            ExecutionExtensionPreview(
                currentDeadlineUtc: deadlineAt, newDeadlineUtc: newEndUtc),
        applyExtensionFor: (conversationId, taskId, newEndUtc) async => true,
        openTask: (conversationId, taskId) async {},
        isAppVisible: () => false,
        autoTick: false,
      );
      await reloaded.load();
      expect(reloaded.autoCompletedTaskIds, isEmpty,
          reason: '旧数据缺失 completionSource 时视为 manual');
      reloaded.dispose();
      await legacyFixture.timer.shutdown();
      legacyFixture.timer.dispose();
      deleteDirQuietly(legacyDir);
    });

    test('重启后仍能从持久化记录识别到期自动完成', () async {
      final dir = newDir('source_restart');
      final clock = FakeEffortClock(startUtc: startAt);
      final h1 = await harness(directory: dir, clock: clock);
      h1.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h1.attach();
      await h1.start();
      h1.clock.advance(const Duration(hours: 2));
      await h1.tick();
      h1.clock.advance(const Duration(minutes: 5));
      await h1.tick();
      h1.clock.advance(const Duration(minutes: 5));
      await h1.tick();
      expect(h1.lastSession!.completionSource, 'auto');
      await h1.close();

      clock.advance(const Duration(minutes: 10));
      final h2 = await harness(directory: dir, clock: clock);
      h2.setTarget(startUtc: startAt, endUtc: deadlineAt);
      await h2.attach();
      expect(h2.controller.autoCompletedTaskIds, contains('task-a'));
      await h2.close();
      deleteDirQuietly(dir);
    });
  });
}
