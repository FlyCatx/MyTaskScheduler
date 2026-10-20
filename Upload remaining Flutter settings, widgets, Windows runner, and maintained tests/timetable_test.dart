// 时间表 v2：模型、绘制、撤销、迁移与请求形状的回归测试。
//
// 这些测试不联网、不依赖真实 DLL：它们只验证“同一份草稿”在模型、网格控件和
// 排程器之间的语义，包括精确分钟、未绑定蓝块、日期覆盖和撤销事务。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_grid.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

Timetable _defaults() => Timetable.withDefaults(weekStart: '2026-10-19');

TimetableDraft _draft() => TimetableDraft(_defaults());

void main() {
  group('默认时间表', () {
    test('每天白格 720 分钟，一周 5040 分钟', () {
      final t = _defaults();
      expect(t.day('2026-10-19', 1).freeMinutes, 720);
      expect(t.freeMinutesPerWeek, 5040);
      expect(t.dailyFreeMinutes(1), 720);
    });

    test('默认占用 00-08、12-14、18-19、23-24，跨午夜已拆分', () {
      final t = _defaults();
      expect(t.stateAt('2026-10-19', 1, 0), TimetableState.occupied);
      expect(t.stateAt('2026-10-19', 1, 479), TimetableState.occupied);
      expect(t.stateAt('2026-10-19', 1, 480), TimetableState.free);
      expect(t.stateAt('2026-10-19', 1, 720), TimetableState.occupied);
      expect(t.stateAt('2026-10-19', 1, 840), TimetableState.free);
      expect(t.stateAt('2026-10-19', 1, 1140), TimetableState.free);
      expect(t.stateAt('2026-10-19', 1, 1380), TimetableState.occupied);
      expect(t.stateAt('2026-10-19', 1, 1439), TimetableState.occupied);
      // 周规则只有 [0,1440) 内的段，不存在 end>1440。
      expect(t.weekly.every((e) => e.end <= 1440), isTrue);
    });

    test('空默认不可用区间 = 全天可用（显式设置，不是缺省）', () {
      final t = Timetable.withDefaults(
        weekStart: '2026-10-19',
        unavailable: const <WallClockRange>[],
      );
      expect(t.freeMinutesPerWeek, 7 * 1440);
    });
  });

  group('绘制与撤销', () {
    test('一次拖动补齐经过的格子，重复经过同格不产生多条历史', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(
        date: '2026-10-19',
        slots: const <int>[36, 37, 38, 39],
        state: TimetableState.task,
      );
      draft.paintSlots(
        date: '2026-10-19',
        slots: const <int>[36, 37],
        state: TimetableState.task,
      );
      draft.endStroke();
      final day = draft.timetable.day('2026-10-19', 1);
      expect(day.stateOfSlot(36), TimetableState.task);
      expect(day.stateOfSlot(39), TimetableState.task);
      expect(draft.undoDepth, 1, reason: '重复经过同格不应多一条撤销');
      expect(draft.undo(), isTrue);
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.free);
    });

    test('连续多次拖动逐次撤销；PointerCancel 回滚半笔', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(date: '2026-10-19', slots: const [36], state: TimetableState.task);
      draft.endStroke();
      draft.beginStroke();
      draft.paintSlots(date: '2026-10-19', slots: const [40], state: TimetableState.task);
      draft.endStroke();
      expect(draft.undoDepth, 2);
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.task);
      draft.undo();
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(40),
          TimetableState.free);
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.task);

      draft.beginStroke();
      draft.paintSlots(date: '2026-10-19', slots: const [44], state: TimetableState.task);
      draft.cancelStroke();
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(44),
          TimetableState.free);
    });

    test('应用后以已提交状态重建撤销基线', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(date: '2026-10-19', slots: const [36], state: TimetableState.task);
      draft.endStroke();
      draft.markApplied();
      expect(draft.undo(), isFalse);
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.task);
    });

    test('右键擦除只恢复目标 15 分钟，不改其它格子', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(
          date: '2026-10-19', slots: const [36, 37], state: TimetableState.occupied);
      draft.endStroke();
      draft.beginStroke();
      draft.eraseSlots(date: '2026-10-19', slots: const [36]);
      draft.endStroke();
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.free);
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(37),
          TimetableState.occupied);
    });
  });

  group('日期覆盖与精确分钟', () {
    test('默认只改本周：日期规则优先于周模板', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(
          date: '2026-10-20', slots: const [36], state: TimetableState.task);
      draft.endStroke();
      expect(draft.timetable.day('2026-10-20', 2).stateOfSlot(36),
          TimetableState.task);
      expect(draft.timetable.day('2026-10-27', 2).stateOfSlot(36),
          TimetableState.free, reason: '下周二不应被本周的日期规则影响');
      expect(draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
          TimetableState.free);
    });

    test('擦除某日默认休息格后变白，并在转换后保持可用', () {
      final draft = _draft();
      // 周一 00:00 默认不可用；右键擦除后必须是显式的 date free，而不是删掉覆盖。
      expect(draft.timetable.stateAt('2026-10-19', 1, 0),
          TimetableState.occupied);
      draft.beginStroke();
      draft.eraseSlots(date: '2026-10-19', slots: const <int>[0]);
      draft.endStroke();
      expect(draft.timetable.stateAt('2026-10-19', 1, 0), TimetableState.free);
      expect(draft.timetable.dates.any((e) => e.date == '2026-10-19'),
          isTrue);
      const base = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
      );
      final converted = draft.timetable.toCalendarSettings(base);
      final exception =
          converted.exceptions.firstWhere((e) => e.date == '2026-10-19');
      expect(
        exception.ranges.any((r) => r.startMinute == 0 && r.endMinute >= 15),
        isTrue,
        reason: '显式 free 覆盖必须进入日期例外，不能被模板重新补回灰块',
      );
    });

    test('每周重复模式改模板后跨周生效', () {
      final draft = _draft();
      draft.beginStroke();
      draft.paintSlots(weekday: 2, slots: const [40], state: TimetableState.occupied);
      draft.endStroke();
      expect(draft.timetable.day('2026-10-20', 2).stateOfSlot(40),
          TimetableState.occupied);
      expect(draft.timetable.day('2026-10-27', 2).stateOfSlot(40),
          TimetableState.occupied);
    });

    test('09:05–09:35 的精确边界保留，不被取整', () {
      var t = _defaults();
      t = t.paint(
        date: '2026-10-19',
        start: 545,
        end: 575,
        state: TimetableState.task,
      );
      final day = t.day('2026-10-19', 1);
      final interval = day.at(545)!;
      expect(interval.start, 545);
      expect(interval.end, 575);
      expect(interval.isPartialCell, isTrue);
      expect(day.slotIsPartial(36), isTrue, reason: '09:00–09:15 格只被部分覆盖');
      // 不再写入 09:00–09:45：总分钟数保持 30。
      final taskMinutes = day.intervals
          .where((i) => i.state == TimetableState.task)
          .fold<int>(0, (sum, i) => sum + i.minutes);
      expect(taskMinutes, 30);
    });
  });

  group('与旧版设置互相转换', () {
    test('显式空可用范围不会被当成全天可用', () {
      const settings = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
        planningDays: 14,
      );
      final t = Timetable.fromSchedule(
        const CalendarSchedule(settings: settings),
        weekStart: '2026-10-19',
      );
      expect(t.freeMinutesPerWeek, 0);
      final converted = t.toCalendarSettings(settings);
      expect(converted.hasAvailability, isFalse);
      expect(converted.weekly.isEmpty, isTrue);
    });

    test('旧版可用时间、占用与片段无损迁移', () {
      const settings = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
        planningDays: 14,
        weekly: WeeklyAvailability({
          1: [WallClockRange(480, 720)],
          2: [WallClockRange(480, 720)],
        }),
        occupancies: [
          CalendarOccupancy(
            id: 'occ-1',
            title: '大学物理',
            kind: 'course',
            weekday: 2,
            ranges: [WallClockRange(540, 600)],
          ),
        ],
      );
      final clock = settings.clock;
      final day = clock.dayStartUtcForDateKey('2026-10-19');
      final schedule = CalendarSchedule(settings: settings, segments: [
        ScheduleSegment(
          id: 'seg-1',
          taskId: 'T1',
          start: day.add(const Duration(minutes: 600)),
          end: day.add(const Duration(minutes: 660)),
          source: SegmentSource.manual,
        ),
      ]);
      final t = Timetable.fromSchedule(schedule, weekStart: '2026-10-19');
      // 周一 08:00-12:00 可用，10:00-11:00 被任务片段占用。
      expect(t.stateAt('2026-10-19', 1, 540), TimetableState.free);
      expect(t.stateAt('2026-10-19', 1, 600), TimetableState.task);
      expect(t.boundMinutesByTask()['T1'], 60);
      // 周二 09:00-10:00 是课程占用。
      expect(t.stateAt('2026-10-20', 2, 540), TimetableState.occupied);

      final back = t.toCalendarSettings(settings);
      expect(back.weekly.forWeekday(1).first.startMinute, 480);
      expect(back.occupancies.any((o) => o.title == '大学物理'), isTrue);
      final segments = t.taskSegments(clock);
      expect(segments, hasLength(1));
      expect(segments.single.taskId, 'T1');
      expect(segments.single.minutes, 60);
    });

    test('未绑定蓝块只占容量，不计入任何任务工时', () {
      var t = _defaults();
      t = t.paint(
        date: '2026-10-19',
        start: 480,
        end: 540,
        state: TimetableState.task,
        title: '任务预留',
      );
      expect(t.boundMinutesByTask(), isEmpty);
      const settings = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
      );
      final converted = t.toCalendarSettings(settings);
      expect(converted.occupancies, hasLength(1));
      expect(converted.occupancies.single.title, '任务预留');
      // 该日 08:00-09:00 不再计入可用容量（日期例外里没有这一段）。
      final exception = converted.exceptions
          .firstWhere((e) => e.date == '2026-10-19');
      expect(
        exception.ranges.any((r) => r.startMinute < 540 && r.endMinute > 480),
        isFalse,
      );
    });
  });

  group('周首日与请求形状', () {
    test('weekStartsOn 只影响列顺序起点', () {
      expect(weekStartFor('2026-10-21', 1), '2026-10-19');
      expect(weekStartFor('2026-10-21', 7), '2026-10-18');
      expect(weekdayOfDateKey('2026-10-19'), 1);
      expect(addDaysToDateKey('2026-12-30', 7), '2027-01-06');
    });

    test('请求 JSON 含 schemaVersion/coverage/revision 与整分钟', () {
      final json = _defaults().toJson();
      expect(json['schemaVersion'], 2);
      expect(json['coverage']['dateFrom'], '2026-10-19');
      expect(json['coverage']['dateTo'], '2026-10-25');
      expect(json['coverage']['defaultState'], 1);
      expect(json['weekly'], isA<List<dynamic>>());
      final first = (json['weekly'] as List<dynamic>).first as Map<String, dynamic>;
      expect(first['start'], isA<int>());
      expect(first['end'], isA<int>());
      expect(first['state'], isA<int>());
      expect(first['origin'], 'default');
    });

    test('非法时间表整体拒绝，不静默修成另一份数据', () {
      expect(
        Timetable.tryParse(<String, dynamic>{
          'schemaVersion': 2,
          'coverage': <String, dynamic>{
            'dateFrom': '2026-10-19',
            'dateTo': '2026-10-25',
            'defaultState': 1,
          },
          'weekly': <dynamic>[
            <String, dynamic>{
              'state': 0,
              'start': 480.5,
              'end': 540,
              'weekdays': <int>[1],
            }
          ],
          'dates': <dynamic>[],
        }),
        isNull,
      );
      expect(
        Timetable.tryParse(<String, dynamic>{
          'schemaVersion': 2,
          'coverage': <String, dynamic>{
            'dateFrom': '2026-10-19',
            'dateTo': '2026-10-18',
          },
          'weekly': <dynamic>[],
          'dates': <dynamic>[],
        }),
        isNull,
      );
    });
  });

  group('通用设置默认值', () {
    test('缺字段用文档默认值；显式空不可用区间表示全天可用', () {
      final legacy = AppPreferences.fromJson(<String, dynamic>{});
      expect(legacy.weekStartsOn, 1);
      expect(legacy.defaultCalendarEditor, CalendarEditorMode.drawing);
      expect(UnavailableRange.totalMinutes(legacy.defaultUnavailableRanges), 720);

      final explicit = AppPreferences.fromJson(<String, dynamic>{
        'weekStartsOn': 7,
        'defaultCalendarEditor': 'fill',
        'defaultUnavailableRanges': <dynamic>[],
      });
      expect(explicit.weekStartsOn, 7);
      expect(explicit.defaultCalendarEditor, CalendarEditorMode.fill);
      expect(explicit.defaultUnavailableRanges, isEmpty);
    });

    test('跨午夜默认不可用时间被规范化为两段', () {
      final normalized = UnavailableRange.normalizeAll(const [
        UnavailableRange(1380, 1560),
      ]);
      expect(normalized, hasLength(2));
      expect(normalized.first.start, 0);
      expect(normalized.first.end, 120);
      expect(normalized.last.start, 1380);
      expect(normalized.last.end, 1440);
    });
  });

  group('排程衔接', () {
    test('默认时间表 300 分钟任务拆成 08:00–12:00 与 14:00–15:00', () {
      const base = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-20',
        planningDays: 7,
      );
      final timetable = Timetable.withDefaults(weekStart: '2026-10-19');
      final settings = timetable.toCalendarSettings(base);
      final plan = autoSchedule(
        current: CalendarSchedule(settings: settings),
        tasks: const <SchedulingTask>[
          SchedulingTask(id: 'T1', name: '写报告', estimatedHours: 5),
        ],
        now: DateTime.utc(2026, 10, 20),
        keepManual: false,
      );
      final segments = plan.schedule.forTask('T1');
      final total =
          segments.fold<int>(0, (sum, s) => sum + s.minutes);
      expect(total, 300);
      const clock = WallClock(480);
      String stamp(DateTime t) {
        final w = clock.toWall(t);
        return WallClockRange.formatMinute(w.hour * 60 + w.minute);
      }

      expect(stamp(segments.first.start), '08:00');
      expect(stamp(segments.first.end), '12:00');
      expect(stamp(segments.last.start), '14:00');
      expect(stamp(segments.last.end), '15:00');
    });
  });

  group('网格控件', () {
    Future<(TimetableGridController, String)> pumpGrid(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.light);
      addTearDown(() => TsColors.apply(Brightness.light));
      final draft = _draft();
      final controller = TimetableGridController(draft: draft);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 960,
            height: 700,
            child: TimetableGrid(
              controller: controller,
              weekStart: '2026-10-19',
              weekStartsOn: 1,
              weeklyMode: false,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (controller, '2026-10-19');
    }

    Offset cellCenter(WidgetTester tester, int day, int slot) {
      final box = tester.getRect(find.byType(TimetableGrid));
      final gridWidth = box.width -
          TimetableGrid.timeAxisWidth -
          TimetableGrid.scrollbarGutter;
      final dayWidth = gridWidth / 7;
      return Offset(
        box.left + TimetableGrid.timeAxisWidth + dayWidth * (day + 0.5),
        box.top +
            TimetableGrid.headerHeight +
            TimetableGrid.topInset +
            TimetableGrid.rowHeight * (slot + 0.5),
      );
    }

    testWidgets('左键点击画一格，右键擦除，中键切换画笔', (tester) async {
      final (controller, _) = await pumpGrid(tester);
      final start = cellCenter(tester, 0, 36);

      var gesture = await tester.startGesture(start);
      await gesture.up();
      await tester.pump();
      expect(controller.brush, TimetableState.occupied);
      expect(
        controller.draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
        TimetableState.occupied,
      );

      gesture = await tester.startGesture(start, buttons: kSecondaryMouseButton);
      await gesture.up();
      await tester.pump();
      expect(
        controller.draft.timetable.day('2026-10-19', 1).stateOfSlot(36),
        TimetableState.free,
        reason: '右键只擦除目标格',
      );

      gesture = await tester.startGesture(start, buttons: kMiddleMouseButton);
      await gesture.up();
      await tester.pump();
      expect(controller.brush, TimetableState.task);
    });

    testWidgets('拖动连续绘制并可用 Ctrl+Z 整笔撤销', (tester) async {
      final (controller, _) = await pumpGrid(tester);
      final from = cellCenter(tester, 0, 36);
      final to = cellCenter(tester, 0, 39);
      final gesture = await tester.startGesture(from);
      await gesture.moveTo(to);
      await gesture.up();
      await tester.pump();
      for (var slot = 36; slot <= 39; slot++) {
        expect(
          controller.draft.timetable.day('2026-10-19', 1).stateOfSlot(slot),
          TimetableState.occupied,
          reason: '拖动经过的格子应连续补齐',
        );
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      for (var slot = 36; slot <= 39; slot++) {
        expect(
          controller.draft.timetable.day('2026-10-19', 1).stateOfSlot(slot),
          TimetableState.free,
          reason: '一次拖动应作为一笔完整撤销',
        );
      }
    });
    testWidgets('滚动到底部时 24:00 标签与最后一格完整可用', (tester) async {
      final (controller, _) = await pumpGrid(tester);
      final scrollable = find
          .descendant(
            of: find.byType(TimetableGrid),
            matching: find.byType(Scrollable),
          )
          .first;
      final state = tester.state<ScrollableState>(scrollable);
      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pump();

      final gridRect = tester.getRect(find.byType(TimetableGrid));
      final statusTop =
          tester.getRect(find.byKey(const Key('timetable-hover'))).top - 5;
      final label = tester.getRect(find.text('24:00'));
      expect(label.top, greaterThanOrEqualTo(gridRect.top + TimetableGrid.headerHeight),
          reason: '00:00/24:00 标签不能被表头裁切');
      expect(label.bottom, lessThanOrEqualTo(statusTop),
          reason: '24:00 不能被底部状态条裁切');

      // 最后一格（周日 23:45–24:00）完整可点、可擦。
      final box = tester.getRect(find.byType(TimetableGrid));
      final gridWidth = box.width -
          TimetableGrid.timeAxisWidth -
          TimetableGrid.scrollbarGutter;
      final dayWidth = gridWidth / 7;
      final lastSlotPoint = Offset(
        box.left + TimetableGrid.timeAxisWidth + dayWidth * 6.5,
        statusTop - 20,
      );
      await tester.tapAt(lastSlotPoint);
      await tester.pump();
      expect(
        controller.draft.timetable
            .stateAt('2026-10-25', 7, 23 * 60 + 45),
        TimetableState.occupied,
      );
      final lastGesture = await tester.startGesture(lastSlotPoint,
          buttons: kSecondaryMouseButton);
      await lastGesture.up();
      await tester.pump();
      expect(
        controller.draft.timetable
            .stateAt('2026-10-25', 7, 23 * 60 + 45),
        TimetableState.free,
      );
    });

    testWidgets('点击时间轴、表头、状态条不修改任何时间数据', (tester) async {
      final (controller, _) = await pumpGrid(tester);
      expect(controller.draft.timetable.dates, isEmpty);
      final box = tester.getRect(find.byType(TimetableGrid));
      await tester.tapAt(Offset(box.left + 20, box.top + 200));
      await tester.tapAt(Offset(box.left + 300, box.top + 10));
      await tester.tapAt(Offset(box.left + 300, box.bottom - 10));
      await tester.pump();
      expect(controller.draft.timetable.dates, isEmpty,
          reason: '时间轴/表头/状态条不是网格，不能画格');
    });
  });

  group('有效时间表派生与网格几何', () {
    test('09:00–10:00 占用中 09:15–09:30 恢复可用，精确分钟保留', () {
      final base = Timetable.withDefaults(
        weekStart: '2026-10-20',
        unavailable: const <WallClockRange>[],
      );
      final withOccupied = base.paint(
        date: '2026-10-20',
        start: 540,
        end: 600,
        state: TimetableState.occupied,
      );
      final withFree = withOccupied.paint(
        date: '2026-10-20',
        start: 555,
        end: 570,
        state: TimetableState.free,
      );
      final snapshot = withFree.copyWith(
        revision: 4,
        dateFrom: '2026-10-20',
        dateTo: '2026-10-20',
      );
      final effective = deriveEffectiveTimetable(snapshot);
      expect(effective['sourceRevision'], 4);
      expect(effective['timezoneId'], snapshot.timezoneId);
      final day = (effective['days'] as List<dynamic>).single
          as Map<String, dynamic>;
      expect(day['date'], '2026-10-20');
      final intervals = (day['intervals'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((i) => <Object?>[i['start'], i['end'], i['state']])
          .toList();
      expect(intervals, <List<Object?>>[
        <Object?>[0, 540, 1],
        <Object?>[540, 555, 0],
        <Object?>[555, 570, 1],
        <Object?>[570, 600, 0],
        <Object?>[600, 1440, 1],
      ]);
    });

    test('状态 0 不被 truthy 过滤，区间连续覆盖 0–1440', () {
      final snapshot = Timetable.withDefaults(weekStart: '2026-10-19')
          .copyWith(dateFrom: '2026-10-19', dateTo: '2026-10-19');
      final effective = deriveEffectiveTimetable(snapshot);
      final day = (effective['days'] as List<dynamic>).single
          as Map<String, dynamic>;
      final intervals = (day['intervals'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      var cursor = 0;
      for (final interval in intervals) {
        expect(interval['start'], cursor);
        cursor = interval['end'] as int;
      }
      expect(cursor, 1440);
      expect(
        intervals.any((i) => i['state'] == 0),
        isTrue,
        reason: '默认占用必须作为 state=0 发送',
      );
    });

    test('重叠 / 反向范围 / 覆盖过大都明确失败，不静默缩小', () {
      const overlapping = Timetable(
        dateFrom: '2026-10-19',
        dateTo: '2026-10-19',
        weekly: <TimetableEntry>[
          TimetableEntry(
            id: 'a',
            state: TimetableState.occupied,
            start: 0,
            end: 600,
            weekdays: <int>[1],
          ),
          TimetableEntry(
            id: 'b',
            state: TimetableState.free,
            start: 500,
            end: 700,
            weekdays: <int>[1],
          ),
        ],
      );
      expect(
        () => deriveEffectiveTimetable(overlapping),
        throwsA(isA<TimetableRequestException>()),
      );
      const reversed = Timetable(
        dateFrom: '2026-10-20',
        dateTo: '2026-10-19',
      );
      expect(
        () => deriveEffectiveTimetable(reversed),
        throwsA(isA<TimetableRequestException>()),
      );
      const tooLong = Timetable(
        dateFrom: '2026-01-01',
        dateTo: '2027-06-01',
      );
      expect(
        () => deriveEffectiveTimetable(tooLong),
        throwsA(isA<TimetableRequestException>()),
      );
    });

    test('网格映射扣时间轴并加滚动偏移，08:00 之后的拖动不写回 00:00', () {
      const geometry = TimetableGridGeometry(
        gridWidth: 700,
        viewportHeight: 400,
        scrollOffset: 480,
      );
      // 08:00 的格线在滚动内容 y=10+480=490；视口内 y=18 处应为 slot 30。
      final cell =
          geometry.hit(const Offset(TimetableGrid.timeAxisWidth + 50, 18));
      expect(cell, isNotNull);
      expect(cell!.day, 0);
      expect(cell.slot, 30);
      // 时间轴本身不是网格。
      expect(geometry.hit(const Offset(10, 18)), isNull);
    });

    test('DDA 补齐真实经过的格子：快速拖动、跨列斜线都不漏也不填矩形', () {
      final vertical = crossedGridCells(const Offset(0.5, 1.0), const Offset(0.5, 60.0));
      expect(vertical.length, 60, reason: '一次跨 59 格也必须全部补齐');
      expect(vertical.first.slot, 1);
      expect(vertical.last.slot, 60);

      final diagonal = crossedGridCells(const Offset(0.5, 10.2), const Offset(2.7, 40.6));
      expect(diagonal.toSet().length, diagonal.length, reason: '同一笔不应重复同格');
      expect(diagonal.length, lessThan(3 * 31), reason: '只画经过的格，不填包围矩形');
      expect(diagonal.first.day, 0);
      expect(diagonal.last.day, 2);
    });
  });
}
