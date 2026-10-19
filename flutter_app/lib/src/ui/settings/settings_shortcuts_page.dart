// 快捷键页：可录制、清除与恢复默认的按键绑定，复用按键分发用的同一份注册表。
// 绑定随设置草稿保存（稳定按键 id + 修饰键）；Esc 固定不可改。
//
// 主要类型：SettingsShortcutsPage、_ShortcutRecorderDialog。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/shortcuts.dart';
import '../../state/settings_controller.dart';
import '../widgets/bezier_ui.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class SettingsShortcutsPage extends StatefulWidget {
  final SettingsController controller;

  const SettingsShortcutsPage({super.key, required this.controller});

  @override
  State<SettingsShortcutsPage> createState() => _SettingsShortcutsPageState();
}

class _SettingsShortcutsPageState extends State<SettingsShortcutsPage> {
  String _query = '';
  String? _error;

  SettingsController get c => widget.controller;

  KeyChord? _binding(CommandDefinition def) =>
      c.shortcutFor(def);

  Map<String, KeyChord?> get _overrides =>
      Map<String, KeyChord?>.from(c.draft.prefs.shortcutOverrides);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final q = _query.trim().toLowerCase();
        final filtered = AppCommands.all.where((def) {
          if (q.isEmpty) return true;
          final chord = _binding(def);
          return def.label.toLowerCase().contains(q) ||
              def.description.toLowerCase().contains(q) ||
              scopeName(def.scope).contains(q) ||
              (chord?.label.toLowerCase().contains(q) ?? false);
        }).toList(growable: false);
        final groups = <ShortcutScope, List<CommandDefinition>>{};
        for (final def in filtered) {
          groups.putIfAbsent(def.scope, () => []).add(def);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('shortcut-search'),
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索动作、作用域或按键',
                prefixIcon: Icon(Icons.search,
                    size: 16, color: TsColors.textFaint),
                filled: true,
                fillColor: TsColors.surface,
                border: BezierInputBorder(
                    radius: 8,
                    borderSide: BorderSide(color: TsColors.border)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              _errorBox(_error!),
            ],
            for (final entry in groups.entries) ...[
              const SizedBox(height: 14),
              SettingsGroupLabel(scopeName(entry.key)),
              SettingsCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < entry.value.length; i++) ...[
                      if (i > 0) const SettingsCardDivider(),
                      _row(entry.value[i]),
                    ],
                  ],
                ),
              ),
            ],
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('没有匹配的快捷键',
                      style:
                          TextStyle(fontSize: 12, color: TsColors.textFaint)),
                ),
              ),
            const SizedBox(height: TsSizes.gapBetweenGroups),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: TsSizes.compactButtonHeight,
                child: FilledButton.icon(
                  key: const Key('shortcuts-reset-all'),
                  onPressed: _resetAll,
                  style: TsButtons.solid(
                    minimumSize:
                        const Size(0, TsSizes.compactButtonHeight),
                    fontSize: 12,
                  ),
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('全部恢复默认'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // One real constraint stays: some chords are reserved. This is a limitation
            // the user must know, not a tutorial paragraph.
            const SettingsNote(
              icon: Icons.block_outlined,
              text: 'Esc 固定用于关闭最上层浮层；Ctrl+C / V / X / A / Z / Y 保留给文本编辑。',
            ),
          ],
        );
      },
    );
  }

  Widget _row(CommandDefinition def) {
    final chord = _binding(def);
    final overridden = c.draft.prefs.shortcutOverrides.containsKey(def.id);
    final actions = <Widget>[
      if (!def.fixed) ...[
        _rowButton(
          key: Key('shortcut-record-${def.id}'),
          label: '录制',
          onTap: () => _record(def),
          solid: true,
        ),
        if (chord != null)
          _rowButton(
            key: Key('shortcut-clear-${def.id}'),
            label: '清除',
            onTap: () => _clear(def),
          ),
        if (overridden)
          _rowButton(
            key: Key('shortcut-reset-${def.id}'),
            label: '默认',
            onTap: () => _reset(def),
          ),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 128,
            child: Align(
              alignment: Alignment.centerLeft,
              child: chord == null
                  ? Text('未绑定',
                      style: TextStyle(
                          fontSize: 11.5, color: TsColors.textFaint))
                  : SettingsKeyChip(chord.label),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(def.label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: TsColors.textPrimary)),
                ),
                if (def.fixed) ...[
                  const SizedBox(width: 6),
                  Text('固定',
                      style:
                          TextStyle(fontSize: 10, color: TsColors.textFaint)),
                ],
                if (overridden && !def.fixed) ...[
                  const SizedBox(width: 6),
                  Text('已自定义',
                      style: TextStyle(fontSize: 10, color: TsColors.accent)),
                ],
              ],
            ),
          ),
          // A real gap between the row's right edge and the first button, plus 8 px
          // between each pair — 0.06 packed 录制/清除/默认 flush together.
          const SizedBox(width: TsSizes.gapInGroup),
          Wrap(
            spacing: TsSizes.gapInGroup,
            runSpacing: TsSizes.gapInGroup,
            alignment: WrapAlignment.end,
            children: actions,
          ),
        ],
      ),
    );
  }

  /// One compact row action. 录制 is a solid action; 清除 / 默认 are secondary but get
  /// the same height and radius so the three never look like differently-sized bricks.
  Widget _rowButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
    bool solid = false,
  }) {
    return SizedBox(
      height: TsSizes.inlineHeight,
      child: TextButton(
        key: key,
        onPressed: onTap,
        style: solid
            ? TsButtons.solid(
                radius: 7,
                minimumSize: const Size(0, TsSizes.inlineHeight),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                fontSize: 11.5,
              )
            : TsButtons.outline(
                radius: 7,
                height: TsSizes.inlineHeight,
                fontSize: 11.5,
              ),
        child: Center(child: Text(label)),
      ),
    );
  }

  Widget _errorBox(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: bezierDecoration(
          color: TsColors.blockedSoft,
          radius: 8,
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5, height: 1.45, color: TsColors.blocked)),
      );

  void _clear(CommandDefinition def) {
    final next = _overrides..[def.id] = null;
    c.updateDraftShortcuts(next);
    setState(() => _error = null);
  }

  void _reset(CommandDefinition def) {
    final next = _overrides..remove(def.id);
    c.updateDraftShortcuts(next);
    setState(() => _error = null);
  }

  void _resetAll() {
    c.updateDraftShortcuts(const <String, KeyChord?>{});
    setState(() => _error = null);
  }

  Future<void> _record(CommandDefinition def) async {
    final chord = await showDialog<KeyChord>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ShortcutRecorderDialog(def: def, current: _binding(def)),
    );
    if (chord == null) return;
    final validation = validateChord(chord, fixed: def.fixed);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    final candidate = _overrides..[def.id] = chord;
    final conflict = findShortcutConflict(def.id, chord, candidate);
    if (conflict != null) {
      setState(() => _error = '「${def.label}」不能用 ${chord.label}：$conflict');
      return;
    }
    c.updateDraftShortcuts(candidate);
    setState(() => _error = null);
  }
}

