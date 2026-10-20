// 自绘标题栏：布局、菜单项目、命令能力与窗口按钮语义。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/desktop_window.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/title_bar.dart';

class _Host extends StatefulWidget {
  const _Host({
    required this.window,
    this.onAbout,
    this.onExit,
    this.onToggle,
  });

  final DesktopWindow window;
  final VoidCallback? onAbout;
  final VoidCallback? onExit;
  final VoidCallback? onToggle;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final TextEditingController _text = TextEditingController(text: 'abc');
  final FocusNode _focus = FocusNode();
  bool _visible = true;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Column(
          children: [
            AppTitleBar(
              window: widget.window,
              sidebarVisible: _visible,
              onToggleSidebar: () {
                widget.onToggle?.call();
                setState(() => _visible = !_visible);
              },
              onOpenAbout: widget.onAbout ?? () {},
              onExit: widget.onExit ?? () {},
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 320,
                  child: TextField(
                    key: const Key('host-field'),
                    controller: _text,
                    focusNode: _focus,
                    autofocus: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<DesktopWindow> _pump(WidgetTester tester,
    {VoidCallback? onAbout,
    VoidCallback? onExit,
    VoidCallback? onToggle}) async {
  TsColors.apply(Brightness.light);
  addTearDown(() => TsColors.apply(Brightness.light));
  final window = DesktopWindow();
  addTearDown(window.dispose);
  await tester.pumpWidget(_Host(
    window: window,
    onAbout: onAbout,
    onExit: onExit,
    onToggle: onToggle,
  ));
  await tester.pumpAndSettle();
  return window;
}

void main() {
  testWidgets('左侧图标/菜单、右侧窗口按钮与提示语义齐全', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsOneWidget);
    expect(find.text('应用'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(find.byTooltip('最大化'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    // 关闭按钮使用红色危险语义。
    expect(find.byKey(const Key('titlebar-close')), findsOneWidget);
  });

  testWidgets('应用菜单只有关于/检查更新/退出，更新禁用且无管理命令', (tester) async {
    var about = 0;
    var exit = 0;
    await _pump(tester, onAbout: () => about++, onExit: () => exit++);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('关于 TaskScheduler'), findsOneWidget);
    expect(find.text('检查更新…'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    expect(find.textContaining('管理'), findsNothing);

    // 禁用项点击无效，菜单不关闭，也不会触发回调。
    await tester.tap(find.text('检查更新…'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('检查更新…'), findsOneWidget);

    await tester.tap(find.text('关于 TaskScheduler'));
    await tester.pumpAndSettle();
    expect(about, 1);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(exit, 1);
  });

  testWidgets('最大化图标跟随真实窗口状态', (tester) async {
    final window = await _pump(tester);
    expect(find.byTooltip('最大化'), findsOneWidget);
    window.maximized.value = true;
    await tester.pump();
    expect(find.byTooltip('还原'), findsOneWidget);
    window.maximized.value = false;
    await tester.pump();
    expect(find.byTooltip('最大化'), findsOneWidget);
  });

  testWidgets('侧边栏折叠后图标仍可见并可恢复', (tester) async {
    var toggles = 0;
    await _pump(tester, onToggle: () => toggles++);
    final toggle = find.byKey(const Key('titlebar-sidebar-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(toggles, 1);
    expect(toggle, findsOneWidget);
    expect(find.byTooltip('展开侧边栏'), findsOneWidget);
  });

  testWidgets('编辑菜单作用于打开前的文本目标，复制/剪切/全选/删除走命令路由',
      (tester) async {
    await _pump(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('host-field')));
    final controller = field.controller!;

    // 选区在打开菜单前设置；打开菜单不能把它丢掉。
    controller.selection =
        const TextSelection(baseOffset: 0, extentOffset: 3);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    for (final label in ['撤销', '重做', '剪切', '复制', '粘贴', '删除', '全选']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Ctrl+Z'), findsOneWidget);
    expect(find.text('Ctrl+A'), findsOneWidget);
    expect(controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
        reason: '打开菜单不能丢失文本选区');

    // 复制使用 Flutter 的文本命令；这里捕获剪贴板写入以证明选中内容被复制。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, 'abc');
    expect(controller.text, 'abc', reason: '复制不修改文本');

    // 全选：先折叠选区，再从菜单执行全选。
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3));

    // 删除：全选后删除整段文本。
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(controller.text, '');
  });
}
