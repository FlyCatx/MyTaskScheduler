// Shared helpers for the extractors. Not exported from document_extractor.dart.

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
///
/// The budgets are split on purpose (R3+ task 06 A): the container bytes, the
/// extracted text bytes and the decompression guards are independent numbers.
class ExtractionContext {
  ExtractionContext({
    required this.limits,
    this.cancellation,
    this.sourceFileBytes = 0,
  });

  final DocumentExtractionLimits limits;
  final ExtractionCancellation? cancellation;

  /// Measured source-file bytes (set by the public API after the length check).
  int sourceFileBytes;

  /// True when the caller used the legacy single `maxBytes` shorthand; error
  /// messages keep the old `max_input_bytes` wording in that mode.
  bool get legacySingleBudget => limits.isLegacySingleBudget;

  /// Upper bound for one decompressed OOXML part / PDF stream.
  int get maxPartBytes => limits.maxZipEntryBytes;

  /// Upper bound for the sum of all decompressed ZIP entry sizes.
  int get maxTotalUncompressedBytes => limits.maxTotalUncompressedBytes;

  /// Upper bound for the number of pages the minimal PDF parser walks.
  int get maxPdfPages => limits.maxPdfPages;

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

  /// Builds a successful result after applying the shared empty/text-budget
  /// checks. Extractors call this as their final step.
  ///
  /// Text above [DocumentExtractionLimits.maxExtractedTextUtf8Bytes] is an
  /// explicit failure: the extracted text is **never** truncated. Text above
  /// the *single request* budget is not an error here — the caller decides
  /// whether to route the material to chunked analysis.
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
    final textBytes = utf8BytesOfText(text);
    final textLimit = limits.maxExtractedTextUtf8Bytes;
    if (textBytes > textLimit) {
      final String message;
      if (legacySingleBudget) {
        message = '提取出的文字约 $textBytes 字节，超过输入上限 $textLimit 字节（未截断）。'
            '请拆分文档后重试，或调大配置里的 max_input_bytes。';
      } else {
        message = '提取出的文字约 $textBytes 字节，超过本地抽取文本上限 '
            '${formatByteSize(textLimit)}（$textLimit 字节，未截断）。'
            '下一步：拆分文档后重试，或改用“分块分析”入口把材料分批发送。';
      }
      return ExtractionResult.failure(
        DocumentError(
          DocumentErrorKind.tooLarge,
          message,
          detail: 'extracted_text_bytes=$textBytes, '
              'max_extracted_text_utf8_bytes=$textLimit',
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
        sourceFileBytes: sourceFileBytes,
        textUtf8Bytes: textBytes,
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
