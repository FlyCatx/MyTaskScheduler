// 材料分块器 — 结构优先（文档 / 页 / 标题 / 段落），超大单段再细分。
//
// 关键不变量（R3-L L2/L1）：
//   * 每个片段有**稳定 ID**：`<docHash>:<page>:<index>`，重叠片段复用同一 ID，
//     因此跨块去重与来源追溯不依赖块序号；
//   * 超长内容只**拆分**、绝不截尾：切片保存原文本的字符区间 [charStart,charEnd)；
//   * 相邻块带适量重叠（标记 overlap），让跨块任务/日期/依赖仍能同块出现；
//   * 表格/列表行、纯日期行尽量与相邻任务保留在同块；
//   * 输出 coverage manifest（文档/页/片段覆盖清单）与 unsplittable 记录；
//   * 本地资源限额（原文件字节、提取文本总字节）触发时显式失败，不静默丢页。
//
// 本文件是纯 Dart：不读文件、不联网、不调用模型。

import 'dart:convert';

import '../document_extraction_types.dart';
import 'analysis_budget.dart';

/// 材料来源的一段文本，带稳定 ID 与页定位。
class SourceSegment {
  const SourceSegment({
    required this.segmentId,
    required this.docHash,
    required this.page,
    required this.index,
    required this.text,
    this.location,
    this.fromOcr = false,
  });

  /// 稳定片段 ID：`<docHash>:<page>:<index>`（页不可靠时为 0）。
  factory SourceSegment.create({
    required String docHash,
    required int page,
    required int index,
    required String text,
    String? location,
    bool fromOcr = false,
  }) =>
      SourceSegment(
        segmentId: '$docHash:$page:$index',
        docHash: docHash,
        page: page,
        index: index,
        text: text,
        location: location,
        fromOcr: fromOcr,
      );

  final String segmentId;
  final String docHash;

  /// 1-based 页号（PDF/PPTX）；0 = 不可靠分页（TXT/MD/DOCX）。
  final int page;

  /// 文档内片段序号（同页内也唯一）。
  final int index;

  final String text;

  /// 原始定位文本，如 `第 3 页`、`第 12 段`。
  final String? location;

  /// OCR 生成的文字（低置信事实应保持待确认）。
  final bool fromOcr;

