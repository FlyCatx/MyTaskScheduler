// Public data model for local document text extraction.
//
// The extraction layer deliberately exposes *structured* failures instead of
// throwing: the UI must be able to tell "this is a scanned PDF, OCR is not
// available" apart from "the file is too large" or "the file is corrupt".
// Nothing in this library touches the network, executes macros/scripts or
// opens external links.
//
// Budgets are deliberately *split* (R3+ / task 06 A):
//   * [DocumentExtractionLimits.maxSourceFileBytes]     — container bytes;
//   * [DocumentExtractionLimits.maxExtractedTextUtf8Bytes] — extracted text;
//   * [DocumentExtractionLimits.maxZipEntryBytes] / [DocumentExtractionLimits.maxTotalUncompressedBytes]
//     — decompression guards for OOXML/PDF streams;
//   * the *single model request* budget is a different number again. A file may
//     be perfectly extractable locally and still not fit one request; callers
//     use [exceedsSingleRequestBudget] / [ExtractionResult.requiresChunking]
//     to route it to the existing chunked-analysis entry instead of rejecting
//     the file. Extraction never truncates text to make it fit.

import 'dart:convert';

/// Local budgets for turning a file into text.
///
/// The defaults mirror `analysis/analysis_budget.dart` (`AnalysisLimits` /
/// `LocalProcessingLimits`) but are *independent* numbers, so a container may
/// be much larger than the text inside it (a DOCX with many images is the
/// motivating example: 5,824,157 bytes of container, a few KB of text).
///
/// [DocumentExtractionLimits] does **not** contain the single-request byte
/// budget: "extractable locally" and "fits one model request" are separate
/// decisions (see [exceedsSingleRequestBudget]).
class DocumentExtractionLimits {
  const DocumentExtractionLimits({
    this.maxSourceFileBytes = 32 * 1024 * 1024,
    this.maxExtractedTextUtf8Bytes = 8 * 1024 * 1024,
    this.maxZipEntryBytes = 64 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 96 * 1024 * 1024,
    this.maxPdfPages = 400,
  }) : _legacySingleBudget = false;

  /// Backwards-compatible single-budget mode used by the legacy
  /// `extractDocument(file, maxBytes: ...)` call: the same number caps the
  /// source file **and** the extracted text, and the decompression guards are
  /// derived from it exactly as before.
  factory DocumentExtractionLimits.single(int maxBytes) {
    var part = maxBytes * 8;
    const floor = 8 * 1024 * 1024;
    const ceiling = 64 * 1024 * 1024;
    if (part < floor) part = floor;
    if (part > ceiling) part = ceiling;
    return DocumentExtractionLimits._legacy(
      maxSourceFileBytes: maxBytes,
      maxExtractedTextUtf8Bytes: maxBytes,
      maxZipEntryBytes: part,
    );
  }

  const DocumentExtractionLimits._legacy({
    required this.maxSourceFileBytes,
    required this.maxExtractedTextUtf8Bytes,
    required this.maxZipEntryBytes,
  })  : maxTotalUncompressedBytes = 96 * 1024 * 1024,
        maxPdfPages = 400,
        _legacySingleBudget = true;

  /// The shared default budget (32 MB container / 8 MB extracted text).
  static const DocumentExtractionLimits defaults = DocumentExtractionLimits();

  /// Maximum accepted source-file (container) bytes. Above this the file is
  /// rejected **before it is read**; the message names the limit and the next
  /// step. Compression ratios never matter here.
  final int maxSourceFileBytes;

  /// Maximum accepted **extracted text** UTF-8 bytes. Above this extraction
  /// fails explicitly with this limit in the message; the text is never
  /// truncated. This is a local-material budget, not a request budget.
  final int maxExtractedTextUtf8Bytes;

  /// Upper bound for one decompressed OOXML part / PDF stream.
  final int maxZipEntryBytes;

  /// Upper bound for the sum of all declared decompressed ZIP entry sizes
  /// (zip-bomb guard).
  final int maxTotalUncompressedBytes;

