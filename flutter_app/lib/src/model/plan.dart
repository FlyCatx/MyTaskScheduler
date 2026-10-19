// Local plan model — the "lp" JSON format owned by this app.
//
// This is NOT the model output format. The model speaks snake_case with per-response
// ids like T1/T2; here every task has a locally generated STABLE id that survives
// versions, plus the locally computed execution signature and completion state.
//
// Only this structure is ever sent to the C core for validation/rescheduling, which
// keeps "what the model said" and "what the app believes locally" strictly apart.

import 'dart:math';

/// Completion state of a task. `needsReview` means "the previous version had this
/// done, but the content changed, so the user must confirm again".
enum Completion { todo, done, needsReview }

String completionToJson(Completion c) => switch (c) {
      Completion.todo => 'todo',
      Completion.done => 'done',
      Completion.needsReview => 'needsReview',
    };

Completion completionFromJson(String? s) => switch (s) {
      'done' => Completion.done,
      'needsReview' => Completion.needsReview,
      _ => Completion.todo,
    };

/// Why a task's completion state needs the user's attention.
enum ReviewKind { changed, split, merge, ambiguous }

/// Recorded when a previously completed task cannot inherit "done" — because its
/// content changed, or because of a split/merge. Never auto-cleared.
class ReviewNote {
  final String taskId;
  final String? previousTaskId;
  final ReviewKind kind;
  final String text;

  const ReviewNote({
    required this.taskId,
    required this.kind,
    required this.text,
    this.previousTaskId,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'taskId': taskId,
        'previousTaskId': previousTaskId,
        'kind': kind.name,
        'text': text,
      };

  factory ReviewNote.fromJson(Map<String, dynamic> j) => ReviewNote(
        taskId: (j['taskId'] as String?) ?? '',
        previousTaskId: j['previousTaskId'] as String?,
        kind: ReviewKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => ReviewKind.changed,
        ),
        text: (j['text'] as String?) ?? '',
      );
}

/// A completed task from the previous version that no longer exists in the new one.
/// Kept in the change summary instead of disappearing silently.
class RemovedCompleted {
  final String id;
  final String name;
  const RemovedCompleted({required this.id, required this.name});

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};

  factory RemovedCompleted.fromJson(Map<String, dynamic> j) => RemovedCompleted(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
      );
}

class Precondition {
  final String description;
  final String status; // met | unmet | unknown

  const Precondition({required this.description, required this.status});

