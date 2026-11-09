// 共享的年月日历选择控件（0.5.0 任务 03）。
//
// 三处用途共用同一套“点字段 → 年月日”的导航：
//   * 执行回顾「自定义」范围：两个 [DatePickerField] + 草稿/应用值（本文件只提供
//     字段与弹层，草稿/应用逻辑由调用方掌握）；
//   * 日程列表的日期标题跳转：调用 [showCalendarPopup] 直接取日期；
//   * 日程编辑的开始/结束字段：直接使用 [DatePickerField]。
//
// 交互约定（与产品框架一致）：
//   * 点字段展开：日格；点年份标题 → 12 年一页的年份网格（左右翻页）；点月份标题
//     → 1–12 月网格；选年进月格、选月回日格；左右箭头翻月；「今天」回填本地今天。
//   * 周一为首列；相邻月（淡色）、今天（描边）、已选中（实心）、键盘焦点（焦点环）
//     四态区分；方向键移动焦点、Enter/Space 选日、Esc 关闭不提交。
//   * 浮窗贴近字段，靠近窗口边缘时向上/向左翻转展开；点空白关闭不提交。
//
// 日期类型约定：所有日期都是“本地日期的 naive 值”，即 `DateTime.utc(y, m, d)`
// （与 model/schedule_event.dart 的 dateKeyToUtc、state/execution/effort_stats.dart
// 的 parseLocalDate 相同），不经过 UTC 换算，因此不会丢最后一天。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'bezier_ui.dart';

/// 日历/日期字段统一的日期文案：`yyyy-MM-dd`。
String formatDatePickerDate(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 归一为本地日期（naive，isUtc == true）。
DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _localToday([DateTime? today]) {
  final now = today ?? DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
}

bool _sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 单日期字段：点字段（或右侧日历图标）弹出 [CalendarPopup]，选日后回调 [onChanged]。
///
/// 生效时机由调用方决定：控件不内置“应用/保存”，只把用户选中的日期回调出去。
class DatePickerField extends StatefulWidget {
  const DatePickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder = '选择日期',
    this.firstDate,
    this.lastDate,
    this.enabled = true,
    this.showIcon = true,
    this.width,
    this.pickIconKey,
    this.focusNode,
    this.today,
  });

  /// 当前值（本地日期）；null = 未选择，显示 [placeholder]。
  final DateTime? value;

  /// 用户选中某一天时回调；取消/点空白/Esc 不会调用。
  final ValueChanged<DateTime> onChanged;

  /// 字段内的标签（如「开始日期」）；null = 不显示标签。
  final String? label;

  final String placeholder;

  /// 可选日期下限（含）；null = 不限制。
  final DateTime? firstDate;

  /// 可选日期上限（含）；null = 不限制。
  final DateTime? lastDate;

  final bool enabled;

  /// 是否显示右侧日历图标。
  final bool showIcon;

  /// 字段宽度；null = 按内容自适应（有界）。日程编辑器/回顾弹窗传显式宽度。
  final double? width;

  /// 右侧日历图标的 Key（测试/定位用）。
  final Key? pickIconKey;

  /// 外部焦点节点（可选）；不传时字段内部自建。
  final FocusNode? focusNode;

  /// 测试注入“今天”；默认本地今天。
  final DateTime? today;

  @override
  State<DatePickerField> createState() => _DatePickerFieldState();
}

