import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';

void main() {
  test('anchors remember their source view and are cleared on view switches',
      () {
    final interaction = TaskInteraction();
    addTearDown(interaction.dispose);
    interaction.enterTask(
      'a',
      anchor: const Rect.fromLTWH(10, 20, 100, 30),
      view: 'gantt',
    );
    expect(interaction.anchors['a']!.view, 'gantt');
    expect(interaction.anchorBelongsTo('a', 'gantt'), isTrue);
    expect(interaction.anchorBelongsTo('a', 'dag'), isFalse);

    interaction.selectAndReveal(
      'a',
      anchor: const Rect.fromLTWH(10, 20, 100, 30),
      view: 'gantt',
    );
    interaction.switchView();
    expect(interaction.anchors, isEmpty);
    expect(interaction.detailTaskId, isNull);
    expect(interaction.selectedTaskId, 'a',
        reason: '切换图表保留任务选择，但旧浮窗必须关闭');

    interaction.setAnchor('b', const Rect.fromLTWH(0, 0, 1, 1), view: 'list');
    interaction.reset();
    expect(interaction.anchors, isEmpty);
  });
}

