import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_service.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

import 'support/fake_ocr.dart';

void main() {
  late Directory dataRoot;
  late Directory docRoot;
  late FakeOcrClient fakeClient;
  late OcrService service;

  OcrService buildService({bool enableCache = true, OcrLimits? limits}) {
    fakeClient = FakeOcrClient(host: fakeHostLocation());
    return OcrService(
      dataRoot: dataRoot,
      limits: limits ?? fastOcrLimits,
      discovery: OcrHostDiscovery(
        location: fakeHostLocation(),
        attempted: const <OcrHostCandidate>[],
      ),
      clientFactory: (_) => fakeClient,
      enableCache: enableCache,
    );
  }

  setUp(() async {
    dataRoot = await Directory.systemTemp.createTemp('ocr_service_data_');
    docRoot = await Directory.systemTemp.createTemp('ocr_service_docs_');
    service = buildService();
  });

  tearDown(() async {
    for (final dir in <Directory>[dataRoot, docRoot]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<File> writePdf(String name, String content) async {
    final file = File('${docRoot.path}${Platform.pathSeparator}$name');
    await file.writeAsString(content);
    return file;
  }

  group('availability', () {
    test('missing host reports the attempted packaged path and env variable', () async {
      final missing = OcrService(
        dataRoot: dataRoot,
        limits: fastOcrLimits,
        discovery: const OcrHostDiscovery(
          location: null,
          attempted: <OcrHostCandidate>[
            OcrHostCandidate(
              path: r'C:\Apps\TaskScheduler\data\ocr\ocr_host.exe',
              source: 'packaged',
            ),
          ],
        ),
        clientFactory: (_) => fakeClient,
      );
      final availability = await missing.availability();
      expect(availability.available, isFalse);
      expect(availability.problem, contains('data\\ocr\\ocr_host.exe'));
      expect(availability.problem, contains('TASKSCHEDULER_OCR_HOST'));
    });

    test('probes once and exposes languages', () async {
      final availability = await service.availability();
      expect(availability.available, isTrue);
      expect(availability.languages.map((language) => language.tag), <String>[
        'zh-Hans-CN',
        'en-US',
      ]);
      await service.availability();
      expect(fakeClient.probeCalls, 1);
      expect(service.hostLocation, isNotNull);
    });

    test('no OCR language makes recognition fail with noLanguage', () async {
      fakeClient.probeResult = OcrAvailability(
        available: false,
        hostPath: fakeHostLocation().path,
        problem: '本机没有安装任何 OCR 识别语言组件。',
      );
      await service.availability();
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      await expectLater(
        service.recognize(filePath: file.path, pages: const <int>[1]),
        throwsA(isA<OcrClientException>().having(
          (error) => error.error.code,
          'code',
          OcrErrorCode.noLanguage,
        )),
      );
    });
  });

  group('recognize', () {
    test('returns a complete result and reports progress', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final progress = <OcrProgress>[];
      final job = await service.recognize(
        filePath: file.path,
        pages: const <int>[1, 2],
        dpi: 150,
        onProgress: progress.add,
      );
      expect(job.isComplete, isTrue);
      expect(job.results.map((result) => result.page), <int>[1, 2]);
      expect(job.totalPages, 3);
      expect(job.dpi, 150);
      expect(job.sourceKind, 'pdf');
      expect(progress, isNotEmpty);
      expect(fakeClient.runRequests.single.pages, <int>[1, 2]);
      expect(fakeClient.runRequests.single.languages, containsAll(<String>['zh-Hans-CN', 'en-US']));
    });

    test('all pages request expands to the document page count', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await service.recognize(filePath: file.path);
      expect(job.requestedPages, <int>[1, 2, 3]);
      expect(fakeClient.runRequests.single.pages, <int>[1, 2, 3]);
    });

    test('out-of-range pages become failures without running the host', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await service.recognize(
        filePath: file.path,
        pages: const <int>[1, 9],
      );
      expect(fakeClient.runRequests.single.pages, <int>[1]);
      expect(job.failures.single.page, 9);
      expect(job.failures.single.code, OcrErrorCode.pageOutOfRange);
      expect(job.isComplete, isFalse);
    });

    test('too many pages is refused with too_large before spawning work', () async {
      final limited = buildService(
        limits: const OcrLimits(
          maxPagesPerJob: 2,
          maxPixelsPerPage: 40000000,
          maxDimension: 10000,
          maxFileBytes: 256 * 1024 * 1024,
          probeTimeout: Duration(milliseconds: 600),
          startupTimeout: Duration(milliseconds: 600),
          pageTimeout: Duration(milliseconds: 300),
          jobTimeout: Duration(seconds: 2),
          cancelGrace: Duration(milliseconds: 150),
        ),
      );
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await limited.recognize(
        filePath: file.path,
        pages: const <int>[1, 2, 3],
      );
      expect(job.jobError, isNotNull);
      expect(job.jobError!.code, OcrErrorCode.tooLarge);
      expect(fakeClient.runRequests, isEmpty);
    });

    test('unsupported format and missing file are job errors', () async {
      final txt = File('${docRoot.path}${Platform.pathSeparator}notes.txt');
      await txt.writeAsString('hello');
      final unsupported = await service.recognize(filePath: txt.path);
      expect(unsupported.jobError!.code, OcrErrorCode.unsupportedFormat);

      final missing = await service.recognize(
        filePath: '${docRoot.path}${Platform.pathSeparator}missing.pdf',
      );
      expect(missing.jobError!.code, OcrErrorCode.renderFailed);
    });

    test('partial failure is returned as partial, never complete', () async {
      fakeClient.runHandler = (request) async => OcrJobResult(
            sourcePath: request.filePath,
            sourceKind: request.kind.wire,
            totalPages: 3,
            requestedPages: request.pages,
            results: <OcrPageResult>[
              fakeJobResult(request: request, pages: <int>[1]).results.single,
            ],
            failures: const <OcrPageFailure>[
              OcrPageFailure(page: 2, code: OcrErrorCode.ocrFailed, message: '该页没有识别出文字。'),
            ],
            engine: 'Windows.Media.Ocr',
            engineVersion: 'Windows.Media.Ocr/test',
            dpi: request.dpi,
          );
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await service.recognize(filePath: file.path, pages: const <int>[1, 2]);
      expect(job.results, hasLength(1));
      expect(job.failures.single.page, 2);
      expect(job.isComplete, isFalse);
      expect(job.isPartial, isTrue);
    });

    test('whole-job failure from the host is passed through', () async {
      fakeClient.runHandler = (request) async => fakeJobResult(
            request: request,
            pages: const <int>[],
            failures: const <OcrPageFailure>[],
            jobError: const OcrError(
              code: OcrErrorCode.encrypted,
              message: 'PDF 已加密',
            ),
          );
      final file = await writePdf('locked.pdf', 'pdf-bytes');
      final job = await service.recognize(filePath: file.path, pages: const <int>[1]);
      expect(job.jobError, isNotNull);
      expect(job.jobError!.code, OcrErrorCode.encrypted);
      expect(job.isComplete, isFalse);
    });

    test('cancelled host job is marked cancelled and not cached', () async {
      fakeClient.runHandler = (request) async => fakeJobResult(
            request: request,
            pages: const <int>[],
            failures: const <OcrPageFailure>[
              OcrPageFailure(
                page: 1,
                code: OcrErrorCode.cancelled,
                message: '识别已取消，该页未完成。',
              ),
            ],
            cancelled: true,
          );
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await service.recognize(filePath: file.path, pages: const <int>[1]);
      expect(job.cancelled, isTrue);
      expect(job.failures.single.code, OcrErrorCode.cancelled);
      expect(job.isComplete, isFalse);
    });

    test('DPI outside the allowed range is clamped with a warning', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final job = await service.recognize(
        filePath: file.path,
        pages: const <int>[1],
        dpi: 9999,
      );
      expect(job.dpi, OcrLimits.standard.maxDpi);
      expect(job.warning, contains('DPI'));
    });

    test('a run is serialised: concurrency is 1', () async {
      var active = 0;
      var maxActive = 0;
      fakeClient.runHandler = (request) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        active--;
        return fakeJobResult(request: request, pages: request.pages);
      };
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final futures = <Future<OcrJobResult>>[
        service.recognize(filePath: file.path, pages: const <int>[1]),
        service.recognize(filePath: file.path, pages: const <int>[2]),
      ];
      final jobs = await Future.wait(futures);
      expect(jobs.map((job) => job.isComplete), <bool>[true, true]);
      expect(maxActive, 1);
      expect(fakeClient.runRequests, hasLength(2));
    });
  });

  group('cache', () {
    test('second run of an unchanged file is served from cache', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      final first = await service.recognize(filePath: file.path, pages: const <int>[1, 2]);
      expect(first.cachedPages, isEmpty);
      expect(fakeClient.runRequests, hasLength(1));

      final second = await service.recognize(filePath: file.path, pages: const <int>[1, 2]);
      expect(fakeClient.runRequests, hasLength(1), reason: 'no new host run expected');
      expect(second.isComplete, isTrue);
      expect(second.cachedPages, <int>[1, 2]);
      expect(second.results.every((result) => result.fromCache), isTrue);
    });

    test('changing the file content invalidates the cache', () async {
      final file = await writePdf('scan.pdf', 'version-1');
      await service.recognize(filePath: file.path, pages: const <int>[1]);
      await file.writeAsString('version-2');
      await service.recognize(filePath: file.path, pages: const <int>[1]);
      expect(fakeClient.runRequests, hasLength(2));
    });

    test('changing DPI bypasses the cache', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      await service.recognize(filePath: file.path, pages: const <int>[1], dpi: 150);
      await service.recognize(filePath: file.path, pages: const <int>[1], dpi: 200);
      expect(fakeClient.runRequests, hasLength(2));
    });

    test('cache disabled always runs the host', () async {
      final uncached = buildService(enableCache: false);
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      await uncached.recognize(filePath: file.path, pages: const <int>[1]);
      await uncached.recognize(filePath: file.path, pages: const <int>[1]);
      expect(fakeClient.runRequests, hasLength(2));
    });

    test('clearCache empties the on-disk cache', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      await service.recognize(filePath: file.path, pages: const <int>[1]);
      expect(await service.cacheSizeBytes(), greaterThan(0));
      expect(await service.clearCache(), greaterThan(0));
      expect(await service.cacheSizeBytes(), 0);
    });

    test('only failed pages are retried; successful ones come from cache', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
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
              OcrPageFailure(page: 2, code: OcrErrorCode.ocrFailed, message: '失败'),
            ],
            engine: 'Windows.Media.Ocr',
            engineVersion: 'Windows.Media.Ocr/test',
            dpi: request.dpi,
          );
        }
        return fakeJobResult(request: request, pages: request.pages);
      };
      final first = await service.recognize(filePath: file.path, pages: const <int>[1, 2]);
      expect(first.cachedPages, isEmpty);
      final second = await service.recognize(filePath: file.path, pages: const <int>[1, 2]);
      expect(fakeClient.runRequests, hasLength(2));
      expect(fakeClient.runRequests.last.pages, <int>[2]);
      expect(second.cachedPages, <int>[1]);
      expect(second.isComplete, isTrue);
    });
  });

  group('detectPages', () {
    test('image input selects page 1 without OCRing', () async {
      final image = File('${docRoot.path}${Platform.pathSeparator}scan.png');
      await image.writeAsBytes(const <int>[1, 2, 3]);
      final detection = await service.detectPages(image.path);
      expect(detection.detectionFailed, isFalse);
      expect(detection.pagesToOcr, <int>[1]);
      expect(fakeClient.runRequests, isEmpty);
    });

    test('an unreadable text layer falls back to the host page count', () async {
      final file = await writePdf('scan.pdf', 'pdf-bytes');
      fakeClient.documentInfoResult = const OcrDocumentInfo(kind: 'pdf', pageCount: 5);
      final detection = await service.detectPages(file.path);
      // The fake bytes are not a real PDF, so the text layer cannot be read; the
      // page count still comes from the host (metadata only) and every page is
      // proposed for OCR with an explicit warning - never a silent skip.
      expect(detection.detectionFailed, isFalse);
      expect(detection.pageCount, 5);
      expect(detection.pagesToOcr, <int>[1, 2, 3, 4, 5]);
      expect(detection.warning, contains('文字层读取失败'));
    });
  });
}
