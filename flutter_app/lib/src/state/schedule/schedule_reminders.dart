// 应用运行期间的日程提醒服务（任务 6）。
//
// 能力边界（01 框架 §8 / 02 任务 6）：
//   * 只保证应用进程运行、提醒服务可用且 OS 接受通知时尝试提醒；不承诺退出
//     应用、休眠或断电后送达，也不实现闹钟音频/后台常驻。
//   * 由唯一应用级服务调度：组合根注入时钟与发送回调（生产可适配现有
//     NativeGateway.showSystemNotification），UI 不直接接触 FFI。
//   * 只有取得数据目录写锁的实例（ScheduleStore.readOnly == false）发送提醒；
//     只读第二实例只展示/只读，不重复发送。
//   * 提醒身份 = occurrenceKey + 实际触发 UTC；仅改标题/地点/备注不会重发，
//     改期/删除/系列修改会重建计划，旧触发项自然消失。
//   * 启动或恢复时只补报过去 catchUpWindow（默认 15 分钟）内到期项并合并为
//     一条通知；更早的到期项不逐条弹出，避免重启通知洪泛。
//   * 去重状态写入 <dataRoot>/schedules/reminder_state.json；保存失败立即停止
//     后续自动派发并报告，避免在没有去重依据的情况下重复通知。
//   * 发送回调返回 false 表示“OS 拒绝/通知不可用”，不是用户已看到；当前进程
//     有限重试（maxSendAttempts），超出后记录 rejected 并提示，不做无界重试。
//   * timer 定到最近一个待发触发项，并以 tickInterval 作为有界的兜底重扫，
//     覆盖休眠恢复、系统时钟跳变等场景；测试注入可推进的 clock + 手动 tick，
//     不等待真实分钟。

import 'dart:async';

import '../../model/schedule_event.dart';
import '../ics/ics_timezones.dart';
import 'schedule_controller.dart';
import 'schedule_expander.dart';
import 'schedule_store.dart';

/// 发送回调：(`title`, `body`) → OS 是否接受。
///
/// 返回值命名为 accepted：true 仅表示系统接受了通知请求，不等于用户看到。
typedef ScheduleReminderSender = Future<bool> Function(
    String title, String body);

/// 提醒去重状态文件版本；读到更大版本时本次运行停止派发，避免覆盖新记录。
const int kScheduleReminderStateVersion = 1;

/// 去重状态最多保留的条目数（限制 `reminder_state.json` 的增长）。
const int kScheduleReminderStateMaxEntries = 500;

/// 已处理去重条目的保留时长；更早的条目可清理（时钟回拨仍能命中近期条目）。
const Duration kScheduleReminderStateRetention = Duration(days: 30);

/// 提醒计划向前看多远：最长提前量是 1 天，再加 1 天缓冲。
///
/// 计划只需要覆盖“从当前时刻起的下一次触达”；应用运行期间 tick 会不断
/// 滚动这个窗口，因此不需要展开远景重复实例。
const Duration kScheduleReminderPlanLookahead = Duration(days: 2);

/// 能力边界文案，供 UI 显示「应用运行时提醒」，不做退出后送达的承诺。
const String kScheduleReminderRuntimeOnlyNotice = '日程提醒仅在应用运行时送达';

/// 一条已计划提醒的去重状态。
enum ScheduleReminderDeliveryStatus {
  /// 已记录发送意图、结果尚未落盘（崩溃窗口内可能重试一次）。
  pending('pending'),

  /// OS 接受了通知请求（不等于用户看到）。
  accepted('accepted'),

  /// 有限重试后仍被拒绝/不可用；本进程与重启都不再重复派发。
  rejected('rejected'),

  /// 明确跳过的旧提醒（例如备份恢复后抑制恢复前到期的补报），不再派发。
  skipped('skipped');

  const ScheduleReminderDeliveryStatus(this.wireName);
  final String wireName;

  static ScheduleReminderDeliveryStatus? parse(Object? value) {
    final text = value is String ? value : (value == null ? '' : '$value');
    for (final status in ScheduleReminderDeliveryStatus.values) {
      if (status.wireName == text) return status;
    }
    return null;
  }
}