class _DatePickerFieldState extends State<DatePickerField> {
  FocusNode? _internalFocus;
  bool _opening = false;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocus!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _internalFocus = FocusNode(debugLabel: 'date-picker-field');
    }
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant DatePickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChanged);
      _internalFocus?.removeListener(_onFocusChanged);
      if (widget.focusNode == null) {
        _internalFocus ??= FocusNode(debugLabel: 'date-picker-field');
      }
      _focusNode.addListener(_onFocusChanged);
    }
    if (!widget.enabled) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _internalFocus?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    if (!widget.enabled || _opening) return;
    _opening = true;
    final picked = await showCalendarPopup(
      context,
      anchorContext: context,
      initialDate: widget.value ?? _localToday(widget.today),
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      today: widget.today,
    );
    _opening = false;
    if (!mounted) return;
    if (picked != null) {
      widget.onChanged(_dateOnly(picked));
    }
    // 关闭后把焦点还给字段：Esc/点空白取消后键盘位置仍然合理。
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final hasValue = value != null;
    final text = hasValue ? formatDatePickerDate(value) : widget.placeholder;
    final focused = _focusNode.hasFocus && widget.enabled;
    final borderColor = !widget.enabled
        ? TsColors.border
        : (focused ? TsColors.accent : TsColors.border);

    final content = SizedBox(
      height: 34,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.label != null) ...[
              Text(
                widget.label!,
                style: TextStyle(
                  fontSize: 11,
                  color: widget.enabled
                      ? TsColors.textSecondary
                      : TsColors.onButtonDisabled,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: hasValue ? FontWeight.w500 : FontWeight.w400,
                  color: !widget.enabled
                      ? TsColors.onButtonDisabled
                      : (hasValue ? TsColors.textPrimary : TsColors.textFaint),
                ),
              ),
            ),
            if (widget.showIcon) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.calendar_today_outlined,
                key: widget.pickIconKey,
                size: 13,
                color: widget.enabled
                    ? TsColors.textSecondary
                    : TsColors.onButtonDisabled,
              ),
            ],
          ],
        ),
      ),
    );

    final field = Material(
      color: widget.enabled ? TsColors.surface : TsColors.surfaceAlt,
      shape: BezierRoundedRectangleBorder(
        radius: 8,
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.enabled ? _open : null,
        customBorder: const BezierRoundedRectangleBorder(radius: 8),
        hoverColor: TsColors.accent.withValues(alpha: 0.06),
        child: content,
      ),
    );

    final sized = widget.width != null
        ? SizedBox(width: widget.width, child: field)
        : ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 112, maxWidth: 200),
            child: field,
          );
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.enabled,
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: widget.label == null ? text : '${widget.label} $text',
        child: sized,
      ),
    );
  }
}

