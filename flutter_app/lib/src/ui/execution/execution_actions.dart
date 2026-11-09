// 任务执行操作入口（0.5.0 任务 13 改版）：开始 / 暂停 / 继续 / 结束任务 / 延长时间，
// 以及次级入口：只停止计时 / 手工补记 / 完成任务 / 撤销完成。
//
// 关键语义（文案与按钮行为都要体现）：
//   * 主按钮只出现一次：开始任务／暂停／继续任务／延长时间按阶段切换；
//   * “结束任务”走执行截止控制器统一的“目标=已完成”命令（既有完成/依赖规则，幂等）；
//   * “只停止计时”是次级入口：只结算本次执行并撤销未到期提醒，任务仍不完成；
//   * “完成任务/撤销完成”保留在次级入口，手工勾选完成同样会让到期提醒收敛；
//   * 任务受阻/排程冲突与执行状态互不影响：受阻任务也可以记录已投入工时；
//   * 已暂停仍保留有效截止；开始另一个任务时控制器会先明确暂停当前任务。

import 'package:flutter/material.dart';

import '../../state/execution/execution_deadline.dart';
import '../../state/execution/execution_deadline_controller.dart';
import '../../state/execution/execution_models.dart';
import '../../state/execution/timer_controller.dart';
import '../theme.dart';
import '../widgets/app_notice.dart';
import 'execution_extension_dialog.dart';
import 'manual_entry_dialog.dart';

class ExecutionActions extends StatelessWidget {
  const ExecutionActions({
    super.key,
    required this.controller,
    required this.taskRef,
    this.deadline,
    this.done = false,
    this.onToggleCompletion,
    this.onManualEntry,
    this.showManualEntry = true,
    this.compact = true,
  });

  final TimerController controller;
  final ExecutionTaskRef taskRef;

