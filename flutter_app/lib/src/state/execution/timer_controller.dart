// 全应用唯一的计时控制器（R3-E1/E3）。
//
// 产品语义（用测试锁住，不要为了“方便”改）：
//   * **停止计时 ≠ 完成任务**：本控制器只记录实际工作，从不修改任务完成状态。
//   * **完成任务不自动写实际耗时**：任务完成/预估都不会被抄进执行记录。
//   * **重新打开任务不重置已确认实际**：记录是独立账本，只追加/修订，不会清零。
//   * 全应用同时只允许一个活动计时；开始另一个任务时**明确暂停当前**，并在返回值/
//     提示里说明“已暂停 X”。
//   * **单调时钟算时长，UTC 持久化**：系统时间回拨/跳变不会产生负时长或巨额工时。
//   * **睡眠/锁屏**：用 wall-monotonic 漂移与“两次 tick 间隔异常”检测 → 关闭当前
//     区间并把不确定的那段放进待校正；默认暂停，不把离开时间算成工作。
//   * **checkpoint 有界间隔（默认 15 秒）+ 暂停/继续/停止/切换等关键点落盘**：
//     崩溃最多丢失 [checkpointInterval] 的已确认时长；从最后检查点到重启的时间
//     进入待校正，不默认算成工作。
//   * **多实例互斥**：数据目录被另一个实例持有时，本控制器只读并给出明确提示。
//
// 精度：内部以微秒/秒保存；界面按分钟取整只影响显示，不回写丢精度。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'effort_clock.dart';
import 'effort_stats.dart';
import 'execution_ledger.dart';
import 'execution_models.dart';
import 'execution_store.dart';

/// 默认检查点间隔：崩溃最多丢失这么多“已确认时长”。
const Duration kDefaultCheckpointInterval = Duration(seconds: 15);

/// 墙钟与单调时钟的允许偏差：超过即视为时间被改动或进程被挂起。
const Duration kClockDriftTolerance = Duration(seconds: 2);

/// 两次 tick 之间的合理最大间隔：超过说明事件循环被睡眠/挂起打断过。
const Duration kTickGapTolerance = Duration(seconds: 5);

/// 单次计时区间的合理上限，防御时钟实现异常产生“巨额工时”。
const Duration kMaxSingleInterval = Duration(hours: 24);

/// 单条手工补记的合理上限。
const Duration kMaxManualEntryDuration = Duration(hours: 24);

/// 手工补记备注长度上限（不导出原文材料）。
const int kMaxManualNoteLength = 500;

/// 手工补记可回溯的年数上限（防止输入错年份产生离谱记录）。
const int kMaxManualBackfillYears = 10;

/// `start()` 的结果。
class TimerStartResult {
  const TimerStartResult({
    required this.ok,
    required this.message,
    this.active,
    this.pausedTaskName,
  });

  final bool ok;
  final String message;
  final ActiveTimer? active;

  /// 因为切换任务而被明确暂停的旧任务名（null 表示没有切换）。
  final String? pausedTaskName;
}

/// 计时操作的结果。
class TimerActionResult {
  const TimerActionResult({required this.ok, required this.message, this.confirmed});

  final bool ok;
  final String message;

  /// 与本次操作相关的已确认时长（停止计时返回本次会话时长）。
  final Duration? confirmed;
}

/// `load()` 的结果。
class TimerLoadResult {
  const TimerLoadResult({
    required this.ok,
    required this.readOnly,
    this.notice,
    this.recoveredCheckpoint,
    this.recoveryNotice,
  });

  final bool ok;
  final bool readOnly;

  /// 只读/损坏恢复等一次性提示。
  final String? notice;

  /// 恢复的检查点（null = 上次没有活动计时）。
  final TimerCheckpoint? recoveredCheckpoint;

  /// 崩溃恢复后的说明（用户需要知道检查点之后的时间进了待校正）。
  final String? recoveryNotice;
}

/// 手工补记校验结果（不写盘；对话框可先用它展示重叠区间）。
class ManualEntryValidation {
  const ManualEntryValidation({
    required this.ok,
    required this.message,
    required this.durationSeconds,
    this.startUtc,
    this.endUtc,
    this.localDate = '',
    this.overlaps = const <OverlapHit>[],
    this.overlapTotal = Duration.zero,
  });

  final bool ok;
  final String message;
  final int durationSeconds;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final String localDate;
  final List<OverlapHit> overlaps;
  final Duration overlapTotal;

  bool get hasOverlap => overlaps.isNotEmpty;
}

/// 手工补记的写入结果。
class ManualEntryOutcome {
  const ManualEntryOutcome({
    required this.ok,
    required this.message,
    this.entry,
    this.recordId,
    this.overlaps = const <OverlapHit>[],
    this.overlapTotal = Duration.zero,
    this.overlapExcluded = Duration.zero,
  });

  final bool ok;
  final String message;
  final ManualEntry? entry;
  final String? recordId;
  final List<OverlapHit> overlaps;
  final Duration overlapTotal;

  /// 默认口径下未计入的重叠时长（0 = 没有排除任何重叠）。
  final Duration overlapExcluded;
}

/// 当前活动计时的只读视图。
class ActiveTimer {
  const ActiveTimer({
    required this.recordId,
    required this.conversationId,
    required this.taskId,
    required this.taskName,
    required this.planVersionId,
    required this.planRevision,
    required this.sessionStartedAtUtc,
    required this.phase,
    this.openIntervalStartUtc,
    this.pausedAtUtc,
  });

  final String recordId;
  final String conversationId;
  final String taskId;
  final String taskName;
  final String planVersionId;
  final int planRevision;
  final DateTime sessionStartedAtUtc;
  final TimerPhase phase;
  final DateTime? openIntervalStartUtc;
  final DateTime? pausedAtUtc;

  bool get isRunning => phase == TimerPhase.running;
  bool get isPaused => phase == TimerPhase.paused;
}

class TimerController extends ChangeNotifier {
  TimerController({
    required this.store,
    EffortClock? clock,
    EffortLocalTime? localTime,
    this.checkpointInterval = kDefaultCheckpointInterval,
    this.driftTolerance = kClockDriftTolerance,
    this.tickGapTolerance = kTickGapTolerance,
    this.maxSingleInterval = kMaxSingleInterval,
    this.uiTickInterval = const Duration(seconds: 1),
    this.autoTick = true,
  })  : clock = clock ?? SystemEffortClock(),
        localTime = localTime ?? const SystemEffortLocalTime();

  final ExecutionStore store;
  final EffortClock clock;
  final EffortLocalTime localTime;

