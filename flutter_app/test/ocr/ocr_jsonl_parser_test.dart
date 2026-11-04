import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

void main() {
  group('OcrJsonlParser', () {
    test('parses the ready handshake with languages', () {
      final event = OcrJsonlParser.parseLine(
        '{"event":"ready","mode":"pdf","host":"taskscheduler-ocr-host",'
        '"hostVersion":"1.0.0","engine":"Windows.Media.Ocr",'
        '"engineVersion":"Windows.Media.Ocr/10.0.19045.0",'
        '"osVersion":"10.0.19045.0","pages":2,'
        '"languages":[{"tag":"zh-Hans-CN","displayName":"中文（简体）",'
        '"nativeName":"中文","recognizer":true}]}',
      );
      expect(event, isA<OcrReadyEvent>());
      final ready = event! as OcrReadyEvent;
      expect(ready.hello.mode, 'pdf');
      expect(ready.hello.pages, 2);
      expect(ready.hello.engineVersion, 'Windows.Media.Ocr/10.0.19045.0');
      expect(ready.hello.languages.single.tag, 'zh-Hans-CN');
      expect(ready.hasRecognizer, isTrue);
    });

    test('parses the probe event', () {
      final event = OcrJsonlParser.parseLine(
        '{"event":"probe","engine":"Windows.Media.Ocr","languageCount":2,'
        '"recognizerAvailable":true,"unavailableRequested":0,'
        '"languages":[{"tag":"en-US","displayName":"英语（美国）","recognizer":true}]}',
      );
      final probe = event! as OcrProbeEvent;
      expect(probe.languageCount, 2);
      expect(probe.recognizerAvailable, isTrue);
      expect(probe.languages.single.tag, 'en-US');
    });

    test('parses info page sizes', () {
      final event = OcrJsonlParser.parseLine(
        '{"event":"info","source":"pdf","pages":2,"encrypted":false,'
        '"pageSizes":[{"page":1,"widthDip":793.6,"heightDip":1122.6,'
        '"rotation":"Normal"},{"page":2,"widthDip":595.0,"heightDip":842.0}]}',
      );
      final info = (event! as OcrInfoEvent).info;
      expect(info.kind, 'pdf');
      expect(info.pageCount, 2);
      expect(info.pageWidthsDip[1], closeTo(793.6, 0.01));
      expect(info.pageHeightsDip[2], closeTo(842.0, 0.01));
      expect(info.encrypted, isFalse);
    });

    test('parses a result event with bbox array and null confidence', () {
      final event = OcrJsonlParser.parseLine(
        '{"event":"result","page":2,"total":3,"method":"ocr",'
        '"engine":"Windows.Media.Ocr","engineVersion":"v1","language":"zh-Hans-CN",'
        '"dpi":150,"width":1240,"height":1754,"elapsedMs":123,'
        '"text":"日期：2026年11月4日\\n工时：2.5小时",'
        '"lines":[{"text":"日期：2026年11月4日","confidence":null,'
        '"bbox":[12.5,10,300,31]}]}',
      );
      final result = (event! as OcrPageResultEvent).result;
      expect(result.page, 2);
      expect(result.width, 1240);
      expect(result.dpi, 150);
      expect(result.method, OcrMethod.ocr);
      expect(result.text, contains('2026年11月4日'));
      expect(result.lines.single.confidence, isNull);
      expect(result.lines.single.bbox!.width, closeTo(300, 0.01));
      expect(result.meanConfidence, isNull);
    });

    test('parses page start and done events', () {
      final start = OcrJsonlParser.parseLine(
        '{"event":"page","page":3,"index":1,"total":3,"width":1240,'
        '"height":1754,"dpi":150,"scaled":false}',
      )! as OcrPageStartEvent;
      expect(start.page, 3);
      expect(start.width, 1240);

      final done = OcrJsonlParser.parseLine(
        '{"event":"done","pages":3,"ok":2,"failed":1,"cancelled":false,'
        '"elapsedMs":900}',
      )! as OcrDoneEvent;
      expect(done.pages, 3);
      expect(done.ok, 2);
      expect(done.failed, 1);
      expect(done.cancelled, isFalse);
    });

    test('parses whole-job and per-page errors', () {
      final fatal = OcrJsonlParser.parseLine(
        '{"event":"error","page":0,"code":"encrypted","message":"PDF 已加密"}',
      )! as OcrPageErrorEvent;
      expect(fatal.error.page, 0);
      expect(fatal.error.code, OcrErrorCode.encrypted);
      expect(fatal.error.message, 'PDF 已加密');

      final outOfRange = OcrJsonlParser.parseLine(
        '{"event":"error","page":9,"code":"page_out_of_range","message":"超出范围"}',
      )! as OcrPageErrorEvent;
      expect(outOfRange.error.code, OcrErrorCode.pageOutOfRange);
    });

    test('unknown codes map to protocolError but keep the message', () {
      final event = OcrJsonlParser.parseLine(
        '{"event":"error","page":1,"code":"future_code","message":"新错误"}',
      )! as OcrPageErrorEvent;
      expect(event.error.code, OcrErrorCode.protocolError);
      expect(event.error.message, '新错误');
    });

    test('buffers a line split across chunks', () {
      final parser = OcrJsonlParser();
      expect(parser.addChunk('{"event":"do'), isEmpty);
      expect(parser.addChunk('ne","pages":1,"ok":1,"failed":0}'), isEmpty);
      final events = parser.addChunk('\n');
      expect(events, hasLength(1));
      expect(events.single, isA<OcrDoneEvent>());
    });

    test('parses two events delivered in one chunk', () {
      final parser = OcrJsonlParser();
      final events = parser.addChunk(
        '{"event":"done","pages":1,"ok":1,"failed":0,"cancelled":false}\n'
        '{"event":"unknown_future","x":1}\n',
      );
      expect(events, hasLength(2));
      expect(events[0], isA<OcrDoneEvent>());
      expect(events[1], isA<OcrUnknownEvent>());
    });

    test('malformed JSON becomes a protocol error event, not a crash', () {
      final event = OcrJsonlParser.parseLine('{"event": not json');
      expect(event, isA<OcrProtocolErrorEvent>());
      final protocol = event! as OcrProtocolErrorEvent;
      expect(protocol.message, contains('无法解析'));
      expect(protocol.line, isNotEmpty);
    });

    test('non-object JSON becomes a protocol error event', () {
      final event = OcrJsonlParser.parseLine('[1,2,3]');
      expect(event, isA<OcrProtocolErrorEvent>());
    });

    test('blank lines are ignored and a leftover partial line is reported', () {
      final parser = OcrJsonlParser();
      expect(parser.addChunk('\n   \n'), isEmpty);
      expect(parser.addChunk('{"event":"done"'), isEmpty);
      final leftover = parser.flush();
      expect(leftover, isA<OcrProtocolErrorEvent>());
      expect(parser.flush(), isNull);
    });
  });
}
