// 附件导入反馈的两种展示（任务 02）。
//
// 为什么单独成文件：附件反馈来自应用层（文件选择 / 批量添加 / 大小限制），但
// 「侧栏内通知」与「侧栏收起时的紧凑提示」只应该是纯展示控件。
//   * 只接收 [AttachmentFeedback] 纯数据，不 import AppController、不联网、
//     不弹 SnackBar、不自己起计时器消失（是否消失由用户关闭或应用层控制）；
//   * 侧栏版本放在会话列表下、账号入口上；紧凑版放在工作区内（由调用方用
//     Positioned 避开编辑器与输入工具），两者使用同一份数据、同一份关闭/详情回调；
//   * 失败文件名与短原因换行显示，默认最多 2 条，其余通过“查看全部”交给应用层
//     打开完整诊断；`onShowDetails == null` 时不显示详情入口。

import 'package:flutter/material.dart';

import '../theme.dart';
import 'bezier_ui.dart';

/// 行内文字动作的样式 + 显式应用字体。
///
/// `ButtonStyle.textStyle` 会整体替换主题排版样式，只写 fontSize 时字体族为 null，
/// 在没有系统字体的渲染环境（截图/测试）里会退回方块字体。
ButtonStyle _linkStyle(double fontSize) {
  return TsButtons.link(fontSize: fontSize).copyWith(
    textStyle: WidgetStatePropertyAll<TextStyle>(
      TextStyle(
        fontFamily: kUiFontFamily,
        fontFamilyFallback: kUiFontFallback,
        fontSize: fontSize,
      ),
    ),
  );
}

/// 一次附件导入的结果快照（应用层组装后传入；UI 层不依赖控制器）。
class AttachmentFeedback {
  const AttachmentFeedback({
    required this.conversationId,
    required this.at,
    this.added = 0,
    this.failed = 0,
    this.failures = const <String>[],
    this.note,
  });

  /// 反馈所属会话；切到别的会话时不应当继续显示上一会话的成功回执。
  final String conversationId;

  /// 本次成功加入的附件数。
  final int added;

  /// 本次失败的附件数。
  final int failed;

  /// 每条形如 `文件名：原因`，可直接展示；长文本允许换行。
  final List<String> failures;

  /// 附加说明，例如“文本超过单次请求上限，发送时使用分块分析”。
  final String? note;

  final DateTime at;

  bool get isEmpty => added == 0 && failed == 0 && note == null;

  bool get hasFailure => failed > 0 || failures.isNotEmpty;

  /// 一行摘要（应用级通知宿主也把它作为主文案/去重依据）。
  String get summaryLabel {
    if (added > 0 && failed > 0) {
      return '附件：成功 $added 个，失败 $failed 个';
    }
    if (failed > 0) {
      return '有 $failed 个附件未加入';
    }
    if (added > 0) {
      return '已添加 $added 个文件';
    }
    return '附件提示';
  }
}

/// 侧栏内附件反馈区（会话列表下、账号入口上）。
class AttachmentNotice extends StatelessWidget {
  final AttachmentFeedback feedback;
  final VoidCallback onDismiss;
  final VoidCallback? onShowDetails;

  /// 默认最多展示的失败条数；其余通过 [onShowDetails] 查看。
  static const int maxVisibleFailures = 2;

