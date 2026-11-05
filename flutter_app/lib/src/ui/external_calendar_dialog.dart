// 本地 ICS 日历「只读导入」向导。
//
// 流程：选择文件 → 读取并展开预览（来源名/规划时区/覆盖范围/读取事件数/展开实例数/
// 占用分钟/透明与取消计数/待新增·修改·移除/警告/样例事件）→ 合并（默认）或完整替换
// （二次确认显示将移除的数量与范围）→ 提交。
//
// 约束：
//   * 外部日历是只读输入：这里只写 ExternalCalendarStore 的快照，绝不写手工时间表；
//   * 取消、读取失败、提交失败都不修改任何已有数据，也不显示“成功导入 0 项”；
//   * 文件选择能力可注入（测试注入假回调）；生产由应用层注册
//     [ExternalCalendarFilePicker.defaultPick]（默认接 NativeGateway.pickTextFiles）。
//
// 主要函数/类型：showExternalCalendarImportDialog、ExternalCalendarFilePicker。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../model/calendar.dart';
import '../model/external_calendar.dart';
import '../state/external_calendar_service.dart';
import 'theme.dart';
import 'widgets/bezier_ui.dart';

/// 打开系统「选择文件」对话框并返回绝对路径；返回空列表表示用户取消。
///
/// 之所以做成可注入回调：widget 测试不能加载真实 ts_bridge.dll，而生产实现
/// 需要 NativeGateway 实例（由应用启动流程持有）。
typedef ExternalCalendarPickFiles = Future<List<String>> Function();

/// 生产接线的默认文件选择器。
///
/// 应用层（bootstrap）在拿到 NativeGateway 后注册一次：
/// ```dart
/// ExternalCalendarFilePicker.defaultPick =
///     () => gateway.pickTextFiles(title: '选择 ICS 日历文件（.ics）');
/// ```
/// 未注册时向导会明确报错，而不是假装成功。
class ExternalCalendarFilePicker {
  ExternalCalendarFilePicker._();

  /// 未接线时为 null，向导显示明确的“文件选择不可用”原因。
  static ExternalCalendarPickFiles? defaultPick;
}

/// 打开导入向导；提交成功返回 true（调用方据此刷新只读占用）。
///
/// [planningDateFrom]/[planningDateTo] 决定展开实例的范围（与排程覆盖范围一致），
/// 事件本身仍完整保存在快照里，之后改排程范围不需要重新选文件。
Future<bool> showExternalCalendarImportDialog(
  BuildContext context, {
  required ExternalCalendarService service,
  required String timezoneId,
  required String planningDateFrom,
  required String planningDateTo,
  ExternalCalendarSource? existingSource,
  bool replaceModeDefault = false,
  ExternalCalendarPickFiles? pickFiles,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExternalCalendarImportDialog(
      service: service,
      timezoneId: timezoneId,
      planningDateFrom: planningDateFrom,
      planningDateTo: planningDateTo,
      existingSource: existingSource,
      replaceModeDefault: replaceModeDefault,
      pickFiles: pickFiles,
    ),
  );
  return result ?? false;
}

class _ExternalCalendarImportDialog extends StatefulWidget {
  const _ExternalCalendarImportDialog({
    required this.service,
    required this.timezoneId,
    required this.planningDateFrom,
    required this.planningDateTo,
    this.existingSource,
    this.replaceModeDefault = false,
    this.pickFiles,
  });

  final ExternalCalendarService service;
  final String timezoneId;
  final String planningDateFrom;
  final String planningDateTo;
  final ExternalCalendarSource? existingSource;
  final bool replaceModeDefault;
  final ExternalCalendarPickFiles? pickFiles;

  @override
  State<_ExternalCalendarImportDialog> createState() =>
      _ExternalCalendarImportDialogState();
}

