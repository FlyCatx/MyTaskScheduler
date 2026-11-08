// 结构化事实账本 — 分块抽取的候选事实在这里被本地校验、归一、去重、
// 关联与矛盾登记。模型只是“提出候选”，本账本决定哪些事实可作为计划依据。
//
// 关键规则：
//   * 每条事实必须有来源：模型给的来源 ID 必须在本地片段索引里存在，并映射到
//     精确页/段与原文区间；引用不存在的来源 ID → 标记 unresolved，绝不静默丢；
//   * 引文（quote）必须能在来源片段里定位，否则事实保持 pending；
//   * 相互矛盾的日期/工时成为待确认项（保留全部事实与来源，不“最后一块赢”）；
//   * 去重按“来源身份 + 事实等价”，不只看任务标题；同名不同日期/对象保留；
//   * 跨块依赖先保留稳定候选线索，归并时解析为任务事实 ID；未解析依赖保留；
//   * “不能在周二 / 至少两小时 / 必须先完成 A”等否定、范围、依赖事实原样保留。
//
// 纯 Dart：不联网，不调用模型。

import 'dart:convert';

import 'material_chunker.dart';

/// 事实类别。
enum FactKind {
  task,
  constraint,
  date,
  hours,
  dependency,
  negation;

  String get wireName => name;

