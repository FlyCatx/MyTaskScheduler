// Widget tests for 「设置 → 模型」.
//
// What must hold:
//   * the connection list shows name / protocol / host / revision / credential state;
//   * every edit goes to the controller DRAFT (no settings.json write, no save());
//   * switching connections keeps unsaved edits (they are already in the draft);
//   * API keys are write-only: they go to the bridge and never stay in the widget tree;
//   * probe success/failure uses the controller's error text and never claims that the
//     model's JSON capability was verified;
//   * the thinking switch only exists for DeepSeek and drops the effort when off.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_model_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

Directory _tempDir(String name) {
  final dir = createTempDataDir(name);
  addTearDown(() {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // A leftover temp dir is harmless.
    }
  });
  return dir;
}

SettingsController _controller({SettingsBridge? bridge}) => SettingsController(
      store: SettingsStore(_tempDir('model_page')),
      bridge: bridge,
      probePollInterval: const Duration(milliseconds: 1),
    );

/// Loads committed profiles through the fake bridge (real file I/O, so it must run in
/// the real async zone rather than the widget tester's fake one).
Future<SettingsController> _loaded(
  WidgetTester tester, {
  FakeSettingsBridge? bridge,
  List<ProviderProfile>? profiles,
}) async {
  final fake =
      bridge ?? FakeSettingsBridge(settings: settingsDocument(profiles: profiles));
  final controller = _controller(bridge: fake);
  await tester.runAsync(() async {
    await controller.load();
  });
  expect(controller.loaded, isTrue);
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  SettingsController controller, {
  Key? pageKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: SettingsModelPage(key: pageKey, controller: controller),
    ),
  ));
  await tester.pumpAndSettle();
}

/// A saved connection without a stored key (so the key input is shown).
ProviderProfile _notConfigured() => sampleProfile().copyWith(
      credentialConfigured: false,
      clearCredentialHost: true,
    );

Text _firstTextContaining(WidgetTester tester, String text) =>
    tester.widget<Text>(find.textContaining(text).first);

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key)));

