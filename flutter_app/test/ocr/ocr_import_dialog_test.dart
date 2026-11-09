import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_material.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_page_detection.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_service.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';
import 'package:taskscheduler_flutter/src/ui/ocr/ocr_import_dialog.dart';

import 'support/fake_ocr.dart';

void main() {
  late Directory dataRoot;
  late Directory docRoot;
  late FakeOcrClient fakeClient;
  late OcrService service;

  setUp(() async {
    dataRoot = await Directory.systemTemp.createTemp('ocr_dialog_data_');
    docRoot = await Directory.systemTemp.createTemp('ocr_dialog_docs_');
    fakeClient = FakeOcrClient(host: fakeHostLocation());
    service = OcrService(
      dataRoot: dataRoot,
      limits: fastOcrLimits,
      discovery: OcrHostDiscovery(
        location: fakeHostLocation(),
        attempted: const <OcrHostCandidate>[],
      ),
      clientFactory: (_) => fakeClient,
      enableCache: false,
      // No real PDF parsing in widget tests: text-layer detection is injected
      // (the fake document has no text layer, like a scan).
      pdfTextReader: (path) async => const OcrPdfPageTexts(
        pageCount: 3,
        texts: <int, String>{},
      ),
    );
  });

  tearDown(() async {
    for (final dir in <Directory>[dataRoot, docRoot]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  // Synchronous on purpose: widget tests run in a FakeAsync zone where real
  // asynchronous file I/O never completes. Sync file calls keep the test
  // deterministic and fast.
  File writeFile(String name, String content) {
    final file = File('${docRoot.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file;
  }

  OcrJobResult completeJob(OcrJobRequest request) => fakeJobResult(
        request: request,
        pages: request.pages,
        texts: <int, String>{
          for (final page in request.pages)
            page: '第 $page 页：日期 2026-11-04，工时 2.5小时',
        },
      );

  /// Bounded pump loop: the dialog shows an indeterminate progress indicator
  /// while the local backend is probed, so pumpAndSettle can never settle.
  /// Pumping explicitly is both faster and deterministic.
  Future<void> settle(WidgetTester tester,
      {Duration step = const Duration(milliseconds: 120),
      int maxSteps = 40}) async {
    await tester.pump();
    for (var i = 0; i < maxSteps; i++) {
      await tester.pump(step);
    }
  }

  Future<_DialogHarness> openDialog(
    WidgetTester tester, {
    OcrPickFiles? pickFiles,
    String? initialFilePath,
  }) async {
    final harness = _DialogHarness();
    final app = MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-ocr'),
              onPressed: () async {
                harness.result = await showOcrImportDialog(
                  context,
                  service: service,
                  pickFiles: pickFiles,
                  initialFilePath: initialFilePath,
                  onConfirm: (material) async {
                    harness.confirmed = material;
                    return harness.confirmSucceeds;
                  },
                );
              },
              child: const Text('打开 OCR'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app);
    await tester.tap(find.byKey(const Key('open-ocr')));
    await settle(tester);
    return harness;
  }

  testWidgets(
      'unavailable OCR backend explains what is missing and offers retry',
      (tester) async {
    fakeClient.probeResult = OcrAvailability.unavailable(
      '找不到本地 OCR 组件 ocr_host.exe。请确认安装包完整。',
      hostPath: fakeHostLocation().path,
    );
    await openDialog(tester);
    expect(find.byKey(const Key('ocr-import-dialog')), findsOneWidget);
    expect(find.byKey(const Key('ocr-error')), findsOneWidget);
    expect(find.textContaining('找不到本地 OCR 组件'), findsOneWidget);
    expect(find.byKey(const Key('ocr-retry-availability')), findsOneWidget);
    expect(find.byKey(const Key('ocr-start')), findsNothing);
  });

  testWidgets('full flow: pick, detect, recognise, review, confirm',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    final file = writeFile('scan.pdf', 'pdf-bytes');
    final harness = await openDialog(
      tester,
      pickFiles: () async => <String>[file.path],
    );
    // Select phase -> pick the file -> detection runs automatically.
    expect(find.byKey(const Key('ocr-pick-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    // Configure phase: suggested range + page plan are visible.
    expect(find.byKey(const Key('ocr-detection-summary')), findsOneWidget);
    expect(find.byKey(const Key('ocr-page-plan')), findsOneWidget);
    final spec =
        tester.widget<TextField>(find.byKey(const Key('ocr-page-spec')));
    expect(spec.controller!.text, '1-3');
    expect(find.textContaining('第 1 页'), findsWidgets);
    // Start local OCR.
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    // Review phase with one editable field per page.
    expect(find.byKey(const Key('ocr-review-summary')), findsOneWidget);
    expect(find.byKey(const Key('ocr-review-text-1')), findsOneWidget);
    expect(find.byKey(const Key('ocr-review-text-3')), findsOneWidget);
    // Correct a date on page 1.
    await tester.enterText(
      find.byKey(const Key('ocr-review-text-1')),
      '第 1 页：日期 2026-11-05，工时 2.5小时',
    );
    await tester.pump();
    // Confirm: unreviewed pages require an explicit partial confirmation.
    await tester.tap(find.byKey(const Key('ocr-confirm')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-partial-confirm-dialog')), findsOneWidget);
    expect(find.textContaining('尚未人工校对'), findsWidgets);
    await tester.tap(find.byKey(const Key('ocr-partial-confirm-accept')));
    await settle(tester);
    expect(harness.confirmed, isNotNull);
    expect(harness.confirmed!.pages, hasLength(3));
    expect(harness.confirmed!.pages.first.reviewedText, contains('11-05'));
    expect(harness.confirmed!.pages[1].reviewedText, isNull);
    expect(harness.result, isTrue);
    expect(find.byKey(const Key('ocr-import-dialog')), findsNothing);
  });

  testWidgets('restore original re-inserts the untouched OCR text',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    final file = writeFile('scan.pdf', 'pdf-bytes');
    final harness = await openDialog(
      tester,
      pickFiles: () async => <String>[file.path],
    );
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    final original = tester
        .widget<TextField>(find.byKey(const Key('ocr-review-text-1')))
        .controller!
        .text;
    await tester.enterText(
      find.byKey(const Key('ocr-review-text-1')),
      '人工手改内容',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ocr-review-text-1')))
          .controller!
          .text,
      '人工手改内容',
    );
    // 恢复识别原文：编辑框回到原始识别文本，且该页不再算人工校对。
    await tester.tap(find.byKey(const Key('ocr-reset-review-1')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('ocr-review-text-1')))
          .controller!
          .text,
      original,
    );
    await tester.tap(find.byKey(const Key('ocr-confirm')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-partial-confirm-accept')));
    await settle(tester);
    expect(harness.confirmed, isNotNull);
    expect(harness.confirmed!.pages.first.reviewedText, isNull);
    expect(harness.confirmed!.pages.first.originalText, original);
  });

  testWidgets(
      'partial OCR failure lists missing pages and confirms only successes',
      (tester) async {
    fakeClient.runHandler = (request) async => OcrJobResult(
          sourcePath: request.filePath,
          sourceKind: request.kind.wire,
          totalPages: 3,
          requestedPages: request.pages,
          results: <OcrPageResult>[
            fakeJobResult(request: request, pages: <int>[1]).results.single,
          ],
          failures: const <OcrPageFailure>[
            OcrPageFailure(
                page: 2, code: OcrErrorCode.ocrFailed, message: '该页没有识别出文字。'),
          ],
          engine: 'Windows.Media.Ocr',
          engineVersion: 'Windows.Media.Ocr/test',
          dpi: request.dpi,
        );
    final file = writeFile('scan.pdf', 'pdf-bytes');
    final harness = await openDialog(
      tester,
      pickFiles: () async => <String>[file.path],
    );
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-failure-list')), findsOneWidget);
    expect(find.textContaining('第 2 页'), findsWidgets);
    expect(find.textContaining('ocr_failed'), findsOneWidget);
    expect(find.byKey(const Key('ocr-rerun-missing')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ocr-confirm')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-partial-confirm-dialog')), findsOneWidget);
    expect(find.textContaining('未识别成功'), findsWidgets);
    expect(find.textContaining('第 2 页'), findsWidgets);
    await tester.tap(find.byKey(const Key('ocr-partial-confirm-accept')));
    await settle(tester);
    expect(harness.confirmed, isNotNull);
    expect(harness.confirmed!.pages.map((page) => page.page), <int>[1]);
  });

  testWidgets('re-recognition keeps the reviewed text and fills missing pages',
      (tester) async {
    var calls = 0;
    fakeClient.runHandler = (request) async {
      calls++;
      if (calls == 1) {
        return OcrJobResult(
          sourcePath: request.filePath,
          sourceKind: request.kind.wire,
          totalPages: 3,
          requestedPages: request.pages,
          results: <OcrPageResult>[
            fakeJobResult(request: request, pages: <int>[1]).results.single,
          ],
          failures: const <OcrPageFailure>[
            OcrPageFailure(
                page: 2, code: OcrErrorCode.ocrFailed, message: '失败'),
            OcrPageFailure(page: 3, code: OcrErrorCode.timeout, message: '超时'),
          ],
          engine: 'Windows.Media.Ocr',
          engineVersion: 'Windows.Media.Ocr/test',
          dpi: request.dpi,
        );
      }
      return completeJob(request);
    };
    final file = writeFile('scan.pdf', 'pdf-bytes');
    final harness = await openDialog(
      tester,
      pickFiles: () async => <String>[file.path],
    );
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('ocr-review-text-1')),
      '人工校对后的第一页',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ocr-rerun-missing')));
    await settle(tester);
    expect(calls, 2);
    expect(find.byKey(const Key('ocr-review-text-2')), findsOneWidget);
    expect(find.byKey(const Key('ocr-review-text-3')), findsOneWidget);
    final reviewedField = tester.widget<TextField>(
      find.byKey(const Key('ocr-review-text-1')),
    );
    expect(reviewedField.controller!.text, '人工校对后的第一页');
    expect(find.byKey(const Key('ocr-failure-list')), findsNothing);
    // Confirm now only needs the "unreviewed pages" confirmation, not missing.
    await tester.tap(find.byKey(const Key('ocr-confirm')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-partial-confirm-accept')));
    await settle(tester);
    expect(harness.confirmed, isNotNull);
    expect(harness.confirmed!.pages.first.reviewedText, '人工校对后的第一页');
  });

  testWidgets('invalid page range blocks the start and explains the format',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    final file = writeFile('scan.pdf', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async => <String>[file.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('ocr-page-spec')), '0-abc');
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-error')), findsOneWidget);
    expect(find.textContaining('页范围格式不正确'), findsOneWidget);
    expect(fakeClient.runRequests, isEmpty);
    expect(find.byKey(const Key('ocr-start')), findsOneWidget);
  });

  testWidgets(
      'cancelling a running job keeps the dialog and reports cancellation',
      (tester) async {
    final completer = Completer<OcrJobResult>();
    fakeClient.runHandler = (request) => completer.future;
    final file = writeFile('scan.pdf', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async => <String>[file.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await tester.pump();
    expect(find.byKey(const Key('ocr-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ocr-cancel')));
    await tester.pump();
    expect(find.textContaining('正在取消'), findsOneWidget);
    completer.complete(OcrJobResult(
      sourcePath: file.path,
      sourceKind: 'pdf',
      totalPages: 3,
      requestedPages: const <int>[1, 2, 3],
      failures: const <OcrPageFailure>[
        OcrPageFailure(
            page: 1, code: OcrErrorCode.cancelled, message: '识别已取消，该页未完成。'),
        OcrPageFailure(
            page: 2, code: OcrErrorCode.cancelled, message: '识别已取消，该页未完成。'),
        OcrPageFailure(
            page: 3, code: OcrErrorCode.cancelled, message: '识别已取消，该页未完成。'),
      ],
      cancelled: true,
      engine: 'Windows.Media.Ocr',
      engineVersion: 'Windows.Media.Ocr/test',
      dpi: 150,
    ));
    await settle(tester);
    expect(find.byKey(const Key('ocr-review-summary')), findsOneWidget);
    expect(find.textContaining('已取消'), findsWidgets);
    expect(find.byKey(const Key('ocr-confirm')), findsOneWidget);
  });

  testWidgets(
      'missing file picker is reported instead of silently doing nothing',
      (tester) async {
    await openDialog(tester);
    expect(find.byKey(const Key('ocr-pick-file')), findsOneWidget);
    final original = OcrFilePicker.defaultPick;
    OcrFilePicker.defaultPick = null;
    addTearDown(() => OcrFilePicker.defaultPick = original);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    expect(find.textContaining('文件选择不可用'), findsOneWidget);
  });

  testWidgets('confirm failure keeps the dialog open with an error',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    final file = writeFile('scan.pdf', 'pdf-bytes');
    final harness = await openDialog(
      tester,
      pickFiles: () async => <String>[file.path],
    );
    harness.confirmSucceeds = false;
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-confirm')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-partial-confirm-accept')));
    await settle(tester);
    expect(harness.confirmed, isNotNull);
    expect(find.byKey(const Key('ocr-import-dialog')), findsOneWidget);
    expect(find.textContaining('没有被保存'), findsOneWidget);
    expect(find.byKey(const Key('ocr-confirm')), findsOneWidget);
  });

  // ------------------------------------------------------- 任务 05：帮助弹窗

  testWidgets('help only explains formats; closing it keeps the dialog state',
      (tester) async {
    await openDialog(tester);
    expect(find.byTooltip('使用说明'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ocr-help')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-help-dialog')), findsOneWidget);
    // 黄框正文：只有格式与提取方式。
    expect(find.text(OcrFileSupport.helpBody), findsWidgets);
    // 红框联网边界整段退出帮助；安装说明也不在正常帮助里常驻。
    expect(find.byKey(const Key('ocr-help-boundary')), findsNothing);
    expect(find.textContaining('联网边界'), findsNothing);
    expect(find.textContaining('模型'), findsNothing);
    expect(find.textContaining('光学字符识别'), findsNothing);
    expect(find.textContaining('安装'), findsNothing);
    // “知道了”用任务 02 的统一主按钮（实心主色），不是行内文字按钮。
    final closeButton = tester.widget<FilledButton>(
      find.byKey(const Key('ocr-help-close')),
    );
    expect(closeButton.style?.backgroundColor, isNotNull);

    await tester.tap(find.byKey(const Key('ocr-help-close')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-help-dialog')), findsNothing);
    // 只关闭最上层帮助，主对话框与已选文件状态保留。
    expect(find.byKey(const Key('ocr-import-dialog')), findsOneWidget);
    expect(find.byKey(const Key('ocr-pick-file')), findsOneWidget);
    expect(find.byKey(const Key('ocr-error')), findsNothing);
    // 打开/关闭帮助不会触发本地识别或模型请求。
    expect(fakeClient.runRequests, isEmpty);
  });

  testWidgets('help opened from the review page keeps reviewed text',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    final file = writeFile('scan.pdf', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async => <String>[file.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('ocr-review-text-1')),
      '人工校对后的第一页',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('ocr-help')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-help-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ocr-help-close')));
    await settle(tester);

    expect(find.byKey(const Key('ocr-help-dialog')), findsNothing);
    final reviewed = tester.widget<TextField>(
      find.byKey(const Key('ocr-review-text-1')),
    );
    expect(reviewed.controller!.text, '人工校对后的第一页');
    expect(find.byKey(const Key('ocr-review-text-3')), findsOneWidget);
  });

  // ------------------------------------------- 任务 05：缺少识别语言的失败状态

  testWidgets('missing OCR language shows the verified settings path',
      (tester) async {
    fakeClient.probeResult = OcrAvailability(
      available: false,
      hostPath: fakeHostLocation().path,
      languages: const <OcrLanguage>[],
      problem: '本机没有安装任何 OCR 识别语言组件。',
      languagePackMissing: true,
      checkedAt: DateTime.now(),
    );
    await openDialog(tester);
    expect(find.byKey(const Key('ocr-import-dialog')), findsOneWidget);
    // 具体原因 + 已核实的系统设置路径 + 当下操作。
    expect(find.textContaining('没有安装任何 OCR 识别语言组件'), findsWidgets);
    expect(find.byKey(const Key('ocr-language-install-guide')), findsOneWidget);
    expect(find.byKey(const Key('ocr-language-install-path')), findsOneWidget);
    expect(find.textContaining('时间和语言'), findsWidgets);
    expect(find.textContaining('光学字符识别'), findsWidgets);
    expect(find.textContaining('重新检查'), findsWidgets);
    expect(find.byKey(const Key('ocr-retry-availability')), findsOneWidget);
  });

  testWidgets('other OCR failures do not show language install instructions',
      (tester) async {
    fakeClient.probeResult = OcrAvailability.unavailable(
      '找不到本地 OCR 组件 ocr_host.exe。请确认安装包完整。',
      hostPath: fakeHostLocation().path,
    );
    await openDialog(tester);
    expect(find.byKey(const Key('ocr-language-install-guide')), findsNothing);
    expect(find.textContaining('光学字符识别'), findsNothing);
  });

  testWidgets('job-level missing language shows the install guide',
      (tester) async {
    fakeClient.runHandler = (request) async => OcrJobResult(
          sourcePath: request.filePath,
          sourceKind: request.kind.wire,
          totalPages: 1,
          requestedPages: request.pages,
          failures: const <OcrPageFailure>[
            OcrPageFailure(
              page: 1,
              code: OcrErrorCode.noLanguage,
              message: '本机没有该语言的 OCR 识别组件。',
            ),
          ],
          engine: 'Windows.Media.Ocr',
          engineVersion: 'Windows.Media.Ocr/test',
          dpi: request.dpi,
          jobError: const OcrError(
            code: OcrErrorCode.noLanguage,
            message: '请求的语言在本机没有可用的 OCR 识别组件。',
          ),
        );
    final file = writeFile('scan.pdf', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async => <String>[file.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-language-install-guide')), findsOneWidget);
    expect(find.textContaining('时间和语言'), findsWidgets);
    expect(find.textContaining('光学字符识别'), findsWidgets);
  });

  // ------------------------------------------------ 任务 06：格式范围与入口校验

  testWidgets('OCR accepts uppercase .PDF and .JPG extensions', (tester) async {
    final pdf = writeFile('SCAN.PDF', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async => <String>[pdf.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-detection-summary')), findsOneWidget);
    expect(find.byKey(const Key('ocr-error')), findsNothing);

    await tester.tap(find.byKey(const Key('ocr-dialog-close')));
    await settle(tester);

    final jpg = writeFile('PHOTO.JPG', 'jpg-bytes');
    await openDialog(tester, pickFiles: () async => <String>[jpg.path]);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-page-plan')), findsOneWidget);
    expect(find.byKey(const Key('ocr-error')), findsNothing);
  });

  for (final name in <String>['notes.txt', 'report.docx', 'calendar.ics']) {
    testWidgets('OCR rejects $name returned by the native dialog',
        (tester) async {
      final file = writeFile(name, 'not-an-ocr-source');
      await openDialog(tester, pickFiles: () async => <String>[file.path]);
      await tester.tap(find.byKey(const Key('ocr-pick-file')));
      await settle(tester);
      expect(find.byKey(const Key('ocr-error')), findsOneWidget);
      expect(find.textContaining('仅支持 PDF、PNG、JPG、JPEG'), findsOneWidget);
      // 拒绝发生在应用入口：不会交给识别器，也不会触发模型请求。
      expect(fakeClient.runRequests, isEmpty);
      expect(find.byKey(const Key('ocr-detection-summary')), findsNothing);
    });
  }

  testWidgets('cancelling the picker after results keeps the reviewed pages',
      (tester) async {
    fakeClient.runHandler = (request) async => completeJob(request);
    var picks = 0;
    final file = writeFile('scan.pdf', 'pdf-bytes');
    await openDialog(tester, pickFiles: () async {
      picks++;
      return picks == 1 ? <String>[file.path] : const <String>[];
    });
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-start')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-review-text-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-review-text-1')), findsOneWidget);
    expect(find.byKey(const Key('ocr-review-text-3')), findsOneWidget);
    expect(find.byKey(const Key('ocr-error')), findsNothing);
  });
}

class _DialogHarness {
  OcrMaterial? confirmed;
  bool confirmSucceeds = true;
  bool? result;
}
