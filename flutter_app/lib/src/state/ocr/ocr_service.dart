// Orchestration for local OCR: discovery → availability → page detection →
// bounded recognition → cache → partial-failure report.
//
// Responsibilities kept out of the UI and out of AppController:
//   * one job at a time (concurrency 1 — the helper is a single child process),
//   * page range / DPI / pixel / page-count limits are validated here and again
//     inside the host (defence in depth),
//   * cached pages are reused only when document hash + engine identity +
//     languages + DPI + page all match; otherwise the page is re-recognised,
//   * a partial job is returned as a partial [OcrJobResult] (failed/missing pages
//     listed explicitly) and is never marked complete,
//   * the source file is never modified; only read (read-only file handle used by
//     the host) and hashed for the cache key,
//   * entirely offline: no network import exists in this layer.
//
// The UI/controller is responsible for turning the confirmed material into an
// attachment and for telling the user that *analysis* of that text may use the
// configured model connection (that step is not local).

import 'dart:async';
import 'dart:io';

import 'ocr_cache.dart';
import 'ocr_client.dart';
import 'ocr_host.dart';
import 'ocr_page_detection.dart';
import 'ocr_types.dart';

/// Creates the host client; injectable so tests can avoid spawning processes.
typedef OcrClientFactory = OcrHostClient Function(OcrHostLocation location);

/// Coordinates local OCR work. Stateless per call except for the backend cache.
class OcrService {
  OcrService({
    this.dataRoot,
    this.limits = OcrLimits.standard,
    this.preferredLanguage,
    OcrHostDiscovery? discovery,
    OcrClientFactory? clientFactory,
    this.enableCache = true,
    OcrPdfPageTextReader? pdfTextReader,
    Future<int?> Function(String filePath)? pageCountReader,
  })  : _discovery = discovery,
        _clientFactory = clientFactory,
        _pdfTextReader = pdfTextReader,
        _pageCountReader = pageCountReader;

  /// Data root used for `<root>/ocr_cache/`. `null` = memory-only session: OCR
  /// still works, caching is skipped.
  final Directory? dataRoot;

  final OcrLimits limits;

  /// Preferred OCR language tag (e.g. "zh-Hans-CN"); `null` = automatic order.
  final String? preferredLanguage;

  final bool enableCache;

  OcrHostDiscovery? _discovery;
  OcrHostClient? _client;
  OcrHostBuildInfo? _buildInfo;
  OcrAvailability? _availability;
  OcrCache? _cache;
  final OcrClientFactory? _clientFactory;
  final OcrPdfPageTextReader? _pdfTextReader;
  final Future<int?> Function(String filePath)? _pageCountReader;

  /// Lazily created so the first chained future is created in the caller's
  /// zone. An eagerly-created Future would schedule its microtask in the
  /// constructor's zone, which delays the first job (and breaks FakeAsync widget
  /// tests entirely).
  Future<void>? _queue;

  final Map<String, OcrDocumentInfo> _infoCache = <String, OcrDocumentInfo>{};

  /// Last discovery result (also available when OCR is unavailable).
  OcrHostDiscovery? get discovery => _discovery;

  OcrHostLocation? get hostLocation => _discovery?.location;

  OcrHostBuildInfo? get buildInfo => _buildInfo;

  OcrHostClient? get client => _client;

  // ---------------------------------------------------------------- backend

