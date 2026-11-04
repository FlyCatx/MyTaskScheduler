// Public data model for local OCR (R3-O).
//
// Design rules (see docs/r3/ocr/README.md):
//   * Local OCR is fully offline: nothing here imports dart:io networking, and
//     no model/API-key material ever becomes part of an OCR result or cache key.
//   * Failures are values, not exceptions, for *expected* per-page problems
//     (encrypted / render_failed / ocr_failed / too_large / ...). A job that
//     lost pages must never look like a complete job.
//   * The engine does not expose a confidence score. [OcrLine.confidence] is
//     therefore `null` for the Windows engine; the UI marks date/time/duration/
//     number fields for confirmation instead of inventing a number.
//   * Every result page carries a source reference: document content hash, page
//     number, rendered pixel geometry, DPI, engine + engine version, method.
//
// This file has no Flutter dependency and is safe to use from tests.

import 'dart:convert';

/// Stable machine-readable OCR error codes.
///
/// Codes 1-6 are emitted by `ocr_host.exe`; the remaining ones are produced by
/// the Dart layer itself (missing host, timeout, cancel, broken protocol).
enum OcrErrorCode {
  encrypted,
  renderFailed,
  ocrFailed,
  noLanguage,
  tooLarge,
  pageOutOfRange,
  hostMissing,
  hostStartFailed,
  protocolError,
  timeout,
  cancelled,
  unsupportedFormat,
}

extension OcrErrorCodeInfo on OcrErrorCode {
  /// Wire value used by the helper (`encrypted`, `render_failed`, ...).
  String get wire => switch (this) {
        OcrErrorCode.encrypted => 'encrypted',
        OcrErrorCode.renderFailed => 'render_failed',
        OcrErrorCode.ocrFailed => 'ocr_failed',
        OcrErrorCode.noLanguage => 'no_language',
        OcrErrorCode.tooLarge => 'too_large',
        OcrErrorCode.pageOutOfRange => 'page_out_of_range',
        OcrErrorCode.hostMissing => 'host_missing',
        OcrErrorCode.hostStartFailed => 'host_start_failed',
        OcrErrorCode.protocolError => 'protocol_error',
        OcrErrorCode.timeout => 'timeout',
        OcrErrorCode.cancelled => 'cancelled',
        OcrErrorCode.unsupportedFormat => 'unsupported_format',
      };

  /// Default user-facing Chinese explanation. The host sends its own message,
  /// which is preferred; this is the fallback for locally generated failures.
  String get defaultMessage => switch (this) {
        OcrErrorCode.encrypted =>
          '文档已加密或密码不正确，无法读取页面。请先解除密码保护，或提供正确密码。',
        OcrErrorCode.renderFailed => '页面渲染失败，无法进行识别。',
        OcrErrorCode.ocrFailed => '这一页没有识别出文字（空白、手写或非文字内容）。',
        OcrErrorCode.noLanguage =>
          '本机没有可用的 OCR 语言组件。请在 Windows 设置 → 时间和语言 → 语言 中安装对应语言。',
        OcrErrorCode.tooLarge => '页面像素或页数超过本地上限。请降低 DPI 或分批处理。',
        OcrErrorCode.pageOutOfRange => '页码范围超出文档实际页数。',
        OcrErrorCode.hostMissing =>
          '找不到本地 OCR 组件（ocr_host.exe）。请确认安装包完整，或设置环境变量 TASKSCHEDULER_OCR_HOST 指向该文件。',
        OcrErrorCode.hostStartFailed => '本地 OCR 组件无法启动。',
        OcrErrorCode.protocolError => '本地 OCR 组件输出无法解析（版本可能不匹配）。',
        OcrErrorCode.timeout => '本地 OCR 超时未完成。可以缩小页范围或降低 DPI 后重试。',
        OcrErrorCode.cancelled => '识别已取消。',
        OcrErrorCode.unsupportedFormat => '不支持的文件类型。仅支持 PDF、PNG、JPEG。',
      };

