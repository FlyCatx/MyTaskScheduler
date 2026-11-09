// 统一对话框动作区：主 / 次 / 危险 / 轻量按钮的唯一定义处（0.5.0 任务 02）。
//
// 目的：本轮新增的冲突弹窗、OCR 帮助、回顾导出等对话框不再各自拼
// TextButton + FilledButton + 手写间距，而是用同一套角色映射：
//
//   * [TsDialogActionRole.primary]   —— 实心蓝按钮（TsButtons.solid）；对话框的主操作；
//   * [TsDialogActionRole.secondary] —— 描边次要按钮（TsButtons.outline）；
//   * [TsDialogActionRole.danger]    —— 红实心危险按钮（TsButtons.danger）；
//   * [TsDialogActionRole.leading]   —— 行内轻量动作（TsButtons.inline），靠左（如导出）。
//
// 动作的声明顺序就是从左到右的显示顺序；leading 永远固定在左端，其余在右端。
import 'package:flutter/material.dart';

import 'buttons.dart';
import 'values.dart';

/// The four button roles a dialog footer may contain.
enum TsDialogActionRole { leading, secondary, primary, danger }

/// One button in a [TsDialogActions] row.
///
/// [label] is the visible text; [onPressed] null renders the disabled state with the
/// shared disabled colours (and, importantly, no callback, so it cannot fire).
class TsDialogAction {
  final String label;
  final VoidCallback? onPressed;
  final TsDialogActionRole role;

  /// Optional key for tests and for stable focus targets.
  final Key? key;
  final IconData? icon;
  final bool autofocus;
  final String? tooltip;

  const TsDialogAction({
    required this.label,
    required this.onPressed,
    this.role = TsDialogActionRole.secondary,
    this.key,
    this.icon,
    this.autofocus = false,
    this.tooltip,
  });
}

/// The standard dialog footer: leading lightweight action on the left, then the
/// secondary / primary / danger actions right-aligned with [TsSizes.gapInGroup].
///
/// Callers normally add the hairline divider themselves (their card layout already has
/// one); [divider] is available for dialogs that want the footer rule included.
class TsDialogActions extends StatelessWidget {
  final List<TsDialogAction> actions;
  final EdgeInsetsGeometry padding;
  final bool divider;

  const TsDialogActions({
    super.key,
    required this.actions,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 10),
    this.divider = false,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      for (final action in actions)
        if (action.role != TsDialogActionRole.leading) _button(action),
    ];
    final leading = <Widget>[
      for (final action in actions)
        if (action.role == TsDialogActionRole.leading) _button(action),
    ];
    final row = Row(
      children: [
        ...leading,
        if (leading.isNotEmpty && rows.isNotEmpty) const Spacer(),
        ..._withGaps(rows),
      ],
    );
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (divider) ...[
            Divider(height: 1, color: TsColors.border),
            const SizedBox(height: 8),
          ],
          row,
        ],
      ),
    );
  }

  List<Widget> _withGaps(List<Widget> buttons) {
    final spaced = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0) spaced.add(const SizedBox(width: TsSizes.gapInGroup));
      spaced.add(buttons[i]);
    }
    return spaced;
  }

  Widget _button(TsDialogAction action) {
    Widget button;
    switch (action.role) {
      case TsDialogActionRole.primary:
        button = FilledButton(
          key: action.key,
          autofocus: action.autofocus,
          style: TsButtons.solid(),
          onPressed: action.onPressed,
          child: _label(action.label, action.icon),
        );
      case TsDialogActionRole.danger:
        button = FilledButton(
          key: action.key,
          autofocus: action.autofocus,
          style: TsButtons.danger(),
          onPressed: action.onPressed,
          child: _label(action.label, action.icon),
        );
      case TsDialogActionRole.secondary:
        button = TextButton(
          key: action.key,
          autofocus: action.autofocus,
          style: TsButtons.outline(),
          onPressed: action.onPressed,
          child: _label(action.label, action.icon),
        );
      case TsDialogActionRole.leading:
        button = TextButton(
          key: action.key,
          autofocus: action.autofocus,
          style: TsButtons.inline(),
          onPressed: action.onPressed,
          child: _label(action.label, action.icon),
        );
    }
    if (action.tooltip != null) {
      button = Tooltip(message: action.tooltip!, child: button);
    }
    return button;
  }

  Widget _label(String text, IconData? icon) {
    if (icon == null) return Text(text);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 6),
        Text(text),
      ],
    );
  }
}
