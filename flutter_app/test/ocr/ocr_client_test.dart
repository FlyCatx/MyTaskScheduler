import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

import 'support/fake_ocr.dart';

OcrJobRequest pdfRequest({List<int> pages = const <int>[1, 2, 3]}) => OcrJobRequest(
      filePath: r'C:\docs\scan.pdf',
      kind: OcrSourceKind.pdf,
      pages: pages,
      languages: const <String>['zh-Hans-CN', 'en-US'],
      dpi: 150,
    );

OcrHostClient clientWith(
  Future<void> Function(FakeProcess process) script, {
  OcrLimits limits = fastOcrLimits,
  void Function(String executable, List<String> arguments)? onSpawn,
}) {
  Future<Process> starter(String executable, List<String> arguments) async {
    onSpawn?.call(executable, arguments);
    final process = FakeProcess();
    Timer(const Duration(milliseconds: 1), () {
      script(process);
    });
    return process;
  }
  return OcrHostClient(
    host: fakeHostLocation(),
    limits: limits,
    processStarter: starter,
  );
}

void main() {
  group('OcrHostClient.run', () {
    test('happy path parses results, reports progress and completes', () async {
      final progress = <OcrProgress>[];
      final args = <String>[];
      final client = clientWith(
        (process) async {
          process.emit(readyEvent(pages: 3));
          process.emit(<String, Object?>{
            'event': 'page',
            'page': 1,
            'index': 1,
            'total': 3,
            'width': 1240,
            'height': 1754,
            'dpi': 150,
            'scaled': false,
          });
          process.emit(resultEvent(page: 1, text: '日期：2026年11月4日'));
          process.emit(<String, Object?>{
            'event': 'page',
            'page': 2,
            'index': 2,
            'total': 3,
            'width': 1240,
            'height': 1754,
            'dpi': 150,
            'scaled': false,
          });
          process.emit(resultEvent(page: 2, text: '工时：2.5小时'));
          process.emit(doneEvent(pages: 3, ok: 2, failed: 0));
          await process.complete(0);
        },
        onSpawn: (executable, arguments) {
          args
            ..clear()
            ..addAll(arguments);
        },
      );

      final job = await client.run(
        pdfRequest(pages: const <int>[1, 2]),
        onProgress: progress.add,
      );

      expect(job.results.map((r) => r.page), <int>[1, 2]);
      expect(job.failures, isEmpty);
      expect(job.cancelled, isFalse);
      expect(job.isComplete, isTrue);
      expect(job.sourceKind, 'pdf');
      expect(job.dpi, 150);
      expect(job.engineVersion, 'Windows.Media.Ocr/test');
      expect(progress, isNotEmpty);
      expect(progress.last.completed, 2);
      expect(args, containsAll(<String>['--pdf', r'C:\docs\scan.pdf', '--pages', '1-2']));
      expect(args, contains('--lang'));
      expect(args, contains('zh-Hans-CN,en-US'));
      expect(args, contains('--watch-stdin'));
    });

    test('partial failure keeps the failed page and never completes', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(pages: 2));
        process.emit(resultEvent(page: 1, text: '第一页'));
        process.emit(errorEvent(page: 2, message: '该页没有识别出文字。'));
        process.emit(doneEvent(pages: 2, ok: 1, failed: 1));
        await process.complete(1);
      });

      final job = await client.run(pdfRequest(pages: const <int>[1, 2]));
      expect(job.results.map((r) => r.page), <int>[1]);
      expect(job.failures.single.page, 2);
      expect(job.failures.single.code, OcrErrorCode.ocrFailed);
      expect(job.isComplete, isFalse);
      expect(job.isPartial, isTrue);
      expect(job.coverageLabel, contains('1/2'));
    });

    test('a page the host never reports becomes a failure, not a success', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(pages: 3));
        process.emit(resultEvent(page: 1));
        process.emit(doneEvent(pages: 3, ok: 1, failed: 0));
        await process.complete(0);
      });

      final job = await client.run(pdfRequest());
      expect(job.results.map((r) => r.page), <int>[1]);
      expect(job.failures.map((f) => f.page), <int>[2, 3]);
      expect(job.failures.every((f) => f.code == OcrErrorCode.protocolError), isTrue);
      expect(job.isComplete, isFalse);
    });

    test('whole-job error (page 0) becomes jobError', () async {
      final client = clientWith((process) async {
        process.emit(errorEvent(
          page: 0,
          code: 'no_language',
          message: '本机没有可用的 OCR 语言组件。',
        ));
        process.emit(doneEvent(pages: 0, ok: 0, failed: 0));
        await process.complete(2);
      });

      final job = await client.run(pdfRequest());
      expect(job.jobError, isNotNull);
      expect(job.jobError!.code, OcrErrorCode.noLanguage);
      expect(job.results, isEmpty);
      expect(job.isComplete, isFalse);
      expect(job.isFailure, isTrue);
    });

    test('inactivity timeout kills the process and reports the pages', () async {
      const limits = OcrLimits(
        probeTimeout: Duration(milliseconds: 300),
        startupTimeout: Duration(milliseconds: 300),
        pageTimeout: Duration(milliseconds: 150),
        jobTimeout: Duration(seconds: 2),
        cancelGrace: Duration(milliseconds: 100),
      );
      FakeProcess? spawned;
      final client = clientWith(
        (process) async {
          spawned = process;
          process.emit(readyEvent(pages: 2));
          // Then silence forever (test ends after the timeout).
        },
        limits: limits,
      );

      final job = await client.run(pdfRequest(pages: const <int>[1, 2]));
      expect(job.results, isEmpty);
      expect(job.failures.map((f) => f.page), <int>[1, 2]);
      expect(job.failures.every((f) => f.code == OcrErrorCode.timeout), isTrue);
      expect(job.isComplete, isFalse);
      expect(spawned!.killed, isTrue);
    });

    test('job timeout is enforced even with a chatty process', () async {
      const limits = OcrLimits(
        probeTimeout: Duration(milliseconds: 200),
        startupTimeout: Duration(milliseconds: 200),
        pageTimeout: Duration(seconds: 5),
        jobTimeout: Duration(milliseconds: 250),
        cancelGrace: Duration(milliseconds: 100),
      );
      final client = clientWith(
        (process) async {
          process.emit(readyEvent(pages: 50));
          // Emit page events slower than the timeout.
          Timer.periodic(const Duration(milliseconds: 40), (timer) {
            if (process.exited) {
              timer.cancel();
              return;
            }
            process.emit(resultEvent(page: 1));
          });
        },
        limits: limits,
      );

      final job = await client.run(pdfRequest(pages: const <int>[1, 2, 3]));
      expect(job.isComplete, isFalse);
      expect(job.failures, isNotEmpty);
      expect(job.failures.every((f) => f.code == OcrErrorCode.timeout), isTrue);
    });

    test('cancellation kills the child and marks the remaining pages', () async {
      final cancellation = OcrCancellation();
      FakeProcess? spawned;
      final client = clientWith((process) async {
        spawned = process;
        process.emit(readyEvent(pages: 3));
      });

      final future = client.run(
        pdfRequest(),
        cancellation: cancellation,
      );
      // Let the client subscribe and start the job, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cancellation.cancel();
      final job = await future;

      expect(job.cancelled, isTrue);
      expect(job.failures.map((f) => f.page), <int>[1, 2, 3]);
      expect(job.failures.every((f) => f.code == OcrErrorCode.cancelled), isTrue);
      expect(job.isComplete, isFalse);
      expect(spawned!.killed, isTrue);
    });

    test('late events after done are dropped', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(pages: 2));
        process.emit(resultEvent(page: 1, text: '第一页'));
        process.emit(doneEvent(pages: 2, ok: 1, failed: 0));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        process.emit(resultEvent(page: 2, text: '迟到结果'));
        process.emitStderr('late output');
        await process.complete(0);
      });

      final job = await client.run(pdfRequest(pages: const <int>[1, 2]));
      expect(job.results.map((r) => r.page), <int>[1]);
      expect(job.results.any((r) => r.text.contains('迟到')), isFalse);
    });

    test('late result after cancellation cannot join another job', () async {
      final cancellation = OcrCancellation();
      final client = clientWith((process) async {
        process.emit(readyEvent(pages: 2));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        process.emit(resultEvent(page: 1, text: '取消后才到的结果'));
      });
      final future = client.run(pdfRequest(pages: const <int>[1, 2]),
          cancellation: cancellation);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancellation.cancel();
      final job = await future;
      expect(job.cancelled, isTrue);
      expect(job.results, isEmpty);
    });

    test('malformed protocol output becomes a protocol job error', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(pages: 1));
        process.emitRaw('not-json\n');
        process.emit(resultEvent(page: 1));
        process.emit(doneEvent(pages: 1, ok: 1, failed: 0));
        await process.complete(0);
      });

      final job = await client.run(pdfRequest(pages: const <int>[1]));
      expect(job.jobError, isNotNull);
      expect(job.jobError!.code, OcrErrorCode.protocolError);
      expect(job.isComplete, isFalse);
      // The valid page can still be used.
      expect(job.results, hasLength(1));
    });

    test('a process that exits without done is not a success', () async {
      final client = clientWith((process) async {
        process.emit(errorEvent(page: 0, code: 'encrypted', message: 'PDF 已加密'));
        await process.complete(2);
      });

      final job = await client.run(pdfRequest());
      expect(job.jobError, isNotNull);
      expect(job.jobError!.code, OcrErrorCode.encrypted);
      expect(job.results, isEmpty);
      expect(job.failures, isEmpty);
    });

    test('missing executable throws a host-missing exception', () async {
      final client = OcrHostClient(
        host: fakeHostLocation(),
        limits: fastOcrLimits,
        processStarter: (executable, arguments) async {
          throw ProcessException(executable, arguments, 'not found', 2);
        },
      );
      await expectLater(
        client.run(pdfRequest()),
        throwsA(isA<OcrHostMissingException>()),
      );
    });

    test('encrypted PDF request passes the password only as an argument', () async {
      final args = <String>[];
      final client = OcrHostClient(
        host: fakeHostLocation(),
        limits: fastOcrLimits,
        processStarter: (executable, arguments) async {
          args
            ..clear()
            ..addAll(arguments);
          final process = FakeProcess();
          Timer(const Duration(milliseconds: 1), () async {
            process.emit(readyEvent(pages: 1));
            process.emit(resultEvent(page: 1));
            process.emit(doneEvent(pages: 1, ok: 1, failed: 0));
            await process.complete(0);
          });
          return process;
        },
      );
      final job = await client.run(const OcrJobRequest(
        filePath: r'C:\docs\secret.pdf',
        kind: OcrSourceKind.pdf,
        pages: <int>[1],
        password: 'p@ss word',
      ));
      expect(job.isComplete, isTrue);
      expect(args, containsAll(<String>['--password', 'p@ss word']));
    });
  });

  group('OcrHostClient.probe', () {
    test('parses languages from the probe event', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(mode: 'probe', pages: 0));
        process.emit(<String, Object?>{
          'event': 'probe',
          'engine': 'Windows.Media.Ocr',
          'languageCount': 2,
          'recognizerAvailable': true,
          'unavailableRequested': 0,
          'languages': <Map<String, Object?>>[
            <String, Object?>{
              'tag': 'zh-Hans-CN',
              'displayName': '中文（简体）',
              'recognizer': true,
            },
            <String, Object?>{
              'tag': 'en-US',
              'displayName': 'English',
              'recognizer': true,
            },
          ],
        });
        process.emit(doneEvent(pages: 0, ok: 0, failed: 0));
        await process.complete(0);
      });

      final availability = await client.probe();
      expect(availability.available, isTrue);
      expect(availability.languages.map((l) => l.tag), <String>['zh-Hans-CN', 'en-US']);
      expect(availability.hostPath, fakeHostLocation().path);
    });

    test('no languages is an explicit unavailable reason', () async {
      final client = clientWith((process) async {
        process.emit(readyEvent(mode: 'probe', pages: 0, languages: const <Map<String, Object?>>[]));
        process.emit(<String, Object?>{
          'event': 'probe',
          'languageCount': 0,
          'recognizerAvailable': false,
          'languages': const <Map<String, Object?>>[],
        });
        process.emit(doneEvent(pages: 0, ok: 0, failed: 0));
        await process.complete(0);
      });

      final availability = await client.probe();
      expect(availability.available, isFalse);
      expect(availability.problem, contains('OCR 识别语言'));
    });

    test('a probe timeout is reported, not thrown', () async {
      final client = clientWith(
        (process) async {
          // Never answers.
        },
        limits: const OcrLimits(
          probeTimeout: Duration(milliseconds: 100),
          startupTimeout: Duration(milliseconds: 100),
          pageTimeout: Duration(milliseconds: 100),
          jobTimeout: Duration(seconds: 1),
          cancelGrace: Duration(milliseconds: 50),
        ),
      );
      final availability = await client.probe();
      expect(availability.available, isFalse);
      expect(availability.problem, contains('超时'));
    });
  });

  group('OcrHostClient.documentInfo', () {
    test('returns page count and page sizes', () async {
      final client = clientWith((process) async {
        process.emit(<String, Object?>{
          'event': 'ready',
          'mode': 'info',
          'hostVersion': '1.0.0',
          'engine': 'Windows.Media.Ocr',
          'engineVersion': 'v1',
          'osVersion': '10.0',
          'pages': 2,
          'languages': const <Map<String, Object?>>[],
        });
        process.emit(<String, Object?>{
          'event': 'info',
          'source': 'pdf',
          'pages': 2,
          'encrypted': false,
          'pageSizes': <Map<String, Object?>>[
            <String, Object?>{'page': 1, 'widthDip': 793.6, 'heightDip': 1122.6},
            <String, Object?>{'page': 2, 'widthDip': 595.0, 'heightDip': 842.0},
          ],
        });
        process.emit(doneEvent(pages: 2, ok: 2, failed: 0));
        await process.complete(0);
      });

      final info = await client.documentInfo(r'C:\docs\scan.pdf');
      expect(info.pageCount, 2);
      expect(info.pageWidthsDip[2], closeTo(595.0, 0.01));
    });

    test('encrypted document throws a client exception with the code', () async {
      final client = clientWith((process) async {
        process.emit(errorEvent(page: 0, code: 'encrypted', message: 'PDF 已加密'));
        process.emit(doneEvent(pages: 0, ok: 0, failed: 0));
        await process.complete(2);
      });

      await expectLater(
        client.documentInfo(r'C:\docs\locked.pdf'),
        throwsA(isA<OcrClientException>().having(
          (error) => error.error.code,
          'code',
          OcrErrorCode.encrypted,
        )),
      );
    });
  });
}
