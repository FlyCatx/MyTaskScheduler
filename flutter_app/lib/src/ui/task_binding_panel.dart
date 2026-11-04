// 蓝色任务预留（state=2）的逐块/批量绑定面板。
//
// 面板只负责“看清选中了什么、三个动作各自的后果、目标任务的工时对比”，
// 不直接修改草稿：用户确认后返回 [TaskBindingPanelResult]，由调用方把三个动作
// 各自变成一笔可撤销事务（绑定 / 解除绑定 / 释放时段）。
//
// 三个动作的语义严格区分：
//   * 绑定/改绑：写入 taskId，状态仍是“任务预留”；
//   * 解除绑定：清掉 taskId，**保留**为未绑定任务预留（不是擦除，会继续占容量）；
//   * 释放时段：删除预留，让该区间回到底层规则（可能重新变回不可用）。
//
// 主要类型：TaskBindingSelection、TaskBindingAction、TaskBindingPanelResult、
// TaskBindingPanel、showTaskBindingPanel。

import 'package:flutter/material.dart';

import '../model/calendar.dart';
import 'theme.dart';
import 'widgets/bezier_ui.dart';

/// 一条被选中的蓝色预留。日期与分钟都来自草稿时间表的日期层。
class TaskBindingSelection {
  const TaskBindingSelection({
    required this.reservationId,
    required this.date,
    required this.start,
    required this.end,
    this.taskId,
    this.title,
  });

  /// 蓝色预留的稳定身份（`reservationId ?? entry.id`）。
  final String reservationId;

  /// yyyy-MM-dd。
  final String date;

  /// 当日起始/结束分钟，半开区间 [start,end)。
  final int start;
  final int end;

  /// 当前绑定；null 表示未绑定（仍是一条任务预留）。
  final String? taskId;
  final String? title;

  int get minutes => end - start;

  String get startLabel => WallClockRange.formatMinute(start);
  String get endLabel => WallClockRange.formatMinute(end);

  /// 完整日期时间，例如 `2026-11-09 09:00-10:00`。
  String get timeLabel => '$date $startLabel-$endLabel';
}

/// 面板确认后的动作。
enum TaskBindingAction {
  /// 绑定或改绑到 [TaskBindingPanelResult.taskId]。
  bind,

  /// 解除绑定，保留为未绑定任务预留。
  unbind,

  /// 释放时段，删除预留并恢复底层规则。
  release,
}

/// 面板返回值：动作 + 目标任务。
class TaskBindingPanelResult {
  const TaskBindingPanelResult._(this.action, this.taskId);

  const TaskBindingPanelResult.bind(String taskId)
      : this._(TaskBindingAction.bind, taskId);
  const TaskBindingPanelResult.unbind()
      : this._(TaskBindingAction.unbind, null);
  const TaskBindingPanelResult.release()
      : this._(TaskBindingAction.release, null);

  final TaskBindingAction action;
  final String? taskId;

  /// 中文动作名，用于撤销事务的 label；绑定动作需要调用方补齐任务名。
  String get actionLabel => switch (action) {
        TaskBindingAction.bind => '绑定蓝块',
        TaskBindingAction.unbind => '解除蓝块绑定',
        TaskBindingAction.release => '释放蓝块时段',
      };
}

/// 打开绑定面板；取消返回 null。
Future<TaskBindingPanelResult?> showTaskBindingPanel(
  BuildContext context, {
  required List<TaskBindingSelection> selection,
  required Map<String, String> taskNames,
  Map<String, double?> taskEstimatedHours = const <String, double?>{},
  Map<String, int> reservedMinutesByTask = const <String, int>{},
}) {
  return showDialog<TaskBindingPanelResult>(
    context: context,
    builder: (_) => TaskBindingPanel(
      selection: selection,
      taskNames: taskNames,
      taskEstimatedHours: taskEstimatedHours,
      reservedMinutesByTask: reservedMinutesByTask,
    ),
  );
}

/// 绑定面板本体。公开给 widget 测试直接 pump。
class TaskBindingPanel extends StatefulWidget {
  const TaskBindingPanel({
    super.key,
    required this.selection,
    required this.taskNames,
    this.taskEstimatedHours = const <String, double?>{},
    this.reservedMinutesByTask = const <String, int>{},
  });

  final List<TaskBindingSelection> selection;

  /// 现存任务 ID → 名称；不在其中的 taskId 是“已删除任务的残留引用”。
  final Map<String, String> taskNames;

  /// 任务预估工时（小时）；null 或缺省 = 工时未知，界面显示“未知”，不按 0 处理。
  final Map<String, double?> taskEstimatedHours;

  /// 每个任务当前已有的预留分钟数（含全部日期）。
  final Map<String, int> reservedMinutesByTask;

  @override
  State<TaskBindingPanel> createState() => _TaskBindingPanelState();
}

class _TaskBindingPanelState extends State<TaskBindingPanel> {
  String? _taskId;

