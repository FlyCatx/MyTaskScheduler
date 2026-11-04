// 关闭流程：写入失败时必须能取消/重试/明确放弃；打开的弹窗不能被主窗口关闭绕过。
//
// 通过真正的通道消息触发 closeRequested，并截获 confirmClose，断言的是窗口层
// 实际收到的命令，而不是某个按钮是否存在。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/model/session.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/ui/app_shell.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';

import '../support/test_support.dart';

class _FailingStore extends InMemorySessionRepository {
  bool fail = false;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    if (fail) throw StateError('模拟磁盘只读');
    return super.saveConversation(conversation);
  }
}

const _channelName = 'taskscheduler/window';

void main() {
  late _FailingStore store;
  late String? lastWindowCall;

  Future<AppController> pumpShell(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store = _FailingStore();
    await seedConversation(store);
    final controller = AppController(engine: FakeScheduleEngine(), store: store);
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(
        controller: controller,
        settings: makeTestSettingsController(),
      ),
    ));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> deliverClose(WidgetTester tester) async {
    final data = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('closeRequested', true));
    await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(_channelName, data, (_) {});
    await tester.pumpAndSettle();
  }

  setUp(() {
    TsColors.apply(Brightness.light);
    lastWindowCall = null;
  });

  testWidgets('保存失败时关闭可取消，恢复后重试才真正关闭', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (call) async {
        lastWindowCall = call.method;
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null));

    final controller = await pumpShell(tester);
    store.fail = true;
    await controller.updateDraft('关闭前尚未保存的草稿');
    await tester.pump();
    expect(controller.errorMessage, contains('草稿未能写入'));

    await deliverClose(tester);
    expect(find.text('保存失败，暂不能退出'), findsOneWidget);
    expect(lastWindowCall, isNot('confirmClose'),
        reason: '写入失败时不能无条件销毁窗口');

    // 取消退出：窗口继续工作，草稿仍在。
    await tester.tap(find.byKey(const Key('close-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，暂不能退出'), findsNothing);
    expect(lastWindowCall, isNot('confirmClose'));
    expect(controller.conversation!.draftText, '关闭前尚未保存的草稿');

    // 仍失败时点重试：再次停在同一个对话框。
    await deliverClose(tester);
    await tester.tap(find.byKey(const Key('close-retry')));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，暂不能退出'), findsOneWidget);

    // 恢复写入后重试：真正发出 confirmClose。
    store.fail = false;
    await tester.tap(find.byKey(const Key('close-retry')));
    await tester.pumpAndSettle();
    expect(lastWindowCall, 'confirmClose');
    expect(find.text('保存失败，暂不能退出'), findsNothing);
  });

  testWidgets('明确放弃后关闭，不把失败当成功', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (call) async {
        lastWindowCall = call.method;
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null));

    final controller = await pumpShell(tester);
    store.fail = true;
    await controller.updateDraft('会被明确放弃的草稿');
    await tester.pump();

    await deliverClose(tester);
    expect(find.text('保存失败，暂不能退出'), findsOneWidget);
    await tester.tap(find.byKey(const Key('close-discard')));
    await tester.pumpAndSettle();
    expect(lastWindowCall, 'confirmClose');
  });

  testWidgets('有打开的弹窗时，关闭先交给该路由而不是直接销毁窗口', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (call) async {
        lastWindowCall = call.method;
        if (call.method == 'isMaximized') return false;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null));

    await pumpShell(tester);
    // 通过“应用 → 关于”打开设置窗口（一个真实路由）。
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于 TaskScheduler'));
    await tester.pumpAndSettle();
    expect(find.text('版本信息'), findsOneWidget);

    await deliverClose(tester);
    expect(lastWindowCall, isNot('confirmClose'),
        reason: '不能绕过设置窗口的未保存保护');
    expect(find.text('版本信息'), findsNothing, reason: '路由先被正常弹出');
  });
}
