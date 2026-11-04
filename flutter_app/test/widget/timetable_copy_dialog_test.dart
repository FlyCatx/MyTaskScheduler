// “复制到…”对话框的界面回归测试。
//
// 覆盖第一轮需求里的复制要求：目标日期集合可点选/输入（去重、校验 coverage）、
// 两种策略、替换前必须确认并列出移除区间与任务引用、“复制整天”的说明与
// 占用/空闲/任务预留预览、默认不复制 taskId、取消不改草稿、无修改时确认不可用。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/timetable_copy_dialog.dart';

const String _source = '2026-11-09';
const String _target = '2026-11-10';

/// 源日期 09:00-10:00 有一条已绑定任务的日期层规则；目标日期默认空闲。
Timetable _timetable() {
  var t = Timetable.withDefaults(weekStart: '2026-11-09');
  t = t.paint(
    date: _source,
    start: 9 * 60,
    end: 10 * 60,
    state: TimetableState.task,
    title: '任务预留',
    taskId: 't1',
    reservationId: 'res-1',
  );
  return t;
}

/// 源日期与目标日期同一时刻各有一条任务预留（替换模式会改写目标的这条）。
///
/// 直接构造 dates 层而不是连续调用 paint：这是数据夹具，用来隔离“复制”的 UI 行为；
/// 日期层多日期写入本身由 model 测试覆盖。
Timetable _timetableWithTargetRule() {
  final base = Timetable.withDefaults(weekStart: '2026-11-09');
  return base.copyWith(
    dates: <TimetableEntry>[
      const TimetableEntry(
        id: 'tt-src',
        state: TimetableState.task,
        start: 9 * 60,
        end: 10 * 60,
        date: _source,
        title: '任务预留',
        taskId: 't1',
        reservationId: 'res-1',
      ),
      const TimetableEntry(
        id: 'tt-tgt',
        state: TimetableState.task,
        start: 9 * 60,
        end: 10 * 60,
        date: _target,
        title: '任务预留',
        taskId: 't1',
        reservationId: 'res-target',
      ),
    ],
  );
}

TimetableCopyPlan? lastPlan;