  static OcrErrorCode fromWire(String raw) {
    final value = raw.trim().toLowerCase();
    for (final code in OcrErrorCode.values) {
      if (code.wire == value) return code;
    }
    return OcrErrorCode.protocolError;
  }
}

/// One structured OCR failure (per page, or whole job when [page] is 0).
class OcrError {
  const OcrError({
    required this.code,
    required this.message,
    this.page = 0,
    this.detail,
  });

  final OcrErrorCode code;

  /// User-facing Chinese message (from the host when available).
  final String message;

  /// 1-based page number, or 0 for a whole-job failure.
  final int page;

  /// Short technical context for diagnostics. Never a stack trace and never
  /// document contents.
  final String? detail;

  String get wireCode => code.wire;

  OcrError copyWith({String? message, String? detail}) => OcrError(
        code: code,
        message: message ?? this.message,
        page: page,
        detail: detail ?? this.detail,
      );

  /// A newer message for the same failure keeps whatever detail exists.
  @override
  String toString() => 'OcrError(${code.wire}, page=$page): $message';
}

/// How a page's text was obtained.
enum OcrMethod {
  /// Existing PDF text layer (no OCR was run for that page).
  text,

  /// Local Windows OCR.
  ocr,
}

extension OcrMethodInfo on OcrMethod {
  String get value => switch (this) {
        OcrMethod.text => 'text',
        OcrMethod.ocr => 'ocr',
      };

  static OcrMethod fromValue(String raw) =>
      raw.trim().toLowerCase() == 'text' ? OcrMethod.text : OcrMethod.ocr;
}

/// What kind of source file an OCR job reads.
///
/// DOCX/PPTX keep their existing text path; only PDF and images need OCR.
enum OcrSourceKind {
  pdf,
  image,
  unsupported;

  static OcrSourceKind fromPath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    switch (extension) {
      case 'pdf':
        return OcrSourceKind.pdf;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'bmp':
      case 'tif':
      case 'tiff':
        return OcrSourceKind.image;
      default:
        return OcrSourceKind.unsupported;
    }
  }

  String get wire => switch (this) {
        OcrSourceKind.pdf => 'pdf',
        OcrSourceKind.image => 'image',
        OcrSourceKind.unsupported => 'unsupported',
      };
}
/// Rectangle in rendered-image pixels (top-left origin).
///
/// The rendered image size and DPI are stored next to it, so the same box can be
/// mapped back to the original page (`x / width * pageWidth`).
class OcrRect {
  const OcrRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  bool get isEmpty => width <= 0 || height <= 0;

  List<double> toJson() => <double>[x, y, width, height];

  static OcrRect? fromJson(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    final values = raw.map((v) => v is num ? v.toDouble() : null).toList(growable: false);
    if (values.any((v) => v == null)) return null;
    return OcrRect(values[0]!, values[1]!, values[2]!, values[3]!);
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  static OcrRect? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final x = (m['x'] as num?)?.toDouble();
    final y = (m['y'] as num?)?.toDouble();
    final w = (m['width'] as num?)?.toDouble();
    final h = (m['height'] as num?)?.toDouble();
    if (x == null || y == null || w == null || h == null) return null;
    return OcrRect(x, y, w, h);
  }

  @override
  String toString() => 'OcrRect(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, '
      '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}

/// One recognised line. `confidence` stays `null` when the engine does not
/// provide scores (Windows.Media.Ocr does not).
class OcrLine {
  const OcrLine({required this.text, this.confidence, this.bbox});

  final String text;
  final double? confidence;
  final OcrRect? bbox;

  bool get hasConfidence => confidence != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'confidence': confidence,
        if (bbox != null) 'bbox': bbox!.toMap(),
      };

