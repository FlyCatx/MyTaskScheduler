// Execution signature — locally computed, never model-provided.
//
// Purpose: decide whether a task that was marked "done" in the previous version is
// still THE SAME WORK. Two rules drive the design:
//
//   * Priority, display title wording, order/position, scores and even the time
//     estimate must NOT invalidate completion. Estimating 2h instead of 3h is not a
//     content change, so `estimatedHours`, `urgency`, `impact` and `deadline` are
//     deliberately excluded.
//   * Goal, steps, dependency identity and external conditions DO matter.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/plan.dart';

const String kSignatureAlgorithm = 'execution-v1';

/// Normalises text for comparison: trim, collapse whitespace, case-fold.
String normalizeText(String s) =>
    s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Computes the execution signature of one task.
///
/// [dependencyNames] maps a dependency id (as used in this plan) to the
/// dependency's display name, so the signature is independent of which id scheme
/// (model id vs stable id) the plan currently uses.
String computeExecutionSignature(
  TaskRecord task,
  Map<String, String> dependencyNames,
) {
  final steps = task.steps.map(normalizeText).join('|');
  final deps = task.dependsOn
      .map((id) => normalizeText(dependencyNames[id] ?? id))
      .toList()
    ..sort();
  final conditions = task.preconditions
      .map((p) => normalizeText(p.description))
      .toList()
    ..sort();

  final canonical = <String>[
    kSignatureAlgorithm,
    'name:${normalizeText(task.name)}',
    'steps:$steps',
    'deps:${deps.join('|')}',
    'conds:${conditions.join('|')}',
  ].join('\n');

  return sha256.convert(utf8.encode(canonical)).toString();
}

/// Computes signatures for a whole plan. Returns a new list with the signature
/// filled in; ids are whatever the plan currently uses.
List<TaskRecord> withComputedSignatures(List<TaskRecord> tasks) {
  final names = <String, String>{for (final t in tasks) t.id: t.name};
  return tasks
      .map((t) => t.copyWith(
            executionSignature: computeExecutionSignature(t, names),
          ))
      .toList(growable: false);
}