/// 提醒去重 key = occurrenceKey + 实际触发 UTC（不用 event revision 当 key）。
String scheduleReminderKey(String occurrenceKey, DateTime triggerUtc) =>
    '$occurrenceKey|${triggerUtc.toUtc().toIso8601String()}';

/// 一条计划中的提醒（触发时刻由实例 + 提醒类型计算，不持久化）。
class ScheduleReminderPlanItem {
  const ScheduleReminderPlanItem({
    required this.eventId,
    required this.occurrenceKey,
    required this.title,
    required this.reminder,
    required this.triggerUtc,
    required this.timezoneId,
    required this.allDay,
    this.startUtc,
    this.startDate,
  });

  final String eventId;
  final String occurrenceKey;
  final String title;
  final ScheduleReminderKind reminder;

  /// 实际触发时刻（UTC）。
  final DateTime triggerUtc;
  final String timezoneId;
  final bool allDay;

  /// 定时实例的开始时刻（UTC）；全天实例为 null。
  final DateTime? startUtc;

  /// 全天实例的本地开始日期（yyyy-MM-dd）；定时实例为 null。
  final String? startDate;

  String get key => scheduleReminderKey(occurrenceKey, triggerUtc);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'eventId': eventId,
        'occurrenceKey': occurrenceKey,
        'title': title,
        'reminder': reminder.wireName,
        'triggerUtc': triggerUtc.toUtc().toIso8601String(),
        'timezoneId': timezoneId,
        'allDay': allDay,
        if (startUtc != null) 'startUtc': startUtc!.toUtc().toIso8601String(),
        if (startDate != null) 'startDate': startDate,
      };
}

/// 去重状态里的一条记录。
class ScheduleReminderStateEntry {
  const ScheduleReminderStateEntry({
    required this.key,
    required this.eventId,
    required this.occurrenceKey,
    required this.triggerUtc,
    required this.status,
    this.attemptedAtUtc,
  });

  final String key;
  final String eventId;
  final String occurrenceKey;
  final DateTime triggerUtc;
  final ScheduleReminderDeliveryStatus status;
  final DateTime? attemptedAtUtc;

  ScheduleReminderStateEntry copyWith({
    ScheduleReminderDeliveryStatus? status,
    DateTime? attemptedAtUtc,
  }) =>
      ScheduleReminderStateEntry(
        key: key,
        eventId: eventId,
        occurrenceKey: occurrenceKey,
        triggerUtc: triggerUtc,
        status: status ?? this.status,
        attemptedAtUtc: attemptedAtUtc ?? this.attemptedAtUtc,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'eventId': eventId,
        'occurrenceKey': occurrenceKey,
        'triggerUtc': triggerUtc.toUtc().toIso8601String(),
        'status': status.wireName,
        if (attemptedAtUtc != null)
          'attemptedAtUtc': attemptedAtUtc!.toUtc().toIso8601String(),
      };

  /// 宽松解析单条记录：坏条目直接丢弃（去重文件是缓存，不阻断启动）。
  static ScheduleReminderStateEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final key = (j['key'] as String?)?.trim() ?? '';
    final eventId = (j['eventId'] as String?)?.trim() ?? '';
    final occurrenceKey = (j['occurrenceKey'] as String?)?.trim() ?? '';
    if (key.isEmpty ||
        eventId.isEmpty ||
        !isValidOccurrenceKey(occurrenceKey)) {
      return null;
    }
    if (eventIdOfOccurrenceKey(occurrenceKey) != eventId) return null;
    final triggerUtc = parseUtc(j['triggerUtc']);
    if (triggerUtc == null) return null;
    if (key != scheduleReminderKey(occurrenceKey, triggerUtc)) return null;
    final status = ScheduleReminderDeliveryStatus.parse(j['status']);
    if (status == null) return null;
    return ScheduleReminderStateEntry(
      key: key,
      eventId: eventId,
      occurrenceKey: occurrenceKey,
      triggerUtc: triggerUtc,
      status: status,
      attemptedAtUtc: parseUtc(j['attemptedAtUtc']),
    );
  }
}

