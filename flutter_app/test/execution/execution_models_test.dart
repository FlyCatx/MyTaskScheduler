// 执行模型测试：JSON round-trip、旧数据缺字段默认值、未知/0 区分、修订上限、
// 待校正处理上限、手工补记重叠口径。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';

void main() {
  group('ExecutionRecord JSON', () {
    test('round-trip 保留全部事实与修订', () {
      final record = ExecutionRecord.start(
        recordId: 'rec-1',
        conversationId: 'conv-1',
        taskId: 'task-a',
        taskName: '整理需求',
        planVersionId: 'ver-1',
        planRevision: 3,
        startedAtUtc: DateTime.utc(2026, 11, 4, 1),
        timeZoneName: 'Asia/Shanghai (UTC+08:00)',
        timeZoneOffsetMinutes: 480,
        estimateBaselineHours: 2,
      ).copyWith(
        intervals: <ExecutionInterval>[
          ExecutionInterval(
            startUtc: DateTime.utc(2026, 11, 4, 1),
            endUtc: DateTime.utc(2026, 11, 4, 1, 30),
          ),
        ],
        manualEntries: <ManualEntry>[
          ManualEntry(
            entryId: 'man-1',
            mode: ManualEntryMode.duration,
            durationSeconds: 600,
            localDate: '2026-11-04',
            createdAtUtc: DateTime.utc(2026, 11, 4, 2),
            note: '补记',
          ),
        ],
        pendingCorrections: <PendingCorrection>[
          PendingCorrection(
            correctionId: 'cor-1',
            observedStartUtc: DateTime.utc(2026, 11, 4, 2),
            observedEndUtc: DateTime.utc(2026, 11, 4, 3),
            wallDeltaSeconds: 3600,
            monotonicDeltaSeconds: 0,
            reason: CorrectionReason.suspend,
            detectedAtUtc: DateTime.utc(2026, 11, 4, 3),
          ),
        ],
        state: ExecutionRecordState.pendingCorrection,
      );

      final json = record.toJson();
      final restored = ExecutionRecord.fromJson(json)!;
      expect(restored.recordId, 'rec-1');
      expect(restored.taskName, '整理需求');
      expect(restored.lineageRootId, 'task-a');
      expect(restored.planRevision, 3);
      expect(restored.estimateBaselineHours, 2);
      expect(restored.intervals.length, 1);
      expect(restored.manualEntries.length, 1);
      expect(restored.pendingCorrections.length, 1);
      expect(restored.pendingCorrections.first.isOpen, true);
      expect(restored.hasRecordedFacts, true);
      expect(restored.state, ExecutionRecordState.pendingCorrection);
      expect(restored.toJson(), json);
    });

    test('旧数据缺字段时给默认值，不编造事实', () {
      final legacy = <String, dynamic>{
        'recordId': 'legacy-1',
        'conversationId': 'conv-1',
        'taskId': 'task-a',
        'taskName': '旧记录',
        'planVersionId': 'ver-0',
        'planRevision': 0,
        'createdAtUtc': '2026-11-01T01:00:00.000Z',
        'timeZoneName': '',
        'timeZoneOffsetMinutes': 0,
        // 缺 state / intervals / manualEntries / pendingCorrections / lineageRootId
      };
      final record = ExecutionRecord.fromJson(legacy)!;
      expect(record.state, ExecutionRecordState.confirmed);
      expect(record.intervals, isEmpty);
      expect(record.manualEntries, isEmpty);
      expect(record.pendingCorrections, isEmpty);
      expect(record.hasRecordedFacts, false);
      expect(record.lineageRootId, 'task-a');
      expect(record.estimateBaselineHours, isNull);
    });

    test('缺 state 但有未处理校正时推导为 pendingCorrection', () {
      final legacy = <String, dynamic>{
        'recordId': 'legacy-2',
        'conversationId': 'conv-1',
        'taskId': 'task-a',
        'createdAtUtc': '2026-11-01T01:00:00.000Z',
        'pendingCorrections': <dynamic>[
          <String, dynamic>{
            'correctionId': 'cor-legacy',
            'observedStartUtc': '2026-11-01T02:00:00.000Z',
            'observedEndUtc': '2026-11-01T03:00:00.000Z',
            'wallDeltaSeconds': 3600,
            'reason': 'suspend',
            'detectedAtUtc': '2026-11-01T03:00:00.000Z',
          },
        ],
      };
      final record = ExecutionRecord.fromJson(legacy)!;
      expect(record.state, ExecutionRecordState.pendingCorrection);
      expect(record.hasOpenCorrections, true);
      expect(record.pendingCorrections.first.isOpen, true);
    });

    test('缺 recordId/taskId 的坏记录返回 null，不猜', () {
      expect(ExecutionRecord.fromJson(<String, dynamic>{'recordId': ''}), isNull);
      expect(ExecutionRecord.fromJson(<String, dynamic>{'taskId': 'a'}), isNull);
      expect(ExecutionRecord.fromJson(null), isNull);
    });
  });

  group('实际事实与未知口径', () {
    test('计时区间长度按绝对时间，非法/零区间不产生事实', () {
      final zero = ExecutionInterval(
        startUtc: DateTime.utc(2026, 11, 4, 1),
        endUtc: DateTime.utc(2026, 11, 4, 1),
      );
      expect(zero.duration, Duration.zero);
      expect(zero.isValid, false);
      final reversed = ExecutionInterval(
        startUtc: DateTime.utc(2026, 11, 4, 2),
        endUtc: DateTime.utc(2026, 11, 4, 1),
      );
      expect(reversed.duration, Duration.zero);
      final normal = ExecutionInterval(
        startUtc: DateTime.utc(2026, 11, 4, 1),
        endUtc: DateTime.utc(2026, 11, 4, 1, 30),
      );
      expect(normal.duration, const Duration(minutes: 30));
    });

    test('没有手工补记的事实不产生实际记录', () {
      final record = ExecutionRecord(
        recordId: 'r',
        conversationId: 'c',
        taskId: 't',
        taskName: '任务',
        planVersionId: 'v',
        planRevision: 0,
        createdAtUtc: DateTime.utc(2026, 11, 4),
        timeZoneName: '',
        timeZoneOffsetMinutes: 0,
      );
      expect(record.hasRecordedFacts, false);
      final withZeroManual = record.copyWith(manualEntries: <ManualEntry>[
        ManualEntry(
          entryId: 'm',
          mode: ManualEntryMode.duration,
          durationSeconds: 0,
          localDate: '2026-11-04',
          createdAtUtc: DateTime.utc(2026, 11, 4),
        ),
      ]);
      // 显式补记 0 分钟 = 已记录 0 分钟，与“从未记录”不同。
      expect(withZeroManual.hasRecordedFacts, true);
    });
  });

  group('待校正处理', () {
    test('未处理前不计入，折扣/全额/自定义各自有界', () {
      final base = PendingCorrection(
        correctionId: 'cor',
        observedStartUtc: DateTime.utc(2026, 11, 4, 2),
        observedEndUtc: DateTime.utc(2026, 11, 4, 3),
        wallDeltaSeconds: 3600,
        monotonicDeltaSeconds: 0,
        reason: CorrectionReason.suspend,
        detectedAtUtc: DateTime.utc(2026, 11, 4, 3),
      );
      expect(base.isOpen, true);
      expect(base.decidedDuration, Duration.zero);

      final discounted = base.resolved(
        decision: CorrectionDecision.discount,
        seconds: 0,
        atUtc: DateTime.utc(2026, 11, 4, 4),
      );
      expect(discounted.isOpen, false);
      expect(discounted.decidedDuration, Duration.zero);

      final counted = base.resolved(
        decision: CorrectionDecision.countFull,
        seconds: 3600,
        atUtc: DateTime.utc(2026, 11, 4, 4),
      );
      expect(counted.decidedDuration, const Duration(hours: 1));

      final capped = base.resolved(
        decision: CorrectionDecision.custom,
        seconds: 48 * 3600,
        atUtc: DateTime.utc(2026, 11, 4, 4),
      );
      expect(capped.decidedDuration,
          const Duration(seconds: kMaxPendingCorrectionSeconds));
      expect(kMaxPendingCorrectionSeconds, 12 * 3600);
    });

    test('墙钟回拨产生的负跨度只保留观察值，展示为 0', () {
      final correction = PendingCorrection(
        correctionId: 'cor-back',
        observedStartUtc: DateTime.utc(2026, 11, 4, 3),
        observedEndUtc: DateTime.utc(2026, 11, 4, 2),
        wallDeltaSeconds: -3600,
        monotonicDeltaSeconds: -3600,
        reason: CorrectionReason.clockJump,
        detectedAtUtc: DateTime.utc(2026, 11, 4, 3),
      );
      expect(correction.observedDuration, Duration.zero);
      expect(correction.wallDeltaSeconds, -3600);
    });
  });

  group('手工补记重叠口径', () {
    ManualEntry entry(OverlapPolicy policy) => ManualEntry(
          entryId: 'm',
          mode: ManualEntryMode.startEnd,
          startUtc: DateTime.utc(2026, 11, 4, 1),
          endUtc: DateTime.utc(2026, 11, 4, 2),
          durationSeconds: 3600,
          localDate: '2026-11-04',
          createdAtUtc: DateTime.utc(2026, 11, 4, 3),
          overlapSpans: <TimeSpan>[
            TimeSpan(
              startUtc: DateTime.utc(2026, 11, 4, 1, 30),
              endUtc: DateTime.utc(2026, 11, 4, 2),
            ),
          ],
          overlapPolicy: policy,
        );

    test('默认排除重叠部分，用户明确保留才计入并带标记', () {
      final excluded = entry(OverlapPolicy.excludeOverlap);
      expect(excluded.overlapSeconds, 1800);
      expect(excluded.countedSeconds, 1800);
      expect(excluded.overlapIncluded, false);

      final included = entry(OverlapPolicy.includeOverlap);
      expect(included.countedSeconds, 3600);
      expect(included.overlapIncluded, true);
    });
  });

  group('修订历史', () {
    test('withRevision 保留最近快照且不超过上限', () {
      var record = ExecutionRecord(
        recordId: 'r',
        conversationId: 'c',
        taskId: 't',
        taskName: '任务',
        planVersionId: 'v',
        planRevision: 0,
        createdAtUtc: DateTime.utc(2026, 11, 4),
        timeZoneName: '',
        timeZoneOffsetMinutes: 0,
      );
      for (var i = 0; i < kMaxRecordRevisions + 5; i++) {
        record = record.withRevision(ExecutionRevision(
          revisionId: 'rev-$i',
          atUtc: DateTime.utc(2026, 11, 4, i),
          action: 'manualAdd',
          snapshot: record.toJson(),
        ));
      }
      expect(record.revisions.length, kMaxRecordRevisions);
      expect(record.revisions.last.revisionId,
          'rev-${kMaxRecordRevisions + 4}');
      expect(record.lastRevertibleRevision?.snapshot, isNotNull);
      // 快照能还原出记录本身。
      final restored =
          ExecutionRecord.fromJson(record.revisions.last.snapshot!)!;
      expect(restored.recordId, 'r');
    });
  });

  group('完成事件', () {
    test('撤销不删除事件本身，只标记 undoneAtUtc', () {
      final event = CompletionEvent(
        eventId: 'e',
        conversationId: 'c',
        taskId: 't',
        planVersionId: 'v',
        planRevision: 0,
        completedAtUtc: DateTime.utc(2026, 11, 4, 1),
      );
      final undone = event.undo(DateTime.utc(2026, 11, 4, 2));
      expect(event.isActive, true);
      expect(undone.isActive, false);
      expect(undone.completedAtUtc, DateTime.utc(2026, 11, 4, 1));
      expect(undone.undoneAtUtc, DateTime.utc(2026, 11, 4, 2));
      final restored = CompletionEvent.fromJson(undone.toJson())!;
      expect(restored.isActive, false);
    });
  });

  group('TimerCheckpoint', () {
    test('round-trip 保留开放区间与暂停状态', () {
      final checkpoint = TimerCheckpoint(
        recordId: 'r',
        conversationId: 'c',
        taskId: 't',
        taskName: '任务',
        planVersionId: 'v',
        planRevision: 2,
        phase: TimerPhase.running,
        sessionStartedAtUtc: DateTime.utc(2026, 11, 4, 1),
        checkpointUtc: DateTime.utc(2026, 11, 4, 1, 10),
        openIntervalStartUtc: DateTime.utc(2026, 11, 4, 1),
        timeZoneName: 'Asia/Shanghai',
        timeZoneOffsetMinutes: 480,
        estimateBaselineHours: 1.5,
      );
      final restored = TimerCheckpoint.fromJson(checkpoint.toJson())!;
      expect(restored.phase, TimerPhase.running);
      expect(restored.openIntervalStartUtc, DateTime.utc(2026, 11, 4, 1));
      expect(restored.estimateBaselineHours, 1.5);
      expect(
        TimerCheckpoint.fromJson(<String, dynamic>{
          'recordId': 'r',
          'phase': 'idle',
        }),
        isNull,
      );
    });
  });
}
