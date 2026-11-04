// OCR text → material fragment: normalisation, provenance, review and
// confirmation markers.
//
// Rules that matter for correctness:
//   * Normalisation is conservative: it removes spaces the OCR engine inserts
//     between Chinese characters / digits and repairs obvious separator
//     confusions, but it never deletes negation words, time symbols, units,
//     identifiers or Chinese colons. Nothing is silently "corrected" to a value
//     the engine did not produce — uncertain date/time/duration/number fields are
//     flagged for user confirmation instead.
//   * Windows.Media.Ocr exposes no per-word confidence, so every flagged field
//     is "needs confirmation"; when another engine does provide scores, a low
//     score is flagged too. No invented confidence number is shown.
//   * The user's reviewed text is stored separately from the OCR original. A
//     re-run replaces the original only; reviewed text and review history stay,
//     and a diff shows what changed.
//   * Each page carries an [OcrSourceRef] (document hash, page, rendered size,
//     DPI, engine+version, method, optionally a bbox), so material provenance
//     survives copying/analysis.

import 'dart:convert';

import 'ocr_types.dart';

/// Confidence below which a field is flagged (only when the engine reports
/// confidence at all; the Windows engine does not).
const double ocrLowConfidenceThreshold = 0.6;

/// Kind of a field that should be confirmed before it becomes a schedule
/// constraint.
enum OcrFlagKind { date, time, duration, number, identifier }

extension OcrFlagKindInfo on OcrFlagKind {
  String get label => switch (this) {
        OcrFlagKind.date => '日期',
        OcrFlagKind.time => '时刻',
        OcrFlagKind.duration => '工时/时长',
        OcrFlagKind.number => '数字',
        OcrFlagKind.identifier => '编号',
      };

  String get wire => name;

  static OcrFlagKind fromWire(String raw) {
    for (final kind in OcrFlagKind.values) {
      if (kind.wire == raw) return kind;
    }
    return OcrFlagKind.number;
  }
}

/// One OCR-derived field that must be confirmed by the user.
class OcrFlaggedField {
  const OcrFlaggedField({
    required this.kind,
    required this.text,
    required this.page,
    required this.lineIndex,
    required this.reason,
    this.bbox,
    this.engineConfidence,
  });

  final OcrFlagKind kind;

  /// Matched text after comparison normalisation (ASCII-ish, for display).
  final String text;

  final int page;
  final int lineIndex;

  /// Why this field needs confirmation (engine has no confidence / low score).
  final String reason;

  final OcrRect? bbox;

  /// Engine confidence when the engine provides it (Windows OCR: null).
  final double? engineConfidence;

  bool get needsConfirmation => true;

  String get locationLabel => '第 $page 页';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.wire,
        'text': text,
        'page': page,
        'lineIndex': lineIndex,
        'reason': reason,
        if (bbox != null) 'bbox': bbox!.toMap(),
        if (engineConfidence != null) 'engineConfidence': engineConfidence,
      };

  static OcrFlaggedField? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final page = (map['page'] as num?)?.toInt();
    final lineIndex = (map['lineIndex'] as num?)?.toInt();
    final text = map['text'];
    if (page == null || lineIndex == null || text is! String) return null;
    return OcrFlaggedField(
      kind: OcrFlagKindInfo.fromWire((map['kind'] as String?) ?? 'number'),
      text: text,
      page: page,
      lineIndex: lineIndex,
      reason: (map['reason'] as String?) ?? '',
      bbox: OcrRect.fromMap(map['bbox']),
      engineConfidence: (map['engineConfidence'] as num?)?.toDouble(),
    );
  }
}

/// One version of the user's review text.
class OcrReviewEntry {
  const OcrReviewEntry({required this.text, required this.reviewedAt});

  final String text;
  final DateTime reviewedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'reviewedAt': reviewedAt.toUtc().toIso8601String(),
      };

  static OcrReviewEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final text = map['text'];
    if (text is! String) return null;
    final at = DateTime.tryParse((map['reviewedAt'] as String?) ?? '');
    if (at == null) return null;
    return OcrReviewEntry(text: text, reviewedAt: at.toUtc());
  }
}

/// One page of OCR material: original recognition + optional user review.
class OcrMaterialPage {
  OcrMaterialPage({
    required this.page,
    required this.originalText,
    required this.result,
    this.reviewedText,
    this.reviewedAt,
    this.previousOriginalText,
    this.reviewHistory = const <OcrReviewEntry>[],
  });

