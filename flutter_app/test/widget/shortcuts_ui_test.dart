import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/shortcuts.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_shortcuts_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

Future<SettingsController> controller(WidgetTester tester) async {
  final c = SettingsController(
    store: SettingsStore(createTempDataDir('shortcuts_ui')),
    bridge: FakeSettingsBridge(),
  );
  await tester.runAsync(c.load);
  addTearDown(c.dispose);
  return c;
}

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('record a new chord and persist it into the settings draft',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await controller(tester);
    await tester.pumpWidget(host(SettingsShortcutsPage(controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(
        const Key('shortcut-record-${AppCommands.newConversation}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut-recorder-value')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Ctrl+J'), findsWidgets);
    await tester.tap(find.byKey(const Key('shortcut-recorder-save')));
    await tester.pumpAndSettle();

    final chord = c.draft.prefs.shortcutOverrides[AppCommands.newConversation];
    expect(chord?.label, 'Ctrl+J');
    expect(c.dirty, isTrue);
  });

  testWidgets('conflicting chord is rejected with the other action name',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await controller(tester);
    await tester.pumpWidget(host(SettingsShortcutsPage(controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(
        const Key('shortcut-record-${AppCommands.openSettings}')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.tap(find.byKey(const Key('shortcut-recorder-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('新建会话'), findsWidgets);
    expect(c.draft.prefs.shortcutOverrides[AppCommands.openSettings], isNull,
        reason: '冲突配置不得写入草稿');
  });

  testWidgets('clear binding and reset to default are explicit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await controller(tester);
    await tester.pumpWidget(host(SettingsShortcutsPage(controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(
        const Key('shortcut-clear-${AppCommands.toggleChart}')));
    await tester.pumpAndSettle();
    expect(c.draft.prefs.shortcutOverrides.containsKey(AppCommands.toggleChart),
        isTrue);
    expect(c.draft.prefs.shortcutOverrides[AppCommands.toggleChart], isNull);
    expect(find.text('未绑定'), findsWidgets);

    await tester.tap(find.byKey(
        const Key('shortcut-reset-${AppCommands.toggleChart}')));
    await tester.pumpAndSettle();
    expect(c.draft.prefs.shortcutOverrides.containsKey(AppCommands.toggleChart),
        isFalse);
    expect(find.text('Ctrl+G'), findsOneWidget);
  });

  testWidgets('fixed Esc has no recording control and cannot be cleared',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await controller(tester);
    await tester.pumpWidget(host(SettingsShortcutsPage(controller: c)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shortcut-record-${AppCommands.closeOverlay}')),
        findsNothing);
    expect(find.byKey(const Key('shortcut-clear-${AppCommands.closeOverlay}')),
        findsNothing);
    expect(find.text('Esc'), findsOneWidget);
  });
}

