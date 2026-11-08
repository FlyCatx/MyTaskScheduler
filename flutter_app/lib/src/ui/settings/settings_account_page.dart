// 本地身份展示页。账户服务已取消，这里只展示本机身份事实，不提供登录/改密表单。

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class SettingsAccountPage extends StatelessWidget {
  const SettingsAccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsGroupLabel('当前身份'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsTile(
                leading: Icons.account_circle_outlined,
                title: '本地账户',
                trailing: Text(
                  kLocalUserName,
                  style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                ),
              ),
              const SettingsCardDivider(),
              const SettingsKeyValue(label: '登录状态', value: '未登录云端'),
              const SettingsKeyValue(label: '云端同步', value: '不支持'),
              const SettingsKeyValue(label: '密码', value: '未保存任何密码'),
            ],
          ),
        ),
      ],
    );
  }
}
