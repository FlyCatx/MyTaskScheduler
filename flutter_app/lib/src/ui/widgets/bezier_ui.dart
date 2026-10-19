// 共享的圆角贝塞尔几何：路径、边框、输入框轮廓、裁剪与分段控件绘制都走 bezierRectPath。
// 圆形元素（状态点、头像等）不经过本文件——圆不是圆角矩形。
//
// 主要类型/函数：bezierRectPath、bezierDecoration、BezierRoundedRectangleBorder、
// BezierInputBorder、BezierRoundedClipper、BezierSegments、SegmentControlGeometry。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 依赖方向：只引用样式值（theme/values.dart），不引用主题装配，因此不会成环。
import '../theme/values.dart';

Path bezierRectPath(Rect rect, double radius) {
  if (rect.isEmpty) return Path();
  final r = radius
      .clamp(0.0, math.min(rect.width, rect.height) / 2)
      .toDouble();
  if (r <= 0) {
    return Path()..addRect(rect);
  }
  final cx = r * 0.675;
  final cx1 = 0.000155 * cx;
  final l = rect.left, t = rect.top, b = rect.bottom, e = rect.right;
  return Path()
    ..fillType = PathFillType.nonZero
    ..moveTo(l + r, t)
    ..lineTo(e - r, t)
    ..cubicTo(e - r + cx, t + cx1, e - cx1, t + r - cx, e, t + r)
    ..lineTo(e, b - r)
    ..cubicTo(e - cx1, b - r + cx, e - r + cx, b - cx1, e - r, b)
    ..lineTo(l + r, b)
    ..cubicTo(l + r - cx, b - cx1, l + cx1, b - r + cx, l, b - r)
    ..lineTo(l, t + r)
    ..cubicTo(l + cx1, t + r - cx, l + r - cx, t + cx1, l + r, t)
    ..close();
}

/// Outer border used by Material, buttons, cards, menus and InkWell.customBorder.
class BezierRoundedRectangleBorder extends OutlinedBorder {
  const BezierRoundedRectangleBorder({
    super.side,
    this.radius = 12,
  });

  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      bezierRectPath(rect, radius);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => bezierRectPath(
        rect.deflate(side.width),
        math.max(0, radius - side.width),
      );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) return;
    canvas.drawPath(getOuterPath(rect, textDirection: textDirection), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) => BezierRoundedRectangleBorder(
        side: side.scale(t),
        radius: radius * t,
      );

  @override
  OutlinedBorder copyWith({BorderSide? side, double? radius}) =>
      BezierRoundedRectangleBorder(
        side: side ?? this.side,
        radius: radius ?? this.radius,
      );

  @override
  bool operator ==(Object other) =>
      other is BezierRoundedRectangleBorder &&
      other.side == side &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(side, radius);
}

/// InputDecorator border. It uses the same path for fill and outline, so focus,
/// error and disabled states cannot drift to a different corner geometry.
class BezierInputBorder extends InputBorder {
  const BezierInputBorder({
    super.borderSide = BorderSide.none,
    this.radius = 12,
  });

  final double radius;

  @override
  bool get isOutline => true;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      bezierRectPath(rect, radius);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      bezierRectPath(rect.deflate(borderSide.width), math.max(0, radius - borderSide.width));

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none || borderSide.width <= 0) return;
    canvas.drawPath(getOuterPath(rect, textDirection: textDirection), borderSide.toPaint());
  }

  @override
  BezierInputBorder copyWith({
    BorderSide? borderSide,
    double? radius,
  }) =>
      BezierInputBorder(
        borderSide: borderSide ?? this.borderSide,
        radius: radius ?? this.radius,
      );

  @override
  InputBorder scale(double t) =>
      BezierInputBorder(borderSide: borderSide.scale(t), radius: radius * t);

  @override
  bool operator ==(Object other) =>
      other is BezierInputBorder &&
      other.borderSide == borderSide &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(borderSide, radius);
}

class BezierRoundedClipper extends CustomClipper<Path> {
  final double radius;
  const BezierRoundedClipper(this.radius);

  @override
  Path getClip(Size size) => bezierRectPath(Offset.zero & size, radius);

