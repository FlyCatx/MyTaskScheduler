// Widget tests for the 0.0.4 settings pages and window.
//
// Scope (see docs/SETTINGS_0_0_4_SPEC.md §8 / §11):
//   * 账户安全: no EDITABLE field and no enabled action (a disabled form cannot claim a
//     sign-in), plus the explicit "no network / no password" statement;
//   * 通用: switches and the font-size slider write the draft and the UI reflects it;
//   * 快捷键: exactly the five shortcuts that are really registered;
//   * 通知: the 120-second reminder is explained and there is no system-notification
//     switch (that feature does not exist);
//   * 关于: the real version constant, and the sanitised diagnostic copy contains no key;
//   * the window renders at a small size with a 1.5x text scale without overflow, works
//     in the dark palette, and asks before discarding unsaved edits.
//
// No test here loads ts_bridge.dll: the settings bridge is the in-memory fake.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/app_info.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_about_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_account_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_general_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_model_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_notifications_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_shortcuts_page.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_storage_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

/// A loaded controller backed by a throw-away folder and the in-memory bridge.
///
/// `load()` performs real file I/O, which fake-async widget tests never advance on
/// their own — it must run inside [WidgetTester.runAsync].
Future<SettingsController> _controller(
  WidgetTester tester, {
  FakeSettingsBridge? bridge,
  bool load = true,
}) async {
  final controller = SettingsController(
    store: SettingsStore(createTempDataDir('settings_pages')),
    bridge: bridge ?? FakeSettingsBridge(),
  );
  if (load) {
    await tester.runAsync(controller.load);
  }
  return controller;
}

/// Hosts a single page the way the dialog does (bounded width, scrollable height).
Widget _host(Widget page) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: page)),
    );

