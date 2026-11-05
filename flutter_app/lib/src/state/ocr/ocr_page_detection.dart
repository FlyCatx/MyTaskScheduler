// Page-level OCR planning for the R3-O feature.
//
// "Which pages actually need OCR?" is answered from the *existing* PDF text
// extractor (document_extractors/pdf_document_extractor.dart via
// extractDocument), not from OCR itself:
//   * pages with a sufficient, clean text layer are skipped (no duplicate text),
//   * pages with no text layer (a scan) are marked,
//   * pages whose text layer is suspiciously short (often just a page number)
//     or garbled are marked with an explanation,
//   * in a mixed document the user sees exactly which pages are scans.
//
// Detection is advisory: the caller can force pages into OCR or exclude them.
// Every decision carries a machine reason plus a Chinese explanation, so the
// dialog can show *why* a page was selected.

import 'dart:io';

import '../document_extractor.dart';
import 'ocr_client.dart';
import 'ocr_types.dart';

/// Why a page does or does not need OCR.
enum OcrPageReason {
  /// Image input: there is no text layer at all (single page).
  imageSource,

  /// PDF page has no extractable text (typical scan).
  noTextLayer,

  /// PDF page has some text, but too little to trust (e.g. only "第 3 页").
  textTooShort,

  /// PDF text layer decodes to garbage (wrong font encoding, broken CMap).
  garbledText,

  /// The page has enough characters overall, but they are only a running
  /// header/footer/page number; the body is a scanned image. This is the
  /// "25 normal header characters hide a scanned table" case: the old
  /// character-count-only rule called such a page "text layer sufficient".
  headerOnlyText,

  /// Mixed document: this page has no text while other pages do.
  mixedMissingText,

  /// Text layer is complete enough; OCR would duplicate text.
  textLayerSufficient,

  /// The user explicitly forced OCR for this page.
  userForced,

  /// The user explicitly excluded this page.
  userExcluded,
}

extension OcrPageReasonInfo on OcrPageReason {
  String get wire => switch (this) {
        OcrPageReason.imageSource => 'image_source',
        OcrPageReason.noTextLayer => 'no_text_layer',
        OcrPageReason.textTooShort => 'text_too_short',
        OcrPageReason.garbledText => 'garbled_text',
        OcrPageReason.headerOnlyText => 'header_only_text',
        OcrPageReason.mixedMissingText => 'mixed_missing_text',
        OcrPageReason.textLayerSufficient => 'text_layer_sufficient',
        OcrPageReason.userForced => 'user_forced',
        OcrPageReason.userExcluded => 'user_excluded',
      };

  String get label => switch (this) {
        OcrPageReason.imageSource => '图片（无文字层）',
        OcrPageReason.noTextLayer => '无文字层',
        OcrPageReason.textTooShort => '文字层过少',
        OcrPageReason.garbledText => '文字层疑似乱码',
        OcrPageReason.headerOnlyText => '仅页眉/页码文字',
        OcrPageReason.mixedMissingText => '混合文档中的扫描页',
        OcrPageReason.textLayerSufficient => '文字层充足',
        OcrPageReason.userForced => '用户强制识别',
        OcrPageReason.userExcluded => '用户排除',
      };

  String get explanation => switch (this) {
        OcrPageReason.imageSource => '图片没有文字层，需要本地 OCR 才能得到文字。',
        OcrPageReason.noTextLayer => '这一页没有可提取的文字（通常是扫描图），需要 OCR。',
        OcrPageReason.textTooShort =>
          '这一页文字层只有很少内容（可能只有页码/标题），建议 OCR 后校对。',
        OcrPageReason.garbledText =>
          '这一页文字层解码后包含大量异常字符（可能是字体编码问题），建议用 OCR 覆盖并校对。',
        OcrPageReason.headerOnlyText =>
          '这一页只有页眉/页码等版式文字，正文很可能是扫描图；仅凭字符数会误判“文字层充足”，建议 OCR 并核对。',
        OcrPageReason.mixedMissingText =>
          '同一文档其它页有文字层，而这一页没有；为避免漏掉扫描正文，已默认选中。',
        OcrPageReason.textLayerSufficient =>
          '文字层充足，直接使用原文即可，重复 OCR 只会增加重复文本。',
        OcrPageReason.userForced => '用户手动要求这一页重新识别。',
        OcrPageReason.userExcluded => '用户手动排除了这一页。',
      };
}

