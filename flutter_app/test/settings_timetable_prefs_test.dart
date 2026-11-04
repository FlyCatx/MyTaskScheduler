// 三项日历通用设置：序列化、默认值、显式空值与界面控件。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_general_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import 'dart:io';

SettingsController _controller() => SettingsController(
      store: SettingsStore(Directory.systemTemp),
      bridge: null,
    );

void main() {
  test('新偏好字段可往返序列化，缺字段保持文档默认值', () {
    const prefs = AppPreferences(
      weekStartsOn: 7,
      defaultCalendarEditor: CalendarEditorMode.fill,
      defaultUnavailableRanges: <UnavailableRange>[
        UnavailableRange(0, 480),
        UnavailableRange(720, 840),
      ],
    );
    final restored = AppPreferences.fromJson(prefs.toJson());
    expect(restored, prefs);
    expect(restored.weekStartsOn, 7);
    expect(restored.defaultCalendarEditor, CalendarEditorMode.fill);
    expect(restored.defaultUnavailableRanges, hasLength(2));
  });

  test('越界周首日被夹回 1–7，显式空默认不可用保持为空', () {
    final restored = AppPreferences.fromJson(<String, dynamic>{
      'weekStartsOn': 9,
      'defaultUnavailableRanges': <dynamic>[],
    });
    expect(restored.weekStartsOn, 1);
    expect(restored.defaultUnavailableRanges, isEmpty);

    final clamped = const AppPreferences(weekStartsOn: 12).normalized();
    expect(clamped.weekStartsOn, 7);
  });

  testWidgets('通用页提供每周第一天、默认编辑方式与默认不可用时间', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TsColors.apply(Brightness.light);
    addTearDown(() => TsColors.apply(Brightness.light));
    final controller = _controller();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsGeneralPage(controller: controller),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('每周第一天'), findsOneWidget);
    expect(find.text('默认编辑方式'), findsOneWidget);
    expect(find.text('默认不可用时间'), findsOneWidget);
    expect(find.byKey(const Key('settings-default-unavailable')), findsOneWidget);
    // 默认每天可用 12 小时。
    expect(find.textContaining('每天可用 12 小时'), findsOneWidget);

    // 清空默认不可用 = 全天可用（明确设置，而不是缺省）。
    await tester.tap(find.byKey(const Key('settings-unavailable-clear')));
    await tester.pump();
    expect(controller.draft.prefs.defaultUnavailableRanges, isEmpty);
    expect(find.textContaining('每天可用 24 小时'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-unavailable-reset')));
    await tester.pump();
    expect(
      UnavailableRange.totalMinutes(
          controller.draft.prefs.defaultUnavailableRanges),
      720,
    );
  });
}
