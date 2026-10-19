// Calendar constraints proposed by the model (0.07).
//
// What these tests protect:
//   * the model answer is *validated* (kind, ranges, weekdays, date, evidence) and a bad
//     answer fails loudly instead of turning into "everything is available";
//   * a course ("周二/周四 8-10 上课") is an occupancy and never a weekly availability;
//   * "中午和晚上各吃饭半小时" (duration only, no start) becomes a question, never a
//     guessed 12:00 block;
//   * proposals are candidates: nothing is applied until a tick, and applying twice does
//     not duplicate what is already confirmed;
//   * the fixed material example from the acceptance list classifies as required.

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/calendar_proposals.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/calendar_constraints.dart';

/// The acceptance material, as the model is expected to return it.
///
/// Current date 2026-10-19, Asia/Shanghai:
///   每天8:00—24:00可工作；每周二和周四08-10上课；2026-10-21 14:00-16:00参加活动；
///   2026-10-22全天不可用；中午和晚上各吃饭30分钟
Map<String, dynamic> acceptancePayload() => <String, dynamic>{
      'schemaVersion': 1,
      'summary': '识别到可工作时间、上课、活动、一个不可用日期与两段用餐时长',
      'proposals': [
        {
          'kind': 'availability',
          'title': '可工作',
          'occupancyKind': null,
          'weekdays': [1, 2, 3, 4, 5, 6, 7],
          'date': null,
          'closed': false,
          'ranges': [
            {'start': 480, 'end': 1440},
          ],
          'durationMinutes': null,
          'evidence': '每天8：00—24：00可工作',
          'source': '材料1:第1段',
          'needsTime': false,
          'question': null,
        },
        {
          'kind': 'occupancy',
          'title': '上课',
          'occupancyKind': 'course',
          'weekdays': [2, 4],
          'date': null,
          'closed': false,
          'ranges': [
            {'start': 480, 'end': 600},
          ],
          'durationMinutes': null,
          'evidence': '每周二和周四08-10上课',
          'source': '材料1:第1段',
          'needsTime': false,
          'question': null,
        },
        {
          'kind': 'occupancy',
          'title': '参加活动',
          'occupancyKind': 'activity',
          'weekdays': <int>[],
          'date': '2026-10-21',
          'closed': false,
          'ranges': [
            {'start': 840, 'end': 960},
          ],
          'durationMinutes': null,
          'evidence': '2026-10-21 14:00-16:00参加活动',
          'source': '材料1:第1段',
          'needsTime': false,
          'question': null,
        },
        {
          'kind': 'exception',
          'title': '全天不可用',
          'occupancyKind': null,
          'weekdays': <int>[],
          'date': '2026-10-22',
          'closed': true,
          'ranges': <Map<String, int>>[],
          'durationMinutes': null,
          'evidence': '2026-10-22全天不可用',
          'source': '材料1:第1段',
          'needsTime': false,
          'question': null,
        },
        {
          'kind': 'occupancy',
          'title': '午饭',
          'occupancyKind': 'rest',
          'weekdays': [1, 2, 3, 4, 5, 6, 7],
          'date': null,
          'closed': false,
          'ranges': <Map<String, int>>[],
          'durationMinutes': 30,
          'evidence': '中午和晚上各吃饭30分钟',
          'source': '材料1:第1段',
          'needsTime': true,
          'question': '「吃饭」只知道 30 分钟，请补充具体起止时间',
        },
        {
          'kind': 'occupancy',
          'title': '晚饭',
          'occupancyKind': 'rest',
          'weekdays': [1, 2, 3, 4, 5, 6, 7],
          'date': null,
          'closed': false,
          'ranges': <Map<String, int>>[],
          'durationMinutes': 30,
          'evidence': '中午和晚上各吃饭30分钟',
          'source': '材料1:第1段',
          'needsTime': true,
          'question': '「吃饭」只知道 30 分钟，请补充具体起止时间',
        },
      ],
      'notes': <String>['中午和晚上各吃饭30分钟：只给了时长，没有给起点'],
    };

ProposalDecodeResult decode(Map<String, dynamic> payload,
        {String signature = 'sig-1'}) =>
    decodeCalendarProposals(
      payload,
      materialSignature: signature,
      now: DateTime.utc(2026, 10, 19, 2),
      thinkingEnabled: true,
      thinkingEffort: 'high',
      protocol: 'deepseek-chat',
    );

