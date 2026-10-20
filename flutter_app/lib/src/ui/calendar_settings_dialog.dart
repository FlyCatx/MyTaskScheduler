// “可用时间与占用时间”编辑框：排程范围、时区、每周可用时间、日期例外、
// 占用/休息时段与拖动吸附步长；模型识别出的约束以“默认不勾选”的候选形式呈现。
//
// 0.1.1 起同一草稿有“手动填写 / 手动绘制”两种编辑方式：分段开关切换，不丢失任何
// 已输入内容；底部为 取消 / 应用 / 保存。应用提交并留在窗口，保存提交后关闭。
//
// 主要函数/类型：showCalendarSettingsDialog、CalendarSettingsResult、CalendarDialogFrame。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/calendar.dart';
import '../model/calendar_proposals.dart';
import '../model/settings.dart';
import '../model/timetable.dart';
import '../state/calendar_constraints.dart';
import '../state/time_ranges.dart';
import './calendar_grid.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

/// Everything the "从材料识别" section needs, supplied by the app layer.
///
/// The dialog deliberately does not know about `AppController` or the native bridge: it
/// asks for a set, shows loading/failure honestly, and can cancel or retry.
class CalendarProposalSource {
  /// Answer computed earlier for the *same* material (free to show again).
  final CalendarProposalSet? cached;

  /// Why asking is not possible right now (e.g. no material yet); shown as text
  /// instead of a button that would fail.
  final String? blockedReason;

  final Future<CalendarProposalOutcome> Function({bool force}) request;

  /// Cancels an in-flight request (no-op when nothing is running).
  final VoidCallback? cancel;

  const CalendarProposalSource({
    this.cached,
    this.blockedReason,
    required this.request,
    this.cancel,
  });
}

/// Result of the dialog: the chosen settings plus, when the user ticked something, the
/// proposals that were applied (used for the status message only).
class CalendarSettingsResult {
  final CalendarSettings settings;
  final int appliedProposals;
  final int skippedProposals;

  /// 0.1.1：编辑后的结构化周时间表；绘图模式的修改也在这里。
  final Timetable? timetable;

  const CalendarSettingsResult({
    required this.settings,
    this.appliedProposals = 0,
    this.skippedProposals = 0,
    this.timetable,
  });
}

/// 打开编辑器。
///
/// [onApply] 只在“应用”时调用：提交成功返回 true，窗口保持打开并把当前状态设为
/// 新的撤销基线；返回 false 时保留草稿并显示错误。
Future<CalendarSettingsResult?> showCalendarSettingsDialog(
  BuildContext context, {
  required CalendarSettings settings,
  required DateTime now,
  CalendarProposalSource? proposals,
  Timetable? timetable,
  int weekStartsOn = 1,
  CalendarEditorMode initialMode = CalendarEditorMode.fill,
  List<UnavailableRange> defaultUnavailableRanges =
      const <UnavailableRange>[],
  Map<String, String> taskNames = const <String, String>{},
  bool useDefaultTimetable = false,
  Future<bool> Function(CalendarSettingsResult result)? onApply,
}) {
  return showDialog<CalendarSettingsResult>(
    context: context,
    builder: (_) => _CalendarSettingsDialog(
      settings: settings,
      now: now,
      proposals: proposals,
      timetable: timetable,
      weekStartsOn: weekStartsOn,
      initialMode: initialMode,
      defaultUnavailableRanges: defaultUnavailableRanges,
      taskNames: taskNames,
      useDefaultTimetable: useDefaultTimetable,
      onApply: onApply,
    ),
  );
}

class _ExceptionRow {
  final TextEditingController date;
  final TextEditingController ranges;
  bool closed;
  _ExceptionRow(CalendarDateException e)
      : date = TextEditingController(text: e.date),
        ranges = TextEditingController(text: formatTimeRanges(e.ranges)),
        closed = e.closed;
  _ExceptionRow.blank()
      : date = TextEditingController(),
        ranges = TextEditingController(),
        closed = true;
  void dispose() {
    date.dispose();
    ranges.dispose();
  }
}

class _OccupancyRow {
  final TextEditingController title;
  final TextEditingController ranges;
  final TextEditingController date;
  String kind;
  int weekday;
  bool provisional;
  _OccupancyRow(CalendarOccupancy o)
      : title = TextEditingController(text: o.title),
        ranges = TextEditingController(text: formatTimeRanges(o.ranges)),
        date = TextEditingController(text: o.date ?? ''),
        kind = o.kind,
        weekday = o.weekday < 1 || o.weekday > 7 ? 1 : o.weekday,
        provisional = o.provisional;
  _OccupancyRow.blank()
      : title = TextEditingController(),
        ranges = TextEditingController(),
        date = TextEditingController(),
        kind = 'course',
        weekday = 1,
        provisional = true;
  void dispose() {
    title.dispose();
    ranges.dispose();
    date.dispose();
  }
}

/// One candidate row. [accepted] starts false for **every** row: recognising something
/// is not the same as applying it.
class _ProposalRow {
  final CalendarProposal proposal;
  bool accepted = false;

  /// Editable time field for a candidate that only had a duration
  /// (`needsTime`); null otherwise.
  final TextEditingController? ranges;

  /// True when the candidate is already part of the real data (so it is shown as
  /// "已在正式数据中" and cannot be imported twice).
  bool alreadyPresent = false;

  _ProposalRow(this.proposal)
      : ranges = proposal.needsTime
            ? TextEditingController(text: '')
            : null;

  void dispose() => ranges?.dispose();
}

class _CalendarSettingsDialog extends StatefulWidget {
  final CalendarSettings settings;
  final DateTime now;
  final CalendarProposalSource? proposals;
  final Timetable? timetable;
  final int weekStartsOn;
  final CalendarEditorMode initialMode;
  final List<UnavailableRange> defaultUnavailableRanges;
  final Map<String, String> taskNames;
  final bool useDefaultTimetable;
  final Future<bool> Function(CalendarSettingsResult result)? onApply;

  const _CalendarSettingsDialog({
    required this.settings,
    required this.now,
    this.proposals,
    this.timetable,
    this.weekStartsOn = 1,
    this.initialMode = CalendarEditorMode.fill,
    this.defaultUnavailableRanges = const <UnavailableRange>[],
    this.taskNames = const <String, String>{},
    this.useDefaultTimetable = false,
    this.onApply,
  });

  @override
  State<_CalendarSettingsDialog> createState() =>
      _CalendarSettingsDialogState();
}