Future<void> _open(
  WidgetTester tester, {
  Timetable? timetable,
  String sourceDate = _source,
}) async {
  lastPlan = null;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 1000);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1100, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  final t = timetable ?? _timetable();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              lastPlan = await showTimetableCopyDialog(
                context,
                timetable: t,
                sourceDate: sourceDate,
                coverageFrom: t.dateFrom,
                coverageTo: t.dateTo,
                taskIds: const {'t1'},
                taskNames: const {'t1': '写报告'},
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

Future<void> _selectTargetByCheckbox(WidgetTester tester) async {
  final finder = find.byKey(const Key('timetable-copy-target-$_target'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开时给出源日期说明，未选目标日期时确认不可用', (tester) async {
    await _open(tester);
    expect(find.byKey(const Key('timetable-copy-dialog')), findsOneWidget);
    expect(find.textContaining('源日期有 1 条日期层规则'), findsOneWidget);
    expect(find.byKey(const Key('timetable-copy-target-summary')), findsOneWidget);
    expect(find.text('已选 0 天'), findsOneWidget);
    expect(find.byKey(const Key('timetable-copy-no-targets')), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('timetable-copy-confirm')));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('输入目标日期后预览具体日期与将写入分钟，确认返回计划', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('timetable-copy-target-dates')), findsOneWidget);
    expect(find.textContaining(_target), findsWidgets);
    expect(find.textContaining('目标日期（1 天）'), findsOneWidget);
    // 源日期状态分解：区分占用/空闲/任务预留。
    expect(find.textContaining('占用'), findsWidgets);
    expect(find.textContaining('空闲'), findsWidgets);
    expect(find.textContaining('任务预留'), findsWidgets);

    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('timetable-copy-confirm')));
    expect(confirm.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();

    expect(lastPlan, isNotNull);
    expect(lastPlan!.targetDates, contains(_target));
    expect(lastPlan!.changedMinutes, 60);
    expect(lastPlan!.isEmpty, isFalse);
  });

  testWidgets('目标日期去重，重复添加给出明确提示', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 天'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), '$_target,$_target');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 天'), findsOneWidget);
    expect(find.textContaining('已经在目标集合里'), findsOneWidget);
  });

  testWidgets('超出 coverage 的目标日期被拒绝并提示范围', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), '2026-12-01');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 天'), findsOneWidget);
    expect(find.textContaining('超出覆盖范围'), findsOneWidget);
    expect(find.textContaining('2026-11-09 至 2026-11-15'), findsOneWidget);
  });

  testWidgets('勾选列表里的目标日期与全选都生效', (tester) async {
    await _open(tester);
    await _selectTargetByCheckbox(tester);
    expect(find.text('已选 1 天'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-copy-select-all')));
    await tester.pumpAndSettle();
    // 覆盖 7 天，全选时排除源日期。
    expect(find.text('已选 6 天'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-copy-clear-targets')));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 天'), findsOneWidget);
  });

  testWidgets('替换策略先列出移除区间与任务引用，确认前可取消且不返回结果', (tester) async {
    await _open(tester, timetable: _timetableWithTargetRule());
    await _selectTargetByCheckbox(tester);
    await tester.tap(find.byKey(const Key('timetable-copy-strategy-replace')));
    await tester.pumpAndSettle();

    // 目标日同区间已有“手动可用”规则，替换会改写它。
    expect(find.textContaining('会移除/改写'), findsWidgets);
    expect(find.byKey(const Key('timetable-copy-removed-range')), findsWidgets);
    expect(find.byKey(const Key('timetable-copy-affected-tasks')), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('替换目标所选时段？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-copy-replace-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-dialog')), findsOneWidget);
    expect(lastPlan, isNull, reason: '取消确认不能返回计划');

    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-copy-replace-confirm')));
    await tester.pumpAndSettle();
    expect(lastPlan, isNotNull);
    expect(lastPlan!.removedRanges, isNotEmpty);
  });

  testWidgets('复制整天区分占用/空闲/任务预留并显示整天说明', (tester) async {
    await _open(tester, timetable: _timetableWithTargetRule());
    await _selectTargetByCheckbox(tester);
    await tester.tap(find.byKey(const Key('timetable-copy-whole-day')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-whole-day-note')),
        findsOneWidget);
    expect(find.textContaining('复制整天：占用/默认不可用时段也属于复制结果'),
        findsOneWidget);
    expect(find.byKey(const Key('timetable-copy-source-states')), findsOneWidget);
    // 整天的任务预留分钟数出现在状态分解里。
    expect(find.textContaining('任务预留 60 分钟'), findsOneWidget);
  });

  testWidgets('默认不复制 taskId；显式勾选保留后才复制绑定并给出提示', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    TimetableEntry? copied;
    for (final entry in lastPlan!.result.dates) {
      if (entry.date == _target && entry.isTask) copied = entry;
    }
    expect(copied, isNotNull);
    expect(copied!.taskId, isNull, reason: '默认不复制任务绑定');

    // 重新打开：勾选保留绑定。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.tap(find.byKey(const Key('timetable-copy-keep-bindings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-warning')), findsWidgets,
        reason: '保留绑定要提示任务预留时长变化');
    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    TimetableEntry? bound;
    for (final entry in lastPlan!.result.dates) {
      if (entry.date == _target && entry.isTask) bound = entry;
    }
    expect(bound, isNotNull);
    expect(bound!.taskId, 't1');
  });

  testWidgets('源日期没有日期层规则时没有可复制内容，确认不可用', (tester) async {
    final timetable = Timetable.withDefaults(weekStart: '2026-11-09');
    await _open(tester, timetable: timetable);
    expect(find.textContaining('没有日期层规则'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-copy-empty')), findsOneWidget);
    expect(find.textContaining('不会产生撤销记录'), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('timetable-copy-confirm')));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('取消/关闭返回 null，且完全不修改传入的时间表', (tester) async {
    final timetable = _timetable();
    final before = jsonEncode(timetable.toJson());
    await _open(tester, timetable: timetable);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _target);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-copy-cancel')));
    await tester.pumpAndSettle();
    expect(lastPlan, isNull);
    expect(find.byKey(const Key('timetable-copy-dialog')), findsNothing);
    expect(jsonEncode(timetable.toJson()), before,
        reason: '取消复制不能修改草稿');

    // 关闭按钮同样不返回计划。
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-copy-close')));
    await tester.pumpAndSettle();
    expect(lastPlan, isNull);
    expect(jsonEncode(timetable.toJson()), before);
  });

  testWidgets('多目标日期各自写入、互不覆盖（回归：日期层不能串日期）', (tester) async {
    await _open(tester);
    await tester.enterText(find.byKey(const Key('timetable-copy-target-input')),
        '2026-11-10, 2026-11-11');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 天'), findsOneWidget);
    expect(find.textContaining('目标日期（2 天）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    expect(lastPlan!.targetDates, <String>['2026-11-10', '2026-11-11']);
    expect(lastPlan!.changedMinutes, 120);
    for (final date in lastPlan!.targetDates) {
      final rules = lastPlan!.result.dates
          .where((e) =>
              e.date == date &&
              e.isTask &&
              e.start == 9 * 60 &&
              e.end == 10 * 60)
          .toList(growable: false);
      expect(rules, isNotEmpty, reason: '$date 的复制结果不能被其它目标日期覆盖');
    }
    // 源日期规则也必须保留。
    expect(
        lastPlan!.result.dates
            .where((e) => e.date == _source && e.isTask)
            .toList(growable: false),
        isNotEmpty);
  });

  testWidgets('源日期不能作为目标日期：天数不虚增、计划里没有源日期', (tester) async {
    await _open(tester);
    // 同时输入源日期和一个合法目标日期：只加目标，源日期被忽略并提示。
    await tester.enterText(find.byKey(const Key('timetable-copy-target-input')),
        '$_source, $_target');
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 天'), findsOneWidget);
    expect(find.textContaining('源日期 $_source 已忽略'), findsOneWidget);
    expect(find.textContaining('目标日期（1 天）：$_target'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-copy-confirm')));
    await tester.pumpAndSettle();
    expect(lastPlan, isNotNull);
    expect(lastPlan!.targetDates, <String>[_target]);
    expect(lastPlan!.targetDates, isNot(contains(_source)));
    expect(
        lastPlan!.result.dates
            .where((e) => e.date == _source)
            .every((e) => e.taskId == 't1'),
        isTrue,
        reason: '源日期的规则不能出现在目标集合里');
  });

  testWidgets('只输入源日期时确认不可用，并明确提示原因', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.byKey(const Key('timetable-copy-target-input')), _source);
    await tester.tap(find.byKey(const Key('timetable-copy-target-add')));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 天'), findsOneWidget);
    expect(find.textContaining('源日期不能作为目标日期'), findsOneWidget);
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('timetable-copy-confirm')));
    expect(confirm.onPressed, isNull);
  });

  testWidgets('源日期越界时明确报错，不静默回退到范围第一天', (tester) async {
    await _open(tester, sourceDate: '2026-12-01');
    // 输入框保留用户给的日期，没有被悄悄改成 coverage 第一天。
    final sourceField = tester.widget<TextField>(
        find.byKey(const Key('timetable-copy-source-date')));
    expect(sourceField.controller!.text, '2026-12-01');
    expect(find.byKey(const Key('timetable-copy-error')), findsOneWidget);
    expect(find.textContaining('不在覆盖范围'), findsOneWidget);
    expect(find.textContaining('2026-11-09 至 2026-11-15'), findsOneWidget);
  });
}