  final int page;

  /// OCR text after conservative normalisation. Never overwritten by a review.
  final String originalText;

  /// Engine output (raw text + line boxes) retained for provenance/debugging.
  final OcrPageResult result;

  /// User-corrected text, or `null` when the user has not reviewed this page.
  final String? reviewedText;

  final DateTime? reviewedAt;

  /// Original text from the *previous* recognition, when a re-run changed it.
  /// Used to show what the new recognition changed.
  final String? previousOriginalText;

  /// Previous review texts (oldest first), capped.
  final List<OcrReviewEntry> reviewHistory;

  bool get isReviewed => reviewedText != null;

  /// What should be used downstream: reviewed text wins over OCR original.
  String get effectiveText => reviewedText ?? originalText;

  /// True when a re-run produced different original text than what was shown.
  bool get changedByRerun =>
      previousOriginalText != null && previousOriginalText != originalText;

  /// Review state is preserved across re-recognition by construction.
  OcrMaterialPage applyReview(String text, {DateTime? at}) {
    final trimmed = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trimRight();
    final stamp = (at ?? DateTime.now()).toUtc();
    if (trimmed.trim().isEmpty) {
      return OcrMaterialPage(
        page: page,
        originalText: originalText,
        result: result,
        reviewedText: null,
        reviewedAt: null,
        previousOriginalText: previousOriginalText,
        reviewHistory: reviewHistory,
      );
    }
    final history = <OcrReviewEntry>[
      ...reviewHistory,
      OcrReviewEntry(text: trimmed, reviewedAt: stamp),
    ];
    if (history.length > 5) history.removeRange(0, history.length - 5);
    return OcrMaterialPage(
      page: page,
      originalText: originalText,
      result: result,
      reviewedText: trimmed,
      reviewedAt: stamp,
      previousOriginalText: previousOriginalText,
      reviewHistory: List<OcrReviewEntry>.unmodifiable(history),
    );
  }

  /// Replaces the OCR original from a new recognition run while preserving the
  /// user's review and its history.
  OcrMaterialPage withRerun(OcrPageResult newResult) {
    final nextOriginal = normaliseOcrText(newResult.text);
    return OcrMaterialPage(
      page: page,
      originalText: nextOriginal,
      result: newResult,
      reviewedText: reviewedText,
      reviewedAt: reviewedAt,
      previousOriginalText: originalText,
      reviewHistory: reviewHistory,
    );
  }

  OcrSourceRef sourceRef(String documentSha256) => OcrSourceRef(
        documentSha256: documentSha256,
        page: page,
        width: result.width,
        height: result.height,
        dpi: result.dpi,
        engine: result.engine,
        engineVersion: result.engineVersion,
        language: result.language,
        method: result.method,
      );

  /// Line-level diff summary between OCR original and user review.
  /// Returns `null` when the page has not been reviewed.
  String? reviewDiff() {
    final review = reviewedText;
    if (review == null) return null;
    final before = _linesOf(originalText);
    final after = _linesOf(review);
    final added = after.where((line) => !before.contains(line)).length;
    final removed = before.where((line) => !after.contains(line)).length;
    if (added == 0 && removed == 0) return '与识别原文一致';
    return '人工校对：新增/修改 $added 行，删除 $removed 行';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page': page,
        'originalText': originalText,
        'result': result.toJson(),
        if (previousOriginalText != null) 'previousOriginalText': previousOriginalText,
        if (reviewedText != null) 'reviewedText': reviewedText,
        if (reviewedAt != null) 'reviewedAt': reviewedAt!.toUtc().toIso8601String(),
        if (reviewHistory.isNotEmpty)
          'reviewHistory': reviewHistory.map((entry) => entry.toJson()).toList(growable: false),
      };

  static OcrMaterialPage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final page = (map['page'] as num?)?.toInt();
    final originalText = map['originalText'];
    final result = OcrPageResult.fromJson(map['result']);
    if (page == null || page < 1 || originalText is! String || result == null) {
      return null;
    }
    final history = <OcrReviewEntry>[];
    final rawHistory = map['reviewHistory'];
    if (rawHistory is List) {
      for (final item in rawHistory) {
        final entry = OcrReviewEntry.fromJson(item);
        if (entry != null) history.add(entry);
      }
    }
    return OcrMaterialPage(
      page: page,
      originalText: originalText,
      result: result,
      reviewedText: map['reviewedText'] as String?,
      reviewedAt: DateTime.tryParse((map['reviewedAt'] as String?) ?? '')?.toUtc(),
      previousOriginalText: map['previousOriginalText'] as String?,
      reviewHistory: List<OcrReviewEntry>.unmodifiable(history),
    );
  }
}

