import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/gantt_chart.dart';

DisplayTask _scheduled(String id, double start, double end) => DisplayTask(
      id: id,
      name: '任务 $id',
      status: 'ready',
      statusText: '可开始',
      level: 0,
      estimateKnown: true,
      estimateHours: end - start,
      scheduleState: ScheduleState.scheduled,
      startHours: start,
      endHours: end,
    );

void main() {
  testWidgets('Gantt uses the actual bar rect and source view for its anchor',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final interaction = TaskInteraction();
    addTearDown(interaction.dispose);
    final snapshot = DisplaySnapshot(
      tasks: [_scheduled('a', 0, 2), _scheduled('b', 2, 4)],
      order: const ['a', 'b'],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 600,
          child: GanttChartView(snapshot: snapshot, interaction: interaction),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('gantt-bar-a'));
    expect(bar, findsOneWidget);
    final rect = tester.getRect(bar);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 420));

    final anchor = interaction.anchors['a'];
    expect(anchor, isNotNull);
    expect(anchor!.view, 'gantt');
    expect(anchor.rect, rect, reason: '锚点必须是实际条形，不是整行/旧图坐标');

    await gesture.removePointer();
    await tester.tap(bar);
    await tester.pump();
    expect(interaction.detailTaskId, 'a');
    expect(interaction.anchors['a']!.view, 'gantt');
  });
}

