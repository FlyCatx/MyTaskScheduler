// Shared fakes for the OCR tests. No real process is spawned here.
//
// * FakeProcess implements the `Process` interface so OcrHostClient can be tested
//   deterministically (JSONL stream, timeouts, cancellation, partial failures).
// * FakeOcrClient lets OcrService (cache/limits/partial reporting) be tested
//   without the Windows OCR host.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

/// Short timeouts so failure/cancel tests run in milliseconds.
const OcrLimits fastOcrLimits = OcrLimits(
  probeTimeout: Duration(milliseconds: 600),
  startupTimeout: Duration(milliseconds: 600),
  pageTimeout: Duration(milliseconds: 300),
  jobTimeout: Duration(seconds: 2),
  cancelGrace: Duration(milliseconds: 150),
);

/// Fake child process. Feed it with [emit] / [emitRaw] and finish it with
/// [complete].
class FakeProcess implements Process {
  FakeProcess({this.exitCodeOnKill = -1});

  final StreamController<List<int>> _stdoutController = StreamController<List<int>>();
  final StreamController<List<int>> _stderrController = StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();
  final List<String> writtenToStdin = <String>[];
  final StreamController<List<int>> _stdinController = StreamController<List<int>>();
  late final IOSink _stdin = IOSink(_stdinController.sink);

  final int exitCodeOnKill;
  bool killed = false;
  int? killSignalNumber;

  @override
  int get pid => 424242;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    killSignalNumber = signal.signalNumber;
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(exitCodeOnKill);
    return true;
  }

  bool get exited => _exitCompleter.isCompleted;

  /// Emits one JSON object followed by a newline.
  void emit(Map<String, Object?> event) => emitRaw('${jsonEncode(event)}\n');

  /// Emits raw text (may be a partial line).
  void emitRaw(String text) {
    if (_stdoutController.isClosed) return;
    _stdoutController.add(utf8.encode(text));
  }

  void emitStderr(String line) {
    if (_stderrController.isClosed) return;
    _stderrController.add(utf8.encode('$line\n'));
  }

  /// Completes the process: exit code + closed streams.
  Future<void> complete([int code = 0]) async {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
    await _stdoutController.close();
    await _stderrController.close();
    if (!_stdinController.isClosed) await _stdinController.close();
  }
}

/// Builds a starter from a per-call script.
typedef FakeProcessScript = Future<void> Function(
    FakeProcess process, String executable, List<String> arguments);

OcrProcessStarter fakeStarter(FakeProcessScript script, {List<FakeProcess>? spawned}) {
  return (String executable, List<String> arguments) async {
    final process = FakeProcess();
    spawned?.add(process);
    // Deliver scripted events only after the client has attached its
    // subscriptions (it attaches them in the microtask continuation of this
    // await; a zero-duration timer runs after that).
    Timer(const Duration(milliseconds: 1), () {
      script(process, executable, arguments);
    });
    return process;
  };
}

/// Fake host client used by OcrService tests.
class FakeOcrClient extends OcrHostClient {
  FakeOcrClient({
    required super.host,
    super.limits = fastOcrLimits,
    this.probeResult,
    this.documentInfoResult,
    this.runHandler,
  });

  OcrAvailability? probeResult;
  OcrDocumentInfo? documentInfoResult;
  Future<OcrJobResult> Function(OcrJobRequest request)? runHandler;

  final List<OcrJobRequest> runRequests = <OcrJobRequest>[];
  int probeCalls = 0;
  int documentInfoCalls = 0;

  @override
  Future<OcrAvailability> probe() async {
    probeCalls++;
    return probeResult ??
        OcrAvailability(
          available: true,
          hostPath: host.path,
          hostVersion: '1.0.0',
          engine: 'Windows.Media.Ocr',
          engineVersion: 'Windows.Media.Ocr/test',
          languages: const <OcrLanguage>[
            OcrLanguage(tag: 'zh-Hans-CN', displayName: '中文（简体）'),
            OcrLanguage(tag: 'en-US', displayName: 'English'),
          ],
          checkedAt: DateTime.now(),
        );
  }

  @override
  Future<OcrDocumentInfo> documentInfo(String filePath, {String? password}) async {
    documentInfoCalls++;
    return documentInfoResult ??
        const OcrDocumentInfo(kind: 'pdf', pageCount: 3);
  }

  @override
  Future<OcrDocumentInfo> imageInfo(String filePath) async {
    documentInfoCalls++;
    return const OcrDocumentInfo(kind: 'image', pageCount: 1);
  }

