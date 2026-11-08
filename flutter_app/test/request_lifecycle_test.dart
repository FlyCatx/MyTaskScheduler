// 请求生命周期回归：占位标记必须按 conversationId + requestId 清理。
//
// 旧实现按“当前会话”清 pending：请求期间切换会话时，旧任务回调会清掉别的
// 会话（或新请求）的占位，崩溃恢复因此可能误判。任务 2 改为按身份清理。
//
// 说明：openConversation 会把“上个进程遗留”的 pending 主动清掉（防止 UI 永久
// 锁死），所以这里用未打开的会话验证清理函数的身份匹配与跨会话边界。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';

import 'support/test_support.dart';

Future<AppController> _controller(InMemorySessionRepository store) async {
  final controller = AppController(engine: FakeScheduleEngine(), store: store);
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

Conversation _withPending(Conversation c, String requestId) => c.copyWith(
      pendingRequest: PendingRequest(
        requestId: requestId,
        baseVersionId: c.currentVersion?.id,
        baseRevision: c.currentVersion?.revision ?? 0,
        startedAt: DateTime(2026, 11, 6, 10),
      ),
    );

Conversation _archived(Conversation c) =>
    c.copyWith(meta: c.meta.withArchived(DateTime(2026, 11, 6, 9)));

void main() {
  test('匹配的 requestId：清除磁盘里的 pending 占位', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    store.conversations['conv-seed'] =
        _archived(_withPending(store.conversations['conv-seed']!, 'req-A'));
    store.index = [
      for (final c in store.conversations.values) ConversationSummary.of(c),
    ];
    final controller = await _controller(store);

    await controller.clearPendingFor(
      conversationId: 'conv-seed',
      requestId: 'req-A',
    );

    expect(store.conversations['conv-seed']!.pendingRequest, isNull);
  });

  test('不匹配的 requestId：不清除别的新请求占位', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    store.conversations['conv-seed'] =
        _archived(_withPending(store.conversations['conv-seed']!, 'req-new'));
    store.index = [
      for (final c in store.conversations.values) ConversationSummary.of(c),
    ];
    final controller = await _controller(store);

    await controller.clearPendingFor(
      conversationId: 'conv-seed',
      requestId: 'req-old',
    );

    expect(store.conversations['conv-seed']!.pendingRequest?.requestId, 'req-new');
  });

  test('只清理目标会话，不按“当前会话”误改其他会话', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    await seedConversation(store, conversationId: 'conv-other', title: '另一个会话');
    store.conversations['conv-seed'] =
        _archived(_withPending(store.conversations['conv-seed']!, 'req-A'));
    store.conversations['conv-other'] =
        _archived(_withPending(store.conversations['conv-other']!, 'req-other'));
    store.index = [
      for (final c in store.conversations.values) ConversationSummary.of(c),
    ];
    final controller = await _controller(store);

    await controller.clearPendingFor(
      conversationId: 'conv-seed',
      requestId: 'req-A',
    );

    expect(store.conversations['conv-seed']!.pendingRequest, isNull);
    // 另一个会话的占位必须原样保留。
    expect(store.conversations['conv-other']!.pendingRequest?.requestId, 'req-other');
  });

  test('启动占位阻止并发启动第二次普通分析', () async {
    final store = InMemorySessionRepository();
    await seedConversation(store);
    final controller = await _controller(store);
    await controller.openConversation('conv-seed');
    await controller.updateDraft('请安排一次复习');

    // 第一个调用在第一个 await 前就占住启动位；第二个必须同步拒绝。
    final first = controller.startAnalysis();
    final second = controller.startAnalysis();
    expect(controller.errorMessage, contains('已有分析在进行中'));
    await second;
    await first;
    // 没有原生桥接：第一次调用最终报告桥接不可用，而不是并发写 pending。
    expect(controller.errorMessage, contains('原生桥接不可用'));
    expect(controller.conversation!.pendingRequest, isNull);
  });
}
