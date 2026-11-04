// 协议 v2 请求与草稿持久化的回归测试。
//
// 这里不启动网络：正式请求被抽成 buildAnalysisRequest，测试直接断言字段与身份；
// 草稿测试使用内存仓储，验证防抖 flush、切换会话和重新加载。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';

import 'support/test_support.dart';

PlanVersion _version({Timetable? timetable, List<TaskRecord>? tasks}) {
  final clock = const WallClock(480);
  final day = clock.dayStartUtcForDateKey('2026-10-19');
  return PlanVersion(
    id: 'ver-2',
    conversationId: 'conv-protocol',
    revision: 3,
    createdAt: DateTime.utc(2026, 10, 19),
    summary: '交付报告',
    tasks: tasks ??
        <TaskRecord>[
          const TaskRecord(
            id: 'T1',
            name: '写报告',
            estimatedHours: 2,
          ),
        ],
    calendar: CalendarSchedule(
      settings: CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
        weekly: WeeklyAvailability({
          for (var d = 1; d <= 7; d++) d: const [WallClockRange(480, 720)],
        }),
      ),
      segments: <ScheduleSegment>[
        ScheduleSegment(
          id: 'seg-manual',
          taskId: 'T1',
          start: day.add(const Duration(minutes: 600)),
          end: day.add(const Duration(minutes: 660)),
          source: SegmentSource.manual,
        ),
      ],
    ),
    timetable: timetable ??
        Timetable.withDefaults(weekStart: '2026-10-19', revision: 5),
  );
}

Conversation _conversation(PlanVersion version,
    {bool includeTimetable = true}) {
  return Conversation(
    id: 'conv-protocol',
    title: '交付报告',
    createdAt: DateTime.utc(2026, 10, 19),
    updatedAt: DateTime.utc(2026, 10, 19),
    versions: <PlanVersion>[version],
    currentVersionId: version.id,
    includeTimetable: includeTimetable,
  );
}

void main() {
  group('正式分析请求', () {
    test('携带 schemaVersion/context/timetable/knownTasks，并保留原有字段', () {
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
      );
      final version = _version();
      final conversation = _conversation(version);
      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: version,
        requestId: 'req-1',
        draft: '周二 11:00-12:00 空闲',
        planContext: '总结：交付报告',
      );

      expect(request['requestSchemaVersion'], 2);
      expect(request['conversationId'], 'conv-protocol');
      expect(request['requestId'], 'req-1');
      expect(request['baseVersionId'], 'ver-2');
      expect(request['baseRevision'], 3);
      expect(request['calendarRevision'], 5);

      final context = request['context'] as Map<String, dynamic>;
      expect(WallClock.formatDateKey(0, 1, 1), isNotEmpty);
      expect(context['timezoneId'], 'Asia/Shanghai');
      expect(context['timezoneOffsetMinutes'], 480);
      expect(context['currentDate'], isA<String>());

      final timetable = request['timetable'] as Map<String, dynamic>;
      expect(timetable['schemaVersion'], 2);
      expect((timetable['coverage'] as Map<String, dynamic>)['dateFrom'],
          '2026-10-19');

      final known = (request['knownTasks'] as List<dynamic>).single
          as Map<String, dynamic>;
      expect(known['id'], 'T1');
      expect(known['estimatedMinutes'], 120);
      expect(request['sources'], isA<List<dynamic>>());
      expect(request['planContext'], '总结：交付报告');
    });

    test('移除请求附带时间表后不再发送 timetable，但版本数据仍在', () {
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
      );
      final version = _version();
      final conversation = _conversation(version, includeTimetable: false);
      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: version,
        requestId: 'req-2',
        draft: '材料',
      );
      expect(request.containsKey('timetable'), isFalse);
      expect(version.timetable, isNotNull);
    });

    test('空会话草稿时间表也会随请求发送', () {
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: InMemorySessionRepository(),
      );
      final draft = Timetable.withDefaults(weekStart: '2026-10-19', revision: 1);
      final conversation = Conversation(
        id: 'conv-empty',
        title: '',
        createdAt: DateTime.utc(2026, 10, 19),
        updatedAt: DateTime.utc(2026, 10, 19),
        calendarDraft: draft,
      );
      final request = controller.buildAnalysisRequest(
        conversation: conversation,
        version: null,
        requestId: 'req-3',
        draft: '',
      );
      expect(request['calendarRevision'], 1);
      expect((request['timetable'] as Map<String, dynamic>)['revision'], 1);
      expect(request.containsKey('knownTasks'), isFalse);

      // 只有时间表时 C 仍需要至少一个来源：请求会带一条明确的数据占位，
      // 不是伪造成用户原文。
      final sources = request['sources'] as List<dynamic>;
      expect(sources, isNotEmpty);
      expect((sources.single as Map<String, dynamic>)['text'],
          contains('仅含已提交的结构化时间表'));
    });
  });

  group('草稿持久化', () {
    test('updateDraft 后 flush，重新加载仍能看到内容', () async {
      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          AppController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      await controller.updateDraft('防抖窗口里的草稿');
      await controller.flushPendingWrites();
      controller.dispose();

      final reloaded = await store.loadConversation('conv-seed');
      expect(reloaded!.draftText, '防抖窗口里的草稿');
    });

    test('切换会话先 flush 当前草稿，再打开另一个会话', () async {
      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          AppController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      await controller.updateDraft('切换前的内容');
      final other = await controller.createConversation();
      expect(other.id, isNot('conv-seed'));
      await controller.openConversation('conv-seed');
      expect(controller.conversation!.draftText, '切换前的内容');

      final reloaded = await store.loadConversation('conv-seed');
      expect(reloaded!.draftText, '切换前的内容');
      controller.dispose();
    });
  });

  group('时间表提交', () {
    test('空会话应用时间表只保存草稿，不创建计划版本', () async {
      final store = InMemorySessionRepository();
      final controller =
          AppController(engine: FakeScheduleEngine(), store: store);
      final conversation = await controller.createConversation();
      expect(controller.canEditTimetable, isTrue,
          reason: '空会话也必须能先编辑时间表草稿');
      const settings = CalendarSettings(
        timezoneOffsetMinutes: 480,
        planningStartDate: '2026-10-19',
      );
      final ok = await controller.applyTimetableSettings(
        settings,
        Timetable.withDefaults(weekStart: '2026-10-19'),
        reschedule: false,
      );
      expect(ok, isTrue);
      expect(controller.hasRequestTimetable, isTrue,
          reason: '只有时间表也应允许发送');
      final loaded = await store.loadConversation(conversation.id);
      expect(loaded!.versions, isEmpty);
      expect(loaded.calendarDraft, isNotNull);
      expect(loaded.includeTimetable, isTrue);
    });
  });
}
