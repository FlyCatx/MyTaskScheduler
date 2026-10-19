// 账户安全页：只做展示，不接任何账号服务。
// 显示本地身份（admin）；登录/改密表单一律禁用，不发网络请求、不保存密码。
//
// 主要类型：SettingsAccountPage。

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
              ),              const SettingsCardDivider(),
              const SettingsKeyValue(label: '登录状态', value: '未登录云端'),
              const SettingsKeyValue(label: '云端同步', value: '不支持'),
              const SettingsKeyValue(label: '密码', value: '未保存任何密码'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const SettingsGroupLabel('登录（未接入）'),
        const SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DisabledField(
                label: '账号',
                hint: '账户服务未接入，无法填写',
                icon: Icons.mail_outline,
              ),
              SizedBox(height: 10),
              _DisabledField(
                label: '密码',
                hint: '本版本不接收、不保存密码',
                icon: Icons.lock_outline,
                obscure: true,
              ),
              SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  // Deliberately null: a disabled button cannot fake a sign-in.
                  onPressed: null,
                  child: Text('登录'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const SettingsGroupLabel('修改密码（未接入）'),
        const SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DisabledField(
                label: '新密码',
                hint: '账户服务未接入',
                icon: Icons.password_outlined,
                obscure: true,
              ),
              SizedBox(height: 10),
              _DisabledField(
                label: '确认新密码',
                hint: '账户服务未接入',
                icon: Icons.password_outlined,
                obscure: true,
              ),
              SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: null,
                  child: Text('修改密码'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A read-only field that LOOKS like an input but cannot be focused or edited.
class _DisabledField extends StatelessWidget {
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;

  const _DisabledField({
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      // `enabled: false` is what makes the "no editable field" test true: the widget
      // still exists for layout, but the platform text input connection is never opened.
      enabled: false,
      obscureText: obscure,
      initialValue: '',
      style: TextStyle(fontSize: 12.5, color: TsColors.textFaint),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 16, color: TsColors.textFaint),
        suffixIcon: Icon(Icons.lock_outline, size: 14, color: TsColors.textFaint),
      ),
    );
  }
}

