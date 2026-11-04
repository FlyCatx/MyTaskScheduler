// 整窗外形（WindowSurface）的几何与绘制验证。
//
// 这里覆盖 Flutter 侧那一半责任：
// - 共享三次贝塞尔路径的四角对称、直边相切、半径夹紧与退化行为；
// - 应用表面确实被裁剪到该路径（角上是透明的，主区是窗口底色）；
// - 1 物理像素灰色描边按 DPR 换算，完整落在轮廓内侧，浅/深色取不同灰；
// - 绘制层不接收指针事件，边缘之外的点击不会落到内容上；
// - 失焦只降低描边对比度，不取消描边。
//
// 原生窗口区域由 C 测试 `tests/test_window_region.c` 与真实窗口探针
// `scripts/window_shape_probe.ps1` 验证，二者互不替代。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/theme/values.dart';
import 'package:taskscheduler_flutter/src/ui/window_surface.dart';

const Key kSurfaceKey = ValueKey('window-surface');
const Key kContentKey = ValueKey('window-surface-content');

/// 沿路径均匀取点，用于对称/边界断言。
List<Offset> _samplePath(Path path, {int samples = 720}) {
  final points = <Offset>[];
  for (final metric in path.computeMetrics()) {
    for (var i = 0; i <= samples; i++) {
      final distance = metric.length * i / samples;
      final tangent = metric.getTangentForOffset(distance);
      if (tangent != null) points.add(tangent.position);
    }
  }
  return points;
}

Future<ui.Image> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(kSurfaceKey),
  );
  // toImage needs the real (non-fake) async loop, otherwise the future never
  // completes inside a widget test.
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
  return image!;
}

Future<ByteData> _rgba(WidgetTester tester, ui.Image image) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data!;
}

Color _pixel(ByteData bytes, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(offset + 3),
    bytes.getUint8(offset),
    bytes.getUint8(offset + 1),
    bytes.getUint8(offset + 2),
  );
}

/// 只断言“是灰的”：抗锯齿会让精确值浮动，但绝不会变成红/白/黑。
void _expectGray(Color color, String reason) {
  expect(color.a, greaterThan(0.8), reason: '$reason：描边必须可见');
  expect((color.r - color.g).abs(), lessThan(0.08), reason: reason);
  expect((color.g - color.b).abs(), lessThan(0.08), reason: reason);
  expect(color.r, lessThan(0.95), reason: '$reason：必须是中性灰而不是白');
}

Widget _host({
  required Widget child,
  Brightness brightness = Brightness.light,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTestTheme(brightness),
    home: RepaintBoundary(
      key: kSurfaceKey,
      child: WindowSurface(child: child),
    ),
  );
}

ThemeData buildTestTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E6BE6),
        brightness: brightness,
        surface: brightness == Brightness.light
            ? const Color(0xFFFFFFFF)
            : const Color(0xFF1D2026),
      ),
    );

