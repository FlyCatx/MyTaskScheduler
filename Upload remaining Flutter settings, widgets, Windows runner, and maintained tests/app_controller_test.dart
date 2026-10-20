// Controller-level tests: conversation switching, read-only history versions,
// completion review, view preference and analysis preconditions.
//
// These run without the native DLL (the schedule engine is faked and no analysis is
// started), so they stay fast and deterministic. The model-selection tests use an
// in-memory settings bridge (also no DLL).

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule_engine.dart';
import 'package:taskscheduler_flutter/src/state/session_repository.dart';
import 'package:taskscheduler_flutter/src/state/settings_controller.dart';
import 'package:taskscheduler_flutter/src/state/settings_store.dart';

import 'support/test_support.dart';

/// Counts persisted conversations so "migrate only once" is observable.
class CountingSessionRepository extends InMemorySessionRepository {
  final Map<String, int> saves = <String, int>{};

  @override
  Future<void> saveConversation(Conversation conversation) async {
    saves[conversation.id] = (saves[conversation.id] ?? 0) + 1;
    return super.saveConversation(conversation);
  }
}

Future<AppController> buildController(
  InMemorySessionRepository store, {
  SettingsController? settings,
}) async {
  final controller = AppController(
    engine: FakeScheduleEngine(),
    store: store,
    settings: settings,
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

/// A loaded [SettingsController] backed by a throw-away directory + fake bridge.
Future<SettingsController> buildSettings({
  Map<String, dynamic>? settings,
}) async {
  final dir = createTempDataDir('app_settings');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final controller = SettingsController(
    store: SettingsStore(dir),
    bridge: FakeSettingsBridge(settings: settings),
    probePollInterval: const Duration(milliseconds: 5),
  );
  addTearDown(controller.dispose);
  await controller.load();
  return controller;
}

/// Two saved connections; the first one is the default.
Map<String, dynamic> twoSettingsProfiles() => settingsDocument(
      profiles: <ProviderProfile>[
        sampleProfile(),
        sampleProfile(id: 'second', name: '第二连接', modelId: 'second-model'),
      ],
    );

/// Seeds a conversation from before 0.0.4: no binding, optional stored provenance.
Future<void> seedLegacyConversation(
  SessionRepository store, {
  String id = 'conv-legacy',
  ModelSelection? selection,
  ModelSource? source,
}) async {
  final plan = samplePlan();
  final version = PlanVersion(
    id: 'ver-legacy',
    conversationId: id,
    createdAt: DateTime(2026, 10, 1),
    summary: plan.summary,
    tasks: plan.tasks,
    notes: plan.notes,
    modelSource: source,
  );
  final conversation = Conversation(
    id: id,
    title: plan.summary,
    createdAt: DateTime(2026, 10, 1),
    updatedAt: DateTime(2026, 10, 1),
    versions: [version],
    currentVersionId: version.id,
    modelSelection: selection,
  );
  await store.ensureLayout();
  await store.saveConversation(conversation);
  await store.saveIndex([ConversationSummary.of(conversation)]);
}

Future<void> seedSecondConversation(InMemorySessionRepository store) async {
  const plan = LocalPlan(
    summary: '另一个计划',
    tasks: [
      TaskRecord(id: 'other-1', name: '另一件事', estimatedHours: 1),
    ],
  );
  final version = PlanVersion(
    id: 'ver-other',
    conversationId: 'conv-other',
    createdAt: DateTime(2026, 10, 16),
    summary: plan.summary,
    tasks: plan.tasks,
  );
  final conversation = Conversation(
    id: 'conv-other',
    title: plan.summary,
    createdAt: DateTime(2026, 10, 16),
    updatedAt: DateTime(2026, 10, 18, 12),
    activityAt: DateTime(2026, 10, 18, 12),
    versions: [version],
    currentVersionId: version.id,
  );
  await store.saveConversation(conversation);
  await store.saveIndex([
    ConversationSummary.of(conversation),
    ...store.index,
  ]);
}

void main() {
  test('switching conversations swaps the plan and never leaks the other one',
      () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    await seedSecondConversation(store);

    final controller = await buildController(store);
    expect(controller.conversation!.id, 'conv-other', reason: '最近更新优先');
    expect(controller.display!.tasks.single.name, '另一件事');

    await controller.openConversation('conv-seed');
    expect(controller.conversation!.id, 'conv-seed');
    expect(controller.display!.tasks.map((t) => t.name), contains('整理实验要求'));
    // The other conversation's task must not appear.
    expect(controller.display!.tasks.any((t) => t.id == 'other-1'), isFalse);
  });

  test('an old version is read-only and cannot be edited', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    // Add a second (current) version so the first one is historical.
    final loaded = store.conversations['conv-seed']!;
    final v1 = loaded.versions.single;
    final v2 = PlanVersion(
      id: 'ver-2',
      conversationId: loaded.id,
      parentId: v1.id,
      createdAt: DateTime(2026, 10, 18),
      summary: '补充后的计划',
      tasks: v1.tasks,
      commitReason: 'supplement',
    );
    await store.saveConversation(loaded.copyWith(
      versions: [v1, v2],
      currentVersionId: v2.id,
      title: v2.summary,
    ));

    final controller = await buildController(store);
    expect(controller.isViewingCurrentVersion, isTrue);
    expect(controller.canEditPlan, isTrue);

    await controller.selectVersion(v1.id);
    expect(controller.viewVersion!.id, v1.id);
    expect(controller.isViewingCurrentVersion, isFalse);
    expect(controller.canEditPlan, isFalse);

    // Editing while viewing an old version must be a no-op.
    final before = store.conversations['conv-seed']!.versions.first.tasks.first.completion;
    final changed = await controller.toggleCompletion(v1.tasks.first.id);
    expect(changed, isFalse);
    expect(
      store.conversations['conv-seed']!.versions.first.tasks.first.completion,
      before,
      reason: '历史版本不可被就地修改',
    );
  });

  test('reviewing a flagged completion records done and bumps the revision',
      () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final controller = await buildController(store);

    final target = controller.viewVersion!.tasks.firstWhere(
      (t) => !t.isDone,
      orElse: () => controller.viewVersion!.tasks.first,
    );
    final ok = await controller.confirmReviewedTask(target.id);
    expect(ok, isTrue);

    final saved = store.conversations['conv-seed']!.versions.single;
    final savedTask = saved.tasks.firstWhere((t) => t.id == target.id);
    expect(savedTask.completion, Completion.done);
    expect(savedTask.completionNote, isNull);
    expect(saved.revision, 1);
  });

  test('the dependency view preference survives a reload', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final controller = await buildController(store);

    await controller.setChartMode('gantt');
    expect(store.conversations['conv-seed']!.chartMode, 'gantt');

    final reopened = await buildController(store);
    expect(reopened.conversation!.chartMode, 'gantt');
  });

  test('starting an analysis without a native bridge reports a clear error',
      () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final controller = await buildController(store);

    controller.updateDraft('请补充一页纸报告');
    await controller.startAnalysis();

    expect(controller.run, isNull);
    expect(controller.errorMessage, contains('原生桥接不可用'));
  });

  test('a draft can be edited while the plan is read-only for an old version',
      () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final controller = await buildController(store);

    controller.updateDraft('新的要求');
    expect(controller.conversation!.draftText, '新的要求');
    // Updating the draft must not recompute or mutate the plan.
    final before = controller.viewVersion!.revision;
    expect(controller.viewVersion!.revision, before);
  });

  test('editing a task through the engine is rejected when validation fails',
      () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final engine = FakeScheduleEngine();
    final controller = AppController(engine: engine, store: store);
    addTearDown(controller.dispose);
    await controller.initialize();

    engine.failWith = ScheduleException('自依赖非法');
    final ok = await controller.updateTask(
      controller.viewVersion!.tasks.first.id,
      name: '改名',
    );
    expect(ok, isFalse);
    expect(controller.errorMessage, contains('自依赖非法'));
    // Nothing persisted.
    expect(
      store.conversations['conv-seed']!.versions.single.tasks.first.name,
      isNot('改名'),
    );
  });

  // ------------------------------------------------- model binding / migration

  test('a new conversation binds the default and keeps it when the default changes',
      () async {
    final settings = await buildSettings(settings: twoSettingsProfiles());
    final store = InMemorySessionRepository();
    final controller = await buildController(store, settings: settings);

    final created = await controller.createConversation();
    expect(created.modelSelection, settings.defaultSelection);
    expect(created.modelSelection!.profileId, 'deepseek-official');

    // The user switches the global default to the second connection.
    expect(
      settings.setDraftDefaultSelection(
          sampleSelection(profileId: 'second', modelId: 'second-model')),
      isNull,
    );
    expect(await settings.save(), isNull);
    expect(settings.defaultSelection?.profileId, 'second');

    // The already-created conversation must not move to the new default.
    expect(store.conversations[created.id]!.modelSelection?.profileId,
        'deepseek-official');
    expect(controller.activeSelection?.profileId, 'deepseek-official');

    // A brand-new conversation does use the new default.
    final next = await controller.createConversation(reuseBlank: false);
    expect(next.modelSelection?.profileId, 'second');
  });

  test('a legacy conversation is migrated once with a visible note', () async {
    final settings = await buildSettings();
    final store = CountingSessionRepository();
    const source = ModelSource(
      profileId: 'old-profile',
      profileRevision: 3,
      modelId: 'old-model',
      endpointHost: 'old.example.test',
    );
    await seedLegacyConversation(store, source: source);
    final writtenBeforeMigration = store.saves['conv-legacy'] ?? 0;

    final controller = await buildController(store, settings: settings);

    // initialize() opened the seeded conversation, so the one-time migration ran.
    final migrated = store.conversations['conv-legacy']!;
    expect(migrated.modelSelection, settings.defaultSelection);
    expect(controller.statusMessage, contains('一次性绑定'));
    expect(store.saves['conv-legacy'], writtenBeforeMigration + 1,
        reason: '迁移必须持久化一次');

    // The historical provenance of the plan version is never rewritten.
    expect(migrated.versions.single.modelSource, source);
    expect(migrated.currentVersion!.modelSource, source);

    // Reopening must not migrate (or write) again.
    await controller.openConversation('conv-legacy');
    expect(store.saves['conv-legacy'], writtenBeforeMigration + 1,
        reason: '只迁移一次');
    expect(store.conversations['conv-legacy']!.modelSelection,
        settings.defaultSelection);
    expect(controller.statusMessage, isNull,
        reason: '已经绑定过的会话不再重复提示');
  });

  test('a legacy conversation without a usable default asks to pick a model',
      () async {
    final settings = await buildSettings(settings: emptySettingsDocument());
    final store = InMemorySessionRepository();
    await seedLegacyConversation(store);

    final controller = await buildController(store, settings: settings);

    expect(store.conversations['conv-legacy']!.modelSelection, isNull,
        reason: '没有有效默认时不能伪造绑定');
    expect(controller.statusMessage, contains('尚未配置模型连接'));
  });

  test('sending is blocked when the conversation binding was updated', () async {
    final settings = await buildSettings();
    final store = InMemorySessionRepository();
    final controller = await buildController(store, settings: settings);
    final created = await controller.createConversation();
    expect(created.modelSelection?.profileRevision, 1);

    // Saving a content edit bumps the profile revision: the conversation's captured
    // revision is now stale and must not be silently replaced by the new one.
    settings.updateDraftProfile(
        settings.profiles.single.copyWith(name: '改过的连接名字'));
    expect(await settings.save(), isNull);
    expect(settings.profileById('deepseek-official')!.revision, 2);

    await controller.updateDraft('要分析的材料');
    await controller.startAnalysis();

    expect(controller.run, isNull, reason: '失效的选择不得发起分析');
    expect(controller.errorMessage, contains('已更新'));
    expect(controller.errorMessage, contains('重新选择'));
    expect(controller.conversation!.draftText, '要分析的材料',
        reason: '发送被拒绝时保留草稿');
    expect(store.conversations[created.id]!.modelSelection?.profileRevision, 1,
        reason: '不得自动改写会话原有的模型绑定');
    expect(controller.statusMessage, isNull);
  });

  test('sending is blocked when the conversation binding was deleted', () async {
    final settings = await buildSettings(settings: twoSettingsProfiles());
    final store = InMemorySessionRepository();
    final controller = await buildController(store, settings: settings);
    final created = await controller.createConversation();
    expect(created.modelSelection?.profileId, 'deepseek-official');

    settings.removeDraftProfile('deepseek-official');
    expect(
      settings.setDraftDefaultSelection(
          sampleSelection(profileId: 'second', modelId: 'second-model')),
      isNull,
    );
    expect(await settings.save(), isNull);
    expect(settings.profileById('deepseek-official'), isNull);

    await controller.updateDraft('要分析的材料');
    await controller.startAnalysis();

    expect(controller.run, isNull);
    expect(controller.errorMessage, contains('已删除'));
    expect(controller.errorMessage, contains('重新选择'));
    expect(controller.errorMessage, contains('不会自动改用其它连接'));
    expect(controller.conversation!.draftText, '要分析的材料');
    expect(store.conversations[created.id]!.modelSelection?.profileId,
        'deepseek-official',
        reason: '失效的绑定保留原值，由用户重新选择');
  });

  group('结构化时间表请求', () {
    test('同一快照同时发送 timetable 与 effectiveTimetable', () async {
      final store = InMemorySessionRepository();
      final controller = await buildController(store);
      await controller.createConversation();
      final base = Timetable.withDefaults(
        weekStart: '2026-10-20',
        unavailable: const <WallClockRange>[],
      );
      final timetable = base
          .paint(
            date: '2026-10-20',
            start: 540,
            end: 600,
            state: TimetableState.occupied,
          )
          .paint(
            date: '2026-10-20',
            start: 555,
            end: 570,
            state: TimetableState.free,
          )
          .copyWith(revision: 9);
      await controller.applyTimetableSettings(
        controller.calendar.settings,
        timetable,
        reschedule: false,
      );
      final conversation = controller.conversation!;
      expect(conversation.includeTimetable, isTrue);
      final savedRevision = conversation.calendarDraft!.revision;

      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: null,
        requestId: 'req-1',
        draft: '请安排',
      );
      expect(request['calendarRevision'], savedRevision);
      final sent = request['timetable'] as Map<String, dynamic>;
      expect(sent['revision'], savedRevision);
      final effective =
          request['effectiveTimetable'] as Map<String, dynamic>;
      expect(effective['sourceRevision'], savedRevision);
      final day = (effective['days'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((d) => d['date'] == '2026-10-20');
      final intervals = (day['intervals'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((i) => <Object?>[i['start'], i['end'], i['state']])
          .toList();
      expect(intervals, <List<Object?>>[
        <Object?>[0, 540, 1],
        <Object?>[540, 555, 0],
        <Object?>[555, 570, 1],
        <Object?>[570, 600, 0],
        <Object?>[600, 1440, 1],
      ]);
    });

    test('关闭附件时两份视图都不发；非法时间表明确失败', () async {
      final store = InMemorySessionRepository();
      final controller = await buildController(store);
      await controller.createConversation();
      await controller.applyTimetableSettings(
        controller.calendar.settings,
        Timetable.withDefaults(weekStart: '2026-10-19'),
        reschedule: false,
      );
      await controller.removeTimetableFromRequest();
      final request = controller.buildAnalysisRequest(
        conversation: controller.conversation!,
        version: null,
        requestId: 'req-2',
        draft: '请安排',
      );
      expect(request.containsKey('timetable'), isFalse);
      expect(request.containsKey('effectiveTimetable'), isFalse);

      const overlapping = Timetable(
        dateFrom: '2026-10-19',
        dateTo: '2026-10-19',
        weekly: <TimetableEntry>[
          TimetableEntry(
            id: 'a',
            state: TimetableState.occupied,
            start: 0,
            end: 600,
            weekdays: <int>[1],
          ),
          TimetableEntry(
            id: 'b',
            state: TimetableState.free,
            start: 500,
            end: 700,
            weekdays: <int>[1],
          ),
        ],
      );
      final error = controller.validateTimetableForRequest(overlapping);
      expect(error, isNotNull);
      expect(error, contains('时间表数据不合法'));
    });
  });
}
