// Windows 锁屏/睡眠事件接线：原生独立原因 → 窗口端口聚合去重 → 串行转交控制器。
//
// 覆盖：
// - 原生 powerState 查询与装配（注册失败可见、无原生实现时安全降级）；
// - 锁屏/解锁、睡眠/恢复两类原因只改变自己那一位，离开状态 = 锁屏 || 睡眠；
// - 重复广播幂等，睡眠+锁屏重叠时不会因其中一类恢复就认为用户已回来；
// - 最小化/失焦/窗口外形变化不是离开原因，不触发 onAppSuspended；
// - 事件按到达顺序串行处理，避免 pause/checkpoint/resume 互相覆盖；
// - AppShell 把聚合后的离开状态转交 AppController.onAppSuspended/onAppResumed。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/desktop_window.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/app_notice.dart';

import '../execution/execution_test_support.dart';
import '../support/test_support.dart';

Map<String, Object?> _powerState({
  bool locked = false,
  bool suspended = false,
  bool lockRegistered = true,
  bool suspendRegistered = true,
  int lockError = 0,
  int suspendError = 0,
  int sequence = 0,
}) =>
    <String, Object?>{
      'locked': locked,
      'suspended': suspended,
      'lockEventsRegistered': lockRegistered,
      'suspendEventsRegistered': suspendRegistered,
      'lockEventsError': lockError,
      'suspendEventsError': suspendError,
      'sequence': sequence,
    };

/// 记录控制器收到的离开/恢复调用，不依赖真实计时器。
class _RecordingController extends AppController {
  _RecordingController({required super.engine, required super.store});

  final List<String> awayCalls = <String>[];

  @override
  Future<void> onAppSuspended() async {
    awayCalls.add('suspend');
  }

  @override
  Future<void> onAppResumed() async {
    awayCalls.add('resume');
  }
}

