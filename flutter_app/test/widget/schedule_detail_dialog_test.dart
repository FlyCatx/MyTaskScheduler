// 日程详情弹窗（任务 11.4）专项：时间/地点/分类/会话/任务/提醒的按需展示，
// 关联任务按稳定 ID 解析；任务删除/会话失效不画误跳；编辑回调与关闭行为。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_detail_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_editor_dialog.dart'
    show ScheduleConversationOption, ScheduleTaskOption;
import 'package:taskscheduler_flutter/src/ui/theme.dart';

DateTime _utc(String date, int minute) {
  final key = dateKeyToUtc(date)!;
  final wall = DateTime.utc(
    key.year,
    key.month,
    key.day + minute ~/ 1440,
    (minute % 1440) ~/ 60,
    minute % 60,
  );
  return IcsTimeZoneResolver().resolveWall('Asia/Shanghai', wall).utc!;
}

ScheduleEvent _event({
  String? location = '会议室 A',
  ScheduleCategory? category = ScheduleCategory.work,
  String? linkedConversationId,
  String? linkedTaskId,
  ScheduleReminderKind reminder = ScheduleReminderKind.minutes5,
}) =>
    ScheduleEvent(
      id: 'ev-1',
      revision: 1,
      title: '需求评审',
      timezoneId: 'Asia/Shanghai',
      startDate: '2026-11-09',
      startMinute: 10 * 60,
      endMinute: 11 * 60,
      location: location,
      category: category,
      linkedConversationId: linkedConversationId,
      linkedTaskId: linkedTaskId,
      reminder: reminder,
      createdAtUtc: DateTime.utc(2026, 11, 1),
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    );

ScheduleOccurrence _occurrence(ScheduleEvent event) => ScheduleOccurrence(
      eventId: event.id,
      occurrenceKey: scheduleOccurrenceKey(event.id, '2026-11-09'),
      originalDate: '2026-11-09',
      title: event.title,
      category: event.category?.wireName,
      timezoneId: event.timezoneId,
      allDay: false,
      blocksScheduling: true,
      reminder: event.reminder,
      linkedConversationId: event.linkedConversationId,
      startUtc: _utc('2026-11-09', 10 * 60),
      endUtc: _utc('2026-11-09', 11 * 60),
    );

void main() {
  setUpAll(IcsTimeZoneResolver.ensureDatabase);
  setUp(() => TsColors.apply(Brightness.light));
  tearDown(() => TsColors.apply(Brightness.light));

  Future<void> open(
    WidgetTester tester, {
    required ScheduleEvent event,
    required Future<ScheduleTaskOption?> Function()? resolveLinkedTask,
    VoidCallback? onEdit,
    Future<void> Function(String)? onOpenConversation,
    Future<void> Function(ScheduleTaskOption)? onOpenTask,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-detail'),
              onPressed: () => showScheduleDetailDialog(
                context,
                occurrence: _occurrence(event),
                event: event,
                displayTimezoneId: 'Asia/Shanghai',
                conversations: const <ScheduleConversationOption>[
                  ScheduleConversationOption(id: 'conv-1', title: 'App 2.0 上线'),
                ],
                resolveLinkedTask: resolveLinkedTask,
                onEdit: onEdit ?? () {},
                onOpenConversation: onOpenConversation,
                onOpenTask: onOpenTask,
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-detail')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('展示存在的时间/地点/分类/会话/提醒字段', (tester) async {
    final event = _event(linkedConversationId: 'conv-1');
    await open(tester, event: event, resolveLinkedTask: null);
    expect(find.byKey(const Key('schedule-detail-dialog')), findsOneWidget);
    expect(find.text('需求评审'), findsOneWidget);
    expect(find.text('11月9日 周一 10:00-11:00'), findsOneWidget);
    expect(find.text('会议室 A'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('App 2.0 上线'), findsOneWidget);
    expect(find.text('提前 5 分钟'), findsOneWidget);
    // 无关联任务：不画空跳转入口。
    expect(find.byKey(const Key('schedule-detail-open-task')), findsNothing);
  });

  testWidgets('关联任务按稳定 ID 解析：改名后仍显示新名并可打开', (tester) async {
    final event = _event(
      linkedConversationId: 'conv-1',
      linkedTaskId: 'task-1',
    );
    ScheduleTaskOption? opened;
    await open(
      tester,
      event: event,
      resolveLinkedTask: () async =>
          const ScheduleTaskOption(id: 'task-1', title: '整理需求清单与验收标准'),
      onOpenTask: (task) async => opened = task,
    );
    await tester.pumpAndSettle();
    expect(find.text('整理需求清单与验收标准'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-detail-open-task')));
    await tester.pumpAndSettle();
    expect(opened?.id, 'task-1');
  });

  testWidgets('任务被删除：明确说明且没有跳转入口，不按同名误跳', (tester) async {
    final event = _event(
      linkedConversationId: 'conv-1',
      linkedTaskId: 'task-gone',
    );
    await open(
      tester,
      event: event,
      resolveLinkedTask: () async => null,
      onOpenTask: (_) async {},
    );
    await tester.pumpAndSettle();
    expect(find.text('关联任务已不存在'), findsOneWidget);
    expect(find.byKey(const Key('schedule-detail-open-task')), findsNothing);
  });

  testWidgets('编辑日程回调在关闭详情后触发', (tester) async {
    var edited = false;
    final event = _event();
    await open(tester, event: event, resolveLinkedTask: null, onEdit: () {
      edited = true;
    });
    await tester.tap(find.byKey(const Key('schedule-detail-edit')));
    await tester.pumpAndSettle();
    expect(edited, isTrue);
    expect(find.byKey(const Key('schedule-detail-dialog')), findsNothing);
  });
}
