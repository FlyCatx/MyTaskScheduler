import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/version_diff.dart';

PlanVersion version(String id, List<TaskRecord> tasks) => PlanVersion(
      id: id,
      conversationId: 'c',
      createdAt: DateTime(2026, 10, 18),
      summary: id,
      tasks: tasks,
    );

void main() {
  test('diff uses stable ids and reports add/remove/field changes', () {
    final before = version('v1', [
      const TaskRecord(
          id: 'a', name: 'A', estimatedHours: 1, dependsOn: []),
      const TaskRecord(id: 'b', name: 'B', estimatedHours: 2),
    ]);
    final after = version('v2', [
      const TaskRecord(
          id: 'a',
          name: 'A 改名',
          estimatedHours: 1.5,
          dependsOn: ['b'],
          deadline: '2026-10-31',
          completion: Completion.done),
      const TaskRecord(id: 'c', name: 'C', completion: Completion.needsReview),
    ]);
    final diff = computeVersionDiff(before, after);
    expect(diff.added.map((t) => t.id), ['c']);
    expect(diff.removed.map((t) => t.id), ['b']);
    final changed = diff.changed.single;
    expect(changed.taskId, 'a');
    expect(changed.fields,
        containsAll(<String>['名称', '预计工时', '截止日期', '前置任务']));
    expect(diff.needsReview, 1);
  });

  test('same name with different id is not treated as the same task', () {
    final before =
        version('v1', [const TaskRecord(id: 'old', name: '同名')]);
    final after =
        version('v2', [const TaskRecord(id: 'new', name: '同名')]);
    final diff = computeVersionDiff(before, after);
    expect(diff.added.single.id, 'new');
    expect(diff.removed.single.id, 'old');
    expect(diff.changed, isEmpty);
  });

  test('first version reports every task as added', () {
    final diff = computeVersionDiff(
        null, version('v1', [const TaskRecord(id: 'a', name: 'A')]));
    expect(diff.added, hasLength(1));
    expect(diff.removed, isEmpty);
  });
}

