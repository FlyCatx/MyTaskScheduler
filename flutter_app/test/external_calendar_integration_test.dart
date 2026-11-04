// 外部日历接入层（T-D）的模型级集成测试。
//
// 覆盖：
//   T01 外部忙碌 + 手工日期 free 例外不被擦除（外部忙碌优先）；
//       外部占用与任务预留重叠时双方数据保留，冲突可解释为“外部日历”来源；
//   T02 请求里的 timetable / effectiveTimetable / calendarRevision 来自同一合成
//       快照，且合成快照包含外部占用；
//   T03 手工 revision 或外部指纹变化后，迟到结果被拒绝；
//   T04 匿名标题：真实事件标题/来源名不进合成时间表与请求，忙碌区间不被截断；
//   D01 0.2.1 旧数据（无 externalSourceIds / externalCalendarRef）打开后请求形状
//       与 0.2.1 完全一致、默认不启用外部日历；
//   D02 备份→另一目录恢复后外部来源与有效占用一致（不依赖原 ICS 文件）。
//
// 全部使用合成数据：不读真实日历、不发网络、不启动原生 DLL。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/backup_service.dart';
import 'package:taskscheduler_flutter/src/state/calendar_planner.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_store.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_expander.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/timetable_composition.dart';

import 'support/test_support.dart';

const String _sourceId = 'ext-aabbccddeeff';
const String _otherSourceId = 'ext-001122334455';
const String _secretEventTitle = '真实事件标题不该出现';
const String _secretSourceName = '私密日程表';

/// 只提供“已加载来源 + 已展开忙碌”的测试替身：不读磁盘、不解析 ICS。
class FakeExternalCalendarService extends ExternalCalendarService {
  FakeExternalCalendarService({
    List<ExternalCalendarSource> sources = const <ExternalCalendarSource>[],
    List<ExternalBusyInstance> busy = const <ExternalBusyInstance>[],
    String fingerprint = 'fp-1',
  })  : _sources = List<ExternalCalendarSource>.of(sources),
        _busy = List<ExternalBusyInstance>.unmodifiable(busy),
        _fingerprint = fingerprint,
        super(
          store: ExternalCalendarStore(Directory.systemTemp),
          limits: const IcsLimits(),
        );

  final List<ExternalCalendarSource> _sources;
  final List<ExternalBusyInstance> _busy;
  String _fingerprint;

  @override
  List<ExternalCalendarSource> get sources =>
      List<ExternalCalendarSource>.unmodifiable(_sources);

  @override
  String get fingerprint => _fingerprint;

  /// 与真实服务一致的会话级指纹：只聚合给定来源的 id|revision|contentHash。
  @override
  String fingerprintOf(Iterable<String> sourceIds) {
    final ids = sourceIds.toSet().toList()..sort();
    final parts = <String>[_fingerprint];
    for (final id in ids) {
      final source = sourceById(id);
      if (source == null || !source.enabled) continue;
      parts.add('${source.id}|${source.revision}|${source.contentHash}');
    }
    return parts.join('#');
  }

  void changeFingerprint(String value) {
    _fingerprint = value;
    notifyListeners();
  }

