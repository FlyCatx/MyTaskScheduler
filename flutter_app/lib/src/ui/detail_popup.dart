// Task detail card — hover preview (after ~300ms) and click-to-pin.
//
// 0.5.0（任务 01）布局契约：
//   * 尺寸：宽度沿用 400 逻辑像素上限；高度上限由调用方按“480 与内容区可用高度
//     的较小值”计算后经 [maxHeight] 传入（见 [computeDetailPopupGeometry]）。
//   * 结构：固定标题/关闭 + 可收缩可滚动的正文 + 固定已有操作区（[executionSection]
//     底栏，任务 13 的执行按钮固定在这里，滚动正文时仍可达）。
//   * 短内容按内容自然收紧（Column mainAxisSize.min + Flexible 正文），长内容只让
//     正文滚动，标题/关闭/操作区不随正文滚走。
//
// Content is strictly sectioned so it does not read as one undifferentiated pile:
//   title/status → estimate & deadline → steps → predecessors & external conditions
//   → scheduling reasons → unlocks → (collapsed) sources.
//
// It contains NO scores, weights, formulas or raw model reasoning.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/display.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

/// 详情卡最大高度上限（逻辑像素）：窗口更高时也不超过它。
const double kTaskDetailMaxHeight = 480;

/// 详情卡与内容区边缘的最小留白（逻辑像素）。
const double kTaskDetailMargin = 8;

/// 详情卡不遮挡图表头部（视图切换/计数）的安全区高度。
const double kTaskDetailHeaderZone = 52;

/// 详情浮窗的定位结果（逻辑像素，相对内容区左上角）。
///
/// [top] 与 [bottom] 二选一：上半区/首行向下展开用 [top]；下半区/末行先整卡
/// 上移进入视口，再按可用高度收缩，用 [bottom] 锚定底边。
class DetailPopupGeometry {
  const DetailPopupGeometry({
    required this.left,
    required this.width,
    required this.maxHeight,
    this.top,
    this.bottom,
  });

  final double left;
  final double width;

  /// 卡片可用的最大高度：`min(480, 实际可用高度)`。
  final double maxHeight;

  final double? top;
  final double? bottom;
}

/// 详情浮窗的纯定位算法（无 BuildContext，便于单元测试）。
///
/// 规则：
///   * 宽度：沿用原有 400 上限与水平优先级（优先放右侧，放不下换左侧，再贴边）；
///   * 高度：`min(kTaskDetailMaxHeight, 当前窗口内容区可用高度)`，并预留主题边距；
///   * 首行/上半区：卡片顶边贴任务行向下展开；
///   * 末行/下半区：先把整卡平移进入视口（底边贴任务行底边），再收缩可用高度——
///     这样最后一行长任务不需要用户滚动窗口就能看到关闭键与操作区。
DetailPopupGeometry computeDetailPopupGeometry({
  required Size viewport,
  Rect? anchor,
  double maxWidth = 400,
  double minWidth = 260,
  double headerZone = kTaskDetailHeaderZone,
  double margin = kTaskDetailMargin,
  double maxHeightLimit = kTaskDetailMaxHeight,
}) {
  final width = math
      .max(minWidth, math.min(maxWidth, viewport.width - margin * 2))
      .toDouble();
  final maxLeft = math.max(margin, viewport.width - width - margin);
  double left;
  if (anchor != null) {
    left = anchor.right + 12;
    if (left + width > viewport.width - margin) {
      final leftSide = anchor.left - width - 12;
      left = leftSide >= margin ? leftSide : viewport.width - width - margin;
    }
  } else {
    left = viewport.width - width - margin * 2;
  }
  left = left.clamp(margin, maxLeft).toDouble();

  final maxAvailableHeight =
      math.max(80.0, viewport.height - headerZone - margin);
  if (anchor == null) {
    return DetailPopupGeometry(
      left: left,
      width: width,
      maxHeight: math.min(maxHeightLimit, maxAvailableHeight),
      top: headerZone,
    );
  }

  final spaceBelow = viewport.height - anchor.bottom - margin;
  final spaceAbove = anchor.top - headerZone - margin;
  // 优先向下展开；下半区（末行）改为底边对齐，先整卡上移再收缩可用高度。
  if (spaceBelow >= spaceAbove) {
    final top = (anchor.top - 8)
        .clamp(headerZone, math.max(headerZone, viewport.height - margin - 120))
        .toDouble();
    final available = viewport.height - margin - top;
    return DetailPopupGeometry(
      left: left,
      width: width,
      maxHeight: math.min(maxHeightLimit, math.max(80.0, available)),
      top: top,
    );
  }

  final cardBottom = (anchor.bottom + 8).clamp(
    math.min(viewport.height - margin, headerZone + 120),
    viewport.height - margin,
  ).toDouble();
  final bottomInset = viewport.height - cardBottom;
  final available = cardBottom - headerZone - margin;
  return DetailPopupGeometry(
    left: left,
    width: width,
    maxHeight: math.min(maxHeightLimit, math.max(80.0, available)),
    bottom: bottomInset,
  );
}

