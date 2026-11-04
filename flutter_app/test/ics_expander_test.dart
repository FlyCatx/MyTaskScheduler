// 重复展开测试（T-C / ics-core）。
//
// 重要：下面所有期待日期都是**人工推导**写死的（按 RFC 5545 + IANA 时区规则），
// 没有用 rrule 或被测代码生成答案，否则测试只会验证“实现与实现一致”。
//
// 覆盖契约 3.5 的 I01–I07 与资源限制：中文/折叠/转义/多事件、UTC/TZID/VTIMEZONE/
// floating、全天/跨午夜/无结束/秒精度、America/New_York 与 Europe/Berlin 的 DST
// 缺失/重复小时（固定 2026 年日期，不随今天漂移）、每日/每周/每月/每年/BYSETPOS、
// EXDATE/RDATE/单次改期/单实例与整系列取消、部分失败/不支持规则/超限、同 UID
// 不同来源隔离。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_event_extractor.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_expander.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_parser.dart';

const String kTz = 'Asia/Shanghai';

const ExternalCalendarPolicy kPolicy = ExternalCalendarPolicy(
  floatingTimezoneId: kTz,
  floatingConfirmed: true,
);

const ExternalCalendarPolicy kUnconfirmedPolicy = ExternalCalendarPolicy();

String fixtureText(String name) =>
    File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}ics'
            '${Platform.pathSeparator}$name')
        .readAsStringSync();