  static OcrLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final text = m['text'];
    if (text is! String) return null;
    return OcrLine(
      text: text,
      confidence: (m['confidence'] as num?)?.toDouble(),
      // The host emits bbox as [x, y, w, h]; the cache format uses a map.
      bbox: OcrRect.fromJson(m['bbox']) ?? OcrRect.fromMap(m['bbox']),
    );
  }
}

/// A successfully recognised page.
class OcrPageResult {
  const OcrPageResult({
    required this.page,
    required this.text,
    this.lines = const <OcrLine>[],
    required this.width,
    required this.height,
    required this.dpi,
    required this.engine,
    required this.engineVersion,
    required this.language,
    this.method = OcrMethod.ocr,
    this.elapsedMs = 0,
    this.scaled = false,
    this.fromCache = false,
  });

  /// 1-based page number inside the source document.
  final int page;

  /// Raw recognised text (line-joined). Normalisation happens in
  /// `ocr_material.dart`; the raw text is kept for provenance/diffs.
  final String text;

  final List<OcrLine> lines;

  /// Rendered image geometry in pixels. Bounding boxes refer to this space.
  final int width;
  final int height;

  /// Requested DPI (render target for PDFs; informational for images).
  final int dpi;

  final String engine;
  final String engineVersion;
  final String language;
  final OcrMethod method;
  final int elapsedMs;

  /// True when the source image was downscaled to fit the pixel limit.
  final bool scaled;

  /// True when this page came from the local cache instead of a fresh run.
  final bool fromCache;

  /// Line count useful for compact progress/summary lines.
  int get lineCount => lines.length;

  /// Mean engine confidence when the engine provides one, else `null`.
  double? get meanConfidence {
    final values = <double>[
      for (final line in lines)
        if (line.confidence != null) line.confidence!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  OcrPageResult copyWith({bool? fromCache, bool? scaled}) => OcrPageResult(
        page: page,
        text: text,
        lines: lines,
        width: width,
        height: height,
        dpi: dpi,
        engine: engine,
        engineVersion: engineVersion,
        language: language,
        method: method,
        elapsedMs: elapsedMs,
        scaled: scaled ?? this.scaled,
        fromCache: fromCache ?? this.fromCache,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page': page,
        'text': text,
        'lines': lines.map((line) => line.toJson()).toList(growable: false),
        'width': width,
        'height': height,
        'dpi': dpi,
        'engine': engine,
        'engineVersion': engineVersion,
        'language': language,
        'method': method.value,
        'elapsedMs': elapsedMs,
        'scaled': scaled,
      };

  static OcrPageResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final page = (m['page'] as num?)?.toInt();
    final text = m['text'];
    final width = (m['width'] as num?)?.toInt();
    final height = (m['height'] as num?)?.toInt();
    if (page == null || page < 1 || text is! String) return null;
    if (width == null || width <= 0 || height == null || height <= 0) return null;
    final lines = <OcrLine>[];
    final rawLines = m['lines'];
    if (rawLines is List) {
      for (final item in rawLines) {
        final line = OcrLine.fromJson(item);
        if (line != null) lines.add(line);
      }
    }
    return OcrPageResult(
      page: page,
      text: text,
      lines: lines,
      width: width,
      height: height,
      dpi: (m['dpi'] as num?)?.toInt() ?? 0,
      engine: (m['engine'] as String?) ?? '',
      engineVersion: (m['engineVersion'] as String?) ?? '',
      language: (m['language'] as String?) ?? '',
      method: OcrMethodInfo.fromValue((m['method'] as String?) ?? 'ocr'),
      elapsedMs: (m['elapsedMs'] as num?)?.toInt() ?? 0,
      scaled: m['scaled'] == true,
    );
  }
}

/// A per-page failure (the page is *not* covered by [OcrJobResult.results]).
class OcrPageFailure {
  const OcrPageFailure({
    required this.page,
    required this.code,
    required this.message,
    this.detail,
    this.elapsedMs = 0,
  });

