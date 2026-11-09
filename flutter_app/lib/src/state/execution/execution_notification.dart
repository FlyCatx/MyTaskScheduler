// 可操作执行通知的 Dart 端口与原生适配（0.5.0 任务 13）。
//
// 业务层（ExecutionDeadlineController）只依赖 [ExecutionNotificationPort]：
//   * 原生能力是否就绪由 [prepare] 返回记录，失败不阻止启动；
//   * 每次 [show] 都返回“系统是否接受”的真实结果，调用方必须记账；
//   * [takeActionJson] 只返回**携带身份**的 JSON；无法识别身份时忽略，绝不按
//     “最后一次通知”猜测点击目标；
//   * 旧 DLL / 尚未交付新符号时，动态分派捕获 NoSuchMethodError 并降级为不可用，
//     由业务层改用前台等价操作。
//
// native-bridge 的最终契约（Dart 侧命名以此为准）：
//   NativeGateway.prepareExecutionNotifications({String appUserModelId, String? exePath})
//       → ExecutionNotificationsStatus{ok, errorKind, error, ...}
//   NativeGateway.showExecutionNotification({required String title, required String body,
//       required Map<String, dynamic> payload}) → ExecutionNotificationResult{accepted, ...}
//   NativeGateway.takeExecutionActionJson() → String?（{"action":"extend|finish|open",
//       "taskId","executionId","deadline"}）
//
// 为了在 native-bridge 落地前保持本仓库 `flutter analyze` 干净，这里通过 dynamic
// 分派调用上述成员：方法不存在时视为“原生不可用”，真实落地后无需改业务代码。

import 'dart:convert';

import '../../ffi/native_gateway.dart';

/// 本应用在 Windows 通知里的 AUMID（runner/main.cpp 与快捷方式使用同一值）。
const String kExecutionAppUserModelId = 'TaskScheduler.Desktop';

/// 一次通知投递的结果（系统/前台是否接受）。
class ExecutionNotificationAttempt {
  const ExecutionNotificationAttempt({
    required this.accepted,
    this.channel,
    this.errorKind,
    this.error,
  });

  /// 系统是否真正接受并显示。
  final bool accepted;

  /// 实际渠道（`winrt` 等）；未知时为 null。
  final String? channel;

  /// 失败类别（`unsupported` / `notPrepared` / `policy` / `winrt` / ...）。
  final String? errorKind;

  /// 可读失败原因（写入投递账本，界面可展示）。
  final String? error;

  static const ExecutionNotificationAttempt unavailable = ExecutionNotificationAttempt(
    accepted: false,
    errorKind: 'unsupported',
    error: '系统可操作通知不可用',
  );
}

/// 原生准备结果。
class ExecutionNotificationPreparation {
  const ExecutionNotificationPreparation({
    required this.ok,
    this.errorKind,
    this.error,
    this.channel,
  });

  final bool ok;
  final String? errorKind;
  final String? error;
  final String? channel;

  static const ExecutionNotificationPreparation unsupported =
      ExecutionNotificationPreparation(
    ok: false,
    errorKind: 'unsupported',
    error: '当前桥接库不支持可操作通知',
  );
}

/// 通知动作（由原生回调 JSON 解析；身份与投递时一致才允许执行）。
class ExecutionNotificationAction {
  const ExecutionNotificationAction({
    required this.action,
    required this.taskId,
    required this.executionId,
    required this.deadline,
  });

  /// `extend` / `finish` / `open`。
  final String action;
  final String taskId;
  final String executionId;

  /// 投递时写入的身份令牌，原样回传；用于期限版本核对。
  final String deadline;

  bool get isExtend => action == 'extend';
  bool get isFinish => action == 'finish';
  bool get isOpen => action == 'open';

  /// 解析原生 JSON；字段缺失或动作未知时返回 null（不猜目标）。
  static ExecutionNotificationAction? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final j = Map<String, dynamic>.from(decoded);
      final action = (j['action'] as String?)?.trim().toLowerCase() ?? '';
      if (action != 'extend' && action != 'finish' && action != 'open') {
        return null;
      }
      final taskId = (j['taskId'] as String?)?.trim() ?? '';
      final executionId = (j['executionId'] as String?)?.trim() ?? '';
      if (taskId.isEmpty || executionId.isEmpty) return null;
      final deadline = j['deadline'];
      return ExecutionNotificationAction(
        action: action,
        taskId: taskId,
        executionId: executionId,
        deadline: deadline == null ? '' : '$deadline',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 可操作通知端口。
abstract class ExecutionNotificationPort {
  /// 原生能力是否就绪（准备失败时业务层直接走前台等价操作）。
  bool get supported;

  /// 一次性准备（快捷方式/协议/通道）；可重复调用，失败不抛异常。
  ExecutionNotificationPreparation prepare();

  /// 显示一条带身份与动作的通知；返回系统是否接受。
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  });