void main() {
  TsColors.apply(Brightness.light);

  testWidgets('列表显示名称、协议、主机、修订与凭据状态', (tester) async {
    final controller = _controller();
    controller.updateDraftProfile(sampleProfile());
    await _pump(tester, controller);

    expect(find.text('DeepSeek 官方'), findsWidgets);
    expect(find.textContaining('api.example.test'), findsWidgets);
    expect(find.textContaining('修订 1'), findsWidgets);
    expect(find.textContaining('凭据已配置'), findsWidgets);
  });

  testWidgets('空状态引导新增，新增/改名/删除都只改草稿', (tester) async {
    final controller = _controller();
    await _pump(tester, controller);

    expect(find.text('还没有模型连接'), findsOneWidget);
    expect(controller.draft.profiles, isEmpty);

    await tester.tap(find.byKey(const Key('settings-model-new')));
    await tester.pumpAndSettle();
    expect(controller.draft.profiles.length, 1);
    final id = controller.draft.profiles.single.id;

    await tester.enterText(find.byKey(const Key('settings-model-name')), '我的连接');
    await tester.pump();
    expect(controller.draft.profiles.single.name, '我的连接');
    expect(controller.dirty, isTrue);

    await tester.tap(find.byKey(Key('settings-model-delete-$id')));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除连接'), findsWidgets);
    await tester.tap(find.byKey(const Key('settings-model-confirm')));
    await tester.pumpAndSettle();

    expect(controller.draft.profiles, isEmpty);
    expect(controller.draft.deletions, contains(id));
    expect(find.text('还没有模型连接'), findsOneWidget);
  });

  testWidgets('编辑已保存连接只写草稿，不调用原生保存', (tester) async {
    final bridge = FakeSettingsBridge();
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '改过的名字',
    );
    await tester.pump();

    expect(controller.draft.profiles.single.name, '改过的名字');
    expect(controller.dirty, isTrue);
    expect(bridge.savedPayloads, isEmpty, reason: '页面不得调用 settings_save');
    expect(controller.profiles.single.name, 'DeepSeek 官方',
        reason: '已提交的值在保存前不变');
  });

  testWidgets('删除已保存连接：草稿标记删除，磁盘列表不变', (tester) async {
    final bridge = FakeSettingsBridge();
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(
      find.byKey(const Key('settings-model-delete-deepseek-official')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-model-confirm')));
    await tester.pumpAndSettle();

    expect(controller.draft.profiles, isEmpty);
    expect(controller.draft.deletions, contains('deepseek-official'));
    expect(controller.profiles.length, 1);
    expect(bridge.savedPayloads, isEmpty);
  });

  testWidgets('切换连接保留未保存的修改（内容已在草稿里）', (tester) async {
    final controller = _controller();
    controller.updateDraftProfile(sampleProfile());
    controller.updateDraftProfile(
      sampleProfile(id: 'second', name: '第二条连接'),
    );
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '第一条改名',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-model-tile-second')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'settings-model-name').controller!.text, '第二条连接');

    await tester.tap(find.byKey(const Key('settings-model-tile-deepseek-official')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'settings-model-name').controller!.text, '第一条改名');
    expect(controller.draft.profiles.first.name, '第一条改名');
  });

  testWidgets('设为默认连接写入草稿的选择', (tester) async {
    final controller = await _loaded(
      tester,
      profiles: [sampleProfile(), sampleProfile(id: 'second', name: '第二条连接')],
    );
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-tile-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-model-set-default')));
    await tester.pumpAndSettle();

    expect(controller.draft.defaultSelection, isNotNull);
    expect(controller.draft.defaultSelection!.profileId, 'second');
    expect(find.textContaining('已设为默认连接'), findsOneWidget);
  });

  testWidgets('API Key 只写不读：保存后清空输入并只显示已配置', (tester) async {
    final bridge = FakeSettingsBridge(
      settings: settingsDocument(
        profiles: [
          sampleProfile().copyWith(
            credentialConfigured: false,
            clearCredentialHost: true,
          ),
        ],
      ),
    );
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    expect(find.textContaining('未配置'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('settings-model-api-key')),
      'sk-test-secret-value',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-model-save-key')));
    await tester.pumpAndSettle();

    expect(bridge.credentialCalls, <String>['deepseek-official']);
    expect(find.textContaining('已配置'), findsWidgets);
    // 密钥不再留在任何输入框里，也不再出现在任何文本里。
    for (final editable
        in tester.widgetList<EditableText>(find.byType(EditableText))) {
      expect(editable.controller.text.contains('sk-test-secret'), isFalse);
    }
    expect(find.textContaining('sk-test-secret-value'), findsNothing);
    expect(find.byKey(const Key('settings-model-api-key')), findsNothing);
  });

  testWidgets('无效端点显示字段级错误文案', (tester) async {
    final controller = _controller();
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-advanced')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-model-chat-url')),
      'ftp://example.test/chat',
    );
    await tester.pump();

    // 校验文案来自 ProviderProfile.validate()：地址必须是 http:// 或 https://。
    expect(find.textContaining('http://'), findsWidgets);
    expect(find.textContaining('草稿校验未通过'), findsOneWidget);
  });

  testWidgets('字段标签不带括号说明，提示行已删除', (tester) async {
    // 0.09：按要求删除标签里的括号注与两处提示行，只保留功能名。
    final controller = _controller();
    await _pump(tester, controller);

    expect(find.text('基础地址'), findsOneWidget);
    expect(find.text('模型 ID'), findsOneWidget);
    expect(find.textContaining('仅展示 / 参考'), findsNothing);
    expect(find.textContaining('可手动输入'), findsNothing);

    await tester.tap(find.byKey(const Key('settings-model-advanced')));
    await tester.pumpAndSettle();
    expect(find.text('Chat Completions 完整地址'), findsOneWidget);
    expect(find.text('模型列表完整地址'), findsOneWidget);
    expect(find.textContaining('请求实际使用'), findsNothing);
    expect(find.textContaining('（可空）'), findsNothing);
    expect(find.textContaining('留空则不能'), findsNothing);
    expect(find.textContaining('密钥写入后立即生效'), findsNothing);
    expect(find.textContaining('换地址后需要重新填写密钥'), findsNothing);
  });

  testWidgets('思考开关只对 DeepSeek 存在，关闭后不残留强度', (tester) async {
    final controller = await _loaded(tester);
    await _pump(tester, controller);

    expect(find.byKey(const Key('settings-model-thinking')), findsOneWidget);
    expect(find.text('low'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byKey(const Key('settings-model-thinking')),
      matching: find.byType(Switch),
    ));
    await tester.pumpAndSettle();

    expect(find.text('low'), findsNothing);
    expect(controller.draft.profiles.single.thinking, ThinkingMode.disabled);
    expect(controller.draft.profiles.single.reasoningEffort, isNull);
  });

  testWidgets('OpenAI 兼容隐藏思考，JSON 模式改为可选', (tester) async {
    final controller = await _loaded(tester);
    await _pump(tester, controller);

    await tester.tap(find.descendant(
      of: find.byKey(const Key('settings-model-protocol')),
      matching: find.text('OpenAI 兼容'),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-model-thinking')), findsNothing);
    // 0.07: the explanatory sentence was removed; the missing switch plus the optional
    // JSON toggle are what the page now shows for this protocol.
    expect(find.textContaining('不会发送 thinking'), findsNothing);
    expect(find.text('JSON 模式（可选）'), findsOneWidget);
    expect(controller.draft.profiles.single.protocol, ProviderProtocol.openAiChat);
    expect(controller.draft.profiles.single.thinking, ThinkingMode.unsupported);
  });

  testWidgets('获取模型列表显示结果，可点选填入模型 ID', (tester) async {
    final bridge = FakeSettingsBridge();
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-discover')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(bridge.probeRequests.length, 1);
    expect(bridge.probeRequests.single['kind'], 'models');
    expect(find.textContaining('发现 2 个模型'), findsOneWidget);
    expect(find.text('model-a'), findsOneWidget);

    await tester.tap(find.text('model-a'));
    await tester.pumpAndSettle();
    expect(controller.draft.profiles.single.modelId, 'model-a');
  });

  testWidgets('探测失败用 controller 的错误文案', (tester) async {
    final bridge = FakeSettingsBridge()
      ..probeOutcome = ProbeOutcome.failure('models', 'auth', 'unauthorized');
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-discover')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('API Key 无效'), findsOneWidget);
  });

  testWidgets('探测进行中可取消', (tester) async {
    final bridge = FakeSettingsBridge()..nonTerminalPolls = 100000;
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-discover')));
    await tester.pump();
    expect(find.byKey(const Key('settings-model-cancel-probe')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-model-cancel-probe')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(find.textContaining('已取消'), findsOneWidget);
    expect(controller.probing, isFalse);
    expect(bridge.cancelledJobs, isNotEmpty);
  });

  testWidgets('探测按钮保留真实可用性；额度/文件说明不再常驻', (tester) async {
    final controller = await _loaded(tester);
    await _pump(tester, controller);

    // 0.07 removed the three teaching notes about quota/文件/能力. The probe buttons and
    // their real disabled-reason feedback stay (asserted by the next tests).
    expect(find.textContaining('会消耗少量调用额度'), findsNothing);
    expect(find.textContaining('不使用当前文件或任务内容'), findsNothing);
    expect(find.textContaining('不等于该模型的 JSON 分析能力已经验证'), findsNothing);
    expect(find.byKey(const Key('settings-model-discover')), findsOneWidget);
    expect(find.byKey(const Key('settings-model-test')), findsOneWidget);
  });

  testWidgets('原生设置不可用时探测按钮禁用并说明原因', (tester) async {
    final controller = _controller();
    controller.updateDraftProfile(sampleProfile());
    await _pump(tester, controller);

    final discover = tester.widget<OutlinedButton>(
      find.byKey(const Key('settings-model-discover')),
    );
    expect(discover.onPressed, isNull);
    expect(find.textContaining('原生设置不可用'), findsWidgets);
  });

  // ---------------------------------------------------------------- 0.0.4 验收
  //
  // 数据层已经把删除默认连接、revision 同步、凭据目标守卫、探测目标守卫与
  // partial 警告的语义固定下来；页面必须与它一致，不能自己猜一个替代值。

  testWidgets('删除默认连接后提示重新选择默认连接，且不自作主张换默认', (tester) async {
    final bridge = FakeSettingsBridge(
      settings: settingsDocument(
        profiles: [
          sampleProfile(),
          sampleProfile(id: 'second', name: '第二条连接'),
        ],
      ),
    );
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);
    expect(controller.draft.defaultSelection!.profileId, 'deepseek-official');

    await tester.tap(
      find.byKey(const Key('settings-model-delete-deepseek-official')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-model-confirm')));
    await tester.pumpAndSettle();

    // 草稿：默认选择被清空，但另一条连接仍在，且没有被自动设为默认。
    expect(controller.draft.deletions, contains('deepseek-official'));
    expect(controller.draft.defaultSelection, isNull);
    expect(controller.draft.profiles.single.id, 'second');
    expect(controller.validateDraft(), contains('默认连接已被删除'));

    // 页面给出明确提示并引导“设为默认”，不调用 save()。
    expect(find.byKey(const Key('settings-model-default-deleted')), findsOneWidget);
    expect(find.text('默认连接已删除，请在右侧选择新的默认连接后再保存'), findsOneWidget);
    // 保存会被控制层拒绝，页面在没有碰过输入框时也要说明原因。
    expect(find.textContaining('草稿校验未通过：默认连接已被删除'), findsOneWidget);
    expect(bridge.savedPayloads, isEmpty, reason: '页面不得调用 settings_save');

    // 用户显式点“把当前连接设为默认”后提示消失，默认选择指向剩下的连接。
    final setDefault = tester.widget<FilledButton>(
      find.byKey(const Key('settings-model-set-default')),
    );
    expect(setDefault.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('settings-model-set-default')));
    await tester.pumpAndSettle();

    expect(controller.draft.defaultSelection!.profileId, 'second');
    expect(controller.validateDraft(), isNull);
    expect(find.byKey(const Key('settings-model-default-deleted')), findsNothing);
  });

  testWidgets('删除最后一条连接显示空状态，不残留默认连接提示', (tester) async {
    final controller = await _loaded(tester, bridge: FakeSettingsBridge());
    await _pump(tester, controller);

    await tester.tap(
      find.byKey(const Key('settings-model-delete-deepseek-official')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-model-confirm')));
    await tester.pumpAndSettle();

    expect(controller.draft.profiles, isEmpty);
    expect(controller.draft.defaultSelection, isNull);
    expect(find.text('还没有模型连接'), findsOneWidget);
    expect(find.byKey(const Key('settings-model-default-deleted')), findsNothing);
  });

  testWidgets('保存后继续编辑同一连接可以再次保存（不会用旧 revision 撞冲突）',
      (tester) async {
    final bridge = FakeSettingsBridge();
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '第一次改名',
    );
    await tester.pump();
    expect(await controller.save(), isNull);
    await tester.pumpAndSettle();

    expect(bridge.savedPayloads.length, 1);
    expect(controller.profiles.single.name, '第一次改名');
    expect(controller.profiles.single.revision, 2);

    // 保存后表单仍停在这条连接上：继续编辑必须带上磁盘上的新 revision。
    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '第二次改名',
    );
    await tester.pump();
    expect(await controller.save(), isNull, reason: '旧 revision 会被原生层拒绝为 conflict');
    await tester.pumpAndSettle();

    expect(bridge.savedPayloads.length, 2);
    final second = (bridge.savedPayloads.last['profiles'] as List<dynamic>).single
        as Map<String, dynamic>;
    expect(second['revision'], 2);
    expect(controller.profiles.single.name, '第二次改名');
    expect(controller.profiles.single.revision, 3);
    expect(controller.lastError, isNull);
    expect(controller.draft.profiles.single.name, '第二次改名');
  });

  testWidgets('保存后修订徽标与设为默认都使用最新 revision', (tester) async {
    final controller = await _loaded(tester, bridge: FakeSettingsBridge());
    await _pump(tester, controller);
    expect(find.textContaining('· 修订 1'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '改名后',
    );
    await tester.pump();
    await controller.save();
    await tester.pumpAndSettle();

    expect(controller.profiles.single.revision, 2);
    expect(find.textContaining('· 修订 2'), findsWidgets);
    expect(find.textContaining('· 修订 1'), findsNothing);

    // 默认选择也要跟上新 revision，否则控制层会提示“配置已更新”。
    await tester.tap(find.byKey(const Key('settings-model-set-default')));
    await tester.pumpAndSettle();
    expect(controller.draft.defaultSelection!.profileRevision, 2);
    expect(find.textContaining('已设为默认连接'), findsOneWidget);
  });

  testWidgets('放弃后表单文本与修订恢复为磁盘值（重新打开也一样）', (tester) async {
    final controller = await _loaded(tester, bridge: FakeSettingsBridge());
    await _pump(tester, controller);

    // 先保存一次，让磁盘上的值不是初始值。
    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '已保存的名字',
    );
    await tester.pump();
    await controller.save();
    await tester.pumpAndSettle();
    expect(find.textContaining('· 修订 2'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '未保存的名字',
    );
    await tester.pump();
    expect(controller.draft.profiles.single.name, '未保存的名字');

    controller.discard();
    await tester.pumpAndSettle();

    expect(
      _field(tester, 'settings-model-name').controller!.text,
      '已保存的名字',
      reason: '放弃后表单不能还显示被丢弃的文本',
    );
    expect(find.textContaining('· 修订 2'), findsWidgets);
    expect(controller.draft.profiles.single.name, '已保存的名字');

    // 关掉再打开（新挂载的页面）读到的仍是回滚后的值。
    await _pump(tester, controller, pageKey: UniqueKey());
    expect(_field(tester, 'settings-model-name').controller!.text, '已保存的名字');
    expect(find.textContaining('· 修订 2'), findsWidgets);
  });

  testWidgets('新建未保存连接时保存密钥被禁用并说明原因', (tester) async {
    final bridge = FakeSettingsBridge(settings: emptySettingsDocument());
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '新连接',
    );
    await tester.pump();
    final id = controller.draft.profiles.single.id;
    expect(controller.profileById(id), isNull, reason: '这条连接还没保存到磁盘');

    final saveKey = tester.widget<FilledButton>(
      find.byKey(const Key('settings-model-save-key')),
    );
    expect(saveKey.onPressed, isNull);
    expect(find.byKey(const Key('settings-model-credential-block')), findsOneWidget);
    expect(find.textContaining('密钥绑定已保存连接的主机'), findsOneWidget);

    // 0.09: 页面上“密钥写入后立即生效…”的说明文字已按要求删除；这里改为核对行为本身：
    // 凭据动作不经过草稿，未保存的连接会被控制层拒绝。

    // 页面的禁用与控制层的拒绝一致：不会把密钥悄悄写到别的主机。
    final error = await controller.setCredential(id, 'sk-test-unsaved');
    expect(error, contains('请先保存连接'));
    expect(bridge.credentialCalls, isEmpty);
  });

  testWidgets('地址有未保存修改时保存密钥被禁用并说明原因', (tester) async {
    final bridge = FakeSettingsBridge(
      settings: settingsDocument(profiles: [_notConfigured()]),
    );
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('settings-model-save-key')))
          .onPressed,
      isNotNull,
      reason: '刚加载的已保存连接可以写密钥',
    );

    await tester.tap(find.byKey(const Key('settings-model-advanced')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-model-chat-url')),
      'https://api.example.test/v2/chat/completions',
    );
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('settings-model-save-key')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('settings-model-credential-block')), findsOneWidget);
    expect(find.textContaining('请先保存连接，再保存 API Key'), findsOneWidget);
    expect(bridge.credentialCalls, isEmpty);
  });

  testWidgets('密钥已生效但设置文件写入失败按警告呈现，不是红色失败', (tester) async {
    final bridge = FakeSettingsBridge(
      settings: settingsDocument(profiles: [_notConfigured()]),
    )..credentialPersistFails = true;
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-api-key')),
      'sk-test-partial-value',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-model-save-key')));
    await tester.pumpAndSettle();

    expect(bridge.credentialCalls, <String>['deepseek-official']);
    // 密钥确实已经生效：按警告（系统提醒色）呈现，不是红色失败。
    expect(find.byKey(const Key('settings-model-credential-warning')), findsOneWidget);
    expect(find.byKey(const Key('settings-model-credential-error')), findsNothing);
    final warning = _firstTextContaining(tester, '设置文件写入失败');
    expect(warning.style?.color, TsColors.pending);
    expect(find.textContaining('请重新保存设置'), findsOneWidget);
    // 只显示“已配置”，输入框已清空，密钥不回显。
    expect(find.textContaining('已配置'), findsWidgets);
    expect(find.byKey(const Key('settings-model-api-key')), findsNothing);
    expect(find.textContaining('sk-test-partial-value'), findsNothing);
  });

  testWidgets('删除密钥的部分失败同样按警告呈现', (tester) async {
    final bridge = FakeSettingsBridge()..credentialPersistFails = true;
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-delete-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-model-confirm')));
    await tester.pumpAndSettle();

    expect(bridge.credentialDeletes, <String>['deepseek-official']);
    expect(find.byKey(const Key('settings-model-credential-warning')), findsOneWidget);
    expect(find.byKey(const Key('settings-model-credential-error')), findsNothing);
    expect(find.textContaining('API Key 已删除'), findsOneWidget);
    expect(_firstTextContaining(tester, 'API Key 已删除').style?.color,
        TsColors.pending);
    expect(find.textContaining('未配置'), findsWidgets);
  });

  testWidgets('探测只针对已保存的配置：未保存连接禁用并说明', (tester) async {
    final bridge = FakeSettingsBridge(settings: emptySettingsDocument());
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.enterText(
      find.byKey(const Key('settings-model-name')),
      '新连接',
    );
    await tester.pump();

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('settings-model-discover')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('settings-model-test')))
          .onPressed,
      isNull,
    );
    // 0.07: the long "只针对已保存的配置" note was removed; the real disabled reason is
    // still printed next to the buttons (it is a real状态, not an explanation).
    expect(find.textContaining('这条连接还没有保存到磁盘'), findsWidgets);
    expect(
      find.textContaining('「获取模型列表」与「测试模型响应」只针对已保存的配置'),
      findsNothing,
    );
    expect(bridge.probeRequests, isEmpty);
  });

  testWidgets('地址有未保存修改时探测按钮禁用并显示与控制器一致的原因',
      (tester) async {
    final bridge = FakeSettingsBridge();
    final controller = await _loaded(tester, bridge: bridge);
    await _pump(tester, controller);

    await tester.tap(find.byKey(const Key('settings-model-advanced')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-model-chat-url')),
      'https://api.example.test/v2/chat/completions',
    );
    await tester.pump();

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('settings-model-discover')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('settings-model-test')))
          .onPressed,
      isNull,
    );
    // 0.1.0：按钮下方那句“请先保存连接，再测试实际请求目标…”已按要求删除；
    // 同一件事只由下面那条橙色提示说明一次。
    expect(find.textContaining('测试实际请求目标'), findsNothing);
    expect(find.textContaining('当前表单有未保存的修改'), findsOneWidget);

    // 控制层在真正发请求前也会拒绝，文案依旧一致。
    final outcome = await controller.testModel('deepseek-official', 1);
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('未保存的修改'));
    expect(bridge.probeRequests, isEmpty, reason: '不应带着未保存的地址发请求');
  });

  testWidgets('思考模式的开关行没有整块悬停底色', (tester) async {
    // 0.1.0：鼠标悬停时 ListTile 默认会画一条整行宽的浅灰底，像另一张面板。
    final controller = await _loaded(tester);
    await _pump(tester, controller);

    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings-model-thinking')),
    );
    expect(tile.hoverColor, Colors.transparent);
  });
}

