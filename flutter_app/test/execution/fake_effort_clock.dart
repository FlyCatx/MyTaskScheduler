import 'package:taskscheduler_flutter/src/state/execution/effort_clock.dart';

/// 测试时分别控制墙钟和单调读数，模拟时间回拨与睡眠。
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

  void advance(Duration duration) {
    if (duration.isNegative) return;
    _nowUtc = _nowUtc.add(duration);
    if (!_frozen) _monotonic += duration;
  }

  void jumpWall(Duration delta) {
    _nowUtc = _nowUtc.add(delta);
  }

  void setWallClock(DateTime utc) {
    _nowUtc = utc.toUtc();
  }

  void freezeMonotonic() {
    _frozen = true;
  }

  void resumeMonotonic() {
    _frozen = false;
  }

  bool get monotonicFrozen => _frozen;
}
