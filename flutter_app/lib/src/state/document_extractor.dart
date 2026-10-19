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
/// [maxBytes] is enforced twice:
/// 1. the source file must not exceed it, and
/// 2. the extracted UTF-8 text must not exceed it (no silent truncation).
///
/// The returned future never completes with an exception for an expected
/// failure (unsupported format, scan, encryption, corruption, empty file,
/// cancellation). Unexpected platform errors are also converted to
/// [DocumentErrorKind.corrupt] with a short detail string.
Future<ExtractionResult> extractDocument(
  File file, {
  required int maxBytes,
  ExtractionCancellation? cancellation,
}) async {
  final context = ExtractionContext(
    maxBytes: maxBytes,
    cancellation: cancellation,
  );
  try {
    if (maxBytes <= 0) {
      context.fail(
        DocumentErrorKind.tooLarge,
        '输入上限 maxBytes 必须大于 0（当前为 $maxBytes）。',
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
    if (length > maxBytes) {
      context.fail(
        DocumentErrorKind.tooLarge,
        '文件 $length 字节，超过输入上限 $maxBytes 字节（未做截断）。'
        '请拆分后重试，或调大配置里的 max_input_bytes。',
        detail: 'file_bytes=$length, max_bytes=$maxBytes',
      );
    }
    context.checkCancelled();

    final bytes = await file.readAsBytes();
    context.checkCancelled();
    // The file may have grown between length() and readAsBytes().
    if (bytes.length > maxBytes) {
      context.fail(
        DocumentErrorKind.tooLarge,
        '文件 ${bytes.length} 字节，超过输入上限 $maxBytes 字节（未做截断）。',
      );
    }

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

String _extensionOf(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

