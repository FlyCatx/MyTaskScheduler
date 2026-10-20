// 日历甘特图：横轴为真实日期时间，每个任务一行、可含多个可拖动片段。
// 每次编辑在指针抬起或菜单动作时一次性提交；冲突允许并标记，不阻塞也不自动消解；
// 待确认/受阻任务显示为暂定片段并保留原状态。
//
// 主要类型：CalendarGanttView、CalendarActions、CalendarScale。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/calendar.dart';
import '../model/display.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../model/timetable.dart';
import '../state/calendar_planner.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import './widgets/bezier_menu.dart';
import 'calendar_settings_dialog.dart';
import 'segment_edit_dialog.dart';
import 'theme.dart';

/// Everything the calendar view may do to the plan. Injected so widget tests can run
/// without a controller, a DLL or storage.
class CalendarActions {
  final bool canEdit;
  final Future<bool> Function(CalendarEditOutcome outcome) commit;
  final Future<CalendarAutoPlan?> Function({required bool keepManual})
      autoSchedule;
  final Future<bool> Function(CalendarSettings settings,
      {required bool reschedule}) applySettings;
  final Future<String?> Function() ensureReady;
  final Map<String, String> taskNotes;

  /// 0.1.1：当前版本的结构化时间表与三项通用设置。
  final Timetable? timetable;
  final int weekStartsOn;
  final CalendarEditorMode defaultEditor;
  final List<UnavailableRange> defaultUnavailableRanges;
  final Map<String, String> taskNames;

  /// 同时提交 CalendarSettings 与 Timetable；为空时退回 [applySettings]。
  final Future<bool> Function(CalendarSettings settings, Timetable timetable,
      {required bool reschedule})? applyTimetable;

  const CalendarActions({
    required this.commit,
    required this.autoSchedule,
    required this.applySettings,
    required this.ensureReady,
    this.canEdit = true,
    this.taskNotes = const <String, String>{},
    this.timetable,
    this.weekStartsOn = 1,
    this.defaultEditor = CalendarEditorMode.drawing,
    this.defaultUnavailableRanges = const <UnavailableRange>[],
    this.taskNames = const <String, String>{},
    this.applyTimetable,
  });

  static CalendarActions readOnly() => CalendarActions(
        canEdit: false,
        commit: (_) async => false,
        autoSchedule: ({required bool keepManual}) async => null,
        applySettings: (settings, {required bool reschedule}) async => false,
        ensureReady: () async => 'read-only',
      );
}

enum CalendarScale { day, week }

enum _DragMode { move, resizeStart, resizeEnd }

class _DragSession {
  final String segmentId;
  final String taskId;
  final _DragMode mode;
  final DateTime originalStart;
  final DateTime originalEnd;
  final double pointerStartX;
  DateTime previewStart;
  DateTime previewEnd;
  bool invalid;
  String? conflictHint;

  _DragSession({
    required this.segmentId,
    required this.taskId,
    required this.mode,
    required this.originalStart,
    required this.originalEnd,
    required this.pointerStartX,
  })  : previewStart = originalStart,
        previewEnd = originalEnd,
        invalid = false;

  int get minutes => previewEnd.difference(previewStart).inMinutes;
}

class CalendarGanttView extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final PlanVersion? version;
  final CalendarSchedule schedule;
  final TaskInteraction interaction;
  final CalendarActions actions;
  final DateTime? clock;

  /// Supplies the "从材料识别" candidates to the settings dialog. Null when the
  /// calendar is read-only (history version) or in a test without a controller.
  final CalendarProposalSource? proposalSource;

  const CalendarGanttView({
    super.key,
    required this.snapshot,
    required this.version,
    required this.schedule,
    required this.interaction,
    required this.actions,
    this.clock,
    this.proposalSource,
  });

  @override
  State<CalendarGanttView> createState() => _CalendarGanttViewState();
}

class _CalendarGanttViewState extends State<CalendarGanttView> {
  static const double labelWidth = 214;
  static const double rowPadding = 6;
  static const double laneHeight = 22;
  static const double laneGap = 2;
  static const double headerHeight = 46;
  static const double edgeGrab = 7;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  final GlobalKey _contentKey = GlobalKey();
  final FocusNode _dragFocus = FocusNode(debugLabel: 'calendar-drag');
  final Map<String, GlobalKey> _labels = {};

  CalendarScale _scale = CalendarScale.day;
  double _zoom = 1;
  double _hOffset = 0;
  DateTime? _now;
  Timer? _nowTimer;
  DateTime? _flashUntil;
  String? _flashSegmentId;

  _DragSession? _drag;
  Timer? _autoScroll;
  Offset? _lastGlobal;

  /// 本次水平拖动是否从空白时间轴开始。按下/超过拖动阈值时决定，移动中不切换。
  bool _blankPan = false;

  /// Which plan version has already been offered the one-time "generate the initial
  /// schedule" step. Keyed by version id (not by callback identity) so a rebuild can
  /// never re-run the automatic pass in a loop.
  String? _readyVersionId;

