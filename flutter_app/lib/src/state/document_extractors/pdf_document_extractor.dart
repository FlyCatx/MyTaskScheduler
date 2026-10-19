// Minimal, pure-Dart PDF text extraction.
//
// Why not a package? The pub packages that expose PDF text on Windows either
// need a native PDFium binary / a mobile plugin (`pdf_text` is Android+iOS
// only), or are commercially licensed (`syncfusion_flutter_pdf`). This parser
// covers the common text-PDF subset without new native dependencies:
//   * classic indirect objects, page trees, inherited resources
//   * FlateDecode (and uncompressed) content streams
//   * simple fonts (WinAnsi/Latin-1) and Type0 fonts with a ToUnicode CMap
//   * Tj / TJ / ' / " text operators
//
// It does not implement: OCR, encryption, linearized/xref-stream-only files,
// object streams (ObjStm), form XObjects, or every exotic font encoding. Those
// limits are reported as warnings or as an explicit unsupported/encrypted
// result rather than silently producing empty text.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../document_extraction_internal.dart';
import '../document_extraction_types.dart';

ExtractionResult extractPdf(ExtractionContext context, Uint8List bytes) {
  context.checkCancelled();
  final source = latin1.decode(bytes, allowInvalid: true);
  final header = source.length > 1024 ? source.substring(0, 1024) : source;
  if (!header.contains('%PDF-')) {
    context.fail(
      DocumentErrorKind.corrupt,
      '不是有效的 PDF（缺少 %PDF- 文件头）。',
      detail: 'missing PDF header',
    );
  }
  if (_hasEncryptionDictionary(source)) {
    context.fail(
      DocumentErrorKind.encrypted,
      'PDF 已加密（加密文档无法提取文字）。请先解除密码保护或另存为未加密 PDF。',
      detail: '/Encrypt present',
    );
  }

  final document = _PdfDocument(context, bytes, source);
  document.parseObjects();
  final pages = document.collectPages();
  context.checkCancelled();

  final segments = <DocumentSegment>[];
  final pageTexts = <String>[];
  final emptyPages = <int>[];
  var anyImage = false;

  for (var i = 0; i < pages.length; i++) {
    context.checkCancelled();
    final pageNumber = i + 1;
    final page = pages[i];
    if (document.pageHasImage(page)) anyImage = true;
    final text = document.extractPageText(page, pageNumber);
    if (text.isEmpty) {
      emptyPages.add(pageNumber);
      pageTexts.add('');
      continue;
    }
    pageTexts.add(text);
    segments.add(DocumentSegment(location: '第 $pageNumber 页', text: text));
  }

  if (segments.isEmpty) {
    final detail = anyImage
        ? 'PDF 只有图片 / 扫描页，没有可提取的文本层'
        : 'PDF 没有可提取的文本层（可能只有图形或使用了不支持的字体编码）';
    context.fail(
      DocumentErrorKind.unsupportedOcr,
      '该 PDF 没有文本层（看起来是扫描件或图片型 PDF），需要 OCR 才能提取文字；'
      '本版本不提供 OCR。请先用文字识别工具转成 TXT 后再添加。',
      detail: detail,
    );
  }

  final warnings = <String>[...document.warnings];
  if (emptyPages.isNotEmpty) {
    warnings.add('第 ${emptyPages.join('、')} 页没有文本层，已跳过该页内容');
  }
  if (document.usedObjectStreams) {
    warnings.add('PDF 使用了压缩对象流（ObjStm），已尽最大努力提取，部分文字可能缺失');
  }

  final text =
      normaliseExtractedText(pageTexts.where((t) => t.isNotEmpty).join('\n\n'));
  return context.succeed(
    text: text,
    kind: 'pdf',
    pages: pages.length,
    segments: segments,
    warning: combineWarnings(warnings),
  );
}

bool _hasEncryptionDictionary(String source) {
  final trailerIndex = source.lastIndexOf('trailer');
  if (trailerIndex >= 0) {
    final start = source.indexOf('<<', trailerIndex);
    if (start >= 0) {
      final dict = _balanced(source, start, '<<', '>>');
      if (dict != null && RegExp(r'/Encrypt\b').hasMatch(dict)) return true;
    }
  }
  // PDFs using cross-reference streams have no `trailer` keyword.
  return RegExp(r'/Encrypt\s+\d+\s+\d+\s+R').hasMatch(source);
}

// ---------------------------------------------------------------------------
// PDF object model / parser
// ---------------------------------------------------------------------------

class _PdfObject {
  _PdfObject({
    required this.number,
    required this.generation,
    required this.body,
    this.streamStart,
    this.streamEnd,
    this.lengthRef,
    this.directLength,
  });

  final int number;
  final int generation;
  final String body;
  int? streamStart;
  int? streamEnd;
  int? lengthRef;
  int? directLength;
  Uint8List? streamBytes;

  bool get hasStream => streamStart != null;
}

class _PdfPage {
  _PdfPage(this.object, this.resources);

  final _PdfObject object;
  final String? resources;
}

class _PdfValue {
  const _PdfValue.raw(this.raw) : ref = null;
  const _PdfValue.ref(this.ref) : raw = null;

  final String? raw;
  final int? ref;
}

