// 跨午夜绘制（paintRange）与“复制到多天”（planCopyDateRules）的回归测试。
//
// 断言用户可观察结果：拆分后的真实日期规则、coverage 外明确失败、fillFreeOnly
// 不覆盖占用/任务预留/用户锁定、replaceSelection 如实统计移除区间与任务引用、
// 无变化时 plan.isEmpty 为 true。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';

/// 全天默认可用、无周模板规则的空白时间表（coverage 2026-10-19..2026-10-25）。
Timetable _blank() => Timetable.withDefaults(
      weekStart: '2026-10-19',
      unavailable: const <WallClockRange>[],
    );

Timetable _crossDayResult(Timetable? result) {
  expect(result, isNotNull, reason: 'coverage 内的跨日区间必须成功');
  return result!;
}

void main() {
  group('paintRange 跨午夜按自然日拆分', () {
    test('同一天写入保留整分钟', () {
      final painted = _crossDayResult(_blank().paintRange(
        startDate: '2026-10-19',
        startMinute: 545,
        endDate: '2026-10-19',
        endMinute: 575,
        state: TimetableState.occupied,
        coverageFrom: '2026-10-19',
        coverageTo: '2026-10-25',
      ));
      expect(painted.day('2026-10-19', 1).at(545)?.start, 545);
      expect(painted.day('2026-10-19', 1).at(545)?.end, 575);
      expect(painted.dates.single.date, '2026-10-19');
    });

    test('周一 23:30 → 周二 00:30 拆成两天，不产生 end>1440 的规则', () {
      final base = _blank();
      final painted = _crossDayResult(base.paintRange(
        startDate: '2026-10-19',
        startMinute: 23 * 60 + 30,
        endDate: '2026-10-20',
        endMinute: 30,
        state: TimetableState.occupied,
        coverageFrom: '2026-10-19',
        coverageTo: '2026-10-25',
      ));
      expect(painted.stateAt('2026-10-19', 1, 23 * 60 + 45),
          TimetableState.occupied);
      expect(painted.stateAt('2026-10-20', 2, 15), TimetableState.occupied);
      // 端点之外仍是默认可用。
      expect(painted.stateAt('2026-10-19', 1, 23 * 60 + 15), TimetableState.free);
      expect(painted.stateAt('2026-10-20', 2, 45), TimetableState.free);
      expect(painted.dates, hasLength(2));
      expect(
        painted.dates.map((e) => '${e.date} ${e.start}-${e.end}').toSet(),
        <String>{'2026-10-19 1410-1440', '2026-10-20 0-30'},
      );
      expect(painted.dates.every((e) => e.end <= kTimetableMinutesPerDay), isTrue);
      // 只改写了涉及的日期，没有动周模板。
      expect(painted.weekly, isEmpty);
      expect(base.dates, isEmpty, reason: '纯函数不能就地修改原时间表');
    });

    test('跨三天：首日 [22:00,24:00)、整天、末日 [0,02:00)', () {
      final painted = _crossDayResult(_blank().paintRange(
        startDate: '2026-10-20',
        startMinute: 22 * 60,
        endDate: '2026-10-22',
        endMinute: 2 * 60,
        state: TimetableState.occupied,
        coverageFrom: '2026-10-19',
        coverageTo: '2026-10-25',
      ));
      expect(painted.stateAt('2026-10-20', 2, 23 * 60), TimetableState.occupied);
      expect(painted.stateAt('2026-10-21', 3, 12 * 60), TimetableState.occupied);
      expect(painted.stateAt('2026-10-22', 4, 60), TimetableState.occupied);
      expect(painted.stateAt('2026-10-22', 4, 3 * 60), TimetableState.free);
      expect(painted.dates, hasLength(3));
    });

    test('周日 23:30 → 周一 00:30 不取模铺满整周', () {
      final base = _blank().copyWith(dateTo: '2026-10-26');
      final painted = _crossDayResult(base.paintRange(
        startDate: '2026-10-25',
        startMinute: 23 * 60 + 30,
        endDate: '2026-10-26',
        endMinute: 30,
        state: TimetableState.occupied,
        coverageFrom: '2026-10-19',
        coverageTo: '2026-10-26',
      ));
      expect(painted.stateAt('2026-10-25', 7, 23 * 60 + 45),
          TimetableState.occupied);
      expect(painted.stateAt('2026-10-26', 1, 15), TimetableState.occupied);
      expect(painted.dates, hasLength(2),
          reason: '跨午夜只写两天，不能按星期取模铺满一周');
      for (final date in <String>['2026-10-19', '2026-10-20', '2026-10-22']) {
        expect(painted.stateAt(date, weekdayOfDateKey(date), 23 * 60 + 45),
            TimetableState.free,
            reason: '$date 不能被这次跨日写入污染');
      }
    });

    test('端点越界 / 区间非法 / 日期非法都返回 null，不静默截断', () {
      Timetable? run({
        String startDate = '2026-10-19',
        int startMinute = 23 * 60 + 30,
        String endDate = '2026-10-20',
        int endMinute = 30,
        String coverageFrom = '2026-10-19',
        String coverageTo = '2026-10-25',
      }) =>
          _blank().paintRange(
            startDate: startDate,
            startMinute: startMinute,
            endDate: endDate,
            endMinute: endMinute,
            state: TimetableState.occupied,
            coverageFrom: coverageFrom,
            coverageTo: coverageTo,
          );

      expect(run(startDate: '2026-10-18'), isNull, reason: '起点在 coverage 之前');
      expect(run(endDate: '2026-10-26'), isNull, reason: '终点在 coverage 之后');
      expect(run(endDate: '2026-10-18'), isNull, reason: '终点早于起点');
      expect(run(endDate: '2026-10-19', endMinute: 23 * 60 + 30), isNull,
          reason: '同一天必须 end > start');
      expect(run(startMinute: 1440), isNull);
      expect(run(endMinute: 1441), isNull);
      expect(run(startDate: '2026-02-31'), isNull, reason: '不存在的日期要明确失败');
      expect(run(coverageFrom: '2026-10-26', coverageTo: '2026-10-25'), isNull,
          reason: 'coverage 反向要明确失败');
    });

    test('跨日蓝块的每个片段有独立 reservationId', () {
      final painted = _crossDayResult(_blank().paintRange(
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
      ));
      expect(painted.taskEntries, hasLength(2));
      expect(
        painted.taskEntries.map((e) => e.reservationId).toSet(),
        <String>{'r1-1', 'r1-2'},
      );
      expect(painted.taskEntries.every((e) => e.taskId == 'T1'), isTrue);
    });
  });

  group('planCopyDateRules 只填空闲（默认）', () {
    Timetable source() => _blank()
        .paint(
          date: '2026-10-19',
          start: 600,
          end: 660,
          state: TimetableState.occupied,
          title: '课程',
        )
        .paint(
          date: '2026-10-19',
          start: 840,
          end: 900,
          state: TimetableState.task,
          title: '任务预留',
          taskId: 'T1',
          reservationId: 'r1',
        );

    test('复制到多天：去重升序、统计写入分钟、不复制 taskId', () {
      final plan = planCopyDateRules(
        source: source(),
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-21', '2026-10-20', '2026-10-21'],
      );
      expect(plan.targetDates, <String>['2026-10-20', '2026-10-21']);
      expect(plan.changedMinutes, 240, reason: '两天 × (60 分钟占用 + 60 分钟蓝块)');
      expect(plan.isEmpty, isFalse);
      expect(plan.protectedSkippedMinutes, 0);
      expect(plan.removedRanges, isEmpty, reason: '填充模式不声明移除任何区间');

      expect(plan.result.stateAt('2026-10-20', 2, 10 * 60 + 30),
          TimetableState.occupied);
      expect(plan.result.stateAt('2026-10-21', 3, 10 * 60 + 30),
          TimetableState.occupied);
      for (final date in <String>['2026-10-20', '2026-10-21']) {
        final copied = plan.result.dates
            .where((e) => e.date == date && e.isTask)
            .toList(growable: false);
        expect(copied, hasLength(1));
        expect(copied.single.taskId, isNull, reason: '默认不复制 taskId');
        expect(copied.single.reservationId, isNotNull,
            reason: '复制出来的蓝块要有独立身份');
        expect(copied.single.reservationId, isNot('r1'));
        expect(copied.single.start, 840);
        expect(copied.single.end, 900);
      }
      expect(plan.warnings.any((w) => w.contains('默认不复制绑定关系')), isTrue);
      expect(applyCopyPlan(plan), same(plan.result));
      // 源日期规则保持原样。
      expect(source().dates, hasLength(2));
    });

    test('不覆盖占用 / 任务预留 / 目标日显式规则（用户锁定）', () {
      // 目标日 10:00-11:00 已被占用；14:00-15:00 是用户显式写出的可用。
      final target = source()
          .paint(
            date: '2026-10-20',
            start: 600,
            end: 660,
            state: TimetableState.occupied,
            title: '已有占用',
          )
          .paint(
            date: '2026-10-20',
            start: 840,
            end: 900,
            state: TimetableState.free,
            title: '手动可用',
          );
      final plan = planCopyDateRules(
        source: target,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
      );
      expect(plan.isEmpty, isTrue, reason: '目标分钟都受保护，没有可写内容');
      expect(plan.protectedSkippedMinutes, 120);
      expect(plan.targetDates, isEmpty);
      expect(plan.result.stateAt('2026-10-20', 2, 870), TimetableState.free);
      expect(identical(plan.result, target), isTrue,
          reason: '无变化时应原样返回源时间表');
    });

    test('部分可写时按可写子区间裁剪并统计被跳过的分钟', () {
      // 目标日 14:00-14:30 被占用，14:30-15:00 仍可写。
      final target = source().paint(
        date: '2026-10-20',
        start: 840,
        end: 870,
        state: TimetableState.task,
        title: '已有预留',
        taskId: 'T2',
        reservationId: 'r2',
      );
      final plan = planCopyDateRules(
        source: target,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
      );
      expect(plan.protectedSkippedMinutes, 30,
          reason: '目标 14:00-14:30 已被任务预留占用，只有 30 分钟可写');
      expect(plan.changedMinutes, 90, reason: '占用 60 + 蓝块可写 30');
      expect(plan.targetDates, <String>['2026-10-20']);
      final copied = plan.result.dates.where(
          (e) => e.date == '2026-10-20' && e.isTask && e.start == 870);
      expect(copied, hasLength(1));
      expect(copied.single.end, 900);
    });

    test('源日期没有显式规则 → plan.isEmpty 为 true', () {
      final blank = _blank();
      final plan = planCopyDateRules(
        source: blank,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.changedMinutes, 0);
      expect(plan.targetDates, isEmpty);
      expect(identical(plan.result, blank), isTrue);
    });

    test('目标日期去重升序；非法日期忽略并提示；源日期不复制给自己', () {
      final plan = planCopyDateRules(
        source: source(),
        sourceDate: '2026-10-19',
        targetDates: <String>[
          '2026-10-21',
          '2026-10-20',
          '2026-10-20',
          '2026-10-19',
          '2026-02-31',
          'not-a-date',
        ],
      );
      expect(plan.targetDates, <String>['2026-10-20', '2026-10-21']);
      expect(plan.warnings.any((w) => w.contains('忽略非法日期')), isTrue);
      expect(
        plan.result.dates
            .where((e) => e.date == '2026-10-19' && e.isTask)
            .length,
        1,
        reason: '源日期原有规则保持原样，不能被重复写成两条',
      );
    });
  });

  group('planCopyDateRules 替换所选时段', () {
    test('如实统计将被移除/改写的区间与任务引用', () {
      // 源：周一 10:00-11:00 占用。目标：周二 09:00-12:00 已绑定任务 T2 的蓝块。
      final target = _blank()
          .paint(
            date: '2026-10-19',
            start: 600,
            end: 660,
            state: TimetableState.occupied,
          )
          .paint(
            date: '2026-10-20',
            start: 540,
            end: 720,
            state: TimetableState.task,
            title: '任务预留',
            taskId: 'T2',
            reservationId: 'r2',
          );
      final plan = planCopyDateRules(
        source: target,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
        strategy: CopyStrategy.replaceSelection,
      );
      expect(plan.removedRanges, contains('2026-10-20 09:00-12:00 任务'));
      expect(plan.affectedTaskIds, contains('T2'));
      expect(plan.changedMinutes, 60);
      expect(plan.result.stateAt('2026-10-20', 2, 10 * 60 + 30),
          TimetableState.occupied);
      expect(plan.result.stateAt('2026-10-20', 2, 9 * 60 + 30),
          TimetableState.task, reason: '替换只动源时段覆盖的分钟');
      expect(plan.result.stateAt('2026-10-20', 2, 11 * 60 + 30),
          TimetableState.task);
      expect(plan.targetDates, <String>['2026-10-20']);
    });

    test('目标已有相同内容时无变化，isEmpty 为 true 且不产生任务引用', () {
      final same = _blank()
          .paint(
            date: '2026-10-19',
            start: 600,
            end: 660,
            state: TimetableState.task,
            taskId: 'T1',
            reservationId: 'r1',
            title: '任务预留',
          )
          .paint(
            date: '2026-10-20',
            start: 600,
            end: 660,
            state: TimetableState.task,
            taskId: 'T1',
            reservationId: 'r2',
            title: '任务预留',
          );
      final plan = planCopyDateRules(
        source: same,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
        strategy: CopyStrategy.replaceSelection,
        keepTaskBindings: true,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.removedRanges, isEmpty);
      expect(plan.affectedTaskIds, isEmpty);
    });

    test('wholeDay=true 复制整天有效时段；默认只复制日期层显式规则', () {
      // 周模板：周一 00:00-08:00 占用；周二没有模板规则（默认可用）。
      final base = _blank().paint(
        weekday: 1,
        start: 0,
        end: 480,
        state: TimetableState.occupied,
      );
      final explicitOnly = planCopyDateRules(
        source: base,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
        strategy: CopyStrategy.replaceSelection,
      );
      expect(explicitOnly.isEmpty, isTrue,
          reason: '周一没有日期层显式规则，默认不复制周模板');

      final wholeDay = planCopyDateRules(
        source: base,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
        strategy: CopyStrategy.replaceSelection,
        wholeDay: true,
      );
      expect(wholeDay.changedMinutes, 480);
      expect(wholeDay.result.stateAt('2026-10-20', 2, 60),
          TimetableState.occupied,
          reason: 'wholeDay 把源日整天有效时段写成目标日日期例外');
      expect(wholeDay.targetDates, <String>['2026-10-20']);
    });
  });

  group('planCopyDateRules 保留任务绑定', () {
    test('keepTaskBindings=true 保留 taskId 并提示预留时长增加', () {
      final source = _blank().paint(
        date: '2026-10-19',
        start: 840,
        end: 900,
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
      );
      final kept = planCopyDateRules(
        source: source,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20', '2026-10-21'],
        keepTaskBindings: true,
      );
      final copied = kept.result.dates
          .where((e) => e.date != '2026-10-19' && e.isTask)
          .toList(growable: false);
      expect(copied, hasLength(2));
      expect(copied.every((e) => e.taskId == 'T1'), isTrue);
      expect(kept.affectedTaskIds, isEmpty, reason: '填充模式不声称移除任务引用');
      expect(
        kept.warnings.any((w) => w.contains('T1') && w.contains('增加 120 分钟')),
        isTrue,
      );
    });

    test('默认 false 时复制为未绑定蓝块', () {
      final source = _blank().paint(
        date: '2026-10-19',
        start: 840,
        end: 900,
        state: TimetableState.task,
        title: '任务预留',
        taskId: 'T1',
        reservationId: 'r1',
      );
      final plan = planCopyDateRules(
        source: source,
        sourceDate: '2026-10-19',
        targetDates: <String>['2026-10-20'],
      );
      final copied = plan.result.dates
          .firstWhere((e) => e.date == '2026-10-20' && e.isTask);
      expect(copied.taskId, isNull);
    });
  });
}
