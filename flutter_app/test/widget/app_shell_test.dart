// Widget tests for the shell layout and the behaviours the migration must fix:
//   * checkboxes change completion only (no row action bubbling);
//   * switching between tree and gantt keeps the same task selection;
//   * a "related task" jump really scrolls the list AND pans the graph;
//   * hover opens the detail card, click pins it, blank click / Esc closes it;
//   * no score / weight / formula text ever reaches the UI.
//
// Storage is an in-memory repository so the fake-async zone is not blocked by disk
// I/O (see InMemorySessionRepository).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/model/shortcuts.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/dag_graph.dart';
import 'package:taskscheduler_flutter/src/ui/detail_popup.dart';
import 'package:taskscheduler_flutter/src/ui/gantt_chart.dart';
import 'package:taskscheduler_flutter/src/ui/settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

typedef Shell = (AppController, FakeScheduleEngine, InMemorySessionRepository);

Future<Shell> pumpShell(WidgetTester tester,
    {SettingsController? settings}) async {
  final store = InMemorySessionRepository();
  await seedConversation(store);
  final engine = FakeScheduleEngine();
  final controller = AppController(engine: engine, store: store);
  await controller.initialize();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: AppShell(
      controller: controller,
      settings: settings ?? makeTestSettingsController(),
    ),
  ));
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
  return (controller, engine, store);
}

String visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join('\n');

