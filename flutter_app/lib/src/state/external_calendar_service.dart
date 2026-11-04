// 外部日历服务：来源管理 + 导入预览 + 原子提交 + 运行时忙碌实例。
//
// 这一层是全纯逻辑与文件系统之间的胶水，不依赖 Widget：
//   * 来源（ExternalCalendarSource）与快照（ExternalSourceSnapshot）都落盘；
//   * 同一份文件重复导入必须**幂等**：内容哈希、时区、策略、范围都没变时
//     diff 全 0、revision 不变、不产生任何写入；
//   * 不同来源互不影响：同 UID 出现在两个来源里也是两份独立数据；
//   * commit 是原子的：先写快照再写来源列表；任一步失败都回滚，旧数据保持
//     可用并返回 false + lastError；
//   * remove 只删自己的快照，不碰其他来源；
//   * 指纹（fingerprint）= 启用来源的 id+revision+contentHash 的稳定哈希，
//     供 T-D 做“外部日历过期/迟到结果”判断。
//
// 只读语义：本层永不修改原始 ICS 文件，也不向任何远程服务发请求。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../model/calendar.dart' show parseDateKey, WallClock;
import '../model/external_calendar.dart';
import 'external_calendar_store.dart';
import 'ics/ics_event_extractor.dart';
import 'ics/ics_expander.dart';
import 'ics/ics_parser.dart';
import 'ics/ics_timezones.dart';

/// 一次导入的差异。
class ExternalImportDiff {
  const ExternalImportDiff({
    this.added = 0,
    this.updated = 0,
    this.removed = 0,
    this.unchanged = 0,
    this.unsupported = 0,
    this.addedUids = const <String>[],
    this.updatedUids = const <String>[],
    this.removedUids = const <String>[],
  });

  final int added;
  final int updated;
  final int removed;
  final int unchanged;

  /// 新文件里因不支持而拒绝的事件数。
  final int unsupported;

  final List<String> addedUids;
  final List<String> updatedUids;
  final List<String> removedUids;

  bool get hasChanges => added > 0 || updated > 0 || removed > 0;

  String get summaryLine =>
      '新增 $added、修改 $updated、移除 $removed、未变 $unchanged'
      '${unsupported > 0 ? '、不支持 $unsupported' : ''}';

  @override
  String toString() => 'ExternalImportDiff($summaryLine)';
}

/// 导入预览（未提交）。
class ExternalImportPreview {
  const ExternalImportPreview({
    required this.existingSource,
    required this.candidate,
    required this.snapshot,
    required this.diff,
    this.warnings = const <ExtImportWarning>[],
    required this.replaceMode,
    this.metadataChanged = false,
    this.truncated = false,
  });

  /// null = 新建来源。
  final ExternalCalendarSource? existingSource;

  /// 已含新 revision / 哈希 / 范围 / 策略的候选来源（尚未落盘）。
  final ExternalCalendarSource candidate;

  /// 候选快照（尚未落盘）。
  final ExternalSourceSnapshot snapshot;

  final ExternalImportDiff diff;
  final List<ExtImportWarning> warnings;

  /// true = 完整替换（文件里没有的旧事件会被移除）；
  /// false = 合并（旧事件保留，不会被悄悄删除）。
  final bool replaceMode;

  /// 内容之外的变化：时区/策略/范围/路径/统计。
  final bool metadataChanged;

  /// 触发了资源上限导致结果不完整（提交前必须提示）。
  final bool truncated;

  /// 没有任何可导入事件（空文件 / 全不支持）。
  bool get isEmpty => snapshot.events.isEmpty;

  bool get hasChanges => diff.hasChanges || metadataChanged || existingSource == null;

  /// “真的会写盘”的判断：与 hasChanges 相同，但空事件的新建来源不允许提交。
  String get summaryLine => '${diff.summaryLine}'
      '${metadataChanged && !diff.hasChanges ? '、设置变化' : ''}'
      '${truncated ? '（结果不完整）' : ''}';

  @override
  String toString() => 'ExternalImportPreview(sources=${snapshot.sourceId}, '
      'events=${snapshot.events.length}, $summaryLine)';
}