  @override
  bool shouldReclip(covariant BezierRoundedClipper oldClipper) =>
      oldClipper.radius != radius;
}

/// Converts the old `BoxDecoration(borderRadius: ...)` idiom to the shared shape.
/// Callers keep their colour, gradient, image and shadows; only the corner geometry
/// changes. Non-uniform borders are not representable by ShapeDecoration and should
/// keep a BoxDecoration (e.g. a deliberate underline).
ShapeDecoration bezierDecoration({
  Color? color,
  Gradient? gradient,
  DecorationImage? image,
  Border? border,
  double radius = 12,
  List<BoxShadow>? boxShadow,
}) {
  final side = _sideOf(border);
  return ShapeDecoration(
    color: color,
    gradient: gradient,
    image: image,
    shadows: boxShadow,
    shape: BezierRoundedRectangleBorder(side: side, radius: radius),
  );
}

BorderSide _sideOf(Border? border) {
  if (border == null) return BorderSide.none;
  for (final side in <BorderSide>[
    border.top,
    border.right,
    border.bottom,
    border.left,
  ]) {
    if (side.style != BorderStyle.none && side.width > 0) return side;
  }
  return BorderSide.none;
}


/// The single spacing value used on every perpendicular edge of the control.
///
/// It appears exactly once in the geometry below: the track is the whole box, every
/// item rect is inset by [kSegmentGap] on all four sides, and the moving block covers
/// that item rect at rest. There is no second "5px padding", "6px block inset" or
/// "4px y offset" anywhere — that was the 0.05 bug.
const double kSegmentGap = 4;

/// Immutable geometry of one segmented control.
///
/// Built once per layout from the *actual* available width, then handed to the painter,
/// the label slots and the hit-test rects. The 0.05 implementation computed the slot
/// width twice (once for the `Row` of labels, once inside the painter from
/// `size.width`); when a parent handed down a tight width the declared `SizedBox`
/// width was overridden, the painter used the real width and the labels kept the
/// smaller one — the highlighted block and the text sat in different places.
class SegmentControlGeometry {
  const SegmentControlGeometry({
    required this.width,
    required this.trackHeight,
    required this.count,
  })  : assert(count >= 1),
        assert(trackHeight > 0);

  /// Width of the whole control, i.e. of the track rectangle.
  final double width;

  /// Height of the track rectangle (`height` on the widget).
  final double trackHeight;

  final int count;

  /// Outer height including the gap above and below the track. The widget's box *is*
  /// the track in x, and is the track plus both gaps in y, so nothing is painted
  /// outside the box and nothing is painted with an unexplained offset.
  double get height => trackHeight + kSegmentGap * 2;

  /// Inner usable width (track minus both side gaps), split evenly by the items.
  double get innerWidth => math.max(0.0, width - kSegmentGap * 2);

  double get slotWidth =>
      count == 0 ? innerWidth : math.max(1.0, innerWidth / count);

  Rect get track => Rect.fromLTWH(0, 0, math.max(0.0, width), height);

  /// Fixed click rect **and** text slot of item [index]; identical on every axis.
  Rect slotAt(int index) {
    final i = index.clamp(0, math.max(0, count - 1));
    return Rect.fromLTWH(
      kSegmentGap + i * slotWidth,
      kSegmentGap,
      slotWidth,
      math.max(1.0, trackHeight),
    );
  }

