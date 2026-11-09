// 任务执行截止与提醒的状态机（0.5.0 任务 13）。
//
// 职责：把“开始执行 → 有效截止 → 到点待处理 → 第一次提醒 → 第二次提醒 → 到期
// 自动完成”整条链路接到既有入口上，并把阶段/截止/两次投递/完成结果持久化。
//
// 不变量（用测试锁住，不要为了“方便”改）：
//   * 有效截止只能来自当前生效甘特排程的最后一段结束时刻（由注入的
//     [resolveTarget] 解析）。没有具体时刻就不安排提醒，绝不猜午夜。
//   * 一次执行只有一个身份 [ExecutionDeadlineSession.executionId]；暂停/继续/延长
//     恢复都不重发“已开始”，也不重复创建执行记录。
//   * 提醒只有在**系统接受**或**前台真实显示**时才记“已投递”，响应窗口从投递时刻
//     起算；未投递的提醒在应用恢复后补发并留足完整窗口。
//   * 自动完成必须同时满足：仍待处理（任务未完成、未删除）、第二次投递的期限版本
//     仍是当前版本、响应窗口已过；并且只提交一次完成命令。
//   * 等待期间（第一次提醒到自动完成）绝不产生执行区间。
//
// 所有时间读取走注入的 [EffortClock]，测试可用假时钟验证 15:59:59/16:00/…/16:10。

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'effort_clock.dart';
import 'effort_stats.dart';
import 'execution_deadline.dart';
import 'execution_deadline_store.dart';
import 'execution_models.dart';
import 'execution_notification.dart';
import 'timer_controller.dart';

/// 完成命令的结果（由 AppController 注入）。
class ExecutionCompletionOutcome {
  const ExecutionCompletionOutcome({
    required this.ok,
    required this.message,
    this.alreadyDone = false,
  });

  final bool ok;
  final String message;

  /// 任务在提交前已经是完成状态（幂等：不重复记录完成事件/释放依赖）。
  final bool alreadyDone;
}

/// 解析出的任务执行目标；找不到任务/会话时返回 null。
typedef ExecutionDeadlineResolver = Future<ExecutionDeadlineTarget?> Function(
  String conversationId,
  String taskId,
);

/// 执行截止控制器。
class ExecutionDeadlineController extends ChangeNotifier {
  ExecutionDeadlineController({
    required this.timer,
    required this.store,
    required this.clock,
    required this.localTime,
    required this.notifications,
    required this.resolveTarget,
    required this.taskRefFor,
    required this.completeTask,
    required this.previewExtensionFor,
    required this.applyExtensionFor,
    required this.openTask,
    bool Function()? isAppVisible,
    this.onNotice,
    this.secondReminderDelay = const Duration(minutes: 5),
    this.autoCompleteDelay = const Duration(minutes: 5),
    this.deliveryRetryInterval = const Duration(seconds: 15),
    this.uiTickInterval = const Duration(seconds: 1),
    this.autoTick = true,
  }) : isAppVisible = isAppVisible ?? (() => false);

  final TimerController timer;
  final ExecutionDeadlineStore store;
  final EffortClock clock;
  final EffortLocalTime localTime;
  final ExecutionNotificationPort notifications;
  final ExecutionDeadlineResolver resolveTarget;
  final Future<ExecutionTaskRef?> Function(String conversationId, String taskId)
      taskRefFor;
  final Future<ExecutionCompletionOutcome> Function(
    String conversationId,
    String taskId,
    DateTime atUtc,
    String source,
  ) completeTask;
  final Future<ExecutionExtensionPreview> Function(
    String conversationId,
    String taskId,
    DateTime newEndUtc,
  ) previewExtensionFor;
  final Future<bool> Function(
    String conversationId,
    String taskId,
    DateTime newEndUtc,
  ) applyExtensionFor;
  final Future<void> Function(String conversationId, String taskId) openTask;
  final bool Function() isAppVisible;
  final void Function(String message, {bool error})? onNotice;

  /// 第一次提醒到第二次提醒的间隔（生产 5 分钟）。
  final Duration secondReminderDelay;

  /// 第二次提醒到自动完成的响应窗口（生产 5 分钟）。
  final Duration autoCompleteDelay;

  /// 投递失败后的最小重试间隔（避免每秒骚扰系统；测试可传 Duration.zero）。
  final Duration deliveryRetryInterval;

  final Duration uiTickInterval;
  final bool autoTick;

  Timer? _tickTimer;
  bool _disposed = false;
  bool _loaded = false;
  bool _readOnly = false;

  /// 所有会话（活跃 + 历史，历史用于旧通知重放的幂等判定）。
  final List<ExecutionDeadlineSession> _sessions = <ExecutionDeadlineSession>[];

  /// 前台等价操作待确认投递：executionId → 通知类型（deadline/second）。
  final Map<String, String> _foregroundPending = <String, String>{};

  /// 投递失败后的下次允许尝试时刻（executionId|kind）。
  final Map<String, DateTime> _nextAttemptAt = <String, DateTime>{};

  /// 内部操作互斥：延长确认与自动完成只能有一个有效（另一个得到“当前正在处理”）。
  bool _busy = false;

  /// 正在“结束任务”的执行身份：计时器停止事件不能把它当成“只停止计时”。
  final Set<String> _finishing = <String>{};

  /// 延长确认后恢复计时的任务（计时器新记录不重发“已开始”）。
  ({String conversationId, String taskId})? _resuming;

  /// 完成/取消正在处理中的身份（完成回调不再重复取消）。
  final Set<String> _completionInFlight = <String>{};

  String? _notice;
  String? _errorMessage;
  String? _persistError;
  String? _notificationStatus;
  String? _lastActiveSignature;
  bool _handlingTimerChange = false;

  /// UI 请求打开“延长截止”对话框时读取（取走即清空，避免重复弹出）。
  ExecutionDeadlineSession? _extendRequest;

  /// 最近一次动作（供 UI 判断是否需要打开浮窗等）。
  ExecutionNotificationAction? _lastAction;

  // ---------------------------------------------------------------- 只读属性

  bool get loaded => _loaded;
  bool get readOnly => _readOnly;
  bool get busy => _busy;

  /// 当前注入时钟的 UTC 时刻（UI 计算默认新截止用）。
  DateTime get nowUtc => clock.nowUtc;

