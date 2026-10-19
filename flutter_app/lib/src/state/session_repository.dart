// 会话/版本/附件的存储接口；生产实现是 session_store.dart 的原子 JSON 文件存储，
// 测试注入内存实现，避免依赖真实文件 I/O。
//
// 主要类型：SessionRepository。

import '../model/session.dart';

abstract class SessionRepository {
  Future<void> ensureLayout();

  Future<List<ConversationSummary>> loadIndex();
  Future<void> saveIndex(List<ConversationSummary> conversations);

  Future<Conversation?> loadConversation(String id);
  Future<void> saveConversation(Conversation conversation);

  /// Removes the conversation payload (main, `.bak`, `.tmp`).
  Future<void> deleteConversation(String id);

  Future<void> saveAttachment(Attachment attachment);
  Future<Attachment?> loadAttachment(String id);

  // ---- 0.05 lifecycle persistence -----------------------------------------
  /// Ids whose deletion must survive .bak fallback and index rebuilds.
  Future<Set<String>> loadTombstones();
  Future<void> markDeleted(String id);
  Future<void> clearDeleted(String id);

  /// Intent log. `beginOperation` must be durable before the mutation starts;
  /// `finishOperation` removes it only after every file/index step succeeded.
  Future<void> beginOperation(
      {required String id, required String kind, required String conversationId});
  Future<void> finishOperation(String id);
  Future<List<Map<String, dynamic>>> pendingOperations();

  /// Attachment ids referenced by any kept, archived or trashed conversation.
  Future<Set<String>> referencedAttachmentIds();

  /// Deletes attachment files whose ids are not in [keep]; returns deleted ids.
  Future<List<String>> pruneAttachments(Set<String> keep);
}

