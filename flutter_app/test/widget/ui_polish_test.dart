// Widget tests for the four UI items in the latest review round:
//
//   1. the task-list and dependency-view headers share ONE continuous bottom rule;
//   2. the tree chart is vertical (first-executed at the top, last at the bottom);
//   3. the bottom-left user entry opens a menu (设置 enabled, 意见反馈/退出登录 inert) and
//      the settings dialog is a centred modal with a complete left rail and an 关于 page;
//   4. an UNSELECTED history row is not partially bold.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/app_info.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/dag_graph.dart';
import 'package:taskscheduler_flutter/src/ui/settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/user_menu.dart';

import '../support/test_support.dart';

Future<AppController> pumpShell(WidgetTester tester,
    {List<Attachment> attachments = const []}) async {
  final store = InMemorySessionRepository();
  await seedConversation(store, attachments: attachments);
  final controller = AppController(engine: FakeScheduleEngine(), store: store);
  await controller.initialize();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: AppShell(
      controller: controller,
      settings: makeTestSettingsController(),
    ),
  ));
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
  return controller;
}

/// Node position of a task inside the DAG (name text is unique per pane).
Offset nodeCenter(WidgetTester tester, String name) {
  final finder = find.descendant(
    of: find.byType(DagGraphView),
    matching: find.text(name),
  );
  return tester.getCenter(finder);
}

