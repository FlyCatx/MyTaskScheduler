// 分块分析协调器 — 把超大材料变成有界、可恢复、可核查的多请求作业。
//
// 流程（R3-L L3/L4/L5）：
//   1. planning   固定作业基线（asOf/时区/计划版本/材料哈希/模型配置），
//                 按请求预算分块，输出覆盖清单与预计请求数；
//   2. extracting 有界 waves（并发上限 / 总请求数 / 失败阈值 / 退避重试上限），
//                 每个块一次抽取请求；取消后的迟到结果直接丢弃；
//   3. normalizing/correlating 本地校验、来源归一、跨块关联去重；
//   4. merging    仅当事实索引仍超出归并上下文时，做有限多层全局归并；
//                 每层保留 factId 与来源，未解析引用不丢；
//   5. validating 本地正式校验 → 预览草稿。
//
// 明确的产品边界：
//   * transport 由调用方注入（测试用 mock，无网络）；本文件不读网络/文件；
//   * 部分块失败/预算耗尽/覆盖不完整/来源凭空引用时，
//     [ChunkedJobOutcome.officialPlanAvailable] 为 false，
//     [ChunkedJobOutcome.officialPlanJson] 为 null —— 不产出“貌似完整”的正式计划；
//   * 时间表 busy 区间随每个请求完整发送，预算不足时显式失败，绝不省略/缩短；
//   * 预算耗尽只保留进度并提示，不循环到成功，不自动扩大预算。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'analysis_budget.dart';
import 'chunked_job.dart';
import 'fact_ledger.dart';
import 'material_chunker.dart';
import 'model_output_parser.dart';

/// 一次分块模型请求。`payload` 是可直接交给 NativeGateway.analyzeAsync 的请求 map
/// （见文件末尾的接线示例注释）。
class ChunkRequest {
  const ChunkRequest({
    required this.jobId,
    required this.chunkId,
    required this.requestId,
    required this.phase,
    required this.attempt,
    required this.payload,
    required this.utf8Bytes,
    required this.estimatedTokens,
  });

  final String jobId;
  final String chunkId;
  final String requestId;

  /// `chunk_extract` 或 `merge`。
  final String phase;
  final int attempt;
  final Map<String, dynamic> payload;
  final int utf8Bytes;
  final int estimatedTokens;
}

/// 一次分块模型请求的结果。
class ChunkResponse {
  const ChunkResponse.ok(
    this.content, {
    this.httpStatus = 200,
    this.usage,
  })  : ok = true,
        errorKind = null,
        error = null,
        retryable = false,
        retryAfterMs = null,
        duplicateBillingRisk = false;

  const ChunkResponse.failure({
    required this.errorKind,
    required this.error,
    this.httpStatus,
    this.retryable = false,
    this.retryAfterMs,
    this.duplicateBillingRisk = false,
  })  : ok = false,
        content = null,
        usage = null;

  final bool ok;

  /// 模型原始内容（严格 JSON 文本）。原生层需要把模型输出原文透传到这里。
  final String? content;
  final String? errorKind;
  final String? error;
  final int? httpStatus;
  final bool retryable;
  final int? retryAfterMs;

  /// 超时/中断等“结果未知”的情况：服务可能已完成并计费。
  final bool duplicateBillingRisk;
  final Map<String, dynamic>? usage;
}

/// 注入的模型传输层。测试用 mock；生产由 app_controller 接到 NativeGateway。
typedef ChunkModelTransport = Future<ChunkResponse> Function(ChunkRequest request);

/// 作业输入规格：所有字段是“每次分析运行时”需要固定下来的事实。
class AnalysisJobSpec {
  const AnalysisJobSpec({
    required this.conversationId,
    required this.userRequest,
    required this.asOf,
    required this.timeZoneId,
    this.timezoneOffsetMinutes = 0,
    this.baseVersionId,
    this.baseRevision = 0,
    this.calendarRevision = -1,
    this.planContext,
    this.knownTasks = const <Map<String, dynamic>>[],
    this.timetableJson,
    this.effectiveTimetableJson,
    this.externalSources = const <Map<String, dynamic>>[],
    this.modelSelection,
    this.modelConfigSignature = '',
    this.documents = const <SourceDocument>[],
    this.promptVersion = 'chunk-extract-v1',
  });

  final String conversationId;

  /// 用户的自然语言要求（所有块共用；不在块之间改写）。
  final String userRequest;

  /// 固定基准时间：相对日期按它解析，所有块一致，不随跨午夜漂移。
  final DateTime asOf;
  final String timeZoneId;
  final int timezoneOffsetMinutes;
  final String? baseVersionId;
  final int baseRevision;

  /// 请求携带的时间表 revision；-1 = 本次不携带时间表。
  final int calendarRevision;
  final String? planContext;
  final List<Map<String, dynamic>> knownTasks;

  /// 完整时间表（busy 区间）。为 null 表示本次作业不携带时间表。
  final Map<String, dynamic>? timetableJson;

  /// 同一快照派生的 effectiveTimetable；与 [timetableJson] 必须同时存在。
  final Map<String, dynamic>? effectiveTimetableJson;

  /// 外部日历来源身份（只含 id/revision/范围，不含事件内容）。
  final List<Map<String, dynamic>> externalSources;

  /// 模型选择（透传给原生层），不是密钥。
  final Map<String, dynamic>? modelSelection;

  /// 模型配置指纹（不含密钥）。
  final String modelConfigSignature;

  /// 材料文档（按顺序分块）。
  final List<SourceDocument> documents;
  final String promptVersion;

  /// 作业输入是否自洽；返回 null 表示合法。
  String? validate() {
    if (conversationId.trim().isEmpty) return '缺少会话 id';
    if (asOf.year < 1970) return '作业基准时间不合法';
    if (timeZoneId.trim().isEmpty) return '缺少时区 id';
    if (documents.isEmpty) return '没有可分析的材料';
    final hashes = <String>{};
    for (final doc in documents) {
      if (doc.docHash.trim().isEmpty) {
        return '材料「${doc.label}」缺少内容哈希';
      }
      if (!hashes.add(doc.docHash)) {
        return '材料哈希重复（${doc.docHash}）；请重新读取文件';
      }
    }
    final hasTimetable = timetableJson != null;
    final hasEffective = effectiveTimetableJson != null;
    if (hasTimetable != hasEffective) {
      return '时间表与 effectiveTimetable 必须来自同一快照（不能只发其中一份）';
    }
    if (hasTimetable && calendarRevision < 0) {
      return '携带时间表时必须提供 calendarRevision';
    }
    return null;
  }

  Map<String, String> get materialHashes => <String, String>{
        for (final doc in documents) doc.docHash: doc.label,
      };

  String get userRequestHash =>
      hashJson(<String, dynamic>{'userRequest': userRequest, 'planContext': planContext});

  String? get timetableSignature =>
      timetableJson == null ? null : hashJson(timetableJson);

  JobBaseline buildBaseline() => JobBaseline(
        asOf: asOf,
        timeZoneId: timeZoneId,
        timezoneOffsetMinutes: timezoneOffsetMinutes,
        baseVersionId: baseVersionId,
        baseRevision: baseRevision,
        calendarRevision: calendarRevision,
        materialHashes: materialHashes,
        modelConfigSignature: modelConfigSignature,
        userRequestHash: userRequestHash,
        timetableSignature: timetableSignature,
        externalSources: externalSources,
        promptVersion: promptVersion,
      );
}