  final int page;
  final OcrErrorCode code;
  final String message;
  final String? detail;
  final int elapsedMs;

  bool get isCancelled => code == OcrErrorCode.cancelled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page': page,
        'code': code.wire,
        'message': message,
        if (detail != null) 'detail': detail,
        'elapsedMs': elapsedMs,
      };

  @override
  String toString() => 'OcrPageFailure(page=$page, ${code.wire}): $message';
}

/// The outcome of one OCR job. Partial success is represented explicitly:
/// successful pages live in [results], lost pages in [failures]; there is no
/// "silently successful" subset.
class OcrJobResult {
  const OcrJobResult({
    required this.sourcePath,
    required this.sourceKind,
    required this.totalPages,
    required this.requestedPages,
    this.results = const <OcrPageResult>[],
    this.failures = const <OcrPageFailure>[],
    this.cancelled = false,
    this.elapsed = Duration.zero,
    this.engine = '',
    this.engineVersion = '',
    this.languages = const <String>[],
    this.dpi = 0,
    this.sourceSha256,
    this.cachedPages = const <int>[],
    this.hostVersion = '',
    this.jobError,
    this.warning,
  });

  /// Absolute source path. Kept for provenance/UI; never part of the cache key
  /// (the content hash is used instead, so moving the file keeps the cache).
  final String sourcePath;

  /// `pdf` or `image`.
  final String sourceKind;

  /// Total pages in the source document (not just the requested range).
  final int totalPages;

  /// Requested 1-based pages, ascending.
  final List<int> requestedPages;

  /// Successful pages, ascending.
  final List<OcrPageResult> results;

  /// Pages that could not be recognised. Order is the request order.
  final List<OcrPageFailure> failures;

  /// True when the user cancelled: the job is incomplete by definition.
  final bool cancelled;

  final Duration elapsed;
  final String engine;
  final String engineVersion;
  final List<String> languages;
  final int dpi;
  final String? sourceSha256;

  /// Pages that were served from the local cache (no OCR process work).
  final List<int> cachedPages;

  final String hostVersion;

  /// Whole-job failure (page 0), e.g. encrypted document or no OCR language.
  /// Per-page problems live in [failures] instead.
  final OcrError? jobError;

  /// Non-fatal notice (e.g. the source file changed while it was being read).
  /// Never used to hide missing pages.
  final String? warning;

  /// True only when every requested page produced a result and nothing failed.
  bool get isComplete =>
      jobError == null &&
      !cancelled &&
      failures.isEmpty &&
      requestedPages.isNotEmpty &&
      results.length == requestedPages.length;

  bool get hasFailures => failures.isNotEmpty;

  bool get isPartial => results.isNotEmpty && !isComplete;

  bool get isFailure => results.isEmpty;

  /// Pages that still have no result (failed or cancelled).
  List<int> get missingPages {
    final have = results.map((r) => r.page).toSet();
    return <int>[
      for (final page in requestedPages)
        if (!have.contains(page)) page,
    ];
  }

  /// Human-readable coverage line, e.g. "3/5 页成功，2 页失败".
  String get coverageLabel =>
      '${results.length}/${requestedPages.length} 页成功'
      '${failures.isEmpty ? '' : '，${failures.length} 页失败'}'
      '${cancelled ? '（已取消）' : ''}';

  OcrJobResult copyWith({
    List<OcrPageResult>? results,
    List<OcrPageFailure>? failures,
    bool? cancelled,
    Duration? elapsed,
    List<int>? cachedPages,
  }) =>
      OcrJobResult(
        sourcePath: sourcePath,
        sourceKind: sourceKind,
        totalPages: totalPages,
        requestedPages: requestedPages,
        results: results ?? this.results,
        failures: failures ?? this.failures,
        cancelled: cancelled ?? this.cancelled,
        elapsed: elapsed ?? this.elapsed,
        engine: engine,
        engineVersion: engineVersion,
        languages: languages,
        dpi: dpi,
        sourceSha256: sourceSha256,
        cachedPages: cachedPages ?? this.cachedPages,
        hostVersion: hostVersion,
        jobError: jobError,
        warning: warning,
      );

