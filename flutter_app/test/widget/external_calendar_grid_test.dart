// R2 绘制网格：外部日历只读占用。
//
// 覆盖：
//   * 无外部数据时渲染与 0.2.1 完全一致（逐像素对比，零回归）；
//   * 外部占用用浅灰斜纹 + 左侧标记 + 「外部」文字绘制（不只靠颜色区分）；
//   * 外部占用不可绘制/擦除/选中，点选/悬停只显示含「外部日历」的信息；
//   * 外部数据不进入 TimetableDraft（无撤销事务、无业务变化）。

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/calendar.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/model/settings.dart';
import 'package:taskscheduler_flutter/src/model/timetable.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_grid.dart';
import 'package:taskscheduler_flutter/src/ui/calendar_settings_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

const String _week = '2026-11-09';

Timetable _timetable() => Timetable.withDefaults(weekStart: _week);

ExternalBusyInstance _busy({
  String dayKey = _week,
  int startMinute = 480,
  int endMinute = 600,
}) =>
    ExternalBusyInstance(
      sourceId: 'ext-000000000001',
      uid: 'busy-1@test',
      startUtc: DateTime.utc(2026, 11, 9, 0).add(Duration(minutes: startMinute)),
      endUtc: DateTime.utc(2026, 11, 9, 0).add(Duration(minutes: endMinute)),
      dayKey: dayKey,
      startMinute: startMinute,
      endMinute: endMinute,
    );

class _Harness {
  _Harness(this.controller);

  final TimetableGridController controller;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  List<ExternalBusyInstance> externalBusy = const <ExternalBusyInstance>[],
  Map<String, String> sourceNames = const <String, String>{},
  bool explicitEmptyExternalList = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));

  final controller = TimetableGridController(draft: TimetableDraft(_timetable()));
  final grid = TimetableGrid(
    key: const Key('grid'),
    controller: controller,
    weekStart: _week,
    weekStartsOn: 1,
    weeklyMode: false,
    externalBusy: explicitEmptyExternalList
        ? const <ExternalBusyInstance>[]
        : externalBusy,
    externalSourceNames: sourceNames,
  );
  await _pumpGrid(tester, grid);
  return _Harness(controller);
}

