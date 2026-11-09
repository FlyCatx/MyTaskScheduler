// 日程展开回归：跨日、全天排他、重复/例外、时区/DST、上限与不完整状态。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';

ScheduleEvent _event({
  String id = 'ev-1',
  String timezoneId = 'Asia/Shanghai',
  bool allDay = false,
  String startDate = '2026-11-09',
  int? startMinute = 540,
  int? endMinute = 600,
  String? endDateExclusive,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  List<ScheduleException> exceptions = const <ScheduleException>[],
}) =>
    ScheduleEvent(
      id: id,
      revision: 0,
      title: '会议',
      timezoneId: timezoneId,
      allDay: allDay,
      startDate: startDate,
      startMinute: startMinute,
      endMinute: endMinute,
      endDateExclusive: endDateExclusive,
      repeat: repeat,
      exceptions: exceptions,
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    );

/// 以事件时区的当地日期构造查询范围（含首日 00:00 到末日次日 00:00）。
ScheduleQuery _queryLocal(
  String timezoneId,
  String fromDate,
  String toDateExclusive, {
  int maxOccurrences = kScheduleMaxOccurrences,
}) {
  final resolver = IcsTimeZoneResolver();
  DateTime utcOf(String date) {
    final r = resolver.resolveWall(timezoneId, DateTime.utc(
      int.parse(date.substring(0, 4)),
      int.parse(date.substring(5, 7)),
      int.parse(date.substring(8, 10)),
    ));
    return r.utc!;
  }
  return ScheduleQuery(
    fromUtc: utcOf(fromDate),
    toUtc: utcOf(toDateExclusive),
    timezoneId: timezoneId,
    maxOccurrences: maxOccurrences,
  );
}

