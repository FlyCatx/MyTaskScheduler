// Session / version storage model.
//
// Relationship: Conversation -> PlanVersion[] (each with a task snapshot),
// plus the messages and the draft the user is typing.
//
// Rules encoded here:
//   * a version is immutable once committed;
//   * the conversation title comes from the committed version's summary (never from
//     a model response that has not been committed);
//   * switching to an old version is read-only — we never recompute or overwrite
//     its historical snapshot.

import 'calendar.dart';
import 'calendar_proposals.dart';
import 'plan.dart';
import 'settings.dart';
import 'timetable.dart';

enum MessageRole { user, notice }

class ChatMessage {
  final String id;
  final MessageRole role;
  final DateTime at;
  final String text;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.at,
    required this.text,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': role.name,
        'at': at.toIso8601String(),
        'text': text,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: (j['id'] as String?) ?? '',
        role: MessageRole.values.firstWhere(
          (r) => r.name == j['role'],
          orElse: () => MessageRole.user,
        ),
        at: DateTime.tryParse((j['at'] as String?) ?? '') ?? DateTime.now(),
        text: (j['text'] as String?) ?? '',
      );
}

/// An attachment's extracted text is stored locally so the conversation stays
/// usable even if the original file is moved or deleted.
class Attachment {
  final String id;
  final String label;
  final String kind; // text | file
  final String? originalPath;
  final String text;
  final int byteLength;

