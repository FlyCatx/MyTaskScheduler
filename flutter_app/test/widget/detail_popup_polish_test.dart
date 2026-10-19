import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/detail_popup.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

void main() {
  testWidgets('close button stays pinned above a scrolled long detail',
      (tester) async {
    final interaction = TaskInteraction()..detailTaskId = 'a'..pinned = true;
    addTearDown(interaction.dispose);
    final task = DisplayTask(
      id: 'a',
      name: '很长的任务标题' * 3,
      status: 'ready',
      statusText: '可开始',
      steps: [for (var i = 0; i < 30; i++) '第 $i 步：' * 4],
      predecessors: const [RelatedTask(id: 'b', name: 'B')],
      reasons: [for (var i = 0; i < 8; i++) '原因 $i：' * 6],
    );
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: TaskDetailCard(
              task: task,
              interaction: interaction,
              maxHeight: 300,
              pinned: true,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(TaskDetailCard));
    final before = tester.getRect(find.byIcon(Icons.close));
    expect(before.top, greaterThanOrEqualTo(card.top));
    expect(before.right, lessThanOrEqualTo(card.right));
    expect(before.width, greaterThanOrEqualTo(40));

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byIcon(Icons.close));
    expect(after, before, reason: '滚动到底部后 X 不能跟着内容滚走');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(interaction.detailTaskId, isNull);
  });
}

