// Widget tests for the sidebar layout (R2-SB / 0.2.2).
//
// Regression being fixed: the 0.2.1 `LayoutBuilder` wrote `_showHistory = false`
// whenever the window was narrower than the breakpoint. That made the user's choice a
// side effect of the window size, so widening/maximising never brought the sidebar back,
// and the collapsed state rendered one `SidebarRail` per band (three repeated expand
// icons, see references/03).
//
// Contract now:
//   * `_sidebarWanted` — the user preference, the only persistent-ish source;
//   * `_sidebarDrawerOpen` — a temporary drawer that only exists on narrow windows.
//
//   SB01  展开 → 缩窄 → 变宽：常驻侧栏自动恢复；会话列表滚动位置、会话 / 搜索词 /
//         草稿 / 选中任务都不变。
//   SB02  手动收起 → 缩窄 → 变宽 / 最大化：仍然收起；不写偏好文件。
//   SB03  窄屏展开 = 临时抽屉（明确关闭按钮 + Esc），关抽屉不改用户偏好；
//         整个折叠状态只有 1 个 rail 展开入口；断点附近有滞回、不抖动；
//         切尺寸不触发会话切换。
//   SB04  断点按等效宽度（逻辑宽度 ÷ 文字缩放）：960 最小宽度、1120 @1.5 倍字号
//         都不常驻且主区无 RenderFlex 溢出；1400 @1.0 仍常驻。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/history_panel.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

const Size _wide = Size(1440, 900);
const Size _narrow = Size(900, 800);

Future<SettingsController> _settings(
  WidgetTester tester, {
  FakeSettingsBridge? bridge,
}) async {
  final controller = SettingsController(
    store: SettingsStore(createTempDataDir('sidebar_layout')),
    bridge: bridge ?? FakeSettingsBridge(),
  );
  await tester.runAsync(controller.load);
  addTearDown(controller.dispose);
  return controller;
}

Future<AppController> _pumpShell(
  WidgetTester tester, {
  required SettingsController settings,
  Size size = _wide,
  int conversationCount = 1,
  TextScaler? textScaler,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = InMemorySessionRepository();
  final summaries = <ConversationSummary>[];
  for (var i = 0; i < conversationCount; i++) {
    final id = 'conv-$i';
    await seedConversation(
      store,
      conversationId: id,
      title: i == 0 ? '顺序表实验' : '会话 $i',
    );
    final conversation = await store.loadConversation(id);
    summaries.add(ConversationSummary.of(conversation!));
  }
  await store.saveIndex(summaries);
  final controller = AppController(engine: FakeScheduleEngine(), store: store);
  await controller.initialize();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child ?? const SizedBox.shrink(),
            ),
    home: AppShell(controller: controller, settings: settings),
  ));
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _resize(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpAndSettle();
}

/// The resident (expanded) sidebar.
Finder get _residentSidebar => find.byType(HistorySidebarList);
Finder get _residentHeader => find.byType(HistorySidebarHeader);
Finder get _rail => find.byKey(const Key('sidebar-rail-expand'));
Finder get _drawer => find.byKey(const Key('sidebar-drawer'));

String _searchText(WidgetTester tester) {
  final field = tester.widget<TextField>(
    find.descendant(
      of: find.byKey(const Key('conversation-search')),
      matching: find.byType(TextField),
    ).first,
  );
  return field.controller?.text ?? '';
}

String _composerText(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('composer-input')))
        .controller
        ?.text ??
    '';

/// 可见的常驻会话列表里的纵向 Scrollable（搜索框内部是横向 Scrollable，要排除）。
ScrollableState _sidebarListScroll(WidgetTester tester) {
  final scrollables = find.descendant(
    of: find.byType(HistorySidebarList),
    matching: find.byType(Scrollable),
  );
  for (final element in scrollables.evaluate()) {
    final state = (element as StatefulElement).state;
    if (state is ScrollableState && state.position.axis == Axis.vertical) {
      return state;
    }
  }
  fail('常驻会话列表没有纵向 Scrollable');
}

