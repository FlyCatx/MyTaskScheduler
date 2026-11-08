// 日程模型回归：字段互斥、严格解析、重复规则与 occurrenceKey 稳定性。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';

ScheduleEvent _event({
  String id = 'ev-1',
  bool allDay = false,
  String startDate = '2026-11-09',
  int? startMinute = 540,
  int? endMinute = 600,
  String? endDateExclusive,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  ScheduleReminderKind reminder = ScheduleReminderKind.none,
  List<ScheduleException> exceptions = const <ScheduleException>[],
  String? linkedConversationId,
}) =>
    ScheduleEvent(
      id: id,
      revision: 0,
      title: '项目会议',
      timezoneId: 'Asia/Shanghai',
      allDay: allDay,
      startDate: startDate,
      startMinute: startMinute,
      endMinute: endMinute,
      endDateExclusive: endDateExclusive,
      repeat: repeat,
      reminder: reminder,
      exceptions: exceptions,
      linkedConversationId: linkedConversationId,
      createdAtUtc: DateTime.utc(2026, 11, 1, 0),
      updatedAtUtc: DateTime.utc(2026, 11, 1, 0),
    );

void main() {
  test('定时/全天事件 JSON 往返保持字段与例外', () {
    final timed = _event(
      linkedConversationId: 'conv-1',
      repeat: const ScheduleRepeatRule.weekly(
        weekdays: <int>[1, 3],
        untilDate: '2026-12-01',
      ),
      reminder: ScheduleReminderKind.minutes15,
      exceptions: const <ScheduleException>[
        ScheduleException.excluded(occurrenceKey: 'ev-1@2026-11-11'),
        ScheduleException.override(
          occurrenceKey: 'ev-1@2026-11-18',
          startDate: '2026-11-19',
          startMinute: 600,
          endMinute: 660,
        ),
      ],
    );
    final parsed = ScheduleEvent.tryParse(timed.toJson());
    expect(parsed, isNotNull);
    expect(parsed!.title, '项目会议');
    expect(parsed.startMinute, 540);
    expect(parsed.endMinute, 600);
    expect(parsed.repeat.kind, ScheduleRepeatKind.weekly);
    expect(parsed.repeat.weekdays, <int>[1, 3]);
    expect(parsed.exceptions, hasLength(2));
    expect(parsed.exceptions.first.excluded, isTrue);
    expect(parsed.exceptions.last.startDate, '2026-11-19');
    expect(parsed.linkedConversationId, 'conv-1');
    expect(parsed.toJson(), timed.toJson());

    final allDay = _event(
      allDay: true,
      startDate: '2026-11-09',
      startMinute: null,
      endMinute: null,
      endDateExclusive: '2026-11-11',
      reminder: ScheduleReminderKind.allDaySameDay,
    );
    final parsedAllDay = ScheduleEvent.tryParse(allDay.toJson());
    expect(parsedAllDay, isNotNull);
    expect(parsedAllDay!.allDay, isTrue);
    expect(parsedAllDay.endDateExclusive, '2026-11-11');
    expect(parsedAllDay.allDayDayCount, 2);
  });

  test('脏字段组合被严格拒绝', () {
    final base = _event().toJson();
    expect(ScheduleEvent.tryParse(base), isNotNull);

    Map<String, dynamic> broken(void Function(Map<String, dynamic>) change) {
      final j = Map<String, dynamic>.from(base);
      change(j);
      return j;
    }

    expect(ScheduleEvent.tryParse(broken((j) => j['startMinute'] = null)), isNull);
    expect(ScheduleEvent.tryParse(broken((j) => j['startMinute'] = 600)), isNull,
        reason: '结束分钟必须大于开始分钟');
    expect(ScheduleEvent.tryParse(broken((j) => j['allDay'] = true)), isNull,
        reason: '全天不能带定时字段');
    expect(ScheduleEvent.tryParse(broken((j) => j['title'] = '  ')), isNull);
    expect(ScheduleEvent.tryParse(broken((j) => j['category'] = 'other')), isNull);
    expect(ScheduleEvent.tryParse(broken((j) => j['reminder'] = 'allDaySameDay')),
        isNull);
    expect(
        ScheduleEvent.tryParse(broken((j) => j['repeat'] = <String, dynamic>{
              'kind': 'weekly',
              'weekdays': <int>[],
            })),
        isNull);
    expect(
        ScheduleEvent.tryParse(broken((j) => j['repeat'] = <String, dynamic>{
              'kind': 'weekly',
              'weekdays': <int>[1, 1],
            })),
        isNull);
    expect(
        ScheduleEvent.tryParse(broken((j) => j['repeat'] = <String, dynamic>{
              'kind': 'daily',
              'weekdays': <int>[1],
            })),
        isNull);
    expect(
        ScheduleEvent.tryParse(broken((j) => j['repeat'] = <String, dynamic>{
              'kind': 'none',
              'untilDate': '2026-12-01',
            })),
        isNull);
    expect(
        ScheduleEvent.tryParse(broken((j) => j['exceptions'] = <dynamic>[
              <String, dynamic>{
                'key': 'other@2026-11-09',
                'excluded': true,
              },
            ])),
        isNull);
  });

  test('全天事件结束日排他且拒绝早于开始日', () {
    final json = _event(
      allDay: true,
      startDate: '2026-11-09',
      startMinute: null,
      endMinute: null,
      endDateExclusive: '2026-11-11',
    ).toJson();
    final parsed = ScheduleEvent.tryParse(json);
    expect(parsed!.endDateExclusive, '2026-11-11');
    final bad = Map<String, dynamic>.from(json)..['endDateExclusive'] = '2026-11-09';
    expect(ScheduleEvent.tryParse(bad), isNull);
  });

  test('草稿校验：定时/全天互斥、提醒类型、重复规则', () {
    ScheduleDraft draft({
      bool allDay = false,
      int? startMinute = 540,
      int? endMinute = 600,
      String? endDateExclusive,
      ScheduleReminderKind reminder = ScheduleReminderKind.none,
      ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
    }) =>
        ScheduleDraft(
          title: '写报告',
          timezoneId: 'Asia/Shanghai',
          startDate: '2026-11-09',
          allDay: allDay,
          startMinute: startMinute,
          endMinute: endMinute,
          endDateExclusive: endDateExclusive,
          reminder: reminder,
          repeat: repeat,
        );

    expect(draft().validate(), isNull);
    expect(draft(allDay: true, startMinute: null, endMinute: null,
            endDateExclusive: '2026-11-10', reminder: ScheduleReminderKind.allDaySameDay)
        .validate(), isNull);
    expect(draft(allDay: true).validate(), isNotNull);
    expect(draft(endMinute: 500).validate(), isNotNull);
    expect(draft(reminder: ScheduleReminderKind.dayBefore).validate(), isNull);
    expect(
        draft(
          allDay: true,
          startMinute: null,
          endMinute: null,
          endDateExclusive: '2026-11-10',
          reminder: ScheduleReminderKind.minutes15,
        ).validate(),
        isNotNull);
    expect(draft(repeat: const ScheduleRepeatRule.daily()).validate(), isNull);
    expect(
        draft(
          repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[3, 1]),
        ).validate(),
        isNull);
  });

  test('occurrenceKey 稳定且可解析原始日期', () {
    final key = scheduleOccurrenceKey('ev-9', '2026-11-16');
    expect(key, 'ev-9@2026-11-16');
    expect(isValidOccurrenceKey(key), isTrue);
    expect(originalDateOfOccurrenceKey(key), '2026-11-16');
    expect(eventIdOfOccurrenceKey(key), 'ev-9');
    expect(isValidOccurrenceKey('ev-9'), isFalse);
    expect(isValidOccurrenceKey('ev-9@not-a-date'), isFalse);
  });

  test('序列规则变化可找出不再匹配的例外（供确认，不默默删除）', () {
    final event = _event(
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
      exceptions: const <ScheduleException>[
        ScheduleException.excluded(occurrenceKey: 'ev-1@2026-11-11'), // 周三
        ScheduleException.excluded(occurrenceKey: 'ev-1@2026-11-09'), // 周一
      ],
    );
    expect(
      event.exceptionsNoLongerMatching(
        const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
      ),
      <String>['ev-1@2026-11-11'],
    );
    // 改成不重复后只剩 startDate 当天的实例，因此周一例外仍有意义，不列入
    // “不再匹配”（只有周三例外失效）。
    expect(
      event.exceptionsNoLongerMatching(const ScheduleRepeatRule.none()),
      <String>['ev-1@2026-11-11'],
    );
  });
}
