// 分块分析作业 — 作业 / 块 / 尝试的稳定 ID、状态机与本地恢复。
//
// 状态机：
//   块：   pending → running → succeeded | failed | cancelled | needsConfirm
//   作业：pending → running → succeeded | failed | cancelled | needsConfirm
//
// 规则：
//   * 只有**通过结构校验**的阶段结果（ParsedChunkOutput）才会被写入块状态；
//   * 恢复（fromJson）不会自动重发任何请求：上次运行中断时处于 running 的块
//     变成 needsConfirm，并标记 duplicateBillingRisk（结果未知，可能已计费）；
//   * 正式计划只在“全部块成功 + 覆盖清单完整 + 作业状态 succeeded”时可用。

import 'analysis_budget.dart';
import 'material_chunker.dart';
import 'model_output_parser.dart';

/// 作业状态。
enum ChunkJobStatus {
  pending,
  running,
  succeeded,
  failed,
  cancelled,
  needsConfirm;

  static ChunkJobStatus parse(Object? raw) =>
      ChunkJobStatus.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => ChunkJobStatus.pending,
      );
}

/// 单个材料块的状态。
enum ChunkStatus {
  pending,
  running,
  succeeded,
  failed,
  cancelled,
  needsConfirm;

  static ChunkStatus parse(Object? raw) => ChunkStatus.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => ChunkStatus.pending,
      );
}

/// 作业所处阶段（界面进度用）。
enum ChunkPhase {
  planning,
  extracting,
  normalizing,
  correlating,
  merging,
  validating,
  previewReady,
  finished,
  failed,
  cancelled;

  String get label => switch (this) {
        ChunkPhase.planning => '准备材料与请求预算',
        ChunkPhase.extracting => '分块抽取',
        ChunkPhase.normalizing => '本地校验与来源归一',
        ChunkPhase.correlating => '跨块关联与去重',
        ChunkPhase.merging => '有限多层归并',
        ChunkPhase.validating => '本地正式校验',
        ChunkPhase.previewReady => '预览草稿已生成',
        ChunkPhase.finished => '完成',
        ChunkPhase.failed => '失败',
        ChunkPhase.cancelled => '已取消',
      };
}

/// 作业固定基线：对所有块生效，任何字段变化都会让旧作业失效。
class JobBaseline {
  const JobBaseline({
    required this.asOf,
    required this.timeZoneId,
    this.timezoneOffsetMinutes = 0,
    this.baseVersionId,
    this.baseRevision = 0,
    this.calendarRevision = -1,
    this.materialHashes = const <String, String>{},
    this.modelConfigSignature = '',
    this.userRequestHash = '',
    this.timetableSignature,
    this.externalSources = const <Map<String, dynamic>>[],
    this.scheduleFingerprint = '',
    this.promptVersion = 'chunk-extract-v1',
  });

  /// 固定基准时间：相对日期（明天/下周一）在所有块中用同一个 asOf 解析。
  final DateTime asOf;
  final String timeZoneId;
  final int timezoneOffsetMinutes;
  final String? baseVersionId;
  final int baseRevision;

  /// 请求携带的时间表 revision；-1 = 本次不携带时间表。
  final int calendarRevision;

  /// 文档哈希 → 标签（材料版本指纹；内容变化使旧作业失效）。
  final Map<String, String> materialHashes;

  /// 模型配置指纹（profileId/revision/model/thinking 的摘要；不含密钥）。
  final String modelConfigSignature;

  /// 用户要求文本的哈希（用户改了要求 → 旧作业失效）。
  final String userRequestHash;

  /// 时间表 JSON 的哈希（时间表变化 → 旧作业失效；null = 不携带）。
  final String? timetableSignature;

  /// 外部日历来源身份（id/revision/范围，不含事件内容）。来源变化 → 旧作业失效。
  final List<Map<String, dynamic>> externalSources;

  /// 本地全局日程忙碌指纹（范围+时区+有效区间并集；为空 = 本次未携带时间表）。
  /// 与外部日历指纹分开命名，不冒用 externalSourceIds。
  final String scheduleFingerprint;

  final String promptVersion;

  /// 外部来源身份指纹（顺序无关）。
  String get externalSourcesSignature => hashJson(
        <Object>[
          for (final source in externalSources)
            <String, Object?>{
              'id': source['id'],
              'revision': source['revision'],
              'dateFrom': source['dateFrom'],
              'dateTo': source['dateTo'],
            },
        ],
      );

