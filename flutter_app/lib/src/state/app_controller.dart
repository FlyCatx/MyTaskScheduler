// 管理会话、版本、分析和执行状态。
// 主要入口：createConversation、startAnalysis、startChunkedAnalysis、cancelAnalysis。
// 迟到分析结果按请求票据校验；失败或取消不覆盖已有计划。

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
import 'schedule/schedule_busy.dart';
import 'schedule/schedule_controller.dart';
import 'schedule/schedule_store.dart';
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

  /// 请求发出时本地全局日程的忙碌指纹（范围+时区+有效区间并集）；空 = 本次不校验。
  final String scheduleFingerprint;

  /// 复核指纹所用的规划范围/时区（与请求时间表一致）。
  final String scheduleDateFrom;
  final String scheduleDateTo;
  final String scheduleTimezoneId;
  final int scheduleTimezoneOffsetMinutes;

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
    this.scheduleFingerprint = '',
    this.scheduleDateFrom = '',
    this.scheduleDateTo = '',
    this.scheduleTimezoneId = '',
    this.scheduleTimezoneOffsetMinutes = 0,
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
        scheduleFingerprint: scheduleFingerprint,
        scheduleDateFrom: scheduleDateFrom,
        scheduleDateTo: scheduleDateTo,
        scheduleTimezoneId: scheduleTimezoneId,
        scheduleTimezoneOffsetMinutes: scheduleTimezoneOffsetMinutes,
      );

  String get elapsedText {
    final s = elapsed.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return m > 0 ? '$m 分 ${r.toString().padLeft(2, '0')} 秒' : '$r 秒';
  }
}

