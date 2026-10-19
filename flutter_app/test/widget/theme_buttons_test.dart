// Button colour policy (0.07).
//
// Requirement: only *real* action buttons are the solid blue block. A bare TextButton
// (an inline "展开完整端点" link) and a bare IconButton (an ellipsis, a header export
// icon, a delete icon) are transparent affordances with their own hover/focus feedback —
// the 0.06 rule that made every one of them a blue rectangle is gone.
//
// Semantic colours keep their meaning: danger stays red, success stays green, disabled
// stays grey/neutral and is still not clickable.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

Color? _background(ButtonStyle? style, Set<WidgetState> states) =>
    style?.backgroundColor?.resolve(states);

Color? _foreground(ButtonStyle? style, Set<WidgetState> states) =>
    style?.foregroundColor?.resolve(states);

String hex(Color c) =>
    '#${(c.a * 255).round().toRadixString(16).padLeft(2, '0')}'
            '${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
            '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
            '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

Future<Color?> pixelAt(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Offset global,
) async {
  final boundary = boundaryKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  final local = boundary.globalToLocal(global);
  return tester.runAsync<Color>(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final x = local.dx.round().clamp(0, image.width - 1);
    final y = local.dy.round().clamp(0, image.height - 1);
    final i = (y * image.width + x) * 4;
    final color = Color.fromARGB(
      bytes[i + 3],
      bytes[i],
      bytes[i + 1],
      bytes[i + 2],
    );
    image.dispose();
    return color;
  });
}

