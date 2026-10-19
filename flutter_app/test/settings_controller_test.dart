// Unit tests for the settings controller: draft dirty state, save success/failure,
// revision conflicts, selection validation, error texts and the asynchronous probe
// lifecycle (including cancel + late results).
//
// Everything runs against [FakeSettingsBridge]; no DLL and no network are involved and
// no real API key is ever used (the fake only records which profile was touched).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/bridge_ffi.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;
  late SettingsStore store;

  setUp(() {
    dir = createTempDataDir('settings_controller');
    store = SettingsStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<SettingsController> build(
    SettingsBridge? bridge, {
    Duration probeTimeout = const Duration(seconds: 35),
    SettingsStore? customStore,
  }) async {
    final controller = SettingsController(
      store: customStore ?? store,
      bridge: bridge,
      probePollInterval: const Duration(milliseconds: 5),
      probeTimeout: probeTimeout,
    );
    addTearDown(controller.dispose);
    await controller.load();
    return controller;
  }

  /// A document with two saved connections, the first one being the default.
  Map<String, dynamic> twoProfiles() => settingsDocument(
        profiles: <ProviderProfile>[
          sampleProfile(),
          sampleProfile(id: 'second', name: '第二连接', modelId: 'second-model'),
        ],
      );

  group('load', () {
    test('reads preferences and the native settings document', () async {
      await store.save(const AppPreferences(themeMode: AppThemeMode.dark));
      final controller = await build(FakeSettingsBridge());

      expect(controller.loaded, isTrue);
      expect(controller.prefs.themeMode, AppThemeMode.dark);
      expect(controller.bridgeAvailable, isTrue);
      expect(controller.profiles, hasLength(1));
      expect(controller.profiles.single.id, 'deepseek-official');
      expect(controller.defaultSelection?.modelId, 'deepseek-chat');
      expect(controller.settingsPath, r'C:\data\settings.json');
      expect(controller.dirty, isFalse);
      expect(controller.loadWarning, isNull);
    });

    test('keeps preferences when the native surface is unavailable', () async {
      await store.save(const AppPreferences(fontScale: 1.1));
      final controller = await build(null);

      expect(controller.prefs.fontScale, 1.1);
      expect(controller.bridgeAvailable, isFalse);
      expect(controller.profiles, isEmpty);
      expect(controller.loadWarning, isNull);
      expect(controller.validateSelection(null), contains('原生设置不可用'));
    });

    test('a native read failure is reported without throwing', () async {
      final bridge = FakeSettingsBridge()
        ..getFailure = NativeCallException(
            'abi', '分析内核版本不匹配：ABI 版本为 1，界面需要 2');
      final controller = await build(bridge);

      expect(controller.bridgeAvailable, isFalse);
      expect(controller.loadWarning, contains('ABI'));
      expect(controller.profiles, isEmpty);
    });

    test('reportLoadFailure records a non-fatal warning', () async {
      final controller = await build(null);
      controller.reportLoadFailure('无法加载 ts_bridge.dll');

      expect(controller.lastError, '无法加载 ts_bridge.dll');
      expect(controller.loadWarning, '无法加载 ts_bridge.dll');
    });
  });

  group('draft', () {
    test('becomes dirty on edit and clean again after discard', () async {
      final controller = await build(FakeSettingsBridge());
      expect(controller.dirty, isFalse);

      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.light));
      expect(controller.dirty, isTrue);
      // The committed value is untouched until save.
      expect(controller.prefs.themeMode, AppThemeMode.system);

      controller.discard();
      expect(controller.dirty, isFalse);
      expect(controller.draft.prefs.themeMode, AppThemeMode.system);
    });

    test('a removed profile is staged as a deletion', () async {
      final controller = await build(FakeSettingsBridge());

      controller.removeDraftProfile('deepseek-official');
      expect(controller.dirty, isTrue);
      expect(controller.draft.profiles, isEmpty);
      expect(controller.draft.deletions, contains('deepseek-official'));
      // Removing the default connection also clears the default in the draft.
      expect(controller.draft.defaultSelection, isNull);
    });

    test('profile validation problems come back immediately', () async {
      final controller = await build(FakeSettingsBridge());
      final broken = sampleProfile(id: 'broken', modelId: '');

      final error = controller.updateDraftProfile(broken);
      expect(error, contains('模型 ID'));
      expect(controller.validateDraft(), contains('模型 ID'));
    });
  });

  group('save', () {
    test('a new profile is sent with revision 0 and stored as revision 1',
        () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);
      final fresh = const ProviderProfile(
        id: 'local-test',
        name: '本地测试连接',
        protocol: ProviderProtocol.openAiChat,
        baseUrl: 'https://local.example.test',
        chatUrl: 'https://local.example.test/v1/chat/completions',
        modelsUrl: '',
        modelId: 'local-model',
        thinking: ThinkingMode.unsupported,
      );
      controller.updateDraftProfile(fresh);
      expect(controller.dirty, isTrue);

      final error = await controller.save();
      expect(error, isNull);
      expect(controller.dirty, isFalse);
      final sent = bridge.savedPayloads.single;
      final sentProfiles = sent['profiles'] as List<dynamic>;
      final added = sentProfiles
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == 'local-test');
      expect(added['revision'], 0, reason: '新连接必须传 0，由原生侧决定 1');
      expect(controller.profiles.any((p) => p.id == 'local-test'), isTrue);
      expect(controller.profileById('local-test')!.revision, 1);
    });

    test('a conflict keeps the committed values and reports a readable error',
        () async {
      final bridge = FakeSettingsBridge()
        ..saveFailure =
            NativeCallException('conflict', '模型配置已被修改，请刷新后重试');
      final controller = await build(bridge);
      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.dark));
      controller.updateDraftProfile(
          controller.profiles.single.copyWith(name: '改过的名字'));
      expect(controller.dirty, isTrue);

      final error = await controller.save();

      expect(error, contains('模型配置已被修改'));
      expect(controller.profiles.single.name, 'DeepSeek 官方',
          reason: '保存失败必须保留旧值');
      expect(controller.prefs.themeMode, AppThemeMode.system);
      expect(controller.dirty, isTrue, reason: '草稿要留着让用户重试');
      // The preferences file is rolled back to the last committed value.
      expect((await store.load()).prefs.themeMode, AppThemeMode.system);
    });

    test('a preferences-only save never calls the native settings API', () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);
      controller.updateDraftPreferences(
          controller.prefs.copyWith(sendMode: SendMode.enter));

      expect(await controller.save(), isNull);
      expect(bridge.savedPayloads, isEmpty);
      expect((await store.load()).prefs.sendMode, SendMode.enter);
    });

    test('a removed connection is sent as deletedProfileIds, not as an omission',
        () async {
      final bridge = FakeSettingsBridge(settings: twoProfiles());
      final controller = await build(bridge);

      controller.removeDraftProfile('second');
      expect(controller.dirty, isTrue);
      expect(await controller.save(), isNull);

      final sent = bridge.savedPayloads.single;
      // The native merge starts from the file on disk: an id that is only absent from
      // `profiles` is *kept*, so the deletion must be explicit.
      expect(sent['deletedProfileIds'], <String>['second']);
      expect((sent['profiles'] as List<dynamic>), hasLength(1));
      expect(sent['defaultProfileId'], 'deepseek-official');
      expect(controller.profiles.map((p) => p.id), <String>['deepseek-official']);
      expect(controller.dirty, isFalse);
      expect(controller.draft.deletions, isEmpty, reason: '保存成功后清空删除列表');

      // A second save has nothing to do and must not resend a stale deletion.
      expect(await controller.save(), isNull);
      expect(bridge.savedPayloads, hasLength(1));
    });

    test('deleting the default connection requires an explicit reselect',
        () async {
      final bridge = FakeSettingsBridge(settings: twoProfiles());
      final controller = await build(bridge);

      controller.removeDraftProfile('deepseek-official');
      expect(controller.draft.defaultSelection, isNull);

      final blocked = await controller.save();
      expect(blocked, contains('默认连接'));
      expect(blocked, contains('选择'));
      expect(bridge.savedPayloads, isEmpty, reason: '未重选默认连接时不得发保存请求');

      final reselect = controller.setDraftDefaultSelection(sampleSelection(
        profileId: 'second',
        modelId: 'second-model',
      ));
      expect(reselect, isNull);
      expect(await controller.save(), isNull);

      final sent = bridge.savedPayloads.single;
      expect(sent['deletedProfileIds'], <String>['deepseek-official']);
      expect(sent['defaultProfileId'], 'second');
      expect(controller.profiles.map((p) => p.id), <String>['second']);
      expect(controller.defaultSelection?.profileId, 'second');
    });

    test('deleting the last connection sends an empty document', () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);

      controller.removeDraftProfile('deepseek-official');
      expect(await controller.save(), isNull);

      final sent = bridge.savedPayloads.single;
      expect(sent['profiles'], isEmpty);
      expect(sent['deletedProfileIds'], <String>['deepseek-official']);
      expect(sent['defaultProfileId'], '');
      expect(controller.profiles, isEmpty);
      expect(controller.defaultSelection, isNull);
    });

    test('deletions survive a restart (new controller over the saved document)',
        () async {
      final bridge = FakeSettingsBridge(settings: twoProfiles());
      final first = await build(bridge);
      first.removeDraftProfile('second');
      expect(await first.save(), isNull);

      // Simulate a process restart: a fresh bridge loads what was persisted.
      final restartedBridge = FakeSettingsBridge(settings: bridge.document);
      final restarted = await build(restartedBridge);

      expect(restarted.profiles.map((p) => p.id), <String>['deepseek-official']);
      expect(restarted.defaultSelection?.profileId, 'deepseek-official');
      expect(restarted.validateSelection(sampleSelection()), isNull);
      expect(restarted.bridgeAvailable, isTrue);
      expect(restarted.dirty, isFalse);
    });

    test('the remaining connection can still be saved and used after a deletion',
        () async {
      final bridge = FakeSettingsBridge(settings: twoProfiles());
      final controller = await build(bridge);

      controller.removeDraftProfile('deepseek-official');
      controller.setDraftDefaultSelection(sampleSelection(
        profileId: 'second',
        modelId: 'second-model',
      ));
      expect(await controller.save(), isNull);
      expect(
        controller.validateSelection(
            sampleSelection(profileId: 'second', modelId: 'second-model')),
        isNull,
      );
      final remaining = controller.profiles.single;
      expect(remaining.id, 'second');
      expect(remaining.revision, 1);

      // Editing it again must not resurrect the deleted connection nor resend a deletion.
      controller.updateDraftProfile(remaining.copyWith(name: '改名后的连接'));
      expect(await controller.save(), isNull);
      expect(controller.profiles.single.name, '改名后的连接');
      expect(controller.profiles.single.revision, 2);
      expect(bridge.savedPayloads.last.containsKey('deletedProfileIds'), isFalse);
      expect(controller.profiles.map((p) => p.id), <String>['second']);
    });

    test('a failed rollback is reported and memory follows what the file holds',
        () async {
      final flaky = _FlakySettingsStore(dir);
      final bridge = FakeSettingsBridge()
        ..saveFailure =
            NativeCallException('conflict', '模型配置已被修改，请刷新后重试');
      final controller = await build(bridge, customStore: flaky);
      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.dark));
      controller.updateDraftProfile(
          controller.profiles.single.copyWith(name: '改过的名字'));

      final error = await controller.save();

      expect(error, contains('模型配置已被修改'));
      expect(error, contains('回滚失败'));
      expect(error, contains('应用偏好已写入新值'));
      expect(error, contains('模型连接仍是旧值'));
      expect(controller.prefs.themeMode, AppThemeMode.dark,
          reason: '回滚失败时磁盘已是新偏好，内存必须与磁盘一致，不能假装回滚成功');
      expect((await flaky.load()).prefs.themeMode, AppThemeMode.dark);
      expect(controller.profiles.single.name, 'DeepSeek 官方',
          reason: '模型连接仍是旧值');
      expect(controller.draft.profiles.single.name, '改过的名字',
          reason: '草稿保留供重试');
      expect(controller.dirty, isTrue);
    });

    test('a successful rollback says the preferences were restored', () async {
      final bridge = FakeSettingsBridge()
        ..saveFailure =
            NativeCallException('conflict', '模型配置已被修改，请刷新后重试');
      final controller = await build(bridge);
      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.dark));
      controller.updateDraftProfile(
          controller.profiles.single.copyWith(name: '改过的名字'));

      final error = await controller.save();

      expect(error, contains('模型连接未保存，应用偏好已恢复原值'));
      expect(controller.prefs.themeMode, AppThemeMode.system);
      expect((await store.load()).prefs.themeMode, AppThemeMode.system);
      expect(controller.profiles.single.name, 'DeepSeek 官方');
      expect(controller.dirty, isTrue);
    });

    test('a native failure without preference changes claims no rollback',
        () async {
      final bridge = FakeSettingsBridge()
        ..saveFailure =
            NativeCallException('conflict', '模型配置已被修改，请刷新后重试');
      final controller = await build(bridge);
      controller.updateDraftProfile(
          controller.profiles.single.copyWith(name: '改过的名字'));

      final error = await controller.save();

      expect(error, contains('模型配置已被修改'));
      expect(error, contains('模型连接未保存'));
      expect(error, isNot(contains('回滚')));
    });

    test('without a native bridge the model part is refused but prefs are kept',
        () async {
      final controller = await build(null);
      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.dark));
      controller.updateDraftProfile(sampleProfile(id: 'extra'));

      final error = await controller.save();

      expect(error, contains('原生设置不可用'));
      expect(controller.profiles, isEmpty);
      expect((await store.load()).prefs.themeMode, AppThemeMode.system,
          reason: '整体保存失败时偏好也要回滚');
    });
  });

  group('selection validation', () {
    test('explains every unusable selection', () async {
      final controller = await build(FakeSettingsBridge());
      final valid = sampleSelection();

      expect(controller.validateSelection(valid), isNull);

      expect(
        controller.validateSelection(valid.copyWith(profileId: 'missing')),
        contains('已被删除'),
      );
      expect(
        controller.validateSelection(valid.copyWith(profileRevision: 9)),
        contains('已更新'),
      );
      expect(
        controller.validateSelection(valid.copyWith(modelId: '  ')),
        contains('模型 ID'),
      );
      expect(
        controller.validateSelection(valid.copyWith(profileRevision: 0)),
        contains('版本'),
      );
    });

    test('reports an empty configuration with an actionable sentence', () async {
      final controller = await build(FakeSettingsBridge(settings: emptySettingsDocument()));
      expect(controller.validateSelection(null), contains('尚未配置模型连接'));
    });

    test('a stale explicit selection is blocked, never replaced by the default',
        () async {
      final controller = await build(FakeSettingsBridge());
      final own = sampleSelection(modelId: 'deepseek-reasoner');
      final conversation = Conversation(
        id: 'conv-1',
        title: '',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        modelSelection: own,
      );
      expect(controller.currentSelectionFor(conversation), own);

      final stale = conversation.copyWith(
        modelSelection: own.copyWith(profileRevision: 42),
      );
      // Display must not pretend the conversation uses another provider.
      expect(controller.currentSelectionFor(stale), isNull,
          reason: '失效的显式选择不能回退到全局默认');

      final staleResolution = controller.resolveSelectionForRequest(stale);
      expect(staleResolution.ok, isFalse);
      expect(staleResolution.selection, isNull);
      expect(staleResolution.migrated, isFalse);
      expect(staleResolution.error, contains('已更新'));
      expect(staleResolution.error, contains('42'));
      expect(staleResolution.error, contains('1'), reason: '错误里要给出当前修订');
      expect(staleResolution.error, contains('重新选择'));

      final deleted = conversation.copyWith(
        modelSelection: own.copyWith(profileId: 'gone'),
      );
      expect(controller.currentSelectionFor(deleted), isNull);
      final deletedResolution = controller.resolveSelectionForRequest(deleted);
      expect(deletedResolution.ok, isFalse);
      expect(deletedResolution.error, contains('已删除'));
      expect(deletedResolution.error, contains('不会自动改用其它连接'));

      final noOverride = Conversation(
        id: 'conv-2',
        title: '',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(controller.currentSelectionFor(noOverride),
          controller.defaultSelection);
      expect(controller.currentSelectionFor(null), controller.defaultSelection);

      final migrated = controller.resolveSelectionForRequest(noOverride);
      expect(migrated.selection, controller.defaultSelection);
      expect(migrated.migrated, isTrue,
          reason: '没有绑定的旧会话由全局默认迁移，并由调用方立刻持久化一次');
    });

    test('an old session without a usable default is asked to choose', () async {
      final noDefault = await build(FakeSettingsBridge(
        settings: settingsDocument(
          profiles: <ProviderProfile>[sampleProfile()],
          defaultProfileId: '',
        ),
      ));
      final legacy = Conversation(
        id: 'conv-legacy',
        title: '',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(noDefault.defaultSelection, isNull);

      final resolution = noDefault.resolveSelectionForRequest(legacy);
      expect(resolution.ok, isFalse);
      expect(resolution.error, contains('尚未绑定模型'));
      expect(resolution.error, contains('选择'));
      expect(noDefault.currentSelectionFor(legacy), isNull);
    });
  });

  group('error texts', () {
    test('maps status codes and native kinds to readable sentences', () {
      expect(SettingsErrorCatalog.describeKind('auth'), contains('401'));
      expect(SettingsErrorCatalog.describeKind('', httpStatus: 401),
          contains('401'));
      expect(SettingsErrorCatalog.describeKind('', httpStatus: 403),
          contains('403'));
      expect(SettingsErrorCatalog.describeKind('', httpStatus: 404),
          contains('404'));
      expect(SettingsErrorCatalog.describeKind('rateLimit'), contains('429'));
      expect(SettingsErrorCatalog.describeKind('', httpStatus: 503),
          contains('5xx'));
      expect(SettingsErrorCatalog.describeKind('network'), contains('网络'));
      expect(SettingsErrorCatalog.describeKind('tls'), contains('证书'));
      expect(SettingsErrorCatalog.describeKind('timeout'), contains('超时'));
      expect(SettingsErrorCatalog.describeKind('truncated'), contains('截断'));
      expect(SettingsErrorCatalog.describeKind('invalidJson'), contains('JSON'));
      expect(SettingsErrorCatalog.describeKind('revision'), contains('版本'));
      expect(SettingsErrorCatalog.describeKind('profileDeleted'),
          contains('已被删除'));
      expect(SettingsErrorCatalog.describeKind('conflict'),
          contains('已被修改'));
      expect(SettingsErrorCatalog.describeKind('cancelled'), '已取消');
    });

    test('falls back to the native message instead of a generic error', () {
      expect(
        SettingsErrorCatalog.describeKind('mystery', message: '自定义失败原因'),
        '自定义失败原因',
      );
      expect(SettingsErrorCatalog.describeKind('mystery'), isNotEmpty);
    });

    test('describes probe outcomes by kind', () {
      const models = ProbeOutcome(
        ok: true,
        kind: 'models',
        httpStatus: 200,
        models: <String>['a', 'b'],
      );
      expect(SettingsErrorCatalog.describeProbe(models), contains('2'));
      const failed = ProbeOutcome(
        ok: false,
        kind: 'chat',
        httpStatus: 401,
        errorKind: 'auth',
        error: 'unauthorized',
      );
      expect(SettingsErrorCatalog.describeProbe(failed), contains('401'));
    });
  });

  group('credentials', () {
    test('stores only a configured flag and never echoes the key', () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);

      expect(controller.credentialConfigured('deepseek-official'), isTrue);
      // A throwaway placeholder: this test never talks to a real service.
      final error = await controller.setCredential(
          'deepseek-official', 'placeholder-not-a-real-key');
      expect(error, isNull);
      expect(bridge.credentialCalls, <String>['deepseek-official']);

      final removed = await controller.deleteCredential('deepseek-official');
      expect(removed, isNull);
      expect(bridge.credentialDeletes, <String>['deepseek-official']);
      expect(controller.credentialConfigured('deepseek-official'), isFalse);
    });

    test('rejects an empty key and an unavailable bridge', () async {
      final controller = await build(FakeSettingsBridge());
      expect(await controller.setCredential('deepseek-official', '   '),
          contains('请输入'));
      // A profile that exists nowhere is refused instead of guessing a target.
      expect(await controller.deleteCredential('missing'),
          contains('该连接不存在'));

      final offline = await build(null);
      expect(await offline.setCredential('deepseek-official', 'placeholder'),
          contains('原生设置不可用'));
    });

    test('refuses a key for an unsaved or edited connection', () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);

      // A brand-new connection exists only in the draft: the native layer cannot bind a
      // key to it (and does not know its host yet).
      controller.updateDraftProfile(sampleProfile(id: 'not-saved'));
      expect(await controller.setCredential('not-saved', 'placeholder'),
          contains('请先保存连接'));
      expect(await controller.deleteCredential('not-saved'),
          contains('请先保存连接'));
      expect(bridge.credentialCalls, isEmpty);
      expect(bridge.credentialDeletes, isEmpty);

      // An unsaved endpoint/auth edit would make the key belong to a host the committed
      // profile does not have.
      controller.updateDraftProfile(controller.profiles.single.copyWith(
          chatUrl: 'https://other.example.test/chat/completions'));
      expect(await controller.setCredential('deepseek-official', 'placeholder'),
          contains('未保存的修改'));
      expect(await controller.deleteCredential('deepseek-official'),
          contains('未保存的修改'));
      expect(bridge.credentialCalls, isEmpty);
      expect(bridge.credentialDeletes, isEmpty);
    });

    test('a partial key write is a readable warning with refreshed state',
        () async {
      final bridge = FakeSettingsBridge(
        settings: settingsDocument(
          profiles: <ProviderProfile>[
            sampleProfile()
                .copyWith(credentialConfigured: false, clearCredentialHost: true),
          ],
        ),
      )..credentialPersistFails = true;
      final controller = await build(bridge);
      expect(controller.credentialConfigured('deepseek-official'), isFalse);

      final message = await controller.setCredential(
          'deepseek-official', 'placeholder-not-a-real-key');

      expect(message, contains('已生效'));
      expect(message, contains('写入失败'));
      expect(message, contains('重新保存设置'));
      expect(controller.credentialConfigured('deepseek-official'), isTrue,
          reason: '密钥已生效：刷新原生状态，不能当成完全失败');
      expect(controller.profileById('deepseek-official')!.credentialHost,
          'api.example.test');
      expect(message!.toLowerCase(), isNot(contains('sk-')));
    });

    test('a partial delete is a readable warning too', () async {
      final bridge = FakeSettingsBridge()..credentialPersistFails = true;
      final controller = await build(bridge);

      final message = await controller.deleteCredential('deepseek-official');

      expect(message, contains('已删除'));
      expect(message, contains('写入失败'));
      expect(controller.credentialConfigured('deepseek-official'), isFalse);
    });

    test('a hard credential failure keeps the old state and a readable reason',
        () async {
      final bridge = FakeSettingsBridge()
        ..credentialSetFailure = NativeCallException(
            'credentialWriteFailed', '无法写入 Windows 凭据管理器');
      final controller = await build(bridge);

      final message =
          await controller.setCredential('deepseek-official', 'placeholder');

      expect(message, contains('凭据'));
      expect(message, isNot(contains('已生效')));
      expect(controller.credentialConfigured('deepseek-official'), isTrue,
          reason: '完全失败不能改动已配置状态');
      expect(bridge.credentialCalls, hasLength(1));
    });

    test('credential changes are immediate and survive discard', () async {
      final bridge = FakeSettingsBridge(
        settings: settingsDocument(
          profiles: <ProviderProfile>[
            sampleProfile()
                .copyWith(credentialConfigured: false, clearCredentialHost: true),
          ],
        ),
      );
      final controller = await build(bridge);
      expect(controller.credentialConfigured('deepseek-official'), isFalse);

      expect(
        await controller.setCredential('deepseek-official', 'placeholder'),
        isNull,
      );
      expect(controller.credentialConfigured('deepseek-official'), isTrue);

      controller.updateDraftPreferences(
          controller.prefs.copyWith(themeMode: AppThemeMode.dark));
      controller.discard();
      expect(controller.credentialConfigured('deepseek-official'), isTrue,
          reason: '凭据操作立即生效，取消/放弃设置窗口不会恢复旧密钥');
      expect(controller.draft.profiles.single.credentialConfigured, isTrue);
    });
  });

  group('probes', () {
    test('discoverModels sends the captured profile revision and thinking mode',
        () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);

      final outcome = await controller.discoverModels(
        'deepseek-official',
        1,
      );

      final request = bridge.probeRequests.single;
      expect(request['kind'], 'models');
      expect(request['profileId'], 'deepseek-official');
      expect(request['profileRevision'], 1);
      expect(request['modelId'], 'deepseek-chat');
      expect(request['thinking'], 'enabled');
      expect(request['reasoningEffort'], 'high');
      expect(outcome.ok, isTrue);
      expect(outcome.models, <String>['model-a', 'model-b']);
      expect(controller.lastProbe, outcome);
      expect(bridge.releasedJobs, isNotEmpty);
    });

    test('an OpenAI-compatible profile never sends thinking parameters', () async {
      final bridge = FakeSettingsBridge(
        settings: settingsDocument(
          profiles: <ProviderProfile>[
            sampleProfile(
              id: 'compatible',
              name: '兼容连接',
              protocol: ProviderProtocol.openAiChat,
            ),
          ],
        ),
      );
      final controller = await build(bridge);

      await controller.testModel('compatible', 1);

      final request = bridge.probeRequests.single;
      expect(request['kind'], 'chat');
      expect(request['thinking'], 'unsupported');
      expect(request['reasoningEffort'], isNull);
    });

    test('an unknown revision fails without starting a job', () async {
      final bridge = FakeSettingsBridge();
      final controller = await build(bridge);

      final outcome = await controller.testModel('deepseek-official', 7);

      expect(outcome.ok, isFalse);
      expect(outcome.errorKind, SettingsErrorCatalog.revision);
      expect(bridge.probeRequests, isEmpty);
    });

    test('a deleted profile fails with the profileDeleted text', () async {
      final controller = await build(FakeSettingsBridge());
      final outcome = await controller.discoverModels('gone', 1);
      expect(outcome.errorKind, SettingsErrorCatalog.profileDeleted);
    });

    test('a cancelled probe returns cancelled and never becomes the last answer',
        () async {
      final bridge = FakeSettingsBridge()..nonTerminalPolls = 1000;
      final controller = await build(bridge);

      final pending = controller.discoverModels('deepseek-official', 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.cancelProbe();
      final outcome = await pending;

      expect(outcome.ok, isFalse);
      expect(outcome.errorKind, SettingsErrorCatalog.cancelled);
      expect(controller.lastProbe, isNull, reason: '迟到/取消的结果不得进入状态');
      expect(bridge.cancelledJobs, isNotEmpty);
    });

    test('a probe that exceeds the budget reports a timeout', () async {
      final bridge = FakeSettingsBridge()..nonTerminalPolls = 1000;
      final controller =
          await build(bridge, probeTimeout: const Duration(milliseconds: 30));

      final outcome = await controller.testModel('deepseek-official', 1);

      expect(outcome.ok, isFalse);
      expect(outcome.errorKind, SettingsErrorCatalog.timeout);
      expect(bridge.cancelledJobs, isNotEmpty);
    });

    test('a native probe failure is described, not swallowed', () async {
      final bridge = FakeSettingsBridge()
        ..probeOutcome = const ProbeOutcome(
          ok: false,
          kind: 'chat',
          httpStatus: 401,
          errorKind: 'auth',
          error: 'unauthorized',
        );
      final controller = await build(bridge);

      final outcome = await controller.testModel('deepseek-official', 1);
      expect(outcome.ok, isFalse);
      expect(SettingsErrorCatalog.describeProbe(outcome), contains('401'));
      expect(controller.lastProbe, outcome);
    });

    test('starting a probe without a bridge is refused with a readable reason',
        () async {
      final controller = await build(null);
      final outcome = await controller.discoverModels('deepseek-official', 1);
      expect(outcome.ok, isFalse);
      expect(SettingsErrorCatalog.describeProbe(outcome), contains('原生设置不可用'));
    });
  });

  // -------------------------------------------------------------------------
  // Real-DLL contract: skipped when `ts_bridge.dll` has not been built.
  //
  // The fake bridge above is written from the same rules as `ts_settings_merge()`, so a
  // real bridge is the only way to prove that the Dart payload is accepted by C. These
  // tests use a throw-away data directory and a fake `authMode=none` profile (no key).
  // -------------------------------------------------------------------------
  group('live DLL deletion contract', () {
    final buildDir = _bridgeBuildDir();
    final skipReason = buildDir == null
        ? 'ts_bridge.dll 未构建；请先运行 scripts/build_flutter_bridge.ps1'
        : null;

    Directory? liveDir;
    NativeGateway? live;

    tearDownAll(_unstageNativeLibs);

    tearDown(() async {
      final gateway = live;
      live = null;
      if (gateway != null && gateway.isOpen) await gateway.close();
      final dir = liveDir;
      if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<NativeGateway> openBridge(Directory dataDir) async {
      final configPath = await _writeMockConfig(dataDir.path);
      try {
        return NativeGateway.open(
          configPath: configPath,
          dataDir: dataDir.path,
          dllDirectories: <String>[buildDir!],
        );
      } on BridgeUnavailableException {
        // Windows only resolves the libcurl import from the DLL's own directory with
        // LOAD_WITH_ALTERED_SEARCH_PATH; if that is unavailable, stage both files next
        // to the test process (what bridge_live_test.dart does as well).
        _stageNativeLibs(buildDir!);
        return NativeGateway.open(
          configPath: configPath,
          dataDir: dataDir.path,
          dllDirectories: <String>[Directory.current.path],
        );
      }
    }

    test('an omitted profile is kept but deletedProfileIds really deletes it',
        () async {
      final dataDir = createTempDataDir('settings_live_delete');
      liveDir = dataDir;
      final gateway = live = await openBridge(dataDir);

      final created = gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[
          _liveProfile('live-a', model: 'model-a'),
          _liveProfile('live-b', model: 'model-b'),
        ],
        defaultProfileId: 'live-a',
        defaultModelId: 'model-a',
      ));
      expect(_profileOf(created, 'live-a')!['revision'], 1);
      expect(_profileOf(created, 'live-b')!['revision'], 1);

      // Omitting a saved connection from `profiles` must NOT delete it.
      final omitted = gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[_profileOf(created, 'live-a')!],
        defaultProfileId: 'live-a',
        defaultModelId: 'model-a',
      ));
      expect(_idsOf(omitted), containsAll(<String>['live-a', 'live-b']));
      expect(_profileOf(omitted, 'live-b')!['revision'], 1);

      // Only the explicit list removes it; the untouched connection keeps its revision.
      final deleted = gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[_profileOf(omitted, 'live-a')!],
        defaultProfileId: 'live-a',
        defaultModelId: 'model-a',
        deleted: <String>['live-b'],
      ));
      expect(_idsOf(deleted), isNot(contains('live-b')));
      expect(_idsOf(deleted), contains('live-a'));
      expect(_profileOf(deleted, 'live-a')!['revision'], 1);
    }, skip: skipReason);

    test('deleting the default or the last connection is validated natively',
        () async {
      final dataDir = createTempDataDir('settings_live_default');
      liveDir = dataDir;
      final gateway = live = await openBridge(dataDir);

      gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[
          _liveProfile('live-a', model: 'model-a'),
          _liveProfile('live-b', model: 'model-b'),
        ],
        defaultProfileId: 'live-b',
        defaultModelId: 'model-b',
      ));
      final current = gateway.settingsGet();

      // The default still points at the deleted connection: the native layer refuses.
      expect(
        () => gateway.settingsSave(_saveDoc(
          profiles: <Map<String, dynamic>>[_profileOf(current, 'live-a')!],
          defaultProfileId: 'live-b',
          defaultModelId: 'model-b',
          deleted: <String>['live-b'],
        )),
        throwsA(isA<NativeCallException>()
            .having((e) => e.kind, 'errorKind', 'validation')),
      );
      // Leaving the default empty while profiles remain is refused as well.
      expect(
        () => gateway.settingsSave(_saveDoc(
          profiles: <Map<String, dynamic>>[_profileOf(current, 'live-a')!],
          deleted: <String>['live-b'],
        )),
        throwsA(isA<NativeCallException>()),
      );

      // Deleting every connection with an empty default is legal and leaves no default.
      final all = _idsOf(gateway.settingsGet());
      final emptied = gateway.settingsSave(_saveDoc(
        profiles: const <Map<String, dynamic>>[],
        deleted: all,
      ));
      expect(_idsOf(emptied), isEmpty);
      expect(emptied['defaultProfileId'], isEmpty);
      expect(_idsOf(gateway.settingsGet()), isEmpty);
    }, skip: skipReason);

    test('a deletion survives a bridge restart', () async {
      final dataDir = createTempDataDir('settings_live_restart');
      liveDir = dataDir;
      final gateway = live = await openBridge(dataDir);

      gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[
          _liveProfile('live-a', model: 'model-a'),
          _liveProfile('live-b', model: 'model-b'),
        ],
        defaultProfileId: 'live-a',
        defaultModelId: 'model-a',
      ));
      final current = gateway.settingsGet();
      final afterDelete = gateway.settingsSave(_saveDoc(
        profiles: <Map<String, dynamic>>[_profileOf(current, 'live-a')!],
        defaultProfileId: 'live-a',
        defaultModelId: 'model-a',
        deleted: <String>['live-b'],
      ));
      expect(_idsOf(afterDelete), isNot(contains('live-b')));
      await gateway.close();
      live = null;

      // A brand-new bridge over the same data directory reads settings.json from disk.
      final reopened = live = await openBridge(dataDir);
      final reloaded = reopened.settingsGet();
      expect(_idsOf(reloaded), isNot(contains('live-b')));
      expect(_idsOf(reloaded), contains('live-a'));
      expect(_profileOf(reloaded, 'live-a')!['revision'], 1);
      expect(reloaded['defaultProfileId'], 'live-a');

      final settingsFile =
          File('${dataDir.path}${Platform.pathSeparator}settings.json');
      expect(settingsFile.existsSync(), isTrue);
      expect(settingsFile.readAsStringSync(), isNot(contains('live-b')));
    }, skip: skipReason);
  });
}

