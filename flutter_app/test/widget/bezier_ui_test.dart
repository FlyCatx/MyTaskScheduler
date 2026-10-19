import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';

void main() {
  test('the shared path is clipped at corners and keeps exact bounds', () {
    const rect = Rect.fromLTWH(20, 30, 200, 80);
    final path = bezierRectPath(rect, 16);
    expect(path.getBounds(), rect);
    expect(path.contains(const Offset(100, 30)), isTrue);
    expect(path.contains(const Offset(20, 30)), isFalse,
        reason: '左上角必须真的被切掉，不是矩形');
  });

  testWidgets('segment labels stay still while only the indicator animates',
      (tester) async {
    var selected = 0;
    final values = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: StatefulBuilder(
              builder: (context, setState) => BezierSegments(
                itemKeys: const [
                  Key('seg-0'),
                  Key('seg-1'),
                  Key('seg-2'),
                ],
                items: const [
                  BezierSegmentItem('依赖图'),
                  BezierSegmentItem('甘特图'),
                  BezierSegmentItem('对比'),
                ],
                selected: selected,
                onChanged: (value) {
                  values.add(value);
                  setState(() => selected = value);
                },
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final before = {
      for (final label in ['依赖图', '甘特图', '对比'])
        label: tester.getCenter(find.text(label)),
    };
    expect(
      find.descendant(
          of: find.byType(BezierSegments), matching: find.byType(CustomPaint)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('seg-1')));
    await tester.pump(const Duration(milliseconds: 120));
    for (final label in before.keys) {
      expect(tester.getCenter(find.text(label)), before[label],
          reason: '文字不能随蓝色块移动');
    }
    await tester.pumpAndSettle();
    expect(values, [1]);
    expect(selected, 1);
  });

  testWidgets('rapid reverse continues from the current block and settles once',
      (tester) async {
    var selected = 0;
    final values = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: StatefulBuilder(
              builder: (context, setState) => BezierSegments(
                itemKeys: const [
                  Key('rev-0'),
                  Key('rev-1'),
                  Key('rev-2'),
                ],
                items: const [
                  BezierSegmentItem('A'),
                  BezierSegmentItem('B'),
                  BezierSegmentItem('C'),
                ],
                selected: selected,
                onChanged: (value) {
                  values.add(value);
                  setState(() => selected = value);
                },
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rev-2')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('rev-0')));
    await tester.pumpAndSettle();
    expect(values, [2, 0]);
    expect(selected, 0);
    expect(
      find.descendant(
          of: find.byType(BezierSegments), matching: find.byType(CustomPaint)),
      findsOneWidget,
      reason: '任何时刻只有一个蓝色指示块',
    );
  });

  testWidgets('disabled and reduced-motion states do not fake animation',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: BezierSegments(
                itemKeys: const [Key('rm-0'), Key('rm-1')],
                items: const [BezierSegmentItem('A'), BezierSegmentItem('B')],
                selected: 0,
                onChanged: (_) => calls++,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rm-1')));
    await tester.pump();
    expect(calls, 1);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: BezierSegments(
              enabled: false,
              itemKeys: const [Key('dis-0'), Key('dis-1')],
              items: const [BezierSegmentItem('A'), BezierSegmentItem('B')],
              selected: 0,
              onChanged: (_) => calls++,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dis-1')));
    await tester.pump();
    expect(calls, 1, reason: '禁用的分段不能回调');
  });
}

