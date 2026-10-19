// Cross-layer contract test: Flutter/Dart → the freshly built ts_bridge.dll → a real
// local HTTP server. No Python mock server is involved.
//
// Why this file exists (0.0.4 acceptance):
//   * C unit tests alone cannot prove that the Dart settings payload actually carries
//     `deletedProfileIds`, that the analysed request uses the selected model/URL, or
//     that model discovery does not become a plan;
//   * FakeSettingsBridge tests alone cannot prove the same, because the fake used to
//     rebuild the stored list from the submitted profiles instead of merging like C.
//
// The test is skipped when ts_bridge.dll has not been built. It only uses fictitious
// credentials (`sk-test-…`) and throw-away data directories; it never touches the
// user's real settings, sessions or credentials.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule_engine.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import 'support/native_bridge.dart';
import 'support/test_support.dart';

class _Captured {
  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  const _Captured(this.method, this.path, this.headers, this.body);

  bool get hasAuthorization => headers.containsKey('authorization');

  String get authorization => headers['authorization'] ?? '';

  Map<String, dynamic> get json =>
      (jsonDecode(body) as Map<String, dynamic>?) ?? const {};
}

/// A tiny OpenAI-compatible mock server that records what it received.
class _MockServer {
  final HttpServer server;
  final List<_Captured> requests = <_Captured>[];
  final String planContent;
  final Duration delay;
  final int status;
  final String? modelsBody;

  _MockServer._(this.server, this.planContent, this.delay, this.status,
      this.modelsBody);

  int get port => server.port;

  String get base => 'http://127.0.0.1:$port';

