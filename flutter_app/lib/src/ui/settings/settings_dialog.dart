// Settings window (0.0.4) — rail + pages + one shared draft.
//
// Behaviour contract (see docs/SETTINGS_0_0_4_SPEC.md §8):
//   * one centred card, `max 980 x 660`; below 900 px wide / 600 px tall the rail narrows
//     and the content pane tightens, so the window stays usable at 1.5x text scale;
//   * the left rail lists 账户安全 / 通用 / 模型 / 快捷键 / 通知 / 存储 / 关于;
//   * every edit is written to `SettingsController.draft` immediately, so switching pages
//     never loses work; only 保存 writes it;
//   * X / Esc / barrier tap closes directly when `controller.dirty` is false, otherwise
//     asks 保存 / 放弃 / 继续编辑;
//   * 保存 shows 正在保存…, disables the buttons, and keeps the dialog open with the
//     reason when the save fails;
//   * the 账户安全 page has nothing to persist, so with no pending edits the footer
//     offers only 关闭 — there is no fake "saved successfully" state.
//
// Page ownership:
//   * account / general / shortcuts / notifications / about are implemented here;
//   * model / storage are implemented by the settings data layer and consumed through the
//     agreed constructors `SettingsModelPage(controller: …)` /
//     `SettingsStoragePage(controller: …)`. Both pages scroll their own content.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../state/settings_controller.dart';
import '../widgets/bezier_ui.dart';
import '../theme.dart';
import 'settings_about_page.dart';
import 'settings_account_page.dart';
import 'settings_general_page.dart';
import 'settings_model_page.dart';
import 'settings_notifications_page.dart';
import 'settings_shortcuts_page.dart';
import 'settings_storage_page.dart';
import 'settings_widgets.dart';

/// The seven categories of the settings rail. Labels and order are part of the product
/// (「账户安全」 keeps its name), so they are not configurable.
enum SettingsSection {
  account('账户安全', Icons.person_outline),
  general('通用', Icons.settings_outlined),
  model('模型', Icons.memory_outlined),
  shortcuts('快捷键', Icons.keyboard_outlined),
  notifications('通知', Icons.notifications_none),
  storage('存储', Icons.folder_outlined),
  about('关于', Icons.info_outline);

  final String label;
  final IconData icon;
  const SettingsSection(this.label, this.icon);
}

/// Opens the settings window.
///
/// The default section is 账户安全 for every generic entry point (user menu, Ctrl+,).
/// Entry points that genuinely mean a specific page still pass an explicit [initial].
Future<void> showSettingsDialog(
  BuildContext context, {
  required SettingsController controller,
  SettingsSection initial = SettingsSection.account,
  String? storageSource,
  bool? storageMemoryOnly,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    // The barrier / Esc route through `maybePop`, which the dialog intercepts with
    // PopScope so unsaved changes can be confirmed instead of silently dropped.
    barrierDismissible: true,
    builder: (_) => SettingsDialog(
      controller: controller,
      initial: initial,
      storageSource: storageSource,
      storageMemoryOnly: storageMemoryOnly,
    ),
  );
}

class SettingsDialog extends StatefulWidget {
  final SettingsController controller;
  final SettingsSection initial;

  /// Authoritative storage facts from `AppController` (`storageSource` /
  /// `!storageIsPersistent`). Optional: the 存储 page falls back to inferring the source
  /// from the data path, which is less precise but never wrong-looking.
  final String? storageSource;
  final bool? storageMemoryOnly;

