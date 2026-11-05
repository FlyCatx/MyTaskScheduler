// JSONL client for `ocr_host.exe`.
//
// The host is a bounded child process: stdout is line-delimited JSON, stderr is
// diagnostics only, and the exit code distinguishes success / partial / fatal.
// This client
//   * parses the stream incrementally (a line may be split across chunks),
//   * reports progress per page,
//   * enforces a job timeout and an inter-event silence timeout by killing the
//     child,
//   * honours cancellation by killing the child, and drops any late event after
//     the job is finished (so a cancelled job can never leak into another one),
//   * never pretends a partial job is complete: failed/missing pages stay in
//     [OcrJobResult.failures] (or [OcrJobResult.jobError] for whole-job errors).
//
// No network, no shell: the executable path is always an explicit file path and
// arguments are passed as a list (never a command string).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ocr_host.dart';
import 'ocr_types.dart';

/// Injection point for tests: replaces `Process.start`.
typedef OcrProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// Thrown for whole-job client failures (host missing/corrupt protocol/...).
class OcrClientException implements Exception {
  OcrClientException(this.error);

  final OcrError error;

  @override
  String toString() => 'OcrClientException(${error.code.wire}): ${error.message}';
}

/// Thrown when the host executable cannot be started at all.
class OcrHostMissingException extends OcrClientException {
  OcrHostMissingException(super.error, {this.hostPath});

  final String? hostPath;
}

/// One request for the host. Built by `OcrService`, never by widgets directly.
class OcrJobRequest {
  const OcrJobRequest({
    required this.filePath,
    required this.kind,
    this.pages = const <int>[],
    this.languages = const <String>[],
    this.dpi = 150,
    this.password,
    this.maxPixels = 40000000,
    this.maxDimension = 10000,
    this.maxPages = 300,
    this.watchStdin = true,
  });

  final String filePath;
  final OcrSourceKind kind;

  /// 1-based ascending pages. Empty means "all pages" for PDFs (the host
  /// defaults to the whole document); images only have page 1.
  final List<int> pages;

  /// Language tags in preference order. Empty = host default (zh-Hans first).
  final List<String> languages;

  final int dpi;

  /// Only for encrypted PDFs. Never logged and never part of a cache key.
  final String? password;

  final int maxPixels;
  final int maxDimension;
  final int maxPages;
  final bool watchStdin;

  List<String> toArguments() {
    final args = <String>[
      if (kind == OcrSourceKind.pdf) ...<String>['--pdf', filePath],
      if (kind == OcrSourceKind.image) ...<String>['--image', filePath],
      if (pages.isNotEmpty) ...<String>['--pages', formatOcrPageSpec(pages)],
      if (languages.isNotEmpty) ...<String>['--lang', languages.join(',')],
      '--dpi',
      '$dpi',
      if ((password ?? '').isNotEmpty) ...<String>['--password', password!],
      '--max-pixels',
      '$maxPixels',
      '--max-dimension',
      '$maxDimension',
      '--max-pages',
      '$maxPages',
      if (watchStdin) '--watch-stdin',
    ];
    return args;
  }
}

// ---------------------------------------------------------------------------
// Parsed host events
// ---------------------------------------------------------------------------

sealed class OcrHostEvent {
  const OcrHostEvent();
}

/// `{"event":"ready",...}` - handshake; always the first event of a run.
class OcrReadyEvent extends OcrHostEvent {
  const OcrReadyEvent(this.hello);

  final OcrHostHello hello;

  /// True when the host reported at least one usable OCR recogniser.
  bool get hasRecognizer => hello.languages.any((language) => language.recognizer);
}

/// `{"event":"probe",...}` - all installed OCR languages.
class OcrProbeEvent extends OcrHostEvent {
  const OcrProbeEvent({
    required this.languages,
    required this.languageCount,
    required this.recognizerAvailable,
    required this.unavailableRequested,
  });

  final List<OcrLanguage> languages;
  final int languageCount;
  final bool recognizerAvailable;
  final int unavailableRequested;
}

/// `{"event":"info",...}` - document metadata without rendering.
class OcrInfoEvent extends OcrHostEvent {
  const OcrInfoEvent(this.info);