  /// “延长时间”对话框的默认候选新截止。
  ///
  /// 取当前有效截止 + 30 分钟，且至少晚于当前时刻 5 分钟，并对齐到下一个整 5 分钟；
  /// 用户仍可在对话框里选择其它选项。这里只给候选，不写任何数据。
  DateTime nextExtensionCandidate(ExecutionDeadlineSession session) {
    final now = clock.nowUtc;
    final base = session.deadlineUtc ?? now;
    var candidate = base.add(const Duration(minutes: 30));
    final earliest = now.add(const Duration(minutes: 5));
    if (candidate.isBefore(earliest)) candidate = earliest;
    const step = Duration(minutes: 5);
    final ms = candidate.millisecondsSinceEpoch;
    final stepMs = step.inMilliseconds;
    final aligned = ((ms + stepMs - 1) ~/ stepMs) * stepMs;
    return DateTime.fromMillisecondsSinceEpoch(aligned, isUtc: true);
  }

  /// 最近一次操作提示。
  String? get notice => _notice;

  String? get errorMessage => _errorMessage;

  /// 原生通知准备结果的一句话说明（null = 未探测/正常）。
  String? get notificationStatus => _notificationStatus;

  /// 持久化失败提示（写盘失败不丢内存状态，下一次操作/轮询重试）。
  String? get persistError => _persistError;

  /// 全部会话（含历史）；UI 用 [activeSessions] 过滤。
  List<ExecutionDeadlineSession> get sessions =>
      List<ExecutionDeadlineSession>.unmodifiable(_sessions);

  List<ExecutionDeadlineSession> get activeSessions => _sessions
      .where((s) => s.isActive)
      .toList(growable: false);

  /// 当前阶段是否已有“待处理/二次提醒”的会话（顶部状态条用）。
  bool get hasPendingSession => _sessions.any((s) =>
      s.stage == ExecutionDeadlineStage.pending ||
      s.stage == ExecutionDeadlineStage.secondReminder);

  /// 顶部/浮窗优先展示的会话。
  ///
  /// 优先当前正在计时/暂停的任务；否则优先待处理/二次提醒；再否则取截止最近的
  /// 已安排会话。没有活跃会话返回 null。
  ExecutionDeadlineSession? get primarySession {
    final active = timer.active;
    if (active != null) {
      for (final s in _sessions) {
        if (!s.isActive) continue;
        if (s.conversationId == active.conversationId &&
            s.taskId == active.taskId) {
          return s;
        }
      }
    }
    ExecutionDeadlineSession? pending;
    for (final s in activeSessions) {
      if (s.stage == ExecutionDeadlineStage.secondReminder) return s;
      if (s.stage == ExecutionDeadlineStage.pending) {
        pending ??= s;
      }
    }
    if (pending != null) return pending;
    final scheduled = activeSessions
        .where((s) => s.stage == ExecutionDeadlineStage.scheduled && s.hasDeadline)
        .toList()
      ..sort((a, b) => a.deadlineUtc!.compareTo(b.deadlineUtc!));
    if (scheduled.isNotEmpty) return scheduled.first;
    return activeSessions.isEmpty ? null : activeSessions.first;
  }

  /// 该执行身份最近一次会话（历史也返回）。
  ExecutionDeadlineSession? sessionById(String executionId) {
    for (var i = _sessions.length - 1; i >= 0; i--) {
      if (_sessions[i].executionId == executionId) return _sessions[i];
    }
    return null;
  }

  /// 某个任务的活跃截止会话（浮窗按任务显示状态用）。
  ExecutionDeadlineSession? sessionForTask(
      String conversationId, String taskId) {
    for (var i = _sessions.length - 1; i >= 0; i--) {
      final s = _sessions[i];
      if (!s.isActive) continue;
      if (s.conversationId == conversationId && s.taskId == taskId) return s;
    }
    return null;
  }

  /// UI 取走“延长截止”请求。
  ExecutionDeadlineSession? takeExtendRequest() {
    final request = _extendRequest;
    _extendRequest = null;
    return request;
  }

  /// 最近一次通知动作（调试/测试）。
  ExecutionNotificationAction? get lastAction => _lastAction;

  /// 全部投递记录（按会话顺序展开；测试断言通知次数用）。
  List<ExecutionNotificationDelivery> get deliveries => <ExecutionNotificationDelivery>[
        for (final s in _sessions) ...s.deliveries,
      ];

  int deliveryCount(String kind, {bool? accepted}) => deliveries
      .where((d) =>
          d.kind == kind && (accepted == null || d.accepted == accepted))
      .length;

  /// 曾被“到期自动完成”的任务 id 集合（只读、不可变）。
  ///
  /// 语义：集合内出现某 taskId，表示执行账本里存在至少一次 `completionSource == 'auto'`
  /// 的已完成截止会话（到期自动完成）；手动结束/人工勾选、只停止计时、已取消的会话都
  /// 不计入。旧数据没有 completionSource 字段时视为 manual，不误报。这里按任务 id
  /// 汇总（不区分会话），供执行回顾展示“到期自动完成”徽标使用。
  Set<String> get autoCompletedTaskIds => Set<String>.unmodifiable(<String>{
        for (final session in _sessions)
          if (session.stage == ExecutionDeadlineStage.completed &&
              session.completionSource == 'auto')
            session.taskId,
      });

  // ---------------------------------------------------------------- 生命周期

