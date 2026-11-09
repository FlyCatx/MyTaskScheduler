// 0.4.0 任务7：全局日程随备份导出/恢复。
//
// 覆盖：
//   * 异目录恢复：日程、重复/例外、删除标记、会话关联完整；提醒运行记录不进入备份；
//   * 重复恢复幂等（同内容跳过，不重写日程库、不留 .bak）；
//   * 同 ID 不同内容：保留本地并 warning；
//   * 旧备份没有日程段：不清空本地日程；
//   * 坏/超大/非法日程数据整份拒绝且不写任何文件；
//   * 恢复时按会话映射重写 linkedConversationId，无匹配解除并 warning；
//   * 部分恢复（新增/相同/冲突）分别计数并给出 warning；
//   * 未启用日程服务时不谎称已恢复日程。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/backup_service.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import '../support/test_support.dart';

String _p(List<String> parts) => parts.join(Platform.pathSeparator);

DateTime _stamp() => DateTime.utc(2026, 11, 1, 8);

ScheduleEvent _timedEvent({
  String id = 'ev-1',
  int revision = 1,
  String title = '例会',
  String? linkedConversationId,
  String? linkedTaskId,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  List<ScheduleException> exceptions = const <ScheduleException>[],
  DateTime? deletedAtUtc,
  int startMinute = 9 * 60,
  int endMinute = 10 * 60,
}) =>
    ScheduleEvent(
      id: id,
      revision: revision,
      title: title,
      timezoneId: 'Asia/Shanghai',
      allDay: false,
      startDate: '2026-11-10',
      startMinute: startMinute,
      endMinute: endMinute,
      linkedConversationId: linkedConversationId,
      linkedTaskId: linkedTaskId,
      repeat: repeat,
      reminder: ScheduleReminderKind.minutes15,
      exceptions: exceptions,
      createdAtUtc: _stamp(),
      updatedAtUtc: _stamp(),
      deletedAtUtc: deletedAtUtc,
    );

ScheduleEvent _allDayEvent({String id = 'ev-allday', String title = '纪念日'}) =>
    ScheduleEvent(
      id: id,
      revision: 1,
      title: title,
      timezoneId: 'Asia/Shanghai',
      allDay: true,
      startDate: '2026-11-09',
      endDateExclusive: '2026-11-11',
      blocksScheduling: false,
      reminder: ScheduleReminderKind.allDaySameDay,
      createdAtUtc: _stamp(),
      updatedAtUtc: _stamp(),
    );

Map<String, dynamic> _scheduleSection(
  List<ScheduleEvent> events, {
  int revision = 1,
}) =>
    <String, dynamic>{
      'schemaVersion': BackupService.scheduleSchemaVersion,
      'revision': revision,
      'events': events.map((event) => event.toJson()).toList(growable: false),
    };

