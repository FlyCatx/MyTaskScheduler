// 执行回顾对话框（R3-R）。
//
// 展示“今日/本周/自定义日期”的执行反馈：已确认投入、未知/待校正、完成任务数、
// 延期任务、估计与实际差异、未安排的剩余工作；每个聚合值都能展开到任务与原始
// 执行记录。统计口径由 EffortReviewService / effort_stats 决定，本对话框只展示。
//
// 导出钩子可选：`onExport(name, csv, suggestedPath)` 返回 true 表示导出成功。
// 未注入时隐藏导出按钮（不伪造“已导出”），也不会自动写文件或调用模型。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/execution/effort_review_service.dart';
import '../../state/execution/effort_stats.dart';
import '../theme.dart';
import '../widgets/bezier_menu.dart';
import '../widgets/bezier_ui.dart';
import '../widgets/date_range_picker.dart';

class EffortReviewDialog extends StatefulWidget {
  const EffortReviewDialog({
    super.key,
    required this.service,
    required this.tasks,
    required this.conversations,
    this.initialPreset = EffortReviewPreset.thisWeek,
    this.onExport,
    this.initialConversationId,
    this.initialTaskId,
    this.autoCompletedTaskIds = const <String>{},
  });

  final EffortReviewService service;

  /// 当前计划里的任务快照（由接线方构造）。
  final List<ExecutionTaskInfo> tasks;
  final List<ExecutionConversationInfo> conversations;
  final EffortReviewPreset initialPreset;

  /// 导出钩子：`name` 是展示名，`csv` 是完整内容（含 BOM），`suggestedPath` 是
  /// 建议文件名。返回 false 表示用户取消/写入失败。
  final Future<bool> Function(String name, String csv, String suggestedPath)?
      onExport;

  final String? initialConversationId;
  final String? initialTaskId;

  /// “到期自动完成”的任务 id（0.5.0 任务 13 的执行结果来源；由接线方注入）。
  /// 只影响展示：命中时在任务折叠行显示“到期自动完成”徽标；默认空集合保持
  /// 旧调用方/旧数据完全不变。
  final Set<String> autoCompletedTaskIds;

  static Future<void> show(
    BuildContext context, {
    required EffortReviewService service,
    required List<ExecutionTaskInfo> tasks,
    required List<ExecutionConversationInfo> conversations,
    EffortReviewPreset initialPreset = EffortReviewPreset.thisWeek,
    Future<bool> Function(String name, String csv, String suggestedPath)?
        onExport,
    String? initialConversationId,
    String? initialTaskId,
    Set<String>? autoCompletedTaskIds,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => EffortReviewDialog(
        service: service,
        tasks: tasks,
        conversations: conversations,
        initialPreset: initialPreset,
        onExport: onExport,
        initialConversationId: initialConversationId,
        initialTaskId: initialTaskId,
        autoCompletedTaskIds:
            autoCompletedTaskIds ?? const <String>{},
      ),
    );
  }

  @override
  State<EffortReviewDialog> createState() => _EffortReviewDialogState();
}

class _EffortReviewDialogState extends State<EffortReviewDialog> {
  /// 自定义范围逆序时的就地错误（保留草稿，只阻止刷新）。
  static const String _reversedRangeMessage = '结束日期须等于或晚于开始日期';

  /// 未知实际耗时的展示值（未知 ≠ 0，但不把“未知”堆到每个数字上）。
  static const String _unknownActualLabel = '—';

  /// 从未产生执行事实时的展示文案。
  static const String _noRecordLabel = '暂无执行记录';

  late EffortReviewPreset _preset;
  String? _conversationId;
  String? _taskId;

  /// 本地“今天”（注入 service 的时区/时钟，测试可复现）。
  late final DateTime _today;

  /// 已应用到报告的日期范围；标题/报告/CSV 只读它。
  late DateTime _appliedFrom;
  late DateTime _appliedTo;

  /// 「自定义」字段的草稿；只有点「应用」才写入已应用值。
  late DateTime _draftFrom;
  late DateTime _draftTo;

