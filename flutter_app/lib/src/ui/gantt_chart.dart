// 相对工时甘特图：横轴为剩余工作的累计小时数（不是日历时间），顺序来自 C 内核。
// 工时未知的任务及其后续任务不给确定条形；已完成任务单独列出且不占剩余时间。
//
// 主要类型：GanttPanel（依赖图/甘特图与日历/相对工时切换）、GanttChartView。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/calendar.dart';
import '../model/display.dart';
import '../model/session.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'calendar_gantt.dart';
import 'calendar_settings_dialog.dart';
import 'theme.dart';

/// Hosts the two gantt sub-modes. The sub-mode choice is persisted per conversation
/// (`Conversation.ganttMode`); a conversation that never used the calendar keeps the
/// old relative-hour view.
class GanttPanel extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;
  final PlanVersion? version;
  final CalendarSchedule calendar;
  final CalendarActions actions;
  final String initialMode;
  final ValueChanged<String> onModeChanged;

  /// Where the calendar settings dialog gets its "从材料识别" candidates from.
  /// Null in read-only contexts (history versions, tests).
  final CalendarProposalSource? proposalSource;
  final DateTime? clock;

  const GanttPanel({
    super.key,
    required this.snapshot,
    required this.interaction,
    required this.version,
    required this.calendar,
    required this.actions,
    required this.initialMode,
    required this.onModeChanged,
    this.proposalSource,
    this.clock,
  });

  @override
  State<GanttPanel> createState() => _GanttPanelState();
}

class _GanttPanelState extends State<GanttPanel> {
  late String _mode = widget.initialMode == 'calendar' ? 'calendar' : 'relative';

  @override
  void didUpdateWidget(covariant GanttPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMode != widget.initialMode) {
      _mode = widget.initialMode == 'calendar' ? 'calendar' : 'relative';
    }
  }

  void _setMode(String mode) {
    if (mode == _mode) return;
    // The old mode's hover anchor belongs to the other view; drop it before switching.
    widget.interaction.switchView();
    setState(() => _mode = mode);
    widget.onModeChanged(mode);
  }

  @override
  Widget build(BuildContext context) {
    final calendar = _mode == 'calendar';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                calendar ? '日历视图' : '甘特视图',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textSecondary),
              ),
              const SizedBox(width: 8),
              BezierSegments(
                key: const Key('gantt-submode'),
                height: 26,
                itemWidth: 84,
                items: const [
                  BezierSegmentItem('日历排程',
                      icon: Icons.calendar_month_outlined),
                  BezierSegmentItem('相对工时',
                      icon: Icons.straighten_outlined),
                ],
                selected: calendar ? 0 : 1,
                onChanged: (i) => _setMode(i == 0 ? 'calendar' : 'relative'),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
        Expanded(
          child: calendar
              ? CalendarGanttView(
                  snapshot: widget.snapshot,
                  version: widget.version,
                  schedule: widget.calendar,
                  interaction: widget.interaction,
                  actions: widget.actions,
                  clock: widget.clock,
                  proposalSource: widget.proposalSource,
                )
              : GanttChartView(
                  snapshot: widget.snapshot,
                  interaction: widget.interaction,
                ),
        ),
      ],
    );
  }
}

/// One row of the chart: either a caption (section separator) or a task.
class _RowSpec {
  final String? caption;
  final DisplayTask? task;
  const _RowSpec.caption(this.caption) : task = null;
  const _RowSpec.task(this.task) : caption = null;
  bool get isCaption => caption != null;
}

class GanttChartView extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;

  const GanttChartView({
    super.key,
    required this.snapshot,
    required this.interaction,
  });

  @override
  State<GanttChartView> createState() => _GanttChartViewState();
}

class _GanttChartViewState extends State<GanttChartView> {
  static const double labelWidth = 214;
  static const double rowHeight = 40;
  static const double captionHeight = 26;
  static const double headerHeight = 34;

  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  final Map<String, GlobalKey> _barKeys = {};
  final List<Timer> _anchorTimers = [];
  double _hOffset = 0;
  double _pxPerHour = 48;

  @override
  void initState() {
    super.initState();
    widget.interaction.registerRevealer(_revealAndRefresh);
    _horizontal.addListener(_onHorizontal);
    _vertical.addListener(_refreshDetailAnchor);
  }