  /// Checks the local backend (host executable + installed OCR languages).
  ///
  /// Never throws for a missing/broken host: the returned [OcrAvailability] has
  /// [OcrAvailability.available] false and a Chinese explanation.
  Future<OcrAvailability> availability({bool refresh = false}) async {
    if (!refresh) {
      final cached = _availability;
      if (cached != null) return cached;
    }
    final discovery = _discovery ?? await discoverOcrHost();
    _discovery = discovery;
    final location = discovery.location;
    if (location == null) {
      final unavailable = OcrAvailability.unavailable(
        discovery.diagnostic,
        hostPath: null,
      );
      _availability = unavailable;
      return unavailable;
    }
    _buildInfo = await readOcrHostBuildInfo(location.path);
    final client = _client ??= _clientFactory?.call(location) ??
        OcrHostClient(host: location, limits: limits);
    final probed = await client.probe();
    final withPath = OcrAvailability(
      available: probed.available,
      hostPath: location.path,
      hostVersion: probed.hostVersion.isNotEmpty
          ? probed.hostVersion
          : (_buildInfo?.hostVersion ?? ''),
      engine: probed.engine.isNotEmpty
          ? probed.engine
          : (_buildInfo?.engine ?? 'Windows.Media.Ocr'),
      engineVersion: probed.engineVersion.isNotEmpty
          ? probed.engineVersion
          : (_buildInfo?.engineVersion ?? 'unknown'),
      languages: probed.languages,
      problem: probed.problem,
      checkedAt: probed.checkedAt ?? DateTime.now(),
    );
    _availability = withPath;
    if (withPath.available) {
      _cache ??= _cacheFor(withPath);
    }
    return withPath;
  }

  OcrCache? _cacheFor(OcrAvailability availability) {
    final root = dataRoot;
    if (!enableCache || root == null) return null;
    final identity = ocrEngineIdentity(
      availability: availability,
      buildInfo: _buildInfo,
    );
    return OcrCache(root: root, engineIdentity: identity);
  }

  /// Resolves a usable backend or throws a client exception with a precise
  /// reason (never a generic "OCR unavailable").
  Future<({OcrHostClient client, OcrAvailability availability})> _requireBackend() async {
    final available = await availability();
    if (!available.available) {
      throw OcrClientException(OcrError(
        code: available.problem != null && available.problem!.contains('语言')
            ? OcrErrorCode.noLanguage
            : OcrErrorCode.hostMissing,
        message: available.problem ?? OcrErrorCode.hostMissing.defaultMessage,
        detail: available.hostPath,
      ));
    }
    final client = _client;
    if (client == null) {
      throw OcrClientException(OcrError(
        code: OcrErrorCode.hostMissing,
        message: OcrErrorCode.hostMissing.defaultMessage,
        detail: available.hostPath,
      ));
    }
    return (client: client, availability: available);
  }

  // -------------------------------------------------------------- detection

  /// Auto-detects which pages need OCR. Uses the existing PDF text extractor;
  /// the host is consulted only for the page count when a PDF has no text layer.
  Future<OcrPageDetection> detectPages(
    String filePath, {
    String? password,
    List<int> forcedPages = const <int>[],
    List<int> excludedPages = const <int>[],
    OcrSourceKind? kind,
    int minTextChars = 24,
  }) async {
    OcrHostClient? client;
    try {
      client = await availability().then((available) => available.available ? _client : null);
    } catch (_) {
      client = null;
    }
    return detectOcrPages(
      filePath,
      kind: kind,
      password: password,
      pdfTextReader: _pdfTextReader,
      pageCountReader: _pageCountReader,
      hostClient: client,
      maxBytes: limits.maxFileBytes,
      minTextChars: minTextChars,
      forcedPages: forcedPages,
      excludedPages: excludedPages,
    );
  }

  /// Reads document metadata (page count / dimensions) for the dialog.
  Future<OcrDocumentInfo> documentInfo(String filePath, {String? password}) async {
    final kind = OcrSourceKind.fromPath(filePath);
    final backend = await _requireBackend();
    final key = _infoCacheKey(filePath, password != null);
    final cached = _infoCache[key];
    if (cached != null) return cached;
    final info = kind == OcrSourceKind.image
        ? await backend.client.imageInfo(filePath)
        : await backend.client.documentInfo(filePath, password: password);
    if (_infoCache.length >= 8) _infoCache.clear();
    _infoCache[key] = info;
    return info;
  }

  String _infoCacheKey(String filePath, bool hasPassword) {
    try {
      final stat = File(filePath).statSync();
      return '$filePath|${stat.size}|${stat.modified.millisecondsSinceEpoch}|$hasPassword';
    } catch (_) {
      return '$filePath|missing|$hasPassword';
    }
  }

