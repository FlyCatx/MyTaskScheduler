// 共享年月日历控件（0.5.0 任务 03）的 widget 测试：
//   * 周一为首列；相邻月 / 今天 / 已选中 / 键盘焦点四态；
//   * 点字段展开、选日回填并关闭；Esc / 点空白不提交；
//   * 点年份标题 → 年份网格（可翻页）→ 选月 → 回日格；闰年 2 月 29 日；
//   * 「今天」回填本地今天；firstDate/lastDate 禁用不可选日；
//   * 浮窗贴近字段，底部空间不足时向上展开。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/date_range_picker.dart';

class _FieldHarness extends StatefulWidget {
  const _FieldHarness({
    required this.initialValue,
    required this.picked,
    this.firstDate,
    this.lastDate,
    this.today,
  });

  final DateTime? initialValue;
  final List<DateTime?> picked;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final DateTime? today;

  @override
  State<_FieldHarness> createState() => _FieldHarnessState();
}

class _FieldHarnessState extends State<_FieldHarness> {
  DateTime? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    return DatePickerField(
      key: const Key('date-field'),
      value: _value,
      label: '开始日期',
      width: 160,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      today: widget.today,
      onChanged: (date) {
        setState(() => _value = date);
        widget.picked.add(date);
      },
    );
  }
}