/// Detection decision for one page.
class OcrPagePlan {
  const OcrPagePlan({
    required this.page,
    required this.needsOcr,
    required this.reason,
    this.textLength = 0,
    this.bodyTextLength = 0,
    this.nativeLines = const <String>[],
    this.detail,
  });

  final int page;
  final bool needsOcr;
  final OcrPageReason reason;

  /// Characters found in the existing text layer (0 when there is none).
  final int textLength;

  /// Characters that are *not* running headers/footers/page numbers. This is
  /// the structural evidence used to spot a scanned body behind a text header.
  final int bodyTextLength;

  /// Text-layer lines classified as running header/footer/page number. They are
  /// preserved so a later merge can keep the native text and drop the duplicate
  /// OCR line instead of writing the header twice.
  final List<String> nativeLines;

  /// Optional technical context (garbage ratio, segment location, ...).
  final String? detail;

  String get explanation => detail == null
      ? reason.explanation
      : '${reason.explanation}（$detail）';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page': page,
        'needsOcr': needsOcr,
        'reason': reason.wire,
        'textLength': textLength,
        'bodyTextLength': bodyTextLength,
        if (nativeLines.isNotEmpty) 'nativeLines': nativeLines,
        if (detail != null) 'detail': detail,
      };
}

/// The complete page plan for one document.
class OcrPageDetection {
  const OcrPageDetection({
    required this.kind,
    required this.pageCount,
    required this.pages,
    this.warning,
    this.error,
    this.encrypted = false,
  });

  final OcrSourceKind kind;

  /// Pages in the source document (1-based plans are in [pages]).
  final int pageCount;

  /// One plan per page 1..[pageCount].
  final List<OcrPagePlan> pages;

  /// Non-fatal caveat (e.g. "PDF 使用了压缩对象流，文字层可能不完整").
  final String? warning;

  /// Set when detection itself failed; [pages] is then empty and the user can
  /// still choose pages manually (the dialog offers a manual fallback).
  final OcrError? error;

  /// The document is encrypted; page rendering needs the password.
  final bool encrypted;

  bool get detectionFailed => error != null;

  /// Pages selected for OCR, ascending.
  List<int> get pagesToOcr => <int>[
        for (final plan in pages)
          if (plan.needsOcr) plan.page,
      ];

  /// Pages that keep their extracted text layer, ascending.
  List<int> get textPages => <int>[
        for (final plan in pages)
          if (!plan.needsOcr) plan.page,
      ];

  int get selectedPageCount => pagesToOcr.length;

  bool get hasSelection => pagesToOcr.isNotEmpty;

  /// True when the document has no usable text layer at all.
  bool get isScannedOnly =>
      pages.isNotEmpty && textPages.every((page) {
        final plan = pages[page - 1];
        return plan.textLength == 0;
      });

  /// True when some pages have text and some need OCR.
  bool get isMixed {
    final withText = pages.where((plan) => plan.textLength > 0).length;
    final needing = selectedPageCount;
    return withText > 0 && needing > 0 && !isScannedOnly;
  }

  OcrPagePlan? planFor(int page) {
    if (page < 1 || page > pages.length) return null;
    return pages[page - 1];
  }

  /// Human-readable summary line for the dialog.
  String get summary {
    if (detectionFailed) return '无法自动检测需要 OCR 的页：${error!.message}';
    if (kind == OcrSourceKind.image) return '图片 1 页，需要本地 OCR。';
    if (isScannedOnly) return '共 $pageCount 页，未发现文字层：全部需要 OCR。';
    if (isMixed) {
      return '共 $pageCount 页：$selectedPageCount 页需要 OCR'
          '（文字层不足/缺失），${pageCount - selectedPageCount} 页沿用文字层。';
    }
    return '共 $pageCount 页，文字层充足：无需 OCR（也可手动强制识别）。';
  }
}

/// A text-layer reader for PDFs. Injectable so unit tests do not need real PDFs.
typedef OcrPdfPageTextReader = Future<OcrPdfPageTexts?> Function(String filePath);

