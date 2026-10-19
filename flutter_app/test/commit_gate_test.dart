// Unit tests for the commit gate — the rules that keep a late / cancelled / stale
// result from replacing a newer, visible plan.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/commit_gate.dart';

CommitContext ctx({
  String? currentVersionId = 'v1',
  int currentRevision = 0,
  Set<String> existing = const {'v1'},
}) =>
    CommitContext(
      conversationId: 'c1',
      currentVersionId: currentVersionId,
      currentRevision: currentRevision,
      existingVersionIds: existing,
    );

void main() {
  group('commit gate', () {
    test('first plan commits', () {
      final gate = ConversationCommitGate();
      final ticket = gate.begin(
        conversationId: 'c1',
        requestId: 'r1',
        baseVersionId: null,
        baseRevision: 0,
      );
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(currentVersionId: null, existing: const {}),
          resultConversationId: 'c1',
          resultRequestId: 'r1',
          resultParentVersionId: null,
          resultVersionId: 'v-new',
        ),
        isTrue,
      );
      gate.finish(ticket);
    });

    test('a cancelled request can never commit', () {
      final gate = ConversationCommitGate();
      final ticket = gate.begin(
        conversationId: 'c1',
        requestId: 'r2',
        baseVersionId: 'v1',
        baseRevision: 0,
      );
      gate.cancel(ticket);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(),
          resultConversationId: 'c1',
          resultRequestId: 'r2',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('a result for another conversation is rejected', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r3', baseVersionId: 'v1', baseRevision: 0);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(),
          resultConversationId: 'c2',
          resultRequestId: 'r3',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('a mismatched request id (late response) is rejected', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r4', baseVersionId: 'v1', baseRevision: 0);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(),
          resultConversationId: 'c1',
          resultRequestId: 'r-old',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('a stale base revision is rejected (plan was edited meanwhile)', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r5', baseVersionId: 'v1', baseRevision: 0);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(currentRevision: 3),
          resultConversationId: 'c1',
          resultRequestId: 'r5',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('a stale base version is rejected', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r6', baseVersionId: 'v1', baseRevision: 0);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(currentVersionId: 'v9'),
          resultConversationId: 'c1',
          resultRequestId: 'r6',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('a duplicate version id is rejected', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r7', baseVersionId: 'v1', baseRevision: 0);
      expect(
        canCommit(
          active: gate.activeFor('c1'),
          context: ctx(existing: const {'v1', 'v2'}),
          resultConversationId: 'c1',
          resultRequestId: 'r7',
          resultParentVersionId: 'v1',
          resultVersionId: 'v2',
        ),
        isFalse,
      );
    });

    test('only one active request per conversation', () {
      final gate = ConversationCommitGate();
      gate.begin(
          conversationId: 'c1', requestId: 'r8', baseVersionId: null, baseRevision: 0);
      expect(
        () => gate.begin(
            conversationId: 'c1', requestId: 'r9', baseVersionId: null, baseRevision: 0),
        throwsStateError,
      );
    });

    test('a cancelled ticket stays active until the terminal event', () {
      final gate = ConversationCommitGate();
      final ticket = gate.begin(
          conversationId: 'c1', requestId: 'r10', baseVersionId: null, baseRevision: 0);
      gate.cancel(ticket);
      expect(gate.isCurrent(ticket), isTrue);
      expect(
        () => gate.begin(
            conversationId: 'c1', requestId: 'r11', baseVersionId: null, baseRevision: 0),
        throwsStateError,
      );
      gate.finish(ticket);
      expect(gate.activeFor('c1'), isNull);
    });
  });
}

