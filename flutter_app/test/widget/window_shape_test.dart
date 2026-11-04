// 窗口状态来源（WindowShape / DesktopWindow）与外形随状态切换的验证。
//
// 第二轮要求：普通还原窗口 18 DIP 圆角，最大化/Snap 直角。这里覆盖：
// - 原生 map → WindowShape 解析与缺字段回退；
// - 初始化查询的迟到结果不得覆盖更新的事件（sequence 守卫）；
// - WindowSurface 在 radius 0 时不再裁剪内容、描边仍是一条直边灰线；
// - 共享窗口端口语义（生产单例 / 测试独立）。

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/desktop_window.dart';
import 'package:taskscheduler_flutter/src/ui/window_surface.dart';

const Key kSurfaceKey = ValueKey('window-shape-surface');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowShape 解析', () {
    test('缺字段用默认值（18 DIP、非最大化）', () {
      const fallback = WindowShape();
      expect(fallback.radiusDip, 18);
      expect(fallback.isRectangular, isFalse);
      final parsed = WindowShape.fromMap(null);
      expect(parsed, fallback);
      expect(WindowShape.fromMap(<String, Object?>{}), fallback);
    });

    test('解析原生 map：maximized/snapped 时 radius 0，DPI 与尺寸保留', () {
      final parsed = WindowShape.fromMap(<Object?, Object?>{
        'radiusDip': 0.0,
        'maximized': true,
        'snapped': false,
        'minimized': false,
        'dpi': 144,
        'width': 2560,
        'height': 1540,
        'sequence': 12,
      });
      expect(parsed.isRectangular, isTrue);
      expect(parsed.maximized, isTrue);
      expect(parsed.dpi, 144);
      expect(parsed.width, 2560);
      expect(parsed.sequence, 12);
    });

    test('负数半径夹到 0，非法类型回退', () {
      final parsed = WindowShape.fromMap(<Object?, Object?>{
        'radiusDip': -5,
        'dpi': 'wrong',
      });
      expect(parsed.radiusDip, 0);
      expect(parsed.isRectangular, isTrue);
      expect(parsed.dpi, 96);
    });
  });

  group('DesktopWindow 状态来源', () {
    test('不传 channel 时返回进程内共享实例；传假 channel 时独立', () {
      final a = DesktopWindow();
      final b = DesktopWindow();
      expect(identical(a, b), isTrue);
      final fake = DesktopWindow(
        channel: const MethodChannel('taskscheduler/window-test-a'),
      );
      expect(identical(fake, a), isFalse);
    });

    test('晚到的初始状态查询不会覆盖更新的事件', () async {
      const channel = MethodChannel('taskscheduler/window-test-seq');
      final window = DesktopWindow(channel: channel);
      addTearDown(window.dispose);

      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      // 让初始 `windowShape` 查询挂起，模拟"查询发出后才发生状态变化"。
      final queryCompleter = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) {
        if (call.method == 'windowShape') return queryCompleter.future;
        if (call.method == 'isMaximized') return Future<Object?>.value(true);
        return Future<Object?>.value(null);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // attach 注册处理器并发出查询（结果先挂起）。
      final attaching = window.attach();
      await Future<void>.delayed(Duration.zero);

      // 事件先到：sequence 5，最大化 → 直角。
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('windowShapeChanged', <String, Object?>{
            'radiusDip': 0.0,
            'maximized': true,
            'sequence': 5,
            'width': 2560,
            'height': 1540,
            'dpi': 144,
          }),
        ),
        (_) {},
      );
      expect(window.shape.value.isRectangular, isTrue);
      expect(window.shape.value.sequence, 5);

      // 查询结果这时才回来，sequence 3 更旧 —— 必须被丢弃。
      queryCompleter.complete(<String, Object?>{
        'radiusDip': 18.0,
        'maximized': false,
        'sequence': 3,
        'width': 1200,
        'height': 800,
        'dpi': 144,
      });
      await attaching;
      expect(window.shape.value.sequence, 5);
      expect(window.shape.value.isRectangular, isTrue);
      expect(window.shape.value.maximized, isTrue);
    });

    test('没有原生实现时 attach 安全降级', () async {
      final window = DesktopWindow(
        channel: const MethodChannel('taskscheduler/window-test-missing'),
      );
      addTearDown(window.dispose);
      await window.attach();
      expect(window.shape.value.radiusDip, 18);
      await window.setCloseGuard(true);
      await window.minimize();
    });
  });

  group('WindowSurface 随真实状态切换外形', () {
    testWidgets('普通窗口：18 DIP 圆角 + 裁剪', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 300);
      addTearDown(tester.view.reset);
      final shape = ValueNotifier<WindowShape>(
        const WindowShape(radiusDip: 18, sequence: 1),
      );
      addTearDown(shape.dispose);
      await tester.pumpWidget(_host(
        shape: shape,
        child: const ColoredBox(color: Color(0xFF123456)),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ClipPath), findsOneWidget);
      final clip = tester.widget<ClipPath>(find.byType(ClipPath));
      expect((clip.clipper! as WindowOutlineClipper).radius, 18);
      final painter = _painter(tester);
      expect(painter.radius, 18);
    });

    testWidgets('最大化：半径 0，不裁剪内容，直边仍有一条灰线', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 300);
      addTearDown(tester.view.reset);
      final shape = ValueNotifier<WindowShape>(
        const WindowShape(radiusDip: 18, sequence: 1),
      );
      addTearDown(shape.dispose);
      await tester.pumpWidget(_host(
        shape: shape,
        child: const ColoredBox(color: Color(0xFF123456)),
      ));
      await tester.pumpAndSettle();

      shape.value = const WindowShape(radiusDip: 0, maximized: true, sequence: 2);
      await tester.pumpAndSettle();

      // 直角状态：没有裁剪层，描边半径 0（只画四条直边）。
      expect(find.byType(ClipPath), findsNothing);
      final painter = _painter(tester);
      expect(painter.radius, 0);

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(kSurfaceKey),
      );
      final image = await tester.runAsync(
        () => boundary.toImage(pixelRatio: 1.0),
      );
      final data =
          await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
      final width = image!.width;
      Color pixel(int x, int y) {
        final offset = (y * width + x) * 4;
        return Color.fromARGB(
          data!.getUint8(offset + 3),
          data.getUint8(offset),
          data.getUint8(offset + 1),
          data.getUint8(offset + 2),
        );
      }

      // 角上是内容色（最大化不切角），四条边中点是灰色直边。
      final corner = pixel(1, 1);
      expect(corner.r, closeTo(0x12 / 255, 0.02));
      for (final point in const [Offset(200, 0), Offset(200, 299), Offset(0, 150), Offset(399, 150)]) {
        final color = pixel(point.dx.round(), point.dy.round());
        expect((color.r - color.g).abs(), lessThan(0.08), reason: '直边应为中性灰');
        expect(color.a, greaterThan(0.8));
      }
      image.dispose();
    });
  });
}

WindowOutlinePainter _painter(WidgetTester tester) {
  final customPaint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((w) => w.foregroundPainter is WindowOutlinePainter);
  return customPaint.foregroundPainter! as WindowOutlinePainter;
}

Widget _host({required ValueListenable<WindowShape> shape, required Widget child}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E6BE6),
        surface: const Color(0xFFFFFFFF),
      ),
    ),
    home: RepaintBoundary(
      key: kSurfaceKey,
      child: WindowSurface(shape: shape, child: child),
    ),
  );
}