void main() {
  group('账户安全', () {
    testWidgets('只有禁用控件：不可编辑、无网络、无假登录', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_host(const SettingsAccountPage()));
      await tester.pumpAndSettle();

      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields, isNotEmpty, reason: '占位表单应当存在（否则测试没有意义）');
      for (final field in fields) {
        expect(field.enabled, isFalse, reason: '账户页任何输入框都必须是禁用状态');
      }

      final login = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '登录'),
      );
      expect(login.onPressed, isNull, reason: '登录按钮必须禁用，不能伪造登录');
      final changePassword = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '修改密码'),
      );
      expect(changePassword.onPressed, isNull,
          reason: '修改密码按钮必须禁用');

      // 0.09: 页首的说明段落已按要求删除；页内应只剩身份事实与禁用控件。
      expect(find.textContaining('账户服务尚未接入'), findsNothing);
      expect(find.textContaining('不会保存密码'), findsNothing);
      expect(find.text('未登录云端'), findsOneWidget,
          reason: '登录状态是事实，不附带括号说明');
      expect(find.text('本地分析'), findsNothing,
          reason: '重复的说明段落已按要求删除');
      expect(find.text('未来能力'), findsNothing);
      // No fake identity / fake success wording.
      expect(find.textContaining('登录成功'), findsNothing);
      expect(find.textContaining('已连接账户'), findsNothing);
    });
  });

  group('通用', () {
    testWidgets('开关与滑块写入草稿并立即反映在界面上', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);
      expect(c.dirty, isFalse);

      await tester.pumpWidget(_host(SettingsGeneralPage(controller: c)));
      await tester.pumpAndSettle();

      // 主题
      await tester.ensureVisible(find.text('深色'));
      await tester.tap(find.text('深色'));
      await tester.pump();
      expect(c.draft.prefs.themeMode, AppThemeMode.dark);
      expect(c.dirty, isTrue);

      // 已完成任务开关
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      final before = c.draft.prefs.showCompletedTasks;
      await tester.ensureVisible(switchFinder);
      await tester.pumpAndSettle();
      await tester.tap(switchFinder);
      await tester.pump();
      expect(c.draft.prefs.showCompletedTasks, isNot(before));
      expect(tester.widget<Switch>(switchFinder).value,
          c.draft.prefs.showCompletedTasks,
          reason: '开关必须反映草稿值');

      // 字号滑块
      await tester.ensureVisible(find.byType(Slider));
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, AppPreferences.minFontScale);
      expect(slider.max, AppPreferences.maxFontScale);
      slider.onChanged!(1.2);
      await tester.pump();
      expect(c.draft.prefs.fontScale, closeTo(1.2, 0.0001));

      // 0.07: the teaching "预览" block was removed on request; the percentage label
      // next to the slider is the visible feedback for the draft value.
      expect(find.textContaining('110%'), findsNothing);
      expect(find.textContaining('120%'), findsOneWidget,
          reason: '字号控件的数值必须跟随草稿');

      // 发送方式
      await tester.ensureVisible(find.text('Enter 发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter 发送'));
      await tester.pump();
      expect(c.draft.prefs.sendMode, SendMode.enter);
    });
  });

  group('快捷键', () {
    testWidgets('列出真实注册项并允许录制/清除/恢复默认', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(SettingsShortcutsPage(controller: c)));
      await tester.pumpAndSettle();

      for (final keys in <String>[
        'Ctrl+Enter',
        'Ctrl+N',
        'Ctrl+,',
        'Ctrl+O',
        'Esc',
      ]) {
        expect(find.text(keys), findsOneWidget, reason: '缺少快捷键 $keys');
      }
      // 0.05: editable registry + search. Esc is fixed and has no record button.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const Key('shortcuts-reset-all')), findsOneWidget);
      expect(find.byKey(const Key('shortcut-record-conversation.new')),
          findsOneWidget);
      expect(find.byKey(const Key('shortcut-record-dialog.close')), findsNothing);
      expect(find.textContaining('固定'), findsWidgets);
    });
  });

  group('通知', () {
    testWidgets('只有应用内开关；120 秒提醒与系统通知说明清晰', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(SettingsNotificationsPage(controller: c)));
      await tester.pumpAndSettle();

      expect(find.byType(Switch), findsNWidgets(3),
          reason: '完成/失败应用内开关 + 系统通知开关');
      expect(find.textContaining('120 秒'), findsWidgets);
      expect(find.textContaining('系统通知'), findsWidgets);
      expect(find.byKey(const Key('settings-notify-system')), findsOneWidget);
      // 0.07 trimmed the long teaching notes; the one non-obvious fact (the 120 s
      // reminder is not a notification and is not muted by these switches) stays.
      expect(find.textContaining('不是通知'), findsOneWidget);

      final beforeSystem = c.draft.prefs.notifySystem;
      await tester.ensureVisible(find.byKey(const Key('settings-notify-system')));
      await tester.tap(find.byKey(const Key('settings-notify-system')));
      await tester.pump();
      expect(c.draft.prefs.notifySystem, isNot(beforeSystem));
      expect(c.dirty, isTrue);

      final before = c.draft.prefs.notifyOnSuccess;
      await tester.ensureVisible(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(c.draft.prefs.notifyOnSuccess, isNot(before));
      expect(c.dirty, isTrue);
    });
  });

  group('关于', () {
    testWidgets('显示真实版本与未配置的更新服务', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(SettingsAboutPage(controller: c)));
      await tester.pumpAndSettle();

      expect(find.textContaining(kAppVersion), findsWidgets);
      expect(find.textContaining('更新服务未配置'), findsOneWidget);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('查看帮助'), findsOneWidget);
      expect(find.text('复制诊断'), findsOneWidget);
      expect(find.textContaining('不会联网检查更新'), findsNothing);
      expect(find.textContaining('打开程序目录下的 README'), findsNothing);
      expect(find.textContaining('复制版本、ABI'), findsNothing);
      expect(find.textContaining('默认折叠；'), findsNothing);
      final diagnosticsSize =
          tester.getSize(find.byKey(const Key('about-diagnostics')));
      expect(diagnosticsSize.height, lessThan(70),
          reason: '精简说明后不应留下空壳诊断卡片');
      await tester.tap(find.byKey(const Key('about-diagnostics')));
      await tester.pump();
      expect(find.text('运行界面'), findsOneWidget);

      // 0.05: 检查更新 is genuinely disabled (no tap, no fake result).
      final updateButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '检查更新'));
      expect(updateButton.onPressed, isNull);
      expect(find.textContaining('更新服务'), findsWidgets);
    });

    testWidgets('脱敏诊断可复制且不含密钥', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(
        tester,
        bridge: FakeSettingsBridge(
          settings: settingsDocument(profiles: <ProviderProfile>[sampleProfile()]),
        ),
      );
      addTearDown(c.dispose);

      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_host(SettingsAboutPage(controller: c)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('复制诊断'));
      await tester.pumpAndSettle();

      expect(copied, isNotNull);
      expect(copied, contains(kAppVersion));
      expect(copied, contains('ABI: 2'));
      expect(copied, contains('连接数: 1'));
      expect(copied, contains('api.example.test'), reason: '端点只保留 host');
      expect(copied!.toLowerCase(), isNot(contains('sk-')));
      expect(copied, isNot(contains('https://')));

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });

  group('设置窗口', () {
    testWidgets('小窗口 + 1.5 倍字号：全部分类可渲染且无溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(780, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SettingsDialog(controller: c)),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final section in SettingsSection.values) {
        await tester.tap(find.text(section.label).first);
        // Two pumps are enough for layout + paint (where overflow is detected). A full
        // pumpAndSettle would also wait on the 模型/存储 pages' asynchronous directory
        // scans, which is not what this test is about.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull,
            reason: '「${section.label}」在 780×560 / 1.5 倍字号下溢出');
      }
    });

    testWidgets('模型/存储页在固定高度里真的能滚到底部', (tester) async {
      await tester.binding.setSurfaceSize(const Size(780, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = await _controller(tester);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: SettingsDialog(controller: c)),
      ));
      await tester.pump();

      await tester.tap(find.text('模型').last);
      await tester.pump();
      final modelScroll = find
          .descendant(
              of: find.byType(SettingsModelPage),
              matching: find.byType(SingleChildScrollView))
          .first;
      final apiKey = find.text('API Key');
      final before = tester.getTopLeft(apiKey).dy;
      await tester.drag(modelScroll, const Offset(0, -260));
      await tester.pump();
      expect(tester.getTopLeft(apiKey).dy, lessThan(before),
          reason: '鼠标/触控板滚动必须能到达模型页底部的凭据区');

      await tester.tap(find.text('存储').last);
      await tester.pump();
      final storageScroll = find
          .descendant(
              of: find.byType(SettingsStoragePage),
              matching: find.byType(SingleChildScrollView))
          .first;
      final cache = find.textContaining('清理');
      final cacheBefore = tester.getTopLeft(cache.first).dy;
      await tester.drag(storageScroll, const Offset(0, -300));
      await tester.pump();
      expect(tester.getTopLeft(cache.first).dy, lessThan(cacheBefore),
          reason: '存储页必须能滚动到缓存清理区');
    });

    testWidgets('暗色调色板下窗口表面不出现白块', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TsColors.apply(Brightness.dark);
      addTearDown(() => TsColors.apply(Brightness.light));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsDialog(controller: c)),
      ));
      await tester.pumpAndSettle();

      final rail = tester.widget<Container>(find.byKey(const Key('settings-rail')));
      final railDecoration = rail.decoration!;
      final railColor = railDecoration is ShapeDecoration
          ? railDecoration.color!
          : (railDecoration as BoxDecoration).color!;
      expect(railColor, TsColors.sidebar);
      expect(railColor.computeLuminance(), lessThan(0.15),
          reason: '暗色边栏不应是浅色');

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, TsColors.surface);
      expect(dialog.backgroundColor!.computeLuminance(), lessThan(0.15));
      expect(tester.takeException(), isNull);
    });

    testWidgets('有未保存修改时关闭会询问；无修改直接关闭', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context, controller: c),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ));

      Future<void> open() async {
        await tester.tap(find.text('打开设置'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsDialog), findsOneWidget);
      }

      // No edits: closing is immediate.
      await open();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);

      // Edit something, then close: the three-way prompt appears.
      await open();
      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(c.dirty, isTrue);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget);
      expect(find.text('继续编辑'), findsOneWidget);
      expect(find.text('放弃'), findsOneWidget);

      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(c.dirty, isTrue, reason: '继续编辑不能丢草稿');

      // 放弃 closes and drops the draft.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
      expect(c.dirty, isFalse);
    });

    testWidgets('点击遮罩关闭时同样先询问（与 Esc 共用 maybePop 路径）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context, controller: c),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);

      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(c.dirty, isTrue);

      // (4,4) is on the modal barrier: outside the 48px inset dialog card.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('有未保存的修改'), findsOneWidget,
          reason: '点击遮罩不能直接丢掉草稿');

      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(c.dirty, isTrue);
    });

    testWidgets('账户页也是取消 / 应用 / 保存三按钮（不再有“关闭”特例）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(
                context,
                controller: c,
                initial: SettingsSection.account,
              ),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();

      // The footer is identical on every page, including 账户安全.
      expect(find.text('关闭'), findsNothing);
      expect(find.byKey(const Key('settings-cancel')), findsOneWidget);
      expect(find.byKey(const Key('settings-apply')), findsOneWidget);
      expect(find.byKey(const Key('settings-save')), findsOneWidget);

      // Nothing to apply → 应用 disabled, but 保存 still works (it just closes): an
      // untouched page must not be impossible to leave with 保存.
      final apply = tester.widget<TextButton>(
          find.byKey(const Key('settings-apply')));
      expect(apply.onPressed, isNull, reason: '没有修改时应用必须禁用');
      final save =
          tester.widget<TextButton>(find.byKey(const Key('settings-save')));
      expect(save.onPressed, isNotNull, reason: '没有修改时仍应能用保存退出');

      await tester.tap(find.byKey(const Key('settings-save')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
      expect(c.dirty, isFalse);
    });

    testWidgets('默认进入账户安全；应用后修改再取消只回退第二次改动',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final c = await _controller(tester);
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context, controller: c),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();

      // No explicit initial → 账户安全 (the generic entry point).
      expect(find.text('本地账户'), findsOneWidget);

      await tester.tap(find.text('通用'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      final appliedValue = !c.draft.prefs.showCompletedTasks;
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(c.dirty, isTrue);

      // 应用: persists and STAYS on 通用 (it must not jump back to 账户安全).
      // The store writes real files, so the write must run under `runAsync`; the
      // footer's indeterminate spinner would otherwise never settle.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('settings-apply')));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.dirty, isFalse);
      expect(c.prefs.showCompletedTasks, appliedValue);
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(find.text('本地账户'), findsNothing,
          reason: '应用后必须留在当前设置页');

      // Second edit, then 取消: only that edit is reverted.
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(c.dirty, isTrue);
      await tester.tap(find.byKey(const Key('settings-cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDialog), findsNothing);
      expect(c.dirty, isFalse);
      expect(c.prefs.showCompletedTasks, appliedValue,
          reason: '取消只回退最近一次未应用的改动，不撤销已应用的内容');
    });
  });
}