void main() {
  test('跨日定时事件是一条实例，时长 60 分钟，不出现负时长', () {
    final event = _event(startMinute: 23 * 60 + 30, endMinute: 24 * 60 + 30);
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-11'),
    );
    expect(result.complete, isTrue);
    expect(result.occurrences, hasLength(1));
    final occurrence = result.occurrences.single;
    expect(occurrence.startUtc, DateTime.utc(2026, 11, 9, 15, 30));
    expect(occurrence.endUtc, DateTime.utc(2026, 11, 9, 16, 30));
    expect(occurrence.duration, const Duration(minutes: 60));
  });

  test('全天 11 月 9—10 日：排他结束是 11 日，10 日仍命中，11 日不占', () {
    final event = _event(
      allDay: true,
      startDate: '2026-11-09',
      startMinute: null,
      endMinute: null,
      endDateExclusive: '2026-11-11',
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-12'),
    );
    final occurrence = result.occurrences.single;
    expect(occurrence.startDate, '2026-11-09');
    expect(occurrence.endDateExclusive, '2026-11-11');
    expect(occurrence.allDay, isTrue);

    // 只看 10 日也能找到该全天日程。
    final day10 = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-10', '2026-11-11'),
    );
    expect(day10.occurrences, hasLength(1));
  });

  test('每周一三 until 周三：包含最后周三，其他日不出现', () {
    final event = _event(
      repeat: const ScheduleRepeatRule.weekly(
        weekdays: <int>[1, 3],
        untilDate: '2026-11-18',
      ),
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-30'),
    );
    expect(result.complete, isTrue);
    expect(
      result.occurrences.map((o) => o.originalDate),
      <String>['2026-11-09', '2026-11-11', '2026-11-16', '2026-11-18'],
    );
  });

  test('改本次到周四：原周三排除、周四一条、key 仍指向原周三；窗口外也能找到', () {
    final event = _event(
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
      exceptions: const <ScheduleException>[
        ScheduleException.override(
          occurrenceKey: 'ev-1@2026-11-11',
          startDate: '2026-11-12',
          startMinute: 600,
          endMinute: 660,
        ),
      ],
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-20'),
    );
    final dates = result.occurrences.map((o) => o.originalDate).toList();
    // 出现日按原始日期记录：11 日仍是一条（被 override 到 12 日），18 日正常。
    expect(dates,
        <String>['2026-11-09', '2026-11-11', '2026-11-16', '2026-11-18']);
    final override = result.occurrences
        .firstWhere((o) => o.occurrenceKey == 'ev-1@2026-11-11');
    expect(override.isOverride, isTrue);
    expect(override.startUtc, DateTime.utc(2026, 11, 12, 2, 0));

    // 只查询 12 日：override 的原始日期在窗口外，仍必须按覆盖时间出现。
    final moved = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-12', '2026-11-13'),
    );
    expect(moved.occurrences.map((o) => o.occurrenceKey),
        contains('ev-1@2026-11-11'));
  });

  test('单次排除后该实例不再出现', () {
    final event = _event(
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
      exceptions: const <ScheduleException>[
        ScheduleException.excluded(occurrenceKey: 'ev-1@2026-11-11'),
      ],
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-20'),
    );
    expect(result.occurrences.map((o) => o.originalDate),
        isNot(contains('2026-11-11')));
    expect(result.occurrences.map((o) => o.originalDate),
        contains('2026-11-09'));
  });

  test('不同时区按当地钟点重复：Asia/Shanghai 09:00 = 01:00Z', () {
    final event = _event(
      timezoneId: 'Asia/Shanghai',
      repeat: const ScheduleRepeatRule.daily(untilDate: '2026-11-11'),
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-10', '2026-11-12'),
    );
    expect(result.occurrences, hasLength(2));
    expect(result.occurrences.first.startUtc, DateTime.utc(2026, 11, 10, 1));
  });

  test('America/New_York 跨夏令时回拨仍保持当地 09:00', () {
    final event = _event(
      timezoneId: 'America/New_York',
      startDate: '2026-10-31',
      repeat: const ScheduleRepeatRule.daily(untilDate: '2026-11-02'),
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('America/New_York', '2026-10-30', '2026-11-04'),
    );
    expect(result.complete, isTrue);
    expect(result.occurrences, hasLength(3));
    // 10/31 09:00 EDT = 13:00Z；11/1 起 EST，09:00 = 14:00Z。
    expect(result.occurrences[0].startUtc, DateTime.utc(2026, 10, 31, 13));
    expect(result.occurrences[1].startUtc, DateTime.utc(2026, 11, 1, 14));
    expect(result.occurrences[2].startUtc, DateTime.utc(2026, 11, 2, 14));
  });

  test('DST 前跳不存在的本地时间：警告 + complete=false，不静默归一化', () {
    final event = _event(
      timezoneId: 'America/New_York',
      startDate: '2026-03-07',
      startMinute: 2 * 60 + 30,
      endMinute: 3 * 60 + 30,
      repeat: const ScheduleRepeatRule.daily(untilDate: '2026-03-09'),
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('America/New_York', '2026-03-06', '2026-03-10'),
    );
    expect(result.complete, isFalse);
    expect(result.warnings.join('；'), contains('本地开始时间无法确定'));
    // 3/8 02:30 不存在，该实例不出现；其余两天仍可见。
    expect(result.occurrences, hasLength(2));
    expect(result.occurrences.map((o) => o.originalDate),
        isNot(contains('2026-03-08')));
  });

  test('实例超过上限时返回 complete=false，且不返回超过上限的条目', () {
    final event = _event(repeat: const ScheduleRepeatRule.daily());
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-12-09',
          maxOccurrences: 5),
    );
    expect(result.complete, isFalse);
    expect(result.occurrences.length, lessThanOrEqualTo(5));
    expect(result.warnings.join('；'), contains('上限'));
  });

  test('非法查询与未知时区都不返回“完整空集”', () {
    final invalid = expandScheduleEvents(
      events: <ScheduleEvent>[_event()],
      query: ScheduleQuery(
        fromUtc: DateTime.utc(2026, 11, 9),
        toUtc: DateTime.utc(2026, 11, 8),
        timezoneId: 'Asia/Shanghai',
      ),
    );
    expect(invalid.complete, isFalse);
    expect(invalid.warnings, isNotEmpty);

    final unknownZone = expandScheduleEvents(
      events: <ScheduleEvent>[_event(timezoneId: 'Not/AZone')],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-11'),
    );
    expect(unknownZone.complete, isFalse);
    expect(unknownZone.occurrences, isEmpty);
    expect(unknownZone.warnings, isNotEmpty);
  });

  test('超过 400 天查询范围明确失败', () {
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[_event()],
      query: ScheduleQuery(
        fromUtc: DateTime.utc(2024, 1, 1),
        toUtc: DateTime.utc(2026, 3, 1),
        timezoneId: 'Asia/Shanghai',
      ),
    );
    expect(result.complete, isFalse);
    expect(result.warnings.join('；'), contains('400'));
  });

  test('DST 时区的每周重复跨换季仍保持当地钟点 09:00', () {
    // 2026 年纽约夏令时：3 月 8 日开始、11 月 1 日结束。
    final weekly = _event(
      timezoneId: 'America/New_York',
      startDate: '2026-03-02', // 周一
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
    );
    final spring = expandScheduleEvents(
      events: <ScheduleEvent>[weekly],
      query: _queryLocal('America/New_York', '2026-03-02', '2026-03-16'),
    );
    expect(spring.complete, isTrue);
    expect(spring.occurrences.map((o) => o.originalDate),
        <String>['2026-03-02', '2026-03-09']);
    // 换季前 EST（UTC-5）与换季后 EDT（UTC-4）的 UTC 时刻不同，但当地都是 09:00。
    expect(spring.occurrences.first.startUtc, DateTime.utc(2026, 3, 2, 14));
    expect(spring.occurrences.last.startUtc, DateTime.utc(2026, 3, 9, 13));
    for (final occurrence in spring.occurrences) {
      final wall = wallOf(occurrence.startUtc!, 'America/New_York');
      expect(wall!.hour, 9);
      expect(wall.minute, 0);
    }

    // 回拨：10 月 26 日（EDT）→ 11 月 2 日（EST）当地仍 09:00。
    final fallEvent = _event(
      timezoneId: 'America/New_York',
      startDate: '2026-10-19', // 周一
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
    );
    final fall = expandScheduleEvents(
      events: <ScheduleEvent>[fallEvent],
      query: _queryLocal('America/New_York', '2026-10-19', '2026-11-09'),
    );
    expect(fall.complete, isTrue);
    final nov2 = fall.occurrences
        .firstWhere((occurrence) => occurrence.originalDate == '2026-11-02');
    expect(nov2.startUtc, DateTime.utc(2026, 11, 2, 14));
    expect(wallOf(nov2.startUtc!, 'America/New_York')!.hour, 9);
  });

  test('实例携带稳定的关联任务 ID，排序不改变身份', () {
    final event = ScheduleEvent(
      id: 'ev-linked',
      revision: 0,
      title: '联调',
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-09',
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      linkedConversationId: 'conv-1',
      linkedTaskId: 'task-7',
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    );
    final result = expandScheduleEvents(
      events: <ScheduleEvent>[event],
      query: _queryLocal('Asia/Shanghai', '2026-11-09', '2026-11-11'),
    );
    expect(result.complete, isTrue);
    expect(result.occurrences.single.linkedTaskId, 'task-7');
    expect(result.occurrences.single.linkedConversationId, 'conv-1');
    expect(result.occurrences.single.toJson()['linkedTaskId'], 'task-7');
  });
}