/// Result of reading a PDF text layer.
class OcrPdfPageTexts {
  const OcrPdfPageTexts({
    required this.pageCount,
    required this.texts,
    this.warning,
    this.failure,
  });

  final int pageCount;

  /// 1-based page -> extracted text (pages without text may be absent/empty).
  final Map<int, String> texts;

  final String? warning;

  /// Set when the text-layer extraction failed (e.g. scanned-only PDF returns
  /// `unsupported_ocr`); detection still proceeds with zero text.
  final DocumentError? failure;
}

/// Reads the PDF text layer with the existing, offline extractor.
Future<OcrPdfPageTexts?> defaultOcrPdfPageTextReader(
  String filePath, {
  int maxBytes = 64 * 1024 * 1024,
}) async {
  final file = File(filePath);
  if (!file.existsSync()) return null;
  final result = await extractDocument(file, maxBytes: maxBytes);
  if (result.error != null) {
    return OcrPdfPageTexts(
      pageCount: 0,
      texts: const <int, String>{},
      failure: result.error,
    );
  }
  final document = result.document!;
  final texts = <int, String>{};
  for (final segment in document.segments) {
    final page = _pageOfLocation(segment.location);
    if (page == null) continue;
    final existing = texts[page];
    texts[page] = existing == null || existing.isEmpty
        ? segment.text
        : '$existing\n${segment.text}';
  }
  return OcrPdfPageTexts(
    pageCount: document.pages,
    texts: texts,
    warning: document.warning,
  );
}

