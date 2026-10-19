// 通用控件：状态芯片（圆点 + 文本），状态同时用颜色与文案表达。
import 'package:flutter/material.dart';

import '../theme/values.dart';
import 'bezier_ui.dart';
/// A compact status chip: dot + text, never colour alone.
class StatusChip extends StatelessWidget {
  final String status;
  final String label;
  final bool dense;

  const StatusChip({
    super.key,
    required this.status,
    required this.label,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = StatusPalette.of(status);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 2),
      decoration: bezierDecoration(
        color: palette.background,
        radius: dense ? 12 : 14,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: palette.foreground, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 11 : 12,
              color: palette.foreground,
              // Regular weight: w500 makes Windows synthesise a fake semi-bold for
              // Chinese glyphs, which reads as "partially bold" text.
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

