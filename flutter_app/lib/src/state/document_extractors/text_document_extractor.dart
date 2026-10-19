// TXT / Markdown extraction. Keeps the original controller semantics:
// strict UTF-8, optional UTF-8 BOM, actionable UTF-16 / GBK messages.

import 'dart:convert';
import 'dart:typed_data';

import '../document_extraction_internal.dart';
import '../document_extraction_types.dart';

ExtractionResult extractPlainText(
  ExtractionContext context,
  Uint8List bytes, {
  required String kind,
}) {
  context.checkCancelled();

  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      context.fail(
        DocumentErrorKind.unsupported,
        '该文件是 UTF-16（小端）编码，请另存为 UTF-8 后重试。',
        detail: 'UTF-16 LE BOM',
      );
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      context.fail(
        DocumentErrorKind.unsupported,
        '该文件是 UTF-16（大端）编码，请另存为 UTF-8 后重试。',
        detail: 'UTF-16 BE BOM',
      );
    }
  }

  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3; // strip UTF-8 BOM
  }

  final String text;
  try {
    text = utf8.decode(bytes.sublist(start));
  } on FormatException {
    context.fail(
      DocumentErrorKind.unsupported,
      '该文件不是 UTF-8 编码（可能是 GBK/ANSI），请用记事本另存为 UTF-8 后重试。',
      detail: 'invalid UTF-8 byte sequence',
    );
  }

  if (text.trim().isEmpty) {
    context.fail(
      DocumentErrorKind.empty,
      '文件里只有空白字符，没有可用的文字内容。',
    );
  }
  context.checkCancelled();

  return context.succeed(
    text: text,
    kind: kind,
    pages: 1,
    segments: [DocumentSegment(text: text)],
  );
}