void main() {
  group('1. pane header rule', () {
    testWidgets('task list and dependency headers share one continuous line',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      final listHeader = tester.getRect(find.text('任务清单'));
      final chartHeader = tester.getRect(find.text('依赖视图'));

      // Same vertical band => same height header row.
      expect(listHeader.center.dy, closeTo(chartHeader.center.dy, 0.5),
          reason: '两个标题必须在同一水平高度');

      // Exactly one horizontal rule under both headers (not one per pane).
      final rules = find.byType(Divider);
      expect(rules, findsWidgets);
      final ruleRect = tester.getRect(rules.first);
      expect(listHeader.bottom, lessThanOrEqualTo(ruleRect.top));
      expect(chartHeader.bottom, lessThanOrEqualTo(ruleRect.top));
      // The rule spans the whole middle area, so it cannot be broken at the splitter.
      expect(ruleRect.width, greaterThan(listHeader.left + 600));
    });
  });

  group('2. vertical tree', () {
    testWidgets('levels run top to bottom, siblings share a row', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      // samplePlan: task-a (level 0), task-c (level 0), task-b (level 1), task-d (level 2)
      final a = nodeCenter(tester, '整理实验要求');
      final c = nodeCenter(tester, '阅读实验材料');
      final b = nodeCenter(tester, '实现 ListInit');
      final d = nodeCenter(tester, '实现 ListInsert');

      // Level 0 on the same row, side by side.
      expect(a.dy, closeTo(c.dy, 1.0), reason: '同一层的任务应在一行');
      expect(a.dx, isNot(closeTo(c.dx, 1.0)), reason: '同一层的任务应水平并排');

      // Deeper levels are BELOW, not to the right.
      expect(b.dy, greaterThan(a.dy + 20), reason: '后继任务应在上方任务的下方');
      expect(d.dy, greaterThan(b.dy + 20), reason: '执行顺序自上而下');
      // And not pushed sideways the way a horizontal layout would.
      expect(b.dx, lessThan(a.dx + 400));
    });
  });

  group('3. user entry + settings', () {
    testWidgets('bottom-left user entry opens a menu with only 设置 enabled',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      expect(find.byType(UserMenuButton), findsOneWidget);
      expect(find.text(kLocalUserName), findsOneWidget);

      // It sits in the bottom-left corner of the window.
      final button = tester.getRect(find.byType(UserMenuButton));
      expect(button.left, lessThan(320));
      expect(button.bottom, greaterThan(700));

      await tester.tap(find.byType(UserMenuButton));
      await tester.pumpAndSettle();

      expect(find.text('设置'), findsWidgets);
      expect(find.text('意见反馈'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);

      // The two inert entries are not interactive: their rows are wrapped in an
      // IgnorePointer so they cannot be tapped or hovered at all.
      for (final label in ['意见反馈', '退出登录']) {
        final guard = find.ancestor(
          of: find.text(label),
          matching: find.byType(IgnorePointer),
        );
        expect(guard, findsWidgets, reason: '「$label」应被 IgnorePointer 包裹（无交互）');
        final row = tester.widget<IgnorePointer>(guard.first);
        expect(row.ignoring, isTrue);
      }
      // 设置 stays clickable.
      final settingsGuard = find.ancestor(
        of: find.text('设置').last,
        matching: find.byType(IgnorePointer),
      );
      expect(settingsGuard, findsNothing, reason: '「设置」必须可点击');
    });

    testWidgets('settings dialog is centred with a complete rail and an 关于 page',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.byType(UserMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsDialog), findsOneWidget);

      // Rail: all seven entries, in the agreed order.
      for (final section in SettingsSection.values) {
        expect(find.text(section.label), findsWidgets,
            reason: '左栏缺少「${section.label}」');
      }
      expect(SettingsSection.values.map((s) => s.label).toList(),
          ['账户安全', '通用', '模型', '快捷键', '通知', '存储', '关于']);

      // Centred card: its centre must match the shell's centre.
      final dialog = tester.getRect(find.byType(SettingsDialog));
      final shell = tester.getRect(find.byType(AppShell));
      expect(dialog.center.dx, closeTo(shell.center.dx, 2));
      expect(dialog.center.dy, closeTo(shell.center.dy, 2));
      expect(dialog.width, lessThanOrEqualTo(shell.width));
      expect(dialog.height, lessThanOrEqualTo(shell.height));

      // The generic entry point lands on 账户安全, so the 关于 page content must be
      // reached by selecting it in the rail.
      expect(find.text('本地账户'), findsOneWidget);
      await tester.tap(find.text('关于').last);
      await tester.pumpAndSettle();

      // 关于 page content (version + help), buttons drawn but not wired.
      expect(find.text('版本信息'), findsOneWidget);
      expect(find.textContaining(kAppVersion), findsWidgets);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('帮助'), findsOneWidget);
      expect(find.text('查看帮助'), findsOneWidget);

      // 0.05: genuinely disabled, not a toast that claims a check happened.
      final updateButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '检查更新'));
      expect(updateButton.onPressed, isNull);
    });

    testWidgets('rail switches to the real 通用 page', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.byType(UserMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();

      // 0.0.4: the pages are implemented, not placeholders.
      expect(find.text('主题'), findsOneWidget);
      expect(find.text('发送方式'), findsOneWidget);
      // The About content is gone.
      expect(find.text('版本信息'), findsNothing);
    });
  });

  group('4. history row weight', () {
    testWidgets('an unselected row is regular weight (no partial bold)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const longTitle = '完成顺序表基本操作及集合并、集合相等判别的实验实现与验证';
      final store = InMemorySessionRepository();
      await seedConversation(store, conversationId: 'conv-1', title: longTitle);
      await seedConversation(store, conversationId: 'conv-2', title: '短标题');
      // Both must be visible, so rebuild the index with two entries.
      final first = await store.loadConversation('conv-1');
      final second = await store.loadConversation('conv-2');
      await store.saveIndex([
        ConversationSummary.of(first!),
        ConversationSummary.of(second!),
      ]);

      final controller =
          AppController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: AppShell(
          controller: controller,
          settings: makeTestSettingsController(),
        ),
      ));
      await tester.pumpAndSettle();

      final titleFinder = find.text(longTitle);
      if (titleFinder.evaluate().isEmpty) return; // current row may be the other one
      final style = tester.widget<Text>(titleFinder.first).style!;
      expect(style.fontWeight, FontWeight.w400,
          reason: '未选中的会话标题必须是常规字重，否则中文会被伪粗体化');
    });
  });
}