  // ------------------------------------------------------------- recognition

  /// Recognises [pages] of [filePath] locally.
  ///
  /// [pages] are 1-based; empty means "all pages" for PDFs and page 1 for
  /// images. Pages that fail are reported in [OcrJobResult.failures]; a partial
  /// job is never reported as complete.
  Future<OcrJobResult> recognize({
    required String filePath,
    List<int> pages = const <int>[],
    String? password,
    int? dpi,
    List<String>? languages,
    OcrCancellation? cancellation,
    void Function(OcrProgress)? onProgress,
    bool useCache = true,
  }) {
    return _serialized(() => _recognize(
          filePath: filePath,
          pages: pages,
          password: password,
          dpi: dpi,
          languages: languages,
          cancellation: cancellation,
          onProgress: onProgress,
          useCache: useCache,
        ));
  }

  Future<OcrJobResult> _recognize({
    required String filePath,
    required List<int> pages,
    required String? password,
    required int? dpi,
    required List<String>? languages,
    required OcrCancellation? cancellation,
    required void Function(OcrProgress)? onProgress,
    required bool useCache,
  }) async {
    final stopwatch = Stopwatch()..start();
    final kind = OcrSourceKind.fromPath(filePath);
    final backend = await _requireBackend();
    final available = backend.availability;
    final cleanPages = <int>{for (final page in pages) if (page >= 1) page}.toList()..sort();

    final warnings = <String>[];
    final requestedDpi = dpi ?? limits.defaultDpi;
    final effectiveDpi = limits.clampDpi(requestedDpi);
    if (effectiveDpi != requestedDpi) {
      warnings.add('DPI 已调整为 $effectiveDpi（允许范围 ${limits.minDpi}-${limits.maxDpi}）。');
    }
    final requestedLanguages = _languageTags(available, languages);

    final file = File(filePath);
    if (!file.existsSync()) {
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        error: OcrError(
          code: OcrErrorCode.renderFailed,
          message: '文件不存在或无法访问：$filePath',
        ),
      );
    }
    if (kind == OcrSourceKind.unsupported) {
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        error: const OcrError(
          code: OcrErrorCode.unsupportedFormat,
          message: '不支持的文件类型。本地 OCR 支持 PDF、PNG、JPEG 图片。',
        ),
      );
    }
    final fileLength = file.lengthSync();
    if (fileLength > limits.maxFileBytes) {
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        error: OcrError(
          code: OcrErrorCode.tooLarge,
          message: '文件 ${(fileLength / (1024 * 1024)).toStringAsFixed(1)} MB，'
              '超过本地 OCR 文件上限 ${(limits.maxFileBytes / (1024 * 1024)).toStringAsFixed(0)} MB。',
        ),
      );
    }

    // Page count: needed for range validation and for "all pages" requests.
    OcrDocumentInfo? info;
    try {
      if (kind == OcrSourceKind.pdf) {
        info = await documentInfo(filePath, password: password);
      } else {
        info = const OcrDocumentInfo(kind: 'image', pageCount: 1);
      }
    } on OcrClientException catch (error) {
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        error: error.error,
      );
    }

    final totalPages = kind == OcrSourceKind.image ? 1 : info.pageCount;
    var requested = cleanPages.isEmpty
        ? <int>[for (var page = 1; page <= totalPages; page++) page]
        : cleanPages;
    if (requested.isEmpty) {
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        error: const OcrError(
          code: OcrErrorCode.pageOutOfRange,
          message: '文档没有可识别的页面。',
        ),
      );
    }
    if (requested.length > limits.maxPagesPerJob) {
      warnings.add('请求 ${requested.length} 页，超过单次上限 ${limits.maxPagesPerJob} 页。');
      return _fatalJobResult(
        filePath: filePath,
        kind: kind,
        dpi: effectiveDpi,
        languages: requestedLanguages,
        totalPages: totalPages,
        requestedPages: requested,
        error: OcrError(
          code: OcrErrorCode.tooLarge,
          message: '请求 ${requested.length} 页，超过单次上限 ${limits.maxPagesPerJob} 页。'
              '请分批识别。',
        ),
        warning: warnings.isEmpty ? null : warnings.join('；'),
      );
    }

    final failures = <OcrPageFailure>[];
    final valid = <int>[];
    for (final page in requested) {
      if (totalPages > 0 && (page < 1 || page > totalPages)) {
        failures.add(OcrPageFailure(
          page: page,
          code: OcrErrorCode.pageOutOfRange,
          message: '第 $page 页超出文档范围（共 $totalPages 页）。',
        ));
      } else {
        valid.add(page);
      }
    }
    requested = List<int>.unmodifiable(requested);

    // Content hash -> cache lookup.
    String? documentSha;
    final cachedResults = <int, OcrPageResult>{};
    final cache = _cache;
    if (useCache && enableCache && cache != null && valid.isNotEmpty) {
      try {
        documentSha = await OcrCache.sha256OfFile(file);
      } catch (error) {
        // A hash failure only disables caching; it must not fail the job.
        warnings.add('无法计算文件内容哈希，本次不使用缓存。');
        documentSha = null;
      }
    }
    if (documentSha != null && cache != null) {
      final cachedKeys = <int>[];
      for (final page in valid) {
        final key = cache.keyFor(
          documentSha: documentSha,
          page: page,
          dpi: effectiveDpi,
          languages: requestedLanguages,
        );
        final hit = await cache.load(key);
        if (hit != null) {
          cachedResults[page] = hit;
          cachedKeys.add(page);
        }
      }
      if (cachedResults.isNotEmpty) {
        _emit(onProgress, OcrProgress(
          phase: OcrPhase.preparing,
          totalPages: requested.length,
          completed: cachedResults.length,
          message: '有 ${cachedResults.length} 页命中本地缓存',
        ));
      }
    }

    final pendingPages = <int>[
      for (final page in valid)
        if (!cachedResults.containsKey(page)) page,
    ];

    OcrJobResult? hostJob;
    if (pendingPages.isNotEmpty) {
      hostJob = await backend.client.run(
        OcrJobRequest(
          filePath: filePath,
          kind: kind,
          pages: pendingPages,
          languages: requestedLanguages,
          dpi: effectiveDpi,
          password: password,
          maxPixels: limits.maxPixelsPerPage,
          maxDimension: limits.maxDimension,
          maxPages: limits.maxPagesPerJob,
        ),
        onProgress: onProgress,
        cancellation: cancellation,
      );
      failures.addAll(hostJob.failures.where((failure) => pendingPages.contains(failure.page)));
    }

    final results = <OcrPageResult>[
      ...cachedResults.values,
      if (hostJob != null) ...hostJob.results,
    ]..sort((a, b) => a.page.compareTo(b.page));
    failures.sort((a, b) => a.page.compareTo(b.page));

    // Cache only results that were freshly recognised and only when the file did
    // not change under us (otherwise the key would be stale).
    final fresh = hostJob?.results ?? const <OcrPageResult>[];
    if (cache != null && documentSha != null && fresh.isNotEmpty && !(hostJob?.cancelled ?? false)) {
      String? afterSha;
      try {
        afterSha = await OcrCache.sha256OfFile(file);
      } catch (_) {
        afterSha = null;
      }
      if (afterSha == documentSha) {
        for (final result in fresh) {
          await cache.store(
            cache.keyFor(
              documentSha: documentSha,
              page: result.page,
              dpi: effectiveDpi,
              languages: requestedLanguages,
            ),
            result,
          );
        }
      } else {
        warnings.add('文件内容在识别期间发生变化，本次结果未写入缓存，建议重新识别。');
      }
    } else if (documentSha != null && fresh.isEmpty && hostJob != null && hostJob.cancelled) {
      warnings.add('识别已取消，未写入缓存。');
    }

    final cancelled = hostJob?.cancelled ?? false;
    final jobError = hostJob?.jobError;
    if (jobError == null && failures.isNotEmpty && results.isEmpty) {
      // Every page failed for its own reason: still a job-level failure summary
      // for the UI, but keep the per-page failures as the source of truth.
      warnings.add('所有请求的页都未能识别，请查看失败页原因。');
    }
    if (jobError != null && results.isEmpty) {
      warnings.add('本地 OCR 无法完成：${jobError.message}');
    }

    return OcrJobResult(
      sourcePath: filePath,
      sourceKind: kind.wire,
      totalPages: totalPages,
      requestedPages: requested,
      results: List<OcrPageResult>.unmodifiable(results),
      failures: List<OcrPageFailure>.unmodifiable(failures),
      cancelled: cancelled,
      elapsed: stopwatch.elapsed,
      engine: available.engine,
      engineVersion: available.engineVersion,
      languages: List<String>.unmodifiable(requestedLanguages),
      dpi: effectiveDpi,
      sourceSha256: documentSha,
      cachedPages: List<int>.unmodifiable(cachedResults.keys.toList()..sort()),
      hostVersion: available.hostVersion,
      jobError: jobError,
      warning: warnings.isEmpty ? null : warnings.join('；'),
    );
  }

  OcrJobResult _fatalJobResult({
    required String filePath,
    required OcrSourceKind kind,
    required int dpi,
    required List<String> languages,
    required OcrError error,
    int totalPages = 0,
    List<int> requestedPages = const <int>[],
    String? warning,
  }) =>
      OcrJobResult(
        sourcePath: filePath,
        sourceKind: kind.wire,
        totalPages: totalPages,
        requestedPages: requestedPages,
        results: const <OcrPageResult>[],
        failures: const <OcrPageFailure>[],
        elapsed: Duration.zero,
        engine: _availability?.engine ?? '',
        engineVersion: _availability?.engineVersion ?? '',
        languages: List<String>.unmodifiable(languages),
        dpi: dpi,
        hostVersion: _availability?.hostVersion ?? '',
        jobError: error,
        warning: warning,
      );

  /// Language tags sent to the host (and used in cache keys).
  List<String> _languageTags(OcrAvailability availability, List<String>? requested) {
    final explicitlyRequested = <String>[
      for (final tag in requested ?? const <String>[])
        if (tag.trim().isNotEmpty && availability.supportsLanguage(tag)) tag.trim(),
    ];
    if (explicitlyRequested.isNotEmpty) {
      return List<String>.unmodifiable(explicitlyRequested.toSet());
    }
    final preferred = preferredLanguage?.trim();
    if (preferred != null && preferred.isNotEmpty && availability.supportsLanguage(preferred)) {
      final tags = availability.preferredTags(preferred);
      if (tags.isNotEmpty) return List<String>.unmodifiable(tags);
    }
    final automatic = availability.preferredTags();
    if (automatic.isNotEmpty) return List<String>.unmodifiable(automatic);
    return const <String>[];
  }

  void _emit(void Function(OcrProgress)? callback, OcrProgress progress) {
    if (callback == null) return;
    try {
      callback(progress);
    } catch (_) {
      // Progress reporting must never break the job.
    }
  }

  // ------------------------------------------------------------------- cache

  /// Removes all cached OCR results. Never touches source files or material.
  Future<int> clearCache() async {
    final cache = _cache;
    if (cache == null) return 0;
    return cache.clearAll();
  }

  /// Current cache size in bytes (0 when caching is disabled/unavailable).
  Future<int> cacheSizeBytes() async {
    final cache = _cache;
    if (cache == null) return 0;
    return cache.sizeBytes();
  }

  // ------------------------------------------------------------- serialisation

  /// Serialises recognition jobs: concurrency is deliberately 1 so a machine
  /// never runs several OCR render/recognise pipelines at once.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queue ?? Future<void>.value();
    _queue = previous.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}
