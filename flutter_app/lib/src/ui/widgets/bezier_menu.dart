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
//
// What lives here (0.5.0 task 02 — one menu implementation for every new control):
//   * [showBezierMenu] — the popup itself: theme rows, viewport-clamped height with
//     internal scrolling, ↑/↓/Home/End + Enter/Space + Esc/Tab keyboard handling;
//   * [BezierMenuTrigger] — a focus-owning trigger that opens the popup and returns focus
//     to itself afterwards (so Tab continues from the trigger);
//   * [BezierMenuSelect] — the ready-made outlined "select" trigger (current value +
//     chevron) used wherever the old `DropdownButton` was bare.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// Marks the currently effective value: a check mark and accent text. Used by the
  /// dropdown-style menus (review filters, schedule filters) to show the current item.
  final bool selected;

  const BezierMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
    this.danger = false,
    this.dividerBefore = false,
    this.shortcut,
    this.selected = false,
  });
}

const double _kMenuRowHeight = 40;
const double _kMenuPaddingV = 6;
const double _kMenuWidth = 220;

/// The tallest a popup may grow before it starts scrolling. The real cap is
/// min(this, viewport height - 16), so a short window shrinks the menu instead of
/// pushing it off-screen.
const double kBezierMenuMaxHeight = 480;

/// Shows [items] anchored at [globalPosition].
///
/// Returns the chosen value, or null when dismissed (outside click / Esc / back).
///
/// The panel opens below the anchor and flips above it when there is not enough room.
/// Its height is capped by the viewport (or [maxHeight] when given); taller menus scroll
/// internally, and keyboard ↑/↓ keeps the highlighted row visible.
///
/// [anchorRect] is the optional trigger rectangle (overlay coordinates). When given, the
/// menu opens just below/beside that rectangle with [gap] and never covers the trigger;
/// [globalPosition] is then only a fallback. [BezierMenuTrigger] passes it automatically.
///
/// Note: because "dismissed" and "null value" are indistinguishable here, nullable
/// selections (for example an "全部会话" row whose value is null) must go through
/// [BezierMenuTrigger] / [BezierMenuSelect], which wrap the value and therefore can
/// report a real null pick.
Future<T?> showBezierMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<BezierMenuItem<T>> items,
  double width = _kMenuWidth,
  double? maxHeight,
  Rect? anchorRect,
  double gap = 4,
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
  final contentHeight = items.length * rowHeight +
      _kMenuPaddingV * 2 +
      dividers;
  // Never taller than the visible area: with a small window the menu scrolls rather
  // than being clamped at a negative/zero top.
  final limit =
      maxHeight ?? math.min(kBezierMenuMaxHeight, screen.height - 16);
  final panelHeight = math.min(contentHeight, math.max(limit, rowHeight * 2));

  final maxLeft = math.max(8.0, screen.width - width - 8.0);
  double left;
  double top;
  final anchor = anchorRect;
  if (anchor == null) {
    left = globalPosition.dx.clamp(8.0, maxLeft).toDouble();
    // Prefer opening below the anchor; flip up when there is not enough room, which keeps
    // the menu on screen next to a conversation card near the bottom edge.
    top = globalPosition.dy;
    if (top + panelHeight > screen.height - 8) {
      top = globalPosition.dy - panelHeight;
    }
  } else {
    // Trigger-aware placement: open fully below or fully above the anchor rect, with a
    // small gap, so the menu never covers the control that owns it (“＋”, a drop-down).
    left = anchor.left.clamp(8.0, maxLeft).toDouble();
    final below = anchor.bottom + gap;
    final above = anchor.top - gap - panelHeight;
    if (below + panelHeight <= screen.height - 8) {
      top = below;
    } else if (above >= 8) {
      top = above;
    } else {
      // Not enough room either way (tiny window): stay on screen; the panel scrolls.
      top = below;
    }
  }
  top = top.clamp(8.0, math.max(8.0, screen.height - panelHeight - 8.0)).toDouble();

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
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: panelHeight),
            child: _BezierMenuPanel<T>(
              items: items,
              rowHeight: rowHeight,
              onSelected: (value) => Navigator.of(menuContext).pop(value),
            ),
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