class _PdfDocument {
  _PdfDocument(this.context, this.bytes, this.source);

  final ExtractionContext context;
  final Uint8List bytes;
  final String source;
  final Map<int, _PdfObject> objects = {};
  final Map<int, _PdfFont?> _fonts = {};
  final List<String> warnings = [];
  Map<String, int>? _globalFontMapCache;
  bool usedObjectStreams = false;

  void parseObjects() {
    final pattern = RegExp(r'(\d{1,10})\s+(\d{1,5})\s+obj\b');
    var searchStart = 0;
    var found = 0;
    while (true) {
      final matches = pattern.allMatches(source, searchStart).iterator;
      if (!matches.moveNext()) break;
      final match = matches.current;
      context.checkCancelled();
      final headerEnd = match.end;
      final number = int.parse(match.group(1)!);
      final generation = int.parse(match.group(2)!);
      final endobj = source.indexOf('endobj', headerEnd);
      if (endobj < 0) break;

      final streamIndex = _findToken(source, 'stream', headerEnd, endobj);
      if (streamIndex >= 0) {
        final body = source.substring(headerEnd, streamIndex);
        var streamStart = streamIndex + 'stream'.length;
        if (streamStart < source.length &&
            source.codeUnitAt(streamStart) == 0x0D) {
          streamStart++;
        }
        if (streamStart < source.length &&
            source.codeUnitAt(streamStart) == 0x0A) {
          streamStart++;
        }

        int? lengthRef;
        int? directLength;
        final refMatch =
            RegExp(r'/Length\s+(\d+)\s+(\d+)\s+R').firstMatch(body);
        if (refMatch != null) {
          lengthRef = int.parse(refMatch.group(1)!);
        } else {
          final directMatch =
              RegExp(r'/Length\s+(\d+)(?![0-9])').firstMatch(body);
          if (directMatch != null) {
            directLength = int.parse(directMatch.group(1)!);
          }
        }

        int? streamEnd;
        if (directLength != null &&
            streamStart + directLength <= bytes.length) {
          final candidate = streamStart + directLength;
          final after = _skipWhitespace(source, candidate);
          if (source.startsWith('endstream', after)) {
            streamEnd = candidate;
          }
        }
        streamEnd ??= _fallbackStreamEnd(streamStart);
        if (streamEnd == null) {
          context.fail(
            DocumentErrorKind.corrupt,
            'PDF 的流对象（$number $generation）缺少 endstream，文件可能已损坏。',
          );
        }

        final object = _PdfObject(
          number: number,
          generation: generation,
          body: body,
          streamStart: streamStart,
          streamEnd: streamEnd,
          lengthRef: lengthRef,
          directLength: directLength,
        );
        object.streamBytes =
            Uint8List.sublistView(bytes, streamStart, streamEnd);
        objects[number] = object;
        found++;

        final endstream = source.indexOf('endstream', streamEnd);
        final nextEndobj = endstream < 0
            ? source.indexOf('endobj', streamEnd)
            : source.indexOf('endobj', endstream + 'endstream'.length);
        if (nextEndobj < 0) break;
        searchStart = nextEndobj + 'endobj'.length;
      } else {
        final body = source.substring(headerEnd, endobj);
        objects[number] = _PdfObject(
          number: number,
          generation: generation,
          body: body,
        );
        found++;
        searchStart = endobj + 'endobj'.length;
      }
    }

    if (found == 0) {
      context.fail(
        DocumentErrorKind.corrupt,
        'PDF 中没有找到可解析的对象，文件可能已损坏。',
        detail: 'no indirect objects',
      );
    }

    _resolveIndirectStreamLengths();

    if (RegExp(r'/Type\s*/ObjStm\b').hasMatch(source)) {
      usedObjectStreams = true;
    }
  }

  void _resolveIndirectStreamLengths() {
    for (final object in objects.values.toList(growable: false)) {
      final ref = object.lengthRef;
      if (ref == null || object.streamStart == null) continue;
      final lengthObject = objects[ref];
      if (lengthObject == null || lengthObject.hasStream) continue;
      final length = int.tryParse(lengthObject.body.trim());
      if (length == null || length < 0) continue;
      final end = object.streamStart! + length;
      if (end > bytes.length) continue;
      final after = _skipWhitespace(source, end);
      if (!source.startsWith('endstream', after)) continue;
      object.streamEnd = end;
      object.streamBytes =
          Uint8List.sublistView(bytes, object.streamStart!, end);
    }
  }

  int? _fallbackStreamEnd(int streamStart) {
    final endstream = source.indexOf('endstream', streamStart);
    if (endstream < 0) return null;
    var end = endstream;
    if (end > streamStart && source.codeUnitAt(end - 1) == 0x0A) end--;
    if (end > streamStart && source.codeUnitAt(end - 1) == 0x0D) end--;
    return end;
  }