  final ScrollController _dailyScroll = ScrollController();
  EffortReviewReport? _report;
  String? _rangeError;
  String? _exportMessage;

  /// 卡片内边距：标题行左侧与正文一致；右侧收窄到关闭按钮的热区边上，
  /// 关闭按钮因此锚定在卡片右内缘（见 [_titleRow]）。
  static const double _contentPaddingH = 20;

  /// 关闭按钮（28 px 热区）到卡片右边缘的主题内边距。
  static const double _titleRightInset = 8;

  /// 日期范围的宽度上限（占标题行可用宽度的比例）：普通宽度下完整显示
  /// “本周 2026-11-02 ~ 2026-11-08”，同时保证左侧标题永远有可见位置。
  static const double _rangeMaxWidthRatio = 0.66;

  /// 低于这个可用宽度时，日期不再挤在标题右侧，而是换到标题下方右对齐。
  static const double _titleNarrowBreakpoint = 440;

  @override
  void initState() {
    super.initState();
    _preset = widget.initialPreset;
    _conversationId = widget.initialConversationId;
    _taskId = widget.initialTaskId;
    _today = EffortReviewService.todayLocalDate(
      widget.service.nowUtc,
      widget.service.localTime,
    );
    _appliedFrom = _today;
    _appliedTo = _today;
    _draftFrom = _today;
    _draftTo = _today;
    _recompute();
  }

  @override
  void dispose() {
    _dailyScroll.dispose();
    super.dispose();
  }

  /// 用“已应用范围”生成报告。草稿只影响字段显示，不进入这里。
  void _recompute() {
    final tasks = widget.tasks;
    final conversations = widget.conversations;
    try {
      switch (_preset) {
        case EffortReviewPreset.today:
          _report = widget.service.today(
            tasks: tasks,
            conversations: conversations,
            conversationId: _conversationId,
            taskId: _taskId,
          );
        case EffortReviewPreset.thisWeek:
          _report = widget.service.thisWeek(
            tasks: tasks,
            conversations: conversations,
            conversationId: _conversationId,
            taskId: _taskId,
          );
        case EffortReviewPreset.custom:
          _report = widget.service.custom(
            tasks: tasks,
            conversations: conversations,
            fromLocalDate: _appliedFrom,
            toLocalDate: _appliedTo,
            conversationId: _conversationId,
            taskId: _taskId,
          );
      }
      _rangeError = null;
    } catch (e) {
      _report = null;
      _rangeError = '生成执行回顾失败：$e';
    }
  }

  /// 切换「今日/本周/自定义」。切到自定义只重置草稿、不刷新报告——应用前的
  /// 标题/报告/CSV 必须继续显示上一次已生效的范围。
  void _changePreset(int index) {
    final next = EffortReviewPreset.values[index];
    setState(() {
      _preset = next;
      _rangeError = null;
      if (next == EffortReviewPreset.custom) {
        _draftFrom = _appliedFrom;
        _draftTo = _appliedTo;
        return;
      }
      _recompute();
    });
  }

  void _onDraftFromChanged(DateTime date) {
    setState(() {
      _draftFrom = date;
      _rangeError =
          _draftTo.isBefore(_draftFrom) ? _reversedRangeMessage : null;
    });
  }

  void _onDraftToChanged(DateTime date) {
    setState(() {
      _draftTo = date;
      _rangeError =
          _draftTo.isBefore(_draftFrom) ? _reversedRangeMessage : null;
    });
  }

