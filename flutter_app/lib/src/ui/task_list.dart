// Task list panel (middle-left).
//
// Interaction contract:
//   * clicking the row selects the task and pins its detail card;
//   * clicking the checkbox ONLY changes completion — it must not also fire the row
//     action (no event bubbling);
//   * Enter on a focused row opens the detail card (keyboard parity with hover).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/display.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

enum TaskFilter { all, ready, blocked, done }

class TaskListView extends StatelessWidget {
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;
  final bool canEdit;
  final Map<String, String> reviewNotes;
  final void Function(String taskId) onToggle;
  final void Function(String taskId) onConfirmReview;
  final void Function(String taskId) onSelect;

  /// When false, completed tasks are hidden from the list. The chart, detail card and
  /// counts still see every task — hiding a row must not change the plan itself.
  final bool showCompleted;

  final TaskFilter filter;
  final String query;
  final ValueChanged<TaskFilter> onFilter;
  final ValueChanged<String> onQuery;

  const TaskListView({
    super.key,
    required this.snapshot,
    required this.interaction,
    required this.canEdit,
    required this.reviewNotes,
    required this.onToggle,
    required this.onConfirmReview,
    required this.onSelect,
    this.showCompleted = true,
    this.filter = TaskFilter.all,
    this.query = '',
    this.onFilter = _noopFilter,
    this.onQuery = _noopQuery,
  });

  static void _noopFilter(TaskFilter _) {}
  static void _noopQuery(String _) {}

  List<DisplayTask> get _items {
    final ordered = snapshot.orderedTasks;
    final rest = snapshot.tasks
        .where((t) => !snapshot.order.contains(t.id))
        .toList(growable: false);
    final all = [...ordered, ...rest];
    final q = query.trim().toLowerCase();
    bool matches(DisplayTask t) {
      if (q.isNotEmpty && !t.name.toLowerCase().contains(q)) return false;
      switch (filter) {
        case TaskFilter.all:
          break;
        case TaskFilter.ready:
          if (!t.isReady) return false;
        case TaskFilter.blocked:
          if (!t.isBlocked) return false;
        case TaskFilter.done:
          if (!t.isDone) return false;
      }
      return showCompleted || !t.isDone;
    }

    // 必须是可增长列表：下面可能把“被筛选隐藏但已选中”的任务补回来。
    final visible = all.where(matches).toList();
    // A related-task jump must not silently fail when the target is filtered out:
    // keep the selected task visible and mark it as a temporary reveal.
    final selected = interaction.selectedTaskId;
    if (selected != null &&
        !visible.any((t) => t.id == selected) &&
        all.any((t) => t.id == selected)) {
      visible.add(all.firstWhere((t) => t.id == selected));
    }
    return visible;
  }