  /// 读取持久化会话并准备原生通知；永不抛异常。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prep = notifications.prepare();
    if (!prep.ok) {
      _notificationStatus =
          '系统可操作通知不可用（${prep.errorKind ?? 'unknown'}：${prep.error ?? '未就绪'}）；'
          '到期提醒将改为应用内等价操作。';
    }
    final result = await store.load();
    _readOnly = result.readOnly;
    if (result.notice != null && result.notice!.trim().isNotEmpty) {
      _notice = result.notice;
    }
    _sessions
      ..clear()
      ..addAll(result.sessions);
    if (!_readOnly) {
      _sessions.sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    }
    timer.addListener(_onTimerChanged);
    _lastActiveSignature = _activeSignature();
    if (autoTick && !_disposed) {
      _tickTimer = Timer.periodic(uiTickInterval, (_) => unawaited(tick()));
    }
    // 启动即校核一次：错过定时器/重启后的补发与补做都靠这里收敛。
    await _bindRestoredTimer();
    await tick();
    _notify();
  }

  /// 正常关闭：停止轮询并把当前阶段/投递状态落盘。重启后按持久状态恢复。
  ///
  /// 不在这里“补做完成”或补发提醒：完全退出时没有常驻服务可保证送达，
  /// 由下次启动的 [tick] 按持久状态收敛。
  Future<void> shutdown() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    await _persistQuietly();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _tickTimer?.cancel();
    _tickTimer = null;
    timer.removeListener(_onTimerChanged);
    unawaited(_persistQuietly());
    super.dispose();
  }

  /// 应用可见性变化（最小化/恢复）时由窗口/壳层调用。
  Future<void> handleAppVisibilityChanged() async {
    if (_disposed) return;
    await tick();
  }

  /// 锁屏/睡眠离开：不在离开期间自动完成；恢复后按持久状态补发/补做。
  Future<void> handleAppSuspended() async {
    // 离开期间不推进响应窗口（时钟仍在走，但投递机会没有增加）；
    // 恢复时 tick 会重新核对并补发。
  }

  /// 应用恢复：立即校核一次（补发未投递提醒、补做到期完成）。
  Future<void> handleAppResumed() async {
    if (_disposed) return;
    await tick();
  }

  /// 用户完成状态发生变化（人工勾选完成/撤销完成/结束命令之外的变化）。
  ///
  /// 由 AppController 在计划提交后回调：完成 → 取消剩余提醒；撤销完成不复活旧会话。
  Future<void> onTaskCompletionChanged(
    String conversationId,
    String taskId, {
    required bool done,
    String source = 'manual',
  }) async {
    if (_disposed || !done) return;
    final session = sessionForTask(conversationId, taskId);
    if (session == null) return;
    // 结束/自动完成命令自己会写最终阶段，避免重复“取消”。
    if (_finishing.contains(session.executionId) ||
        _completionInFlight.contains(session.executionId)) {
      return;
    }
    final index = _indexOf(session.executionId);
    if (index < 0) return;
    _sessions[index] = session.copyWith(
      stage: ExecutionDeadlineStage.completed,
      completedAtUtc: clock.nowUtc,
      completionSource: source,
      completionError: null,
      clearCompletionError: true,
      clearResponseWindow: true,
      notice: '任务已完成，已取消剩余到期提醒',
    );
    _foregroundPending.remove(session.executionId);
    await _persistQuietly();
    _notify();
  }

  // ---------------------------------------------------------------- 计时器事件

  String _activeSignature() {
    final active = timer.active;
    if (active == null) return 'idle';
    return '${active.recordId}|${timer.phase.name}';
  }

  void _onTimerChanged() {
    if (_disposed || _handlingTimerChange) return;
    _handlingTimerChange = true;
    final previous = _lastActiveSignature ?? 'idle';
    _lastActiveSignature = _activeSignature();
    unawaited(_handleTimerChanged(previous).whenComplete(() {
      _handlingTimerChange = false;
    }));
  }

  Future<void> _handleTimerChanged(String previousSignature) async {
    if (_disposed) return;
    final active = timer.active;
    if (active == null) {
      // 活动计时结束：若不是内部结算/结束命令，视为“只停止计时”→ 撤销未到期提醒。
      final previousRecordId = previousSignature.split('|').first;
      final session = _sessionByRecordId(previousRecordId);
      if (session != null &&
          session.stage == ExecutionDeadlineStage.scheduled &&
          !_finishing.contains(session.executionId) &&
          !_busy) {
        final index = _indexOf(session.executionId);
        if (index >= 0) {
          _sessions[index] = session.copyWith(
            stage: ExecutionDeadlineStage.cancelled,
            clearResponseWindow: true,
            notice: '已停止计时；任务未完成，该次未到期提醒已撤销',
          );
          _notice = '已停止计时；任务未完成，未到期提醒已撤销';
          await _persistQuietly();
          _notify();
        }
      }
      return;
    }

    final resuming = _resuming;
    if (resuming != null &&
        resuming.conversationId == active.conversationId &&
        resuming.taskId == active.taskId) {
      _resuming = null;
      await _attachRecordToSession(active);
      await _persistQuietly();
      _notify();
      return;
    }

    // 已有同一任务的活跃会话（重新开始同一任务）→ 不重复创建、不重发开始通知。
    final existing = sessionForTask(active.conversationId, active.taskId);
    if (existing != null) {
      await _attachRecordToSession(active);
      await _persistQuietly();
      _notify();
      return;
    }

    await _createSessionForActive(active, notifyStart: true);
  }

  /// 计时器恢复/首次启动时把活动计时绑到已有会话（不重发“已开始”）。
  Future<void> _bindRestoredTimer() async {
    final active = timer.active;
    if (active == null) return;
    final existing =
        _sessionByRecordId(active.recordId) ??
            sessionForTask(active.conversationId, active.taskId);
    if (existing != null) {
      await _attachRecordToSession(active);
    } else {
      // 应用启动时已有一个恢复出来的活动计时，但没有截止会话：
      // 补建会话但不发“已开始”（后台恢复不重发）。
      await _createSessionForActive(active, notifyStart: false);
    }
  }

  Future<void> _attachRecordToSession(ActiveTimer active) async {
    final session =
        _sessionByRecordId(active.recordId) ??
            sessionForTask(active.conversationId, active.taskId);
    if (session == null) return;
    if (session.recordIds.contains(active.recordId)) return;
    final index = _indexOf(session.executionId);
    if (index < 0) return;
    _sessions[index] = session.copyWith(
      recordIds: <String>[...session.recordIds, active.recordId],
    );
  }

  Future<void> _createSessionForActive(
    ActiveTimer active, {
    required bool notifyStart,
  }) async {
    final target =
        await resolveTarget(active.conversationId, active.taskId);
    final now = clock.nowUtc;
    final session = ExecutionDeadlineSession(
      executionId: newExecutionId('dl'),
      conversationId: active.conversationId,
      taskId: active.taskId,
      taskName: target?.taskName ?? active.taskName,
      stage: ExecutionDeadlineStage.scheduled,
      startedAtUtc: active.sessionStartedAtUtc,
      revision: 1,
      deadlineUtc: target?.effectiveDeadlineUtc,
      recordIds: <String>[active.recordId],
    );
    _sessions.add(session);
    if (notifyStart) {
      await _sendStartNotification(session, target, now);
    }
    await _persistQuietly();
    _notify();
  }

  Future<void> _sendStartNotification(
    ExecutionDeadlineSession session,
    ExecutionDeadlineTarget? target,
    DateTime now,
  ) async {
    final period = _plannedPeriodLabel(session, target);
    final title = '${session.taskName} 已开始';
    final body = period == null ? '已开始计时' : '计划时段 $period';
    final payload = _payload(session, kind: 'started');
    final attempt = notifications.show(title: title, body: body, payload: payload);
    final index = _indexOf(session.executionId);
    if (index < 0) return;
    var updated = _sessions[index];
    // 原生不可用但应用内提示真实可见 → 记一条“前台等价投递”，仍不声称系统已送达。
    final foregroundFallback = !attempt.accepted && onNotice != null;
    final delivery = ExecutionNotificationDelivery(
      kind: 'started',
      atUtc: now,
      channel: attempt.accepted
          ? 'native'
          : (foregroundFallback ? 'foreground' : 'none'),
      accepted: attempt.accepted || foregroundFallback,
      errorKind: attempt.errorKind,
      error: attempt.error,
    );
    updated = updated.copyWith(
      deliveries: _appendDelivery(updated, delivery),
    );
    if (!attempt.accepted) {
      // 原生不可用：应用内提示一次（只提示，不伪造系统投递）。
      onNotice?.call('「${session.taskName}」已开始（系统通知不可用，已改为应用内提示）');
    }
    _sessions[index] = updated;
  }

  String? _plannedPeriodLabel(
    ExecutionDeadlineSession session,
    ExecutionDeadlineTarget? target,
  ) {
    final start = target?.plannedStartUtc;
    final end = target?.plannedEndUtc;
    if (start == null || end == null) return null;
    final s = formatWallClockLabel(localTime.toLocal(start));
    final e = formatWallClockLabel(localTime.toLocal(end));
    return '$s–$e';
  }

  // ---------------------------------------------------------------- 轮询主循环

  /// 一次校核：先处理原生动作，再逐个推进会话。
  Future<void> tick() async {
    if (_disposed || !_loaded || _readOnly || _busy) return;
    // 同步占位，保证“延长确认 vs 自动完成”只能有一个有效（另一个立刻得到忙碌）。
    _busy = true;
    try {
      // 计时器事件可能还在异步队列里（例如测试里直接调用 tick）：先同步一次，
      // 保证“开始任务→创建会话/已开始通知”无需等待下一个事件循环。
      if (!_handlingTimerChange &&
          _activeSignature() != _lastActiveSignature) {
        _handlingTimerChange = true;
        final previous = _lastActiveSignature ?? 'idle';
        _lastActiveSignature = _activeSignature();
        try {
          await _handleTimerChanged(previous);
        } finally {
          _handlingTimerChange = false;
        }
      }
      await _drainActions();
      if (_disposed) return;
      var changed = false;
      final now = clock.nowUtc;
      for (final snapshot in List<ExecutionDeadlineSession>.from(_sessions)) {
        if (!snapshot.isActive) continue;
        final result = await _advanceSession(snapshot.executionId, now);
        changed = changed || result;
      }
      if (changed) {
        await _persistQuietly();
        _notify();
      }
    } catch (error) {
      _errorMessage = '执行截止校核失败：$error';
      _notify();
    } finally {
      _busy = false;
    }
  }

  Future<bool> _advanceSession(String executionId, DateTime now) async {
    final session = sessionById(executionId);
    if (session == null || !session.isActive) return false;
    var current = session;
    var changed = false;

    final target =
        await resolveTarget(current.conversationId, current.taskId);
    if (target == null) {
      // 任务/会话已删除：取消提醒，不做任何完成动作。
      _replace(
        current.copyWith(
          stage: ExecutionDeadlineStage.cancelled,
          clearResponseWindow: true,
          notice: '任务已不存在，已取消到期提醒',
        ),
      );
      _foregroundPending.remove(current.executionId);
      _notice = '任务「${current.taskName}」已不存在，到期提醒已取消';
      return true;
    }

    if (target.isDone) {
      _replace(
        current.copyWith(
          stage: ExecutionDeadlineStage.completed,
          completedAtUtc: now,
          completionSource: 'manual',
          clearResponseWindow: true,
          notice: '任务已完成，已取消到期提醒',
        ),
      );
      _foregroundPending.remove(current.executionId);
      return true;
    }

    if (current.stage == ExecutionDeadlineStage.scheduled) {
      final resolvedEnd = target.effectiveDeadlineUtc;
      if (resolvedEnd == null) {
        if (current.hasDeadline) {
          _replace(current.copyWith(
            clearDeadline: true,
            notice: '当前没有可用的甘特排程，暂不安排到期提醒',
          ));
          changed = true;
        }
      } else if (!current.hasDeadline ||
          !current.deadlineUtc!.isAtSameMomentAs(resolvedEnd)) {
        // 手动调整排程 → 旧期限失效，按新的最后一段结束时刻重新安排提醒。
        _replace(current.copyWith(
          deadlineUtc: resolvedEnd,
          deadlineVersion: current.deadlineVersion + 1,
          taskName: target.taskName,
          notice: '有效截止已更新为 ${_formatLocalTime(resolvedEnd)}',
        ));
        _notice = '有效截止已更新为 ${_formatLocalTime(resolvedEnd)}';
        changed = true;
      }
      current = sessionById(executionId)!;
      if (current.stage != ExecutionDeadlineStage.scheduled) {
        return changed;
      }
      if (current.hasDeadline && !now.isBefore(current.deadlineUtc!)) {
        await _enterPending(current, now);
        current = sessionById(executionId)!;
        changed = true;
      } else {
        return changed;
      }
    }

    if (current.stage == ExecutionDeadlineStage.pending) {
      // 等待期间排程被手动改过（或在“保存新甘特结束时刻”后崩溃/写盘先后不一致）：
      // 新截止晚于旧截止时按延长收敛——旧提醒作废，按新截止重新安排；
      // 只提示、绝不自动搬动其它任务，也不因为排程被改就提前完成。
      final resolvedEnd = target.effectiveDeadlineUtc;
      if (resolvedEnd != null &&
          current.hasDeadline &&
          !resolvedEnd.isAtSameMomentAs(current.deadlineUtc!)) {
        if (resolvedEnd.isAfter(current.deadlineUtc!)) {
          _replace(current.copyWith(
            stage: ExecutionDeadlineStage.scheduled,
            deadlineUtc: resolvedEnd,
            deadlineVersion: current.deadlineVersion + 1,
            scheduleChanged: false,
            clearSettled: true,
            clearFirstDelivery: true,
            clearSecondDelivery: true,
            clearResponseWindow: true,
            notice: '排程已延长，已按新截止重新安排提醒',
          ));
          _notice =
              '检测到排程已延长，已按新截止 ${_formatLocalTime(resolvedEnd)} 重新安排提醒';
          await _persistQuietly();
          return true;
        }
        if (!current.scheduleChanged) {
          _replace(current.copyWith(
            scheduleChanged: true,
            notice: '排程已手动调整；当前待处理期限仍按 ${_formatLocalTime(current.deadlineUtc!)}，'
                '需要延长请选择“延长时间”',
          ));
          changed = true;
        }
      }
      current = sessionById(executionId)!;
      if (current.stage != ExecutionDeadlineStage.pending) return changed;
      if (!current.firstDelivered) {
        final delivered = await _attemptDelivery(current, 'deadline', now);
        changed = changed || delivered;
        current = sessionById(executionId)!;
      }
      if (current.firstDelivered &&
          !current.secondDelivered &&
          current.stage == ExecutionDeadlineStage.pending) {
        final due = current.firstDeliveredAtUtc!
            .add(secondReminderDelay);
        if (!now.isBefore(due)) {
          final delivered = await _attemptDelivery(current, 'second', now);
          changed = changed || delivered;
        }
      }
      return changed;
    }

    if (current.stage == ExecutionDeadlineStage.secondReminder) {
      final windowEnd = current.responseWindowEndsAtUtc;
      if (windowEnd != null && !now.isBefore(windowEnd)) {
        changed = await _tryAutoComplete(current, now) || changed;
      }
      return changed;
    }
    return changed;
  }

  /// 到点：结算执行区间（截断在截止点）、进入待处理、准备第一次提醒。
  Future<void> _enterPending(
    ExecutionDeadlineSession session,
    DateTime now,
  ) async {
    final deadline = session.deadlineUtc!;
    // 结算动作触发的计时器停止事件不能被当成“只停止计时”。
    _finishing.add(session.executionId);
    try {
      // 正在计时 → 先把未闭区间结算到截止点；等待的 5＋5 分钟绝不计工时。
      final active = timer.active;
      if (active != null &&
          active.conversationId == session.conversationId &&
          active.taskId == session.taskId) {
        final result = active.isRunning
            ? await timer.stopAndConfirmAt(deadline)
            : await timer.stopAndConfirm();
        if (!result.ok) {
          // 落盘失败：不进入待处理（避免“界面上待处理但磁盘没有结算”），
          // 保持 scheduled 等下一次轮询重试。
          _notice = '到点结算失败：${result.message}';
          await _persistQuietly();
          return;
        }
      }
      _replace(session.copyWith(
        stage: ExecutionDeadlineStage.pending,
        settledAtUtc: now,
        notice: '计划时段已结束，任务待处理',
      ));
      _notice = '「${session.taskName}」计划时段已结束，任务待处理';
      _notify();
      await _persistQuietly();
    } finally {
      _finishing.remove(session.executionId);
    }
  }

  // ---------------------------------------------------------------- 投递

  /// 尝试一次提醒投递：系统接受即记账；否则降级为前台等价操作（需 UI 确认显示）。
  Future<bool> _attemptDelivery(
    ExecutionDeadlineSession session,
    String kind,
    DateTime now,
  ) async {
    // 已经在前台显示了等价的同类提醒（等 UI 确认投递）：不要重复弹系统通知。
    if (_foregroundPending[session.executionId] == kind) return false;
    final retryKey = '${session.executionId}|$kind';
    final nextAt = _nextAttemptAt[retryKey];
    if (nextAt != null && now.isBefore(nextAt)) return false;

    final autoAt = now.add(autoCompleteDelay);
    final title = kind == 'deadline'
        ? '${session.taskName} · 计划时段已结束'
        : '${session.taskName} · 再次提醒';
    final body = kind == 'deadline'
        ? '任务待处理：延长或结束任务'
        : '请在 ${_formatLocalTime(autoAt)} 前选择，届时将自动完成';
    final attempt = notifications.show(
      title: title,
      body: body,
      payload: _payload(session, kind: kind),
    );

    final index = _indexOf(session.executionId);
    if (index < 0) return false;
    var current = _sessions[index];
    final delivery = ExecutionNotificationDelivery(
      kind: kind,
      atUtc: now,
      channel: attempt.accepted ? 'native' : 'foreground',
      accepted: attempt.accepted,
      errorKind: attempt.errorKind,
      error: attempt.error,
    );
    current = current.copyWith(
      deliveries: _appendDelivery(current, delivery),
    );

    if (attempt.accepted) {
      current = _markDelivered(current, kind, now, 'native');
      _nextAttemptAt.remove(retryKey);
      _replace(current);
      _notice = kind == 'deadline'
          ? '已发送到期提醒（系统通知）'
          : '已发送第二次提醒（系统通知）';
      return true;
    }

    // 原生未接受：应用可见时提供前台等价操作，等 UI 真正显示后再记投递。
    if (isAppVisible()) {
      _foregroundPending[session.executionId] = kind;
      _replace(current.copyWith(
        notice: kind == 'deadline'
            ? '系统通知不可用，已在应用内显示“延长／结束任务”入口'
            : '系统通知不可用，已在应用内显示二次提醒（响应窗口从显示起算）',
      ));
      _nextAttemptAt.remove(retryKey);
      _notice = kind == 'deadline'
          ? '系统通知不可用，已改为应用内提醒'
          : '系统通知不可用，已改为应用内二次提醒';
      onNotice?.call(_notice!);
      return true;
    }

    // 应用不可见且系统拒绝：保持待处理，恢复后补发并留满窗口。
    _nextAttemptAt[retryKey] = now.add(deliveryRetryInterval);
    _replace(current.copyWith(
      notice: '系统通知未送达且应用不可见，保持待处理；恢复后补发',
    ));
    _notice = '系统通知未送达（${attempt.error ?? attempt.errorKind ?? '未知原因'}）；'
        '应用不可见，保持待处理，恢复后会补发提醒';
    return true;
  }

  ExecutionDeadlineSession _markDelivered(
    ExecutionDeadlineSession session,
    String kind,
    DateTime atUtc,
    String channel,
  ) {
    if (kind == 'deadline') {
      return session.copyWith(
        firstDeliveredAtUtc: atUtc,
        firstDeliveryChannel: channel,
        notice: '已提醒任务待处理',
      );
    }
    return session.copyWith(
      stage: ExecutionDeadlineStage.secondReminder,
      secondDeliveredAtUtc: atUtc,
      secondDeliveryChannel: channel,
      responseWindowEndsAtUtc: atUtc.add(autoCompleteDelay),
      responseDeadlineVersion: session.deadlineVersion,
      notice: '已二次提醒；${_formatLocalTime(atUtc.add(autoCompleteDelay))} 前可选择',
    );
  }

  /// UI 真实显示了前台等价提醒后调用：从这里开始计响应窗口。
  Future<void> ackForegroundDelivery(String executionId) async {
    final kind = _foregroundPending[executionId];
    if (kind == null) return;
    final session = sessionById(executionId);
    if (session == null || !session.isActive) {
      _foregroundPending.remove(executionId);
      return;
    }
    _foregroundPending.remove(executionId);
    final now = clock.nowUtc;
    final index = _indexOf(executionId);
    if (index < 0) return;
    var current = _sessions[index];
    final delivery = ExecutionNotificationDelivery(
      kind: kind,
      atUtc: now,
      channel: 'foreground',
      accepted: true,
    );
    current = current.copyWith(
      deliveries: _appendDelivery(current, delivery),
    );
    current = _markDelivered(current, kind, now, 'foreground');
    _sessions[index] = current;
    _notice = kind == 'deadline'
        ? '应用内到期提醒已显示'
        : '应用内二次提醒已显示；${_formatLocalTime(now.add(autoCompleteDelay))} 前可选择';
    await _persistQuietly();
    _notify();
  }

  /// 是否有待 UI 显示的前台提醒（顶部状态条据此展示“延长／结束”入口）。
  bool foregroundPendingFor(String executionId) =>
      _foregroundPending.containsKey(executionId);

  // ---------------------------------------------------------------- 自动完成

  Future<bool> _tryAutoComplete(
    ExecutionDeadlineSession session,
    DateTime now,
  ) async {
    if (_completionInFlight.contains(session.executionId)) return false;
    // 期限版本不匹配 = 期间发生了延长/重新安排，旧响应窗口作废。
    if (session.responseDeadlineVersion != null &&
        session.responseDeadlineVersion != session.deadlineVersion) {
      _replace(session.copyWith(
        stage: ExecutionDeadlineStage.scheduled,
        clearFirstDelivery: true,
        clearSecondDelivery: true,
        clearResponseWindow: true,
        notice: '期限已更新，旧的自动完成已取消',
      ));
      _notice = '期限已更新，旧的自动完成已取消';
      return true;
    }
    _completionInFlight.add(session.executionId);
    try {
      final target =
          await resolveTarget(session.conversationId, session.taskId);
      if (target == null || target.isDone) {
        // 期间被删除/已完成：自动完成作废（不会重复释放依赖）。
        _replace(session.copyWith(
          stage: ExecutionDeadlineStage.completed,
          completedAtUtc: now,
          completionSource: 'manual',
          clearResponseWindow: true,
          notice: '任务已完成或已不存在，无需自动完成',
        ));
        return true;
      }
      final outcome = await completeTask(
        session.conversationId,
        session.taskId,
        session.responseWindowEndsAtUtc ?? now,
        'auto',
      );
      final index = _indexOf(session.executionId);
      if (index < 0) return true;
      final current = _sessions[index];
      if (outcome.ok) {
        _sessions[index] = current.copyWith(
          stage: ExecutionDeadlineStage.completed,
          completedAtUtc: now,
          completionSource: 'auto',
          autoCompleteAttemptedAtUtc: now,
          completionError: null,
          clearCompletionError: true,
          clearResponseWindow: true,
          notice: '已按截止自动完成',
        );
        _notice = '「${current.taskName}」已按截止自动完成（等待时间不计入实际耗时）';
        return true;
      }
      _sessions[index] = current.copyWith(
        autoCompleteAttemptedAtUtc: now,
        completionError: outcome.message,
        notice: '自动完成未成功：${outcome.message}（会重试）',
      );
      _errorMessage = '自动完成失败：${outcome.message}';
      return true;
    } finally {
      _completionInFlight.remove(session.executionId);
    }
  }

  // ---------------------------------------------------------------- 用户命令

  /// “结束任务”：手动提前结束 / 待处理时结束 / 自动完成共用 `目标=已完成` 命令。
  ///
  /// 幂等：已完成的会话再次调用直接成功；计时器只停止一次；完成只提交一次。
  Future<ExecutionDeadlineAction> finishSession(
    String executionId, {
    String source = 'manual',
  }) async {
    // 同步占位：与延长确认/自动完成互斥，避免同一时刻提交两个结果。
    if (_busy) {
      return const ExecutionDeadlineAction(
          ok: false, message: '另一个到期操作正在进行，请稍后重试');
    }
    _busy = true;
    try {
      return await _finishSessionInternal(executionId, source: source);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<ExecutionDeadlineAction> _finishSessionInternal(
    String executionId, {
    String source = 'manual',
  }) async {
    if (!await _ensureWritable()) {
      return const ExecutionDeadlineAction(ok: false, message: '执行记录只读，无法结束任务');
    }
    final session = sessionById(executionId);
    if (session == null) {
      return const ExecutionDeadlineAction(ok: false, message: '找不到这次执行，提醒可能已过期');
    }
    if (session.stage == ExecutionDeadlineStage.completed) {
      return ExecutionDeadlineAction(ok: true, message: '任务已完成', session: session, completed: true);
    }
    if (session.stage == ExecutionDeadlineStage.cancelled) {
      return ExecutionDeadlineAction(ok: false, message: '这次执行已取消', session: session);
    }
    _finishing.add(executionId);
    try {
      // 1) 计时还挂在这个任务上：先按实际停止时刻结算（提前结束按实际时刻）。
      final active = timer.active;
      if (active != null &&
          active.conversationId == session.conversationId &&
          active.taskId == session.taskId) {
        final stopped = await timer.stopAndConfirm();
        if (!stopped.ok) {
          _notice = '结束任务未完成：${stopped.message}';
          _errorMessage = _notice;
          return ExecutionDeadlineAction(
              ok: false, message: _notice!, session: sessionById(executionId));
        }
      }
      // 2) 完成命令（既有完成/依赖规则，幂等，禁止裸 toggle）。
      final outcome = await completeTask(
        session.conversationId,
        session.taskId,
        clock.nowUtc,
        source,
      );
      final current = sessionById(executionId) ?? session;
      final index = _indexOf(executionId);
      if (outcome.ok) {
        if (index >= 0) {
          _sessions[index] = current.copyWith(
            stage: ExecutionDeadlineStage.completed,
            completedAtUtc: clock.nowUtc,
            completionSource: source,
            completionError: null,
            clearCompletionError: true,
            clearResponseWindow: true,
            settledAtUtc: current.settledAtUtc ?? clock.nowUtc,
            notice: outcome.alreadyDone ? '任务此前已完成' : '已结束任务并标记完成',
          );
        }
        _foregroundPending.remove(executionId);
        _notice = outcome.alreadyDone
            ? '「${current.taskName}」已完成，无需重复提交'
            : '已结束「${current.taskName}」并标记完成；剩余提醒已取消';
        await _persistQuietly();
        return ExecutionDeadlineAction(
          ok: true,
          message: _notice!,
          session: sessionById(executionId),
          completed: true,
        );
      }
      // 部分成功（计时已停、完成未成功）：保留待处理状态可重试，不重写工时。
      if (index >= 0) {
        _sessions[index] = current.copyWith(
          stage: current.stage == ExecutionDeadlineStage.scheduled
              ? ExecutionDeadlineStage.pending
              : current.stage,
          completionError: outcome.message,
          clearResponseWindow: true,
          notice: '计时已停止，但任务完成未成功：${outcome.message}',
        );
      }
      _notice = '计时已停止，但任务完成未成功：${outcome.message}（可重试结束任务）';
      _errorMessage = _notice;
      await _persistQuietly();
      return ExecutionDeadlineAction(
          ok: false, message: _notice!, session: sessionById(executionId));
    } finally {
      _finishing.remove(executionId);
    }
  }

  /// 预览延长：当前/新截止与潜在重叠（只读）。
  Future<ExecutionExtensionPreview> previewExtension(
    String executionId,
    DateTime newEndUtc,
  ) async {
    final session = sessionById(executionId);
    if (session == null) {
      return ExecutionExtensionPreview(
        currentDeadlineUtc: null,
        newDeadlineUtc: newEndUtc,
        error: '找不到这次执行',
      );
    }
    return previewExtensionFor(
        session.conversationId, session.taskId, newEndUtc);
  }

  /// 用户明确确认延长：保存新的甘特结束时刻、重排提醒、从确认时刻恢复计时。
  ///
  /// [expectedRevision] 是打开对话框时的会话修订号：期间自动完成或别的操作发生
  /// 变化时拒绝陈旧提交（延长确认与自动完成只能有一个有效）。
  Future<ExecutionDeadlineAction> confirmExtension(
    String executionId,
    DateTime newEndUtc, {
    required int expectedRevision,
  }) async {
    // 同步占位：与自动完成/结束任务互斥，只能有一个结果生效。
    if (_busy) {
      return const ExecutionDeadlineAction(
          ok: false, message: '另一个到期操作正在进行，请稍后重试');
    }
    _busy = true;
    try {
      return await _confirmExtensionInternal(
        executionId,
        newEndUtc,
        expectedRevision: expectedRevision,
      );
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<ExecutionDeadlineAction> _confirmExtensionInternal(
    String executionId,
    DateTime newEndUtc, {
    required int expectedRevision,
  }) async {
    if (!await _ensureWritable()) {
      return const ExecutionDeadlineAction(ok: false, message: '执行记录只读，无法延长');
    }
    final session = sessionById(executionId);
    if (session == null) {
      return const ExecutionDeadlineAction(ok: false, message: '这次执行已结束或不存在');
    }
    if (!session.isActive ||
        (session.stage != ExecutionDeadlineStage.pending &&
            session.stage != ExecutionDeadlineStage.secondReminder)) {
      return ExecutionDeadlineAction(
        ok: false,
        message: _staleStateMessage(session),
        session: session,
      );
    }
    if (session.revision != expectedRevision) {
      return ExecutionDeadlineAction(
        ok: false,
        message: '任务状态已变化（${_stageLabel(session.stage)}），请重新打开延长入口',
        session: session,
      );
    }
    final now = clock.nowUtc;
    if (!newEndUtc.isAfter(now)) {
      return ExecutionDeadlineAction(
          ok: false, message: '新截止必须晚于当前时刻', session: session);
    }
    final currentDeadline = session.deadlineUtc;
    if (currentDeadline != null && !newEndUtc.isAfter(currentDeadline)) {
      return ExecutionDeadlineAction(
          ok: false, message: '新截止必须晚于当前有效截止', session: session);
    }
    try {
      // 保存新的甘特结束时刻（只改本任务最后一段的结束，不搬动其它任务）。
      final applied = await applyExtensionFor(
        session.conversationId,
        session.taskId,
        newEndUtc,
      );
      if (!applied) {
        _notice = '新的甘特结束时刻未能保存，原状态保留，可重试';
        _errorMessage = _notice;
        return ExecutionDeadlineAction(
            ok: false, message: _notice!, session: sessionById(executionId));
      }
      // 重新核对面板数据：期间若被自动完成，拒绝继续恢复计时。
      final latest = sessionById(executionId)!;
      if (!latest.isActive) {
        return ExecutionDeadlineAction(
          ok: false,
          message: _staleStateMessage(latest),
          session: latest,
        );
      }
      final index = _indexOf(executionId);
      if (index >= 0) {
        _sessions[index] = latest.copyWith(
          stage: ExecutionDeadlineStage.scheduled,
          deadlineUtc: newEndUtc,
          deadlineVersion: latest.deadlineVersion + 1,
          scheduleChanged: false,
          clearSettled: true,
          clearFirstDelivery: true,
          clearSecondDelivery: true,
          clearResponseWindow: true,
          notice: '已延长至 ${_formatLocalTime(newEndUtc)}，恢复计时',
        );
      }
      // 从确认时刻恢复计时：
      final active = timer.active;
      var resumeMessage = '';
      if (active != null &&
          active.conversationId == session.conversationId &&
          active.taskId == session.taskId &&
          active.isPaused) {
        final resumed = await timer.resume();
        if (!resumed.ok) resumeMessage = '；恢复计时失败：${resumed.message}';
      } else if (active == null) {
        final ref = await taskRefFor(session.conversationId, session.taskId);
        if (ref == null) {
          resumeMessage = '；任务已不可用，未恢复计时';
        } else {
          _resuming = (
            conversationId: session.conversationId,
            taskId: session.taskId
          );
          final started = await timer.start(ref);
          if (!started.ok) {
            _resuming = null;
            resumeMessage = '；恢复计时失败：${started.message}';
          } else {
            await _attachRecordToSession(timer.active!);
          }
        }
      } else {
        resumeMessage = '；另一个任务正在计时，本次不再并行计时';
      }
      _notice = '已延长「${session.taskName}」至 ${_formatLocalTime(newEndUtc)}，'
          '提醒已按新截止重新安排$resumeMessage';
      await _persistQuietly();
      return ExecutionDeadlineAction(
          ok: true, message: _notice!, session: sessionById(executionId));
    } finally {
      _notify();
    }
  }

  /// 处理一个原生动作（供轮询与测试直接调用；身份不匹配时无副作用）。
  Future<void> handleAction(ExecutionNotificationAction action) async {
    _lastAction = action;
    final session = sessionById(action.executionId);
    if (session == null ||
        session.taskId != action.taskId ||
        !session.isActive) {
      // 旧通知重放：身份不存在或已结束 → 无副作用。
      _notice = '该提醒对应的一次执行已结束，操作已忽略';
      _notify();
      return;
    }
    final token = _deadlineToken(session);
    if (action.deadline.isNotEmpty && action.deadline != token) {
      _notice = '该提醒对应的期限已变化，操作已忽略';
      _notify();
      return;
    }
    if (action.isOpen) {
      await openTask(session.conversationId, session.taskId);
      _notice = '已打开「${session.taskName}」';
      _notify();
      return;
    }
    if (action.isFinish) {
      await _finishSessionInternal(session.executionId, source: 'manual');
      return;
    }
    if (action.isExtend) {
      if (session.stage == ExecutionDeadlineStage.pending ||
          session.stage == ExecutionDeadlineStage.secondReminder) {
        _extendRequest = session;
        _notice = '请选择新的截止时间';
        _notify();
      } else {
        _notice = '当前不需要延长（${_stageLabel(session.stage)}）';
        _notify();
      }
    }
  }

  // ---------------------------------------------------------------- 内部工具

  Future<void> _drainActions() async {
    for (var i = 0; i < 10; i++) {
      final raw = notifications.takeActionJson();
      if (raw == null) return;
      final action = ExecutionNotificationAction.tryParse(raw);
      if (action == null) continue;
      await handleAction(action);
      if (_disposed) return;
    }
  }

  Future<bool> _ensureWritable() async {
    if (!_loaded) await load();
    return !_readOnly;
  }

  int _indexOf(String executionId) {
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].executionId == executionId) return i;
    }
    return -1;
  }

  void _replace(ExecutionDeadlineSession session) {
    final index = _indexOf(session.executionId);
    if (index < 0) return;
    _sessions[index] = session;
  }

  ExecutionDeadlineSession? _sessionByRecordId(String recordId) {
    if (recordId.isEmpty) return null;
    for (var i = _sessions.length - 1; i >= 0; i--) {
      final s = _sessions[i];
      if (s.isActive && s.recordIds.contains(recordId)) return s;
    }
    return null;
  }

  List<ExecutionNotificationDelivery> _appendDelivery(
    ExecutionDeadlineSession session,
    ExecutionNotificationDelivery delivery,
  ) {
    final next = <ExecutionNotificationDelivery>[
      ...session.deliveries,
      delivery,
    ];
    // 投递账本只保留最近 40 条，避免长期重试把文件撑大。
    if (next.length > 40) next.removeRange(0, next.length - 40);
    return List<ExecutionNotificationDelivery>.unmodifiable(next);
  }

  String _deadlineToken(ExecutionDeadlineSession session) {
    final ms = session.deadlineUtc?.millisecondsSinceEpoch ?? 0;
    return '${session.deadlineVersion}:$ms';
  }

  Map<String, dynamic> _payload(
    ExecutionDeadlineSession session, {
    required String kind,
  }) =>
      <String, dynamic>{
        'taskId': session.taskId,
        'executionId': session.executionId,
        'deadline': _deadlineToken(session),
        'kind': kind,
      };

  String _formatLocalTime(DateTime utc) =>
      formatWallClockLabel(localTime.toLocal(utc.toUtc()));

  String _stageLabel(ExecutionDeadlineStage stage) => switch (stage) {
        ExecutionDeadlineStage.scheduled => '已安排',
        ExecutionDeadlineStage.pending => '待处理',
        ExecutionDeadlineStage.secondReminder => '再次提醒',
        ExecutionDeadlineStage.completed => '已完成',
        ExecutionDeadlineStage.cancelled => '已取消',
      };

  String _staleStateMessage(ExecutionDeadlineSession session) {
    final status = _stageLabel(session.stage);
    final completedAt = session.completedAtUtc;
    if (session.stage == ExecutionDeadlineStage.completed &&
        completedAt != null) {
      return '任务已${session.completionSource == 'auto' ? '按到期自动' : ''}完成'
          '（${_formatLocalTime(completedAt)}），此前的延长/结束操作已失效';
    }
    return '当前状态为“$status”，此前的操作已失效';
  }

  Future<bool> _persistQuietly() async {
    if (_disposed || _readOnly || !_loaded) return false;
    try {
      await store.save(_sessions);
      _persistError = null;
      return true;
    } catch (error) {
      _persistError = '执行截止记录保存失败：$error';
      _errorMessage = _persistError;
      // 写盘失败不丢内存状态；下一次操作/轮询继续重试。
      return false;
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
