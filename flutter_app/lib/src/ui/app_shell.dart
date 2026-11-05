// App shell — layout matching the requested design:
//
//   ┌──────────┬──────────────────────────────────────────────┐
//   │ history  │ one-sentence summary                          │
//   │ (240px)  ├───────────────────┬──────────────────────────┤
//   │          │ task list (~32%)  │ graph / gantt (switch)   │
//   │          ├───────────────────┴──────────────────────────┤
//   │          │ notes counters (collapsible)                  │
//   │          │ composer: attachments + text + / send arrow   │
//   └──────────┴──────────────────────────────────────────────┘

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/display.dart';
import '../model/session.dart';
import '../model/shortcuts.dart';
import '../state/app_controller.dart';
import '../state/execution/effort_review_service.dart';
import '../state/execution/effort_stats.dart';
import '../state/settings_controller.dart';
import 'analysis/chunked_analysis_dialog.dart';
import 'calendar_gantt.dart';
import 'calendar_settings_dialog.dart';
import 'composer.dart';
import 'desktop_window.dart';
import 'execution/effort_review_dialog.dart';
import 'execution/execution_actions.dart';
import 'execution/execution_status_strip.dart';
import './widgets/app_notice.dart';
import './widgets/attachment_notice.dart' as attachment_notice;
import './widgets/bezier_ui.dart';
import './widgets/bezier_menu.dart';
import 'dag_graph.dart';
import 'detail_popup.dart';
import 'gantt_chart.dart';
import 'history_panel.dart';
import 'model_selection_dialog.dart';
import 'notes_panel.dart';
import 'ocr/ocr_import_dialog.dart';
import 'settings_dialog.dart';
import './widgets/status_strip.dart';
import 'summary_bar.dart';
import 'task_edit_dialog.dart';
import 'task_list.dart';
import 'theme.dart';
import 'title_bar.dart';
import 'user_menu.dart';

enum ChartMode { tree, gantt }

enum _CloseChoice { retry, cancel, discard }

/// **等效宽度**（可用逻辑宽度 ÷ 文字缩放）≥ 该值时显示常驻侧栏；否则不常驻，
/// 用户展开时只显示临时抽屉。
///
/// 0.2.2 把断点从 940 提到 1080：常驻侧栏宽 244，若在 940 附近就常驻，主区放不下
/// 依赖视图标题行与输入框工具栏（实测 940–1040 在 1.0 倍字号下就横向溢出）。窗口
/// 窄（例如 960 的原生最小宽度）时宁可改走抽屉形态、让主区拿整宽，也不要挤出一个
/// 横向溢出。
///
/// 断点按**等效宽度**判断（见 [resolveSidebarWide] 的调用处）：文字放大后同样的
/// 逻辑宽度能装下的内容变少，所以 1.5 倍字号下需要更宽的窗口才显示常驻侧栏，
/// 否则主区仍会被挤到溢出。
const double kSidebarResidentMinWidth = 1080;

/// 断点滞回（DIP）：跨过 [kSidebarResidentMinWidth] 后还要再走这么多才切换形态，
/// 避免把窗口拖到断点附近时侧栏反复展开/收起（抖动）。
const double kSidebarBreakpointHysteresis = 24;

/// 由**等效宽度**与前一次形态判定是否「宽」（= 常驻侧栏形态）。
///
/// 「等效宽度」= 可用逻辑宽度 ÷ 文字缩放（clamp 到 1.0..2.0），因此 1.5 倍字号下
/// 1120 DIP 的窗口只按 747 判断 —— 主区拿到整宽，不会有“文字太大 + 常驻侧栏”
/// 双重挤压。调用方负责做除法；本函数保持纯函数，可直接单测断点行为。
///
/// 滞回规则：
///   * 之前没有判定（首帧）→ 直接按 1080 判断；
///   * 窄 → 宽：需要 ≥ 1080 + 24 = 1104；
///   * 宽 → 窄：需要 < 1080 - 24 = 1056。
bool resolveSidebarWide(double effectiveWidth, bool? previous) {
  if (previous == null) return effectiveWidth >= kSidebarResidentMinWidth;
  if (previous) {
    return effectiveWidth >=
        kSidebarResidentMinWidth - kSidebarBreakpointHysteresis;
  }
  return effectiveWidth >=
      kSidebarResidentMinWidth + kSidebarBreakpointHysteresis;
}

class AppShell extends StatefulWidget {
  final AppController controller;

  /// Application settings (theme, model connections, notifications). Owned by the
  /// bootstrap and shared with the settings dialog.
  final SettingsController settings;

  /// Boot-time storage notice (data directory fallback). Shown once in the summary
  /// bar; the shell does not own the controller's copy so it cannot be dismissed.
  final String? bootNotice;