  int get _hiddenCount => snapshot.tasks.length - _items.length;

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      children: [
        _TaskFilterBar(
          snapshot: snapshot,
          filter: filter,
          query: query,
          onFilter: onFilter,
          onQuery: onQuery,
        ),
        if (_hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('已按筛选隐藏 $_hiddenCount 项',
                  key: const Key('task-hidden-count'),
                  style:
                      TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      snapshot.tasks.isEmpty ? '还没有任务' : '没有匹配的任务',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TsColors.textFaint),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final task = items[index];
                    final temporary = interaction.selectedTaskId == task.id &&
                        !snapshot
                            .orderedTasks
                            .where((t) =>
                                (query.trim().isEmpty ||
                                    t.name
                                        .toLowerCase()
                                        .contains(query.trim().toLowerCase())) &&
                                (filter == TaskFilter.all ||
                                    (filter == TaskFilter.ready && t.isReady) ||
                                    (filter == TaskFilter.blocked && t.isBlocked) ||
                                    (filter == TaskFilter.done && t.isDone)))
                            .any((t) => t.id == task.id);
                    return TaskRow(
                      key: ValueKey('task-row-${task.id}'),
                      task: task,
                      orderIndex: snapshot.orderIndex(task.id),
                      selected: interaction.selectedTaskId == task.id,
                      canEdit: canEdit,
                      reviewNote: reviewNotes[task.id],
                      temporaryReveal: temporary,
                      onTap: () {
                        interaction.selectAndReveal(task.id, view: 'list');
                        onSelect(task.id);
                      },
                      onToggle: () => onToggle(task.id),
                      onConfirmReview: () => onConfirmReview(task.id),
                      interaction: interaction,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Compact search + status filter above the task rows. Counts are clickable.
class _TaskFilterBar extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final TaskFilter filter;
  final String query;
  final ValueChanged<TaskFilter> onFilter;
  final ValueChanged<String> onQuery;

  const _TaskFilterBar({
    required this.snapshot,
    required this.filter,
    required this.query,
    required this.onFilter,
    required this.onQuery,
  });

  @override
  State<_TaskFilterBar> createState() => _TaskFilterBarState();
}

class _TaskFilterBarState extends State<_TaskFilterBar> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(covariant _TaskFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = widget.snapshot.counts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Column(
        children: [
          SizedBox(
            height: 28,
            child: TextField(
              key: const Key('task-search'),
              controller: _controller,
              onChanged: widget.onQuery,
              style: const TextStyle(fontSize: 11.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索任务',
                hintStyle:
                    TextStyle(fontSize: 11, color: TsColors.textFaint),
                prefixIcon: Icon(Icons.search,
                    size: 14, color: TsColors.textFaint),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 26, minHeight: 26),
                contentPadding: const EdgeInsets.symmetric(vertical: 5),
                filled: true,
                fillColor: TsColors.surface,
                border: BezierInputBorder(
                    radius: 7,
                    borderSide: BorderSide(color: TsColors.border)),
                enabledBorder: BezierInputBorder(
                    radius: 7,
                    borderSide: BorderSide(color: TsColors.border)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              _chip('全部', TaskFilter.all, counts.total),
              _chip('可开始', TaskFilter.ready, counts.ready),
              _chip('受阻', TaskFilter.blocked, counts.blocked),
              _chip('已完成', TaskFilter.done, counts.done),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, TaskFilter value, int count) {
    final active = widget.filter == value;
    return Tooltip(
      message: '筛选$label（$count 项）',
      child: InkWell(
        key: Key('task-filter-${value.name}'),
        customBorder: const BezierRoundedRectangleBorder(radius: 6),
        onTap: () => widget.onFilter(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: bezierDecoration(
            color: active ? TsColors.accentSoft : TsColors.surfaceAlt,
            radius: 6,
          ),
          child: Text('$label $count',
              style: TextStyle(
                  fontSize: 10.5,
                  color:
                      active ? TsColors.accent : TsColors.textSecondary)),
        ),
      ),
    );
  }
}

/// Header of the task-list pane.
///
/// Rendered by the shell inside a fixed-height row shared with the chart header, so the
/// two panes' bottom rules land on exactly one continuous line.
class TaskListHeader extends StatelessWidget {
  final DisplaySnapshot snapshot;
  final bool canEdit;

  const TaskListHeader({
    super.key,
    required this.snapshot,
    required this.canEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
      child: Row(
        children: [
          const Text('任务清单',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(
            '${snapshot.counts.done}/${snapshot.counts.total} 已完成',
            style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
          ),
          const Spacer(),
          if (!canEdit)
            Tooltip(
              message: '分析进行中或正在查看历史版本，任务不可编辑',
              child: Icon(Icons.lock_outline, size: 15, color: TsColors.textFaint),
            ),
        ],
      ),
    );
  }
}

class TaskRow extends StatefulWidget {
  final DisplayTask task;
  final int orderIndex;
  final bool selected;
  final bool canEdit;
  final String? reviewNote;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onConfirmReview;
  final TaskInteraction interaction;
  final bool temporaryReveal;

  const TaskRow({
    super.key,
    required this.task,
    required this.orderIndex,
    required this.selected,
    required this.canEdit,
    required this.reviewNote,
    required this.onTap,
    required this.onToggle,
    required this.onConfirmReview,
    required this.interaction,
    this.temporaryReveal = false,
  });

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final selected = widget.selected;
    final palette = StatusPalette.of(task.status);

    return FocusableActionDetector(
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: MouseRegion(
        onEnter: (e) {
          final box = context.findRenderObject() as RenderBox?;
          Rect? rect;
          if (box != null && box.hasSize) {
            rect = box.localToGlobal(Offset.zero) & box.size;
          }
          widget.interaction.enterTask(task.id, anchor: rect, view: 'list');
        },
        onExit: (_) => widget.interaction.leaveTask(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null && box.hasSize) {
              widget.interaction.setAnchor(
                task.id,
                box.localToGlobal(Offset.zero) & box.size,
                view: 'list',
              );
            }
            widget.onTap();
          },
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: TsColors.border, width: 0.8),
              ),
            ),
            child: Container(
              decoration: selected || _hover
                  ? bezierDecoration(
                      color: selected ? TsColors.accentSoft : TsColors.surfaceAlt,
                      radius: 8,
                    )
                  : null,
              padding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
              child: Row(
              // Center (not top): a two-line task name used to leave the checkbox
              // pinned to the top edge, which looked detached from the row.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Checkbox in its own hit area: toggling completion must never also
                // select/navigate.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.canEdit ? widget.onToggle : null,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2, right: 6),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: task.isDone,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: widget.canEdit ? (_) => widget.onToggle() : null,
                      ),
                    ),
                  ),
                ),
                if (widget.orderIndex > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '${widget.orderIndex}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: TsColors.textFaint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: task.isDone ? TsColors.done : TsColors.textPrimary,
                          decoration:
                              task.isDone ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusChip(
                            status: task.status,
                            label: task.affected
                                ? '${task.statusText}（受影响）'
                                : task.statusText,
                            dense: true,
                          ),
                          Text(
                            task.estimateLabel,
                            style: TextStyle(fontSize: 11, color: palette.foreground),
                          ),
                          if (task.conditions.isNotEmpty)
                            Text(
                              '外部条件 ${task.conditions.length}',
                              style: TextStyle(
                                  fontSize: 11, color: TsColors.textFaint),
                            ),
                          if (task.level > 0)
                            Text(
                              '第 ${task.level + 1} 层',
                              style: TextStyle(
                                  fontSize: 11, color: TsColors.textFaint),
                            ),
                          if (widget.temporaryReveal)
                            Container(
                              key: const Key('task-temporary-reveal'),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: bezierDecoration(
                                color: TsColors.pendingSoft,
                                radius: 4,
                              ),
                              child: Text('因定位临时显示',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: TsColors.pending)),
                            ),
                        ],
                      ),
                      if (widget.reviewNote != null) ...[
                        const SizedBox(height: 6),
                        _ReviewBanner(
                          text: widget.reviewNote!,
                          canEdit: widget.canEdit,
                          onConfirm: widget.onConfirmReview,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  final String text;
  final bool canEdit;
  final VoidCallback onConfirm;

  const _ReviewBanner({
    required this.text,
    required this.canEdit,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: bezierDecoration(
        color: TsColors.pendingSoft,
        radius: 6,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 13, color: TsColors.pending),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 11, color: TsColors.pending)),
          ),
          if (canEdit)
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: onConfirm,
              child: const Text('确认已完成', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