/// A complete OCR material fragment for one document.
class OcrMaterial {
  OcrMaterial({
    required this.documentSha256,
    required this.fileLabel,
    required this.kind,
    required List<OcrMaterialPage> pages,
    this.engine = '',
    this.engineVersion = '',
    this.languages = const <String>[],
    this.dpi = 0,
    required this.createdAt,
    this.warning,
    this.lastRerunAt,
    this.rerunFailurePages = const <int>[],
  })  : pages = List<OcrMaterialPage>.unmodifiable(
          (pages.toList(growable: false)..sort((a, b) => a.page.compareTo(b.page))),
        );

  /// Builds material from a finished job. Pages without a result (failures,
  /// cancelled pages) are simply absent; the caller must show the failure list,
  /// never present this as complete.
  factory OcrMaterial.fromJob({
    required OcrJobResult job,
    required String fileLabel,
    String? documentSha256,
    DateTime? createdAt,
    String? warning,
  }) {
    final sha = documentSha256 ?? job.sourceSha256 ?? '';
    final pages = <OcrMaterialPage>[
      for (final result in job.results)
        OcrMaterialPage(
          page: result.page,
          originalText: normaliseOcrText(result.text),
          result: result,
        ),
    ];
    return OcrMaterial(
      documentSha256: sha,
      fileLabel: fileLabel,
      kind: OcrSourceKind.fromPath(job.sourcePath),
      pages: pages,
      engine: job.engine,
      engineVersion: job.engineVersion,
      languages: job.languages,
      dpi: job.dpi,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
      warning: warning ?? job.warning,
    );
  }

  /// Lower-case hex SHA-256 of the source document bytes ('' when unknown).
  final String documentSha256;

  /// File name only (never a full path): safe to store in the material.
  final String fileLabel;

  final OcrSourceKind kind;
  final List<OcrMaterialPage> pages;

  final String engine;
  final String engineVersion;
  final List<String> languages;
  final int dpi;
  final DateTime createdAt;
  final String? warning;
  final DateTime? lastRerunAt;

  /// Pages that failed in the most recent re-run. They keep their previous text;
  /// this list exists so the UI never hides a partially failed re-recognition.
  final List<int> rerunFailurePages;

  bool get isEmpty => pages.isEmpty;
  int get pageCount => pages.length;

  int get reviewedPageCount => pages.where((page) => page.isReviewed).length;

  int get unreviewedPageCount => pages.where((page) => !page.isReviewed).length;

  bool get allReviewed => pages.isNotEmpty && unreviewedPageCount == 0;

  /// Material text in page order: used by the attachment/composer layer.
  String get text => pages.map(_pageBlock).join('\n\n');

  String _pageBlock(OcrMaterialPage page) {
    final marker = page.isReviewed ? '【第 ${page.page} 页 · 本地 OCR · 已人工校对】' : '【第 ${page.page} 页 · 本地 OCR】';
    return '$marker\n${page.effectiveText}';
  }

  /// Text with an explicit provenance footer, for "add to material" flows.
  String toAttachmentText() {
    final header = '【OCR 材料：$fileLabel，共 ${pages.length} 页，本地离线识别】';
    final footer = '（以上文字由本地 OCR 引擎 $engineVersion 生成，'
        '来源为第 ${pages.map((page) => page.page).join('、')} 页；'
        '日期、时刻、工时与编号请以人工校对结果为准。）';
    return '$header\n\n$text\n\n$footer';
  }

  /// Every OCR-derived value that must be confirmed before it constrains a plan.
  List<OcrFlaggedField> get flaggedFields => <OcrFlaggedField>[
        for (final page in pages) ..._flaggedFieldsOfPage(page),
      ];

  int get flaggedFieldCount => flaggedFields.length;

  bool get hasFlaggedFields => flaggedFieldCount > 0;

  /// True when at least one page looks like a multi-column/complex layout where
  /// reading order is not reliable.
  bool get layoutComplex => pages.any((page) => detectComplexLayout(page.result));

