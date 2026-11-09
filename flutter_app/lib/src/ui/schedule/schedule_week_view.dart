// 日程周视图（任务 11）：左侧紧凑月历导航 + 右侧一周七列时间轴。
//
// 交互与规则：
//   * 按应用当地周一开头；左侧小点表示当天有日程；点日期定位到对应周与日期；
//   * 右侧上方是独立的“全天”行，下方定时事件按真实起止位置绘制；
//   * 跨日事件在每一天列里按真实边界裁剪，并显示“续”标记；
//   * 重叠事件各自占一条泳道，仍可分别选中；
//   * 点击空档回调 (日期, 分钟)，点击事件回调该实例；
//   * “显示任务时段”只读叠加当前甘特任务层，不写回日程、不参与占用。
//
// 本文件只做展示与手势回调；数据来自 ScheduleController 的展开结果与
// 组合根注入的任务层快照，不直接读写文件。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/calendar.dart' show parseDateKey;
import '../../model/schedule_event.dart'
    show ScheduleCategory, dateKeyToUtc;
import '../../state/ics/ics_timezones.dart' show IcsTimeZoneResolver;
import '../../state/schedule/schedule_expander.dart'
    show ScheduleOccurrence, dateKeyOfWall, wallOf;
import '../theme.dart';
import '../widgets/bezier_ui.dart';

/// 周视图里只读绘制的任务时段（由组合根从当前甘特排程构造，不持久化）。
class ScheduleTaskTime {
  const ScheduleTaskTime({
    required this.taskId,
    required this.title,
    required this.startUtc,
    required this.endUtc,
    this.tentative = false,
  });

  final String taskId;
  final String title;
  final DateTime startUtc;
  final DateTime endUtc;

  /// 待确认任务的暂定片段：用虚线/淡色区分，仍然只读。
  final bool tentative;
}

/// 一周七列时间轴 + 左侧月历导航。
class ScheduleWeekView extends StatelessWidget {
  const ScheduleWeekView({
    super.key,
    required this.weekStart,
    required this.timezoneId,
    required this.occurrences,
    required this.monthAnchor,
    required this.monthOccurrences,
    required this.selectedDate,
    required this.today,
    required this.taskTimes,
    required this.showTaskLayer,
    required this.onToggleTaskLayer,
    required this.onSelectDate,
    required this.onMonthChanged,
    required this.onSelectSlot,
    required this.onSelectOccurrence,
    required this.emptyMessage,
    this.showEmptyMessage = false,
  });

  /// 本周周一（本地日期，零时刻）。
  final DateTime weekStart;
  final String timezoneId;

  /// 已按筛选规则过滤、属于本周的实例。
  final List<ScheduleOccurrence> occurrences;

  /// 左侧月历当前月（当月 1 日）。
  final DateTime monthAnchor;

  /// 当月全部实例（不受筛选影响），用于小点导航。
  final List<ScheduleOccurrence> monthOccurrences;

  /// 当前选中日期（点击日期标题/小日历后高亮）。
  final DateTime selectedDate;
  final DateTime today;

  /// 任务层只读数据；[showTaskLayer] 为 false 时完全不参与绘制。
  final List<ScheduleTaskTime> taskTimes;
  final bool showTaskLayer;
  final ValueChanged<bool> onToggleTaskLayer;

  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<DateTime> onMonthChanged;

  /// 点击空档：日期 + 当地分钟（从 00:00 起）。
  final void Function(DateTime date, int startMinute) onSelectSlot;
  final ValueChanged<ScheduleOccurrence> onSelectOccurrence;

