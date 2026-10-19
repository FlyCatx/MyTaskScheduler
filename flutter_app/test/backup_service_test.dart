// Unit tests for backup / restore / cache maintenance.
//
// Covered:
//   * the backup contains no key material;
//   * restore validates before touching anything and keeps the previous files byte for
//     byte on failure;
//   * restore is refused while an analysis runs or while the settings draft is dirty;
//   * a same-id conversation with *different* content rejects the whole import, while an
//     identical one is skipped (a second restore changes nothing);
//   * a partially failed commit is rolled back and reported file by file (never "全部恢复
//     成功");
//   * cache cleanup only deletes files this program wrote into `<root>/cache`; `.tmp`
//     files in the root, conversations/, attachments/ and settings/ are never touched,
//     and the preview is exactly the set that gets deleted.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/backup_service.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import 'support/test_support.dart';

/// Joins path segments with the platform separator.
String _p(List<String> parts) => parts.join(Platform.pathSeparator);

void main() {
  late Directory dir;
  late SessionStore store;
  late SettingsStore settingsStore;
  late SettingsController settings;
  late BackupService backups;
  late String backupPath;

  setUp(() async {
    dir = createTempDataDir('backup');
    store = SessionStore(dir);
    settingsStore = SettingsStore(dir);
    settings = SettingsController(
      store: settingsStore,
      bridge: FakeSettingsBridge(),
    );
    addTearDown(settings.dispose);
    await settings.load();
    backups = BackupService(
      store: store,
      root: dir,
      settings: settings,
      settingsStore: settingsStore,
    );
    backupPath = '${dir.path}${Platform.pathSeparator}backup.json';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('export', () {
    test('writes one JSON document with prefs, index, sessions and profiles',
        () async {
      await seedConversation(store);
      settings.updateDraftPreferences(
          settings.prefs.copyWith(themeMode: AppThemeMode.dark));
      expect(await settings.save(), isNull);

      final result = await backups.exportBackup(backupPath);

      expect(result.conversationCount, 1);
      expect(result.profileCount, 1);
      expect(result.byteLength, greaterThan(0));
      final doc = jsonDecode(await File(backupPath).readAsString())
          as Map<String, dynamic>;
      expect(doc['schemaVersion'], BackupService.schemaVersion);
      expect(doc['kind'], BackupService.backupKind);
      expect(doc['exportedAt'], isA<String>());
      final prefs = doc['appPrefs'] as Map<String, dynamic>;
      expect(prefs['themeMode'], 'dark');
      expect((doc['index'] as List<dynamic>), hasLength(1));
      expect((doc['conversations'] as List<dynamic>), hasLength(1));
      final settingsDoc = doc['settings'] as Map<String, dynamic>;
      expect(settingsDoc['defaultProfileId'], 'deepseek-official');
      expect((settingsDoc['profiles'] as List<dynamic>), hasLength(1));
      // Atomic write: no staging file left behind.
      expect(File('$backupPath.tmp').existsSync(), isFalse);
    });

    test('never contains key material', () async {
      await seedConversation(store);
      await backups.exportBackup(backupPath);

      final doc = jsonDecode(await File(backupPath).readAsString())
          as Map<String, dynamic>;
      final sensitive = _findSensitiveKeys(doc);
      expect(sensitive, isEmpty, reason: '备份中不得出现任何密钥字段：$sensitive');
      final profiles = (doc['settings'] as Map<String, dynamic>)['profiles']
          as List<dynamic>;
      for (final raw in profiles.cast<Map<String, dynamic>>()) {
        expect(raw.containsKey('apiKey'), isFalse);
        expect(raw.containsKey('key'), isFalse);
      }
    });
  });

  group('restore', () {
    test('rejects a missing file without touching existing data', () async {
      await seedConversation(store);
      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final before = await convFile.readAsString();

      final result = await backups.restoreBackup('$backupPath.missing');

      expect(result.ok, isFalse);
      expect(result.error, contains('不存在'));
      expect(await convFile.readAsString(), before);
    });

    test('rejects invalid JSON and preserves the previous index', () async {
      await seedConversation(store);
      final indexFile = File(_p([dir.path, 'index.json']));
      final before = await indexFile.readAsString();
      await File(backupPath).writeAsString('{ not json');

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('JSON'));
      expect(await indexFile.readAsString(), before);
      expect(indexFile.existsSync(), isTrue);
    });

    test('rejects an unsupported schema version', () async {
      await seedConversation(store);
      await File(backupPath).writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': 99,
        'conversations': <dynamic>[],
      }));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('99'));
    });

    test('rejects a conversation with an invalid id before writing anything',
        () async {
      await seedConversation(store);
      await File(backupPath).writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': BackupService.schemaVersion,
        'conversations': <dynamic>[
          <String, dynamic>{'id': '../escape', 'versions': <dynamic>[]},
        ],
      }));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('ID'));
      // Nothing escaped the data folder.
      expect(File(_p([dir.path, '..', 'escape.json'])).existsSync(), isFalse);
    });

    test('an index pointing at a missing conversation is rejected', () async {
      await seedConversation(store);
      await File(backupPath).writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': BackupService.schemaVersion,
        'conversations': <dynamic>[],
        'index': <dynamic>[
          <String, dynamic>{'id': 'ghost', 'title': '幽灵'},
        ],
      }));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('ghost'));
    });

    test('a valid backup restores conversations, keeps history and leaves .bak',
        () async {
      await seedConversation(store);
      final restored = _newConversation();
      final seeded = (await store.loadConversation('conv-seed'))!;
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[restored, seeded],
        appPrefs: const AppPreferences(themeMode: AppThemeMode.dark).toJson(),
        settings: <String, dynamic>{
          'schemaVersion': 2,
          'defaultProfileId': 'deepseek-official',
          'defaultModelId': 'deepseek-chat',
          'profiles': <dynamic>[sampleProfile().toJson()],
        },
      ));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      expect(result.conversationCount, 2);
      expect(result.restoredConversationCount, 1);
      expect(result.skippedConversationCount, 1,
          reason: '内容相同的既有会话必须跳过（幂等），不得重写或覆盖');
      expect(result.restoredPrefs, isTrue);
      expect(result.prefsReloaded, isTrue);
      expect(result.backupPaths, isNotEmpty);
      expect(result.sessionsReloaded, isFalse);
      expect(result.requiresRestart, isTrue,
          reason: '没有注入刷新回调时必须如实要求重启，不能假装 UI 已同步');

      final reloaded = await store.loadConversation('conv-restored');
      expect(reloaded, isNotNull);
      expect(reloaded!.modelSelection, sampleSelection(),
          reason: '会话的模型选择必须持久化');
      expect(await store.loadConversation('conv-seed'), isNotNull,
          reason: '恢复不得删除备份之外的既有会话');
      expect((await settingsStore.load()).prefs.themeMode, AppThemeMode.dark);
      expect(settings.prefs.themeMode, AppThemeMode.dark,
          reason: '恢复后的偏好必须写回内存中的控制器');

      final index = await store.loadIndex();
      expect(index.map((s) => s.id),
          containsAll(<String>['conv-seed', 'conv-restored']));
      // The previous index is recoverable.
      expect(File(_p([dir.path, 'index.json.bak'])).existsSync(), isTrue);
      // The backed-up connection already existed locally with a working credential.
      // The backup contains no key, so restoring must not pretend the existing key was
      // cleared (or delete it): the "re-enter after restore" rule applies to NEW
      // connections, covered by the empty-settings test below.
      expect(result.warning, isNull);
      expect(settings.profileById('deepseek-official')?.credentialConfigured,
          isTrue);
      expect(settings.defaultSelection?.profileId, 'deepseek-official');
    });

    test('restores model connections into an empty settings file, without keys',
        () async {
      final bridge = FakeSettingsBridge(settings: emptySettingsDocument());
      final localStore = SettingsStore(dir);
      final localSettings =
          SettingsController(store: localStore, bridge: bridge);
      addTearDown(localSettings.dispose);
      await localSettings.load();
      final service = BackupService(
        store: store,
        root: dir,
        settings: localSettings,
        settingsStore: localStore,
      );
      await File(backupPath).writeAsString(_backupJsonWithProfile(
        profileId: 'restored-conn',
        profileRevision: 3,
      ));

      final result = await service.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      expect(result.warning, isNull);
      expect(result.restoredProfileCount, 1);
      final stored = localSettings.profileById('restored-conn');
      expect(stored, isNotNull);
      expect(stored!.revision, 1,
          reason: '新连接以 revision 0 恢复，由原生侧变成 1');
      expect(stored.credentialConfigured, isFalse,
          reason: '备份不含密钥，恢复后必须重新输入');
      expect(localSettings.defaultSelection?.profileId, 'restored-conn');
      // The saved payload must never carry key material.
      for (final payload in bridge.savedPayloads) {
        expect(_findSensitiveKeys(payload), isEmpty);
      }
    });

    test('refuses to run while the settings draft has unsaved changes',
        () async {
      await seedConversation(store);
      settings.updateDraftPreferences(
          settings.prefs.copyWith(themeMode: AppThemeMode.dark));
      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final before = await convFile.readAsString();
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
        appPrefs: const AppPreferences(themeMode: AppThemeMode.light).toJson(),
      ));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('请先保存或放弃设置修改再恢复'));
      expect(await convFile.readAsString(), before,
          reason: '拒绝时不得改动任何会话文件');
      expect(File(_p([dir.path, 'conversations', 'conv-restored.json']))
          .existsSync(), isFalse);
      expect(File(_p([dir.path, 'settings', 'app_prefs.json'])).existsSync(),
          isFalse, reason: '拒绝时不得写入偏好文件');
      expect(File(_p([dir.path, 'index.json.bak'])).existsSync(), isFalse);
      expect(settings.dirty, isTrue, reason: '用户的草稿不能被恢复操作丢掉');
    });

    test('refuses to run while an analysis is in progress (injected isBusy)',
        () async {
      await seedConversation(store);
      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final before = await convFile.readAsString();
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
      ));
      var busyChecks = 0;
      final service = BackupService(
        store: store,
        root: dir,
        settings: settings,
        settingsStore: settingsStore,
        isBusy: () {
          busyChecks++;
          return true;
        },
      );

      final result = await service.restoreBackup(backupPath);

      expect(busyChecks, greaterThan(0), reason: '必须真的询问注入的分析状态');
      expect(result.ok, isFalse);
      expect(result.error, contains('分析中'));
      expect(await convFile.readAsString(), before);
      expect(File(_p([dir.path, 'conversations', 'conv-restored.json']))
          .existsSync(), isFalse);
      expect(File(_p([dir.path, 'index.json.bak'])).existsSync(), isFalse);
      expect(backups.restoreStagingDirectory.existsSync(), isFalse,
          reason: '拒绝时连暂存目录都不应创建');
    });

    test('rejects the whole import when a same-id conversation differs',
        () async {
      await seedConversation(store);
      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final indexFile = File(_p([dir.path, 'index.json']));
      final convBefore = await convFile.readAsString();
      final indexBefore = await indexFile.readAsString();
      final local = (await store.loadConversation('conv-seed'))!;
      final changed = local.copyWith(title: '被改过的标题');
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[changed],
        appPrefs: const AppPreferences(themeMode: AppThemeMode.dark).toJson(),
      ));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('内容不同'));
      expect(result.error, contains('conv-seed'));
      expect(result.error, contains('未恢复任何数据'));
      expect(result.conflictConversationIds, <String>['conv-seed']);
      expect(await convFile.readAsString(), convBefore,
          reason: '同 ID 内容不同必须整体拒绝，原文件字节不变');
      expect(await indexFile.readAsString(), indexBefore);
      expect(File('${convFile.path}.bak').existsSync(), isFalse);
      expect(File('${indexFile.path}.bak').existsSync(), isFalse);
      expect(File(_p([dir.path, 'settings', 'app_prefs.json'])).existsSync(),
          isFalse, reason: '整体拒绝时偏好也不得写入');
    });

    test('a same-id identical conversation is skipped and nothing is rewritten',
        () async {
      await seedConversation(store);
      await settingsStore.save(const AppPreferences());
      final exported =
          _p([dir.parent.path, 'idem-${DateTime.now().microsecondsSinceEpoch}.json']);
      addTearDown(() {
        try {
          final file = File(exported);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // ignore
        }
      });
      await backups.exportBackup(exported);

      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final indexFile = File(_p([dir.path, 'index.json']));
      final prefsFile = File(_p([dir.path, 'settings', 'app_prefs.json']));
      final convBefore = await convFile.readAsString();
      final indexBefore = await indexFile.readAsString();
      final prefsBefore = await prefsFile.readAsString();

      final result = await backups.restoreBackup(exported);

      expect(result.ok, isTrue);
      expect(result.restoredConversationCount, 0);
      expect(result.skippedConversationCount, 1);
      expect(result.restoredPrefs, isFalse,
          reason: '内容相同的偏好不重写，避免无意义的 .bak 与改动');
      expect(await convFile.readAsString(), convBefore);
      expect(await indexFile.readAsString(), indexBefore);
      expect(await prefsFile.readAsString(), prefsBefore);
      expect(File('${convFile.path}.bak').existsSync(), isFalse);
      expect(File('${indexFile.path}.bak').existsSync(), isFalse);
      expect(File('${prefsFile.path}.bak').existsSync(), isFalse,
          reason: '幂等恢复不得留下 .bak');
      expect(result.summary, contains('内容相同'));
    });

    test('rolls a partially committed restore back and reports the files',
        () async {
      await seedConversation(store);
      final convFile = File(_p([dir.path, 'conversations', 'conv-seed.json']));
      final indexFile = File(_p([dir.path, 'index.json']));
      final convBefore = await convFile.readAsString();
      final indexBefore = await indexFile.readAsString();
      // A directory where the second staged conversation must be promoted: the rename
      // fails, so the first (already promoted) file has to be rolled back.
      final blocked = Directory(
          _p([dir.path, 'conversations', 'conv-new-2.json']));
      await blocked.create(recursive: true);
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[
          _newConversation(id: 'conv-new-1'),
          _newConversation(id: 'conv-new-2'),
        ],
        appPrefs: const AppPreferences(themeMode: AppThemeMode.dark).toJson(),
      ));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('恢复提交失败'));
      expect(result.error, contains('已回滚 1 个文件'));
      expect(result.rolledBackPaths, hasLength(1));
      expect(result.rolledBackPaths.single, contains('conv-new-1'));
      expect(result.dataUnchanged, isFalse,
          reason: '发生过替换就不能声称“原有数据未被修改”');
      expect(
          File(_p([dir.path, 'conversations', 'conv-new-1.json'])).existsSync(),
          isFalse,
          reason: '已提交的文件必须被回滚删除');
      expect(blocked.existsSync(), isTrue);
      expect(await convFile.readAsString(), convBefore);
      expect(await indexFile.readAsString(), indexBefore);
      expect(File(_p([dir.path, 'settings', 'app_prefs.json'])).existsSync(),
          isFalse);
      expect(backups.restoreStagingDirectory.listSync(), isEmpty,
          reason: '回滚后不得残留暂存文件');
    });

    test('reloads preferences and refreshes the session list through the callback',
        () async {
      await seedConversation(store);
      await settingsStore.save(const AppPreferences());
      var reloadCalls = 0;
      final service = BackupService(
        store: store,
        root: dir,
        settings: settings,
        settingsStore: settingsStore,
        reloadSessions: () async {
          reloadCalls++;
        },
      );
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
        appPrefs: const AppPreferences(themeMode: AppThemeMode.dark).toJson(),
      ));

      final result = await service.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      expect(result.restoredPrefs, isTrue);
      expect(result.prefsReloaded, isTrue);
      expect(settings.prefs.themeMode, AppThemeMode.dark);
      expect(reloadCalls, 1);
      expect(result.sessionsReloaded, isTrue);
      expect(result.requiresRestart, isFalse,
          reason: '会话已刷新且偏好已重读时不需要重启');
      expect(result.warning, isNull);
    });

    test('reports a failed session refresh instead of claiming it succeeded',
        () async {
      await seedConversation(store);
      final service = BackupService(
        store: store,
        root: dir,
        settings: settings,
        settingsStore: settingsStore,
        reloadSessions: () async => throw StateError('列表已释放'),
      );
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
      ));

      final result = await service.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      expect(result.sessionsReloaded, isFalse);
      expect(result.requiresRestart, isTrue);
      expect(result.warning, contains('刷新会话列表失败'));
    });

    test('reports a readable warning when connections cannot be saved', () async {
      final bridge = FakeSettingsBridge(settings: emptySettingsDocument())
        ..saveFailure =
            NativeCallException('revision', '模型配置版本不一致，请刷新设置后重试');
      final localStore = SettingsStore(dir);
      final localSettings =
          SettingsController(store: localStore, bridge: bridge);
      addTearDown(localSettings.dispose);
      await localSettings.load();
      final service = BackupService(
        store: store,
        root: dir,
        settings: localSettings,
        settingsStore: localStore,
      );
      await File(backupPath)
          .writeAsString(_backupJsonWithProfile(profileId: 'fail-conn'));

      final result = await service.restoreBackup(backupPath);

      expect(result.ok, isTrue, reason: '会话/偏好已恢复，不能整体报失败');
      expect(result.restoredProfileCount, 0);
      expect(result.warning, contains('模型连接未恢复'));
      expect(result.warning, contains('版本'));
      expect(localSettings.profileById('fail-conn'), isNull);
      expect(localSettings.dirty, isFalse, reason: '失败后草稿要回到原状');
    });

    test('explains that connections cannot be restored without a controller',
        () async {
      final service = BackupService(
        store: store,
        root: dir,
        settingsStore: settingsStore,
      );
      await File(backupPath)
          .writeAsString(_backupJsonWithProfile(profileId: 'orphan'));

      final result = await service.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      expect(result.restoredProfileCount, 0);
      expect(result.warning, contains('没有可用的设置控制器'));
    });

    test('an oversized file is refused before it is parsed', () async {
      final limited = BackupService(
        store: store,
        root: dir,
        settings: settings,
        settingsStore: settingsStore,
        maxImportBytesLimit: 1024,
      );
      await File(backupPath).writeAsString('x' * 4096);

      final result = await limited.restoreBackup(backupPath);

      expect(result.ok, isFalse);
      expect(result.error, contains('过大'));
    });

    test('stages inside <root>/cache/restore and leaves no .tmp beside the data',
        () async {
      await seedConversation(store);
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
      ));

      final result = await backups.restoreBackup(backupPath);

      expect(result.ok, isTrue);
      final conversationsDir = Directory(_p([dir.path, 'conversations']));
      final leftovers = conversationsDir.listSync().where((entity) {
        final name = entity.path.split(Platform.pathSeparator).last;
        return name.endsWith('.tmp') || name.contains('.restore.');
      }).toList();
      expect(leftovers, isEmpty,
          reason: '暂存文件不得写回用户的数据目录（不能是 target 旁的 .restore.tmp）');
      expect(
        backups.restoreStagingDirectory.path,
        endsWith(_p([BackupService.cacheDirectoryName,
            BackupService.restoreStagingName])),
      );
      expect(backups.restoreStagingDirectory.listSync(), isEmpty,
          reason: '提交成功后暂存目录必须为空');
    });
  });

  group('cache cleanup', () {
    test('deletes only app-owned cache files and never scans user folders',
        () async {
      await seedConversation(store);
      final conversationsDir = Directory(_p([dir.path, 'conversations']));
      final attachmentsDir = Directory(_p([dir.path, 'attachments']))
        ..createSync(recursive: true);
      final userSettingsDir = Directory(_p([dir.path, 'settings']))
        ..createSync(recursive: true);
      final cacheDir = Directory(_p([dir.path, BackupService.cacheDirectoryName]))
        ..createSync(recursive: true);
      final restoreDir =
          Directory(_p([cacheDir.path, BackupService.restoreStagingName]))
            ..createSync(recursive: true);

      // Would be deleted by the old ".tmp anywhere" implementation: all must survive.
      final rootTmp = File(_p([dir.path, 'write.tmp']))
        ..writeAsStringSync('root');
      final convTmp = File(_p([conversationsDir.path, 'active.json.tmp']))
        ..writeAsStringSync('conv');
      final attTmp = File(_p([attachmentsDir.path, 'user.tmp']))
        ..writeAsStringSync('user-attachment');
      final prefsTmp = File(_p([userSettingsDir.path, 'app_prefs.json.tmp']))
        ..writeAsStringSync('prefs');
      final userFile = File(_p([dir.path, 'notes.txt']))
        ..writeAsStringSync('keep me');
      final history = File(_p([conversationsDir.path, 'conv-seed.json']));
      final attachment = File(_p([attachmentsDir.path, 'att-1.json']))
        ..writeAsStringSync('{"id":"att-1"}');

      // App-owned cache files: named by this program, so they are cache.
      final cacheOne = File(_p([cacheDir.path, 'tsc-cleanup-1.tmp']))
        ..writeAsStringSync('abcde');
      final cacheTwo = File(_p([cacheDir.path, 'tsc-cleanup-2.json']))
        ..writeAsStringSync('1234567');
      // Unknown file in the cache directory: not ours, must survive.
      final cacheForeign = File(_p([cacheDir.path, 'notes.txt']))
        ..writeAsStringSync('keep');
      final cacheDotFile = File(_p([cacheDir.path, '.marker']))
        ..writeAsStringSync('keep');
      // Restore staging: never treated as cleanable cache.
      final staging =
          File(_p([restoreDir.path, 'tsc-restore-conversation-x.json']))
            ..writeAsStringSync('staged');

      final preview = await backups.scanCache();
      expect(preview.fileCount, 2);
      expect(preview.names, <String>['tsc-cleanup-1.tmp', 'tsc-cleanup-2.json']);
      expect(preview.bytes, 12);

      final result = await backups.clearCache();

      expect(result.deletedFiles, 2);
      expect(result.bytes, 12);
      expect(result.paths.toSet(), preview.names.toSet());
      expect(result.skipped, isFalse);
      expect(result.failedPaths, isEmpty);
      expect(cacheOne.existsSync(), isFalse);
      expect(cacheTwo.existsSync(), isFalse);
      // Nothing in the user folders is deleted — not even a `.tmp`.
      expect(rootTmp.existsSync(), isTrue);
      expect(convTmp.existsSync(), isTrue);
      expect(attTmp.existsSync(), isTrue);
      expect(prefsTmp.existsSync(), isTrue);
      expect(userFile.existsSync(), isTrue);
      expect(history.existsSync(), isTrue);
      expect(attachment.existsSync(), isTrue);
      // Unknown cache content and the staging area are preserved.
      expect(cacheForeign.existsSync(), isTrue);
      expect(cacheDotFile.existsSync(), isTrue);
      expect(staging.existsSync(), isTrue);
      expect(cacheDir.existsSync(), isTrue, reason: '缓存目录本身必须保留');
    });

    test('the preview is exactly the set cleanup deletes', () async {
      final cacheDir = Directory(_p([dir.path, BackupService.cacheDirectoryName]))
        ..createSync(recursive: true);
      for (var i = 0; i < 3; i++) {
        File(_p([cacheDir.path, 'tsc-part-$i.bin']))
            .writeAsStringSync('x' * (i + 1));
      }
      File(_p([cacheDir.path, 'keep-me.txt'])).writeAsStringSync('user');

      final preview = await backups.scanCache();
      final result = await backups.clearCache();

      expect(result.deletedFiles, preview.fileCount);
      expect(result.bytes, preview.bytes);
      expect(result.paths.toSet(), preview.names.toSet());
      expect((await backups.scanCache()).isEmpty, isTrue);
      expect((await backups.clearCache()).deletedFiles, 0);
      expect(File(_p([cacheDir.path, 'keep-me.txt'])).existsSync(), isTrue);
    });

    test('keeps the lock file, the cache directory and reports what it freed',
        () async {
      final cacheDir = Directory(_p([dir.path, BackupService.cacheDirectoryName]))
        ..createSync(recursive: true);
      File(_p([cacheDir.path, 'tsc-1.tmp'])).writeAsStringSync('12345');

      final result = await backups.clearCache();

      expect(result.deletedFiles, 1);
      expect(result.summary, contains('已清理 1 个缓存文件'));
      expect(backups.cacheLockFile.existsSync(), isTrue,
          reason: '锁文件必须保留（删除会破坏跨进程互斥）');
      expect(result.paths, isNot(contains(BackupService.cacheLockFileName)));
      expect(cacheDir.existsSync(), isTrue);
      // The lock file is not itself reported as cache.
      expect((await backups.scanCache()).isEmpty, isTrue);
    });

    test('a cleanup running during a restore does not damage the restore',
        () async {
      await seedConversation(store);
      final cacheDir = Directory(_p([dir.path, BackupService.cacheDirectoryName]))
        ..createSync(recursive: true);
      final stale = File(_p([cacheDir.path, 'tsc-stale.tmp']))
        ..writeAsStringSync('stale');
      await File(backupPath).writeAsString(_backupJson(
        conversations: <Conversation>[_newConversation()],
      ));

      // Both operations run concurrently; the service serialises them, so the cleanup
      // can never observe or delete a half-staged restore.
      final restoreFuture = backups.restoreBackup(backupPath);
      final clearFuture = backups.clearCache();
      final restoreResult = await restoreFuture;
      final clearResult = await clearFuture;

      expect(restoreResult.ok, isTrue);
      expect(restoreResult.restoredConversationCount, 1);
      expect(clearResult.deletedFiles, 1);
      expect(clearResult.paths, <String>['tsc-stale.tmp']);
      expect(stale.existsSync(), isFalse);
      // The restored conversation and its index survived, and the staging area is empty.
      expect(await store.loadConversation('conv-restored'), isNotNull);
      expect(await store.loadIndex(), isNotEmpty);
      expect(backups.restoreStagingDirectory.listSync(), isEmpty,
          reason: '清理不得删除恢复用的暂存目录');
    });
  });

  group('directory size', () {
    test('counts the files it can see', () async {
      await seedConversation(store);
      final usage = await backups.directorySize();
      expect(usage.files, greaterThan(0));
      expect(usage.bytes, greaterThan(0));
      expect(usage.formatted, isNotEmpty);
    });

    test('formats byte counts for the storage page', () {
      expect(formatByteCount(512), '512 B');
      expect(formatByteCount(2048), contains('KB'));
      expect(formatByteCount(5 * 1024 * 1024), contains('MB'));
    });
  });
}

