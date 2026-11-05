// 「设置 → 外部日历」页：本地 ICS 来源管理。
//
// 与 settings_dialog 的契约：构造函数固定为
// `SettingsExternalCalendarPage({service, timezoneId, currentConversationTitle, onChanged})`
// （T-B 负责在设置窗口挂载并传参；本页不修改 settings_dialog.dart）。
//
// 页面只管理「来源」这一层：新建导入、更新（重新选文件）、改名、启用/停用、删除。
// 外部日历是只读输入：这里不会写手工时间表；删除只移除外部来源自己的快照。
// 每个动作都显示真实结果，失败时保留原数据并给出原因，不假装成功。
//
// 纵向滚动由外层的 SettingsPageViewport（T-B）负责，本页不自带 ScrollView。

import 'package:flutter/material.dart';

import '../../model/calendar.dart';
import '../../model/external_calendar.dart';
import '../../model/timetable.dart' show addDaysToDateKey;
import '../../state/external_calendar_service.dart';
import '../external_calendar_dialog.dart';
import '../theme.dart';
import 'settings_widgets.dart';

class SettingsExternalCalendarPage extends StatefulWidget {
  const SettingsExternalCalendarPage({
    super.key,
    required this.service,
    required this.timezoneId,
    this.currentConversationTitle,
    this.onChanged,
    this.pickFiles,
  });

  final ExternalCalendarService service;
  final String timezoneId;
  final String? currentConversationTitle;

  /// 外部日历数据变化后的通知（应用层据此刷新只读占用/排程）。
  final VoidCallback? onChanged;

  /// 测试注入口；生产默认走 [ExternalCalendarFilePicker.defaultPick]。
  final ExternalCalendarPickFiles? pickFiles;

  @override
  State<SettingsExternalCalendarPage> createState() =>
      _SettingsExternalCalendarPageState();
}

