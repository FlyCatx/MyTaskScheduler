// 统一的关闭图标按钮（0.5.0 任务 02）。
//
// 各窗口右上角关闭键此前是手写的 `IconButton(style: TsButtons.closeIcon(...))`，
// 工具提示、图标大小和键名各不相同。统一到 [TsCloseButton] 后：
//   * 外观：透明圆形底 + 主文字色 ×，hover/focus 加深（来自 TsButtons.closeIcon）；
//   * 语义：默认 tooltip “关闭”，可覆盖为“取消本次分析”等；
//   * 尺寸：默认 28（标题行用），需要更小时显式传 size。
import 'package:flutter/material.dart';

import '../theme/buttons.dart';

class TsCloseButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final double iconSize;

  const TsCloseButton({
    super.key,
    required this.onPressed,
    this.tooltip = '关闭',
    this.size = 28,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      style: TsButtons.closeIcon(size: size),
      onPressed: onPressed,
      icon: Icon(Icons.close, size: iconSize),
    );
  }
}
