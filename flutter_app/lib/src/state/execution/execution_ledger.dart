// 执行记录账本：记录集合、查询、重叠检测与恢复去重。
//
// 不变量：
//   * 账本内 recordId 全局唯一。`addRecord` 遇到重复会拒绝，恢复备份走
//     [ExecutionLedger.mergeFrom]（按 recordId / eventId 跳过重复），所以同一份
//     备份恢复两次不会重复累计任何工时。
//   * 软删除的记录（`deletedAtUtc != null`）保留在账本里用于追溯，但默认不参与
//     统计与重叠检测；任务被删除不会删除它，只是归属不到当前任务（报告列为“未归属”）。
//   * 只有“已确认事实”参与重叠检测：计时区间、已解析的校正区间、手工补记。
//     未处理的待校正区间不参与（因为它还没被确认为工作）。
//   * 本类是可变的进程内对象；持久化由 ExecutionStore 负责原子写。

import 'execution_models.dart';

/// 重叠来源。
enum OverlapSource {
  timer,
  manual,
}

/// 一次与已有记录重叠的命中（用于“提示区间且不默认重复计入”）。
class OverlapHit {
  const OverlapHit({
    required this.recordId,
    required this.taskId,
    required this.taskName,
    required this.source,
    required this.span,
  });

  final String recordId;
  final String taskId;
  final String taskName;
  final OverlapSource source;

  /// 与待补记区间相交的实际重叠段。
  final TimeSpan span;

  Duration get overlapDuration => span.duration;

  String get sourceLabel =>
      source == OverlapSource.timer ? '计时记录' : '手工补记';

  @override
  String toString() =>
      '$sourceLabel ${span.startUtc.toLocal()} - ${span.endUtc.toLocal()}';
}

/// 恢复备份的合并结果。
class MergeResult {
  const MergeResult({
    this.addedRecords = 0,
    this.addedCompletionEvents = 0,
    this.skippedRecords = 0,
    this.skippedCompletionEvents = 0,
  });

  final int addedRecords;
  final int addedCompletionEvents;
  final int skippedRecords;
  final int skippedCompletionEvents;

  bool get changed => addedRecords > 0 || addedCompletionEvents > 0;

  String get describe {
    if (!changed) {
      return '没有新增执行记录（${skippedRecords + skippedCompletionEvents} 条已存在或重复，已按 recordId 跳过）';
    }
    return '已恢复 $addedRecords 条执行记录、$addedCompletionEvents 个完成事件；'
        '跳过 ${skippedRecords + skippedCompletionEvents} 条重复记录';
  }
}

class ExecutionLedger {
  ExecutionLedger({
    Iterable<ExecutionRecord> records = const <ExecutionRecord>[],
    Iterable<CompletionEvent> completionEvents = const <CompletionEvent>[],
    this.revision = 0,
    this.updatedAtUtc,
  }) {
    for (final record in records) {
      // 读回时也按 recordId 去重：旧文件里可能有历史重复，保留第一条（不猜哪条更新）。
      _records.putIfAbsent(record.recordId, () => record);
    }
    final seenEvents = <String>{};
    for (final event in completionEvents) {
      if (seenEvents.add(event.eventId)) _completionEvents.add(event);
    }
  }

  /// 与 [kExecutionLedgerSchemaVersion] 对应；由 ExecutionStore 写入。
  static const int schemaVersion = kExecutionLedgerSchemaVersion;

  final Map<String, ExecutionRecord> _records = <String, ExecutionRecord>{};
  final List<CompletionEvent> _completionEvents = <CompletionEvent>[];

  /// 账本修订号：每次事实变更 +1，便于“是否需要重新读取/导出”的判断。
  int revision;

  DateTime? updatedAtUtc;

  List<ExecutionRecord> get records =>
      List<ExecutionRecord>.unmodifiable(_records.values);

  List<CompletionEvent> get completionEvents =>
      List<CompletionEvent>.unmodifiable(_completionEvents);

  int get length => _records.length;

  bool get isEmpty => _records.isEmpty && _completionEvents.isEmpty;

  /// 未软删除的记录（统计默认口径）。
  List<ExecutionRecord> get activeRecords => _records.values
      .where((r) => !r.isDeleted)
      .toList(growable: false);

  List<ExecutionRecord> get deletedRecords => _records.values
      .where((r) => r.isDeleted)
      .toList(growable: false);

  ExecutionRecord? recordById(String recordId) => _records[recordId];

  List<ExecutionRecord> recordsForTask(String taskId, {bool includeDeleted = false}) {
    if (taskId.trim().isEmpty) return const <ExecutionRecord>[];
    final out = _records.values
        .where((r) => r.taskId == taskId && (includeDeleted || !r.isDeleted))
        .toList(growable: false);
    out.sort(_compareByCreatedAt);
    return out;
  }

  List<ExecutionRecord> recordsForConversation(
    String conversationId, {
    bool includeDeleted = false,
  }) {
    final out = _records.values
        .where((r) =>
            r.conversationId == conversationId && (includeDeleted || !r.isDeleted))
        .toList(growable: false);
    out.sort(_compareByCreatedAt);
    return out;
  }