/// A brand-new conversation, as found in a backup written by another install.
Conversation _newConversation({
  String id = 'conv-restored',
  String title = '恢复的会话',
  DateTime? at,
}) {
  final when = at ?? DateTime(2026, 11, 1);
  final version = PlanVersion(
    id: 'ver-$id',
    conversationId: id,
    createdAt: when,
    summary: '恢复的计划',
  );
  return Conversation(
    id: id,
    title: title,
    createdAt: when,
    updatedAt: when,
    versions: <PlanVersion>[version],
    currentVersionId: version.id,
    modelSelection: sampleSelection(),
  );
}

/// Builds one backup document. The index defaults to the conversations, which is what a
/// real export writes.
String _backupJson({
  List<Conversation> conversations = const <Conversation>[],
  List<ConversationSummary>? index,
  Map<String, dynamic>? appPrefs,
  Map<String, dynamic>? settings,
}) {
  final summaries =
      index ?? conversations.map(ConversationSummary.of).toList(growable: false);
  return jsonEncode(<String, dynamic>{
    'schemaVersion': BackupService.schemaVersion,
    'kind': BackupService.backupKind,
    if (appPrefs != null) 'appPrefs': appPrefs,
    if (settings != null) 'settings': settings,
    'conversations':
        conversations.map((c) => c.toJson()).toList(growable: false),
    'index': summaries.map((s) => s.toJson()).toList(growable: false),
  });
}

