// Unit tests for session persistence: versions are immutable, the index is rebuilt,
// and a half-written file falls back to the previous copy instead of losing data.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';

import 'support/test_support.dart';

void main() {
  late Directory dir;
  late SessionStore store;

  setUp(() {
    dir = createTempDataDir('store');
    store = SessionStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('conversation round-trips with versions, completion and signatures', () async {
    await seedConversation(store);
    final loaded = await store.loadConversation('conv-seed');
    expect(loaded, isNotNull);
    expect(loaded!.versions, hasLength(1));
    final v = loaded.versions.single;
    expect(v.summary, '完成顺序表实验');
    expect(v.tasks.first.executionSignature, 'sig-a');
    expect(v.tasks.first.completion, Completion.todo);
    expect(v.tasks.firstWhere((t) => t.id == 'task-c').completion, Completion.done);
    // Stored task metadata must survive even though it is local-only.
    expect(v.notes, hasLength(2));
  });

  test('index lists conversations with their version count', () async {
    await seedConversation(store);
    final index = await store.loadIndex();
    expect(index.single.id, 'conv-seed');
    expect(index.single.versionCount, 1);
    expect(index.single.title, '完成顺序表实验');
  });

  test('adding a version keeps the old one intact (versions are append-only)', () async {
    await seedConversation(store);
    final loaded = (await store.loadConversation('conv-seed'))!;
    final oldVersion = loaded.versions.single;
    final newVersion = PlanVersion(
      id: 'ver-2',
      conversationId: loaded.id,
      parentId: oldVersion.id,
      createdAt: DateTime(2026, 10, 18),
      summary: '补充：加上测试',
      tasks: oldVersion.tasks,
      commitReason: 'supplement',
    );
    final updated = loaded.copyWith(
      versions: [...loaded.versions, newVersion],
      currentVersionId: newVersion.id,
    );
    await store.saveConversation(updated);
    await store.saveIndex([ConversationSummary.of(updated)]);

    final reloaded = (await store.loadConversation('conv-seed'))!;
    expect(reloaded.versions, hasLength(2));
    expect(reloaded.versions.first.id, 'ver-1');
    expect(reloaded.versions.first.summary, '完成顺序表实验');
    expect(reloaded.currentVersion?.id, 'ver-2');
    expect(reloaded.currentVersion?.parentId, 'ver-1');
  });

  test('a corrupted main file falls back to the backup copy', () async {
    await seedConversation(store);
    // Write a second time so a .bak exists.
    await seedConversation(store, title: '第二版标题');
    final file = File('${dir.path}${Platform.pathSeparator}conversations'
        '${Platform.pathSeparator}conv-seed.json');
    expect(file.existsSync(), isTrue);
    await file.writeAsString('{ this is not json');

    final loaded = await store.loadConversation('conv-seed');
    expect(loaded, isNotNull, reason: '损坏时应回退到 .bak，而不是丢掉整个会话');
  });

  test('missing conversation returns null instead of throwing', () async {
    await store.ensureLayout();
    expect(await store.loadConversation('nope'), isNull);
  });

  test('attachment text survives even if the source file is gone', () async {
    await store.ensureLayout();
    const attachment = Attachment(
      id: 'att-1',
      label: 'sample.txt',
      kind: 'file',
      originalPath: r'C:\moved\sample.txt',
      text: '实验要求：实现顺序表',
      byteLength: 30,
    );
    await store.saveAttachment(attachment);
    final loaded = await store.loadAttachment('att-1');
    expect(loaded, isNotNull);
    expect(loaded!.text, '实验要求：实现顺序表');
    expect(loaded.originalPath, r'C:\moved\sample.txt');
  });

  test('an old conversation without model fields still loads (follow the default)',
      () {
    // A 0.0.3 file: no `modelSelection`, no `modelSource`.
    final legacy = <String, dynamic>{
      'schemaVersion': 1,
      'id': 'conv-legacy',
      'title': '旧会话',
      'createdAt': '2026-10-01T09:00:00.000',
      'updatedAt': '2026-10-01T09:00:00.000',
      'currentVersionId': 'ver-legacy',
      'draftText': '',
      'chartMode': 'gantt',
      'messages': <dynamic>[],
      'attachments': <dynamic>[],
      'versions': <dynamic>[
        <String, dynamic>{
          'id': 'ver-legacy',
          'conversationId': 'conv-legacy',
          'revision': 3,
          'createdAt': '2026-10-01T09:00:00.000',
          'summary': '旧计划',
          'commitReason': 'initial',
          'tasks': <dynamic>[
            <String, dynamic>{
              'id': 'task-1',
              'name': '旧任务',
              'dependsOn': <dynamic>[],
              'preconditions': <dynamic>[],
              'steps': <dynamic>[],
              'estimatedHours': 1.0,
              'completion': 'done',
              'completionNote': null,
              'executionSignature': 'sig-old',
            },
          ],
          'notes': <dynamic>[],
          'removedCompleted': <dynamic>[],
          'reviewNotes': <dynamic>[],
        },
      ],
    };

    final conversation = Conversation.fromJson(legacy);

    expect(conversation.modelSelection, isNull,
        reason: '旧会话缺失选择时表示“跟随全局默认”，不能伪造一个连接');
    expect(conversation.chartMode, 'gantt');
    final version = conversation.versions.single;
    expect(version.modelSource, isNull, reason: '旧版本的来源未知，必须显示为未知');
    // Completion state must survive the schema extension untouched.
    expect(version.tasks.single.completion, Completion.done);
    expect(version.tasks.single.executionSignature, 'sig-old');
    expect(version.revision, 3);
  });

  test('modelSelection and modelSource round-trip through the store', () async {
    const selection = ModelSelection(
      profileId: 'deepseek-official',
      profileRevision: 4,
      modelId: 'deepseek-chat',
      thinking: ThinkingMode.enabled,
      reasoningEffort: ReasoningEffort.high,
    );
    const source = ModelSource(
      profileId: 'deepseek-official',
      profileRevision: 4,
      modelId: 'deepseek-chat',
      protocol: ProviderProtocol.deepseekChat,
      thinking: ThinkingMode.enabled,
      reasoningEffort: ReasoningEffort.high,
      endpointHost: 'api.deepseek.com',
    );
    final version = PlanVersion(
      id: 'ver-1',
      conversationId: 'conv-model',
      createdAt: DateTime(2026, 10, 17, 9),
      summary: '带来源的计划',
      modelSource: source,
    );
    final conversation = Conversation(
      id: 'conv-model',
      title: '带来源的计划',
      createdAt: DateTime(2026, 10, 17, 9),
      updatedAt: DateTime(2026, 10, 17, 9),
      versions: [version],
      currentVersionId: version.id,
      modelSelection: selection,
    );
    await store.saveConversation(conversation);

    final raw = jsonDecode(
      await File('${dir.path}${Platform.pathSeparator}conversations'
              '${Platform.pathSeparator}conv-model.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    expect(raw['modelSelection'], isA<Map<String, dynamic>>());
    final rawVersion =
        (raw['versions'] as List<dynamic>).single as Map<String, dynamic>;
    expect(rawVersion['modelSource'], isA<Map<String, dynamic>>());
    // Never a secret, only the endpoint host.
    expect(jsonEncode(rawVersion['modelSource']), isNot(contains('api_key')));

    final reloaded = await store.loadConversation('conv-model');
    expect(reloaded, isNotNull);
    expect(reloaded!.modelSelection, selection);
    expect(reloaded.currentVersion!.modelSource, source);
  });

  test('a half-written modelSelection falls back to null instead of crashing', () {
    final conversation = Conversation.fromJson(<String, dynamic>{
      'id': 'conv-broken',
      'title': '',
      'createdAt': '2026-10-01T09:00:00.000',
      'updatedAt': '2026-10-01T09:00:00.000',
      'modelSelection': <String, dynamic>{'thinking': 'enabled'},
      'versions': <dynamic>[],
    });
    expect(conversation.modelSelection, isNull);
  });

  test('binding a legacy conversation to a model keeps old version sources unknown',
      () async {
    final plan = samplePlan();
    final version = PlanVersion(
      id: 'ver-legacy',
      conversationId: 'conv-legacy',
      createdAt: DateTime(2026, 10, 1),
      summary: plan.summary,
      tasks: plan.tasks,
      notes: plan.notes,
    );
    const selection = ModelSelection(
      profileId: 'deepseek-official',
      profileRevision: 2,
      modelId: 'deepseek-chat',
      thinking: ThinkingMode.enabled,
      reasoningEffort: ReasoningEffort.high,
    );
    final conversation = Conversation(
      id: 'conv-legacy',
      title: plan.summary,
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
      versions: [version],
      currentVersionId: version.id,
    );
    await store.saveConversation(conversation);

    final loaded = (await store.loadConversation('conv-legacy'))!;
    expect(loaded.modelSelection, isNull);
    expect(loaded.versions.single.modelSource, isNull);

    // The one-time migration only writes the binding; it must not invent provenance for
    // versions that were produced before the source was recorded.
    await store.saveConversation(loaded.copyWith(modelSelection: selection));
    final rebound = (await store.loadConversation('conv-legacy'))!;
    expect(rebound.modelSelection, selection);
    expect(rebound.versions.single.id, 'ver-legacy');
    expect(rebound.versions.single.revision, 0);
    expect(rebound.versions.single.modelSource, isNull,
        reason: '一次性绑定不能改写历史版本的来源');
  });
}

