// 执行层测试的公共夹具：隔离临时目录、可注入时钟、固定东八区本地时间。
//
// 约定：
//   * 每个测试使用独立的 `<package>/test_tmp/exec_*` 目录，结束时删除；
//   * 时钟一律用 FakeEffortClock，时间轴人工可算；
//   * 本地时区用固定 +08:00，避免 CI 机器时区影响断言；
//   * 不依赖真实 DLL、不联网。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart' show TestFailure;
import 'package:taskscheduler_flutter/src/model/plan.dart' show Completion;
import 'package:taskscheduler_flutter/src/state/execution/effort_clock.dart';
import 'package:taskscheduler_flutter/src/state/execution/effort_stats.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_models.dart';
import 'package:taskscheduler_flutter/src/state/execution/execution_store.dart';
import 'package:taskscheduler_flutter/src/state/execution/timer_controller.dart';

/// 固定 +08:00（测试断言不受机器时区/DST 影响）。
const EffortLocalTime shanghaiLocalTime = FixedOffsetEffortLocalTime(
  offset: Duration(hours: 8),
  label: 'Asia/Shanghai (UTC+08:00)',
);

/// 测试时钟起点：2026-11-04（周三）本地 09:00 / UTC 01:00。
final DateTime testStartUtc = DateTime.utc(2026, 11, 4, 1);

Directory newTempDir(String label) {
  final base = '${Directory.current.path}${Platform.pathSeparator}test_tmp';
  final dir = Directory(
      '$base${Platform.pathSeparator}exec_${label}_${DateTime.now().microsecondsSinceEpoch}');
  dir.createSync(recursive: true);
  return dir;
}

void deleteDirQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // Windows 上文件句柄可能延迟释放：清理失败不影响断言结果。
  }
}

/// 一次计时器测试的完整装配。
class TimerFixture {
  TimerFixture({
    required this.directory,
    required this.store,
    required this.clock,
    required this.timer,
  });

  final Directory directory;
  final ExecutionStore store;
  final FakeEffortClock clock;
  final TimerController timer;

  /// 创建夹具并 load()。默认关闭 autoTick，测试手动调用 [TimerController.tick]。
  ///
  /// [memory] 为 true 时使用内存存储（UI 测试用，避免真实磁盘 IO 与 widget 测试
  /// 的伪异步时钟互相等待）。
  static Future<TimerFixture> create({
    Directory? directory,
    FakeEffortClock? clock,
    EffortLocalTime? localTime,
    Duration checkpointInterval = kDefaultCheckpointInterval,
    Duration tickGapTolerance = const Duration(minutes: 5),
    Duration driftTolerance = kClockDriftTolerance,
    Duration uiTickInterval = const Duration(seconds: 1),
    bool autoTick = false,
    bool load = true,
    bool memory = false,
  }) async {
    final dir = directory ?? newTempDir('timer');
    final fakeClock = clock ??
        FakeEffortClock(startUtc: testStartUtc);
    final store = memory ? ExecutionStore.memory() : ExecutionStore(dir);
    final timer = TimerController(
      store: store,
      clock: fakeClock,
      localTime: localTime ?? shanghaiLocalTime,
      checkpointInterval: checkpointInterval,
      tickGapTolerance: tickGapTolerance,
      driftTolerance: driftTolerance,
      uiTickInterval: uiTickInterval,
      autoTick: autoTick,
    );
    if (load) await timer.load();
    return TimerFixture(
      directory: dir,
      store: store,
      clock: fakeClock,
      timer: timer,
    );
  }

  Future<void> close() async {
    await timer.shutdown();
    timer.dispose();
    deleteDirQuietly(directory);
  }
}

/// 常用任务引用（默认带 2 小时预估基线）。
ExecutionTaskRef taskRef({
  String conversationId = 'conv-1',
  String taskId = 'task-a',
  String name = '整理需求',
  String planVersionId = 'ver-1',
  int planRevision = 1,
  double? estimateHours = 2,
  String? lineageRootId,
}) {
  return ExecutionTaskRef(
    conversationId: conversationId,
    taskId: taskId,
    taskName: name,
    planVersionId: planVersionId,
    planRevision: planRevision,
    estimateHours: estimateHours,
    lineageRootId: lineageRootId,
  );
}

/// 常用任务上下文。
ExecutionTaskInfo taskInfo({
  String conversationId = 'conv-1',
  String taskId = 'task-a',
  String name = '整理需求',
  String planVersionId = 'ver-1',
  int planRevision = 1,
  double? currentEstimateHours,
  Completion? completion,
  String? deadline,
  String? lineageRootId,
  DateTime? plannedStartUtc,
  DateTime? plannedEndUtc,
}) {
  return ExecutionTaskInfo(
    conversationId: conversationId,
    taskId: taskId,
    name: name,
    planVersionId: planVersionId,
    planRevision: planRevision,
    currentEstimateHours: currentEstimateHours,
    completion: completion,
    deadline: deadline,
    lineageRootId: lineageRootId,
    plannedStartUtc: plannedStartUtc,
    plannedEndUtc: plannedEndUtc,
  );
}

ExecutionConversationInfo conversationInfo({
  String id = 'conv-1',
  String title = '顺序表实验',
}) =>
    ExecutionConversationInfo(id: id, title: title);

/// 构造一条“计时区间”记录（直接写账本用，不经过控制器）。
ExecutionRecord recordWithInterval({
  String recordId = 'rec-1',
  String conversationId = 'conv-1',
  String taskId = 'task-a',
  String taskName = '整理需求',
  String planVersionId = 'ver-1',
  int planRevision = 1,
  double? estimateBaselineHours,
  required DateTime startUtc,
  required DateTime endUtc,
  String lineageRootId = '',
}) {
  return ExecutionRecord(
    recordId: recordId,
    conversationId: conversationId,
    taskId: taskId,
    taskName: taskName,
    lineageRootId: lineageRootId.isEmpty ? taskId : lineageRootId,
    planVersionId: planVersionId,
    planRevision: planRevision,
    estimateBaselineHours: estimateBaselineHours,
    createdAtUtc: startUtc,
    timeZoneName: 'Asia/Shanghai (UTC+08:00)',
    timeZoneOffsetMinutes: 480,
    intervals: <ExecutionInterval>[
      ExecutionInterval(startUtc: startUtc, endUtc: endUtc),
    ],
  );
}

/// 本地墙钟时间 → UTC（固定 +8 时区）。
DateTime shanghaiUtc(int year, int month, int day,
        [int hour = 0, int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).subtract(const Duration(hours: 8));

/// 断言 Duration 相等（按微秒，避免 toString 干扰）。
void expectDuration(Duration actual, Duration expected, {String? reason}) {
  if (actual.inMicroseconds != expected.inMicroseconds) {
    throw TestFailure(
        '${reason ?? 'Duration'} 期望 $expected（${expected.inMicroseconds}µs），'
        '实际 $actual（${actual.inMicroseconds}µs）');
  }
}