/// 应用运行期间的日程提醒调度器。
///
/// 生命周期：组合根先 `await controller.initialize()`，再 `start()`；退出时先
/// `await stop()`（停止新派发并等待在途保存）再释放实例锁。`dispose()` 只释放
/// 本服务自身，不关闭 controller/store（它们归组合根所有）。
class ScheduleReminderService {
  ScheduleReminderService({
    required ScheduleController controller,
    required ScheduleStore store,
    required ScheduleReminderSender send,
    DateTime Function()? clock,
    this.tickInterval = const Duration(minutes: 1),
    this.catchUpWindow = const Duration(minutes: 15),
    this.retryDelay = const Duration(seconds: 2),
    this.maxSendAttempts = 3,
    this.onNotice,
  })  : _controller = controller,
        _store = store,
        _send = send,
        _clock = clock ?? DateTime.now {
    if (tickInterval <= Duration.zero) {
      throw ArgumentError.value(tickInterval, 'tickInterval', '必须大于 0');
    }
    if (catchUpWindow < Duration.zero) {
      throw ArgumentError.value(catchUpWindow, 'catchUpWindow', '不能为负数');
    }
    if (retryDelay < Duration.zero) {
      throw ArgumentError.value(retryDelay, 'retryDelay', '不能为负数');
    }
    if (maxSendAttempts < 1) {
      throw ArgumentError.value(maxSendAttempts, 'maxSendAttempts', '至少为 1');
    }
  }

  final ScheduleController _controller;
  final ScheduleStore _store;
  final ScheduleReminderSender _send;
  final DateTime Function() _clock;

  /// 兜底 tick 的最大间隔（也是 timer 的最长等待）：限制为定时重扫，不做
  /// 无界高频扫描；测试注入大值并手动 `tick()`。
  final Duration tickInterval;

  /// 启动/恢复时补报过去多久内到期的提醒（默认 15 分钟，合并为一条）。
  final Duration catchUpWindow;

  /// 发送被 OS 拒绝时的重试间隔（测试可注入 `Duration.zero`）。
  final Duration retryDelay;

  /// 单次通知的最大发送尝试次数（含首次），有限重试。
  final int maxSendAttempts;

  /// 面向用户的提示（例如保存失败、通知被系统拒绝）；UI 决定如何展示。
  final void Function(String message)? onNotice;

  bool _running = false;
  bool _disposed = false;
  bool _dispatchHalted = false;
  bool _stateLoaded = false;
  bool _suppressCatchUp = false;
  Timer? _timer;
  Future<void> _queue = Future<void>.value();
  Map<String, ScheduleReminderStateEntry> _state =
      <String, ScheduleReminderStateEntry>{};
  List<ScheduleReminderPlanItem> _plan = const <ScheduleReminderPlanItem>[];
  List<String> _planWarnings = const <String>[];
  String? _lastNotice;
  String? _lastSendError;
  DateTime? _lastAcceptedAt;
  String? _reportedPlanWarning;

  bool get isRunning => _running;
  bool get isDisposed => _disposed;

  /// 去重状态保存失败或遇到更新版本后，自动派发已停止。
  bool get dispatchHalted => _dispatchHalted;

  /// 当前实例是否只读（只读实例不发送提醒，也不写去重状态）。
  bool get readOnly => _controller.readOnly || _store.readOnly;

  /// 去重状态是否会持久化；内存模式下仅内存去重，重启后可能重复提醒一次。
  bool get statePersistent => !_store.isMemoryOnly;

  /// 当前是否允许发送提醒（运行中、非只读、未停止派发）。
  bool get deliversNotifications => _running && !readOnly && !_dispatchHalted;

  /// 最近一次面向用户的提示。
  String? get lastNotice => _lastNotice;

  /// 最近一次发送异常（发送回调抛出时记录），正常为 null。
  String? get lastSendError => _lastSendError;

  /// 最近一次 OS 接受通知的时间（供点击分发区分“日程提醒”与“分析完成”）。
  DateTime? get lastAcceptedAt => _lastAcceptedAt;

