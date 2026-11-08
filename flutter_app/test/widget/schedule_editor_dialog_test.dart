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
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
}) async {
  TsColors.apply(brightness);
  await tester.pumpWidget(_host(
    controller: controller,
    event: event,
    occurrence: occurrence,
    conversations: conversations,
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
  ScheduleReminderKind reminder = ScheduleReminderKind.none,
}) async {
  final result = await controller.createEvent(ScheduleDraft(
    title: title,
    timezoneId: 'Asia/Shanghai',
    startDate: startDate,
    allDay: allDay,
    startMinute: allDay ? null : startMinute,
    endMinute: allDay ? null : endMinute,
    endDateExclusive: allDay ? (endDateExclusive ?? '2026-11-10') : null,
    repeat: repeat,
    category: category,
    linkedConversationId: linkedConversationId,
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
    await tester.enterText(
        find.byKey(const Key('schedule-start-date')), '2026-11-09');
    await tester.enterText(
        find.byKey(const Key('schedule-start-time')), '23:30');
    await tester.enterText(
        find.byKey(const Key('schedule-end-date')), '2026-11-10');
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
    await tester.enterText(
        find.byKey(const Key('schedule-start-date')), '2026-11-19');
    await tester.enterText(
        find.byKey(const Key('schedule-start-time')), '18:15');
    await tester.enterText(
        find.byKey(const Key('schedule-end-date')), '2026-11-19');
    await tester.enterText(
        find.byKey(const Key('schedule-end-time')), '19:45');

    // 切到全天：输入表单换成日期区间，定时草稿仍在控制器里。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-start-time')), findsNothing);
    await tester.enterText(
        find.byKey(const Key('schedule-allday-start')), '2026-11-20');
    await tester.enterText(
        find.byKey(const Key('schedule-allday-end')), '2026-11-21');

    // 切回定时：刚才 18:15/19:45 没有被全天分支覆盖。
    await tester.tap(find.byKey(const Key('schedule-all-day')));
    await tester.pumpAndSettle();
    expect(_textOf(tester, const Key('schedule-start-time')), '18:15');
    expect(_textOf(tester, const Key('schedule-end-time')), '19:45');
    expect(_textOf(tester, const Key('schedule-start-date')), '2026-11-19');

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
}
