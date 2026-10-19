// 设置页共用的控件与版式：分组标题、卡片、行、键值、说明、按键标签与描边按钮。
// 颜色全部取自运行时调色板，因此这些控件不能是 const；尺寸集中在此，
// 保证窗口（最大 980 x 660，窄屏切换为侧栏）与各页一致。
//
// 主要类型：SettingsGroupLabel、SettingsCard、SettingsTile、SettingsKeyValue、
// SettingsNote、SettingsIntro、SettingsKeyChip、SettingsOutlinedButton。

import 'package:flutter/material.dart';

import '../widgets/bezier_ui.dart';
import '../theme.dart';

/// Preferred window size of the settings dialog.
const double kSettingsMaxWidth = 980;
const double kSettingsMaxHeight = 660;

/// Below either of these the rail narrows and the content pane tightens its padding.
const double kSettingsCompactWidth = 900;
const double kSettingsCompactHeight = 600;

const double kSettingsRailWidth = 214;
const double kSettingsRailCompactWidth = 148;

/// Small caption above a group of rows (e.g. 外观 / 输入).
class SettingsGroupLabel extends StatelessWidget {
  final String text;

  const SettingsGroupLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6, top: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: TsColors.textFaint,
          height: 1.3,
        ),
      ),
    );
  }
}

/// One bordered card holding a group of rows.
class SettingsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const SettingsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: bezierDecoration(
        color: TsColors.surface,
        radius: 12,
        border: Border.all(color: TsColors.border),
      ),
      child: child,
    );
  }
}

/// Hairline row separator inside a [SettingsCard].
class SettingsCardDivider extends StatelessWidget {
  const SettingsCardDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(height: 16, thickness: 1, color: TsColors.border);
  }
}

/// Title + optional control, with the control on the **same row to the right** whenever
/// the pane really has room.
///
/// 0.06 stacked the control below the title at `maxWidth < 640`, i.e. almost always — so
/// a settings page with the explanatory text removed showed a wide empty strip on the
/// right and every switch alone on its own line. The threshold now describes the actual
/// minimum the row needs (a readable title plus the control), not a fixed number picked
/// for the old, text-heavy layout. Only a genuinely narrow pane (or a 1.5x text scale in
/// a narrow pane) moves the control below, and there it scrolls instead of overflowing.
class SettingsTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? leading;
  final bool dense;

  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.dense = false,
  });

  /// Below this the control cannot sit next to a readable title any more.
  static const double kMinSideBySideWidth = 300;

  @override
  Widget build(BuildContext context) {
    final control = trailing;
    final lead = leading;
    final labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: dense ? 12.5 : 13,
            height: 1.35,
            color: TsColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: TsColors.textFaint,
              ),
            ),
          ),
      ],
    );

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lead != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 10),
            child: Icon(lead, size: 17, color: TsColors.textSecondary),
          ),
        ],
        Expanded(child: labels),
      ],
    );

    if (control == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
        child: head,
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The available room is measured *after* the text scale has been applied by
          // the framework, so a 1.5x font in a narrow pane really does switch to the
          // stacked layout instead of squeezing the title to a single glyph.
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final needsStack = constraints.maxWidth < kMinSideBySideWidth * scale;
          if (needsStack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                head,
                // Real gap, not a padding trick: the control group must never touch the
                // label above it.
                const SizedBox(height: TsSizes.gapInGroup),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  // A very narrow pane (plus a 1.5x text scale) can be narrower than a
                  // segmented control; scrolling it is better than an overflow stripe.
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: control,
                  ),
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: head),
              const SizedBox(width: TsSizes.gapBetweenGroups),
              control,
            ],
          );
        },
      ),
    );
  }
}

/// Label + value line (about page / diagnostics style).
class SettingsKeyValue extends StatelessWidget {
  final String label;
  final String value;
  final double labelWidth;

  const SettingsKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 104,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 360;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(fontSize: 11.5, color: TsColors.textFaint)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: TsColors.textPrimary)),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(label,
                    style: TextStyle(fontSize: 11.5, color: TsColors.textFaint)),
              ),
              Expanded(
                child: Text(value,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: TsColors.textPrimary)),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Soft informational / warning box. Never colour alone: it always carries an icon.
class SettingsNote extends StatelessWidget {
  final String text;
  final IconData icon;

  /// Foreground tone; defaults to the secondary text colour.
  final Color? tone;

  /// Background; defaults to [TsColors.surfaceAlt].
  final Color? background;

  const SettingsNote({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.tone,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone ?? TsColors.textSecondary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: bezierDecoration(
        color: background ?? TsColors.surfaceAlt,
        radius: 9,
        border: Border.all(color: TsColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.55, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Muted paragraph used at the top of a page.
class SettingsIntro extends StatelessWidget {
  final String text;
  final IconData? icon;

  const SettingsIntro({super.key, required this.text, this.icon});

  @override
  Widget build(BuildContext context) {
    final child = Text(
      text,
      style: TextStyle(fontSize: 11.5, height: 1.6, color: TsColors.textSecondary),
    );
    final glyph = icon;
    if (glyph == null) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(glyph, size: 15, color: TsColors.textSecondary),
        ),
        const SizedBox(width: 8),
        Expanded(child: child),
      ],
    );
  }
}

/// A keyboard-key chip (shortcuts page). ASCII only, so no CJK font concerns.
class SettingsKeyChip extends StatelessWidget {
  final String label;

  const SettingsKeyChip(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 6,
        border: Border.all(color: TsColors.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: TsColors.textPrimary,
        ),
      ),
    );
  }
}

/// Outlined button matching the settings look (compact, 8 px radius).
class SettingsOutlinedButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SettingsOutlinedButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: TsButtons.filled(
        radius: 8,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

/// Floating snack bar; used for "copied" / "not available in this build" messages.
void showSettingsMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, maxLines: 3),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ),
  );
}