  /// 任务谱系（拆分/合并）下的全部记录：同一 [ExecutionRecord.lineageRootId]。
  List<ExecutionRecord> recordsForLineage(
    String lineageRootId, {
    bool includeDeleted = false,
  }) {
    final out = _records.values
        .where((r) =>
            r.lineageRootId == lineageRootId &&
            (includeDeleted || !r.isDeleted))
        .toList(growable: false);
    out.sort(_compareByCreatedAt);
    return out;
  }

  /// 全部未处理的待校正区间（跨记录）。
  List<({ExecutionRecord record, PendingCorrection correction})>
      get openCorrections {
    final out = <({ExecutionRecord record, PendingCorrection correction})>[];
    for (final record in activeRecords) {
      for (final correction in record.pendingCorrections) {
        if (correction.isOpen) {
          out.add((record: record, correction: correction));
        }
      }
    }
    return out;
  }

  /// 新增记录；recordId 已存在时返回 false（调用方必须处理，不能静默覆盖）。
  bool addRecord(ExecutionRecord record) {
    if (_records.containsKey(record.recordId)) return false;
    _records[record.recordId] = record;
    _touch();
    return true;
  }

  /// 替换已有记录；不存在时返回 false。
  bool replaceRecord(ExecutionRecord record) {
    if (!_records.containsKey(record.recordId)) return false;
    _records[record.recordId] = record;
    _touch();
    return true;
  }

  /// 彻底移除一条记录（仅用于“新建记录后保存失败”的回滚；正常删除走软删除）。
  bool removeRecord(String recordId) {
    final removed = _records.remove(recordId);
    if (removed == null) return false;
    _touch();
    return true;
  }

  /// 恢复备份的幂等合并：已存在的 recordId / eventId 一律跳过，绝不覆盖本地事实。
  MergeResult mergeFrom(ExecutionLedger imported) {
    var addedRecords = 0;
    var skippedRecords = 0;
    for (final record in imported.records) {
      if (_records.containsKey(record.recordId)) {
        skippedRecords++;
      } else {
        _records[record.recordId] = record;
        addedRecords++;
      }
    }
    var addedEvents = 0;
    var skippedEvents = 0;
    final existing = _completionEvents.map((e) => e.eventId).toSet();
    for (final event in imported.completionEvents) {
      if (existing.contains(event.eventId)) {
        skippedEvents++;
      } else {
        _completionEvents.add(event);
        existing.add(event.eventId);
        addedEvents++;
      }
    }
    if (addedRecords > 0 || addedEvents > 0) _touch();
    return MergeResult(
      addedRecords: addedRecords,
      addedCompletionEvents: addedEvents,
      skippedRecords: skippedRecords,
      skippedCompletionEvents: skippedEvents,
    );
  }

  /// 查找与 [startUtc, endUtc) 重叠的已确认事实。
  ///
  /// 默认排除软删除记录与未处理的待校正区间。用于手工补记前的提示：
  /// 有重叠时 UI 必须列出区间，并默认不计入重叠部分。
  List<OverlapHit> findOverlaps({
    required DateTime startUtc,
    required DateTime endUtc,
    String? ignoreRecordId,
    String? ignoreEntryId,
  }) {
    final target = TimeSpan(startUtc: startUtc.toUtc(), endUtc: endUtc.toUtc());
    if (!target.isValid) return const <OverlapHit>[];
    final hits = <OverlapHit>[];
    for (final record in activeRecords) {
      if (record.recordId == ignoreRecordId) continue;
      for (final interval in record.intervals) {
        final span = _intersect(target, interval.startUtc, interval.endUtc);
        if (span != null) {
          hits.add(OverlapHit(
            recordId: record.recordId,
            taskId: record.taskId,
            taskName: record.taskName,
            source: OverlapSource.timer,
            span: span,
          ));
        }
      }
      for (final entry in record.manualEntries) {
        if (ignoreEntryId != null && entry.entryId == ignoreEntryId) continue;
        final start = entry.startUtc;
        final end = entry.endUtc;
        if (start == null || end == null) continue;
        final span = _intersect(target, start, end);
        if (span != null) {
          hits.add(OverlapHit(
            recordId: record.recordId,
            taskId: record.taskId,
            taskName: record.taskName,
            source: OverlapSource.manual,
            span: span,
          ));
        }
      }
    }
    hits.sort((a, b) => a.span.startUtc.compareTo(b.span.startUtc));
    return hits;
  }

  /// 记录一次任务完成事件；同一任务已有未撤销事件时不重复记录。
  CompletionEvent? recordCompletion({
    required String conversationId,
    required String taskId,
    required String planVersionId,
    required int planRevision,
    required DateTime completedAtUtc,
  }) {
    if (taskId.trim().isEmpty) return null;
    final active = activeCompletionFor(taskId);
    if (active != null) return active;
    final event = CompletionEvent(
      eventId: newExecutionId('cev'),
      conversationId: conversationId,
      taskId: taskId,
      planVersionId: planVersionId,
      planRevision: planRevision,
      completedAtUtc: completedAtUtc.toUtc(),
    );
    _completionEvents.add(event);
    _touch();
    return event;
  }