  @override
  void initState() {
    super.initState();
    _now = widget.clock ?? DateTime.now();
    _horizontal.addListener(_onHorizontal);
    _nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() => _now = widget.clock ?? DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureReady());
    if (!_initialScrollPlanned) _planInitialScroll();
  }

  bool _initialScrollPlanned = false;

  void _planInitialScroll() {
    _initialScrollPlanned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFocus(animate: false);
    });
  }

  /// Opens the view where the work actually is: the first scheduled segment, otherwise
  /// today, otherwise the start of the range. Opening at 00:00 of the first day would
  /// show an empty timeline whenever the plan starts later in the day.
  void _scrollToFocus({bool animate = true}) {
    final segments = widget.schedule.segments;
    DateTime? anchor;
    if (segments.isNotEmpty) {
      anchor = segments
          .map((s) => s.start)
          .reduce((a, b) => a.isBefore(b) ? a : b);
    } else {
      final now = _now ?? DateTime.now();
      if (!now.isBefore(_rangeStart) && !now.isAfter(_settings.endInstant)) {
        anchor = now;
      }
    }
    if (anchor == null) {
      _scrollToToday(animate: animate);
      return;
    }
    if (!_horizontal.hasClients) return;
    final target = (_xFor(anchor) - 90).clamp(
      0.0,
      _horizontal.position.maxScrollExtent,
    );
    if (animate) {
      _horizontal.animateTo(target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic);
    } else {
      _horizontal.jumpTo(target);
    }
  }

  Future<void> _ensureReady() async {
    final id = widget.version?.id;
    if (_readyVersionId == id) return;
    _readyVersionId = id;
    await widget.actions.ensureReady();
  }

  @override
  void didUpdateWidget(covariant CalendarGanttView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version?.id != widget.version?.id) {
      _readyVersionId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureReady();
      });
    }
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
    _nowTimer?.cancel();
    _horizontal.removeListener(_onHorizontal);
    _horizontal.dispose();
    _vertical.dispose();
    _dragFocus.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- geometry

  CalendarSettings get _settings => widget.schedule.settings;

  WallClock get _wall => _settings.clock;

  DateTime get _rangeStart => _settings.startInstant;

  double get _pxPerHour => (_scale == CalendarScale.day ? 48.0 : 14.0) * _zoom;

  double get _pxPerMinute => _pxPerHour / 60.0;

  double get _timelineWidth {
    final minutes = _settings.endInstant.difference(_rangeStart).inMinutes;
    return math.max(320.0, minutes * _pxPerMinute);
  }

  double _xFor(DateTime instant) =>
      instant.difference(_rangeStart).inMinutes * _pxPerMinute;

  DateTime _instantFor(double x) =>
      _rangeStart.add(Duration(minutes: (x / _pxPerMinute).round()));

  DateTime _snap(DateTime instant, {bool up = false}) {
    final snap = math.max(1, _settings.snapMinutes);
    final offsetMs = _settings.timezoneOffsetMinutes * 60 * 1000;
    final wallMs = instant.millisecondsSinceEpoch + offsetMs;
    final unit = snap * 60 * 1000;
    final snapped = up
        ? ((wallMs + unit - 1) ~/ unit) * unit
        : (wallMs ~/ unit) * unit;
    return DateTime.fromMillisecondsSinceEpoch(snapped - offsetMs, isUtc: true);
  }

  void _onHorizontal() {
    if (!_horizontal.hasClients) return;
    if ((_horizontal.offset - _hOffset).abs() < 0.5) return;
    setState(() => _hOffset = _horizontal.offset);
  }

  void _scrollToToday({bool animate = true}) {
    if (!_horizontal.hasClients) return;
    final now = _now ?? DateTime.now();
    final target = (_xFor(now) - 120).clamp(
      0.0,
      _horizontal.position.maxScrollExtent,
    );
    if (animate) {
      _horizontal.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _horizontal.jumpTo(target);
    }
  }

  GlobalKey _labelKey(String id) => _labels.putIfAbsent(id, () => GlobalKey());

  /// Row height that fits both the lane stack and the two-line label at the current text
  /// scale (Windows text scaling goes up to 1.5x; a fixed height overflowed there).
  double _heightFor(_CalendarRow row) {
    if (row.isCaption) return 24;
    final factor = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
    final laneBox = row.lanes * (laneHeight + laneGap) + 6;
    final labelBox = 10 + 30 * factor;
    return math.max(laneBox, labelBox);
  }

  Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // ------------------------------------------------------------------ rows

  List<_CalendarRow> _buildRows() {
    final snap = widget.snapshot;
    final order = snap.order;
    final scheduled = <_CalendarRow>[];
    final unscheduled = <_CalendarRow>[];
    final done = <_CalendarRow>[];

    final tasks = <DisplayTask>[...snap.tasks]
      ..sort((a, b) {
        final ia = order.indexOf(a.id);
        final ib = order.indexOf(b.id);
        if (ia != ib) {
          if (ia < 0) return 1;
          if (ib < 0) return -1;
          return ia.compareTo(ib);
        }
        return a.name.compareTo(b.name);
      });

    for (final task in tasks) {
      final segments = widget.schedule.forTask(task.id);
      final estimateMinutes =
          ((task.estimateHours ?? 0) * 60).round();
      final row = _CalendarRow(
        task: task,
        segments: segments,
        estimatedMinutes: task.estimateKnown ? estimateMinutes : null,
        note: widget.actions.taskNotes[task.id],
        clock: _wall,
      );
      if (task.isDone) {
        done.add(row);
      } else if (segments.isEmpty) {
        unscheduled.add(row);
      } else {
        scheduled.add(row);
      }
    }
    return <_CalendarRow>[
      ...scheduled,
      if (unscheduled.isNotEmpty) ...[
        _CalendarRow.caption('未排期'),
        ...unscheduled,
      ],
      if (done.isNotEmpty) ...[
        _CalendarRow.caption('已完成（历史安排只读，不再占用未来时段）'),
        ...done,
      ],
    ];
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    if (snapshot.tasks.isEmpty) {
      return const Center(child: Text('还没有任务'));
    }
    final rows = _buildRows();
    final conflicts = _conflicts(rows);
    final conflictCount = conflicts.length;

    return Focus(
      focusNode: _dragFocus,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _drag != null) {
          _cancelDrag();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_settings.hasAvailability) _missingAvailabilityBanner(),
          if (_missingStartDate) _invalidStartBanner(),
          if (conflictCount > 0 || (widget.schedule.note?.trim().isNotEmpty ?? false))
            _banner(conflictCount),
          _toolbar(conflicts),
          if (_drag != null) _dragInfoBar(),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _axisHeader(),
                const Divider(height: 1, thickness: 1),
                Expanded(child: _body(rows, conflicts)),
              ],
            ),
          ),
          if (conflicts.isNotEmpty) _conflictStrip(conflicts),
        ],
      ),
    );
  }

  bool get _missingStartDate => !_settings.hasValidStart;

  Widget _missingAvailabilityBanner() {
    return _Banner(
      icon: Icons.event_busy_outlined,
      tone: TsColors.pending,
      text: '还没有设置可用时间。日历不会假设你每天 24 小时都能工作；'
          '请先设置每周可用时间、日期例外和课程/休息占用，再自动安排。',
      action: widget.actions.canEdit
          ? _BannerAction(label: '设置可用时间', onTap: _openSettings)
          : null,
    );
  }

  Widget _invalidStartBanner() {
    return _Banner(
      icon: Icons.error_outline,
      tone: TsColors.blocked,
      text: '排程起始日期「${_settings.planningStartDate}」无效，请改为 yyyy-MM-dd。',
      action: widget.actions.canEdit
          ? _BannerAction(label: '修正', onTap: _openSettings)
          : null,
    );
  }

  /// 只在有客观信息时出现：冲突数量与排程引擎给出的说明。
  Widget _banner(int conflicts) {
    final buffer = StringBuffer();
    if (conflicts > 0) {
      buffer.write('当前有 $conflicts 处冲突（允许保存，已在下方列出）。');
    }
    final note = widget.schedule.note;
    if (note != null && note.trim().isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(note.trim());
    }
    return _Banner(
      icon: Icons.event_available_outlined,
      text: buffer.toString(),
      tone: conflicts > 0 ? TsColors.pending : null,
    );
  }

  Widget _toolbar(List<CalendarConflict> conflicts) {
    final canEdit = widget.actions.canEdit;
    // One compact height for the whole group (segments + every tool button), so the row
    // is a single line of equally tall controls instead of mixed 26/28 px boxes.
    const toolbarHeight = 30.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // Wrap, not a fixed Row: on a wide window the 日/周 segments and every tool button
      // share one line; when the pane gets narrow the group wraps naturally instead of
      // overflowing. The segments no longer claim a full line — see the widthFactor fix
      // in BezierSegments.
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          BezierSegments(
            key: const Key('calendar-scale'),
            height: toolbarHeight,
            itemWidth: 56,
            items: const [
              BezierSegmentItem('日'),
              BezierSegmentItem('周'),
            ],
            selected: _scale.index,
            onChanged: (i) => setState(() {
              _scale = CalendarScale.values[i];
              _hOffset = _horizontal.hasClients ? _horizontal.offset : 0;
            }),
          ),
          _ToolButton(
            label: '今天',
            icon: Icons.today_outlined,
            height: toolbarHeight,
            onTap: () => _scrollToFocus(),
          ),
          _ToolButton(
            label: '缩小',
            icon: Icons.zoom_out,
            height: toolbarHeight,
            onTap: () => setState(() => _zoom = (_zoom / 1.25).clamp(0.5, 4)),
          ),
          _ToolButton(
            label: '放大',
            icon: Icons.zoom_in,
            height: toolbarHeight,
            onTap: () => setState(() => _zoom = (_zoom * 1.25).clamp(0.5, 4)),
          ),
          _ToolButton(
            label: '可用时间',
            icon: Icons.schedule_outlined,
            height: toolbarHeight,
            onTap: canEdit ? _openSettings : null,
          ),
          _ToolButton(
            label: '自动安排',
            icon: Icons.auto_awesome,
            height: toolbarHeight,
            onTap: canEdit ? () => _autoSchedule(keepManual: true) : null,
          ),
          _ToolButton(
            label: '重排全部',
            icon: Icons.restart_alt,
            height: toolbarHeight,
            onTap: canEdit ? () => _autoSchedule(keepManual: false) : null,
          ),
          if (!canEdit)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('历史版本只读',
                  style: TextStyle(fontSize: 11, color: TsColors.textFaint)),
            ),
        ],
      ),
    );
  }

  Widget _dragInfoBar() {
    final drag = _drag!;
    final start = _wall.toWall(drag.previewStart);
    final end = _wall.toWall(drag.previewEnd);
    final text = '${start.year}-${_two(start.month)}-${_two(start.day)} '
        '${_two(start.hour)}:${_two(start.minute)} → '
        '${_two(end.hour)}:${_two(end.minute)}'
        '${end.day != start.day ? '（次日）' : ''}'
        ' · ${formatDurationMinutes(drag.minutes)}';
    final hint = drag.invalid
        ? '时长必须大于 0：取消本次拖动（Esc）'
        : (drag.conflictHint ?? '松手保存，Esc 取消');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: bezierDecoration(
        color: drag.invalid ? TsColors.blockedSoft : TsColors.accentSoft,
        radius: 8,
      ),
      child: Row(
        children: [
          Icon(
            drag.invalid ? Icons.error_outline : Icons.open_with,
            size: 14,
            color: drag.invalid ? TsColors.blocked : TsColors.accent,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: drag.invalid ? TsColors.blocked : TsColors.textPrimary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    color: drag.invalid ? TsColors.blocked : TsColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _axisHeader() {
    final dayWidth = 24 * _pxPerHour;
    final hourStep = _scale == CalendarScale.day
        ? (_pxPerHour >= 52 ? 1 : 2)
        : 6;
    return SizedBox(
      height: headerHeight,
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Text(
                '任务 · 已安排/预计',
                maxLines: 2,
                style: TextStyle(
                    fontSize: 10.5, height: 1.3, color: TsColors.textFaint),
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: -_hOffset,
                    top: 0,
                    bottom: 0,
                    width: _timelineWidth,
                    child: Stack(
                      children: [
                        for (var d = 0;
                            d < _settings.planningDays.clamp(1, 400);
                            d++)
                          Positioned(
                            left: d * dayWidth + 5,
                            top: 4,
                            child: Text(
                              _dayLabel(_rangeStart.add(Duration(days: d))),
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: _isToday(_rangeStart.add(Duration(days: d)))
                                    ? TsColors.accent
                                    : TsColors.textSecondary,
                              ),
                            ),
                          ),
                        for (var h = 0;
                            h * _pxPerHour < _timelineWidth;
                            h += hourStep)
                          Positioned(
                            left: h * _pxPerHour + 4,
                            top: 26,
                            child: Text(
                              '${_two(h % 24)}:00',
                              style: TextStyle(
                                  fontSize: 9.5, color: TsColors.textFaint),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(List<_CalendarRow> rows, List<CalendarConflict> conflicts) {
    return Scrollbar(
      controller: _vertical,
      child: SingleChildScrollView(
        controller: _vertical,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: labelWidth,
              child: Column(
                children: [for (final row in rows) _labelCell(row)],
              ),
            ),
            Expanded(
              // Blank-timeline pan: only a gesture that starts on empty canvas reaches
              // this recognizer. A gesture that starts on a bar (or its resize edge)
              // is claimed by the bar's own horizontal recognizer, which is deeper in
              // the tree and wins the arena at pointer-down; ownership never switches
              // mid-drag. Wheel / touchpad / vertical scrolling are untouched.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => _blankPan = true,
                onHorizontalDragUpdate: (details) {
                  if (!_blankPan || !_horizontal.hasClients) return;
                  final c = _horizontal;
                  // Drag content right → offset decreases; clamp at both ends so the
                  // timeline does not jitter past its bounds.
                  c.jumpTo((c.offset - details.delta.dx)
                      .clamp(c.position.minScrollExtent, c.position.maxScrollExtent)
                      .toDouble());
                },
                onHorizontalDragEnd: (_) => _blankPan = false,
                onHorizontalDragCancel: () => _blankPan = false,
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  thickness: 9,
                  radius: const Radius.circular(4),
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _horizontal,
                    // Reserve the strip the horizontal bar paints over, so it never
                    // covers the last row of bars.
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SizedBox(
                      key: _contentKey,
                      width: _timelineWidth,
                      child: Column(
                        children: [
                          for (final row in rows)
                            _timelineCell(row, conflicts),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labelCell(_CalendarRow row) {
    if (row.isCaption) {
      return SizedBox(
        height: 24,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(row.caption!,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textFaint)),
          ),
        ),
      );
    }
    final task = row.task!;
    final palette = StatusPalette.of(task.status);
    final selected = widget.interaction.selectedTaskId == task.id;
    final allocated = row.scheduledMinutes;
    final estimate = row.estimatedMinutes;
    final balance = estimate == null ? null : estimate - allocated;
    final status = estimate == null
        ? '工时待确认'
        : balance! <= 0
            ? '已安排 ${formatDurationMinutes(allocated)}'
            : allocated == 0
                ? '未安排 · 需 ${formatDurationMinutes(estimate)}'
                : '已安排 ${formatDurationMinutes(allocated)}'
                    ' / 未安排 ${formatDurationMinutes(balance)}';
    final hasTentative = row.segments.any((s) => s.tentative);
    return SizedBox(
      key: _labelKey(task.id),
      height: _heightFor(row),
      child: MouseRegion(
        onEnter: (_) {
          if (_drag != null) return;
          widget.interaction.enterTask(task.id,
              anchor: _rectOf(_labelKey(task.id)), view: 'calendar');
        },
        onExit: (_) => widget.interaction.leaveTask(),
        child: GestureDetector(
          onTap: () => widget.interaction.selectAndReveal(
            task.id,
            anchor: _rectOf(_labelKey(task.id)),
            view: 'calendar',
          ),
          child: Container(
            color: selected ? TsColors.accentSoft : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          color: palette.foreground, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (hasTentative)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Tooltip(
                          message: '暂定安排：任务状态未改变',
                          child: Text('暂定',
                              style: TextStyle(
                                  fontSize: 9.5, color: TsColors.pending)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: balance != null && balance < 0
                        ? TsColors.blocked
                        : TsColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _timelineCell(_CalendarRow row, List<CalendarConflict> conflicts) {
    if (row.isCaption) return const SizedBox(height: 24);
    final task = row.task!;
    final canEdit = widget.actions.canEdit && !task.isDone;
    final dayWidth = 24 * _pxPerHour;
    final rowConflicts = conflicts
        .where((c) => c.taskId == task.id && c.segmentId != null)
        .toList(growable: false);

    return SizedBox(
      height: _heightFor(row),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Day / hour grid.
          Positioned.fill(
            child: CustomPaint(
              painter: _GridPainter(
                days: _settings.planningDays,
                dayWidth: dayWidth,
                pxPerHour: _pxPerHour,
                hourStep: _scale == CalendarScale.day ? 1 : 6,
                nowOffset: _nowOffsetFor(),
                border: TsColors.border,
                faint: TsColors.border.withValues(alpha: 0.45),
                now: TsColors.blocked,
              ),
            ),
          ),
          for (var lane = 0; lane < row.lanes; lane++)
            if (row.laneLabels[lane] != null)
              Positioned(
                left: 4,
                top: rowPadding + lane * (laneHeight + laneGap),
                child: Text(row.laneLabels[lane]!,
                    style:
                        TextStyle(fontSize: 9.5, color: TsColors.textFaint)),
              ),
          for (var i = 0; i < row.segments.length; i++)
            _segmentWidget(
              row,
              row.segments[i],
              row.laneOf[i],
              canEdit,
              rowConflicts,
            ),
        ],
      ),
    );
  }

  double? _nowOffsetFor() {
    final now = _now;
    if (now == null) return null;
    if (now.isBefore(_rangeStart) || now.isAfter(_settings.endInstant)) {
      return null;
    }
    return _xFor(now);
  }

  Widget _segmentWidget(
    _CalendarRow row,
    ScheduleSegment segment,
    int lane,
    bool canEdit,
    List<CalendarConflict> conflicts,
  ) {
    final dragging = _drag?.segmentId == segment.id;
    final start = dragging ? _drag!.previewStart : segment.start;
    final end = dragging ? _drag!.previewEnd : segment.end;
    final left = _xFor(start);
    final width = math.max(6.0, _xFor(end) - left);
    final top = rowPadding + lane * (laneHeight + laneGap);
    final segmentConflicts =
        conflicts.where((c) => c.segmentId == segment.id).toList(growable: false);
    final hasConflict = segmentConflicts.isNotEmpty;
    final flash = _flashSegmentId == segment.id &&
        _flashUntil != null &&
        DateTime.now().isBefore(_flashUntil!);
    final palette = StatusPalette.of(row.task!.status);
    final fill = segment.tentative
        ? TsColors.pendingSoft
        : (row.task!.isDone ? TsColors.doneSoft : palette.background);
    final borderColor = hasConflict
        ? TsColors.blocked
        : (segment.tentative
            ? TsColors.pending
            : palette.foreground.withValues(alpha: 0.45));

    // Progressive disclosure: a 30-minute bar cannot hold "08:00–08:30", so narrow bars
    // show only the start time and very narrow ones show nothing at all.
    final startWall = _wall.toWall(start);
    final endWall = _wall.toWall(end);
    final startLabel = '${_two(startWall.hour)}:${_two(startWall.minute)}';
    final endLabel = '${_two(endWall.hour)}:${_two(endWall.minute)}';
    final label = width >= 84
        ? '$startLabel–$endLabel'
        : width >= 34
            ? startLabel
            : '';

    return Positioned(
      key: Key('calendar-segment-${segment.id}'),
      left: left,
      top: top,
      height: laneHeight,
      width: width,
      child: MouseRegion(
        cursor: canEdit
            ? SystemMouseCursors.grab
            : SystemMouseCursors.basic,
        onEnter: (_) {
          if (_drag != null) return;
          widget.interaction.enterTask(row.task!.id,
              anchor: _segmentRect(segment), view: 'calendar');
        },
        onExit: (_) => widget.interaction.leaveTask(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // `down` (not `start`): the reported start position must be where the pointer
          // actually went down, otherwise the 18px touch slop shifts it and an edge grab
          // is misread as a body move (which also made the segment jump by the slop).
          dragStartBehavior: DragStartBehavior.down,
          // Horizontal only, and on purpose: time runs left-to-right, so a vertical
          // movement must not move the segment — and, crucially, a *horizontal* drag
          // recognizer accepts at the same 18px slop as the enclosing timeline scroll
          // view. As the inner-most recognizer it then wins the gesture arena, so
          // dragging a bar moves the bar instead of scrolling the canvas (a pan
          // recognizer needs 36px and would lose to the scroll view on real, many-step
          // pointer movement).
          onHorizontalDragStart: canEdit ? (d) => _onDragStart(d, segment) : null,
          onHorizontalDragUpdate: canEdit ? _onDragUpdate : null,
          onHorizontalDragEnd: canEdit ? (_) => _onDragEnd() : null,
          onHorizontalDragCancel: canEdit ? _cancelDrag : null,
          onTap: () {
            widget.interaction.selectAndReveal(
              row.task!.id,
              anchor: _segmentRect(segment),
              view: 'calendar',
            );
          },
          onSecondaryTapUp: canEdit
              ? (d) => _showSegmentMenu(segment, row, d.globalPosition)
              : null,
          child: Container(
            decoration: bezierDecoration(
              color: fill,
              radius: 5,
              border: Border.all(
                color: flash ? TsColors.accent : borderColor,
                width: hasConflict ? 1.6 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.centerLeft,
            // Narrow segments (a 30-minute bar is ~24px) must not overflow: the warning
            // and hand-tool glyphs only appear when there is room for them, and the
            // time label only when it can be read.
            child: Row(
              children: [
                if (hasConflict && width > 40)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.warning_amber_rounded,
                        size: 11, color: TsColors.blocked),
                  ),
                if (segment.source == SegmentSource.manual &&
                    !hasConflict &&
                    width > 40)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.pan_tool_alt_outlined,
                        size: 10,
                        color: palette.foreground.withValues(alpha: 0.7)),
                  ),
                if (label.isNotEmpty)
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 9.5,
                        color: palette.foreground,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Rect? _segmentRect(ScheduleSegment segment) {
    final content =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (content == null || !content.hasSize) return null;
    final left = _xFor(segment.start);
    return content.localToGlobal(Offset(left, 0)) & Size(
      math.max(6.0, _xFor(segment.end) - left),
      laneHeight,
    );
  }

  Widget _conflictStrip(List<CalendarConflict> conflicts) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: bezierDecoration(
        color: TsColors.background,
        radius: 8,
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14, color: TsColors.blocked),
              const SizedBox(width: 6),
              Text('冲突 ${conflicts.length} 处（允许保存，不会自动顺延其他任务）',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: TsColors.textPrimary)),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 64),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in conflicts)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _locateConflict(c),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Text(c.kind.label,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: c.kind.isBlocking
                                        ? TsColors.blocked
                                        : TsColors.pending)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                c.message,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: TsColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _locateConflict(CalendarConflict conflict) {
    final segmentId = conflict.segmentId;
    ScheduleSegment? segment;
    if (segmentId != null) segment = widget.schedule.segmentById(segmentId);
    if (segment == null) {
      final own = widget.schedule.forTask(conflict.taskId);
      if (own.isNotEmpty) segment = own.first;
    }
    final taskId = segment?.taskId ?? conflict.taskId;
    widget.interaction.selectAndReveal(
      taskId,
      anchor: _rectOf(_labelKey(taskId)),
      view: 'calendar',
    );
    if (segment != null && _horizontal.hasClients) {
      final target = (_xFor(segment.start) - 120).clamp(
        0.0,
        _horizontal.position.maxScrollExtent,
      );
      _horizontal.animateTo(target,
          duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
      setState(() {
        _flashSegmentId = segment!.id;
        _flashUntil = DateTime.now().add(const Duration(seconds: 2));
      });
      Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _flashSegmentId = null);
      });
    }
    final ctx = _labels[taskId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 240), alignment: 0.35);
    }
  }

  // ------------------------------------------------------------ conflicts

  List<CalendarConflict> _conflicts(List<_CalendarRow> rows) {
    final scheduling = <SchedulingTask>[
      for (final row in rows)
        if (!row.isCaption)
          SchedulingTask(
            id: row.task!.id,
            name: row.task!.name,
            estimatedHours: row.task!.estimateHours,
            dependsOn: widget.version?.plan.taskById(row.task!.id)?.dependsOn ??
                const <String>[],
            deadline:
                widget.version?.plan.taskById(row.task!.id)?.deadline,
            isDone: row.task!.isDone,
            isBlocked: row.task!.isBlocked,
            isPending: row.task!.isPending,
          ),
    ];
    return detectConflicts(
      schedule: widget.schedule,
      tasks: scheduling,
      now: _now ?? DateTime.now(),
      taskNames: {for (final r in rows) if (!r.isCaption) r.task!.id: r.task!.name},
    );
  }

  // --------------------------------------------------------------- actions

  Future<void> _openSettings() async {
    final applyTimetable = widget.actions.applyTimetable;
    final result = await showCalendarSettingsDialog(
      context,
      settings: _settings,
      now: _now ?? DateTime.now(),
      proposals: widget.proposalSource,
      timetable: widget.actions.timetable,
      weekStartsOn: widget.actions.weekStartsOn,
      initialMode: widget.actions.defaultEditor,
      defaultUnavailableRanges: widget.actions.defaultUnavailableRanges,
      taskNames: widget.actions.taskNames,
      onApply: applyTimetable == null
          ? null
          : (r) => applyTimetable(
                r.settings,
                r.timetable ??
                    Timetable.fromSchedule(widget.schedule,
                        weekStart: r.settings.planningStartDate),
                reschedule: true,
              ),
    );
    if (result == null) return;
    if (applyTimetable != null && result.timetable != null) {
      await applyTimetable(result.settings, result.timetable!,
          reschedule: true);
    } else {
      await widget.actions.applySettings(result.settings, reschedule: true);
    }
  }

  Future<void> _autoSchedule({required bool keepManual}) async {
    if (!keepManual) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重排全部安排？', style: TextStyle(fontSize: 15)),
          content: const Text(
            '会丢弃所有手动拖动过的片段，按当前可用时间从头安排。'
            '可以用“撤销”恢复。',
            style: TextStyle(fontSize: 12.5, height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('重排全部')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await widget.actions.autoSchedule(keepManual: keepManual);
  }

  // ---------------------------------------------------------------- drag

  void _onDragStart(DragStartDetails details, ScheduleSegment segment) {
    if (!widget.actions.canEdit) return;
    final content =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (content == null) return;
    final local = content.globalToLocal(details.globalPosition);
    final left = _xFor(segment.start);
    final right = _xFor(segment.end);
    final mode = (local.dx - left).abs() <= edgeGrab
        ? _DragMode.resizeStart
        : (right - local.dx).abs() <= edgeGrab
            ? _DragMode.resizeEnd
            : _DragMode.move;
    setState(() {
      _drag = _DragSession(
        segmentId: segment.id,
        taskId: segment.taskId,
        mode: mode,
        originalStart: segment.start,
        originalEnd: segment.end,
        pointerStartX: local.dx,
      );
    });
    _lastGlobal = details.globalPosition;
    _dragFocus.requestFocus();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final drag = _drag;
    if (drag == null) return;
    _lastGlobal = details.globalPosition;
    _applyDragDelta();
    _maybeAutoScroll();
  }

  void _applyDragDelta() {
    final drag = _drag;
    final content =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (drag == null || content == null || _lastGlobal == null) return;
    final local = content.globalToLocal(_lastGlobal!);
    final deltaMinutes = ((local.dx - drag.pointerStartX) / _pxPerMinute);
    // Snap the *moved edge* only: a body drag keeps the original duration exactly, so
    // rounding the two ends separately can never change the estimate.
    final original = switch (drag.mode) {
      _DragMode.move => drag.originalStart,
      _DragMode.resizeStart => drag.originalStart,
      _DragMode.resizeEnd => drag.originalEnd,
    };
    final target = original.add(Duration(minutes: deltaMinutes.round()));
    var snapped = _snap(target);
    switch (drag.mode) {
      case _DragMode.move:
        final duration = drag.originalEnd.difference(drag.originalStart);
        drag.previewStart = snapped;
        drag.previewEnd = snapped.add(duration);
        break;
      case _DragMode.resizeStart:
        if (_snap(drag.originalEnd).difference(snapped).inMinutes <= 0) {
          snapped = _snap(drag.originalEnd)
              .subtract(Duration(minutes: _settings.snapMinutes));
        }
        drag.previewStart = snapped;
        drag.previewEnd = drag.originalEnd;
        break;
      case _DragMode.resizeEnd:
        if (snapped.difference(_snap(drag.originalStart)).inMinutes <= 0) {
          snapped = _snap(drag.originalStart)
              .add(Duration(minutes: _settings.snapMinutes));
        }
        drag.previewStart = drag.originalStart;
        drag.previewEnd = snapped;
        break;
    }
    drag.invalid = !drag.previewEnd.isAfter(drag.previewStart);
    drag.conflictHint = _previewConflictHint(drag);
    setState(() {});
  }

  /// Live, cheap overlap preview for the dragged segment (full conflict detection runs
  /// again after the commit).
  String? _previewConflictHint(_DragSession drag) {
    final preview = TimeInterval(drag.previewStart, drag.previewEnd);
    final taskNames = {
      for (final t in widget.snapshot.tasks) t.id: t.name,
    };
    for (final other in widget.schedule.segments) {
      if (other.id == drag.segmentId) continue;
      final overlap = preview.intersect(other.interval);
      if (overlap == null) continue;
      final name = taskNames[other.taskId] ?? other.taskId;
      return other.taskId == drag.taskId
          ? '将与自己的另一段重叠 ${formatDurationMinutes(overlap.minutes)}（仍可保存）'
          : '将与「$name」重叠 ${formatDurationMinutes(overlap.minutes)}（仍可保存）';
    }
    final availability = buildAvailability(_settings);
    final uncovered = subtractIntervals([preview], availability.open);
    if (uncovered.isNotEmpty) {
      return '落入不可用时段 ${describeUnavailable(_settings, uncovered.first)}'
          '（仍可保存）';
    }
    return null;
  }

  void _maybeAutoScroll() {
    if (!_horizontal.hasClients || _lastGlobal == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(_lastGlobal!);
    final width = box.size.width;
    final nearRight = local.dx > width - 40;
    final nearLeft = local.dx < labelWidth + 20;
    if (!nearRight && !nearLeft) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    if (_autoScroll != null) return;
    _autoScroll = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted || _drag == null || !_horizontal.hasClients) {
        _autoScroll?.cancel();
        _autoScroll = null;
        return;
      }
      final step = nearRight ? 12.0 : -12.0;
      final next = (_horizontal.offset + step).clamp(
        0.0,
        _horizontal.position.maxScrollExtent,
      );
      if (next == _horizontal.offset) {
        _autoScroll?.cancel();
        _autoScroll = null;
        return;
      }
      _horizontal.jumpTo(next);
      if (_lastGlobal != null) {
        _lastGlobal = _lastGlobal! + Offset(step, 0);
      }
      _applyDragDelta();
    });
  }

  void _cancelDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    if (_drag == null) return;
    setState(() => _drag = null);
  }

  Future<void> _onDragEnd() async {
    _autoScroll?.cancel();
    _autoScroll = null;
    final drag = _drag;
    if (drag == null) return;
    if (drag.invalid) {
      setState(() => _drag = null);
      return;
    }
    final moved = !drag.previewStart.isAtSameMomentAs(drag.originalStart) ||
        !drag.previewEnd.isAtSameMomentAs(drag.originalEnd);
    if (!moved) {
      setState(() => _drag = null);
      return;
    }
    final tasks = widget.version?.tasks;
    if (tasks == null) {
      setState(() => _drag = null);
      return;
    }
    final outcome = drag.mode == _DragMode.move
        ? moveSegment(
            schedule: widget.schedule,
            tasks: tasks,
            segmentId: drag.segmentId,
            newStart: drag.previewStart,
          )
        : resizeSegment(
            schedule: widget.schedule,
            tasks: tasks,
            segmentId: drag.segmentId,
            newStart: drag.previewStart,
            newEnd: drag.previewEnd,
          );
    setState(() => _drag = null);
    await widget.actions.commit(outcome);
  }

  // ---------------------------------------------------------------- menus

  Future<void> _showSegmentMenu(
    ScheduleSegment segment,
    _CalendarRow row,
    Offset globalPosition,
  ) async {
    // Same menu style as the conversation menu and the settings menu: one shared
    // component, no per-call popup theme.
    final action = await showBezierMenu<String>(
      context: context,
      globalPosition: globalPosition,
      items: const [
        BezierMenuItem(
          value: 'edit',
          label: '精确编辑时间…',
          icon: Icons.edit_calendar_outlined,
        ),
        BezierMenuItem(
          value: 'split',
          label: '在此处拆分',
          icon: Icons.content_cut,
        ),
        BezierMenuItem(
          value: 'split-mid',
          label: '从中点拆分',
          icon: Icons.vertical_split,
        ),
        BezierMenuItem(
          value: 'cancel',
          label: '取消此段安排（不改工时）',
          icon: Icons.event_busy_outlined,
          danger: true,
          dividerBefore: true,
        ),
      ],
    );
    if (action == null || !mounted) return;
    final tasks = widget.version?.tasks;
    if (tasks == null) return;
    switch (action) {
      case 'cancel':
        await widget.actions.commit(cancelSegment(
          schedule: widget.schedule,
          tasks: tasks,
          segmentId: segment.id,
        ));
        break;
      case 'split-mid':
        final mid = segment.start
            .add(Duration(minutes: segment.minutes ~/ 2));
        await widget.actions.commit(splitSegment(
          schedule: widget.schedule,
          tasks: tasks,
          segmentId: segment.id,
          at: mid,
        ));
        break;
      case 'split':
        final content =
            _contentKey.currentContext?.findRenderObject() as RenderBox?;
        DateTime at = segment.start.add(Duration(minutes: segment.minutes ~/ 2));
        if (content != null) {
          final x = content.globalToLocal(globalPosition).dx;
          final candidate = _snap(_instantFor(x));
          if (candidate.isAfter(segment.start) &&
              candidate.isBefore(segment.end)) {
            at = candidate;
          }
        }
        await widget.actions.commit(splitSegment(
          schedule: widget.schedule,
          tasks: tasks,
          segmentId: segment.id,
          at: at,
        ));
        break;
      case 'edit':
        final result = await showSegmentEditDialog(
          context,
          segment: segment,
          settings: _settings,
          taskName: row.task!.name,
        );
        if (result == null) return;
        if (!mounted) return;
        if (result.cancel) {
          await widget.actions.commit(cancelSegment(
            schedule: widget.schedule,
            tasks: tasks,
            segmentId: segment.id,
          ));
        } else {
          await widget.actions.commit(resizeSegment(
            schedule: widget.schedule,
            tasks: tasks,
            segmentId: segment.id,
            newStart: result.start,
            newEnd: result.end,
          ));
        }
        break;
    }
  }

  // --------------------------------------------------------------- labels

  String _dayLabel(DateTime instant) {
    final w = _wall.toWall(instant);
    final today = _isToday(instant);
    return '${w.month}月${w.day}日 ${_weekday(w.weekday)}${today ? ' · 今天' : ''}';
  }

  bool _isToday(DateTime instant) {
    final now = _now ?? DateTime.now();
    return _wall.dateKey(instant) == _wall.dateKey(now);
  }

  static String _weekday(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };

  static String _two(int v) => v.toString().padLeft(2, '0');
}

// ------------------------------------------------------------------ helpers

class _CalendarRow {
  final String? caption;
  final DisplayTask? task;
  final List<ScheduleSegment> segments;
  final int? estimatedMinutes;
  final String? note;
  final WallClock clock;

  /// Lane index per segment, so two overlapping segments of the same task are drawn
  /// on separate lines instead of hiding each other.
  final List<int> laneOf;

  /// `11/20` marker shown at the left of each lane (the row label already names the
  /// task, so the lane needs its own date hint).
  final List<String?> laneLabels;

  _CalendarRow({
    required this.task,
    required this.segments,
    this.estimatedMinutes,
    this.note,
    this.clock = const WallClock(kDefaultTimezoneOffsetMinutes),
  })  : caption = null,
        laneOf = _assignLanes(segments),
        laneLabels = _laneLabels(segments, _assignLanes(segments), clock);

  _CalendarRow.caption(String this.caption)
      : task = null,
        segments = const [],
        estimatedMinutes = null,
        note = null,
        clock = const WallClock(kDefaultTimezoneOffsetMinutes),
        laneOf = const <int>[],
        laneLabels = const <String?>[];

  bool get isCaption => caption != null;

  int get scheduledMinutes =>
      segments.fold<int>(0, (sum, s) => sum + math.max(0, s.minutes));

  int get lanes {
    if (segments.isEmpty) return 1;
    return laneOf.fold<int>(0, (m, v) => math.max(m, v)) + 1;
  }

  static List<String?> _laneLabels(
    List<ScheduleSegment> segments,
    List<int> laneOf,
    WallClock clock,
  ) {
    if (segments.isEmpty) return const <String?>[null];
    final lanes =
        laneOf.fold<int>(0, (m, v) => math.max(m, v)) + 1;
    final labels = List<String?>.filled(lanes, null);
    for (var i = 0; i < segments.length; i++) {
      final wall = clock.toWall(segments[i].start);
      labels[laneOf[i]] ??= '${wall.month}/${wall.day}';
    }
    return labels;
  }

  static List<int> _assignLanes(List<ScheduleSegment> segments) {
    final laneEnds = <DateTime>[];
    final out = <int>[];
    for (final s in segments) {
      var lane = laneEnds.indexWhere((end) => !end.isAfter(s.start));
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(s.end);
      } else {
        laneEnds[lane] = s.end;
      }
      out.add(lane);
    }
    return out;
  }

  double get height =>
      16 + lanes * (_CalendarGanttViewState.laneHeight +
          _CalendarGanttViewState.laneGap);
}

class _GridPainter extends CustomPainter {
  final int days;
  final double dayWidth;
  final double pxPerHour;
  final int hourStep;
  final double? nowOffset;
  final Color border;
  final Color faint;
  final Color now;

  const _GridPainter({
    required this.days,
    required this.dayWidth,
    required this.pxPerHour,
    required this.hourStep,
    required this.border,
    required this.faint,
    required this.now,
    this.nowOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final thin = Paint()
      ..color = faint
      ..strokeWidth = 0.6;
    final strong = Paint()
      ..color = border
      ..strokeWidth = 1;
    final stepPx = pxPerHour * hourStep;
    if (stepPx >= 6) {
      for (var x = 0.0; x <= size.width; x += stepPx) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), thin);
      }
    }
    for (var d = 0; d <= days; d++) {
      final x = d * dayWidth;
      if (x > size.width) break;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), strong);
    }
    final marker = nowOffset;
    if (marker != null && marker >= 0 && marker <= size.width) {
      canvas.drawLine(
        Offset(marker, 0),
        Offset(marker, size.height),
        Paint()
          ..color = now
          ..strokeWidth = 1.4,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.days != days ||
      old.dayWidth != dayWidth ||
      old.pxPerHour != pxPerHour ||
      old.hourStep != hourStep ||
      old.nowOffset != nowOffset ||
      old.border != border;
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? tone;
  final Widget? action;

  const _Banner({
    required this.icon,
    required this.text,
    this.tone,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone ?? TsColors.textSecondary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: bezierDecoration(
        color: TsColors.background,
        radius: 8,
        border: Border.all(color: TsColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class _BannerAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _BannerAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: FilledButton(
        onPressed: onTap,
        style: TsButtons.filled(
          radius: 8,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          fontSize: 11.5,
        ),
        child: Text(label),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final double height;

  const _ToolButton({
    required this.label,
    required this.icon,
    this.onTap,
    this.height = 30,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: FilledButton.icon(
        onPressed: onTap,
        style: TsButtons.filled(
          radius: 8,
          minimumSize: Size(0, height),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          fontSize: 11.5,
        ),
        icon: Icon(icon, size: 13),
        label: Text(label),
      ),
    );
  }
}