  /// The moving block for a fractional [position] (0 → first item, 1.5 → halfway
  /// between the second and third) and a 0..1 [pulse] scale.
  ///
  /// At rest (`pulse == 0`) the block is exactly [slotAt] of the nearest slot, which is
  /// what "静止时选中块与所选槽对齐" means. While animating, the block may only grow by
  /// [kSegmentGap] per side, so it can never leave the track or be clipped flat.
  Rect blockFor(double position, double pulse) {
    final p = pulse.clamp(0.0, 1.0).toDouble();
    final clamped = position
        .clamp(0.0, math.max(0.0, (count - 1).toDouble()))
        .toDouble();
    final lowIndex = clamped.floor().clamp(0, math.max(0, count - 1)).toInt();
    final highIndex =
        (lowIndex + 1).clamp(0, math.max(0, count - 1)).toInt();
    final t = clamped - lowIndex;
    final a = slotAt(lowIndex);
    final b = slotAt(highIndex);
    final base = Rect.fromLTRB(
      a.left + (b.left - a.left) * t,
      a.top,
      a.right + (b.right - a.right) * t,
      a.bottom,
    );
    if (p <= 0) return base;
    // Growth is capped by the gap and by a fraction of the block, whichever is
    // smaller: a wide control pulses mostly vertically (still clearly visible), a
    // narrow one pulses on both axes — and neither overflows the track.
    final growX = math.min(kSegmentGap, base.width * 0.08) * p;
    final growY = math.min(kSegmentGap, base.height * 0.14) * p;
    return Rect.fromLTRB(
      base.left - growX,
      base.top - growY,
      base.right + growX,
      base.bottom + growY,
    );
  }

  /// Convenience for tests and debug painting: the label/hit slot centre.
  Offset slotCenter(int index) => slotAt(index).center;
}

class BezierSegmentItem {
  final String label;
  final IconData? icon;
  const BezierSegmentItem(this.label, {this.icon});
}

/// A compact two-to-four item segmented control with a single animated blue block.
///
/// Every item gets an equal share of the host-provided width, its label centred inside
/// that share, and its click area equal to the same rectangle. Track and block are
/// painted with the shared Bézier path; labels and the track never move or scale.
class BezierSegments extends StatefulWidget {
  final List<BezierSegmentItem> items;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final double height;
  final double? itemWidth;
  final List<Key?>? itemKeys;

  /// Fill the host width (and split it equally) instead of shrink-wrapping to the
  /// widest label. Settings rows that own the full row width use this.
  final bool expand;

  const BezierSegments({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.height = 30,
    this.itemWidth,
    this.itemKeys,
    this.expand = false,
  })  : assert(items.length >= 2),
        assert(selected >= 0 && selected < items.length);

  @override
  State<BezierSegments> createState() => _BezierSegmentsState();
}

