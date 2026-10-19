// NativeGateway — the Dart-side façade over ts_bridge.dll.
//
// Responsibilities:
//   * open/close the DLL and own the native handle lifetime;
//   * translate JSON strings <-> typed maps;
//   * expose a *poll-based* async analysis (no native -> Dart callbacks);
//   * expose the settings/credential/probe surface added by ABI 2;
//   * guarantee that buffers are released and jobs are released even on error.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import '../model/settings.dart';
import 'bridge_ffi.dart';

/// Runtime information reported by the native layer. Never contains secrets.
class BridgeInfo {
  final String model;
  final String endpoint;
  final String configPath;
  final bool mockMode;
  final bool hasApiKey;
  final bool requiresAuth;
  final bool httpAvailable;
  final int waitPromptMs;
  final int maxInputBytes;

  const BridgeInfo({
    required this.model,
    required this.endpoint,
    required this.configPath,
    required this.mockMode,
    required this.hasApiKey,
    required this.requiresAuth,
    required this.httpAvailable,
    required this.waitPromptMs,
    required this.maxInputBytes,
  });

  factory BridgeInfo.fromJson(Map<String, dynamic> j) => BridgeInfo(
        model: (j['model'] as String?) ?? '',
        endpoint: (j['endpoint'] as String?) ?? '',
        configPath: (j['configPath'] as String?) ?? '',
        mockMode: j['mockMode'] == true,
        hasApiKey: j['hasApiKey'] == true,
        requiresAuth: j['requiresAuth'] == true,
        httpAvailable: j['httpAvailable'] == true,
        waitPromptMs: (j['waitPromptMs'] as num?)?.toInt() ?? 120000,
        maxInputBytes: (j['maxInputBytes'] as num?)?.toInt() ?? 262144,
      );

  /// Short human sentence for the status bar. Deliberately says nothing about
  /// the key value, only whether one is available.
  String get statusLine {
    if (mockMode) return '离线模拟模式（不联网）';
    final parts = <String>['模型 $model'];
    if (!httpAvailable) {
      parts.add('本构建未启用网络');
    } else if (requiresAuth && !hasApiKey) {
      parts.add('缺少密钥');
    }
    return parts.join(' · ');
  }
}

/// One analysis event delivered by the native job queue.
class BridgeEvent {
  final String type;
  final String stage;
  final String detail;
  final String error;
  final int elapsedMs;

  /// Identity echo: lets the controller verify "this result belongs to the
  /// request I started", so a late response can never overwrite a newer plan.
  final String conversationId;
  final String requestId;
  final String? baseVersionId;
  final int baseRevision;

  const BridgeEvent({
    required this.type,
    required this.stage,
    required this.detail,
    required this.error,
    required this.elapsedMs,
    required this.conversationId,
    required this.requestId,
    required this.baseVersionId,
    required this.baseRevision,
  });

  bool get isTerminal =>
      type == 'succeeded' || type == 'failed' || type == 'cancelled';

  factory BridgeEvent.fromJson(Map<String, dynamic> j) => BridgeEvent(
        type: (j['type'] as String?) ?? 'progress',
        stage: (j['stage'] as String?) ?? '',
        detail: (j['detail'] as String?) ?? '',
        error: (j['error'] as String?) ?? '',
        elapsedMs: (j['elapsedMs'] as num?)?.toInt() ?? 0,
        conversationId: (j['conversationId'] as String?) ?? '',
        requestId: (j['requestId'] as String?) ?? '',
        baseVersionId: j['baseVersionId'] as String?,
        baseRevision: (j['baseRevision'] as num?)?.toInt() ?? 0,
      );
}

class BridgePollResult {
  final bool terminal;
  final List<BridgeEvent> events;
  const BridgePollResult(this.terminal, this.events);
}

/// Failure returned by the native layer (validation, export, transport, settings).
class NativeCallException implements Exception {
  final String kind;
  final String message;

  /// Raw native payload (e.g. the `current` document of a revision conflict), when
  /// the native call returned structured JSON. Never contains a secret.
  final Map<String, dynamic>? data;