  /// 基线指纹（作业 ID/失效判断用）。
  String get signature => shortHash(
        '${asOf.toIso8601String()}|$timeZoneId|$timezoneOffsetMinutes|'
        '${baseVersionId ?? ''}|$baseRevision|$calendarRevision|'
        '${_sortedMap(materialHashes)}|$modelConfigSignature|'
        '$userRequestHash|${timetableSignature ?? ''}|'
        '$externalSourcesSignature|$scheduleFingerprint|$promptVersion',
      );

  /// 当前输入是否仍与作业基线一致（不一致 → 旧作业必须失效/重新确认）。
  bool matches(JobBaseline other) => signature == other.signature;

  static String _sortedMap(Map<String, String> values) {
    final keys = values.keys.toList()..sort();
    return <String>[for (final key in keys) '$key=${values[key]}'].join(',');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'asOf': asOf.toIso8601String(),
        'timeZoneId': timeZoneId,
        'timezoneOffsetMinutes': timezoneOffsetMinutes,
        'baseVersionId': baseVersionId,
        'baseRevision': baseRevision,
        'calendarRevision': calendarRevision,
        'materialHashes': materialHashes,
        'modelConfigSignature': modelConfigSignature,
        'userRequestHash': userRequestHash,
        'timetableSignature': timetableSignature,
        'externalSources': externalSources,
        'scheduleFingerprint': scheduleFingerprint,
        'promptVersion': promptVersion,
      };

  factory JobBaseline.fromJson(Map<String, dynamic> j) => JobBaseline(
        asOf:
            DateTime.tryParse((j['asOf'] as String?) ?? '') ?? DateTime.now(),
        timeZoneId: (j['timeZoneId'] as String?) ?? '',
        timezoneOffsetMinutes:
            (j['timezoneOffsetMinutes'] as num?)?.toInt() ?? 0,
        baseVersionId: j['baseVersionId'] as String?,
        baseRevision: (j['baseRevision'] as num?)?.toInt() ?? 0,
        calendarRevision: (j['calendarRevision'] as num?)?.toInt() ?? -1,
        materialHashes: <String, String>{
          for (final entry
              in ((j['materialHashes'] as Map?) ?? const <String, dynamic>{})
                  .entries)
            entry.key.toString(): entry.value.toString(),
        },
        modelConfigSignature: (j['modelConfigSignature'] as String?) ?? '',
        userRequestHash: (j['userRequestHash'] as String?) ?? '',
        timetableSignature: j['timetableSignature'] as String?,
        externalSources: ((j['externalSources'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false),
        scheduleFingerprint: (j['scheduleFingerprint'] as String?) ?? '',
        promptVersion: (j['promptVersion'] as String?) ?? 'chunk-extract-v1',
      );
}

/// 一次模型尝试（审计/重复计费风险记录）。
class ChunkAttempt {
  ChunkAttempt({
    required this.attemptId,
    required this.chunkId,
    required this.attemptNumber,
    required this.requestId,
    required this.startedAt,
    this.requestUtf8Bytes = 0,
    this.estimatedTokens = 0,
    this.status = 'running',
  });

  final String attemptId;
  final String chunkId;
  final int attemptNumber;
  final String requestId;
  final DateTime startedAt;
  int requestUtf8Bytes;
  int estimatedTokens;
  String status; // running | succeeded | failed | abandoned
  DateTime? finishedAt;
  String? errorCode;
  String? errorMessage;
  int? httpStatus;

  /// 网络超时/中断时结果未知：服务可能已处理并计费，只能提示风险，不能断言未发生。
  bool duplicateBillingRisk = false;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'attemptId': attemptId,
        'chunkId': chunkId,
        'attemptNumber': attemptNumber,
        'requestId': requestId,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'requestUtf8Bytes': requestUtf8Bytes,
        'estimatedTokens': estimatedTokens,
        'status': status,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
        'httpStatus': httpStatus,
        'duplicateBillingRisk': duplicateBillingRisk,
      };

  factory ChunkAttempt.fromJson(Map<String, dynamic> j) => ChunkAttempt(
        attemptId: (j['attemptId'] as String?) ?? '',
        chunkId: (j['chunkId'] as String?) ?? '',
        attemptNumber: (j['attemptNumber'] as num?)?.toInt() ?? 0,
        requestId: (j['requestId'] as String?) ?? '',
        startedAt:
            DateTime.tryParse((j['startedAt'] as String?) ?? '') ?? DateTime.now(),
        requestUtf8Bytes: (j['requestUtf8Bytes'] as num?)?.toInt() ?? 0,
        estimatedTokens: (j['estimatedTokens'] as num?)?.toInt() ?? 0,
        status: (j['status'] as String?) ?? 'running',
      )
        ..finishedAt = DateTime.tryParse((j['finishedAt'] as String?) ?? '')
        ..errorCode = j['errorCode'] as String?
        ..errorMessage = j['errorMessage'] as String?
        ..httpStatus = (j['httpStatus'] as num?)?.toInt()
        ..duplicateBillingRisk = j['duplicateBillingRisk'] == true;
}

/// 单个材料块的可持久化状态。
class ChunkState {
  ChunkState({
    required this.chunkId,
    required this.docHash,
    required this.firstPage,
    required this.segmentIds,
    required this.utf8Bytes,
    required this.estimatedTokens,
    this.status = ChunkStatus.pending,
    this.attempts = 0,
    this.parsed,
    this.failureCode,
    this.failureMessage,
    this.unknownOutcome = false,
  });

