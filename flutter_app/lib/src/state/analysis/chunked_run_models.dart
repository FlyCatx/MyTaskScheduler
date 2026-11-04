// R3-L 接线层的数据视图：预估与运行结果（UI 只依赖这两个小对象）。

import 'chunked_coordinator.dart';

/// 分块分析预估（不发起任何请求）。
class ChunkedEstimateView {
  const ChunkedEstimateView({
    required this.chunkCount,
    required this.estimatedExtractionRequests,
    required this.estimatedMergeRequestsMax,
    required this.maxTotalRequests,
    required this.maxConcurrentRequests,
    required this.maxMergeLayers,
    required this.estimatedMaterialTokens,
    required this.materialBytes,
    required this.singleRequestUtf8Bytes,
    required this.documentCount,
    required this.pageCoverage,
    required this.missingPages,
    required this.costNotice,
    required this.needsChunking,
  });

  final int chunkCount;
  final int estimatedExtractionRequests;
  final int estimatedMergeRequestsMax;
  final int maxTotalRequests;
  final int maxConcurrentRequests;
  final int maxMergeLayers;
  final int estimatedMaterialTokens;
  final int materialBytes;
  final int singleRequestUtf8Bytes;
  final int documentCount;

  /// 每份文档的覆盖说明（例如 `文档A: 1/1 页`）。
  final List<String> pageCoverage;
  final List<String> missingPages;
  final String costNotice;

  /// 材料超过单请求上限（或文档多于 1 份/片段多于 1 段）才建议分块。
  final bool needsChunking;

  factory ChunkedEstimateView.fromEstimate({
    required JobEstimate estimate,
    required int materialBytes,
    required int singleRequestUtf8Bytes,
    required int documentCount,
  }) {
    final coverage = estimate.coverage;
    return ChunkedEstimateView(
      chunkCount: estimate.chunkCount,
      estimatedExtractionRequests: estimate.estimatedExtractionRequests,
      estimatedMergeRequestsMax: estimate.estimatedMergeRequestsMax,
      maxTotalRequests: estimate.maxTotalRequests,
      maxConcurrentRequests: estimate.maxConcurrentRequests,
      maxMergeLayers: estimate.maxMergeLayers,
      estimatedMaterialTokens: estimate.estimatedMaterialTokens,
      materialBytes: materialBytes,
      singleRequestUtf8Bytes: singleRequestUtf8Bytes,
      documentCount: documentCount,
      pageCoverage: coverage.documents
          .map((d) => d.totalPages > 0
              ? '${d.label}: ${d.coveredPages.length}/${d.totalPages} 页、'
                  '${d.coveredSegments}/${d.totalSegments} 段'
              : '${d.label}: ${d.coveredSegments}/${d.totalSegments} 段')
          .toList(growable: false),
      missingPages: <String>[
        for (final d in coverage.documents)
          for (final page in d.missingPages) '${d.label} 第 $page 页',
      ],
      costNotice: estimate.costNotice,
      needsChunking: estimate.chunkCount > 1 ||
          materialBytes > singleRequestUtf8Bytes,
    );
  }
}

/// 一次分块分析的运行结果。
class ChunkedRunResult {
  const ChunkedRunResult({
    required this.ok,
    required this.message,
    this.committedPlanVersionId,
    this.partial = false,
    this.blockers = const <String>[],
    this.pendingConfirmations = 0,
    this.factsCount = 0,
    this.coverageLines = const <String>[],
  });

  final bool ok;
  final String message;

  /// 成功提交后的本地计划版本 id；null = 未提交（预览/失败/取消）。
  final String? committedPlanVersionId;

  /// true = 材料未完整处理；绝不能当作正式计划提交。
  final bool partial;
  final List<String> blockers;
  final int pendingConfirmations;
  final int factsCount;
  final List<String> coverageLines;
}
