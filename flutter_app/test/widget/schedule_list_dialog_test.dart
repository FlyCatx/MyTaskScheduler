// 日程列表弹窗冒烟回归（0.4.0）：全局列表可打开、展示现有日程、可关闭。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/schedule_event.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_controller.dart';
import 'package:taskscheduler_flutter/src/state/schedule/schedule_store.dart';
import 'package:taskscheduler_flutter/src/ui/schedule/schedule_list_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

Future<ScheduleController> _controller() async {
  final controller = ScheduleController(store: ScheduleStore.memory());
  await controller.initialize();
  final created = await controller.createEvent(const ScheduleDraft(
    title: '全局日程冒烟',
    timezoneId: 'Asia/Shanghai',
    startDate: '2026-11-05',
    startMinute: 600,
    endMinute: 660,
  ));
  expect(created.ok, isTrue, reason: created.message);
  // 假异步 zone 里不 await 由测试体调度的 Future。
  addTearDown(() {
    unawaited(controller.close());
  });
  return controller;
}

Widget _host(ScheduleController controller) => MaterialApp(
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
                clock: () => DateTime.utc(2026, 11, 6, 1),
              ),
              child: const Text('打开列表'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester, ScheduleController controller) async {
  TsColors.apply(Brightness.light);
  await tester.pumpWidget(_host(controller));
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-list')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('打开全局日程列表并展示现有日程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _controller();
    await _open(tester, controller);
    expect(find.byKey(const Key('schedule-list-dialog')), findsOneWidget);
    expect(find.textContaining('全局日程冒烟'), findsWidgets);
  });

  testWidgets('关闭按钮只关闭列表，不修改日程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await _controller();
    await _open(tester, controller);
    await tester.tap(find.byKey(const Key('schedule-list-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('schedule-list-dialog')), findsNothing);
    expect(controller.events, hasLength(1));
  });
}
