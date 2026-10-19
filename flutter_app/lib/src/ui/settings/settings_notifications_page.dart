// 通知页：只控制应用内提醒开关。
// 120 秒等待提醒属于请求控制（继续等待 / 取消请求），不受本页开关影响；
// 系统通知可能被操作系统拦下，因此文案不承诺“已弹出”。
//
// 主要类型：SettingsNotificationsPage。

import 'package:flutter/material.dart';

import '../../state/settings_controller.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class SettingsNotificationsPage extends StatelessWidget {
  final SettingsController controller;

  const SettingsNotificationsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.draft.prefs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsGroupLabel('应用内提醒'),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsTile(
                    leading: Icons.task_alt,
                    title: '分析完成提醒',
                    trailing: Switch(
                      value: prefs.notifyOnSuccess,
                      onChanged: (value) => controller.updateDraftPreferences(
                          prefs.copyWith(notifyOnSuccess: value)),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.error_outline,
                    title: '分析失败提醒',
                    trailing: Switch(
                      value: prefs.notifyOnFailure,
                      onChanged: (value) => controller.updateDraftPreferences(
                          prefs.copyWith(notifyOnFailure: value)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: TsSizes.gapBetweenGroups),
            const SettingsGroupLabel('系统通知（Windows 通知中心）'),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsTile(
                    leading: Icons.desktop_windows_outlined,
                    title: '完成/失败时显示系统通知',
                    trailing: Switch(
                      key: const Key('settings-notify-system'),
                      value: prefs.notifySystem,
                      onChanged: (value) => controller.updateDraftPreferences(
                          prefs.copyWith(notifySystem: value)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SettingsNote(
                    icon: Icons.hourglass_bottom,
                    tone: TsColors.pending,
                    background: TsColors.pendingSoft,
                    text: '120 秒提醒不是通知：等待超过 120 秒时会提示「继续等待 / 取消请求」，'
                        '不会被上面的开关静音。系统可能拦截通知，程序会如实提示结果。',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

