// 外部日历的本地存储。
//
// 布局（`<dataRoot>/external_calendar/`，与 SessionStore 同级，纳入备份）：
//   sources.json                 — 来源列表（id/名称/启用/范围/策略/统计）
//   snapshots/<sourceId>.json    — 每个来源一份导入快照（事件 + 警告 + 统计）
//
// 可靠性写法见 storage_json_write.dart（与 SessionStore、ExecutionStore 共用）：
//   * 新内容先写唯一临时文件 `<file>.<token>.tmp` 并 flush；
//   * 旧主文件改名 `<file>.bak`；
//   * 临时文件改名成主文件；
//   * 读取时主文件损坏/缺失就回退 `.bak`；残留 `*.tmp` 一律忽略；
//   * 绝不“rename 失败就直接覆盖主文件”——那会在杀毒/索引器短暂占用时把唯一
//     好副本换成半份数据。
//
// 与快照相关的两个判断：
//   * 快照内容不合法（半份 JSON、未知 schema）→ loadSnapshot 返回 null，由服务
//     决定下一步（重新导入），**不会**把半个快照当成成功数据；
//   * sources.json 不合法 → 抛 [ExternalCalendarStoreException]，让服务把
//     “来源列表损坏”显示给用户并拒绝写入，避免静默丢来源。

import 'dart:convert';
import 'dart:io';

import '../model/external_calendar.dart';
import 'storage_json_write.dart';

/// 存储层错误（损坏、不可写、非法 id）。
class ExternalCalendarStoreException implements Exception {
  const ExternalCalendarStoreException(this.message, {this.path = ''});

  final String message;
  final String path;

  @override
  String toString() =>
      path.isEmpty ? '外部日历存储错误：$message' : '外部日历存储错误：$message（$path）';
}

class ExternalCalendarStore {
  ExternalCalendarStore(this.dataRoot);

  /// 应用数据根目录（与 index.json、conversations/ 同级）。
  final Directory dataRoot;

  /// `<dataRoot>/external_calendar/`。
  Directory get baseDir =>
      Directory('${dataRoot.path}${Platform.pathSeparator}$kExternalCalendarDirName');

  Directory get snapshotsDir =>
      Directory('${baseDir.path}${Platform.pathSeparator}snapshots');

  File get sourcesFile =>
      File('${baseDir.path}${Platform.pathSeparator}sources.json');

  /// 最近一次读取失败的原因（给服务拼 lastError 用）。
  String? lastError;

  Future<void> ensureLayout() async {
    await baseDir.create(recursive: true);
    await snapshotsDir.create(recursive: true);
  }

  // ------------------------------------------------------------ sources

  /// 读取来源列表。文件不存在 → 空列表；
  /// 文件存在但主文件与 `.bak` 都不可解析 → 抛错（绝不静默返回空列表，
  /// 否则下一次写入会把用户全部来源覆盖掉）。
  Future<List<ExternalCalendarSource>> loadSources() async {
    lastError = null;
    final read = await _readJsonResult(sourcesFile);
    final raw = read.data;
    if (raw == null) {
      if (read.unreadable) {
        lastError = '来源列表文件损坏，且没有可用的 .bak 备份';
        throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
      }
      return const <ExternalCalendarSource>[];
    }
    final version = (raw['schemaVersion'] as num?)?.toInt();
    if (version != null && version > kExternalSourcesSchemaVersion) {
      lastError = '来源列表来自更新的版本（schema $version）';
      throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
    }
    final list = raw['sources'];
    if (list == null) return const <ExternalCalendarSource>[];
    if (list is! List) {
      lastError = '来源列表不是数组，文件可能损坏';
      throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
    }
    final out = <ExternalCalendarSource>[];
    final seen = <String>{};
    for (final item in list) {
      final source = ExternalCalendarSource.fromJson(item);
      if (source == null) {
        lastError = '来源列表里有一条记录不合法，文件可能损坏';
        throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
      }
      if (!seen.add(source.id)) {
        lastError = '来源列表里有重复 id：${source.id}';
        throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
      }
      out.add(source);
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return List<ExternalCalendarSource>.unmodifiable(out);
  }

  /// 原子写入来源列表。
  Future<void> saveSources(List<ExternalCalendarSource> sources) async {
    for (final source in sources) {
      _requireSafeId(source.id);
    }
    final payload = <String, dynamic>{
      'schemaVersion': kExternalSourcesSchemaVersion,
      'sources': sources.map((s) => s.toJson()).toList(growable: false),
    };
    try {
      await _writeJson(sourcesFile, payload);
      lastError = null;
    } on Object catch (error) {
      lastError = '来源列表写入失败：$error';
      throw ExternalCalendarStoreException(lastError!, path: sourcesFile.path);
    }
  }

  // ----------------------------------------------------------- snapshots

  File snapshotFile(String sourceId) => File(
      '${snapshotsDir.path}${Platform.pathSeparator}$sourceId.json');

  /// 读取一个来源的快照；不存在或损坏都返回 null（不上抛，避免一个坏快照
  /// 挡住其他来源；服务会把 null 当作“需要重新导入”）。
  Future<ExternalSourceSnapshot?> loadSnapshot(String sourceId) async {
    if (!isSafeId(sourceId)) return null;
    final read = await _readJsonResult(snapshotFile(sourceId));
    final raw = read.data;
    if (raw == null) {
      if (read.unreadable) {
        lastError = '快照 $sourceId 损坏且没有可用的 .bak，已忽略（需要重新导入）';
      }
      return null;
    }
    final snapshot = ExternalSourceSnapshot.fromJson(raw);
    if (snapshot == null) {
      lastError = '快照 $sourceId 内容不合法，已忽略（需要重新导入）';
      return null;
    }
    if (snapshot.sourceId != sourceId) {
      lastError = '快照文件与来源 id 不一致：$sourceId';
      return null;
    }
    return snapshot;
  }

  /// 读取全部快照（损坏的跳过并记录 lastError）。
  Future<List<ExternalSourceSnapshot>> loadAllSnapshots() async {
    if (!await snapshotsDir.exists()) return const <ExternalSourceSnapshot>[];
    final out = <ExternalSourceSnapshot>[];
    final entities = await snapshotsDir.list(followLinks: false).toList();
    entities.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.json')) continue;
      final sourceId = name.substring(0, name.length - '.json'.length);
      final snapshot = await loadSnapshot(sourceId);
      if (snapshot != null) out.add(snapshot);
    }
    out.sort((a, b) => a.sourceId.compareTo(b.sourceId));
    return List<ExternalSourceSnapshot>.unmodifiable(out);
  }

