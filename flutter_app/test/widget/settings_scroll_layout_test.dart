// Widget tests for the unified settings scroll layout (R2-ST / 0.2.2).
//
// The 0.2.1 settings window let 模型 / 存储 pages bring their own vertical scroll view
// into a dialog that also scrolled: the two scroll areas competed for the wheel, the
// scrollbar landed on top of switches and text fields, and each page had a different
// right margin (setting screenshots references/04 and 05). Now every page is rendered
// inside one `SettingsPageViewport`:
//
//   * one ScrollController per page (never two controllers for one scroll view);
//   * one explicit scrollbar bound to that controller;
//   * a real 18 DIP gutter, 8 DIP scrollbar, 4 DIP from the viewport's right edge;
//   * thumb hidden when the content fits (gutter still reserved → no horizontal jump).
//
//   ST01  同尺寸轮流切所有页：主轴轨道 x 一致、内容右边缘不越过沟槽。
//   ST02  长文本 / 1.5 倍字号 / 窄窗口无 RenderFlex 溢出；滚到最底最后一项完整可见；
//         滚动条不跨底栏。
//   ST03  切页返回保留输入与滚动位置；模型页双列不共享 controller、不冲突。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_store.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_expander.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_external_calendar_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_model_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_storage_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_widgets.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

const Key _pageStack = Key('settings-page-stack');