  const Attachment({
    required this.id,
    required this.label,
    required this.kind,
    this.originalPath,
    required this.text,
    required this.byteLength,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'kind': kind,
        'originalPath': originalPath,
        'text': text,
        'byteLength': byteLength,
      };

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: (j['id'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'text',
        originalPath: j['originalPath'] as String?,
        text: (j['text'] as String?) ?? '',
        byteLength: (j['byteLength'] as num?)?.toInt() ?? 0,
      );
}

class PlanVersion {
  final String id;
  final String conversationId;
  final String? parentId;

  /// Local revision counter; increments on every local edit of this version.
  final int revision;

  final DateTime createdAt;
  final String summary;

  /// Fallback title derived from the submitted material, used when the model did
  /// not produce a summary. A missing summary must never discard a valid plan.
  final String sourceSummary;

  final String signatureAlgorithm;
  final String algorithmVersion;

  final List<TaskRecord> tasks;
  final List<PlanNote> notes;
  final List<RemovedCompleted> removedCompleted;
  final List<ReviewNote> reviewNotes;

  /// 'initial' or 'supplement'.
  final String commitReason;

  /// Calendar half of this version (0.06): availability rules, occupancy and the
  /// scheduled segments. Absent in versions written before 0.06 — a missing field is
  /// read as "no calendar data yet", never as "24/7 available".
  final CalendarSchedule calendar;

  /// 0.1.1: 结构化周时间表（协议 v2）。旧版本没有该字段时由 [calendar] 推导，
  /// 不把“尚未配置”当成全天可用。
  final Timetable? timetable;

  /// Which profile/model produced this version. `null` means "来源未知": versions
  /// committed before 0.0.4 (and failed requests) carry no source, and the UI must say
  /// so rather than inventing a name.
  final ModelSource? modelSource;

  const PlanVersion({
    required this.id,
    required this.conversationId,
    this.parentId,
    this.revision = 0,
    required this.createdAt,
    required this.summary,
    this.sourceSummary = '',
    this.signatureAlgorithm = 'execution-v1',
    this.algorithmVersion = '1.0',
    this.tasks = const [],
    this.notes = const [],
    this.removedCompleted = const [],
    this.reviewNotes = const [],
    this.commitReason = 'initial',
    this.calendar = const CalendarSchedule(),
    this.timetable,
    this.modelSource,
  });

  LocalPlan get plan => LocalPlan(summary: summary, tasks: tasks, notes: notes);

  String get displayTitle {
    if (summary.trim().isNotEmpty) return summary.trim();
    if (sourceSummary.trim().isNotEmpty) return sourceSummary.trim();
    return '未命名计划';
  }

  PlanVersion copyWith({
    int? revision,
    List<TaskRecord>? tasks,
    List<PlanNote>? notes,
    CalendarSchedule? calendar,
    Timetable? timetable,
  }) =>
      PlanVersion(
        id: id,
        conversationId: conversationId,
        parentId: parentId,
        revision: revision ?? this.revision,
        createdAt: createdAt,
        summary: summary,
        sourceSummary: sourceSummary,
        signatureAlgorithm: signatureAlgorithm,
        algorithmVersion: algorithmVersion,
        tasks: tasks ?? this.tasks,
        notes: notes ?? this.notes,
        removedCompleted: removedCompleted,
        reviewNotes: reviewNotes,
        commitReason: commitReason,
        calendar: calendar ?? this.calendar,
        timetable: timetable ?? this.timetable,
        modelSource: modelSource,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'conversationId': conversationId,
        'parentId': parentId,
        'revision': revision,
        'createdAt': createdAt.toIso8601String(),
        'summary': summary,
        'sourceSummary': sourceSummary,
        'signatureAlgorithm': signatureAlgorithm,
        'algorithmVersion': algorithmVersion,
        'commitReason': commitReason,
        // 0.06: calendar data is additive. A version written before it simply has no
        // `calendar` key and reads back as "no calendar data yet".
        'calendar': calendar.toJson(),
        // 0.1.1: 新字段；缺失时由 calendar 推导，旧文件读取不会失败。
        'timetable': timetable?.toJson(),
        // Null for older versions; `fromJson` keeps that "unknown" instead of guessing.
        'modelSource': modelSource?.toJson(),
        'tasks': tasks.map((t) {
          // Local-only facts are stored next to the plain task fields: the C core
          // neither needs nor is allowed to decide them.
          final m = t.toLocalJson();
          m['completion'] = completionToJson(t.completion);
          m['completionNote'] = t.completionNote;
          m['executionSignature'] = t.executionSignature;
          return m;
        }).toList(growable: false),
        'notes': notes.map((n) => n.toJson()).toList(growable: false),
        'removedCompleted':
            removedCompleted.map((r) => r.toJson()).toList(growable: false),
        'reviewNotes': reviewNotes.map((r) => r.toJson()).toList(growable: false),
      };

  factory PlanVersion.fromJson(Map<String, dynamic> j) {
    return PlanVersion(
      id: (j['id'] as String?) ?? '',
      conversationId: (j['conversationId'] as String?) ?? '',
      parentId: j['parentId'] as String?,
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      summary: (j['summary'] as String?) ?? '',
      sourceSummary: (j['sourceSummary'] as String?) ?? '',
      signatureAlgorithm: (j['signatureAlgorithm'] as String?) ?? 'execution-v1',
      algorithmVersion: (j['algorithmVersion'] as String?) ?? '1.0',
      commitReason: (j['commitReason'] as String?) ?? 'initial',
      modelSource: ModelSource.fromJson(j['modelSource']),
      tasks: ((j['tasks'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((t) => TaskRecord.fromLocalJson(
                t,
                completion: completionFromJson(t['completion'] as String?),
                executionSignature: (t['executionSignature'] as String?) ?? '',
              ))
          .toList(growable: false),
      notes: ((j['notes'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlanNote.fromJson)
          .toList(growable: false),
      removedCompleted: ((j['removedCompleted'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RemovedCompleted.fromJson)
          .toList(growable: false),
      reviewNotes: ((j['reviewNotes'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ReviewNote.fromJson)
          .toList(growable: false),
      calendar: CalendarSchedule.fromJson(j['calendar'], now: DateTime.now()),
      timetable: Timetable.tryParse(j['timetable']),
    );
  }
}

/// Persisted record of an in-flight request. Written before the request starts and
/// cleared on a terminal event, so a crash cannot leave a "phantom lock".
class PendingRequest {
  final String requestId;
  final String? baseVersionId;
  final int baseRevision;
  final DateTime startedAt;

  const PendingRequest({
    required this.requestId,
    required this.baseVersionId,
    required this.baseRevision,
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'requestId': requestId,
        'baseVersionId': baseVersionId,
        'baseRevision': baseRevision,
        'startedAt': startedAt.toIso8601String(),
      };

  factory PendingRequest.fromJson(Map<String, dynamic> j) => PendingRequest(
        requestId: (j['requestId'] as String?) ?? '',
        baseVersionId: j['baseVersionId'] as String?,
        baseRevision: (j['baseRevision'] as num?)?.toInt() ?? 0,
        startedAt:
            DateTime.tryParse((j['startedAt'] as String?) ?? '') ?? DateTime.now(),
      );
}

/// User-owned conversation metadata. Kept separate from the model-generated title so
/// re-analysis/version switching can never overwrite a manual name.
class ConversationMeta {
  const ConversationMeta({
    this.customTitle,
    this.pinOrder,
    this.archivedAt,
    this.deletedAt,
  });

  final String? customTitle;
  final int? pinOrder;
  final DateTime? archivedAt;
  final DateTime? deletedAt;

  bool get isPinned => pinOrder != null;
  bool get isArchived => archivedAt != null;
  bool get isDeleted => deletedAt != null;

  String titleFor(String generatedTitle) {
    final custom = customTitle?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final auto = generatedTitle.trim();
    return auto.isEmpty ? '新会话' : auto;
  }

  ConversationMeta rename(String value) => ConversationMeta(
        customTitle: value.trim().isEmpty ? null : value.trim(),
        pinOrder: pinOrder,
        archivedAt: archivedAt,
        deletedAt: deletedAt,
      );

  ConversationMeta withPin(int? order) => ConversationMeta(
        customTitle: customTitle,
        pinOrder: order,
        archivedAt: archivedAt,
        deletedAt: deletedAt,
      );

  ConversationMeta withArchived(DateTime? at) => ConversationMeta(
        customTitle: customTitle,
        pinOrder: pinOrder,
        archivedAt: at,
        deletedAt: deletedAt,
      );

  ConversationMeta withDeleted(DateTime? at) => ConversationMeta(
        customTitle: customTitle,
        pinOrder: pinOrder,
        archivedAt: archivedAt,
        deletedAt: at,
      );

  /// Restoring from trash keeps the earlier archive/pin state.
  ConversationMeta restoreDeleted() => ConversationMeta(
        customTitle: customTitle,
        pinOrder: pinOrder,
        archivedAt: archivedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'customTitle': customTitle,
        'pinOrder': pinOrder,
        'archivedAt': archivedAt?.toUtc().toIso8601String(),
        'deletedAt': deletedAt?.toUtc().toIso8601String(),
      };

  factory ConversationMeta.fromJson(Object? raw) {
    final j = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    DateTime? date(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toUtc() : null;
    final title = j['customTitle'];
    final order = j['pinOrder'];
    return ConversationMeta(
      customTitle: title is String && title.trim().isNotEmpty
          ? title.trim()
          : null,
      pinOrder: order is int && order >= 0 ? order : null,
      archivedAt: date(j['archivedAt']),
      deletedAt: date(j['deletedAt']),
    );
  }
}

class Conversation {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ConversationMeta meta;

  /// Last *content* activity. View switches (tree/gantt) must not reorder the list,
  /// so they update [updatedAt] only for backwards compatibility while sorting uses
  /// this field.
  final DateTime activityAt;
  final List<ChatMessage> messages;
  final List<PlanVersion> versions;
  final String? currentVersionId;
  final String draftText;
  final List<Attachment> attachments;
  final PendingRequest? pendingRequest;

  /// Last selected dependency view ('tree' or 'gantt'), remembered per conversation
  /// so reopening a plan returns to the view the user was using.
  final String chartMode;

  /// 0.06: last selected gantt sub-mode — 'relative' (cumulative remaining hours) or
  /// 'calendar' (real dates). A conversation that has never been switched defaults to
  /// 'relative', so old sessions keep their original semantics.
  final String ganttMode;

  /// Per-conversation model override. `null` (and the value written by older builds)
  /// means "follow the global default selection". Persisted so switching back to the
  /// conversation restores the same connection.
  final ModelSelection? modelSelection;

  /// 0.07: last validated set of calendar-constraint *proposals* for this conversation.
  ///
  /// Cached (and persisted) so reopening the calendar dialog does not spend another
  /// model request. [CalendarProposalSet.materialSignature] ties it to the exact
  /// material it was computed from: if the user adds a file or edits the draft, the
  /// cached answer is no longer presented as current and the dialog asks again.
  /// Proposals are never applied automatically.
  final CalendarProposalSet? calendarProposals;

  /// 0.1.1: 空会话在首次提交前也可以编辑时间表；取消不留附件，应用/保存才写入。
  final Timetable? calendarDraft;

  /// 是否把已提交的时间表随下一次模型请求发送。移除只影响请求附带项。
  final bool includeTimetable;

  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.meta = const ConversationMeta(),
    DateTime? activityAt,
    this.messages = const [],
    this.versions = const [],
    this.currentVersionId,
    this.draftText = '',
    this.attachments = const [],
    this.pendingRequest,
    this.chartMode = 'tree',
    this.ganttMode = 'relative',
    this.modelSelection,
    this.calendarProposals,
    this.calendarDraft,
    this.includeTimetable = true,
  }) : activityAt = activityAt ?? updatedAt;

  String get generatedTitle {
    final v = currentVersion;
    if (v != null) return v.displayTitle;
    return title.trim();
  }

  /// Title the UI shows: a manual name wins over the auto title until it is cleared.
  String get listTitle => meta.titleFor(generatedTitle);

  bool get isPinned => meta.isPinned;
  bool get isArchived => meta.isArchived;
  bool get isDeleted => meta.isDeleted;

  PlanVersion? get currentVersion {
    if (versions.isEmpty) return null;
    final id = currentVersionId;
    if (id != null) {
      for (final v in versions) {
        if (v.id == id) return v;
      }
    }
    return versions.last;
  }

  bool get hasVersions => versions.isNotEmpty;

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    DateTime? activityAt,
    ConversationMeta? meta,
    List<ChatMessage>? messages,
    List<PlanVersion>? versions,
    String? currentVersionId,
    bool clearCurrentVersion = false,
    String? draftText,
    List<Attachment>? attachments,
    PendingRequest? pendingRequest,
    bool clearPendingRequest = false,
    String? chartMode,
    String? ganttMode,
    ModelSelection? modelSelection,
    bool clearModelSelection = false,
    CalendarProposalSet? calendarProposals,
    bool clearCalendarProposals = false,
    Timetable? calendarDraft,
    bool clearCalendarDraft = false,
    bool? includeTimetable,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        meta: meta ?? this.meta,
        activityAt: activityAt ?? this.activityAt,
        messages: messages ?? this.messages,
        versions: versions ?? this.versions,
        currentVersionId:
            clearCurrentVersion ? null : (currentVersionId ?? this.currentVersionId),
        draftText: draftText ?? this.draftText,
        attachments: attachments ?? this.attachments,
        pendingRequest:
            clearPendingRequest ? null : (pendingRequest ?? this.pendingRequest),
        chartMode: chartMode ?? this.chartMode,
        ganttMode: ganttMode ?? this.ganttMode,
        modelSelection: clearModelSelection
            ? null
            : (modelSelection ?? this.modelSelection),
        calendarProposals: clearCalendarProposals
            ? null
            : (calendarProposals ?? this.calendarProposals),
        calendarDraft:
            clearCalendarDraft ? null : (calendarDraft ?? this.calendarDraft),
        includeTimetable: includeTimetable ?? this.includeTimetable,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': 2,
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'activityAt': activityAt.toIso8601String(),
        'meta': meta.toJson(),
        'currentVersionId': currentVersionId,
        'draftText': draftText,
        'chartMode': chartMode,
        'ganttMode': ganttMode,
        'modelSelection': modelSelection?.toJson(),
        'calendarProposals': calendarProposals?.toJson(),
        'calendarDraft': calendarDraft?.toJson(),
        'includeTimetable': includeTimetable,
        'pendingRequest': pendingRequest?.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(growable: false),
        'attachments': attachments.map((a) => a.toJson()).toList(growable: false),
        'versions': versions.map((v) => v.toJson()).toList(growable: false),
      };

  factory Conversation.fromJson(Map<String, dynamic> j) {
    final updated =
        DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now();
    return Conversation(
      id: (j['id'] as String?) ?? '',
      title: (j['title'] as String?) ?? '',
      createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
      updatedAt: updated,
      activityAt: DateTime.tryParse((j['activityAt'] as String?) ?? '') ?? updated,
      meta: ConversationMeta.fromJson(j['meta']),
      currentVersionId: j['currentVersionId'] as String?,
      draftText: (j['draftText'] as String?) ?? '',
      messages: ((j['messages'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(growable: false),
      attachments: ((j['attachments'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Attachment.fromJson)
          .toList(growable: false),
      versions: ((j['versions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlanVersion.fromJson)
          .toList(growable: false),
      pendingRequest: j['pendingRequest'] is Map<String, dynamic>
          ? PendingRequest.fromJson(j['pendingRequest'] as Map<String, dynamic>)
          : null,
      chartMode: (j['chartMode'] as String?) ?? 'tree',
      ganttMode: j['ganttMode'] == 'calendar' ? 'calendar' : 'relative',
      modelSelection: ModelSelection.tryParse(j['modelSelection']),
      // Older sessions have no cached proposals: that is "never analysed", not
      // "nothing found", so it stays null instead of becoming an empty set.
      calendarProposals: CalendarProposalSet.fromJson(j['calendarProposals']),
      calendarDraft: Timetable.tryParse(j['calendarDraft']),
      includeTimetable: j['includeTimetable'] != false,
    );
  }
}

/// Light-weight row for the history sidebar (avoids loading every conversation).
class ConversationSummary {
  final String id;
  final String title;
  final DateTime updatedAt;
  final DateTime activityAt;
  final int versionCount;
  final String? currentVersionId;
  final ConversationMeta meta;

  const ConversationSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    DateTime? activityAt,
    required this.versionCount,
    this.currentVersionId,
    this.meta = const ConversationMeta(),
  }) : activityAt = activityAt ?? updatedAt;

  String get displayTitle => meta.titleFor(title);

  bool get isPinned => meta.isPinned;
  bool get isArchived => meta.isArchived;
  bool get isDeleted => meta.isDeleted;

  ConversationSummary copyWith({
    String? title,
    DateTime? updatedAt,
    DateTime? activityAt,
    int? versionCount,
    String? currentVersionId,
    ConversationMeta? meta,
  }) =>
      ConversationSummary(
        id: id,
        title: title ?? this.title,
        updatedAt: updatedAt ?? this.updatedAt,
        activityAt: activityAt ?? this.activityAt,
        versionCount: versionCount ?? this.versionCount,
        currentVersionId: currentVersionId ?? this.currentVersionId,
        meta: meta ?? this.meta,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': 2,
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'activityAt': activityAt.toIso8601String(),
        'meta': meta.toJson(),
        'versionCount': versionCount,
        'currentVersionId': currentVersionId,
      };

  factory ConversationSummary.fromJson(Map<String, dynamic> j) {
    final updated =
        DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now();
    return ConversationSummary(
      id: (j['id'] as String?) ?? '',
      title: (j['title'] as String?) ?? '',
      updatedAt: updated,
      activityAt:
          DateTime.tryParse((j['activityAt'] as String?) ?? '') ?? updated,
      versionCount: (j['versionCount'] as num?)?.toInt() ?? 0,
      currentVersionId: j['currentVersionId'] as String?,
      meta: ConversationMeta.fromJson(j['meta']),
    );
  }

  factory ConversationSummary.of(Conversation c) => ConversationSummary(
        id: c.id,
        title: c.generatedTitle,
        updatedAt: c.updatedAt,
        activityAt: c.activityAt,
        versionCount: c.versions.length,
        currentVersionId: c.currentVersionId,
        meta: c.meta,
      );
}