  /// Single-line summary for logs/diagnostics. Contains no document text.
  String get summary => 'OCR($sourceKind, pages=${requestedPages.length}/'
      '$totalPages, ok=${results.length}, failed=${failures.length}, '
      'cancelled=$cancelled, ${elapsed.inMilliseconds}ms)';
}

/// Progress callback payload. All counters are 1-based/explicit so the UI never
/// has to guess.
class OcrProgress {
  const OcrProgress({
    required this.phase,
    this.currentPage = 0,
    this.totalPages = 0,
    this.completed = 0,
    this.failed = 0,
    this.message,
  });

  final OcrPhase phase;

  /// 1-based page currently being worked on (0 = none yet).
  final int currentPage;

  /// Number of requested pages.
  final int totalPages;

  /// Successfully completed pages so far.
  final int completed;

  /// Failed pages so far.
  final int failed;

  final String? message;

  /// 0..1 estimate: completed+failed over total. `null` while preparing.
  double? get fraction {
    if (totalPages <= 0) return null;
    return ((completed + failed) / totalPages).clamp(0.0, 1.0);
  }

  OcrProgress copyWith({
    OcrPhase? phase,
    int? currentPage,
    int? totalPages,
    int? completed,
    int? failed,
    String? message,
  }) =>
      OcrProgress(
        phase: phase ?? this.phase,
        currentPage: currentPage ?? this.currentPage,
        totalPages: totalPages ?? this.totalPages,
        completed: completed ?? this.completed,
        failed: failed ?? this.failed,
        message: message ?? this.message,
      );

  @override
  String toString() => 'OcrProgress(${phase.name}, '
      'page=$currentPage/$totalPages, ok=$completed, failed=$failed)';
}

/// High-level pipeline phase, used by the UI to label progress.
enum OcrPhase { preparing, detecting, recognizing, finalizing, done, failed }

/// Cooperative cancellation for an OCR job.
///
/// The listener is how the client kills the child process: cancelling is not
/// just "ignore the result", it terminates the work.
class OcrCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        // A failing cleanup listener must not break cancellation itself.
      }
    }
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

/// Provenance of one recognised page: what was read, how, and from where.
class OcrSourceRef {
  const OcrSourceRef({
    required this.documentSha256,
    required this.page,
    required this.width,
    required this.height,
    required this.dpi,
    required this.engine,
    required this.engineVersion,
    required this.language,
    required this.method,
    this.bbox,
  });

  final String documentSha256;
  final int page;

  /// Rendered page image size; [bbox] coordinates are in this pixel space.
  final int width;
  final int height;
  final int dpi;

  final String engine;
  final String engineVersion;
  final String language;
  final OcrMethod method;

  /// Optional region inside the rendered page (e.g. a flagged line).
  final OcrRect? bbox;

  String get locationLabel => '第 $page 页';

  /// Compact description for the material viewer: page + method + geometry.
  String get describe {
    final box = bbox == null ? '' : '，区域 ${bbox!}';
    final source = method == OcrMethod.text ? '原文文字层' : '本地 OCR';
    return '第 $page 页（$source，${width}x$height @ $dpi DPI$box）';
  }