class _ShortcutRecorderDialog extends StatefulWidget {
  final CommandDefinition def;
  final KeyChord? current;

  const _ShortcutRecorderDialog({required this.def, this.current});

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'shortcut-recorder');
  KeyChord? _recorded;
  String? _hint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chord = _recorded;
    return AlertDialog(
      title: Text('录制：${widget.def.label}',
          style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 400,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.escape) {
              Navigator.of(context).pop();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.controlLeft ||
                key == LogicalKeyboardKey.controlRight ||
                key == LogicalKeyboardKey.shiftLeft ||
                key == LogicalKeyboardKey.shiftRight ||
                key == LogicalKeyboardKey.altLeft ||
                key == LogicalKeyboardKey.altRight ||
                key == LogicalKeyboardKey.metaLeft ||
                key == LogicalKeyboardKey.metaRight) {
              return KeyEventResult.handled;
            }
            final pressed = HardwareKeyboard.instance.logicalKeysPressed;
            final next = KeyChord(
              key.keyId,
              control: pressed.contains(LogicalKeyboardKey.controlLeft) ||
                  pressed.contains(LogicalKeyboardKey.controlRight),
              shift: pressed.contains(LogicalKeyboardKey.shiftLeft) ||
                  pressed.contains(LogicalKeyboardKey.shiftRight),
              alt: pressed.contains(LogicalKeyboardKey.altLeft) ||
                  pressed.contains(LogicalKeyboardKey.altRight),
              meta: pressed.contains(LogicalKeyboardKey.metaLeft) ||
                  pressed.contains(LogicalKeyboardKey.metaRight),
            );
            setState(() {
              _recorded = next;
              _hint = validateChord(next, fixed: false);
            });
            return KeyEventResult.handled;
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('按下新的组合键。按 Esc 取消录制。',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: bezierDecoration(
                    color: TsColors.surfaceAlt,
                    radius: 10,
                    border: Border.all(color: TsColors.border),
                  ),
                  child: Text(
                    chord?.label ?? '等待按键…',
                    key: const Key('shortcut-recorder-value'),
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: chord == null
                            ? TsColors.textFaint
                            : TsColors.textPrimary),
                  ),
                ),
              ),
              if (_hint != null) ...[
                const SizedBox(height: 12),
                Text(_hint!,
                    style: TextStyle(
                        fontSize: 11.5, color: TsColors.blocked)),
              ],
              const SizedBox(height: 10),
              Text('当前：${widget.current?.label ?? '未绑定'}',
                  style:
                      TextStyle(fontSize: 11, color: TsColors.textFaint)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消录制')),
        FilledButton(
          key: const Key('shortcut-recorder-save'),
          onPressed: chord == null
              ? null
              : () => Navigator.of(context).pop(chord),
          child: const Text('使用此组合'),
        ),
      ],
    );
  }
}

