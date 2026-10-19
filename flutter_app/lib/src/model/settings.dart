import 'key_chord.dart';

// Settings value objects: provider protocol, thinking mode, provider profile,
// model selection/source and the local application preferences.
//
// Deliberately **pure Dart** (no Flutter imports): `tool/seed_demo_data.dart` runs on
// the plain Dart VM and imports `model/session.dart`, which now carries a
// [ModelSelection]. Theme/send-mode choices are therefore plain enums, and the UI maps
// them to Flutter's own enums (`AppThemeMode` -> `ThemeMode`).
//
// Serialisation rules:
//   * field names match the native `settings.json` schema (`schemaVersion: 2`);
//   * `fromJson` never throws on missing/garbage fields: it falls back to defaults,
//     because a single bad connection must not make the whole settings file unreadable;
//   * identity fields are never invented: [ModelSource.fromJson] returns `null` when the
//     profile/model identity is missing instead of showing a made-up name.

/// Chat protocol of a provider profile.
///
/// The C core also has an internal `legacy` protocol (0) for the old `config.json`;
/// it is never written by this Dart layer.
enum ProviderProtocol {
  deepseekChat('deepseek-chat', 'DeepSeek 官方'),
  openAiChat('openai-chat', 'OpenAI 兼容');

  const ProviderProtocol(this.wireName, this.label);

  /// Value used in `settings.json` and in bridge JSON.
  final String wireName;

  /// Short human label for the settings UI.
  final String label;

  /// True only for protocols where `thinking` / `reasoning_effort` may be sent.
  bool get supportsThinking => this == ProviderProtocol.deepseekChat;

  /// Lenient parser: unknown values fall back instead of throwing.
  static ProviderProtocol parse(
    Object? value, {
    ProviderProtocol fallback = ProviderProtocol.deepseekChat,
  }) {
    if (value is ProviderProtocol) return value;
    if (value is String) {
      final text = value.trim().toLowerCase();
      for (final p in values) {
        if (p.wireName == text || p.name.toLowerCase() == text) return p;
      }
      if (text == 'deepseek') return ProviderProtocol.deepseekChat;
      if (text == 'openai') return ProviderProtocol.openAiChat;
    }
    return fallback;
  }
}

/// Thinking support of a provider profile / request.
enum ThinkingMode {
  unsupported('unsupported', '不支持'),
  disabled('disabled', '关闭'),
  enabled('enabled', '开启');

  const ThinkingMode(this.wireName, this.label);

  final String wireName;
  final String label;

  static ThinkingMode parse(
    Object? value, {
    ThinkingMode fallback = ThinkingMode.disabled,
  }) {
    if (value is ThinkingMode) return value;
    if (value is String) {
      final text = value.trim().toLowerCase();
      for (final m in values) {
        if (m.wireName == text || m.name.toLowerCase() == text) return m;
      }
      if (text == 'true') return ThinkingMode.enabled;
      if (text == 'false') return ThinkingMode.disabled;
    }
    return fallback;
  }
}

/// The only reasoning-effort values the C core accepts when thinking is enabled.
abstract final class ReasoningEffort {
  static const String low = 'low';
  static const String high = 'high';
  static const String max = 'max';

  static const List<String> values = <String>[low, high, max];

  static const String defaultValue = high;

  /// Returns the normalised value, or `null` when [value] is not supported.
  static String? normalize(Object? value) {
    if (value is! String) return null;
    final text = value.trim().toLowerCase();
    return values.contains(text) ? text : null;
  }

  static bool isSupported(Object? value) => normalize(value) != null;
}

/// Authentication modes understood by the native layer.
abstract final class AuthMode {
  static const String bearer = 'bearer';
  static const String none = 'none';

  static String normalize(Object? value, {String fallback = bearer}) {
    if (value is! String) return fallback;
    final text = value.trim().toLowerCase();
    return text == bearer || text == none ? text : fallback;
  }
}

/// Valid identity shape for a profile id (shared with the C layer).
final RegExp kProfileIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

