// R2「设置 → 外部日历」来源管理页（widget 测试）。
//
// 覆盖：空状态与新建导入、来源列表信息（名称/启用开关/范围/事件实例数/hash/导入
// 时间/诊断）、启用/停用、改名、更新（重新选文件）、删除（显示受影响会话与事件数
// 并确认）、数据变化后 onChanged 被调用。
//
// 注入假 service（与真实 ExternalCalendarService 同一契约）：真实实现的
// preview/commit 会读写真实文件，而 testWidgets 的假异步不会完成真实 dart:io
// Future；存储/解析由 T-C 的纯逻辑测试覆盖，这里只验证页面行为。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/ui/external_calendar_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/settings/settings_external_calendar_page.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

const String _tz = 'Asia/Shanghai';
const String _from = '2026-11-09';
const String _to = '2026-11-22';
const String _hash = 'deadbeefcafebabe0011223344556677';

const ExtImportStats _stats = ExtImportStats(
  readEvents: 2,
  expandedInstances: 3,
  busyMinutes: 150,
  transparentEvents: 1,
  cancelledEvents: 0,
  tentativeInstances: 1,
  warningCount: 1,
  unsupportedCount: 0,
  ignoredComponents: 2,
);

ExternalEventRecord _nightEvent() => const ExternalEventRecord(
      uid: 'night@test',
      startUtc: '2026-11-09T15:00:00.000Z',
      endUtc: '2026-11-09T17:00:00.000Z',
      summary: '夜间值班',
    );

ExternalEventRecord _replacementEvent() => const ExternalEventRecord(
      uid: 'replacement@test',
      startUtc: '2026-11-12T01:00:00.000Z',
      endUtc: '2026-11-12T02:30:00.000Z',
      summary: '替换事件',
    );

ExternalCalendarSource _source({
  String id = 'ext-000000000001',
  String name = '测试日历',
  int revision = 1,
  bool enabled = true,
  ExtImportStats stats = _stats,
}) =>
    ExternalCalendarSource(
      id: id,
      name: name,
      filePath: 'C:/fixtures/valid.ics',
      contentHash: _hash,
      importedAt: '2026-11-04T03:04:05.000Z',
      revision: revision,
      dateFrom: _from,
      dateTo: _to,
      timezoneId: _tz,
      enabled: enabled,
      stats: stats,
      policy: const ExternalCalendarPolicy(
        floatingTimezoneId: _tz,
        floatingConfirmed: true,
      ),
    );

ExternalSourceSnapshot _snapshotOf(
  ExternalCalendarSource source,
  List<ExternalEventRecord> events,
) =>
    ExternalSourceSnapshot(
      sourceId: source.id,
      revision: source.revision,
      contentHash: source.contentHash,
      timezoneId: source.timezoneId,
      dateFrom: source.dateFrom,
      dateTo: source.dateTo,
      policy: source.policy,
      events: events,
      stats: source.stats,
    );

ExternalImportPreview _commitPreview({
  required ExternalCalendarSource? existing,
  required List<ExternalEventRecord> events,
  required ExternalImportDiff diff,
  required bool replaceMode,
}) {
  final candidate = existing == null
      ? _source(name: 'valid', revision: 1)
      : existing.copyWith(
          revision: existing.revision + 1,
          importedAt: '2026-11-05T00:00:00.000Z',
        );
  return ExternalImportPreview(
    existingSource: existing,
    candidate: candidate,
    snapshot: ExternalSourceSnapshot(
      sourceId: candidate.id,
      revision: candidate.revision,
      contentHash: candidate.contentHash,
      timezoneId: _tz,
      dateFrom: _from,
      dateTo: _to,
      events: events,
      warnings: const <ExtImportWarning>[],
      stats: candidate.stats,
    ),
    diff: diff,
    warnings: const <ExtImportWarning>[],
    replaceMode: replaceMode,
  );
}

class _FakeService extends ChangeNotifier implements ExternalCalendarService {
  _FakeService();