  /// True when the full rendered size/DPI fingerprint is identical.
  bool geometryMatches(OcrPageResult other) =>
      other.page == page &&
      other.width == width &&
      other.height == height &&
      other.dpi == dpi;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'documentSha256': documentSha256,
        'page': page,
        'width': width,
        'height': height,
        'dpi': dpi,
        'engine': engine,
        'engineVersion': engineVersion,
        'language': language,
        'method': method.value,
        if (bbox != null) 'bbox': bbox!.toMap(),
      };

  static OcrSourceRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final sha = (m['documentSha256'] as String?) ?? '';
    final page = (m['page'] as num?)?.toInt();
    final width = (m['width'] as num?)?.toInt();
    final height = (m['height'] as num?)?.toInt();
    if (sha.isEmpty || page == null || page < 1) return null;
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    return OcrSourceRef(
      documentSha256: sha,
      page: page,
      width: width,
      height: height,
      dpi: (m['dpi'] as num?)?.toInt() ?? 0,
      engine: (m['engine'] as String?) ?? '',
      engineVersion: (m['engineVersion'] as String?) ?? '',
      language: (m['language'] as String?) ?? '',
      method: OcrMethodInfo.fromValue((m['method'] as String?) ?? 'ocr'),
      bbox: OcrRect.fromMap(m['bbox']),
    );
  }
}

/// One OCR language known to the local engine.
class OcrLanguage {
  const OcrLanguage({
    required this.tag,
    required this.displayName,
    this.nativeName = '',
    this.recognizer = true,
  });

  final String tag;
  final String displayName;
  final String nativeName;

  /// True when this language has an installed OCR recogniser (not just a
  /// display language).
  final bool recognizer;

  static OcrLanguage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final tag = (m['tag'] as String?)?.trim() ?? '';
    if (tag.isEmpty) return null;
    return OcrLanguage(
      tag: tag,
      displayName: (m['displayName'] as String?) ?? tag,
      nativeName: (m['nativeName'] as String?) ?? '',
      recognizer: m['recognizer'] != false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tag': tag,
        'displayName': displayName,
        'nativeName': nativeName,
        'recognizer': recognizer,
      };
}

/// Availability of the local OCR backend (host executable + language packs).
class OcrAvailability {
  const OcrAvailability({
    required this.available,
    this.hostPath,
    this.hostVersion = '',
    this.engine = '',
    this.engineVersion = '',
    this.languages = const <OcrLanguage>[],
    this.problem,
    this.checkedAt,
  });

  /// A usable host *and* at least one OCR language are required.
  final bool available;

  final String? hostPath;
  final String hostVersion;
  final String engine;
  final String engineVersion;
  final List<OcrLanguage> languages;

  /// Why OCR is unavailable (user-facing Chinese), or `null` when available.
  final String? problem;

  final DateTime? checkedAt;

  bool get hasLanguages => languages.isNotEmpty;

  bool supportsLanguage(String tag) {
    final wanted = tag.trim().toLowerCase();
    if (wanted.isEmpty) return false;
    for (final language in languages) {
      final availableTag = language.tag.toLowerCase();
      if (availableTag == wanted) return true;
      if (wanted.startsWith('zh') && availableTag.startsWith('zh')) return true;
      if (wanted.startsWith('en') && availableTag.startsWith('en')) return true;
      if (availableTag.startsWith('$wanted-') || wanted.startsWith('$availableTag-')) {
        return true;
      }
    }
    return false;
  }

  /// Language tags to pass to the host: all available recognisers, requested
  /// language first when it exists.
  List<String> preferredTags([String? preferred]) {
    final tags = <String>[
      for (final language in languages)
        if (language.recognizer) language.tag,
    ];
    final wanted = preferred?.trim() ?? '';
    if (wanted.isEmpty) return tags;
    final index = tags.indexWhere((tag) => tag.toLowerCase() == wanted.toLowerCase());
    if (index > 0) {
      final first = tags.removeAt(index);
      tags.insert(0, first);
    }
    return tags;
  }

  static OcrAvailability unavailable(String problem, {String? hostPath}) =>
      OcrAvailability(available: false, hostPath: hostPath, problem: problem);
}