  /// 检查点间隔（= 崩溃最大可丢失的已确认时长）。
  final Duration checkpointInterval;
  final Duration driftTolerance;
  final Duration tickGapTolerance;
  final Duration maxSingleInterval;
  final Duration uiTickInterval;

  /// 是否创建 1 秒 UI tick 定时器。单元测试关闭它并用 [tick] 手动推进。
  final bool autoTick;

  Timer? _uiTimer;
  bool _disposed = false;
  bool _loaded = false;
  bool _shutdownStarted = false;
  bool _readOnly = false;
  String? _readOnlyNotice;
  String? _notice;
  String? _recoveryNotice;

  ActiveTimer? _active;
  TimerPhase _phase = TimerPhase.idle;

  DateTime? _openStartUtc;
  Duration? _openStartMonotonic;

  DateTime? _lastTickUtc;
  Duration? _lastTickMonotonic;
  Duration _lastCheckpointMonotonic = Duration.zero;

  /// 本次计时会话中已闭区间的累计时长（单调时钟口径），用于状态条显示。
  Duration _sessionClosed = Duration.zero;

  // ------------------------------------------------------------------ 只读属

  ExecutionLedger get ledger => store.ledger;

  bool get readOnly => _readOnly;

  String? get readOnlyNotice => _readOnlyNotice;

  /// 最近一次操作提示（中文）。UI 显示后可调用 [clearNotice]。
  String? get notice => _notice;

  /// 崩溃/异常退出的恢复说明（显示给用户，直到停止本次计时）。
  String? get recoveryNotice => _recoveryNotice;

  TimerPhase get phase => _phase;

  ActiveTimer? get active => _active;

  bool get hasActive => _active != null;

  bool get isRunning => _phase == TimerPhase.running;

  bool get isPaused => _phase == TimerPhase.paused;

  Duration get elapsed {
    final active = _active;
    if (active == null) return Duration.zero;
    var micros = _sessionClosed.inMicroseconds;
    if (_phase == TimerPhase.running) {
      final start = _openStartMonotonic;
      if (start != null) {
        final delta = clock.monotonic - start;
        if (delta > Duration.zero) {
          micros += math.min(delta.inMicroseconds, maxSingleInterval.inMicroseconds);
        }
      }
    }
    return Duration(microseconds: math.max(0, micros));
  }

  /// 全局未处理的待校正区间（跨记录；停止计时后仍会提示用户处理）。
  List<({ExecutionRecord record, PendingCorrection correction})>
      get openCorrections => ledger.openCorrections;

  bool get hasOpenCorrections => ledger.openCorrections.isNotEmpty;

  /// 崩溃恢复等场景下最大可丢失的已确认时长（给 UI/文档显示）。
  Duration get maxCheckpointLoss => checkpointInterval;

  String get localTodayDate => formatLocalDate(localTime.toLocal(clock.nowUtc));

  // ------------------------------------------------------------------ 生命周期

  /// 打开账本并恢复上次计时检查点。
  Future<TimerLoadResult> load() async {
    if (_loaded) {
      return TimerLoadResult(
        ok: true,
        readOnly: _readOnly,
        notice: _readOnlyNotice,
        recoveryNotice: _recoveryNotice,
      );
    }
    final openResult = await store.open();
    _loaded = true;
    _readOnly = openResult.readOnly;
    _readOnlyNotice = openResult.readOnly ? openResult.notice : null;
    _notice = openResult.notice;

    if (!_readOnly && openResult.checkpoint != null) {
      await _recoverFromCheckpoint(openResult.checkpoint!);
    }
    if (_readOnly) {
      _phase = TimerPhase.idle;
      _active = null;
    }
    if (autoTick && !_disposed) {
      _uiTimer =
          Timer.periodic(uiTickInterval, (_) => unawaited(tick()));
    }
    _notify();
    return TimerLoadResult(
      ok: true,
      readOnly: _readOnly,
      notice: openResult.notice,
      recoveredCheckpoint: openResult.checkpoint,
      recoveryNotice: _recoveryNotice,
    );
  }

  /// 开始计时。
  ///
  /// 已有别的活动计时时**先明确暂停它**（返回 [TimerStartResult.pausedTaskName]），
  /// 保证全应用同时只有一个活动计时。
  Future<TimerStartResult> start(ExecutionTaskRef ref) async {
    if (!await _ensureWritable('开始计时')) {
      return TimerStartResult(ok: false, message: _readOnlyNotice ?? '只读实例不能开始计时');
    }
    final active = _active;
    if (active != null && active.taskId == ref.taskId) {
      if (active.isRunning) {
        return TimerStartResult(
          ok: false,
          message: '「${active.taskName}」正在计时中',
          active: active,
        );
      }
      return TimerStartResult(
        ok: false,
        message: '「${active.taskName}」已暂停，点击继续即可恢复计时',
        active: active,
      );
    }

    String? pausedTaskName;
    if (active != null) {
      final paused = await pause();
      if (!paused.ok) {
        return TimerStartResult(ok: false, message: '切换计时失败：${paused.message}');
      }
      pausedTaskName = active.taskName;
    }

    final now = clock.nowUtc;
    final offsetMinutes = localTime.offsetMinutesAt(now);
    final record = ExecutionRecord.start(
      recordId: newExecutionId('exe'),
      conversationId: ref.conversationId,
      taskId: ref.taskId,
      taskName: ref.taskName,
      lineageRootId: ref.lineageRootId,
      planVersionId: ref.planVersionId,
      planRevision: ref.planRevision,
      startedAtUtc: now,
      timeZoneName: localTime.timeZoneLabel,
      timeZoneOffsetMinutes: offsetMinutes,
      estimateBaselineHours: ref.effectiveEstimateHours,
    );
    ledger.addRecord(record);
    final saved = await _persistLedger();
    if (!saved) {
      // 账本没写成功：回滚内存记录，避免“界面显示在计时但磁盘没有任何记录”。
      ledger.removeRecord(record.recordId);
      _notice = '计时未开始：执行记录保存失败（数据未写入磁盘，请检查磁盘权限/空间）';
      _notify();
      return TimerStartResult(ok: false, message: _notice!);
    }

    _active = ActiveTimer(
      recordId: record.recordId,
      conversationId: record.conversationId,
      taskId: record.taskId,
      taskName: record.taskName,
      planVersionId: record.planVersionId,
      planRevision: record.planRevision,
      sessionStartedAtUtc: now,
      phase: TimerPhase.running,
      openIntervalStartUtc: now,
    );
    _phase = TimerPhase.running;
    _openStartUtc = now;
    _openStartMonotonic = clock.monotonic;
    _lastTickUtc = now;
    _lastTickMonotonic = clock.monotonic;
    _lastCheckpointMonotonic = clock.monotonic;
    _sessionClosed = Duration.zero;
    _recoveryNotice = null;
    await _writeCheckpointQuietly();
    _notice = pausedTaskName == null
        ? '开始计时：${ref.taskName}'
        : '已暂停「$pausedTaskName」，开始计时：${ref.taskName}';
    _notify();
    return TimerStartResult(
      ok: true,
      message: _notice!,
      active: _active,
      pausedTaskName: pausedTaskName,
    );
  }

