// SettingsController — one shared source of truth for the settings UI and the
// conversation flow.
//
// Design rules:
//   * committed state ([prefs], [profiles], [defaultSelection]) is only replaced after a
//     successful save; the editable copy lives in [draft], so cancelling a dialog never
//     leaks half-applied configuration;
//   * model profiles are owned by the native layer (`settings.json`), preferences are a
//     plain JSON file — `save()` writes the file first, then the native document, and
//     rolls the file back if the native save fails, so both sides keep the old values;
//   * probes are asynchronous, cancellable and generation-guarded: a late probe result
//     is reported as cancelled and never becomes the "last" answer;
//   * no secret ever leaves this class: keys go straight to the native credential store
//     and only a boolean "configured" flag is kept.

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ffi/native_gateway.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../model/shortcuts.dart';
import 'settings_store.dart';

/// Human-readable mapping for every error kind the native layer / HTTP layer can
/// produce. The UI shows these strings; the raw kind stays available for branching.
abstract final class SettingsErrorCatalog {
  static const String auth = 'auth';
  static const String forbidden = 'forbidden';
  static const String notFound = 'notFound';
  static const String rateLimit = 'rateLimit';
  static const String server = 'server';
  static const String network = 'network';
  static const String tls = 'tls';
  static const String timeout = 'timeout';
  static const String truncated = 'truncated';
  static const String invalidJson = 'invalidJson';
  static const String revision = 'revision';
  static const String profileDeleted = 'profileDeleted';
  static const String conflict = 'conflict';
  static const String cancelled = 'cancelled';
  static const String credentialHost = 'credentialHost';

  static const Map<String, String> _texts = <String, String>{
    auth: 'API Key 无效或已过期（401），请在「设置 → 模型」重新填写',
    forbidden: '没有访问该模型的权限（403），请确认账号与模型是否匹配',
    notFound: '接口地址或模型不存在（404），请检查完整 URL 与模型 ID',
    rateLimit: '请求过于频繁或被限流（429），请稍后重试',
    server: '服务端暂时不可用（5xx），请稍后重试',
    network: '无法连接服务器（网络不通或域名解析失败），请检查网络与地址',
    tls: 'TLS 证书校验失败（程序不会关闭证书校验），请检查系统时间、代理与根证书',
    timeout: '等待响应超时，请稍后重试',
    truncated: '响应被截断（内容不完整），请重试',
    invalidJson: '服务返回的不是有效 JSON，请确认地址指向兼容 Chat Completions 的接口',
    'badJson': '服务返回的不是有效 JSON，请确认地址指向兼容 Chat Completions 的接口',
    'decode': '服务返回的不是有效 JSON，请确认地址指向兼容 Chat Completions 的接口',
    revision: '模型配置版本不一致，请刷新设置后重试',
    'unknownRevision': '模型配置版本不一致，请刷新设置后重试',
    profileDeleted: '该模型连接已被删除，请到「设置 → 模型」重新选择',
    conflict: '模型配置已被修改，请刷新后重试',
    cancelled: '已取消',
    credentialHost: '连接地址已更换，请重新确认认证方式并重新输入 API Key',
    'hostMismatch': '连接地址已更换，请重新确认认证方式并重新输入 API Key',
    'credential': '无法读写系统凭据存储，请检查当前账户权限',
    'typeMismatch': '返回结果类型不匹配，已拒绝使用该结果',
    'abi': '分析内核版本不匹配（界面需要 ABI 2），请使用随程序提供的 ts_bridge.dll',
    'disposed': '原生桥接已关闭',
    'bridge': '原生设置不可用，请重新启动程序',
    'config': '配置不完整，请补齐后重试',
    'validation': '配置校验未通过，请检查填写内容',
    'unknown': '操作失败，请稍后重试',
  };

  /// Maps a status code to a kind. Exposed for tests.
  static String? kindForStatus(int? status) {
    if (status == null || status <= 0) return null;
    if (status == 401) return auth;
    if (status == 403) return forbidden;
    if (status == 404) return notFound;
    if (status == 408) return timeout;
    if (status == 429) return rateLimit;
    if (status >= 500) return server;
    return null;
  }

  /// Readable text for a kind, falling back to the status code and then to the native
  /// message (never to a bare "unknown error").
  static String describeKind(
    String? kind, {
    String? message,
    int? httpStatus,
  }) {
    final normalized = (kind ?? '').trim();
    final direct = _texts[normalized] ?? _texts[normalized.toLowerCase()];
    if (direct != null) return direct;
    final byStatus = kindForStatus(httpStatus);
    if (byStatus != null) return _texts[byStatus]!;
    final trimmed = (message ?? '').trim();
    if (trimmed.isNotEmpty) return trimmed;
    return _texts['unknown']!;
  }

  /// Readable text for a native failure.
  static String describe(NativeCallException error) => describeKind(
        error.kind,
        message: error.message,
        httpStatus: (error.data?['httpStatus'] as num?)?.toInt(),
      );

  /// Readable text for a probe result.
  static String describeProbe(ProbeOutcome outcome) {
    if (outcome.ok) {
      if (outcome.kind == 'models') {
        final count = outcome.models.length;
        return count == 0 ? '连接成功，但服务未返回任何模型' : '连接成功，发现 $count 个模型';
      }
      return '连接成功，模型返回了可用响应';
    }
    return describeKind(
      outcome.errorKind,
      message: outcome.error,
      httpStatus: outcome.httpStatus,
    );
  }
}

/// An editable settings snapshot: exactly what "保存" would write.
///
/// [profiles] never contains the ids in [deletions]; keeping both makes the dirty
/// check explicit and lets a save omit deleted connections from the native document.
class SettingsDraft {
  const SettingsDraft({
    required this.prefs,
    this.profiles = const <ProviderProfile>[],
    this.defaultSelection,
    this.deletions = const <String>{},
  });

