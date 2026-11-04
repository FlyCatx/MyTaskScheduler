// 执行回顾对话框（R3-R）。
//
// 展示“今日/本周/自定义日期”的执行反馈：已确认投入、未知/待校正、完成任务数、
// 延期任务、估计与实际差异、未安排的剩余工作；每个聚合值都能展开到任务与原始
// 执行记录。统计口径由 EffortReviewService / effort_stats 决定，本对话框只展示。
//
// 导出钩子可选：`onExport(name, csv, suggestedPath)` 返回 true 表示导出成功。
// 未注入时隐藏导出按钮（不伪造“已导出”），也不会自动写文件或调用模型。

import 'package:flutter/material.dart';

import '../../state/execution/effort_review_service.dart';
import '../../state/execution/effort_stats.dart';
import '../theme.dart';

class EffortReviewDialog extends StatefulWidget {
  const EffortReviewDialog({
    super.key,
    required this.service,
    required this.tasks,
    required this.conversations,
    this.initialPreset = EffortReviewPreset.thisWeek,
    this.onExport,
    this.initialConversationId,
    this.initialTaskId,
  });

  final EffortReviewService service;

  /// 当前计划里的任务快照（由接线方构造）。
  final List<ExecutionTaskInfo> tasks;
  final List<ExecutionConversationInfo> conversations;
  final EffortReviewPreset initialPreset;

  /// 导出钩子：`name` 是展示名，`csv` 是完整内容（含 BOM），`suggestedPath` 是
  /// 建议文件名。返回 false 表示用户取消/写入失败。
  final Future<bool> Function(String name, String csv, String suggestedPath)?
      onExport;

  final String? initialConversationId;
  final String? initialTaskId;

  static Future<void> show(
    BuildContext context, {
    required EffortReviewService service,
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    EffortReviewPreset initialPreset = EffortReviewPreset.thisWeek,
    Future<bool> Function(String name, String csv, String suggestedPath)?
        onExport,
    String? initialConversationId,
    String? initialTaskId,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => EffortReviewDialog(
        service: service,
        tasks: tasks,
        conversations: conversations,
        initialPreset: initialPreset,
        onExport: onExport,
        initialConversationId: initialConversationId,
        initialTaskId: initialTaskId,
      ),
    );
  }

  @override
  State<EffortReviewDialog> createState() => _EffortReviewDialogState();
}

class _EffortReviewDialogState extends State<EffortReviewDialog> {
  late EffortReviewPreset _preset;
  String? _conversationId;
  String? _taskId;
  late final TextEditingController _fromCtrl;
  late final TextEditingController _toCtrl;
  EffortReviewReport? _report;
  String? _rangeError;
  String? _exportMessage;

