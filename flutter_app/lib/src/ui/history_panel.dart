// Left sidebar, split into three bands so the shell can align them with the right side:
//
//   HistorySidebarHeader  — fixed height, same as the summary bar
//   HistorySidebarList    — scrollable conversation list
//   StorageFooter         — same height band as the composer (bottom row)
//
// Splitting them (instead of one tall Column) is what makes "title bars share a height"
// and "sidebar hint and input box share a baseline" actually true rather than eyeballed.

import 'package:flutter/material.dart';

import '../model/session.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

const double kSidebarWidth = 244;
const double kRailWidth = 40;

enum ConversationListMode { active, archived, trash }

/// Everything the sidebar can do to a conversation. The target id is always captured by
/// the row (never `currentId`), so right-clicking an unselected row is safe.
enum ConversationMenuAction {
  open,
  rename,
  pin,
  unpin,
  archive,
  unarchive,
  export,
  trash,
  restore,
  deletePermanently,
}

/// Shared shell for a sidebar band: same background and right border everywhere, so
/// the three bands still read as one panel.
class _SidebarBand extends StatelessWidget {
  final Widget child;
  final double width;

  const _SidebarBand({required this.child, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: TsColors.sidebar,
        border: Border(right: BorderSide(color: TsColors.border)),
      ),
      child: child,
    );
  }
}

class HistorySidebarHeader extends StatelessWidget {
  final VoidCallback onNew;
  final VoidCallback? onCollapse;

  const HistorySidebarHeader({
    super.key,
    required this.onNew,
    this.onCollapse,
  });

  @override
  Widget build(BuildContext context) {
    return _SidebarBand(
      width: kSidebarWidth,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            const Text('会话',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: '新建会话',
              visualDensity: VisualDensity.compact,
              onPressed: onNew,
              icon: const Icon(Icons.edit_square, size: 17),
            ),
            if (onCollapse != null)
              IconButton(
                tooltip: '收起会话栏',
                visualDensity: VisualDensity.compact,
                onPressed: onCollapse,
                icon: const Icon(Icons.chevron_left, size: 17),
              ),
          ],
        ),
      ),
    );
  }
}

class HistorySidebarList extends StatelessWidget {
  final List<ConversationSummary> summaries;
  final String? currentId;
  final ConversationListMode mode;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<ConversationListMode> onMode;
  final void Function(String id) onOpen;
  final void Function(String id, Offset globalPosition) onMenu;
  final FocusNode? searchFocusNode;

  const HistorySidebarList({
    super.key,
    required this.summaries,
    required this.currentId,
    required this.mode,
    required this.query,
    required this.onQuery,
    required this.onMode,
    required this.onOpen,
    required this.onMenu,
    this.searchFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final pinned = mode == ConversationListMode.active
        ? summaries.where((s) => s.isPinned).toList(growable: false)
        : const <ConversationSummary>[];
    final regular = mode == ConversationListMode.active
        ? summaries.where((s) => !s.isPinned).toList(growable: false)
        : summaries;
    return _SidebarBand(
      width: kSidebarWidth,
      child: Column(
        children: [
          _searchAndModes(),
          Expanded(
            child: summaries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
                    child: Text(
                      query.trim().isEmpty
                          ? switch (mode) {
                              ConversationListMode.active =>
                                '还没有会话。粘贴材料后开始第一次分析。',
                              ConversationListMode.archived => '没有已归档的会话。',
                              ConversationListMode.trash => '最近删除为空。',
                            }
                          : '没有匹配“${query.trim()}”的会话',
                      style:
                          TextStyle(fontSize: 12, color: TsColors.textFaint),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        _sectionLabel('置顶'),
                        for (final s in pinned) _tile(s),
                      ],
                      if (regular.isNotEmpty) ...[
                        if (pinned.isNotEmpty) _sectionLabel('最近'),
                        for (final s in regular) _tile(s),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 3),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.4,
                color: TsColors.textFaint)),
      );

  Widget _searchAndModes() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Column(
        children: [
          SizedBox(
            height: 30,
            child: _ConversationSearchField(
              key: const Key('conversation-search'),
              query: query,
              hint: mode == ConversationListMode.trash
                  ? '搜索最近删除'
                  : '搜索会话标题',
              onChanged: onQuery,
              focusNode: searchFocusNode,
            ),
          ),
          const SizedBox(height: 5),
          BezierSegments(
            expand: true,
            height: 26,
            items: const [
              BezierSegmentItem('全部'),
              BezierSegmentItem('归档'),
              BezierSegmentItem('回收'),
            ],
            itemKeys: const [
              Key('conversation-mode-active'),
              Key('conversation-mode-archived'),
              Key('conversation-mode-trash'),
            ],
            selected: mode.index,
            onChanged: (index) => onMode(ConversationListMode.values[index]),
          ),
        ],
      ),
    );
  }

  Widget _tile(ConversationSummary s) => _HistoryTile(
        summary: s,
        active: s.id == currentId,
        mode: mode,
        onTap: () => onOpen(s.id),
        onMenu: (position) => onMenu(s.id, position),
      );
}

/// Stateful field so typing does not recreate the controller/caret on every keystroke.
class _ConversationSearchField extends StatefulWidget {
  final String query;
  final String hint;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  const _ConversationSearchField({
    super.key,
    required this.query,
    required this.hint,
    required this.onChanged,
    this.focusNode,
  });

