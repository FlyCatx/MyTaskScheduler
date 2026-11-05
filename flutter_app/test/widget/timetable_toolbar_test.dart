// 任务 01：时间表编辑器的标题/工具区重排与纯色蓝块。
//
// 覆盖：
//   * 标题与关闭独占标题行，绘制动作回到“画笔 + 编辑动作”工具区；
//   * 宽窗工具区一行、同高、中心线对齐，禁用态/Tooltip/回调都在；
//   * 窄窗按组换行；更窄时次要动作（必要时连撤销/重做）收进“更多操作”菜单，
//     菜单项保留禁用态与原 key；
//   * 大字号（1.5 倍）不溢出、不靠缩小字号；
//   * 工具栏占高后 08:00 附近仍能真实滚动并拖画；
//   * 蓝块内部是不透明纯色：已绑定/未绑定两种实色，块内不被网格线/白斜线贯穿，
//     未绑定仍有左侧形状标记（不靠颜色深浅单独区分）。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      planningDays: 7,
      weekly: WeeklyAvailability({
        1: [WallClockRange(480, 720)],
        2: [WallClockRange(480, 720)],
      }),
    );

CalendarSettingsResult? lastResult;

Future<void> _open(
  WidgetTester tester, {
  Size size = const Size(1300, 1000),
  double textScale = 1.0,
  Timetable? timetable,
  CalendarSettings? settings,
}) async {
  lastResult = null;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              lastResult = await showCalendarSettingsDialog(
                context,
                settings: settings ?? _settings(),
                now: DateTime.utc(2026, 10, 19, 2),
                timetable: timetable ??
                    Timetable.withDefaults(weekStart: '2026-10-19'),
                weekStartsOn: 1,
                initialMode: CalendarEditorMode.drawing,
                defaultUnavailableRanges: UnavailableRange.defaults,
                taskNames: const <String, String>{'T1': '写报告'},
                taskEstimatedHours: const <String, double?>{'T1': 2.0},
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

ScrollableState _gridScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(
      of: find.byType(TimetableGrid),
      matching: find.byType(Scrollable),
    ));

/// 网格视口内某天某 15 分钟格的全局坐标（自动扣除真实滚动偏移）。
Offset _cellCenter(WidgetTester tester, int day, int slot) {
  final box = tester.getRect(find.byType(TimetableGrid));
  final gridWidth = box.width -
      TimetableGrid.timeAxisWidth -
      TimetableGrid.scrollbarGutter;
  final dayWidth = gridWidth / 7;
  final offset = _gridScrollable(tester).position.pixels;
  return Offset(
    box.left + TimetableGrid.timeAxisWidth + dayWidth * (day + 0.5),
    box.top +
        TimetableGrid.headerHeight +
        TimetableGrid.topInset +
        TimetableGrid.rowHeight * (slot + 0.5) -
        offset,
  );
}

double _centerY(WidgetTester tester, Finder finder) =>
    tester.getRect(finder).center.dy;

void _expectNoOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull, reason: '布局不得溢出');
}