  /// 撤销完成：把该任务最新一条未撤销事件标记为已撤销（不删除执行记录）。
  bool undoCompletion(String taskId, DateTime atUtc) {
    for (var i = _completionEvents.length - 1; i >= 0; i--) {
      final event = _completionEvents[i];
      if (event.taskId == taskId && event.isActive) {
        _completionEvents[i] = event.undo(atUtc.toUtc());
        _touch();
        return true;
      }
    }
    return false;
  }

  CompletionEvent? activeCompletionFor(String taskId) {
    for (var i = _completionEvents.length - 1; i >= 0; i--) {
      final event = _completionEvents[i];
      if (event.taskId == taskId && event.isActive) return event;
    }
    return null;
  }

  /// 范围内“完成事件”的数量（完成时间取事件时间，不取当前读取时间）。
  int completedCount({DateTime? fromUtc, DateTime? toUtc}) {
    var count = 0;
    for (final event in _completionEvents) {
      if (!event.isActive) continue;
      final at = event.completedAtUtc;
      if (fromUtc != null && at.isBefore(fromUtc)) continue;
      if (toUtc != null && !at.isBefore(toUtc)) continue;
      count++;
    }
    return count;
  }

  /// 删除/恢复记录（软删除 + 修订快照），返回记录是否发生变化。
  ExecutionRecord? setRecordDeleted(
    String recordId, {
    required bool deleted,
    required DateTime atUtc,
    required String reason,
    String? note,
  }) {
    final record = _records[recordId];
    if (record == null || record.isDeleted == deleted) return null;
    final before = record.withRevision(ExecutionRevision(
      revisionId: newExecutionId('rev'),
      atUtc: atUtc.toUtc(),
      action: deleted ? 'delete' : 'restore',
      note: note,
      snapshot: record.toJson(),
    ));
    final next = deleted
        ? before.copyWith(deletedAtUtc: atUtc.toUtc(), deletedReason: reason)
        : before.copyWith(clearDeleted: true);
    _records[recordId] = next;
    _touch();
    return next;
  }

  /// 撤销最近一次带快照的修订，返回恢复后的记录。
  ExecutionRecord? revertRecord(String recordId, {required DateTime atUtc}) {
    final record = _records[recordId];
    if (record == null) return null;
    final revision = record.lastRevertibleRevision;
    final snapshot = revision?.snapshot;
    if (snapshot == null) return null;
    final restored = ExecutionRecord.fromJson(snapshot);
    if (restored == null) return null;
    final next = restored.withRevision(ExecutionRevision(
      revisionId: newExecutionId('rev'),
      atUtc: atUtc.toUtc(),
      action: 'revise',
      note: '撤销「${revision!.action}」',
      snapshot: record.toJson(),
    ));
    _records[recordId] = next;
    _touch();
    return next;
  }

  void _touch() {
    revision += 1;
    updatedAtUtc = DateTime.now().toUtc();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'revision': revision,
        'updatedAtUtc': updatedAtUtc?.toUtc().toIso8601String(),
        'records': records.map((r) => r.toJson()).toList(growable: false),
        'completionEvents':
            _completionEvents.map((e) => e.toJson()).toList(growable: false),
      };

  /// 容错解析：坏条目被跳过，不因一条坏记录丢掉整个账本。
  static ExecutionLedger fromJson(Map<String, dynamic> raw) {
    final records = <ExecutionRecord>[];
    final rawRecords = raw['records'];
    if (rawRecords is List) {
      for (final item in rawRecords) {
        final record = ExecutionRecord.fromJson(item);
        if (record != null) records.add(record);
      }
    }
    final events = <CompletionEvent>[];
    final rawEvents = raw['completionEvents'];
    if (rawEvents is List) {
      for (final item in rawEvents) {
        final event = CompletionEvent.fromJson(item);
        if (event != null) events.add(event);
      }
    }
    return ExecutionLedger(
      records: records,
      completionEvents: events,
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      updatedAtUtc: parseUtc(raw['updatedAtUtc']),
    );
  }

  static int _compareByCreatedAt(ExecutionRecord a, ExecutionRecord b) {
    final byTime = a.createdAtUtc.compareTo(b.createdAtUtc);
    if (byTime != 0) return byTime;
    return a.recordId.compareTo(b.recordId);
  }

  static TimeSpan? _intersect(TimeSpan target, DateTime start, DateTime end) {
    final lo = target.startUtc.isAfter(start) ? target.startUtc : start;
    final hi = target.endUtc.isBefore(end) ? target.endUtc : end;
    if (!hi.isAfter(lo)) return null;
    return TimeSpan(startUtc: lo, endUtc: hi);
  }
}