/// 作业预估价（费用未知，不虚构金额）。
class JobEstimate {
  const JobEstimate({
    required this.chunkCount,
    required this.estimatedExtractionRequests,
    required this.estimatedMergeRequestsMax,
    required this.maxTotalRequests,
    required this.maxConcurrentRequests,
    required this.maxMergeLayers,
    required this.estimatedMaterialTokens,
    required this.coverage,
  });

  final int chunkCount;
  final int estimatedExtractionRequests;
  final int estimatedMergeRequestsMax;
  final int maxTotalRequests;
  final int maxConcurrentRequests;
  final int maxMergeLayers;
  final int estimatedMaterialTokens;
  final CoverageManifest coverage;

  /// 费用说明：成本未知就显示未知。
  String get costNotice =>
      '费用未知：按实际发起的请求次数与所用模型计费为准；本预估不含价格信息';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunkCount': chunkCount,
        'estimatedExtractionRequests': estimatedExtractionRequests,
        'estimatedMergeRequestsMax': estimatedMergeRequestsMax,
        'maxTotalRequests': maxTotalRequests,
        'maxConcurrentRequests': maxConcurrentRequests,
        'maxMergeLayers': maxMergeLayers,
        'estimatedMaterialTokens': estimatedMaterialTokens,
        'costNotice': costNotice,
        'coverage': coverage.toJson(),
      };
}

/// 预览草稿中的一个候选任务（本地稳定候选 ID，尚未提交为正式任务）。
class DraftTaskCandidate {
  const DraftTaskCandidate({
    required this.candidateId,
    required this.name,
    this.estimatedHours,
    this.deadline,
    this.dependsOn = const <String>[],
    this.sourceRefs = const <String>[],
    this.sourceSegmentIds = const <String>[],
    this.pendingNote,
  });

  final String candidateId;
  final String name;
  final double? estimatedHours;
  final String? deadline;

  /// 已解析的候选任务 ID；未解析依赖在 notes 里保留。
  final List<String> dependsOn;

  /// 来源身份（片段 ID 列表），供计划版本追溯。
  final List<String> sourceRefs;
  final List<String> sourceSegmentIds;
  final String? pendingNote;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'candidateId': candidateId,
        'name': name,
        'estimatedHours': estimatedHours,
        'deadline': deadline,
        'dependsOn': dependsOn,
        'sourceRefs': sourceRefs,
        'sourceSegmentIds': sourceSegmentIds,
        'pendingNote': pendingNote,
      };
}

/// 预览草稿中的一条说明/待确认项。
class DraftNote {
  const DraftNote({required this.kind, required this.text, this.taskRefs = const <String>[]});

  /// `question` / `blocked` / `assumption`（与 PlanNote 的 kind 对齐）。
  final String kind;
  final String text;
  final List<String> taskRefs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'text': text,
        'taskRefs': taskRefs,
      };
}

/// 预览草稿：用户确认前只是草稿，不创建正式版本。
class DraftPlanPreview {
  const DraftPlanPreview({
    required this.jobId,
    required this.partial,
    required this.blockers,
    required this.summary,
    required this.tasks,
    required this.notes,
    required this.pending,
    required this.coverage,
    required this.jobSummary,
    required this.facts,
  });

  final String jobId;

  /// true = 材料未完整处理，不能作为正式计划提交。
  final bool partial;
  final List<String> blockers;
  final String summary;
  final List<DraftTaskCandidate> tasks;
  final List<DraftNote> notes;
  final List<PendingConfirmation> pending;
  final CoverageManifest coverage;
  final Map<String, dynamic> jobSummary;

  /// 账本事实（含待确认），供预览界面展开来源。
  final List<Map<String, dynamic>> facts;

  /// 转成计划 JSON（与 `LocalPlan` 形状对齐；提交前仍应走 app_controller 的
  /// 本地校验/reconcileTasks）。partial 时调用方必须展示 [partial]/[blockers]。
  Map<String, dynamic> toPlanJson() => <String, dynamic>{
        'summary': summary,
        'tasks': <Map<String, dynamic>>[
          for (final task in tasks)
            <String, dynamic>{
              'id': task.candidateId,
              'name': task.name,
              'estimatedHours': task.estimatedHours,
              'deadline': task.deadline,
              'dependsOn': task.dependsOn,
              'sourceRefs': task.sourceRefs,
              'steps': const <String>[],
              'preconditions': const <Map<String, dynamic>>[],
              'urgency': 3,
              'impact': 3,
              'actualStatus': 'todo',
            },
        ],
        'notes': notes.map((n) => n.toJson()).toList(growable: false),
        'partial': partial,
        'blockers': blockers,
        'jobId': jobId,
      };
}

/// 作业最终结果。
class ChunkedJobOutcome {
  const ChunkedJobOutcome({
    required this.job,
    this.ledger,
    this.preview,
    required this.blockers,
    required this.officialPlanAvailable,
    required this.message,
  });

  final ChunkedJob job;
  final FactLedger? ledger;
  final DraftPlanPreview? preview;
  final List<String> blockers;

  /// 只有全部块成功、覆盖完整、无阻塞问题且未被取消时才为 true。
  final bool officialPlanAvailable;

  final String message;

  /// 正式计划 JSON；不可用时为 null（不产出“貌似完整”的正式计划）。
  Map<String, dynamic>? get officialPlanJson =>
      officialPlanAvailable ? preview?.toPlanJson() : null;

  /// 需要用户确认/操作（重试失败块、排除失败块或取消）。
  bool get needsUserConfirmation =>
      !officialPlanAvailable && !job.isCancelled;
}

/// 分块分析协调器。网络/模型调用全部通过注入的 [transport]。
class ChunkedCoordinator {
  ChunkedCoordinator({
    required this.spec,
    required this.limits,
    required this.transport,
    this.parser = const ModelOutputParser(),
    this.tokenEstimator = const TokenEstimator(),
    this.budgetSafetyBytes = 4096,
    this.budgetSafetyTokens = 1024,
    DateTime Function()? clock,
    Future<void> Function(Duration duration)? delay,
  })  : clock = clock ?? DateTime.now,
        delay = delay ?? Future<void>.delayed;

  final AnalysisJobSpec spec;
  final AnalysisLimits limits;
  final ChunkModelTransport transport;
  final ModelOutputParser parser;
  final TokenEstimator tokenEstimator;

  /// 分块时额外预留的信封字节/ token 余量（多片段 source label 等）。
  final int budgetSafetyBytes;
  final int budgetSafetyTokens;
  final DateTime Function() clock;
  final Future<void> Function(Duration duration) delay;

  ChunkPlan? _planCache;
  RequestBudget? _budgetCache;

  // ------------------------------------------------------------- planning

  /// 固定信封探测请求（空材料），用于测量真正的材料可用预算。
  Map<String, dynamic> _probePayload() => _buildPayload(
        jobId: 'job-probe',
        requestId: 'req-probe',
        chunkId: 'chunk:probe',
        phaseName: 'chunk_extract',
        attempt: 1,
        label: '材料片段',
        text: '',
      );

