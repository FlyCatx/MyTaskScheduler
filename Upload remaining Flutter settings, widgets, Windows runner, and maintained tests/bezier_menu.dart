// The one popup-menu style used everywhere in the product.
//
// Why not `showMenu` / `PopupMenuButton`:
//   * `showMenu` picks its own elevation, shape, padding and *animate-in* behaviour, so
//     the conversation menu looked different from the settings (user) menu no matter how
//     much of its `PopupMenuTheme` was overridden;
//   * the settings menu is drawn by hand: theme surface colour, hairline border, Bézier
//     corners, uniform 40 px rows, **no shadow, no tint**;
//   * it also gave a scale/size animation. The requirement is a short opacity fade only
//     (120–180 ms), with no scaling, bounce, size expansion or position slide.
//
// `showGeneralDialog` + `FadeTransition` gives exactly that: a plain route whose only
// transition is opacity, an outside-click barrier, Esc handling and focus restoration for
// free, and the overlay is removed by the route machinery *after* the fade-out finishes.
// The menu content itself is a flat `Material(elevation: 0)` with a 1 px border.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'bezier_ui.dart';
import '../theme.dart';

/// One row of a [showBezierMenu] popup.
class BezierMenuItem<T> {
  final T value;
  final String label;
  final IconData? icon;

  /// When false the row is drawn muted and cannot be picked (still visible, so the user
  /// can see the action exists but is unavailable).
  final bool enabled;

  /// Destructive rows use the danger colour and never the accent.
  final bool danger;

  /// A hairline separator drawn *before* this row.
  final bool dividerBefore;

  /// Right-aligned accelerator text (for example `Ctrl+Z`). Purely informational:
  /// the menu row does not synthesize key events.
  final String? shortcut;

  const BezierMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.danger = false,
    this.dividerBefore = false,
    this.shortcut,
  });
}

const double _kMenuRowHeight = 40;
const double _kMenuPaddingV = 6;
const double _kMenuWidth = 220;

/// Shows [items] anchored at [globalPosition].
///
/// Returns the chosen value, or null when dismissed (outside click / Esc / back).
Future<T?> showBezierMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<BezierMenuItem<T>> items,
  double width = _kMenuWidth,
}) {
  if (items.isEmpty) return Future<T?>.value(null);

  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final screen = overlayBox?.size ?? MediaQuery.sizeOf(context);
  // Text scale enlarges the rows, so the height used for edge clamping is measured the
  // same way the rows are laid out.
  final scale = MediaQuery.textScalerOf(context).scale(1);
  final rowHeight = _kMenuRowHeight * (scale > 1.3 ? 1.3 : scale);
  final dividers = items.where((i) => i.dividerBefore).length;
  final height = items.length * rowHeight +
      _kMenuPaddingV * 2 +
      dividers;

  final left = globalPosition.dx
      .clamp(8.0, math.max(8.0, screen.width - width - 8.0))
      .toDouble();
  // Prefer opening below the anchor; flip up when there is not enough room, which keeps
  // the menu on screen next to a conversation card near the bottom edge.
  var top = globalPosition.dy;
  if (top + height > screen.height - 8) {
    top = globalPosition.dy - height;
  }
  top = top.clamp(8.0, math.max(8.0, screen.height - height - 8.0)).toDouble();

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.transparent,
    // 150 ms: inside the requested 120–180 ms fade window.
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (menuContext, _, __) => Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: _BezierMenuPanel<T>(
            items: items,
            rowHeight: rowHeight,
            onSelected: (value) => Navigator.of(menuContext).pop(value),
          ),
        ),
      ],
    ),
    // Opacity only. No FadeTransition+ScaleTransition combo, no SizeTransition, no
    // slide: the requirement forbids every one of those for this menu.
    transitionBuilder: (menuContext, animation, _, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOut);
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _BezierMenuPanel<T> extends StatelessWidget {
  final List<BezierMenuItem<T>> items;
  final double rowHeight;
  final ValueChanged<T> onSelected;

  const _BezierMenuPanel({
    required this.items,
    required this.rowHeight,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final item in items) {
      if (item.dividerBefore) {
        rows.add(Divider(height: 1, thickness: 1, color: TsColors.border));
      }
      rows.add(_BezierMenuRow<T>(
        item: item,
        height: rowHeight,
        onSelected: onSelected,
      ));
    }
    return Material(
      key: const Key('bezier-menu-panel'),
      color: TsColors.surface,
      // Flat by design: a hairline border instead of a drop shadow.
      elevation: 0,
      shape: const BezierRoundedRectangleBorder(radius: 12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: bezierDecoration(
          radius: 12,
          border: Border.all(color: TsColors.border),
        ),
        padding: const EdgeInsets.symmetric(vertical: _kMenuPaddingV),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

class _BezierMenuRow<T> extends StatefulWidget {
  final BezierMenuItem<T> item;
  final double height;
  final ValueChanged<T> onSelected;

  const _BezierMenuRow({
    required this.item,
    required this.height,
    required this.onSelected,
  });

  @override
  State<_BezierMenuRow<T>> createState() => _BezierMenuRowState<T>();
}

class _BezierMenuRowState<T> extends State<_BezierMenuRow<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final color = !item.enabled
        ? TsColors.textFaint
        : (item.danger ? TsColors.blocked : TsColors.textPrimary);
    final content = Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: item.enabled && _hover
          ? bezierDecoration(color: TsColors.surfaceAlt, radius: 8)
          : null,
      child: Row(
        children: [
          if (item.icon != null) ...[
            Icon(item.icon, size: 17, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          if (item.shortcut != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                item.shortcut!,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.5,
                  color: item.enabled ? TsColors.textFaint : color,
                ),
              ),
            ),
        ],
      ),
    );

    if (!item.enabled) {
      // 惰性：没有指针、没有水波纹、没有悬停反馈；AbsorbPointer 同时避免
      // 点击“穿到”菜单外的遮罩把菜单关掉（禁用项应保持菜单打开）。
      return AbsorbPointer(child: content);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelected(item.value),
        child: content,
      ),
    );
  }
}