  /// The user must look at the material when pages are unreviewed, fields are
  /// flagged or the layout is complex.
  bool get needsUserReview =>
      unreviewedPageCount > 0 || hasFlaggedFields || layoutComplex;

  /// Short user-facing note explaining why review matters.
  String? get reviewHint {
    if (pages.isEmpty) return null;
    final parts = <String>[];
    if (unreviewedPageCount > 0) {
      parts.add('$unreviewedPageCount 页尚未人工校对');
    }
    if (hasFlaggedFields) {
      parts.add('$flaggedFieldCount 个日期/时刻/工时/编号字段需确认');
    }
    if (layoutComplex) {
      parts.add('检测到多栏/复杂布局，阅读顺序需人工确认');
    }
    return parts.isEmpty ? null : parts.join('；');
  }

  /// Applies a user review to one page (returns a new immutable material).
  OcrMaterial applyReview(int page, String text, {DateTime? at}) => _withPages(<OcrMaterialPage>[
        for (final entry in pages)
          entry.page == page ? entry.applyReview(text, at: at) : entry,
      ]);

  /// Merges a re-recognition result:
  ///   * original OCR text/lines are replaced for pages present in [job],
  ///   * user review and review history are preserved,
  ///   * pages that failed in the re-run keep their previous text (they are
  ///     reported through [rerunFailures] instead of silently disappearing).
  OcrMaterial rerun(OcrJobResult job, {DateTime? at}) {
    final jobSha = job.sourceSha256 ?? '';
    if (documentSha256.isNotEmpty && jobSha.isNotEmpty && jobSha != documentSha256) {
      throw ArgumentError('不能把另一份文档的识别结果合并进现有材料。');
    }
    final fresh = <int, OcrPageResult>{
      for (final result in job.results) result.page: result,
    };
    final updated = <OcrMaterialPage>[
      for (final existing in pages)
        fresh.containsKey(existing.page)
            ? existing.withRerun(fresh[existing.page]!)
            : existing,
      for (final entry in fresh.entries)
        if (!pages.any((page) => page.page == entry.key))
          OcrMaterialPage(
            page: entry.key,
            originalText: normaliseOcrText(entry.value.text),
            result: entry.value,
          ),
    ];
    return OcrMaterial(
      documentSha256: documentSha256,
      fileLabel: fileLabel,
      kind: kind,
      pages: updated,
      engine: job.engine.isNotEmpty ? job.engine : engine,
      engineVersion: job.engineVersion.isNotEmpty ? job.engineVersion : engineVersion,
      languages: job.languages.isNotEmpty ? job.languages : languages,
      dpi: job.dpi > 0 ? job.dpi : dpi,
      createdAt: createdAt,
      warning: job.warning,
      lastRerunAt: (at ?? DateTime.now()).toUtc(),
      rerunFailurePages: <int>[
        for (final failure in job.failures)
          if (!job.results.any((result) => result.page == failure.page)) failure.page,
      ],
    );
  }

  /// Pages that failed in the most recent re-run (empty when never re-run).
  List<int> get rerunFailures => rerunFailurePages;

  /// Review diff per page, keyed by page number (only reviewed pages).
  Map<int, String> get reviewDiffs => <int, String>{
        for (final page in pages)
          if (page.reviewDiff() != null) page.page: page.reviewDiff()!,
      };

  OcrMaterial _withPages(List<OcrMaterialPage> next) => OcrMaterial(
        documentSha256: documentSha256,
        fileLabel: fileLabel,
        kind: kind,
        pages: next,
        engine: engine,
        engineVersion: engineVersion,
        languages: languages,
        dpi: dpi,
        createdAt: createdAt,
        warning: warning,
        lastRerunAt: lastRerunAt,
        rerunFailurePages: rerunFailurePages,
      );