  static Future<_MockServer> start({
    required String planContent,
    Duration delay = Duration.zero,
    int status = 200,
    String? modelsBody,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock =
        _MockServer._(server, planContent, delay, status, modelsBody);
    server.listen(mock._handle);
    return mock;
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    requests.add(
        _Captured(request.method, request.uri.path, headers, body));
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    if (request.uri.path.endsWith('/models')) {
      request.response.write(modelsBody ??
          jsonEncode(<String, dynamic>{
            'object': 'list',
            'data': [
              {'id': 'model-a'},
              {'id': 'model-b'},
            ],
          }));
    } else if (status >= 400) {
      request.response.write(jsonEncode(<String, dynamic>{
        'error': {'message': 'mock failure', 'type': 'mock_error'},
      }));
    } else {
      request.response.write(jsonEncode(<String, dynamic>{
        'id': 'chatcmpl-test',
        'object': 'chat.completion',
        'model': 'mock',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': planContent},
            'finish_reason': 'stop',
          }
        ],
        'usage': {'prompt_tokens': 3, 'completion_tokens': 5, 'total_tokens': 8},
      }));
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

String _readPlanContent() {
  final candidates = <String>[
    '../tests/data/mock_responses/valid_tasks.json',
    'tests/data/mock_responses/valid_tasks.json',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('缺少 tests/data/mock_responses/valid_tasks.json 夹具');
}

Map<String, dynamic> _analyzeRequest(String id) => <String, dynamic>{
      'conversationId': 'conv-$id',
      'requestId': 'req-$id',
      'userRequest': '补充要求',
      'sources': [
        {'kind': 'text', 'label': '文段1', 'text': '整理实验材料'}
      ],
    };

Map<String, dynamic> _profileJson({
  required String id,
  required String chatUrl,
  required String modelsUrl,
  required String modelId,
  String protocol = 'openai-chat',
  String authMode = 'none',
  String apiKeyEnv = '',
  String thinking = 'unsupported',
  String? reasoningEffort,
}) =>
    <String, dynamic>{
      'id': id,
      'name': id,
      'revision': 0,
      'protocol': protocol,
      'baseUrl': Uri.parse(chatUrl).origin,
      'chatUrl': chatUrl,
      'modelsUrl': modelsUrl,
      'authMode': authMode,
      'apiKeyEnv': apiKeyEnv,
      'modelId': modelId,
      'thinking': thinking,
      'reasoningEffort': reasoningEffort,
      'jsonMode': false,
    };

Map<String, dynamic> _settingsDocument({
  required List<Map<String, dynamic>> profiles,
  required String defaultId,
  required String defaultModel,
  String thinking = 'unsupported',
  String? effort,
}) =>
    <String, dynamic>{
      'schemaVersion': 2,
      'defaultProfileId': defaultId,
      'defaultModelId': defaultModel,
      'defaultThinking': thinking,
      'defaultReasoningEffort': effort,
      'profiles': profiles,
    };

Future<void> _waitTerminal(NativeGateway gateway, int job,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final polled = gateway.poll(job);
    if (polled.terminal) return;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  fail('分析在 $timeout 内没有进入终态');
}

void main() {
  final bridgeDir = findBridgeDir();
  final skipReason = bridgeDir == null
      ? 'ts_bridge.dll 未构建；先运行 scripts/build_flutter_bridge.ps1'
      : null;
  late String nativeDir;
  late Directory tempRoot;
  late String configPath;
  late String waitConfigPath;
  late String longWaitConfigPath;
  late String planContent;

  setUpAll(() async {
    if (bridgeDir == null) return;
    nativeDir = await stageNativeLibs(bridgeDir);
    planContent = _readPlanContent();
    tempRoot =
        await Directory.systemTemp.createTemp('ts-settings-integration');
    final config = File('${tempRoot.path}${Platform.pathSeparator}config.json');
    await config.writeAsString(jsonEncode(<String, dynamic>{
      'endpoint_url': 'https://example.invalid/chat/completions',
      'model': 'legacy-model',
      'api_key_env': '',
      'mock_mode': false,
      'connect_timeout_ms': 3000,
      'request_timeout_ms': 0,
      'json_mode': true,
    }));
    configPath = config.path;
    final waitConfig =
        File('${tempRoot.path}${Platform.pathSeparator}config-wait.json');
    await waitConfig.writeAsString(jsonEncode(<String, dynamic>{
      'endpoint_url': 'https://example.invalid/chat/completions',
      'model': 'legacy-model',
      'api_key_env': '',
      'mock_mode': false,
      'connect_timeout_ms': 3000,
      'wait_prompt_ms': 1000,
      'request_timeout_ms': 0,
      'json_mode': true,
    }));
    waitConfigPath = waitConfig.path;
    final longWait =
        File('${tempRoot.path}${Platform.pathSeparator}config-wait-120s.json');
    await longWait.writeAsString(jsonEncode(<String, dynamic>{
      'endpoint_url': 'https://example.invalid/chat/completions',
      'model': 'legacy-model',
      'api_key_env': '',
      'mock_mode': false,
      'connect_timeout_ms': 3000,
      'wait_prompt_ms': 120000,
      'request_timeout_ms': 0,
      'json_mode': true,
    }));
    longWaitConfigPath = longWait.path;
  });

  tearDownAll(() async {
    if (bridgeDir == null) return;
    try {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    } catch (_) {
      // Best effort cleanup of our own temp folder.
    }
  });

  NativeGateway openGateway(Directory dataDir) => NativeGateway.open(
        configPath: configPath,
        dataDir: dataDir.path,
        dllDirectories: [nativeDir],
      );

  Directory newDataDir(String name) {
    final d = Directory(
        '${tempRoot.path}${Platform.pathSeparator}${name}_${DateTime.now().microsecondsSinceEpoch}');
    d.createSync(recursive: true);
    // Seed an EMPTY settings.json so the bridge does not migrate the legacy
    // config.json into an extra profile: this test wants exactly the profiles it
    // creates itself. (Migration is covered by the C tests.)
    File('${d.path}${Platform.pathSeparator}settings.json').writeAsStringSync(
        jsonEncode(<String, dynamic>{
      'schemaVersion': 2,
      'defaultProfileId': '',
      'defaultModelId': '',
      'defaultThinking': 'unsupported',
      'defaultReasoningEffort': null,
      'profiles': <dynamic>[],
    }));
    return d;
  }

  test('Dart settings payload deletes profiles through the real C merge', () async {
    final dataDir = newDataDir('delete');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: 'http://127.0.0.1:9/chat/completions',
        modelsUrl: 'http://127.0.0.1:9/models',
        modelId: 'model-a');
    final b = _profileJson(
        id: 'p-b',
        chatUrl: 'http://127.0.0.1:9/chat/completions',
        modelsUrl: 'http://127.0.0.1:9/models',
        modelId: 'model-b');
    final c = _profileJson(
        id: 'p-c',
        chatUrl: 'http://127.0.0.1:9/chat/completions',
        modelsUrl: 'http://127.0.0.1:9/models',
        modelId: 'model-c');
    gateway.settingsSave(_settingsDocument(
        profiles: [a, b, c], defaultId: 'p-a', defaultModel: 'model-a'));

    final settings = SettingsController(
      store: SettingsStore(dataDir),
      bridge: gateway,
    );
    await settings.load();
    addTearDown(settings.dispose);
    expect(settings.profiles.map((p) => p.id), containsAll(['p-a', 'p-b', 'p-c']));

    // Repro of the contract gap: omitting a profile does NOT delete it in C.
    final omitted = gateway.settingsGet();
    final raw = <String, dynamic>{
      'schemaVersion': 2,
      'defaultProfileId': 'p-a',
      'defaultModelId': 'model-a',
      'defaultThinking': 'unsupported',
      'defaultReasoningEffort': null,
      'profiles': [
        for (final p in (omitted['profiles'] as List))
          if ((p as Map)['id'] == 'p-a') p
      ],
    };
    gateway.settingsSave(raw);
    expect(
        (gateway.settingsGet()['profiles'] as List)
            .map((p) => (p as Map)['id']),
        contains('p-b'),
        reason: '省略 profile 不应删除（这是 C 的既有合并语义）');

    // With the controller fix the deletion is explicit and must really delete.
    settings.removeDraftProfile('p-b');
    final error = await settings.save();
    expect(error, isNull, reason: '删除普通连接应当成功：$error');
    final saved = gateway.settingsGet();
    expect((saved['profiles'] as List).map((p) => (p as Map)['id']),
        isNot(contains('p-b')));

    // Deleting the default connection while another one remains requires a new
    // default; the save must be refused instead of silently picking another provider.
    settings.removeDraftProfile('p-a');
    expect(await settings.save(), isNotNull,
        reason: '默认连接被删除且未重选时必须拒绝保存');
    expect((gateway.settingsGet()['profiles'] as List), hasLength(2),
        reason: '被拒绝的保存不能改动磁盘');

    // Choose the remaining profile explicitly, then delete the last one.
    final remainingDraft = settings.draft.profiles.single;
    final remainingId = remainingDraft.id;
    final selectionError = settings.setDraftDefaultSelection(ModelSelection(
      profileId: remainingId,
      profileRevision: remainingDraft.revision,
      modelId: remainingDraft.modelId,
      thinking: ThinkingMode.unsupported,
    ));
    expect(selectionError, isNull);
    expect(await settings.save(), isNull);

    settings.removeDraftProfile(remainingId);
    expect(await settings.save(), isNull, reason: '删除最后一个连接应成功');
    final empty = gateway.settingsGet();
    expect(empty['profiles'] as List, isEmpty);
    expect(empty['defaultProfileId'], isEmpty);

    // Restart: a fresh gateway over the same data directory sees the same result.
    await gateway.close();
    final reopened = openGateway(dataDir);
    addTearDown(reopened.close);
    expect(reopened.settingsGet()['profiles'] as List, isEmpty);
  }, skip: skipReason);

  test('analysis uses the selected URL/model and survives a settings save',
      () async {
    final dataDir = newDataDir('switch');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final serverA = await _MockServer.start(planContent: planContent);
    final serverB = await _MockServer.start(planContent: planContent);
    addTearDown(serverA.close);
    addTearDown(serverB.close);

    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${serverA.base}/chat/completions',
        modelsUrl: '${serverA.base}/models',
        modelId: 'model-a');
    final b = _profileJson(
        id: 'p-b',
        chatUrl: '${serverB.base}/chat/completions',
        modelsUrl: '${serverB.base}/models',
        modelId: 'model-b');
    gateway.settingsSave(_settingsDocument(
        profiles: [a, b], defaultId: 'p-a', defaultModel: 'model-a'));

    final aRev = ((gateway.settingsGet()['profiles'] as List)
            .firstWhere((p) => (p as Map)['id'] == 'p-a') as Map)['revision']
        as num;
    ModelSelection selA(int rev, String model) => ModelSelection(
        profileId: 'p-a',
        profileRevision: rev.toInt(),
        modelId: model,
        thinking: ThinkingMode.unsupported);

    final jobA = gateway.analyzeAsync(_analyzeRequest('a'),
        modelSelection: selA(aRev.toInt(), 'model-a'));
    await _waitTerminal(gateway, jobA);
    final outA = gateway.result(jobA)!;
    gateway.release(jobA);
    expect(outA.ok, isTrue);
    expect(serverA.requests, hasLength(1));
    expect(serverB.requests, isEmpty);
    expect(serverA.requests.single.json['model'], 'model-a');

    final jobB = gateway.analyzeAsync(_analyzeRequest('b'),
        modelSelection: ModelSelection(
            profileId: 'p-b',
            profileRevision: ((gateway.settingsGet()['profiles'] as List)
                    .firstWhere((p) => (p as Map)['id'] == 'p-b') as Map)['revision']
                as int,
            modelId: 'model-b',
            thinking: ThinkingMode.unsupported));
    await _waitTerminal(gateway, jobB);
    expect(gateway.result(jobB)!.ok, isTrue);
    gateway.release(jobB);
    expect(serverB.requests, hasLength(1));
    expect(serverB.requests.single.json['model'], 'model-b');
    expect(serverA.requests, hasLength(1));
  }, skip: skipReason);

  test('saving while a request runs keeps the old snapshot and next request moves on',
      () async {
    final dataDir = newDataDir('snapshot');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final slow = await _MockServer.start(
        planContent: planContent,
        delay: const Duration(milliseconds: 1200));
    addTearDown(slow.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${slow.base}/chat/completions',
        modelsUrl: '${slow.base}/models',
        modelId: 'model-before');
    gateway.settingsSave(_settingsDocument(
        profiles: [a], defaultId: 'p-a', defaultModel: 'model-before'));
    final rev = ((gateway.settingsGet()['profiles'] as List).single
        as Map)['revision'] as int;

    final job = gateway.analyzeAsync(_analyzeRequest('slow'),
        modelSelection: ModelSelection(
            profileId: 'p-a',
            profileRevision: rev,
            modelId: 'model-before',
            thinking: ThinkingMode.unsupported));
    // Change the same profile while the request is in flight.
    gateway.settingsSave(_settingsDocument(
        profiles: [
          _profileJson(
              id: 'p-a',
              chatUrl: '${slow.base}/chat/completions',
              modelsUrl: '${slow.base}/models',
              modelId: 'model-after')
            ..['revision'] = rev,
        ],
        defaultId: 'p-a',
        defaultModel: 'model-after'));
    await _waitTerminal(gateway, job);
    expect(gateway.result(job)!.ok, isTrue);
    gateway.release(job);
    expect(slow.requests.single.json['model'], 'model-before',
        reason: '运行中的请求必须使用启动瞬间的快照');

    final newRev = ((gateway.settingsGet()['profiles'] as List).single
        as Map)['revision'] as int;
    final job2 = gateway.analyzeAsync(_analyzeRequest('next'),
        modelSelection: ModelSelection(
            profileId: 'p-a',
            profileRevision: newRev,
            modelId: 'model-after',
            thinking: ThinkingMode.unsupported));
    await _waitTerminal(gateway, job2);
    expect(gateway.result(job2)!.ok, isTrue);
    gateway.release(job2);
    expect(slow.requests.last.json['model'], 'model-after');

    // The old revision must be rejected before any network request is made.
    final before = slow.requests.length;
    expect(
        () => gateway.analyzeAsync(_analyzeRequest('stale'),
            modelSelection: ModelSelection(
                profileId: 'p-a',
                profileRevision: rev,
                modelId: 'model-before',
                thinking: ThinkingMode.unsupported)),
        throwsA(isA<NativeCallException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(slow.requests.length, before);
  }, skip: skipReason);

  test('thinking parameters follow the protocol and leave no residue', () async {
    final dataDir = newDataDir('thinking');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final server = await _MockServer.start(planContent: planContent);
    addTearDown(server.close);
    final deepseek = _profileJson(
        id: 'p-ds',
        chatUrl: '${server.base}/chat/completions',
        modelsUrl: '${server.base}/models',
        modelId: 'deepseek-chat',
        protocol: 'deepseek-chat',
        thinking: 'disabled');
    final compat = _profileJson(
        id: 'p-compat',
        chatUrl: '${server.base}/chat/completions',
        modelsUrl: '${server.base}/models',
        modelId: 'compat-model');
    gateway.settingsSave(_settingsDocument(
        profiles: [deepseek, compat],
        defaultId: 'p-ds',
        defaultModel: 'deepseek-chat'));

    Future<void> run(String profileId, int revision, String model,
        ThinkingMode thinking, String? effort) async {
      final job = gateway.analyzeAsync(_analyzeRequest('t$profileId$thinking'),
          modelSelection: ModelSelection(
              profileId: profileId,
              profileRevision: revision,
              modelId: model,
              thinking: thinking,
              reasoningEffort: effort));
      await _waitTerminal(gateway, job);
      expect(gateway.result(job)!.ok, isTrue);
      gateway.release(job);
    }

    final dsRev = ((gateway.settingsGet()['profiles'] as List)
            .firstWhere((p) => (p as Map)['id'] == 'p-ds') as Map)['revision']
        as int;
    final compatRev = ((gateway.settingsGet()['profiles'] as List)
            .firstWhere((p) => (p as Map)['id'] == 'p-compat') as Map)['revision']
        as int;

    await run('p-ds', dsRev, 'deepseek-chat', ThinkingMode.enabled, 'high');
    var body = server.requests.last.json;
    expect((body['thinking'] as Map)['type'], 'enabled');
    expect(body['reasoning_effort'], 'high');

    await run('p-ds', dsRev, 'deepseek-chat', ThinkingMode.disabled, null);
    body = server.requests.last.json;
    expect((body['thinking'] as Map)['type'], 'disabled');
    expect(body.containsKey('reasoning_effort'), isFalse,
        reason: '关闭思考后不得残留 effort');

    await run('p-compat', compatRev, 'compat-model',
        ThinkingMode.unsupported, null);
    body = server.requests.last.json;
    expect(body.containsKey('thinking'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  }, skip: skipReason);

  test('model discovery and response test are probes, not plans', () async {
    final dataDir = newDataDir('probe');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final server = await _MockServer.start(planContent: planContent);
    addTearDown(server.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${server.base}/chat/completions',
        modelsUrl: '${server.base}/models',
        modelId: 'model-a');
    gateway.settingsSave(
        _settingsDocument(profiles: [a], defaultId: 'p-a', defaultModel: 'model-a'));
    final rev = ((gateway.settingsGet()['profiles'] as List).single
        as Map)['revision'] as int;

    final settings = SettingsController(
        store: SettingsStore(dataDir), bridge: gateway);
    await settings.load();
    addTearDown(settings.dispose);

    final models = await settings.discoverModels('p-a', rev);
    expect(models.ok, isTrue, reason: models.error);
    expect(models.models, containsAll(['model-a', 'model-b']));
    expect(server.requests.last.path, '/models');

    final probeJob = gateway.probeAsync(<String, dynamic>{
      'kind': 'models',
      'profileId': 'p-a',
      'profileRevision': rev,
      'modelId': 'model-a',
    });
    await _waitTerminal(gateway, probeJob);
    expect(() => gateway.result(probeJob), throwsA(isA<NativeCallException>()),
        reason: '探针结果不能被当作计划结果读取');
    expect(gateway.probeResult(probeJob), isNotNull);
    gateway.release(probeJob);

    final test = await settings.testModel('p-a', rev, modelId: 'model-a');
    expect(test.ok, isTrue, reason: test.error);
    expect(server.requests.last.path, '/chat/completions');
    expect(server.requests.last.json['model'], 'model-a');
  }, skip: skipReason);

  test('cross-origin model list cannot reuse the chat credential', () async {
    final dataDir = newDataDir('origin');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final serverA = await _MockServer.start(planContent: planContent);
    final serverB = await _MockServer.start(planContent: planContent);
    addTearDown(serverA.close);
    addTearDown(serverB.close);
    final profile = _profileJson(
        id: 'p-sec',
        chatUrl: '${serverA.base}/chat/completions',
        modelsUrl: '${serverB.base}/models',
        modelId: 'model-a',
        protocol: 'deepseek-chat',
        authMode: 'bearer',
        thinking: 'disabled');
    // Saving a bearer connection whose models URL lives on another origin must be
    // refused before a credential can ever be sent there.
    expect(
        () => gateway.settingsSave(_settingsDocument(
            profiles: [profile],
            defaultId: 'p-sec',
            defaultModel: 'model-a')),
        throwsA(isA<NativeCallException>()));
    expect(serverA.requests, isEmpty);
    expect(serverB.requests, isEmpty);
  }, skip: skipReason);

  test(
      'a deleted or re-versioned conversation binding blocks sending without fallback',
      () async {
    final dataDir = newDataDir('stale');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final serverA = await _MockServer.start(planContent: planContent);
    final serverB = await _MockServer.start(planContent: planContent);
    addTearDown(serverA.close);
    addTearDown(serverB.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${serverA.base}/chat/completions',
        modelsUrl: '${serverA.base}/models',
        modelId: 'model-a');
    final b = _profileJson(
        id: 'p-b',
        chatUrl: '${serverB.base}/chat/completions',
        modelsUrl: '${serverB.base}/models',
        modelId: 'model-b');
    gateway.settingsSave(_settingsDocument(
        profiles: [a, b], defaultId: 'p-a', defaultModel: 'model-a'));

    final settings =
        SettingsController(store: SettingsStore(dataDir), bridge: gateway);
    await settings.load();
    addTearDown(settings.dispose);
    final app = AppController(
      engine: NativeScheduleEngine(gateway),
      store: InMemorySessionRepository(),
      gateway: gateway,
      settings: settings,
    );
    await app.initialize();
    addTearDown(app.dispose);
    final conv = await app.createConversation();
    expect(conv.modelSelection?.profileId, 'p-a',
        reason: '新会话必须绑定创建时的默认选择');
    await app.updateDraft('材料');

    // Delete the bound connection through the controller (same path as the UI),
    // switching the default to B first.
    final bProfile =
        settings.profiles.firstWhere((p) => p.id == 'p-b');
    expect(
        settings.setDraftDefaultSelection(ModelSelection(
          profileId: bProfile.id,
          profileRevision: bProfile.revision,
          modelId: bProfile.modelId,
          thinking: ThinkingMode.unsupported,
        )),
        isNull);
    settings.removeDraftProfile('p-a');
    expect(await settings.save(), isNull);

    await app.startAnalysis();
    expect(app.isRunning, isFalse);
    expect(app.errorMessage ?? '', contains('已删除'),
        reason: '失效的会话绑定必须明确阻止发送');
    expect(serverA.requests, isEmpty);
    expect(serverB.requests, isEmpty,
        reason: '不能自动改用另一个供应商发送材料');

    // Same story for a revision change: the conversation keeps the old revision and
    // must ask the user to re-select instead of silently using the new config.
    final dataDir2 = newDataDir('revision');
    final gateway2 = openGateway(dataDir2);
    addTearDown(gateway2.close);
    gateway2.settingsSave(_settingsDocument(
        profiles: [
          _profileJson(
              id: 'p-a',
              chatUrl: '${serverA.base}/chat/completions',
              modelsUrl: '${serverA.base}/models',
              modelId: 'model-a')
        ],
        defaultId: 'p-a',
        defaultModel: 'model-a'));
    final settings2 =
        SettingsController(store: SettingsStore(dataDir2), bridge: gateway2);
    await settings2.load();
    addTearDown(settings2.dispose);
    final app2 = AppController(
      engine: NativeScheduleEngine(gateway2),
      store: InMemorySessionRepository(),
      gateway: gateway2,
      settings: settings2,
    );
    await app2.initialize();
    addTearDown(app2.dispose);
    await app2.createConversation();
    await app2.updateDraft('材料');
    final current = settings2.profiles.single;
    expect(
        settings2.updateDraftProfile(
            current.copyWith(modelId: 'model-a2', revision: current.revision)),
        isNull);
    expect(await settings2.save(), isNull);
    final beforeA = serverA.requests.length;
    await app2.startAnalysis();
    expect(app2.isRunning, isFalse);
    expect(app2.errorMessage ?? '', contains('已更新'),
        reason: '过期修订必须要求重新选择');
    expect(serverA.requests.length, beforeA);
  }, skip: skipReason);

  test('probe HTTP status and malformed JSON are classified across FFI',
      () async {
    final cases = <(int, String?, String)>[
      (401, null, 'auth'),
      (403, null, 'auth'),
      (404, null, 'config'),
      (429, null, 'rateLimit'),
      (500, null, 'server'),
      (502, null, 'server'),
      (200, 'this is not json', 'protocol'),
      (200, '{"data":[{"id":"model-a"}', 'protocol'),
    ];
    for (final (status, modelsBody, expected) in cases) {
      final dataDir = newDataDir('status-$status');
      final gateway = openGateway(dataDir);
      final server = await _MockServer.start(
          planContent: planContent, status: status, modelsBody: modelsBody);
      int? job;
      try {
        gateway.settingsSave(_settingsDocument(
            profiles: [
              _profileJson(
                  id: 'p',
                  chatUrl: '${server.base}/chat/completions',
                  modelsUrl: '${server.base}/models',
                  modelId: 'model-a')
            ],
            defaultId: 'p',
            defaultModel: 'model-a'));
        job = gateway.probeAsync(<String, dynamic>{
          'kind': 'models',
          'profileId': 'p',
          'profileRevision': 1,
          'modelId': 'model-a',
        });
        ProbeOutcome? outcome;
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          outcome = gateway.probeResult(job);
          if (outcome != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(outcome, isNotNull, reason: 'HTTP $status 探针必须有终态');
        expect(outcome!.ok, isFalse, reason: 'HTTP $status 必须失败');
        expect(outcome.errorKind, expected,
            reason: 'HTTP $status / ${modelsBody ?? "plain"} 分类错误');
        expect(outcome.error ?? '', isNotEmpty);
        expect(server.requests, hasLength(1),
            reason: '探针只发一次，不应重试 401/403/404/429/5xx');
      } finally {
        if (job != null) gateway.release(job);
        await server.close();
        gateway.close();
      }
    }
  }, skip: skipReason);

  test('the Windows notification bridge is callable and reports refusal truthfully',
      () async {
    final dataDir = newDataDir('notify');
    final gateway = openGateway(dataDir);
    try {
      final sent = gateway.showSystemNotification(
          'TaskScheduler 验收', '通知桥接调用测试（不会声称一定显示）');
      expect(sent, isA<bool>());
      // No user click happened; polling must return false.
      expect(gateway.takeNotificationClick(), isFalse);
    } finally {
      gateway.close();
    }
  }, skip: skipReason);

  test('cancel wins over a late response and releases the job', () async {
    final dataDir = newDataDir('cancel');
    final gateway = openGateway(dataDir);
    addTearDown(gateway.close);
    final slow = await _MockServer.start(
        planContent: planContent,
        delay: const Duration(milliseconds: 800));
    addTearDown(slow.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${slow.base}/chat/completions',
        modelsUrl: '${slow.base}/models',
        modelId: 'model-a');
    gateway.settingsSave(
        _settingsDocument(profiles: [a], defaultId: 'p-a', defaultModel: 'model-a'));
    final rev = ((gateway.settingsGet()['profiles'] as List).single
        as Map)['revision'] as int;
    final job = gateway.analyzeAsync(_analyzeRequest('cancel'),
        modelSelection: ModelSelection(
            profileId: 'p-a',
            profileRevision: rev,
            modelId: 'model-a',
            thinking: ThinkingMode.unsupported));
    expect(gateway.cancel(job), isTrue);
    await _waitTerminal(gateway, job);
    final out = gateway.result(job)!;
    expect(out.ok, isFalse);
    expect(out.errorKind, 'cancelled');
    gateway.release(job);
  }, skip: skipReason);

  test(
      'a slow request keeps running past the wait threshold, then cancel is real',
      () async {
    final dataDir = newDataDir('wait');
    final gateway = NativeGateway.open(
      configPath: waitConfigPath,
      dataDir: dataDir.path,
      dllDirectories: [nativeDir],
    );
    addTearDown(gateway.close);
    final slow = await _MockServer.start(
        planContent: planContent,
        delay: const Duration(milliseconds: 3000));
    addTearDown(slow.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${slow.base}/chat/completions',
        modelsUrl: '${slow.base}/models',
        modelId: 'model-a');
    gateway.settingsSave(
        _settingsDocument(profiles: [a], defaultId: 'p-a', defaultModel: 'model-a'));

    final controller = AppController(
      engine: NativeScheduleEngine(gateway),
      store: InMemorySessionRepository(),
      gateway: gateway,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await controller.updateDraft('慢请求验收');
    await controller.startAnalysis();
    expect(controller.isRunning, isTrue);

    // Past wait_prompt_ms (1000 ms) the UI must offer "wait/cancel" but the request
    // must stay alive: no resend, no automatic cancel.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(controller.waitPromptVisible, isTrue);
    expect(controller.isRunning, isTrue);
    expect(slow.requests, hasLength(1));

    controller.dismissWaitPrompt(); // "keep waiting"
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(controller.isRunning, isTrue);
    expect(slow.requests, hasLength(1), reason: '继续等待不得重发请求');

    await controller.cancelAnalysis();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.isRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(controller.isRunning, isFalse);
    expect(controller.statusMessage ?? '', contains('已取消'));
    // The formal request has no total timeout; the mock was still sleeping when the
    // user cancelled, so the cancellation must not be reported as a success plan.
    expect(controller.viewVersion, isNull);
    expect(slow.requests, hasLength(1));
  }, skip: skipReason);

  // The production wait threshold is 120 s. The test above scales it to 1 s for a fast
  // suite; this opt-in case waits the real 120 s once (`TS_LONG_WAIT=1 flutter test ...`).
  test(
      'a real 120-second wait keeps the request alive until the user cancels',
      () async {
    final dataDir = newDataDir('wait120');
    final gateway = NativeGateway.open(
      configPath: longWaitConfigPath,
      dataDir: dataDir.path,
      dllDirectories: [nativeDir],
    );
    addTearDown(gateway.close);
    final slow = await _MockServer.start(
        planContent: planContent, delay: const Duration(seconds: 125));
    addTearDown(slow.close);
    final a = _profileJson(
        id: 'p-a',
        chatUrl: '${slow.base}/chat/completions',
        modelsUrl: '${slow.base}/models',
        modelId: 'model-a');
    gateway.settingsSave(
        _settingsDocument(profiles: [a], defaultId: 'p-a', defaultModel: 'model-a'));
    final controller = AppController(
      engine: NativeScheduleEngine(gateway),
      store: InMemorySessionRepository(),
      gateway: gateway,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await controller.updateDraft('120 秒等待验收');
    await controller.startAnalysis();
    expect(controller.isRunning, isTrue);

    // 121 s > 120 000 ms: the prompt must appear, yet the request must still be alive
    // and must not have been resent.
    await Future<void>.delayed(const Duration(seconds: 121));
    expect(controller.isRunning, isTrue, reason: '120 秒后请求必须仍然存活');
    expect(controller.waitPromptVisible, isTrue);
    expect(slow.requests, hasLength(1), reason: '等待期间不得重发');

    await controller.cancelAnalysis();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (controller.isRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(controller.isRunning, isFalse);
    expect(controller.statusMessage ?? '', contains('已取消'));
    expect(controller.viewVersion, isNull);
  },
      skip: skipReason ??
          (Platform.environment['TS_LONG_WAIT'] == '1'
              ? null
              : 'opt-in: set TS_LONG_WAIT=1 (waits 121 s)'),
      timeout: const Timeout(Duration(minutes: 4)));
}

