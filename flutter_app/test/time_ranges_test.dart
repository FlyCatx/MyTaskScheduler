// The shared time-range parser (0.07).
//
// One parser is used by 每周可用时间, 日期例外 and 课程/活动/休息占用. These tests pin the
// grammar so the three editors cannot drift apart again, and pin the semantics that the
// planner depends on (end-minute model for cross-midnight windows, 24:00 as a legal end,
// 00:00 as "end of day", merging before summing).

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/state/time_ranges.dart';

List<WallClockRange> _ok(String text) {
  final result = parseTimeRanges(text);
  expect(result.error, isNull, reason: '「$text」应当被接受：${result.error}');
  return result.ranges;
}

String _err(String text) {
  final result = parseTimeRanges(text);
  expect(result.error, isNotNull, reason: '「$text」应当被拒绝');
  return result.error!;
}

String _fmt(String text) => formatTimeRanges(_ok(text));

void main() {
  group('分隔符与字符等价', () {
    test('8 / 08 / 8:00 / 08：00 都表示同一段时间', () {
      expect(_fmt('8-12'), '08:00-12:00');
      expect(_fmt('08-12'), '08:00-12:00');
      expect(_fmt('8:00-12:00'), '08:00-12:00');
      expect(_fmt('08:00-12:00'), '08:00-12:00');
    });

    test('中文冒号、中文逗号、长横线、全角空白都接受', () {
      expect(_fmt('08：00—12：00'), '08:00-12:00');
      // 分隔符旁边允许空白（包括全角空格与普通空格混用）
      expect(_fmt('8： 00 — 12：00，14-18'), '08:00-12:00, 14:00-18:00');
      expect(_fmt('8 ： 00 - 12 ： 00'), '08:00-12:00');
      expect(_fmt('09:00~12:00'), '09:00-12:00');
      expect(_fmt('09:00〜12:00'), '09:00-12:00');
      expect(_fmt('09:00至12:00'), '09:00-12:00');
      expect(_fmt('09:00到12:00'), '09:00-12:00');
    });

    test('多种段分隔符（中英逗号/分号/顿号）等价', () {
      for (final text in <String>[
        '8-12, 14-18',
        '8-12，14-18',
        '8-12; 14-18',
        '8-12；14-18',
        '8-12、14-18',
      ]) {
        expect(_fmt(text), '08:00-12:00, 14:00-18:00', reason: text);
      }
    });

    test('空白文本 = 没有窗口（该天不可用），不是 24 小时', () {
      final result = parseTimeRanges('   ');
      expect(result.ok, isTrue);
      expect(result.ranges, isEmpty);
      expect(result.totalMinutes, 0);
    });
  });

  group('非法输入必须报错而不是忽略', () {
    test('残留字符不能被当成成功', () {
      // 完整匹配：`8-12xyz` 不能"找到 8-12 就算过"。
      expect(_err('8-12xyz'), contains('无法识别'));
      expect(_err('abc'), contains('无法识别'));
      expect(_err('8-12, x'), contains('无法识别'));
    });

    test('超出范围的时刻被拒绝', () {
      for (final text in <String>['8:60-10:00', '25:00-26:00', '24:30-25:00', '24:00-08:00']) {
        expect(_err(text), contains('超出范围'), reason: text);
      }
    });

    test('起止相同被拒绝（不能猜成 24 小时或 0 分钟）', () {
      expect(_err('08:00-08:00'), contains('结束必须晚于开始'));
      expect(_err('8-8'), contains('结束必须晚于开始'));
    });

    test('任何输入都不会产生超过 24 小时的窗口', () {
      // `08:00-07:59` 是"跨午夜到次日 7:59"，按项目模型是合法的 23 小时 59 分，
      // 不是负数，也不是被丢弃。上限保护只是兜底，正常输入不会触发。
      final wrapped = parseTimeRanges('08:00-07:59');
      expect(wrapped.ok, isTrue);
      expect(wrapped.ranges.single.durationMinutes, 1439);
      expect(wrapped.ranges.single.endMinute, greaterThan(1440));
      for (final text in <String>['0-23:59', '00:00-24:00', '23:00-22:00']) {
        final result = parseTimeRanges(text);
        if (result.ok) {
          for (final r in result.ranges) {
            expect(r.durationMinutes, lessThanOrEqualTo(1440), reason: text);
          }
        }
      }
    });
  });

  group('24:00 / 00:00 的兼容语义', () {
    test('24:00 是合法的结束，等于 1440 分钟', () {
      final ranges = _ok('08:00-24:00');
      expect(ranges.single.startMinute, 480);
      expect(ranges.single.endMinute, 1440);
      expect(WallClockRange.format(ranges.single), '08:00-24:00');
    });

    test('00:00 作为结束仍表示日末（保留旧行为）', () {
      final ranges = _ok('22:00-00:00');
      expect(ranges.single.startMinute, 1320);
      expect(ranges.single.endMinute, 1440);
      expect(ranges.single.durationMinutes, 120);
    });

    test('00:00-24:00 是整日', () {
      final ranges = _ok('00:00-24:00');
      expect(ranges.single.isFullDay, isTrue);
      expect(ranges.single.durationMinutes, 1440);
    });
  });

  group('跨午夜沿用项目分钟模型', () {
    test('22:00-02:00 的结束分钟是 1560', () {
      final ranges = _ok('22:00-02:00');
      expect(ranges.single.startMinute, 1320);
      expect(ranges.single.endMinute, 1560);
      expect(ranges.single.crossesMidnight, isTrue);
      expect(ranges.single.durationMinutes, 240);
    });

    test('规范显示后可再次解析回同一个区间（往返稳定）', () {
      final first = _ok('22:00-02:00').single;
      final text = WallClockRange.format(first);
      expect(text, '22:00-02:00');
      final again = _ok(text).single;
      expect(again.startMinute, first.startMinute);
      expect(again.endMinute, first.endMinute);
    });

    test('不会把结束早于开始直接丢弃或当成负时长', () {
      final result = parseTimeRanges('23:30-00:30');
      expect(result.ok, isTrue);
      expect(result.ranges.single.endMinute, greaterThan(result.ranges.single.startMinute));
      expect(result.totalMinutes, 60);
    });
  });

  group('排序 / 合并 / 合计', () {
    test('多段自动排序', () {
      expect(_fmt('14-18, 8-12'), '08:00-12:00, 14:00-18:00');
    });

    test('重叠与重复先合并再计时（8-12 + 10-14 合计 6 小时）', () {
      final result = parseTimeRanges('8-12, 10-14');
      expect(result.ok, isTrue);
      expect(result.ranges.length, 1);
      expect(result.totalMinutes, 360);
      expect(formatTimeRanges(result.ranges), '08:00-14:00');
    });

    test('完全重复的段只算一次', () {
      final result = parseTimeRanges('9-10, 9-10, 9-10');
      expect(result.totalMinutes, 60);
    });

    test('相邻但不重叠的两段都保留', () {
      final result = parseTimeRanges('8-10, 10-12');
      // 相邻（10:00 共享端点）应合并成一段，合计仍是 4 小时。
      expect(result.totalMinutes, 240);
      expect(result.ranges.length, 1);
    });

    test('totalTimeRangeMinutes 与解析结果一致', () {
      final ranges = _ok('8-12, 14-18');
      expect(totalTimeRangeMinutes(ranges), 480);
    });
  });

  group('三个编辑入口共用同一套规则', () {
    // 这段文字同时是"每周可用时间""日期例外""占用时段"的输入格式；解析结果必须完全
    // 相同，否则同一份材料在三个入口会得到不同语义。
    const sample = '8： 00 — 12：00，14-18';
    test('解析结果与规范显示一致', () {
      final ranges = _ok(sample);
      expect(formatTimeRanges(ranges), '08:00-12:00, 14:00-18:00');
      expect(totalTimeRangeMinutes(ranges), 480);
    });

    test('parseTimeRangesOrError 与 parseTimeRanges 结论一致', () {
      String? error;
      final ok = parseTimeRangesOrError('8-12', onError: (e) => error = e);
      expect(error, isNull);
      expect(ok!.single.startMinute, 480);

      final bad = parseTimeRangesOrError('8-12x', onError: (e) => error = e);
      expect(bad, isNull);
      expect(error, contains('无法识别'));
    });
  });
}

