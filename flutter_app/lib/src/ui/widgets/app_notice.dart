// 应用内通知显示在窗口左下角，弹出对话框时仍须可见。
// 宿主挂在 MaterialApp.builder，位于 Navigator 和模态路由之上；只有通知卡片
// 接收指针，卡片外仍由下层模态遮罩处理，不能点透到主界面。
// 外层不绘制背景；按钮所需的 Material 使用透明类型。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'attachment_notice.dart' as attachment;
import 'bezier_ui.dart';

/// 行内文字动作样式 + 显式应用字体（宿主位于 Navigator 之外，没有 Material/
/// 主题 DefaultTextStyle 时，按钮文字会退回默认字体/方块）。
ButtonStyle _appLinkStyle(double fontSize) {
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

/// 卡片正文样式：显式字体族，保证宿主不在 Material/DefaultTextStyle 之下时
/// 仍与正文同一种中文字体。
TextStyle _appTextStyle({
  required double fontSize,
  required Color color,
  FontWeight? fontWeight,
  double height = 1.4,
}) {
  return TextStyle(
    fontFamily: kUiFontFamily,
    fontFamilyFallback: kUiFontFallback,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
    color: color,
  );
}

/// 通知种类：决定配色、图标与默认停留时长。
enum AppNoticeKind { success, warning, error, info }

/// 一条通知（不可变快照；控制器替换列表项来更新状态）。
class AppNotice {
  const AppNotice({
    required this.id,
    required this.kind,
    required this.message,
    this.details = const <String>[],
    this.actionLabel,
    this.onAction,
    this.actionValidFor,
    this.autoDismiss,
    this.dismissible = true,
    this.dedupeKey,
    this.conversationId,
    this.attachmentFeedback,
    this.onDismiss,
    this.onShowDetails,
    this.actionExpired = false,
  });

  final int id;
  final AppNoticeKind kind;

  /// 主文案。短成功一次完整显示（不截断）；长路径/文件名允许换行。
  final String message;

  /// 附加逐项内容（例如失败的每个文件：“文件名：原因”）。
  final List<String> details;

  final String? actionLabel;
  final VoidCallback? onAction;

  /// 动作（撤销）的有效期；超时后按钮禁用，避免在新状态上执行旧操作。
  final Duration? actionValidFor;
  final bool actionExpired;

  /// 自动消失时长；null = 需要用户关闭（附件/失败默认如此）。
  final Duration? autoDismiss;

  final bool dismissible;

  /// 去重键：短时间内重复刷新只更新同一条，不再堆叠。
  final String? dedupeKey;

  /// 归属会话；切会话时由 AppShell 调用 [AppNotices.dismissConversation] 清理。
  final String? conversationId;

  /// 附件反馈：非空时复用 [attachment.AttachmentNotice] 的卡片视觉与 key。
  final attachment.AttachmentFeedback? attachmentFeedback;

  /// 关闭/详情回调。附件通知用它回写控制器（用户关闭 = 手动关闭）。
  final VoidCallback? onDismiss;
  final VoidCallback? onShowDetails;

  AppNotice copyWith({
    AppNoticeKind? kind,
    String? message,
    List<String>? details,
    String? actionLabel,
    VoidCallback? onAction,
    bool? actionExpired,
    Duration? autoDismiss,
    bool? dismissible,
    attachment.AttachmentFeedback? attachmentFeedback,
    VoidCallback? onDismiss,
    VoidCallback? onShowDetails,
  }) {
    return AppNotice(
      id: id,
      kind: kind ?? this.kind,
      message: message ?? this.message,
      details: details ?? this.details,
      actionLabel: actionLabel ?? this.actionLabel,
      onAction: onAction ?? this.onAction,
      actionValidFor: actionValidFor,
      autoDismiss: autoDismiss ?? this.autoDismiss,
      dismissible: dismissible ?? this.dismissible,
      dedupeKey: dedupeKey,
      conversationId: conversationId,
      attachmentFeedback: attachmentFeedback ?? this.attachmentFeedback,
      onDismiss: onDismiss ?? this.onDismiss,
      onShowDetails: onShowDetails ?? this.onShowDetails,
      actionExpired: actionExpired ?? this.actionExpired,
    );
  }
}

/// [AppNotices.show] 返回的句柄：可在动作完成后关闭对应通知。
class AppNoticeHandle {
  AppNoticeHandle._(this._owner, this.id);

  final AppNotices _owner;
  final int id;

  bool get isActive => _owner.notices.any((n) => n.id == id);

  void dismiss() => _owner.dismiss(id);
}

/// 全局通知队列（单例）。UI 只通过 [AppNotices.instance] 投递，不持有其他状态。
class AppNotices extends ChangeNotifier {
  AppNotices._();

  static final AppNotices instance = AppNotices._();

  /// 同时展示的最大卡片数；更多时折叠成“另有 N 条通知”，可展开滚动查看。
  static const int maxVisible = 4;

  final List<AppNotice> _items = <AppNotice>[];
  final Map<int, Timer> _autoTimers = <int, Timer>{};
  final Map<int, Timer> _actionTimers = <int, Timer>{};
  int _nextId = 0;

  /// 已挂载的宿主数量。没有宿主时（例如只渲染 ExecutionActions 的组件测试）
  /// 不启动自动关闭/有效期计时器：否则计时器会活过 widget 树，测试里变成
  /// “A Timer is still pending even after the widget tree was disposed”。
  int _hosts = 0;

  bool get hasHost => _hosts > 0;

  void attachHost() {
    _hosts++;
    if (_hosts == 1) {
      for (final notice in _items) {
        _armTimers(notice);
      }
    }
  }

  void detachHost() {
    if (_hosts == 0) return;
    _hosts--;
    if (_hosts == 0) _cancelAllTimers();
  }

  /// 宿主距离窗口底边的距离（由 AppShell 实测底部输入带高度后写入）。
  double _bottomInset = 96;

  List<AppNotice> get notices => List<AppNotice>.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  double get bottomInset => _bottomInset;

  /// 同一条消息是否已经在展示（用于消除“状态条 + 临时通知”双回执）。
  bool isShowingMessage(String message) {
    if (message.trim().isEmpty) return false;
    final text = message.trim();
    for (final notice in _items) {
      if (notice.message.contains(text) ||
          text.contains(notice.message) ||
          notice.details.contains(text)) {
        return true;
      }
    }
    return false;
  }

  void setBottomInset(double value) {
    if (!value.isFinite) return;
    final next = value.clamp(0.0, 4000.0).toDouble();
    if ((next - _bottomInset).abs() < 0.5) return;
    _bottomInset = next;
    notifyListeners();
  }

  /// 投递一条通知；相同 [dedupeKey] 存在时原地更新而不是堆叠。
  AppNoticeHandle show({
    required AppNoticeKind kind,
    required String message,
    List<String> details = const <String>[],
    String? actionLabel,
    VoidCallback? onAction,
    Duration? actionValidFor,
    Duration? autoDismiss,
    bool dismissible = true,
    String? dedupeKey,
    String? conversationId,
    VoidCallback? onDismiss,
    VoidCallback? onShowDetails,
    attachment.AttachmentFeedback? attachmentFeedback,
  }) {
    final text = message.trim();
    final visibleDetails = <String>[
      for (final line in details)
        if (line.trim().isNotEmpty) line.trim(),
    ];

    if (dedupeKey != null) {
      final index = _items.indexWhere((n) => n.dedupeKey == dedupeKey);
      if (index >= 0) {
        final old = _items[index];
        _cancelTimers(old.id);
        _items[index] = AppNotice(
          id: old.id,
          kind: kind,
          message: text,
          details: visibleDetails,
          actionLabel: actionLabel,
          onAction: onAction,
          actionValidFor: actionValidFor,
          autoDismiss: autoDismiss,
          dismissible: dismissible,
          dedupeKey: dedupeKey,
          conversationId: conversationId,
          attachmentFeedback: attachmentFeedback,
          onDismiss: onDismiss,
          onShowDetails: onShowDetails,
        );
        _armTimers(_items[index]);
        notifyListeners();
        return AppNoticeHandle._(this, old.id);      }
    }

    final id = ++_nextId;
    final notice = AppNotice(
      id: id,
      kind: kind,
      message: text,
      details: visibleDetails,
      actionLabel: actionLabel,
      onAction: onAction,
      actionValidFor: actionValidFor,
      autoDismiss: autoDismiss,
      dismissible: dismissible,
      dedupeKey: dedupeKey,
      conversationId: conversationId,
      attachmentFeedback: attachmentFeedback,
      onDismiss: onDismiss,
      onShowDetails: onShowDetails,
    );
    _items.add(notice);
    _armTimers(notice);
    notifyListeners();
    return AppNoticeHandle._(this, id);
  }

  /// 附件反馈：同一批（同一会话、连续刷新）只保留一条，更新计数/失败清单。
  AppNoticeHandle showAttachment({
    required attachment.AttachmentFeedback feedback,
    required VoidCallback onDismiss,
    VoidCallback? onShowDetails,
  }) {
    final kind = feedback.hasFailure
        ? AppNoticeKind.warning
        : AppNoticeKind.success;
    return show(
      kind: kind,
      message: feedback.summaryLabel,
      details: feedback.failures,
      dedupeKey: 'attachment',
      conversationId: feedback.conversationId,
      dismissible: true,
      onDismiss: onDismiss,
      onShowDetails: onShowDetails,
      attachmentFeedback: feedback,
    );
  }

  /// 关闭当前附件通知（控制器已清空反馈时调用，幂等）。
  void dismissAttachment() {
    final target = _items.where((n) => n.dedupeKey == 'attachment').toList();
    for (final notice in target) {
      dismiss(notice.id);
    }
  }

  /// 会话切换：清掉属于旧会话的通知，避免旧动作作用到新会话。
  void dismissConversation(String? conversationId) {
    if (conversationId == null) return;
    final stale = _items
        .where((n) => n.conversationId == conversationId)
        .map((n) => n.id)
        .toList(growable: false);
    for (final id in stale) {
      dismiss(id);
    }
  }

  void dismiss(int id) {
    final index = _items.indexWhere((n) => n.id == id);
    if (index < 0) return;
    _items.removeAt(index);
    _cancelTimers(id);
    notifyListeners();
  }

  /// 清空全部（窗口销毁/测试重置时调用，同时取消计时器）。
  void clear() {
    _cancelAllTimers();
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  /// 清空并恢复默认锚点（新 Shell 接管时调用；会 notify 宿主）。
  void reset() {
    clear();
    _nextId = 0;
    _bottomInset = 96;
  }

  /// 测试专用别名（与 [reset] 等价，语义更明确）。
  void resetForTest() => reset();

  /// 树销毁阶段使用：清空并取消计时器，但不 notify（避免在卸载中触发祖先重建）。
  void resetSilently() {
    _cancelAllTimers();
    _items.clear();
    _nextId = 0;
    _bottomInset = 96;
  }

  void _armTimers(AppNotice notice) {
    if (!hasHost) return;
    if (notice.autoDismiss != null) {
      _autoTimers[notice.id] = Timer(notice.autoDismiss!, () {
        dismiss(notice.id);
      });
    }
    if (notice.actionLabel != null && notice.actionValidFor != null) {
      _actionTimers[notice.id] = Timer(notice.actionValidFor!, () {
        final index = _items.indexWhere((n) => n.id == notice.id);
        if (index < 0) return;
        // 有效期结束：就地禁用撤销按钮，但卡片本身保留（用户仍能读结果并关闭）。
        _items[index] = _items[index].copyWith(actionExpired: true);
        _actionTimers.remove(notice.id);
        notifyListeners();
      });
    }
  }

  void _cancelTimers(int id) {
    _autoTimers.remove(id)?.cancel();
    _actionTimers.remove(id)?.cancel();
  }

  void _cancelAllTimers() {
    for (final timer in _autoTimers.values) {
      timer.cancel();
    }
    for (final timer in _actionTimers.values) {
      timer.cancel();
    }
    _autoTimers.clear();
    _actionTimers.clear();
  }

  @override
  void dispose() {
    _cancelAllTimers();
    super.dispose();
  }
}

/// 生产环境挂载标记：AppShell 在它下面时不再自己挂一份宿主（只渲染一次）。
class AppNoticeMountScope extends InheritedWidget {
  const AppNoticeMountScope({super.key, required this.mounted, required super.child});

  final bool mounted;

  static bool isMounted(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppNoticeMountScope>()
          ?.mounted ??
      false;

  @override
  bool updateShouldNotify(AppNoticeMountScope oldWidget) =>
      oldWidget.mounted != mounted;
}

/// 只渲染一次的通知宿主：`child` 是正常应用树，通知卡片叠在左下角。
class AppNoticeHost extends StatefulWidget {
  const AppNoticeHost({
    super.key,
    required this.child,
    this.controller,
    this.maxCardWidth = 460,
    this.margin = 12,
  });

  final Widget child;
  final AppNotices? controller;
  final double maxCardWidth;
  final double margin;

  @override
  State<AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<AppNoticeHost> {
  AppNotices get _controller => widget.controller ?? AppNotices.instance;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _controller.attachHost();
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant AppNoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget.controller ?? AppNotices.instance;
    if (!identical(oldController, _controller)) {
      oldController.removeListener(_onChanged);
      oldController.detachHost();
      _controller.attachHost();
      _controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.detachHost();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    if (_controller.isEmpty && _expanded) {
      _expanded = false;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final notices = _controller.notices;
    return Stack(
      key: const Key('app-notice-host'),
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (notices.isNotEmpty) _buildOverlay(context, notices),
      ],
    );
  }

  Widget _buildOverlay(BuildContext context, List<AppNotice> notices) {
    final media = MediaQuery.of(context);
    final margin = widget.margin;
    final availableHeight =
        math.max(120.0, media.size.height - _controller.bottomInset - margin - 48);
    Widget content = Positioned(
      left: margin,
      right: margin,
      bottom: _controller.bottomInset,
      // 不画底色：卡片之外必须透出真实界面/模态遮罩。
      child: Align(
        alignment: Alignment.bottomLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(widget.maxCardWidth, media.size.width - margin * 2),
            maxHeight: availableHeight,
          ),
          child: LayoutBuilder(builder: (context, constraints) {
            final visible = _expanded
                ? notices
                : notices.length > AppNotices.maxVisible
                    ? notices.sublist(notices.length - AppNotices.maxVisible)
                    : notices;
            final hidden = notices.length - visible.length;
            return SizedBox(
              width: constraints.maxWidth,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (hidden > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _MoreRow(
                            hidden: hidden,
                            expanded: _expanded,
                            onTap: () => setState(() => _expanded = !_expanded),
                          ),
                        ),
                      if (_expanded && notices.length > AppNotices.maxVisible)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _MoreRow(
                            hidden: 0,
                            expanded: true,
                            onTap: () => setState(() => _expanded = false),
                          ),
                        ),
                      for (final notice in visible)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _NoticeCard(
                            notice: notice,
                            onDismiss: () => _dismiss(notice),
                            onAction: () => _runAction(notice),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
    // 宿主挂在 MaterialApp.builder（Navigator/Overlay 之外）时，没有 Overlay 祖先：
    // 关闭按钮的 Tooltip 会因 “No Overlay widget found” 抛错。此时禁用 Tooltip
    // （按钮本身仍是可聚焦、可点击的 IconButton，语义标签保留）。
    if (Overlay.maybeOf(context) == null) {
      content = TooltipVisibility(visible: false, child: content);
    }
    return content;
  }

  void _dismiss(AppNotice notice) {
    notice.onDismiss?.call();
    _controller.dismiss(notice.id);
  }

  void _runAction(AppNotice notice) {
    if (notice.actionExpired) return;
    final action = notice.onAction;
    if (action == null) return;
    action();
    _controller.dismiss(notice.id);
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.hidden,
    required this.expanded,
    required this.onTap,
  });

  final int hidden;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = expanded
        ? '收起较早通知'
        : hidden > 0
            ? '另有 $hidden 条通知'
            : '收起较早通知';
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        // 只承接按钮的文字动作，不铺任何底色（卡片外必须透出真实界面）。
        type: MaterialType.transparency,
        child: TextButton(
          key: const Key('app-notice-more'),
          onPressed: onTap,
          style: _appLinkStyle(10.5),
          child: Text(label),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.notice,
    required this.onDismiss,
    required this.onAction,
  });

  final AppNotice notice;
  final VoidCallback onDismiss;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final attachmentFeedback = notice.attachmentFeedback;
    if (attachmentFeedback != null) {
      // 附件反馈复用原来的卡片视觉与 key；外层只做圆角裁剪/透明 Material。
      return Material(
        type: MaterialType.transparency,
        child: attachment.AttachmentNotice(
          key: const Key('app-notice-attachment'),
          feedback: attachmentFeedback,
          onDismiss: onDismiss,
          onShowDetails: notice.onShowDetails,
        ),
      );
    }

    final palette = _NoticePalette.of(notice.kind);
    return Material(
      // 透明 Material：只给按钮提供 Material/DefaultTextStyle，不铺任何底色。
      type: MaterialType.transparency,
      child: Container(
      key: Key('app-notice-${notice.id}'),
      padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
      decoration: bezierDecoration(
        color: palette.background,
        radius: 10,
        border: Border.all(color: palette.foreground.withValues(alpha: 0.34)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: TsColors.textPrimary.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(palette.icon, size: 16, color: palette.foreground),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  notice.message,
                  key: const Key('app-notice-message'),
                  // 短成功也要完整显示：不设 maxLines。
                  style: _appTextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.foreground,
                  ),
                ),
                for (var i = 0; i < notice.details.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      notice.details[i],
                      key: Key('app-notice-detail-$i'),
                      // 文件名 + 原因可换行；超长时省略，完整内容在详情/导出里。
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: _appTextStyle(
                        fontSize: 10.5,
                        color: TsColors.textSecondary,
                      ),
                    ),
                  ),
                if (notice.onShowDetails != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton(
                      key: const Key('app-notice-details'),
                      onPressed: notice.onShowDetails,
                      style: _appLinkStyle(10.5),
                      child: const Text('查看详情'),
                    ),
                  ),
                if (notice.actionLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: TextButton(
                      key: const Key('app-notice-action'),
                      onPressed: notice.actionExpired ? null : onAction,
                      style: _appLinkStyle(11.5),
                      child: Text(notice.actionLabel!),
                    ),
                  ),
              ],
            ),
          ),
          if (notice.dismissible)
            IconButton(
              key: const Key('app-notice-dismiss'),
              tooltip: '关闭通知',
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              style: TsButtons.ghost(),
              icon: Icon(Icons.close, size: 14, color: palette.foreground),
            ),
        ],
      ),
      ),
    );
  }
}

class _NoticePalette {
  const _NoticePalette({
    required this.foreground,
    required this.background,
    required this.icon,
  });

  final Color foreground;
  final Color background;
  final IconData icon;

  static _NoticePalette of(AppNoticeKind kind) => switch (kind) {
        AppNoticeKind.success => _NoticePalette(
            foreground: TsColors.ready,
            background: TsColors.readySoft,
            icon: Icons.check_circle_outline,
          ),
        AppNoticeKind.warning => _NoticePalette(
            foreground: TsColors.pending,
            background: TsColors.pendingSoft,
            icon: Icons.warning_amber_rounded,
          ),
        AppNoticeKind.error => _NoticePalette(
            foreground: TsColors.blocked,
            background: TsColors.blockedSoft,
            icon: Icons.error_outline,
          ),
        AppNoticeKind.info => _NoticePalette(
            foreground: TsColors.waiting,
            background: TsColors.waitingSoft,
            icon: Icons.info_outline,
          ),
      };
}