class _CalendarSettingsDialogState extends State<_CalendarSettingsDialog> {
  late final TextEditingController _startDate;
  late final TextEditingController _planningDays;
  late final TextEditingController _snap;
  late final TextEditingController _offset;
  late final Map<int, TextEditingController> _weekly;
  late final List<_ExceptionRow> _exceptions;
  late final List<_OccupancyRow> _occupancies;
  final List<_ProposalRow> _proposalRows = <_ProposalRow>[];
  late final List<String> _pendingNotes;
  final ScrollController _scroll = ScrollController();

  /// 绘制网格的纵向滚动位置：切换“填写/绘制”时保留，不因重建网格 State 归零。
  final ScrollController _gridScroll = ScrollController();
  String? _error;

  /// 0.1.1：模式、周导航与共享时间表草稿。
  late CalendarEditorMode _mode;
  late String _weekStart;
  bool _weeklyMode = false;
  late TimetableDraft _draft;
  late TimetableGridController _grid;
  late CalendarSettings _applied;
  String? _applyStatus;

  // Proposal section state.
  CalendarProposalSet? _proposalSet;
  bool _proposalLoading = false;
  String _proposalStage = '';
  String? _proposalError;
  List<String> _rejected = const [];
  bool _requestedOnOpen = false;

  static const List<int> _weekdays = <int>[1, 2, 3, 4, 5, 6, 7];

  /// One height for every footer action button, so 取消 and 保存并重新安排 line up.
  static const double _actionHeight = 36;
  static const double _actionRadius = 9;
  static const double _actionFontSize = 12.5;

  /// Reserved strip on the right of the scrolling content for the scrollbar. Without
  /// it the bar is painted over the delete buttons (the 0.06 screenshot bug).
  static const double _scrollbarGutter = 16;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    final clock = s.clock;
    final fallbackStart = clock.toWall(widget.now);
    _startDate = TextEditingController(
      text: s.planningStartDate.isEmpty
          ? WallClock.formatDateKey(
              fallbackStart.year, fallbackStart.month, fallbackStart.day)
          : s.planningStartDate,
    );
    _planningDays = TextEditingController(text: '${s.planningDays}');
    _snap = TextEditingController(text: '${s.snapMinutes}');
    _offset = TextEditingController(text: '${s.timezoneOffsetMinutes}');
    _weekly = <int, TextEditingController>{
      for (final d in _weekdays)
        d: TextEditingController(text: formatTimeRanges(s.weekly.forWeekday(d))),
    };
    _exceptions = s.exceptions.map(_ExceptionRow.new).toList();
    _occupancies = s.occupancies.map(_OccupancyRow.new).toList();
    _pendingNotes = <String>[];
    final seenNotes = <String>{};
    for (final note in s.pendingNotes) {
      final text = note.trim();
      if (text.isEmpty) continue;
      if (seenNotes.add(text)) _pendingNotes.add(text);
    }
    final cached = widget.proposals?.cached;
    if (cached != null) _installProposalSet(cached);