  final List<ExternalCalendarSource> _sources = <ExternalCalendarSource>[];
  final Map<String, ExternalSourceSnapshot> _snapshots =
      <String, ExternalSourceSnapshot>{};
  String? _lastError;
  int commitCalls = 0;

  void seed(ExternalCalendarSource source, List<ExternalEventRecord> events) {
    _sources.add(source);
    _snapshots[source.id] = _snapshotOf(source, events);
  }

  @override
  List<ExternalCalendarSource> get sources =>
      List<ExternalCalendarSource>.unmodifiable(_sources);

  @override
  ExternalSourceSnapshot? snapshotOf(String id) => _snapshots[id];

  @override
  String? get lastError => _lastError;

  @override
  Future<ExternalImportPreview?> preview({
    required String filePath,
    ExternalCalendarSource? existing,
    required String timezoneId,
    required ExternalCalendarPolicy policy,
    required String dateFrom,
    required String dateTo,
    required bool replaceMode,
  }) async =>
      _commitPreview(
        existing: existing,
        events: filePath.contains('replace')
            ? <ExternalEventRecord>[_replacementEvent()]
            : <ExternalEventRecord>[_nightEvent()],
        diff: filePath.contains('replace')
            ? const ExternalImportDiff(added: 1, removed: 1)
            : const ExternalImportDiff(added: 1),
        replaceMode: replaceMode,
      );

  @override
  Future<bool> commit(ExternalImportPreview preview) async {
    commitCalls++;
    final candidate = preview.candidate;
    _sources.removeWhere((s) => s.id == candidate.id);
    _sources.add(candidate);
    _snapshots[candidate.id] = preview.snapshot;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setEnabled(String id, bool enabled) async {
    final index = _sources.indexWhere((s) => s.id == id);
    if (index < 0) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    _sources[index] = _sources[index].copyWith(enabled: enabled);
    notifyListeners();
    return true;
  }

  @override
  Future<bool> rename(String id, String name) async {
    final index = _sources.indexWhere((s) => s.id == id);
    if (index < 0) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _lastError = '名称不能为空';
      return false;
    }
    _sources[index] = _sources[index].copyWith(name: trimmed);
    notifyListeners();
    return true;
  }