void main() {
  testWidgets('宽窗：标题独占标题行，绘制动作回到工具区并与画笔同高同中心线', (tester) async {
    await _open(tester);

    // 标题/关闭独占稳定位置。
    final titleRow = find.byKey(const Key('timetable-title-row'));
    expect(titleRow, findsOneWidget);
    expect(
      find.descendant(of: titleRow, matching: find.text('可用时间与占用时间')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: titleRow, matching: find.byKey(const Key('timetable-close'))),
      findsOneWidget,
    );
    // 标题行里不再有绘制动作。
    for (final key in const <String>[
      'timetable-undo',
      'timetable-redo',
      'timetable-clear-week',
      'timetable-copy-to',
      'timetable-range-toggle',
    ]) {
      expect(
        find.descendant(of: titleRow, matching: find.byKey(Key(key))),
        findsNothing,
        reason: '$key 不应再占用标题行',
      );
    }

    // 画笔与编辑动作全部在同一个工具区。
    final toolbar = find.byKey(const Key('timetable-toolbar'));
    expect(toolbar, findsOneWidget);
    for (final key in const <String>[
      'timetable-brush',
      'timetable-undo',
      'timetable-redo',
      'timetable-clear-week',
      'timetable-select-blocks',
      'timetable-copy-to',
      'timetable-range-toggle',
    ]) {
      expect(
        find.descendant(of: toolbar, matching: find.byKey(Key(key))),
        findsOneWidget,
        reason: '$key 必须在编辑工具区',
      );
    }
    _expectNoOverflow(tester);

    // 宽窗一行：所有控件中心线一致（同一组高度/间距）。
    final brushY = _centerY(tester, find.byKey(const Key('timetable-brush')));
    for (final key in const <String>[
      'timetable-undo',
      'timetable-redo',
      'timetable-clear-week',
      'timetable-select-blocks',
      'timetable-copy-to',
      'timetable-range-toggle',
    ]) {
      expect(_centerY(tester, find.byKey(Key(key))), closeTo(brushY, 1.5),
          reason: '$key 与画笔选择必须对齐中心线');
    }
    // 控制高度统一（30），工具行 38 由画笔外框决定。
    expect(tester.getRect(find.byKey(const Key('timetable-undo'))).height, 30);
    expect(tester.getRect(find.byKey(const Key('timetable-range-toggle'))).height,
        30);
    expect(tester.getRect(toolbar).height,
        closeTo(CalendarToolbarMetrics.rowHeight, 0.5));
    // Tooltip 保留。
    expect(find.byTooltip('清空本周手工绘制（可撤销）'), findsOneWidget);
    // 禁用态保留（初始没有可撤销操作）。
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('timetable-undo')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('窄窗：工具区按“画笔/历史/编辑动作”整组换行，动作仍可点', (tester) async {
    // 760 逻辑宽：对话框内可用宽度不足以一行放下三组，但足够放下编辑动作组。
    await _open(tester, size: const Size(760, 760));
    _expectNoOverflow(tester);
    final toolbar = find.byKey(const Key('timetable-toolbar'));
    expect(toolbar, findsOneWidget);
    expect(
      tester.getRect(toolbar).height,
      greaterThan(CalendarToolbarMetrics.rowHeight + 2),
      reason: '空间不足时应整组换行而不是压缩控件',
    );
    // 不靠缩小字号：按钮文字仍是 11，工具行高不变。
    expect(tester.getRect(find.byKey(const Key('timetable-undo'))).height, 30);
    expect(find.byKey(const Key('timetable-clear-week')), findsOneWidget);

    // 换行后仍可操作：选择蓝块 → 出现选择栏；跨日时段 → 出现面板。
    await tester.tap(find.byKey(const Key('timetable-select-blocks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-selection-bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-select-blocks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-range-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-range-panel')), findsOneWidget);
    _expectNoOverflow(tester);
  });

  testWidgets('更窄：次要动作收进“更多操作”，菜单项保留 key/禁用态/回调', (tester) async {
    await _open(tester, size: const Size(700, 760));
    _expectNoOverflow(tester);
    expect(find.byKey(const Key('timetable-more-actions')), findsOneWidget);
    // 收纳后内联的次要动作不再占位（菜单位于 Popup 里，打开后才构建）。
    expect(find.byKey(const Key('timetable-clear-week')), findsNothing);
    expect(find.byKey(const Key('timetable-undo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-more-actions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-clear-week')), findsOneWidget);
    expect(find.byKey(const Key('timetable-select-blocks')), findsOneWidget);
    expect(find.byKey(const Key('timetable-copy-to')), findsOneWidget);
    expect(find.byKey(const Key('timetable-range-toggle')), findsOneWidget);

    // 通过菜单仍能开启跨日时段（回调保留）。
    await tester.tap(find.byKey(const Key('timetable-range-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-range-panel')), findsOneWidget);
    _expectNoOverflow(tester);
  });

  testWidgets('极窄：撤销/重做也进菜单且保持禁用态', (tester) async {
    // 500 逻辑宽：内容宽度 < 420，撤销/重做一起收纳。
    await _open(tester, size: const Size(500, 900));
    _expectNoOverflow(tester);
    expect(find.byKey(const Key('timetable-undo')), findsNothing);
    await tester.tap(find.byKey(const Key('timetable-more-actions')));
    await tester.pumpAndSettle();
    final undo = tester
        .widget<PopupMenuItem<String>>(find.byKey(const Key('timetable-more-undo')));
    expect(undo.enabled, isFalse, reason: '没有可撤销操作时菜单项也要禁用');
    final redo = tester
        .widget<PopupMenuItem<String>>(find.byKey(const Key('timetable-more-redo')));
    expect(redo.enabled, isFalse);
    _expectNoOverflow(tester);
  });

  testWidgets('系统字号 1.5 倍：工具区不溢出，动作与底部保存按钮可达', (tester) async {
    await _open(tester, size: const Size(1280, 720), textScale: 1.5);
    _expectNoOverflow(tester);
    expect(find.byKey(const Key('timetable-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('timetable-undo')), findsOneWidget);
    expect(find.byKey(const Key('calendar-settings-save')), findsOneWidget);
    expect(find.byKey(const Key('calendar-settings-cancel')), findsOneWidget);
    expect(find.byKey(const Key('timetable-close')), findsOneWidget);
    // 没有靠缩小字号：按钮文字仍按 1.5 倍系统字号渲染（没有被 FittedBox 压扁）。
    final undoLabel = find.descendant(
      of: find.byKey(const Key('timetable-undo')),
      matching: find.text('撤销'),
    );
    expect(undoLabel, findsOneWidget);
    expect(
      MediaQuery.textScalerOf(tester.element(undoLabel)).scale(11),
      closeTo(16.5, 0.01),
    );
    expect(tester.getSize(undoLabel).height, greaterThan(16));
    expect(
      find.descendant(
        of: find.byKey(const Key('timetable-toolbar')),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
      reason: '工具区不能用 FittedBox 缩字蒙混',
    );
  });

  testWidgets('工具栏占高后 08:00 附近仍可滚动并拖画', (tester) async {
    await _open(tester, size: const Size(1280, 720));
    final scrollable = _gridScrollable(tester);
    expect(scrollable.position.maxScrollExtent, greaterThan(200),
        reason: '网格必须可滚动');
    // 滚到 08:00 落在视口中部：工具栏占高后它本来不在首屏。
    scrollable.position.jumpTo(430);
    await tester.pumpAndSettle();
    _expectNoOverflow(tester);

    // 用“任务”画笔在 08:00 处真实拖出一格。
    await tester.tap(find.text('任务').first);
    await tester.pump();
    final gesture = await tester.startGesture(_cellCenter(tester, 0, 32));
    await gesture.up();
    await tester.pump();

    await tester.tap(find.byKey(const Key('calendar-settings-save')));
    await tester.pumpAndSettle();
    final entry = lastResult!.timetable!.dates.firstWhere(
      (e) => e.date == '2026-10-19' && e.start == 8 * 60,
      orElse: () => throw StateError('08:00 的绘制没有写入'),
    );
    expect(entry.end, 8 * 60 + 15);
    expect(entry.state, TimetableState.task);
  });

  testWidgets('跨年长日期 + 窄窗：周标签可换行，标题与工具区不溢出', (tester) async {
    await _open(
      tester,
      size: const Size(760, 760),
      settings: const CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-12-28',
        planningDays: 7,
        weekly: WeeklyAvailability({
          1: [WallClockRange(480, 720)],
          2: [WallClockRange(480, 720)],
        }),
      ),
      timetable: Timetable.withDefaults(weekStart: '2026-12-28'),
    );
    // 跨年周标签比普通周更长：不能把标题/关闭或工具区挤坏。
    expect(find.byKey(const Key('timetable-week-label')), findsOneWidget);
    expect(find.textContaining('2027'), findsWidgets);
    expect(find.byKey(const Key('timetable-title-row')), findsOneWidget);
    expect(find.byKey(const Key('timetable-close')), findsOneWidget);
    expect(find.byKey(const Key('timetable-toolbar')), findsOneWidget);
    _expectNoOverflow(tester);
  });

  testWidgets('覆盖范围警告与底部保存按钮在窄窗仍可达', (tester) async {
    await _open(tester, size: const Size(700, 720));
    await tester.tap(find.byKey(const Key('timetable-next-week')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-outside-coverage')), findsOneWidget);
    expect(find.byKey(const Key('timetable-close')), findsOneWidget);
    expect(find.byKey(const Key('calendar-settings-save')), findsOneWidget);
    _expectNoOverflow(tester);
  });

  testWidgets('蓝块内部是不透明纯色，块内没有网格线/白斜线', (tester) async {
    final timetable = _twoTaskBlocks();
    final controller =
        TimetableGridController(draft: TimetableDraft(timetable));
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TsColors.apply(Brightness.light);
    addTearDown(() => TsColors.apply(Brightness.light));
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const Key('grid-boundary'),
            child: SizedBox(
              width: 1000,
              height: 700,
              child: TimetableGrid(
                key: const Key('grid'),
                controller: controller,
                weekStart: '2026-10-19',
                weekStartsOn: 1,
                weeklyMode: false,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final scrollable = _gridScrollable(tester);
    scrollable.position.jumpTo(200);
    await tester.pumpAndSettle();

    final boundaryRect = tester.getRect(find.byKey(const Key('grid-boundary')));
    final rgba = await _rgbaOf(tester);
    final width = boundaryRect.width.toInt();
    int channel(int x, int y, int c) => rgba[(y * width + x) * 4 + c];
    int argbRed(Color c) => (c.toARGB32() >> 16) & 0xFF;
    int argbGreen(Color c) => (c.toARGB32() >> 8) & 0xFF;
    int argbBlue(Color c) => c.toARGB32() & 0xFF;
    bool isColorAt(int x, int y, Color expected) =>
        channel(x, y, 0) == argbRed(expected) &&
        channel(x, y, 1) == argbGreen(expected) &&
        channel(x, y, 2) == argbBlue(expected);

    final gridTop = tester.getRect(find.byKey(const Key('grid'))).top;
    final contentRowTop =
        gridTop + TimetableGrid.headerHeight;
    final axisLeft =
        tester.getRect(find.byKey(const Key('grid'))).left +
            TimetableGrid.timeAxisWidth;
    final gridWidth = tester.getRect(find.byKey(const Key('grid'))).width -
        TimetableGrid.timeAxisWidth -
        TimetableGrid.scrollbarGutter;
    final dayWidth = gridWidth / 7;
    final scrollOffset = scrollable.position.pixels;
    double screenX(int day, double dxInDay) =>
        axisLeft + dayWidth * day + dxInDay;
    double screenY(int minute) =>
        contentRowTop +
        TimetableGrid.topInset +
        (minute / 60) * 4 * TimetableGrid.rowHeight -
        scrollOffset;

    // 已绑定块：周一 09:00–10:00，内部每个采样点都是同一种实色。
    final bound = TimetableBlockColors.bound;
    for (var minute = 545; minute < 595; minute += 10) {
      for (var dx = 12.0; dx < dayWidth - 12; dx += 12) {
        expect(
          isColorAt(screenX(0, dx).round(), screenY(minute).round(), bound),
          isTrue,
          reason: '已绑定蓝块内部必须是纯色（minute=$minute dx=$dx）',
        );
      }
    }
    // 未绑定块：周二 10:00–12:00，同色系但不透明浅蓝，也没有白色斜线。
    final unbound = TimetableBlockColors.unbound;
    for (var minute = 615; minute < 705; minute += 15) {
      for (var dx = 12.0; dx < dayWidth - 12; dx += 12) {
        expect(
          isColorAt(screenX(1, dx).round(), screenY(minute).round(), unbound),
          isTrue,
          reason: '未绑定蓝块内部必须是纯色（minute=$minute dx=$dx）',
        );
      }
    }
    // 未绑定仍有形状标记：块最左侧 2px 是更深的标记色。
    expect(
      isColorAt(screenX(1, 1).round(), screenY(650).round(),
          TimetableBlockColors.unboundMarker),
      isTrue,
      reason: '未绑定块需要左侧实心标记条，不只靠颜色深浅',
    );
    // 对照：同一天同一时刻、块外（周一 10:30 之后的空白区）不是块色。
    expect(
      isColorAt(screenX(0, dayWidth / 2).round(), screenY(645).round(), bound),
      isFalse,
      reason: '块外不能整列刷成任务蓝',
    );
  });
}

Timetable _twoTaskBlocks() {
  var timetable = Timetable.withDefaults(weekStart: '2026-10-19');
  timetable = timetable.paint(
    date: '2026-10-19',
    start: 9 * 60,
    end: 10 * 60,
    state: TimetableState.task,
    title: '写报告',
    taskId: 'T1',
    reservationId: 'res-1',
  );
  timetable = timetable.paint(
    date: '2026-10-20',
    start: 10 * 60,
    end: 12 * 60,
    state: TimetableState.task,
    title: '任务预留',
    reservationId: 'res-unbound-1',
  );
  return timetable;
}

Future<Uint8List> _rgbaOf(WidgetTester tester) async {
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(const Key('grid-boundary')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}
