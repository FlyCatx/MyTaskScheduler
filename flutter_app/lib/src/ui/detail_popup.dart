// Task detail card — hover preview (after ~300ms) and click-to-pin.
//
// Content is strictly sectioned so it does not read as one undifferentiated pile:
//   title/status → estimate & deadline → steps → predecessors & external conditions
//   → scheduling reasons → unlocks → (collapsed) sources.
//
// It contains NO scores, weights, formulas or raw model reasoning.

import 'package:flutter/material.dart';

import '../model/display.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class TaskDetailCard extends StatelessWidget {
  final DisplayTask task;
  final TaskInteraction interaction;
  final double maxHeight;
  final bool pinned;

  /// Local editing is only offered for the current version while no analysis runs.
  final bool canEdit;
  final VoidCallback? onEdit;

  /// Cycles an external condition between met / unknown / unmet (local only — no
  /// model call), which is what "保留条件确认" means here.
  final void Function(int index)? onCycleCondition;

  const TaskDetailCard({
    super.key,
    required this.task,
    required this.interaction,
    required this.maxHeight,
    required this.pinned,
    this.canEdit = false,
    this.onEdit,
    this.onCycleCondition,
  });

  @override
  Widget build(BuildContext context) {
    final palette = StatusPalette.of(task.status);
    return MouseRegion(
      onEnter: (_) => interaction.enterDetail(),
      onExit: (_) => interaction.leaveDetail(),
      child: Material(
        elevation: 10,
        shape: const BezierRoundedRectangleBorder(radius: 12),
        clipBehavior: Clip.antiAlias,
        color: TsColors.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Stack(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 52, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              task.name,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      StatusChip(
                          status: task.status,
                          label: task.affected
                              ? '${task.statusText}（受影响）'
                              : task.statusText),
                      const SizedBox(width: 8),
                      if (pinned)
                        Text('已固定',
                            style: TextStyle(fontSize: 11, color: TsColors.textFaint)),
                      const Spacer(),
                      if (canEdit && onEdit != null)
                        TextButton.icon(
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_outlined, size: 14),
                          label: const Text('编辑', style: TextStyle(fontSize: 11.5)),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: bezierDecoration(
                      color: TsColors.background,
                      radius: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.timer_outlined,
                            size: 14, color: TsColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(task.estimateLabel,
                            style: TextStyle(
                                fontSize: 12, color: TsColors.textPrimary)),
                        const SizedBox(width: 16),
                        Icon(Icons.event_outlined,
                            size: 14, color: TsColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(
                          (task.deadline == null || task.deadline!.isEmpty)
                              ? '截止未指定'
                              : '截止 ${task.deadline}',
                          style: TextStyle(
                              fontSize: 12, color: TsColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  if (task.steps.isNotEmpty)
                    _Section(
                      label: '执行步骤',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < task.steps.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Text('${i + 1}. ${task.steps[i]}',
                                  style: const TextStyle(fontSize: 12.5, height: 1.45)),
                            ),
                        ],
                      ),
                    ),
                  _Section(
                    label: '前置任务',
                    child: task.predecessors.isEmpty
                        ? Text('无（可以直接开始）',
                            style: TextStyle(
                                fontSize: 12.5, color: TsColors.textSecondary))
                        : _chips(task.predecessors),
                  ),
                  if (task.conditions.isNotEmpty)
                    _Section(
                      label: canEdit ? '外部条件（点击可切换确认状态）' : '外部条件',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < task.conditions.length; i++)
                            _conditionRow(task.conditions[i], i),
                        ],
                      ),
                    ),
                  _Section(
                    label: '为什么这样安排',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final r in task.reasons)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(r,
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.5)),
                          ),
                      ],
                    ),
                  ),
                  _Section(
                    label: '完成后解锁',
                    child: task.unlocks.isEmpty
                        ? Text('暂无；其它任务可能仍需额外前置条件',
                            style: TextStyle(
                                fontSize: 12.5, color: TsColors.textSecondary))
                        : _chips(task.unlocks),
                  ),
                  if (task.stillWaiting.isNotEmpty)
                    _Section(
                      label: '仍待其它前置',
                      child: _chips(task.stillWaiting, muted: true),
                    ),
                  if (task.scheduleNote != null)
                    _Section(
                      label: '时间轴说明',
                      child: Text(task.scheduleNote!,
                          style: TextStyle(
                              fontSize: 12.5, color: TsColors.textSecondary)),
                    ),
                  if (task.sources.isNotEmpty)
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 6),
                        title: Text('来源依据',
                            style: TextStyle(
                                fontSize: 12, color: TsColors.textSecondary)),
                        children: [
                          for (final s in task.sources)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text('· $s',
                                    style: TextStyle(
                                        fontSize: 12, color: TsColors.textFaint)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '提示：点击任意关联任务可直接跳转；Esc 或点击空白处关闭',
                    style: TextStyle(
                        fontSize: 11, color: palette.foreground.withValues(alpha: 0.7)),
                  ),
                ],
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Semantics(
                    button: true,
                    label: '关闭详情',
                    child: Tooltip(
                      message: '关闭详情',
                      child: Material(
                        color: TsColors.surface.withValues(alpha: 0.86),
                        shape: const CircleBorder(),
                        elevation: 1,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: interaction.closeDetail,
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: Icon(
                              Icons.close,
                              size: 18,
                              color: TsColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _conditionRow(TaskCondition c, int index) {
    final icon = c.status == 'met'
        ? Icons.check_circle_outline
        : (c.status == 'unmet' ? Icons.block : Icons.help_outline);
    final color = c.status == 'met'
        ? TsColors.ready
        : (c.status == 'unmet' ? TsColors.blocked : TsColors.pending);
    final row = Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${c.text}（${c.statusText}）',
                style: const TextStyle(fontSize: 12.5, height: 1.4)),
          ),
        ],
      ),
    );
    if (!canEdit || onCycleCondition == null) return row;
    return InkWell(
      onTap: () => onCycleCondition!(index),
      customBorder: const BezierRoundedRectangleBorder(radius: 6),
      child: row,
    );
  }

  Widget _chips(List<RelatedTask> items, {bool muted = false}) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final t in items)
          ActionChip(
            visualDensity: VisualDensity.compact,
            labelStyle: TextStyle(
              fontSize: 11.5,
              color: muted ? TsColors.textSecondary : TsColors.accent,
            ),
            backgroundColor: muted ? TsColors.doneSoft : TsColors.accentSoft,
            side: BorderSide.none,
            label: Text(t.name),
            onPressed: () => interaction.selectAndReveal(t.id),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  final Widget child;

  const _Section({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  color: TsColors.textFaint,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

