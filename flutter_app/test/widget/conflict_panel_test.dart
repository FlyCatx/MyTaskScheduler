// 冲突详情/建议面板的 widget 测试（R1-C）。
//
// 覆盖：
//  * 甘特图冲突条每行可打开详情对话框（解释：类型/来源/区间/任务/剩余需求/可用容量）
//  * `定位` 复用甘特图的定位机制（选中任务并滚动时间轴，不改变数据）
//  * 建议的预览（调整前后/受影响任务/截止风险/新增冲突）与提交
//    （提交走 CalendarActions.commit = 生产环境的 AppController.applyCalendarEdit）
//  * 预览期间数据变化 → 重新计算并让用户重新确认，不用过期建议覆盖新数据
//  * 无可行建议时明确说明原因，保留“允许带冲突保存”
//  * 跨周片段也能定位到正确日期

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/conflict_suggestions.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_gantt.dart';
import 'package:taskscheduler_flutter/src/ui/conflict_panel.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

const int _offset = 480;

DateTime at(String wall) {
  final parts = wall.split(' ');
  final date = parts[0].split('-').map(int.parse).toList();
  final time =
      parts.length > 1 ? parts[1].split(':').map(int.parse).toList() : [0, 0];
  return DateTime.utc(date[0], date[1], date[2], time[0], time[1])
      .subtract(const Duration(minutes: _offset));
}

CalendarSettings settings({
  int days = 7,
  List<CalendarOccupancy> occupancies = const [],
}) =>
    CalendarSettings(
      timezoneOffsetMinutes: _offset,
      planningStartDate: '2026-11-18',
      planningDays: days,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++)
          d: const [WallClockRange(8 * 60, 13 * 60)],
      }),
      occupancies: occupancies,
      snapMinutes: 15,
      chunkMinutes: 120,
    );

LocalPlan conflictPlan() => const LocalPlan(
      summary: '冲突测试',
      tasks: [
        TaskRecord(id: 't1', name: '写报告', estimatedHours: 2),
        TaskRecord(id: 't2', name: '做实验', estimatedHours: 2),
      ],
    );

List<SchedulingTask> schedulingTasks(List<TaskRecord> records) => <SchedulingTask>[
      for (final t in records)
        SchedulingTask(
          id: t.id,
          name: t.name,
          estimatedHours: t.estimatedHours,
          dependsOn: t.dependsOn,
          deadline: t.deadline,
        ),
    ];

CalendarSchedule overlapSchedule({
  SegmentSource source = SegmentSource.auto,
  int days = 7,
}) =>
    CalendarSchedule(
      settings: settings(days: days),
      segments: [
        ScheduleSegment(
          id: 's1',
          taskId: 't1',
          start: at('2026-11-18 08:00'),
          end: at('2026-11-18 09:00'),
          source: source,
        ),
        ScheduleSegment(
          id: 's2',
          taskId: 't2',
          start: at('2026-11-18 08:30'),
          end: at('2026-11-18 09:30'),
          source: source,
        ),
      ],
    );

ConflictSnapshot snapshotOf(
  CalendarSchedule schedule,
  List<TaskRecord> tasks, {
  int planRevision = 3,
  int timetableRevision = -1,
  Map<String, String>? taskNames,
}) {
  final scheduling = schedulingTasks(tasks);
  return ConflictSnapshot(
    schedule: schedule,
    tasks: scheduling,
    now: at('2026-11-18 07:00'),
    taskNames: taskNames ?? {for (final t in scheduling) t.id: t.name},
    stamp: ConflictVersionStamp(
      planRevision: planRevision,
      timetableRevision: timetableRevision,
      scheduleSignature: calendarScheduleSignature(schedule),
    ),
  );
}

ConflictDetail detailOfKind(
  CalendarSchedule schedule,
  List<SchedulingTask> tasks,
  ConflictKind kind,
) {
  final details = explainConflicts(
    schedule: schedule,
    tasks: tasks,
    now: at('2026-11-18 07:00'),
    taskNames: {for (final t in tasks) t.id: t.name},
  );
  return details.firstWhere((d) => d.conflict.kind == kind);
}

class Recorded {
  final List<CalendarEditOutcome> commits = <CalendarEditOutcome>[];
}

