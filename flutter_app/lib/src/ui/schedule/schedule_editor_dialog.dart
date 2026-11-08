// 日程新建/编辑弹窗（0.4.0 任务 4）。
//
// 交互要点（01 框架 §3/§7、02 提示词任务 4）：
//   * 字段顺序：标题/地点 → 时间 → 提醒 → 重复 → 备注；分类/关联/时区可折叠或次级；
//   * 定时与全天两套草稿分开保存，切换分支不丢输入，提交只保存当前合法分支；
//   * 定时保存本地墙钟与 IANA 时区；全天界面结束日包含当天，存储结束日排他；
//   * 重复日程的“仅本次”编辑只改本次日期/时间（override，key 仍指向原始日期），
//     标题/提醒/关联等系列字段只读，并提供“改为编辑整个系列”的明确入口；
//   * 保存中禁用重复提交；失败就地显示并保留草稿；取消/Esc 走脏数据确认；
//   * 本弹窗只通过 ScheduleController 读写，不碰文件、不 import FFI。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/calendar.dart' show WallClock, parseDateKey;
import '../../model/schedule_event.dart';
import '../../state/schedule/schedule_controller.dart';
import '../../state/schedule/schedule_expander.dart'
    show ScheduleOccurrence, wallOf;
import '../theme.dart';
import '../widgets/bezier_ui.dart';

/// 单次编辑还是系列编辑。
enum ScheduleEditScope { occurrence, series }

/// 会话关联下拉的一项；数据由 AppShell 从会话列表构造，弹窗不依赖 AppController。
class ScheduleConversationOption {
  const ScheduleConversationOption({
    required this.id,
    required this.title,
    this.statusLabel,
  });

  final String id;
  final String title;

  /// 已归档/最近删除等状态；null 表示正常会话。
  final String? statusLabel;
}

/// 编辑成功的结果；[anchorDate] 供列表把日期导航到保存后的日期。
class ScheduleEditorOutcome {
  const ScheduleEditorOutcome({
    required this.result,
    required this.occurrenceOnly,
    this.anchorDate,
  });

  final ScheduleMutationResult result;
  final bool occurrenceOnly;
  final String? anchorDate;
}

/// 打开新建/编辑弹窗；返回 null 表示取消。会话关联候选由调用方注入。
Future<ScheduleEditorOutcome?> showScheduleEditorDialog(
  BuildContext context, {
  required ScheduleController controller,
  required String timezoneId,
  ScheduleEvent? event,
  ScheduleOccurrence? occurrence,
  List<ScheduleConversationOption> conversations =
      const <ScheduleConversationOption>[],
  DateTime Function()? clock,
}) {
  assert(event != null || occurrence == null,
      'occurrence 只能用于编辑已存在的系列');
  return showDialog<ScheduleEditorOutcome>(
    context: context,
    builder: (_) => ScheduleEditorDialog(
      controller: controller,
      timezoneId: timezoneId,
      event: event,
      occurrence: occurrence,
      conversations: conversations,
      clock: clock,
    ),
  );
}

class ScheduleEditorDialog extends StatefulWidget {
  const ScheduleEditorDialog({
    super.key,
    required this.controller,
    required this.timezoneId,
    this.event,
    this.occurrence,
    this.conversations = const <ScheduleConversationOption>[],
    this.clock,
  });

  final ScheduleController controller;
  final String timezoneId;
  final ScheduleEvent? event;
  final ScheduleOccurrence? occurrence;
  final List<ScheduleConversationOption> conversations;
  final DateTime Function()? clock;

  @override
  State<ScheduleEditorDialog> createState() => _ScheduleEditorDialogState();
}

class _ScheduleEditorDialogState extends State<ScheduleEditorDialog> {
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;

  late final TextEditingController _title;
  late final TextEditingController _location;
  late final TextEditingController _notes;
  late final TextEditingController _timezone;

  // 定时分支草稿（YYYY-MM-DD / HH:mm）。
  late final TextEditingController _timedStartDate;
  late final TextEditingController _timedStartClock;
  late final TextEditingController _timedEndDate;
  late final TextEditingController _timedEndClock;

