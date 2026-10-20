// 7 天 × 96 格的周时间表绘制控件与月/年导航。
//
// 交互约定：
//   * 左键单击画一格，按住拖动连续画；快速移动按“经过的格子”补齐，不跳格；
//   * 右键擦除目标格（只恢复该 15 分钟范围），中键在“占用 / 任务”两个画笔间循环；
//   * 一次按下到抬起是一个撤销事务；Ctrl+Z 在网格焦点内只撤销日程操作；
//   * 表头与左侧时间轴固定，只有内容纵向滚动；
//   * 开始/结束不是 15 分钟整数倍时保留真实边界并画出标记，不取整。
//
// 主要类型：TimetableGrid、TimetableGridController、showTimetableMonthPicker、
// showTimetableYearPicker。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/calendar.dart';
import '../model/timetable.dart';
import '../model/settings.dart';
import 'edit_commands.dart';
import 'theme.dart';
import 'widgets/bezier_ui.dart';

/// 画笔控制器：把“当前画笔 / 是否每周重复 / 撤销”暴露给工具栏与测试。
class TimetableGridController extends ChangeNotifier {
  TimetableGridController({
    required TimetableDraft draft,
    TimetableState brush = TimetableState.occupied,
  })  : _draft = draft,
        _brush = brush;

  final TimetableDraft _draft;
  TimetableState _brush;

  TimetableState get brush => _brush;
  TimetableDraft get draft => _draft;
  bool get canUndo => _draft.hasUndo;

  void setBrush(TimetableState state) {
    if (_brush == state) return;
    _brush = state;
    notifyListeners();
  }

  void cycleBrush() {
    _brush = _brush == TimetableState.occupied
        ? TimetableState.task
        : TimetableState.occupied;
    notifyListeners();
  }

  void undo() {
    if (_draft.undo()) notifyListeners();
  }

  void markApplied() {
    _draft.markApplied();
    notifyListeners();
  }
}

/// 一个 15 分钟格坐标（显示层）。
typedef TimetableCell = ({int day, int slot});

/// 网格几何：把“仅网格视口”的局部坐标映射为格子。
///
/// 视口是 [TimetableGrid] 中包住滚动内容的那一层（不含日期表头、底部状态条、
/// 右侧滚动条沟槽）。竖直方向必须加上滚动偏移，水平方向必须扣掉左侧时间轴；
/// hover、按下、拖动、自动滚动后的补画都走同一个 [hit] / [toGrid]，不能各自
/// 再加减一次偏移。
class TimetableGridGeometry {
  const TimetableGridGeometry({
    required this.gridWidth,
    required this.viewportHeight,
    required this.scrollOffset,
    this.axisWidth = TimetableGrid.timeAxisWidth,
    this.topInset = TimetableGrid.topInset,
    this.rowHeight = TimetableGrid.rowHeight,
    this.days = 7,
    this.slotsPerDay = kTimetableSlotsPerDay,
  });

  final double gridWidth;
  final double viewportHeight;
  final double scrollOffset;
  final double axisWidth;
  final double topInset;
  final double rowHeight;
  final int days;
  final int slotsPerDay;

  double get dayWidth => days <= 0 ? 0 : gridWidth / days;

  /// 视口坐标 → 连续格坐标；不在网格内时返回 null。
  Offset? toGrid(Offset viewportPoint) {
    if (dayWidth <= 0 || rowHeight <= 0) return null;
    final x = viewportPoint.dx - axisWidth;
    final y = viewportPoint.dy + scrollOffset - topInset;
    if (x < 0 || x >= dayWidth * days) return null;
    if (y < 0 || y >= slotsPerDay * rowHeight) return null;
    return Offset(x / dayWidth, y / rowHeight);
  }

