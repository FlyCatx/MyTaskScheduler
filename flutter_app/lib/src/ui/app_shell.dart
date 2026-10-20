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
import '../state/settings_controller.dart';
import 'calendar_gantt.dart';
import 'calendar_settings_dialog.dart';
import 'composer.dart';
import 'desktop_window.dart';
import './widgets/bezier_ui.dart';
import './widgets/bezier_menu.dart';
import 'dag_graph.dart';
import 'detail_popup.dart';
import 'gantt_chart.dart';
import 'history_panel.dart';
import 'model_selection_dialog.dart';
import 'notes_panel.dart';
import 'settings_dialog.dart';
import './widgets/status_strip.dart';
import 'summary_bar.dart';
import 'task_edit_dialog.dart';
import 'task_list.dart';
import 'theme.dart';
import 'title_bar.dart';
import 'user_menu.dart';

enum ChartMode { tree, gantt }

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
  bool _showHistory = true;
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
    _window.attach().then((_) {
      if (mounted) _window.setCloseGuard(true);
    });
  }

  /// 统一关闭流程：先落盘必要数据，再真正销毁窗口。
  Future<void> _handleWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await c.flushPendingWrites();
    } catch (_) {
      // 即使落盘失败也要让用户能关闭窗口；失败信息已经由存储层记录。
    }
    await _window.confirmClose();
    _closing = false;
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    s.removeListener(_onSettingsChanged);
    c.interaction.removeListener(_onControllerChanged);
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
    setState(() {});
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  /// In-app completion/failure notice. The 120-second reminder is a *request control*
  /// and deliberately not affected by these preferences.
  void _notifyRunFinished() {
    final prefs = s.prefs;
    final status = c.statusMessage ?? '';
    final error = c.errorMessage;
    if (status.contains('已取消')) return;
    final succeeded = status.startsWith('已生成新版本');
    if (succeeded && !prefs.notifyOnSuccess) return;
    if (!succeeded && error == null) return;
    if (!succeeded && !prefs.notifyOnFailure) return;
    final message = succeeded
        ? '分析完成：已生成新版本'
        : '分析失败：${_short(error ?? status)}';
    final conversationId = c.conversation?.id;
    var systemNoticeFailed = false;
    if (prefs.notifySystem && conversationId != null) {
      final gw = c.gateway;
      try {
        final title = succeeded ? 'TaskScheduler · 分析完成' : 'TaskScheduler · 分析失败';
        final body = succeeded
            ? '${c.conversation?.listTitle ?? '会话'}：已生成新版本'
            : '${c.conversation?.listTitle ?? '会话'}：$message';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            systemNoticeFailed ? '$message（系统通知不可用，已仅显示应用内提醒）' : message,
            maxLines: 3,
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    });
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

    return Shortcuts(
      shortcuts: _buildShortcuts(),
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseDetailIntent: CallbackAction<_CloseDetailIntent>(onInvoke: (_) {
            c.interaction.closeDetail();
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
            setState(() => _showHistory = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _searchFocus.requestFocus();
            });
            return null;
          }),
          _ToggleChartIntent: CallbackAction<_ToggleChartIntent>(onInvoke: (_) {
            _toggleChart();
            return null;
          }),
          _ToggleSidebarIntent:
              CallbackAction<_ToggleSidebarIntent>(onInvoke: (_) {
            setState(() => _showHistory = !_showHistory);
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
              final wide = constraints.maxWidth >= 940;
              if (!wide) _showHistory = false;
              final showSidebar = _showHistory && wide;
              /*
               * Three full-width bands instead of two independent columns:
               *   top    — sidebar title | summary bar      (same height)
               *   middle — conversation list | tasks + chart + notes
               *   bottom — storage hint | composer          (same height)
               * Putting both sides of a band in ONE Row is what actually makes the
               * heights match; two Columns would drift apart as content changes.
               */
              return Column(
                children: [
                  // 自绘标题栏：替代 Windows 原生标题栏的可见部分；拖动/吸附/缩放
                  // 仍由原生 WM_NCHITTEST 处理。
                  AppTitleBar(
                    window: _window,
                    sidebarVisible: showSidebar,
                    onToggleSidebar: () =>
                        setState(() => _showHistory = !_showHistory),
                    onOpenAbout: _openAbout,
                    onExit: _exitApplication,
                  ),
                  SizedBox(
                    // 顶栏随文字缩放增高，1.5 倍字号下标题与副标题不会纵向溢出。
                    height: TsSizes.textScaleAwareHeight(context, kTopBarHeight),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showSidebar)
                          HistorySidebarHeader(
                            onNew: _onNewConversation,
                            onCollapse: () => setState(() => _showHistory = false),
                          )
                        else
                          SidebarRail(onExpand: () => setState(() => _showHistory = true)),
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
                        if (showSidebar)
                          HistorySidebarList(
                            summaries: c.searchSummaries(
                              _conversationQuery,
                              archived:
                                  _listMode == ConversationListMode.archived,
                              deleted:
                                  _listMode == ConversationListMode.trash,
                            ),
                            currentId: conv?.id,
                            mode: _listMode,
                            query: _conversationQuery,
                            onQuery: (value) =>
                                setState(() => _conversationQuery = value),
                            onMode: (mode) => setState(() => _listMode = mode),
                            onOpen: (id) => c.openConversation(id),
                            onMenu: _showConversationMenu,
                            searchFocusNode: _searchFocus,
                          )
                        else
                          SidebarRail(onExpand: () => setState(() => _showHistory = true)),
                        Expanded(
                          child: Column(
                            children: [
                              StatusStrip(
                                // Location fallbacks are silent now; only the
                                // "nothing writable" case is a real warning.
                                storageNotice: c.storageNotice,
                                errorMessage: c.errorMessage,
                                statusMessage: c.statusMessage,
                                onDismissError: c.clearMessages,
                              ),
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showSidebar)
                          SidebarBottomBand(
                            child: UserMenuButton(
                              onOpenSettings: _openSettings,
                            ),
                          )
                        else
                          SidebarRail(
                              onExpand: () => setState(() => _showHistory = true)),
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
                              onSend: () => c.startAnalysis(),
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
            }),
          ),
        ),
      ),
    );
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
                                        calendar: c.calendar,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(c.errorMessage ?? '本次编辑未通过校验，已保留原计划'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      _offerUndo();
    }
  }

  Future<void> _toggleTask(String id) async {
    final ok = await c.toggleCompletion(id);
    if (ok && mounted) _offerUndo();
  }

  void _offerUndo() {
    if (!c.canUndo) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(c.undoLabel ?? '已修改'),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          await c.undoLast();
          if (mounted) _showSnack(c.statusMessage ?? '已撤销');
        },
      ),
    ));
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(c.errorMessage ?? '条件状态更新未通过校验'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // -------------------------------------------------------------- actions

  Future<void> _onNewConversation() async {
    await c.createConversation();
    _draft.clear();
    _rootFocus.requestFocus();
  }

  /// Opens the settings window. Unsaved changes are handled inside the dialog.
  Future<void> _openSettings({SettingsSection initial = SettingsSection.account}) async {
    await showSettingsDialog(
      context,
      controller: s,
      initial: initial,
      storageSource: c.storageSource,
      storageMemoryOnly: !c.storageIsPersistent,
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
    final settings = c.viewVersion?.calendar.settings ?? c.calendar.settings;
    final timetable = c.currentTimetable();
    final result = await showCalendarSettingsDialog(
      context,
      settings: settings,
      now: DateTime.now(),
      timetable: timetable,
      weekStartsOn: c.weekStartsOn,
      initialMode: c.defaultCalendarEditor,
      defaultUnavailableRanges: c.defaultUnavailableRanges,
      taskNames: c.taskNamesById,
      useDefaultTimetable: conv?.calendarDraft == null && c.viewVersion == null,
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
  Future<void> _addFile() async {
    final gw = c.gateway;
    if (gw == null) {
      _showSnack('原生桥接不可用，无法打开文件对话框');
      return;
    }
    List<String> paths;
    try {
      paths = await gw.pickTextFiles();
    } catch (e) {
      _showSnack('打开文件对话框失败：$e');
      return;
    }
    if (paths.isEmpty) return; // user cancelled

    final failures = <String>[];
    var added = 0;
    for (final path in paths) {
      final ok = await c.addTextFile(path);
      if (ok) {
        added++;
      } else {
        final name = path.split(Platform.pathSeparator).last;
        failures.add('$name：${c.errorMessage ?? '无法添加'}');
      }
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      if (added > 1) _showSnack('已添加 $added 个文件');
      return;
    }
    _showSnack(failures.length == 1 && added == 0
        ? failures.single
        : '已添加 $added 个，${failures.length} 个失败：${failures.join('；')}');
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
    _showSnack(c.statusMessage ?? c.errorMessage ?? '完成');
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
    if (mounted) _showSnack(c.statusMessage ?? '已更新标题');
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

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? '已导出到 $path' : '导出失败：$error'),
        behavior: SnackBarBehavior.floating,
      ),
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
          Text(
            '${snapshot.tasks.length} 个任务 · ${snapshot.order.length} 个进入建议顺序',
            style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
          ),
          const Spacer(),
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
