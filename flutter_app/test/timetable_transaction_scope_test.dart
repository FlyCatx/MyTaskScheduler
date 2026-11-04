// 第一轮验收 E01/E02/E07 的模型级回归（纯模型，不依赖 Widget / Win32）。
//
// E01 一笔绘制事务：多格笔画只产生一条历史；undo/redo 完整恢复 state/taskId/
//    reservationId/精确分钟（非 15 分钟整点）；新编辑清 redo；无变化不入历史。
// E02 历史容量：超过 200 笔后丢最旧、undoDepth 有界；undo 后新编辑让旧 redo 失效。
// E07 跨周编辑：模型层没有“当前周”概念，历史按日期规则生效；浏览另一周不影响
//    历史；undo 只撤销最后那一笔且作用于它原本的日期。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/model/timetable_transactions.dart';

Timetable _defaults({String weekStart = '2026-11-09'}) =>
    Timetable.withDefaults(weekStart: weekStart);

void main() {
  group('E01 一笔绘制事务', () {
    test('多格笔画只产生一条历史，undo/redo 恢复 state/taskId/reservationId', () {
      final draft = TimetableDraft(_defaults());
      draft.beginStroke();
      draft.paintSlots(
        date: '2026-11-10',
        slots: const <int>[32, 33, 34, 35],
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
      );
      draft.endStroke();

      expect(draft.undoDepth, 1, reason: '一笔拖动只能产生一条历史');
      final drawn = draft.timetable.taskEntries.single;
      expect(drawn.start, 32 * 15);
      expect(drawn.end, 36 * 15);
      expect(drawn.taskId, 'T1');
      expect(drawn.reservationId, 'r1');

      expect(draft.undo(), isTrue);
      expect(draft.timetable.taskEntries, isEmpty);
      expect(draft.canRedo, isTrue);

      expect(draft.redo(), isTrue);
      final restored = draft.timetable.taskEntries.single;
      expect(restored.state, TimetableState.task);
      expect(restored.taskId, 'T1');
      expect(restored.reservationId, 'r1');
      expect(restored.start, 32 * 15);
      expect(restored.end, 36 * 15);
      expect(restored.date, '2026-11-10');
      expect(restored.title, '任务预留');
      expect(draft.undoDepth, 1);
      expect(draft.canRedo, isFalse);
    });

    test('非 15 分钟整点的区间在笔画/undo/redo 中保留真实边界', () {
      // 初始规则 09:05–10:05（545–605），不是 15 分钟整点。
      final base = _defaults().paint(
        date: '2026-11-10',
        start: 545,
        end: 605,
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
      );
      final draft = TimetableDraft(base);
      expect(draft.timetable.day('2026-11-10', 2).at(545)!.start, 545);

      // 一笔只覆盖其中 09:30–10:00（570–600）：精确边界必须保留。
      draft.beginStroke();
      draft.paintSlots(
        date: '2026-11-10',
        slots: const <int>[38, 39],
        state: TimetableState.occupied,
      );
      draft.endStroke();
      final intervals = draft.timetable.day('2026-11-10', 2).intervals;
      final task = intervals
          .where((i) => i.state == TimetableState.task)
          .toList(growable: false);
      expect(task.map((i) => '${i.start}-${i.end}').toSet(),
          <String>{'545-570', '600-605'},
          reason: '笔画切分后仍保留 09:05 / 10:05 的精确分钟');
      expect(
        intervals.any((i) =>
            i.state == TimetableState.occupied &&
            i.start == 570 &&
            i.end == 600),
        isTrue,
      );

      expect(draft.undo(), isTrue);
      final restored = draft.timetable
          .day('2026-11-10', 2)
          .intervals
          .where((i) => i.state == TimetableState.task)
          .toList(growable: false);
      expect(restored, hasLength(1));
      expect(restored.single.start, 545);
      expect(restored.single.end, 605);
      expect(restored.single.taskId, 'T1');
      expect(restored.single.reservationId, 'r1');

      expect(draft.redo(), isTrue);
      final reSplit = draft.timetable
          .day('2026-11-10', 2)
          .intervals
          .where((i) => i.state == TimetableState.task)
          .toList(growable: false);
      expect(reSplit.map((i) => '${i.start}-${i.end}').toSet(),
          <String>{'545-570', '600-605'});
    });

    test('undo 后新编辑清空 redo', () {
      final draft = TimetableDraft(_defaults());
      draft.paintSlots(
          date: '2026-11-10', slots: const <int>[32], state: TimetableState.task);
      draft.endStroke();
      draft.undo();
      expect(draft.canRedo, isTrue);

      draft.paintSlots(
          date: '2026-11-11', slots: const <int>[32], state: TimetableState.task);
      draft.endStroke();
      expect(draft.canRedo, isFalse, reason: '新编辑分叉后旧 redo 必须失效');
      expect(draft.redo(), isFalse);
    });

    test('无变化不产生历史：空笔画与 recordTransaction 都返回无变化', () {
      final draft = TimetableDraft(_defaults());
      // 重复擦除已经显式可用的同一格：内容不变。
      draft.eraseSlots(date: '2026-11-10', slots: const <int>[0]);
      draft.endStroke();
      expect(draft.undoDepth, 1);
      draft.eraseSlots(date: '2026-11-10', slots: const <int>[0]);
      draft.endStroke();
      expect(draft.undoDepth, 1, reason: '无变化笔画不能产生历史');

      expect(
        draft.recordTransaction(draft.timetable, label: '空复制'),
        isFalse,
        reason: 'recordTransaction 无变化必须返回 false',
      );
      expect(draft.undoDepth, 1);
      expect(
        draft.recordTransaction(
          draft.timetable.copyWith(revision: 7),
          label: '只改 revision',
        ),
        isFalse,
        reason: 'revision 不是业务数据，不能产生撤销记录',
      );
    });
  });

  group('E02 历史容量与分叉', () {
    test('超过 200 笔丢最旧，undoDepth 有界且只能回退最近 200 笔', () {
      expect(TimetableDraft.historyCapacity, 200);
      final draft = TimetableDraft(_defaults());
      var current = draft.timetable;
      for (var i = 0; i < 205; i++) {
        final date = addDaysToDateKey('2026-11-01', i ~/ 24);
        final minute = (i % 24) * 60;
        final next = current.paint(
          date: date,
          start: minute,
          end: minute + 15,
          state: TimetableState.occupied,
        );
        expect(draft.recordTransaction(next, label: '第 $i 笔'), isTrue);
        current = next;
      }
      expect(draft.undoDepth, 200, reason: '容量上限必须是 200，不能无限增长');
      expect(draft.timetable.dates, hasLength(205));

      for (var i = 0; i < 200; i++) {
        expect(draft.undo(), isTrue, reason: '第 ${i + 1} 次撤销应成功');
      }
      expect(draft.canUndo, isFalse);
      expect(draft.undo(), isFalse, reason: '最旧的 5 笔已经被丢弃');
      expect(draft.undoDepth, 0);
      expect(draft.redoDepth, 200);
      // 前 5 笔（i=0..4）落到的规则仍在初始快照里。
      expect(draft.timetable.dates, hasLength(5));
    });

    test('undo 后新事务让旧 redo 不可用', () {
      final draft = TimetableDraft(_defaults());
      var current = draft.timetable;
      for (var i = 0; i < 3; i++) {
        final next = current.paint(
          date: addDaysToDateKey('2026-11-10', i),
          start: 480,
          end: 540,
          state: TimetableState.task,
        );
        expect(draft.recordTransaction(next, label: '第 $i 笔'), isTrue);
        current = next;
      }
      draft.undo();
      expect(draft.canRedo, isTrue);
      expect(draft.redoDepth, 1);

      final branched = draft.timetable.paint(
        date: '2026-11-20',
        start: 480,
        end: 540,
        state: TimetableState.occupied,
      );
      expect(draft.recordTransaction(branched, label: '改画另一天'), isTrue);
      expect(draft.canRedo, isFalse, reason: '分叉后旧 redo 不可用');
      expect(draft.redoDepth, 0);
    });
  });

  group('E07 跨周编辑按日期生效', () {
    test('两周各画一笔：undo 只撤销后一笔且作用于原始日期', () {
      // 覆盖两周：2026-11-09..2026-11-22。
      final base = _defaults().copyWith(dateTo: '2026-11-22');
      final draft = TimetableDraft(base);

      draft.paintSlots(
        date: '2026-11-10', // 第一周周二
        slots: const <int>[32],
        state: TimetableState.task,
        taskId: 'T1',
        reservationId: 'r1',
        title: '任务预留',
      );
      draft.endStroke();
      expect(draft.undoDepth, 1);

      // 模型层没有“当前可见周”，weekDays 只是只读展开：不能动历史。
      final week1 = draft.timetable.weekDays(weekStart: '2026-11-09');
      final week2 = draft.timetable.weekDays(weekStart: '2026-11-16');
      expect(week1, hasLength(7));
      expect(week2, hasLength(7));
      expect(draft.undoDepth, 1, reason: '浏览另一周不产生也不清空历史');
      expect(draft.canRedo, isFalse);

      draft.paintSlots(
        date: '2026-11-17', // 第二周周二
        slots: const <int>[32],
        state: TimetableState.task,
        taskId: 'T2',
        reservationId: 'r2',
        title: '任务预留',
      );
      draft.endStroke();
      expect(draft.undoDepth, 2);

      expect(draft.undo(), isTrue);
      expect(
        draft.timetable.dates.any((e) => e.date == '2026-11-17'),
        isFalse,
        reason: '撤销只作用于后一笔（第二周）',
      );
      expect(
        draft.timetable.dates
            .where((e) => e.date == '2026-11-10' && e.isTask)
            .single
            .taskId,
        'T1',
        reason: '第一周的笔不能被一起撤销',
      );
      expect(draft.canRedo, isTrue);

      expect(draft.redo(), isTrue);
      expect(
        draft.timetable.dates
            .where((e) => e.date == '2026-11-17' && e.isTask)
            .single
            .taskId,
        'T2',
      );
    });

    test('recordTransaction 用 affectedDates 标记跨周批量事务', () {
      final base = _defaults().copyWith(dateTo: '2026-11-22');
      final history = TimetableHistory(initial: base);
      final changed = base
          .paint(
            date: '2026-11-10',
            start: 480,
            end: 540,
            state: TimetableState.task,
            taskId: 'T1',
            reservationId: 'r1',
          )
          .paint(
            date: '2026-11-17',
            start: 480,
            end: 540,
            state: TimetableState.task,
            taskId: 'T1',
            reservationId: 'r2',
          );
      final real = TimetableTransaction(
        label: '复制到第二周',
        before: base,
        after: changed,
        affectedDates: const <String>{'2026-11-10', '2026-11-17'},
      );
      expect(real.affectedDates, <String>{'2026-11-10', '2026-11-17'});
      expect(history.record(real), isTrue);
      expect(history.undoLabel, '复制到第二周');
      final undone = history.undo()!;
      expect(undone.dates, isEmpty);
      expect(history.redoLabel, '复制到第二周');
      final redone = history.redo()!;
      expect(
        redone.dates.map((e) => e.date).toSet(),
        <String>{'2026-11-10', '2026-11-17'},
      );
    });
  });
}
