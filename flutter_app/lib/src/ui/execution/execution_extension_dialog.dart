// “延长时间”对话框（0.5.0 任务 13）。
//
// 语义：
//   * 只读预览：打开/取消/改选项都不算延期成功；
//   * 新截止必须晚于当前时刻与原有效截止（校验在控制器里再核对一次）；
//   * 确认前展示潜在重叠与受影响的其它任务（不会自动搬动它们）；
//   * 确认走 [ExecutionDeadlineController.confirmExtension]：保存新的甘特结束时刻、
//     重排提醒、从确认时刻恢复计时；失败保留原状态可重试，状态已变化时拒绝陈旧提交。
//
// 时间显示遵循应用配置的本地时区（注入的 EffortLocalTime）。

import 'package:flutter/material.dart';

import '../../state/execution/execution_deadline.dart';
import '../../state/execution/execution_deadline_controller.dart';
import '../theme.dart';

/// 对话框返回结果；取消返回 null。
class ExecutionExtensionResult {
  const ExecutionExtensionResult({
    required this.ok,
    required this.message,
    this.session,
  });

  final bool ok;
  final String message;
  final ExecutionDeadlineSession? session;
}

/// 打开“延长时间”对话框。
Future<ExecutionExtensionResult?> showExecutionExtensionDialog(
  BuildContext context, {
  required ExecutionDeadlineController controller,
  required ExecutionDeadlineSession session,
}) {
  return showDialog<ExecutionExtensionResult>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _ExecutionExtensionDialog(
      controller: controller,
      session: session,
    ),
  );
}

class _ExecutionExtensionDialog extends StatefulWidget {
  const _ExecutionExtensionDialog({
    required this.controller,
    required this.session,
  });

  final ExecutionDeadlineController controller;
  final ExecutionDeadlineSession session;

  @override
  State<_ExecutionExtensionDialog> createState() =>
      _ExecutionExtensionDialogState();
}

