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

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../ffi/native_gateway.dart';
import '../model/calendar.dart';
import '../model/calendar_proposals.dart';
import '../model/display.dart';
import '../model/external_calendar.dart';
import '../model/plan.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../model/timetable.dart';
import 'analysis/analysis.dart';
import 'analysis/chunked_plan_transport.dart';
import 'analysis/chunked_run_models.dart';
import 'calendar_constraints.dart';
import 'calendar_planner.dart';
import 'commit_gate.dart';
import 'document_extractor.dart';
import 'execution/effort_stats.dart';
import 'execution/execution_models.dart';
import 'execution/timer_controller.dart';
import 'external_calendar_service.dart';
import 'ocr/ocr_material.dart';
import 'ocr/ocr_service.dart';
import 'reconciler.dart';
import 'schedule_engine.dart';
import 'session_repository.dart';
import 'session_store.dart';
import 'settings_controller.dart';
import 'signature.dart';
import 'storage_root.dart';
import 'task_interaction.dart';
import 'timetable_composition.dart';

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

  /// 请求发出时的外部日历集合指纹（`ExternalCalendarService.fingerprint`）；
  /// 服务不可用/未启用时为空串。迟到结果在指纹变化时拒绝。
  final String externalFingerprint;

  /// 请求发出时实际使用的外部来源快照引用（写入新版本的 `externalCalendarRef`）。
  final List<ExternalCalendarSourceRef> externalSourcesRef;

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
    this.externalFingerprint = '',
    this.externalSourcesRef = const <ExternalCalendarSourceRef>[],
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
        externalFingerprint: externalFingerprint,
        externalSourcesRef: externalSourcesRef,
      );

  String get elapsedText {
    final s = elapsed.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return m > 0 ? '$m 分 ${r.toString().padLeft(2, '0')} 秒' : '$r 秒';
  }
}

/// 附件导入的一次性反馈（0.3.0，提示词 02）。
///
/// 只描述“本次批量导入发生了什么”，由 UI 在侧栏通知区展示；不再是底部浮动
/// SnackBar。失败项保留文件名与短原因；`note` 用于“已成功但需要分块分析”等附加说明。
class AttachmentFeedback {
  const AttachmentFeedback({
    required this.conversationId,
    required this.added,
    required this.failed,
    this.failures = const <String>[],
    this.note,
    required this.at,
  });

  final String conversationId;
  final int added;
  final int failed;

  /// 每条形如 `文件名：原因`，可直接展示（长文本允许换行）。
  final List<String> failures;
  final String? note;
  final DateTime at;

  bool get isEmpty =>
      added == 0 && failed == 0 && (note == null || note!.trim().isEmpty);
  bool get hasFailures => failed > 0;
  String get summary {
    if (added > 0 && failed > 0) return '已添加 $added 个文件，$failed 个失败';
    if (failed > 0) return '$failed 个文件未能添加';
    return '已添加 $added 个文件';
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

  /// 外部日历来源服务（只读导入）。
  ///
  /// 可空：没有来源管理/测试/无原生环境时传 null —— 此时一切行为与 0.2.1 相同
  /// （不会有任何合成时间表，也不会有外部指纹）。
  final ExternalCalendarService? externalCalendar;

  /// Where sessions are stored (shown in the sidebar footer) and, when the primary
  /// location was not writable, a one-line explanation for the user.
  final String storagePath;
  final String? storageNotice;
  final bool storageIsPersistent;

  /// Storage resolution details for the "存储" page (never a secret).
  final String storageSource;
  final List<RejectedRoot> storageRejected;

  /// 0.2.3（R3-E）：执行计时账本控制器。
  ///
  /// 可空：无原生/测试嵌入时不启用执行计时，所有 `execution*` 接口安全降级，
  /// 既有行为（0.2.2）完全不变。执行记录与计划版本分开持久化，计划 JSON 不被改写。
  final TimerController? timer;

  /// 0.2.3（R3-O/R3-Q）：数据根目录，供 OCR 缓存/分块作业等本地服务使用。
  /// 可空 = 本次运行没有可写目录（内存模式），相关功能必须明确报不可用。
  final Directory? dataDirectory;

  /// 0.2.3（R3-O）：本地离线 OCR 服务；null = 本环境未启用（文件仍走文本提取）。
  final OcrService? ocr;

  AppController({
    required this.engine,
    required this.store,
    this.gateway,
    this.settings,
    this.externalCalendar,
    this.timer,
    this.dataDirectory,
    this.ocr,
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
  String? _lastDocumentErrorCode;
  bool _busy = false;

  /// 0.3.0（提示词 02）：附件导入反馈。不再用底部浮动 SnackBar，而是交给
  /// 侧栏/工作区的紧凑通知区显示。按会话隔离，避免切会话后看到上一会话的回执。
  AttachmentFeedback? _attachmentFeedback;

  /// 最近一次添加文件的结构化失败码（如 `unsupported_ocr`）；成功/无关时为 null。
  /// UI 用它决定是否提供“本地 OCR 导入”，不靠匹配中文错误文案。
  String? get lastDocumentErrorCode => _lastDocumentErrorCode;

  // ------------------------------------------------ attachment feedback (0.3.0)

  /// 当前会话的附件导入反馈；没有或属于别的会话时为 null（切会话不串回执）。
  AttachmentFeedback? get attachmentFeedback {
    final feedback = _attachmentFeedback;
    if (feedback == null) return null;
    if (feedback.conversationId != _conversation?.id) return null;
    return feedback;
  }

  /// 记录一次批量导入结果（成功/失败合并为一条，不弹 SnackBar）。
  void reportAttachmentFeedback({
    required int added,
    required int failed,
    List<String> failures = const <String>[],
    String? note,
  }) {
    final conversationId = _conversation?.id ?? '';
    if (added == 0 && failed == 0 && (note == null || note.trim().isEmpty)) {
      return;
    }
    _attachmentFeedback = AttachmentFeedback(
      conversationId: conversationId,
      added: added,
      failed: failed,
      failures: List<String>.unmodifiable(failures),
      note: (note == null || note.trim().isEmpty) ? null : note.trim(),
      at: DateTime.now(),
    );
    _notify();
  }

  void dismissAttachmentFeedback() {
    if (_attachmentFeedback == null) return;
    _attachmentFeedback = null;
    _notify();
  }

  // ------------------------------------------- material size / request budget

  /// 当前会话会随请求发送的材料文本总字节数（草稿 + 附件提取文本，UTF-8）。
  int get materialUtf8Bytes {
    final c = _conversation;
    if (c == null) return 0;
    var total = utf8.encode(c.draftText).length;
    for (final attachment in c.attachments) {
      total += attachment.byteLength > 0
          ? attachment.byteLength
          : utf8.encode(attachment.text).length;
    }
    return total;
  }

  /// 单次模型请求允许的输入字节上限（来自内核配置）。
  int get singleRequestInputBytes => engine.info.maxInputBytes;

  /// 材料是否超过单次请求预算 → 应走「分块分析」而不是普通发送。
  bool get materialExceedsSingleRequest =>
      materialUtf8Bytes > singleRequestInputBytes;

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

  /// 时间表可以在“没有计划版本的空会话”里编辑（先存草稿），也可以在当前版本上编辑；
  /// 历史版本只读，分析进行中禁止提交。
  bool get canEditTimetable {
    if (hasActiveRunForCurrent) return false;
    if (_viewVersion == null) return _conversation != null;
    return isViewingCurrentVersion;
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
    // 切换会话前先落盘当前草稿：防抖窗口里的输入不能因为切换而丢失。
    await flushPendingWrites();
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
    // 只在内存里立即生效；落盘走防抖，避免每个按键都写一次文件。
    _draftDirty.add(c.id);
    if (_inFlutterTest) {
      // `flutter test` 会检查残留 Timer；测试环境立即落盘，行为与关闭时 flush 一致。
      await flushPendingWrites();
    } else {
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 450), () {
        unawaited(flushPendingWrites());
      });
    }
    _notify();
  }

  static final bool _inFlutterTest =
      Platform.environment['FLUTTER_TEST'] == 'true';

  final Set<String> _draftDirty = <String>{};
  Timer? _draftTimer;

  /// 正在进行的排空任务。并发调用必须等待同一个 Future，不能“看到别人在写就
  /// 直接返回成功”——关闭流程会因此提前销毁进程。
  Future<bool>? _flushInFlight;

  /// Flushes debounced writes (draft text) and drains edits that arrive while a
  /// write is in flight. Returns false when a write failed and the dirty set could
  /// not be drained; callers must not treat that as “saved”.
  Future<bool> flushPendingWrites() {
    final existing = _flushInFlight;
    if (existing != null) {
      return existing.then((ok) {
        if (!ok) return false;
        // 上一次排空结束前可能又产生了新草稿：继续排空，直到真正没有 dirty。
        if (_draftDirty.isEmpty) return true;
        return flushPendingWrites();
      });
    }
    if (_draftDirty.isEmpty) return Future.value(true);
    final future = _drainDraftWrites();
    _flushInFlight = future;
    future.whenComplete(() {
      if (identical(_flushInFlight, future)) _flushInFlight = null;
    });
    return future;
  }

  Future<bool> _drainDraftWrites() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    while (_draftDirty.isNotEmpty) {
      final id = _draftDirty.first;
      final snapshot = _cache[id];
      if (snapshot == null) {
        _draftDirty.remove(id);
        continue;
      }
      try {
        await store.saveConversation(snapshot);
      } catch (e) {
        // 保留 dirty，允许调用方重试；错误可见，不能假装已保存。
        _errorMessage = '草稿未能写入本地存储：$e';
        _notify();
        return false;
      }
      // 保存期间用户继续输入会替换缓存对象：这一条仍需再写一次。
      if (identical(_cache[id], snapshot)) {
        _draftDirty.remove(id);
      }
    }
    return true;
  }

