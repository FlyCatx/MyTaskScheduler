// DOCX / PPTX extraction through ZIP + OOXML.
//
// Only the text parts are read. Macros, embedded objects, scripts and external
// relationships are never executed or fetched. The archive is inspected in
// memory (no extraction to disk) and every decompressed part is size-capped.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../document_extraction_internal.dart';
import '../document_extraction_types.dart';

/// OLE/CFB magic: password-protected OOXML is stored inside a CFB container,
/// and the same magic identifies the legacy binary .doc/.ppt formats.
const _cfbMagic = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

ExtractionResult extractDocx(ExtractionContext context, Uint8List bytes) {
  context.checkCancelled();
  _rejectNonZipContainer(context, bytes, 'DOCX');

  final archive = _openZip(context, bytes);
  context.checkCancelled();

  final warnings = <String>[];
  _macroWarning(archive, 'word/vbaProject.bin', warnings);

  final documentPart = _readPart(context, archive, 'word/document.xml');
  if (documentPart == null) {
    context.fail(
      DocumentErrorKind.corrupt,
      'DOCX 缺少 word/document.xml，文件可能已损坏或不是 Word 文档。',
      detail: 'missing word/document.xml',
    );
  }
  final document = _parseXml(context, documentPart, 'word/document.xml');
  if (document.rootElement.name.local != 'document') {
    context.fail(
      DocumentErrorKind.corrupt,
      'DOCX 的 word/document.xml 根节点不是 w:document，文件结构不正确。',
    );
  }

  // `w:p` appears in document order. Nested paragraphs (text boxes) are
  // included as their own paragraphs; the outer paragraph skips their subtree
  // so text is not duplicated.
  final paragraphs = document.findAllElements('p', namespace: '*');
  final segments = <DocumentSegment>[];
  var paragraphIndex = 0;
  for (final paragraph in paragraphs) {
    context.checkCancelled();
    paragraphIndex++;
    final raw = _docxParagraphText(paragraph);
    final text = raw.trim();
    if (text.isEmpty) continue;
    segments.add(
      DocumentSegment(location: '第 $paragraphIndex 段', text: text),
    );
  }

  final text = normaliseExtractedText(
    segments.map((segment) => segment.text).join('\n'),
  );
  return context.succeed(
    text: text,
    kind: 'docx',
    // No layout engine here, so a page count would be a guess. Paragraph
    // locations are the useful provenance for DOCX.
    pages: 0,
    segments: segments,
    warning: combineWarnings(warnings),
  );
}

ExtractionResult extractPptx(ExtractionContext context, Uint8List bytes) {
  context.checkCancelled();
  _rejectNonZipContainer(context, bytes, 'PPTX');

  final archive = _openZip(context, bytes);
  context.checkCancelled();

  final warnings = <String>[];
  _macroWarning(archive, 'ppt/vbaProject.bin', warnings);

  final slideEntries = _slideEntries(archive);
  if (slideEntries.isEmpty) {
    return const ExtractionResult.failure(
      DocumentError(
        DocumentErrorKind.empty,
        'PPTX 中没有找到幻灯片（ppt/slides/slideN.xml）。',
      ),
    );
  }

  final orderedNames = _orderedSlideNames(
    context,
    archive,
    slideEntries,
    warnings,
  );

  final segments = <DocumentSegment>[];
  var invalidSlides = 0;
  for (var i = 0; i < orderedNames.length; i++) {
    context.checkCancelled();
    final name = orderedNames[i];
    final slideNumber = i + 1;
    final part = _readPart(context, archive, name);
    if (part == null) {
      invalidSlides++;
      warnings.add('第 $slideNumber 张幻灯片（$name）缺失，已跳过。');
      continue;
    }
    final XmlDocument slide;
    try {
      slide = _parseXml(context, part, name);
    } on ExtractionFailure {
      invalidSlides++;
      warnings.add('第 $slideNumber 张幻灯片（$name）无法解析，已跳过。');
      continue;
    }
    final text = _pptxSlideText(slide);
    if (text.isEmpty) {
      warnings.add('第 $slideNumber 张幻灯片没有文字。');
      continue;
    }
    segments.add(
      DocumentSegment(location: '第 $slideNumber 张幻灯片', text: text),
    );
  }

  if (orderedNames.isNotEmpty && invalidSlides == orderedNames.length) {
    context.fail(
      DocumentErrorKind.corrupt,
      'PPTX 中的幻灯片都无法解析，文件可能已损坏。',
      detail: 'all $invalidSlides slide parts invalid',
    );
  }

  return context.succeed(
    text: normaliseExtractedText(
      segments.map((segment) => segment.text).join('\n\n'),
    ),
    kind: 'pptx',
    pages: orderedNames.length,
    segments: segments,
    warning: combineWarnings(warnings),
  );
}

