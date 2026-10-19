// Unit tests for stable-identity matching and completion inheritance.
//
// These encode the requirement that completion must never be inherited by model id
// or by list position, and that splits/merges surface as "needs review" instead of a
// silent guess.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/state/reconciler.dart';
import 'package:taskscheduler_flutter/src/state/signature.dart';

int _idSeq = 0;
String newId() => 'new-${_idSeq++}';

TaskRecord prevTask(
  String id,
  String name, {
  List<String> steps = const [],
  List<String> deps = const [],
  Completion completion = Completion.todo,
  Map<String, String> depNames = const {},
}) {
  final t = TaskRecord(
    id: id,
    name: name,
    steps: steps,
    dependsOn: deps,
    completion: completion,
  );
  return t.copyWith(executionSignature: computeExecutionSignature(t, depNames));
}

/// A proposed task as the model would return it: model ids, no signature.
TaskRecord proposed(
  String modelId,
  String name, {
  List<String> steps = const [],
  List<String> deps = const [],
  String? previousTaskId,
}) =>
    TaskRecord(
      id: modelId,
      name: name,
      steps: steps,
      dependsOn: deps,
      previousTaskId: previousTaskId,
    );

void main() {
  setUp(() => _idSeq = 0);

  group('completion inheritance', () {
    test('unchanged work keeps its stable id and its done state', () {
      final previous = [prevTask('a', '整理要求', completion: Completion.done)];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '整理要求')],
        idFactory: newId,
      );
      expect(result.tasks.single.id, 'a');
      expect(result.tasks.single.completion, Completion.done);
      expect(result.reviewNotes, isEmpty);
    });

    test('content change keeps the id but asks for review', () {
      final previous = [
        prevTask('a', '整理要求', steps: ['读材料'], completion: Completion.done)
      ];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '整理要求', steps: ['读材料', '整理接口'])],
        idFactory: newId,
      );
      expect(result.tasks.single.id, 'a');
      expect(result.tasks.single.completion, Completion.needsReview);
      expect(result.tasks.single.completionNote, contains('内容有变化'));
      expect(result.reviewNotes.single.kind, ReviewKind.changed);
    });

    test('a brand new task never inherits done, even if the model claims it', () {
      final result = reconcileTasks(
        previous: const [],
        proposed: [proposed('T1', '全新任务')],
        idFactory: newId,
      );
      expect(result.tasks.single.completion, Completion.todo);
    });

    test('matching by list position would be wrong — order changes are handled', () {
      final previous = [
        prevTask('a', '任务甲', completion: Completion.done),
        prevTask('b', '任务乙', completion: Completion.done),
      ];
      // The new response lists them in the opposite order and renumbers the ids.
      final result = reconcileTasks(
        previous: previous,
        proposed: [
          proposed('T1', '任务乙'),
          proposed('T2', '任务甲'),
        ],
        idFactory: newId,
      );
      final byName = {for (final t in result.tasks) t.name: t};
      expect(byName['任务甲']!.id, 'a');
      expect(byName['任务乙']!.id, 'b');
      expect(byName['任务甲']!.completion, Completion.done);
      expect(byName['任务乙']!.completion, Completion.done);
    });

    test('model hint is honoured when it points at an existing task', () {
      final previous = [prevTask('a', '整理要求', completion: Completion.done)];
      final result = reconcileTasks(
        previous: previous,
        proposed: [
          proposed('T1', '整理要求（改写）', previousTaskId: 'a'),
        ],
        idFactory: newId,
      );
      expect(result.tasks.single.id, 'a');
      // The name changed, so the signature differs -> review, not silent done.
      expect(result.tasks.single.completion, Completion.needsReview);
    });

    test('a hint pointing at an unknown id is not trusted', () {
      final previous = [prevTask('a', '整理要求', completion: Completion.done)];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '别的任务', previousTaskId: 'does-not-exist')],
        idFactory: newId,
      );
      expect(result.tasks.single.id, isNot('a'));
      expect(result.tasks.single.completion, Completion.todo);
    });

    test('an unresolved review is never silently cleared', () {
      final previous = [
        prevTask('a', '整理要求', completion: Completion.needsReview),
      ];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '整理要求')],
        idFactory: newId,
      );
      expect(result.tasks.single.completion, Completion.needsReview);
    });

    test('splitting one task into two flags both halves for review', () {
      final previous = [prevTask('a', '实现顺序表', completion: Completion.done)];
      final result = reconcileTasks(
        previous: previous,
        proposed: [
          proposed('T1', '实现顺序表：初始化', previousTaskId: 'a'),
          proposed('T2', '实现顺序表：插入', previousTaskId: 'a'),
        ],
        idFactory: newId,
      );
      final notes = result.reviewNotes;
      expect(notes.any((n) => n.kind == ReviewKind.split), isTrue);
      expect(
        result.tasks.where((t) => t.completion == Completion.done),
        isEmpty,
        reason: '拆分后不能自动继承完成',
      );
    });

    test('merging two tasks into one asks for confirmation', () {
      final previous = [
        prevTask('a', '实现 ListInit', completion: Completion.done),
        prevTask('b', '实现 ListInsert', completion: Completion.done),
      ];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '实现 ListInit 与 ListInsert')],
        idFactory: newId,
      );
      expect(result.tasks.single.completion, isNot(Completion.done));
      expect(
        result.reviewNotes.any((n) => n.kind == ReviewKind.merge),
        isTrue,
      );
    });

    test('removed completed tasks are reported, not dropped silently', () {
      final previous = [
        prevTask('a', '已完成但被删除', completion: Completion.done),
        prevTask('b', '保留任务', completion: Completion.done),
      ];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '保留任务')],
        idFactory: newId,
      );
      expect(result.removedCompleted.single.id, 'a');
      expect(result.removedCompleted.single.name, '已完成但被删除');
    });

    test('dependencies are rewritten from model ids to stable ids', () {
      final previous = [
        prevTask('a', '第一步', completion: Completion.done),
        prevTask('b', '第二步',
            deps: ['a'],
            depNames: {'a': '第一步'},
            completion: Completion.done),
      ];
      final result = reconcileTasks(
        previous: previous,
        proposed: [
          proposed('T1', '第一步'),
          proposed('T2', '第二步', deps: ['T1']),
        ],
        idFactory: newId,
      );
      final second = result.tasks.firstWhere((t) => t.name == '第二步');
      expect(second.dependsOn, ['a']);
      expect(second.id, 'b');
      expect(second.completion, Completion.done);
    });

    test('new tasks get freshly minted ids and old ids are not reused', () {
      final previous = [prevTask('a', '旧任务', completion: Completion.done)];
      final result = reconcileTasks(
        previous: previous,
        proposed: [proposed('T1', '完全不同的任务')],
        idFactory: newId,
      );
      expect(result.tasks.single.id, startsWith('new-'));
      expect(result.tasks.single.id, isNot('a'));
      expect(result.removedCompleted.single.id, 'a');
    });
  });

  group('name similarity', () {
    test('exact match scores 100', () {
      expect(nameSimilarity('整理要求', '整理要求'), 100);
    });
    test('containment scores high', () {
      expect(nameSimilarity('整理要求', '整理要求并归档'), greaterThanOrEqualTo(80));
    });
    test('unrelated names score low', () {
      expect(nameSimilarity('整理要求', '部署上线'), lessThan(40));
    });
  });
}

