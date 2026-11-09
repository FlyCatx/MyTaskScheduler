// 执行截止会话的本地存储（0.5.0 任务 13）。
//
// 布局（与执行账本同一目录，`<dataRoot>/execution/`）：
//   deadlines.json     — 截止会话 + 投递账本（含 schemaVersion）
//   deadlines.json.bak — 上一次成功写入的副本（主文件损坏时的恢复路径）
//
// 设计：
//   * 只保存“身份/阶段/截止/投递/完成结果”这些恢复所需事实，不复制执行区间；
//   * 主文件与备份都不可解析时，把损坏文件改名留证后以空列表启动，并给明确提示；
//   * 读到来自更新版本的 schema 时只读：绝不用旧结构覆盖新数据；
//   * 内存模式（没有可写目录）完全可用，只是重启后丢失（与执行账本一致）。

import 'dart:convert';
import 'dart:io';

import '../storage_json_write.dart';
import 'execution_deadline.dart';
import 'execution_store.dart';

/// 读取结果：会话列表 + 一次性提示（损坏恢复/更新版本只读）。
class ExecutionDeadlineLoadResult {
  const ExecutionDeadlineLoadResult({
    required this.sessions,
    this.notice,
    this.readOnly = false,
  });

  final List<ExecutionDeadlineSession> sessions;
  final String? notice;
  final bool readOnly;
}

class ExecutionDeadlineStore {
  ExecutionDeadlineStore(this._executionStore);

  final ExecutionStore _executionStore;

  bool get isMemoryOnly => _executionStore.isMemoryOnly;

  File get deadlineFile => File(
      '${_executionStore.executionDir.path}${Platform.pathSeparator}deadlines.json');

  File get deadlineBackupFile => File('${deadlineFile.path}.bak');

  /// 读取持久化的截止会话；永不抛异常。
  Future<ExecutionDeadlineLoadResult> load() async {
    if (isMemoryOnly) {
      return const ExecutionDeadlineLoadResult(sessions: <ExecutionDeadlineSession>[]);
    }
    final main = _readJson(deadlineFile);
    final backup = main == null ? _readJson(deadlineBackupFile) : null;
    final data = main ?? backup;
    if (data == null) {
      // 文件存在但都不可解析：改名留证，避免静默覆盖（与执行账本策略一致）。
      final existed = deadlineFile.existsSync() || deadlineBackupFile.existsSync();
      if (existed) {
        final quarantined = _quarantineCorrupt();
        return ExecutionDeadlineLoadResult(
          sessions: const <ExecutionDeadlineSession>[],
          notice: quarantined == null
              ? '执行截止记录损坏且无法备份原文件，本次以空记录启动（未写入可能被覆盖）。'
              : '执行截止记录损坏；原文件已保留为 $quarantined，本次以空记录启动。',
        );
      }
      return const ExecutionDeadlineLoadResult(sessions: <ExecutionDeadlineSession>[]);
    }
    final version = (data['schemaVersion'] as num?)?.toInt();
    if (version != null && version > kExecutionDeadlineSchemaVersion) {
      return ExecutionDeadlineLoadResult(
        sessions: const <ExecutionDeadlineSession>[],
        readOnly: true,
        notice: '执行截止记录来自更新的版本（schema $version），本次不会自动补发或覆盖。',
      );
    }
    final rawSessions = data['sessions'];
    final sessions = <ExecutionDeadlineSession>[];
    if (rawSessions is List) {
      for (final item in rawSessions) {
        final session = ExecutionDeadlineSession.fromJson(item);
        if (session != null) sessions.add(session);
      }
    }
    return ExecutionDeadlineLoadResult(
      sessions: sessions,
      notice: backup != null ? '执行截止记录主文件损坏，已从 .bak 备份恢复。' : null,
    );
  }

  /// 原子保存；内存模式为 no-op。失败抛 [ExecutionStoreException]（可重试）。
  Future<void> save(List<ExecutionDeadlineSession> sessions) async {
    if (isMemoryOnly) return;
    final retained = sessions.length <= kMaxRetainedDeadlineSessions
        ? sessions
        : sessions.sublist(sessions.length - kMaxRetainedDeadlineSessions);
    final payload = <String, dynamic>{
      'schemaVersion': kExecutionDeadlineSchemaVersion,
      'sessions': retained.map((s) => s.toJson()).toList(growable: false),
    };
    try {
      await deadlineFile.parent.create(recursive: true);
      await writeJsonAtomically(deadlineFile, payload);
    } catch (e) {
      throw ExecutionStoreException('执行截止记录保存失败：$e', path: deadlineFile.path);
    }
  }

  Map<String, dynamic>? _readJson(File file) {
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  String? _quarantineCorrupt() {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    for (final candidate in <File>[deadlineFile, deadlineBackupFile]) {
      try {
        if (!candidate.existsSync()) continue;
        final target = '${candidate.path}.corrupt-$stamp';
        candidate.renameSync(target);
        return target;
      } catch (_) {
        // 试下一个候选。
      }
    }
    return null;
  }
}