  @override
  void initState() {
    super.initState();
    _preset = widget.initialPreset;
    _conversationId = widget.initialConversationId;
    _taskId = widget.initialTaskId;
    final today = EffortReviewService.todayLocalDate(
      widget.service.nowUtc,
      widget.service.localTime,
    );
    _fromCtrl = TextEditingController(text: formatLocalDate(today));
    _toCtrl = TextEditingController(text: formatLocalDate(today));
    _recompute();
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  void _recompute() {
    final tasks = widget.tasks;
    final conversations = widget.conversations;
    try {
      switch (_preset) {
        case EffortReviewPreset.today:
          _report = widget.service.today(
            tasks: tasks,
            conversations: conversations,
            conversationId: _conversationId,
            taskId: _taskId,
          );
        case EffortReviewPreset.thisWeek:
          _report = widget.service.thisWeek(
            tasks: tasks,
            conversations: conversations,
            conversationId: _conversationId,
            taskId: _taskId,
          );
        case EffortReviewPreset.custom:
          final from = parseLocalDate(_fromCtrl.text);
          final to = parseLocalDate(_toCtrl.text);
          if (from == null || to == null) {
            _report = null;
            _rangeError = '日期格式应为 YYYY-MM-DD';
            return;
          }
          _report = widget.service.custom(
            tasks: tasks,
            conversations: conversations,
            fromLocalDate: from,
            toLocalDate: to,
            conversationId: _conversationId,
            taskId: _taskId,
          );
      }
      _rangeError = null;
    } catch (e) {
      _report = null;
      _rangeError = '生成执行回顾失败：$e';
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return AlertDialog(
      key: const Key('effort-review-dialog'),
      title: Row(
        children: [
          const Icon(Icons.insights_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '执行回顾',
              style: TextStyle(fontSize: 15, color: TsColors.textPrimary),
            ),
          ),
          Text(
            report?.range.label ?? '',
            key: const Key('effort-review-range'),
            style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
          ),
        ],
      ),
      content: SizedBox(
        width: 660,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildFilters(context, report),
            const SizedBox(height: 8),
            if (report != null) _buildSummary(context, report),
            if (report?.rangeNote != null)
              _noteText(report!.rangeNote!, key: const Key('effort-review-range-note')),
            if (report?.completionNote != null)
              _noteText(report!.completionNote!,
                  key: const Key('effort-review-completion-note')),
            if (_rangeError != null)
              _noteText(_rangeError!,
                  key: const Key('effort-review-range-error'),
                  color: TsColors.blocked),
            if (report != null && report.daily.isNotEmpty) ...[
              const SizedBox(height: 6),
              _buildDaily(context, report),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: report == null
                  ? const Center(
                      child: Text(
                        '请选择有效的日期范围',
                        style: TextStyle(fontSize: 12),
                        key: Key('effort-review-empty'),
                      ),
                    )
                  : _buildTaskList(context, report),
            ),
            if (_exportMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _exportMessage!,
                  key: const Key('effort-review-export-message'),
                  style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        if (widget.onExport != null)
          TextButton.icon(
            key: const Key('effort-review-export'),
            style: TsButtons.inline(),
            onPressed: report == null ? null : _export,
            icon: const Icon(Icons.download_outlined, size: 14),
            label: const Text('导出 CSV'),
          ),
        TextButton(
          key: const Key('effort-review-close'),
          style: TsButtons.inline(),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context, EffortReviewReport? report) {
    final taskOptions = widget.tasks
        .where((t) =>
            _conversationId == null || t.conversationId == _conversationId)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<EffortReviewPreset>(
              key: const Key('effort-review-presets'),
              segments: const [
                ButtonSegment<EffortReviewPreset>(
                  value: EffortReviewPreset.today,
                  label: Text('今日'),
                ),
                ButtonSegment<EffortReviewPreset>(
                  value: EffortReviewPreset.thisWeek,
                  label: Text('本周'),
                ),
                ButtonSegment<EffortReviewPreset>(
                  value: EffortReviewPreset.custom,
                  label: Text('自定义'),
                ),
              ],
              selected: <EffortReviewPreset>{_preset},
              onSelectionChanged: (selection) {
                setState(() {
                  _preset = selection.first;
                  _recompute();
                });
              },
            ),
            if (_preset == EffortReviewPreset.custom) ...[
              SizedBox(
                width: 126,
                child: TextField(
                  key: const Key('effort-review-from'),
                  controller: _fromCtrl,
                  decoration: const InputDecoration(
                    labelText: '开始日期',
                    hintText: 'YYYY-MM-DD',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              SizedBox(
                width: 126,
                child: TextField(
                  key: const Key('effort-review-to'),
                  controller: _toCtrl,
                  decoration: const InputDecoration(
                    labelText: '结束日期',
                    hintText: 'YYYY-MM-DD',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                key: const Key('effort-review-apply'),
                style: TsButtons.inline(),
                onPressed: () => setState(_recompute),
                child: const Text('应用'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _dropdown<String?>(
              key: const Key('effort-review-filter-conversation'),
              label: '会话',
              value: _conversationId,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('全部会话'),
                ),
                for (final conversation in widget.conversations)
                  DropdownMenuItem<String?>(
                    value: conversation.id,
                    child: SizedBox(
                      width: 150,
                      child: Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
              onChanged: (value) => setState(() {
                _conversationId = value;
                if (_taskId != null &&
                    !taskOptions.any((t) => t.taskId == _taskId)) {
                  _taskId = null;
                }
                _recompute();
              }),
            ),
            _dropdown<String?>(
              key: const Key('effort-review-filter-task'),
              label: '任务',
              value: _taskId,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('全部任务'),
                ),
                for (final task in taskOptions)
                  DropdownMenuItem<String?>(
                    value: task.taskId,
                    child: SizedBox(
                      width: 170,
                      child: Text(
                        task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
              onChanged: (value) => setState(() {
                _taskId = value;
                _recompute();
              }),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dropdown<T>({
    required Key key,
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final exists = items.any((item) => item.value == value);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label：',
            style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary)),
        DropdownButton<T>(
          key: key,
          value: exists ? value : null,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
          items: items,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context, EffortReviewReport report) {
    final pendingLabel = report.pendingTotal > Duration.zero
        ? '${formatEffortDuration(report.pendingTotal)}（${report.pendingCorrectionCount} 段）'
        : '无';
    final remaining = report.remainingSuggestionHours;
    final metrics = <(Key, String, String)>[
      (
        const Key('effort-review-confirmed'),
        '已确认投入',
        formatEffortDuration(report.confirmedTotal)
      ),
      (const Key('effort-review-pending'), '待校正', pendingLabel),
      (
        const Key('effort-review-completed'),
        '完成任务',
        '${report.completedTaskCount}'
      ),
      (
        const Key('effort-review-delayed'),
        '延期任务',
        '${report.delayedTasks.length}'
      ),
      (
        const Key('effort-review-done-no-actual'),
        '完成但无实际',
        '${report.doneWithoutActual.length}'
      ),
      (
        const Key('effort-review-unestimated'),
        '未估算',
        '${report.unestimatedTasks.length}'
      ),
      (
        const Key('effort-review-remaining'),
        '建议剩余',
        remaining == null ? kEffortUnknownLabel : '${formatEffortHours(remaining)}（建议）'
      ),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final metric in metrics)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${metric.$2}：',
                  style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary)),
              Text(
                metric.$3,
                key: metric.$1,
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildDaily(BuildContext context, EffortReviewReport report) {
    final points = report.daily.take(60).toList(growable: false);
    return SizedBox(
      height: 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: points.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final point = points[index];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: TsColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TsColors.border),
            ),
            child: Text(
              '${point.localDate}  ${formatEffortDuration(point.confirmed)}',
              style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTaskList(BuildContext context, EffortReviewReport report) {
    if (report.tasks.isEmpty) {
      return Center(
        child: Text(
          '这个范围内没有执行记录（未知 ≠ 0）',
          key: const Key('effort-review-empty'),
          style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
        ),
      );
    }
    return ListView.builder(
      itemCount: report.tasks.length,
      itemBuilder: (context, index) {
        final task = report.tasks[index];
        final records = report.recordsFor(task.taskId);
        return ExpansionTile(
          key: Key('effort-review-task-${task.taskId}'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 8, 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  task.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: TsColors.textPrimary),
                ),
              ),
              if (!task.attributed) ...[
                const SizedBox(width: 6),
                _tag('未归属', TsColors.pending),
              ],
              if (task.isDone) ...[
                const SizedBox(width: 6),
                _tag('已完成', TsColors.done),
              ],
            ],
          ),
          subtitle: Text(
            '范围投入 ${formatEffortDuration(task.rangeConfirmed)}｜'
            '实际 ${task.actualHours == null ? kEffortUnknownLabel : formatEffortHours(task.actualHours)}｜'
            '基线 ${formatEffortHours(task.baselineHours)}｜'
            '偏差 ${formatEffortHours(task.deviationHours)}'
            '${task.deviationPercent == null ? '' : '（${formatEffortPercent(task.deviationPercent)}）'}｜'
            '建议剩余 ${formatEffortHours(task.suggestedRemainingHours)}'
            '${task.plannedStartUtc == null && task.plannedEndUtc == null ? '' : '｜计划偏差 开始 ${formatEffortHours(task.startDeviationHours)} / 结束 ${formatEffortHours(task.endDeviationHours)}'}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
          ),
          children: <Widget>[
            if (records.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  '没有执行记录：实际耗时未知（不是 0 分钟）',
                  style: TextStyle(fontSize: 11, color: TsColors.pending),
                ),
              ),
            for (final effort in records)
              Padding(
                key: Key('effort-record-${effort.record.recordId}'),
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_rangeText(effort)}｜${effort.sourceSummary}｜'
                        '范围 ${formatEffortDuration(confirmedWithin(effort, fromUtc: report.fromUtc, toUtc: report.toUtc, localTime: widget.service.localTime))}'
                        '｜累计 ${formatEffortDuration(effort.confirmedDuration)}'
                        '${effort.pendingDuration > Duration.zero ? '｜待校正 ${formatEffortDuration(effort.pendingDuration)}' : ''}'
                        '${effort.overlapIncludedDuration > Duration.zero ? '｜含明确保留的重叠' : ''}',
                        style: TextStyle(
                            fontSize: 10.5, color: TsColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            if (task.unknownIndicators.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '未知项：${task.unknownIndicators.join('；')}',
                  style: TextStyle(fontSize: 10.5, color: TsColors.pending),
                ),
              ),
          ],
        );
      },
    );
  }

  String _rangeText(RecordEffort effort) {
    final localTime = widget.service.localTime;
    final start = effort.firstConfirmedStartUtc;
    final end = effort.lastConfirmedEndUtc;
    String format(DateTime? utc) {
      if (utc == null) return kEffortUnknownLabel;
      final wall = localTime.toLocal(utc);
      final hh = wall.hour.toString().padLeft(2, '0');
      final mm = wall.minute.toString().padLeft(2, '0');
      return '${formatLocalDate(wall)} $hh:$mm';
    }

    return '${format(start)} ~ ${format(end)}';
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _noteText(String text, {Key? key, Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        key: key,
        style: TextStyle(fontSize: 10.5, color: color ?? TsColors.textFaint),
      ),
    );
  }

  Future<void> _export() async {
    final report = _report;
    final hook = widget.onExport;
    if (report == null || hook == null) return;
    final suggested = report.suggestedFileName();
    bool ok;
    try {
      ok = await hook('执行回顾 CSV', report.buildCsv(), suggested);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exportMessage = '导出失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _exportMessage = ok
        ? '已导出执行回顾（含时区、统计范围、指标口径与未知值）'
        : '导出未完成（已取消或写入失败）');
  }
}
