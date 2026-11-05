// 手工补记对话框（R3-E4）。
//
// 交互要点：
//   * 两种模式：起止时间（可检测重叠）/ 仅时长（无法检测重叠，显式提示）；
//   * 时长非负且有上限、起止校验时序、未来时间拒绝（未来安排走排程功能）；
//   * 与已有记录重叠时先展示重叠区间，**默认不计入**；用户明确选择“保留并计入”
//     才计入，且报告会标注该口径；
//   * 校验/写盘均由 TimerController 完成，本对话框只负责收集输入和展示规则。

import 'package:flutter/material.dart';

import '../../state/execution/effort_stats.dart';
import '../../state/execution/execution_ledger.dart';
import '../../state/execution/execution_models.dart';
import '../../state/execution/timer_controller.dart';
import '../theme.dart';
import '../widgets/bezier_ui.dart';

class ManualEntryDialog extends StatefulWidget {
  const ManualEntryDialog({
    super.key,
    required this.controller,
    required this.taskRef,
  });

  final TimerController controller;
  final ExecutionTaskRef taskRef;

  static Future<ManualEntryOutcome?> show(
    BuildContext context, {
    required TimerController controller,
    required ExecutionTaskRef taskRef,
  }) {
    return showDialog<ManualEntryOutcome>(
      context: context,
      builder: (_) => ManualEntryDialog(
        controller: controller,
        taskRef: taskRef,
      ),
    );
  }

