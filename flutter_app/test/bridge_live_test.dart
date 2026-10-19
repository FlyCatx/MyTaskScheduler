// Live integration test for the real C bridge (ts_bridge.dll).
//
// This is the Dart half of "build a real C DLL and a minimal Flutter/Dart FFI probe
// before writing the whole UI". It is skipped when the DLL has not been built, so
// `flutter test` still works on a machine without MSVC.
//
// Build the DLL first:
//   powershell -ExecutionPolicy Bypass -File scripts/build_flutter_bridge.ps1

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';

import 'support/native_bridge.dart';

Future<String> _writeMockConfig(String dir) async {
  final file = File('$dir${Platform.pathSeparator}ts_bridge_dart_test.json');
  await file.writeAsString(jsonEncode({
    'endpoint_url': 'https://example.invalid/chat/completions',
    'model': 'dart-bridge-test',
    'api_key_env': '',
    'mock_mode': true,
    'connect_timeout_ms': 15000,
    'wait_prompt_ms': 120000,
    'request_timeout_ms': 0,
    'json_mode': true,
  }));
  return file.path;
}

void main() {
  final bridgeDir = findBridgeDir();
  final skipReason = bridgeDir == null
      ? 'ts_bridge.dll 未构建；请先运行 scripts/build_flutter_bridge.ps1'
      : null;

  late String nativeDir;

  setUpAll(() async {
    if (bridgeDir == null) return;
    nativeDir = await stageNativeLibs(bridgeDir);
  });

  test('edit(): validates, reschedules and returns a score-free display snapshot',
      () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: [nativeDir],
    );
    addTearDown(() => gateway.close());

    final info = gateway.info();
    expect(info.mockMode, isTrue);
    expect(info.model, 'dart-bridge-test');
    expect(info.hasApiKey, isFalse);

    final display = gateway.edit(_samplePlanJson());
    final text = jsonEncode(display);
    expect(text.contains('基础分'), isFalse);
    expect(text.contains('最终'), isFalse);
    expect(text.contains('"score"'), isFalse);

    final tasks = (display['tasks'] as List).cast<Map<String, dynamic>>();
    expect(tasks, hasLength(5));
    final byId = {for (final t in tasks) t['id']: t};

    // Relative-hour timeline: 1h then 2h, and nothing after the unknown duration.
    expect(byId['A']!['startHours'], 0);
    expect(byId['A']!['endHours'], 1);
    expect(byId['B']!['startHours'], 1);
    expect(byId['B']!['endHours'], 3);
    expect(byId['C']!['scheduleState'], 'unknownHours');
    expect(byId['C']!['startHours'], isNull);
    expect(byId['D']!['scheduleState'], 'unscheduled');
    expect((byId['D']!['scheduleNote'] as String).contains('起始时间待定'), isTrue);

    // Completion status round-trips into the display layer.
    expect(byId['E']!['status'], 'done');
    expect(byId['E']!['scheduleState'], 'completed');

    // Reasons are natural language and contain no numbers from the score model.
    final reasons = (byId['A']!['reasons'] as List).cast<String>().join(' ');
    expect(reasons.isNotEmpty, isTrue);
    expect(reasons.contains('基础分'), isFalse);
  }, skip: skipReason);

  test('invalid plans are rejected and produce no half-built snapshot', () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: [nativeDir],
    );
    addTearDown(() => gateway.close());

    expect(
      () => gateway.edit({
        'schemaVersion': '1',
        'tasks': [
          {
            'id': 'X',
            'name': 'x',
            'dependsOn': ['MISSING'],
            'preconditions': <dynamic>[],
            'steps': <dynamic>[],
            'estimatedHours': 1,
            'actualStatus': 'todo',
          }
        ],
      }),
      throwsA(isA<NativeCallException>()),
    );
  }, skip: skipReason);

  test('analyzeAsync never blocks the caller and delivers a terminal event', () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: [nativeDir],
    );
    addTearDown(() => gateway.close());

    final stopwatch = Stopwatch()..start();
    final job = gateway.analyzeAsync({
      'conversationId': 'conv-dart',
      'requestId': 'req-dart',
      'baseVersionId': null,
      'baseRevision': 0,
      'userRequest': '帮我安排顺序表实验',
      'sources': [
        {
          'kind': 'text',
          'label': '文段1',
          'text': '实现 ListInit 与 ListInsert，并写测试。'
        }
      ],
    });
    stopwatch.stop();
    expect(stopwatch.elapsedMilliseconds, lessThan(1000),
        reason: '启动分析必须立即返回，不能在 UI 线程上阻塞');

    var sawStarted = false;
    var sawProgress = false;
    var terminal = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final polled = gateway.poll(job);
      for (final e in polled.events) {
        if (e.type == 'started') sawStarted = true;
        if (e.type == 'progress') sawProgress = true;
        expect(e.conversationId, 'conv-dart');
        expect(e.requestId, 'req-dart');
      }
      if (polled.terminal) {
        terminal = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(sawStarted, isTrue);
    expect(sawProgress, isTrue, reason: '至少应上报一次进度');
    expect(terminal, isTrue);

    final outcome = gateway.result(job);
    expect(outcome, isNotNull);
    expect(outcome!.ok, isTrue);
    expect(outcome.plan, isNotNull);
    expect((outcome.plan!['tasks'] as List), isNotEmpty);
    expect(jsonEncode(outcome.plan).contains('基础分'), isFalse);

    gateway.release(job);
    // After release the job is gone: no wild pointer, just a clean error.
    expect(() => gateway.result(job), isA<Object>());
  }, skip: skipReason);

  test('constraintsAsync goes through the real DLL and returns a constraints job',
      () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: [nativeDir],
    );
    addTearDown(() => gateway.close());

    // Same request shape as an analysis: the material list is what reaches the model.
    final job = gateway.constraintsAsync({
      'conversationId': 'conv-cst',
      'requestId': 'req-cst',
      'userRequest': '每天8：00—24：00可工作；每周二和周四08-10上课',
      'sources': [
        {
          'kind': 'text',
          'label': '材料1',
          'text': '每天8：00—24：00可工作；每周二和周四08-10上课；'
              '2026-10-21 14:00-16:00参加活动；2026-10-22全天不可用；'
              '中午和晚上各吃饭30分钟',
        },
      ],
    });

    var terminal = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final polled = gateway.poll(job);
      for (final e in polled.events) {
        expect(e.requestId, 'req-cst');
      }
      if (polled.terminal) {
        terminal = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(terminal, isTrue, reason: '约束识别必须能进入终态');

    final outcome = gateway.constraintsResult(job);
    expect(outcome, isNotNull);
    // Mock mode returns the canned task-plan body, which contains no proposals. The
    // honest answer is therefore "ok, nothing found" — never an invented window.
    expect(outcome!.ok, isTrue);
    expect(outcome.constraints, isNotNull);
    expect((outcome.constraints!['proposals'] as List), isEmpty);
    // The thinking configuration of THIS request is reported, not the global setting.
    expect(outcome.protocol, isNotNull);

    // A probe/analysis result must not be usable as constraints (type safety).
    final analyze = gateway.analyzeAsync({
      'conversationId': 'conv-cst',
      'requestId': 'req-analyze',
      'userRequest': '安排顺序表实验',
      'sources': [
        {'kind': 'text', 'label': '文段1', 'text': '实现 ListInit。'}
      ],
    });
    final analyzeDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(analyzeDeadline)) {
      if (gateway.poll(analyze).terminal) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      () => gateway.constraintsResult(analyze),
      throwsA(isA<NativeCallException>()),
      reason: '分析结果不能被当成约束结果',
    );
    gateway.release(analyze);
    gateway.release(job);
  }, skip: skipReason);

  test('ABI 2 settings survive a real save/reload without secrets', () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final dataDir = await Directory.systemTemp.createTemp('ts-live-settings');
    addTearDown(() => dataDir.deleteSync(recursive: true));
    final gateway = NativeGateway.open(
      configPath: configPath,
      dataDir: dataDir.path,
      dllDirectories: [nativeDir],
    );

    final before = gateway.settingsGet();
    expect((before['abiVersion'] as num).toInt(), 2);
    expect((before['schemaVersion'] as num).toInt(), 2);

    final saved = gateway.settingsSave(<String, dynamic>{
      'schemaVersion': 2,
      'defaultProfileId': 'live-profile',
      'defaultModelId': 'live-model',
      'defaultThinking': 'unsupported',
      'defaultReasoningEffort': null,
      'profiles': <dynamic>[
        <String, dynamic>{
          'id': 'live-profile',
          'name': 'Live profile',
          'revision': 0,
          'protocol': 'openai-chat',
          'baseUrl': 'http://127.0.0.1:9',
          'chatUrl': 'http://127.0.0.1:9/chat/completions',
          'modelsUrl': '',
          'authMode': 'none',
          'apiKeyEnv': '',
          'modelId': 'live-model',
          'thinking': 'unsupported',
          'reasoningEffort': null,
          'jsonMode': false,
        },
      ],
    });
    final profiles = (saved['profiles'] as List).cast<Map<String, dynamic>>();
    final live = profiles.where((p) => p['id'] == 'live-profile').toList();
    expect(live, hasLength(1));
    expect((live.single['revision'] as num).toInt(), 1,
        reason: '新连接保存后 revision 应为 1');
    expect(live.single['credentialConfigured'], isFalse);
    // The legacy profile migrated from config.json is kept until explicitly deleted.
    expect(profiles.any((p) => p['id'] == 'legacy-config'), isTrue);

    // Nothing in the settings document may look like a credential.
    final text = jsonEncode(saved);
    expect(text.contains('sk-'), isFalse);
    expect(text.contains('"apiKey":'), isFalse);

    final reloaded = gateway.settingsGet();
    expect((reloaded['profiles'] as List)
        .where((p) => (p as Map)['id'] == 'live-profile'), hasLength(1));
    final settingsFile = File('${dataDir.path}${Platform.pathSeparator}settings.json');
    expect(settingsFile.existsSync(), isTrue);
    expect(settingsFile.readAsStringSync().contains('sk-'), isFalse);

    await gateway.close();
  }, skip: skipReason);

  test('shutdown is graceful and closes without hanging', () async {
    final configPath = await _writeMockConfig(Directory.current.path);
    final gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: [nativeDir],
    );
    final sw = Stopwatch()..start();
    await gateway.close();
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 13)));
  }, skip: skipReason);
}