  @override
  Future<OcrJobResult> run(
    OcrJobRequest request, {
    void Function(OcrProgress)? onProgress,
    OcrCancellation? cancellation,
  }) {
    runRequests.add(request);
    onProgress?.call(OcrProgress(
      phase: OcrPhase.recognizing,
      currentPage: request.pages.isEmpty ? 0 : request.pages.first,
      totalPages: request.pages.length,
      message: 'fake host running',
    ));
    final handler = runHandler;
    if (handler == null) {
      return Future<OcrJobResult>.value(
        fakeJobResult(request: request, pages: request.pages),
      );
    }
    return handler(request);
  }
}

OcrHostLocation fakeHostLocation() =>
    const OcrHostLocation(path: r'C:\fake\ocr\ocr_host.exe', source: 'explicit');

/// Builds a complete synthetic job result for [request].
OcrJobResult fakeJobResult({
  required OcrJobRequest request,
  required List<int> pages,
  Map<int, String> texts = const <int, String>{},
  List<OcrPageFailure> failures = const <OcrPageFailure>[],
  bool cancelled = false,
  OcrError? jobError,
  int? dpi,
}) {
  final results = <OcrPageResult>[
    for (final page in pages)
      OcrPageResult(
        page: page,
        text: texts[page] ?? '第 $page 页测试文字',
        lines: <OcrLine>[
          OcrLine(
            text: texts[page] ?? '第 $page 页测试文字',
            bbox: const OcrRect(10, 10, 400, 30),
          ),
        ],
        width: 1240,
        height: 1754,
        dpi: dpi ?? request.dpi,
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/test',
        language: 'zh-Hans-CN',
      ),
  ];
  return OcrJobResult(
    sourcePath: request.filePath,
    sourceKind: request.kind.wire,
    totalPages: pages.isEmpty ? 0 : pages.last,
    requestedPages: pages,
    results: results,
    failures: failures,
    cancelled: cancelled,
    elapsed: const Duration(milliseconds: 5),
    engine: 'Windows.Media.Ocr',
    engineVersion: 'Windows.Media.Ocr/test',
    languages: request.languages,
    dpi: dpi ?? request.dpi,
    hostVersion: '1.0.0',
    jobError: jobError,
  );
}

/// JSON lines used by FakeProcess-based tests (fields match the host protocol).
Map<String, Object?> readyEvent({
  int pages = 3,
  String mode = 'pdf',
  List<Map<String, Object?>>? languages,
}) =>
    <String, Object?>{
      'event': 'ready',
      'mode': mode,
      'host': 'taskscheduler-ocr-host',
      'hostVersion': '1.0.0',
      'engine': 'Windows.Media.Ocr',
      'engineVersion': 'Windows.Media.Ocr/test',
      'osVersion': '10.0.0.0',
      'pages': pages,
      if (mode == 'pdf' || mode == 'image') 'source': mode,
      'languages': languages ??
          <Map<String, Object?>>[
            <String, Object?>{
              'tag': 'zh-Hans-CN',
              'displayName': '中文（简体）',
              'nativeName': '中文',
              'recognizer': true,
            },
            <String, Object?>{
              'tag': 'en-US',
              'displayName': 'English',
              'nativeName': 'English',
              'recognizer': true,
            },
          ],
    };

Map<String, Object?> resultEvent({
  required int page,
  String text = '测试文字',
  int width = 1240,
  int height = 1754,
  int dpi = 150,
  int total = 3,
}) =>
    <String, Object?>{
      'event': 'result',
      'page': page,
      'total': total,
      'method': 'ocr',
      'engine': 'Windows.Media.Ocr',
      'engineVersion': 'Windows.Media.Ocr/test',
      'language': 'zh-Hans-CN',
      'dpi': dpi,
      'width': width,
      'height': height,
      'elapsedMs': 10,
      'text': text,
      'lines': <Map<String, Object?>>[
        <String, Object?>{
          'text': text,
          'confidence': null,
          'bbox': <double>[10, 10, 400, 30],
        },
      ],
    };

Map<String, Object?> errorEvent({
  required int page,
  String code = 'ocr_failed',
  String message = '该页没有识别出文字。',
}) =>
    <String, Object?>{
      'event': 'error',
      'page': page,
      'code': code,
      'message': message,
      'elapsedMs': 3,
    };

Map<String, Object?> doneEvent({
  required int pages,
  required int ok,
  required int failed,
  bool cancelled = false,
}) =>
    <String, Object?>{
      'event': 'done',
      'pages': pages,
      'ok': ok,
      'failed': failed,
      'cancelled': cancelled,
      'elapsedMs': 42,
    };
