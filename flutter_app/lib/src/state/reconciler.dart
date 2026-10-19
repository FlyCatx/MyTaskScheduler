// Stable task identity + completion inheritance.
//
// The model numbers its tasks T1/T2/... freshly on every response, and the list
// order can change freely. Neither may be used as identity. This module:
//
//   1. proposes a match between each new task and a task of the previous version
//      (model hint `previous_task_id` first, then normalised name similarity);
//   2. resolves matches one-to-one, flagging splits/merges instead of guessing;
//   3. keeps the previous STABLE id for matched tasks, mints a new one otherwise;
//   4. inherits completion only when the execution signature is unchanged.

import '../model/plan.dart';
import 'signature.dart';

class ReconcileResult {
  final List<TaskRecord> tasks;
  final List<ReviewNote> reviewNotes;
  final List<RemovedCompleted> removedCompleted;

  /// previous stable id -> new stable id (for diagnostics / tests).
  final Map<String, String> matchedPairs;

  /// model id (as returned by the model this round) -> local stable id.
  /// Used to translate note task references into stable ids.
  final Map<String, String> modelIdToStableId;

  const ReconcileResult({
    required this.tasks,
    required this.reviewNotes,
    required this.removedCompleted,
    required this.matchedPairs,
    required this.modelIdToStableId,
  });
}