class _ExecutionExtensionDialogState extends State<_ExecutionExtensionDialog> {
  late ExecutionDeadlineSession _session;
  late DateTime _newEndUtc;
  ExecutionExtensionPreview? _preview;
  bool _previewing = false;
  bool _busy = false;
  String? _error;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _newEndUtc = widget.controller.nextExtensionCandidate(_session);
    _refreshPreview();
  }

  String get _localLabel {
    final local = widget.controller.localTime.toLocal(_newEndUtc);
    return '${local.month}月${local.day}日 ${formatWallClockLabel(local)}';
  }

  String _formatUtc(DateTime? utc) {
    if (utc == null) return '未安排';
    final local = widget.controller.localTime.toLocal(utc);
    return '${local.month}月${local.day}日 ${formatWallClockLabel(local)}';
  }

  void _pickOption(Duration delta) {
    final base = _session.deadlineUtc ?? widget.controller.nowUtc;
    var candidate = base.add(delta);
    final earliest = widget.controller.nowUtc.add(const Duration(minutes: 1));
    if (candidate.isBefore(earliest)) candidate = earliest;
    setState(() {
      _newEndUtc = candidate;
      _error = null;
    });
    _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    setState(() {
      _previewing = true;
    });
    try {
      final preview = await widget.controller.previewExtension(
        _session.executionId,
        _newEndUtc,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _previewing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _error = '预览失败：$error';
      });
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    // 打开对话框时的修订号：期间自动完成/结束/别的延长发生时拒绝陈旧提交。
    final expectedRevision = _session.revision;
    if (_newEndUtc.isBefore(widget.controller.nowUtc)) {
      setState(() => _error = '新截止必须晚于当前时刻');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.controller.confirmExtension(
      _session.executionId,
      _newEndUtc,
      expectedRevision: expectedRevision,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _session = result.session ?? _session;
      } else {
        _error = result.message;
        _stale = !result.ok &&
            (result.session == null || !result.session!.isActive);
      }
    });
    if (result.ok) {
      Navigator.of(context).pop(ExecutionExtensionResult(
        ok: true,
        message: result.message,
        session: result.session,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final current = _formatUtc(_session.deadlineUtc);
    return AlertDialog(
      key: const Key('execution-extension-dialog'),
      title: Row(
        children: [
          Icon(Icons.more_time, size: 18, color: TsColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '延长时间 · ${_session.taskName}',
              style: const TextStyle(fontSize: 15),
            ),
          ),
          IconButton(
            key: const Key('execution-extension-close'),
            icon: const Icon(Icons.close, size: 16),
            splashRadius: 14,
            tooltip: '取消（不会改变截止）',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前有效截止：$current',
                key: const Key('execution-extension-current'),
                style: TextStyle(
                    fontSize: 12, color: TsColors.textSecondary),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _optionChip('+15 分钟', const Duration(minutes: 15)),
                  _optionChip('+30 分钟', const Duration(minutes: 30)),
                  _optionChip('+1 小时', const Duration(hours: 1)),
                  _optionChip('+2 小时', const Duration(hours: 2)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('新截止：',
                      style: TextStyle(
                          fontSize: 12, color: TsColors.textSecondary)),
                  Text(
                    _localLabel,
                    key: const Key('execution-extension-new'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: TsColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('execution-extension-preview-refresh'),
                    style: TsButtons.inline(fontSize: 11.5),
                    onPressed: _previewing ? null : _refreshPreview,
                    child: const Text('重新核对重叠'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_previewing)
                Text('正在核对与已有排程的重叠…',
                    key: const Key('execution-extension-previewing'),
                    style: TextStyle(
                        fontSize: 11, color: TsColors.textFaint))
              else if (preview != null && preview.error != null)
                _noteBox(preview.error!, tone: TsColors.blocked)
              else if (preview != null) ...[
                if (preview.conflicts.isEmpty)
                  Text(
                    '与当前已排片段没有新增重叠。',
                    key: const Key('execution-extension-no-overlap'),
                    style: TextStyle(
                        fontSize: 11, color: TsColors.textSecondary),
                  )
                else
                  Column(
                    key: const Key('execution-extension-overlaps'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('潜在重叠（保存后仍允许带冲突；其它任务不会被自动搬动）：',
                          style: TextStyle(
                              fontSize: 11,
                              color: TsColors.pending,
                              height: 1.5)),
                      for (final line in preview.conflicts)
                        Text('· $line',
                            style: TextStyle(
                                fontSize: 11,
                                color: TsColors.pending,
                                height: 1.5)),
                      if (preview.otherTaskNames.isNotEmpty)
                        Text(
                          '涉及任务：${preview.otherTaskNames.join('、')}',
                          style: TextStyle(
                              fontSize: 11,
                              color: TsColors.textSecondary,
                              height: 1.5),
                        ),
                    ],
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 6),
                _noteBox(
                  _stale ? '$_error；请关闭后按当前真实状态重新操作。' : _error!,
                  key: const Key('execution-extension-error'),
                  tone: TsColors.blocked,
                ),
                if (!_stale)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('原状态已保留，可修正后重试。',
                        style: TextStyle(
                            fontSize: 10.5, color: TsColors.textFaint)),
                  ),
              ],
              const SizedBox(height: 8),
              Text(
                '确认后：保存新的甘特结束时刻 → 重排到期提醒 → 从确认时刻恢复计时。'
                '打开或取消本对话框不会改变截止。',
                style: TextStyle(
                    fontSize: 10.5, height: 1.5, color: TsColors.textFaint),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('execution-extension-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('execution-extension-confirm'),
          style: TsButtons.filled(
            radius: 8,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            fontSize: 12,
          ),
          onPressed: _busy || _stale ? null : _confirm,
          child: Text(_busy ? '保存中…' : '确认延长'),
        ),
      ],
    );
  }

  Widget _optionChip(String label, Duration delta) {
    return OutlinedButton(
      key: Key('execution-extension-option-${delta.inMinutes}'),
      style: TsButtons.outline(
        radius: 8,
        height: 28,
        fontSize: 11.5,
      ),
      onPressed: _busy ? null : () => _pickOption(delta),
      child: Text(label),
    );
  }

  Widget _noteBox(String text, {Key? key, required Color tone}) {
    return Container(
      key: key,
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: TsColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: TsColors.border),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, height: 1.5, color: tone),
      ),
    );
  }
}
