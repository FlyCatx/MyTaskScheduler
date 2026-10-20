// Top title bar of the right pane. Its height comes from AppShell and grows with the
// text scale so it lines up with the sidebar's header without clipping.
//
// Nothing that can wrap lives here: counts are on one small subtitle line, and long
// messages (errors, storage fallback) are rendered by [StatusStrip] inside the content
// area instead.

import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/settings.dart';
import '../state/app_controller.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';
import 'version_diff_dialog.dart';

class SummaryBar extends StatelessWidget {
  final Conversation? conversation;
  final PlanVersion? version;
  final RunState? run;
  final VoidCallback onNewConversation;
  final void Function(String versionId) onSelectVersion;
  final VoidCallback onExportUser;
  final VoidCallback onExportDiag;
  final VoidCallback? onShowMaterials;
  final VoidCallback? onExportAll;

  const SummaryBar({
    super.key,
    required this.conversation,
    required this.version,
    required this.run,
    required this.onNewConversation,
    required this.onSelectVersion,
    required this.onExportUser,
    required this.onExportDiag,
    this.onShowMaterials,
    this.onExportAll,
  });

  @override
  Widget build(BuildContext context) {
    final versions = conversation?.versions ?? const <PlanVersion>[];
    final currentIndex =
        versions.indexWhere((v) => v.id == version?.id);
    final title = version?.displayTitle ??
        (conversation == null || conversation!.messages.isEmpty
            ? '新会话'
            : conversation!.listTitle);

    return Container(
      // 高度由 AppShell 的顶栏 SizedBox 决定（随文字缩放增高），这里不再固定。
      decoration: BoxDecoration(
        color: TsColors.surface,
        border: Border(bottom: BorderSide(color: TsColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.25),
                ),
                const SizedBox(height: 2),
                _subtitle(versions),
              ],
            ),
          ),
          if (run != null) _ThinkingChip(run: run!),
          const SizedBox(width: 8),
          if (versions.length > 1)
            _VersionMenu(
              versions: versions,
              currentId: version?.id,
              onSelect: onSelectVersion,
            ),
          if (currentIndex > 0)
            IconButton(
              key: const Key('version-diff-button'),
              tooltip: '查看与上一版的差异',
              visualDensity: VisualDensity.compact,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => VersionDiffDialog(
                  before: versions[currentIndex - 1],
                  after: versions[currentIndex],
                ),
              ),
              icon: const Icon(Icons.difference_outlined, size: 17),
            ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: '导出',
            enabled: version != null,
            onSelected: (v) {
              if (v == 'txt') onExportUser();
              if (v == 'diag') onExportDiag();
              if (v == 'materials') onShowMaterials?.call();
              if (v == 'all') onExportAll?.call();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: 'txt', child: Text('导出任务计划（TXT）')),
              const PopupMenuItem(
                  value: 'diag', child: Text('导出结构化诊断（JSON，含内部评分）')),
              if (onShowMaterials != null)
                const PopupMenuItem(
                    value: 'materials', child: Text('材料与补充记录')),
              if (onExportAll != null)
                const PopupMenuItem(
                    value: 'all', child: Text('导出全部会话历史（Markdown）')),
            ],
            icon: const Icon(Icons.ios_share, size: 18),
          ),
          IconButton(
            tooltip: '新建会话',
            onPressed: onNewConversation,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
          ),
        ],
      ),
    );
  }

  /// One line: version position + completion counts + pending reviews.
  Widget _subtitle(List<PlanVersion> versions) {
    if (version == null) {
      return Text(
        '还没有计划：粘贴材料或添加文本文件后开始分析',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: TsColors.textFaint),
      );
    }
    final index = versions.indexWhere((v) => v.id == version!.id);
    final done = version!.tasks.where((t) => t.isDone).length;
    final parts = <String>[
      versions.length > 1 ? '第 ${index + 1}/${versions.length} 版' : '当前计划',
      '$done/${version!.tasks.length} 已完成',
      if (version!.reviewNotes.isNotEmpty) '${version!.reviewNotes.length} 项待复核',
      if (version!.removedCompleted.isNotEmpty)
        '${version!.removedCompleted.length} 项上版已完成被移除',
      if (version!.revision > 0) '修订 ${version!.revision}',
    ];
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color: version!.reviewNotes.isEmpty ? TsColors.textFaint : TsColors.pending,
      ),
    );
  }
}

