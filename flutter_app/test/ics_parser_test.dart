// RFC 5545 内容行解析测试（T-C / ics-core）。
//
// 覆盖：UTF-8 BOM、CRLF/LF/单独 CR、折叠行（空格/TAB 续行）、参数引号与多值、
// 参数 RFC 6868 转义、TEXT 转义、BEGIN/END 嵌套、多个顶层日历、错误定位。
// 这些用例刻意用真实导出器会产生的形态，而不是“理想化”的输入。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_parser.dart';

String fixtureText(String name) =>
    File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}ics'
            '${Platform.pathSeparator}$name')
        .readAsStringSync();

String calendar(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\n$body'
    'END:VCALENDAR\r\n';

String event(String uid, String extra) => 'BEGIN:VEVENT\r\n'
    'UID:$uid\r\n'
    'DTSTAMP:20260101T000000Z\r\n'
    '$extra'
    'END:VEVENT\r\n';

void main() {
  group('parseIcs：编码与折叠行', () {
    test('UTF-8 BOM + CRLF + 折叠行 + 引号参数 + 多值参数', () {
      // `File.readAsString` 自己会吃掉 BOM，所以这里用字节确认 fixture 真带 BOM，
      // 再把 BOM 显式拼回去交给解析器（模拟真实文件字节）。
      final bytes = File('test${Platform.pathSeparator}fixtures'
              '${Platform.pathSeparator}ics${Platform.pathSeparator}'
              'bom_folded_crlf.ics')
          .readAsBytesSync();
      expect(bytes.take(3).toList(), <int>[0xEF, 0xBB, 0xBF],
          reason: 'fixture 必须带 UTF-8 BOM');
      final text = '\uFEFF${fixtureText('bom_folded_crlf.ics')}';
      expect(text.codeUnitAt(0), 0xFEFF);
      expect(text.contains('\r\n'), isTrue);

      final root = parseIcs(text);
      expect(root.name, 'VCALENDAR');
      final vevent = root.allNamed('VEVENT').single;

      final dtstart = vevent.property('DTSTART')!;
      expect(dtstart.name, 'DTSTART');
      expect(dtstart.parameter('TZID'), 'Asia/Shanghai',
          reason: 'TZID 的引号必须被去掉');
      expect(dtstart.value, '20260302T090000');

      final summary = vevent.property('SUMMARY')!;
      // 折叠行已拼回：`SUMMARY:带\;分号\,逗号\\反斜杠\n换行` + ` 的折叠标题`。
      expect(summary.value, '带\\;分号\\,逗号\\\\反斜杠\\n换行的折叠标题');
      expect(unescapeText(summary.value), '带;分号,逗号\\反斜杠\n换行的折叠标题');

      final multi = vevent.property('X-MULTI')!;
      expect(multi.parameterValues('PARAM'), <String>['a', 'b', 'c']);
      expect(multi.parameterValues('QUOTED'), <String>['x:y;z,1'],
          reason: '引号里的 : ; , 都是普通字符');
      expect(multi.value, 'value');
    });

    test('单独的 CR 与 LF 都能作为行分隔符', () {
      final crOnly = calendar(event('cr@test', 'SUMMARY:CR 行\r'))
          .replaceAll('\r\n', '\r');
      final root = parseIcs(crOnly);
      expect(root.allNamed('VEVENT'), hasLength(1));
      expect(root.allNamed('VEVENT').single.property('SUMMARY')!.value, 'CR 行');

      final lfOnly = calendar(event('lf@test', 'SUMMARY:LF 行\n'))
          .replaceAll('\r\n', '\n');
      final lfRoot = parseIcs(lfOnly);
      expect(lfRoot.allNamed('VEVENT').single.property('SUMMARY')!.value, 'LF 行');
    });

    test('TAB 续行同样被展开', () {
      final text = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:tab@test\n'
          'SUMMARY:第一段\n'
          '\t第二段\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';
      final root = parseIcs(text);
      expect(root.allNamed('VEVENT').single.property('SUMMARY')!.value,
          '第一段第二段');
    });

    test('折叠行保留原始行号（续行不单独占一条逻辑行）', () {
      final text = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:line@test\n'
          'SUMMARY:第一段\n'
          ' 续行\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';
      final root = parseIcs(text);
      final summary = root.allNamed('VEVENT').single.property('SUMMARY')!;
      expect(summary.line, 4);
    });
  });

  group('parseIcs：参数', () {
    test('引号参数里的冒号/分号/逗号不会被切断', () {
      final text = calendar(event(
        'param@test',
        'SUMMARY:x\n'
            'DTSTART;TZID="America/New_York";VALUE=DATE-TIME:20260302T090000\n',
      ));
      final dtstart = parseIcs(text).allNamed('VEVENT').single.property('DTSTART')!;
      expect(dtstart.parameter('TZID'), 'America/New_York');
      expect(dtstart.parameter('VALUE'), 'DATE-TIME');
      expect(dtstart.value, '20260302T090000');
    });

    test('参数多值与 RFC 6868 转义（^n ^^ ^\'）', () {
      final text = calendar(event(
        'caret@test',
        'SUMMARY:x\n'
            'X-NOTE;MEMBERS="a,b";TEXT="换行^n与^^和^\'":ok\n',
      ));
      final property = parseIcs(text).allNamed('VEVENT').single.property('X-NOTE')!;
      expect(property.parameterValues('MEMBERS'), <String>['a,b'],
          reason: '引号里的逗号是值的一部分，不能再拆分');
      expect(property.parameter('TEXT'), '换行\n与^和"');
    });

    test('参数名大小写不敏感', () {
      final text = calendar(event(
        'case@test',
        'SUMMARY:x\n'
            'DTSTART;tzid=Asia/Shanghai:20260302T090000\n',
      ));
      final dtstart = parseIcs(text).allNamed('VEVENT').single.property('DTSTART')!;
      expect(dtstart.parameter('TZID'), 'Asia/Shanghai');
    });
  });

  group('parseIcs：组件树', () {
    test('BEGIN/END 正确嵌套（VEVENT 里嵌 VALARM）', () {
      final root = parseIcs(fixtureText('basic_cn.ics'));
      expect(root.name, 'VCALENDAR');
      final events = root.allNamed('VEVENT');
      expect(events, hasLength(2));
      expect(events.first.childrenNamed('VALARM'), hasLength(1));
      expect(events.first.childrenNamed('VALARM').single.property('ACTION')!.value,
          'DISPLAY');
      expect(root.allNamed('VTODO'), hasLength(1));
      // 组件树里 VEVENT 是 VCALENDAR 的直接子节点。
      expect(root.children.where((c) => c.name == 'VEVENT'), hasLength(2));
    });

    test('未知属性原样保留（不影响解析）', () {
      final root = parseIcs(fixtureText('basic_cn.ics'));
      final event = root.allNamed('VEVENT').first;
      final custom = event.property('X-CUSTOM-PROP');
      expect(custom, isNotNull);
      expect(custom!.value, 'ignored');
    });

    test('多个顶层 VCALENDAR 被包装成合成根，allNamed 仍能找到事件', () {
      final first = calendar(event('a@test', 'SUMMARY:A\nDTSTART:20260302T010000Z\n'));
      final second = calendar(event('b@test', 'SUMMARY:B\nDTSTART:20260303T010000Z\n'));
      final root = parseIcs('$first$second');
      expect(root.name, 'VCALENDAR');
      expect(root.children, hasLength(2));
      expect(root.allNamed('VEVENT'), hasLength(2));
    });
  });

  group('parseIcs：错误处理', () {
    test('空文本', () {
      expect(() => parseIcs(''), throwsA(isA<IcsParseException>()));
      expect(() => parseIcs('   \r\n  '), throwsA(isA<IcsParseException>()));
    });

    test('END 没有对应 BEGIN', () {
      expect(
        () => parseIcs('BEGIN:VCALENDAR\nEND:VEVENT\nEND:VCALENDAR\n'),
        throwsA(isA<IcsParseException>().having(
            (e) => e.line, 'line', 2)),
      );
    });

    test('BEGIN/END 名字不匹配', () {
      expect(
        () => parseIcs('BEGIN:VCALENDAR\nBEGIN:VEVENT\nEND:VCALENDAR\n'),
        throwsA(isA<IcsParseException>()),
      );
    });

    test('组件没有闭合', () {
      expect(
        () => parseIcs('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x@test\n'),
        throwsA(isA<IcsParseException>()),
      );
    });

    test('属性落在组件外', () {
      expect(
        () => parseIcs('SUMMARY:顶层属性\nBEGIN:VCALENDAR\nEND:VCALENDAR\n'),
        throwsA(isA<IcsParseException>().having((e) => e.line, 'line', 1)),
      );
    });

    test('续行前面没有内容行', () {
      expect(
        () => parseIcs(' 续行\nBEGIN:VCALENDAR\nEND:VCALENDAR\n'),
        throwsA(isA<IcsParseException>()),
      );
    });

    test('内容行没有冒号', () {
      expect(
        () => parseIcs('BEGIN:VCALENDAR\nSUMMARY 没有冒号\nEND:VCALENDAR\n'),
        throwsA(isA<IcsParseException>()),
      );
    });

    test('根组件结束后还有内容', () {
      expect(
        () => parseIcs('BEGIN:VCALENDAR\nEND:VCALENDAR\nX-GARBAGE:1\n'),
        throwsA(isA<IcsParseException>()),
      );
    });
  });

  group('unescapeText', () {
    test('标准转义', () {
      expect(unescapeText(r'a\\b'), r'a\b');
      expect(unescapeText(r'a\;b'), 'a;b');
      expect(unescapeText(r'a\,b'), 'a,b');
      expect(unescapeText(r'a\nb'), 'a\nb');
      expect(unescapeText(r'a\Nb'), 'a\nb');
    });

    test('非标准转义只保留字符本身', () {
      expect(unescapeText(r'a\:b'), 'a:b');
      expect(unescapeText(r'a\qb'), 'aqb');
    });

    test('没有反斜杠时原样返回', () {
      expect(unescapeText('普通文本, 无转义'), '普通文本, 无转义');
    });

    test('结尾孤立反斜杠原样保留，不会抛异常', () {
      expect(unescapeText('结尾\\'), '结尾\\');
    });
  });

  group('IcalComponent 查询辅助', () {
    test('property/propertiesNamed/childrenNamed/allNamed 大小写不敏感', () {
      final root = parseIcs(fixtureText('basic_cn.ics'));
      expect(root.property('version')!.value, '2.0');
      expect(root.propertiesNamed('PRODID'), hasLength(1));
      final event = root.childrenNamed('vevent').first;
      expect(event.childrenNamed('Valarm'), hasLength(1));
      expect(root.allNamed('vtodo'), hasLength(1));
      expect(event.valueOf('SUMMARY'), isNotNull);
    });
  });
}