String calendar(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n$body'
    'END:VCALENDAR\r\n';

String event({
  required String uid,
  required String lines,
}) =>
    'BEGIN:VEVENT\r\nUID:$uid\r\nDTSTAMP:20260101T000000Z\r\n$lines'
    'END:VEVENT\r\n';

class Harness {
  Harness(this.extract, this.expansion);

  final IcsExtractResult extract;
  final IcsExpansion expansion;

  List<ExternalBusyInstance> of(String uid) =>
      expansion.instances.where((i) => i.uid == uid).toList(growable: false);

  List<String> startsOf(String uid) => of(uid)
      .map((i) => i.startUtc.toIso8601String())
      .toList(growable: false);

  List<String> dayKeysOf(String uid) =>
      of(uid).map((i) => i.dayKey).toList(growable: false);

  List<int> minutesOf(String uid) => of(uid)
      .expand((i) => <int>[i.startMinute, i.endMinute])
      .toList(growable: false);

  List<String> warningCodesFor(String? uid) => expansion.warnings
      .where((w) => uid == null || w.uid == uid)
      .map((w) => w.code)
      .toList(growable: false);

  List<String> extractWarningCodes() =>
      extract.warnings.map((w) => w.code).toList(growable: false);
}

Harness run(
  String ics, {
  String timezoneId = kTz,
  ExternalCalendarPolicy policy = kPolicy,
  IcsLimits limits = const IcsLimits(),
  String from = '2026-03-01',
  String to = '2026-03-31',
  String sourceId = 'src-test',
}) {
  final parsed = parseIcs(ics);
  final extract = extractIcsEvents(
    parsed,
    sourceId: sourceId,
    timezoneId: timezoneId,
    policy: policy,
    limits: limits,
  );
  final zones = extract.zones;
  final fromDate = parseDateKeyUtc(from)!;
  final toDate = parseDateKeyUtc(to)!;
  final fromUtc = zones.wallToUtc(
      timezoneId, DateTime.utc(fromDate.year, fromDate.month, fromDate.day))!;
  final toUtc = zones.wallToUtc(
    timezoneId,
    DateTime.utc(toDate.year, toDate.month, toDate.day)
        .add(const Duration(days: 1)),
  )!;
  final expansion = expandIcsEvents(
    extract.events,
    fromUtc: fromUtc,
    toUtc: toUtc,
    zones: zones,
    policy: policy,
    limits: limits,
    sourceId: sourceId,
    planningTimezoneId: timezoneId,
  );
  return Harness(extract, expansion);
}

void main() {
  group('I01 中文/折叠/转义/多事件', () {
    test('两条事件都展开；摘要转义与折叠行正确', () {
      final harness = run(fixtureText('basic_cn.ics'));
      expect(harness.extract.events, hasLength(2));
      expect(harness.expansion.instances, hasLength(2));

      final first = harness.extract.events.first;
      expect(first.uid, 'basic-1@example.test');
      expect(first.summary, '团队周会; 讨论,计划与复盘');
      expect(first.startUtc, '2026-03-02T01:00:00.000Z');
      expect(first.endUtc, '2026-03-02T02:30:00.000Z');
      expect(first.startSecond, 9 * 3600);
      expect(first.endSecond, 10 * 3600 + 30 * 60);

      expect(harness.startsOf('basic-1@example.test'),
          <String>['2026-03-02T01:00:00.000Z']);
      expect(harness.dayKeysOf('basic-1@example.test'), <String>['2026-03-02']);
      expect(harness.minutesOf('basic-1@example.test'), <int>[540, 630]);

      expect(harness.startsOf('basic-2@example.test'),
          <String>['2026-03-03T01:00:00.000Z']);
      expect(harness.minutesOf('basic-2@example.test'), <int>[540, 600]);
    });

    test('VTODO/VALARM 只计数不导入', () {
      final harness = run(fixtureText('basic_cn.ics'));
      expect(harness.extract.componentCounts['VEVENT'], 2);
      expect(harness.extract.componentCounts['VTODO'], 1);
      expect(harness.extract.componentCounts['VALARM'], 1);
      expect(harness.extract.partialStats.ignoredComponents, 2);
      expect(harness.extractWarningCodes(), contains('ignored-components'));
      expect(harness.extract.partialStats.readEvents, 2);
    });
  });

  group('I02 UTC/TZID/VTIMEZONE/floating', () {
    test('四种时间形态都能落到正确的 UTC 时刻', () {
      final harness = run(fixtureText('timezones.ics'));
      expect(harness.extract.events, hasLength(4));
      expect(harness.extract.unsupportedUids, isEmpty);

      // UTC 事件：2026-03-02 01:00Z = 上海 09:00。
      expect(harness.startsOf('tz-utc@example.test'),
          <String>['2026-03-02T01:00:00.000Z']);
      expect(harness.minutesOf('tz-utc@example.test'), <int>[540, 600]);

      // IANA TZID：上海 2026-03-03 14:00 = 06:00Z。
      expect(harness.startsOf('tz-iana@example.test'),
          <String>['2026-03-03T06:00:00.000Z']);
      expect(harness.minutesOf('tz-iana@example.test'), <int>[840, 900]);

      // Windows 时区名（VTIMEZONE 只给固定 +0800）映射到 Asia/Shanghai。
      expect(harness.startsOf('tz-windows@example.test'),
          <String>['2026-03-04T01:00:00.000Z']);
      expect(harness.minutesOf('tz-windows@example.test'), <int>[540, 600]);

      // floating：按确认过的 Asia/Shanghai 解释，08:00 = 00:00Z。
      expect(harness.startsOf('tz-floating@example.test'),
          <String>['2026-03-05T00:00:00.000Z']);
      expect(harness.minutesOf('tz-floating@example.test'), <int>[480, 540]);
    });

    test('floating 未确认时不应用该事件（绝不猜默认时区）', () {
      final harness =
          run(fixtureText('timezones.ics'), policy: kUnconfirmedPolicy);
      expect(harness.extract.events, hasLength(3));
      expect(harness.extract.unsupportedUids, <String>['tz-floating@example.test']);
      expect(harness.extractWarningCodes(), contains('floating-unconfirmed'));
      expect(harness.of('tz-floating@example.test'), isEmpty);
      // 其余事件不受影响。
      expect(harness.startsOf('tz-utc@example.test'),
          <String>['2026-03-02T01:00:00.000Z']);
    });

    test('未知 TZID 记 warning 并拒绝事件，不会回退到 Asia/Shanghai', () {
      final ics = calendar(event(
        uid: 'unknown-tz@test',
        lines: 'DTSTART;TZID=Custom/Nowhere:20260302T090000\r\n'
            'DTEND;TZID=Custom/Nowhere:20260302T100000\r\n'
            'SUMMARY:未知时区\r\n',
      ));
      final harness = run(ics);
      expect(harness.extract.events, isEmpty);
      expect(harness.extract.unsupportedUids, <String>['unknown-tz@test']);
      expect(harness.extractWarningCodes(), contains('unknown-timezone'));
      expect(harness.expansion.instances, isEmpty);
    });
  });

  group('I03 全天/跨午夜/无结束/秒精度', () {
    test('全天、跨午夜拆段、无结束、秒精度与 DURATION', () {
      final harness = run(fixtureText('allday_midnight.ics'));

      // 全天：2026-03-05 00:00–24:00（上海），UTC 是前一天 16:00 起。
      final allDay = harness.extract.events
          .firstWhere((e) => e.uid == 'day-1@example.test');
      expect(allDay.allDay, isTrue);
      expect(allDay.startSecond, 0);
      expect(allDay.endSecond, 86400);
      expect(harness.startsOf('day-1@example.test'),
          <String>['2026-03-04T16:00:00.000Z']);
      expect(harness.dayKeysOf('day-1@example.test'), <String>['2026-03-05']);
      expect(harness.minutesOf('day-1@example.test'), <int>[0, 1440]);

      // 跨午夜：2026-03-06 23:30–03-07 00:30（上海）拆成两段。
      expect(harness.startsOf('night-1@example.test'), <String>[
        '2026-03-06T15:30:00.000Z',
        '2026-03-06T16:00:00.000Z',
      ]);
      expect(harness.dayKeysOf('night-1@example.test'),
          <String>['2026-03-06', '2026-03-07']);
      expect(harness.minutesOf('night-1@example.test'),
          <int>[1410, 1440, 0, 30]);

      // 只有 DTSTART 没有结束：RFC 的零时长标记，不占时间也不报错。
      final noEnd = harness.extract.events
          .firstWhere((e) => e.uid == 'noend-1@example.test');
      expect(noEnd.startUtc, noEnd.endUtc);
      expect(harness.of('noend-1@example.test'), isEmpty);

      // 秒精度：09:15:30–10:45:30 → 起点 floor 555、终点 ceil 646。
      final second = harness.extract.events
          .firstWhere((e) => e.uid == 'second-1@example.test');
      expect(second.startSecond, 33330);
      expect(second.endSecond, 38730);
      expect(harness.startsOf('second-1@example.test'),
          <String>['2026-03-09T01:15:30.000Z']);
      expect(harness.minutesOf('second-1@example.test'), <int>[555, 646]);

      // DURATION:PT45M 的结束时间。
      expect(harness.startsOf('duration-1@example.test'),
          <String>['2026-03-10T06:00:00.000Z']);
      expect(harness.minutesOf('duration-1@example.test'), <int>[840, 885]);

      // 总占用分钟：1440（全天）+ 60（跨午夜）+ 90（秒精度）+ 45 = 1635。
      expect(harness.expansion.stats.busyMinutes, 1635);
      expect(harness.expansion.stats.expandedInstances, 4);
    });
  });

  group('I04 DST 缺失/重复小时（America/New_York / Europe/Berlin）', () {
    test('DST 切换前后的偏移正确，缺失/重复小时拒绝并 warning', () {
      final harness = run(
        fixtureText('dst.ics'),
        from: '2026-03-01',
        to: '2026-12-01',
        limits: const IcsLimits(maxRangeDays: 600),
      );

      // 2026-03-07 09:00 EST(-5) = 14:00Z；2026-03-09 09:00 EDT(-4) = 13:00Z。
      expect(harness.startsOf('dst-ny-before@example.test'),
          <String>['2026-03-07T14:00:00.000Z']);
      expect(harness.startsOf('dst-ny-after@example.test'),
          <String>['2026-03-09T13:00:00.000Z']);

      // 单次事件的 DTSTART 本身落在 DST 边界：提取阶段就拒绝该事件并 warning
      // （不猜是哪一次/不存在的时间），三条都不得产生实例。
      expect(harness.extractWarningCodes(), containsAll(<String>[
        'dst-gap',
        'dst-ambiguous',
      ]));
      expect(harness.extract.unsupportedUids, containsAll(<String>[
        'dst-ny-gap@example.test',
        'dst-ny-ambiguous@example.test',
        'dst-berlin-ambiguous@example.test',
      ]));
      expect(harness.of('dst-ny-gap@example.test'), isEmpty);
      expect(harness.of('dst-ny-ambiguous@example.test'), isEmpty);
      expect(harness.of('dst-berlin-ambiguous@example.test'), isEmpty);

      expect(harness.expansion.instances, hasLength(2));
    });

    test('RRULE 生成的某个实例落在 DST 缺失/重复小时：只跳过该实例', () {
      // 每天 02:30（纽约）：3/7 02:30 EST = 07:30Z；
      // 3/8 02:30 不存在（前跳）→ 跳过并 warning；
      // 3/9 02:30 EDT = 06:30Z。
      final gapIcs = calendar(event(
        uid: 'gap-instance@test',
        lines: 'DTSTART;TZID=America/New_York:20260307T023000\r\n'
            'DTEND;TZID=America/New_York:20260307T033000\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\n'
            'SUMMARY:每天凌晨两个半\r\n',
      ));
      final gap = run(gapIcs,
          timezoneId: 'America/New_York', from: '2026-03-01', to: '2026-03-31');
      expect(gap.startsOf('gap-instance@test'), <String>[
        '2026-03-07T07:30:00.000Z',
        '2026-03-09T06:30:00.000Z',
      ]);
      expect(gap.warningCodesFor('gap-instance@test'), contains('dst-gap'));

      // 每天 01:30（纽约）：10/31 01:30 EDT = 05:30Z；
      // 11/1 01:30 出现两次 → 跳过并 warning；11/2 01:30 EST = 06:30Z。
      final ambiguousIcs = calendar(event(
        uid: 'ambiguous-instance@test',
        lines: 'DTSTART;TZID=America/New_York:20261031T013000\r\n'
            'DTEND;TZID=America/New_York:20261031T023000\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\n'
            'SUMMARY:每天凌晨一个半\r\n',
      ));
      final ambiguous = run(ambiguousIcs,
          timezoneId: 'America/New_York',
          from: '2026-10-01',
          to: '2026-11-15');
      expect(ambiguous.startsOf('ambiguous-instance@test'), <String>[
        '2026-10-31T05:30:00.000Z',
        '2026-11-02T06:30:00.000Z',
      ]);
      expect(ambiguous.warningCodesFor('ambiguous-instance@test'),
          contains('dst-ambiguous'));
    });

    test('RRULE 按源墙上时间展开：跨 DST 每天 09:00 本地不变', () {
      // 2026-03-07 09:00 EST = 14:00Z；03-08 09:00 EDT = 13:00Z；
      // 03-09 09:00 EDT = 13:00Z。若按“每 24 小时”展开会得到错误的 14:00Z。
      final ics = calendar(event(
        uid: 'wall-daily@test',
        lines: 'DTSTART;TZID=America/New_York:20260307T090000\r\n'
            'DTEND;TZID=America/New_York:20260307T100000\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\n'
            'SUMMARY:跨 DST 的每日会议\r\n',
      ));
      final harness = run(
        ics,
        timezoneId: 'America/New_York',
        from: '2026-03-01',
        to: '2026-03-31',
      );
      expect(harness.startsOf('wall-daily@test'), <String>[
        '2026-03-07T14:00:00.000Z',
        '2026-03-08T13:00:00.000Z',
        '2026-03-09T13:00:00.000Z',
      ]);
      // 规划时区是纽约，所以三天的分钟数都是 540–600。
      expect(harness.dayKeysOf('wall-daily@test'),
          <String>['2026-03-07', '2026-03-08', '2026-03-09']);
      expect(harness.minutesOf('wall-daily@test'), <int>[540, 600, 540, 600, 540, 600]);
    });
  });

  group('I05 每日/每周/每月/每年 + BYSETPOS', () {
    test('手工推导的展开日期与次数', () {
      final harness = run(
        fixtureText('recurrence.ics'),
        from: '2026-01-01',
        to: '2027-04-01',
        limits: const IcsLimits(maxRangeDays: 600),
      );
      expect(harness.expansion.instances, hasLength(24));

      // FREQ=DAILY;COUNT=3，上海 09:00 = 01:00Z。
      expect(harness.startsOf('rec-daily@example.test'), <String>[
        '2026-03-02T01:00:00.000Z',
        '2026-03-03T01:00:00.000Z',
        '2026-03-04T01:00:00.000Z',
      ]);

      // FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=4：3/2 一、3/4 三、3/6 五、3/9 一。
      expect(harness.dayKeysOf('rec-weekly@example.test'),
          <String>['2026-03-02', '2026-03-04', '2026-03-06', '2026-03-09']);

      // FREQ=MONTHLY;BYDAY=1MO;COUNT=3：3/2、4/6、5/4（都是当月第一个周一）。
      expect(harness.dayKeysOf('rec-monthly@example.test'),
          <String>['2026-03-02', '2026-04-06', '2026-05-04']);

      // FREQ=YEARLY;COUNT=2：2026-03-02、2027-03-02。
      expect(harness.dayKeysOf('rec-yearly@example.test'),
          <String>['2026-03-02', '2027-03-02']);

      // 每月最后一个工作日（BYDAY=MO..FR;BYSETPOS=-1）：
      // 2026-01-30 周五、2026-02-27 周五、2026-03-31 周二。
      expect(harness.dayKeysOf('rec-last-weekday@example.test'),
          <String>['2026-01-30', '2026-02-27', '2026-03-31']);

      // INTERVAL=2 的每周：3/2、3/16、3/30。
      expect(harness.dayKeysOf('rec-biweekly@example.test'),
          <String>['2026-03-02', '2026-03-16', '2026-03-30']);

      // UNTIL 用 UTC：上海 20:00 = 12:00Z，UNTIL=20260304T120000Z 含当天。
      expect(harness.startsOf('rec-until-utc@example.test'), <String>[
        '2026-03-02T12:00:00.000Z',
        '2026-03-03T12:00:00.000Z',
        '2026-03-04T12:00:00.000Z',
      ]);

      // 纯日期 UNTIL 的全天事件：3/5、3/6、3/7（含 UNTIL 当天）。
      expect(harness.dayKeysOf('rec-allday-until@example.test'),
          <String>['2026-03-05', '2026-03-06', '2026-03-07']);
      expect(harness.minutesOf('rec-allday-until@example.test'),
          <int>[0, 1440, 0, 1440, 0, 1440]);
    });
  });

  group('I06 EXDATE/RDATE/单次改期/取消', () {
    test('取消、改期、排除与追加都按 RFC 语义生效', () {
      final harness = run(fixtureText('exceptions.ics'));

      // 原始 4 次：3/2、3/9、3/16、3/23。
      // 3/9 改到 3/10 14:00；3/16 被 EXDATE 排除；3/23 单实例取消；
      // RDATE 追加 3/11 09:00。
      expect(harness.startsOf('ex-1@example.test'), <String>[
        '2026-03-02T01:00:00.000Z',
        '2026-03-10T06:00:00.000Z',
        '2026-03-11T01:00:00.000Z',
      ]);
      expect(harness.extract.events
              .firstWhere((e) => e.rrule != null)
              .rrule,
          'FREQ=WEEKLY;COUNT=4');

      // 整系列取消：一条实例都不展开。
      expect(harness.of('ex-2@example.test'), isEmpty);
      expect(harness.expansion.instances, hasLength(3));

      // 取消事件计数：ex-2 系列 + ex-1 的单实例取消。
      expect(harness.expansion.stats.cancelledEvents, 2);
    });

    test('EXDATE 用 UTC 形式同样生效', () {
      final ics = calendar(event(
        uid: 'ex-utc@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260302T090000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260302T100000\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\n'
            'EXDATE:20260303T010000Z\r\n'
            'SUMMARY:UTC EXDATE\r\n',
      ));
      final harness = run(ics);
      // 3/2 09:00、3/3 09:00（=03-03T01:00Z，被排除）、3/4 09:00。
      expect(harness.startsOf('ex-utc@test'), <String>[
        '2026-03-02T01:00:00.000Z',
        '2026-03-04T01:00:00.000Z',
      ]);
    });

    test('全天系列的纯日期 EXDATE 生效', () {
      final ics = calendar(event(
        uid: 'allday-ex@test',
        lines: 'DTSTART;VALUE=DATE:20260305\r\n'
            'RRULE:FREQ=DAILY;COUNT=3\r\n'
            'EXDATE;VALUE=DATE:20260306\r\n'
            'SUMMARY:全天排除一天\r\n',
      ));
      final harness = run(ics);
      expect(harness.dayKeysOf('allday-ex@test'),
          <String>['2026-03-05', '2026-03-07']);
    });

    test('定时事件的纯日期 EXDATE 属于 RFC 违规：保留占用并 warning', () {
      final ics = calendar(event(
        uid: 'mismatch-ex@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260302T090000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260302T100000\r\n'
            'RRULE:FREQ=DAILY;COUNT=2\r\n'
            'EXDATE;VALUE=DATE:20260303\r\n'
            'SUMMARY:类型不匹配\r\n',
      ));
      final harness = run(ics);
      expect(harness.startsOf('mismatch-ex@test'), <String>[
        '2026-03-02T01:00:00.000Z',
        '2026-03-03T01:00:00.000Z',
      ]);
      expect(harness.extractWarningCodes(), contains('date-type-mismatch'));
    });
  });

  group('I07 部分失败/不支持规则/超限', () {
    test('不支持的事件被拒绝并 warning，其余事件照常导入', () {
      final harness = run(
        fixtureText('partial_unsupported.ics'),
        policy: kUnconfirmedPolicy,
      );

      // RANGE=THISANDFUTURE 的系列被整体拒绝；未知时区、未知 RRULE 参数、
      // WKST=SU、未确认 floating 都被拒绝。
      expect(harness.extract.unsupportedUids, <String>[
        'bad-rule@example.test',
        'bad-wkst@example.test',
        'float-1@example.test',
        'range-1@example.test',
        'unk-tz@example.test',
      ]);
      expect(harness.extract.events, hasLength(2));
      expect(harness.extract.partialStats.readEvents, 8);
      expect(harness.extract.partialStats.unsupportedCount, 5);
      expect(harness.extract.partialStats.ignoredComponents, 3);
      expect(harness.extractWarningCodes(), containsAll(<String>[
        'unsupported-recurrence-range',
        'unknown-timezone',
        'unsupported-rrule-part',
        'unsupported-rrule',
        'floating-unconfirmed',
      ]));

      // 透明事件与暂定事件都保留为“实例”，但 busy/tentative 标记不同。
      final transparent = harness
          .of('trans-1@example.test')
          .single;
      expect(transparent.busy, isFalse);
      expect(transparent.tentative, isFalse);
      final tentative = harness.of('tent-1@example.test').single;
      expect(tentative.busy, isTrue, reason: '默认策略：暂定也算占用');
      expect(tentative.tentative, isTrue);
    });

    test('busyPolicy 三档对透明/暂定的处理不同', () {
      final opaqueOnly = run(
        fixtureText('partial_unsupported.ics'),
        policy: const ExternalCalendarPolicy(
            busyPolicy: ExternalBusyPolicy.opaqueOnly),
      );
      expect(opaqueOnly.of('trans-1@example.test').single.busy, isFalse);
      expect(opaqueOnly.of('tent-1@example.test').single.busy, isFalse);

      final allBusy = run(
        fixtureText('partial_unsupported.ics'),
        policy: const ExternalCalendarPolicy(
            busyPolicy: ExternalBusyPolicy.allCountsAsBusy),
      );
      expect(allBusy.of('trans-1@example.test').single.busy, isTrue);
      expect(allBusy.of('tent-1@example.test').single.busy, isTrue);
    });

    test('maxEvents：超出上限明确 warning，不假装导入完整', () {
      final harness = run(
        fixtureText('basic_cn.ics'),
        limits: const IcsLimits(maxEvents: 1),
      );
      expect(harness.extract.partialStats.readEvents, 2);
      expect(harness.extract.events, hasLength(1));
      expect(harness.extractWarningCodes(), contains('event-limit'));
    });

    test('maxInstances：截断时 truncated=true 且 warning', () {
      final ics = calendar(event(
        uid: 'many@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260302T090000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260302T100000\r\n'
            'RRULE:FREQ=DAILY;COUNT=10\r\n'
            'SUMMARY:很多次\r\n',
      ));
      final harness = run(ics, limits: const IcsLimits(maxInstances: 3));
      expect(harness.expansion.truncated, isTrue);
      expect(harness.expansion.instances, hasLength(3));
      expect(harness.warningCodesFor(null), contains('instance-limit'));
    });

    test('maxRangeDays：范围被截断时 truncated=true 且 warning', () {
      final ics = calendar(event(
        uid: 'range@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260302T090000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260302T100000\r\n'
            'SUMMARY:范围限流\r\n',
      ));
      final harness = run(
        ics,
        from: '2026-03-01',
        to: '2026-03-31',
        limits: const IcsLimits(maxRangeDays: 2),
      );
      expect(harness.expansion.truncated, isTrue);
      expect(harness.warningCodesFor(null), contains('range-clamped'));
      // 3/2 仍在被允许的前 2 天内。
      expect(harness.expansion.instances, hasLength(1));
    });
  });

  group('U01 同 UID 不同来源互不影响', () {
    test('两个来源的同 UID 事件各自展开，sourceId 不混淆', () {
      final harnessA =
          run(fixtureText('idempotent_a.ics'), sourceId: 'ext-aaaaaaaaaaaa');
      final harnessB =
          run(fixtureText('idempotent_b.ics'), sourceId: 'ext-bbbbbbbbbbbb');
      expect(harnessA.startsOf('shared-1@example.test'),
          <String>['2026-03-02T01:00:00.000Z']);
      expect(harnessB.startsOf('shared-1@example.test'),
          <String>['2026-03-02T07:00:00.000Z']);
      expect(harnessA.of('shared-1@example.test').single.sourceId,
          'ext-aaaaaaaaaaaa');
      expect(harnessB.of('shared-1@example.test').single.sourceId,
          'ext-bbbbbbbbbbbb');
    });
  });

  group('展开边界与健壮性', () {
    test('范围把跨边界事件裁剪到范围端点', () {
      // 事件 2026-02-28 23:00 – 03-01 02:00（上海）；范围从 03-01 00:00 起。
      final ics = calendar(event(
        uid: 'clip@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260228T230000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260301T020000\r\n'
            'SUMMARY:跨范围边界\r\n',
      ));
      final harness = run(ics);
      expect(harness.dayKeysOf('clip@test'), <String>['2026-03-01']);
      expect(harness.minutesOf('clip@test'), <int>[0, 120]);
      expect(harness.startsOf('clip@test'),
          <String>['2026-02-28T16:00:00.000Z']);
    });

    test('结束早于开始的事件被拒绝而不是产生负区间', () {
      final ics = calendar(event(
        uid: 'bad-end@test',
        lines: 'DTSTART;TZID=Asia/Shanghai:20260302T100000\r\n'
            'DTEND;TZID=Asia/Shanghai:20260302T090000\r\n'
            'SUMMARY:坏区间\r\n',
      ));
      final harness = run(ics);
      expect(harness.extract.events, isEmpty);
      expect(harness.extractWarningCodes(), contains('end-before-start'));
    });
  });
}
