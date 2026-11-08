// 全局日程服务：唯一的权威 ScheduleController（task 2）。
//
// 约束：
//   * 所有读-改-写命令在同一 Future 队列里串行执行，读旧快照的两个命令
//     不会互相覆盖；只有保存成功才 notifyListeners 并展示成功；
//   * expectedRevision 防止旧弹窗覆盖新编辑；冲突/失败与“已提交”可区分；
//   * 撤销以整个快照为逆操作，恢复后也推进 revision；任何新编辑清空旧撤销栈，
//     因此旧撤销不会覆盖新状态；日程撤销不进入会话任务撤销栈；
//   * 日程全局共享，关联会话仅是导航/筛选；无会话也可创建；
//   * 第二实例只读、内存模式明确“关闭后丢失”。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../model/calendar.dart' show parseDateKey;
import '../../model/plan.dart' show IdGenerator;
import '../../model/schedule_event.dart';
import 'schedule_expander.dart';
import 'schedule_store.dart';

enum ScheduleMutationStatus { committed, rejected, failed }

/// 命令结果：成功/拒绝/失败可区分，成功才携带 eventId 与 revision。
class ScheduleMutationResult {
  const ScheduleMutationResult({
    required this.status,
    required this.message,
    this.eventId,
    this.revision,
    this.failedOccurrenceKeys = const <String>[],
  });

  final ScheduleMutationStatus status;
  final String message;
  final String? eventId;
  final int? revision;
  final List<String> failedOccurrenceKeys;

  bool get ok => status == ScheduleMutationStatus.committed;

  static ScheduleMutationResult committed(
    String message, {
    String? eventId,
    int? revision,
    List<String> failedOccurrenceKeys = const <String>[],
  }) =>
      ScheduleMutationResult(
        status: ScheduleMutationStatus.committed,
        message: message,
        eventId: eventId,
        revision: revision,
        failedOccurrenceKeys: failedOccurrenceKeys,
      );

  static ScheduleMutationResult rejected(String message) =>
      ScheduleMutationResult(
        status: ScheduleMutationStatus.rejected,
        message: message,
      );

  static ScheduleMutationResult failed(String message) =>
      ScheduleMutationResult(
        status: ScheduleMutationStatus.failed,
        message: message,
      );
}

class _UndoEntry {
  const _UndoEntry({required this.label, required this.before});
  final String label;
  final ScheduleSnapshot before;
}

class ScheduleController extends ChangeNotifier {
  ScheduleController({
    required ScheduleStore store,
    DateTime Function()? clock,
    String Function(String prefix)? idFactory,
  })  : _store = store,
        _clock = clock ?? DateTime.now,
        _idFactory = idFactory ?? IdGenerator.next;

  final ScheduleStore _store;
  final DateTime Function() _clock;
  final String Function(String prefix) _idFactory;

  ScheduleSnapshot _snapshot = ScheduleSnapshot.empty;
  Future<ScheduleOpenResult>? _opening;
  Future<void> _queue = Future<void>.value();
  final List<_UndoEntry> _undoStack = <_UndoEntry>[];
  bool _closed = false;
  int _activeMutations = 0;

  /// 底层 store（备份/迁移等组合根接线需要；写操作仍必须走 controller）。
  ScheduleStore get store => _store;

  bool get readOnly => _store.readOnly;
  String? get notice => _store.notice;
  bool get memoryOnly => _store.isMemoryOnly;
  bool get isOpen => _store.opened;
  int get revision => _snapshot.revision;

  /// 未删除的日程（全局共享）。
  List<ScheduleEvent> get events => _snapshot.activeEvents;

  /// 全部事件（含删除标记，供备份/诊断）。
  List<ScheduleEvent> get allEvents =>
      _snapshot.events.values.toList(growable: false);

  ScheduleEvent? eventById(String id) {
    final event = _snapshot.events[id];
    if (event == null || event.isDeleted) return null;
    return event;
  }

  bool get canUndo => _undoStack.isNotEmpty && !readOnly && !_closed;

  /// 是否有命令正在执行（备份恢复/关闭等待时用于互斥）。
  bool get isMutating => _activeMutations > 0;

  /// 等待已排队的命令全部完成（退出/迁移前调用；不发起新命令）。
  Future<void> drain() => _queue;

  /// 打开存储并加载快照；重复调用返回同一次打开结果。
  Future<ScheduleOpenResult> initialize() => _opening ??= _open();

  Future<ScheduleOpenResult> _open() async {
    final result = await _store.open();
    _snapshot = result.snapshot;
    notifyListeners();
    return result;
  }

