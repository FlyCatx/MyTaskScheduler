// 全局日程管理弹窗（0.4.0 任务 4）。
//
// 范围（01 框架 §4、02 提示词任务 4）：
//   * 默认显示当前周，可上一周/下一周/本周/输入日期跳转/日期选择器看远期日程；
//   * 标题搜索、分类筛选、关联筛选只影响展示，绝不改变忙碌合成；
//   * 列表项同时就是详情：时间/忙闲/重复/提醒/关联都可读，可编辑/删除/跳转会话；
//   * 重复日程的编辑/删除先问“仅本次/整个系列”；单次删除写 exclusion，
//     整个系列删除走 deleteEvent（expectedRevision 由控制器校验）；
//   * 删除后用现有通知宿主提供受 revision 保护的撤销；
//   * 只通过 ScheduleController 读写；会话列表与跳转由 AppShell 注入，不依赖 AppController。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/calendar.dart' show parseDateKey;
import '../../model/schedule_event.dart';
import '../../state/ics/ics_timezones.dart' show IcsTimeZoneResolver;
import '../../state/schedule/schedule_controller.dart';
import '../../state/schedule/schedule_expander.dart';
import '../theme.dart';
import '../widgets/app_notice.dart';
import '../widgets/bezier_ui.dart';
import 'schedule_editor_dialog.dart';

export 'schedule_editor_dialog.dart'
    show ScheduleConversationOption, ScheduleEditScope, ScheduleEditorOutcome,
        ScheduleEditorDialog, showScheduleEditorDialog;

/// 打开全局日程管理弹窗。
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
  });

  final ScheduleController controller;
  final String timezoneId;
  final int weekStartsOn;
  final List<ScheduleConversationOption> conversations;
  final Future<void> Function(String conversationId)? onOpenConversation;
  final String? currentConversationId;
  final DateTime Function()? clock;

  @override
  State<ScheduleListDialog> createState() => _ScheduleListDialogState();
}

class _ScheduleListDialogState extends State<ScheduleListDialog> {
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  final IcsTimeZoneResolver _resolver = IcsTimeZoneResolver();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _jump = TextEditingController();

  late DateTime _anchor;
  String _categoryFilter = 'all';
  String _linkFilter = 'all';
  bool _onlyCurrent = false;
  String? _jumpError;

  DateTime get _nowWall =>
      wallOf(_clock().toUtc(), widget.timezoneId) ?? _clock();

  @override
  void initState() {
    super.initState();
    final wall = _nowWall;
    _anchor = DateTime(wall.year, wall.month, wall.day);
  }

