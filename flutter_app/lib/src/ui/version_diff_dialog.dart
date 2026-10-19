import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/version_diff.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

/// Read-only comparison of two committed versions by stable task id.
class VersionDiffDialog extends StatelessWidget {
  final PlanVersion? before;
  final PlanVersion after;

  const VersionDiffDialog({super.key, required this.before, required this.after});

  @override
  Widget build(BuildContext context) {
    final diff = computeVersionDiff(before, after);
    return AlertDialog(
      title: Text('版本差异：${before?.displayTitle ?? '初始版本'} → ${after.displayTitle}',
          style: const TextStyle(fontSize: 14.5)),
      content: SizedBox(
        width: 620,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (before == null)
                  _note('这是第一个版本，下面全部任务都算新增。'),
                if (diff.unknownIdentityNote != null)
                  _note(diff.unknownIdentityNote!),
                _section('新增任务', diff.added
                    .map((t) => '＋ ${t.name}（ID ${t.id}）')
                    .toList()),
                _section('删除任务', diff.removed
                    .map((t) => '－ ${t.name}（ID ${t.id}）')
                    .toList()),
                _section(
                    '修改任务',
                    diff.changed
                        .map((c) =>
                            '• ${c.name}（ID ${c.taskId}）：${c.fields.join('、')}')
                        .toList()),
                const SizedBox(height: 8),
                _kv('完成状态继承', '${diff.inheritedCompleted} 项沿用已完成'),
                _kv('仍需复核', '${diff.needsReview} 项'),
                _kv('当前已完成', '${diff.stillCompleted} 项'),
                const SizedBox(height: 8),
                _note('旧版本保持只读；差异按稳定任务 ID 计算，同名不同 ID 不会被当作同一任务。'
                    '完成状态以版本里保存的 reconcile 结果为准，这里不重新猜测。'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭')),
      ],
    );
  }

  Widget _section(String title, List<String> lines) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary)),
          const SizedBox(height: 4),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(line,
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: TsColors.textSecondary)),
            ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          children: [
            SizedBox(
                width: 110,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 11.5, color: TsColors.textFaint))),
            Text(v,
                style: TextStyle(
                    fontSize: 11.5, color: TsColors.textSecondary)),
          ],
        ),
      );

  Widget _note(String text) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: bezierDecoration(
          color: TsColors.surfaceAlt,
          radius: 7,
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, height: 1.5, color: TsColors.textFaint)),
      );
}