/// 外部日历服务。UI 通过 ChangeNotifier 刷新。
class ExternalCalendarService extends ChangeNotifier {
  ExternalCalendarService({
    required ExternalCalendarStore store,
    required IcsLimits limits,
  })  : _store = store,
        _limits = limits;

  final ExternalCalendarStore _store;
  final IcsLimits _limits;

  IcsLimits get limits => _limits;
  ExternalCalendarStore get store => _store;

  List<ExternalCalendarSource> _sources = const <ExternalCalendarSource>[];
  final Map<String, ExternalSourceSnapshot> _snapshots =
      <String, ExternalSourceSnapshot>{};
  final Map<String, List<ExternalBusyInstance>> _busyCache =
      <String, List<ExternalBusyInstance>>{};
  List<ExtImportWarning> _lastBusyWarnings = const <ExtImportWarning>[];

  String? _lastError;
  bool _loaded = false;
  bool _sourcesLoadFailed = false;

  String? get lastError => _lastError;

  /// 最近一次 [busyFor] 产生的 warning（截断、DST 跳过等）；供 UI 提示。
  List<ExtImportWarning> get lastBusyWarnings => _lastBusyWarnings;

  /// 全局来源列表（按 id 稳定排序）。
  List<ExternalCalendarSource> get sources => _sources;

  bool get isLoaded => _loaded;

  ExternalCalendarSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  ExternalSourceSnapshot? snapshotOf(String id) => _snapshots[id];

  /// 启用来源集合的稳定指纹：id|revision|contentHash 排序后 sha256。
  String get fingerprint => fingerprintOf(
      _sources.where((s) => s.enabled).map((s) => s.id));

  /// 指定来源集合的稳定指纹（T-D 做“某会话关联来源”的过期判断用）。
  ///
  /// 未启用/不存在的 id 不参与计算；空集合返回固定哈希（稳定、非空）。
  String fingerprintOf(Iterable<String> sourceIds) {
    final wanted = sourceIds.toSet().toList()..sort();
    final lines = <String>[];
    for (final id in wanted) {
      final source = sourceById(id);
      if (source == null || !source.enabled) continue;
      lines.add('${source.id}|${source.revision}|${source.contentHash}');
    }
    return sha256HexOfBytes(utf8.encode(lines.join('\n')));
  }

  // ---------------------------------------------------------------- load

  /// 读取来源列表与快照。损坏来源列表时保留“损坏”状态并拒绝后续写入。
  Future<void> load() async {
    _lastError = null;
    _sourcesLoadFailed = false;
    try {
      final loaded = await _store.loadSources();
      _sources = List<ExternalCalendarSource>.unmodifiable(loaded);
    } on Object catch (error) {
      _sourcesLoadFailed = true;
      _lastError = '外部日历来源列表无法读取：$error';
      _sources = const <ExternalCalendarSource>[];
      _snapshots.clear();
      _busyCache.clear();
      _loaded = true;
      notifyListeners();
      return;
    }
    _snapshots.clear();
    _busyCache.clear();
    final mismatched = <String>[];
    for (final source in _sources) {
      final snapshot = await _store.loadSnapshot(source.id);
      if (snapshot == null) continue;
      // 快照必须与来源的 revision/哈希一致，否则说明上次提交半途中断。
      if (snapshot.revision != source.revision ||
          snapshot.contentHash != source.contentHash) {
        mismatched.add(source.name);
        continue;
      }
      _snapshots[source.id] = snapshot;
    }
    if (mismatched.isNotEmpty) {
      _lastError = '这些来源的快照与来源记录不一致，需要重新导入：${mismatched.join('、')}';
    }
    final storeError = _store.lastError;
    if (storeError != null && _lastError == null) {
      _lastError = storeError;
    }
    _loaded = true;
    notifyListeners();
  }

  // ------------------------------------------------------------- preview

