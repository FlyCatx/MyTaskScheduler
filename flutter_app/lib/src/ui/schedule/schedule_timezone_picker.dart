// 时区选择器（任务 10.3/10.4）：可搜索、可滚动的应用风格选单。
//
// 规则：
//   * 选项来自 IANA 数据库（中文城市 + 当前 UTC 偏移展示），保存 IANA ID；
//   * 搜索只缩小选项，不接受任意文本作为保存值；
//   * 同偏移不同 DST 的地区分别列出，并用“有夏令时”标记区分；
//   * 旧数据里的 IANA ID 先精确命中；目录里没有时由调用方显示“修复入口”，
//     本选单只负责返回用户明确选中的有效 IANA ID。

import 'package:flutter/material.dart';

import '../../state/schedule/schedule_timezones.dart';
import '../theme.dart';
import '../widgets/bezier_ui.dart';

/// 打开时区选单；返回选中的 IANA ID，取消返回 null。
Future<String?> showScheduleTimeZonePicker(
  BuildContext context, {
  required String? currentId,
  DateTime Function()? clock,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => ScheduleTimeZonePicker(
      currentId: currentId,
      clock: clock,
    ),
  );
}

class ScheduleTimeZonePicker extends StatefulWidget {
  const ScheduleTimeZonePicker({
    super.key,
    required this.currentId,
    this.clock,
  });

  final String? currentId;
  final DateTime Function()? clock;

  @override
  State<ScheduleTimeZonePicker> createState() => _ScheduleTimeZonePickerState();
}

class _ScheduleTimeZonePickerState extends State<ScheduleTimeZonePicker> {
  final TextEditingController _search = TextEditingController();
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = _clock().toUtc();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final options = ScheduleTimeZoneCatalog.search(_search.text, _now);
    final current =
        ScheduleTimeZoneCatalog.find(widget.currentId, _now);
    return Dialog(
      key: const Key('schedule-timezone-picker'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const BezierRoundedRectangleBorder(radius: 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择时区',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: TsColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('schedule-timezone-picker-close'),
                    tooltip: '关闭',
                    style: TsButtons.closeIcon(size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('schedule-timezone-search'),
                controller: _search,
                autofocus: true,
                style: const TextStyle(fontSize: 12.5),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '搜索城市、地区或 IANA 名称（如 北京、Asia/Shanghai）',
                  prefixIcon: Icon(Icons.search, size: 16),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '按当前 UTC 偏移排列；保存时使用 IANA 标识，不使用任意文本。',
                style: TextStyle(
                  fontSize: 10.5,
                  color: TsColors.textFaint,
                ),
              ),
              const SizedBox(height: 6),
              Divider(height: 1, thickness: 1, color: TsColors.border),
              Expanded(
                child: options.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的时区，换个关键词试试',
                          style: TextStyle(
                            fontSize: 12,
                            color: TsColors.textSecondary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('schedule-timezone-list'),
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final option = options[index];
                          final selected = option.id == current?.id ||
                              option.id == widget.currentId;
                          return _TimeZoneRow(
                            option: option,
                            selected: selected,
                            onTap: () =>
                                Navigator.of(context).pop(option.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeZoneRow extends StatefulWidget {
  const _TimeZoneRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ScheduleTimeZoneOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TimeZoneRow> createState() => _TimeZoneRowState();
}

class _TimeZoneRowState extends State<_TimeZoneRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: Key('schedule-timezone-option-${option.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: widget.selected
                ? TsColors.accentSoft
                : (_hover ? TsColors.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${option.offsetLabel} ${option.cityLabel}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: TsColors.textPrimary,
                            ),
                          ),
                        ),
                        if (option.observesDst) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: bezierDecoration(
                              color: TsColors.pendingSoft,
                              radius: 4,
                            ),
                            child: Text(
                              '有夏令时',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: TsColors.pending,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      option.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: TsColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected)
                Icon(Icons.check, size: 16, color: TsColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
