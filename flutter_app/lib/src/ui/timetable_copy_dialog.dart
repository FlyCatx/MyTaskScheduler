// “复制到…”对话框：把某个源日期的时段复制到多个目标日期。
//
// 只做预览与确认，不修改草稿：返回 [TimetableCopyPlan]，由调用方把它作为一笔
// 可撤销事务提交（`_draft.recordTransaction(plan.result, label: ...)`）。取消
// 或关闭返回 null，草稿保持原样；预览为空（没有实际写入）时确认按钮禁用，
// 因此不会产生空撤销记录。
//
// 语义（与 model/timetable.dart 的 planCopyDateRules 一致）：
//   * 策略“仅填充目标空闲区间”（默认）：只写目标日空闲分钟，占用/任务预留/
//     目标日显式规则都会被跳过并计入“受保护跳过”；
//   * 策略“替换目标所选时段”：整体替换目标日对应区间，会移除/改写已有内容，
//     必须在确认前看清移除区间数与任务引用；
//   * “复制整天”把源日 0–1440 的完整有效区间（含默认不可用）都当作复制结果，
//     预览按占用/空闲/任务预留分别统计；
//   * 默认不复制任务绑定（taskId），显式勾选保留后由 plan.warnings 给出任务
//     预留时长变化的提示。
//
// 主要函数：showTimetableCopyDialog。

import 'package:flutter/material.dart';

import '../model/calendar.dart';
import '../model/timetable.dart';
import 'theme.dart';
import 'widgets/bezier_ui.dart';

/// 打开“复制到…”对话框。
///
/// [timetable] 是当前草稿；[sourceDate] 为默认源日期（yyyy-MM-dd）；
/// [coverageFrom]/[coverageTo] 是允许的日期范围；[taskIds] 是现存任务 ID，
/// [taskNames] 用于把任务引用显示成名字（缺省时显示原始 ID）。
Future<TimetableCopyPlan?> showTimetableCopyDialog(
  BuildContext context, {
  required Timetable timetable,
  required String sourceDate,
  required String coverageFrom,
  required String coverageTo,
  Set<String> taskIds = const <String>{},
  Map<String, String> taskNames = const <String, String>{},
}) {
  return showDialog<TimetableCopyPlan>(
    context: context,
    builder: (_) => TimetableCopyDialog(
      timetable: timetable,
      sourceDate: sourceDate,
      coverageFrom: coverageFrom,
      coverageTo: coverageTo,
      taskIds: taskIds,
      taskNames: taskNames,
    ),
  );
}

/// 对话框本体。公开给 widget 测试直接 pump。
class TimetableCopyDialog extends StatefulWidget {
  const TimetableCopyDialog({
    super.key,
    required this.timetable,
    required this.sourceDate,
    required this.coverageFrom,
    required this.coverageTo,
    this.taskIds = const <String>{},
    this.taskNames = const <String, String>{},
  });

  final Timetable timetable;
  final String sourceDate;
  final String coverageFrom;
  final String coverageTo;
  final Set<String> taskIds;
  final Map<String, String> taskNames;

  @override
  State<TimetableCopyDialog> createState() => _TimetableCopyDialogState();
}

class _TimetableCopyDialogState extends State<TimetableCopyDialog> {
  late final TextEditingController _source;
  late final TextEditingController _targetInput;
  late final List<String> _coverageDates;

  final Set<String> _targets = <String>{};
  CopyStrategy _strategy = CopyStrategy.fillFreeOnly;
  bool _keepTaskBindings = false;
  bool _wholeDay = false;