  /// 生成导入预览。失败（文件不可读/过大/解析失败）返回 null 并设置 lastError。
  Future<ExternalImportPreview?> preview({
    required String filePath,
    ExternalCalendarSource? existing,
    required String timezoneId,
    required ExternalCalendarPolicy policy,
    required String dateFrom,
    required String dateTo,
    required bool replaceMode,
  }) async {
    _lastError = null;
    if (_sourcesLoadFailed) {
      _lastError = '外部日历来源列表损坏，已暂停写入；请先修复或备份 sources.json';
      return null;
    }
    final fromKey = parseDateKey(dateFrom);
    final toKey = parseDateKey(dateTo);
    if (fromKey == null || toKey == null) {
      _lastError = '导入范围不是合法日期（$dateFrom ~ $dateTo）';
      return null;
    }
    if (toKey.compareTo(fromKey) < 0) {
      _lastError = '导入范围的结束日期早于开始日期';
      return null;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      _lastError = '找不到文件：$filePath';
      return null;
    }
    final length = await file.length();
    if (length > _limits.maxFileBytes) {
      _lastError = '文件过大（${_formatBytes(length)}），超过 '
          '${_formatBytes(_limits.maxFileBytes)} 上限';
      return null;
    }
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on Object catch (error) {
      _lastError = '读取文件失败：$error';
      return null;
    }
    return previewBytes(
      bytes: bytes,
      filePath: filePath,
      existing: existing,
      timezoneId: timezoneId,
      policy: policy,
      dateFrom: fromKey,
      dateTo: toKey,
      replaceMode: replaceMode,
    );
  }

