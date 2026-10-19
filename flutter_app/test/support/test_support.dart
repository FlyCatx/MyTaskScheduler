// Shared test fixtures: a fake schedule engine and sample JSON.
//
// Widget/unit tests must never need the real DLL or a network. The fake engine
// returns a display snapshot shaped exactly like the one the C core produces
// (see src/display.c), so the UI code under test sees realistic data.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/schedule_engine.dart';
import 'package:taskscheduler_flutter/src/state/session_repository.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

export 'package:taskscheduler_flutter/src/state/memory_session_repository.dart';

/// A settings controller with default preferences and no native bridge.
///
/// No file is written: [SettingsStore] only touches disk on save, which widget tests
/// never do. Production always passes a loaded controller from the bootstrap.
SettingsController makeTestSettingsController() => SettingsController(
      store: SettingsStore(Directory.systemTemp),
      bridge: null,
    );

class FakeScheduleEngine implements ScheduleEngine {
  int computeCalls = 0;
  ScheduleException? failWith;
  DisplaySnapshot? lastPlanResult;

  @override
  BridgeInfo get info => const BridgeInfo(
        model: 'fake-model',
        endpoint: 'http://localhost/fake',
        configPath: '',
        mockMode: true,
        hasApiKey: false,
        requiresAuth: false,
        httpAvailable: true,
        waitPromptMs: 120000,
        maxInputBytes: 262144,
      );

  @override
  DisplaySnapshot compute(LocalPlan plan) {
    computeCalls++;
    final failure = failWith;
    if (failure != null) throw failure;
    final snapshot = buildSnapshotFor(plan);
    lastPlanResult = snapshot;
    return snapshot;
  }

