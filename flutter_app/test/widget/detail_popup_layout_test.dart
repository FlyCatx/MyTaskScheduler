// 任务详情浮窗布局：
//   * 短内容按内容自然收紧（远小于 480）；长内容卡高 ≤480 且只滚正文；
//   * 固定标题/关闭 + 固定已有操作区（executionSection 底栏）在正文滚动时不动；
//   * 定位算法：首行/上半区向下展开，末行/下半区先整卡平移进视口再收缩可用高度；
//     高度上限 = min(480, 可用高度)；水平方向仍优先放右侧、放不下换左侧。
//
// 这些是 widget/纯函数测试；桌面实机（窗口缩放、125%/150% 系统缩放）仍需人工
// 截图核对。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/detail_popup.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

DisplayTask _shortTask() => const DisplayTask(
      id: 'short',
      name: '短任务',
      status: 'ready',
      statusText: '可开始',
    );

DisplayTask _longTask() => DisplayTask(
      id: 'long',
      name: '很长的任务标题' * 3,
      status: 'ready',
      statusText: '可开始',
      steps: [for (var i = 0; i < 40; i++) '第 $i 步：' * 4],
      predecessors: const [RelatedTask(id: 'dep', name: '前置任务')],
      reasons: [for (var i = 0; i < 10; i++) '原因 $i：' * 6],
    );

TaskDetailCard _card(
  TaskInteraction interaction,
  DisplayTask task, {
  double maxHeight = kTaskDetailMaxHeight,
  Widget? executionSection,
}) {
  return TaskDetailCard(
    task: task,
    interaction: interaction,
    maxHeight: maxHeight,
    pinned: true,
    executionSection: executionSection,
  );
}

Future<void> _pumpCard(WidgetTester tester, Widget card) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: Center(child: card),
    ),
  ));
  await tester.pumpAndSettle();
}

Widget _actionFooter() => SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('detail-exec-action'),
              onPressed: () {},
              child: const Text('开始任务'),
            ),
          ),
        ],
      ),
    );

ScrollableState _bodyScroll(WidgetTester tester) {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('task-detail-body')),
        matching: find.byType(Scrollable),
      )
      .first;
  return tester.state<ScrollableState>(scrollable);
}