void main() {
  test('solid action buttons are one deep blue with white text', () {
    final theme = buildAppTheme(Brightness.light);
    const normal = <WidgetState>{};
    for (final entry in <String, ButtonStyle?>{
      'filled': theme.filledButtonTheme.style,
      'elevated': theme.elevatedButtonTheme.style,
      'outlined': theme.outlinedButtonTheme.style,
    }.entries) {
      expect(hex(_background(entry.value, normal)!), '#FF3B6CF6',
          reason: '${entry.key} button fill');
      expect(hex(_foreground(entry.value, normal)!), '#FFFFFFFF',
          reason: '${entry.key} button label/icon colour');
      for (final state in <WidgetState>{
        WidgetState.hovered,
        WidgetState.pressed,
        WidgetState.focused,
      }) {
        final fill = _background(entry.value, {state});
        expect(fill, isNotNull, reason: '${entry.key} $state fill');
        expect(fill, isNot(const Color(0x00000000)),
            reason: '${entry.key} must stay solid on $state');
      }
      expect(hex(_background(entry.value, {WidgetState.disabled})!),
          '#FFDDE2EA',
          reason: '${entry.key} disabled fill');
      expect(hex(_foreground(entry.value, {WidgetState.disabled})!),
          '#FF8A93A3',
          reason: '${entry.key} disabled label');
    }
  });

  test('a bare TextButton / IconButton is transparent, not a blue block', () {
    final theme = buildAppTheme(Brightness.light);
    const normal = <WidgetState>{};
    for (final entry in <String, ButtonStyle?>{
      'text': theme.textButtonTheme.style,
      'icon': theme.iconButtonTheme.style,
    }.entries) {
      expect(_background(entry.value, normal), const Color(0x00000000),
          reason: '${entry.key} must be transparent at rest');
      // Disabled keeps the transparent fill and only mutes the glyph.
      expect(_background(entry.value, {WidgetState.disabled}),
          const Color(0x00000000),
          reason: '${entry.key} disabled fill');
      expect(hex(_foreground(entry.value, {WidgetState.disabled})!),
          '#FF8A93A3',
          reason: '${entry.key} disabled foreground');
      // Hover/pressed are still visible: transparent does not mean "no feedback". The
      // feedback may be a faint background tint (icon buttons) or an overlay tint
      // (text buttons) — either way it must be subtle, never a solid fill.
      final hoverFill = _background(entry.value, {WidgetState.hovered})!;
      final hoverOverlay =
          entry.value!.overlayColor?.resolve({WidgetState.hovered}) ??
              const Color(0x00000000);
      final feedback = math.max(hoverFill.a, hoverOverlay.a);
      expect(feedback, greaterThan(0),
          reason: '${entry.key} must show a faint hover tint');
      expect(feedback, lessThan(0.5),
          reason: '${entry.key} hover must stay a tint, not a solid fill');
    }
  });

  test('ordinary solid buttons share one height and radius', () {
    final theme = buildAppTheme(Brightness.light);
    final filled = theme.filledButtonTheme.style!;
    expect(filled.minimumSize!.resolve(const <WidgetState>{})!.height,
        TsSizes.buttonHeight);
    expect(TsSizes.buttonHeight, 36);
    final icon = theme.iconButtonTheme.style!;
    expect(icon.fixedSize!.resolve(const <WidgetState>{})!.width,
        TsSizes.iconButtonSize);
  });

  test('dark theme keeps a deep blue with white text (not the light accent)', () {
    final theme = buildAppTheme(Brightness.dark);
    TsColors.apply(Brightness.dark);
    addTearDown(() => TsColors.apply(Brightness.light));
    expect(hex(_background(theme.filledButtonTheme.style, const <WidgetState>{})!),
        '#FF3B6CF6');
    expect(hex(_foreground(theme.filledButtonTheme.style, const <WidgetState>{})!),
        '#FFFFFFFF');
    expect(hex(TsColors.accent), '#FF7A9BFF',
        reason: 'the lighter accent is for text/links, not for button fills');
  });

  test('the selected blue is shared by buttons, segments and switches', () {
    for (final brightness in Brightness.values) {
      TsColors.apply(brightness);
      final theme = buildAppTheme(brightness);
      final p = brightness == Brightness.dark ? TsPalette.dark : TsPalette.light;
      expect(TsColors.selected, p.selected);
      expect(TsColors.selected, TsColors.buttonFill,
          reason: 'a Switch and a solid button must read as the same accent');
      final thumb = theme.switchTheme.thumbColor!
          .resolve(const <WidgetState>{WidgetState.selected});
      expect(thumb, p.onButton);
      final track = theme.switchTheme.trackColor!
          .resolve(const <WidgetState>{WidgetState.selected});
      expect(track, p.selected);
      expect(theme.sliderTheme.activeTrackColor, p.selected);
      expect(theme.sliderTheme.thumbColor, p.selected);
      final box = theme.checkboxTheme.fillColor!
          .resolve(const <WidgetState>{WidgetState.selected});
      expect(box, p.selected);
      // Disabled states stay neutral rather than turning blue.
      expect(
          theme.switchTheme.trackColor!
              .resolve(const <WidgetState>{WidgetState.disabled}),
          p.trackDisabled);
      expect(
          theme.switchTheme.trackColor!.resolve(const <WidgetState>{
            WidgetState.disabled,
            WidgetState.selected,
          }),
          p.selectedDisabled);
    }
    addTearDown(() => TsColors.apply(Brightness.light));
  });

  test('semantic variants keep their own colours', () {
    TsColors.apply(Brightness.light);
    expect(hex(TsButtons.danger().backgroundColor!.resolve(const <WidgetState>{})!),
        hex(TsColors.blocked));
    expect(
        hex(TsButtons.success().backgroundColor!.resolve(const <WidgetState>{})!),
        hex(TsColors.ready));
    // A danger button is still white-on-red, never blue.
    expect(
        hex(TsButtons.danger().foregroundColor!.resolve(const <WidgetState>{})!),
        '#FFFFFFFF');
    // The link and close variants are deliberately *not* solid blue.
    expect(TsButtons.link().backgroundColor!.resolve(const <WidgetState>{}),
        const Color(0x00000000));
    expect(
        TsButtons.closeIcon().backgroundColor!.resolve(const <WidgetState>{})!
            .a,
        lessThan(0.2));
  });

  testWidgets('rendered: solid buttons filled, inline buttons transparent',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      // The boundary wraps the whole Scaffold so the background is part of the image and
      // "transparent" can be compared against a real surface colour.
      home: RepaintBoundary(
        key: key,
        child: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A real action button chosen explicitly as solid.
                TextButton(
                  style: TsButtons.solid(),
                  onPressed: () {},
                  child: const Text('A'),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: () {}, child: const Text('B')),
                const SizedBox(width: 12),
                // A bare TextButton: inline link, transparent.
                TextButton(onPressed: () {}, child: const Text('C')),
                const SizedBox(width: 12),
                const FilledButton(onPressed: null, child: Text('D')),
                const SizedBox(width: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: TsColors.blocked),
                  onPressed: () {},
                  child: const Text('E'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Future<Color?> sample(Offset global) => pixelAt(tester, key, global);

    Future<void> expectFill(String label, Color expected) async {
      final rect = tester.getRect(find.text(label));
      // Sample close to the left edge of the glyph strip so the label itself does not
      // cover the sample point.
      final color = await sample(Offset(rect.left - 4, rect.center.dy));
      expect(color, expected, reason: 'button $label fill');
    }

    await expectFill('A', TsColors.buttonFill);
    await expectFill('B', TsColors.buttonFill);
    await expectFill('D', TsColors.buttonDisabledFill);
    await expectFill('E', TsColors.blocked);
    // C is a bare TextButton: its own rectangle paints nothing, so the surface shows
    // through — exactly what "transparent affordance" means.
    await expectFill('C', TsColors.background);
  });

  testWidgets('a rendered IconButton has no solid background', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: RepaintBoundary(
        key: key,
        child: Scaffold(
          body: Center(
            child: IconButton(
              tooltip: '会话菜单',
              onPressed: () {},
              icon: const Icon(Icons.more_horiz, size: 16),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byIcon(Icons.more_horiz));
    // Just inside the hit box but away from the glyph: the surface must show through.
    final color = await pixelAt(tester, key, Offset(rect.left - 6, rect.center.dy));
    expect(color, TsColors.background);
  });

  testWidgets('a disabled button keeps "no callback", so it cannot be triggered',
      (tester) async {
    // The grey fill is asserted above; this pins the other half of the contract: the
    // widget really has no onPressed, so a tap cannot run anything.
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const Scaffold(
        body: Center(
          child: FilledButton(
            key: Key('disabled-save'),
            onPressed: null,
            child: Text('保存'),
          ),
        ),
      ),
    ));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('disabled-save')));
    expect(button.onPressed, isNull);
    await tester.tap(find.text('保存'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the segmented control paints only the selected slot blue',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: RepaintBoundary(
          key: key,
          child: Center(
            child: SizedBox(
              width: 300,
              child: BezierSegments(
                expand: true,
                height: 28,
                items: const [
                  BezierSegmentItem('X'),
                  BezierSegmentItem('Y'),
                ],
                selected: 1,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Measure the *painted* control: the widget's own box may be taller (the outer
    // Align reports the available height), so slot offsets must come from the painter.
    final painted = find
        .descendant(
          of: find.byType(BezierSegments),
          matching: find.byType(CustomPaint),
        )
        .first;
    final origin = tester.getTopLeft(painted);
    const geometry = SegmentControlGeometry(width: 300, trackHeight: 28, count: 2);
    // Sample inside each slot but left of the centred glyph: the label is white, so the
    // exact centre can legitimately be a glyph pixel.
    Offset probe(int index) => origin +
        Offset(geometry.slotAt(index).left + 8, geometry.slotAt(index).center.dy);
    final selected = await pixelAt(tester, key, probe(1));
    expect(selected, TsColors.selected);
    final unselected = await pixelAt(tester, key, probe(0));
    // The unselected slot keeps the neutral track, so the selection is still readable.
    expect(unselected, isNot(TsColors.selected));
    expect(unselected, TsColors.track);
  });

  testWidgets('a non-expanding control shrink-wraps inside a Wrap',
      (tester) async {
    // 0.07 bug fix: the Align inside BezierSegments used to take the whole available
    // width, so in the calendar toolbar 日/周 claimed an entire line and pushed every
    // tool button onto the next one.
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: Wrap(
            children: [
              BezierSegments(
                itemWidth: 56,
                items: const [
                  BezierSegmentItem('日'),
                  BezierSegmentItem('周'),
                ],
                selected: 0,
                onChanged: (_) {},
              ),
              const SizedBox(width: 100, height: 20),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final segments = tester.getSize(find.byType(BezierSegments));
    expect(segments.width, lessThan(200),
        reason: 'a two-item control must not claim the whole row');
    final wrapRunCount =
        tester.getRect(find.byType(Wrap)).height;
    expect(wrapRunCount, lessThan(80), reason: 'both children fit on one line');
  });
}

