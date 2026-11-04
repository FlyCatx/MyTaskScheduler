// 通用页：外观与输入偏好（主题、字号等）。
// 所有编辑先写入 SettingsController.draft，由页脚的 应用 / 保存 决定何时写盘。
//
// 主要类型：SettingsGeneralPage。

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../../state/settings_controller.dart';
import '../../state/time_ranges.dart';
import '../widgets/bezier_ui.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class SettingsGeneralPage extends StatelessWidget {
  final SettingsController controller;

  const SettingsGeneralPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.draft.prefs;
        void update(AppPreferences next) =>
            controller.updateDraftPreferences(next);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsGroupLabel('外观'),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsTile(
                    leading: Icons.brightness_6_outlined,
                    title: '主题',
                    trailing: BezierSegments(
                      height: 28,
                      itemWidth: 64,
                      items: const [
                        BezierSegmentItem('浅色'),
                        BezierSegmentItem('深色'),
                        BezierSegmentItem('自动'),
                      ],
                      selected: switch (prefs.themeMode) {
                        AppThemeMode.light => 0,
                        AppThemeMode.dark => 1,
                        AppThemeMode.system => 2,
                      },
                      onChanged: (index) => update(prefs.copyWith(
                        themeMode: switch (index) {
                          0 => AppThemeMode.light,
                          1 => AppThemeMode.dark,
                          _ => AppThemeMode.system,
                        },
                      )),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.format_size,
                    title: '字号',
                    trailing: SizedBox(
                      width: 230,
                      child: Row(
                        children: [
                          Expanded(
                            child: Slider(
                              min: AppPreferences.minFontScale,
                              max: AppPreferences.maxFontScale,
                              divisions: 45,
                              value: prefs.fontScale,
                              label: '${(prefs.fontScale * 100).round()}%',
                              onChanged: (value) => update(
                                  prefs.copyWith(fontScale: value)),
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            child: Text(
                              '${(prefs.fontScale * 100).round()}%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: TsColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.account_tree_outlined,
                    title: '默认依赖视图',
                    trailing: BezierSegments(
                      height: 28,
                      itemWidth: 78,
                      items: const [
                        BezierSegmentItem('依赖图'),
                        BezierSegmentItem('甘特图'),
                      ],
                      selected: prefs.defaultChartMode ==
                              AppPreferences.kChartModeGantt
                          ? 1
                          : 0,
                      onChanged: (index) => update(prefs.copyWith(
                        defaultChartMode: index == 1
                            ? AppPreferences.kChartModeGantt
                            : AppPreferences.kChartModeTree,
                      )),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.checklist_rtl,
                    title: '显示已完成任务',
                    trailing: Switch(
                      value: prefs.showCompletedTasks,
                      onChanged: (value) => update(
                          prefs.copyWith(showCompletedTasks: value)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: TsSizes.gapBetweenGroups),
            const SettingsGroupLabel('输入'),
            SettingsCard(
              child: SettingsTile(
                leading: Icons.send_outlined,
                title: '发送方式',
                trailing: BezierSegments(
                  height: 28,
                  items: const [
                    BezierSegmentItem('Ctrl+Enter 发送'),
                    BezierSegmentItem('Enter 发送'),
                  ],
                  selected: prefs.sendMode == SendMode.enter ? 1 : 0,
                  onChanged: (index) => update(prefs.copyWith(
                    sendMode:
                        index == 1 ? SendMode.enter : SendMode.ctrlEnter,
                  )),
                ),
              ),
            ),
            const SizedBox(height: TsSizes.gapBetweenGroups),
            const SettingsGroupLabel('日历与时间表'),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsTile(
                    leading: Icons.view_week_outlined,
                    title: '每周第一天',
                    trailing: DropdownButton<int>(
                      key: const Key('settings-week-starts-on'),
                      value: prefs.weekStartsOn,
                      underline: const SizedBox.shrink(),
                      style: TextStyle(
                          fontSize: 12, color: TsColors.textPrimary),
                      items: [
                        for (var d = 1; d <= 7; d++)
                          DropdownMenuItem(
                            value: d,
                            child: Text(_weekdayLabel(d)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          update(prefs.copyWith(weekStartsOn: value));
                        }
                      },
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.edit_calendar_outlined,
                    title: '默认编辑方式',
                    trailing: BezierSegments(
                      height: 28,
                      itemWidth: 84,
                      items: const [
                        BezierSegmentItem('手动填写'),
                        BezierSegmentItem('手动绘制'),
                      ],
                      selected: prefs.defaultCalendarEditor ==
                              CalendarEditorMode.drawing
                          ? 1
                          : 0,
                      onChanged: (index) => update(prefs.copyWith(
                        defaultCalendarEditor: index == 1
                            ? CalendarEditorMode.drawing
                            : CalendarEditorMode.fill,
                      )),
                    ),
                  ),
                  const SettingsCardDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.nightlight_outlined,
                                size: 17, color: TsColors.textSecondary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('默认不可用时间',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: TsColors.textPrimary)),
                            ),
                            Text(
                              '每天可用 ${(1440 - UnavailableRange.totalMinutes(prefs.defaultUnavailableRanges)) ~/ 60} 小时 '
                              '${(1440 - UnavailableRange.totalMinutes(prefs.defaultUnavailableRanges)) % 60} 分',
                              style: TextStyle(
                                  fontSize: 10.5, color: TsColors.textFaint),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _DefaultUnavailableField(
                          ranges: prefs.defaultUnavailableRanges,
                          onChanged: (ranges) =>
                              update(prefs.copyWith(defaultUnavailableRanges: ranges)),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            TextButton(
                              key: const Key('settings-unavailable-reset'),
                              onPressed: () => update(prefs.copyWith(
                                  defaultUnavailableRanges:
                                      UnavailableRange.defaults)),
                              child: const Text('恢复默认'),
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              key: const Key('settings-unavailable-clear'),
                              onPressed: () => update(prefs.copyWith(
                                  defaultUnavailableRanges:
                                      const <UnavailableRange>[])),
                              child: const Text('清空（全天可用）'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _weekdayLabel(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };
}

/// 默认不可用时间的文本编辑器：`23:00-08:00, 12:00-14:00`。
///
/// 解析失败只显示错误，不把半截输入写进偏好；清空表示“全天可用”。
class _DefaultUnavailableField extends StatefulWidget {
  final List<UnavailableRange> ranges;
  final ValueChanged<List<UnavailableRange>> onChanged;

  const _DefaultUnavailableField({
    required this.ranges,
    required this.onChanged,
  });

  @override
  State<_DefaultUnavailableField> createState() =>
      _DefaultUnavailableFieldState();
}

class _DefaultUnavailableFieldState extends State<_DefaultUnavailableField> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.ranges));
  }

  @override
  void didUpdateWidget(covariant _DefaultUnavailableField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _format(widget.ranges);
    if (next != _controller.text &&
        widget.ranges.toString() != oldWidget.ranges.toString()) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _format(List<UnavailableRange> ranges) => ranges
      .map((r) => '${_hhmm(r.start)}-${_hhmm(r.end)}')
      .join(', ');

  static String _hhmm(int minute) {
    final m = minute % 1440;
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  void _onChanged(String text) {
    if (text.trim().isEmpty) {
      setState(() => _error = null);
      widget.onChanged(const <UnavailableRange>[]);
      return;
    }
    final parsed = parseTimeRanges(text);
    if (!parsed.ok) {
      setState(() => _error = '时间格式应为 HH:mm-HH:mm，多段用逗号分隔');
      return;
    }
    final ranges = parsed.ranges
        .map((r) => UnavailableRange(r.startMinute, r.endMinute))
        .toList(growable: false);
    setState(() => _error = null);
    widget.onChanged(UnavailableRange.normalizeAll(ranges));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('settings-default-unavailable'),
          controller: _controller,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            hintText: '例如 23:00-08:00, 12:00-14:00',
            isDense: true,
            errorText: _error,
          ),
          onChanged: _onChanged,
        ),
      ],
    );
  }
}
