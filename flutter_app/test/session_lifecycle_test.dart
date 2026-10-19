import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';

import 'support/test_support.dart';

Conversation _conversation(
  String id, {
  String title = '自动标题',
  String? customTitle,
  DateTime? activity,
  List<Attachment> attachments = const [],
}) {
  final at = activity ?? DateTime(2026, 10, 18, 10);
  return Conversation(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    activityAt: at,
    attachments: attachments,
    meta: ConversationMeta(customTitle: customTitle),
  );
}

void main() {
  group('ConversationMeta', () {
    test('manual title wins until explicitly cleared', () {
      final c = _conversation('c1', title: '模型摘要', customTitle: '我的名字');
      expect(c.listTitle, '我的名字');
      final renamed = c.copyWith(title: '重新分析后的摘要');
      expect(renamed.listTitle, '我的名字',
          reason: '重新分析/切换版本不能覆盖手动标题');
      expect(renamed.copyWith(meta: renamed.meta.rename('')).listTitle,
          '重新分析后的摘要');
    });

    test('pin/archive/delete JSON round-trips and trash restore keeps pin', () {
      final meta = ConversationMeta(
        customTitle: '标题',
        pinOrder: 3,
        archivedAt: DateTime.utc(2026, 10, 18, 9),
        deletedAt: DateTime.utc(2026, 10, 18, 10),
      );
      final back = ConversationMeta.fromJson(meta.toJson());
      expect(back.customTitle, '标题');
      expect(back.pinOrder, 3);
      expect(back.archivedAt, DateTime.utc(2026, 10, 18, 9));
      expect(back.deletedAt, DateTime.utc(2026, 10, 18, 10));
      expect(back.isDeleted, isTrue);
      final restored = back.restoreDeleted();
      expect(restored.isDeleted, isFalse);
      expect(restored.pinOrder, 3);
      expect(restored.archivedAt, DateTime.utc(2026, 10, 18, 9));
    });

    test('old JSON without metadata uses safe defaults', () {
      final c = Conversation.fromJson(<String, dynamic>{
        'id': 'old',
        'title': '旧会话',
        'createdAt': '2026-10-01T00:00:00.000',
        'updatedAt': '2026-10-01T00:00:00.000',
        'versions': <dynamic>[],
      });
      expect(c.meta.customTitle, isNull);
      expect(c.meta.isPinned, isFalse);
      expect(c.meta.isArchived, isFalse);
      expect(c.meta.isDeleted, isFalse);
      expect(c.activityAt, c.updatedAt);
      expect(c.listTitle, '旧会话');
    });
  });

  group('SessionStore lifecycle', () {
    late Directory dir;
    late SessionStore store;

    setUp(() async {
      dir = createTempDataDir('lifecycle');
      store = SessionStore(dir);
      await store.ensureLayout();
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('tombstone prevents a .bak fallback from resurrecting a deleted id',
        () async {
      final c = _conversation('conv-delete');
      await store.saveConversation(c);
      // Second write creates the .bak that used to be a resurrection path.
      await store.saveConversation(c.copyWith(title: '改过'));
      expect(File('${dir.path}/conversations/conv-delete.json.bak').existsSync(),
          isTrue);

      await store.markDeleted('conv-delete');
      await store.deleteConversation('conv-delete');
      await store.saveIndex([ConversationSummary.of(c)]);

      final reopened = SessionStore(dir);
      expect((await reopened.loadIndex()).map((s) => s.id),
          isNot(contains('conv-delete')));
      expect(await reopened.loadTombstones(), contains('conv-delete'));
      expect(
          File('${dir.path}/conversations/conv-delete.json.bak').existsSync(),
          isFalse,
          reason: '永久删除必须清理 .bak');
    });

    test('unknown future schema is refused instead of silently downgraded',
        () async {
      final index = File('${dir.path}/index.json');
      final original = jsonEncode(<String, dynamic>{
        'schemaVersion': 99,
        'conversations': <dynamic>[],
      });
      await index.writeAsString(original);
      await expectLater(
        store.loadIndex(),
        throwsA(isA<SessionFormatException>()),
      );
      expect(await index.readAsString(), original,
          reason: '读取失败不得改写文件');
    });

    test('attachment pruning keeps every referenced conversation, including trash',
        () async {
      const a = Attachment(
          id: 'att-a', label: 'a.txt', kind: 'text', text: 'A', byteLength: 1);
      const b = Attachment(
          id: 'att-b', label: 'b.txt', kind: 'text', text: 'B', byteLength: 1);
      final live = _conversation('live', attachments: const [a]);
      final trashed = _conversation('trash', attachments: [b]).copyWith(
          meta: const ConversationMeta(deletedAt: null));
      await store.saveAttachment(a);
      await store.saveAttachment(b);
      await store.saveConversation(live);
      await store.saveConversation(trashed);
      final removed = await store.pruneAttachments(
          await store.referencedAttachmentIds());
      expect(removed, isEmpty);
      expect(await store.loadAttachment('att-a'), isNotNull);
      expect(await store.loadAttachment('att-b'), isNotNull);
    });
  });

  group('AppController conversation lifecycle', () {
    test('rename/archive/trash/restore survive a restart and keep order hints',
        () async {
      final dir = createTempDataDir('lifecycle-controller');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = SessionStore(dir);
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final first = await controller.createConversation(reuseBlank: false);
      await controller.renameConversation(first.id, '手写标题');
      await controller.setPinned(first.id, true);
      final second = await controller.createConversation(reuseBlank: false);
      await controller.updateDraft('第二会话的材料');
      await controller.setArchived(second.id, true);

      expect(controller.visibleSummaries.map((s) => s.id), contains(first.id));
      expect(controller.archivedSummaries.map((s) => s.id), contains(second.id));
      expect(controller.searchSummaries('手写').single.id, first.id);
      expect(
          controller.searchSummaries('新会话', archived: true)
              .map((s) => s.id),
          contains(second.id));

      await controller.moveToTrash(first.id);
      expect(controller.trashedSummaries.map((s) => s.id), contains(first.id));
      expect(controller.visibleSummaries.map((s) => s.id),
          isNot(contains(first.id)));
      await controller.restoreFromTrash(first.id);
      expect(controller.visibleSummaries.map((s) => s.id), contains(first.id));
      final restored = controller.summaries.firstWhere((s) => s.id == first.id);
      expect(restored.isPinned, isTrue, reason: '恢复后保留此前置顶状态');
      expect(restored.displayTitle, '手写标题');

      final reopened = AppController(engine: FakeScheduleEngine(), store: store);
      addTearDown(reopened.dispose);
      await reopened.initialize();
      final reloaded = reopened.summaries.firstWhere((s) => s.id == first.id);
      expect(reloaded.displayTitle, '手写标题');
      expect(reloaded.isPinned, isTrue);
      expect(reopened.archivedSummaries.map((s) => s.id), contains(second.id));
    });

    test('switching the dependency view does not reorder recent conversations',
        () async {
      final store = InMemorySessionRepository();
      final older = _conversation('older',
          activity: DateTime(2026, 10, 17, 10));
      final newer = _conversation('newer',
          activity: DateTime(2026, 10, 18, 10));
      await store.saveConversation(older);
      await store.saveConversation(newer);
      await store.saveIndex(
          [ConversationSummary.of(older), ConversationSummary.of(newer)]);
      final controller = AppController(
          engine: FakeScheduleEngine(), store: store);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.summaries.first.id, 'newer');
      await controller.openConversation('older');
      final before = controller.summaries.map((s) => s.id).toList();
      await controller.setChartMode('gantt');
      expect(controller.summaries.map((s) => s.id).toList(), before,
          reason: '切换图表不是内容活动，不得挤乱最近列表');
    });

    test('permanent delete removes payload and is not resurrected by .bak',
        () async {
      final dir = createTempDataDir('permanent');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = SessionStore(dir);
      final controller = AppController(
          engine: FakeScheduleEngine(), store: store);
      addTearDown(controller.dispose);
      await controller.initialize();
      final c = await controller.createConversation(reuseBlank: false);
      await store.saveConversation(
          (await store.loadConversation(c.id))!.copyWith(title: '触发备份'));
      await controller.renameConversation(c.id, '要删除的会话');
      expect(await controller.permanentlyDelete(c.id), isTrue);

      final reopened = AppController(
          engine: FakeScheduleEngine(), store: SessionStore(dir));
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.summaries.map((s) => s.id), isNot(contains(c.id)));
      expect(File('${dir.path}/conversations/${c.id}.json').existsSync(), isFalse);
      expect(File('${dir.path}/conversations/${c.id}.json.bak').existsSync(),
          isFalse);
      expect(await store.loadTombstones(), contains(c.id));
    });
  });
}