  /// 当前计划（按触发时刻排序）；启动/重建后更新，测试与诊断可读。
  List<ScheduleReminderPlanItem> get plan => _plan;

  /// 计算提醒时间时遇到的警告（时区未知、DST 歧义等）。
  List<String> get planWarnings => _planWarnings;

  /// 已保留的去重状态条目数（测试/诊断用）。
  int get retainedStateEntries => _state.length;

  /// 启动：读入去重状态、计算计划并处理补报；重复调用无副作用。
  Future<void> start() async {
    if (_disposed) {
      throw StateError('日程提醒服务已释放，不能再启动');
    }
    if (_running) return;
    _running = true;
    _controller.addListener(_onControllerChanged);
    await _serialize(_startImpl);
  }

  Future<void> _startImpl() async {
    try {
      if (!_stateLoaded) {
        _stateLoaded = true;
        await _loadState();
      }
      if (!_running) return;
      if (_store.isMemoryOnly) {
        _emitNotice('没有可写数据目录：日程提醒去重仅保存在内存中，重启应用后可能重复提醒一次。');
      } else if (readOnly) {
        _emitNotice('当前日程实例为只读，不会发送日程提醒。');
      }
      await _recomputeImpl();
    } catch (error) {
      _handleInternalError(error);
    }
  }

  /// 停止：取消 timer、移除 listener，并等待在途派发/保存完成。
  Future<void> stop() async {
    if (!_running) {
      _cancelTimer();
      return;
    }
    _running = false;
    _cancelTimer();
    _controller.removeListener(_onControllerChanged);
    await _queue;
  }

  /// 释放服务自身（不关闭 controller/store）。可重复调用。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }

  /// 重新计算计划并处理到期项。
  ///
  /// 在启动、系统恢复、时钟跳变、日程增删改与备份恢复后调用。
  Future<void> rebuild() => _serialize(_safeRecompute);

  /// 兜底 tick：生产由 timer 调用，测试可手动推进（配合注入的 clock）。
  Future<void> tick() => _serialize(_safeRecompute);

  /// 让下一次重算不做“过去 catchUpWindow 内”的补报（备份恢复后抑制旧提醒）。
  ///
  /// 只影响一次重算；正常的未来触发不受影响。应在恢复前调用。
  void suppressNextCatchUp() {
    _suppressCatchUp = true;
  }

  Future<void> _safeRecompute() async {
    if (!_running || _disposed) return;
    try {
      await _recomputeImpl();
    } catch (error) {
      _handleInternalError(error);
    }
  }

  Future<void> _recomputeImpl() async {
    final now = _clock().toUtc();
    final computation = _computePlan(now);
    _plan = computation.items;
    _planWarnings = computation.warnings;
    if (!computation.complete || computation.warnings.isNotEmpty) {
      final summary = computation.warnings.isEmpty
          ? '展开结果不完整'
          : computation.warnings.join('；');
      if (summary != _reportedPlanWarning) {
        _reportedPlanWarning = summary;
        _emitNotice('部分日程提醒无法计算：$summary');
      }
    } else {
      _reportedPlanWarning = null;
    }

    if (_pruneState(now) && !readOnly && !_store.isMemoryOnly) {
      if (!await _persistState()) return;
    }

    final suppressCatchUp = _suppressCatchUp;
    _suppressCatchUp = false;
    if (!deliversNotifications) return;

    final cutoff = now.subtract(catchUpWindow);
    final due = <ScheduleReminderPlanItem>[
      for (final item in _plan)
        if (!item.triggerUtc.isAfter(now) &&
            item.triggerUtc.isAfter(cutoff) &&
            _needsDispatch(item))
          item,
    ];
    if (due.isEmpty) {
      _scheduleTimer();
      return;
    }
    if (suppressCatchUp) {
      // 备份恢复后抑制旧提醒：把这些已到期项标记为 skipped 并落盘，
      // 后续 tick/重启都不会再逐条弹出。
      await _markSkipped(due);
      _scheduleTimer();
      return;
    }
    await _dispatchBatch(due);
    _scheduleTimer();
  }

