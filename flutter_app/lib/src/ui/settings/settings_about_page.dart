// 关于页：版本、许可、帮助入口与脱敏诊断文本。
// 版本取自 kAppVersion；检查更新保持原位置但禁用（无更新后端）；
// 帮助打开可执行文件旁的 README，缺失时如实说明；
// 诊断文本只含版本/ABI/端点主机/连接数/存储路径，绝不含密钥、完整 URL 或提示词。
//
// 主要类型：SettingsAboutPage、_DiagnosticsDisclosure。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../model/abi.dart';
import '../../state/settings_controller.dart';
import '../theme.dart';
import '../widgets/bezier_ui.dart';
import 'settings_widgets.dart';

class SettingsAboutPage extends StatelessWidget {
  final SettingsController controller;

  const SettingsAboutPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SettingsTile(
                    leading: Icons.verified_outlined,
                    title: '版本信息',
                    subtitle: '$kAppName $kAppVersion（本机桌面版）',
                    trailing: Tooltip(
                      message: '更新服务尚未接入',
                      child: SettingsOutlinedButton(
                        label: '检查更新',
                        onPressed: null,
                      ),
                    ),
                  ),
                  const SettingsNote(
                    icon: Icons.cloud_off_outlined,
                    text: '更新服务未配置',
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.help_outline,
                    title: '帮助',
                    trailing: SettingsOutlinedButton(
                      label: '查看帮助',
                      onPressed: () => _openReadme(context),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.gavel_outlined,
                    title: '许可证',
                    trailing: SettingsOutlinedButton(
                      label: '复制许可说明',
                      onPressed: () => _copy(
                        context,
                        _licenseText(),
                        '已复制许可证说明',
                      ),
                    ),
                  ),
                  const SettingsCardDivider(),
                  SettingsTile(
                    leading: Icons.content_copy_outlined,
                    title: '脱敏诊断',
                    trailing: SettingsOutlinedButton(
                      label: '复制诊断',
                      onPressed: () => _copy(
                        context,
                        buildSanitizedDiagnostics(controller),
                        '已复制脱敏诊断信息',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SettingsCard(
              child: _DiagnosticsDisclosure(controller: controller),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                _FooterLink(
                  label: '服务协议',
                  onTap: () => showSettingsMessage(
                      context, '服务协议：本版本随程序分发，未接入在线协议页'),
                ),
                _FooterLink(
                  label: '隐私协议',
                  onTap: () => showSettingsMessage(
                      context, '隐私说明：所有数据保存在本机，程序不上传材料与密钥'),
                ),
                _FooterLink(
                  label: '意见反馈',
                  onTap: () => showSettingsMessage(context, '该功能尚未接入'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Copyright © 2026 $kAppName. All rights reserved.',
              style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------- actions

  Future<void> _copy(BuildContext context, String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    showSettingsMessage(context, done);
  }

  Future<void> _openReadme(BuildContext context) async {
    final path = findProgramReadme();
    if (path == null) {
      showSettingsMessage(
        context,
        '未找到 README（已查找程序目录：${programDirectory()}）',
      );
      return;
    }
    final ok = await openPathWithShell(path);
    if (!context.mounted) return;
    if (!ok) showSettingsMessage(context, '无法打开 $path');
  }
}

class _DiagnosticsDisclosure extends StatefulWidget {
  final SettingsController controller;
  const _DiagnosticsDisclosure({required this.controller});

  @override
  State<_DiagnosticsDisclosure> createState() => _DiagnosticsDisclosureState();
}

class _DiagnosticsDisclosureState extends State<_DiagnosticsDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            key: const Key('about-diagnostics'),
            customBorder: const BezierRoundedRectangleBorder(radius: 7),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
              child: Row(
                children: [
                  Text('诊断信息',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: TsColors.textPrimary)),
                  const Spacer(),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: TsColors.textFaint),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SettingsKeyValue(
                    label: '运行界面', value: 'Flutter (Windows desktop)'),
                const SettingsKeyValue(
                    label: '分析内核',
                    value:
                        'ts_bridge.dll / 现有 C 核心（ABI $kExpectedAbiVersion）'),
                SettingsKeyValue(
                  label: '数据位置',
                  value: widget.controller.dataRootPath.isEmpty
                      ? '（内存中，本次运行不保存）'
                      : widget.controller.dataRootPath,
                ),
                SettingsKeyValue(
                  label: '设置文件',
                  value: widget.controller.settingsPath.isEmpty
                      ? '设置文件尚未生成'
                      : widget.controller.settingsPath,
                ),
                SettingsKeyValue(
                    label: '模型连接',
                    value: '${widget.controller.profiles.length} 个已保存连接'),
              ],
            ),
          ),
      ],
    );
  }
}

class _FooterLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FooterLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const BezierRoundedRectangleBorder(radius: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Text(
          label,
          style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ helpers

/// Directory that contains the running executable (portable package root).
String programDirectory() => File(Platform.resolvedExecutable).parent.path;

/// First README-like file next to the executable, or `null` when none exists.
String? findProgramReadme() {
  final dir = programDirectory();
  const names = <String>[
    'README.txt',
    'README.md',
    'readme.txt',
    'readme.md',
    '使用说明.txt',
  ];
  for (final name in names) {
    final file = File('$dir${Platform.pathSeparator}$name');
    try {
      if (file.existsSync()) return file.path;
    } catch (_) {
      // A locked/inaccessible file must not break the page.
    }
  }
  return null;
}

/// Opens [path] with the platform's default handler. Returns false on failure.
Future<bool> openPathWithShell(String path) async {
  try {
    if (Platform.isWindows) {
      // explorer.exe handles both files and directories and returns immediately.
      await Process.run('explorer.exe', <String>[path]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
      return true;
    }
    await Process.run('xdg-open', <String>[path]);
    return true;
  } catch (_) {
    return false;
  }
}

/// Diagnostic block copied to the clipboard. No secrets, no full URLs with query parts.
String buildSanitizedDiagnostics(SettingsController controller) {
  final hosts = <String>{};
  for (final profile in controller.profiles) {
    final host = profile.endpointHost.trim();
    if (host.isNotEmpty) hosts.add(host);
  }
  final root = controller.dataRootPath;
  final settingsPath = controller.settingsPath;
  return <String>[
    '$kAppName 脱敏诊断',
    '版本: $kAppVersion',
    'ABI: $kExpectedAbiVersion',
    '端点 host: ${hosts.isEmpty ? '未配置' : hosts.join(', ')}',
    '连接数: ${controller.profiles.length}',
    // The exact source label (env/portable/localAppData/…) lives on the 存储 page; the
    // directory itself is the one fact that is always available here.
    '存储来源: ${root.isEmpty ? '内存（不持久化）' : root}',
    '设置文件: ${settingsPath.isEmpty ? '尚未生成' : settingsPath}',
    '原生设置: ${controller.bridgeAvailable ? '可用' : '不可用'}',
    '说明: 不含 API Key、不含密钥、不含完整请求地址与材料内容。',
  ].join('\n');
}

String _licenseText() => <String>[
      '$kAppName $kAppVersion',
      '本程序采用 MIT License。',
      '第三方组件：cJSON（MIT License）、libcurl（curl License）、'
          'Flutter（BSD-3-Clause）。',
      '完整许可文本见程序目录 licenses/ 文件夹。',
    ].join('\n');