/// Compact "thinking" indicator: elapsed time only — never model reasoning text.
class _ThinkingChip extends StatelessWidget {
  final RunState run;

  const _ThinkingChip({required this.run});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: bezierDecoration(
        color: TsColors.accentSoft,
        radius: 20,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          const SizedBox(width: 7),
          Text(
            run.cancelRequested
                ? '正在停止 · ${run.elapsedText}'
                : '正在思考 · ${run.elapsedText}',
            style: TextStyle(fontSize: 11.5, color: TsColors.accent),
          ),
        ],
      ),
    );
  }
}

class _VersionMenu extends StatelessWidget {
  final List<PlanVersion> versions;
  final String? currentId;
  final void Function(String versionId) onSelect;

  const _VersionMenu({
    required this.versions,
    required this.currentId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final index = versions.indexWhere((v) => v.id == currentId);
    return PopupMenuButton<String>(
      tooltip: '切换历史版本（旧版本只读）',
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (var i = 0; i < versions.length; i++)
          PopupMenuItem(
            value: versions[i].id,
            height: 56,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('版本 ${i + 1}', style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        versions[i].displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Provenance is the one thing a version list otherwise hides: which
                // connection/model produced this plan. Old versions have no source and
                // must say so instead of looking identical to the current one.
                Tooltip(
                  message: versionSourceTooltip(versions[i]),
                  child: Text(
                    versionSourceLabel(versions[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: bezierDecoration(
          radius: 8,
          border: Border.all(color: TsColors.border),
        ),
        child: Row(
          children: [
            Icon(Icons.history, size: 14, color: TsColors.textSecondary),
            const SizedBox(width: 5),
            Text(
              '${index < 0 ? versions.length : index + 1}/${versions.length}',
              style: const TextStyle(fontSize: 11.5),
            ),
            Icon(Icons.expand_more, size: 15, color: TsColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Model provenance of one committed version, for the version-switch menu.
///
/// Versions created before 0.0.4 (or a failed analysis without a `source` block) have
/// no [PlanVersion.modelSource]; showing a made-up name would be worse than saying so.
String versionSourceLabel(PlanVersion version) {
  final source = version.modelSource;
  if (source == null) return '来源未知';
  final thinking = switch (source.thinking) {
    ThinkingMode.enabled => ' · 思考 ${source.reasoningEffort ?? ''}'.trimRight(),
    ThinkingMode.disabled => ' · 思考关闭',
    ThinkingMode.unsupported => '',
  };
  return '模型 ${source.modelId}$thinking';
}

/// Hover text with the connection identity (never a key, never a full URL).
String versionSourceTooltip(PlanVersion version) {
  final source = version.modelSource;
  if (source == null) {
    return '该版本没有记录模型来源（0.0.4 之前的版本，或分析失败未返回来源）';
  }
  final parts = <String>[
    '连接 ${source.profileId}',
    '修订 ${source.profileRevision}',
    source.protocol.label,
    if (source.endpointHost.isNotEmpty) source.endpointHost,
  ];
  return parts.join(' · ');
}

/// 120-second reminder: non-modal, does not interrupt the request, shown once.
class WaitPromptBar extends StatelessWidget {
  final RunState run;
  final VoidCallback onKeepWaiting;
  final VoidCallback onCancel;

  const WaitPromptBar({
    super.key,
    required this.run,
    required this.onKeepWaiting,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: bezierDecoration(
        color: TsColors.pendingSoft,
        radius: 10,
        border: Border.all(color: TsColors.pending.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.hourglass_bottom, size: 16, color: TsColors.pending),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本次请求已等待超过 120 秒，模型尚未返回完整结果。'
              '继续等待不会重新发送请求。',
              style: TextStyle(fontSize: 12, color: TsColors.pending, height: 1.4),
            ),
          ),
          TextButton(
            onPressed: onKeepWaiting,
            child: const Text('继续等待', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: onCancel,
            // Destructive: keeps the red semantic colour instead of the blue button token.
            style: TsButtons.danger(radius: 8),
            child: const Text('取消请求', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Height shared with the sidebar so both title rows line up exactly.
const double kSummaryBarHeight = kTopBarHeight;
