// 执行记录账本的本地存储。
//
// 布局（`<dataRoot>/execution/`，与 index.json / conversations/ 同级，可纳入备份）：
//   ledger.json     — 全部执行记录 + 完成事件（含 schemaVersion）
//   ledger.json.bak — 上一次成功写入的完整副本（主文件损坏时的恢复路径）
//   checkpoint.json — 活动计时检查点（小而频繁写，默认 15 秒一次）
//   instance.lock   — 多实例互斥锁文件（只创建，从不删除）
//
// 写入走 storage_json_write.dart，与会话和外部日历共用。读取时：
//   * 主文件损坏/缺失 → 回退 `.bak`；两者都不可解析 → 把损坏文件改名为
//     `ledger.json.corrupt-<时间戳>` 保留证据后以空账本启动，并给出明确提示；
//   * 读到 schema 比本构建更新的账本 → **只读**，避免用旧结构覆盖新数据。
//
// 多实例：`instance.lock` 用 `RandomAccessFile.lock(FileLock.exclusive)`（进程级）
// 加进程内注册表双保险。抢不到锁的实例进入只读模式：可以查看记录，但不能开始/
// 修改计时，并显示明确提示——不能两个进程各自产生重叠活动会话。

import 'dart:convert';
import 'dart:io';

import '../storage_json_write.dart';
import 'execution_ledger.dart';
import 'execution_models.dart';

/// 执行记录存储错误（不可写、读取失败等）。
class ExecutionStoreException implements Exception {
  const ExecutionStoreException(this.message, {this.path = ''});

  final String message;
  final String path;

  @override
  String toString() => path.isEmpty ? message : '$message（$path）';
}

/// 只读实例（另一个实例正在使用同一数据目录，或账本来自更新版本）。
class ExecutionReadOnlyException implements Exception {
  const ExecutionReadOnlyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `ExecutionStore.open()` 的结果：接线方据此显示提示并决定是否允许写入。
class ExecutionOpenResult {
  const ExecutionOpenResult({
    required this.ledger,
    this.checkpoint,
    this.readOnly = false,
    this.notice,
    this.recoveredFromBackup = false,
    this.corruptFallback = false,
    this.newerSchema = false,
    this.lockConflict = false,
  });

  final ExecutionLedger ledger;
  final TimerCheckpoint? checkpoint;
  final bool readOnly;

  /// 用户可见的一句话说明（只读/损坏恢复/锁冲突）；正常时为 null。
  final String? notice;

  final bool recoveredFromBackup;
  final bool corruptFallback;
  final bool newerSchema;
  final bool lockConflict;

  bool get ok => true;
}

class ExecutionStore {
  /// 磁盘模式：`dataRoot` 通常是 SessionStore 的同一个数据根目录。
  ExecutionStore(Directory dataRoot)
      : _root = dataRoot.absolute,
        _memoryOnly = false;

  /// 内存模式：没有任何可写目录时使用，界面仍可用但重启后丢失。
  ExecutionStore.memory()
      : _root = null,
        _memoryOnly = true;

  final Directory? _root;
  final bool _memoryOnly;

  ExecutionLedger _ledger = ExecutionLedger();
  TimerCheckpoint? _checkpoint;
  bool _opened = false;

  bool _readOnly = false;
  String? _readOnlyNotice;
  String? _loadNotice;
  bool _recoveredFromBackup = false;
  bool _corruptFallback = false;
  bool _newerSchema = false;

  RandomAccessFile? _lockHandle;
  Object? _lockToken;

  /// 进程内锁注册表：同一路径在同一个进程里也只允许一个写实例。
  static final Map<String, Object> _inProcessLocks = <String, Object>{};

  /// 本类的写入统一走 [writeJsonAtomically]（同路径串行化、唯一临时文件）。

  bool get isMemoryOnly => _memoryOnly;

  Directory? get dataRoot => _root;

  Directory get executionDir {
    final root = _root;
    if (root == null) return Directory('');
    return Directory('${root.path}${Platform.pathSeparator}execution');
  }

  File get ledgerFile =>
      File('${executionDir.path}${Platform.pathSeparator}ledger.json');

  File get ledgerBackupFile => File('${ledgerFile.path}.bak');

  File get checkpointFile =>
      File('${executionDir.path}${Platform.pathSeparator}checkpoint.json');

  File get instanceLockFile =>
      File('${executionDir.path}${Platform.pathSeparator}instance.lock');

  bool get readOnly => _readOnly;

  String? get readOnlyNotice => _readOnlyNotice;

  /// 本次打开过程中的一次性提示（损坏恢复、锁冲突等）。
  String? get loadNotice => _loadNotice;

  bool get opened => _opened;

