// Bottom composer, modelled on the requested layout:
//
//   ┌───────────────────────────────────────────────────────────┐
//   │ 📄 exp1.txt   📄 notes.md            ← selected files, blue │
//   │ ┌───────────────────────────────────────────────────────┐ │
//   │ │ 多行输入区（固定高度，超出后内部滚动）                    │ │
//   │ └───────────────────────────────────────────────────────┘ │
//   │ (+)                                          快捷键 · (↑)  │
//   └───────────────────────────────────────────────────────────┘
//
// Design notes:
//   * the "+" (add file) sits INSIDE the box at the bottom-left, the send arrow at the
//     bottom-right — both inside the same rounded container as the text;
//   * the text area has a FIXED height (kComposerTextLines lines). Longer text scrolls
//     inside the field instead of growing the composer, so the layout never jumps;
//   * selected files are shown above the text as blue, link-like entries with a file
//     icon (not as grey Material chips), matching the requested reference;
//   * the file picker is the native Windows dialog (ts_bridge_pick_file), not a
//     Flutter-drawn dialog;
//   * no voice entry.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/session.dart';
import '../model/shortcuts.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

/// Fixed number of visible text lines. Kept in one place so the shell can reserve the
/// matching footer height.
const int kComposerTextLines = 4;

/// The bottom band that hosts the composer. Exposed so the shell and the tests can
/// refer to the same element when checking that it lines up with the sidebar footer.
class ComposerBand extends StatelessWidget {
  final Widget child;

