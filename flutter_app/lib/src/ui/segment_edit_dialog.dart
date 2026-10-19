// 单个日历片段的精确编辑框：键盘可操作，可填任意起止时间（含非 15 分钟时长），
// 也可直接删除该排程（与“减少工时”是两个不同动作）。
//
// 主要函数/类型：showSegmentEditDialog、SegmentEditResult。

import 'package:flutter/material.dart';

import '../model/calendar.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class SegmentEditResult {
  final DateTime start;
  final DateTime end;
  final bool cancel;

  const SegmentEditResult({
    required this.start,
    required this.end,
    this.cancel = false,
  });

  /// "取消此段安排" — nothing of the time fields is used, only [cancel].
  static SegmentEditResult get remove => SegmentEditResult(
        start: DateTime.utc(1970),
        end: DateTime.utc(1970),
        cancel: true,
      );
}

Future<SegmentEditResult?> showSegmentEditDialog(
  BuildContext context, {
  required ScheduleSegment segment,
  required CalendarSettings settings,
  required String taskName,
}) {
  return showDialog<SegmentEditResult>(
    context: context,
    builder: (_) => _SegmentEditDialog(
      segment: segment,
      settings: settings,
      taskName: taskName,
    ),
  );
}

class _SegmentEditDialog extends StatefulWidget {
  final ScheduleSegment segment;
  final CalendarSettings settings;
  final String taskName;

  const _SegmentEditDialog({
    required this.segment,
    required this.settings,
    required this.taskName,
  });

  @override
  State<_SegmentEditDialog> createState() => _SegmentEditDialogState();
}

class _SegmentEditDialogState extends State<_SegmentEditDialog> {
  late final WallClock _clock = widget.settings.clock;
  late final TextEditingController _startDate;
  late final TextEditingController _startTime;
  late final TextEditingController _endDate;
  late final TextEditingController _endTime;
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = _clock.toWall(widget.segment.start);
    final end = _clock.toWall(widget.segment.end);
    _startDate = TextEditingController(text: _date(start));
    _startTime = TextEditingController(text: _time(start));
    _endDate = TextEditingController(text: _date(end));
    _endTime = TextEditingController(text: _time(end));
  }

  @override
  void dispose() {
    _startDate.dispose();
    _startTime.dispose();
    _endDate.dispose();
    _endTime.dispose();
    super.dispose();
  }

  static String _date(DateTime wall) =>
      '${wall.year.toString().padLeft(4, '0')}-'
      '${wall.month.toString().padLeft(2, '0')}-'
      '${wall.day.toString().padLeft(2, '0')}';

  static String _time(DateTime wall) =>
      '${wall.hour.toString().padLeft(2, '0')}:'
      '${wall.minute.toString().padLeft(2, '0')}';

  DateTime? _parse(TextEditingController date, TextEditingController time) {
    final d = parseDateKey(date.text);
    if (d == null) return null;
    final m = RegExp(r'^\s*(\d{1,2})\s*[:：]\s*(\d{1,2})\s*$')
        .firstMatch(time.text);
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final minute = int.parse(m.group(2)!);
    if (h > 23 || minute > 59) return null;
    final parts = d.split('-').map(int.parse).toList();
    return _clock.fromWall(DateTime.utc(parts[0], parts[1], parts[2], h, minute));
  }

  void _setDuration(int minutes) {
    final start = _parse(_startDate, _startTime);
    if (start == null) {
      setState(() => _error = '先填写合法的开始日期与时间');
      return;
    }
    final end = _clock.toWall(start.add(Duration(minutes: minutes)));
    setState(() {
      _error = null;
      _endDate.text = _date(end);
      _endTime.text = _time(end);
    });
  }

  void _submit() {
    final start = _parse(_startDate, _startTime);
    final end = _parse(_endDate, _endTime);
    if (start == null || end == null) {
      setState(() => _error = '日期需为 yyyy-MM-dd，时间需为 HH:MM');
      return;
    }
    if (!end.isAfter(start)) {
      setState(() => _error = '结束时间必须晚于开始时间');
      return;
    }
    Navigator.of(context).pop(SegmentEditResult(start: start, end: end));
  }

  @override
  Widget build(BuildContext context) {
    final minutes = widget.segment.minutes;
    return AlertDialog(
      title: const Text('精确编辑安排片段', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.taskName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary)),
            const SizedBox(height: 2),
            Text(
              '当前 ${formatMinutes(minutes)}（${widget.settings.timezoneId}）',
              style: TextStyle(fontSize: 11, color: TsColors.textFaint),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('segment-edit-start-date'),
                    controller: _startDate,
                    decoration: const InputDecoration(labelText: '开始日期'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('segment-edit-start-time'),
                    controller: _startTime,
                    decoration: const InputDecoration(labelText: '开始时间'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('segment-edit-end-date'),
                    controller: _endDate,
                    decoration: const InputDecoration(labelText: '结束日期'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('segment-edit-end-time'),
                    controller: _endTime,
                    decoration: const InputDecoration(labelText: '结束时间'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in const [15, 30, 45, 60, 90, 120])
                  TextButton(
                    onPressed: () => _setDuration(m),
                    style: TsButtons.filled(
                      radius: 7,
                      minimumSize: const Size(0, 26),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      fontSize: 11,
                    ),
                    child: Text('$m 分钟'),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(fontSize: 11.5, color: TsColors.blocked)),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: bezierDecoration(color: TsColors.background, radius: 8),
              child: Text(
                '修改片段时长会按“变化量”同步预计工时：'
                '完整安排的任务变成片段之和，部分安排的任务保留未安排余额。'
                '“取消此段安排”只把工时退回未安排余额，不减少预计工时。',
                style: TextStyle(
                    fontSize: 10.5, height: 1.5, color: TsColors.textFaint),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('segment-edit-cancel-arrangement'),
          onPressed: () =>
              Navigator.of(context).pop(SegmentEditResult.remove),
          style: TsButtons.danger(radius: 8),
          child: const Text('取消此段安排'),
        ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回')),
        FilledButton(
          key: const Key('segment-edit-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// `90 分钟` / `1 小时 30 分`, shared with other calendar surfaces.
String formatMinutes(int minutes) {
  final m = minutes.abs();
  final h = m ~/ 60;
  final rest = m % 60;
  if (h == 0) return '$rest 分钟';
  if (rest == 0) return '$h 小时';
  return '$h 小时 $rest 分';
}

