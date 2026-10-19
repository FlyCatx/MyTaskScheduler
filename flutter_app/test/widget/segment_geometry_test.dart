// Segmented-control geometry (0.06 regression test for the 图1 misalignment).
//
// What went wrong in 0.05: the label `Row` computed its own slot width from
// `desiredWidth`, while the painter derived the block position from the real
// `size.width`. With a tight parent the declared `SizedBox` width was overridden, so the
// blue block was placed by the painter's larger width and the labels stayed packed to
// the left. These tests pin both halves to one geometry, in three hostile hosts:
// tight, loose and very narrow.
//
// The block itself is verified by rasterising the frame and measuring the bounding box
// of the accent-blue pixels — the only way to prove that what is *painted* lines up with
// what is *clicked* and *read*. (The label glyphs are white, so a single sampled pixel
// could legitimately be a glyph; a bounding box cannot.)

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

/// Bounding box of every pixel of [color] in the rendered subtree, in the widget's own
/// coordinate space (the render object is the whole test surface, so this is also the
/// screen space of the test).
///
/// `toImage()` completes on the engine thread, so it has to run inside
/// [WidgetTester.runAsync]; awaiting it in the fake-async zone would deadlock.
Future<Rect?> colorBounds(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Color color,
) async {
  final boundary = boundaryKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  final target = (
    (color.a * 255).round(),
    (color.r * 255).round(),
    (color.g * 255).round(),
    (color.b * 255).round(),
  );
  return tester.runAsync<Rect?>(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    var minX = 1 << 30, maxX = -1, minY = 1 << 30, maxY = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 4;
        if (bytes[i + 3] == target.$1 &&
            bytes[i] == target.$2 &&
            bytes[i + 1] == target.$3 &&
            bytes[i + 2] == target.$4) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    image.dispose();
    if (maxX < 0) return null;
    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX.toDouble() + 1,
      maxY.toDouble() + 1,
    );
  });
}

Widget host({
  required Widget child,
  required GlobalKey boundaryKey,
  double width = 400,
  bool tight = false,
}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: RepaintBoundary(
        key: boundaryKey,
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            child: tight
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [child],
                  )
                : Align(alignment: Alignment.centerLeft, child: child),
          ),
        ),
      ),
    ),
  );
}

void expectRectClose(Rect? actual, Rect expected, {double tolerance = 2}) {
  expect(actual, isNotNull, reason: 'the selected block was not painted at all');
  expect((actual!.left - expected.left).abs(), lessThanOrEqualTo(tolerance),
      reason: 'block left $actual vs slot $expected');
  expect((actual.right - expected.right).abs(), lessThanOrEqualTo(tolerance),
      reason: 'block right $actual vs slot $expected');
  expect((actual.top - expected.top).abs(), lessThanOrEqualTo(tolerance),
      reason: 'block top $actual vs slot $expected');
  expect((actual.bottom - expected.bottom).abs(), lessThanOrEqualTo(tolerance),
      reason: 'block bottom $actual vs slot $expected');
}

