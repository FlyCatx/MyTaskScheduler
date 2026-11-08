// 全局日程的权威存储：<dataRoot>/schedules/events.json。
//
// 复用现有落盘能力（storage_json_write.dart）与执行记录的实例锁思路：
//   * 同一数据根只允许一个写实例；第二实例只读并提示，不发送提醒；
//   * 主文件损坏回退 .bak；两者都坏或来自更新版本 → 只读并保留文件，不写空库；
//   * 整个 read-modify-write 事务由 ScheduleController 串行化，本类只负责
//     一次快照的原子保存与严格读取；
//   * 无数据目录时允许内存模式，明确关闭后丢失，不谎称已保存；
//   * 提醒去重状态放独立 reminder_state.json（提醒服务使用，不进入日程本体）。

import 'dart:convert';
import 'dart:io';

import '../../model/schedule_event.dart';
import '../storage_json_write.dart';

/// 日程文件结构版本；读到更大版本必须只读，不能用旧结构覆盖。
const int kScheduleSchemaVersion = 1;

class ScheduleStoreException implements Exception {
  const ScheduleStoreException(this.message, {this.path = ''});
  final String message;
  final String path;
  @override
  String toString() => path.isEmpty ? message : '$message（$path）';
}

/// 只读实例（另一个进程正在使用同一数据目录，或数据来自更新版本）。
class ScheduleReadOnlyException implements Exception {
  const ScheduleReadOnlyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一次读取/打开的结果；接线方据此显示提示并决定是否允许写入。
class ScheduleOpenResult {
  const ScheduleOpenResult({
    required this.snapshot,
    this.readOnly = false,
    this.notice,
    this.recoveredFromBackup = false,
    this.corruptFallback = false,
    this.newerSchema = false,
    this.lockConflict = false,
    this.memoryOnly = false,
  });

  final ScheduleSnapshot snapshot;
  final bool readOnly;
  final String? notice;
  final bool recoveredFromBackup;
  final bool corruptFallback;
  final bool newerSchema;
  final bool lockConflict;
  final bool memoryOnly;
}

/// 日程库快照：revision + 全部事件（含 deletedAtUtc 的删除标记，供撤销/备份）。
class ScheduleSnapshot {
  const ScheduleSnapshot({
    required this.revision,
    required this.events,
  });

  final int revision;
  final Map<String, ScheduleEvent> events;

  static const ScheduleSnapshot empty =
      ScheduleSnapshot(revision: 0, events: <String, ScheduleEvent>{});

  List<ScheduleEvent> get activeEvents => events.values
      .where((e) => !e.isDeleted)
      .toList(growable: false);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': kScheduleSchemaVersion,
        'revision': revision,
        'events': events.values.map((e) => e.toJson()).toList(growable: false),
      };
}

class ScheduleStore {
  /// 磁盘模式：dataRoot 通常是 SessionStore 的同一个数据根目录。
  ScheduleStore(Directory dataRoot)
      : _root = dataRoot.absolute,
        _memoryOnly = false;

  /// 内存模式：没有任何可写目录时使用，界面可用但重启后丢失。
  ScheduleStore.memory()
      : _root = null,
        _memoryOnly = true;

  final Directory? _root;
  final bool _memoryOnly;

  ScheduleSnapshot _snapshot = ScheduleSnapshot.empty;
  bool _opened = false;
  bool _readOnly = false;
  String? _notice;
  bool _recoveredFromBackup = false;
  bool _corruptFallback = false;
  bool _newerSchema = false;

  RandomAccessFile? _lockHandle;
  Object? _lockToken;

  static final Map<String, Object> _inProcessLocks = <String, Object>{};

  bool get isMemoryOnly => _memoryOnly;
  bool get readOnly => _readOnly;
  String? get notice => _notice;
  bool get opened => _opened;
  int get revision => _snapshot.revision;
  ScheduleSnapshot get snapshot => _snapshot;

  Directory get schedulesDir {
    final root = _root;
    if (root == null) return Directory('');
    return Directory('${root.path}${Platform.pathSeparator}schedules');
  }

  File get eventsFile =>
      File('${schedulesDir.path}${Platform.pathSeparator}events.json');

  File get eventsBackupFile => File('${eventsFile.path}.bak');

  File get reminderStateFile =>
      File('${schedulesDir.path}${Platform.pathSeparator}reminder_state.json');

