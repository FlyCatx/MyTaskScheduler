// Windows 窗口能力端口。
//
// Dart 只描述"想做什么"（最小化、最大化/还原、关闭、上报拖动区域），真正的窗口
// 状态由 runner 的 Win32 实现负责；最大化与外形都由原生消息回传，不能只靠点击时
// 翻转一个 bool。
//
// 第二轮（0.2.2）新增：唯一的窗口状态来源 [WindowShape]。它把"真实窗口状态 +
// 实际像素尺寸 + 当前 DPI + 生效圆角"一起传给 Flutter，原生侧在窗口区域应用完成后
// 才推送，因此 Flutter 的裁剪/描边与真实窗口形状永远描述同一个状态：
//   普通还原窗口 → 18 DIP 圆角；最大化 / 系统 Snap → 直角（半径 0）。
//
// 会话/电源事件：runner 通过**同一个** taskscheduler/window 通道上报锁屏/解锁与
// 睡眠/恢复两类独立原因（powerStateChanged 事件与 powerState 查询）。[DesktopWindow]
// 把两类原因聚合成"离开"（锁屏 || 睡眠），去重并串行转交 [onExecutionAwayChanged]；
// 原生注册失败也随状态上报，界面可以明确提示。最小化、失焦、窗口外形变化都不是
// 离开原因。
//
// 在测试或缺少原生实现的环境里，所有调用都安全降级（no-op），不会阻塞界面。
//
// 主要类型：WindowShape、WindowPowerState、DesktopWindow。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次窗口状态快照。
///
/// [radiusDip] 是**实际生效**的圆角半径：普通窗口 18，最大化/Snap/最小化为 0
/// （最小化保留上一个值，因为没有可绘制区域）。[sequence] 由原生单调递增，
/// 用来丢弃初始化查询的迟到结果。
@immutable
class WindowShape {
  const WindowShape({
    this.radiusDip = 18,
    this.maximized = false,
    this.snapped = false,
    this.minimized = false,
    this.dpi = 96,
    this.width = 0,
    this.height = 0,
    this.sequence = 0,
  });

  final double radiusDip;
  final bool maximized;
  final bool snapped;
  final bool minimized;
  final int dpi;
  final int width;
  final int height;
  final int sequence;

