import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

void main() {
  test('theme uses the shared Bézier shape for inputs and buttons', () {
    final theme = buildAppTheme();
    expect(theme.inputDecorationTheme.border, isA<BezierInputBorder>());
    expect(theme.inputDecorationTheme.focusedBorder, isA<BezierInputBorder>());
    expect(
      theme.textButtonTheme.style?.shape?.resolve(const {}),
      isA<BezierRoundedRectangleBorder>(),
    );
    expect(
      theme.outlinedButtonTheme.style?.shape?.resolve(const {}),
      isA<BezierRoundedRectangleBorder>(),
    );
    expect(theme.dialogTheme.shape, isA<BezierRoundedRectangleBorder>());
    expect(theme.popupMenuTheme.shape, isA<BezierRoundedRectangleBorder>());
  });

  testWidgets('Microsoft YaHei is the rendered family, not just a theme field',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return const Column(
              children: [
                Text('中文 English 123'),
                TextField(
                  decoration: InputDecoration(hintText: '提示'),
                ),
              ],
            );
          },
        ),
      ),
    ));
    final text = tester.widget<Text>(find.text('中文 English 123'));
    final defaultStyle =
        DefaultTextStyle.of(tester.element(find.text('中文 English 123')));
    expect(text.style?.fontFamily ?? defaultStyle.style.fontFamily,
        kUiFontFamily);
    expect(defaultStyle.style.fontFamilyFallback, containsAll(kUiFontFallback));

    final theme = Theme.of(tester.element(find.byType(TextField)));
    expect(theme.textTheme.bodyMedium?.fontFamily, kUiFontFamily);
    expect(theme.textTheme.titleMedium?.fontFamily, kUiFontFamily);
    expect(theme.inputDecorationTheme.hintStyle?.fontFamily, kUiFontFamily);
    expect(theme.tooltipTheme.textStyle?.fontFamily, kUiFontFamily);
    expect(theme.textTheme.titleMedium?.fontFamilyFallback,
        containsAll(kUiFontFallback));
  });
}