  /// Rebuilds a display snapshot from a local plan, mimicking the C rules that
  /// matter for the UI: statuses, order, relative timeline with unknown hours.
  static DisplaySnapshot buildSnapshotFor(LocalPlan plan) {
    final ids = plan.tasks.map((t) => t.id).toList();
    final done = plan.tasks.where((t) => t.isDone).map((t) => t.id).toSet();

    // Simple topological order using dependsOn.
    final order = <String>[];
    final remaining = {...ids};
    var progress = true;
    while (remaining.isNotEmpty && progress) {
      progress = false;
      for (final t in plan.tasks) {
        if (!remaining.contains(t.id)) continue;
        if (t.dependsOn.every((d) => !remaining.contains(d) || done.contains(d))) {
          order.add(t.id);
          remaining.remove(t.id);
          progress = true;
          break;
        }
      }
    }
    order.addAll(remaining);

    /// Longest dependency path from a root: what the C display layer calls `level`.
    /// Guards against cycles so a malformed plan cannot hang a test.
    final depthCache = <String, int>{};
    int depthOf(String id, [Set<String>? stack]) {
      final cached = depthCache[id];
      if (cached != null) return cached;
      final task = plan.taskById(id);
      if (task == null || task.dependsOn.isEmpty) {
        depthCache[id] = 0;
        return 0;
      }
      final visiting = stack ?? <String>{};
      if (!visiting.add(id)) return 0; // cycle: stop
      var maxDepth = 0;
      for (final dep in task.dependsOn) {
        maxDepth = math.max(maxDepth, depthOf(dep, visiting) + 1);
      }
      visiting.remove(id);
      depthCache[id] = maxDepth;
      return maxDepth;
    }

    double cursor = 0;
    var cursorKnown = true;
    final startHours = <String, double>{};
    final endHours = <String, double>{};

    for (final id in order) {
      final t = plan.taskById(id)!;
      if (t.isDone) continue;
      final blocked = t.preconditions.any((p) => p.status != 'met');
      if (blocked) continue;
      if (!t.hoursKnown) {
        cursorKnown = false;
        continue;
      }
      if (!cursorKnown) continue;
      startHours[id] = cursor;
      endHours[id] = cursor + t.estimatedHours!;
      cursor = endHours[id]!;
    }

    final tasks = plan.tasks.map((t) {
      final blocked = t.preconditions.any((p) => p.status == 'unmet');
      final pending = t.preconditions.any((p) => p.status == 'unknown');
      final status = t.isDone
          ? 'done'
          : (blocked ? 'blocked' : (pending ? 'pending' : 'ready'));
      final scheduleState = t.isDone
          ? ScheduleState.completed
          : (blocked ? ScheduleState.blocked : (pending ? ScheduleState.pending : (endHours.containsKey(t.id) ? ScheduleState.scheduled : ScheduleState.unknownHours)));
      final preds = t.dependsOn
          .map((d) => RelatedTask(id: d, name: plan.taskById(d)?.name ?? d))
          .toList(growable: false);
      return DisplayTask(
        id: t.id,
        name: t.name,
        status: status,
        statusText: const {
          'done': '已完成',
          'blocked': '受阻',
          'pending': '待确认',
        }[status] ?? '可开始',
        // Real dependency depth (longest path from a root), matching what the C
        // display layer produces. A flat "0 or 1" value would hide layout bugs.
        level: depthOf(t.id),
        estimateKnown: t.hoursKnown,
        estimateHours: t.estimatedHours,
        deadline: t.deadline,
        steps: t.steps,
        sources: t.sourceRefs,
        reasons: [
          '现在可以做：前置任务都已完成。',
          if (t.urgencyReason != null) '安排依据：${t.urgencyReason}',
        ],
        conditions: t.preconditions
            .map((p) => TaskCondition(text: p.description, status: p.status))
            .toList(),
        predecessors: preds,
        unlocks: const [],
        stillWaiting: const [],
        scheduleState: scheduleState,
        startHours: startHours[t.id],
        endHours: endHours[t.id],
        scheduleNote: endHours.containsKey(t.id) ? null : '预计工时待确认',
      );
    }).toList();

    return DisplaySnapshot(
      summary: plan.summary,
      sortedAt: '2026-10-17 10:00:00',
      tasks: tasks,
      order: order,
      blocked: tasks.where((t) => t.status == 'blocked').map((t) => t.id).toList(),
      pending: tasks.where((t) => t.status == 'pending').map((t) => t.id).toList(),
      notes: plan.notes
          .map((n) => NoteView(
                kind: n.kind,
                text: n.text,
                tasks: n.taskIds
                    .map((id) => RelatedTask(
                        id: id, name: plan.taskById(id)?.name ?? id))
                    .toList(growable: false),
              ))
          .toList(growable: false),
      counts: DisplayCounts(
        total: tasks.length,
        done: tasks.where((t) => t.status == 'done').length,
        blocked: tasks.where((t) => t.status == 'blocked').length,
        pending: tasks.where((t) => t.status == 'pending').length,
        unknownHours: tasks
            .where((t) => !t.estimateKnown && t.status != 'done')
            .length,
      ),
    );
  }
}

/// A minimal but realistic local plan: two dependent tasks plus a finished one.
LocalPlan samplePlan({Completion first = Completion.todo}) => LocalPlan(
      summary: '完成顺序表实验',
      tasks: [
        TaskRecord(
          id: 'task-a',
          name: '整理实验要求',
          estimatedHours: 0.5,
          urgency: 4,
          impact: 4,
          urgencyReason: '后续实现要先明确接口',
          steps: const ['读说明', '整理接口'],
          sourceRefs: const ['文件1:段落1'],
          executionSignature: 'sig-a',
          completion: first,
        ),
        const TaskRecord(
          id: 'task-b',
          name: '实现 ListInit',
          dependsOn: ['task-a'],
          estimatedHours: 2,
          urgency: 3,
          impact: 4,
          executionSignature: 'sig-b',
        ),
        const TaskRecord(
          id: 'task-c',
          name: '阅读实验材料',
          estimatedHours: 0.5,
          executionSignature: 'sig-c',
          completion: Completion.done,
        ),
        // Deliberately no estimate: the UI must never turn this into "0 小时".
        const TaskRecord(
          id: 'task-d',
          name: '实现 ListInsert',
          dependsOn: ['task-b'],
          executionSignature: 'sig-d',
        ),
      ],
      notes: const [
        PlanNote(kind: 'question', text: 'ElemType 具体是什么类型？', taskIds: ['task-b']),
        PlanNote(kind: 'assumption', text: '假定使用 C11 实现'),
      ],
    );

