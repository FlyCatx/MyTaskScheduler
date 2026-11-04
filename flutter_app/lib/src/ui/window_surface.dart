// 整窗外形：一条共享的三次贝塞尔路径同时用于裁剪全部应用表面与绘制内侧灰色描边。
//
// 为什么需要两层：
// - 原生侧（`flutter_app/windows/runner/window_region.h`）用同一份三次路径生成窗口
//   Region，顶层 HWND 的四个外角因此真的不属于窗口；单独一个 ClipPath 改变不了
//   不透明 Windows 窗口的形状。
// - Flutter 侧负责把标题栏、侧边栏、主区、输入区、弹窗遮罩与菜单裁剪到同一条路径，
//   并在最外层画 1 物理像素的灰色描边。绘制层 hitTest 返回 false，不抢鼠标/焦点。
//
// 第二轮（0.2.2）：外形不再是一个静态常量。真实的窗口状态（普通/最大化/Snap）由
// [DesktopWindow.shape] 提供，原生在应用窗口区域后才推送；半径因此与真实窗口形状
// 永远同步：普通窗口 18 DIP 圆角，最大化/Snap 半径 0（直角，只保留一条灰色直边）。
//
// 该组件必须位于 MaterialApp.builder 中、Navigator/Overlay 之外，才能同时约束弹窗与
// 菜单；并且绘制层在 child 之上，所以全屏遮罩盖不住描边。
//
// 主要类型：cubicWindowPath、WindowOutlineClipper、WindowOutlinePainter、WindowSurface。

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'desktop_window.dart';
import 'theme/values.dart';
import 'window_probe/alpha_probe.dart';

/// 标准圆角的三次贝塞尔近似系数（四分之一圆，k = 4/3 * (sqrt(2) - 1)）。
///
/// 这是“标准圆角”的近似曲线，不是精确圆弧，也不是连续曲率的超椭圆；原生
/// `window_region.h` 使用同一个系数，两层轮廓因此重合。
const double kWindowBezierK = 0.5522847498307936;

/// 生成整窗外轮廓 Path（相对 [box] 左上角，顺时针）。
///
/// 半径先按短边一半夹紧；`radius <= 0` 时退化为矩形（最大化/Snap 的直角状态）。
Path cubicWindowPath(Rect box, double requestedRadius) {
  if (box.isEmpty) return Path();
  final limit = math.min(box.width, box.height) / 2;
  final r = requestedRadius.isFinite
      ? requestedRadius.clamp(0.0, limit).toDouble()
      : 0.0;
  if (r <= 0) {
    return Path()..addRect(box);
  }
  final c = r * kWindowBezierK;
  final l = box.left, t = box.top, e = box.right, b = box.bottom;
  return Path()
    ..fillType = PathFillType.nonZero
    ..moveTo(l + r, t)
    ..lineTo(e - r, t)
    ..cubicTo(e - r + c, t, e, t + r - c, e, t + r)
    ..lineTo(e, b - r)
    ..cubicTo(e, b - r + c, e - r + c, b, e - r, b)
    ..lineTo(l + r, b)
    ..cubicTo(l + r - c, b, l, b - r + c, l, b - r)
    ..lineTo(l, t + r)
    ..cubicTo(l, t + r - c, l + r - c, t, l + r, t)
    ..close();
}

/// 把应用表面裁剪到整窗外轮廓。
class WindowOutlineClipper extends CustomClipper<Path> {
  const WindowOutlineClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) => cubicWindowPath(Offset.zero & size, radius);

  @override
  bool shouldReclip(WindowOutlineClipper oldClipper) =>
      oldClipper.radius != radius;
}

/// 在轮廓内侧绘制描边。
///
/// 路径整体内缩 `strokeWidth / 2`，因此描边完整落在可绘制区域内，不会被窗口边缘裁掉
/// 一半；[hitTest] 返回 false，纯装饰不接收指针事件。半径为 0 时就是沿四条直边画的
/// 一条灰线（最大化/Snap，只有一条边，不重复）。
class WindowOutlinePainter extends CustomPainter {
  const WindowOutlinePainter({
    required this.radius,
    required this.strokeWidth,
    required this.color,
  });

