// OCR 配置弹窗的**布局**测试（0.3.0 任务 03B）。
//
// 只做布局/可达性断言：OCR 的逻辑用例（解析、缓存、取消、校对、部分失败…）仍在
//
// test/ocr/ocr_import_dialog_test.dart（ocr-dev2 的目录）里，本文件不改它们。
//
// 验收点：
//   * 选择阶段：格式/文字层说明并入文件控件（按钮 Tooltip + 控件内简短提示），
//     初始页两段常驻说明（文件格式+文字层处理、后续联网边界）整段删除、不占位；
//     模型发送边界保留在可随时打开的“使用说明与联网边界”入口（标题栏帮助）；
//   * 顶部 _boundaryNotice 与“识别语言：…”常驻说明已删除，且没有留下空白；
//   * 页计划列表不再固定 maxHeight: 168：长列表独立滚动、短列表按内容收缩，
//     16 页样例显示的行数明显多于原来约 7 行；
//   * 文件选择 / 页范围 / DPI / 密码 / 建议页范围 / 开始识别 / 底部按钮始终可达；
//   * 极矮窗口允许整表滚动；
//   * 窄窗 + 1.5 倍字号不溢出，页码/原因/说明三列不互相覆盖。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_page_detection.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_service.dart';
import 'package:taskscheduler_flutter/src/ui/ocr/ocr_import_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../ocr/support/fake_ocr.dart';

/// 与 references/05.png 对应的混合文档：共 16 页，7 页需要 OCR，9 页沿用文字层。
/// 第 7 页文字层过少，第 10–15 页没有文字层。
const int kPageCount = 16;
const List<int> kNeedsOcrPages = <int>[7, 10, 11, 12, 13, 14, 15];

String _longText(int page) =>
    // 与 references/05.png 同结构：首行页码（页眉）、中间正文、末行重复表头。
    // 文字层检测的页眉启发式会把首/末行当页眉，中间正文长度足够 → “文字层充足”。
    '第 $page 页\n本页正文：2026 年 11 月 4 日完成课堂观察记录与研修反思，'
    '正文包含完整的申报材料文字，文字层可信。\n教师研修优秀成果申报表';

OcrPdfPageTexts _mixedDocument() => OcrPdfPageTexts(
      pageCount: kPageCount,
      texts: <int, String>{
        for (var page = 1; page <= kPageCount; page++)
          if (page == 7)
            7: '第 7 页'
          else if (!kNeedsOcrPages.contains(page))
            page: _longText(page),
      },
    );

