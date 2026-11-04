// 外部日历服务测试：来源管理、导入预览/幂等/原子提交、忙碌实例、指纹。
//
// 覆盖契约 3.7 与 U01：
//   * 同内容重复导入幂等（diff 全 0、revision 不变、不产生写入）；
//   * 不同来源同 UID 互不影响；
//   * commit 原子（失败保留旧 sources/snapshot 并返回 false + lastError）；
//   * remove 只删自己的数据；
//   * fingerprint 是启用来源 id+revision+contentHash 的稳定哈希；
//   * 只读语义（本层不写原 ICS 文件）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_store.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_expander.dart';

import 'support/test_support.dart';

const String kTz = 'Asia/Shanghai';
const String kFrom = '2026-03-01';
const String kTo = '2026-03-31';

String fixturePath(String name) =>
    File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}ics'
            '${Platform.pathSeparator}$name')
        .path;

String fixtureText(String name) => File(fixturePath(name)).readAsStringSync();

void main() {
  late Directory root;
  late ExternalCalendarStore store;
  late ExternalCalendarService service;

  setUp(() async {
    root = createTempDataDir('external_calendar_service');
    store = ExternalCalendarStore(root);
    service = ExternalCalendarService(store: store, limits: const IcsLimits());
    await service.load();
  });

  tearDown(() {
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<ExternalImportPreview> previewOf(
    String filePath, {
    ExternalCalendarSource? existing,
    bool replaceMode = false,
    String from = kFrom,
    String to = kTo,
    ExternalCalendarPolicy policy = const ExternalCalendarPolicy(),
  }) async {
    final preview = await service.preview(
      filePath: filePath,
      existing: existing,
      timezoneId: kTz,
      policy: policy,
      dateFrom: from,
      dateTo: to,
      replaceMode: replaceMode,
    );
    expect(preview, isNotNull, reason: '预览失败：${service.lastError}');
    return preview!;
  }

  Future<ExternalCalendarSource> importFile(
    String name, {
    ExternalCalendarSource? existing,
    bool replaceMode = false,
    String from = kFrom,
    String to = kTo,
  }) async {
    final preview = await previewOf(
      fixturePath(name),
      existing: existing,
      replaceMode: replaceMode,
      from: from,
      to: to,
    );
    expect(await service.commit(preview), isTrue,
        reason: '提交失败：${service.lastError}');
    return service.sourceById(preview.candidate.id)!;
  }

  group('加载', () {
    test('空目录加载为空且无错误', () async {
      expect(service.sources, isEmpty);
      expect(service.lastError, isNull);
      expect(service.fingerprint, isNotEmpty);
    });

    test('来源列表损坏时不覆盖数据，并进入拒绝写入状态', () async {
      await store.ensureLayout();
      await store.sourcesFile.writeAsString('{损坏的 JSON');
      final broken = ExternalCalendarService(
          store: store, limits: const IcsLimits());
      await broken.load();
      expect(broken.lastError, isNotNull);
      expect(broken.sources, isEmpty);
      final preview = await broken.preview(
        filePath: fixturePath('basic_cn.ics'),
        timezoneId: kTz,
        policy: const ExternalCalendarPolicy(),
        dateFrom: kFrom,
        dateTo: kTo,
        replaceMode: false,
      );
      expect(preview, isNull);
      expect(broken.lastError, contains('损坏'));
    });
  });

  group('新建导入', () {
    test('预览给出候选来源/统计/差异，提交后落盘并可重新加载', () async {
      final preview = await previewOf(fixturePath('basic_cn.ics'));

      expect(preview.existingSource, isNull);
      expect(preview.candidate.id, matches(RegExp(r'^ext-[0-9a-f]{12}$')));
      expect(preview.candidate.name, 'basic_cn',
          reason: '新建来源默认名取文件名（不含扩展名）');
      expect(preview.candidate.revision, 1);
      expect(preview.candidate.enabled, isTrue);
      expect(preview.candidate.dateFrom, kFrom);
      expect(preview.candidate.dateTo, kTo);
      expect(preview.candidate.contentHash, hasLength(64));
      expect(preview.diff.added, 2);
      expect(preview.diff.updated, 0);
      expect(preview.diff.removed, 0);
      expect(preview.diff.summaryLine, contains('新增 2'));
      expect(preview.snapshot.events, hasLength(2));
      expect(preview.snapshot.stats.readEvents, 2);
      expect(preview.snapshot.stats.expandedInstances, 2);
      expect(preview.snapshot.stats.busyMinutes, 150); // 90 + 60
      expect(preview.truncated, isFalse);
      expect(preview.isEmpty, isFalse);
      expect(preview.hasChanges, isTrue);

      expect(await service.commit(preview), isTrue);
      expect(service.sources, hasLength(1));
      expect(service.snapshotOf(preview.candidate.id), isNotNull);
      expect(store.sourcesFile.existsSync(), isTrue);
      expect(store.snapshotFile(preview.candidate.id).existsSync(), isTrue);

      // 用同一个 store 新建服务：来源与快照都能恢复。
      final reloaded =
          ExternalCalendarService(store: store, limits: const IcsLimits());
      await reloaded.load();
      expect(reloaded.sources, hasLength(1));
      expect(reloaded.sources.single.id, preview.candidate.id);
      expect(reloaded.snapshotOf(preview.candidate.id)!.events, hasLength(2));
      expect(reloaded.fingerprint, service.fingerprint);
    });

    test('同内容重复导入幂等：diff 全 0、revision 不变、不写盘', () async {
      final source = await importFile('basic_cn.ics');
      final sourcesBytes = store.sourcesFile.readAsBytesSync();
      final snapshotBytes =
          store.snapshotFile(source.id).readAsBytesSync();

      final preview = await previewOf(
        fixturePath('basic_cn.ics'),
        existing: service.sourceById(source.id),
      );
      expect(preview.hasChanges, isFalse);
      expect(preview.diff.added, 0);
      expect(preview.diff.updated, 0);
      expect(preview.diff.removed, 0);
      expect(preview.diff.unchanged, 2);
      expect(preview.candidate.revision, source.revision);

      expect(await service.commit(preview), isTrue);
      expect(service.sourceById(source.id)!.revision, 1);
      expect(store.sourcesFile.readAsBytesSync(), sourcesBytes,
          reason: '幂等导入不应产生任何写入');
      expect(store.snapshotFile(source.id).readAsBytesSync(), snapshotBytes,
          reason: '幂等导入不应重写快照');
    });

    test('内容不变但策略变化：diff 仍为 0，revision 必须 +1', () async {
      final source = await importFile('basic_cn.ics');
      final preview = await previewOf(
        fixturePath('basic_cn.ics'),
        existing: service.sourceById(source.id),
        policy: const ExternalCalendarPolicy(
            busyPolicy: ExternalBusyPolicy.allCountsAsBusy),
      );
      expect(preview.diff.hasChanges, isFalse);
      expect(preview.metadataChanged, isTrue);
      expect(preview.hasChanges, isTrue);
      expect(preview.candidate.revision, 2);
      expect(await service.commit(preview), isTrue);
      final updated = service.sourceById(source.id)!;
      expect(updated.revision, 2);
      expect(updated.policy.busyPolicy, ExternalBusyPolicy.allCountsAsBusy);
      // 策略变化后透明事件也会被计为占用（这里没有透明事件，只验证持久化）。
      expect(service.snapshotOf(source.id)!.policy.busyPolicy,
          ExternalBusyPolicy.allCountsAsBusy);
    });

    test('内容变化：diff 显示修改、提交后 revision +1 且忙碌时间更新', () async {
      final imported = await importFile('idempotent_a.ics');
      expect(service.busyFor(
        sourceIds: <String>{imported.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      ), hasLength(1));

      final preview = await previewOf(
        fixturePath('idempotent_b.ics'),
        existing: service.sourceById(imported.id),
      );
      // 同一来源里的同一 UID = 同一条事件被更新（RFC 语义），不是新增+删除。
      expect(preview.diff.updated, 1);
      expect(preview.diff.added, 0);
      expect(preview.diff.removed, 0);
      expect(preview.candidate.revision, 2);
      expect(await service.commit(preview), isTrue);

      final updated = service.sourceById(imported.id)!;
      expect(updated.revision, 2);
      final busy = service.busyFor(
        sourceIds: <String>{imported.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      );
      expect(busy, hasLength(1));
      // 来源 B 的同 UID 事件在上海 15:00 = 07:00Z。
      expect(busy.single.startUtc.toIso8601String(),
          '2026-03-02T07:00:00.000Z');
    });
  });

  group('U01 同 UID 不同来源隔离', () {
    test('两个来源的同一 UID 各自独立，busyFor 按来源集合取数', () async {
      final a = await importFile('idempotent_a.ics');
      final b = await importFile('idempotent_b.ics');
      expect(a.id, isNot(b.id));
      expect(service.sources, hasLength(2));
      expect(service.snapshotOf(a.id)!.events.single.uid, 'shared-1@example.test');
      expect(service.snapshotOf(b.id)!.events.single.uid, 'shared-1@example.test');

      final onlyA = service.busyFor(
        sourceIds: <String>{a.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      );
      expect(onlyA, hasLength(1));
      expect(onlyA.single.sourceId, a.id);
      expect(onlyA.single.startUtc.toIso8601String(),
          '2026-03-02T01:00:00.000Z');

      final onlyB = service.busyFor(
        sourceIds: <String>{b.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      );
      expect(onlyB.single.startUtc.toIso8601String(),
          '2026-03-02T07:00:00.000Z');

      final both = service.busyFor(
        sourceIds: <String>{a.id, b.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      );
      expect(both, hasLength(2));
      expect(both.map((i) => i.sourceId).toSet(), <String>{a.id, b.id});
    });

    test('一个来源的结构不合法不影响另一个来源', () async {
      final a = await importFile('idempotent_a.ics');
      final b = await importFile('idempotent_b.ics');
      // 手工写坏 B 的快照；A 仍然可用（B 只需要重新导入）。
      await store.snapshotFile(b.id).writeAsString('半份 JSON');
      final reloaded =
          ExternalCalendarService(store: store, limits: const IcsLimits());
      await reloaded.load();
      expect(reloaded.sourceById(a.id), isNotNull);
      expect(reloaded.snapshotOf(b.id), isNull);
      expect(reloaded.busyFor(
        sourceIds: <String>{a.id, b.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      ), hasLength(1));
    });
  });

  group('来源管理', () {
    test('setEnabled/rename 持久化，禁用来源不参与 fingerprint 与忙碌', () async {
      final source = await importFile('basic_cn.ics');
      final enabledFingerprint = service.fingerprint;
      expect(enabledFingerprint, service.fingerprintOf(<String>[source.id]));

      expect(await service.setEnabled(source.id, false), isTrue);
      expect(service.sourceById(source.id)!.enabled, isFalse);
      expect(service.fingerprint, service.fingerprintOf(const <String>[]),
          reason: '禁用的来源不参与全量指纹');
      expect(
        service.busyFor(
          sourceIds: <String>{source.id},
          dateFrom: kFrom,
          dateTo: kTo,
          timezoneId: kTz,
        ),
        isEmpty,
      );

      expect(await service.rename(source.id, '  工作日程  '), isTrue);
      expect(service.sourceById(source.id)!.name, '工作日程');
      expect(await service.rename(source.id, '   '), isFalse);

      final reloaded =
          ExternalCalendarService(store: store, limits: const IcsLimits());
      await reloaded.load();
      expect(reloaded.sourceById(source.id)!.name, '工作日程');
      expect(reloaded.sourceById(source.id)!.enabled, isFalse);
    });

    test('remove 只删自己的数据，其他来源不受影响', () async {
      final a = await importFile('idempotent_a.ics');
      final b = await importFile('idempotent_b.ics');
      expect(await service.remove(a.id), isTrue);
      expect(service.sources.map((s) => s.id), <String>[b.id]);
      expect(store.snapshotFile(a.id).existsSync(), isFalse);
      expect(store.snapshotFile(b.id).existsSync(), isTrue);
      expect(service.snapshotOf(b.id), isNotNull);
      expect(
        service.busyFor(
          sourceIds: <String>{a.id},
          dateFrom: kFrom,
          dateTo: kTo,
          timezoneId: kTz,
        ),
        isEmpty,
      );
      expect(await service.remove(a.id), isFalse, reason: '重复删除返回 false');
      expect(service.lastError, isNotNull);
    });

    test('fingerprint 随 revision 变化，且对来源顺序不敏感', () async {
      final a = await importFile('idempotent_a.ics');
      final b = await importFile('idempotent_b.ics');
      final f1 = service.fingerprint;
      expect(service.fingerprintOf(<String>[b.id, a.id]), f1);
      final preview = await previewOf(
        fixturePath('idempotent_b.ics'),
        existing: service.sourceById(a.id),
      );
      expect(preview.diff.hasChanges, isTrue);
      expect(await service.commit(preview), isTrue);
      expect(service.fingerprint, isNot(f1));
    });
  });

  group('原子性', () {
    test('sources.json 写入失败时回滚快照、返回 false、旧数据可用', () async {
      final source = await importFile('idempotent_a.ics');
      expect(await store.loadSnapshot(source.id), isNotNull);

      final preview = await previewOf(
        fixturePath('idempotent_b.ics'),
        existing: service.sourceById(source.id),
      );

      // 用“同名目录”占住 sources.json，让 rename 必定失败。
      await store.sourcesFile.delete();
      await Directory(store.sourcesFile.path).create(recursive: true);
      try {
        expect(await service.commit(preview), isFalse);
        expect(service.lastError, isNotNull);
        // 内存里的来源没有被改动。
        expect(service.sourceById(source.id)!.revision, 1);
        // 磁盘上的旧快照被回滚（而不是留着半份新快照）。
        final onDisk = await store.loadSnapshot(source.id);
        expect(onDisk, isNotNull);
        expect(onDisk!.revision, 1);
        expect(onDisk.contentHash, source.contentHash);
        expect(onDisk.events.single.uid, 'shared-1@example.test');
      } finally {
        await Directory(store.sourcesFile.path).delete(recursive: true);
      }
    });

    test('过期预览不能覆盖已被别人改过的来源', () async {
      final source = await importFile('idempotent_a.ics');
      final stale = await previewOf(
        fixturePath('idempotent_b.ics'),
        existing: service.sourceById(source.id),
      );
      // 模拟另一个实例先提交了一次更新（revision 变成 2）。
      final fresh = await previewOf(
        fixturePath('basic_cn.ics'),
        existing: service.sourceById(source.id),
      );
      expect(await service.commit(fresh), isTrue);
      expect(service.sourceById(source.id)!.revision, 2);

      expect(await service.commit(stale), isFalse);
      expect(service.lastError, contains('revision'));
      expect(service.sourceById(source.id)!.revision, 2);
    });
  });

  group('预览失败与空文件', () {
    test('文件不存在 / 过大 / 内容不是 ICS 都返回 null + lastError', () async {
      expect(
        await service.preview(
          filePath: '${root.path}${Platform.pathSeparator}missing.ics',
          timezoneId: kTz,
          policy: const ExternalCalendarPolicy(),
          dateFrom: kFrom,
          dateTo: kTo,
          replaceMode: false,
        ),
        isNull,
      );
      expect(service.lastError, contains('找不到文件'));

      final tiny = ExternalCalendarService(
          store: store, limits: const IcsLimits(maxFileBytes: 16));
      await tiny.load();
      expect(
        await tiny.preview(
          filePath: fixturePath('basic_cn.ics'),
          timezoneId: kTz,
          policy: const ExternalCalendarPolicy(),
          dateFrom: kFrom,
          dateTo: kTo,
          replaceMode: false,
        ),
        isNull,
      );
      expect(tiny.lastError, contains('过大'));

      final bad = File('${root.path}${Platform.pathSeparator}bad.ics');
      await bad.writeAsString('这根本不是 ICS 文件');
      expect(
        await service.preview(
          filePath: bad.path,
          timezoneId: kTz,
          policy: const ExternalCalendarPolicy(),
          dateFrom: kFrom,
          dateTo: kTo,
          replaceMode: false,
        ),
        isNull,
      );
      expect(service.lastError, contains('ICS'));
    });

    test('非法导入范围返回 null', () async {
      expect(
        await service.preview(
          filePath: fixturePath('basic_cn.ics'),
          timezoneId: kTz,
          policy: const ExternalCalendarPolicy(),
          dateFrom: '2026-13-01',
          dateTo: kTo,
          replaceMode: false,
        ),
        isNull,
      );
      expect(service.lastError, contains('日期'));
      expect(
        await service.preview(
          filePath: fixturePath('basic_cn.ics'),
          timezoneId: kTz,
          policy: const ExternalCalendarPolicy(),
          dateFrom: '2026-03-31',
          dateTo: '2026-03-01',
          replaceMode: false,
        ),
        isNull,
      );
      expect(service.lastError, contains('早于'));
    });

    test('空文件/只含不支持组件：预览可展示诊断，提交被拒绝', () async {
      final empty = await previewOf(fixturePath('empty.ics'));
      expect(empty.isEmpty, isTrue);
      expect(empty.snapshot.events, isEmpty);
      expect(empty.warnings.map((w) => w.code), contains('no-events'));
      expect(empty.diff.unsupported, 0);
      expect(await service.commit(empty), isFalse);
      expect(service.lastError, contains('没有可导入的事件'));
      expect(service.sources, isEmpty);

      final todo = File('${root.path}${Platform.pathSeparator}todo.ics');
      await todo.writeAsString('BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'BEGIN:VTODO\r\nUID:t@test\r\nDTSTAMP:20260101T000000Z\r\nEND:VTODO\r\n'
          'END:VCALENDAR\r\n');
      final onlyUnsupported = await previewOf(todo.path);
      expect(onlyUnsupported.isEmpty, isTrue);
      expect(onlyUnsupported.warnings.map((w) => w.code),
          contains('ignored-components'));
      expect(await service.commit(onlyUnsupported), isFalse);
    });
  });

  group('合并 vs 完整替换', () {
    test('完整替换移除文件里已不存在的事件；合并保留旧事件', () async {
      final source = await importFile('idempotent_a.ics');
      expect(service.snapshotOf(source.id)!.events, hasLength(1));

      // 完整替换成 basic_cn（两个不同 UID 的事件）。
      final replacePreview = await previewOf(
        fixturePath('basic_cn.ics'),
        existing: service.sourceById(source.id),
        replaceMode: true,
      );
      expect(replacePreview.replaceMode, isTrue);
      expect(replacePreview.diff.added, 2);
      expect(replacePreview.diff.removed, 1);
      expect(await service.commit(replacePreview), isTrue);
      expect(service.snapshotOf(source.id)!.events, hasLength(2));

      // 合并导入 exceptions.ics：旧的两条被保留，同时新增 4 条记录。
      final mergePreview = await previewOf(
        fixturePath('exceptions.ics'),
        existing: service.sourceById(source.id),
        replaceMode: false,
      );
      expect(mergePreview.warnings.map((w) => w.code), contains('merge-retained'));
      expect(mergePreview.diff.removed, 2,
          reason: 'diff 如实反映“文件里已不存在”的旧事件数');
      expect(mergePreview.diff.added, 4);
      expect(mergePreview.snapshot.events, hasLength(6),
          reason: '合并模式下旧事件仍保留在快照里，不会被悄悄删除');
      expect(await service.commit(mergePreview), isTrue);
      expect(service.snapshotOf(source.id)!.events, hasLength(6));
      // basic 2 条 + ex-1 的 3 个实例（改期/追加/排除后）+ ex-2 整系列取消。
      expect(service.busyFor(
        sourceIds: <String>{source.id},
        dateFrom: kFrom,
        dateTo: kTo,
        timezoneId: kTz,
      ), hasLength(5));
    });
  });

  group('忙碌实例', () {
    test('跨午夜实例按规划日拆分，日期与分钟都正确', () async {
      final source = await importFile('allday_midnight.ics');
      final instances = service.busyFor(
        sourceIds: <String>{source.id},
        dateFrom: '2026-03-05',
        dateTo: '2026-03-10',
        timezoneId: kTz,
      );
      final night = instances
          .where((i) => i.uid == 'night-1@example.test')
          .toList(growable: false);
      expect(night, hasLength(2));
      expect(night[0].dayKey, '2026-03-06');
      expect(night[0].startMinute, 1410);
      expect(night[0].endMinute, 1440);
      expect(night[1].dayKey, '2026-03-07');
      expect(night[1].startMinute, 0);
      expect(night[1].endMinute, 30);

      final allDay = instances
          .where((i) => i.uid == 'day-1@example.test')
          .toList(growable: false);
      expect(allDay, hasLength(1));
      expect(allDay.single.dayKey, '2026-03-05');
      expect(allDay.single.startMinute, 0);
      expect(allDay.single.endMinute, 1440);
    });

    test('范围只影响返回的实例，不修改快照', () async {
      final source = await importFile('recurrence.ics', from: '2026-01-01', to: '2027-04-01');
      final march = service.busyFor(
        sourceIds: <String>{source.id},
        dateFrom: '2026-03-01',
        dateTo: '2026-03-31',
        timezoneId: kTz,
      );
      expect(march, isNotEmpty);
      expect(march.every((i) => i.dayKey.startsWith('2026-03')), isTrue);
      // 快照里保存的是事件而不是实例，范围变化不需要重新导入。
      expect(service.snapshotOf(source.id)!.events, hasLength(8));
    });

    test('非法的忙碌范围返回空并设置 lastError', () async {
      final source = await importFile('basic_cn.ics');
      expect(
        service.busyFor(
          sourceIds: <String>{source.id},
          dateFrom: 'bad',
          dateTo: kTo,
          timezoneId: kTz,
        ),
        isEmpty,
      );
      expect(service.lastError, isNotNull);
      expect(
        service.busyFor(
          sourceIds: <String>{},
          dateFrom: kFrom,
          dateTo: kTo,
          timezoneId: kTz,
        ),
        isEmpty,
      );
    });

    test('展开触发资源上限时 busyFor 给出警告与 lastError', () async {
      final limited = ExternalCalendarService(
        store: store,
        limits: const IcsLimits(maxInstances: 1),
      );
      await limited.load();
      final preview = await limited.preview(
        filePath: fixturePath('recurrence.ics'),
        timezoneId: kTz,
        policy: const ExternalCalendarPolicy(),
        dateFrom: '2026-01-01',
        dateTo: '2027-04-01',
        replaceMode: false,
      );
      expect(preview, isNotNull);
      expect(preview!.truncated, isTrue);
      expect(await limited.commit(preview), isTrue);
      final busy = limited.busyFor(
        sourceIds: <String>{preview.candidate.id},
        dateFrom: '2026-01-01',
        dateTo: '2027-04-01',
        timezoneId: kTz,
      );
      expect(busy, hasLength(1));
      expect(limited.lastBusyWarnings.map((w) => w.code),
          contains('instance-limit'));
      expect(limited.lastError, contains('上限'));
    });
  });

  group('快照一致性', () {
    test('快照 revision 与来源不一致时（提交中断）不把它当成有效数据', () async {
      final source = await importFile('idempotent_a.ics');
      // 手工写一份 revision 不匹配的快照（模拟 commit 两步之间崩溃）。
      await store.saveSnapshot(ExternalSourceSnapshot(
        sourceId: source.id,
        revision: 99,
        contentHash: 'different',
        timezoneId: kTz,
        dateFrom: kFrom,
        dateTo: kTo,
        events: service.snapshotOf(source.id)!.events,
      ));
      final reloaded =
          ExternalCalendarService(store: store, limits: const IcsLimits());
      await reloaded.load();
      expect(reloaded.sourceById(source.id), isNotNull);
      expect(reloaded.snapshotOf(source.id), isNull);
      expect(reloaded.lastError, contains('不一致'));
      expect(
        reloaded.busyFor(
          sourceIds: <String>{source.id},
          dateFrom: kFrom,
          dateTo: kTo,
          timezoneId: kTz,
        ),
        isEmpty,
      );
    });

    test('来源 id 生成格式稳定（ext- + 12 hex）', () {
      final ids = <String>{
        for (var i = 0; i < 20; i++) newExternalSourceId(),
      };
      expect(ids, hasLength(20));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^ext-[0-9a-f]{12}$')));
      }
    });

    test('来源列表 JSON 是 UTF-8 且包含 schemaVersion', () async {
      await importFile('basic_cn.ics');
      final decoded =
          jsonDecode(store.sourcesFile.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['schemaVersion'], kExternalSourcesSchemaVersion);
      expect((decoded['sources'] as List<dynamic>), hasLength(1));
    });
  });
}
