// Display DTOs — exactly what the UI is allowed to render.
//
// Produced by the C core (`ts_display_build`) from the validated plan + schedule.
// It never contains scores, weights, formulas, candidate pools or model reasoning
// text. If a field is not here, the UI must not show it.

class RelatedTask {
  final String id;
  final String name;

  const RelatedTask({required this.id, required this.name});

  factory RelatedTask.fromJson(Map<String, dynamic> j) => RelatedTask(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
      );
}

class TaskCondition {
  final String text;
  final String status; // met | unmet | unknown

  const TaskCondition({required this.text, required this.status});

  String get statusText => switch (status) {
        'met' => '已满足',
        'unmet' => '未满足',
        _ => '待确认',
      };

  factory TaskCondition.fromJson(Map<String, dynamic> j) => TaskCondition(
        text: (j['text'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'unknown',
      );
}

class NoteView {
  final String kind; // question | blocked | assumption
  final String text;
  final List<RelatedTask> tasks;

  const NoteView({required this.kind, required this.text, this.tasks = const []});

  String get kindText => switch (kind) {
        'blocked' => '受阻',
        'assumption' => '分析假设',
        _ => '待确认',
      };

  factory NoteView.fromJson(Map<String, dynamic> j) => NoteView(
        kind: (j['kind'] as String?) ?? 'question',
        text: (j['text'] as String?) ?? '',
        tasks: ((j['tasks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RelatedTask.fromJson)
            .toList(growable: false),
      );
}

/// How a task appears on the relative-hour timeline.
enum ScheduleState { scheduled, completed, unscheduled, blocked, pending, unknownHours, invalid }

ScheduleState scheduleStateFrom(String? s) => switch (s) {
      'scheduled' => ScheduleState.scheduled,
      'completed' => ScheduleState.completed,
      'blocked' => ScheduleState.blocked,
      'pending' => ScheduleState.pending,
      'unknownHours' => ScheduleState.unknownHours,
      'unscheduled' => ScheduleState.unscheduled,
      _ => ScheduleState.invalid,
    };

class DisplayTask {
  final String id;
  final String name;
  final String status; // ready | waiting | pending | blocked | done | unknown
  final String statusText;
  final int level;
  final bool affected;
  final bool estimateKnown;
  final double? estimateHours;
  final String? deadline;
  final String? estimateReason;
  final List<String> steps;
  final List<String> sources;
  final List<String> reasons;
  final List<TaskCondition> conditions;
  final List<RelatedTask> predecessors;
  final List<RelatedTask> unlocks;
  final List<RelatedTask> stillWaiting;
  final ScheduleState scheduleState;
  final double? startHours;
  final double? endHours;
  final String? scheduleNote;
  final String? previousTaskId;

  const DisplayTask({
    required this.id,
    required this.name,
    required this.status,
    required this.statusText,
    this.level = 0,
    this.affected = false,
    this.estimateKnown = false,
    this.estimateHours,
    this.deadline,
    this.estimateReason,
    this.steps = const [],
    this.sources = const [],
    this.reasons = const [],
    this.conditions = const [],
    this.predecessors = const [],
    this.unlocks = const [],
    this.stillWaiting = const [],
    this.scheduleState = ScheduleState.unscheduled,
    this.startHours,
    this.endHours,
    this.scheduleNote,
    this.previousTaskId,
  });

  bool get isDone => status == 'done';
  bool get isReady => status == 'ready';
  bool get isBlocked => status == 'blocked';
  bool get isPending => status == 'pending';

  /// Compact estimate label. Never invents a value for unknown hours.
  String get estimateLabel {
    if (!estimateKnown || estimateHours == null) return '工时待确认';
    final h = estimateHours!;
    if (h < 1) return '约 ${(h * 60).round()} 分钟';
    if (h == h.roundToDouble()) return '约 ${h.round()} 小时';
    return '约 ${h.toStringAsFixed(1)} 小时';
  }

  factory DisplayTask.fromJson(Map<String, dynamic> j) {
    List<RelatedTask> rel(String key) =>
        ((j[key] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RelatedTask.fromJson)
            .toList(growable: false);
    List<String> strs(String key) => ((j[key] as List<dynamic>?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);

    return DisplayTask(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      status: (j['status'] as String?) ?? 'unknown',
      statusText: (j['statusText'] as String?) ?? '',
      level: (j['level'] as num?)?.toInt() ?? 0,
      affected: j['affected'] == true,
      estimateKnown: j['estimateKnown'] == true,
      estimateHours: (j['estimateHours'] as num?)?.toDouble(),
      deadline: j['deadline'] as String?,
      estimateReason: j['estimateReason'] as String?,
      steps: strs('steps'),
      sources: strs('sources'),
      reasons: strs('reasons'),
      conditions: ((j['conditions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TaskCondition.fromJson)
          .toList(growable: false),
      predecessors: rel('predecessors'),
      unlocks: rel('unlocks'),
      stillWaiting: rel('stillWaiting'),
      scheduleState: scheduleStateFrom(j['scheduleState'] as String?),
      startHours: (j['startHours'] as num?)?.toDouble(),
      endHours: (j['endHours'] as num?)?.toDouble(),
      scheduleNote: j['scheduleNote'] as String?,
      previousTaskId: j['previousTaskId'] as String?,
    );
  }
}

class DisplayCounts {
  final int total;
  final int ready;
  final int waiting;
  final int blocked;
  final int pending;
  final int done;
  final int unknownHours;

  const DisplayCounts({
    this.total = 0,
    this.ready = 0,
    this.waiting = 0,
    this.blocked = 0,
    this.pending = 0,
    this.done = 0,
    this.unknownHours = 0,
  });

  factory DisplayCounts.fromJson(Map<String, dynamic>? j) {
    int v(String k) => (j?[k] as num?)?.toInt() ?? 0;
    return DisplayCounts(
      total: v('total'),
      ready: v('ready'),
      waiting: v('waiting'),
      blocked: v('blocked'),
      pending: v('pending'),
      done: v('done'),
      unknownHours: v('unknownHours'),
    );
  }
}

class DisplaySnapshot {
  final String summary;
  final String sortedAt;
  final String? unresolvableReason;
  final List<DisplayTask> tasks;
  final List<String> order;
  final List<String> blocked;
  final List<String> pending;
  final List<String> affected;
  final List<NoteView> notes;
  final DisplayCounts counts;

  const DisplaySnapshot({
    this.summary = '',
    this.sortedAt = '',
    this.unresolvableReason,
    this.tasks = const [],
    this.order = const [],
    this.blocked = const [],
    this.pending = const [],
    this.affected = const [],
    this.notes = const [],
    this.counts = const DisplayCounts(),
  });

  DisplayTask? byId(String? id) {
    if (id == null) return null;
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Position in the suggested order (1-based); 0 when not scheduled.
  int orderIndex(String id) {
    final i = order.indexOf(id);
    return i < 0 ? 0 : i + 1;
  }

  /// Tasks in the C-provided suggested order (single-person serial order).
  List<DisplayTask> get orderedTasks {
    final out = <DisplayTask>[];
    for (final id in order) {
      final t = byId(id);
      if (t != null) out.add(t);
    }
    return out;
  }

  List<DisplayTask> get completedTasks =>
      tasks.where((t) => t.scheduleState == ScheduleState.completed).toList();

  /// Tasks that exist but have no definite position on the timeline.
  List<DisplayTask> get unscheduledTasks => tasks
      .where((t) => t.scheduleState != ScheduleState.scheduled &&
          t.scheduleState != ScheduleState.completed)
      .toList();

  /// Total known remaining hours (sum of definite bars). Used only for axis width;
  /// never presented as "the whole plan will take N hours".
  double get totalKnownHours {
    double max = 0;
    for (final t in tasks) {
      if (t.endHours != null && t.endHours! > max) max = t.endHours!;
    }
    return max;
  }

  factory DisplaySnapshot.fromJson(Map<String, dynamic> j) => DisplaySnapshot(
        summary: (j['summary'] as String?) ?? '',
        sortedAt: (j['sortedAt'] as String?) ?? '',
        unresolvableReason: j['unresolvableReason'] as String?,
        tasks: ((j['tasks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DisplayTask.fromJson)
            .toList(growable: false),
        order: ((j['order'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        blocked: ((j['blocked'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        pending: ((j['pending'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        affected: ((j['affected'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        notes: ((j['notes'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(NoteView.fromJson)
            .toList(growable: false),
        counts: DisplayCounts.fromJson(j['counts'] as Map<String, dynamic>?),
      );
}

