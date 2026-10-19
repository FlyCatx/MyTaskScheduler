// 真实 DLL 测试的公共准备（bridge_live_test / settings_bridge_integration_test 共用）。
//
// 两件事：
//   * [findBridgeDir]：在常见的构建目录里找到 `ts_bridge.dll`（找不到则由调用方 skip）；
//   * [stageNativeLibs]：把 `ts_bridge.dll` 与 `libcurl-x64.dll` 复制到测试进程的工作目录。
//
// 为什么必须复制到工作目录：`libcurl-x64.dll` 是 `ts_bridge.dll` 的导入依赖，Windows 按
// 标准搜索顺序（应用目录、系统目录、**当前目录**、PATH）解析，而不会搜索被加载 DLL 自身
// 所在目录。复制时只在此文件缺失或大小不同时才写，且不删除——测试文件并发运行，
// 删除会让另一个文件正要加载的 DLL 消失。
import 'dart:io';

/// 返回包含 `ts_bridge.dll` 的目录（绝对路径），找不到返回 null。
String? findBridgeDir() {
  final candidates = <String>[
    '${Directory.current.parent.path}${Platform.pathSeparator}build-flutter'
        '${Platform.pathSeparator}Release',
    '${Directory.current.path}${Platform.pathSeparator}..'
        '${Platform.pathSeparator}build-flutter${Platform.pathSeparator}Release',
  ];
  for (final c in candidates) {
    final dll = File('$c${Platform.pathSeparator}ts_bridge.dll');
    if (dll.existsSync()) return Directory(c).absolute.path;
  }
  return null;
}

/// 把原生运行库 stage 到 [Directory.current]，返回该目录。
Future<String> stageNativeLibs(String bridgeDir) async {
  final target = Directory.current.path;
  for (final name in ['ts_bridge.dll', 'libcurl-x64.dll']) {
    final source = File('$bridgeDir${Platform.pathSeparator}$name');
    if (!source.existsSync()) continue;
    final dest = File('$target${Platform.pathSeparator}$name');
    if (dest.existsSync() && dest.lengthSync() == source.lengthSync()) continue;
    try {
      await source.copy(dest.path);
    } on FileSystemException {
      // 另一个测试文件正在复制或持有同一个 DLL；使用已存在的副本。
    }
  }
  return target;
}

