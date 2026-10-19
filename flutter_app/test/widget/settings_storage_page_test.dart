// Widget + service tests for 「设置 → 存储」.
//
// What must hold:
//   * the page shows the REAL data directory, the persistence state and the size/count;
//   * the source label is only marked "inferred" when it really was inferred;
//   * "打开目录" reports a failure reason and never a fake success;
//   * a backup is a single key-less JSON file; restore validates before touching
//     anything (a rejected file leaves the previous data byte-identical, no `.bak`);
//   * restore is disabled while an analysis runs, and the success message only claims
//     what really happened ("会话列表已刷新" vs. "需重启");
//   * cache cleanup previews the real cache directory through `BackupService.scanCache`
//     (one implementation for preview + delete) and reports skip reasons instead of a
//     fake success.
//
// The widget cases inject a stub BackupService so they stay deterministic and never
// touch the real DLL or the network; the service cases below them use a real temporary
// directory and the real BackupService.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/backup_service.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_storage_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

/// Joins path segments with the platform separator.
String _p(List<String> parts) => parts.join(Platform.pathSeparator);

/// Isolated data directory for one test.
Directory _dataDir(String name) {
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

SettingsController _controller(Directory dir) =>
    SettingsController(store: SettingsStore(dir));

/// In-memory [BackupService] so widget tests never depend on real files.
class _StubBackupService extends BackupService {
  _StubBackupService({
    required super.store,
    required super.root,
  });

  DirectoryUsage usage = const DirectoryUsage(bytes: 2048, files: 3);
  BackupRestoreResult restoreResult = const BackupRestoreResult(
    ok: true,
    conversationCount: 2,
    restoredConversationCount: 2,
    restoredPrefs: true,
    profileCount: 1,
  );
  CachePreview cachePreview = const CachePreview(
    directory: r'C:\data\cache',
    entries: <CachePreviewEntry>[
      CachePreviewEntry(name: 'tsc-a.tmp', bytes: 64),
      CachePreviewEntry(name: 'tsc-b.tmp', bytes: 64),
    ],
  );
  CacheClearResult clearResult = const CacheClearResult(
    deletedFiles: 2,
    bytes: 128,
    paths: <String>['tsc-a.tmp', 'tsc-b.tmp'],
  );

  String? exportedTo;
  String? restoredFrom;
  int clearCalls = 0;
  int scanCalls = 0;

  @override
  Future<DirectoryUsage> directorySize() async => usage;

  @override
  Future<CachePreview> scanCache() async {
    scanCalls++;
    return cachePreview;
  }

  @override
  Future<BackupExportResult> exportBackup(String path) async {
    exportedTo = path;
    return BackupExportResult(
      path: path,
      conversationCount: 2,
      profileCount: 1,
      byteLength: 2048,
    );
  }

  @override
  Future<BackupRestoreResult> restoreBackup(String path) async {
    restoredFrom = path;
    return restoreResult;
  }

  @override
  Future<CacheClearResult> clearCache() async {
    clearCalls++;
    return clearResult;
  }
}

_StubBackupService _stub(Directory dir) => _StubBackupService(
      store: InMemorySessionRepository(),
      root: dir,
    );

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: page),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TsColors.apply(Brightness.light);

  group('存储页', () {
    testWidgets('显示占用统计；常驻页面不再展示完整路径与来源说明', (tester) async {
      final dir = _dataDir('storage_render');
      final controller = _controller(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: _stub(dir)),
      );

      // 0.07: the full local path, the "来源 portable …" line, the "持久化 可写 …"
      // line and the migration explanation were removed as permanent implementation
      // detail. The real information (占用) and the actions stay.
      expect(find.text('数据目录'), findsOneWidget);
      expect(find.text(dir.path), findsNothing, reason: '完整本机路径不再常驻显示');
      expect(find.textContaining('由程序路径推断'), findsNothing);
      expect(find.textContaining('未知来源'), findsNothing);
      expect(find.textContaining('可写（数据保存在磁盘上）'), findsNothing);
      expect(find.textContaining('迁移只复制并校验'), findsNothing);
      expect(find.textContaining('2.0 KB'), findsOneWidget);
      expect(find.textContaining('3 个文件'), findsOneWidget);
      // The functionality named in the requirement is all still there.
      expect(find.byKey(const Key('settings-storage-open')), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-refresh')), findsOneWidget);
      expect(
          find.byKey(const Key('settings-storage-migration-path')), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-backup-path')), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-restore-path')), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-clean-run')), findsOneWidget);
    });

    testWidgets('权威来源参数不会被标成“由程序路径推断”', (tester) async {
      final dir = _dataDir('storage_source');
      final controller = _controller(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          storageSource: 'portable',
          backupService: _stub(dir),
        ),
      );

      // The source label itself is no longer printed, but the storage layer still
      // records it: a portable root must not produce a warning banner.
      expect(find.textContaining('由程序路径推断'), findsNothing);
      expect(find.textContaining('portable（程序目录下的 TaskSchedulerData）'),
          findsNothing);
      expect(find.textContaining('系统临时区'), findsNothing);
    });

    testWidgets('内存模式给出丢失警告，并禁用打开目录', (tester) async {
      final dir = _dataDir('storage_memory');
      final controller = _controller(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          storageSource: 'memory',
          memoryOnly: true,
          backupService: _stub(dir),
        ),
      );

      expect(find.textContaining('内存模式'), findsWidgets);
      expect(find.textContaining('关闭程序即丢失'), findsWidgets);
      final open = tester.widget<OutlinedButton>(
        find.byKey(const Key('settings-storage-open')),
      );
      expect(open.onPressed, isNull);
    });

    testWidgets('打开目录失败给出原因，恢复后不残留假成功', (tester) async {
      final dir = _dataDir('storage_open');
      final controller = _controller(dir);
      String? opened;
      String? failure = '拒绝访问，OS Error 5';
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          backupService: _stub(dir),
          openDirectory: (path) async {
            opened = path;
            return failure;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('settings-storage-open')));
      await tester.pumpAndSettle();
      expect(opened, dir.path);
      expect(find.textContaining('拒绝访问'), findsOneWidget);

      failure = null;
      await tester.tap(find.byKey(const Key('settings-storage-open')));
      await tester.pumpAndSettle();
      expect(find.textContaining('拒绝访问'), findsNothing);
      expect(find.textContaining('已打开'), findsNothing);
    });

    testWidgets('备份沿用默认文件名，并显示路径与大小', (tester) async {
      final dir = _dataDir('storage_backup');
      final controller = _controller(dir);
      final stub = _stub(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      final field = tester.widget<TextField>(
        find.byKey(const Key('settings-storage-backup-path')),
      );
      final path = field.controller!.text;
      expect(path, contains('TaskScheduler-backup-'));
      expect(path, endsWith('.json'));
      // 0.07: the long "备份是单个 JSON 文件… 不含 API Key" paragraph was removed. The
      // operation, its path field and its real result message stay.
      expect(find.textContaining('不含 API Key'), findsNothing);

      await tester.tap(find.byKey(const Key('settings-storage-backup-run')));
      await tester.pumpAndSettle();

      expect(stub.exportedTo, path);
      expect(find.textContaining('备份完成'), findsOneWidget);
      expect(find.textContaining('2 个会话'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsWidgets);
    });

    testWidgets('恢复校验失败显示原因，且不报告成功', (tester) async {
      final dir = _dataDir('storage_restore');
      final controller = _controller(dir);
      final stub = _stub(dir)
        ..restoreResult = const BackupRestoreResult(
          ok: false,
          error: '备份版本不受支持（schemaVersion=99，本程序支持 1），已拒绝导入',
        );
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      await tester.enterText(
        find.byKey(const Key('settings-storage-restore-path')),
        r'C:\tmp\bad-backup.json',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-storage-restore-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(stub.restoredFrom, r'C:\tmp\bad-backup.json');
      expect(find.textContaining('schemaVersion=99'), findsOneWidget);
      expect(find.textContaining('原有数据未被修改'), findsOneWidget);
      expect(find.textContaining('已恢复'), findsNothing);
    });

    testWidgets('分析进行中禁用恢复并说明原因', (tester) async {
      final dir = _dataDir('storage_restore_busy');
      final controller = _controller(dir);
      final stub = _stub(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          backupService: stub,
          isAnalysisRunning: () => true,
        ),
      );

      expect(find.textContaining('分析进行中'), findsOneWidget);
      final restore = tester.widget<OutlinedButton>(
        find.byKey(const Key('settings-storage-restore-run')),
      );
      expect(restore.onPressed, isNull,
          reason: '分析进行中不得允许恢复（会覆盖正在使用的会话文件）');
      expect(stub.restoredFrom, isNull);
    });

    testWidgets('恢复成功后只在真的刷新时提示“会话列表已刷新”', (tester) async {
      final dir = _dataDir('storage_restore_refreshed');
      final controller = _controller(dir);
      final stub = _stub(dir)
        ..restoreResult = const BackupRestoreResult(
          ok: true,
          conversationCount: 1,
          restoredConversationCount: 1,
          sessionsReloaded: true,
          requiresRestart: false,
        );
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      await tester.enterText(
        find.byKey(const Key('settings-storage-restore-path')),
        r'C:\tmp\good-backup.json',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-storage-restore-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('会话列表已刷新'), findsOneWidget);
      expect(find.textContaining('重启'), findsNothing);
    });

    testWidgets('没有刷新回调时如实提示需要重启', (tester) async {
      final dir = _dataDir('storage_restore_restart');
      final controller = _controller(dir);
      final stub = _stub(dir)
        ..restoreResult = const BackupRestoreResult(
          ok: true,
          conversationCount: 1,
          restoredConversationCount: 1,
          sessionsReloaded: false,
          requiresRestart: true,
        );
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      await tester.enterText(
        find.byKey(const Key('settings-storage-restore-path')),
        r'C:\tmp\good-backup.json',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-storage-restore-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('重启'), findsOneWidget);
      expect(find.textContaining('会话列表已刷新'), findsNothing);
    });

    testWidgets('恢复成功后通过 onDataRestored 刷新会话列表', (tester) async {
      final dir = _dataDir('storage_restore_callback');
      final controller = _controller(dir);
      // The service did not own the refresh hook (`sessionsReloaded: false`), so the page
      // has to perform the refresh itself; production passes the hook into the service
      // and the page then does not refresh twice.
      final stub = _stub(dir)
        ..restoreResult = const BackupRestoreResult(
          ok: true,
          conversationCount: 1,
          restoredConversationCount: 1,
          sessionsReloaded: false,
          requiresRestart: true,
        );
      var refreshed = 0;
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          backupService: stub,
          onDataRestored: () async {
            refreshed++;
          },
        ),
      );

      await tester.enterText(
        find.byKey(const Key('settings-storage-restore-path')),
        r'C:\tmp\good-backup.json',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-storage-restore-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(refreshed, 1, reason: '恢复成功后必须调用主界面刷新回调');
      expect(find.textContaining('会话列表已刷新'), findsOneWidget);
      expect(find.textContaining('重启'), findsNothing,
          reason: '页面自己刷新成功后不得再提示重启');
    });

    testWidgets('刷新会话列表失败时如实报告，并提示重启', (tester) async {
      final dir = _dataDir('storage_restore_refresh_failed');
      final controller = _controller(dir);
      final stub = _stub(dir)
        ..restoreResult = const BackupRestoreResult(
          ok: true,
          conversationCount: 1,
          restoredConversationCount: 1,
          requiresRestart: true,
        );
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          backupService: stub,
          onDataRestored: () async => throw StateError('控制器已释放'),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('settings-storage-restore-path')),
        r'C:\tmp\good-backup.json',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings-storage-restore-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('刷新会话列表失败'), findsOneWidget);
      expect(find.textContaining('重启'), findsOneWidget);
      expect(find.textContaining('会话列表已刷新'), findsNothing);
    });

    testWidgets('清理前先显示应用缓存的真实数量与字节，确认后才删除', (tester) async {
      final dir = _dataDir('storage_clean');
      final controller = _controller(dir);
      final stub = _stub(dir);
      await _pumpPage(
        tester,
        SettingsStoragePage(
          controller: controller,
          backupService: stub,
        ),
      );

      await tester.tap(find.byKey(const Key('settings-storage-clean-run')));
      await tester.pumpAndSettle();
      expect(stub.scanCalls, 1, reason: '预览必须走 BackupService.scanCache');
      expect(find.textContaining('2 个应用缓存文件'), findsOneWidget);
      expect(find.textContaining('128 B'), findsOneWidget);
      expect(find.textContaining('tsc-a.tmp'), findsOneWidget);
      expect(stub.clearCalls, 0, reason: '确认之前不得删除任何文件');

      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();
      expect(stub.clearCalls, 1);
      expect(find.textContaining('已清理 2 个缓存文件'), findsOneWidget);
    });

    testWidgets('没有缓存文件时不调用删除', (tester) async {
      final dir = _dataDir('storage_clean_empty');
      final controller = _controller(dir);
      final stub = _stub(dir)..cachePreview = const CachePreview();
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      await tester.tap(find.byKey(const Key('settings-storage-clean-run')));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有发现可清理的应用缓存文件'), findsOneWidget);
      expect(find.byKey(const Key('settings-storage-confirm')), findsNothing);
      expect(stub.clearCalls, 0);
    });

    testWidgets('缓存被占用时如实说明未清理，不谎报成功', (tester) async {
      final dir = _dataDir('storage_clean_skipped');
      final controller = _controller(dir);
      final stub = _stub(dir)
        ..clearResult = const CacheClearResult(
          deletedFiles: 0,
          bytes: 0,
          skippedReason: '缓存目录正被另一个程序实例使用（锁不可用：占用）',
        );
      await _pumpPage(
        tester,
        SettingsStoragePage(controller: controller, backupService: stub),
      );

      await tester.tap(find.byKey(const Key('settings-storage-clean-run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-storage-confirm')));
      await tester.pumpAndSettle();

      expect(stub.clearCalls, 1);
      expect(find.textContaining('未清理任何文件'), findsOneWidget);
      expect(find.textContaining('另一个程序实例'), findsOneWidget);
      expect(find.textContaining('已清理'), findsNothing);
    });
  });

  group('来源推断', () {
    test('按 storage_root 的候选顺序识别 env/portable/…', () {
      const env = <String, String>{
        'TASKSCHEDULER_DATA_DIR': r'D:\data',
        'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
        'APPDATA': r'C:\Users\me\AppData\Roaming',
        'TEMP': r'C:\Temp',
      };
      const exe = r'C:\Program\TaskScheduler';

      expect(
        inferStorageSource(r'D:\data', environment: env, exeDirectory: exe)
            .source,
        'env',
      );
      expect(
        inferStorageSource(
          r'C:\Program\TaskScheduler\TaskSchedulerData',
          environment: env,
          exeDirectory: exe,
        ).source,
        'portable',
      );
      expect(
        inferStorageSource(
          r'C:\Users\me\AppData\Local\TaskSchedulerFlutter',
          environment: env,
          exeDirectory: exe,
        ).source,
        'localAppData',
      );
      expect(
        inferStorageSource(
          r'C:\Users\me\AppData\Roaming\TaskSchedulerFlutter',
          environment: env,
          exeDirectory: exe,
        ).source,
        'appData',
      );
      expect(
        inferStorageSource(
          r'C:\Temp\TaskSchedulerFlutter',
          environment: env,
          exeDirectory: exe,
        ).source,
        'temp',
      );
      expect(
        inferStorageSource(r'E:\somewhere', environment: env, exeDirectory: exe)
            .source,
        'unknown',
      );
    });
  });

  group('备份 / 恢复 / 清理（真实临时目录）', () {
    test('备份是单个 JSON，含会话但不含任何密钥', () async {
      final dir = _dataDir('backup_real');
      final store = SessionStore(dir);
      await seedConversation(store, conversationId: 'conv-a');
      final settings = SettingsController(
        store: SettingsStore(dir),
        bridge: FakeSettingsBridge(),
      );
      await settings.load();
      addTearDown(settings.dispose);

      final service = BackupService(store: store, root: dir, settings: settings);
      final target = _p([
        dir.parent.path,
        'backup-${DateTime.now().microsecondsSinceEpoch}.json',
      ]);
      addTearDown(() {
        try {
          final file = File(target);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // ignore
        }
      });

      final result = await service.exportBackup(target);
      final text = await File(target).readAsString();
      expect(utf8.encode(text).length, result.byteLength);
      expect(result.conversationCount, 1);
      expect(result.profileCount, settings.profiles.length);

      final doc = jsonDecode(text) as Map<String, dynamic>;
      expect(doc['kind'], BackupService.backupKind);
      expect(doc['schemaVersion'], BackupService.schemaVersion);
      expect((doc['conversations'] as List<dynamic>).length, 1);

      final settingsDoc = doc['settings'] as Map<String, dynamic>;
      expect(settingsDoc['note'], contains('不含密钥'));
      final profiles = (settingsDoc['profiles'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(profiles, isNotEmpty);
      for (final profile in profiles) {
        expect(profile.containsKey('apiKey'), isFalse);
        expect(profile.containsKey('key'), isFalse);
        expect(profile.containsKey('authorization'), isFalse);
        expect(profile.containsKey('password'), isFalse);
      }
      // 没有任何形如密钥的字符串（本测试从未写入真实密钥）。
      // 说明：任务 ID 形如 task-a，也会匹配 "sk-"，所以这里要求典型密钥长度。
      expect(RegExp(r'sk-[A-Za-z0-9]{16,}').hasMatch(text), isFalse);
    });

    test('恢复校验失败时不动原数据、不留 .bak；备份内 ID 冲突同样被拒绝', () async {
      final dir = _dataDir('restore_real');
      final store = SessionStore(dir);
      await seedConversation(store, conversationId: 'conv-keep');
      final convFile = File(
        _p([dir.path, 'conversations', 'conv-keep.json']),
      );
      expect(convFile.existsSync(), isTrue);
      final before = await convFile.readAsString();
      final service = BackupService(store: store, root: dir);

      final bad = File(_p([
        dir.parent.path,
        'bad-${DateTime.now().microsecondsSinceEpoch}.json',
      ]));
      await bad.writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': 99,
        'kind': BackupService.backupKind,
        'conversations': <dynamic>[],
      }));
      addTearDown(() {
        try {
          if (bad.existsSync()) bad.deleteSync();
        } catch (_) {
          // ignore
        }
      });

      final result = await service.restoreBackup(bad.path);
      expect(result.ok, isFalse);
      expect(result.error, contains('schemaVersion=99'));
      expect(await convFile.readAsString(), before);
      expect(File('${convFile.path}.bak').existsSync(), isFalse);

      // 同一个会话在备份里出现两次 → 结构校验失败，仍然不写入。
      final conversation = jsonDecode(before) as Map<String, dynamic>;
      final dup = File(_p([
        dir.parent.path,
        'dup-${DateTime.now().microsecondsSinceEpoch}.json',
      ]));
      await dup.writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': BackupService.schemaVersion,
        'kind': BackupService.backupKind,
        'conversations': <dynamic>[conversation, conversation],
      }));
      addTearDown(() {
        try {
          if (dup.existsSync()) dup.deleteSync();
        } catch (_) {
          // ignore
        }
      });

      final dupResult = await service.restoreBackup(dup.path);
      expect(dupResult.ok, isFalse);
      expect(dupResult.error, contains('重复的会话 ID'));
      expect(await convFile.readAsString(), before);
      expect(File('${convFile.path}.bak').existsSync(), isFalse);
    });

    test('缓存清理只删程序自有的 cache 文件，用户目录中的 .tmp 原样保留', () async {
      final dir = _dataDir('cache_real');
      final conversations = Directory(_p([dir.path, 'conversations']))
        ..createSync(recursive: true);
      final attachments = Directory(_p([dir.path, 'attachments']))
        ..createSync(recursive: true);
      final settingsDir = Directory(_p([dir.path, 'settings']))
        ..createSync(recursive: true);
      final cacheDir =
          Directory(_p([dir.path, BackupService.cacheDirectoryName]))
            ..createSync(recursive: true);

      final history = File(_p([conversations.path, 'history.json']))
        ..writeAsStringSync('{"id":"conv-1"}');
      final historyTmp = File('${history.path}.tmp')..writeAsStringSync('a');
      final attachment = File(_p([attachments.path, 'a.json']))
        ..writeAsStringSync('aa');
      final attachmentTmp =
          File('${attachment.path}.restore.tmp')..writeAsStringSync('bb');
      final prefs = File(_p([settingsDir.path, 'app_prefs.json']))
        ..writeAsStringSync('ppp');
      final prefsTmp = File('${prefs.path}.tmp')..writeAsStringSync('ccc');
      final rootTmp = File(_p([dir.path, 'write.tmp']))..writeAsStringSync('dddd');
      final userFile = File(_p([dir.path, 'notes.txt']))
        ..writeAsStringSync('keep me');
      final cacheOwned = File(_p([cacheDir.path, 'tsc-leftover.tmp']))
        ..writeAsStringSync('12345');
      final cacheForeign = File(_p([cacheDir.path, 'user-notes.txt']))
        ..writeAsStringSync('keep me too');

      final service = BackupService(store: SessionStore(dir), root: dir);
      final preview = await service.scanCache();
      final result = await service.clearCache();

      expect(preview.names, <String>['tsc-leftover.tmp']);
      expect(result.deletedFiles, preview.fileCount);
      expect(result.bytes, preview.bytes);
      expect(cacheOwned.existsSync(), isFalse);
      expect(cacheForeign.existsSync(), isTrue,
          reason: 'cache 目录中不是程序命名的文件同样不能删');
      // The `.tmp` files in the user folders are NOT cache: they stay.
      expect(history.existsSync(), isTrue);
      expect(attachment.existsSync(), isTrue);
      expect(prefs.existsSync(), isTrue);
      expect(userFile.existsSync(), isTrue);
      expect(historyTmp.existsSync(), isTrue);
      expect(attachmentTmp.existsSync(), isTrue);
      expect(prefsTmp.existsSync(), isTrue);
      expect(rootTmp.existsSync(), isTrue);
    });

    test('目录统计返回文件数与字节数', () async {
      final dir = _dataDir('usage_real');
      Directory(_p([dir.path, 'conversations'])).createSync(recursive: true);
      File(_p([dir.path, 'a.txt'])).writeAsStringSync('12345');
      File(_p([dir.path, 'conversations', 'b.json'])).writeAsStringSync('123');

      final usage = await BackupService(store: SessionStore(dir), root: dir)
          .directorySize();
      expect(usage.files, 2);
      expect(usage.bytes, 8);
      expect(usage.formatted, isNotEmpty);
    });
  });
}

