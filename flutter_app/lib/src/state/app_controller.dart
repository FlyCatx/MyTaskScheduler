// AppController — orchestration: conversations, versions, analysis lifecycle.
//
// Invariants enforced here (and covered by tests):
//   * a draft can always be edited; the plan cannot be edited while this
//     conversation has an analysis in flight (so the base revision cannot move
//     underneath the request);
//   * a failed / cancelled analysis never clears the old plan and never rewrites
//     the old title;
//   * a late result is verified against the request ticket before committing;
//   * while waiting, the UI shows only "正在思考 · 用时" + stop — never model
//     reasoning text, never a fake percentage.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ffi/native_gateway.dart';
import '../model/calendar.dart';
import '../model/calendar_proposals.dart';
import '../model/display.dart';
import '../model/plan.dart';
import '../model/session.dart';
import '../model/settings.dart';
import 'calendar_constraints.dart';
import 'calendar_planner.dart';
import 'commit_gate.dart';
import 'document_extractor.dart';
import 'reconciler.dart';
import 'schedule_engine.dart';
import 'session_repository.dart';
import 'session_store.dart';
import 'settings_controller.dart';
import 'signature.dart';
import 'storage_root.dart';
import 'task_interaction.dart';

class RunState {
  final String conversationId;
  final String requestId;
  final int jobId;
  final DateTime startedAt;
  final String? baseVersionId;
  final int baseRevision;
  final Duration elapsed;
  final String stage;
  final String detail;
  final bool cancelRequested;

  /// Exact draft text that was submitted with this request. Used at commit time to
  /// decide whether the draft may be cleared: anything the user typed *after*
  /// sending must survive the commit.
  final String submittedDraft;

  const RunState({
    required this.conversationId,
    required this.requestId,
    required this.jobId,
    required this.startedAt,
    required this.baseVersionId,
    required this.baseRevision,
    required this.elapsed,
    required this.stage,
    required this.detail,
    required this.cancelRequested,
    this.submittedDraft = '',
  });

  RunState copyWith({
    Duration? elapsed,
    String? stage,
    String? detail,
    bool? cancelRequested,
  }) =>
      RunState(
        conversationId: conversationId,
        requestId: requestId,
        jobId: jobId,
        startedAt: startedAt,
        baseVersionId: baseVersionId,
        baseRevision: baseRevision,
        elapsed: elapsed ?? this.elapsed,
        stage: stage ?? this.stage,
        detail: detail ?? this.detail,
        cancelRequested: cancelRequested ?? this.cancelRequested,
        submittedDraft: submittedDraft,
      );

  String get elapsedText {
    final s = elapsed.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return m > 0 ? '$m 分 ${r.toString().padLeft(2, '0')} 秒' : '$r 秒';
  }
}

class AppController extends ChangeNotifier {
  final ScheduleEngine engine;
  final SessionRepository store;
  final NativeGateway? gateway;

  /// Global model/settings state. Optional so the existing tests (and any headless
  /// embedding) keep working without a settings store; when present it is the only
  /// source of the model selection used for a request.
  final SettingsController? settings;

  /// Alias kept for older call sites / tests that used the longer name.
  SettingsController? get settingsController => settings;

  /// Where sessions are stored (shown in the sidebar footer) and, when the primary
  /// location was not writable, a one-line explanation for the user.
  final String storagePath;
  final String? storageNotice;
  final bool storageIsPersistent;

  /// Storage resolution details for the "存储" page (never a secret).
  final String storageSource;
  final List<RejectedRoot> storageRejected;

  AppController({
    required this.engine,
    required this.store,
    this.gateway,
    this.settings,
    this.storagePath = '',
    this.storageNotice,
    this.storageIsPersistent = true,
    this.storageSource = '',
    this.storageRejected = const <RejectedRoot>[],
  });

  // ------------------------------------------------------------------ state

  final TaskInteraction interaction = TaskInteraction();
  final ConversationCommitGate gate = ConversationCommitGate();

  final List<ConversationSummary> _summaries = [];
  final Map<String, Conversation> _cache = {};

  Conversation? _conversation;
  PlanVersion? _viewVersion;
  DisplaySnapshot? _display;

  RunState? _run;
  Timer? _pollTimer;
  Timer? _tickTimer;
  bool _waitPromptShown = false;
  bool _disposed = false;

  String? _statusMessage;
  String? _errorMessage;
  bool _busy = false;

  List<ConversationSummary> get summaries => List.unmodifiable(_summaries);
  Conversation? get conversation => _conversation;
  PlanVersion? get viewVersion => _viewVersion;
  DisplaySnapshot? get display => _display;
  RunState? get run => _run;
  bool get isRunning => _run != null;
  bool get waitPromptVisible => _waitPromptShown;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  bool get busy => _busy;

  bool get isViewingCurrentVersion {
    final c = _conversation;
    final v = _viewVersion;
    if (c == null || v == null) return false;
    return c.currentVersionId == v.id ||
        (c.currentVersionId == null &&
            c.versions.isNotEmpty &&
            identical(c.versions.last, v));
  }

  /// Plan editing (checkbox, condition status) is allowed only when the current
  /// version is being viewed and no analysis is in flight for it.
  bool get canEditPlan {
    if (!isViewingCurrentVersion) return false;
    final run = _run;
    final c = _conversation;
    if (run != null && c != null && run.conversationId == c.id) return false;
    return true;
  }