  File get instanceLockFile =>
      File('${schedulesDir.path}${Platform.pathSeparator}instance.lock');

  String? _lockKey() {
    final root = _root;
    if (root == null) return null;
    return root.path.toLowerCase();
  }

  /// 打开存储：建目录、抢实例锁、读取日程库。
  ///
  /// 永不抛出（除编程错误）：失败给出只读/空库 + notice。
  Future<ScheduleOpenResult> open() async {
    if (_opened) {
      return ScheduleOpenResult(
        snapshot: _snapshot,
        readOnly: _readOnly,
        notice: _notice,
        recoveredFromBackup: _recoveredFromBackup,
        corruptFallback: _corruptFallback,
        newerSchema: _newerSchema,
        memoryOnly: _memoryOnly,
      );
    }
    _opened = true;
    if (_memoryOnly) {
      _snapshot = ScheduleSnapshot.empty;
      return const ScheduleOpenResult(
        snapshot: ScheduleSnapshot.empty,
        memoryOnly: true,
        notice: '当前没有可写数据目录，日程仅保存在内存中，关闭后丢失',
      );
    }

    try {
      await schedulesDir.create(recursive: true);
    } catch (e) {
      _readOnly = true;
      _notice = '日程目录不可写，本次运行只读：$e';
      _snapshot = ScheduleSnapshot.empty;
      return ScheduleOpenResult(
        snapshot: _snapshot,
        readOnly: true,
        notice: _notice,
      );
    }

    final lock = await _tryAcquireInstanceLock();
    if (!lock) {
      _readOnly = true;
      _notice = '另一个 TaskScheduler 实例正在使用同一数据目录；'
          '本实例的日程为只读，也不会发送日程提醒。';
    }

    await _load();
    return ScheduleOpenResult(
      snapshot: _snapshot,
      readOnly: _readOnly,
      notice: _notice,
      recoveredFromBackup: _recoveredFromBackup,
      corruptFallback: _corruptFallback,
      newerSchema: _newerSchema,
      lockConflict: !lock,
    );
  }

  Future<void> _load() async {
    final main = await _readEventsFile(eventsFile);
    if (main.newerSchema) {
      _newerSchema = true;
      _readOnly = true;
      _snapshot = ScheduleSnapshot.empty;
      _notice = '日程数据来自更新的版本（schema ${main.version}），本次运行只读，不会覆盖该文件。';
      return;
    }
    if (main.snapshot != null) {
      _snapshot = main.snapshot!;
      return;
    }
    final backup = await _readEventsFile(eventsBackupFile);
    if (backup.newerSchema) {
      _newerSchema = true;
      _readOnly = true;
      _snapshot = ScheduleSnapshot.empty;
      _notice = '日程备份来自更新的版本（schema ${backup.version}），本次运行只读。';
      return;
    }
    if (backup.snapshot != null) {
      _recoveredFromBackup = true;
      _snapshot = backup.snapshot!;
      _notice = '日程主文件损坏或缺失，已从 .bak 备份恢复。';
      if (backup.newerSchema) {
        _newerSchema = true;
        _readOnly = true;
        _notice = '日程备份来自更新的版本，本次运行只读。';
      }
      return;
    }
    if (main.existed || backup.existed) {
      // 两处都不可解析：保留证据、只读启动，绝不写空库覆盖。
      _corruptFallback = true;
      _readOnly = true;
      _notice = '日程文件损坏且没有可用备份；本次运行只读，请先手动备份后修复或删除 ${eventsFile.path}。';
      _snapshot = ScheduleSnapshot.empty;
      return;
    }
    _snapshot = ScheduleSnapshot.empty;
  }

