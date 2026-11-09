// 全局日程弹窗（0.5.0 任务 09 + 11）：左侧紧凑月历 + 右侧一周七列时间轴。
//
// 功能范围：
//   * 保留右上关闭 ×（唯一关闭入口），去掉底部重复关闭/跳转教程/忙碌解释；
//   * 日期标题可点击并复用共享年月日历（任务 03），替代“跳转输入 + 跳转按钮 +
//     单独选日期”三个控件；分类、关联筛选使用统一菜单；有筛选条件且无结果显示
//     “没有符合条件的日程”，本周确无显示“本周暂无日程”，浏览其他周用对应措辞；
//   * 搜索/分类/关联/仅当前会话只影响展示，忙碌与排程避让仍来自全部有效占用
//     （本弹窗不参与忙碌合成，也不另写一份日程存储）；
//   * 点击空档预填日期时间；点击事件出详情；详情里可编辑/删除并停留在原周；
//   * “显示任务时段”只读叠加当前甘特任务层，关闭只隐藏，不写入日程；
//   * 重复日程的编辑/删除沿用既有“仅本次/整个系列”语义与受 revision 保护撤销。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/schedule_event.dart';
import '../../state/ics/ics_timezones.dart' show IcsTimeZoneResolver;
import '../../state/schedule/schedule_controller.dart';
import '../../state/schedule/schedule_expander.dart';
import '../theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/bezier_menu.dart';
import '../widgets/bezier_ui.dart';
import '../widgets/date_range_picker.dart'
    show formatDatePickerDate, showCalendarPopup;
import 'schedule_detail_dialog.dart';
import 'schedule_editor_dialog.dart';
import 'schedule_week_view.dart';

export 'schedule_editor_dialog.dart'
    show ScheduleConversationOption, ScheduleEditScope, ScheduleEditorOutcome,
        ScheduleEditorDialog, ScheduleTaskOption, showScheduleEditorDialog;

/// 打开全局日程弹窗。
Future<void> showScheduleListDialog(
  BuildContext context, {
  required ScheduleController controller,
  required String timezoneId,
  int weekStartsOn = 1,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
  Future<void> Function(String conversationId)? onOpenConversation,
  String? currentConversationId,
  DateTime Function()? clock,
  List<ScheduleTaskTime> taskTimes = const <ScheduleTaskTime>[],
  Future<List<ScheduleTaskOption>> Function(String conversationId)?
      loadConversationTasks,
  Future<void> Function(String conversationId, ScheduleTaskOption task)?
      onOpenTask,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ScheduleListDialog(
      controller: controller,
      timezoneId: timezoneId,
      weekStartsOn: weekStartsOn,
      conversations: conversations,
      onOpenConversation: onOpenConversation,
      currentConversationId: currentConversationId,
      clock: clock,
      taskTimes: taskTimes,
      loadConversationTasks: loadConversationTasks,
      onOpenTask: onOpenTask,
    ),
  );
}

class ScheduleListDialog extends StatefulWidget {
  const ScheduleListDialog({
    super.key,
    required this.controller,
    required this.timezoneId,
    this.weekStartsOn = 1,
    this.conversations = const <ScheduleConversationOption>[],
    this.onOpenConversation,
    this.currentConversationId,
    this.clock,
    this.taskTimes = const <ScheduleTaskTime>[],
    this.loadConversationTasks,
    this.onOpenTask,
  });

  final ScheduleController controller;
  final String timezoneId;
  final int weekStartsOn;
  final List<ScheduleConversationOption> conversations;
  final Future<void> Function(String conversationId)? onOpenConversation;
  final String? currentConversationId;
  final DateTime Function()? clock;
  final List<ScheduleTaskTime> taskTimes;
  final Future<List<ScheduleTaskOption>> Function(String conversationId)?
      loadConversationTasks;
  final Future<void> Function(String conversationId, ScheduleTaskOption task)?
      onOpenTask;