  /// 测试用启停：只改内存状态，不写盘。
  bool setEnabledForTest(String id, bool enabled) {
    for (var i = 0; i < _sources.length; i++) {
      if (_sources[i].id != id) continue;
      _sources[i] = _sources[i].copyWith(enabled: enabled);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 测试用“重新导入”：只改 revision/hash，不写盘。
  bool bumpRevisionForTest(String id) {
    for (var i = 0; i < _sources.length; i++) {
      if (_sources[i].id != id) continue;
      final next = _sources[i].revision + 1;
      _sources[i] = _sources[i].copyWith(
        revision: next,
        contentHash: 'hash-$id-v$next',
      );
      notifyListeners();
      return true;
    }
    return false;
  }

  @override
  ExternalCalendarSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  @override
  List<ExternalBusyInstance> busyFor({
    required Set<String> sourceIds,
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
  }) =>
      _busy
          .where((instance) =>
              sourceIds.contains(instance.sourceId) &&
              instance.dayKey.compareTo(dateFrom) >= 0 &&
              instance.dayKey.compareTo(dateTo) <= 0)
          .toList(growable: false);
}

ExternalBusyInstance _busy({
  String sourceId = _sourceId,
  String uid = 'uid-1',
  required String dayKey,
  required int startMinute,
  required int endMinute,
  bool busy = true,
}) {
  final wall = DateTime.utc(
    int.parse(dayKey.substring(0, 4)),
    int.parse(dayKey.substring(5, 7)),
    int.parse(dayKey.substring(8, 10)),
  );
  const offset = Duration(hours: 8);
  return ExternalBusyInstance(
    sourceId: sourceId,
    uid: uid,
    startUtc: wall.add(Duration(minutes: startMinute)).subtract(offset),
    endUtc: wall.add(Duration(minutes: endMinute)).subtract(offset),
    busy: busy,
    dayKey: dayKey,
    startMinute: startMinute,
    endMinute: endMinute,
  );
}

ExternalCalendarSource _source({
  String id = _sourceId,
  String name = _secretSourceName,
  int revision = 2,
  bool enabled = true,
  String dateFrom = '2026-11-01',
  String dateTo = '2026-11-30',
}) =>
    ExternalCalendarSource(
      id: id,
      name: name,
      contentHash: 'hash-$id',
      importedAt: '2026-11-01T00:00:00.000Z',
      revision: revision,
      dateFrom: dateFrom,
      dateTo: dateTo,
      timezoneId: 'Asia/Shanghai',
      enabled: enabled,
    );

/// 手工时间表：2026-11-09 起一周，10:00-12:00 是用户手画的“这一天可用”。
Timetable _manualWithFreeException({int revision = 4}) {
  final base = Timetable.withDefaults(
    weekStart: '2026-11-09',
    revision: revision,
  );
  return base.paint(
    date: '2026-11-10',
    start: 10 * 60,
    end: 12 * 60,
    state: TimetableState.free,
    origin: TimetableOrigin.manual,
    title: '手动可用',
  );
}

/// 手工时间表：2026-11-10 10:00-11:00 绑定任务 taskA 的蓝色预留。
Timetable _manualWithTaskReservation({int revision = 4}) {
  final base = Timetable.withDefaults(
    weekStart: '2026-11-09',
    revision: revision,
  );
  return base.paint(
    date: '2026-11-10',
    start: 10 * 60,
    end: 11 * 60,
    state: TimetableState.task,
    origin: TimetableOrigin.manual,
    title: '任务安排',
    taskId: 'taskA',
    reservationId: 'res-A',
  );
}

CalendarSettings _baseSettings() => CalendarSettings(
      timezoneId: 'Asia/Shanghai',
      timezoneOffsetMinutes: 480,
      planningStartDate: '2026-11-09',
      planningDays: 14,
      weekly: WeeklyAvailability({
        for (var day = 1; day <= 7; day++)
          day: const <WallClockRange>[WallClockRange(480, 1080)],
      }),
    );

PlanVersion _version(Timetable timetable, {String id = 'ver-1'}) => PlanVersion(
      id: id,
      conversationId: 'conv-ext',
      revision: 0,
      createdAt: DateTime.utc(2026, 11, 9),
      summary: '外部日历集成',
      tasks: const <TaskRecord>[
        TaskRecord(id: 'taskA', name: '写报告', estimatedHours: 2),
      ],
      calendar: CalendarSchedule(settings: _baseSettings()),
      timetable: timetable,
    );

Conversation _conversation(
  PlanVersion version, {
  Set<String> externalSourceIds = const <String>{},
}) =>
    Conversation(
      id: 'conv-ext',
      title: '外部日历集成',
      createdAt: DateTime.utc(2026, 11, 9),
      updatedAt: DateTime.utc(2026, 11, 9),
      versions: <PlanVersion>[version],
      currentVersionId: version.id,
      externalSourceIds: externalSourceIds,
    );

/// 一棵普通的合成结果：外部忙碌 2026-11-10 10:30-11:30。
List<ExternalBusyInstance> _defaultBusy() => <ExternalBusyInstance>[
      _busy(dayKey: '2026-11-10', startMinute: 630, endMinute: 690),
    ];

DateTime _overlapStart() => DateTime.utc(2026, 11, 10, 2, 30); // 10:30 +08

void main() {
  group('T01 合成时间表', () {
    test('外部忙碌优先，但手工日期 free 例外在忙碌时段之外仍然生效', () {
      final manual = _manualWithFreeException();
      final composed = composeExternalBusy(
        manual: manual,
        busy: _defaultBusy(),
        timezoneId: 'Asia/Shanghai',
      );

      // 手工时间表本身不被修改：它只有手工来源的条目。
      expect(manual.dates.any((e) => e.origin == TimetableOrigin.external),
          isFalse);
      expect(manual.stateAt('2026-11-10', DateTime.tuesday, 11 * 60),
          TimetableState.free);

      // 忙碌分钟：占用，来源 external，标题匿名，没有任务/预留绑定。
      final busyInterval = composed
          .dayIntervals('2026-11-10', DateTime.tuesday)
          .firstWhere((i) => i.start == 630);
      expect(busyInterval.state, TimetableState.occupied);
      expect(busyInterval.origin, TimetableOrigin.external);
      expect(busyInterval.title, '外部日历');
      expect(busyInterval.taskId, isNull);
      expect(busyInterval.reservationId, isNull);

      // 忙碌之外的“这一天可用”例外没有被擦除：11:30-12:00 仍然是 free。
      final afterBusy = composed
          .dayIntervals('2026-11-10', DateTime.tuesday)
          .firstWhere((i) => i.start == 690);
      expect(afterBusy.state, TimetableState.free);
      expect(composed.stateAt('2026-11-10', DateTime.tuesday, 11 * 60 + 45),
          TimetableState.free);
      // 忙碌之前的手工可用也保留。
      expect(composed.stateAt('2026-11-10', DateTime.tuesday, 10 * 60 + 15),
          TimetableState.free);

      // 合成结果必须仍是同一层不重叠的一致性快照（请求会校验）。
      expect(composed.isConsistent, isTrue);
      expect(composed.hasExternalBusy, isTrue);
      // 契约 id：ext-<sourceId>-<yyyymmdd>-<start>-<end>
      expect(
        composed.dates
            .where((e) => e.origin == TimetableOrigin.external)
            .map((e) => e.id),
        contains('ext-$_sourceId-20261110-630-690'),
      );
      // 只读标记绝不进入 taskId / reservationId。
      for (final entry in composed.dates
          .where((e) => e.origin == TimetableOrigin.external)) {
        expect(entry.taskId, isNull);
        expect(entry.reservationId, isNull);
        expect(entry.title, '外部日历');
      }

      // 请求使用的派生视图与合成快照同源，而且能展开外部占用。
      final effective = deriveEffectiveTimetable(composed);
      expect(effective['sourceRevision'], composed.revision);
      final day = (effective['days'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((d) => d['date'] == '2026-11-10');
      final intervals =
          (day['intervals'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        intervals.any((i) =>
            i['start'] == 630 &&
            i['end'] == 690 &&
            i['state'] == TimetableState.occupied.code),
        isTrue,
      );
    });

    test('coverage 取手工覆盖与忙碌日期的并集', () {
      final manual = _manualWithFreeException();
      expect(manual.dateTo.compareTo('2026-12-01') < 0, isTrue);
      final composed = composeExternalBusy(
        manual: manual,
        busy: <ExternalBusyInstance>[
          _busy(dayKey: '2026-12-01', startMinute: 120, endMinute: 180),
        ],
        timezoneId: 'Asia/Shanghai',
      );
      expect(composed.dateTo, '2026-12-01');
      expect(composed.dateFrom, manual.dateFrom);
      expect(composed.coverageDays, greaterThan(manual.coverageDays));
      // 原手工日期仍可展开。
      expect(composed.stateAt('2026-11-10', DateTime.tuesday, 11 * 60 + 45),
          TimetableState.free);
    });

    test('外部占用与任务预留重叠：双方数据保留，冲突可解释为外部日历来源', () {
      final manual = _manualWithTaskReservation();
      final composed = composeExternalBusy(
        manual: manual,
        busy: _defaultBusy(), // 10:30-11:30 与 10:00-11:00 的蓝块重叠
        timezoneId: 'Asia/Shanghai',
      );

      // 手工蓝块没有被抹掉：10:00-10:30 仍是绑定了 taskA 的任务预留。
      final kept = composed.dates
          .where((e) => e.state == TimetableState.task)
          .where((e) => e.start == 600);
      expect(kept, isNotEmpty);
      expect(kept.first.end, 630);
      expect(kept.first.taskId, 'taskA');
      expect(kept.first.reservationId, 'res-A');
      // 外部占用段同时存在。
      expect(
        composed.dates.any((e) =>
            e.origin == TimetableOrigin.external &&
            e.start == 630 &&
            e.end == 690),
        isTrue,
      );

      // 用合成快照派生 settings：外部占用带 external/sourceId，排程器能扣除它。
      final derived = composed.toCalendarSettings(_baseSettings());
      final externalOccupancies =
          derived.occupancies.where((o) => o.external).toList(growable: false);
      expect(externalOccupancies, hasLength(1));
      expect(externalOccupancies.single.sourceId, _sourceId);
      expect(externalOccupancies.single.title, '外部日历');
      expect(externalOccupancies.single.date, '2026-11-10');
      expect(externalOccupancies.single.ranges.single.startMinute, 630);

      // 冲突检测：用户原本 10:00-11:00 的任务片段落在外部占用上，必须可见，
      // 且冲突说明能指出“外部日历”。
      final clock = derived.clock;
      final schedule = CalendarSchedule(
        settings: derived,
        segments: manual.taskSegments(clock),
      );
      final conflicts = detectConflicts(
        schedule: schedule,
        tasks: const <SchedulingTask>[
          SchedulingTask(id: 'taskA', name: '写报告', estimatedHours: 2),
        ],
        now: DateTime.utc(2026, 11, 9),
      );
      final externalConflict = conflicts
          .where((c) =>
              c.kind == ConflictKind.unavailable &&
              c.message.contains('外部日历'))
          .toList(growable: false);
      expect(externalConflict, isNotEmpty);
      expect(externalConflict.first.start, _overlapStart());
      // 双方数据都还在：用户片段没有被改写。
      expect(schedule.segments.single.start,
          DateTime.utc(2026, 11, 10, 2, 0));
      expect(schedule.segments.single.end, DateTime.utc(2026, 11, 10, 3, 0));
    });

    test('多个来源的外部忙碌重叠时合成结果仍一致（同状态占用）', () {
      final manual = _manualWithFreeException();
      final composed = composeExternalBusy(
        manual: manual,
        busy: <ExternalBusyInstance>[
          _busy(dayKey: '2026-11-10', startMinute: 630, endMinute: 690),
          _busy(
            sourceId: _otherSourceId,
            uid: 'uid-2',
            dayKey: '2026-11-10',
            startMinute: 660,
            endMinute: 720,
          ),
        ],
        timezoneId: 'Asia/Shanghai',
      );
      expect(composed.isConsistent, isTrue);
      // 10:30-12:00 全部是占用；两个来源的条目都存在（互相切割后仍保留来源身份）。
      for (final minute in <int>[630, 660, 700, 719]) {
        expect(composed.stateAt('2026-11-10', DateTime.tuesday, minute),
            TimetableState.occupied);
      }
      final sources = composed.dates
          .where((e) => e.origin == TimetableOrigin.external)
          .map((e) => composed.externalSourceIdOf(e))
          .toSet();
      expect(sources, <String>{_sourceId, _otherSourceId});
      // 受影响的合成条目来源映射齐全，且标题都是匿名串。
      for (final entry in composed.dates
          .where((e) => e.origin == TimetableOrigin.external)) {
        expect(composed.externalSourceIdOf(entry), isNotNull);
        expect(entry.title, '外部日历');
      }
      // 手工 free 例外被忙碌覆盖到 12:00，之后恢复为默认占用。
      expect(composed.stateAt('2026-11-10', DateTime.tuesday, 720),
          TimetableState.occupied);
    });

    test('没有忙碌时原样返回手工时间表（0.2.1 行为不变）', () {
      final manual = _manualWithFreeException();
      final composed = composeExternalBusy(
        manual: manual,
        busy: const <ExternalBusyInstance>[],
        timezoneId: 'Asia/Shanghai',
      );
      expect(identical(composed, manual), isTrue);
      expect(composed.toJson(), manual.toJson());
    });
  });

  group('T02/T04 模型请求同源与隐私', () {
    late FakeExternalCalendarService service;

    setUp(() {
      service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[_source()],
        busy: _defaultBusy(),
      );
    });

    AppController controllerWith(FakeExternalCalendarService service) {
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
        externalCalendar: service,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('timetable / effectiveTimetable / calendarRevision 来自同一合成快照', () {
      final manual = _manualWithFreeException();
      final version = _version(manual);
      final conversation =
          _conversation(version, externalSourceIds: <String>{_sourceId});
      final controller = controllerWith(service);
      final manualBefore = jsonEncode(manual.toJson());

      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: version,
        requestId: 'req-ext',
        draft: '按我的空闲时间安排',
      );

      final timetable = request['timetable'] as Map<String, dynamic>;
      final effective = request['effectiveTimetable'] as Map<String, dynamic>;
      expect(request['calendarRevision'], manual.revision);
      expect(timetable['revision'], manual.revision);
      expect(effective['sourceRevision'], timetable['revision']);

      // 请求时间表里确实带了外部占用（state=0、origin=external、匿名标题）。
      final dates = (timetable['dates'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final external = dates
          .where((e) =>
              e['origin'] == 'external' &&
              e['date'] == '2026-11-10' &&
              e['start'] == 630 &&
              e['end'] == 690)
          .toList(growable: false);
      expect(external, hasLength(1));
      expect(external.single['state'], TimetableState.occupied.code);
      expect(external.single['title'], '外部日历');
      expect(external.single['taskId'], isNull);
      expect(external.single['reservationId'], isNull);

      // 派生视图与权威规则逐天同源：忙碌当天出现相同的外部占用区间。
      final day = (effective['days'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((d) => d['date'] == '2026-11-10');
      final intervals =
          (day['intervals'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        intervals.any((i) =>
            i['start'] == 630 && i['end'] == 690 && i['state'] == 0),
        isTrue,
      );

      // context 只带来源身份（id/revision/范围），不带标题或路径。
      final context = request['context'] as Map<String, dynamic>;
      final externalSources =
          (context['externalSources'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(externalSources, hasLength(1));
      expect(externalSources.single['id'], _sourceId);
      expect(externalSources.single['revision'], 2);
      expect(externalSources.single['dateFrom'], '2026-11-01');
      expect(externalSources.single['dateTo'], '2026-11-30');
      expect(externalSources.single.containsKey('name'), isFalse);
      expect(externalSources.single.containsKey('contentHash'), isFalse);

      // 真实事件标题/来源名不出现在请求 JSON 的任何位置。
      final encoded = jsonEncode(request);
      expect(encoded.contains(_secretEventTitle), isFalse);
      expect(encoded.contains(_secretSourceName), isFalse);
      // 匿名标题是唯一允许的展示串。
      expect(encoded.contains('外部日历'), isTrue);

      // 手工权威时间表没有被合成改写（合成快照不落盘、不回写）。
      expect(jsonEncode(manual.toJson()), manualBefore);
      final composed = controller.requestTimetableFor(conversation, version);
      expect(composed, isNotNull);
      expect(composed!.hasExternalBusy, isTrue);
      expect(identical(composed, manual), isFalse);
    });

    test('T04 忙碌区间不静默截断：整段都进入派生视图', () {
      final manual = _manualWithFreeException();
      final busy = <ExternalBusyInstance>[
        _busy(dayKey: '2026-11-10', startMinute: 600, endMinute: 720),
      ];
      final composed = composeExternalBusy(
        manual: manual,
        busy: busy,
        timezoneId: 'Asia/Shanghai',
      );
      final effective = deriveEffectiveTimetable(composed);
      final day = (effective['days'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((d) => d['date'] == '2026-11-10');
      final intervals =
          (day['intervals'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        intervals.any((i) =>
            i['start'] == 600 && i['end'] == 720 && i['state'] == 0),
        isTrue,
      );
      // 全天必须完整覆盖 0..1440（派生视图不允许缺口）。
      final cursor = intervals.fold<int>(
          0, (end, interval) => interval['end'] as int);
      expect(cursor, kTimetableMinutesPerDay);
    });
  });

  group('T03 迟到结果拒绝', () {
    test('手工 revision 变化 → 拒绝', () {
      final message = AppController.staleResultMessage(
        requestedTimetableRevision: 4,
        currentTimetableRevision: 5,
        requestedExternalFingerprint: 'fp-1',
        currentExternalFingerprint: 'fp-1',
      );
      expect(message, isNotNull);
      expect(message!, contains('时间表'));
    });

    test('外部指纹变化 → 拒绝', () {
      final message = AppController.staleResultMessage(
        requestedTimetableRevision: 4,
        currentTimetableRevision: 4,
        requestedExternalFingerprint: 'fp-1',
        currentExternalFingerprint: 'fp-2',
      );
      expect(message, isNotNull);
      expect(message!, contains('外部日历'));
    });

    test('两者都没变（或未带时间表）→ 可采纳', () {
      expect(
        AppController.staleResultMessage(
          requestedTimetableRevision: 4,
          currentTimetableRevision: 4,
          requestedExternalFingerprint: '',
          currentExternalFingerprint: '',
        ),
        isNull,
      );
      expect(
        AppController.staleResultMessage(
          requestedTimetableRevision: -1,
          currentTimetableRevision: 7,
          requestedExternalFingerprint: 'fp-1',
          currentExternalFingerprint: 'fp-1',
        ),
        isNull,
      );
    });

    test('控制器读到的会话级外部指纹随来源变化，并用于拒绝', () {
      final manual = _manualWithFreeException();
      final version = _version(manual);
      final service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[
          _source(),
          _source(id: _otherSourceId, name: '另一个来源'),
        ],
        busy: _defaultBusy(),
      );
      addTearDown(service.dispose);
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
        externalCalendar: service,
      );
      addTearDown(controller.dispose);
      final conversation =
          _conversation(version, externalSourceIds: <String>{_sourceId});
      final requested = controller.externalFingerprintFor(conversation);
      expect(requested, isNotEmpty);

      // 无关来源（会话没有关联）变化不应让本会话的结果过期。
      expect(service.bumpRevisionForTest(_otherSourceId), isTrue);
      expect(controller.externalFingerprintFor(conversation), requested);

      // 关联来源内容变化 → 指纹变化 → 拒绝。
      expect(service.bumpRevisionForTest(_sourceId), isTrue);
      final current = controller.externalFingerprintFor(conversation);
      expect(current, isNot(requested));
      final message = AppController.staleResultMessage(
        requestedTimetableRevision: manual.revision,
        currentTimetableRevision: version.timetable!.revision,
        requestedExternalFingerprint: requested,
        currentExternalFingerprint: current,
      );
      expect(message, isNotNull);
      expect(message!, contains('外部日历'));
    });
  });

  group('D01 0.2.1 旧数据迁移', () {
    test('旧会话/版本缺新字段：读回默认不启用，请求形状与 0.2.1 一致', () {
      final manual = _manualWithFreeException();
      final legacyVersionJson = <String, dynamic>{
        'id': 'ver-legacy',
        'conversationId': 'conv-legacy',
        'revision': 4,
        'createdAt': DateTime.utc(2026, 11, 9).toIso8601String(),
        'summary': '旧版本',
        'tasks': const <dynamic>[],
        'notes': const <dynamic>[],
        'calendar': CalendarSchedule(settings: _baseSettings()).toJson(),
        'timetable': manual.toJson(),
        // 0.2.1 没有 externalCalendarRef 键。
      };
      final version = PlanVersion.fromJson(legacyVersionJson);
      expect(version.externalCalendarRef, isNull);
      expect(legacyVersionJson.containsKey('externalCalendarRef'), isFalse);

      final legacyConversationJson = <String, dynamic>{
        'id': 'conv-legacy',
        'title': '旧会话',
        'createdAt': DateTime.utc(2026, 11, 9).toIso8601String(),
        'updatedAt': DateTime.utc(2026, 11, 9).toIso8601String(),
        'versions': <dynamic>[legacyVersionJson],
        'includeTimetable': true,
        // 0.2.1 没有 externalSourceIds 键。
      };
      final conversation = Conversation.fromJson(legacyConversationJson);
      expect(conversation.externalSourceIds, isEmpty);

      // 无服务、无关联来源 → 请求与 0.2.1 完全一致（不增加任何键）。
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
      );
      addTearDown(controller.dispose);
      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: version,
        requestId: 'req-legacy',
        draft: '旧材料',
      );
      expect(request['calendarRevision'], 4);
      expect((request['timetable'] as Map<String, dynamic>).length, greaterThan(0));
      // 没有外部数据时请求里的时间表就是手工权威 JSON，逐字节一致。
      expect(request['timetable'], manual.toJson());
      final context = request['context'] as Map<String, dynamic>;
      expect(context.containsKey('externalSources'), isFalse);
      expect(context.keys.toSet(),
          <String>{'currentDate', 'timezoneId', 'timezoneOffsetMinutes'});
      // 每一条时间表区间都仍是手工/默认来源，没有一行外部占用。
      final dates = (request['timetable'] as Map<String, dynamic>)['dates']
          as List<dynamic>;
      for (final raw in dates.cast<Map<String, dynamic>>()) {
        expect(raw['origin'], isNot('external'));
      }

      // 会话与版本重新序列化后仍然没有外部数据（不污染旧数据）。
      final roundTrip = Conversation.fromJson(conversation.toJson());
      expect(roundTrip.externalSourceIds, isEmpty);
      expect(roundTrip.versions.single.externalCalendarRef, isNull);
    });

    test('旧备份（没有 externalCalendar 段）仍可恢复', () {
      // 结构校验路径：_parse 对缺失的 externalCalendar 键是“无外部日历”，不报错。
      final version = _version(_manualWithFreeException(), id: 'ver-old');
      final conversation = _conversation(version);
      final roundTrip = Conversation.fromJson(
          jsonDecode(jsonEncode(conversation.toJson())) as Map<String, dynamic>);
      expect(roundTrip.externalSourceIds, isEmpty);
      expect(roundTrip.currentVersion!.externalCalendarRef, isNull);
    });
  });

  group('会话级关联与历史快照', () {
    Future<({AppController controller, InMemorySessionRepository store})>
        readyController(FakeExternalCalendarService service) async {
      final store = InMemorySessionRepository();
      final version = _version(_manualWithFreeException());
      final conversation = _conversation(version);
      await store.ensureLayout();
      await store.saveConversation(conversation);
      await store.saveIndex(<ConversationSummary>[
        ConversationSummary.of(conversation),
      ]);
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: store,
        externalCalendar: service,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      return (controller: controller, store: store);
    }

    test('会话级来源关联：默认空、新会话不继承、写回后持久化并生效', () async {
      final service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[
          _source(),
          _source(id: _otherSourceId, name: '另一个来源'),
        ],
        busy: _defaultBusy(),
      );
      addTearDown(service.dispose);
      final ready = await readyController(service);
      final controller = ready.controller;
      const conversationId = 'conv-ext';

      expect(controller.externalSourceIdsForConversation(conversationId),
          isEmpty);
      // 新会话不继承任何来源。
      final created = await controller.createConversation();
      expect(created.externalSourceIds, isEmpty);

      // 写入（含多余空白的 id 会被规范化；未知 id 保留在会话上，由启用过滤生效）。
      expect(
        await controller.setExternalSourcesForConversation(
            conversationId, <String>{_sourceId, '  ', _otherSourceId}),
        isTrue,
      );
      final persisted = await ready.store.loadConversation(conversationId);
      expect(persisted!.externalSourceIds, <String>{_sourceId, _otherSourceId});
      expect(
        controller.externalSourceIdsForConversation(conversationId),
        <String>{_sourceId, _otherSourceId},
      );

      // 停用其中一个来源：会话关联仍在，但“实际生效”的集合会过滤掉它。
      expect(service.setEnabledForTest(_otherSourceId, false), isTrue);
      expect(controller.externalSourceIdsForConversation(conversationId),
          <String>{_sourceId});
    });

    test('停用/未知来源不触发合成；请求形状回到 0.2.1', () async {
      final service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[
          _source(enabled: false),
        ],
        busy: _defaultBusy(),
      );
      addTearDown(service.dispose);
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
        externalCalendar: service,
      );
      addTearDown(controller.dispose);
      final manual = _manualWithFreeException();
      final version = _version(manual);
      final conversation =
          _conversation(version, externalSourceIds: <String>{_sourceId});
      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: version,
        requestId: 'req-disabled',
        draft: '材料',
      );
      expect((request['context'] as Map<String, dynamic>)
          .containsKey('externalSources'), isFalse);
      expect(request['timetable'], manual.toJson());
    });

    test('externalBusyInRange 只返回已关联来源、且落在范围内的忙碌实例', () async {
      final service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[_source()],
        busy: _defaultBusy(),
      );
      addTearDown(service.dispose);
      final ready = await readyController(service);
      final controller = ready.controller;
      await controller.openConversation('conv-ext');
      await controller.setExternalSourcesForConversation(
          'conv-ext', <String>{_sourceId});

      final inRange = controller.externalBusyInRange(
        dateFrom: '2026-11-09',
        dateTo: '2026-11-15',
      );
      expect(inRange, hasLength(1));
      expect(inRange.single.sourceId, _sourceId);
      expect(inRange.single.startMinute, 630);
      expect(inRange.single.endMinute, 690);

      final outside = controller.externalBusyInRange(
        dateFrom: '2026-11-16',
        dateTo: '2026-11-20',
      );
      expect(outside, isEmpty);
      // 该实例没有任何标题字段（只读展示不会泄露外部事件内容）。
      expect(inRange.single.toString().contains(_secretEventTitle), isFalse);
    });

    test('外部占用绝不写回版本：即使合成 settings 传入保存路径也会被剥离', () async {
      final service = FakeExternalCalendarService(
        sources: <ExternalCalendarSource>[_source()],
        busy: _defaultBusy(),
      );
      addTearDown(service.dispose);
      final ready = await readyController(service);
      final controller = ready.controller;
      await controller.openConversation('conv-ext');
      await controller.setExternalSourcesForConversation(
          'conv-ext', <String>{_sourceId});

      final version = controller.viewVersion!;
      final composed = controller.calendarWithExternalBusy(version);
      expect(composed.settings.occupancies.any((o) => o.external), isTrue,
          reason: '合成快照确实带了外部占用');

      final ok = await controller.applyTimetableSettings(
        composed.settings,
        version.timetable!,
        reschedule: false,
      );
      expect(ok, isTrue);
      final saved = controller.viewVersion!;
      expect(saved.calendar.settings.occupancies.any((o) => o.external), isFalse,
          reason: '落盘的 settings 不得含外部占用');
      expect(saved.timetable!.revision, version.timetable!.revision + 1);

      final reloaded = await ready.store.loadConversation('conv-ext');
      final persisted = reloaded!.versions.last;
      expect(persisted.calendar.settings.occupancies.any((o) => o.external),
          isFalse);
      expect(persisted.timetable!.hasExternalBusy, isFalse);
    });

    test('PlanVersion.externalCalendarRef 往返序列化（旧版本缺省为 null）', () {
      final version = _version(_manualWithFreeException(), id: 'ver-ref');
      expect(version.externalCalendarRef, isNull);
      final withRef = version.copyWith(
        externalCalendarRef: const ExternalCalendarRef(
          fingerprint: 'fp-commit',
          sources: <ExternalCalendarSourceRef>[
            ExternalCalendarSourceRef(
              id: _sourceId,
              revision: 3,
              contentHash: 'hash-commit',
              dateFrom: '2026-11-01',
              dateTo: '2026-11-30',
            ),
          ],
        ),
      );
      final decoded = PlanVersion.fromJson(
          jsonDecode(jsonEncode(withRef.toJson())) as Map<String, dynamic>);
      expect(decoded.externalCalendarRef, isNotNull);
      expect(decoded.externalCalendarRef!.fingerprint, 'fp-commit');
      expect(decoded.externalCalendarRef!.sources.single.id, _sourceId);
      expect(decoded.externalCalendarRef!.sources.single.revision, 3);
      // 历史快照只含身份与范围，不含事件标题。
      final encoded = jsonEncode(decoded.toJson());
      expect(encoded.contains(_secretEventTitle), isFalse);
      expect(encoded.contains(_secretSourceName), isFalse);
      // 没有该键的旧 JSON 读回 null（不报错）。
      final legacy = withRef.toJson()..remove('externalCalendarRef');
      expect(PlanVersion.fromJson(legacy).externalCalendarRef, isNull);
    });
  });

  group('D02 备份恢复', () {
    test('外部日历目录随备份保存，恢复到另一目录后来源与占用一致', () async {
      final sourceRoot = createTempDataDir('ext-backup-src');
      final targetRoot = createTempDataDir('ext-backup-dst');
      addTearDown(() {
        if (sourceRoot.existsSync()) sourceRoot.deleteSync(recursive: true);
        if (targetRoot.existsSync()) targetRoot.deleteSync(recursive: true);
      });

      final icsFile = File(
          '${sourceRoot.path}${Platform.pathSeparator}synthetic.ics');
      await icsFile.writeAsString(_syntheticIcs(), flush: true);

      final sourceStore = ExternalCalendarStore(sourceRoot);
      final service = ExternalCalendarService(
        store: sourceStore,
        limits: const IcsLimits(),
      );
      addTearDown(service.dispose);
      await service.load();
      final preview = await service.preview(
        filePath: icsFile.path,
        timezoneId: 'Asia/Shanghai',
        policy: const ExternalCalendarPolicy(),
        dateFrom: '2026-11-01',
        dateTo: '2026-11-30',
        replaceMode: false,
      );
      expect(preview, isNotNull, reason: service.lastError);
      expect(await service.commit(preview!), isTrue, reason: service.lastError);
      expect(service.sources, hasLength(1));

      final sourceId = service.sources.single.id;
      final beforeBusy = service.busyFor(
        sourceIds: <String>{sourceId},
        dateFrom: '2026-11-01',
        dateTo: '2026-11-30',
        timezoneId: 'Asia/Shanghai',
      );
      expect(beforeBusy, isNotEmpty);

      final backupPath =
          '${sourceRoot.path}${Platform.pathSeparator}ext-backup.json';
      final backup = BackupService(
        store: SessionStore(sourceRoot),
        root: sourceRoot,
      );
      final exported = await backup.exportBackup(backupPath);
      expect(exported.path, backupPath);
      final document = jsonDecode(await File(backupPath).readAsString())
          as Map<String, dynamic>;
      final externalDoc = document['externalCalendar'] as Map<String, dynamic>;
      final files = (externalDoc['files'] as List<dynamic>);
      expect(files, isNotEmpty);

      final restoreBackup = BackupService(
        store: SessionStore(targetRoot),
        root: targetRoot,
      );
      final restored = await restoreBackup.restoreBackup(backupPath);
      expect(restored.ok, isTrue, reason: restored.error);
      expect(restored.restoredExternalCalendarFileCount, files.length);

      // 恢复不依赖原 ICS：目标目录里没有 .ics，只有外部日历快照数据。
      final restoredService = ExternalCalendarService(
        store: ExternalCalendarStore(targetRoot),
        limits: const IcsLimits(),
      );
      addTearDown(restoredService.dispose);
      await restoredService.load();
      expect(restoredService.sources, hasLength(1));
      final restoredSource = restoredService.sources.single;
      expect(restoredSource.id, sourceId);
      expect(restoredSource.revision, service.sources.single.revision);
      expect(restoredSource.contentHash, service.sources.single.contentHash);
      expect(restoredSource.dateFrom, service.sources.single.dateFrom);
      expect(restoredSource.dateTo, service.sources.single.dateTo);
      expect(restoredService.fingerprint, service.fingerprint);

      final afterBusy = restoredService.busyFor(
        sourceIds: <String>{sourceId},
        dateFrom: '2026-11-01',
        dateTo: '2026-11-30',
        timezoneId: 'Asia/Shanghai',
      );
      expect(afterBusy.length, beforeBusy.length);
      for (var i = 0; i < beforeBusy.length; i++) {
        expect(afterBusy[i].sourceId, beforeBusy[i].sourceId);
        expect(afterBusy[i].dayKey, beforeBusy[i].dayKey);
        expect(afterBusy[i].startMinute, beforeBusy[i].startMinute);
        expect(afterBusy[i].endMinute, beforeBusy[i].endMinute);
        expect(afterBusy[i].busy, beforeBusy[i].busy);
      }
    });
  });
}

/// 合成 ICS：一个 2026-11-10 10:00-11:00 (+08) 的普通占用事件。
String _syntheticIcs() => <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//TaskScheduler//Test//CN',
      'CALSCALE:GREGORIAN',
      'BEGIN:VEVENT',
      'UID:test-event-1',
      'DTSTAMP:20261101T000000Z',
      'DTSTART:20261110T020000Z',
      'DTEND:20261110T030000Z',
      'SUMMARY:$_secretEventTitle',
      'STATUS:CONFIRMED',
      'TRANSP:OPAQUE',
      'END:VEVENT',
      'END:VCALENDAR',
      '',
    ].join('\r\n');
