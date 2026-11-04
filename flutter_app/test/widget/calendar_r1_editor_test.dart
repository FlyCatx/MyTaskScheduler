// R1 时间表编辑器（绘制页）新增能力的界面回归测试：
//   * 跨日时段：显式模式 + 起止日期时间输入、完整日期/总时长/自然日拆分预览、
//     一次提交一笔事务、范围外明确报错不截断、起止校验；
//   * “复制到…”入口：打开对话框、确认后写入目标日期且可撤销；
//   * 蓝块选择与绑定：选择模式、逐块点选、绑定面板三个动作、原子可撤销/重做；
//   * 撤销/重做按钮反映 canUndo/canRedo，应用成功后回到新基线。

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
      planningDays: 7,
      weekly: WeeklyAvailability({
        1: [WallClockRange(480, 720)],
        2: [WallClockRange(480, 720)],
      }),
    );

CalendarSettingsResult? lastResult;

Future<void> _open(
  WidgetTester tester, {
  Future<bool> Function(CalendarSettingsResult result)? onApply,
  Map<String, String> taskNames = const {'T1': '写报告'},
  Map<String, double?> estimatedHours = const {'T1': 2.0},
}) async {
  lastResult = null;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1300, 1100);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1300, 1100));
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
                initialMode: CalendarEditorMode.drawing,
                defaultUnavailableRanges: UnavailableRange.defaults,
                taskNames: taskNames,
                taskEstimatedHours: estimatedHours,
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

TextButton _toolbarButton(WidgetTester tester, String key) =>
    tester.widget<TextButton>(find.byKey(Key(key)));

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

/// 在 day 0 用“任务”画笔拖出 08:00–09:00 的蓝色块（未绑定）。
///
/// 选 08:00 是有意的：默认时间表 [00:00,08:00) 是占用，08:00 之后才是空闲，
/// “复制到目标空闲区间”的策略需要目标日该时刻为 free。
Future<void> _drawTaskBlock(WidgetTester tester) async {
  await tester.tap(find.text('任务').first);
  await tester.pump();
  final gesture = await tester.startGesture(_cellCenter(tester, 0, 32));
  await gesture.moveTo(_cellCenter(tester, 0, 35));
  await gesture.up();
  await tester.pump();
}

Future<CalendarSettingsResult> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('calendar-settings-save')));
  await tester.pumpAndSettle();
  return lastResult!;
}

Future<void> _openRangeMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('timetable-range-toggle')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('timetable-range-panel')), findsOneWidget);
}

/// 画好蓝块后：开选择模式 → 点选该块 → 打开绑定面板。
Future<void> _selectDrawnBlockAndOpenPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('timetable-select-blocks')));
  await tester.pumpAndSettle();
  await tester.tapAt(_cellCenter(tester, 0, 32));
  await tester.pumpAndSettle();
  expect(find.textContaining('已选 1 块'), findsWidgets);
  await tester.tap(find.byKey(const Key('timetable-bind-selection')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('task-binding-panel')), findsOneWidget);
}

/// 绑定当前选中的蓝块（面板默认选中唯一任务 T1）。
Future<void> _bindDrawnBlock(WidgetTester tester) async {
  await _selectDrawnBlockAndOpenPanel(tester);
  await tester.tap(find.byKey(const Key('task-binding-bind')));
  await tester.pumpAndSettle();
}

/// 选择仍有效时重新打开绑定面板（绑定动作不会清空选择）。
Future<void> _reopenBindingPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('timetable-bind-selection')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('task-binding-panel')), findsOneWidget);
}

Future<void> _enterRange(
  WidgetTester tester, {
  required String startDate,
  required String startTime,
  required String endDate,
  required String endTime,
}) async {
  await tester.enterText(
      find.byKey(const Key('timetable-range-start-date')), startDate);
  await tester.enterText(
      find.byKey(const Key('timetable-range-start-time')), startTime);
  await tester.enterText(
      find.byKey(const Key('timetable-range-end-date')), endDate);
  await tester.enterText(
      find.byKey(const Key('timetable-range-end-time')), endTime);
  await tester.pump();
}