  TimetableCell? hit(Offset viewportPoint) {
    final p = toGrid(viewportPoint);
    if (p == null) return null;
    final day = p.dx.floor();
    final slot = p.dy.floor();
    if (day < 0 || day >= days || slot < 0 || slot >= slotsPerDay) return null;
    return (day: day, slot: slot);
  }
}

/// 线段真正穿过的格子（网格 DDA），不是包围矩形。
///
/// 两点都必须在 [0,7) × [0,96) 内；离开网格由调用方断开笔画，避免把滚动条、
/// 时间轴上的移动连成一笔跨网格的斜线。恰好穿过格角时同时跨两轴，不额外填充
/// 只接触角点的旁格。
List<TimetableCell> crossedGridCells(Offset from, Offset to) {
  bool inside(Offset p) =>
      p.dx >= 0 && p.dx < 7 && p.dy >= 0 && p.dy < kTimetableSlotsPerDay;
  if (!inside(from) || !inside(to)) return const <TimetableCell>[];
  var x = from.dx.floor();
  var y = from.dy.floor();
  final endX = to.dx.floor();
  final endY = to.dy.floor();
  final dx = to.dx - from.dx;
  final dy = to.dy - from.dy;
  final sx = dx.sign.toInt();
  final sy = dy.sign.toInt();
  final deltaX = sx == 0 ? double.infinity : 1 / dx.abs();
  final deltaY = sy == 0 ? double.infinity : 1 / dy.abs();
  var nextX = sx == 0 ? double.infinity : ((sx > 0 ? x + 1 : x) - from.dx) / dx;
  var nextY = sy == 0 ? double.infinity : ((sy > 0 ? y + 1 : y) - from.dy) / dy;
  final out = <TimetableCell>[(day: x, slot: y)];
  var guard = 0;
  while ((x != endX || y != endY) && guard++ < 4096) {
    if ((nextX - nextY).abs() < 1e-10) {
      x += sx;
      y += sy;
      nextX += deltaX;
      nextY += deltaY;
    } else if (nextX < nextY) {
      x += sx;
      nextX += deltaX;
    } else {
      y += sy;
      nextY += deltaY;
    }
    if (x < 0 || x >= 7 || y < 0 || y >= kTimetableSlotsPerDay) break;
    out.add((day: x, slot: y));
  }
  return out;
}

/// 网格的编辑命令目标：撤销接日程事务，其他文本命令不适用。
///
/// 网格没有实现重做，因此重做在标题栏菜单里保持禁用，不伪装成功。
class TimetableGridEditTarget implements EditTarget {
  TimetableGridEditTarget({
    required this.controller,
    required bool Function() isAlive,
    this.onChanged,
  }) : _isAlive = isAlive;

  final TimetableGridController controller;
  final bool Function() _isAlive;
  final VoidCallback? onChanged;

  @override
  bool get isAlive => _isAlive();

  @override
  bool canExecute(EditCommand command) =>
      command == EditCommand.undo && controller.canUndo;

  @override
  Future<void> execute(EditCommand command) async {
    if (command != EditCommand.undo) return;
    controller.undo();
    onChanged?.call();
  }
}

/// 绘制网格。父控件负责“填写/绘制”切换、周导航和应用按钮。
class TimetableGrid extends StatefulWidget {
  final TimetableGridController controller;
  final String weekStart;
  final int weekStartsOn;

  /// True 编辑周模板（每周重复）；false 只改本周具体日期。
  final bool weeklyMode;
  final VoidCallback? onChanged;
  final ValueChanged<String>? onHover;

  /// 任务 ID → 名称；用于悬浮提示里的绑定情况。
  final Map<String, String> taskNames;

  /// 绑定入口：把当前周未绑定的蓝色块批量绑定到任务。
  final VoidCallback? onBindUnbound;

  /// 外部持有的纵向滚动 controller（切换编辑方式时保留滚动位置）。
  /// 为 null 时由网格自己创建并在 dispose 时释放。
  final ScrollController? verticalController;

