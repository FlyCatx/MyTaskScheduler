// Tests for the local "more file formats" extraction layer.
//
// Every fixture is constructed in a temp directory by the test itself:
// DOCX/PPTX are minimal OOXML ZIPs, PDFs are hand-written minimal files.
// No real user file is read.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/document_extractor.dart';

// ---------------------------------------------------------------------------
// Temp files / ZIP fixtures
// ---------------------------------------------------------------------------

Directory _tempDir() {
  final dir = Directory(
    '${Directory.current.path}${Platform.pathSeparator}test_tmp'
    '${Platform.pathSeparator}doc_extract_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

File _write(Directory dir, String name, List<int> bytes) {
  final file = File('${dir.path}${Platform.pathSeparator}$name')
    ..writeAsBytesSync(bytes);
  return file;
}

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

const _contentTypes = '<?xml version="1.0" encoding="UTF-8"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '</Types>';

Uint8List _docxZip(String documentXml, {bool withMacro = false}) => _zip({
      '[Content_Types].xml': utf8.encode(_contentTypes),
      'word/document.xml': utf8.encode(documentXml),
      if (withMacro) 'word/vbaProject.bin': const [0x4D, 0x5A, 0x00],
    });

String _docxXml(String body) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:body>$body</w:body></w:document>';

String _slideXml(String text) =>
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
    '<p:cSld><p:spTree><p:sp><p:txBody>'
    '<a:p><a:r><a:t>${_xmlEscape(text)}</a:t></a:r></a:p>'
    '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>';

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

Uint8List _pptxZip({
  required Map<String, String> slides,
  List<String>? order,
  bool includePresentation = true,
  bool withMacro = false,
}) {
  final entries = <String, List<int>>{
    '[Content_Types].xml': utf8.encode(_contentTypes),
  };
  slides.forEach((name, xml) {
    entries['ppt/slides/$name.xml'] = utf8.encode(xml);
  });
  if (withMacro) {
    entries['ppt/vbaProject.bin'] = const [0x4D, 0x5A, 0x00];
  }
  if (includePresentation) {
    final displayOrder = order ?? slides.keys.toList();
    final slideIds = <String>[];
    final relationships = <String>[];
    for (var i = 0; i < displayOrder.length; i++) {
      final name = displayOrder[i];
      final number = RegExp(r'(\d+)$').firstMatch(name)?.group(1) ?? '${i + 1}';
      final relId = 'rId$number';
      slideIds.add('<p:sldId id="${256 + i}" r:id="$relId"/>');
      relationships.add(
        '<Relationship Id="$relId" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
        'Target="slides/$name.xml"/>',
      );
    }
    entries['ppt/presentation.xml'] = utf8.encode(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:presentation '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<p:sldIdLst>${slideIds.join()}</p:sldIdLst></p:presentation>',
    );
    entries['ppt/_rels/presentation.xml.rels'] = utf8.encode(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships '
      'xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${relationships.join()}</Relationships>',
    );
  }
  return _zip(entries);
}

// ---------------------------------------------------------------------------
// Minimal PDF builder
// ---------------------------------------------------------------------------

class _PdfBuilder {
  final Map<int, List<int>> _objects = {};

  int addObject(String body) {
    final number = _objects.length + 1;
    _objects[number] = latin1.encode(body);
    return number;
  }

  int addStream(List<int> data, {String extra = ''}) {
    final number = _objects.length + 1;
    final body = BytesBuilder()
      ..add(latin1.encode('<< /Length ${data.length} $extra >>\nstream\n'))
      ..add(data)
      ..add(latin1.encode('\nendstream'));
    _objects[number] = body.toBytes();
    return number;
  }

  Uint8List build({required int root, String trailerExtra = ''}) {
    final out = BytesBuilder()..add(latin1.encode('%PDF-1.4\n'));
    final numbers = _objects.keys.toList()..sort();
    for (final number in numbers) {
      out
        ..add(latin1.encode('$number 0 obj\n'))
        ..add(_objects[number]!)
        ..add(latin1.encode('\nendobj\n'));
    }
    out.add(
      latin1.encode(
        'trailer\n<< /Root $root 0 R /Size ${_objects.length + 1} '
        '$trailerExtra >>\n%%EOF\n',
      ),
    );
    return out.toBytes();
  }
}

Uint8List _textPdf(
  List<String> pageContents, {
  bool compressed = false,
}) {
  final builder = _PdfBuilder();
  final font = builder.addObject(
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  final pageRefs = <int>[];
  for (final content in pageContents) {
    final data = compressed
        ? const ZLibEncoder().encodeBytes(utf8.encode(content))
        : latin1.encode(content);
    final contentRef = builder.addStream(
      data,
      extra: compressed ? '/Filter /FlateDecode' : '',
    );
    pageRefs.add(
      builder.addObject(
        '<< /Type /Page /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 $font 0 R >> >> '
        '/Contents $contentRef 0 R >>',
      ),
    );
  }
  final pages = builder.addObject(
    '<< /Type /Pages /Kids '
    '[${pageRefs.map((ref) => '$ref 0 R').join(' ')}] '
    '/Count ${pageRefs.length} >>',
  );
  final catalog = builder.addObject(
    '<< /Type /Catalog /Pages $pages 0 R >>',
  );
  return builder.build(root: catalog);
}

Uint8List _imageOnlyPdf() {
  final builder = _PdfBuilder();
  final image = builder.addStream(
    const [0, 0, 0],
    extra: '/Type /XObject /Subtype /Image /Width 1 /Height 1 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8',
  );
  final content = builder.addStream(
    latin1.encode('q 612 0 0 792 0 0 cm /Im0 Do Q'),
  );
  final page = builder.addObject(
    '<< /Type /Page /MediaBox [0 0 612 792] '
    '/Resources << /XObject << /Im0 $image 0 R >> >> '
    '/Contents $content 0 R >>',
  );
  final pages = builder.addObject(
    '<< /Type /Pages /Kids [$page 0 R] /Count 1 >>',
  );
  final catalog = builder.addObject(
    '<< /Type /Catalog /Pages $pages 0 R >>',
  );
  return builder.build(root: catalog);
}

Uint8List _multiStreamPdf() {
  final builder = _PdfBuilder();
  final font = builder.addObject(
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  final first = builder.addStream(
    latin1.encode('BT /F1 12 Tf 72 712 Td (Hello ) Tj ET'),
  );
  final second = builder.addStream(
    latin1.encode('BT /F1 12 Tf 72 700 Td [(World) -120 (Again)] TJ ET'),
  );
  final page = builder.addObject(
    '<< /Type /Page /MediaBox [0 0 612 792] '
    '/Contents [$first 0 R $second 0 R] >>',
  );
  // Resources live on the Pages node to exercise inheritance.
  final pages = builder.addObject(
    '<< /Type /Pages /Kids [$page 0 R] /Count 1 '
    '/Resources << /Font << /F1 $font 0 R >> >> >>',
  );
  final catalog = builder.addObject(
    '<< /Type /Catalog /Pages $pages 0 R >>',
  );
  return builder.build(root: catalog);
}

Uint8List _cjkPdf() {
  final builder = _PdfBuilder();
  const cmap = '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
2 beginbfchar
<0001> <4F60>
<0002> <597D>
endbfchar
endcmap
CMapName currentdict /CMap defineresource pop
end
end
''';
  final cmapRef = builder.addStream(latin1.encode(cmap));
  final cidFont = builder.addObject(
    '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /SimSun '
    '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) '
    '/Supplement 0 >> >>',
  );
  final font = builder.addObject(
    '<< /Type /Font /Subtype /Type0 /BaseFont /SimSun /Encoding /Identity-H '
    '/DescendantFonts [$cidFont 0 R] /ToUnicode $cmapRef 0 R >>',
  );
  final content = builder.addStream(
    latin1.encode('BT /F1 12 Tf 72 712 Td <00010002> Tj ET'),
  );
  final page = builder.addObject(
    '<< /Type /Page /MediaBox [0 0 612 792] '
    '/Resources << /Font << /F1 $font 0 R >> >> '
    '/Contents $content 0 R >>',
  );
  final pages = builder.addObject(
    '<< /Type /Pages /Kids [$page 0 R] /Count 1 >>',
  );
  final catalog = builder.addObject(
    '<< /Type /Catalog /Pages $pages 0 R >>',
  );
  return builder.build(root: catalog);
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

void _expectFailure(ExtractionResult result, DocumentErrorKind kind) {
  expect(
    result.ok,
    isFalse,
    reason: 'expected failure, got text: ${result.document?.text}',
  );
  expect(result.error, isNotNull);
  expect(result.error!.kind, kind, reason: result.error!.message);
  expect(result.errorCode, kind.code);
}

void main() {
  group('TXT / MD', () {
    test('UTF-8 text and Markdown are returned as one segment', () async {
      final dir = _tempDir();
      final txt = _write(dir, 'notes.txt', utf8.encode('第一行\n第二行'));
      final md = _write(dir, 'readme.md', utf8.encode('# 标题\n\n正文'));

      final txtResult = await extractDocument(txt, maxBytes: 4096);
      expect(txtResult.ok, isTrue);
      expect(txtResult.document!.kind, 'txt');
      expect(txtResult.document!.pages, 1);
      expect(txtResult.document!.segments, hasLength(1));
      expect(txtResult.document!.segments.single.location, isNull);
      expect(txtResult.document!.text, '第一行\n第二行');

      final mdResult = await extractDocument(md, maxBytes: 4096);
      expect(mdResult.ok, isTrue);
      expect(mdResult.document!.kind, 'md');
      expect(mdResult.document!.text, contains('正文'));
    });

    test('UTF-8 BOM is stripped', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'bom.txt',
        [0xEF, 0xBB, 0xBF, ...utf8.encode('内容')],
      );
      final result = await extractDocument(file, maxBytes: 4096);
      expect(result.ok, isTrue);
      expect(result.document!.text, '内容');
    });

    test('GBK / invalid UTF-8 is a structured unsupported error', () async {
      final dir = _tempDir();
      // GBK bytes for "实验".
      final file = _write(dir, 'gbk.txt', const [0xCA, 0xB5, 0xD1, 0xE9]);
      final result = await extractDocument(file, maxBytes: 4096);
      _expectFailure(result, DocumentErrorKind.unsupported);
      expect(result.error!.message, contains('不是 UTF-8'));
    });

    test('UTF-16 is rejected with an actionable message', () async {
      final dir = _tempDir();
      final le = _write(dir, 'le.txt', const [0xFF, 0xFE, 0x41, 0x00]);
      final be = _write(dir, 'be.txt', const [0xFE, 0xFF, 0x00, 0x41]);

      final leResult = await extractDocument(le, maxBytes: 4096);
      final beResult = await extractDocument(be, maxBytes: 4096);
      _expectFailure(leResult, DocumentErrorKind.unsupported);
      _expectFailure(beResult, DocumentErrorKind.unsupported);
      expect(leResult.error!.message, contains('UTF-16'));
      expect(beResult.error!.message, contains('UTF-16'));
    });

    test('empty and whitespace-only files are empty', () async {
      final dir = _tempDir();
      final empty = _write(dir, 'empty.txt', const []);
      final spaces = _write(dir, 'spaces.txt', utf8.encode('  \n\t\n'));
      _expectFailure(
        await extractDocument(empty, maxBytes: 4096),
        DocumentErrorKind.empty,
      );
      _expectFailure(
        await extractDocument(spaces, maxBytes: 4096),
        DocumentErrorKind.empty,
      );
    });

    test('too large is reported before reading', () async {
      final dir = _tempDir();
      final file = _write(dir, 'big.txt', utf8.encode('x' * 100));
      final result = await extractDocument(file, maxBytes: 10);
      _expectFailure(result, DocumentErrorKind.tooLarge);
      expect(result.error!.message, contains('超过输入上限'));
    });

    test('legacy .doc / .ppt are explicitly unsupported', () async {
      final dir = _tempDir();
      final doc = _write(dir, 'old.doc', const [0xD0, 0xCF, 0x11, 0xE0]);
      final ppt = _write(dir, 'old.ppt', const [0xD0, 0xCF, 0x11, 0xE0]);
      final docResult = await extractDocument(doc, maxBytes: 4096);
      final pptResult = await extractDocument(ppt, maxBytes: 4096);
      _expectFailure(docResult, DocumentErrorKind.unsupported);
      _expectFailure(pptResult, DocumentErrorKind.unsupported);
      expect(docResult.error!.message, contains('.docx'));
      expect(pptResult.error!.message, contains('.pptx'));
    });

    test('unknown extension is unsupported', () async {
      final dir = _tempDir();
      final file = _write(dir, 'archive.xyz', utf8.encode('hello'));
      final result = await extractDocument(file, maxBytes: 4096);
      _expectFailure(result, DocumentErrorKind.unsupported);
    });

    test('repeated extraction of the same file is stable', () async {
      final dir = _tempDir();
      final file = _write(dir, 'repeat.txt', utf8.encode('重复添加'));
      final first = await extractDocument(file, maxBytes: 4096);
      final second = await extractDocument(file, maxBytes: 4096);
      expect(first.ok, isTrue);
      expect(second.ok, isTrue);
      expect(first.document!.text, second.document!.text);
    });
  });

  group('DOCX', () {
    final documentXml = _docxXml(
      '<w:p><w:r><w:t>第一段</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">第二段 </w:t></w:r>'
      '<w:r><w:tab/><w:t>带制表</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>第三段</w:t></w:r>'
      '<w:del><w:r><w:delText>已删除</w:delText></w:r></w:del></w:p>'
      '<w:p><w:r><w:instrText>HYPERLINK</w:instrText></w:r></w:p>',
    );

    test('extracts paragraphs with paragraph numbers', () async {
      final dir = _tempDir();
      final file = _write(dir, 'a.docx', _docxZip(documentXml));
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      final doc = result.document!;
      expect(doc.kind, 'docx');
      expect(doc.pages, 0);
      expect(doc.segments, hasLength(3));
      expect(doc.segments[0].location, '第 1 段');
      expect(doc.segments[0].text, '第一段');
      expect(doc.segments[1].location, '第 2 段');
      expect(doc.segments[1].text, '第二段 \t带制表');
      expect(doc.segments[2].location, '第 3 段');
      expect(doc.text, isNot(contains('已删除')));
      expect(doc.text, isNot(contains('HYPERLINK')));
    });

    test('macros are ignored and reported', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'macro.docx',
        _docxZip(documentXml, withMacro: true),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue);
      expect(result.document!.warning, contains('宏'));
    });

    test('missing document.xml is corrupt', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'missing.docx',
        _zip({'[Content_Types].xml': utf8.encode(_contentTypes)}),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.corrupt,
      );
    });

    test('malformed XML is corrupt', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'bad.docx',
        _docxZip('<w:document><w:body><w:p></w:document>'),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.corrupt,
      );
    });

    test('empty document is empty', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'empty.docx',
        _docxZip(_docxXml('<w:p><w:r><w:t>   </w:t></w:r></w:p>')),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.empty,
      );
    });

    test('DTD / entity declarations are rejected', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'dtd.docx',
        _docxZip(
          '<?xml version="1.0"?>'
          '<!DOCTYPE w:document [<!ENTITY xxe "boom">]>'
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:body><w:p><w:r><w:t>&xxe;</w:t></w:r></w:p></w:body>'
          '</w:document>',
        ),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.unsupported,
      );
    });

    test('encrypted OOXML is detected as encrypted', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'secret.docx',
        [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 1, 2, 3, 4],
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.encrypted,
      );
    });

    test('random bytes with a docx extension are corrupt', () async {
      final dir = _tempDir();
      final file = _write(dir, 'random.docx', utf8.encode('not a zip'));
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.corrupt,
      );
    });

    test('extracted text over maxBytes is too large, not truncated', () async {
      final dir = _tempDir();
      final long = List.filled(4000, '文档内容').join();
      final file = _write(
        dir,
        'long.docx',
        _docxZip(_docxXml('<w:p><w:r><w:t>$long</w:t></w:r></w:p>')),
      );
      final result = await extractDocument(file, maxBytes: 4096);
      _expectFailure(result, DocumentErrorKind.tooLarge);
      expect(result.error!.message, contains('未截断'));
    });
  });

  group('PPTX', () {
    test('extracts slide text in presentation order', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'deck.pptx',
        _pptxZip(
          slides: {
            'slide1': _slideXml('第一页内容'),
            'slide2': _slideXml('第二页内容'),
          },
          // Deliberately reverse the file-name order.
          order: ['slide2', 'slide1'],
        ),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      final doc = result.document!;
      expect(doc.kind, 'pptx');
      expect(doc.pages, 2);
      expect(doc.segments, hasLength(2));
      expect(doc.segments[0].location, '第 1 张幻灯片');
      expect(doc.segments[0].text, contains('第二页内容'));
      expect(doc.segments[1].location, '第 2 张幻灯片');
      expect(doc.segments[1].text, contains('第一页内容'));
    });

    test('missing presentation order falls back with a warning', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'nopres.pptx',
        _pptxZip(
          slides: {
            'slide1': _slideXml('唯一一页'),
          },
          includePresentation: false,
        ),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue);
      expect(result.document!.text, contains('唯一一页'));
      expect(result.document!.warning, contains('文件名顺序'));
    });

    test('one bad slide yields a partial success', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'partial.pptx',
        _pptxZip(
          slides: {
            'slide1': _slideXml('好的一页'),
            'slide2': '<p:sld><p:cSld>',
          },
          includePresentation: false,
        ),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue);
      expect(result.document!.segments, hasLength(1));
      expect(result.document!.text, contains('好的一页'));
      expect(result.document!.warning, contains('无法解析'));
    });

    test('slides without text are empty', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'empty.pptx',
        _pptxZip(slides: {'slide1': _slideXml('   ')}),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.empty,
      );
    });

    test('a PPTX with no slides is empty', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'noslides.pptx',
        _zip({'[Content_Types].xml': utf8.encode(_contentTypes)}),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.empty,
      );
    });

    test('macros are ignored and reported', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'macro.pptx',
        _pptxZip(
          slides: {'slide1': _slideXml('带宏')},
          withMacro: true,
        ),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue);
      expect(result.document!.warning, contains('宏'));
    });
  });

  group('PDF', () {
    test('text PDF is extracted per page', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'text.pdf',
        _textPdf([
          'BT /F1 12 Tf 72 712 Td (Hello PDF) Tj ET',
          'BT /F1 12 Tf 72 700 Td (Second page) Tj ET',
        ]),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      final doc = result.document!;
      expect(doc.kind, 'pdf');
      expect(doc.pages, 2);
      expect(doc.segments, hasLength(2));
      expect(doc.segments[0].location, '第 1 页');
      expect(doc.segments[0].text, contains('Hello PDF'));
      expect(doc.segments[1].location, '第 2 页');
      expect(doc.segments[1].text, contains('Second page'));
      expect(doc.warning, isNull);
    });

    test('FlateDecode content streams are decompressed', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'compressed.pdf',
        _textPdf(
          ['BT /F1 12 Tf 72 712 Td (Compressed text) Tj ET'],
          compressed: true,
        ),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(result.document!.text, contains('Compressed text'));
    });

    test('multiple content streams, TJ arrays and inherited resources work',
        () async {
      final dir = _tempDir();
      final file = _write(dir, 'streams.pdf', _multiStreamPdf());
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(result.document!.text, contains('Hello'));
      expect(result.document!.text, contains('World Again'));
    });

    test('Type0 font with ToUnicode extracts CJK text', () async {
      final dir = _tempDir();
      final file = _write(dir, 'cjk.pdf', _cjkPdf());
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue, reason: result.error?.message);
      expect(result.document!.text, '你好');
    });

    test('scanned/image-only PDF is unsupportedOcr', () async {
      final dir = _tempDir();
      final file = _write(dir, 'scan.pdf', _imageOnlyPdf());
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      _expectFailure(result, DocumentErrorKind.unsupportedOcr);
      expect(result.error!.message, contains('OCR'));
    });

    test('PDF without a text layer is unsupportedOcr', () async {
      final dir = _tempDir();
      final file = _write(dir, 'blank.pdf', _textPdf(['']));
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.unsupportedOcr,
      );
    });

    test('one empty page yields partial success with a warning', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'partial.pdf',
        _textPdf([
          'BT /F1 12 Tf 72 712 Td (Page one) Tj ET',
          '',
        ]),
      );
      final result = await extractDocument(file, maxBytes: 64 * 1024);
      expect(result.ok, isTrue);
      expect(result.document!.pages, 2);
      expect(result.document!.segments, hasLength(1));
      expect(result.document!.warning, contains('第 2 页'));
    });

    test('encrypted PDF is encrypted', () async {
      final dir = _tempDir();
      final source = latin1.decode(
        _textPdf(['BT /F1 12 Tf 72 712 Td (Secret) Tj ET']),
      );
      final file = _write(
        dir,
        'encrypted.pdf',
        latin1.encode(
          source.replaceFirst('trailer\n<<', 'trailer\n<< /Encrypt 99 0 R'),
        ),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.encrypted,
      );
    });

    test('corrupt PDF is corrupt', () async {
      final dir = _tempDir();
      final file = _write(
        dir,
        'corrupt.pdf',
        latin1.encode('%PDF-1.4\nthis is not really a pdf'),
      );
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.corrupt,
      );
    });

    test('non-PDF bytes with a pdf extension are corrupt', () async {
      final dir = _tempDir();
      final file = _write(dir, 'fake.pdf', utf8.encode('not a pdf at all'));
      _expectFailure(
        await extractDocument(file, maxBytes: 64 * 1024),
        DocumentErrorKind.corrupt,
      );
    });
  });

  group('limits and cancellation', () {
    test('missing file is a structured failure, not an exception', () async {
      final dir = _tempDir();
      final file = File('${dir.path}${Platform.pathSeparator}missing.txt');
      final result = await extractDocument(file, maxBytes: 4096);
      _expectFailure(result, DocumentErrorKind.corrupt);
    });

    test('invalid maxBytes is rejected', () async {
      final dir = _tempDir();
      final file = _write(dir, 'a.txt', utf8.encode('hello'));
      _expectFailure(
        await extractDocument(file, maxBytes: 0),
        DocumentErrorKind.tooLarge,
      );
    });

    test('cancellation returns the cancelled kind', () async {
      final dir = _tempDir();
      final file = _write(dir, 'cancel.txt', utf8.encode('hello'));
      final cancellation = ExtractionCancellation()..cancel();
      final result = await extractDocument(
        file,
        maxBytes: 4096,
        cancellation: cancellation,
      );
      _expectFailure(result, DocumentErrorKind.cancelled);
    });
  });
}