  NativeCallException(this.kind, this.message, {this.data});

  @override
  String toString() => 'NativeCallException($kind): $message';
}

class AnalyzeOutcome {
  final bool ok;
  final String? errorKind;
  final String? error;
  final Map<String, dynamic>? plan;
  final Map<String, dynamic>? usage;
  final int elapsedMs;
  final int httpStatus;

  /// Which profile/model produced this result. `null` means "来源未知": failures and
  /// old native builds do not report it, and it is never guessed.
  final ModelSource? source;

  const AnalyzeOutcome({
    required this.ok,
    this.errorKind,
    this.error,
    this.plan,
    this.usage,
    required this.elapsedMs,
    required this.httpStatus,
    this.source,
  });
}

/// Result of a connectivity probe (`models` discovery or `chat` round-trip).
///
/// Deliberately a separate type from [AnalyzeOutcome]: a probe result must never be
/// committed as a plan, and mixing the two types is a programming error that this
/// class refuses to hide (see [NativeGateway.probeResult]).
class ProbeOutcome {
  /// 'models' or 'chat'; empty when the native layer did not report it.
  final String kind;
  final bool ok;
  final int httpStatus;
  final int elapsedMs;

  /// Discovered model ids (kind == 'models').
  final List<String> models;

  /// Model the chat probe actually used (kind == 'chat').
  final String? model;

  /// Whether the chat probe response parsed as JSON.
  final bool? contentIsJson;

  final Map<String, dynamic>? usage;
  final String? errorKind;
  final String? error;

  const ProbeOutcome({
    required this.ok,
    this.kind = '',
    this.httpStatus = 0,
    this.elapsedMs = 0,
    this.models = const <String>[],
    this.model,
    this.contentIsJson,
    this.usage,
    this.errorKind,
    this.error,
  });