  /// 与 [preview] 相同，但直接接收文件字节（测试/内存导入用）。
  ExternalImportPreview? previewBytes({
    required List<int> bytes,
    required String filePath,
    ExternalCalendarSource? existing,
    required String timezoneId,
    required ExternalCalendarPolicy policy,
    required String dateFrom,
    required String dateTo,
    required bool replaceMode,
  }) {
    _lastError = null;
    if (_sourcesLoadFailed) {
      _lastError = '外部日历来源列表损坏，已暂停写入；请先修复或备份 sources.json';
      return null;
    }
    if (bytes.length > _limits.maxFileBytes) {
      _lastError = '文件过大（${_formatBytes(bytes.length)}），超过 '
          '${_formatBytes(_limits.maxFileBytes)} 上限';
      return null;
    }
    final fromKey = parseDateKey(dateFrom);
    final toKey = parseDateKey(dateTo);
    if (fromKey == null || toKey == null) {
      _lastError = '导入范围不是合法日期（$dateFrom ~ $dateTo）';
      return null;
    }
    if (toKey.compareTo(fromKey) < 0) {
      _lastError = '导入范围的结束日期早于开始日期';
      return null;
    }
    final contentHash = sha256HexOfBytes(bytes);
    final existingSnapshot =
        existing == null ? null : _snapshots[existing.id];

    // 幂等快路径：内容、时区、策略、范围、路径都没变 → 不解析、不写入。
    if (existing != null &&
        existingSnapshot != null &&
        existing.contentHash == contentHash &&
        existing.timezoneId == timezoneId &&
        existing.policy == policy &&
        existing.dateFrom == fromKey &&
        existing.dateTo == toKey &&
        existing.filePath == filePath &&
        !replaceMode) {
      final candidate = existing.copyWith(filePath: filePath);
      final unchanged = existingSnapshot.events.length;
      return ExternalImportPreview(
        existingSource: existing,
        candidate: candidate,
        snapshot: existingSnapshot,
        diff: ExternalImportDiff(unchanged: unchanged),
        warnings: existingSnapshot.warnings,
        replaceMode: replaceMode,
        metadataChanged: false,
        truncated: false,
      );
    }

    final text = _decodeIcsBytes(bytes);
    final IcalComponent calendar;
    try {
      calendar = parseIcs(text);
    } on IcsParseException catch (error) {
      _lastError = error.toString();
      return null;
    } on Object catch (error) {
      _lastError = 'ICS 解析失败：$error';
      return null;
    }

    final IcsExtractResult extracted;
    try {
      extracted = extractIcsEvents(
        calendar,
        sourceId: existing?.id ?? 'pending',
        timezoneId: timezoneId,
        policy: policy,
        limits: _limits,
      );
    } on Object catch (error) {
      _lastError = 'ICS 事件提取失败：$error';
      return null;
    }

    final zones = extracted.zones;
    final range = _planningRange(zones, timezoneId, fromKey, toKey);
    if (range == null) {
      _lastError = '应用时区 $timezoneId 无法解析，无法计算导入范围';
      return null;
    }

    final warnings = <ExtImportWarning>[...extracted.warnings];
    final previousEvents = existingSnapshot?.events ?? const <ExternalEventRecord>[];
    var diff = _diffRecords(previousEvents, extracted.events);
    if (extracted.unsupportedUids.isNotEmpty) {
      diff = ExternalImportDiff(
        added: diff.added,
        updated: diff.updated,
        removed: diff.removed,
        unchanged: diff.unchanged,
        unsupported: extracted.unsupportedUids.length,
        addedUids: diff.addedUids,
        updatedUids: diff.updatedUids,
        removedUids: diff.removedUids,
      );
    }

    // 合并模式：文件里已经删掉、但以前导入过的事件保留（不会被悄悄清掉）。
    final List<ExternalEventRecord> effectiveEvents;
    if (replaceMode) {
      effectiveEvents = extracted.events;
    } else {
      final newKeys = extracted.events.map((e) => e.identityKey).toSet();
      final retained = previousEvents
          .where((e) => !newKeys.contains(e.identityKey))
          .toList(growable: false);
      if (retained.isNotEmpty) {
        warnings.add(ExtImportWarning(
          'merge-retained',
          '合并模式：文件里已删除的 ${retained.length} 条旧事件被保留；'
              '如需彻底移除请使用“完整替换”',
        ));
      }
      effectiveEvents = <ExternalEventRecord>[
        ...retained,
        ...extracted.events,
      ];
    }

    final expansion = expandIcsEvents(
      effectiveEvents,
      fromUtc: range.fromUtc,
      toUtc: range.toUtc,
      zones: zones,
      policy: policy,
      limits: _limits,
      sourceId: existing?.id ?? 'pending',
      planningTimezoneId: timezoneId,
    );
    warnings.addAll(expansion.warnings);
    if (effectiveEvents.isEmpty) {
      warnings.add(const ExtImportWarning(
        'no-events',
        '文件里没有可导入的事件；如果这是空文件或全部事件都不支持，请检查文件内容',
      ));
    }
    final stats = _mergeStats(
      extracted.partialStats,
      expansion.stats,
      warnings.length,
      extracted.unsupportedUids.length,
    );

    final now = DateTime.now().toUtc().toIso8601String();
    final sourceId = existing?.id ?? newExternalSourceId();
    final revision = existing == null ? 1 : existing.revision + 1;
    final candidate = ExternalCalendarSource(
      id: sourceId,
      name: existing?.name ?? _defaultSourceName(filePath),
      type: kExternalCalendarTypeLocalFile,
      filePath: filePath,
      contentHash: contentHash,
      importedAt: now,
      revision: revision,
      dateFrom: fromKey,
      dateTo: toKey,
      timezoneId: timezoneId,
      enabled: existing?.enabled ?? true,
      policy: policy,
      stats: stats,
    );
    final metadataChanged = existing == null ||
        existing.contentHash != contentHash ||
        existing.timezoneId != timezoneId ||
        existing.policy != policy ||
        existing.dateFrom != fromKey ||
        existing.dateTo != toKey ||
        existing.filePath != filePath ||
        existing.stats != stats ||
        existing.revision != revision;
    return ExternalImportPreview(
      existingSource: existing,
      candidate: candidate,
      snapshot: ExternalSourceSnapshot(
        sourceId: sourceId,
        revision: revision,
        contentHash: contentHash,
        timezoneId: timezoneId,
        dateFrom: fromKey,
        dateTo: toKey,
        policy: policy,
        events: List<ExternalEventRecord>.unmodifiable(effectiveEvents),
        warnings: List<ExtImportWarning>.unmodifiable(warnings),
        stats: stats,
      ),
      diff: diff,
      warnings: List<ExtImportWarning>.unmodifiable(warnings),
      replaceMode: replaceMode,
      metadataChanged: metadataChanged,
      truncated: expansion.truncated,
    );
  }

