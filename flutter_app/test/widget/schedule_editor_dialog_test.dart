// 日程新建/编辑弹窗回归（0.4.0 任务 4）。
//
// 覆盖用户行为而不是镜像内部实现：
//   * 无会话也能创建，保存后控制器里有一条全局日程；
//   * 字段校验失败就地提示、弹窗不关、草稿保留；
//   * 跨日 23:30→次日 00:30 保存为 1410/1470 分钟；
//   * 定时与全天分支来回切换不丢输入，提交只保存当前分支；
//   * 保存失败（写盘抛错）弹窗不关、草稿还在、控制器没有伪成功；
//   * 重复规则变更影响单次例外时先提示再确认，不静默删除例外；
//   * 单次编辑只改本次日期/时间（override），并明确提供切换到整个系列；
//   * 脏数据关闭/Esc 需要确认；保存中禁重复提交；
//   * 暗色 + 150% 字号 + 窄窗不溢出。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/ics/ics_timezones.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_expander.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_editor_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/date_range_picker.dart'
    show DatePickerField, formatDatePickerDate;

int _idSeed = 0;

ScheduleController _controller({ScheduleStore? store}) {
  final controller = ScheduleController(
    store: store ?? ScheduleStore.memory(),
    clock: () => DateTime.utc(2026, 11, 6, 1),
    idFactory: (prefix) => '$prefix-${_idSeed++}',
  );
  // Widget 测试的假异步 zone 里不能 await 由测试体调度的 Future；关服务用 unawaited。
  addTearDown(() {
    unawaited(controller.close());
  });
  return controller;
}

Future<ScheduleController> _readyController({ScheduleStore? store}) async {
  final controller = _controller(store: store);
  await controller.initialize();
  return controller;
}

class _FailingStore extends ScheduleStore {
  _FailingStore() : super.memory();

  @override
  Future<void> saveSnapshot(ScheduleSnapshot snapshot) async {
    throw StateError('disk full');
  }
}

class _HangingStore extends ScheduleStore {
  _HangingStore() : super.memory();

  final Completer<void> gate = Completer<void>();
  int saves = 0;

  @override
  Future<void> saveSnapshot(ScheduleSnapshot snapshot) async {
    saves++;
    await gate.future;
    await super.saveSnapshot(snapshot);
  }
}

