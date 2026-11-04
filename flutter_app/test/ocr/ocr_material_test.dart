import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_material.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

OcrPageResult pageResult(
  int page, {
  required String text,
  List<String>? lines,
  int width = 1240,
  int height = 1754,
  double? confidence,
}) {
  final lineTexts = lines ?? <String>[text];
  return OcrPageResult(
    page: page,
    text: text,
    lines: <OcrLine>[
      for (var i = 0; i < lineTexts.length; i++)
        OcrLine(
          text: lineTexts[i],
          confidence: confidence,
          bbox: OcrRect(10, 10 + i * 40, 400, 30),
        ),
    ],
    width: width,
    height: height,
    dpi: 150,
    engine: 'Windows.Media.Ocr',
    engineVersion: 'Windows.Media.Ocr/test',
    language: 'zh-Hans-CN',
  );
}

OcrMaterial materialWith(List<OcrPageResult> results, {String? sha}) {
  final job = OcrJobResult(
    sourcePath: r'C:\docs\scan.pdf',
    sourceKind: 'pdf',
    totalPages: results.length,
    requestedPages: <int>[for (final result in results) result.page],
    results: results,
    engine: 'Windows.Media.Ocr',
    engineVersion: 'Windows.Media.Ocr/test',
    languages: const <String>['zh-Hans-CN', 'en-US'],
    dpi: 150,
    sourceSha256: sha ?? 'a' * 64,
  );
  return OcrMaterial.fromJob(job: job, fileLabel: 'scan.pdf');
}

