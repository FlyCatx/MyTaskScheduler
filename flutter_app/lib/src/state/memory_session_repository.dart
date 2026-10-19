// In-memory session storage.
//
// Two callers:
//   * widget/unit tests — deterministic, no disk I/O inside Flutter's fake-async zone;
//   * production fallback — if NO directory is writable, the app still runs (sessions
//     just do not survive a restart) instead of refusing to start.

import '../model/session.dart';
import 'session_repository.dart';

class InMemorySessionRepository implements SessionRepository {
  final Map<String, Conversation> conversations = {};
  final Map<String, Attachment> attachments = {};
  final Set<String> tombstones = <String>{};
  final Map<String, Map<String, dynamic>> operations = {};
  List<ConversationSummary> index = [];

  @override
  Future<void> ensureLayout() async {}

  @override
  Future<List<ConversationSummary>> loadIndex() async => List.unmodifiable(index);

  @override
  Future<void> saveIndex(List<ConversationSummary> conversations) async {
    index = List.of(conversations);
  }

  @override
  Future<Conversation?> loadConversation(String id) async => conversations[id];

  @override
  Future<void> saveConversation(Conversation conversation) async {
    conversations[conversation.id] = conversation;
  }

  @override
  Future<void> deleteConversation(String id) async {
    conversations.remove(id);
  }

  @override
  Future<void> saveAttachment(Attachment attachment) async {
    attachments[attachment.id] = attachment;
  }

  @override
  Future<Attachment?> loadAttachment(String id) async => attachments[id];

  @override
  Future<Set<String>> loadTombstones() async => Set.of(tombstones);

  @override
  Future<void> markDeleted(String id) async => tombstones.add(id);

  @override
  Future<void> clearDeleted(String id) async => tombstones.remove(id);

  @override
  Future<void> beginOperation(
      {required String id,
      required String kind,
      required String conversationId}) async {
    operations[id] = <String, dynamic>{
      'id': id,
      'kind': kind,
      'conversationId': conversationId,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  @override
  Future<void> finishOperation(String id) async => operations.remove(id);

  @override
  Future<List<Map<String, dynamic>>> pendingOperations() async =>
      operations.values.map(Map<String, dynamic>.from).toList(growable: false);

  @override
  Future<Set<String>> referencedAttachmentIds() async {
    final ids = <String>{};
    for (final c in conversations.values) {
      for (final a in c.attachments) {
        ids.add(a.id);
      }
    }
    return ids;
  }

  @override
  Future<List<String>> pruneAttachments(Set<String> keep) async {
    final removed = attachments.keys.where((id) => !keep.contains(id)).toList();
    for (final id in removed) {
      attachments.remove(id);
    }
    return removed;
  }
}

