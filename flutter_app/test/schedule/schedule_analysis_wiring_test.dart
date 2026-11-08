// 分析接线回归（task 3）：日程指纹不一致/不可用时拒绝迟到结果。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/commit_gate.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';

import '../support/test_support.dart';

AnalyzeOutcome _outcome() => const AnalyzeOutcome(
      ok: true,
      plan: <String, dynamic>{
        'tasks': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'm1', 'name': '写报告', 'estimatedHours': 1},
        ],
        'notes': <dynamic>[],
      },
      elapsedMs: 1,
      httpStatus: 200,
    );

Future<ScheduleController> _schedule() async {
  final controller = ScheduleController(store: ScheduleStore.memory());
  await controller.initialize();
  addTearDown(controller.close);
  return controller;
}

Future<({AppController app, RequestTicket ticket})> _app(
    ScheduleController schedule) async {
  final store = InMemorySessionRepository();
  await seedConversation(store);
  final app = AppController(
    engine: FakeScheduleEngine(),
    store: store,
    schedule: schedule,
  );
  await app.initialize();
  addTearDown(app.dispose);
  final ticket = app.gate.begin(
    conversationId: 'conv-seed',
    requestId: 'req-1',
    baseVersionId: 'ver-1',
    baseRevision: 0,
    calendarRevision: -1,
  );
  return (app: app, ticket: ticket);
}

void main() {
  setUp(ScheduleStore.resetInstanceLocksForTest);

  test('日程指纹不匹配：拒绝迟到结果，版本数不变', () async {
    final schedule = await _schedule();
    final fixture = await _app(schedule);
    final result = await fixture.app.commitAnalysisResult(
      fixture.ticket,
      _outcome(),
      '',
      scheduleFingerprint: 'not-the-current-fingerprint',
      scheduleDateFrom: '2026-11-10',
      scheduleDateTo: '2026-11-10',
      scheduleTimezoneId: 'Asia/Shanghai',
      scheduleTimezoneOffsetMinutes: 480,
    );
    expect(result.status, PlanCommitStatus.rejected);
    expect(result.message, contains('本地日程'));
    expect(fixture.app.conversation!.versions.length, 1);
  });

  test('日程不可用（DST 不存在时刻）：failed 且不落盘', () async {
    final schedule = await _schedule();
    final created = await schedule.createEvent(const ScheduleDraft(
      title: 'DST 会议',
      timezoneId: 'America/New_York',
      startDate: '2026-03-08',
      startMinute: 2 * 60 + 30,
      endMinute: 3 * 60 + 30,
    ));
    expect(created.ok, isTrue, reason: created.message);
    final fixture = await _app(schedule);
    final result = await fixture.app.commitAnalysisResult(
      fixture.ticket,
      _outcome(),
      '',
      scheduleFingerprint: 'captured',
      scheduleDateFrom: '2026-03-08',
      scheduleDateTo: '2026-03-08',
      scheduleTimezoneId: 'America/New_York',
      scheduleTimezoneOffsetMinutes: -300,
    );
    expect(result.status, PlanCommitStatus.failed);
    expect(result.message, contains('本地日程数据当前不可用'));
    expect(fixture.app.conversation!.versions.length, 1);
  });

  test('注意：只有非空日程指纹才参与复核（未携带时间表时保持旧行为）', () async {
    final schedule = await _schedule();
    final fixture = await _app(schedule);
    final result = await fixture.app.commitAnalysisResult(
      fixture.ticket,
      _outcome(),
      '',
    );
    expect(result.status, PlanCommitStatus.committed, reason: result.message);
    expect(result.versionId, isNotNull);
  });
}