Conversation _conversation({String id = 'conv-1', String title = '恢复的会话'}) {
  final when = DateTime(2026, 11, 1);
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

void main() {
  final tempDirs = <Directory>[];

  Directory temp(String name) {
    final dir = createTempDataDir(name);
    tempDirs.add(dir);
    return dir;
  }

  setUp(() {
    tempDirs.clear();
    ScheduleStore.resetInstanceLocksForTest();
  });

  tearDown(() {
    for (final dir in tempDirs.reversed) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // 单个临时目录删除失败不影响其他用例。
      }
    }
    ScheduleStore.resetInstanceLocksForTest();
  });

  Future<ScheduleStore> openSchedule(Directory dir) async {
    final store = ScheduleStore(dir);
    final opened = await store.open();
    expect(opened.readOnly, isFalse, reason: opened.notice);
    addTearDown(store.close);
    return store;
  }

  Future<void> seedSchedules(
    ScheduleStore store,
    List<ScheduleEvent> events, {
    int revision = 1,
  }) =>
      store.saveSnapshot(ScheduleSnapshot(
        revision: revision,
        events: <String, ScheduleEvent>{
          for (final event in events) event.id: event,
        },
      ));

  BackupService service(
    Directory root, {
    ScheduleStore? scheduleStore,
    Future<void> Function()? reloadSchedule,
    int? maxScheduleEvents,
    int? maxScheduleSectionBytes,
  }) =>
      BackupService(
        store: SessionStore(root),
        root: root,
        settingsStore: SettingsStore(root),
        scheduleStore: scheduleStore,
        reloadSchedule: reloadSchedule,
        maxScheduleEventsLimit:
            maxScheduleEvents ?? BackupService.maxScheduleEvents,
        maxScheduleSectionBytesLimit:
            maxScheduleSectionBytes ?? BackupService.maxScheduleSectionBytes,
      );

  String writeBackup(
    Directory dir, {
    String name = 'backup.json',
    List<Conversation> conversations = const <Conversation>[],
    Object? schedules,
    bool includeSchedules = false,
  }) {
    final path = _p(<String>[dir.path, name]);
    final summaries =
        conversations.map(ConversationSummary.of).toList(growable: false);
    final doc = <String, dynamic>{
      'schemaVersion': BackupService.schemaVersion,
      'kind': BackupService.backupKind,
      'conversations':
          conversations.map((conversation) => conversation.toJson())
              .toList(growable: false),
      'index': summaries.map((summary) => summary.toJson()).toList(growable: false),
    };
    if (includeSchedules) doc['schedules'] = schedules;
    File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(doc));
    return path;
  }

  test('异目录恢复：日程、重复/例外、删除标记与会话关联完整', () async {
    final src = temp('schedule-rt-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-seed');
    final srcSchedules = await openSchedule(src);
    final weekly = _timedEvent(
      id: 'ev-weekly',
      title: '每周例会',
      linkedConversationId: 'conv-seed',
      repeat: const ScheduleRepeatRule.weekly(
        weekdays: <int>[1, 3],
        untilDate: '2026-12-31',
      ),
      exceptions: <ScheduleException>[
        const ScheduleException.excluded(
          occurrenceKey: 'ev-weekly@2026-11-11',
        ),
        const ScheduleException.override(
          occurrenceKey: 'ev-weekly@2026-11-18',
          startDate: '2026-11-19',
          startMinute: 10 * 60,
          endMinute: 11 * 60,
        ),
      ],
    );
    final allDay = _allDayEvent(id: 'ev-allday', title: '纪念日');
    final deleted = _timedEvent(
      id: 'ev-deleted',
      title: '已删除日程',
      deletedAtUtc: DateTime.utc(2026, 11, 5),
    );
    await seedSchedules(
      srcSchedules,
      <ScheduleEvent>[weekly, allDay, deleted],
      revision: 7,
    );
    // 提醒运行记录不进入备份：跨目录恢复后不作为重新发送依据。
    File(_p(<String>[src.path, 'schedules', 'reminder_state.json']))
        .writeAsStringSync('{"sent":["REMINDER-MARKER"]}');

    final backupPath = _p(<String>[src.path, 'backup.json']);
    final exported =
        await service(src, scheduleStore: srcSchedules).exportBackup(backupPath);

    expect(exported.scheduleEventCount, 3);
    expect(exported.warning, isNull);
    final text = await File(backupPath).readAsString();
    expect(text.contains('REMINDER-MARKER'), isFalse);
    final doc = jsonDecode(text) as Map<String, dynamic>;
    final section = doc['schedules'] as Map<String, dynamic>;
    expect(section['schemaVersion'], BackupService.scheduleSchemaVersion);
    expect(section['revision'], 7);
    expect(section['events'] as List<dynamic>, hasLength(3));

    final dst = temp('schedule-rt-dst');
    final dstSchedules = await openSchedule(dst);
    var reloads = 0;
    final restored = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        reloads++;
        await dstSchedules.reload();
      },
    ).restoreBackup(backupPath);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.scheduleSectionPresent, isTrue);
    expect(restored.scheduleEventCount, 3);
    expect(restored.restoredScheduleEventCount, 3);
    expect(restored.skippedScheduleEventCount, 0);
    expect(restored.conflictScheduleEventIds, isEmpty);
    expect(restored.unlinkedScheduleEventIds, isEmpty);
    expect(restored.scheduleReloaded, isTrue);
    expect(restored.scheduleNotices, isEmpty);
    expect(reloads, 1);
    expect(await SessionStore(dst).loadConversation('conv-seed'), isNotNull);
    expect(
      File(_p(<String>[dst.path, 'schedules', 'reminder_state.json']))
          .existsSync(),
      isFalse,
      reason: '提醒运行记录不随备份恢复',
    );

    ScheduleEvent restoredEvent(String id) => dstSchedules.snapshot.events[id]!;
    expect(
      jsonEncode(restoredEvent('ev-weekly').toJson()),
      jsonEncode(weekly.toJson()),
    );
    expect(restoredEvent('ev-weekly').linkedConversationId, 'conv-seed');
    expect(restoredEvent('ev-weekly').repeat.weekdays, <int>[1, 3]);
    expect(restoredEvent('ev-weekly').exceptions, hasLength(2));
    expect(
      restoredEvent('ev-weekly').exceptions.first.occurrenceKey,
      'ev-weekly@2026-11-11',
    );
    expect(
      jsonEncode(restoredEvent('ev-allday').toJson()),
      jsonEncode(allDay.toJson()),
    );
    expect(restoredEvent('ev-allday').blocksScheduling, isFalse);
    expect(restoredEvent('ev-deleted').isDeleted, isTrue);
  });

  test('重复恢复幂等：同内容跳过，不重写日程库、不留 .bak', () async {
    final src = temp('schedule-idem-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-seed');
    final srcSchedules = await openSchedule(src);
    await seedSchedules(srcSchedules, <ScheduleEvent>[
      _timedEvent(id: 'ev-1'),
      _allDayEvent(id: 'ev-2'),
    ]);
    final backupPath = _p(<String>[src.path, 'backup.json']);
    await service(src, scheduleStore: srcSchedules).exportBackup(backupPath);

    final dst = temp('schedule-idem-dst');
    final dstSchedules = await openSchedule(dst);
    var reloads = 0;
    Future<void> reload() async {
      reloads++;
      await dstSchedules.reload();
    }

    final first = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: reload,
    ).restoreBackup(backupPath);
    expect(first.ok, isTrue, reason: first.error);
    expect(first.restoredScheduleEventCount, 2);
    final eventsFile =
        File(_p(<String>[dst.path, 'schedules', 'events.json']));
    final bytesAfterFirst = eventsFile.readAsBytesSync();
    final revisionAfterFirst = dstSchedules.snapshot.revision;

    final second = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: reload,
    ).restoreBackup(backupPath);

    expect(second.ok, isTrue, reason: second.error);
    expect(second.scheduleSectionPresent, isTrue);
    expect(second.restoredScheduleEventCount, 0);
    expect(second.skippedScheduleEventCount, 2);
    expect(second.conflictScheduleEventIds, isEmpty);
    expect(reloads, 1, reason: '没有改动时不应重复刷新日程服务');
    expect(eventsFile.readAsBytesSync(), bytesAfterFirst);
    expect(dstSchedules.snapshot.revision, revisionAfterFirst);
    expect(File('${eventsFile.path}.bak').existsSync(), isFalse);
  });
  test('同 ID 不同内容：保留本地日程并给出 warning', () async {
    final src = temp('schedule-conflict-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-seed');
    final srcSchedules = await openSchedule(src);
    await seedSchedules(srcSchedules, <ScheduleEvent>[
      _timedEvent(id: 'ev-shared', title: '备份标题'),
    ]);
    final backupPath = _p(<String>[src.path, 'backup.json']);
    await service(src, scheduleStore: srcSchedules).exportBackup(backupPath);

    final dst = temp('schedule-conflict-dst');
    await seedConversation(SessionStore(dst), conversationId: 'conv-seed');
    final dstSchedules = await openSchedule(dst);
    await seedSchedules(dstSchedules, <ScheduleEvent>[
      _timedEvent(id: 'ev-shared', title: '本地标题', revision: 3),
    ]);
    final eventsFile =
        File(_p(<String>[dst.path, 'schedules', 'events.json']));
    final eventsBefore = eventsFile.readAsBytesSync();

    final restored = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        await dstSchedules.reload();
      },
    ).restoreBackup(backupPath);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredScheduleEventCount, 0);
    expect(restored.conflictScheduleEventIds, <String>['ev-shared']);
    expect(restored.scheduleNotices, isNotEmpty);
    expect(restored.warning, contains('保留本地'));
    expect(restored.summary, contains('保留本地'));
    expect(dstSchedules.snapshot.events['ev-shared']!.title, '本地标题');
    expect(dstSchedules.snapshot.events['ev-shared']!.revision, 3);
    expect(eventsFile.readAsBytesSync(), eventsBefore,
        reason: '只有冲突、没有新增时不得重写日程库');
  });

  test('旧备份没有日程段：不清空本地日程', () async {
    final dst = temp('schedule-old-dst');
    await seedConversation(SessionStore(dst), conversationId: 'conv-seed');
    final dstSchedules = await openSchedule(dst);
    await seedSchedules(dstSchedules, <ScheduleEvent>[
      _timedEvent(id: 'ev-local', title: '本地日程'),
    ]);
    final eventsFile = File(_p(<String>[dst.path, 'schedules', 'events.json']));
    final before = eventsFile.readAsBytesSync();
    final backupPath = writeBackup(
      dst,
      conversations: <Conversation>[_conversation(id: 'conv-new')],
    );

    final restored = await service(dst, scheduleStore: dstSchedules)
        .restoreBackup(backupPath);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredConversationCount, 1);
    expect(restored.scheduleSectionPresent, isFalse);
    expect(restored.scheduleEventCount, 0);
    expect(restored.restoredScheduleEventCount, 0);
    expect(restored.scheduleNotices, isEmpty);
    expect(eventsFile.readAsBytesSync(), before,
        reason: '旧备份没有日程段时不得改写本地日程库');
    await dstSchedules.reload();
    expect(dstSchedules.snapshot.events.containsKey('ev-local'), isTrue);
  });

  test('坏/超大/非法日程数据整份拒绝且不写任何文件', () async {
    final dst = temp('schedule-bad-dst');
    await seedConversation(SessionStore(dst), conversationId: 'conv-seed');
    final dstSchedules = await openSchedule(dst);
    await seedSchedules(dstSchedules, <ScheduleEvent>[
      _timedEvent(id: 'ev-local'),
    ]);
    final scheduleFile =
        File(_p(<String>[dst.path, 'schedules', 'events.json']));
    final scheduleBefore = scheduleFile.readAsBytesSync();
    final conversationFile = File(
      _p(<String>[dst.path, 'conversations', 'conv-seed.json']),
    );
    final conversationBefore = conversationFile.readAsStringSync();

    final cases = <({
      String name,
      Object? schedules,
      int? maxEvents,
      int? maxBytes,
      String expected,
    })>[
      (
        name: 'not-a-map',
        schedules: 'oops',
        maxEvents: null,
        maxBytes: null,
        expected: '日程数据结构',
      ),
      (
        name: 'bad-version',
        schedules: <String, dynamic>{
          'schemaVersion': 99,
          'revision': 1,
          'events': <dynamic>[],
        },
        maxEvents: null,
        maxBytes: null,
        expected: '版本不受支持',
      ),
      (
        name: 'bad-revision',
        schedules: <String, dynamic>{
          'schemaVersion': BackupService.scheduleSchemaVersion,
          'revision': 'x',
          'events': <dynamic>[],
        },
        maxEvents: null,
        maxBytes: null,
        expected: 'revision',
      ),
      (
        name: 'bad-events',
        schedules: <String, dynamic>{
          'schemaVersion': BackupService.scheduleSchemaVersion,
          'revision': 1,
          'events': 'x',
        },
        maxEvents: null,
        maxBytes: null,
        expected: '列表',
      ),
      (
        name: 'invalid-event',
        schedules: _scheduleSection(<ScheduleEvent>[
          _timedEvent(id: 'ev-bad', title: ''),
        ]),
        maxEvents: null,
        maxBytes: null,
        expected: '第 1 条日程',
      ),
      (
        name: 'duplicate-id',
        schedules: _scheduleSection(<ScheduleEvent>[
          _timedEvent(id: 'ev-dup'),
          _timedEvent(id: 'ev-dup', startMinute: 11 * 60, endMinute: 12 * 60),
        ]),
        maxEvents: null,
        maxBytes: null,
        expected: '重复的日程 ID',
      ),
      (
        name: 'too-many-events',
        schedules: _scheduleSection(<ScheduleEvent>[
          _timedEvent(id: 'ev-a'),
          _timedEvent(id: 'ev-b', startMinute: 11 * 60, endMinute: 12 * 60),
          _timedEvent(id: 'ev-c', startMinute: 13 * 60, endMinute: 14 * 60),
        ]),
        maxEvents: 2,
        maxBytes: null,
        expected: '过多',
      ),
      (
        name: 'too-large-section',
        schedules: _scheduleSection(<ScheduleEvent>[
          _timedEvent(id: 'ev-a'),
        ]),
        maxEvents: null,
        maxBytes: 64,
        expected: '过大',
      ),
    ];

    for (final testCase in cases) {
      final path = writeBackup(
        dst,
        name: '${testCase.name}.json',
        conversations: <Conversation>[_conversation(id: 'conv-other')],
        schedules: testCase.schedules,
        includeSchedules: true,
      );
      final restored = await service(
        dst,
        scheduleStore: dstSchedules,
        maxScheduleEvents: testCase.maxEvents,
        maxScheduleSectionBytes: testCase.maxBytes,
      ).restoreBackup(path);
      expect(restored.ok, isFalse, reason: testCase.name);
      expect(restored.error, contains(testCase.expected),
          reason: testCase.name);
      expect(
        File(_p(<String>[dst.path, 'conversations', 'conv-other.json']))
            .existsSync(),
        isFalse,
        reason: '${testCase.name}: 校验失败不得写入任何会话',
      );
    }
    expect(scheduleFile.readAsBytesSync(), scheduleBefore);
    expect(conversationFile.readAsStringSync(), conversationBefore);
    await dstSchedules.reload();
    expect(dstSchedules.snapshot.events.containsKey('ev-local'), isTrue);
  });

  test('恢复时按会话映射重写关联；无匹配解除并 warning', () async {
    final dst = temp('schedule-link-dst');
    final dstStore = SessionStore(dst);
    await seedConversation(dstStore, conversationId: 'conv-local');
    final dstSchedules = await openSchedule(dst);
    final path = writeBackup(
      dst,
      conversations: <Conversation>[_conversation(id: 'conv-A')],
      includeSchedules: true,
      schedules: _scheduleSection(<ScheduleEvent>[
        _timedEvent(
          id: 'ev-linked',
          linkedConversationId: 'conv-A',
          linkedTaskId: 'task-1',
        ),
        _timedEvent(
          id: 'ev-local-linked',
          linkedConversationId: 'conv-local',
          startMinute: 11 * 60,
          endMinute: 12 * 60,
        ),
        _timedEvent(
          id: 'ev-dangling',
          linkedConversationId: 'conv-gone',
          linkedTaskId: 'task-gone',
          startMinute: 13 * 60,
          endMinute: 14 * 60,
        ),
      ]),
    );

    final restored = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        await dstSchedules.reload();
      },
    ).restoreBackup(path);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredScheduleEventCount, 3);
    expect(restored.unlinkedScheduleEventIds, <String>['ev-dangling']);
    expect(restored.warning, contains('解除关联'));
    expect(dstSchedules.snapshot.events['ev-linked']!.linkedConversationId,
        'conv-A');
    // 会话映射不变时保留稳定任务引用。
    expect(dstSchedules.snapshot.events['ev-linked']!.linkedTaskId, 'task-1');
    expect(
      dstSchedules.snapshot.events['ev-local-linked']!.linkedConversationId,
      'conv-local',
    );
    expect(
      dstSchedules.snapshot.events['ev-dangling']!.linkedConversationId,
      isNull,
    );
    // 解除会话关联时必须同时清空任务引用，避免备份恢复后悬空误跳。
    expect(dstSchedules.snapshot.events['ev-dangling']!.linkedTaskId, isNull);
    expect(await dstStore.loadConversation('conv-A'), isNotNull);
  });

  test('备份导出/恢复往返保留 linkedTaskId；旧备份缺失字段默认 null', () async {
    final src = temp('schedule-task-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-1');
    final srcSchedules = await openSchedule(src);
    await srcSchedules.open();
    await srcSchedules.saveSnapshot(ScheduleSnapshot(
      revision: 1,
      events: <String, ScheduleEvent>{
        'ev-task': _timedEvent(
          id: 'ev-task',
          linkedConversationId: 'conv-1',
          linkedTaskId: 'task-42',
        ),
      },
    ));
    final backupPath = _p(<String>[src.path, 'task-backup.json']);
    await service(src, scheduleStore: srcSchedules).exportBackup(backupPath);

    final dst = temp('schedule-task-dst');
    await seedConversation(SessionStore(dst), conversationId: 'conv-1');
    final dstSchedules = await openSchedule(dst);
    final restored = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        await dstSchedules.reload();
      },
    ).restoreBackup(backupPath);
    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredScheduleEventCount, 1);
    expect(dstSchedules.snapshot.events['ev-task']!.linkedTaskId, 'task-42');

    // 旧备份（事件 JSON 没有 linkedTaskId）恢复后默认 null，不判损坏。
    final legacyPath = writeBackup(
      dst,
      conversations: <Conversation>[_conversation(id: 'conv-old')],
      includeSchedules: true,
      schedules: <String, dynamic>{
        'schemaVersion': BackupService.scheduleSchemaVersion,
        'revision': 1,
        'events': <Map<String, dynamic>>[
          Map<String, dynamic>.from(_timedEvent(id: 'ev-legacy').toJson())
            ..remove('linkedTaskId'),
        ],
      },
    );
    final legacy = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        await dstSchedules.reload();
      },
    ).restoreBackup(legacyPath);
    expect(legacy.ok, isTrue, reason: legacy.error);
    expect(dstSchedules.snapshot.events['ev-legacy']!.linkedTaskId, isNull);
  });

  test('部分恢复：新增/相同/冲突分别计数并给出 warning', () async {
    final src = temp('schedule-partial-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-seed');
    final srcSchedules = await openSchedule(src);
    final same = _timedEvent(id: 'ev-same', title: '相同');
    final changedRemote = _timedEvent(
      id: 'ev-conflict',
      title: '备份版本',
      startMinute: 11 * 60,
      endMinute: 12 * 60,
    );
    final added = _allDayEvent(id: 'ev-new', title: '新增');
    await seedSchedules(
      srcSchedules,
      <ScheduleEvent>[same, changedRemote, added],
    );
    final backupPath = _p(<String>[src.path, 'backup.json']);
    await service(src, scheduleStore: srcSchedules).exportBackup(backupPath);

    final dst = temp('schedule-partial-dst');
    await seedConversation(SessionStore(dst), conversationId: 'conv-seed');
    final dstSchedules = await openSchedule(dst);
    final localChanged = _timedEvent(
      id: 'ev-conflict',
      title: '本地版本',
      revision: 5,
      startMinute: 11 * 60,
      endMinute: 12 * 60,
    );
    final localOnly = _timedEvent(
      id: 'ev-local-only',
      title: '仅本地',
      startMinute: 15 * 60,
      endMinute: 16 * 60,
    );
    await seedSchedules(
      dstSchedules,
      <ScheduleEvent>[same, localChanged, localOnly],
    );

    final restored = await service(
      dst,
      scheduleStore: dstSchedules,
      reloadSchedule: () async {
        await dstSchedules.reload();
      },
    ).restoreBackup(backupPath);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredScheduleEventCount, 1);
    expect(restored.skippedScheduleEventCount, 1);
    expect(restored.conflictScheduleEventIds, <String>['ev-conflict']);
    expect(dstSchedules.snapshot.events['ev-conflict']!.title, '本地版本');
    expect(dstSchedules.snapshot.events.containsKey('ev-new'), isTrue);
    expect(dstSchedules.snapshot.events.containsKey('ev-local-only'), isTrue,
        reason: '备份里没有的本地日程必须保留');
    expect(restored.summary, contains('1 条日程'));
    expect(restored.summary, contains('1 条日程内容相同'));
    expect(restored.summary, contains('保留本地'));
    expect(restored.warning, contains('保留本地'));
  });

  test('未启用日程服务：不谎报日程已恢复，其余数据照常恢复', () async {
    final dst = temp('schedule-noservice-dst');
    final path = writeBackup(
      dst,
      conversations: <Conversation>[_conversation(id: 'conv-new')],
      includeSchedules: true,
      schedules: _scheduleSection(<ScheduleEvent>[_timedEvent(id: 'ev-1')]),
    );

    final restored = await service(dst).restoreBackup(path);

    expect(restored.ok, isTrue, reason: restored.error);
    expect(restored.restoredConversationCount, 1);
    expect(restored.scheduleSectionPresent, isTrue);
    expect(restored.scheduleEventCount, 1);
    expect(restored.restoredScheduleEventCount, 0);
    expect(restored.scheduleNotices, isNotEmpty);
    expect(restored.warning, contains('未启用日程服务'));
    expect(Directory(_p(<String>[dst.path, 'schedules'])).existsSync(), isFalse);
    expect(await SessionStore(dst).loadConversation('conv-new'), isNotNull);
  });

  test('未启用日程服务导出：文档不含 schedules 段', () async {
    final src = temp('schedule-noexport-src');
    await seedConversation(SessionStore(src), conversationId: 'conv-seed');
    final backupPath = _p(<String>[src.path, 'backup.json']);
    final exported = await service(src).exportBackup(backupPath);
    expect(exported.scheduleEventCount, 0);
    final doc =
        jsonDecode(await File(backupPath).readAsString()) as Map<String, dynamic>;
    expect(doc.containsKey('schedules'), isFalse);
  });
}