  final OcrDocumentInfo info;
}

/// `{"event":"page",...}` - one page finished rendering, OCR starts.
class OcrPageStartEvent extends OcrHostEvent {
  const OcrPageStartEvent({
    required this.page,
    required this.total,
    required this.width,
    required this.height,
    required this.dpi,
    required this.scaled,
  });

  final int page;
  final int total;
  final int width;
  final int height;
  final int dpi;
  final bool scaled;
}

/// `{"event":"result",...}` - a successfully recognised page.
class OcrPageResultEvent extends OcrHostEvent {
  const OcrPageResultEvent(this.result);

  final OcrPageResult result;
}

/// `{"event":"error",...}` - a per-page failure, or a whole-job failure when
/// page is 0.
class OcrPageErrorEvent extends OcrHostEvent {
  const OcrPageErrorEvent(this.error);

  final OcrError error;
}

/// `{"event":"done",...}` - the host finished the requested page list.
class OcrDoneEvent extends OcrHostEvent {
  const OcrDoneEvent({
    required this.pages,
    required this.ok,
    required this.failed,
    required this.cancelled,
    required this.elapsedMs,
  });

  final int pages;
  final int ok;
  final int failed;
  final bool cancelled;
  final int elapsedMs;
}

/// A line that is not valid JSON/an object we understand. Kept as an event so
/// the majority of a long job can still be used; the client also records it as
/// a protocol error.
class OcrProtocolErrorEvent extends OcrHostEvent {
  const OcrProtocolErrorEvent(this.message, {this.line});

  final String message;

  /// Short excerpt of the offending line (protocol output only, never document
  /// text; truncated to keep diagnostics bounded).
  final String? line;
}

/// Forward-compatible event: unknown `event` values are ignored, not fatal.
class OcrUnknownEvent extends OcrHostEvent {
  const OcrUnknownEvent(this.name, this.raw);

  final String name;
  final Map<String, dynamic> raw;
}

// ---------------------------------------------------------------------------
// JSONL parsing
// ---------------------------------------------------------------------------

/// Incremental JSONL parser.
///
/// Usage: feed decoded text chunks with [addChunk]; complete lines are returned
/// as events. A trailing partial line is buffered. [flush] converts a non-empty
/// remainder into a protocol error (the host always terminates lines with `\n`).
class OcrJsonlParser {
  String _pending = '';

  /// Feed one decoded chunk. Returns every event completed by this chunk.
  List<OcrHostEvent> addChunk(String chunk) {
    if (chunk.isEmpty) return const <OcrHostEvent>[];
    _pending += chunk;
    final events = <OcrHostEvent>[];
    var newline = _pending.indexOf('\n');
    while (newline >= 0) {
      final line = _pending.substring(0, newline);
      _pending = _pending.substring(newline + 1);
      final event = _parseLine(line, <OcrHostEvent>[]);
      if (event != null) events.add(event);
      newline = _pending.indexOf('\n');
    }
    return events;
  }

  /// Returns the final event for a leftover partial line (usually a protocol
  /// error), or `null` when the buffer is empty.
  OcrHostEvent? flush() {
    final remainder = _pending;
    _pending = '';
    if (remainder.trim().isEmpty) return null;
    return _parseLine(remainder, <OcrHostEvent>[]);
  }

  void reset() => _pending = '';

  /// Parses one complete line. Public for unit tests.
  static OcrHostEvent? parseLine(String line) => _parseLine(line, <OcrHostEvent>[]);

