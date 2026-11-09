// 日程详情弹窗（任务 11.4）。
//
// 交互与规则：
//   * 点击周视图事件弹出，显示存在的时间/地点/分类/会话/任务/提醒；
//   * “编辑日程”打开原编辑器；关闭详情只关闭自身，调用方仍停留在原周；
//   * 关联任务按稳定 ID 解析：任务改名后仍显示新名字并跳到同一个任务；任务被删除
//     或会话失效时显示“关联任务已不存在/会话不可用”，不按同名猜测跳转；
//   * 无关联任务时不画任何跳转入口（避免空跳转）。

import 'package:flutter/material.dart';

import '../../model/schedule_event.dart';
import '../../state/schedule/schedule_expander.dart' show ScheduleOccurrence, wallOf;
import '../theme.dart';
import '../widgets/bezier_ui.dart';
import 'schedule_editor_dialog.dart'
    show ScheduleConversationOption, ScheduleTaskOption;

/// 打开日程详情；返回后调用方仍停留在原周（本弹窗不改变周/选中状态）。
Future<void> showScheduleDetailDialog(
  BuildContext context, {
  required ScheduleOccurrence occurrence,
  required ScheduleEvent? event,
  required String displayTimezoneId,
  required List<ScheduleConversationOption> conversations,
  required Future<ScheduleTaskOption?> Function()? resolveLinkedTask,
  required VoidCallback onEdit,
  Future<void> Function()? onDelete,
  Future<void> Function(String conversationId)? onOpenConversation,
  Future<void> Function(ScheduleTaskOption task)? onOpenTask,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ScheduleDetailDialog(
      occurrence: occurrence,
      event: event,
      displayTimezoneId: displayTimezoneId,
      conversations: conversations,
      resolveLinkedTask: resolveLinkedTask,
      onEdit: onEdit,
      onDelete: onDelete,
      onOpenConversation: onOpenConversation,
      onOpenTask: onOpenTask,
    ),
  );
}

class ScheduleDetailDialog extends StatelessWidget {
  const ScheduleDetailDialog({
    super.key,
    required this.occurrence,
    required this.event,
    required this.displayTimezoneId,
    required this.conversations,
    required this.resolveLinkedTask,
    required this.onEdit,
    this.onDelete,
    this.onOpenConversation,
    this.onOpenTask,
  });

  final ScheduleOccurrence occurrence;
  final ScheduleEvent? event;
  final String displayTimezoneId;
  final List<ScheduleConversationOption> conversations;
  final Future<ScheduleTaskOption?> Function()? resolveLinkedTask;
  final VoidCallback onEdit;
  final Future<void> Function()? onDelete;
  final Future<void> Function(String conversationId)? onOpenConversation;
  final Future<void> Function(ScheduleTaskOption task)? onOpenTask;

