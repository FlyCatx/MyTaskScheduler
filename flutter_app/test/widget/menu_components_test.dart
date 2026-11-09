// 统一菜单、选择触发器、对话框动作和关闭键的组件级测试。
//
// 覆盖行为：
//   * 菜单是扁平的（elevation 0、主题 surface、Bézier 圆角 12、无阴影）；
//   * 菜单高度受可视区域限制，超出时内部滚动，键盘仍能选中最后一项；
//   * ↑/↓/Home/End + Enter/Space 选择；Esc/Tab 关闭并让焦点回到触发器；
//   * 禁用项不能选择，且不会关闭菜单；
//   * 长文本（会话名）省略而不撑破浮层；
//   * 当前项用 selected 勾选态；可空值选择（“全部会话”）能被正确上报；
//   * 对话框动作区的主/次/危险/轻量角色与禁用态；
//   * 统一关闭图标的 tooltip 与点击。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/ui/theme.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_menu.dart';
import 'package:taskscheduler_flutter/src/ui/widgets/bezier_ui.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      builder: (context, app) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(textScale)),
          child: app!,
        );
      },
      home: Scaffold(body: Center(child: child)),
    );

Widget _menuHost({
  required List<BezierMenuItem<String>> items,
  required void Function(String?) onResult,
  double width = 220,
  double? maxHeight,
}) {
  return _app(Builder(
    builder: (context) => TextButton(
      key: const Key('open-menu'),
      onPressed: () async {
        final result = await showBezierMenu<String>(
          context: context,
          globalPosition: const Offset(300, 200),
          items: items,
          width: width,
          maxHeight: maxHeight,
        );
        onResult(result);
      },
      child: const Text('打开'),
    ),
  ));
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-menu')));
  await tester.pumpAndSettle();
}

Finder get _panel => find.byKey(const Key('bezier-menu-panel'));

