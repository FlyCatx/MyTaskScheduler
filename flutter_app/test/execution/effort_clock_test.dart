// 可注入时钟测试：墙钟与单调读数分离推进，用于构造人工可算的时间轴。

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_clock.dart';

void main() {
  test('正常流逝同时推进墙钟与单调时钟', () {
    final clock = FakeEffortClock(startUtc: DateTime.utc(2026, 11, 4, 1));
    clock.advance(const Duration(seconds: 90));
    expect(clock.nowUtc, DateTime.utc(2026, 11, 4, 1, 1, 30));
    expect(clock.monotonic, const Duration(seconds: 90));
  });

  test('jumpWall 只改墙钟，模拟系统时间被修改', () {
    final clock = FakeEffortClock(startUtc: DateTime.utc(2026, 11, 4, 1));
    clock.jumpWall(const Duration(hours: -2));
    expect(clock.nowUtc, DateTime.utc(2026, 11, 3, 23));
    expect(clock.monotonic, Duration.zero,
        reason: '单调时钟不会因为系统时间回拨而倒退');
  });

  test('冻结单调时钟可模拟睡眠，恢复后继续前进', () {
    final clock = FakeEffortClock(startUtc: DateTime.utc(2026, 11, 4, 1));
    clock.freezeMonotonic();
    clock.advance(const Duration(hours: 2));
    expect(clock.nowUtc, DateTime.utc(2026, 11, 4, 3));
    expect(clock.monotonic, Duration.zero);
    expect(clock.monotonicFrozen, true);

    clock.resumeMonotonic();
    clock.advance(const Duration(seconds: 5));
    expect(clock.monotonic, const Duration(seconds: 5));
  });

  test('负的流逝被忽略，保护时长不为负', () {
    final clock = FakeEffortClock(startUtc: DateTime.utc(2026, 11, 4, 1));
    clock.advance(const Duration(seconds: -10));
    expect(clock.nowUtc, DateTime.utc(2026, 11, 4, 1));
    expect(clock.monotonic, Duration.zero);
  });

  test('系统时钟是真实时间的包装且单调读数非负', () {
    final clock = SystemEffortClock();
    expect(clock.nowUtc.isUtc, true);
    expect(clock.monotonic.isNegative, false);
  });
}