  /// Serialises the material (no API keys, no source file contents beyond OCR
  /// text; `documentSha256` is a hash).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': 1,
        'documentSha256': documentSha256,
        'fileLabel': fileLabel,
        'kind': kind.wire,
        'engine': engine,
        'engineVersion': engineVersion,
        'languages': languages,
        'dpi': dpi,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (warning != null) 'warning': warning,
        if (lastRerunAt != null) 'lastRerunAt': lastRerunAt!.toUtc().toIso8601String(),
        if (rerunFailurePages.isNotEmpty) 'rerunFailurePages': rerunFailurePages,
        'pages': pages.map((page) => page.toJson()).toList(growable: false),
      };

  String toJsonString() => jsonEncode(toJson());

  static OcrMaterial? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final fileLabel = map['fileLabel'];
    if (fileLabel is! String) return null;
    final pages = <OcrMaterialPage>[];
    final rawPages = map['pages'];
    if (rawPages is List) {
      for (final item in rawPages) {
        final page = OcrMaterialPage.fromJson(item);
        if (page != null) pages.add(page);
      }
    }
    if (pages.isEmpty) return null;
    final createdAt = DateTime.tryParse((map['createdAt'] as String?) ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return OcrMaterial(
      documentSha256: (map['documentSha256'] as String?) ?? '',
      fileLabel: fileLabel,
      kind: OcrSourceKind.values.firstWhere(
        (value) => value.wire == (map['kind'] as String?),
        orElse: () => OcrSourceKind.pdf,
      ),
      pages: pages,
      engine: (map['engine'] as String?) ?? '',
      engineVersion: (map['engineVersion'] as String?) ?? '',
      languages: <String>[
        for (final tag in (map['languages'] as List<dynamic>? ?? const <dynamic>[]))
          if (tag is String) tag,
      ],
      dpi: (map['dpi'] as num?)?.toInt() ?? 0,
      createdAt: createdAt,
      warning: map['warning'] as String?,
      lastRerunAt: DateTime.tryParse((map['lastRerunAt'] as String?) ?? '')?.toUtc(),
      rerunFailurePages: <int>[
        for (final page in (map['rerunFailurePages'] as List<dynamic>? ?? const <dynamic>[]))
          if (page is num) page.toInt(),
      ],
    );
  }

  static OcrMaterial? fromJsonString(String raw) {
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

/// Conservative OCR text normalisation.
///
/// What it does:
///   * normalises line endings and strips control/zero-width characters,
///   * removes spaces the OCR engine inserts between Chinese characters and
///     between digits (e.g. "2026 年 1 1 月" → "2026年11月"),
///   * collapses runs of spaces on English lines,
///   * repairs obvious separator confusions (`一`/`·` used as `-` in IDs and
///     dates, `．` used as `.` in decimals/dates),
///   * joins a hyphenated word split across lines.
///
/// What it deliberately does NOT do:
///   * no punctuation deletion — negation words (不/没有/未/不能/除外), units
///     (小时/分钟/元/人), numbering and Chinese colons (：) are preserved,
///   * no digit/ID "correction", no lowercase folding, no date interpretation.
String normaliseOcrText(String raw) {
  final cleaned = raw.replaceAll(
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B-\u200D\uFEFF]'),
    '',
  );
  final rawLines = cleaned
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final joined = _joinHyphenatedLines(rawLines);
  final out = <String>[];
  var blankRun = 0;
  for (final line in joined) {
    final normalised = _normaliseLine(line);
    if (normalised.isEmpty) {
      blankRun++;
      if (blankRun > 1) continue;
      out.add('');
    } else {
      blankRun = 0;
      out.add(normalised);
    }
  }
  return out.join('\n').trim();
}

List<String> _joinHyphenatedLines(List<String> lines) {
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (i + 1 < lines.length && line.endsWith('-')) {
      final next = lines[i + 1].trimLeft();
      if (next.isNotEmpty && RegExp(r'^[a-z]').hasMatch(next)) {
        line = '${line.substring(0, line.length - 1)}${next.trim()}';
        i++;
      }
    }
    out.add(line);
  }
  return out;
}

String _normaliseLine(String rawLine) {
  var line = rawLine.replaceFirst(RegExp(r'^[ \t\u3000]+'), '');
  line = line.replaceAll(RegExp(r'[ \t\u3000]+$'), '');
  if (line.isEmpty) return '';
  final hasCjk = _cjkPattern.hasMatch(line);
  if (hasCjk) {
    // OCR inserts spaces between Chinese glyphs and around digits.
    line = line.replaceAll(_cjkSpaceCjk, '');
    line = line.replaceAll(_cjkSpaceAlnum, '');
    line = line.replaceAll(_alnumSpaceCjk, '');
    line = line.replaceAll(_spaceAroundFullWidth, '');
    line = line.replaceAll(_cjkFullWidthSpaces, '');
  }
  // Join digit runs split by OCR ("1 1 月" -> "11 月") for every script; this is
  // needed for dates even on otherwise English lines.
  line = line.replaceAll(_digitSpaceDigit, '');
  line = line.replaceAll(_multiSpace, ' ');
  line = line.replaceAll(_dashConfusion, '-');
  line = line.replaceAllMapped(_dotConfusion, _dotReplacement);
  return line;
}

