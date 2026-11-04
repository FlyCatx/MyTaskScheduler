// 外部日历存储测试：原子写、.bak 回退、损坏不冒充成功、只删自己的快照。
//
// 与 session_store_test.dart 同风格：用 test_tmp 下的临时目录，不碰真实用户数据。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_store.dart';

import 'support/test_support.dart';

ExternalCalendarSource makeSource(
  String id, {
  String name = '来源',
  String hash = 'hash-1',
  int revision = 1,
  bool enabled = true,
}) =>
    ExternalCalendarSource(
      id: id,
      name: name,
      filePath: '${Directory.systemTemp.path}${Platform.pathSeparator}$id.ics',
      contentHash: hash,
      importedAt: '2026-03-01T00:00:00.000Z',
      revision: revision,
      dateFrom: '2026-03-01',
      dateTo: '2026-03-31',
      timezoneId: 'Asia/Shanghai',
      enabled: enabled,
      policy: const ExternalCalendarPolicy(floatingTimezoneId: 'Asia/Shanghai'),
      stats: const ExtImportStats(readEvents: 2, expandedInstances: 3),
    );

ExternalSourceSnapshot makeSnapshot(
  String sourceId, {
  int revision = 1,
  String hash = 'hash-1',
  int eventCount = 1,
}) =>
    ExternalSourceSnapshot(
      sourceId: sourceId,
      revision: revision,
      contentHash: hash,
      timezoneId: 'Asia/Shanghai',
      dateFrom: '2026-03-01',
      dateTo: '2026-03-31',
      events: <ExternalEventRecord>[
        for (var i = 0; i < eventCount; i++)
          ExternalEventRecord(
            uid: 'u$i@test',
            startUtc: '2026-03-0${i + 2}T01:00:00.000Z',
            endUtc: '2026-03-0${i + 2}T02:00:00.000Z',
            timezoneId: 'Asia/Shanghai',
            summary: '事件 $i',
          ),
      ],
      warnings: const <ExtImportWarning>[
        ExtImportWarning('no-events', '示例警告', uid: 'u0@test'),
      ],
      stats: ExtImportStats(
        readEvents: eventCount,
        expandedInstances: eventCount,
        busyMinutes: eventCount * 60,
        warningCount: 1,
      ),
    );