  const SettingsDialog({
    super.key,
    required this.controller,
    this.initial = SettingsSection.account,
    this.storageSource,
    this.storageMemoryOnly,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsSection _section = widget.initial;

  /// True while `controller.save()` is in flight (the controller also exposes `saving`,
  /// but the local flag covers the gap before the first notification).
  bool _saving = false;

  /// Readable save failure. Shown in the footer; the dialog stays open.
  String? _error;

  /// Guards against re-entrant close requests (barrier + Esc + button while a nested
  /// confirm dialog is already open).
  bool _closing = false;

  SettingsController get c => widget.controller;

  bool get _busy => _saving || c.saving;

  // --------------------------------------------------------------- geometry

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    // Spec §8: a window narrower than 900 or shorter than 600 switches to the compact
    // rail (and tighter insets) instead of squeezing the content pane.
    final compact =
        media.width < kSettingsCompactWidth || media.height < kSettingsCompactHeight;
    final inset = compact ? 10.0 : 48.0;
    // Never exceed the screen: a fixed 980x660 would be clipped on small displays or at
    // 1.5x text scale (which also enlarges the dialog's own padding).
    final width =
        math.min(kSettingsMaxWidth, math.max(320.0, media.width - inset * 2));
    final height =
        math.min(kSettingsMaxHeight, math.max(260.0, media.height - inset * 2));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Dialog(
        backgroundColor: TsColors.surface,
        insetPadding: EdgeInsets.all(inset),
        shape: const BezierRoundedRectangleBorder(radius: 16),
        child: SizedBox(
          width: width,
          height: height,
          child: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _rail(compact),
                Expanded(child: _content(compact)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- left rail

  Widget _rail(bool compact) {
    final width = compact ? kSettingsRailCompactWidth : kSettingsRailWidth;
    final horizontal = compact ? 8.0 : 14.0;
    return ClipPath(
      clipper: const BezierRoundedClipper(16),
      child: Container(
        key: const Key('settings-rail'),
        width: width,
        decoration: ShapeDecoration(
          color: TsColors.sidebar,
          shape: BezierRoundedRectangleBorder(
            side: BorderSide(color: TsColors.border),
            radius: 16,
          ),
        ),
        padding: EdgeInsets.fromLTRB(horizontal, 18, horizontal, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(left: compact ? 4 : 10, bottom: 14),
            child: Text(
              '设置',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.2,
                color: TsColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            // Scrolls only when the window is too short for all seven entries at the
            // current text scale — every entry is still built (no lazy list).
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in SettingsSection.values)
                    _railItem(section, compact),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: compact ? 4 : 10, top: 8),
            child: Text(
              '$kAppName $kAppVersion',
              style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _railItem(SettingsSection section, bool compact) {
    final selected = section == _section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? TsColors.accentSoft : Colors.transparent,
        shape: const BezierRoundedRectangleBorder(radius: 8),
        child: InkWell(
          customBorder: const BezierRoundedRectangleBorder(radius: 8),
          onTap: () => setState(() {
            _section = section;
            _error = null;
          }),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: 9,
            ),
            child: Row(
              children: [
                Icon(
                  section.icon,
                  size: 17,
                  color: selected ? TsColors.accent : TsColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    section.label,
                    // A narrow rail wraps instead of clipping at 1.5x text scale.
                    maxLines: compact ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color:
                          selected ? TsColors.accent : TsColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- content

  Widget _content(bool compact) {
    final pad = compact ? 14.0 : 24.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 10, 6, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TsColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                // The translucent round close button from 0.05 — deliberately not a
                // blue rectangle.
                style: TsButtons.closeIcon(size: 28),
                onPressed: _requestClose,
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        ),
        Expanded(child: _pageArea(compact)),
        _footer(compact),
      ],
    );
  }

  /// Content area.
  ///
  /// The 模型 / 存储 pages come from the settings data layer and bring their own vertical
  /// scroll view (they contain fixed-height inner lists). Wrapping them in a second
  /// scrollable would swallow the mouse wheel — the inner one has no extent but still
  /// consumes the pointer signal — so those two get the dialog's padding only.
  Widget _pageArea(bool compact) {
    final pad = compact ? 14.0 : 24.0;
    final padding = EdgeInsets.fromLTRB(pad, 2, pad, 18);
    if (_section == SettingsSection.model ||
        _section == SettingsSection.storage) {
      return Padding(padding: padding, child: _page());
    }
    return SingleChildScrollView(padding: padding, child: _page());
  }

  Widget _page() {
    return switch (_section) {
      SettingsSection.account => const SettingsAccountPage(),
      SettingsSection.general => SettingsGeneralPage(controller: c),
      SettingsSection.model => SettingsModelPage(controller: c),
      SettingsSection.shortcuts => SettingsShortcutsPage(controller: c),
      SettingsSection.notifications => SettingsNotificationsPage(controller: c),
      SettingsSection.storage => SettingsStoragePage(
          controller: c,
          storageSource: widget.storageSource,
          memoryOnly: widget.storageMemoryOnly,
        ),
      SettingsSection.about => SettingsAboutPage(controller: c),
    };
  }

  // ----------------------------------------------------------------- footer

  /// Fixed footer: 取消 / 应用 / 保存 on **every** page, including 账户安全.
  ///
  /// 应用 is the only difference between 应用 and 保存 (stay vs close): both run the same
  /// validated write through [SettingsController.save], so there is no second, subtly
  /// different "apply" path that could leave the running app on different values than
  /// the file.
  Widget _footer(bool compact) {
    final dirty = c.dirty;
    final saving = _busy;
    final error = _error;

    final String? status = saving
        ? '正在保存…'
        : (error ?? (dirty ? '修改尚未应用' : null));
    final Color statusColor = error != null
        ? TsColors.blocked
        : (saving ? TsColors.textSecondary : TsColors.pending);

    return Container(
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 24,
        10,
        compact ? 14 : 24,
        12,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: TsColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: saving
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          )
                        : Icon(
                            error != null
                                ? Icons.error_outline
                                : Icons.edit_note,
                            size: 14,
                            color: statusColor,
                          ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // All three buttons share one height and one radius. Their labels are centred
          // by the button style itself; a `Center` child would make each button expand
          // to the full row width and break the group.
          SizedBox(
            height: TsSizes.buttonHeight,
            child: TsButtonRow(
              children: [
                TextButton(
                  key: const Key('settings-cancel'),
                  onPressed: saving ? null : _requestClose,
                  style: TsButtons.outline(),
                  child: const Text('取消'),
                ),
                TextButton(
                  key: const Key('settings-apply'),
                  // Nothing to apply → disabled (not a no-op that looks like it worked).
                  onPressed: (!dirty || saving) ? null : _apply,
                  style: TsButtons.solid(),
                  child: Text(saving ? '正在保存…' : '应用'),
                ),
                TextButton(
                  key: const Key('settings-save'),
                  // With no changes 保存 still closes — an untouched 账户安全 page must
                  // never be impossible to leave with the 保存 button.
                  onPressed: saving ? null : _saveAndClose,
                  style: TsButtons.solid(),
                  child: Text(saving ? '正在保存…' : '保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- actions

  /// 应用: persist the whole draft, stay on the current page.
  ///
  /// The controller is the single writer: it validates every pending field, writes the
  /// preference file and the native settings document, updates its baseline and notifies
  /// its listeners — which is what makes a theme / font-size / shortcut change take
  /// effect immediately while this window stays open.
  Future<void> _apply() async {
    final ok = await _save();
    if (!mounted) return;
    if (ok) {
      setState(() {
        _error = null;
      });
    }
  }

  /// Saves the draft and closes the dialog on success. On failure the dialog stays open
  /// and the readable reason is shown in the footer.
  Future<void> _saveAndClose() async {
    final ok = await _save();
    if (!mounted) return;
    if (ok) _pop();
  }

  /// Returns true when the draft was written.
  Future<bool> _save() async {
    if (_busy) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await c.save();
    if (!mounted) return false;
    setState(() {
      _saving = false;
      _error = error;
    });
    return error == null;
  }

  /// X / Esc / barrier tap / 取消. Asks before throwing unsaved edits away.
  Future<void> _requestClose() async {
    if (_closing || _busy) return;
    if (!c.dirty) {
      _pop();
      return;
    }
    _closing = true;
    try {
      final choice = await showDialog<_UnsavedChoice>(
        context: context,
        builder: (_) => const _UnsavedChangesDialog(),
      );
      if (!mounted) return;
      if (choice == _UnsavedChoice.save) {
        final ok = await _save();
        if (!mounted) return;
        if (ok) _pop();
      } else if (choice == _UnsavedChoice.discard) {
        c.discard();
        _pop();
      }
      // null (barrier/Esc) and keepEditing both mean "stay here with the draft intact".
    } finally {
      _closing = false;
    }
  }

  void _pop() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

enum _UnsavedChoice { save, discard, keepEditing }

class _UnsavedChangesDialog extends StatelessWidget {
  const _UnsavedChangesDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('有未保存的修改', style: TextStyle(fontSize: 15)),
      content: const Text(
        '关闭设置窗口前要保存这些修改吗？选择「放弃」会丢弃本次修改，'
        '磁盘上的设置保持原样。',
        style: TextStyle(fontSize: 12.5, height: 1.55),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UnsavedChoice.keepEditing),
          child: const Text('继续编辑'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UnsavedChoice.discard),
          child: const Text('放弃'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_UnsavedChoice.save),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