  // 全天分支草稿；界面结束日包含当天。
  late final TextEditingController _allDayStart;
  late final TextEditingController _allDayEnd;

  late final TextEditingController _until;

  bool _allDay = false;
  String _category = '';
  bool _blocksScheduling = true;
  String _linkedConversationId = '';
  String _repeatKind = 'none';
  final Set<int> _weekdays = <int>{};
  ScheduleReminderKind _timedReminder = ScheduleReminderKind.none;
  ScheduleReminderKind _allDayReminder = ScheduleReminderKind.none;
  String _timezoneId = '';

  bool _advanced = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  late ScheduleEditScope _scope;

  bool get _isCreate => widget.event == null;

  bool get _occurrenceOnly => _scope == ScheduleEditScope.occurrence;

  DateTime get _nowWall =>
      wallOf(_clock().toUtc(), widget.timezoneId) ?? _clock();

  @override
  void initState() {
    super.initState();
    _scope = widget.occurrence != null
        ? ScheduleEditScope.occurrence
        : ScheduleEditScope.series;
    _timezoneId = widget.timezoneId;
    _title = TextEditingController();
    _location = TextEditingController();
    _notes = TextEditingController();
    _timezone = TextEditingController(text: _timezoneId);
    _timedStartDate = TextEditingController();
    _timedStartClock = TextEditingController();
    _timedEndDate = TextEditingController();
    _timedEndClock = TextEditingController();
    _allDayStart = TextEditingController();
    _allDayEnd = TextEditingController();
    _until = TextEditingController();
    _applyInitialValues();
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    _timezone.dispose();
    _timedStartDate.dispose();
    _timedStartClock.dispose();
    _timedEndDate.dispose();
    _timedEndClock.dispose();
    _allDayStart.dispose();
    _allDayEnd.dispose();
    _until.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 初值/草稿

  void _applyInitialValues() {
    final event = widget.event;
    if (event != null) {
      _fillSeries(event);
      if (_scope == ScheduleEditScope.occurrence) {
        _fillOccurrence(widget.occurrence!);
      }
      return;
    }
    // 新建：开始时间取下个整点（23 点后取 23:00，结束跨到次日 00:00）。
    final wall = _nowWall;
    final today = _dateKey(wall);
    final startMinute = wall.hour >= 23 ? 23 * 60 : (wall.hour + 1) * 60;
    final endMinute = startMinute + 60;
    _timedStartDate.text = today;
    _timedStartClock.text = _clockText(startMinute);
    _timedEndDate.text = _shiftDate(today, endMinute ~/ 1440);
    _timedEndClock.text = _clockText(endMinute % 1440);
    _allDayStart.text = today;
    _allDayEnd.text = today;
    _weekdays.add(_weekdayOf(today));
  }

  void _fillSeries(ScheduleEvent event) {
    _title.text = event.title;
    _location.text = event.location ?? '';
    _notes.text = event.notes ?? '';
    _timezone.text = event.timezoneId;
    _timezoneId = event.timezoneId;
    _category = event.category?.wireName ?? '';
    _blocksScheduling = event.blocksScheduling;
    _linkedConversationId = event.linkedConversationId ?? '';
    _repeatKind = event.repeat.kind.wireName;
    _weekdays
      ..clear()
      ..addAll(event.repeat.weekdays);
    _until.text = event.repeat.untilDate ?? '';
    if (event.allDay) {
      _allDayReminder = event.reminder;
      _timedReminder = ScheduleReminderKind.none;
    } else {
      _timedReminder = event.reminder;
      _allDayReminder = ScheduleReminderKind.none;
    }
    _allDay = event.allDay;
    if (event.allDay) {
      _allDayStart.text = event.startDate;
      final end = event.endDateExclusive ?? _shiftDate(event.startDate, 1);
      _allDayEnd.text = _shiftDate(end, -1);
      // 定时分支也放一份等价草稿，切分支时不至于空白。
      _timedStartDate.text = event.startDate;
      _timedStartClock.text = '09:00';
      _timedEndDate.text = event.startDate;
      _timedEndClock.text = '10:00';
    } else {
      final startMinute = event.startMinute ?? 9 * 60;
      final endMinute = event.endMinute ?? startMinute + 60;
      _timedStartDate.text = event.startDate;
      _timedStartClock.text = _clockText(startMinute % 1440);
      _timedEndDate.text =
          _shiftDate(event.startDate, startMinute ~/ 1440 + endMinute ~/ 1440);
      _timedEndClock.text = _clockText(endMinute % 1440);
      _allDayStart.text = event.startDate;
      _allDayEnd.text = event.startDate;
    }
    if (_weekdays.isEmpty) _weekdays.add(_weekdayOf(event.startDate));
  }

  void _fillOccurrence(ScheduleOccurrence occurrence) {
    _allDay = occurrence.allDay;
    if (occurrence.allDay) {
      _allDayStart.text = occurrence.startDate ?? _dateKey(_nowWall);
      final end = occurrence.endDateExclusive;
      _allDayEnd.text =
          end == null ? _allDayStart.text : _shiftDate(end, -1);
      return;
    }
    final startWall =
        occurrence.startUtc == null ? null : _wallOf(occurrence.startUtc!);
    final endWall =
        occurrence.endUtc == null ? null : _wallOf(occurrence.endUtc!);
    if (startWall == null || endWall == null) return;
    final startDate = _dateKey(startWall);
    _timedStartDate.text = startDate;
    _timedStartClock.text =
        _clockText(startWall.hour * 60 + startWall.minute);
    final dayDiff = dateKeyToUtc(_dateKey(endWall))!
        .difference(dateKeyToUtc(startDate)!)
        .inDays;
    _timedEndDate.text = _dateKey(endWall);
    _timedEndClock.text = _clockText(endWall.hour * 60 + endWall.minute);
    if (dayDiff < 0) _timedEndDate.text = startDate;
  }

  // ------------------------------------------------------------------ 保存

  Future<void> _save() async {
    if (_saving) return;
    final time = _readTime();
    if (time == null) return;
    final event = widget.event;
    ScheduleDraft? draft;
    if (!_occurrenceOnly) {
      draft = _buildDraft(time);
      if (draft == null) return;
    } else {
      // 单次编辑也要先过同一份时间/时区校验，但只保存日期与时间。
      draft = _buildDraft(time, forOccurrence: true);
      if (draft == null) return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    ScheduleMutationResult result;
    try {
      if (_occurrenceOnly) {
        final occurrence = widget.occurrence!;
        result = await widget.controller.overrideOccurrence(
          event!.id,
          occurrence.occurrenceKey,
          startDate: time.startDate,
          startMinute: time.startMinute,
          endMinute: time.endMinute,
          endDateExclusive: time.endDateExclusive,
        );
      } else if (event == null) {
        result = await widget.controller.createEvent(draft);
      } else {
        result = await widget.controller.updateEvent(
          event.id,
          event.revision,
          draft,
        );
        if (!result.ok &&
            result.status == ScheduleMutationStatus.rejected &&
            _isExceptionImpact(result.message)) {
          // 先不带 confirmDropInvalidExceptions 调用，失败后向用户展示影响再确认。
          if (!mounted) return;
          setState(() => _saving = false);
          final confirmed = await _confirmDropInvalidExceptions(result.message);
          if (!mounted || !confirmed) return;
          setState(() => _saving = true);
          result = await widget.controller.updateEvent(
            event.id,
            event.revision,
            draft,
            confirmDropInvalidExceptions: true,
          );
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '日程保存失败：$error';
      });
      return;
    }
    if (!mounted) return;
    if (result.ok) {
      _dirty = false;
      Navigator.of(context).pop(ScheduleEditorOutcome(
        result: result,
        occurrenceOnly: _occurrenceOnly,
        anchorDate: time.startDate,
      ));
      return;
    }
    setState(() {
      _saving = false;
      _error = result.message;
    });
  }

  static bool _isExceptionImpact(String message) =>
      message.contains('单次例外') && message.contains('影响');

  Future<bool> _confirmDropInvalidExceptions(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改重复规则会影响单次例外',
            style: TextStyle(fontSize: 15)),
        content: Text(
          '$message\n\n继续保存会删除这些不再命中新规则的单次例外（例如移到其他日期的本次修改）。'
          '取消可以继续编辑，原数据不会被改动。',
          style: const TextStyle(fontSize: 12.5, height: 1.55),
        ),
        actions: [
          TextButton(
            key: const Key('schedule-exceptions-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('schedule-exceptions-confirm'),
            style: TsButtons.solid(fill: TsColors.blocked),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续并移除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  ScheduleDraft? _buildDraft(
    _TimeSelection time, {
    bool forOccurrence = false,
  }) {
    final title = _title.text.trim();
    if (title.isEmpty) {
      _setError('标题不能为空');
      return null;
    }
    if (title.length > kScheduleTitleMaxLength) {
      _setError('标题不能超过 $kScheduleTitleMaxLength 个字符');
      return null;
    }
    final location = _location.text.trim();
    if (location.length > kScheduleLocationMaxLength) {
      _setError('地点不能超过 $kScheduleLocationMaxLength 个字符');
      return null;
    }
    final notes = _notes.text.trim();
    if (notes.length > kScheduleNotesMaxLength) {
      _setError('备注不能超过 $kScheduleNotesMaxLength 个字符');
      return null;
    }
    final timezone = _timezone.text.trim();
    if (timezone.isEmpty) {
      _setError('时区不能为空');
      return null;
    }
    if (wallOf(DateTime.now().toUtc(), timezone) == null) {
      _setError('时区无法解析：$timezone（应使用 IANA 名称，例如 Asia/Shanghai）');
      return null;
    }
    final event = widget.event;
    ScheduleRepeatRule repeat;
    if (forOccurrence) {
      repeat = event?.repeat ?? const ScheduleRepeatRule.none();
    } else {
      final parsed = _buildRepeat();
      if (parsed == null) return null;
      repeat = parsed;
    }
    final draft = ScheduleDraft(
      title: title,
      location: location,
      notes: notes,
      category: _category.isEmpty
          ? null
          : ScheduleCategory.parse(_category),
      timezoneId: timezone,
      allDay: _allDay,
      startDate: time.startDate,
      startMinute: time.startMinute,
      endMinute: time.endMinute,
      endDateExclusive: time.endDateExclusive,
      blocksScheduling: forOccurrence
          ? (event?.blocksScheduling ?? true)
          : _blocksScheduling,
      linkedConversationId: forOccurrence
          ? event?.linkedConversationId
          : (_linkedConversationId.isEmpty ? null : _linkedConversationId),
      repeat: repeat,
      reminder: forOccurrence
          ? (event?.reminder ?? ScheduleReminderKind.none)
          : (_allDay ? _allDayReminder : _timedReminder),
    );
    final error = draft.validate();
    if (error != null) {
      _setError(error);
      return null;
    }
    return draft;
  }

  ScheduleRepeatRule? _buildRepeat() {
    String? until;
    final untilText = _until.text.trim();
    if (untilText.isNotEmpty) {
      until = parseDateKey(untilText);
      if (until == null) {
        _setError('重复结束日期格式应为 YYYY-MM-DD');
        return null;
      }
    }
    switch (_repeatKind) {
      case 'daily':
        return ScheduleRepeatRule.daily(untilDate: until);
      case 'weekly':
        if (_weekdays.isEmpty) {
          _setError('每周重复至少要选择一天');
          return null;
        }
        final days = _weekdays.toList()..sort();
        return ScheduleRepeatRule.weekly(weekdays: days, untilDate: until);
      default:
        return const ScheduleRepeatRule.none();
    }
  }

  _TimeSelection? _readTime() {
    if (_allDay) {
      final start = parseDateKey(_allDayStart.text.trim());
      if (start == null) {
        _setError('全天开始日期格式应为 YYYY-MM-DD');
        return null;
      }
      final end = parseDateKey(_allDayEnd.text.trim());
      if (end == null) {
        _setError('全天结束日期格式应为 YYYY-MM-DD');
        return null;
      }
      if (end.compareTo(start) < 0) {
        _setError('全天结束日期不能早于开始日期');
        return null;
      }
      return _TimeSelection(
        startDate: start,
        endDateExclusive: _shiftDate(end, 1),
      );
    }
    final startDate = parseDateKey(_timedStartDate.text.trim());
    if (startDate == null) {
      _setError('开始日期格式应为 YYYY-MM-DD');
      return null;
    }
    final startClock = _parseClock(_timedStartClock.text);
    if (startClock == null) {
      _setError('开始时间格式应为 HH:mm');
      return null;
    }
    final endDate = parseDateKey(_timedEndDate.text.trim());
    if (endDate == null) {
      _setError('结束日期格式应为 YYYY-MM-DD');
      return null;
    }
    final endClock = _parseClock(_timedEndClock.text);
    if (endClock == null) {
      _setError('结束时间格式应为 HH:mm');
      return null;
    }
    final startBase = dateKeyToUtc(startDate);
    final endBase = dateKeyToUtc(endDate);
    if (startBase == null || endBase == null) {
      _setError('日期不合法');
      return null;
    }
    final dayDiff = endBase.difference(startBase).inDays;
    if (dayDiff < 0) {
      _setError('结束日期不能早于开始日期');
      return null;
    }
    if (dayDiff > 1) {
      _setError('单次日程最多跨一天（24 小时内）');
      return null;
    }
    var endMinute = dayDiff * 1440 + endClock;
    if (endMinute <= startClock) {
      // 单次编辑只改开始时间时，保持原实例时长而不是逼用户再改结束时间；
      // 系列编辑仍要求显式合法区间（避免静默改结束时间）。
      final original = _occurrenceOnly ? widget.occurrence : null;
      final duration = original?.duration.inMinutes ?? 0;
      if (original != null && duration > 0) {
        endMinute = startClock + duration;
        if (endMinute > 1439 + 1440) {
          _setError('结束时间必须晚于开始时间');
          return null;
        }
      } else {
        _setError('结束时间必须晚于开始时间');
        return null;
      }
    }
    return _TimeSelection(
      startDate: startDate,
      startMinute: startClock,
      endMinute: endMinute,
    );
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  void _markDirty() {
    if (_dirty && mounted) return;
    setState(() => _dirty = true);
  }

  // ------------------------------------------------------------ 关闭流程

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的日程？', style: TextStyle(fontSize: 15)),
        content: const Text(
          '关闭后本次修改会丢失；已保存的日程不受影响。',
          style: TextStyle(fontSize: 12.5, height: 1.55),
        ),
        actions: [
          TextButton(
            key: const Key('schedule-discard-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            key: const Key('schedule-discard-confirm'),
            style: TsButtons.solid(fill: TsColors.blocked),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (discard == true) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final width = math.min(640.0, math.max(320.0, media.width - 32));
    final height = math.min(680.0, math.max(320.0, media.height - 40));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: Dialog(
        key: const Key('schedule-editor-dialog'),
        backgroundColor: TsColors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        shape: const BezierRoundedRectangleBorder(radius: 16),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titleRow(),
              Divider(height: 1, thickness: 1, color: TsColors.border),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                  child: _body(),
                ),
              ),
              Divider(height: 1, thickness: 1, color: TsColors.border),
              _actionRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleRow() {
    final label = _occurrenceOnly
        ? '编辑本次日程'
        : (_isCreate ? '新建日程' : '编辑日程');
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
      child: Row(
        children: [
          Icon(
            _occurrenceOnly ? Icons.event_repeat : Icons.event_note_outlined,
            size: 17,
            color: TsColors.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: TsColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            key: const Key('schedule-editor-close'),
            tooltip: '关闭',
            style: TsButtons.closeIcon(size: 28),
            onPressed: _saving ? null : _requestClose,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_occurrenceOnly) return _occurrenceBody();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('schedule-title'),
          controller: _title,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          onChanged: (_) => _markDirty(),
          decoration: const InputDecoration(
            labelText: '标题（必填）',
            hintText: '例如：项目会议',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('schedule-location'),
          controller: _location,
          style: const TextStyle(fontSize: 12.5),
          onChanged: (_) => _markDirty(),
          decoration: const InputDecoration(
            labelText: '地点（可选）',
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const Key('schedule-category'),
                initialValue: _category,
                style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary),
                decoration: const InputDecoration(labelText: '分类'),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem(value: '', child: Text('未分类')),
                  for (final category in ScheduleCategory.values)
                    DropdownMenuItem(
                      value: category.wireName,
                      child: Text(category.label),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _category = value ?? '';
                  _dirty = true;
                }),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const Key('schedule-linked'),
                initialValue: _linkedConversationId,
                isExpanded: true,
                style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary),
                decoration: const InputDecoration(labelText: '关联会话（可选）'),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem(value: '', child: Text('不关联')),
                  for (final option in widget.conversations)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(
                        option.statusLabel == null
                            ? option.title
                            : '${option.title}（${option.statusLabel}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _linkedConversationId = value ?? '';
                  _dirty = true;
                }),
              ),
            ),
          ],
        ),
        _sectionLabel('时间'),
        Row(
          children: [
            Text('全天日程', style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary)),
            const Spacer(),
            Switch(
              key: const Key('schedule-all-day'),
              value: _allDay,
              onChanged: (value) => setState(() {
                _allDay = value;
                _dirty = true;
              }),
            ),
          ],
        ),
        if (_allDay) ...[
          _dateField(
            key: const Key('schedule-allday-start'),
            pickKey: const Key('schedule-allday-start-pick'),
            controller: _allDayStart,
            label: '开始日期',
          ),
          const SizedBox(height: 10),
          _dateField(
            key: const Key('schedule-allday-end'),
            pickKey: const Key('schedule-allday-end-pick'),
            controller: _allDayEnd,
            label: '结束日期（含当天）',
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _dateField(
                  key: const Key('schedule-start-date'),
                  pickKey: const Key('schedule-start-date-pick'),
                  controller: _timedStartDate,
                  label: '开始日期',
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: _clockField(
                  key: const Key('schedule-start-time'),
                  controller: _timedStartClock,
                  label: '开始',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _dateField(
                  key: const Key('schedule-end-date'),
                  pickKey: const Key('schedule-end-date-pick'),
                  controller: _timedEndDate,
                  label: '结束日期（可次日）',
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: _clockField(
                  key: const Key('schedule-end-time'),
                  controller: _timedEndClock,
                  label: '结束',
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint('精确到分钟；结束日期晚于开始日期即表示跨日，最多跨一天。'),
          ),
        ],
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '占用排程时间（其他会话的排程会避开这段）',
                style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
              ),
            ),
            Switch(
              key: const Key('schedule-blocks'),
              value: _blocksScheduling,
              onChanged: (value) => setState(() {
                _blocksScheduling = value;
                _dirty = true;
              }),
            ),
          ],
        ),
        _sectionLabel('提醒（应用运行期间）'),
        _reminderDropdown(),
        _sectionLabel('重复'),
        BezierSegments(
          key: const Key('schedule-repeat'),
          items: const <BezierSegmentItem>[
            BezierSegmentItem('不重复'),
            BezierSegmentItem('每天'),
            BezierSegmentItem('每周'),
          ],
          itemKeys: const <Key?>[
            Key('schedule-repeat-none'),
            Key('schedule-repeat-daily'),
            Key('schedule-repeat-weekly'),
          ],
          selected: const ['none', 'daily', 'weekly'].indexOf(_repeatKind),
          expand: true,
          onChanged: (index) => setState(() {
            _repeatKind = const ['none', 'daily', 'weekly'][index];
            _dirty = true;
          }),
        ),
        if (_repeatKind == 'weekly') ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  key: Key('schedule-weekday-$day'),
                  label: Text(_weekdayLabel(day)),
                  selected: _weekdays.contains(day),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _weekdays.add(day);
                    } else {
                      _weekdays.remove(day);
                    }
                    _dirty = true;
                  }),
                ),
            ],
          ),
        ],
        if (_repeatKind != 'none') ...[
          const SizedBox(height: 8),
          _dateField(
            key: const Key('schedule-until'),
            pickKey: const Key('schedule-until-pick'),
            controller: _until,
            label: '重复结束日期（空 = 不设结束）',
            clearKey: const Key('schedule-until-clear'),
          ),
        ],
        _sectionLabel('备注'),
        TextField(
          key: const Key('schedule-notes'),
          controller: _notes,
          style: const TextStyle(fontSize: 12.5, height: 1.5),
          minLines: 2,
          maxLines: 4,
          onChanged: (_) => _markDirty(),
          decoration: const InputDecoration(
            labelText: '备注（可选，最多 $kScheduleNotesMaxLength 字）',
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('schedule-advanced-toggle'),
          style: TsButtons.link(),
          onPressed: () => setState(() => _advanced = !_advanced),
          icon: Icon(
            _advanced ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          label: const Text('高级：时区'),
        ),
        if (_advanced) ...[
          const SizedBox(height: 4),
          TextField(
            key: const Key('schedule-timezone'),
            controller: _timezone,
            style: const TextStyle(fontSize: 12.5),
            onChanged: (_) => _markDirty(),
            decoration: const InputDecoration(
              labelText: 'IANA 时区',
              hintText: '例如 Asia/Shanghai',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _hint('定时日程按该时区的当地钟点重复；默认沿用应用当前时区。'),
          ),
        ],
        if (_error != null) _errorBanner(),
      ],
    );
  }

  Widget _occurrenceBody() {
    final occurrence = widget.occurrence!;
    final event = widget.event!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('schedule-occurrence-banner'),
          padding: const EdgeInsets.all(10),
          decoration: bezierDecoration(color: TsColors.accentSoft, radius: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '标题：${event.title}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TsColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '正在编辑 ${occurrence.originalDate} 这一次。标题、地点、备注、提醒、'
                '关联和重复规则属于整个系列，本次只能修改日期/时间。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: TsColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                key: const Key('schedule-switch-to-series'),
                style: TsButtons.link(),
                onPressed: _switchToSeries,
                child: const Text('改为编辑整个系列'),
              ),
            ],
          ),
        ),
        _sectionLabel('时间'),
        if (_allDay) ...[
          _dateField(
            key: const Key('schedule-allday-start'),
            pickKey: const Key('schedule-allday-start-pick'),
            controller: _allDayStart,
            label: '开始日期',
          ),
          const SizedBox(height: 10),
          _dateField(
            key: const Key('schedule-allday-end'),
            pickKey: const Key('schedule-allday-end-pick'),
            controller: _allDayEnd,
            label: '结束日期（含当天）',
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _dateField(
                  key: const Key('schedule-start-date'),
                  pickKey: const Key('schedule-start-date-pick'),
                  controller: _timedStartDate,
                  label: '开始日期',
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: _clockField(
                  key: const Key('schedule-start-time'),
                  controller: _timedStartClock,
                  label: '开始',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _dateField(
                  key: const Key('schedule-end-date'),
                  pickKey: const Key('schedule-end-date-pick'),
                  controller: _timedEndDate,
                  label: '结束日期（可次日）',
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: _clockField(
                  key: const Key('schedule-end-time'),
                  controller: _timedEndClock,
                  label: '结束',
                ),
              ),
            ],
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _hint('只改这一次：其他实例保持不变；以后查询仍用原始发生日期定位这次修改。'),
        ),
        if (_error != null) _errorBanner(),
      ],
    );
  }

  void _switchToSeries() {
    final event = widget.event;
    if (event == null) return;
    setState(() {
      _scope = ScheduleEditScope.series;
      _fillSeries(event);
      _dirty = true;
    });
  }

  Widget _reminderDropdown() {
    final options = _allDay
        ? const <ScheduleReminderKind>[
            ScheduleReminderKind.none,
            ScheduleReminderKind.allDaySameDay,
            ScheduleReminderKind.allDayPrevDay,
          ]
        : const <ScheduleReminderKind>[
            ScheduleReminderKind.none,
            ScheduleReminderKind.atStart,
            ScheduleReminderKind.minutes5,
            ScheduleReminderKind.minutes15,
            ScheduleReminderKind.minutes30,
            ScheduleReminderKind.dayBefore,
          ];
    final value = _allDay ? _allDayReminder : _timedReminder;
    // 定时/全天两套提醒选项互斥；分支切换时重建 FormField，避免内部旧值不在新选项里。
    return KeyedSubtree(
      key: ValueKey<bool>(_allDay),
      child: DropdownButtonFormField<ScheduleReminderKind>(
        key: const Key('schedule-reminder'),
        initialValue:
            options.contains(value) ? value : ScheduleReminderKind.none,
        style: TextStyle(fontSize: 12.5, color: TsColors.textPrimary),
        decoration: const InputDecoration(labelText: '提醒'),
        items: <DropdownMenuItem<ScheduleReminderKind>>[
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(option.label)),
        ],
        onChanged: (selected) => setState(() {
          final next = selected ?? ScheduleReminderKind.none;
          if (_allDay) {
            _allDayReminder = next;
          } else {
            _timedReminder = next;
          }
          _dirty = true;
        }),
      ),
    );
  }

  Widget _actionRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            key: const Key('schedule-cancel'),
            style: TsButtons.inline(),
            onPressed: _saving ? null : _requestClose,
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('schedule-save'),
            style: TsButtons.solid(),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: TsColors.textPrimary,
          ),
        ),
      );

  Widget _hint(String text) => Text(
        text,
        style: TextStyle(fontSize: 11, height: 1.45, color: TsColors.textFaint),
      );

  Widget _errorBanner() => Container(
        key: const Key('schedule-editor-error'),
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(10),
        decoration: bezierDecoration(
          color: TsColors.blockedSoft,
          radius: 8,
          border: Border.all(color: TsColors.blocked.withValues(alpha: 0.4)),
        ),
        child: Text(
          _error!,
          style: TextStyle(fontSize: 11.5, height: 1.45, color: TsColors.blocked),
        ),
      );

  Widget _dateField({
    required Key key,
    required Key pickKey,
    required TextEditingController controller,
    required String label,
    Key? clearKey,
  }) {
    return TextField(
      key: key,
      controller: controller,
      style: const TextStyle(fontSize: 12.5),
      onChanged: (_) => _markDirty(),
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        isDense: true,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (clearKey != null)
              IconButton(
                key: clearKey,
                tooltip: '清空',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.clear, size: 15),
                onPressed: () => setState(() {
                  controller.clear();
                  _dirty = true;
                }),
              ),
            IconButton(
              key: pickKey,
              tooltip: '选择日期',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.event, size: 15),
              onPressed: () => _pickDate(controller, label),
            ),
          ],
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      ),
    );
  }

  Widget _clockField({
    required Key key,
    required TextEditingController controller,
    required String label,
  }) =>
      TextField(
        key: key,
        controller: controller,
        style: const TextStyle(fontSize: 12.5),
        onChanged: (_) => _markDirty(),
        decoration: InputDecoration(
          labelText: label,
          hintText: 'HH:mm',
          isDense: true,
        ),
      );

  Future<void> _pickDate(TextEditingController controller, String label) async {
    final parsed = parseDateKey(controller.text.trim());
    final base = parsed == null ? _nowWall : dateKeyToUtc(parsed)!;
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: label,
    );
    if (picked == null || !mounted) return;
    setState(() {
      controller.text = _dateKey(picked);
      _dirty = true;
    });
  }

  // -------------------------------------------------------------- 小工具

  static String _dateKey(DateTime date) =>
      WallClock.formatDateKey(date.year, date.month, date.day);

  static String _shiftDate(String dateKey, int days) {
    final base = dateKeyToUtc(dateKey);
    if (base == null) return dateKey;
    return _dateKey(base.add(Duration(days: days)));
  }

  static int _weekdayOf(String dateKey) => dateKeyToUtc(dateKey)?.weekday ?? 1;

  static String _weekdayLabel(int day) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day - 1];

  static String _clockText(int minutes) {
    final value = minutes % 1440;
    return '${(value ~/ 60).toString().padLeft(2, '0')}:'
        '${(value % 60).toString().padLeft(2, '0')}';
  }

  static int? _parseClock(String text) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  DateTime? _wallOf(DateTime utc) => wallOf(utc, _timezoneId);
}

class _TimeSelection {
  const _TimeSelection({
    required this.startDate,
    this.startMinute,
    this.endMinute,
    this.endDateExclusive,
  });

  final String startDate;
  final int? startMinute;
  final int? endMinute;
  final String? endDateExclusive;
}