  /// 直角状态：最大化 / Snap 时没有圆角轮廓。
  bool get isRectangular => radiusDip <= 0.5;

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return fallback;
  }

  static int _int(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  static bool _bool(Object? value) => value == true;

  /// 从 `taskscheduler/window` 的原生 map 解析；缺字段时用 [fallback]。
  static WindowShape fromMap(Object? raw, {WindowShape fallback = const WindowShape()}) {
    if (raw is! Map) return fallback;
    final radius = _double(raw['radiusDip'], fallback.radiusDip);
    return WindowShape(
      radiusDip: radius < 0 ? 0 : radius,
      maximized: _bool(raw['maximized']),
      snapped: _bool(raw['snapped']),
      minimized: _bool(raw['minimized']),
      dpi: _int(raw['dpi'], fallback.dpi),
      width: _int(raw['width'], fallback.width),
      height: _int(raw['height'], fallback.height),
      sequence: _int(raw['sequence'], fallback.sequence),
    );
  }

  WindowShape copyWith({
    double? radiusDip,
    bool? maximized,
    bool? snapped,
    bool? minimized,
    int? dpi,
    int? width,
    int? height,
    int? sequence,
  }) {
    return WindowShape(
      radiusDip: radiusDip ?? this.radiusDip,
      maximized: maximized ?? this.maximized,
      snapped: snapped ?? this.snapped,
      minimized: minimized ?? this.minimized,
      dpi: dpi ?? this.dpi,
      width: width ?? this.width,
      height: height ?? this.height,
      sequence: sequence ?? this.sequence,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowShape &&
      other.radiusDip == radiusDip &&
      other.maximized == maximized &&
      other.snapped == snapped &&
      other.minimized == minimized &&
      other.dpi == dpi &&
      other.width == width &&
      other.height == height &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(radiusDip, maximized, snapped, minimized, dpi,
      width, height, sequence);

  @override
  String toString() => 'WindowShape(radius=$radiusDip, max=$maximized, '
      'snap=$snapped, min=$minimized, dpi=$dpi, ${width}x$height, seq=$sequence)';
}

/// 原生会话/电源状态：锁屏与睡眠是两类独立原因。
///
/// "离开"= 锁屏 || 睡眠。睡眠恢复时若仍处于锁屏，用户还没回来，不能提前恢复。
/// [lockEventsRegistered]/[suspendEventsRegistered] 表达原生监听是否注册成功
/// （失败时带 Windows 错误码）；"没收到事件"不能当成"用户一直在"。
@immutable
class WindowPowerState {
  const WindowPowerState({
    this.locked = false,
    this.suspended = false,
    this.lockEventsRegistered = true,
    this.suspendEventsRegistered = true,
    this.lockEventsError = 0,
    this.suspendEventsError = 0,
    this.sequence = 0,
  });

  final bool locked;
  final bool suspended;

  /// 是否成功注册了锁屏/解锁（WM_WTSSESSION_CHANGE）与睡眠/恢复（WM_POWERBROADCAST）
  /// 监听。
  final bool lockEventsRegistered;
  final bool suspendEventsRegistered;

  /// 注册失败时的 Windows 错误码（GetLastError），0 表示没有错误。
  final int lockEventsError;
  final int suspendEventsError;

  /// 原生单调递增的状态序号：查询结果不得覆盖更晚的事件。
  final int sequence;

  /// 锁屏或睡眠任一项成立即为离开。
  bool get away => locked || suspended;

  bool get hasRegistrationFailure =>
      !lockEventsRegistered || !suspendEventsRegistered;

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static int _int(Object? value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  /// 从 `taskscheduler/window` 的原生 map 解析；缺字段时用 [fallback]。
  static WindowPowerState fromMap(
    Object? raw, {
    WindowPowerState fallback = const WindowPowerState(),
  }) {
    if (raw is! Map) return fallback;
    return WindowPowerState(
      locked: _bool(raw['locked'], fallback.locked),
      suspended: _bool(raw['suspended'], fallback.suspended),
      lockEventsRegistered:
          _bool(raw['lockEventsRegistered'], fallback.lockEventsRegistered),
      suspendEventsRegistered: _bool(
          raw['suspendEventsRegistered'], fallback.suspendEventsRegistered),
      lockEventsError: _int(raw['lockEventsError'], fallback.lockEventsError),
      suspendEventsError:
          _int(raw['suspendEventsError'], fallback.suspendEventsError),
      sequence: _int(raw['sequence'], fallback.sequence),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowPowerState &&
      other.locked == locked &&
      other.suspended == suspended &&
      other.lockEventsRegistered == lockEventsRegistered &&
      other.suspendEventsRegistered == suspendEventsRegistered &&
      other.lockEventsError == lockEventsError &&
      other.suspendEventsError == suspendEventsError &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(locked, suspended, lockEventsRegistered,
      suspendEventsRegistered, lockEventsError, suspendEventsError, sequence);

  @override
  String toString() => 'WindowPowerState(locked=$locked, suspended=$suspended, '
      'lockRegistered=$lockEventsRegistered, '
      'suspendRegistered=$suspendEventsRegistered, '
      'lockError=$lockEventsError, suspendError=$suspendEventsError, '
      'seq=$sequence)';
}

class DesktopWindow {
  /// 生产环境只有一个窗口端口（同一个 MethodChannel 只能有一个回调处理器）。
  /// 不传 [channel] 时返回进程内共享实例；测试传入假 channel 时得到独立实例。
  factory DesktopWindow({MethodChannel? channel}) {
    if (channel != null) return DesktopWindow._(channel);
    return _shared ??= DesktopWindow._(const MethodChannel('taskscheduler/window'));
  }

  DesktopWindow._(this._channel);

  static DesktopWindow? _shared;

  /// 是否使用进程内共享实例：共享实例的 notifier 由整个进程复用，不能因某个
  /// widget 的 dispose 被销毁。
  bool get isShared => identical(this, _shared);

  final MethodChannel _channel;

  /// 真实窗口是否最大化（由原生事件更新，包括系统快捷键造成的变化）。
  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// 真实窗口外形状态（圆角/直角、DPI、实际尺寸、状态序号）。
  final ValueNotifier<WindowShape> shape = ValueNotifier<WindowShape>(
    const WindowShape(),
  );

  /// 原生会话/电源状态（锁屏、睡眠与监听注册结果）。
  final ValueNotifier<WindowPowerState> power =
      ValueNotifier<WindowPowerState>(const WindowPowerState());

  /// 原生侧收到关闭请求（标题栏关闭按钮 / 菜单退出 / Alt+F4）。
  VoidCallback? onCloseRequested;

  Future<void> Function(bool away)? _onExecutionAwayChanged;

  /// 聚合后的离开状态变化：原生只报告锁屏/睡眠两类独立原因，这里去重并按到达
  /// 顺序串行回调。赋值时会把当前聚合状态补给新监听者（启动即锁屏也不会漏掉）。
  Future<void> Function(bool away)? get onExecutionAwayChanged =>
      _onExecutionAwayChanged;
  set onExecutionAwayChanged(Future<void> Function(bool away)? callback) {
    _onExecutionAwayChanged = callback;
    _publishExecutionAway();
  }

  bool _attached = false;
  bool _available = true;
  bool _disposed = false;

  /// 已应用的最新状态序号：初始化查询的迟到结果不得覆盖更新的事件。
  int _sequence = 0;

  /// 电源状态序号（与 [WindowShape.sequence] 独立）。
  int _powerSequence = 0;

  /// 最近一次投递出去的聚合离开状态；重复事件不重复回调。
  bool _awayDelivered = false;

  /// 离开/恢复回调串行队列：前一个事件处理完才轮到下一个。
  Future<void> _awayQueue = Future<void>.value();

  /// 当前聚合离开状态（锁屏 || 睡眠）。
  bool get executionAway => power.value.away;

  /// 注册原生事件并读取初始状态（形状 + 最大化 + 会话/电源）。
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _disposed = false;
    // 每次重新绑定都以本次查询为准：解绑期间残留的序号不能把新状态挡掉。
    _powerSequence = -1;
    _channel.setMethodCallHandler(_handleCall);
    final initial = await _invoke<dynamic>('windowShape');
    if (initial != null) _applyShape(initial, fromQuery: true);
    final initialMax = await _invoke<bool>('isMaximized');
    if (initialMax != null) maximized.value = initialMax;
    final initialPower = await _invoke<dynamic>('powerState');
    if (initialPower != null) _applyPower(initialPower);
  }

  void _applyShape(Object? raw, {bool fromQuery = false}) {
    final parsed = WindowShape.fromMap(raw, fallback: shape.value);
    // 查询结果只在本进程还没有更晚的状态时才采用。
    if (fromQuery && parsed.sequence < _sequence) return;
    if (!fromQuery && parsed.sequence < _sequence) return;
    _sequence = parsed.sequence;
    if (shape.value != parsed) shape.value = parsed;
    if (maximized.value != parsed.maximized) maximized.value = parsed.maximized;
  }

  void _applyPower(Object? raw) {
    final parsed = WindowPowerState.fromMap(raw, fallback: power.value);
    // 查询结果与事件共用一个序号：迟到的查询结果不得覆盖更晚的事件。
    if (parsed.sequence < _powerSequence) return;
    _powerSequence = parsed.sequence;
    if (power.value != parsed) power.value = parsed;
    _publishExecutionAway();
  }

  /// 把聚合后的"离开"状态串行投递给监听者；状态没变就不重复回调。
  void _publishExecutionAway() {
    final callback = _onExecutionAwayChanged;
    if (callback == null || _disposed) return;
    final away = power.value.away;
    if (away == _awayDelivered) return;
    _awayDelivered = away;
    _awayQueue = _awayQueue.then((_) async {
      if (_disposed) return;
      await callback(away);
    }).catchError((Object error, StackTrace stack) {
      // 一次回调失败（例如控制器已释放）不能卡住后续的离开/恢复事件。
      debugPrint('execution away callback failed: $error');
    });
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'windowShapeChanged':
        _applyShape(call.arguments);
      case 'maximizedChanged':
        maximized.value = call.arguments == true;
      case 'powerStateChanged':
        _applyPower(call.arguments);
      case 'closeRequested':
        onCloseRequested?.call();
    }
    return null;
  }

  /// 启用/停用关闭守卫：启用后原生关闭请求先交给 Dart 统一关闭流程。
  Future<void> setCloseGuard(bool enabled) =>
      _invoke<void>('setCloseGuard', enabled);

  Future<void> minimize() => _invoke<void>('minimize');

  Future<void> toggleMaximize() => _invoke<void>('toggleMaximize');

  Future<void> restore() => _invoke<void>('restore');

  /// 请求关闭（原生发回 closeRequested，走统一保存流程）。
  Future<void> requestClose() => _invoke<void>('requestClose');

  /// 保存完成后真正销毁窗口。
  Future<void> confirmClose() => _invoke<void>('confirmClose');

  /// 报告可拖动标题栏区域的物理像素矩形（相对客户区左上角）。
  Future<void> setDragRegion(Rect rect) => _invoke<void>('setDragRegion', {
        'left': rect.left.round(),
        'top': rect.top.round(),
        'right': rect.right.round(),
        'bottom': rect.bottom.round(),
      });

  Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    if (!_available) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // 单元/Widget 测试没有原生 runner：保持可用但不做任何事。
      _available = false;
      return null;
    } on PlatformException {
      return null;
    }
  }

  void dispose() {
    // 解绑后不再向已销毁的界面投递；重新 attach 的端口从当前查询结果重新同步。
    _disposed = true;
    _onExecutionAwayChanged = null;
    _awayDelivered = false;
    if (_attached) {
      _channel.setMethodCallHandler(null);
      _attached = false;
    }
    if (isShared) return; // 共享端口由进程复用，不销毁 notifier。
    maximized.dispose();
    shape.dispose();
    power.dispose();
  }
}