Map<String, dynamic> _samplePlanJson() => {
      'schemaVersion': '1',
      'summary': '完成顺序表实验',
      'tasks': [
        {
          'id': 'A',
          'name': '整理接口要求',
          'dependsOn': <dynamic>[],
          'preconditions': <dynamic>[],
          'steps': ['读说明'],
          'urgency': 4,
          'urgencyReason': '后续实现要先明确接口',
          'impact': 4,
          'impactReason': '接口影响实现与测试范围',
          'estimatedHours': 1.0,
          'estimateReason': '读一份短说明',
          'deadline': null,
          'sourceRefs': ['文件1:段落1'],
          'actualStatus': 'todo',
        },
        {
          'id': 'B',
          'name': '实现 ListInit',
          'dependsOn': ['A'],
          'preconditions': <dynamic>[],
          'steps': ['写函数'],
          'urgency': 3,
          'urgencyReason': '接口定稿后即可实现',
          'impact': 4,
          'impactReason': '是后续实现的基础',
          'estimatedHours': 2.0,
          'estimateReason': '一个函数',
          'deadline': null,
          'sourceRefs': <dynamic>[],
          'actualStatus': 'todo',
        },
        {
          'id': 'C',
          'name': '实现 ListInsert',
          'dependsOn': ['B'],
          'preconditions': <dynamic>[],
          'steps': ['写插入'],
          'urgency': 3,
          'urgencyReason': '依赖初始化完成',
          'impact': 3,
          'impactReason': '核心操作',
          'estimatedHours': null,
          'estimateReason': null,
          'deadline': null,
          'sourceRefs': <dynamic>[],
          'actualStatus': 'todo',
        },
        {
          'id': 'D',
          'name': '编写测试',
          'dependsOn': ['C'],
          'preconditions': <dynamic>[],
          'steps': ['写用例'],
          'urgency': 2,
          'urgencyReason': '实现完成后测试',
          'impact': 3,
          'impactReason': '验证正确性',
          'estimatedHours': 0.5,
          'estimateReason': '一条用例',
          'deadline': null,
          'sourceRefs': <dynamic>[],
          'actualStatus': 'todo',
        },
        {
          'id': 'E',
          'name': '阅读实验材料',
          'dependsOn': <dynamic>[],
          'preconditions': <dynamic>[],
          'steps': ['读材料'],
          'urgency': 2,
          'urgencyReason': '已完成',
          'impact': 2,
          'impactReason': '前置阅读',
          'estimatedHours': 0.5,
          'estimateReason': '阅读',
          'deadline': null,
          'sourceRefs': <dynamic>[],
          'actualStatus': 'done',
        },
      ],
      'notes': <dynamic>[],
    };

