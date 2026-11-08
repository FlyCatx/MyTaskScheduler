// 设置 → 关于页：0.3.0 文案与隐私说明校正。
//
// 检查内容：
//   * “检查更新”的禁用原因只通过按钮 Tooltip 提示，重复常驻的
//     “更新服务未配置”卡片已删除（不占位、不出现在语义树）；
//   * 未接入的“意见反馈”只保留不可用状态（无点击、Tooltip 说明），不是可完成动作；
//   * “隐私协议”打开可读说明：本机 OCR 本地完成、主动发起模型分析时材料文字
//     会经配置的模型连接发送、API Key 存在 Windows 凭据管理器且不随材料发送；
//     不再出现“程序不上传材料与密钥”的绝对承诺。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_about_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

void main() {
  testWidgets('关于页删除重复更新卡片，禁用原因只留 Tooltip', (tester) async {
    final controller = makeTestSettingsController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: SettingsAboutPage(controller: controller)),
      ),
    ));
    await tester.pump();

    expect(find.text('检查更新'), findsOneWidget);
    // 常驻说明删除：既不显示文本，也不留下同文案的替身。
    expect(find.text('更新服务未配置'), findsNothing);
    expect(find.textContaining('更新服务未配置'), findsNothing);
    // 禁用原因仍可通过 Tooltip 读到。
    expect(find.byTooltip('更新服务尚未接入'), findsOneWidget);
    // 版本行与下一行之间不再被说明卡片隔开（版本信息后直接是分隔线/帮助入口）。
    expect(find.text('版本信息'), findsOneWidget);
    expect(find.text('帮助'), findsOneWidget);
  });

  testWidgets('未接入的意见反馈不再可点击，只保留准确的不可用状态', (tester) async {
    final controller = makeTestSettingsController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: SettingsAboutPage(controller: controller)),
      ),
    ));
    await tester.pump();

    // 入口仍在（用户能知道该能力的状态），但不是可点击动作。
    expect(find.text('意见反馈'), findsOneWidget);
    expect(find.byTooltip('意见反馈功能尚未接入'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('意见反馈'), matching: find.byType(InkWell)),
      findsNothing,
      reason: '未接入的反馈不能表现为可完成的点击动作',
    );

    // 点击不应出现“尚未接入”的一次性提示——那等于承认有一个空壳动作。
    await tester.tap(find.text('意见反馈'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('该功能尚未接入'), findsNothing);
  });

  testWidgets('隐私协议弹窗明确本地 OCR、模型发送与密钥存储，不做绝对承诺',
      (tester) async {
    final controller = makeTestSettingsController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: SettingsAboutPage(controller: controller)),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('隐私协议'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('about-privacy-dialog')), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const Key('about-privacy-text')))
        .data!;
    // 事实边界必须都在，且旧绝对承诺不得保留。
    expect(text, contains('本机'));
    expect(text, contains('OCR'));
    expect(text, contains('模型连接'));
    expect(text, contains('发送'));
    expect(text, contains('Windows 凭据管理器'));
    expect(text, contains('不随材料内容发送'));
    expect(text, isNot(contains('程序不上传材料与密钥')));
    expect(text, isNot(contains('所有数据保存在本机，程序不上传')));

    await tester.tap(find.byKey(const Key('about-privacy-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-privacy-dialog')), findsNothing);
  });
}
