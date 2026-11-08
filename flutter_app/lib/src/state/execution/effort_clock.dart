// 为执行计时提供 UTC 墙钟与单调计时读数。
// 主要类型：EffortClock、SystemEffortClock。经过时长只用单调读数；
// 睡眠造成的时钟差异仍需交给用户校正。

/// 计时器依赖的时钟抽象。
abstract class EffortClock {
  /// 当前墙钟（UTC）。只用于持久化时间戳与检测漂移，不用于计算经过时长。
  DateTime get nowUtc;

  /// 单调递增读数。只用于计算进程内经过时长。
  Duration get monotonic;
}

/// 生产环境时钟：UTC 墙钟 + 进程启动以来的单调读数。
class SystemEffortClock implements EffortClock {
  SystemEffortClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  DateTime get nowUtc => DateTime.now().toUtc();

  @override
  Duration get monotonic => _stopwatch.elapsed;
}

