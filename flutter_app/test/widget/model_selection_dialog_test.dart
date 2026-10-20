// 模型选择弹窗（图 1）：三段控件填满输入宽度，两段说明被删除，行为不变。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/ui/model_selection_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';

import '../support/test_support.dart';

Future<void> _open(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 800);
  addTearDown(tester.view.reset);
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              await showModelSelectionDialog(
                context,
                profiles: <ProviderProfile>[sampleProfile()],
                current: sampleSelection(),
                globalDefault: sampleSelection(),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('三段控件填满输入区宽度，每段等宽', (tester) async {
    await _open(tester);
    final segments = find.byType(BezierSegments);
    expect(segments, findsOneWidget);
    final fieldWidth = tester.getSize(find.byType(TextField)).width;
    final segmentWidth = tester.getSize(segments).width;
    expect(segmentWidth, closeTo(fieldWidth, 1.0),
        reason: '改的是分段控件宽度，不是整个弹窗');
    // 三段等宽：三个文字中心应等距，且每段占据约三分之一。
    final rect = tester.getRect(segments);
    final third = rect.width / 3;
    final low = tester.getCenter(find.text('low')).dx;
    final high = tester.getCenter(find.text('high')).dx;
    final max = tester.getCenter(find.text('max')).dx;
    expect(high - low, closeTo(third, 3.0));
    expect(max - high, closeTo(third, 3.0));
    expect(low, closeTo(rect.left + third / 2, 4));
    expect(high, closeTo(rect.left + third * 1.5, 4));
    expect(max, closeTo(rect.left + third * 2.5, 4));
  });

  testWidgets('两段黄框说明已删除；跟随全局默认保留', (tester) async {
    await _open(tester);
    expect(find.textContaining('切换只影响之后的请求'), findsNothing);
    expect(find.textContaining('thinking.type=disabled'), findsNothing);
    expect(find.text('跟随全局默认'), findsOneWidget);
    expect(find.text('思考模式'), findsOneWidget);
  });
}
