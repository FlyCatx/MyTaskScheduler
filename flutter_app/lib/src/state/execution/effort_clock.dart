// 计时用的可注入时钟（R3-E3）。
//
// 计时规则：**进程内经过时长只用单调时钟**，持久化用 UTC。系统时间回拨/跳变
// 只影响“待校正区间”，不会产生负时长或巨额工时。测试通过 [FakeEffortClock] 注入
// 人工可算的时间轴：它把“墙钟”和“单调读数”分开推进，因此能精确复现回拨、跳变、
// 睡眠/锁屏导致的 wall-monotonic 漂移。
//
// 注意：`Stopwatch` 使用系统单调计数（Windows 上是 QPC），不随用户改时间而跳变；
// 但它是否跨睡眠继续走取决于平台，所以睡眠/锁屏不能靠单调时钟证明“没在工作”，
// 只能靠 wall-monotonic 漂移检测后交给用户校正。

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

/// 测试/仿真用时钟。
///
/// [advance] 同时推进墙钟与单调时钟（正常流逝）；[jumpWall] 只改墙钟（系统时间
/// 被修改）；[freezeMonotonic] 可模拟单调时钟不走的睡眠场景（先冻结再 jumpWall）。
class FakeEffortClock implements EffortClock {
  FakeEffortClock({
    DateTime? startUtc,
    Duration monotonic = Duration.zero,
    bool frozenMonotonic = false,
  })  : _nowUtc = (startUtc ?? DateTime.utc(2026, 11, 4, 9)).toUtc(),
        _monotonic = monotonic,
        _frozen = frozenMonotonic;

  DateTime _nowUtc;
  Duration _monotonic;
  bool _frozen;

  @override
  DateTime get nowUtc => _nowUtc;

  @override
  Duration get monotonic => _monotonic;

  /// 正常时间流逝：墙钟与单调时钟一起前进。
  void advance(Duration duration) {
    if (duration.isNegative) return;
    _nowUtc = _nowUtc.add(duration);
    if (!_frozen) _monotonic += duration;
  }

  /// 只改墙钟（模拟用户/系统把时间往前或往后拨）。
  void jumpWall(Duration delta) {
    _nowUtc = _nowUtc.add(delta);
  }

  /// 直接把墙钟设为某个绝对时刻（不回拨时可配合 [jumpWall]）。
  void setWallClock(DateTime utc) {
    _nowUtc = utc.toUtc();
  }

  /// 让单调时钟停止前进（模拟睡眠/锁屏时 QPC 不累计），直到 [resumeMonotonic]。
  void freezeMonotonic() {
    _frozen = true;
  }

  /// 恢复单调时钟前进。
  void resumeMonotonic() {
    _frozen = false;
  }

  bool get monotonicFrozen => _frozen;
}