  /// 单次请求的信封预算（扣掉系统提示/时间表/已知任务/用户要求后的剩余量）。
  RequestBudget requestBudget() {
    final cached = _budgetCache;
    if (cached != null) return cached;
    final probe = _probePayload();
    final budget = RequestBudget(
      limits: limits,
      estimator: tokenEstimator,
      envelopeUtf8Bytes: utf8BytesOfJson(probe),
      envelopeTokens: tokenEstimator.estimateJson(probe),
      safetyBytes: budgetSafetyBytes,
      safetyTokens: budgetSafetyTokens,
    );
    _budgetCache = budget;
    return budget;
  }

  /// 分块计划（缓存；材料/限额不变时结果稳定）。
  ///
  /// 分块器只按“材料正文”字节计算；真实请求还要装每个片段的 source 标签。
  /// 这里对每个块**序列化后复核**，超限就缩小块预算重新拆分（绝不截尾）。
  ChunkPlan planChunks() {
    final cached = _planCache;
    if (cached != null) return cached;
    final budget = requestBudget();
    final chunker = MaterialChunker(limits: limits, estimator: tokenEstimator);
    var maxChunk = budget.usable ? budget.remainingUtf8Bytes : 0;
    ChunkPlan? lastPlan;
    for (var attempt = 0; attempt < 6 && maxChunk >= 256; attempt++) {
      final plan = chunker.build(
        spec.documents,
        maxChunkUtf8Bytes: maxChunk,
        overlapUtf8Bytes: limits.overlapUtf8Bytes,
      );
      lastPlan = plan;
      final overflow =
          plan.chunks.where((chunk) => !_chunkRequestFits(chunk)).toList();
      if (overflow.isEmpty) {
        _planCache = plan;
        return plan;
      }
      // 重新拆分：缩小块正文预算（来源标签等固定开销不会消失）。
      maxChunk = math.max(256, (maxChunk * 3) ~/ 4 - 128);
    }
    // 仍无法装入：显式失败并保留覆盖清单，不截断材料。
    final fallback = lastPlan ??
        chunker.build(
          spec.documents,
          maxChunkUtf8Bytes: 0,
          overlapUtf8Bytes: limits.overlapUtf8Bytes,
        );
    final manifest = CoverageManifest(
      documents: fallback.manifest.documents,
      chunkCount: fallback.manifest.chunkCount,
      estimatedExtractionRequests: fallback.manifest.estimatedExtractionRequests,
      estimatedTokens: fallback.manifest.estimatedTokens,
      unsplittable: fallback.manifest.unsplittable,
      issues: <MaterialIssue>[
        ...fallback.manifest.issues,
        const MaterialIssue(
          code: 'request_overhead_unfittable',
          critical: true,
          message: '请求序列化后（含来源标签开销）仍超出单请求上限，且无法再拆分；'
              '请增大单请求上限或减少材料（禁止截断材料）',
        ),
      ],
    );
    final plan = ChunkPlan(chunks: fallback.chunks, manifest: manifest);
    _planCache = plan;
    return plan;
  }

  bool _chunkRequestFits(MaterialChunk chunk) {
    final payload = _extractPayload(
      chunk,
      jobId: 'job-plan-probe',
      requestId: 'req-plan-probe',
      attempt: 1,
    );
    return requestBudget()
        .checkRequest(
          payload,
          expectTimetable: spec.timetableJson != null,
          expectedTimetableSignature: spec.timetableSignature,
        )
        .ok;
  }

  /// 界面预估：分块数、请求数上限、并发、可核查覆盖清单；不虚构费用。
  JobEstimate estimate() {
    final plan = planChunks();
    final chunkCount = plan.chunks.length;
    return JobEstimate(
      chunkCount: chunkCount,
      estimatedExtractionRequests: chunkCount,
      estimatedMergeRequestsMax: chunkCount == 0 ? 0 : limits.maxMergeLayers,
      maxTotalRequests: limits.maxJobTotalRequests,
      maxConcurrentRequests: limits.maxConcurrentRequests,
      maxMergeLayers: limits.maxMergeLayers,
      estimatedMaterialTokens: plan.manifest.estimatedTokens,
      coverage: plan.manifest,
    );
  }

  /// 创建（或从相同材料重建）作业。作业 ID 由基线签名派生，稳定可恢复。
  ChunkedJob createJob({String? jobId}) {
    final baseline = spec.buildBaseline();
    return ChunkedJob.create(
      jobId: jobId ?? 'job-${baseline.signature}',
      baseline: baseline,
      plan: planChunks(),
      limits: limits,
    );
  }

  void cancel(ChunkedJob job) {
    job.cancel();
  }

  // ------------------------------------------------------------------ run

  /// 运行/继续作业。可对持久化恢复后的作业再次调用：
  /// 已成功的块不会重发；结果未知的块保持 needsConfirm，不自动重发。
  Future<ChunkedJobOutcome> run(ChunkedJob job) async {
    final specError = spec.validate();
    if (specError != null) {
      job.setStatus(ChunkJobStatus.failed,
          phase: ChunkPhase.failed, message: '作业参数不合法：$specError');
      return ChunkedJobOutcome(
        job: job,
        blockers: <String>['作业参数不合法：$specError'],
        officialPlanAvailable: false,
        message: '未生成正式计划：作业参数不合法：$specError',
      );
    }
    final expectedBaseline = spec.buildBaseline();
    if (job.baseline.signature != expectedBaseline.signature) {
      const message = '材料/时间表/计划版本/模型配置或基准时间已变化，旧作业已失效：'
          '请重新创建作业（不会自动沿用旧结果）';
      job.setStatus(ChunkJobStatus.needsConfirm,
          phase: ChunkPhase.validating, message: message);
      return ChunkedJobOutcome(
        job: job,
        blockers: const <String>[message],
        officialPlanAvailable: false,
        message: '未生成正式计划：$message',
      );
    }
    if (job.plan.chunks.isEmpty) {
      final reasons = job.plan.manifest.criticalIssues
          .map((i) => i.message)
          .toList(growable: false);
      final message = reasons.isEmpty ? '没有可分析的材料块' : reasons.join('；');
      job.setStatus(ChunkJobStatus.failed,
          phase: ChunkPhase.failed, message: '未生成正式计划：$message');
      return ChunkedJobOutcome(
        job: job,
        blockers: <String>[message],
        officialPlanAvailable: false,
        message: '未生成正式计划：$message',
      );
    }
    if (job.isCancelled) {
      return _cancelledOutcome(job);
    }

    job.setStatus(ChunkJobStatus.running, phase: ChunkPhase.planning);

    await _runExtractionWaves(job);
    if (job.isCancelled) return _cancelledOutcome(job);

    // 抽取阶段因失败阈值/预算提前停止时的原因，必须保留到最终结论（不能被
    // 后续的“未成功块”概括覆盖）。
    final earlyStopMessage = _earlyStopMessage(job);

    if (job.succeededChunkCount == 0) {
      final message =
          earlyStopMessage ?? job.statusMessage ?? '所有材料块均未成功，未生成正式计划';
      job.setStatus(ChunkJobStatus.failed,
          phase: ChunkPhase.failed, message: message);
      return ChunkedJobOutcome(
        job: job,
        blockers: <String>[message],
        officialPlanAvailable: false,
        message: '未生成正式计划：$message',
      );
    }

    // 3) 本地校验/归一 + 跨块关联去重（不花钱，可重复执行）。
    job.setStatus(ChunkJobStatus.running, phase: ChunkPhase.normalizing);
    final ledger = _rebuildLedger(job);
    ledger.reconcile();

    // 4) 有限多层全局归并：仅在事实索引仍超归并上下文时发生。
    //    已经失败/待确认/预算耗尽的作业不再花钱归并（反正不能产出正式计划）。
    final mergeSkipped = job.hasFailedChunks ||
        job.hasUnknownOutcome ||
        job.budget.exhausted ||
        !job.plan.manifest.complete;
    var mergeOk = true;
    if (!mergeSkipped) {
      job.setStatus(ChunkJobStatus.running, phase: ChunkPhase.merging);
      mergeOk = await _runMergeLayers(job, ledger);
    }
    if (job.isCancelled) return _cancelledOutcome(job);

    // 5) 本地正式校验 + 预览草稿。
    job.setStatus(ChunkJobStatus.running, phase: ChunkPhase.validating);
    ledger.reconcile();
    final blockers = _collectBlockers(
      job,
      ledger,
      mergeOk: mergeOk,
      mergeSkipped: mergeSkipped,
      earlyStopMessage: earlyStopMessage,
    );
    final preview = _buildPreview(job, ledger, blockers);
    final official =
        blockers.isEmpty && job.allChunksSucceeded && !job.isCancelled;
    final message = official
        ? '分块分析完成：${job.plan.chunks.length} 个材料块、'
            '${ledger.facts.length} 条事实；正式计划草稿待用户确认'
        : '未生成正式计划：${blockers.join('；')}';
    job.setStatus(
      official ? ChunkJobStatus.succeeded : ChunkJobStatus.needsConfirm,
      phase: ChunkPhase.previewReady,
      message: message,
    );
    return ChunkedJobOutcome(
      job: job,
      ledger: ledger,
      preview: preview,
      blockers: blockers,
      officialPlanAvailable: official,
      message: message,
    );
  }

