// 提交结果回归：成功必须有本次新增版本；拒绝/写入失败不能触碰磁盘与内存版本。
//
// 覆盖任务 1：PlanCommitResult 的 committed / rejected / failed 三种出口，
// 以及“先校验、后落盘、最后发布内存”的顺序和索引写失败的可恢复提示。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/commit_gate.dart';
import 'package:taskscheduler_flutter/src/state/schedule_engine.dart';

import 'support/test_support.dart';

class _FailingStore extends InMemorySessionRepository {
  bool failConversationWrites = false;
  bool failIndexWrites = false;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    if (failConversationWrites) throw StateError('disk full');
    await super.saveConversation(conversation);
  }

  @override
  Future<void> saveIndex(List<ConversationSummary> conversations) async {
    if (failIndexWrites) throw StateError('index write failed');
    await super.saveIndex(conversations);
  }
}

AnalyzeOutcome _outcome(List<Map<String, dynamic>> tasks) => AnalyzeOutcome(
      ok: true,
      plan: <String, dynamic>{
        'tasks': tasks,
        'notes': <dynamic>[],
      },
      elapsedMs: 1,
      httpStatus: 200,
    );

final List<Map<String, dynamic>> _oneTask = <Map<String, dynamic>>[
  <String, dynamic>{'id': 'm1', 'name': '写实验报告', 'estimatedHours': 2},
];

class _Fixture {
  _Fixture(this.store, this.engine, this.controller, this.ticket);
  final _FailingStore store;
  final FakeScheduleEngine engine;
  final AppController controller;
  final RequestTicket ticket;
}

Future<_Fixture> _fixture({String? baseVersionId = 'ver-1'}) async {
  final store = _FailingStore();
  await seedConversation(store);
  final engine = FakeScheduleEngine();
  final controller = AppController(engine: engine, store: store);
  await controller.initialize();
  expect(controller.conversation?.id, 'conv-seed');
  final ticket = controller.gate.begin(
    conversationId: 'conv-seed',
    requestId: 'req-test',
    baseVersionId: baseVersionId,
    baseRevision: 0,
    calendarRevision: 0,
  );
  addTearDown(controller.dispose);
  return _Fixture(store, engine, controller, ticket);
}

void main() {
  test('正常提交：返回本次新增版本 id，磁盘与内存同时更新', () async {
    final f = await _fixture();
    final before = f.controller.conversation!.versions.length;
    final result = await f.controller.commitAnalysisResult(
      f.ticket,
      _outcome(_oneTask),
      f.controller.conversation!.draftText,
    );

    expect(result.status, PlanCommitStatus.committed);
    expect(result.ok, isTrue);
    expect(result.versionId, isNotNull);
    expect(result.warning, isNull);
    expect(f.engine.computeCalls, greaterThan(0));

    final memory = f.controller.conversation!;
    expect(memory.versions.length, before + 1);
    expect(memory.currentVersionId, result.versionId);
    expect(memory.currentVersion!.parentId, 'ver-1');
    final persisted = f.store.conversations['conv-seed']!;
    expect(persisted.versions.length, before + 1);
    expect(persisted.currentVersionId, result.versionId);
    expect(f.controller.viewVersion?.id, result.versionId);
  });

  test('空任务：提交门拒绝，版本与存储均不变', () async {
    final f = await _fixture();
    final before = f.controller.conversation!.versions.length;
    final result = await f.controller.commitAnalysisResult(
      f.ticket,
      _outcome(<Map<String, dynamic>>[]),
      '',
    );
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.versionId, isNull);
    expect(f.controller.conversation!.versions.length, before);
    expect(f.store.conversations['conv-seed']!.versions.length, before);
  });

  test('取消后的结果不能提交', () async {
    final f = await _fixture();
    f.ticket.cancelled = true;
    final result = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('取消'));
    expect(f.controller.conversation!.versions.length, 1);
  });

  test('基础版本已变化：拒绝且不生成新版本', () async {
    final f = await _fixture(baseVersionId: null);
    final before = f.controller.conversation!.versions.length;
    final result = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('过期'));
    expect(f.controller.conversation!.versions.length, before);
  });

  test('时间表 revision 变化：拒绝迟到结果', () async {
    final f = await _fixture();
    final ticket = f.controller.gate.activeFor('conv-seed')!;
    final stale = f.controller.gate;
    stale.finish(ticket);
    final retry = f.controller.gate.begin(
      conversationId: 'conv-seed',
      requestId: 'req-2',
      baseVersionId: 'ver-1',
      baseRevision: 0,
      calendarRevision: 99,
    );
    final result = await f.controller.commitAnalysisResult(retry, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('时间表'));
    expect(f.controller.conversation!.versions.length, 1);
  });

  test('外部日历指纹变化：拒绝迟到结果', () async {
    final f = await _fixture();
    final result = await f.controller.commitAnalysisResult(
      f.ticket,
      _outcome(_oneTask),
      '',
      externalFingerprint: 'fp-changed',
    );
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('外部日历'));
  });

  test('已归档会话：拒绝并保留原计划', () async {
    final store = _FailingStore();
    await seedConversation(store);
    final conv = store.conversations['conv-seed']!;
    store.conversations['conv-seed'] =
        conv.copyWith(meta: conv.meta.withArchived(DateTime.now()));
    final controller = AppController(engine: FakeScheduleEngine(), store: store);
    await controller.initialize();
    addTearDown(controller.dispose);
    final ticket = controller.gate.begin(
      conversationId: 'conv-seed',
      requestId: 'req-archived',
      baseVersionId: 'ver-1',
      baseRevision: 0,
    );
    final result = await controller.commitAnalysisResult(ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('归档'));
    expect(store.conversations['conv-seed']!.versions.length, 1);
  });

  test('C 本地校验失败：failed，且不写存储、不发布内存版本', () async {
    final f = await _fixture();
    f.engine.failWith = ScheduleException('任务依赖成环');
    final result = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.failed);
    expect(result.message, contains('计划校验失败'));
    expect(result.versionId, isNull);
    expect(f.controller.conversation!.versions.length, 1);
    expect(f.store.conversations['conv-seed']!.versions.length, 1);
  });

  test('会话文件写入失败：failed，内存版本不前进', () async {
    final f = await _fixture();
    f.store.failConversationWrites = true;
    final result = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.failed);
    expect(result.message, contains('未能写入'));
    expect(f.controller.conversation!.versions.length, 1);
  });

  test('会话已写入但索引失败：committed + 可恢复 warning', () async {
    final f = await _fixture();
    f.store.failIndexWrites = true;
    final result = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(result.status, PlanCommitStatus.committed);
    expect(result.versionId, isNotNull);
    expect(result.warning, isNotNull);
    final persisted = f.store.conversations['conv-seed']!;
    expect(persisted.currentVersionId, result.versionId);
    expect(f.controller.conversation!.currentVersionId, result.versionId);
  });

  test('同一票据重复提交：第二次拒绝，只新增一个版本', () async {
    final f = await _fixture();
    final first = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(first.status, PlanCommitStatus.committed);
    final second = await f.controller.commitAnalysisResult(f.ticket, _outcome(_oneTask), '');
    expect(second.status, PlanCommitStatus.rejected);
    expect(f.controller.conversation!.versions.length, 2);
    expect(f.store.conversations['conv-seed']!.versions.length, 2);
  });
}