  @override
  Widget build(BuildContext context) {
    final category = event?.category;
    final categoryLabel =
        category?.label ?? ScheduleCategory.parse(occurrence.category)?.label;
    final location = event?.location?.trim();
    final linkedConversationId = event?.linkedConversationId;
    final linkedConversation = _conversationFor(linkedConversationId);
    final linkedTaskId = event?.linkedTaskId;
    final reminder = event?.reminder ?? occurrence.reminder;

    final rows = <Widget>[
      _row('时间', _timeText()),
      if (location != null && location.isNotEmpty) _row('地点', location),
      if (categoryLabel != null && categoryLabel.isNotEmpty)
        _row(
          '分类',
          categoryLabel,
          leading: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _categoryColor(category ?? ScheduleCategory.parse(occurrence.category)),
              shape: BoxShape.circle,
            ),
          ),
        ),
      if (linkedConversationId != null)
        _row(
          '关联会话',
          linkedConversation?.title ?? '会话不可用',
          trailing: linkedConversation != null && onOpenConversation != null
              ? TextButton(
                  key: const Key('schedule-detail-open-conversation'),
                  style: TsButtons.link(),
                  onPressed: () => onOpenConversation!(linkedConversationId),
                  child: const Text('打开'),
                )
              : null,
        ),
      if (linkedTaskId != null)
        _linkedTaskRow(context, linkedTaskId, linkedConversationId),
      if (reminder != ScheduleReminderKind.none)
        _row(
          '提醒',
          reminder.label,
          trailing: Text(
            '应用运行期间',
            style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
          ),
        ),
    ];

    return Dialog(
      key: const Key('schedule-detail-dialog'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const BezierRoundedRectangleBorder(radius: 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      occurrence.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: TsColors.textPrimary,
                      ),
                    ),
                  ),
                  TsCloseButton(
                    key: const Key('schedule-detail-close'),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Divider(height: 1, thickness: 1, color: TsColors.border),
              const SizedBox(height: 8),
              ...rows,
              const SizedBox(height: 8),
              TsDialogActions(
                actions: [
                  if (onDelete != null)
                    TsDialogAction(
                      key: const Key('schedule-detail-delete'),
                      label: '删除',
                      role: TsDialogActionRole.leading,
                      onPressed: () {
                        Navigator.of(context).pop();
                        onDelete!();
                      },
                    ),
                  TsDialogAction(
                    key: const Key('schedule-detail-edit'),
                    label: '编辑日程',
                    role: TsDialogActionRole.secondary,
                    onPressed: () {
                      Navigator.of(context).pop();
                      onEdit();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linkedTaskRow(
    BuildContext context,
    String linkedTaskId,
    String? conversationId,
  ) {
    final resolver = resolveLinkedTask;
    if (resolver == null || conversationId == null) {
      return _row('关联任务', '关联任务不可用');
    }
    return FutureBuilder<ScheduleTaskOption?>(
      future: resolver(),
      builder: (context, snapshot) {
        final task = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return _row(
            '关联任务',
            '读取中…',
            trailing: const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          );
        }
        if (task == null) {
          // 任务被删除或会话失效：明确说明，绝不按同名任务误跳。
          return _row('关联任务', '关联任务已不存在');
        }
        final canOpen = onOpenTask != null;
        return _row(
          '关联任务',
          task.title,
          key: const Key('schedule-detail-linked-task'),
          trailing: canOpen
              ? TextButton(
                  key: const Key('schedule-detail-open-task'),
                  style: TsButtons.link(),
                  onPressed: () => onOpenTask!(task),
                  child: const Text('打开 ↗'),
                )
              : null,
        );
      },
    );
  }

  Widget _row(
    String label,
    String value, {
    Key? key,
    Widget? leading,
    Widget? trailing,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: TsColors.textFaint),
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leading != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 6),
                    child: leading,
                  ),
                ],
                Expanded(
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: TsColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  /// 时间行：定时按显示时区展示；全天按日期区间展示。
  String _timeText() {
    if (occurrence.allDay) {
      final start = occurrence.startDate == null
          ? null
          : dateKeyToUtc(occurrence.startDate!);
      final end = occurrence.endDateExclusive == null
          ? null
          : dateKeyToUtc(occurrence.endDateExclusive!);
      if (start == null || end == null) return '全天';
      final endInclusive = end.subtract(const Duration(days: 1));
      if (endInclusive.isAtSameMomentAs(start)) {
        return '${_md(start)} ${_weekday(start.weekday)} · 全天';
      }
      return '${_md(start)} ${_weekday(start.weekday)} – '
          '${_md(endInclusive)} ${_weekday(endInclusive.weekday)} · 全天';
    }
    final startUtc = occurrence.startUtc;
    final endUtc = occurrence.endUtc;
    if (startUtc == null || endUtc == null) return '时间未知';
    final start = wallOf(startUtc, displayTimezoneId);
    final end = wallOf(endUtc, displayTimezoneId);
    if (start == null || end == null) return '时间未知';
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    if (sameDay) {
      return '${_md(start)} ${_weekday(start.weekday)} '
          '${_hm(start)}-${_hm(end)}';
    }
    return '${_md(start)} ${_weekday(start.weekday)} ${_hm(start)} → '
        '${_md(end)} ${_weekday(end.weekday)} ${_hm(end)}';
  }

  ScheduleConversationOption? _conversationFor(String? id) {
    if (id == null) return null;
    for (final option in conversations) {
      if (option.id == id) return option;
    }
    return null;
  }

  static Color _categoryColor(ScheduleCategory? category) {
    switch (category) {
      case ScheduleCategory.work:
        return TsColors.waiting;
      case ScheduleCategory.study:
        return TsColors.accent;
      case ScheduleCategory.life:
        return TsColors.ready;
      case null:
        return TsColors.done;
    }
  }

  static String _md(DateTime date) =>
      '${date.month}月${date.day}日';

  static String _hm(DateTime date) =>
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';

  static String _weekday(int weekday) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][weekday - 1];
}