  ChunkedJobOutcome _cancelledOutcome(ChunkedJob job) {
    const message = '已取消：不接收迟到结果，保留已完成进度，未生成正式计划';
    job.cancel(message: message);
    return ChunkedJobOutcome(
      job: job,
      blockers: const <String>[message],
      officialPlanAvailable: false,
      message: message,
    );
  }

  // ------------------------------------------------------- extraction waves

  Future<void> _runExtractionWaves(ChunkedJob job) async {
    job.setStatus(ChunkJobStatus.running, phase: ChunkPhase.extracting);
    while (true) {
      if (job.isCancelled) return;
      final pending = job.pendingChunks;
      if (pending.isEmpty) break;
      if (job.failedChunkCount > limits.maxFailedChunks) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.extracting,
            message: '失败块数超过阈值 ${limits.maxFailedChunks}；'
                '已停止发起新请求（保留进度，不循环到成功）');
        return;
      }
      if (!job.budget.canStartRequest()) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.extracting,
            message: '预算耗尽（${job.budget.exhaustedReason ?? '请求/token 预算不足'}）；'
                '已保留进度，未循环重试');
        return;
      }
      final wave = pending
          .take(math.max(1, limits.maxConcurrentRequests))
          .toList(growable: false);
      final results =
          await Future.wait(wave.map((state) => _extractChunk(job, state)));
      if (job.isCancelled) return; // 迟到结果已在单块逻辑里丢弃
      if (results.any((r) => r == _ChunkRunResult.budgetExhausted)) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.extracting,
            message: job.statusMessage ?? '预算耗尽；已保留进度，未循环重试');
        return;
      }
      if (job.failedChunkCount > limits.maxFailedChunks) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.extracting,
            message: '失败块数超过阈值 ${limits.maxFailedChunks}；已停止发起新请求');
        return;
      }
    }
  }

  Future<_ChunkRunResult> _extractChunk(ChunkedJob job, ChunkState state) async {
    final chunk = _chunkById(job, state.chunkId);
    while (!job.isCancelled) {
      if (state.attempts >= limits.maxAttemptsPerChunk) {
        job.markChunkFailed(state.chunkId,
            code: 'attempts_exhausted', message: '尝试次数已达上限，块判失败');
        return _ChunkRunResult.failed;
      }
      if (!job.budget.canStartRequest()) {
        return _ChunkRunResult.budgetExhausted;
      }
      final requestId = job.nextRequestId(state.chunkId, 'extract');
      final attempt = job.beginAttempt(
        state.chunkId,
        requestId: requestId,
        requestUtf8Bytes: 0,
        estimatedTokens: chunk.estimatedTokens,
        now: clock(),
      );
      final request = _buildExtractRequest(job, chunk, requestId, attempt.attemptNumber);
      final verdict = requestBudget().checkRequest(
        request.payload,
        expectTimetable: spec.timetableJson != null,
        expectedTimetableSignature: spec.timetableSignature,
      );
      if (!verdict.ok) {
        // 超限只能重新拆分；这里已经过了分块阶段，说明预算假设被破坏：
        // 明确失败并保留进度，绝不截尾后硬发。
        job.finishAttemptFailure(
          attempt,
          code: verdict.isViolation ? 'request_envelope_violation' : 'request_budget_exceeded',
          message: verdict.reason ?? '请求超出预算',
          now: clock(),
          exhausted: true,
        );
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.extracting,
            message: '请求预算复核失败（${verdict.reason}）；请不要截断材料，'
                '请缩小材料或扩大预算后重新分块');
        return _ChunkRunResult.budgetExhausted;
      }
      attempt
        ..requestUtf8Bytes = verdict.utf8Bytes
        ..estimatedTokens = verdict.estimatedTokens;

      ChunkResponse response;
      try {
        response = await transport(request);
      } catch (e) {
        response = ChunkResponse.failure(
          errorKind: 'transport',
          error: '传输层异常：$e',
          retryable: true,
          duplicateBillingRisk: true,
        );
      }
      job.budget.record(tokens: verdict.estimatedTokens, bytes: verdict.utf8Bytes);
      // 取消后到达的结果：不解析、不入账、不保存（丢弃）。
      if (job.isCancelled) return _ChunkRunResult.dropped;

      if (response.ok) {
        final parseOutcome = _parseChunk(job, chunk, response.content ?? '');
        final parsed = parseOutcome.parsed;
        if (parsed != null) {
          job.finishAttemptSuccess(attempt, parsed, now: clock());
          return _ChunkRunResult.success;
        }
        // 结构不符：判块失败并保留原因；坏 JSON 允许有限次重试（默认 1 次）。
        final failure =
            parseOutcome.failure ?? const ParseFailure('invalid_json', '模型输出不是合法 JSON');
        final canRetry = attempt.attemptNumber <= limits.retryParseFailures &&
            attempt.attemptNumber < limits.maxAttemptsPerChunk;
        job.finishAttemptFailure(
          attempt,
          code: failure.code,
          message: failure.message,
          now: clock(),
          duplicateBillingRisk: false,
          exhausted: !canRetry,
        );
        if (!canRetry) return _ChunkRunResult.failed;
        await delay(_backoff(attempt.attemptNumber));
        continue;
      }

      final retryable = _isRetryable(response);
      final duplicateRisk = response.duplicateBillingRisk ||
          response.errorKind == 'timeout' ||
          response.errorKind == 'network' ||
          response.errorKind == 'unknown';
      final canRetry =
          retryable && attempt.attemptNumber < limits.maxAttemptsPerChunk;
      job.finishAttemptFailure(
        attempt,
        code: response.errorKind ?? 'request_failed',
        message: response.error ?? '模型请求失败',
        now: clock(),
        httpStatus: response.httpStatus,
        duplicateBillingRisk: duplicateRisk,
        exhausted: !canRetry,
      );
      if (!canRetry) return _ChunkRunResult.failed;
      await delay(_backoff(attempt.attemptNumber));
    }
    return _ChunkRunResult.dropped;
  }

  _ParseOutcome _parseChunk(
      ChunkedJob job, MaterialChunk chunk, String content) {
    try {
      return _ParseOutcome.success(parser.parseChunk(
        content,
        context: ChunkParseContext(
          jobId: job.jobId,
          chunkId: chunk.chunkId,
          asOf: job.baseline.asOf,
          timeZoneId: job.baseline.timeZoneId,
          knownSegmentIds: chunk.segmentIds.toSet(),
        ),
      ));
    } on ParseFailure catch (e) {
      return _ParseOutcome.failure(e);
    }
  }

  bool _isRetryable(ChunkResponse response) {
    if (response.retryable) return true;
    final status = response.httpStatus ?? 0;
    if (status == 400 ||
        status == 401 ||
        status == 403 ||
        status == 404 ||
        status == 422) {
      return false;
    }
    if (status == 408 || status == 429 || status >= 500) return true;
    switch (response.errorKind) {
      case 'timeout':
      case 'network':
      case 'server':
      case 'rate_limit':
        return true;
      default:
        return false;
    }
  }

  Duration _backoff(int attemptNumber) {
    final exponent = math.max(0, attemptNumber - 1);
    final ms = math.min(
      limits.retryBackoffBaseMs * math.pow(2, exponent).toInt(),
      limits.retryBackoffMaxMs,
    );
    return Duration(milliseconds: ms);
  }

  // -------------------------------------------------------------- requests

  MaterialChunk _chunkById(ChunkedJob job, String chunkId) =>
      job.plan.chunks.firstWhere((c) => c.chunkId == chunkId);

  ChunkRequest _buildExtractRequest(
    ChunkedJob job,
    MaterialChunk chunk,
    String requestId,
    int attemptNumber,
  ) {
    final payload = _extractPayload(
      chunk,
      jobId: job.jobId,
      requestId: requestId,
      attempt: attemptNumber,
    );
    return _requestOf(
      jobId: job.jobId,
      chunkId: chunk.chunkId,
      requestId: requestId,
      phase: 'chunk_extract',
      attempt: attemptNumber,
      payload: payload,
    );
  }

  /// 抽取请求的完整 payload（每个片段一条带来源 ID 的 source）。
  Map<String, dynamic> _extractPayload(
    MaterialChunk chunk, {
    required String jobId,
    required String requestId,
    required int attempt,
  }) {
    // 每个片段单独作为一条 source 并带稳定来源 ID，模型才能给出可校验的引用。
    final sources = <Map<String, dynamic>>[
      for (final slice in chunk.segments)
        <String, dynamic>{
          'kind': 'text',
          'label': '片段 ${slice.segmentId}'
              '${slice.overlap ? '（上下文重叠）' : ''}'
              '${slice.page > 0 ? '（第 ${slice.page} 页）' : ''}',
          'text': slice.text,
        },
    ];
    return _buildPayload(
      jobId: jobId,
      requestId: requestId,
      chunkId: chunk.chunkId,
      phaseName: 'chunk_extract',
      attempt: attempt,
      label: '材料片段 ${chunk.chunkId}（${chunk.pageLabel}）',
      text: chunk.text,
      sources: sources,
      segmentIds: chunk.segmentIds,
    );
  }

  ChunkRequest _buildMergeRequest(
    ChunkedJob job,
    List<FactEntry> facts,
    int layer,
    int batchIndex,
    String requestId,
    int attemptNumber,
  ) {
    final index = <Map<String, dynamic>>[
      for (final fact in facts) _factIndexEntry(fact),
    ];
    final payload = _buildPayload(
      jobId: job.jobId,
      requestId: requestId,
      chunkId: 'merge:L$layer:$batchIndex',
      phaseName: 'merge',
      attempt: attemptNumber,
      label: '事实索引（第 $layer 层，第 ${batchIndex + 1} 批）',
      text: jsonEncode(<String, dynamic>{'facts': index}),
      mergeFacts: index,
      mergeLayer: layer,
    );
    return _requestOf(
      jobId: job.jobId,
      chunkId: 'merge:L$layer:$batchIndex',
      requestId: requestId,
      phase: 'merge',
      attempt: attemptNumber,
      payload: payload,
    );
  }

  ChunkRequest _requestOf({
    required String jobId,
    required String chunkId,
    required String requestId,
    required String phase,
    required int attempt,
    required Map<String, dynamic> payload,
  }) =>
      ChunkRequest(
        jobId: jobId,
        chunkId: chunkId,
        requestId: requestId,
        phase: phase,
        attempt: attempt,
        payload: payload,
        utf8Bytes: utf8BytesOfJson(payload),
        estimatedTokens: tokenEstimator.estimateJson(payload),
      );

  /// 构造与 app_controller.buildAnalysisRequest 同形的请求（requestSchemaVersion 2），
  /// 材料只装当前块；时间表/上下文/已知任务等固定信封逐块一致。
  Map<String, dynamic> _buildPayload({
    required String jobId,
    required String requestId,
    required String chunkId,
    required String phaseName,
    required int attempt,
    required String label,
    required String text,
    List<Map<String, dynamic>>? sources,
    List<String>? segmentIds,
    List<Map<String, dynamic>>? mergeFacts,
    int? mergeLayer,
  }) {
    return <String, dynamic>{
      'requestSchemaVersion': 2,
      'conversationId': spec.conversationId,
      'requestId': requestId,
      'jobId': jobId,
      'chunkId': chunkId,
      'attempt': attempt,
      'analysisPhase': phaseName,
      'baseVersionId': spec.baseVersionId,
      'baseRevision': spec.baseRevision,
      'calendarRevision':
          spec.timetableJson == null ? -1 : spec.calendarRevision,
      'context': <String, dynamic>{
        'currentDate': AnalysisDateResolver.formatDateKey(spec.asOf),
        'timezoneId': spec.timeZoneId,
        'timezoneOffsetMinutes': spec.timezoneOffsetMinutes,
        if (spec.externalSources.isNotEmpty)
          'externalSources': spec.externalSources,
      },
      'userRequest': spec.userRequest,
      if (spec.planContext != null) 'planContext': spec.planContext,
      'knownTasks': spec.knownTasks,
      // 同一份时间表快照原样发送：不省略、不缩短。
      if (spec.timetableJson != null && spec.effectiveTimetableJson != null) ...{
        'timetable': spec.timetableJson,
        'effectiveTimetable': spec.effectiveTimetableJson,
      },
      'sources': sources ??
          <Map<String, dynamic>>[
            <String, dynamic>{'kind': 'text', 'label': label, 'text': text},
          ],
      if (segmentIds != null) 'segmentIds': segmentIds,
      'chunkInstruction': phaseName == 'merge'
          ? ModelOutputParser.mergeInstruction
          : ModelOutputParser.extractionInstruction,
      'promptVersion': spec.promptVersion,
      if (spec.modelSelection != null) 'modelSelection': spec.modelSelection,
      if (mergeFacts != null) 'mergeFacts': mergeFacts,
      if (mergeLayer != null) 'mergeLayer': mergeLayer,
    };
  }

  // ---------------------------------------------------------------- ledger

  /// 从“已通过结构校验”的块结果重建账本；重放已成功的归并层（不重发请求）。
  FactLedger _rebuildLedger(ChunkedJob job) {
    final ledger = FactLedger.forChunks(
      jobId: job.jobId,
      chunks: job.plan.chunks,
    );
    for (final chunk in job.plan.chunks) {
      final state = job.stateFor(chunk.chunkId);
      final parsed = state.parsed;
      if (parsed == null) continue;
      for (final candidate in parsed.facts) {
        ledger.addCandidate(candidate, chunkId: chunk.chunkId);
      }
    }
    ledger.reconcile();
    for (final record in job.mergeLayers) {
      if (record.status == 'succeeded' && record.result != null) {
        _applyMergeResult(ledger, record.result!);
      }
    }
    return ledger;
  }

  void _applyMergeResult(FactLedger ledger, MergeParseResult result) {
    for (final group in result.duplicates) {
      ledger.applyMergeGroups(
        <List<String>>[group.factIds],
        reasons: <String>[group.reason],
      );
    }
    ledger.reconcile();
    for (final group in result.contradictions) {
      ledger.registerContradiction(FactContradiction(
        key: 'merge:${group.factIds.join(',')}',
        factIds: group.factIds,
        reason: '归并层报告矛盾：${group.reason}；保留全部事实，等待用户确认',
      ));
    }
  }

  // ---------------------------------------------------------------- merging

  int _indexTokens(List<FactEntry> facts) => tokenEstimator.estimateJson(
        <String, dynamic>{
          'facts': <Map<String, dynamic>>[
            for (final fact in facts) _factIndexEntry(fact),
          ],
        },
      );

  Map<String, dynamic> _factIndexEntry(FactEntry fact) => <String, dynamic>{
        'factId': fact.factId,
        'kind': fact.kind.name,
        'taskHint': fact.taskHint,
        if (fact.objectKey != null && fact.objectKey!.isNotEmpty)
          'object': fact.objectKey,
        if (fact.dueDate != null) 'dueDate': fact.dueDate,
        if (fact.dueDateRaw != null && fact.dueDate == null)
          'dueDateRaw': fact.dueDateRaw,
        if (fact.hours != null) 'hours': fact.hours,
        if (fact.hoursIsMinimum) 'minimum': true,
        if (fact.dependsOnHints.isNotEmpty)
          'dependsOn': fact.dependsOnHints,
        if (fact.constraintText != null) 'constraint': fact.constraintText,
        'status': fact.status.name,
        'sources': <Map<String, dynamic>>[
          for (final source in fact.sources)
            <String, dynamic>{
              'segmentId': source.segmentId,
              'page': source.page,
              'quote': source.quoteSpan?.quote,
            },
        ],
      };

  Future<bool> _runMergeLayers(ChunkedJob job, FactLedger ledger) async {
    // 重放历史层，并确定下一起始层；若上次层未完成 → 不自动重发。
    var nextLayer = 0;
    for (final record in job.mergeLayers) {
      if (record.status == 'succeeded' && record.result != null) {
        nextLayer = math.max(nextLayer, record.layer + 1);
        continue;
      }
      job.setStatus(ChunkJobStatus.needsConfirm,
          phase: ChunkPhase.merging,
          message: '上次归并层未完成（${record.errorMessage ?? record.status}）；'
              '恢复时不会自动重发，请确认后重试');
      return false;
    }

    while (_indexTokens(ledger.facts) > limits.mergeBudgetTokens) {
      if (job.isCancelled) return false;
      if (nextLayer >= limits.maxMergeLayers) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.merging,
            message: '归并层数达到上限（${limits.maxMergeLayers}）后事实索引仍超出上下文；'
                '已保留进度，请缩小材料范围或明确扩大预算（不会循环到成功）');
        return false;
      }
      if (!job.budget.canStartRequest()) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.merging,
            message: '归并阶段预算耗尽（${job.budget.exhaustedReason ?? '预算不足'}）；'
                '已保留进度，未循环重试');
        return false;
      }
      final layer = nextLayer;
      final factsAtStart = ledger.facts;
      final record = MergeLayerRecord(
        layer: layer,
        inputFactIds: factsAtStart.map((f) => f.factId).toList(growable: false),
      );
      job.addMergeLayer(record);

      final batches = _batchFacts(job, factsAtStart);
      final results = <MergeParseResult>[];
      for (var i = 0; i < batches.length; i++) {
        if (job.isCancelled) return false;
        final batch = batches[i];
        final requestId = 'req:${job.jobId}:merge:L$layer:$i';
        final attempt = ChunkAttempt(
          attemptId: 'merge:L$layer:$i#a1',
          chunkId: 'merge:L$layer:$i',
          attemptNumber: 1,
          requestId: requestId,
          startedAt: clock(),
          estimatedTokens: _indexTokens(batch),
        );
        job.attempts.add(attempt);
        final request = _buildMergeRequest(
            job, batch, layer, i, requestId, attempt.attemptNumber);
        final verdict = requestBudget().checkRequest(
          request.payload,
          expectTimetable: spec.timetableJson != null,
          expectedTimetableSignature: spec.timetableSignature,
        );
        if (!verdict.ok) {
          _finishMergeAttemptFailure(
            attempt,
            code: 'merge_request_budget_exceeded',
            message: verdict.reason ?? '归并请求超出预算',
          );
          record
            ..status = 'failed'
            ..errorCode = 'merge_request_budget_exceeded'
            ..errorMessage = verdict.reason;
          job.setStatus(ChunkJobStatus.needsConfirm,
              phase: ChunkPhase.merging,
              message: '归并请求超出上下文预算；请缩小范围或扩大预算'
                  '（禁止截断事实索引）');
          return false;
        }
        attempt
          ..requestUtf8Bytes = verdict.utf8Bytes
          ..estimatedTokens = verdict.estimatedTokens;
        record.requestIds.add(requestId);
        ChunkResponse response;
        try {
          response = await transport(request);
        } catch (e) {
          response = ChunkResponse.failure(
            errorKind: 'transport',
            error: '传输层异常：$e',
            retryable: true,
            duplicateBillingRisk: true,
          );
        }
        job.budget.record(
            tokens: verdict.estimatedTokens, bytes: verdict.utf8Bytes);
        if (job.isCancelled) return false;
        if (!response.ok) {
          _finishMergeAttemptFailure(
            attempt,
            code: response.errorKind ?? 'merge_failed',
            message: response.error ?? '归并请求失败',
            duplicateBillingRisk: response.duplicateBillingRisk,
          );
          record
            ..status = 'failed'
            ..errorCode = response.errorKind
            ..errorMessage = response.error ?? '归并请求失败';
          job.setStatus(ChunkJobStatus.needsConfirm,
              phase: ChunkPhase.merging,
              message: '跨块归并请求失败（${response.error ?? '未知错误'}）；'
                  '未生成正式计划，可重试失败阶段');
          return false;
        }
        try {
          final parsed = parser.parseMerge(
            response.content ?? '',
            knownFactIds: factsAtStart.map((f) => f.factId).toSet(),
          );
          results.add(parsed);
          _finishMergeAttemptSuccess(attempt);
        } on ParseFailure catch (e) {
          _finishMergeAttemptFailure(
            attempt,
            code: e.code,
            message: e.message,
          );
          record
            ..status = 'failed'
            ..errorCode = e.code
            ..errorMessage = e.message;
          job.setStatus(ChunkJobStatus.needsConfirm,
              phase: ChunkPhase.merging,
              message: '归并输出结构不符（${e.message}）；未生成正式计划');
          return false;
        }
      }

      // 应用本层结果：合并组 + 矛盾，保留所有来源。
      final duplicates = <MergeGroup>[
        for (final result in results) ...result.duplicates,
      ];
      final contradictions = <MergeGroup>[
        for (final result in results) ...result.contradictions,
      ];
      final unresolved = <String>[
        for (final result in results) ...result.unresolvedFactIds,
      ];
      final combined = MergeParseResult(
        duplicates: duplicates,
        contradictions: contradictions,
        unresolvedFactIds: unresolved,
        notes: <String>[for (final result in results) ...result.notes],
        warnings: <String>[for (final result in results) ...result.warnings],
      );
      final beforeIds = factsAtStart.map((f) => f.factId).toList(growable: false);
      _applyMergeResult(ledger, combined);
      record
        ..status = 'succeeded'
        ..result = combined
        ..outputFactIds =
            ledger.facts.map((f) => f.factId).toList(growable: false);
      final afterIds =
          ledger.facts.map((f) => f.factId).toList(growable: false);
      nextLayer = layer + 1;
      if (afterIds.length >= beforeIds.length) {
        job.setStatus(ChunkJobStatus.needsConfirm,
            phase: ChunkPhase.merging,
            message: '归并无法进一步压缩事实索引（仍超出上下文）；'
                '已保留进度，请缩小材料范围或明确扩大预算（不循环到成功）');
        return false;
      }
    }
    return true;
  }

  /// 按单请求归并预算把事实分批；单条事实都装不下时明确失败（不截断）。
  List<List<FactEntry>> _batchFacts(ChunkedJob job, List<FactEntry> facts) {
    final budget = requestBudget();
    final maxTokens = limits.mergeBudgetTokens;
    final maxBytes = budget.remainingUtf8Bytes;
    final batches = <List<FactEntry>>[];
    var current = <FactEntry>[];
    var tokens = 0;
    var bytes = 0;
    for (final fact in facts) {
      final entry = _factIndexEntry(fact);
      final entryTokens = tokenEstimator.estimateJson(entry);
      final entryBytes = utf8BytesOfJson(entry);
      final tooBig = entryTokens > maxTokens || entryBytes > maxBytes;
      if (tooBig) {
        // 单条事实超过归并上下文：无法归并；调用方会在请求预算复核处显式失败。
        if (current.isNotEmpty) {
          batches.add(current);
          current = <FactEntry>[];
          tokens = 0;
          bytes = 0;
        }
        batches.add(<FactEntry>[fact]);
        continue;
      }
      if (current.isNotEmpty &&
          (tokens + entryTokens > maxTokens || bytes + entryBytes > maxBytes)) {
        batches.add(current);
        current = <FactEntry>[];
        tokens = 0;
        bytes = 0;
      }
      current.add(fact);
      tokens += entryTokens;
      bytes += entryBytes;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  // ------------------------------------------------------------ validation

  /// 抽取阶段提前停止（失败阈值/预算）的原因；用于最终结论，避免被后续概括覆盖。
  String? _earlyStopMessage(ChunkedJob job) {
    final message = job.statusMessage;
    if (message == null || message.contains('未生成正式计划')) return null;
    if (message.contains('超过阈值') || message.contains('预算')) return message;
    return null;
  }

  List<String> _collectBlockers(
    ChunkedJob job,
    FactLedger ledger, {
    required bool mergeOk,
    required bool mergeSkipped,
    String? earlyStopMessage,
  }) {
    final blockers = <String>[];
    if (earlyStopMessage != null) blockers.add(earlyStopMessage);
    if (job.isCancelled) blockers.add('作业已取消');
    if (!job.plan.manifest.complete) {
      final uncovered = job.plan.manifest.uncoveredSegmentIds.length;
      final missingPages = job.plan.manifest.documents
          .fold<int>(0, (sum, doc) => sum + doc.missingPages.length);
      blockers.add('材料覆盖不完整（未覆盖片段 $uncovered 个、缺页 $missingPages 页）');
    }
    if (job.plan.manifest.blockingUnsplittable.isNotEmpty) {
      blockers.add(
          '有 ${job.plan.manifest.blockingUnsplittable.length} 个片段无法装入请求预算');
    }
    if (job.failedChunkCount > 0) {
      blockers.add('有 ${job.failedChunkCount} 个材料块未成功（失败/取消/结果待确认），'
          '不能提交貌似完整的正式计划');
    }
    if (job.hasUnknownOutcome) {
      blockers.add(job.duplicateBillingNotice ?? '存在结果未知的请求');
    }
    if (job.budget.exhausted) {
      blockers.add(
          '作业预算耗尽（${job.budget.exhaustedReason ?? '预算不足'}），已保留进度；'
          '请缩小范围或明确扩大预算，未循环重试');
    }
    if (!mergeOk) {
      blockers.add(job.statusMessage ?? '跨块归并未完成');
    }
    if (ledger.hasUnresolvedSources) {
      blockers.add('有事实引用了不存在的来源 ID（${ledger.unknownSegmentIds.join('、')}），'
          '已标记 unresolved 并保留；需用户确认排除后才可提交');
    }
    // 去重后的稳定顺序，避免同一原因重复。
    final seen = <String>{};
    return <String>[
      for (final blocker in blockers)
        if (seen.add(blocker)) blocker,
    ];
  }

  DraftPlanPreview _buildPreview(
    ChunkedJob job,
    FactLedger ledger,
    List<String> blockers,
  ) {
    ledger.reconcile();
    final confirmedTaskFacts = <FactEntry>[];
    final pendingTaskFacts = <FactEntry>[];
    for (final fact in ledger.taskFacts) {
      if (fact.status == FactStatus.confirmed && fact.verifiedSource) {
        confirmedTaskFacts.add(fact);
      } else {
        pendingTaskFacts.add(fact);
      }
    }
    final candidateByFact = <String, String>{};
    final taskFactsInOrder = <FactEntry>[];
    for (var i = 0; i < confirmedTaskFacts.length; i++) {
      final fact = confirmedTaskFacts[i];
      final candidateId = 'draft-task-${i + 1}';
      candidateByFact[fact.factId] = candidateId;
      taskFactsInOrder.add(fact);
    }
    // 跨块依赖：解析为本地候选任务 ID；未解析的进入 notes（保留）。
    final tasks = <DraftTaskCandidate>[];
    for (var i = 0; i < taskFactsInOrder.length; i++) {
      final fact = taskFactsInOrder[i];
      final candidateId = candidateByFact[fact.factId]!;
      final links = ledger.dependencyLinks[fact.factId] ?? const <String>[];
      tasks.add(DraftTaskCandidate(
        candidateId: candidateId,
        name: fact.taskHint,
        estimatedHours: fact.hours,
        deadline: fact.dueDate,
        dependsOn: <String>[
          for (final factId in links)
            if (candidateByFact[factId] != null) candidateByFact[factId]!,
        ],
        sourceRefs: <String>[
          for (final source in fact.sources)
            if (source.segmentId.isNotEmpty) source.segmentId,
        ],
        sourceSegmentIds: <String>[
          for (final source in fact.sources) source.segmentId,
        ],
      ));
    }

    final notes = <DraftNote>[];
    for (final contradiction in ledger.contradictions) {
      notes.add(DraftNote(
        kind: 'question',
        text: contradiction.reason,
        taskRefs: <String>[
          for (final factId in contradiction.factIds)
            if (candidateByFact[factId] != null) candidateByFact[factId]!,
        ],
      ));
    }
    for (final pending in ledger.pendingConfirmations()) {
      notes.add(DraftNote(
        kind: pending.kind == 'unresolvedDependency' ? 'blocked' : 'question',
        text: pending.text,
      ));
    }
    for (final fact in pendingTaskFacts) {
      notes.add(DraftNote(
        kind: 'question',
        text: '任务事实待确认，未自动生成任务：${fact.taskHint}'
            '${fact.pendingReason == null ? '' : '（${fact.pendingReason}）'}',
      ));
    }
    for (final fact in ledger.constraintFacts) {
      if (fact.status != FactStatus.confirmed) continue;
      final text = fact.constraintText ??
          fact.quoteSpan?.quote ??
          (fact.dependsOnHints.isEmpty
              ? ''
              : '依赖：${fact.dependsOnHints.join('、')}');
      if (text.trim().isEmpty) continue;
      notes.add(DraftNote(kind: 'assumption', text: '约束事实（$text）'));
    }

    final pending = ledger.pendingConfirmations();
    final factsJson = <Map<String, dynamic>>[
      for (final fact in ledger.facts)
        <String, dynamic>{
          ...fact.toJson(),
          'taskCandidateIds': <String>[
            if (candidateByFact[fact.factId] != null)
              candidateByFact[fact.factId]!,
          ],
        },
    ];
    final partial = blockers.isNotEmpty;
    final summary = partial
        ? '分块分析草稿（不完整）：${tasks.length} 个候选任务、'
            '${ledger.facts.length} 条事实（${job.plan.chunks.length} 个材料块）'
        : '分块分析：${tasks.length} 个候选任务、'
            '${ledger.facts.length} 条事实（${job.plan.chunks.length} 个材料块）';

    return DraftPlanPreview(
      jobId: job.jobId,
      partial: partial,
      blockers: blockers,
      summary: summary,
      tasks: tasks,
      notes: notes,
      pending: pending,
      coverage: job.plan.manifest,
      facts: factsJson,
      jobSummary: <String, dynamic>{
        'jobId': job.jobId,
        'baselineSignature': job.baseline.signature,
        'chunksTotal': job.plan.chunks.length,
        'chunksSucceeded': job.succeededChunkCount,
        'chunksFailed': job.failedChunkCount,
        'requestsUsed': job.budget.requestsUsed,
        'tokensUsed': job.budget.tokensUsed,
        'mergeLayers': job.mergeLayers.length,
        'factsTotal': ledger.facts.length,
        'factsConfirmed': ledger.confirmedFacts.length,
        'factsPending': ledger.pendingFacts.length,
        'contradictions': ledger.contradictions.length,
        'unresolvedDependencies': ledger.unresolvedDependencies.length,
        'coverageComplete': job.plan.manifest.complete,
        'officialPlanAvailable': !partial && job.allChunksSucceeded,
      },
    );
  }
  void _finishMergeAttemptSuccess(ChunkAttempt attempt) {
    attempt
      ..status = 'succeeded'
      ..finishedAt = clock();
  }

  void _finishMergeAttemptFailure(
    ChunkAttempt attempt, {
    required String code,
    required String message,
    bool duplicateBillingRisk = false,
  }) {
    attempt
      ..status = 'failed'
      ..finishedAt = clock()
      ..errorCode = code
      ..errorMessage = message
      ..duplicateBillingRisk = duplicateBillingRisk;
  }
}

enum _ChunkRunResult { success, failed, dropped, budgetExhausted }

class _ParseOutcome {
  const _ParseOutcome._(this.parsed, this.failure);

  const _ParseOutcome.success(ParsedChunkOutput parsed) : this._(parsed, null);

  const _ParseOutcome.failure(ParseFailure failure) : this._(null, failure);

  final ParsedChunkOutput? parsed;
  final ParseFailure? failure;
}

// ---------------------------------------------------------------------------
// app_controller 侧接线示例（本仓库不改 app_controller，仅说明调用方式）：
//
//   final coordinator = ChunkedCoordinator(
//     spec: AnalysisJobSpec(
//       conversationId: conversation.id,
//       userRequest: draft,
//       asOf: DateTime.now(),                    // 作业开始时固定一次
//       timeZoneId: timetable.timezoneId,
//       baseVersionId: version?.id,
//       baseRevision: version?.revision ?? 0,
//       calendarRevision: timetable.revision,
//       timetableJson: timetable.toJson(),
//       effectiveTimetableJson: deriveEffectiveTimetable(timetable),
//       knownTasks: [...],                       // 与 buildAnalysisRequest 一致
//       documents: conversation.attachments
//           .map((a) => SourceDocument.fromExtractedDocument(
//                 ... , docHash: a.contentHash, label: a.label))
//           .toList(),
//       modelSelection: selection?.toJson(),
//     ),
//     limits: const AnalysisLimits(),
//     transport: (request) async {
//       // 生产适配：NativeGateway.analyzeAsync(request.payload) → poll → result，
//       // 必须把模型 JSON 原文作为 ChunkResponse.content 返回（不在这里解析）。
//       final jobId = gateway.analyzeAsync(request.payload);
//       final outcome = await _waitForOutcome(jobId); // 复用现有轮询
//       return outcome.ok
//           ? ChunkResponse.ok(outcome.rawContent!)
//           : ChunkResponse.failure(
//               errorKind: outcome.errorKind ?? 'unknown',
//               error: outcome.error ?? '失败',
//               httpStatus: outcome.httpStatus);
//     },
//   );
//   final estimate = coordinator.estimate();      // 界面展示覆盖/请求数/费用未知
//   final job = coordinator.createJob();
//   final outcome = await coordinator.run(job);
//   if (outcome.officialPlanAvailable) {
//     // 先给用户预览；确认后再走现有 _commitResult 的本地校验/提交路径。
//     final planJson = outcome.officialPlanJson!;
//   } else {
//     // 展示 outcome.blockers / preview.partial；可重试失败块或取消。
//   }
// ---------------------------------------------------------------------------