/// 一次附件导入的结果。失败项带文件名和简短原因；[note] 用于提示后续操作。
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

  /// 外部日历来源服务；为空时不合成占用时间，也不生成来源指纹。
  final ExternalCalendarService? externalCalendar;

  /// Where sessions are stored (shown in the sidebar footer) and, when the primary
  /// location was not writable, a one-line explanation for the user.
  final String storagePath;
  final String? storageNotice;
  final bool storageIsPersistent;

  /// Storage resolution details for the "存储" page (never a secret).
  final String storageSource;
  final List<RejectedRoot> storageRejected;

  /// 执行计时；为空时相关操作降级。执行记录单独持久化，不改写计划 JSON。
  final TimerController? timer;

  /// OCR 缓存和分块作业的数据根目录。为空时依赖落盘的功能应明确报不可用。
  final Directory? dataDirectory;

  /// 本地 OCR 服务；为空时仍可提取文本文件。
  final OcrService? ocr;

  /// 全局日程服务；为空表示本构建没有启用日程（行为与 0.3.x 一致）。
  final ScheduleController? schedule;

  /// 日程存储（备份/迁移接线用）；没有启用日程时为 null。
  ScheduleStore? get scheduleStore => schedule?.store;

  AppController({
    required this.engine,
    required this.store,
    this.gateway,
    this.settings,
    this.externalCalendar,
    this.timer,
    this.dataDirectory,
    this.ocr,
    this.schedule,
    this.storagePath = '',
    this.storageNotice,
    this.storageIsPersistent = true,
    this.storageSource = '',
    this.storageRejected = const <RejectedRoot>[],
  });


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

  /// 启动准备窗口的占位。从点击到取得 gate ticket / native job 之间有多个 await，
  /// 不占位时连点会并发保存 pending 并让第二个请求撞上 gate.begin 的 StateError。
  bool _starting = false;

  /// 释放被 ABI 拒绝（job 仍在运行）时保留 id，按有界节奏重试；不伪造“已释放”。
  /// 退出时 gateway.close() 的 shutdownBegin 会统一取消并销毁剩余 job。
  final Set<int> _nativeJobsPendingRelease = <int>{};

  String? _statusMessage;
  String? _errorMessage;
  String? _lastDocumentErrorCode;
  bool _busy = false;

  /// 最近一次附件导入反馈按会话隔离，切换会话后不显示旧回执。
  AttachmentFeedback? _attachmentFeedback;

  /// 最近一次添加文件的结构化失败码（如 `unsupported_ocr`）；成功/无关时为 null。
  /// UI 用它决定是否提供“本地 OCR 导入”，不靠匹配中文错误文案。
  String? get lastDocumentErrorCode => _lastDocumentErrorCode;


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
      // 本地抽取和单次模型请求分别限额。抽取成功但请求超限时保留材料，
      // 由发送入口提示使用分块分析。
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
      // 抽取结果不截断；超出单次请求预算也不算导入失败。
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

  /// 把本地 OCR（含用户校对）结果加入当前会话材料。
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


  static const AnalysisLimits _chunkedLimits =
      AnalysisLimits(maxConcurrentRequests: 1);

  bool _chunkedRunning = false;
  bool _chunkedCancelRequested = false;
  ChunkedCoordinator? _chunkedCoordinator;
  ChunkedJob? _chunkedJob;
  ModelSelection? _chunkedSelection;

  // 预览会话（任务 4）：分析结束只产出预览，用户确认后才提交。
  ChunkedCoordinator? _previewCoordinator;
  ChunkedJob? _previewJob;
  FactLedger? _previewLedger;
  AnalysisJobSpec? _previewSpec;
  DraftPlanPreview? _preview;
  List<String> _previewBlockers = const <String>[];
  List<String> _previewCoverageLines = const <String>[];
  String _previewExternalFingerprint = '';
  List<ExternalCalendarSourceRef> _previewExternalRefs =
      const <ExternalCalendarSourceRef>[];
  bool _previewCommitting = false;

  /// 已提交过的预览身份（jobId + 候选任务集合）：双击确认不能生成第二个版本。
  final Set<String> _committedPreviewKeys = <String>{};

  bool get chunkedAnalysisRunning => _chunkedRunning;

  bool get chunkedPreviewAvailable => _preview != null;

  bool get chunkedPreviewCommitting => _previewCommitting;

  /// 当前预览视图；没有预览时为 null。失效原因（材料/时间表/版本/模型变化）
  /// 在读取时重新计算，不依赖 UI 主动刷新。
  ChunkedPreviewView? get chunkedPreview {
    final preview = _preview;
    if (preview == null) return null;
    final excludedFacts =
        _previewLedger?.excludedFacts.keys.toSet() ?? const <String>{};
    final excludedCandidates = <String>{};
    for (final fact in preview.facts) {
      final factId = fact['factId']?.toString() ?? '';
      if (!excludedFacts.contains(factId)) continue;
      for (final raw in (fact['taskCandidateIds'] as List<dynamic>?) ??
          const <dynamic>[]) {
        final id = raw.toString();
        if (id.isNotEmpty) excludedCandidates.add(id);
      }
    }
    return ChunkedPreviewView(
      preview: preview,
      staleReason: _chunkedPreviewStaleReason(),
      excludedFactIds: excludedFacts,
      excludedCandidateIds: excludedCandidates,
      committing: _previewCommitting,
      coverageLines: _previewCoverageLines,
    );
  }

  /// 用 [base] 的固定 asOf 归一化 [current]，用于比较“除作业基准时间外”的基线。
  /// asOf 是作业开始时固定的相对日期锚点，重建作业时必然不同，不能算作失效。
  static JobBaseline normalizePreviewBaseline(
    JobBaseline current,
    JobBaseline base,
  ) =>
      JobBaseline(
        asOf: base.asOf,
        timeZoneId: current.timeZoneId,
        timezoneOffsetMinutes: current.timezoneOffsetMinutes,
        baseVersionId: current.baseVersionId,
        baseRevision: current.baseRevision,
        calendarRevision: current.calendarRevision,
        materialHashes: current.materialHashes,
        modelConfigSignature: current.modelConfigSignature,
        userRequestHash: current.userRequestHash,
        timetableSignature: current.timetableSignature,
        externalSources: current.externalSources,
        scheduleFingerprint: current.scheduleFingerprint,
        promptVersion: current.promptVersion,
      );

  String? _chunkedPreviewStaleReason() {
    final spec = _previewSpec;
    final job = _previewJob;
    if (spec == null || job == null) return null;
    final session = _conversation;
    if (session == null || session.id != spec.conversationId) {
      return '当前会话与预览不一致';
    }
    final prepared = _prepareChunkedInputs(resolveSelection: false);
    final current = prepared.spec;
    if (current == null) {
      return prepared.error ?? '当前材料已不可用';
    }
    final normalized =
        normalizePreviewBaseline(current.buildBaseline(), job.baseline);
    if (normalized.signature != job.baseline.signature) {
      return '材料、时间表、计划版本或模型配置已变化，请重新分析';
    }
    return null;
  }

  void _clearChunkedPreviewState() {
    _previewCoordinator = null;
    _previewJob = null;
    _previewLedger = null;
    _previewSpec = null;
    _preview = null;
    _previewBlockers = const <String>[];
    _previewCoverageLines = const <String>[];
    _previewExternalFingerprint = '';
    _previewExternalRefs = const <ExternalCalendarSourceRef>[];
  }

  /// 丢弃预览（不产生版本；关闭预览不应修改当前正式版本）。
  void discardChunkedPreview() {
    if (_preview == null) return;
    _clearChunkedPreviewState();
    _notify();
  }

  void _rebuildChunkedPreview() {
    final coordinator = _previewCoordinator;
    final job = _previewJob;
    final ledger = _previewLedger;
    if (coordinator == null || job == null || ledger == null) return;
    _preview = coordinator.buildPreview(job, ledger, blockers: _previewBlockers);
  }

  void _installChunkedPreview({
    required ChunkedCoordinator coordinator,
    required ChunkedJob job,
    required FactLedger ledger,
    required AnalysisJobSpec spec,
    required DraftPlanPreview preview,
    required List<String> blockers,
    required List<String> coverageLines,
    required String externalFingerprint,
    required List<ExternalCalendarSourceRef> externalSourcesRef,
  }) {
    _previewCoordinator = coordinator;
    _previewJob = job;
    _previewLedger = ledger;
    _previewSpec = spec;
    _preview = preview;
    _previewBlockers = List<String>.unmodifiable(blockers);
    _previewCoverageLines = List<String>.unmodifiable(coverageLines);
    _previewExternalFingerprint = externalFingerprint;
    _previewExternalRefs =
        List<ExternalCalendarSourceRef>.unmodifiable(externalSourcesRef);
  }

  /// 人工排除/恢复一个候选任务：更新账本与预览（不是只隐藏一行提示）。
  ChunkedRunResult setChunkedPreviewTaskExcluded(
    String candidateId, {
    required bool excluded,
  }) {
    final preview = _preview;
    final ledger = _previewLedger;
    if (preview == null || ledger == null) {
      return const ChunkedRunResult(ok: false, message: '没有待处理的分块预览');
    }
    String? factId;
    for (final fact in preview.facts) {
      final ids = ((fact['taskCandidateIds'] as List<dynamic>?) ??
              const <dynamic>[])
          .map((e) => e.toString());
      if (ids.contains(candidateId)) {
        factId = fact['factId']?.toString();
        break;
      }
    }
    if (factId == null || factId.isEmpty) {
      return const ChunkedRunResult(
          ok: false, message: '找不到该候选任务对应的账本事实');
    }
    if (excluded) {
      ledger.excludeFact(factId, reason: '用户在预览中排除候选任务');
    } else {
      ledger.restoreFact(factId);
    }
    _rebuildChunkedPreview();
    _notify();
    return ChunkedRunResult(
      ok: true,
      message: excluded ? '已排除该候选任务，依赖与待确认项已重算' : '已恢复该候选任务',
      previewReady: true,
    );
  }

  /// 把预览转成正式提交。
  ///
  /// 只有 [ChunkedPreviewView.canCommit] 为 true 的预览才应调用；该入口与普通分析
  /// 共用提交门/落盘顺序，成功时 [ChunkedRunResult.committedPlanVersionId] 是本次
  /// 新增版本。单独公开是为了让测试不依赖真实原生桥接。
  Future<ChunkedRunResult> commitChunkedPreview({
    required DraftPlanPreview preview,
    required String conversationId,
    required int calendarRevision,
    String externalFingerprint = '',
    List<ExternalCalendarSourceRef> externalSourcesRef =
        const <ExternalCalendarSourceRef>[],
  }) async {
    final c = _conversation;
    if (c == null || c.id != conversationId) {
      return const ChunkedRunResult(
          ok: false, message: '结果不属于当前会话，已丢弃');
    }
    if (preview.partial || preview.blockers.isNotEmpty) {
      return ChunkedRunResult(
        ok: false,
        message: '材料未完整处理，不能生成正式计划',
        partial: true,
        blockers: preview.blockers,
        previewReady: true,
      );
    }
    final previewKey = _chunkedPreviewKey(preview);
    if (_committedPreviewKeys.contains(previewKey)) {
      return const ChunkedRunResult(
        ok: false,
        message: '该预览已提交，不能重复生成版本',
        previewReady: true,
      );
    }
    final RequestTicket ticket;
    try {
      ticket = gate.begin(
        conversationId: conversationId,
        requestId: IdGenerator.next('req'),
        baseVersionId: c.currentVersion?.id,
        baseRevision: c.currentVersion?.revision ?? 0,
        calendarRevision: calendarRevision,
      );
    } on StateError catch (e) {
      return ChunkedRunResult(ok: false, message: e.message);
    }
    final PlanCommitResult commit;
    try {
      commit = await commitAnalysisResult(
        ticket,
        AnalyzeOutcome(
          ok: true,
          plan: preview.toPlanJson(),
          elapsedMs: 0,
          httpStatus: 200,
        ),
        c.draftText,
        externalFingerprint: externalFingerprint,
        externalSourcesRef: externalSourcesRef,
      );
    } finally {
      gate.finish(ticket);
    }
    if (commit.status != PlanCommitStatus.committed || commit.versionId == null) {
      if (commit.status == PlanCommitStatus.failed) {
        _errorMessage = commit.message;
      }
      _statusMessage = commit.message;
      _notify();
      return ChunkedRunResult(
        ok: false,
        message: commit.message,
        previewReady: true,
      );
    }
    _committedPreviewKeys.add(previewKey);
    final message = commit.warning == null
        ? '已确认并生成计划版本'
        : '已确认并生成计划版本；${commit.warning}';
    _statusMessage = message;
    _notify();
    return ChunkedRunResult(
      ok: true,
      message: message,
      committedPlanVersionId: commit.versionId,
    );
  }

  /// 预览身份：同一个 job + 相同候选任务集合视为同一份预览（排除/恢复会改变它）。
  static String _chunkedPreviewKey(DraftPlanPreview preview) =>
      '${preview.jobId}::'
      '${preview.tasks.map((t) => '${t.candidateId}|${t.name}').join(',')}';

  /// 确认预览：重新校验基线、完整性、关键待确认项后才提交；双击幂等。
  Future<ChunkedRunResult> confirmChunkedPreview() async {
    final preview = _preview;
    final spec = _previewSpec;
    final job = _previewJob;
    if (preview == null || spec == null || job == null) {
      return const ChunkedRunResult(ok: false, message: '没有待确认的分块预览');
    }
    if (_previewCommitting) {
      return const ChunkedRunResult(
          ok: false, message: '正在提交预览，请勿重复点击', previewReady: true);
    }
    final stale = _chunkedPreviewStaleReason();
    if (stale != null) {
      return ChunkedRunResult(
          ok: false, message: '预览已失效：$stale', previewReady: true);
    }
    if (preview.partial || preview.blockers.isNotEmpty) {
      return ChunkedRunResult(
        ok: false,
        message: '材料未完整处理，不能生成正式计划',
        partial: true,
        blockers: preview.blockers,
        previewReady: true,
      );
    }
    final critical = preview.pending.where((p) => p.critical).toList();
    if (critical.isNotEmpty) {
      return ChunkedRunResult(
        ok: false,
        message: '仍有待确认的关键问题：${critical.first.text}',
        previewReady: true,
      );
    }
    _previewCommitting = true;
    _notify();
    try {
      final result = await commitChunkedPreview(
        preview: preview,
        conversationId: spec.conversationId,
        calendarRevision: job.baseline.calendarRevision,
        externalFingerprint: _previewExternalFingerprint,
        externalSourcesRef: _previewExternalRefs,
      );
      if (result.ok) _clearChunkedPreviewState();
      return result;
    } finally {
      _previewCommitting = false;
      _notify();
    }
  }

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
    if (_disposed) {
      return const ChunkedRunResult(ok: false, message: '应用已关闭');
    }
    // 与普通分析共享启动占位：从点击到 coordinator.run 之间不能并发启动第二个作业。
    if (_starting || _chunkedRunning || _run != null) {
      return const ChunkedRunResult(
          ok: false, message: '已有分析在进行中，请等待或取消');
    }
    _starting = true;
    try {
      return await _startChunkedAnalysisBody(onProgress: onProgress);
    } catch (e) {
      return ChunkedRunResult(ok: false, message: '分块分析失败：$e');
    } finally {
      _starting = false;
    }
  }

  Future<ChunkedRunResult> _startChunkedAnalysisBody({
    void Function(JobProgress progress)? onProgress,
  }) async {
    final gw = gateway;
    if (gw == null) {
      return const ChunkedRunResult(ok: false, message: '原生桥接不可用，无法发起分块分析');
    }
    var c = await ensureConversation();
    if (_disposed) {
      return const ChunkedRunResult(ok: false, message: '应用已关闭');
    }
    // 新的分块分析会让旧预览失效：先丢弃（旧预览对应旧基线）。
    _clearChunkedPreviewState();
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
    try {
      await store.saveConversation(withPending);
    } catch (e) {
      _conversation = c;
      _cache[c.id] = c;
      gate.finish(ticket);
      return ChunkedRunResult(
          ok: false, message: '保存请求占位失败，未发起分块分析：$e');
    }
    if (_disposed) {
      gate.finish(ticket);
      try {
        await clearPendingFor(conversationId: c.id, requestId: requestId);
      } catch (_) {
        // 退出清理尽力而为。
      }
      return const ChunkedRunResult(ok: false, message: '应用已关闭');
    }

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
      try {
        await clearPendingFor(conversationId: c.id, requestId: requestId);
      } catch (_) {
        // 清理失败不改变“作业创建失败”的结论。
      }
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
    var cancelRequested = false;
    try {
      outcome = await coordinator.run(job);
      cancelRequested = _chunkedCancelRequested;
    } catch (e) {
      // 运行异常也必须结束票据并清匹配占位；否则下一次分析会被 gate 永久拒绝。
      gate.finish(ticket);
      try {
        await clearPendingFor(conversationId: c.id, requestId: requestId);
      } catch (_) {
        // 不覆盖最初的失败原因。
      }
      _chunkedRunning = false;
      _chunkedCoordinator = null;
      _chunkedJob = null;
      _chunkedSelection = null;
      _chunkedCancelRequested = false;
      _notify();
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

    if (cancelRequested || job.isCancelled) {
      gate.finish(ticket);
      try {
        await clearPendingFor(conversationId: c.id, requestId: requestId);
      } catch (_) {
        // 取消路径的清理失败不改变“已取消”的结论。
      }
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
    // 任务 4：分析结束先产出预览，不自动提交；提交由 confirmChunkedPreview 单独触发。
    final ledger = outcome.ledger;
    if (preview == null || ledger == null) {
      gate.finish(ticket);
      try {
        await clearPendingFor(conversationId: c.id, requestId: requestId);
      } catch (_) {
        // 清理失败不改变结论。
      }
      final message = outcome.message.isEmpty
          ? '分块分析结束，但没有可展示的预览，未生成计划'
          : outcome.message;
      _errorMessage = message;
      _statusMessage = message;
      _notify();
      return ChunkedRunResult(
        ok: false,
        message: message,
        blockers: blockers,
        pendingConfirmations: pendingCount,
        factsCount: factsCount,
        coverageLines: coverageLines,
      );
    }
    _installChunkedPreview(
      coordinator: coordinator,
      job: job,
      ledger: ledger,
      spec: spec,
      preview: preview,
      blockers: blockers,
      coverageLines: coverageLines,
      externalFingerprint: requestExternalFingerprint,
      externalSourcesRef: requestExternalRefs,
    );
    gate.finish(ticket);
    try {
      await clearPendingFor(conversationId: c.id, requestId: requestId);
    } catch (e) {
      _errorMessage = '清理待处理标记失败：$e';
    }
    final blocked = preview.partial || blockers.isNotEmpty;
    final message = blocked
        ? '分块分析结束：材料未完整处理，预览不可提交'
        : '分块分析结束，请在预览中确认后生成计划';
    _statusMessage = message;
    if (blocked) _errorMessage = message;
    _notify();
    return ChunkedRunResult(
      ok: false,
      message: message,
      partial: preview.partial,
      blockers: blockers,
      pendingConfirmations: pendingCount,
      factsCount: factsCount,
      coverageLines: coverageLines,
      previewReady: true,
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
      // 运行中的 job 释放会被 ABI 拒绝；交给有界回收，最终由关闭流程统一销毁。
      _releaseNativeJob(nativeJob);
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
    // 分块作业与普通分析使用同一份日程忙碌指纹；展开不完整时直接报错。
    var scheduleFingerprint = '';
    if (requestTimetable != null && schedule != null) {
      final scheduleError = validateScheduleForRequest(
        c,
        version?.timetable ?? c.calendarDraft,
      );
      if (scheduleError != null) {
        return (
          spec: null,
          selection: null,
          migratedSelection: null,
          error: scheduleError,
          materialBytes: materialBytes,
          documentCount: documents.length,
        );
      }
      scheduleFingerprint =
          captureScheduleRequestBaseline(c, version)?.fingerprint ?? '';
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
        scheduleFingerprint: scheduleFingerprint,
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


  /// 全局启用来源的指纹；服务不可用时为空串。
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
    var composed = settings;
    if (busy.isNotEmpty) {
      composed = composeExternalSettings(base: composed, busy: busy);
    }
    final scheduleBusy = scheduleBusyForRange(
      dateFrom: _settingsDateFrom(settings),
      dateTo: _settingsDateTo(settings),
      timezoneId: settings.timezoneId,
      timezoneOffsetMinutes: settings.timezoneOffsetMinutes,
    );
    if (scheduleBusy != null &&
        scheduleBusy.available &&
        scheduleBusy.wallRanges.isNotEmpty) {
      composed = composeScheduleSettings(
        base: composed,
        busy: scheduleBusy.wallRanges,
      );
    }
    if (identical(composed, settings)) return version.calendar;
    return version.calendar.copyWith(settings: composed);
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
    var composed = manual;
    final busy = _externalBusyForRange(
      conversation: conversation,
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
    );
    if (busy.isNotEmpty) {
      composed = composeExternalBusy(
        manual: composed,
        busy: busy,
        timezoneId: manual.timezoneId,
      );
    }
    final scheduleBusy = scheduleBusyForRange(
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
      timezoneOffsetMinutes: manual.timezoneOffsetMinutes,
    );
    if (scheduleBusy != null &&
        scheduleBusy.available &&
        scheduleBusy.wallRanges.isNotEmpty) {
      composed = composeScheduleBusy(
        manual: composed,
        busy: scheduleBusy.wallRanges,
        timezoneId: manual.timezoneId,
      );
    }
    return composed;
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

  /// 本地全局日程在 [dateFrom,dateTo]（含首尾本地日期）内的忙碌与指纹。
  ///
  /// 返回 null = 未启用日程服务（与 0.3.x 行为一致）；available=false 表示展开
  /// 不完整，调用方必须阻断/提示，不能当成“没有忙碌”。
  ScheduleBusySnapshot? scheduleBusyForRange({
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
    required int timezoneOffsetMinutes,
  }) {
    final ctrl = schedule;
    if (ctrl == null) return null;
    final from = parseDateKey(dateFrom);
    final to = parseDateKey(dateTo);
    if (from == null || to == null || to.compareTo(from) < 0) {
      return ScheduleBusySnapshot.unavailable(
        fromUtc: DateTime.utc(1970),
        toUtc: DateTime.utc(1970),
        timezoneId: timezoneId,
        warnings: const <String>['日程范围不合法'],
      );
    }
    final clock = WallClock(timezoneOffsetMinutes);
    final fromUtc = clock.dayStartUtcForDateKey(from);
    final toUtc = clock.dayStartUtcForDateKey(to).add(const Duration(days: 1));
    return computeScheduleBusy(
      events: ctrl.events,
      fromUtc: fromUtc,
      toUtc: toUtc,
      timezoneId: timezoneId,
    );
  }

  /// 校验请求时间表范围上的本地日程能否完整展开；null = 可继续。
  String? validateScheduleForRequest(
    Conversation conversation,
    Timetable? manual,
  ) {
    if (manual == null || schedule == null) return null;
    final range = _busyRangeForTimetable(conversation, manual);
    final snap = scheduleBusyForRange(
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
      timezoneOffsetMinutes: manual.timezoneOffsetMinutes,
    );
    if (snap == null || snap.complete) return null;
    final reason = snap.warnings.isEmpty ? '展开失败' : snap.warnings.first;
    return '本地日程忙碌无法完整展开（$reason），请检查日程时区/重复设置后重试';
  }

  /// 捕获请求发出时的日程忙碌基线；未携带时间表或没有日程服务时返回 null。
  ({
    String fingerprint,
    String dateFrom,
    String dateTo,
    String timezoneId,
    int offsetMinutes
  })? captureScheduleRequestBaseline(
    Conversation conversation,
    PlanVersion? version,
  ) {
    final manual = version?.timetable ?? conversation.calendarDraft;
    if (manual == null || schedule == null) return null;
    final range = _busyRangeForTimetable(conversation, manual);
    final snap = scheduleBusyForRange(
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
      timezoneOffsetMinutes: manual.timezoneOffsetMinutes,
    );
    final fingerprint = snap?.fingerprint;
    if (fingerprint == null) return null;
    return (
      fingerprint: fingerprint,
      dateFrom: range.from,
      dateTo: range.to,
      timezoneId: manual.timezoneId,
      offsetMinutes: manual.timezoneOffsetMinutes,
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
    var composed = settings;
    if (busy.isNotEmpty) {
      composed = composeExternalSettings(base: composed, busy: busy);
    }
    final scheduleBusy = scheduleBusyForRange(
      dateFrom: _settingsDateFrom(settings),
      dateTo: _settingsDateTo(settings),
      timezoneId: settings.timezoneId,
      timezoneOffsetMinutes: settings.timezoneOffsetMinutes,
    );
    if (scheduleBusy != null &&
        scheduleBusy.available &&
        scheduleBusy.wallRanges.isNotEmpty) {
      composed = composeScheduleSettings(
        base: composed,
        busy: scheduleBusy.wallRanges,
      );
    }
    return composed;
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
    if (_disposed) return;
    // 启动占位先于第一个 await：连点/与分块分析交叉启动时不能并发保存 pending。
    if (_starting || _run != null || _chunkedRunning) {
      _errorMessage = '已有分析在进行中，请等待或取消';
      _notify();
      return;
    }
    _starting = true;
    try {
      await _startAnalysisBody();
    } catch (e) {
      _errorMessage = '启动分析失败：$e';
      _notify();
    } finally {
      _starting = false;
    }
  }

  Future<void> _startAnalysisBody() async {
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
    // 材料超过单次请求预算时不能硬发（C 侧会拒绝），
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
    // 本地日程展开不完整时不能把"空忙碌"发给模型（宁可不分析）。
    final manualTimetable = version?.timetable ?? c.calendarDraft;
    final scheduleError = c.includeTimetable
        ? validateScheduleForRequest(c, manualTimetable)
        : null;
    if (scheduleError != null) {
      _errorMessage = scheduleError;
      _notify();
      return;
    }
    final scheduleBaseline = c.includeTimetable
        ? captureScheduleRequestBaseline(c, version)
        : null;

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

    final RequestTicket ticket;
    try {
      ticket = gate.begin(
        conversationId: c.id,
        requestId: requestId,
        baseVersionId: version?.id,
        baseRevision: version?.revision ?? 0,
        // -1 = 本次请求没有带时间表，之后改时间表不影响结果可用性。
        calendarRevision:
            requestTimetable == null ? -1 : requestTimetable.revision,
      );
    } on StateError catch (e) {
      _errorMessage = e.message;
      _notify();
      return;
    }

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
    try {
      await store.saveConversation(withPending);
    } catch (e) {
      // 占位没写成功就不能继续：回退内存并释放票据，否则会话被永久锁住。
      _conversation = c;
      _cache[c.id] = c;
      gate.finish(ticket);
      _errorMessage = '保存请求占位失败，未发起分析：$e';
      _notify();
      return;
    }
    if (_disposed) {
      gate.finish(ticket);
      try {
        await clearPendingFor(
          conversationId: c.id,
          requestId: requestId,
        );
      } catch (_) {
        // 退出清理尽力而为；崩溃恢复会再次处理 pending。
      }
      return;
    }

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
        scheduleFingerprint: scheduleBaseline?.fingerprint ?? '',
        scheduleDateFrom: scheduleBaseline?.dateFrom ?? '',
        scheduleDateTo: scheduleBaseline?.dateTo ?? '',
        scheduleTimezoneId: scheduleBaseline?.timezoneId ?? '',
        scheduleTimezoneOffsetMinutes: scheduleBaseline?.offsetMinutes ?? 0,
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
      try {
        await clearPendingFor(
          conversationId: c.id,
          requestId: requestId,
        );
      } catch (cleanupError) {
        _errorMessage = '$_errorMessage；清理待处理标记失败：$cleanupError';
      }
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

  /// 尝试释放一个已终结的原生 job。ABI 规定运行中的 job 释放返回非 0：
  /// 此时保留 id 交给 [_reapNativeJobs] 重试，绝不假装已释放。
  bool _releaseNativeJob(int jobId) {
    final gw = gateway;
    if (gw == null) return true;
    var released = false;
    try {
      released = gw.tryRelease(jobId);
    } catch (_) {
      released = false;
    }
    if (released) {
      _nativeJobsPendingRelease.remove(jobId);
    } else {
      _nativeJobsPendingRelease.add(jobId);
    }
    return released;
  }

  /// 有界回收：每次 tick 尝试一次；取消失败/仍运行不会阻塞 UI，也不会无限忙等。
  void _reapNativeJobs() {
    if (_nativeJobsPendingRelease.isEmpty) return;
    final gw = gateway;
    if (gw == null) {
      _nativeJobsPendingRelease.clear();
      return;
    }
    for (final id in _nativeJobsPendingRelease.toList(growable: false)) {
      try {
        if (gw.tryRelease(id)) _nativeJobsPendingRelease.remove(id);
      } catch (_) {
        // 保持待回收：桥接关闭时统一销毁。
      }
    }
  }

  void _tick() {
    _reapNativeJobs();
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
      // 轮询本身坏掉时不能只丢内存引用：必须结束票据、清匹配的占位、回收原生 job，
      // 否则会话会被“幽灵锁”卡住且退出时无法判断 job 是否已终结。
      var detail = '读取分析进度失败：$e';
      _stopTimers();
      try {
        gw.cancel(run.jobId);
      } catch (_) {
        // 取消失败不改变结论：job 仍可能运行，交给有界回收/关闭等待。
      }
      _releaseNativeJob(run.jobId);
      final ticket = gate.activeFor(run.conversationId);
      if (ticket != null && ticket.requestId == run.requestId) {
        gate.finish(ticket);
      }
      try {
        await clearPendingFor(
          conversationId: run.conversationId,
          requestId: run.requestId,
        );
      } catch (cleanupError) {
        detail = '$detail；清理待处理标记失败：$cleanupError';
      }
      _errorMessage = detail;
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
    _releaseNativeJob(run.jobId);

    final ticket = gate.activeFor(run.conversationId);
    if (ticket == null || ticket.requestId != run.requestId) {
      // A newer request already took over; this result must not touch anything.
      _run = null;
      _notify();
      return;
    }

    var cleanupNote = '';
    try {
      await clearPendingFor(
        conversationId: run.conversationId,
        requestId: run.requestId,
      );
    } catch (e) {
      cleanupNote = '；清理待处理标记失败：$e';
    }

    try {
      if (terminal.type == 'cancelled' || outcome == null || !outcome.ok) {
        final message = terminal.type == 'cancelled'
            ? '已取消本次分析；原有计划与标题保持不变'
            : '分析失败：${outcome?.error ?? terminal.error}；原有计划与标题保持不变';
        _statusMessage = '$message$cleanupNote';
        if (terminal.type != 'cancelled') _errorMessage = outcome?.error;
        return;
      }

      final commit = await commitAnalysisResult(
        ticket,
        outcome,
        run.submittedDraft,
        externalFingerprint: run.externalFingerprint,
        externalSourcesRef: run.externalSourcesRef,
        scheduleFingerprint: run.scheduleFingerprint,
        scheduleDateFrom: run.scheduleDateFrom,
        scheduleDateTo: run.scheduleDateTo,
        scheduleTimezoneId: run.scheduleTimezoneId,
        scheduleTimezoneOffsetMinutes: run.scheduleTimezoneOffsetMinutes,
      );
      _statusMessage = commit.warning == null
          ? '${commit.message}$cleanupNote'
          : '${commit.message}；${commit.warning}$cleanupNote';
      if (commit.status == PlanCommitStatus.failed) {
        _errorMessage = commit.message;
      }
    } catch (e) {
      // 提交过程中的意外异常也必须结束票据，避免下一次分析被永久锁死。
      _errorMessage = '提交分析结果失败：$e';
      _statusMessage = '分析已完成，但结果未能写入本地版本；原有计划保持不变$cleanupNote';
    } finally {
      gate.finish(ticket);
      _run = null;
      _waitPromptShown = false;
      _notify();
    }
  }

  /// 把 [outcome] 应用到 [ticket] 对应的会话，并返回明确结果。
  ///
  /// 校验顺序：请求身份/会话可用性 → 时间表与外部日历基线 → 任务映射 → 提交门
  /// → 候选计划本地校验 → 落盘。任何一步失败都不改磁盘与内存版本；只有
  /// [PlanCommitStatus.committed] 才表示成功，且 [PlanCommitResult.versionId]
  /// 只可能是本次新增版本。该入口同时供普通分析与分块分析复用。
  Future<PlanCommitResult> commitAnalysisResult(
    RequestTicket ticket,
    AnalyzeOutcome outcome,
    String submittedDraft, {
    String externalFingerprint = '',
    List<ExternalCalendarSourceRef> externalSourcesRef =
        const <ExternalCalendarSourceRef>[],
    String scheduleFingerprint = '',
    String scheduleDateFrom = '',
    String scheduleDateTo = '',
    String scheduleTimezoneId = '',
    int scheduleTimezoneOffsetMinutes = 0,
  }) async {
    final plan = outcome.plan;
    final latest = await _loadFor(ticket.conversationId);
    if (latest == null || latest.isDeleted || latest.isArchived) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '会话已归档或删除，迟到结果已丢弃',
      );
    }
    final currentTimetable =
        latest.currentVersion?.timetable ?? latest.calendarDraft;
    var currentScheduleFingerprint = '';
    if (scheduleFingerprint.isNotEmpty) {
      final snapshot = scheduleBusyForRange(
        dateFrom: scheduleDateFrom,
        dateTo: scheduleDateTo,
        timezoneId: scheduleTimezoneId,
        timezoneOffsetMinutes: scheduleTimezoneOffsetMinutes,
      );
      if (snapshot == null || !snapshot.available) {
        return const PlanCommitResult(
          status: PlanCommitStatus.failed,
          message: '本地日程数据当前不可用，无法确认分析结果是否已过期；'
              '原有计划保持不变',
        );
      }
      currentScheduleFingerprint = snapshot.fingerprint!;
    }
    final stale = staleResultMessage(
      requestedTimetableRevision: ticket.calendarRevision,
      currentTimetableRevision: currentTimetable?.revision ?? 0,
      requestedExternalFingerprint: externalFingerprint,
      currentExternalFingerprint: externalFingerprintFor(latest),
      requestedScheduleFingerprint: scheduleFingerprint,
      currentScheduleFingerprint: currentScheduleFingerprint,
    );
    if (stale != null) {
      return PlanCommitResult(status: PlanCommitStatus.rejected, message: stale);
    }
    final c = _conversation;
    if (c == null || c.id != ticket.conversationId || plan == null) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '结果不属于当前会话，已丢弃',
      );
    }
    // 取消或新请求已接管时，即使结果完整也不能提交（提交门之外的第二道保险）。
    if (ticket.cancelled ||
        !identical(gate.activeFor(ticket.conversationId), ticket)) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '本次请求已取消或已被新请求替代，结果未采纳',
      );
    }

    final proposed = ((plan['tasks'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((t) => TaskRecord.fromLocalJson(t))
        .toList(growable: false);
    if (proposed.isEmpty) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '模型没有返回任何任务，已忽略本次结果',
      );
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
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '本次结果已过期（计划版本已变化），未采纳；原有计划保持不变',
      );
    }
    // 乐观并发检查：校验期间若有其他流程替换了会话缓存，本次提交直接放弃，
    // 不覆盖别人的状态。检查与落盘之间没有 await。
    if (!identical(_conversation, c) || !identical(_cache[c.id], c)) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '会话状态在提交前已变化，未采纳；请重新分析',
      );
    }
    if (newVersion.plan.tasks.isEmpty) {
      return const PlanCommitResult(
        status: PlanCommitStatus.rejected,
        message: '本地整理后没有可提交的任务，未生成新版本',
      );
    }
    // 先跑 C 内核的校验/重排；非法计划绝不能先落盘再失败。
    final DisplaySnapshot snapshot;
    try {
      snapshot = engine.compute(newVersion.plan);
    } on ScheduleException catch (e) {
      return PlanCommitResult(
        status: PlanCommitStatus.failed,
        message: '计划校验失败：${e.message}',
      );
    } catch (e) {
      return PlanCommitResult(
        status: PlanCommitStatus.failed,
        message: '计划校验失败：$e',
      );
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
    // 先落盘、后发布内存状态：写入失败时界面不能显示“已生成”，也不能留下
    // 一个只存在于内存中的版本。保存失败时旧文件由原子写入保留。
    try {
      await store.saveConversation(updated);
    } catch (e) {
      return PlanCommitResult(
        status: PlanCommitStatus.failed,
        message: '新版本未能写入本地存储：$e',
      );
    }
    _conversation = updated;
    _cache[c.id] = updated;
    _viewVersion = newVersion;
    _display = snapshot;
    String? warning;
    try {
      _reindexSummaries();
      await store.saveIndex(_summaries);
    } catch (e) {
      // 会话文件已经保存；索引只服务侧栏摘要，重启或下次保存会重建。
      warning = '计划版本已保存，但会话列表索引更新失败：$e';
      _errorMessage = warning;
    }
    final message = reconciled.reviewNotes.isEmpty
        ? '已生成新版本'
        : '已生成新版本；有 ${reconciled.reviewNotes.length} 项完成状态需要你复核';
    return PlanCommitResult(
      status: PlanCommitStatus.committed,
      message: message,
      versionId: newVersion.id,
      warning: warning,
    );
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

  /// 只清除与本次请求匹配的持久化占位标记。
  ///
  /// 不能按“当前会话”清理：请求期间用户可能切换会话，或新请求已写入自己的
  /// pending；按 conversationId + requestId 清理可避免旧任务回调清掉新任务的占位。
  Future<void> clearPendingFor({
    required String conversationId,
    required String requestId,
  }) async {
    var c = _cache[conversationId];
    if (c == null) {
      try {
        c = await store.loadConversation(conversationId);
      } catch (_) {
        return;
      }
    }
    if (c == null) return;
    final pending = c.pendingRequest;
    if (pending == null || pending.requestId != requestId) return;
    final cleared = c.copyWith(clearPendingRequest: true);
    if (identical(_cache[conversationId], c)) _cache[conversationId] = cleared;
    if (_conversation?.id == conversationId) _conversation = cleared;
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
    final manualSettings = withoutLocalScheduleOccupancies(
        withoutExternalOccupancies(settings));
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
    String requestedScheduleFingerprint = '',
    String currentScheduleFingerprint = '',
  }) {
    final timetableStale =
        calendarStaleMessage(requestedTimetableRevision, currentTimetableRevision);
    if (timetableStale != null) return timetableStale;
    final externalStale = externalCalendarStaleMessage(
        requestedExternalFingerprint, currentExternalFingerprint);
    if (externalStale != null) return externalStale;
    if (requestedScheduleFingerprint.isNotEmpty &&
        requestedScheduleFingerprint != currentScheduleFingerprint) {
      return '本地日程在分析期间已变化（新增/改期/删除/忙闲切换），'
          '本次结果未应用；请重新分析';
    }
    return null;
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
    final manualSettings = withoutLocalScheduleOccupancies(
        withoutExternalOccupancies(settings));
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
        // 成功不占用主区状态栏；撤销和版本数据仍保留。
        _statusMessage = null;
        _notify();
      }
      return ok;
    } finally {
      _applyingTimetable = false;
    }
  }


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
      // 结束的 job 才可释放；运行中释放会被 ABI 拒绝并转入有界回收。
      _releaseNativeJob(jobId);
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
    // 日程命令在退出前排空：不能 dispose 后丢写入；实例锁由 bootstrap 释放。
    await schedule?.drain();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    unawaited(flushPendingWrites());
    _disposed = true;
    _stopTimers();
    final run = _run;
    if (run != null) {
      try {
        gateway?.cancel(run.jobId);
      } catch (_) {
        // 关闭流程会统一取消；这里只尽量缩短工作线程存活时间。
      }
    }
    _reapNativeJobs();
    interaction.dispose();
    super.dispose();
  }
}

class _UndoEntry {
  final String label;
  final Future<void> Function() run;
  const _UndoEntry(this.label, this.run);
}