  bool get hasActiveRunForCurrent {
    final run = _run;
    final c = _conversation;
    return run != null && c != null && run.conversationId == c.id;
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> initialize() async {
    await store.ensureLayout();
    try {
      final loaded = await store.loadIndex();
      _summaries
        ..clear()
        ..addAll(loaded);
      _sortSummaries();
      await recoverPendingOperations();
      await _recoverOrphanedDrafts();
    } on SessionFormatException catch (e) {
      _errorMessage = e.toString();
      _summaries.clear();
      _notify();
      return;
    } catch (e) {
      _errorMessage = '读取本地会话失败：$e';
    }
    final first = visibleSummaries.isEmpty ? null : visibleSummaries.first;
    if (first != null) {
      await openConversation(first.id);
    }
    _notify();
  }

  /// A previous permanent-delete may have completed the payload removal but crashed
  /// before the index write. The tombstone is authoritative, so drop such rows.
  Future<void> _recoverOrphanedDrafts() async {
    final tombstones = await store.loadTombstones();
    if (tombstones.isEmpty) return;
    final before = _summaries.length;
    _summaries.removeWhere((s) => tombstones.contains(s.id));
    if (_summaries.length != before) await store.saveIndex(_summaries);
  }

  Future<void> openConversation(String id) async {
    _busy = true;
    _notify();
    try {
      var c = _cache[id];
      if (c == null) {
        try {
          c = await store.loadConversation(id);
        } on SessionFormatException catch (e) {
          _errorMessage = e.toString();
          return;
        }
        if (c != null) _cache[id] = c;
      }
      if (c == null) {
        _errorMessage = '会话已不存在或已损坏';
        return;
      }
      // A pending request from a previous process can never be resumed; clear it
      // instead of leaving the UI permanently locked.
      if (c.pendingRequest != null) {
        c = c.copyWith(clearPendingRequest: true);
        _cache[id] = c;
        await store.saveConversation(c);
      }
      _conversation = c;
      interaction.reset();
      _viewVersion = c.currentVersion;
      _errorMessage = null;
      _statusMessage = null;
      _waitPromptShown = false;
      _display = _viewVersion == null ? null : _compute(_viewVersion!.plan);
      _reindexSummaries();

      // One-time migration for a session written before conversations carried a model
      // binding: bind the current global default and tell the user. A running analysis
      // already owns its captured selection, so it is never touched here, and the
      // historical versions' `modelSource` stays exactly as recorded.
      await _migrateLegacyConversation(c);
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Binds a legacy conversation (no model binding of its own) to the current default.
  ///
  /// Runs at most once per conversation because the binding is persisted: after that
  /// [Conversation.modelSelection] is no longer null. A running analysis already owns its
  /// captured selection, so it is left alone; historical versions' `modelSource` is never
  /// rewritten.
  Future<Conversation> _migrateLegacyConversation(Conversation c) async {
    final settings = this.settings;
    if (settings == null || !settings.loaded) return c;
    if (c.modelSelection != null) return c;
    final run = _run;
    if (run != null && run.conversationId == c.id) return c;
    final resolution = settings.resolveSelectionForRequest(c);
    final selection = resolution.selection;
    if (selection == null) {
      // No usable default: say why instead of silently following the default later.
      final reason = resolution.error;
      if (reason != null) _statusMessage = reason;
      return c;
    }
    final migrated = c.copyWith(modelSelection: selection);
    _conversation = migrated;
    _cache[migrated.id] = migrated;
    await store.saveConversation(migrated);
    _reindexSummaries();
    _statusMessage = _migrationNote(selection);
    return migrated;
  }

  String _migrationNote(ModelSelection selection) {
    final name = settings?.profileById(selection.profileId)?.name.trim() ?? '';
    final label = name.isEmpty ? selection.profileId : name;
    return '已为这个旧会话一次性绑定模型连接「$label」，之后不会跟随全局默认变化；'
        '可在输入框上方重新选择模型';
  }

  Future<Conversation> createConversation({bool reuseBlank = true}) async {
    // Consecutive "new conversation" clicks reuse an untouched blank conversation
    // instead of littering the sidebar, but never reuse one with a draft/attachment.
    final blank = reuseBlank
        ? visibleSummaries.where((s) {
            final cached = _cache[s.id];
            return s.versionCount == 0 &&
                (cached == null ||
                    (cached.draftText.trim().isEmpty &&
                        cached.attachments.isEmpty &&
                        cached.pendingRequest == null));
          }).toList()
        : const <ConversationSummary>[];
    if (blank.isNotEmpty) {
      final existing = await _loadFor(blank.first.id);
      if (existing != null &&
          existing.versions.isEmpty &&
          existing.draftText.trim().isEmpty &&
          existing.attachments.isEmpty) {
        _conversation = existing;
        _viewVersion = null;
        _display = null;
        interaction.reset();
        _notify();
        return existing;
      }
    }
    final now = DateTime.now();
    final settings = this.settings;
    final c = Conversation(
      id: IdGenerator.next('conv'),
      title: '',
      createdAt: now,
      updatedAt: now,
      // New conversations start from the user's default dependency view; existing
      // conversations keep their own value.
      chartMode: settings?.prefs.defaultChartMode ?? 'tree',
      // Capture the default model **at creation time**: changing the global default
      // later must not silently move an existing conversation to another provider.
      modelSelection: settings?.usableDefaultSelection,
    );
    _cache[c.id] = c;
    await store.saveConversation(c);
    _reindexSummaries();
    await store.saveIndex(_summaries);
    _conversation = c;
    _viewVersion = null;
    _display = null;
    interaction.reset();
    _notify();
    return c;
  }

  Future<Conversation>? _ensuring;

  /// Returns the current conversation, creating one on demand.
  ///
  /// Why: a freshly started app has no conversation, and the composer is usable
  /// immediately. Without this, typing or adding a file on a fresh start did nothing
  /// (the draft was dropped and the file was rejected with a generic error).
  Future<Conversation> ensureConversation() {
    final existing = _conversation;
    if (existing != null) return Future.value(existing);
    final pending = _ensuring;
    if (pending != null) return pending;
    final created = createConversation();
    _ensuring = created;
    created.whenComplete(() => _ensuring = null);
    return created;
  }

  Future<void> updateDraft(String text) async {
    if (_disposed) return;
    final c = _conversation ?? await ensureConversation();
    if (_disposed) return;
    _conversation = c.copyWith(
      draftText: text,
      updatedAt: DateTime.now(),
      activityAt: DateTime.now(),
    );
    _cache[c.id] = _conversation!;
    _notify();
  }

  // ----------------------------------------------------------- attachments

  /// Extracts TXT/MD/PDF/DOCX/PPTX locally and stores the text with its source location.
  Future<bool> addTextFile(String path) async {
    if (_disposed) return false;
    final file = File(path);
    final name = file.uri.pathSegments.isEmpty ? path : file.uri.pathSegments.last;
    final current = _conversation;
    if (current != null &&
        current.attachments.any(
            (a) => (a.originalPath ?? '') == path || a.label == name)) {
      _errorMessage = '这个文件已经添加过：$name';
      _notify();
      return false;
    }
    try {
      final result = await extractDocument(
        file,
        maxBytes: engine.info.maxInputBytes,
      );
      if (result.error != null) {
        _errorMessage = result.error!.message;
        _notify();
        return false;
      }
      final doc = result.document!;
      final text = doc.segments
          .map((s) => s.location == null ? s.text : '【${s.location}】\n${s.text}')
          .join('\n\n');
      if (utf8.encode(text).length > engine.info.maxInputBytes) {
        _errorMessage =
            '提取出的文本超过输入上限 ${engine.info.maxInputBytes} 字节（未截断）；请拆分文件。';
        _notify();
        return false;
      }
      // Only create a conversation once the file is known to be usable.
      final c = current ?? await ensureConversation();
      if (_disposed) return false;
      final attachment = Attachment(
        id: IdGenerator.next('att'),
        label: name,
        kind: doc.kind,
        originalPath: path,
        text: text,
        byteLength: utf8.encode(text).length,
      );
      await store.saveAttachment(attachment);
      _conversation = c.copyWith(
        attachments: [...c.attachments, attachment],
        updatedAt: DateTime.now(),
        activityAt: DateTime.now(),
      );
      _cache[c.id] = _conversation!;
      await store.saveConversation(_conversation!);
      _errorMessage = null;
      if (doc.warning != null) _statusMessage = doc.warning;
      _notify();
      return true;
    } catch (e) {
      _errorMessage = '读取文件失败：$e';
      _notify();
      return false;
    }
  }

  Future<void> removeAttachment(String id) async {
    final c = _conversation;
    if (c == null) return;
    _conversation = c.copyWith(
      attachments: c.attachments.where((a) => a.id != id).toList(growable: false),
      updatedAt: DateTime.now(),
    );
    _cache[c.id] = _conversation!;
    await store.saveConversation(_conversation!);
    _notify();
  }

  // -------------------------------------------------------------- analysis

  Future<void> startAnalysis() async {
    if (_run != null) return;
    // Sending from a brand-new session must work without clicking "新建会话" first.
    var c = await ensureConversation();
    if (_disposed) return;
    final version = c.currentVersion;
    final draft = c.draftText.trim();
    if (draft.isEmpty && c.attachments.isEmpty) {
      _errorMessage = '请先粘贴材料或添加文本文件';
      _notify();
      return;
    }

    // Resolve the model selection **now**: switching the default connection later must
    // not change a request that is already on its way. The native side receives the exact
    // profile revision and snapshots it for the worker thread.
    //
    // This is the sending path, so a broken explicit binding is *blocked* instead of
    // being silently re-pointed at the global default; a legacy conversation without a
    // binding is migrated once and the user is told.
    final settings = this.settings;
    ModelSelection? selection;
    String? migrationNote;
    if (settings != null) {
      final resolution = settings.resolveSelectionForRequest(c);
      final selectionError = resolution.error;
      if (selectionError != null) {
        // Keep the draft and the attachments: the user retries after fixing the model.
        _errorMessage = selectionError;
        _notify();
        return;
      }
      selection = resolution.selection;
      if (resolution.migrated && selection != null && c.modelSelection == null) {
        c = c.copyWith(modelSelection: selection);
        _conversation = c;
        _cache[c.id] = c;
        await store.saveConversation(c);
        _reindexSummaries();
        migrationNote = _migrationNote(selection);
      }
    }

    final gw = gateway;
    if (gw == null) {
      _errorMessage = '原生桥接不可用，无法发起分析';
      _notify();
      return;
    }

    final requestId = IdGenerator.next('req');

    final ticket = gate.begin(
      conversationId: c.id,
      requestId: requestId,
      baseVersionId: version?.id,
      baseRevision: version?.revision ?? 0,
    );

    // Persist the pending request before starting, so a crash cannot leave a
    // half-locked conversation behind silently.
    final withPending = c.copyWith(
      pendingRequest: PendingRequest(
        requestId: requestId,
        baseVersionId: version?.id,
        baseRevision: version?.revision ?? 0,
        startedAt: DateTime.now(),
      ),
    );
    _conversation = withPending;
    _cache[c.id] = withPending;
    await store.saveConversation(withPending);

    final planContext = version == null ? null : _buildPlanContext(version);
    final request = <String, dynamic>{
      'conversationId': c.id,
      'requestId': requestId,
      'baseVersionId': version?.id,
      'baseRevision': version?.revision ?? 0,
      'userRequest': draft,
      'planContext': planContext,
      'sources': [
        if (draft.isNotEmpty)
          {'kind': 'text', 'label': '文段1', 'text': draft},
        for (final a in c.attachments)
          if (a.kind == 'file' && a.originalPath != null)
            {'kind': 'file', 'path': a.originalPath}
          else
            {'kind': 'text', 'label': a.label, 'text': a.text},
      ],
    };

    try {
      final jobId = gw.analyzeAsync(request, modelSelection: selection);
      _run = RunState(
        conversationId: c.id,
        requestId: requestId,
        jobId: jobId,
        startedAt: DateTime.now(),
        baseVersionId: version?.id,
        baseRevision: version?.revision ?? 0,
        elapsed: Duration.zero,
        stage: '开始分析',
        detail: '',
        cancelRequested: false,
        submittedDraft: c.draftText,
      );
      _waitPromptShown = false;
      _errorMessage = null;
      // Keep the one-time migration notice visible while the request runs instead of
      // wiping it immediately.
      _statusMessage = migrationNote;
      _startTimers();
    } catch (e) {
      gate.finish(ticket);
      _run = null;
      _errorMessage = _describeStartFailure(e);
      await _clearPending();
    }
    _notify();
  }

  /// Distinguishes "the model configuration moved under us" from a generic transport
  /// failure, so the user knows whether to retry or to reopen the settings dialog.
  String _describeStartFailure(Object error) {
    if (error is NativeCallException) {
      switch (error.kind) {
        case SettingsErrorCatalog.profileDeleted:
        case SettingsErrorCatalog.revision:
        case SettingsErrorCatalog.conflict:
        case 'config':
        case 'validation':
          return '无法开始分析：${SettingsErrorCatalog.describe(error)}';
      }
      return '无法开始分析：${error.message}';
    }
    return '无法开始分析：$error';
  }

  /// Selects the model connection for the current conversation (persisted).
  ///
  /// Passing `null` clears the binding: the next send re-binds once from the usable
  /// global default (if any) or asks the user to pick a model. Switching the model never
  /// creates a plan version and never disturbs a running request (which already owns its
  /// own captured selection).
  Future<String?> setConversationSelection(ModelSelection? selection) async {
    final c = _conversation;
    if (c == null) return '当前没有会话';
    if (selection != null) {
      final settings = this.settings;
      if (settings != null) {
        final error = settings.validateSelection(selection);
        if (error != null) return error;
      } else {
        final invalid = selection.validate();
        if (invalid.isNotEmpty) return invalid.first;
      }
    }
    if (c.modelSelection == selection) return null;
    final updated = selection == null
        ? c.copyWith(clearModelSelection: true, updatedAt: DateTime.now())
        : c.copyWith(modelSelection: selection, updatedAt: DateTime.now());
    _conversation = updated;
    _cache[updated.id] = updated;
    _notify();
    await store.saveConversation(updated);
    return null;
  }

  /// The selection a new request would use right now (conversation override or default).
  ModelSelection? get activeSelection =>
      settings?.currentSelectionFor(_conversation);

  String _buildPlanContext(PlanVersion version) {
    final buf = StringBuffer();
    if (version.summary.trim().isNotEmpty) {
      buf.writeln('总结：${version.summary.trim()}');
    }
    for (final t in version.tasks) {
      final hours = t.hoursKnown ? '${t.estimatedHours}h' : '工时未知';
      final state = t.isDone ? '已完成' : '未完成';
      final deps = t.dependsOn.isEmpty
          ? '无前置'
          : '前置：${t.dependsOn.map((d) => version.plan.taskById(d)?.name ?? d).join('、')}';
      buf.writeln('- id=${t.id} 名称=${t.name}（$state，$hours，$deps）');
    }
    return buf.toString();
  }

  void _startTimers() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _pollTimer =
        Timer.periodic(const Duration(milliseconds: 120), (_) => _pollOnce());
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  void _tick() {
    final run = _run;
    if (run == null) return;
    final elapsed = DateTime.now().difference(run.startedAt);
    _run = run.copyWith(elapsed: elapsed);
    final waitMs = engine.info.waitPromptMs;
    if (!_waitPromptShown && waitMs > 0 && elapsed.inMilliseconds >= waitMs) {
      _waitPromptShown = true;
    }
    _notify();
  }

  Future<void> _pollOnce() async {
    final run = _run;
    final gw = gateway;
    if (run == null || gw == null) return;
    BridgePollResult polled;
    try {
      polled = gw.poll(run.jobId);
    } catch (e) {
      _errorMessage = '读取分析进度失败：$e';
      _stopTimers();
      _run = null;
      _notify();
      return;
    }
    for (final e in polled.events) {
      if (e.type == 'progress' || e.type == 'started') {
        _run = _run?.copyWith(stage: e.stage, detail: e.detail);
      }
      if (e.isTerminal) {
        await _finishRun(e);
        return;
      }
    }
    _notify();
  }

  Future<void> _finishRun(BridgeEvent terminal) async {
    final run = _run;
    final gw = gateway;
    if (run == null || gw == null) return;
    _stopTimers();

    AnalyzeOutcome? outcome;
    try {
      outcome = gw.result(run.jobId);
    } catch (e) {
      _errorMessage = '读取分析结果失败：$e';
    }
    gw.release(run.jobId);

    final ticket = gate.activeFor(run.conversationId);
    if (ticket == null || ticket.requestId != run.requestId) {
      // A newer request already took over; this result must not touch anything.
      _run = null;
      _notify();
      return;
    }

    await _clearPending();

    if (terminal.type == 'cancelled' || outcome == null || !outcome.ok) {
      final message = terminal.type == 'cancelled'
          ? '已取消本次分析；原有计划与标题保持不变'
          : '分析失败：${outcome?.error ?? terminal.error}；原有计划与标题保持不变';
      _statusMessage = message;
      if (terminal.type != 'cancelled') _errorMessage = outcome?.error;
      gate.finish(ticket);
      _run = null;
      _notify();
      return;
    }

    await _commitResult(ticket, outcome, run.submittedDraft);
    gate.finish(ticket);
    _run = null;
    _waitPromptShown = false;
    _notify();
  }

  Future<void> _commitResult(
      RequestTicket ticket, AnalyzeOutcome outcome, String submittedDraft) async {
    final c = _conversation;
    final plan = outcome.plan;
    final latest = await _loadFor(ticket.conversationId);
    if (latest == null || latest.isDeleted || latest.isArchived) {
      _statusMessage = '会话已归档或删除，迟到结果已丢弃';
      return;
    }
    if (c == null || c.id != ticket.conversationId || plan == null) {
      _statusMessage = '结果不属于当前会话，已丢弃';
      return;
    }

    final proposed = ((plan['tasks'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((t) => TaskRecord.fromLocalJson(t))
        .toList(growable: false);
    if (proposed.isEmpty) {
      _statusMessage = '模型没有返回任何任务，已忽略本次结果';
      return;
    }

    final base = _versionById(c, ticket.baseVersionId);
    final reconciled = reconcileTasks(
      previous: base?.tasks ?? const [],
      proposed: proposed,
      idFactory: () => IdGenerator.next('task'),
    );

    // Translate note task references from model ids to stable ids.
    final notes = ((plan['notes'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((n) {
      final refs = ((n['taskRefs'] as List<dynamic>?) ?? const [])
          .map((r) => reconciled.modelIdToStableId[r.toString()] ?? '')
          .where((r) => r.isNotEmpty)
          .toList(growable: false);
      return PlanNote(
        kind: (n['kind'] as String?) ?? 'question',
        text: (n['text'] as String?) ?? '',
        taskIds: refs,
      );
    }).toList(growable: false);

    final newVersion = PlanVersion(
      id: IdGenerator.next('ver'),
      conversationId: c.id,
      parentId: ticket.baseVersionId,
      revision: 0,
      createdAt: DateTime.now(),
      summary: (plan['summary'] as String?)?.trim() ?? '',
      sourceSummary: _fallbackSummary(c),
      tasks: reconciled.tasks,
      notes: notes,
      removedCompleted: reconciled.removedCompleted,
      reviewNotes: reconciled.reviewNotes,
      commitReason: ticket.baseVersionId == null ? 'initial' : 'supplement',
      // Provenance of the committed plan; `null` (unknown) when the native layer did not
      // report a source — never guessed from the current settings.
      modelSource: outcome.source,
      // Calendar arrangements follow the tasks that still exist and keep their stable
      // id; segments of removed tasks are dropped (their work no longer exists) and
      // segments of a task whose estimate changed are re-checked by the conflict pass.
      calendar: (base?.calendar ??
              CalendarSchedule.blank(now: DateTime.now()))
          .inheritedBy(reconciled.tasks.map((t) => t.id).toSet()),
    );

    final allowed = canCommit(
      active: gate.activeFor(c.id),
      context: CommitContext(
        conversationId: c.id,
        currentVersionId: c.currentVersion?.id,
        currentRevision: c.currentVersion?.revision ?? 0,
        existingVersionIds: c.versions.map((v) => v.id).toSet(),
      ),
      resultConversationId: c.id,
      resultRequestId: ticket.requestId,
      resultParentVersionId: newVersion.parentId,
      resultVersionId: newVersion.id,
    );
    if (!allowed) {
      _statusMessage = '本次结果已过期（计划版本已变化），未采纳；原有计划保持不变';
      return;
    }

    // Commit title + plan together: the title only changes with the new result.
    // The draft is cleared ONLY if the user did not type anything new while waiting.
    final draftUntouched = c.draftText == submittedDraft;
    final updated = c.copyWith(
      versions: [...c.versions, newVersion],
      currentVersionId: newVersion.id,
      title: newVersion.displayTitle,
      draftText: draftUntouched ? '' : c.draftText,
      attachments: draftUntouched ? const [] : c.attachments,
      messages: [
        ...c.messages,
        ChatMessage(
          id: IdGenerator.next('msg'),
          role: MessageRole.user,
          at: DateTime.now(),
          text: c.draftText.trim().isEmpty ? '（分析附件材料）' : c.draftText.trim(),
        ),
        ChatMessage(
          id: IdGenerator.next('msg'),
          role: MessageRole.notice,
          at: DateTime.now(),
          text: newVersion.displayTitle,
        ),
      ],
      updatedAt: DateTime.now(),
      clearPendingRequest: true,
    );
    _conversation = updated;
    _cache[c.id] = updated;
    _viewVersion = newVersion;
    _display = _compute(newVersion.plan) ?? _display;
    await store.saveConversation(updated);
    _reindexSummaries();
    await store.saveIndex(_summaries);
    _statusMessage = reconciled.reviewNotes.isEmpty
        ? '已生成新版本'
        : '已生成新版本；有 ${reconciled.reviewNotes.length} 项完成状态需要你复核';
  }

  PlanVersion? _versionById(Conversation c, String? id) {
    if (id == null) return null;
    for (final v in c.versions) {
      if (v.id == id) return v;
    }
    return null;
  }

  String _fallbackSummary(Conversation c) {
    final draft = c.draftText.trim();
    if (draft.isNotEmpty) {
      return draft.length <= 24 ? draft : '${draft.substring(0, 24)}…';
    }
    if (c.attachments.isNotEmpty) return c.attachments.first.label;
    return '新计划';
  }

  Future<void> _clearPending() async {
    final fresh = _conversation;
    if (fresh == null) return;
    final cleared = fresh.copyWith(clearPendingRequest: true);
    _conversation = cleared;
    _cache[cleared.id] = cleared;
    await store.saveConversation(cleared);
  }

  Future<void> cancelAnalysis() async {
    final run = _run;
    final gw = gateway;
    if (run == null || gw == null) return;
    final ticket = gate.activeFor(run.conversationId);
    if (ticket != null) gate.cancel(ticket);
    gw.cancel(run.jobId);
    _run = run.copyWith(cancelRequested: true, stage: '正在停止');
    _waitPromptShown = false;
    _notify();
  }

  void dismissWaitPrompt() {
    // "Continue waiting": no re-send, no repeated prompt.
    if (!_waitPromptShown) return;
    _waitPromptShown = false;
    _notify();
  }

  // ------------------------------------------------------------- versions

  /// Remembers the dependency view per conversation (it survives restarts).
  Future<void> setChartMode(String mode) async {
    final c = _conversation;
    if (c == null || c.chartMode == mode) return;
    final updated = c.copyWith(chartMode: mode);
    _conversation = updated;
    _cache[c.id] = updated;
    _notify();
    await store.saveConversation(updated);
  }

  /// 0.06: remembers the gantt sub-mode (relative hours vs calendar) per conversation.
  Future<void> setGanttMode(String mode) async {
    final c = _conversation;
    if (c == null || c.ganttMode == mode) return;
    final updated = c.copyWith(ganttMode: mode);
    _conversation = updated;
    _cache[c.id] = updated;
    _notify();
    await store.saveConversation(updated);
  }

  Future<void> selectVersion(String versionId) async {
    final c = _conversation;
    if (c == null) return;
    if (_run != null && _run!.conversationId == c.id) return;
    final v = _versionById(c, versionId);
    if (v == null) return;
    _viewVersion = v;
    interaction.reset();
    _display = _compute(v.plan) ?? _display;
    _notify();
  }

  // ----------------------------------------------------------- plan edits

  Future<bool> toggleCompletion(String taskId) async {
    if (!canEditPlan) return false;
    final v = _viewVersion;
    if (v == null) return false;
    final tasks = v.tasks.map((t) {
      if (t.id != taskId) return t;
      final next = t.isDone ? Completion.todo : Completion.done;
      return t.copyWith(completion: next, clearCompletionNote: true);
    }).toList(growable: false);
    final before = v;
    final expected = v.revision + 1;
    final ok =
        await _applyTasks(v.copyWith(tasks: tasks, revision: expected));
    if (ok) _rememberTaskUndo(before, expected);
    return ok;
  }

  /// One-level undo for a reversible plan edit. It refuses when the version moved on
  /// (new plan, another edit, switched version) instead of overwriting newer work.
  void _rememberTaskUndo(PlanVersion before, int expectedRevision) {
    _undo = _UndoEntry('撤销任务修改', () async {
      final current = _viewVersion;
      if (current == null ||
          current.id != before.id ||
          current.revision != expectedRevision ||
          !canEditPlan) {
        _statusMessage = '计划已变化，无法撤销这次修改';
        _notify();
        return;
      }
      await _applyTasks(before.copyWith(
        revision: current.revision + 1,
      ));
    });
    _statusMessage = '已修改任务；可用“撤销”恢复';
  }

  Future<bool> confirmReviewedTask(String taskId) async {
    if (!canEditPlan) return false;
    final v = _viewVersion;
    if (v == null) return false;
    final tasks = v.tasks
        .map((t) => t.id == taskId
            ? t.copyWith(completion: Completion.done, clearCompletionNote: true)
            : t)
        .toList(growable: false);
    final ok = await _applyTasks(
        v.copyWith(tasks: tasks, revision: v.revision + 1));
    if (ok) _rememberTaskUndo(v, v.revision + 1);
    return ok;
  }

  Future<bool> setPreconditionStatus(
      String taskId, int index, String status) async {
    if (!canEditPlan) return false;
    final v = _viewVersion;
    if (v == null) return false;
    final tasks = v.tasks.map((t) {
      if (t.id != taskId) return t;
      if (index < 0 || index >= t.preconditions.length) return t;
      final conds = List<Precondition>.from(t.preconditions);
      conds[index] = conds[index].copyWith(status: status);
      return t.copyWith(preconditions: conds);
    }).toList(growable: false);
    return _applyTasks(v.copyWith(tasks: tasks, revision: v.revision + 1));
  }

  /// Edits the fields the user is allowed to correct locally (name, estimate,
  /// deadline, dependencies). The C core re-validates and re-schedules; a rejected
  /// edit leaves memory and disk untouched.
  Future<bool> updateTask(
    String taskId, {
    String? name,
    double? estimatedHours,
    bool clearEstimate = false,
    String? deadline,
    bool clearDeadline = false,
    List<String>? dependsOn,
  }) async {
    if (!canEditPlan) return false;
    final v = _viewVersion;
    if (v == null) return false;
    final tasks = v.tasks
        .map((t) => t.id == taskId
            ? t.copyWith(
                name: name,
                estimatedHours: estimatedHours,
                clearEstimatedHours: clearEstimate,
                deadline: deadline,
                dependsOn: dependsOn,
              )
            : t)
        .toList(growable: false);
    final ok = await _applyTasks(
        v.copyWith(tasks: tasks, revision: v.revision + 1));
    if (ok) {
      _rememberTaskUndo(v, v.revision + 1);
      // Editing the estimate directly must not silently delete arrangements. If the new
      // estimate is smaller than what is already scheduled, say so and leave the
      // segments untouched for the user to trim.
      if (estimatedHours != null) {
        final allocated = v.calendar.minutesForTask(taskId);
        final newMinutes = (estimatedHours * 60).round();
        if (allocated > newMinutes) {
          _statusMessage = '已安排 ${formatDurationMinutes(allocated)} 超过新的预计工时 '
              '${formatDurationMinutes(newMinutes)}；'
              '安排片段没有被自动删除，请在日历中调整';
        }
      }
    }
    return ok;
  }

  /// Applies edited tasks to the CURRENT version, recomputes the schedule through
  /// the C core, and persists. On validation failure the previous state is kept.
  Future<bool> _applyTasks(PlanVersion next) async {
    final c = _conversation;
    if (c == null) return false;
    // A user edit changes the work itself, so the execution signature must follow
    // (unlike priority/estimate-only changes, which never invalidate completion).
    final withSignatures = next.copyWith(tasks: withComputedSignatures(next.tasks));
    // Recompute first: if C rejects the edit we must not touch storage.
    final snapshot = _compute(withSignatures.plan);
    if (snapshot == null) return false;

    final versions = c.versions
        .map((v) => v.id == withSignatures.id ? withSignatures : v)
        .toList(growable: false);
    final updated = c.copyWith(
      versions: versions,
      updatedAt: DateTime.now(),
      activityAt: DateTime.now(),
    );
    _conversation = updated;
    _cache[c.id] = updated;
    _viewVersion = withSignatures;
    _display = snapshot;
    await store.saveConversation(updated);
    _reindexSummaries();
    await store.saveIndex(_summaries);
    _notify();
    return true;
  }

  // ------------------------------------------------- calendar (0.06)

  /// Notes produced by the last automatic pass ("容量不足…", "前置还未安排…"), keyed by
  /// task id. Transient on purpose: the persisted facts are the segments and the
  /// estimated hours, so a restart cannot resurface a stale conclusion.
  Map<String, String> _calendarTaskNotes = const {};
  Map<String, String> get calendarTaskNotes => _calendarTaskNotes;

  /// Calendar half of the version being viewed (empty for pre-0.06 versions).
  CalendarSchedule get calendar =>
      _viewVersion?.calendar ?? CalendarSchedule.blank(now: DateTime.now());

  /// Planner input: task facts + display status + the C core's suggested order.
  List<SchedulingTask> schedulingTasks() {
    final v = _viewVersion;
    if (v == null) return const <SchedulingTask>[];
    final snap = _display;
    final order = snap?.order ?? const <String>[];
    return <SchedulingTask>[
      for (final t in v.tasks)
        SchedulingTask.fromRecord(
          t,
          status: snap?.byId(t.id)?.status ?? (t.isDone ? 'done' : 'unknown'),
          orderIndex: (() {
            final i = order.indexOf(t.id);
            return i < 0 ? 1 << 20 : i;
          })(),
        ),
    ];
  }

  Map<String, String> get taskNamesById => <String, String>{
        for (final t in _viewVersion?.tasks ?? const <TaskRecord>[]) t.id: t.name,
      };

  /// Commits one calendar edit atomically: segments, estimated hours and revision move
  /// together, the C core re-validates, and storage is written once. A validation
  /// failure leaves memory *and* disk untouched.
  Future<bool> applyCalendarEdit(CalendarEditOutcome outcome) async {
    if (!outcome.ok) {
      _errorMessage = outcome.error;
      _notify();
      return false;
    }
    if (!canEditPlan) {
      _errorMessage = '当前查看的是历史版本（或正在分析），日历修改不会保存';
      _notify();
      return false;
    }
    final v = _viewVersion;
    if (v == null) return false;
    final next = v.copyWith(
      calendar: outcome.schedule,
      tasks: outcome.tasks ?? v.tasks,
      revision: v.revision + 1,
    );
    final ok = await _applyTasks(next);
    if (ok) {
      _rememberTaskUndo(v, v.revision + 1);
      _statusMessage = outcome.message ?? outcome.label;
      _errorMessage = null;
    } else {
      _errorMessage ??= '本次日历修改未通过校验，已保留原安排';
    }
    _notify();
    return ok;
  }

  /// Explicit "重新自动安排". [keepManual] is the documented default: user-dragged
  /// segments survive and only the automatic part is recomputed.
  Future<CalendarAutoPlan?> runAutoSchedule({bool keepManual = true}) async {
    final v = _viewVersion;
    if (v == null) {
      _errorMessage = '没有可安排的版本';
      _notify();
      return null;
    }
    final plan = autoSchedule(
      current: v.calendar,
      tasks: schedulingTasks(),
      suggestedOrder: _display?.order ?? const <String>[],
      now: DateTime.now(),
      keepManual: keepManual,
    );
    _calendarTaskNotes = plan.taskNotes;
    if (plan.notes.isNotEmpty && plan.schedule.segments.isEmpty) {
      _errorMessage = plan.notes.join(' ');
      _notify();
      return plan;
    }
    final ok = await applyCalendarEdit(CalendarEditOutcome(
      schedule: plan.schedule,
      tasks: v.tasks,
      label: keepManual ? '重新自动安排（保留手调片段）' : '重排全部安排',
      message: plan.notes.isEmpty ? null : plan.notes.join(' '),
    ));
    return ok ? plan : null;
  }

  /// First entry into calendar mode: generate the initial schedule only when the user
  /// has actually provided availability. Otherwise report what is missing instead of
  /// inventing 24/7 capacity.
  Future<String?> ensureCalendarReady() async {
    final v = _viewVersion;
    if (v == null) return null;
    final cal = v.calendar;
    if (cal.autoGenerated || cal.segments.isNotEmpty) return null;
    if (!cal.settings.hasAvailability) return 'no-availability';
    final plan = await runAutoSchedule(keepManual: true);
    if (plan == null) return 'auto-failed';
    if (plan.schedule.segments.isEmpty) {
      return plan.notes.isEmpty ? 'auto-empty' : plan.notes.first;
    }
    return null;
  }

  /// Applies a new availability configuration and (optionally) re-schedules.
  Future<bool> applyCalendarSettings(
    CalendarSettings settings, {
    bool reschedule = true,
  }) async {
    final v = _viewVersion;
    if (v == null) return false;
    var schedule = v.calendar.copyWith(settings: settings);
    if (reschedule) {
      final plan = autoSchedule(
        current: schedule,
        tasks: schedulingTasks(),
        suggestedOrder: _display?.order ?? const <String>[],
        now: DateTime.now(),
        keepManual: true,
      );
      _calendarTaskNotes = plan.taskNotes;
      schedule = plan.schedule;
    }
    return applyCalendarEdit(CalendarEditOutcome(
      schedule: schedule,
      tasks: v.tasks,
      label: '更新可用时间',
      message: reschedule ? '已按新的可用时间重新安排' : '已保存可用时间',
    ));
  }

  // ---------------------------------------- AI calendar-constraint proposals

  /// The material a constraint scan is allowed to see: everything the user actually
  /// submitted for this conversation (their messages) plus the extracted text of every
  /// uploaded attachment, plus whatever is in the input box right now.
  ///
  /// Using the attachments' *extracted text* (not just the new draft) is the whole
  /// point: a course table uploaded yesterday must reach the model without the user
  /// pasting it again.
  List<({String label, String text})> calendarMaterialSources() {
    final c = _conversation;
    if (c == null) return const [];
    final out = <({String label, String text})>[];
    final draft = c.draftText.trim();
    if (draft.isNotEmpty) {
      out.add((label: '文段1', text: draft));
    }
    var index = 0;
    for (final a in c.attachments) {
      index++;
      final text = a.text.trim();
      if (text.isEmpty) continue;
      out.add((label: a.label.isEmpty ? '材料$index' : a.label, text: text));
    }
    return out;
  }

  /// Signature of the material above; a cached proposal set is only reused when this
  /// still matches, so "材料变化" can never silently keep an outdated answer.
  String get calendarProposalSignature => materialSignature(<String>[
        for (final s in calendarMaterialSources()) s.text,
      ]);

  /// Cached, validated proposal set for the current conversation (null = never asked).
  CalendarProposalSet? get calendarProposals => _conversation?.calendarProposals;

  /// Native job id of an in-flight constraint scan (null when idle). Exposed so the
  /// dialog can offer 取消 without inventing its own request state.
  int? get calendarProposalJob => _proposalJob;
  bool get calendarProposalRunning => _proposalJob != null;
  String get calendarProposalStage => _proposalStage;
  String? get calendarProposalError => _proposalError;
  int? _proposalJob;
  String _proposalStage = '';
  String? _proposalError;

  /// True when the cached set still belongs to the current material.
  bool get calendarProposalsAreCurrent {
    final set = calendarProposals;
    if (set == null) return false;
    return set.materialSignature == calendarProposalSignature;
  }

  /// Runs (or reuses) one real model request that extracts calendar constraints.
  ///
  /// Rules encoded here:
  ///   * a cached answer for the *same* material is returned without spending another
  ///     request — opening the dialog repeatedly is free;
  ///   * [force] is the only way to spend a second request, and only an explicit
  ///     "重新识别" click passes it;
  ///   * failures are returned as text; they never fall back to "everything available";
  ///   * the answer is stored per conversation and tagged with the material signature,
  ///     so a late answer for an old material cannot become current.
  Future<CalendarProposalOutcome> fetchCalendarProposals(
      {bool force = false}) async {
    final gw = gateway;
    final c = _conversation;
    if (c == null) {
      return const CalendarProposalOutcome.failure('当前没有会话');
    }
    if (gw == null) {
      return const CalendarProposalOutcome.failure('原生桥接不可用，无法识别时间约束');
    }
    final sources = calendarMaterialSources();
    if (sources.isEmpty) {
      return const CalendarProposalOutcome.failure(
          '还没有可识别的材料：请先在输入框粘贴材料，或用「添加材料」上传课程表/活动安排');
    }
    final signature = calendarProposalSignature;
    final cached = c.calendarProposals;
    if (!force && cached != null && cached.materialSignature == signature) {
      return CalendarProposalOutcome.success(cached);
    }
    if (_proposalJob != null) {
      return CalendarProposalOutcome.failure(
          '正在识别中（$_proposalStage），请稍候或取消后再试');
    }
    if (hasActiveRunForCurrent) {
      return const CalendarProposalOutcome.failure(
          '正在分析本次材料，请在分析结束后再识别时间约束');
    }

    ModelSelection? selection;
    final settings = this.settings;
    if (settings != null) {
      final resolution = settings.resolveSelectionForRequest(c);
      final selectionError = resolution.error;
      if (selectionError != null) {
        return CalendarProposalOutcome.failure(selectionError);
      }
      selection = resolution.selection;
    }

    final cid = c.id;
    final requestId = IdGenerator.next('cst');
    final request = <String, dynamic>{
      'conversationId': cid,
      'requestId': requestId,
      'userRequest': sources.length > 1 ? sources.first.text : '',
      'sources': [
        for (final s in sources) {'kind': 'text', 'label': s.label, 'text': s.text},
      ],
      'materialSignature': signature,
    };

    int jobId;
    try {
      jobId = gw.constraintsAsync(request, modelSelection: selection);
    } catch (e) {
      final message = e is NativeCallException ? e.message : '$e';
      _proposalError = message;
      _notify();
      return CalendarProposalOutcome.failure('无法开始识别：$message');
    }

    _proposalJob = jobId;
    _proposalStage = '已提交请求';
    _proposalError = null;
    _notify();

    try {
      final terminal = await _awaitProposalJob(jobId);
      if (terminal == null) {
        return const CalendarProposalOutcome.failure('已取消本次识别（结果未采纳）');
      }
      ConstraintsOutcome? outcome;
      try {
        outcome = gw.constraintsResult(jobId);
      } catch (e) {
        outcome = null;
        _proposalError = '$e';
      }
      if (terminal.type == 'cancelled') {
        return const CalendarProposalOutcome.failure('已取消本次识别（结果未采纳）');
      }
      if (outcome == null || !outcome.ok) {
        final detail = outcome?.error;
        final message = (detail != null && detail.isNotEmpty)
            ? detail
            : (terminal.error.isNotEmpty ? terminal.error : '识别失败');
        _proposalError = message;
        _notify();
        return CalendarProposalOutcome.failure(message);
      }
      final decoded = decodeCalendarProposals(
        outcome.constraints,
        materialSignature: signature,
        now: DateTime.now(),
        thinkingEnabled: outcome.thinkingEnabled,
        thinkingEffort: outcome.thinkingEffort,
        protocol: outcome.protocol,
      );
      if (!decoded.ok) {
        final message = decoded.error ?? '识别结果未通过校验';
        _proposalError = message;
        _notify();
        return CalendarProposalOutcome.failure(message);
      }
      final set = decoded.set!;
      await _storeProposalSet(cid, signature, set);
      _proposalError = null;
      return CalendarProposalOutcome.success(set, rejected: decoded.rejected);
    } finally {
      _proposalJob = null;
      _proposalStage = '';
      _notify();
      try {
        gw.release(jobId);
      } catch (_) {
        // Releasing a finished job must never surface as a user-facing error.
      }
    }
  }

  /// Polls the native job until it reaches a terminal state. Null = cancelled/replaced.
  Future<BridgeEvent?> _awaitProposalJob(int jobId) async {
    final gw = gateway;
    if (gw == null) return null;
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (_proposalJob == jobId) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_proposalJob != jobId) return null;
      if (DateTime.now().isAfter(deadline)) {
        gw.cancel(jobId);
        _proposalError = '识别超时';
        return null;
      }
      BridgePollResult polled;
      try {
        polled = gw.poll(jobId);
      } catch (e) {
        _proposalError = '读取识别进度失败：$e';
        return null;
      }
      for (final e in polled.events) {
        if ((e.type == 'progress' || e.type == 'started') && e.stage.isNotEmpty) {
          _proposalStage = e.stage;
          _notify();
        }
        if (e.isTerminal) return e;
      }
    }
    return null;
  }

  /// Explicit user cancel of an in-flight constraint scan.
  void cancelCalendarProposals() {
    final job = _proposalJob;
    if (job == null) return;
    gateway?.cancel(job);
    _proposalJob = null;
    _proposalStage = '';
    _proposalError = null;
    _notify();
  }

  /// Persists the validated set on the conversation it belongs to.
  ///
  /// A result for a conversation that has been closed/deleted in the meantime is
  /// dropped instead of being written into whatever conversation is current now.
  Future<void> _storeProposalSet(
      String conversationId, String signature, CalendarProposalSet set) async {
    final current = _conversation;
    if (current == null || current.id != conversationId) return;
    if (current.calendarProposals?.materialSignature == signature &&
        current.calendarProposals?.createdAt == set.createdAt) {
      return;
    }
    final updated = current.copyWith(calendarProposals: set);
    _conversation = updated;
    _cache[updated.id] = updated;
    await store.saveConversation(updated);
    _notify();
  }

  /// Feeds the model's material *only* through the normal source list; nothing here is
  /// applied to the calendar. Kept as a documented seam so tests can assert that the
  /// attachment text really reaches the request.
  Map<String, dynamic> buildConstraintRequestForTest({bool force = false}) =>
      <String, dynamic>{
        'force': force,
        'signature': calendarProposalSignature,
        'sources': [
          for (final s in calendarMaterialSources())
            {'label': s.label, 'text': s.text},
        ],
      };

  // ------------------------------------------------- conversation lifecycle

  List<ConversationSummary> get visibleSummaries => _summaries
      .where((s) => !s.isArchived && !s.isDeleted)
      .toList(growable: false);
  List<ConversationSummary> get archivedSummaries => _summaries
      .where((s) => s.isArchived && !s.isDeleted)
      .toList(growable: false);
  List<ConversationSummary> get trashedSummaries => _summaries
      .where((s) => s.isDeleted)
      .toList(growable: false);

  bool hasActiveRun(String conversationId) =>
      _run?.conversationId == conversationId;

  /// Cancels a run for a conversation that is being archived/trashed. The gate is
  /// invalidated synchronously before the UI continues, so a late result cannot commit.
  Future<void> cancelRunFor(String conversationId) async {
    final run = _run;
    if (run == null || run.conversationId != conversationId) return;
    final ticket = gate.activeFor(conversationId);
    if (ticket != null) gate.cancel(ticket);
    gateway?.cancel(run.jobId);
    _stopTimers();
    _run = null;
    _waitPromptShown = false;
    final c = _conversation;
    if (c != null && c.id == conversationId && c.pendingRequest != null) {
      try {
        await store.saveConversation(c.copyWith(clearPendingRequest: true));
      } catch (_) {}
    }
    _notify();
  }

  Future<Conversation?> _loadFor(String id) async {
    var c = _cache[id];
    if (c == null) {
      c = await store.loadConversation(id);
      if (c != null) _cache[id] = c;
    }
    return c;
  }

  Future<void> _saveLifecycle(Conversation c) async {
    _cache[c.id] = c;
    await store.saveConversation(c);
    _reindexSummaries();
    _sortSummaries();
    await store.saveIndex(_summaries);
    if (_conversation?.id == c.id) _conversation = c;
    _notify();
  }

  void _sortSummaries() {
    _summaries.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      if (a.isPinned && b.isPinned) {
        final o = (a.meta.pinOrder ?? 0).compareTo(b.meta.pinOrder ?? 0);
        if (o != 0) return o;
      }
      final byActivity = b.activityAt.compareTo(a.activityAt);
      return byActivity != 0 ? byActivity : a.id.compareTo(b.id);
    });
  }

  Future<bool> renameConversation(String id, String? title) async {
    final c = await _loadFor(id);
    if (c == null) return false;
    final next = c.copyWith(meta: c.meta.rename(title ?? ''));
    await _saveLifecycle(next);
    _undo = _UndoEntry('重命名会话', () => renameConversation(id, c.meta.customTitle));
    return true;
  }

  Future<bool> setPinned(String id, bool pinned) async {
    final c = await _loadFor(id);
    if (c == null) return false;
    final order = pinned
        ? (_summaries.where((s) => s.isPinned).fold<int>(0,
                (max, s) => (s.meta.pinOrder ?? 0) > max ? s.meta.pinOrder! : max) +
            1)
        : null;
    await _saveLifecycle(c.copyWith(meta: c.meta.withPin(order)));
    return true;
  }

  Future<bool> setArchived(String id, bool archived) async {
    final c = await _loadFor(id);
    if (c == null) return false;
    if (archived && hasActiveRun(id)) await cancelRunFor(id);
    final next = c.copyWith(
        meta: c.meta.withArchived(archived ? DateTime.now().toUtc() : null));
    await _saveLifecycle(next);
    if (archived && _conversation?.id == id) {
      await _openAdjacentTo(id);
    }
    _undo = _UndoEntry(archived ? '归档会话' : '恢复归档', () async {
      await setArchived(id, !archived);
    });
    return true;
  }

  Future<bool> moveToTrash(String id) async {
    final c = await _loadFor(id);
    if (c == null) return false;
    if (hasActiveRun(id)) await cancelRunFor(id);
    final at = DateTime.now().toUtc();
    await _saveLifecycle(c.copyWith(meta: c.meta.withDeleted(at)));
    if (_conversation?.id == id) await _openAdjacentTo(id);
    _undo = _UndoEntry('移入最近删除', () => restoreFromTrash(id));
    _statusMessage = '已移入最近删除';
    _notify();
    return true;
  }

  Future<bool> restoreFromTrash(String id) async {
    final c = await _loadFor(id);
    if (c == null) return false;
    await _saveLifecycle(c.copyWith(meta: c.meta.restoreDeleted()));
    _statusMessage = '已从最近删除恢复';
    _notify();
    return true;
  }

  /// Permanent deletion: tombstone first, then payload/index, then attachment GC.
  /// A failed step leaves the tombstone in place so a .bak rollback cannot resurrect it.
  Future<bool> permanentlyDelete(String id) async {
    final opId = IdGenerator.next('op');
    try {
      await store.beginOperation(
          id: opId, kind: 'permanentDelete', conversationId: id);
      await store.markDeleted(id);
    } catch (e) {
      _errorMessage = '永久删除失败：$e';
      _notify();
      return false;
    }
    try {
      await store.deleteConversation(id);
      _cache.remove(id);
      _summaries.removeWhere((s) => s.id == id);
      await store.saveIndex(_summaries);
      final keep = await store.referencedAttachmentIds();
      await store.pruneAttachments(keep);
      await store.finishOperation(opId);
      if (_conversation?.id == id) {
        _conversation = null;
        _viewVersion = null;
        _display = null;
        await _openAdjacentTo(id);
      }
      _statusMessage = '已永久删除';
      _notify();
      return true;
    } catch (e) {
      _errorMessage = '永久删除未完成：$e（已标记为删除，重启后仍不会显示）';
      _notify();
      return false;
    }
  }

  Future<void> _openAdjacentTo(String removedId) async {
    final visible = visibleSummaries.where((s) => s.id != removedId).toList();
    if (visible.isEmpty) {
      _conversation = null;
      _viewVersion = null;
      _display = null;
      interaction.reset();
      _notify();
      return;
    }
    await openConversation(visible.first.id);
  }

  _UndoEntry? _undo;
  String? get undoLabel => _undo?.label;
  bool get canUndo => _undo != null;

  Future<void> undoLast() async {
    final entry = _undo;
    if (entry == null) return;
    _undo = null;
    await entry.run();
    _statusMessage = '已撤销：${entry.label}';
    _notify();
  }

  /// Search visible/archived/trash independently. Matching is case-insensitive on
  /// both the custom and generated title; an empty query returns everything.
  List<ConversationSummary> searchSummaries(
    String query, {
    bool archived = false,
    bool deleted = false,
  }) {
    final q = query.trim().toLowerCase();
    final source = deleted
        ? trashedSummaries
        : archived
            ? archivedSummaries
            : visibleSummaries;
    if (q.isEmpty) return source;
    return source
        .where((s) =>
            s.displayTitle.toLowerCase().contains(q) ||
            s.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  /// Runs crash recovery for a permanent-delete operation interrupted last run.
  Future<void> recoverPendingOperations() async {
    try {
      final ops = await store.pendingOperations();
      for (final op in ops) {
        final id = (op['id'] as String?) ?? '';
        final kind = (op['kind'] as String?) ?? '';
        final cid = (op['conversationId'] as String?) ?? '';
        if (id.isEmpty || cid.isEmpty) continue;
        if (kind == 'permanentDelete') {
          await store.deleteConversation(cid);
          _cache.remove(cid);
          _summaries.removeWhere((s) => s.id == cid);
        }
        await store.finishOperation(id);
      }
      if (ops.isNotEmpty) await store.saveIndex(_summaries);
    } catch (e) {
      _statusMessage = '恢复未完成的操作失败：$e';
    }
  }

  /// Runs the C core's validate + reschedule.
  ///
  /// Returns null on failure and records the reason. Callers that merely *display* a
  /// version may keep the previous snapshot, but callers that persist an edit MUST
  /// treat null as "rejected" and leave storage untouched.
  DisplaySnapshot? _compute(LocalPlan plan) {
    if (plan.tasks.isEmpty) return null;
    try {
      final snap = engine.compute(plan);
      _errorMessage = null;
      return snap;
    } on ScheduleException catch (e) {
      _errorMessage = '计划校验失败：${e.message}';
      return null;
    } catch (e) {
      _errorMessage = '重算失败：$e';
      return null;
    }
  }

  // --------------------------------------------------------------- export
  Future<String?> exportUserText(String path) async {
    final v = _viewVersion;
    final gw = gateway;
    if (v == null || gw == null) return '没有可导出的计划';
    try {
      gw.export(localPlan: _localJsonForExport(v), path: path, format: 'txt');
      return null;
    } on NativeCallException catch (e) {
      return e.message;
    }
  }

  Future<String?> exportDiagnostics(String path) async {
    final v = _viewVersion;
    final gw = gateway;
    if (v == null || gw == null) return '没有可导出的计划';
    try {
      gw.export(localPlan: _localJsonForExport(v), path: path, format: 'diag');
      return null;
    } on NativeCallException catch (e) {
      return e.message;
    }
  }

  /// Exports one conversation (metadata, materials, every version) as Markdown.
  Future<String?> exportConversation(String id, String path) async {
    final c = await _loadFor(id);
    if (c == null) return '会话不存在';
    final b = StringBuffer()
      ..writeln('# ${c.listTitle}')
      ..writeln()
      ..writeln('- 会话 ID：${c.id}')
      ..writeln('- 创建：${c.createdAt.toIso8601String()}')
      ..writeln('- 更新：${c.activityAt.toIso8601String()}')
      ..writeln('- 版本数：${c.versions.length}')
      ..writeln('- 状态：${c.isDeleted ? '最近删除' : c.isArchived ? '已归档' : '正常'}')
      ..writeln();
    final materials = c.messages.where((m) => m.role == MessageRole.user).toList();
    if (materials.isNotEmpty) {
      b.writeln('## 材料与补充记录');
      for (final m in materials) {
        b
          ..writeln()
          ..writeln('### ${m.at.toIso8601String()}')
          ..writeln()
          ..writeln(m.text);
      }
    }
    for (final v in c.versions) {
      b
        ..writeln()
        ..writeln('## 版本 ${v.id}（${v.createdAt.toIso8601String()}）')
        ..writeln()
        ..writeln(v.displayTitle)
        ..writeln();
      for (final t in v.tasks) {
        final done = t.completion == Completion.done ? ' [已完成]' : '';
        b.writeln('- ${t.name}$done'
            '${t.estimatedHours == null ? '' : ' · ${t.estimatedHours} 小时'}'
            '${t.dependsOn.isEmpty ? '' : ' · 等待前置：${t.dependsOn.join('、')}'}');
      }
      if (v.notes.isNotEmpty) {
        b.writeln();
        for (final n in v.notes) {
          b.writeln('> ${n.text}');
        }
      }
      if (v.calendar.segments.isNotEmpty) {
        final clock = v.calendar.settings.clock;
        String stamp(DateTime t) {
          final w = clock.toWall(t);
          return '${WallClock.formatDateKey(w.year, w.month, w.day)} '
              '${WallClockRange.formatMinute(w.hour * 60 + w.minute)}';
        }

        b
          ..writeln()
          ..writeln('### 日历安排（${v.calendar.settings.timezoneId}）');
        for (final t in v.tasks) {
          final own = v.calendar.forTask(t.id);
          if (own.isEmpty) continue;
          final total = v.calendar.minutesForTask(t.id);
          b.writeln('- ${t.name} · 已安排 ${formatDurationMinutes(total)}'
              '${t.estimatedHours == null ? '' : ' / 预计 ${formatHours(t.estimatedHours)}'}'
              '${own.any((s) => s.tentative) ? '（含暂定）' : ''}');
          for (final s in own) {
            b.writeln('  - ${stamp(s.start)} → ${stamp(s.end)}'
                ' · ${formatDurationMinutes(s.minutes)}'
                '${s.source == SegmentSource.manual ? ' · 手调' : ''}'
                '${s.tentative ? ' · 暂定' : ''}');
          }
        }
      }
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(b.toString(), flush: true);
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// Exports all non-deleted conversations into one Markdown file.
  Future<String?> exportAllHistory(String path) async {
    final b = StringBuffer()
      ..writeln('# TaskScheduler 会话历史导出')
      ..writeln()
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln();
    for (final s in _summaries.where((s) => !s.isDeleted)) {
      final c = await _loadFor(s.id);
      if (c == null) continue;
      b
        ..writeln('## ${c.listTitle}')
        ..writeln()
        ..writeln('- 会话 ID：${c.id}')
        ..writeln('- 版本数：${c.versions.length}')
        ..writeln('- 最近活动：${c.activityAt.toIso8601String()}');
      for (final v in c.versions) {
        b
          ..writeln()
          ..writeln('### ${v.displayTitle}')
          ..writeln()
          ..writeln('- 版本：${v.id} · ${v.createdAt.toIso8601String()}');
        for (final t in v.tasks) {
          b.writeln('- ${t.completion == Completion.done ? '[x]' : '[ ]'} ${t.name}');
        }
      }
      b.writeln();
    }
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(b.toString(), flush: true);
      return null;
    } catch (e) {
      return '$e';
    }
  }


  /// The local plan JSON handed back to C must carry the user's completion state;
  /// C uses it for status and the relative timeline but never writes it.
  LocalPlan _planWithCompletion(PlanVersion v) =>
      LocalPlan(summary: v.summary, tasks: v.tasks, notes: v.notes);

  Map<String, dynamic> _localJsonForExport(PlanVersion v) =>
      _planWithCompletion(v).toLocalJson();

  // ------------------------------------------------------------- internals

  void _reindexSummaries() {
    final updated = <ConversationSummary>[];
    for (final s in _summaries) {
      final cached = _cache[s.id];
      updated.add(cached != null ? ConversationSummary.of(cached) : s);
    }
    for (final entry in _cache.entries) {
      if (!updated.any((s) => s.id == entry.key)) {
        updated.add(ConversationSummary.of(entry.value));
      }
    }
    updated.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _summaries
      ..clear()
      ..addAll(updated);
    _sortSummaries();
  }

  void clearMessages() {
    _statusMessage = null;
    _errorMessage = null;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    interaction.dispose();
    super.dispose();
  }
}

class _UndoEntry {
  final String label;
  final Future<void> Function() run;
  const _UndoEntry(this.label, this.run);
}