  // -------------------------------------------------------------- commit

  /// 原子提交预览。返回 false 时旧 sources/snapshot 保持不变，原因见 [lastError]。
  Future<bool> commit(ExternalImportPreview preview) async {
    _lastError = null;
    if (_sourcesLoadFailed) {
      _lastError = '外部日历来源列表损坏，已暂停写入；请先修复或备份 sources.json';
      return false;
    }
    final existing = preview.existingSource == null
        ? null
        : sourceById(preview.existingSource!.id);
    if (preview.existingSource != null && existing == null) {
      _lastError = '要更新的外部日历来源已不存在，请重新预览';
      return false;
    }
    if (existing != null &&
        existing.revision != preview.existingSource!.revision) {
      _lastError = '外部日历来源已被修改（revision '
          '${existing.revision} != ${preview.existingSource!.revision}），请重新预览';
      return false;
    }
    if (!preview.hasChanges) {
      // 幂等：完全没有变化，不写入、不涨 revision。
      return true;
    }
    if (preview.snapshot.events.isEmpty &&
        (existing == null || !preview.replaceMode)) {
      _lastError = '没有可导入的事件，未创建/更新来源';
      return false;
    }

    final oldSnapshot = existing == null ? null : _snapshots[existing.id];
    final nextSources = <ExternalCalendarSource>[
      for (final source in _sources)
        if (source.id != preview.candidate.id) source,
      preview.candidate,
    ]..sort((a, b) => a.id.compareTo(b.id));

    // 1) 先写快照：即使随后来源列表写失败，也只是一份“暂未被引用”的快照。
    try {
      await _store.saveSnapshot(preview.snapshot);
    } on Object catch (error) {
      _lastError = '保存外部日历快照失败：$error';
      return false;
    }

    // 2) 再写来源列表；失败则回滚快照，保持旧数据可用。
    try {
      await _store.saveSources(nextSources);
    } on Object catch (error) {
      try {
        if (oldSnapshot != null) {
          await _store.saveSnapshot(oldSnapshot);
        } else {
          await _store.deleteSnapshot(preview.snapshot.sourceId);
        }
      } catch (_) {
        // 回滚也失败：保留错误信息让用户重新导入，绝不再做别的写入。
      }
      _lastError = '保存外部日历来源列表失败，已回滚：$error';
      return false;
    }

    // 3) 内存状态只在两步都成功后更新。
    _sources = List<ExternalCalendarSource>.unmodifiable(nextSources);
    _snapshots[preview.candidate.id] = preview.snapshot;
    _invalidateBusyCache();
    _lastError = null;
    notifyListeners();
    return true;
  }

  // ------------------------------------------------------- source 管理

  Future<bool> setEnabled(String id, bool enabled) async {
    _lastError = null;
    final source = sourceById(id);
    if (source == null) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    if (source.enabled == enabled) return true;
    return _saveSourcesMutation(source.copyWith(enabled: enabled));
  }