/// Name similarity in [0, 100]. Deliberately conservative: an uncertain match must
/// fall through to "new task" (which never auto-inherits completion) rather than
/// silently reusing a stable id.
double nameSimilarity(String a, String b) {
  final na = normalizeText(a);
  final nb = normalizeText(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 100;
  if (na.contains(nb) || nb.contains(na)) return 80;
  final sa = _bigrams(na);
  final sb = _bigrams(nb);
  if (sa.isEmpty || sb.isEmpty) return 0;
  final inter = sa.intersection(sb).length;
  final union = sa.union(sb).length;
  return union == 0 ? 0 : 100.0 * inter / union;
}

Set<String> _bigrams(String s) {
  final runes = s.runes.toList();
  if (runes.length < 2) return {s};
  final out = <String>{};
  for (var i = 0; i + 1 < runes.length; i++) {
    out.add(String.fromCharCodes(runes.sublist(i, i + 2)));
  }
  return out;
}

const double _kAssignThreshold = 62; // below this we refuse to reuse an id

/// Merge detection thresholds.
///
/// A merge is "one new task that absorbed several old ones". Plain name similarity
/// is not enough (e.g. "实现 ListInit 与 ListInsert" is only 70% similar to
/// "实现 ListInsert" because the shared words are not at the same position), so a
/// distinctive token from the old name must also appear inside the new name.
const double _kMergeSimilarity = 60;
const int _kMergeTokenMinLength = 3;

bool _tokenCoveredBy(String newName, String oldName) {
  final normalized = normalizeText(newName);
  final tokens = normalizeText(oldName)
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((t) => t.length >= _kMergeTokenMinLength);
  return tokens.any(normalized.contains);
}

class _Pair {
  final int newIndex;
  final int oldIndex;
  final double score;
  final bool hint;
  _Pair(this.newIndex, this.oldIndex, this.score, this.hint);
}

/// Reconciles [proposed] (model ids) against [previous] (stable ids).
///
/// [idFactory] mints new stable ids; injectable so tests are deterministic.
ReconcileResult reconcileTasks({
  required List<TaskRecord> previous,
  required List<TaskRecord> proposed,
  required String Function() idFactory,
}) {
  final prevById = {for (final t in previous) t.id: t};
  final previousById = prevById; // alias for readability below
  final notes = <ReviewNote>[];
  final pairs = <_Pair>[];

  // 1) Score every plausible (new, old) pair.
  for (var i = 0; i < proposed.length; i++) {
    final p = proposed[i];
    final hint = p.previousTaskId;
    for (var j = 0; j < previous.length; j++) {
      final old = previous[j];
      final sim = nameSimilarity(p.name, old.name);
      final hinted = hint != null && hint == old.id;
      if (hinted) {
        pairs.add(_Pair(i, j, 1000 + sim, true));
      } else if (sim >= _kAssignThreshold - 10) {
        pairs.add(_Pair(i, j, sim, false));
      }
    }
  }

  // 2) Greedy one-to-one assignment, hints first, then similarity.
  pairs.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byNew = a.newIndex.compareTo(b.newIndex);
    if (byNew != 0) return byNew;
    return a.oldIndex.compareTo(b.oldIndex);
  });

  final newToOld = <int, int>{};
  final oldToNew = <int, int>{};
  for (final pair in pairs) {
    if (newToOld.containsKey(pair.newIndex)) continue;
    if (oldToNew.containsKey(pair.oldIndex)) continue;
    if (!pair.hint && pair.score < _kAssignThreshold) continue;
    newToOld[pair.newIndex] = pair.oldIndex;
    oldToNew[pair.oldIndex] = pair.newIndex;
  }

  // 3) Signatures must come from the proposed content, using proposed names for deps.
  final proposedNames = <String, String>{for (final t in proposed) t.id: t.name};

  final stableIdOfModelId = <String, String>{};
  final resultTasks = <TaskRecord>[];
  final matchedPairs = <String, String>{};

  for (var i = 0; i < proposed.length; i++) {
    final p = proposed[i];
    final oldIndex = newToOld[i];
    final old = oldIndex == null ? null : previous[oldIndex];

    final stableId = old?.id ?? idFactory();
    stableIdOfModelId[p.id] = stableId;
    if (old != null) matchedPairs[old.id] = stableId;

    final signature = computeExecutionSignature(p, proposedNames);
    resultTasks.add(p.copyWith(id: stableId, executionSignature: signature));
  }

  // 4) Rewrite dependencies from model ids to stable ids.
  final rewritten = resultTasks
      .map((t) => t.copyWith(
            dependsOn: t.dependsOn
                .map((dep) => stableIdOfModelId[dep] ?? dep)
                .toList(growable: false),
          ))
      .toList(growable: false);

  // 5) Completion inheritance + review notes.
  final finalTasks = <TaskRecord>[];
  for (var i = 0; i < rewritten.length; i++) {
    final t = rewritten[i];
    final oldIndex = newToOld[i];
    final prev = oldIndex == null ? null : previous[oldIndex];

    // Merge detection: one new task that absorbed several old tasks.
    final resembling = previous
        .where((o) =>
            nameSimilarity(t.name, o.name) >= _kMergeSimilarity &&
            _tokenCoveredBy(t.name, o.name))
        .toList(growable: false);
    final isMerge = prev != null && resembling.length >= 2;

    // Split detection: two or more new tasks claim the same old task by hint and
    // only one could be matched.
    final splitClaim = proposed[i].previousTaskId;
    final isSplit = splitClaim != null &&
        previousById.containsKey(splitClaim) &&
        (prev == null || prev.id != splitClaim);

    var completion = Completion.todo;
    String? completionNote;

    if (prev != null) {
      final unchanged = prev.executionSignature.isNotEmpty &&
          prev.executionSignature == t.executionSignature;
      if (prev.completion == Completion.done) {
        if (unchanged && !isMerge) {
          completion = Completion.done;
        } else {
          completion = Completion.needsReview;
          completionNote = isMerge
              ? '上版多个任务被合并到这里，内容有变化，请确认完成状态'
              : '上版已完成，内容有变化，请确认';
          notes.add(ReviewNote(
            taskId: t.id,
            previousTaskId: prev.id,
            kind: isMerge ? ReviewKind.merge : ReviewKind.changed,
            text: completionNote,
          ));
        }
      } else if (prev.completion == Completion.needsReview) {
        // Never silently clear an unresolved review.
        completion = Completion.needsReview;
        completionNote = prev.completionNote ?? '上版待复核，请确认完成状态';
      }
    } else if (isSplit) {
      completion = Completion.needsReview;
      completionNote = '上版任务被拆分为多个任务，请确认完成状态';
      notes.add(ReviewNote(
        taskId: t.id,
        previousTaskId: splitClaim,
        kind: ReviewKind.split,
        text: completionNote,
      ));
    }

    finalTasks.add(t.copyWith(
      completion: completion,
      completionNote: completionNote,
      clearCompletionNote: completionNote == null,
    ));
  }

  // 6) Completed tasks that disappeared must stay visible in the change summary.
  final removedCompleted = <RemovedCompleted>[];
  for (final old in previous) {
    if (old.completion != Completion.done) continue;
    if (matchedPairs.containsKey(old.id)) continue;
    removedCompleted.add(RemovedCompleted(id: old.id, name: old.name));
  }

  return ReconcileResult(
    tasks: finalTasks,
    reviewNotes: notes,
    removedCompleted: removedCompleted,
    matchedPairs: matchedPairs,
    modelIdToStableId: stableIdOfModelId,
  );
}