/// Writes a conversation + index into [store] so `initialize()` can load it.
Future<void> seedConversation(
  SessionRepository store, {
  String conversationId = 'conv-seed',
  String title = '顺序表实验',
  LocalPlan? plan,
  List<Attachment> attachments = const [],
  String chartMode = 'tree',
}) async {
  final localPlan = plan ?? samplePlan();
  final version = PlanVersion(
    id: 'ver-1',
    conversationId: conversationId,
    revision: 0,
    createdAt: DateTime(2026, 10, 17, 9),
    summary: localPlan.summary,
    tasks: localPlan.tasks,
    notes: localPlan.notes,
  );
  final conversation = Conversation(
    id: conversationId,
    title: title,
    createdAt: DateTime(2026, 10, 17, 9),
    updatedAt: DateTime(2026, 10, 17, 9),
    versions: [version],
    currentVersionId: version.id,
    attachments: attachments,
    chartMode: chartMode,
  );
  await store.ensureLayout();
  await store.saveConversation(conversation);
  await store.saveIndex([ConversationSummary.of(conversation)]);
}

/// Creates an isolated, writable data directory for one test.
///
/// Deliberately NOT under `Directory.systemTemp`: on locked-down Windows setups the
/// real %TEMP% may be non-writable even for the current user, so tests use a folder
/// inside the package instead.
Directory createTempDataDir(String name) {
  final base = '${Directory.current.path}${Platform.pathSeparator}test_tmp';
  final dir = Directory(
      '$base${Platform.pathSeparator}${name}_${DateTime.now().microsecondsSinceEpoch}');
  dir.createSync(recursive: true);
  return dir;
}

/// A realistic saved connection used by the settings/backup tests.
ProviderProfile sampleProfile({
  String id = 'deepseek-official',
  String name = 'DeepSeek 官方',
  int revision = 1,
  String modelId = 'deepseek-chat',
  ProviderProtocol protocol = ProviderProtocol.deepseekChat,
}) =>
    ProviderProfile(
      id: id,
      name: name,
      revision: revision,
      protocol: protocol,
      baseUrl: 'https://api.example.test',
      chatUrl: 'https://api.example.test/chat/completions',
      modelsUrl: 'https://api.example.test/models',
      authMode: AuthMode.bearer,
      modelId: modelId,
      thinking: protocol == ProviderProtocol.deepseekChat
          ? ThinkingMode.enabled
          : ThinkingMode.unsupported,
      reasoningEffort:
          protocol == ProviderProtocol.deepseekChat ? ReasoningEffort.high : null,
      jsonMode: true,
      credentialConfigured: true,
      credentialHost: 'api.example.test',
    );

ModelSelection sampleSelection({
  String profileId = 'deepseek-official',
  int profileRevision = 1,
  String modelId = 'deepseek-chat',
  ThinkingMode thinking = ThinkingMode.enabled,
  String? reasoningEffort = ReasoningEffort.high,
}) =>
    ModelSelection(
      profileId: profileId,
      profileRevision: profileRevision,
      modelId: modelId,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
    );

/// The native settings document shape (`ts_bridge_settings_get`).
Map<String, dynamic> emptySettingsDocument() => <String, dynamic>{
      'ok': true,
      'abiVersion': 2,
      'schemaVersion': 2,
      'settingsPath': r'C:\data\settings.json',
      'defaultProfileId': '',
      'defaultModelId': '',
      'defaultThinking': 'unsupported',
      'defaultReasoningEffort': null,
      'profiles': <dynamic>[],
    };

/// A settings document holding one saved profile + its default selection.
Map<String, dynamic> settingsDocument({
  List<ProviderProfile>? profiles,
  String? defaultProfileId,
  String? defaultModelId,
}) {
  final list = profiles ?? <ProviderProfile>[sampleProfile()];
  final defaultId = defaultProfileId ??
      (list.isEmpty ? '' : list.first.id);
  final owner = list.where((p) => p.id == defaultId);
  final defaultModel = defaultModelId ??
      (owner.isEmpty ? '' : owner.first.modelId);
  return <String, dynamic>{
    'ok': true,
    'abiVersion': 2,
    'schemaVersion': 2,
    'settingsPath': r'C:\data\settings.json',
    'defaultProfileId': defaultId,
    'defaultModelId': defaultModel,
    'defaultThinking': 'enabled',
    'defaultReasoningEffort': 'high',
    'profiles': list.map((p) => p.toJson()).toList(growable: false),
  };
}

