// Bottom strip that replaces the old "big notes box":
// three counters (待确认 / 受阻 / 分析假设) that expand into sectioned cards.
// Each card can jump to the task it refers to.

import 'package:flutter/material.dart';

import '../model/display.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class NotesPanel extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;
  final VoidCallback? onJumpToTask;

  const NotesPanel({
    super.key,
    required this.snapshot,
    required this.interaction,
    this.onJumpToTask,
  });

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

class _NotesPanelState extends State<NotesPanel> {
  bool _expanded = false;

  List<NoteView> _of(String kind) =>
      widget.snapshot.notes.where((n) => n.kind == kind).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final questions = _of('question');
    final blocked = _of('blocked');
    final assumptions = _of('assumption');
    final total = questions.length + blocked.length + assumptions.length;

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: TsColors.border)),
        color: TsColors.surface,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: total == 0 ? null : () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  _Counter(
                      label: '待确认',
                      count: questions.length,
                      color: TsColors.pending,
                      bg: TsColors.pendingSoft),
                  const SizedBox(width: 8),
                  _Counter(
                      label: '受阻',
                      count: blocked.length,
                      color: TsColors.blocked,
                      bg: TsColors.blockedSoft),
                  const SizedBox(width: 8),
                  _Counter(
                      label: '分析假设',
                      count: assumptions.length,
                      color: TsColors.waiting,
                      bg: TsColors.waitingSoft),
                  const Spacer(),
                  if (total == 0)
                    Text('没有需要你确认的条目',
                        style: TextStyle(fontSize: 11.5, color: TsColors.textFaint))
                  else
                    Row(
                      children: [
                        Text(_expanded ? '收起' : '展开',
                            style: TextStyle(
                                fontSize: 11.5, color: TsColors.textSecondary)),
                        Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                            size: 18, color: TsColors.textSecondary),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && total > 0)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (questions.isNotEmpty)
                      _Group(
                        title: '待确认',
                        color: TsColors.pending,
                        items: questions,
                        interaction: widget.interaction,
                        onJump: widget.onJumpToTask,
                      ),
                    if (blocked.isNotEmpty)
                      _Group(
                        title: '受阻',
                        color: TsColors.blocked,
                        items: blocked,
                        interaction: widget.interaction,
                        onJump: widget.onJumpToTask,
                      ),
                    if (assumptions.isNotEmpty)
                      _Group(
                        title: '分析假设',
                        color: TsColors.waiting,
                        items: assumptions,
                        interaction: widget.interaction,
                        onJump: widget.onJumpToTask,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final Color bg;

  const _Counter({
    required this.label,
    required this.count,
    required this.color,
    required this.bg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: bezierDecoration(color: bg, radius: 14),
      child: Text(
        '$label $count',
        style: TextStyle(fontSize: 11.5, color: color),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final Color color;
  final List<NoteView> items;
  final TaskInteraction interaction;
  final VoidCallback? onJump;

  const _Group({
    required this.title,
    required this.color,
    required this.items,
    required this.interaction,
    this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final n in items)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: bezierDecoration(
                color: TsColors.background,
                radius: 8,
                border: Border.all(color: TsColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.text, style: const TextStyle(fontSize: 12, height: 1.45)),
                  if (n.tasks.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in n.tasks)
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            backgroundColor: TsColors.accentSoft,
                            side: BorderSide.none,
                            labelStyle: TextStyle(
                                fontSize: 11, color: TsColors.accent),
                            label: Text(t.name),
                            onPressed: () {
                              interaction.selectAndReveal(t.id);
                              onJump?.call();
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

