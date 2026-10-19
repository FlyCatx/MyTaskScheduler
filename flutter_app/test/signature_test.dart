// Unit tests for the locally computed execution signature.
//
// The rule under test: changing priority / estimate / deadline must NOT invalidate
// completion, while changing the goal, the steps, the dependencies or the external
// conditions must.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/state/signature.dart';

TaskRecord base() => const TaskRecord(
      id: 't1',
      name: '整理实验要求',
      steps: ['读说明', '整理接口'],
      preconditions: [Precondition(description: '教师提供材料', status: 'unknown')],
      estimatedHours: 2,
      urgency: 3,
      impact: 3,
      deadline: '2026-11-01',
    );

String sigOf(TaskRecord t, [Map<String, String> deps = const {}]) =>
    computeExecutionSignature(t, deps);

void main() {
  group('execution signature', () {
    test('identical content produces identical signature', () {
      expect(sigOf(base()), sigOf(base()));
    });

    test('estimate / urgency / impact / deadline changes do NOT change it', () {
      final modified = base().copyWith(
        estimatedHours: 5,
        urgency: 5,
        impact: 5,
        deadline: '2026-12-31',
      );
      expect(sigOf(modified), sigOf(base()));
    });

    test('external-condition STATUS changes do NOT change it', () {
      final confirmed = base().copyWith(preconditions: const [
        Precondition(description: '教师提供材料', status: 'met'),
      ]);
      expect(sigOf(confirmed), sigOf(base()));
    });

    test('name change DOES change it', () {
      expect(sigOf(base().copyWith(name: '整理接口要求')), isNot(sigOf(base())));
    });

    test('step change DOES change it', () {
      expect(
        sigOf(base().copyWith(steps: ['读说明'])),
        isNot(sigOf(base())),
      );
    });

    test('adding a dependency DOES change it', () {
      final withDep = base().copyWith(dependsOn: ['t0']);
      expect(
        sigOf(withDep, {'t0': '准备环境'}),
        isNot(sigOf(base())),
      );
    });

    test('dependency identity is compared by name, not by id', () {
      final a = base().copyWith(dependsOn: ['model-T1']);
      final b = base().copyWith(dependsOn: ['stable-abc']);
      expect(
        sigOf(a, {'model-T1': '准备环境'}),
        sigOf(b, {'stable-abc': '准备环境'}),
      );
    });

    test('whitespace and case folding do not create false differences', () {
      final noisy = base().copyWith(name: '  整理实验要求  ', steps: ['读说明 ', '整理接口']);
      expect(sigOf(noisy), sigOf(base()));
    });

    test('signature is stable across a whole plan recomputation', () {
      final tasks = [base(), base().copyWith(id: 't2', name: '实现')];
      final first = withComputedSignatures(tasks);
      final second = withComputedSignatures(first);
      expect(first.map((t) => t.executionSignature),
          second.map((t) => t.executionSignature));
      expect(first.first.executionSignature, hasLength(64)); // sha-256 hex
    });
  });
}