/// A [SettingsStore] whose second save (the rollback after a native failure) throws.
///
/// Reproduces "the preferences file accepted the new values but the rollback failed":
/// the controller must then follow the file instead of pretending nothing was written.
class _FlakySettingsStore extends SettingsStore {
  _FlakySettingsStore(super.root);

  int saves = 0;

  @override
  Future<void> save(AppPreferences prefs) async {
    saves++;
    if (saves == 2) {
      throw const FileSystemException('模拟：回滚写入失败');
    }
    await super.save(prefs);
  }
}

// ---------------------------------------------------------------------------
// Helpers for the real-DLL group.
// ---------------------------------------------------------------------------

/// Directory holding a built `ts_bridge.dll`, or `null` when it has not been built.
String? _bridgeBuildDir() {
  final candidates = <String>[
    '${Directory.current.parent.path}${Platform.pathSeparator}build-flutter'
        '${Platform.pathSeparator}Release',
    '${Directory.current.path}${Platform.pathSeparator}..'
        '${Platform.pathSeparator}build-flutter${Platform.pathSeparator}Release',
    '${Directory.current.path}${Platform.pathSeparator}build-flutter'
        '${Platform.pathSeparator}Release',
  ];
  for (final candidate in candidates) {
    final dll = File('$candidate${Platform.pathSeparator}ts_bridge.dll');
    if (dll.existsSync()) return Directory(candidate).absolute.path;
  }
  return null;
}