  /// 取出一个待处理的用户动作 JSON；没有返回 null。
  String? takeActionJson();
}

/// 原生桥接实现：动态分派，兼容“旧 DLL/尚未交付”的环境。
class NativeExecutionNotificationPort implements ExecutionNotificationPort {
  NativeExecutionNotificationPort(
    this._gateway, {
    this.appUserModelId = kExecutionAppUserModelId,
    String? exePath,
  }) : _exePath = exePath;

  final NativeGateway _gateway;
  final String appUserModelId;
  final String? _exePath;

  bool _prepared = false;
  bool _prepareOk = false;
  String? _prepareErrorKind;
  String? _prepareError;
  String? _channel;

  @override
  bool get supported => _prepareOk;

  String? get prepareError => _prepareError;
  String? get prepareErrorKind => _prepareErrorKind;
  String? get channel => _channel;

  @override
  ExecutionNotificationPreparation prepare() {
    if (_prepared) {
      return ExecutionNotificationPreparation(
        ok: _prepareOk,
        errorKind: _prepareErrorKind,
        error: _prepareError,
        channel: _channel,
      );
    }
    _prepared = true;
    try {
      final dynamic gateway = _gateway;
      final dynamic status = gateway.prepareExecutionNotifications(
        appUserModelId: appUserModelId,
        exePath: _exePath,
      );
      _prepareOk = _readBool(status, 'ok');
      _prepareErrorKind = _readString(status, 'errorKind');
      _prepareError = _readString(status, 'error');
      _channel = _readString(status, 'channel');
      if (!_prepareOk) {
        _prepareError ??= '系统可操作通知未就绪';
      }
    } catch (error) {
      // 旧 DLL / 尚未交付新符号：安安静静降级，由业务层走前台等价操作。
      _prepareOk = false;
      _prepareErrorKind = 'unsupported';
      _prepareError = '当前桥接库不支持可操作通知：$error';
    }
    return ExecutionNotificationPreparation(
      ok: _prepareOk,
      errorKind: _prepareErrorKind,
      error: _prepareError,
      channel: _channel,
    );
  }

  @override
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) {
    if (!_prepareOk) {
      prepare();
    }
    if (!_prepareOk) {
      return ExecutionNotificationAttempt(
        accepted: false,
        errorKind: _prepareErrorKind ?? 'notPrepared',
        error: _prepareError ?? '系统可操作通知未就绪',
      );
    }
    try {
      final dynamic gateway = _gateway;
      final dynamic result = gateway.showExecutionNotification(
        title: title,
        body: body,
        payload: payload,
      );
      final accepted = _readBool(result, 'accepted');
      return ExecutionNotificationAttempt(
        accepted: accepted,
        channel: _readString(result, 'channel'),
        errorKind: _readString(result, 'errorKind'),
        error: _readString(result, 'error'),
      );
    } catch (error) {
      return ExecutionNotificationAttempt(
        accepted: false,
        errorKind: 'unsupported',
        error: '发送系统通知失败：$error',
      );
    }
  }

  @override
  String? takeActionJson() {
    if (!_prepareOk) return null;
    try {
      final dynamic gateway = _gateway;
      final dynamic raw = gateway.takeExecutionActionJson();
      return raw is String && raw.trim().isNotEmpty ? raw : null;
    } catch (_) {
      return null;
    }
  }

  static bool _readBool(Object? target, String key) {
    if (target == null) return false;
    try {
      final dynamic value = target;
      final dynamic member = key == 'ok' ? value.ok : value.accepted;
      return member == true;
    } catch (_) {
      return false;
    }
  }

  static String? _readString(Object? target, String key) {
    if (target == null) return null;
    try {
      final dynamic value = target;
      final dynamic member = switch (key) {
        'errorKind' => value.errorKind,
        'error' => value.error,
        'channel' => value.channel,
        _ => null,
      };
      return member is String && member.trim().isNotEmpty ? member : null;
    } catch (_) {
      return null;
    }
  }
}

/// 完全不可用（测试或没有桥接库）：永远返回“未接受”，业务层据此走前台等价操作。
class DisabledExecutionNotificationPort implements ExecutionNotificationPort {
  const DisabledExecutionNotificationPort();

  @override
  bool get supported => false;

  @override
  ExecutionNotificationPreparation prepare() =>
      ExecutionNotificationPreparation.unsupported;

  @override
  ExecutionNotificationAttempt show({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) =>
      ExecutionNotificationAttempt.unavailable;

  @override
  String? takeActionJson() => null;
}
