// 按稳定任务 ID 比较两个计划版本，得到字段级差异（历史版本视图使用）。
// 比较只用 TaskRecord.id：名称属于展示数据，同名不同 ID 不视为同一任务。
//
// 主要类型：TaskFieldChange、VersionDiff。

import 'plan.dart';
import 'session.dart';

class TaskFieldChange {
  final String taskId;
  final String name;
  final Set<String> fields;
  const TaskFieldChange(this.taskId, this.name, this.fields);
}

class VersionDiff {
  final PlanVersion? before;
  final PlanVersion after;
  final List<TaskRecord> added;
  final List<TaskRecord> removed;
  final List<TaskFieldChange> changed;
  final int inheritedCompleted;
  final int needsReview;
  final int stillCompleted;
  final String? unknownIdentityNote;

  const VersionDiff({
    this.before,
    required this.after,
    this.added = const [],
    this.removed = const [],
    this.changed = const [],
    this.inheritedCompleted = 0,
    this.needsReview = 0,
    this.stillCompleted = 0,
    this.unknownIdentityNote,
  });

  bool get hasChanges =>
      added.isNotEmpty || removed.isNotEmpty || changed.isNotEmpty;

  int get changedCount => added.length + removed.length + changed.length;
}

VersionDiff computeVersionDiff(PlanVersion? before, PlanVersion after) {
  if (before == null) {
    return VersionDiff(
      before: before,
      after: after,
      added: after.tasks,
      stillCompleted: after.tasks
          .where((t) => t.completion == Completion.done)
          .length,
    );
  }
  final oldById = {for (final t in before.tasks) t.id: t};
  final newById = {for (final t in after.tasks) t.id: t};
  final added = <TaskRecord>[];
  final removed = <TaskRecord>[];
  final changed = <TaskFieldChange>[];
  for (final t in after.tasks) {
    final old = oldById[t.id];
    if (old == null) {
      added.add(t);
      continue;
    }
    final fields = <String>{};
    if (old.name != t.name) fields.add('名称');
    if (old.estimatedHours != t.estimatedHours) fields.add('预计工时');
    if (old.deadline != t.deadline) fields.add('截止日期');
    final oldDeps = old.dependsOn.toSet();
    final newDeps = t.dependsOn.toSet();
    if (oldDeps.length != newDeps.length ||
        !oldDeps.containsAll(newDeps)) {
      fields.add('前置任务');
    }
    if (fields.isNotEmpty) changed.add(TaskFieldChange(t.id, t.name, fields));
  }
  for (final t in before.tasks) {
    if (!newById.containsKey(t.id)) removed.add(t);
  }
  final inherited = after.tasks.where((t) {
    final old = oldById[t.id];
    return old != null &&
        old.completion == Completion.done &&
        t.completion == Completion.done;
  }).length;
  final review = after.tasks
      .where((t) => t.completion == Completion.needsReview)
      .length;
  final completed = after.tasks
      .where((t) => t.completion == Completion.done)
      .length;
  return VersionDiff(
    before: before,
    after: after,
    added: added,
    removed: removed,
    changed: changed,
    inheritedCompleted: inherited,
    needsReview: review,
    stillCompleted: completed,
    unknownIdentityNote: before.tasks.any((t) => t.id.trim().isEmpty)
        ? '旧版本中有缺少稳定 ID 的任务，无法可靠判断其身份；差异只对可见 ID 负责。'
        : null,
  );
}

