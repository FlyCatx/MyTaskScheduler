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

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/calendar.dart';
import '../model/external_calendar.dart';
import '../model/timetable.dart';
import '../model/settings.dart';
import 'edit_commands.dart';
import 'theme.dart';
import 'widgets/bezier_ui.dart';

/// 画笔控制器：把“当前画笔 / 撤销重做 / 蓝块选择”暴露给工具栏与测试。
///
/// 蓝块选择状态由 controller 统一持有：选择模式下左键单击蓝色块 = 切换选中，
/// 不产生绘制/擦除，也不产生撤销事务；选中集合用稳定身份
/// `entry.reservationId ?? entry.id` 表示（蓝块复制/绑定后仍可定位）。
class TimetableGridController extends ChangeNotifier {
  TimetableGridController({
    required TimetableDraft draft,
    TimetableState brush = TimetableState.occupied,
  })  : _draft = draft,
        _brush = brush;

  final TimetableDraft _draft;
  TimetableState _brush;
  bool _selectionMode = false;
  final Set<String> _selected = <String>{};

  TimetableState get brush => _brush;
  TimetableDraft get draft => _draft;
  bool get canUndo => _draft.hasUndo;
  bool get canRedo => _draft.canRedo;
  int get undoDepth => _draft.undoDepth;
  int get redoDepth => _draft.redoDepth;

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

  /// 重做一笔；成功才通知（失败无副作用）。
  void redo() {
    if (_draft.redo()) notifyListeners();
  }

  void markApplied() {
    _draft.markApplied();
    notifyListeners();
  }

  // ------------------------------------------------------------ 蓝块选择

  /// 选择模式：开启后左键单击蓝色块 = 切换选中，不再绘制/擦除。
  bool get selectionMode => _selectionMode;

  /// 已选蓝色块身份集合（不可变快照）。
  ///
  /// 身份 = `entry.reservationId ?? entry.id`；已被撤销/删除的块会自动剔除，
  /// 调用方按同一规则反查条目：
  /// `dates.where((e) => e.isTask && selected.contains(e.reservationId ?? e.id))`。
  Set<String> get selectedReservationIds {
    final live = _liveTaskIdentities();
    return Set<String>.unmodifiable(
      _selected.where(live.contains).toSet(),
    );
  }

  bool get hasSelection => selectedReservationIds.isNotEmpty;

  /// 选中的蓝色块条目数（只统计当前时间表里仍存在的条目）。
  int get selectedBlockCount {
    final ids = selectedReservationIds;
    if (ids.isEmpty) return 0;
    return _draft.timetable.dates
        .where((e) => e.isTask && ids.contains(_identityOf(e)))
        .length;
  }

  /// 选中条目的分钟数合计。
  int get selectedMinutes {
    final ids = selectedReservationIds;
    if (ids.isEmpty) return 0;
    var total = 0;
    for (final e in _draft.timetable.dates) {
      if (!e.isTask || !ids.contains(_identityOf(e))) continue;
      total += e.minutes;
    }
    return total;
  }

  void setSelectionMode(bool enabled) {
    if (_selectionMode == enabled) return;
    _selectionMode = enabled;
    if (!enabled) _selected.clear();
    notifyListeners();
  }

  void toggleSelectionMode() => setSelectionMode(!_selectionMode);

  /// 切换一个蓝色块的选中状态（选择模式的主入口）。
  void toggleSelection(String reservationId) {
    final id = reservationId.trim();
    if (id.isEmpty) return;
    if (!_selected.add(id)) _selected.remove(id);
    notifyListeners();
  }

  /// [toggleSelection] 的旧命名别名，保持已接入调用方可编译。
  void toggleReservation(String reservationId) => toggleSelection(reservationId);