  @override
  void didUpdateWidget(covariant GanttChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interaction != widget.interaction) {
      oldWidget.interaction.unregisterRevealer(_revealAndRefresh);
      widget.interaction.registerRevealer(_revealAndRefresh);
    }
  }

  @override
  void dispose() {
    widget.interaction.unregisterRevealer(_revealAndRefresh);
    _horizontal.removeListener(_onHorizontal);
    _vertical.removeListener(_refreshDetailAnchor);
    for (final t in _anchorTimers) {
      t.cancel();
    }
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _onHorizontal() {
    if (!_horizontal.hasClients) return;
    if ((_horizontal.offset - _hOffset).abs() < 0.5) return;
    setState(() => _hOffset = _horizontal.offset);
    _refreshDetailAnchor();
  }

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, () => GlobalKey());

  GlobalKey _barKeyFor(String id) =>
      _barKeys.putIfAbsent(id, () => GlobalKey());

  Rect? _globalRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _refreshDetailAnchor() {
    final id = widget.interaction.detailTaskId;
    if (id == null) return;
    final rect = _globalRect(_barKeys[id] ?? _keyFor(id));
    if (rect != null) {
      widget.interaction.setAnchor(id, rect, view: 'gantt');
    }
  }

  void _revealAndRefresh(String id) {
    _reveal(id);
    _anchorTimers.add(Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      _refreshDetailAnchor();
    }));
  }

  /// Scrolls AND pans so the target row/bar is genuinely visible.
  void _reveal(String id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    }
    final task = widget.snapshot.byId(id);
    if (task == null || !_horizontal.hasClients) return;
    if (task.startHours == null) return;
    final target = task.startHours! * _pxPerHour - 60;
    _horizontal.animateTo(
      target.clamp(0.0, _horizontal.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  List<_RowSpec> _rows() {
    final snap = widget.snapshot;
    final scheduled = <DisplayTask>[];
    for (final id in snap.order) {
      final t = snap.byId(id);
      if (t != null && t.scheduleState == ScheduleState.scheduled) {
        scheduled.add(t);
      }
    }
    final completed = <DisplayTask>[];
    final unscheduled = <DisplayTask>[];
    for (final t in snap.tasks) {
      if (t.scheduleState == ScheduleState.completed) {
        completed.add(t);
      } else if (t.scheduleState != ScheduleState.scheduled) {
        unscheduled.add(t);
      }
    }
    return <_RowSpec>[
      for (final t in scheduled) _RowSpec.task(t),
      if (completed.isNotEmpty) ...[
        const _RowSpec.caption('已完成（不占用剩余时间）'),
        for (final t in completed) _RowSpec.task(t),
      ],
      if (unscheduled.isNotEmpty) ...[
        const _RowSpec.caption('未排期'),
        for (final t in unscheduled) _RowSpec.task(t),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.snapshot;
    if (snap.tasks.isEmpty) {
      return const Center(child: Text('还没有任务'));
    }
    final rows = _rows();
    final totalHours = math.max(1.0, snap.totalKnownHours.ceilToDouble());

    return LayoutBuilder(builder: (context, constraints) {
      final available = math.max(200.0, constraints.maxWidth - labelWidth);
      _pxPerHour = ((available - 40) / totalHours).clamp(16.0, 140.0);
      final timelineWidth = math.max(available, totalHours * _pxPerHour + 40);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(timelineWidth, totalHours),
          const Divider(height: 1),
          Expanded(
            child: Scrollbar(
              controller: _vertical,
              child: SingleChildScrollView(
                controller: _vertical,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Column(
                        children: [
                          for (var i = 0; i < rows.length; i++)
                            _labelCell(rows[i]),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        controller: _horizontal,
                        child: SizedBox(
                          width: timelineWidth,
                          child: Column(
                            children: [
                              for (var i = 0; i < rows.length; i++)
                                _barCell(rows[i], timelineWidth),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (snap.unresolvableReason != null)
            _Banner(
              icon: Icons.info_outline,
              text: snap.unresolvableReason!,
              tone: TsColors.pending,
            ),
        ],
      );
    });
  }

  // ------------------------------------------------------------- header

  Widget _header(double timelineWidth, double totalHours) {
    final step = totalHours > 40
        ? 8.0
        : totalHours > 16
            ? 4.0
            : totalHours > 8
                ? 2.0
                : 1.0;
    return SizedBox(
      height: headerHeight,
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('任务 · 相对累计工时',
                    maxLines: 2,
                    style: TextStyle(
                        fontSize: 10.5,
                        height: 1.25,
                        color: TsColors.textFaint)),
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
                    width: timelineWidth,
                    child: Stack(
                      children: [
                        for (var h = 0.0; h <= totalHours + 0.001; h += step)
                          Positioned(
                            left: h * _pxPerHour + 6,
                            top: 10,
                            child: Text(
                              h == 0 ? '0 小时' : '${_fmt(h)} 小时',
                              style: TextStyle(
                                  fontSize: 10.5, color: TsColors.textFaint),
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

  // --------------------------------------------------------------- cells

  Widget _labelCell(_RowSpec spec) {
    if (spec.isCaption) {
      return SizedBox(
        height: captionHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(spec.caption!,
                style: TextStyle(
                    fontSize: 11,
                    color: TsColors.textFaint,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }
    final task = spec.task!;
    final palette = StatusPalette.of(task.status);
    final selected = widget.interaction.selectedTaskId == task.id;
    return SizedBox(
      key: _keyFor(task.id),
      height: rowHeight,
      child: MouseRegion(
        onEnter: (e) => widget.interaction.enterTask(
          task.id,
          anchor: _globalRect(_keyFor(task.id)),
          view: 'gantt',
        ),
        onExit: (_) => widget.interaction.leaveTask(),
        child: GestureDetector(
          onTap: () => widget.interaction.selectAndReveal(
            task.id,
            anchor: _globalRect(_keyFor(task.id)),
            view: 'gantt',
          ),
          child: Container(
            color: selected ? TsColors.accentSoft : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: palette.foreground, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ),
                if (task.estimateKnown)
                  Text(task.estimateLabel,
                      style:
                          TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _barCell(_RowSpec spec, double timelineWidth) {
    if (spec.isCaption) return const SizedBox(height: captionHeight);
    final task = spec.task!;
    final palette = StatusPalette.of(task.status);
    final selected = widget.interaction.selectedTaskId == task.id;

    if (task.scheduleState == ScheduleState.scheduled &&
        task.startHours != null &&
        task.endHours != null) {
      final left = task.startHours! * _pxPerHour + 6;
      final width = math.max(6.0, (task.endHours! - task.startHours!) * _pxPerHour);
      return SizedBox(
        height: rowHeight,
        child: MouseRegion(
          onEnter: (e) => widget.interaction.enterTask(
            task.id,
            anchor: _globalRect(_barKeyFor(task.id)),
            view: 'gantt',
          ),
          onExit: (_) => widget.interaction.leaveTask(),
          child: GestureDetector(
            onTap: () => widget.interaction.selectAndReveal(
              task.id,
              anchor: _globalRect(_barKeyFor(task.id)),
              view: 'gantt',
            ),
            child: Stack(
              children: [
                for (var h = 0; h * _pxPerHour < timelineWidth; h++)
                  Positioned(
                    left: h * _pxPerHour + 6,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 0.6, color: TsColors.border),
                  ),
                Positioned(
                  left: left,
                  top: 9,
                  height: rowHeight - 18,
                  width: width,
                  child: KeyedSubtree(
                    key: ValueKey('gantt-bar-${task.id}'),
                    child: Container(
                      key: _barKeyFor(task.id),
                    decoration: bezierDecoration(
                      color: palette.background,
                      radius: 6,
                      border: Border.all(
                        color: selected
                            ? TsColors.accent
                            : palette.foreground.withValues(alpha: 0.35),
                        width: selected ? 1.6 : 1,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.centerLeft,
                    child: width > 76
                        ? Text(
                            '${_fmt(task.startHours!)}–${_fmt(task.endHours!)} h',
                            style: TextStyle(fontSize: 10.5, color: palette.foreground),
                          )
                        : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final note = task.scheduleState == ScheduleState.completed
        ? '已完成（不占剩余时间）'
        : '${task.scheduleNote ?? '未排期'}'
            '${task.estimateKnown ? '（已知时长 ${task.estimateLabel}）' : ''}';
    return SizedBox(
      height: rowHeight,
      child: MouseRegion(
        onEnter: (e) => widget.interaction.enterTask(
          task.id,
          anchor: _globalRect(_barKeyFor(task.id)),
          view: 'gantt',
        ),
        onExit: (_) => widget.interaction.leaveTask(),
        child: GestureDetector(
          onTap: () => widget.interaction.selectAndReveal(
            task.id,
            anchor: _globalRect(_barKeyFor(task.id)),
            view: 'gantt',
          ),
          child: Stack(
            children: [
              Positioned(
                left: 6,
                right: 12,
                top: rowHeight / 2 - 11,
                height: 22,
                child: Container(
                  key: _barKeyFor(task.id),
                  decoration: bezierDecoration(
                    radius: 6,
                    border: Border.all(
                      color: selected ? TsColors.accent : TsColors.border,
                      width: selected ? 1.6 : 1,
                    ),
                    color: task.scheduleState == ScheduleState.completed
                        ? TsColors.doneSoft
                        : Colors.transparent,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    note,
                    style:
                        TextStyle(fontSize: 10.5, color: TsColors.textFaint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;

  /// Status tone. Nullable on purpose: [TsColors] is a runtime palette now, so it can
  /// no longer be a `const` default value.
  final Color? tone;

  const _Banner({
    required this.icon,
    required this.text,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone ?? TsColors.textSecondary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 6),
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
        ],
      ),
    );
  }
}