  List<_PdfPage> collectPages() {
    final pages = <_PdfPage>[];
    final visited = <int>{};

    _PdfObject? catalog;
    for (final object in objects.values) {
      if (RegExp(r'/Type\s*/Catalog\b').hasMatch(object.body)) {
        catalog = object;
        break;
      }
    }

    if (catalog != null) {
      final pagesValue = _readValue(catalog.body, 'Pages');
      if (pagesValue?.ref != null) {
        final root = objects[pagesValue!.ref!];
        if (root != null) _visitPageNode(root, null, 0, pages, visited);
      }
    }

    if (pages.isEmpty) {
      warnings.add('PDF 缺少可用的页面树，已按对象编号提取页面。');
      final pageObjects = <_PdfObject>[];
      for (final object in objects.values) {
        if (RegExp(r'/Type\s*/Page\b').hasMatch(object.body)) {
          pageObjects.add(object);
        }
      }
      pageObjects.sort((a, b) => a.number.compareTo(b.number));
      for (final object in pageObjects) {
        pages.add(_PdfPage(object, _resourcesOf(object, null)));
      }
    }

    if (pages.isEmpty) {
      if (usedObjectStreams) {
        context.fail(
          DocumentErrorKind.unsupported,
          '该 PDF 的页面结构存放在压缩对象流（ObjStm）中，当前的最小解析器无法读取。'
          '请用 PDF 阅读器另存为“优化/非压缩”PDF，或直接复制文字为 TXT。',
          detail: 'ObjStm-only page tree',
        );
      }
      context.fail(
        DocumentErrorKind.corrupt,
        'PDF 中没有找到任何页面，文件可能已损坏。',
        detail: 'no /Type /Page',
      );
    }
    return pages;
  }

  void _visitPageNode(
    _PdfObject node,
    String? inheritedResources,
    int depth,
    List<_PdfPage> pages,
    Set<int> visited,
  ) {
    if (depth > 64) {
      context.fail(
        DocumentErrorKind.corrupt,
        'PDF 页面树嵌套过深，文件结构异常。',
      );
    }
    if (!visited.add(node.number)) return;

    final resources = _resourcesOf(node, inheritedResources);
    final type = _nameOf(node.body, 'Type');
    if (type == 'Pages') {
      for (final ref in _arrayRefs(node.body, 'Kids')) {
        final child = objects[ref];
        if (child != null) {
          _visitPageNode(child, resources, depth + 1, pages, visited);
        }
      }
      return;
    }
    if (type == 'Page' || _readValue(node.body, 'Contents') != null) {
      pages.add(_PdfPage(node, resources));
    }
  }

  String? _resourcesOf(_PdfObject node, String? inherited) {
    final value = _readValue(node.body, 'Resources');
    if (value == null) return inherited;
    if (value.ref != null) return objects[value.ref!]?.body ?? inherited;
    return value.raw ?? inherited;
  }

  String extractPageText(_PdfPage page, int pageNumber) {
    final contentRefs = _contentRefs(page.object);
    final buffer = StringBuffer();
    final fontMap = fontMapFor(page.resources);
    for (final ref in contentRefs) {
      context.checkCancelled();
      final object = objects[ref];
      if (object == null) {
        warnings.add('第 $pageNumber 页引用的内容流对象 $ref 缺失');
        continue;
      }
      final data = decodeStream(object, pageNumber);
      if (data == null) continue;
      final interpreter = _ContentInterpreter(
        this,
        fontMap,
        data,
        pageNumber,
      );
      final text = interpreter.run();
      if (text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(text);
      }
    }
    return normaliseExtractedText(buffer.toString());
  }

  List<int> _contentRefs(_PdfObject pageObject) {
    final value = _readValue(pageObject.body, 'Contents');
    if (value == null) return const [];
    if (value.ref != null) {
      final object = objects[value.ref!];
      if (object == null) return const [];
      final trimmed = object.body.trimLeft();
      if (trimmed.startsWith('[')) return _refsInArray(object.body);
      return [value.ref!];
    }
    final raw = value.raw;
    if (raw == null) return const [];
    if (raw.trimLeft().startsWith('[')) return _refsInArray(raw);
    return const [];
  }

  Map<String, int> fontMapFor(String? resources) {
    if (resources == null || resources.trim().isEmpty) {
      return _globalFontMap();
    }
    final fontValue = _readValue(resources, 'Font');
    if (fontValue == null) return _globalFontMap();
    String? dict;
    if (fontValue.ref != null) {
      dict = objects[fontValue.ref!]?.body;
    } else {
      dict = fontValue.raw;
    }
    if (dict == null) return _globalFontMap();
    final map = _fontRefs(dict);
    return map.isEmpty ? _globalFontMap() : map;
  }