  Future<({ScheduleSnapshot? snapshot, bool existed, int version, bool newerSchema})>
      _readEventsFile(File file) async {
    try {
      if (!await file.exists()) {
        return (snapshot: null, existed: false, version: 0, newerSchema: false);
      }
      final text = await file.readAsString();
      if (text.trim().isEmpty) {
        return (snapshot: null, existed: true, version: 0, newerSchema: false);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return (snapshot: null, existed: true, version: 0, newerSchema: false);
      }
      final j = Map<String, dynamic>.from(decoded);
      final rawVersion = j['schemaVersion'];
      if (rawVersion is! int || rawVersion < 1) {
        return (snapshot: null, existed: true, version: 0, newerSchema: false);
      }
      if (rawVersion > kScheduleSchemaVersion) {
        return (
          snapshot: null,
          existed: true,
          version: rawVersion,
          newerSchema: true,
        );
      }
      final rawRevision = j['revision'];
      if (rawRevision is! int || rawRevision < 0) {
        return (snapshot: null, existed: true, version: rawVersion, newerSchema: false);
      }
      final rawEvents = j['events'];
      if (rawEvents is! List) {
        return (snapshot: null, existed: true, version: rawVersion, newerSchema: false);
      }
      final events = <String, ScheduleEvent>{};
      for (final raw in rawEvents) {
        final event = ScheduleEvent.tryParse(raw);
        if (event == null) {
          return (snapshot: null, existed: true, version: rawVersion, newerSchema: false);
        }
        if (events.containsKey(event.id)) {
          return (snapshot: null, existed: true, version: rawVersion, newerSchema: false);
        }
        events[event.id] = event;
      }
      return (
        snapshot: ScheduleSnapshot(
          revision: rawRevision,
          events: Map<String, ScheduleEvent>.unmodifiable(events),
        ),
        existed: true,
        version: rawVersion,
        newerSchema: false,
      );
    } catch (_) {
      return (snapshot: null, existed: true, version: 0, newerSchema: false);
    }
  }

  /// 重新读取磁盘快照（备份恢复后由 controller 调用）。
  ///
  /// 不改变只读/锁状态：仍是同一实例的重新读盘，不重新抢锁。
  Future<void> reload() async {
    if (_memoryOnly) return;
    await _load();
  }

  /// 原子保存整份快照；只读/内存模式按语义处理（内存模式只更新内存）。
  ///
  /// 调用方必须已经串行化整个 read-modify-write 事务并校验 revision。
  Future<void> saveSnapshot(ScheduleSnapshot snapshot) async {
    if (_memoryOnly) {
      _snapshot = snapshot;
      return;
    }
    if (_readOnly) {
      throw ScheduleReadOnlyException(_notice ?? '日程数据处于只读状态，未保存改动');
    }
    try {
      await writeJsonAtomically(
        eventsFile,
        snapshot.toJson(),
        prepareDirectory: () => schedulesDir.create(recursive: true),
      );
      _snapshot = snapshot;
    } catch (e) {
      throw ScheduleStoreException('日程保存失败：$e', path: eventsFile.path);
    }
  }

  /// 读取提醒去重状态（不存在/损坏返回 null；提醒服务自行重建）。
  Future<Map<String, dynamic>?> loadReminderState() async {
    if (_memoryOnly) return null;
    try {
      if (!await reminderStateFile.exists()) return null;
      final text = await reminderStateFile.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 保存提醒去重状态；失败抛出由提醒服务决定停止派发。
  Future<void> saveReminderState(Map<String, dynamic> state) async {
    if (_memoryOnly) return;
    if (_readOnly) {
      throw ScheduleReadOnlyException(_notice ?? '日程处于只读状态，未保存提醒状态');
    }
    await writeJsonAtomically(
      reminderStateFile,
      state,
      prepareDirectory: () => schedulesDir.create(recursive: true),
    );
  }

  Future<bool> _tryAcquireInstanceLock() async {
    final key = _lockKey();
    if (key == null) return true;
    if (_inProcessLocks.containsKey(key)) return false;
    final token = Object();
    _inProcessLocks[key] = token;
    try {
      final handle = await instanceLockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      _lockHandle = handle;
      _lockToken = token;
      return true;
    } catch (_) {
      if (identical(_inProcessLocks[key], token)) {
        _inProcessLocks.remove(key);
      }
      return false;
    }
  }

  /// 释放实例锁并关闭文件句柄。可重复调用。
  Future<void> close() async {
    _opened = false;
    final token = _lockToken;
    _lockToken = null;
    final key = _lockKey();
    if (key != null && token != null && identical(_inProcessLocks[key], token)) {
      _inProcessLocks.remove(key);
    }
    final handle = _lockHandle;
    _lockHandle = null;
    if (handle != null) {
      try {
        await handle.close();
      } catch (_) {
        // 关闭句柄失败不影响退出；锁随进程结束释放。
      }
    }
  }

  /// 仅测试用：清空进程内锁注册表。
  static void resetInstanceLocksForTest() {
    _inProcessLocks.clear();
  }
}