/// In-memory [SettingsBridge] so the controller tests never need the real DLL.
///
/// [FakeSettingsBridge._applySave] mirrors the real `ts_settings_merge()`
/// (`src/profile_store.c`) closely enough to catch controller bugs:
///   * the stored document is the **baseline** — a profile merely omitted from
///     `profiles` is kept, only `deletedProfileIds` removes one;
///   * deletions are applied before additions/modifications; deleting and modifying the
///     same id in one request is an `invalidRequest`;
///   * a new id must arrive with revision 0 and is stored as 1; an existing id must send
///     the exact stored revision (else `conflict`) and only bumps when an editable field
///     actually changed; missing revisions are refused, never guessed;
///   * `credentialConfigured` / `credentialHost` always come from the stored profile
///     (a new profile is stored as not configured);
///   * the defaults come from the request and must point at an existing profile.
///
/// It also supports failure injection for credential operations, including the native
/// "partial" shape (key active, `settings.json` write failed).
class FakeSettingsBridge implements SettingsBridge {
  FakeSettingsBridge({Map<String, dynamic>? settings})
      : _settings = settings ?? settingsDocument();

  Map<String, dynamic> _settings;

  /// Overrides the document returned by the next successful save.
  Map<String, dynamic>? saveResponse;

  NativeCallException? saveFailure;
  NativeCallException? getFailure;
  NativeCallException? probeStartFailure;

  /// Thrown before any state change by the corresponding credential call.
  NativeCallException? credentialSetFailure;
  NativeCallException? credentialDeleteFailure;

  /// When true a credential call still updates the stored document (the OS credential
  /// store did change) and then throws the native "partial" failure: the key is active
  /// but `settings.json` could not be persisted.
  bool credentialPersistFails = false;

  /// Number of polls answered with `terminal: false` before the terminal one.
  int nonTerminalPolls = 0;

  /// Probe answer; defaults to two discovered models.
  ProbeOutcome? probeOutcome;

  final List<Map<String, dynamic>> savedPayloads = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> probeRequests = <Map<String, dynamic>>[];
  final List<int> cancelledJobs = <int>[];
  final List<int> releasedJobs = <int>[];
  final List<String> credentialCalls = <String>[];
  final List<String> credentialDeletes = <String>[];

  Map<String, dynamic> get document => _settings;

  int _jobSeq = 0;
  final Map<int, int> _polls = <int, int>{};
  final Set<int> _terminal = <int>{};

  @override
  Map<String, dynamic> settingsGet() {
    final failure = getFailure;
    if (failure != null) throw failure;
    return Map<String, dynamic>.from(_settings);
  }

  @override
  Map<String, dynamic> settingsSave(Map<String, dynamic> settings) {
    savedPayloads.add(Map<String, dynamic>.from(settings));
    final failure = saveFailure;
    if (failure != null) throw failure;
    final result = saveResponse ?? _applySave(settings);
    if (result['ok'] == false) {
      throw NativeCallException(
        (result['errorKind'] as String?) ?? 'unknown',
        (result['error'] as String?) ?? '保存失败',
        data: result,
      );
    }
    _settings = Map<String, dynamic>.from(result);
    return _settings;
  }

