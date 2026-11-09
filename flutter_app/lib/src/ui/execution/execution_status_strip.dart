// 常驻执行状态区（R3-E1；0.5.0 任务 13 扩展）。
//
// 设计约束：
//   * 顶部显示“同一当前任务、执行/暂停状态、计时”；到点待处理时显示待处理/二次
//     提醒与“延长时间／结束任务”操作（最右“回顾”由壳层负责，不在本组件内）；
//   * 只显示事实：任务名、状态、本次已记录时间、有效截止；从不因为计时改任务完成；
//   * 系统通知不可用时，这里真实显示等价提醒；显示后由本组件回报投递确认，响应窗口
//     才从此起算（见 ExecutionDeadlineController.ackForegroundDelivery）；
//   * 只读实例明确显示锁提示，不伪装成可计时。

import 'package:flutter/material.dart';

import '../../state/execution/effort_stats.dart';
import '../../state/execution/execution_deadline.dart';
import '../../state/execution/execution_deadline_controller.dart';
import '../../state/execution/timer_controller.dart';
import '../theme.dart';
import '../widgets/app_notice.dart';
import 'execution_extension_dialog.dart';

class ExecutionStatusStrip extends StatelessWidget {
  const ExecutionStatusStrip({
    super.key,
    required this.controller,
    this.deadline,
    this.onOpenTask,
    this.onOpenDeadlineTask,
    this.showWhenIdle = false,
  });

  final TimerController controller;

  /// 执行截止控制器；null = 未启用到期提醒（行为与 0.4.x 一致）。
  final ExecutionDeadlineController? deadline;

  /// 点击任务名回到任务详情（由接线方注入导航）。
  final VoidCallback? onOpenTask;

  /// 点击“待处理/再次提醒”的任务名打开对应会话的任务浮窗（可选）。
  final void Function(ExecutionDeadlineSession session)? onOpenDeadlineTask;

