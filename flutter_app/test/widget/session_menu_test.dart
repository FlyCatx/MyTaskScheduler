import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

Future<AppController> pumpTwo(WidgetTester tester) async {
  final store = InMemorySessionRepository();
  await seedConversation(store);
  final other = Conversation(
    id: 'conv-other',
    title: '另一个会话',
    createdAt: DateTime(2026, 10, 18, 9),
    updatedAt: DateTime(2026, 10, 18, 9),
    activityAt: DateTime(2026, 10, 18, 9),
  );
  await store.saveConversation(other);
  await store.saveIndex([
    ...store.index,
    ConversationSummary.of(other),
  ]);
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

void main() {
  testWidgets('right-side ... menu acts on its own row, not the open session',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await pumpTwo(tester);
    // conv-other is the newest, so it is open; seed is not.
    expect(controller.conversation?.id, 'conv-other');

    await tester.tap(find.byKey(const Key('conversation-menu-conv-seed')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('conversation-rename-field')), '手动标题');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final renamed = controller.summaries.firstWhere((s) => s.id == 'conv-seed');
    expect(renamed.displayTitle, '手动标题');
    expect(controller.conversation?.id, 'conv-other',
        reason: '菜单操作非当前会话，不得擅自打开它');
  });

  testWidgets('会话菜单使用统一的扁平样式，且只做淡入淡出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTwo(tester);

    await tester.tap(find.byKey(const Key('conversation-menu-conv-seed')));
    await tester.pump();
    // 淡入过程中已经在画，但尚未完全不透明：只有透明度动画，没有缩放/尺寸/位移动画。
    await tester.pump(const Duration(milliseconds: 40));
    final panelFinder = find.byKey(const Key('bezier-menu-panel'));
    expect(panelFinder, findsOneWidget);
    // 只看菜单自己的动画层，避免把界面里其它无关的隐式动画算进来。
    final menuFades = tester.widgetList<FadeTransition>(
        find.ancestor(of: panelFinder, matching: find.byType(FadeTransition)));
    expect(menuFades.any((f) => f.opacity.value > 0 && f.opacity.value < 1), isTrue,
        reason: '菜单应当有一个短促的淡入过程');
    expect(find.ancestor(of: panelFinder, matching: find.byType(ScaleTransition)),
        findsNothing,
        reason: '不得使用缩放动画');
    expect(find.ancestor(of: panelFinder, matching: find.byType(SizeTransition)),
        findsNothing,
        reason: '不得使用尺寸展开动画');
    expect(find.ancestor(of: panelFinder, matching: find.byType(SlideTransition)),
        findsNothing,
        reason: '不得使用位移动画');

    await tester.pumpAndSettle();
    // 扁平样式：Material elevation 0，没有阴影。
    final panel = panelFinder;
    expect(panel, findsOneWidget);
    final material = tester.widget<Material>(panel);
    expect(material.elevation, 0);
    expect(material.color, TsColors.surface);
    // 样式与设置窗口的用户菜单一致：Bezier 圆角 + 细边框。
    final shape = material.shape as BezierRoundedRectangleBorder;
    expect(shape.radius, 12);

    // 外部点击关闭。
    await tester.tapAt(const Offset(700, 60));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
  });

  testWidgets('search, archive and trash views are separated',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await pumpTwo(tester);
    await tester.enterText(
        find.byKey(const Key('conversation-search')), '另一个');
    await tester.pump();
    expect(find.text('另一个会话'), findsWidgets);
    expect(controller.searchSummaries('另一个').single.id, 'conv-other');

    await controller.setArchived('conv-other', true);
    await controller.moveToTrash('conv-seed');
    await tester.pump();
    expect(controller.visibleSummaries, isEmpty);
    expect(controller.archivedSummaries.single.id, 'conv-other');
    expect(controller.trashedSummaries.single.id, 'conv-seed');
    await controller.restoreFromTrash('conv-seed');
    expect(controller.visibleSummaries.single.id, 'conv-seed');
  });
}