  const AppShell({
    super.key,
    required this.controller,
    required this.settings,
    this.bootNotice,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const double _minListWidth = 250;
  static const double _maxListWidth = 560;

  final TextEditingController _draft = TextEditingController();
  final GlobalKey _middleKey = GlobalKey();
  final FocusNode _rootFocus = FocusNode(debugLabel: 'app-root');
  final FocusNode _composerFocus = FocusNode(debugLabel: 'composer-shell');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'conversation-search');

  ChartMode _chartMode = ChartMode.tree;

  /// 侧栏的**用户偏好**：唯一状态，只有用户动作会改它（标题栏按钮 / Ctrl+B /
  /// 侧栏收起按钮 / 搜索会话快捷键）。
  ///
  /// 窗口尺寸永远**不**写这里——0.2.1 在 LayoutBuilder 里直接写 `_showHistory`，
  /// 于是窗口缩窄一次侧栏就永久消失、放大/最大化也不会自己回来。这是本次修复的根因。
  bool _sidebarWanted = true;

  /// 窄窗口下的**临时抽屉**。只在可用逻辑宽度小于断点时显示；关闭它不会改
  /// [_sidebarWanted]，所以「窄屏里关掉抽屉」不会被误当成「用户收起了侧栏」——
  /// 窗口变宽后侧栏会按用户偏好自动恢复。
  bool _sidebarDrawerOpen = false;

  /// 上一次布局判定的宽/窄结果（带滞回，见 [_isWideFor]）；null = 还没判过。
  bool? _wideLayout;

  double _listWidth = 360;
  String? _lastConversationId;
  RunState? _previousRun;
  ConversationListMode _listMode = ConversationListMode.active;
  String _conversationQuery = '';
  TaskFilter _taskFilter = TaskFilter.all;
  String _taskQuery = '';
  Timer? _notificationPoll;
  String? _notifiedConversationId;

  /// 自绘标题栏使用的窗口端口；原生不可用时所有调用安全降级。
  final DesktopWindow _window = DesktopWindow();

  /// 关闭流程去重：保存进行中再次点击关闭不会启动第二份流程。
  bool _closing = false;

  // ------------------------------------------------ 应用级通知宿主（0.3.0 R4-B）

  /// 底部输入带（含账号入口）：通知宿主按它实测的高度上移，保证不盖住账号入口。
  final GlobalKey _bottomBandKey = GlobalKey(debugLabel: 'shell-bottom-band');
  bool _anchorSyncScheduled = false;

  /// 已被临时通知覆盖的状态条文案：同一事件不再同时出“顶部状态条 + 左下通知”。
  String? _suppressedStatus;
  String? _suppressedError;

  /// 最近一次投递到通知宿主的附件反馈（按对象身份去重，避免每次重建重复投递）。
  Object? _lastAttachmentFeedback;
  String? _noticeConversationId;

  AppController get c => widget.controller;
  SettingsController get s => widget.settings;

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerChanged);
    s.addListener(_onSettingsChanged);
    // Hover / pin state lives in TaskInteraction, which is NOT part of
    // AppController's own notifier chain — the shell must listen to it separately or
    // the detail card would never appear.
    c.interaction.addListener(_onControllerChanged);
    // 0.3.0（R4-B）：通知宿主是全局单例（挂在 bootstrap 的 MaterialApp.builder，
    // 位于 Navigator 之上）。新的 Shell 接管时清掉上一实例的残留并清掉旧计时器；
    // 控制器里若已有附件反馈（例如窗口重建），按同一宿主补投一次。
    AppNotices.instance.addListener(_onNoticesChanged);
    _noticeConversationId = c.conversation?.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppNotices.instance.reset();
      _syncAttachmentNotice();
    });
    _rootFocus.requestFocus();
    // On the real Windows embedder the focus node is not attached during initState,
    // so the call above is a no-op; ask again after the first frame so the global
    // shortcuts have an owner even before the user clicks something.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocus.requestFocus();
    });
    _notificationPoll = Timer.periodic(const Duration(seconds: 1), (_) {
      final gw = c.gateway;
      if (gw == null) return;
      try {
        if (!gw.takeNotificationClick()) return;
        final id = _notifiedConversationId;
        if (id != null && c.summaries.any((s) => s.id == id)) {
          c.openConversation(id);
        }
      } catch (_) {
        // Older DLL / notification unavailable: stay silent instead of crashing.
      }
    });
    // 原生关闭（标题栏 X、菜单退出、Alt+F4、任务栏关闭）统一走保存流程。
    _window.onCloseRequested = _handleWindowClose;
    // 本地 OCR 的文件选择器：直接使用原生对话框；不可用时对话框会明确说明。
    OcrFilePicker.defaultPick = () async {
      final gw = c.gateway;
      if (gw == null) return const <String>[];
      return gw.pickTextFiles(title: '选择扫描 PDF 或图片（本地 OCR）');
    };
    _window.attach().then((_) {
      if (mounted) _window.setCloseGuard(true);
    });
  }

  /// 统一关闭流程：先落盘必要数据，再真正销毁窗口。
  ///
  /// * 仍有弹窗/路由时，先交给该路由自己的未保存保护（maybePop），不绕过它；
  /// * 写入失败时不退出，提供“重试 / 取消退出 / 放弃并退出”；
  /// * 只有写入真正排空或用户明确放弃后才 confirmClose。
  Future<void> _handleWindowClose() async {
    if (_closing || !mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      await navigator.maybePop();
      return;
    }
    _closing = true;
    try {
      while (true) {
        final saved = await c.flushPendingWrites();
        if (saved) break;
        final choice = await _askCloseAfterFailure();
        if (choice == null || choice == _CloseChoice.cancel) return;
        if (choice == _CloseChoice.discard) break;
        // retry: loop and flush again.
      }
      // 计时检查点必须在窗口销毁前落盘（活动计时保存后暂停，不把退出期间算成工作）。
      await c.shutdown();
      await _window.confirmClose();
    } finally {
      _closing = false;
    }
  }

  Future<_CloseChoice?> _askCloseAfterFailure() {
    return showDialog<_CloseChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('保存失败，暂不能退出', style: TextStyle(fontSize: 15)),
        content: Text(
          '${c.errorMessage ?? '未保存的草稿写入失败。'}\n\n'
          '可以重试写入、取消退出回到工作，或明确放弃这些未保存修改后退出。',
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
        actions: [
          TextButton(
            key: const Key('close-cancel'),
            onPressed: () => Navigator.of(ctx).pop(_CloseChoice.cancel),
            child: const Text('取消退出'),
          ),
          FilledButton(
            key: const Key('close-retry'),
            onPressed: () => Navigator.of(ctx).pop(_CloseChoice.retry),
            child: const Text('重试'),
          ),
          TextButton(
            key: const Key('close-discard'),
            onPressed: () => Navigator.of(ctx).pop(_CloseChoice.discard),
            child: Text('放弃并退出',
                style: TextStyle(color: TsColors.blocked)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    s.removeListener(_onSettingsChanged);
    c.interaction.removeListener(_onControllerChanged);
    AppNotices.instance.removeListener(_onNoticesChanged);
    // 同步取消未完成的自动关闭计时器并丢弃仍引用本 State 的撤销回调；
    // 不 notify——树正在销毁，避免在卸载阶段触发祖先重建。
    AppNotices.instance.resetSilently();
    _lastAttachmentFeedback = null;
    _draft.dispose();
    _notificationPoll?.cancel();
    _window.onCloseRequested = null;
    _window.dispose();
    _rootFocus.dispose();
    _composerFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final run = c.run;
    if (run == null && _previousRun != null) {
      _notifyRunFinished();
    }
    _previousRun = run;
    _handleConversationBoundNotices();
    _syncAttachmentNotice();
    setState(() {});
  }

  /// 会话切换：清掉属于旧会话的通知（旧“撤销/导出”等动作不得作用到新会话）。
  void _handleConversationBoundNotices() {
    final id = c.conversation?.id;
    if (id == _noticeConversationId) return;
    final old = _noticeConversationId;
    _noticeConversationId = id;
    AppNotices.instance.dismissConversation(old);
  }

  /// 附件反馈：控制器是唯一数据源，宿主只展示一份（不再分侧栏/抽屉/工作区）。
  void _syncAttachmentNotice() {
    final feedback = c.attachmentFeedback;
    if (feedback == null) {
      _lastAttachmentFeedback = null;
      AppNotices.instance.dismissAttachment();
      return;
    }
    if (identical(feedback, _lastAttachmentFeedback)) return;
    _lastAttachmentFeedback = feedback;
    AppNotices.instance.showAttachment(
      feedback: _noticeData(feedback),
      onDismiss: c.dismissAttachmentFeedback,
      onShowDetails: () => _showAttachmentFeedbackDetails(feedback),
    );
  }

  /// 通知/状态条双回执抑制：同一事件已进入左下通知后，从顶部状态条移除。
  void _onNoticesChanged() {
    if (!mounted) return;
    final status = c.statusMessage;
    final error = c.errorMessage;
    var changed = false;
    if (status != null &&
        status != _suppressedStatus &&
        AppNotices.instance.isShowingMessage(status)) {
      _suppressedStatus = status;
      changed = true;
    }
    if (error != null &&
        error != _suppressedError &&
        AppNotices.instance.isShowingMessage(error)) {
      _suppressedError = error;
      changed = true;
    }
    if (changed) setState(() {});
  }

  /// 传给 StatusStrip 的已过滤文案：同一事件已经出现在左下通知里就不再重复。
  String? _visibleStatusMessage() {
    final message = c.statusMessage;
    if (message == null) {
      _suppressedStatus = null;
      return null;
    }
    if (message == _suppressedStatus) return null;
    _suppressedStatus = null;
    return message;
  }

  String? _visibleErrorMessage() {
    final message = c.errorMessage;
    if (message == null) {
      _suppressedError = null;
      return null;
    }
    if (message == _suppressedError) return null;
    _suppressedError = null;
    return message;
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- sidebar

  /// 当前**等效宽度**（可用逻辑宽度 ÷ 文字缩放）是否算「宽」（= 常驻侧栏形态），
  /// 带 ±[kSidebarBreakpointHysteresis] 滞回，见 [resolveSidebarWide]。只读
  /// [_wideLayout]（上一次判定），不碰 [_sidebarWanted]。
  bool _isWideFor(double effectiveWidth) =>
      resolveSidebarWide(effectiveWidth, _wideLayout);

  /// 把 LayoutBuilder 的可用逻辑宽度换成「等效宽度」：文字放大后同样宽度能装下的
  /// 内容更少，所以断点要按缩放折算。clamp 避免极端设置（<1.0 或 >2.0）把形态
  /// 翻来翻去。
  static double _effectiveWidth(double width, TextScaler textScaler) {
    final scale = textScaler.scale(1).clamp(1.0, 2.0);
    return width / scale;
  }

  /// 标题栏按钮 / Ctrl+B：宽屏切换「常驻侧栏偏好」，窄屏只开关临时抽屉。
  void _toggleSidebar() {
    setState(() {
      if (_wideLayout == true) {
        _sidebarWanted = !_sidebarWanted;
        if (!_sidebarWanted) _sidebarDrawerOpen = false;
      } else {
        // 窄屏没有常驻侧栏可收起：这里只开关临时抽屉，不写用户偏好。
        _sidebarDrawerOpen = !_sidebarDrawerOpen;
      }
    });
    if (_sidebarDrawerOpen) _focusRootSoon();
  }

  /// 折叠状态下唯一的展开入口（rail）以及搜索会话快捷键都走这里。
  void _expandSidebar() {
    if (_wideLayout == true) {
      setState(() => _sidebarWanted = true);
    } else {
      setState(() => _sidebarDrawerOpen = true);
      _focusRootSoon();
    }
  }

  /// 侧栏头部「收起」按钮：只改用户偏好（宽屏才会出现常驻侧栏）。
  void _collapseSidebar() {
    setState(() {
      _sidebarWanted = false;
      _sidebarDrawerOpen = false;
    });
  }

  /// 关闭窄屏临时抽屉。**不**改 [_sidebarWanted]：用户只是关掉了这个临时浮层，
  /// 不是决定“以后都不要侧栏”。窗口变宽后侧栏按偏好自动恢复。
  void _closeSidebarDrawer() {
    if (!_sidebarDrawerOpen) return;
    setState(() => _sidebarDrawerOpen = false);
    _focusRootSoon();
  }

  /// 让全局快捷键（尤其是 Esc）有焦点所有者。
  void _focusRootSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocus.requestFocus();
    });
  }

  /// 会话列表本身（常驻侧栏与窄屏抽屉共用同一份实现）。
  ///
  /// 只读取现有状态（会话、搜索词、列表模式），不修改它们；折叠/展开不会改变
  /// 当前会话、搜索词或选中任务。[searchFocusNode] 只在列表可见时传入，避免隐藏
  /// 的常驻列表与抽屉同时挂同一个 FocusNode。
  Widget _sidebarList({FocusNode? searchFocusNode}) {
    return HistorySidebarList(
      summaries: c.searchSummaries(
        _conversationQuery,
        archived: _listMode == ConversationListMode.archived,
        deleted: _listMode == ConversationListMode.trash,
      ),
      currentId: c.conversation?.id,
      mode: _listMode,
      query: _conversationQuery,
      onQuery: (value) => setState(() => _conversationQuery = value),
      onMode: (mode) => setState(() => _listMode = mode),
      onOpen: (id) {
        c.openConversation(id);
        // 抽屉是临时浮层：选中会话后自动收起（不改用户偏好）。
        if (_sidebarDrawerOpen) _closeSidebarDrawer();
      },
      onMenu: _showConversationMenu,
      searchFocusNode: searchFocusNode,
    );
  }

  /// 窄屏临时抽屉 / 覆盖面板：标题行（新建 + 关闭）+ 会话列表 + 账户入口。
  ///
  /// 它有明确的关闭按钮；点击遮罩或按 Esc 也会关闭。关闭**不改**
  /// [_sidebarWanted]，所以窗口重新变宽时常驻侧栏会按用户偏好恢复。
  Widget _buildSidebarDrawer() {
    return Positioned.fill(
      top: AppTitleBar.height,
      child: Stack(
        children: [
          // 遮罩：点击空白处关闭抽屉。
          Positioned.fill(
            child: GestureDetector(
              key: const Key('sidebar-drawer-barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: _closeSidebarDrawer,
              child: Container(color: Colors.black.withValues(alpha: 0.22)),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: kSidebarWidth,
            child: Material(
              key: const Key('sidebar-drawer'),
              color: TsColors.sidebar,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: TsSizes.textScaleAwareHeight(context, kTopBarHeight),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 14, right: 4),
                      child: Row(
                        children: [
                          const Text(
                            '会话',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: '新建会话',
                            visualDensity: VisualDensity.compact,
                            onPressed: _onNewConversation,
                            icon: const Icon(Icons.edit_square, size: 17),
                          ),
                          IconButton(
                            key: const Key('sidebar-drawer-close'),
                            tooltip: '关闭会话栏',
                            visualDensity: VisualDensity.compact,
                            onPressed: _closeSidebarDrawer,
                            icon: const Icon(Icons.close, size: 17),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: _sidebarList(searchFocusNode: _searchFocus)),
                  Container(height: 1, color: TsColors.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: UserMenuButton(onOpenSettings: _openSettings),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// In-app completion/failure notice. The 120-second reminder is a *request control*
  /// and deliberately not affected by these preferences.
  ///
  /// 0.3.0（R4-B）：分析结束统一进左下通知宿主；成功/失败开关与系统通知偏好保持。
  /// 成功时顶部状态条的同一条回执被抑制（避免“两张通知”）。
  void _notifyRunFinished() {
    final prefs = s.prefs;
    final status = c.statusMessage ?? '';
    final error = c.errorMessage;
    if (status.contains('已取消')) return;
    final succeeded = status.startsWith('已生成新版本');
    if (succeeded && !prefs.notifyOnSuccess) return;
    if (!succeeded && error == null) return;
    if (!succeeded && !prefs.notifyOnFailure) return;
    final conversationId = c.conversation?.id;
    var systemNoticeFailed = false;
    if (prefs.notifySystem && conversationId != null) {
      final gw = c.gateway;
      try {
        final title = succeeded ? 'TaskScheduler · 分析完成' : 'TaskScheduler · 分析失败';
        final body = succeeded
            ? '${c.conversation?.listTitle ?? '会话'}：已生成新版本'
            : '${c.conversation?.listTitle ?? '会话'}：${_short(error ?? status)}';
        final sent = gw?.showSystemNotification(title, body) ?? false;
        if (sent) {
          _notifiedConversationId = conversationId;
        } else {
          systemNoticeFailed = true;
        }
      } catch (_) {
        systemNoticeFailed = true;
      }
    }
    final headline = succeeded ? '分析完成：已生成新版本' : '分析失败';
    _showNotice(
      kind: succeeded ? AppNoticeKind.success : AppNoticeKind.error,
      message: systemNoticeFailed
          ? '$headline（系统通知不可用，已仅显示应用内提醒）'
          : headline,
      details: succeeded
          ? const <String>[]
          : <String>[
              _short(error ?? status),
              '原有计划与标题保持不变；按提示修正后可重试。',
            ],
      // 失败要读完原因，保留到手动关闭；成功短时后自动消失。
      autoDismiss: succeeded ? const Duration(seconds: 5) : null,
      dedupeKey: 'analysis-finished',
      conversationScoped: true,
      suppressStatusText: c.statusMessage,
      suppressErrorText: succeeded ? null : c.errorMessage,
    );
  }

  static String _short(String text) =>
      text.length <= 220 ? text : '${text.substring(0, 220)}…';

  @override
  Widget build(BuildContext context) {
    final conv = c.conversation;
    if (conv != null && conv.id != _lastConversationId) {
      _lastConversationId = conv.id;
      _draft.text = conv.draftText;
      // Restore the last dependency view used in this conversation.
      _chartMode = conv.chartMode == 'gantt' ? ChartMode.gantt : ChartMode.tree;
    }

    final version = c.viewVersion;
    final snapshot = c.display;
    final run = c.run;
    final reviewNotes = <String, String>{
      for (final n in version?.reviewNotes ?? const []) n.taskId: n.text,
    };

    _scheduleBottomAnchorSync();
    return _maybeHostNotices(Shortcuts(
      shortcuts: _buildShortcuts(),
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseDetailIntent: CallbackAction<_CloseDetailIntent>(onInvoke: (_) {
            // Esc 先关最上层浮层：窄屏临时抽屉优先，其次才是详情卡。
            if (_sidebarDrawerOpen) {
              _closeSidebarDrawer();
            } else {
              c.interaction.closeDetail();
            }
            return null;
          }),
          _NewSessionIntent: CallbackAction<_NewSessionIntent>(onInvoke: (_) {
            _onNewConversation();
            return null;
          }),
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(onInvoke: (_) {
            _openSettings();
            return null;
          }),
          _AddFileIntent: CallbackAction<_AddFileIntent>(onInvoke: (_) {
            if (c.run == null) _addFile();
            return null;
          }),
          _ConversationMenuIntent:
              CallbackAction<_ConversationMenuIntent>(onInvoke: (_) {
            final id = c.conversation?.id;
            if (id != null) {
              final size = MediaQuery.of(context).size;
              _showConversationMenu(
                  id, Offset(size.width * 0.2, size.height * 0.4));
            }
            return null;
          }),
          _FocusComposerIntent: CallbackAction<_FocusComposerIntent>(onInvoke: (_) {
            _composerFocus.requestFocus();
            return null;
          }),
          _SearchConversationsIntent:
              CallbackAction<_SearchConversationsIntent>(onInvoke: (_) {
            // 搜索会话需要侧栏可见：宽屏打开常驻侧栏，窄屏打开临时抽屉。
            if (_wideLayout == true) {
              setState(() => _sidebarWanted = true);
            } else {
              setState(() => _sidebarDrawerOpen = true);
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _searchFocus.requestFocus();
            });
            return null;
          }),
          _ToggleChartIntent: CallbackAction<_ToggleChartIntent>(onInvoke: (_) {
            _toggleChart();
            return null;
          }),
          _ToggleSidebarIntent:
              CallbackAction<_ToggleSidebarIntent>(onInvoke: (_) {
            _toggleSidebar();
            return null;
          }),
          _StopAnalysisIntent: CallbackAction<_StopAnalysisIntent>(onInvoke: (_) {
            _stopAnalysisWithConfirm();
            return null;
          }),
        },
        child: Focus(
          focusNode: _rootFocus,
          // Without autofocus the root node is not attached when initState calls
          // requestFocus(), so nothing owns keyboard focus and the global shortcuts
          // (Ctrl+, / Ctrl+N / Ctrl+O / Esc) never fire until the user tabs or clicks.
          autofocus: true,
          child: Scaffold(
            // One uniform surface: the sidebar is the only tinted area, so panels no
            // longer look like mismatched grey/white blocks.
            backgroundColor: TsColors.surface,
            body: LayoutBuilder(builder: (context, constraints) {
              /*
               * 侧栏形态只由两件事决定（R2-SB）：
               *   * **等效宽度**（可用逻辑宽度 ÷ 文字缩放）是否够宽 —— 带滞回；
               *   * 用户偏好 _sidebarWanted —— 只有用户动作会改它。
               *
               * 这里**不写** _sidebarWanted：窗口缩窄/放大只改变“常驻侧栏能不能显示”，
               * 不会把用户的选择记成“不要侧栏”，所以缩窄再放大能自动恢复；
               * 用户手动收起后，放大/最大化也仍然保持收起。
               *
               * 用等效宽度而不是原始宽度：1.5 倍字号下 1120 DIP 只按 747 判断，
               * 侧栏改走抽屉、主区拿整宽，避免“文字大 + 常驻侧栏”双重挤压导致溢出。
               */
              final effectiveWidth = _effectiveWidth(
                constraints.maxWidth,
                MediaQuery.textScalerOf(context),
              );
              final wide = _isWideFor(effectiveWidth);
              if (_wideLayout != wide) {
                _wideLayout = wide;
                if (wide && _sidebarDrawerOpen) {
                  // 变宽后常驻侧栏接管，窄屏临时抽屉不再有意义。这是形态切换，
                  // 不是“用户关抽屉”，所以只清临时状态，不碰 _sidebarWanted。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _sidebarDrawerOpen) {
                      setState(() => _sidebarDrawerOpen = false);
                    }
                  });
                }
              }
              // 常驻侧栏 = 宽屏 && 用户想要；窄屏永远不常驻，只用临时抽屉。
              final residentSidebar = wide && _sidebarWanted;
              final drawerOpen = !wide && _sidebarDrawerOpen;
              /*
               * Three full-width bands instead of two independent columns:
               *   top    — sidebar title | summary bar      (same height)
               *   middle — conversation list | tasks + chart + notes
               *   bottom — storage hint | composer          (same height)
               * Putting both sides of a band in ONE Row is what actually makes the
               * heights match; two Columns would drift apart as content changes.
               */
              final shell = Column(
                children: [
                  // 自绘标题栏：替代 Windows 原生标题栏的可见部分；拖动/吸附/缩放
                  // 仍由原生 WM_NCHITTEST 处理。
                  AppTitleBar(
                    window: _window,
                    // 抽屉打开时按钮语义是“收起”，所以也算可见。
                    sidebarVisible: residentSidebar || drawerOpen,
                    onToggleSidebar: _toggleSidebar,
                    onOpenAbout: _openAbout,
                    onExit: _exitApplication,
                  ),
                  SizedBox(
                    // 顶栏随文字缩放增高，1.5 倍字号下标题与副标题不会纵向溢出。
                    height: TsSizes.textScaleAwareHeight(context, kTopBarHeight),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (residentSidebar)
                          HistorySidebarHeader(
                            onNew: _onNewConversation,
                            onCollapse: _collapseSidebar,
                          )
                        else
                          // 折叠形态只在中间带保留**唯一**一个展开入口；顶/底带
                          // 只留同宽占位，右侧内容因此不会横向跳动。
                          const _SidebarRailSpacer(
                            key: Key('sidebar-collapsed-header'),
                          ),
                        Expanded(
                          child: SummaryBar(
                            conversation: conv,
                            version: version,
                            run: run,
                            onNewConversation: _onNewConversation,
                            onSelectVersion: (id) => c.selectVersion(id),
                            onExportUser: () => _export(diagnostics: false),
                            onExportDiag: () => _export(diagnostics: true),
                            onShowMaterials: _showMaterials,
                            onExportAll: _exportAllHistory,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        /*
                         * 折叠/展开只改变可见性，不销毁会话列表：
                         *   * rail 一直在树里（折叠时可见，展开时 offstage），所以整个
                         *     shell 只有一个展开入口，且不随形态切换重建；
                         *   * 会话列表同理，展开→折叠→展开后**滚动位置**还在（离屏时
                         *     不参与语义/焦点，也不会被点到）。
                         */
                        Offstage(
                          offstage: residentSidebar,
                          child: SizedBox(
                            width: kRailWidth,
                            child: SidebarRail(
                              key: const Key('sidebar-rail-expand'),
                              onExpand: _expandSidebar,
                            ),
                          ),
                        ),
                        Offstage(
                          offstage: !residentSidebar,
                          child: SizedBox(
                            width: kSidebarWidth,
                            child: ExcludeFocus(
                              excluding: !residentSidebar,
                              child: ExcludeSemantics(
                                excluding: !residentSidebar,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: _sidebarList(
                                        searchFocusNode:
                                            residentSidebar ? _searchFocus : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              StatusStrip(
                                // Location fallbacks are silent now; only the
                                // "nothing writable" case is a real warning.
                                storageNotice: c.storageNotice,
                                // 已经被左下临时通知覆盖的同一条回执不再在顶部重复。
                                errorMessage: _visibleErrorMessage(),
                                statusMessage: _visibleStatusMessage(),
                                onDismissError: c.clearMessages,
                              ),
                              // 0.2.3（R3-E）：常驻执行计时状态区。切会话/切视图都
                              // 还能看到正在计时的任务；空闲时也保留“工时回顾”入口。
                              if (c.executionTimer != null)
                                _buildExecutionStatusArea(),
                              if (c.waitPromptVisible && run != null)
                                WaitPromptBar(
                                  run: run,
                                  onKeepWaiting: c.dismissWaitPrompt,
                                  onCancel: c.cancelAnalysis,
                                ),
                              Expanded(child: _buildMiddle(snapshot, reviewNotes, run)),
                              if (snapshot != null)
                                NotesPanel(
                                  snapshot: snapshot,
                                  interaction: c.interaction,
                                  onJumpToTask: () {},
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  /*
                   * IntrinsicHeight gives this row a concrete height (the tallest child),
                   * which lets CrossAxisAlignment.stretch make the sidebar footer exactly
                   * as tall as the composer — that is the "same bottom band" requirement.
                   * Without it, a Row inside a Column receives unbounded height.
                   */
                  IntrinsicHeight(
                    key: _bottomBandKey,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (residentSidebar)
                          SidebarBottomBand(
                            child: UserMenuButton(
                              onOpenSettings: _openSettings,
                            ),
                          )
                        else
                          // 折叠形态的底部带：账户入口有真实语义（打开设置/账户页），
                          // 保留；它不是一个重复的侧栏展开开关。
                          _CollapsedSidebarFooterBand(
                            key: const Key('sidebar-collapsed-footer'),
                            onOpenSettings: _openSettings,
                          ),
                        Expanded(
                          child: ComposerBand(
                            child: Composer(
                              textController: _draft,
                              attachments: conv?.attachments ?? const [],
                              running: run != null,
                              canSend: run == null &&
                                  (c.conversation != null) &&
                                  ((_draft.text.trim().isNotEmpty) ||
                                      (conv?.attachments.isNotEmpty ?? false) ||
                                      c.hasRequestTimetable),
                              onSend: _handleSend,
                              materialNotice: c.materialExceedsSingleRequest
                                  ? '材料约 ${c.materialUtf8Bytes} 字节，超过单次请求上限 '
                                      '${c.singleRequestInputBytes} 字节；点击发送将进入「分块分析」'
                                  : null,
                              onAddFile: _addFile,
                              onRemoveAttachment: (id) => c.removeAttachment(id),
                              onDraftChanged: (text) => c.updateDraft(text),
                              enterToSend: s.prefs.sendOnEnter,
                              focusNode: _composerFocus,
                              useCustomBindings: true,
                              sendChord: resolveBinding(
                                AppCommands.send,
                                s.prefs.shortcutOverrides,
                                AppCommands.byId(AppCommands.send)!.defaultChord,
                              ),
                              modelLabel: modelSelectionLabel(
                                  s.profiles,
                                  conv?.modelSelection ??
                                      s.defaultSelection),
                              onModelTap: _changeModel,
                              onOpenTimetable: _openTimetableEditor,
                              timetableSummary: c.timetableSummary,
                              onRemoveTimetable: c.removeTimetableFromRequest,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              if (!drawerOpen) return shell;
              // 窄屏临时抽屉：覆盖在内容之上，有明确关闭按钮，Esc 也走
              // `_CloseDetailIntent`（见 _buildShortcuts/_CloseDetailIntent）。
              return Stack(
                children: [
                  Positioned.fill(child: shell),
                  _buildSidebarDrawer(),
                ],
              );
            }),
          ),
        ),
      ),
    ));
  }

  /// 生产环境由 bootstrap 在 MaterialApp.builder 挂载通知宿主（Navigator 之上）；
  /// 只有独立嵌入/组件测试（没有 [AppNoticeMountScope]）时才在页面内挂一份兜底，
  /// 保证通知仍可见且只渲染一次。
  Widget _maybeHostNotices(Widget shell) {
    if (AppNoticeMountScope.isMounted(context)) return shell;
    return AppNoticeHost(
      controller: AppNotices.instance,
      child: shell,
    );
  }

  /// 通知锚点：底部输入带（含账号入口）实测高度 + 间距 = 宿主距窗口底边的距离。
  /// 只在布局结束后量一次，缩放窗口/换字号时随 build 重新测量，不依赖固定像素。
  void _scheduleBottomAnchorSync() {
    if (_anchorSyncScheduled) return;
    _anchorSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorSyncScheduled = false;
      if (!mounted) return;
      final object = _bottomBandKey.currentContext?.findRenderObject();
      if (object is! RenderBox || !object.hasSize) return;
      AppNotices.instance.setBottomInset(object.size.height + 12);
    });
  }

  // ------------------------------------------------------------- middle

  Widget _buildMiddle(DisplaySnapshot? snapshot, Map<String, String> reviewNotes,
      RunState? run) {
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;
      final maxList = (available * 0.62).clamp(_minListWidth, _maxListWidth);
      _listWidth = _listWidth.clamp(_minListWidth, maxList);

      return Stack(
        key: _middleKey,
        children: [
          // Tap-to-dismiss layer, behind the content.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                c.interaction.closeDetail();
                _rootFocus.requestFocus();
              },
              child: const SizedBox.expand(),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              /*
               * ONE header row for both panes + ONE rule under it. Previously each pane
               * drew its own divider inside its own header height, so the two rules sat
               * a few pixels apart and looked broken across the gutter.
               */
              SizedBox(
                height: kPaneHeaderHeight,
                child: Row(
                  children: [
                    SizedBox(
                      width: _listWidth,
                      child: snapshot == null
                          ? const SizedBox.shrink()
                          : TaskListHeader(
                              snapshot: snapshot,
                              canEdit: c.canEditPlan && run == null,
                            ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: snapshot == null
                          ? const SizedBox.shrink()
                          : _ChartHeader(
                              mode: _chartMode,
                              onChanged: _changeChartMode,
                              snapshot: snapshot,
                            ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: TsColors.border),
              Expanded(
                child: Row(
                  children: [
                    /*
                     * Both halves of the middle area are white. The list column used to
                     * fall through to the scaffold's grey, which made the task list and
                     * the chart look like two different panels.
                     */
                    SizedBox(
                      width: _listWidth,
                      child: Container(
                        color: TsColors.surface,
                        child: snapshot == null
                            ? const _EmptyState()
                            : TaskListView(
                                snapshot: snapshot,
                                interaction: c.interaction,
                                canEdit: c.canEditPlan && run == null,
                                reviewNotes: reviewNotes,
                                showCompleted: s.prefs.showCompletedTasks,
                                filter: _taskFilter,
                                query: _taskQuery,
                                onFilter: (value) =>
                                    setState(() => _taskFilter = value),
                                onQuery: (value) =>
                                    setState(() => _taskQuery = value),
                                onToggle: _toggleTask,
                                onConfirmReview: (id) => c.confirmReviewedTask(id),
                                onSelect: (_) {},
                              ),
                      ),
                    ),
                    _Splitter(
                      onDrag: (dx) => setState(() {
                        _listWidth = (_listWidth + dx).clamp(_minListWidth, maxList);
                      }),
                      onReset: () => setState(() => _listWidth = 360),
                    ),
                    Expanded(
                      child: Container(
                        color: TsColors.surface,
                        child: snapshot == null
                            ? const _EmptyState(chart: true)
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                                child: _chartMode == ChartMode.tree
                                    ? DagGraphView(
                                        snapshot: snapshot,
                                        interaction: c.interaction,
                                      )
                                    : GanttPanel(
                                        snapshot: snapshot,
                                        interaction: c.interaction,
                                        version: c.viewVersion,
                                        // 合成快照：只读外部忙碌已并入 settings，冲突检测/
                                        // 不可用时段因此包含外部占用；手工时间表本身不变。
                                        calendar:
                                            c.currentCalendarSchedule ?? c.calendar,
                                        initialMode:
                                            c.conversation?.ganttMode ?? 'relative',
                                        onModeChanged: (mode) =>
                                            c.setGanttMode(mode),
                                        proposalSource: CalendarProposalSource(
                                          cached: c.calendarProposalsAreCurrent
                                              ? c.calendarProposals
                                              : null,
                                          blockedReason:
                                              c.calendarMaterialSources().isEmpty
                                                  ? '还没有可识别的材料：先在输入框粘贴材料，或添加课程表/活动安排文件。'
                                                  : null,
                                          request: ({bool force = false}) =>
                                              c.fetchCalendarProposals(
                                                  force: force),
                                          cancel: c.cancelCalendarProposals,
                                        ),
                                        clock: null,
                                        actions: c.canEditPlan && run == null
                                            ? CalendarActions(
                                                commit: c.applyCalendarEdit,
                                                autoSchedule: ({required bool keepManual}) =>
                                                    c.runAutoSchedule(
                                                        keepManual: keepManual),
                                                applySettings: (settings,
                                                        {required bool reschedule}) =>
                                                    c.applyCalendarSettings(settings,
                                                        reschedule: reschedule),
                                                ensureReady: c.ensureCalendarReady,
                                                taskNotes: c.calendarTaskNotes,
                                                timetable: c.viewVersion?.timetable ??
                                                    c.conversation?.calendarDraft,
                                                weekStartsOn: c.weekStartsOn,
                                                defaultEditor: c.defaultCalendarEditor,
                                                defaultUnavailableRanges:
                                                    c.defaultUnavailableRanges,
                                                taskNames: c.taskNamesById,
                                                applyTimetable: (settings, timetable,
                                                        {required bool reschedule}) =>
                                                    c.applyTimetableSettings(
                                                        settings, timetable,
                                                        reschedule: reschedule),
                                              )
                                            : CalendarActions(
                                                canEdit: false,
                                                commit: (_) async => false,
                                                autoSchedule: ({required bool keepManual}) async =>
                                                    null,
                                                applySettings: (settings,
                                                        {required bool reschedule}) async =>
                                                    false,
                                                ensureReady: c.ensureCalendarReady,
                                                taskNotes: c.calendarTaskNotes,
                                              ),
                                      ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (snapshot != null) _buildDetailLayer(snapshot),
        ],
      );
    });
  }

  Widget _buildDetailLayer(DisplaySnapshot snapshot) {
    final id = c.interaction.detailTaskId;
    if (id == null) return const SizedBox.shrink();
    final task = snapshot.byId(id);
    if (task == null) return const SizedBox.shrink();

    final middleBox = _middleKey.currentContext?.findRenderObject() as RenderBox?;
    final middleSize = middleBox?.size ?? const Size(800, 600);
    final anchor = c.interaction.anchors[id];

    final cardWidth = math.max(260.0, math.min(400.0, middleSize.width - 16));
    double left;
    double top;
    if (anchor != null && middleBox != null) {
      final localTopRight = middleBox.globalToLocal(anchor.rect.topRight);
      final localTopLeft = middleBox.globalToLocal(anchor.rect.topLeft);
      left = localTopRight.dx + 12;
      if (left + cardWidth > middleSize.width - 8) {
        final leftSide = localTopLeft.dx - cardWidth - 12;
        left = leftSide >= 8 ? leftSide : (middleSize.width - cardWidth - 8);
      }
      top = localTopRight.dy - 8;
      // Pinned detail stays inside the viewport even when its trigger scrolls away.
      top = top.clamp(52.0, math.max(52.0, middleSize.height - 160));
    } else {
      left = middleSize.width - cardWidth - 16;
      top = 16;
    }
    left = left.clamp(8.0, (middleSize.width - cardWidth - 8).clamp(8.0, double.infinity));
    /*
     * Keep the card clear of the chart header (~46px) so the tree/gantt switch and the
     * task counters stay clickable while a detail is pinned. A floating card that
     * covers the controls it describes would be worse than no card.
     */
    const headerZone = 52.0;
    final maxTop = (middleSize.height - 120).clamp(headerZone, double.infinity);
    top = top.clamp(headerZone, maxTop);

    /*
     * Height is derived from the top we actually placed the card at, so the card can
     * never overhang the bottom of the chart area (it used to spill into the notes
     * strip). It is also capped relative to the pane so a long detail does not fill the
     * whole chart: the body scrolls instead.
     */
    final availableBelow = middleSize.height - top - 12;
    final heightCap = middleSize.height * 0.72;
    final cardMaxHeight =
        math.min(availableBelow, math.max(180.0, heightCap)).clamp(160.0, 900.0);

    return Positioned(
      left: left,
      top: top,
      child: SizedBox(
        width: cardWidth,
        child: TaskDetailCard(
          task: task,
          interaction: c.interaction,
          maxHeight: cardMaxHeight,
          pinned: c.interaction.pinned,
          canEdit: c.canEditPlan,
          onEdit: () => _editTask(task, snapshot),
          onCycleCondition: (index) => _cycleCondition(task, index, snapshot),
          executionSection: _buildExecutionSection(task),
        ),
      ),
    );
  }

  Future<void> _editTask(DisplayTask view, DisplaySnapshot snapshot) async {
    final version = c.viewVersion;
    final record = version?.plan.taskById(view.id);
    if (version == null || record == null) return;
    final result = await showDialog<TaskEditResult>(
      context: context,
      builder: (_) => TaskEditDialog(task: record, allTasks: version.tasks),
    );
    if (result == null) return;
    final ok = await c.updateTask(
      view.id,
      name: result.name,
      estimatedHours: result.estimatedHours,
      clearEstimate: result.estimatedHours == null,
      deadline: result.deadline,
      dependsOn: result.dependsOn,
    );
    if (!mounted) return;
    if (!ok) {
      _showNotice(
        kind: AppNoticeKind.error,
        message: c.errorMessage ?? '本次编辑未通过校验，已保留原计划',
        autoDismiss: null,
        conversationScoped: true,
        suppressErrorText: c.errorMessage,
      );
    } else {
      _offerUndo();
    }
  }

  Future<void> _toggleTask(String id) async {
    final ok = await c.toggleCompletion(id);
    if (ok && mounted) _offerUndo();
  }

  /// 可撤销操作的通知（保留原来的撤销有效期/回调，迁移到左下宿主）。
  ///
  /// 执行前校验：仍停在同一会话，且撤销栈顶部仍是发出通知时的那次操作；切会话或
  /// 又做了别的修改后旧动作不会落到新状态上。
  void _offerUndo() {
    if (!c.canUndo) return;
    final conversationId = c.conversation?.id;
    final expectedLabel = c.undoLabel;
    _showNotice(
      kind: AppNoticeKind.info,
      message: expectedLabel ?? '已修改',
      actionLabel: '撤销',
      actionValidFor: const Duration(seconds: 4),
      autoDismiss: const Duration(seconds: 4),
      dedupeKey: 'undo',
      conversationScoped: true,
      suppressStatusText: c.statusMessage,
      onAction: () async {
        if (!mounted) return;
        if (c.conversation?.id != conversationId) return;
        if (c.undoLabel != expectedLabel) return;
        await c.undoLast();
        if (mounted) _showSnack(c.statusMessage ?? '已撤销');
      },
    );
  }

  Future<void> _cycleCondition(
      DisplayTask view, int index, DisplaySnapshot snapshot) async {
    final version = c.viewVersion;
    final record = version?.plan.taskById(view.id);
    if (record == null || index < 0 || index >= record.preconditions.length) return;
    const order = ['unknown', 'met', 'unmet'];
    final current = record.preconditions[index].status;
    final next = order[(order.indexOf(current) + 1) % order.length];
    final ok = await c.setPreconditionStatus(view.id, index, next);
    if (!mounted || ok) return;
    _showNotice(
      kind: AppNoticeKind.error,
      message: c.errorMessage ?? '条件状态更新未通过校验',
      autoDismiss: null,
      conversationScoped: true,
      suppressErrorText: c.errorMessage,
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _onNewConversation() async {
    await c.createConversation();
    _draft.clear();
    _rootFocus.requestFocus();
  }

  /// Opens the settings window. Unsaved changes are handled inside the dialog.
  ///
  /// The external-calendar service is optional; when the app was bootstrapped without
  /// one the settings page shows an explicit "service unavailable" notice.
  Future<void> _openSettings({SettingsSection initial = SettingsSection.account}) async {
    final conv = c.conversation;
    await showSettingsDialog(
      context,
      controller: s,
      initial: initial,
      storageSource: c.storageSource,
      storageMemoryOnly: !c.storageIsPersistent,
      externalCalendar: c.externalCalendar,
      timezoneId: c.calendar.settings.timezoneId,
      currentConversationTitle: conv?.generatedTitle,
      // 0.2.3（R3-E）：备份/恢复执行记录必须复用运行中的存储实例。
      executionStore: c.executionTimer?.store,
      // 外部日历来源变化后刷新只读占用/排程等界面（不重新规划、不改手工时间表）。
      onExternalCalendarChanged: () {
        if (mounted) setState(() {});
      },
    );
    if (mounted) _rootFocus.requestFocus();
  }

  /// 「应用 → 关于 TaskScheduler」：复用设置窗口的“关于”页和未保存保护。
  Future<void> _openAbout() => _openSettings(initial: SettingsSection.about);

  /// 「应用 → 退出」和标题栏关闭按钮：交给统一关闭流程（保存后真正退出）。
  Future<void> _exitApplication() => _window.requestClose();

  /// Selects the model for *this* conversation's future requests. The current plan is
  /// not regenerated — only the next supplement request uses the new selection.
  Future<void> _changeModel() async {
    final conv = c.conversation;
    if (conv == null) return;
    final choice = await showModelSelectionDialog(
      context,
      profiles: s.profiles,
      current: conv.modelSelection ?? s.defaultSelection,
      globalDefault: s.defaultSelection,
    );
    if (choice == null || !mounted) return;
    final error = await c.setConversationSelection(
        choice.followDefault ? null : choice.selection);
    if (!mounted) return;
    if (error != null) _showSnack(error);
    _rootFocus.requestFocus();
  }

  /// 加号右侧的时间图标：与甘特图“可用时间”打开同一个编辑器、同一份时间表。
  Future<void> _openTimetableEditor() async {
    if (c.conversation == null) await c.ensureConversation();
    if (!mounted) return;
    if (!c.canEditTimetable) {
      _showSnack('当前查看的是历史版本（或正在分析），不能修改时间表');
      return;
    }
    final conv = c.conversation;
    // 编辑的是“当前看到的版本”：外部忙碌已合成进排程快照，所以设置也用合成快照的
    // settings，冲突提示/不可用时段才与图上一致；没有版本时退回当前日历设置。
    final settings = c.currentCalendarSchedule?.settings ??
        c.viewVersion?.calendar.settings ??
        c.calendar.settings;
    // 时间表仍是手工权威数据：外部日历只作为只读输入传给编辑器展示。
    final timetable = c.currentTimetable();
    // 绑定面板需要“任务预估时长”才能显示预留与计划时长的差异；工时未知的任务以
    // null 传入，面板显示“未知”，绝不按 0 计算。
    final taskEstimatedHours = <String, double?>{
      for (final task in c.schedulingTasks()) task.id: task.estimatedHours,
    };
    final result = await showCalendarSettingsDialog(
      context,
      settings: settings,
      now: DateTime.now(),
      timetable: timetable,
      weekStartsOn: c.weekStartsOn,
      initialMode: c.defaultCalendarEditor,
      defaultUnavailableRanges: c.defaultUnavailableRanges,
      taskNames: c.taskNamesById,
      taskEstimatedHours: taskEstimatedHours,
      useDefaultTimetable: conv?.calendarDraft == null && c.viewVersion == null,
      // 外部日历只读展示：编辑器可看到斜纹占用与来源，但绝不会写回手工时间表。
      externalCalendar: c.externalCalendar,
      externalSourceIds: c.currentExternalSourceIds,
      onApply: (r) => c.applyTimetableSettings(
        r.settings,
        r.timetable ?? timetable,
        reschedule: true,
      ),
    );
    if (result == null || !mounted) return;
    final ok = await c.applyTimetableSettings(
      result.settings,
      result.timetable ?? timetable,
      reschedule: true,
    );
    if (!ok && mounted) _showSnack(c.errorMessage ?? '时间表未能保存');
  }

  /// Opens the NATIVE Windows file dialog (ts_bridge_pick_file → GetOpenFileNameW).
  ///
  /// Multi-selection is enabled, so one dialog can add several files; each is read and
  /// validated independently and per-file failures are reported without losing the ones
  /// that succeeded.
  // --------------------------------------------- execution (0.2.3 R3-E/R3-R)

  /// 常驻执行状态区：左侧是当前计时任务（空闲时也保留入口），右侧是工时回顾。
  Widget _buildExecutionStatusArea() {
    final timer = c.executionTimer!;
    return Row(
      children: [
        Expanded(
          child: ExecutionStatusStrip(
            controller: timer,
            showWhenIdle: true,
            onOpenTask: _openActiveTimerTask,
          ),
        ),
        Tooltip(
          message: '工时回顾与 CSV 导出',
          child: TextButton.icon(
            key: const Key('open-effort-review'),
            onPressed: _openEffortReview,
            icon: const Icon(Icons.assessment_outlined, size: 14),
            label: const Text('回顾', style: TextStyle(fontSize: 11.5)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
        if (c.conversation != null && !c.isRunning && !c.chunkedAnalysisRunning)
          Tooltip(
            message: '超大材料分块分析（多次模型请求，费用未知）',
            child: TextButton.icon(
              key: const Key('open-chunked-analysis'),
              onPressed: _openChunkedAnalysis,
              icon: const Icon(Icons.call_split, size: 14),
              label: const Text('分块分析', style: TextStyle(fontSize: 11.5)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        if (c.ocr != null && !c.isRunning)
          Tooltip(
            message: '扫描 PDF / 图片：本地离线 OCR，识别后可校对',
            child: TextButton.icon(
              key: const Key('open-ocr-import'),
              onPressed: _openOcrImport,
              icon: const Icon(Icons.document_scanner_outlined, size: 14),
              label: const Text('OCR', style: TextStyle(fontSize: 11.5)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
      ],
    );
  }

  /// 打开本地 OCR 导入（不依赖先尝试文本提取）。
  Future<void> _openOcrImport() async {
    final service = c.ocr;
    if (service == null) {
      _showSnack('本地 OCR 未启用');
      return;
    }
    await showOcrImportDialog(
      context,
      service: service,
      onConfirm: (material) async {
        final error = await c.addOcrMaterial(material);
        if (error != null) {
          _showSnack(error);
          return false;
        }
        return true;
      },
    );
  }

  /// 打开分块分析对话框（先做不联网的本地预估，用户确认后才发请求）。
  Future<void> _openChunkedAnalysis() async {
    final estimate = c.describeChunkedAnalysis();
    if (estimate == null) {
      _showSnack('当前没有可分析的文本材料（请先粘贴材料或添加文件）');
      return;
    }
    await ChunkedAnalysisDialog.show(
      context,
      controller: c,
      estimate: estimate,
    );
  }

  /// 点状态区里的任务名：切到计时任务所在会话（不改计时状态）。
  void _openActiveTimerTask() {
    final active = c.executionTimer?.active;
    if (active == null) return;
    if (active.conversationId != c.conversation?.id) {
      c.openConversation(active.conversationId);
    }
  }

  /// 任务详情卡里的“执行与实际耗时”区；未启用计时时返回 null（完全隐藏）。
  Widget? _buildExecutionSection(DisplayTask task) {
    final timer = c.executionTimer;
    if (timer == null) return null;
    final ref = c.executionRefFor(task.id);
    if (ref == null) return null;
    final effort = c.executionTaskEffort(task.id);
    final lines = <String>[];
    if (effort == null || !effort.factsKnown) {
      lines.add('实际耗时：$kEffortUnknownLabel（尚未计时或补记）');
    } else {
      final parts = <String>[
        '实际 ${formatEffortHours(effort.actualHours)}',
        if (effort.baselineHours != null)
          '基线 ${formatEffortHours(effort.baselineHours)}',
      ];
      final deviation = effort.deviationHours;
      if (deviation != null) {
        final sign = deviation >= 0 ? '+' : '';
        final pct = effort.deviationPercent;
        parts.add('偏差 $sign${formatEffortHours(deviation)}'
            '${pct == null ? '' : '（${formatEffortPercent(pct)}）'}');
      }
      lines.add(parts.join(' · '));
    }
    if (effort != null && effort.totalPending > Duration.zero) {
      lines.add('待校正 ${formatEffortDuration(effort.totalPending)}'
          '（未计入实际，需确认）');
    }
    if (effort != null &&
        !effort.isDone &&
        effort.suggestedRemainingHours != null) {
      lines.add('剩余建议 ${formatEffortHours(effort.suggestedRemainingHours)}'
          '（建议值，未自动完成）');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: TsColors.textSecondary)),
          ),
        const SizedBox(height: 4),
        ExecutionActions(
          controller: timer,
          taskRef: ref,
          done: task.status == 'done',
          onToggleCompletion: () async {
            await c.toggleCompletion(task.id);
          },
        ),
      ],
    );
  }

  Future<void> _openEffortReview() async {
    final timer = c.executionTimer;
    if (timer == null) return;
    final tasks = c.executionTaskContext().values.toList(growable: false);
    final conversations = <ExecutionConversationInfo>[
      for (final summary in c.summaries)
        ExecutionConversationInfo(id: summary.id, title: summary.displayTitle),
    ];
    await EffortReviewDialog.show(
      context,
      service: EffortReviewService(ledger: timer.ledger),
      tasks: tasks,
      conversations: conversations,
      onExport: _exportReviewCsv,
    );
  }

  /// 导出回顾 CSV：复用现有的“输入保存路径”对话框，写入由 AppController 负责。
  Future<bool> _exportReviewCsv(
      String name, String csv, String suggestedPath) async {
    final pathController = TextEditingController(
      text: suggestedPath.contains('\\') || suggestedPath.contains('/')
          ? suggestedPath
          : '${_defaultDir()}\\$suggestedPath',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导出$name'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: pathController,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(labelText: '保存路径'),
              ),
              const SizedBox(height: 8),
              Text(
                'CSV 含时区、统计范围、口径与未知值；不含 API Key 与材料原文。',
                style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(pathController.text.trim()),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return false;
    final error = await c.writeEffortCsv(path: path, csv: csv);
    if (!mounted) return error == null;
    // 控制器同时会把“已导出回顾 CSV：...”写进状态条；这里只保留左下通知一份。
    _showNotice(
      kind: error == null ? AppNoticeKind.success : AppNoticeKind.error,
      message: error ?? '已导出$name 到 $path',
      autoDismiss: error == null ? const Duration(seconds: 5) : null,
      suppressStatusText:
          (c.statusMessage ?? '').startsWith('已导出回顾 CSV') ? c.statusMessage : null,
    );
    return error == null;
  }

  /// 发送入口：材料超单次请求预算时不硬发，改为分块分析确认入口。
  Future<void> _handleSend() async {
    if (!c.materialExceedsSingleRequest) {
      await c.startAnalysis();
      return;
    }
    final estimate = c.describeChunkedAnalysis();
    if (estimate == null) {
      _showSnack('材料超过单次请求上限，且当前无法建立分块作业；请减少材料后再发送');
      return;
    }
    await ChunkedAnalysisDialog.show(context, controller: c, estimate: estimate);
  }

  Future<void> _addFile() async {
    final gw = c.gateway;
    if (gw == null) {
      // 提示词 02：附件类反馈走侧栏通知区，不再用底部浮动 SnackBar。
      c.reportAttachmentFeedback(
        added: 0,
        failed: 0,
        note: '无法打开文件对话框：原生桥接不可用',
      );
      return;
    }
    List<String> paths;
    try {
      paths = await gw.pickTextFiles();
    } catch (e) {
      c.reportAttachmentFeedback(
        added: 0,
        failed: 0,
        note: '打开文件对话框失败：$e',
      );
      return;
    }
    if (paths.isEmpty) return; // user cancelled

    final failures = <String>[];
    var added = 0;
    for (final path in paths) {
      final ok = await c.addTextFile(path);
      if (ok) {
        added++;
        continue;
      }
      final name = path.split(Platform.pathSeparator).last;
      // 扫描型 PDF / 图片：文本提取明确返回 unsupported_ocr 且本地 OCR 可用时，
      // 直接进入 OCR 导入（页范围→识别→校对→加入材料），而不是只报“不支持”。
      if (c.lastDocumentErrorCode == 'unsupported_ocr' && c.ocr != null) {
        if (!mounted) return;
        final confirmed = await showOcrImportDialog(
          context,
          service: c.ocr!,
          initialFilePath: path,
          onConfirm: (material) async {
            final error = await c.addOcrMaterial(material);
            if (error != null) {
              _showSnack(error);
              return false;
            }
            return true;
          },
        );
        if (confirmed) {
          added++;
          continue;
        }
        failures.add('$name：未完成本地 OCR 导入');
        continue;
      }
      failures.add('$name：${c.errorMessage ?? '无法添加'}');
    }
    if (!mounted) return;
    // 超单次请求预算时给出可执行说明（材料已保留，不会截断），由侧栏通知展示。
    final exceeds = added > 0 && c.materialExceedsSingleRequest;
    c.reportAttachmentFeedback(
      added: added,
      failed: failures.length,
      failures: failures,
      note: exceeds
          ? '材料文本约 ${c.materialUtf8Bytes} 字节，超过单次请求上限 '
              '${c.singleRequestInputBytes} 字节；发送时请使用「分块分析」。'
          : null,
    );
  }

  /// 应用级临时通知（0.3.0 R4-B）：所有原来的 SnackBar/附件三处渲染都收敛到这里。
  ///
  /// * 会话归属：`conversationScoped` 时记录当前会话，切会话/窗口重建后旧动作不会
  ///   作用到新会话；执行动作前再次核对会话仍是当次会话。
  /// * 双回执：投递后若顶部状态条/错误横幅是同一条文案，就把它从 StatusStrip 移除。
  void _showNotice({
    required AppNoticeKind kind,
    required String message,
    List<String> details = const <String>[],
    String? actionLabel,
    VoidCallback? onAction,
    Duration? actionValidFor,
    Duration? autoDismiss,
    String? dedupeKey,
    bool conversationScoped = false,
    String? suppressStatusText,
    String? suppressErrorText,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    final convId = c.conversation?.id;
    VoidCallback? wrappedAction;
    if (onAction != null) {
      wrappedAction = () {
        if (!mounted) return;
        if (conversationScoped && c.conversation?.id != convId) return;
        onAction();
      };
    }
    AppNotices.instance.show(
      kind: kind,
      message: text,
      details: details,
      actionLabel: actionLabel,
      onAction: wrappedAction,
      actionValidFor: actionValidFor,
      autoDismiss: autoDismiss,
      dedupeKey: dedupeKey,
      conversationId: conversationScoped ? convId : null,
    );
    if (suppressStatusText != null && c.statusMessage == suppressStatusText) {
      _suppressedStatus = suppressStatusText;
    }
    if (suppressErrorText != null && c.errorMessage == suppressErrorText) {
      _suppressedError = suppressErrorText;
    }
  }

  /// 旧 `_showSnack` 的语义迁移：按文案判断种类，失败保留到用户关闭。
  void _showSnack(String message) {
    if (!mounted) return;
    final kind = _inferNoticeKind(message);
    _showNotice(
      kind: kind,
      message: message,
      autoDismiss: kind == AppNoticeKind.error || kind == AppNoticeKind.warning
          ? null
          : const Duration(seconds: 4),
    );
  }

  static AppNoticeKind _inferNoticeKind(String message) {
    if (message.contains('失败') ||
        message.contains('未能') ||
        message.contains('无法') ||
        message.contains('错误') ||
        message.contains('未通过')) {
      return AppNoticeKind.error;
    }
    if (message.contains('不能') ||
        message.contains('不可用') ||
        message.contains('未启用') ||
        message.contains('没有')) {
      return AppNoticeKind.warning;
    }
    if (message.startsWith('已') || message.contains('成功')) {
      return AppNoticeKind.success;
    }
    return AppNoticeKind.info;
  }

  attachment_notice.AttachmentFeedback _noticeData(AttachmentFeedback feedback) {
    return attachment_notice.AttachmentFeedback(
      conversationId: feedback.conversationId,
      at: feedback.at,
      added: feedback.added,
      failed: feedback.failed,
      failures: feedback.failures,
      note: feedback.note,
    );
  }

  /// 打开附件反馈详情（侧栏通知区的“查看全部”入口）。
  Future<void> _showAttachmentFeedbackDetails(AttachmentFeedback feedback) {
    final lines = <String>[
      ...feedback.failures,
      if (feedback.note != null) feedback.note!,
    ];
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: TsColors.surface,
        shape: const BezierRoundedRectangleBorder(radius: 14),
        title: const Text('文件导入结果', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(feedback.summary,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('· $line',
                        style: TextStyle(
                            fontSize: 12, height: 1.45, color: TsColors.textSecondary)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------- conversation actions

  // ------------------------------------------------------- command dispatch

  Map<ShortcutActivator, Intent> _buildShortcuts() {
    final map = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.f10, shift: true):
          const _ConversationMenuIntent(),
      const SingleActivator(LogicalKeyboardKey.contextMenu):
          const _ConversationMenuIntent(),
    };
    for (final def in AppCommands.all) {
      final chord = s.shortcutFor(def);
      if (chord == null) continue;
      final intent = switch (def.id) {
        AppCommands.newConversation => const _NewSessionIntent(),
        AppCommands.openSettings => const _OpenSettingsIntent(),
        AppCommands.addFile => const _AddFileIntent(),
        AppCommands.closeOverlay => const _CloseDetailIntent(),
        AppCommands.focusComposer => const _FocusComposerIntent(),
        AppCommands.searchConversations => const _SearchConversationsIntent(),
        AppCommands.toggleChart => const _ToggleChartIntent(),
        AppCommands.toggleSidebar => const _ToggleSidebarIntent(),
        AppCommands.stopAnalysis => const _StopAnalysisIntent(),
        AppCommands.send => null,
        _ => null,
      };
      if (intent != null) map[chord.activator] = intent;
    }
    return map;
  }

  /// Text the user submitted for this conversation (drafts + attachments) used to be
  /// fed to a local regex "extractor" here. That path is gone: calendar constraints now
  /// come from a real model request (`AppController.fetchCalendarProposals`), which
  /// receives the same material through the normal `sources` list.

  void _changeChartMode(ChartMode m) {
    if (m == _chartMode) return;
    // The old popup's anchor belongs to the old view. Close it and drop all cached
    // rectangles before the new view is built; a new hover/click will supply one.
    c.interaction.switchView();
    setState(() => _chartMode = m);
    c.setChartMode(m == ChartMode.gantt ? 'gantt' : 'tree');
  }

  void _toggleChart() {
    final next =
        _chartMode == ChartMode.tree ? ChartMode.gantt : ChartMode.tree;
    _changeChartMode(next);
  }

  Future<void> _stopAnalysisWithConfirm() async {
    if (!c.isRunning) {
      _showSnack('当前没有正在进行的分析');
      return;
    }
    final go = await _confirm(
      title: '停止当前分析？',
      body: '已发出的请求会被取消，模型结果将丢弃；原有计划和标题保持不变。',
      confirm: '停止分析',
      danger: true,
    );
    if (!go) return;
    await c.cancelAnalysis();
  }

  /// The conversation menu — right-click, the card's ellipsis button and the keyboard
  /// entry all call this, so there is exactly one menu and one style.
  ///
  /// It uses [showBezierMenu] (theme surface, hairline border, Bézier corners, uniform
  /// 40 px rows, no shadow, 150 ms fade) instead of `showMenu`, whose own elevation and
  /// animate-in made this menu look different from the settings menu.
  Future<void> _showConversationMenu(
      String id, Offset globalPosition) async {
    ConversationSummary? summary;
    for (final s in c.summaries) {
      if (s.id == id) {
        summary = s;
        break;
      }
    }
    if (summary == null) return;
    final inTrash = _listMode == ConversationListMode.trash;
    final running = c.hasActiveRun(id);
    final items = <BezierMenuItem<ConversationMenuAction>>[
      if (!inTrash) ...[
        const BezierMenuItem(
          value: ConversationMenuAction.open,
          label: '打开',
          icon: Icons.open_in_new,
        ),
        const BezierMenuItem(
          value: ConversationMenuAction.rename,
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
        ),
        BezierMenuItem(
          value: summary.isPinned
              ? ConversationMenuAction.unpin
              : ConversationMenuAction.pin,
          label: summary.isPinned ? '取消置顶' : '置顶',
          icon: Icons.push_pin_outlined,
        ),
        BezierMenuItem(
          value: summary.isArchived
              ? ConversationMenuAction.unarchive
              : ConversationMenuAction.archive,
          label: summary.isArchived ? '恢复归档' : '归档',
          icon: Icons.archive_outlined,
        ),
        const BezierMenuItem(
          value: ConversationMenuAction.export,
          label: '导出',
          icon: Icons.ios_share,
        ),
        BezierMenuItem(
          value: ConversationMenuAction.trash,
          label: running ? '停止分析并移入最近删除' : '移入最近删除',
          icon: Icons.delete_outline,
          danger: true,
          dividerBefore: true,
        ),
      ],
      if (inTrash) ...[
        const BezierMenuItem(
          value: ConversationMenuAction.restore,
          label: '恢复',
          icon: Icons.restore,
        ),
        const BezierMenuItem(
          value: ConversationMenuAction.deletePermanently,
          label: '永久删除',
          icon: Icons.delete_forever,
          danger: true,
          dividerBefore: true,
        ),
      ],
    ];
    final selected = await showBezierMenu<ConversationMenuAction>(
      context: context,
      globalPosition: globalPosition,
      items: items,
    );
    if (!mounted || selected == null) return;
    await _runConversationAction(id, summary, selected);
  }

  Future<void> _runConversationAction(String id, ConversationSummary summary,
      ConversationMenuAction action) async {
    switch (action) {
      case ConversationMenuAction.open:
        await c.openConversation(id);
      case ConversationMenuAction.rename:
        await _renameConversation(summary);
      case ConversationMenuAction.pin:
      case ConversationMenuAction.unpin:
        await c.setPinned(id, action == ConversationMenuAction.pin);
      case ConversationMenuAction.archive:
      case ConversationMenuAction.unarchive:
        final archive = action == ConversationMenuAction.archive;
        if (archive && c.hasActiveRun(id)) {
          final go = await _confirm(
            title: '停止分析并归档？',
            body: '这个会话正在分析。归档会先停止分析，迟到结果不会写回。',
            confirm: '停止并归档',
          );
          if (!go) return;
        }
        await c.setArchived(id, archive);
      case ConversationMenuAction.export:
        await _exportConversation(summary);
      case ConversationMenuAction.trash:
        final running = c.hasActiveRun(id);
        final go = await _confirm(
          title: running ? '停止分析并移入最近删除？' : '移入最近删除？',
          body: running
              ? '这个会话正在分析。继续会停止分析，迟到结果不会恢复该会话；之后可在“回收”中恢复。'
              : '会话会移到“回收”，可随时恢复；不会立即删除文件。',
          confirm: running ? '停止并移入回收' : '移入回收',
        );
        if (!go) return;
        await c.moveToTrash(id);
      case ConversationMenuAction.restore:
        await c.restoreFromTrash(id);
      case ConversationMenuAction.deletePermanently:
        final go = await _confirm(
          title: '永久删除“${summary.displayTitle}”？',
          body: '主文件、备份、临时文件和无人引用的附件都会删除，且无法恢复。'
              '你自己另存的导出文件不受影响。',
          confirm: '永久删除',
          danger: true,
        );
        if (!go) return;
        await c.permanentlyDelete(id);
    }
    if (!mounted) return;
    final message = c.statusMessage ?? c.errorMessage ?? '完成';
    final kind = _inferNoticeKind(message);
    _showNotice(
      kind: kind,
      message: message,
      autoDismiss: kind == AppNoticeKind.error || kind == AppNoticeKind.warning
          ? null
          : const Duration(seconds: 4),
      conversationScoped: true,
      suppressStatusText: c.statusMessage,
      suppressErrorText: c.errorMessage,
    );
    _rootFocus.requestFocus();
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirm,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(body,
              style: const TextStyle(fontSize: 12.5, height: 1.6)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _renameConversation(ConversationSummary summary) async {
    final controller = TextEditingController(text: summary.meta.customTitle ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名会话', style: TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('conversation-rename-field'),
              controller: controller,
              autofocus: true,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '自定义标题',
                hintText: '留空恢复自动标题',
              ),
            ),
            Text('自动标题：${summary.title}',
                style:
                    TextStyle(fontSize: 11, color: TsColors.textFaint)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    await c.renameConversation(summary.id, value);
    if (!mounted) return;
    _showNotice(
      kind: AppNoticeKind.success,
      message: c.statusMessage ?? '已更新标题',
      autoDismiss: const Duration(seconds: 4),
      conversationScoped: true,
      suppressStatusText: c.statusMessage,
    );
  }

  Future<void> _exportConversation(ConversationSummary summary) async {
    final safe = summary.displayTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final controller = TextEditingController(
      text: '${_defaultDir()}\\$safe.md',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出会话历史', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '保存路径'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('导出')),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    final error = await c.exportConversation(summary.id, path);
    if (!mounted) return;
    _showSnack(error == null ? '已导出到 $path' : '导出失败：$error');
  }

  Future<void> _showMaterials() async {
    final conv = c.conversation;
    if (conv == null) return;
    final materials =
        conv.messages.where((m) => m.role == MessageRole.user).toList();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('材料与补充记录', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 600,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('附件（${conv.attachments.length}）',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TsColors.textPrimary)),
                  const SizedBox(height: 4),
                  if (conv.attachments.isEmpty)
                    Text('没有附件记录',
                        style: TextStyle(
                            fontSize: 11.5, color: TsColors.textFaint))
                  else
                    for (final a in conv.attachments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                            '• ${a.label} · ${a.kind} · ${a.byteLength} 字节',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: TsColors.textSecondary)),
                      ),
                  const SizedBox(height: 12),
                  Text('提交的材料（${materials.length}）',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TsColors.textPrimary)),
                  const SizedBox(height: 4),
                  if (materials.isEmpty)
                    Text('没有可用的材料记录；旧版数据可能未保存历史。',
                        style: TextStyle(
                            fontSize: 11.5, color: TsColors.textFaint))
                  else
                    for (final m in materials) ...[
                      Text(m.at.toLocal().toString(),
                          style: TextStyle(
                              fontSize: 10.5, color: TsColors.textFaint)),
                      const SizedBox(height: 2),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: bezierDecoration(
                          color: TsColors.surfaceAlt,
                          radius: 7,
                        ),
                        child: Text(m.text,
                            maxLines: 12,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                height: 1.5,
                                color: TsColors.textSecondary)),
                      ),
                    ],
                  Text('失败/取消状态只在当前运行期间显示，旧数据没有持久记录；'
                      '这里不会虚构历史结果。',
                      style: TextStyle(
                          fontSize: 11, height: 1.5, color: TsColors.textFaint)),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _exportAllHistory() async {
    final controller = TextEditingController(
      text: '${_defaultDir()}\\TaskScheduler-全部会话历史.md',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出全部会话历史', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '保存路径'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('导出')),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    final error = await c.exportAllHistory(path);
    if (!mounted) return;
    _showSnack(error == null ? '已导出到 $path' : '导出失败：$error');
  }

  Future<void> _export({required bool diagnostics}) async {
    final controller = TextEditingController(
      text: diagnostics
          ? '${_defaultDir()}\\任务计划-诊断.json'
          : '${_defaultDir()}\\任务计划.txt',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(diagnostics ? '导出结构化诊断 JSON' : '导出任务计划 TXT'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(labelText: '保存路径'),
              ),
              const SizedBox(height: 8),
              Text(
                diagnostics
                    ? '诊断文件保留内部评分与权重，供排查使用，不要当作日常交付物。'
                    : '日常导出的 TXT 只包含任务事实与自然语言安排原因，不含评分与公式。',
                style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    final error = diagnostics
        ? await c.exportDiagnostics(path)
        : await c.exportUserText(path);
    if (!mounted) return;
    _showNotice(
      kind: error == null ? AppNoticeKind.success : AppNoticeKind.error,
      message: error == null ? '已导出到 $path' : '导出失败：$error',
      autoDismiss: error == null ? const Duration(seconds: 5) : null,
    );
  }

  String _defaultDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$home\\Documents';
  }
}

class _Splitter extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback? onReset;

  const _Splitter({required this.onDrag, this.onReset});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '拖动调整列表宽度；双击恢复默认',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          onDoubleTap: onReset,
          child: Container(
            width: 7,
            color: TsColors.surface,
            child: Center(
              child: Container(width: 1, color: TsColors.border),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartHeader extends StatelessWidget {
  final ChartMode mode;
  final void Function(ChartMode) onChanged;
  final DisplaySnapshot snapshot;

  const _ChartHeader({
    required this.mode,
    required this.onChanged,
    required this.snapshot,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
      child: Row(
        children: [
          const Text('依赖视图',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          // 计数是“可以截断”的说明文字：窄窗口 / 1.5 倍字号下必须让位给右侧的视图
          // 切换器，而不是把整行撑出横向溢出（0.2.1 在 960–1040 就是这样溢出的）。
          Expanded(
            child: Text(
              '${snapshot.tasks.length} 个任务 · ${snapshot.order.length} 个进入建议顺序',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
            ),
          ),
          const SizedBox(width: 8),
          BezierSegments(
            height: 30,
            itemWidth: 88,
            items: const [
              BezierSegmentItem('依赖图',
                  icon: Icons.account_tree_outlined),
              BezierSegmentItem('甘特图',
                  icon: Icons.view_timeline_outlined),
            ],
            selected: mode.index,
            onChanged: (index) => onChanged(ChartMode.values[index]),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool chart;

  const _EmptyState({this.chart = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              chart ? Icons.account_tree_outlined : Icons.playlist_add_check,
              size: 34,
              color: TsColors.border,
            ),
            const SizedBox(height: 10),
            Text(
              chart
                  ? '分析完成后，这里显示依赖图 / 相对累计工时甘特图'
                  : '把材料粘贴到底部输入框，或添加文本文件后开始分析',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: TsColors.textFaint, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseDetailIntent extends Intent {
  const _CloseDetailIntent();
}

class _NewSessionIntent extends Intent {
  const _NewSessionIntent();
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _AddFileIntent extends Intent {
  const _AddFileIntent();
}

class _ConversationMenuIntent extends Intent {
  const _ConversationMenuIntent();
}

class _FocusComposerIntent extends Intent {
  const _FocusComposerIntent();
}

class _SearchConversationsIntent extends Intent {
  const _SearchConversationsIntent();
}

class _ToggleChartIntent extends Intent {
  const _ToggleChartIntent();
}

class _ToggleSidebarIntent extends Intent {
  const _ToggleSidebarIntent();
}

class _StopAnalysisIntent extends Intent {
  const _StopAnalysisIntent();
}

/// 折叠形态下顶/底带里的同宽占位（与 [SidebarRail] 一样 40 DIP 宽）。
///
/// 它只画侧栏背景与右边框，**不**放展开按钮：0.2.1 的截图里上/中/下三个重复的
/// 展开图标就是三条带各放了一个 [SidebarRail] 造成的；现在整个折叠状态只有中间
/// 带那一个展开入口，顶/底带只负责让右侧内容不横向跳动。
class _SidebarRailSpacer extends StatelessWidget {
  const _SidebarRailSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kRailWidth,
      decoration: BoxDecoration(
        color: TsColors.sidebar,
        border: Border(right: BorderSide(color: TsColors.border)),
      ),
    );
  }
}

/// 折叠形态的底部带：保留有真实语义的账户入口（打开设置/账户页）。
///
/// 它不是折叠开关——不展开侧栏，所以不会与唯一的 rail 入口重复。常驻侧栏展开时
/// 账户入口在 [SidebarBottomBand] 里（完整用户菜单）。
class _CollapsedSidebarFooterBand extends StatelessWidget {
  const _CollapsedSidebarFooterBand({
    super.key,
    required this.onOpenSettings,
  });

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: kRailWidth,
      decoration: BoxDecoration(
        color: TsColors.sidebar,
        border: Border(right: BorderSide(color: TsColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(5, 0, 5, 10),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: IconButton(
          key: const Key('sidebar-collapsed-account'),
          tooltip: '账户与设置',
          onPressed: onOpenSettings,
          style: TsButtons.icon(size: 28),
          icon: const Icon(Icons.person_outline, size: 16),
        ),
      ),
    );
  }
}