  /// 备份恢复后从磁盘重新读取；调用方负责同步刷新日历叠层。
  Future<void> reloadFromDisk() => _serialize<void>(() async {
        await _store.reload();
        _snapshot = _store.snapshot;
        _undoStack.clear();
        notifyListeners();
      });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      _activeMutations++;
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _activeMutations--;
      }
    });
    return completer.future;
  }

  Future<ScheduleMutationResult> createEvent(ScheduleDraft draft) =>
      _serialize<ScheduleMutationResult>(() async {
        if (_closed) return ScheduleMutationResult.rejected('日程服务已关闭');
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        final error = draft.validate();
        if (error != null) return ScheduleMutationResult.rejected(error);
        final now = _clock().toUtc();
        final id = _idFactory('ev');
        final event = draft.toEvent(id: id, revision: 1, nowUtc: now);
        final next = Map<String, ScheduleEvent>.from(_snapshot.events);
        next[id] = event;
        return _commit(
          next,
          message: '已创建日程',
          eventId: id,
          undo: _UndoEntry(label: '创建日程', before: _snapshot),
        );
      });

  Future<ScheduleMutationResult> updateEvent(
    String id,
    int expectedRevision,
    ScheduleDraft draft, {
    bool confirmDropInvalidExceptions = false,
  }) =>
      _serialize<ScheduleMutationResult>(() async {
        if (_closed) return ScheduleMutationResult.rejected('日程服务已关闭');
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        final existing = _snapshot.events[id];
        if (existing == null || existing.isDeleted) {
          return ScheduleMutationResult.rejected('日程不存在或已删除');
        }
        if (existing.revision != expectedRevision) {
          return ScheduleMutationResult.rejected('日程已被其他操作修改，请刷新后重试');
        }
        final error = draft.validate();
        if (error != null) return ScheduleMutationResult.rejected(error);

        final typeChanged = existing.allDay != draft.allDay;
        final invalid = typeChanged
            ? existing.exceptions.map((e) => e.occurrenceKey).toList()
            : existing.exceptionsNoLongerMatching(draft.repeat);
        if (invalid.isNotEmpty && !confirmDropInvalidExceptions) {
          return ScheduleMutationResult.rejected(
            '修改重复规则会影响 ${invalid.length} 条单次例外，请确认后重试',
          );
        }
        final kept = existing.exceptions
            .where((e) => !invalid.contains(e.occurrenceKey))
            .toList(growable: false);
        final updated = existing.appliedDraft(
          draft,
          revision: existing.revision + 1,
          updatedAtUtc: _clock().toUtc(),
          exceptions: kept,
        );
        final next = Map<String, ScheduleEvent>.from(_snapshot.events);
        next[id] = updated;
        return _commit(
          next,
          message: invalid.isEmpty
              ? '已保存日程'
              : '已保存日程，并移除 ${invalid.length} 条失效的单次例外',
          eventId: id,
          undo: _UndoEntry(label: '编辑日程', before: _snapshot),
        );
      });

  Future<ScheduleMutationResult> deleteEvent(
    String id,
    int expectedRevision,
  ) =>
      _serialize<ScheduleMutationResult>(() async {
        if (_closed) return ScheduleMutationResult.rejected('日程服务已关闭');
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        final existing = _snapshot.events[id];
        if (existing == null || existing.isDeleted) {
          return ScheduleMutationResult.rejected('日程不存在或已删除');
        }
        if (existing.revision != expectedRevision) {
          return ScheduleMutationResult.rejected('日程已被其他操作修改，请刷新后重试');
        }
        final now = _clock().toUtc();
        final updated = existing.copyWith(
          revision: existing.revision + 1,
          updatedAtUtc: now,
          deletedAtUtc: now,
        );
        final next = Map<String, ScheduleEvent>.from(_snapshot.events);
        next[id] = updated;
        return _commit(
          next,
          message: '已删除日程',
          eventId: id,
          undo: _UndoEntry(label: '删除日程', before: _snapshot),
        );
      });

  /// 单次例外：排除/恢复某一次发生（按稳定 occurrenceKey，不按列表行号）。
  Future<ScheduleMutationResult> setOccurrenceExcluded(
    String eventId,
    String occurrenceKey, {
    required bool excluded,
  }) =>
      _serialize<ScheduleMutationResult>(() async {
        final existing = _snapshot.events[eventId];
        if (existing == null || existing.isDeleted) {
          return ScheduleMutationResult.rejected('日程不存在或已删除');
        }
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        if (eventIdOfOccurrenceKey(occurrenceKey) != eventId ||
            !isValidOccurrenceKey(occurrenceKey)) {
          return ScheduleMutationResult.rejected('单次例外的身份不合法');
        }
        final exceptions = <ScheduleException>[
          for (final e in existing.exceptions)
            if (e.occurrenceKey != occurrenceKey) e,
          if (excluded) ScheduleException.excluded(occurrenceKey: occurrenceKey),
        ];
        final updated = existing.copyWith(
          revision: existing.revision + 1,
          updatedAtUtc: _clock().toUtc(),
          exceptions: List<ScheduleException>.unmodifiable(exceptions),
        );
        final next = Map<String, ScheduleEvent>.from(_snapshot.events);
        next[eventId] = updated;
        return _commit(
          next,
          message: excluded ? '已删除本次日程' : '已恢复本次日程',
          eventId: eventId,
          undo: _UndoEntry(label: excluded ? '删除本次日程' : '恢复本次日程', before: _snapshot),
        );
      });

  /// 单次例外：把某一次改到另一个日期/时间（key 仍指向原始日期）。
  Future<ScheduleMutationResult> overrideOccurrence(
    String eventId,
    String occurrenceKey, {
    required String startDate,
    int? startMinute,
    int? endMinute,
    String? endDateExclusive,
  }) =>
      _serialize<ScheduleMutationResult>(() async {
        final existing = _snapshot.events[eventId];
        if (existing == null || existing.isDeleted) {
          return ScheduleMutationResult.rejected('日程不存在或已删除');
        }
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        if (eventIdOfOccurrenceKey(occurrenceKey) != eventId ||
            !isValidOccurrenceKey(occurrenceKey)) {
          return ScheduleMutationResult.rejected('单次例外的身份不合法');
        }
        if (parseDateKey(startDate) == null) {
          return ScheduleMutationResult.rejected('单次日程的日期不合法');
        }
        ScheduleException? override;
        if (existing.allDay) {
          final end = endDateExclusive == null ? null : parseDateKey(endDateExclusive);
          if (end == null || end.compareTo(startDate) <= 0) {
            return ScheduleMutationResult.rejected('全天日程的结束日期必须晚于开始日期');
          }
          override = ScheduleException.override(
            occurrenceKey: occurrenceKey,
            startDate: startDate,
            endDateExclusive: end,
          );
        } else {
          final sm = startMinute;
          final em = endMinute;
          if (sm == null || em == null || sm < 0 || sm > 1439 || em <= sm) {
            return ScheduleMutationResult.rejected('单次日程的时间不合法');
          }
          override = ScheduleException.override(
            occurrenceKey: occurrenceKey,
            startDate: startDate,
            startMinute: sm,
            endMinute: em,
          );
        }
        final exceptions = <ScheduleException>[
          for (final e in existing.exceptions)
            if (e.occurrenceKey != occurrenceKey) e,
          override,
        ];
        final updated = existing.copyWith(
          revision: existing.revision + 1,
          updatedAtUtc: _clock().toUtc(),
          exceptions: List<ScheduleException>.unmodifiable(exceptions),
        );
        final next = Map<String, ScheduleEvent>.from(_snapshot.events);
        next[eventId] = updated;
        return _commit(
          next,
          message: '已保存本次修改',
          eventId: eventId,
          undo: _UndoEntry(label: '修改本次日程', before: _snapshot),
        );
      });

  /// 撤销最近一次日程命令（以完整快照为逆操作，恢复后也推进 revision）。
  Future<ScheduleMutationResult> undoLastMutation() =>
      _serialize<ScheduleMutationResult>(() async {
        if (_closed) return ScheduleMutationResult.rejected('日程服务已关闭');
        if (readOnly) {
          return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
        }
        if (_undoStack.isEmpty) {
          return ScheduleMutationResult.rejected('没有可撤销的日程操作');
        }
        final entry = _undoStack.last;
        return _commit(
          entry.before.events,
          message: '已撤销：${entry.label}',
          undo: null,
          clearUndo: true,
        );
      });

  Future<ScheduleMutationResult> _commit(
    Map<String, ScheduleEvent> next, {
    required String message,
    String? eventId,
    _UndoEntry? undo,
    bool clearUndo = false,
  }) async {
    if (readOnly) {
      return ScheduleMutationResult.rejected(notice ?? '日程为只读，未保存改动');
    }
    final revision = _snapshot.revision + 1;
    final snapshot = ScheduleSnapshot(
      revision: revision,
      events: Map<String, ScheduleEvent>.unmodifiable(next),
    );
    try {
      await _store.saveSnapshot(snapshot);
    } catch (error) {
      return ScheduleMutationResult.failed('日程保存失败：$error');
    }
    _snapshot = snapshot;
    _undoStack.clear();
    if (!clearUndo && undo != null) _undoStack.add(undo);
    notifyListeners();
    return ScheduleMutationResult.committed(
      message,
      eventId: eventId,
      revision: revision,
    );
  }

  /// 展开指定范围的实例；调用方必须检查 result.complete。
  ScheduleExpansionResult occurrences(ScheduleQuery query) =>
      expandScheduleEvents(events: events, query: query);

  /// 便捷范围展开（本地时区由调用方给出）。
  ScheduleExpansionResult occurrencesInRange({
    required DateTime fromUtc,
    required DateTime toUtc,
    required String timezoneId,
    int maxOccurrences = kScheduleMaxOccurrences,
  }) =>
      occurrences(ScheduleQuery(
        fromUtc: fromUtc,
        toUtc: toUtc,
        timezoneId: timezoneId,
        maxOccurrences: maxOccurrences,
      ));

  /// 关闭：等待队列中命令完成，再释放实例锁。可重复调用。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _queue;
    await _store.close();
  }
}