  @override
  State<ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<ManualEntryDialog> {
  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;
  late final TextEditingController _minutesCtrl;
  late final TextEditingController _dateCtrl;
  late final TextEditingController _noteCtrl;

  ManualEntryMode _mode = ManualEntryMode.startEnd;
  OverlapPolicy _policy = OverlapPolicy.excludeOverlap;
  ManualEntryValidation? _validation;
  String? _error;
  bool _overlapAcknowledged = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final nowWall = widget.controller.localTime
        .toLocal(widget.controller.clock.nowUtc);
    final startWall = nowWall.subtract(const Duration(minutes: 30));
    _startCtrl = TextEditingController(text: _formatWall(startWall));
    _endCtrl = TextEditingController(text: _formatWall(nowWall));
    _minutesCtrl = TextEditingController(text: '30');
    _dateCtrl = TextEditingController(text: formatLocalDate(nowWall));
    _noteCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    _minutesCtrl.dispose();
    _dateCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasOverlap = _validation?.hasOverlap ?? false;
    final saveLabel = hasOverlap && !_overlapAcknowledged ? '确认口径并保存' : '保存';
    return AlertDialog(
      key: const Key('manual-entry-dialog'),
      backgroundColor: TsColors.surface,
      titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      title: Row(
        children: [
          Icon(Icons.edit_calendar_outlined, size: 17, color: TsColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '手工补记实际耗时',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: TsColors.textPrimary),
            ),
          ),
          // 与执行回顾/OCR 主弹窗一致的右上角关闭入口。
          IconButton(
            key: const Key('manual-close'),
            tooltip: '关闭',
            style: TsButtons.closeIcon(size: 28),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '任务：${widget.taskRef.taskName}',
                style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
              ),
              const SizedBox(height: 10),
              // 与执行回顾/设置一致的主题分段控件（不再是 Material SegmentedButton）。
              BezierSegments(
                key: const Key('manual-mode'),
                items: const <BezierSegmentItem>[
                  BezierSegmentItem('起止时间', icon: Icons.schedule),
                  BezierSegmentItem('仅时长', icon: Icons.timer_outlined),
                ],
                selected: _mode.index,
                expand: true,
                itemKeys: const <Key?>[
                  Key('manual-mode-start-end'),
                  Key('manual-mode-duration'),
                ],
                onChanged: (index) {
                  setState(() {
                    _mode = ManualEntryMode.values[index];
                    _error = null;
                    _validation = null;
                    _overlapAcknowledged = false;
                  });
                },
              ),
              const SizedBox(height: 12),
              if (_mode == ManualEntryMode.startEnd)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('manual-start'),
                        controller: _startCtrl,
                        decoration: const InputDecoration(
                          labelText: '开始时间',
                          hintText: 'YYYY-MM-DD HH:mm',
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('manual-end'),
                        controller: _endCtrl,
                        decoration: const InputDecoration(
                          labelText: '结束时间',
                          hintText: 'YYYY-MM-DD HH:mm',
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        key: const Key('manual-minutes'),
                        controller: _minutesCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '补记时长',
                          suffixText: '分钟',
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: const Key('manual-date'),
                        controller: _dateCtrl,
                        decoration: const InputDecoration(
                          labelText: '归属日期',
                          hintText: 'YYYY-MM-DD',
                          isDense: true,
                        ),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('manual-note'),
                controller: _noteCtrl,
                maxLength: kMaxManualNoteLength,
                decoration: const InputDecoration(
                  labelText: '说明（可选）',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12.5),
              ),
              if (_mode == ManualEntryMode.duration)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '仅时长补记无法检测与已有记录的重叠；请确认这些工作没有已计时的记录。',
                    style: TextStyle(fontSize: 11, color: TsColors.pending),
                  ),
                ),
              if (hasOverlap) _buildOverlapPanel(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    key: const Key('manual-error'),
                    style: TextStyle(fontSize: 11.5, color: TsColors.blocked),
                  ),
                )
              else if (_validation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _validation!.message,
                    key: const Key('manual-message'),
                    style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('manual-cancel'),
          style: TsButtons.inline(),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('manual-save'),
          style: TsButtons.solid(),
          onPressed: _saving ? null : _save,
          child: Text(saveLabel),
        ),
      ],
    );
  }

  Widget _buildOverlapPanel() {
    final validation = _validation!;
    final hits = validation.overlaps.take(5).toList(growable: false);
    return Container(
      key: const Key('manual-overlap-panel'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TsColors.pendingSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TsColors.pending.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '与已有记录重叠 ${formatEffortDuration(validation.overlapTotal)}：',
            style: TextStyle(fontSize: 11.5, color: TsColors.pending),
          ),
          const SizedBox(height: 4),
          for (final hit in hits)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '· ${hit.taskName}｜${hit.sourceLabel}｜'
                '${_formatHit(hit)}（${formatEffortDuration(hit.overlapDuration)}）',
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
            ),
          if (validation.overlaps.length > hits.length)
            Text(
              '… 另有 ${validation.overlaps.length - hits.length} 段重叠',
              style: TextStyle(fontSize: 11, color: TsColors.textFaint),
            ),
          const SizedBox(height: 6),
          // ListTile/RadioListTile 的背景与涟漪画在最近的 Material 上；这里放在
          // 有背景色的 DecoratedBox 里，必须自带透明 Material，否则 Flutter 会断言
          // “背景/涟漪可能不可见”。
          Material(
            type: MaterialType.transparency,
            child: RadioListTile<OverlapPolicy>(
              key: const Key('manual-overlap-exclude'),
              value: OverlapPolicy.excludeOverlap,
              // ignore: deprecated_member_use
              groupValue: _policy,
              dense: true,
              contentPadding: EdgeInsets.zero,
              // ignore: deprecated_member_use
              onChanged: (value) => setState(() => _policy = value!),
              title: Text(
                '重叠部分不计入（默认）',
                style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: RadioListTile<OverlapPolicy>(
              key: const Key('manual-overlap-include'),
              value: OverlapPolicy.includeOverlap,
              // ignore: deprecated_member_use
              groupValue: _policy,
              dense: true,
              contentPadding: EdgeInsets.zero,
              // ignore: deprecated_member_use
              onChanged: (value) => setState(() => _policy = value!),
              title: Text(
                '明确保留并计入重叠部分（报告会标注口径）',
                style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final draft = _buildDraft();
    if (draft == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final validation =
        await widget.controller.previewManualEntry(widget.taskRef, draft);
    if (!mounted) return;
    if (!validation.ok) {
      setState(() {
        _saving = false;
        _error = validation.message;
        _validation = validation;
      });
      return;
    }
    if (validation.hasOverlap && !_overlapAcknowledged) {
      // 第一次保存只展开重叠区间与口径选择，要求用户明确看到再保存。
      setState(() {
        _saving = false;
        _validation = validation;
        _overlapAcknowledged = true;
      });
      return;
    }
    final outcome =
        await widget.controller.addManualEntry(widget.taskRef, draft);
    if (!mounted) return;
    if (!outcome.ok) {
      setState(() {
        _saving = false;
        _error = outcome.message;
      });
      return;
    }
    Navigator.of(context).pop(outcome);
  }

  ManualEntryDraft? _buildDraft() {
    if (_mode == ManualEntryMode.startEnd) {
      final startWall = _parseLocalWall(_startCtrl.text);
      final endWall = _parseLocalWall(_endCtrl.text);
      if (startWall == null || endWall == null) {
        setState(() => _error = '时间格式应为 YYYY-MM-DD HH:mm');
        return null;
      }
      return ManualEntryDraft(
        mode: ManualEntryMode.startEnd,
        startUtc: widget.controller.localTime.localToUtc(startWall),
        endUtc: widget.controller.localTime.localToUtc(endWall),
        note: _noteCtrl.text,
        overlapPolicy: _policy,
      );
    }
    final minutes = int.tryParse(_minutesCtrl.text.trim());
    if (minutes == null) {
      setState(() => _error = '时长应为整数分钟');
      return null;
    }
    return ManualEntryDraft(
      mode: ManualEntryMode.duration,
      duration: Duration(minutes: minutes),
      localDate: _dateCtrl.text.trim(),
      note: _noteCtrl.text,
      overlapPolicy: _policy,
    );
  }

  static String _formatWall(DateTime wall) {
    final hh = wall.hour.toString().padLeft(2, '0');
    final mm = wall.minute.toString().padLeft(2, '0');
    return '${formatLocalDate(wall)} $hh:$mm';
  }

  static String _formatHit(OverlapHit hit) {
    final start = hit.span.startUtc.toLocal();
    final end = hit.span.endUtc.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(start.month)}-${two(start.day)} '
        '${two(start.hour)}:${two(start.minute)}–'
        '${two(end.hour)}:${two(end.minute)}';
  }

  /// 输入是“本地墙钟时间”，只解析字段，不依赖系统时区。
  static DateTime? _parseLocalWall(String raw) {
    final text = raw.trim().replaceAll('T', ' ');
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    return DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
        parsed.minute, parsed.second);
  }
}