  /// 执行截止控制器；null = 未启用截止提醒（按钮退回 0.4.x 的“开始/暂停/停止”）。
  final ExecutionDeadlineController? deadline;

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
      listenable: Listenable.merge(<Listenable>[
        controller,
        if (deadline != null) deadline!,
      ]),
      builder: (context, _) {
        final active = controller.active;
        final isThisTask = active != null &&
            active.taskId == taskRef.taskId &&
            active.conversationId == taskRef.conversationId;
        final running = isThisTask && controller.isRunning;
        final paused = isThisTask && controller.isPaused;
        final readOnly = controller.readOnly;
        final session = deadline?.sessionForTask(
          taskRef.conversationId,
          taskRef.taskId,
        );
        // 到点待处理/二次提醒：主按钮是“延长时间”，次按钮是“结束任务”。
        final waiting = session != null &&
            (session.stage == ExecutionDeadlineStage.pending ||
                session.stage == ExecutionDeadlineStage.secondReminder);

        final primary = _primaryButton(
          context,
          readOnly: readOnly,
          isThisTask: isThisTask,
          running: running,
          paused: paused,
          waiting: waiting,
          session: session,
        );

        final secondary = <Widget>[
          if (waiting)
            OutlinedButton.icon(
              key: const Key('execution-action-finish'),
              style: TsButtons.outline(radius: 8, height: 30, fontSize: 12),
              onPressed: readOnly
                  ? null
                  : () => _finishTask(context, session),
              icon: const Icon(Icons.check_circle_outline, size: 15),
              label: const Text('结束任务'),
            )
          else if (isThisTask && !readOnly)
            OutlinedButton.icon(
              key: const Key('execution-action-finish'),
              style: TsButtons.outline(radius: 8, height: 30, fontSize: 12),
              onPressed: () => _finishTask(context, session),
              icon: const Icon(Icons.check_circle_outline, size: 15),
              label: const Text('结束任务'),
            ),
        ];

        final secondaryLinks = <Widget>[
          // 只停止计时：仅当本任务正在计时/暂停时出现；等待阶段无计时可停。
          if (isThisTask && !readOnly && !waiting)
            _linkButton(
              context,
              key: const Key('execution-action-stop'),
              label: '只停止计时',
              icon: Icons.stop_outlined,
              tooltip: '停止本次计时并确认实际耗时；不会把任务标记为完成，'
                  '并撤销该次未到期提醒',
              onPressed: () async {
                final result = await controller.stopAndConfirm();
                if (!context.mounted) return;
                _showMessage(context,
                    ok: result.ok, message: result.message);
              },
            ),
          if (onToggleCompletion != null && !waiting)
            _linkButton(
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
            _linkButton(
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
                _showMessage(context,
                    ok: outcome.ok, message: outcome.message);
              },
            ),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                primary,
                if (secondary.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ...secondary,
                ],
              ],
            ),
            if (secondaryLinks.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 2,
                runSpacing: 0,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: secondaryLinks,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _primaryButton(
    BuildContext context, {
    required bool readOnly,
    required bool isThisTask,
    required bool running,
    required bool paused,
    required bool waiting,
    required ExecutionDeadlineSession? session,
  }) {
    if (waiting) {
      return FilledButton.icon(
        key: const Key('execution-action-extend'),
        style: TsButtons.filled(
          radius: 8,
          minimumSize: Size(0, compact ? 30 : 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          fontSize: compact ? 12 : 13,
        ),
        onPressed: readOnly ? null : () => _extendDeadline(context, session),
        icon: const Icon(Icons.more_time, size: 16),
        label: const Text('延长时间'),
      );
    }
    if (readOnly) {
      return FilledButton.icon(
        key: const Key('execution-action-start'),
        style: TsButtons.filled(
          radius: 8,
          minimumSize: Size(0, compact ? 30 : 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          fontSize: compact ? 12 : 13,
        ),
        onPressed: null,
        icon: const Icon(Icons.lock_outline, size: 16),
        label: const Text('计时只读'),
      );
    }
    if (!isThisTask) {
      return FilledButton.icon(
        key: const Key('execution-action-start'),
        style: TsButtons.filled(
          radius: 8,
          minimumSize: Size(0, compact ? 30 : 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          fontSize: compact ? 12 : 13,
        ),
        onPressed: () async {
          final result = await controller.start(taskRef);
          if (!context.mounted) return;
          _showMessage(context, ok: result.ok, message: result.message);
        },
        icon: const Icon(Icons.play_arrow_outlined, size: 16),
        label: const Text('开始任务'),
      );
    }
    if (running) {
      return FilledButton.icon(
        key: const Key('execution-action-pause'),
        style: TsButtons.filled(
          radius: 8,
          minimumSize: Size(0, compact ? 30 : 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          fontSize: compact ? 12 : 13,
        ),
        onPressed: () async {
          final result = await controller.pause();
          if (!context.mounted) return;
          _showMessage(context, ok: result.ok, message: result.message);
        },
        icon: const Icon(Icons.pause_outlined, size: 16),
        label: const Text('暂停'),
      );
    }
    return FilledButton.icon(
      key: const Key('execution-action-resume'),
      style: TsButtons.filled(
        radius: 8,
        minimumSize: Size(0, compact ? 30 : 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        fontSize: compact ? 12 : 13,
      ),
      onPressed: () async {
        final result = await controller.resume();
        if (!context.mounted) return;
        _showMessage(context, ok: result.ok, message: result.message);
      },
      icon: const Icon(Icons.play_arrow_outlined, size: 16),
      label: const Text('继续任务'),
    );
  }

  Future<void> _finishTask(
    BuildContext context,
    ExecutionDeadlineSession? session,
  ) async {
    final d = deadline;
    if (d != null && session != null) {
      final result = await d.finishSession(session.executionId);
      if (!context.mounted) return;
      _showMessage(context, ok: result.ok, message: result.message);
      return;
    }
    // 未启用截止控制器（旧构建/测试）：停止本次计时 + 走既有完成入口。
    final stopped = await controller.stopAndConfirm();
    if (stopped.ok && onToggleCompletion != null && !done) {
      await onToggleCompletion!();
    }
    if (!context.mounted) return;
    _showMessage(
      context,
      ok: stopped.ok,
      message: stopped.ok ? '已结束任务并标记完成' : stopped.message,
    );
  }

  Future<void> _extendDeadline(
    BuildContext context,
    ExecutionDeadlineSession? session,
  ) async {
    final d = deadline;
    if (d == null || session == null) return;
    final result = await showExecutionExtensionDialog(
      context,
      controller: d,
      session: session,
    );
    if (result == null || !context.mounted) return;
    _showMessage(context, ok: result.ok, message: result.message);
  }

  Widget _linkButton(
    BuildContext context, {
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    final child = TextButton.icon(
      key: key,
      style: TsButtons.inline(fontSize: compact ? 11 : 12),
      onPressed: onPressed,
      icon: Icon(icon, size: compact ? 13 : 15),
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