  final String chunkId;
  final String docHash;
  final int firstPage;
  final List<String> segmentIds;
  final int utf8Bytes;
  final int estimatedTokens;
  ChunkStatus status;

  /// 已发起的尝试次数（含失败）。
  int attempts;

  /// 仅当结构校验通过后才非空。
  ParsedChunkOutput? parsed;

  String? failureCode;
  String? failureMessage;

  /// 上次进程中断时该块正在运行：结果未知，恢复不自动重发。
  bool unknownOutcome;

  bool get succeeded => status == ChunkStatus.succeeded;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunkId': chunkId,
        'docHash': docHash,
        'firstPage': firstPage,
        'segmentIds': segmentIds,
        'utf8Bytes': utf8Bytes,
        'estimatedTokens': estimatedTokens,
        'status': status.name,
        'attempts': attempts,
        'parsed': parsed?.toJson(),
        'failureCode': failureCode,
        'failureMessage': failureMessage,
        'unknownOutcome': unknownOutcome,
      };

  factory ChunkState.fromJson(Map<String, dynamic> j) => ChunkState(
        chunkId: (j['chunkId'] as String?) ?? '',
        docHash: (j['docHash'] as String?) ?? '',
        firstPage: (j['firstPage'] as num?)?.toInt() ?? 0,
        segmentIds: ((j['segmentIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        utf8Bytes: (j['utf8Bytes'] as num?)?.toInt() ?? 0,
        estimatedTokens: (j['estimatedTokens'] as num?)?.toInt() ?? 0,
        status: ChunkStatus.parse(j['status']),
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        parsed: j['parsed'] is Map<String, dynamic>
            ? ParsedChunkOutput.fromJson(j['parsed'] as Map<String, dynamic>)
            : null,
        failureCode: j['failureCode'] as String?,
        failureMessage: j['failureMessage'] as String?,
        unknownOutcome: j['unknownOutcome'] == true,
      );
}

/// 一次归并层的记录。每一层保留输入/输出 factId；恢复时可本地重放已成功的层。
class MergeLayerRecord {
  MergeLayerRecord({
    required this.layer,
    required this.inputFactIds,
    List<String> requestIds = const <String>[],
    this.status = 'running',
    this.result,
    List<String> outputFactIds = const <String>[],
    this.errorCode,
    this.errorMessage,
  })  : requestIds = List<String>.from(requestIds),
        outputFactIds = List<String>.from(outputFactIds);

  final int layer;
  final List<String> inputFactIds;
  final List<String> requestIds;
  String status; // running | succeeded | failed | needsConfirm
  MergeParseResult? result;
  List<String> outputFactIds;
  String? errorCode;
  String? errorMessage;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'layer': layer,
        'inputFactIds': inputFactIds,
        'requestIds': requestIds,
        'status': status,
        'result': result?.toJson(),
        'outputFactIds': outputFactIds,
        'errorCode': errorCode,
        'errorMessage': errorMessage,
      };

  factory MergeLayerRecord.fromJson(Map<String, dynamic> j) => MergeLayerRecord(
        layer: (j['layer'] as num?)?.toInt() ?? 0,
        inputFactIds: ((j['inputFactIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        requestIds: ((j['requestIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        status: (j['status'] as String?) ?? 'running',
        result: j['result'] is Map<String, dynamic>
            ? MergeParseResult.fromJson(j['result'] as Map<String, dynamic>)
            : null,
        outputFactIds: ((j['outputFactIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        errorCode: j['errorCode'] as String?,
        errorMessage: j['errorMessage'] as String?,
      );
}

/// 作业进度快照（界面可轮询展示，不伪造百分比之外的信息）。
class JobProgress {
  const JobProgress({
    required this.phase,
    required this.chunksTotal,
    required this.chunksDone,
    required this.chunksFailed,
    required this.requestsUsed,
    required this.tokensUsed,
    required this.tokensBudget,
    this.message,
  });

  final ChunkPhase phase;
  final int chunksTotal;
  final int chunksDone;
  final int chunksFailed;
  final int requestsUsed;
  final int tokensUsed;
  final int tokensBudget;
  final String? message;

  int get chunksRemaining => chunksTotal - chunksDone - chunksFailed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'phase': phase.name,
        'phaseLabel': phase.label,
        'chunksTotal': chunksTotal,
        'chunksDone': chunksDone,
        'chunksFailed': chunksFailed,
        'requestsUsed': requestsUsed,
        'tokensUsed': tokensUsed,
        'tokensBudget': tokensBudget,
        'message': message,
      };
}

/// 分块分析作业。
class ChunkedJob {
  ChunkedJob._({
    required this.jobId,
    required this.baseline,
    required this.plan,
    required this.limits,
    required this.budget,
  });

  factory ChunkedJob.create({
    required String jobId,
    required JobBaseline baseline,
    required ChunkPlan plan,
    required AnalysisLimits limits,
  }) {
    final job = ChunkedJob._(
      jobId: jobId,
      baseline: baseline,
      plan: plan,
      limits: limits,
      budget: JobBudget(limits: limits),
    );
    for (final chunk in plan.chunks) {
      job.chunks[chunk.chunkId] = ChunkState(
        chunkId: chunk.chunkId,
        docHash: chunk.docHash,
        firstPage: chunk.firstPage,
        segmentIds: chunk.segmentIds,
        utf8Bytes: chunk.utf8Bytes,
        estimatedTokens: chunk.estimatedTokens,
      );
    }
    return job;
  }

  /// 从本地持久化恢复。中断时 running 的块 → needsConfirm（结果未知，不重发）。
  factory ChunkedJob.fromJson(
    Map<String, dynamic> j, {
    required AnalysisLimits limits,
  }) {
    final job = ChunkedJob._(
      jobId: (j['jobId'] as String?) ?? '',
      baseline: JobBaseline.fromJson(
          (j['baseline'] as Map<String, dynamic>?) ?? const <String, dynamic>{}),
      plan: ChunkPlan.fromJson(
          (j['plan'] as Map<String, dynamic>?) ?? const <String, dynamic>{}),
      limits: limits,
      budget: JobBudget.fromJson(
        (j['budget'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        limits: limits,
      ),
    );
    for (final raw in (j['chunks'] as List<dynamic>?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final state = ChunkState.fromJson(raw);
      job.chunks[state.chunkId] = state;
    }
    for (final raw in (j['attempts'] as List<dynamic>?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      job.attempts.add(ChunkAttempt.fromJson(raw));
    }
    for (final raw in (j['mergeLayers'] as List<dynamic>?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      job.mergeLayers.add(MergeLayerRecord.fromJson(raw));
    }
    job.status = ChunkJobStatus.parse(j['status']);
    job.phase = ChunkPhase.values.firstWhere(
      (p) => p.name == j['phase'],
      orElse: () => ChunkPhase.planning,
    );
    job.statusMessage = j['statusMessage'] as String?;
    job._attemptCounter = (j['attemptCounter'] as num?)?.toInt() ?? 0;
    job._markInterrupted();
    return job;
  }

  final String jobId;
  final JobBaseline baseline;
  final ChunkPlan plan;
  final AnalysisLimits limits;
  final JobBudget budget;

  ChunkJobStatus status = ChunkJobStatus.pending;
  ChunkPhase phase = ChunkPhase.planning;
  String? statusMessage;

  final Map<String, ChunkState> chunks = <String, ChunkState>{};
  final List<ChunkAttempt> attempts = <ChunkAttempt>[];
  final List<MergeLayerRecord> mergeLayers = <MergeLayerRecord>[];
  int _attemptCounter = 0;

  bool get isCancelled => status == ChunkJobStatus.cancelled;

  bool get allChunksSucceeded =>
      chunks.isNotEmpty && chunks.values.every((c) => c.succeeded);

  bool get hasFailedChunks => chunks.values.any((c) =>
      c.status == ChunkStatus.failed ||
      c.status == ChunkStatus.cancelled ||
      c.status == ChunkStatus.needsConfirm);

  int get failedChunkCount => chunks.values
      .where((c) =>
          c.status == ChunkStatus.failed ||
          c.status == ChunkStatus.cancelled ||
          c.status == ChunkStatus.needsConfirm)
      .length;

  int get succeededChunkCount =>
      chunks.values.where((c) => c.succeeded).length;

  bool get hasUnknownOutcome =>
      chunks.values.any((c) => c.unknownOutcome);

  /// 是否允许产出“正式计划”：作业成功 + 覆盖完整 + 无未成功块。
  bool get canProduceOfficialPlan =>
      status == ChunkJobStatus.succeeded &&
      plan.manifest.complete &&
      allChunksSucceeded;

  List<ChunkState> get pendingChunks => <ChunkState>[
        for (final chunkId in plan.chunks.map((c) => c.chunkId))
          if (chunks[chunkId]!.status == ChunkStatus.pending) chunks[chunkId]!,
      ];

  JobProgress get progress => JobProgress(
        phase: phase,
        chunksTotal: chunks.length,
        chunksDone: succeededChunkCount,
        chunksFailed: failedChunkCount,
        requestsUsed: budget.requestsUsed,
        tokensUsed: budget.tokensUsed,
        tokensBudget: limits.maxJobTotalTokens,
        message: statusMessage,
      );

  ChunkState stateFor(String chunkId) {
    final state = chunks[chunkId];
    if (state == null) {
      throw StateError('未知材料块：$chunkId');
    }
    return state;
  }

  /// 下一次尝试的稳定 ID：`<chunkId>#a<n>`。
  String nextAttemptId(String chunkId) =>
      '$chunkId#a${stateFor(chunkId).attempts + 1}';

  String nextRequestId(String chunkId, String phaseName) =>
      'req:$jobId:$chunkId:$phaseName#a${stateFor(chunkId).attempts + 1}';

  ChunkAttempt beginAttempt(
    String chunkId, {
    required String requestId,
    required int requestUtf8Bytes,
    required int estimatedTokens,
    required DateTime now,
  }) {
    final state = stateFor(chunkId);
    state
      ..attempts += 1
      ..status = ChunkStatus.running
      ..failureCode = null
      ..failureMessage = null;
    final attempt = ChunkAttempt(
      attemptId: '$chunkId#a${state.attempts}',
      chunkId: chunkId,
      attemptNumber: state.attempts,
      requestId: requestId,
      startedAt: now,
      requestUtf8Bytes: requestUtf8Bytes,
      estimatedTokens: estimatedTokens,
    );
    attempts.add(attempt);
    _attemptCounter++;
    return attempt;
  }

  /// 结构校验通过后才调用：保存阶段结果，块置 succeeded。
  void finishAttemptSuccess(
    ChunkAttempt attempt,
    ParsedChunkOutput parsed, {
    required DateTime now,
  }) {
    attempt
      ..status = 'succeeded'
      ..finishedAt = now;
    final state = stateFor(attempt.chunkId)
      ..status = ChunkStatus.succeeded
      ..parsed = parsed
      ..failureCode = null
      ..failureMessage = null;
    state.unknownOutcome = false;
  }

  /// 记录一次失败尝试；是否还能重试由协调器结合 [AnalysisLimits.maxAttemptsPerChunk]
  /// 与错误可重试性决定。这里仅保存事实。
  void finishAttemptFailure(
    ChunkAttempt attempt, {
    required String code,
    required String message,
    required DateTime now,
    int? httpStatus,
    bool duplicateBillingRisk = false,
    required bool exhausted,
  }) {
    attempt
      ..status = 'failed'
      ..finishedAt = now
      ..errorCode = code
      ..errorMessage = message
      ..httpStatus = httpStatus
      ..duplicateBillingRisk = duplicateBillingRisk;
    final state = stateFor(attempt.chunkId)
      ..failureCode = code
      ..failureMessage = message;
    if (exhausted) {
      state.status = ChunkStatus.failed;
    } else {
      state.status = ChunkStatus.pending;
    }
  }

  void markChunkFailed(String chunkId, {required String code, required String message}) {
    stateFor(chunkId)
      ..status = ChunkStatus.failed
      ..failureCode = code
      ..failureMessage = message;
  }

  void markChunkCancelled(String chunkId, {String? message}) {
    stateFor(chunkId)
      ..status = ChunkStatus.cancelled
      ..failureCode = 'cancelled'
      ..failureMessage = message ?? '作业取消，未处理该块';
  }

  void markChunkNeedsConfirm(String chunkId, {required String message}) {
    stateFor(chunkId)
      ..status = ChunkStatus.needsConfirm
      ..failureCode = 'needs_confirm'
      ..failureMessage = message;
  }

  void setStatus(ChunkJobStatus next, {ChunkPhase? phase, String? message}) {
    status = next;
    if (phase != null) this.phase = phase;
    if (message != null) statusMessage = message;
  }

  void cancel({String message = '已取消；保留已完成进度，不再发送新请求'}) {
    status = ChunkJobStatus.cancelled;
    phase = ChunkPhase.cancelled;
    statusMessage = message;
    for (final state in chunks.values) {
      if (state.status == ChunkStatus.pending ||
          state.status == ChunkStatus.running) {
        state
          ..status = ChunkStatus.cancelled
          ..failureCode = 'cancelled'
          ..failureMessage = '作业取消';
      }
    }
    for (final attempt in attempts) {
      if (attempt.status == 'running') {
        attempt
          ..status = 'abandoned'
          ..duplicateBillingRisk = true
          ..errorCode = 'cancelled';
      }
    }
  }

  void addMergeLayer(MergeLayerRecord record) => mergeLayers.add(record);

  /// 恢复时把“上次仍在运行”的尝试标为结果未知；不自动重发。
  void _markInterrupted() {
    for (final state in chunks.values) {
      if (state.status == ChunkStatus.running) {
        state
          ..status = ChunkStatus.needsConfirm
          ..unknownOutcome = true
          ..failureCode = 'unknown_outcome'
          ..failureMessage = '上次请求结果未知（服务可能已完成并计费）；'
              '恢复时不会自动重发，需用户确认重试';
      }
    }
    for (final attempt in attempts) {
      if (attempt.status == 'running') {
        attempt
          ..status = 'abandoned'
          ..duplicateBillingRisk = true
          ..errorCode = 'unknown_outcome'
          ..errorMessage = '进程中断，未取得结果；可能已计费';
      }
    }
  }

  /// 恢复作业时提示的重复计费风险（存在未知结果时非空）。
  String? get duplicateBillingNotice {
    final risky = attempts.where((a) => a.duplicateBillingRisk).toList();
    if (risky.isEmpty) return null;
    return '有 ${risky.length} 次请求结果未知（超时/中断），服务可能已完成并计费；'
        '恢复时不会自动重发，请确认后再重试';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': 1,
        'jobId': jobId,
        'baseline': baseline.toJson(),
        'plan': plan.toJson(),
        'limits': limits.toDisplayJson(),
        'budget': budget.toJson(),
        'status': status.name,
        'phase': phase.name,
        'statusMessage': statusMessage,
        'attemptCounter': _attemptCounter,
        'chunks': chunks.values.map((c) => c.toJson()).toList(growable: false),
        'attempts': attempts.map((a) => a.toJson()).toList(growable: false),
        'mergeLayers':
            mergeLayers.map((m) => m.toJson()).toList(growable: false),
      };

  /// 诊断摘要（块 ID/耗时/错误码/大小；不含模型全文与密钥）。
  Map<String, dynamic> diagnosticJson() => <String, dynamic>{
        'jobId': jobId,
        'baselineSignature': baseline.signature,
        'status': status.name,
        'phase': phase.name,
        'chunksTotal': chunks.length,
        'chunksSucceeded': succeededChunkCount,
        'chunksFailed': failedChunkCount,
        'requestsUsed': budget.requestsUsed,
        'tokensUsed': budget.tokensUsed,
        'bytesUsed': budget.bytesUsed,
        'mergeLayers': mergeLayers.length,
        'attempts': <Map<String, dynamic>>[
          for (final attempt in attempts)
            <String, dynamic>{
              'attemptId': attempt.attemptId,
              'status': attempt.status,
              'errorCode': attempt.errorCode,
              'httpStatus': attempt.httpStatus,
              'requestBytes': attempt.requestUtf8Bytes,
              'estimatedTokens': attempt.estimatedTokens,
              'duplicateBillingRisk': attempt.duplicateBillingRisk,
              'elapsedMs': attempt.finishedAt
                  ?.difference(attempt.startedAt)
                  .inMilliseconds,
            },
        ],
      };
}