class _BezierMenuPanel<T> extends StatefulWidget {
  final List<BezierMenuItem<T>> items;
  final double rowHeight;
  final ValueChanged<T> onSelected;

  const _BezierMenuPanel({
    required this.items,
    required this.rowHeight,
    required this.onSelected,
  });

  @override
  State<_BezierMenuPanel<T>> createState() => _BezierMenuPanelState<T>();
}

class _BezierMenuPanelState<T> extends State<_BezierMenuPanel<T>> {
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _rowKeys = <GlobalKey>[];

  /// Index of the keyboard-highlighted row, or null when no row can be picked.
  int? _highlight;

  @override
  void initState() {
    super.initState();
    _rowKeys.addAll(
        List<GlobalKey>.generate(widget.items.length, (_) => GlobalKey()));
    _highlight = _firstSelectableIndex();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _selectable(int index) {
    final item = widget.items[index];
    return item.enabled;
  }

  /// Prefer the current value as the starting point, like a native select.
  int? _firstSelectableIndex() {
    final selected = widget.items.indexWhere((i) => i.selected && i.enabled);
    if (selected >= 0) return selected;
    final first = widget.items.indexWhere((i) => i.enabled);
    return first >= 0 ? first : null;
  }

  void _moveHighlight(int delta) {
    if (widget.items.isEmpty) return;
    var index = _highlight ?? -1;
    for (var step = 0; step < widget.items.length; step++) {
      index = (index + delta) % widget.items.length;
      if (index < 0) index += widget.items.length;
      if (_selectable(index)) {
        setState(() => _highlight = index);
        _reveal(index);
        return;
      }
    }
  }

  void _edgeHighlight({required bool last}) {
    if (!widget.items.any((item) => item.enabled)) return;
    var index = last ? widget.items.length - 1 : 0;
    while (index >= 0 && index < widget.items.length && !_selectable(index)) {
      index += last ? -1 : 1;
    }
    if (index < 0 || index >= widget.items.length) return;
    setState(() => _highlight = index);
    _reveal(index);
  }

  /// Keep the keyboard-highlighted row inside the scrollable viewport.
  void _reveal(int index) {
    if (index < 0 || index >= _rowKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys[index].currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 80),
      );
    });
  }

  void _activateHighlighted() {
    final index = _highlight;
    if (index == null || !_selectable(index)) return;
    widget.onSelected(widget.items[index].value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _edgeHighlight(last: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _edgeHighlight(last: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _activateHighlighted();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.tab) {
      // Esc / Tab dismiss back to the trigger; the route restores its focus.
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (item.dividerBefore) {
        rows.add(Divider(height: 1, thickness: 1, color: TsColors.border));
      }
      rows.add(_BezierMenuRow<T>(
        key: _rowKeys[i],
        item: item,
        height: widget.rowHeight,
        keyboardHighlighted: _highlight == i,
        onHover: () => setState(() => _highlight = i),
        onSelected: () => widget.onSelected(item.value),
      ));
    }
    return Focus(
      key: const Key('bezier-menu-focus'),
      autofocus: true,
      onKeyEvent: _onKey,
      child: Material(
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
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ),
    );
  }
}

class _BezierMenuRow<T> extends StatefulWidget {
  final BezierMenuItem<T> item;
  final double height;
  final bool keyboardHighlighted;
  final VoidCallback onHover;
  final VoidCallback onSelected;

  const _BezierMenuRow({
    super.key,
    required this.item,
    required this.height,
    required this.keyboardHighlighted,
    required this.onHover,
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
        : (item.danger
            ? TsColors.blocked
            : (item.selected ? TsColors.accent : TsColors.textPrimary));
    // Keyboard highlight is a clear focus ring; hover is the quieter surface tint. Both
    // use theme values only — no per-page colour.
    final decoration = !item.enabled
        ? null
        : (widget.keyboardHighlighted
            ? bezierDecoration(
                color: TsColors.accentSoft,
                radius: 8,
                border: Border.all(color: TsColors.accent, width: 1.2),
              )
            : (_hover
                ? bezierDecoration(color: TsColors.surfaceAlt, radius: 8)
                : null));
    final content = Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: decoration,
      child: Row(
        children: [
          if (item.icon != null) ...[
            Icon(item.icon, size: 17, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Tooltip(
              // Long conversation / task names are ellipsized in the row; hovering still
              // lets the user read the full value without widening the popup.
              message: item.label,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
          ),
          if (item.selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, size: 16, color: TsColors.accent),
          ],
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
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onHover();
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelected,
        child: content,
      ),
    );
  }
}

// ---------------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------------

/// Lets a menu carry a nullable value: [showBezierMenu] cannot distinguish "picked
/// null" from "dismissed", so triggers wrap every pick in [_MenuChoice].
class _MenuChoice<T> {
  final T value;

  const _MenuChoice(this.value);
}

/// A focus-owning trigger for [showBezierMenu].
///
/// * clicking, Enter or Space opens the menu anchored at the trigger's bottom-left;
/// * the trigger keeps focus while the menu is open and gets it back after the menu
///   closes, so Tab continues from the trigger (not from the top of the page);
/// * [childBuilder] receives the open/focused state so the caller can paint the
///   “selected while open” state with theme values;
/// * selecting a row with a null value is reported correctly (via [_MenuChoice]) —
///   this is what the review/schedule “全部…” rows need.
class BezierMenuTrigger<T> extends StatefulWidget {
  final Widget? child;

  /// When given, overrides [child] and receives `(context, open, focused)`.
  final Widget Function(BuildContext context, bool open, bool focused)?
      childBuilder;
  final List<BezierMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final double menuWidth;
  final double? menuMaxHeight;
  final bool enabled;
  final FocusNode? focusNode;
  final String? tooltip;

  const BezierMenuTrigger({
    super.key,
    this.child,
    this.childBuilder,
    required this.items,
    required this.onSelected,
    this.menuWidth = _kMenuWidth,
    this.menuMaxHeight,
    this.enabled = true,
    this.focusNode,
    this.tooltip,
  }) : assert(child != null || childBuilder != null,
            'BezierMenuTrigger needs a child or a childBuilder');

  @override
  State<BezierMenuTrigger<T>> createState() => _BezierMenuTriggerState<T>();
}

class _BezierMenuTriggerState<T> extends State<BezierMenuTrigger<T>> {
  FocusNode? _ownedFocus;
  bool _open = false;
  bool _focused = false;

  FocusNode get _focusNode => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  Future<void> _openMenu() async {
    if (!mounted || !widget.enabled || _open || widget.items.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || overlayBox == null) return;
    _focusNode.requestFocus();
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    setState(() => _open = true);
    final choice = await showBezierMenu<_MenuChoice<T>>(
      context: context,
      globalPosition: topLeft + Offset(0, box.size.height),
      anchorRect: topLeft & box.size,
      width: widget.menuWidth,
      maxHeight: widget.menuMaxHeight,
      items: <BezierMenuItem<_MenuChoice<T>>>[
        for (final item in widget.items)
          BezierMenuItem<_MenuChoice<T>>(
            value: _MenuChoice<T>(item.value),
            label: item.label,
            icon: item.icon,
            enabled: item.enabled,
            danger: item.danger,
            dividerBefore: item.dividerBefore,
            shortcut: item.shortcut,
            selected: item.selected,
          ),
      ],
    );
    if (!mounted) return;
    setState(() => _open = false);
    // The route normally restores this focus already; doing it explicitly also covers
    // keyboard dismissal and keeps Tab traversal starting at the trigger.
    _focusNode.requestFocus();
    if (choice != null) widget.onSelected(choice.value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final visual = widget.childBuilder?.call(context, _open, _focused) ??
        widget.child!;
    Widget trigger = Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.enabled,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? _openMenu : null,
          child: visual,
        ),
      ),
    );
    if (widget.tooltip != null) {
      trigger = Tooltip(message: widget.tooltip!, child: trigger);
    }
    return trigger;
  }
}

/// The standard “select” trigger used where a bare `DropdownButton` used to be.
///
/// It shows the current value plus a chevron and uses the same default / hover / focus /
/// open / disabled states as [TsButtons.outline]: surface fill, hairline border, primary
/// text; hover and keyboard focus darken the border; an open menu keeps the accent border
/// and soft accent fill; a disabled trigger is muted and inert.
class BezierMenuSelect<T> extends StatelessWidget {
  /// Text of the current value (already formatted by the caller, e.g. “全部会话”).
  final String label;
  final List<BezierMenuItem<T>> items;
  final ValueChanged<T> onSelected;

  /// Fixed trigger width. Null shrink-wraps between [minWidth] and [maxWidth].
  final double? width;
  final double minWidth;
  final double maxWidth;
  final double menuWidth;
  final bool enabled;
  final String? tooltip;
  final FocusNode? focusNode;
  final IconData? icon;

  /// Compact variant for dense toolbar rows (28 px instead of 30 px).
  final bool dense;

  const BezierMenuSelect({
    super.key,
    required this.label,
    required this.items,
    required this.onSelected,
    this.width,
    this.minWidth = 120,
    this.maxWidth = 280,
    this.menuWidth = 280,
    this.enabled = true,
    this.tooltip,
    this.focusNode,
    this.icon,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final height = dense ? 28.0 : 30.0;
    return BezierMenuTrigger<T>(
      items: items,
      onSelected: onSelected,
      enabled: enabled,
      menuWidth: menuWidth,
      focusNode: focusNode,
      tooltip: tooltip,
      childBuilder: (context, open, focused) => _SelectVisual(
        label: label,
        icon: icon,
        open: open,
        focused: focused,
        enabled: enabled,
        height: height,
        width: width,
        minWidth: minWidth,
        maxWidth: maxWidth,
      ),
    );
  }
}

/// The painted select trigger. It owns the hover state so default / hover / focus / open
/// / disabled all read differently while using only theme values.
class _SelectVisual extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool open;
  final bool focused;
  final bool enabled;
  final double height;
  final double? width;
  final double minWidth;
  final double maxWidth;

  const _SelectVisual({
    required this.label,
    required this.open,
    required this.focused,
    required this.enabled,
    required this.height,
    required this.minWidth,
    required this.maxWidth,
    this.icon,
    this.width,
  });

  @override
  State<_SelectVisual> createState() => _SelectVisualState();
}

class _SelectVisualState extends State<_SelectVisual> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final open = widget.open;
    final textColor = enabled ? TsColors.textPrimary : TsColors.onButtonDisabled;
    final chevronColor =
        enabled ? TsColors.textFaint : TsColors.onButtonDisabled;
    final borderColor = !enabled
        ? TsColors.border
        : (open
            ? TsColors.accent
            : (widget.focused || _hover ? TsColors.borderStrong : TsColors.border));
    final fill = !enabled
        ? TsColors.surfaceAlt
        : (open
            ? TsColors.accentSoft
            : (_hover ? TsColors.surfaceAlt : TsColors.surface));
    final body = Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: bezierDecoration(
        color: fill,
        radius: 9,
        border: Border.all(color: borderColor, width: open ? 1.2 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 14, color: chevronColor),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: textColor),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 16, color: chevronColor),
        ],
      ),
    );
    final sized = widget.width != null
        ? SizedBox(width: widget.width, child: body)
        : ConstrainedBox(
            constraints:
                BoxConstraints(minWidth: widget.minWidth, maxWidth: widget.maxWidth),
            child: body,
          );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: sized,
    );
  }
}