void main() {
  late Directory root;
  late ExternalCalendarStore store;

  setUp(() {
    root = createTempDataDir('external_calendar_store');
    store = ExternalCalendarStore(root);
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('布局与来源列表', () {
    test('ensureLayout 创建 external_calendar/ 与 snapshots/', () async {
      await store.ensureLayout();
      expect(store.baseDir.path.endsWith('external_calendar'), isTrue);
      expect(store.baseDir.existsSync(), isTrue);
      expect(store.snapshotsDir.existsSync(), isTrue);
      expect(store.sourcesFile.path.endsWith('sources.json'), isTrue);
    });

    test('没有文件时 loadSources 返回空列表', () async {
      expect(await store.loadSources(), isEmpty);
    });

    test('来源列表往返保留策略与统计，按 id 排序', () async {
      await store.saveSources(<ExternalCalendarSource>[
        makeSource('ext-bbbbbbbbbbbb', name: '周末', hash: 'h-b', revision: 3),
        makeSource('ext-aaaaaaaaaaaa', name: '工作', hash: 'h-a'),
      ]);
      final loaded = await store.loadSources();
      expect(loaded.map((s) => s.id).toList(),
          <String>['ext-aaaaaaaaaaaa', 'ext-bbbbbbbbbbbb']);
      final first = loaded.first;
      expect(first.name, '工作');
      expect(first.revision, 1);
      expect(first.dateFrom, '2026-03-01');
      expect(first.policy.floatingTimezoneId, 'Asia/Shanghai');
      expect(first.stats.readEvents, 2);
      expect(first.enabled, isTrue);
    });

    test('原子写：第二次写入后 .bak 保留上一份，主文件是新的', () async {
      await store.saveSources(<ExternalCalendarSource>[
        makeSource('ext-aaaaaaaaaaaa'),
      ]);
      await store.saveSources(<ExternalCalendarSource>[
        makeSource('ext-aaaaaaaaaaaa'),
        makeSource('ext-bbbbbbbbbbbb'),
      ]);
      final bak = File('${store.sourcesFile.path}.bak');
      expect(bak.existsSync(), isTrue);
      expect(await store.loadSources(), hasLength(2));
      final bakJson = jsonDecode(bak.readAsStringSync()) as Map<String, dynamic>;
      expect((bakJson['sources'] as List<dynamic>), hasLength(1),
          reason: '.bak 必须是上一份完整数据');
    });

    test('主文件损坏时回退 .bak', () async {
      await store.saveSources(<ExternalCalendarSource>[
        makeSource('ext-aaaaaaaaaaaa'),
      ]);
      await store.saveSources(<ExternalCalendarSource>[
        makeSource('ext-aaaaaaaaaaaa'),
        makeSource('ext-bbbbbbbbbbbb'),
      ]);
      // 模拟写坏主文件（半份 JSON）。
      await store.sourcesFile.writeAsString('{"schemaVersion":1,"sources":[{"id"');
      final loaded = await store.loadSources();
      expect(loaded, hasLength(1), reason: '必须回退到 .bak 的上一次完整数据');
      expect(loaded.single.id, 'ext-aaaaaaaaaaaa');
    });

    test('主文件与 .bak 都损坏时抛错，绝不冒充“空来源列表”', () async {
      await store.ensureLayout();
      await store.sourcesFile.writeAsString('不是 JSON');
      await expectLater(
        store.loadSources(),
        throwsA(isA<ExternalCalendarStoreException>()),
      );
      expect(store.lastError, isNotNull);
    });

    test('来源列表含非法记录/重复 id/更高 schema 都抛错', () async {
      await store.ensureLayout();
      await store.sourcesFile.writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'sources': <dynamic>[
          <String, dynamic>{'name': '没有 id'},
        ],
      }));
      await expectLater(store.loadSources(),
          throwsA(isA<ExternalCalendarStoreException>()));

      await store.sourcesFile.writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'sources': <dynamic>[
          makeSource('ext-aaaaaaaaaaaa').toJson(),
          makeSource('ext-aaaaaaaaaaaa').toJson(),
        ],
      }));
      await expectLater(store.loadSources(),
          throwsA(isA<ExternalCalendarStoreException>()));

      await store.sourcesFile.writeAsString(jsonEncode(<String, dynamic>{
        'schemaVersion': 99,
        'sources': <dynamic>[],
      }));
      await expectLater(store.loadSources(),
          throwsA(isA<ExternalCalendarStoreException>()));
    });
  });

  group('快照', () {
    test('快照往返保留事件/警告/统计', () async {
      final snapshot = makeSnapshot('ext-aaaaaaaaaaaa', eventCount: 2);
      await store.saveSnapshot(snapshot);
      final loaded = await store.loadSnapshot('ext-aaaaaaaaaaaa');
      expect(loaded, isNotNull);
      expect(loaded!.events, hasLength(2));
      expect(loaded.events.first.uid, 'u0@test');
      expect(loaded.events.first.timezoneId, 'Asia/Shanghai');
      expect(loaded.warnings.single.code, 'no-events');
      expect(loaded.stats.busyMinutes, 120);
      expect(loaded.revision, 1);
    });

    test('快照损坏时回退 .bak；两份都坏返回 null', () async {
      await store.saveSnapshot(makeSnapshot('ext-aaaaaaaaaaaa', eventCount: 1));
      await store.saveSnapshot(
          makeSnapshot('ext-aaaaaaaaaaaa', revision: 2, hash: 'hash-2', eventCount: 2));
      final file = store.snapshotFile('ext-aaaaaaaaaaaa');
      expect(file.existsSync(), isTrue);
      await file.writeAsString('中断的半份 JSON');
      final fallback = await store.loadSnapshot('ext-aaaaaaaaaaaa');
      expect(fallback, isNotNull);
      expect(fallback!.revision, 1, reason: '.bak 是上一次完整快照');
      expect(fallback.events, hasLength(1));

      await File('${file.path}.bak').writeAsString('也坏了');
      expect(await store.loadSnapshot('ext-aaaaaaaaaaaa'), isNull);
      expect(store.lastError, contains('损坏'));
    });

    test('快照文件与来源 id 不一致时忽略', () async {
      final snapshot = makeSnapshot('ext-bbbbbbbbbbbb');
      await store.ensureLayout();
      final file = store.snapshotFile('ext-aaaaaaaaaaaa');
      await file.writeAsString(jsonEncode(snapshot.toJson()));
      expect(await store.loadSnapshot('ext-aaaaaaaaaaaa'), isNull);
      expect(store.lastError, contains('不一致'));
    });

    test('deleteSnapshot 只删除自己的文件（含 .bak 与临时文件）', () async {
      await store.saveSnapshot(makeSnapshot('ext-aaaaaaaaaaaa'));
      await store.saveSnapshot(makeSnapshot('ext-bbbbbbbbbbbb'));
      // 残留临时文件（模拟崩溃）。
      final leftover = File(
          '${store.snapshotFile('ext-aaaaaaaaaaaa').path}.123-0.tmp');
      await leftover.writeAsString('tmp');
      await store.deleteSnapshot('ext-aaaaaaaaaaaa');

      expect(store.snapshotFile('ext-aaaaaaaaaaaa').existsSync(), isFalse);
      expect(File('${store.snapshotFile('ext-aaaaaaaaaaaa').path}.bak').existsSync(),
          isFalse);
      expect(leftover.existsSync(), isFalse);
      expect(store.snapshotFile('ext-bbbbbbbbbbbb').existsSync(), isTrue,
          reason: '不能碰其他来源的快照');
      expect(await store.loadSnapshot('ext-bbbbbbbbbbbb'), isNotNull);
    });

    test('referencedSnapshotIds 与 loadAllSnapshots', () async {
      await store.saveSnapshot(makeSnapshot('ext-aaaaaaaaaaaa'));
      await store.saveSnapshot(makeSnapshot('ext-bbbbbbbbbbbb'));
      expect(await store.referencedSnapshotIds(),
          <String>{'ext-aaaaaaaaaaaa', 'ext-bbbbbbbbbbbb'});
      final all = await store.loadAllSnapshots();
      expect(all.map((s) => s.sourceId).toList(),
          <String>['ext-aaaaaaaaaaaa', 'ext-bbbbbbbbbbbb']);
    });

    test('非法来源 id 不允许写入，也读不到', () async {
      await store.ensureLayout();
      expect(
        () => store.saveSnapshot(makeSnapshot('../evil')),
        throwsA(isA<ExternalCalendarStoreException>()),
      );
      expect(await store.loadSnapshot('../evil'), isNull);
      expect(ExternalCalendarStore.isSafeId('ext-0123456789ab'), isTrue);
      expect(ExternalCalendarStore.isSafeId('../etc'), isFalse);
    });
  });
}