  void setSelectedReservations(Iterable<String> ids) {
    final next = <String>{
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    };
    if (setEquals(next, _selected)) return;
    _selected
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  Set<String> _liveTaskIdentities() => <String>{
        for (final e in _draft.timetable.dates)
          if (e.isTask) _identityOf(e),
      };

  static String _identityOf(TimetableEntry entry) =>
      entry.reservationId ?? entry.id;
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

  /// 视口坐标 → 连续格坐标；不在【可见网格视口】内时返回 null。
  ///
  /// 先校验指针确实落在可写视口内，再扣时间轴、加滚动偏移。否则把指针拖到
  /// 表头、状态条或视口外时，滚动偏移会把它映射到隐藏时段并写入。
  Offset? toGrid(Offset viewportPoint) {
    if (dayWidth <= 0 || rowHeight <= 0) return null;
    if (!viewportPoint.dx.isFinite || !viewportPoint.dy.isFinite) return null;
    if (viewportPoint.dy < 0 || viewportPoint.dy >= viewportHeight) return null;
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

/// 网格的编辑命令目标：撤销/重做接日程事务，其他文本命令不适用。
///
/// 网格自己的撤销栈是时间表事务（一笔拖动 = 一笔），因此重做也必须走同一套
/// 业务快照恢复，而不是交给文本编辑器的 UndoHistory。
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
  bool canExecute(EditCommand command) => switch (command) {
        EditCommand.undo => controller.canUndo,
        EditCommand.redo => controller.canRedo,
        _ => false,
      };

  @override
  Future<void> execute(EditCommand command) async {
    switch (command) {
      case EditCommand.undo:
        controller.undo();
      case EditCommand.redo:
        controller.redo();
      default:
        return;
    }
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

  /// 具体日期是否允许绘制/擦除。用于把“可见周（UI）”限制在排程覆盖范围内，
  /// 避免在 coverage 之外画出不会随请求发送的规则。为 null 时全部允许。
  final bool Function(String date)? canEditDate;

  /// 选择模式下用户点选导致选中集合变化后回调新集合（身份规则见
  /// [TimetableGridController.selectedReservationIds]）。
  final ValueChanged<Set<String>>? onSelectionChanged;

  /// 只读外部日历占用（来自 ExternalCalendarService.busyFor）。
  ///
  /// 这些实例**不进入** [TimetableDraft]：网格只在最底层用浅灰斜纹叠加显示，
  /// 不参与绘制/擦除/蓝块绑定与撤销事务。为空时渲染与 0.2.1 完全一致。
  final List<ExternalBusyInstance> externalBusy;

  /// 外部来源 id → 名称（仅供悬停/点选信息显示，本地使用，不进入模型请求）。
  final Map<String, String> externalSourceNames;

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
    this.canEditDate,
    this.onSelectionChanged,
    this.externalBusy = const <ExternalBusyInstance>[],
    this.externalSourceNames = const <String, String>{},
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
    if (_disposed) return;
    // 切到选择模式时丢掉进行中的半笔：选择模式下单击不能被当成绘制。
    if (widget.controller.selectionMode && _pointer != null) {
      _endStroke(commit: false);
      return;
    }
    if (mounted) setState(() {});
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

  // ------------------------------------------------------------ selection

  /// 选中蓝色块在网格上的高亮区间（按日期分组，分钟坐标）。
  ///
  /// 用“日期 + 分钟区间”匹配而不是只用 reservationId：旧数据里没有
  /// reservationId 的未绑定蓝块也必须能高亮。
  Map<String, List<({int start, int end})>> _selectionRanges() {
    final ids = widget.controller.selectedReservationIds;
    if (ids.isEmpty) return const <String, List<({int start, int end})>>{};
    final out = <String, List<({int start, int end})>>{};
    for (final entry in _draft.timetable.dates) {
      if (!entry.isTask || entry.date == null) continue;
      final identity = entry.reservationId ?? entry.id;
      if (!ids.contains(identity)) continue;
      out.putIfAbsent(entry.date!, () => <({int start, int end})>[]).add(
            (start: entry.start, end: entry.end),
          );
    }
    return out;
  }

  /// 选择模式下点选一格：命中日期层蓝色块则切换选中，否则不改任何数据。
  void _toggleSelectionAt(TimetableCell cell, List<TimetableDay> days) {
    if (cell.day < 0 || cell.day >= days.length) return;
    final date = days[cell.day].date;
    final minute = cell.slot * kTimetableSlotMinutes;
    final identities = <String>{};
    for (final entry in _draft.timetable.dates) {
      if (entry.date != date || !entry.isTask) continue;
      if (!entry.coversMinute(minute)) continue;
      identities.add(entry.reservationId ?? entry.id);
    }
    if (identities.isEmpty) return;
    final next = widget.controller.selectedReservationIds.toSet();
    if (identities.every(next.contains)) {
      next.removeAll(identities);
    } else {
      next.addAll(identities);
    }
    widget.controller.setSelectedReservations(next);
    widget.onSelectionChanged?.call(widget.controller.selectedReservationIds);
  }

  // ---------------------------------------------------- 外部日历（只读占用）

  /// 命中的外部占用实例；外部数据不进入草稿，命中只用于“显示信息、禁止编辑”。
  ExternalBusyInstance? _externalAt(TimetableCell cell) {
    final busyList = widget.externalBusy;
    if (busyList.isEmpty) return null;
    final days = _days;
    if (cell.day < 0 || cell.day >= days.length) return null;
    final date = days[cell.day].date;
    final minute = cell.slot * kTimetableSlotMinutes;
    for (final busy in busyList) {
      if (busy.dayKey != date) continue;
      if (minute >= busy.startMinute && minute < busy.endMinute) return busy;
    }
    return null;
  }

  /// 外部占用的可读信息：显式写出「外部日历」「只读」，避免只靠颜色区分。
  String externalBusyLabel(ExternalBusyInstance busy) {
    final name = widget.externalSourceNames[busy.sourceId];
    final source = (name == null || name.trim().isEmpty)
        ? busy.sourceId
        : name.trim();
    final tentative = busy.tentative ? ' · 暂定' : '';
    return '${busy.dayKey} ${_hhmm(busy.startMinute)}-${_hhmm(busy.endMinute)}'
        ' · 外部日历$tentative · 来源：$source · 只读（不可绘制/擦除/绑定）';
  }

  /// 点选外部占用只显示信息：不落笔、不擦除、不改选择、不产生撤销事务。
  void _showExternalInfo(ExternalBusyInstance busy, {required bool notify}) {
    final text = externalBusyLabel(busy);
    if (text != _hoverText) {
      setState(() => _hoverText = text);
    }
    if (notify) widget.onHover?.call(text);
  }

  // ------------------------------------------------------------- gestures

  void _handleDown(PointerDownEvent event) {
    // 一笔进行中拒绝第二指针（鼠标第二键/触摸第二指）抢占；当前笔画的归属不变。
    if (_pointer != null) return;
    _focus.requestFocus();
    if (event.buttons & kMiddleMouseButton != 0) {
      if (widget.controller.selectionMode) return;
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
    // 外部日历占用是只读的：点选只显示信息，不绘制/擦除/选中/绑定。
    final external = _externalAt(cell);
    if (external != null) {
      _showExternalInfo(external, notify: true);
      return;
    }
    if (widget.controller.selectionMode) {
      // 选择模式只做选中切换：不落笔、不产生撤销事务；右键也不擦除。
      if (isErase) return;
      _toggleSelectionAt(cell, _days);
      return;
    }
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
      if (!widget.weeklyMode &&
          widget.canEditDate != null &&
          !widget.canEditDate!(day.date)) {
        // coverage 之外的日期不写入：它们不会进入请求，也不应静默影响本地排程。
        continue;
      }
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
    final manualText =
        '${d.date} ${_hhmm(start)}-${_hhmm(end)} · $title · $origin$bound'
        '${interval?.isPartialCell == true ? ' · 精确边界' : ''}'
        '${widget.weeklyMode || widget.canEditDate == null || widget.canEditDate!(d.date) ? '' : ' · 排程范围外（不可绘制）'}';
    // 外部占用叠加：手工数据优先显示；命中外部实例时追加只读信息。
    final external = _externalAt(cell);
    final text = external == null
        ? manualText
        : (interval == null || interval.state == TimetableState.free)
            ? externalBusyLabel(external)
            : '$manualText · 叠加：${externalBusyLabel(external)}';
    if (text != _hoverText) {
      setState(() => _hoverText = text);
      widget.onHover?.call(text);
    }
  }

  static String _hhmm(int minute) => WallClockRange.formatMinute(minute);

  static String _durationLabel(int minutes) =>
      '${minutes ~/ 60} 小时 ${minutes % 60} 分';

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
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final keyboard = HardwareKeyboard.instance;
              final control = keyboard.isControlPressed || keyboard.isMetaPressed;
              if (!control) return KeyEventResult.ignored;
              final key = event.logicalKey;
              // Ctrl+Z 撤销；Ctrl+Y 与 Ctrl+Shift+Z 都重做（与标题栏菜单一致）。
              if (key == LogicalKeyboardKey.keyZ && !keyboard.isShiftPressed) {
                widget.controller.undo();
                _changed();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.keyY ||
                  (key == LogicalKeyboardKey.keyZ && keyboard.isShiftPressed)) {
                widget.controller.redo();
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
                cursor: SystemMouseCursors.precise,
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
                                    selected: _selectionRanges(),
                                    externalBusy: widget.externalBusy,
                                    externalSourceNames:
                                        widget.externalSourceNames,
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
    final controller = widget.controller;
    final selected = controller.selectedReservationIds;
    final hint = _hoverText ??
        (controller.selectionMode
            ? '选择模式：单击蓝色块选中/取消'
                '${selected.isEmpty ? '' : ' · 已选 ${selected.length} 块 · ${_durationLabel(controller.selectedMinutes)}'}'
            : '左键绘制 · 拖动连续绘制 · 右键擦除 · 中键切换画笔 · Ctrl+Z 撤销 · Ctrl+Y 重做');
    final timetable = _draft.timetable;
    // 两个口径分开命名：本周实际可用（按 7 个真实日期展开）与每周模板容量。
    final stats = widget.weekStart.isNotEmpty && timetable.hasEntries
        ? '本周可用 ${_durationLabel(timetable.freeMinutesInWeek(widget.weekStart))}'
            ' · 每周模板 ${_durationLabel(timetable.freeMinutesPerWeek)}'
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
                      // 窄到单列只有几十像素时星期/日期宁可省略也不能换行撑高
                      // 表头（否则表头 Column 会纵向溢出）。
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: TsColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${_int(d.date.substring(5, 7))}/${_int(d.date.substring(8))}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
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
    // 时间轴标签高度随系统字号放大：固定 11 会把 1.5 倍字号的整点标签纵向裁掉。
    final labelHeight = 11.0 *
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6).toDouble();
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

/// 时间表蓝块（任务预留）的**不透明实色**。
///
/// 任务 01：蓝块内部必须是纯色，不能被底网格（小时/刻钟线）或未绑定区间的白色
/// 斜线贯穿。已绑定与未绑定用两种实色区分，形状差异（未绑定的左侧深色标记条）
/// 仍保留，避免只靠颜色表达状态。
class TimetableBlockColors {
  TimetableBlockColors._();

  /// 已绑定任务块：与按钮/选中控件同一个“选中蓝”。
  static Color get bound => TsColors.selected;

  /// 未绑定任务块：同色系的不透明浅蓝（向白色混合 45%，不是透明度）。
  static Color get unbound =>
      Color.lerp(TsColors.selected, const Color(0xFFFFFFFF), 0.45)!;

  /// 未绑定块的左侧标记条：同色系更深一档，作为非颜色的形状标记。
  static Color get unboundMarker =>
      Color.lerp(TsColors.selected, const Color(0xFF000000), 0.30)!;
}

class _GridPainter extends CustomPainter {
  final List<TimetableDay> days;
  final double width;
  final double rowHeight;
  final double topInset;

  /// 选中蓝色块的高亮区间：日期 → 分钟区间列表（选择模式）。
  final Map<String, List<({int start, int end})>> selected;

  /// 只读外部日历占用；只在网格最底层画斜纹，不覆盖手工数据。
  final List<ExternalBusyInstance> externalBusy;

  /// 外部来源 id → 名称（当前只用于将来扩展；绘制层不显示标题，保护隐私）。
  final Map<String, String> externalSourceNames;

  _GridPainter({
    required this.days,
    required this.width,
    required this.rowHeight,
    required this.topInset,
    this.selected = const <String, List<({int start, int end})>>{},
    this.externalBusy = const <ExternalBusyInstance>[],
    this.externalSourceNames = const <String, String>{},
  });

  static const Color _free = Color(0xFFFFFFFF);
  static const Color _occupied = Color(0xFF4B5563);
  static const Color _occupiedSoft = Color(0xFFE5E7EB);

  // 外部占用的视觉：浅灰底 + 灰色斜纹 + 左侧实心标记条 + 「外部」文字。
  // 斜纹与标记条是形状差异，不只靠颜色，和手工占用（实心深灰）/蓝块区分开。
  static const Color _externalFill = Color(0xFFF1F2F4);
  static const Color _externalHatch = Color(0xFF9CA3AF);
  static const Color _externalMarker = Color(0xFF6B7280);
  static const Color _externalBorder = Color(0xFF9CA3AF);
  static const double _externalMarkerWidth = 3;
  static const double _externalHatchSpacing = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final dayWidth = width / 7;
    final height = kTimetableSlotsPerDay * rowHeight;
    final fill = Paint()..style = PaintingStyle.fill;
    // 任务蓝块：两种不透明实色（已绑定/未绑定），块内部不会被网格线或白斜线贯穿。
    final taskBound = TimetableBlockColors.bound;
    final taskUnbound = TimetableBlockColors.unbound;

    for (var i = 0; i < days.length && i < 7; i++) {
      final left = i * dayWidth;
      final day = days[i];
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(left, topInset, dayWidth, height));

      // 1) 当日底色。
      fill.color = _free;
      canvas.drawRect(
          Rect.fromLTWH(left, topInset, dayWidth, height), fill);

      // 2) 底网格（小时/刻钟线）先画。任务块与外部占用随后覆盖它，因此块内部
      //    不会出现贯穿的周期性横线（任务 01 的第一个来源）。
      _paintGridLines(canvas, left, dayWidth);

      // 3) 只读外部占用画在手工数据下面：手工占用/蓝块始终可见、可编辑。
      _paintExternalBusy(canvas, day, left, dayWidth);

      // 4) 手工区间：不透明纯色，后画所以完整覆盖底网格。
      for (final interval in day.intervals) {
        if (interval.state == TimetableState.free) continue;
        final isTask = interval.state == TimetableState.task;
        fill.color = isTask
            ? (interval.taskId == null ? taskUnbound : taskBound)
            : _occupied;
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
        if (isTask && interval.taskId == null) {
          // 未绑定：左侧实心深色标记条（形状差异，不只依赖颜色深浅）。
          canvas.drawRect(
            Rect.fromLTWH(left + 1, top, 2, bottom - top),
            Paint()..color = TimetableBlockColors.unboundMarker,
          );
        }
        // 选择模式高亮：选中的蓝色块加蓝色边框与淡色底，避免只靠颜色区分
        // 未选中/已选中；未绑定蓝块也能高亮（按日期+分钟匹配）。
        if (isTask) {
          final ranges = selected[day.date];
          if (ranges != null) {
            for (final range in ranges) {
              final overlapStart = math.max(range.start, interval.start);
              final overlapEnd = math.min(range.end, interval.end);
              if (overlapEnd <= overlapStart) continue;
              final highlightTop =
                  topInset + overlapStart / 60 * 4 * rowHeight;
              final highlightBottom =
                  topInset + overlapEnd / 60 * 4 * rowHeight;
              final rect = Rect.fromLTWH(
                  left + 1, highlightTop, dayWidth - 2,
                  highlightBottom - highlightTop);
              canvas.drawRect(
                  rect, Paint()..color = const Color(0x332563EB));
              canvas.drawRect(
                rect,
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2
                  ..color = const Color(0xFF2563EB),
              );
            }
          }
        }
      }

      // 5) 日分隔竖线（画在块边缘之外，不进入块内部）。
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

  /// 15 分钟线与整点线：只画在手工区间之前，作为背景网格。
  void _paintGridLines(Canvas canvas, double left, double dayWidth) {
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
  }

  /// 画一个自然日内的外部占用：浅灰斜纹 + 左侧标记条 + 「外部」文字。
  ///
  /// [dayWidth]/[left] 是该日在网格里的横向几何；实例的 [ExternalBusyInstance.dayKey]
  /// 与当前天一致时才画，[startMinute]/[endMinute] 是当天内的分钟。
  void _paintExternalBusy(
      Canvas canvas, TimetableDay day, double left, double dayWidth) {
    if (externalBusy.isEmpty) return;
    for (final busy in externalBusy) {
      if (busy.dayKey != day.date) continue;
      final start = busy.startMinute.clamp(0, kTimetableMinutesPerDay);
      final end = busy.endMinute.clamp(0, kTimetableMinutesPerDay);
      if (end <= start) continue;
      final top = topInset + start / 60 * 4 * rowHeight;
      final bottom = topInset + end / 60 * 4 * rowHeight;
      final rect = Rect.fromLTWH(left + 1, top, dayWidth - 2, bottom - top);
      if (rect.width <= 0 || rect.height <= 0) continue;

      // 浅灰底。
      canvas.drawRect(rect, Paint()..color = _externalFill);

      // 灰色斜纹：裁剪在实例矩形内，不会画到相邻格子。
      canvas.save();
      canvas.clipRect(rect);
      final hatch = Paint()
        ..color = _externalHatch.withValues(alpha: 0.55)
        ..strokeWidth = 1;
      for (var y = rect.top - rect.width;
          y < rect.bottom;
          y += _externalHatchSpacing) {
        canvas.drawLine(
          Offset(rect.left, y),
          Offset(rect.right, y + rect.width),
          hatch,
        );
      }
      canvas.restore();

      // 左侧来源/只读标记条（形状差异，不只靠颜色）。
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, _externalMarkerWidth, rect.height),
        Paint()..color = _externalMarker,
      );
      // 每个实例的左上角再画一个小圆点，强调“这是外部来源”。
      if (rect.height >= 12) {
        canvas.drawCircle(
          Offset(rect.left + _externalMarkerWidth + 4, rect.top + 4),
          2.2,
          Paint()..color = _externalMarker,
        );
      }
      // 顶部虚线边框：与手工占用（实心描边）区分。
      final border = Paint()
        ..color = _externalBorder
        ..strokeWidth = 1;
      for (var x = rect.left + 3; x < rect.right; x += 6) {
        canvas.drawLine(Offset(x, rect.top),
            Offset(math.min(x + 3, rect.right), rect.top), border);
      }
      // 足够高时写「外部」两个字：文字本身也是非颜色区分。
      if (rect.height >= 18 && rect.width >= 34) {
        final label = TextPainter(
          text: TextSpan(
            text: '外部',
            style: TextStyle(
              fontSize: 8,
              color: TsColors.textSecondary,
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(
          canvas,
          Offset(rect.left + _externalMarkerWidth + 2, rect.top + 2),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.days != days ||
      old.width != width ||
      old.rowHeight != rowHeight ||
      old.topInset != topInset ||
      old.selected != selected ||
      old.externalBusy != externalBusy ||
      old.externalSourceNames != externalSourceNames;
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