  @override
  void initState() {
    super.initState();
    // 默认选中第一个任务的当前绑定，改绑时少点一次；没有任务时保持 null。
    final bound = widget.selection
        .map((e) => e.taskId)
        .whereType<String>()
        .where(widget.taskNames.containsKey)
        .toList(growable: false);
    if (bound.isNotEmpty) {
      _taskId = bound.first;
    } else if (widget.taskNames.isNotEmpty) {
      _taskId = taskIdsSortedByName(widget.taskNames).first;
    }
  }

  List<String> get _sortedTaskIds =>
      taskIdsSortedByName(widget.taskNames);

  int get _selectedMinutes =>
      widget.selection.fold<int>(0, (sum, e) => sum + e.minutes);

  /// 已删除任务的残留引用：选了它们也能解除/释放，不会假装“未绑定”。
  List<TaskBindingSelection> get _orphans => widget.selection
      .where((e) =>
          e.taskId != null &&
          e.taskId!.isNotEmpty &&
          !widget.taskNames.containsKey(e.taskId))
      .toList(growable: false);

  /// 原绑定分组：任务 → 该任务下的块数/分钟；未绑定单独一组。
  Map<String, ({int count, int minutes})> get _originalBindings {
    final out = <String, ({int count, int minutes})>{};
    for (final entry in widget.selection) {
      final taskId = entry.taskId;
      final key = (taskId == null || taskId.isEmpty)
          ? '未绑定'
          : (widget.taskNames[taskId] ?? '已删除任务（$taskId）');
      final prior = out[key] ?? (count: 0, minutes: 0);
      out[key] = (
        count: prior.count + 1,
        minutes: prior.minutes + entry.minutes,
      );
    }
    return out;
  }

  double? get _estimateHours {
    final taskId = _taskId;
    if (taskId == null) return null;
    final hours = widget.taskEstimatedHours[taskId];
    // 0 / 负数同样视为“未知”，避免把未知工时当成 0 分钟参与超额判断。
    return (hours == null || hours <= 0) ? null : hours;
  }

  int get _reservedMinutes =>
      _taskId == null ? 0 : (widget.reservedMinutesByTask[_taskId] ?? 0);

  /// 改绑/绑定后目标任务的预留总量：已有总量 − 这些块里已属于该任务的部分 + 本次全部块。
  int get _projectedMinutes {
    final taskId = _taskId;
    if (taskId == null) return 0;
    var alreadyOnTarget = 0;
    for (final entry in widget.selection) {
      if (entry.taskId == taskId) alreadyOnTarget += entry.minutes;
    }
    return _reservedMinutes - alreadyOnTarget + _selectedMinutes;
  }

  int? get _overMinutes {
    final estimate = _estimateHours;
    if (estimate == null) return null;
    final estimateMinutes = (estimate * 60).round();
    final over = _projectedMinutes - estimateMinutes;
    return over > 0 ? over : null;
  }

  void _finish(TaskBindingPanelResult result) {
    Navigator.of(context).pop(result);
  }