void _rejectNonZipContainer(
  ExtractionContext context,
  Uint8List bytes,
  String label,
) {
  if (bytes.length >= _cfbMagic.length) {
    var cfb = true;
    for (var i = 0; i < _cfbMagic.length; i++) {
      if (bytes[i] != _cfbMagic[i]) {
        cfb = false;
        break;
      }
    }
    if (cfb) {
      context.fail(
        DocumentErrorKind.encrypted,
        '$label 文件是加密的 Office 文档（或其实是旧版二进制格式）。'
        '请先解除密码保护，并用 Office/WPS 另存为 .${label.toLowerCase()} 后重试。',
        detail: 'OLE/CFB container',
      );
    }
  }
  final isZip = bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      (bytes[2] == 0x03 || bytes[2] == 0x05) &&
      (bytes[3] == 0x04 || bytes[3] == 0x06);
  if (!isZip) {
    context.fail(
      DocumentErrorKind.corrupt,
      '$label 文件不是有效的 ZIP/OOXML 容器，可能已损坏。',
      detail: 'bad ZIP signature',
    );
  }
}

Archive _openZip(ExtractionContext context, Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    final text = '$error'.toLowerCase();
    if (text.contains('encrypt') || text.contains('password')) {
      context.fail(
        DocumentErrorKind.encrypted,
        'Office 文档已加密，需要密码才能读取，本版本不支持加密文档。',
        detail: '$error',
      );
    }
    context.fail(
      DocumentErrorKind.corrupt,
      '无法读取 ZIP/OOXML 容器，文件可能已损坏。',
      detail: '$error',
    );
  }
}

/// Returns `null` only when the part is absent; structural failures throw.
Uint8List? _readPart(
  ExtractionContext context,
  Archive archive,
  String name,
) {
  final file = archive.find(name);
  if (file == null || !file.isFile) return null;
  if (file.size > context.maxPartBytes) {
    context.fail(
      DocumentErrorKind.tooLarge,
      '文档内部文件 $name 解压后约 ${file.size} 字节，超过安全上限 '
      '${context.maxPartBytes} 字节，已拒绝读取。',
      detail: 'zip part too large',
    );
  }
  try {
    final data = file.readBytes();
    if (data == null) return null;
    if (data.length > context.maxPartBytes) {
      context.fail(
        DocumentErrorKind.tooLarge,
        '文档内部文件 $name 解压后超过安全上限，已拒绝读取。',
      );
    }
    return data;
  } on ExtractionFailure {
    rethrow;
  } catch (error) {
    context.fail(
      DocumentErrorKind.corrupt,
      '无法读取文档内部文件 $name，文件可能已损坏。',
      detail: '$error',
    );
  }
}

XmlDocument _parseXml(
  ExtractionContext context,
  Uint8List bytes,
  String partName,
) {
  // allowMalformed keeps encoding problems separate from XML structure
  // problems; the XML parser still rejects malformed markup.
  final text = utf8.decode(bytes, allowMalformed: true);
  // OOXML never needs a DTD. Reject it instead of giving a parser the chance
  // to expand entities (no external access is attempted either way).
  if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
    context.fail(
      DocumentErrorKind.unsupported,
      '文档内部 XML（$partName）包含 DTD/实体声明，出于安全考虑已拒绝解析。',
      detail: 'DTD/ENTITY rejected',
    );
  }
  try {
    return XmlDocument.parse(text);
  } catch (error) {
    context.fail(
      DocumentErrorKind.corrupt,
      '文档内部 XML（$partName）无法解析，文件可能已损坏。',
      detail: '$error',
    );
  }
}

void _macroWarning(Archive archive, String macroPath, List<String> warnings) {
  if (archive.find(macroPath) != null) {
    warnings.add('文档包含宏（$macroPath），已忽略且未执行。');
  }
}