void main() {
  testWidgets('短任务：卡片高度按内容自然收紧，远小于 480 上限', (tester) async {
    final interaction = TaskInteraction()..detailTaskId = 'short'..pinned = true;
    addTearDown(interaction.dispose);
    await _pumpCard(tester, _card(interaction, _shortTask()));
    final size = tester.getSize(find.byType(TaskDetailCard));
    expect(size.height, lessThan(kTaskDetailMaxHeight),
        reason: '短内容不能撑到上限');
    expect(size.height, greaterThan(60));
    expect(find.byKey(const Key('task-detail-body')), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('长任务：卡高 ≤480，正文可滚到底，标题/关闭固定不动', (tester) async {
    final interaction = TaskInteraction()..detailTaskId = 'long'..pinned = true;
    addTearDown(interaction.dispose);
    final task = _longTask();
    await _pumpCard(tester, _card(interaction, task));
    final size = tester.getSize(find.byType(TaskDetailCard));
    expect(size.height, closeTo(kTaskDetailMaxHeight, 1));
    final scroll = _bodyScroll(tester);
    expect(scroll.position.maxScrollExtent, greaterThan(0),
        reason: '长内容必须由正文自己滚动');
    final closeBefore = tester.getRect(find.byIcon(Icons.close));
    final titleBefore = tester.getRect(find.text(task.name));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byIcon(Icons.close)), closeBefore,
        reason: '关闭键固定在标题区，不随正文滚动');
    expect(tester.getRect(find.text(task.name)), titleBefore,
        reason: '标题固定在顶部');
    expect(tester.takeException(), isNull);
  });

  testWidgets('固定操作区：正文滚到底后 executionSection 仍在原位、按钮可达',
      (tester) async {
    final interaction = TaskInteraction()..detailTaskId = 'long'..pinned = true;
    addTearDown(interaction.dispose);
    await _pumpCard(
      tester,
      _card(interaction, _longTask(),
          maxHeight: 320, executionSection: _actionFooter()),
    );
    final cardRect = tester.getRect(find.byType(TaskDetailCard));
    final actionRect = tester.getRect(find.byKey(const Key('detail-exec-action')));
    expect(cardRect.contains(actionRect.center), isTrue,
        reason: '操作区必须在卡片内');
    expect(actionRect.bottom, lessThanOrEqualTo(cardRect.bottom + 0.5));

    final closeBefore = tester.getRect(find.byIcon(Icons.close));
    await tester.drag(
      find.byKey(const Key('task-detail-body')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const Key('detail-exec-action'))),
      actionRect,
      reason: '执行按钮固定在底栏，不随正文滚动',
    );
    expect(tester.getRect(find.byIcon(Icons.close)), closeBefore);
    // 底栏存在时短任务同样自然收紧。
    final shortInteraction = TaskInteraction()
      ..detailTaskId = 'short'
      ..pinned = true;
    addTearDown(shortInteraction.dispose);
    await _pumpCard(
      tester,
      _card(shortInteraction, _shortTask(), executionSection: _actionFooter()),
    );
    expect(
      tester.getSize(find.byType(TaskDetailCard)).height,
      lessThan(kTaskDetailMaxHeight),
    );
    expect(find.byKey(const Key('detail-exec-action')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('浮窗定位算法 computeDetailPopupGeometry', () {
    test('首行/上半区：向下展开，高度取 min(480, 可用高度)', () {
      final geo = computeDetailPopupGeometry(
        viewport: const Size(900, 700),
        anchor: const Rect.fromLTWH(300, 120, 200, 60),
      );
      expect(geo.top, 112); // 贴任务行顶边 -8
      expect(geo.bottom, isNull);
      expect(geo.maxHeight, 480);
      // 右侧放不下时换到左侧/贴边，且不越出内容区。
      expect(geo.left, 492);
      expect(geo.left + geo.width, lessThanOrEqualTo(900));
    });

    test('末行/下半区：先整卡平移进视口（底边对齐行底），再收缩可用高度', () {
      final geo = computeDetailPopupGeometry(
        viewport: const Size(900, 700),
        anchor: const Rect.fromLTWH(300, 620, 200, 60),
      );
      expect(geo.top, isNull);
      expect(geo.bottom, 12, reason: '卡片底边贴任务行底边 +8，整卡进入视口');
      expect(geo.maxHeight, 480);
      // 卡片完整在视口内：底边 700-12=688，高度 480 → 顶边 208 > headerZone。
      expect(700 - geo.bottom! - geo.maxHeight, greaterThanOrEqualTo(52));
    });

    test('矮窗口：高度上限收缩为可用高度，仍不超过 480', () {
      final geo = computeDetailPopupGeometry(
        viewport: const Size(900, 500),
        anchor: const Rect.fromLTWH(300, 120, 200, 60),
      );
      expect(geo.top, 112);
      expect(geo.maxHeight, 380);
      expect(geo.maxHeight, lessThan(480));
    });

    test('没有锚点：默认贴右上方，高度不超过 min(480, 可视高度)', () {
      final geo = computeDetailPopupGeometry(
        viewport: const Size(900, 400),
        anchor: null,
      );
      expect(geo.top, kTaskDetailHeaderZone);
      expect(geo.maxHeight, 340);
      expect(geo.left, 900 - geo.width - 16);
    });

    test('水平：行在右侧时卡片放左侧，且绝不越出内容区', () {
      final geo = computeDetailPopupGeometry(
        viewport: const Size(700, 700),
        anchor: const Rect.fromLTWH(560, 120, 120, 40),
      );
      expect(geo.left, greaterThanOrEqualTo(8));
      expect(geo.left + geo.width, lessThanOrEqualTo(700 - 8));
    });
  });
}
