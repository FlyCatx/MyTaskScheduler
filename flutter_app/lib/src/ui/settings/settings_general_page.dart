// 通用页：外观与输入偏好（主题、字号等）。
// 所有编辑先写入 SettingsController.draft，由页脚的 应用 / 保存 决定何时写盘。
//
// 主要类型：SettingsGeneralPage。

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../../state/settings_controller.dart';
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
          ],
        );
      },
    );
  }
}