    _mode = widget.initialMode;
    _applied = widget.settings;
    final anchor = widget.settings.planningStartDate.isEmpty
        ? WallClock.formatDateKey(
            clock.toWall(widget.now).year,
            clock.toWall(widget.now).month,
            clock.toWall(widget.now).day,
          )
        : widget.settings.planningStartDate;
    _weekStart = weekStartFor(anchor, widget.weekStartsOn);
    final Timetable initial;
    if (widget.timetable != null) {
      initial = widget.timetable!;
    } else if (widget.useDefaultTimetable) {
      initial = Timetable.withDefaults(
        weekStart: _weekStart,
        timezoneId: widget.settings.timezoneId,
        timezoneOffsetMinutes: widget.settings.timezoneOffsetMinutes,
        unavailable: <WallClockRange>[
          for (final r in widget.defaultUnavailableRanges)
            WallClockRange(r.start, r.end),
        ],
      );
    } else {
      initial = Timetable.fromSchedule(
        CalendarSchedule(settings: widget.settings),
        weekStart: _weekStart,
      );
    }
    _draft = TimetableDraft(initial.copyWith(
      dateFrom: _weekStart,
      dateTo: addDaysToDateKey(_weekStart, 6),
    ));
    _grid = TimetableGridController(draft: _draft);
    _grid.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ask once, after the first frame: the dialog must open instantly and show its
    // loading state instead of blocking on a network request.
    if (_requestedOnOpen) return;
    _requestedOnOpen = true;
    final source = widget.proposals;
    if (source == null) return;
    if (_proposalSet != null) return;
    if (source.blockedReason != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _request(force: false);
    });
  }

  @override
  void dispose() {
    if (_proposalLoading) widget.proposals?.cancel?.call();
    _scroll.dispose();
    _gridScroll.dispose();
    _grid.dispose();
    _startDate.dispose();
    _planningDays.dispose();
    _snap.dispose();
    _offset.dispose();
    for (final c in _weekly.values) {
      c.dispose();
    }
    for (final r in _exceptions) {
      r.dispose();
    }
    for (final r in _occupancies) {
      r.dispose();
    }
    for (final r in _proposalRows) {
      r.dispose();
    }
    super.dispose();
  }

  // -------------------------------------------------------------- proposals

  void _installProposalSet(CalendarProposalSet set) {
    _proposalSet = set;
    for (final row in _proposalRows) {
      row.dispose();
    }
    _proposalRows.clear();
    for (final proposal in set.proposals) {
      final row = _ProposalRow(proposal);
      row.alreadyPresent = _isAlreadyPresent(proposal);
      _proposalRows.add(row);
    }
    final seen = _pendingNotes.map((n) => n.trim()).toSet();
    for (final note in set.notes) {
      final text = note.trim();
      if (text.isEmpty) continue;
      if (seen.add(text)) _pendingNotes.add(text);
    }
  }

  bool _isAlreadyPresent(CalendarProposal p) {
    if (!p.isApplicable) return false;
    switch (p.kind) {
      case CalendarProposalKind.availability:
        final days = p.isRepeating
            ? (p.weekdays.isEmpty ? _weekdays : p.weekdays)
            : const <int>[];
        if (days.isEmpty) {
          return _exceptions.any((e) => e.date.text.trim() == p.date);
        }
        return days.every((d) {
          final text = _weekly[d]!.text;
          final parsed = parseTimeRanges(text);
          if (!parsed.ok) return false;
          final merged = parsed.ranges;
          return p.ranges.every((want) => merged.any((have) =>
              have.startMinute <= want.startMinute &&
              have.endMinute >= want.endMinute));
        });
      case CalendarProposalKind.occupancy:
        return _occupancies.any((o) {
          if (o.title.text.trim() != p.title.trim()) return false;
          if (o.kind != p.occupancyKind) return false;
          final dateText = o.date.text.trim();
          if (p.isRepeating) {
            if (dateText.isNotEmpty) return false;
            if (!p.weekdays.contains(o.weekday)) return false;
          } else {
            if (dateText != p.date) return false;
          }
          final parsed = parseTimeRanges(o.ranges.text);
          return parsed.ok &&
              p.ranges.every((want) => parsed.ranges
                  .any((have) => have == want));
        });
      case CalendarProposalKind.exception:
        return _exceptions
            .any((e) => e.date.text.trim() == p.date && p.closed && e.closed);
      case CalendarProposalKind.task:
        return _draft.timetable.dates.any((e) =>
            e.state == TimetableState.task &&
            e.taskId == p.taskId &&
            e.start == (p.ranges.isEmpty ? -1 : p.ranges.first.startMinute) &&
            e.end == (p.ranges.isEmpty ? -1 : p.ranges.first.endMinute));
      case CalendarProposalKind.unclear:
        return false;
    }
  }

  Future<void> _request({required bool force}) async {
    final source = widget.proposals;
    if (source == null || _proposalLoading) return;
    setState(() {
      _proposalLoading = true;
      _proposalError = null;
      _proposalStage = '正在识别…';
      _rejected = const [];
    });
    final outcome = await source.request(force: force);
    if (!mounted) return;
    setState(() {
      _proposalLoading = false;
      _proposalStage = '';
      _rejected = outcome.rejected;
      if (outcome.ok) {
        _installProposalSet(outcome.set!);
        _proposalError = null;
      } else {
        _proposalError = outcome.error;
      }
    });
  }

  void _cancelRequest() {
    widget.proposals?.cancel?.call();
    setState(() {
      _proposalLoading = false;
      _proposalStage = '';
      _proposalError = '已取消本次识别';
    });
  }

  // -------------------------------------------------------------- parsing

  /// Parses every time field and reports the first failure. Shared by all three
  /// editors, so they can never drift apart.
  List<WallClockRange>? _parse(
      String text, void Function(String) onError) {
    return parseTimeRangesOrError(text, onError: onError);
  }

  /// 校验表单并得到基础 CalendarSettings；失败返回 null 并写入 [_error]。
  CalendarSettings? _baseSettings() {
    String? error;
    void fail(String message) => error ??= message;

    final dateKey = parseDateKey(_startDate.text);
    if (dateKey == null) {
      setState(() => _error = '排程起始日期需为 yyyy-MM-dd');
      return null;
    }
    final days = int.tryParse(_planningDays.text.trim());
    if (days == null || days < 1 || days > 366) {
      setState(() => _error = '规划范围需为 1–366 天');
      return null;
    }
    final snap = int.tryParse(_snap.text.trim());
    if (snap == null || snap < 1 || snap > 120) {
      setState(() => _error = '吸附步长需为 1–120 分钟');
      return null;
    }
    final offset = int.tryParse(_offset.text.trim());
    if (offset == null || offset < -720 || offset > 840) {
      setState(() => _error = '时区偏移需为 -720–840 分钟（如 +480 表示东八区）');
      return null;
    }

    final weekly = <int, List<WallClockRange>>{};
    for (final d in _weekdays) {
      final ranges = _parse(_weekly[d]!.text, fail);
      if (ranges == null) break;
      if (ranges.isNotEmpty) weekly[d] = ranges;
    }
    if (error != null) {
      setState(() => _error = error);
      return null;
    }

    final exceptions = <CalendarDateException>[];
    for (final row in _exceptions) {
      final key = parseDateKey(row.date.text);
      if (key == null) {
        fail('日期例外需要 yyyy-MM-dd');
        break;
      }
      final ranges =
          row.closed ? const <WallClockRange>[] : _parse(row.ranges.text, fail);
      if (ranges == null) break;
      if (!row.closed && ranges.isEmpty) {
        fail('日期例外 $key 不是“关闭”，需要至少一个时段');
        break;
      }
      exceptions.add(CalendarDateException(
        date: key,
        closed: row.closed,
        ranges: ranges,
      ));
    }
    if (error != null) {
      setState(() => _error = error);
      return null;
    }

    final occupancies = <CalendarOccupancy>[];
    for (var i = 0; i < _occupancies.length; i++) {
      final row = _occupancies[i];
      final title = row.title.text.trim();
      if (title.isEmpty) {
        fail('第 ${i + 1} 条占用需要名称');
        break;
      }
      final ranges = _parse(row.ranges.text, fail);
      if (ranges == null) break;
      if (ranges.isEmpty) {
        fail('占用「$title」需要至少一个时段');
        break;
      }
      final dateText = row.date.text.trim();
      final key = dateText.isEmpty ? null : parseDateKey(dateText);
      if (dateText.isNotEmpty && key == null) {
        fail('占用「$title」的日期需为 yyyy-MM-dd，或留空表示每周重复');
        break;
      }
      occupancies.add(CalendarOccupancy(
        id: 'occ-${occupancies.length + 1}',
        title: title,
        kind: row.kind,
        date: key,
        weekday: key == null ? row.weekday : 0,
        ranges: ranges,
        provisional: false,
      ));
    }
    if (error != null) {
      setState(() => _error = error);
      return null;
    }

    return CalendarSettings(
      timezoneId: widget.settings.timezoneId,
      timezoneOffsetMinutes: offset,
      planningStartDate: dateKey,
      planningDays: days,
      weekly: WeeklyAvailability(weekly),
      exceptions: exceptions,
      occupancies: occupancies,
      snapMinutes: snap,
      chunkMinutes: widget.settings.chunkMinutes,
      pendingNotes: _pendingNotes,
    );
  }

  /// 收集被勾选的候选；时长型候选必须由用户填入具体时段。
  List<CalendarProposal>? _acceptedProposals(
      void Function(String) fail) {
    final accepted = <CalendarProposal>[];
    for (final row in _proposalRows) {
      if (!row.accepted) continue;
      final controller = row.ranges;
      if (controller != null) {
        final typed = _parse(controller.text, fail);
        if (typed == null) return null;
        if (typed.isEmpty) {
          fail('「${row.proposal.title}」需要先填写具体时段（例如 12:00-12:30）');
          return null;
        }
        accepted.add(row.proposal.withRanges(typed));
      } else {
        accepted.add(row.proposal);
      }
    }
    return accepted;
  }

  /// 生成待提交结果；失败时返回 null 且不关闭窗口。
  CalendarSettingsResult? _buildResult() {
    final base = _baseSettings();
    if (base == null) return null;
    String? error;
    final accepted = _acceptedProposals((message) => error ??= message);
    if (accepted == null || error != null) {
      setState(() => _error = error ?? '候选内容不合法');
      return null;
    }

    if (_mode == CalendarEditorMode.drawing) {
      final derived = _draft.timetable.toCalendarSettings(base);
      final settings = derived.copyWith(pendingNotes: _pendingNotes);
      return CalendarSettingsResult(
        settings: settings,
        timetable: _draft.timetable,
      );
    }

    final applied = applyAcceptedProposals(
      accepted: accepted,
      weekly: <int, List<WallClockRange>>{
        for (final e in base.weekly.byWeekday.entries) e.key: [...e.value],
      },
      exceptions: base.exceptions,
      occupancies: base.occupancies,
      pendingNotes: _pendingNotes,
      idPrefix: 'p${DateTime.now().millisecondsSinceEpoch}',
    );
    return CalendarSettingsResult(
      settings: base.copyWith(
        weekly: WeeklyAvailability(applied.weekly),
        exceptions: applied.exceptions,
        occupancies: applied.occupancies,
        pendingNotes: applied.pendingNotes,
      ),
      appliedProposals: applied.applied,
      skippedProposals: applied.skipped,
      timetable: _draft.timetable,
    );
  }

  Future<void> _apply() async {
    final result = _buildResult();
    if (result == null) return;
    final callback = widget.onApply;
    if (callback != null) {
      final ok = await callback(result);
      if (!mounted) return;
      if (!ok) {
        setState(() => _error ??= '提交失败，修改仍保留在编辑器中');
        return;
      }
    }
    setState(() {
      _error = null;
      _applyStatus = '已应用';
      _applied = result.settings;
      _draft.markApplied();
    });
  }

  void _save() {
    final result = _buildResult();
    if (result == null) return;
    Navigator.of(context).pop(result);
  }

  /// 手动填写 ↔ 手动绘制：先把当前表单内容并入草稿，避免切换丢修改。
  void _setMode(CalendarEditorMode mode) {
    if (mode == _mode) return;
    final base = _baseSettings();
    if (base == null) return;
    if (mode == CalendarEditorMode.fill) {
      // 绘制 → 填写：把当前周表推导出的周可用/日期例外/占用写回表单。
      final derived = _draft.timetable.toCalendarSettings(base);
      for (final d in _weekdays) {
        _weekly[d]!.text = formatTimeRanges(derived.weekly.forWeekday(d));
      }
      for (final row in _exceptions) {
        row.dispose();
      }
      _exceptions
        ..clear()
        ..addAll(derived.exceptions.map(_ExceptionRow.new));
      for (final row in _occupancies) {
        row.dispose();
      }
      _occupancies
        ..clear()
        ..addAll(derived.occupancies.map(_OccupancyRow.new));
    } else {
      // 填写 → 绘制：用当前表单重建时间表（保留已画的日期规则）。
      final rebuilt = Timetable.fromSchedule(
        CalendarSchedule(settings: base),
        weekStart: _weekStart,
      );
      final merged = _mergeTimetables(rebuilt, _draft.timetable);
      _draft.reset(merged.copyWith(
        dateFrom: _weekStart,
        dateTo: addDaysToDateKey(_weekStart, 6),
      ));
    }
    setState(() {
      _mode = mode;
      _error = null;
    });
  }

  /// 表单重建的周规则 + 已绘制草稿的日期规则；同一周的同一天以草稿为准。
  Timetable _mergeTimetables(Timetable fromForm, Timetable drawn) {
    final dateKeys = drawn.dates.map((e) => e.date!).toSet();
    final dates = <TimetableEntry>[
      for (final e in fromForm.dates)
        if (!dateKeys.contains(e.date)) e,
      ...drawn.dates,
    ];
    return drawn.copyWith(weekly: fromForm.weekly, dates: dates);
  }

  void _shiftWeek(int days) {
    final next = addDaysToDateKey(_weekStart, days);
    setState(() {
      _weekStart = next;
      _draft.reset(_draft.timetable.copyWith(
        dateFrom: next,
        dateTo: addDaysToDateKey(next, 6),
      ));
    });
  }

  Future<void> _pickMonth() async {
    final picked = await showTimetableMonthPicker(
      context,
      initialDate: _weekStart,
      weekStartsOn: widget.weekStartsOn,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _weekStart = weekStartFor(picked, widget.weekStartsOn);
      _draft.reset(_draft.timetable.copyWith(
        dateFrom: _weekStart,
        dateTo: addDaysToDateKey(_weekStart, 6),
      ));
    });
  }

  Future<void> _pickYear() async {
    final picked = await showTimetableYearPicker(
      context,
      initialDate: _weekStart,
    );
    if (picked == null || !mounted) return;
    final selected = await showTimetableMonthPicker(
      context,
      initialDate: picked,
      weekStartsOn: widget.weekStartsOn,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _weekStart = weekStartFor(selected, widget.weekStartsOn);
      _draft.reset(_draft.timetable.copyWith(
        dateFrom: _weekStart,
        dateTo: addDaysToDateKey(_weekStart, 6),
      ));
    });
  }

  // ---------------------------------------------------------------- build

  /// 绘制模式的弹窗尺寸：可用客户区约 93% 宽、88–90% 高，四周 24–48 逻辑像素。
  /// 填写模式使用较小但同一外壳的尺寸，两种模式之间平滑过渡。
  ({double width, double height}) _dialogSize(MediaQueryData media) {
    final insets = media.viewInsets;
    final usableWidth = math.max(320.0, media.size.width - insets.horizontal);
    final usableHeight = math.max(240.0, media.size.height - insets.vertical);
    final drawing = _mode == CalendarEditorMode.drawing;
    if (drawing) {
      final marginX = (usableWidth * 0.035).clamp(24.0, 48.0).toDouble();
      final marginY = (usableHeight * 0.05).clamp(24.0, 48.0).toDouble();
      return (
        width: math.max(320.0, usableWidth - marginX * 2),
        height: math.max(240.0, usableHeight - marginY * 2),
      );
    }
    return (
      width: math.min(680.0, math.max(360.0, usableWidth - 96)),
      height: math.min(640.0, math.max(320.0, usableHeight - 80)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = _dialogSize(media);
    final reduceMotion = media.disableAnimations;
    final duration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 200);
    final drawing = _mode == CalendarEditorMode.drawing;

    return Dialog(
      // 尺寸完全由内容决定，不叠加 AlertDialog 的默认边距与 560 宽度上限。
      insetPadding: EdgeInsets.zero,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        width: size.width,
        height: size.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: _editorHeader(),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    // 淡入 + 轻微位移；正在淡出的旧子树不接收指针，避免两份可交互表单。
                    final outgoing =
                        animation.status == AnimationStatus.reverse;
                    final curved = CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeInCubic,
                    );
                    return IgnorePointer(
                      ignoring: outgoing,
                      child: FadeTransition(
                        opacity: curved,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.015),
                            end: Offset.zero,
                          ).animate(curved),
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey<CalendarEditorMode>(_mode),
                    child: drawing ? _drawContent() : _fillContent(),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text(_error!,
                    key: const Key('calendar-settings-error'),
                    style: TextStyle(fontSize: 11.5, color: TsColors.blocked)),
              ),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text('可用时间与占用时间', style: TextStyle(fontSize: 15)),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            style: TsButtons.closeIcon(size: 28),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  /// 填写模式：固定标题/模式开关/底部按钮，只有中间表单滚动。
  Widget _fillContent() {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: _scroll,
        // Always visible: a hidden scrollbar is what made the 0.06 build look like
        // the buttons were simply cut off at the window edge.
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(right: _scrollbarGutter, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('排程范围'),
              _rangeRow(),
              const SizedBox(height: 8),
              _offsetRow(),
              const SizedBox(height: 14),
              _sectionTitle('每周可用时间（留空 = 该天不可用）'),
              _presets(),
              const SizedBox(height: 6),
              for (final d in _weekdays)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(_weekdayLabel(d),
                            style: TextStyle(
                                fontSize: 11.5,
                                color: TsColors.textSecondary)),
                      ),
                      Expanded(
                        child: TextField(
                          key: Key('calendar-weekday-$d'),
                          controller: _weekly[d],
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            hintText: '例如 08:00-12:00, 14:00-18:00',
                            isDense: true,
                          ),
                          // Live total: the visible sum must follow typing, not the
                          // next unrelated rebuild.
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '每周可用合计：${_weeklyMinutes()} 分钟'
                '（${(_weeklyMinutes() / 60).toStringAsFixed(1)} 小时）',
                key: const Key('calendar-weekly-total'),
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
              ),
              const SizedBox(height: 14),
              _sectionTitle('日期例外'),
              for (var i = 0; i < _exceptions.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _exceptionRow(i),
                ),
              _addButton(
                key: const Key('calendar-add-exception'),
                label: '新增日期例外',
                icon: Icons.add,
                onTap: () =>
                    setState(() => _exceptions.add(_ExceptionRow.blank())),
              ),
              const SizedBox(height: 14),
              _sectionTitle('课程 / 活动 / 休息占用'),
              for (var i = 0; i < _occupancies.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _occupancyRow(i),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, top: 2),
                child: Text(
                  '日期留空 = 每周重复（按上面选的星期）；'
                  '填 yyyy-MM-dd = 只影响该天。',
                  style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
                ),
              ),
              _addButton(
                key: const Key('calendar-add-occupancy'),
                label: '新增占用',
                icon: Icons.add,
                onTap: () =>
                    setState(() => _occupancies.add(_OccupancyRow.blank())),
              ),
              const SizedBox(height: 14),
              _proposalSection(),
              if (_pendingNotes.isNotEmpty) ...[
                const SizedBox(height: 14),
                _sectionTitle('待确认（未结构化，不会自动使用）'),
                for (final note in _pendingNotes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(Icons.help_outline,
                              size: 13, color: TsColors.pending),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(note,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.5,
                                  color: TsColors.textSecondary)),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: Row(
        children: [
          if (_applyStatus != null)
            Expanded(
              child: Text(_applyStatus!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: TsColors.ready)),
            )
          else
            const Spacer(),
          _action(
            key: const Key('calendar-settings-cancel'),
            label: '取消',
            filled: false,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
          _action(
            key: const Key('calendar-settings-apply'),
            label: '应用',
            filled: false,
            onPressed: _apply,
          ),
          const SizedBox(width: 10),
          _action(
            key: const Key('calendar-settings-save'),
            label: '保存并重新安排',
            filled: true,
            onPressed: _save,
          ),
        ],
      ),
    );
  }

  Widget _editorHeader() {
    // Wrap 而不是固定 Row：弹窗在两种尺寸之间动画过渡时，较窄的一帧会把
    // 周导航推到下一行，而不是溢出；宽窗口仍然是一行。
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        EditorModeSwitch(mode: _mode, onChanged: _setMode),
        if (_mode == CalendarEditorMode.drawing) ...[
          const SizedBox(width: 8),
          _navButton(Icons.calendar_month_outlined, '月视图', _pickMonth),
          _navButton(Icons.date_range_outlined, '年视图', _pickYear),
          const SizedBox(width: 2),
          IconButton(
            key: const Key('timetable-prev-week'),
            tooltip: '上一周',
            onPressed: () => _shiftWeek(-7),
            icon: const Icon(Icons.chevron_left, size: 18),
          ),
          Text(
            _weekRangeLabel(),
            key: const Key('timetable-week-label'),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          IconButton(
            key: const Key('timetable-next-week'),
            tooltip: '下一周',
            onPressed: () => _shiftWeek(7),
            icon: const Icon(Icons.chevron_right, size: 18),
          ),
          TextButton(
            key: const Key('timetable-this-week'),
            onPressed: _goThisWeek,
            child: const Text('本周'),
          ),
          const SizedBox(width: 8),
          FilterChip(
            key: const Key('timetable-weekly-mode'),
            label: const Text('每周重复'),
            selected: _weeklyMode,
            onSelected: (value) => setState(() => _weeklyMode = value),
          ),
        ],
      ],
    );
  }

  Widget _navButton(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 17),
    );
  }

  void _goThisWeek() {
    final wall = _applied.clock.toWall(widget.now);
    final today = WallClock.formatDateKey(wall.year, wall.month, wall.day);
    setState(() {
      _weekStart = weekStartFor(today, widget.weekStartsOn);
      _draft.reset(_draft.timetable.copyWith(
        dateFrom: _weekStart,
        dateTo: addDaysToDateKey(_weekStart, 6),
      ));
    });
  }

  String _weekRangeLabel() {
    final end = addDaysToDateKey(_weekStart, 6);
    final startYear = _weekStart.substring(0, 4);
    final endYear = end.substring(0, 4);
    if (startYear == endYear) {
      return '$startYear ${_md(_weekStart)} – ${_md(end)}';
    }
    return '${_weekStart.substring(0, 4)}-${_md(_weekStart)} – '
        '${end.substring(0, 4)}-${_md(end)}';
  }

  static String _md(String key) =>
      '${int.parse(key.substring(5, 7))}月${int.parse(key.substring(8))}日';

  Widget _drawContent() {
    // 不设固定宽高：标题、模式开关、工具栏、日期表头与底部状态/按钮由外壳固定，
    // 只有网格占据剩余空间并独立滚动。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _drawToolbar(),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: TsColors.border),
              borderRadius: const BorderRadius.all(Radius.circular(9)),
            ),
            clipBehavior: Clip.antiAlias,
            child: TimetableGrid(
              key: const Key('timetable-grid'),
              controller: _grid,
              weekStart: _weekStart,
              weekStartsOn: widget.weekStartsOn,
              weeklyMode: _weeklyMode,
              taskNames: widget.taskNames,
              verticalController: _gridScroll,
              onChanged: () {},
            ),
          ),
        ),
      ],
    );
  }

  Widget _drawToolbar() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BezierSegments(
          key: const Key('timetable-brush'),
          height: 30,
          itemWidth: 74,
          items: const [
            BezierSegmentItem('占用'),
            BezierSegmentItem('任务'),
          ],
          selected: _grid.brush == TimetableState.occupied ? 0 : 1,
          onChanged: (index) => _grid.setBrush(index == 0
              ? TimetableState.occupied
              : TimetableState.task),
        ),
        _smallToolButton('撤销', Icons.undo, () {
          _grid.undo();
          setState(() {});
        }),
        _smallToolButton('清空本周', Icons.layers_clear, _clearWeek),
        _smallToolButton('绑定蓝块', Icons.link, _bindUnbound),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            _weeklyMode ? '正在编辑每周模板' : '只修改本周具体日期',
            style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
          ),
        ),
      ],
    );
  }

  Widget _smallToolButton(String label, IconData icon, VoidCallback onTap) {
    return SizedBox(
      height: 30,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: TsButtons.filled(
          radius: 7,
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          fontSize: 11,
        ),
      ),
    );
  }

  void _clearWeek() {
    final base = _baseSettings();
    if (base == null) return;
    setState(() {
      _draft.reset(Timetable.withDefaults(
        weekStart: _weekStart,
        timezoneId: base.timezoneId,
        timezoneOffsetMinutes: base.timezoneOffsetMinutes,
        unavailable: <WallClockRange>[
          for (final r in widget.defaultUnavailableRanges)
            WallClockRange(r.start, r.end),
        ],
      ));
    });
  }

  Future<void> _bindUnbound() async {
    final base = _baseSettings();
    if (base == null) return;
    final unbound = _draft.timetable.dates
        .where((e) =>
            e.state == TimetableState.task &&
            (e.taskId == null || e.taskId!.isEmpty))
        .toList(growable: false);
    if (unbound.isEmpty) {
      setState(() => _error = '本周没有未绑定的蓝色块');
      return;
    }
    if (widget.taskNames.isEmpty) {
      setState(() => _error = '还没有可绑定的任务');
      return;
    }
    final taskId = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('把本周未绑定蓝块绑定到任务',
            style: TextStyle(fontSize: 14)),
        children: [
          for (final entry in widget.taskNames.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(entry.key),
              child: Text(entry.value, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
    if (taskId == null || !mounted) return;
    var next = _draft.timetable;
    for (final entry in unbound) {
      next = next.paint(
        date: entry.date,
        start: entry.start,
        end: entry.end,
        state: TimetableState.task,
        origin: TimetableOrigin.manual,
        title: widget.taskNames[taskId] ?? entry.title,
        taskId: taskId,
        reservationId: entry.reservationId ?? entry.id,
      );
    }
    setState(() {
      _draft.reset(next);
      _error = null;
    });
  }

  // ------------------------------------------------------------- sections

  Widget _rangeRow() {
    return LayoutBuilder(builder: (context, constraints) {
      final start = TextField(
        key: const Key('calendar-start-date'),
        controller: _startDate,
        decoration: const InputDecoration(labelText: '排程起始日期（yyyy-MM-dd）'),
      );
      final daysField = TextField(
        key: const Key('calendar-planning-days'),
        controller: _planningDays,
        decoration: const InputDecoration(labelText: '规划范围（天）'),
      );
      final snapField = TextField(
        key: const Key('calendar-snap'),
        controller: _snap,
        decoration: const InputDecoration(labelText: '吸附（分钟）'),
      );
      if (constraints.maxWidth < 520) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            start,
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: daysField),
              const SizedBox(width: 8),
              Expanded(child: snapField),
            ]),
          ],
        );
      }
      return Row(
        children: [
          Expanded(flex: 3, child: start),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: daysField),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: snapField),
        ],
      );
    });
  }

  Widget _offsetRow() {
    return LayoutBuilder(builder: (context, constraints) {
      final offsetField = TextField(
        key: const Key('calendar-offset'),
        controller: _offset,
        decoration: const InputDecoration(
          labelText: '时区偏移（分钟，+480 = 东八区）',
        ),
      );
      final tz = Text(
        '时区：${widget.settings.timezoneId}',
        style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
      );
      if (constraints.maxWidth < 520) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [offsetField, const SizedBox(height: 6), tz],
        );
      }
      return Row(
        children: [
          Expanded(flex: 2, child: offsetField),
          const SizedBox(width: 10),
          Expanded(flex: 3, child: tz),
        ],
      );
    });
  }

  Widget _presets() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final preset in const <(String, String)>[
          ('工作日 09:00-18:00', '09:00-18:00'),
          ('每天 09:00-18:00', '09:00-18:00'),
          ('清空', ''),
        ])
          SizedBox(
            height: 30,
            child: TextButton(
              onPressed: () => _applyPreset(preset.$1, preset.$2),
              style: TsButtons.filled(
                radius: 7,
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                fontSize: 11,
              ),
              child: Text(preset.$1),
            ),
          ),
      ],
    );
  }

  Widget _exceptionRow(int i) {
    final row = _exceptions[i];
    return LayoutBuilder(builder: (context, constraints) {
      final dateField = SizedBox(
        width: 118,
        child: TextField(
          controller: row.date,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(hintText: 'yyyy-MM-dd', isDense: true),
        ),
      );
      final rangesField = TextField(
        controller: row.ranges,
        enabled: !row.closed,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          hintText: row.closed ? '整日不可用' : '08:00-12:00',
          isDense: true,
        ),
      );
      final toggle = SizedBox(
        height: 32,
        child: FilledButton(
          onPressed: () => setState(() => row.closed = !row.closed),
          style: TsButtons.filled(
            radius: 7,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            fontSize: 11,
          ),
          child: Text(row.closed ? '关闭' : '开放'),
        ),
      );
      final delete = _deleteIcon(
        tooltip: '删除这条日期例外',
        onTap: () => setState(() {
          _exceptions.removeAt(i).dispose();
        }),
      );
      if (constraints.maxWidth < 560) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              dateField,
              const SizedBox(width: 8),
              Expanded(child: rangesField),
            ]),
            const SizedBox(height: 8),
            // A real gap (8 px) between the state toggle and delete: they used to be
            // flush against the scrollbar and each other.
            Row(children: [toggle, const SizedBox(width: 8), delete]),
          ],
        );
      }
      return Row(
        children: [
          dateField,
          const SizedBox(width: 8),
          Expanded(child: rangesField),
          const SizedBox(width: 8),
          toggle,
          const SizedBox(width: 8),
          delete,
        ],
      );
    });
  }

  Widget _occupancyRow(int i) {
    final row = _occupancies[i];
    return LayoutBuilder(builder: (context, constraints) {
      final titleField = TextField(
        controller: row.title,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
            hintText: '名称（课程/活动）', isDense: true),
      );
      final kindField = SizedBox(
        width: 84,
        child: DropdownButtonFormField<String>(
          initialValue: row.kind,
          isDense: true,
          style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
          decoration: const InputDecoration(isDense: true),
          items: const [
            DropdownMenuItem(value: 'course', child: Text('课程')),
            DropdownMenuItem(value: 'activity', child: Text('活动')),
            DropdownMenuItem(value: 'rest', child: Text('休息')),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => row.kind = value);
          },
        ),
      );
      final weekdayField = SizedBox(
        width: 84,
        child: DropdownButtonFormField<int>(
          initialValue: row.weekday,
          isDense: true,
          style: TextStyle(fontSize: 11.5, color: TsColors.textPrimary),
          decoration: const InputDecoration(isDense: true),
          items: [
            for (final d in _weekdays)
              DropdownMenuItem(value: d, child: Text(_weekdayLabel(d))),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() => row.weekday = value);
          },
        ),
      );
      final dateField = SizedBox(
        width: 132,
        child: TextField(
          key: Key('calendar-occupancy-date-$i'),
          controller: row.date,
          style: const TextStyle(fontSize: 12),
          decoration:
              const InputDecoration(hintText: '一次性日期', isDense: true),
        ),
      );
      final delete = _deleteIcon(
        tooltip: '删除这条占用',
        onTap: () => setState(() {
          _occupancies.removeAt(i).dispose();
        }),
      );
      final rangesField = TextField(
        key: Key('calendar-occupancy-ranges-$i'),
        controller: row.ranges,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          hintText: '时段，如 08:00-09:40；多段用逗号分隔',
          isDense: true,
        ),
      );

      final narrow = constraints.maxWidth < 560;
      final header = narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleField,
                const SizedBox(height: 8),
                Row(children: [
                  kindField,
                  const SizedBox(width: 8),
                  weekdayField,
                  const SizedBox(width: 8),
                  delete,
                ]),
                const SizedBox(height: 8),
                dateField,
              ],
            )
          : Row(children: [
              Expanded(flex: 3, child: titleField),
              const SizedBox(width: 8),
              kindField,
              const SizedBox(width: 8),
              weekdayField,
              const SizedBox(width: 8),
              dateField,
              const SizedBox(width: 8),
              delete,
            ]);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: 6),
          rangesField,
        ],
      );
    });
  }

  Widget _proposalSection() {
    final set = _proposalSet;
    final source = widget.proposals;
    final blocked = source?.blockedReason;
    return Column(
      key: const Key('calendar-proposals'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('从材料识别（待确认，勾选后才应用）'),
        if (blocked != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(blocked,
                style: TextStyle(fontSize: 10.5, color: TsColors.textFaint)),
          ),
        Row(
          children: [
            if (_proposalLoading) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                _proposalLoading
                    ? (_proposalStage.isEmpty ? '正在识别…' : _proposalStage)
                    : (set == null
                        ? (_proposalError ?? '还没有识别结果')
                        : '${set.proposals.length} 条候选 · ${set.thinkingLabel}'),
                key: const Key('calendar-proposal-status'),
                style: TextStyle(
                  fontSize: 10.5,
                  color: _proposalError != null
                      ? TsColors.blocked
                      : TsColors.textFaint,
                ),
              ),
            ),
            if (_proposalLoading)
              _smallButton(label: '取消', onTap: _cancelRequest)
            else if (source != null && blocked == null)
              _smallButton(
                key: const Key('calendar-proposal-retry'),
                label: set == null ? '识别时间约束' : '重新识别',
                onTap: () => _request(force: set != null),
              ),
          ],
        ),
        if (_rejected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '有 ${_rejected.length} 条候选未通过校验，已忽略：${_rejected.join('；')}',
              style: TextStyle(fontSize: 10, color: TsColors.pending),
            ),
          ),
        for (final row in _proposalRows)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _proposalTile(row),
          ),
        if (set != null && set.proposals.isEmpty && set.notes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '模型没有在材料里找到时间约束。可以补充材料后点“重新识别”。',
              style: TextStyle(fontSize: 10.5, color: TsColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _proposalTile(_ProposalRow row) {
    final p = row.proposal;
    final editable = row.ranges != null;
    final canTick = p.isApplicable && !row.alreadyPresent;
    final badge = switch (p.kind) {
      CalendarProposalKind.availability => TsColors.ready,
      CalendarProposalKind.occupancy => TsColors.waiting,
      CalendarProposalKind.exception => TsColors.blocked,
      CalendarProposalKind.task => TsColors.accent,
      CalendarProposalKind.unclear => TsColors.pending,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: bezierDecoration(
        color: TsColors.surfaceAlt,
        radius: 9,
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 1, right: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: bezierDecoration(
                    color: badge.withValues(alpha: 0.12), radius: 5),
                child: Text(
                  p.kind.label,
                  style: TextStyle(fontSize: 10, color: badge),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _proposalTitle(p),
                      style: TextStyle(
                          fontSize: 12, color: TsColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text('依据：${p.evidence}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10,
                            height: 1.4,
                            color: TsColors.textSecondary)),
                    Text('来源：${p.source}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 10, color: TsColors.textFaint)),
                    if (row.alreadyPresent)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('已在正式数据中，不会重复导入',
                            style: TextStyle(
                                fontSize: 10, color: TsColors.textFaint)),
                      ),
                  ],
                ),
              ),
              Tooltip(
                message: row.alreadyPresent
                    ? '已在正式数据中'
                    : (canTick ? '勾选后才会应用到正式数据' : '需要先补充时段'),
                child: Checkbox(
                  key: Key('calendar-proposal-check-${p.id}'),
                  value: row.accepted,
                  onChanged: (!canTick && !editable) || row.alreadyPresent
                      ? null
                      : (value) =>
                          setState(() => row.accepted = value == true),
                ),
              ),
            ],
          ),
          if (editable)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 4),
              child: TextField(
                key: Key('calendar-proposal-ranges-${p.id}'),
                controller: row.ranges,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '补充具体时段，例如 12:00-12:30',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
        ],
      ),
    );
  }

  String _proposalTitle(CalendarProposal p) {
    if (p.kind == CalendarProposalKind.exception) {
      return '${p.date} ${p.closed ? '整天不可用' : p.rangeLabel}';
    }
    if (p.kind == CalendarProposalKind.unclear) {
      return p.question ?? p.title;
    }
    final when = p.isRepeating ? p.weekdayLabel : p.date!;
    final kindText = switch (p.kind) {
      CalendarProposalKind.occupancy => switch (p.occupancyKind) {
          'course' => '课程',
          'rest' => '休息',
          _ => '活动',
        },
      CalendarProposalKind.task => p.isUnboundTask ? '任务预留（待绑定）' : '任务安排',
      _ => '可用时间',
    };
    return '$kindText · ${p.title} · $when ${p.rangeLabel}';
  }

  // --------------------------------------------------------------- helpers

  Widget _action({
    required Key key,
    required String label,
    required bool filled,
    required VoidCallback onPressed,
  }) {
    // Same height / radius / font / vertical padding for both footer buttons; only the
    // emphasis differs. `minimumSize` alone is not enough — the visual box is forced by
    // the SizedBox so a longer label cannot make its neighbour shorter.
    final style = filled
        ? TsButtons.filled(
            radius: _actionRadius,
            minimumSize: const Size(0, _actionHeight),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            fontSize: _actionFontSize,
          )
        : ButtonStyle(
            backgroundColor:
                const WidgetStatePropertyAll<Color>(Color(0x00000000)),
            foregroundColor: WidgetStatePropertyAll(TsColors.textPrimary),
            overlayColor: WidgetStatePropertyAll(
                TsColors.textPrimary.withValues(alpha: 0.06)),
            elevation: const WidgetStatePropertyAll<double>(0),
            side: WidgetStatePropertyAll(BorderSide(color: TsColors.border)),
            shape: const WidgetStatePropertyAll<OutlinedBorder>(
                BezierRoundedRectangleBorder(radius: _actionRadius)),
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16)),
            minimumSize: const WidgetStatePropertyAll(Size(0, _actionHeight)),
            textStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: _actionFontSize)),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
    return SizedBox(
      height: _actionHeight,
      child: TextButton(
        key: key,
        onPressed: onPressed,
        // `alignment: center` centres the label inside the visual box without a
        // `Center` widget: a `Center` would make the button expand to the whole
        // OverflowBar width and push its neighbour onto a second line.
        style: style.copyWith(alignment: Alignment.center),
        child: Text(label),
      ),
    );
  }

  Widget _addButton({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: SizedBox(
        height: 32,
        child: FilledButton.icon(
          key: key,
          onPressed: onTap,
          style: TsButtons.filled(
            radius: 8,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            fontSize: 11.5,
          ),
          icon: Icon(icon, size: 15),
          label: Text(label),
        ),
      ),
    );
  }

  Widget _smallButton({
    Key? key,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 28,
      child: TextButton(
        key: key,
        onPressed: onTap,
        style: TsButtons.filled(
          radius: 7,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          fontSize: 11,
        ),
        child: Text(label),
      ),
    );
  }

  /// Transparent icon button with a real 32x32 hit box: delete is destructive, not a
  /// blue block, and must stay clickable next to the scrollbar.
  Widget _deleteIcon({required String tooltip, required VoidCallback onTap}) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          backgroundColor:
              const WidgetStatePropertyAll<Color>(Color(0x00000000)),
          overlayColor: WidgetStatePropertyAll(
              TsColors.blocked.withValues(alpha: 0.10)),
          foregroundColor: WidgetStatePropertyAll(TsColors.blocked),
          iconColor: WidgetStatePropertyAll(TsColors.blocked),
          elevation: const WidgetStatePropertyAll<double>(0),
          side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
          minimumSize: const WidgetStatePropertyAll(Size.square(32)),
          fixedSize: const WidgetStatePropertyAll(Size.square(32)),
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
              BezierRoundedRectangleBorder(radius: 7)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.delete_outline, size: 16),
      ),
    );
  }

  void _applyPreset(String label, String ranges) {
    setState(() {
      if (ranges.isEmpty) {
        for (final c in _weekly.values) {
          c.text = '';
        }
        return;
      }
      final days =
          label.startsWith('工作日') ? const [1, 2, 3, 4, 5] : _weekdays;
      for (final d in _weekdays) {
        _weekly[d]!.text = days.contains(d) ? ranges : '';
      }
    });
  }

  int _weeklyMinutes() {
    var total = 0;
    for (final d in _weekdays) {
      final parsed = parseTimeRanges(_weekly[d]!.text);
      if (!parsed.ok) continue;
      total += parsed.totalMinutes;
    }
    return total;
  }

  static String _weekdayLabel(int weekday) => switch (weekday) {
        1 => '周一',
        2 => '周二',
        3 => '周三',
        4 => '周四',
        5 => '周五',
        6 => '周六',
        _ => '周日',
      };

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: TsColors.textPrimary,
          ),
        ),
      );
}

/// Decorative helper kept next to the dialog so `bezier` styling stays consistent.
class CalendarDialogFrame extends StatelessWidget {
  final Widget child;
  const CalendarDialogFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: bezierDecoration(
          color: TsColors.surface,
          radius: 12,
          border: Border.all(color: TsColors.border),
        ),
        child: child,
      );
}