  /// 暂停计时：关闭当前区间，暂停时间不计入实际耗时。
  Future<TimerActionResult> pause() async {
    if (_active == null) {
      return const TimerActionResult(ok: false, message: '当前没有正在计时的任务');
    }
    if (_phase != TimerPhase.running) {
      return const TimerActionResult(ok: false, message: '计时已经处于暂停状态');
    }
    if (!await _ensureWritable('暂停计时')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例不能修改计时');
    }
    final closed = _closeOpenInterval();
    final saved = await _persistLedger();
    if (closed != null) {
      _sessionClosed += closed;
    }
    _phase = TimerPhase.paused;
    _openStartUtc = null;
    _openStartMonotonic = null;
    _active = _copyActive(phase: TimerPhase.paused, pausedAt: clock.nowUtc);
    await _writeCheckpointQuietly();
    _notice = saved ? '已暂停计时（暂停时间不计入实际耗时）' : '已暂停，但执行记录保存失败，请检查磁盘';
    _notify();
    return TimerActionResult(
      ok: saved,
      message: _notice!,
      confirmed: _sessionClosed,
    );
  }

  /// 继续计时：产生新的有效区间。
  Future<TimerActionResult> resume() async {
    if (_active == null) {
      return const TimerActionResult(ok: false, message: '当前没有正在计时的任务');
    }
    if (_phase == TimerPhase.running) {
      return const TimerActionResult(ok: false, message: '计时正在进行中');
    }
    if (!await _ensureWritable('继续计时')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例不能修改计时');
    }
    final now = clock.nowUtc;
    _phase = TimerPhase.running;
    _openStartUtc = now;
    _openStartMonotonic = clock.monotonic;
    _lastTickUtc = now;
    _lastTickMonotonic = clock.monotonic;
    _lastCheckpointMonotonic = clock.monotonic;
    _active = _copyActive(phase: TimerPhase.running);
    await _writeCheckpointQuietly();
    _notice = '继续计时：${_active?.taskName ?? ''}';
    _notify();
    return TimerActionResult(ok: true, message: _notice!, confirmed: _sessionClosed);
  }

  /// 停止本次计时并确认。**不会**把任务标记为完成，也不会写预估为实际。
  Future<TimerActionResult> stopAndConfirm() => _stopAndConfirmInternal();

  /// 按“有效截止点”结算本次计时（任务 13 到点待处理）。
  ///
  /// 与 [stopAndConfirm] 的唯一区别：当前未闭区间被截断在 [deadlineUtc]，到点之后
  /// 才轮询到的等待时间绝不写进实际耗时。若开始时间已经晚于截止点（例如用户给
  /// 已过截止的任务手动开始），不删掉真实发生的工作，按正常停止处理。
  Future<TimerActionResult> stopAndConfirmAt(DateTime deadlineUtc) =>
      _stopAndConfirmInternal(atUtc: deadlineUtc);

  Future<TimerActionResult> _stopAndConfirmInternal({DateTime? atUtc}) async {
    final active = _active;
    if (active == null) {
      return const TimerActionResult(ok: false, message: '当前没有正在计时的任务');
    }
    if (!await _ensureWritable('停止计时')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例不能修改计时');
    }
    Duration closed = Duration.zero;
    if (_phase == TimerPhase.running) {
      closed = _closeOpenInterval(atUtc: atUtc) ?? Duration.zero;
      _sessionClosed += closed;
    }
    final record = ledger.recordById(active.recordId);
    if (record != null) {
      final next = record.copyWith(
        state: record.hasOpenCorrections
            ? ExecutionRecordState.pendingCorrection
            : ExecutionRecordState.confirmed,
      );
      ledger.replaceRecord(next);
    }
    final saved = await _persistLedger();
    await store.clearCheckpoint();
    final done = _sessionClosed;
    final openCorrections = ledger.openCorrections;
    _active = null;
    _phase = TimerPhase.idle;
    _openStartUtc = null;
    _openStartMonotonic = null;
    _lastTickUtc = null;
    _lastTickMonotonic = null;
    _sessionClosed = Duration.zero;
    _recoveryNotice = null;
    _notice = saved
        ? '已停止并确认本次计时 ${formatEffortDuration(done)}。'
            '任务完成状态未改变；${openCorrections.isEmpty ? '没有待校正区间' : '还有 ${openCorrections.length} 段待校正区间需要确认'}'
        : '已停止计时，但执行记录保存失败，请检查磁盘';
    _notify();
    return TimerActionResult(ok: saved, message: _notice!, confirmed: done);
  }

  /// 周期/手动检查点：检测时钟漂移与睡眠，写检查点。
  ///
  /// autoTick 打开时由 1 秒 UI 定时器调用；测试可关闭 autoTick 后手动调用。
  Future<TimerActionResult> tick() async {
    if (_disposed) return const TimerActionResult(ok: false, message: '控制器已释放');
    if (_active == null) return const TimerActionResult(ok: false, message: '当前没有活动计时');
    if (_readOnly) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final nowUtc = clock.nowUtc;
    final nowMonotonic = clock.monotonic;

    if (_phase == TimerPhase.running) {
      final lastMono = _lastTickMonotonic;
      final lastUtc = _lastTickUtc;
      final openStart = _openStartMonotonic;
      if (lastMono != null && lastUtc != null && openStart != null) {
        final monoDelta = nowMonotonic - lastMono;
        final wallDelta = nowUtc.difference(lastUtc);
        final drift = monoDelta - wallDelta;
        final intervalTooLong = nowMonotonic - openStart > maxSingleInterval;
        final driftExceeded = drift.abs() > driftTolerance;
        final gapTooLong = monoDelta > tickGapTolerance;

        if (driftExceeded || gapTooLong || intervalTooLong) {
          return _splitForUncertainty(
            nowUtc: nowUtc,
            nowMonotonic: nowMonotonic,
            monoDelta: monoDelta,
            wallDelta: wallDelta,
            reason: intervalTooLong
                ? CorrectionReason.suspend
                : (wallDelta.isNegative || drift.isNegative
                    ? CorrectionReason.clockJump
                    : CorrectionReason.suspend),
            intervalTooLong: intervalTooLong,
          );
        }

        _lastTickUtc = nowUtc;
        _lastTickMonotonic = nowMonotonic;

        final sinceCheckpoint = nowMonotonic - _lastCheckpointMonotonic;
        if (sinceCheckpoint >= checkpointInterval) {
          final saved = await _writeCheckpointQuietly();
          if (saved) _lastCheckpointMonotonic = nowMonotonic;
        }
      }
    }
    _notify();
    return const TimerActionResult(ok: true, message: '检查点已更新');
  }