void main() {
  group('normaliseOcrText', () {
    test('removes the spaces the Chinese engine inserts between characters', () {
      expect(normaliseOcrText('项 目 周 会 纪 要'), '项目周会纪要');
      expect(
        normaliseOcrText('日 期 ： 2026 年 1 1 月 4 日'),
        '日期：2026年11月4日',
      );
    });

    test('keeps negation words, units, identifiers and Chinese colons', () {
      final text = normaliseOcrText('要 求 ： 本 周 不 能 安 排 加 班 ； 工 时 ： 2.5 小 时');
      expect(text, contains('不能'));
      expect(text, contains('小时'));
      expect(text, contains('：'));
      expect(text, contains('；'));
      expect(text, isNot(contains(' ')));
    });

    test('repairs dash and dot confusions in dates and identifiers', () {
      expect(
        normaliseOcrText('编 号 ： TS 一 2026 一 1104'),
        '编号：TS-2026-1104',
      );
      expect(
        normaliseOcrText('Date: 2026 · 1 1 · 04'),
        'Date: 2026-11-04',
      );
      expect(normaliseOcrText('工 时 ： 2 · 5 小 时'), '工时：2.5小时');
      expect(normaliseOcrText('工 时 ： 2．5小时'), '工时：2.5小时');
      // OCR sometimes emits a Chinese comma as the decimal separator. Only a
      // digit run followed by a unit is repaired; list separators stay as-is.
      expect(normaliseOcrText('工 时 ： 2 ， 5 小 时'), '工时：2.5小时');
      expect(normaliseOcrText('第 3，4 项'), '第3，4项');
    });

    test('keeps English spacing and joins a hyphenated word split by a line', () {
      expect(
        normaliseOcrText('Date: 2026-11-04\nTime: 09:15'),
        'Date: 2026-11-04\nTime: 09:15',
      );
      expect(
        normaliseOcrText('Prepare OCR accept-\nance report'),
        'Prepare OCR acceptance report',
      );
    });

    test('strips control characters but keeps line breaks', () {
      expect(normaliseOcrText('第一行\u0000\n第二行'), '第一行\n第二行');
    });

    test('does not invent missing content', () {
      // No guessing of dates/numbers: unknown stays unknown.
      expect(normaliseOcrText('日期：未 知'), '日期：未知');
    });
  });

  group('flagged fields', () {
    test('marks dates, times, durations and identifiers for confirmation', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(
          1,
          text: '日 期 ： 2026 年 11 月 4 日\n时 间 ： 14:30\n工 时 ： 2.5 小 时\n编 号 ： TS-2026-1104',
        ),
      ]);
      final flags = material.flaggedFields;
      expect(flags.map((flag) => flag.kind), containsAll(<OcrFlagKind>[
        OcrFlagKind.date,
        OcrFlagKind.time,
        OcrFlagKind.duration,
        OcrFlagKind.identifier,
      ]));
      expect(flags.every((flag) => flag.needsConfirmation), isTrue);
      expect(flags.every((flag) => flag.page == 1), isTrue);
      // Windows OCR exposes no confidence: flags say so explicitly instead of
      // showing an invented score.
      final flag = flags.firstWhere((entry) => entry.kind == OcrFlagKind.date);
      expect(flag.engineConfidence, isNull);
      expect(flag.reason, contains('不提供逐词置信度'));
    });

    test('low engine confidence is flagged when a score exists', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(
          1,
          text: '日期：2026-11-04',
          lines: const <String>['日期：2026-11-04'],
          confidence: 0.31,
        ),
      ]);
      final flag = material.flaggedFields.first;
      expect(flag.engineConfidence, 0.31);
      expect(flag.reason, contains('较低'));
    });

    test('material asks for review when fields are flagged', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(1, text: '日期：2026-11-04'),
      ]);
      expect(material.needsUserReview, isTrue);
      expect(material.reviewHint, contains('需确认'));
    });
  });

  group('review separation', () {
    test('review is stored separately from the OCR original', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(1, text: '日期：2026-11-04 工时：2.5小时'),
      ]);
      final reviewed = material.applyReview(1, '日期：2026-11-05 工时：2.5小时');
      expect(reviewed.pages.single.originalText, '日期：2026-11-04工时：2.5小时');
      expect(reviewed.pages.single.reviewedText, '日期：2026-11-05 工时：2.5小时');
      expect(reviewed.pages.single.effectiveText, contains('11-05'));
      expect(reviewed.pages.single.isReviewed, isTrue);
      expect(reviewed.pages.single.reviewDiff(), contains('人工校对'));
      expect(reviewed.reviewedPageCount, 1);
    });

    test('clearing the review restores the OCR original', () {
      final reviewed = materialWith(<OcrPageResult>[pageResult(1, text: '原文')])
          .applyReview(1, '校对');
      final cleared = reviewed.applyReview(1, '   ');
      expect(cleared.pages.single.reviewedText, isNull);
      expect(cleared.pages.single.effectiveText, '原文');
    });

    test('re-recognition never overwrites reviewed text', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(1, text: '日期：2026-11-04'),
      ]).applyReview(1, '日期：2026-11-05（人工确认）');

      final rerunJob = OcrJobResult(
        sourcePath: r'C:\docs\scan.pdf',
        sourceKind: 'pdf',
        totalPages: 1,
        requestedPages: const <int>[1],
        results: <OcrPageResult>[pageResult(1, text: '日期：2026-11-06')],
        sourceSha256: 'a' * 64,
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/test2',
        dpi: 200,
      );
      final rerun = material.rerun(rerunJob);
      final page = rerun.pages.single;
      expect(page.reviewedText, '日期：2026-11-05（人工确认）');
      expect(page.effectiveText, contains('11-05'));
      expect(page.originalText, contains('11-06'));
      expect(page.previousOriginalText, contains('11-04'));
      expect(page.changedByRerun, isTrue);
      expect(page.reviewHistory, hasLength(1));
      expect(rerun.dpi, 200);
      expect(rerun.engineVersion, 'Windows.Media.Ocr/test2');
    });

    test('re-run failures keep previous text and are reported', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(1, text: '第一页'),
        pageResult(2, text: '第二页'),
      ]);
      final rerunJob = OcrJobResult(
        sourcePath: r'C:\docs\scan.pdf',
        sourceKind: 'pdf',
        totalPages: 2,
        requestedPages: const <int>[1, 2],
        results: <OcrPageResult>[pageResult(1, text: '第一页（新）')],
        failures: const <OcrPageFailure>[
          OcrPageFailure(page: 2, code: OcrErrorCode.ocrFailed, message: '失败'),
        ],
        sourceSha256: 'a' * 64,
        dpi: 150,
      );
      final rerun = material.rerun(rerunJob);
      expect(rerun.pages.map((page) => page.page), <int>[1, 2]);
      expect(rerun.pages[1].effectiveText, '第二页');
      expect(rerun.rerunFailures, <int>[2]);
    });

    test('cannot merge another document into the material', () {
      final material = materialWith(<OcrPageResult>[pageResult(1, text: '原文')]);
      final otherJob = OcrJobResult(
        sourcePath: r'C:\docs\other.pdf',
        sourceKind: 'pdf',
        totalPages: 1,
        requestedPages: const <int>[1],
        results: <OcrPageResult>[pageResult(1, text: '别的文档')],
        sourceSha256: 'b' * 64,
        dpi: 150,
      );
      expect(() => material.rerun(otherJob), throwsArgumentError);
    });
  });

  group('layout detection', () {
    test('two side-by-side columns are flagged as complex', () {
      final lines = <OcrLine>[
        for (var i = 0; i < 4; i++) OcrLine(text: '左栏 $i', bbox: OcrRect(20, 20.0 + i * 50, 200, 30)),
        for (var i = 0; i < 4; i++) OcrLine(text: '右栏 $i', bbox: OcrRect(700, 20.0 + i * 50, 200, 30)),
      ];
      final result = OcrPageResult(
        page: 1,
        text: '左栏\n右栏',
        lines: lines,
        width: 1000,
        height: 800,
        dpi: 150,
        engine: 'Windows.Media.Ocr',
        engineVersion: 'v1',
        language: 'zh-Hans-CN',
      );
      expect(detectComplexLayout(result), isTrue);
      expect(materialWith(<OcrPageResult>[result]).layoutComplex, isTrue);
    });

    test('a single column is not flagged', () {
      final lines = <OcrLine>[
        for (var i = 0; i < 8; i++) OcrLine(text: '行 $i', bbox: OcrRect(20, 20.0 + i * 40, 800, 30)),
      ];
      final result = OcrPageResult(
        page: 1,
        text: '正文',
        lines: lines,
        width: 1000,
        height: 800,
        dpi: 150,
        engine: 'Windows.Media.Ocr',
        engineVersion: 'v1',
        language: 'zh-Hans-CN',
      );
      expect(detectComplexLayout(result), isFalse);
    });
  });

  group('material text and provenance', () {
    test('attachment text has page markers, provenance and page ordering', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(2, text: '第二页内容'),
        pageResult(1, text: '第一页内容'),
      ]).applyReview(2, '第二页校对内容');
      final text = material.toAttachmentText();
      expect(text, contains('【OCR 材料：scan.pdf，共 2 页，本地离线识别】'));
      expect(text.indexOf('第 1 页'), lessThan(text.indexOf('第 2 页')));
      expect(text, contains('已人工校对'));
      expect(text, contains('第二页校对内容'));
      expect(text, contains('本地 OCR 引擎 Windows.Media.Ocr/test'));
      expect(text, contains('第 1、2 页'));
    });

    test('source ref carries the document hash and geometry', () {
      final material = materialWith(<OcrPageResult>[pageResult(1, text: '内容')]);
      final ref = material.pages.single.sourceRef(material.documentSha256);
      expect(ref.documentSha256, 'a' * 64);
      expect(ref.page, 1);
      expect(ref.width, 1240);
      expect(ref.dpi, 150);
      expect(ref.method, OcrMethod.ocr);
      expect(ref.describe, contains('第 1 页'));
    });

    test('material JSON round-trips review state without secrets', () {
      final material = materialWith(<OcrPageResult>[
        pageResult(1, text: '日期：2026-11-04'),
      ]).applyReview(1, '日期：2026-11-05');
      final encoded = material.toJsonString();
      expect(encoded, isNot(contains('password')));
      final decoded = OcrMaterial.fromJsonString(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.fileLabel, 'scan.pdf');
      expect(decoded.pages.single.reviewedText, '日期：2026-11-05');
      expect(decoded.pages.single.originalText, contains('11-04'));
      expect(decoded.documentSha256, 'a' * 64);
      expect(decoded.reviewedPageCount, 1);
    });

    test('job failures are not represented as empty success material', () {
      final job = OcrJobResult(
        sourcePath: r'C:\docs\scan.pdf',
        sourceKind: 'pdf',
        totalPages: 2,
        requestedPages: const <int>[1, 2],
        results: const <OcrPageResult>[],
        failures: const <OcrPageFailure>[
          OcrPageFailure(page: 1, code: OcrErrorCode.encrypted, message: '加密'),
        ],
        sourceSha256: 'a' * 64,
        dpi: 150,
      );
      final material = OcrMaterial.fromJob(job: job, fileLabel: 'scan.pdf');
      expect(material.isEmpty, isTrue);
      expect(material.pages, isEmpty);
    });
  });
}
