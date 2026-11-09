// 日程弹窗（任务 09/11）行为回归：范围表达、筛选与空态、唯一关闭入口、
// 日期标题复用共享日历、点击空档预填、事件详情、任务层只读叠加。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_list_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_week_view.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/date_range_picker.dart'
    show DatePickerField, formatDatePickerDate;

int _idSeed = 0;
final DateTime _now = DateTime.utc(2026, 11, 6, 1); // 上海墙钟 2026-11-06 09:00（周五）

ScheduleController _controller() {
  final controller = ScheduleController(
    store: ScheduleStore.memory(),
    clock: () => _now,
    idFactory: (prefix) => '$prefix-${_idSeed++}',
  );
  addTearDown(() => unawaited(controller.close()));
  return controller;
}

Future<ScheduleController> _ready() async {
  final controller = _controller();
  await controller.initialize();
  return controller;
}

Future<ScheduleEvent> _seed(
  ScheduleController controller, {
  String title = '需求评审',
  String startDate = '2026-11-05',
  int startMinute = 10 * 60,
  int endMinute = 11 * 60,
  bool allDay = false,
  String? endDateExclusive,
  ScheduleCategory? category,
  String? linkedConversationId,
  String? linkedTaskId,
  ScheduleReminderKind reminder = ScheduleReminderKind.none,
}) async {
  final result = await controller.createEvent(ScheduleDraft(
    title: title,
    timezoneId: 'Asia/Shanghai',
    startDate: startDate,
    allDay: allDay,
    startMinute: allDay ? null : startMinute,
    endMinute: allDay ? null : endMinute,
    endDateExclusive: allDay ? (endDateExclusive ?? '2026-11-06') : null,
    category: category,
    linkedConversationId: linkedConversationId,
    linkedTaskId: linkedTaskId,
    reminder: reminder,
  ));
  expect(result.ok, isTrue, reason: result.message);
  return controller.eventById(result.eventId!)!;
}