CalendarActions ganttActions(Recorded record, {bool canEdit = true}) =>
    CalendarActions(
      canEdit: canEdit,
      commit: (outcome) async {
        record.commits.add(outcome);
        return true;
      },
      autoSchedule: ({required bool keepManual}) async => null,
      applySettings: (settings, {required bool reschedule}) async => true,
      ensureReady: () async => null,
      taskNames: const {'t1': '写报告', 't2': '做实验'},
    );

/// 直接 pump 一个能打开冲突详情对话框的宿主（用于不依赖甘特图的场景）。
Future<void> pumpDetailsDialogHost(
  WidgetTester tester, {
  required ConflictDetail detail,
  required ConflictSnapshot snapshot,
  required ConflictSnapshot Function() currentSnapshot,
  required Recorded record,
  bool canEdit = true,
  VoidCallback? onLocate,
  VoidCallback? onOpenTimetable,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open-conflict-dialog'),
            onPressed: () => showConflictDetailsDialog(
              context,
              detail: detail,
              snapshot: snapshot,
              currentSnapshot: currentSnapshot,
              commit: (outcome) async {
                record.commits.add(outcome);
                return true;
              },
              canEdit: canEdit,
              onLocate: onLocate,
              onOpenTimetable: onOpenTimetable,
            ),
            child: const Text('打开冲突详情'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-conflict-dialog')));
  await tester.pumpAndSettle();
}

void main() {
  final plan = conflictPlan();
  final display = FakeScheduleEngine.buildSnapshotFor(plan);

  Future<TaskInteraction> pumpGantt(
    WidgetTester tester, {
    required CalendarSchedule schedule,
    required Recorded record,
    bool canEdit = true,
    PlanVersion? versionOverride,
  }) async {
    final interaction = TaskInteraction();
    final version = versionOverride ??
        PlanVersion(
          id: 'ver-conflict',
          conversationId: 'conv-1',
          revision: 3,
          createdAt: at('2026-11-18 07:00'),
          summary: plan.summary,
          tasks: plan.tasks,
          calendar: schedule,
        );
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 700,
          child: CalendarGanttView(
            snapshot: display,
            version: version,
            schedule: schedule,
            interaction: interaction,
            actions: ganttActions(record, canEdit: canEdit),
            clock: at('2026-11-18 07:00'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return interaction;
  }

  testWidgets('甘特图冲突条每行可打开详情：类型/来源/区间/任务/剩余需求/可用容量',
      (tester) async {
    final schedule = overlapSchedule();
    await pumpGantt(tester, schedule: schedule, record: Recorded());

    expect(find.textContaining('点击查看解释与建议'), findsOneWidget);
    expect(find.byKey(const Key('calendar-conflict-row-0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-conflict-row-0')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conflict-detail-dialog')), findsOneWidget);
    expect(find.textContaining('来源：任务预留'), findsWidgets);
    expect(find.textContaining('08:30–09:00'), findsWidgets);
    expect(find.textContaining('剩余需求'), findsWidgets);
    expect(find.textContaining('1 小时'), findsWidgets);
    expect(find.textContaining('同快照可用容量'), findsWidgets);
    expect(find.textContaining('计划版本 rev 3'), findsWidgets);
    // 绿色区域只留一份明细：每类事实只出现一次，不再有灰色复述段落。
    expect(find.byKey(const Key('conflict-detail-tasks')), findsOneWidget);
    expect(find.byKey(const Key('conflict-detail-range')), findsOneWidget);
    expect(find.byKey(const Key('conflict-detail-remaining')), findsOneWidget);
    expect(find.byKey(const Key('conflict-detail-capacity')), findsOneWidget);
    expect(find.byKey(const Key('conflict-detail-explanation')), findsNothing);
    // 黄色区域删除叙述；允许保存冲突的能力保留（不再用灰色说明文案充当证据）。
    expect(find.byKey(const Key('conflict-allow-save-note')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('conflict-detail-dialog')),
        matching: find.textContaining('允许保存'),
      ),
      findsNothing,
    );
    expect(find.textContaining('本地确定性生成'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('conflict-detail-dialog')),
        matching: find.textContaining('不会偷偷删除'),
      ),
      findsNothing,
    );
    // 主按钮“在甘特图中定位”、次按钮“关闭”。
    expect(
      tester.widget(find.byKey(const Key('conflict-detail-locate'))),
      isA<FilledButton>(),
    );
    expect(
      tester.widget(find.byKey(const Key('conflict-detail-close'))),
      isA<TextButton>(),
    );
    // 覆盖来源提示不是“自动解决”，而是一次可见的允许保存的冲突。
    expect(find.textContaining('写报告'), findsWidgets);
    expect(find.textContaining('做实验'), findsWidgets);
  });

  testWidgets('点击“定位”复用甘特图定位机制且不改变数据', (tester) async {
    final record = Recorded();
    final interaction =
        await pumpGantt(tester, schedule: overlapSchedule(), record: record);

    await tester.tap(find.byKey(const Key('calendar-conflict-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conflict-detail-locate')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conflict-detail-dialog')), findsNothing);
    expect(interaction.selectedTaskId, 't1');
    expect(record.commits, isEmpty, reason: '定位只读，不能改数据');
  });

  testWidgets('建议预览展示调整前后/新增冲突，提交走 commit（可撤销的一次事务）',
      (tester) async {
    final record = Recorded();
    final schedule = overlapSchedule();
    await pumpGantt(tester, schedule: schedule, record: record);

    await tester.tap(find.byKey(const Key('calendar-conflict-row-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conflict-suggestion-moveToNextGap')),
        findsOneWidget);

    await tester.tap(
        find.byKey(const Key('conflict-suggestion-preview-moveToNextGap')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conflict-preview-dialog')), findsOneWidget);
    expect(find.textContaining('预览基于此快照'), findsOneWidget);
    expect(find.byKey(const Key('conflict-preview-before-t1')), findsOneWidget);
    expect(find.byKey(const Key('conflict-preview-after-t1')), findsOneWidget);
    expect(find.textContaining('新增冲突：0 处'), findsOneWidget);
    expect(find.textContaining('截止风险'), findsWidgets);

    await tester.tap(find.byKey(const Key('conflict-preview-apply')));
    await tester.pumpAndSettle();

    expect(record.commits, hasLength(1));
    final outcome = record.commits.single;
    expect(outcome.ok, isTrue);
    expect(outcome.label, contains('移动'));
    expect(outcome.message, contains('计划版本 rev 3'));
    final moved = outcome.schedule!.segmentById('s1')!;
    expect(moved.start.isAfter(at('2026-11-18 08:00')), isTrue);
    expect(moved.minutes, 60, reason: '移动不改变时长');
    expect(find.byKey(const Key('conflict-applied-message')), findsOneWidget);
    expect(find.textContaining('已应用建议'), findsOneWidget);
  });

  testWidgets('预览期间数据变化：拒绝过期建议、重新计算并提示重新确认', (tester) async {
    final schedule = overlapSchedule();
    final tasks = schedulingTasks(plan.tasks);
    final original = snapshotOf(schedule, plan.tasks);
    final detail = detailOfKind(schedule, tasks, ConflictKind.taskOverlap);
    final record = Recorded();
    var current = original;

    await pumpDetailsDialogHost(
      tester,
      detail: detail,
      snapshot: original,
      currentSnapshot: () => current,
      record: record,
    );

    // 模拟预览期间计划被别的操作改了一版（版本号变化）。
    current = ConflictSnapshot(
      schedule: original.schedule,
      tasks: original.tasks,
      now: original.now,
      taskNames: original.taskNames,
      stamp: ConflictVersionStamp(
        planRevision: 4,
        timetableRevision: original.stamp.timetableRevision,
        scheduleSignature: original.stamp.scheduleSignature,
      ),
    );

    await tester.tap(
        find.byKey(const Key('conflict-suggestion-apply-moveToNextGap')));
    await tester.pumpAndSettle();

    expect(record.commits, isEmpty, reason: '过期建议不能覆盖新数据');
    expect(find.byKey(const Key('conflict-stale-message')), findsOneWidget);
    expect(find.textContaining('已重新计算'), findsOneWidget);
    expect(find.textContaining('计划版本 rev 4'), findsWidgets);
  });

  testWidgets('无可行自动建议时只写简短原因，并给有效手动入口', (tester) async {
    final schedule = overlapSchedule(source: SegmentSource.manual);
    final tasks = schedulingTasks(plan.tasks);
    final detail = detailOfKind(schedule, tasks, ConflictKind.taskOverlap);
    final record = Recorded();
    final snapshot = snapshotOf(schedule, plan.tasks);
    var openedTimetable = 0;

    await pumpDetailsDialogHost(
      tester,
      detail: detail,
      snapshot: snapshot,
      currentSnapshot: () => snapshot,
      record: record,
      onLocate: () {},
      onOpenTimetable: () => openedTimetable++,
    );

    expect(find.byKey(const Key('conflict-suggestion-none')), findsOneWidget);
    expect(find.byKey(const Key('conflict-none-reason')), findsOneWidget);
    expect(find.text('该时段已手动固定'), findsOneWidget,
        reason: '手动固定只写一句短原因');
    expect(find.textContaining('没有可自动应用的可行建议'), findsNothing);
    expect(find.textContaining('不会偷偷删除'), findsNothing);
    expect(
      find.byKey(const Key('conflict-suggestion-apply-moveToNextGap')),
      findsNothing,
    );
    // 无自动建议时给真实手动入口；点击后关闭本层并调用入口。
    await tester.tap(
        find.byKey(const Key('conflict-suggestion-none-manual-entry')));
    await tester.pumpAndSettle();
    expect(openedTimetable, 1);
    expect(find.byKey(const Key('conflict-detail-dialog')), findsNothing);
    expect(record.commits, isEmpty);
  });

  testWidgets('不可用冲突显示“用户占用”来源与课程名称', (tester) async {
    final schedule = CalendarSchedule(
      settings: settings(
        days: 1,
        occupancies: const [
          CalendarOccupancy(
            id: 'occ-1',
            title: '线性代数',
            kind: 'course',
            weekday: 3,
            ranges: [WallClockRange(8 * 60 + 30, 9 * 60)],
          ),
        ],
      ),
      segments: [
        ScheduleSegment(
          id: 's1',
          taskId: 't1',
          start: at('2026-11-18 08:00'),
          end: at('2026-11-18 10:00'),
          source: SegmentSource.auto,
        ),
      ],
    );
    final tasks = schedulingTasks(plan.tasks);
    final detail = detailOfKind(schedule, tasks, ConflictKind.unavailable);
    final snapshot = snapshotOf(schedule, plan.tasks);
    final record = Recorded();

    await pumpDetailsDialogHost(
      tester,
      detail: detail,
      snapshot: snapshot,
      currentSnapshot: () => snapshot,
      record: record,
    );

    expect(find.textContaining('来源：用户占用'), findsWidgets);
    expect(find.textContaining('线性代数'), findsWidgets);
    expect(find.textContaining('不可用时段'), findsWidgets);
  });

  testWidgets('跨周片段：定位后在时间轴上滚动到正确日期', (tester) async {
    final schedule = CalendarSchedule(
      settings: settings(days: 14),
      segments: [
        ScheduleSegment(
          id: 's1',
          taskId: 't1',
          start: at('2026-11-25 08:00'),
          end: at('2026-11-25 09:00'),
          source: SegmentSource.auto,
        ),
        ScheduleSegment(
          id: 's2',
          taskId: 't2',
          start: at('2026-11-25 08:30'),
          end: at('2026-11-25 09:30'),
          source: SegmentSource.auto,
        ),
      ],
    );
    final interaction =
        await pumpGantt(tester, schedule: schedule, record: Recorded());
    final horizontal = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);
    final scroll = tester.state<ScrollableState>(horizontal);
    // 打开时会自动滚到第一段安排（11月25日）；先回到 0 才能验证“定位”真的滚过去。
    scroll.position.jumpTo(0);
    await tester.pump();

    await tester.tap(find.byKey(const Key('calendar-conflict-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conflict-detail-locate')));
    await tester.pumpAndSettle();
    // 让 flash（2 秒）计时器正常结束，避免测试结束时残留 timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(interaction.selectedTaskId, 't1');
    expect(scroll.position.pixels, greaterThan(500),
        reason: '第二周的冲突需要把时间轴滚到 11月25日 附近');
  });

  testWidgets('只读历史版本：能看解释与建议，但不能应用', (tester) async {
    final record = Recorded();
    final schedule = overlapSchedule();
    final tasks = schedulingTasks(plan.tasks);
    final detail = detailOfKind(schedule, tasks, ConflictKind.taskOverlap);
    final snapshot = snapshotOf(schedule, plan.tasks);
    await pumpDetailsDialogHost(
      tester,
      detail: detail,
      snapshot: snapshot,
      currentSnapshot: () => snapshot,
      record: record,
      canEdit: false,
    );
    expect(find.byKey(const Key('conflict-readonly-note')), findsOneWidget);
    expect(
      find.byKey(const Key('conflict-suggestion-apply-moveToNextGap')),
      findsNothing,
    );
    expect(record.commits, isEmpty);
  });
}