  const TimetableGrid({
    super.key,
    required this.controller,
    required this.weekStart,
    required this.weekStartsOn,
    required this.weeklyMode,
    this.onChanged,
    this.onHover,
    this.taskNames = const <String, String>{},
    this.onBindUnbound,
    this.verticalController,
  });

  static const double timeAxisWidth = 54;
  static const double rowHeight = 16;
  static const double headerHeight = 38;

  /// 网格内容顶部留白：00:00 标签按文字高度完整放在内容内，不被表头裁切。
  static const double topInset = 10;

  /// 网格内容底部留白：24:00 标签与最后一格的点击区域都完整。
  static const double bottomInset = 14;

  /// 右侧滚动条沟槽：滚动条画在沟槽里，不压住周日列。
  static const double scrollbarGutter = 18;

  static double get gridHeight => kTimetableSlotsPerDay * rowHeight;
  static double get contentHeight => topInset + gridHeight + bottomInset;

  @override
  State<TimetableGrid> createState() => _TimetableGridState();
}

class _TimetableGridState extends State<TimetableGrid> {
  final FocusNode _focus = FocusNode(debugLabel: 'timetable-grid');
  final GlobalKey _viewportKey = GlobalKey(debugLabel: 'timetable-viewport');
  ScrollController? _ownedVertical;
  Timer? _autoScroll;
  double _autoScrollDelta = 0;
  int? _pointer;
  bool _erasing = false;
  Offset? _lastGrid;
  Offset? _lastGlobal;
  final Set<TimetableCell> _visited = <TimetableCell>{};
  String? _hoverText;
  double _gridWidth = 7 * 120;
  bool _disposed = false;

  late final EditTarget _editTarget = TimetableGridEditTarget(
    controller: widget.controller,
    isAlive: () => !_disposed,
  );

  ScrollController get _vertical =>
      widget.verticalController ?? (_ownedVertical ??= ScrollController());

