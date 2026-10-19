// Local session/version storage.
//
// Layout (under the app data root):
//   index.json                      — sidebar rows (id/title/updatedAt/versionCount)
//   conversations/<id>.json         — full conversation (versions are immutable)
//   attachments/<id>.json           — extracted attachment text + source mapping
//
// Writes are crash-tolerant: the new payload goes to `<file>.tmp`, the previous
// file is renamed to `<file>.bak`, then the tmp file is promoted. On load, a missing
// main file falls back to `.bak`, and leftover `.tmp` files are ignored.

import 'dart:convert';
import 'dart:io';

import '../model/session.dart';
import 'session_repository.dart';

/// Raised when a file was written by a newer schema. The caller must show an
/// explanation and must not overwrite it with this build's data.
class SessionFormatException implements Exception {
  final String path;
  final int found;
  final int supported;
  const SessionFormatException(this.path, this.found, this.supported);

  @override
  String toString() =>
      '会话文件来自更新版本（schema $found > $supported）：$path；为避免覆盖，本次未修改该文件';
}

class SessionStore implements SessionRepository {
  final Directory root;

  SessionStore(this.root);

  static const int indexSchemaVersion = 2;
  static const int conversationSchemaVersion = 2;

  static Directory defaultRoot() {
    final override = Platform.environment['TASKSCHEDULER_DATA_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return Directory(override.trim());
    }
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.trim().isNotEmpty) {
      return Directory('${local.trim()}${Platform.pathSeparator}TaskSchedulerFlutter');
    }
    return Directory(
        '${Directory.current.path}${Platform.pathSeparator}TaskSchedulerData');
  }

  Directory get _conversationsDir =>
      Directory('${root.path}${Platform.pathSeparator}conversations');

  Directory get _attachmentsDir =>
      Directory('${root.path}${Platform.pathSeparator}attachments');

  File get _indexFile => File('${root.path}${Platform.pathSeparator}index.json');
  File get _tombstonesFile =>
      File('${root.path}${Platform.pathSeparator}tombstones.json');
  File get _operationsFile =>
      File('${root.path}${Platform.pathSeparator}operations.json');

  @override
  Future<void> ensureLayout() async {
    await root.create(recursive: true);
    await _conversationsDir.create(recursive: true);
    await _attachmentsDir.create(recursive: true);
  }

  // ---------------------------------------------------------------- index

  @override
  Future<List<ConversationSummary>> loadIndex() async {
    final raw = await _readJson(_indexFile);
    if (raw == null) return const [];
    _requireSchema(raw, _indexFile.path, indexSchemaVersion);
    final list = (raw['conversations'] as List<dynamic>?) ?? const [];
    final tombstones = await loadTombstones();
    final out = list
        .whereType<Map<String, dynamic>>()
        .map(ConversationSummary.fromJson)
        .where((s) => !tombstones.contains(s.id))
        .toList();
    out.sort(_compareSummaries);
    return out;
  }

  /// Stable ordering: pinned first (explicit order), then newest effective activity,
  /// then id. Ties must not swap between restarts.
  static int _compareSummaries(ConversationSummary a, ConversationSummary b) {
    final ap = a.isPinned;
    final bp = b.isPinned;
    if (ap != bp) return ap ? -1 : 1;
    if (ap && bp) {
      final o = (a.meta.pinOrder ?? 0).compareTo(b.meta.pinOrder ?? 0);
      if (o != 0) return o;
    }
    final byActivity = b.activityAt.compareTo(a.activityAt);
    if (byActivity != 0) return byActivity;
    return a.id.compareTo(b.id);
  }

  @override
  Future<void> saveIndex(List<ConversationSummary> conversations) async {
    await ensureLayout();
    await _writeJson(_indexFile, <String, dynamic>{
      'schemaVersion': indexSchemaVersion,
      'conversations':
          conversations.map((c) => c.toJson()).toList(growable: false),
    });
  }

  // -------------------------------------------------------- conversations

  File _conversationFile(String id) =>
      File('${_conversationsDir.path}${Platform.pathSeparator}$id.json');

  @override
  Future<Conversation?> loadConversation(String id) async {
    final f = _conversationFile(id);
    final raw = await _readJson(f);
    if (raw == null) return null;
    _requireSchema(raw, f.path, conversationSchemaVersion);
    return Conversation.fromJson(raw);
  }

  @override
  Future<void> saveConversation(Conversation c) async {
    await ensureLayout();
    await _writeJson(_conversationFile(c.id), c.toJson());
  }

  @override
  Future<void> deleteConversation(String id) async {
    final f = _conversationFile(id);
    for (final candidate in <File>[
      f,
      File('${f.path}.bak'),
      File('${f.path}.tmp'),
    ]) {
      try {
        if (await candidate.exists()) await candidate.delete();
      } catch (_) {
        // A locked leftover must not abort the rest of the cleanup; the tombstone and
        // index removal already prevent it from being shown.
      }
    }
  }

  // ---------------------------------------------------------- attachments

  @override
  Future<void> saveAttachment(Attachment a) async {
    await ensureLayout();
    await _writeJson(
      File('${_attachmentsDir.path}${Platform.pathSeparator}${a.id}.json'),
      a.toJson(),
    );
  }

  @override
  Future<Attachment?> loadAttachment(String id) async {
    final raw = await _readJson(
        File('${_attachmentsDir.path}${Platform.pathSeparator}$id.json'));
    if (raw == null) return null;
    return Attachment.fromJson(raw);
  }

  @override
  Future<Set<String>> loadTombstones() async {
    final raw = await _readJson(_tombstonesFile);
    if (raw == null) return <String>{};
    final map = raw['deleted'];
    if (map is! Map<String, dynamic>) return <String>{};
    return map.keys.where((id) => id.trim().isNotEmpty).toSet();
  }

  @override
  Future<void> markDeleted(String id) async {
    await ensureLayout();
    final map = (await _readJson(_tombstonesFile))?['deleted'];
    final deleted = <String, dynamic>{
      if (map is Map<String, dynamic>) ...map,
      id: DateTime.now().toUtc().toIso8601String(),
    };
    await _writeJson(_tombstonesFile, <String, dynamic>{
      'schemaVersion': 1,
      'deleted': deleted,
    });
  }

  @override
  Future<void> clearDeleted(String id) async {
    final map = (await _readJson(_tombstonesFile))?['deleted'];
    if (map is! Map<String, dynamic> || !map.containsKey(id)) return;
    final deleted = Map<String, dynamic>.from(map)..remove(id);
    await _writeJson(_tombstonesFile, <String, dynamic>{
      'schemaVersion': 1,
      'deleted': deleted,
    });
  }

  @override
  Future<void> beginOperation({
    required String id,
    required String kind,
    required String conversationId,
  }) async {
    await ensureLayout();
    final raw = await _readJson(_operationsFile);
    final existing = raw?['operations'];
    final ops = <String, dynamic>{
      if (existing is List<dynamic>)
        for (final o in existing.whereType<Map<String, dynamic>>())
          if ((o['id'] as String?)?.isNotEmpty ?? false) o['id'] as String: o,
      id: <String, dynamic>{
        'id': id,
        'kind': kind,
        'conversationId': conversationId,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
      },
    };
    await _writeJson(_operationsFile, <String, dynamic>{
      'schemaVersion': 1,
      'operations': ops.values.toList(growable: false),
    });
  }

  @override
  Future<void> finishOperation(String id) async {
    final raw = await _readJson(_operationsFile);
    final existing = raw?['operations'];
    if (existing is! List<dynamic>) return;
    final ops = existing
        .whereType<Map<String, dynamic>>()
        .where((o) => o['id'] != id)
        .toList(growable: false);
    await _writeJson(_operationsFile, <String, dynamic>{
      'schemaVersion': 1,
      'operations': ops,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> pendingOperations() async {
    final raw = await _readJson(_operationsFile);
    final existing = raw?['operations'];
    if (existing is! List<dynamic>) return const [];
    return existing
        .whereType<Map<String, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList(growable: false);
  }

  @override
  Future<Set<String>> referencedAttachmentIds() async {
    final keep = <String>{};
    if (!await _conversationsDir.exists()) return keep;
    await for (final entity in _conversationsDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final raw = await _readJson(entity);
      if (raw == null) continue;
      final attachments = (raw['attachments'] as List<dynamic>?) ?? const [];
      for (final a in attachments.whereType<Map<String, dynamic>>()) {
        final id = (a['id'] as String?)?.trim() ?? '';
        if (id.isNotEmpty) keep.add(id);
      }
    }
    return keep;
  }

  @override
  Future<List<String>> pruneAttachments(Set<String> keep) async {
    if (!await _attachmentsDir.exists()) return const [];
    final removed = <String>[];
    await for (final entity in _attachmentsDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      final id = name.substring(0, name.length - '.json'.length);
      if (keep.contains(id)) continue;
      try {
        await entity.delete();
        removed.add(id);
        final bak = File('${entity.path}.bak');
        if (await bak.exists()) await bak.delete();
      } catch (_) {
        // Keep the file on failure; it is harmless and never shown without a ref.
      }
    }
    return removed;
  }

  // ------------------------------------------------------------ internals

  static void _requireSchema(
      Map<String, dynamic> raw, String path, int supported) {
    final found = (raw['schemaVersion'] as num?)?.toInt();
    if (found != null && found > supported) {
      throw SessionFormatException(path, found, supported);
    }
  }

  Future<Map<String, dynamic>?> _readJson(File file) async {
    for (final candidate in <File>[
      file,
      File('${file.path}.bak'),
    ]) {
      try {
        if (!await candidate.exists()) continue;
        final text = await candidate.readAsString();
        if (text.trim().isEmpty) continue;
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Corrupted file: try the backup, then give up quietly. Losing one
        // sidebar row must not prevent the app from starting.
      }
    }
    return null;
  }

  Future<void> _writeJson(File file, Map<String, dynamic> data) async {
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    final payload = const JsonEncoder.withIndent('  ').convert(data);
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await file.exists()) {
        if (await bak.exists()) await bak.delete();
        await file.rename(bak.path);
      }
      await tmp.rename(file.path);
      /*
       * Keep the .bak on purpose: it is the only recovery path if the main file is
       * later truncated by a crash mid-write. It always holds the previous good copy.
       */
    } catch (_) {
      // Fall back to a direct write if rename is blocked (e.g. file locked).
      await file.writeAsString(payload, flush: true);
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }
}