void main() {
  testWidgets('初始时撤销/重做按钮禁用，跨日模式本身不修改草稿', (tester) async {
    await _open(tester);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNull);
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNull);

    await _openRangeMode(tester);
    // 打开面板只显示输入与预览，不写入任何东西。
    expect(find.byKey(const Key('timetable-range-preview')), findsOneWidget);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNull);

    final result = await _save(tester);
    expect(
        result.timetable!.dates
            .where((e) => e.start == 22 * 60)
            .toList(growable: false),
        isEmpty,
        reason: '打开跨日面板不能画出任何东西');
  });

  testWidgets('跨日时段预览写明完整日期与总时长，并按自然日拆分', (tester) async {
    await _open(tester);
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-20',
      endTime: '00:30',
    );
    expect(find.textContaining('2026-10-19 23:30 → 2026-10-20 00:30'),
        findsOneWidget);
    expect(find.textContaining('共 60 分钟'), findsOneWidget);
    expect(find.textContaining('按自然日拆分'), findsOneWidget);
    expect(find.textContaining('2026-10-19 23:30-24:00（30 分钟）'),
        findsOneWidget);
    expect(find.textContaining('2026-10-20 00:00-00:30（30 分钟）'),
        findsOneWidget);
    expect(find.byKey(const Key('timetable-range-error')), findsNothing);
  });

  testWidgets('提交跨日时段是一笔事务：两个自然日各一条规则，可撤销可重做', (tester) async {
    await _open(tester);
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-20',
      endTime: '00:30',
    );
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已提交'), findsOneWidget);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull);
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNull);

    final drawn = await _save(tester);
    final dates = drawn.timetable!.dates;
    expect(
        dates.any((e) =>
            e.date == '2026-10-19' && e.start == 23 * 60 + 30 && e.end == 1440),
        isTrue);
    expect(
        dates.any((e) => e.date == '2026-10-20' && e.start == 0 && e.end == 30),
        isTrue);

    // 重新打开（数据相同）验证撤销/重做：撤销后两天规则都消失，重做后回来。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNull,
        reason: '重新打开是新的草稿基线');
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-20',
      endTime: '00:30',
    );
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNotNull);
    final afterUndo = await _save(tester);
    expect(
        afterUndo.timetable!.dates
            .where((e) => e.start == 23 * 60 + 30)
            .toList(growable: false),
        isEmpty);
    expect(
        afterUndo.timetable!.dates
            .where((e) => e.date == '2026-10-20' && e.start == 0)
            .toList(growable: false),
        isEmpty,
        reason: '一次提交只对应一条历史：撤销一次两天规则都应消失');

    // 撤销 → 重做：规则回来。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-20',
      endTime: '00:30',
    );
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-redo')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull);
    final afterRedo = await _save(tester);
    expect(
        afterRedo.timetable!.dates
            .any((e) => e.date == '2026-10-19' && e.start == 23 * 60 + 30),
        isTrue);
  });

  testWidgets('结束不晚于开始时明确报错且不写入', (tester) async {
    await _open(tester);
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-19',
      endTime: '00:30',
    );
    expect(find.byKey(const Key('timetable-range-error')), findsOneWidget);
    // 错误在“校验提示”和“自然日拆分说明”里各出现一次。
    expect(find.textContaining('结束必须晚于开始'), findsWidgets);
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已提交'), findsNothing);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNull);
  });

  testWidgets('端点超出 coverage 时提示扩大范围或取消，不静默截断', (tester) async {
    await _open(tester);
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-11-09',
      startTime: '22:00',
      endDate: '2026-11-10',
      endTime: '02:00',
    );
    expect(find.byKey(const Key('timetable-range-error')), findsOneWidget);
    expect(find.textContaining('扩大排程范围'), findsOneWidget);
    expect(find.textContaining('不会截断写入'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已提交'), findsNothing);
    final result = await _save(tester);
    expect(result.timetable!.dates, isEmpty,
        reason: '范围外不能静默写入任何区间');
  });

  testWidgets('清空本周是一笔可撤销事务，撤销能恢复规则', (tester) async {
    await _open(tester);
    await _drawTaskBlock(tester);
    await tester.tap(find.byKey(const Key('timetable-clear-week')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull,
        reason: '清空本周必须进入撤销历史');
    expect(find.byKey(const Key('calendar-settings-error')), findsNothing,
        reason: '清空是正常操作，不能显示红色错误');
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    final restored = await _save(tester);
    expect(
        restored.timetable!.dates.any(
            (e) => e.date == '2026-10-19' && e.start == 8 * 60),
        isTrue,
        reason: '撤销清空本周应恢复被清掉的规则');
  });

  testWidgets('“复制到…”入口：取消不改草稿，确认后写入目标日期且可撤销', (tester) async {
    await _open(tester);
    await _drawTaskBlock(tester);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull,
        reason: '画蓝块提交一笔历史后撤销按钮必须可用');

    // 先取消一次：不产生事务。画蓝块本身是一笔历史，撤销一次应完全回到无规则。
    await tester.tap(find.byKey(const Key('timetable-copy-to')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-copy-cancel')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull,
        reason: '画蓝块本身有历史；这里只验证没有多出复制历史');
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    final cancelled = await _save(tester);
    expect(cancelled.timetable!.dates, isEmpty,
        reason: '取消复制后撤销一次只撤销画蓝块这一笔，说明取消没有留下历史');

    // 再确认：复制到 2026-10-20。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _drawTaskBlock(tester);
    await tester.tap(find.byKey(const Key('timetable-copy-to')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), '2026-10-20');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull,
        reason: '确认复制是一笔可撤销事务');
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNull,
        reason: '新编辑必须清空 redo');

    final result = await _save(tester);
    final dates = result.timetable!.dates;
    expect(
        dates
            .where((e) => e.date == '2026-10-20' && e.start == 8 * 60)
            .toList(growable: false),
        isNotEmpty,
        reason: '目标日期出现复制结果');
    expect(
        dates.any((e) => e.date == '2026-10-19' && e.start == 8 * 60),
        isTrue,
        reason: '复制不能破坏源日期的规则');
    expect(
        dates
            .where((e) =>
                e.date == '2026-10-20' && e.state == TimetableState.task)
            .first
            .taskId,
        isNull,
        reason: '默认不复制任务绑定');
  });

  testWidgets('无修改的复制不产生撤销记录', (tester) async {
    await _open(tester);
    await _drawTaskBlock(tester);

    // 第一次复制：周一 → 周二。
    await tester.tap(find.byKey(const Key('timetable-copy-to')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), '2026-10-20');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();

    // 第二次复制同一目标：目标已有相同内容 → 预览为空、确认不可用。
    await tester.tap(find.byKey(const Key('timetable-copy-to')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), '2026-10-20');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-empty')), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('timetable-copy-confirm')));
    expect(confirm.onPressed, isNull, reason: '无修改的复制不能确认');
    await tester.tap(find.byKey(const Key('timetable-copy-cancel')));
    await tester.pumpAndSettle();

    // 撤销一次：应撤销第一次复制。若空复制入了历史，这一步看到的会是空操作。
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    final result = await _save(tester);
    expect(
        result.timetable!.dates
            .where((e) => e.date == '2026-10-20')
            .toList(growable: false),
        isEmpty,
        reason: '无修改的复制不得产生撤销记录');
  });

  testWidgets('选择模式逐块点选 → 绑定面板绑定 → 一笔事务，可撤销/重做', (tester) async {
    await _open(tester);
    await _drawTaskBlock(tester);

    await tester.tap(find.byKey(const Key('timetable-select-blocks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-selection-bar')), findsOneWidget);
    expect(find.textContaining('已选 0 块'), findsOneWidget);

    // 逐块点选：点在蓝块上选中，不绘制。
    await tester.tapAt(_cellCenter(tester, 0, 32));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 块 · 60 分钟'), findsOneWidget);
    expect(find.textContaining('已选 0 块'), findsNothing);

    await tester.tap(find.byKey(const Key('timetable-bind-selection')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-binding-panel')), findsOneWidget);
    expect(find.text('2026-10-19 08:00-09:00'), findsWidgets);
    await tester.tap(find.byKey(const Key('task-binding-bind')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-binding-panel')), findsNothing);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull);

    // 撤销：绑定回到未绑定。
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNotNull);
    final undone = await _save(tester);
    final entry = undone.timetable!.dates.firstWhere(
        (e) => e.date == '2026-10-19' && e.start == 8 * 60);
    expect(entry.taskId, isNull, reason: '撤销必须恢复完整业务数据');

    // 重做：绑定回来。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _drawTaskBlock(tester);
    await tester.tap(find.byKey(const Key('timetable-select-blocks')));
    await tester.pumpAndSettle();
    await tester.tapAt(_cellCenter(tester, 0, 32));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-bind-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-binding-bind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-redo')));
    await tester.pumpAndSettle();
    final redone = await _save(tester);
    final bound = redone.timetable!.dates.firstWhere(
        (e) => e.date == '2026-10-19' && e.start == 8 * 60);
    expect(bound.taskId, 'T1');
  });

  testWidgets('按“未绑定”筛选后批量选中当前周蓝块', (tester) async {
    await _open(tester);
    await _drawTaskBlock(tester);
    await tester.tap(find.byKey(const Key('timetable-select-blocks')));
    await tester.pumpAndSettle();

    // 用“未绑定”筛选批量选中。
    await tester.tap(find.byKey(const Key('timetable-selection-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未绑定').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('选中筛选结果（1 块）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-select-filtered')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 块 · 60 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-selection-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0 块'), findsOneWidget);
  });

  testWidgets('同一天的跨日模式输入（开始 < 结束）也能提交', (tester) async {
    await _open(tester);
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '09:00',
      endDate: '2026-10-19',
      endTime: '11:30',
    );
    expect(find.textContaining('共 150 分钟'), findsOneWidget);
    expect(find.textContaining('2026-10-19 09:00-11:30（150 分钟）'),
        findsOneWidget);
    expect(find.byKey(const Key('timetable-range-error')), findsNothing);
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    final result = await _save(tester);
    final rules = result.timetable!.dates
        .where((e) => e.date == '2026-10-19' && e.start == 9 * 60)
        .toList(growable: false);
    expect(rules, isNotEmpty);
    expect(rules.first.end, 11 * 60 + 30);
  });

  testWidgets('解除绑定保留蓝块身份，释放时段删除蓝块，二者都可撤销', (tester) async {
    // 1) 解除绑定：仍是 state=task，taskId 清空，reservationId 保留。
    await _open(tester);
    await _drawTaskBlock(tester);
    await _bindDrawnBlock(tester);
    await _reopenBindingPanel(tester);
    await tester.tap(find.byKey(const Key('task-binding-unbind')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNull,
        reason: '新编辑清空 redo');
    final unbound = await _save(tester);
    final unboundEntry = unbound.timetable!.dates.firstWhere(
        (e) => e.date == '2026-10-19' && e.start == 8 * 60);
    expect(unboundEntry.state, TimetableState.task);
    expect(unboundEntry.taskId, isNull);
    expect(unboundEntry.reservationId, isNotNull,
        reason: '解除绑定不能丢稳定身份');
    expect(unboundEntry.title, '写报告',
        reason: '解除绑定应保留原标题，不丢这条预留的描述');

    // 2) 解除绑定可撤销：撤销后绑定回来。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _drawTaskBlock(tester);
    await _bindDrawnBlock(tester);
    await _reopenBindingPanel(tester);
    await tester.tap(find.byKey(const Key('task-binding-unbind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-undo')));
    await tester.pumpAndSettle();
    final restored = await _save(tester);
    expect(
        restored.timetable!.dates
            .firstWhere((e) => e.date == '2026-10-19' && e.start == 8 * 60)
            .taskId,
        'T1');

    // 3) 释放时段是另一个动作：删除预留，恢复底层每周规则（08:00 起为 free）。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await _drawTaskBlock(tester);
    await _bindDrawnBlock(tester);
    await _reopenBindingPanel(tester);
    await tester.tap(find.byKey(const Key('task-binding-release')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-binding-release-confirm')));
    await tester.pumpAndSettle();
    final released = await _save(tester);
    expect(
        released.timetable!.dates
            .where((e) => e.date == '2026-10-19' && e.start == 8 * 60)
            .toList(growable: false),
        isEmpty,
        reason: '释放时段删除任务预留，而不是只清绑定');
    expect(released.timetable!.stateAt('2026-10-19', 1, 8 * 60 + 5),
        TimetableState.free);
  });

  testWidgets('应用成功后 markApplied：撤销/重做回到新基线', (tester) async {
    var calls = 0;
    await _open(tester, onApply: (result) async {
      calls++;
      return true;
    });
    await _openRangeMode(tester);
    await _enterRange(
      tester,
      startDate: '2026-10-19',
      startTime: '23:30',
      endDate: '2026-10-20',
      endTime: '00:30',
    );
    await tester.tap(find.byKey(const Key('timetable-range-apply')));
    await tester.pumpAndSettle();
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('calendar-settings-apply')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('已应用'), findsOneWidget);
    expect(_toolbarButton(tester, 'timetable-undo').onPressed, isNull,
        reason: '应用成功后建立新基线');
    expect(_toolbarButton(tester, 'timetable-redo').onPressed, isNull);
  });
}










