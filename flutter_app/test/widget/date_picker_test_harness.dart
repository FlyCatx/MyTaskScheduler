// 执行回顾/日历相关测试共用的日期弹层操作辅助（不是测试文件本身）。
//
// 共享日期控件（ui/widgets/date_range_picker.dart）的交互是“点字段 → 弹出日历”；
// 这里封装“在弹层里选到指定年月日”的固定路径，供回顾自定义范围等用例复用。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String datePickerKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

Future<void> _openYearGridFor(WidgetTester tester, int year) async {
  await tester.tap(find.byKey(const Key('calendar-year-button')));
  await tester.pumpAndSettle();
  for (var i = 0; i < 24; i++) {
    if (find.byKey(Key('calendar-year-$year')).evaluate().isNotEmpty) return;
    final range = tester
        .widget<Text>(find.byKey(const Key('calendar-year-range')))
        .data!;
    final start = int.parse(range.split('–').first.trim());
    await tester.tap(find.byKey(Key(
        year < start ? 'calendar-year-page-prev' : 'calendar-year-page-next')));
    await tester.pumpAndSettle();
  }
  fail('年份网格里找不到 $year');
}

/// 点开 [fieldKey] 字段的日历，并选到 [date]（选年后自动进月格，再回日格）。
Future<void> pickDateFromField(
  WidgetTester tester,
  Key fieldKey,
  DateTime date,
) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await _openYearGridFor(tester, date.year);
  await tester.tap(find.byKey(Key('calendar-year-${date.year}')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('calendar-month-${date.month}')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('calendar-day-${datePickerKey(date)}')));
  await tester.pumpAndSettle();
}