class TaskDetailCard extends StatelessWidget {
  final DisplayTask task;
  final TaskInteraction interaction;

  /// 卡片最大高度（调用方按 `min(480, 可用高度)` 计算；短内容会自然收紧）。
  final double maxHeight;
  final bool pinned;

  /// Local editing is only offered for the current version while no analysis runs.
  final bool canEdit;
  final VoidCallback? onEdit;

  /// Cycles an external condition between met / unknown / unmet (local only — no
  /// model call), which is what "保留条件确认" means here.
  final void Function(int index)? onCycleCondition;

  /// 0.2.3（R3-E）：执行计时/实际耗时区（开始、暂停、继续、停止、完成、手工补记）。
  /// 0.5.0（任务 01/13）：它放在**固定底栏**里，不随正文滚动，因此任务 13 的开始/
  /// 暂停/结束/延长按钮始终可达。由接线方构造，卡片本身不依赖计时控制器；
  /// null = 本构建未启用执行计时。
  final Widget? executionSection;

  const TaskDetailCard({
    super.key,
    required this.task,
    required this.interaction,
    required this.maxHeight,
    required this.pinned,
    this.canEdit = false,
    this.onEdit,
    this.onCycleCondition,
    this.executionSection,
  });

  @override
  Widget build(BuildContext context) {
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
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    Divider(height: 1, thickness: 1, color: TsColors.border),
                    // 正文：唯一可滚动的区域；短内容按内容自然收紧。
                    Flexible(
                      child: SingleChildScrollView(
                        key: const Key('task-detail-body'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _body(context),
                        ),
                      ),
                    ),
                    if (executionSection != null) ...[
                      Divider(height: 1, thickness: 1, color: TsColors.border),
                      // 固定操作区：任务 13 开始/暂停/结束等按钮常驻底栏。
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.max(80.0, maxHeight * 0.5),
                        ),
                        child: SingleChildScrollView(
                          key: const Key('task-detail-footer'),
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '执行与实际耗时',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: TsColors.textFaint,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              executionSection!,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _closeButton(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 固定标题区：任务名 + 状态/固定态 + 编辑入口；右侧 52 px 留给关闭按钮。
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 52, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.name,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
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
        ],
      ),
    );
  }

  Widget _closeButton() {
    // 统一的关闭图标按钮（0.5.0 任务 02）：40 px 热区，固定在标题区右上角。
    return TsCloseButton(
      key: const Key('task-detail-close'),
      tooltip: '关闭详情',
      size: 40,
      iconSize: 18,
      onPressed: interaction.closeDetail,
    );
  }

  /// 可滚动正文（不含标题/状态，也不含固定操作区）。
  List<Widget> _body(BuildContext context) {
    final palette = StatusPalette.of(task.status);
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.background,
          radius: 8,
        ),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, size: 14, color: TsColors.textSecondary),
            const SizedBox(width: 6),
            Text(task.estimateLabel,
                style:
                    TextStyle(fontSize: 12, color: TsColors.textPrimary)),
            const SizedBox(width: 16),
            Icon(Icons.event_outlined, size: 14, color: TsColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              (task.deadline == null || task.deadline!.isEmpty)
                  ? '截止未指定'
                  : '截止 ${task.deadline}',
              style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
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
                style:
                    TextStyle(fontSize: 12.5, color: TsColors.textSecondary))
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
                child:
                    Text(r, style: const TextStyle(fontSize: 12.5, height: 1.5)),
              ),
          ],
        ),
      ),
      _Section(
        label: '完成后解锁',
        child: task.unlocks.isEmpty
            ? Text('暂无；其它任务可能仍需额外前置条件',
                style:
                    TextStyle(fontSize: 12.5, color: TsColors.textSecondary))
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
              style:
                  TextStyle(fontSize: 12.5, color: TsColors.textSecondary)),
        ),
      if (task.sources.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 6),
            title: Text('来源依据',
                style: TextStyle(fontSize: 12, color: TsColors.textSecondary)),
            children: [
              for (final s in task.sources)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· $s',
                        style:
                            TextStyle(fontSize: 12, color: TsColors.textFaint)),
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
    ];
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