/// 在独立假 channel 上创建窗口端口并完成 attach，返回窗口与发送事件的辅助函数。
Future<(DesktopWindow, Future<void> Function(Map<String, Object?>))>
    _attachFakeWindow(WidgetTester tester, String channelName,
        {Map<String, Object?>? initialPower}) async {
  final channel = MethodChannel(channelName);
  final window = DesktopWindow(channel: channel);
  addTearDown(window.dispose);
  final messenger = tester.binding.defaultBinaryMessenger;
  final query = initialPower ?? _powerState();
  messenger.setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'windowShape':
        return <String, Object?>{
          'radiusDip': 18.0,
          'maximized': false,
          'snapped': false,
          'minimized': false,
          'dpi': 96,
          'width': 1200,
          'height': 800,
          'sequence': 1,
        };
      case 'isMaximized':
        return false;
      case 'powerState':
        return query;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await window.attach();

  Future<void> send(Map<String, Object?> state) async {
    await messenger.handlePlatformMessage(
      channelName,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall('powerStateChanged', state)),
      (_) {},
    );
  }

  return (window, send);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppNotices.instance.resetForTest();
  });
  tearDown(() {
    AppNotices.instance.resetForTest();
  });

  group('WindowPowerState 解析', () {
    test('缺字段回退；离开状态 = 锁屏 || 睡眠', () {
      const fallback = WindowPowerState();
      expect(fallback.away, isFalse);
      expect(fallback.hasRegistrationFailure, isFalse);
      expect(WindowPowerState.fromMap(null), fallback);

      final locked = WindowPowerState.fromMap(
        <String, Object?>{'locked': true},
        fallback: fallback,
      );
      expect(locked.locked, isTrue);
      expect(locked.suspended, isFalse);
      expect(locked.away, isTrue);
      // 缺注册字段时沿用 fallback（默认已注册），不能凭空报错。
      expect(locked.hasRegistrationFailure, isFalse);

      final suspended = WindowPowerState.fromMap(
        <String, Object?>{'suspended': true},
        fallback: fallback,
      );
      expect(suspended.away, isTrue);

      final both = WindowPowerState.fromMap(
        <String, Object?>{'locked': true, 'suspended': true},
        fallback: fallback,
      );
      expect(both.away, isTrue);
    });

    test('解析注册失败与 Windows 错误码', () {
      final parsed = WindowPowerState.fromMap(<String, Object?>{
        'locked': false,
        'suspended': false,
        'lockEventsRegistered': false,
        'suspendEventsRegistered': false,
        'lockEventsError': 5,
        'suspendEventsError': 87,
        'sequence': 3,
      });
      expect(parsed.hasRegistrationFailure, isTrue);
      expect(parsed.lockEventsRegistered, isFalse);
      expect(parsed.lockEventsError, 5);
      expect(parsed.suspendEventsError, 87);
      expect(parsed.sequence, 3);
    });
  });

  group('DesktopWindow 离开原因聚合', () {
    testWidgets('锁屏/睡眠独立原因 → 聚合去重；一类恢复不算回来', (tester) async {
      final (window, send) =
          await _attachFakeWindow(tester, 'taskscheduler/window-power-a');
      final delivered = <bool>[];
      window.onExecutionAwayChanged = (away) async {
        delivered.add(away);
      };
      await tester.pump();

      // 锁屏：离开。
      await send(_powerState(locked: true, sequence: 1));
      await tester.pump();
      expect(window.power.value.locked, isTrue);
      expect(delivered, <bool>[true]);

      // 重复锁屏广播：幂等，不重复暂停。
      await send(_powerState(locked: true, sequence: 2));
      await tester.pump();
      expect(delivered, <bool>[true]);

      // 睡眠叠加在锁屏上：已经是离开，不重复。
      await send(_powerState(locked: true, suspended: true, sequence: 3));
      await tester.pump();
      expect(window.power.value.suspended, isTrue);
      expect(delivered, <bool>[true]);

      // 只解除锁屏但仍在睡眠：用户还没回来，不能提前恢复。
      await send(_powerState(locked: false, suspended: true, sequence: 4));
      await tester.pump();
      expect(delivered, <bool>[true]);

      // 睡眠恢复：这时候才回到前台。
      await send(_powerState(sequence: 5));
      await tester.pump();
      expect(delivered, <bool>[true, false]);

      // 重复恢复广播：幂等。
      await send(_powerState(sequence: 6));
      await tester.pump();
      expect(delivered, <bool>[true, false]);
    });

    testWidgets('睡眠+锁屏重叠：先恢复睡眠仍保持离开，解锁后才恢复',
        (tester) async {
      final (window, send) =
          await _attachFakeWindow(tester, 'taskscheduler/window-power-b');
      final delivered = <bool>[];
      window.onExecutionAwayChanged = (away) async {
        delivered.add(away);
      };
      await tester.pump();

      await send(_powerState(locked: true, sequence: 1));
      await send(_powerState(locked: true, suspended: true, sequence: 2));
      await tester.pump();
      expect(delivered, <bool>[true]);

      // 恢复睡眠，但用户仍锁着屏：不能算回来。
      await send(_powerState(locked: true, sequence: 3));
      await tester.pump();
      expect(delivered, <bool>[true]);

      await send(_powerState(sequence: 4));
      await tester.pump();
      expect(delivered, <bool>[true, false]);
    });

    testWidgets('最小化/外形变化不是离开原因', (tester) async {
      final (window, send) =
          await _attachFakeWindow(tester, 'taskscheduler/window-power-c');
      final delivered = <bool>[];
      window.onExecutionAwayChanged = (away) async {
        delivered.add(away);
      };
      await tester.pump();

      final messenger = tester.binding.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'taskscheduler/window-power-c',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('windowShapeChanged', <String, Object?>{
            'radiusDip': 0.0,
            'maximized': true,
            'snapped': false,
            'minimized': false,
            'sequence': 9,
          }),
        ),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        'taskscheduler/window-power-c',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('maximizedChanged', true)),
        (_) {},
      );
      await tester.pump();

      // 窗口事件只更新窗口状态，不产生离开/恢复。
      expect(delivered, isEmpty);
      expect(window.maximized.value, isTrue);
      expect(window.power.value.away, isFalse);
    });

    testWidgets('事件串行处理：前一个恢复完成前不开始下一个暂停', (tester) async {
      final (window, send) =
          await _attachFakeWindow(tester, 'taskscheduler/window-power-d');
      final gate = Completer<void>();
      final log = <String>[];
      window.onExecutionAwayChanged = (away) async {
        log.add('start:$away');
        if (away) await gate.future;
        log.add('end:$away');
      };
      await tester.pump();

      await send(_powerState(locked: true, sequence: 1));
      await tester.pump();
      // 暂停回调被门闩挂起；恢复事件已到，但必须排队等待。
      expect(log, <String>['start:true']);

      await send(_powerState(sequence: 2));
      await tester.pump();
      expect(log, <String>['start:true'],
          reason: '恢复事件不能和暂停回调并发执行');

      gate.complete();
      await tester.pumpAndSettle();
      expect(log, <String>['start:true', 'end:true', 'start:false', 'end:false']);
    });

    testWidgets('原生注册失败：端口记录原因，不伪造离开事件', (tester) async {
      final (window, send) = await _attachFakeWindow(
        tester,
        'taskscheduler/window-power-e',
        initialPower: _powerState(lockRegistered: false, lockError: 5),
      );
      final delivered = <bool>[];
      window.onExecutionAwayChanged = (away) async {
        delivered.add(away);
      };
      await tester.pump();

      expect(window.power.value.lockEventsRegistered, isFalse);
      expect(window.power.value.lockEventsError, 5);
      expect(window.power.value.hasRegistrationFailure, isTrue);
      // 睡眠监听仍可用；锁屏事件永远不会到达，也不能凭空产生。
      await send(_powerState(
        suspended: true,
        lockRegistered: false,
        lockError: 5,
        sequence: 1,
      ));
      await tester.pump();
      expect(delivered, <bool>[true]);
    });

    // 用普通 test 而不是 testWidgets：真实（未 mock）通道在 FakeAsync 里等不到
    // 平台响应；单元测试环境没有原生实现，attach 必须安全降级。
    test('没有原生实现时 attach 安全降级', () async {
      final window = DesktopWindow(
        channel: const MethodChannel('taskscheduler/window-power-missing'),
      );
      addTearDown(window.dispose);
      await window.attach();
      expect(window.power.value.away, isFalse);
      expect(window.power.value.hasRegistrationFailure, isFalse);
    });
  });

  /// 用独立窗口端口（假 channel）装配 AppShell，返回投递原生事件的函数。
  ///
  /// 每个测试使用自己的 channel 与端口：共享实例在多个测试间会保留状态，
  /// 单独断言"事件是否转交控制器"时不需要也不应该承受这种耦合。
  Future<_ShellHarness> pumpShell(
    WidgetTester tester,
    AppController controller, {
    required Map<String, Object?> initialPower,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final channel = MethodChannel('taskscheduler/window-test-shell-'
        '${DateTime.now().microsecondsSinceEpoch}');
    final window = DesktopWindow(channel: channel);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'windowShape':
          return <String, Object?>{
            'radiusDip': 18.0,
            'maximized': false,
            'sequence': 1,
          };
        case 'isMaximized':
          return false;
        case 'powerState':
          return initialPower;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    // 卸载 Shell 会 dispose 注入的端口；放在控制器 dispose 之后注册，保证先解绑。
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(
        controller: controller,
        settings: makeTestSettingsController(),
        window: window,
      ),
    ));
    await tester.pumpAndSettle();

    return _ShellHarness(
      channelName: channel.name,
      send: (Map<String, Object?> state) async {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec()
              .encodeMethodCall(MethodCall('powerStateChanged', state)),
          (_) {},
        );
        await tester.pumpAndSettle();
      },
    );
  }

  group('AppShell 接线上报控制器', () {
    testWidgets('锁屏/睡眠经窗口端口转交 onAppSuspended/onAppResumed',
        (tester) async {
      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          _RecordingController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      addTearDown(controller.dispose);

      final harness = await pumpShell(
        tester,
        controller,
        initialPower: _powerState(sequence: 100),
      );
      final send = harness.send;
      expect(controller.awayCalls, isEmpty);

      await send(_powerState(locked: true, sequence: 101));
      expect(controller.awayCalls, <String>['suspend']);

      // 睡眠叠加：已是离开，不重复暂停。
      await send(_powerState(locked: true, suspended: true, sequence: 102));
      expect(controller.awayCalls, <String>['suspend']);

      // 先恢复睡眠但仍在锁屏：不算回来。
      await send(_powerState(locked: true, sequence: 103));
      expect(controller.awayCalls, <String>['suspend']);

      await send(_powerState(sequence: 104));
      expect(controller.awayCalls, <String>['suspend', 'resume']);

      // 重复事件幂等。
      await send(_powerState(sequence: 105));
      expect(controller.awayCalls, <String>['suspend', 'resume']);

      // 窗口最大化/最小化/失焦不是离开原因：通道里没有对应事件，外壳也不该
      // 因为窗口状态变化去暂停计时。
      final messenger = tester.binding.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        harness.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('maximizedChanged', true),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(controller.awayCalls, <String>['suspend', 'resume']);
    });

    testWidgets('窗口卸载后晚到的离开事件不再调用控制器', (tester) async {
      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          _RecordingController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      addTearDown(controller.dispose);

      final harness = await pumpShell(
        tester,
        controller,
        initialPower: _powerState(sequence: 100),
      );
      final send = harness.send;
      await send(_powerState(locked: true, sequence: 101));
      expect(controller.awayCalls, <String>['suspend']);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await send(_powerState(locked: true, sequence: 102));
      expect(controller.awayCalls, <String>['suspend'],
          reason: '窗口关闭/卸载后到达的事件必须被丢弃');
    });

    testWidgets('锁屏时正在运行的计时暂停；tick 继续也不自动恢复', (tester) async {
      final fixture = await TimerFixture.create(memory: true);
      addTearDown(fixture.close);
      final started = await fixture.timer.start(taskRef());
      expect(started.ok, isTrue);
      expect(fixture.timer.isRunning, isTrue);
      fixture.clock.advance(const Duration(seconds: 30));
      await fixture.timer.tick();

      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller = AppController(
        engine: FakeScheduleEngine(),
        store: store,
        timer: fixture.timer,
      );
      await controller.initialize();
      addTearDown(controller.dispose);

      final harness = await pumpShell(
        tester,
        controller,
        initialPower: _powerState(sequence: 100),
      );
      final send = harness.send;
      expect(fixture.timer.isRunning, isTrue);

      // 锁屏：即使 tick 一直在跑，也必须暂停并留下待校正区间。
      await send(_powerState(locked: true, sequence: 101));
      expect(fixture.timer.isRunning, isFalse);
      expect(fixture.timer.isPaused, isTrue);
      expect(fixture.timer.ledger.openCorrections, isNotEmpty);
      final pausedElapsed = fixture.timer.elapsed;

      // tick 继续：暂停状态不变，离开时间不计入工作。
      fixture.clock.advance(const Duration(minutes: 5));
      await fixture.timer.tick();
      await tester.pumpAndSettle();
      expect(fixture.timer.isRunning, isFalse);
      expect(fixture.timer.elapsed, pausedElapsed);

      // 恢复：只提示待校正，不自动续跑。
      await send(_powerState(sequence: 102));
      expect(fixture.timer.isRunning, isFalse);
      expect(fixture.timer.isPaused, isTrue);
    });

    testWidgets('原生注册失败时给出可见说明', (tester) async {
      final store = InMemorySessionRepository();
      await seedConversation(store);
      final controller =
          _RecordingController(engine: FakeScheduleEngine(), store: store);
      await controller.initialize();
      addTearDown(controller.dispose);

      await pumpShell(
        tester,
        controller,
        initialPower: _powerState(
          lockRegistered: false,
          lockError: 5,
          suspendRegistered: false,
          suspendError: 87,
          sequence: 100,
        ),
      );

      expect(find.text('无法接收系统锁屏或睡眠事件，离开期间计时可能不会自动暂停'),
          findsOneWidget);
      expect(find.textContaining('错误码 5'), findsOneWidget);
      expect(find.textContaining('错误码 87'), findsOneWidget);
    });
  });
}

/// 假窗口端口装配结果：channel 名用于投递窗口事件，send 投递电源状态事件。
class _ShellHarness {
  const _ShellHarness({required this.channelName, required this.send});

  final String channelName;
  final Future<void> Function(Map<String, Object?>) send;
}