  /// 只有合法草稿才能应用：逆序时保留输入并就地报错，阻止刷新。
  void _applyDraft() {
    if (_draftTo.isBefore(_draftFrom)) {
      setState(() => _rangeError = _reversedRangeMessage);
      return;
    }
    setState(() {
      _appliedFrom = _draftFrom;
      _appliedTo = _draftTo;
      _rangeError = null;
      _recompute();
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final media = MediaQuery.of(context);
    // 与 OCR 主弹窗/设置弹窗一致：一个居中卡片，按可用窗口算上限，最小尺寸下
    // 仍能操作（内容在极矮窗口时整体滚动，见 [_content]）。
    final width = math.min(720.0, math.max(420.0, media.size.width - 64));
    final height = math.min(640.0, math.max(360.0, media.size.height - 64));
    return Dialog(
      key: const Key('effort-review-dialog'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const BezierRoundedRectangleBorder(radius: 16),
      child: SizedBox(
        key: const Key('effort-review-card'),
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(report),
            Divider(height: 1, color: TsColors.border),
            Expanded(child: _content(context, report)),
            Divider(height: 1, color: TsColors.border),
            _footer(report),
          ],
        ),
      ),
    );
  }

  /// 标题行：左“图标 + 执行回顾”，右侧“日期范围 + 关闭”。
  ///
  /// 以卡片自身的实际约束排版（不写绝对坐标）：
  /// * 关闭按钮是行末固定宽控件，右侧只留 [_titleRightInset]，因此锚定在卡片
  ///   右内缘。原先左侧用 Flexible、右侧用 Expanded，Flexible 没用满的份额留在
  ///   行尾，关闭按钮就被推离右边缘（用户截图里的黄框问题）。
  /// * 普通宽度：标题 Expanded 吃掉全部空余宽度；日期有 [_rangeMaxWidth] 上限，
  ///   完整显示“本周 2026-11-02 ~ 2026-11-08”。
  /// * 极窄（可用宽度 < [_titleNarrowBreakpoint]）：日期换到标题下方并右对齐。
  /// * 标题、日期、关闭三个热区彼此独立（日期是只读文本，关闭是 28 px 热区）。
  Widget _titleRow(EffortReviewReport? report) {
    final rangeLabel = report?.range.label ?? '';
    final rangeStyle = TextStyle(fontSize: 11.5, color: TsColors.textSecondary);
    final titleText = Text(
      '执行回顾',
      key: const Key('effort-review-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 15, color: TsColors.textPrimary),
    );
    Widget rangeText() => Text(
          rangeLabel,
          key: const Key('effort-review-range'),
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: rangeStyle,
        );
    final closeButton = TsCloseButton(
      key: const Key('effort-review-close-icon'),
      tooltip: '关闭',
      size: 28,
      onPressed: () => Navigator.of(context).pop(),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          _contentPaddingH, 10, _titleRightInset, 8),
      child: LayoutBuilder(builder: (context, constraints) {
        final available = constraints.maxWidth;
        final titleIcon = Icon(Icons.insights_outlined,
            size: 17, color: TsColors.accent);
        if (available < _titleNarrowBreakpoint) {
          // 极窄：日期换行到标题下方、右对齐；关闭仍固定在行的最右端。
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleIcon,
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    titleText,
                    if (rangeLabel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: rangeText(),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              closeButton,
            ],
          );
        }
        return Row(
          children: [
            titleIcon,
            const SizedBox(width: 8),
            Expanded(child: titleText),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: available * _rangeMaxWidthRatio,
              ),
              child: rangeText(),
            ),
            const SizedBox(width: 6),
            closeButton,
          ],
        );
      }),
    );
  }

  /// 中间正文：筛选 → 统计 → 每日数据 → 任务明细，整块可滚动（页面固定底部
  /// 动作）。用 CustomScrollView 而不是“固定头部 + Expanded(ListView)”：
  /// 窄窗/1.5 倍字号下头部行数会变多，固定头部会把列表压成 0 高甚至溢出；
  /// 单一滚动区保证长范围、表单错误、空状态和展开任务都不会出现截行或
  /// 不可滚达区域，同时任务明细仍然是懒构建的 sliver 列表。
  Widget _content(BuildContext context, EffortReviewReport? report) {
    final header = <Widget>[
      _buildFilters(context, report),
      const SizedBox(height: 8),
      if (report != null) _buildSummary(context, report),
      if (report?.rangeNote != null)
        _noteText(report!.rangeNote!,
            key: const Key('effort-review-range-note')),
      if (report?.completionNote != null)
        _noteText(report!.completionNote!,
            key: const Key('effort-review-completion-note')),
      if (_rangeError != null)
        _noteText(_rangeError!,
            key: const Key('effort-review-range-error'),
            color: TsColors.blocked),
      if (report != null && report.daily.isNotEmpty) ...[
        const SizedBox(height: 6),
        _buildDaily(context, report),
      ],
      const SizedBox(height: 8),
    ];
    return CustomScrollView(
      key: const Key('effort-review-task-list'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
              _contentPaddingH, 12, _contentPaddingH, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: header,
            ),
          ),
        ),
        if (report == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_contentPaddingH, 32,
                  _contentPaddingH, 24),
              child: Center(
                child: Text(
                  '请选择有效的日期范围',
                  key: const Key('effort-review-empty'),
                  style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                ),
              ),
            ),
          )
        else if (report.tasks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_contentPaddingH, 32,
                  _contentPaddingH, 24),
              child: Center(
                child: Text(
                  _noRecordLabel,
                  key: const Key('effort-review-empty'),
                  style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                _contentPaddingH, 0, _contentPaddingH, 10),
            sliver: SliverList.builder(
              itemCount: report.tasks.length,
              itemBuilder: (context, index) =>
                  _taskTile(context, report, report.tasks[index]),
            ),
          ),
      ],
    );
  }

  /// 底部动作固定：导出回执（有的话）与 导出 CSV / 关闭 永远不随正文滚动。
  /// 使用统一的 [TsDialogActions]：导出是左端轻量动作，关闭是右端次要按钮。
  Widget _footer(EffortReviewReport? report) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_exportMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(_contentPaddingH, 8, _contentPaddingH, 0),
            child: Text(
              _exportMessage!,
              key: const Key('effort-review-export-message'),
              style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
            ),
          ),
        TsDialogActions(
          actions: [
            if (widget.onExport != null)
              TsDialogAction(
                key: const Key('effort-review-export'),
                label: '导出 CSV',
                icon: Icons.download_outlined,
                role: TsDialogActionRole.leading,
                onPressed: report == null ? null : _export,
              ),
            TsDialogAction(
              key: const Key('effort-review-close'),
              label: '关闭',
              role: TsDialogActionRole.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context, EffortReviewReport? report) {
    final taskOptions = widget.tasks
        .where((t) =>
            _conversationId == null || t.conversationId == _conversationId)
        .toList(growable: false);
    return LayoutBuilder(builder: (context, constraints) {
      // 下拉框宽度按实际可用宽度算上限（原来的 150/170 固定宽度在窄窗或长名称下
      // 会把选项文字裁掉）。窄窗时整组换行，两项各占一行。
      final available =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 640.0;
      final dropdownWidth = available < 520
          ? (available * 0.60).clamp(120.0, 240.0)
          : (available * 0.36).clamp(160.0, 280.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 与设置弹窗/OCR 弹窗同一个分段控件：不再使用 Material SegmentedButton。
              BezierSegments(
                key: const Key('effort-review-presets'),
                height: 30,
                itemWidth: 64,
                items: const [
                  BezierSegmentItem('今日'),
                  BezierSegmentItem('本周'),
                  BezierSegmentItem('自定义'),
                ],
                selected: _preset.index,
                onChanged: _changePreset,
              ),
              if (_preset == EffortReviewPreset.custom) ...[
                SizedBox(
                  width: 162,
                  child: DatePickerField(
                    key: const Key('effort-review-from'),
                    value: _draftFrom,
                    label: '开始日期',
                    today: _today,
                    onChanged: _onDraftFromChanged,
                  ),
                ),
                SizedBox(
                  width: 162,
                  child: DatePickerField(
                    key: const Key('effort-review-to'),
                    value: _draftTo,
                    label: '结束日期',
                    today: _today,
                    onChanged: _onDraftToChanged,
                  ),
                ),
                TextButton(
                  key: const Key('effort-review-apply'),
                  style: TsButtons.inline(),
                  // 逆序草稿直接禁用「应用」：保留输入、就地报错，阻止刷新。
                  onPressed:
                      _draftTo.isBefore(_draftFrom) ? null : _applyDraft,
                  child: const Text('应用'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown<String?>(
                key: const Key('effort-review-filter-conversation'),
                label: '会话',
                value: _conversationId,
                width: dropdownWidth,
                options: <(String?, String)>[
                  (null, '全部会话'),
                  for (final conversation in widget.conversations)
                    (conversation.id, conversation.title),
                ],
                onChanged: (value) => setState(() {
                  _conversationId = value;
                  if (_taskId != null &&
                      !taskOptions.any((t) => t.taskId == _taskId)) {
                    _taskId = null;
                  }
                  _recompute();
                }),
              ),
              _dropdown<String?>(
                key: const Key('effort-review-filter-task'),
                label: '任务',
                value: _taskId,
                width: dropdownWidth,
                options: <(String?, String)>[
                  (null, '全部任务'),
                  for (final task in taskOptions) (task.taskId, task.name),
                ],
                onChanged: (value) => setState(() {
                  _taskId = value;
                  _recompute();
                }),
              ),
            ],
          ),
        ],
      );
    });
  }

  /// 有界宽度的统一菜单选择器（0.5.0 任务 02）：按钮里显示省略后的选中项，
  /// 展开后限高滚动、当前项勾选、长名称悬停可读，Esc/键盘/Tab 可用。
  /// 可空值（“全部会话 / 全部任务”）通过 [BezierMenuSelect] 正确上报 null。
  Widget _dropdown<T>({
    required Key key,
    required String label,
    required T value,
    required List<(T, String)> options,
    required double width,
    required ValueChanged<T?> onChanged,
  }) {
    final exists = options.any((option) => option.$1 == value);
    final current = exists
        ? options.firstWhere((option) => option.$1 == value).$2
        : (options.isEmpty ? '—' : options.first.$2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label：',
            style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary)),
        SizedBox(
          width: width,
          child: BezierMenuSelect<T>(
            key: key,
            label: current,
            width: width,
            menuWidth: 320,
            items: <BezierMenuItem<T>>[
              for (final option in options)
                BezierMenuItem<T>(
                  value: option.$1,
                  label: option.$2,
                  selected: option.$1 == value,
                ),
            ],
            onSelected: (selected) => onChanged(selected),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context, EffortReviewReport report) {
    final pendingLabel = report.pendingTotal > Duration.zero
        ? '${formatEffortDuration(report.pendingTotal)}（${report.pendingCorrectionCount} 段）'
        : '无';
    final remaining = report.remainingSuggestionHours;
    final metrics = <(Key, String, String)>[
      (
        const Key('effort-review-confirmed'),
        '已确认投入',
        formatEffortDuration(report.confirmedTotal)
      ),
      (const Key('effort-review-pending'), '待校正', pendingLabel),
      (
        const Key('effort-review-completed'),
        '完成任务',
        '${report.completedTaskCount}'
      ),
      (
        const Key('effort-review-delayed'),
        '延期任务',
        '${report.delayedTasks.length}'
      ),
      (
        const Key('effort-review-done-no-actual'),
        '完成但无实际',
        '${report.doneWithoutActual.length}'
      ),
      (
        const Key('effort-review-unestimated'),
        '未估算',
        '${report.unestimatedTasks.length}'
      ),
      (
        const Key('effort-review-remaining'),
        '建议剩余',
        remaining == null ? kEffortUnknownLabel : '${formatEffortHours(remaining)}（建议）'
      ),
    ];
    final labelStyle =
        TextStyle(fontSize: 11.5, color: TsColors.textSecondary);
    final valueStyle = TextStyle(fontSize: 12, color: TsColors.textPrimary);
    // 每一项本身也按可用宽度封顶：窄窗/1.5 倍字号时值可以换行，最右侧
    // “建议剩余”不会被挤出卡片（Wrap 只负责行间换行，不负责单行内收缩）。
    return LayoutBuilder(builder: (context, constraints) {
      final maxItemWidth =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 640.0;
      return Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          for (final metric in metrics)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxItemWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${metric.$2}：', style: labelStyle),
                  Flexible(
                    child: Text(metric.$3, key: metric.$1, style: valueStyle),
                  ),
                ],
              ),
            ),
        ],
      );
    });
  }

  /// 每日数据：今日/本周按整项换行（7 天全部可读，不出现半露胶囊）；长范围
  /// 改成有界高度内滚动，**不再 take(60)**——服务支持 366 天，第 61 天到末日
  /// 都必须可达。
  Widget _buildDaily(BuildContext context, EffortReviewReport report) {
    final points = report.daily;
    // 按字号放大（Windows 文本缩放最高 1.5×）时胶囊高度同比放大，避免日期与
    // 分钟被裁掉。
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
    final chipHeight = 22 * scale;
    Widget chip(DailyEffortPoint point) => Container(
          key: Key('effort-review-day-${point.localDate}'),
          height: chipHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: TsColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: TsColors.border),
          ),
          // Center(widthFactor: 1) 让胶囊按文字宽度收缩（在 Wrap 里保持“胶囊”
          // 形状），而不是靠 Container.alignment 拉伸成整行宽。
          child: Center(
            widthFactor: 1,
            child: Text(
              '${point.localDate}  ${formatEffortDuration(point.confirmed)}',
              maxLines: 1,
              style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
            ),
          ),
        );
    final chips = <Widget>[for (final point in points) chip(point)];
    // 今日 / 本周（至多 7 天）：直接换行，全部可见、不能半露被裁。
    if (points.length <= 7) {
      return Wrap(
        key: const Key('effort-review-daily'),
        spacing: 6,
        runSpacing: 6,
        children: chips,
      );
    }
    // 长范围：有界高度（最多 3 行胶囊）内纵向滚动，所有日期都可达。
    const visibleRows = 3;
    final maxHeight = visibleRows * chipHeight + (visibleRows - 1) * 6;
    return ConstrainedBox(
      key: const Key('effort-review-daily'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Scrollbar(
        controller: _dailyScroll,
        child: SingleChildScrollView(
          key: const Key('effort-review-daily-scroll'),
          controller: _dailyScroll,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: chips,
          ),
        ),
      ),
    );
  }

  /// 一条任务明细（SliverList 的子项）。副标题不再强制 3 行省略：窄窗或
  /// 1.5 倍字号下需要换行显示完整指标，而不是把“建议剩余”等截掉。
  Widget _taskTile(
      BuildContext context, EffortReviewReport report, TaskEffort task) {
    final records = report.recordsFor(task.taskId);
    // 四种状态按数据区分，不用一句“未知 ≠ 0”概括：
    //   * 从未记录：factsKnown == false → “暂无执行记录 / 实际 —”；
    //   * 范围外有记录：实际已知、范围投入 0 分钟；
    //   * 已确认零投入：实际 0 分钟（仍显示真实的 0）；
    //   * 待校正：标题旁保留醒目标记，展开区仍列待校正时长。
    final rangeLabel = task.factsKnown
        ? '范围投入 ${formatEffortDuration(task.rangeConfirmed)}'
        : _noRecordLabel;
    final plannedDeviation =
        task.plannedStartUtc == null && task.plannedEndUtc == null
            ? ''
            : '｜计划偏差 开始 ${formatEffortHours(task.startDeviationHours)}'
                ' / 结束 ${formatEffortHours(task.endDeviationHours)}';
    final pendingLabel = task.totalPending > Duration.zero
        ? '｜待校正 ${formatEffortDuration(task.totalPending)}'
        : '';
    final subtitleText = '$rangeLabel｜实际 ${_formatActualHours(task.actualHours)}｜'
        '基线 ${formatEffortHours(task.baselineHours)}｜'
        '偏差 ${formatEffortHours(task.deviationHours)}'
        '${task.deviationPercent == null ? '' : '（${formatEffortPercent(task.deviationPercent)}）'}｜'
        '建议剩余 ${formatEffortHours(task.suggestedRemainingHours)}'
        '$plannedDeviation$pendingLabel';
    return ExpansionTile(
          key: Key('effort-review-task-${task.taskId}'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 8, 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  task.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: TsColors.textPrimary),
                ),
              ),
              if (!task.attributed) ...[
                const SizedBox(width: 6),
                _tag('未归属', TsColors.pending),
              ],
              if (task.openCorrectionCount > 0) ...[
                const SizedBox(width: 6),
                _tag('待校正', TsColors.pending),
              ],
              if (widget.autoCompletedTaskIds.contains(task.taskId)) ...[
                const SizedBox(width: 6),
                _tag(
                  '到期自动完成',
                  TsColors.waiting,
                  key: Key(
                      'effort-review-auto-completed-${task.taskId}'),
                ),
              ],
              if (task.isDone) ...[
                const SizedBox(width: 6),
                _tag('已完成', TsColors.done),
              ],
            ],
          ),
          subtitle: Text(
            subtitleText,
            style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
          ),
          children: <Widget>[
            if (records.isEmpty)
              Padding(
                key: Key('effort-review-no-record-${task.taskId}'),
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  _noRecordLabel,
                  style: TextStyle(fontSize: 11, color: TsColors.textSecondary),
                ),
              ),
            for (final effort in records)
              Padding(
                key: Key('effort-record-${effort.record.recordId}'),
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_rangeText(effort)}｜${effort.sourceSummary}｜'
                        '范围 ${formatEffortDuration(confirmedWithin(effort, fromUtc: report.fromUtc, toUtc: report.toUtc, localTime: widget.service.localTime))}'
                        '｜累计 ${formatEffortDuration(effort.confirmedDuration)}'
                        '${effort.pendingDuration > Duration.zero ? '｜待校正 ${formatEffortDuration(effort.pendingDuration)}' : ''}'
                        '${effort.overlapIncludedDuration > Duration.zero ? '｜含明确保留的重叠' : ''}',
                        style: TextStyle(
                            fontSize: 10.5, color: TsColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            if (task.unknownIndicators.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '未知项：${task.unknownIndicators.join('；')}',
                  style: TextStyle(fontSize: 10.5, color: TsColors.pending),
                ),
              ),
          ],
        );
  }

  /// 实际耗时的展示映射（只改界面，不改聚合/CSV 的“未知”空值语义）：
  ///   * 从未产生执行事实 → `—`（未知 ≠ 0）；
  ///   * 已确认投入为 0 → `0 分钟`（真实的零值保留）；
  ///   * 其余按现有小时文案。
  String _formatActualHours(double? hours) {
    if (hours == null) return _unknownActualLabel;
    if (hours == 0) return formatEffortDuration(Duration.zero);
    return formatEffortHours(hours);
  }

  String _rangeText(RecordEffort effort) {
    final localTime = widget.service.localTime;
    final start = effort.firstConfirmedStartUtc;
    final end = effort.lastConfirmedEndUtc;
    String format(DateTime? utc) {
      if (utc == null) return kEffortUnknownLabel;
      final wall = localTime.toLocal(utc);
      final hh = wall.hour.toString().padLeft(2, '0');
      final mm = wall.minute.toString().padLeft(2, '0');
      return '${formatLocalDate(wall)} $hh:$mm';
    }

    return '${format(start)} ~ ${format(end)}';
  }

  Widget _tag(String text, Color color, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }

  Widget _noteText(String text, {Key? key, Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        key: key,
        style: TextStyle(fontSize: 10.5, color: color ?? TsColors.textFaint),
      ),
    );
  }

  Future<void> _export() async {
    final report = _report;
    final hook = widget.onExport;
    if (report == null || hook == null) return;
    final suggested = report.suggestedFileName();
    bool ok;
    try {
      ok = await hook('执行回顾 CSV', report.buildCsv(), suggested);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exportMessage = '导出失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _exportMessage = ok
        ? '已导出执行回顾（含时区、统计范围、指标口径与未知值）'
        : '导出未完成（已取消或写入失败）');
  }
}
