// Local task edit dialog (name / estimate / deadline / dependencies).
//
// This is the "现有编辑功能" carried over from the Win32 UI. It never calls the
// model: the controller re-validates and re-schedules through the C core, and keeps
// the previous state if the edit is rejected (unknown dependency, cycle, ...).

import 'package:flutter/material.dart';

import '../model/plan.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class TaskEditResult {
  final String name;
  final double? estimatedHours;
  final String? deadline;
  final List<String> dependsOn;

  const TaskEditResult({
    required this.name,
    required this.estimatedHours,
    required this.deadline,
    required this.dependsOn,
  });
}

class TaskEditDialog extends StatefulWidget {
  final TaskRecord task;
  final List<TaskRecord> allTasks;

  const TaskEditDialog({super.key, required this.task, required this.allTasks});

  @override
  State<TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<TaskEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _hours;
  late final TextEditingController _deadline;
  late final TextEditingController _depSearch;
  late Set<String> _deps;
  String? _error;
  String _hourUnit = 'h'; // h | min

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.task.name);
    _hours = TextEditingController(
        text: widget.task.estimatedHours == null
            ? ''
            : _trim(widget.task.estimatedHours!));
    _deadline = TextEditingController(text: widget.task.deadline ?? '');
    _depSearch = TextEditingController();
    _deps = widget.task.dependsOn.toSet();
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _name.dispose();
    _hours.dispose();
    _deadline.dispose();
    _depSearch.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '任务名称不能为空');
      return;
    }
    double? hours;
    final hoursText = _hours.text.trim();
    if (hoursText.isNotEmpty) {
      final parsed = double.tryParse(hoursText);
      if (parsed == null || parsed <= 0) {
        setState(() => _error = '预计工时必须是正数，或留空表示“待确认”');
        return;
      }
      hours = _hourUnit == 'min' ? parsed / 60.0 : parsed;
    }
    final deadline = _deadline.text.trim();
    if (deadline.isNotEmpty) {
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(deadline);
      final parsed = match == null ? null : DateTime.tryParse(deadline);
      if (parsed == null ||
          parsed.year.toString().padLeft(4, '0') != match!.group(1) ||
          parsed.month.toString().padLeft(2, '0') != match.group(2) ||
          parsed.day.toString().padLeft(2, '0') != match.group(3)) {
        setState(() => _error = '截止日期必须是有效的 YYYY-MM-DD（例如 2026-10-31）');
        return;
      }
    }
    for (final dep in _deps) {
      if (_createsCycle(widget.task.id, dep, _deps)) {
        setState(() => _error = '前置任务会形成环，已阻止保存');
        return;
      }
    }
    Navigator.of(context).pop(TaskEditResult(
      name: name,
      estimatedHours: hours,
      deadline: deadline.isEmpty ? null : deadline,
      dependsOn: _deps.toList(growable: false),
    ));
  }

  Future<void> _pickDeadline() async {
    final parsed = DateTime.tryParse(_deadline.text.trim());
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: parsed ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择截止日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _deadline.text = '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    });
  }

  /// True when adding [depId] would let [taskId] reach itself. The current task's new
  /// dependency set is used while walking through it; other tasks keep their saved edges.
  bool _createsCycle(String taskId, String depId, Set<String> selected) {
    final byId = {for (final t in widget.allTasks) t.id: t};
    final visited = <String>{};
    bool reaches(String id) {
      if (id == taskId) return true;
      if (!visited.add(id)) return false;
      final deps = id == taskId ? selected : (byId[id]?.dependsOn ?? const []);
      for (final d in deps) {
        if (reaches(d)) return true;
      }
      return false;
    }

    return reaches(depId);
  }

  @override
  Widget build(BuildContext context) {
    final others = widget.allTasks.where((t) => t.id != widget.task.id).toList();
    final depQuery = _depSearch.text.trim().toLowerCase();
    final visibleOthers = depQuery.isEmpty
        ? others
        : others
            .where((t) => t.name.toLowerCase().contains(depQuery))
            .toList(growable: false);
    return Dialog(
      shape: const BezierRoundedRectangleBorder(radius: 14),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('编辑任务',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(labelText: '任务名称'),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('task-hours'),
                          controller: _hours,
                          style: const TextStyle(fontSize: 13),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                            labelText: _hourUnit == 'min'
                                ? '预计工时（分钟，留空=待确认）'
                                : '预计工时（小时，留空=待确认）',
                          ),
                        ),
                        const SizedBox(height: 5),
                        BezierSegments(
                          key: const Key('task-hours-unit'),
                          height: 24,
                          itemWidth: 44,
                          items: const [
                            BezierSegmentItem('小时'),
                            BezierSegmentItem('分钟'),
                          ],
                          selected: _hourUnit == 'min' ? 1 : 0,
                          onChanged: (index) {
                            final next = index == 1 ? 'min' : 'h';
                            if (next == _hourUnit) return;
                            // Convert the visible number so 1.5 h stays 90 min.
                            final parsed = double.tryParse(_hours.text.trim());
                            setState(() {
                              if (parsed != null) {
                                _hours.text = next == 'min'
                                    ? _trim(parsed * 60)
                                    : _trim(parsed / 60);
                              }
                              _hourUnit = next;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('task-deadline'),
                          controller: _deadline,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: '截止（YYYY-MM-DD，留空=未指定）',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            TextButton.icon(
                              key: const Key('task-deadline-pick'),
                              onPressed: _pickDeadline,
                              icon: const Icon(Icons.event, size: 15),
                              label: const Text('选择日期',
                                  style: TextStyle(fontSize: 11.5)),
                            ),
                            TextButton(
                              key: const Key('task-deadline-clear'),
                              onPressed: () => setState(() => _deadline.clear()),
                              child: const Text('清空',
                                  style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text('前置任务（可多选；依赖图是 DAG，不允许成环）',
                  style: TextStyle(fontSize: 11.5, color: TsColors.textFaint)),
              const SizedBox(height: 6),
              SizedBox(
                height: 30,
                child: TextField(
                  key: const Key('task-dep-search'),
                  controller: _depSearch,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索前置任务',
                    prefixIcon: Icon(Icons.search,
                        size: 15, color: TsColors.textFaint),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    filled: true,
                    fillColor: TsColors.surface,
                    border: BezierInputBorder(
                        radius: 7,
                        borderSide: BorderSide(color: TsColors.border)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (visibleOthers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text('没有匹配的任务',
                              style: TextStyle(
                                  fontSize: 11.5, color: TsColors.textFaint)),
                        ),
                      for (final t in visibleOthers)
                        CheckboxListTile(
                          value: _deps.contains(t.id),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(t.name, style: const TextStyle(fontSize: 12.5)),
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              if (_createsCycle(widget.task.id, t.id, _deps)) {
                                _error = '前置任务会形成环：${t.name}';
                                return;
                              }
                              _deps.add(t.id);
                              _error = null;
                            } else {
                              _deps.remove(t.id);
                              _error = null;
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!,
                      style: TextStyle(fontSize: 11.5, color: TsColors.blocked)),
                ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _submit, child: const Text('保存并重排')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