  const ComposerBand({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TsColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

class Composer extends StatefulWidget {
  final TextEditingController textController;
  final List<Attachment> attachments;
  final bool running;
  final bool canSend;
  final VoidCallback onSend;
  final Future<void> Function() onAddFile;
  final void Function(String id) onRemoveAttachment;
  final void Function(String text) onDraftChanged;

  /// When true, a plain Enter sends and Shift+Enter inserts a newline.
  /// Ctrl+Enter always sends (kept as the documented default shortcut).
  final bool enterToSend;

  /// Optional current model label + handler. Hidden when [onModelTap] is null.
  final String? modelLabel;
  final VoidCallback? onModelTap;

  /// 0.1.1：加号右侧的时间图标打开与甘特“可用时间”相同的编辑器。
  final VoidCallback? onOpenTimetable;
  final String? timetableSummary;
  final VoidCallback? onRemoveTimetable;

  /// Optional externally owned focus node (so a global "focus composer" action can
  /// request it). When null the composer owns one.
  final FocusNode? focusNode;

  /// When true, [sendChord] is authoritative (including null = user unbound it).
  final bool useCustomBindings;
  final KeyChord? sendChord;

  const Composer({
    super.key,
    required this.textController,
    required this.attachments,
    required this.running,
    required this.canSend,
    required this.onSend,
    required this.onAddFile,
    required this.onRemoveAttachment,
    required this.onDraftChanged,
    this.enterToSend = false,
    this.modelLabel,
    this.onModelTap,
    this.onOpenTimetable,
    this.timetableSummary,
    this.onRemoveTimetable,
    this.focusNode,
    this.useCustomBindings = false,
    this.sendChord,
  });

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final FocusNode _focus = FocusNode(debugLabel: 'composer');
  bool _hovering = false;
  bool _expanded = false;

  FocusNode get _effectiveFocus => widget.focusNode ?? _focus;

  @override
  void dispose() {
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _effectiveFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.running;
    final maxHeight = MediaQuery.of(context).size.height;
    final expandedHeight = (maxHeight * 0.42).clamp(160.0, 420.0);
    final shortcuts = <ShortcutActivator, Intent>{
      if (_expanded)
        const SingleActivator(LogicalKeyboardKey.escape): const _CollapseIntent(),
    };
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.attachments.isNotEmpty) _fileLinks(),
        if (widget.timetableSummary != null) _timetableChip(),
        // Same TextField instance/position in both states; only constraints change.
        SendShortcut(
          controller: widget.textController,
          enterToSend: widget.enterToSend,
          useCustomBinding: widget.useCustomBindings,
          sendChord: widget.sendChord,
          onSend: () {
            if (widget.canSend) widget.onSend();
          },
          child: SizedBox(
            height: _expanded ? expandedHeight : null,
            child: TextField(
              key: const Key('composer-input'),
              controller: widget.textController,
              focusNode: _effectiveFocus,
              minLines: _expanded ? null : kComposerTextLines,
              maxLines: _expanded ? null : kComposerTextLines,
              expands: _expanded,
              onChanged: widget.onDraftChanged,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(
                hintText: '粘贴材料或补充要求…',
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.only(top: 2, bottom: 2),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        _toolbar(enabled),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Shortcuts(
        shortcuts: shortcuts,
        child: Actions(
          actions: <Type, Action<Intent>>{
            _CollapseIntent: CallbackAction<_CollapseIntent>(onInvoke: (_) {
              if (_expanded) _toggleExpanded();
              return null;
            }),
          },
          child: Container(
            decoration: bezierDecoration(
              color: TsColors.surface,
              radius: 16,
              border: Border.all(
                color: _hovering || _effectiveFocus.hasFocus
                    ? const Color(0xFFC9D4E8)
                    : TsColors.border,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: content,
          ),
        ),
      ),
    );
  }

  /// 已提交时间表的摘要标记；点击移除会取消“随本次请求发送”，不删除日程。
  Widget _timetableChip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_outlined, size: 14, color: TsColors.accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              widget.timetableSummary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            key: const Key('composer-timetable-remove'),
            onTap: widget.onRemoveTimetable,
            child: Icon(Icons.close, size: 13, color: TsColors.accent),
          ),
        ],
      ),
    );
  }

  /// Selected files, shown as blue link-style entries above the text.
  Widget _fileLinks() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final a in widget.attachments)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _FileLink(
                  label: a.label,
                  onRemove: () => widget.onRemoveAttachment(a.id),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(bool enabled) {
    final chord = widget.useCustomBindings
        ? widget.sendChord
        : KeyChord(LogicalKeyboardKey.enter.keyId, control: true);
    final sendHint = chord?.label ?? '未绑定组合键';
    final hint = widget.enterToSend
        ? 'Enter 发送 · Shift+Enter 换行 · $sendHint 也可发送'
        : '$sendHint 发送';
    return Row(
      children: [
        Tooltip(
          message: widget.running ? '分析进行中，暂不能添加文件' : '添加材料（TXT / MD / PDF / DOCX / PPTX，系统对话框）',
          child: _IconSquare(
            icon: Icons.add,
            onTap: enabled ? widget.onAddFile : null,
          ),
        ),
        if (widget.onOpenTimetable != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: widget.timetableSummary == null
                ? '编辑可用时间（手动填写 / 手动绘制）'
                : '重新编辑随请求发送的时间表',
            child: _IconSquare(
              icon: Icons.schedule_outlined,
              onTap: enabled ? widget.onOpenTimetable : null,
            ),
          ),
        ],
        const SizedBox(width: 10),
        if (widget.running)
          Text('分析进行中，可继续编辑草稿',
              style: TextStyle(fontSize: 11, color: TsColors.textFaint))
        else
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: TsColors.textFaint),
          ),
        if (widget.onModelTap != null) ...[
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Tooltip(
              message: '为后续请求选择模型（不重新生成计划）',
              child: InkWell(
                customBorder: const BezierRoundedRectangleBorder(radius: 6),
                onTap: widget.onModelTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.memory_outlined,
                          size: 13, color: TsColors.textFaint),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          widget.modelLabel ?? '模型',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 11, color: TsColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        const Spacer(),
        Tooltip(
          message: _expanded ? '收起输入区（Esc）' : '展开输入区',
          child: IconButton(
            key: const Key('composer-expand'),
            visualDensity: VisualDensity.compact,
            onPressed: _toggleExpanded,
            icon: Icon(
              _expanded ? Icons.close_fullscreen : Icons.open_in_full,
              size: 16,
            ),
          ),
        ),
        const SizedBox(width: 2),
        Tooltip(
          message: widget.canSend ? '开始分析' : '先粘贴材料或添加文件',
          child: _SendButton(onTap: widget.canSend ? widget.onSend : null),
        ),
      ],
    );
  }
}

/// Blue, link-styled file entry (icon + name). Clicking the x removes it.
class _FileLink extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _FileLink({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '移除该附件',
      child: InkWell(
        onTap: onRemove,
        customBorder: const BezierRoundedRectangleBorder(radius: 6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.description_outlined,
                  size: 14, color: TsColors.accent),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: TsColors.accent,
                    decoration: TextDecoration.underline,
                    decorationColor: TsColors.accent,
                    decorationStyle: TextDecorationStyle.dotted,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.close, size: 12, color: TsColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconSquare extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _IconSquare({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? TsColors.buttonFill : TsColors.buttonDisabledFill,
      shape: const BezierRoundedRectangleBorder(radius: 9),
      child: InkWell(
        customBorder: const BezierRoundedRectangleBorder(radius: 9),
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 18,
            color: enabled ? TsColors.onButton : TsColors.onButtonDisabled,
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _SendButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      // Same deep blue as every other action button; grey while there is nothing to
      // send, and never clickable in that state.
      color: enabled ? TsColors.buttonFill : TsColors.buttonDisabledFill,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            Icons.arrow_upward,
            size: 18,
            color: enabled ? TsColors.onButton : TsColors.onButtonDisabled,
          ),
        ),
      ),
    );
  }
}

/// Kept so the shell can keep keyboard handling in one place.
class SendShortcut extends StatelessWidget {
  final Widget child;
  final VoidCallback onSend;
  final TextEditingController? controller;

  /// Plain Enter sends when true; otherwise Enter inserts a newline and Ctrl+Enter
  /// sends (the documented default).
  final bool enterToSend;

  /// 0.05: user-configurable Ctrl+Enter replacement; null with [useCustomBinding]
  /// true means "unbound".
  final bool useCustomBinding;
  final KeyChord? sendChord;

  const SendShortcut({
    super.key,
    required this.child,
    required this.onSend,
    this.controller,
    this.enterToSend = false,
    this.useCustomBinding = false,
    this.sendChord,
  });

  bool _composing() {
    final value = controller?.value;
    if (value == null) return false;
    // While an IME is composing (Chinese/Japanese input), Enter commits the candidate
    // rather than sending; treating it as "send" would submit half-finished text.
    return value.composing.isValid && !value.composing.isCollapsed;
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      if (useCustomBinding ? sendChord != null : true)
        (useCustomBinding
                ? sendChord!.activator
                : const SingleActivator(LogicalKeyboardKey.enter,
                    control: true)):
            const _SendIntent(),
      if (enterToSend)
        const SingleActivator(LogicalKeyboardKey.enter): const _SendIntent(),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
            if (_composing()) return null;
            onSend();
            return null;
          }),
        },
        child: child,
      ),
    );
  }
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _CollapseIntent extends Intent {
  const _CollapseIntent();
}
