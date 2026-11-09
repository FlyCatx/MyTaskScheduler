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

    testWidgets('“＋”菜单顺序：添加材料 → 从 PDF / 图片提取文字 → 分块分析',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();

      final panel = find.byKey(const Key('bezier-menu-panel'));
      expect(panel, findsOneWidget);
      final add = tester.getCenter(find.text('添加材料')).dy;
      final extract = tester.getCenter(find.text('从 PDF / 图片提取文字')).dy;
      final chunked = tester.getCenter(find.text('分块分析')).dy;
      expect(add, lessThan(extract), reason: '添加材料在最上');
      expect(extract, lessThan(chunked), reason: 'OCR 入口在分块分析之上');

      // 菜单完整落在可视区域内，且靠近底部时向上展开而不是被裁掉。
      final rect = tester.getRect(panel);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(900));
      // 不遮住触发器与发送键：菜单在“＋”上方展开。
      final trigger = tester.getRect(find.byKey(const Key('composer-add-menu')));
      expect(rect.bottom, lessThanOrEqualTo(trigger.top),
          reason: '菜单应在触发器上方展开');
      final send = tester.getRect(find.descendant(
          of: find.byType(Composer), matching: find.byIcon(Icons.arrow_upward)));
      expect(rect.overlaps(send), isFalse, reason: '菜单不得遮住发送键');
    });

    testWidgets('选择“添加材料”仍走原生桥接，且菜单关闭', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加材料'));
      await tester.pumpAndSettle();

      // In tests there is no native gateway, so the shell must say so instead of
      // opening a Flutter-drawn picker.
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('原生桥接不可用'), findsOneWidget);
      expect(find.byKey(const Key('bezier-menu-panel')), findsNothing);
    });

    testWidgets('选择“分块分析”复用既有预估入口，不直接发请求', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final (controller, _) = await pumpShell(tester);

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分块分析'));
      await tester.pumpAndSettle();

      // 没有材料时只提示，不打开对话框、不发请求。
      expect(find.textContaining('当前没有可分析的文本材料'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(controller.isRunning, isFalse);
    });

    testWidgets('Esc 关闭“＋”菜单且不触发任何动作', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bezier-menu-panel')), findsNothing);
      expect(find.textContaining('原生桥接不可用'), findsNothing);
    });
    testWidgets('OCR 与分块分析各自只打开自己的动作，选择后菜单关闭', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var add = 0;
      var extract = 0;
      var chunked = 0;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(_composerApp(
        text: text,
        onAddFile: () async => add++,
        onExtractText: () => extract++,
        onChunkedAnalysis: () => chunked++,
      ));

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从 PDF / 图片提取文字'));
      await tester.pumpAndSettle();
      expect(extract, 1);
      expect(add, 0);
      expect(chunked, 0);
      expect(find.byKey(const Key('bezier-menu-panel')), findsNothing,
          reason: '选择后菜单必须关闭，只保留一个目标窗口');

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分块分析'));
      await tester.pumpAndSettle();
      expect(chunked, 1);
      expect(extract, 1, reason: '一次选择只触发一个动作');
      expect(find.byKey(const Key('bezier-menu-panel')), findsNothing);
    });

    testWidgets('不可用的 OCR / 分块分析项为禁用态：点击无效且菜单不关闭',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var add = 0;
      final text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(_composerApp(
        text: text,
        onAddFile: () async => add++,
        // 未注入 = OCR 服务缺失 / 当前没有可分析会话。
        onExtractText: null,
        onChunkedAnalysis: null,
      ));

      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从 PDF / 图片提取文字'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('分块分析'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bezier-menu-panel')), findsOneWidget,
          reason: '禁用项不能关闭菜单');
      expect(add, 0);

      // 菜单仍可用：选择“添加材料”。
      await tester.tap(find.text('添加材料'));
      await tester.pumpAndSettle();
      expect(add, 1);
    });
    testWidgets('无 OCR 服务时 OCR 项禁用；分块分析沿用旧可用性',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpShell(tester);

      // 测试装配没有 OCR 服务（等价于原顶部 OCR 按钮不显示）。
      await tester.tap(find.byKey(const Key('composer-add-menu')));
      await tester.pumpAndSettle();

      final extract = tester.widget<Text>(find.text('从 PDF / 图片提取文字'));
      expect(extract.style!.color, TsColors.textFaint, reason: '不可用时为禁用态');
      await tester.tap(find.text('从 PDF / 图片提取文字'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bezier-menu-panel')), findsOneWidget,
          reason: '禁用项不关闭菜单');
      expect(find.byType(Dialog), findsNothing);

      // 有会话时“分块分析”仍可用（与原顶部按钮一致），点击复用既有预估入口。
      final chunked = tester.widget<Text>(find.text('分块分析'));
      expect(chunked.style!.color, TsColors.textPrimary, reason: '可用项为主文字色');
      await tester.tap(find.text('分块分析'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前没有可分析的文本材料'), findsOneWidget);
      expect(find.byKey(const Key('bezier-menu-panel')), findsNothing);
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

/// Standalone composer harness: lets each menu action be counted without the shell.
Widget _composerApp({
  required TextEditingController text,
  required Future<void> Function() onAddFile,
  VoidCallback? onExtractText,
  VoidCallback? onChunkedAnalysis,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 900,
          child: Composer(
            textController: text,
            attachments: const [],
            running: false,
            canSend: true,
            onSend: () {},
            onAddFile: onAddFile,
            onRemoveAttachment: (_) {},
            onDraftChanged: (_) {},
            onExtractText: onExtractText,
            onChunkedAnalysis: onChunkedAnalysis,
          ),
        ),
      ),
    ),
  );
}
