import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/document_extraction_types.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_page_detection.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

/// A "sufficient" text layer page for the default 24-character threshold.
const String goodText =
    '这是一页有完整文字层的正文，包含足够多的字符用于判断是否需要 OCR。'
    '日期：2026年11月4日，工时：2.5小时。';

void main() {
  group('detectOcrPagesFromTexts', () {
    test('image always needs OCR on its single page', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.image,
        pageCount: 1,
        pageTexts: const <int, String>{},
      );
      expect(detection.pageCount, 1);
      expect(detection.pagesToOcr, <int>[1]);
      expect(detection.pages.single.reason, OcrPageReason.imageSource);
      expect(detection.isScannedOnly, isTrue);
    });

    test('a fully scanned PDF marks every page and explains why', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 3,
        pageTexts: const <int, String>{},
      );
      expect(detection.isScannedOnly, isTrue);
      expect(detection.pagesToOcr, <int>[1, 2, 3]);
      expect(detection.pages.every((p) => p.reason == OcrPageReason.noTextLayer), isTrue);
      expect(detection.pages.first.explanation, contains('扫描'));
      expect(detection.summary, contains('全部需要 OCR'));
    });

    test('a sufficient text layer is not selected again (mixed document)', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 3,
        pageTexts: const <int, String>{1: goodText, 3: goodText},
      );
      expect(detection.pagesToOcr, <int>[2]);
      expect(detection.textPages, <int>[1, 3]);
      expect(detection.isMixed, isTrue);
      expect(detection.pages[1].reason, OcrPageReason.mixedMissingText);
      expect(detection.pages.first.reason, OcrPageReason.textLayerSufficient);
      expect(detection.summary, contains('1 页需要 OCR'));
    });

    test('a page with only a page number is flagged as too short with reason', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 2,
        pageTexts: const <int, String>{1: goodText, 2: '第 12 页'},
      );
      expect(detection.pagesToOcr, <int>[2]);
      final plan = detection.pages[1];
      expect(plan.reason, OcrPageReason.textTooShort);
      expect(plan.textLength, 6);
      expect(plan.explanation, contains('文字层只有很少内容'));
      expect(plan.detail, contains('6 个字符'));
    });

    test('garbled text is flagged with the anomaly ratio', () {
      final garbled = '\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD'
          '\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD\uFFFD';
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 1,
        pageTexts: <int, String>{1: garbled},
      );
      final plan = detection.pages.single;
      expect(plan.needsOcr, isTrue);
      expect(plan.reason, OcrPageReason.garbledText);
      expect(plan.detail, contains('%'));
    });

    test('force and exclude override the automatic decision', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 3,
        pageTexts: const <int, String>{1: goodText, 2: goodText, 3: goodText},
        forcedPages: const <int>[1],
        excludedPages: const <int>[2],
      );
      expect(detection.pagesToOcr, <int>[1]);
      expect(detection.pages[0].reason, OcrPageReason.userForced);
      expect(detection.pages[1].needsOcr, isFalse);
      expect(detection.pages[1].reason, OcrPageReason.userExcluded);
      expect(detection.pages[2].reason, OcrPageReason.textLayerSufficient);
    });

    test('a document with no usable text and unknown page count errors clearly', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 0,
        pageTexts: const <int, String>{},
      );
      expect(detection.detectionFailed, isTrue);
      expect(detection.error!.code, OcrErrorCode.pageOutOfRange);
      expect(detection.pages, isEmpty);
    });

    test('out-of-range text entries are ignored', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 1,
        pageTexts: const <int, String>{1: goodText, 99: 'x'},
      );
      expect(detection.pages, hasLength(1));
      expect(detection.pagesToOcr, isEmpty);
    });

    test('planFor returns null outside the document', () {
      final detection = detectOcrPagesFromTexts(
        kind: OcrSourceKind.pdf,
        pageCount: 2,
        pageTexts: const <int, String>{},
      );
      expect(detection.planFor(1), isNotNull);
      expect(detection.planFor(0), isNull);
      expect(detection.planFor(3), isNull);
    });
  });

  group('ocrGarbageRatio', () {
    test('clean text has a near-zero ratio', () {
      expect(ocrGarbageRatio(goodText), lessThan(0.01));
    });

    test('replacement characters dominate a broken text layer', () {
      expect(ocrGarbageRatio('\uFFFD' * 10), 1.0);
    });

    test('a few question marks in prose are not treated as garbage', () {
      expect(ocrGarbageRatio('这样可以吗？真的可以吗？'), lessThan(0.2));
    });

    test('empty text returns zero', () {
      expect(ocrGarbageRatio(''), 0);
    });
  });

  group('detectOcrPages (high level)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ocr_detect_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('unsupported extension is refused', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}notes.txt');
      await file.writeAsString('hello');
      final detection = await detectOcrPages(file.path);
      expect(detection.detectionFailed, isTrue);
      expect(detection.error!.code, OcrErrorCode.unsupportedFormat);
    });

    test('missing file is reported, not treated as a scan', () async {
      final detection = await detectOcrPages(
          '${tempDir.path}${Platform.pathSeparator}missing.pdf');
      expect(detection.detectionFailed, isTrue);
      expect(detection.error!.code, OcrErrorCode.renderFailed);
    });

    test('image input does not read a text layer', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}scan.png');
      await file.writeAsBytes(const <int>[1, 2, 3]);
      final detection = await detectOcrPages(file.path);
      expect(detection.detectionFailed, isFalse);
      expect(detection.pagesToOcr, <int>[1]);
      expect(detection.pages.single.reason, OcrPageReason.imageSource);
    });

    test('PDF uses the injected text reader (mixed pages)', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}mixed.pdf');
      await file.writeAsBytes(const <int>[1, 2, 3]);
      final detection = await detectOcrPages(
        file.path,
        pdfTextReader: (path) async => const OcrPdfPageTexts(
          pageCount: 2,
          texts: <int, String>{1: goodText},
        ),
      );
      expect(detection.pagesToOcr, <int>[2]);
      expect(detection.isMixed, isTrue);
    });

    test('scanned PDF asks the page-count reader for the total', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}scan.pdf');
      await file.writeAsBytes(const <int>[1, 2, 3]);
      final detection = await detectOcrPages(
        file.path,
        pdfTextReader: (path) async => const OcrPdfPageTexts(
          pageCount: 0,
          texts: <int, String>{},
          failure: DocumentError(
            DocumentErrorKind.unsupportedOcr,
            '该 PDF 没有文本层',
          ),
        ),
        pageCountReader: (path) async => 4,
      );
      expect(detection.detectionFailed, isFalse);
      expect(detection.pageCount, 4);
      expect(detection.pagesToOcr, <int>[1, 2, 3, 4]);
      expect(detection.warning, contains('文字层'));
    });

    test('scanned PDF without a page-count source fails with a clear message', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}scan.pdf');
      await file.writeAsBytes(const <int>[1, 2, 3]);
      final detection = await detectOcrPages(
        file.path,
        pdfTextReader: (path) async => const OcrPdfPageTexts(
          pageCount: 0,
          texts: <int, String>{},
          failure: DocumentError(DocumentErrorKind.unsupportedOcr, '没有文本层'),
        ),
      );
      expect(detection.detectionFailed, isTrue);
      expect(detection.error!.message, contains('页数'));
    });
  });
}
