// 时间表编辑事务与撤销/重做历史的回归测试。
//
// 断言的是“用户可观察结果”：撤销/重做后 state、taskId、reservationId、日期规则
// 与周规则是否完整恢复；无变化是否真的不入历史；容量上限是否真的丢最旧。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/model/timetable_transactions.dart';

Timetable _defaults() => Timetable.withDefaults(weekStart: '2026-10-19');

Timetable _withTaskBlock() => _defaults().paint(
      date: '2026-10-19',
      start: 600,
      end: 660,
      state: TimetableState.task,
      origin: TimetableOrigin.manual,
      title: '任务预留',
      taskId: 'T1',
      reservationId: 'r1',
    );

void main() {
  group('TimetableHistory 基础行为', () {
    test('record 记录一笔；undo/redo 恢复完整业务数据（state/taskId/reservationId）',
        () {
      final before = _defaults();
      final after = _withTaskBlock();
      final history = TimetableHistory(initial: before);
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
      expect(history.undo(), isNull);
      expect(history.redo(), isNull);

      const label = '绘制任务 10:00-11:00';
      expect(
        history.record(TimetableTransaction(
          label: label,
          before: before,
          after: after,
          affectedDates: const <String>{'2026-10-19'},
        )),
        isTrue,
      );
      expect(history.canUndo, isTrue);
      expect(history.undoDepth, 1);
      expect(history.undoLabel, label);
      expect(history.redoDepth, 0);

      final undone = history.undo()!;
      expect(undone.stateAt('2026-10-19', 1, 630), TimetableState.free);
      expect(undone.dates, isEmpty, reason: '撤销必须移除整条日期规则');
      expect(history.canRedo, isTrue);
      expect(history.redoDepth, 1);
      expect(history.redoLabel, label);
      expect(history.canUndo, isFalse);

      final redone = history.redo()!;
      expect(identical(history.timetable, redone), isTrue,
          reason: 'present 必须与 redo 返回的快照一致');
      final entry = redone.taskEntries.single;
      expect(entry.state, TimetableState.task);
      expect(entry.taskId, 'T1');
      expect(entry.reservationId, 'r1');
      expect(entry.title, '任务预留');
      expect(entry.start, 600);
      expect(entry.end, 660);
      expect(entry.date, '2026-10-19');
      expect(history.canUndo, isTrue);
      expect(history.canRedo, isFalse);
    });

    test('业务数据相同（只差 revision）不入栈，也不清空 redo', () {
      final base = _defaults();
      final history = TimetableHistory(initial: base);
      final changed = _withTaskBlock();
      history.record(
          TimetableTransaction(label: '绘制', before: base, after: changed));
      history.undo();
      expect(history.canRedo, isTrue);

      final noChange = TimetableTransaction(
        label: '空操作',
        before: base,
        after: base.copyWith(revision: 5),
      );
      expect(history.record(noChange), isFalse);
      expect(history.canRedo, isTrue, reason: '无变化不能清空重做路径');
      expect(history.undoDepth, 0);
      expect(history.redoDepth, 1);
    });

    test('undo 后产生新编辑 → redo 清空', () {
      final base = _defaults();
      final history = TimetableHistory(initial: base);
      final t1 = base.paint(
          date: '2026-10-19', start: 600, end: 660, state: TimetableState.task);
      final t2 = t1.paint(
          date: '2026-10-20', start: 600, end: 660, state: TimetableState.task);
      history.record(TimetableTransaction(label: '画周一', before: base, after: t1));
      history.record(TimetableTransaction(label: '画周二', before: t1, after: t2));
      history.undo();
      expect(history.canRedo, isTrue);
      expect(history.redoLabel, '画周二');

      final branched = base.paint(
          date: '2026-10-21', start: 600, end: 660, state: TimetableState.task);
      history.record(TimetableTransaction(
          label: '改画周三', before: history.timetable!, after: branched));
      expect(history.canRedo, isFalse, reason: '分叉后旧的重做路径必须失效');
      expect(history.redoDepth, 0);
    });

    test('容量上限丢最旧；默认容量常量是 200', () {
      expect(TimetableHistory.defaultCapacity, 200);
      expect(TimetableDraft.historyCapacity, TimetableHistory.defaultCapacity);

      final base = _defaults();
      final history = TimetableHistory(initial: base, capacity: 3);
      var previous = base;
      for (var day = 0; day < 4; day++) {
        final next = previous.paint(
          date: addDaysToDateKey('2026-10-19', day),
          start: 600,
          end: 660,
          state: TimetableState.task,
        );
        history.record(
            TimetableTransaction(label: '第 $day 笔', before: previous, after: next));
        previous = next;
      }
      expect(history.undoDepth, 3, reason: '超出容量要丢最旧，而不是无限增长');
      expect(history.undo(), isNotNull);
      expect(history.undo(), isNotNull);
      expect(history.undo(), isNotNull);
      expect(history.undo(), isNull, reason: '最旧的一笔已被丢弃');
    });

    test('markApplied 以基线为准并清空两栈', () {
      final base = _defaults();
      final history = TimetableHistory(initial: base);
      final changed = _withTaskBlock();
      history.record(
          TimetableTransaction(label: '绘制', before: base, after: changed));
      history.undo();
      expect(history.canRedo, isTrue);

      history.markApplied(changed);
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
      expect(history.timetable, changed);
      expect(history.undoDepth, 0);
      expect(history.redoDepth, 0);
    });
  });

  group('TimetableDraft 撤销/重做', () {
    test('一笔拖动可撤销可重做，taskId/reservationId 完整恢复', () {
      final draft = TimetableDraft(_defaults());
      draft.paintSlots(
        date: '2026-10-19',
        slots: const <int>[40, 41],
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
      );
      draft.endStroke();
      expect(draft.canUndo, isTrue);
      expect(draft.canRedo, isFalse);
      expect(draft.undoDepth, 1);

      expect(draft.undo(), isTrue);
      expect(draft.timetable.dates, isEmpty);
      expect(draft.timetable.stateAt('2026-10-19', 1, 10 * 60), TimetableState.free);
      expect(draft.canRedo, isTrue);
      expect(draft.redoDepth, 1);

      expect(draft.redo(), isTrue);
      final entry = draft.timetable.taskEntries.single;
      expect(entry.state, TimetableState.task);
      expect(entry.taskId, 'T1');
      expect(entry.reservationId, 'r1');
      expect(entry.start, 600);
      expect(entry.end, 630);
      expect(draft.canRedo, isFalse);
    });

    test('undo 后产生新编辑 → redo 清空', () {
      final draft = TimetableDraft(_defaults());
      draft.paintSlots(
          date: '2026-10-19', slots: const <int>[40], state: TimetableState.task);
      draft.endStroke();
      draft.undo();
      expect(draft.canRedo, isTrue);

      draft.paintSlots(
          date: '2026-10-19', slots: const <int>[44], state: TimetableState.task);
      draft.endStroke();
      expect(draft.canRedo, isFalse, reason: '新编辑必须清空重做栈');
      expect(draft.redo(), isFalse);
      expect(draft.timetable.dates.single.start, 44 * 15);
    });

    test('无变化的笔画不入历史', () {
      final draft = TimetableDraft(_defaults());
      draft.eraseSlots(date: '2026-10-19', slots: const <int>[0]);
      draft.endStroke();
      expect(draft.undoDepth, 1);

      // 再擦一次同样的格子：内容完全一致，不应多一条历史。
      draft.eraseSlots(date: '2026-10-19', slots: const <int>[0]);
      draft.endStroke();
      expect(draft.undoDepth, 1, reason: '无变化的笔画不能产生撤销记录');
    });

    test('recordTransaction 一次调用 = 一笔事务；undo/redo 整笔恢复', () {
      final draft = TimetableDraft(_defaults());
      final painted = draft.timetable.paintRange(
        startDate: '2026-10-19',
        startMinute: 23 * 60 + 30,
        endDate: '2026-10-20',
        endMinute: 30,
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
        coverageFrom: '2026-10-19',
        coverageTo: '2026-10-25',
      )!;
      const label = '跨日绘制任务 23:30-00:30';
      expect(
        draft.recordTransaction(
          painted,
          label: label,
          affectedDates: const <String>{'2026-10-19', '2026-10-20'},
        ),
        isTrue,
        reason: '有真实变化应返回 true（T2 据此判断是否产生撤销记录）',
      );
      expect(draft.undoDepth, 1, reason: '跨日整段是一笔事务，不是每天一笔');
      expect(draft.lastActionLabel, label);

      expect(draft.undo(), isTrue);
      expect(draft.timetable.dates, isEmpty);
      expect(
        draft.timetable.stateAt('2026-10-19', 1, 23 * 60 + 45),
        TimetableState.occupied,
        reason: '撤销必须回到默认占用，而不是留下半段',
      );

      expect(draft.redo(), isTrue);
      expect(draft.timetable.taskEntries, hasLength(2));
      expect(
        draft.timetable.taskEntries.map((e) => e.taskId).toSet(),
        <String>{'T1'},
      );
      expect(
        draft.timetable.taskEntries.map((e) => e.reservationId).toSet(),
        <String>{'r1-1', 'r1-2'},
        reason: '跨日拆分的两个片段必须有各自稳定的预留身份',
      );
    });

    test('recordTransaction 无变化不入栈、不清空 redo，并返回 false', () {
      final draft = TimetableDraft(_defaults());
      final changed = draft.timetable.paint(
          date: '2026-10-19', start: 600, end: 660, state: TimetableState.task);
      expect(draft.recordTransaction(changed, label: '画一笔'), isTrue);
      expect(draft.undoDepth, 1);
      draft.undo();
      expect(draft.canRedo, isTrue);

      expect(
        draft.recordTransaction(draft.timetable.copyWith(revision: 9),
            label: '空操作'),
        isFalse,
        reason: '无真实变化必须返回 false，T2 不应产生撤销记录',
      );
      expect(draft.undoDepth, 0);
      expect(draft.canRedo, isTrue, reason: '无真实变化不能清空重做');
    });

    test('reset 与 markApplied 都清空两栈', () {
      final draft = TimetableDraft(_defaults());
      final changed = draft.timetable.paint(
          date: '2026-10-19', start: 600, end: 660, state: TimetableState.task);
      expect(draft.recordTransaction(changed, label: '画一笔'), isTrue);
      draft.undo();
      expect(draft.canRedo, isTrue);
      draft.reset(changed);
      expect(draft.canUndo, isFalse);
      expect(draft.canRedo, isFalse);
      expect(draft.timetable, changed);

      expect(
        draft.recordTransaction(
          changed.paint(
              date: '2026-10-20',
              start: 600,
              end: 660,
              state: TimetableState.task),
          label: '再画一笔',
        ),
        isTrue,
      );
      expect(draft.undoDepth, 1);
      draft.markApplied();
      expect(draft.canUndo, isFalse);
      expect(draft.canRedo, isFalse);
      expect(draft.undoDepth, 0);
    });

    test('进行中的笔画：redo 不可用，undo 回滚半笔', () {
      final draft = TimetableDraft(_defaults());
      draft.beginStroke();
      draft.paintSlots(
          date: '2026-10-19', slots: const <int>[40], state: TimetableState.task);
      expect(draft.canUndo, isTrue);
      expect(draft.canRedo, isFalse);
      expect(draft.redo(), isFalse, reason: '半笔未提交时不能重做');
      expect(draft.undo(), isTrue);
      expect(draft.timetable.dates, isEmpty);
      expect(draft.undoDepth, 0);
    });
  });
}