  /// 当前账本（打开后长期持有同一引用；关闭前一直有效）。
  ExecutionLedger get ledger => _ledger;

  TimerCheckpoint? get checkpoint => _checkpoint;

  /// 打开存储：创建目录、抢实例锁、读取账本与检查点。
  ///
  /// 永不抛异常（除极端编程错误）：失败时给出只读/空账本 + [ExecutionOpenResult.notice]。
  Future<ExecutionOpenResult> open() async {
    if (_opened) {
      return ExecutionOpenResult(
        ledger: _ledger,
        checkpoint: _checkpoint,
        readOnly: _readOnly,
        notice: _loadNotice,
        recoveredFromBackup: _recoveredFromBackup,
        corruptFallback: _corruptFallback,
        newerSchema: _newerSchema,
      );
    }
    _opened = true;
    if (_memoryOnly) {
      _ledger = ExecutionLedger();
      _checkpoint = null;
      return ExecutionOpenResult(ledger: _ledger);
    }

    try {
      await executionDir.create(recursive: true);
    } catch (e) {
      _readOnly = true;
      _readOnlyNotice = '执行记录目录不可写，本次运行只读：$e';
      _ledger = ExecutionLedger();
      return ExecutionOpenResult(
        ledger: _ledger,
        readOnly: true,
        notice: _readOnlyNotice,
      );
    }

    final lock = await _tryAcquireInstanceLock();
    if (!lock) {
      _readOnly = true;
      _readOnlyNotice =
          '另一个 TaskScheduler 实例正在使用同一数据目录；本实例的执行计时为只读。'
          '请关闭另一个实例后再记录实际工时。';
      _loadNotice = _readOnlyNotice;
    }

    await _loadLedger();
    await _loadCheckpoint();

    return ExecutionOpenResult(
      ledger: _ledger,
      checkpoint: _checkpoint,
      readOnly: _readOnly,
      notice: _loadNotice,
      recoveredFromBackup: _recoveredFromBackup,
      corruptFallback: _corruptFallback,
      newerSchema: _newerSchema,
      lockConflict: !lock,
    );
  }

  /// 原子保存当前账本。只读时抛 [ExecutionReadOnlyException]。
  Future<void> persistLedger() async {
    if (_memoryOnly) return;
    if (_readOnly) {
      throw ExecutionReadOnlyException(
          _readOnlyNotice ?? '执行记录处于只读状态，未保存任何改动');
    }
    final payload = _ledger.toJson();
    try {
      await _writeJson(ledgerFile, payload);
    } catch (e) {
      throw ExecutionStoreException('执行记录保存失败：$e', path: ledgerFile.path);
    }
  }

  /// 写入活动计时检查点（有界间隔 + 关键点调用）。只读时抛
  /// [ExecutionReadOnlyException]。
  Future<void> saveCheckpoint(TimerCheckpoint checkpoint) async {
    _checkpoint = checkpoint;
    if (_memoryOnly) return;
    if (_readOnly) {
      throw ExecutionReadOnlyException(
          _readOnlyNotice ?? '执行记录处于只读状态，未保存计时检查点');
    }
    final payload = <String, dynamic>{
      'schemaVersion': kExecutionLedgerSchemaVersion,
      'activeTimer': checkpoint.toJson(),
    };
    try {
      await _writeJson(checkpointFile, payload, keepBackup: false);
    } catch (e) {
      throw ExecutionStoreException(
        '计时检查点保存失败：$e',
        path: checkpointFile.path,
      );
    }
  }

  /// 清除检查点（停止计时/确认后）。
  Future<void> clearCheckpoint() async {
    _checkpoint = null;
    if (_memoryOnly || _readOnly) return;
    for (final candidate in <File>[
      checkpointFile,
      File('${checkpointFile.path}.bak'),
    ]) {
      try {
        if (await candidate.exists()) await candidate.delete();
      } catch (_) {
        // 残留旧检查点由下次恢复流程按“已暂停/已停止”处理，不阻塞停止计时。
      }
    }
  }