class _ExternalCalendarImportDialogState
    extends State<_ExternalCalendarImportDialog> {
  String? _filePath;
  ExternalImportPreview? _preview;
  bool _busy = false;
  String? _error;

  late bool _replaceMode = widget.replaceModeDefault;
  ExternalBusyPolicy _busyPolicy = ExternalBusyPolicy.tentativeCountsAsBusy;
  late bool _floatingConfirmed = true;

  /// 防止迟到的 preview 结果覆盖新的一次选择（取消/重选时守卫）。
  int _requestId = 0;

  ExternalCalendarSource? get _existing => widget.existingSource;

  ExternalCalendarPolicy get _policy => ExternalCalendarPolicy(
        busyPolicy: _busyPolicy,
        floatingTimezoneId: widget.timezoneId,
        floatingConfirmed: _floatingConfirmed,
      );

  @override
  void initState() {
    super.initState();
    // 合并模式对“更新已有来源”才有意义；新建来源时合并/替换等价。
    if (_existing == null) _replaceMode = false;
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    final pick = widget.pickFiles ?? ExternalCalendarFilePicker.defaultPick;
    if (pick == null) {
      setState(() => _error =
          '文件选择不可用：应用还没有接入原生文件选择。'
          '请在应用启动时注册 ExternalCalendarFilePicker.defaultPick，'
          '或从调用方传入 pickFiles 回调。');
      return;
    }
    List<String> paths;
    try {
      paths = await pick();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '打开文件对话框失败：${_short(e)}');
      return;
    }
    if (!mounted || paths.isEmpty) return; // 用户取消：不改任何状态
    await _loadPreview(paths.first);
  }

  /// 读取并生成预览；失败（null/异常）时只显示原因，不写入任何数据。
  Future<void> _loadPreview(String path) async {
    final requestId = ++_requestId;
    setState(() {
      _filePath = path;
      _busy = true;
      _error = null;
    });
    ExternalImportPreview? preview;
    String? failure;
    try {
      preview = await widget.service.preview(
        filePath: path,
        existing: _existing,
        timezoneId: widget.timezoneId,
        policy: _policy,
        dateFrom: widget.planningDateFrom,
        dateTo: widget.planningDateTo,
        replaceMode: _replaceMode && _existing != null,
      );
      if (preview == null) {
        failure = widget.service.lastError ?? '无法读取该文件（不是有效的 ICS 日历？）';
      }
    } catch (e) {
      failure = '读取日历失败：${_short(e)}';
    }
    if (!mounted || requestId != _requestId) return;
    setState(() {
      _busy = false;
      _preview = preview;
      _error = failure;
    });
  }

  /// 已选文件后改策略/模式：重新生成预览，草稿数据不受影响。
  Future<void> _refreshPreview() async {
    final path = _filePath;
    if (path == null || _busy) return;
    await _loadPreview(path);
  }

  /// 预览层面的阻断原因：空文件或只有不支持组件时必须明确报错。
  String? _blockingError() {
    final preview = _preview;
    if (preview == null) return null;
    if (preview.snapshot.events.isNotEmpty) return null;
    final unsupported = preview.diff.unsupported;
    if (unsupported > 0) {
      return '该文件没有可导入的日历事件：$unsupported 个事件使用了不支持的组件或时间规则'
          '（VTODO/VALARM/VJOURNAL 等组件只统计、不导入），本次不会写入任何数据。';
    }
    return '该文件没有可导入的日历事件（空文件，或只包含不支持组件的文件），'
        '本次不会写入任何数据。';
  }

  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null || _busy) return;
    if (_blockingError() != null) return;
    // 完整替换是破坏性操作：二次确认要显示将移除的数量与范围。
    if (_replaceMode && _existing != null) {
      final confirmed = await _confirmReplace(preview);
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var ok = false;
    String? failure;
    try {
      ok = await widget.service.commit(preview);
      if (!ok) {
        failure = widget.service.lastError ?? '提交失败：外部日历数据未被修改';
      }
    } catch (e) {
      failure = '提交失败：${_short(e)}';
    }
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = failure ?? '提交失败：外部日历数据未被修改';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// 完整替换的二次确认：显示移除数量、旧/新覆盖范围与新增/修改数量。
  Future<bool?> _confirmReplace(ExternalImportPreview preview) {
    final existing = _existing;
    final diff = preview.diff;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('external-calendar-replace-confirm-dialog'),
        backgroundColor: TsColors.surface,
        title: const Text('完整替换这个来源？', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: Text(
            '完整替换会移除新文件里没有的事件，而不是合并。\n\n'
            '· 将移除：${diff.removed} 条事件\n'
            '· 原覆盖范围：${existing?.dateFrom ?? '—'} 至 ${existing?.dateTo ?? '—'}\n'
            '· 新覆盖范围：${preview.candidate.dateFrom} 至 '
            '${preview.candidate.dateTo}\n'
            '· 待新增 ${diff.added} 条、修改 ${diff.updated} 条\n\n'
            '手工时间表、任务与其它来源不受影响；导入后仍可再次重新导入。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: TsColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('external-calendar-replace-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回预览'),
          ),
          TextButton(
            key: const Key('external-calendar-replace-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TsButtons.filled(radius: 8),
            child: const Text('确认完整替换'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.min(760.0, math.max(340.0, media.size.width - 64));
    final height = math.min(660.0, math.max(320.0, media.size.height - 64));
    final preview = _preview;
    final blocking = _blockingError();
    return Dialog(
      key: const Key('external-calendar-import-dialog'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const BezierRoundedRectangleBorder(radius: 16),
      child: SizedBox(
        key: const Key('external-calendar-import-card'),
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(),
            Divider(height: 1, color: TsColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _fileRow(),
                    const SizedBox(height: 8),
                    _policyRow(),
                    const SizedBox(height: 10),
                    if (_busy)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 1.6),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '正在读取并展开日历…',
                              key: const Key('external-calendar-import-status'),
                              style: TextStyle(
                                  fontSize: 11.5, color: TsColors.textFaint),
                            ),
                          ],
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          _error!,
                          key: const Key('external-calendar-import-error'),
                          style:
                              TextStyle(fontSize: 11.5, color: TsColors.blocked),
                        ),
                      ),
                    if (blocking != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          blocking,
                          key: const Key('external-calendar-import-blocked'),
                          style:
                              TextStyle(fontSize: 11.5, color: TsColors.blocked),
                        ),
                      ),
                    if (preview != null) ...[
                      _previewSummary(preview),
                      const SizedBox(height: 10),
                      _diffRow(preview),
                      const SizedBox(height: 10),
                      _warnings(preview),
                      const SizedBox(height: 10),
                      _samples(preview),
                    ],
                  ],
                ),
              ),
            ),
            _footer(blocking != null),
          ],
        ),
      ),
    );
  }

  Widget _titleRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 8),
      child: Row(
        children: [
          Icon(Icons.event_available_outlined, size: 17, color: TsColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _existing == null ? '导入外部日历' : '重新导入「${_existing!.name}」',
              style: const TextStyle(fontSize: 15),
              softWrap: true,
            ),
          ),
          IconButton(
            key: const Key('external-calendar-import-close'),
            tooltip: '关闭',
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            style: TsButtons.closeIcon(size: 28),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _fileRow() {
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          height: 32,
          child: FilledButton.icon(
            key: const Key('external-calendar-pick-file'),
            onPressed: _busy ? null : _pickFile,
            style: TsButtons.filled(
              radius: 8,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              fontSize: 11.5,
            ),
            icon: const Icon(Icons.folder_open, size: 15),
            label: Text(_filePath == null ? '选择 ICS 文件…' : '重新选择文件…'),
          ),
        ),
        Text(
          _filePath == null ? '尚未选择文件' : _fileName(_filePath!),
          key: const Key('external-calendar-file-name'),
          style: TextStyle(fontSize: 11, color: TsColors.textFaint),
        ),
        if (_filePath != null)
          Text(
            '规划范围 ${widget.planningDateFrom} 至 ${widget.planningDateTo}',
            style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
          ),
      ],
    );
  }

  Widget _policyRow() {
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('暂定/透明处理：',
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary)),
            DropdownButton<ExternalBusyPolicy>(
              key: const Key('external-calendar-busy-policy'),
              value: _busyPolicy,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
              items: const [
                DropdownMenuItem(
                  value: ExternalBusyPolicy.opaqueOnly,
                  child: Text('仅非透明占用', style: TextStyle(fontSize: 11.5)),
                ),
                DropdownMenuItem(
                  value: ExternalBusyPolicy.tentativeCountsAsBusy,
                  child: Text('暂定也算占用', style: TextStyle(fontSize: 11.5)),
                ),
                DropdownMenuItem(
                  value: ExternalBusyPolicy.allCountsAsBusy,
                  child: Text('透明也算占用', style: TextStyle(fontSize: 11.5)),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _busyPolicy = value);
                      _refreshPreview();
                    },
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              key: const Key('external-calendar-floating-confirm'),
              value: _floatingConfirmed,
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _floatingConfirmed = value == true);
                      _refreshPreview();
                    },
            ),
            Flexible(
              child: Text(
                '无时区时间按 ${widget.timezoneId} 解释',
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _previewSummary(ExternalImportPreview preview) {
    final candidate = preview.candidate;
    final stats = candidate.stats;
    return Container(
      key: const Key('external-calendar-preview'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 10,
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('来源名', candidate.name),
          _kv('目标时区', widget.timezoneId),
          _kv('覆盖范围', '${candidate.dateFrom} 至 ${candidate.dateTo}'),
          _kv(
            '读取事件数 / 展开实例数',
            '${stats.readEvents} 条事件 · ${stats.expandedInstances} 个实例',
          ),
          _kv('占用分钟', '${stats.busyMinutes} 分钟'),
          _kv(
            '透明 / 取消 / 暂定',
            '透明 ${stats.transparentEvents} · 取消 ${stats.cancelledEvents} · '
                '暂定实例 ${stats.tentativeInstances}',
          ),
          _kv('不支持 / 警告', '${stats.unsupportedCount} / ${stats.warningCount}'),
          if (preview.summaryLine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                preview.summaryLine,
                key: const Key('external-calendar-summary-line'),
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
            ),
          if (!preview.hasChanges)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '与已导入内容相比没有变化：提交不会产生新版本。',
                key: const Key('external-calendar-no-changes'),
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
              ),
            ),
          if (preview.truncated)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '结果不完整：触发了资源上限（实例/天数），只统计了部分事件；'
                '请缩小导入范围或减少重复规则后重试。',
                key: const Key('external-calendar-truncated'),
                style: TextStyle(fontSize: 10.5, color: TsColors.pending),
              ),
            ),
        ],
      ),
    );
  }

  Widget _diffRow(ExternalImportPreview preview) {
    final diff = preview.diff;
    return Wrap(
      key: const Key('external-calendar-diff'),
      spacing: 12,
      runSpacing: 2,
      children: [
        Text('待新增 ${diff.added}', style: _diffStyle(TsColors.ready)),
        Text('待修改 ${diff.updated}', style: _diffStyle(TsColors.waiting)),
        Text('待移除 ${diff.removed}', style: _diffStyle(TsColors.blocked)),
        Text('不变 ${diff.unchanged}', style: _diffStyle(TsColors.textFaint)),
        Text('不支持 ${diff.unsupported}', style: _diffStyle(TsColors.pending)),
        if (diff.removed == 0 && diff.added == 0 && diff.updated == 0)
          Text('（本次导入不会改变已保存的实例）',
              style: _diffStyle(TsColors.textFaint)),
      ],
    );
  }

  TextStyle _diffStyle(Color color) => TextStyle(fontSize: 11, color: color);

  Widget _warnings(ExternalImportPreview preview) {
    final warnings = preview.warnings.isNotEmpty
        ? preview.warnings
        : preview.snapshot.warnings;
    return Column(
      key: const Key('external-calendar-warnings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '警告 ${warnings.length} 条',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: warnings.isEmpty ? TsColors.textFaint : TsColors.pending,
          ),
        ),
        if (warnings.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('没有警告。',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
          )
        else
          for (final warning in warnings.take(6))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '· ${warning.code.isEmpty ? '' : '[${warning.code}] '}'
                '${warning.message}',
                style: TextStyle(
                    fontSize: 10.5, height: 1.45, color: TsColors.textSecondary),
              ),
            ),
        if (warnings.length > 6)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('…另有 ${warnings.length - 6} 条警告',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
          ),
      ],
    );
  }

  Widget _samples(ExternalImportPreview preview) {
    final samples = _sampleEvents(preview.snapshot.events);
    return Column(
      key: const Key('external-calendar-samples'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '样例事件（共 ${preview.snapshot.events.length} 条，最多显示 6 条）',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: TsColors.textPrimary,
          ),
        ),
        if (samples.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('没有可显示的事件。',
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
          )
        else
          for (final sample in samples)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                _sampleLabel(sample),
                key: Key('external-calendar-sample-${sample.identityKey}'),
                style: TextStyle(
                    fontSize: 10.5, height: 1.5, color: TsColors.textSecondary),
              ),
            ),
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label,
                style: TextStyle(fontSize: 11, color: TsColors.textFaint)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 11.5, height: 1.45, color: TsColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _footer(bool blocked) {
    final preview = _preview;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: TsColors.border)),
      ),
      // 常驻模式说明已删除：合并/完整替换由主题分段控件表达。动作组显式右对齐；
      // 窄窗时 Wrap 让分段控件整组换行，提交按钮保持 32 高 + 14 横内边距的热区。
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          if (_existing != null)
            BezierSegments(
              key: const Key('external-calendar-mode-segments'),
              items: const <BezierSegmentItem>[
                BezierSegmentItem('合并'),
                BezierSegmentItem('完整替换'),
              ],
              selected: _replaceMode ? 1 : 0,
              itemKeys: const <Key?>[
                Key('external-calendar-mode-merge'),
                Key('external-calendar-mode-replace'),
              ],
              enabled: !_busy,
              onChanged: (index) {
                final replace = index == 1;
                if (replace == _replaceMode) return;
                setState(() => _replaceMode = replace);
                _refreshPreview();
              },
            ),
          TextButton(
            key: const Key('external-calendar-import-cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          SizedBox(
            height: 32,
            child: FilledButton(
              key: const Key('external-calendar-import-confirm'),
              onPressed: (_busy || preview == null || blocked) ? null : _confirm,
              style: TsButtons.filled(
                radius: 8,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                fontSize: 11.5,
              ),
              child: Text(_replaceMode && _existing != null ? '完整替换导入' : '合并导入'),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 样例格式化

  ExternalEventRecord? _firstWhere(
      Iterable<ExternalEventRecord> events,
      bool Function(ExternalEventRecord) test) {
    for (final event in events) {
      if (test(event)) return event;
    }
    return null;
  }

  /// 样例优先覆盖：全天、跨午夜，再按文件顺序补足。
  List<ExternalEventRecord> _sampleEvents(List<ExternalEventRecord> events) {
    final picks = <ExternalEventRecord>[];
    void add(ExternalEventRecord? event) {
      if (event == null || picks.contains(event)) return;
      picks.add(event);
    }

    add(_firstWhere(events, (e) => e.allDay));
    add(_firstWhere(events, (e) => !e.allDay && _crossesMidnight(e)));
    for (final event in events) {
      if (picks.length >= 6) break;
      add(event);
    }
    return picks;
  }

  bool _crossesMidnight(ExternalEventRecord event) {
    final times = _localTimes(event);
    if (times == null) return false;
    final start = times.start;
    final end = times.end;
    if (end.day == start.day) return false;
    // 23:00-00:00 这种“到当日结束”不算跨午夜。
    return !(end.hour == 0 && end.minute == 0);
  }

  ({DateTime start, DateTime end})? _localTimes(ExternalEventRecord event) {
    final startUtc = DateTime.tryParse(event.startUtc)?.toUtc();
    final endUtc = DateTime.tryParse(event.endUtc)?.toUtc();
    if (startUtc == null || endUtc == null) return null;
    try {
      final location = tz.getLocation(widget.timezoneId);
      return (
        start: tz.TZDateTime.from(startUtc, location),
        end: tz.TZDateTime.from(endUtc, location),
      );
    } catch (_) {
      // 时区数据库未初始化或时区未知：退回 UTC，不猜测其它时区。
      return (start: startUtc, end: endUtc);
    }
  }

  String _sampleLabel(ExternalEventRecord event) {
    final times = _localTimes(event);
    final title = event.summary.trim().isEmpty ? '（无标题）' : event.summary.trim();
    final suffix = StringBuffer();
    if (event.allDay) suffix.write(' · 全天');
    if (event.status == 'tentative') suffix.write(' · 暂定');
    if (event.status == 'cancelled') suffix.write(' · 已取消');
    if (event.transparency == 'transparent') suffix.write(' · 透明');
    if (event.rrule != null) suffix.write(' · 重复');
    if (times == null) {
      return '$title · ${event.startUtc}–${event.endUtc}$suffix';
    }
    final start = times.start;
    final end = times.end;
    if (event.allDay) {
      return '$title · 全天 ${_ymd(start)}$suffix';
    }
    final crossMidnight = _crossesMidnight(event);
    final timeLabel = crossMidnight
        ? '${_ymd(start)} ${_hhmm(start)}–${_ymd(end)} ${_hhmm(end)}（跨午夜）'
        : '${_ymd(start)} ${_hhmm(start)}–${_hhmm(end)}';
    return '$title · $timeLabel$suffix';
  }

  static String _ymd(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _hhmm(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? path : normalized.substring(index + 1);
  }

  static String _short(Object error) {
    final text = error.toString().replaceAll('\n', ' ');
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}

/// 供测试/其它 UI 复用：把实例的分钟区间格式化为 `HH:mm-HH:mm`。
String externalBusyTimeLabel(ExternalBusyInstance instance) =>
    '${WallClockRange.formatMinute(instance.startMinute)}-'
    '${WallClockRange.formatMinute(instance.endMinute)}';
