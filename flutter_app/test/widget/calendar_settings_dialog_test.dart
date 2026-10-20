// The "可用时间与占用时间" editor (0.07).
//
// These tests cover the parts of the 11-image hand-off that live in this dialog:
//   * img 1: one parser for all three editors, canonical text, live weekly total, equal
//     footer buttons, and the two explanatory sentences actually removed;
//   * img 2: model proposals are **unticked by default**, carry evidence/source, can be
//     edited when only a duration was recognised, and are only written on 保存;
//   * img 3: the scrolling area reserves room for the scrollbar, and the exception row
//     has a real gap between its toggle and its delete button.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/calendar_proposals.dart';
import 'package:taskscheduler_flutter/src/state/calendar_constraints.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

CalendarSettings _settings() => CalendarSettings(
      timezoneOffsetMinutes: 480,
      planningStartDate: '2026-10-19',
      planningDays: 14,
      weekly: WeeklyAvailability({
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 1440)],
      }),
      exceptions: const [
        CalendarDateException(date: '2026-10-22', closed: true),
      ],
      occupancies: const [
        CalendarOccupancy(
          id: 'occ-1',
          title: '大学物理',
          kind: 'course',
          weekday: 3,
          ranges: [WallClockRange(540, 600)],
        ),
      ],
    );

CalendarProposalSet _proposalSet() => decodeCalendarProposals(
      {
        'schemaVersion': 1,
        'proposals': [
          {
            'kind': 'occupancy',
            'title': '上课',
            'occupancyKind': 'course',
            'weekdays': [2, 4],
            'date': null,
            'closed': false,
            'ranges': [
              {'start': 480, 'end': 600},
            ],
            'evidence': '每周二和周四08-10上课',
            'source': '材料1:第1段',
            'needsTime': false,
            'question': null,
          },
          {
            'kind': 'occupancy',
            'title': '午饭',
            'occupancyKind': 'rest',
            'weekdays': [1, 2, 3, 4, 5],
            'date': null,
            'closed': false,
            'ranges': <Map<String, int>>[],
            'durationMinutes': 30,
            'evidence': '中午吃饭30分钟',
            'source': '材料1:第1段',
            'needsTime': true,
            'question': '「吃饭」只知道 30 分钟，请补充具体起止时间',
          },
        ],
        'notes': <String>[],
      },
      materialSignature: 'sig',
      now: DateTime.utc(2026, 10, 19),
      thinkingEnabled: true,
      thinkingEffort: 'high',
      protocol: 'deepseek-chat',
    ).set!;

Future<void> _open(
  WidgetTester tester, {
  CalendarProposalSource? source,
  CalendarSettings? settings,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1100, 900));
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
              final result = await showCalendarSettingsDialog(
                context,
                settings: settings ?? _settings(),
                now: DateTime.utc(2026, 10, 19, 2),
                proposals: source,
              );
              // Kept so a test can read the popped value.
              lastResult = result;
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

CalendarSettingsResult? lastResult;