Future<List<DateTime?>> _pumpField(
  WidgetTester tester, {
  required DateTime? value,
  DateTime? firstDate,
  DateTime? lastDate,
  DateTime? today,
  Alignment alignment = Alignment.center,
}) async {
  final picked = <DateTime?>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _FieldHarness(
            initialValue: value,
            picked: picked,
            firstDate: firstDate,
            lastDate: lastDate,
            today: today,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return picked;
}

DateTime _day(int y, int m, int d) => DateTime.utc(y, m, d);

String _key(DateTime date) => 'calendar-day-${formatDatePickerDate(date)}';

Text _dayText(WidgetTester tester, DateTime date) => tester.widget<Text>(
      find.descendant(
        of: find.byKey(Key(_key(date))),
        matching: find.byType(Text),
      ),
    );

void main() {
  setUp(() => TsColors.apply(Brightness.light));

  testWidgets('点字段展开：周一为首列，已选中/今天/相邻月用不同颜色区分', (tester) async {
    await _pumpField(
      tester,
      value: _day(2026, 11, 9),
      today: _day(2026, 11, 11),
    );
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('calendar-popup')), findsOneWidget);
    // 星期一为首列。
    const labels = <String>['一', '二', '三', '四', '五', '六', '日'];
    for (var i = 0; i < labels.length; i++) {
      expect(
        tester
            .widget<Text>(find.byKey(Key('calendar-weekday-$i')))
            .data,
        labels[i],
      );
    }
    // 2026-11-09 是周一：它和“一”列在同一 x 位置。
    expect(
      tester.getCenter(find.byKey(Key(_key(_day(2026, 11, 9))))).dx,
      closeTo(tester.getCenter(find.byKey(const Key('calendar-weekday-0'))).dx, 0.5),
    );
    // 已选中：实心，文字为 onButton。
    expect(_dayText(tester, _day(2026, 11, 9)).style!.color, TsColors.onButton);
    // 今天（未选中）：accent 文字。
    expect(_dayText(tester, _day(2026, 11, 11)).style!.color, TsColors.accent);
    // 相邻月（10-26 属于日格第一行）：淡色文字，仍可点（不置灰）。
    expect(_dayText(tester, _day(2026, 10, 26)).style!.color, TsColors.textFaint);
    // 当月普通日：主文字色。
    expect(
      _dayText(tester, _day(2026, 11, 12)).style!.color,
      TsColors.textPrimary,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选日回填并关闭；Esc 与点空白都不提交', (tester) async {
    // 选日：回填并关闭。
    final picked = await _pumpField(tester, value: _day(2026, 11, 9));
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(_key(_day(2026, 11, 15)))));
    await tester.pumpAndSettle();
    expect(picked, [_day(2026, 11, 15)]);
    expect(find.byKey(const Key('calendar-popup')), findsNothing);
    expect(
      find.text('2026-11-15'),
      findsOneWidget,
      reason: '选中日期回填到触发它的字段',
    );

    // Esc：关闭且不提交，字段保持原值。
    picked.clear();
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-popup')), findsNothing);
    expect(picked, isEmpty);
    expect(
      tester.widget<DatePickerField>(find.byKey(const Key('date-field'))).value,
      _day(2026, 11, 15),
    );

    // 点空白：关闭且不提交。
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-popup')), findsNothing);
    expect(picked, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点年份 → 年份网格翻页 → 选月 → 选闰年 2 月 29 日', (tester) async {
    final picked = await _pumpField(tester, value: _day(2026, 11, 9));
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar-year-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-year-range')), findsOneWidget);
    // 当前页覆盖 2026；翻到下一页（含 2028）再翻回来。
    expect(find.byKey(const Key('calendar-year-2026')), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-year-page-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-year-2026')), findsNothing);
    expect(find.byKey(const Key('calendar-year-2028')), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-year-page-prev')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-year-2026')), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-year-page-next')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calendar-year-2028')));
    await tester.pumpAndSettle();
    // 选年后进入 1–12 月网格。
    expect(find.byKey(const Key('calendar-month-2')), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-month-2')));
    await tester.pumpAndSettle();
    // 回到日格：2028 年 2 月有 29 日（闰年）。
    expect(find.byKey(Key(_key(_day(2028, 2, 29)))), findsOneWidget);
    await tester.tap(find.byKey(Key(_key(_day(2028, 2, 29)))));
    await tester.pumpAndSettle();
    expect(picked, [_day(2028, 2, 29)]);
    expect(find.text('2028-02-29'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左右箭头翻月；「今天」回填本地今天', (tester) async {
    final picked = await _pumpField(
      tester,
      value: _day(2026, 11, 9),
      today: _day(2026, 12, 1),
    );
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-next-month')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key(_key(_day(2026, 12, 1)))), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-prev-month')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key(_key(_day(2026, 11, 9)))), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-today')));
    await tester.pumpAndSettle();
    expect(picked, [_day(2026, 12, 1)]);
    expect(find.text('2026-12-01'), findsOneWidget);
    expect(find.byKey(const Key('calendar-popup')), findsNothing);
  });

  testWidgets('键盘：方向键移动焦点，Enter 选日；焦点环与今天区分', (tester) async {
    final picked = await _pumpField(
      tester,
      value: _day(2026, 11, 9),
      today: _day(2026, 11, 20),
    );
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    // 初始焦点 = 已选中日（11-09）。右移一天、下移一周 → 11-17。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    // 焦点日有焦点环（border 2），且不是今天的单像素描边。
    final focusedBox = tester.widget<Container>(
      find.descendant(
        of: find.byKey(Key(_key(_day(2026, 11, 17)))),
        matching: find.byType(Container),
      ),
    );
    final decoration = focusedBox.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect((decoration.border! as Border).top.width, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, [_day(2026, 11, 17)]);
    expect(find.byKey(const Key('calendar-popup')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('firstDate/lastDate 之外的日子不可选', (tester) async {
    await _pumpField(
      tester,
      value: _day(2026, 11, 10),
      firstDate: _day(2026, 11, 10),
      lastDate: _day(2026, 11, 20),
    );
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    InkWell cell(DateTime date) => tester.widget<InkWell>(
          find.byKey(Key(_key(date))),
        );
    expect(cell(_day(2026, 11, 9)).onTap, isNull);
    expect(cell(_day(2026, 11, 21)).onTap, isNull);
    expect(cell(_day(2026, 11, 10)).onTap, isNotNull);
    expect(cell(_day(2026, 11, 20)).onTap, isNotNull);
    await tester.tap(find.byKey(Key(_key(_day(2026, 11, 9)))));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('calendar-popup')),
      findsOneWidget,
      reason: '禁用日点击不提交，弹层不关闭',
    );
  });

  testWidgets('底部空间不足时向上展开，且不越出窗口', (tester) async {
    await _pumpField(
      tester,
      value: _day(2026, 11, 9),
      alignment: Alignment.bottomCenter,
    );
    final fieldRect = tester.getRect(find.byKey(const Key('date-field')));
    await tester.tap(find.byKey(const Key('date-field')));
    await tester.pumpAndSettle();
    final popupRect = tester.getRect(find.byKey(const Key('calendar-popup')));
    expect(popupRect.bottom, lessThanOrEqualTo(fieldRect.top + 0.5),
        reason: '下方放不下时向上展开');
    expect(popupRect.top, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(800));
    expect(tester.takeException(), isNull);
  });
}