  void _onControllerChanged() {
    if (!_running || _disposed) return;
    unawaited(rebuild());
  }

  Future<void> _loadState() async {
    final raw = await _store.loadReminderState();
    if (raw == null) return;
    final version = raw['schemaVersion'];
    if (version is int && version > kScheduleReminderStateVersion) {
      _dispatchHalted = true;
      _emitNotice('日程提醒去重记录来自更新的应用版本（schema $version），本次运行不发送提醒，以免覆盖新版本记录。');
      return;
    }
    final entriesRaw = raw['entries'];
    if (entriesRaw is! List) return;
    final entries = <String, ScheduleReminderStateEntry>{};
    for (final item in entriesRaw) {
      final entry = ScheduleReminderStateEntry.tryParse(item);
      if (entry != null) entries[entry.key] = entry;
    }
    _state = entries;
  }

  Future<void> _markSkipped(List<ScheduleReminderPlanItem> items) async {
    final at = _clock().toUtc();
    for (final item in items) {
      _state[item.key] = ScheduleReminderStateEntry(
        key: item.key,
        eventId: item.eventId,
        occurrenceKey: item.occurrenceKey,
        triggerUtc: item.triggerUtc,
        status: ScheduleReminderDeliveryStatus.skipped,
        attemptedAtUtc: at,
      );
    }
    await _persistState();
  }

  Future<void> _dispatchBatch(
    List<ScheduleReminderPlanItem> items,
  ) async {
    final attemptedAt = _clock().toUtc();
    final pending = <String, ScheduleReminderStateEntry>{
      for (final item in items)
        item.key: ScheduleReminderStateEntry(
          key: item.key,
          eventId: item.eventId,
          occurrenceKey: item.occurrenceKey,
          triggerUtc: item.triggerUtc,
          status: ScheduleReminderDeliveryStatus.pending,
          attemptedAtUtc: attemptedAt,
        ),
    };
    // 先落盘“尝试中”，再发送：崩溃后最多有限重复，而不是没有去重依据地重发。
    _state.addAll(pending);
    if (!await _persistState()) return;

    _lastSendError = null;
    var accepted = false;
    try {
      accepted = await _sendWithRetries(
        _titleFor(items),
        _bodyFor(items),
      );
    } catch (error) {
      _lastSendError = '$error';
      accepted = false;
    }
    final status = accepted
        ? ScheduleReminderDeliveryStatus.accepted
        : ScheduleReminderDeliveryStatus.rejected;
    final finishedAt = _clock().toUtc();
    if (accepted) _lastAcceptedAt = finishedAt;
    for (final key in pending.keys) {
      final entry = _state[key];
      if (entry != null) {
        _state[key] =
            entry.copyWith(status: status, attemptedAtUtc: finishedAt);
      }
    }
    if (!await _persistState()) return;
    if (!accepted) {
      _emitNotice('日程提醒发送失败：系统通知被拒绝或当前不可用；本进程不再重试，请检查系统通知设置。');
    }
  }

  Future<bool> _sendWithRetries(String title, String body) async {
    for (var attempt = 0; attempt < maxSendAttempts; attempt++) {
      if (!_running || _disposed) return false;
      try {
        if (await _send(title, body)) return true;
      } catch (error) {
        _lastSendError = '$error';
      }
      if (attempt + 1 < maxSendAttempts && retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
    }
    return false;
  }

  String _titleFor(List<ScheduleReminderPlanItem> items) =>
      items.length == 1 ? '日程提醒' : '日程提醒（${items.length} 条）';

  String _bodyFor(List<ScheduleReminderPlanItem> items) =>
      items.map(_bodyForItem).join('\n');

  String _bodyForItem(ScheduleReminderPlanItem item) {
    if (item.allDay) {
      return '「${item.title}」全天日程（${item.startDate ?? ''}）';
    }
    final startUtc = item.startUtc;
    final wall = startUtc == null ? null : wallOf(startUtc, item.timezoneId);
    final when = wall == null
        ? (startUtc == null ? '' : startUtc.toUtc().toIso8601String())
        : _formatWall(wall);
    return '「${item.title}」将于 $when（${item.timezoneId}）开始';
  }

  String _formatWall(DateTime wall) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${wall.year.toString().padLeft(4, '0')}-${two(wall.month)}-${two(wall.day)} '
        '${two(wall.hour)}:${two(wall.minute)}';
  }

