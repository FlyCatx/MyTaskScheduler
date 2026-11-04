// 2026-11-03 审查 F2/F3/F4/F5/F6 的正式回归测试。
//
// 这些用例按“用户可观察结果”断言：保存后的时间表事实、flush 的完成时机、
// 截止时间的真实瞬间、网格可见边界、本周实际容量。不是只检查控件存在。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_grid.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import 'support/test_support.dart';

CalendarSettings _fillSettings() => const CalendarSettings(
      timezoneOffsetMinutes: 480,
      planningStartDate: '2026-10-19',
      planningDays: 14,
      weekly: WeeklyAvailability({
        1: [WallClockRange(540, 720)], // 周一 09:00-12:00
        2: [WallClockRange(540, 720)],
      }),
    );

Timetable _fillTimetable(CalendarSettings settings) =>
    Timetable.fromSchedule(
      CalendarSchedule(settings: settings),
      weekStart: settings.planningStartDate,
    ).copyWith(
      dateFrom: settings.planningStartDate,
      dateTo: addDaysToDateKey(
          settings.planningStartDate, settings.planningDays - 1),
    );

CalendarSettingsResult? _lastResult;

Future<void> _openFillDialog(WidgetTester tester,
    {Future<bool> Function(CalendarSettingsResult)? onApply}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1300, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1300, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  final settings = _fillSettings();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              _lastResult = await showCalendarSettingsDialog(
                context,
                settings: settings,
                now: DateTime.utc(2026, 10, 19, 2),
                timetable: _fillTimetable(settings),
                weekStartsOn: 1,
                initialMode: CalendarEditorMode.fill,
                onApply: onApply,
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  group('F2 手动填写同步到权威时间表', () {
    testWidgets('填写周一 10:00–11:00 后直接保存，09:00 不再可用', (tester) async {
      _lastResult = null;
      await _openFillDialog(tester);
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-1')), '10:00-11:00');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();

      final result = _lastResult;
      expect(result, isNotNull);
      expect(result!.settings.weekly.forWeekday(1).first.startMinute, 600);
      expect(result.settings.weekly.forWeekday(1).first.endMinute, 660);
      // 真正提交的时间表也必须是新值：09:30 占用、10:30 可用。
      expect(
        result.timetable!.stateAt('2026-10-19', 1, 9 * 60 + 30),
        TimetableState.occupied,
        reason: '表单修改后的时间表不能被旧 _draft.timetable 覆盖',
      );
      expect(
        result.timetable!.stateAt('2026-10-19', 1, 10 * 60 + 30),
        TimetableState.free,
      );
      // 规划范围保持 14 天，不被缩成可见的一周。
      expect(result.timetable!.dateFrom, '2026-10-19');
      expect(result.timetable!.dateTo, '2026-11-01');
    });

    testWidgets('同日已有绘制块与表单日期例外同时保存，两边都不丢', (tester) async {
      // 预置一条周二的绘制任务块，然后在表单里给同一天加一条日期例外。
      final settings = _fillSettings();
      final drawn = _fillTimetable(settings).paint(
        date: '2026-10-20',
        start: 720,
        end: 780,
        state: TimetableState.task,
        taskId: 'T1',
        reservationId: 'r1',
        title: '任务预留',
      );
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1300, 900);
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.light);
      addTearDown(() => TsColors.apply(Brightness.light));
      CalendarSettingsResult? result;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showCalendarSettingsDialog(
                    context,
                    settings: settings,
                    now: DateTime.utc(2026, 10, 19, 2),
                    timetable: drawn,
                    weekStartsOn: 1,
                    initialMode: CalendarEditorMode.fill,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
          find.byKey(const Key('calendar-add-exception')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-add-exception')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('calendar-exception-date-0')), '2026-10-20');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();

      final merged = result!.timetable!;
      expect(merged.stateAt('2026-10-20', 2, 12 * 60 + 30),
          TimetableState.task,
          reason: '已绘制任务块必须保留');
      final entries = merged.dates.where((e) => e.date == '2026-10-20');
      expect(entries.any((e) => e.state == TimetableState.occupied), isTrue,
          reason: '表单新增的日期例外也必须保留');
    });

    testWidgets('取消/关闭有未保存改动时先确认，不静默丢弃', (tester) async {
      _lastResult = null;
      await _openFillDialog(tester);
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-1')), '10:00-11:00');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的时间表修改？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-discard-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-settings-cancel')), findsOneWidget,
          reason: '继续编辑时不能关闭弹窗');

      await tester.tap(find.byKey(const Key('calendar-settings-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-discard-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-settings-cancel')), findsNothing);
      expect(_lastResult, isNull, reason: '取消不能产生提交结果');
    });

    testWidgets('应用成功后关闭不再提示丢弃', (tester) async {
      await _openFillDialog(tester, onApply: (result) async => true);
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-1')), '10:00-11:00');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-apply')));
      await tester.pumpAndSettle();
      expect(find.text('已应用'), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-settings-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的时间表修改？'), findsNothing,
          reason: '刚应用成功的数据已是已保存基线');
      expect(find.byKey(const Key('calendar-settings-cancel')), findsNothing);
    });

    testWidgets('填写保存经控制器提交后，重新打开仍是同一份新时间表', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1300, 900);
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.light);
      addTearDown(() => TsColors.apply(Brightness.light));

      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          AppController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      addTearDown(controller.dispose);
      await controller.openConversation('conv-seed');
      final settings = _fillSettings();

      CalendarSettingsResult? first;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  first = await showCalendarSettingsDialog(
                    context,
                    settings: settings,
                    now: DateTime.utc(2026, 10, 19, 2),
                    timetable: controller.currentTimetable(),
                    weekStartsOn: 1,
                    initialMode: CalendarEditorMode.fill,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-1')), '10:00-11:00');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(first, isNotNull);
      expect(
        await controller.applyTimetableSettings(
            first!.settings, first!.timetable!,
            reschedule: false),
        isTrue,
      );
      expect(
          controller.currentTimetable().stateAt('2026-10-19', 1, 9 * 60 + 30),
          TimetableState.occupied);

      CalendarSettingsResult? reopened;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  reopened = await showCalendarSettingsDialog(
                    context,
                    settings: controller.calendar.settings,
                    now: DateTime.utc(2026, 10, 19, 2),
                    timetable: controller.currentTimetable(),
                    weekStartsOn: 1,
                    initialMode: CalendarEditorMode.fill,
                  );
                },
                child: const Text('重新打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('重新打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(reopened!.timetable!.stateAt('2026-10-19', 1, 9 * 60 + 30),
          TimetableState.occupied,
          reason: '重新打开时不能回退到保存前的旧时间表');
    });
  });

  group('F3 关闭 flush 等待进行中的写入', () {
    test('正在写入时再次 flush 必须等待同一个保存完成', () async {
      final store = _BlockingStore();
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: store,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      await controller.ensureConversation();

      store.block = true;
      store.gate = Completer<void>();
      final first = controller.updateDraft('未保存的草稿');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      var secondDone = false;
      final second = controller.flushPendingWrites().then((value) {
        secondDone = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(secondDone, isFalse,
          reason: '第一次写入未完成时，第二次 flush 不能提前返回');

      store.gate!.complete();
      store.block = false;
      await first;
      expect(await second, isTrue);
      expect(secondDone, isTrue);
    });

    test('写入失败返回 false 并保留 dirty，恢复后可重试成功', () async {
      final store = _BlockingStore();
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: store,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      await controller.ensureConversation();

      store.failNext = true;
      final writing = controller.updateDraft('失败草稿');
      // 第二次调用共享同一个进行中的 flush，得到明确的 false。
      expect(await controller.flushPendingWrites(), isFalse);
      await writing;
      expect(controller.errorMessage, contains('草稿未能写入'));

      store.failNext = false;
      expect(await controller.flushPendingWrites(), isTrue);
    });
  });

  group('F4 截止时间解析', () {
    const offset = 480; // Asia/Shanghai
    final now = DateTime.utc(2026, 11, 3, 2); // 北京时间 10:00

    test('上午 10 点输入 18:00 仍是当天 18:00', () {
      final parsed = parseDeadlineText('18:00',
          now: now, offsetMinutes: offset);
      expect(parsed.at, DateTime.utc(2026, 11, 3, 10));
      expect(parsed.problem, isNull);
    });

    test('晚于输入时刻时推断为次日，并标记 inferred', () {
      final parsed = parseDeadlineText('18:00',
          now: DateTime.utc(2026, 11, 3, 11), // 北京 19:00
          offsetMinutes: offset);
      expect(parsed.at, DateTime.utc(2026, 11, 4, 10));
      expect(parsed.inferred, isTrue);
    });

    test('带 Z / +08:00 的 ISO 保留原时区', () {
      expect(
        parseDeadlineText('2026-11-03T18:00:00Z',
                now: now, offsetMinutes: offset)
            .at,
        DateTime.utc(2026, 11, 3, 18),
      );
      expect(
        parseDeadlineText('2026-11-03T18:00:00+08:00',
                now: now, offsetMinutes: offset)
            .at,
        DateTime.utc(2026, 11, 3, 10),
      );
    });

    test('非法日期拒绝，闰日接受', () {
      final bad = parseDeadlineText('2026-02-30',
          now: now, offsetMinutes: offset);
      expect(bad.at, isNull);
      expect(bad.problem, isNotNull);
      final leap = parseDeadlineText('2024-02-29',
          now: now, offsetMinutes: offset);
      expect(leap.at, isNotNull);
      expect(leap.problem, isNull);
    });
  });

  group('F5 网格可见视口边界', () {
    test('viewportHeight=300、offset=400、y=330 不命中', () {
      const geometry = TimetableGridGeometry(
        gridWidth: 700,
        viewportHeight: 300,
        scrollOffset: 400,
      );
      expect(geometry.hit(const Offset(54 + 50, 330)), isNull,
          reason: '视口外的点不能写进隐藏时段');
      expect(geometry.hit(const Offset(54 + 50, -1)), isNull);
      expect(geometry.hit(const Offset(54 + 50, 290)), isNotNull);
      // 时间轴/沟槽仍不在网格内。
      expect(geometry.hit(const Offset(10, 100)), isNull);
      expect(geometry.hit(const Offset(54 + 700 + 1, 100)), isNull);
    });
  });

  group('F6 本周实际容量', () {
    test('模板 84 小时；本周一 09:00–10:00 占用后本周 83 小时', () {
      final timetable = Timetable.withDefaults(weekStart: '2026-10-19');
      expect(timetable.freeMinutesPerWeek, 5040);
      final withOccupied = timetable.paint(
        date: '2026-10-19',
        start: 540,
        end: 600,
        state: TimetableState.occupied,
      );
      expect(withOccupied.freeMinutesInWeek('2026-10-19'), 4980);
      expect(withOccupied.freeMinutesPerWeek, 5040,
          reason: '模板容量不能被具体日期占用改变');
    });
  });

  group('F8 导航与覆盖范围', () {
    testWidgets('切换周不缩 coverage，也不清空未提交笔画的撤销历史', (tester) async {
      final settings = const CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
        planningDays: 14,
        weekly: WeeklyAvailability({
          1: [WallClockRange(480, 720)],
          2: [WallClockRange(480, 720)],
        }),
      );
      final timetable = Timetable.fromSchedule(
        CalendarSchedule(settings: settings),
        weekStart: '2026-10-19',
      ).copyWith(dateFrom: '2026-10-19', dateTo: '2026-11-01');
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1300, 900);
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.light);
      addTearDown(() => TsColors.apply(Brightness.light));
      CalendarSettingsResult? result;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showCalendarSettingsDialog(
                    context,
                    settings: settings,
                    now: DateTime.utc(2026, 10, 19, 2),
                    timetable: timetable,
                    weekStartsOn: 1,
                    initialMode: CalendarEditorMode.drawing,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      Offset cell(int day, int slot) {
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

      // 第一周：画周二 08:00。
      await tester.tap(find.text('任务').first);
      await tester.pump();
      var gesture = await tester.startGesture(cell(1, 32));
      await gesture.up();
      await tester.pump();

      // 浏览下一周，再画第二周周二 08:00。
      await tester.tap(find.byKey(const Key('timetable-next-week')));
      await tester.pumpAndSettle();
      gesture = await tester.startGesture(cell(1, 32));
      await gesture.up();
      await tester.pump();

      // 回到第一周：撤销栈仍在，Ctrl+Z 撤销的是第二周那一笔。
      await tester.tap(find.byKey(const Key('timetable-prev-week')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      final merged = result!.timetable!;
      expect(merged.dateFrom, '2026-10-19');
      expect(merged.dateTo, '2026-11-01', reason: '14 天覆盖不能被缩成一周');
      expect(merged.dates.any((e) => e.date == '2026-10-20'), isTrue,
          reason: '第一周的笔画应保留');
      expect(merged.dates.any((e) => e.date == '2026-10-27'), isFalse,
          reason: '回到第一周后 Ctrl+Z 应撤销第二周的那一笔');
    });

    testWidgets('打开旧数据时 coverage 扩展到包含范围外日期规则，保存不丢', (tester) async {
      final settings = const CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-26',
        planningDays: 7,
        weekly: WeeklyAvailability({
          1: [WallClockRange(480, 720)],
          2: [WallClockRange(480, 720)],
        }),
      );
      // 模拟 0.1.2 的“保存时 coverage = 当前可见周”，但仍有上一周的日期规则。
      final timetable = Timetable.fromSchedule(
        CalendarSchedule(settings: settings),
        weekStart: '2026-10-26',
      )
          .copyWith(dateFrom: '2026-10-26', dateTo: '2026-11-01')
          .paint(
            date: '2026-10-20',
            start: 540,
            end: 600,
            state: TimetableState.occupied,
          );
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1300, 900);
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.light);
      addTearDown(() => TsColors.apply(Brightness.light));
      CalendarSettingsResult? result;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showCalendarSettingsDialog(
                    context,
                    settings: settings,
                    now: DateTime.utc(2026, 10, 26, 2),
                    timetable: timetable,
                    weekStartsOn: 1,
                    initialMode: CalendarEditorMode.drawing,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(result!.timetable!.dateFrom, '2026-10-20',
          reason: '不能因为打开填写/绘制页就把范围外规则丢掉');
      expect(result!.timetable!.dateTo, '2026-11-01');
      expect(result!.timetable!.dates.any((e) => e.date == '2026-10-20'), isTrue);
    });

    testWidgets('修改规划天数后 coverage 按新范围展开', (tester) async {
      _lastResult = null;
      await _openFillDialog(tester);
      await tester.enterText(
          find.byKey(const Key('calendar-planning-days')), '21');
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(_lastResult!.timetable!.dateFrom, '2026-10-19');
      expect(_lastResult!.timetable!.dateTo, '2026-11-08');
    });
  });
}

class _BlockingStore extends InMemorySessionRepository {
  bool block = false;
  bool failNext = false;
  Completer<void>? gate;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    if (failNext) {
      failNext = false;
      throw StateError('模拟磁盘写入失败');
    }
    final pending = gate;
    if (block && pending != null) {
      await pending.future;
    }
    return super.saveConversation(conversation);
  }
}