  /// 无结果时的文案：本周暂无日程 / 没有符合条件的日程 / 其他周对应措辞。
  final String emptyMessage;
  final bool showEmptyMessage;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 224,
          child: _MonthNav(
            monthAnchor: monthAnchor,
            selectedDate: selectedDate,
            today: today,
            occurrences: monthOccurrences,
            timezoneId: timezoneId,
            showTaskLayer: showTaskLayer,
            onToggleTaskLayer: onToggleTaskLayer,
            onSelectDate: onSelectDate,
            onMonthChanged: onMonthChanged,
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: TsColors.border),
        Expanded(
          child: _WeekTimeline(
            weekStart: weekStart,
            timezoneId: timezoneId,
            occurrences: occurrences,
            today: today,
            selectedDate: selectedDate,
            taskTimes: taskTimes,
            showTaskLayer: showTaskLayer,
            onSelectSlot: onSelectSlot,
            onSelectOccurrence: onSelectOccurrence,
            emptyMessage: emptyMessage,
            showEmptyMessage: showEmptyMessage,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 左侧紧凑月历
// ---------------------------------------------------------------------------

class _MonthNav extends StatelessWidget {
  const _MonthNav({
    required this.monthAnchor,
    required this.selectedDate,
    required this.today,
    required this.occurrences,
    required this.timezoneId,
    required this.showTaskLayer,
    required this.onToggleTaskLayer,
    required this.onSelectDate,
    required this.onMonthChanged,
  });

  final DateTime monthAnchor;
  final DateTime selectedDate;
  final DateTime today;
  final List<ScheduleOccurrence> occurrences;
  final String timezoneId;
  final bool showTaskLayer;
  final ValueChanged<bool> onToggleTaskLayer;
  final ValueChanged<DateTime> onSelectDate;
  final ValueChanged<DateTime> onMonthChanged;

  @override
  Widget build(BuildContext context) {
    final month = DateTime(monthAnchor.year, monthAnchor.month);
    final firstWeekday = month.weekday; // 1 = 周一
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = firstWeekday - 1;
    final cells = <DateTime?>[
      for (var i = 0; i < leading; i++) null,
      for (var day = 1; day <= daysInMonth; day++)
        DateTime(month.year, month.month, day),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    final dotDates = <String>{};
    for (final occurrence in occurrences) {
      final dates = _occurrenceDatesInMonth(occurrence, month);
      dotDates.addAll(dates);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
          child: Row(
            children: [
              IconButton(
                key: const Key('schedule-month-prev'),
                tooltip: '上个月',
                style: TsButtons.icon(size: TsSizes.compactIconSize),
                onPressed: () => onMonthChanged(
                  DateTime(month.year, month.month - 1),
                ),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Expanded(
                child: Text(
                  '${month.year}年${month.month}月',
                  key: const Key('schedule-month-label'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                key: const Key('schedule-month-next'),
                tooltip: '下个月',
                style: TsButtons.icon(size: TsSizes.compactIconSize),
                onPressed: () => onMonthChanged(
                  DateTime(month.year, month.month + 1),
                ),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: TsColors.textFaint,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: cells.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.0,
              ),
              itemBuilder: (context, index) {
                final date = cells[index];
                if (date == null) return const SizedBox.shrink();
                return _MonthDayCell(
                  date: date,
                  selected: _sameDay(date, selectedDate),
                  isToday: _sameDay(date, today),
                  hasEvents: dotDates.contains(_dateKey(date)),
                  onTap: () => onSelectDate(date),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 8, 10),
          child: InkWell(
            key: const Key('schedule-task-layer-toggle'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => onToggleTaskLayer(!showTaskLayer),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: showTaskLayer,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (value) => onToggleTaskLayer(value ?? false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '显示任务时段',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: TsColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 该实例在 [month] 里占用的日期集合（全天按日期区间，定时按显示时区日期）。
  Set<String> _occurrenceDatesInMonth(
    ScheduleOccurrence occurrence,
    DateTime month,
  ) {
    final out = <String>{};
    final monthStartKey = _dateKey(month);
    final nextMonth = DateTime(month.year, month.month + 1);
    final monthEndKey = _dateKey(nextMonth);
    if (occurrence.allDay) {
      final start = occurrence.startDate ?? '';
      final end = occurrence.endDateExclusive ?? '';
      if (start.isEmpty || end.isEmpty) return out;
      var date = start.compareTo(monthStartKey) < 0 ? monthStartKey : start;
      while (date.compareTo(end) < 0 && date.compareTo(monthEndKey) < 0) {
        out.add(date);
        final utc = dateKeyToUtc(date);
        if (utc == null) break;
        date = _dateKey(utc.add(const Duration(days: 1)));
      }
      return out;
    }
    final start = occurrence.startUtc == null
        ? null
        : wallOf(occurrence.startUtc!, timezoneId);
    final end = occurrence.endUtc == null
        ? null
        : wallOf(occurrence.endUtc!, timezoneId);
    if (start == null || end == null) return out;
    var cursor = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    var guard = 0;
    while (!cursor.isAfter(last) && guard < 40) {
      guard++;
      final key = _dateKey(cursor);
      if (key.compareTo(monthStartKey) >= 0 &&
          key.compareTo(monthEndKey) < 0) {
        out.add(key);
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return out;
  }
}

class _MonthDayCell extends StatefulWidget {
  const _MonthDayCell({
    required this.date,
    required this.selected,
    required this.isToday,
    required this.hasEvents,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final bool isToday;
  final bool hasEvents;
  final VoidCallback onTap;

  @override
  State<_MonthDayCell> createState() => _MonthDayCellState();
}

class _MonthDayCellState extends State<_MonthDayCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dateKey = _dateKey(widget.date);
    final selected = widget.selected;
    final background = selected
        ? TsColors.selected
        : (_hover ? TsColors.surfaceAlt : Colors.transparent);
    final foreground =
        selected ? TsColors.onButton : TsColors.textPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: Key('schedule-mini-day-$dateKey'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(7),
            border: widget.isToday && !selected
                ? Border.all(color: TsColors.accent, width: 1)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${widget.date.day}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight:
                      selected || widget.isToday ? FontWeight.w600 : FontWeight.w400,
                  color: foreground,
                ),
              ),
              const SizedBox(height: 1),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.hasEvents
                      ? (selected ? TsColors.onButton : TsColors.accent)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 右侧一周时间轴
// ---------------------------------------------------------------------------

class _WeekTimeline extends StatelessWidget {
  const _WeekTimeline({
    required this.weekStart,
    required this.timezoneId,
    required this.occurrences,
    required this.today,
    required this.selectedDate,
    required this.taskTimes,
    required this.showTaskLayer,
    required this.onSelectSlot,
    required this.onSelectOccurrence,
    required this.emptyMessage,
    required this.showEmptyMessage,
  });

  final DateTime weekStart;
  final String timezoneId;
  final List<ScheduleOccurrence> occurrences;
  final DateTime today;
  final DateTime selectedDate;
  final List<ScheduleTaskTime> taskTimes;
  final bool showTaskLayer;
  final void Function(DateTime date, int startMinute) onSelectSlot;
  final ValueChanged<ScheduleOccurrence> onSelectOccurrence;
  final String emptyMessage;
  final bool showEmptyMessage;

  static const double _hourHeight = 44;
  static const double _headerHeight = 44;
  static const double _gutterWidth = 54;

  @override
  Widget build(BuildContext context) {
    final resolver = IcsTimeZoneResolver();
    final days = List<DateTime>.generate(
      7,
      (index) => DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day + index,
      ),
    );
    final dayBounds = <_DayBounds>[
      for (final day in days) _dayBoundsFor(day, resolver),
    ];

    final timed = <(ScheduleOccurrence, int, int, int, bool, bool)>[];
    for (final occurrence in occurrences) {
      if (occurrence.allDay) continue;
      final startUtc = occurrence.startUtc;
      final endUtc = occurrence.endUtc;
      if (startUtc == null || endUtc == null) continue;
      for (var i = 0; i < days.length; i++) {
        final bounds = dayBounds[i];
        final dayStart = bounds.startUtc;
        final dayEnd = bounds.endUtc;
        if (dayStart == null || dayEnd == null) continue;
        if (!startUtc.isBefore(dayEnd) || !dayStart.isBefore(endUtc)) {
          continue;
        }
        final clipStart = startUtc.isAfter(dayStart) ? startUtc : dayStart;
        final clipEnd = endUtc.isBefore(dayEnd) ? endUtc : dayEnd;
        final startMinute = clipStart.difference(dayStart).inMinutes;
        final endMinute = clipEnd.difference(dayStart).inMinutes;
        if (endMinute <= startMinute) continue;
        timed.add((
          occurrence,
          i,
          startMinute,
          endMinute,
          startUtc.isBefore(dayStart),
          endUtc.isAfter(dayEnd),
        ));
      }
    }

    // 任务层：只读，按显示时区落到每一天列。
    final taskBlocks = <_TaskBlock>[];
    if (showTaskLayer) {
      for (final task in taskTimes) {
        final startUtc = task.startUtc.toUtc();
        final endUtc = task.endUtc.toUtc();
        if (!endUtc.isAfter(startUtc)) continue;
        for (var i = 0; i < days.length; i++) {
          final bounds = dayBounds[i];
          final dayStart = bounds.startUtc;
          final dayEnd = bounds.endUtc;
          if (dayStart == null || dayEnd == null) continue;
          if (!startUtc.isBefore(dayEnd) || !dayStart.isBefore(endUtc)) {
            continue;
          }
          final clipStart = startUtc.isAfter(dayStart) ? startUtc : dayStart;
          final clipEnd = endUtc.isBefore(dayEnd) ? endUtc : dayEnd;
          final startMinute = clipStart.difference(dayStart).inMinutes;
          final endMinute = clipEnd.difference(dayStart).inMinutes;
          if (endMinute <= startMinute) continue;
          taskBlocks.add(_TaskBlock(task, i, startMinute, endMinute));
        }
      }
    }

    // 可见时间窗：至少 08:00–18:00，有日程/任务时按真实边界扩展。
    var minMinute = 8 * 60;
    var maxMinute = 18 * 60;
    for (final item in timed) {
      minMinute = math.min(minMinute, item.$3);
      maxMinute = math.max(maxMinute, item.$4);
    }
    for (final block in taskBlocks) {
      minMinute = math.min(minMinute, block.startMinute);
      maxMinute = math.max(maxMinute, block.endMinute);
    }
    final startHour = (minMinute ~/ 60).clamp(0, 23);
    final endHour = ((maxMinute + 59) ~/ 60).clamp(startHour + 1, 24);
    final contentHeight = (endHour - startHour) * _hourHeight;

    final allDayRows = _layoutAllDay(days, occurrences);
    final allDayHeight = math.max(34.0, 24.0 + allDayRows.laneCount * 22.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _headerHeight,
          child: Row(
            children: [
              const SizedBox(width: _gutterWidth),
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _DayHeader(
                    day: days[i],
                    isToday: _sameDay(days[i], today),
                    isSelected: _sameDay(days[i], selectedDate),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        SizedBox(
          height: allDayHeight,
          child: Row(
            children: [
              SizedBox(
                width: _gutterWidth,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6, right: 6),
                    child: Text(
                      '全天',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: TsColors.textFaint,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columnWidth = constraints.maxWidth / 7;
                    return Stack(
                      children: [
                        for (final bar in allDayRows.bars)
                          Positioned(
                            left: bar.startIndex * columnWidth + 2,
                            top: 3 + bar.lane * 22,
                            width: math.max(
                              12,
                              (bar.endIndex - bar.startIndex) * columnWidth - 4,
                            ),
                            height: 20,
                            child: _AllDayBarView(
                              occurrence: bar.occurrence,
                              onTap: () => onSelectOccurrence(bar.occurrence),
                            ),
                          ),
                        if (allDayRows.laneCount == 0)
                          Positioned.fill(
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: TsColors.border,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: SizedBox(
                  height: contentHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _gutterWidth,
                        height: contentHeight,
                        child: Stack(
                          children: [
                            for (var hour = startHour; hour <= endHour; hour++)
                              Positioned(
                                right: 6,
                                top: (hour - startHour) * _hourHeight - 6,
                                child: Text(
                                  '${hour.toString().padLeft(2, '0')}:00',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: TsColors.textFaint,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, gridConstraints) {
                            final columnWidth = gridConstraints.maxWidth / 7;
                            return Stack(
                              children: [
                                // 小时横线。
                                for (var hour = startHour;
                                    hour <= endHour;
                                    hour++)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: (hour - startHour) * _hourHeight,
                                    child: Divider(
                                      height: 1,
                                      thickness: 1,
                                      color: TsColors.border,
                                    ),
                                  ),
                                // 每列背景（空档点击）与竖线。
                                for (var i = 0; i < 7; i++)
                                  Positioned(
                                    left: i * columnWidth,
                                    top: 0,
                                    width: columnWidth,
                                    height: contentHeight,
                                    child: GestureDetector(
                                      key: Key('schedule-day-column-$i'),
                                      behavior: HitTestBehavior.opaque,
                                      onTapUp: (details) {
                                        final minute = startHour * 60 +
                                            (details.localPosition.dy /
                                                    _hourHeight *
                                                    60)
                                                .floor();
                                        final snapped = (minute ~/ 30) * 30;
                                        onSelectSlot(
                                          days[i],
                                          snapped.clamp(0, 24 * 60 - 15),
                                        );
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            right: BorderSide(
                                              color: TsColors.border,
                                              width: 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                // 任务层（在日程下方，只读）。
                                for (final block in taskBlocks)
                                  Positioned(
                                    left: block.dayIndex * columnWidth + 2,
                                    top: _topFor(block.startMinute, startHour),
                                    width: math.max(
                                      4,
                                      columnWidth - 4,
                                    ),
                                    height: math.max(
                                      4,
                                      _heightFor(
                                        block.startMinute,
                                        block.endMinute,
                                      ),
                                    ),
                                    child: _TaskLayerBlock(block: block),
                                  ),
                                // 定时日程。
                                for (final layout in _layoutTimed(timed))
                                  Positioned(
                                    left: layout.dayIndex * columnWidth +
                                        2 +
                                        layout.lane *
                                            (columnWidth - 4) /
                                            layout.laneCount,
                                    top: _topFor(layout.startMinute, startHour),
                                    width: math.max(
                                      14,
                                      (columnWidth - 6) / layout.laneCount,
                                    ),
                                    height: math.max(
                                      18,
                                      _heightFor(
                                        layout.startMinute,
                                        layout.endMinute,
                                      ),
                                    ),
                                    child: _TimedEventBlock(
                                      occurrence: layout.occurrence,
                                      continuesBefore: layout.continuesBefore,
                                      continuesAfter: layout.continuesAfter,
                                      compact: _heightFor(
                                            layout.startMinute,
                                            layout.endMinute,
                                          ) <
                                          34,
                                      onTap: () =>
                                          onSelectOccurrence(layout.occurrence),
                                    ),
                                  ),
                                if (showEmptyMessage)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 10,
                                          ),
                                          decoration: bezierDecoration(
                                            color: TsColors.surface,
                                            radius: 10,
                                            border: Border.all(
                                              color: TsColors.border,
                                            ),
                                          ),
                                          child: Text(
                                            emptyMessage,
                                            key: const Key(
                                                'schedule-week-empty'),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: TsColors.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static double _topFor(int minute, int startHour) =>
      (minute - startHour * 60) / 60 * _hourHeight;

  static double _heightFor(int startMinute, int endMinute) =>
      math.max(4, (endMinute - startMinute) / 60 * _hourHeight);

  _DayBounds _dayBoundsFor(DateTime day, IcsTimeZoneResolver resolver) {
    final start = resolver.resolveWall(
      timezoneId,
      DateTime.utc(day.year, day.month, day.day),
    );
    final next = resolver.resolveWall(
      timezoneId,
      DateTime.utc(day.year, day.month, day.day + 1),
    );
    if (start.utc == null || next.utc == null) {
      return const _DayBounds(null, null);
    }
    return _DayBounds(start.utc, next.utc);
  }

  // ---------------------------------------------------------------- 全天布局

  _AllDayLayout _layoutAllDay(
    List<DateTime> days,
    List<ScheduleOccurrence> all,
  ) {
    final bars = <_AllDayBar>[];
    final weekStartKey = _dateKey(days.first);
    final weekEndKey = _dateKey(
      DateTime(days.last.year, days.last.month, days.last.day + 1),
    );
    for (final occurrence in all) {
      if (!occurrence.allDay) continue;
      final start = occurrence.startDate;
      final endExclusive = occurrence.endDateExclusive;
      if (start == null || endExclusive == null) continue;
      if (start.compareTo(weekEndKey) >= 0) continue;
      if (endExclusive.compareTo(weekStartKey) <= 0) continue;
      final visibleStart = start.compareTo(weekStartKey) < 0
          ? weekStartKey
          : start;
      final visibleEnd =
          endExclusive.compareTo(weekEndKey) > 0 ? weekEndKey : endExclusive;
      final startIndex = _indexOfKey(days, visibleStart);
      final endIndexExclusive = _indexOfKey(days, visibleEnd);
      final endIndex = endIndexExclusive <= startIndex
          ? math.min(startIndex + 1, 7)
          : math.min(endIndexExclusive, 7);
      if (startIndex < 0 || startIndex >= 7) continue;
      bars.add(_AllDayBar(
        occurrence: occurrence,
        startIndex: startIndex,
        endIndex: math.max(startIndex + 1, endIndex),
      ));
    }
    // 泳道：同一天列上重叠的全天日程各占一行。
    final laneEnds = <int, List<int>>{};
    var laneCount = 0;
    for (final bar in bars) {
      var lane = 0;
      while (true) {
        final ends = laneEnds[lane] ?? <int>[];
        if (!ends.any((end) => end > bar.startIndex)) {
          ends.add(bar.endIndex);
          laneEnds[lane] = ends;
          bar.lane = lane;
          break;
        }
        lane++;
      }
      laneCount = math.max(laneCount, lane + 1);
    }
    return _AllDayLayout(bars: bars, laneCount: laneCount);
  }

  /// 定时事件分区 + 泳道分配。
  List<_TimedLayout> _layoutTimed(
    List<(ScheduleOccurrence, int, int, int, bool, bool)> timed,
  ) {
    final out = <_TimedLayout>[];
    for (var day = 0; day < 7; day++) {
      final items = <_DayItem>[
        for (final item in timed)
          if (item.$2 == day)
            _DayItem(
              occurrence: item.$1,
              startMinute: item.$3,
              endMinute: item.$4,
              continuesBefore: item.$5,
              continuesAfter: item.$6,
            ),
      ];
      if (items.isEmpty) continue;
      items.sort((a, b) {
        final byStart = a.startMinute.compareTo(b.startMinute);
        if (byStart != 0) return byStart;
        final byEnd = b.endMinute.compareTo(a.endMinute);
        if (byEnd != 0) return byEnd;
        return a.occurrence.occurrenceKey
            .compareTo(b.occurrence.occurrenceKey);
      });
      // 简单相邻簇：与当前簇已占用区间相交就并入同一簇。
      var cluster = <_DayItem>[];
      var clusterEnd = -1;
      void flush() {
        if (cluster.isEmpty) return;
        final laneEnds = <int>[];
        for (final item in cluster) {
          var lane = 0;
          while (lane < laneEnds.length && laneEnds[lane] > item.startMinute) {
            lane++;
          }
          if (lane == laneEnds.length) {
            laneEnds.add(item.endMinute);
          } else {
            laneEnds[lane] = item.endMinute;
          }
          out.add(_TimedLayout(
            occurrence: item.occurrence,
            dayIndex: day,
            startMinute: item.startMinute,
            endMinute: item.endMinute,
            continuesBefore: item.continuesBefore,
            continuesAfter: item.continuesAfter,
            lane: lane,
            laneCount: 0,
          ));
        }
        final laneCount = laneEnds.length;
        for (var i = out.length - cluster.length; i < out.length; i++) {
          out[i] = out[i].withLaneCount(laneCount);
        }
        cluster = <_DayItem>[];
        clusterEnd = -1;
      }

      for (final item in items) {
        if (cluster.isNotEmpty && item.startMinute >= clusterEnd) {
          flush();
        }
        cluster.add(item);
        clusterEnd = math.max(clusterEnd, item.endMinute);
      }
      flush();
    }
    return out;
  }

  static int _indexOfKey(List<DateTime> days, String dateKey) {
    for (var i = 0; i < days.length; i++) {
      if (_dateKey(days[i]) == dateKey) return i;
    }
    // 跨周边界：按日期差计算（不依赖列表里有这一天）。
    final parsed = parseDateKey(dateKey);
    if (parsed == null || days.isEmpty) return -1;
    final date = dateKeyToUtc(parsed);
    final base = dateKeyToUtc(_dateKey(days.first));
    if (date == null || base == null) return -1;
    return date.difference(base).inDays;
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.isToday,
    required this.isSelected,
  });

  final DateTime day;
  final bool isToday;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return Container(
      decoration: isSelected
          ? BoxDecoration(
              color: TsColors.accentSoft,
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            weekdays[day.weekday - 1],
            style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
          ),
          const SizedBox(height: 1),
          Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isToday ? TsColors.accent : TsColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AllDayBarView extends StatelessWidget {
  const _AllDayBarView({required this.occurrence, required this.onTap});

  final ScheduleOccurrence occurrence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(occurrence.category);
    return GestureDetector(
      key: Key('schedule-allday-${occurrence.occurrenceKey}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          occurrence.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: color),
        ),
      ),
    );
  }
}

class _TimedEventBlock extends StatelessWidget {
  const _TimedEventBlock({
    required this.occurrence,
    required this.continuesBefore,
    required this.continuesAfter,
    required this.compact,
    required this.onTap,
  });

  final ScheduleOccurrence occurrence;
  final bool continuesBefore;
  final bool continuesAfter;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(occurrence.category);
    return GestureDetector(
      key: Key('schedule-event-${occurrence.occurrenceKey}'),
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 5, vertical: compact ? 1 : 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(5),
          ),
          child: compact
              ? Text(
                  occurrence.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9.5,
                    height: 1.2,
                    color: Colors.white,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${continuesBefore ? '← ' : ''}${occurrence.title}'
                      '${continuesAfter ? ' →' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _timeRangeLabel(occurrence),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.5,
                        height: 1.2,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TaskLayerBlock extends StatelessWidget {
  const _TaskLayerBlock({required this.block});

  final _TaskBlock block;

  @override
  Widget build(BuildContext context) {
    final task = block.task;
    return IgnorePointer(
      child: Container(
        key: Key('schedule-task-layer-${task.taskId}-${block.dayIndex}'),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: task.tentative
              ? TsColors.waitingSoft.withValues(alpha: 0.7)
              : TsColors.doneSoft,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: (task.tentative ? TsColors.waiting : TsColors.done)
                .withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          task.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9.5,
            height: 1.2,
            color: task.tentative ? TsColors.waiting : TsColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 布局数据
// ---------------------------------------------------------------------------

class _DayBounds {
  const _DayBounds(this.startUtc, this.endUtc);
  final DateTime? startUtc;
  final DateTime? endUtc;
  bool get valid => startUtc != null && endUtc != null;
}

class _AllDayBar {
  _AllDayBar({
    required this.occurrence,
    required this.startIndex,
    required this.endIndex,
  });

  final ScheduleOccurrence occurrence;
  final int startIndex;
  final int endIndex;
  int lane = 0;
}

class _AllDayLayout {
  const _AllDayLayout({required this.bars, required this.laneCount});
  final List<_AllDayBar> bars;
  final int laneCount;
}

class _DayItem {
  const _DayItem({
    required this.occurrence,
    required this.startMinute,
    required this.endMinute,
    required this.continuesBefore,
    required this.continuesAfter,
  });

  final ScheduleOccurrence occurrence;
  final int startMinute;
  final int endMinute;
  final bool continuesBefore;
  final bool continuesAfter;
}

class _TimedLayout {
  const _TimedLayout({
    required this.occurrence,
    required this.dayIndex,
    required this.startMinute,
    required this.endMinute,
    required this.continuesBefore,
    required this.continuesAfter,
    required this.lane,
    required this.laneCount,
  });

  final ScheduleOccurrence occurrence;
  final int dayIndex;
  final int startMinute;
  final int endMinute;
  final bool continuesBefore;
  final bool continuesAfter;
  final int lane;
  final int laneCount;

  _TimedLayout withLaneCount(int value) => _TimedLayout(
        occurrence: occurrence,
        dayIndex: dayIndex,
        startMinute: startMinute,
        endMinute: endMinute,
        continuesBefore: continuesBefore,
        continuesAfter: continuesAfter,
        lane: lane,
        laneCount: math.max(1, value),
      );
}

class _TaskBlock {
  const _TaskBlock(this.task, this.dayIndex, this.startMinute, this.endMinute);
  final ScheduleTaskTime task;
  final int dayIndex;
  final int startMinute;
  final int endMinute;
}

// ---------------------------------------------------------------------------
// 共用小工具
// ---------------------------------------------------------------------------

Color _categoryColor(String? wireName) {
  switch (wireName) {
    case 'work':
      return TsColors.buttonFill;
    case 'study':
      return TsColors.waiting;
    case 'life':
      return TsColors.ready;
    default:
      return TsColors.done;
  }
}

String _timeRangeLabel(ScheduleOccurrence occurrence) {
  final start = occurrence.startUtc == null
      ? null
      : wallOf(occurrence.startUtc!, occurrence.timezoneId);
  final end = occurrence.endUtc == null
      ? null
      : wallOf(occurrence.endUtc!, occurrence.timezoneId);
  if (start == null || end == null) return '';
  String hm(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
  return '${hm(start)}-${hm(end)}';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 供列表弹窗复用：把展开实例按显示时区的日期键分组。
Map<String, List<ScheduleOccurrence>> groupOccurrencesByDisplayDate(
  List<ScheduleOccurrence> occurrences,
  String timezoneId,
) {
  final out = <String, List<ScheduleOccurrence>>{};
  for (final occurrence in occurrences) {
    if (occurrence.allDay) {
      final start = occurrence.startDate;
      final end = occurrence.endDateExclusive;
      if (start == null || end == null) continue;
      var date = start;
      var guard = 0;
      while (date.compareTo(end) < 0 && guard < 64) {
        guard++;
        out.putIfAbsent(date, () => <ScheduleOccurrence>[]).add(occurrence);
        final utc = dateKeyToUtc(date);
        if (utc == null) break;
        date = dateKeyOfWall(utc.add(const Duration(days: 1)));
      }
      continue;
    }
    final start = occurrence.startUtc == null
        ? null
        : wallOf(occurrence.startUtc!, timezoneId);
    final end = occurrence.endUtc == null
        ? null
        : wallOf(occurrence.endUtc!, timezoneId);
    if (start == null || end == null) continue;
    var cursor = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    var guard = 0;
    while (!cursor.isAfter(last) && guard < 40) {
      guard++;
      out
          .putIfAbsent(_dateKey(cursor), () => <ScheduleOccurrence>[])
          .add(occurrence);
      cursor = cursor.add(const Duration(days: 1));
    }
  }
  return out;
}

/// 分类标签颜色（详情/周视图共用）。
(Color, Color) scheduleCategoryColors(ScheduleCategory? category) {
  switch (category) {
    case ScheduleCategory.work:
      return (TsColors.waiting, TsColors.waitingSoft);
    case ScheduleCategory.study:
      return (TsColors.accent, TsColors.accentSoft);
    case ScheduleCategory.life:
      return (TsColors.ready, TsColors.readySoft);
    case null:
      return (TsColors.textSecondary, TsColors.doneSoft);
  }
}