  bool _needsDispatch(ScheduleReminderPlanItem item) {
    final status = _state[item.key]?.status;
    // 只有从未处理或崩溃残留的 pending 需要派发；accepted/rejected/skipped 均已处理。
    return status == null || status == ScheduleReminderDeliveryStatus.pending;
  }

  void _scheduleTimer() {
    _cancelTimer();
    if (!_running || _disposed || _dispatchHalted || readOnly) return;
    final now = _clock().toUtc();
    DateTime? next;
    for (final item in _plan) {
      if (!item.triggerUtc.isAfter(now)) continue;
      if (!_needsDispatch(item)) continue;
      if (next == null || item.triggerUtc.isBefore(next)) {
        next = item.triggerUtc;
      }
    }
    var wait = next == null ? tickInterval : next.difference(now);
    if (wait > tickInterval) wait = tickInterval;
    if (wait < const Duration(milliseconds: 1)) {
      wait = const Duration(milliseconds: 1);
    }
    _timer = Timer(wait, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (!_running || _disposed) return;
    unawaited(tick());
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<bool> _persistState() async {
    if (readOnly || _store.isMemoryOnly) return true;
    try {
      await _store.saveReminderState(_stateJson());
      return true;
    } catch (error) {
      _dispatchHalted = true;
      _cancelTimer();
      _emitNotice('日程提醒去重状态保存失败，已停止后续自动提醒：$error');
      return false;
    }
  }

  Map<String, dynamic> _stateJson() {
    final entries = _state.values.toList(growable: false)
      ..sort((a, b) {
        final byTrigger = a.triggerUtc.compareTo(b.triggerUtc);
        return byTrigger != 0 ? byTrigger : a.key.compareTo(b.key);
      });
    return <String, dynamic>{
      'schemaVersion': kScheduleReminderStateVersion,
      'entries': entries.map((e) => e.toJson()).toList(growable: false),
    };
  }

  /// 清理过期 pending（崩溃残留）与超出保留量/时长的已处理条目。
  bool _pruneState(DateTime now) {
    final catchUpCutoff = now.subtract(catchUpWindow);
    final retentionCutoff = now.subtract(kScheduleReminderStateRetention);
    var removed = false;
    _state.removeWhere((key, entry) {
      final stale = entry.status == ScheduleReminderDeliveryStatus.pending
          ? entry.triggerUtc.isBefore(catchUpCutoff)
          : entry.triggerUtc.isBefore(retentionCutoff);
      if (stale) removed = true;
      return stale;
    });
    if (_state.length > kScheduleReminderStateMaxEntries) {
      final sorted = _state.values.toList(growable: false)
        ..sort((a, b) => a.triggerUtc.compareTo(b.triggerUtc));
      final excess = _state.length - kScheduleReminderStateMaxEntries;
      for (final entry in sorted.take(excess)) {
        _state.remove(entry.key);
        removed = true;
      }
    }
    return removed;
  }

  _PlanComputation _computePlan(DateTime nowUtc) {
    final fromUtc = nowUtc.subtract(catchUpWindow);
    final toUtc = nowUtc.add(kScheduleReminderPlanLookahead);
    final resolver = IcsTimeZoneResolver();
    final items = <String, ScheduleReminderPlanItem>{};
    final warnings = <String>[];
    var complete = true;

    for (final event in _controller.events) {
      // 无提醒的日程不参与展开，避免每个 tick 做无用功。
      if (event.reminder == ScheduleReminderKind.none) continue;
      final result = expandScheduleEvents(
        events: <ScheduleEvent>[event],
        query: ScheduleQuery(
          fromUtc: fromUtc,
          toUtc: toUtc,
          timezoneId: event.timezoneId,
        ),
      );
      if (!result.complete) {
        complete = false;
        for (final warning in result.warnings) {
          if (!warnings.contains(warning)) warnings.add(warning);
        }
      }
      for (final occurrence in result.occurrences) {
        final triggerUtc = _triggerUtcFor(occurrence, resolver, warnings);
        if (triggerUtc == null) {
          complete = false;
          continue;
        }
        if (triggerUtc.isBefore(fromUtc) || triggerUtc.isAfter(toUtc)) continue;
        final item = ScheduleReminderPlanItem(
          eventId: occurrence.eventId,
          occurrenceKey: occurrence.occurrenceKey,
          title: occurrence.title,
          reminder: occurrence.reminder,
          triggerUtc: triggerUtc,
          timezoneId: occurrence.timezoneId,
          allDay: occurrence.allDay,
          startUtc: occurrence.startUtc,
          startDate: occurrence.startDate,
        );
        items[item.key] = item;
      }
    }

    final sorted = items.values.toList(growable: false)
      ..sort((a, b) {
        final byTrigger = a.triggerUtc.compareTo(b.triggerUtc);
        return byTrigger != 0 ? byTrigger : a.key.compareTo(b.key);
      });
    return _PlanComputation(
      items: List<ScheduleReminderPlanItem>.unmodifiable(sorted),
      warnings: List<String>.unmodifiable(warnings),
      complete: complete,
    );
  }

  DateTime? _triggerUtcFor(
    ScheduleOccurrence occurrence,
    IcsTimeZoneResolver resolver,
    List<String> warnings,
  ) {
    final reminder = occurrence.reminder;
    if (reminder == ScheduleReminderKind.none) return null;
    if (occurrence.allDay) {
      final startDate = occurrence.startDate;
      if (startDate == null) {
        warnings.add('日程「${occurrence.title}」缺少全天日期');
        return null;
      }
      final targetDate = reminder == ScheduleReminderKind.allDayPrevDay
          ? addDaysToDateKey(startDate, -1)
          : startDate;
      final base = dateKeyToUtc(targetDate);
      if (base == null) {
        warnings.add('日程「${occurrence.title}」的提醒日期不合法');
        return null;
      }
      // 全天提醒固定在当地 09:00（按事件时区，不按设备固定偏移）。
      final wall = DateTime.utc(base.year, base.month, base.day, 9);
      final converted = resolver.resolveWall(occurrence.timezoneId, wall);
      if (!converted.isOk || converted.utc == null) {
        warnings.add('日程「${occurrence.title}」的提醒时间无法确定：${converted.detail}');
        return null;
      }
      return converted.utc;
    }
    final startUtc = occurrence.startUtc;
    if (startUtc == null) {
      warnings.add('日程「${occurrence.title}」缺少开始时间');
      return null;
    }
    switch (reminder) {
      case ScheduleReminderKind.atStart:
        return startUtc;
      case ScheduleReminderKind.minutes5:
        return startUtc.subtract(const Duration(minutes: 5));
      case ScheduleReminderKind.minutes15:
        return startUtc.subtract(const Duration(minutes: 15));
      case ScheduleReminderKind.minutes30:
        return startUtc.subtract(const Duration(minutes: 30));
      case ScheduleReminderKind.dayBefore:
        return startUtc.subtract(const Duration(days: 1));
      case ScheduleReminderKind.none:
      case ScheduleReminderKind.allDaySameDay:
      case ScheduleReminderKind.allDayPrevDay:
        return null;
    }
  }

  void _emitNotice(String message) {
    _lastNotice = message;
    try {
      onNotice?.call(message);
    } catch (_) {
      // 提示回调失败不能打断提醒调度。
    }
  }

  void _handleInternalError(Object error) {
    _dispatchHalted = true;
    _cancelTimer();
    _emitNotice('日程提醒调度失败，已停止自动派发：$error');
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}

class _PlanComputation {
  const _PlanComputation({
    required this.items,
    required this.warnings,
    required this.complete,
  });

  final List<ScheduleReminderPlanItem> items;
  final List<String> warnings;
  final bool complete;
}