class _SettingsExternalCalendarPageState
    extends State<SettingsExternalCalendarPage> {
  String? _status;
  String? _error;
  bool _busy = false;
  String? _busySourceId;

  /// 改名对话框的输入控制器：对话框退场动画期间仍在树上，不能立刻 dispose，
  /// 统一由页面在销毁时释放（避免 “used after being disposed” 破坏整棵控件树）。
  final List<TextEditingController> _renameControllers =
      <TextEditingController>[];

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void didUpdateWidget(covariant SettingsExternalCalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_onServiceChanged);
      widget.service.addListener(_onServiceChanged);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    for (final controller in _renameControllers) {
      controller.dispose();
    }
    _renameControllers.clear();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  ExternalCalendarService get _service => widget.service;

  // ------------------------------------------------------------- 导入/更新

  /// 新导入的默认展开范围：今天起 30 天（事件仍完整保存在快照里）。
  ({String from, String to}) _defaultPlanningRange() {
    final now = DateTime.now();
    final from = WallClock.formatDateKey(now.year, now.month, now.day);
    return (from: from, to: addDaysToDateKey(from, 29));
  }

  Future<void> _openImport({ExternalCalendarSource? existing}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busySourceId = existing?.id;
      _error = null;
    });
    final range = existing == null
        ? _defaultPlanningRange()
        : (from: existing.dateFrom, to: existing.dateTo);
    bool imported = false;
    try {
      imported = await showExternalCalendarImportDialog(
        context,
        service: _service,
        timezoneId: widget.timezoneId,
        planningDateFrom: range.from,
        planningDateTo: range.to,
        existingSource: existing,
        // 更新已有来源时默认按“完整替换”进入：重新选的文件通常就是新的完整快照，
        // 但仍然需要用户在对话框里二次确认才会移除旧事件。
        replaceModeDefault: existing != null,
        pickFiles: widget.pickFiles,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busySourceId = null;
        });
      }
    }
    if (!mounted || !imported) return;
    setState(() {
      _error = null;
      _status = existing == null
          ? '已导入外部日历来源；只读占用会参与之后的排程与请求。'
          : '已更新来源「${existing.name}」；只读占用已刷新。';
    });
    widget.onChanged?.call();
  }

  // ------------------------------------------------------- 启用/停用、改名

  Future<void> _toggleEnabled(ExternalCalendarSource source, bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busySourceId = source.id;
      _error = null;
      _status = null;
    });
    var ok = false;
    try {
      ok = await _service.setEnabled(source.id, enabled);
      if (!ok) _error = _service.lastError ?? '未能${enabled ? '启用' : '停用'}该来源';
    } catch (e) {
      _error = '${enabled ? '启用' : '停用'}失败：${_short(e)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busySourceId = null;
      if (ok) _status = '已${enabled ? '启用' : '停用'}「${source.name}」';
    });
    if (ok) widget.onChanged?.call();
  }

  Future<void> _rename(ExternalCalendarSource source) async {
    if (_busy) return;
    final controller = TextEditingController(text: source.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TsColors.surface,
        title: const Text('重命名外部日历来源', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 380,
          child: TextField(
            key: const Key('external-calendar-rename-field'),
            controller: controller,
            autofocus: true,
            style: const TextStyle(fontSize: 12.5),
            decoration: const InputDecoration(
              labelText: '来源名称',
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('external-calendar-rename-cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('external-calendar-rename-confirm'),
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.of(ctx).pop(text);
            },
            style: TsButtons.filled(radius: 8),
            child: const Text('保存名称'),
          ),
        ],
      ),
    );
    // 不在这里 dispose：对话框退场动画期间 TextField 仍会访问控制器。
    _renameControllers.add(controller);
    if (result == null || !mounted || result == source.name) return;
    setState(() {
      _busy = true;
      _busySourceId = source.id;
      _error = null;
      _status = null;
    });
    var ok = false;
    try {
      ok = await _service.rename(source.id, result);
      if (!ok) _error = _service.lastError ?? '未能重命名该来源';
    } catch (e) {
      _error = '重命名失败：${_short(e)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busySourceId = null;
      if (ok) _status = '已重命名为「$result」';
    });
    if (ok) widget.onChanged?.call();
  }

  // --------------------------------------------------------------- 删除

  Future<void> _delete(ExternalCalendarSource source) async {
    if (_busy) return;
    final snapshot = _service.snapshotOf(source.id);
    final eventCount = snapshot?.events.length ?? 0;
    final instanceCount = source.stats.expandedInstances;
    final conversation = widget.currentConversationTitle?.trim() ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TsColors.surface,
        title: const Text('删除这个外部日历来源？', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 440,
          child: Text(
            '将删除来源「${source.name}」及它自己的导入快照。\n\n'
            '· 受影响事件：$eventCount 条（其中的占用实例：$instanceCount 个）\n'
            '· 受影响会话：${conversation.isEmpty ? '当前没有打开的会话' : '当前会话「$conversation」'}'
            '${conversation.isEmpty ? '' : '（如已关联，将不再使用这些外部占用）'}\n\n'
            '手工时间表、任务与其它来源不受影响；重新导入可从原 ICS 文件恢复。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: TsColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('external-calendar-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('external-calendar-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TsButtons.filled(radius: 8),
            child: const Text('删除来源'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _busySourceId = source.id;
      _error = null;
      _status = null;
    });
    var ok = false;
    try {
      ok = await _service.remove(source.id);
      if (!ok) _error = _service.lastError ?? '未能删除该来源';
    } catch (e) {
      _error = '删除失败：${_short(e)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busySourceId = null;
      if (ok) _status = '已删除来源「${source.name}」';
    });
    if (ok) widget.onChanged?.call();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final sources = _service.sources;
    return Column(
      key: const Key('settings-external-calendar-page'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '来源 ${sources.length} 个',
                      key: const Key('external-calendar-source-count'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TsColors.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 32,
                    child: FilledButton.icon(
                      key: const Key('external-calendar-new-import'),
                      onPressed: _busy ? null : () => _openImport(),
                      style: TsButtons.filled(
                        radius: 8,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        fontSize: 11.5,
                      ),
                      icon: const Icon(Icons.add, size: 15),
                      label: Text(_busy && _busySourceId == null
                          ? '正在处理…'
                          : '新建导入'),
                    ),
                  ),
                ],
              ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _status!,
                    key: const Key('external-calendar-page-status'),
                    style: TextStyle(fontSize: 11, color: TsColors.ready),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const Key('external-calendar-page-error'),
                    style: TextStyle(fontSize: 11, color: TsColors.blocked),
                  ),
                ),
              // 列表前间距只在确实有来源时使用：零来源保持“来源 0 个 + 新建导入”
              // 的紧凑空态，最后一个来源删除后同样恢复紧凑。
              if (sources.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (var i = 0; i < sources.length; i++) ...[
                  if (i > 0) const SettingsCardDivider(),
                  _sourceCard(sources[i]),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourceCard(ExternalCalendarSource source) {
    final snapshot = _service.snapshotOf(source.id);
    final eventCount = snapshot?.events.length ?? source.stats.readEvents;
    final stats = source.stats;
    final hash = source.contentHash.length >= 8
        ? source.contentHash.substring(0, 8)
        : source.contentHash;
    final busySource = _busySourceId == source.id;
    return Padding(
      key: Key('external-calendar-source-${source.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      key: Key('external-calendar-source-name-${source.id}'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: source.enabled
                            ? TsColors.textPrimary
                            : TsColors.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '范围 ${source.dateFrom} 至 ${source.dateTo} · '
                      '$eventCount 条事件 · ${stats.expandedInstances} 个实例 · '
                      '占用 ${stats.busyMinutes} 分钟',
                      key: Key('external-calendar-source-range-${source.id}'),
                      style: TextStyle(
                          fontSize: 11.5, height: 1.5, color: TsColors.textSecondary),
                    ),
                    Text(
                      '哈希 $hash · 第 ${source.revision} 版 · 导入于 '
                      '${_formatImportedAt(source.importedAt)} · 时区 ${source.timezoneId}',
                      key: Key('external-calendar-source-meta-${source.id}'),
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: TsColors.textFaint),
                    ),
                    Text(
                      '诊断：透明 ${stats.transparentEvents} · 取消 '
                      '${stats.cancelledEvents} · 暂定实例 ${stats.tentativeInstances} · '
                      '警告 ${stats.warningCount} · 不支持 ${stats.unsupportedCount}',
                      key: Key('external-calendar-source-diagnostics-${source.id}'),
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: TsColors.textFaint),
                    ),
                    Text(
                      '策略：${_busyPolicyLabel(source.policy.busyPolicy)}'
                      '${source.policy.floatingConfirmed ? ' · 无时区时间按 ${source.policy.floatingTimezoneId} 解释' : ''}',
                      style: TextStyle(
                          fontSize: 10.5, height: 1.5, color: TsColors.textFaint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    key: Key('external-calendar-source-toggle-${source.id}'),
                    value: source.enabled,
                    onChanged: busySource || _busy
                        ? null
                        : (value) => _toggleEnabled(source, value),
                  ),
                  Text(
                    source.enabled ? '已启用' : '已停用',
                    style: TextStyle(
                        fontSize: 10, color: TsColors.textFaint),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              SettingsOutlinedButton(
                key: Key('external-calendar-source-update-${source.id}'),
                label: '更新（重新选文件）',
                onPressed: _busy ? null : () => _openImport(existing: source),
              ),
              SettingsOutlinedButton(
                key: Key('external-calendar-source-rename-${source.id}'),
                label: '改名',
                onPressed: _busy ? null : () => _rename(source),
              ),
              SettingsOutlinedButton(
                key: Key('external-calendar-source-delete-${source.id}'),
                label: '删除',
                onPressed: _busy ? null : () => _delete(source),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _busyPolicyLabel(ExternalBusyPolicy policy) {
    switch (policy) {
      case ExternalBusyPolicy.opaqueOnly:
        return '仅非透明占用';
      case ExternalBusyPolicy.tentativeCountsAsBusy:
        return '暂定也算占用';
      case ExternalBusyPolicy.allCountsAsBusy:
        return '透明也算占用';
    }
  }

  /// ISO8601 → `yyyy-MM-dd HH:mm`（无法解析时原样显示，不猜测）。
  static String _formatImportedAt(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _short(Object error) {
    final text = error.toString().replaceAll('\n', ' ');
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }
}