  /// Upper bound for the number of pages the minimal PDF parser walks.
  final int maxPdfPages;

  final bool _legacySingleBudget;

  /// True when this budget came from the legacy `maxBytes` shorthand.
  bool get isLegacySingleBudget => _legacySingleBudget;

  /// True when every limit is positive.
  bool get isValid =>
      maxSourceFileBytes > 0 &&
      maxExtractedTextUtf8Bytes > 0 &&
      maxZipEntryBytes > 0 &&
      maxTotalUncompressedBytes > 0 &&
      maxPdfPages > 0;

  /// Human-readable summary used in local-limit error messages / diagnostics.
  String get summary => '源文件 ≤ ${formatByteSize(maxSourceFileBytes)}；'
      '抽取文本 ≤ ${formatByteSize(maxExtractedTextUtf8Bytes)}；'
      '单个解压条目 ≤ ${formatByteSize(maxZipEntryBytes)}；'
      '解压总量 ≤ ${formatByteSize(maxTotalUncompressedBytes)}；'
      'PDF 页数 ≤ $maxPdfPages';

  @override
  String toString() => 'DocumentExtractionLimits($summary)';
}

/// Why a document could not be turned into text.
enum DocumentErrorKind {
  /// The format (or a feature required by the format) is not supported.
  unsupported,

  /// A PDF without a text layer (typically a scan). OCR is intentionally not
  /// part of this version.
  unsupportedOcr,

  /// The source file (or the extracted text) exceeds the caller's limit.
  tooLarge,

  /// The document is password protected / encrypted.
  encrypted,

  /// The container/XML/PDF structure could not be parsed.
  corrupt,

  /// The file or the extracted text is empty.
  empty,

  /// The caller cancelled the extraction.
  cancelled,
}

extension DocumentErrorKindCode on DocumentErrorKind {
  /// Stable machine-readable code, suitable for the controller/UI.
  String get code => switch (this) {
        DocumentErrorKind.unsupported => 'unsupported',
        DocumentErrorKind.unsupportedOcr => 'unsupported_ocr',
        DocumentErrorKind.tooLarge => 'too_large',
        DocumentErrorKind.encrypted => 'encrypted',
        DocumentErrorKind.corrupt => 'corrupt',
        DocumentErrorKind.empty => 'empty',
        DocumentErrorKind.cancelled => 'cancelled',
      };
}

/// A structured extraction failure. [message] is user-facing Chinese text;
/// [detail] carries optional technical context for logs, never a stack trace.
class DocumentError {
  const DocumentError(this.kind, this.message, {this.detail});

  final DocumentErrorKind kind;
  final String message;
  final String? detail;

  String get code => kind.code;

  @override
  String toString() => 'DocumentError(${kind.code}): $message';
}

/// A contiguous piece of text tied to a source location.
///
/// Locations are only emitted for formats where they are meaningful:
/// * PDF: `第 N 页`
/// * DOCX: `第 N 段`
/// * PPTX: `第 N 张幻灯片`
/// * TXT/MD: `null` (the whole file is one segment)
class DocumentSegment {
  const DocumentSegment({this.location, required this.text});

  final String? location;
  final String text;

  @override
  String toString() => location == null ? text : '[$location] $text';
}

/// Successfully extracted text plus enough metadata to show provenance.
class ExtractedDocument {
  const ExtractedDocument({
    required this.text,
    required this.kind,
    required this.pages,
    required this.segments,
    this.warning,
    this.sourceFileBytes = 0,
    int? textUtf8Bytes,
  }) : _textUtf8Bytes = textUtf8Bytes;

  /// Normalised, non-empty text (UTF-16 string; callers should measure
  /// [textUtf8Bytes] against their own context/request limit).
  final String text;

  /// `txt`, `md`, `pdf`, `docx` or `pptx`.
  final String kind;

  /// Page count for PDF, slide count for PPTX, `1` for TXT/MD. DOCX has no
  /// reliable pagination without a layout engine and reports `0`.
  final int pages;