  factory ProbeOutcome.fromJson(Map<String, dynamic> j) {
    final rawModel = (j['model'] as String?)?.trim() ?? '';
    return ProbeOutcome(
      ok: j['ok'] == true,
      kind: (j['kind'] as String?) ?? '',
      httpStatus: (j['httpStatus'] as num?)?.toInt() ?? 0,
      elapsedMs: (j['elapsedMs'] as num?)?.toInt() ?? 0,
      models: ((j['models'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .map((m) => m.trim())
          .where((m) => m.isNotEmpty)
          .toList(growable: false),
      model: rawModel.isEmpty ? null : rawModel,
      contentIsJson: j['contentIsJson'] as bool?,
      usage: j['usage'] is Map<String, dynamic>
          ? j['usage'] as Map<String, dynamic>
          : null,
      errorKind: j['errorKind'] as String?,
      error: j['error'] as String?,
    );
  }

  factory ProbeOutcome.failure(String kind, String errorKind, String error) =>
      ProbeOutcome(ok: false, kind: kind, errorKind: errorKind, error: error);

  /// True when the probe was cancelled before it could produce a usable answer.
  bool get isCancelled => errorKind == 'cancelled';
}

/// The slice of [NativeGateway] the settings layer needs.
///
/// Why an interface: [NativeGateway] can only be created by loading the real DLL, so
/// unit tests inject an in-memory implementation and stay offline/deterministic.
abstract class SettingsBridge {
  /// Reads the native settings document. Throws [NativeCallException] on failure.
  Map<String, dynamic> settingsGet();

  /// Writes the whole settings document and returns the stored document.
  Map<String, dynamic> settingsSave(Map<String, dynamic> settings);

  /// Writes an API key to the OS credential store. The key is never echoed back.
  void credentialSet(String profileId, String key);

  void credentialDelete(String profileId);

  /// Starts a probe job and returns its id.
  int probeAsync(Map<String, dynamic> request);

  /// Reads the terminal probe result; `null` while the job is still running.
  ProbeOutcome? probeResult(int job);

  BridgePollResult poll(int job);

  bool cancel(int job);

  void release(int job);
}

/// Result of one calendar-constraint extraction job (0.07).
///
/// Deliberately separate from [AnalyzeOutcome]: a constraints answer must never be
/// committed as a plan, and a plan must never be mistaken for constraints.
class ConstraintsOutcome {
  final bool ok;
  final String? errorKind;
  final String? error;

  /// Raw `constraints` object (`proposals` + `notes`). Not validated yet — that is the
  /// job of `decodeCalendarProposals`, so the gateway never claims an answer is usable.
  final Map<String, dynamic>? constraints;

  final int elapsedMs;
  final int httpStatus;

  /// Thinking configuration this request actually used, as reported by the native layer.
  final bool thinkingEnabled;
  final String? thinkingEffort;
  final String? protocol;

  const ConstraintsOutcome({
    required this.ok,
    this.errorKind,
    this.error,
    this.constraints,
    this.elapsedMs = 0,
    this.httpStatus = 0,
    this.thinkingEnabled = false,
    this.thinkingEffort,
    this.protocol,
  });

  factory ConstraintsOutcome.fromJson(Map<String, dynamic> j) {
    final thinking = j['thinking'] is Map<String, dynamic>
        ? j['thinking'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return ConstraintsOutcome(
      ok: j['ok'] == true,
      errorKind: j['errorKind'] as String?,
      error: j['error'] as String?,
      constraints: j['constraints'] is Map<String, dynamic>
          ? j['constraints'] as Map<String, dynamic>
          : null,
      elapsedMs: (j['elapsedMs'] as num?)?.toInt() ?? 0,
      httpStatus: (j['httpStatus'] as num?)?.toInt() ?? 0,
      thinkingEnabled: thinking['enabled'] == true,
      thinkingEffort: thinking['effort'] as String?,
      protocol: thinking['protocol'] as String?,
    );
  }
}

class NativeGateway implements SettingsBridge {
  final BridgeBindings _bindings;
  Pointer<Void> _handle;
  bool _disposed = false;
  BridgeInfo? _info;

  NativeGateway._(this._bindings, this._handle);

  /// Opens the DLL and creates a bridge instance.
  ///
  /// [dllDirectories] lets tests (and any non-standard packaging) point at the
  /// folder holding ts_bridge.dll. Windows also needs that folder to contain
  /// libcurl-x64.dll, because the bridge links it.
  ///
  /// [dataDir] is the writable user-data folder (sessions, `settings.json`). It is
  /// passed through `ts_bridge_create_ex` when this DLL exports it; older DLLs fall
  /// back to `ts_bridge_create`, whose ABI check then reports a clear mismatch.
  static NativeGateway open({
    required String configPath,
    String? dataDir,
    List<String>? dllDirectories,
  }) {
    final bindings = BridgeBindings.open(extraDirectories: dllDirectories);
    String? error;
    Pointer<Void> handle;
    final dir = (dataDir ?? '').trim();
    if (dir.isNotEmpty) {
      try {
        handle = bindings.createEx(configPath, dir, onError: (e) => error = e);
      } on BridgeUnavailableException {
        // DLL predates ABI 2: keep the old entry point so `info()` can report the
        // version mismatch precisely instead of failing to load at all.
        handle = bindings.create(configPath, onError: (e) => error = e);
      }
    } else {
      handle = bindings.create(configPath, onError: (e) => error = e);
    }
    if (handle == nullptr) {
      throw NativeCallException('create', error ?? '创建原生桥接失败');
    }
    return NativeGateway._(bindings, handle);
  }

  bool get isOpen => !_disposed && _handle != nullptr;

  /// True when the DLL exports the ABI 2 settings API.
  bool get supportsSettings => _bindings.supportsSettings;

  BridgeInfo info() {
    _ensureAlive();
    final res = _bindings.info(_handle);
    if (!res.ok) {
      throw NativeCallException('info', res.error ?? '读取运行期信息失败');
    }
    final json = jsonDecode(res.json!) as Map<String, dynamic>;
    final version = (json['abiVersion'] as num?)?.toInt() ?? 0;
    if (version != kExpectedAbiVersion) {
      throw NativeCallException(
        'abi',
        '分析内核版本不匹配：ts_bridge.dll 的 ABI 版本为 $version，'
            '界面需要 $kExpectedAbiVersion。请使用随程序一起提供的 ts_bridge.dll。',
      );
    }
    _info = BridgeInfo.fromJson(json);
    return _info!;
  }

  BridgeInfo get cachedInfo => _info ?? info();

  /// Starts an analysis. Returns the native job id. Never blocks on I/O.
  ///
  /// [modelSelection] is merged into the request as `modelSelection` so the native
  /// side can snapshot that exact profile revision before the worker starts.
  int analyzeAsync(Map<String, dynamic> request, {ModelSelection? modelSelection}) {
    _ensureAlive();
    final payload = modelSelection == null
        ? request
        : (Map<String, dynamic>.from(request)
          ..['modelSelection'] = modelSelection.toJson());
    final res = _bindings.analyze(_handle, jsonEncode(payload));
    if (!res.ok) {
      throw NativeCallException('analyze', _messageFrom(res.error),
          data: _tryDecode(res.error));
    }
    return int.parse(res.json!);
  }

  @override
  BridgePollResult poll(int job) {
    _ensureAlive();
    final res = _bindings.poll(_handle, job);
    if (!res.ok) {
      throw NativeCallException('poll', _messageFrom(res.error));
    }
    final json = jsonDecode(res.json!) as Map<String, dynamic>;
    final list = (json['events'] as List<dynamic>? ?? const [])
        .map((e) => BridgeEvent.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return BridgePollResult(json['terminal'] == true, list);
  }

  @override
  bool cancel(int job) {
    _ensureAlive();
    return _bindings.cancel(_handle, job);
  }

  /// Reads the terminal analysis result. Returns null while the job is still running.
  ///
  /// A probe result is rejected: it must never be committed as a plan.
  AnalyzeOutcome? result(int job) {
    _ensureAlive();
    final json = _resultJson(job);
    if (json == null) return null;
    final jobType = (json['jobType'] as String?)?.trim() ?? '';
    if (jobType == 'probe') {
      throw NativeCallException(
          'typeMismatch', '这是连通性探测结果，不能作为分析结果提交');
    }
    return AnalyzeOutcome(
      ok: json['ok'] == true,
      errorKind: json['errorKind'] as String?,
      error: json['error'] as String?,
      plan: json['plan'] is Map<String, dynamic>
          ? json['plan'] as Map<String, dynamic>
          : null,
      usage: json['usage'] is Map<String, dynamic>
          ? json['usage'] as Map<String, dynamic>
          : null,
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
      httpStatus: (json['httpStatus'] as num?)?.toInt() ?? 0,
      source: ModelSource.fromJson(json['source']),
    );
  }

  /// Reads the terminal probe result. Returns null while the job is still running.
  ///
  /// An analysis result is rejected with an explicit error instead of being coerced
  /// into a model list.
  @override
  ProbeOutcome? probeResult(int job) {
    _ensureAlive();
    final json = _resultJson(job);
    if (json == null) return null;
    final jobType = (json['jobType'] as String?)?.trim() ?? '';
    final kind = (json['kind'] as String?)?.trim() ?? '';
    final looksLikeAnalysis = json['plan'] is Map<String, dynamic>;
    if (jobType == 'analyze' || looksLikeAnalysis || (jobType != 'probe' && kind.isEmpty)) {
      throw NativeCallException(
        'typeMismatch',
        '原生返回的不是连通性探测结果（jobType=${jobType.isEmpty ? '未知' : jobType}），'
            '已拒绝作为探测结果使用',
      );
    }
    return ProbeOutcome.fromJson(json);
  }

  /// Starts a calendar-constraint extraction job. Never blocks on I/O.
  ///
  /// The request shape is the analysis request shape (`userRequest` + `sources`), so the
  /// model sees the *same* material the analysis sees — including the extracted text of
  /// every uploaded attachment, not just whatever is currently in the input box.
  int constraintsAsync(Map<String, dynamic> request,
      {ModelSelection? modelSelection}) {
    _ensureAlive();
    final payload = modelSelection == null
        ? request
        : (Map<String, dynamic>.from(request)
          ..['modelSelection'] = modelSelection.toJson());
    final res = _bindings.constraints(_handle, jsonEncode(payload));
    if (!res.ok) {
      throw NativeCallException('constraints', _messageFrom(res.error),
          data: _tryDecode(res.error));
    }
    return int.parse(res.json!);
  }

  /// Reads the terminal constraint result; null while the job is still running.
  ConstraintsOutcome? constraintsResult(int job) {
    _ensureAlive();
    final json = _resultJson(job);
    if (json == null) return null;
    final jobType = (json['jobType'] as String?)?.trim() ?? '';
    if (jobType != 'constraints') {
      throw NativeCallException(
        'typeMismatch',
        '原生返回的不是约束识别结果（jobType=${jobType.isEmpty ? '未知' : jobType}）',
      );
    }
    return ConstraintsOutcome.fromJson(json);
  }

  /// Starts a probe job (`kind` = `models` | `chat`). Never blocks on I/O.
  @override
  int probeAsync(Map<String, dynamic> request) {
    _ensureAlive();
    final res = _bindings.probe(_handle, jsonEncode(request));
    if (!res.ok) {
      throw NativeCallException('probe', _messageFrom(res.error),
          data: _tryDecode(res.error));
    }
    return int.parse(res.json!);
  }

  /// Reads the native settings document (profiles + defaults, never a key).
  ///
  /// Throws [NativeCallException] when the native layer reports `ok:false`.
  @override
  Map<String, dynamic> settingsGet() {
    _ensureAlive();
    final res = _bindings.settingsGet(_handle);
    if (!res.ok) {
      throw NativeCallException('settings', _messageFrom(res.error),
          data: _tryDecode(res.error));
    }
    final json = _decodeObject(res.json, '设置读取');
    _throwIfNotOk(json);
    return json;
  }

  /// Saves the whole settings document; the native side enforces revisions.
  @override
  Map<String, dynamic> settingsSave(Map<String, dynamic> settings) {
    _ensureAlive();
    final res = _bindings.settingsSave(_handle, jsonEncode(settings));
    if (!res.ok) {
      final data = _tryDecode(res.error);
      throw NativeCallException(
        (data?['errorKind'] as String?) ?? 'settingsSave',
        (data?['error'] as String?) ?? _messageFrom(res.error),
        data: data,
      );
    }
    final json = _decodeObject(res.json, '设置保存');
    _throwIfNotOk(json);
    return json;
  }

  @override
  void credentialSet(String profileId, String key) {
    _ensureAlive();
    final res = _bindings.credentialSet(_handle, profileId, key);
    if (!res.ok) {
      final data = _tryDecode(res.error);
      throw NativeCallException(
        (data?['errorKind'] as String?) ?? 'credential',
        (data?['error'] as String?) ?? _messageFrom(res.error),
        data: data,
      );
    }
    _throwIfNotOk(_decodeObject(res.json, '凭据保存'));
  }

  @override
  void credentialDelete(String profileId) {
    _ensureAlive();
    final res = _bindings.credentialDelete(_handle, profileId);
    if (!res.ok) {
      final data = _tryDecode(res.error);
      throw NativeCallException(
        (data?['errorKind'] as String?) ?? 'credential',
        (data?['error'] as String?) ?? _messageFrom(res.error),
        data: data,
      );
    }
    _throwIfNotOk(_decodeObject(res.json, '凭据删除'));
  }

  @override
  void release(int job) {
    if (_disposed) return;
    _bindings.release(_handle, job);
  }

  /// Validates + reschedules a local plan and returns the display snapshot.
  /// Throws [NativeCallException] (kind=validation) when the plan is invalid;
  /// callers must keep their previous plan untouched in that case.
  Map<String, dynamic> edit(Map<String, dynamic> localPlan) {
    _ensureAlive();
    final res = _bindings.edit(_handle, jsonEncode({'plan': localPlan}));
    if (!res.ok) {
      final map = _tryDecode(res.error);
      throw NativeCallException(
          (map?['errorKind'] as String?) ?? 'validation',
          (map?['error'] as String?) ?? '计划校验失败');
    }
    final json = jsonDecode(res.json!) as Map<String, dynamic>;
    return json['display'] as Map<String, dynamic>;
  }

  void export({
    required Map<String, dynamic> localPlan,
    required String path,
    required String format,
  }) {
    _ensureAlive();
    final res = _bindings.export(
        _handle, jsonEncode({'plan': localPlan, 'path': path, 'format': format}));
    if (!res.ok) {
      final map = _tryDecode(res.error);
      throw NativeCallException(
          (map?['errorKind'] as String?) ?? 'export',
          (map?['error'] as String?) ?? '导出失败');
    }
  }

  /// Graceful shutdown: cancel, poll readiness without blocking the UI,
  /// then destroy. Bounded by [timeout].
  Future<void> close({Duration timeout = const Duration(seconds: 12)}) async {
    if (_disposed) return;
    _disposed = true;
    try {
      _bindings.shutdownBegin(_handle);
      final deadline = DateTime.now().add(timeout);
      while (!_bindings.shutdownReady(_handle)) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      _bindings.destroy(_handle);
    } catch (_) {
      // Shutdown must never throw during app exit.
    } finally {
      _handle = nullptr;
    }
  }

  /// Opens the system "open file" dialog. Returns null when the user cancels.
  ///
  /// Opens the system "open file" dialog, allowing several files at once.
  ///
  /// Returns the chosen absolute paths (empty when the user cancelled).
  /// The dialog is modal and runs on the calling thread, so it is invoked only from
  /// a direct user action (never while an analysis is running).
  Future<List<String>> pickTextFiles(
      {String title = '添加材料（TXT / MD / PDF / DOCX / PPTX，可多选）'}) async {
    _ensureAlive();
    final result = _bindings.pickFiles(_handle, title: title);
    if (result.error != null) {
      throw NativeCallException('dialog', result.error!);
    }
    return result.paths;
  }

  /// Shows a Windows notification (tray balloon). Returns false when the OS refuses
  /// it (notifications disabled / policy); the caller must not claim it was sent.
  bool showSystemNotification(String title, String body) {
    _ensureAlive();
    return _bindings.showNotification(_handle, title, body);
  }

  /// True once after the user clicked the last notification.
  bool takeNotificationClick() {
    _ensureAlive();
    return _bindings.takeNotificationClick(_handle);
  }

  void _ensureAlive() {
    if (_disposed || _handle == nullptr) {
      throw NativeCallException('disposed', '原生桥接已关闭');
    }
  }

  /// Shared terminal-result reader for analysis and probe jobs.
  Map<String, dynamic>? _resultJson(int job) {
    final res = _bindings.result(_handle, job);
    if (!res.ok) {
      final map = _tryDecode(res.error);
      if (map != null && map['errorKind'] == 'running') return null;
      throw NativeCallException(
          (map?['errorKind'] as String?) ?? 'result',
          (map?['error'] as String?) ?? _messageFrom(res.error),
          data: map);
    }
    return _decodeObject(res.json, '结果读取');
  }

  static Map<String, dynamic> _decodeObject(String? raw, String what) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) return value;
    } on FormatException {
      // Fall through to the explicit error below.
    }
    throw NativeCallException('decode', '$what返回的内容不是有效 JSON');
  }

  static void _throwIfNotOk(Map<String, dynamic> json) {
    if (json['ok'] == false) {
      throw NativeCallException(
        (json['errorKind'] as String?) ?? 'unknown',
        (json['error'] as String?) ?? '原生调用失败',
        data: json,
      );
    }
  }

  static String _messageFrom(String? raw) {
    final map = _tryDecode(raw);
    return (map?['error'] as String?) ?? raw ?? '原生调用失败';
  }

  static Map<String, dynamic>? _tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort extraction of a human message from a raw native payload.
  static String humanize(String? raw) {
    final map = _tryDecode(raw);
    if (map != null) {
      if (map['error'] is String) return map['error'] as String;
      if (map['message'] is String) return map['message'] as String;
    }
    return raw ?? '未知错误';
  }
}