  final double radius;
  final double strokeWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0) return;
    final box = (Offset.zero & size).deflate(strokeWidth / 2);
    if (box.isEmpty) return;
    final path = cubicWindowPath(
      box,
      math.max(0.0, radius - strokeWidth / 2),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..isAntiAlias = true,
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(WindowOutlinePainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.color != color;
}

/// 整个顶层窗口的应用表面：共享路径裁剪 + 内侧灰色描边。
///
/// 上层必须给出紧约束（应用根节点的约束就是整个 Flutter 表面），因此这里的
/// `CustomPaint` 正好覆盖整窗。不要把它放进 `Scaffold.body`。
///
/// [shape] 提供真实窗口状态时，圆角半径随状态变化（普通 18 DIP / 最大化与 Snap 0）；
/// 为空时使用固定的 [radius]（组件测试用）。
class WindowSurface extends StatefulWidget {
  const WindowSurface({
    super.key,
    required this.child,
    this.shape,
    this.background,
    this.border,
    this.radius = TsWindowShape.radius,
  });

  final Widget child;

  /// 真实窗口状态来源；为 null 时外形固定为 [radius]。
  final ValueListenable<WindowShape>? shape;

  /// 窗口底色；默认取主题 surface，和标题栏/主区一致，避免边缘出现别的颜色。
  final Color? background;

  /// 描边颜色；默认按当前明暗主题取中性灰令牌。
  final Color? border;

  final double radius;

  @override
  State<WindowSurface> createState() => _WindowSurfaceState();
}

class _WindowSurfaceState extends State<WindowSurface> {
  AppLifecycleListener? _lifecycle;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    // 失焦时只降低描边对比度，不取消描边：用户仍能看出窗口边界。
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final focused = state == AppLifecycleState.resumed;
        if (focused != _focused && mounted) {
          setState(() => _focused = focused);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /*
     * R3-V V3 验收实验入口：只有 TASKSCHEDULER_ALPHA_PROBE 被设置时才走透明探针
     * 外壳（透明根 + alpha 探针条 + 关闭原生 Region）。正常用户运行不会设置该
     * 环境变量，因此生产路径与之前完全一致。见 window_probe/alpha_probe.dart。
     */
    if (WindowAlphaProbe.enabled) {
      return WindowAlphaProbeShell(
        radius: widget.radius,
        child: widget.child,
      );
    }
    final listenable = widget.shape;
    if (listenable == null) {
      return _surface(context, widget.radius);
    }
    return ValueListenableBuilder<WindowShape>(
      valueListenable: listenable,
      builder: (context, shape, _) {
        final radius = shape.radiusDip.isFinite
            ? shape.radiusDip.clamp(0.0, widget.radius).toDouble()
            : widget.radius;
        return _surface(context, radius);
      },
    );
  }

  Widget _surface(BuildContext context, double radius) {
    final theme = Theme.of(context);
    final background = widget.background ?? theme.colorScheme.surface;
    final baseBorder = widget.border ?? TsWindowShape.borderFor(theme.brightness);
    final border = _focused
        ? baseBorder
        : Color.lerp(baseBorder, background, TsWindowShape.inactiveBlend) ??
            baseBorder;
    final strokeWidth = TsWindowShape.strokeWidth(
      MediaQuery.devicePixelRatioOf(context),
    );

    /*
     * 顺序很重要：底色铺满整个矩形，裁剪只作用于内容，描边画在最上层。
     *
     * 如果反过来先裁剪再铺底色，窗口 Region 的二值边界与 Flutter 的抗锯齿裁剪之间会
     * 露出约 1 物理像素的“未绘制”区域；DWM 合成时那里会变黑，四角出现暗色毛边。
     * 底色铺满后，落在 Region 内但在抗锯齿边缘上的像素是窗口底色而不是透明，原生硬
     * 边界看起来就是灰色描边本身。
     */
    final clipped = radius <= 0.5
        ? widget.child
        : ClipPath(
            clipper: WindowOutlineClipper(radius),
            clipBehavior: Clip.antiAlias,
            child: widget.child,
          );
    return ColoredBox(
      color: background,
      child: CustomPaint(
        foregroundPainter: WindowOutlinePainter(
          radius: radius,
          strokeWidth: strokeWidth,
          color: border,
        ),
        child: clipped,
      ),
    );
  }
}
