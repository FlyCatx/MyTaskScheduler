// 任务列表筛选回归：每个筛选值都必须渲染，且受阻/待确认任务在对应用筛选下可见。
//
// 这个场景原来是 flutter_app/test_tmp 里的一次性诊断（用真实 DLL 快照复现「点“受阻”，
// 面板不再渲染」）。诊断的价值是覆盖“有受阻/待确认任务时仍能渲染”，所以这里用固定快照
// 把它变成常驻回归，不再依赖 DLL 与人工观察。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/display.dart';
import 'package:taskscheduler_flutter/src/state/task_interaction.dart';
import 'package:taskscheduler_flutter/src/ui/task_list.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

Map<String, dynamic> _task(
  String id,
  String name,
  String status,
  String statusText, {
  String scheduleState = 'scheduled',
}) =>
    <String, dynamic>{
      'id': id,
      'name': name,
      'status': status,
      'statusText': statusText,
      'level': 0,
      'affected': false,
      'estimateKnown': true,
      'estimateHours': 1.0,
      'deadline': null,
      'estimateReason': null,
      'steps': <String>[],
      'sources': <String>[],
      'conditions': <dynamic>[],
      'predecessors': <dynamic>[],
      'unlocks': <dynamic>[],
      'stillWaiting': <dynamic>[],
      'reasons': <String>[],
      'scheduleState': scheduleState,
      'startHours': 0,
      'endHours': 1,
      'scheduleNote': null,
    };

/// 一份同时含 可开始 / 待前置 / 受阻 / 待确认 / 已完成 的展示快照。
DisplaySnapshot _snapshot() => DisplaySnapshot.fromJson(<String, dynamic>{
      'ok': true,
      'formatVersion': '1',
      'summary': '筛选回归',
      'sortedAt': '2026-10-19 10:00:00',
      'unresolvableReason': null,
      'tasks': <dynamic>[
        _task('t-ready', '可开始一', 'ready', '可开始'),
        _task('t-waiting', '待前置一', 'waiting', '待前置'),
        _task('t-blocked', '受阻一', 'blocked', '受阻'),
        _task('t-pending', '待确认一', 'pending', '待确认'),
        _task('t-done', '已完成一', 'done', '已完成',
            scheduleState: 'completed'),
      ],
      'order': <String>['t-ready', 't-waiting'],
      'blocked': <dynamic>[
        {'id': 't-blocked', 'name': '受阻一', 'reasons': <String>['等待老师审批']}
      ],
      'pending': <dynamic>[
        {'id': 't-pending', 'name': '待确认一', 'reasons': <String>['环境是否就绪未知']}
      ],
      'affected': <dynamic>[],
      'notes': <dynamic>[],
      'counts': <String, dynamic>{
        'total': 5,
        'ready': 1,
        'waiting': 1,
        'blocked': 1,
        'pending': 1,
        'done': 1,
        'unknownHours': 0,
      },
    });

void main() {
  testWidgets('每个筛选值都能渲染，受阻任务在受阻筛选下可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final snapshot = _snapshot();

    Future<void> pump(TaskFilter filter, bool showCompleted) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: TaskListView(
            snapshot: snapshot,
            interaction: TaskInteraction(),
            canEdit: true,
            reviewNotes: const <String, String>{},
            showCompleted: showCompleted,
            filter: filter,
            query: '',
            onFilter: (_) {},
            onQuery: (_) {},
            onToggle: (_) async => true,
            onConfirmReview: (_) async => true,
            onSelect: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final filter in TaskFilter.values) {
      for (final showCompleted in <bool>[true, false]) {
        await pump(filter, showCompleted);
        expect(tester.takeException(), isNull,
            reason: '筛选 ${filter.name}（showCompleted=$showCompleted）不应抛异常');
      }
    }

    // 受阻筛选：受阻任务可见，可开始任务被隐藏。
    await pump(TaskFilter.blocked, true);
    expect(find.text('受阻一'), findsOneWidget);
    expect(find.text('可开始一'), findsNothing);

    // 待确认任务在「全部」里存在（它不在 blocked 列表，但同样必须渲染）。
    await pump(TaskFilter.all, true);
    expect(find.text('待确认一'), findsOneWidget);
    expect(find.text('受阻一'), findsOneWidget);

    // 已完成开关关掉时，已完成任务不出现在列表里。
    await pump(TaskFilter.all, false);
    expect(find.text('已完成一'), findsNothing);
    expect(find.text('可开始一'), findsOneWidget);
  });

  testWidgets('选中的任务被筛选隐藏时仍能渲染（临时显示那一行）', (tester) async {
    // 回归：先选中一个“可开始”任务，再切到“受阻”。被选中的任务不在筛选结果里，
    // 列表必须把它临时补回来，而不是在 build 期间抛异常导致整块面板不渲染。
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final snapshot = _snapshot();
    final interaction = TaskInteraction();
    addTearDown(interaction.dispose);
    interaction.selectAndReveal('t-ready', view: 'list');

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: TaskListView(
          snapshot: snapshot,
          interaction: interaction,
          canEdit: true,
          reviewNotes: const <String, String>{},
          filter: TaskFilter.blocked,
          onToggle: (_) async => true,
          onConfirmReview: (_) async => true,
          onSelect: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '筛选把选中任务隐藏时不得抛异常');
    expect(find.text('受阻一'), findsOneWidget);
    expect(find.text('可开始一'), findsOneWidget,
        reason: '选中的任务被临时显示，避免跳转目标静默消失');
  });
}