  @override
  Future<bool> remove(String id) async {
    final before = _sources.length;
    _sources.removeWhere((s) => s.id == id);
    if (_sources.length == before) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    _snapshots.remove(id);
    notifyListeners();
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

late _FakeService _service;

Future<void> _pumpPage(
  WidgetTester tester, {
  VoidCallback? onChanged,
  Future<List<String>> Function()? pick,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 1000);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SettingsExternalCalendarPage(
          service: _service,
          timezoneId: _tz,
          currentConversationTitle: '会话 A',
          onChanged: onChanged,
          pickFiles: pick,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    _service = _FakeService();
    ExternalCalendarFilePicker.defaultPick = null;
  });

  tearDown(() {
    ExternalCalendarFilePicker.defaultPick = null;
    _service.dispose();
  });

  testWidgets('零来源时只显示来源计数与新建导入，三组说明不再出现', (tester) async {
    final semantics = tester.ensureSemantics();
    var changed = 0;
    await _pumpPage(
      tester,
      onChanged: () => changed++,
      pick: () async => <String>['C:/fixtures/valid.ics'],
    );

    // 三组常驻说明必须从控件树移除：不是透明字体、同色字体或空白占位。
    expect(find.byKey(const Key('external-calendar-page-intro')), findsNothing);
    expect(
        find.byKey(const Key('external-calendar-sources-empty')), findsNothing);
    expect(find.byKey(const Key('external-calendar-page-note')), findsNothing);
    expect(find.text('外部日历（本地 ICS，只读）'), findsNothing);
    expect(find.textContaining('还没有导入任何外部日历'), findsNothing);
    expect(find.textContaining('外部占用以浅灰斜纹叠加'), findsNothing);
    // 语义树同样不得残留这三段（没有隐藏占位）。
    expect(find.bySemanticsLabel(RegExp('本地 ICS，只读')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('还没有导入任何外部日历')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('浅灰斜纹')), findsNothing);

    // 零来源只保留“来源 0 个”+“新建导入”，并保持紧凑（没有空段落占高）。
    expect(find.text('来源 0 个'), findsOneWidget);
    expect(
        find.byKey(const Key('external-calendar-new-import')), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const Key('settings-external-calendar-page')))
          .height,
      lessThan(120),
      reason: '零来源不应保留说明段落或该组专用间距',
    );

    await tester.tap(find.byKey(const Key('external-calendar-new-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-import-dialog')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('external-calendar-pick-file')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('external-calendar-import-confirm')));
    await tester.pumpAndSettle();

    expect(_service.sources, hasLength(1));
    expect(changed, 1, reason: '导入成功后必须通知应用刷新');
    expect(
        find.byKey(const Key('external-calendar-sources-empty')), findsNothing);
    final source = _service.sources.single;
    expect(find.byKey(Key('external-calendar-source-${source.id}')),
        findsOneWidget);
    expect(find.byKey(Key('external-calendar-source-name-${source.id}')),
        findsOneWidget);
    // 有来源后说明仍然不存在。
    expect(find.byKey(const Key('external-calendar-page-intro')), findsNothing);
    expect(find.byKey(const Key('external-calendar-page-note')), findsNothing);
    semantics.dispose();
  });

  testWidgets('来源列表显示范围/事件实例数/hash/导入时间/诊断与启用开关，且说明不出现', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[
      _nightEvent(),
      _replacementEvent(),
    ]);
    await _pumpPage(tester);

    expect(find.text('来源 1 个'), findsOneWidget);
    // 非空时也不再有分组标题/说明/底部提示。
    expect(find.byKey(const Key('external-calendar-page-intro')), findsNothing);
    expect(find.byKey(const Key('external-calendar-page-note')), findsNothing);
    expect(find.text('外部日历（本地 ICS，只读）'), findsNothing);
    // 非空来源的全部操作入口都可用。
    expect(find.byKey(Key('external-calendar-source-toggle-${source.id}')),
        findsOneWidget);
    expect(find.byKey(Key('external-calendar-source-update-${source.id}')),
        findsOneWidget);
    expect(find.byKey(Key('external-calendar-source-rename-${source.id}')),
        findsOneWidget);
    expect(find.byKey(Key('external-calendar-source-delete-${source.id}')),
        findsOneWidget);
    expect(
        find.byKey(Key('external-calendar-source-${source.id}')), findsOneWidget);
    expect(
      tester
          .widget<Text>(
              find.byKey(Key('external-calendar-source-meta-${source.id}')))
          .data,
      contains(source.contentHash.substring(0, 8)),
    );
    expect(
      tester
          .widget<Text>(
              find.byKey(Key('external-calendar-source-range-${source.id}')))
          .data,
      contains(_from),
    );
    expect(find.byKey(Key('external-calendar-source-diagnostics-${source.id}')),
        findsOneWidget);
    final switchWidget = tester.widget<Switch>(
        find.byKey(Key('external-calendar-source-toggle-${source.id}')));
    expect(switchWidget.value, isTrue);
  });

  testWidgets('停用/启用来源会写回并通知应用', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[_nightEvent()]);
    var changed = 0;
    await _pumpPage(tester, onChanged: () => changed++);

    await tester
        .tap(find.byKey(Key('external-calendar-source-toggle-${source.id}')));
    await tester.pumpAndSettle();
    expect(_service.sources.single.enabled, isFalse);
    expect(changed, 1);
    expect(find.text('已停用'), findsOneWidget);

    await tester
        .tap(find.byKey(Key('external-calendar-source-toggle-${source.id}')));
    await tester.pumpAndSettle();
    expect(_service.sources.single.enabled, isTrue);
    expect(changed, 2);
  });

  testWidgets('改名写回并通知应用，空名称被拒绝', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[_nightEvent()]);
    var changed = 0;
    await _pumpPage(tester, onChanged: () => changed++);

    await tester
        .tap(find.byKey(Key('external-calendar-source-rename-${source.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-rename-field')),
        findsOneWidget);
    // 标签已缩为“来源名称”，不再附带“不影响模型请求”的常驻解释。
    expect(find.text('来源名称'), findsOneWidget);
    expect(find.textContaining('只影响本地显示'), findsNothing);

    // 空名称：确认按钮不提交（对话框保持打开）。
    await tester.enterText(
        find.byKey(const Key('external-calendar-rename-field')), '   ');
    await tester.tap(find.byKey(const Key('external-calendar-rename-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-rename-field')),
        findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('external-calendar-rename-field')), '我的工作日历');
    await tester.tap(find.byKey(const Key('external-calendar-rename-confirm')));
    await tester.pumpAndSettle();
    expect(_service.sources.single.name, '我的工作日历');
    expect(changed, 1);
    expect(find.text('我的工作日历'), findsWidgets);
  });

  testWidgets('更新走重新选文件的完整替换，取消不改变来源', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[
      _nightEvent(),
      _replacementEvent(),
    ]);
    await _pumpPage(
        tester, pick: () async => <String>['C:/fixtures/replace.ics']);

    await tester
        .tap(find.byKey(Key('external-calendar-source-update-${source.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-import-dialog')),
        findsOneWidget);
    expect(find.text('重新导入「测试日历」'), findsOneWidget);
    await tester.tap(find.byKey(const Key('external-calendar-pick-file')));
    await tester.pumpAndSettle();
    expect(find.textContaining('完整替换'), findsWidgets);

    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();
    expect(_service.sources.single.name, source.name);
    expect(_service.sources.single.revision, source.revision);
    expect(_service.snapshotOf(source.id)!.events, hasLength(2));
  });

  testWidgets('删除显示受影响会话与事件数，取消不删、确认后删除并通知', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[
      _nightEvent(),
      _replacementEvent(),
    ]);
    var changed = 0;
    await _pumpPage(tester, onChanged: () => changed++);

    await tester
        .tap(find.byKey(Key('external-calendar-source-delete-${source.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('受影响事件'), findsOneWidget);
    expect(find.textContaining('2 条'), findsWidgets);
    expect(find.textContaining('会话 A'), findsWidgets);
    expect(find.textContaining('受影响会话'), findsOneWidget);

    await tester.tap(find.byKey(const Key('external-calendar-delete-cancel')));
    await tester.pumpAndSettle();
    expect(_service.sources, hasLength(1));
    expect(changed, 0);

    await tester
        .tap(find.byKey(Key('external-calendar-source-delete-${source.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('external-calendar-delete-confirm')));
    await tester.pumpAndSettle();
    expect(_service.sources, isEmpty);
    expect(changed, 1);
    // 删到零后恢复紧凑空态：只有“来源 0 个”+“新建导入”，没有多余空卡片。
    expect(find.byKey(Key('external-calendar-source-${source.id}')),
        findsNothing);
    expect(find.text('来源 0 个'), findsOneWidget);
    expect(
        find.byKey(const Key('external-calendar-new-import')), findsOneWidget);
    expect(
        find.byKey(const Key('external-calendar-sources-empty')), findsNothing);
    expect(find.textContaining('还没有导入任何外部日历'), findsNothing);
    expect(find.byKey(const Key('external-calendar-page-note')), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const Key('settings-external-calendar-page')))
          .height,
      lessThan(120),
      reason: '最后一个来源删除后不应留下空卡片或说明占位',
    );
  });

  testWidgets('服务端变化会刷新页面（例如其它入口导入/启停）', (tester) async {
    final source = _source();
    _service.seed(source, <ExternalEventRecord>[_nightEvent()]);
    await _pumpPage(tester);
    expect(
      tester
          .widget<Switch>(
              find.byKey(Key('external-calendar-source-toggle-${source.id}')))
          .value,
      isTrue,
    );
    await tester.runAsync(() => _service.setEnabled(source.id, false));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
              find.byKey(Key('external-calendar-source-toggle-${source.id}')))
          .value,
      isFalse,
    );
  });
}
