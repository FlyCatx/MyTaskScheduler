// 任务 13 的 AppController 接线测试（真实完成/依赖入口 + 甘特期限写回）。
//
// 覆盖：
//   * 有效截止 = 当前生效甘特任务最后一段结束时刻（多段取最晚 end；无排程为 null，
//     不猜午夜）；
//   * “目标=已完成”命令幂等：重复提交只记录一次完成事件，不写实际耗时；
//   * 延长只改本任务最后一段的结束时刻，不移动其它任务、不改编预估。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_controller.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_deadline_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_notification.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/timer_controller.dart';

import '../execution/fake_effort_clock.dart';
import '../execution/execution_test_support.dart';
import '../support/test_support.dart';

class _NoopNotifications implements ExecutionNotificationPort {
  const _NoopNotifications();

  @override
  bool get supported => false;

  @override
  ExecutionNotificationPreparation prepare() =>
      ExecutionNotificationPreparation.unsupported;

  @override
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) =>
      ExecutionNotificationAttempt.unavailable;

  @override
  String? takeActionJson() => null;
}

const int _offset = 480;

CalendarSettings _settings() => CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-04',
      planningDays: 7,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(8 * 60, 20 * 60)],
      }),
      snapMinutes: 15,
      chunkMinutes: 120,
    );

