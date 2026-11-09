// 日程重叠检测（任务 11.6）单测：实际重叠分钟、首尾相接=0、编辑自身排除、
// 全天/关闭占用日程不参与、跨半夜实例按同一对象合并。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_conflicts.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';

DateTime _utc(String date, int minute) {
  final key = dateKeyToUtc(date)!;
  final wall = DateTime.utc(
    key.year,
    key.month,
    key.day + minute ~/ 1440,
    (minute % 1440) ~/ 60,
    minute % 60,
  );
  return IcsTimeZoneResolver().resolveWall('Asia/Shanghai', wall).utc!;
}

ScheduleOccurrence _occ({
  required String eventId,
  required String date,
  required int start,
  required int end,
  String? title,
  bool allDay = false,
  bool blocks = true,
  String? startDate,
  String? endDateExclusive,
}) {
  return ScheduleOccurrence(
    eventId: eventId,
    occurrenceKey: scheduleOccurrenceKey(eventId, date),
    originalDate: date,
    title: title ?? eventId,
    timezoneId: 'Asia/Shanghai',
    allDay: allDay,
    blocksScheduling: blocks,
    reminder: ScheduleReminderKind.none,
    startUtc: allDay ? null : _utc(date, start),
    endUtc: allDay ? null : _utc(date, end),
    startDate: startDate,
    endDateExclusive: endDateExclusive,
  );
}

void main() {
  setUpAll(IcsTimeZoneResolver.ensureDatabase);

  test('部分重叠按实际分钟数统计（30 分钟）', () {
    final overlaps = findScheduleOverlaps(
      startUtc: _utc('2026-11-09', 14 * 60 + 30),
      endUtc: _utc('2026-11-09', 15 * 60 + 30),
      candidates: <ScheduleOccurrence>[
        _occ(
          eventId: 'ev-a',
          date: '2026-11-09',
          start: 14 * 60,
          end: 15 * 60,
          title: '前端页面开发',
        ),
      ],
    );
    expect(overlaps, hasLength(1));
    expect(overlaps.single.overlapMinutes, 30);
    expect(overlaps.single.title, '前端页面开发');
    expect(overlaps.single.overlapStartUtc, _utc('2026-11-09', 14 * 60 + 30));
    expect(overlaps.single.overlapEndUtc, _utc('2026-11-09', 15 * 60));
  });

  test('刚好首尾相接重叠为 0 分钟，不算冲突', () {
    final overlaps = findScheduleOverlaps(
      startUtc: _utc('2026-11-09', 15 * 60),
      endUtc: _utc('2026-11-09', 16 * 60),
      candidates: <ScheduleOccurrence>[
        _occ(eventId: 'ev-a', date: '2026-11-09', start: 14 * 60, end: 15 * 60),
      ],
    );
    expect(overlaps, isEmpty);
  });

  test('完全包含时取被包含区间分钟数', () {
    final overlaps = findScheduleOverlaps(
      startUtc: _utc('2026-11-09', 13 * 60),
      endUtc: _utc('2026-11-09', 17 * 60),
      candidates: <ScheduleOccurrence>[
        _occ(eventId: 'ev-a', date: '2026-11-09', start: 14 * 60, end: 15 * 60),
      ],
    );
    expect(overlaps.single.overlapMinutes, 60);
  });

  test('编辑自身时排除原记录：系列排除整个事件，单次只排除本次实例', () {
    final target = _occ(
      eventId: 'ev-a',
      date: '2026-11-09',
      start: 14 * 60,
      end: 15 * 60,
    );
    final ownSeries = _occ(
      eventId: 'ev-a',
      date: '2026-11-16',
      start: 14 * 60,
      end: 15 * 60,
    );
    final other = _occ(
      eventId: 'ev-b',
      date: '2026-11-09',
      start: 14 * 60 + 30,
      end: 15 * 60 + 30,
    );
    final candidates = <ScheduleOccurrence>[target, ownSeries, other];

    final series = findScheduleOverlaps(
      startUtc: target.startUtc!,
      endUtc: target.endUtc!,
      candidates: candidates,
      excludeEventId: 'ev-a',
    );
    expect(series.map((o) => o.eventId), <String>['ev-b']);

    final single = findScheduleOverlaps(
      startUtc: target.startUtc!,
      endUtc: target.endUtc!,
      candidates: candidates,
      excludeOccurrenceKey: target.occurrenceKey,
    );
    expect(single.map((o) => o.eventId), <String>['ev-b']);
    expect(
      single.where((o) => o.occurrenceKey == target.occurrenceKey),
      isEmpty,
    );
  });

  test('全天与关闭占用的日程不参与排程冲突', () {
    final overlaps = findScheduleOverlaps(
      startUtc: _utc('2026-11-09', 14 * 60),
      endUtc: _utc('2026-11-09', 15 * 60),
      candidates: <ScheduleOccurrence>[
        _occ(
          eventId: 'ev-allday',
          date: '2026-11-09',
          start: 0,
          end: 0,
          allDay: true,
          startDate: '2026-11-09',
          endDateExclusive: '2026-11-10',
        ),
        _occ(
          eventId: 'ev-free',
          date: '2026-11-09',
          start: 14 * 60,
          end: 15 * 60,
          blocks: false,
        ),
      ],
    );
    expect(overlaps, isEmpty);
    // 本日程自己不占用排程时也不产生冲突。
    expect(
      findScheduleOverlaps(
        startUtc: _utc('2026-11-09', 14 * 60),
        endUtc: _utc('2026-11-09', 15 * 60),
        candidates: <ScheduleOccurrence>[
          _occ(
            eventId: 'ev-b',
            date: '2026-11-09',
            start: 14 * 60,
            end: 15 * 60,
          ),
        ],
        blocksScheduling: false,
      ),
      isEmpty,
    );
  });

  test('跨半夜实例按同一对象合并分钟数', () {
    // 23:00–次日 01:00 的同一个实例在两天列各产生一段重叠，合并回同一条冲突。
    final occurrence = _occ(
      eventId: 'ev-night',
      date: '2026-11-09',
      start: 23 * 60,
      end: 24 * 60 + 60,
    );
    final merged = mergeOverlapsByOccurrence(<ScheduleOverlap>[
      ScheduleOverlap(
        occurrence: occurrence,
        overlapStartUtc: _utc('2026-11-09', 23 * 60 + 30),
        overlapEndUtc: _utc('2026-11-10', 0),
        overlapMinutes: 30,
      ),
      ScheduleOverlap(
        occurrence: occurrence,
        overlapStartUtc: _utc('2026-11-10', 0),
        overlapEndUtc: _utc('2026-11-10', 0).add(const Duration(minutes: 30)),
        overlapMinutes: 30,
      ),
    ]);
    expect(merged, hasLength(1));
    expect(merged.single.overlapMinutes, 60);
    expect(merged.single.occurrenceKey, occurrence.occurrenceKey);
  });
}