void main() {
  test('geometry splits the track evenly and keeps the gap symmetric', () {
    const g = SegmentControlGeometry(width: 400, trackHeight: 30, count: 2);
    expect(g.height, 30 + kSegmentGap * 2);
    expect(g.innerWidth, 400 - kSegmentGap * 2);
    expect(g.slotWidth, (400 - kSegmentGap * 2) / 2);
    // First and last slot are exactly one gap away from the outer edge.
    expect(g.slotAt(0).left, kSegmentGap);
    expect(g.slotAt(1).right, 400 - kSegmentGap);
    // Vertical gap equals the horizontal one.
    expect(g.slotAt(0).top, kSegmentGap);
    expect(g.slotAt(1).bottom, g.height - kSegmentGap);
    // At rest the block *is* the slot.
    expect(g.blockFor(0, 0), g.slotAt(0));
    expect(g.blockFor(1, 0), g.slotAt(1));
    // It can never leave the track, even at full pulse.
    for (final position in [0.0, 0.5, 1.0]) {
      for (final pulse in [0.0, 0.5, 1.0]) {
        final block = g.blockFor(position, pulse);
        expect(block.left >= 0, isTrue);
        expect(block.right <= g.width, isTrue);
        expect(block.top >= 0, isTrue);
        expect(block.bottom <= g.height, isTrue);
      }
    }
    // …and it really does grow (the pulse must stay perceptible).
    expect(g.blockFor(0, 1).height, greaterThan(g.blockFor(0, 0).height));
    expect(g.blockFor(0, 1).width, greaterThan(g.blockFor(0, 0).width));
  });

  testWidgets('labels, click rects and the painted block share one slot in a tight host',
      (tester) async {
    final key = GlobalKey();
    var selected = 0;
    await tester.pumpWidget(host(
      tight: true,
      boundaryKey: key,
      width: 400,
      child: StatefulBuilder(
        builder: (context, setState) => BezierSegments(
          expand: true,
          height: 30,
          items: const [
            BezierSegmentItem('DeepSeek 官方'),
            BezierSegmentItem('OpenAI 兼容'),
          ],
          selected: selected,
          onChanged: (i) => setState(() => selected = i),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    const geometry = SegmentControlGeometry(width: 400, trackHeight: 30, count: 2);
    final origin = tester.getTopLeft(find.byType(BezierSegments));
    expect(origin, Offset.zero);
    expect(tester.getSize(find.byType(BezierSegments)).width, 400,
        reason: 'expand must fill the host width');

    // Text centres sit on the slot centres.
    for (final entry in <int, String>{0: 'DeepSeek 官方', 1: 'OpenAI 兼容'}.entries) {
      final center = tester.getCenter(find.text(entry.value));
      final expected = origin.dx + geometry.slotCenter(entry.key).dx;
      expect((center.dx - expected).abs(), lessThan(1.5),
          reason: 'label ${entry.value} must be centred in slot ${entry.key}');
    }

    // The painted block covers exactly the first slot.
    expectRectClose(
      await colorBounds(tester, key, TsColors.buttonFill),
      geometry.slotAt(0).shift(origin),
    );

    // Selecting the second item moves the block to the second slot — and nowhere else.
    await tester.tap(find.text('OpenAI 兼容'));
    await tester.pumpAndSettle();
    final moved = await colorBounds(tester, key, TsColors.buttonFill);
    expectRectClose(moved, geometry.slotAt(1).shift(origin));
  });

  testWidgets('three uneven labels still get equal slots', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(host(
      tight: true,
      boundaryKey: key,
      width: 360,
      child: BezierSegments(
        expand: true,
        height: 28,
        items: const [
          BezierSegmentItem('low'),
          BezierSegmentItem('high'),
          BezierSegmentItem('max'),
        ],
        selected: 1,
        onChanged: (_) {},
      ),
    ));
    await tester.pumpAndSettle();

    const geometry = SegmentControlGeometry(width: 360, trackHeight: 28, count: 3);
    final origin = tester.getTopLeft(find.byType(BezierSegments));
    for (final entry in <int, String>{0: 'low', 1: 'high', 2: 'max'}.entries) {
      final center = tester.getCenter(find.text(entry.value));
      expect((center.dx - (origin.dx + geometry.slotCenter(entry.key).dx)).abs(),
          lessThan(1.5));
    }
    // Every slot has exactly the same width.
    expect(geometry.slotAt(0).width,
        closeTo(geometry.slotAt(2).width, 1e-9));
    // …and the block is on the middle slot.
    expectRectClose(
      await colorBounds(tester, key, TsColors.buttonFill),
      geometry.slotAt(1).shift(origin),
    );
  });

  testWidgets('a narrow host squeezes the slots instead of desynchronising them',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(host(
      tight: true,
      boundaryKey: key,
      width: 180,
      child: BezierSegments(
        expand: true,
        height: 26,
        items: const [
          BezierSegmentItem('全部'),
          BezierSegmentItem('归档'),
          BezierSegmentItem('回收'),
        ],
        selected: 2,
        onChanged: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BezierSegments)).width, 180);
    final origin = tester.getTopLeft(find.byType(BezierSegments));
    const geometry = SegmentControlGeometry(width: 180, trackHeight: 26, count: 3);
    // The last label must still be centred in the last slot (no overflow to the left).
    final center = tester.getCenter(find.text('回收'));
    expect((center.dx - (origin.dx + geometry.slotCenter(2).dx)).abs(),
        lessThan(1.5));
    expectRectClose(
      await colorBounds(tester, key, TsColors.buttonFill),
      geometry.slotAt(2).shift(origin),
    );
  });

  testWidgets('a loose host shrink-wraps without desynchronising anything',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(host(
      boundaryKey: key,
      width: 800,
      child: BezierSegments(
        height: 30,
        itemWidth: 90,
        items: const [
          BezierSegmentItem('A'),
          BezierSegmentItem('B'),
        ],
        selected: 0,
        onChanged: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
    // The *painted* control shrink-wraps to 2 * 90 + 2 gaps even though the host offered
    // 800px: the widget's own box may be wider (Align reports the available width), but
    // the geometry, the labels and the block all use the same smaller width.
    final painted = find
        .descendant(
          of: find.byType(BezierSegments),
          matching: find.byType(CustomPaint),
        )
        .first;
    expect(tester.getSize(painted).width, 90 * 2 + kSegmentGap * 2);
    final origin = tester.getTopLeft(painted);
    const geometry =
        SegmentControlGeometry(width: 188, trackHeight: 30, count: 2);
    expectRectClose(
      await colorBounds(tester, key, TsColors.buttonFill),
      geometry.slotAt(0).shift(origin),
    );
  });

  testWidgets('clicking a slot selects that slot; the current one does not re-fire',
      (tester) async {
    final changes = <int>[];
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => BezierSegments(
              height: 30,
              itemWidth: 90,
              items: const [
                BezierSegmentItem('A'),
                BezierSegmentItem('B'),
              ],
              selected: selected,
              onChanged: (i) {
                changes.add(i);
                setState(() => selected = i);
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(changes, [1]);
    expect(selected, 1);
    // Tapping the already-selected item must not fire again.
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(changes, [1]);
  });

  testWidgets('the animation only moves the block: the track and labels stay put',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => BezierSegments(
              height: 30,
              itemWidth: 90,
              items: const [
                BezierSegmentItem('A'),
                BezierSegmentItem('B'),
              ],
              selected: selected,
              onChanged: (i) => setState(() => selected = i),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final beforeA = tester.getCenter(find.text('A'));
    final beforeB = tester.getCenter(find.text('B'));
    await tester.tap(find.text('B'));
    await tester.pump(const Duration(milliseconds: 180));
    // Mid-animation the labels have not moved by a single pixel.
    expect(tester.getCenter(find.text('A')), beforeA);
    expect(tester.getCenter(find.text('B')), beforeB);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('A')), beforeA);
    expect(tester.getCenter(find.text('B')), beforeB);
  });

  testWidgets('reduced motion jumps straight to the final state', (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => BezierSegments(
                height: 30,
                itemWidth: 80,
                items: const [
                  BezierSegmentItem('A'),
                  BezierSegmentItem('B'),
                ],
                selected: selected,
                onChanged: (i) => setState(() => selected = i),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pump(); // no time passes: the state must already be final
    expect(selected, 1);
  });

  test('dark theme uses the same deep blue block with white text', () {
    TsColors.apply(Brightness.dark);
    addTearDown(() => TsColors.apply(Brightness.light));
    expect(TsColors.buttonFill, const Color(0xFF3B6CF6));
    expect(TsColors.onButton, Colors.white);
    expect(TsColors.accent, const Color(0xFF7A9BFF),
        reason: 'the lighter accent stays for text/links only');
  });
}

