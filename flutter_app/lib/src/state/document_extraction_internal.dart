// Shared helpers for the extractors. Not exported from document_extractor.dart.

import 'dart:convert';

import 'document_extraction_types.dart';

/// Thrown inside an extractor and converted to an [ExtractionResult] at the
/// public boundary. It never escapes the public extraction API.
class ExtractionFailure implements Exception {
  ExtractionFailure(this.error);

  final DocumentError error;

  @override
  String toString() => error.toString();
}

/// Limits + cancellation shared by every format extractor.
class ExtractionContext {
  const ExtractionContext({
    required this.maxBytes,
    this.cancellation,
  });

  /// Maximum accepted source-file size **and** maximum accepted extracted-text
  /// size. Consistent with the existing controller behaviour: never truncate
  /// silently, report the over-limit condition instead.
  final int maxBytes;

  final ExtractionCancellation? cancellation;

  /// Upper bound for one decompressed OOXML part / PDF stream. This protects
  /// against zip bombs and runaway streams. It is deliberately independent of
  /// [maxBytes] (a small .docx may legitimately contain a larger XML part).
  int get maxPartBytes {
    var limit = maxBytes * 8;
    const floor = 8 * 1024 * 1024;
    const ceiling = 64 * 1024 * 1024;
    if (limit < floor) limit = floor;
    if (limit > ceiling) limit = ceiling;
    return limit;
  }

  void checkCancelled() {
    if (cancellation?.isCancelled ?? false) {
      throw ExtractionFailure(
        const DocumentError(
          DocumentErrorKind.cancelled,
          '提取已取消，未保存任何内容。',
        ),
      );
    }
  }

  Never fail(
    DocumentErrorKind kind,
    String message, {
    String? detail,
  }) {
    throw ExtractionFailure(DocumentError(kind, message, detail: detail));
  }

  /// Builds a successful result after applying the shared empty/too-large
  /// checks. Extractors call this as their final step.
  ExtractionResult succeed({
    required String text,
    required String kind,
    required int pages,
    required List<DocumentSegment> segments,
    String? warning,
  }) {
    if (text.trim().isEmpty || segments.isEmpty) {
      return ExtractionResult.failure(
        DocumentError(
          DocumentErrorKind.empty,
          '未从该 $kind 文件中提取到文字（文件可能是空的，或只包含图片/图形）。',
        ),
      );
    }
    final textBytes = utf8.encode(text).length;
    if (textBytes > maxBytes) {
      return ExtractionResult.failure(
        DocumentError(
          DocumentErrorKind.tooLarge,
          '提取出的文字约 $textBytes 字节，超过输入上限 $maxBytes 字节（未截断）。'
          '请拆分文档后重试，或调大配置里的 max_input_bytes。',
          detail: 'extracted_text_bytes=$textBytes, max_bytes=$maxBytes',
        ),
      );
    }
    return ExtractionResult.success(
      ExtractedDocument(
        text: text,
        kind: kind,
        pages: pages,
        segments: List<DocumentSegment>.unmodifiable(segments),
        warning: warning,
      ),
    );
  }
}

/// Joins non-null warnings, removes duplicates and keeps document order.
String? combineWarnings(Iterable<String?> warnings) {
  final seen = <String>{};
  final kept = <String>[];
  for (final warning in warnings) {
    final value = warning?.trim();
    if (value == null || value.isEmpty) continue;
    if (seen.add(value)) kept.add(value);
  }
  return kept.isEmpty ? null : kept.join('；');
}

/// Normalises text extracted from a document:
/// * CRLF/CR -> LF
/// * strips NUL and other non-printing control chars (keeps tab/newline)
/// * trims trailing spaces per line
/// * collapses 3+ blank lines to at most one blank line
String normaliseExtractedText(String input) {
  final withoutControls = input.replaceAll(
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
    '',
  );
  final lines = withoutControls
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+$'), ''))
      .toList(growable: false);
  final out = <String>[];
  var blankRun = 0;
  for (final line in lines) {
    final blank = line.trim().isEmpty;
    if (blank) {
      blankRun++;
      if (blankRun > 1) continue;
      out.add('');
    } else {
      blankRun = 0;
      out.add(line);
    }
  }
  return out.join('\n').trim();
}