  const AttachmentNotice({
    super.key,
    required this.feedback,
    required this.onDismiss,
    this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    if (feedback.isEmpty) return const SizedBox.shrink();

    final failed = feedback.hasFailure;
    final warned = !failed && feedback.note != null;
    final accent = failed
        ? TsColors.blocked
        : warned
            ? TsColors.pending
            : TsColors.ready;
    final background = failed
        ? TsColors.blockedSoft
        : warned
            ? TsColors.pendingSoft
            : TsColors.readySoft;
    final icon = failed
        ? Icons.error_outline
        : warned
            ? Icons.info_outline
            : Icons.check_circle_outline;

    final visibleFailures =
        feedback.failures.take(maxVisibleFailures).toList(growable: false);
    final hiddenFailures = feedback.failures.length - visibleFailures.length;
    final showDetails = onShowDetails != null && feedback.failures.isNotEmpty;
    final detailsLabel = hiddenFailures > 0
        ? '查看全部 ${feedback.failures.length} 条失败'
        : '查看详情';

    return Padding(
      // 侧栏宽度由外层决定：这里不设固定宽度，长文件名/原因按可用宽度换行。
      key: const Key('attachment-notice'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: bezierDecoration(
          color: background,
          radius: 9,
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 15, color: accent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _summaryLabel(feedback),
                        key: const Key('attachment-notice-summary'),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: accent,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('attachment-notice-dismiss'),
                  tooltip: '关闭附件提示',
                  onPressed: onDismiss,
                  visualDensity: VisualDensity.compact,
                  style: TsButtons.ghost(),
                  icon: Icon(Icons.close, size: 14, color: accent),
                ),
              ],
            ),
            for (var i = 0; i < visibleFailures.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: Container(
                  key: Key('attachment-notice-failure-$i'),
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: bezierDecoration(
                    color: TsColors.surface,
                    radius: 6,
                    border: Border.all(
                      color: TsColors.blocked.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Text(
                    visibleFailures[i],
                    // 文件名 + 短原因可换行；完整诊断交给“查看全部/查看详情”。
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: TsColors.textSecondary,
                    ),
                  ),
                ),
              ),
            if (showDetails)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 6),
                child: TextButton(
                  key: const Key('attachment-notice-details'),
                  onPressed: onShowDetails,
                  style: _linkStyle(10.5),
                  child: Text(detailsLabel),
                ),
              ),
            if (feedback.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: Text(
                  feedback.note!,
                  key: const Key('attachment-notice-note'),
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: TsColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _summaryLabel(AttachmentFeedback feedback) =>
      feedback.summaryLabel;
}

/// 侧栏收起时的紧凑提示：工作区内可见的一行胶囊，避开编辑器/输入工具的位置
/// 由调用方决定；默认不限宽，超过可用宽度时文本省略而不会溢出。
class CompactAttachmentNotice extends StatelessWidget {
  final AttachmentFeedback feedback;
  final VoidCallback onDismiss;
  final VoidCallback? onShowDetails;

  const CompactAttachmentNotice({
    super.key,
    required this.feedback,
    required this.onDismiss,
    this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    if (feedback.isEmpty) return const SizedBox.shrink();

    final failed = feedback.hasFailure;
    final warned = !failed && feedback.note != null;
    final accent = failed
        ? TsColors.blocked
        : warned
            ? TsColors.pending
            : TsColors.ready;
    final background = failed
        ? TsColors.blockedSoft
        : warned
            ? TsColors.pendingSoft
            : TsColors.readySoft;
    final icon = failed
        ? Icons.error_outline
        : warned
            ? Icons.info_outline
            : Icons.check_circle_outline;
    final detailsLabel = feedback.failures.length > AttachmentNotice.maxVisibleFailures
        ? '查看全部'
        : '详情';

    return ConstrainedBox(
      key: const Key('attachment-notice-compact'),
      // 有上限的紧凑宽度：宽工作区不会拉成一条横贯屏幕的横幅。
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        color: background,
        elevation: 2,
        shadowColor: TsColors.textPrimary.withValues(alpha: 0.18),
        shape: BezierRoundedRectangleBorder(
          side: BorderSide(color: accent.withValues(alpha: 0.35)),
          radius: 9,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: accent),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _compactLabel(feedback),
                      key: const Key('attachment-notice-compact-summary'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                    if (feedback.failures.isNotEmpty)
                      Text(
                        feedback.failures.first,
                        key: const Key('attachment-notice-compact-failure'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: TsColors.textSecondary,
                        ),
                      )
                    else if (feedback.note != null)
                      // 没有失败时把可执行说明（如“发送时用分块分析”）留在紧凑态里，
                      // 单行省略，与失败项同高，不改变胶囊高度。
                      Text(
                        feedback.note!,
                        key: const Key('attachment-notice-compact-note'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: TsColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              if (onShowDetails != null && feedback.failures.isNotEmpty)
                TextButton(
                  key: const Key('attachment-notice-compact-details'),
                  onPressed: onShowDetails,
                  style: _linkStyle(10.5),
                  child: Text(detailsLabel),
                ),
              IconButton(
                key: const Key('attachment-notice-compact-dismiss'),
                tooltip: '关闭附件提示',
                onPressed: onDismiss,
                visualDensity: VisualDensity.compact,
                style: TsButtons.ghost(),
                icon: Icon(Icons.close, size: 14, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _compactLabel(AttachmentFeedback feedback) {
    if (feedback.added > 0 && feedback.failed > 0) {
      return '附件 成功 ${feedback.added} · 失败 ${feedback.failed}';
    }
    if (feedback.failed > 0) {
      return '有 ${feedback.failed} 个附件未加入';
    }
    if (feedback.added > 0) {
      return '已添加 ${feedback.added} 个文件';
    }
    return '附件提示';
  }
}