int? _pageOfLocation(String? location) {
  if (location == null) return null;
  final match = RegExp(r'第\s*(\d+)\s*页').firstMatch(location);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Pure detection rule set (no I/O), used by tests and by the async wrapper.
OcrPageDetection detectOcrPagesFromTexts({
  required OcrSourceKind kind,
  required int pageCount,
  required Map<int, String> pageTexts,
  int minTextChars = 24,
  double maxGarbageRatio = 0.02,
  List<int> forcedPages = const <int>[],
  List<int> excludedPages = const <int>[],
  String? warning,
  bool encrypted = false,
}) {
  if (kind == OcrSourceKind.image) {
    return OcrPageDetection(
      kind: kind,
      pageCount: 1,
      pages: const <OcrPagePlan>[
        OcrPagePlan(
          page: 1,
          needsOcr: true,
          reason: OcrPageReason.imageSource,
        ),
      ],
      warning: warning,
    );
  }
  if (pageCount <= 0) {
    return OcrPageDetection(
      kind: kind,
      pageCount: 0,
      pages: const <OcrPagePlan>[],
      error: const OcrError(
        code: OcrErrorCode.pageOutOfRange,
        message: '无法确定文档页数，不能自动检测哪些页需要 OCR。',
      ),
    );
  }

  final forced = forcedPages.toSet();
  final excluded = excludedPages.toSet();
  final texts = <int, String>{
    for (final entry in pageTexts.entries)
      if (entry.key >= 1 && entry.key <= pageCount) entry.key: entry.value,
  };
  final anyText = texts.values.any((text) => text.trim().isNotEmpty);

  // Structural evidence available from the existing extractor: per-page text
  // lines only (it exposes no glyph/image boxes). We therefore classify lines
  // as running header/footer/page-number and keep the remaining "body" text:
  //   * a page-number-only line,
  //   * a digit-normalised template that repeats on >= 2 pages and sits in the
  //     first/last line (running header/footer),
  //   * on a page whose whole text layer is <= 2 lines, a line that names a
  //     page/form ("Page 1 of 4", "第 3 页", "考核表", "台账").
  final pageLines = <int, List<String>>{};
  for (var page = 1; page <= pageCount; page++) {
    pageLines[page] = <String>[
      for (final line in (texts[page] ?? '').split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }
  final templateCounts = <String, int>{};
  for (final lines in pageLines.values) {
    for (final line in lines) {
      final template = ocrHeaderTemplate(line);
      templateCounts[template] = (templateCounts[template] ?? 0) + 1;
    }
  }
  final plans = <OcrPagePlan>[];

  for (var page = 1; page <= pageCount; page++) {
    final raw = texts[page] ?? '';
    final text = raw.trim();
    final textLength = text.length;
    final garbageRatio = ocrGarbageRatio(text);
    final lines = pageLines[page] ?? const <String>[];
    final headerLines = <String>[];
    final bodyLines = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final positional = i == 0 || i == lines.length - 1;
      if (ocrIsPageNumberLine(line)) {
        headerLines.add(line);
        continue;
      }
      final template = ocrHeaderTemplate(line);
      final repeats = (templateCounts[template] ?? 0) >= 2;
      final singleLineHeader =
          lines.length <= 2 && positional && ocrLooksLikeHeaderLine(line);
      // A repeated template on a multi-line page (first/last line) is a running
      // header. On a single-line page the whole "body" would be classified as
      // header, so require an explicit page/form marker before doing that;
      // otherwise two pages with identical body text would both become "header".
      final repeatedHeader =
          repeats && positional && (lines.length > 2 || ocrLooksLikeHeaderLine(line));
      if (repeatedHeader || singleLineHeader) {
        headerLines.add(line);
        continue;
      }
      bodyLines.add(line);
    }
    final bodyTextLength =
        bodyLines.join('\n').replaceAll(RegExp(r'\s+'), '').length;

    if (excluded.contains(page)) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: false,
        reason: OcrPageReason.userExcluded,
        textLength: textLength,
        bodyTextLength: bodyTextLength,
        nativeLines: headerLines,
      ));
      continue;
    }
    if (forced.contains(page)) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: true,
        reason: OcrPageReason.userForced,
        textLength: textLength,
        bodyTextLength: bodyTextLength,
        nativeLines: headerLines,
      ));
      continue;
    }
    if (text.isEmpty) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: true,
        reason: anyText
            ? OcrPageReason.mixedMissingText
            : OcrPageReason.noTextLayer,
        textLength: 0,
      ));
      continue;
    }
    if (garbageRatio > maxGarbageRatio) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: true,
        reason: OcrPageReason.garbledText,
        textLength: textLength,
        bodyTextLength: bodyTextLength,
        nativeLines: headerLines,
        detail: '异常字符比例 ${(garbageRatio * 100).toStringAsFixed(1)}%',
      ));
      continue;
    }
    // The actual "25 header characters, scanned body" case: the page passed the
    // character threshold, but everything it contains is running header/footer.
    if (textLength >= minTextChars &&
        bodyTextLength < minTextChars &&
        headerLines.isNotEmpty) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: true,
        reason: OcrPageReason.headerOnlyText,
        textLength: textLength,
        bodyTextLength: bodyTextLength,
        nativeLines: headerLines,
        detail: '页眉/页码 ${headerLines.length} 行，正文仅 $bodyTextLength 字符'
            '（文字层共 $textLength 字符）',
      ));
      continue;
    }
    if (textLength < minTextChars) {
      plans.add(OcrPagePlan(
        page: page,
        needsOcr: true,
        reason: OcrPageReason.textTooShort,
        textLength: textLength,
        bodyTextLength: bodyTextLength,
        nativeLines: headerLines,
        detail: '仅 $textLength 个字符',
      ));
      continue;
    }
    plans.add(OcrPagePlan(
      page: page,
      needsOcr: false,
      reason: OcrPageReason.textLayerSufficient,
      textLength: textLength,
      bodyTextLength: bodyTextLength,
      nativeLines: headerLines,
    ));
  }

  return OcrPageDetection(
    kind: kind,
    pageCount: pageCount,
    pages: List<OcrPagePlan>.unmodifiable(plans),
    warning: warning,
    encrypted: encrypted,
  );
}

/// True for a line that is only a page number ("12", "第 12 页", "Page 3",
/// "3 / 16", "- 3 -").
bool ocrIsPageNumberLine(String line) {
  final compact = line.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return false;
  final patterns = <RegExp>[
    RegExp(r'^第?\d+页?$'),
    RegExp(r'^page\d+$', caseSensitive: false),
    RegExp(r'^\d+/\d+$'),
    RegExp(r'^-?\d+-?$'),
    RegExp(r'^第?\d+页共\d+页$'),
  ];
  for (final pattern in patterns) {
    if (pattern.hasMatch(compact)) return true;
  }
  return false;
}

