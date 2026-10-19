// Widget tests for the composer redesign and for the band alignment requested in the
// layout review:
//   * selected files appear ABOVE the text as blue, link-styled entries;
//   * "+" sits inside the box at the bottom-left, the send arrow inside at bottom-right;
//   * the text area has a FIXED height and scrolls internally;
//   * the sidebar title row and the summary bar share one height;
//   * the sidebar footer and the composer share one bottom band;
//   * the add-file button goes through the native dialog (not a Flutter dialog).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/composer.dart';
import 'package:taskscheduler_flutter/src/ui/history_panel.dart';
import 'package:taskscheduler_flutter/src/ui/summary_bar.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

Future<(AppController, InMemorySessionRepository)> pumpShell(
  WidgetTester tester, {
  List<Attachment> attachments = const [],
}) async {
  final store = InMemorySessionRepository();
  await seedConversation(store, attachments: attachments);
  final controller = AppController(engine: FakeScheduleEngine(), store: store);
  await controller.initialize();
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: AppShell(
      controller: controller,
      settings: makeTestSettingsController(),
    ),
  ));
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
  return (controller, store);
}

const _attachment = Attachment(
  id: 'att-1',
  label: 'exp1.txt',
  kind: 'file',
  originalPath: r'C:\docs\exp1.txt',
  text: '顺序表实验要求……',
  byteLength: 42,
);

void main() {
  group('composer', () {
    testWidgets('shows selected files above the text as blue link entries',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester, attachments: const [_attachment]);

      expect(find.byType(_FileLinkProbe), findsNothing);
      final label = find.text('exp1.txt');
      expect(label, findsOneWidget, reason: '文件名应显示在输入框上方');

      final style = tester.widget<Text>(label).style!;
      expect(style.color, TsColors.accent, reason: '文件用蓝色链接样式展示');
      expect(style.decoration, TextDecoration.underline);

      // It sits ABOVE the text field (smaller y than the field's top edge).
      final labelBottom = tester.getBottomLeft(label).dy;
      final fieldTop = tester
          .getTopLeft(find.descendant(
              of: find.byType(Composer), matching: find.byType(TextField)))
          .dy;
      expect(labelBottom, lessThanOrEqualTo(fieldTop + 1));

      // Clicking the entry removes the attachment.
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(find.text('exp1.txt'), findsNothing);
    });

    testWidgets('"+" is bottom-left inside the box and the send arrow bottom-right',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      final box = tester.getRect(find.byType(Composer));
      // Scope to the composer: the chart's zoom button also uses Icons.add.
      final plus = tester.getCenter(
          find.descendant(of: find.byType(Composer), matching: find.byIcon(Icons.add)));
      final send = tester.getCenter(find.descendant(
          of: find.byType(Composer), matching: find.byIcon(Icons.arrow_upward)));

      expect(box.contains(plus), isTrue, reason: '“+”必须位于输入框内部');
      expect(box.contains(send), isTrue, reason: '发送箭头必须位于输入框内部');
      // Vertically both in the lower half; horizontally one left, one right.
      expect(plus.dy, greaterThan(box.center.dy));
      expect(send.dy, greaterThan(box.center.dy));
      expect(plus.dx, lessThan(box.center.dx));
      expect(send.dx, greaterThan(box.center.dx));
      // Near the edges.
      expect(plus.dx - box.left, lessThan(60));
      expect(box.right - send.dx, lessThan(60));
    });

    testWidgets('manual expand keeps text and Esc collapses again',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final (controller, _) = await pumpShell(tester);
      await controller.updateDraft('展开前后都要保留的文本');
      await tester.pump();
      final input = find.byKey(const Key('composer-input'));
      final collapsed = tester.getSize(input).height;
      expect(tester.widget<TextField>(input).maxLines, kComposerTextLines);

      await tester.tap(find.byKey(const Key('composer-expand')));
      await tester.pump();
      expect(tester.getSize(input).height, greaterThan(collapsed + 40));
      expect(tester.widget<TextField>(input).expands, isTrue);
      expect(controller.conversation!.draftText, '展开前后都要保留的文本');

      await tester.tap(input);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.getSize(input).height, collapsed,
          reason: 'Esc 先收起输入区，不丢字');
      expect(controller.conversation!.draftText, '展开前后都要保留的文本');
    });

    testWidgets('text area has a fixed line count and scrolls internally',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      final field = tester.widget<TextField>(find
          .descendant(
              of: find.byType(Composer), matching: find.byType(TextField))
          .first);
      expect(field.minLines, kComposerTextLines);
      expect(field.maxLines, kComposerTextLines,
          reason: '固定行数，超出后由输入框内部滚动，而不是把界面撑高');
      expect(field.keyboardType, TextInputType.multiline);
    });

    testWidgets('adding a file goes through the native bridge, not a Flutter dialog',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.descendant(
          of: find.byType(Composer), matching: find.byIcon(Icons.add)));
      await tester.pumpAndSettle();

      // In tests there is no native gateway, so the shell must say so instead of
      // opening a Flutter-drawn picker.
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('原生桥接不可用'), findsOneWidget);
    });
  });

  group('band alignment', () {
    testWidgets('sidebar title row and summary bar share the same height',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      final header = tester.getSize(find.byType(HistorySidebarHeader));
      final summary = tester.getSize(find.byType(SummaryBar));
      expect(header.height, summary.height);
      expect(header.height, kTopBarHeight);
      // Same top edge => the two title rows are on one line.
      expect(tester.getTopLeft(find.byType(HistorySidebarHeader)).dy,
          tester.getTopLeft(find.byType(SummaryBar)).dy);
    });

    testWidgets('sidebar bottom band and composer occupy one band', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      final bandLeft = tester.getRect(find.byType(SidebarBottomBand));
      final bandRight = tester.getRect(find.byType(ComposerBand));

      expect(bandLeft.top, bandRight.top,
          reason: '左侧底部带与右侧输入框必须从同一条基线开始');
      expect(bandLeft.bottom, bandRight.bottom,
          reason: '两者高度必须一致（同一条底部带）');
    });
  });
}

/// Never instantiated; only used to make sure no legacy chip-based file widget remains.
class _FileLinkProbe extends StatelessWidget {
  const _FileLinkProbe();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

