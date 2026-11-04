// 常驻的小型计时状态区（R3-E1）。
//
// 设计约束：
//   * 只显示“当前活动计时”的事实：任务名、此次已记录时间、暂停/停止入口；
//   * 不弹窗打断每个小操作；
//   * 计时状态与任务完成/排程受阻是**独立**事实：这里从不显示“已完成”，
//     也从不因为计时去改任务状态；
//   * 只读实例（另一实例占用数据目录）明确显示锁提示，不伪装成可计时。

import 'package:flutter/material.dart';

import '../../state/execution/effort_stats.dart';
import '../../state/execution/timer_controller.dart';
import '../theme.dart';

class ExecutionStatusStrip extends StatelessWidget {
  const ExecutionStatusStrip({
    super.key,
    required this.controller,
    this.onOpenTask,
    this.showWhenIdle = false,
  });

  final TimerController controller;

  /// 点击任务名回到任务详情（由接线方注入导航）。
  final VoidCallback? onOpenTask;

  /// 没有活动计时时是否也显示一行提示（默认隐藏，避免占位）。
  final bool showWhenIdle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.active;
        if (active == null) {
          // 只读实例必须始终可见地提示；普通空闲状态默认不占位。
          if (!showWhenIdle && !controller.readOnly) {
            return const SizedBox.shrink();
          }
          return _shell(
            context,
            left: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  controller.readOnly
                      ? Icons.lock_outline
                      : Icons.timer_outlined,
                  size: 14,
                  color: TsColors.textFaint,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    controller.readOnly
                        ? (controller.readOnlyNotice ?? '执行计时为只读')
                        : '当前没有计时中的任务',
                    key: const Key('execution-status-idle'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5, color: TsColors.textSecondary),
                  ),
                ),
              ],
            ),
            right: const <Widget>[],
          );
        }

        final running = controller.isRunning;
        final hasPending = controller.hasOpenCorrections;
        final pendingCount = controller.openCorrections.length;
        final color = running
            ? TsColors.ready
            : (hasPending ? TsColors.pending : TsColors.waiting);
        final statusLabel = running
            ? '计时中'
            : (hasPending ? '待校正' : '已暂停');
        final elapsedText = formatElapsedClock(controller.elapsed);

        return _shell(
          context,
          left: Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.readOnly)
                  Tooltip(
                    message: controller.readOnlyNotice ?? '只读实例',
                    child: const Icon(Icons.lock_outline, size: 13),
                  )
                else
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(width: 7),
                Flexible(
                  child: InkWell(
                    onTap: onOpenTask,
                    borderRadius: BorderRadius.circular(4),
                    child: Text(
                      active.taskName,
                      key: const Key('execution-status-task'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: TsColors.textPrimary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusLabel,
                  key: const Key('execution-status-phase'),
                  style: TextStyle(fontSize: 11, color: color),
                ),
                if (hasPending) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '有 $pendingCount 段不确定时间未确认，暂不计入实际耗时',
                    child: Text(
                      '待校正 $pendingCount 段',
                      key: const Key('execution-status-pending'),
                      style: TextStyle(fontSize: 11, color: TsColors.pending),
                    ),
                  ),
                ],
              ],
            ),
          ),
          right: <Widget>[
            Text(
              elapsedText,
              key: const Key('execution-status-elapsed'),
              style: TextStyle(
                fontSize: 12.5,
                color: TsColors.textPrimary,
                fontFeatures: const <FontFeature>[FontFeature('tnum')],
              ),
            ),
            const SizedBox(width: 8),
            if (!controller.readOnly)
              TextButton(
                key: const Key('execution-status-toggle'),
                style: TsButtons.inline(fontSize: 11.5),
                onPressed: () => running
                    ? controller.pause()
                    : controller.resume(),
                child: Text(running ? '暂停' : '继续'),
              ),
            if (!controller.readOnly)
              TextButton(
                key: const Key('execution-status-stop'),
                style: TsButtons.inline(fontSize: 11.5),
                onPressed: () => controller.stopAndConfirm(),
                child: const Text('停止计时'),
              ),
          ],
          extra: controller.recoveryNotice == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 13, color: TsColors.pending),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          controller.recoveryNotice!,
                          key: const Key('execution-status-recovery'),
                          style: TextStyle(
                            fontSize: 11,
                            color: TsColors.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _shell(
    BuildContext context, {
    required Widget left,
    required List<Widget> right,
    Widget? extra,
  }) {
    return Container(
      key: const Key('execution-status-strip'),
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        color: TsColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              left,
              const Spacer(),
              ...right,
            ],
          ),
          if (extra != null) extra,
        ],
      ),
    );
  }
}
