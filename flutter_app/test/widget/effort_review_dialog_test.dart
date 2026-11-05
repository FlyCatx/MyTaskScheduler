// 执行回顾弹窗的**布局/视觉**测试（0.3.0 任务 03A）。
//
// 统计口径与筛选/导出回调用例已经在 test/execution/effort_review_dialog_test.dart
// （timing-dev 的目录）里，这里只补 UI 层验收：
//   * 与 OCR 主弹窗/设置弹窗同一套贝塞尔卡片（不再是 AlertDialog + 固定 660×400）；
//   * 标题左“执行回顾”、右“日期范围 + 关闭”；底部动作固定、中间列表滚动；
//   * 窄窗 + 1.5 倍字号允许分组换行、不溢出、关闭可达；
//   * 空状态可读，“未知”与“0 分钟”区分；
//   * 自定义日期非法时可执行反馈仍在；
//   * 导出前后同一批数据的日期范围/记录条数/分钟数一致（视觉调整不改统计口径）。

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_review_service.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_ledger.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/ui/execution/effort_review_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';

import '../execution/execution_test_support.dart';

class _Fixture {
  _Fixture({required this.service, required this.tasks});
  final EffortReviewService service;
  final List<ExecutionTaskInfo> tasks;
}

/// 1 条 30 分钟记录（task-a）+ 1 个已完成但无记录的任务（task-b，实际=未知）
/// + 1 个未估算任务（task-c）。额外任务用于把明细列表撑到需要滚动。
_Fixture _fixture({int extraTasks = 0}) {
  final records = <ExecutionRecord>[
    recordWithInterval(
      recordId: 'r1',
      taskId: 'task-a',
      taskName: '任务A',
      estimateBaselineHours: 2,
      startUtc: shanghaiUtc(2026, 11, 4, 9),
      endUtc: shanghaiUtc(2026, 11, 4, 9, 30),
    ),
  ];
  final tasks = <ExecutionTaskInfo>[
    taskInfo(
        taskId: 'task-a',
        name: '任务A',
        currentEstimateHours: 2,
        completion: Completion.todo),
    taskInfo(
        taskId: 'task-b',
        name: '任务B',
        completion: Completion.done,
        deadline: '2026-10-01'),
    taskInfo(
        taskId: 'task-c',
        name: '任务C',
        completion: Completion.todo,
        deadline: '2026-10-30'),
  ];
  for (var i = 0; i < extraTasks; i++) {
    final id = 'extra-$i';
    records.add(recordWithInterval(
      recordId: 'rec-$i',
      taskId: id,
      taskName: '补充任务 $i',
      estimateBaselineHours: 1,
      startUtc: shanghaiUtc(2026, 11, 4, 10, i % 50),
      endUtc: shanghaiUtc(2026, 11, 4, 10, i % 50 + 5),
    ));
    tasks.add(taskInfo(
      taskId: id,
      name: '补充任务 $i',
      currentEstimateHours: 1,
      completion: Completion.todo,
    ));
  }
  final ledger = ExecutionLedger(
    records: records,
    completionEvents: <CompletionEvent>[
      CompletionEvent(
        eventId: 'e1',
        conversationId: 'conv-1',
        taskId: 'task-b',
        planVersionId: 'ver-1',
        planRevision: 1,
        completedAtUtc: shanghaiUtc(2026, 11, 4, 10, 30),
      ),
    ],
  );
  final service = EffortReviewService(
    ledger: ledger,
    localTime: shanghaiLocalTime,
    nowUtc: () => testStartUtc,
  );
  return _Fixture(service: service, tasks: tasks);
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  // MediaQuery 来自 View 的物理尺寸；只 setSurfaceSize 会让 MediaQuery 仍是
  // 默认的 800×600，卡片就会按错误的窗口上限计算。两者都设，测试窗口与
  // 真实窗口一致。
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
}