  int get utf8Bytes => utf8.encode(text).length;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'segmentId': segmentId,
        'docHash': docHash,
        'page': page,
        'index': index,
        'text': text,
        if (location != null) 'location': location,
        'fromOcr': fromOcr,
      };

  factory SourceSegment.fromJson(Map<String, dynamic> j) => SourceSegment(
        segmentId: (j['segmentId'] as String?) ?? '',
        docHash: (j['docHash'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        index: (j['index'] as num?)?.toInt() ?? 0,
        text: (j['text'] as String?) ?? '',
        location: j['location'] as String?,
        fromOcr: j['fromOcr'] == true,
      );
}

/// 一份来源材料（文档），由有序片段组成。
class SourceDocument {
  const SourceDocument({
    required this.docHash,
    required this.label,
    required this.kind,
    required this.segments,
    this.sourceFileBytes = 0,
    this.fromOcr = false,
  });

  /// 从现有本地提取结果构造，保留 `第 N 页 / 第 N 段 / 第 N 张幻灯片` 定位。
  factory SourceDocument.fromExtractedDocument(
    ExtractedDocument document, {
    required String docHash,
    required String label,
    int sourceFileBytes = 0,
    bool fromOcr = false,
  }) {
    final segments = <SourceSegment>[];
    for (var i = 0; i < document.segments.length; i++) {
      final raw = document.segments[i];
      final text = raw.text;
      if (text.trim().isEmpty) continue;
      final page = _pageOfLocation(raw.location, i);
      segments.add(SourceSegment.create(
        docHash: docHash,
        page: page,
        index: i,
        text: text,
        location: raw.location,
        fromOcr: fromOcr,
      ));
    }
    return SourceDocument(
      docHash: docHash,
      label: label,
      kind: document.kind,
      segments: segments,
      sourceFileBytes: sourceFileBytes,
      fromOcr: fromOcr,
    );
  }

  static int _pageOfLocation(String? location, int index) {
    if (location == null) return 0;
    final page = RegExp(r'第\s*(\d+)\s*页').firstMatch(location);
    if (page != null) return int.parse(page.group(1)!);
    final slide = RegExp(r'第\s*(\d+)\s*张幻灯片').firstMatch(location);
    if (slide != null) return int.parse(slide.group(1)!);
    // “第 N 段”没有可靠页号：归为 page 0，但保留片段序号。
    return 0;
  }

  final String docHash;
  final String label;

  /// `pdf` / `docx` / `pptx` / `txt` / `md` / `ocr`。
  final String kind;
  final List<SourceSegment> segments;

  /// 原文件字节数（用于与原文件上限比较；0 = 未知）。
  final int sourceFileBytes;
  final bool fromOcr;

  int get extractedUtf8Bytes =>
      segments.fold(0, (sum, s) => sum + s.utf8Bytes);

  /// PDF/PPTX 的可核查页数；无可靠分页时为 0。
  int get pageCount {
    if (kind != 'pdf' && kind != 'pptx') return 0;
    var maxPage = 0;
    for (final s in segments) {
      if (s.page > maxPage) maxPage = s.page;
    }
    return maxPage;
  }

  bool get isPaged => pageCount > 0;
}

/// 块内的一段材料切片（原文本的 [charStart, charEnd) 区间）。
class ChunkSegmentSlice {
  const ChunkSegmentSlice({
    required this.segmentId,
    required this.page,
    required this.index,
    required this.text,
    required this.charStart,
    required this.charEnd,
    this.overlap = false,
    this.fromOcr = false,
  });

  final String segmentId;
  final int page;
  final int index;
  final String text;
  final int charStart;
  final int charEnd;

  /// 上下文重叠片段：内容已在别的块里出现过，仅用于让跨块任务/日期不断开。
  final bool overlap;

  /// 该切片来自 OCR 文本（低置信事实保持待确认）。
  final bool fromOcr;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'segmentId': segmentId,
        'page': page,
        'index': index,
        'text': text,
        'charStart': charStart,
        'charEnd': charEnd,
        'overlap': overlap,
        'fromOcr': fromOcr,
      };

  factory ChunkSegmentSlice.fromJson(Map<String, dynamic> j) => ChunkSegmentSlice(
        segmentId: (j['segmentId'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        index: (j['index'] as num?)?.toInt() ?? 0,
        text: (j['text'] as String?) ?? '',
        charStart: (j['charStart'] as num?)?.toInt() ?? 0,
        charEnd: (j['charEnd'] as num?)?.toInt() ?? 0,
        overlap: j['overlap'] == true,
        fromOcr: j['fromOcr'] == true,
      );
}

/// 一次抽取请求的材料块。
class MaterialChunk {
  const MaterialChunk({
    required this.chunkId,
    required this.docHash,
    required this.firstPage,
    required this.lastPage,
    required this.segments,
    required this.text,
    required this.segmentIds,
    required this.hasOverlap,
    required this.utf8Bytes,
    required this.estimatedTokens,
  });

  /// 稳定块 ID：`chunk:<docHash>:<page>:<起始字符偏移>`。
  final String chunkId;
  final String docHash;
  final int firstPage;
  final int lastPage;
  final List<ChunkSegmentSlice> segments;

  /// 拼好的材料正文（各切片按顺序以换行连接）。
  final String text;

  /// 块内出现的稳定片段 ID（含重叠片段）。
  final List<String> segmentIds;

  final bool hasOverlap;
  final int utf8Bytes;
  final int estimatedTokens;

  String get pageLabel {
    if (firstPage <= 0) return '无分页（按段）';
    return firstPage == lastPage ? '第 $firstPage 页' : '第 $firstPage–$lastPage 页';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunkId': chunkId,
        'docHash': docHash,
        'firstPage': firstPage,
        'lastPage': lastPage,
        'segments': segments.map((s) => s.toJson()).toList(growable: false),
        'text': text,
        'segmentIds': segmentIds,
        'hasOverlap': hasOverlap,
        'utf8Bytes': utf8Bytes,
        'estimatedTokens': estimatedTokens,
      };

  factory MaterialChunk.fromJson(Map<String, dynamic> j) => MaterialChunk(
        chunkId: (j['chunkId'] as String?) ?? '',
        docHash: (j['docHash'] as String?) ?? '',
        firstPage: (j['firstPage'] as num?)?.toInt() ?? 0,
        lastPage: (j['lastPage'] as num?)?.toInt() ?? 0,
        segments: ((j['segments'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChunkSegmentSlice.fromJson)
            .toList(growable: false),
        text: (j['text'] as String?) ?? '',
        segmentIds: ((j['segmentIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        hasOverlap: j['hasOverlap'] == true,
        utf8Bytes: (j['utf8Bytes'] as num?)?.toInt() ?? 0,
        estimatedTokens: (j['estimatedTokens'] as num?)?.toInt() ?? 0,
      );
}

/// 不可按原结构保留、只能硬拆或无法装入的单元记录。内容仍不丢失（硬拆）。
class UnsplittableItem {
  const UnsplittableItem({
    required this.segmentId,
    required this.page,
    required this.docHash,
    required this.reason,
    this.blocking = false,
  });

  final String segmentId;
  final int page;
  final String docHash;

  /// 例如“单段无可读断点，按字符边界硬拆（内容未截断）”。
  final String reason;

  /// true = 即使硬拆也装不进请求预算（材料无法完整覆盖）。
  final bool blocking;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'segmentId': segmentId,
        'page': page,
        'docHash': docHash,
        'reason': reason,
        'blocking': blocking,
      };

  factory UnsplittableItem.fromJson(Map<String, dynamic> j) => UnsplittableItem(
        segmentId: (j['segmentId'] as String?) ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        docHash: (j['docHash'] as String?) ?? '',
        reason: (j['reason'] as String?) ?? '',
        blocking: j['blocking'] == true,
      );
}

/// 材料级问题（本地限额或结构失败）。[critical] 的问题使覆盖清单不完整。
class MaterialIssue {
  const MaterialIssue({
    required this.code,
    required this.message,
    this.docHash,
    this.critical = false,
  });

  final String code;
  final String message;
  final String? docHash;
  final bool critical;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        'docHash': docHash,
        'critical': critical,
      };

  factory MaterialIssue.fromJson(Map<String, dynamic> j) => MaterialIssue(
        code: (j['code'] as String?) ?? '',
        message: (j['message'] as String?) ?? '',
        docHash: j['docHash'] as String?,
        critical: j['critical'] == true,
      );
}

/// 单份文档的覆盖情况。
class DocumentCoverage {
  const DocumentCoverage({
    required this.docHash,
    required this.label,
    required this.kind,
    required this.totalPages,
    required this.coveredPages,
    required this.totalSegments,
    required this.coveredSegments,
    required this.uncoveredSegmentIds,
    required this.missingPages,
    this.fromOcr = false,
  });

  final String docHash;
  final String label;
  final String kind;

  /// PDF/PPTX 的页数；无分页文档为 0。
  final int totalPages;

  /// 被至少一个块覆盖的页号（升序）。
  final List<int> coveredPages;

  final int totalSegments;
  final int coveredSegments;
  final List<String> uncoveredSegmentIds;

  /// 有页概念但没有任何文本/片段的页号（需显式失败，不能用成功页掩盖丢页）。
  final List<int> missingPages;

  final bool fromOcr;

  bool get complete =>
      uncoveredSegmentIds.isEmpty && missingPages.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'docHash': docHash,
        'label': label,
        'kind': kind,
        'totalPages': totalPages,
        'coveredPages': coveredPages,
        'totalSegments': totalSegments,
        'coveredSegments': coveredSegments,
        'uncoveredSegmentIds': uncoveredSegmentIds,
        'missingPages': missingPages,
        'fromOcr': fromOcr,
        'complete': complete,
      };

  factory DocumentCoverage.fromJson(Map<String, dynamic> j) => DocumentCoverage(
        docHash: (j['docHash'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        totalPages: (j['totalPages'] as num?)?.toInt() ?? 0,
        coveredPages: ((j['coveredPages'] as List<dynamic>?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(growable: false),
        totalSegments: (j['totalSegments'] as num?)?.toInt() ?? 0,
        coveredSegments: (j['coveredSegments'] as num?)?.toInt() ?? 0,
        uncoveredSegmentIds:
            ((j['uncoveredSegmentIds'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
        missingPages: ((j['missingPages'] as List<dynamic>?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(growable: false),
        fromOcr: j['fromOcr'] == true,
      );
}

/// 覆盖清单：机器可核查“处理覆盖了什么”，它证明覆盖，不证明语义无遗漏。
class CoverageManifest {
  const CoverageManifest({
    required this.documents,
    required this.chunkCount,
    required this.estimatedExtractionRequests,
    required this.estimatedTokens,
    required this.unsplittable,
    required this.issues,
  });

  final List<DocumentCoverage> documents;
  final int chunkCount;

  /// 仅抽取阶段预计请求数（归并可能另加，界面应显示预计范围）。
  final int estimatedExtractionRequests;

  final int estimatedTokens;
  final List<UnsplittableItem> unsplittable;
  final List<MaterialIssue> issues;

  int get totalSegments =>
      documents.fold(0, (sum, d) => sum + d.totalSegments);

  int get coveredSegments =>
      documents.fold(0, (sum, d) => sum + d.coveredSegments);

  List<String> get uncoveredSegmentIds => <String>[
        for (final d in documents) ...d.uncoveredSegmentIds,
      ];

  List<MaterialIssue> get criticalIssues =>
      issues.where((i) => i.critical).toList(growable: false);

  List<UnsplittableItem> get blockingUnsplittable =>
      unsplittable.where((u) => u.blocking).toList(growable: false);

  /// 覆盖完整 = 文档全片段覆盖 + 无缺页 + 无 critical issue + 无阻塞 unsplittable。
  bool get complete =>
      criticalIssues.isEmpty &&
      blockingUnsplittable.isEmpty &&
      uncoveredSegmentIds.isEmpty &&
      documents.every((d) => d.missingPages.isEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'documents': documents.map((d) => d.toJson()).toList(growable: false),
        'chunkCount': chunkCount,
        'estimatedExtractionRequests': estimatedExtractionRequests,
        'estimatedTokens': estimatedTokens,
        'unsplittable': unsplittable.map((u) => u.toJson()).toList(growable: false),
        'issues': issues.map((i) => i.toJson()).toList(growable: false),
        'complete': complete,
        'totalSegments': totalSegments,
        'coveredSegments': coveredSegments,
      };

  factory CoverageManifest.fromJson(Map<String, dynamic> j) => CoverageManifest(
        documents: ((j['documents'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DocumentCoverage.fromJson)
            .toList(growable: false),
        chunkCount: (j['chunkCount'] as num?)?.toInt() ?? 0,
        estimatedExtractionRequests:
            (j['estimatedExtractionRequests'] as num?)?.toInt() ?? 0,
        estimatedTokens: (j['estimatedTokens'] as num?)?.toInt() ?? 0,
        unsplittable: ((j['unsplittable'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(UnsplittableItem.fromJson)
            .toList(growable: false),
        issues: ((j['issues'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MaterialIssue.fromJson)
            .toList(growable: false),
      );
}

/// 分块结果：块 + 覆盖清单。
class ChunkPlan {
  const ChunkPlan({required this.chunks, required this.manifest});

  final List<MaterialChunk> chunks;
  final CoverageManifest manifest;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chunks': chunks.map((c) => c.toJson()).toList(growable: false),
        'manifest': manifest.toJson(),
      };

  factory ChunkPlan.fromJson(Map<String, dynamic> j) => ChunkPlan(
        chunks: ((j['chunks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MaterialChunk.fromJson)
            .toList(growable: false),
        manifest: CoverageManifest.fromJson(
            (j['manifest'] as Map<String, dynamic>?) ?? const <String, dynamic>{}),
      );
}

/// 结构优先的材料分块器。
class MaterialChunker {
  MaterialChunker({
    required this.limits,
    this.estimator = const TokenEstimator(),
  });

  final AnalysisLimits limits;
  final TokenEstimator estimator;

  /// 按结构分块。
  ///
  /// [maxChunkUtf8Bytes] 是单块正文可用的字节预算（调用方已从单请求上限里扣掉
  /// 固定信封）；[overlapUtf8Bytes] 默认取 [AnalysisLimits.overlapUtf8Bytes]。
  ChunkPlan build(
    List<SourceDocument> documents, {
    required int maxChunkUtf8Bytes,
    int? overlapUtf8Bytes,
  }) {
    final issues = <MaterialIssue>[];
    final unsplittable = <UnsplittableItem>[];
    final usableDocs = <SourceDocument>[];

    if (maxChunkUtf8Bytes < 256) {
      issues.add(const MaterialIssue(
        code: 'request_budget_too_small',
        message: '单请求可用字节过小（固定信封已占满预算），无法分块；'
            '请增大单请求上限或缩小时间表/已知任务等固定内容',
        critical: true,
      ));
      return ChunkPlan(
        chunks: const <MaterialChunk>[],
        manifest: CoverageManifest(
          documents: const <DocumentCoverage>[],
          chunkCount: 0,
          estimatedExtractionRequests: 0,
          estimatedTokens: 0,
          unsplittable: const <UnsplittableItem>[],
          issues: issues,
        ),
      );
    }

    var extractedBytes = 0;
    for (final doc in documents) {
      extractedBytes += doc.extractedUtf8Bytes;
      if (doc.sourceFileBytes > limits.maxSourceFileBytes) {
        issues.add(MaterialIssue(
          code: 'source_file_too_large',
          docHash: doc.docHash,
          critical: true,
          message: '「${doc.label}」原文件 ${doc.sourceFileBytes} 字节超过原文件上限 '
              '${limits.maxSourceFileBytes}；未截断处理，请拆分文件',
        ));
        continue;
      }
      if (doc.segments.isEmpty) {
        issues.add(MaterialIssue(
          code: 'empty_document',
          docHash: doc.docHash,
          critical: true,
          message: '「${doc.label}」没有可用文本片段',
        ));
        continue;
      }
      if (doc.isPaged && doc.pageCount > limits.local.maxPdfPages) {
        issues.add(MaterialIssue(
          code: 'too_many_pages',
          docHash: doc.docHash,
          critical: true,
          message: '「${doc.label}」共 ${doc.pageCount} 页，超过本地处理上限 '
              '${limits.local.maxPdfPages} 页；请选择页范围后重试',
        ));
        continue;
      }
      usableDocs.add(doc);
    }

    if (extractedBytes > limits.maxExtractedTextUtf8Bytes) {
      issues.add(MaterialIssue(
        code: 'extracted_text_too_large',
        critical: true,
        message: '全部材料提取文本共 $extractedBytes 字节，超过提取文本上限 '
            '${limits.maxExtractedTextUtf8Bytes}；未截断，请减少材料或拆分文件',
      ));
      return ChunkPlan(
        chunks: const <MaterialChunk>[],
        manifest: CoverageManifest(
          documents: <DocumentCoverage>[
            for (final doc in documents)
              _coverageFor(doc, const <ChunkSegmentSlice>[], const <int>[]),
          ],
          chunkCount: 0,
          estimatedExtractionRequests: 0,
          estimatedTokens: 0,
          unsplittable: const <UnsplittableItem>[],
          issues: issues,
        ),
      );
    }

    final overlap = overlapUtf8Bytes ?? limits.overlapUtf8Bytes;
    final chunks = <MaterialChunk>[];
    final slicesByDoc = <String, List<ChunkSegmentSlice>>{};
    for (final doc in usableDocs) {
      final blocks = <_Block>[];
      for (final segment in doc.segments) {
        final segmentBlocks = _splitIntoSegments(segment, maxChunkUtf8Bytes);
        for (final block in segmentBlocks.blocks) {
          blocks.add(block);
        }
        unsplittable.addAll(segmentBlocks.unsplittable);
      }
      final docChunks = _packDocument(
        doc,
        blocks,
        maxChunkUtf8Bytes: maxChunkUtf8Bytes,
        overlapUtf8Bytes: overlap,
      );
      chunks.addAll(docChunks);
      final slices = <ChunkSegmentSlice>[];
      for (final chunk in docChunks) {
        slices.addAll(chunk.segments.where((s) => !s.overlap));
      }
      slicesByDoc[doc.docHash] = slices;
    }

    // 覆盖清单：优先用“非重叠切片”计算区间并集，重叠只用于去重/上下文。
    final coverages = <DocumentCoverage>[];
    for (final doc in documents) {
      final slices = slicesByDoc[doc.docHash] ?? const <ChunkSegmentSlice>[];
      coverages.add(_coverageFor(doc, slices, const <int>[]));
    }

    // 无可用文档：没有块，但问题已记录，覆盖不完整。
    final tokenTotal = chunks.fold(0, (sum, c) => sum + c.estimatedTokens);
    return ChunkPlan(
      chunks: chunks,
      manifest: CoverageManifest(
        documents: coverages,
        chunkCount: chunks.length,
        estimatedExtractionRequests: chunks.length,
        estimatedTokens: tokenTotal,
        unsplittable: unsplittable,
        issues: issues,
      ),
    );
  }

  // ---------------------------------------------------------------- blocks

  _SplitResult _splitIntoSegments(
      SourceSegment segment, int maxChunkUtf8Bytes) {
    final blocks = _segmentBlocks(segment);
    final out = <_Block>[];
    final unsplittable = <UnsplittableItem>[];
    for (final block in blocks) {
      if (block.utf8Bytes <= maxChunkUtf8Bytes) {
        out.add(block);
        continue;
      }
      final split = _splitOversized(segment, block, maxChunkUtf8Bytes);
      out.addAll(split.blocks);
      unsplittable.addAll(split.unsplittable);
    }
    return _SplitResult(blocks: out, unsplittable: unsplittable);
  }

  /// 把一段文本按空行/标题/列表/表格行切成结构块。
  ///
  /// 标题行不单独成块：它会与紧随其后的段落/列表/表格行留在同一块，
  /// 避免“标题在上一块、内容在下一块”导致结构信息与任务/日期断开。
  List<_Block> _segmentBlocks(SourceSegment segment) {
    final text = segment.text;
    final blocks = <_Block>[];
    var paragraphStart = -1;
    var paragraphEnd = -1;
    var headingStart = -1;
    var headingEnd = -1;
    var lineStart = 0;
    var i = 0;

    void flushParagraph() {
      if (paragraphStart >= 0 && paragraphEnd > paragraphStart) {
        blocks.add(_Block(
          segment: segment,
          charStart: paragraphStart,
          charEnd: paragraphEnd,
        ));
      }
      paragraphStart = -1;
      paragraphEnd = -1;
    }

    void flushHeadingAlone() {
      if (headingStart >= 0 && headingEnd > headingStart) {
        blocks.add(_Block(
          segment: segment,
          charStart: headingStart,
          charEnd: headingEnd,
        ));
      }
      headingStart = -1;
      headingEnd = -1;
    }

    while (i <= text.length) {
      final atEnd = i == text.length;
      if (!atEnd && text.codeUnitAt(i) != 0x0A) {
        i++;
        continue;
      }
      final line = text.substring(lineStart, i);
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        flushParagraph();
        flushHeadingAlone();
      } else if (_isHeadingLine(trimmed)) {
        flushParagraph();
        flushHeadingAlone();
        headingStart = lineStart;
        headingEnd = lineStart + line.length;
      } else if (_isListOrTableLine(trimmed)) {
        flushParagraph();
        // 标题 + 紧随其后的列表/表格行同块；相邻列表行由 packer 连续放入同块。
        final start = headingStart >= 0 ? headingStart : lineStart;
        headingStart = -1;
        headingEnd = -1;
        blocks.add(_Block(
          segment: segment,
          charStart: start,
          charEnd: lineStart + line.length,
        ));
      } else {
        if (paragraphStart < 0) {
          paragraphStart = headingStart >= 0 ? headingStart : lineStart;
          headingStart = -1;
          headingEnd = -1;
        }
        paragraphEnd = lineStart + line.length;
      }
      lineStart = i + 1;
      i++;
    }
    flushParagraph();
    flushHeadingAlone();
    return blocks;
  }

  static final RegExp _headingPattern =
      RegExp(r'^(#{1,6}\s|第[一二三四五六七八九十百千0-9]+[章节篇部分]|'
          r'[一二三四五六七八九十]+、|附录|【[^】]{1,30}】$)');
  static final RegExp _listOrTablePattern =
      RegExp(r'^(\s*[-*•·]\s+|\s*\d+[.)、]\s+|\s*[（(]\d+[)）]|\s*\|.*\|)');
  static final RegExp _tableishPattern = RegExp(r'(\t.*\t|\S\s{2,}\S)');
  static final RegExp _datePattern = RegExp(
      r'(\d{4}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}\s*日?|'
      r'\d{1,2}\s*月\s*\d{1,2}\s*日|'
      r'(周一|周二|周三|周四|周五|周六|周日|星期一|星期二|星期三|星期四|星期五|星期六|星期日))');

  bool _isHeadingLine(String line) {
    if (line.length > 80) return false;
    return _headingPattern.hasMatch(line);
  }

  bool _isListOrTableLine(String line) {
    if (_listOrTablePattern.hasMatch(line)) return true;
    final tabs = '\t'.allMatches(line).length;
    if (tabs >= 2) return true;
    if (_tableishPattern.hasMatch(line) && line.contains('  ')) return true;
    return false;
  }

  bool _isDateOnlyBlock(_Block block) {
    final text = block.text.trim();
    if (text.length > 60) return false;
    if (!_datePattern.hasMatch(text)) return false;
    // 只含日期/星期的时间线行（不含大段任务描述）才需要跟随任务块。
    return !text.contains('。') || text.length <= 24;
  }

  _SplitResult _splitOversized(
      SourceSegment segment, _Block block, int maxBytes) {
    final text = block.text;
    final blocks = <_Block>[];
    final unsplittable = <UnsplittableItem>[];
    var start = 0;
    var hardSplit = false;
    while (start < text.length) {
      var end = _naturalSplitEnd(text, start, maxBytes);
      if (end <= start) {
        end = _hardSplitEnd(text, start, maxBytes);
        hardSplit = true;
      }
      if (end <= start) {
        // 兜底：至少前进一个 code unit，避免死循环（不会出现在正常预算下）。
        end = start + 1;
      }
      blocks.add(_Block(
        segment: segment,
        charStart: block.charStart + start,
        charEnd: block.charStart + end,
      ));
      start = end;
    }
    if (hardSplit) {
      unsplittable.add(UnsplittableItem(
        segmentId: segment.segmentId,
        page: segment.page,
        docHash: segment.docHash,
        reason: '单段在 $maxBytes 字节预算内没有可读断点，按字符边界硬拆；'
            '内容已完整拆入多个块，未截断',
      ));
    }
    return _SplitResult(blocks: blocks, unsplittable: unsplittable);
  }

  /// 在 [start, byte 预算] 内找自然断点（句子 > 分号 > 逗号/空白），返回断点后的
  /// 字符下标；找不到返回 -1（交给硬拆）。
  int _naturalSplitEnd(String text, int start, int maxBytes) {
    var bytes = 0;
    var scan = start;
    while (scan < text.length) {
      final rune = text.codeUnitAt(scan);
      final size = _utf8Size(rune, text, scan);
      if (bytes + size > maxBytes) break;
      bytes += size;
      scan += _codeUnitStep(rune, text, scan);
    }
    if (scan <= start) return -1;
    final minSplit = start + ((scan - start) ~/ 3);
    for (var i = scan - 1; i >= minSplit; i--) {
      final ch = text[i];
      if ('。！？；!?;\n'.contains(ch)) return i + 1;
    }
    for (var i = scan - 1; i >= minSplit; i--) {
      final ch = text[i];
      if ('，,、：: '.contains(ch)) return i + 1;
    }
    return -1;
  }

  int _hardSplitEnd(String text, int start, int maxBytes) {
    var bytes = 0;
    var scan = start;
    while (scan < text.length) {
      final rune = text.codeUnitAt(scan);
      final size = _utf8Size(rune, text, scan);
      if (bytes + size > maxBytes) break;
      bytes += size;
      scan += _codeUnitStep(rune, text, scan);
    }
    return scan;
  }

  static int _utf8Size(int firstUnit, String text, int index) {
    if (firstUnit < 0x80) return 1;
    if (firstUnit < 0x800) return 2;
    if (firstUnit >= 0xD800 && firstUnit <= 0xDBFF) return 4;
    return 3;
  }

  static int _codeUnitStep(int firstUnit, String text, int index) {
    if (firstUnit >= 0xD800 && firstUnit <= 0xDBFF) return 2;
    return 1;
  }

  // ------------------------------------------------------------- packing

  List<MaterialChunk> _packDocument(
    SourceDocument doc,
    List<_Block> blocks, {
    required int maxChunkUtf8Bytes,
    required int overlapUtf8Bytes,
  }) {
    final chunks = <MaterialChunk>[];
    var index = 0;
    var previousTail = <_Block>[];

    while (index < blocks.length) {
      final body = <_Block>[];
      var bodyBytes = 0;

      // 上一块尾部作为上下文重叠（带同一稳定片段 ID）。
      for (final block in previousTail) {
        final bytes = block.utf8Bytes;
        if (bodyBytes + bytes > maxChunkUtf8Bytes) break;
        body.add(block.asOverlap());
        bodyBytes += bytes;
      }

      var addedNew = 0;
      while (index < blocks.length) {
        final block = blocks[index];
        final bytes = block.utf8Bytes;
        if (bodyBytes + bytes > maxChunkUtf8Bytes && addedNew > 0) break;
        if (bodyBytes + bytes > maxChunkUtf8Bytes && addedNew == 0) {
          // 重叠上下文挤掉了正文首位：先丢掉重叠（它是可选的），再装正文。
          if (body.any((b) => b.overlap)) {
            bodyBytes = body
                .where((b) => !b.overlap)
                .fold(0, (sum, b) => sum + b.utf8Bytes);
            body.removeWhere((b) => b.overlap);
            continue;
          }
          // 单块本身超过预算（理论上已在细分阶段处理）：仍然装入并记录问题，
          // 不截断；运行期预算复核会显式失败而不是静默截尾。
          body.add(block);
          bodyBytes += bytes;
          index++;
          addedNew++;
          break;
        }
        body.add(block);
        bodyBytes += bytes;
        index++;
        addedNew++;
        if (bodyBytes >= maxChunkUtf8Bytes) break;
      }
      if (addedNew == 0 && body.isEmpty) {
        // 防御：不可能发生，跳过避免死循环。
        index++;
        continue;
      }

      // 纯日期行不要孤立在块尾：留到下一块与对应任务同块。
      if (addedNew >= 2 &&
          index < blocks.length &&
          body.isNotEmpty &&
          !body.last.overlap &&
          _isDateOnlyBlock(body.last)) {
        body.removeLast();
        index--;
      }

      final firstNew = body.where((b) => !b.overlap).toList(growable: false);
      if (firstNew.isEmpty) {
        // 只有重叠块：不再单独成块，交给下一轮。
        continue;
      }

      final chunk = _buildChunk(doc, body, chunks.length);
      chunks.add(chunk);

      previousTail = <_Block>[];
      var tailBytes = 0;
      for (var i = body.length - 1; i >= 0; i--) {
        final block = body[i];
        if (block.overlap) continue;
        if (tailBytes + block.utf8Bytes > overlapUtf8Bytes) break;
        tailBytes += block.utf8Bytes;
        previousTail.insert(0, block);
      }
    }
    return chunks;
  }

  MaterialChunk _buildChunk(SourceDocument doc, List<_Block> blocks, int ordinal) {
    final slices = <ChunkSegmentSlice>[
      for (final block in blocks)
        ChunkSegmentSlice(
          segmentId: block.segment.segmentId,
          page: block.segment.page,
          index: block.segment.index,
          text: block.text,
          charStart: block.charStart,
          charEnd: block.charEnd,
          overlap: block.overlap,
          fromOcr: block.segment.fromOcr,
        ),
    ];
    final text = slices.map((s) => s.text).join('\n');
    final segmentIds = <String>[];
    for (final slice in slices) {
      if (!segmentIds.contains(slice.segmentId)) segmentIds.add(slice.segmentId);
    }
    final firstNew = slices.firstWhere((s) => !s.overlap, orElse: () => slices.first);
    final pageNumbers = <int>[
      for (final s in slices)
        if (s.page > 0) s.page,
    ];
    final firstPage = pageNumbers.isEmpty
        ? 0
        : pageNumbers.reduce((a, b) => a < b ? a : b);
    final lastPage =
        pageNumbers.isEmpty ? 0 : pageNumbers.reduce((a, b) => a > b ? a : b);
    final bytes = utf8.encode(text).length;
    return MaterialChunk(
      chunkId: 'chunk:${doc.docHash}:$ordinal:${firstNew.charStart}',
      docHash: doc.docHash,
      firstPage: firstPage,
      lastPage: lastPage,
      segments: slices,
      text: text,
      segmentIds: segmentIds,
      hasOverlap: slices.any((s) => s.overlap),
      utf8Bytes: bytes,
      estimatedTokens: estimator.estimate(text),
    );
  }

  DocumentCoverage _coverageFor(
    SourceDocument doc,
    List<ChunkSegmentSlice> slices,
    List<int> extraMissingPages,
  ) {
    final ranges = <String, List<_Range>>{};
    final pages = <int>{};
    for (final slice in slices) {
      pages.add(slice.page);
      final list = ranges.putIfAbsent(slice.segmentId, () => <_Range>[]);
      list.add(_Range(slice.charStart, slice.charEnd));
    }
    final covered = <String>[];
    final uncovered = <String>[];
    for (final segment in doc.segments) {
      final list = ranges[segment.segmentId];
      if (list == null || list.isEmpty) {
        uncovered.add(segment.segmentId);
        continue;
      }
      list.sort((a, b) => a.start.compareTo(b.start));
      var cursor = 0;
      var ok = true;
      for (final range in list) {
        if (range.start > cursor) {
          // 块之间可能夹着换行/空白：空白不是信息丢失，但任何非空白缺口都算漏字。
          final gap = segment.text.substring(cursor, range.start);
          if (gap.trim().isNotEmpty) {
            ok = false;
            break;
          }
        }
        if (range.end > cursor) cursor = range.end;
      }
      if (cursor < segment.text.length &&
          segment.text.substring(cursor).trim().isNotEmpty) {
        ok = false;
      }
      if (ok) {
        covered.add(segment.segmentId);
      } else {
        uncovered.add(segment.segmentId);
      }
    }
    final totalPages = doc.pageCount;
    final coveredPageNumbers = pages.where((p) => p > 0).toList()..sort();
    final missingPages = <int>[
      if (totalPages > 0)
        for (var p = 1; p <= totalPages; p++)
          if (!coveredPageNumbers.contains(p)) p,
      ...extraMissingPages,
    ];
    return DocumentCoverage(
      docHash: doc.docHash,
      label: doc.label,
      kind: doc.kind,
      totalPages: totalPages,
      coveredPages: coveredPageNumbers,
      totalSegments: doc.segments.length,
      coveredSegments: covered.length,
      uncoveredSegmentIds: uncovered,
      missingPages: missingPages,
      fromOcr: doc.fromOcr,
    );
  }
}

class _Block {
  _Block({
    required this.segment,
    required this.charStart,
    required this.charEnd,
    this.overlap = false,
  });

  final SourceSegment segment;
  final int charStart;
  final int charEnd;
  final bool overlap;

  String get text => segment.text.substring(charStart, charEnd);

  int get utf8Bytes => utf8.encode(text).length;

  _Block asOverlap() => _Block(
        segment: segment,
        charStart: charStart,
        charEnd: charEnd,
        overlap: true,
      );
}

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}

class _SplitResult {
  const _SplitResult({required this.blocks, required this.unsplittable});
  final List<_Block> blocks;
  final List<UnsplittableItem> unsplittable;
}