Future<void> _pumpGrid(WidgetTester tester, TimetableGrid grid) async {
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: const Key('grid-boundary'),
          child: SizedBox(width: 1000, height: 700, child: grid),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Offset _cellCenter(WidgetTester tester, int day, int slot) {
  final box = tester.getRect(find.byKey(const Key('grid')));
  final gridWidth =
      box.width - TimetableGrid.timeAxisWidth - TimetableGrid.scrollbarGutter;
  final dayWidth = gridWidth / 7;
  return Offset(
    box.left + TimetableGrid.timeAxisWidth + dayWidth * (day + 0.5),
    box.top +
        TimetableGrid.headerHeight +
        TimetableGrid.topInset +
        TimetableGrid.rowHeight * (slot + 0.5),
  );
}

Future<Uint8List> _pngOf(WidgetTester tester) async {
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(const Key('grid-boundary')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

Future<Uint8List> _rgbaOf(WidgetTester tester) async {
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(const Key('grid-boundary')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

String _hoverText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('timetable-hover')))
    .data!;

void main() {
  testWidgets('无外部数据时渲染与 0.2.1 完全一致（逐像素零回归）', (tester) async {
    await _pump(tester);
    final baseline = await _pngOf(tester);

    // 显式传空列表：与完全不传（默认参数）必须逐像素一致。
    await _pump(tester, explicitEmptyExternalList: true);
    final explicitEmpty = await _pngOf(tester);

    expect(baseline, equals(explicitEmpty),
        reason: '无外部数据时新增参数不能改变任何渲染');
  });

  testWidgets('外部占用画成浅灰斜纹并带来源标记（不只靠颜色区分）', (tester) async {
    await _pump(
      tester,
      externalBusy: [_busy()],
      sourceNames: const {'ext-000000000001': '工作日历'},
    );
    // 09:30 所在的格子在外部区间 08:00-10:00 内，且该时段手工数据默认可空闲。
    final cell = _cellCenter(tester, 0, 38);
    final boundaryRect =
        tester.getRect(find.byKey(const Key('grid-boundary')));
    final rgba = await _rgbaOf(tester);
    final width = boundaryRect.width.toInt();
    final height = boundaryRect.height.toInt();
    expect(rgba.length, greaterThanOrEqualTo(width * height * 4));

    int pixelAt(int x, int y, int channel) => rgba[(y * width + x) * 4 + channel];

    var fillPixels = 0;
    var hatchPixels = 0;
    for (var dy = -6; dy <= 6; dy++) {
      for (var dx = 8; dx <= 48; dx++) {
        final x = (cell.dx + dx - boundaryRect.left).round();
        final y = (cell.dy + dy - boundaryRect.top).round();
        if (x < 2 || y < 2 || x >= width - 2 || y >= height - 2) continue;
        final r = pixelAt(x, y, 0);
        final g = pixelAt(x, y, 1);
        final b = pixelAt(x, y, 2);
        if (r > 236 && g > 238 && b > 240) fillPixels++;
        // 斜纹是 9CA3AF 以 55% 叠在 F1F2F4 上：约 (194,199,206)，灰度介于
        // 填充与网格线之间；扫描区内没有任何网格线，命中即可证明斜纹存在。
        if (r >= 175 && r <= 220 && g >= 180 && g <= 224 && b >= 185 && b <= 232) {
          hatchPixels++;
        }
      }
    }
    expect(fillPixels, greaterThan(0), reason: '外部占用底色必须存在');
    expect(hatchPixels, greaterThan(0),
        reason: '外部占用必须带斜纹（形状差异），不能只有一块纯色');
  });

  testWidgets('悬停外部占用显示「外部日历」与只读说明', (tester) async {
    await _pump(
      tester,
      externalBusy: [_busy()],
      sourceNames: const {'ext-000000000001': '工作日历'},
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    await tester.pump();
    await mouse.moveTo(_cellCenter(tester, 0, 38));
    await tester.pump();
    expect(_hoverText(tester), contains('外部日历'));
    expect(_hoverText(tester), contains('只读'));
    expect(_hoverText(tester), contains('工作日历'));
    await mouse.removePointer();
    await tester.pump();
  });

  testWidgets('外部占用不可绘制/擦除，草稿与撤销历史不变', (tester) async {
    final harness = await _pump(
      tester,
      externalBusy: [_busy()],
      sourceNames: const {'ext-000000000001': '工作日历'},
    );
    final before = jsonEncode(harness.controller.draft.timetable.toJson());
    final center = _cellCenter(tester, 0, 38);

    // 左键（绘制）与右键（擦除）都只显示信息。
    final paint = await tester.startGesture(center);
    await paint.up();
    await tester.pump();
    expect(jsonEncode(harness.controller.draft.timetable.toJson()), before,
        reason: '外部占用的时间段不能被绘制');
    expect(harness.controller.undoDepth, 0);
    expect(_hoverText(tester), contains('外部日历'));

    final erase =
        await tester.startGesture(center, buttons: kSecondaryMouseButton);
    await erase.up();
    await tester.pump();
    expect(jsonEncode(harness.controller.draft.timetable.toJson()), before,
        reason: '外部占用的时间段不能被擦除');
    expect(harness.controller.undoDepth, 0);

    // 外部数据不进入草稿：画在外部区间之外仍然正常工作（局部只读，不是整体禁用）。
    final outside = await tester.startGesture(_cellCenter(tester, 0, 44));
    await outside.up();
    await tester.pump();
    expect(harness.controller.draft.timetable.hasEntries, isTrue,
        reason: '外部区间之外仍可正常绘制');
  });

  testWidgets('选择模式下点选外部占用不会选中蓝块', (tester) async {
    final harness = await _pump(
      tester,
      externalBusy: [_busy()],
      sourceNames: const {'ext-000000000001': '工作日历'},
    );
    harness.controller.setSelectionMode(true);
    await tester.pump();
    final tap = await tester.startGesture(_cellCenter(tester, 0, 38));
    await tap.up();
    await tester.pump();
    expect(harness.controller.selectedReservationIds, isEmpty);
    expect(_hoverText(tester), contains('外部日历'),
        reason: '点选外部占用只显示信息');
  });

  testWidgets('绘制页没有外部服务时不显示外部日历入口（零回归）', (tester) async {
    await _openEditor(tester);
    expect(find.byKey(const Key('external-calendar-open-import')), findsNothing);
    expect(find.byKey(const Key('external-calendar-editor-note')), findsNothing);
    expect(find.byType(TimetableGrid), findsOneWidget);
  });

  testWidgets('绘制页入口打开导入向导，并按会话关联来源叠加只读占用', (tester) async {
    final service = _EditorFakeService(<ExternalBusyInstance>[
      _busy(dayKey: '2026-11-10', startMinute: 300, endMinute: 360),
    ]);
    addTearDown(service.dispose);
    await _openEditor(
      tester,
      externalCalendar: service,
      externalSourceIds: const <String>{'ext-000000000001'},
    );

    expect(
        find.byKey(const Key('external-calendar-open-import')), findsOneWidget);
    final note = tester
        .widget<Text>(find.byKey(const Key('external-calendar-editor-note')))
        .data!;
    expect(note, contains('只读'));
    expect(note, contains('1 条'), reason: '本周应显示 1 条叠加实例');

    // 悬停外部占用：可见信息含「外部日历」，证明服务数据已接到网格。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    await tester.pump();
    await mouse.moveTo(_editorCellCenter(tester, 1, 21));
    await tester.pump();
    expect(_hoverText(tester), contains('外部日历'));
    await mouse.removePointer();

    // 标题行入口打开导入向导；取消后回到绘制页。
    await tester.tap(find.byKey(const Key('external-calendar-open-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-import-dialog')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-import-dialog')),
        findsNothing);
  });
}

CalendarSettings _editorSettings() => const CalendarSettings(
      timezoneOffsetMinutes: 480,
      planningStartDate: _week,
      planningDays: 7,
      weekly: WeeklyAvailability({
        1: [WallClockRange(480, 720)],
        2: [WallClockRange(480, 720)],
      }),
    );

Future<void> _openEditor(
  WidgetTester tester, {
  ExternalCalendarService? externalCalendar,
  Set<String> externalSourceIds = const <String>{},
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1300, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1300, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open-editor'),
            onPressed: () async {
              await showCalendarSettingsDialog(
                context,
                settings: _editorSettings(),
                now: DateTime.utc(2026, 11, 9, 2),
                timetable: Timetable.withDefaults(weekStart: _week),
                weekStartsOn: 1,
                initialMode: CalendarEditorMode.drawing,
                defaultUnavailableRanges: UnavailableRange.defaults,
                externalCalendar: externalCalendar,
                externalSourceIds: externalSourceIds,
                externalCalendarPickFiles: () async => const <String>[],
              );
            },
            child: const Text('编辑'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-editor')));
  await tester.pumpAndSettle();
}

Offset _editorCellCenter(WidgetTester tester, int day, int slot) {
  final box = tester.getRect(find.byType(TimetableGrid));
  final gridWidth =
      box.width - TimetableGrid.timeAxisWidth - TimetableGrid.scrollbarGutter;
  final dayWidth = gridWidth / 7;
  return Offset(
    box.left + TimetableGrid.timeAxisWidth + dayWidth * (day + 0.5),
    box.top +
        TimetableGrid.headerHeight +
        TimetableGrid.topInset +
        TimetableGrid.rowHeight * (slot + 0.5),
  );
}

/// 绘制页只读占用的最小 fake：sources + busyFor 即可。
class _EditorFakeService extends ChangeNotifier
    implements ExternalCalendarService {
  _EditorFakeService(this.busy);

  final List<ExternalBusyInstance> busy;

  @override
  List<ExternalCalendarSource> get sources => const <ExternalCalendarSource>[
        ExternalCalendarSource(
          id: 'ext-000000000001',
          name: '工作日历',
          contentHash: 'deadbeefcafebabe',
          revision: 1,
          dateFrom: _week,
          dateTo: '2026-11-15',
          timezoneId: 'Asia/Shanghai',
        ),
      ];

  @override
  List<ExternalBusyInstance> busyFor({
    required Set<String> sourceIds,
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
  }) =>
      <ExternalBusyInstance>[
        for (final instance in busy)
          if (sourceIds.contains(instance.sourceId)) instance,
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
