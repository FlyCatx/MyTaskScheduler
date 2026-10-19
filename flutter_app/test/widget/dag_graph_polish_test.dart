import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/dag_graph.dart';

DisplayTask _task(
  String id,
  int level, {
  List<RelatedTask> predecessors = const [],
}) =>
    DisplayTask(
      id: id,
      name: id.toUpperCase(),
      status: 'ready',
      statusText: '可开始',
      level: level,
      predecessors: predecessors,
      estimateKnown: true,
      estimateHours: 1,
    );

DisplaySnapshot _snapshot() => DisplaySnapshot(
      tasks: [
        _task('a', 0),
        _task('b', 1, predecessors: const [RelatedTask(id: 'a', name: 'A')]),
        _task('c', 1, predecessors: const [RelatedTask(id: 'a', name: 'A')]),
        _task('d', 3, predecessors: const [RelatedTask(id: 'c', name: 'C')]),
      ],
      order: const ['a', 'b', 'c', 'd'],
      counts: const DisplayCounts(),
    );

Future<TaskInteraction> _pump(WidgetTester tester) async {
  final interaction = TaskInteraction();
  addTearDown(interaction.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DagGraphView(
          snapshot: _snapshot(),
          interaction: interaction,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return interaction;
}

void main() {
  testWidgets('rows share a centre axis and fit-all centres the content',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester);

    final a = tester.getCenter(find.byKey(const Key('dag-node-a')));
    final b = tester.getCenter(find.byKey(const Key('dag-node-b')));
    final c = tester.getCenter(find.byKey(const Key('dag-node-c')));
    expect((a.dx - (b.dx + c.dx) / 2).abs(), lessThan(1.5),
        reason: '两层节点必须围绕同一水平中心轴');
    expect(a.dx, closeTo(450, 1.5),
        reason: '单节点顶行在 900 宽视口中应居中');
    expect((c.dy - b.dy).abs(), lessThan(0.5));
  });

  testWidgets('non-contiguous levels use the level index, not the raw number',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester);
    final b = tester.getCenter(find.byKey(const Key('dag-node-b')));
    final d = tester.getCenter(find.byKey(const Key('dag-node-d')));
    // level 3 is the third row: exactly one row pitch below level 1.
    expect(d.dy - b.dy, closeTo(78 + 44, 0.6));
  });

  testWidgets('small panes keep readable scale and show the real zoom percent',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(tester);
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final scale = viewer.transformationController!.value.getRow(0)[0];
    expect(scale, greaterThanOrEqualTo(0.55),
        reason: '初始视图不能为了塞进小窗而无限缩小');
    final label = tester.widget<Text>(find.byKey(const Key('dag-zoom-percent')));
    expect(label.data, '${(scale * 100).round()}%',
        reason: '缩放百分比必须反映实际变换');
  });

  testWidgets('resize recentres before interaction, but a user pan survives',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final interaction = await _pump(tester);

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpAndSettle();
    final a = tester.getCenter(find.byKey(const Key('dag-node-a')));
    final graph = tester.getCenter(find.byType(DagGraphView));
    expect(a.dx, closeTo(graph.dx, 2),
        reason: 'resize 后仍应按实际包围盒居中');
    final resizedViewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final resizedScale =
        resizedViewer.transformationController!.value.getRow(0)[0];
    final resizedLabel =
        tester.widget<Text>(find.byKey(const Key('dag-zoom-percent')));
    expect(resizedLabel.data, '${(resizedScale * 100).round()}%',
        reason: 'resize 后百分比必须同步');

    await tester.binding.setSurfaceSize(const Size(900, 300));
    await tester.pumpAndSettle();
    final smallViewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final smallScale =
        smallViewer.transformationController!.value.getRow(0)[0];
    final smallLabel =
        tester.widget<Text>(find.byKey(const Key('dag-zoom-percent')));
    expect(smallLabel.data, '${(smallScale * 100).round()}%',
        reason: '输入区展开式的高度缩小也必须同步百分比');
    expect(
      tester.getRect(find.byKey(const ValueKey('dag-node-a'))).width,
      closeTo(220 * smallScale, 1.5),
      reason: '实际节点宽度必须与矩阵缩放一致',
    );

    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final controller = viewer.transformationController!;
    controller.value = Matrix4.translationValues(123, 45, 0);
    await tester.pump();
    interaction.selectOnly('a');
    await tester.pump();
    expect(controller.value.getRow(0)[3], 123);
    expect(controller.value.getRow(1)[3], 45,
        reason: '用户平移后普通 rebuild 不能把图表抢回归中');
  });
}