  Map<String, dynamic> _applySave(Map<String, dynamic> payload) {
    // 1) The file on disk is the baseline: untouched connections survive.
    final working = <String, Map<String, dynamic>>{};
    for (final raw in (_settings['profiles'] as List<dynamic>? ?? const [])) {
      if (raw is Map<String, dynamic>) {
        final id = (raw['id'] as String?) ?? '';
        if (id.isNotEmpty) working[id] = Map<String, dynamic>.from(raw);
      }
    }

    // 2) Explicit deletions first (idempotent, like the native merge).
    final deleted = <String>{};
    for (final raw
        in (payload['deletedProfileIds'] as List<dynamic>? ?? const [])) {
      if (raw is! String) {
        throw NativeCallException('invalidRequest', 'deletedProfileIds 里必须是字符串');
      }
      deleted.add(raw);
      working.remove(raw);
    }

    // 3) Additions / modifications with the native revision rules.
    for (final raw in (payload['profiles'] as List<dynamic>? ?? const [])) {
      if (raw is! Map<String, dynamic>) {
        throw NativeCallException('validation', 'profile 必须是 JSON 对象');
      }
      final next = Map<String, dynamic>.from(raw);
      final id = (next['id'] as String?) ?? '';
      if (id.isEmpty) {
        throw NativeCallException('validation', 'profile 缺少 id');
      }
      if (deleted.contains(id)) {
        throw NativeCallException(
            'invalidRequest', '同一个请求里既删除又修改了某个连接；请刷新后重试');
      }
      final expected =
          next['revision'] is num ? (next['revision'] as num).toInt() : null;
      final old = working[id];
      if (old == null) {
        if (expected != null && expected != 0) {
          throw NativeCallException(
            'invalidRevision',
            '连接 $id 在磁盘上不存在，但请求里带了 revision=$expected；'
                '新建连接必须用 revision=0，请刷新后重试',
          );
        }
        next['revision'] = 1;
        next['credentialConfigured'] = false;
        next['credentialHost'] = null;
      } else {
        final oldRevision = (old['revision'] as num?)?.toInt() ?? 0;
        if (expected == null) {
          throw NativeCallException(
            'invalidRevision',
            '连接 $id 的请求缺少 revision，无法确认配置版本；请刷新设置后重试',
          );
        }
        if (expected != oldRevision) {
          throw NativeCallException(
            'conflict',
            '模型配置已被修改，请刷新后重试'
                '（连接 $id：磁盘 revision=$oldRevision，请求 revision=$expected）',
          );
        }
        next['revision'] =
            _sameEditable(old, next) ? oldRevision : oldRevision + 1;
        // Credential metadata belongs to the credential subsystem, not to a save.
        next['credentialConfigured'] = old['credentialConfigured'] ?? false;
        next['credentialHost'] = old['credentialHost'];
      }
      working[id] = next;
    }

    // 4) Defaults come from the request and must be internally consistent.
    final defaultProfileId = (payload['defaultProfileId'] as String?) ?? '';
    final defaultModelId = (payload['defaultModelId'] as String?) ?? '';
    final stored = working.values.toList(growable: false);
    if (stored.isEmpty) {
      if (defaultProfileId.trim().isNotEmpty) {
        throw NativeCallException(
            'validation', '没有任何连接时 defaultProfileId 必须为空（当前指向不存在的连接）');
      }
    } else {
      if (defaultProfileId.trim().isEmpty) {
        throw NativeCallException(
            'validation', 'defaultProfileId 不能为空（必须指向一个存在的连接）');
      }
      if (!working.containsKey(defaultProfileId)) {
        throw NativeCallException(
            'validation', 'defaultProfileId 指向不存在的连接：$defaultProfileId');
      }
      if (defaultModelId.trim().isEmpty) {
        throw NativeCallException('validation', 'defaultModelId 不能为空');
      }
    }

    return <String, dynamic>{
      ..._settings,
      'ok': true,
      'profiles': stored,
      'defaultProfileId': defaultProfileId,
      'defaultModelId': defaultModelId,
      'defaultThinking': payload['defaultThinking'],
      'defaultReasoningEffort': payload['defaultReasoningEffort'],
    };
  }

  @override
  void credentialSet(String profileId, String key) {
    credentialCalls.add(profileId);
    final failure = credentialSetFailure;
    if (failure != null) throw failure;
    final profile = _profileInDocument(profileId);
    if (profile == null) {
      throw NativeCallException('profileNotFound', '该模型连接不存在或已被删除');
    }
    profile['credentialConfigured'] = true;
    profile['credentialHost'] = _hostOf(profile);
    if (credentialPersistFails) {
      throw _partialCredentialFailure(
        configured: true,
        host: profile['credentialHost'] as String?,
        message: 'API Key 已写入 Windows 凭据管理器，但 settings.json 写入失败；请重新保存设置',
      );
    }
  }