final Set<String> _stagedLibs = <String>{};

/// Copies `ts_bridge.dll` + `libcurl-x64.dll` next to the test process when the direct
/// absolute load is not enough. Only files created here are removed again.
void _stageNativeLibs(String sourceDir) {
  for (final name in <String>['ts_bridge.dll', 'libcurl-x64.dll']) {
    final source = File('$sourceDir${Platform.pathSeparator}$name');
    if (!source.existsSync()) continue;
    final target =
        File('${Directory.current.path}${Platform.pathSeparator}$name');
    if (target.existsSync()) continue;
    try {
      source.copySync(target.path);
      _stagedLibs.add(target.path);
    } catch (_) {
      // Another test process is using it; the absolute load is the normal path anyway.
    }
  }
}

void _unstageNativeLibs() {
  for (final path in _stagedLibs) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      file.deleteSync();
    } catch (_) {
      // Still mapped by a running process; harmless for the test run.
    }
  }
  _stagedLibs.clear();
}

/// Minimal mock config: the live tests never touch the network.
Future<String> _writeMockConfig(String dir) async {
  final file = File('$dir${Platform.pathSeparator}live_config.json');
  await file.writeAsString(jsonEncode(<String, dynamic>{
    'endpoint_url': 'https://example.invalid/chat/completions',
    'model': 'dart-live-settings',
    'api_key_env': '',
    'mock_mode': true,
    'connect_timeout_ms': 15000,
    'wait_prompt_ms': 120000,
    'request_timeout_ms': 0,
    'json_mode': true,
  }));
  return file.path;
}