Future<SettingsController> _controller(WidgetTester tester) async {
  final controller = SettingsController(
    store: SettingsStore(createTempDataDir('settings_scroll')),
    bridge: FakeSettingsBridge(
      settings: settingsDocument(profiles: <ProviderProfile>[sampleProfile()]),
    ),
  );
  await tester.runAsync(controller.load);
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _openDialog(
  WidgetTester tester,
  SettingsController controller, {
  Size size = const Size(1000, 760),
  TextScaler? textScaler,
  ExternalCalendarService? externalCalendar,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child ?? const SizedBox.shrink(),
            ),
    home: Scaffold(
      body: SettingsDialog(
        controller: controller,
        externalCalendar: externalCalendar,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// Switches the rail to [section] and lets the IndexedStack relayout.
///
/// Deliberately does NOT `pumpAndSettle`: the 存储 page starts a real directory scan and
/// the 模型 page may poll — those are not what these layout tests are about.
Future<void> _select(WidgetTester tester, SettingsSection section) async {
  final item = find.descendant(
    of: find.byKey(const Key('settings-rail')),
    matching: find.text(section.label),
  );
  expect(item, findsWidgets, reason: '左栏缺少「${section.label}」');
  await tester.tap(item.first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

Finder _viewport(SettingsSection section) =>
    find.byKey(ValueKey('settings-viewport-${section.name}'));

Finder _scrollOf(SettingsSection section) => find.descendant(
      of: _viewport(section),
      matching: find.byKey(const Key('settings-viewport-scroll')),
    );

Finder _barOf(SettingsSection section) => find.descendant(
      of: _viewport(section),
      matching: find.byKey(const Key('settings-viewport-scrollbar')),
    );

String _fieldText(WidgetTester tester, Finder field) {
  final editable = tester.widget<EditableText>(
    find.descendant(of: field, matching: find.byType(EditableText)).first,
  );
  return editable.controller.text;
}

/// The page's content box (used to check the content right edge stays inside the gutter).
Finder _contentOf(SettingsSection section) {
  final viewport = _viewport(section);
  return switch (section) {
    SettingsSection.model => find.byType(SettingsModelPage),
    SettingsSection.storage => find.byType(SettingsStoragePage),
    // 外部日历页在 T-E 落地前是一个占位实现，没有 public 类型；用它的分组标题。
    SettingsSection.externalCalendar => find
        .descendant(of: viewport, matching: find.byType(SettingsGroupLabel))
        .first,
    _ => find.descendant(of: viewport, matching: find.byType(SettingsCard)).first,
  };
}

void main() {
  TsColors.apply(Brightness.light);

  testWidgets('ST01 轮流切所有页：主轴轨道 x 一致、内容右边缘不越过沟槽', (tester) async {
    final c = await _controller(tester);
    await _openDialog(tester, c);

    final scrollRects = <SettingsSection, Rect>{};
    for (final section in SettingsSection.values) {
      await _select(tester, section);
      expect(tester.takeException(), isNull, reason: '「${section.label}」渲染异常');
      expect(_viewport(section), findsOneWidget);
      expect(find.byKey(_pageStack), findsOneWidget);

      final scrollRect = tester.getRect(_scrollOf(section));
      scrollRects[section] = scrollRect;

      // 内容右边缘必须 ≤ 视口右边缘 - 18 DIP 沟槽。
      final contentRect = tester.getRect(_contentOf(section));
      expect(
        contentRect.right,
        lessThanOrEqualTo(scrollRect.right - kSettingsScrollbarGutter + 0.5),
        reason: '「${section.label}」内容越过了右侧滚动条沟槽',
      );

      // 沟槽是实际布局空间，不是画在内容上的浮层。
      final scroll = tester.widget<SingleChildScrollView>(_scrollOf(section));
      final padding = scroll.padding! as EdgeInsets;
      expect(padding.right, greaterThanOrEqualTo(kSettingsScrollbarGutter));

      // 唯一 controller + 显式滚动条，且条宽/距右边缘固定。
      final bar = tester.widget<RawScrollbar>(_barOf(section));
      expect(bar.controller, isNotNull, reason: '「${section.label}」滚动条没有绑定 controller');
      expect(identical(bar.controller, scroll.controller), isTrue,
          reason: '「${section.label}」滚动条与滚动视图必须是同一个 controller');
      expect(bar.thickness, kSettingsScrollbarThickness);
      expect(bar.crossAxisMargin, kSettingsScrollbarInset);

      // 内容不足时不画滑块（但沟槽还在，横向不跳动）。
      expect(bar.controller!.hasClients, isTrue);
      expect(bar.thumbVisibility,
          bar.controller!.position.maxScrollExtent > 0.5,
          reason: '「${section.label}」滑块可见性必须由是否真有可滚动范围决定');
    }

    // 所有页的主滚动轨道在同一条竖线上（x 与宽度一致）。
    final base = scrollRects[SettingsSection.account]!;
    for (final entry in scrollRects.entries) {
      expect(entry.value.left, closeTo(base.left, 0.01),
          reason: '「${entry.key.label}」的主滚动轨道与其它页不对齐');
      expect(entry.value.width, closeTo(base.width, 0.01),
          reason: '「${entry.key.label}」的滚动视口宽度与其它页不一致');
      expect(entry.value.right, closeTo(base.right, 0.01));
    }
  });

  testWidgets('ST02 1.5 倍字号/窄窗口无溢出；滚到最底最后一项完整可见；条不跨底栏',
      (tester) async {
    final c = await _controller(tester);
    await _openDialog(
      tester,
      c,
      size: const Size(780, 560),
      textScaler: const TextScaler.linear(1.5),
    );

    // 每个分类在 780×560 / 1.5 倍字号下都不能有 RenderFlex 溢出。
    for (final section in SettingsSection.values) {
      await _select(tester, section);
      expect(tester.takeException(), isNull,
          reason: '「${section.label}」在 780×560 / 1.5 倍字号下溢出');
    }

    // 存储页是最长的一页：滚到最底，最后一项必须完整可见。
    await _select(tester, SettingsSection.storage);
    final bar = tester.widget<RawScrollbar>(_barOf(SettingsSection.storage));
    final controller = bar.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(bar.thumbVisibility, isTrue, reason: '内容超出时滑块必须可见');

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();

    final viewportRect = tester.getRect(_scrollOf(SettingsSection.storage));
    final lastItem = tester.getRect(find.byKey(const Key('settings-storage-clean-run')));
    expect(lastItem.bottom, lessThanOrEqualTo(viewportRect.bottom + 0.5),
        reason: '滚到最底时最后一项必须完整可见（不能被视口裁掉）');
    expect(lastItem.top, greaterThanOrEqualTo(viewportRect.top - 0.5));

    // 滚动条（以及它的轨道）完全在内容视口内，不跨到底部按钮栏。
    final barRect = tester.getRect(_barOf(SettingsSection.storage));
    final footer = tester.getRect(find.byKey(const Key('settings-save')));
    expect(barRect.bottom, lessThanOrEqualTo(footer.top + 0.5),
        reason: '滚动条不能跨过固定 footer');

    // 正常字号 + 更窄的窗口下同样不溢出。
    await tester.binding.setSurfaceSize(const Size(700, 520));
    await tester.pumpAndSettle();
    for (final section in SettingsSection.values) {
      await _select(tester, section);
      expect(tester.takeException(), isNull,
          reason: '「${section.label}」在 700×520 下溢出');
    }

    // 原生最小宽度 960×800（主界面在该宽度改走抽屉形态）：设置窗口同样无溢出。
    await tester.binding.setSurfaceSize(const Size(960, 800));
    await tester.pumpAndSettle();
    for (final section in SettingsSection.values) {
      await _select(tester, section);
      expect(tester.takeException(), isNull,
          reason: '「${section.label}」在 960×800 下溢出');
    }
  });

  testWidgets('ST03 切页返回保留输入与滚动位置；模型页双列不共享 controller',
      (tester) async {
    final c = await _controller(tester);
    await _openDialog(tester, c, size: const Size(1100, 760));

    // 通用页写一段未保存文本。
    await _select(tester, SettingsSection.general);
    final unavailable = find.byKey(const Key('settings-default-unavailable'));
    await tester.enterText(unavailable, '23:00-08:00');
    await tester.pump();
    // 这个输入框会把合法输入规范化（如 23:00-08:00 → 00:00-08:00, 23:00-00:00）；
    // 记录规范化后的内容，切页返回必须逐字保留。
    final generalText = _fieldText(tester, unavailable);
    expect(generalText, isNotEmpty);

    // 快捷键页写一个搜索词。
    await _select(tester, SettingsSection.shortcuts);
    final shortcutSearch = find.byKey(const Key('shortcut-search'));
    await tester.enterText(shortcutSearch, '新建');
    await tester.pump();

    // 存储页滚动到中间并记下偏移。
    await _select(tester, SettingsSection.storage);
    final storageBar =
        tester.widget<RawScrollbar>(_barOf(SettingsSection.storage));
    final storageController = storageBar.controller!;
    expect(storageController.position.maxScrollExtent, greaterThan(0));
    final savedOffset =
        math.min(140.0, storageController.position.maxScrollExtent - 1);
    storageController.jumpTo(savedOffset);
    await tester.pump();

    // 切回通用：未保存文本还在。
    await _select(tester, SettingsSection.general);
    expect(_fieldText(tester, unavailable), generalText,
        reason: '切页不得清掉未保存的表单');

    // 切回快捷键：搜索词还在。
    await _select(tester, SettingsSection.shortcuts);
    expect(_fieldText(tester, shortcutSearch), '新建');

    // 切到模型页：双列各自滚动，不共享 controller。
    await _select(tester, SettingsSection.model);
    final modelBar =
        tester.widget<RawScrollbar>(_barOf(SettingsSection.model));
    final modelListView = tester.widget<ListView>(
      find
          .descendant(
              of: find.byType(SettingsModelPage),
              matching: find.byType(ListView))
          .first,
    );
    expect(modelBar.controller, isNotNull);
    expect(modelListView.controller, isNotNull);
    expect(identical(modelBar.controller, modelListView.controller), isFalse,
        reason: '连接列表的独立滚动不能与主视口共享同一个 ScrollController');
    expect(modelBar.controller!.positions.length, 1,
        reason: '主视口 controller 只 attach 一个 position');
    expect(modelListView.controller!.positions.length, 1,
        reason: '连接列表 controller 只 attach 一个 position');

    // 模型页的编辑跨切页保留。
    final modelName = find.byKey(const Key('settings-model-name'));
    await tester.enterText(modelName, '保留的名字');
    await tester.pump();
    await _select(tester, SettingsSection.general);
    await _select(tester, SettingsSection.model);
    expect(_fieldText(tester, modelName), '保留的名字',
        reason: '切页不得清掉模型连接编辑');

    // 存储页的滚动位置切回来仍然在。
    await _select(tester, SettingsSection.storage);
    final restored =
        tester.widget<RawScrollbar>(_barOf(SettingsSection.storage)).controller!;
    expect(identical(restored, storageController), isTrue,
        reason: '每页滚动位置由各自的 controller 保留');
    expect(restored.offset, closeTo(savedOffset, 1.0),
        reason: '切页返回后滚动位置应恢复');
  });

  testWidgets('ST04 外部日历分类：无服务时说明不可用，有服务时挂载 T-E 页面', (tester) async {
    final c = await _controller(tester);

    // 不传 service（独立构造 SettingsDialog 的宿主 / 测试）：显示明确说明，不崩溃。
    await _openDialog(tester, c);
    await _select(tester, SettingsSection.externalCalendar);
    expect(find.byKey(const Key('settings-external-calendar-unavailable')),
        findsOneWidget);
    expect(find.byType(SettingsExternalCalendarPage), findsNothing);

    // 传 service：挂载 T-E 的真实来源管理页。
    final service = ExternalCalendarService(
      store: ExternalCalendarStore(createTempDataDir('settings_scroll_extcal')),
      limits: const IcsLimits(),
    );
    addTearDown(service.dispose);
    await _openDialog(tester, c, externalCalendar: service);
    await _select(tester, SettingsSection.externalCalendar);
    expect(find.byType(SettingsExternalCalendarPage), findsOneWidget);
    expect(find.byKey(const Key('settings-external-calendar-unavailable')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}