void main() {
  late Directory docRoot;
  late FakeOcrClient fakeClient;
  late OcrService service;

  setUp(() async {
    docRoot = await Directory.systemTemp.createTemp('ocr_layout_docs_');
    fakeClient = FakeOcrClient(host: fakeHostLocation());
    service = OcrService(
      dataRoot: null,
      limits: fastOcrLimits,
      discovery: OcrHostDiscovery(
        location: fakeHostLocation(),
        attempted: const <OcrHostCandidate>[],
      ),
      clientFactory: (_) => fakeClient,
      enableCache: false,
      pdfTextReader: (path) async => _mixedDocument(),
    );
  });

  tearDown(() async {
    if (await docRoot.exists()) await docRoot.delete(recursive: true);
  });

  File writeFile(String name, String content) {
    final file = File('${docRoot.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file;
  }

  Future<void> setSurface(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TsColors.apply(Brightness.light);
    addTearDown(() => TsColors.apply(Brightness.light));
  }

  /// 有界 pump：探测本地 OCR 组件时进度指示器一直在转，pumpAndSettle 永远不会停。
  Future<void> settle(WidgetTester tester,
      {Duration step = const Duration(milliseconds: 120), int maxSteps = 40}) async {
    await tester.pump();
    for (var i = 0; i < maxSteps; i++) {
      await tester.pump(step);
    }
  }

  Future<void> openConfigure(WidgetTester tester, String fileName) async {
    final file = writeFile(fileName, 'dummy-bytes');
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-ocr'),
              onPressed: () => showOcrImportDialog(
                context,
                service: service,
                pickFiles: () async => <String>[file.path],
                onConfirm: (_) async => true,
              ),
              child: const Text('打开 OCR'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-ocr')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('ocr-pick-file')));
    await settle(tester);
  }

  /// 打开弹窗但不选文件：停留在“选择文件”阶段。
  Future<void> openSelect(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-ocr'),
              onPressed: () => showOcrImportDialog(
                context,
                service: service,
                pickFiles: () async => const <String>[],
                onConfirm: (_) async => true,
              ),
              child: const Text('打开 OCR'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-ocr')));
    await settle(tester);
  }

  Rect cardRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('ocr-import-card')));

  bool insideCard(WidgetTester tester, Key key) {
    final rect = tester.getRect(find.byKey(key));
    final card = cardRect(tester);
    return card.contains(rect.topLeft) &&
        card.contains(rect.bottomRight - const Offset(1, 1));
  }

  int visiblePlanRows(WidgetTester tester) {
    var count = 0;
    for (var page = 1; page <= kPageCount; page++) {
      final finder = find.byKey(Key('ocr-page-plan-row-$page'));
      if (finder.evaluate().isEmpty) continue;
      if (insideCard(tester, Key('ocr-page-plan-row-$page'))) count++;
    }
    return count;
  }

  testWidgets('选择阶段：格式提示并入文件控件，联网边界移入可查看帮助入口',
      (tester) async {
    await setSurface(tester, const Size(1280, 900));
    await openSelect(tester);

    // 选择阶段本身可见：选文件按钮、文件名占位、控件内简短格式/文字层提示。
    expect(find.byKey(const Key('ocr-pick-file')), findsOneWidget);
    expect(find.byKey(const Key('ocr-file-name')), findsOneWidget);
    expect(find.byKey(const Key('ocr-file-hint')), findsOneWidget);
    expect(find.textContaining('文本型 PDF 复用原文字层'), findsWidgets);
    // 格式说明并入按钮 Tooltip（可随时查看，不再占一整段常驻正文）。
    expect(
      find.byTooltip('支持扫描型/混合文字层 PDF、PNG、JPEG；'
          '文本型 PDF 优先使用原有文字层，不重复识别。'),
      findsOneWidget,
    );

    // 旧的两段常驻说明（格式+文字层处理、后续联网边界）必须整段消失。
    expect(find.textContaining('支持扫描型 PDF、混合文字/扫描 PDF'), findsNothing);
    expect(find.textContaining('识别与选择文件都在本机完成'), findsNothing);
    expect(find.textContaining('只有你主动让已配置的模型分析材料时'), findsNothing);
    expect(find.byKey(const Key('ocr-local-boundary')), findsNothing);

    // 边界说明保留一处可达入口：标题栏帮助。
    expect(find.byKey(const Key('ocr-help')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ocr-help')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-help-dialog')), findsOneWidget);
    expect(find.byKey(const Key('ocr-help-body')), findsOneWidget);
    expect(find.byKey(const Key('ocr-help-boundary')), findsOneWidget);
    expect(find.textContaining('只有你主动让已配置的模型分析材料时'), findsWidgets);
    expect(find.textContaining('本机完成'), findsWidgets);
    await tester.tap(find.byKey(const Key('ocr-help-close')));
    await settle(tester);
    expect(find.byKey(const Key('ocr-help-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('16 页混合 PDF：两段常驻说明已删除，页计划列表吃掉剩余高度',
      (tester) async {
    await setSurface(tester, const Size(1280, 900));
    await openConfigure(tester, 'scan.pdf');

    // 配置阶段
    expect(find.byKey(const Key('ocr-detection-summary')), findsOneWidget);
    expect(find.byKey(const Key('ocr-page-plan')), findsOneWidget);

    // 1) 标黄的两段常驻说明整段删除（含空白间距）：既不显示也不占位。
    expect(find.byKey(const Key('ocr-boundary-notice')), findsNothing);
    expect(find.byKey(const Key('ocr-languages')), findsNothing);
    expect(find.textContaining('识别语言：'), findsNothing);
    expect(find.textContaining('本地离线：识别在你自己的电脑上完成'), findsNothing);
    expect(find.textContaining('联网边界'), findsNothing);
    // 仍保留“本地处理 / 之后主动分析才联网”的必要说明（帮助入口可达）。
    expect(find.byKey(const Key('ocr-local-boundary')), findsNothing,
        reason: '配置阶段不重复常驻说明；模型发送边界在标题栏帮助入口查看');
    expect(find.byKey(const Key('ocr-help')), findsOneWidget,
        reason: '帮助入口在配置阶段也必须可达');
    // 删除后不留空白：文件行仍紧接在主体顶部。
    expect(find.byKey(const Key('ocr-file-hint')), findsNothing,
        reason: '已选文件后不显示选择阶段的格式提示');

    // 2) 页列表获得剩余高度：不再固定在 168。
    final planRect = tester.getRect(find.byKey(const Key('ocr-page-plan')));
    expect(planRect.height, greaterThan(260),
        reason: '页计划列表必须吃掉删除文案与底部富余的高度');

    // 3) 16 页样例显示的行数明显多于原来的约 7 行。
    final rows = visiblePlanRows(tester);
    expect(rows, greaterThan(7), reason: '16 页样例应显示多于原来的约 7 行，实测 $rows 行');
    expect(rows, greaterThanOrEqualTo(10), reason: '实测只显示 $rows 行');

    // 4) 所有可执行控件都在卡片内，无需滚动即可到达。
    for (final key in <Key>[
      const Key('ocr-dialog-close'),
      const Key('ocr-pick-file'),
      const Key('ocr-page-spec'),
      const Key('ocr-dpi'),
      const Key('ocr-password'),
      const Key('ocr-apply-suggested-pages'),
      const Key('ocr-start'),
      const Key('ocr-footer-close'),
    ]) {
      expect(find.byKey(key), findsOneWidget);
      expect(insideCard(tester, key), isTrue, reason: '$key 必须在卡片内可见');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('页计划列表长时独立滚动：滚动它不影响页范围/DPI/密码', (tester) async {
    await setSurface(tester, const Size(1280, 900));
    await openConfigure(tester, 'scan.pdf');

    final cardBefore = cardRect(tester);
    final pageSpecBefore = tester.getRect(find.byKey(const Key('ocr-page-spec')));
    expect(find.byKey(const Key('ocr-page-plan-row-1')), findsOneWidget);

    // 列表自己的 Scrollable（不是外层页面）。
    final listScrollable = find.descendant(
      of: find.byKey(const Key('ocr-page-plan')),
      matching: find.byType(Scrollable),
    );
    expect(listScrollable, findsOneWidget);
    final scrollState = tester.state<ScrollableState>(listScrollable);
    await tester.drag(listScrollable, const Offset(0, -160));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(scrollState.position.pixels, greaterThan(0),
        reason: '长列表必须能独立滚动');
    // 滚动后后面的页进入视口（前几行离开并被回收，说明是真滚动了）。
    expect(find.byKey(const Key('ocr-page-plan-row-12')), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('ocr-page-spec'))), pageSpecBefore,
        reason: '列表滚动不能带动页范围/DPI 这些固定控件');
    expect(cardRect(tester), cardBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单页图片：页列表按内容收缩，底部控件紧接其后而不是被推到最底',
      (tester) async {
    await setSurface(tester, const Size(1280, 900));
    // 图片输入只有 1 页；detectPages 对图片直接给出单页计划。
    await openConfigure(tester, 'scan.png');
    expect(find.byKey(const Key('ocr-page-plan')), findsOneWidget);
    expect(find.byKey(const Key('ocr-page-plan-row-1')), findsOneWidget);
    final planRect = tester.getRect(find.byKey(const Key('ocr-page-plan')));
    expect(planRect.height, lessThan(80), reason: '短列表按内容收缩，不占满剩余高度');
    expect(insideCard(tester, const Key('ocr-start')), isTrue);
    expect(insideCard(tester, const Key('ocr-password')), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('极矮窗口：整表滚动，开始识别与底部按钮仍然可达', (tester) async {
    await setSurface(tester, const Size(900, 420));
    await openConfigure(tester, 'scan.pdf');

    // 极矮时走整页滚动分支：配置内容外层是 SingleChildScrollView。
    expect(
      find.ancestor(
        of: find.byKey(const Key('ocr-page-spec')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsWidgets,
      reason: '极矮窗口必须允许整表滚动',
    );
    // 列表在整表滚动里被限高，不会把页面撑到无限高。
    final planRect = tester.getRect(find.byKey(const Key('ocr-page-plan')));
    expect(planRect.height, lessThanOrEqualTo(130));
    expect(planRect.height, greaterThan(80));
    // 底部按钮（footer）固定在卡片底部，始终可达。
    expect(insideCard(tester, const Key('ocr-start')), isTrue);
    expect(insideCard(tester, const Key('ocr-footer-close')), isTrue);
    // 整表可以滚动到密码/建议页范围。
    await tester.dragUntilVisible(
      find.byKey(const Key('ocr-apply-suggested-pages')),
      find.byType(SingleChildScrollView).first,
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗 + 1.5 倍字号：页行三列不重叠、无溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await setSurface(tester, const Size(400, 720));
    await openConfigure(tester, 'scan.pdf');

    expect(tester.takeException(), isNull, reason: '窄窗 + 大字号不得溢出');
    expect(find.byKey(const Key('ocr-page-plan-row-1')), findsOneWidget);
    // 页码 / 原因 / 说明三段文字不互相覆盖。
    final pageText = tester.getRect(find.text('第 1 页').first);
    final reasonText = tester.getRect(find.text('文字层充足').first);
    expect(pageText.right, lessThanOrEqualTo(reasonText.left + 1));
    // 字号放大后行更高、显示的页更少，但列表仍在有界容器里可滚动、不溢出。
    expect(
      find.descendant(
        of: find.byKey(const Key('ocr-page-plan')),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
    expect(insideCard(tester, const Key('ocr-start')), isTrue);
  });
}
