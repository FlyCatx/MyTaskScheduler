// R2 外部日历导入向导（widget 测试）。
//
// 覆盖：预览（来源/范围/事件数/实例数/占用分钟/透明与取消计数/新增修改移除/
// 警告/含跨午夜与全天的样例）、取消不改数据、读取失败明确报错、空文件/只含
// 不支持组件的文件明确报错、完整替换二次确认、确认后写入来源快照。
//
// 这里注入一个假 service（与真实 ExternalCalendarService 同一契约）：
//   * 真实 service 的 preview/commit 会读写真实文件，而 testWidgets 的假异步
//     不会完成真实 dart:io Future；解析/存储逻辑由 T-C 的纯逻辑测试覆盖；
//   * 本文件只验证 UI 对契约字段（preview.isEmpty / diff / warnings / truncated /
//     replaceMode / lastError）的呈现与交互；文件选择用假回调注入。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:taskscheduler_flutter/src/model/external_calendar.dart';
import 'package:taskscheduler_flutter/src/state/external_calendar_service.dart';
import 'package:taskscheduler_flutter/src/ui/external_calendar_dialog.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

const String _tz = 'Asia/Shanghai';
const String _from = '2026-11-09';
const String _to = '2026-11-22';
const String _hash = 'deadbeefcafebabe0011223344556677';

ExternalEventRecord _nightEvent() => const ExternalEventRecord(
      uid: 'night@test',
      startUtc: '2026-11-09T15:00:00.000Z',
      endUtc: '2026-11-09T17:00:00.000Z',
      summary: '夜间值班',
    );

ExternalEventRecord _allDayEvent() => const ExternalEventRecord(
      uid: 'all-day@test',
      startUtc: '2026-11-10T00:00:00.000Z',
      endUtc: '2026-11-11T00:00:00.000Z',
      allDay: true,
      summary: '全天培训',
    );

ExternalEventRecord _replacementEvent() => const ExternalEventRecord(
      uid: 'replacement@test',
      startUtc: '2026-11-12T01:00:00.000Z',
      endUtc: '2026-11-12T02:30:00.000Z',
      summary: '替换后只保留这一条',
    );

const ExtImportStats _stats = ExtImportStats(
  readEvents: 2,
  expandedInstances: 3,
  busyMinutes: 150,
  transparentEvents: 1,
  cancelledEvents: 0,
  tentativeInstances: 1,
  warningCount: 1,
  unsupportedCount: 0,
);

const List<ExtImportWarning> _warnings = <ExtImportWarning>[
  ExtImportWarning('test-warning', '合成警告：测试用'),
];

ExternalCalendarSource _source({ExternalCalendarSource? existing}) =>
    ExternalCalendarSource(
      id: existing?.id ?? 'ext-000000000001',
      name: existing?.name ?? '测试日历',
      filePath: 'C:/fixtures/valid.ics',
      contentHash: _hash,
      importedAt: '2026-11-04T00:00:00.000Z',
      revision: (existing?.revision ?? 0) + 1,
      dateFrom: _from,
      dateTo: _to,
      timezoneId: _tz,
      stats: _stats,
    );

ExternalImportPreview _previewOf({
  required List<ExternalEventRecord> events,
  ExternalCalendarSource? existing,
  ExternalImportDiff? diff,
  bool replaceMode = false,
  bool truncated = false,
  bool metadataChanged = false,
  List<ExtImportWarning> warnings = _warnings,
}) {
  final candidate = _source(existing: existing);
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
      warnings: warnings,
      stats: _stats,
    ),
    diff: diff ??
        ExternalImportDiff(
          added: events.length,
          unchanged: 0,
          unsupported: 0,
        ),
    warnings: warnings,
    replaceMode: replaceMode,
    metadataChanged: metadataChanged,
    truncated: truncated,
  );
}