  final AppPreferences prefs;
  final List<ProviderProfile> profiles;
  final ModelSelection? defaultSelection;

  /// Profile ids removed in this draft (still undeleted on disk until save).
  final Set<String> deletions;

  SettingsDraft copyWith({
    AppPreferences? prefs,
    List<ProviderProfile>? profiles,
    ModelSelection? defaultSelection,
    bool clearDefaultSelection = false,
    Set<String>? deletions,
  }) =>
      SettingsDraft(
        prefs: prefs ?? this.prefs,
        profiles: profiles ?? this.profiles,
        defaultSelection: clearDefaultSelection
            ? null
            : (defaultSelection ?? this.defaultSelection),
        deletions: deletions ?? this.deletions,
      );

  @override
  String toString() => 'SettingsDraft(prefs=$prefs, profiles=${profiles.length}, '
      'default=${defaultSelection?.profileId ?? '-'}, deletions=${deletions.length})';
}

/// The native `settings.json` document, decoded.
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.profiles,
    this.defaultSelection,
    this.settingsPath = '',
    this.schemaVersion = profilesSchemaVersion,
    this.warning,
  });

  /// Native settings schema version (ABI 2).
  static const int profilesSchemaVersion = 2;

  final List<ProviderProfile> profiles;
  final ModelSelection? defaultSelection;
  final String settingsPath;
  final int schemaVersion;
  final String? warning;

  /// Parses the document returned by `ts_bridge_settings_get` /
  /// `ts_bridge_settings_save`. Throws [NativeCallException] when the native layer
  /// reported `ok:false`.
  factory SettingsSnapshot.fromNative(Map<String, dynamic> json) {
    if (json['ok'] == false) {
      throw NativeCallException(
        (json['errorKind'] as String?) ?? 'unknown',
        (json['error'] as String?) ?? '读取模型设置失败',
        data: json,
      );
    }
    final profiles = <ProviderProfile>[];
    for (final raw in (json['profiles'] as List<dynamic>?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final profile = ProviderProfile.fromJson(raw);
      if (profile.id.trim().isNotEmpty) profiles.add(profile);
    }
    final defaultProfileId = (json['defaultProfileId'] as String?)?.trim() ?? '';
    final defaultModelId = (json['defaultModelId'] as String?)?.trim() ?? '';
    ModelSelection? selection;
    if (defaultProfileId.isNotEmpty) {
      ProviderProfile? owner;
      for (final p in profiles) {
        if (p.id == defaultProfileId) {
          owner = p;
          break;
        }
      }
      if (owner != null) {
        final thinking = ThinkingMode.parse(
          json['defaultThinking'],
          fallback: owner.effectiveThinking,
        );
        selection = ModelSelection(
          profileId: owner.id,
          profileRevision: owner.revision,
          modelId: defaultModelId.isNotEmpty ? defaultModelId : owner.modelId,
          thinking: thinking,
          reasoningEffort: ReasoningEffort.normalize(
                json['defaultReasoningEffort'],
              ) ??
              (thinking == ThinkingMode.enabled
                  ? owner.effectiveReasoningEffort
                  : null),
        );
      }
    }
    final warning = (json['warning'] as String?)?.trim() ?? '';
    return SettingsSnapshot(
      profiles: profiles,
      defaultSelection: selection,
      settingsPath: (json['settingsPath'] as String?) ?? '',
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? profilesSchemaVersion,
      warning: warning.isEmpty ? null : warning,
    );
  }
}

/// What a request would actually use as its model, and why it may not be sent.
///
/// The distinction matters: a conversation with an *explicit* binding that no longer
/// resolves (profile deleted / revision changed) must be blocked, never silently sent
/// with the current global default — that would make the plan provenance a lie. Only a
/// conversation without any binding (a pre-0.0.4 session) may be migrated from the
/// default, and only once.
class SelectionResolution {
  const SelectionResolution._({
    this.selection,
    this.error,
    this.migrated = false,
  });

  /// The exact selection to send; `null` when [error] explains why not.
  final ModelSelection? selection;

  /// Readable reason the request must not be sent (kept for the composer/status line).
  final String? error;

  /// True when the selection came from the global default for a conversation that had
  /// no binding of its own. The caller persists it once and tells the user.
  final bool migrated;

  bool get ok => error == null && selection != null;

  bool get failed => error != null;

  factory SelectionResolution.ready(
    ModelSelection selection, {
    bool migrated = false,
  }) =>
      SelectionResolution._(selection: selection, migrated: migrated);

  factory SelectionResolution.failure(String error) =>
      SelectionResolution._(error: error);

  @override
  String toString() => 'SelectionResolution(ok=$ok, migrated=$migrated, '
      'selection=$selection, error=${error ?? '-'})';
}

