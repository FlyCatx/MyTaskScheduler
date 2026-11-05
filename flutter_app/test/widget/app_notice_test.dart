// 0.3.0（R4-B）应用级左下角通知宿主：内容、交互、层级、生命周期与白底回归。
//
// 覆盖：
//   * 短成功一次完整显示；图标/文案/关闭对齐；关闭键鼠可达，关闭后输入焦点不动；
//   * 超长无空格路径换行且不挤掉关闭/动作按钮；
//   * 同批附件汇总一条（连续上报只更新同一条），失败文件名+原因可见、详情/关闭回调；
//   * 撤销有效期：有效期内可执行，过期后按钮禁用；
//   * 连续消息按顺序展示；dedupeKey 相同在短时间重复刷新只更新不堆叠；
//   * 模态打开时通知仍在最上层、卡片外点击落到模态遮罩而不是主界面；
//   * 卡片外没有白底（用纯色底图做像素对照），只有卡片圆角内绘制背景；
//   * 超出可见条数时标注“另有 N 条通知”并可展开。

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/execution/execution_actions.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_widgets.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/app_notice.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/attachment_notice.dart';

import '../execution/execution_test_support.dart';

const Color kBackground = Color(0xFF123456);

final DateTime _at = DateTime(2026, 11, 5, 18, 20);

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(900, 700),
  Widget? home,
  double textScale = 1.0,
  bool host = true,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  AppNotices.instance.resetForTest();
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    builder: host
        ? (context, child) => AppNoticeHost(
              controller: AppNotices.instance,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            )
        : null,
    home: home ??
        const Scaffold(
          body: ColoredBox(
            color: kBackground,
            child: SizedBox.expand(),
          ),
        ),
  );
  await tester.pumpWidget(RepaintBoundary(key: const Key('capture'), child: app));
  await tester.pumpAndSettle();
  // 每个用例结束后取消自动关闭计时器，避免假异步里留下 pending timer。
  addTearDown(() => AppNotices.instance.resetForTest());
}

Finder _card() => find.byKey(const Key('app-notice-dismiss'));

/// 通知卡片的实际矩形（消息文本最近的 Container 就是卡片本体）。
Rect _cardRect(WidgetTester tester) {
  final container = find
      .ancestor(
        of: find.byKey(const Key('app-notice-message')),
        matching: find.byType(Container),
      )
      .first;
  return tester.getRect(container);
}