  static OcrHostEvent? _parseLine(String line, List<OcrHostEvent> sink) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (error) {
      return OcrProtocolErrorEvent(
        '无法解析本地 OCR 组件的输出行：${error.message}',
        line: _excerpt(trimmed),
      );
    }
    if (decoded is! Map) {
      return OcrProtocolErrorEvent(
        '本地 OCR 组件输出了非对象 JSON 行。',
        line: _excerpt(trimmed),
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    final name = (map['event'] as String?)?.trim() ?? '';
    switch (name) {
      case 'ready':
        final hello = OcrHostHello.fromJson(map);
        if (hello == null) {
          return OcrProtocolErrorEvent('ready 事件缺少 engine 字段。', line: _excerpt(trimmed));
        }
        return OcrReadyEvent(hello);
      case 'probe':
        return OcrProbeEvent(
          languages: _languages(map['languages']),
          languageCount: (map['languageCount'] as num?)?.toInt() ?? 0,
          recognizerAvailable: map['recognizerAvailable'] == true,
          unavailableRequested: (map['unavailableRequested'] as num?)?.toInt() ?? 0,
        );
      case 'info':
        return OcrInfoEvent(_documentInfo(map));
      case 'page':
        return OcrPageStartEvent(
          page: (map['page'] as num?)?.toInt() ?? 0,
          total: (map['total'] as num?)?.toInt() ?? 0,
          width: (map['width'] as num?)?.toInt() ?? 0,
          height: (map['height'] as num?)?.toInt() ?? 0,
          dpi: (map['dpi'] as num?)?.toInt() ?? 0,
          scaled: map['scaled'] == true,
        );
      case 'result':
        final result = OcrPageResult.fromJson(map);
        if (result == null) {
          return OcrProtocolErrorEvent(
            'result 事件缺少 page/text/width/height 字段。',
            line: _excerpt(trimmed),
          );
        }
        return OcrPageResultEvent(result);
      case 'error':
        final page = (map['page'] as num?)?.toInt() ?? 0;
        final code = OcrErrorCodeInfo.fromWire((map['code'] as String?) ?? '');
        final message = (map['message'] as String?)?.trim();
        return OcrPageErrorEvent(OcrError(
          code: code,
          message: (message == null || message.isEmpty) ? code.defaultMessage : message,
          page: page,
          detail: (map['detail'] as String?)?.trim(),
        ));
      case 'done':
        return OcrDoneEvent(
          pages: (map['pages'] as num?)?.toInt() ?? 0,
          ok: (map['ok'] as num?)?.toInt() ?? 0,
          failed: (map['failed'] as num?)?.toInt() ?? 0,
          cancelled: map['cancelled'] == true,
          elapsedMs: (map['elapsedMs'] as num?)?.toInt() ?? 0,
        );
      default:
        return OcrUnknownEvent(name, map);
    }
  }

  static String _excerpt(String line) {
    final single = line.replaceAll('\n', ' ');
    return single.length <= 160 ? single : '${single.substring(0, 160)}…';
  }

  static List<OcrLanguage> _languages(Object? raw) {
    final languages = <OcrLanguage>[];
    if (raw is List) {
      for (final item in raw) {
        final language = OcrLanguage.fromJson(item);
        if (language != null) languages.add(language);
      }
    }
    return languages;
  }

  static OcrDocumentInfo _documentInfo(Map<String, dynamic> map) {
    final widths = <int, double>{};
    final heights = <int, double>{};
    final rawSizes = map['pageSizes'];
    if (rawSizes is List) {
      for (final item in rawSizes) {
        if (item is! Map) continue;
        final pageMap = Map<String, dynamic>.from(item);
        final page = (pageMap['page'] as num?)?.toInt();
        if (page == null || page < 1) continue;
        final width = (pageMap['widthDip'] as num?)?.toDouble() ??
            (pageMap['width'] as num?)?.toDouble();
        final height = (pageMap['heightDip'] as num?)?.toDouble() ??
            (pageMap['height'] as num?)?.toDouble();
        if (width != null) widths[page] = width;
        if (height != null) heights[page] = height;
      }
    }
    return OcrDocumentInfo(
      kind: (map['source'] as String?) ?? '',
      pageCount: (map['pages'] as num?)?.toInt() ?? 0,
      encrypted: map['encrypted'] == true,
      pageWidthsDip: widths,
      pageHeightsDip: heights,
    );
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Internal outcome of one process run.
class _RunOutcome {
  _RunOutcome({
    required this.reason,
    required this.events,
    required this.stderr,
    this.exitCode,
  });

  /// done | exit | timeout | silence | cancelled.
  final String reason;
  final List<OcrHostEvent> events;
  final List<String> stderr;
  final int? exitCode;

  bool get timedOut => reason == 'timeout' || reason == 'silence';
  bool get cancelled => reason == 'cancelled';
}

/// Runs the OCR helper and turns its JSONL stream into typed results.
class OcrHostClient {
  OcrHostClient({
    required this.host,
    this.limits = OcrLimits.standard,
    OcrProcessStarter? processStarter,
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  final OcrHostLocation host;
  final OcrLimits limits;
  final OcrProcessStarter _processStarter;

  static Future<Process> _defaultProcessStarter(
          String executable, List<String> arguments) =>
      Process.start(executable, arguments, runInShell: false);

  /// Probes the host and its installed OCR languages.
  ///
  /// Never throws: every problem becomes an [OcrAvailability] with a Chinese
  /// [OcrAvailability.problem] explaining what is missing.
  Future<OcrAvailability> probe() async {
    Process process;
    try {
      process = await _processStarter(host.path, const <String>['--probe'])
          .timeout(limits.startupTimeout);
    } on TimeoutException {
      return OcrAvailability.unavailable(
        '本地 OCR 组件启动超时（${limits.startupTimeout.inSeconds} 秒）。',
        hostPath: host.path,
      );
    } on ProcessException catch (error) {
      return OcrAvailability.unavailable(
        '无法启动本地 OCR 组件（${error.message}）。请确认文件完整且可执行：${host.path}',
        hostPath: host.path,
      );
    } catch (error) {
      return OcrAvailability.unavailable(
        '无法启动本地 OCR 组件：$error',
        hostPath: host.path,
      );
    }

    final outcome = await _collect(
      process,
      isDone: (event) => event is OcrDoneEvent,
      timeout: limits.probeTimeout,
      silenceTimeout: limits.probeTimeout,
    );

    OcrHostHello? hello;
    OcrProbeEvent? probeEvent;
    String? protocolProblem;
    for (final event in outcome.events) {
      if (event is OcrReadyEvent) hello = event.hello;
      if (event is OcrProbeEvent) probeEvent = event;
      if (event is OcrProtocolErrorEvent) protocolProblem ??= event.message;
    }
    final languages = probeEvent?.languages.isNotEmpty == true
        ? probeEvent!.languages
        : (hello?.languages ?? const <OcrLanguage>[]);
    if (hello == null) {
      final detail = _stderrHint(outcome);
      return OcrAvailability.unavailable(
        '本地 OCR 组件没有返回握手信息'
        '${outcome.timedOut ? '（超时）' : ''}。$detail',
        hostPath: host.path,
      );
    }
    if (languages.isEmpty) {
      return OcrAvailability(
        available: false,
        hostPath: host.path,
        hostVersion: hello.hostVersion,
        engine: hello.engine,
        engineVersion: hello.engineVersion,
        pipelineVersion: hello.pipelineVersion,
        languages: languages,
        problem: '本机没有安装任何 OCR 识别语言组件。'
            '请在 Windows 设置 → 时间和语言 → 语言 中安装语言包'
            '（至少简体中文或英文的“光学字符识别”组件）后重试。'
            '${protocolProblem == null ? '' : '（$protocolProblem）'}',
        checkedAt: DateTime.now(),
      );
    }
    return OcrAvailability(
      available: true,
      hostPath: host.path,
      hostVersion: hello.hostVersion,
      engine: hello.engine,
      engineVersion: hello.engineVersion,
      pipelineVersion: hello.pipelineVersion,
      languages: languages,
      checkedAt: DateTime.now(),
    );
  }

  /// Reads page count / dimensions without rendering. Throws [OcrClientException]
  /// for encrypted/corrupt documents so the UI can show the real reason.
  Future<OcrDocumentInfo> documentInfo(String filePath, {String? password}) async {
    final arguments = <String>['--info', '--pdf', filePath];
    if ((password ?? '').isNotEmpty) {
      arguments.addAll(<String>['--password', password!]);
    }
    final outcome = await _runInfo(arguments);
    OcrInfoEvent? info;
    OcrError? error;
    for (final event in outcome.events) {
      if (event is OcrInfoEvent) info = event;
      if (event is OcrPageErrorEvent && event.error.page == 0) error = event.error;
    }
    if (error != null) throw OcrClientException(error);
    if (info == null) {
      throw OcrClientException(OcrError(
        code: outcome.timedOut ? OcrErrorCode.timeout : OcrErrorCode.protocolError,
        message: '读取文档信息失败'
            '${outcome.timedOut ? '（超时）' : ''}。${_stderrHint(outcome)}',
        detail: host.path,
      ));
    }
    return info.info;
  }

  /// Reads image metadata (single page).
  Future<OcrDocumentInfo> imageInfo(String filePath) async {
    final outcome = await _runInfo(<String>['--info', '--image', filePath]);
    OcrInfoEvent? info;
    OcrError? error;
    for (final event in outcome.events) {
      if (event is OcrInfoEvent) info = event;
      if (event is OcrPageErrorEvent && event.error.page == 0) error = event.error;
    }
    if (error != null) throw OcrClientException(error);
    if (info == null) {
      throw OcrClientException(OcrError(
        code: outcome.timedOut ? OcrErrorCode.timeout : OcrErrorCode.protocolError,
        message: '读取图片信息失败'
            '${outcome.timedOut ? '（超时）' : ''}。${_stderrHint(outcome)}',
        detail: host.path,
      ));
    }
    return info.info;
  }

  Future<_RunOutcome> _runInfo(List<String> arguments) async {
    Process process;
    try {
      process = await _processStarter(host.path, arguments)
          .timeout(limits.startupTimeout);
    } on TimeoutException {
      return _RunOutcome(
        reason: 'timeout',
        events: const <OcrHostEvent>[],
        stderr: const <String>[],
      );
    } on ProcessException catch (error) {
      throw OcrHostMissingException(
        OcrError(
          code: OcrErrorCode.hostMissing,
          message: '无法启动本地 OCR 组件：${error.message}',
          detail: host.path,
        ),
        hostPath: host.path,
      );
    }
    return _collect(
      process,
      isDone: (event) => event is OcrDoneEvent,
      timeout: limits.probeTimeout,
      silenceTimeout: limits.probeTimeout,
    );
  }

  /// Runs one OCR job. Never throws for document-level problems: those become
  /// [OcrJobResult.jobError]. Only an unstartable host throws.
  Future<OcrJobResult> run(
    OcrJobRequest request, {
    void Function(OcrProgress)? onProgress,
    OcrCancellation? cancellation,
  }) async {
    final stopwatch = Stopwatch()..start();
    final results = <OcrPageResult>[];
    final failures = <OcrPageFailure>[];
    OcrError? jobError;
    OcrHostHello? hello;

    _emit(onProgress, OcrProgress(
      phase: OcrPhase.preparing,
      totalPages: request.pages.length,
      message: '正在启动本地 OCR 组件',
    ));

    Process process;
    try {
      process = await _processStarter(host.path, request.toArguments())
          .timeout(limits.startupTimeout);
    } on TimeoutException {
      throw OcrClientException(OcrError(
        code: OcrErrorCode.timeout,
        message: '本地 OCR 组件启动超时（${limits.startupTimeout.inSeconds} 秒）。',
        detail: host.path,
      ));
    } on ProcessException catch (error) {
      throw OcrHostMissingException(
        OcrError(
          code: OcrErrorCode.hostMissing,
          message: '无法启动本地 OCR 组件：${error.message}',
          detail: host.path,
        ),
        hostPath: host.path,
      );
    }

    final outcome = await _collect(
      process,
      isDone: (event) => event is OcrDoneEvent,
      timeout: limits.jobTimeout,
      silenceTimeout: limits.pageTimeout,
      cancellation: cancellation,
      onEvent: (event) {
        if (event is OcrReadyEvent) {
          hello = event.hello;
          _emit(onProgress, OcrProgress(
            phase: OcrPhase.recognizing,
            totalPages: request.pages.length,
            message: '本地 OCR 开始识别（${hello!.engineVersion}）',
          ));
        } else if (event is OcrPageStartEvent) {
          _emit(onProgress, OcrProgress(
            phase: OcrPhase.recognizing,
            currentPage: event.page,
            totalPages: request.pages.length,
            completed: results.length,
            failed: failures.length,
            message: '正在识别第 ${event.page} 页',
          ));
        } else if (event is OcrPageResultEvent) {
          results.add(event.result);
          _emit(onProgress, OcrProgress(
            phase: OcrPhase.recognizing,
            currentPage: event.result.page,
            totalPages: request.pages.length,
            completed: results.length,
            failed: failures.length,
          ));
        } else if (event is OcrPageErrorEvent) {
          if (event.error.page <= 0) {
            jobError ??= event.error;
          } else {
            failures.add(OcrPageFailure(
              page: event.error.page,
              code: event.error.code,
              message: event.error.message,
              detail: event.error.detail,
            ));
          }
          _emit(onProgress, OcrProgress(
            phase: OcrPhase.recognizing,
            totalPages: request.pages.length,
            completed: results.length,
            failed: failures.length,
            message: event.error.page <= 0 ? event.error.message : null,
          ));
        } else if (event is OcrProtocolErrorEvent) {
          jobError ??= OcrError(
            code: OcrErrorCode.protocolError,
            message: event.message,
            detail: event.line,
          );
        }
      },
    );

    // Everything the host did not report is a missing page, never a success.
    if (jobError == null) {
      final haveResults = results.map((result) => result.page).toSet();
      final haveFailures = failures.map((failure) => failure.page).toSet();
      final pending = <int>[
        for (final page in request.pages)
          if (!haveResults.contains(page) && !haveFailures.contains(page)) page,
      ];
      if (pending.isNotEmpty) {
        final code = outcome.cancelled
            ? OcrErrorCode.cancelled
            : outcome.timedOut
                ? OcrErrorCode.timeout
                : OcrErrorCode.protocolError;
        for (final page in pending) {
          failures.add(OcrPageFailure(
            page: page,
            code: code,
            message: code == OcrErrorCode.cancelled
                ? '识别已取消，该页未完成。'
                : code == OcrErrorCode.timeout
                    ? '本地 OCR 超时，该页未完成。'
                    : '本地 OCR 组件没有返回该页结果。',
            detail: _stderrHint(outcome),
          ));
        }
      }
    }

    results.sort((a, b) => a.page.compareTo(b.page));
    failures.sort((a, b) => a.page.compareTo(b.page));
    _emit(onProgress, OcrProgress(
      phase: outcome.cancelled
          ? OcrPhase.failed
          : (jobError == null && failures.isEmpty ? OcrPhase.done : OcrPhase.finalizing),
      totalPages: request.pages.length,
      completed: results.length,
      failed: failures.length,
      message: outcome.cancelled ? '已取消' : null,
    ));

    if (hello == null && outcome.events.isEmpty) {
      // No handshake at all: the host did not start properly. Surface it as a
      // job error instead of an empty "success".
      jobError ??= OcrError(
        code: outcome.timedOut ? OcrErrorCode.timeout : OcrErrorCode.hostStartFailed,
        message: '本地 OCR 组件没有返回任何可用结果。${_stderrHint(outcome)}',
        detail: host.path,
      );
    }

    return OcrJobResult(
      sourcePath: request.filePath,
      sourceKind: request.kind.wire,
      totalPages: hello?.pages ?? 0,
      requestedPages: List<int>.unmodifiable(
          request.pages.isEmpty
              ? <int>[for (var page = 1; page <= (hello?.pages ?? 0); page++) page]
              : request.pages),
      results: List<OcrPageResult>.unmodifiable(results),
      failures: List<OcrPageFailure>.unmodifiable(failures),
      cancelled: outcome.cancelled,
      elapsed: stopwatch.elapsed,
      engine: hello?.engine ?? '',
      engineVersion: hello?.engineVersion ?? '',
      languages: List<String>.unmodifiable(
          hello?.languages.map((language) => language.tag).toList(growable: false) ??
              request.languages),
      dpi: request.dpi,
      hostVersion: hello?.hostVersion ?? '',
      jobError: jobError,
    );
  }

  static void _emit(void Function(OcrProgress)? callback, OcrProgress progress) {
    if (callback == null) return;
    try {
      callback(progress);
    } catch (_) {
      // Progress reporting must never break the job.
    }
  }

  static String _stderrHint(_RunOutcome outcome) {
    if (outcome.stderr.isEmpty) return '';
    final tail = outcome.stderr.last;
    return '（诊断：$tail）';
  }

  /// Spawns nothing else: consumes [process] until [isDone] fires, the process
  /// exits, the timeout expires or [cancellation] is triggered.
  Future<_RunOutcome> _collect(
    Process process, {
    required bool Function(OcrHostEvent event) isDone,
    required Duration timeout,
    Duration? silenceTimeout,
    OcrCancellation? cancellation,
    void Function(OcrHostEvent event)? onEvent,
  }) async {
    final events = <OcrHostEvent>[];
    final stderrLines = <String>[];
    final parser = OcrJsonlParser();
    final completer = Completer<String>();
    final stdoutClosed = Completer<void>();
    StreamSubscription<String>? stdoutSub;
    StreamSubscription<String>? stderrSub;
    Timer? timeoutTimer;
    Timer? silenceTimer;
    var stopped = false;
    // What ended the collection. A plain process "exit" still allows draining
    // buffered stdout lines; "done"/"cancelled"/timeouts stop processing at once
    // (late results must never join a finished job).
    String? terminalReason;

    void finish(String reason) {
      if (completer.isCompleted) return;
      terminalReason = reason;
      completer.complete(reason);
    }

    bool drainOnly() => terminalReason != null && terminalReason != 'exit';

    void armSilence() {
      if (silenceTimeout == null) return;
      silenceTimer?.cancel();
      silenceTimer = Timer(silenceTimeout, () {
        _kill(process);
        finish('silence');
      });
    }

    void handleEvent(OcrHostEvent event) {
      if (stopped || drainOnly()) return;
      events.add(event);
      try {
        onEvent?.call(event);
      } catch (_) {
        // A consumer exception must not stop stream processing.
      }
      if (isDone(event)) {
        finish('done');
      } else {
        armSilence();
      }
    }

    timeoutTimer = Timer(timeout, () {
      _kill(process);
      finish('timeout');
    });
    armSilence();

    stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        for (final event in parser.addChunk('$line\n')) {
          handleEvent(event);
          if (drainOnly()) break;
        }
      },
      onError: (Object error) {
        stderrLines.add('stdout: $error');
      },
      onDone: () {
        if (!stdoutClosed.isCompleted) stdoutClosed.complete();
        if (stopped) return;
        final remainder = parser.flush();
        if (remainder != null) handleEvent(remainder);
      },
    );
    stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        stderrLines.add(trimmed.length <= 400 ? trimmed : '${trimmed.substring(0, 400)}…');
        if (stderrLines.length > 40) stderrLines.removeAt(0);
      },
      onError: (Object error) {
        stderrLines.add('stderr: $error');
      },
    );

    process.exitCode.then((code) {
      if (!completer.isCompleted) finish('exit');
    }).catchError((Object _) {
      if (!completer.isCompleted) finish('exit');
    });

    void cancelListener() {
      _kill(process);
      finish('cancelled');
    }

    cancellation?.addListener(cancelListener);

    final reason = await completer.future;
    // A process that simply exited may still have buffered stdout lines in
    // flight; drain them before dropping late events.
    if (reason == 'exit' && !stdoutClosed.isCompleted) {
      try {
        await stdoutClosed.future.timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // Timed out: proceed with what we have.
      }
    }
    stopped = true;
    timeoutTimer.cancel();
    silenceTimer?.cancel();
    cancellation?.removeListener(cancelListener);

    if (reason == 'timeout' || reason == 'silence' || reason == 'cancelled') {
      _kill(process);
    }
    int? exitCode;
    try {
      exitCode = await process.exitCode.timeout(limits.cancelGrace, onTimeout: () {
        _kill(process);
        return -1;
      });
    } catch (_) {
      exitCode = null;
    }

    // Give the stdout decoder a last chance to flush buffered lines, but never
    // wait forever on a dead pipe.
    if (!stdoutClosed.isCompleted) {
      try {
        await stdoutClosed.future.timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // Timed out: stop reading.
      }
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();

    return _RunOutcome(
      reason: reason,
      events: List<OcrHostEvent>.unmodifiable(events),
      stderr: List<String>.unmodifiable(stderrLines),
      exitCode: exitCode,
    );
  }

  static void _kill(Process process) {
    try {
      process.kill();
    } catch (_) {
      // Already exited.
    }
  }
}
