// Local, offline text extraction for the "more file formats" feature.
//
// Supported:
//   * TXT / MD  — strict UTF-8 (same rules as the original controller path)
//   * PDF       — text-layer PDFs only. A minimal, pure-Dart parser is used;
//                 scanned/image-only PDFs return `unsupportedOcr` and OCR is
//                 intentionally not attempted.
//   * DOCX      — ZIP + OOXML (`word/document.xml`), paragraph locations
//   * PPTX      — ZIP + OOXML (`ppt/slides/slideN.xml`), slide locations
//
// Explicitly unsupported: legacy binary .doc/.ppt, encrypted documents,
// macros/scripts/external links (never executed or followed), and any format
// not listed above.
//
// Budgets (R3+ task 06 A): container bytes, extracted-text bytes and
// decompression guards are *separate* limits ([DocumentExtractionLimits]).
// A file that is larger than one model request is never rejected here: it is
// extracted locally and the caller routes it to chunked analysis via
// [ExtractionResult.requiresChunking]. Everything is processed locally and
// only after the user asks for it; selecting a file never calls the network.
//
// The API never throws: every failure is an [ExtractionResult] whose
// [DocumentError] carries a structured [DocumentErrorKind].

import 'dart:io';

import 'document_extraction_internal.dart';
import 'document_extraction_types.dart';
import 'document_extractors/ooxml_document_extractor.dart';
import 'document_extractors/pdf_document_extractor.dart';
import 'document_extractors/text_document_extractor.dart';

export 'document_extraction_types.dart';

/// Extracts plain text from [file] without network access and without
/// executing any document content.
///
/// Budgets, in order:
/// 1. the source file must not exceed
///    [DocumentExtractionLimits.maxSourceFileBytes] (checked before reading);
/// 2. every decompressed OOXML part / PDF stream and the total uncompressed
///    ZIP size must stay inside the local guards;
/// 3. the extracted UTF-8 text must not exceed
///    [DocumentExtractionLimits.maxExtractedTextUtf8Bytes] — no silent
///    truncation ever.
///
/// [limits] and [maxBytes] are both optional:
/// * [limits] — the split budgets (defaults: 32 MB container / 8 MB text);
/// * [maxBytes] — **legacy** compatibility shorthand: the same number limits
///   both the source file and the text, keeping the original
///   `max_input_bytes` wording. If both are supplied, [limits] wins.
///
/// Over the *local* budgets the result is [DocumentErrorKind.tooLarge] with a
/// message naming the concrete limit and the next step. A result that is
/// within the local budgets but larger than one model request is a **success**;
/// use [ExtractionResult.textUtf8Bytes] / [ExtractionResult.requiresChunking]
/// to decide between the normal flow and the chunked-analysis entry.
///
/// The returned future never completes with an exception for an expected
/// failure (unsupported format, scan, encryption, corruption, empty file,
/// cancellation). Unexpected platform errors are also converted to
/// [DocumentErrorKind.corrupt] with a short detail string.
Future<ExtractionResult> extractDocument(
  File file, {
  DocumentExtractionLimits? limits,
  int? maxBytes,
  ExtractionCancellation? cancellation,
}) async {
  final effectiveLimits =
      limits ?? (maxBytes != null ? DocumentExtractionLimits.single(maxBytes) : DocumentExtractionLimits.defaults);
  final context = ExtractionContext(
    limits: effectiveLimits,
    cancellation: cancellation,
  );
  try {
    if (!effectiveLimits.isValid) {
      if (effectiveLimits.isLegacySingleBudget) {
        context.fail(
          DocumentErrorKind.tooLarge,
          '输入上限 maxBytes 必须大于 0（当前为 ${effectiveLimits.maxSourceFileBytes}）。',
        );
      }
      context.fail(
        DocumentErrorKind.tooLarge,
        '本地文档处理预算配置无效：所有上限都必须大于 0（当前 ${effectiveLimits.summary}）。',
      );
    }
    context.checkCancelled();

    if (!await file.exists()) {
      context.fail(
        DocumentErrorKind.corrupt,
        '文件不存在或无法访问：${file.path}',
        detail: 'file does not exist',
      );
    }
    final length = await file.length();
    if (length == 0) {
      context.fail(
        DocumentErrorKind.empty,
        '文件是空的：${file.path}',
        detail: 'zero-length file',
      );
    }
    _checkSourceBudget(context, length);
    context.checkCancelled();

    final bytes = await file.readAsBytes();
    context.checkCancelled();
    // The file may have grown between length() and readAsBytes().
    if (bytes.length > effectiveLimits.maxSourceFileBytes) {
      context.fail(
        DocumentErrorKind.tooLarge,
        _sourceBudgetMessage(context, bytes.length),
        detail: 'file_bytes=${bytes.length}, '
            'max_source_file_bytes=${effectiveLimits.maxSourceFileBytes}',
      );
    }
    context.sourceFileBytes = bytes.length;

    final extension = _extensionOf(file.path);
    switch (extension) {
      case 'txt':
      case 'md':
        return extractPlainText(context, bytes, kind: extension);
      case 'pdf':
        return extractPdf(context, bytes);
      case 'docx':
      case 'docm':
        return extractDocx(context, bytes);
      case 'pptx':
      case 'pptm':
        return extractPptx(context, bytes);
      case 'doc':
      case 'ppt':
        context.fail(
          DocumentErrorKind.unsupported,
          '旧版二进制 .$extension 文件不支持。请用 Office/WPS 打开后另存为 '
          '.${extension}x 再重试。',
          detail: 'legacy OLE/CFB binary format',
        );
      case '':
        context.fail(
          DocumentErrorKind.unsupported,
          '无法识别文件类型（没有扩展名）：${file.path}。'
          '目前支持 TXT、MD、PDF、DOCX、PPTX。',
        );
      default:
        context.fail(
          DocumentErrorKind.unsupported,
          '不支持 .$extension 文件。目前支持 UTF-8 的 TXT / MD，以及文本型 PDF、'
          'DOCX、PPTX。图片与扫描件需要先转成文字。',
        );
    }
  } on ExtractionFailure catch (failure) {
    return ExtractionResult.failure(failure.error);
  } catch (error) {
    // No raw exception/stack trace is allowed to reach the UI. Keep a short
    // detail for diagnostics.
    return ExtractionResult.failure(
      DocumentError(
        DocumentErrorKind.corrupt,
        '读取或解析文件失败。文件可能已损坏、被其它程序占用，或不是有效的文档。',
        detail: '$error',
      ),
    );
  }
}

void _checkSourceBudget(ExtractionContext context, int length) {
  final limit = context.limits.maxSourceFileBytes;
  if (length > limit) {
    context.fail(
      DocumentErrorKind.tooLarge,
      _sourceBudgetMessage(context, length),
      detail: 'file_bytes=$length, max_source_file_bytes=$limit',
    );
  }
}

String _sourceBudgetMessage(ExtractionContext context, int length) {
  final limit = context.limits.maxSourceFileBytes;
  if (context.legacySingleBudget) {
    return '文件 $length 字节，超过输入上限 $limit 字节（未做截断）。'
        '请拆分后重试，或调大配置里的 max_input_bytes。';
  }
  return '文件 $length 字节，超过本地导入上限：单个源文件最大 '
      '${formatByteSize(limit)}（$limit 字节，未做截断，未读取内容）。'
      '下一步：拆分或压缩该文件后重试，或改用“分块分析”入口。';
}

String _extensionOf(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}
