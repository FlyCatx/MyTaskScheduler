// 任务执行操作入口（R3-E1）：开始 / 暂停 / 继续 / 停止本次计时 / 完成任务 / 手工补记。
//
// 关键语义（文案与按钮行为都要体现）：
//   * “停止计时”只结束本次计时并确认实际耗时，**不会**把任务标记为完成；
//   * “完成任务”是独立按钮，不自动写实际耗时，也不自动停止计时；
//   * 任务受阻/排程冲突与执行状态互不影响：受阻任务也可以记录已投入工时；
//   * 开始另一个任务时，控制器会先明确暂停当前任务，并在提示里说明。

import 'package:flutter/material.dart';

import '../../state/execution/execution_models.dart';
import '../../state/execution/timer_controller.dart';
import '../theme.dart';
import '../widgets/app_notice.dart';
import 'manual_entry_dialog.dart';

class ExecutionActions extends StatelessWidget {
  const ExecutionActions({
    super.key,
    required this.controller,
    required this.taskRef,
    this.done = false,
    this.onToggleCompletion,
    this.onManualEntry,
    this.showManualEntry = true,
    this.compact = true,
  });

  final TimerController controller;
  final ExecutionTaskRef taskRef;

  /// 当前任务是否已完成（只用于按钮文案；本控件从不自行改写完成状态）。
  final bool done;

  /// 由接线方注入的完成/撤销完成动作（走后端 `toggleCompletion`）。
  final Future<void> Function()? onToggleCompletion;

  /// 自定义手工补记入口；null 时使用内置 [ManualEntryDialog]。
  final Future<void> Function()? onManualEntry;

  final bool showManualEntry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final active = controller.active;
        final isThisTask = active != null &&
            active.taskId == taskRef.taskId &&
            active.conversationId == taskRef.conversationId;
        final running = isThisTask && controller.isRunning;
        final paused = isThisTask && controller.isPaused;
        final readOnly = controller.readOnly;

        final buttons = <Widget>[
          if (!isThisTask || readOnly)
            _actionButton(
              context,
              key: const Key('execution-action-start'),
              label: readOnly ? '计时只读' : '开始计时',
              icon: Icons.play_arrow_outlined,
              onPressed: readOnly
                  ? null
                  : () async {
                      final result = await controller.start(taskRef);
                      if (!context.mounted) return;
                      _showMessage(context, ok: result.ok, message: result.message);
                    },
            )
          else if (running)
            _actionButton(
              context,
              key: const Key('execution-action-pause'),
              label: '暂停',
              icon: Icons.pause_outlined,
              onPressed: () async {
                final result = await controller.pause();
                if (!context.mounted) return;
                _showMessage(context, ok: result.ok, message: result.message);
              },
            )
          else if (paused)
            _actionButton(
              context,
              key: const Key('execution-action-resume'),
              label: '继续',
              icon: Icons.play_arrow_outlined,
              onPressed: () async {
                final result = await controller.resume();
                if (!context.mounted) return;
                _showMessage(context, ok: result.ok, message: result.message);
              },
            ),
          if (isThisTask && !readOnly)
            _actionButton(
              context,
              key: const Key('execution-action-stop'),
              label: '停止计时',
              icon: Icons.stop_outlined,
              tooltip: '停止本次计时并确认实际耗时；不会把任务标记为完成',
              onPressed: () async {
                final result = await controller.stopAndConfirm();
                if (!context.mounted) return;
                _showMessage(context, ok: result.ok, message: result.message);
              },
            ),
          if (onToggleCompletion != null)
            _actionButton(
              context,
              key: const Key('execution-action-complete'),
              label: done ? '撤销完成' : '完成任务',
              icon: done ? Icons.undo_outlined : Icons.check_circle_outline,
              tooltip: done
                  ? '撤销完成不会删除任何计时/补记记录'
                  : '完成任务不会自动把预估写成实际耗时',
              onPressed: () async {
                await onToggleCompletion!();
              },
            ),
          if (showManualEntry && !readOnly)
            _actionButton(
              context,
              key: const Key('execution-action-manual'),
              label: '手工补记',
              icon: Icons.edit_calendar_outlined,
              onPressed: () async {
                if (onManualEntry != null) {
                  await onManualEntry!();
                  return;
                }
                final outcome = await ManualEntryDialog.show(
                  context,
                  controller: controller,
                  taskRef: taskRef,
                );
                if (outcome == null || !context.mounted) return;
                _showMessage(context, ok: outcome.ok, message: outcome.message);
              },
            ),
        ];

        return Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: buttons,
        );
      },
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    String? tooltip,
  }) {
    final child = TextButton.icon(
      key: key,
      style: TsButtons.inline(fontSize: compact ? 11.5 : 12.5),
      onPressed: onPressed,
      icon: Icon(icon, size: compact ? 14 : 16),
      label: Text(label),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip, child: child);
  }

  /// 执行计时反馈统一进应用级左下角通知（0.3.0 R4-B）；不再用 ScaffoldMessenger。
  ///
  /// 失败保留到用户关闭（计时失败需要读完原因），成功短时后自动消失；同一句提示
  /// 短时间内重复出现时只更新一条，不堆叠。
  void _showMessage(
    BuildContext context, {
    required bool ok,
    required String message,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    AppNotices.instance.show(
      kind: ok ? AppNoticeKind.success : AppNoticeKind.error,
      message: text,
      autoDismiss: ok ? const Duration(seconds: 4) : null,
      dedupeKey: 'execution:$text',
    );
  }
}