String _docxParagraphText(XmlElement paragraph) {
  final out = StringBuffer();

  void walk(XmlNode node) {
    if (node is XmlElement) {
      final name = node.name.local;
      if (node != paragraph && name == 'p') {
        // Nested paragraph (text box): handled by its own iteration.
        return;
      }
      switch (name) {
        case 't':
          out.write(node.innerText);
          return;
        case 'tab':
          out.write('\t');
          return;
        case 'br':
        case 'cr':
          out.write('\n');
          return;
        case 'noBreakHyphen':
          out.write('-');
          return;
        case 'softHyphen':
          return;
        case 'instrText':
        case 'delText':
          // Field instructions and deleted revisions are not document text.
          return;
        case 'drawing':
        case 'pict':
          // Do not execute/parse embedded drawings here. Text boxes inside
          // them contain their own w:p, which is visited separately.
          return;
      }
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  walk(paragraph);
  return out.toString();
}

String _pptxSlideText(XmlDocument slide) {
  final paragraphs = <String>[];
  for (final paragraph in slide.findAllElements('p', namespace: '*')) {
    final buffer = StringBuffer();
    void walk(XmlNode node) {
      if (node is XmlElement) {
        final name = node.name.local;
        if (node != paragraph && name == 'p') return;
        switch (name) {
          case 't':
            buffer.write(node.innerText);
            return;
          case 'br':
            buffer.write('\n');
            return;
          case 'tab':
            buffer.write('\t');
            return;
        }
      }
      for (final child in node.children) {
        walk(child);
      }
    }

    walk(paragraph);
    final text = buffer.toString().trim();
    if (text.isNotEmpty) paragraphs.add(text);
  }
  return paragraphs.join('\n');
}

/// Slide part names, sorted by their numeric suffix. This is the fallback when
/// the presentation order cannot be read.
List<String> _slideEntries(Archive archive) {
  final pattern = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
  final entries = <({String name, int number})>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final match = pattern.firstMatch(file.name);
    if (match == null) continue;
    final number = int.tryParse(match.group(1)!);
    if (number == null) continue;
    entries.add((name: file.name, number: number));
  }
  entries.sort((a, b) => a.number.compareTo(b.number));
  return [for (final entry in entries) entry.name];
}

List<String> _orderedSlideNames(
  ExtractionContext context,
  Archive archive,
  List<String> sortedNames,
  List<String> warnings,
) {
  final presentationPart = _readPart(context, archive, 'ppt/presentation.xml');
  final relsPart =
      _readPart(context, archive, 'ppt/_rels/presentation.xml.rels');
  if (presentationPart == null || relsPart == null) {
    warnings.add('未找到 presentation.xml / 关系文件，幻灯片按文件名顺序读取。');
    return sortedNames;
  }

  try {
    final presentation =
        XmlDocument.parse(utf8.decode(presentationPart, allowMalformed: true));
    final rels = XmlDocument.parse(utf8.decode(relsPart, allowMalformed: true));

    final relationships = <String, String>{};
    for (final relationship
        in rels.findAllElements('Relationship', namespace: '*')) {
      final id = _attribute(relationship, 'Id');
      final target = _attribute(relationship, 'Target');
      if (id != null && target != null) {
        relationships[id] = _resolvePartTarget(target);
      }
    }

    final ordered = <String>[];
    for (final slideId
        in presentation.findAllElements('sldId', namespace: '*')) {
      // `p:sldId` has both `id="256"` and `r:id="rId2"`; only the latter
      // points at the relationship (and therefore at the slide part).
      final id = _relationshipId(slideId);
      if (id == null) continue;
      final target = relationships[id];
      if (target != null && sortedNames.contains(target)) {
        if (!ordered.contains(target)) ordered.add(target);
      }
    }
    if (ordered.isEmpty) {
      warnings.add('无法确认幻灯片顺序，已按文件名排序。');
      return sortedNames;
    }
    if (ordered.length != sortedNames.length) {
      warnings.add('部分幻灯片缺少顺序信息，已按文件名补齐。');
      for (final name in sortedNames) {
        if (!ordered.contains(name)) ordered.add(name);
      }
    }
    return ordered;
  } catch (_) {
    warnings.add('幻灯片顺序信息无法解析，已按文件名排序。');
    return sortedNames;
  }
}

String? _attribute(XmlElement element, String localName) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }
  return null;
}

String? _relationshipId(XmlElement element) {
  const relationshipsNamespace =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  for (final attribute in element.attributes) {
    if (attribute.name.local != 'id') continue;
    if (attribute.name.prefix == 'r' ||
        attribute.name.namespaceUri == relationshipsNamespace) {
      return attribute.value;
    }
  }
  return null;
}

String _resolvePartTarget(String target) {
  var value = target.replaceAll('\\', '/').trim();
  if (value.startsWith('/')) {
    value = value.substring(1);
  } else if (!value.startsWith('ppt/')) {
    value = 'ppt/$value';
  }
  final out = <String>[];
  for (final segment in value.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(segment);
  }
  return out.join('/');
}