void main() {
  testWidgets('短成功一次完整显示：图标/文案/关闭对齐，无 SnackBar', (tester) async {
    await _pump(tester);
    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: '已添加 7 个文件',
    );
    await tester.pumpAndSettle();

    expect(find.text('已添加 7 个文件'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const Key('app-notice-host')), findsOneWidget);

    final card = _cardRect(tester);
    final dismiss = tester.getRect(_card());
    expect(card.contains(dismiss.center), isTrue,
        reason: '关闭按钮必须在卡片内部');
    // 图标与单行文案的垂直中心对齐。
    final iconCenter = tester
        .getRect(find.byIcon(Icons.check_circle_outline))
        .center;
    final messageCenter =
        tester.getRect(find.byKey(const Key('app-notice-message'))).center;
    expect((iconCenter.dy - messageCenter.dy).abs(), lessThan(4));

    await tester.tap(_card());
    await tester.pumpAndSettle();
    expect(find.text('已添加 7 个文件'), findsNothing);
  });

  testWidgets('超长无空格路径换行，关闭/动作按钮不被挤掉', (tester) async {
    await _pump(tester, size: const Size(620, 600));
    final longPath = 'C:\\Users\\teacher\\Documents\\${'a' * 160}\\report.docx';
    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: '已导出到 $longPath',
      actionLabel: '打开所在文件夹',
      onAction: () {},
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '长路径必须换行而不是溢出');

    final message = tester.widget<Text>(find.byKey(const Key('app-notice-message')));
    expect(message.maxLines, isNull, reason: '短成功/长路径都完整显示，不设 maxLines');
    final messageHeight =
        tester.getRect(find.byKey(const Key('app-notice-message'))).height;
    expect(messageHeight, greaterThan(20), reason: '长路径应换行成多行');
    final dismiss = tester.getRect(_card());
    final action = tester.getRect(find.byKey(const Key('app-notice-action')));
    final cardRect = _cardRect(tester);
    expect(dismiss.right, lessThanOrEqualTo(cardRect.right + 0.5));
    expect(action.bottom, lessThanOrEqualTo(cardRect.bottom + 0.5));
    expect(
      tester.getRect(find.byKey(const Key('app-notice-host'))).width,
      greaterThan(0),
    );
  });

  testWidgets('同批附件汇总一条：连续上报只更新，失败文件名/原因/详情/关闭可用', (tester) async {
    var dismissed = 0;
    var details = 0;
    await _pump(tester);

    AppNotices.instance.showAttachment(
      feedback: AttachmentFeedback(
        conversationId: 'c1',
        at: _at,
        added: 7,
        failed: 0,
      ),
      onDismiss: () => dismissed++,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-notice')), findsOneWidget);
    expect(find.text('已添加 7 个文件'), findsOneWidget);

    // 同一批的第二次刷新：仍是同一张卡片，计数更新而不是堆叠。
    AppNotices.instance.showAttachment(
      feedback: AttachmentFeedback(
        conversationId: 'c1',
        at: _at,
        added: 6,
        failed: 2,
        failures: <String>[
          '附件6.2026年教师国情研修优秀成果申报表（田钦）.docx：文件 5824157 字节，超过输入上限 262144 字节（未做截断）',
          '课程表扫描件-2026-11-05.png：本地 OCR 未识别到文字，已保留原文件可重试',
        ],
        note: '材料超过单次请求上限，发送时请使用「分块分析」。',
      ),
      onDismiss: () => dismissed++,
      onShowDetails: () => details++,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-notice')), findsOneWidget,
        reason: '同一批附件只能有一条通知');
    expect(find.textContaining('失败 2 个'), findsOneWidget);
    expect(find.textContaining('5824157 字节'), findsOneWidget);
    expect(find.textContaining('分块分析'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attachment-notice-details')));
    expect(details, 1);
    await tester.tap(find.byKey(const Key('attachment-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(dismissed, 1);
    expect(find.byKey(const Key('attachment-notice')), findsNothing);
  });

  testWidgets('撤销：有效期内可执行，过期后禁用且不执行', (tester) async {
    var undone = 0;
    await _pump(tester);
    AppNotices.instance.show(
      kind: AppNoticeKind.info,
      message: '已修改任务',
      actionLabel: '撤销',
      actionValidFor: const Duration(seconds: 4),
      autoDismiss: const Duration(seconds: 4),
      onAction: () => undone++,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('app-notice-action')));
    await tester.pumpAndSettle();
    expect(undone, 1, reason: '有效期内撤销可执行');
    expect(find.text('已修改任务'), findsNothing, reason: '执行后通知关闭');

    // 过期：按钮保留但禁用，点击不执行。
    AppNotices.instance.show(
      kind: AppNoticeKind.info,
      message: '已修改任务（过期）',
      actionLabel: '撤销',
      actionValidFor: const Duration(seconds: 1),
      onAction: () => undone++,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final action = tester.widget<TextButton>(find.byKey(const Key('app-notice-action')));
    expect(action.onPressed, isNull, reason: '过期后撤销按钮禁用');
    await tester.tap(find.byKey(const Key('app-notice-action')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(undone, 1);
  });

  testWidgets('连续消息按顺序展示；dedupeKey 相同只更新一条', (tester) async {
    await _pump(tester, size: const Size(900, 800));
    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: '第一条',
      dedupeKey: 'same',
    );
    AppNotices.instance.show(
      kind: AppNoticeKind.info,
      message: '第二条',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-notice-message')), findsNWidgets(2));
    final first = tester.getRect(find.text('第一条'));
    final second = tester.getRect(find.text('第二条'));
    expect(first.top, lessThan(second.top), reason: '先投递的通知在上方');

    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: '第一条（刷新）',
      dedupeKey: 'same',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-notice-message')), findsNWidgets(2),
        reason: '同一 dedupeKey 不应堆叠');
    expect(find.text('第一条（刷新）'), findsOneWidget);
    expect(find.text('第一条'), findsNothing);
  });

  testWidgets('模态打开时通知在最上层可见；卡片外点击落到遮罩，不穿透主界面', (tester) async {
    var backgroundClicks = 0;
    await _pump(
      tester,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const Key('open-dialog'),
                onPressed: () {
                  showDialog<void>(
                    context: tester.element(find.byKey(const Key('open-dialog'))),
                    builder: (context) => const AlertDialog(
                      content: SizedBox(
                        width: 200,
                        height: 120,
                        child: Text('模态内容'),
                      ),
                    ),
                  );
                },
                child: const Text('打开弹窗'),
              ),
              TextButton(
                key: const Key('background-button'),
                onPressed: () => backgroundClicks++,
                child: const Text('主界面按钮'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-dialog')));
    await tester.pumpAndSettle();
    expect(find.text('模态内容'), findsOneWidget);

    AppNotices.instance.show(
      kind: AppNoticeKind.warning,
      message: '模态打开时的通知',
      autoDismiss: null,
    );
    await tester.pumpAndSettle();
    expect(find.text('模态打开时的通知'), findsOneWidget,
        reason: '宿主位于 Navigator 之上，弹窗打开时仍可见');

    // 通知卡片本身可点（关闭），模态仍在。
    await tester.tap(_card());
    await tester.pumpAndSettle();
    expect(find.text('模态内容'), findsOneWidget);

    // 重新投递后，点卡片外：应命中模态遮罩关闭弹窗，而不是穿透到主界面按钮。
    AppNotices.instance.show(
      kind: AppNoticeKind.warning,
      message: '再次显示',
      autoDismiss: null,
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 120));
    await tester.pumpAndSettle();
    expect(find.text('模态内容'), findsNothing, reason: '卡片外点击应由遮罩处理');
    expect(backgroundClicks, 0, reason: '卡片外点击不能穿透到主界面');
  });

  testWidgets('卡片外没有白底：纯色底图上只有卡片圆角内绘制背景', (tester) async {
    await _pump(tester, size: const Size(900, 700));
    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: '已添加 7 个文件',
    );
    await tester.pumpAndSettle();

    final dismiss = tester.getRect(_card());
    final cardRect = _cardRect(tester);
    expect(dismiss.center, isNotNull);
    final rgba = await _rgbaOf(tester);
    final width = tester.view.physicalSize.width.toInt();

    int at(int x, int y, int channel) => rgba[(y * width + x) * 4 + channel];
    bool isColor(int x, int y, Color color) {
      final argb = color.toARGB32();
      return at(x, y, 0) == ((argb >> 16) & 0xFF) &&
          at(x, y, 1) == ((argb >> 8) & 0xFF) &&
          at(x, y, 2) == (argb & 0xFF);
    }

    // 卡片四周（阴影之外）必须还是底图颜色：不能有独立白色矩形。
    final samplePoints = <Offset>[
      Offset(cardRect.left - 20, cardRect.center.dy),
      Offset(cardRect.right + 20, cardRect.center.dy),
      Offset(cardRect.center.dx, cardRect.top - 24),
      Offset(cardRect.center.dx, cardRect.bottom + 28),
      const Offset(60, 60),
      const Offset(800, 120),
    ];
    for (final point in samplePoints) {
      final x = point.dx.round();
      final y = point.dy.round();
      if (x < 0 || y < 0 || x >= width || y >= tester.view.physicalSize.height) {
        continue;
      }
      if (cardRect.inflate(14).contains(point)) continue;
      expect(isColor(x, y, kBackground), isTrue,
          reason: '卡片外的透明区域不能画白色/其它底色（x=$x y=$y）');
    }
    // 卡片内部是合法浅色（不是纯白），且与外部底图不同。
    // 取卡片左下内边距处：避开文字字形与圆角半径。
    final inside = Offset(cardRect.left + 16, cardRect.bottom - 5);
    expect(isColor(inside.dx.round(), inside.dy.round(), TsColors.readySoft),
        isTrue);
    expect(isColor(inside.dx.round(), inside.dy.round(), kBackground), isFalse);
  });

  testWidgets('关闭按钮键盘可达，且通知出现不移动输入焦点', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await _pump(
      tester,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            child: TextField(key: const Key('input'), focusNode: focusNode),
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    AppNotices.instance.show(
      kind: AppNoticeKind.info,
      message: '后台通知',
      autoDismiss: null,
    );
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue, reason: '通知出现不能抢输入焦点');

    // 键盘可达：关闭按钮在 Tab 顺序中，聚焦后 Space/Enter 能激活。
    final dismissFinder = find.byKey(const Key('app-notice-dismiss'));
    // 按钮内部的 Focus 是 IconButton 的 build 产物（在按钮 element 之下），
    // 从按钮内容节点取它最近的 Focus 节点，才能模拟键盘聚焦。
    final inner = find
        .descendant(of: dismissFinder, matching: find.byType(Icon))
        .first;
    final node = Focus.of(tester.element(inner));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue, reason: '关闭按钮必须可获得键盘焦点');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('后台通知'), findsNothing, reason: '键盘应能关闭通知');
    expect(tester.takeException(), isNull);
  });

  testWidgets('超出可见条数标注额外条数并可展开滚动', (tester) async {
    await _pump(tester, size: const Size(900, 520));
    for (var i = 0; i < 6; i++) {
      AppNotices.instance.show(
        kind: AppNoticeKind.info,
        message: '通知 $i',
        autoDismiss: null,
      );
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-notice-message')), findsNWidgets(
        AppNotices.maxVisible));
    expect(find.text('另有 2 条通知'), findsOneWidget);
    await tester.tap(find.byKey(const Key('app-notice-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-notice-message')), findsNWidgets(6));
    expect(find.text('收起较早通知'), findsOneWidget);
  });

  testWidgets('设置页一次性反馈也走应用级通知（不再有 SnackBar）', (tester) async {
    await _pump(
      tester,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('settings-feedback'),
              onPressed: () => showSettingsMessage(context, '已复制诊断信息'),
              child: const Text('触发设置反馈'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('settings-feedback')));
    await tester.pumpAndSettle();
    expect(find.text('已复制诊断信息'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // 让自动关闭计时器在用例内结算，避免假异步里遗留 pending timer。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('已复制诊断信息'), findsNothing);
  });

  testWidgets('执行计时反馈也走应用级通知（不再有 SnackBar）', (tester) async {
    final fixture = await TimerFixture.create(memory: true);
    addTearDown(fixture.close);
    await _pump(
      tester,
      home: Scaffold(
        body: Center(
          child: ExecutionActions(
            controller: fixture.timer,
            taskRef: taskRef(name: '整理需求'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('execution-action-start')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(const Key('app-notice-message')), findsOneWidget,
        reason: '计时反馈必须进左下通知宿主');
    expect(find.textContaining('整理需求'), findsWidgets);
    // 同一句提示重复投递只更新一条（不堆叠）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

Future<Uint8List> _rgbaOf(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('capture')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}