/// 在 [anchorContext] 附近弹出日历，返回用户选中的本地日期；取消/Esc/点空白返回 null。
///
/// 供没有内联字段的入口使用（例如日程列表的日期标题）：调用方只负责把返回的日期
/// 应用到自己的状态，不需要关心弹层定位与关闭。
Future<DateTime?> showCalendarPopup(
  BuildContext context, {
  required BuildContext anchorContext,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  DateTime? today,
  double gap = 6,
  double margin = 8,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  if (anchorBox == null || !anchorBox.hasSize) {
    return Future<DateTime?>.value(null);
  }
  final anchorRect = anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final origin = overlayBox != null && overlayBox.hasSize
      ? overlayBox.localToGlobal(Offset.zero)
      : Offset.zero;

  final completer = Completer<DateTime?>();
  late OverlayEntry entry;
  var closed = false;
  void close([DateTime? value]) {
    if (closed) return;
    closed = true;
    entry.remove();
    if (!completer.isCompleted) completer.complete(value);
  }

  entry = OverlayEntry(
    builder: (_) => Stack(
      children: [
        // 点空白关闭且不提交：铺满的透明挡层在弹层下面。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => close(),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _CalendarPopupPositionDelegate(
              anchorRect: anchorRect,
              origin: origin,
              gap: gap,
              margin: margin,
            ),
            child: CalendarPopup(
              initialDate: initialDate,
              firstDate: firstDate,
              lastDate: lastDate,
              today: today,
              onSelected: close,
              onCancel: () => close(),
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

enum _CalendarView { day, month, year }

/// 弹出层本体：日格 / 1–12 月 / 年份网格三视图。
///
/// 可单独 pump 做 widget 测试；[DatePickerField] 与 [showCalendarPopup] 内部都复用它。
class CalendarPopup extends StatefulWidget {
  const CalendarPopup({
    super.key,
    required this.initialDate,
    required this.onSelected,
    this.onCancel,
    this.firstDate,
    this.lastDate,
    this.today,
  });

  /// 打开时高亮/定位的日期（本地日期）。
  final DateTime initialDate;

  /// 用户选中某一天时回调（弹层是否关闭由调用方决定）。
  final ValueChanged<DateTime> onSelected;

  /// 用户按 Esc 时回调；null = 不处理。
  final VoidCallback? onCancel;

  final DateTime? firstDate;
  final DateTime? lastDate;

  /// 测试注入“今天”；默认本地今天。
  final DateTime? today;

  @override
  State<CalendarPopup> createState() => _CalendarPopupState();
}

class _CalendarPopupState extends State<CalendarPopup> {
  static const double _width = 296;
  static const double _cellHeight = 34;
  static const double _monthCellHeight = 40;

  final FocusNode _focusNode = FocusNode(debugLabel: 'calendar-popup');

  /// 当前展示的月份（当月 1 日）。
  late DateTime _visibleMonth;

  /// 键盘焦点所在日期。
  late DateTime _focusedDate;

  late DateTime _today;

  _CalendarView _view = _CalendarView.day;

  /// 年份网格当前页的第一个年份（12 年一页）。
  int _yearPageStart = 0;

  DateTime? get _selected => _latestSelected;
  DateTime? _latestSelected;

  @override
  void initState() {
    super.initState();
    _today = _localToday(widget.today);
    final initial = _clampToRange(_dateOnly(widget.initialDate));
    _latestSelected = initial;
    _focusedDate = initial;
    _visibleMonth = DateTime.utc(initial.year, initial.month, 1);
    _yearPageStart = (initial.year ~/ 12) * 12;
    _focusNode.addListener(_onFocusChanged);
    // 弹层插进 Overlay 后，autofocus 在部分宿主（如弹窗内的浮层）不一定抢到
    // 焦点；这里在首帧结束后显式请求一次，保证 Esc / 方向键可用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  DateTime _clampToRange(DateTime date) {
    final first = widget.firstDate == null ? null : _dateOnly(widget.firstDate!);
    final last = widget.lastDate == null ? null : _dateOnly(widget.lastDate!);
    if (first != null && date.isBefore(first)) return first;
    if (last != null && date.isAfter(last)) return last;
    return date;
  }

  bool _isSelectable(DateTime date) {
    final first = widget.firstDate == null ? null : _dateOnly(widget.firstDate!);
    final last = widget.lastDate == null ? null : _dateOnly(widget.lastDate!);
    if (first != null && date.isBefore(first)) return false;
    if (last != null && date.isAfter(last)) return false;
    return true;
  }

  void _select(DateTime date) {
    final normalized = _dateOnly(date);
    setState(() {
      _latestSelected = normalized;
      _focusedDate = normalized;
      _visibleMonth = DateTime.utc(normalized.year, normalized.month, 1);
    });
    widget.onSelected(normalized);
  }

  void _selectToday() {
    final today = _today;
    if (_isSelectable(today)) {
      _select(today);
      return;
    }
    // 今天超出可选范围：只导航到今天的月份，不提交。
    setState(() {
      _visibleMonth = DateTime.utc(today.year, today.month, 1);
      _focusedDate = _clampToRange(today);
      _view = _CalendarView.day;
    });
  }

  void _shiftMonth(int delta) {
    setState(() {
      _visibleMonth =
          DateTime.utc(_visibleMonth.year, _visibleMonth.month + delta, 1);
    });
  }

  void _shiftYear(int delta) {
    setState(() {
      _visibleMonth = DateTime.utc(_visibleMonth.year + delta, _visibleMonth.month, 1);
    });
  }

  void _shiftYearPage(int delta) {
    setState(() {
      _yearPageStart += delta * 12;
    });
  }

  void _openYearView() {
    setState(() {
      _view = _CalendarView.year;
      _yearPageStart = (_visibleMonth.year ~/ 12) * 12;
    });
  }

  void _openMonthView() {
    setState(() => _view = _CalendarView.month);
  }

  void _chooseYear(int year) {
    setState(() {
      _visibleMonth = DateTime.utc(year, _visibleMonth.month, 1);
      _view = _CalendarView.month;
    });
  }

  void _chooseMonth(int month) {
    setState(() {
      _visibleMonth = DateTime.utc(_visibleMonth.year, month, 1);
      _view = _CalendarView.day;
    });
  }

  void _moveFocus(int dayDelta) {
    final next = _focusedDate.add(Duration(days: dayDelta));
    setState(() {
      _focusedDate = next;
      _visibleMonth = DateTime.utc(next.year, next.month, 1);
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onCancel?.call();
      return KeyEventResult.handled;
    }
    if (_view != _CalendarView.day) {
      if (key == LogicalKeyboardKey.backspace) {
        setState(() => _view = _CalendarView.day);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveFocus(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveFocus(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-7);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocus(7);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_isSelectable(_focusedDate)) _select(_focusedDate);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        if (_view == _CalendarView.day) ...[
          const SizedBox(height: 2),
          _weekdayRow(),
          const SizedBox(height: 2),
          _dayGrid(),
          const SizedBox(height: 2),
          Divider(height: 1, color: TsColors.border),
          SizedBox(
            height: 34,
            child: Center(
              child: TextButton(
                key: const Key('calendar-today'),
                style: TsButtons.link(fontSize: 12),
                onPressed: _selectToday,
                child: const Text('今天'),
              ),
            ),
          ),
        ] else if (_view == _CalendarView.month)
          _monthGrid()
        else
          _yearGrid(),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        key: const Key('calendar-popup'),
        elevation: 10,
        color: TsColors.surface,
        clipBehavior: Clip.antiAlias,
        shape: BezierRoundedRectangleBorder(
          radius: 12,
          side: BorderSide(color: TsColors.border),
        ),
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _width,
              maxHeight: math.max(120, media.height - 24),
            ),
            child: SizedBox(
              width: _width,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 头部

  Widget _header() {
    final children = <Widget>[];
    switch (_view) {
      case _CalendarView.day:
        children.addAll([
          _navButton(
            key: const Key('calendar-prev-month'),
            icon: Icons.chevron_left,
            tooltip: '上个月',
            onTap: () => _shiftMonth(-1),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _titleButton(
                  key: const Key('calendar-year-button'),
                  label: '${_visibleMonth.year}年',
                  onTap: _openYearView,
                ),
                const SizedBox(width: 2),
                _titleButton(
                  key: const Key('calendar-month-button'),
                  label: '${_visibleMonth.month}月',
                  onTap: _openMonthView,
                ),
              ],
            ),
          ),
          _navButton(
            key: const Key('calendar-next-month'),
            icon: Icons.chevron_right,
            tooltip: '下个月',
            onTap: () => _shiftMonth(1),
          ),
        ]);
      case _CalendarView.month:
        children.addAll([
          _navButton(
            key: const Key('calendar-prev-month'),
            icon: Icons.chevron_left,
            tooltip: '上一年',
            onTap: () => _shiftYear(-1),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _titleButton(
                  key: const Key('calendar-year-button'),
                  label: '${_visibleMonth.year}年',
                  onTap: _openYearView,
                ),
                const SizedBox(width: 2),
                _titleButton(
                  key: const Key('calendar-back-to-day'),
                  label: '月',
                  onTap: () => setState(() => _view = _CalendarView.day),
                ),
              ],
            ),
          ),
          _navButton(
            key: const Key('calendar-next-month'),
            icon: Icons.chevron_right,
            tooltip: '下一年',
            onTap: () => _shiftYear(1),
          ),
        ]);
      case _CalendarView.year:
        children.addAll([
          _navButton(
            key: const Key('calendar-year-page-prev'),
            icon: Icons.chevron_left,
            tooltip: '上 12 年',
            onTap: () => _shiftYearPage(-1),
          ),
          Expanded(
            child: Center(
              child: Text(
                '$_yearPageStart – ${_yearPageStart + 11}',
                key: const Key('calendar-year-range'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
            ),
          ),
          _navButton(
            key: const Key('calendar-year-page-next'),
            icon: Icons.chevron_right,
            tooltip: '下 12 年',
            onTap: () => _shiftYearPage(1),
          ),
        ]);
    }
    return SizedBox(height: 34, child: Row(children: children));
  }

  Widget _navButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      style: TsButtons.icon(size: 28),
      onPressed: onTap,
      icon: Icon(icon, size: 17),
    );
  }

  Widget _titleButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton(
      key: key,
      style: TextButton.styleFrom(
        foregroundColor: TsColors.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 28),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          fontFamily: kUiFontFamily,
          fontFamilyFallback: kUiFontFallback,
        ),
      ),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const Icon(Icons.arrow_drop_down, size: 16),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 日格

  Widget _weekdayRow() {
    const labels = <String>['一', '二', '三', '四', '五', '六', '日'];
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Center(
                child: Text(
                  labels[i],
                  key: Key('calendar-weekday-$i'),
                  style: TextStyle(fontSize: 11, color: TsColors.textFaint),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dayGrid() {
    final first = DateTime.utc(_visibleMonth.year, _visibleMonth.month, 1);
    final leading = first.weekday - DateTime.monday;
    final start = first.subtract(Duration(days: leading));
    final rows = <Widget>[];
    for (var row = 0; row < 6; row++) {
      final cells = <Widget>[];
      for (var col = 0; col < 7; col++) {
        final date = start.add(Duration(days: row * 7 + col));
        cells.add(Expanded(child: _dayCell(date)));
      }
      rows.add(SizedBox(height: _cellHeight, child: Row(children: cells)));
    }
    return Column(children: rows);
  }

  Widget _dayCell(DateTime date) {
    final inMonth =
        date.year == _visibleMonth.year && date.month == _visibleMonth.month;
    final isSelected = _selected != null && _sameDate(date, _selected!);
    final isToday = _sameDate(date, _today);
    final isFocused = _focusNode.hasFocus && _sameDate(date, _focusedDate);
    final selectable = _isSelectable(date);

    Color textColor;
    if (isSelected) {
      textColor = TsColors.onButton;
    } else if (!inMonth) {
      textColor = TsColors.textFaint;
    } else if (isToday) {
      textColor = TsColors.accent;
    } else {
      textColor = TsColors.textPrimary;
    }
    if (!selectable) {
      textColor = textColor.withValues(alpha: 0.38);
    }

    BoxDecoration? decoration;
    if (isSelected) {
      decoration = BoxDecoration(
        color: selectable ? TsColors.accent : TsColors.selectedDisabled,
        borderRadius: BorderRadius.circular(8),
      );
    } else if (isFocused) {
      decoration = BoxDecoration(
        border: Border.all(color: TsColors.accent, width: 2),
        borderRadius: BorderRadius.circular(8),
      );
    } else if (isToday) {
      decoration = BoxDecoration(
        border: Border.all(color: TsColors.accent, width: 1),
        borderRadius: BorderRadius.circular(8),
      );
    }

    return Semantics(
      button: true,
      selected: isSelected,
      enabled: selectable,
      label: '${date.year}年${date.month}月${date.day}日'
          '${isToday ? ' 今天' : ''}${inMonth ? '' : ' 相邻月'}',
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: Key('calendar-day-${formatDatePickerDate(date)}'),
            customBorder: const BezierRoundedRectangleBorder(radius: 8),
            onTap: selectable ? () => _select(date) : null,
            hoverColor: TsColors.accent.withValues(alpha: 0.08),
            child: Container(
              decoration: decoration,
              alignment: Alignment.center,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.0,
                  fontWeight:
                      isSelected || isToday ? FontWeight.w600 : FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 月 / 年

  Widget _monthGrid() {
    final rows = <Widget>[];
    for (var row = 0; row < 3; row++) {
      final cells = <Widget>[];
      for (var col = 0; col < 4; col++) {
        final month = row * 4 + col + 1;
        cells.add(Expanded(child: _monthCell(month)));
      }
      rows.add(SizedBox(height: _monthCellHeight, child: Row(children: cells)));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Column(children: rows),
    );
  }

  Widget _monthCell(int month) {
    final isSelected = _selected != null &&
        _selected!.year == _visibleMonth.year &&
        _selected!.month == month;
    final isCurrent = _visibleMonth.month == month;
    final isToday = _today.year == _visibleMonth.year && _today.month == month;
    Color textColor = isSelected
        ? TsColors.onButton
        : (isCurrent ? TsColors.accent : TsColors.textPrimary);
    if (!isSelected && isToday && !isCurrent) textColor = TsColors.accent;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('calendar-month-$month'),
          customBorder: const BezierRoundedRectangleBorder(radius: 8),
          onTap: () => _chooseMonth(month),
          hoverColor: TsColors.accent.withValues(alpha: 0.08),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? TsColors.accent
                  : (isCurrent ? TsColors.accentSoft : null),
              borderRadius: BorderRadius.circular(8),
              border: isToday && !isSelected
                  ? Border.all(color: TsColors.accent, width: 1)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '$month月',
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    isSelected || isCurrent ? FontWeight.w600 : FontWeight.w400,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _yearGrid() {
    final rows = <Widget>[];
    for (var row = 0; row < 3; row++) {
      final cells = <Widget>[];
      for (var col = 0; col < 4; col++) {
        final year = _yearPageStart + row * 4 + col;
        cells.add(Expanded(child: _yearCell(year)));
      }
      rows.add(SizedBox(height: _monthCellHeight, child: Row(children: cells)));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Column(children: rows),
    );
  }

  Widget _yearCell(int year) {
    final isSelected =
        _selected != null && _selected!.year == year;
    final isCurrent = _visibleMonth.year == year;
    final textColor = isSelected
        ? TsColors.onButton
        : (isCurrent ? TsColors.accent : TsColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('calendar-year-$year'),
          customBorder: const BezierRoundedRectangleBorder(radius: 8),
          onTap: () => _chooseYear(year),
          hoverColor: TsColors.accent.withValues(alpha: 0.08),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? TsColors.accent
                  : (isCurrent ? TsColors.accentSoft : null),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '$year年',
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    isSelected || isCurrent ? FontWeight.w600 : FontWeight.w400,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把弹层放进 anchor 附近：优先下方/左对齐，靠近窗口边缘时向上/向右对齐，
/// 并保证不越出可用区域。使用 [SingleChildLayoutDelegate] 在拿到弹层真实尺寸后
/// 再定位，因此不需要估算高度（日格/月格/年格高度不同）。
class _CalendarPopupPositionDelegate extends SingleChildLayoutDelegate {
  _CalendarPopupPositionDelegate({
    required this.anchorRect,
    required this.origin,
    required this.gap,
    required this.margin,
  });

  /// 锚点控件的全局矩形。
  final Rect anchorRect;

  /// Overlay 布局坐标系的全局原点。
  final Offset origin;

  final double gap;
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - margin * 2),
      maxHeight: math.max(0, constraints.maxHeight - margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final anchor = anchorRect.shift(-origin);
    final maxLeft = math.max(margin, size.width - childSize.width - margin);
    final maxTop = math.max(margin, size.height - childSize.height - margin);

    // 水平：优先与字段左对齐；右侧放不下就右对齐；再不行贴边。
    double left = anchor.left;
    if (left + childSize.width > size.width - margin) {
      left = anchor.right - childSize.width;
    }
    left = left.clamp(margin, maxLeft).toDouble();

    // 垂直：优先下方；下方放不下且上方放得下则向上展开。
    final below = anchor.bottom + gap;
    final above = anchor.top - gap - childSize.height;
    final fitsBelow = below + childSize.height <= size.height - margin;
    final fitsAbove = above >= margin;
    double top = (!fitsBelow && fitsAbove) ? above : below;
    top = top.clamp(margin, maxTop).toDouble();

    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _CalendarPopupPositionDelegate oldDelegate) =>
      anchorRect != oldDelegate.anchorRect ||
      origin != oldDelegate.origin ||
      gap != oldDelegate.gap ||
      margin != oldDelegate.margin;
}