  static FactKind? parse(Object? raw) {
    final value = raw?.toString().trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    for (final kind in FactKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// 事实确认状态：confirmed = 来源与结构均通过本地校验；pending = 待用户确认。
enum FactStatus { confirmed, pending }

/// 原文引用的字符区间（相对所属片段文本）。
class QuoteSpan {
  const QuoteSpan({required this.start, required this.end, required this.quote});

  final int start;
  final int end;
  final String quote;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': start,
        'end': end,
        'quote': quote,
      };

  factory QuoteSpan.fromJson(Map<String, dynamic> j) => QuoteSpan(
        start: (j['start'] as num?)?.toInt() ?? 0,
        end: (j['end'] as num?)?.toInt() ?? 0,
        quote: (j['quote'] as String?) ?? '',
      );
}

/// 事实的一条来源引用（合并后可以有多条）。
class FactSourceRef {
  const FactSourceRef({
    required this.segmentId,
    required this.chunkId,
    required this.docHash,
    required this.page,
    this.quoteSpan,
    this.verified = false,
    this.sourceRef,
  });

  final String segmentId;
  final String chunkId;
  final String docHash;
  final int page;
  final QuoteSpan? quoteSpan;

  /// 来源片段存在且（有引文时）引文可在片段中定位。
  final bool verified;

  /// 模型原始引用（例如 `文段1:段落2`）。来源只精确到段落时如实保留该精度，
  /// 不用片段前缀冒充模型引句；为空表示通道未提供模型引用。
  final String? sourceRef;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'segmentId': segmentId,
        'chunkId': chunkId,
        'docHash': docHash,
        'page': page,
        'quoteSpan': quoteSpan?.toJson(),
        'verified': verified,
        if (sourceRef != null) 'sourceRef': sourceRef,
      };

  factory FactSourceRef.fromJson(Map<String, dynamic> j) => FactSourceRef(
        segmentId: (j['segmentId'] as String?) ?? '',
        chunkId: (j['chunkId'] as String?) ?? '',
        docHash: (j['docHash'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        quoteSpan: j['quoteSpan'] is Map<String, dynamic>
            ? QuoteSpan.fromJson(j['quoteSpan'] as Map<String, dynamic>)
            : null,
        verified: j['verified'] == true,
        sourceRef: j['sourceRef'] as String?,
      );
}

/// 模型给出的候选事实（本地尚未校验）。由 model_output_parser 生成。
class FactCandidate {
  const FactCandidate({
    required this.kind,
    required this.sourceIds,
    required this.taskHint,
    this.objectKey,
    this.quote,
    this.dueDate,
    this.dueDateRaw,
    this.hours,
    this.hoursIsMinimum = false,
    this.dependsOnHints = const <String>[],
    this.confidence,
    this.constraintText,
    this.sourceRefBySegment = const <String, String>{},
  });

  final FactKind kind;
  final List<String> sourceIds;

  /// segmentId → 模型原始引用（`文段K:段落M`）。仅用于如实保留来源精度。
  final Map<String, String> sourceRefBySegment;
  final String taskHint;

  /// 同名不同对象的区分线索（例如项目 A / 项目 B）。
  final String? objectKey;

  final String? quote;

  /// 本地解析后的绝对日期 `YYYY-MM-DD`；未解析为 null。
  final String? dueDate;

  /// 模型原始日期文本（相对日期无法解析时保留，不编造）。
  final String? dueDateRaw;

  final double? hours;

  /// `至少两小时` 的“至少”语义。
  final bool hoursIsMinimum;

  final List<String> dependsOnHints;
  final double? confidence;

  /// 否定/约束的原文短句（例如“不能在周二安排提交材料”）。
  final String? constraintText;
}

/// 一条已进入账本的事实。factId 由账本分配（`f:<chunkId>:<序号>`），在账本内唯一。
class FactEntry {
  const FactEntry({
    required this.factId,
    required this.kind,
    required this.docHash,
    required this.page,
    required this.segmentId,
    required this.quoteSpan,
    required this.taskHint,
    required this.dueDate,
    required this.hours,
    required this.hoursIsMinimum,
    required this.dependsOnHints,
    required this.confidence,
    required this.status,
    required this.chunkId,
    required this.jobId,
    this.objectKey,
    this.constraintText,
    this.dueDateRaw,
    this.sources = const <FactSourceRef>[],
    this.mergedFactIds = const <String>[],
    this.conflictReasons = const <String>[],
    this.unresolvedSourceIds = const <String>[],
    this.pendingReason,
  });

  final String factId;
  final FactKind kind;

  /// 主来源的文档哈希；来源 unresolved 时为空串（不编造）。
  final String docHash;
  final int page;
  final String segmentId;
  final QuoteSpan? quoteSpan;
  final String taskHint;
  final String? dueDate;
  final double? hours;
  final bool hoursIsMinimum;
  final List<String> dependsOnHints;
  final double? confidence;
  final FactStatus status;
  final String chunkId;
  final String jobId;

  final String? objectKey;
  final String? constraintText;
  final String? dueDateRaw;

  final List<FactSourceRef> sources;

  /// 被合并进来的其它事实 ID（来源与冲突理由都保留）。
  final List<String> mergedFactIds;
  final List<String> conflictReasons;
  final List<String> unresolvedSourceIds;
  final String? pendingReason;

  bool get isTask => kind == FactKind.task;
  bool get verifiedSource => sources.any((s) => s.verified);
  bool get hasUnresolvedSource => unresolvedSourceIds.isNotEmpty;

  FactEntry copyWith({
    FactStatus? status,
    List<FactSourceRef>? sources,
    List<String>? mergedFactIds,
    List<String>? conflictReasons,
    List<String>? unresolvedSourceIds,
    String? pendingReason,
    String? dueDate,
    double? hours,
    bool? hoursIsMinimum,
    List<String>? dependsOnHints,
    String? constraintText,
  }) =>
      FactEntry(
        factId: factId,
        kind: kind,
        docHash: docHash,
        page: page,
        segmentId: segmentId,
        quoteSpan: quoteSpan,
        taskHint: taskHint,
        dueDate: dueDate ?? this.dueDate,
        hours: hours ?? this.hours,
        hoursIsMinimum: hoursIsMinimum ?? this.hoursIsMinimum,
        dependsOnHints: dependsOnHints ?? this.dependsOnHints,
        confidence: confidence,
        status: status ?? this.status,
        chunkId: chunkId,
        jobId: jobId,
        objectKey: objectKey,
        constraintText: constraintText ?? this.constraintText,
        dueDateRaw: dueDateRaw,
        sources: sources ?? this.sources,
        mergedFactIds: mergedFactIds ?? this.mergedFactIds,
        conflictReasons: conflictReasons ?? this.conflictReasons,
        unresolvedSourceIds: unresolvedSourceIds ?? this.unresolvedSourceIds,
        pendingReason: pendingReason ?? this.pendingReason,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'factId': factId,
        'kind': kind.name,
        'docHash': docHash,
        'page': page,
        'segmentId': segmentId,
        'quoteSpan': quoteSpan?.toJson(),
        'taskHint': taskHint,
        'dueDate': dueDate,
        'dueDateRaw': dueDateRaw,
        'hours': hours,
        'hoursIsMinimum': hoursIsMinimum,
        'dependsOnHints': dependsOnHints,
        'confidence': confidence,
        'status': status.name,
        'chunkId': chunkId,
        'jobId': jobId,
        'objectKey': objectKey,
        'constraintText': constraintText,
        'sources': sources.map((s) => s.toJson()).toList(growable: false),
        'mergedFactIds': mergedFactIds,
        'conflictReasons': conflictReasons,
        'unresolvedSourceIds': unresolvedSourceIds,
        'pendingReason': pendingReason,
      };

  factory FactEntry.fromJson(Map<String, dynamic> j) => FactEntry(
        factId: (j['factId'] as String?) ?? '',
        kind: FactKind.parse(j['kind']) ?? FactKind.task,
        docHash: (j['docHash'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        segmentId: (j['segmentId'] as String?) ?? '',
        quoteSpan: j['quoteSpan'] is Map<String, dynamic>
            ? QuoteSpan.fromJson(j['quoteSpan'] as Map<String, dynamic>)
            : null,
        taskHint: (j['taskHint'] as String?) ?? '',
        dueDate: j['dueDate'] as String?,
        dueDateRaw: j['dueDateRaw'] as String?,
        hours: (j['hours'] as num?)?.toDouble(),
        hoursIsMinimum: j['hoursIsMinimum'] == true,
        dependsOnHints: ((j['dependsOnHints'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        confidence: (j['confidence'] as num?)?.toDouble(),
        status: FactStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => FactStatus.pending,
        ),
        chunkId: (j['chunkId'] as String?) ?? '',
        jobId: (j['jobId'] as String?) ?? '',
        objectKey: j['objectKey'] as String?,
        constraintText: j['constraintText'] as String?,
        sources: ((j['sources'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FactSourceRef.fromJson)
            .toList(growable: false),
        mergedFactIds: ((j['mergedFactIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        conflictReasons: ((j['conflictReasons'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        unresolvedSourceIds:
            ((j['unresolvedSourceIds'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
        pendingReason: j['pendingReason'] as String?,
      );
}

/// 两条（或多条）事实互相矛盾的登记。事实本身全部保留。
class FactContradiction {
  const FactContradiction({
    required this.key,
    required this.factIds,
    required this.reason,
  });

  /// 矛盾分组键（例如规范化任务名 + 对象线索）。
  final String key;
  final List<String> factIds;

  /// 用户可读的冲突理由（列出全部取值，不选“最后一块赢”）。
  final String reason;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'factIds': factIds,
        'reason': reason,
      };

  factory FactContradiction.fromJson(Map<String, dynamic> j) => FactContradiction(
        key: (j['key'] as String?) ?? '',
        factIds: ((j['factIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        reason: (j['reason'] as String?) ?? '',
      );
}

/// 无法解析到本地任务事实的依赖线索（保留，不静默丢弃）。
class UnresolvedDependency {
  const UnresolvedDependency({
    required this.factId,
    required this.hint,
    this.candidateFactIds = const <String>[],
  });

  final String factId;
  final String hint;
  final List<String> candidateFactIds;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'factId': factId,
        'hint': hint,
        'candidateFactIds': candidateFactIds,
      };

  factory UnresolvedDependency.fromJson(Map<String, dynamic> j) =>
      UnresolvedDependency(
        factId: (j['factId'] as String?) ?? '',
        hint: (j['hint'] as String?) ?? '',
        candidateFactIds:
            ((j['candidateFactIds'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
      );
}

/// 账本级问题（来源无法验证、引文找不到等）。
class LedgerIssue {
  const LedgerIssue({
    required this.code,
    required this.message,
    this.factId,
    this.critical = false,
  });

  final String code;
  final String message;
  final String? factId;

  /// true = 阻断“正式计划”，必须先由用户确认/排除。
  final bool critical;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        'factId': factId,
        'critical': critical,
      };

  factory LedgerIssue.fromJson(Map<String, dynamic> j) => LedgerIssue(
        code: (j['code'] as String?) ?? '',
        message: (j['message'] as String?) ?? '',
        factId: j['factId'] as String?,
        critical: j['critical'] == true,
      );
}

/// 待用户确认项（矛盾、未解析来源、低置信、未解析依赖）。
class PendingConfirmation {
  const PendingConfirmation({
    required this.id,
    required this.kind,
    required this.text,
    this.factIds = const <String>[],
    this.critical = false,
  });

  final String id;

  /// `contradiction` / `unresolvedSource` / `unresolvedDependency` /
  /// `lowConfidence` / `invalidDate`。
  final String kind;
  final String text;
  final List<String> factIds;
  final bool critical;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'text': text,
        'factIds': factIds,
        'critical': critical,
      };
}

/// 片段索引（从块切片重建，用于来源存在性与引文定位）。
class _SegmentIndexEntry {
  const _SegmentIndexEntry({
    required this.segmentId,
    required this.docHash,
    required this.page,
    required this.text,
    required this.fromOcr,
  });

  final String segmentId;
  final String docHash;
  final int page;
  final String text;
  final bool fromOcr;
}

/// 事实账本。
class FactLedger {
  FactLedger._({
    required this.jobId,
    required Map<String, _SegmentIndexEntry> segments,
  }) : _segments = segments;

  /// 从分块结果重建片段文本（非重叠切片按字符区间拼接，重叠片段跳过）。
  /// 这样作业持久化后不必保存完整原文也能校验来源。
  factory FactLedger.forChunks({
    required String jobId,
    required List<MaterialChunk> chunks,
  }) {
    final slicesBySegment = <String, List<ChunkSegmentSlice>>{};
    for (final chunk in chunks) {
      for (final slice in chunk.segments) {
        if (slice.overlap) continue;
        slicesBySegment
            .putIfAbsent(slice.segmentId, () => <ChunkSegmentSlice>[])
            .add(slice);
      }
    }
    final segments = <String, _SegmentIndexEntry>{};
    slicesBySegment.forEach((segmentId, slices) {
      final ordered = List<ChunkSegmentSlice>.from(slices)
        ..sort((a, b) => a.charStart.compareTo(b.charStart));
      final buffer = StringBuffer();
      for (final slice in ordered) {
        buffer.write(slice.text);
      }
      final first = ordered.first;
      segments[segmentId] = _SegmentIndexEntry(
        segmentId: segmentId,
        docHash: chunkDocHashFor(chunks, segmentId),
        page: first.page,
        text: buffer.toString(),
        fromOcr: ordered.any((slice) => slice.fromOcr),
      );
    });
    return FactLedger._(jobId: jobId, segments: segments);
  }

  /// 在块列表里查某片段所属文档哈希（重叠/跨块片段同样可查）。
  static String chunkDocHashFor(List<MaterialChunk> chunks, String segmentId) {
    for (final chunk in chunks) {
      if (chunk.segmentIds.contains(segmentId)) return chunk.docHash;
    }
    return '';
  }

  final String jobId;
  final Map<String, _SegmentIndexEntry> _segments;
  final Map<String, FactEntry> _facts = <String, FactEntry>{};
  final Map<String, String> _factIdByKey = <String, String>{};
  final List<String> _order = <String>[];
  final List<FactContradiction> _contradictions = <FactContradiction>[];
  final List<UnresolvedDependency> _unresolvedDependencies =
      <UnresolvedDependency>[];
  final List<LedgerIssue> _issues = <LedgerIssue>[];
  final Map<String, List<String>> _dependencyLinks = <String, List<String>>{};
  final Set<String> _unknownSegmentIds = <String>{};

  /// 用户人工排除的事实：factId → 理由。事实本身保留在账本里（可撤销、可追溯），
  /// 只是不再作为可用任务/待确认项参与预览与提交。
  final Map<String, String> _excluded = <String, String>{};

  int _factCounter = 0;
  bool _reconciled = false;

  bool get isReconciled => _reconciled;

  List<FactEntry> get facts => <FactEntry>[
        for (final id in _order) _facts[id]!,
      ];

  List<FactEntry> get confirmedFacts => facts
      .where((f) => !_excluded.containsKey(f.factId))
      .where((f) => f.status == FactStatus.confirmed)
      .toList(growable: false);

  List<FactEntry> get pendingFacts => facts
      .where((f) => !_excluded.containsKey(f.factId))
      .where((f) => f.status == FactStatus.pending)
      .toList(growable: false);

  List<FactEntry> get taskFacts => facts
      .where((f) => !_excluded.containsKey(f.factId))
      .where((f) => f.kind == FactKind.task)
      .toList(growable: false);

  /// factId → 排除理由（人工处理历史；撤销用 [restoreFact]）。
  Map<String, String> get excludedFacts => Map<String, String>.unmodifiable(_excluded);

  bool isExcluded(String factId) => _excluded.containsKey(factId);

  /// 人工排除一条事实：保留原始记录与理由，只从可用事实中移除。
  ///
  /// 这不是“隐藏提示”：预览任务、待确认项、依赖解析都会随之重算；调用方
  /// 必须重新构建预览，不能只改 UI。
  void excludeFact(String factId, {String reason = ''}) {
    if (!_facts.containsKey(factId)) return;
    _excluded[factId] = reason.trim().isEmpty ? '用户排除' : reason.trim();
    _reconciled = false;
  }

  /// 撤销一次人工排除。
  void restoreFact(String factId) {
    if (_excluded.remove(factId) != null) _reconciled = false;
  }

  List<FactContradiction> get contradictions =>
      List<FactContradiction>.unmodifiable(_contradictions);

  List<UnresolvedDependency> get unresolvedDependencies =>
      List<UnresolvedDependency>.unmodifiable(_unresolvedDependencies);

  List<LedgerIssue> get issues => List<LedgerIssue>.unmodifiable(_issues);

  List<LedgerIssue> get criticalIssues =>
      _issues.where((i) => i.critical).toList(growable: false);

  /// factId → 它依赖的任务 factIds（已解析部分）。
  Map<String, List<String>> get dependencyLinks =>
      <String, List<String>>{
        for (final entry in _dependencyLinks.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      };

  /// 是否有模型凭空引用（来源 ID 在本地不存在）。存在时不能产出正式计划。
  bool get hasUnresolvedSources => _unknownSegmentIds.isNotEmpty;

  Set<String> get unknownSegmentIds =>
      Set<String>.unmodifiable(_unknownSegmentIds);

  /// 来源 ID 是否存在于本地片段索引。
  bool hasSegment(String segmentId) => _segments.containsKey(segmentId);

  String segmentText(String segmentId) => _segments[segmentId]?.text ?? '';

  int segmentPage(String segmentId) => _segments[segmentId]?.page ?? 0;

  // ------------------------------------------------------------------ ingest

  /// 加入一条候选事实并做本地校验/归一/去重。
  ///
  /// 返回入账后的事实（可能是合并到已有事实的版本）。任何情况下事实不会被丢弃：
  /// 来源不存在的保留为 unresolved + pending，留给用户确认。
  FactEntry addCandidate(
    FactCandidate candidate, {
    required String chunkId,
    bool fromOcr = false,
  }) {
    _reconciled = false;
    final verifiedSources = <FactSourceRef>[];
    final unresolved = <String>[];
    var quoteMiss = false;
    var ocrSource = false;
    for (final rawId in candidate.sourceIds) {
      final id = rawId.trim();
      if (id.isEmpty) continue;
      final segment = _segments[id];
      if (segment == null) {
        unresolved.add(id);
        _unknownSegmentIds.add(id);
        continue;
      }
      if (segment.fromOcr) ocrSource = true;
      final quote = candidate.quote?.trim();
      QuoteSpan? span;
      if (quote != null && quote.isNotEmpty) {
        span = locateQuote(segment.text, quote);
        if (span == null) quoteMiss = true;
      }
      verifiedSources.add(FactSourceRef(
        segmentId: segment.segmentId,
        chunkId: chunkId,
        docHash: segment.docHash,
        page: segment.page,
        quoteSpan: span,
        verified: quote == null || quote.isEmpty || span != null,
        sourceRef: candidate.sourceRefBySegment[segment.segmentId],
      ));
    }

    // 日期/工时/置信度的本地复核。
    final dateProblem = candidate.dueDateRaw != null &&
        candidate.dueDate == null &&
        candidate.dueDateRaw!.trim().isNotEmpty;
    final lowConfidence = candidate.confidence != null &&
        (candidate.confidence! < 0.5 ||
            ((fromOcr || ocrSource) &&
                (candidate.kind == FactKind.date ||
                    candidate.kind == FactKind.hours) &&
                candidate.confidence! < 0.85));

    String? pendingReason;
    if (unresolved.isNotEmpty) {
      pendingReason = '模型引用了不存在的来源 ID：${unresolved.join('、')}';
      _issues.add(LedgerIssue(
        code: 'unresolved_source',
        factId: null,
        critical: true,
        message: '事实「${candidate.taskHint}」引用了本地不存在的来源 ID：'
            '${unresolved.join('、')}（已保留并标记 unresolved，未静默丢弃）',
      ));
    } else if (quoteMiss) {
      pendingReason = '引文未能在来源片段中找到，需人工确认';
      _issues.add(LedgerIssue(
        code: 'quote_not_found',
        critical: false,
        message: '事实「${candidate.taskHint}」的引文未能在来源片段中定位',
      ));
    } else if (dateProblem) {
      pendingReason = '日期无法本地解析：${candidate.dueDateRaw}（未编造日期）';
    } else if (lowConfidence) {
      pendingReason = '置信度较低，需用户确认';
    }

    final primary = verifiedSources.isEmpty ? null : verifiedSources.first;
    final status = pendingReason == null ? FactStatus.confirmed : FactStatus.pending;
    final fact = FactEntry(
      factId: 'f:$chunkId:${_factCounter++}',
      kind: candidate.kind,
      docHash: primary?.docHash ?? '',
      page: primary?.page ?? 0,
      segmentId: primary?.segmentId ?? '',
      quoteSpan: primary?.quoteSpan,
      taskHint: candidate.taskHint.trim(),
      dueDate: candidate.dueDate,
      dueDateRaw: candidate.dueDateRaw,
      hours: candidate.hours,
      hoursIsMinimum: candidate.hoursIsMinimum,
      dependsOnHints: List<String>.unmodifiable(
          candidate.dependsOnHints.map((h) => h.trim()).where((h) => h.isNotEmpty)),
      confidence: candidate.confidence,
      status: status,
      chunkId: chunkId,
      jobId: jobId,
      objectKey: _cleanObject(candidate.objectKey),
      constraintText: candidate.constraintText?.trim(),
      sources: List<FactSourceRef>.unmodifiable(verifiedSources),
      unresolvedSourceIds: List<String>.unmodifiable(unresolved),
      pendingReason: pendingReason,
      conflictReasons: const <String>[],
      mergedFactIds: const <String>[],
    );

    final key = _dedupeKey(fact);
    final existingId = _factIdByKey[key];
    if (existingId != null) {
      final merged = _mergeInto(_facts[existingId]!, fact);
      _facts[merged.factId] = merged;
      return merged;
    }
    _factIdByKey[key] = fact.factId;
    _facts[fact.factId] = fact;
    _order.add(fact.factId);
    return fact;
  }

  /// 应用模型归并结果：把 [groups] 中的事实合成一条，保留全部来源与理由。
  void applyMergeGroups(
    List<List<String>> groups, {
    List<String> reasons = const <String>[],
  }) {
    for (final group in groups) {
      final ids = group.where(_facts.containsKey).toList(growable: false);
      if (ids.length < 2) continue;
      final canonical = _facts[ids.first]!;
      var merged = canonical;
      for (var i = 1; i < ids.length; i++) {
        merged = _mergeInto(merged, _facts[ids[i]]!);
      }
      final reason = reasons.isEmpty ? '模型判定为同一事实（归并）' : reasons.first;
      merged = merged.copyWith(
        conflictReasons: <String>[
          ...merged.conflictReasons,
          '归并理由：$reason',
        ],
        mergedFactIds: <String>[
          ...merged.mergedFactIds,
          for (final id in ids.skip(1)) id,
        ],
      );
      _facts[merged.factId] = merged;
      for (final id in ids.skip(1)) {
        _facts.remove(id);
        _order.remove(id);
      }
      // 同一事实的旧键仍指向保留的事实。
      _factIdByKey[_dedupeKey(merged)] = merged.factId;
      _reconciled = false;
    }
  }

  FactEntry _mergeInto(FactEntry base, FactEntry other) {
    final sources = <FactSourceRef>[...base.sources];
    for (final source in other.sources) {
      // 来源身份 = 片段 ID + 原文区间；同一片段在重叠块里被再次抽取不算新来源。
      final duplicate = sources.any((s) =>
          s.segmentId == source.segmentId &&
          (s.quoteSpan?.start ?? -1) == (source.quoteSpan?.start ?? -1) &&
          (s.quoteSpan?.end ?? -1) == (source.quoteSpan?.end ?? -1));
      if (!duplicate) sources.add(source);
    }
    final unresolved = <String>{
      ...base.unresolvedSourceIds,
      ...other.unresolvedSourceIds,
    }.toList(growable: false);
    final reasons = <String>[
      ...base.conflictReasons,
      ...other.conflictReasons,
    ];
    final pending = base.status == FactStatus.pending ||
        other.status == FactStatus.pending;
    final pendingReason = base.pendingReason ??
        other.pendingReason ??
        (base.status == FactStatus.pending || other.status == FactStatus.pending
            ? '合并事实中存在待确认项'
            : null);
    return base.copyWith(
      status: pending ? FactStatus.pending : FactStatus.confirmed,
      sources: List<FactSourceRef>.unmodifiable(sources),
      unresolvedSourceIds: unresolved,
      mergedFactIds: <String>[
        ...base.mergedFactIds,
        ...other.mergedFactIds,
        if (!base.mergedFactIds.contains(other.factId)) other.factId,
      ],
      conflictReasons: List<String>.unmodifiable(reasons),
      pendingReason: pendingReason,
    );
  }

  // ------------------------------------------------------------- reconcile

  /// 跨块关联/去重/矛盾登记/依赖解析。幂等，可重复调用。
  void reconcile() {
    _contradictions.clear();
    _unresolvedDependencies.clear();
    _dependencyLinks.clear();

    // 1) 矛盾日期/工时：同一任务（标题 + 对象线索）出现不同取值。
    final taskGroups = <String, List<FactEntry>>{};
    for (final fact in facts) {
      if (fact.kind != FactKind.task && fact.kind != FactKind.date) continue;
      final key = _taskGroupKey(fact);
      taskGroups.putIfAbsent(key, () => <FactEntry>[]).add(fact);
    }
    taskGroups.forEach((key, group) {
      if (group.length < 2) return;
      final dates = <String>{
        for (final fact in group)
          if (fact.dueDate != null && fact.dueDate!.isNotEmpty) fact.dueDate!,
      };
      if (dates.length > 1) {
        _contradictions.add(FactContradiction(
          key: key,
          factIds: group.map((f) => f.factId).toList(growable: false),
          reason: '同一任务的截止日期互相矛盾：${dates.join(' / ')}；'
              '保留全部来源，等待用户确认（不采用最后一块）',
        ));
      }
      final hours = <String>{
        for (final fact in group)
          if (fact.hours != null) _hoursLabel(fact),
      };
      if (hours.length > 1) {
        _contradictions.add(FactContradiction(
          key: '$key#hours',
          factIds: group.map((f) => f.factId).toList(growable: false),
          reason: '同一任务的工时互相矛盾：${hours.join(' / ')}；等待用户确认',
        ));
      }
    });

    // 2) 依赖解析：先按规范化标题精确匹配，唯一包含匹配才接受。
    final byNormalizedTitle = <String, List<FactEntry>>{};
    for (final fact in taskFacts) {
      byNormalizedTitle
          .putIfAbsent(_normalizeText(fact.taskHint), () => <FactEntry>[])
          .add(fact);
    }
    for (final fact in facts) {
      if (fact.dependsOnHints.isEmpty) continue;
      final resolved = <String>[];
      for (final hint in fact.dependsOnHints) {
        final normalized = _normalizeText(hint);
        var matches = byNormalizedTitle[normalized] ?? const <FactEntry>[];
        if (matches.isEmpty) {
          final contains = <FactEntry>[
            for (final entry in byNormalizedTitle.entries)
              if (entry.key.contains(normalized) || normalized.contains(entry.key))
                ...entry.value,
          ];
          if (contains.length == 1) matches = contains;
        }
        if (matches.length == 1) {
          resolved.add(matches.first.factId);
        } else {
          _unresolvedDependencies.add(UnresolvedDependency(
            factId: fact.factId,
            hint: hint,
            candidateFactIds:
                matches.map((f) => f.factId).toList(growable: false),
          ));
        }
      }
      if (resolved.isNotEmpty) {
        _dependencyLinks
            .putIfAbsent(fact.factId, () => <String>[])
            .addAll(resolved);
      }
      // 依赖事实（“必须先完成 A”类）的描述对象是某任务时，把已解析的目标
      // 挂到该任务事实的依赖上，预览阶段才能生成任务间依赖。
      if (fact.kind == FactKind.dependency && resolved.isNotEmpty) {
        final targets = byNormalizedTitle[_normalizeText(fact.taskHint)] ??
            const <FactEntry>[];
        if (targets.length == 1) {
          final links = _dependencyLinks.putIfAbsent(
              targets.first.factId, () => <String>[]);
          for (final id in resolved) {
            if (!links.contains(id)) links.add(id);
          }
        }
      }
    }
    _reconciled = true;
  }

  /// 登记一条由模型归并层给出的矛盾（不改变事实本身，只增加待确认项）。
  void registerContradiction(FactContradiction contradiction) {
    _contradictions.add(contradiction);
  }

  /// 用户可见的待确认项（矛盾/未知来源/未解析依赖/低置信/日期未解析）。
  List<PendingConfirmation> pendingConfirmations() {
    final out = <PendingConfirmation>[];
    var index = 0;
    for (final contradiction in _contradictions) {
      // 相关事实都被人工排除后，矛盾也随之解决（保留原始记录，不再提示）。
      if (contradiction.factIds.isNotEmpty &&
          contradiction.factIds.every(_excluded.containsKey)) {
        continue;
      }
      out.add(PendingConfirmation(
        id: 'pending:contradiction:${index++}',
        kind: 'contradiction',
        text: contradiction.reason,
        factIds: contradiction.factIds,
      ));
    }
    for (final fact in pendingFacts) {
      if (fact.hasUnresolvedSource) {
        out.add(PendingConfirmation(
          id: 'pending:unresolved:${fact.factId}',
          kind: 'unresolvedSource',
          critical: true,
          factIds: <String>[fact.factId],
          text: '「${_factLabel(fact)}」引用了不存在的来源 ID '
              '${fact.unresolvedSourceIds.join('、')}，已标记 unresolved；'
              '请确认是否排除该事实',
        ));
      } else if (fact.dueDateRaw != null && fact.dueDate == null) {
        out.add(PendingConfirmation(
          id: 'pending:date:${fact.factId}',
          kind: 'invalidDate',
          factIds: <String>[fact.factId],
          text: '「${_factLabel(fact)}」的日期「${fact.dueDateRaw}」无法本地解析，'
              '未编造日期，请确认',
        ));
      } else if (fact.pendingReason != null) {
        out.add(PendingConfirmation(
          id: 'pending:fact:${fact.factId}',
          kind: 'lowConfidence',
          factIds: <String>[fact.factId],
          text: '「${_factLabel(fact)}」${fact.pendingReason}',
        ));
      }
    }
    for (final dependency in _unresolvedDependencies) {
      if (_excluded.containsKey(dependency.factId)) continue;
      out.add(PendingConfirmation(
        id: 'pending:dependency:${dependency.factId}:'
            '${_normalizeText(dependency.hint)}',
        kind: 'unresolvedDependency',
        factIds: <String>[dependency.factId],
        text: '依赖线索「${dependency.hint}」无法解析为本地任务；已保留，'
            '未静默丢弃',
      ));
    }
    return List<PendingConfirmation>.unmodifiable(out);
  }

  /// 否定/范围/依赖约束的用户可读清单（供预览草稿的 notes 使用）。
  List<FactEntry> get constraintFacts => facts
      .where((f) =>
          f.kind == FactKind.constraint ||
          f.kind == FactKind.negation ||
          f.kind == FactKind.hours ||
          f.kind == FactKind.dependency)
      .toList(growable: false);

  // ------------------------------------------------------------------ utils

  String _dedupeKey(FactEntry fact) {
    final hint = _normalizeText(fact.taskHint);
    final object = _normalizeText(fact.objectKey ?? '');
    switch (fact.kind) {
      case FactKind.task:
        return 'task|$hint|$object|${fact.dueDate ?? ''}|${_hoursLabel(fact)}';
      case FactKind.date:
        return 'date|$hint|${fact.dueDate ?? fact.dueDateRaw ?? ''}';
      case FactKind.hours:
        return 'hours|$hint|${_hoursLabel(fact)}';
      case FactKind.dependency:
        return 'dependency|$hint|'
            '${fact.dependsOnHints.map(_normalizeText).join(',')}';
      case FactKind.negation:
      case FactKind.constraint:
        return '${fact.kind.name}|$hint|'
            '${_normalizeText(fact.constraintText ?? '')}|'
            '${_normalizeText(fact.quoteSpan?.quote ?? '')}';
    }
  }

  static String _taskGroupKey(FactEntry fact) =>
      '${_normalizeText(fact.taskHint)}|${fact.objectKey ?? ''}';

  static String _hoursLabel(FactEntry fact) {
    if (fact.hours == null) return '';
    final value = fact.hours == fact.hours!.roundToDouble()
        ? fact.hours!.toStringAsFixed(0)
        : fact.hours!.toString();
    return fact.hoursIsMinimum ? '>=$value' : value;
  }

  static String _factLabel(FactEntry fact) {
    if (fact.taskHint.isNotEmpty) return fact.taskHint;
    if (fact.constraintText != null && fact.constraintText!.isNotEmpty) {
      return fact.constraintText!;
    }
    return fact.factId;
  }

  /// 对象线索保留原始大小写（展示用）；去重/分组时才规范化。
  static String _cleanObject(String? raw) => raw?.trim() ?? '';

  /// 去重用规范化：全角/半角空白归一、去除标点差异、小写。
  static String _normalizeText(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.toLowerCase().runes) {
      if (_isPunctuationOrSpace(rune)) continue;
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  static bool _isPunctuationOrSpace(int rune) {
    return rune == 0x20 ||
        (rune >= 0x09 && rune <= 0x0D) ||
        (rune >= 0x3000 && rune <= 0x303F) ||
        (rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x60) ||
        (rune >= 0x7B && rune <= 0x7E) ||
        (rune >= 0xFF01 && rune <= 0xFF0F) ||
        (rune >= 0xFF1A && rune <= 0xFF20) ||
        (rune >= 0xFF3B && rune <= 0xFF40) ||
        (rune >= 0xFF5B && rune <= 0xFF65);
  }

  /// 在来源片段中定位引文（先精确、后忽略空白差异），返回原文区间。
  static QuoteSpan? locateQuote(String text, String quote) {
    if (quote.isEmpty) return null;
    final exact = text.indexOf(quote);
    if (exact >= 0) {
      return QuoteSpan(start: exact, end: exact + quote.length, quote: quote);
    }
    final trimmed = quote.trim();
    if (trimmed.isNotEmpty) {
      final second = text.indexOf(trimmed);
      if (second >= 0) {
        return QuoteSpan(
            start: second, end: second + trimmed.length, quote: trimmed);
      }
    }
    // 忽略空白差异的匹配：把片段压成“非空白字符 + 原下标”后查找。
    final compressed = StringBuffer();
    final positions = <int>[];
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch.trim().isEmpty) continue;
      compressed.write(ch);
      positions.add(i);
    }
    final normalizedQuote = quote.replaceAll(RegExp(r'\s+'), '');
    if (normalizedQuote.isEmpty) return null;
    final hit = compressed.toString().indexOf(normalizedQuote);
    if (hit < 0) return null;
    final start = positions[hit];
    final end = positions[hit + normalizedQuote.length - 1] + 1;
    return QuoteSpan(start: start, end: end, quote: text.substring(start, end));
  }
}

/// 日期解析：相对日期必须使用**作业固定基准**（asOf），不能随跨午夜漂移。
class AnalysisDateResolver {
  const AnalysisDateResolver({required this.asOf, required this.timeZoneId});

  final DateTime asOf;
  final String timeZoneId;

  static final RegExp _isoPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final RegExp _cnPattern =
      RegExp(r'^(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$');
  static final RegExp _weekdayPattern =
      RegExp(r'^(下{0,2}|这|本)?\s*(周|星期|礼拜)([一二三四五六日天1-7])$');

  /// 把模型给的日期文本转成 `YYYY-MM-DD`；无法可靠解析返回 null（不编造）。
  String? resolve(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    final iso = _isoPattern.firstMatch(text);
    if (iso != null) {
      return _formatSafe(
          int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
    }
    final cn = _cnPattern.firstMatch(text);
    if (cn != null) {
      return _formatSafe(
          int.parse(cn.group(1)!), int.parse(cn.group(2)!), int.parse(cn.group(3)!));
    }
    final relative = _resolveRelative(text);
    return relative;
  }

  String? _resolveRelative(String text) {
    final base = DateTime(asOf.year, asOf.month, asOf.day);
    switch (text) {
      case '今天':
      case '今日':
      case 'today':
        return formatDateKey(base);
      case '明天':
      case '明日':
      case 'tomorrow':
        return formatDateKey(base.add(const Duration(days: 1)));
      case '后天':
        return formatDateKey(base.add(const Duration(days: 2)));
      case '大后天':
        return formatDateKey(base.add(const Duration(days: 3)));
    }
    final weekday = _weekdayPattern.firstMatch(text);
    if (weekday != null) {
      final target = _weekdayNumber(weekday.group(3)!);
      if (target == null) return null;
      final prefix = weekday.group(1) ?? '';
      final current = base.weekday; // 1=周一 … 7=周日
      var daysAhead = (target - current) % 7;
      if (daysAhead == 0) daysAhead = 7;
      if (prefix == '下') daysAhead += 7;
      if (prefix == '下下') daysAhead += 14;
      return formatDateKey(base.add(Duration(days: daysAhead)));
    }
    return null;
  }

  static int? _weekdayNumber(String raw) {
    const map = <String, int>{
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7,
      '1': 1,
      '2': 2,
      '3': 3,
      '4': 4,
      '5': 5,
      '6': 6,
      '7': 7,
    };
    return map[raw];
  }

  static String? _formatSafe(int year, int month, int day) {
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return formatDateKey(parsed);
  }

  static String formatDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

/// 便于阅读的事实摘要（诊断/预览用，不含全文）。
String factSummary(FactEntry fact) =>
    '${fact.kind.name}「${fact.taskHint.isEmpty ? fact.constraintText ?? '' : fact.taskHint}」'
    '${fact.dueDate == null ? '' : ' 截止 ${fact.dueDate}'}'
    '${fact.hours == null ? '' : ' 工时 ${fact.hours}'}'
    '${fact.status == FactStatus.pending ? '（待确认）' : ''}';

/// JSON 稳定编码（测试/诊断用）。
String factJson(FactEntry fact) => jsonEncode(fact.toJson());