  @override
  void credentialDelete(String profileId) {
    credentialDeletes.add(profileId);
    final failure = credentialDeleteFailure;
    if (failure != null) throw failure;
    final profile = _profileInDocument(profileId);
    if (profile == null) {
      throw NativeCallException('profileNotFound', '该模型连接不存在或已被删除');
    }
    profile['credentialConfigured'] = false;
    profile['credentialHost'] = null;
    if (credentialPersistFails) {
      throw _partialCredentialFailure(
        configured: false,
        host: null,
        message: 'API Key 已删除，但 settings.json 写入失败；请重新保存设置',
      );
    }
  }

  NativeCallException _partialCredentialFailure({
    required bool configured,
    String? host,
    required String message,
  }) =>
      NativeCallException('writeFailed', message, data: <String, dynamic>{
        'ok': false,
        'errorKind': 'writeFailed',
        'error': message,
        // The native layer reports "the key already took effect".
        'partial': true,
        'credentialConfigured': configured,
        'credentialHost': host,
      });

  Map<String, dynamic>? _profileInDocument(String id) {
    for (final raw in (_settings['profiles'] as List<dynamic>? ?? const [])) {
      if (raw is Map<String, dynamic> && raw['id'] == id) return raw;
    }
    return null;
  }

  static String _hostOf(Map<String, dynamic> profile) {
    final chatUrl = (profile['chatUrl'] as String?) ?? '';
    final host = Uri.tryParse(chatUrl)?.host ?? '';
    if (host.isNotEmpty) return host;
    return Uri.tryParse((profile['baseUrl'] as String?) ?? '')?.host ?? '';
  }

  @override
  int probeAsync(Map<String, dynamic> request) {
    probeRequests.add(Map<String, dynamic>.from(request));
    final failure = probeStartFailure;
    if (failure != null) throw failure;
    final job = ++_jobSeq;
    _polls[job] = 0;
    return job;
  }

  @override
  BridgePollResult poll(int job) {
    final count = _polls[job];
    if (count == null) {
      throw NativeCallException('result', '任务不存在或已释放');
    }
    _polls[job] = count + 1;
    if (count >= nonTerminalPolls) {
      _terminal.add(job);
      return const BridgePollResult(true, <BridgeEvent>[]);
    }
    return const BridgePollResult(false, <BridgeEvent>[]);
  }

  @override
  ProbeOutcome? probeResult(int job) {
    if (!_terminal.contains(job)) return null;
    return probeOutcome ??
        const ProbeOutcome(
          ok: true,
          kind: 'models',
          httpStatus: 200,
          elapsedMs: 12,
          models: <String>['model-a', 'model-b'],
        );
  }

  @override
  bool cancel(int job) {
    cancelledJobs.add(job);
    return true;
  }

  @override
  void release(int job) {
    releasedJobs.add(job);
    _polls.remove(job);
    _terminal.remove(job);
  }

  /// Fields the native `same_editable()` compares (revision and credential metadata are
  /// deliberately excluded; `NULL`/`""` mean the same thing).
  static const List<String> _editableTextFields = <String>[
    'id',
    'name',
    'baseUrl',
    'chatUrl',
    'modelsUrl',
    'authMode',
    'apiKeyEnv',
    'modelId',
    'reasoningEffort',
  ];

  static bool _sameEditable(Map<String, dynamic> a, Map<String, dynamic> b) {
    for (final key in _editableTextFields) {
      if (_optionalText(a[key]) != _optionalText(b[key])) return false;
    }
    final aProtocol = _optionalText(a['protocol']) ?? 'legacy';
    final bProtocol = _optionalText(b['protocol']) ?? 'legacy';
    if (aProtocol != bProtocol) return false;
    final aDefaultThinking =
        aProtocol == 'openai-chat' ? 'unsupported' : 'disabled';
    final bDefaultThinking =
        bProtocol == 'openai-chat' ? 'unsupported' : 'disabled';
    if ((_optionalText(a['thinking']) ?? aDefaultThinking) !=
        (_optionalText(b['thinking']) ?? bDefaultThinking)) {
      return false;
    }
    final aJson = a['jsonMode'] is bool ? a['jsonMode'] as bool : false;
    final bJson = b['jsonMode'] is bool ? b['jsonMode'] as bool : false;
    return aJson == bJson;
  }