Future<void> main() async {
  late Directory dir;
  late InMemorySessionRepository store;
  late ExecutionStore execution;
  late TimerController timer;
  late FakeEffortClock clock;
  late AppController controller;

  DateTime wall(int hour, int minute) =>
      DateTime.utc(2026, 11, 4, hour, minute)
          .subtract(const Duration(minutes: _offset));

  Future<void> saveSegments(List<ScheduleSegment> segments) async {
    final version = controller.viewVersion!;
    final ok = await controller.applyCalendarEdit(CalendarEditOutcome(
      schedule: version.calendar.copyWith(
        settings: _settings(),
        segments: segments,
      ),
      tasks: version.tasks,
      label: '测试排程',
    ));
    expect(ok, isTrue, reason: controller.errorMessage);
  }

  setUp(() async {
    dir = createTempDataDir('deadline-wiring');
    store = InMemorySessionRepository();
    await seedConversation(store);
    execution = ExecutionStore(dir);
    final opened = await execution.open();
    expect(opened.readOnly, isFalse, reason: opened.notice);
    clock = FakeEffortClock(startUtc: wall(14, 0));
    timer = TimerController(store: execution, clock: clock, autoTick: false);
    await timer.load();
    controller = AppController(
      engine: FakeScheduleEngine(),
      store: store,
      timer: timer,
      dataDirectory: dir,
    );
    await controller.initialize();
    await controller.openConversation('conv-seed');
  });

  tearDown(() async {
    controller.dispose();
    await execution.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('有效截止取甘特最后一段结束；无排程为 null（不猜午夜）', () async {
    await saveSegments([
      ScheduleSegment(
        id: 's1',
        taskId: 'task-a',
        start: wall(14, 0),
        end: wall(15, 0),
        source: SegmentSource.auto,
      ),
      ScheduleSegment(
        id: 's2',
        taskId: 'task-a',
        start: wall(15, 30),
        end: wall(16, 0),
        source: SegmentSource.manual,
      ),
      ScheduleSegment(
        id: 's3',
        taskId: 'task-b',
        start: wall(14, 0),
        end: wall(14, 30),
        source: SegmentSource.auto,
      ),
    ]);

    final target =
        await controller.executionDeadlineTargetFor('conv-seed', 'task-a');
    expect(target, isNotNull);
    expect(target!.plannedStartUtc, wall(14, 0));
    expect(target.plannedEndUtc, wall(16, 0),
        reason: '取最后一段结束，而不是第一段或估算时长');
    expect(controller.executionDeadlineForTask('task-a'), wall(16, 0));

    // task-c 没有排程：没有具体时刻，绝不猜测午夜。
    final noSchedule =
        await controller.executionDeadlineTargetFor('conv-seed', 'task-c');
    expect(noSchedule, isNotNull);
    expect(noSchedule!.plannedEndUtc, isNull);
    expect(controller.executionDeadlineForTask('task-c'), isNull);

    expect(
        await controller.executionDeadlineTargetFor('conv-seed', 'no-such'),
        isNull);
  });

  test('完成命令幂等：重复提交只记录一次完成事件，不写实际耗时', () async {
    final at = wall(16, 10);
    final first = await controller.completeTaskFromExecution(
        'conv-seed', 'task-a', at, 'auto');
    expect(first.ok, isTrue, reason: first.message);
    expect(first.alreadyDone, isFalse);

    final version = controller.viewVersion!;
    expect(
      version.tasks.firstWhere((t) => t.id == 'task-a').completion,
      Completion.done,
    );
    final events = execution.ledger.completionEvents;
    expect(events, hasLength(1));
    expect(events.single.taskId, 'task-a');
    expect(events.single.completedAtUtc, at,
        reason: '完成时间取完成事实时间，不是重试读取时间');
    expect(execution.ledger.records, isEmpty,
        reason: '完成不会凭空写实际耗时');

    // 重复提交（双击/旧通知重放）：仍成功，但不再释放依赖、不再记录事件。
    final second = await controller.completeTaskFromExecution(
        'conv-seed', 'task-a', at.add(const Duration(minutes: 1)), 'auto');
    expect(second.ok, isTrue);
    expect(second.alreadyDone, isTrue);
    expect(execution.ledger.completionEvents, hasLength(1));
  });

  test('延长只改本任务最后一段结束：不移动其它任务、不改编预估', () async {
    await saveSegments([
      ScheduleSegment(
        id: 's1',
        taskId: 'task-a',
        start: wall(14, 0),
        end: wall(15, 0),
        source: SegmentSource.auto,
      ),
      ScheduleSegment(
        id: 's2',
        taskId: 'task-a',
        start: wall(15, 30),
        end: wall(16, 0),
        source: SegmentSource.auto,
      ),
      ScheduleSegment(
        id: 's3',
        taskId: 'task-b',
        start: wall(14, 0),
        end: wall(14, 30),
        source: SegmentSource.auto,
      ),
    ]);
    final before = controller.viewVersion!;
    final target = await controller.previewExecutionExtension(
        'conv-seed', 'task-a', wall(16, 30));
    expect(target.error, isNull);
    expect(target.currentDeadlineUtc, wall(16, 0));
    expect(target.newDeadlineUtc, wall(16, 30));

    final ok = await controller.applyExecutionExtension(
        'conv-seed', 'task-a', wall(16, 30));
    expect(ok, isTrue, reason: controller.errorMessage);

    final after = controller.viewVersion!;
    expect(after.calendar.segments, hasLength(3), reason: '不新增/删除片段');
    final s1 = after.calendar.segmentById('s1')!;
    final s2 = after.calendar.segmentById('s2')!;
    final s3 = after.calendar.segmentById('s3')!;
    expect(s1.end, wall(15, 0), reason: '非最后一段不动');
    expect(s2.end, wall(16, 30), reason: '最后一段结束时刻写入新截止');
    expect(s3.start, wall(14, 0), reason: '不移动其它任务');
    expect(s3.end, wall(14, 30));
    expect(
      after.tasks.firstWhere((t) => t.id == 'task-a').estimatedHours,
      before.tasks.firstWhere((t) => t.id == 'task-a').estimatedHours,
      reason: '延长时间不改编预估工时',
    );

    final targetAfter =
        await controller.executionDeadlineTargetFor('conv-seed', 'task-a');
    expect(targetAfter!.plannedEndUtc, wall(16, 30));
  });

  test('AppController 暴露“到期自动完成”任务 id（读取持久化来源，手动/旧数据不误报）',
      () async {
    final deadlineStore = ExecutionDeadlineStore(execution);
    await deadlineStore.save(<ExecutionDeadlineSession>[
      ExecutionDeadlineSession(
        executionId: 'exec-auto',
        conversationId: 'conv-seed',
        taskId: 'task-b',
        taskName: '实现 ListInit',
        stage: ExecutionDeadlineStage.completed,
        startedAtUtc: wall(14, 0),
        revision: 1,
        completedAtUtc: wall(16, 10),
        completionSource: 'auto',
      ),
      // 手动结束：不进集合。
      ExecutionDeadlineSession(
        executionId: 'exec-manual',
        conversationId: 'conv-seed',
        taskId: 'task-a',
        taskName: '整理实验要求',
        stage: ExecutionDeadlineStage.completed,
        startedAtUtc: wall(14, 0),
        revision: 1,
        completedAtUtc: wall(15, 0),
        completionSource: 'manual',
      ),
      // 旧数据（没有 completionSource）：不误报。
      ExecutionDeadlineSession(
        executionId: 'exec-legacy',
        conversationId: 'conv-seed',
        taskId: 'task-c',
        taskName: '阅读实验材料',
        stage: ExecutionDeadlineStage.completed,
        startedAtUtc: wall(14, 0),
        revision: 1,
        completedAtUtc: wall(15, 0),
      ),
    ]);
    final deadline = ExecutionDeadlineController(
      timer: timer,
      store: deadlineStore,
      clock: clock,
      localTime: shanghaiLocalTime,
      notifications: const _NoopNotifications(),
      resolveTarget: controller.executionDeadlineTargetFor,
      taskRefFor: controller.executionTaskRefIn,
      completeTask: controller.completeTaskFromExecution,
      previewExtensionFor: controller.previewExecutionExtension,
      applyExtensionFor: controller.applyExecutionExtension,
      openTask: controller.openExecutionTask,
      isAppVisible: () => false,
      autoTick: false,
    );
    controller.attachExecutionDeadline(deadline);
    await deadline.load();

    expect(controller.executionAutoCompletedTaskIds, {'task-b'});
    expect(controller.executionAutoCompletedTaskIds, isNot(contains('task-a')));
    expect(controller.executionAutoCompletedTaskIds, isNot(contains('task-c')));
    expect(
      () => controller.executionAutoCompletedTaskIds.add('x'),
      throwsUnsupportedError,
      reason: '只读集合',
    );
  });
}