/// Build metadata written next to the host executable by
/// `scripts/build_ocr_host.ps1` (`build-info.json`). Used to fingerprint the
/// cache and to prove which binary was shipped.
class OcrHostBuildInfo {
  const OcrHostBuildInfo({
    required this.hostVersion,
    required this.engine,
    required this.engineVersion,
    this.sha256,
    this.builtAtUtc,
    this.compilerKind,
    this.windowsSdk,
    this.raw = const <String, dynamic>{},
  });

  final String hostVersion;
  final String engine;
  final String engineVersion;
  final String? sha256;
  final String? builtAtUtc;
  final String? compilerKind;
  final String? windowsSdk;
  final Map<String, dynamic> raw;

  static OcrHostBuildInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final output = m['output'];
    final compiler = m['compiler'];
    final sdk = m['windowsSdk'];
    return OcrHostBuildInfo(
      hostVersion: (m['hostVersion'] as String?) ?? '',
      engine: (m['engine'] as String?) ?? '',
      engineVersion: (m['engineVersion'] as String?) ?? '',
      sha256: output is Map ? (output['sha256'] as String?) : null,
      builtAtUtc: (m['builtAtUtc'] as String?)?.trim(),
      compilerKind: compiler is Map ? (compiler['kind'] as String?) : null,
      windowsSdk: sdk is Map ? (sdk['unionMetadata'] as String?) : null,
      raw: m,
    );
  }
}

/// A decoded `ready` handshake from the host; the client validates the protocol.
///
/// Kept out of `ocr_client.dart` so availability/service code can use it
/// without importing the process layer.
class OcrHostHello {
  const OcrHostHello({
    required this.hostVersion,
    required this.engine,
    required this.engineVersion,
    required this.osVersion,
    this.mode = '',
    this.source,
    this.pages = 0,
    this.languages = const <OcrLanguage>[],
  });

  final String hostVersion;
  final String engine;
  final String engineVersion;
  final String osVersion;
  final String mode;
  final String? source;
  final int pages;
  final List<OcrLanguage> languages;

  static OcrHostHello? fromJson(Map<String, dynamic> m) {
    final engine = (m['engine'] as String?)?.trim() ?? '';
    if (engine.isEmpty) return null;
    final languages = <OcrLanguage>[];
    final rawLanguages = m['languages'];
    if (rawLanguages is List) {
      for (final item in rawLanguages) {
        final language = OcrLanguage.fromJson(item);
        if (language != null) languages.add(language);
      }
    }
    return OcrHostHello(
      hostVersion: (m['hostVersion'] as String?) ?? '',
      engine: engine,
      engineVersion: (m['engineVersion'] as String?) ?? '',
      osVersion: (m['osVersion'] as String?) ?? '',
      mode: (m['mode'] as String?) ?? '',
      source: m['source'] as String?,
      pages: (m['pages'] as num?)?.toInt() ?? 0,
      languages: languages,
    );
  }
}

/// Document metadata used for page planning (from `--info`).
class OcrDocumentInfo {
  const OcrDocumentInfo({
    required this.kind,
    required this.pageCount,
    this.encrypted = false,
    this.pageWidthsDip = const <int, double>{},
    this.pageHeightsDip = const <int, double>{},
  });

  final String kind;
  final int pageCount;
  final bool encrypted;
  final Map<int, double> pageWidthsDip;
  final Map<int, double> pageHeightsDip;

  List<int> get allPages => <int>[for (var i = 1; i <= pageCount; i++) i];
}

/// Limits for one OCR job. Kept in one place so the UI, service and host agree.
class OcrLimits {
  const OcrLimits({
    this.defaultDpi = 150,
    this.minDpi = 72,
    this.maxDpi = 300,
    this.maxPagesPerJob = 300,
    this.maxPixelsPerPage = 40000000,
    this.maxDimension = 10000,
    this.maxFileBytes = 256 * 1024 * 1024,
    this.probeTimeout = const Duration(seconds: 20),
    this.startupTimeout = const Duration(seconds: 30),
    this.pageTimeout = const Duration(minutes: 2),
    this.jobTimeout = const Duration(minutes: 45),
    this.cancelGrace = const Duration(seconds: 3),
  });

