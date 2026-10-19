// 快捷键动作注册表：同一份定义驱动按键分发、设置页与界面文案。
// 绑定以稳定的按键 id + 修饰键持久化，不保存本地化后的显示文本。
//
// 主要类型：ShortcutScope、CommandDefinition；导出 KeyChord（key_chord.dart）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'key_chord.dart';

export 'key_chord.dart';

enum ShortcutScope { application, composer, list, chart, dialog }

extension KeyChordActivator on KeyChord {
  SingleActivator get activator => SingleActivator(
        LogicalKeyboardKey(keyId),
        control: control,
        shift: shift,
        alt: alt,
        meta: meta,
        includeRepeats: false,
      );
}

class CommandDefinition {
  final String id;
  final String label;
  final String description;
  final ShortcutScope scope;
  final KeyChord? defaultChord;

  /// Reserved bindings (Esc) can be neither cleared nor remapped.
  final bool fixed;

  CommandDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.scope,
    required this.defaultChord,
    this.fixed = false,
  });
}

/// Stable ids. Do not rename these when changing display text.
abstract final class AppCommands {
  static const send = 'composer.send';
  static const newConversation = 'conversation.new';
  static const openSettings = 'settings.open';
  static const addFile = 'file.add';
  static const closeOverlay = 'dialog.close';
  static const focusComposer = 'composer.focus';
  static const searchConversations = 'conversation.search';
  static const toggleChart = 'chart.toggle';
  static const toggleSidebar = 'sidebar.toggle';
  static const stopAnalysis = 'analysis.stop';

  static final List<CommandDefinition> all = [
    CommandDefinition(
      id: send,
      label: '发送当前输入',
      description: '发送方式选择 Enter 发送时仍可用；输入法合成中不会触发。',
      scope: ShortcutScope.composer,
      defaultChord: KeyChord(LogicalKeyboardKey.enter.keyId, control: true),
    ),
    CommandDefinition(
      id: newConversation,
      label: '新建会话',
      description: '与左侧「新建会话」相同；空会话会被复用。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyN.keyId, control: true),
    ),
    CommandDefinition(
      id: openSettings,
      label: '打开设置',
      description: '打开设置窗口；未保存的模型修改会先询问。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.comma.keyId, control: true),
    ),
    CommandDefinition(
      id: addFile,
      label: '添加材料文件',
      description: '打开系统文件对话框；分析进行中不可用。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyO.keyId, control: true),
    ),
    CommandDefinition(
      id: closeOverlay,
      label: '关闭最上层浮层',
      description: '关闭设置、详情或菜单；保留给 Esc，不能取消或改键。',
      scope: ShortcutScope.dialog,
      defaultChord: KeyChord(LogicalKeyboardKey.escape.keyId),
      fixed: true,
    ),
    CommandDefinition(
      id: focusComposer,
      label: '定位到输入框',
      description: '把焦点移到输入区，不改变草稿。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyL.keyId, control: true),
    ),
    CommandDefinition(
      id: searchConversations,
      label: '搜索会话',
      description: '聚焦会话搜索框，匹配自定义标题与自动标题。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyF.keyId, control: true),
    ),
    CommandDefinition(
      id: toggleChart,
      label: '切换依赖图 / 甘特图',
      description: '只改变视图，不重新生成计划。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyG.keyId, control: true),
    ),
    CommandDefinition(
      id: toggleSidebar,
      label: '展开 / 收起会话栏',
      description: '窄窗口下没有可收起的会话栏。',
      scope: ShortcutScope.application,
      defaultChord: KeyChord(LogicalKeyboardKey.keyB.keyId, control: true),
    ),
    CommandDefinition(
      id: stopAnalysis,
      label: '停止当前分析',
      description: '独立于 Esc；需要确认后会取消原生请求。',
      scope: ShortcutScope.application,
      defaultChord:
          KeyChord(LogicalKeyboardKey.backspace.keyId, control: true, shift: true),
    ),
  ];

  static CommandDefinition? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// True when two scopes can receive the same key in one focus path.
bool scopesOverlap(ShortcutScope a, ShortcutScope b) =>
    a == b ||
    a == ShortcutScope.application ||
    b == ShortcutScope.application ||
    a == ShortcutScope.dialog ||
    b == ShortcutScope.dialog;

/// `overrides` uses nullable values: absent = default, explicit null = unbound.
KeyChord? resolveBinding(
    String id, Map<String, KeyChord?> overrides, KeyChord? defaultValue) {
  return overrides.containsKey(id) ? overrides[id] : defaultValue;
}

/// Returns a readable conflict message, or null. The candidate itself must be included
/// in [all] with the same command id; other commands are compared.
String? findShortcutConflict(
  String commandId,
  KeyChord chord,
  Map<String, KeyChord?> bindings,
) {
  final candidate = AppCommands.byId(commandId);
  if (candidate == null) return null;
  for (final def in AppCommands.all) {
    if (def.id == commandId) continue;
    final other = resolveBinding(def.id, bindings, def.defaultChord);
    if (other == null || other.signature != chord.signature) continue;
    if (scopesOverlap(candidate.scope, def.scope)) {
      return '与「${def.label}」冲突（${other.label}，${_scopeName(def.scope)}）';
    }
  }
  return null;
}

String scopeName(ShortcutScope scope) => _scopeName(scope);

String _scopeName(ShortcutScope scope) => switch (scope) {
      ShortcutScope.application => '全局',
      ShortcutScope.composer => '输入框',
      ShortcutScope.list => '列表',
      ShortcutScope.chart => '图表',
      ShortcutScope.dialog => '弹窗',
    };

/// Rejects chords that would break text editing, IME or the OS.
String? validateChord(KeyChord chord, {required bool fixed}) {
  if (fixed) return '该快捷键固定为 Esc，不能改键或取消';
  final key = LogicalKeyboardKey.findKeyByKeyId(chord.keyId);
  if (key == null) return '无法识别的按键';
  if (key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight) {
    return '请同时按下一个非修饰键';
  }
  if (chord.control && !chord.shift && !chord.alt) {
    final protected = <int>{
      LogicalKeyboardKey.keyC.keyId,
      LogicalKeyboardKey.keyV.keyId,
      LogicalKeyboardKey.keyX.keyId,
      LogicalKeyboardKey.keyA.keyId,
      LogicalKeyboardKey.keyZ.keyId,
      LogicalKeyboardKey.keyY.keyId,
    };
    if (protected.contains(chord.keyId)) {
      return 'Ctrl+C/V/X/A/Z/Y 保留给文本编辑，不能占用';
    }
  }
  return null;
}