  Map<String, int> _globalFontMap() {
    final cached = _globalFontMapCache;
    if (cached != null) return cached;
    final map = <String, int>{};
    for (final object in objects.values) {
      final fontValue = _readValue(object.body, 'Font');
      if (fontValue == null) continue;
      String? dict;
      if (fontValue.ref != null) {
        dict = objects[fontValue.ref!]?.body;
      } else {
        dict = fontValue.raw;
      }
      if (dict == null) continue;
      for (final entry in _fontRefs(dict).entries) {
        map.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _globalFontMapCache = map;
    return map;
  }

  Map<String, int> _fontRefs(String dict) {
    final map = <String, int>{};
    final pattern = RegExp(r'/([A-Za-z0-9_.+-]+)\s+(\d+)\s+\d+\s+R');
    for (final match in pattern.allMatches(dict)) {
      map[match.group(1)!] = int.parse(match.group(2)!);
    }
    return map;
  }

  _PdfFont? fontFor(int ref) {
    if (_fonts.containsKey(ref)) return _fonts[ref];
    final object = objects[ref];
    if (object == null) {
      _fonts[ref] = null;
      return null;
    }
    final subtype = _nameOf(object.body, 'Subtype') ?? '';
    final isType0 = subtype == 'Type0';
    _PdfCMap? cmap;
    final toUnicode = _readValue(object.body, 'ToUnicode');
    if (toUnicode?.ref != null) {
      final cmapObject = objects[toUnicode!.ref!];
      if (cmapObject != null) {
        final data = decodeStream(cmapObject, null);
        if (data != null) {
          cmap = _PdfCMap.parse(latin1.decode(data, allowInvalid: true));
        }
      }
    }
    if (isType0 && cmap == null) {
      warnings.add('PDF 使用了缺少 ToUnicode 映射的 Type0 字体，部分文字可能无法还原');
    }
    final encodingValue = _readValue(object.body, 'Encoding');
    final encodingRaw = encodingValue?.raw ?? '';
    final encoding = encodingRaw.toLowerCase();
    if (encodingRaw.contains('Differences')) {
      warnings.add('PDF 字体使用了 Differences 编码，部分字符可能不准确');
    }
    if (!isType0 && cmap == null && encoding.contains('macroman')) {
      warnings.add('PDF 使用了 MacRoman 字体编码，部分字符可能不准确');
    }
    final font = _PdfFont(
      objectNumber: ref,
      cmap: cmap,
      isType0: isType0,
    );
    _fonts[ref] = font;
    return font;
  }

  Uint8List? decodeStream(_PdfObject object, int? pageNumber) {
    final raw = object.streamBytes;
    if (raw == null) return null;
    final filterValue = _readValue(object.body, 'Filter');
    final filter = filterValue?.raw ?? '';
    if (filter.trim().isEmpty) return raw;

    if (filter.contains('FlateDecode')) {
      try {
        return const ZLibDecoder().decodeBytes(
          raw,
          maxOutputSize: context.maxPartBytes,
        );
      } catch (_) {
        try {
          return const ZLibDecoder().decodeBytes(
            raw,
            raw: true,
            maxOutputSize: context.maxPartBytes,
          );
        } catch (_) {
          final where = pageNumber == null ? '' : '（第 $pageNumber 页）';
          warnings.add('PDF 内容流$where解压失败，已跳过该流');
          return null;
        }
      }
    }
    if (filter.contains('ASCIIHexDecode')) {
      return _asciiHexDecode(raw);
    }
    if (filter.contains('Crypt')) {
      warnings.add('PDF 内容流使用了 Crypt 过滤器，已跳过');
      return null;
    }
    final where = pageNumber == null ? '' : '（第 $pageNumber 页）';
    warnings.add('PDF 内容流$where使用了暂不支持的过滤器 $filter，已跳过');
    return null;
  }

  bool pageHasImage(_PdfPage page) {
    final resources = page.resources;
    if (resources == null) return false;
    final xobject = _readValue(resources, 'XObject');
    if (xobject == null) return false;
    String? dict;
    if (xobject.ref != null) {
      dict = objects[xobject.ref!]?.body;
    } else {
      dict = xobject.raw;
    }
    if (dict == null) return false;
    final pattern = RegExp(r'/([A-Za-z0-9_.+-]+)\s+(\d+)\s+\d+\s+R');
    for (final match in pattern.allMatches(dict)) {
      final object = objects[int.parse(match.group(2)!)];
      if (object != null &&
          RegExp(r'/Subtype\s*/Image\b').hasMatch(object.body)) {
        return true;
      }
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// PDF value helpers
// ---------------------------------------------------------------------------

_PdfValue? _readValue(String body, String key) {
  final pattern = RegExp(
    '/${RegExp.escape(key)}(?![A-Za-z0-9#_.+-])',
  );
  final match = pattern.firstMatch(body);
  if (match == null) return null;
  final index = _skipWhitespace(body, match.end);
  if (index >= body.length) return null;

  if (body.startsWith('<<', index)) {
    final raw = _balanced(body, index, '<<', '>>');
    return raw == null ? null : _PdfValue.raw(raw);
  }
  if (body.codeUnitAt(index) == 0x5B) {
    final raw = _balanced(body, index, '[', ']');
    return raw == null ? null : _PdfValue.raw(raw);
  }
  if (body.codeUnitAt(index) == 0x2F) {
    final name = _readName(body, index);
    return _PdfValue.raw(name);
  }
  if (body.codeUnitAt(index) == 0x3C) {
    final end = body.indexOf('>', index);
    if (end < 0) return null;
    return _PdfValue.raw(body.substring(index, end + 1));
  }

  final ref =
      RegExp(r'(\d+)\s+(\d+)\s+R(?![A-Za-z0-9])').matchAsPrefix(body, index);
  if (ref != null) {
    return _PdfValue.ref(int.parse(ref.group(1)!));
  }

  final token = _readToken(body, index);
  return token == null ? null : _PdfValue.raw(token);
}

String? _nameOf(String body, String key) {
  final value = _readValue(body, key);
  if (value?.raw == null) return null;
  return value!.raw!.trim();
}

List<int> _arrayRefs(String body, String key) {
  final value = _readValue(body, key);
  if (value == null) return const [];
  if (value.ref != null) return const [];
  return _refsInArray(value.raw ?? '');
}

List<int> _refsInArray(String raw) {
  final refs = <int>[];
  final pattern = RegExp(r'(\d+)\s+(\d+)\s+R(?![A-Za-z0-9])');
  for (final match in pattern.allMatches(raw)) {
    refs.add(int.parse(match.group(1)!));
  }
  return refs;
}

// ---------------------------------------------------------------------------
// PDF lexing helpers
// ---------------------------------------------------------------------------

bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

bool _isDelimiter(int c) =>
    _isWhitespace(c) ||
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x7B ||
    c == 0x7D ||
    c == 0x2F ||
    c == 0x25;

int _skipWhitespace(String source, int index) {
  var i = index;
  while (i < source.length && _isWhitespace(source.codeUnitAt(i))) {
    i++;
  }
  return i;
}

int _findToken(String source, String token, int start, int limit) {
  var index = start;
  while (index < limit) {
    final found = source.indexOf(token, index);
    if (found < 0 || found >= limit) return -1;
    final before = found == 0 ? 0x20 : source.codeUnitAt(found - 1);
    final after = found + token.length >= source.length
        ? 0x20
        : source.codeUnitAt(found + token.length);
    if (_isDelimiter(before) && _isDelimiter(after)) return found;
    index = found + 1;
  }
  return -1;
}

String? _balanced(String source, int start, String open, String close) {
  if (!source.startsWith(open, start)) return null;
  var depth = 0;
  var i = start;
  while (i < source.length) {
    if (source.startsWith(open, i)) {
      depth++;
      i += open.length;
      continue;
    }
    if (source.startsWith(close, i)) {
      depth--;
      i += close.length;
      if (depth == 0) return source.substring(start, i);
      continue;
    }
    i++;
  }
  return null;
}

String? _readName(String body, int start) {
  var i = start + 1;
  final buffer = StringBuffer();
  while (i < body.length && !_isDelimiter(body.codeUnitAt(i))) {
    buffer.writeCharCode(body.codeUnitAt(i));
    i++;
  }
  return buffer.toString();
}

String? _readToken(String body, int start) {
  var i = start;
  final buffer = StringBuffer();
  while (i < body.length && !_isDelimiter(body.codeUnitAt(i))) {
    buffer.writeCharCode(body.codeUnitAt(i));
    i++;
  }
  return buffer.isEmpty ? null : buffer.toString();
}

Uint8List? _asciiHexDecode(Uint8List input) {
  final digits = <int>[];
  for (final byte in input) {
    if (byte == 0x3E) break; // '>'
    final value = _hexValue(byte);
    if (value >= 0) digits.add(value);
  }
  if (digits.length.isOdd) digits.add(0);
  final out = Uint8List(digits.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (digits[i * 2] << 4) | digits[i * 2 + 1];
  }
  return out;
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

// ---------------------------------------------------------------------------
// Fonts / ToUnicode CMaps
// ---------------------------------------------------------------------------

class _PdfFont {
  _PdfFont({
    required this.objectNumber,
    required this.cmap,
    required this.isType0,
  });

  final int objectNumber;
  final _PdfCMap? cmap;
  final bool isType0;

  String decode(Uint8List data) {
    final out = StringBuffer();
    var i = 0;
    while (i < data.length) {
      final match = cmap?.matchAt(
        data,
        i,
        defaultLength: isType0 ? 2 : 1,
      );
      var length = match?.length ?? (isType0 ? 2 : 1);
      if (i + length > data.length) length = data.length - i;
      var code = match?.code ?? 0;
      if (match == null) {
        for (var j = 0; j < length; j++) {
          code = (code << 8) | data[i + j];
        }
      }
      final mapped = cmap?.chars[code] ?? _fallback(code, isType0: isType0);
      out.write(mapped);
      i += length;
    }
    return out.toString();
  }

  String _fallback(int code, {required bool isType0}) {
    if (isType0) {
      if (code >= 0x20 && code <= 0x10FFFF) {
        if (code >= 0xD800 && code <= 0xDFFF) return '';
        return String.fromCharCode(code);
      }
      return '';
    }
    return _winAnsiChar(code & 0xFF);
  }
}

class _CodeMatch {
  const _CodeMatch(this.code, this.length);

  final int code;
  final int length;
}

class _PdfCodeSpace {
  const _PdfCodeSpace(this.length, this.low, this.high);

  final int length;
  final int low;
  final int high;

  bool contains(int code) => code >= low && code <= high;
}

class _PdfCMap {
  _PdfCMap();

  final Map<int, String> chars = {};
  final List<_PdfCodeSpace> codeSpaces = [];

  static _PdfCMap? parse(String text) {
    final cmap = _PdfCMap();

    for (final block in RegExp(
      r'begincodespacerange([\s\S]*?)endcodespacerange',
    ).allMatches(text)) {
      for (final pair in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(block.group(1)!)) {
        final lowHex = pair.group(1)!;
        final highHex = pair.group(2)!;
        final length = lowHex.length ~/ 2;
        if (length <= 0 || length != highHex.length ~/ 2) continue;
        cmap.codeSpaces.add(
          _PdfCodeSpace(
            length,
            int.parse(lowHex, radix: 16),
            int.parse(highHex, radix: 16),
          ),
        );
      }
    }

    for (final block in RegExp(
      r'beginbfchar([\s\S]*?)endbfchar',
    ).allMatches(text)) {
      for (final pair in RegExp(
        r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
      ).allMatches(block.group(1)!)) {
        final mapped = _hexToUnicode(pair.group(2)!);
        if (mapped.isEmpty) continue;
        cmap.chars[int.parse(pair.group(1)!, radix: 16)] = mapped;
      }
    }

    for (final block in RegExp(
      r'beginbfrange([\s\S]*?)endbfrange',
    ).allMatches(text)) {
      _parseRange(block.group(1)!, cmap);
    }

    return cmap.chars.isEmpty && cmap.codeSpaces.isEmpty ? null : cmap;
  }

  static void _parseRange(String block, _PdfCMap cmap) {
    final pattern = RegExp(
      r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:<([0-9A-Fa-f]+)>|\[([^\]]*)\])',
    );
    for (final match in pattern.allMatches(block)) {
      final low = int.parse(match.group(1)!, radix: 16);
      final high = int.parse(match.group(2)!, radix: 16);
      if (high < low) continue;
      final span = high - low;
      if (span > 4096) continue; // avoid giant maps from pathological ranges

      final direct = match.group(3);
      if (direct != null) {
        for (var offset = 0; offset <= span; offset++) {
          final mapped = _hexToUnicode(
            _incrementUtf16Hex(direct, offset),
          );
          if (mapped.isNotEmpty) cmap.chars[low + offset] = mapped;
        }
        continue;
      }
      final list = match.group(4);
      if (list == null) continue;
      final destinations = RegExp(r'<([0-9A-Fa-f]+)>')
          .allMatches(list)
          .map((m) => m.group(1)!)
          .toList(growable: false);
      for (var offset = 0;
          offset < destinations.length && offset <= span;
          offset++) {
        final mapped = _hexToUnicode(destinations[offset]);
        if (mapped.isNotEmpty) cmap.chars[low + offset] = mapped;
      }
    }
  }

  _CodeMatch? matchAt(
    Uint8List data,
    int offset, {
    int defaultLength = 1,
  }) {
    _PdfCodeSpace? best;
    var bestCode = 0;
    for (final space in codeSpaces) {
      if (offset + space.length > data.length) continue;
      var code = 0;
      for (var i = 0; i < space.length; i++) {
        code = (code << 8) | data[offset + i];
      }
      if (space.contains(code)) {
        if (best == null || space.length > best.length) {
          best = space;
          bestCode = code;
        }
      }
    }
    if (best != null) return _CodeMatch(bestCode, best.length);

    // No matching code space: fall back to the font's normal code length. The
    // font still gets a chance to use its chars map / fallback.
    var fallbackLength = defaultLength < 1 ? 1 : defaultLength;
    if (offset + fallbackLength > data.length) fallbackLength = 1;
    var code = 0;
    for (var i = 0; i < fallbackLength; i++) {
      code = (code << 8) | data[offset + i];
    }
    return _CodeMatch(code, fallbackLength);
  }
}

String _hexToUnicode(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (clean.isEmpty) return '';
  final buffer = StringBuffer();
  if (clean.length % 4 == 0) {
    for (var i = 0; i < clean.length; i += 4) {
      buffer.writeCharCode(int.parse(clean.substring(i, i + 4), radix: 16));
    }
    return buffer.toString();
  }
  if (clean.length.isEven) {
    for (var i = 0; i < clean.length; i += 2) {
      buffer.writeCharCode(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return buffer.toString();
  }
  return '';
}

String _incrementUtf16Hex(String hex, int offset) {
  final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (clean.isEmpty) return hex;
  final units = <int>[];
  if (clean.length % 4 == 0) {
    for (var i = 0; i < clean.length; i += 4) {
      units.add(int.parse(clean.substring(i, i + 4), radix: 16));
    }
  } else if (clean.length.isEven) {
    for (var i = 0; i < clean.length; i += 2) {
      units.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
  } else {
    return hex;
  }
  var carry = offset;
  for (var i = units.length - 1; i >= 0 && carry > 0; i--) {
    final value = units[i] + carry;
    units[i] = value & 0xFFFF;
    carry = value >> 16;
  }
  return units.map((unit) => unit.toRadixString(16).padLeft(4, '0')).join();
}

const _winAnsiSpecial = <int, String>{
  0x80: '\u20AC',
  0x82: '\u201A',
  0x83: '\u0192',
  0x84: '\u201E',
  0x85: '\u2026',
  0x86: '\u2020',
  0x87: '\u2021',
  0x88: '\u02C6',
  0x89: '\u2030',
  0x8A: '\u0160',
  0x8B: '\u2039',
  0x8C: '\u0152',
  0x8E: '\u017D',
  0x91: '\u2018',
  0x92: '\u2019',
  0x93: '\u201C',
  0x94: '\u201D',
  0x95: '\u2022',
  0x96: '\u2013',
  0x97: '\u2014',
  0x98: '\u02DC',
  0x99: '\u2122',
  0x9A: '\u0161',
  0x9B: '\u203A',
  0x9C: '\u0153',
  0x9E: '\u017E',
  0x9F: '\u0178',
};

String _winAnsiChar(int byte) {
  final special = _winAnsiSpecial[byte];
  if (special != null) return special;
  if (byte >= 0x20 && byte != 0x7F) {
    return String.fromCharCode(byte);
  }
  return '';
}

// ---------------------------------------------------------------------------
// Content-stream interpreter
// ---------------------------------------------------------------------------

class _PdfName {
  const _PdfName(this.value);

  final String value;
}

class _ContentInterpreter {
  _ContentInterpreter(this.document, this.fontMap, this.bytes, this.pageNumber);

  final _PdfDocument document;
  final Map<String, int> fontMap;
  final Uint8List bytes;
  final int pageNumber;

  final StringBuffer _out = StringBuffer();
  final List<Object?> _stack = [];
  final List<List<Object?>> _arrays = [];
  var _dictDepth = 0;
  _PdfFont? _font;
  var _pendingBreak = false;
  var _pendingSpace = false;
  var _hadText = false;
  var _lastChar = '';

  String run() {
    final source = latin1.decode(bytes, allowInvalid: true);
    var i = 0;
    while (i < source.length) {
      final c = source.codeUnitAt(i);
      if (_isWhitespace(c)) {
        i++;
        continue;
      }
      if (c == 0x25) {
        while (i < source.length) {
          final current = source.codeUnitAt(i);
          if (current == 0x0A || current == 0x0D) break;
          i++;
        }
        continue;
      }
      if (c == 0x28) {
        final literal = _readLiteral(source, i);
        _addOperand(literal.bytes);
        i = literal.next;
        continue;
      }
      if (c == 0x3C) {
        if (i + 1 < source.length && source.codeUnitAt(i + 1) == 0x3C) {
          _dictDepth++;
          i += 2;
          continue;
        }
        final hex = _readHex(source, i);
        _addOperand(hex.bytes);
        i = hex.next;
        continue;
      }
      if (c == 0x3E) {
        if (i + 1 < source.length && source.codeUnitAt(i + 1) == 0x3E) {
          if (_dictDepth > 0) _dictDepth--;
          i += 2;
          continue;
        }
        i++;
        continue;
      }
      if (c == 0x5B) {
        _arrays.add(<Object?>[]);
        i++;
        continue;
      }
      if (c == 0x5D) {
        if (_arrays.isNotEmpty) _addOperand(_arrays.removeLast());
        i++;
        continue;
      }
      if (c == 0x2F) {
        final name = _readName(source, i);
        _addOperand(_PdfName(name ?? ''));
        i += 1 + (name?.length ?? 0);
        continue;
      }
      if (c == 0x27) {
        _apply("'");
        i++;
        continue;
      }
      if (c == 0x22) {
        _apply('"');
        i++;
        continue;
      }
      final number = _readNumber(source, i);
      if (number != null) {
        _addOperand(number.value);
        i = number.next;
        continue;
      }

      var end = i;
      while (end < source.length && !_isDelimiter(source.codeUnitAt(end))) {
        end++;
      }
      if (end == i) {
        i++;
        continue;
      }
      final operator = source.substring(i, end);
      i = end;
      if (operator == 'BI') {
        i = _skipInlineImage(source, i);
        _stack.clear();
        _arrays.clear();
        continue;
      }
      _apply(operator);
    }
    return normaliseExtractedText(_out.toString());
  }

  void _addOperand(Object? value) {
    if (_dictDepth > 0) return;
    if (_arrays.isNotEmpty) {
      _arrays.last.add(value);
    } else {
      _stack.add(value);
    }
  }

  void _apply(String operator) {
    if (_dictDepth > 0) return;
    switch (operator) {
      case 'true':
      case 'false':
      case 'null':
        _addOperand(operator);
        return;
      case 'Tf':
        final name = _stack.length >= 2 ? _stack[_stack.length - 2] : null;
        if (name is _PdfName) {
          final ref = fontMap[name.value];
          _font = ref == null ? null : document.fontFor(ref);
        }
        break;
      case 'Tj':
        final string = _lastString();
        if (string != null) _show(string);
        break;
      case 'TJ':
        final array = _lastArray();
        if (array != null) {
          for (final item in array) {
            if (item is Uint8List) {
              _show(item);
            } else if (item is num && item < -100) {
              _append(' ');
            }
          }
        }
        break;
      case "'":
        _newline();
        final string = _lastString();
        if (string != null) _show(string);
        break;
      case '"':
        _newline();
        final string = _lastString();
        if (string != null) _show(string);
        break;
      case 'Td':
      case 'TD':
        if (_stack.length >= 2 &&
            _stack[_stack.length - 1] is num &&
            _stack[_stack.length - 2] is num) {
          final tx = _stack[_stack.length - 2] as num;
          final ty = _stack[_stack.length - 1] as num;
          if (ty.abs() > 0.01) {
            _pendingBreak = true;
          } else if (tx > 0.01) {
            _pendingSpace = true;
          }
        }
        break;
      case 'T*':
        _newline();
        break;
      case 'Tm':
        if (_hadText) _pendingBreak = true;
        break;
      case 'BT':
        if (_hadText && _out.isNotEmpty) _pendingBreak = true;
        break;
      case 'ET':
        if (_hadText) _newline();
        break;
      case 'Do':
        // Form XObjects are not interpreted (documented limitation). Image
        // XObjects are detected separately for the OCR message.
        break;
    }
    _stack.clear();
  }

  Uint8List? _lastString() {
    for (var i = _stack.length - 1; i >= 0; i--) {
      final value = _stack[i];
      if (value is Uint8List) return value;
    }
    return null;
  }

  List<Object?>? _lastArray() {
    for (var i = _stack.length - 1; i >= 0; i--) {
      final value = _stack[i];
      if (value is List<Object?>) return value;
    }
    return null;
  }

  void _show(Uint8List data) {
    if (data.isEmpty) return;
    if (_pendingBreak && _out.isNotEmpty) _newline();
    _pendingBreak = false;
    if (_pendingSpace && _out.isNotEmpty && _lastChar.trim().isNotEmpty) {
      _append(' ');
    }
    _pendingSpace = false;
    final text = _font?.decode(data) ?? _decodeFallback(data);
    if (text.isEmpty) return;
    _append(text);
    _hadText = true;
  }

  String _decodeFallback(Uint8List data) {
    final buffer = StringBuffer();
    for (final byte in data) {
      buffer.write(_winAnsiChar(byte));
    }
    return buffer.toString();
  }

  void _append(String text) {
    if (text.isEmpty) return;
    _out.write(text);
    _lastChar = text[text.length - 1];
  }

  void _newline() {
    if (_out.isEmpty || _lastChar == '\n') return;
    _append('\n');
  }

  int _skipInlineImage(String source, int index) {
    final id = source.indexOf('ID', index);
    if (id < 0) return source.length;
    var start = id + 2;
    if (start < source.length && _isWhitespace(source.codeUnitAt(start))) {
      start++;
    }
    var search = start;
    while (search + 1 < source.length) {
      final found = source.indexOf('EI', search);
      if (found < 0) return source.length;
      final before = found == 0 ? 0x20 : source.codeUnitAt(found - 1);
      final after =
          found + 2 >= source.length ? 0x20 : source.codeUnitAt(found + 2);
      if (_isDelimiter(before) && _isDelimiter(after)) {
        return found + 2;
      }
      search = found + 2;
    }
    return source.length;
  }
}

({Uint8List bytes, int next}) _readLiteral(String source, int start) {
  final out = <int>[];
  var depth = 1;
  var i = start + 1;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 0x5C) {
      i++;
      if (i >= source.length) break;
      final escaped = source.codeUnitAt(i);
      switch (escaped) {
        case 0x6E: // n
          out.add(0x0A);
          i++;
          break;
        case 0x72: // r
          out.add(0x0D);
          i++;
          break;
        case 0x74: // t
          out.add(0x09);
          i++;
          break;
        case 0x62: // b
          out.add(0x08);
          i++;
          break;
        case 0x66: // f
          out.add(0x0C);
          i++;
          break;
        case 0x28:
        case 0x29:
        case 0x5C:
          out.add(escaped);
          i++;
          break;
        case 0x0D:
          i++;
          if (i < source.length && source.codeUnitAt(i) == 0x0A) i++;
          break;
        case 0x0A:
          i++;
          break;
        default:
          if (escaped >= 0x30 && escaped <= 0x37) {
            var value = 0;
            var digits = 0;
            while (digits < 3 &&
                i < source.length &&
                source.codeUnitAt(i) >= 0x30 &&
                source.codeUnitAt(i) <= 0x37) {
              value = value * 8 + (source.codeUnitAt(i) - 0x30);
              i++;
              digits++;
            }
            out.add(value & 0xFF);
          } else {
            out.add(escaped);
            i++;
          }
      }
      continue;
    }
    if (c == 0x28) {
      depth++;
      out.add(c);
      i++;
      continue;
    }
    if (c == 0x29) {
      depth--;
      i++;
      if (depth == 0) break;
      out.add(c);
      continue;
    }
    out.add(c);
    i++;
  }
  return (bytes: Uint8List.fromList(out), next: i);
}

({Uint8List bytes, int next}) _readHex(String source, int start) {
  final digits = <int>[];
  var i = start + 1;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    i++;
    if (c == 0x3E) break;
    final value = _hexValue(c);
    if (value >= 0) digits.add(value);
  }
  if (digits.length.isOdd) digits.add(0);
  final out = Uint8List(digits.length ~/ 2);
  for (var j = 0; j < out.length; j++) {
    out[j] = (digits[j * 2] << 4) | digits[j * 2 + 1];
  }
  return (bytes: out, next: i);
}

({num value, int next})? _readNumber(String source, int start) {
  var i = start;
  if (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c == 0x2B || c == 0x2D) i++;
  }
  var digits = 0;
  while (i < source.length) {
    final c = source.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) break;
    digits++;
    i++;
  }
  if (i < source.length && source.codeUnitAt(i) == 0x2E) {
    i++;
    while (i < source.length) {
      final c = source.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) break;
      digits++;
      i++;
    }
  }
  if (digits == 0) return null;
  final value = num.tryParse(source.substring(start, i));
  if (value == null) return null;
  return (value: value, next: i);
}