/// The native settings request shape used by the live group.
Map<String, dynamic> _saveDoc({
  required List<Map<String, dynamic>> profiles,
  String defaultProfileId = '',
  String defaultModelId = '',
  List<String> deleted = const <String>[],
}) =>
    <String, dynamic>{
      'schemaVersion': 2,
      'defaultProfileId': defaultProfileId,
      'defaultModelId': defaultModelId,
      'defaultThinking': 'unsupported',
      'defaultReasoningEffort': null,
      'profiles': profiles,
      if (deleted.isNotEmpty) 'deletedProfileIds': deleted,
    };

/// A fake connection with `authMode=none`: no key is ever written by these tests.
Map<String, dynamic> _liveProfile(String id, {required String model}) =>
    <String, dynamic>{
      'id': id,
      'name': '连接 $id',
      'revision': 0,
      'protocol': 'openai-chat',
      'baseUrl': 'http://127.0.0.1:9',
      'chatUrl': 'http://127.0.0.1:9/chat/completions',
      'modelsUrl': '',
      'authMode': 'none',
      'apiKeyEnv': '',
      'modelId': model,
      'thinking': 'unsupported',
      'reasoningEffort': null,
      'jsonMode': false,
    };

List<String> _idsOf(Map<String, dynamic> document) =>
    ((document['profiles'] as List<dynamic>?) ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map((p) => (p['id'] as String?) ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

Map<String, dynamic>? _profileOf(
    Map<String, dynamic> document, String id) {
  for (final raw
      in (document['profiles'] as List<dynamic>?) ?? const <dynamic>[]) {
    if (raw is Map<String, dynamic> && raw['id'] == id) return raw;
  }
  return null;
}