  TimetableCopyPlan? _plan;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    _coverageDates = _buildCoverageDates(
        widget.coverageFrom, widget.coverageTo);
    // 源日期越界不静默回退：保留用户给定的日期，由 _recompute 明确报错，
    // 避免“看起来复制了别的一天”。
    _source = TextEditingController(text: widget.sourceDate.trim());
    _targetInput = TextEditingController();
    _recompute();
  }

  @override
  void dispose() {
    _source.dispose();
    _targetInput.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 计算

  String get _sourceDate => _source.text.trim();

  void _recompute() {
    _inputError = null;
    // 目标集合永远不能包含源日期：改源日期后自动剔除旧源日期，保证
    // 已选天数、预览、plan.targetDates 与确认文案一致。
    _targets.remove(_sourceDate);
    final source = parseDateKey(_sourceDate);
    if (source == null) {
      _plan = null;
      _inputError = '源日期需为 yyyy-MM-dd';
      return;
    }
    if (_sourceDate.compareTo(widget.coverageFrom) < 0 ||
        _sourceDate.compareTo(widget.coverageTo) > 0) {
      _plan = null;
      _inputError = '源日期 $_sourceDate 不在覆盖范围'
          '（${widget.coverageFrom} 至 ${widget.coverageTo}）内';
      return;
    }
    if (_targets.isEmpty) {
      _plan = null;
      return;
    }
    _plan = planCopyDateRules(
      source: widget.timetable,
      sourceDate: _sourceDate,
      targetDates: _targets,
      strategy: _strategy,
      keepTaskBindings: _keepTaskBindings,
      wholeDay: _wholeDay,
    );
  }

  bool get _canConfirm => _plan != null && !_plan!.isEmpty;

  void _addTypedTargets() {
    final text = _targetInput.text.trim();
    if (text.isEmpty) return;
    final tokens = text.split(RegExp(r'[,，、;；\s]+'));
    final invalid = <String>[];
    final outside = <String>[];
    final sourceSkipped = <String>[];
    final added = <String>[];
    for (final token in tokens) {
      if (token.isEmpty) continue;
      final key = parseDateKey(token);
      if (key == null) {
        invalid.add(token);
        continue;
      }
      if (key.compareTo(widget.coverageFrom) < 0 ||
          key.compareTo(widget.coverageTo) > 0) {
        outside.add(key);
        continue;
      }
      // 目标日期不能等于源日期：不加入目标集合，也不让“已选 N 天”虚增。
      if (key == _sourceDate) {
        sourceSkipped.add(key);
        continue;
      }
      if (_targets.add(key)) added.add(key);
    }
    setState(() {
      _targetInput.clear();
      _recompute();
      if (invalid.isNotEmpty) {
        _inputError = '不是合法日期：${invalid.join('、')}（需要 yyyy-MM-dd）';
      } else if (outside.isNotEmpty) {
        _inputError = '超出覆盖范围：${outside.join('、')}'
            '（${widget.coverageFrom} 至 ${widget.coverageTo}）';
      } else if (sourceSkipped.isNotEmpty && added.isNotEmpty) {
        _inputError = '源日期 $_sourceDate 已忽略（目标日期不能等于源日期）';
      } else if (sourceSkipped.isNotEmpty) {
        _inputError = '源日期不能作为目标日期';
      } else if (added.isEmpty) {
        _inputError = '这些日期已经在目标集合里（已去重）';
      }
    });
  }

  void _toggleTarget(String date, bool selected) {
    // 源日期不允许成为目标（列表里已禁用，这里再兜一层）。
    if (selected && date == _sourceDate) return;
    setState(() {
      if (selected) {
        _targets.add(date);
      } else {
        _targets.remove(date);
      }
      _recompute();
    });
  }

  void _selectAllTargets() {
    setState(() {
      _targets
        ..clear()
        ..addAll(_coverageDates.where((d) => d != _sourceDate));
      _recompute();
    });
  }

  void _clearTargets() {
    setState(() {
      _targets.clear();
      _recompute();
    });
  }

  // ------------------------------------------------------------- 提交

  Future<void> _confirm() async {
    final plan = _plan;
    if (plan == null || plan.isEmpty) return;
    if (_strategy == CopyStrategy.replaceSelection &&
        plan.removedRanges.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('替换目标所选时段？', style: TextStyle(fontSize: 15)),
          content: Text(
            '将替换 ${plan.targetDates.length} 个目标日期的对应时段：'
            '会移除或改写 ${plan.removedRanges.length} 个区间'
            '${plan.affectedTaskIds.isEmpty ? '' : '，涉及 ${_taskRefLabel(plan.affectedTaskIds)}'}。'
            '此操作可在编辑器里撤销。',
            style: const TextStyle(fontSize: 12.5, height: 1.5),
          ),
          actions: [
            TextButton(
              key: const Key('timetable-copy-replace-cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('timetable-copy-replace-confirm'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('替换', style: TextStyle(color: TsColors.blocked)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    Navigator.of(context).pop(plan);
  }

  // ------------------------------------------------------------- 展示

  String _taskRefLabel(Iterable<String> taskIds) {
    final labels = <String>[];
    for (final taskId in taskIds) {
      final name = widget.taskNames[taskId];
      if (name != null && name.isNotEmpty) {
        labels.add(name);
      } else if (widget.taskIds.isEmpty ||
          !widget.taskIds.contains(taskId)) {
        labels.add('已删除任务（$taskId）');
      } else {
        labels.add(taskId);
      }
    }
    return labels.join('、');
  }

  List<TimetableEntry> get _sourceRules => widget.timetable.dates
      .where((e) => e.date == _sourceDate)
      .toList(growable: false);

  /// 源日期展开后的占用/空闲/任务预留分钟数（用于区分“复制整天”的内容）。
  ({int occupied, int free, int task}) _sourceBreakdown() {
    var occupied = 0;
    var free = 0;
    var task = 0;
    if (parseDateKey(_sourceDate) == null) {
      return (occupied: 0, free: 0, task: 0);
    }
    for (final interval in widget.timetable.dayIntervals(
        _sourceDate, weekdayOfDateKey(_sourceDate))) {
      switch (interval.state) {
        case TimetableState.occupied:
          occupied += interval.minutes;
        case TimetableState.free:
          free += interval.minutes;
        case TimetableState.task:
          task += interval.minutes;
      }
    }
    return (occupied: occupied, free: free, task: task);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 720),
        child: Container(
          key: const Key('timetable-copy-dialog'),
          decoration: bezierDecoration(
            color: TsColors.surface,
            radius: 14,
            border: Border.all(color: TsColors.border),
          ),
          child: Column(
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
                      _sourceRow(),
                      const SizedBox(height: 12),
                      _targetSection(),
                      const SizedBox(height: 12),
                      _strategySection(),
                      const SizedBox(height: 12),
                      _previewSection(),
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
            child: Text('复制时间表到其他日期',
                style: TextStyle(fontSize: 15)),
          ),
          IconButton(
            tooltip: '关闭',
            key: const Key('timetable-copy-close'),
            onPressed: () => Navigator.of(context).pop(),
            style: TsButtons.closeIcon(size: 28),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _sourceRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 170,
          child: TextField(
            key: const Key('timetable-copy-source-date'),
            controller: _source,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              labelText: '源日期（yyyy-MM-dd）',
              isDense: true,
            ),
            onChanged: (_) => setState(_recompute),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _sourceRules.isEmpty
                ? '源日期没有日期层规则：未勾选“复制整天”时将没有可复制内容。'
                : '源日期有 ${_sourceRules.length} 条日期层规则'
                    '（未勾选“复制整天”时复制这些规则）。',
            key: const Key('timetable-copy-source-summary'),
            style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _targetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('目标日期',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary)),
            const SizedBox(width: 8),
            Text('已选 ${_targets.length} 天',
                key: const Key('timetable-copy-target-summary'),
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary)),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('timetable-copy-target-input'),
                controller: _targetInput,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '输入目标日期，如 2026-11-10, 2026-11-12',
                  isDense: true,
                ),
                onSubmitted: (_) => _addTypedTargets(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: FilledButton(
                key: const Key('timetable-copy-target-add'),
                onPressed: _addTypedTargets,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  fontSize: 11.5,
                ),
                child: const Text('添加日期'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: TextButton(
                key: const Key('timetable-copy-select-all'),
                onPressed: _selectAllTargets,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  fontSize: 11,
                ),
                child: const Text('全选范围内日期'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: TextButton(
                key: const Key('timetable-copy-clear-targets'),
                onPressed: _clearTargets,
                style: TsButtons.filled(
                  radius: 8,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  fontSize: 11,
                ),
                child: const Text('清空'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_inputError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _inputError!,
              key: const Key('timetable-copy-error'),
              style: TextStyle(fontSize: 11, color: TsColors.blocked),
            ),
          ),
        Container(
          height: 148,
          decoration: BoxDecoration(
            border: Border.all(color: TsColors.border),
            borderRadius: const BorderRadius.all(Radius.circular(9)),
          ),
          clipBehavior: Clip.antiAlias,
          child: _coverageDates.isEmpty
              ? Center(
                  child: Text(
                    '覆盖范围为空，无法选择目标日期',
                    style: TextStyle(
                        fontSize: 11, color: TsColors.textFaint),
                  ),
                )
              : ListView.builder(
                  key: const Key('timetable-copy-target-list'),
                  itemCount: _coverageDates.length,
                  itemBuilder: (context, index) {
                    final date = _coverageDates[index];
                    final isSource = date == _sourceDate;
                    final selected = _targets.contains(date);
                    return InkWell(
                      key: Key('timetable-copy-target-$date'),
                      onTap: isSource
                          ? null
                          : () => _toggleTarget(date, !selected),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 30,
                              height: 30,
                              child: Checkbox(
                                value: selected,
                                onChanged: isSource
                                    ? null
                                    : (value) =>
                                        _toggleTarget(date, value == true),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isSource ? '$date（源日期）' : date,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: isSource
                                    ? TsColors.textFaint
                                    : TsColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _strategySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('复制策略',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary)),
        const SizedBox(height: 6),
        _strategyTile(
          key: const Key('timetable-copy-strategy-fill'),
          strategy: CopyStrategy.fillFreeOnly,
          title: '仅填充目标空闲区间（默认）',
          detail: '占用、任务预留、目标日自己的日期规则都会跳过，'
              '被跳过的分钟数会在预览里给出。',
        ),
        const SizedBox(height: 4),
        _strategyTile(
          key: const Key('timetable-copy-strategy-replace'),
          strategy: CopyStrategy.replaceSelection,
          title: '替换目标所选时段',
          detail: '会移除或改写目标日期已有的区间，确认前会列出区间数与任务引用。',
        ),
        const SizedBox(height: 8),
        _checkRow(
          key: const Key('timetable-copy-whole-day'),
          value: _wholeDay,
          onChanged: (value) => setState(() {
            _wholeDay = value;
            _recompute();
          }),
          title: '复制整天',
          subtitle: '勾选后源日期 0–24 时的完整有效区间都算复制结果，'
              '默认不可用/占用时段也会一起复制；预览按占用/空闲/任务预留分别统计。',
        ),
        _checkRow(
          key: const Key('timetable-copy-keep-bindings'),
          value: _keepTaskBindings,
          onChanged: (value) => setState(() {
            _keepTaskBindings = value;
            _recompute();
          }),
          title: '保留任务绑定（默认不复制 taskId）',
          subtitle: '不勾选时复制出的蓝块是未绑定任务预留；勾选后保留 taskId，'
              '预览会提示每个任务“预留时长将增加 N 分钟”。',
        ),
      ],
    );
  }

  /// 自绘复选行：CheckboxListTile 在带背景装饰的容器里会触发“背景色可能看不见”
  /// 的框架断言，这里用 Checkbox + InkWell 显式表达，也更方便测试按 Key 点击。
  Widget _checkRow({
    required Key key,
    required bool value,
    required ValueChanged<bool> onChanged,
    required String title,
    required String subtitle,
  }) {
    return InkWell(
      key: key,
      borderRadius: const BorderRadius.all(Radius.circular(9)),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                value: value,
                onChanged: (next) => onChanged(next == true),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 11.5, color: TsColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 10.5, color: TsColors.textFaint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _strategyTile({
    required Key key,
    required CopyStrategy strategy,
    required String title,
    required String detail,
  }) {
    final selected = _strategy == strategy;
    return InkWell(
      key: key,
      borderRadius: const BorderRadius.all(Radius.circular(9)),
      onTap: () => setState(() {
        _strategy = strategy;
        _recompute();
      }),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: selected ? TsColors.surfaceAlt : Colors.transparent,
          border: Border.all(
              color: selected ? TsColors.accent : TsColors.border),
          borderRadius: const BorderRadius.all(Radius.circular(9)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? TsColors.accent : TsColors.textFaint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: TsColors.textPrimary,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      )),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: TextStyle(
                          fontSize: 10.5, color: TsColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewSection() {
    final plan = _plan;
    final breakdown = _sourceBreakdown();
    return Container(
      key: const Key('timetable-copy-preview'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 9,
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('预览',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary)),
          const SizedBox(height: 6),
          Text(
            _sourceDateLabel(),
            key: const Key('timetable-copy-source-label'),
            style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            '源日期状态：占用 ${breakdown.occupied} 分钟 · '
            '空闲 ${breakdown.free} 分钟 · '
            '任务预留 ${breakdown.task} 分钟',
            key: const Key('timetable-copy-source-states'),
            style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
          ),
          if (_wholeDay)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '复制整天：占用/默认不可用时段也属于复制结果。',
                key: const Key('timetable-copy-whole-day-note'),
                style: TextStyle(fontSize: 10.5, color: TsColors.pending),
              ),
            ),
          const SizedBox(height: 6),
          if (_targets.isEmpty)
            Text(
              '请选择至少一个目标日期。',
              key: const Key('timetable-copy-no-targets'),
              style: TextStyle(fontSize: 11, color: TsColors.textFaint),
            )
          else
            Text(
              '目标日期（${_targets.length} 天）：${_targetDateList()}',
              key: const Key('timetable-copy-target-dates'),
              style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
            ),
          if (plan != null) ...[
            const SizedBox(height: 6),
            Text(
              _planSummary(plan),
              key: const Key('timetable-copy-plan-summary'),
              style: TextStyle(
                  fontSize: 11.5, color: TsColors.textPrimary),
            ),
            if (plan.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '没有可复制的修改（目标日期可能已包含相同内容），'
                  '不会产生撤销记录。',
                  key: const Key('timetable-copy-empty'),
                  style: TextStyle(fontSize: 11, color: TsColors.textFaint),
                ),
              ),
            if (plan.removedRanges.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '会移除/改写的区间：',
                style:
                    TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
              for (final range
                  in plan.removedRanges.take(8).toList(growable: false))
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text('· $range',
                      key: const Key('timetable-copy-removed-range'),
                      style: TextStyle(
                          fontSize: 10.5, color: TsColors.textSecondary)),
                ),
              if (plan.removedRanges.length > 8)
                Text('…还有 ${plan.removedRanges.length - 8} 个区间',
                    style: TextStyle(
                        fontSize: 10.5, color: TsColors.textFaint)),
            ],
            if (plan.affectedTaskIds.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '涉及任务引用：${_taskRefLabel(plan.affectedTaskIds)}',
                key: const Key('timetable-copy-affected-tasks'),
                style:
                    TextStyle(fontSize: 11, color: TsColors.pending),
              ),
            ],
            if (plan.warnings.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('提示：',
                  style: TextStyle(
                      fontSize: 11, color: TsColors.textSecondary)),
              for (final warning in plan.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text('· $warning',
                      key: const Key('timetable-copy-warning'),
                      style: TextStyle(
                          fontSize: 10.5, color: TsColors.pending)),
                ),
            ],
          ],
        ],
      ),
    );
  }

  String _sourceDateLabel() {
    final weekday = weekdayOfDateKey(_sourceDate);
    return '源日期：$_sourceDate（${_weekdayLabel(weekday)}）'
        '${_wholeDay ? ' · 整天 00:00-24:00' : ' · 仅日期层规则'}';
  }

  String _planSummary(TimetableCopyPlan plan) {
    final buffer = StringBuffer();
    buffer.write('将写入 ${plan.changedMinutes} 分钟');
    buffer.write('；目标日期 ${plan.targetDates.length} 天');
    if (_strategy == CopyStrategy.fillFreeOnly) {
      buffer.write('；受保护跳过 ${plan.protectedSkippedMinutes} 分钟');
    } else {
      buffer.write('；会移除/改写 ${plan.removedRanges.length} 个区间');
      if (plan.affectedTaskIds.isNotEmpty) {
        buffer.write('；涉及任务引用 ${plan.affectedTaskIds.length} 个');
      }
    }
    if (!_keepTaskBindings) {
      buffer.write('；任务绑定不复制');
    } else {
      buffer.write('；保留任务绑定');
    }
    return buffer.toString();
  }

  String _targetDateList() {
    final sorted = _targets.toList()..sort();
    if (sorted.length <= 24) return sorted.join('、');
    return '${sorted.take(24).join('、')} …（共 ${sorted.length} 天）';
  }

  Widget _footer() {
    final plan = _plan;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              plan == null
                  ? '选择目标日期后生成预览'
                  : (_canConfirm
                      ? '确认后作为一笔可撤销操作写入草稿'
                      : '没有实际修改，确认不可用'),
              style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
            ),
          ),
          SizedBox(
            height: 34,
            child: TextButton(
              key: const Key('timetable-copy-cancel'),
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
          const SizedBox(width: 8),
          SizedBox(
            height: 34,
            child: FilledButton(
              key: const Key('timetable-copy-confirm'),
              onPressed: _canConfirm ? _confirm : null,
              style: TsButtons.filled(
                radius: 8,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                fontSize: 12,
              ),
              child: Text(
                plan == null || plan.targetDates.isEmpty
                    ? '确认复制'
                    : '确认复制到 ${plan.targetDates.length} 天',
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _weekdayLabel(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };
}

/// 覆盖范围内的所有日期（升序，最多 401 天，与 400 天上限一致）。
List<String> _buildCoverageDates(String from, String to) {
  final out = <String>[];
  if (parseDateKey(from) == null || parseDateKey(to) == null) return out;
  if (to.compareTo(from) < 0) return out;
  var key = from;
  var guard = 0;
  while (key.compareTo(to) <= 0 && guard++ <= 400) {
    out.add(key);
    key = addDaysToDateKey(key, 1);
  }
  return out;
}
