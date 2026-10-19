// Per-conversation model selection.
//
// Product rule: switching the model does NOT generate a new plan. The next supplement
// request uses the new selection; the existing versions (and their completion state)
// stay untouched. A new conversation starts from the global default.

import 'package:flutter/material.dart';

import '../model/settings.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

/// Human label for the composer/status line. Never invents a model name: when the
/// selection (or the profile behind it) is unknown, the caller is told so explicitly.
String modelSelectionLabel(
    List<ProviderProfile> profiles, ModelSelection? selection) {
  if (selection == null) return '跟随全局默认';
  final profile = profiles.where((p) => p.id == selection.profileId).firstOrNull;
  final name = profile?.name ?? '配置已删除';
  final thinking = switch (selection.thinking) {
    ThinkingMode.enabled => ' · 思考 ${selection.reasoningEffort ?? ''}'.trimRight(),
    ThinkingMode.disabled => ' · 思考关闭',
    ThinkingMode.unsupported => '',
  };
  return '$name · ${selection.modelId}$thinking';
}

/// Result of the selection dialog: either an explicit selection, or "follow the global
/// default" (which is stored as `null` on the conversation).
class ModelSelectionChoice {
  final bool followDefault;
  final ModelSelection? selection;

  const ModelSelectionChoice.followDefault()
      : followDefault = true,
        selection = null;

  const ModelSelectionChoice.select(ModelSelection this.selection)
      : followDefault = false;
}

Future<ModelSelectionChoice?> showModelSelectionDialog(
  BuildContext context, {
  required List<ProviderProfile> profiles,
  required ModelSelection? current,
  required ModelSelection? globalDefault,
}) {
  return showDialog<ModelSelectionChoice?>(
    context: context,
    builder: (_) => _ModelSelectionDialog(
      profiles: profiles,
      current: current,
      globalDefault: globalDefault,
    ),
  );
}

class _ModelSelectionDialog extends StatefulWidget {
  final List<ProviderProfile> profiles;
  final ModelSelection? current;
  final ModelSelection? globalDefault;

  const _ModelSelectionDialog({
    required this.profiles,
    required this.current,
    required this.globalDefault,
  });

  @override
  State<_ModelSelectionDialog> createState() => _ModelSelectionDialogState();
}

class _ModelSelectionDialogState extends State<_ModelSelectionDialog> {
  late ProviderProfile? _profile;
  late final TextEditingController _model;
  late ThinkingMode _thinking;
  late String? _effort;

  @override
  void initState() {
    super.initState();
    final seed = widget.current ??
        (widget.globalDefault != null &&
                widget.profiles.any((p) => p.id == widget.globalDefault!.profileId)
            ? widget.globalDefault
            : null);
    _profile = seed == null
        ? (widget.profiles.isEmpty ? null : widget.profiles.first)
        : widget.profiles.where((p) => p.id == seed.profileId).firstOrNull;
    _model = TextEditingController(
        text: seed?.modelId.isNotEmpty == true
            ? seed!.modelId
            : (_profile?.modelId ?? ''));
    _thinking = seed?.thinking ??
        (_profile?.protocol == ProviderProtocol.deepseekChat
            ? _profile!.thinking
            : ThinkingMode.unsupported);
    _effort = seed?.reasoningEffort ?? _profile?.reasoningEffort;
    _normalizeThinking();
  }

  void _normalizeThinking() {
    final profile = _profile;
    if (profile == null) return;
    if (profile.protocol != ProviderProtocol.deepseekChat) {
      _thinking = ThinkingMode.unsupported;
      _effort = null;
      return;
    }
    if (_thinking == ThinkingMode.unsupported) {
      _thinking = profile.thinking == ThinkingMode.unsupported
          ? ThinkingMode.disabled
          : profile.thinking;
    }
    if (_thinking == ThinkingMode.enabled) {
      _effort = const {'low', 'high', 'max'}.contains(_effort)
          ? _effort
          : (profile.reasoningEffort ?? 'high');
    } else {
      _effort = null;
    }
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canUse = _profile != null && _model.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('后续请求使用的模型', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '切换只影响之后的请求，不会重新生成计划；已有版本与完成状态保持不变。',
              style: TextStyle(fontSize: 11.5, color: TsColors.textFaint, height: 1.5),
            ),
            const SizedBox(height: 14),
            if (widget.profiles.isEmpty)
              Text('还没有模型连接。请到 设置 → 模型 添加连接并选择模型。',
                  style: TextStyle(fontSize: 12, color: TsColors.pending))
            else ...[
              DropdownButtonFormField<String>(
                initialValue: _profile?.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '连接'),
                items: [
                  for (final p in widget.profiles)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text('${p.name}（修订 ${p.revision}）',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) {
                  setState(() {
                    _profile =
                        widget.profiles.where((p) => p.id == id).firstOrNull;
                    if (_profile != null) {
                      if (_model.text.trim().isEmpty) {
                        _model.text = _profile!.modelId;
                      }
                      _thinking = _profile!.thinking;
                      _effort = _profile!.reasoningEffort;
                      _normalizeThinking();
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '模型 ID',
                  hintText: '例如 deepseek-chat；以连接页面的模型列表为准',
                ),
              ),
              if (_profile?.protocol == ProviderProtocol.deepseekChat) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('思考模式', style: TextStyle(fontSize: 12.5)),
                  subtitle: Text('关闭时请求显式发送 thinking.type=disabled',
                      style: TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
                  value: _thinking == ThinkingMode.enabled,
                  onChanged: (on) {
                    setState(() {
                      _thinking =
                          on ? ThinkingMode.enabled : ThinkingMode.disabled;
                      _normalizeThinking();
                    });
                  },
                ),
                if (_thinking == ThinkingMode.enabled)
                  BezierSegments(
                    height: 28,
                    items: const [
                      BezierSegmentItem('low'),
                      BezierSegmentItem('high'),
                      BezierSegmentItem('max'),
                    ],
                    selected: switch (_effort ?? 'high') {
                      'low' => 0,
                      'high' => 1,
                      _ => 2,
                    },
                    onChanged: (index) => setState(
                      () => _effort = switch (index) {
                        0 => 'low',
                        1 => 'high',
                        _ => 'max',
                      },
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(context)
                    .pop(const ModelSelectionChoice.followDefault()),
                child: const Text('跟随全局默认', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canUse
              ? () {
                  final profile = _profile!;
                  final selection = ModelSelection(
                    profileId: profile.id,
                    profileRevision: profile.revision,
                    modelId: _model.text.trim(),
                    thinking: profile.protocol == ProviderProtocol.deepseekChat
                        ? _thinking
                        : ThinkingMode.unsupported,
                    reasoningEffort:
                        _thinking == ThinkingMode.enabled ? _effort : null,
                  );
                  Navigator.of(context)
                      .pop(ModelSelectionChoice.select(selection));
                }
              : null,
          child: const Text('使用此模型'),
        ),
      ],
    );
  }
}

