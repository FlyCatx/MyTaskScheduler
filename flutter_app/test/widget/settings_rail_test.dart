// Focused check: the settings rail renders an icon for every entry.
//
// This exists because the packaged build once showed only two of the seven rail icons
// (存储 and 关于) while the others were blank, which no amount of position assertions
// would have caught.
//
// Updated for 0.0.4: the dialog now needs a `SettingsController`. The controller is
// built on an in-memory/native-free fake bridge, so the test never touches ts_bridge.dll
// and never depends on a real data directory.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

void main() {
  testWidgets('every rail entry renders its icon', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = SettingsController(
      store: SettingsStore(createTempDataDir('settings_rail')),
      bridge: FakeSettingsBridge(),
    );
    await tester.runAsync(controller.load);
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SettingsDialog(controller: controller)),
    ));
    await tester.pumpAndSettle();

    for (final section in SettingsSection.values) {
      final finder = find.byIcon(section.icon);
      expect(finder, findsOneWidget, reason: '「${section.label}」缺少图标');
      final icon = tester.widget<Icon>(finder);
      final size = tester.getSize(finder);
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
      expect(icon.size, 17);
      expect(icon.color, isNotNull);
      // Guard against an invisible icon (same colour as the rail background).
      expect(icon.color, isNot(TsColors.sidebar));
      expect(icon.color, isNot(Colors.transparent));
    }
  });
}