/// A minimal but valid backup document holding one connection (and no sessions).
String _backupJsonWithProfile({
  required String profileId,
  int profileRevision = 1,
  Map<String, dynamic>? appPrefs,
}) =>
    jsonEncode(<String, dynamic>{
      'schemaVersion': BackupService.schemaVersion,
      'kind': BackupService.backupKind,
      if (appPrefs != null) 'appPrefs': appPrefs,
      'conversations': <dynamic>[],
      'index': <dynamic>[],
      'settings': <String, dynamic>{
        'schemaVersion': 2,
        'defaultProfileId': profileId,
        'defaultModelId': 'restored-model',
        'profiles': <dynamic>[
          sampleProfile(
            id: profileId,
            name: '恢复的连接',
            revision: profileRevision,
          ).toJson(),
        ],
      },
    });

/// Recursively collects keys that look like credential material.
List<String> _findSensitiveKeys(Object? value, [String prefix = '']) {
  final out = <String>[];
  if (value is Map) {
    for (final entry in value.entries) {
      final name = entry.key.toString();
      final normalized = name.replaceAll('_', '').replaceAll('-', '').toLowerCase();
      const sensitive = <String>{
        'apikey',
        'key',
        'token',
        'secret',
        'password',
        'authorization',
        'credential',
      };
      if (sensitive.contains(normalized)) {
        out.add('$prefix/$name');
      }
      out.addAll(_findSensitiveKeys(entry.value, '$prefix/$name'));
    }
  } else if (value is List) {
    for (var i = 0; i < value.length; i++) {
      out.addAll(_findSensitiveKeys(value[i], '$prefix[$i]'));
    }
  }
  return out;
}