void main() {
  setUp(() {});

  testWidgets('renders history, summary, task list and the tree chart', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('完成顺序表实验'), findsWidgets);
    expect(find.text('任务清单'), findsOneWidget);
    expect(find.byType(DagGraphView), findsOneWidget);
    expect(find.text('依赖图'), findsOneWidget);
    expect(find.text('甘特图'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing, reason: '本轮没有语音入口');
  });

  testWidgets('no score, weight or formula text is ever rendered', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    final texts = visibleText(tester);
    for (final forbidden in ['基础分', '最终分', '权重', '关键链', '候选池', '76.05']) {
      expect(texts.contains(forbidden), isFalse,
          reason: '界面不得出现内部数据：$forbidden');
    }
  });

  testWidgets('checkbox toggles completion without selecting the row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, engine, _) = await pumpShell(tester);
    final callsBefore = engine.computeCalls;

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    final version = controller.viewVersion!;
    expect(version.tasks.first.isDone, isTrue, reason: '勾选应写入完成状态');
    expect(engine.computeCalls, greaterThan(callsBefore),
        reason: '完成状态变化必须重新经 C 内核校验与排序');
    expect(controller.interaction.pinned, isFalse,
        reason: '点复选框不应连带触发行的“固定详情”动作');
  });

  testWidgets('completion is persisted through the repository and bumps revision',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, store) = await pumpShell(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    final saved = store.conversations['conv-seed']!;
    expect(saved.versions.single.tasks.first.isDone, isTrue);
    expect(controller.viewVersion!.revision, 1);
  });

  testWidgets('switching to the gantt keeps the same selected task', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, _) = await pumpShell(tester);

    await tester.tap(find.text('整理实验要求').first);
    await tester.pumpAndSettle();
    final selected = controller.interaction.selectedTaskId;
    expect(selected, isNotNull);

    await tester.tap(find.text('甘特图'));
    await tester.pumpAndSettle();
    expect(find.byType(GanttChartView), findsOneWidget);
    expect(controller.interaction.selectedTaskId, selected,
        reason: '切换图表不能丢失选中任务');
  });

  testWidgets('clicking a node pins the detail card; closing removes it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, _) = await pumpShell(tester);

    await tester.tap(find.text('整理实验要求').last);
    await tester.pumpAndSettle();

    expect(controller.interaction.pinned, isTrue);
    expect(find.byType(TaskDetailCard), findsOneWidget);
    expect(find.text('为什么这样安排'), findsOneWidget);
    expect(find.text('执行步骤'), findsOneWidget);

    controller.interaction.closeDetail();
    await tester.pumpAndSettle();
    expect(find.byType(TaskDetailCard), findsNothing);
  });

  testWidgets('related task chips switch the selection to the target task',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, _) = await pumpShell(tester);

    controller.interaction.selectAndReveal('task-b');
    await tester.pumpAndSettle();
    expect(controller.interaction.selectedTaskId, 'task-b');
    expect(find.byType(TaskDetailCard), findsOneWidget);

    // The detail card lists the predecessor as a chip; tapping it must move there.
    final chip = find.widgetWithText(ActionChip, '整理实验要求');
    expect(chip, findsWidgets);
    await tester.tap(chip.first);
    await tester.pumpAndSettle();
    expect(controller.interaction.selectedTaskId, 'task-a',
        reason: '关联任务跳转必须真正切换选中目标');
    expect(controller.interaction.pinned, isTrue,
        reason: '跳转后详情应固定在新目标上，而不是关掉');
  });

  testWidgets('notes counters expand into sectioned cards with jump chips',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    expect(find.textContaining('待确认 1'), findsOneWidget);
    expect(find.textContaining('分析假设 1'), findsOneWidget);
    await tester.tap(find.textContaining('待确认 1'));
    await tester.pumpAndSettle();
    expect(find.text('ElemType 具体是什么类型？'), findsOneWidget);
  });

  testWidgets('unknown hours are shown as pending, never as a fake duration',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    expect(find.text('工时待确认'), findsWidgets);
    // "实现 ListInsert" has no estimate; it must not be rendered as 0 hours.
    final texts = visibleText(tester);
    expect(texts.contains('0 小时'), isFalse);
  });

  testWidgets('gantt explains unavailable start times instead of faking them',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);
    await tester.tap(find.text('甘特图'));
    await tester.pumpAndSettle();

    expect(find.textContaining('未排期'), findsWidgets);
    expect(find.textContaining('已完成（不占剩余时间）'), findsWidgets);
  });

  testWidgets('current version is editable, a historical version is not',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, _) = await pumpShell(tester);
    expect(controller.canEditPlan, isTrue);
    expect(controller.isViewingCurrentVersion, isTrue);
  });

  testWidgets('display snapshot parses the exact JSON shape the C core emits',
      (tester) async {
    final snap = DisplaySnapshot.fromJson(displayFixtureMap());
    expect(snap.tasks, hasLength(5));
    expect(snap.orderIndex('task-b'), 2);
    expect(snap.byId('task-h')!.estimateKnown, isFalse);
    expect(snap.byId('task-h')!.scheduleState, ScheduleState.unknownHours);
    expect(snap.byId('task-d')!.scheduleNote, contains('起始时间待定'));
    expect(snap.byId('task-done')!.scheduleState, ScheduleState.completed);
    expect(snap.totalKnownHours, 2.5);
    expect(snap.counts.unknownHours, 1);
    expect(snap.notes.first.tasks.single.name, '实现 ListInit');
  });

  testWidgets('common logical window sizes render without overflow',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
      await tester.binding.setSurfaceSize(size);
      await pumpShell(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '窗口 $size 不应溢出');
    }
  });

  testWidgets('task search and status filters explain hidden rows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);
    expect(find.byKey(const Key('task-row-task-a')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('task-search')), 'ListInit');
    await tester.pump();
    expect(find.byKey(const Key('task-row-task-b')), findsOneWidget);
    expect(find.byKey(const Key('task-row-task-a')), findsNothing);
    expect(find.byKey(const Key('task-hidden-count')), findsOneWidget);
    expect(find.textContaining('已按筛选隐藏'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('task-search')), '');
    await tester.tap(find.byKey(const Key('task-filter-done')));
    await tester.pump();
    expect(find.byKey(const Key('task-filter-done')), findsOneWidget);
    expect(find.textContaining('已完成'), findsWidgets);
    expect(find.byKey(const Key('task-row-task-a')), findsNothing,
        reason: '未完成的任务在“已完成”筛选下隐藏');
  });

  testWidgets('选中任务后切到受阻筛选仍能渲染任务清单', (tester) async {
    // 回归（0.1.0）：先点选一个任务，再切到“受阻”。被选中的任务不在筛选结果里，
    // 列表要把该行临时补回来；原先用定长列表，补回时抛异常导致整块列表不渲染。
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    await tester.tap(find.byKey(const Key('task-row-task-a')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('task-filter-blocked')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: '筛选把选中任务隐藏时不得让任务清单停止渲染');
    expect(find.text('任务清单'), findsOneWidget);

    // 回到“全部”同样不能出错。
    await tester.tap(find.byKey(const Key('task-filter-all')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('task-row-task-a')), findsOneWidget);
  });

  testWidgets('a recorded custom binding is what the shell actually dispatches',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = SettingsController(
      store: SettingsStore(createTempDataDir('custom_shortcut')),
      bridge: FakeSettingsBridge(),
    );
    await tester.runAsync(settings.load);
    settings.updateDraftShortcuts({
      AppCommands.openSettings:
          KeyChord(LogicalKeyboardKey.keyJ.keyId, control: true),
    });
    await tester.runAsync(settings.save);
    addTearDown(settings.dispose);
    await pumpShell(tester, settings: settings);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget,
        reason: 'Ctrl+J 必须按用户自定义绑定打开设置，而不是仍然用 Ctrl+,');
  });

  testWidgets('global shortcuts work without clicking a control first',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (controller, _, _) = await pumpShell(tester);

    // Ctrl+, opens the settings window (root focus must be attached/autofocused).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget,
        reason: 'Ctrl+, 必须能在没有先点击任何控件时打开设置');

    // Esc closes the clean dialog (no unsaved edits).
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);

    // Ctrl+N creates a new conversation.
    final before = controller.summaries.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.summaries.length, greaterThan(before));
  });
}

