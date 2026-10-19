// Commit gate — the only place that decides whether a model result may replace
// the visible plan.
//
// The rules exist because a late or out-of-band response must never overwrite a
// newer plan, and because a failed/cancelled run must leave the old plan and the
// old title untouched:
//
//   * at most one active request per conversation;
//   * the result must carry the exact requestId / conversationId the app started;
//   * the result's base version + revision must still be the current ones
//     (i.e. nobody edited the plan while the request was in flight);
//   * a cancelled request can never commit, even if a full result arrived;
//   * a version id can only be committed once.

class RequestTicket {
  final String conversationId;
  final String requestId;
  final String? baseVersionId;
  final int baseRevision;
  bool cancelled = false;

  RequestTicket({
    required this.conversationId,
    required this.requestId,
    required this.baseVersionId,
    required this.baseRevision,
  });
}

class CommitRejection {
  final String reason;
  const CommitRejection(this.reason);
  @override
  String toString() => 'CommitRejection($reason)';
}

/// Immutable description of the conversation state a commit would apply to.
class CommitContext {
  final String conversationId;
  final String? currentVersionId;
  final int currentRevision;
  final Set<String> existingVersionIds;

  const CommitContext({
    required this.conversationId,
    required this.currentVersionId,
    required this.currentRevision,
    required this.existingVersionIds,
  });
}

/// Pure decision function, so the rules can be unit-tested without any I/O.
bool canCommit({
  required RequestTicket? active,
  required CommitContext context,
  required String resultConversationId,
  required String resultRequestId,
  required String? resultParentVersionId,
  required String resultVersionId,
}) {
  if (active == null) return false;
  if (active.cancelled) return false;
  if (resultConversationId != context.conversationId) return false;
  if (resultConversationId != active.conversationId) return false;
  if (resultRequestId != active.requestId) return false;
  if (resultParentVersionId != active.baseVersionId) return false;
  if (context.currentVersionId != active.baseVersionId) return false;
  if (context.currentRevision != active.baseRevision) return false;
  if (context.existingVersionIds.contains(resultVersionId)) return false;
  return true;
}

/// Per-conversation gate. Keeps the active ticket so the controller can ask
/// "is this still the request I started?".
class ConversationCommitGate {
  final Map<String, RequestTicket> _active = {};

  RequestTicket? activeFor(String conversationId) => _active[conversationId];

  bool get hasAnyActive => _active.isNotEmpty;

  RequestTicket begin({
    required String conversationId,
    required String requestId,
    required String? baseVersionId,
    required int baseRevision,
  }) {
    if (_active.containsKey(conversationId)) {
      throw StateError('该会话已有进行中的分析，请先等待或取消');
    }
    final ticket = RequestTicket(
      conversationId: conversationId,
      requestId: requestId,
      baseVersionId: baseVersionId,
      baseRevision: baseRevision,
    );
    _active[conversationId] = ticket;
    return ticket;
  }

  /// Marks a ticket cancelled. It stays "active" until the native job reports a
  /// terminal event, so the UI cannot start a second request prematurely.
  void cancel(RequestTicket ticket) {
    final current = _active[ticket.conversationId];
    if (identical(current, ticket)) ticket.cancelled = true;
  }

  bool isCurrent(RequestTicket ticket) =>
      identical(_active[ticket.conversationId], ticket);

  /// Clears the active ticket after a terminal event, regardless of outcome.
  void finish(RequestTicket ticket) {
    if (identical(_active[ticket.conversationId], ticket)) {
      _active.remove(ticket.conversationId);
    }
  }
}