  Future<void> _confirmRelease() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('释放这些时段？', style: TextStyle(fontSize: 15)),
        content: Text(
          '将删除 ${widget.selection.length} 块任务预留（共 $_selectedMinutes 分钟），'
          '这些区间会回到底层规则：原本不可用的会重新变成不可用，不会变成空闲。',
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
        actions: [
          TextButton(
            key: const Key('task-binding-release-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('task-binding-release-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('释放时段',
                style: TextStyle(color: TsColors.blocked)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _finish(const TaskBindingPanelResult.release());
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _selectedMinutes;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Container(
          decoration: bezierDecoration(
            color: TsColors.surface,
            radius: 14,
            border: Border.all(color: TsColors.border),
          ),
          child: Column(
            key: const Key('task-binding-panel'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titleRow(),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _selectionSummary(total),
                      const SizedBox(height: 12),
                      _originalBindingSection(),
                      const SizedBox(height: 12),
                      _taskSection(),
                      const SizedBox(height: 12),
                      _actionsSection(),
                    ],
                  ),
                ),
              ),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
      child: Row(
        children: [
          const Expanded(
            child: Text('任务预留绑定', style: TextStyle(fontSize: 15)),
          ),
          IconButton(
            tooltip: '关闭',
            key: const Key('task-binding-close'),
            onPressed: () => Navigator.of(context).pop(),
            style: TsButtons.closeIcon(size: 28),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _selectionSummary(int total) {
    return Container(
      key: const Key('task-binding-summary'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 9,
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已选 ${widget.selection.length} 块任务预留 · 共 $total 分钟'
            '（${_formatDuration(total)}）',
            style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 148),
            child: SingleChildScrollView(
              key: const Key('task-binding-blocks'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.selection.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        widget.selection[i].timeLabel,
                        key: Key('task-binding-block-$i'),
                        style: TextStyle(
                            fontSize: 11, color: TsColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _originalBindingSection() {
    final bindings = _originalBindings;
    final orphans = _orphans;
    return Column(
      key: const Key('task-binding-original'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('原绑定',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary)),
        const SizedBox(height: 4),
        for (final entry in bindings.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '· ${entry.key}：${entry.value.count} 块 · ${entry.value.minutes} 分钟',
              style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
            ),
          ),
        if (orphans.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '有 ${orphans.length} 块引用的任务已不存在（'
              '${orphans.map((e) => e.taskId).toSet().join('、')}）；'
              '可以重新绑定到现有任务，或解除绑定/释放时段。',
              key: const Key('task-binding-orphan-warning'),
              style: TextStyle(fontSize: 11, color: TsColors.pending),
            ),
          ),
      ],
    );
  }

  Widget _taskSection() {
    final estimateMinutes = _estimateHours == null
        ? null
        : (_estimateHours! * 60).round();
    final over = _overMinutes;
    return Column(
      key: const Key('task-binding-task-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('目标任务',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary)),
        const SizedBox(height: 6),
        if (_sortedTaskIds.isEmpty)
          Text(
            '还没有可绑定的任务。可以先解除绑定（保留为未绑定预留）或释放时段。',
            key: const Key('task-binding-no-tasks'),
            style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
          )
        else
          DropdownButtonFormField<String>(
            key: const Key('task-binding-task-select'),
            initialValue: _taskId,
            isDense: true,
            style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
            decoration: const InputDecoration(
              labelText: '绑定到任务',
              isDense: true,
            ),
            items: [
              for (final taskId in _sortedTaskIds)
                DropdownMenuItem<String>(
                  value: taskId,
                  child: Text(
                    widget.taskNames[taskId] ?? taskId,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            onChanged: (value) => setState(() => _taskId = value),
          ),
        const SizedBox(height: 8),
        _taskInfoRows(estimateMinutes, over),
      ],
    );
  }

  Widget _taskInfoRows(int? estimateMinutes, int? over) {
    final taskId = _taskId;
    final estimateLabel =
        estimateMinutes == null ? '未知' : '$estimateMinutes 分钟';
    return Column(
      key: const Key('task-binding-task-info'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '目标任务：${taskId == null ? '未选择' : (widget.taskNames[taskId] ?? taskId)}',
          style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
        ),
        Text(
          '预估时长：$estimateLabel',
          key: const Key('task-binding-estimate'),
          style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
        ),
        Text(
          '已有预留总量：$_reservedMinutes 分钟',
          key: const Key('task-binding-reserved'),
          style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
        ),
        Text(
          '本次操作后合计：$_projectedMinutes 分钟'
          '${estimateMinutes == null ? '（工时未知，不按 0 判断）' : ''}',
          key: const Key('task-binding-projected'),
          style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
        ),
        if (over != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '预留超出预估工时 $over 分钟（不阻止保存）',
              key: const Key('task-binding-over-warning'),
              style: TextStyle(fontSize: 11, color: TsColors.pending),
            ),
          ),
      ],
    );
  }

  Widget _actionsSection() {
    final hasSelection = widget.selection.isNotEmpty;
    final canBind = hasSelection && _taskId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('操作',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(
              height: 32,
              child: FilledButton.icon(
                key: const Key('task-binding-bind'),
                onPressed:
                    canBind ? () => _finish(TaskBindingPanelResult.bind(_taskId!)) : null,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  fontSize: 11.5,
                ),
                icon: const Icon(Icons.link, size: 15),
                label: Text(_hasBoundToTarget() ? '改绑到该任务' : '绑定到该任务'),
              ),
            ),
            SizedBox(
              height: 32,
              child: OutlinedButton.icon(
                key: const Key('task-binding-unbind'),
                onPressed: hasSelection
                    ? () => _finish(const TaskBindingPanelResult.unbind())
                    : null,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  fontSize: 11.5,
                ),
                icon: const Icon(Icons.link_off, size: 15),
                label: const Text('解除绑定（保留为未绑定预留）'),
              ),
            ),
            SizedBox(
              height: 32,
              child: TextButton.icon(
                key: const Key('task-binding-release'),
                onPressed: hasSelection ? _confirmRelease : null,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  fontSize: 11.5,
                ),
                icon: Icon(Icons.layers_clear,
                    size: 15, color: TsColors.blocked),
                label: Text('释放时段',
                    style: TextStyle(color: TsColors.blocked)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '解除绑定只清任务引用，仍占容量；释放时段会删除预留并恢复底层规则。',
          style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
        ),
      ],
    );
  }

  bool _hasBoundToTarget() {
    final taskId = _taskId;
    if (taskId == null) return false;
    return widget.selection.any((e) => e.taskId == taskId);
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            height: 34,
            child: TextButton(
              key: const Key('task-binding-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              style: TsButtons.filled(
                radius: 8,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                fontSize: 12,
              ),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 按名称排序的任务 ID：下拉框顺序稳定，测试不依赖 Map 插入顺序。
List<String> taskIdsSortedByName(Map<String, String> taskNames) {
  final ids = taskNames.keys.toList()
    ..sort((a, b) {
      final byName = (taskNames[a] ?? a).compareTo(taskNames[b] ?? b);
      return byName != 0 ? byName : a.compareTo(b);
    });
  return ids;
}

String _formatDuration(int minutes) {
  final m = minutes < 0 ? 0 : minutes;
  final h = m ~/ 60;
  final rest = m % 60;
  if (h == 0) return '$rest 分钟';
  if (rest == 0) return '$h 小时';
  return '$h 小时 $rest 分';
}
