// 账本测试：recordId 去重、恢复备份幂等、重叠检测、软删除/撤销、完成事件。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';

import 'execution_test_support.dart';

ExecutionRecord sampleRecord({
  String recordId = 'rec-1',
  String taskId = 'task-a',
  String conversationId = 'conv-1',
  DateTime? start,
  DateTime? end,
}) {
  final startUtc = start ?? DateTime.utc(2026, 11, 4, 1);
  final endUtc = end ?? startUtc.add(const Duration(hours: 1));
  return recordWithInterval(
    recordId: recordId,
    taskId: taskId,
    conversationId: conversationId,
    startUtc: startUtc,
    endUtc: endUtc,
  );
}

void main() {
  group('记录集合', () {
    test('addRecord 拒绝重复 recordId，不静默覆盖已有事实', () {
      final ledger = ExecutionLedger();
      expect(ledger.addRecord(sampleRecord()), true);
      final duplicate = sampleRecord(end: DateTime.utc(2026, 11, 4, 5));
      expect(ledger.addRecord(duplicate), false);
      expect(ledger.records.length, 1);
      expect(ledger.recordById('rec-1')!.intervals.first.endUtc,
          DateTime.utc(2026, 11, 4, 2));
    });

    test('构造时按 recordId 去重（旧文件历史重复保留第一条）', () {
      final ledger = ExecutionLedger(records: <ExecutionRecord>[
        sampleRecord(),
        sampleRecord(end: DateTime.utc(2026, 11, 4, 3)),
      ]);
      expect(ledger.records.length, 1);
      expect(ledger.recordById('rec-1')!.intervals.first.endUtc,
          DateTime.utc(2026, 11, 4, 2));
    });

    test('按任务/会话/谱系查询，默认排除软删除记录', () {
      final ledger = ExecutionLedger(records: <ExecutionRecord>[
        sampleRecord(recordId: 'r1'),
        sampleRecord(recordId: 'r2', taskId: 'task-b'),
        sampleRecord(
            recordId: 'r3', taskId: 'task-c', conversationId: 'conv-2'),
      ]);
      expect(ledger.recordsForTask('task-a').map((r) => r.recordId), ['r1']);
      expect(ledger.recordsForConversation('conv-1').length, 2);
      expect(
          ledger.recordsForLineage('task-a').map((r) => r.recordId), ['r1']);

      ledger.setRecordDeleted('r1',
          deleted: true,
          atUtc: DateTime.utc(2026, 11, 4, 6),
          reason: '测试删除');
      expect(ledger.recordsForTask('task-a'), isEmpty);
      expect(ledger.recordsForTask('task-a', includeDeleted: true).length, 1);
      expect(ledger.records.length, 3, reason: '软删除保留记录与历史');
    });
  });

  group('恢复备份幂等', () {
    test('重复合并同一份数据不重复累计，本地已有事实不被覆盖', () {
      final local = ExecutionLedger(records: <ExecutionRecord>[
        sampleRecord(end: DateTime.utc(2026, 11, 4, 2)),
      ]);
      final imported = ExecutionLedger(records: <ExecutionRecord>[
        // 同一 recordId 但内容不同：必须保留本地版本。
        sampleRecord(end: DateTime.utc(2026, 11, 4, 9)),
        sampleRecord(recordId: 'rec-2', taskId: 'task-b'),
      ], completionEvents: <CompletionEvent>[
        CompletionEvent(
          eventId: 'ev-1',
          conversationId: 'conv-1',
          taskId: 'task-a',
          planVersionId: 'ver-1',
          planRevision: 1,
          completedAtUtc: DateTime.utc(2026, 11, 5, 1),
        ),
      ]);

      final first = local.mergeFrom(imported);
      expect(first.addedRecords, 1);
      expect(first.addedCompletionEvents, 1);
      expect(first.skippedRecords, 1);
      expect(local.recordById('rec-1')!.intervals.first.endUtc,
          DateTime.utc(2026, 11, 4, 2));

      final second = local.mergeFrom(imported);
      expect(second.changed, false);
      expect(second.addedRecords, 0);
      expect(second.addedCompletionEvents, 0);
      expect(local.records.length, 2);
      expect(local.completionEvents.length, 1);
      expect(second.describe, contains('跳过'));
    });
  });

  group('重叠检测', () {
    test('计时区间与手工补记都参与，未处理校正不参与', () {
      final base = sampleRecord(
        start: DateTime.utc(2026, 11, 4, 1),
        end: DateTime.utc(2026, 11, 4, 2),
      );
      final withManual = base.copyWith(manualEntries: <ManualEntry>[
        ManualEntry(
          entryId: 'm1',
          mode: ManualEntryMode.startEnd,
          startUtc: DateTime.utc(2026, 11, 4, 4),
          endUtc: DateTime.utc(2026, 11, 4, 5),
          durationSeconds: 3600,
          localDate: '2026-11-04',
          createdAtUtc: DateTime.utc(2026, 11, 4, 6),
        ),
      ], pendingCorrections: <PendingCorrection>[
        PendingCorrection(
          correctionId: 'cor',
          observedStartUtc: DateTime.utc(2026, 11, 4, 7),
          observedEndUtc: DateTime.utc(2026, 11, 4, 9),
          wallDeltaSeconds: 7200,
          monotonicDeltaSeconds: 0,
          reason: CorrectionReason.suspend,
          detectedAtUtc: DateTime.utc(2026, 11, 4, 9),
        ),
      ]);
      final ledger = ExecutionLedger(records: <ExecutionRecord>[withManual]);

      final timerHits = ledger.findOverlaps(
        startUtc: DateTime.utc(2026, 11, 4, 1, 30),
        endUtc: DateTime.utc(2026, 11, 4, 2, 30),
      );
      expect(timerHits.length, 1);
      expect(timerHits.first.source, OverlapSource.timer);
      expect(timerHits.first.overlapDuration, const Duration(minutes: 30));

      final manualHits = ledger.findOverlaps(
        startUtc: DateTime.utc(2026, 11, 4, 4, 30),
        endUtc: DateTime.utc(2026, 11, 4, 4, 45),
      );
      expect(manualHits.length, 1);
      expect(manualHits.first.source, OverlapSource.manual);
      expect(manualHits.first.overlapDuration, const Duration(minutes: 15));

      final correctionHits = ledger.findOverlaps(
        startUtc: DateTime.utc(2026, 11, 4, 7, 30),
        endUtc: DateTime.utc(2026, 11, 4, 8),
      );
      expect(correctionHits, isEmpty,
          reason: '未处理的待校正区间还没被确认成工作，不应提示重叠');

      final none = ledger.findOverlaps(
        startUtc: DateTime.utc(2026, 11, 4, 11),
        endUtc: DateTime.utc(2026, 11, 4, 12),
      );
      expect(none, isEmpty);
    });

    test('ignoreRecordId 允许排除指定记录', () {
      final ledger = ExecutionLedger(records: <ExecutionRecord>[
        sampleRecord(),
      ]);
      final hits = ledger.findOverlaps(
        startUtc: DateTime.utc(2026, 11, 4, 1, 30),
        endUtc: DateTime.utc(2026, 11, 4, 2),
        ignoreRecordId: 'rec-1',
      );
      expect(hits, isEmpty);
    });
  });

  group('软删除与撤销', () {
    test('删除记录保留历史，撤销恢复原始事实', () {
      final ledger = ExecutionLedger(records: <ExecutionRecord>[
        sampleRecord(),
      ]);
      final deleted = ledger.setRecordDeleted(
        'rec-1',
        deleted: true,
        atUtc: DateTime.utc(2026, 11, 4, 6),
        reason: '用户删除',
      )!;
      expect(deleted.isDeleted, true);
      expect(deleted.revisionActions, ['delete']);

      final restored = ledger.revertRecord('rec-1',
          atUtc: DateTime.utc(2026, 11, 4, 7))!;
      expect(restored.isDeleted, false);
      expect(restored.intervals.length, 1);
      expect(restored.intervals.first.duration, const Duration(hours: 1));
      // 撤销本身也留下一条带快照的修订，保证可继续追溯。
      expect(restored.revisionActions, contains('revise'));
      expect(restored.revisions.last.note, contains('撤销'));
      expect(restored.revisions.last.snapshot, isNotNull);
    });
  });

  group('完成事件', () {
    test('同一任务不重复记录；撤销后可再次记录', () {
      final ledger = ExecutionLedger();
      final first = ledger.recordCompletion(
        conversationId: 'conv-1',
        taskId: 'task-a',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: DateTime.utc(2026, 11, 4, 1),
      )!;
      final duplicate = ledger.recordCompletion(
        conversationId: 'conv-1',
        taskId: 'task-a',
        planVersionId: 'ver-1',
        planRevision: 2,
        completedAtUtc: DateTime.utc(2026, 11, 4, 2),
      )!;
      expect(duplicate.eventId, first.eventId);
      expect(ledger.completionEvents.length, 1);

      expect(ledger.undoCompletion('task-a', DateTime.utc(2026, 11, 4, 3)), true);
      expect(ledger.activeCompletionFor('task-a'), isNull);
      expect(ledger.completionEvents.length, 1, reason: '撤销不删除事件');

      final second = ledger.recordCompletion(
        conversationId: 'conv-1',
        taskId: 'task-a',
        planVersionId: 'ver-1',
        planRevision: 2,
        completedAtUtc: DateTime.utc(2026, 11, 4, 4),
      )!;
      expect(second.eventId, isNot(first.eventId));
      expect(ledger.activeCompletionFor('task-a')!.completedAtUtc,
          DateTime.utc(2026, 11, 4, 4));
    });

    test('完成数按事件时间过滤范围，未撤销才算', () {
      final ledger = ExecutionLedger(completionEvents: <CompletionEvent>[
        CompletionEvent(
          eventId: 'e1',
          conversationId: 'c',
          taskId: 't1',
          planVersionId: 'v',
          planRevision: 0,
          completedAtUtc: DateTime.utc(2026, 11, 4, 1),
        ),
        CompletionEvent(
          eventId: 'e2',
          conversationId: 'c',
          taskId: 't2',
          planVersionId: 'v',
          planRevision: 0,
          completedAtUtc: DateTime.utc(2026, 11, 5, 1),
        ),
        CompletionEvent(
          eventId: 'e3',
          conversationId: 'c',
          taskId: 't3',
          planVersionId: 'v',
          planRevision: 0,
          completedAtUtc: DateTime.utc(2026, 11, 4, 2),
          undoneAtUtc: DateTime.utc(2026, 11, 4, 3),
        ),
      ]);
      expect(
        ledger.completedCount(
          fromUtc: DateTime.utc(2026, 11, 4),
          toUtc: DateTime.utc(2026, 11, 5),
        ),
        1,
      );
      expect(ledger.completedCount(), 2);
    });
  });

  test('JSON round-trip 与坏条目容错', () {
    final ledger = ExecutionLedger(
      records: <ExecutionRecord>[sampleRecord()],
      completionEvents: <CompletionEvent>[
        CompletionEvent(
          eventId: 'e1',
          conversationId: 'c',
          taskId: 't',
          planVersionId: 'v',
          planRevision: 0,
          completedAtUtc: DateTime.utc(2026, 11, 4, 1),
        ),
      ],
    );
    final json = ledger.toJson();
    final restored = ExecutionLedger.fromJson(json);
    expect(restored.records.length, 1);
    expect(restored.completionEvents.length, 1);

    final corrupted = ExecutionLedger.fromJson(<String, dynamic>{
      'records': <dynamic>[
        <String, dynamic>{'recordId': ''},
        <String, dynamic>{
          'recordId': 'ok',
          'taskId': 't',
          'taskName': '任务',
          'createdAtUtc': '2026-11-04T01:00:00.000Z',
        },
      ],
    });
    expect(corrupted.records.length, 1);
    expect(corrupted.records.first.recordId, 'ok');
  });
}