  static const OcrLimits standard = OcrLimits();

  final int defaultDpi;
  final int minDpi;
  final int maxDpi;
  final int maxPagesPerJob;
  final int maxPixelsPerPage;
  final int maxDimension;
  final int maxFileBytes;
  final Duration probeTimeout;
  final Duration startupTimeout;

  /// Maximum silence between two host events; a hung render/OCR is killed.
  final Duration pageTimeout;

  /// Hard budget for the whole job.
  final Duration jobTimeout;

  /// How long to wait for the child to exit after kill before giving up.
  final Duration cancelGrace;

  int clampDpi(int dpi) {
    if (dpi < minDpi) return minDpi;
    if (dpi > maxDpi) return maxDpi;
    return dpi;
  }

  bool isValidDpi(int dpi) => dpi >= minDpi && dpi <= maxDpi;

  /// Pages that can actually be requested for [info] under this limit.
  List<int> clampPages(Iterable<int> requested, OcrDocumentInfo info) {
    final wanted = <int>{};
    for (final page in requested) {
      if (page >= 1 && page <= info.pageCount) wanted.add(page);
    }
    final sorted = wanted.toList(growable: false)..sort();
    if (sorted.length > maxPagesPerJob) {
      return sorted.sublist(0, maxPagesPerJob);
    }
    return sorted;
  }

  String describe() => 'DPI $minDpi-$maxDpi（默认 $defaultDpi），单次最多 $maxPagesPerJob 页，'
      '每页最多 ${maxPixelsPerPage ~/ 1000000} MP / 最长边 $maxDimension 像素';
}

/// Parses `"1-3,5"` into ascending 1-based pages. Throws [FormatException] for
/// malformed ranges; out-of-document pages are handled by the caller.
List<int> parseOcrPageSpec(String raw) {
  final result = <int>{};
  for (final part in raw.split(',')) {
    final token = part.trim();
    if (token.isEmpty) continue;
    final dash = token.indexOf('-');
    if (dash < 0) {
      final page = int.tryParse(token);
      if (page == null || page < 1) {
        throw FormatException('页码必须是正整数：$token');
      }
      result.add(page);
      continue;
    }
    final fromRaw = token.substring(0, dash).trim();
    final toRaw = token.substring(dash + 1).trim();
    final from = fromRaw.isEmpty ? 1 : int.tryParse(fromRaw);
    final to = toRaw.isEmpty ? null : int.tryParse(toRaw);
    if (from == null || from < 1 || (to != null && to < from)) {
      throw FormatException('页码范围无效：$token');
    }
    if (to == null) {
      throw FormatException('页码范围需要上限（如 5-10）：$token');
    }
    if (to - from > 10000) {
      throw FormatException('页码范围过大：$token');
    }
    for (var page = from; page <= to; page++) {
      result.add(page);
    }
  }
  final sorted = result.toList(growable: false)..sort();
  return sorted;
}

/// Format [pages] back into a compact spec string ("1-3,5").
String formatOcrPageSpec(Iterable<int> pages) {
  final sorted = pages.toList(growable: false)..sort();
  if (sorted.isEmpty) return '';
  final parts = <String>[];
  var start = sorted.first;
  var previous = sorted.first;
  for (var i = 1; i < sorted.length; i++) {
    final page = sorted[i];
    if (page == previous + 1) {
      previous = page;
      continue;
    }
    parts.add(start == previous ? '$start' : '$start-$previous');
    start = page;
    previous = page;
  }
  parts.add(start == previous ? '$start' : '$start-$previous');
  return parts.join(',');
}

/// UTF-8 byte length helper used to compare OCR text against request budgets.
int ocrUtf8Length(String text) => utf8.encode(text).length;