/// Global settings state shared by the settings UI and [AppController].
class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.store,
    SettingsBridge? bridge,
    this.probePollInterval = const Duration(milliseconds: 120),
    this.probeTimeout = const Duration(seconds: 35),
  })  : _bridge = bridge,
        _draft = const SettingsDraft(prefs: AppPreferences());

  final SettingsStore store;
  final SettingsBridge? _bridge;

  /// How often a probe job is polled (tests use a few milliseconds).
  final Duration probePollInterval;

  /// Controller-side budget for one probe, including polling overhead.
  final Duration probeTimeout;

  AppPreferences _prefs = const AppPreferences();
  List<ProviderProfile> _profiles = const <ProviderProfile>[];
  ModelSelection? _defaultSelection;
  String _settingsPath = '';
  bool _bridgeAvailable = false;
  bool _loaded = false;
  bool _saving = false;
  bool _probing = false;
  bool _disposed = false;
  String? _loadWarning;
  String? _lastError;
  ProbeOutcome? _lastProbe;

  SettingsDraft _draft;

  // ------------------------------------------------------------- committed

  AppPreferences get prefs => _prefs;

  List<ProviderProfile> get profiles => List<ProviderProfile>.unmodifiable(_profiles);

  ModelSelection? get defaultSelection => _defaultSelection;

  /// Path of the native `settings.json` (or of the preferences file when the native
  /// side is unavailable). Returned for the "存储" page; never a secret.
  String get settingsPath => _settingsPath;

  /// Data directory that owns both the sessions and the settings files.
  Directory get dataRoot => store.root;

  String get dataRootPath => store.root.path;

  /// True when the native settings API answered successfully.
  bool get bridgeAvailable => _bridgeAvailable;

  bool get loaded => _loaded;
  bool get saving => _saving;
  bool get probing => _probing;

  /// Non-fatal load problem (corrupt preferences file, unreadable native settings).
  String? get loadWarning => _loadWarning;

  /// Last error produced by a save/probe/credential call.
  String? get lastError => _lastError;

  /// Last probe that actually completed (a cancelled probe result is never stored).
  ProbeOutcome? get lastProbe => _lastProbe;

  bool get hasProfiles => _profiles.isNotEmpty;

  ProviderProfile? profileById(String id) {
    for (final p in _profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool credentialConfigured(String profileId) {
    final profile = _draftProfileById(profileId) ?? profileById(profileId);
    return profile?.credentialConfigured ?? false;
  }

  // ---------------------------------------------------------------- draft

  SettingsDraft get draft => _draft;

  /// True when the draft differs from the committed state.
  bool get dirty =>
      _draft.prefs != _prefs ||
      _draft.defaultSelection != _defaultSelection ||
      _draft.deletions.isNotEmpty ||
      !_sameProfiles(_draft.profiles, _profiles);

  SettingsDraft _baselineDraft() => SettingsDraft(
        prefs: _prefs,
        profiles: _profiles,
        defaultSelection: _defaultSelection,
      );

  void updateDraftPreferences(AppPreferences prefs) {
    _draft = _draft.copyWith(prefs: prefs.normalized());
    _notify();
  }

  /// Replaces the whole shortcut override map (draft-scoped; saved with 保存).
  void updateDraftShortcuts(Map<String, KeyChord?> overrides) {
    updateDraftPreferences(
        _draft.prefs.copyWith(shortcutOverrides: overrides));
  }

  /// Resolves the effective binding for [commandId] from draft preferences.
  KeyChord? shortcutFor(CommandDefinition command) =>
      resolveBinding(command.id, _draft.prefs.shortcutOverrides,
          command.defaultChord);

  /// Inserts or replaces a profile in the draft.
  ///
  /// Invalid input is still stored (the form keeps what the user typed) but the
  /// returned message lets the UI show the problem immediately.
  String? updateDraftProfile(ProviderProfile profile) {
    if (profile.id.trim().isEmpty) return '请先填写连接 ID';
    final existing = _draft.profiles.indexWhere((p) => p.id == profile.id);
    final next = List<ProviderProfile>.from(_draft.profiles);
    if (existing >= 0) {
      next[existing] = profile;
    } else {
      next.add(profile);
    }
    final deletions = Set<String>.from(_draft.deletions)..remove(profile.id);
    var selection = _draft.defaultSelection;
    if (selection != null && selection.profileId == profile.id) {
      // Keep the default pointing at the same profile, with the edited identity.
      selection = selection.copyWith(profileRevision: profile.revision);
    }
    _draft = _draft.copyWith(
      profiles: next,
      deletions: deletions,
      defaultSelection: selection,
    );
    _notify();
    return profile.firstError;
  }

  /// Alias kept for the settings UI: replace the profile with the same id.
  String? replace(ProviderProfile profile) => updateDraftProfile(profile);

  /// Marks a profile for deletion (applied on the next successful [save]).
  void removeDraftProfile(String id) {
    final existed = _draft.profiles.any((p) => p.id == id);
    if (!existed) return;
    final next = _draft.profiles.where((p) => p.id != id).toList(growable: false);
    final deletions = Set<String>.from(_draft.deletions)..add(id);
    final dropDefault = _draft.defaultSelection?.profileId == id;
    _draft = _draft.copyWith(
      profiles: next,
      deletions: deletions,
      clearDefaultSelection: dropDefault,
    );
    _notify();
  }

  String? setDraftDefaultSelection(ModelSelection? selection) {
    if (selection == null) {
      _draft = _draft.copyWith(clearDefaultSelection: true);
      _notify();
      return null;
    }
    final profile = _draftProfileById(selection.profileId);
    if (profile == null) return '请选择一个已存在的连接作为默认连接';
    if (selection.profileRevision != profile.revision &&
        !_isPostSaveRevision(profile, selection)) {
      return '该连接的配置已更新，请重新选择默认连接';
    }
    final invalid = selection.validate();
    if (invalid.isNotEmpty) return invalid.first;
    _draft = _draft.copyWith(defaultSelection: selection);
    _notify();
    return null;
  }

  /// A brand-new draft profile (revision 0) becomes revision 1 after the next save, so a
  /// default selection may legitimately carry revision 1 before that save. This is used
  /// by restore and by "select the new default in the same save" flows.
  static bool _isPostSaveRevision(
          ProviderProfile profile, ModelSelection selection) =>
      profile.revision == 0 && selection.profileRevision == 1;

  /// Replaces the draft with connections restored from a backup and saves once.
  ///
  /// The backup does not contain credentials, so every restored connection is marked
  /// unconfigured. Existing connections not present in [profiles] are kept by the native
  /// merge; callers that want a pure replace must stage deletions separately.
  Future<String?> restoreProfiles(
    List<ProviderProfile> profiles, {
    ModelSelection? defaultSelection,
  }) async {
    final restored = profiles
        .map((p) => p.copyWith(
              credentialConfigured: false,
              clearCredentialHost: true,
            ))
        .toList(growable: false);
    ModelSelection? restoredDefault;
    if (defaultSelection != null) {
      final owner = restored.where((p) => p.id == defaultSelection.profileId);
      if (owner.isNotEmpty) {
        final revision = owner.first.revision == 0 ? 1 : owner.first.revision;
        restoredDefault =
            defaultSelection.copyWith(profileRevision: revision);
      }
    }
    _draft = _draft.copyWith(
      profiles: restored,
      defaultSelection: restoredDefault,
      clearDefaultSelection: restoredDefault == null,
      deletions: const <String>{},
    );
    _notify();
    return save();
  }

  /// Drops every uncommitted change.
  void discard() {
    _draft = _baselineDraft();
    _lastError = null;
    _notify();
  }

  // ------------------------------------------------------------ validation

  /// Validates the draft (not just one field). Returns the first readable problem.
  ///
  /// The default selection is part of the contract with the native layer:
  ///   * with at least one profile, a default must exist and point at one of them —
  ///     deleting the default connection forces the user to pick another one explicitly
  ///     (never an automatic "pick some other provider" guess);
  ///   * with no profiles left, no default may remain (the native side rejects a
  ///     `defaultProfileId` that points nowhere).
  String? validateDraft() {
    final ids = <String>{};
    for (final p in _draft.profiles) {
      if (p.id.trim().isEmpty) return '连接 ID 不能为空';
      if (!ids.add(p.id)) return '连接 ID 重复：${p.id}';
      final error = p.firstError;
      if (error != null) {
        final name = p.name.trim().isEmpty ? p.id : p.name.trim();
        return '「$name」：$error';
      }
    }
    final selection = _draft.defaultSelection;
    if (_draft.profiles.isEmpty) {
      if (selection != null) {
        return '没有任何连接时不能保留默认连接，请重新选择默认连接';
      }
      return null;
    }
    if (selection == null) {
      return _draft.deletions.isNotEmpty
          ? '默认连接已被删除，请先选择一个默认连接再保存'
          : '请选择一个默认连接（新会话会使用它）';
    }
    final profile = _draftProfileById(selection.profileId);
    if (profile == null) return '默认连接已被删除，请重新选择默认连接';
    if (selection.profileRevision != profile.revision &&
        !_isPostSaveRevision(profile, selection)) {
      return '默认连接的配置已更新，请重新确认默认连接';
    }
    final invalid = selection.validate();
    if (invalid.isNotEmpty) return invalid.first;
    return null;
  }

  /// Send-time check for the selection that would be used by a request.
  ///
  /// Returns `null` when the selection is usable, otherwise a readable sentence for
  /// the composer. Before `load()` completes there is nothing to check against, so the
  /// native default is allowed (returns `null`).
  String? validateSelection(ModelSelection? selection) {
    if (!_loaded) return null;
    final chosen = selection ?? _defaultSelection;
    if (!_bridgeAvailable && _profiles.isEmpty) {
      return '无法读取模型设置（原生设置不可用），请重新启动程序后再试';
    }
    if (_profiles.isEmpty) {
      return '尚未配置模型连接，请到「设置 → 模型」添加一个连接';
    }
    if (chosen == null) {
      return '尚未选择默认模型，请到「设置 → 模型」设置默认连接';
    }
    final profile = profileById(chosen.profileId);
    if (profile == null) {
      return '模型连接「${chosen.profileId}」已被删除，请到「设置 → 模型」重新选择';
    }
    if (chosen.profileRevision != profile.revision) {
      return '模型连接「${profile.name}」的配置已更新（版本 ${profile.revision}），'
          '请在「设置 → 模型」重新确认';
    }
    if (chosen.modelId.trim().isEmpty) return '请为当前连接填写模型 ID';
    final invalid = chosen.validate();
    if (invalid.isNotEmpty) return invalid.first;
    return null;
  }

  /// The global default selection when it is currently usable, else `null`.
  ///
  /// "Usable" means: it exists, points at a saved profile whose revision still matches,
  /// has a model id and passes [ModelSelection.validate].
  ModelSelection? get usableDefaultSelection {
    final fallback = _defaultSelection;
    if (fallback == null) return null;
    final profile = profileById(fallback.profileId);
    if (profile == null || profile.revision != fallback.profileRevision) return null;
    if (fallback.modelId.trim().isEmpty) return null;
    if (fallback.validate().isNotEmpty) return null;
    return fallback;
  }

  /// Resolves the model selection a request for [conversation] must use.
  ///
  /// This is the *sending* path, so it never hides a broken explicit binding:
  ///   * a conversation with its own selection returns that exact selection, or a
  ///     readable error when the profile was deleted / its revision changed;
  ///   * a conversation without any selection (an old session) is migrated from the
  ///     global default and flagged [SelectionResolution.migrated] so the caller can
  ///     persist it once; when there is no usable default it fails instead of guessing.
  ///
  /// Passing `null` asks "what would a request send right now" and simply reports the
  /// default (still flagged as a migration source, since there is nothing to bind).
  SelectionResolution resolveSelectionForRequest(Conversation? conversation) {
    final own = conversation?.modelSelection;
    if (own != null) {
      final profile = profileById(own.profileId);
      if (profile == null) {
        return SelectionResolution.failure(
          '该会话使用的模型连接已删除，请在输入框上方重新选择模型（不会自动改用其它连接）',
        );
      }
      if (profile.revision != own.profileRevision) {
        return SelectionResolution.failure(
          '该会话使用的模型连接配置已更新（旧修订 ${own.profileRevision} → '
          '当前 ${profile.revision}），请重新选择模型',
        );
      }
      final invalid = own.validate();
      if (invalid.isNotEmpty) return SelectionResolution.failure(invalid.first);
      return SelectionResolution.ready(own);
    }
    final fallback = usableDefaultSelection;
    if (fallback != null) {
      return SelectionResolution.ready(fallback, migrated: true);
    }
    if (!_loaded) {
      return SelectionResolution.failure('模型设置尚未加载，请稍后再试');
    }
    if (_profiles.isEmpty) {
      if (!_bridgeAvailable) {
        return SelectionResolution.failure(
            '无法读取模型设置（原生设置不可用），请重新启动程序后再试');
      }
      return SelectionResolution.failure('尚未配置模型连接，请到「设置 → 模型」添加一个连接');
    }
    if (_defaultSelection == null) {
      return SelectionResolution.failure('该旧会话尚未绑定模型，请在输入框上方选择后再分析');
    }
    return SelectionResolution.failure(
        '默认模型连接不可用（可能已删除或配置已更新），请在输入框上方重新选择模型');
  }

  /// Display-only answer to "which model does this conversation use right now".
  ///
  /// Unlike [resolveSelectionForRequest], a broken explicit binding returns `null`
  /// instead of falling back to the global default: the UI must show "no usable model"
  /// rather than a different provider than the one the conversation was created with.
  /// A conversation without a binding still shows the (usable) global default.
  ModelSelection? currentSelectionFor(Conversation? conversation) {
    final own = conversation?.modelSelection;
    if (own != null) {
      final profile = profileById(own.profileId);
      if (profile == null || profile.revision != own.profileRevision) return null;
      return own;
    }
    return usableDefaultSelection;
  }

  // ------------------------------------------------------------------ load

  /// Loads preferences + native settings. Never throws: problems are reported through
  /// [loadWarning] / [lastError] and the defaults are used.
  Future<void> load() async {
    SettingsPreferencesLoad loadedPrefs;
    try {
      loadedPrefs = await store.load();
    } catch (e) {
      loadedPrefs = SettingsPreferencesLoad(
        prefs: const AppPreferences(),
        warning: '读取应用偏好失败：${_shortError(e)}',
        path: store.prefsPath,
      );
    }
    _prefs = loadedPrefs.prefs;
    _profiles = const <ProviderProfile>[];
    _defaultSelection = null;
    _settingsPath = loadedPrefs.path;
    _bridgeAvailable = false;
    _lastError = null;
    _lastProbe = null;
    final warnings = <String>[];
    final prefsWarning = loadedPrefs.warning;
    if (prefsWarning != null) warnings.add(prefsWarning);

    final bridge = _bridge;
    if (bridge != null) {
      try {
        final snapshot = SettingsSnapshot.fromNative(bridge.settingsGet());
        _profiles = snapshot.profiles;
        _defaultSelection = snapshot.defaultSelection;
        if (snapshot.settingsPath.isNotEmpty) {
          _settingsPath = snapshot.settingsPath;
        }
        _bridgeAvailable = true;
        final nativeWarning = snapshot.warning;
        if (nativeWarning != null) warnings.add(nativeWarning);
      } on NativeCallException catch (e) {
        warnings.add('无法读取模型设置：${SettingsErrorCatalog.describe(e)}');
      } catch (e) {
        warnings.add('无法读取模型设置：${_shortError(e)}');
      }
    }
    _loadWarning = warnings.isEmpty ? null : warnings.join('；');
    _draft = _baselineDraft();
    _loaded = true;
    _notify();
  }

  /// Records a startup/load problem coming from the outer bootstrap (e.g. the native
  /// bridge could not be opened at all). Never throws: the app must still start.
  void reportLoadFailure(String message) {
    final text = message.trim();
    if (text.isEmpty) return;
    _lastError = text;
    _loadWarning = text;
    _notify();
  }

  // ------------------------------------------------------------------ save
  /// Writes preferences, then the native settings document.
  ///
  /// Returns `null` on success or a readable error. On failure the committed values and
  /// the preferences file keep their previous content — or, when the rollback itself
  /// fails, the memory state follows what the file actually holds and the message says
  /// so. [draft] is always left untouched on failure so the user can fix and retry.
  Future<String?> save() async {
    if (_saving) return '正在保存，请稍候';

    final previousPrefs = _prefs;
    final prefsChanged = _draft.prefs != previousPrefs;
    // A staged deletion is a change even when the remaining profiles look identical.
    final profilesChanged = _draft.deletions.isNotEmpty ||
        !_sameProfiles(_draft.profiles, _profiles) ||
        _draft.defaultSelection != _defaultSelection;
    if (!prefsChanged && !profilesChanged) {
      // Nothing to write: still clear the draft so `dirty` reports the truth.
      _draft = _baselineDraft();
      return null;
    }

    // Without the native document there is no way to persist model changes. Report
    // that before field-level validation (no user edit can fix a missing DLL), and do
    // not touch the preferences file in that case.
    final bridge = _bridge;
    if (profilesChanged && (bridge == null || !_bridgeAvailable)) {
      _lastError = '原生设置不可用，模型连接未保存';
      _notify();
      return _lastError;
    }

    final invalid = validateDraft();
    if (invalid != null) return invalid;

    _saving = true;
    _lastError = null;
    _notify();
    try {
      if (prefsChanged) {
        try {
          await store.save(_draft.prefs);
        } catch (e) {
          _lastError = '保存应用偏好失败：${_shortError(e)}';
          return _lastError;
        }
      }

      if (!profilesChanged) {
        _prefs = _draft.prefs;
        _draft = _baselineDraft();
        return null;
      }

      try {
        final stored =
            SettingsSnapshot.fromNative(bridge!.settingsSave(_payload()));
        _profiles = stored.profiles;
        _defaultSelection = stored.defaultSelection;
        if (stored.settingsPath.isNotEmpty) _settingsPath = stored.settingsPath;
        _prefs = _draft.prefs;
        _lastError = null;
        _loadWarning = null;
        _draft = _baselineDraft();
        return null;
      } on NativeCallException catch (e) {
        return await _nativeSaveFailed(
          SettingsErrorCatalog.describe(e),
          previousPrefs: previousPrefs,
          prefsChanged: prefsChanged,
        );
      } catch (e) {
        return await _nativeSaveFailed(
          '保存模型设置失败：${_shortError(e)}',
          previousPrefs: previousPrefs,
          prefsChanged: prefsChanged,
        );
      }
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// The document handed to `ts_bridge_settings_save`.
  ///
  /// The native side merges *starting from the file on disk*, so a connection that is
  /// merely absent from `profiles` is kept: deletions must be listed explicitly in
  /// `deletedProfileIds`. That list is deduplicated, sorted and stripped of ids the draft
  /// still carries (a connection removed and re-added before saving is not a deletion).
  Map<String, dynamic> _payload() {
    final selection = _draft.defaultSelection;
    final owner =
        selection == null ? null : _draftProfileById(selection.profileId);
    final thinking = selection?.thinking ??
        owner?.effectiveThinking ??
        ThinkingMode.unsupported;
    final effort = thinking == ThinkingMode.enabled
        ? (ReasoningEffort.normalize(selection?.reasoningEffort) ??
            owner?.effectiveReasoningEffort)
        : null;
    final draftIds = _draft.profiles.map((p) => p.id).toSet();
    final deletions = _draft.deletions
        .where((id) => id.trim().isNotEmpty && !draftIds.contains(id))
        .toSet()
        .toList(growable: false)
      ..sort();
    return <String, dynamic>{
      'schemaVersion': SettingsSnapshot.profilesSchemaVersion,
      'defaultProfileId': selection?.profileId ?? '',
      'defaultModelId': selection?.modelId ?? '',
      'defaultThinking': thinking.wireName,
      'defaultReasoningEffort': effort,
      'profiles':
          _draft.profiles.map((p) => p.toJson()).toList(growable: false),
      if (deletions.isNotEmpty) 'deletedProfileIds': deletions,
    };
  }

  /// Handles a failed native save without swallowing a failed preferences rollback.
  ///
  /// * rollback ok: file and memory keep the old preferences, the connections stay old;
  /// * rollback failed: the file already holds the *new* preferences, so memory must
  ///   follow the file (otherwise the UI would lie until the next restart); the model
  ///   connections are still the old ones and the draft is kept for a retry.
  Future<String> _nativeSaveFailed(
    String reason, {
    required AppPreferences previousPrefs,
    required bool prefsChanged,
  }) async {
    if (!prefsChanged) {
      _lastError = '$reason；模型连接未保存';
      return _lastError!;
    }
    final rolledBack = await _rollbackPrefs(previousPrefs);
    if (rolledBack) {
      _lastError = '$reason；模型连接未保存，应用偏好已恢复原值';
    } else {
      _prefs = _draft.prefs;
      _lastError = '$reason；应用偏好已写入新值且回滚失败；模型连接仍是旧值；'
          '请重新保存设置以恢复一致';
    }
    return _lastError!;
  }

  /// Best-effort rollback of the preferences file. Returns `false` when the file could
  /// not be restored, which the caller must not hide.
  Future<bool> _rollbackPrefs(AppPreferences previous) async {
    try {
      await store.save(previous);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------ credential

  // Credential operations are immediate and final: the key is written to (or removed
  // from) the OS credential store right away, so they are NOT part of [draft] and are
  // not rolled back by the settings window's "取消/放弃". Cancelling the dialog never
  // restores an old key.
  //
  // The native layer binds a key to the *saved* profile's `chatUrl` host, so a key is
  // only accepted for a connection that exists on disk with no unsaved edits to its
  // endpoint/auth fields — otherwise the key would silently belong to a different host
  // than the UI shows.

  /// Stores an API key for [profileId]. Returns `null` on success.
  ///
  /// The key is passed straight to the native credential store: it is never logged,
  /// stored in memory, or echoed in the returned message. A "partial" native failure
  /// (key stored, `settings.json` not writable) returns a readable warning plus the
  /// refreshed authoritative state — it is neither a full success nor a full failure.
  Future<String?> setCredential(String profileId, String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return '请输入 API Key';
    final bridge = _bridge;
    if (bridge == null || !_bridgeAvailable) {
      return '原生设置不可用，无法保存 API Key';
    }
    final targetError = _credentialTargetError(profileId, action: '保存');
    if (targetError != null) return targetError;
    final savedHost = profileById(profileId)?.endpointHost;
    try {
      bridge.credentialSet(profileId, trimmed);
    } on NativeCallException catch (e) {
      final partial = _isPartialCredentialFailure(e);
      final data = e.data;
      await _refreshCredentialState(
        profileId,
        fallbackConfigured: partial
            ? (data?['credentialConfigured'] is bool
                ? data!['credentialConfigured'] as bool
                : true)
            : null,
        fallbackHost: partial
            ? ((data?['credentialHost'] as String?) ?? savedHost)
            : null,
      );
      final message = partial
          ? _partialCredentialWarning(deleted: false)
          : SettingsErrorCatalog.describe(e);
      _lastError = message;
      _notify();
      return message;
    } catch (e) {
      await _refreshCredentialState(profileId);
      _lastError = '保存 API Key 失败：${_shortError(e)}';
      _notify();
      return _lastError;
    }
    await _refreshCredentialState(profileId,
        fallbackConfigured: true, fallbackHost: savedHost);
    _lastError = null;
    _notify();
    return null;
  }

  /// Removes the stored API key for [profileId]. Returns `null` on success.
  Future<String?> deleteCredential(String profileId) async {
    final bridge = _bridge;
    if (bridge == null || !_bridgeAvailable) {
      return '原生设置不可用，无法删除 API Key';
    }
    final targetError = _credentialTargetError(profileId, action: '删除');
    if (targetError != null) return targetError;
    try {
      bridge.credentialDelete(profileId);
    } on NativeCallException catch (e) {
      final partial = _isPartialCredentialFailure(e);
      final data = e.data;
      await _refreshCredentialState(
        profileId,
        fallbackConfigured: partial
            ? (data?['credentialConfigured'] is bool
                ? data!['credentialConfigured'] as bool
                : false)
            : null,
        fallbackHost: partial ? (data?['credentialHost'] as String?) : null,
      );
      final message = partial
          ? _partialCredentialWarning(deleted: true)
          : SettingsErrorCatalog.describe(e);
      _lastError = message;
      _notify();
      return message;
    } catch (e) {
      await _refreshCredentialState(profileId);
      _lastError = '删除 API Key 失败：${_shortError(e)}';
      _notify();
      return _lastError;
    }
    await _refreshCredentialState(profileId, fallbackConfigured: false);
    _lastError = null;
    _notify();
    return null;
  }

  /// Rejects a credential operation whose target is not a saved connection.
  ///
  /// `action` is '保存' or '删除' and only shapes the message.
  String? _credentialTargetError(String profileId, {required String action}) {
    final committed = profileById(profileId);
    if (committed == null) {
      return _draftProfileById(profileId) != null
          ? '请先保存连接，再${action}API Key'
          : '该连接不存在，请刷新后重试';
    }
    final draft = _draftProfileById(profileId);
    if (draft != null && !_sameCredentialTarget(committed, draft)) {
      return '连接有未保存的修改，请先保存连接再${action}API Key';
    }
    return null;
  }

  /// Fields that decide which host/user a stored key belongs to. Cosmetic edits (name,
  /// model id, thinking) do not change the credential target.
  static bool _sameCredentialTarget(ProviderProfile a, ProviderProfile b) =>
      a.protocol == b.protocol &&
      a.chatUrl.trim() == b.chatUrl.trim() &&
      a.baseUrl.trim() == b.baseUrl.trim() &&
      a.authMode == b.authMode &&
      a.apiKeyEnv.trim() == b.apiKeyEnv.trim();

  /// Which endpoint a probe would really contact. Editing the model id or thinking
  /// level is fine (the probe request carries those), but changing chat/models URLs or
  /// the auth mode must be saved first or the UI would describe a different target than
  /// the native layer actually uses.
  static bool _sameProbeTarget(ProviderProfile committed, ProviderProfile draft) =>
      committed.protocol == draft.protocol &&
      committed.chatUrl.trim() == draft.chatUrl.trim() &&
      committed.modelsUrl.trim() == draft.modelsUrl.trim() &&
      committed.authMode == draft.authMode &&
      committed.apiKeyEnv.trim() == draft.apiKeyEnv.trim();

  static bool _isPartialCredentialFailure(NativeCallException e) =>
      e.data?['partial'] == true;

  static String _partialCredentialWarning({required bool deleted}) => deleted
      ? 'API Key 已删除，但设置文件写入失败；请重新保存设置以恢复一致'
      : 'API Key 已生效，但设置文件写入失败；请重新保存设置以恢复一致';

  /// Refreshes the credential flags after a native call.
  ///
  /// The native layer is authoritative, so [settingsGet] is preferred; when it is not
  /// available the caller's local knowledge is applied (and only then — a hard failure
  /// without a fallback must never flip flags to a guessed value).
  Future<void> _refreshCredentialState(
    String profileId, {
    bool? fallbackConfigured,
    String? fallbackHost,
  }) async {
    final bridge = _bridge;
    var synced = false;
    if (bridge != null && _bridgeAvailable) {
      try {
        final snapshot = SettingsSnapshot.fromNative(bridge.settingsGet());
        _profiles = snapshot.profiles;
        _defaultSelection = snapshot.defaultSelection;
        if (snapshot.settingsPath.isNotEmpty) _settingsPath = snapshot.settingsPath;
        synced = true;
      } catch (_) {
        // Native read failed: fall through to the optimistic local knowledge.
      }
    }
    if (!synced && fallbackConfigured == null) return;
    if (!synced) {
      _profiles = _profiles
          .map((p) => p.id == profileId
              ? p.copyWith(
                  credentialConfigured: fallbackConfigured,
                  credentialHost: fallbackHost,
                  clearCredentialHost: fallbackConfigured != true,
                )
              : p)
          .toList(growable: false);
    }
    final authoritative = profileById(profileId);
    final configured =
        authoritative?.credentialConfigured ?? fallbackConfigured ?? false;
    final host = configured ? (authoritative?.credentialHost ?? fallbackHost) : null;
    _updateDraftCredential(profileId, configured: configured, host: host);
  }

  /// Mirrors the credential flags into the draft so the settings form shows the same
  /// state as the committed list.
  void _updateDraftCredential(String id,
      {required bool configured, String? host}) {
    final next = _draft.profiles
        .map((p) => p.id == id
            ? p.copyWith(
                credentialConfigured: configured,
                credentialHost: host,
                clearCredentialHost: !configured,
              )
            : p)
        .toList(growable: false);
    _draft = _draft.copyWith(profiles: next);
  }

  // ---------------------------------------------------------------- probes

  /// Discovers the models exposed by the profile's `modelsUrl`.
  Future<ProbeOutcome> discoverModels(
    String profileId,
    int profileRevision, {
    String modelId = '',
    Duration? timeout,
  }) =>
      _runProbe(
        kind: 'models',
        profileId: profileId,
        profileRevision: profileRevision,
        modelId: modelId,
        timeout: timeout,
      );

  /// Sends one tiny chat request to verify connectivity / credentials.
  Future<ProbeOutcome> testModel(
    String profileId,
    int profileRevision, {
    String modelId = '',
    Duration? timeout,
  }) =>
      _runProbe(
        kind: 'chat',
        profileId: profileId,
        profileRevision: profileRevision,
        modelId: modelId,
        timeout: timeout,
      );

  /// Cancels the probe in flight. Its pending future completes with a `cancelled`
  /// outcome, and any result that arrives later is ignored.
  void cancelProbe() {
    _probeGeneration++;
    final job = _activeProbeJob;
    _activeProbeJob = null;
    _probing = false;
    final bridge = _bridge;
    if (job != null && bridge != null) _abandon(bridge, job);
    _notify();
  }

  int _probeGeneration = 0;
  int? _activeProbeJob;

  Future<ProbeOutcome> _runProbe({
    required String kind,
    required String profileId,
    required int profileRevision,
    required String modelId,
    Duration? timeout,
  }) async {
    final bridge = _bridge;
    if (bridge == null || !_bridgeAvailable) {
      return ProbeOutcome.failure(
        kind,
        'bridge',
        SettingsErrorCatalog.describeKind('bridge'),
      );
    }
    final profile = profileById(profileId);
    if (profile == null) {
      return ProbeOutcome.failure(
        kind,
        SettingsErrorCatalog.profileDeleted,
        '该连接尚未保存，请先保存连接再测试（测试只针对已保存的配置）',
      );
    }
    if (profileRevision != profile.revision) {
      return ProbeOutcome.failure(
        kind,
        SettingsErrorCatalog.revision,
        SettingsErrorCatalog.describeKind(SettingsErrorCatalog.revision),
      );
    }
    final draft = _draftProfileById(profileId);
    if (draft != null && !_sameProbeTarget(profile, draft)) {
      return ProbeOutcome.failure(
        kind,
        'config',
        '连接地址或认证方式有未保存的修改；请先保存连接，再测试实际请求目标',
      );
    }
    final effectiveModel = modelId.trim().isEmpty ? profile.modelId.trim() : modelId.trim();
    if (effectiveModel.isEmpty) {
      return ProbeOutcome.failure(kind, 'config', '请先填写模型 ID');
    }
    final thinking = profile.effectiveThinking;
    final request = <String, dynamic>{
      'kind': kind,
      'profileId': profile.id,
      'profileRevision': profile.revision,
      'modelId': effectiveModel,
      'thinking': thinking.wireName,
      'reasoningEffort':
          thinking == ThinkingMode.enabled ? profile.effectiveReasoningEffort : null,
      if (timeout != null) 'timeoutMs': _clampProbeTimeout(timeout),
    };

    final previous = _activeProbeJob;
    final generation = ++_probeGeneration;
    _probing = true;
    _notify();
    int job;
    try {
      job = bridge.probeAsync(request);
    } on NativeCallException catch (e) {
      _probing = false;
      _notify();
      return ProbeOutcome.failure(kind, e.kind, SettingsErrorCatalog.describe(e));
    }
    _activeProbeJob = job;
    if (previous != null) _abandon(bridge, previous);

    final budget = timeout ?? probeTimeout;
    final deadline = DateTime.now().add(budget);
    ProbeOutcome? outcome;
    try {
      outcome = await _pollProbe(bridge, job, kind, generation, deadline);
    } finally {
      if (_activeProbeJob == job) _activeProbeJob = null;
      _probing = false;
    }
    _notify();
    return outcome;
  }

  Future<ProbeOutcome> _pollProbe(
    SettingsBridge bridge,
    int job,
    String kind,
    int generation,
    DateTime deadline,
  ) async {
    while (true) {
      if (generation != _probeGeneration) {
        _abandon(bridge, job);
        return ProbeOutcome.failure(
          kind,
          SettingsErrorCatalog.cancelled,
          SettingsErrorCatalog.describeKind(SettingsErrorCatalog.cancelled),
        );
      }
      BridgePollResult polled;
      try {
        polled = bridge.poll(job);
      } on NativeCallException catch (e) {
        if (generation != _probeGeneration) {
          return ProbeOutcome.failure(
            kind,
            SettingsErrorCatalog.cancelled,
            SettingsErrorCatalog.describeKind(SettingsErrorCatalog.cancelled),
          );
        }
        return ProbeOutcome.failure(kind, e.kind, SettingsErrorCatalog.describe(e));
      }
      if (polled.terminal) {
        ProbeOutcome? result;
        try {
          result = bridge.probeResult(job);
        } on NativeCallException catch (e) {
          return ProbeOutcome.failure(kind, e.kind, SettingsErrorCatalog.describe(e));
        } finally {
          bridge.release(job);
        }
        if (generation != _probeGeneration) {
          // A newer probe (or an explicit cancel) owns the UI now: discard silently.
          return ProbeOutcome.failure(
            kind,
            SettingsErrorCatalog.cancelled,
            SettingsErrorCatalog.describeKind(SettingsErrorCatalog.cancelled),
          );
        }
        final outcome = result ??
            ProbeOutcome.failure(kind, 'unknown', '没有拿到探测结果，请重试');
        _lastProbe = outcome;
        return outcome;
      }
      if (DateTime.now().isAfter(deadline)) {
        _abandon(bridge, job);
        return ProbeOutcome.failure(
          kind,
          SettingsErrorCatalog.timeout,
          SettingsErrorCatalog.describeKind(SettingsErrorCatalog.timeout),
        );
      }
      await Future<void>.delayed(probePollInterval);
    }
  }

  void _abandon(SettingsBridge bridge, int job) {
    try {
      bridge.cancel(job);
    } catch (_) {
      // Already finished/cancelled; nothing to do.
    }
    try {
      bridge.release(job);
    } catch (_) {
      // The native layer refuses to release a running job; poll will collect it.
    }
  }

  /// Native probe timeouts are limited to [3000, 120000] ms by the bridge.
  static int _clampProbeTimeout(Duration timeout) {
    final ms = timeout.inMilliseconds;
    if (ms < 3000) return 3000;
    if (ms > 120000) return 120000;
    return ms;
  }

  // ------------------------------------------------------------- internals

  ProviderProfile? _draftProfileById(String id) {
    for (final p in _draft.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  static bool _sameProfiles(
    List<ProviderProfile> a,
    List<ProviderProfile> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final job = _activeProbeJob;
    _activeProbeJob = null;
    final bridge = _bridge;
    if (job != null && bridge != null) _abandon(bridge, job);
    super.dispose();
  }
}