  @override
  State<ScheduleListDialog> createState() => _ScheduleListDialogState();
}

class _ScheduleListDialogState extends State<ScheduleListDialog> {
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  final IcsTimeZoneResolver _resolver = IcsTimeZoneResolver();
  final TextEditingController _search = TextEditingController();

  /// 当前选中日期（定位周与高亮）。
  late DateTime _anchor;

  /// 左侧月历当前月（当月 1 日）。
  late DateTime _visibleMonth;

  String _categoryFilter = 'all';
  String _linkFilter = 'all';
  bool _onlyCurrent = false;
  bool _showTaskLayer = false;

  DateTime get _nowWall =>
      wallOf(_clock().toUtc(), widget.timezoneId) ?? _clock();

  @override
  void initState() {
    super.initState();
    final wall = _nowWall;
    _anchor = DateTime(wall.year, wall.month, wall.day);
    _visibleMonth = DateTime(wall.year, wall.month);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- 范围查询

  DateTime _weekStartOf(DateTime date) {
    final offset = (date.weekday - widget.weekStartsOn + 7) % 7;
    return DateTime(date.year, date.month, date.day - offset);
  }

  DateTime get _weekStart => _weekStartOf(_anchor);

  DateTime? _utcOfWall(DateTime wallDate) {
    final result = _resolver.resolveWall(
      widget.timezoneId,
      DateTime.utc(wallDate.year, wallDate.month, wallDate.day),
    );
    return result.utc ??
        DateTime.utc(wallDate.year, wallDate.month, wallDate.day);
  }

  ScheduleExpansionResult _expansionFor(DateTime fromWall, DateTime toWallExclusive) {
    final from = _utcOfWall(fromWall);
    final to = _utcOfWall(toWallExclusive);
    if (from == null || to == null) return ScheduleExpansionResult.empty;
    return widget.controller.occurrencesInRange(
      fromUtc: from,
      // 排他边界减 1 秒：最后一个全天日程不会被算进下一段。
      toUtc: to.subtract(const Duration(seconds: 1)),
      timezoneId: widget.timezoneId,
    );
  }

  /// 本周全部实例（未过滤，用于空态判断与统计）。
  List<ScheduleOccurrence> get _weekAll {
    final start = _weekStart;
    return _expansionFor(start, start.add(const Duration(days: 7))).occurrences;
  }

  List<ScheduleOccurrence> _visible(
    List<ScheduleOccurrence> all,
  ) {
    final query = _search.text.trim().toLowerCase();
    final current = widget.currentConversationId;
    final filtered = <ScheduleOccurrence>[];
    for (final occurrence in all) {
      if (_categoryFilter != 'all' &&
          (occurrence.category ?? '') != _categoryFilter) {
        continue;
      }
      final linked = occurrence.linkedConversationId;
      if (_linkFilter == 'none') {
        if (linked != null) continue;
      } else if (_linkFilter != 'all') {
        if (linked != _linkFilter) continue;
      }
      if (_onlyCurrent && current != null && linked != current) continue;
      if (query.isNotEmpty) {
        final event = widget.controller.eventById(occurrence.eventId);
        final haystack = [
          occurrence.title,
          event?.location ?? '',
          event?.notes ?? '',
        ].join('\n').toLowerCase();
        if (!haystack.contains(query)) continue;
      }
      filtered.add(occurrence);
    }
    return filtered;
  }

  bool get _hasActiveFilters =>
      _search.text.trim().isNotEmpty ||
      _categoryFilter != 'all' ||
      _linkFilter != 'all' ||
      _onlyCurrent;

  /// 左侧月历小点用的当月实例（不受筛选影响，帮助导航）。
  List<ScheduleOccurrence> get _monthAll {
    final month = DateTime(_visibleMonth.year, _visibleMonth.month);
    return _expansionFor(
      month,
      DateTime(month.year, month.month + 1),
    ).occurrences;
  }

  // ------------------------------------------------------------------ 操作

  Future<void> _add({DateTime? date, int? startMinute}) async {
    final outcome = await showScheduleEditorDialog(
      context,
      controller: widget.controller,
      timezoneId: widget.timezoneId,
      conversations: widget.conversations,
      clock: widget.clock,
      loadConversationTasks: widget.loadConversationTasks,
      initialDate: date,
      initialStartMinute: startMinute,
    );
    if (outcome == null || !mounted) return;
    _afterSaved(outcome);
  }

  void _afterSaved(ScheduleEditorOutcome outcome) {
    final anchor = outcome.anchorDate;
    if (anchor != null) {
      final date = dateKeyToUtc(anchor);
      if (date != null && mounted) {
        setState(() {
          _anchor = DateTime(date.year, date.month, date.day);
          _visibleMonth = DateTime(date.year, date.month);
        });
      }
    }
    _showNotice(AppNoticeKind.success, outcome.result.message);
  }

  Future<void> _edit(ScheduleOccurrence occurrence) async {
    final event = widget.controller.eventById(occurrence.eventId);
    if (event == null) {
      _showNotice(AppNoticeKind.error, '日程已不存在，请关闭后重新打开日程');
      return;
    }
    var scope = ScheduleEditScope.series;
    if (event.repeat.repeats) {
      final chosen = await _askScope(occurrence: occurrence, deleting: false);
      if (chosen == null || !mounted) return;
      scope = chosen;
    }
    final outcome = await showScheduleEditorDialog(
      context,
      controller: widget.controller,
      timezoneId: widget.timezoneId,
      event: event,
      occurrence: scope == ScheduleEditScope.occurrence ? occurrence : null,
      conversations: widget.conversations,
      clock: widget.clock,
      loadConversationTasks: widget.loadConversationTasks,
    );
    if (outcome == null || !mounted) return;
    _afterSaved(outcome);
  }

  Future<void> _delete(ScheduleOccurrence occurrence) async {
    final event = widget.controller.eventById(occurrence.eventId);
    if (event == null) {
      _showNotice(AppNoticeKind.error, '日程已不存在，请关闭后重新打开日程');
      return;
    }
    ScheduleMutationResult result;
    if (event.repeat.repeats) {
      final scope = await _askScope(occurrence: occurrence, deleting: true);
      if (scope == null || !mounted) return;
      if (scope == ScheduleEditScope.occurrence) {
        result = await widget.controller.setOccurrenceExcluded(
          event.id,
          occurrence.occurrenceKey,
          excluded: true,
        );
      } else {
        result = await widget.controller.deleteEvent(event.id, event.revision);
      }
    } else {
      result = await widget.controller.deleteEvent(event.id, event.revision);
    }
    if (!mounted) return;
    if (result.ok) {
      _showUndoNotice(result);
    } else {
      _showNotice(AppNoticeKind.error, result.message);
    }
  }

  Future<void> _openDetail(ScheduleOccurrence occurrence) async {
    final event = widget.controller.eventById(occurrence.eventId);
    if (event == null) {
      _showNotice(AppNoticeKind.error, '日程已不存在，请关闭后重新打开日程');
      return;
    }
    await showScheduleDetailDialog(
      context,
      occurrence: occurrence,
      event: event,
      displayTimezoneId: widget.timezoneId,
      conversations: widget.conversations,
      resolveLinkedTask: _linkedTaskResolver(event),
      onEdit: () => _edit(occurrence),
      onDelete: () => _delete(occurrence),
      onOpenConversation: widget.onOpenConversation == null
          ? null
          : (id) async {
              await widget.onOpenConversation!(id);
              if (mounted) Navigator.of(context).pop();
            },
      onOpenTask: widget.onOpenTask == null || event.linkedConversationId == null
          ? null
          : (task) async {
              await widget.onOpenTask!(event.linkedConversationId!, task);
            },
    );
  }

  Future<ScheduleTaskOption?> Function()? _linkedTaskResolver(
    ScheduleEvent event,
  ) {
    final loader = widget.loadConversationTasks;
    final conversationId = event.linkedConversationId;
    final taskId = event.linkedTaskId;
    if (loader == null || conversationId == null || taskId == null) {
      return null;
    }
    return () async {
      try {
        final tasks = await loader(conversationId);
        for (final task in tasks) {
          if (task.id == taskId) return task;
        }
      } catch (_) {
        // 会话读取失败不打断详情：按“不可用”展示，绝不同名误跳。
      }
      return null;
    };
  }

  Future<ScheduleEditScope?> _askScope({
    required ScheduleOccurrence occurrence,
    required bool deleting,
  }) {
    final event = widget.controller.eventById(occurrence.eventId);
    final title = event?.title ?? occurrence.title;
    final date = occurrence.originalDate;
    return showDialog<ScheduleEditScope>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('schedule-scope-dialog'),
        title: Text(
          deleting ? '删除重复日程' : '编辑重复日程',
          style: const TextStyle(fontSize: 15),
        ),
        content: Text(
          deleting
              ? '「$title」是重复日程。要删除 $date 这一次，还是删除整个系列？'
              : '「$title」是重复日程。要修改 $date 这一次，还是修改整个系列？',
          style: const TextStyle(fontSize: 12.5, height: 1.55),
        ),
        actions: [
          TextButton(
            key: const Key('schedule-scope-cancel'),
            style: TsButtons.inline(),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('schedule-scope-occurrence'),
            style: TsButtons.inline(),
            onPressed: () =>
                Navigator.of(context).pop(ScheduleEditScope.occurrence),
            child: Text(deleting ? '仅删除本次' : '仅修改本次'),
          ),
          FilledButton(
            key: const Key('schedule-scope-series'),
            style: deleting ? TsButtons.solid(fill: TsColors.blocked) : null,
            onPressed: () =>
                Navigator.of(context).pop(ScheduleEditScope.series),
            child: Text(deleting ? '删除整个系列' : '修改整个系列'),
          ),
        ],
      ),
    );
  }

  void _showNotice(
    AppNoticeKind kind,
    String message, {
    List<String> details = const <String>[],
  }) {
    AppNotices.instance.show(
      kind: kind,
      message: message,
      details: details,
      autoDismiss: kind == AppNoticeKind.error || kind == AppNoticeKind.warning
          ? null
          : const Duration(seconds: 4),
      dedupeKey: 'schedule-list',
    );
  }

  /// 删除后的撤销：撤销动作由控制器用 revision 保护，新编辑后旧撤销不会覆盖新状态。
  void _showUndoNotice(ScheduleMutationResult result) {
    AppNotices.instance.show(
      kind: AppNoticeKind.success,
      message: result.message,
      actionLabel: '撤销',
      actionValidFor: const Duration(seconds: 8),
      autoDismiss: const Duration(seconds: 8),
      dedupeKey: 'schedule-mutation',
      onAction: () async {
        final undo = await widget.controller.undoLastMutation();
        if (!mounted) return;
        if (undo.ok) {
          AppNotices.instance.show(
            kind: AppNoticeKind.success,
            message: undo.message,
            autoDismiss: const Duration(seconds: 4),
            dedupeKey: 'schedule-mutation',
          );
          setState(() {});
        } else {
          AppNotices.instance.show(
            kind: AppNoticeKind.error,
            message: undo.message,
            autoDismiss: null,
            dedupeKey: 'schedule-mutation',
          );
        }
      },
    );
  }

  // ---------------------------------------------------------------- 导航

  void _selectDate(DateTime date) {
    setState(() {
      _anchor = DateTime(date.year, date.month, date.day);
      _visibleMonth = DateTime(date.year, date.month);
    });
  }

  void _shiftWeek(int days) {
    setState(() {
      _anchor = _anchor.add(Duration(days: days));
      _visibleMonth = DateTime(_anchor.year, _anchor.month);
    });
  }

  Future<void> _pickAnchorDate(BuildContext anchorContext) async {
    final picked = await showCalendarPopup(
      context,
      anchorContext: anchorContext,
      initialDate: DateTime.utc(_anchor.year, _anchor.month, _anchor.day),
      firstDate: DateTime.utc(2000, 1, 1),
      lastDate: DateTime.utc(2100, 12, 31),
      today: _nowWall,
    );
    if (picked == null || !mounted) return;
    _selectDate(picked);
  }

  Future<void> _selectCategory(String value) async {
    setState(() => _categoryFilter = value);
  }

  Future<void> _selectLink(String value) async {
    setState(() => _linkFilter = value);
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = math.min(1080.0, math.max(360.0, media.width - 28));
    final height = math.min(780.0, math.max(360.0, media.height - 36));
    return Dialog(
      key: const Key('schedule-list-dialog'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      shape: const BezierRoundedRectangleBorder(radius: 16),
      child: SizedBox(
        width: width,
        height: height,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => _content(),
        ),
      ),
    );
  }

  Widget _content() {
    final weekAll = _weekAll;
    final visible = _visible(weekAll);
    final monthAll = _monthAll;
    final isCurrentWeek = _isSameWeek(_weekStart, _weekStartOf(_nowWall));
    final emptyMessage = _emptyMessage(isCurrentWeek);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        _toolbar(isCurrentWeek),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        Expanded(
          child: ScheduleWeekView(
            weekStart: _weekStart,
            timezoneId: widget.timezoneId,
            occurrences: visible,
            monthAnchor: _visibleMonth,
            monthOccurrences: monthAll,
            selectedDate: _anchor,
            today: _nowWall,
            taskTimes: widget.taskTimes,
            showTaskLayer: _showTaskLayer,
            onToggleTaskLayer: (value) =>
                setState(() => _showTaskLayer = value),
            onSelectDate: _selectDate,
            onMonthChanged: (month) => setState(() {
              _visibleMonth = DateTime(month.year, month.month);
            }),
            onSelectSlot: (date, startMinute) => _add(
              date: date,
              startMinute: startMinute,
            ),
            onSelectOccurrence: _openDetail,
            emptyMessage: emptyMessage,
            showEmptyMessage: visible.isEmpty,
          ),
        ),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        _footer(visible.length, isCurrentWeek),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: Row(
        children: [
          Icon(Icons.event_note_outlined, size: 17, color: TsColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '日程',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary,
              ),
            ),
          ),
          FilledButton.icon(
            key: const Key('schedule-add'),
            style: TsButtons.solid(),
            onPressed: () => _add(),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('添加日程'),
          ),
          const SizedBox(width: 4),
          TsCloseButton(
            key: const Key('schedule-list-close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(bool isCurrentWeek) {
    final weekStart = _weekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            key: const Key('schedule-prev-week'),
            tooltip: '上一周',
            style: TsButtons.icon(size: TsSizes.compactIconSize),
            onPressed: () => _shiftWeek(-7),
            icon: const Icon(Icons.chevron_left, size: 18),
          ),
          _DateTitle(
            label: _weekRangeLabel(weekStart, weekEnd),
            onTap: _pickAnchorDate,
          ),
          IconButton(
            key: const Key('schedule-next-week'),
            tooltip: '下一周',
            style: TsButtons.icon(size: TsSizes.compactIconSize),
            onPressed: () => _shiftWeek(7),
            icon: const Icon(Icons.chevron_right, size: 18),
          ),
          OutlinedButton(
            key: const Key('schedule-this-week'),
            style: TsButtons.outline(height: TsSizes.compactButtonHeight),
            onPressed: () {
              final wall = _nowWall;
              _selectDate(wall);
            },
            child: const Text('本周'),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 168,
            child: TextField(
              key: const Key('schedule-search'),
              controller: _search,
              style: const TextStyle(fontSize: 12),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索',
                prefixIcon: Icon(Icons.search, size: 15),
                isDense: true,
              ),
            ),
          ),
          BezierMenuSelect<String>(
            key: const Key('schedule-category-filter'),
            label: _categoryLabel,
            width: 132,
            dense: true,
            menuWidth: 168,
            items: <BezierMenuItem<String>>[
              for (final option in const <(String, String)>[
                ('all', '全部分类'),
                ('work', '工作'),
                ('study', '学习'),
                ('life', '生活'),
              ])
                BezierMenuItem(
                  value: option.$1,
                  label: option.$2,
                  selected: _categoryFilter == option.$1,
                ),
            ],
            onSelected: _selectCategory,
          ),
          BezierMenuSelect<String>(
            key: const Key('schedule-linked-filter'),
            label: _linkLabel,
            width: 176,
            dense: true,
            menuWidth: 240,
            items: <BezierMenuItem<String>>[
              BezierMenuItem(
                value: 'all',
                label: '全部关联',
                selected: _linkFilter == 'all',
              ),
              BezierMenuItem(
                value: 'none',
                label: '未关联',
                selected: _linkFilter == 'none',
              ),
              for (final option in widget.conversations)
                BezierMenuItem(
                  value: option.id,
                  label: option.title,
                  selected: _linkFilter == option.id,
                ),
            ],
            onSelected: _selectLink,
          ),
          if (widget.currentConversationId != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: const Key('schedule-only-current'),
                  value: _onlyCurrent,
                  visualDensity: VisualDensity.compact,
                  onChanged: (value) =>
                      setState(() => _onlyCurrent = value ?? false),
                ),
                const Text('仅当前会话', style: TextStyle(fontSize: 12)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _footer(int visibleCount, bool isCurrentWeek) {
    final rangeWord = isCurrentWeek ? '本周' : '这一周';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$rangeWord $visibleCount 条 · '
              '全局共 ${widget.controller.events.length} 个日程',
              key: const Key('schedule-footer-stats'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: TsColors.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _emptyMessage(bool isCurrentWeek) {
    if (_hasActiveFilters) return '没有符合条件的日程';
    return isCurrentWeek ? '本周暂无日程' : '这一周暂无日程';
  }

  String get _categoryLabel {
    switch (_categoryFilter) {
      case 'work':
        return '工作';
      case 'study':
        return '学习';
      case 'life':
        return '生活';
      default:
        return '全部分类';
    }
  }

  String get _linkLabel {
    if (_linkFilter == 'none') return '未关联';
    if (_linkFilter == 'all') return '全部关联';
    for (final option in widget.conversations) {
      if (option.id == _linkFilter) return option.title;
    }
    return '全部关联';
  }

  bool _isSameWeek(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _weekRangeLabel(DateTime start, DateTime end) {
    final sameYear = start.year == end.year;
    final sameMonth = sameYear && start.month == end.month;
    final startLabel = '${start.month}月${start.day}日';
    final endLabel =
        sameMonth ? '${end.day}日' : '${end.month}月${end.day}日';
    if (sameYear && start.year == _nowWall.year) {
      return '$startLabel-$endLabel';
    }
    if (sameYear) return '${start.year}年$startLabel-$endLabel';
    return '${start.year}年$startLabel-${end.year}年$endLabel';
  }
}

/// 可点击的日期标题：替代“跳转输入 + 跳转按钮 + 单独选日期”。
class _DateTitle extends StatelessWidget {
  const _DateTitle({required this.label, required this.onTap});

  final String label;
  final Future<void> Function(BuildContext anchorContext) onTap;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (titleContext) => InkWell(
        key: const Key('schedule-week-label'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => onTap(titleContext),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 14, color: TsColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// 供测试/外部复用：把本地日期格式化成日期键。
String scheduleDateKey(DateTime date) => formatDatePickerDate(date);