void main() {
  group('解析固定验收材料', () {
    test('四类提案分别归类，用餐只给时长', () {
      final result = decode(acceptancePayload());
      expect(result.ok, isTrue, reason: result.error);
      final set = result.set!;

      final availability =
          set.proposals.where((p) => p.kind == CalendarProposalKind.availability);
      expect(availability.length, 1);
      expect(availability.single.weekdays.length, 7,
          reason: '“每天”必须展开成 7 个星期');
      expect(availability.single.ranges.single.endMinute, 1440);

      final courses = set.proposals.where(
          (p) => p.kind == CalendarProposalKind.occupancy && p.occupancyKind == 'course');
      expect(courses.length, 1);
      expect(courses.single.weekdays, <int>[2, 4],
          reason: '周二和周四必须保留为两条星期规则');
      expect(courses.single.weekdayLabel, '周二、周四');
      expect(courses.single.isApplicable, isTrue);

      final exceptions =
          set.proposals.where((p) => p.kind == CalendarProposalKind.exception);
      expect(exceptions.single.date, '2026-10-22');
      expect(exceptions.single.closed, isTrue);

      final rests = set.proposals.where((p) => p.occupancyKind == 'rest').toList();
      expect(rests.length, 2, reason: '中午与晚上是两条约束');
      for (final rest in rests) {
        expect(rest.durationMinutes, 30);
        expect(rest.ranges, isEmpty);
        expect(rest.needsTime, isTrue);
        expect(rest.isApplicable, isFalse,
            reason: '只知道时长的候选不能直接应用（不能把猜出的时刻当事实）');
      }
    });

    test('课程不会被当成每周可工作时间', () {
      final set = decode(acceptancePayload()).set!;
      final availability = set.proposals
          .where((p) => p.kind == CalendarProposalKind.availability)
          .toList();
      for (final p in availability) {
        expect(p.occupancyKind, 'activity',
            reason: 'availability 提案不带占用类型');
        expect(p.title, '可工作');
      }
      // 上课只出现在 occupancy 里。
      final courseTitles = set.proposals
          .where((p) => p.kind == CalendarProposalKind.occupancy)
          .map((p) => p.title)
          .toList();
      expect(courseTitles, contains('上课'));
    });

    test('待确认说明去重（同一句只出现一次）', () {
      final set = decode(acceptancePayload()).set!;
      final notes = set.notes;
      expect(notes.length, notes.toSet().length);
      // 两条用餐候选共享同一句 question，只能出现一次。
      expect(
          notes.where((n) => n.contains('只知道 30 分钟')).length, 1);
    });

    test('本次思考配置如实记录，不冒充全局设置', () {
      final set = decode(acceptancePayload()).set!;
      expect(set.thinkingEnabled, isTrue);
      expect(set.thinkingEffort, 'high');
      expect(set.thinkingLabel, contains('思考'));
    });

    test('提案 ID 稳定：同内容同 ID，不同星期不同 ID', () {
      final a = decode(acceptancePayload()).set!;
      final b = decode(acceptancePayload()).set!;
      expect(a.proposals.map((p) => p.id).toList(),
          b.proposals.map((p) => p.id).toList());

      final course = a.proposals
          .firstWhere((p) => p.title == '上课' && p.isApplicable);
      final shifted = CalendarProposal(
        id: '',
        kind: course.kind,
        title: course.title,
        occupancyKind: course.occupancyKind,
        weekdays: const <int>[3],
        ranges: course.ranges,
        evidence: course.evidence,
        source: course.source,
      );
      final rebuilt = calendarProposalId(
        kind: shifted.kind,
        title: shifted.title,
        weekdays: shifted.weekdays,
        date: null,
        ranges: shifted.ranges,
        occupancyKind: shifted.occupancyKind,
      );
      expect(rebuilt, isNot(course.id),
          reason: '相同文本在不同星期不是同一条规则');
    });
  });

  group('校验失败必须报错，不能降级', () {
    ProposalDecodeResult decodeOne(Map<String, dynamic> proposal) =>
        decode(<String, dynamic>{
          'schemaVersion': 1,
          'proposals': [proposal],
          'notes': <String>[],
        });

    Map<String, dynamic> base() => <String, dynamic>{
          'kind': 'occupancy',
          'title': '上课',
          'occupancyKind': 'course',
          'weekdays': [2],
          'date': null,
          'closed': false,
          'ranges': [
            {'start': 480, 'end': 600},
          ],
          'durationMinutes': null,
          'evidence': '周二 8-10 上课',
          'source': '文件1:第2段',
          'needsTime': false,
          'question': null,
        };

    test('未知类型被丢弃并报告', () {
      final result = decodeOne(base()..['kind'] = 'holiday');
      expect(result.ok, isTrue);
      expect(result.set!.proposals, isEmpty);
      expect(result.rejected.single, contains('未知类型'));
    });

    test('没有原文依据的提案被丢弃', () {
      final result = decodeOne(base()..['evidence'] = '  ');
      expect(result.set!.proposals, isEmpty);
      expect(result.rejected.single, contains('没有原文依据'));
    });

    test('非法时段被丢弃（0 <= start < end <= 2880）', () {
      for (final ranges in <List<Map<String, int>>>[
        [
          {'start': 600, 'end': 480},
        ],
        [
          {'start': -5, 'end': 600},
        ],
        [
          {'start': 480, 'end': 4000},
        ],
      ]) {
        final result = decodeOne(base()..['ranges'] = ranges);
        expect(result.set!.proposals, isEmpty, reason: '$ranges');
        expect(result.rejected.single, contains('不合法'));
      }
    });

    test('非法星期与日期被丢弃', () {
      expect(decodeOne(base()..['weekdays'] = [9]).rejected.single,
          contains('不是 1–7'));
      expect(decodeOne(base()..['date'] = '2026-13-40').rejected.single,
          contains('yyyy-MM-dd'));
    });

    test('既无时段也无时长的提案被丢弃', () {
      final proposal = base()..['ranges'] = <Map<String, int>>[];
      final result = decodeOne(proposal);
      expect(result.set!.proposals, isEmpty);
      expect(result.rejected.single, contains('既没有时段'));
    });

    test('日期例外必须给出具体日期', () {
      final proposal = base()
        ..['kind'] = 'exception'
        ..['closed'] = true
        ..['ranges'] = <Map<String, int>>[]
        ..['date'] = null;
      final result = decodeOne(proposal);
      expect(result.set!.proposals, isEmpty);
      expect(result.rejected.single, contains('必须给出具体日期'));
    });

    test('缺少 proposals 数组是整体失败，不是空结果', () {
      final result = decode(<String, dynamic>{'notes': <String>[]});
      expect(result.ok, isFalse);
      expect(result.error, contains('proposals'));
    });

    test('模型未注明来源时保留提案并标注占位来源', () {
      final result = decodeOne(base()..['source'] = '');
      final p = result.set!.proposals.single;
      expect(p.source, contains('未注明来源'));
    });
  });

  group('应用：默认不勾选，确认后写入且去重', () {
    AppliedProposals apply({
      required Iterable<CalendarProposal> accepted,
      Map<int, List<WallClockRange>>? weekly,
      List<CalendarDateException>? exceptions,
      List<CalendarOccupancy>? occupancies,
      List<String>? notes,
    }) =>
        applyAcceptedProposals(
          accepted: accepted,
          weekly: weekly ?? <int, List<WallClockRange>>{},
          exceptions: exceptions ?? <CalendarDateException>[],
          occupancies: occupancies ?? <CalendarOccupancy>[],
          pendingNotes: notes ?? <String>[],
          idPrefix: 'p1',
        );

    test('未勾选时什么都不写', () {
      final set = decode(acceptancePayload()).set!;
      final applied = apply(accepted: const <CalendarProposal>[]);
      expect(applied.weekly, isEmpty);
      expect(applied.exceptions, isEmpty);
      expect(applied.occupancies, isEmpty);
      expect(applied.applied, 0);
      // 候选本身没有被应用，只是存在于候选集里。
      // 可勾选的是：可用时间、上课、活动、不可用日期（4 条）；两条只给时长的用餐
      // 候选需要用户先补时间，因此不在此列。
      expect(set.applicableCount, 4);
    });

    test('勾选可用时间后按星期写入 weekly', () {
      final set = decode(acceptancePayload()).set!;
      final availability = set.proposals
          .firstWhere((p) => p.kind == CalendarProposalKind.availability);
      final applied = apply(accepted: [availability]);
      expect(applied.weekly.keys.toList()..sort(), <int>[1, 2, 3, 4, 5, 6, 7]);
      expect(applied.weekly[1]!.single.endMinute, 1440);
      expect(applied.applied, 1);
    });

    test('勾选课程后成为正式占用（不是可用时间）', () {
      final set = decode(acceptancePayload()).set!;
      final course =
          set.proposals.firstWhere((p) => p.title == '上课' && p.isApplicable);
      final applied = apply(accepted: [course]);
      expect(applied.weekly, isEmpty);
      expect(applied.occupancies.length, 2, reason: '周二与周四各一条');
      expect(applied.occupancies.every((o) => o.kind == 'course'), isTrue);
      expect(applied.occupancies.every((o) => o.isWeekly), isTrue);
      expect(applied.occupancies.map((o) => o.weekday).toList()..sort(),
          <int>[2, 4]);
      expect(applied.occupancies.every((o) => o.provisional == false), isTrue,
          reason: '用户勾选后就是确认数据，不是暂定值');
    });

    test('重复应用不会重复导入', () {
      final set = decode(acceptancePayload()).set!;
      final course =
          set.proposals.firstWhere((p) => p.title == '上课' && p.isApplicable);
      final first = apply(accepted: [course]);
      final second = apply(accepted: [course], occupancies: first.occupancies);
      expect(second.occupancies.length, first.occupancies.length);
      expect(second.applied, 0);
      expect(second.skipped, 1);
    });

    test('已存在的可用窗口不会被重复叠加', () {
      final set = decode(acceptancePayload()).set!;
      final availability = set.proposals
          .firstWhere((p) => p.kind == CalendarProposalKind.availability);
      final weekly = <int, List<WallClockRange>>{
        for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 1440)],
      };
      final applied = apply(accepted: [availability], weekly: weekly);
      expect(applied.applied, 0);
      expect(applied.skipped, 1);
    });

    test('仅时长的候选只留下问题，不产生占用', () {
      final set = decode(acceptancePayload()).set!;
      final rests = set.proposals.where((p) => p.needsTime).toList();
      final applied = apply(accepted: rests);
      expect(applied.occupancies, isEmpty);
      expect(applied.pendingNotes.length, 1,
          reason: '两条用餐候选共享同一句待确认说明，去重后只有一条');
    });

    test('填入时段后用餐可应用', () {
      final set = decode(acceptancePayload()).set!;
      final lunch = set.proposals.firstWhere((p) => p.title == '午饭');
      final filled = lunch.withRanges(const [WallClockRange(720, 750)]);
      expect(filled.isApplicable, isTrue);
      final applied = apply(accepted: [filled]);
      expect(applied.occupancies, isNotEmpty);
      expect(applied.occupancies.first.kind, 'rest');
      expect(applied.occupancies.first.ranges.single.startMinute, 720);
    });

    test('日期例外写入 exceptions', () {
      final set = decode(acceptancePayload()).set!;
      final closed =
          set.proposals.firstWhere((p) => p.kind == CalendarProposalKind.exception);
      final applied = apply(accepted: [closed]);
      expect(applied.exceptions.single.date, '2026-10-22');
      expect(applied.exceptions.single.closed, isTrue);
      expect(applied.exceptions.single.ranges, isEmpty);
    });
  });

  group('持久化与旧数据兼容', () {
    test('提案集可以往返序列化', () {
      final set = decode(acceptancePayload()).set!;
      final restored = CalendarProposalSet.fromJson(set.toJson());
      expect(restored, isNotNull);
      expect(restored!.proposals.length, set.proposals.length);
      expect(restored.notes, set.notes);
      expect(restored.materialSignature, set.materialSignature);
      expect(restored.proposals.first.id, set.proposals.first.id);
    });

    test('旧会话没有该字段时是 null（从未识别），不是空集', () {
      final conversation = Conversation.fromJson(<String, dynamic>{
        'id': 'c1',
        'title': 't',
        'createdAt': '2026-10-01T00:00:00Z',
        'updatedAt': '2026-10-01T00:00:00Z',
      });
      expect(conversation.calendarProposals, isNull);
    });

    test('未知 schema 版本被忽略而不是猜', () {
      final raw = decode(acceptancePayload()).set!.toJson();
      raw['schemaVersion'] = 99;
      expect(CalendarProposalSet.fromJson(raw), isNull);
    });
  });

  group('材料签名', () {
    test('材料变化后签名变化，缓存不再被当作当前结果', () {
      final before = materialSignature(<String>['每天 8-24 可工作']);
      final after = materialSignature(<String>['每天 8-24 可工作', '周二 8-10 上课']);
      expect(before, isNot(after));
      expect(before, isNotEmpty);
      expect(materialSignature(<String>['  ', '']), isEmpty);
    });
  });
}