final RegExp _cjkPattern = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');
final RegExp _cjkSpaceCjk =
    RegExp(r'(?<=[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF])[ \t]+(?=[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF])');
final RegExp _cjkSpaceAlnum =
    RegExp(r'(?<=[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF])[ \t]+(?=[0-9A-Za-z])');
final RegExp _alnumSpaceCjk =
    RegExp(r'(?<=[0-9A-Za-z])[ \t]+(?=[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF])');
final RegExp _digitSpaceDigit = RegExp(r'(?<=[0-9])[ \t]+(?=[0-9])');
final RegExp _spaceAroundFullWidth =
    RegExp(r'[ \t]+(?=[：；，。、！？（）【】《》“”‘’])|(?<=[：；，。、！？（）【】《》“”‘’])[ \t]+');
final RegExp _cjkFullWidthSpaces = RegExp(r'[\u3000]+');
final RegExp _multiSpace = RegExp(r'[ \t]{2,}');
final RegExp _dashConfusion = RegExp(r'(?<=[0-9A-Za-z])[ \t]*[一－–—][ \t]*(?=[0-9A-Za-z])');
final RegExp _dotConfusion = RegExp(r'(?<=[0-9])[ \t]*[·•．，][ \t]*(?=[0-9])');

String _dotReplacement(Match match) {
  final before = match.input.substring(0, match.start);
  final after = match.input.substring(match.end);
  final separator = match.group(0)!.trim();
  final leftRun = RegExp(r'\d+$').firstMatch(before.trimRight())?.group(0) ?? '';
  final trimmedAfter = after.trimLeft();
  final rightRun = RegExp(r'^\d+').firstMatch(trimmedAfter)?.group(0) ?? '';
  // A unit immediately after the right digit run means a quantity ("2，5小时").
  final rest = trimmedAfter.replaceFirst(RegExp(r'^\d+'), '');
  final unitAfter = RegExp(r'^\s*(小\s*时|分钟|小时|分|个|元|人|页|天|周|月|年|h|hours?)')
      .firstMatch(rest);
  // A Chinese comma between two digits is ambiguous (list separator vs decimal
  // separator): only repair it when a unit follows, otherwise keep it.
  if (separator == '，' && unitAfter == null) return '，';
  // 4-digit group on the left is a year -> date separator.
  if (leftRun.length == 4 || rightRun.length == 4) return '-';
  if (leftRun.length <= 2 && rightRun.length <= 2 && unitAfter != null) return '.';
  // Another part of the same line already looks like a year -> date separator.
  if (RegExp(r'\d{4}').hasMatch(before)) return '-';
  return '.';
}

/// Comparison form used for field detection and tests.
///
/// Applies full-width→ASCII folding, case folding, whitespace removal and the
/// same separator repair as [normaliseOcrText]. This is *only* for matching; the
/// material keeps [normaliseOcrText] text.
String ocrComparableText(String raw) {
  final halfWidth = _foldFullWidth(normaliseOcrText(raw));
  var text = halfWidth.toLowerCase();
  text = text.replaceAll(RegExp(r'\s+'), '');
  text = text.replaceAll('：', ':').replaceAll('；', ';').replaceAll('，', ',');
  text = text.replaceAll(RegExp(r'[一－–—]'), '-');
  return text;
}