  TimetableDraft get _draft => widget.controller.draft;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant TimetableGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    EditTargetRegistry.clear(_editTarget);
    _endStroke(commit: false);
    widget.controller.removeListener(_onController);
    _ownedVertical?.dispose();
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  void _onController() {
    if (!_disposed && mounted) setState(() {});
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      EditTargetRegistry.setActive(_editTarget);
    } else {
      EditTargetRegistry.clear(_editTarget);
      _endStroke(commit: false);
    }
  }

  void _changed() {
    if (_disposed) return;
    widget.onChanged?.call();
    setState(() {});
  }

  List<TimetableDay> get _days =>
      _draft.timetable.weekDays(weekStart: widget.weekStart);

  TimetableGridGeometry get _geometry => TimetableGridGeometry(
        gridWidth: _gridWidth,
        viewportHeight: _viewportHeight,
        scrollOffset: _vertical.hasClients ? _vertical.offset : 0,
      );

  double _viewportHeight = 0;

  RenderBox? get _viewportBox {
    final object = _viewportKey.currentContext?.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  Offset? _viewportPoint(PointerEvent event) {
    final box = _viewportBox;
    if (box == null) return null;
    return box.globalToLocal(event.position);
  }

  // ------------------------------------------------------------- gestures

  void _handleDown(PointerDownEvent event) {
    // 只处理主指针；第二根手指/第二个按键不进入绘制状态机，避免打断一笔。
    _focus.requestFocus();
    if (event.buttons & kMiddleMouseButton != 0) {
      widget.controller.cycleBrush();
      return;
    }
    final isErase = event.buttons & kSecondaryMouseButton != 0;
    final isPaint = event.buttons & kPrimaryMouseButton != 0;
    if (!isErase && !isPaint) return;
    final local = _viewportPoint(event);
    if (local == null) return;
    final cell = _geometry.hit(local);
    if (cell == null) return;
    _pointer = event.pointer;
    _erasing = isErase;
    _lastGlobal = event.position;
    _lastGrid = _geometry.toGrid(local);
    _visited
      ..clear()
      ..add(cell);
    _draft.beginStroke();
    _paintCells(<TimetableCell>[cell]);
    _changed();
  }

  void _handleMove(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    _lastGlobal = event.position;
    final local = _viewportPoint(event);
    if (local == null) {
      // 指针离开视口：断开轨迹，但继续按视口边缘判断自动滚动。
      _lastGrid = null;
      _maybeAutoScroll(null);
      return;
    }
    _extendStroke(local);
    _maybeAutoScroll(local);
  }

  /// 把“上一格 → 当前点”真正经过的格子补齐；同一笔内去重。
  void _extendStroke(Offset local) {
    final geometry = _geometry;
    final current = geometry.hit(local);
    final gridPoint = geometry.toGrid(local);
    if (current == null || gridPoint == null) {
      _lastGrid = null;
      return;
    }
    final from = _lastGrid;
    final cells = <TimetableCell>[];
    if (from == null) {
      cells.add(current);
    } else {
      cells.addAll(crossedGridCells(from, gridPoint));
      if (cells.isEmpty) cells.add(current);
    }
    final fresh = <TimetableCell>[
      for (final cell in cells)
        if (_visited.add(cell)) cell,
    ];
    _lastGrid = gridPoint;
    if (fresh.isEmpty) return;
    _paintCells(fresh);
    _changed();
  }

  void _handleUp(PointerEvent event) {
    if (_pointer != event.pointer) return;
    _endStroke(commit: true);
  }

  void _handleCancel(PointerEvent event) {
    if (_pointer != event.pointer) return;
    _endStroke(commit: false);
  }

  /// 统一终止：停计时器、清指针/轨迹、按 [commit] 结束或回滚这一笔。
  void _endStroke({required bool commit}) {
    _stopAutoScroll();
    _pointer = null;
    _lastGlobal = null;
    _lastGrid = null;
    _visited.clear();
    if (commit) {
      _draft.endStroke();
    } else {
      _draft.cancelStroke();
    }
    if (mounted) _changed();
  }

  void _paintCells(List<TimetableCell> cells) {
    final days = _days;
    if (days.isEmpty) return;
    final byDay = <int, List<int>>{};
    for (final cell in cells) {
      if (cell.day < 0 || cell.day >= days.length) continue;
      if (cell.slot < 0 || cell.slot >= kTimetableSlotsPerDay) continue;
      byDay.putIfAbsent(cell.day, () => <int>[]).add(cell.slot);
    }
    for (final entry in byDay.entries) {
      final day = days[entry.key];
      final slots = entry.value.toSet().toList()..sort();
      if (_erasing) {
        _draft.eraseSlots(
          date: widget.weeklyMode ? null : day.date,
          weekday: widget.weeklyMode ? day.weekday : null,
          slots: slots,
        );
        continue;
      }
      final state = widget.controller.brush;
      _draft.paintSlots(
        date: widget.weeklyMode ? null : day.date,
        weekday: widget.weeklyMode ? day.weekday : null,
        slots: slots,
        state: state,
        title: state == TimetableState.task ? '任务预留' : null,
      );
    }
  }

  /// 边缘自动滚动：按【视口】坐标判断方向，每次 tick 用最后全局位置重新映射
  /// 并补画。方向在每次 move 时更新；离开边缘、到边界、抬起或失焦都停止。
  void _maybeAutoScroll(Offset? local) {
    const edge = 30.0;
    if (local == null || _viewportHeight <= 0 || !_vertical.hasClients) {
      _stopAutoScroll();
      return;
    }
    double delta = 0;
    if (local.dy < edge) {
      delta = -14 * (1 - local.dy / edge).clamp(0.0, 1.0);
    } else if (local.dy > _viewportHeight - edge) {
      delta = 14 * ((local.dy - _viewportHeight + edge) / edge).clamp(0.0, 1.0);
    }
    if (delta == 0) {
      _stopAutoScroll();
      return;
    }
    // 每次 move 都更新方向：反向拖动时正在运行的计时器立刻跟着改，不沿用旧方向。
    _autoScrollDelta = delta;
    if (_autoScroll?.isActive == true) return;
    _autoScroll = Timer.periodic(const Duration(milliseconds: 32), (_) {
      _autoScrollTick();
    });
  }

  void _autoScrollTick() {
    if (!mounted || _pointer == null || !_vertical.hasClients) {
      _stopAutoScroll();
      return;
    }
    final before = _vertical.offset;
    final next = (before + _autoScrollDelta)
        .clamp(_vertical.position.minScrollExtent,
            _vertical.position.maxScrollExtent)
        .toDouble();
    if ((next - before).abs() < 0.01) {
      _stopAutoScroll();
      return;
    }
    _vertical.jumpTo(next);
    final global = _lastGlobal;
    final box = _viewportBox;
    if (global == null || box == null) return;
    // 滚动后用【最后全局鼠标位置】重新映射并补画，避免把旧坐标画到新偏移上。
    _extendStroke(box.globalToLocal(global));
  }

  void _stopAutoScroll() {
    _autoScrollDelta = 0;
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  void _handleHover(PointerHoverEvent event) {
    final local = _viewportPoint(event);
    final cell = local == null ? null : _geometry.hit(local);
    if (cell == null) {
      if (_hoverText != null) {
        setState(() => _hoverText = null);
        widget.onHover?.call('');
      }
      return;
    }
    final d = _days[cell.day];
    final minute = cell.slot * kTimetableSlotMinutes;
    final interval = d.at(minute);
    final state = interval?.state ?? TimetableState.fromCode(_draft.timetable.defaultState);
    final start = interval?.start ?? cell.slot * kTimetableSlotMinutes;
    final end = interval?.end ?? start + kTimetableSlotMinutes;
    final bound = interval?.taskId == null
        ? ''
        : ' · 绑定：${widget.taskNames[interval!.taskId!] ?? interval.taskId}';
    final origin = switch (interval?.origin) {
      TimetableOrigin.defaultRule => '默认',
      TimetableOrigin.model => '模型',
      _ => '手动',
    };
    final title = (interval?.title == null || interval!.title!.isEmpty)
        ? state.label
        : interval.title!;
    final text = '${d.date} ${_hhmm(start)}-${_hhmm(end)} · $title · $origin$bound'
        '${interval?.isPartialCell == true ? ' · 精确边界' : ''}';
    if (text != _hoverText) {
      setState(() => _hoverText = text);
      widget.onHover?.call(text);
    }
  }

  static String _hhmm(int minute) => WallClockRange.formatMinute(minute);

  double _scaledHeaderHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return TimetableGrid.headerHeight * scale;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final days = _days;
    // 日期表头随文字缩放增高，1.5 倍字号下两行标签不会纵向溢出。
    final headerHeight = _scaledHeaderHeight(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(days, headerHeight),
        Expanded(
          child: Focus(
            focusNode: _focus,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.keyZ &&
                  HardwareKeyboard.instance.isControlPressed) {
                widget.controller.undo();
                _changed();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: LayoutBuilder(builder: (context, constraints) {
              _viewportHeight = constraints.maxHeight;
              _gridWidth = math.max(
                7 * 24,
                constraints.maxWidth -
                    TimetableGrid.timeAxisWidth -
                    TimetableGrid.scrollbarGutter,
              );
              return MouseRegion(
                onHover: _handleHover,
                child: Listener(
                  key: _viewportKey,
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _handleDown,
                  onPointerMove: _handleMove,
                  onPointerUp: _handleUp,
                  onPointerCancel: _handleCancel,
                  child: Scrollbar(
                    controller: _vertical,
                    thumbVisibility: true,
                    // 沟槽在滚动条内侧：滚动条画在 18px 空带里，不压住周日列。
                    child: Padding(
                      padding: const EdgeInsets.only(
                          right: TimetableGrid.scrollbarGutter),
                      child: SingleChildScrollView(
                        controller: _vertical,
                        child: SizedBox(
                          height: TimetableGrid.contentHeight,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _timeAxis(),
                              SizedBox(
                                width: _gridWidth,
                                height: TimetableGrid.contentHeight,
                                child: CustomPaint(
                                  painter: _GridPainter(
                                    days: days,
                                    width: _gridWidth,
                                    rowHeight: TimetableGrid.rowHeight,
                                    topInset: TimetableGrid.topInset,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        _statusBar(),
      ],
    );
  }

  Widget _statusBar() {
    final hint = _hoverText ??
        '左键绘制 · 拖动连续绘制 · 右键擦除 · 中键切换画笔 · Ctrl+Z 撤销';
    final stats = widget.weekStart.isNotEmpty && _draft.timetable.hasEntries
        ? '每周可用 ${_draft.timetable.freeMinutesPerWeek ~/ 60} 小时 '
            '${_draft.timetable.freeMinutesPerWeek % 60} 分'
        : null;
    // 状态条在滚动区之外：长提示省略、窄窗口换行，最后一个格不会被它遮挡。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: TsColors.border)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final hintText = Text(
          hint,
          key: const Key('timetable-hover'),
          maxLines: narrow ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
        );
        if (stats == null) return hintText;
        final statsText = Text(
          stats,
          style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [hintText, const SizedBox(height: 2), statsText],
          );
        }
        return Row(
          children: [
            Expanded(child: hintText),
            const SizedBox(width: 8),
            statsText,
          ],
        );
      }),
    );
  }

  Widget _header(List<TimetableDay> days, double headerHeight) {
    return SizedBox(
      height: headerHeight,
      child: Row(
        children: [
          SizedBox(
            width: TimetableGrid.timeAxisWidth,
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4, bottom: 4),
                child: Text('时间',
                    style:
                        TextStyle(fontSize: 10, color: TsColors.textFaint)),
              ),
            ),
          ),
          for (final d in days)
            Expanded(
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: TsColors.surfaceAlt,
                  border: Border(
                    left: BorderSide(
                        color: TsColors.border.withValues(alpha: 0.7)),
                    bottom: BorderSide(color: TsColors.border),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _weekdayName(d.weekday),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: TsColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${_int(d.date.substring(5, 7))}/${_int(d.date.substring(8))}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: TsColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 与右侧滚动条沟槽同宽，保证表头 7 列和网格 7 列严格对齐。
          const SizedBox(width: TimetableGrid.scrollbarGutter),
        ],
      ),
    );
  }

  Widget _timeAxis() {
    const labelHeight = 11.0;
    return SizedBox(
      width: TimetableGrid.timeAxisWidth,
      height: TimetableGrid.contentHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var hour = 0; hour <= 24; hour++)
            Positioned(
              // 以整点线为中心，并把标签整体夹在内容范围内：00:00 不被顶部裁切，
              // 24:00 不被底部状态条裁切。
              top: (TimetableGrid.topInset +
                      hour * 4 * TimetableGrid.rowHeight -
                      labelHeight / 2)
                  .clamp(0.0, TimetableGrid.contentHeight - labelHeight)
                  .toDouble(),
              right: 4,
              height: labelHeight,
              child: Text(
                '${hour.toString().padLeft(2, '0')}:00',
                style: TextStyle(fontSize: 9, color: TsColors.textFaint),
              ),
            ),
        ],
      ),
    );
  }

  static String _weekdayName(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };

  static int _int(String s) => int.tryParse(s) ?? 0;
}

class _GridPainter extends CustomPainter {
  final List<TimetableDay> days;
  final double width;
  final double rowHeight;
  final double topInset;

  _GridPainter({
    required this.days,
    required this.width,
    required this.rowHeight,
    required this.topInset,
  });

  static const Color _free = Color(0xFFFFFFFF);
  static const Color _occupied = Color(0xFF4B5563);
  static const Color _occupiedSoft = Color(0xFFE5E7EB);

  @override
  void paint(Canvas canvas, Size size) {
    final dayWidth = width / 7;
    final height = kTimetableSlotsPerDay * rowHeight;
    final fill = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < days.length && i < 7; i++) {
      final left = i * dayWidth;
      final day = days[i];
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(left, topInset, dayWidth, height));
      fill.color = _free;
      canvas.drawRect(
          Rect.fromLTWH(left, topInset, dayWidth, height), fill);

      for (final interval in day.intervals) {
        if (interval.state == TimetableState.free) continue;
        final color = interval.state == TimetableState.task
            ? (interval.taskId == null
                ? TsColors.accent.withValues(alpha: 0.45)
                : TsColors.accent)
            : _occupied;
        fill.color = color;
        final top = topInset + interval.start / 60 * 4 * rowHeight;
        final bottom = topInset + interval.end / 60 * 4 * rowHeight;
        canvas.drawRect(
          Rect.fromLTWH(left + 1, top, dayWidth - 2, bottom - top),
          fill,
        );
        // 精确边界：不是 15 分钟整数倍时画一条细线，避免用户以为被取整。
        if (interval.start % kTimetableSlotMinutes != 0) {
          canvas.drawRect(
            Rect.fromLTWH(left + 1, top - 1, dayWidth - 2, 2),
            Paint()..color = const Color(0xFF111827),
          );
        }
        if (interval.end % kTimetableSlotMinutes != 0) {
          canvas.drawRect(
            Rect.fromLTWH(left + 1, bottom - 1, dayWidth - 2, 2),
            Paint()..color = const Color(0xFF111827),
          );
        }
        if (interval.state == TimetableState.task && interval.taskId == null) {
          // 未绑定：斜线标记，不只依赖颜色。
          final line = Paint()
            ..color = const Color(0x99FFFFFF)
            ..strokeWidth = 1;
          for (var y = top + 4; y < bottom; y += 8) {
            canvas.drawLine(
                Offset(left + 3, y), Offset(left + dayWidth - 4, y + 4), line);
          }
        }
      }

      // 15 分钟线与小时线。
      for (var slot = 0; slot <= kTimetableSlotsPerDay; slot++) {
        final y = topInset + slot * rowHeight;
        final hour = slot % 4 == 0;
        canvas.drawLine(
          Offset(left, y),
          Offset(left + dayWidth, y),
          Paint()
            ..color = hour
                ? const Color(0xFF9CA3AF)
                : _occupiedSoft.withValues(alpha: 0.75)
            ..strokeWidth = hour ? 1 : 0.5,
        );
      }
      canvas.drawLine(
        Offset(left, topInset),
        Offset(left, topInset + height),
        Paint()
          ..color = const Color(0xFFD1D5DB)
          ..strokeWidth = 1,
      );
      canvas.restore();
    }
    canvas.drawLine(
      Offset(width, topInset),
      Offset(width, topInset + height),
      Paint()
        ..color = const Color(0xFFD1D5DB)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.days != days ||
      old.width != width ||
      old.rowHeight != rowHeight ||
      old.topInset != topInset;
}

// ---------------------------------------------------------------- navigation

/// 月视图：选具体日期后回到该日所在周。
Future<String?> showTimetableMonthPicker(
  BuildContext context, {
  required String initialDate,
  int weekStartsOn = 1,
}) async {
  final date = parseDateKey(initialDate) ?? '1970-01-01';
  var year = int.tryParse(date.substring(0, 4)) ?? 1970;
  var month = int.tryParse(date.substring(5, 7)) ?? 1;
  final selected = date;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final first = DateTime.utc(year, month, 1);
        final leading = (first.weekday - weekStartsOn + 7) % 7;
        final start = first.subtract(Duration(days: leading));
        final cells = List<DateTime>.generate(42, (i) => start.add(Duration(days: i)));
        return AlertDialog(
          title: Row(
            children: [
              IconButton(
                tooltip: '上一年',
                onPressed: () => setState(() => year--),
                icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
              ),
              IconButton(
                tooltip: '上个月',
                onPressed: () => setState(() {
                  month--;
                  if (month < 1) {
                    month = 12;
                    year--;
                  }
                }),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Expanded(
                child: Text('$year 年 $month 月',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14)),
              ),
              IconButton(
                tooltip: '下个月',
                onPressed: () => setState(() {
                  month++;
                  if (month > 12) {
                    month = 1;
                    year++;
                  }
                }),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
              IconButton(
                tooltip: '下一年',
                onPressed: () => setState(() => year++),
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
              ),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Expanded(
                        child: Center(
                          child: Text(
                            _weekdayShort((weekStartsOn - 1 + i) % 7 + 1),
                            style: TextStyle(
                                fontSize: 10.5, color: TsColors.textFaint),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                for (var row = 0; row < 6; row++)
                  Row(
                    children: [
                      for (var col = 0; col < 7; col++)
                        Expanded(
                          child: _dayCell(ctx, cells[row * 7 + col], month,
                              selected),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );
}

Widget _dayCell(BuildContext ctx, DateTime date, int month, String selected) {
  final inMonth = date.month == month;
  final key = WallClock.formatDateKey(date.year, date.month, date.day);
  final isSelected = key == selected;
  return SizedBox(
    height: 32,
    child: InkWell(
      onTap: () => Navigator.of(ctx).pop(key),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? TsColors.accentSoft : null,
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: Text(
          '${date.day}',
          style: TextStyle(
            fontSize: 11.5,
            color: inMonth
                ? (isSelected ? TsColors.accent : TsColors.textPrimary)
                : TsColors.textFaint,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    ),
  );
}

/// 年视图：先选月，再进入月视图选日。
Future<String?> showTimetableYearPicker(
  BuildContext context, {
  required String initialDate,
}) async {
  var year = int.tryParse(initialDate.substring(0, 4)) ?? DateTime.now().year;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        return AlertDialog(
          title: Row(
            children: [
              IconButton(
                tooltip: '上一年',
                onPressed: () => setState(() => year--),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Expanded(
                child: Text('$year 年',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14)),
              ),
              IconButton(
                tooltip: '下一年',
                onPressed: () => setState(() => year++),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var row = 0; row < 3; row++)
                  Row(
                    children: [
                      for (var col = 0; col < 4; col++)
                        Expanded(
                          child: SizedBox(
                            height: 40,
                            child: InkWell(
                              onTap: () => Navigator.of(ctx)
                                  .pop('$year-${(row * 4 + col + 1).toString().padLeft(2, '0')}-01'),
                              child: Center(
                                child: Text(
                                  '${row * 4 + col + 1} 月',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );
}

String _weekdayShort(int weekday) => switch (weekday) {
      1 => '一',
      2 => '二',
      3 => '三',
      4 => '四',
      5 => '五',
      6 => '六',
      _ => '日',
    };

/// 顶部的“手动填写 / 手动绘制”分段开关。
class EditorModeSwitch extends StatelessWidget {
  final CalendarEditorMode mode;
  final ValueChanged<CalendarEditorMode> onChanged;

  const EditorModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return BezierSegments(
      height: 30,
      itemWidth: 88,
      items: const [
        BezierSegmentItem('手动填写'),
        BezierSegmentItem('手动绘制'),
      ],
      selected: mode == CalendarEditorMode.fill ? 0 : 1,
      onChanged: (index) => onChanged(
        index == 0 ? CalendarEditorMode.fill : CalendarEditorMode.drawing,
      ),
    );
  }
}
