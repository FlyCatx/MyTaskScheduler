// 任务 02：侧栏内附件反馈与侧栏收起时的紧凑提示（纯展示组件）。
//
// 覆盖：
//   * 成功/失败计数、失败文件名+短原因换行、最多默认 2 条、查看全部/详情入口；
//   * onShowDetails == null 时隐藏入口；不自动消失（由用户关闭）；
//   * 紧凑态：失败时显示第一条失败；只有 note 时显示 note（可执行说明），单行省略；
//   * 窄侧栏 + 1.5 倍字号不溢出；
//   * 关闭按钮不抢输入焦点（通知消失后输入框仍在焦点）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/attachment_notice.dart';

AttachmentFeedback _feedback({
  int added = 0,
  int failed = 0,
  List<String> failures = const <String>[],
  String? note,
}) =>
    AttachmentFeedback(
      conversationId: 'conv-1',
      added: added,
      failed: failed,
      failures: failures,
      note: note,
      at: DateTime(2026, 11, 5, 18, 20),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 300,
  double textScale = 1.0,
}) async {
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: appChild!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空反馈不占位', (tester) async {
    await _pump(
      tester,
      AttachmentNotice(feedback: _feedback(), onDismiss: () {}),
    );
    expect(find.byKey(const Key('attachment-notice')), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('只有成功：显示“已添加 N 个文件”，可关闭且不会自动消失', (tester) async {
    var dismissed = 0;
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(added: 2),
        onDismiss: () => dismissed++,
      ),
    );
    expect(find.text('已添加 2 个文件'), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-details')), findsNothing,
        reason: '没有失败时不显示详情入口');

    // 不自动消失：等 30 秒仍在（由用户关闭或应用层控制）。
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('已添加 2 个文件'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attachment-notice-dismiss')));
    expect(dismissed, 1);
  });

  testWidgets('一成一败：摘要含成功/失败计数、失败文件名与原因可见、可查看详情', (tester) async {
    var details = 0;
    const failure =
        '附件6.2026年教师国情研修优秀成果申报表（田钦）.docx：'
        '文件 5824157 字节，超过输入上限 262144 字节（未做截断），请拆分后重试';
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(added: 1, failed: 1, failures: const [failure]),
        onDismiss: () {},
        onShowDetails: () => details++,
      ),
    );
    expect(find.textContaining('失败 1 个'), findsOneWidget);
    expect(find.textContaining('成功 1 个'), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-failure-0')), findsOneWidget);
    expect(find.textContaining('5824157 字节'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attachment-notice-details')));
    expect(details, 1);
  });

  testWidgets('失败超过 2 条：默认只展示 2 条，其余通过“查看全部”', (tester) async {
    var details = 0;
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(
          failed: 3,
          failures: const ['a.docx：太大', 'b.pdf：加密', 'c.png：识别不到文字'],
        ),
        onDismiss: () {},
        onShowDetails: () => details++,
      ),
    );
    expect(find.byKey(const Key('attachment-notice-failure-0')), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-failure-1')), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-failure-2')), findsNothing);
    expect(find.text('查看全部 3 条失败'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attachment-notice-details')));
    expect(details, 1);
  });

  testWidgets('onShowDetails 为 null 时不显示详情入口', (tester) async {
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(
          failed: 3,
          failures: const ['a.docx：太大', 'b.pdf：加密', 'c.png：识别不到文字'],
        ),
        onDismiss: () {},
      ),
    );
    expect(find.byKey(const Key('attachment-notice-details')), findsNothing);
    expect(find.textContaining('查看全部'), findsNothing);
  });

  testWidgets('note 单独显示：例如“发送时使用分块分析”', (tester) async {
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(
          added: 1,
          note: '文本超过单次请求上限，发送时使用分块分析',
        ),
        onDismiss: () {},
      ),
    );
    expect(find.byKey(const Key('attachment-notice-note')), findsOneWidget);
    expect(find.textContaining('发送时使用分块分析'), findsOneWidget);
  });

  testWidgets('窄侧栏 + 1.5 倍字号：长文件名换行且不溢出', (tester) async {
    await _pump(
      tester,
      AttachmentNotice(
        feedback: _feedback(
          added: 1,
          failed: 2,
          failures: const [
            '附件6.2026年教师国情研修优秀成果申报表（田钦）.docx：文件 5824157 字节，超过输入上限 262144 字节（未做截断）',
            '课程表扫描件-2026-11-05.png：本地 OCR 未识别到文字，已保留原文件可重试',
          ],
        ),
        onDismiss: () {},
        onShowDetails: () {},
      ),
      width: 240,
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull, reason: '窄侧栏大字号不能溢出');
    expect(find.byKey(const Key('attachment-notice')), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-failure-0')), findsOneWidget);
  });

  testWidgets('紧凑态：失败时显示第一条失败（含文件名），note 省略保持高度稳定', (tester) async {
    var dismissed = 0;
    var details = 0;
    await _pump(
      tester,
      CompactAttachmentNotice(
        feedback: _feedback(
          added: 2,
          failed: 3,
          failures: const [
            '附件6.2026年教师国情研修优秀成果申报表（田钦）.docx：文件过大',
            'b.pdf：加密',
            'c.png：识别不到文字',
          ],
          note: '文本超过单次请求上限，发送时使用分块分析',
        ),
        onDismiss: () => dismissed++,
        onShowDetails: () => details++,
      ),
      width: 1100,
    );
    expect(find.byKey(const Key('attachment-notice-compact')), findsOneWidget);
    expect(find.textContaining('成功 2'), findsOneWidget);
    expect(find.textContaining('失败 3'), findsOneWidget);
    expect(
        find.byKey(const Key('attachment-notice-compact-failure')),
        findsOneWidget);
    expect(find.textContaining('申报表'), findsOneWidget);
    expect(find.byKey(const Key('attachment-notice-compact-note')), findsNothing,
        reason: '有失败项时显示失败，note 省略以保持高度稳定');
    expect(find.text('查看全部'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attachment-notice-compact-details')));
    expect(details, 1);
    await tester.tap(find.byKey(const Key('attachment-notice-compact-dismiss')));
    expect(dismissed, 1);
  });

  testWidgets('紧凑态只有 note：显示可执行说明（单行省略）', (tester) async {
    await _pump(
      tester,
      CompactAttachmentNotice(
        feedback: _feedback(
          added: 1,
          note: '文本 5824157 字节超过单次请求上限，发送时使用分块分析',
        ),
        onDismiss: () {},
      ),
      width: 1100,
    );
    expect(find.text('已添加 1 个文件'), findsOneWidget);
    final note = find.byKey(const Key('attachment-notice-compact-note'));
    expect(note, findsOneWidget);
    expect(find.textContaining('分块分析'), findsOneWidget);
    // 单行省略：不会变成多行把胶囊撑高。
    expect(tester.widget<Text>(note).maxLines, 1);
    expect(tester.widget<Text>(note).overflow, TextOverflow.ellipsis);
    expect(find.byKey(const Key('attachment-notice-compact-details')),
        findsNothing);
  });

  testWidgets('紧凑态窄工作区 + 1.5 倍字号不溢出', (tester) async {
    await _pump(
      tester,
      CompactAttachmentNotice(
        feedback: _feedback(
          added: 1,
          failed: 1,
          failures: const [
            '附件6.2026年教师国情研修优秀成果申报表（田钦）.docx：文件 5824157 字节，超过输入上限',
          ],
        ),
        onDismiss: () {},
        onShowDetails: () {},
      ),
      width: 230,
      textScale: 1.5,
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('attachment-notice-compact')), findsOneWidget);
  });

  testWidgets('关闭按钮不抢输入焦点', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pump(
      tester,
      Column(
        children: [
          TextField(focusNode: focus),
          AttachmentNotice(
            feedback: _feedback(added: 1),
            onDismiss: () {},
          ),
        ],
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.byKey(const Key('attachment-notice-dismiss')));
    await tester.pump();
    expect(focus.hasFocus, isTrue, reason: '关闭通知不能把焦点从输入框抢走');
    expect(tester.takeException(), isNull);
  });
}