/// Normalised template of a line: whitespace collapsed, lower-cased, each run
/// of digits replaced by '#'. Two occurrences of the same template on different
/// pages identify a running header/footer ("... Page 1 of 4" / "... Page 4 of 4").
String ocrHeaderTemplate(String line) {
  return line
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\d+'), '#')
      .trim();
}

/// A form/table/page label; only applied to pages whose whole text layer is at
/// most two lines, so a normal body line is never reclassified.
bool ocrLooksLikeHeaderLine(String line) {
  final lower = line.toLowerCase();
  if (RegExp(r'第\s*\d+\s*页').hasMatch(lower)) return true;
  if (RegExp(r'page\s*\d+').hasMatch(lower)) return true;
  if (RegExp(r'\d+\s*/\s*\d+').hasMatch(lower)) return true;
  if (RegExp(r'(form|申请[表单]|审批[表单]|考核[表单]|台账|报名[表单]|记录[表单])')
      .hasMatch(lower)) {
    return true;
  }
  return false;
}

/// Removes OCR lines that duplicate a native header/footer line kept from the
/// PDF text layer. Used when a page is OCRed for its scanned body while the
/// header already exists as text: the header must be written once, in its
/// native form. Comparison ignores whitespace/case but keeps digits (a wrong
/// header number must not be silently merged).
String mergeOcrTextWithNativeLines({
  required String ocrText,
  required List<String> nativeLines,
}) {
  if (nativeLines.isEmpty) return ocrText;
  final keys = <String>{
    for (final line in nativeLines)
      if (ocrLineKey(line).isNotEmpty) ocrLineKey(line),
  };
  final kept = <String>[];
  for (final line in ocrText.split('\n')) {
    final key = ocrLineKey(line);
    if (key.isNotEmpty && keys.contains(key)) continue;
    kept.add(line);
  }
  return kept.join('\n').trim();
}

/// Comparison key for header de-duplication.
String ocrLineKey(String line) =>
    line.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// Lines classified as native header/footer for [page] (empty when unknown).
extension OcrPageDetectionNativeLines on OcrPageDetection {
  List<String> nativeLinesFor(int page) => planFor(page)?.nativeLines ?? const <String>[];
}

/// Ratio of characters that almost certainly indicate a broken text layer.
///
/// Only used to *suggest* OCR; a legitimate document can still contain a few
/// replacement characters, which is why the threshold is a percentage.
double ocrGarbageRatio(String text) {
  if (text.isEmpty) return 0;
  var suspicious = 0;
  var total = 0;
  var questionMarks = 0;
  for (final rune in text.runes) {
    // Count line breaks/whitespace as neutral, but still part of the length.
    total++;
    if (rune == 0xFFFD) {
      suspicious++;
    } else if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
      suspicious++;
    } else if (rune >= 0xE000 && rune <= 0xF8FF) {
      // Private-use area: no real text should land here.
      suspicious++;
    } else if (rune == 0x25A1 || rune == 0x25A0 || rune == 0x25AF) {
      suspicious++;
    } else if (rune == 0x003F) {
      questionMarks++;
    }
  }
  // A long run of '?' is also a classic broken-decoding artefact, but a single
  // question mark in prose is normal.
  if (total > 0 && questionMarks / total > 0.2) {
    suspicious += questionMarks;
  }
  return total == 0 ? 0 : suspicious / total;
}