String _foldFullWidth(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Field detection
// ---------------------------------------------------------------------------

class _FieldPattern {
  const _FieldPattern(this.kind, this.pattern);

  final OcrFlagKind kind;
  final RegExp pattern;
}

final List<_FieldPattern> _fieldPatterns = <_FieldPattern>[
  _FieldPattern(
    OcrFlagKind.date,
    RegExp(r'\d{4}[-/.]\d{1,2}[-/.]\d{1,2}'),
  ),
  _FieldPattern(
    OcrFlagKind.date,
    RegExp(r'\d{4}年\d{1,2}月(\d{1,2}日)?'),
  ),
  _FieldPattern(OcrFlagKind.date, RegExp(r'\d{1,2}月\d{1,2}日')),
  _FieldPattern(
    OcrFlagKind.time,
    RegExp(r'\d{1,2}:\d{2}(:\d{2})?'),
  ),
  _FieldPattern(
    OcrFlagKind.time,
    RegExp(r'(上午|下午|中午|晚上|凌晨|早上)?\d{1,2}点(\d{1,2}分)?'),
  ),
  _FieldPattern(
    OcrFlagKind.duration,
    RegExp(r'\d+(\.\d+)?(个)?(小时|钟头|分钟|工作日|天|周|h|hr|hours?)'),
  ),
  _FieldPattern(
    OcrFlagKind.duration,
    RegExp(r'(半|一|两|三)个?(小时|天|工作日)'),
  ),
  _FieldPattern(
    OcrFlagKind.identifier,
    RegExp(r'[a-z]{2,}[-_]?\d{2,}[-_a-z0-9]*'),
  ),
  _FieldPattern(
    OcrFlagKind.identifier,
    RegExp(r'(编号|单号|合同号|订单号|工单号|ref|no\.?)[:]?[a-z0-9-]{2,}'),
  ),
  _FieldPattern(OcrFlagKind.number, RegExp(r'\d+(\.\d+)?')),
];

List<OcrFlaggedField> _flaggedFieldsOfPage(OcrMaterialPage page) {
  final flags = <OcrFlaggedField>[];
  final lines = page.result.lines;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final comparable = ocrComparableText(line.text);
    if (comparable.isEmpty) continue;
    final spans = <({int start, int end, OcrFlagKind kind, String text, String reason})>[];
    for (final pattern in _fieldPatterns) {
      for (final match in pattern.pattern.allMatches(comparable)) {
        if (match.end <= match.start) continue;
        final covered = spans.any((span) =>
            match.start >= span.start && match.end <= span.end);
        if (covered) continue;
        final confidence = line.confidence;
        final reason = confidence == null
            ? '本地 OCR 引擎不提供逐词置信度，${pattern.kind.label}需人工确认'
            : confidence < ocrLowConfidenceThreshold
                ? '引擎置信度 ${(confidence * 100).toStringAsFixed(0)}% 较低，需人工确认'
                : '${pattern.kind.label}来自 OCR，建议确认';
        spans.add((
          start: match.start,
          end: match.end,
          kind: pattern.kind,
          text: match.group(0) ?? '',
          reason: reason,
        ));
      }
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    for (final span in spans) {
      flags.add(OcrFlaggedField(
        kind: span.kind,
        text: span.text,
        page: page.page,
        lineIndex: index,
        reason: span.reason,
        bbox: line.bbox,
        engineConfidence: line.confidence,
      ));
    }
  }
  // Keep the UI readable: one flag per identical (page, kind, text) tuple.
  final seen = <String>{};
  final deduped = <OcrFlaggedField>[];
  for (final flag in flags) {
    if (seen.add('${flag.page}|${flag.kind.wire}|${flag.text}')) deduped.add(flag);
  }
  return deduped;
}

/// Heuristic: does this page look multi-column (reading order unreliable)?
///
/// Only used to *ask the user to review*; it never reorders text silently.
bool detectComplexLayout(OcrPageResult result) {
  final lines = result.lines.where((line) => line.bbox != null && !line.bbox!.isEmpty).toList();
  if (lines.length < 6 || result.width <= 0) return false;
  final pageWidth = result.width.toDouble();
  for (var i = 0; i < lines.length; i++) {
    final a = lines[i].bbox!;
    for (var j = i + 1; j < lines.length; j++) {
      final b = lines[j].bbox!;
      final overlapTop = a.y > b.y ? a.y : b.y;
      final overlapBottom =
          (a.y + a.height) < (b.y + b.height) ? (a.y + a.height) : (b.y + b.height);
      final overlap = overlapBottom - overlapTop;
      if (overlap <= 0) continue;
      final minHeight = a.height < b.height ? a.height : b.height;
      if (minHeight <= 0 || overlap / minHeight < 0.5) continue;
      final centerA = a.x + a.width / 2;
      final centerB = b.x + b.width / 2;
      if ((centerA - centerB).abs() > pageWidth * 0.25) return true;
    }
  }
  return false;
}

List<String> _linesOf(String text) {
  final lines = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    lines.add(trimmed);
  }
  return lines;
}