  /// 恢复备份/异目录恢复：按 recordId / eventId 幂等合并，然后原子保存。
  ///
  /// 已存在的本地记录一律保留（不覆盖），重复恢复同一份数据不会改变任何计数。
  Future<MergeResult> mergeRestored(ExecutionLedger imported) async {
    if (_readOnly) {
      throw ExecutionReadOnlyException(
          _readOnlyNotice ?? '执行记录处于只读状态，未合并备份数据');
    }
    final result = _ledger.mergeFrom(imported);
    if (result.changed) await persistLedger();
    return result;
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

  // ------------------------------------------------------------- internals

  String? _lockKey() {
    final root = _root;
    if (root == null) return null;
    return root.path.toLowerCase();
  }

  Future<bool> _tryAcquireInstanceLock() async {
    final key = _lockKey();
    if (key == null) return true;
    if (_inProcessLocks.containsKey(key)) return false;
    final token = Object();
    _inProcessLocks[key] = token;
    try {
      final handle = await instanceLockFile.open(mode: FileMode.append);
      // 非阻塞排它锁：另一个进程持有时抛异常。
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

  Future<void> _loadLedger() async {
    final read = await _readJsonResult(ledgerFile);
    if (read.data != null) {
      final version = (read.data!['schemaVersion'] as num?)?.toInt();
      if (version != null && version > ExecutionLedger.schemaVersion) {
        _newerSchema = true;
        _readOnly = true;
        _readOnlyNotice = '执行记录来自更新的版本（schema $version），本次运行只读，'
            '不会覆盖该文件。';
        _loadNotice = _readOnlyNotice;
      }
      _ledger = ExecutionLedger.fromJson(read.data!);
      return;
    }
    // 主文件不可用：尝试 .bak。
    final backup = await _readJsonResult(ledgerBackupFile);
    if (backup.data != null) {
      _recoveredFromBackup = true;
      final version = (backup.data!['schemaVersion'] as num?)?.toInt();
      if (version != null && version > ExecutionLedger.schemaVersion) {
        _newerSchema = true;
        _readOnly = true;
        _readOnlyNotice = '执行记录备份来自更新的版本（schema $version），本次运行只读。';
      }
      _ledger = ExecutionLedger.fromJson(backup.data!);
      _loadNotice = '执行记录主文件损坏或缺失，已从 .bak 备份恢复。';
      return;
    }
    if (read.existed || backup.existed) {
      // 主文件与备份都不可解析：保留证据，使用空账本（明确提示，不静默）。
      final quarantined = await _quarantineCorruptLedger();
      _corruptFallback = true;
      if (quarantined == null) {
        // 连改名都失败：只读，避免把唯一剩余文件覆盖掉。
        _readOnly = true;
        _readOnlyNotice = '执行记录文件损坏且无法备份原文件，本次运行只读，'
            '请先手动备份或删除 ${ledgerFile.path}。';
        _loadNotice = _readOnlyNotice;
      } else {
        _loadNotice =
            '执行记录文件损坏且没有可用备份；损坏文件已保留为 $quarantined，'
            '本次以空账本启动。';
      }
    }
    _ledger = ExecutionLedger();
  }

  /// 把损坏的账本文件改名留证；返回新路径，失败返回 null。
  Future<String?> _quarantineCorruptLedger() async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    for (final candidate in <File>[ledgerFile, ledgerBackupFile]) {
      try {
        if (!await candidate.exists()) continue;
        final target = '${candidate.path}.corrupt-$stamp';
        await candidate.rename(target);
        return target;
      } catch (_) {
        // 试下一个候选；全部失败时上层转只读。
      }
    }
    return null;
  }

  Future<void> _loadCheckpoint() async {
    final read = await _readJsonResult(checkpointFile);
    final raw = read.data;
    if (raw == null) return;
    final version = (raw['schemaVersion'] as num?)?.toInt();
    if (version != null && version > kExecutionLedgerSchemaVersion) {
      _loadNotice = '计时检查点来自更新版本，已忽略（本次不会自动恢复上次计时）。';
      return;
    }
    _checkpoint = TimerCheckpoint.fromJson(raw['activeTimer']);
  }

  ({Map<String, dynamic>? data, bool existed}) _readJsonSyncResult(File file) {
    try {
      if (!file.existsSync()) return (data: null, existed: false);
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) return (data: null, existed: true);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return (data: decoded, existed: true);
      }
      return (data: null, existed: true);
    } catch (_) {
      return (data: null, existed: true);
    }
  }

  /// 只读指定文件本身（不自动回退 `.bak`）：调用方需要区分“主文件损坏”与
  /// “主文件缺失”，才能给出正确提示并按 recordId 幂等恢复。
  Future<({Map<String, dynamic>? data, bool existed})> _readJsonResult(
      File file) async {
    final sync = _readJsonSyncResult(file);
    if (sync.data != null) return sync;
    // 第二次判断“是否存在”，只用于区分“没有文件”与“文件损坏”。
    return (data: null, existed: await file.exists());
  }

  /// 检查点用 `keepBackup: false`：允许丢一个写入周期，不需要 `.bak`。
  Future<void> _writeJson(
    File file,
    Map<String, dynamic> data, {
    bool keepBackup = true,
  }) =>
      writeJsonAtomically(file, data, keepBackup: keepBackup);

  /// 仅测试用：清空进程内锁注册表（正常情况下 close() 会释放）。
  static void resetInstanceLocksForTest() {
    _inProcessLocks.clear();
  }
}