  static String? _optionalText(Object? value) {
    if (value == null) return null;
    final text = value is String ? value.trim() : value.toString();
    return text.isEmpty ? null : text;
  }
}

/// Reads a display snapshot fixture as a raw map (for fromJson tests).
Map<String, dynamic> displayFixtureMap() => jsonDecode(displayFixtureJson)
    as Map<String, dynamic>;

const String displayFixtureJson = '''
{
  "ok": true,
  "formatVersion": "1",
  "summary": "完成顺序表实验",
  "sortedAt": "2026-10-17 10:00:00",
  "unresolvableReason": null,
  "tasks": [
    {
      "id": "task-a", "name": "整理实验要求", "status": "ready", "statusText": "可开始",
      "level": 0, "affected": false, "estimateKnown": true, "estimateHours": 0.5,
      "deadline": null, "estimateReason": "读一份短说明",
      "steps": ["读说明"], "sources": ["文件1:段落1"],
      "conditions": [],
      "predecessors": [], "unlocks": [], "stillWaiting": [],
      "reasons": ["没有前置任务，现在就可以开始。", "安排依据：后续实现要先明确接口。"],
      "scheduleState": "scheduled", "startHours": 0, "endHours": 0.5, "scheduleNote": null
    },
    {
      "id": "task-b", "name": "实现 ListInit", "status": "waiting", "statusText": "待前置",
      "level": 1, "affected": false, "estimateKnown": true, "estimateHours": 2,
      "deadline": null, "estimateReason": null,
      "steps": [], "sources": [],
      "conditions": [],
      "predecessors": [{"id": "task-a", "name": "整理实验要求"}],
      "unlocks": [], "stillWaiting": [],
      "reasons": ["需要等这些前置任务完成后才能开始：整理实验要求"],
      "scheduleState": "scheduled", "startHours": 0.5, "endHours": 2.5, "scheduleNote": null
    },
    {
      "id": "task-h", "name": "实现 ListInsert", "status": "ready", "statusText": "可开始",
      "level": 1, "affected": false, "estimateKnown": false, "estimateHours": null,
      "deadline": null, "estimateReason": null,
      "steps": [], "sources": [], "conditions": [],
      "predecessors": [], "unlocks": [], "stillWaiting": [],
      "reasons": ["预计工时未知，时间轴上不给确定起止时间。"],
      "scheduleState": "unknownHours", "startHours": null, "endHours": null,
      "scheduleNote": "预计工时待确认"
    },
    {
      "id": "task-d", "name": "编写测试", "status": "ready", "statusText": "可开始",
      "level": 2, "affected": false, "estimateKnown": true, "estimateHours": 0.5,
      "deadline": null, "estimateReason": null,
      "steps": [], "sources": [], "conditions": [],
      "predecessors": [{"id": "task-h", "name": "实现 ListInsert"}],
      "unlocks": [], "stillWaiting": [],
      "reasons": ["前序任务工时未知，起始时间待定。"],
      "scheduleState": "unscheduled", "startHours": null, "endHours": null,
      "scheduleNote": "前序任务工时未知，起始时间待定"
    },
    {
      "id": "task-done", "name": "阅读实验材料", "status": "done", "statusText": "已完成",
      "level": 0, "affected": false, "estimateKnown": true, "estimateHours": 0.5,
      "deadline": null, "estimateReason": null,
      "steps": [], "sources": [], "conditions": [],
      "predecessors": [], "unlocks": [], "stillWaiting": [],
      "reasons": ["你已标记为完成；它不再占用剩余时间。"],
      "scheduleState": "completed", "startHours": null, "endHours": null,
      "scheduleNote": "已完成"
    }
  ],
  "order": ["task-a", "task-b"],
  "blocked": [],
  "pending": [],
  "affected": [],
  "notes": [
    {"kind": "question", "text": "ElemType 具体是什么类型？",
     "tasks": [{"id": "task-b", "name": "实现 ListInit"}]},
    {"kind": "assumption", "text": "假定使用 C11 实现", "tasks": []}
  ],
  "counts": {"total": 5, "ready": 2, "waiting": 1, "blocked": 0, "pending": 0,
             "done": 1, "unknownHours": 1}
}
''';