  Future<bool> rename(String id, String name) async {
    _lastError = null;
    final source = sourceById(id);
    if (source == null) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _lastError = '名称不能为空';
      return false;
    }
    if (trimmed == source.name) return true;
    return _saveSourcesMutation(source.copyWith(name: trimmed));
  }

  /// 删除一个来源（只删它自己的快照，不碰其他来源）。
  Future<bool> remove(String id) async {
    _lastError = null;
    final source = sourceById(id);
    if (source == null) {
      _lastError = '外部日历来源不存在';
      return false;
    }
    final nextSources = _sources
        .where((s) => s.id != id)
        .toList(growable: false);
    try {
      await _store.saveSources(nextSources);
    } on Object catch (error) {
      _lastError = '删除外部日历来源失败：$error';
      return false;
    }
    _sources = List<ExternalCalendarSource>.unmodifiable(nextSources);
    _snapshots.remove(id);
    _invalidateBusyCache();
    await _store.deleteSnapshot(id);
    _lastError = null;
    notifyListeners();
    return true;
  }

  Future<bool> _saveSourcesMutation(ExternalCalendarSource updated) async {
    if (_sourcesLoadFailed) {
      _lastError = '外部日历来源列表损坏，已暂停写入；请先修复或备份 sources.json';
      return false;
    }
    final nextSources = <ExternalCalendarSource>[
      for (final source in _sources)
        if (source.id != updated.id) source,
      updated,
    ]..sort((a, b) => a.id.compareTo(b.id));
    try {
      await _store.saveSources(nextSources);
    } on Object catch (error) {
      _lastError = '保存外部日历来源失败：$error';
      return false;
    }
    _sources = List<ExternalCalendarSource>.unmodifiable(nextSources);
    _invalidateBusyCache();
    _lastError = null;
    notifyListeners();
    return true;
  }

  // ---------------------------------------------------------------- busy

  /// 某来源集合在 `[dateFrom, dateTo]`（规划时区自然日，含首尾）内的忙碌实例。
  ///
  /// 只读、纯计算；不写盘、不发请求。禁用的来源与不存在的来源被跳过；
  /// 展开触发资源上限时结果置 warning（见 [lastBusyWarnings]）并截断。
  List<ExternalBusyInstance> busyFor({
    required Set<String> sourceIds,
    required String dateFrom,
    required String dateTo,
    required String timezoneId,
  }) {
    _lastBusyWarnings = const <ExtImportWarning>[];
    if (sourceIds.isEmpty) return const <ExternalBusyInstance>[];
    final fromKey = parseDateKey(dateFrom);
    final toKey = parseDateKey(dateTo);
    if (fromKey == null || toKey == null) {
      _lastError = '忙碌时间范围不是合法日期（$dateFrom ~ $dateTo）';
      return const <ExternalBusyInstance>[];
    }
    if (toKey.compareTo(fromKey) < 0) return const <ExternalBusyInstance>[];
    final resolver = IcsTimeZoneResolver();
    final range = _planningRange(resolver, timezoneId, fromKey, toKey);
    if (range == null) {
      _lastError = '应用时区 $timezoneId 无法解析，无法读取外部忙碌时间';
      return const <ExternalBusyInstance>[];
    }
    final ids = sourceIds.toList()..sort();
    final out = <ExternalBusyInstance>[];
    final warnings = <ExtImportWarning>[];
    var truncated = false;
    for (final id in ids) {
      final source = sourceById(id);
      if (source == null || !source.enabled) continue;
      final snapshot = _snapshots[id];
      if (snapshot == null) continue;
      final cacheKey = '$id|${snapshot.revision}|$fromKey|$toKey|$timezoneId';
      var instances = _busyCache[cacheKey];
      if (instances == null) {
        final expansion = expandIcsEvents(
          snapshot.events,
          fromUtc: range.fromUtc,
          toUtc: range.toUtc,
          zones: resolver,
          policy: snapshot.policy,
          limits: _limits,
          sourceId: id,
          planningTimezoneId: timezoneId,
        );
        warnings.addAll(expansion.warnings);
        truncated = truncated || expansion.truncated;
        instances = expansion.instances;
        _busyCache[cacheKey] = instances;
      }
      out.addAll(instances);
    }
    _lastBusyWarnings = List<ExtImportWarning>.unmodifiable(warnings);
    if (truncated) {
      _lastError = '外部日历展开超过资源上限，忙碌时间不完整';
    }
    out.sort((a, b) {
      final byStart = a.startUtc.compareTo(b.startUtc);
      if (byStart != 0) return byStart;
      final bySource = a.sourceId.compareTo(b.sourceId);
      if (bySource != 0) return bySource;
      return a.uid.compareTo(b.uid);
    });
    return List<ExternalBusyInstance>.unmodifiable(out);
  }

  void _invalidateBusyCache() => _busyCache.clear();

  // ------------------------------------------------------------ internals

  ExternalImportDiff _diffRecords(
    List<ExternalEventRecord> previous,
    List<ExternalEventRecord> next,
  ) {
    final previousByKey = <String, ExternalEventRecord>{};
    for (final record in previous) {
      previousByKey[record.identityKey] = record;
    }
    final nextByKey = <String, ExternalEventRecord>{};
    for (final record in next) {
      nextByKey[record.identityKey] = record;
    }
    final added = <String>[];
    final updated = <String>[];
    final removed = <String>[];
    var unchanged = 0;
    for (final entry in nextByKey.entries) {
      final old = previousByKey[entry.key];
      if (old == null) {
        added.add(entry.value.uid);
        continue;
      }
      if (old == entry.value) {
        unchanged++;
      } else {
        updated.add(entry.value.uid);
      }
    }
    for (final entry in previousByKey.entries) {
      if (!nextByKey.containsKey(entry.key)) removed.add(entry.value.uid);
    }
    return ExternalImportDiff(
      added: added.length,
      updated: updated.length,
      removed: removed.length,
      unchanged: unchanged,
      addedUids: List<String>.unmodifiable(_dedupe(added)),
      updatedUids: List<String>.unmodifiable(_dedupe(updated)),
      removedUids: List<String>.unmodifiable(_dedupe(removed)),
    );
  }

  static List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    final out = <String>[];
    for (final value in values) {
      if (seen.add(value)) out.add(value);
    }
    return out;
  }

  static ExtImportStats _mergeStats(
    ExtImportStats eventStats,
    ExtImportStats expansionStats,
    int warningCount,
    int unsupportedCount,
  ) =>
      ExtImportStats(
        readEvents: eventStats.readEvents,
        expandedInstances: expansionStats.expandedInstances,
        busyMinutes: expansionStats.busyMinutes,
        transparentEvents: eventStats.transparentEvents,
        cancelledEvents: eventStats.cancelledEvents,
        tentativeInstances: expansionStats.tentativeInstances,
        warningCount: warningCount,
        unsupportedCount: unsupportedCount,
        ignoredComponents: eventStats.ignoredComponents,
      );

  /// `[dateFrom 00:00, dateTo+1 00:00)` 在规划时区里对应的 UTC 区间。
  _PlanningRange? _planningRange(
    IcsTimeZoneResolver zones,
    String timezoneId,
    String dateFrom,
    String dateTo,
  ) {
    if (!zones.isKnown(timezoneId)) return null;
    final fromDate = parseDateKeyUtc(dateFrom);
    final toDate = parseDateKeyUtc(dateTo);
    if (fromDate == null || toDate == null) return null;
    final fromMidnight = DateTime.utc(fromDate.year, fromDate.month, fromDate.day);
    final toMidnight = DateTime.utc(toDate.year, toDate.month, toDate.day)
        .add(const Duration(days: 1));
    final fromUtc = zones.wallToUtc(timezoneId, fromMidnight);
    final toUtc = zones.wallToUtc(timezoneId, toMidnight);
    if (fromUtc == null || toUtc == null) return null;
    return _PlanningRange(fromUtc: fromUtc, toUtc: toUtc);
  }

  static String _defaultSourceName(String filePath) {
    final segments = filePath.split(RegExp(r'[\\/]'));
    final base = segments.isEmpty ? '' : segments.last;
    final dot = base.lastIndexOf('.');
    final name = dot > 0 ? base.substring(0, dot) : base;
    final trimmed = name.trim();
    return trimmed.isEmpty ? '外部日历' : trimmed;
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// ICS 编码嗅探：UTF-8（含 BOM）、UTF-16LE/BE（Windows 导出器可能这么写）。
  static String _decodeIcsBytes(List<int> bytes) {
    if (bytes.length >= 2) {
      final b0 = bytes[0];
      final b1 = bytes[1];
      if (b0 == 0xFF && b1 == 0xFE) return _decodeUtf16(bytes, littleEndian: true);
      if (b0 == 0xFE && b1 == 0xFF) return _decodeUtf16(bytes, littleEndian: false);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian ? data.getUint16(i, Endian.little) : data.getUint16(i, Endian.big));
    }
    return String.fromCharCodes(units);
  }
}

class _PlanningRange {
  const _PlanningRange({required this.fromUtc, required this.toUtc});

  final DateTime fromUtc;
  final DateTime toUtc;
}

/// 供测试/诊断：`yyyy-MM-dd` 方便从 DateTime 生成。
String externalDateKey(DateTime date) =>
    WallClock.formatDateKey(date.year, date.month, date.day);
