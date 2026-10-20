// “手动填写 / 手动绘制”共享草稿的界面回归测试。
//
// 目标：两种编辑方式在同一对话框内切换时不丢修改；绘制结果随保存返回结构化
// 时间表；应用按钮提交但不关闭窗口。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_grid.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

CalendarSettings _settings() => const CalendarSettings(
      timezoneOffsetMinutes: 480,
      planningStartDate: '2026-10-19',
      planningDays: 14,
      weekly: WeeklyAvailability({
        1: [WallClockRange(480, 720)],
        2: [WallClockRange(480, 720)],
      }),
    );

CalendarSettingsResult? lastResult;

Future<void> _open(
  WidgetTester tester, {
  CalendarEditorMode mode = CalendarEditorMode.drawing,
  Future<bool> Function(CalendarSettingsResult result)? onApply,
}) async {
  lastResult = null;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1300, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1300, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              lastResult = await showCalendarSettingsDialog(
                context,
                settings: _settings(),
                now: DateTime.utc(2026, 10, 19, 2),
                timetable: Timetable.withDefaults(weekStart: '2026-10-19'),
                weekStartsOn: 1,
                initialMode: mode,
                defaultUnavailableRanges: UnavailableRange.defaults,
                taskNames: const <String, String>{'T1': '写报告'},
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

Offset _cellCenter(WidgetTester tester, int day, int slot) {
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

void main() {
  testWidgets('绘制模式显示 7×96 网格，拖动后保存返回日期规则', (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);
    expect(find.byKey(const Key('timetable-week-label')), findsOneWidget);

    // 切到“任务”画笔，在可见区域内画 05:00–06:00。
    await tester.tap(find.text('任务').first);
    await tester.pump();
    final from = _cellCenter(tester, 0, 20);
    final to = _cellCenter(tester, 0, 23);
    final gesture = await tester.startGesture(from);
    await gesture.moveTo(to);
    await gesture.up();
    await tester.pump();

    await tester.tap(find.byKey(const Key('calendar-settings-save')));
    await tester.pumpAndSettle();
    final result = lastResult!;
    expect(result.timetable, isNotNull);
    final entry = result.timetable!.dates.firstWhere(
        (e) => e.date == '2026-10-19' && e.start == 5 * 60);
    expect(entry.end, 6 * 60);
    expect(entry.state, TimetableState.task);
  });

  testWidgets('填写 ↔ 绘制切换不丢草稿，画过的日期规则仍在', (tester) async {
    await _open(tester);
    await tester.tap(find.text('任务').first);
    await tester.pump();
    final gesture = await tester.startGesture(_cellCenter(tester, 1, 20));
    await gesture.up();
    await tester.pump();

    // 切到填写：出现每周可用时间与合计。
    await tester.tap(find.text('手动填写'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-weekday-1')), findsOneWidget);

    // 再切回绘制：网格还在，05:00 的绘制仍在。
    await tester.tap(find.text('手动绘制'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-settings-save')));
    await tester.pumpAndSettle();
    final entry = lastResult!.timetable!.dates
        .firstWhere((e) => e.date == '2026-10-20' && e.start == 5 * 60);
    expect(entry.end, 5 * 60 + 15);
  });

  testWidgets('绘制弹窗接近可用客户区的 93% 宽 / 88–90% 高', (tester) async {
    await _open(tester);
    final dialog = tester.getRect(find.byType(Dialog));
    // Dialog 是整屏容器；真正的内容盒子是里面的 AnimatedContainer。
    final frame = tester.getRect(find.byType(AnimatedContainer));
    expect(frame.width / 1300, greaterThanOrEqualTo(0.92));
    expect(frame.width / 1300, lessThanOrEqualTo(0.94));
    expect(frame.height / 900, greaterThanOrEqualTo(0.88));
    expect(frame.height / 900, lessThanOrEqualTo(0.91));
    expect(dialog.width, 1300);
    // 标题、工具栏、表头、状态条与底部按钮都在窗口内。
    expect(find.text('可用时间与占用时间'), findsOneWidget);
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);
    expect(find.byKey(const Key('calendar-settings-save')), findsOneWidget);
  });

  testWidgets('填写 ↔ 绘制使用淡入/位移动画，过渡中没有两份可交互表单', (tester) async {
    await _open(tester);
    final modeSwitcher = find.byWidgetPredicate((w) =>
        w is AnimatedSwitcher && w.duration == const Duration(milliseconds: 200));
    expect(modeSwitcher, findsOneWidget);
    final switcher = tester.widget<AnimatedSwitcher>(modeSwitcher);
    expect(switcher.duration, const Duration(milliseconds: 200));

    await tester.tap(find.text('手动填写'));
    await tester.pump();
    // 过渡中：新旧两棵子树同时存在（淡入 + 轻微位移），但旧树被 IgnorePointer。
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);
    expect(find.byKey(const Key('calendar-weekday-1')), findsOneWidget);
    final ignoring = tester
        .widgetList<IgnorePointer>(find.byType(IgnorePointer))
        .where((w) => w.ignoring)
        .length;
    expect(ignoring, greaterThan(0), reason: '正在淡出的旧表单不能接收指针');

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-grid')), findsNothing);
    expect(find.byKey(const Key('calendar-weekday-1')), findsOneWidget);
  });

  testWidgets('1280×720、文字 1.5 倍时弹窗与工具栏不溢出', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TsColors.apply(Brightness.light);
    addTearDown(() => TsColors.apply(Brightness.light));
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.5)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showCalendarSettingsDialog(
                context,
                settings: _settings(),
                now: DateTime.utc(2026, 10, 19, 2),
                timetable: Timetable.withDefaults(weekStart: '2026-10-19'),
                weekStartsOn: 1,
                initialMode: CalendarEditorMode.drawing,
                defaultUnavailableRanges: UnavailableRange.defaults,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '小窗口 + 1.5 倍文字不能溢出');
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);
    expect(find.byKey(const Key('calendar-settings-save')), findsOneWidget);
  });

  testWidgets('应用提交但不关闭窗口；提交失败保留草稿', (tester) async {
    var calls = 0;
    await _open(tester, onApply: (result) async {
      calls++;
      return calls == 1;
    });
    final before = find.byKey(const Key('timetable-grid'));
    expect(before, findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-settings-apply')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget,
        reason: '应用后窗口保持打开');
    expect(find.textContaining('已应用'), findsOneWidget);

    // 第二次提交失败：必须留在窗口并显示错误，不能假装成功。
    await tester.tap(find.byKey(const Key('calendar-settings-apply')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byKey(const Key('timetable-grid')), findsOneWidget);
    expect(find.textContaining('提交失败'), findsOneWidget);
  });
}