void main() {
  group('showBezierMenu', () {
    testWidgets('扁平样式：主题 surface、elevation 0、贝塞尔圆角 12', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var result = 'unset';
      await tester.pumpWidget(_menuHost(
        items: const [
          BezierMenuItem(value: 'a', label: '第一项'),
          BezierMenuItem(value: 'b', label: '第二项'),
        ],
        onResult: (value) => result = value ?? 'null',
      ));
      await _openMenu(tester);

      final material = tester.widget<Material>(_panel);
      expect(material.elevation, 0, reason: '菜单必须无阴影');
      expect(material.color, TsColors.surface);
      final shape = material.shape as BezierRoundedRectangleBorder;
      expect(shape.radius, 12);
      expect(find.text('第一项'), findsOneWidget);
      expect(result, 'unset');
    });

    testWidgets('高度受可视区域限制，超出时内部滚动并可选到最后一项', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final items = <BezierMenuItem<String>>[
        for (var i = 0; i < 20; i++)
          BezierMenuItem(value: 'item-$i', label: '项目 $i'),
      ];
      var result = 'unset';
      await tester.pumpWidget(
          _menuHost(items: items, onResult: (value) => result = value ?? 'null'));
      await _openMenu(tester);

      final panel = tester.getRect(_panel);
      expect(panel.top, greaterThanOrEqualTo(8),
          reason: '菜单不能从窗口上沿被裁掉');
      expect(panel.bottom, lessThanOrEqualTo(320 - 8),
          reason: '菜单必须完整落在可视区域内');
      expect(
        find.descendant(
            of: _panel, matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
        reason: '内容高于可视区域时菜单内部可滚动',
      );

      // 滚动到末尾并选择最后一项。
      await tester.drag(_panel, const Offset(0, -1200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('项目 19'));
      await tester.pumpAndSettle();
      expect(result, 'item-19');
    });

    testWidgets('键盘 ↓ 跳过禁用项、Enter 选择；Esc 关闭不选择', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = 'unset';
      var result = 'unset';
      await tester.pumpWidget(_menuHost(
        items: const [
          BezierMenuItem(value: 'a', label: '甲'),
          BezierMenuItem(value: 'b', label: '乙（禁用）', enabled: false),
          BezierMenuItem(value: 'c', label: '丙'),
        ],
        onResult: (value) {
          result = value ?? 'null';
          selected = value ?? 'null';
        },
      ));
      await _openMenu(tester);

      // 初始高亮第一项；↓ 跳过禁用的乙到丙；Enter 选丙。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'c');
      expect(selected, 'c');

      // 重新打开：Esc 关闭但不选择。
      result = 'unset';
      await _openMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(result, 'null', reason: 'Esc 应返回 null（未选择）');
    });

    testWidgets('Home/End 跳到首尾可用项，Space 选择', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var result = 'unset';
      await tester.pumpWidget(_menuHost(
        items: const [
          BezierMenuItem(value: 'a', label: '甲'),
          BezierMenuItem(value: 'b', label: '乙'),
          BezierMenuItem(value: 'c', label: '丙'),
        ],
        onResult: (value) => result = value ?? 'null',
      ));
      await _openMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(result, 'c');

      result = 'unset';
      await _openMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'a');
    });

    testWidgets('禁用项点击无效且不关闭菜单', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var result = 'unset';
      await tester.pumpWidget(_menuHost(
        items: const [
          BezierMenuItem(value: 'a', label: '可用项'),
          BezierMenuItem(value: 'b', label: '禁用项', enabled: false),
        ],
        onResult: (value) => result = value ?? 'null',
      ));
      await _openMenu(tester);
      await tester.tap(find.text('禁用项'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget, reason: '禁用项不应关闭菜单');
      expect(result, 'unset', reason: '禁用项不产生选择');
    });

    testWidgets('长文本省略而不撑破浮层宽度', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final longName = '一个非常非常长的会话标题' * 8;
      var result = 'unset';
      await tester.pumpWidget(_menuHost(
        items: [
          BezierMenuItem(value: 'long', label: longName),
          const BezierMenuItem(value: 'short', label: '短标题'),
        ],
        onResult: (value) => result = value ?? 'null',
        width: 240,
      ));
      await _openMenu(tester);
      expect(tester.takeException(), isNull, reason: '长标题不得溢出');
      final panel = tester.getRect(_panel);
      expect(panel.width, 240);
      final label = tester.widget<Text>(find.text(longName));
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      await tester.tap(find.text('短标题'));
      await tester.pumpAndSettle();
      expect(result, 'short');
    });

    testWidgets('当前项（selected）显示勾选态', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_menuHost(
        items: const [
          BezierMenuItem(value: 'a', label: '甲', selected: true),
          BezierMenuItem(value: 'b', label: '乙'),
        ],
        onResult: (_) {},
      ));
      await _openMenu(tester);
      final check = find.descendant(
          of: _panel, matching: find.byIcon(Icons.check));
      expect(check, findsOneWidget);
      expect(tester.getRect(check).center.dy,
          closeTo(tester.getRect(find.text('甲')).center.dy, 4));
    });
  });

  group('BezierMenuSelect / BezierMenuTrigger', () {
    testWidgets('当前值、打开态描边、Tab 关闭后焦点回到触发器', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var picked = 'unset';
      await tester.pumpWidget(_app(BezierMenuSelect<String>(
        key: const Key('select'),
        label: '全部分类',
        width: 180,
        focusNode: focus,
        items: const [
          BezierMenuItem(value: 'all', label: '全部分类', selected: true),
          BezierMenuItem(value: 'course', label: '课程'),
          BezierMenuItem(value: 'work', label: '工作'),
        ],
        onSelected: (value) => picked = value,
      )));
      expect(find.text('全部分类'), findsOneWidget);

      // 打开前：普通描边。
      Container container() => tester.widget<Container>(find
          .ancestor(of: find.byIcon(Icons.expand_more), matching: find.byType(Container))
          .first);
      BorderSide side() {
        final decoration = container().decoration! as ShapeDecoration;
        return (decoration.shape as BezierRoundedRectangleBorder).side;
      }

      expect(side().color, TsColors.border);

      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      // 打开态：accent 描边 + 软 accent 底，与“选中”语义一致。
      expect(side().color, TsColors.accent);

      // Tab 关闭菜单，焦点回到触发器（之后 Tab 才能从当前位置继续）。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(picked, 'unset', reason: 'Tab 只是关闭，不产生选择');

      // 重新打开并点选具体值。
      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: _panel, matching: find.text('课程')));
      await tester.pumpAndSettle();
      expect(picked, 'course');
      expect(focus.hasFocus, isTrue, reason: '选择后焦点也回到触发器');
    });

    testWidgets('可空值菜单能区分“全部会话（null）”与关闭', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Object? picked = 'unset';
      var picks = 0;
      await tester.pumpWidget(_app(BezierMenuSelect<String?>(
        key: const Key('session-select'),
        label: '全部会话',
        width: 200,
        items: const [
          BezierMenuItem<String?>(value: null, label: '全部会话', selected: true),
          BezierMenuItem<String?>(value: 'conv-1', label: '顺序表实验'),
          BezierMenuItem<String?>(
              value: 'conv-2', label: '移动端 App 2.0 上线项目示例', selected: false),
        ],
        onSelected: (value) {
          picked = value;
          picks++;
        },
      )));
      await tester.tap(find.byKey(const Key('session-select')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.descendant(of: _panel, matching: find.text('全部会话')));
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(picked, isNull, reason: '“全部”是一个真实选择，不是关闭');
    });

    testWidgets('禁用触发器不打开菜单', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(BezierMenuSelect<String>(
        key: const Key('select'),
        label: '全部任务',
        enabled: false,
        items: const [BezierMenuItem(value: 'a', label: '甲')],
        onSelected: (_) {},
      )));
      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    });

    testWidgets('150% 文字缩放下菜单与选择触发器不溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var picked = 'unset';
      await tester.pumpWidget(_app(
        BezierMenuSelect<String>(
          key: const Key('select'),
          label: '全部关联会话',
          width: 200,
          items: const [
            BezierMenuItem(value: 'all', label: '全部关联会话', selected: true),
            BezierMenuItem(value: 'course', label: '课程'),
            BezierMenuItem(
                value: 'long', label: '一个很长很长的会话标题，用来验证省略与缩放'),
          ],
          onSelected: (value) => picked = value,
        ),
        textScale: 1.5,
      ));
      expect(tester.takeException(), isNull, reason: '150% 缩放下触发器不得溢出');

      await tester.tap(find.byKey(const Key('select')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '150% 缩放下菜单不得溢出');
      final panel = tester.getRect(_panel);
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.bottom, lessThanOrEqualTo(800));
      await tester.tap(find.descendant(of: _panel, matching: find.text('课程')));
      await tester.pumpAndSettle();
      expect(picked, 'course');
    });

    testWidgets('通用触发器支持自定义子控件与键盘 Enter 打开', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var picked = 'unset';
      await tester.pumpWidget(_app(BezierMenuTrigger<String>(
        key: const Key('trigger'),
        focusNode: focus,
        tooltip: '更多操作',
        items: const [
          BezierMenuItem(value: 'x', label: '操作 X'),
          BezierMenuItem(value: 'y', label: '操作 Y'),
        ],
        onSelected: (value) => picked = value,
        child: const SizedBox(
          width: 32,
          height: 32,
          child: Icon(Icons.add),
        ),
      )));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget, reason: 'Enter 应打开菜单');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked, 'y');
    });
  });

  group('TsDialogActions / TsCloseButton', () {
    testWidgets('主/次/危险/轻量角色与禁用态', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final taps = <String>[];
      await tester.pumpWidget(_app(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TsDialogActions(actions: <TsDialogAction>[
            TsDialogAction(
              key: const Key('leading'),
              label: '导出 CSV',
              role: TsDialogActionRole.leading,
              onPressed: () => taps.add('leading'),
            ),
            TsDialogAction(
              key: const Key('secondary'),
              label: '关闭',
              role: TsDialogActionRole.secondary,
              onPressed: () => taps.add('secondary'),
            ),
            TsDialogAction(
              key: const Key('primary'),
              label: '在甘特图中定位',
              role: TsDialogActionRole.primary,
              onPressed: () => taps.add('primary'),
            ),
            TsDialogAction(
              key: const Key('danger'),
              label: '删除',
              role: TsDialogActionRole.danger,
              onPressed: () => taps.add('danger'),
            ),
            const TsDialogAction(
              key: Key('disabled'),
              label: '确认生成计划',
              role: TsDialogActionRole.primary,
              onPressed: null,
            ),
          ]),
        ],
      )));
      // 角色样式来自统一按钮映射。
      expect(
        hexOf(tester
            .widget<FilledButton>(find.byKey(const Key('primary')))
            .style!
            .backgroundColor!
            .resolve(const <WidgetState>{})!),
        hexOf(TsColors.buttonFill),
      );
      expect(
        hexOf(tester
            .widget<TextButton>(find.byKey(const Key('secondary')))
            .style!
            .foregroundColor!
            .resolve(const <WidgetState>{})!),
        hexOf(TsColors.textPrimary),
      );
      expect(
        hexOf(tester
            .widget<FilledButton>(find.byKey(const Key('danger')))
            .style!
            .backgroundColor!
            .resolve(const <WidgetState>{})!),
        hexOf(TsColors.blocked),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('disabled')))
            .onPressed,
        isNull,
        reason: '禁用动作没有回调，不能触发',
      );

      for (final key in const ['leading', 'secondary', 'primary', 'danger']) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
      }
      expect(taps, ['leading', 'secondary', 'primary', 'danger']);
    });

    testWidgets('统一关闭键：tooltip 与点击', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var closed = 0;
      await tester.pumpWidget(_app(TsCloseButton(
        key: const Key('close'),
        tooltip: '取消本次分析',
        onPressed: () => closed++,
      )));
      expect(
        tester
            .widget<IconButton>(find.descendant(
                of: find.byKey(const Key('close')),
                matching: find.byType(IconButton)))
            .tooltip,
        '取消本次分析',
      );
      await tester.tap(find.byKey(const Key('close')));
      await tester.pump();
      expect(closed, 1);
    });
  });
}

String hexOf(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