Widget _host(
  ScheduleController controller, {
  String? currentConversationId,
  List<ScheduleTaskTime> taskTimes = const <ScheduleTaskTime>[],
  Future<List<ScheduleTaskOption>> Function(String)? loadConversationTasks,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const Key('open-list'),
            onPressed: () => showScheduleListDialog(
              context,
              controller: controller,
              timezoneId: 'Asia/Shanghai',
              clock: () => _now,
              currentConversationId: currentConversationId,
              conversations: conversations,
              taskTimes: taskTimes,
              loadConversationTasks: loadConversationTasks,
            ),
            child: const Text('打开列表'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  ScheduleController controller, {
  String? currentConversationId,
  List<ScheduleTaskTime> taskTimes = const <ScheduleTaskTime>[],
  Future<List<ScheduleTaskOption>> Function(String)? loadConversationTasks,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
}) async {
  TsColors.apply(Brightness.light);
  await tester.pumpWidget(_host(
    controller,
    currentConversationId: currentConversationId,
    taskTimes: taskTimes,
    loadConversationTasks: loadConversationTasks,
    conversations: conversations,
  ));
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-list')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

String _weekLabel(WidgetTester tester) {
  final text = find.descendant(
    of: find.byKey(const Key('schedule-week-label')),
    matching: find.byType(Text),
  );
  return tester.widget<Text>(text.first).data ?? '';
}

void main() {
  setUpAll(IcsTimeZoneResolver.ensureDatabase);
  setUp(() => TsColors.apply(Brightness.light));
  tearDown(() => TsColors.apply(Brightness.light));

  testWidgets('打开日程并展示本周事件；只有一个关闭入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller);

    await _open(tester, controller);
    expect(find.byKey(const Key('schedule-list-dialog')), findsOneWidget);
    expect(find.text('需求评审'), findsWidgets);

    // 顶部 × 是唯一关闭入口；底部不再有重复关闭与说明文案。
    expect(find.byKey(const Key('schedule-list-close')), findsOneWidget);
    expect(find.byKey(const Key('schedule-list-close-footer')), findsNothing);
    expect(find.textContaining('筛选只影响展示'), findsNothing);
    expect(find.textContaining('跳转日期'), findsNothing);

    // 统计只描述范围与数量。
    expect(find.byKey(const Key('schedule-footer-stats')), findsOneWidget);
    expect(find.textContaining('本周 1 条'), findsOneWidget);
  });

  testWidgets('无日历时本周空态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _open(tester, controller);
    expect(find.text('本周暂无日程'), findsOneWidget);
    expect(find.byKey(const Key('schedule-week-empty')), findsOneWidget);
  });

  testWidgets('有日程但筛选到 0 条时用筛选空态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller, category: ScheduleCategory.work);

    await _open(tester, controller);
    await tester.tap(find.text('全部分类').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('学习').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('没有符合条件的日程'), findsOneWidget);
    expect(find.text('本周暂无日程'), findsNothing);
  });

  testWidgets('浏览其他周用范围措辞；上一周/下一周/本周可返回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller);
    await _open(tester, controller);
    final thisWeek = _weekLabel(tester);

    await tester.tap(find.byKey(const Key('schedule-next-week')));
    await tester.pump();
    expect(find.text('这一周暂无日程'), findsOneWidget);
    expect(find.text('本周暂无日程'), findsNothing);

    await tester.tap(find.byKey(const Key('schedule-prev-week')));
    await tester.pump();
    expect(_weekLabel(tester), thisWeek);
    expect(find.text('需求评审'), findsWidgets);

    await tester.tap(find.byKey(const Key('schedule-next-week')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('schedule-this-week')));
    await tester.pump();
    expect(_weekLabel(tester), thisWeek);
  });

  testWidgets('可点日期标题复用共享年月日历并定位对应周', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _open(tester, controller);
    expect(_weekLabel(tester), '11月2日-8日');

    await tester.tap(find.byKey(const Key('schedule-week-label')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('calendar-popup')), findsOneWidget);

    // 日格默认显示 11 月，翻到 12 月后选 12 月 9 日。
    await tester.tap(find.byKey(const Key('calendar-next-month')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('calendar-day-2026-12-09')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // 12 月 9 日为周三 → 当周周一是 12 月 7 日。
    expect(_weekLabel(tester), '12月7日-13日');
  });

  testWidgets('点击事件打开详情，关闭详情仍停留在原周', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    final event = await _seed(
      controller,
      category: ScheduleCategory.work,
      reminder: ScheduleReminderKind.minutes5,
    );
    await _open(tester, controller);
    final weekLabel = _weekLabel(tester);

    await tester.tap(find.byKey(Key('schedule-event-${event.id}@2026-11-05')));
    await tester.pump();
    expect(find.byKey(const Key('schedule-detail-dialog')), findsOneWidget);
    expect(find.byKey(const Key('schedule-detail-edit')), findsOneWidget);
    expect(find.byKey(const Key('schedule-detail-linked-task')), findsNothing,
        reason: '无关联任务时不画空跳转入口');
    expect(find.text('提前 5 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule-detail-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('schedule-detail-dialog')), findsNothing);
    expect(_weekLabel(tester), weekLabel);
  });

  testWidgets('点击空档用所选日期预填新建日程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _open(tester, controller);

    // 第 3 列（周三 = 11 月 4 日），点击时间轴中部。
    final column = find.byKey(const Key('schedule-day-column-2'));
    final rect = tester.getRect(column);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);
    final startField =
        tester.widget<DatePickerField>(find.byKey(const Key('schedule-start-date')));
    expect(startField.value, isNotNull);
    expect(formatDatePickerDate(startField.value!), '2026-11-04');
  });

  testWidgets('筛选只影响展示：日程数据与全局统计不变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller, title: '工作日程', category: ScheduleCategory.work);
    await _seed(
      controller,
      title: '学习日程',
      startDate: '2026-11-05',
      startMinute: 12 * 60,
      endMinute: 13 * 60,
      category: ScheduleCategory.study,
    );
    await _open(tester, controller);
    expect(find.textContaining('本周 2 条'), findsOneWidget);

    await tester.tap(find.text('全部分类').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('工作').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('本周 1 条'), findsOneWidget);
    expect(find.textContaining('全局共 2 个日程'), findsOneWidget);
    expect(controller.events, hasLength(2), reason: '筛选不删除/不修改数据');
  });

  testWidgets('仅当前会话筛选生效', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller, title: '当前会话日程', linkedConversationId: 'c-1');
    await _seed(
      controller,
      title: '其他会话日程',
      startDate: '2026-11-05',
      startMinute: 12 * 60,
      endMinute: 13 * 60,
      linkedConversationId: 'c-2',
    );
    await _open(
      tester,
      controller,
      currentConversationId: 'c-1',
      conversations: const <ScheduleConversationOption>[
        ScheduleConversationOption(id: 'c-1', title: '会话一'),
        ScheduleConversationOption(id: 'c-2', title: '会话二'),
      ],
    );
    await tester.tap(find.byKey(const Key('schedule-only-current')));
    await tester.pump();
    expect(find.text('当前会话日程'), findsWidgets);
    expect(find.text('其他会话日程'), findsNothing);
  });

  testWidgets('任务层只读叠加：勾选显示、再取消只隐藏，不新增日程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller, title: '已有日程');
    final taskTimes = <ScheduleTaskTime>[
      ScheduleTaskTime(
        taskId: 'task-1',
        title: '写方案',
        startUtc: DateTime.utc(2026, 11, 5, 2),
        endUtc: DateTime.utc(2026, 11, 5, 4),
      ),
    ];
    await _open(tester, controller, taskTimes: taskTimes);
    expect(find.byKey(const Key('schedule-task-layer-task-1-3')), findsNothing);

    await tester.tap(find.byKey(const Key('schedule-task-layer-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('schedule-task-layer-task-1-3')), findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule-task-layer-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('schedule-task-layer-task-1-3')), findsNothing);
    expect(controller.events, hasLength(1), reason: '任务层不保存为日程');
  });

  testWidgets('只有右上关闭一个入口，关闭后不修改日程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _ready();
    await _seed(controller);
    await _open(tester, controller);
    await tester.tap(find.byKey(const Key('schedule-list-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('schedule-list-dialog')), findsNothing);
    expect(controller.events, hasLength(1));
  });
}