  // ----------------------------------------------------------- attachments

  /// Extracts TXT/MD/PDF/DOCX/PPTX locally and stores the text with its source location.
  Future<bool> addTextFile(String path) async {
    if (_disposed) return false;
    _lastDocumentErrorCode = null;
    final file = File(path);
    final name = file.uri.pathSegments.isEmpty ? path : file.uri.pathSegments.last;
    final startConversation = _conversation;
    final targetId = startConversation?.id;
    if (startConversation != null &&
        startConversation.attachments.any(
            (a) => (a.originalPath ?? '') == path || a.label == name)) {
      _errorMessage = '这个文件已经添加过：$name';
      _notify();
      return false;
    }
    try {
      // 0.3.0（提示词 06A）：本地抽取使用分开的预算（容器 32MB / 文本 8MB），
      // 不再拿单次请求上限 262144 字节同时卡文件大小和文本长度。文件可抽取但
      // 超单次请求时保留材料，由 UI 引导到分块分析（见 AppShell._handleSend）。
      final result = await extractDocument(
        file,
        limits: DocumentExtractionLimits.defaults,
      );
      if (result.error != null) {
        _lastDocumentErrorCode = result.error!.code;
        _errorMessage = result.error!.message;
        _notify();
        return false;
      }
      final doc = result.document!;
      final text = doc.segments
          .map((s) => s.location == null ? s.text : '【${s.location}】\n${s.text}')
          .join('\n\n');
      // 抽取结果一律不截断；超出单次请求预算不算导入失败（提示词 06A）：
      // 材料保留在本地，发送时由 UI 提供分块估算/确认入口。
      final textBytes = result.textUtf8Bytes ?? utf8.encode(text).length;
      // 提取是异步的：完成后必须合并到“最近”的会话，不能用提取前的旧快照覆盖。
      final latest = targetId == null
          ? _conversation
          : (_cache[targetId] ?? (targetId == _conversation?.id ? _conversation : null));
      if (targetId != null && latest == null) {
        _errorMessage = '文件提取完成时会话已被关闭或删除，未添加：$name';
        _notify();
        return false;
      }
      if (latest != null &&
          latest.attachments.any(
              (a) => (a.originalPath ?? '') == path || a.label == name)) {
        _errorMessage = '这个文件已经添加过：$name';
        _notify();
        return false;
      }
      final c = latest ?? await ensureConversation();
      if (_disposed) return false;
      final attachment = Attachment(
        id: IdGenerator.next('att'),
        label: name,
        kind: doc.kind,
        originalPath: path,
        text: text,
        byteLength: textBytes,
      );
      await store.saveAttachment(attachment);
      // 合并最新状态，保留提取期间用户新加的附件、改过的草稿和切换过的版本。
      final current = _cache[c.id] ?? c;
      final updated = current.copyWith(
        attachments: [...current.attachments, attachment],
        updatedAt: DateTime.now(),
        activityAt: DateTime.now(),
      );
      _cache[c.id] = updated;
      if (_conversation?.id == c.id) _conversation = updated;
      await store.saveConversation(updated);
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

  /// 0.2.3（R3-O）：把本地 OCR（含用户校对）结果加入当前会话材料。
  ///
  /// 返回 null = 成功；否则为用户可读的失败原因。完整页级来源（页号/bbox/引擎
  /// 版本/置信度/校对原文）写入 `<data>/ocr_materials/<id>.json`，附件里只存摘要
  /// 与相对路径；不存原始页图，不联网。
  Future<String?> addOcrMaterial(OcrMaterial material) async {
    if (_disposed) return '应用已关闭';
    final text = material.text;
    if (material.pages.isEmpty || text.trim().isEmpty) {
      return 'OCR 结果为空，未加入材料';
    }
    final attachmentId = IdGenerator.next('att');
    String? materialRelativePath;
    final root = dataDirectory;
    if (root != null) {
      try {
        final dir =
            Directory('${root.path}${Platform.pathSeparator}ocr_materials');
        await dir.create(recursive: true);
        final file =
            File('${dir.path}${Platform.pathSeparator}$attachmentId.json');
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(material.toJson()),
          flush: true,
        );
        materialRelativePath = 'ocr_materials/$attachmentId.json';
      } catch (e) {
        return '保存 OCR 来源数据失败（未加入材料）：$e';
      }
    }
    final attachment = Attachment(
      id: attachmentId,
      label: material.fileLabel,
      kind: 'ocr',
      text: text,
      byteLength: utf8.encode(text).length,
      provenance: <String, dynamic>{
        'method': 'local_ocr',
        'documentSha256': material.documentSha256,
        'pages': material.pages.length,
        'engine': material.engine,
        'engineVersion': material.engineVersion,
        'languages': material.languages,
        'dpi': material.dpi,
        'flaggedFields': material.flaggedFields.length,
        'reviewedPages':
            material.pages.where((p) => p.reviewedText != null).length,
        if (materialRelativePath != null) 'materialFile': materialRelativePath,
        'createdAt': material.createdAt.toUtc().toIso8601String(),
      },
    );
    final targetId = _conversation?.id;
    final latest = targetId == null
        ? _conversation
        : (_cache[targetId] ??
            (targetId == _conversation?.id ? _conversation : null));
    if (targetId != null && latest == null) {
      return 'OCR 完成时会话已被关闭或删除，未加入材料';
    }
    final conversation = latest ?? await ensureConversation();
    if (_disposed) return '应用已关闭';
    await store.saveAttachment(attachment);
    final current = _cache[conversation.id] ?? conversation;
    final updated = current.copyWith(
      attachments: [...current.attachments, attachment],
      updatedAt: DateTime.now(),
      activityAt: DateTime.now(),
    );
    _cache[conversation.id] = updated;
    if (_conversation?.id == conversation.id) _conversation = updated;
    await store.saveConversation(updated);
    _errorMessage = null;
    _notify();
    return null;
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

  // ------------------------------------------------- execution (0.2.3 R3-E)

  /// 执行计时控制器；null = 本构建/本环境未启用执行计时。
  TimerController? get executionTimer => timer;

  bool get executionAvailable => timer != null;

  /// 全部执行记录（只读；已删除记录仍在账本里，由统计口径决定是否计入）。
  List<ExecutionRecord> get executionRecords =>
      timer?.ledger.records ?? const <ExecutionRecord>[];

  /// 某任务在当前查看版本里的执行引用；找不到返回 null（不猜、不跨会话搬移）。
  ExecutionTaskRef? executionRefFor(String taskId) {
    final v = _viewVersion;
    final conv = _conversation;
    if (v == null || conv == null || taskId.isEmpty) return null;
    TaskRecord? task;
    for (final t in v.tasks) {
      if (t.id == taskId) {
        task = t;
        break;
      }
    }
    if (task == null) return null;
    return ExecutionTaskRef(
      conversationId: conv.id,
      taskId: task.id,
      taskName: task.name,
      planVersionId: v.id,
      planRevision: v.revision,
      estimateHours: task.estimatedHours,
      lineageRootId: task.previousTaskId ?? task.id,
    );
  }

  /// 开始计时。返回 null = 成功；否则是用户可读的失败原因。
  Future<String?> startTaskTimer(String taskId) async {
    final t = timer;
    if (t == null) return '执行计时不可用（未启用计时服务）';
    final ref = executionRefFor(taskId);
    if (ref == null) return '当前视图里找不到这个任务，未开始计时';
    final result = await t.start(ref);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  Future<String?> pauseTaskTimer() async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.pause();
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  Future<String?> resumeTaskTimer() async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.resume();
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  /// 停止本次计时并确认本次会话时长（不改变任务完成状态）。
  Future<String?> stopTaskTimer() async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.stopAndConfirm();
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  /// 手工补记预校验（不写盘）。[taskId] 必须能在当前视图里解析。
  Future<ManualEntryValidation> previewManualEntryForTask(
      String taskId, ManualEntryDraft draft) async {
    final t = timer;
    final ref = executionRefFor(taskId);
    if (t == null || ref == null) {
      return const ManualEntryValidation(
        ok: false,
        message: '当前视图里找不到这个任务，无法补记',
        durationSeconds: 0,
      );
    }
    return t.previewManualEntry(ref, draft);
  }

  /// 写入手工补记；返回 null = 成功，否则失败原因。
  Future<String?> addManualEntryForTask(
      String taskId, ManualEntryDraft draft) async {
    final t = timer;
    final ref = executionRefFor(taskId);
    if (t == null || ref == null) return '当前视图里找不到这个任务，无法补记';
    final result = await t.addManualEntry(ref, draft);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  Future<String?> removeManualEntry(String recordId, String entryId) async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.removeManualEntry(recordId, entryId);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  /// 删除/恢复一条执行记录（保留修订，可撤销）。
  Future<String?> setExecutionRecordDeleted(String recordId,
      {required bool deleted}) async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.setRecordDeleted(recordId, deleted: deleted);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  Future<String?> revertExecutionRecord(String recordId) async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result = await t.revertRecord(recordId);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  /// 处理待校正区间（离开/睡眠等不确定时间）。
  Future<String?> resolveExecutionCorrection(
    String correctionId,
    CorrectionDecision decision, {
    Duration? custom,
  }) async {
    final t = timer;
    if (t == null) return '执行计时不可用';
    final result =
        await t.resolveCorrection(correctionId, decision, custom: custom);
    _statusMessage = result.message;
    _notify();
    return result.ok ? null : result.message;
  }

  /// 窗口/电源生命周期钩子：应用被挂起/锁屏/睡眠前调用。
  Future<void> onAppSuspended() async {
    final t = timer;
    if (t == null) return;
    final result = await t.handleAwayDetected();
    if (result.ok) _statusMessage = result.message;
    _notify();
  }

  Future<void> onAppResumed() async {
    final t = timer;
    if (t == null) return;
    final result = await t.handleResumeFromAway();
    if (result.ok) _statusMessage = result.message;
    _notify();
  }

  /// 当前查看版本的任务上下文（报告/详情卡用）。
  Map<String, ExecutionTaskInfo> executionTaskContext() {
    final v = _viewVersion;
    final conv = _conversation;
    if (v == null || conv == null) return const <String, ExecutionTaskInfo>{};
    final out = <String, ExecutionTaskInfo>{};
    for (final t in v.tasks) {
      out[t.id] = ExecutionTaskInfo(
        conversationId: conv.id,
        taskId: t.id,
        name: t.name,
        planVersionId: v.id,
        planRevision: v.revision,
        currentEstimateHours: t.estimatedHours,
        completion: t.completion,
        deadline: t.deadline,
        lineageRootId: t.previousTaskId ?? t.id,
      );
    }
    return out;
  }

  /// 某个任务的执行事实汇总；未知返回 null（不是 0）。
  TaskEffort? executionTaskEffort(String taskId) {
    final aggregate = aggregateEffort(
      records: executionRecords,
      taskContext: executionTaskContext(),
    );
    for (final t in aggregate.tasks) {
      if (t.taskId == taskId) return t;
    }
    return null;
  }

  /// 偏差回顾：按时间范围（UTC 边界）聚合执行事实。
  ///
  /// [conversationId] 为 null 时汇总全部会话；任务上下文来自当前已加载的会话，
  /// 其它会话的记录会以“未归属历史记录”出现而不是被丢弃。
  EffortAggregate executionReview({
    required DateTime fromUtc,
    required DateTime toUtc,
    String? conversationId,
  }) {
    final records = executionRecords
        .where((r) =>
            conversationId == null || r.conversationId == conversationId);
    return aggregateEffort(
      records: records,
      taskContext: executionTaskContext(),
      fromUtc: fromUtc,
      toUtc: toUtc,
    );
  }

  /// 写 CSV 回顾导出；返回 null = 成功，否则失败原因。不导出密钥/材料原文。
  Future<String?> exportEffortCsv({
    required String path,
    required EffortAggregate aggregate,
    required DateTime fromUtc,
    required DateTime toUtc,
    required String rangeLabel,
    String? conversationId,
  }) async {
    final csv = buildEffortCsv(
      aggregate: aggregate,
      fromUtc: fromUtc,
      toUtc: toUtc,
      rangeLabel: rangeLabel,
    );
    return writeEffortCsv(path: path, csv: csv);
  }

  /// 写入已经生成好的 CSV（回顾对话框自己按当前范围/过滤条件生成内容）。
  ///
  /// 返回 null = 成功。写入 UTF-8 字节（内容若已带 BOM 则原样保留），
  /// 不改动任何材料/会话数据。
  Future<String?> writeEffortCsv({required String path, required String csv}) async {
    try {
      var text = csv;
      if (!text.startsWith('\uFEFF')) text = '\uFEFF$text';
      final bytes = utf8.encode(text);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      _statusMessage = '已导出回顾 CSV：$path';
      _notify();
      return null;
    } catch (e) {
      return '导出失败：$e';
    }
  }

  /// 完成/撤销完成事件与真实计划状态保持同步（不写实际耗时）。
  Future<void> _syncCompletionEvents(
      PlanVersion? previous, PlanVersion next) async {
    final t = timer;
    final conv = _conversation;
    if (t == null || conv == null) return;
    final before = <String, Completion>{
      for (final task in previous?.tasks ?? const <TaskRecord>[])
        task.id: task.completion,
    };
    final after = <String, Completion>{for (final task in next.tasks) task.id: task.completion};
    for (final entry in after.entries) {
      final was = before[entry.key];
      final isDone = entry.value == Completion.done;
      final wasDone = was == Completion.done;
      if (isDone && !wasDone) {
        await t.recordTaskCompletion(
          conversationId: conv.id,
          taskId: entry.key,
          planVersionId: next.id,
          planRevision: next.revision,
        );
      } else if (!isDone && wasDone) {
        await t.undoTaskCompletion(entry.key);
      }
    }
  }

  // ------------------------------------------------- chunked analysis (R3-L)

  static const AnalysisLimits _chunkedLimits =
      AnalysisLimits(maxConcurrentRequests: 1);

  bool _chunkedRunning = false;
  bool _chunkedCancelRequested = false;
  ChunkedCoordinator? _chunkedCoordinator;
  ChunkedJob? _chunkedJob;
  ModelSelection? _chunkedSelection;

  bool get chunkedAnalysisRunning => _chunkedRunning;

  /// 分块分析预估（不发起任何模型请求）；材料为空/参数不合法时返回 null。
  ChunkedEstimateView? describeChunkedAnalysis() {
    final prepared = _prepareChunkedInputs(resolveSelection: false);
    final spec = prepared.spec;
    if (spec == null) return null;
    try {
      final coordinator = ChunkedCoordinator(
        spec: spec,
        limits: _chunkedLimits,
        transport: PlanChunkTransport(sendPlan: (_) async => null).call,
      );
      return ChunkedEstimateView.fromEstimate(
        estimate: coordinator.estimate(),
        materialBytes: prepared.materialBytes,
        singleRequestUtf8Bytes: engine.info.maxInputBytes,
        documentCount: prepared.documentCount,
      );
    } catch (e) {
      return null;
    }
  }

  /// 分块分析：分块抽取 → 本地校验归一 → 有界归并 → 预览 → 本地校验后提交。
  ///
  /// [onProgress] 会在每个 wave 的关键节点被调用（不阻塞 UI）。
  /// 返回结果明确区分“已提交”“部分处理未提交”“失败/取消”。
  Future<ChunkedRunResult> startChunkedAnalysis({
    void Function(JobProgress progress)? onProgress,
  }) async {
    if (_chunkedRunning) {
      return const ChunkedRunResult(ok: false, message: '已有分块分析在进行中');
    }
    if (_run != null) {
      return const ChunkedRunResult(
          ok: false, message: '普通分析进行中，无法开始分块分析');
    }
    final gw = gateway;
    if (gw == null) {
      return const ChunkedRunResult(ok: false, message: '原生桥接不可用，无法发起分块分析');
    }
    var c = await ensureConversation();
    if (_disposed) {
      return const ChunkedRunResult(ok: false, message: '应用已关闭');
    }
    final version = c.currentVersion;
    final draft = c.draftText.trim();
    if (draft.isEmpty && c.attachments.isEmpty && !hasRequestTimetable) {
      return const ChunkedRunResult(
          ok: false, message: '请先粘贴材料、添加文件，或先设置时间表');
    }

    final prepared = _prepareChunkedInputs(resolveSelection: true);
    if (prepared.error != null || prepared.spec == null) {
      return ChunkedRunResult(
          ok: false, message: prepared.error ?? '分块分析参数不合法');
    }
    final spec = prepared.spec!;
    final selection = prepared.selection;
    if (prepared.migratedSelection != null && c.modelSelection == null) {
      c = c.copyWith(modelSelection: prepared.migratedSelection);
      _conversation = c;
      _cache[c.id] = c;
      await store.saveConversation(c);
      _reindexSummaries();
    }

    final requestTimetable = c.includeTimetable ? requestTimetableFor(c, version) : null;
    final requestExternalFingerprint = externalFingerprintFor(c);
    final requestExternalRefs = _externalSourceRefs(c);
    final requestId = IdGenerator.next('req');
    RequestTicket ticket;
    try {
      ticket = gate.begin(
        conversationId: c.id,
        requestId: requestId,
        baseVersionId: version?.id,
        baseRevision: version?.revision ?? 0,
        calendarRevision: requestTimetable?.revision ?? -1,
      );
    } on StateError catch (e) {
      return ChunkedRunResult(ok: false, message: e.message);
    }

    // 与普通分析一致：先写入 pending 占位，避免崩溃后留下“幽灵锁”。
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

    final coordinator = ChunkedCoordinator(
      spec: spec,
      limits: _chunkedLimits,
      transport: PlanChunkTransport(sendPlan: _sendChunkPlan).call,
    );
    late final ChunkedJob job;
    try {
      job = coordinator.createJob();
    } catch (e) {
      gate.finish(ticket);
      await _clearPending();
      return ChunkedRunResult(ok: false, message: '分块作业创建失败：$e');
    }

    _chunkedCoordinator = coordinator;
    _chunkedJob = job;
    _chunkedSelection = selection;
    _chunkedRunning = true;
    _chunkedCancelRequested = false;
    _errorMessage = null;
    _statusMessage = '分块分析开始：${job.progress.chunksTotal} 块';
    _notify();

    final progressTimer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 150), (_) {
            if (_disposed) return;
            onProgress(job.progress);
          });
    final watch = Stopwatch()..start();
    ChunkedJobOutcome? outcome;
    try {
      outcome = await coordinator.run(job);
    } catch (e) {
      return ChunkedRunResult(ok: false, message: '分块分析失败：$e');
    } finally {
      progressTimer?.cancel();
      _chunkedRunning = false;
      _chunkedCoordinator = null;
      _chunkedJob = null;
      _chunkedSelection = null;
      _chunkedCancelRequested = false;
      _notify();
    }
    watch.stop();

    if (_chunkedCancelRequested || job.isCancelled) {
      gate.finish(ticket);
      await _clearPending();
      _statusMessage = '分块分析已取消（已完成的本地阶段保留，不自动重发）';
      _notify();
      return ChunkedRunResult(
        ok: false,
        message: _statusMessage!,
        blockers: outcome.blockers,
      );
    }

    final blockers = outcome.blockers;
    final preview = outcome.preview;
    final factsCount = outcome.ledger?.facts.length ?? 0;
    final pendingCount = outcome.ledger?.pendingConfirmations().length ?? 0;
    final coverageLines = preview?.coverage.documents
            .map((d) => d.totalPages > 0
                ? '${d.label}: ${d.coveredPages.length}/${d.totalPages} 页、'
                    '${d.coveredSegments}/${d.totalSegments} 段'
                : '${d.label}: ${d.coveredSegments}/${d.totalSegments} 段')
            .toList(growable: false) ??
        const <String>[];
    if (!outcome.officialPlanAvailable || outcome.officialPlanJson == null) {
      gate.finish(ticket);
      await _clearPending();
      final message = outcome.message.isEmpty
          ? '材料未完整处理，未生成正式计划'
          : outcome.message;
      _errorMessage = message;
      _statusMessage = blockers.isEmpty ? message : '$message；${blockers.first}';
      _notify();
      return ChunkedRunResult(
        ok: false,
        message: _statusMessage!,
        partial: preview?.partial ?? true,
        blockers: blockers,
        pendingConfirmations: pendingCount,
        factsCount: factsCount,
        coverageLines: coverageLines,
      );
    }

    // 正式提交：与普通分析同一条本地校验/版本提交路径（C 校验 + reconcile）。
    final planJson = outcome.officialPlanJson!;
    await _commitResult(
      ticket,
      AnalyzeOutcome(
        ok: true,
        plan: planJson,
        elapsedMs: watch.elapsedMilliseconds,
        httpStatus: 200,
      ),
      draft,
      externalFingerprint: requestExternalFingerprint,
      externalSourcesRef: requestExternalRefs,
    );
    gate.finish(ticket);
    await _clearPending();
    final committed = _conversation?.currentVersion?.id;
    final message = (planJson['partial'] == true)
        ? '分块结果不完整，已拒绝提交'
        : '分块分析完成，已生成计划版本';
    _statusMessage = message;
    _notify();
    return ChunkedRunResult(
      ok: planJson['partial'] != true,
      message: _statusMessage!,
      committedPlanVersionId: committed,
      partial: planJson['partial'] == true,
      blockers: blockers,
      pendingConfirmations: pendingCount,
      factsCount: factsCount,
      coverageLines: coverageLines,
    );
  }

  void cancelChunkedAnalysis() {
    final job = _chunkedJob;
    final coordinator = _chunkedCoordinator;
    if (job == null || coordinator == null) return;
    _chunkedCancelRequested = true;
    _statusMessage = '正在取消分块分析（迟到结果会被丢弃）';
    coordinator.cancel(job);
    _notify();
  }

  /// 分块请求的 transport：复用原生 analyze 通道；每个块是一个独立请求。
  Future<Map<String, dynamic>?> _sendChunkPlan(ChunkRequest request) async {
    final gw = gateway;
    if (gw == null) throw StateError('原生桥接不可用');
    if (_chunkedCancelRequested) throw StateError('分块作业已取消');
    final nativeJob = gw.analyzeAsync(
      request.payload,
      modelSelection: _chunkedSelection,
    );
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (true) {
        if (_disposed || _chunkedCancelRequested) {
          gw.cancel(nativeJob);
          throw StateError('分块作业已取消');
        }
        final poll = gw.poll(nativeJob);
        if (poll.terminal) {
          final outcome = gw.result(nativeJob);
          if (outcome == null) return null;
          if (!outcome.ok) {
            throw StateError(outcome.error ?? '模型请求失败（${outcome.errorKind ?? 'unknown'}）');
          }
          return outcome.plan;
        }
        if (DateTime.now().isAfter(deadline)) {
          gw.cancel(nativeJob);
          throw StateError('分块请求超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      try {
        gw.release(nativeJob);
      } catch (_) {
        // 释放失败不影响结果；桥接关闭时统一清理。
      }
    }
  }

  /// 组装分块作业参数（材料、时间表快照、稳定基线）。
  ({AnalysisJobSpec? spec, ModelSelection? selection, ModelSelection? migratedSelection, String? error, int materialBytes, int documentCount})
      _prepareChunkedInputs({required bool resolveSelection}) {
    final c = _conversation;
    final version = _viewVersion ?? c?.currentVersion;
    if (c == null) {
      return (
        spec: null,
        selection: null,
        migratedSelection: null,
        error: '还没有会话',
        materialBytes: 0,
        documentCount: 0,
      );
    }
    final draft = c.draftText.trim();
    final documents = <SourceDocument>[];
    if (draft.isNotEmpty) {
      documents.add(_sourceDocumentFromText(
        draft,
        label: '文段1',
        kind: 'text',
      ));
    }
    for (final attachment in c.attachments) {
      final text = attachment.text.trim();
      if (text.isEmpty) continue;
      documents.add(_sourceDocumentFromText(
        text,
        label: attachment.label,
        kind: attachment.kind == 'file' ? 'file' : 'text',
        fromOcr: attachment.kind == 'ocr',
      ));
    }
    if (documents.isEmpty && !hasRequestTimetable) {
      return (
        spec: null,
        selection: null,
        migratedSelection: null,
        error: '没有可分析的文本材料',
        materialBytes: 0,
        documentCount: 0,
      );
    }
    final materialBytes = documents.fold<int>(
        0, (sum, doc) => sum + doc.sourceFileBytes);
    final requestTimetable =
        c.includeTimetable ? requestTimetableFor(c, version) : null;
    Map<String, dynamic>? effectiveTimetable;
    if (requestTimetable != null) {
      try {
        effectiveTimetable = deriveEffectiveTimetable(requestTimetable);
      } on TimetableRequestException catch (e) {
        return (
          spec: null,
          selection: null,
          migratedSelection: null,
          error: '时间表数据不合法，未开始分块分析：${e.message}',
          materialBytes: materialBytes,
          documentCount: documents.length,
        );
      }
    }
    ModelSelection? selection;
    ModelSelection? migrated;
    final settings = this.settings;
    if (resolveSelection && settings != null) {
      final resolution = settings.resolveSelectionForRequest(c);
      if (resolution.error != null) {
        return (
          spec: null,
          selection: null,
          migratedSelection: null,
          error: resolution.error,
          materialBytes: materialBytes,
          documentCount: documents.length,
        );
      }
      selection = resolution.selection;
      if (resolution.migrated && selection != null && c.modelSelection == null) {
        migrated = selection;
      }
    } else if (settings != null) {
      selection = c.modelSelection ?? settings.defaultSelection;
    }

    final externalSources = <Map<String, dynamic>>[
      for (final source in _externalSourceRefs(c))
        <String, dynamic>{
          'id': source.id,
          'revision': source.revision,
          'dateFrom': source.dateFrom,
          'dateTo': source.dateTo,
        },
    ];
    final knownTasks = <Map<String, dynamic>>[
      for (final task in version?.tasks ?? const <TaskRecord>[])
        if (!task.isDone)
          <String, dynamic>{
            'id': task.id,
            'title': task.name,
            'estimatedMinutes': task.estimatedHours == null
                ? null
                : (task.estimatedHours! * 60).round(),
          },
    ];
    final userRequest = draft.isEmpty
        ? '请依据材料生成完整的任务计划；材料中的明确要求、约束与依赖必须保留。'
        : (draft.length <= 800
            ? draft
            : '请依据以下材料生成完整的任务计划；材料中的明确要求、约束与依赖必须保留。');
    final timetableJson = requestTimetable?.toJson();
    return (
      spec: AnalysisJobSpec(
        conversationId: c.id,
        userRequest: userRequest,
        asOf: DateTime.now(),
        timeZoneId: requestTimetable?.timezoneId ?? calendar.settings.timezoneId,
        timezoneOffsetMinutes: requestTimetable?.timezoneOffsetMinutes ??
            calendar.settings.timezoneOffsetMinutes,
        baseVersionId: version?.id,
        baseRevision: version?.revision ?? 0,
        calendarRevision:
            requestTimetable?.revision ?? version?.timetable?.revision ?? 0,
        planContext: version == null ? null : _buildPlanContext(version),
        knownTasks: knownTasks,
        timetableJson: timetableJson,
        effectiveTimetableJson: effectiveTimetable,
        externalSources: externalSources,
        modelSelection: selection?.toJson(),
        modelConfigSignature: selection == null
            ? ''
            : '${selection.profileId}@${selection.profileRevision}/${selection.modelId}',
        documents: documents,
      ),
      selection: selection,
      migratedSelection: migrated,
      error: null,
      materialBytes: materialBytes,
      documentCount: documents.length,
    );
  }

  /// 把附件/草稿文本转成带稳定片段 ID 的文档（PDF 页标记优先作为页号）。
  SourceDocument _sourceDocumentFromText(
    String text, {
    required String label,
    required String kind,
    bool fromOcr = false,
  }) {
    final bytes = utf8.encode(text);
    final hash = sha256.convert(bytes).toString();
    final segments = <SourceSegment>[];
    var index = 0;
    // 现有 PDF 提取器用 `【第 N 页】` 标记页；把它还原成页号，覆盖清单才有意义。
    final pagePattern = RegExp(r'【第\s*(\d+)\s*(?:页|张幻灯片|段)】');
    final matches = pagePattern.allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      for (final paragraph in text.split(RegExp(r'\n\s*\n'))) {
        final trimmed = paragraph.trim();
        if (trimmed.isEmpty) continue;
        segments.add(SourceSegment.create(
          docHash: hash,
          page: 0,
          index: index++,
          text: trimmed,
          location: label,
          fromOcr: fromOcr,
        ));
      }
    } else {
      for (var i = 0; i < matches.length; i++) {
        final page = int.tryParse(matches[i].group(1) ?? '') ?? 0;
        final start = matches[i].end;
        final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
        final body = text.substring(start, end).trim();
        if (body.isEmpty) continue;
        segments.add(SourceSegment.create(
          docHash: hash,
          page: page <= 0 ? 0 : page,
          index: index++,
          text: body,
          location: '第 $page 页',
          fromOcr: fromOcr,
        ));
      }
    }
    if (segments.isEmpty) {
      segments.add(SourceSegment.create(
        docHash: hash,
        page: 0,
        index: 0,
        text: text.trim(),
        location: label,
        fromOcr: fromOcr,
      ));
    }
    return SourceDocument(
      docHash: hash,
      label: label,
      kind: kind,
      segments: segments,
      sourceFileBytes: bytes.length,
      fromOcr: fromOcr,
    );
  }

  // ------------------------------------------------------- external calendar

  /// 外部日历集合指纹（全局启用来源）；服务不可用时为空串（= 0.2.1 行为）。
  ///
  /// 迟到结果的实际判定请用会话级 [externalFingerprintFor]：只有该会话**实际
  /// 关联并使能**的来源变化才应让结果过期（无关来源的导入/改名不应打断分析）。
  String get externalFingerprint => externalCalendar?.fingerprint ?? '';

  /// 某会话实际关联来源集合的指纹（顺序无关，跳过停用/不存在的来源）。
  ///
  /// 服务不可用时返回空串（与 [externalFingerprint] 一致）。空集合返回 T-C 的
  /// 稳定哈希（非空），因此“关联来源从无到有”也会被识别为变化。
  String externalFingerprintFor(Conversation conversation) {
    final service = externalCalendar;
    if (service == null) return '';
    return service.fingerprintOf(_enabledExternalSourceIds(conversation));
  }

  /// 迟到结果的外部日历一致性判断：指纹相同（或都没有服务）才可用。
  static String? externalCalendarStaleMessage(
      String requestedFingerprint, String currentFingerprint) {
    if (requestedFingerprint == currentFingerprint) return null;
    return '外部日历在分析期间已更新（来源或内容发生变化），本次结果未应用；'
        '请用最新日历重新分析';
  }

  /// 会话**实际生效**的外部来源 id：先看会话关联，再过滤到“存在且启用”。
  ///
  /// 返回空集合 = 不启用外部日历（0.2.1 旧数据、或来源被停用/删除）。
  Set<String> externalSourceIdsForConversation(String conversationId) {
    final c = _cache[conversationId] ??
        (_conversation?.id == conversationId ? _conversation : null);
    if (c == null) return const <String>{};
    return _enabledExternalSourceIds(c);
  }

  /// 当前会话实际生效的外部来源 id（界面/对话框只读展示用）。
  Set<String> get currentExternalSourceIds {
    final c = _conversation;
    if (c == null) return const <String>{};
    return _enabledExternalSourceIds(c);
  }

  /// 会话级外部来源关联写入口（持久化到 `Conversation.externalSourceIds`）。
  ///
  /// 只保存合成 id，不保存任何事件内容；未知 id 会被保留（恢复备份时服务可能
  /// 尚未加载，真正的生效过滤发生在 [externalSourceIdsForConversation]）。
  Future<bool> setExternalSourcesForConversation(
      String conversationId, Iterable<String> sourceIds) async {
    final c = await _loadFor(conversationId);
    if (c == null) return false;
    final next = <String>{
      for (final raw in sourceIds)
        if (raw.trim().isNotEmpty) raw.trim(),
    };
    final current = c.externalSourceIds;
    if (next.length == current.length && next.containsAll(current)) return true;
    final updated = c.copyWith(
      externalSourceIds: Set<String>.unmodifiable(next),
      updatedAt: DateTime.now(),
      activityAt: DateTime.now(),
    );
    _cache[updated.id] = updated;
    if (_conversation?.id == updated.id) _conversation = updated;
    await store.saveConversation(updated);
    _notify();
    return true;
  }

  Set<String> _enabledExternalSourceIds(Conversation conversation) {
    final service = externalCalendar;
    final wanted = conversation.externalSourceIds;
    if (service == null || wanted.isEmpty) return const <String>{};
    final out = <String>{};
    for (final source in service.sources) {
      if (source.enabled && wanted.contains(source.id)) out.add(source.id);
    }
    return out.isEmpty ? const <String>{} : Set<String>.unmodifiable(out);
  }

  /// 请求发出时使用的来源快照引用（只含 id/revision/hash/范围）。
  List<ExternalCalendarSourceRef> _externalSourceRefs(
      Conversation conversation) {
    final service = externalCalendar;
    if (service == null) return const <ExternalCalendarSourceRef>[];
    final ids = _enabledExternalSourceIds(conversation);
    if (ids.isEmpty) return const <ExternalCalendarSourceRef>[];
    final out = <ExternalCalendarSourceRef>[];
    for (final source in service.sources) {
      if (!ids.contains(source.id)) continue;
      out.add(ExternalCalendarSourceRef(
        id: source.id,
        revision: source.revision,
        contentHash: source.contentHash,
        dateFrom: source.dateFrom,
        dateTo: source.dateTo,
      ));
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return List<ExternalCalendarSourceRef>.unmodifiable(out);
  }

  /// 请求/排程使用的**合成**时间表快照：手工权威时间表 + 外部忙碌（只读）。
  ///
  /// [version] 为空时使用会话草稿。没有外部来源、没有忙碌时返回手工时间表本身
  /// （同一对象），从而保证 0.2.1 行为与请求形状完全不变。
  Timetable? requestTimetableFor(
      Conversation conversation, PlanVersion? version) {
    final manual = version?.timetable ?? conversation.calendarDraft;
    if (manual == null) return null;
    return _composeTimetable(conversation, manual);
  }

  /// 当前查看版本用于冲突/排程展示的合成快照（settings 追加外部占用）。
  ///
  /// 没有外部忙碌时返回 [PlanVersion.calendar] 本身；结果**不落盘**。
  CalendarSchedule calendarWithExternalBusy(
    PlanVersion version, {
    Conversation? conversation,
  }) {
    final c = conversation ?? _conversation;
    if (c == null) return version.calendar;
    final settings = version.calendar.settings;
    final busy = _externalBusyForRange(
      conversation: c,
      dateFrom: _settingsDateFrom(settings),
      dateTo: _settingsDateTo(settings),
      timezoneId: settings.timezoneId,
    );
    if (busy.isEmpty) return version.calendar;
    return version.calendar.copyWith(
      settings: composeExternalSettings(base: settings, busy: busy),
    );
  }

  /// 当前查看版本的合成排程快照；没有版本时为 null。
  CalendarSchedule? get currentCalendarSchedule {
    final v = _viewVersion;
    if (v == null) return null;
    return calendarWithExternalBusy(v);
  }

  /// 某会话在 [dateFrom, dateTo] 内的外部忙碌实例（只读展示用）。
  ///
  /// 交给时间表网格画斜纹：只含 `dayKey/startMinute/endMinute` 与来源 id，
  /// **[ExternalBusyInstance] 不携带事件标题**，因此不会泄露外部日历内容。
  List<ExternalBusyInstance> externalBusyInRange({
    required String dateFrom,
    required String dateTo,
    String? conversationId,
    String? timezoneId,
  }) {
    final id = conversationId ?? _conversation?.id;
    if (id == null) return const <ExternalBusyInstance>[];
    final c = _cache[id] ??
        (_conversation?.id == id ? _conversation : null);
    if (c == null) return const <ExternalBusyInstance>[];
    return _externalBusyForRange(
      conversation: c,
      dateFrom: dateFrom,
      dateTo: dateTo,
      timezoneId: timezoneId ?? currentTimetable().timezoneId,
    );
  }

  Timetable _composeTimetable(Conversation conversation, Timetable manual) {
    final range = _busyRangeForTimetable(conversation, manual);
    final busy = _externalBusyForRange(
      conversation: conversation,
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
    );
    if (busy.isEmpty) return manual;
    return composeExternalBusy(
      manual: manual,
      busy: busy,
      timezoneId: manual.timezoneId,
    );
  }

  List<ExternalBusyInstance> _externalBusyForRange({
    required Conversation conversation,
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
  }) {
    final service = externalCalendar;
    if (service == null) return const <ExternalBusyInstance>[];
    final ids = _enabledExternalSourceIds(conversation);
    if (ids.isEmpty) return const <ExternalBusyInstance>[];
    if (parseDateKey(dateFrom) == null || parseDateKey(dateTo) == null) {
      return const <ExternalBusyInstance>[];
    }
    return service.busyFor(
      sourceIds: ids,
      dateFrom: dateFrom,
      dateTo: dateTo,
      timezoneId: timezoneId,
    );
  }

  /// 外部忙碌查询范围：手工 coverage ∪ 已关联来源的导入范围。
  ///
  /// 请求的 effectiveTimetable 最多 400 天；并集超限时退回手工 coverage
  /// （请求只覆盖该范围，外部忙碌在覆盖范围内仍然生效，不在范围内本来就不发送）。
  ({String from, String to}) _busyRangeForTimetable(
      Conversation conversation, Timetable manual) {
    var from = manual.dateFrom;
    var to = manual.dateTo;
    var extended = false;
    final wanted = conversation.externalSourceIds;
    for (final source in externalCalendar?.sources ??
        const <ExternalCalendarSource>[]) {
      if (!wanted.contains(source.id) || !source.enabled) continue;
      final sourceFrom = parseDateKey(source.dateFrom);
      final sourceTo = parseDateKey(source.dateTo);
      if (sourceFrom == null || sourceTo == null) continue;
      if (sourceFrom.compareTo(from) < 0) {
        from = sourceFrom;
        extended = true;
      }
      if (sourceTo.compareTo(to) > 0) {
        to = sourceTo;
        extended = true;
      }
    }
    if (!extended) return (from: manual.dateFrom, to: manual.dateTo);
    if (dateKeySpanDays(from, to) > 400) {
      return (from: manual.dateFrom, to: manual.dateTo);
    }
    return (from: from, to: to);
  }

  /// 排程/冲突用的 settings：在手工 settings 上追加外部占用（运行时）。
  CalendarSettings _settingsWithExternalBusy(
    CalendarSettings settings, {
    Conversation? conversation,
  }) {
    final c = conversation ?? _conversation;
    if (c == null) return settings;
    final busy = _externalBusyForRange(
      conversation: c,
      dateFrom: _settingsDateFrom(settings),
      dateTo: _settingsDateTo(settings),
      timezoneId: settings.timezoneId,
    );
    if (busy.isEmpty) return settings;
    return composeExternalSettings(base: settings, busy: busy);
  }

  static String _settingsDateFrom(CalendarSettings settings) {
    final start = parseDateKey(settings.planningStartDate);
    return start ?? settings.planningStartDate;
  }

  static String _settingsDateTo(CalendarSettings settings) {
    final start = parseDateKey(settings.planningStartDate);
    if (start == null) return settings.planningStartDate;
    final days = settings.planningDays < 1 ? 1 : settings.planningDays;
    return addDaysToDateKey(start, days - 1);
  }

  // -------------------------------------------------------------- analysis

  /// 构造正式分析请求。独立成方法，测试可以直接断言请求形状而不启动网络。
  ///
  /// 时间表同时发送权威规则（timetable）与同一快照的派生日期区间
  /// （effectiveTimetable）；派生失败时两份都不发送，由 [validateTimetableForRequest]
  /// 在开始请求前给出明确错误，绝不把不完整数据交给模型。
  Map<String, dynamic> buildAnalysisRequest({
    required Conversation conversation,
    required PlanVersion? version,
    required String requestId,
    required String draft,
    String? planContext,
  }) {
    final clock = (version?.calendar.settings ?? calendar.settings).clock;
    final wallNow = clock.toWall(DateTime.now());
    // timetable / effectiveTimetable / calendarRevision 必须来自**同一份**快照：
    // 这里是运行时合成快照（手工时间表 + 外部忙碌）。C 侧会逐分钟校验两份视图
    // 同源，因此不能只替换其中一份。
    final requestTimetable = conversation.includeTimetable
        ? requestTimetableFor(conversation, version)
        : null;
    Map<String, dynamic>? effectiveTimetable;
    if (requestTimetable != null) {
      try {
        effectiveTimetable = deriveEffectiveTimetable(requestTimetable);
      } on TimetableRequestException {
        effectiveTimetable = null;
      }
    }
    final externalSources = _externalSourceRefs(conversation);
    return <String, dynamic>{
      'requestSchemaVersion': 2,
      'conversationId': conversation.id,
      'requestId': requestId,
      'baseVersionId': version?.id,
      'baseRevision': version?.revision ?? 0,
      'calendarRevision':
          requestTimetable?.revision ?? version?.timetable?.revision ?? 0,
      'context': <String, dynamic>{
        'currentDate': WallClock.formatDateKey(
            wallNow.year, wallNow.month, wallNow.day),
        'timezoneId':
            requestTimetable?.timezoneId ?? calendar.settings.timezoneId,
        'timezoneOffsetMinutes': requestTimetable?.timezoneOffsetMinutes ??
            calendar.settings.timezoneOffsetMinutes,
        // 只有真正启用了外部来源时才加这个键：0.2.1 旧数据的请求形状保持不变。
        // 内容只有合成 id/revision/范围，不含标题、路径或事件内容。
        if (externalSources.isNotEmpty)
          'externalSources': <Map<String, dynamic>>[
            for (final source in externalSources)
              <String, dynamic>{
                'id': source.id,
                'revision': source.revision,
                'dateFrom': source.dateFrom,
                'dateTo': source.dateTo,
              },
          ],
      },
      'userRequest': draft,
      'planContext': planContext,
      if (requestTimetable != null && effectiveTimetable != null) ...{
        'timetable': requestTimetable.toJson(),
        'effectiveTimetable': effectiveTimetable,
      },
      if (version != null)
        'knownTasks': <Map<String, dynamic>>[
          for (final t in version.tasks)
            if (!t.isDone)
              <String, dynamic>{
                'id': t.id,
                'title': t.name,
                'estimatedMinutes': t.estimatedHours == null
                    ? null
                    : (t.estimatedHours! * 60).round(),
              },
        ],
      'sources': <Map<String, dynamic>>[
        if (draft.isNotEmpty)
          {'kind': 'text', 'label': '文段1', 'text': draft},
        for (final a in conversation.attachments)
          if (a.kind == 'file' && a.originalPath != null)
            {'kind': 'file', 'path': a.originalPath}
          else
            {'kind': 'text', 'label': a.label, 'text': a.text},
        if (draft.isEmpty &&
            conversation.attachments.isEmpty &&
            requestTimetable != null)
          {
            'kind': 'text',
            'label': '时间表',
            'text': '（本次请求仅含已提交的结构化时间表，没有额外文字材料。）',
          },
      ],
    };
  }

  /// 请求前置校验：非法时间表必须明确失败，而不是省略后继续当“没有约束”排程。
  String? validateTimetableForRequest(Timetable? timetable) {
    if (timetable == null) return null;
    try {
      deriveEffectiveTimetable(timetable);
      return null;
    } on TimetableRequestException catch (e) {
      return '时间表数据不合法，未发送请求：${e.message}';
    }
  }

  /// 是否有会随请求发送的已提交时间表（空会话草稿也算）。
  bool get hasRequestTimetable {
    final c = _conversation;
    if (c == null || !c.includeTimetable) return false;
    return (_viewVersion?.timetable ?? c.calendarDraft) != null;
  }

  Future<void> startAnalysis() async {
    if (_run != null) return;
    // Sending from a brand-new session must work without clicking "新建会话" first.
    var c = await ensureConversation();
    if (_disposed) return;
    final version = c.currentVersion;
    final draft = c.draftText.trim();
    if (draft.isEmpty && c.attachments.isEmpty && !hasRequestTimetable) {
      _errorMessage = '请先粘贴材料、添加文本文件，或先设置时间表';
      _notify();
      return;
    }
    // 0.3.0（提示词 06）：材料超过单次请求预算时不能硬发（C 侧会拒绝），
    // 保留本地材料并明确引导到分块分析；不截断材料。
    if (materialExceedsSingleRequest) {
      _errorMessage = '材料约 $materialUtf8Bytes 字节，超过单次请求上限 '
          '$singleRequestInputBytes 字节；本地材料已保留，请使用「分块分析」发送';
      _notify();
      return;
    }

    // 非法时间表明确失败：不能把“带了非法约束”当成“没有约束”继续排程。
    // 这里的快照是运行时合成的（手工时间表 + 外部忙碌），请求里的
    // timetable/effectiveTimetable/calendarRevision 全部取自它。
    final requestTimetable = c.includeTimetable
        ? requestTimetableFor(c, version)
        : null;
    final timetableError = validateTimetableForRequest(requestTimetable);
    if (timetableError != null) {
      _errorMessage = timetableError;
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

    // 外部日历指纹与来源引用必须在请求发出的同一刻固定下来：分析期间关联来源
    // 或内容变化会让迟到结果失去意义，提交时按它们拒绝。
    final requestExternalFingerprint = externalFingerprintFor(c);
    final requestExternalRefs = _externalSourceRefs(c);

    final ticket = gate.begin(
      conversationId: c.id,
      requestId: requestId,
      baseVersionId: version?.id,
      baseRevision: version?.revision ?? 0,
      // -1 = 本次请求没有带时间表，之后改时间表不影响结果可用性。
      calendarRevision:
          requestTimetable == null ? -1 : requestTimetable.revision,
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
    final request = buildAnalysisRequest(
      conversation: c,
      version: version,
      requestId: requestId,
      draft: draft,
      planContext: planContext,
    );

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
        externalFingerprint: requestExternalFingerprint,
        externalSourcesRef: requestExternalRefs,
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

    await _commitResult(
      ticket,
      outcome,
      run.submittedDraft,
      externalFingerprint: run.externalFingerprint,
      externalSourcesRef: run.externalSourcesRef,
    );
    gate.finish(ticket);
    _run = null;
    _waitPromptShown = false;
    _notify();
  }

  Future<void> _commitResult(
    RequestTicket ticket,
    AnalyzeOutcome outcome,
    String submittedDraft, {
    String externalFingerprint = '',
    List<ExternalCalendarSourceRef> externalSourcesRef =
        const <ExternalCalendarSourceRef>[],
  }) async {
    final c = _conversation;
    final plan = outcome.plan;
    final latest = await _loadFor(ticket.conversationId);
    if (latest == null || latest.isDeleted || latest.isArchived) {
      _statusMessage = '会话已归档或删除，迟到结果已丢弃';
      return;
    }
    final currentTimetable =
        latest.currentVersion?.timetable ?? latest.calendarDraft;
    final stale = staleResultMessage(
      requestedTimetableRevision: ticket.calendarRevision,
      currentTimetableRevision: currentTimetable?.revision ?? 0,
      requestedExternalFingerprint: externalFingerprint,
      currentExternalFingerprint: externalFingerprintFor(latest),
    );
    if (stale != null) {
      _statusMessage = stale;
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

    final liveIds = reconciled.tasks.map((t) => t.id).toSet();
    final inheritedTimetable =
        (base?.timetable ?? c.calendarDraft)?.inheritedBy(liveIds);
    CalendarSchedule committedCalendar;
    if (base == null && inheritedTimetable != null) {
      // 空会话先画了时间表，再发送分析：首个版本必须把草稿时间表变成可用时间，
      // 否则甘特图会显示“没有可用时间”。
      final blank = CalendarSchedule.blank(now: DateTime.now()).settings;
      final derived = inheritedTimetable.toCalendarSettings(blank);
      committedCalendar = CalendarSchedule(
        settings: derived,
        segments: inheritedTimetable.taskSegments(derived.clock),
      );
    } else {
      committedCalendar = (base?.calendar ??
              CalendarSchedule.blank(now: DateTime.now()))
          .inheritedBy(liveIds);
    }

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
      calendar: committedCalendar,
      timetable: inheritedTimetable,
      // 历史快照：记录本次请求实际使用的外部日历集合（只含指纹/来源身份，
      // 不含任何事件标题或路径）。没有启用外部日历时为 null。
      externalCalendarRef: externalSourcesRef.isEmpty
          ? null
          : ExternalCalendarRef(
              fingerprint: externalFingerprint,
              sources: externalSourcesRef,
            ),
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
    final previous = _viewVersion;
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
    // 完成事件跟随真实计划状态（只在完成状态真正变化时记录/撤销，不写实际耗时）。
    await _syncCompletionEvents(previous, withSignatures);
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
  Future<bool> applyCalendarEdit(CalendarEditOutcome outcome,
      {Timetable? timetable}) async {
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
    // 防呆：即使调用方把“合成排程快照”（含 external 占用）传回来，也绝不把
    // 外部日历数据写进版本；这里统一剥掉 external 占用再落盘。
    final baseSchedule = outcome.schedule!;
    final committedSchedule = baseSchedule.copyWith(
      settings: withoutExternalOccupancies(baseSchedule.settings),
    );
    final next = v.copyWith(
      calendar: committedSchedule,
      tasks: outcome.tasks ?? v.tasks,
      revision: v.revision + 1,
      timetable: timetable ?? v.timetable,
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
    // 排程使用“手工 settings + 外部忙碌”的运行时快照；提交时恢复手工 settings，
    // 外部数据绝不写回版本。
    final manualSettings = v.calendar.settings;
    final schedulingSettings = _settingsWithExternalBusy(manualSettings);
    final plan = autoSchedule(
      current: v.calendar.copyWith(settings: schedulingSettings),
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
      schedule: plan.schedule.copyWith(settings: manualSettings),
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
    // 编辑器可能拿到的是合成快照的 settings；落盘前剥掉外部占用。
    final manualSettings = withoutExternalOccupancies(settings);
    var schedule = v.calendar.copyWith(settings: manualSettings);
    if (reschedule) {
      final plan = autoSchedule(
        current: schedule.copyWith(
            settings: _settingsWithExternalBusy(manualSettings)),
        tasks: schedulingTasks(),
        suggestedOrder: _display?.order ?? const <String>[],
        now: DateTime.now(),
        keepManual: true,
      );
      _calendarTaskNotes = plan.taskNotes;
      schedule = plan.schedule.copyWith(settings: manualSettings);
    }
    return applyCalendarEdit(CalendarEditOutcome(
      schedule: schedule,
      tasks: v.tasks,
      label: '更新可用时间',
      message: reschedule ? '已按新的可用时间重新安排' : '已保存可用时间',
    ));
  }

  // ------------------------------------------------ structured timetable

  int get weekStartsOn => settings?.prefs.weekStartsOn ?? 1;

  CalendarEditorMode get defaultCalendarEditor =>
      settings?.prefs.defaultCalendarEditor ?? CalendarEditorMode.drawing;

  List<UnavailableRange> get defaultUnavailableRanges =>
      settings?.prefs.defaultUnavailableRanges ?? UnavailableRange.defaults;

  /// 当前会话使用的时间表：版本数据 → 空会话草稿 → 由旧版设置推导/新建默认。
  ///
  /// [createDefault] 只应由“打开编辑器”调用：它会在内存里生成一份默认周表，
  /// 不会写盘；取消后不会留下空附件。
  Timetable currentTimetable() {
    final v = _viewVersion;
    final draft = _conversation?.calendarDraft;
    if (v?.timetable != null) return v!.timetable!;
    if (draft != null) return draft;
    final wall = calendar.settings.clock.toWall(DateTime.now());
    final today = WallClock.formatDateKey(wall.year, wall.month, wall.day);
    final anchor = calendar.settings.planningStartDate.isEmpty
        ? today
        : calendar.settings.planningStartDate;
    final weekStart = weekStartFor(anchor, weekStartsOn);
    if (v == null || !v.calendar.settings.hasAvailability && v.calendar.segments.isEmpty) {
      return Timetable.withDefaults(
        weekStart: weekStart,
        timezoneId: calendar.settings.timezoneId,
        timezoneOffsetMinutes: calendar.settings.timezoneOffsetMinutes,
        unavailable: <WallClockRange>[
          for (final r in defaultUnavailableRanges)
            WallClockRange(r.start, r.end),
        ],
      );
    }
    return Timetable.fromSchedule(v.calendar, weekStart: weekStart);
  }

  /// 迟到结果的时间表一致性判断：请求未带时间表（-1）或 revision 未变时可用。
  static String? calendarStaleMessage(int requestedRevision, int currentRevision) {
    if (requestedRevision < 0 || requestedRevision == currentRevision) {
      return null;
    }
    return '时间表在分析期间已修改（revision $requestedRevision → '
        '$currentRevision），本次结果未应用；请用新时间表重新分析';
  }

  /// 迟到结果能否采纳的**唯一判定**（纯函数，便于直接测试）。
  ///
  /// 两个条件都必须满足：
  ///   * 手工时间表 revision 没有变化（请求未带时间表时传 -1）；
  ///   * 外部日历集合指纹没有变化（服务不可用时两侧都是空串）。
  ///
  /// 返回 null = 可采纳；否则返回给用户看的中文原因。这里**不会**把外部忙碌
  /// 写回任何数据：拒绝只是丢弃迟到结果。
  static String? staleResultMessage({
    required int requestedTimetableRevision,
    required int currentTimetableRevision,
    required String requestedExternalFingerprint,
    required String currentExternalFingerprint,
  }) {
    final timetableStale =
        calendarStaleMessage(requestedTimetableRevision, currentTimetableRevision);
    if (timetableStale != null) return timetableStale;
    return externalCalendarStaleMessage(
        requestedExternalFingerprint, currentExternalFingerprint);
  }

  /// 输入框里的时间表摘要；没有可发送的时间表时为 null。
  ///
  /// 这里给出的是 coverage 内按天展开的可用总量（含日期覆盖与本周占用），
  /// 不是“每周模板容量”，避免把模板值显示成本周实际可用。
  String? get timetableSummary {
    final c = _conversation;
    if (c == null || !c.includeTimetable) return null;
    final tt = c.currentVersion?.timetable ?? c.calendarDraft;
    if (tt == null) return null;
    final free = tt.freeMinutesInCoverage;
    final tasks = tt.taskEntries.length;
    final bound = tt.boundMinutesByTask().values.fold<int>(0, (a, b) => a + b);
    return '时间表：覆盖 ${tt.coverageDays} 天 · 可用 ${free ~/ 60} 小时 '
        '${free % 60} 分 · 蓝色 $tasks 段（已绑定 $bound 分钟）';
  }

  /// 移除随请求发送的时间表；不会删除已保存的日程数据。
  Future<void> removeTimetableFromRequest() async {
    final c = _conversation;
    if (c == null) return;
    final updated = c.copyWith(includeTimetable: false, updatedAt: DateTime.now());
    _conversation = updated;
    _cache[updated.id] = updated;
    await store.saveConversation(updated);
    _notify();
  }

  /// 时间表提交进行中标记：防止重复点击/并发展开导致重复排程或乱序写入。
  bool _applyingTimetable = false;

  /// 应用编辑器的结果：时间表与 CalendarSettings 一起提交，并按需重新安排。
  ///
  /// [timetable] 是唯一权威草稿；settings 里的周可用/例外/占用必须已经反映在
  /// 时间表中（编辑器负责同源重建）。revision 从当前已提交状态推进，不能拿
  /// 编辑器打开时的旧 revision 反复 +1。
  Future<bool> applyTimetableSettings(
    CalendarSettings settings,
    Timetable timetable, {
    bool reschedule = true,
  }) async {
    // 编辑器可能拿的是合成快照 settings；外部占用绝不进入版本数据。
    final manualSettings = withoutExternalOccupancies(settings);
    if (_applyingTimetable) {
      _errorMessage = '时间表正在保存，请稍候';
      _notify();
      return false;
    }
    final invalid = validateTimetableForRequest(timetable);
    if (invalid != null) {
      _errorMessage = invalid;
      _notify();
      return false;
    }
    _applyingTimetable = true;
    try {
      final v = _viewVersion;
      if (v == null) {
        // 空会话：只保存草稿时间表，不创建空计划版本。
        final c = _conversation;
        if (c == null) return false;
        final committedRevision = c.calendarDraft?.revision ?? 0;
        final updated = c.copyWith(
          calendarDraft:
              timetable.copyWith(revision: committedRevision + 1),
          includeTimetable: true,
          updatedAt: DateTime.now(),
          activityAt: DateTime.now(),
        );
        _conversation = updated;
        _cache[updated.id] = updated;
        await store.saveConversation(updated);
        // 提示词 02：保存成功回执不在主区顶部显示（也不留占位）；数据已落盘，
        // 失败仍走 _errorMessage。撤销/历史不依赖这条文案。
        _notify();
        return true;
      }
      final clock = manualSettings.clock;
      final committedRevision = v.timetable?.revision ?? 0;
      final nextTimetable =
          timetable.copyWith(revision: committedRevision + 1);
      final derived = nextTimetable.toCalendarSettings(manualSettings);
      final auto =
          v.calendar.segments.where((s) => s.source == SegmentSource.auto);
      final manual = nextTimetable.taskSegments(clock);
      var schedule = v.calendar.copyWith(
        settings: derived,
        segments: List<ScheduleSegment>.unmodifiable(<ScheduleSegment>[
          ...auto,
          ...manual,
        ]..sort((a, b) => a.start.compareTo(b.start))),
      );
      if (reschedule) {
        // 排程按“手工 settings + 外部忙碌”计算；提交前恢复手工 settings，
        // 外部占用绝不会进入版本数据。
        final plan = autoSchedule(
          current: schedule.copyWith(
              settings: _settingsWithExternalBusy(derived)),
          tasks: schedulingTasks(),
          suggestedOrder: _display?.order ?? const <String>[],
          now: DateTime.now(),
          keepManual: true,
        );
        _calendarTaskNotes = plan.taskNotes;
        schedule = plan.schedule.copyWith(settings: derived);
      }
      final ok = await applyCalendarEdit(
        CalendarEditOutcome(
          schedule: schedule,
          tasks: v.tasks,
          label: '更新时间表',
          message: reschedule ? '已保存时间表并重新安排' : '已保存时间表',
        ),
        timetable: nextTimetable,
      );
      if (ok) {
        // 提示词 02：时间表保存成功回执不在主区顶部显示，也不留占位。底层操作名
        // /撤销数据仍保留在 `_rememberTaskUndo` 与版本数据里；失败与存储警告不受影响。
        _statusMessage = null;
        _notify();
      }
      return ok;
    } finally {
      _applyingTimetable = false;
    }
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
  String get calendarProposalSignature {
    final tt = currentTimetable();
    return materialSignature(<String>[
      for (final s in calendarMaterialSources()) s.text,
      'calendarRevision=${tt.revision}',
      'dateFrom=${tt.dateFrom}',
      'timezone=${tt.timezoneId}/${tt.timezoneOffsetMinutes}',
    ]);
  }

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
    final tt = currentTimetable();
    // 识别请求同样携带同一快照的两份视图；非法数据明确失败。
    final timetableError = validateTimetableForRequest(tt);
    if (timetableError != null) {
      return CalendarProposalOutcome.failure(timetableError);
    }
    Map<String, dynamic>? effectiveTimetable;
    try {
      effectiveTimetable = deriveEffectiveTimetable(tt);
    } on TimetableRequestException catch (e) {
      return CalendarProposalOutcome.failure(e.message);
    }
    final clock = (c.currentVersion?.calendar.settings ?? calendar.settings).clock;
    final wallNow = clock.toWall(DateTime.now());
    final request = <String, dynamic>{
      'requestSchemaVersion': 2,
      'conversationId': cid,
      'requestId': requestId,
      'calendarRevision': tt.revision,
      'context': <String, dynamic>{
        'currentDate': WallClock.formatDateKey(
            wallNow.year, wallNow.month, wallNow.day),
        'timezoneId': tt.timezoneId,
        'timezoneOffsetMinutes': tt.timezoneOffsetMinutes,
      },
      'timetable': tt.toJson(),
      'effectiveTimetable': effectiveTimetable,
      'knownTasks': <Map<String, dynamic>>[
        for (final t in c.currentVersion?.tasks ?? const <TaskRecord>[])
          if (!t.isDone)
            <String, dynamic>{
              'id': t.id,
              'title': t.name,
              'estimatedMinutes': t.estimatedHours == null
                  ? null
                  : (t.estimatedHours! * 60).round(),
            },
      ],
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

  /// 关闭前等待防抖写入完成；返回后可以安全地销毁控制器。
  Future<void> shutdown() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    await flushPendingWrites();
    // 活动计时保存检查点并暂停（不把退出到重启之间的时间算成工作）。
    await timer?.shutdown();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    unawaited(flushPendingWrites());
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