class _FakeService extends ChangeNotifier implements ExternalCalendarService {
  final List<ExternalCalendarSource> _sources = <ExternalCalendarSource>[];
  final Map<String, ExternalSourceSnapshot> _snapshots =
      <String, ExternalSourceSnapshot>{};

  String? _lastError;
  int previewCalls = 0;
  int commitCalls = 0;
  ExternalImportPreview? committed;

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
  }) async {
    previewCalls++;
    _lastError = null;
    if (filePath.contains('bad')) {
      _lastError = '无法解析该文件（不是有效的 ICS 日历）';
      return null;
    }
    if (filePath.contains('empty')) {
      return _previewOf(
        events: const <ExternalEventRecord>[],
        existing: existing,
        diff: const ExternalImportDiff(),
        warnings: const <ExtImportWarning>[
          ExtImportWarning('no-events', '文件里没有可导入的事件'),
        ],
      );
    }
    if (filePath.contains('todo')) {
      return _previewOf(
        events: const <ExternalEventRecord>[],
        existing: existing,
        diff: const ExternalImportDiff(unsupported: 1),
        warnings: const <ExtImportWarning>[
          ExtImportWarning('ignored-components', 'VTODO 只统计、不导入'),
        ],
      );
    }
    if (filePath.contains('replace')) {
      return _previewOf(
        events: <ExternalEventRecord>[_replacementEvent()],
        existing: existing,
        diff: const ExternalImportDiff(added: 1, removed: 1),
        replaceMode: replaceMode,
        warnings: const <ExtImportWarning>[],
      );
    }
    return _previewOf(
      events: <ExternalEventRecord>[_nightEvent(), _allDayEvent()],
      existing: existing,
      diff: const ExternalImportDiff(added: 2, unchanged: 0),
    );
  }

  @override
  Future<bool> commit(ExternalImportPreview preview) async {
    commitCalls++;
    _lastError = null;
    if (preview.snapshot.events.isEmpty &&
        (preview.existingSource == null || !preview.replaceMode)) {
      _lastError = '没有可导入的事件，未创建/更新来源';
      return false;
    }
    final candidate = preview.candidate;
    _sources.removeWhere((s) => s.id == candidate.id);
    _sources.add(candidate);
    _snapshots[candidate.id] = preview.snapshot;
    committed = preview;
    notifyListeners();
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

late _FakeService _service;
bool? _lastImported;

Future<void> _openDialog(
  WidgetTester tester, {
  Future<List<String>> Function()? pick,
  ExternalCalendarSource? existing,
  bool replaceDefault = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1100, 900);
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  _lastImported = null;
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open-dialog'),
            onPressed: () async {
              _lastImported = await showExternalCalendarImportDialog(
                context,
                service: _service,
                timezoneId: _tz,
                planningDateFrom: _from,
                planningDateTo: _to,
                existingSource: existing,
                replaceModeDefault: replaceDefault,
                pickFiles: pick == null ? null : () async => pick(),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open-dialog')));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('external-calendar-pick-file')));
  await tester.pumpAndSettle();
}

Finder get _confirmButton =>
    find.byKey(const Key('external-calendar-import-confirm'));

bool _confirmEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_confirmButton).onPressed != null;

Future<ExternalCalendarSource> _seedExisting() async {
  const diff = ExternalImportDiff(added: 2);
  final preview = _previewOf(
    events: <ExternalEventRecord>[_nightEvent(), _allDayEvent()],
    diff: diff,
  );
  await _service.commit(preview);
  return _service.sources.single;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  setUp(() {
    _service = _FakeService();
    ExternalCalendarFilePicker.defaultPick = null;
  });

  tearDown(() {
    ExternalCalendarFilePicker.defaultPick = null;
    _service.dispose();
  });

  testWidgets('预览显示统计、差异、警告与含跨午夜/全天的样例', (tester) async {
    await _openDialog(tester, pick: () async => <String>['C:/fixtures/valid.ics']);
    expect(find.byKey(const Key('external-calendar-preview')), findsNothing);
    await _pick(tester);

    expect(find.byKey(const Key('external-calendar-preview')), findsOneWidget);
    expect(find.textContaining('2 条事件'), findsWidgets);
    expect(find.byKey(const Key('external-calendar-diff')), findsOneWidget);
    expect(find.textContaining('待新增'), findsWidgets);
    expect(find.byKey(const Key('external-calendar-warnings')), findsOneWidget);
    expect(find.byKey(const Key('external-calendar-samples')), findsOneWidget);
    // 样例必须覆盖跨午夜与全天（合同要求的可读预览）。
    expect(find.textContaining('跨午夜'), findsWidgets);
    expect(find.textContaining('全天'), findsWidgets);
    expect(_confirmEnabled(tester), isTrue);
  });

  testWidgets('取消不改任何数据（不写来源、不写快照）', (tester) async {
    await _openDialog(tester, pick: () async => <String>['C:/fixtures/valid.ics']);
    await _pick(tester);
    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();

    expect(_lastImported, isFalse);
    expect(_service.sources, isEmpty);
    expect(_service.commitCalls, 0);
    expect(
        find.byKey(const Key('external-calendar-import-dialog')), findsNothing);
  });

  testWidgets('确认后写入来源与快照，并返回 true', (tester) async {
    await _openDialog(tester, pick: () async => <String>['C:/fixtures/valid.ics']);
    await _pick(tester);
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();

    expect(_lastImported, isTrue);
    expect(_service.commitCalls, 1);
    expect(_service.sources, hasLength(1));
    final source = _service.sources.single;
    expect(source.timezoneId, _tz);
    expect(source.dateFrom, _from);
    expect(source.dateTo, _to);
    expect(source.revision, 1);
    final snapshot = _service.snapshotOf(source.id);
    expect(snapshot, isNotNull);
    expect(snapshot!.events, hasLength(2));
    expect(
        find.byKey(const Key('external-calendar-import-dialog')), findsNothing);
  });

  testWidgets('读取失败时明确报错，且不改动已导入的数据', (tester) async {
    final existing = await _seedExisting();
    final callsAfterSeed = _service.commitCalls;
    await _openDialog(
      tester,
      pick: () async => <String>['C:/fixtures/bad.ics'],
      existing: existing,
    );
    await _pick(tester);

    final blocked = find.byKey(const Key('external-calendar-import-blocked'));
    final error = find.byKey(const Key('external-calendar-import-error'));
    expect(blocked.evaluate().isNotEmpty || error.evaluate().isNotEmpty, isTrue,
        reason: '读取失败必须有明确错误，不能显示“成功导入 0 项”');
    expect(find.textContaining('无法解析该文件'), findsOneWidget);
    expect(_confirmEnabled(tester), isFalse);

    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();
    expect(_lastImported, isFalse);
    expect(_service.commitCalls, callsAfterSeed);
    expect(_service.sources.single.revision, existing.revision);
  });

  testWidgets('空文件明确报错，不写数据', (tester) async {
    await _openDialog(tester, pick: () async => <String>['C:/fixtures/empty.ics']);
    await _pick(tester);

    expect(find.byKey(const Key('external-calendar-import-blocked')),
        findsOneWidget);
    expect(find.textContaining('没有可导入'), findsWidgets);
    expect(_confirmEnabled(tester), isFalse);
    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();
    expect(_lastImported, isFalse);
    expect(_service.sources, isEmpty);
  });

  testWidgets('只含不支持组件的文件明确报错，不写数据', (tester) async {
    await _openDialog(tester, pick: () async => <String>['C:/fixtures/todo.ics']);
    await _pick(tester);

    expect(find.byKey(const Key('external-calendar-import-blocked')),
        findsOneWidget);
    expect(find.textContaining('不支持'), findsWidgets);
    expect(_confirmEnabled(tester), isFalse);
    await tester.tap(find.byKey(const Key('external-calendar-import-cancel')));
    await tester.pumpAndSettle();
    expect(_lastImported, isFalse);
    expect(_service.sources, isEmpty);
  });

  testWidgets('结果被截断时给出明确提示（不显示成完整导入）', (tester) async {
    // 用一个独立 fake 子类覆盖 preview，返回 truncated=true 的预览。
    final truncated = _TruncatedService();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open-truncated'),
              onPressed: () async {
                _lastImported = await showExternalCalendarImportDialog(
                  context,
                  service: truncated,
                  timezoneId: _tz,
                  planningDateFrom: _from,
                  planningDateTo: _to,
                  pickFiles: () async => <String>['C:/fixtures/valid.ics'],
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-truncated')));
    await tester.pumpAndSettle();
    await _pick(tester);
    expect(find.byKey(const Key('external-calendar-truncated')),
        findsOneWidget);
    expect(find.textContaining('结果不完整'), findsWidgets);
    truncated.dispose();
  });

  testWidgets('完整替换需要二次确认，并在确认后移除旧事件', (tester) async {
    final existing = await _seedExisting();
    final callsAfterSeed = _service.commitCalls;
    await _openDialog(
      tester,
      pick: () async => <String>['C:/fixtures/replace.ics'],
      existing: existing,
      replaceDefault: true,
    );
    await _pick(tester);
    expect(find.byKey(const Key('external-calendar-mode-note')), findsOneWidget);
    expect(find.textContaining('完整替换'), findsWidgets);

    // 第一次确认 → 弹出二次确认（显示将移除的数量与新旧范围）。
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external-calendar-replace-confirm-dialog')),
        findsOneWidget);
    expect(find.textContaining('将移除'), findsWidgets);
    expect(find.textContaining('原覆盖范围'), findsOneWidget);
    expect(find.textContaining('新覆盖范围'), findsOneWidget);

    // 取消二次确认：停留在导入向导，数据不变。
    await tester.tap(find.byKey(const Key('external-calendar-replace-cancel')));
    await tester.pumpAndSettle();
    expect(_lastImported, isNull);
    expect(_service.commitCalls, callsAfterSeed);
    expect(_service.sources.single.revision, existing.revision);

    // 再次确认并真正执行替换。
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('external-calendar-replace-confirm')));
    await tester.pumpAndSettle();
    expect(_lastImported, isTrue);
    expect(_service.commitCalls, callsAfterSeed + 1);
    expect(_service.sources, hasLength(1));
    final snapshot = _service.snapshotOf(existing.id);
    expect(snapshot, isNotNull);
    expect(snapshot!.events, hasLength(1),
        reason: '完整替换后旧事件必须被移除');
    expect(snapshot.events.single.uid, 'replacement@test');
  });

  testWidgets('用户取消选择文件时静默返回，不写数据', (tester) async {
    await _openDialog(tester, pick: () async => const <String>[]);
    await _pick(tester);
    expect(_lastImported, isNull);
    expect(_service.previewCalls, 0);
    expect(_service.sources, isEmpty);
    expect(find.byKey(const Key('external-calendar-import-error')), findsNothing);
  });

  testWidgets('未注入且未接线时，选择文件给出明确原因而不是静默失败', (tester) async {
    await _openDialog(tester, pick: null);
    await tester.tap(find.byKey(const Key('external-calendar-pick-file')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('external-calendar-import-error')), findsOneWidget);
    expect(find.textContaining('文件选择不可用'), findsOneWidget);
    expect(_service.sources, isEmpty);
  });
}

/// 预览触发资源上限的 fake：只用于验证“结果不完整”提示。
class _TruncatedService extends _FakeService {
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
      _previewOf(
        events: <ExternalEventRecord>[_nightEvent()],
        diff: const ExternalImportDiff(added: 1),
        truncated: true,
      );
}