Future<void> _openDialog(
  WidgetTester tester, {
  required EffortReviewService service,
  required List<ExecutionTaskInfo> tasks,
  Future<bool> Function(String name, String csv, String suggestedPath)? onExport,
  EffortReviewPreset preset = EffortReviewPreset.today,
  Size surface = const Size(1000, 760),
  double textScale = 1.0,
  List<ExecutionConversationInfo>? conversations,
}) async {
  await _setSurface(tester, surface);
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open-review'),
            onPressed: () => EffortReviewDialog.show(
              context,
              service: service,
              tasks: tasks,
              conversations: conversations ??
                  <ExecutionConversationInfo>[
                    conversationInfo(id: 'conv-1', title: '顺序表实验'),
                  ],
              initialPreset: preset,
              onExport: onExport,
            ),
            child: const Text('打开回顾'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-review')));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data!;

Rect _cardRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('effort-review-card')));

Rect _rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

/// 单行文本是否完整显示（没有被省略号截断）：用与渲染一致的样式/文字缩放
/// 测量“完整文本所需宽度”，再和实际渲染宽度比较。只断言 find.byKey 不能发现
/// 被裁的文本。
bool _isTextFullyLaidOut(WidgetTester tester, Key textKey) {
  final widget = tester.widget<Text>(find.byKey(textKey));
  final box = tester.renderObject<RenderBox>(find.byKey(textKey));
  final painter = TextPainter(
    text: TextSpan(text: widget.data, style: widget.style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(tester.element(find.byKey(textKey))),
    maxLines: widget.maxLines,
  )..layout();
  return box.size.width + 0.5 >= painter.width;
}

/// 标题栏几何：关闭按钮锚定卡片右内缘、日期在按钮左侧、标题在左侧且不与
/// 日期重叠。普通宽度要求日期完整显示；极窄要求日期换到标题下方右对齐。
void _expectTitleGeometry(WidgetTester tester, {required bool narrow}) {
  final card = _cardRect(tester);
  final close = _rectOf(tester, const Key('effort-review-close-icon'));
  final range = _rectOf(tester, const Key('effort-review-range'));
  final title = _rectOf(tester, const Key('effort-review-title'));

  // 28×28 独立热区，距卡片右内缘 = 主题内边距 8（不是按截图写的绝对坐标）。
  expect(close.width, closeTo(28, 1));
  expect(close.height, closeTo(28, 1));
  expect(card.right - close.right, closeTo(8, 1.5),
      reason: '关闭按钮必须锚定卡片右内缘（右侧只留 8 px 主题内边距）');
  expect(card.right - close.right, lessThan(16),
      reason: '截图问题：关闭按钮离卡片右缘太远');

  // 日期在关闭按钮左侧，两者热区不重叠。
  expect(range.right, lessThanOrEqualTo(close.left + 0.5),
      reason: '日期范围必须在关闭按钮左侧');
  // 标题占左侧空余宽度，不与日期重叠（窄窗时日期换到下方，改用纵向比较）。
  expect(title.left, greaterThanOrEqualTo(card.left + 20 - 0.5));
  if (narrow) {
    expect(range.top, greaterThanOrEqualTo(title.bottom - 0.5),
        reason: '极窄时日期换行到标题下方');
    expect(range.right, greaterThan(card.left + card.width * 0.5),
        reason: '换行后的日期右对齐');
  } else {
    expect(title.right, lessThanOrEqualTo(range.left + 0.5),
        reason: '标题与日期不能在同一行重叠');
    expect((range.center.dy - title.center.dy).abs(), lessThanOrEqualTo(1.5),
        reason: '普通宽度日期与标题同一行');
    expect(_isTextFullyLaidOut(tester, const Key('effort-review-range')), isTrue,
        reason: '普通宽度必须完整显示日期范围，不能出现省略号');
  }
}

void main() {
  testWidgets('贝塞尔卡片：标题左 / 日期范围 + 关闭右 / 底部动作固定 / 中间列表滚动',
      (tester) async {
    final f = _fixture(extraTasks: 24);
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      onExport: (name, csv, path) async => true,
    );

    // 不再是 Material AlertDialog。
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const Key('effort-review-dialog')), findsOneWidget);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.shape, isA<BezierRoundedRectangleBorder>());
    expect((dialog.shape! as BezierRoundedRectangleBorder).radius, 16);

    // 标题左、日期范围右（范围是“今日 2026-11-04”）。
    final title = find.text('执行回顾');
    final range = find.byKey(const Key('effort-review-range'));
    expect(title, findsOneWidget);
    expect(_text(tester, const Key('effort-review-range')), contains('2026-11-04'));
    expect(tester.getCenter(title).dx, lessThan(tester.getCenter(range).dx));
    // 关闭按钮在标题行右侧。
    expect(find.byKey(const Key('effort-review-close-icon')), findsOneWidget);

    // 从顶部弹出的卡片：筛选/摘要在上，明细列表在下。
    expect(find.byKey(const Key('effort-review-presets')), findsOneWidget);
    expect(find.byKey(const Key('effort-review-filter-conversation')),
        findsOneWidget);
    expect(find.byKey(const Key('effort-review-confirmed')), findsOneWidget);

    // 底部动作固定：滚动列表前后，按钮位置不变。
    final exportRect = tester.getRect(find.byKey(const Key('effort-review-export')));
    final closeRect = tester.getRect(find.byKey(const Key('effort-review-close')));
    expect(exportRect.top, greaterThan(tester.getRect(find.byKey(
            const Key('effort-review-filter-conversation'))).bottom));

    final list = find.byKey(const Key('effort-review-task-list'));
    expect(list, findsOneWidget);
    final firstTile = find.byKey(const Key('effort-review-task-extra-0'));
    final beforeTop = tester.getTopLeft(firstTile).dy;
    await tester.drag(list, const Offset(0, -180));
    await tester.pumpAndSettle();
    final afterTop = tester.getTopLeft(firstTile).dy;
    expect(afterTop, lessThan(beforeTop), reason: '明细列表自身滚动');
    expect(tester.getRect(find.byKey(const Key('effort-review-export'))), exportRect,
        reason: '底部导出动作固定，不随列表滚动');
    expect(tester.getRect(find.byKey(const Key('effort-review-close'))), closeRect,
        reason: '底部关闭动作固定，不随列表滚动');
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出前后同一批数据：日期范围 / 记录条数 / 分钟数一致', (tester) async {
    final f = _fixture();
    String? csv;
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      onExport: (name, content, path) async {
        csv = content;
        return true;
      },
    );
    final rangeBefore = _text(tester, const Key('effort-review-range'));
    final confirmedBefore = _text(tester, const Key('effort-review-confirmed'));
    // 展开任务行，数出 UI 上显示的原始执行记录条数。
    await tester.tap(find.byKey(const Key('effort-review-task-task-a')));
    await tester.pumpAndSettle();
    int uiRecordCount() => find
        .byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('effort-record-'))
        .evaluate()
        .length;
    final recordsBefore = uiRecordCount();
    expect(recordsBefore, 1);

    await tester.tap(find.byKey(const Key('effort-review-export')));
    await tester.pumpAndSettle();
    expect(csv, isNotNull);
    // 导出后 UI 上的日期/条数/分钟数完全没变（视觉调整不改统计口径）。
    expect(_text(tester, const Key('effort-review-range')), rangeBefore);
    expect(_text(tester, const Key('effort-review-confirmed')), confirmedBefore);
    expect(uiRecordCount(), recordsBefore);

    // CSV 里是同一批数据：统计范围 = UI 日期范围，记录行数 = UI 记录条数，
    // 范围确认分钟数合计 = UI “已确认投入”。
    final lines = const LineSplitter()
        .convert(csv!.replaceFirst('\uFEFF', ''));
    final header = lines.first.split(',');
    int column(String name) {
      final index = header.indexOf(name);
      expect(index, greaterThanOrEqualTo(0), reason: 'CSV 缺少列 $name');
      return index;
    }

    final typeColumn = column('类型');
    final minutesColumn = column('范围确认时长(分钟)');
    final rangeColumn = column('统计范围');
    final recordRows = lines
        .skip(1)
        .map((line) => line.split(','))
        .where((cells) =>
            cells.length > typeColumn &&
            (cells[typeColumn] == '记录' || cells[typeColumn] == '未归属记录'))
        .toList(growable: false);
    expect(recordRows.length, recordsBefore,
        reason: 'CSV 记录行数必须与 UI 展开的记录条数一致');
    final minutes = recordRows.fold<double>(
      0,
      (sum, cells) => sum + double.parse(cells[minutesColumn]),
    );
    expect(minutes, 30.0, reason: 'CSV 范围确认分钟数合计必须与 UI 已确认投入一致');
    expect(confirmedBefore, '30 分钟');
    expect(recordRows.every((cells) => cells[rangeColumn] == rangeBefore), isTrue,
        reason: 'CSV 统计范围必须与 UI 标题右侧的日期范围一致');
    // 未知仍然是未知，不会在导出里变成 0。
    expect(csv, contains('无实际工时记录'));
    expect(csv, contains('未知'));
  });

  testWidgets('空状态可读；未注入导出钩子时不显示导出按钮', (tester) async {
    final service = EffortReviewService(
      ledger: ExecutionLedger(),
      localTime: shanghaiLocalTime,
      nowUtc: () => testStartUtc,
    );
    await _openDialog(tester, service: service, tasks: const <ExecutionTaskInfo>[]);
    expect(find.byKey(const Key('effort-review-empty')), findsOneWidget);
    expect(find.textContaining('未知 ≠ 0'), findsOneWidget);
    expect(find.byKey(const Key('effort-review-export')), findsNothing,
        reason: '未注入导出钩子时不显示导出按钮（不伪造导出）');
    expect(find.byKey(const Key('effort-review-close')), findsOneWidget);
  });

  testWidgets('已完成但无记录：实际耗时显示“未知”，不是 0 分钟', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    expect(find.textContaining('实际 未知'), findsWidgets);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('effort-review-done-no-actual')))
          .data,
      '1',
    );
    await tester.tap(find.byKey(const Key('effort-review-task-task-b')));
    await tester.pumpAndSettle();
    expect(find.textContaining('实际耗时未知（不是 0 分钟）'), findsOneWidget);
  });

  testWidgets('自定义日期非法：可执行反馈与底部动作仍可达', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      onExport: (name, csv, path) async => true,
    );
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-review-from')), findsOneWidget);
    // 1) 无法解析的日期 → 明确格式提示，导出禁用。
    await tester.enterText(find.byKey(const Key('effort-review-from')), 'abc');
    await tester.tap(find.byKey(const Key('effort-review-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-review-range-error')), findsOneWidget);
    expect(find.textContaining('日期格式应为 YYYY-MM-DD'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(const Key('effort-review-export'))).onPressed,
      isNull,
    );
    expect(find.byKey(const Key('effort-review-close')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 2) 起止颠倒 → 按时间先后调整并给出说明（不装作没发生）。
    await tester.enterText(find.byKey(const Key('effort-review-from')), '2026-11-04');
    await tester.enterText(find.byKey(const Key('effort-review-to')), '2026-10-30');
    await tester.tap(find.byKey(const Key('effort-review-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-review-range-note')), findsOneWidget);
    expect(find.textContaining('顺序颠倒'), findsOneWidget);
  });

  testWidgets('窄窗 + 1.5 倍字号：筛选/摘要分组换行、不溢出、关闭可达', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      surface: const Size(560, 460),
      textScale: 1.5,
      onExport: (name, csv, path) async => true,
    );
    expect(find.byKey(const Key('effort-review-dialog')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '窄窗 + 大字号不得溢出');
    // 关闭（标题右侧 + 底部）与导出都在窗口内。
    final dialogRect = tester.getRect(find.byKey(const Key('effort-review-dialog')));
    for (final key in <Key>[
      const Key('effort-review-close-icon'),
      const Key('effort-review-close'),
      const Key('effort-review-export'),
      const Key('effort-review-presets'),
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(dialogRect.contains(rect.topLeft) &&
              dialogRect.contains(rect.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: '$key 必须留在卡片内');
    }
    // 分组换行后，“今日/本周/自定义”分段与筛选下拉仍可点。
    await tester.tap(find.text('本周'));
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('effort-review-range')), contains('本周'));
  });

  testWidgets('极矮窗口：中间整体滚动，底部动作仍固定', (tester) async {
    final f = _fixture(extraTasks: 4);
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      surface: const Size(720, 420),
      textScale: 1.0,
      onExport: (name, csv, path) async => true,
    );
    expect(tester.takeException(), isNull);
    final dialogRect = tester.getRect(find.byKey(const Key('effort-review-card')));
    // 卡片高度按可用窗口算上限（不是固定 660×400）。
    final media =
        MediaQuery.of(tester.element(find.byKey(const Key('effort-review-card'))));
    expect(dialogRect.height,
        closeTo(math.min(640, math.max(360, media.size.height - 64)), 1));
    expect(find.byKey(const Key('effort-review-export')), findsOneWidget);
    expect(find.byKey(const Key('effort-review-close')), findsOneWidget);
  });

  // ------------------------------------------------ R4-A 几何/交互断言

  testWidgets('常规窗口：关闭贴卡片右内缘、日期在按钮左侧且完整显示', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      preset: EffortReviewPreset.thisWeek,
    );
    _expectTitleGeometry(tester, narrow: false);
    // 本周标题完整：本周 2026-11-02 ~ 2026-11-08
    expect(_text(tester, const Key('effort-review-range')),
        startsWith('本周 2026-11-02 ~ 2026-11-08'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗：日期换行到标题下方右对齐，关闭仍贴右内缘', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      preset: EffortReviewPreset.thisWeek,
      surface: const Size(520, 460),
    );
    _expectTitleGeometry(tester, narrow: true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('150% 文字缩放：标题/日期/关闭几何仍成立且日期完整', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      preset: EffortReviewPreset.thisWeek,
      textScale: 1.5,
    );
    _expectTitleGeometry(tester, narrow: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本周 7 天每日胶囊全部完整可见（无半露被裁）', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      preset: EffortReviewPreset.thisWeek,
    );
    final card = _cardRect(tester);
    final daily = _rectOf(tester, const Key('effort-review-daily'));
    // 今日/本周按整项换行，不是横向滚动列表 —— 不应存在横向滚动/半露胶囊。
    expect(find.byKey(const Key('effort-review-daily-scroll')), findsNothing);
    final dates = <String>[
      for (var day = 2; day <= 8; day++)
        '2026-11-${day.toString().padLeft(2, '0')}',
    ];
    final rows = <double>{};
    for (final date in dates) {
      final rect = _rectOf(tester, Key('effort-review-day-$date'));
      expect(rect.width, greaterThan(20), reason: '$date 胶囊有实际宽度');
      expect(rect.height, greaterThan(10));
      // 整项完整落在每日区域与卡片内，不能被卡片/滚动视口裁掉一半。
      expect(rect.left, greaterThanOrEqualTo(daily.left - 0.5));
      expect(rect.right, lessThanOrEqualTo(daily.right + 0.5));
      expect(rect.top, greaterThanOrEqualTo(daily.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(daily.bottom + 0.5),
          reason: '$date 胶囊不能在每日区域内被裁');
      expect(rect.bottom, lessThanOrEqualTo(card.bottom + 0.5),
          reason: '$date 胶囊必须完整在卡片内');
      rows.add(rect.top);
    }
    // 7 天换行成多行而不是被裁：至少两行，且每行都完整。
    expect(rows.length, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义 61 天：每日数据有界滚动，第 61 天可滚到且完整可见',
      (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      preset: EffortReviewPreset.custom,
    );
    expect(find.byKey(const Key('effort-review-from')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('effort-review-from')), '2026-01-01');
    await tester.enterText(
        find.byKey(const Key('effort-review-to')), '2026-03-02');
    await tester.tap(find.byKey(const Key('effort-review-apply')));
    await tester.pumpAndSettle();
    expect(_text(tester, const Key('effort-review-range')),
        contains('2026-01-01'));
    expect(_text(tester, const Key('effort-review-range')),
        contains('2026-03-02'));

    // 不再 take(60)：61 个日期胶囊全部构建（第 61 天可寻址）。
    var chips = 0;
    for (var i = 0; i < 61; i++) {
      final date = DateTime.utc(2026, 1, 1).add(Duration(days: i));
      final key = Key('effort-review-day-'
          '${date.year}-${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}');
      if (find.byKey(key).evaluate().isNotEmpty) chips++;
    }
    expect(chips, 61, reason: '366 天范围内不能被 take(60) 截断');

    // 长范围每天数据放进有界高度内纵向滚动，而不是横向半露。
    final daily = _rectOf(tester, const Key('effort-review-daily'));
    final card = _cardRect(tester);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('effort-review-daily')),
          matching: find.byType(Scrollable),
        )
        .first;
    final state = tester.state<ScrollableState>(scrollable);
    expect(state.position.maxScrollExtent, greaterThan(0));
    expect(daily.bottom, lessThanOrEqualTo(card.bottom),
        reason: '每日区域高度有界，不能把任务明细挤出卡片');

    // 初始位置：最后一天还在视口下方。
    final lastKey = const Key('effort-review-day-2026-03-02');
    expect(tester.getRect(find.byKey(lastKey)).bottom,
        greaterThan(daily.bottom - 0.5),
        reason: '61 天不会一次全部铺在卡片里');

    // 滚到底后第 61 天完整可见（在每日视口与卡片内）。
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last = tester.getRect(find.byKey(lastKey));
    expect(last.top, greaterThanOrEqualTo(daily.top - 0.5));
    expect(last.bottom, lessThanOrEqualTo(daily.bottom + 0.5),
        reason: '滚到底后第 61 天必须完整可见（不能半露被裁）');
    expect(last.right, lessThanOrEqualTo(card.right + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选下拉：宽度有界、窄窗整组换行、长会话名选项可读且联动过滤',
      (tester) async {
    final f = _fixture();
    const longTitle = '在11月20-24日课程与巡演约束下排定7项作业与申报任务的完成时间';
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      surface: const Size(720, 620),
      conversations: <ExecutionConversationInfo>[
        conversationInfo(id: 'conv-1', title: '顺序表实验'),
        conversationInfo(id: 'conv-2', title: longTitle),
      ],
    );
    final card = _cardRect(tester);
    final convDrop = _rectOf(tester, const Key('effort-review-filter-conversation'));
    final taskDrop = _rectOf(tester, const Key('effort-review-filter-task'));
    // 有界宽度：不再使用 150/170 固定宽度（会裁掉长名称），且都在卡片内。
    expect(convDrop.width, lessThanOrEqualTo(card.width / 2 + 1));
    expect(convDrop.width, greaterThan(80));
    for (final rect in <Rect>[convDrop, taskDrop]) {
      expect(rect.left, greaterThanOrEqualTo(card.left + 10));
      expect(rect.right, lessThanOrEqualTo(card.right - 10));
    }
    expect(tester.takeException(), isNull);

    // 打开长会话名的菜单：选项以完整名称出现（两行内可读，不被省略号截断）。
    await tester.tap(find.byKey(const Key('effort-review-filter-conversation')));
    await tester.pumpAndSettle();
    expect(find.text(longTitle), findsOneWidget);
    final itemRect = tester.getRect(find.text(longTitle));
    expect(itemRect.width, greaterThan(120));
    // 菜单项允许两行；选中后按钮里是单行省略显示。
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(longTitle));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 1,
        reason: '选择后菜单关闭，按钮内以单行显示选中项');

    // 会话联动过滤：conv-2 没有记录 → 已确认投入 0 分钟（未知语义不变）。
    expect(_text(tester, const Key('effort-review-confirmed')), '0 分钟');
    expect(find.byKey(const Key('effort-review-remaining')), findsOneWidget);
  });

  testWidgets('窄窗筛选整组换行且两项不重叠', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      surface: const Size(480, 560),
    );
    final card = _cardRect(tester);
    final convDrop = _rectOf(tester, const Key('effort-review-filter-conversation'));
    final taskDrop = _rectOf(tester, const Key('effort-review-filter-task'));
    expect(convDrop.overlaps(taskDrop), isFalse, reason: '整组换行后两项不能重叠');
    expect(taskDrop.top, greaterThanOrEqualTo(convDrop.bottom - 0.5),
        reason: '窄窗下第二个下拉换到下一行');
    expect(convDrop.right, lessThanOrEqualTo(card.right - 10));
    expect(taskDrop.right, lessThanOrEqualTo(card.right - 10));
    // 所有统计项（含最右“建议剩余”）都有可见位置且在卡片内。
    for (final key in <Key>[
      const Key('effort-review-confirmed'),
      const Key('effort-review-pending'),
      const Key('effort-review-completed'),
      const Key('effort-review-delayed'),
      const Key('effort-review-done-no-actual'),
      const Key('effort-review-unestimated'),
      const Key('effort-review-remaining'),
    ]) {
      final rect = _rectOf(tester, key);
      expect(rect.left, greaterThanOrEqualTo(card.left - 0.5));
      expect(rect.right, lessThanOrEqualTo(card.right + 0.5),
          reason: '$key 不能被卡片右缘裁掉');
      expect(rect.top, greaterThanOrEqualTo(card.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(card.bottom + 0.5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('150% 字号 + 窄窗：统计项与“建议剩余”仍完整可见', (tester) async {
    final f = _fixture();
    await _openDialog(
      tester,
      service: f.service,
      tasks: f.tasks,
      surface: const Size(560, 520),
      textScale: 1.5,
    );
    final card = _cardRect(tester);
    final remaining = _rectOf(tester, const Key('effort-review-remaining'));
    expect(remaining.right, lessThanOrEqualTo(card.right + 0.5),
        reason: '“建议剩余”不能被裁到卡片外');
    expect(remaining.left, greaterThanOrEqualTo(card.left - 0.5));
    expect(remaining.bottom, lessThanOrEqualTo(card.bottom + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开任务不截行：可滚动到明细与最后一条任务', (tester) async {
    final f = _fixture(extraTasks: 24);
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    final card = _cardRect(tester);
    // 展开第一条任务：记录行完整可见（不截行）。
    await tester.tap(find.byKey(const Key('effort-review-task-task-a')));
    await tester.pumpAndSettle();
    final record = find.byKey(const Key('effort-record-r1'));
    expect(record, findsOneWidget);
    final recordRect = tester.getRect(record);
    expect(recordRect.right, lessThanOrEqualTo(card.right + 0.5));
    expect(recordRect.left, greaterThanOrEqualTo(card.left - 0.5));

    // 滚到底：最后一条任务完整可见。
    final outer = find
        .descendant(
          of: find.byKey(const Key('effort-review-task-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    final state = tester.state<ScrollableState>(outer);
    state.position.jumpTo(state.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final lastTile = tester.getRect(
        find.byKey(const Key('effort-review-task-extra-23')));
    expect(lastTile.bottom, lessThanOrEqualTo(card.bottom + 0.5),
        reason: '滚到底后最后一条任务完整可见');
    expect(tester.takeException(), isNull);
  });

  testWidgets('空状态与表单错误都完整落在卡片内', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('effort-review-from')), 'abc');
    await tester.tap(find.byKey(const Key('effort-review-apply')));
    await tester.pumpAndSettle();
    final card = _cardRect(tester);
    final errorRect = _rectOf(tester, const Key('effort-review-range-error'));
    expect(errorRect.right, lessThanOrEqualTo(card.right + 0.5),
        reason: '表单错误不能被裁');
    // 错误状态下正文给出空状态提示，同样完整可见。
    final emptyRect = _rectOf(tester, const Key('effort-review-empty'));
    expect(emptyRect.left, greaterThanOrEqualTo(card.left - 0.5));
    expect(emptyRect.right, lessThanOrEqualTo(card.right + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc 关闭弹窗', (tester) async {
    final f = _fixture();
    await _openDialog(tester, service: f.service, tasks: f.tasks);
    expect(find.byKey(const Key('effort-review-dialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-review-dialog')), findsNothing,
        reason: 'Esc 必须仍然能关闭执行回顾');
  });
}
