// 通用控件：按钮行，按共享间距（[TsSizes.gapInGroup]）排布子按钮。
import 'package:flutter/material.dart';

import '../theme/values.dart';
/// Groups siblings in one button row with the shared 8 px gap.
class TsButtonRow extends StatelessWidget {
  final List<Widget> children;
  final MainAxisAlignment alignment;
  final double gap;

  const TsButtonRow({
    super.key,
    required this.children,
    this.alignment = MainAxisAlignment.end,
    this.gap = TsSizes.gapInGroup,
  });

  @override
  Widget build(BuildContext context) {
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) spaced.add(SizedBox(width: gap));
      spaced.add(children[i]);
    }
    return Row(mainAxisAlignment: alignment, children: spaced);
  }
}