  /// Ordered source segments. Never empty when this object exists.
  final List<DocumentSegment> segments;

  /// Human-readable note about a partial success (for example a scanned page
  /// inside an otherwise textual PDF), or `null` when everything was clean.
  final String? warning;

  /// Measured container bytes (0 when unknown). For diagnostics and for the
  /// chunked-material `SourceDocument.sourceFileBytes` field.
  final int sourceFileBytes;

  final int? _textUtf8Bytes;

  bool get hasWarning => warning != null;
  int get characterCount => text.length;

  /// UTF-8 byte length of [text] — the exact number the analysis budgets use.
  /// Computed once by the extractor and cached here.
  int get textUtf8Bytes => _textUtf8Bytes ?? utf8BytesOfText(text);

  /// True when this text fits one model request of [maxInputBytes] UTF-8 bytes.
  ///
  /// This is *not* a reason to reject the file: callers should keep the local
  /// material and use the chunked-analysis estimate/confirmation entry.
  bool canFitSingleRequest(int maxInputBytes) =>
      !exceedsSingleRequestBudget(text, maxInputBytes);
}

/// The result of the public extraction API. Exactly one of [document] /
/// [error] is set.
class ExtractionResult {
  const ExtractionResult._(this.document, this.error);

  const ExtractionResult.success(ExtractedDocument document)
      : this._(document, null);

  const ExtractionResult.failure(DocumentError error) : this._(null, error);

  final ExtractedDocument? document;
  final DocumentError? error;

  bool get ok => document != null;
  bool get isFailure => error != null;

  /// The error code (`unsupported_ocr`, `too_large`, ...) or `null` on success.
  String? get errorCode => error?.code;

  /// UTF-8 bytes of the extracted text, or `null` on failure.
  int? get textUtf8Bytes => document?.textUtf8Bytes;

  /// Measured container bytes, or 0 when the extraction failed before reading.
  int get sourceFileBytes => document?.sourceFileBytes ?? 0;

  /// True when the file was extracted locally **but** its text exceeds one
  /// model request of [maxInputBytes]. The caller should keep the material and
  /// route it to the existing chunked analysis; the text must not be truncated.
  bool requiresChunking(int maxInputBytes) =>
      document != null && !document!.canFitSingleRequest(maxInputBytes);

  @override
  String toString() => ok
      ? 'ExtractionResult(ok, kind=${document!.kind}, '
          'pages=${document!.pages}, chars=${document!.characterCount}, '
          'textUtf8Bytes=${document!.textUtf8Bytes}, '
          'sourceFileBytes=${document!.sourceFileBytes})'
      : 'ExtractionResult(failure, ${error!.code}: ${error!.message})';
}

/// UTF-8 byte length of [text] (same measure the analysis budgets use).
int utf8BytesOfText(String text) => utf8.encode(text).length;

/// True when [text] cannot be sent as one request body of [maxInputBytes].
///
/// Returns `true` for a non-empty text when [maxInputBytes] is not positive
/// (no request can carry it); an empty text never "exceeds".
bool exceedsSingleRequestBudget(String text, int maxInputBytes) {
  if (text.isEmpty) return false;
  if (maxInputBytes <= 0) return true;
  return utf8BytesOfText(text) > maxInputBytes;
}

/// Short human-readable byte size for user-facing limit messages.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes 字节';
  if (bytes < 1024 * 1024) {
    final kb = (bytes / 1024);
    return kb == kb.roundToDouble()
        ? '${kb.round()} KB'
        : '${kb.toStringAsFixed(1)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return mb == mb.roundToDouble()
      ? '${mb.round()} MB'
      : '${mb.toStringAsFixed(1)} MB';
}

/// Cooperative cancellation token for [extractDocument].
///
/// Extraction checks it between I/O, pages, slides and paragraphs. A cancelled
/// extraction returns [DocumentErrorKind.cancelled], never a half-built
/// document.
class ExtractionCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
