// Bottom-left user entry + its popup menu.
//
// Product decision: there is NO login system. A single local account ("admin") exists
// purely as the entry point to the settings dialog. The other two entries are drawn to
// match the reference design but are intentionally inert (light grey, no interaction),
// so the UI does not pretend to have features it does not have.
//
// The menu is an explicit OverlayEntry rather than showMenu(): showMenu needs a
// pre-computed rectangle, and getting "hug the button, open upwards" out of it produced
// a tall empty popup floating far above the entry with a drop shadow. Owning the overlay
// makes the anchor exact and lets us drop the shadow.

import 'package:flutter/material.dart';

import '../app_info.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class UserMenuButton extends StatefulWidget {
  final VoidCallback onOpenSettings;

  const UserMenuButton({super.key, required this.onOpenSettings});

  @override
  State<UserMenuButton> createState() => _UserMenuButtonState();
}

class _UserMenuButtonState extends State<UserMenuButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        customBorder: const BezierRoundedRectangleBorder(radius: 12),
        onTap: () => _showMenu(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: bezierDecoration(
            // Theme-aware: a hard-coded light grey turned into a bright block in dark
            // mode. Hover is a slightly stronger tint of the same border colour.
            color: _hover
                ? TsColors.border.withValues(alpha: 0.45)
                : TsColors.surfaceAlt,
            radius: 12,
            border: Border.all(color: _hover ? TsColors.border : Colors.transparent),
          ),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: TsColors.border,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person_outline,
                    size: 16, color: TsColors.textSecondary),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  kLocalUserName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary),
                ),
              ),
              Icon(Icons.expand_less, size: 16, color: TsColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the menu directly above the entry, left-aligned with it.
  void _showMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || overlayBox == null) return;
    // Anchor in OVERLAY coordinates: MediaQuery height and the overlay's actual height
    // can disagree (embedded hosts, test surfaces), and using the wrong one pushes the
    // menu off-screen.
    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final overlayHeight = overlayBox.size.height;
    const menuWidth = 208.0;
    const gap = 6.0;

    late final OverlayEntry entry;
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      entry.remove();
    }

    void openSettings() {
      close();
      widget.onOpenSettings();
    }

    entry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            // Click-outside catcher.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: origin.dx,
              // Anchored to the button's top edge: the menu grows upward from here.
              bottom: overlayHeight - origin.dy + gap,
              width: menuWidth,
              child: _MenuPanel(
                onSettings: openSettings,
                onDismiss: close,
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  }
}

class _MenuPanel extends StatelessWidget {
  final VoidCallback onSettings;
  final VoidCallback onDismiss;

  const _MenuPanel({required this.onSettings, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Material(
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
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuRow(
              icon: Icons.settings_outlined,
              label: '设置',
              onTap: onSettings,
            ),
            const _MenuRow(icon: Icons.send_outlined, label: '意见反馈'),
            const _MenuRow(icon: Icons.logout, label: '退出登录'),
          ],
        ),
      ),
    );
  }
}

/// One menu row. When [onTap] is null the row is inert: light grey, no ripple, no
/// hover highlight — it only exists to match the reference design.
class _MenuRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _MenuRow({required this.icon, required this.label, this.onTap});

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = enabled ? TsColors.textPrimary : TsColors.textFaint;
    final content = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: enabled && _hover
          ? bezierDecoration(color: TsColors.surfaceAlt, radius: 8)
          : null,
      child: Row(
        children: [
          Icon(widget.icon, size: 17, color: color),
          const SizedBox(width: 10),
          Text(widget.label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );

    if (!enabled) {
      // Inert: no pointer, no ripple, no hover feedback.
      return IgnorePointer(child: content);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: content,
      ),
    );
  }
}

