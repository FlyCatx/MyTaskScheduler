// Windows 窗口能力端口。
//
// Dart 只描述“想做什么”（最小化、最大化/还原、关闭、上报拖动区域），真正
// 的窗口状态由 runner 的 Win32 实现负责；最大化状态由原生 WM_SIZE 事件
// 回传，不能只靠点击时翻转一个 bool。
//
// 在测试或缺少原生实现的环境里，所有调用都安全降级（no-op），不会阻塞界面。
//
// 主要类型：DesktopWindow。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindow {
  DesktopWindow({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('taskscheduler/window');

  final MethodChannel _channel;

  /// 真实窗口是否最大化（由原生事件更新，包括系统快捷键造成的变化）。
  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// 原生侧收到关闭请求（标题栏关闭按钮 / 菜单退出 / Alt+F4）。
  VoidCallback? onCloseRequested;

  bool _attached = false;
  bool _available = true;

  /// 注册原生事件并读取初始最大化状态。
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_handleCall);
    final initial = await _invoke<bool>('isMaximized');
    if (initial != null) maximized.value = initial;
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'maximizedChanged':
        maximized.value = call.arguments == true;
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
    if (_attached) {
      _channel.setMethodCallHandler(null);
      _attached = false;
    }
    maximized.dispose();
  }
}