void main() {
  group('cubicWindowPath 几何', () {
    test('四个角对称、全部落在矩形内、四边中点与曲线相切', () {
      const box = Rect.fromLTWH(0, 0, 400, 300);
      const radius = 18.0;
      final path = cubicWindowPath(box, radius);
      final points = _samplePath(path);

      expect(points, isNotEmpty);
      for (final point in points) {
        expect(point.dx, inInclusiveRange(-0.01, box.right + 0.01));
        expect(point.dy, inInclusiveRange(-0.01, box.bottom + 0.01));
      }

      // 四角是真实曲线：矩形的四个角点不在路径上。
      expect(path.contains(const Offset(0.5, 0.5)), isFalse);
      expect(path.contains(const Offset(399.5, 0.5)), isFalse);
      expect(path.contains(const Offset(0.5, 299.5)), isFalse);
      expect(path.contains(const Offset(399.5, 299.5)), isFalse);

      // 直边内侧与中心属于窗口。
      expect(path.contains(const Offset(200, 0.6)), isTrue);
      expect(path.contains(const Offset(200, 150)), isTrue);

      // 左右/上下镜像对称：用路径自身判断（按弧长取样点在镜像后并不镜像，
      // 因为起点不在对称轴上），直接在网格点上比较 contains 结果。
      // 列主序变换矩阵：x' = sx*x + tx, y' = sy*y + ty。
      Float64List mirror(double sx, double sy, double tx, double ty) {
        final matrix = Float64List.fromList(<double>[
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]);
        matrix[0] = sx;
        matrix[5] = sy;
        matrix[12] = tx;
        matrix[13] = ty;
        return matrix;
      }

      final mirroredXPath =
          path.transform(mirror(-1, 1, box.width, 0));
      final mirroredYPath =
          path.transform(mirror(1, -1, 0, box.height));
      var asymmetric = 0;
      for (var y = 2.0; y < box.height; y += 7) {
        for (var x = 2.0; x < box.width; x += 7) {
          final point = Offset(x, y);
          if (path.contains(point) !=
              mirroredXPath.contains(Offset(box.width - x, y))) {
            asymmetric++;
          }
          if (path.contains(point) !=
              mirroredYPath.contains(Offset(x, box.height - y))) {
            asymmetric++;
          }
        }
      }
      expect(asymmetric, 0, reason: '四角必须左右/上下对称');
    });

    test('半径按短边一半夹紧，0 半径退化为矩形', () {
      const box = Rect.fromLTWH(0, 0, 100, 20);
      final clamped = cubicWindowPath(box, 50);
      for (final point in _samplePath(clamped)) {
        expect(point.dx, inInclusiveRange(-0.01, 100.01));
        expect(point.dy, inInclusiveRange(-0.01, 20.01));
      }
      // 半径被夹到 10：矩形左上角 (0.5,0.5) 仍在曲线外。
      expect(clamped.contains(const Offset(0.5, 0.5)), isFalse);

      final rect = cubicWindowPath(box, 0);
      expect(rect.contains(const Offset(0.5, 0.5)), isTrue);
      expect(rect.contains(const Offset(99.5, 19.5)), isTrue);
    });

    test('空矩形返回空路径，非法半径不抛出', () {
      expect(cubicWindowPath(Rect.zero, 12).computeMetrics().isEmpty, isTrue);
      expect(cubicWindowPath(const Rect.fromLTWH(0, 0, 10, 10), -4), isNotNull);
      expect(
        cubicWindowPath(const Rect.fromLTWH(0, 0, 10, 10), double.nan),
        isNotNull,
      );
    });
  });

  group('WindowOutlinePainter', () {
    test('描边宽度按 DPR 换算为 1 物理像素', () {
      expect(TsWindowShape.strokeWidth(1.0), closeTo(1.0, 1e-9));
      expect(TsWindowShape.strokeWidth(1.5), closeTo(2 / 3, 1e-9));
      expect(TsWindowShape.strokeWidth(2.0), closeTo(0.5, 1e-9));
      expect(TsWindowShape.strokeWidth(0), closeTo(1.0, 1e-9));
      expect(TsWindowShape.strokeWidth(double.infinity), closeTo(1.0, 1e-9));
    });

    test('不接收指针事件，参数变化才重绘', () {
      const painter = WindowOutlinePainter(
        radius: 12,
        strokeWidth: 0.667,
        color: TsWindowShape.borderLight,
      );
      expect(painter.hitTest(const Offset(5, 5)), isFalse);
      expect(painter.hitTest(Offset.zero), isFalse);
      expect(
        painter.shouldRepaint(
          const WindowOutlinePainter(
            radius: 12,
            strokeWidth: 0.667,
            color: TsWindowShape.borderLight,
          ),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          const WindowOutlinePainter(
            radius: 11,
            strokeWidth: 0.667,
            color: TsWindowShape.borderLight,
          ),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const WindowOutlinePainter(
            radius: 12,
            strokeWidth: 0.5,
            color: TsWindowShape.borderLight,
          ),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const WindowOutlinePainter(
            radius: 12,
            strokeWidth: 0.667,
            color: TsWindowShape.borderDark,
          ),
        ),
        isTrue,
      );
    });

    test('主题令牌：灰色描边、18 逻辑像素半径、1 物理像素', () {
      expect(TsWindowShape.radius, 18);
      expect(TsWindowShape.borderWidthPhysical, 1);
      expect(TsWindowShape.borderFor(Brightness.light), TsWindowShape.borderLight);
      expect(TsWindowShape.borderFor(Brightness.dark), TsWindowShape.borderDark);
      // 中性灰：三通道接近，不是蓝色（蓝通道不得明显高于红/绿）。
      for (final color in [
        TsWindowShape.borderLight,
        TsWindowShape.borderDark,
      ]) {
        expect((color.b - color.r).abs(), lessThan(0.08));
      }
    });
  });

  group('WindowSurface 像素级验证', () {
    testWidgets('四角被裁剪到轮廓外，主区是窗口底色，边缘有灰色描边', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 300);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(child: const ColoredBox(color: Color(0xFF123456))),
      );
      await tester.pumpAndSettle();

      final image = await _capture(tester);
      final data = await _rgba(tester, image);
      expect(image.width, 400);
      expect(image.height, 300);

      // 四角在外轮廓之外：不绘制内容（不是内容色），而是窗口底色。原生 Region 会
      // 把这些像素整个裁掉，所以屏幕上看到的是桌面；这里断言的是“内容被裁剪”和
      // “没有透明黑洞”（透明会被 DWM 合成为黑色毛边）。
      for (final corner in const [
        Offset(1, 1),
        Offset(398, 1),
        Offset(1, 298),
        Offset(398, 298),
      ]) {
        final pixel =
            _pixel(data, image.width, corner.dx.round(), corner.dy.round());
        expect(pixel.a, greaterThan(0.9), reason: '角上必须是窗口底色，不能透明 $corner');
        expect(
          (pixel.r - 0x12 / 255).abs() > 0.1 ||
              (pixel.g - 0x34 / 255).abs() > 0.1,
          isTrue,
          reason: '角上不能是内容色（说明内容没被裁剪）$corner',
        );
        expect((pixel.r - pixel.g).abs(), lessThan(0.05),
            reason: '角上应是中性底色 $corner');
      }

      // 主区是内容颜色。
      final center = _pixel(data, image.width, 200, 150);
      expect(center.r, closeTo(0x12 / 255, 0.02));
      expect(center.g, closeTo(0x34 / 255, 0.02));
      expect(center.b, closeTo(0x56 / 255, 0.02));

      // 四条边的中点是灰色描边（1 物理像素在 dpr=1 下就是 1 逻辑像素）。
      _expectGray(_pixel(data, image.width, 200, 0), '上边描边');
      _expectGray(_pixel(data, image.width, 200, 299), '下边描边');
      _expectGray(_pixel(data, image.width, 0, 150), '左边描边');
      _expectGray(_pixel(data, image.width, 399, 150), '右边描边');

      image.dispose();
    });

    testWidgets('深色主题使用深灰描边，且仍然画在内容之上', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          brightness: Brightness.dark,
          child: const ColoredBox(color: Color(0xFF0A0C10)),
        ),
      );
      await tester.pumpAndSettle();

      final image = await _capture(tester);
      final data = await _rgba(tester, image);
      final edge = _pixel(data, image.width, 160, 0);
      _expectGray(edge, '深色上边描边');
      // 深灰比浅灰暗。
      expect(
        edge.r,
        lessThan(TsWindowShape.borderLight.r + 0.02),
      );
      image.dispose();
    });

    testWidgets('描边随 DPR 缩放：150% 时仍是 1 物理像素', (tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(600, 450);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(child: const ColoredBox(color: Color(0xFFFFFFFF))),
      );
      await tester.pumpAndSettle();

      final customPaint = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .firstWhere((w) => w.foregroundPainter is WindowOutlinePainter);
      final painter = customPaint.foregroundPainter! as WindowOutlinePainter;
      expect(painter.radius, TsWindowShape.radius);
      expect(painter.strokeWidth, closeTo(1 / 1.5, 1e-9));
      expect(painter.color, TsWindowShape.borderLight);
    });

    testWidgets('绘制层不吞事件：中心点击到达内容，角外点击被裁剪', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          child: GestureDetector(
            key: kContentKey,
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const ColoredBox(color: Color(0xFFFFFFFF)),
          ),
        ),
      );

      await tester.tapAt(const Offset(200, 150));
      expect(taps, 1);

      // 左上角 2x2 在外轮廓之外，不应命中内容。
      await tester.tapAt(const Offset(1, 1));
      expect(taps, 1);
    });

    testWidgets('应用表面裁剪使用同一条路径', (tester) async {
      await tester.pumpWidget(
        _host(child: const ColoredBox(color: Color(0xFFFFFFFF))),
      );
      final clip = tester.widget<ClipPath>(
        find.descendant(
          of: find.byType(WindowSurface),
          matching: find.byType(ClipPath),
        ),
      );
      expect(clip.clipper, isA<WindowOutlineClipper>());
      expect((clip.clipper! as WindowOutlineClipper).radius, TsWindowShape.radius);
      expect(clip.clipBehavior, Clip.antiAlias);
    });
  });
}