class _BezierSegmentsState extends State<BezierSegments>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late double _from;
  late double _to;
  double _startPulse = 0;
  bool _reduceMotion = false;
  int _hovered = -1;
  int _focused = -1;

  double get _progress => Curves.easeInOutCubic.transform(_controller.value);
  double get _position => _from + (_to - _from) * _progress;

  double get _pulse {
    final t = _controller.value;
    if (t < 0.5) {
      return _startPulse +
          (1 - _startPulse) * Curves.easeInOutCubic.transform(t * 2);
    }
    return 1 - Curves.easeInOutCubic.transform((t - 0.5) * 2);
  }

  @override
  void initState() {
    super.initState();
    _from = _to = widget.selected.toDouble();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant BezierSegments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _from = _to = widget.selected.toDouble();
      _controller.value = 1;
    } else if (oldWidget.selected != widget.selected) {
      // Continue from whatever is visible right now: a fast back-and-forth must not
      // snap the block to the old slot first.
      final current = _position;
      final pulse = _pulse;
      _from = current;
      _to = widget.selected.toDouble();
      _startPulse = pulse;
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  TextStyle _labelStyle(BuildContext context, {Color? color}) => TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        fontSize: widget.height >= 38 ? 13 : 11.5,
        fontWeight: FontWeight.w600,
        color: color,
      );

  double _intrinsicSlot(BuildContext context) {
    if (widget.itemWidth != null && widget.itemWidth! > 0) {
      return widget.itemWidth!;
    }
    var widest = 0.0;
    for (final item in widget.items) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: _labelStyle(context)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final iconWidth = item.icon == null ? 0.0 : 19.0;
      widest = math.max(
        widest,
        painter.width + iconWidth + (widget.height >= 38 ? 32 : 24),
      );
    }
    return math.max(52, widest);
  }

  void _select(int index) {
    if (!widget.enabled) return;
    // Clicking the already selected item must not fire a redundant callback.
    if (index == widget.selected) return;
    widget.onChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    final textColor = TsColors.textSecondary;
    final desiredWidth = _intrinsicSlot(context) * widget.items.length +
        kSegmentGap * 2;

    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      double width;
      if (maxWidth.isFinite) {
        width = widget.expand ? maxWidth : math.min(desiredWidth, maxWidth);
      } else {
        width = desiredWidth;
      }
      final geometry = SegmentControlGeometry(
        width: width,
        trackHeight: widget.height,
        count: widget.items.length,
      );

      return Align(
        alignment: AlignmentDirectional.centerStart,
        // `widthFactor: 1` is essential: without it Align expands to the *whole*
        // available width, so inside a `Wrap` the segmented control consumed an entire
        // run and every toolbar button was pushed onto the next line (0.06 bug). With
        // it, the box is exactly as wide as the painted control, and `expand: true`
        // still fills the host width because the inner SizedBox already does.
        widthFactor: 1,
        child: SizedBox(
          width: geometry.width,
          height: geometry.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => CustomPaint(
                      painter: _SegmentPainter(
                        geometry: geometry,
                        position: _position,
                        pulse: _pulse,
                        enabled: widget.enabled,
                        radius: widget.height * 0.34,
                      ),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < widget.items.length; i++)
                Positioned.fromRect(
                  rect: geometry.slotAt(i),
                  child: _slot(context, i, textColor),
                ),
            ],
          ),
        ),
      );
    });
  }

  Widget _slot(
    BuildContext context,
    int i,
    Color textColor,
  ) {
    final item = widget.items[i];
    final selected = i == widget.selected;
    final highlighted = !selected && (i == _hovered || i == _focused);
    return Semantics(
      selected: selected,
      button: true,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = i),
        onExit: (_) => setState(() {
          if (_hovered == i) _hovered = -1;
        }),
        child: Focus(
          canRequestFocus: widget.enabled,
          onFocusChange: (focused) => setState(() {
            if (focused) {
              _focused = i;
            } else if (_focused == i) {
              _focused = -1;
            }
          }),
          onKeyEvent: (node, event) {
            if (!widget.enabled || event is! KeyDownEvent) {
              return KeyEventResult.ignored;
            }
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space) {
              _select(i);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            key: widget.itemKeys?[i],
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? () => _select(i) : null,
            child: Container(
              decoration: highlighted
                  ? bezierDecoration(
                      color: TsColors.textPrimary.withValues(alpha: 0.05),
                      radius: widget.height * 0.30,
                    )
                  : null,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (item.icon != null) ...[
                    Icon(
                      item.icon,
                      size: 14,
                      color: selected ? TsColors.onButton : textColor,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: _labelStyle(
                        context,
                        color: selected ? TsColors.onButton : textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentPainter extends CustomPainter {
  final SegmentControlGeometry geometry;
  final double position;
  final double pulse;
  final bool enabled;
  final double radius;

  const _SegmentPainter({
    required this.geometry,
    required this.position,
    required this.pulse,
    required this.enabled,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The painter is given the same geometry object the layout used; it never derives
    // a slot from `size` on its own.
    final g = SegmentControlGeometry(
      width: size.width,
      trackHeight: size.height - kSegmentGap * 2,
      count: geometry.count,
    );
    canvas.drawPath(
      bezierRectPath(g.track, g.height / 2),
      // Unselected track comes from the palette (it was a hard-coded light grey, so a
      // themed switch/slider and this control disagreed about "neutral").
      Paint()..color = TsColors.track,
    );
    final block = g.blockFor(position, pulse).intersect(g.track);
    if (block.isEmpty) return;
    canvas.drawPath(
      bezierRectPath(block, radius),
      // Same "selected" blue as Switch / Slider / Checkbox / solid buttons.
      Paint()
        ..color = enabled
            ? TsColors.selected
            : TsColors.selectedDisabled,
    );
  }

  @override
  bool shouldRepaint(covariant _SegmentPainter old) =>
      geometry.width != old.geometry.width ||
      geometry.height != old.geometry.height ||
      geometry.count != old.geometry.count ||
      position != old.position ||
      pulse != old.pulse ||
      enabled != old.enabled ||
      radius != old.radius;
}