  /// 原子写入一份快照。
  Future<void> saveSnapshot(ExternalSourceSnapshot snapshot) async {
    _requireSafeId(snapshot.sourceId);
    try {
      await _writeJson(snapshotFile(snapshot.sourceId), snapshot.toJson());
      lastError = null;
    } on Object catch (error) {
      lastError = '快照写入失败：$error';
      throw ExternalCalendarStoreException(
        lastError!,
        path: snapshotFile(snapshot.sourceId).path,
      );
    }
  }

  /// 删除一个来源的快照（含 `.bak` 与残留临时文件）。
  ///
  /// 只动这个 sourceId 自己的文件；删除失败不上抛（孤儿文件由
  /// [referencedSnapshotIds] 之后的清理流程处理，不影响数据正确性）。
  Future<void> deleteSnapshot(String sourceId) async {
    if (!isSafeId(sourceId)) return;
    final primary = snapshotFile(sourceId);
    final candidates = <File>[
      primary,
      File('${primary.path}.bak'),
    ];
    for (final candidate in candidates) {
      try {
        if (await candidate.exists()) await candidate.delete();
      } catch (_) {
        // 被占用时保留；它不会被当成有效快照（源已移除）。
      }
    }
    // 清理同名残留临时文件。
    try {
      if (await snapshotsDir.exists()) {
        await for (final entity in snapshotsDir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('$sourceId.json.') && name.endsWith('.tmp')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// 磁盘上存在快照文件的来源 id 集合（用于孤儿清理/诊断）。
  Future<Set<String>> referencedSnapshotIds() async {
    final keep = <String>{};
    if (!await snapshotsDir.exists()) return keep;
    await for (final entity in snapshotsDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.toLowerCase().endsWith('.json')) continue;
      final id = name.substring(0, name.length - '.json'.length);
      if (isSafeId(id)) keep.add(id);
    }
    return keep;
  }

  // ------------------------------------------------------------ internals

  /// id 只允许 `[A-Za-z0-9_-]`，避免路径穿越与非法文件名。
  static bool isSafeId(String id) {
    if (id.isEmpty || id.length > 64) return false;
    for (var i = 0; i < id.length; i++) {
      final code = id.codeUnitAt(i);
      final ok = (code >= 0x30 && code <= 0x39) ||
          (code >= 0x41 && code <= 0x5A) ||
          (code >= 0x61 && code <= 0x7A) ||
          code == 0x2D ||
          code == 0x5F;
      if (!ok) return false;
    }
    return true;
  }

  static void _requireSafeId(String id) {
    if (!isSafeId(id)) {
      throw ExternalCalendarStoreException('来源 id 不合法：$id');
    }
  }

  /// 读取主文件并回退 `.bak`。
  ///
  /// [unreadable] 表示“文件确实存在，但主文件与 .bak 都解析失败”——
  /// 调用方必须区分这种情况和“文件不存在”，否则会静默丢数据。
  Future<({Map<String, dynamic>? data, bool unreadable})> _readJsonResult(
      File file) async {
    var sawExisting = false;
    for (final candidate in <File>[
      file,
      File('${file.path}.bak'),
    ]) {
      try {
        if (!await candidate.exists()) continue;
        sawExisting = true;
        final text = await candidate.readAsString();
        if (text.trim().isEmpty) continue;
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          return (data: decoded, unreadable: false);
        }
      } catch (_) {
        // 损坏：继续尝试 .bak。
      }
    }
    return (data: null, unreadable: sawExisting);
  }

  /// 同路径串行化、临时文件与 `.bak` 的落盘协议见 [writeJsonAtomically]。
  Future<void> _writeJson(File file, Map<String, dynamic> data) =>
      writeJsonAtomically(file, data, prepareDirectory: ensureLayout);
}