/// Scrolls a widget inside the dialog's scrolling content into view before tapping it.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => lastResult = null);

  group('图 1：时间输入与按钮', () {
    testWidgets('删除两条指定说明，保留时区实际值与合计', (tester) async {
      await _open(tester);
      expect(find.textContaining('每周规则按此偏移的本地墙钟时间解释'), findsNothing);
      expect(find.textContaining('空白的星期表示不可用'), findsNothing);
      // 时区的实际值仍然显示，可用合计仍然显示。
      expect(find.textContaining('时区：Asia/Shanghai'), findsOneWidget);
      expect(find.byKey(const Key('calendar-weekly-total')), findsOneWidget);
    });

    testWidgets('三处编辑都接受中文冒号/逗号/长横线并规范化', (tester) async {
      await _open(tester);
      // 每周可用时间
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-1')), '8： 00 — 12：00，14-18');
      // 占用时段
      await tester.enterText(
          find.byKey(const Key('calendar-occupancy-ranges-0')), '8： 00 — 9： 40');
      await tester.pump();
      // 合计随输入即时更新（不依赖其它控件触发 rebuild）
      final total = tester
          .widget<Text>(find.byKey(const Key('calendar-weekly-total')))
          .data!;
      expect(total, contains('分钟'));
      final minutes = int.parse(RegExp(r'合计：(\d+)').firstMatch(total)!.group(1)!);
      // 周一只剩 08:00-12:00 + 14:00-18:00 = 480 分钟，其余六天各 960 分钟。
      expect(minutes, 480 + 960 * 6);

      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      final result = lastResult!.settings;
      expect(WallClockRange.format(result.weekly.forWeekday(1).first),
          '08:00-12:00');
      expect(result.occupancies.first.ranges.first.startMinute, 480);
      expect(result.occupancies.first.ranges.first.endMinute, 580);
    });

    testWidgets('非法时间阻止保存并给出具体原因', (tester) async {
      await _open(tester);
      await tester.enterText(
          find.byKey(const Key('calendar-weekday-2')), '8-12xyz');
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(lastResult, isNull, reason: '非法时间不能保存');
      expect(find.textContaining('无法识别的时段'), findsOneWidget);
    });

    testWidgets('底部两个按钮等高、同圆角，文字居中', (tester) async {
      await _open(tester);
      final cancel = tester
          .getRect(find.byKey(const Key('calendar-settings-cancel')));
      final save =
          tester.getRect(find.byKey(const Key('calendar-settings-save')));
      expect(save.height, cancel.height);
      expect(save.height, greaterThanOrEqualTo(32));
      expect(save.top, closeTo(cancel.top, 0.5),
          reason: '同一行的按钮必须上下对齐');

      final cancelButton = tester.widget<TextButton>(
          find.byKey(const Key('calendar-settings-cancel')));
      final saveButton = tester.widget<TextButton>(
          find.byKey(const Key('calendar-settings-save')));
      final cancelShape = cancelButton.style!.shape!.resolve(const <WidgetState>{})
          as BezierRoundedRectangleBorder;
      final saveShape = saveButton.style!.shape!.resolve(const <WidgetState>{})
          as BezierRoundedRectangleBorder;
      expect(cancelShape.radius, saveShape.radius);
    });
  });

  group('图 3：滚动条与操作区', () {
    testWidgets('滚动内容为滚动条留出右侧空间', (tester) async {
      await _open(tester);
      final scroll = tester.widget<SingleChildScrollView>(find
          .descendant(
            of: find.byType(Scrollbar),
            matching: find.byType(SingleChildScrollView),
          )
          .first);
      final padding = scroll.padding! as EdgeInsets;
      expect(padding.right, greaterThanOrEqualTo(16),
          reason: '滚动条不能盖住删除按钮/复选框');
      final scrollbar =
          tester.widget<Scrollbar>(find.byType(Scrollbar).first);
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.controller, isNotNull);
    });

    testWidgets('日期例外的“关闭/开放”和删除按钮之间有真实间距', (tester) async {
      await _open(tester);
      final toggles = find.widgetWithText(FilledButton, '关闭');
      final firstToggle = toggles.first;
      final toggleRect = tester.getRect(firstToggle);
      // 同一行的删除图标（tooltip 唯一）。
      final deleteIcon = find.byTooltip('删除这条日期例外').first;
      final deleteRect = tester.getRect(deleteIcon);
      expect(deleteRect.left - toggleRect.right, greaterThanOrEqualTo(6),
          reason: '两个按钮之间要有真实间距，不能贴在一起');
      expect(deleteRect.width, greaterThanOrEqualTo(28),
          reason: '删除按钮需要足够的点击区域');
    });
  });

  group('图 2：模型识别的候选', () {
    testWidgets('新识别候选默认未勾选，并显示依据与来源', (tester) async {
      await _open(
        tester,
        source: CalendarProposalSource(
          cached: _proposalSet(),
          request: ({bool force = false}) async =>
              CalendarProposalOutcome.success(_proposalSet()),
        ),
      );
      // 按候选 ID 定位复选框，逐个断言"默认不勾选"。
      for (final proposal in _proposalSet().proposals) {
        final box = tester.widget<Checkbox>(
          find.byKey(Key('calendar-proposal-check-${proposal.id}')),
        );
        expect(box.value, isFalse,
            reason: '识别成功不等于应用：所有候选默认都不勾选');
      }
      expect(find.textContaining('每周二和周四08-10上课'), findsOneWidget,
          reason: '必须显示原文依据');
      expect(find.textContaining('材料1:第1段'), findsWidgets);
      expect(find.textContaining('本次识别：思考'), findsOneWidget);
    });

    testWidgets('未勾选时不写入数据；勾选后才成为正式占用', (tester) async {
      await _open(
        tester,
        source: CalendarProposalSource(
          cached: _proposalSet(),
          request: ({bool force = false}) async =>
              CalendarProposalOutcome.success(_proposalSet()),
        ),
      );
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(lastResult!.settings.occupancies.length, 1,
          reason: '只有原来那条占用');
      expect(lastResult!.appliedProposals, 0);

      // 勾选课程候选后保存 → 周二/周四各一条正式占用。
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final course = _proposalSet()
          .proposals
          .firstWhere((p) => p.title == '上课');
      await _reveal(
          tester, find.byKey(Key('calendar-proposal-check-${course.id}')));
      await tester.tap(find.byKey(Key('calendar-proposal-check-${course.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      final occupancies = lastResult!.settings.occupancies;
      expect(occupancies.where((o) => o.title == '上课').length, 2);
      expect(lastResult!.appliedProposals, greaterThan(0));
    });

    testWidgets('只给时长的候选必须先补时段才能勾选', (tester) async {
      await _open(
        tester,
        source: CalendarProposalSource(
          cached: _proposalSet(),
          request: ({bool force = false}) async =>
              CalendarProposalOutcome.success(_proposalSet()),
        ),
      );
      final lunch =
          _proposalSet().proposals.firstWhere((p) => p.title == '午饭');
      expect(
        tester
            .widget<Checkbox>(
                find.byKey(Key('calendar-proposal-check-${lunch.id}')))
            .onChanged,
        isNotNull,
        reason: '可以勾选，但保存时会要求先填时间',
      );
      expect(find.byKey(Key('calendar-proposal-ranges-${lunch.id}')),
          findsOneWidget);
      expect(find.textContaining('只知道 30 分钟'), findsWidgets);

      await _reveal(
          tester, find.byKey(Key('calendar-proposal-check-${lunch.id}')));
      await tester.tap(find.byKey(Key('calendar-proposal-check-${lunch.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      expect(lastResult, isNull, reason: '没有具体时段时不能保存');
      expect(find.textContaining('需要先填写具体时段'), findsOneWidget);

      await _reveal(
          tester, find.byKey(Key('calendar-proposal-ranges-${lunch.id}')));
      await tester.enterText(
          find.byKey(Key('calendar-proposal-ranges-${lunch.id}')),
          '12：00-12：30');
      await tester.tap(find.byKey(const Key('calendar-settings-save')));
      await tester.pumpAndSettle();
      final rest = lastResult!.settings.occupancies
          .firstWhere((o) => o.kind == 'rest');
      expect(rest.ranges.single.startMinute, 720);
      expect(rest.ranges.single.endMinute, 750);
    });

    testWidgets('识别失败时显示原因并可重试（不假装成功）', (tester) async {
      var calls = 0;
      await _open(
        tester,
        source: CalendarProposalSource(
          request: ({bool force = false}) async {
            calls++;
            return calls == 1
                ? const CalendarProposalOutcome.failure('网络不可用')
                : CalendarProposalOutcome.success(_proposalSet());
          },
        ),
      );
      expect(calls, 1, reason: '打开弹窗后自动请求一次');
      expect(find.textContaining('网络不可用'), findsOneWidget);
      await _reveal(
          tester, find.byKey(const Key('calendar-proposal-retry')));
      await tester.tap(find.byKey(const Key('calendar-proposal-retry')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byKey(const Key('calendar-proposal-status')), findsOneWidget);
      expect(find.textContaining('网络不可用'), findsNothing);
    });

    testWidgets('已有缓存时不会再次请求（打开弹窗不重复计费）', (tester) async {
      var calls = 0;
      await _open(
        tester,
        source: CalendarProposalSource(
          cached: _proposalSet(),
          request: ({bool force = false}) async {
            calls++;
            return CalendarProposalOutcome.success(_proposalSet());
          },
        ),
      );
      expect(calls, 0);
      // 只有用户点“重新识别”才会再发一次请求。
      await _reveal(
          tester, find.byKey(const Key('calendar-proposal-retry')));
      await tester.tap(find.byKey(const Key('calendar-proposal-retry')));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('没有材料时给出说明而不是可点的按钮', (tester) async {
      await _open(
        tester,
        source: const CalendarProposalSource(
          blockedReason: '还没有可识别的材料',
          request: _neverRequest,
        ),
      );
      expect(find.textContaining('还没有可识别的材料'), findsOneWidget);
      expect(find.byKey(const Key('calendar-proposal-retry')), findsNothing);
    });
  });
}

/// A request that cannot be awaited in a fake-async test (never used: blocked).
Future<CalendarProposalOutcome> _neverRequest({bool force = false}) async =>
    throw StateError('不应发起请求');
