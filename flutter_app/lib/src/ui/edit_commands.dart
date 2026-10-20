// 编辑命令的抽象与“打开菜单前捕获目标”的会话对象。
//
// 设计要点：
//   * 菜单打开前确定目标（文本输入框 / 时间表网格），菜单展开后不再从
//     FocusManager.primaryFocus 重新取——那时焦点已经属于菜单；
//   * 能力（canExecute）决定菜单项的启用状态；不支持的命令明确禁用，
//     不伪装成功；
//   * 文本命令走 Flutter 的 Intent/Action 路由（与键盘快捷键同一条命令
//     链），不向任意控件硬发按键事件。
//
// 主要类型：EditCommand、EditTarget、EditMenuSession、EditTargetRegistry、
// captureEditTarget、TextEditTarget。

import 'package:flutter/material.dart';

/// UndoHistoryState 没有公开的静态查找入口；这里只读取它的 canUndo/canRedo，
/// 不修改撤销栈。Flutter 把该类标记为 visibleForTesting，因此对这两处查找
/// 单独压制该诊断，而不用自己的撤销栈去猜测文本编辑器的状态。
// ignore: invalid_use_of_visible_for_testing_member
typedef _TextUndoHistory = UndoHistoryState<TextEditingValue>;

/// 标题栏“编辑”菜单支持的命令。
enum EditCommand { undo, redo, cut, copy, paste, delete, selectAll }

/// 一个可接收编辑命令的目标。
abstract interface class EditTarget {
  bool get isAlive;

  bool canExecute(EditCommand command);

  Future<void> execute(EditCommand command);
}

/// 菜单打开前捕获的目标快照；菜单项与快捷键共用同一路由。
class EditMenuSession {
  EditMenuSession(this.target);

  final EditTarget? target;

  bool enabled(EditCommand command) =>
      target != null && target!.isAlive && target!.canExecute(command);

  Future<void> invoke(EditCommand command) async {
    if (!enabled(command)) return;
    await target!.execute(command);
  }
}

/// 非文本目标（例如时间表网格）注册自己，供标题栏在焦点位于其上时取用。
class EditTargetRegistry {
  static EditTarget? _active;

  static EditTarget? get active => _active;

  static void setActive(EditTarget? target) {
    _active = target;
  }

  static void clear(EditTarget target) {
    if (identical(_active, target)) _active = null;
  }
}

/// 在菜单打开前调用：优先当前焦点所在的文本输入框，其次已注册的非文本目标。
EditTarget? captureEditTarget() {
  final focus = FocusManager.instance.primaryFocus;
  final text = TextEditTarget.fromFocus(focus);
  if (text != null) return text;
  final registered = EditTargetRegistry.active;
  if (registered != null && registered.isAlive) return registered;
  return null;
}

/// 文本输入框的编辑目标。所有命令都通过 Flutter 的 Actions 路由执行，
/// 因此撤销栈、选区和只读限制与键盘快捷键完全一致。
class TextEditTarget implements EditTarget {
  TextEditTarget._(this._state, this._dispatchContext, this._undoHistory);

  final EditableTextState _state;

  /// 焦点节点的 context：位于 EditableText 的 Actions 之下，命令从这里向上查找，
  /// 才能命中与键盘快捷键相同的 Action；用 EditableText 自身 context 会找不到。
  final BuildContext _dispatchContext;
  final _TextUndoHistory? _undoHistory;

  static EditTarget? fromFocus(FocusNode? node) {
    final context = node?.context;
    if (context == null) return null;
    final state = context.findAncestorStateOfType<EditableTextState>();
    if (state == null) return null;
    return TextEditTarget._(
      state,
      context,
      context.findAncestorStateOfType<_TextUndoHistory>(),
    );
  }

  @override
  bool get isAlive => _state.mounted;

  TextEditingValue get _value => _state.textEditingValue;

  bool get _readOnly => _state.widget.readOnly;

  bool get _hasSelection =>
      _value.selection.isValid && !_value.selection.isCollapsed;

  @override
  bool canExecute(EditCommand command) => switch (command) {
        EditCommand.undo => _undoHistory?.canUndo ?? false,
        EditCommand.redo => _undoHistory?.canRedo ?? false,
        EditCommand.cut => !_readOnly && _hasSelection,
        EditCommand.copy => _hasSelection,
        EditCommand.paste => !_readOnly,
        EditCommand.delete => !_readOnly && _value.text.isNotEmpty,
        EditCommand.selectAll => _value.text.isNotEmpty,
      };

  @override
  Future<void> execute(EditCommand command) async {
    final cause = SelectionChangedCause.keyboard;
    final Intent intent = switch (command) {
      EditCommand.undo => UndoTextIntent(cause),
      EditCommand.redo => RedoTextIntent(cause),
      EditCommand.cut => CopySelectionTextIntent.cut(cause),
      EditCommand.copy => CopySelectionTextIntent.copy,
      EditCommand.paste => PasteTextIntent(cause),
      EditCommand.delete => const DeleteCharacterIntent(forward: true),
      EditCommand.selectAll => SelectAllTextIntent(cause),
    };
    Actions.maybeInvoke(_dispatchContext, intent);
  }
}
