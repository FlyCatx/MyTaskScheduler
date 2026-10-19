// Public data model for local document text extraction.
//
// The extraction layer deliberately exposes *structured* failures instead of
// throwing: the UI must be able to tell "this is a scanned PDF, OCR is not
// available" apart from "the file is too large" or "the file is corrupt".
// Nothing in this library touches the network, executes macros/scripts or
// opens external links.

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
  });

  /// Normalised, non-empty text (UTF-16 string; callers should measure
  /// `utf8.encode(text).length` against their own context limit).
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

  bool get hasWarning => warning != null;
  int get characterCount => text.length;
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

  @override
  String toString() => ok
      ? 'ExtractionResult(ok, kind=${document!.kind}, '
          'pages=${document!.pages}, chars=${document!.characterCount})'
      : 'ExtractionResult(failure, ${error!.code}: ${error!.message})';
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