  @override
  void dispose() {
    _search.dispose();
    _jump.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- 查询范围

  DateTime _weekStartOf(DateTime date) {
    final offset = (date.weekday - widget.weekStartsOn + 7) % 7;
    return DateTime(date.year, date.month, date.day - offset);
  }

  DateTime? _utcOfWall(DateTime wallDate) {
    final result = _resolver.resolveWall(
      widget.timezoneId,
      DateTime.utc(wallDate.year, wallDate.month, wallDate.day),
    );
    return result.utc ??
        DateTime.utc(wallDate.year, wallDate.month, wallDate.day);
  }

  ScheduleExpansionResult _expansionFor(DateTime weekStart) {
    final from = _utcOfWall(weekStart) ??
        DateTime.utc(weekStart.year, weekStart.month, weekStart.day);
    final endWall = weekStart.add(const Duration(days: 7));
    final end = _utcOfWall(endWall) ??
        DateTime.utc(endWall.year, endWall.month, endWall.day);
    return widget.controller.occurrencesInRange(
      fromUtc: from,
      // 排他边界减 1 秒：当周最后一个全天日程不会被算进下一周。
      toUtc: end.subtract(const Duration(seconds: 1)),
      timezoneId: widget.timezoneId,
    );
  }

  List<ScheduleOccurrence> _visibleOccurrences(List<ScheduleOccurrence> all) {
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

  // ------------------------------------------------------------------ 操作

  Future<void> _add() async {
    final outcome = await showScheduleEditorDialog(
      context,
      controller: widget.controller,
      timezoneId: widget.timezoneId,
      conversations: widget.conversations,
      clock: widget.clock,
    );
    if (outcome == null || !mounted) return;
    _afterSaved(outcome);
  }

  void _afterSaved(ScheduleEditorOutcome outcome) {
    final anchor = outcome.anchorDate;
    if (anchor != null) {
      final date = dateKeyToUtc(anchor);
      if (date != null) {
        setState(() => _anchor = DateTime(date.year, date.month, date.day));
      }
    }
    _showNotice(AppNoticeKind.success, outcome.result.message);
  }

  Future<void> _edit(ScheduleOccurrence occurrence) async {
    final event = widget.controller.eventById(occurrence.eventId);
    if (event == null) {
      _showNotice(AppNoticeKind.error, '日程已不存在，请关闭后重新打开列表');
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
    );
    if (outcome == null || !mounted) return;
    _afterSaved(outcome);
  }

  Future<void> _delete(ScheduleOccurrence occurrence) async {
    final event = widget.controller.eventById(occurrence.eventId);
    if (event == null) {
      _showNotice(AppNoticeKind.error, '日程已不存在，请关闭后重新打开列表');
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

  Future<void> _openLinkedConversation(ScheduleOccurrence occurrence) async {
    final opener = widget.onOpenConversation;
    final id = occurrence.linkedConversationId;
    if (opener == null || id == null) return;
    await opener(id);
    if (!mounted) return;
    Navigator.of(context).pop();
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
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('schedule-scope-occurrence'),
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

  void _shiftWeek(int days) {
    setState(() {
      _anchor = _anchor.add(Duration(days: days));
      _jumpError = null;
    });
  }

  void _jumpToDate(String text) {
    final parsed = parseDateKey(text.trim());
    if (parsed == null) {
      setState(() => _jumpError = '日期格式应为 YYYY-MM-DD');
      return;
    }
    final date = dateKeyToUtc(parsed);
    if (date == null) {
      setState(() => _jumpError = '日期不合法');
      return;
    }
    setState(() {
      _anchor = DateTime(date.year, date.month, date.day);
      _jumpError = null;
    });
  }

  Future<void> _pickAnchorDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '跳转到日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _anchor = DateTime(picked.year, picked.month, picked.day);
      _jumpError = null;
    });
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = math.min(780.0, math.max(320.0, media.width - 24));
    final height = math.min(720.0, math.max(320.0, media.height - 36));
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
    final weekStart = _weekStartOf(_anchor);
    final expansion = _expansionFor(weekStart);
    final visible = _visibleOccurrences(expansion.occurrences);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        _toolbar(weekStart),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        Expanded(child: _listArea(expansion, visible)),
        Divider(height: 1, thickness: 1, color: TsColors.border),
        _footer(visible.length),
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
            onPressed: _add,
            icon: const Icon(Icons.add, size: 15),
            label: const Text('添加日程'),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('schedule-list-close'),
            tooltip: '关闭',
            style: TsButtons.closeIcon(size: 28),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(DateTime weekStart) {
    final weekEnd = weekStart.add(const Duration(days: 6));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: const Key('schedule-prev-week'),
                tooltip: '上一周',
                visualDensity: VisualDensity.compact,
                onPressed: () => _shiftWeek(-7),
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Text(
                _weekRangeLabel(weekStart, weekEnd),
                key: const Key('schedule-week-label'),
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              IconButton(
                key: const Key('schedule-next-week'),
                tooltip: '下一周',
                visualDensity: VisualDensity.compact,
                onPressed: () => _shiftWeek(7),
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
              TextButton(
                key: const Key('schedule-this-week'),
                style: TsButtons.inline(),
                onPressed: () {
                  final wall = _nowWall;
                  setState(() {
                    _anchor = DateTime(wall.year, wall.month, wall.day);
                    _jumpError = null;
                  });
                },
                child: const Text('本周'),
              ),
              SizedBox(
                width: 150,
                child: TextField(
                  key: const Key('schedule-jump'),
                  controller: _jump,
                  style: const TextStyle(fontSize: 12),
                  onSubmitted: _jumpToDate,
                  decoration: const InputDecoration(
                    labelText: '跳转日期',
                    hintText: 'YYYY-MM-DD',
                    isDense: true,
                  ),
                ),
              ),
              TextButton(
                key: const Key('schedule-jump-go'),
                style: TsButtons.inline(),
                onPressed: () => _jumpToDate(_jump.text),
                child: const Text('跳转'),
              ),
              TextButton.icon(
                key: const Key('schedule-jump-pick'),
                style: TsButtons.inline(),
                onPressed: _pickAnchorDate,
                icon: const Icon(Icons.event, size: 15),
                label: const Text('选择日期'),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  key: const Key('schedule-search'),
                  controller: _search,
                  style: const TextStyle(fontSize: 12),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '搜索',
                    hintText: '标题/地点/备注',
                    isDense: true,
                  ),
                ),
              ),
              DropdownButton<String>(
                key: const Key('schedule-category-filter'),
                value: _categoryFilter,
                isDense: true,
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem(value: 'all', child: Text('全部分类')),
                  for (final category in ScheduleCategory.values)
                    DropdownMenuItem(
                      value: category.wireName,
                      child: Text(category.label),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _categoryFilter = value ?? 'all'),
              ),
              DropdownButton<String>(
                key: const Key('schedule-linked-filter'),
                value: _linkFilter,
                isDense: true,
                style: TextStyle(fontSize: 12, color: TsColors.textPrimary),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem(value: 'all', child: Text('全部关联')),
                  const DropdownMenuItem(value: 'none', child: Text('未关联')),
                  for (final option in widget.conversations)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(
                        option.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _linkFilter = value ?? 'all'),
              ),
              if (widget.currentConversationId != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const Key('schedule-only-current'),
                      value: _onlyCurrent,
                      onChanged: (value) =>
                          setState(() => _onlyCurrent = value ?? false),
                    ),
                    const Text('仅当前会话', style: TextStyle(fontSize: 12)),
                  ],
                ),
            ],
          ),
          if (_jumpError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _jumpError!,
                key: const Key('schedule-jump-error'),
                style: TextStyle(fontSize: 11.5, color: TsColors.blocked),
              ),
            ),
        ],
      ),
    );
  }

  Widget _listArea(
    ScheduleExpansionResult expansion,
    List<ScheduleOccurrence> visible,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!expansion.complete)
          Container(
            key: const Key('schedule-warnings'),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(10),
            decoration: bezierDecoration(
              color: TsColors.pendingSoft,
              radius: 8,
              border:
                  Border.all(color: TsColors.pending.withValues(alpha: 0.4)),
            ),
            child: Text(
              '日程展开不完整：${expansion.warnings.join('；')}',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: TsColors.pending,
              ),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? _emptyState()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: visible.length,
                  itemBuilder: (context, index) => _row(visible[index]),
                ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_available_outlined,
                size: 34, color: TsColors.border),
            const SizedBox(height: 10),
            Text(
              '这个范围没有日程',
              style: TextStyle(fontSize: 12.5, color: TsColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              '默认显示当前周；可用「跳转日期」查看远期日程。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: TsColors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(int visibleCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '本周 $visibleCount 条 · 全局共 ${widget.controller.events.length} 个日程；'
              '筛选只影响展示，不改变忙碌计算。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: TsColors.textFaint,
              ),
            ),
          ),
          TextButton(
            key: const Key('schedule-list-close-footer'),
            style: TsButtons.inline(),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 列表行

  Widget _row(ScheduleOccurrence occurrence) {
    final event = widget.controller.eventById(occurrence.eventId);
    final linked = _conversationFor(occurrence.linkedConversationId);
    final timeLines = _timeLines(occurrence);
    final meta = <String>[
      _repeatLabel(event),
      if (occurrence.reminder != ScheduleReminderKind.none)
        '提醒：${occurrence.reminder.label}',
      if (occurrence.linkedConversationId != null)
        linked == null
            ? '关联：会话不可用'
            : '关联：${linked.title}${linked.statusLabel == null ? '' : '（${linked.statusLabel}）'}',
      if (event?.location != null && event!.location!.trim().isNotEmpty)
        '地点：${event.location!.trim()}',
      if (occurrence.timezoneId != widget.timezoneId)
        '时区：${occurrence.timezoneId}',
    ];
    final actions = <Widget>[
      if (occurrence.linkedConversationId != null &&
          widget.onOpenConversation != null)
        TextButton(
          key: Key('schedule-open-conversation-${occurrence.occurrenceKey}'),
          style: TsButtons.inline(fontSize: 11.5),
          onPressed: () => _openLinkedConversation(occurrence),
          child: const Text('打开会话'),
        ),
      TextButton(
        key: Key('schedule-edit-${occurrence.occurrenceKey}'),
        style: TsButtons.inline(fontSize: 11.5),
        onPressed: () => _edit(occurrence),
        child: const Text('编辑'),
      ),
      TextButton(
        key: Key('schedule-delete-${occurrence.occurrenceKey}'),
        style: TsButtons.inline(fontSize: 11.5).copyWith(
          foregroundColor: WidgetStatePropertyAll(TsColors.blocked),
        ),
        onPressed: () => _delete(occurrence),
        child: const Text('删除'),
      ),
    ];

    return Container(
      key: Key('schedule-row-${occurrence.occurrenceKey}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: bezierDecoration(color: TsColors.surfaceAlt, radius: 10),
      child: LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final leading = SizedBox(
          width: narrow ? 100 : 124,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                timeLines.$1,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                timeLines.$2,
                style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
              ),
            ],
          ),
        );
        final middle = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  occurrence.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
                if (occurrence.category != null)
                  _categoryBadge(occurrence.category!),
                if (!occurrence.blocksScheduling)
                  _badge('不占用', TsColors.done, TsColors.doneSoft),
                if (occurrence.isOverride)
                  _badge('本次已调整', TsColors.waiting, TsColors.waitingSoft),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              meta.join(' · '),
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: TsColors.textFaint,
              ),
            ),
          ],
        );
        final buttonRow = Wrap(spacing: 2, children: actions);
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  leading,
                  const SizedBox(width: 8),
                  Expanded(child: middle),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: buttonRow,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(child: middle),
            buttonRow,
          ],
        );
      }),
    );
  }

  Widget _badge(String label, Color foreground, Color background) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: bezierDecoration(color: background, radius: 6),
        child: Text(
          label,
          style: TextStyle(fontSize: 10.5, color: foreground),
        ),
      );

  Widget _categoryBadge(String wireName) {
    final label =
        ScheduleCategory.parse(wireName)?.label ?? wireName;
    final (foreground, background) = switch (wireName) {
      'work' => (TsColors.waiting, TsColors.waitingSoft),
      'study' => (TsColors.accent, TsColors.accentSoft),
      'life' => (TsColors.ready, TsColors.readySoft),
      _ => (TsColors.textSecondary, TsColors.doneSoft),
    };
    return _badge(label, foreground, background);
  }

  ScheduleConversationOption? _conversationFor(String? id) {
    if (id == null) return null;
    for (final option in widget.conversations) {
      if (option.id == id) return option;
    }
    return null;
  }

  // -------------------------------------------------------------- 展示格式

  String _repeatLabel(ScheduleEvent? event) {
    final rule = event?.repeat;
    if (rule == null || !rule.repeats) return '单次';
    final until = rule.untilDate;
    switch (rule.kind) {
      case ScheduleRepeatKind.daily:
        return until == null ? '每天' : '每天，至 $until';
      case ScheduleRepeatKind.weekly:
        final days = rule.weekdays
            .map((day) =>
                const ['一', '二', '三', '四', '五', '六', '日'][day - 1])
            .join('、');
        return '每周$days${until == null ? '' : '，至 $until'}';
      case ScheduleRepeatKind.none:
        return '单次';
    }
  }

  /// 返回（日期行, 时间行）；定时实例按日程自身时区的墙钟显示。
  (String, String) _timeLines(ScheduleOccurrence occurrence) {
    if (occurrence.allDay) {
      final start = dateKeyToUtc(occurrence.startDate ?? '');
      final endExclusive = dateKeyToUtc(occurrence.endDateExclusive ?? '');
      final startLabel = start == null
          ? (occurrence.startDate ?? '')
          : '${_md(start)} ${_weekdayName(start.weekday)}';
      if (start == null || endExclusive == null) {
        return (startLabel, '全天');
      }
      final endInclusive = endExclusive.subtract(const Duration(days: 1));
      if (endInclusive.isAtSameMomentAs(start)) {
        return (startLabel, '全天');
      }
      final days = endExclusive.difference(start).inDays;
      return ('${_md(start)} – ${_md(endInclusive)}', '全天 · $days 天');
    }
    final start = occurrence.startUtc == null
        ? null
        : wallOf(occurrence.startUtc!, occurrence.timezoneId);
    final end = occurrence.endUtc == null
        ? null
        : wallOf(occurrence.endUtc!, occurrence.timezoneId);
    if (start == null || end == null) {
      return ('时间未知', '');
    }
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) {
      return (
        '${_md(start)} ${_weekdayName(start.weekday)}',
        '${_hm(start)}–${_hm(end)}',
      );
    }
    return (
      '${_md(start)} ${_hm(start)} →',
      '${_md(end)} ${_hm(end)}',
    );
  }

  String _weekRangeLabel(DateTime start, DateTime end) {
    final sameYear = start.year == end.year;
    final startLabel = '${start.year} ${_md(start)}';
    return sameYear
        ? '$startLabel – ${_md(end)}'
        : '$startLabel – ${end.year} ${_md(end)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _md(DateTime date) =>
      '${_two(date.month)}-${_two(date.day)}';

  static String _hm(DateTime date) =>
      '${_two(date.hour)}:${_two(date.minute)}';

  static String _weekdayName(int weekday) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];
}
