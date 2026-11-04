// 分块分析对话框（R3-L 用户入口）。
//
// 只展示协调器给出的真实预估/覆盖/进度，并明确边界：
//   * 费用未知（按实际请求次数与所用模型计费，不虚构金额）；
//   * 材料会分块发送给当前配置的模型（联网），本地分块与归并本身不联网；
//   * 部分块失败/材料未完整覆盖时不给正式计划，只给失败清单与阻塞原因。

import 'package:flutter/material.dart';

import '../../state/analysis/chunked_job.dart';
import '../../state/analysis/chunked_run_models.dart';
import '../../state/app_controller.dart';
import '../theme.dart';
import '../widgets/bezier_ui.dart';

class ChunkedAnalysisDialog extends StatefulWidget {
  const ChunkedAnalysisDialog({
    super.key,
    required this.controller,
    required this.estimate,
  });

  final AppController controller;
  final ChunkedEstimateView estimate;

  static Future<void> show(
    BuildContext context, {
    required AppController controller,
    required ChunkedEstimateView estimate,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChunkedAnalysisDialog(
        controller: controller,
        estimate: estimate,
      ),
    );
  }

  @override
  State<ChunkedAnalysisDialog> createState() => _ChunkedAnalysisDialogState();
}

class _ChunkedAnalysisDialogState extends State<ChunkedAnalysisDialog> {
  bool _running = false;
  JobProgress? _progress;
  ChunkedRunResult? _result;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _progress = null;
    });
    final result = await widget.controller.startChunkedAnalysis(
      onProgress: (progress) {
        if (!mounted) return;
        setState(() => _progress = progress);
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _error = result.ok ? null : result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final estimate = widget.estimate;
    return AlertDialog(
      backgroundColor: TsColors.surface,
      shape: const BezierRoundedRectangleBorder(radius: 14),
      title: Row(
        children: [
          Icon(Icons.call_split, size: 16, color: TsColors.accent),
          const SizedBox(width: 8),
          const Text('分块分析', style: TextStyle(fontSize: 15)),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('材料文档', '${estimate.documentCount} 份'),
              _row('本地材料', '${_formattedBytes(estimate.materialBytes)} / '
                  '单请求上限 ${_formattedBytes(estimate.singleRequestUtf8Bytes)}'),
              _row('分块数', '${estimate.chunkCount} 块'),
              _row('预计模型请求',
                  '${estimate.estimatedExtractionRequests} 次抽取'
                  ' + 最多 ${estimate.estimatedMergeRequestsMax} 次归并'
                  '（总上限 ${estimate.maxTotalRequests}）'),
              _row('并发上限', '${estimate.maxConcurrentRequests}（默认低并发）'),
              _row('材料 token（估算）',
                  '${estimate.estimatedMaterialTokens}（保守估算，不是计费依据）'),
              const SizedBox(height: 8),
              if (estimate.pageCoverage.isNotEmpty) ...[
                Text('页面/片段覆盖',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: TsColors.textFaint)),
                const SizedBox(height: 4),
                for (final line in estimate.pageCoverage)
                  Text('· $line',
                      style: TextStyle(
                          fontSize: 12, color: TsColors.textSecondary)),
              ],
              if (estimate.missingPages.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('缺页（不能当作完整材料）：${estimate.missingPages.join('、')}',
                    style: TextStyle(fontSize: 12, color: TsColors.blocked)),
              ],
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: bezierDecoration(color: TsColors.background, radius: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(estimate.costNotice,
                        style: TextStyle(
                            fontSize: 12, color: TsColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(
                      '分块后的材料会分别发送给当前配置的模型（联网）；本地分块、'
                      '事实归并与校验不联网。部分块失败或覆盖不完整时不会生成正式计划。',
                      style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (_progress != null) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _progress!.chunksTotal == 0
                      ? null
                      : _progress!.chunksDone / _progress!.chunksTotal,
                  minHeight: 6,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_progress!.phase.label} · 已完成 ${_progress!.chunksDone}'
                  '/${_progress!.chunksTotal}，失败 ${_progress!.chunksFailed}，'
                  '请求 ${_progress!.requestsUsed}',
                  key: const Key('chunked-progress'),
                  style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                ),
                if (_progress!.message != null && _progress!.message!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_progress!.message!,
                        style: TextStyle(
                            fontSize: 11.5, color: TsColors.textFaint)),
                  ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 12),
                Text(_result!.message,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: _result!.ok ? TsColors.ready : TsColors.blocked)),
                if (_result!.factsCount > 0)
                  Text(
                    '事实账本：${_result!.factsCount} 条，待确认 ${_result!.pendingConfirmations} 条',
                    style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                  ),
                if (_result!.coverageLines.isNotEmpty)
                  for (final line in _result!.coverageLines)
                    Text('· $line',
                        style: TextStyle(
                            fontSize: 11.5, color: TsColors.textFaint)),
                if (_result!.blockers.isNotEmpty)
                  for (final blocker in _result!.blockers)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('阻塞：$blocker',
                          style: TextStyle(
                              fontSize: 12, color: TsColors.blocked)),
                    ),
              ],
              if (_error != null && _result == null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: TextStyle(fontSize: 12.5, color: TsColors.blocked)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('chunked-cancel'),
          onPressed: _running
              ? () {
                  widget.controller.cancelChunkedAnalysis();
                }
              : () => Navigator.of(context).pop(),
          child: Text(_running ? '取消本次分析' : '关闭'),
        ),
        if (!_running && _result == null)
          FilledButton(
            key: const Key('chunked-start'),
            onPressed: _start,
            child: const Text('开始分块分析'),
          ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: TsColors.textFaint)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  static String _formattedBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(2)} MB';
  }
}