  Precondition copyWith({String? status}) =>
      Precondition(description: description, status: status ?? this.status);

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'description': description, 'status': status};

  factory Precondition.fromJson(Map<String, dynamic> j) => Precondition(
        description: (j['description'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'unknown',
      );
}

/// A task that the user must look at: question / blocked / assumption.
class PlanNote {
  final String kind; // question | blocked | assumption
  final String text;

  /// Stable task ids (not model ids) so the UI can jump to the related task.
  final List<String> taskIds;

  const PlanNote({required this.kind, required this.text, this.taskIds = const []});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'text': text,
        'taskRefs': taskIds,
      };

  factory PlanNote.fromJson(Map<String, dynamic> j) => PlanNote(
        kind: (j['kind'] as String?) ?? 'question',
        text: (j['text'] as String?) ?? '',
        taskIds: ((j['taskRefs'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
      );
}

class TaskRecord {
  final String id;
  final String name;
  final String? previousTaskId;
  final List<String> steps;
  final List<String> dependsOn; // stable ids
  final List<Precondition> preconditions;
  final double? estimatedHours;
  final String? estimateReason;
  final String? deadline;
  final int urgency;
  final int impact;
  final String? urgencyReason;
  final String? impactReason;
  final List<String> sourceRefs;

  /// Locally computed; the model can neither produce nor override it.
  final String executionSignature;

  final Completion completion;
  final String? completionNote;

  /// Set when a local edit made the task unschedulable for a non-task reason
  /// (kept for completeness; normal blocked/pending comes from preconditions).
  final String? schedulingBlock;

  const TaskRecord({
    required this.id,
    required this.name,
    this.previousTaskId,
    this.steps = const [],
    this.dependsOn = const [],
    this.preconditions = const [],
    this.estimatedHours,
    this.estimateReason,
    this.deadline,
    this.urgency = 3,
    this.impact = 3,
    this.urgencyReason,
    this.impactReason,
    this.sourceRefs = const [],
    this.executionSignature = '',
    this.completion = Completion.todo,
    this.completionNote,
    this.schedulingBlock,
  });

  bool get isDone => completion == Completion.done;
  bool get needsReview => completion == Completion.needsReview;
  bool get hoursKnown => estimatedHours != null && estimatedHours! > 0;

  TaskRecord copyWith({
    String? id,
    String? name,
    String? previousTaskId,
    List<String>? steps,
    List<String>? dependsOn,
    List<Precondition>? preconditions,
    double? estimatedHours,
    bool clearEstimatedHours = false,
    String? estimateReason,
    String? deadline,
    int? urgency,
    int? impact,
    String? urgencyReason,
    String? impactReason,
    List<String>? sourceRefs,
    String? executionSignature,
    Completion? completion,
    String? completionNote,
    bool clearCompletionNote = false,
    String? schedulingBlock,
  }) {
    return TaskRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      previousTaskId: previousTaskId ?? this.previousTaskId,
      steps: steps ?? this.steps,
      dependsOn: dependsOn ?? this.dependsOn,
      preconditions: preconditions ?? this.preconditions,
      estimatedHours:
          clearEstimatedHours ? null : (estimatedHours ?? this.estimatedHours),
      estimateReason: estimateReason ?? this.estimateReason,
      deadline: deadline ?? this.deadline,
      urgency: urgency ?? this.urgency,
      impact: impact ?? this.impact,
      urgencyReason: urgencyReason ?? this.urgencyReason,
      impactReason: impactReason ?? this.impactReason,
      sourceRefs: sourceRefs ?? this.sourceRefs,
      executionSignature: executionSignature ?? this.executionSignature,
      completion: completion ?? this.completion,
      completionNote:
          clearCompletionNote ? null : (completionNote ?? this.completionNote),
      schedulingBlock: schedulingBlock ?? this.schedulingBlock,
    );
  }

  Map<String, dynamic> toLocalJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'previousTaskId': previousTaskId,
        'dependsOn': dependsOn,
        'preconditions':
            preconditions.map((p) => p.toJson()).toList(growable: false),
        'steps': steps,
        'urgency': urgency,
        'urgencyReason': urgencyReason,
        'impact': impact,
        'impactReason': impactReason,
        'estimatedHours': estimatedHours,
        'estimateReason': estimateReason,
        'deadline': deadline,
        'sourceRefs': sourceRefs,
        'actualStatus': isDone ? 'done' : 'todo',
      };

  /// Parses a task produced by the C core (`ts_local_plan_to_json`). Completion and
  /// signature are intentionally kept from the local record when available.
  factory TaskRecord.fromLocalJson(
    Map<String, dynamic> j, {
    Completion? completion,
    String? executionSignature,
  }) {
    return TaskRecord(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      previousTaskId: j['previousTaskId'] as String?,
      steps: _strList(j['steps']),
      dependsOn: _strList(j['dependsOn']),
      preconditions: ((j['preconditions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Precondition.fromJson)
          .toList(growable: false),
      estimatedHours: (j['estimatedHours'] as num?)?.toDouble(),
      estimateReason: j['estimateReason'] as String?,
      deadline: j['deadline'] as String?,
      urgency: (j['urgency'] as num?)?.toInt() ?? 3,
      impact: (j['impact'] as num?)?.toInt() ?? 3,
      urgencyReason: j['urgencyReason'] as String?,
      impactReason: j['impactReason'] as String?,
      sourceRefs: _strList(j['sourceRefs']),
      executionSignature: executionSignature ?? '',
      completion: completion ?? Completion.todo,
    );
  }

  static List<String> _strList(dynamic v) => ((v as List<dynamic>?) ?? const [])
      .map((e) => e.toString())
      .toList(growable: false);
}

/// A whole plan as the app stores it (stable ids only).
class LocalPlan {
  final String summary;
  final List<TaskRecord> tasks;
  final List<PlanNote> notes;

  const LocalPlan({this.summary = '', this.tasks = const [], this.notes = const []});

  Map<String, dynamic> toLocalJson() => <String, dynamic>{
        'schemaVersion': '1',
        'summary': summary,
        'tasks': tasks.map((t) => t.toLocalJson()).toList(growable: false),
        'notes': notes.map((n) => n.toJson()).toList(growable: false),
      };

  TaskRecord? taskById(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  LocalPlan copyWith({String? summary, List<TaskRecord>? tasks, List<PlanNote>? notes}) =>
      LocalPlan(
        summary: summary ?? this.summary,
        tasks: tasks ?? this.tasks,
        notes: notes ?? this.notes,
      );
}

/// Local id generator. Ids must be unique and stable across versions; they are
/// never derived from model ids or list positions.
class IdGenerator {
  static final Random _random = Random.secure();
  static int _counter = 0;

  static String next(String prefix) {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rnd = _random.nextInt(1 << 32).toRadixString(36);
    final c = (_counter++).toRadixString(36);
    return '$prefix-$ts-$c$rnd';
  }
}