  @override
  State<_ConversationSearchField> createState() =>
      _ConversationSearchFieldState();
}

class _ConversationSearchFieldState extends State<_ConversationSearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(covariant _ConversationSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        onChanged: widget.onChanged,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hint,
          hintStyle: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
          prefixIcon:
              Icon(Icons.search, size: 15, color: TsColors.textFaint),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 28, minHeight: 28),
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          filled: true,
          fillColor: TsColors.surface,
          border: BezierInputBorder(
              radius: 7,
              borderSide: BorderSide(color: TsColors.border)),
          enabledBorder: BezierInputBorder(
              radius: 7,
              borderSide: BorderSide(color: TsColors.border)),
        ),
      );
}

/// Bottom band under the conversation list.
///
/// Reserves the sidebar's width/background so the composer still starts at the same x
/// and both sides of the bottom band share one height. The user entry sits at the very
/// bottom of this band (bottom-left corner of the window).
class SidebarBottomBand extends StatelessWidget {
  final Widget child;

  const SidebarBottomBand({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return _SidebarBand(
      width: kSidebarWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Align(alignment: Alignment.bottomLeft, child: child),
      ),
    );
  }
}

/// Collapsed rail: one narrow band per shell row, so the three rows stay aligned.
class SidebarRail extends StatelessWidget {
  final VoidCallback onExpand;

  const SidebarRail({super.key, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    return _SidebarBand(
      width: kRailWidth,
      child: Center(
        child: IconButton(
          tooltip: '展开会话列表',
          onPressed: onExpand,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.menu, size: 18),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final ConversationSummary summary;
  final bool active;
  final ConversationListMode mode;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  const _HistoryTile({
    required this.summary,
    required this.active,
    required this.mode,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final canMenu = mode != ConversationListMode.trash;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: active ? TsColors.accentSoft : Colors.transparent,
        shape: const BezierRoundedRectangleBorder(radius: 8),
        child: GestureDetector(
          onSecondaryTapDown: canMenu
              ? (d) => onMenu(d.globalPosition)
              : null,
          child: InkWell(
            customBorder: const BezierRoundedRectangleBorder(radius: 8),
            onTap: onTap,
            onLongPress: canMenu
                ? () => onMenu(
                    MediaQuery.of(context).size.center(Offset.zero))
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (summary.isPinned)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(Icons.push_pin_outlined,
                                    size: 12, color: TsColors.textFaint),
                              ),
                            Flexible(
                              child: Text(
                                summary.displayTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: active
                                      ? TsColors.accent
                                      : TsColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${summary.versionCount} 个版本 · ${_when(summary.activityAt)}',
                          style: TextStyle(
                              fontSize: 10.5, color: TsColors.textFaint),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    child: IconButton(
                      key: Key('conversation-menu-${summary.id}'),
                      tooltip: '会话菜单',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 24, height: 24),
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox?;
                        final origin = box == null
                            ? Offset.zero
                            : box.localToGlobal(
                                Offset(box.size.width - 4, 4));
                        onMenu(origin);
                      },
                      icon: Icon(Icons.more_horiz,
                          size: 15, color: TsColors.textFaint),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${t.month}/${t.day}';
  }
}

