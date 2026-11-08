// 计时控制器测试（R3-E1/E3 的核心语义）。
//
// 用可注入时钟构造人工可算的时间轴，锁住：
//   * 开始/暂停/继续/停止，暂停不计入；停止≠完成；完成不写实际；重开不清零；
//   * 全应用单活动计时，切任务先明确暂停；
//   * 回拨/跳变/睡眠/tick 间隔异常 → 待校正、暂停、不产生负值或巨额；
//   * checkpoint 有界（默认 15 秒）与崩溃恢复边界（检查点之后不自动计入）；
//   * 多实例同目录只读；
//   * 手工补记校验、重叠默认不计入、用户明确保留才计入、删除可撤销。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';

import 'execution_test_support.dart';
import 'fake_effort_clock.dart';

void main() {
  group('开始/暂停/继续/停止', () {
    test('暂停不计入、继续产生新区间、停止只结束计时', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      final start = await timer.start(taskRef());
      expect(start.ok, true);
      expect(timer.isRunning, true);
      expect(timer.active!.taskId, 'task-a');

      clock.advance(const Duration(seconds: 60));
      await timer.tick();
      final paused = await timer.pause();
      expect(paused.ok, true);
      expect(timer.isPaused, true);
      expectDuration(timer.elapsed, const Duration(seconds: 60));

      // 暂停 10 分钟：暂停区间不计入实际耗时。
      clock.advance(const Duration(minutes: 10));
      await timer.tick();
      expectDuration(timer.elapsed, const Duration(seconds: 60));

      await timer.resume();
      clock.advance(const Duration(seconds: 30));
      await timer.tick();
      final stopped = await timer.stopAndConfirm();
      expect(stopped.ok, true);
      expect(stopped.confirmed, const Duration(seconds: 90));
      expect(timer.hasActive, false);
      expectDuration(timer.elapsed, Duration.zero);

      final record =
          timer.ledger.recordsForTask('task-a').single;
      expect(record.intervals.length, 2);
      expect(record.pendingCorrections, isEmpty);
      expect(record.state, ExecutionRecordState.confirmed);
      final effort = RecordEffort(record);
      expectDuration(effort.confirmedDuration, const Duration(seconds: 90));

      // 停止计时 ≠ 完成任务：控制器从不写完成事件/预估。
      expect(timer.ledger.completionEvents, isEmpty);
      expect(record.hasRecordedFacts, true);
      // 完成任务也不会自动写实际（这里没有任何自动追加的记录）。
      expect(timer.ledger.records.length, 1);
    });

    test('重新打开任务不重置已确认实际：再次开始只追加新记录', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 40));
      await timer.tick();
      await timer.pause();
      await timer.stopAndConfirm();

      final first = timer.ledger.recordsForTask('task-a').single;
      final firstConfirmed = RecordEffort(first).confirmedDuration;

      clock.advance(const Duration(hours: 3));
      await timer.start(taskRef(planVersionId: 'ver-2', planRevision: 2));
      clock.advance(const Duration(seconds: 20));
      await timer.tick();
      await timer.stopAndConfirm();

      final records = timer.ledger.recordsForTask('task-a');
      expect(records.length, 2, reason: '第二次开始是一条新记录，不改写旧记录');
      expect(RecordEffort(records.first).confirmedDuration, firstConfirmed);
      expect(first.estimateBaselineHours, 2);
      expect(records.last.estimateBaselineHours, 2);
      expect(records.last.planVersionId, 'ver-2');
    });

    test('全应用同时只有一个活动计时：开始另一个先明确暂停当前', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef(taskId: 'task-a', name: '任务 A'));
      clock.advance(const Duration(minutes: 1));
      await timer.tick();

      final switched = await timer.start(
          taskRef(taskId: 'task-b', name: '任务 B', estimateHours: 1));
      expect(switched.ok, true);
      expect(switched.pausedTaskName, '任务 A');
      expect(timer.active!.taskId, 'task-b');
      expect(timer.isRunning, true);

      clock.advance(const Duration(minutes: 2));
      await timer.tick();
      await timer.pause();

      final a = timer.ledger.recordsForTask('task-a').single;
      final b = timer.ledger.recordsForTask('task-b').single;
      expectDuration(RecordEffort(a).confirmedDuration, const Duration(minutes: 1));
      expectDuration(RecordEffort(b).confirmedDuration, const Duration(minutes: 2),
          reason: '切换后不会出现两个同时运行的计时');
      expect(a.intervals.length, 1);
      expect(b.intervals.length, 1);
    });
  });

  group('系统时间异常与睡眠', () {
    test('墙钟回拨：无负时长，超出部分进待校正', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 60));
      await timer.tick();
      clock.jumpWall(const Duration(hours: -1));
      final result = await timer.tick();

      expect(result.ok, true);
      expect(timer.isPaused, true);
      expect(timer.elapsed.isNegative, false);
      expectDuration(timer.elapsed, const Duration(seconds: 60));

      final record = timer.ledger.recordsForTask('task-a').single;
      expect(record.hasOpenCorrections, true);
      final correction = record.pendingCorrections.single;
      expect(correction.reason, CorrectionReason.clockJump);
      expect(correction.wallDeltaSeconds, lessThan(0));
      // 待校正不进入确认时长。
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 60));
      expectDuration(RecordEffort(record).pendingDuration, Duration.zero,
          reason: '负跨度没有可展示的正时长');
    });

    test('墙钟大幅前跳：不会产生巨额已确认工时', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 60));
      await timer.tick();
      clock.jumpWall(const Duration(hours: 48));
      await timer.tick();

      final record = timer.ledger.recordsForTask('task-a').single;
      expect(timer.isPaused, true);
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 60));
      expect(record.pendingCorrections.single.wallDeltaSeconds,
          const Duration(hours: 48).inSeconds);

      // 默认待校正不计入；用户明确折扣后确认时长仍只有 1 分钟。
      await timer.resolveCorrection(record.pendingCorrections.single.correctionId,
          CorrectionDecision.discount);
      final after = timer.ledger.recordsForTask('task-a').single;
      expect(after.state, ExecutionRecordState.confirmed);
      expectDuration(RecordEffort(after).confirmedDuration,
          const Duration(seconds: 60));
    });

    test('睡眠/锁屏（单调时钟停走）：暂停 + 待校正，不伪造精确值', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 10));
      await timer.tick();
      // 睡 2 小时：墙钟前进、单调时钟不走。
      clock.freezeMonotonic();
      clock.advance(const Duration(hours: 2));
      await timer.tick();
      clock.resumeMonotonic();

      expect(timer.isPaused, true);
      final record = timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 10));
      final correction = record.pendingCorrections.single;
      // 墙钟与单调时钟不一致时无法区分“睡眠”和“系统时间被改”，
      // 两者都进入待校正，由用户确认；关键是不自动计入。
      expect(
        correction.reason,
        anyOf(CorrectionReason.suspend, CorrectionReason.clockJump),
      );
      expectDuration(correction.observedDuration, const Duration(hours: 2));

      // 用户确认这段时间确实在工作，才按上限计入。
      await timer.resolveCorrection(
          correction.correctionId, CorrectionDecision.countFull);
      final resolved = timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(resolved).confirmedDuration,
          const Duration(seconds: 10) + const Duration(hours: 2));
    });

    test('tick 间隔异常（进程被挂起）也进入待校正', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 10));
      await timer.tick();
      // 事件循环被挂起 2 小时（墙钟与单调时钟都前进）。
      clock.advance(const Duration(hours: 2));
      await timer.tick();

      expect(timer.isPaused, true);
      final record = timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 10));
      expect(record.pendingCorrections.single.reason, CorrectionReason.suspend);
    });

    test('显式离开钩子：关闭当前区间并把不确定段标记待校正', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 30));
      await timer.tick();
      clock.advance(const Duration(minutes: 5));
      await timer.handleAwayDetected(reason: CorrectionReason.suspend);

      expect(timer.isPaused, true);
      final record = timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 30));

      final resume = await timer.handleResumeFromAway();
      expect(resume.message, contains('待校正'));
    });
  });

  group('checkpoint 与崩溃恢复', () {
    test('检查点按有界间隔写入，最大丢失时长明确', () async {
      final fixture = await TimerFixture.create(
        checkpointInterval: const Duration(seconds: 15),
      );
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;
      expect(timer.maxCheckpointLoss, const Duration(seconds: 15));

      await timer.start(taskRef());
      final startAt = clock.nowUtc;
      clock.advance(const Duration(seconds: 5));
      await timer.tick();
      // 5 秒没到间隔：检查点还停留在开始时刻。
      expect(fixture.store.checkpoint!.checkpointUtc, startAt);

      clock.advance(const Duration(seconds: 11)); // 累计 16 秒
      await timer.tick();
      expect(fixture.store.checkpoint!.checkpointUtc,
          startAt.add(const Duration(seconds: 16)),
          reason: '达到间隔即落盘，不能只在正常退出时保存');
      expect(fixture.store.checkpoint!.openIntervalStartUtc, startAt);
    });

    test('崩溃恢复把 [最后检查点, 重启] 放进待校正，不默认算入', () async {
      final dir = newTempDir('crash');
      final clock = FakeEffortClock(startUtc: testStartUtc);
      final fixture = await TimerFixture.create(directory: dir, clock: clock);
      final timer = fixture.timer;

      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 5));
      // 未到检查点间隔就崩溃：最近检查点还在开始时刻。
      await fixture.store.close();

      clock.advance(const Duration(hours: 1));
      final reopened = await TimerFixture.create(directory: dir, clock: clock);
      addTearDown(() async {
        await reopened.close();
        deleteDirQuietly(dir);
      });

      expect(reopened.timer.isPaused, true);
      expect(reopened.timer.recoveryNotice, contains('待校正'));
      final record = reopened.timer.ledger.recordsForTask('task-a').single;
      expect(record.pendingCorrections.single.reason,
          CorrectionReason.crashRecovery);
      // 只丢失检查点间隔内的 5 秒（≤ 15 秒），且不自动计为工作。
      expectDuration(RecordEffort(record).confirmedDuration, Duration.zero);
      expectDuration(
        record.pendingCorrections.single.observedDuration,
        const Duration(hours: 1, seconds: 5),
        reason: '检查点到重启的全部时间都进待校正（包括崩溃前的 5 秒）',
      );

      await reopened.timer.resolveCorrection(
        record.pendingCorrections.single.correctionId,
        CorrectionDecision.discount,
      );
      final stopped = await reopened.timer.stopAndConfirm();
      expect(stopped.ok, true);
      expect(reopened.timer.hasActive, false);

      final after = reopened.timer.ledger.recordsForTask('task-a').single;
      expect(after.state, ExecutionRecordState.confirmed);
      expectDuration(RecordEffort(after).confirmedDuration, Duration.zero);
    });

    test('恢复到检查点为止的已确认时长，检查点之后不自动计入', () async {
      final dir = newTempDir('crash2');
      final clock = FakeEffortClock(startUtc: testStartUtc);
      final fixture = await TimerFixture.create(directory: dir, clock: clock);
      final timer = fixture.timer;

      await timer.start(taskRef());
      final startAt = clock.nowUtc;
      clock.advance(const Duration(seconds: 20));
      await timer.tick(); // 20 秒 > 15 秒，检查点落在 t0+20s
      await fixture.store.close();

      clock.advance(const Duration(hours: 1));
      final reopened = await TimerFixture.create(directory: dir, clock: clock);
      addTearDown(() async {
        await reopened.close();
        deleteDirQuietly(dir);
      });

      final record = reopened.timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(record).confirmedDuration,
          const Duration(seconds: 20));
      expect(record.intervals.single.endUtc,
          startAt.add(const Duration(seconds: 20)));
      expect(record.pendingCorrections.single.observedStartUtc,
          startAt.add(const Duration(seconds: 20)));
    });

    test('暂停状态退出：重开后保留暂停会话且不产生待校正', () async {
      final dir = newTempDir('paused');
      final clock = FakeEffortClock(startUtc: testStartUtc);
      final fixture = await TimerFixture.create(directory: dir, clock: clock);

      await fixture.timer.start(taskRef());
      clock.advance(const Duration(seconds: 5));
      await fixture.timer.tick();
      await fixture.timer.pause();
      await fixture.store.close();

      clock.advance(const Duration(minutes: 10));
      final reopened = await TimerFixture.create(directory: dir, clock: clock);
      addTearDown(() async {
        await reopened.close();
        deleteDirQuietly(dir);
      });
      expect(reopened.timer.isPaused, true);
      expectDuration(reopened.timer.elapsed, const Duration(seconds: 5));
      final record = reopened.timer.ledger.recordsForTask('task-a').single;
      expect(record.pendingCorrections, isEmpty);

      await reopened.timer.resume();
      clock.advance(const Duration(seconds: 10));
      await reopened.timer.tick();
      await reopened.timer.stopAndConfirm();
      final after = reopened.timer.ledger.recordsForTask('task-a').single;
      expectDuration(RecordEffort(after).confirmedDuration,
          const Duration(seconds: 15));
    });

    test('正常关闭会暂停并保存检查点，重开可继续', () async {
      final dir = newTempDir('shutdown');
      final clock = FakeEffortClock(startUtc: testStartUtc);
      final fixture = await TimerFixture.create(directory: dir, clock: clock);
      await fixture.timer.start(taskRef());
      clock.advance(const Duration(seconds: 25));
      await fixture.timer.tick();
      await fixture.timer.shutdown();
      fixture.timer.dispose();

      clock.advance(const Duration(minutes: 5));
      final reopened = await TimerFixture.create(directory: dir, clock: clock);
      addTearDown(() async {
        await reopened.close();
        deleteDirQuietly(dir);
      });
      expect(reopened.timer.isPaused, true);
      expectDuration(reopened.timer.elapsed, const Duration(seconds: 25));
      final record = reopened.timer.ledger.recordsForTask('task-a').single;
      expect(record.pendingCorrections, isEmpty);
    });
  });

  group('多实例只读', () {
    test('第二个实例只读：可查看但不能开始/修改计时', () async {
      final dir = newTempDir('multi');
      final first = await TimerFixture.create(directory: dir);
      addTearDown(() async {
        await first.close();
        deleteDirQuietly(dir);
      });
      await first.timer.start(taskRef());
      first.clock.advance(const Duration(seconds: 30));
      await first.timer.tick();

      final second = await TimerFixture.create(directory: dir);
      expect(second.timer.readOnly, true);
      expect(second.timer.readOnlyNotice, contains('另一个'));
      expect(second.timer.ledger.recordsForTask('task-a').length, 1,
          reason: '只读实例仍能查看执行记录');

      final start = await second.timer.start(taskRef(taskId: 'task-b'));
      expect(start.ok, false);
      expect(start.message, contains('只读'));
      final pause = await second.timer.pause();
      expect(pause.ok, false);
      final manual = await second.timer.previewManualEntry(
        taskRef(),
        const ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: Duration(minutes: 10),
        ),
      );
      expect(manual.ok, false);
      await second.close();
    });
  });

  group('手工补记', () {
    test('拒绝未来时间、起止颠倒、负时长与超上限', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      final now = clock.nowUtc;
      final future = await timer.previewManualEntry(
        taskRef(taskId: 'task-a'),
        ManualEntryDraft(
          mode: ManualEntryMode.startEnd,
          startUtc: now.add(const Duration(hours: 1)),
          endUtc: now.add(const Duration(hours: 2)),
        ),
      );
      expect(future.ok, false);
      expect(future.message, contains('未来'));

      final reversed = await timer.previewManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.startEnd,
          startUtc: now.subtract(const Duration(minutes: 30)),
          endUtc: now.subtract(const Duration(hours: 1)),
        ),
      );
      expect(reversed.ok, false);
      expect(reversed.message, contains('结束时间必须晚于开始时间'));

      final negative = await timer.previewManualEntry(
        taskRef(),
        const ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: Duration(minutes: -5),
        ),
      );
      expect(negative.ok, false);
      expect(negative.message, contains('非负'));

      final tooLong = await timer.previewManualEntry(
        taskRef(),
        const ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: Duration(hours: 30),
        ),
      );
      expect(tooLong.ok, false);
      expect(tooLong.message, contains('不能超过'));

      final tooOld = await timer.previewManualEntry(
        taskRef(),
        const ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: Duration(minutes: 30),
          localDate: '1990-01-01',
        ),
      );
      expect(tooOld.ok, false);
      expect(tooOld.message, contains('久远'));

      // 校验失败不写盘。
      expect(timer.ledger.records, isEmpty);
    });

    test('没有计时记录时补记会新建记录；0 分钟也算已记录（≠未知）', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      final zero = await timer.addManualEntry(
        taskRef(taskId: 'task-new', name: '新任务'),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: Duration.zero,
          localDate: formatLocalDate(timer.localTime.toLocal(clock.nowUtc)),
        ),
      );
      expect(zero.ok, true);
      final record = timer.ledger.recordsForTask('task-new').single;
      expect(record.hasRecordedFacts, true);
      expectDuration(RecordEffort(record).confirmedDuration, Duration.zero);
      expect(record.manualEntries.single.durationSeconds, 0);

      final added = await timer.addManualEntry(
        taskRef(taskId: 'task-new', name: '新任务'),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: const Duration(minutes: 25),
          localDate: formatLocalDate(timer.localTime.toLocal(clock.nowUtc)),
        ),
      );
      expect(added.ok, true);
      expect(timer.ledger.recordsForTask('task-new').length, 1,
          reason: '同一任务继续挂到已有记录，不重复建记录');
      expectDuration(
        RecordEffort(timer.ledger.recordsForTask('task-new').single)
            .confirmedDuration,
        const Duration(minutes: 25),
      );
    });

    test('重叠提示区间且默认不计入；用户明确保留才计入并标口径', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;
      clock.setWallClock(DateTime.utc(2026, 11, 4, 5));

      // 已有 1 小时计时事实（直接写账本，避免依赖计时流程）。
      final existingStart = DateTime.utc(2026, 11, 4, 1);
      final existingEnd = existingStart.add(const Duration(hours: 1));
      fixture.store.ledger.addRecord(recordWithInterval(
        recordId: 'existing',
        startUtc: existingStart,
        endUtc: existingEnd,
      ));
      await fixture.store.persistLedger();

      final overlapStart = existingStart.add(const Duration(minutes: 30));
      final overlapEnd = overlapStart.add(const Duration(hours: 1));
      final preview = await timer.previewManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.startEnd,
          startUtc: overlapStart,
          endUtc: overlapEnd,
        ),
      );
      expect(preview.ok, true);
      expect(preview.hasOverlap, true);
      expect(preview.overlapTotal, const Duration(minutes: 30));
      expect(preview.overlaps.single.span.startUtc, overlapStart);

      final excluded = await timer.addManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.startEnd,
          startUtc: overlapStart,
          endUtc: overlapEnd,
        ),
      );
      expect(excluded.ok, true);
      final excludedRecord = timer.ledger.recordsForTask('task-a').single;
      final excludedEntry = excludedRecord.manualEntries.single;
      expect(excludedEntry.overlapSeconds, 1800);
      expect(excludedEntry.countedSeconds, 1800);
      expect(excluded.overlapExcluded, const Duration(minutes: 30));

      // 另一条完全重叠、“明确保留并计入”的补记。
      final included = await timer.addManualEntry(
        taskRef(taskId: 'task-a'),
        ManualEntryDraft(
          mode: ManualEntryMode.startEnd,
          startUtc: existingStart,
          endUtc: existingStart.add(const Duration(minutes: 15)),
          overlapPolicy: OverlapPolicy.includeOverlap,
        ),
      );
      expect(included.ok, true);
      final record = timer.ledger.recordsForTask('task-a').single;
      final includedEntry =
          record.manualEntries.lastWhere((e) => e.overlapIncluded);
      expect(includedEntry.durationSeconds, 900);
      expect(includedEntry.countedSeconds, 900);

      final effort = RecordEffort(record);
      expectDuration(effort.overlapIncludedDuration, const Duration(minutes: 15));
      expectDuration(effort.manualCountedDuration,
          const Duration(minutes: 30) + const Duration(minutes: 15));
    });

    test('仅时长补记按归属日期整天计入', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;
      final today = formatLocalDate(timer.localTime.toLocal(clock.nowUtc));
      final yesterday = formatLocalDate(
          timer.localTime.toLocal(clock.nowUtc.subtract(const Duration(days: 1))));

      await timer.addManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: const Duration(minutes: 45),
          localDate: yesterday,
        ),
      );
      await timer.addManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: const Duration(minutes: 15),
          localDate: today,
        ),
      );
      final record = timer.ledger.recordsForTask('task-a').single;
      expect(record.manualEntries.length, 2);
      expectDuration(
        confirmedWithin(
          RecordEffort(record),
          fromUtc: shanghaiUtc(2026, 11, 4),
          toUtc: shanghaiUtc(2026, 11, 5),
          localTime: timer.localTime,
        ),
        const Duration(minutes: 15),
      );
      expectDuration(
        confirmedWithin(
          RecordEffort(record),
          fromUtc: shanghaiUtc(2026, 11, 3),
          toUtc: shanghaiUtc(2026, 11, 4),
          localTime: timer.localTime,
        ),
        const Duration(minutes: 45),
      );
    });

    test('删除补记可撤销，恢复后事实回来', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;
      final outcome = await timer.addManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: const Duration(minutes: 20),
          localDate: formatLocalDate(timer.localTime.toLocal(clock.nowUtc)),
        ),
      );
      final recordId = outcome.recordId!;
      final entryId = outcome.entry!.entryId;

      final removed = await timer.removeManualEntry(recordId, entryId);
      expect(removed.ok, true);
      expect(
          timer.ledger.recordById(recordId)!.manualEntries.length, 0);

      final reverted = await timer.revertRecord(recordId);
      expect(reverted.ok, true);
      expect(
          timer.ledger.recordById(recordId)!.manualEntries.length, 1);
      expectDuration(
        RecordEffort(timer.ledger.recordById(recordId)!).confirmedDuration,
        const Duration(minutes: 20),
      );
    });
  });

  group('待校正处理与完成事件', () {
    test('自定义校正是有界的，负面输入被拒绝', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;
      await timer.start(taskRef());
      clock.advance(const Duration(seconds: 5));
      await timer.tick();
      clock.advance(const Duration(hours: 3));
      await timer.tick();
      final correction = timer.ledger
          .recordsForTask('task-a')
          .single
          .pendingCorrections
          .single;

      final negative = await timer.resolveCorrection(
        correction.correctionId,
        CorrectionDecision.custom,
        custom: const Duration(seconds: -1),
      );
      expect(negative.ok, false);

      final custom = await timer.resolveCorrection(
        correction.correctionId,
        CorrectionDecision.custom,
        custom: const Duration(minutes: 5),
      );
      expect(custom.ok, true);
      final record = timer.ledger.recordsForTask('task-a').single;
      expect(record.state, ExecutionRecordState.confirmed);
      expectDuration(RecordEffort(record).correctionDuration,
          const Duration(minutes: 5));
    });

    test('完成事件独立于计时记录：完成/撤销都不删除实际耗时', () async {
      final fixture = await TimerFixture.create();
      addTearDown(fixture.close);
      final timer = fixture.timer;
      final clock = fixture.clock;

      await timer.addManualEntry(
        taskRef(),
        ManualEntryDraft(
          mode: ManualEntryMode.duration,
          duration: const Duration(minutes: 10),
          localDate: formatLocalDate(timer.localTime.toLocal(clock.nowUtc)),
        ),
      );
      final before = RecordEffort(timer.ledger.recordsForTask('task-a').single);

      final completed = await timer.recordTaskCompletion(
        conversationId: 'conv-1',
        taskId: 'task-a',
        planVersionId: 'ver-1',
        planRevision: 1,
      );
      expect(completed.ok, true);
      expect(timer.ledger.completionEvents.length, 1);
      // 完成不写实际：记录事实没有变化。
      expectDuration(
        RecordEffort(timer.ledger.recordsForTask('task-a').single)
            .confirmedDuration,
        before.confirmedDuration,
      );

      final undone = await timer.undoTaskCompletion('task-a');
      expect(undone.ok, true);
      expect(timer.ledger.activeCompletionFor('task-a'), isNull);
      expect(timer.ledger.recordsForTask('task-a').length, 1,
          reason: '撤销完成不删除执行记录');
    });
  });

  test('没有活动计时时 tick/pause/stop 返回明确失败', () async {
    final fixture = await TimerFixture.create();
    addTearDown(fixture.close);
    expect((await fixture.timer.tick()).ok, false);
    expect((await fixture.timer.pause()).ok, false);
    expect((await fixture.timer.resume()).ok, false);
    expect((await fixture.timer.stopAndConfirm()).ok, false);
  });
}
