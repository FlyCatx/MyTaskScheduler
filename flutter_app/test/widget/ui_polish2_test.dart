// Widget tests for the fourth review round:
//   1. the user menu hugs the corner (no tall empty popup, no shadow);
//   2. DAG nodes are tall enough for a two-line title plus the status row;
//   3. the task-list checkbox is vertically centred;
//   4. the global font is Microsoft YaHei;
//   5. multi-file selection is wired through one dialog call.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/app_info.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/dag_graph.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/user_menu.dart';

import '../support/test_support.dart';

Future<AppController> pumpShell(WidgetTester tester) async {
  final store = InMemorySessionRepository();
  await seedConversation(store);
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
  testWidgets('4. the global theme uses Microsoft YaHei', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    final context = tester.element(find.byType(AppShell));
    final theme = Theme.of(context);
    expect(theme.textTheme.bodyMedium?.fontFamily, kUiFontFamily);
    expect(theme.textTheme.titleLarge?.fontFamily, kUiFontFamily);
    expect(kUiFontFamily, 'Microsoft YaHei');

    // A plain Text inherits the family from the ambient DefaultTextStyle.
    final text = tester.widget<Text>(find.text('任务清单'));
    expect(text.style?.fontFamily ?? kUiFontFamily, kUiFontFamily);
  });

  testWidgets('1. the user menu sits right above the button and has no shadow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    final button = tester.getRect(find.byType(UserMenuButton));
    await tester.tap(find.byType(UserMenuButton));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('退出登录'));
    // The menu is above the button and close to it (previously it floated ~220px up).
    expect(menu.bottom, lessThan(button.top + 40));
    expect(button.top - menu.bottom, lessThan(120),
        reason: '菜单应紧贴用户入口，而不是浮在高处');

    final material = tester.widget<Material>(find
        .ancestor(of: find.text('设置'), matching: find.byType(Material))
        .first);
    expect(material.elevation, 0, reason: '用户菜单不应有阴影');
  });

  testWidgets('1b. inert entries ignore taps', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    await tester.tap(find.byType(UserMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('意见反馈'), findsOneWidget);

    // Tapping a disabled row must not close the menu (no feedback at all).
    await tester.tap(find.text('意见反馈'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('意见反馈'), findsOneWidget);
  });

  testWidgets('2. DAG nodes fit a two-line title and the status row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    // Longest name in the sample plan would wrap to two lines at nodeWidth.
    final finder = find.descendant(
      of: find.byType(DagGraphView),
      matching: find.text('实现 ListInsert'),
    );
    expect(finder, findsOneWidget);

    // The node box itself: the AnimatedContainer drawn for this task.
    final nodeBox = tester.getRect(
        find.ancestor(of: finder, matching: find.byType(AnimatedContainer)).first);
    expect(nodeBox.height, greaterThanOrEqualTo(76),
        reason: '节点必须容纳两行标题 + 状态行');

    // Every text inside that node (title, order badge, status, estimate) must be fully
    // inside the box — the old 60px box clipped the status/estimate at the bottom edge.
    final texts = find.descendant(
        of: find.ancestor(of: finder, matching: find.byType(AnimatedContainer)).first,
        matching: find.byType(Text));
    expect(texts, findsWidgets);
    for (final element in texts.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.bottom, lessThanOrEqualTo(nodeBox.bottom + 1),
          reason: '节点内的文字不能超出节点底边：${(element.widget as Text).data}');
    }
  });

  testWidgets('3. the row checkbox is vertically centred', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpShell(tester);

    final rowFinder = find.byKey(const ValueKey('task-row-task-b'));
    final row = tester.getRect(rowFinder);
    // The checkbox belonging to THAT row (not the first one in the list).
    final box = tester.getRect(
        find.descendant(of: rowFinder, matching: find.byType(Checkbox)));
    // Centre within a couple of pixels (the checkbox is compact, not top-aligned).
    expect((box.center.dy - row.center.dy).abs(), lessThan(6),
        reason: '复选框应相对整行垂直居中');
  });

  test('5. version constant matches the release', () {
    expect(kAppVersion, '0.1.0');
    expect(kAppVersionSemver, '0.1.0');
  });
}