  /// 应用被挂起/锁屏/睡眠后的显式钩子（来自窗口生命周期或电源事件）。
  ///
  /// 默认策略：关闭当前区间、把上次 tick 到现在放进待校正、暂停计时。
  Future<TimerActionResult> handleAwayDetected({
    CorrectionReason reason = CorrectionReason.suspend,
  }) async {
    final active = _active;
    if (active == null || _phase != TimerPhase.running) {
      return const TimerActionResult(ok: false, message: '当前没有正在运行的计时');
    }
    if (!await _ensureWritable('记录离开场景')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final nowUtc = clock.nowUtc;
    final nowMonotonic = clock.monotonic;
    final lastMono = _lastTickMonotonic ?? _openStartMonotonic ?? nowMonotonic;
    final lastUtc = _lastTickUtc ?? _openStartUtc ?? nowUtc;
    return _splitForUncertainty(
      nowUtc: nowUtc,
      nowMonotonic: nowMonotonic,
      monoDelta: nowMonotonic - lastMono,
      wallDelta: nowUtc.difference(lastUtc),
      reason: reason,
      intervalTooLong: false,
    );
  }

  /// 从挂起/锁屏恢复后的显式钩子。
  ///
  /// 本控制器默认在检测到离开时已经暂停，所以这里只返回说明，不会把离开时间
  /// 自动算成工作；用户需要先校正待校正区间。
  Future<TimerActionResult> handleResumeFromAway() async {
    final open = ledger.openCorrections;
    if (open.isEmpty) {
      return const TimerActionResult(ok: true, message: '已恢复；没有需要校正的时间区间');
    }
    _notice = '已恢复；离开期间的 ${open.length} 段不确定时间已标记为待校正，请确认是否计入。';
    _notify();
    return TimerActionResult(ok: true, message: _notice!);
  }

  /// 处理一段待校正区间：折扣 / 全额 / 自定义。
  Future<TimerActionResult> resolveCorrection(
    String correctionId,
    CorrectionDecision decision, {
    Duration? custom,
  }) async {
    if (!await _ensureWritable('校正计时')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final record = _recordForCorrection(correctionId);
    if (record == null) {
      return const TimerActionResult(ok: false, message: '找不到这段待校正区间');
    }
    final index =
        record.pendingCorrections.indexWhere((c) => c.correctionId == correctionId);
    if (index < 0) {
      return const TimerActionResult(ok: false, message: '找不到这段待校正区间');
    }
    final correction = record.pendingCorrections[index];
    if (!correction.isOpen) {
      return const TimerActionResult(ok: false, message: '这段区间已经处理过了');
    }
    int seconds;
    switch (decision) {
      case CorrectionDecision.discount:
        seconds = 0;
      case CorrectionDecision.countFull:
        seconds = correction.wallDeltaSeconds > 0 ? correction.wallDeltaSeconds : 0;
      case CorrectionDecision.custom:
        final value = custom;
        if (value == null || value.isNegative) {
          return const TimerActionResult(ok: false, message: '自定义时长必须是非负数');
        }
        seconds = value.inSeconds;
    }
    if (seconds > kMaxPendingCorrectionSeconds) {
      seconds = kMaxPendingCorrectionSeconds;
    }
    final resolved = correction.resolved(
      decision: decision,
      seconds: seconds,
      atUtc: clock.nowUtc,
    );
    final corrections = List<PendingCorrection>.from(record.pendingCorrections);
    corrections[index] = resolved;
    final next = record.copyWith(
      pendingCorrections: corrections,
      state: corrections.any((c) => c.isOpen)
          ? ExecutionRecordState.pendingCorrection
          : ExecutionRecordState.confirmed,
    );
    ledger.replaceRecord(next);
    final saved = await _persistLedger();
    final minutes = formatEffortDuration(Duration(seconds: seconds));
    _notice = saved
        ? '已处理待校正区间：计入 $minutes（报告会按此口径统计）'
        : '已更新内存，但执行记录保存失败';
    _notify();
    return TimerActionResult(ok: saved, message: _notice!);
  }

  // -------------------------------------------------------------- 手工补记

  /// 校验手工补记草稿（不写盘）。对话框用它先展示重叠区间。
  Future<ManualEntryValidation> previewManualEntry(
    ExecutionTaskRef ref,
    ManualEntryDraft draft,
  ) async {
    if (_readOnly) {
      return ManualEntryValidation(
        ok: false,
        message: _readOnlyNotice ?? '只读实例不能补记工时',
        durationSeconds: 0,
      );
    }
    if (ref.taskId.trim().isEmpty || ref.conversationId.trim().isEmpty) {
      return const ManualEntryValidation(
        ok: false,
        message: '缺少任务或会话信息，无法补记',
        durationSeconds: 0,
      );
    }
    final now = clock.nowUtc;
    final nowLocalDate = formatLocalDate(localTime.toLocal(now));

    if (draft.mode == ManualEntryMode.startEnd) {
      final start = draft.startUtc?.toUtc();
      final end = draft.endUtc?.toUtc();
      if (start == null || end == null) {
        return const ManualEntryValidation(
          ok: false,
          message: '起止模式需要填写开始和结束时间',
          durationSeconds: 0,
        );
      }
      if (!end.isAfter(start)) {
        return ManualEntryValidation(
          ok: false,
          message: '结束时间必须晚于开始时间',
          durationSeconds: 0,
          startUtc: start,
          endUtc: end,
        );
      }
      if (end.isAfter(now)) {
        return ManualEntryValidation(
          ok: false,
          message: '不能补记未来时间；以后的安排请用排程/日历功能',
          durationSeconds: 0,
          startUtc: start,
          endUtc: end,
        );
      }
      final duration = end.difference(start);
      if (duration > kMaxManualEntryDuration) {
        return ManualEntryValidation(
          ok: false,
          message: '单次补记不能超过 ${kMaxManualEntryDuration.inHours} 小时',
          durationSeconds: duration.inSeconds,
          startUtc: start,
          endUtc: end,
        );
      }
      final overlaps = ledger.findOverlaps(
        startUtc: start,
        endUtc: end,
      );
      final overlapTotal = Duration(
        microseconds: overlaps.fold<int>(
          0,
          (sum, hit) => sum + hit.overlapDuration.inMicroseconds,
        ),
      );
      final localDate = formatLocalDate(localTime.toLocal(start));
      final baseMessage = overlaps.isEmpty
          ? '补记时长：${formatEffortDuration(duration)}'
          : '补记时长 ${formatEffortDuration(duration)}；与已有记录重叠 '
              '${formatEffortDuration(overlapTotal)}（${overlaps.length} 段），'
              '默认不计入重叠部分';
      return ManualEntryValidation(
        ok: true,
        message: baseMessage,
        durationSeconds: duration.inSeconds,
        startUtc: start,
        endUtc: end,
        localDate: localDate,
        overlaps: List<OverlapHit>.unmodifiable(overlaps),
        overlapTotal: overlapTotal,
      );
    }

    // 仅时长模式
    final duration = draft.duration;
    if (duration == null || duration.isNegative) {
      return const ManualEntryValidation(
        ok: false,
        message: '补记时长必须是非负的分钟/秒数',
        durationSeconds: 0,
      );
    }
    if (duration > kMaxManualEntryDuration) {
      return ManualEntryValidation(
        ok: false,
        message: '单次补记不能超过 ${kMaxManualEntryDuration.inHours} 小时',
        durationSeconds: duration.inSeconds,
      );
    }
    final localDate = draft.localDate?.trim().isNotEmpty == true
        ? draft.localDate!.trim()
        : nowLocalDate;
    final parsedDate = parseLocalDate(localDate);
    if (parsedDate == null) {
      return const ManualEntryValidation(
        ok: false,
        message: '日期格式应为 YYYY-MM-DD',
        durationSeconds: 0,
      );
    }
    final today = parseLocalDate(nowLocalDate)!;
    if (parsedDate.isAfter(today)) {
      return ManualEntryValidation(
        ok: false,
        message: '不能补记未来日期；以后的安排请用排程/日历功能',
        durationSeconds: duration.inSeconds,
        localDate: localDate,
      );
    }
    final earliest = DateTime.utc(today.year - kMaxManualBackfillYears, today.month,
        today.day);
    if (parsedDate.isBefore(earliest)) {
      return ManualEntryValidation(
        ok: false,
        message: '日期过于久远，请确认是否输错年份',
        durationSeconds: duration.inSeconds,
        localDate: localDate,
      );
    }
    if ((draft.note ?? '').length > kMaxManualNoteLength) {
      return ManualEntryValidation(
        ok: false,
        message: '说明不能超过 $kMaxManualNoteLength 个字',
        durationSeconds: duration.inSeconds,
        localDate: localDate,
      );
    }
    return ManualEntryValidation(
      ok: true,
      message: '仅时长补记无法检测与已有记录的重叠；请确认没有重复记录。'
          '补记时长：${formatEffortDuration(duration)}',
      durationSeconds: duration.inSeconds,
      localDate: localDate,
    );
  }

  /// 写入手工补记。默认口径：与已有记录重叠的部分**不计入**；
  /// 用户明确选择 [OverlapPolicy.includeOverlap] 时才计入，并在报告里标注口径。
  Future<ManualEntryOutcome> addManualEntry(
    ExecutionTaskRef ref,
    ManualEntryDraft draft,
  ) async {
    final validation = await previewManualEntry(ref, draft);
    if (!validation.ok) {
      return ManualEntryOutcome(
        ok: false,
        message: validation.message,
        overlaps: validation.overlaps,
        overlapTotal: validation.overlapTotal,
      );
    }
    if (!await _ensureWritable('补记工时')) {
      return ManualEntryOutcome(
        ok: false,
        message: _readOnlyNotice ?? '只读实例不能补记工时',
      );
    }

    final record = _recordForManualEntry(ref);
    final now = clock.nowUtc;
    final entry = ManualEntry(
      entryId: newExecutionId('man'),
      mode: draft.mode,
      startUtc: validation.startUtc,
      endUtc: validation.endUtc,
      durationSeconds: validation.durationSeconds,
      localDate: validation.localDate.isNotEmpty ? validation.localDate : localTodayDate,
      note: _normalizedNote(draft.note),
      createdAtUtc: now,
      overlapSpans: validation.overlaps
          .map((hit) => hit.span)
          .toList(growable: false),
      overlapPolicy: draft.overlapPolicy,
    );

    final existed = ledger.recordById(record.recordId) != null;
    final next = record.withRevision(ExecutionRevision(
      revisionId: newExecutionId('rev'),
      atUtc: now,
      action: 'manualAdd',
      note: '新增手工补记 ${formatEffortDuration(Duration(seconds: validation.durationSeconds))}',
      snapshot: existed ? record.toJson() : null,
    )).copyWith(manualEntries: <ManualEntry>[...record.manualEntries, entry]);

    if (existed) {
      ledger.replaceRecord(next);
    } else {
      ledger.addRecord(next);
    }
    final saved = await _persistLedger();
    _notice = saved ? _manualEntryMessage(entry) : '已更新内存，但执行记录保存失败，请检查磁盘';
    _notify();
    return ManualEntryOutcome(
      ok: saved,
      message: _notice!,
      entry: entry,
      recordId: next.recordId,
      overlaps: validation.overlaps,
      overlapTotal: validation.overlapTotal,
      overlapExcluded: draft.overlapPolicy == OverlapPolicy.excludeOverlap
          ? validation.overlapTotal
          : Duration.zero,
    );
  }

  /// 删除一条手工补记（保留修订快照，可撤销）。
  Future<TimerActionResult> removeManualEntry(
    String recordId,
    String entryId,
  ) async {
    if (!await _ensureWritable('删除补记')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final record = ledger.recordById(recordId);
    if (record == null) {
      return const TimerActionResult(ok: false, message: '找不到这条执行记录');
    }
    if (_active?.recordId == recordId) {
      return const TimerActionResult(ok: false, message: '正在计时的记录不能删除补记，请先停止计时');
    }
    final remaining = record.manualEntries
        .where((e) => e.entryId != entryId)
        .toList(growable: false);
    if (remaining.length == record.manualEntries.length) {
      return const TimerActionResult(ok: false, message: '找不到这条补记');
    }
    final next = record
        .withRevision(ExecutionRevision(
          revisionId: newExecutionId('rev'),
          atUtc: clock.nowUtc,
          action: 'manualRemove',
          note: '删除手工补记',
          snapshot: record.toJson(),
        ))
        .copyWith(manualEntries: remaining);
    ledger.replaceRecord(next);
    final saved = await _persistLedger();
    _notice = saved ? '已删除补记；可用“撤销”恢复' : '已更新内存，但执行记录保存失败';
    _notify();
    return TimerActionResult(ok: saved, message: _notice!);
  }

  /// 软删除/恢复整条执行记录（保留事实与修订历史，统计默认排除已删除）。
  Future<TimerActionResult> setRecordDeleted(
    String recordId, {
    required bool deleted,
  }) async {
    if (!await _ensureWritable('删除执行记录')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    if (deleted && _active?.recordId == recordId) {
      return const TimerActionResult(ok: false, message: '正在计时的记录不能删除，请先停止计时');
    }
    final next = ledger.setRecordDeleted(
      recordId,
      deleted: deleted,
      atUtc: clock.nowUtc,
      reason: '用户删除',
      note: deleted ? '用户删除执行记录' : '用户恢复执行记录',
    );
    if (next == null) {
      return const TimerActionResult(ok: false, message: '找不到这条执行记录，或状态已经相同');
    }
    final saved = await _persistLedger();
    _notice = saved
        ? (deleted ? '已删除执行记录（保留历史，可撤销；统计不再计入）' : '已恢复执行记录')
        : '已更新内存，但执行记录保存失败';
    _notify();
    return TimerActionResult(ok: saved, message: _notice!);
  }

  /// 撤销最近一次带快照的修订（补记增删/记录删除恢复）。
  Future<TimerActionResult> revertRecord(String recordId) async {
    if (!await _ensureWritable('撤销修订')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final next = ledger.revertRecord(recordId, atUtc: clock.nowUtc);
    if (next == null) {
      return const TimerActionResult(ok: false, message: '没有可撤销的修订');
    }
    final saved = await _persistLedger();
    _notice = saved ? '已撤销最近的修改' : '已更新内存，但执行记录保存失败';
    _notify();
    return TimerActionResult(ok: saved, message: _notice!);
  }

  // -------------------------------------------------------------- 完成事件

  /// 记录完成事件（完成时间取事件时间，不是报告读取时间）。
  ///
  /// 注意：这里**只记事件**，不会写实际耗时、不会停止计时。
  /// [atUtc] 由“到期自动完成”传入响应窗口结束时刻；普通完成取当前时钟。
  Future<TimerActionResult> recordTaskCompletion({
    required String conversationId,
    required String taskId,
    required String planVersionId,
    required int planRevision,
    DateTime? atUtc,
  }) async {
    if (!await _ensureWritable('记录完成')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final event = ledger.recordCompletion(
      conversationId: conversationId,
      taskId: taskId,
      planVersionId: planVersionId,
      planRevision: planRevision,
      completedAtUtc: atUtc ?? clock.nowUtc,
    );
    if (event == null) {
      return const TimerActionResult(ok: false, message: '任务 id 为空，未记录完成事件');
    }
    final saved = await _persistLedger();
    return TimerActionResult(
      ok: saved,
      message: saved ? '已记录完成事件' : '已记录完成事件，但保存失败，请检查磁盘',
    );
  }

  /// 撤销完成事件（不删除任何执行记录）。返回是否找到可撤销的完成事件。
  Future<TimerActionResult> undoTaskCompletion(String taskId) async {
    if (!await _ensureWritable('撤销完成')) {
      return TimerActionResult(ok: false, message: _readOnlyNotice ?? '只读实例');
    }
    final ok = ledger.undoCompletion(taskId, clock.nowUtc);
    if (!ok) {
      return const TimerActionResult(ok: false, message: '没有可撤销的完成事件');
    }
    await _persistLedger();
    return const TimerActionResult(ok: true, message: '已撤销完成事件（执行记录保留）');
  }

  // -------------------------------------------------------------- 生命周期

  /// 正常关闭：保存检查点并暂停活动计时，再释放实例锁。重开应用后可继续或确认。
  Future<void> shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    _uiTimer?.cancel();
    _uiTimer = null;
    if (_loaded && !_readOnly && _active != null) {
      if (_phase == TimerPhase.running) {
        final closed = _closeOpenInterval();
        if (closed != null) _sessionClosed += closed;
        _phase = TimerPhase.paused;
        _openStartUtc = null;
        _openStartMonotonic = null;
        await _persistLedger();
      }
      _active = _copyActive(phase: TimerPhase.paused, pausedAt: clock.nowUtc);
      await _writeCheckpointQuietly();
    }
    await store.close();
    _loaded = false;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _uiTimer?.cancel();
    _uiTimer = null;
    // dispose 不能 await：异步完成“暂停 + 检查点 + 释放实例锁”。
    unawaited(shutdown());
    super.dispose();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    _notify();
  }

  // ---------------------------------------------------------------- internals

  Future<bool> _ensureWritable(String action) async {
    if (!_loaded) await load();
    if (_readOnly) {
      _notice = _readOnlyNotice ?? '只读实例不能$action';
      _notify();
      return false;
    }
    return true;
  }

  Future<bool> _persistLedger() async {
    if (_readOnly) return false;
    try {
      await store.persistLedger();
      return true;
    } on ExecutionReadOnlyException catch (e) {
      _readOnly = true;
      _readOnlyNotice = e.message;
      return false;
    } on ExecutionStoreException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _writeCheckpointQuietly() async {
    final active = _active;
    if (active == null) return false;
    final checkpoint = TimerCheckpoint(
      recordId: active.recordId,
      conversationId: active.conversationId,
      taskId: active.taskId,
      taskName: active.taskName,
      planVersionId: active.planVersionId,
      planRevision: active.planRevision,
      estimateBaselineHours:
          ledger.recordById(active.recordId)?.estimateBaselineHours,
      phase: _phase,
      sessionStartedAtUtc: active.sessionStartedAtUtc,
      checkpointUtc: clock.nowUtc,
      openIntervalStartUtc: _phase == TimerPhase.running ? _openStartUtc : null,
      timeZoneName: ledger.recordById(active.recordId)?.timeZoneName ?? '',
      timeZoneOffsetMinutes:
          ledger.recordById(active.recordId)?.timeZoneOffsetMinutes ?? 0,
    );
    try {
      await store.saveCheckpoint(checkpoint);
      return true;
    } on ExecutionReadOnlyException catch (e) {
      _readOnly = true;
      _readOnlyNotice = e.message;
      return false;
    } on ExecutionStoreException catch (e) {
      // 检查点写失败不停止计时，但必须让用户知道“最大可能丢失”变大。
      _notice = '${e.message}；计时仍在进行，但崩溃时可能丢失更多时间';
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 关闭当前未闭区间并写进记录；返回本段时长（闭区间失败也返回估算）。
  ///
  /// [atUtc] 非空时把区间结束截断在该时刻（有效截止点）：只结算截止点之前真正
  /// 计时的部分，晚到的等待时间不计入。
  Duration? _closeOpenInterval({DateTime? atUtc}) {
    final active = _active;
    final startUtc = _openStartUtc;
    final startMono = _openStartMonotonic;
    if (active == null || startUtc == null || startMono == null) return null;
    var duration = clock.monotonic - startMono;
    if (duration.isNegative) duration = Duration.zero;
    if (duration > maxSingleInterval) duration = maxSingleInterval;
    var endUtc = startUtc.add(duration);
    if (atUtc != null && atUtc.isAfter(startUtc) && atUtc.isBefore(endUtc)) {
      endUtc = atUtc.toUtc();
      duration = endUtc.difference(startUtc);
    }
    if (duration.isNegative) {
      duration = Duration.zero;
      endUtc = startUtc;
    }
    final record = ledger.recordById(active.recordId);
    if (record != null) {
      final interval = ExecutionInterval(
        startUtc: startUtc,
        endUtc: endUtc,
        source: IntervalSource.timer,
      );
      ledger.replaceRecord(record.copyWith(
        intervals: <ExecutionInterval>[...record.intervals, interval],
        state: record.hasOpenCorrections
            ? ExecutionRecordState.pendingCorrection
            : ExecutionRecordState.confirmed,
      ));
    }
    return duration;
  }

  /// 检测到不确定时间：关闭到上次 tick 的区间，剩余部分进待校正并暂停。
  Future<TimerActionResult> _splitForUncertainty({
    required DateTime nowUtc,
    required Duration nowMonotonic,
    required Duration monoDelta,
    required Duration wallDelta,
    required CorrectionReason reason,
    required bool intervalTooLong,
  }) async {
    final active = _active;
    if (active == null) {
      return const TimerActionResult(ok: false, message: '当前没有活动计时');
    }
    final openStartUtc = _openStartUtc;
    final openStartMono = _openStartMonotonic;
    final lastTickUtc = _lastTickUtc ?? openStartUtc ?? nowUtc;
    final lastTickMono = _lastTickMonotonic ?? openStartMono ?? nowMonotonic;

    if (openStartUtc != null && openStartMono != null) {
      var duration = lastTickMono - openStartMono;
      if (duration.isNegative) duration = Duration.zero;
      if (duration > maxSingleInterval) duration = maxSingleInterval;
      final record = ledger.recordById(active.recordId);
      if (record != null) {
        ledger.replaceRecord(record.copyWith(
          intervals: <ExecutionInterval>[
            ...record.intervals,
            ExecutionInterval(
              startUtc: openStartUtc,
              endUtc: openStartUtc.add(duration),
              source: IntervalSource.timer,
              note: '检测到${_reasonLabel(reason)}，截断到检查点',
            ),
          ],
        ));
      }
      _sessionClosed += duration;
    }

    final record = ledger.recordById(active.recordId);
    if (record != null) {
      final correction = PendingCorrection(
        correctionId: newExecutionId('cor'),
        observedStartUtc: lastTickUtc,
        observedEndUtc: nowUtc,
        wallDeltaSeconds: wallDelta.inSeconds,
        monotonicDeltaSeconds: monoDelta.inSeconds,
        reason: reason,
        detectedAtUtc: nowUtc,
      );
      ledger.replaceRecord(record.copyWith(
        pendingCorrections: <PendingCorrection>[
          ...record.pendingCorrections,
          correction,
        ],
        state: ExecutionRecordState.pendingCorrection,
      ));
    }

    _phase = TimerPhase.paused;
    _openStartUtc = null;
    _openStartMonotonic = null;
    _active = _copyActive(phase: TimerPhase.paused, pausedAt: nowUtc);
    final saved = await _persistLedger();
    await _writeCheckpointQuietly();
    _notice = '检测到${_reasonLabel(reason)}：已暂停计时并标记 '
        '${formatEffortDuration(pendingCorrectionWall(wallDelta))} 为待校正；'
        '这段时间不会自动算成工作，请确认是否计入。'
        '${saved ? '' : '（执行记录保存失败，请检查磁盘）'}';
    _notify();
    return TimerActionResult(
      ok: saved,
      message: _notice!,
      confirmed: _sessionClosed,
    );
  }

  String _reasonLabel(CorrectionReason reason) => switch (reason) {
        CorrectionReason.clockJump => '系统时间异常或睡眠/锁屏',
        CorrectionReason.suspend => '睡眠/锁屏等离开',
        CorrectionReason.crashRecovery => '上次异常退出',
        CorrectionReason.manual => '不确定的时间区间',
      };

  /// 恢复检查点：检查点之前的时间计入，之后的时间进待校正（不默认算工作）。
  Future<void> _recoverFromCheckpoint(TimerCheckpoint checkpoint) async {
    var record = ledger.recordById(checkpoint.recordId);
    if (record == null) {
      record = ExecutionRecord.start(
        recordId: checkpoint.recordId,
        conversationId: checkpoint.conversationId,
        taskId: checkpoint.taskId,
        taskName: checkpoint.taskName,
        planVersionId: checkpoint.planVersionId,
        planRevision: checkpoint.planRevision,
        startedAtUtc: checkpoint.sessionStartedAtUtc,
        timeZoneName: checkpoint.timeZoneName,
        timeZoneOffsetMinutes: checkpoint.timeZoneOffsetMinutes,
        estimateBaselineHours: checkpoint.estimateBaselineHours,
      );
      ledger.addRecord(record);
    }

    if (checkpoint.phase == TimerPhase.running) {
      final nowUtc = clock.nowUtc;
      final openStartUtc = checkpoint.openIntervalStartUtc ??
          checkpoint.sessionStartedAtUtc;
      final checkpointUtc = checkpoint.checkpointUtc;
      var closedDuration = checkpointUtc.difference(openStartUtc);
      if (closedDuration.isNegative) closedDuration = Duration.zero;
      if (closedDuration > maxSingleInterval) closedDuration = maxSingleInterval;

      final intervals = <ExecutionInterval>[...record.intervals];
      if (closedDuration > Duration.zero) {
        intervals.add(ExecutionInterval(
          startUtc: openStartUtc,
          endUtc: openStartUtc.add(closedDuration),
          source: IntervalSource.timer,
          note: '崩溃恢复到检查点',
        ));
      }
      final wallDelta = nowUtc.difference(checkpointUtc);
      final correction = PendingCorrection(
        correctionId: newExecutionId('cor'),
        observedStartUtc: checkpointUtc,
        observedEndUtc: nowUtc,
        wallDeltaSeconds: wallDelta.inSeconds,
        monotonicDeltaSeconds: 0,
        reason: CorrectionReason.crashRecovery,
        detectedAtUtc: nowUtc,
      );
      final next = record.copyWith(
        intervals: intervals,
        pendingCorrections: <PendingCorrection>[
          ...record.pendingCorrections,
          correction,
        ],
        state: ExecutionRecordState.pendingCorrection,
      );
      ledger.replaceRecord(next);
      record = next;
      await _persistLedger();
      _sessionClosed = _closedSessionDuration(next, checkpoint.sessionStartedAtUtc);
      _active = ActiveTimer(
        recordId: record.recordId,
        conversationId: record.conversationId,
        taskId: record.taskId,
        taskName: record.taskName,
        planVersionId: record.planVersionId,
        planRevision: record.planRevision,
        sessionStartedAtUtc: checkpoint.sessionStartedAtUtc,
        phase: TimerPhase.paused,
        pausedAtUtc: nowUtc,
      );
      _phase = TimerPhase.paused;
      _lastTickUtc = nowUtc;
      _lastTickMonotonic = clock.monotonic;
      _recoveryNotice = '上次计时未正常停止：检查点之前的 ${formatEffortDuration(closedDuration)} '
          '已计入；从检查点到重启的 ${formatEffortDuration(pendingCorrectionWall(wallDelta))} '
          '标记为待校正（不会自动算成工作）。';
      await _writeCheckpointQuietly();
    } else {
      // 上次是暂停状态：恢复成暂停的活动计时，让用户选择继续或停止确认。
      _sessionClosed = _closedSessionDuration(record, checkpoint.sessionStartedAtUtc);
      _active = ActiveTimer(
        recordId: record.recordId,
        conversationId: record.conversationId,
        taskId: record.taskId,
        taskName: record.taskName,
        planVersionId: record.planVersionId,
        planRevision: record.planRevision,
        sessionStartedAtUtc: checkpoint.sessionStartedAtUtc,
        phase: TimerPhase.paused,
        pausedAtUtc: clock.nowUtc,
      );
      _phase = TimerPhase.paused;
      _lastTickUtc = clock.nowUtc;
      _lastTickMonotonic = clock.monotonic;
      _recoveryNotice = '上次计时处于暂停状态，已恢复；可以继续计时或停止确认。';
      await _writeCheckpointQuietly();
    }
  }

  /// 本次会话已闭区间时长（按记录重算；用于恢复后状态条显示）。
  Duration _closedSessionDuration(ExecutionRecord record, DateTime sessionStartUtc) {
    var micros = 0;
    for (final interval in record.intervals) {
      if (!interval.isValid) continue;
      if (interval.startUtc.isBefore(sessionStartUtc)) continue;
      micros += interval.duration.inMicroseconds;
    }
    for (final correction in record.pendingCorrections) {
      final decided = correction.decidedSeconds;
      if (decided == null || decided <= 0) continue;
      if (correction.detectedAtUtc.isBefore(sessionStartUtc)) continue;
      micros += decided * Duration.microsecondsPerSecond;
    }
    return Duration(microseconds: micros);
  }

  ActiveTimer _copyActive({required TimerPhase phase, DateTime? pausedAt}) {
    final active = _active!;
    return ActiveTimer(
      recordId: active.recordId,
      conversationId: active.conversationId,
      taskId: active.taskId,
      taskName: active.taskName,
      planVersionId: active.planVersionId,
      planRevision: active.planRevision,
      sessionStartedAtUtc: active.sessionStartedAtUtc,
      phase: phase,
      openIntervalStartUtc: phase == TimerPhase.running ? _openStartUtc : null,
      pausedAtUtc: phase == TimerPhase.paused ? (pausedAt ?? clock.nowUtc) : null,
    );
  }

  ExecutionRecord? _recordForCorrection(String correctionId) {
    for (final record in ledger.activeRecords) {
      if (record.pendingCorrections.any((c) => c.correctionId == correctionId)) {
        return record;
      }
    }
    return null;
  }

  ExecutionRecord _recordForManualEntry(ExecutionTaskRef ref) {
    // 优先挂到当前活动记录（同任务），其次挂到该任务最近一条未删除记录。
    final active = _active;
    if (active != null &&
        active.taskId == ref.taskId &&
        active.conversationId == ref.conversationId) {
      final record = ledger.recordById(active.recordId);
      if (record != null) return record;
    }
    final existing = ledger
        .recordsForTask(ref.taskId)
        .where((r) => r.conversationId == ref.conversationId)
        .toList(growable: false);
    if (existing.isNotEmpty) return existing.last;
    final now = clock.nowUtc;
    return ExecutionRecord.start(
      recordId: newExecutionId('exe'),
      conversationId: ref.conversationId,
      taskId: ref.taskId,
      taskName: ref.taskName,
      lineageRootId: ref.lineageRootId,
      planVersionId: ref.planVersionId,
      planRevision: ref.planRevision,
      startedAtUtc: now,
      timeZoneName: localTime.timeZoneLabel,
      timeZoneOffsetMinutes: localTime.offsetMinutesAt(now),
      estimateBaselineHours: ref.effectiveEstimateHours,
    );
  }

  String _manualEntryMessage(ManualEntry entry) {
    final base = '已补记 ${formatEffortDuration(Duration(seconds: entry.durationSeconds))}';
    if (!entry.hasOverlap) return '$base（${entry.mode == ManualEntryMode.duration ? '仅时长，无法检测重叠' : '未与已有记录重叠'}）';
    if (entry.overlapPolicy == OverlapPolicy.includeOverlap) {
      return '$base；已按你的选择计入重叠 '
          '${formatEffortDuration(Duration(seconds: entry.overlapSeconds))}，报告会标注该口径';
    }
    return '$base；与已有记录重叠 '
        '${formatEffortDuration(Duration(seconds: entry.overlapSeconds))} 默认未计入，报告会标注口径';
  }

  String? _normalizedNote(String? note) {
    final text = note?.trim() ?? '';
    if (text.isEmpty) return null;
    return text.length > kMaxManualNoteLength
        ? text.substring(0, kMaxManualNoteLength)
        : text;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}

/// 待校正墙钟跨度的展示时长（负值按 0，避免“-3 分钟”这种文案）。
Duration pendingCorrectionWall(Duration wallDelta) =>
    wallDelta.isNegative ? Duration.zero : wallDelta;