void main() {
  testWidgets('SB01 展开→缩窄→变宽：侧栏自动恢复，会话列表滚动位置/会话/搜索词/草稿都保留',
      (tester) async {
    final settings = await _settings(tester);
    final controller = await _pumpShell(
      tester,
      settings: settings,
      conversationCount: 24,
    );

    // 宽屏：常驻侧栏。
    expect(_residentHeader, findsOneWidget);
    expect(_residentSidebar, findsOneWidget);
    expect(_rail, findsNothing, reason: '展开状态不应再出现折叠 rail');

    // 会话列表滚到中间：折叠/展开不得重置这个位置。
    final listScroll = _sidebarListScroll(tester);
    expect(listScroll.position.maxScrollExtent, greaterThan(0),
        reason: '需要用可滚动的会话列表验证滚动位置保留');
    listScroll.position.jumpTo(150);
    await tester.pump();
    final savedListOffset = listScroll.position.pixels;

    // 缩窄：常驻侧栏不显示，只剩唯一一个展开入口；不抛异常。
    await _resize(tester, _narrow);
    expect(tester.takeException(), isNull);
    expect(_residentHeader, findsNothing);
    expect(_residentSidebar, findsNothing);
    expect(_rail, findsOneWidget);
    expect(find.byType(SidebarRail), findsOneWidget,
        reason: '折叠状态只允许一个 rail 展开入口');

    // 变宽：自动恢复展开（用户偏好从未被窗口尺寸改写）。
    await _resize(tester, _wide);
    expect(tester.takeException(), isNull);
    expect(_residentHeader, findsOneWidget);
    expect(_residentSidebar, findsOneWidget);
    expect(find.byType(SidebarRail), findsNothing);
    expect(_sidebarListScroll(tester).position.pixels,
        closeTo(savedListOffset, 1.0),
        reason: '折叠/展开不得重置会话列表的滚动位置');

    // 写下搜索词与草稿，并记下当前会话/任务。
    await tester.enterText(find.byKey(const Key('conversation-search')), '实验');
    await tester.enterText(find.byKey(const Key('composer-input')), '不要丢的草稿');
    await tester.pumpAndSettle();
    final conversationId = controller.conversation!.id;
    controller.interaction.selectAndReveal('task-b');
    await tester.pumpAndSettle();
    final selectedTask = controller.interaction.selectedTaskId;
    final summaryCount = controller.summaries.length;

    // 再缩窄/变宽一次：这些状态一样不能变。
    await _resize(tester, _narrow);
    expect(_residentHeader, findsNothing);
    await _resize(tester, _wide);
    expect(_residentHeader, findsOneWidget);

    // 折叠/展开不得改变会话、搜索词、选中任务、草稿、请求状态。
    expect(controller.conversation!.id, conversationId);
    expect(controller.summaries.length, summaryCount);
    expect(controller.interaction.selectedTaskId, selectedTask);
    expect(controller.run, isNull, reason: '切换尺寸不得启动请求');
    expect(_searchText(tester), '实验', reason: '搜索词跨尺寸保留');
    expect(_composerText(tester), '不要丢的草稿', reason: '草稿跨尺寸保留');
    expect(settings.dirty, isFalse, reason: '侧栏形态是临时 UI 状态，不写设置草稿');
  });

  testWidgets('SB02 手动收起→缩窄→变宽/最大化：仍然收起，且不写偏好文件',
      (tester) async {
    final bridge = FakeSettingsBridge();
    final settings = await _settings(tester, bridge: bridge);
    final controller = await _pumpShell(tester, settings: settings);
    final conversationId = controller.conversation!.id;

    // 用户在宽屏手动收起。
    await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(_residentHeader, findsNothing);
    expect(_rail, findsOneWidget);

    // 缩窄再变宽（模拟最大化 / 还原）：用户偏好是“收起”，不能被尺寸改写。
    await _resize(tester, _narrow);
    expect(_rail, findsOneWidget);
    expect(_residentHeader, findsNothing);

    await _resize(tester, const Size(1920, 1080));
    expect(tester.takeException(), isNull);
    expect(_residentHeader, findsNothing,
        reason: '手动收起后放大/最大化仍要保持收起');
    expect(_residentSidebar, findsNothing);
    expect(_rail, findsOneWidget);

    // 再还原一次，仍然收起。
    await _resize(tester, _wide);
    expect(_residentHeader, findsNothing);
    expect(controller.conversation!.id, conversationId);

    // 侧栏形态从不写用户设置/偏好文件。
    expect(settings.dirty, isFalse);
    expect(bridge.savedPayloads, isEmpty, reason: '切换侧栏不得调用保存');
  });

  testWidgets('SB03 窄屏抽屉：展开可用、Esc 可关、不改偏好、只有 1 个 rail',
      (tester) async {
    final settings = await _settings(tester);
    final controller =
        await _pumpShell(tester, settings: settings, size: _narrow);
    final conversationId = controller.conversation!.id;
    expect(tester.takeException(), isNull);

    // 窄屏默认：没有常驻侧栏，也没有抽屉，只有唯一 rail。
    expect(_residentSidebar, findsNothing);
    expect(_drawer, findsNothing);
    expect(_rail, findsOneWidget);
    expect(find.byType(SidebarRail), findsOneWidget);

    // 展开 → 临时抽屉/覆盖面板，里面有可用的会话列表与搜索框。
    await tester.tap(_rail);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget);
    expect(find.byKey(const Key('sidebar-drawer-close')), findsOneWidget,
        reason: '临时抽屉必须有明确关闭按钮');
    expect(
      find.descendant(of: _drawer, matching: find.byType(HistorySidebarList)),
      findsOneWidget,
      reason: '抽屉里必须是真实可用的会话面板',
    );
    expect(
      find.descendant(of: _drawer, matching: find.byKey(const Key('conversation-search'))),
      findsOneWidget,
    );
    expect(find.byType(SidebarRail), findsOneWidget,
        reason: '展开抽屉时也不能出现第二个 rail 入口');
    // 抽屉不改变当前会话。
    expect(controller.conversation!.id, conversationId);

    // Esc 关闭抽屉。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_drawer, findsNothing, reason: 'Esc 必须能关掉临时抽屉');
    expect(_rail, findsOneWidget);

    // 关闭抽屉 ≠ 收起侧栏：用户偏好没变，变宽后常驻侧栏恢复。
    await _resize(tester, _wide);
    expect(_residentHeader, findsOneWidget,
        reason: '关抽屉不改 _sidebarWanted，变宽后应恢复常驻侧栏');

    // 断点附近带 ±24 滞回（窄→宽方向）：1090 仍在 1080..1104 的滞回带里，保持窄。
    await _resize(tester, _narrow); // 900 → 窄
    expect(_rail, findsOneWidget);
    expect(_residentHeader, findsNothing);
    await _resize(tester, const Size(1090, 800));
    expect(_residentHeader, findsNothing,
        reason: '从窄变宽必须越过 1080+24 才切换，避免断点抖动');
    expect(_rail, findsOneWidget);
    await _resize(tester, _wide); // ≥1104 → 宽
    expect(_residentHeader, findsOneWidget);
    await _resize(tester, _narrow); // <1056 → 窄
    expect(_rail, findsOneWidget);
    expect(_residentHeader, findsNothing);

    // 切尺寸不触发会话切换。
    expect(controller.conversation!.id, conversationId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SB04 等效宽度断点：960 最小宽度与 1120@1.5 倍字号都不常驻且不溢出',
      (tester) async {
    final settings = await _settings(tester);

    // 原生最小宽度 960 DIP、1.0 倍字号：侧栏不常驻（主区拿整宽），无 RenderFlex 溢出。
    await _pumpShell(tester, settings: settings, size: const Size(960, 800));
    expect(tester.takeException(), isNull,
        reason: '960 宽度下主区不应出现 RenderFlex 溢出');
    expect(_residentHeader, findsNothing, reason: '960 < 1080，侧栏不得常驻');
    expect(_rail, findsOneWidget);
    expect(_drawer, findsNothing);

    // 1120 DIP + 1.5 倍字号：等效宽度 747 < 1080 → 抽屉形态，主区拿整宽、无溢出。
    await _pumpShell(
      tester,
      settings: settings,
      size: const Size(1120, 800),
      textScaler: const TextScaler.linear(1.5),
    );
    expect(tester.takeException(), isNull,
        reason: '1120 @1.5 倍字号下不得出现 RenderFlex 溢出');
    expect(_residentHeader, findsNothing,
        reason: '等效宽度 1120/1.5≈747 < 1080，侧栏必须改用抽屉形态');
    expect(_rail, findsOneWidget);
    // 抽屉在窄形态下依然可用。
    await tester.tap(_rail);
    await tester.pumpAndSettle();
    expect(_drawer, findsOneWidget);
    expect(tester.takeException(), isNull);

    // 对照：1400 DIP、1.0 倍字号仍然常驻（断点没有被抬高到影响正常宽窗口）。
    await _pumpShell(tester, settings: settings, size: const Size(1400, 900));
    expect(tester.takeException(), isNull);
    expect(_residentHeader, findsOneWidget,
        reason: '1400 ≥ 1080，1.0 倍字号下侧栏应常驻');
    expect(_rail, findsNothing);
  });

  test('SB03b 断点滞回是纯函数：1080 ± 24，两个方向都不抖动', () {
    // 首帧：按 1080 判断（入参是等效宽度）。
    expect(resolveSidebarWide(1079.9, null), isFalse);
    expect(resolveSidebarWide(1080, null), isTrue);

    // 窄 → 宽：需要 ≥ 1104 才切换。
    expect(resolveSidebarWide(1080, false), isFalse);
    expect(resolveSidebarWide(1103.9, false), isFalse);
    expect(resolveSidebarWide(1104, false), isTrue);
    // 滞回带 1080..1104 内来回：不会来回跳。
    expect(resolveSidebarWide(1090, false), isFalse);
    expect(resolveSidebarWide(1090, true), isTrue);

    // 宽 → 窄：需要 < 1056 才切换。
    expect(resolveSidebarWide(1056, true), isTrue);
    expect(resolveSidebarWide(1055.9, true), isFalse);
    expect(resolveSidebarWide(1060, true), isTrue);
    expect(resolveSidebarWide(1060, false), isFalse);

    // 常量本身也是契约的一部分。
    expect(kSidebarResidentMinWidth, 1080);
    expect(kSidebarBreakpointHysteresis, 24);
  });
}