Widget _host({
  required ScheduleController controller,
  ScheduleEvent? event,
  ScheduleOccurrence? occurrence,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
  Future<List<ScheduleTaskOption>> Function(String)? loadConversationTasks,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildAppTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const Key('open-editor'),
            onPressed: () => showScheduleEditorDialog(
              context,
              controller: controller,
              timezoneId: 'Asia/Shanghai',
              event: event,
              occurrence: occurrence,
              conversations: conversations,
              clock: () => DateTime.utc(2026, 11, 6, 1),
              loadConversationTasks: loadConversationTasks,
            ),
            child: const Text('打开编辑'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester, {
  required ScheduleController controller,
  ScheduleEvent? event,
  ScheduleOccurrence? occurrence,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
  Future<List<ScheduleTaskOption>> Function(String)? loadConversationTasks,
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) async {
  TsColors.apply(brightness);
  await tester.pumpWidget(_host(
    controller: controller,
    event: event,
    occurrence: occurrence,
    conversations: conversations,
    loadConversationTasks: loadConversationTasks,
    brightness: brightness,
    textScale: textScale,
  ));
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-editor')));
  // 标题输入框 autofocus + 光标动画下 pumpAndSettle 可能永不结束；用有界 pump。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

String _textOf(WidgetTester tester, Key key) {
  final field = tester.widget<TextField>(find.byKey(key));
  return field.controller?.text ?? '';
}

String _dateOf(WidgetTester tester, Key key) {
  final field = tester.widget<DatePickerField>(find.byKey(key));
  return field.value == null ? '' : formatDatePickerDate(field.value!);
}

/// 通过共享年月日历控件选一个日期（开始/结束字段均为只读点开选择）。
Future<void> _pickDate(WidgetTester tester, Key fieldKey, String dateKey) async {
  await tester.tap(find.byKey(fieldKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  final day = find.byKey(Key('calendar-day-$dateKey'));
  expect(day, findsOneWidget, reason: '日期弹层应显示 $dateKey 的日格');
  await tester.tap(day);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// 编辑正文可滚动：点下方字段前先滚动到可见（与真实用户一致）。
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  // 用纵向 Scrollable（弹窗正文）而不是 TextField 内部的横向 Scrollable。
  final scrollable = find
      .byWidgetPredicate(
          (widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down)
      .first;
  for (var i = 0; i < 8; i++) {
    if (finder.hitTestable().evaluate().isNotEmpty) break;
    await tester.drag(scrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<ScheduleEvent> _seed(
  ScheduleController controller, {
  String title = '周会',
  String startDate = '2026-11-09',
  int startMinute = 540,
  int endMinute = 600,
  bool allDay = false,
  String? endDateExclusive,
  ScheduleRepeatRule repeat = const ScheduleRepeatRule.none(),
  ScheduleCategory? category,
  String? linkedConversationId,
  String? linkedTaskId,
  String timezoneId = 'Asia/Shanghai',
  ScheduleReminderKind reminder = ScheduleReminderKind.none,
}) async {
  final result = await controller.createEvent(ScheduleDraft(
    title: title,
    timezoneId: timezoneId,
    startDate: startDate,
    allDay: allDay,
    startMinute: allDay ? null : startMinute,
    endMinute: allDay ? null : endMinute,
    endDateExclusive: allDay ? (endDateExclusive ?? '2026-11-10') : null,
    repeat: repeat,
    category: category,
    linkedConversationId: linkedConversationId,
    linkedTaskId: linkedTaskId,
    reminder: reminder,
  ));
  expect(result.ok, isTrue, reason: result.message);
  return controller.eventById(result.eventId!)!;
}

void main() {
  setUpAll(() {
    IcsTimeZoneResolver.ensureDatabase();
    // 弹窗标题输入框 autofocus：光标闪烁会不断调度帧，pumpAndSettle 永不结束。
    EditableText.debugDeterministicCursor = true;
  });
  tearDownAll(() => EditableText.debugDeterministicCursor = false);
  setUp(() => TsColors.apply(Brightness.light));
  tearDown(() => TsColors.apply(Brightness.light));

  testWidgets('无会话也能新建日程；保存后进入全局控制器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);
    expect(find.text('新建日程'), findsOneWidget);
    expect(find.byKey(const Key('schedule-linked')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('schedule-title')), '项目会议');
    await tester.enterText(find.byKey(const Key('schedule-location')), '3 楼会议室');
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    expect(controller.events, hasLength(1));
    final event = controller.events.single;
    expect(event.title, '项目会议');
    expect(event.location, '3 楼会议室');
    expect(event.linkedConversationId, isNull);
    expect(event.timezoneId, 'Asia/Shanghai');
    expect(event.allDay, isFalse);
    expect(event.blocksScheduling, isTrue, reason: '新建默认占用排程时间');
  });

  testWidgets('标题为空时就地提示且不关闭弹窗、不写数据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);
    expect(find.byKey(const Key('schedule-editor-error')), findsOneWidget);
    expect(find.text('标题不能为空'), findsOneWidget);
    expect(controller.events, isEmpty);
  });

  testWidgets('跨日 23:30 → 次日 00:30 保存为 1410/1470 分钟', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '跨夜值班');
    await _pickDate(tester, const Key('schedule-start-date'), '2026-11-09');
    await tester.enterText(
        find.byKey(const Key('schedule-start-time')), '23:30');
    await _pickDate(tester, const Key('schedule-end-date'), '2026-11-10');
    await tester.enterText(
        find.byKey(const Key('schedule-end-time')), '00:30');
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(controller.events, hasLength(1));
    final event = controller.events.single;
    expect(event.startDate, '2026-11-09');
    expect(event.startMinute, 23 * 60 + 30);
    expect(event.endMinute, 24 * 60 + 30);
    expect(event.allDay, isFalse);
  });

  testWidgets('定时与全天草稿分别保留，切换回来不丢输入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '纪念日');
    await _pickDate(tester, const Key('schedule-start-date'), '2026-11-19');
    await tester.enterText(
        find.byKey(const Key('schedule-start-time')), '18:15');
    await _pickDate(tester, const Key('schedule-end-date'), '2026-11-19');
    await tester.enterText(
        find.byKey(const Key('schedule-end-time')), '19:45');

    // 切到全天：输入表单换成日期区间，定时草稿仍在控制器里。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-start-time')), findsNothing);
    await _pickDate(tester, const Key('schedule-allday-start'), '2026-11-20');
    await _pickDate(tester, const Key('schedule-allday-end'), '2026-11-21');

    // 切回定时：刚才 18:15/19:45 没有被全天分支覆盖。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    expect(_textOf(tester, const Key('schedule-start-time')), '18:15');
    expect(_textOf(tester, const Key('schedule-end-time')), '19:45');
    expect(_dateOf(tester, const Key('schedule-start-date')), '2026-11-19');

    // 再切回全天提交：只保存全天分支，界面结束日含当天 → 存储排他 +1 天。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(controller.events, hasLength(1));
    final event = controller.events.single;
    expect(event.allDay, isTrue);
    expect(event.startDate, '2026-11-20');
    expect(event.endDateExclusive, '2026-11-22');
    expect(event.startMinute, isNull);
    expect(event.endMinute, isNull);
  });

  testWidgets('保存失败弹窗不关、草稿保留、控制器没有伪成功', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController(store: _FailingStore());

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '写盘失败也要留草稿');
    await tester.enterText(
        find.byKey(const Key('schedule-location')), '未保存地点');
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);
    expect(find.byKey(const Key('schedule-editor-error')), findsOneWidget);
    expect(find.textContaining('保存失败'), findsWidgets);
    expect(_textOf(tester, const Key('schedule-title')), '写盘失败也要留草稿');
    expect(_textOf(tester, const Key('schedule-location')), '未保存地点');
    expect(controller.events, isEmpty);
  });

  testWidgets('保存中禁止重复提交：只写一次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _HangingStore();
    final controller = await _readyController(store: store);

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '只应创建一次');
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    // 保存按钮已禁用：再点一次不会发起第二个命令。
    await tester.tap(find.byKey(const Key('schedule-save')),
        warnIfMissed: false);
    await tester.pump();

    store.gate.complete();
    await tester.pumpAndSettle();
    expect(store.saves, 1);
    expect(controller.events, hasLength(1));
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
  });

  testWidgets('改系列重复规则影响单次例外：先提示，确认后才移除', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    final event = await _seed(
      controller,
      title: '每周例会',
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1, 3]),
    );
    // 周三那次改成 10:00，形成一条单次例外。
    final moved = await controller.overrideOccurrence(
      event.id,
      scheduleOccurrenceKey(event.id, '2026-11-11'),
      startDate: '2026-11-11',
      startMinute: 600,
      endMinute: 660,
    );
    expect(moved.ok, isTrue, reason: moved.message);
    final edited = controller.eventById(event.id)!;
    expect(edited.exceptions, hasLength(1));

    await _open(tester, controller: controller, event: edited);
    // 切到“不重复”：周三的例外在新的单次规则下不再命中。
    // 重复区在滚动正文下方，先滚到可见再点（与真实用户一致）。
    await tester.ensureVisible(find.byKey(const Key('schedule-repeat-none')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-repeat-none')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    // 第一次保存被拒绝，弹窗先说明影响；取消时原数据不变。
    expect(find.byKey(const Key('schedule-exceptions-confirm')), findsOneWidget);
    expect(find.textContaining('单次例外'), findsWidgets);
    await tester.tap(find.byKey(const Key('schedule-exceptions-cancel')));
    await tester.pumpAndSettle();
    expect(controller.eventById(event.id)!.repeat.repeats, isTrue);
    expect(controller.eventById(event.id)!.exceptions, hasLength(1));

    // 再次保存并确认：规则改为单次，失效例外被移除（不是静默删除）。
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-exceptions-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    final saved = controller.eventById(event.id)!;
    expect(saved.repeat.repeats, isFalse);
    expect(saved.exceptions, isEmpty);
  });

  testWidgets('单次编辑只改本次时间；系列字段只读，可切到整个系列', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    final event = await _seed(
      controller,
      title: '每周例会',
      startMinute: 540,
      endMinute: 600,
      repeat: const ScheduleRepeatRule.weekly(weekdays: <int>[1]),
    );
    final occurrence = ScheduleOccurrence(
      eventId: event.id,
      occurrenceKey: scheduleOccurrenceKey(event.id, '2026-11-09'),
      originalDate: '2026-11-09',
      title: event.title,
      timezoneId: event.timezoneId,
      allDay: false,
      blocksScheduling: true,
      reminder: ScheduleReminderKind.none,
      startUtc: DateTime.utc(2026, 11, 9, 1),
      endUtc: DateTime.utc(2026, 11, 9, 2),
    );

    await _open(
      tester,
      controller: controller,
      event: event,
      occurrence: occurrence,
    );
    expect(find.text('编辑本次日程'), findsOneWidget);
    expect(find.byKey(const Key('schedule-occurrence-banner')), findsOneWidget);
    // 单次编辑隐藏重复/关联等系列修改能力。
    expect(find.byKey(const Key('schedule-repeat')), findsNothing);
    expect(find.byKey(const Key('schedule-linked')), findsNothing);
    expect(find.byKey(const Key('schedule-title')), findsNothing);

    await tester.enterText(
        find.byKey(const Key('schedule-start-time')), '10:00');
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    final saved = controller.eventById(event.id)!;
    expect(saved.exceptions, hasLength(1));
    final exception = saved.exceptions.single;
    expect(exception.occurrenceKey,
        scheduleOccurrenceKey(event.id, '2026-11-09'));
    expect(exception.startMinute, 600);

    // 重新打开并切到整个系列：出现重复/关联/标题等系列字段。
    final updated = controller.eventById(event.id)!;
    await _open(
      tester,
      controller: controller,
      event: updated,
      occurrence: ScheduleOccurrence(
        eventId: updated.id,
        occurrenceKey: scheduleOccurrenceKey(updated.id, '2026-11-09'),
        originalDate: '2026-11-09',
        title: updated.title,
        timezoneId: updated.timezoneId,
        allDay: false,
        blocksScheduling: true,
        reminder: ScheduleReminderKind.none,
        startUtc: DateTime.utc(2026, 11, 9, 2),
        endUtc: DateTime.utc(2026, 11, 9, 3),
        isOverride: true,
      ),
    );
    await tester.tap(find.byKey(const Key('schedule-switch-to-series')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-repeat')), findsOneWidget);
    expect(find.byKey(const Key('schedule-linked')), findsOneWidget);
    expect(find.byKey(const Key('schedule-title')), findsOneWidget);
    expect(_textOf(tester, const Key('schedule-title')), '每周例会');
  });

  testWidgets('脏数据关闭需要确认；Esc 同样受保护', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '未保存标题');
    await tester.tap(find.byKey(const Key('schedule-editor-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-discard-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-discard-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-discard-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-discard-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    expect(controller.events, isEmpty);
  });

  testWidgets('未修改时关闭不需要确认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.tap(find.byKey(const Key('schedule-editor-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-discard-confirm')), findsNothing);
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
  });

  testWidgets('暗色 / 150% 字号 / 窄窗可用且不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(
      tester,
      controller: controller,
      brightness: Brightness.dark,
      textScale: 1.5,
    );
    expect(find.byKey(const Key('schedule-editor-dialog')), findsOneWidget);
    expect(find.byKey(const Key('schedule-title')), findsOneWidget);
    expect(find.byKey(const Key('schedule-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除常驻说明；提醒只出现一个字段标签并说明运行期限制', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    expect(find.textContaining('精确到分钟'), findsNothing);
    expect(find.textContaining('其他会话的排程会避开这段'), findsNothing);
    expect(find.byKey(const Key('schedule-blocks')), findsOneWidget);
    // 只有一个“提醒”字段标签，且带运行期限制。
    expect(find.text('提醒'), findsNothing);
    expect(find.text('提醒（应用运行期间）'), findsOneWidget);
    expect(find.byKey(const Key('schedule-reminder')), findsOneWidget);
    // 开始/结束复用共享日期控件，定时事项保留时分输入。
    expect(find.byType(DatePickerField), findsNWidgets(2));
    expect(find.byKey(const Key('schedule-start-time')), findsOneWidget);
    expect(find.byKey(const Key('schedule-end-time')), findsOneWidget);

    // 全天分支只输入日期，不显示时分。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-start-time')), findsNothing);
    expect(find.byKey(const Key('schedule-end-time')), findsNothing);
    expect(find.byKey(const Key('schedule-allday-start')), findsOneWidget);
    expect(find.byKey(const Key('schedule-allday-end')), findsOneWidget);
  });

  testWidgets('时区选单可搜索中文城市并保存 IANA；重开预选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    await _open(tester, controller: controller);
    await tester.enterText(find.byKey(const Key('schedule-title')), '时区日程');
    await _tapVisible(
        tester, find.byKey(const Key('schedule-notes-timezone-toggle')));
    expect(find.byKey(const Key('schedule-notes')), findsOneWidget,
        reason: '展开备注与时区');
    await _tapVisible(tester, find.byKey(const Key('schedule-timezone')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('schedule-timezone-picker')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('schedule-timezone-search')), '北京');
    await tester.pump();
    await tester.tap(
        find.byKey(const Key('schedule-timezone-option-Asia/Shanghai')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    expect(controller.events, hasLength(1));
    final event = controller.events.single;
    expect(event.timezoneId, 'Asia/Shanghai');

    // 重开：时区选单预选为保存的 IANA 值。
    await _open(tester, controller: controller, event: event);
    await _tapVisible(tester, find.byKey(const Key('schedule-notes-timezone-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Asia/Shanghai'), findsOneWidget);
    expect(find.byKey(const Key('schedule-timezone-invalid')), findsNothing);
  });

  testWidgets('同偏移不同 DST 地区分别保存：Europe/London 与 Africa/Abidjan',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();

    Future<void> createWith(String search, String expectedId) async {
      await _open(tester, controller: controller);
      await tester.enterText(
          find.byKey(const Key('schedule-title')), '时区-$expectedId');
      await _tapVisible(tester, find.byKey(const Key('schedule-notes-timezone-toggle')));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const Key('schedule-timezone')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
          find.byKey(const Key('schedule-timezone-search')), search);
      await tester.pump();
      // 伦敦与阿比让当前都是 UTC+00:00，但只有伦敦有夏令时：分别列出且可区分。
      await tester.tap(find.byKey(Key('schedule-timezone-option-$expectedId')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('schedule-save')));
      await tester.pumpAndSettle();
      expect(
        controller.events.any((event) =>
            event.timezoneId == expectedId && event.title == '时区-$expectedId'),
        isTrue,
      );
    }

    await createWith('伦敦', 'Europe/London');
    await createWith('阿比让', 'Africa/Abidjan');
  });

  testWidgets('无效旧时区：显示修复入口、保存被拒绝，重选后才写入', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    final event = await _seed(
      controller,
      title: '旧时区日程',
      timezoneId: 'Invalid/Zone',
    );
    expect(event.timezoneId, 'Invalid/Zone');

    await _open(tester, controller: controller, event: event);
    await _tapVisible(tester, find.byKey(const Key('schedule-notes-timezone-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-timezone-invalid')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-error')), findsOneWidget);
    expect(find.textContaining('时区无法解析'), findsOneWidget);

    await _tapVisible(tester, find.byKey(const Key('schedule-timezone')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
        find.byKey(const Key('schedule-timezone-search')), '上海');
    await tester.pump();
    await tester.tap(
        find.byKey(const Key('schedule-timezone-option-Asia/Shanghai')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    expect(controller.eventById(event.id)!.timezoneId, 'Asia/Shanghai');
  });

  testWidgets('选择关联会话后可选该会话任务并保存稳定 ID', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    const conversations = <ScheduleConversationOption>[
      ScheduleConversationOption(id: 'c-1', title: '会话一'),
    ];
    Future<List<ScheduleTaskOption>> loadTasks(String id) async {
      if (id != 'c-1') return const <ScheduleTaskOption>[];
      return const <ScheduleTaskOption>[
        ScheduleTaskOption(id: 't-1', title: '任务一'),
        ScheduleTaskOption(id: 't-2', title: '任务二', done: true),
      ];
    }

    await _open(
      tester,
      controller: controller,
      conversations: conversations,
      loadConversationTasks: loadTasks,
    );
    await tester.enterText(find.byKey(const Key('schedule-title')), '关联任务日程');
    await tester.tap(find.byKey(const Key('schedule-linked')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话一').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-linked-task')), findsOneWidget);
    await tester.tap(find.text('不关联任务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务二（已完成）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    final event = controller.events.single;
    expect(event.linkedConversationId, 'c-1');
    expect(event.linkedTaskId, 't-2');
  });

  testWidgets('换会话清除不匹配任务；任务被删除时清空引用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    final event = await _seed(
      controller,
      title: '已关联',
      linkedConversationId: 'c-1',
      linkedTaskId: 't-1',
    );
    expect(event.linkedTaskId, 't-1');
    const conversations = <ScheduleConversationOption>[
      ScheduleConversationOption(id: 'c-1', title: '会话一'),
      ScheduleConversationOption(id: 'c-2', title: '会话二'),
    ];
    Future<List<ScheduleTaskOption>> loadTasks(String id) async {
      if (id == 'c-1') {
        return const <ScheduleTaskOption>[
          ScheduleTaskOption(id: 't-1', title: '任务一'),
        ];
      }
      return const <ScheduleTaskOption>[
        ScheduleTaskOption(id: 't-9', title: '另一会话任务'),
      ];
    }

    await _open(
      tester,
      controller: controller,
      event: event,
      conversations: conversations,
      loadConversationTasks: loadTasks,
    );
    await tester.tap(find.byKey(const Key('schedule-linked')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话二').last);
    await tester.pumpAndSettle();
    // 任务下拉已刷新为新会话任务；旧的 t-1 不在选项里。
    await tester.tap(find.text('不关联任务').last);
    await tester.pumpAndSettle();
    expect(find.text('另一会话任务').last, findsOneWidget);
    await tester.tap(find.text('另一会话任务').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();

    final saved = controller.eventById(event.id)!;
    expect(saved.linkedConversationId, 'c-2');
    expect(saved.linkedTaskId, 't-9');

    // 再模拟任务被删除：loader 对该会话返回空 → 打开即清除引用，保存后为空。
    Future<List<ScheduleTaskOption>> loadDeleted(String id) async =>
        const <ScheduleTaskOption>[];
    final latest = controller.eventById(event.id)!;
    await _open(
      tester,
      controller: controller,
      event: latest,
      conversations: conversations,
      loadConversationTasks: loadDeleted,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    expect(controller.eventById(event.id)!.linkedTaskId, isNull);
  });

  testWidgets('开始/结束变化触发重叠检测：显示相交对象与实际重叠分钟，可保留冲突',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    final a = await _seed(
      controller,
      title: '前端页面开发',
      startDate: '2026-11-09',
      startMinute: 14 * 60,
      endMinute: 15 * 60,
    );
    final b = await _seed(
      controller,
      title: '设计讨论',
      startDate: '2026-11-09',
      startMinute: 14 * 60 + 30,
      endMinute: 15 * 60 + 30,
    );

    await _open(tester, controller: controller, event: b);
    expect(find.byKey(const Key('schedule-conflict-banner')), findsOneWidget);
    expect(find.textContaining('前端页面开发'), findsWidgets);
    expect(find.textContaining('重叠 30 分钟'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-conflict-view')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-conflict-dialog')), findsOneWidget);
    expect(find.textContaining('重叠 30 分钟'), findsWidgets);
    await tester.tap(find.byKey(const Key('schedule-conflict-keep')));
    await tester.pumpAndSettle();
    // 按既有规则保留冲突：保存成功，不会阻止写入。
    await tester.tap(find.byKey(const Key('schedule-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-editor-dialog')), findsNothing);
    expect(controller.eventById(b.id)!.startMinute, 14 * 60 + 30);

    // 编辑自身时排除原记录：编辑 A 只会看到 B 的 30 分钟重叠。
    final latestA = controller.eventById(a.id)!;
    await _open(tester, controller: controller, event: latestA);
    expect(find.byKey(const Key('schedule-conflict-banner')), findsOneWidget);
    expect(find.textContaining('「设计讨论」'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-editor-close')));
    await tester.pumpAndSettle();

    // 刚好首尾相接 = 0 分钟：C 从 15:30 开始，与 A/B 都不冲突。
    final c = await _seed(
      controller,
      title: '版本验收',
      startDate: '2026-11-09',
      startMinute: 15 * 60 + 30,
      endMinute: 16 * 60 + 30,
    );
    await _open(tester, controller: controller, event: c);
    expect(find.byKey(const Key('schedule-conflict-banner')), findsNothing);
  });

  testWidgets('占用开关关闭后不再提示排程冲突', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _readyController();
    await _seed(
      controller,
      title: '前端页面开发',
      startDate: '2026-11-09',
      startMinute: 14 * 60,
      endMinute: 15 * 60,
    );
    final b = await _seed(
      controller,
      title: '设计讨论',
      startDate: '2026-11-09',
      startMinute: 14 * 60 + 30,
      endMinute: 15 * 60 + 30,
    );
    await _open(tester, controller: controller, event: b);
    expect(find.byKey(const Key('schedule-conflict-banner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-blocks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-conflict-banner')), findsNothing);
  });
}