/// High-level detection: reads the text layer (existing extractor) and falls
/// back to the OCR host only for page count when the PDF has no text layer.
///
/// The helper is used for metadata only (`--info`); it does not OCR anything.
Future<OcrPageDetection> detectOcrPages(
  String filePath, {
  OcrSourceKind? kind,
  OcrPdfPageTextReader? pdfTextReader,
  Future<int?> Function(String filePath)? pageCountReader,
  OcrHostClient? hostClient,
  String? password,
  int maxBytes = 64 * 1024 * 1024,
  int minTextChars = 24,
  double maxGarbageRatio = 0.02,
  List<int> forcedPages = const <int>[],
  List<int> excludedPages = const <int>[],
}) async {
  final sourceKind = kind ?? OcrSourceKind.fromPath(filePath);
  final file = File(filePath);
  if (!file.existsSync()) {
    return OcrPageDetection(
      kind: sourceKind,
      pageCount: 0,
      pages: const <OcrPagePlan>[],
      error: OcrError(
        code: OcrErrorCode.renderFailed,
        message: '文件不存在或无法访问：$filePath',
      ),
    );
  }
  if (sourceKind == OcrSourceKind.unsupported) {
    return OcrPageDetection(
      kind: sourceKind,
      pageCount: 0,
      pages: const <OcrPagePlan>[],
      error: const OcrError(
        code: OcrErrorCode.unsupportedFormat,
        message: '不支持的文件类型。本地 OCR 支持 PDF、PNG、JPEG 图片。',
      ),
    );
  }
  if (sourceKind == OcrSourceKind.image) {
    return detectOcrPagesFromTexts(
      kind: sourceKind,
      pageCount: 1,
      pageTexts: const <int, String>{},
      forcedPages: forcedPages,
      excludedPages: excludedPages,
    );
  }

  final reader = pdfTextReader ?? defaultOcrPdfPageTextReader;
  final texts = await reader(filePath);
  if (texts == null) {
    return OcrPageDetection(
      kind: sourceKind,
      pageCount: 0,
      pages: const <OcrPagePlan>[],
      error: OcrError(
        code: OcrErrorCode.renderFailed,
        message: '无法读取 PDF 文件：$filePath',
      ),
    );
  }

  final failure = texts.failure;
  final pageCount = texts.pageCount;
  final warningParts = <String>[];
  if (texts.warning != null) warningParts.add(texts.warning!);

  if (failure != null) {
    switch (failure.kind) {
      case DocumentErrorKind.unsupportedOcr:
        warningParts.add('未发现文字层（扫描件）：已把全部页标记为需要 OCR。');
        break;
      case DocumentErrorKind.encrypted:
        warningParts.add('PDF 已加密：需要文档密码才能渲染页面。');
        break;
      case DocumentErrorKind.tooLarge:
        warningParts.add('文件过大，未做文字层检查；请分批识别。');
        break;
      default:
        warningParts.add('文字层读取失败（${failure.code}）：${failure.message}');
        break;
    }
  }

  if (pageCount <= 0) {
    // No text layer / failed extraction: ask the host for the page count only.
    final readerForCount = pageCountReader ??
        (hostClient == null
            ? null
            : (path) async {
                try {
                  final info = await hostClient.documentInfo(path, password: password);
                  return info.pageCount;
                } catch (_) {
                  return null;
                }
              });
    final count = readerForCount == null ? null : await readerForCount(filePath);
    if (count == null || count <= 0) {
      return OcrPageDetection(
        kind: sourceKind,
        pageCount: 0,
        pages: const <OcrPagePlan>[],
        error: OcrError(
          code: failure?.kind == DocumentErrorKind.encrypted
              ? OcrErrorCode.encrypted
              : OcrErrorCode.renderFailed,
          message: failure?.kind == DocumentErrorKind.encrypted
              ? 'PDF 已加密，需要提供密码才能确定页数并渲染页面。'
              : '无法确定 PDF 页数，不能自动检测需要 OCR 的页。${failure?.message ?? ''}',
          detail: failure?.detail,
        ),
      );
    }
    final detection = detectOcrPagesFromTexts(
      kind: sourceKind,
      pageCount: count,
      pageTexts: const <int, String>{},
      forcedPages: forcedPages,
      excludedPages: excludedPages,
      warning: warningParts.isEmpty ? null : warningParts.join('；'),
      encrypted: failure?.kind == DocumentErrorKind.encrypted,
    );
    return detection;
  }

  final detection = detectOcrPagesFromTexts(
    kind: sourceKind,
    pageCount: pageCount,
    pageTexts: texts.texts,
    minTextChars: minTextChars,
    maxGarbageRatio: maxGarbageRatio,
    forcedPages: forcedPages,
    excludedPages: excludedPages,
    warning: warningParts.isEmpty ? null : warningParts.join('；'),
    encrypted: failure?.kind == DocumentErrorKind.encrypted,
  );
  return detection;
}