final RegExp _httpUrlPattern = RegExp(r'^https?://\S+$');

final RegExp _envVarPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// One configured provider connection (mirrors the native `TsProfile`).
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.name,
    this.revision = 0,
    this.protocol = ProviderProtocol.deepseekChat,
    this.baseUrl = '',
    this.chatUrl = '',
    this.modelsUrl = '',
    this.authMode = AuthMode.bearer,
    this.apiKeyEnv = '',
    this.modelId = '',
    this.thinking = ThinkingMode.disabled,
    this.reasoningEffort,
    this.jsonMode = true,
    this.credentialConfigured = false,
    this.credentialHost,
  });

  /// DeepSeek official preset (thinking on, JSON mode on, key in CredMan).
  factory ProviderProfile.deepseekPreset({
    String id = 'deepseek-official',
    String name = 'DeepSeek 官方',
    int revision = 0,
    String baseUrl = 'https://api.deepseek.com',
    String modelId = 'deepseek-chat',
  }) =>
      ProviderProfile(
        id: id,
        name: name,
        revision: revision,
        protocol: ProviderProtocol.deepseekChat,
        baseUrl: baseUrl,
        chatUrl: '$baseUrl/chat/completions',
        modelsUrl: '$baseUrl/models',
        authMode: AuthMode.bearer,
        modelId: modelId,
        thinking: ThinkingMode.enabled,
        reasoningEffort: ReasoningEffort.defaultValue,
        jsonMode: true,
      );

  /// OpenAI-compatible preset: no thinking parameters are ever sent.
  factory ProviderProfile.compatiblePreset({
    required String id,
    required String name,
    String baseUrl = '',
    String chatUrl = '',
    String modelsUrl = '',
    int revision = 0,
    String modelId = '',
    bool jsonMode = true,
  }) =>
      ProviderProfile(
        id: id,
        name: name,
        revision: revision,
        protocol: ProviderProtocol.openAiChat,
        baseUrl: baseUrl,
        chatUrl: chatUrl.isEmpty && baseUrl.isNotEmpty
            ? '$baseUrl/chat/completions'
            : chatUrl,
        modelsUrl: modelsUrl.isEmpty && baseUrl.isNotEmpty
            ? '$baseUrl/models'
            : modelsUrl,
        authMode: AuthMode.bearer,
        modelId: modelId,
        thinking: ThinkingMode.unsupported,
        jsonMode: jsonMode,
      );

  /// Stable identity; never changes for an existing connection.
  final String id;
  final String name;

  /// Optimistic-concurrency revision. `0` means "not saved yet"; the native layer
  /// stores `1` after the first successful save.
  final int revision;

  final ProviderProtocol protocol;

  /// Display/derivation only; requests always use [chatUrl] verbatim.
  final String baseUrl;

  /// Complete Chat Completions URL. Never derived by appending `/v1` at runtime.
  final String chatUrl;

  /// Complete model-list URL; may be empty when discovery is unsupported.
  final String modelsUrl;

  final String authMode;

  /// Legacy compatibility: name of the environment variable holding the key.
  final String apiKeyEnv;

  final String modelId;
  final ThinkingMode thinking;
  final String? reasoningEffort;
  final bool jsonMode;

  /// Whether a key exists in Windows Credential Manager. The key itself is never
  /// readable from Dart.
  final bool credentialConfigured;

  /// Host the stored credential belongs to; a changed host invalidates it.
  final String? credentialHost;

  /// Host of [chatUrl] (diagnostics / credential-host comparison).
  String get endpointHost {
    final host = Uri.tryParse(chatUrl)?.host ?? '';
    if (host.isNotEmpty) return host;
    return Uri.tryParse(baseUrl)?.host ?? '';
  }

  bool get supportsThinking => protocol.supportsThinking;

  /// Effective thinking: only DeepSeek-protocol profiles may enable thinking.
  ThinkingMode get effectiveThinking =>
      protocol.supportsThinking ? thinking : ThinkingMode.unsupported;

  /// Effective effort: only meaningful when thinking is enabled.
  String? get effectiveReasoningEffort =>
      effectiveThinking == ThinkingMode.enabled
          ? ReasoningEffort.normalize(reasoningEffort) ??
              ReasoningEffort.defaultValue
          : null;

  /// Human readable validation problems; empty means "safe to save".
  List<String> validate() {
    final errors = <String>[];
    if (!kProfileIdPattern.hasMatch(id)) {
      errors.add('连接 ID 只能包含字母、数字、下划线和连字符（1-64 个字符）');
    }
    if (name.trim().isEmpty) {
      errors.add('请填写连接名称');
    }
    if (revision < 0) {
      errors.add('连接版本号无效（revision=$revision）');
    }
    if (baseUrl.trim().isNotEmpty && !_httpUrlPattern.hasMatch(baseUrl.trim())) {
      errors.add('基础地址必须是 http:// 或 https:// 开头的完整地址');
    }
    if (chatUrl.trim().isEmpty) {
      errors.add('请填写完整的 Chat Completions 地址（http:// 或 https://）');
    } else if (!_httpUrlPattern.hasMatch(chatUrl.trim())) {
      errors.add('Chat Completions 地址必须是 http:// 或 https:// 开头的完整地址');
    }
    if (modelsUrl.trim().isNotEmpty &&
        !_httpUrlPattern.hasMatch(modelsUrl.trim())) {
      errors.add('模型列表地址必须是 http:// 或 https:// 开头的完整地址');
    }
    if (authMode != AuthMode.bearer && authMode != AuthMode.none) {
      errors.add('认证方式只能是 bearer 或 none');
    }
    if (apiKeyEnv.trim().isNotEmpty &&
        !_envVarPattern.hasMatch(apiKeyEnv.trim())) {
      errors.add('环境变量名只能包含字母、数字和下划线，且不能以数字开头');
    }
    if (modelId.trim().isEmpty) {
      errors.add('请选择或填写模型 ID');
    }
    if (thinking == ThinkingMode.enabled &&
        protocol.supportsThinking &&
        !ReasoningEffort.isSupported(reasoningEffort)) {
      errors.add('思考强度只能是 low / high / max');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  /// First validation problem, or `null`.
  String? get firstError {
    final list = validate();
    return list.isEmpty ? null : list.first;
  }

  ProviderProfile copyWith({
    String? id,
    String? name,
    int? revision,
    ProviderProtocol? protocol,
    String? baseUrl,
    String? chatUrl,
    String? modelsUrl,
    String? authMode,
    String? apiKeyEnv,
    String? modelId,
    ThinkingMode? thinking,
    String? reasoningEffort,
    bool clearReasoningEffort = false,
    bool? jsonMode,
    bool? credentialConfigured,
    String? credentialHost,
    bool clearCredentialHost = false,
  }) =>
      ProviderProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        revision: revision ?? this.revision,
        protocol: protocol ?? this.protocol,
        baseUrl: baseUrl ?? this.baseUrl,
        chatUrl: chatUrl ?? this.chatUrl,
        modelsUrl: modelsUrl ?? this.modelsUrl,
        authMode: authMode ?? this.authMode,
        apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
        modelId: modelId ?? this.modelId,
        thinking: thinking ?? this.thinking,
        reasoningEffort: clearReasoningEffort
            ? null
            : (reasoningEffort ?? this.reasoningEffort),
        jsonMode: jsonMode ?? this.jsonMode,
        credentialConfigured: credentialConfigured ?? this.credentialConfigured,
        credentialHost: clearCredentialHost
            ? null
            : (credentialHost ?? this.credentialHost),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'revision': revision,
        'protocol': protocol.wireName,
        'baseUrl': baseUrl,
        'chatUrl': chatUrl,
        'modelsUrl': modelsUrl,
        'authMode': authMode,
        'apiKeyEnv': apiKeyEnv,
        'modelId': modelId,
        'thinking': thinking.wireName,
        'reasoningEffort': reasoningEffort,
        'jsonMode': jsonMode,
        'credentialConfigured': credentialConfigured,
        'credentialHost': credentialHost,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> json) {
    final protocol = ProviderProtocol.parse(json['protocol']);
    final thinking = ThinkingMode.parse(
      json['thinking'],
      fallback: protocol.supportsThinking
          ? ThinkingMode.disabled
          : ThinkingMode.unsupported,
    );
    return ProviderProfile(
      id: (_stringOr(json['id']) ?? '').trim(),
      name: _stringOr(json['name']) ?? '',
      revision: _intOr(json['revision'], 0),
      protocol: protocol,
      baseUrl: _stringOr(json['baseUrl']) ?? '',
      chatUrl: _stringOr(json['chatUrl']) ?? '',
      modelsUrl: _stringOr(json['modelsUrl']) ?? '',
      authMode: AuthMode.normalize(json['authMode']),
      apiKeyEnv: _stringOr(json['apiKeyEnv']) ?? '',
      modelId: _stringOr(json['modelId']) ?? '',
      thinking: thinking,
      reasoningEffort: ReasoningEffort.normalize(json['reasoningEffort']),
      jsonMode: _boolOr(json['jsonMode'], true),
      credentialConfigured: _boolOr(json['credentialConfigured'], false),
      credentialHost: _emptyToNull(json['credentialHost']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProviderProfile &&
      other.id == id &&
      other.name == name &&
      other.revision == revision &&
      other.protocol == protocol &&
      other.baseUrl == baseUrl &&
      other.chatUrl == chatUrl &&
      other.modelsUrl == modelsUrl &&
      other.authMode == authMode &&
      other.apiKeyEnv == apiKeyEnv &&
      other.modelId == modelId &&
      other.thinking == thinking &&
      other.reasoningEffort == reasoningEffort &&
      other.jsonMode == jsonMode &&
      other.credentialConfigured == credentialConfigured &&
      other.credentialHost == credentialHost;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        revision,
        protocol,
        baseUrl,
        chatUrl,
        modelsUrl,
        authMode,
        apiKeyEnv,
        modelId,
        thinking,
        reasoningEffort,
        jsonMode,
        credentialConfigured,
        credentialHost,
      );

  @override
  String toString() =>
      'ProviderProfile($id, rev=$revision, ${protocol.wireName}, model=$modelId)';
}

/// A concrete "use this profile revision + model" choice captured at send time.
class ModelSelection {
  const ModelSelection({
    required this.profileId,
    required this.profileRevision,
    required this.modelId,
    this.thinking = ThinkingMode.disabled,
    this.reasoningEffort,
  });

  final String profileId;

  /// Revision of the profile the request was configured with. Required: a request
  /// with an unknown revision must fail instead of silently using the newest config.
  final int profileRevision;

  final String modelId;
  final ThinkingMode thinking;
  final String? reasoningEffort;

  List<String> validate() {
    final errors = <String>[];
    if (profileId.trim().isEmpty) {
      errors.add('请选择模型连接');
    } else if (!kProfileIdPattern.hasMatch(profileId.trim())) {
      errors.add('模型连接 ID 格式不正确');
    }
    if (profileRevision < 1) {
      errors.add('缺少模型配置版本，请刷新设置后重试');
    }
    if (modelId.trim().isEmpty) {
      errors.add('请选择或填写模型 ID');
    }
    if (thinking == ThinkingMode.enabled &&
        !ReasoningEffort.isSupported(reasoningEffort)) {
      errors.add('思考强度只能是 low / high / max');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  String? get firstError {
    final list = validate();
    return list.isEmpty ? null : list.first;
  }

  ModelSelection copyWith({
    String? profileId,
    int? profileRevision,
    String? modelId,
    ThinkingMode? thinking,
    String? reasoningEffort,
    bool clearReasoningEffort = false,
  }) =>
      ModelSelection(
        profileId: profileId ?? this.profileId,
        profileRevision: profileRevision ?? this.profileRevision,
        modelId: modelId ?? this.modelId,
        thinking: thinking ?? this.thinking,
        reasoningEffort: clearReasoningEffort
            ? null
            : (reasoningEffort ?? this.reasoningEffort),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'profileId': profileId,
        'profileRevision': profileRevision,
        'modelId': modelId,
        'thinking': thinking.wireName,
        'reasoningEffort': reasoningEffort,
      };

  /// Lenient parse for stored conversation overrides; identity is kept verbatim so a
  /// stale selection stays detectable (it is *not* silently repaired).
  factory ModelSelection.fromJson(Map<String, dynamic> json) => ModelSelection(
        profileId: _stringOr(json['profileId']) ?? '',
        profileRevision: _intOr(json['profileRevision'], 0),
        modelId: _stringOr(json['modelId']) ?? '',
        thinking: ThinkingMode.parse(json['thinking']),
        reasoningEffort: ReasoningEffort.normalize(json['reasoningEffort']),
      );

  /// Returns `null` when [json] carries no usable identity at all.
  static ModelSelection? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final selection = ModelSelection.fromJson(json);
    if (selection.profileId.trim().isEmpty || selection.modelId.trim().isEmpty) {
      return null;
    }
    return selection;
  }

  @override
  bool operator ==(Object other) =>
      other is ModelSelection &&
      other.profileId == profileId &&
      other.profileRevision == profileRevision &&
      other.modelId == modelId &&
      other.thinking == thinking &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(
        profileId,
        profileRevision,
        modelId,
        thinking,
        reasoningEffort,
      );

  @override
  String toString() =>
      'ModelSelection($profileId@$profileRevision/$modelId, ${thinking.wireName}, '
      '$reasoningEffort)';
}

/// Provenance of a committed plan version: which profile/model produced it.
///
/// Deliberately contains no secret. [ModelSource.fromJson] returns `null` when the
/// identity is missing so old versions are shown as "来源未知" instead of inventing a
/// name.
class ModelSource {
  const ModelSource({
    required this.profileId,
    required this.profileRevision,
    required this.modelId,
    this.protocol = ProviderProtocol.deepseekChat,
    this.thinking = ThinkingMode.disabled,
    this.reasoningEffort,
    this.endpointHost = '',
  });

  final String profileId;
  final int profileRevision;
  final String modelId;
  final ProviderProtocol protocol;
  final ThinkingMode thinking;
  final String? reasoningEffort;

  /// Host only (never the full URL with query parameters, never a key).
  final String endpointHost;

  static ModelSource? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final profileId = (_stringOr(json['profileId']) ?? '').trim();
    final modelId = (_stringOr(json['modelId']) ?? '').trim();
    if (profileId.isEmpty || modelId.isEmpty) return null;
    return ModelSource(
      profileId: profileId,
      profileRevision: _intOr(json['profileRevision'], 0),
      modelId: modelId,
      protocol: ProviderProtocol.parse(json['protocol']),
      thinking: ThinkingMode.parse(json['thinking']),
      reasoningEffort: ReasoningEffort.normalize(json['reasoningEffort']),
      endpointHost: (_stringOr(json['endpointHost']) ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'profileId': profileId,
        'profileRevision': profileRevision,
        'modelId': modelId,
        'protocol': protocol.wireName,
        'thinking': thinking.wireName,
        'reasoningEffort': reasoningEffort,
        'endpointHost': endpointHost,
      };

  @override
  bool operator ==(Object other) =>
      other is ModelSource &&
      other.profileId == profileId &&
      other.profileRevision == profileRevision &&
      other.modelId == modelId &&
      other.protocol == protocol &&
      other.thinking == thinking &&
      other.reasoningEffort == reasoningEffort &&
      other.endpointHost == endpointHost;

  @override
  int get hashCode => Object.hash(profileId, profileRevision, modelId, protocol,
      thinking, reasoningEffort, endpointHost);

  @override
  String toString() => 'ModelSource($profileId@$profileRevision/$modelId)';
}

/// Window theme choice. Pure Dart so the model layer stays Flutter-free; the UI maps
/// this to `ThemeMode`.
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeMode(this.wireName, this.label);

  final String wireName;
  final String label;

  static AppThemeMode parse(
    Object? value, {
    AppThemeMode fallback = AppThemeMode.system,
  }) {
    if (value is AppThemeMode) return value;
    if (value is String) {
      final text = value.trim().toLowerCase();
      for (final m in values) {
        if (m.wireName == text || m.name.toLowerCase() == text) return m;
      }
    }
    return fallback;
  }
}

/// What pressing Enter in the composer does.
enum SendMode {
  ctrlEnter('ctrlEnter', 'Ctrl+Enter 发送'),
  enter('enter', 'Enter 发送');

  const SendMode(this.wireName, this.label);

  final String wireName;
  final String label;

  static SendMode parse(
    Object? value, {
    SendMode fallback = SendMode.ctrlEnter,
  }) {
    if (value is SendMode) return value;
    if (value is String) {
      final text = value.trim().toLowerCase();
      for (final m in values) {
        if (m.wireName.toLowerCase() == text || m.name.toLowerCase() == text) {
          return m;
        }
      }
    }
    return fallback;
  }
}

/// Local application preferences (`<dataRoot>/settings/app_prefs.json`).
///
/// These never leave the machine and contain no secrets. [AppPreferences.fromJson]
/// clamps values so a hand-edited file cannot produce an unreadable UI
/// (e.g. `fontScale: 99`).
class AppPreferences {
  const AppPreferences({
    this.themeMode = AppThemeMode.system,
    this.fontScale = 1.0,
    this.defaultChartMode = kChartModeTree,
    this.showCompletedTasks = true,
    this.sendMode = SendMode.ctrlEnter,
    this.notifyOnSuccess = true,
    this.notifyOnFailure = true,
    this.notifySystem = false,
    this.shortcutOverrides = const <String, KeyChord?>{},
  });

  static const String kChartModeTree = 'tree';
  static const String kChartModeGantt = 'gantt';

  static const List<String> chartModes = <String>[kChartModeTree, kChartModeGantt];

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.30;

  final AppThemeMode themeMode;
  final double fontScale;

  /// Default dependency view for new conversations ('tree' or 'gantt').
  final String defaultChartMode;

  final bool showCompletedTasks;
  final SendMode sendMode;
  final bool notifyOnSuccess;
  final bool notifyOnFailure;
  final bool notifySystem;

  /// Stable command id -> override. Absent = default, explicit null = unbound.
  final Map<String, KeyChord?> shortcutOverrides;

  bool get sendOnEnter => sendMode == SendMode.enter;

  /// True when the value is inside the supported slider range.
  static bool isFontScaleAllowed(double value) =>
      value >= minFontScale && value <= maxFontScale;

  /// Returns a copy with every field normalised (unknown enums/chart modes fall back,
  /// font scale clamped).
  AppPreferences normalized() => AppPreferences(
        themeMode: themeMode,
        fontScale: fontScale.clamp(minFontScale, maxFontScale).toDouble(),
        defaultChartMode:
            chartModes.contains(defaultChartMode) ? defaultChartMode : kChartModeTree,
        showCompletedTasks: showCompletedTasks,
        sendMode: sendMode,
        notifyOnSuccess: notifyOnSuccess,
        notifyOnFailure: notifyOnFailure,
        notifySystem: notifySystem,
        shortcutOverrides:
            Map<String, KeyChord?>.unmodifiable(shortcutOverrides),
      );

  AppPreferences copyWith({
    AppThemeMode? themeMode,
    double? fontScale,
    String? defaultChartMode,
    bool? showCompletedTasks,
    SendMode? sendMode,
    bool? notifyOnSuccess,
    bool? notifyOnFailure,
    bool? notifySystem,
    Map<String, KeyChord?>? shortcutOverrides,
  }) =>
      AppPreferences(
        themeMode: themeMode ?? this.themeMode,
        fontScale: fontScale ?? this.fontScale,
        defaultChartMode: defaultChartMode ?? this.defaultChartMode,
        showCompletedTasks: showCompletedTasks ?? this.showCompletedTasks,
        sendMode: sendMode ?? this.sendMode,
        notifyOnSuccess: notifyOnSuccess ?? this.notifyOnSuccess,
        notifyOnFailure: notifyOnFailure ?? this.notifyOnFailure,
        notifySystem: notifySystem ?? this.notifySystem,
        shortcutOverrides: shortcutOverrides ?? this.shortcutOverrides,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'themeMode': themeMode.wireName,
        'fontScale': fontScale,
        'defaultChartMode': defaultChartMode,
        'showCompletedTasks': showCompletedTasks,
        'sendMode': sendMode.wireName,
        'notifyOnSuccess': notifyOnSuccess,
        'notifyOnFailure': notifyOnFailure,
        'notifySystem': notifySystem,
        'shortcuts': <String, dynamic>{
          for (final e in shortcutOverrides.entries)
            e.key: e.value?.toJson(),
        },
      };

  factory AppPreferences.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const AppPreferences();
    final rawScale = _doubleOr(json['fontScale']);
    final chart = (_stringOr(json['defaultChartMode']) ?? '').trim();
    return AppPreferences(
      themeMode: AppThemeMode.parse(json['themeMode']),
      fontScale: rawScale == null
          ? 1.0
          : rawScale.clamp(minFontScale, maxFontScale).toDouble(),
      defaultChartMode: chartModes.contains(chart) ? chart : kChartModeTree,
      showCompletedTasks: _boolOr(json['showCompletedTasks'], true),
      sendMode: SendMode.parse(json['sendMode']),
      notifyOnSuccess: _boolOr(json['notifyOnSuccess'], true),
      notifyOnFailure: _boolOr(json['notifyOnFailure'], true),
      notifySystem: _boolOr(json['notifySystem'], false),
      shortcutOverrides: _shortcutsOr(json['shortcuts']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.themeMode == themeMode &&
      other.fontScale == fontScale &&
      other.defaultChartMode == defaultChartMode &&
      other.showCompletedTasks == showCompletedTasks &&
      other.sendMode == sendMode &&
      other.notifyOnSuccess == notifyOnSuccess &&
      other.notifyOnFailure == notifyOnFailure &&
      other.notifySystem == notifySystem &&
      _sameShortcuts(other.shortcutOverrides, shortcutOverrides);

  static bool _sameShortcuts(
      Map<String, KeyChord?> a, Map<String, KeyChord?> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        themeMode,
        fontScale,
        defaultChartMode,
        showCompletedTasks,
        sendMode,
        notifyOnSuccess,
        notifyOnFailure,
        notifySystem,
        Object.hashAllUnordered(shortcutOverrides.entries
            .map((e) => '${e.key}=${e.value?.signature ?? 'null'}')),
      );

  @override
  String toString() => 'AppPreferences(${themeMode.wireName}, scale=$fontScale, '
      'chart=$defaultChartMode, send=${sendMode.wireName})';
}

/// Parses the stable shortcuts map. Invalid chords are dropped so a corrupt file
/// cannot make the app unstartable.
Map<String, KeyChord?> _shortcutsOr(Object? raw) {
  if (raw is! Map) return const <String, KeyChord?>{};
  final out = <String, KeyChord?>{};
  raw.forEach((key, value) {
    final id = key is String ? key.trim() : '';
    if (id.isEmpty) return;
    if (value == null) {
      out[id] = null;
    } else {
      final chord = KeyChord.fromJson(value);
      if (chord != null) out[id] = chord;
    }
  });
  return Map<String, KeyChord?>.unmodifiable(out);
}

String? _emptyToNull(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

/// Tolerant field readers: a hand-edited or foreign JSON file must never crash the app
/// with a `TypeError` just because one field has the wrong JSON type.
String? _stringOr(Object? value) => value is String ? value : null;

bool _boolOr(Object? value, bool fallback) => value is bool ? value : fallback;

int _intOr(Object? value, int fallback) => value is num ? value.toInt() : fallback;

double? _doubleOr(Object? value) => value is num ? value.toDouble() : null;

