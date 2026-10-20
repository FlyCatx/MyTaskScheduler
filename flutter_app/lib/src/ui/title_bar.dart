// 自绘标题栏（替换 Windows 原生标题栏的可见部分）。
//
// 布局：收起/展开侧边栏 · 「应用」菜单 · 「编辑」菜单 · 可拖动空白 · 最小化/最大化/关闭。
// 拖动区域通过 DesktopWindow 上报给 runner，由 Win32 以 HTCAPTION 处理，
// 因此窗口拖动、双击最大化/还原、Aero Snap、边缘缩放和 Alt+F4 都保持系统原生
// 行为；按钮与菜单不在拖动区域内。
//
// 主要类型：AppTitleBar、_CaptionButton、WindowSizeGlyph。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_window.dart';
import 'edit_commands.dart';
import 'theme.dart';
import 'widgets/bezier_menu.dart';
import 'widgets/bezier_ui.dart';

class AppTitleBar extends StatefulWidget {
  const AppTitleBar({
    super.key,
    required this.window,
    required this.sidebarVisible,
    required this.onToggleSidebar,
    required this.onOpenAbout,
    required this.onExit,
  });

  final DesktopWindow window;
  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;
  final VoidCallback onOpenAbout;
  final VoidCallback onExit;

  static const double height = 40;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> {
  final GlobalKey _dragKey = GlobalKey(debugLabel: 'titlebar-drag');
  final GlobalKey _appMenuKey = GlobalKey(debugLabel: 'titlebar-app-menu');
  final GlobalKey _editMenuKey = GlobalKey(debugLabel: 'titlebar-edit-menu');
  Rect? _lastRegion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDragRegion());
  }

  @override
  void didUpdateWidget(covariant AppTitleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDragRegion());
  }

  /// 把空白拖动区按物理像素上报；窗口缩放后重新计算。
  void _reportDragRegion() {
    if (!mounted) return;
    final box = _dragKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final region = Rect.fromLTWH(
      origin.dx * dpr,
      origin.dy * dpr,
      box.size.width * dpr,
      box.size.height * dpr,
    );
    if (region == _lastRegion) return;
    _lastRegion = region;
    widget.window.setDragRegion(region);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportDragRegion());
    return Container(
      height: AppTitleBar.height,
      decoration: BoxDecoration(
        color: TsColors.surface,
        border: Border(bottom: BorderSide(color: TsColors.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          _TitleIconButton(
            key: const Key('titlebar-sidebar-toggle'),
            icon: Icons.view_sidebar_outlined,
            tooltip: widget.sidebarVisible ? '收起侧边栏' : '展开侧边栏',
            onTap: widget.onToggleSidebar,
          ),
          const SizedBox(width: 2),
          _MenuAnchorButton(
            key: _appMenuKey,
            label: '应用',
            onPressed: _openAppMenu,
          ),
          _MenuAnchorButton(
            key: _editMenuKey,
            label: '编辑',
            onPressed: _openEditMenu,
          ),
          // 空白拖动区：不包含按钮、菜单和右侧窗口按钮。
          Expanded(
            child: SizedBox(
              key: _dragKey,
              height: AppTitleBar.height,
              child: const SizedBox.expand(),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: widget.window.maximized,
            builder: (context, maximized, _) => Row(
              children: [
                _CaptionButton(
                  key: const Key('titlebar-minimize'),
                  tooltip: '最小化',
                  onTap: widget.window.minimize,
                  type: _WindowGlyph.minimize,
                  color: TsColors.textSecondary,
                ),
                _CaptionButton(
                  key: const Key('titlebar-maximize'),
                  tooltip: maximized ? '还原' : '最大化',
                  onTap: widget.window.toggleMaximize,
                  type: maximized ? _WindowGlyph.restore : _WindowGlyph.maximize,
                  color: TsColors.textSecondary,
                ),
                _CaptionButton(
                  key: const Key('titlebar-close'),
                  tooltip: '关闭',
                  danger: true,
                  onTap: widget.window.requestClose,
                  type: _WindowGlyph.close,
                  color: TsColors.textSecondary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAppMenu() async {
    final box = _anchorBox(_appMenuKey);
    if (box == null) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final selected = await showBezierMenu<String>(
      context: context,
      globalPosition: origin,
      width: 232,
      items: const [
        BezierMenuItem(value: 'about', label: '关于 TaskScheduler'),
        // 检查更新尚未实现：灰色禁用，没有点击处理，也不发网络请求。
        BezierMenuItem(value: 'update', label: '检查更新…', enabled: false),
        BezierMenuItem(
            value: 'exit', label: '退出', dividerBefore: true, danger: true),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case 'about':
        widget.onOpenAbout();
        break;
      case 'exit':
        widget.onExit();
        break;
    }
  }

  Future<void> _openEditMenu() async {
    // 必须在菜单打开前捕获目标：菜单一打开，primaryFocus 就变成菜单本身。
    final session = EditMenuSession(captureEditTarget());
    final box = _anchorBox(_editMenuKey);
    if (box == null) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final selected = await showBezierMenu<EditCommand>(
      context: context,
      globalPosition: origin,
      width: 236,
      items: [
        BezierMenuItem(
          value: EditCommand.undo,
          label: '撤销',
          shortcut: 'Ctrl+Z',
          enabled: session.enabled(EditCommand.undo),
        ),
        BezierMenuItem(
          value: EditCommand.redo,
          label: '重做',
          shortcut: 'Ctrl+Y',
          enabled: session.enabled(EditCommand.redo),
        ),
        BezierMenuItem(
          value: EditCommand.cut,
          label: '剪切',
          shortcut: 'Ctrl+X',
          dividerBefore: true,
          enabled: session.enabled(EditCommand.cut),
        ),
        BezierMenuItem(
          value: EditCommand.copy,
          label: '复制',
          shortcut: 'Ctrl+C',
          enabled: session.enabled(EditCommand.copy),
        ),
        BezierMenuItem(
          value: EditCommand.paste,
          label: '粘贴',
          shortcut: 'Ctrl+V',
          enabled: session.enabled(EditCommand.paste),
        ),
        BezierMenuItem(
          value: EditCommand.delete,
          label: '删除',
          enabled: session.enabled(EditCommand.delete),
        ),
        BezierMenuItem(
          value: EditCommand.selectAll,
          label: '全选',
          shortcut: 'Ctrl+A',
          dividerBefore: true,
          enabled: session.enabled(EditCommand.selectAll),
        ),
      ],
    );
    if (selected == null) return;
    await session.invoke(selected);
  }

  RenderBox? _anchorBox(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }
}

class _TitleIconButton extends StatefulWidget {
  const _TitleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_TitleIconButton> createState() => _TitleIconButtonState();
}

class _TitleIconButtonState extends State<_TitleIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              width: 34,
              height: 30,
              alignment: Alignment.center,
              decoration: bezierDecoration(
                color: _hover ? TsColors.surfaceAlt : Colors.transparent,
                radius: 7,
              ),
              child: Icon(widget.icon, size: 17, color: TsColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuAnchorButton extends StatefulWidget {
  const _MenuAnchorButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  State<_MenuAnchorButton> createState() => _MenuAnchorButtonState();
}

class _MenuAnchorButtonState extends State<_MenuAnchorButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: bezierDecoration(
              color: _hover ? TsColors.surfaceAlt : Colors.transparent,
              radius: 7,
            ),
            child: Text(
              widget.label,
              style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

enum _WindowGlyph { minimize, maximize, restore, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.tooltip,
    required this.onTap,
    required this.type,
    required this.color,
    this.danger = false,
  });

  final String tooltip;
  final VoidCallback onTap;
  final _WindowGlyph type;
  final Color color;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final hoveredDanger = widget.danger && _hover;
    final background = _pressed
        ? (hoveredDanger ? const Color(0xFFB00020) : TsColors.surfaceAlt)
        : (_hover || _focused)
            ? (hoveredDanger ? const Color(0xFFE81123) : TsColors.surfaceAlt)
            : Colors.transparent;
    final fg = hoveredDanger
        ? Colors.white
        : (_focused ? TsColors.textPrimary : widget.color);
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: FocusableActionDetector(
          // 键盘 Tab 可聚焦，Enter/Space 触发；聚焦时与 hover 一样有可见底色。
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() {
              _hover = false;
              _pressed = false;
            }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              onTap: widget.onTap,
              child: Container(
                width: 46,
                height: AppTitleBar.height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: background,
                  border: _focused
                      ? Border.all(color: TsColors.accent, width: 1)
                      : null,
                ),
                child: CustomPaint(
                  size: const Size(16, 16),
                  painter: _WindowGlyphPainter(
                    type: widget.type,
                    color: fg,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowGlyphPainter extends CustomPainter {
  _WindowGlyphPainter({required this.type, required this.color});

  final _WindowGlyph type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final center = size.center(Offset.zero);
    switch (type) {
      case _WindowGlyph.minimize:
        canvas.drawLine(center + const Offset(-5, 0), center + const Offset(5, 0),
            paint);
      case _WindowGlyph.maximize:
        final rect = Rect.fromCenter(center: center, width: 10, height: 9);
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(2.5)), paint);
      case _WindowGlyph.restore:
        // Windows 还原图标：前窗在左下，后窗向右上错开；只画后窗的上边与右边，
        // 其余部分被前窗遮住。两个矩形的并集在 16×16 画布内居中，避免原来
        // 后框偏左导致的“钩子贴在右上角”的错位感。
        final front = Rect.fromCenter(
          center: center + const Offset(-1.5, 1.5),
          width: 10,
          height: 9,
        );
        final back = front.shift(const Offset(3, -3));
        final path = Path()
          ..moveTo(back.left + 3, back.top)
          ..lineTo(back.right - 3, back.top)
          ..quadraticBezierTo(back.right, back.top, back.right, back.top + 3)
          ..lineTo(back.right, back.bottom - 2);
        canvas.drawPath(path, paint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(front, const Radius.circular(2.5)),
          paint,
        );
      case _WindowGlyph.close:
        canvas.drawLine(
            center + const Offset(-5, -5), center + const Offset(5, 5), paint);
        canvas.drawLine(
            center + const Offset(5, -5), center + const Offset(-5, 5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter old) =>
      old.type != type || old.color != color;
}