  /// 没有活动计时时是否也显示一行提示（默认隐藏，避免占位）。
  final bool showWhenIdle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        if (deadline != null) deadline!,
      ]),
      builder: (context, _) {
        final session = deadline?.primarySession;
        if (session != null) {
          // 前台等价提醒只有“真实显示”后才开始响应窗口：本帧显示完再回报确认。
          if (deadline!.foregroundPendingFor(session.executionId)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              deadline!.ackForegroundDelivery(session.executionId);
            });
          }
          return _deadlineRow(context, session);
        }
        return _timerRow(context);
      },
    );
  }

  // ------------------------------------------------------------ 截止会话状态

  Widget _deadlineRow(
    BuildContext context,
    ExecutionDeadlineSession session,
  ) {
    final active = controller.active;
    final isActiveTask = active != null &&
        active.conversationId == session.conversationId &&
        active.taskId == session.taskId;
    final running = isActiveTask && controller.isRunning;
    final paused = isActiveTask && controller.isPaused;
    final pending = session.stage == ExecutionDeadlineStage.pending ||
        session.stage == ExecutionDeadlineStage.secondReminder;
    final foreground = deadline!.foregroundPendingFor(session.executionId) ||
        session.firstDeliveryChannel == 'foreground' ||
        session.secondDeliveryChannel == 'foreground';

    final Color color = pending
        ? TsColors.pending
        : running
            ? TsColors.ready
            : TsColors.waiting;
    final String phaseLabel = pending
        ? (session.stage == ExecutionDeadlineStage.secondReminder ? '等待回复' : '待处理')
        : running
            ? '计时中'
            : (paused ? '已暂停' : '已安排');
    final elapsedText = isActiveTask
        ? formatElapsedClock(controller.elapsed)
        : '—';
    final deadlineText = pending
        ? (session.stage == ExecutionDeadlineStage.secondReminder &&
                session.responseWindowEndsAtUtc != null
            ? '请在 ${_formatClock(session.responseWindowEndsAtUtc!)} 前选择，届时将自动完成'
            : '计划时段已结束；可延长或结束任务')
        : (session.deadlineUtc == null
            ? '当前没有生效截止'
            : '截止 ${_formatClock(session.deadlineUtc!)}');

    final right = <Widget>[
      if (!readOnlyOrPending(session, running, paused))
        Text(
          elapsedText,
          key: const Key('execution-status-elapsed'),
          style: TextStyle(
            fontSize: 12.5,
            color: TsColors.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature('tnum')],
          ),
        ),
      if (pending) ...[
        const SizedBox(width: 8),
        FilledButton(
          key: const Key('execution-status-extend'),
          style: TsButtons.filled(
            radius: 7,
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            fontSize: 11.5,
          ),
          onPressed: controller.readOnly
              ? null
              : () => _extend(context, session),
          child: const Text('延长时间'),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          key: const Key('execution-status-finish'),
          style: TsButtons.outline(radius: 7, height: 28, fontSize: 11.5),
          onPressed: controller.readOnly
              ? null
              : () => _finish(context, session),
          child: const Text('结束任务'),
        ),
      ] else ...[
        const SizedBox(width: 8),
        if (isActiveTask && !controller.readOnly)
          TextButton(
            key: const Key('execution-status-toggle'),
            style: TsButtons.inline(fontSize: 11.5),
            onPressed: () => running
                ? controller.pause()
                : controller.resume(),
            child: Text(running ? '暂停' : '继续任务'),
          ),
        if (!controller.readOnly)
          OutlinedButton(
            key: const Key('execution-status-finish'),
            style: TsButtons.outline(radius: 7, height: 28, fontSize: 11.5),
            onPressed: () => _finish(context, session),
            child: const Text('结束任务'),
          ),
      ],
    ];

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
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            const SizedBox(width: 7),
            Flexible(
              child: InkWell(
                onTap: () {
                  final open = onOpenDeadlineTask;
                  if (open != null) {
                    open(session);
                  } else {
                    onOpenTask?.call();
                  }
                },
                borderRadius: BorderRadius.circular(4),
                child: Text(
                  session.taskName,
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
              phaseLabel,
              key: const Key('execution-status-phase'),
              style: TextStyle(fontSize: 11, color: color),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                deadlineText,
                key: const Key('execution-status-deadline'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
      right: right,
      extra: (foreground || controller.recoveryNotice != null)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (foreground)
                  Row(
                    children: [
                      Icon(Icons.notifications_off_outlined,
                          size: 13, color: TsColors.pending),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '系统通知不可用，已在应用内显示等价提醒；'
                          '从显示起算 5 分钟响应窗口。',
                          key: const Key('execution-status-foreground'),
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: TsColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                if (controller.recoveryNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
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
                                height: 1.35,
                                color: TsColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            )
          : (deadline!.notice == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    deadline!.notice!,
                    key: const Key('execution-status-deadline-notice'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: TsColors.textSecondary),
                  ),
                )),
    );
  }

  bool readOnlyOrPending(
    ExecutionDeadlineSession session,
    bool running,
    bool paused,
  ) =>
      session.stage == ExecutionDeadlineStage.pending ||
      session.stage == ExecutionDeadlineStage.secondReminder ||
      !(running || paused);

  // ------------------------------------------------------------ 普通计时状态

  Widget _timerRow(BuildContext context) {
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
              controller.readOnly ? Icons.lock_outline : Icons.timer_outlined,
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
                style:
                    TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
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
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
                  Icon(Icons.info_outline, size: 13, color: TsColors.pending),
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
  }

  // ------------------------------------------------------------ helpers

  String _formatClock(DateTime utc) {
    final local = deadline!.localTime.toLocal(utc.toUtc());
    return formatWallClockLabel(local);
  }

  Future<void> _extend(
    BuildContext context,
    ExecutionDeadlineSession session,
  ) async {
    final controller = deadline!;
    final result = await showExecutionExtensionDialog(
      context,
      controller: controller,
      session: session,
    );
    if (result == null || !context.mounted) return;
    AppNotices.instance.show(
      kind: result.ok ? AppNoticeKind.success : AppNoticeKind.error,
      message: result.message,
      autoDismiss: result.ok ? const Duration(seconds: 5) : null,
      dedupeKey: 'execution-deadline:${result.message}',
    );
  }

  Future<void> _finish(
    BuildContext context,
    ExecutionDeadlineSession session,
  ) async {
    final result = await deadline!.finishSession(session.executionId);
    if (!context.mounted && result.message.isEmpty) return;
    AppNotices.instance.show(
      kind: result.ok ? AppNoticeKind.success : AppNoticeKind.error,
      message: result.message,
      autoDismiss: result.ok ? const Duration(seconds: 6) : null,
      dedupeKey: 'execution-deadline:${result.message}',
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
