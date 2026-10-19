// Dependency graph view — a DAG drawn as a layered tree.
//
// Data is a DAG, so every task is drawn exactly once and ALL predecessor edges are
// kept. A single-parent TreeView would silently drop the multi-parent edges that
// this app exists to show.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/display.dart';
import '../state/task_interaction.dart';
import './widgets/bezier_ui.dart';
import 'theme.dart';

class DagGraphView extends StatefulWidget {
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;

  const DagGraphView({
    super.key,
    required this.snapshot,
    required this.interaction,
  });

  @override
  State<DagGraphView> createState() => _DagGraphViewState();
}

class _DagGraphViewState extends State<DagGraphView>
    with TickerProviderStateMixin {
  // Node box: tall enough for a TWO-LINE title plus the status row. At 60px the title
  // and the "状态 + 工时" row overlapped, so the estimate was clipped at the bottom edge.
  static const double nodeWidth = 220;
  static const double nodeHeight = 78;
  static const double hGap = 24;
  static const double vGap = 44;
  static const double padding = 22;

  final TransformationController _transform = TransformationController();
  late AnimationController _anim;
  Animation<Matrix4>? _matrixAnim;

  final Map<String, Offset> _positions = {};
  final Map<String, GlobalKey> _nodeKeys = {};
  final List<Timer> _anchorTimers = [];
  Size _content = const Size(400, 300);
  Size _viewport = const Size(400, 300);
  Size? _lastViewport;
  String _fittedFor = '';

  GlobalKey _nodeKeyFor(String id) =>
      _nodeKeys.putIfAbsent(id, () => GlobalKey());

  /// Initial view and resize both center the actual content bounds. Once the user has
  /// panned/zoomed, rebuilds must not steal the transform back.
  void _scheduleInitialView() {
    final signature = widget.snapshot.tasks.map((t) => t.id).join(',');
    final changedPlan = _fittedFor != signature;
    final resized = _lastViewport != null && _lastViewport != _viewport;
    _lastViewport = _viewport;
    if (!changedPlan && !resized) return;
    if (changedPlan) {
      _fittedFor = signature;
    }
    // A real viewport resize (composer expand, splitter drag) must refit; a plain
    // rebuild after the user panned/zoomed must not.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitAll(animate: false, readable: true);
    });
  }

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        final a = _matrixAnim;
        if (a != null) _transform.value = a.value;
      });
    widget.interaction.registerRevealer(_reveal);
  }

  @override
  void didUpdateWidget(covariant DagGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interaction != widget.interaction) {
      oldWidget.interaction.unregisterRevealer(_reveal);
      widget.interaction.registerRevealer(_reveal);
    }
  }

  @override
  void dispose() {
    widget.interaction.unregisterRevealer(_reveal);
    for (final t in _anchorTimers) {
      t.cancel();
    }
    _anchorTimers.clear();
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- layout

  void _layout() {
    _positions.clear();
    final byLevel = <int, List<DisplayTask>>{};
    for (final t in widget.snapshot.tasks) {
      byLevel.putIfAbsent(t.level, () => <DisplayTask>[]).add(t);
    }
    final levels = byLevel.keys.toList()..sort();
    var maxPerRow = 0;
    final rowWidths = <int, double>{};
    for (final level in levels) {
      final count = byLevel[level]!.length;
      maxPerRow = math.max(maxPerRow, count);
      rowWidths[level] =
          count * nodeWidth + math.max(0, count - 1) * hGap;
    }
    final maxRowWidth = rowWidths.values.fold<double>(0, math.max);
    /*
     * VERTICAL layout: dependency level runs top → bottom.
     *   level 0 (no predecessors, executed first) is the TOP row;
     *   deeper levels are drawn below.
     * Within one level, tasks are ordered left → right by suggested order.
     *
     * Every row shares the same horizontal centre axis. The widest row is the
     * reference; narrower rows are offset by half the difference instead of starting
     * at the same left margin.
     */
    for (var levelIndex = 0; levelIndex < levels.length; levelIndex++) {
      final level = levels[levelIndex];
      final items = byLevel[level]!;
      items.sort((a, b) {
        final ao = widget.snapshot.orderIndex(a.id);
        final bo = widget.snapshot.orderIndex(b.id);
        final av = ao == 0 ? 1 << 20 : ao;
        final bv = bo == 0 ? 1 << 20 : bo;
        final byOrder = av.compareTo(bv);
        return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
      });
      final rowWidth = rowWidths[level]!;
      final startX = padding + (maxRowWidth - rowWidth) / 2;
      for (var column = 0; column < items.length; column++) {
        _positions[items[column].id] = Offset(
          startX + column * (nodeWidth + hGap),
          padding + levelIndex * (nodeHeight + vGap),
        );
      }
    }
    _content = Size(
      padding * 2 + math.max(1, maxPerRow) * nodeWidth +
          math.max(0, maxPerRow - 1) * hGap,
      padding * 2 + math.max(1, levels.length) * nodeHeight +
          math.max(0, levels.length - 1) * vGap,
    );
  }

  void _fitAll({bool animate = true, bool readable = false}) {
    if (_positions.isEmpty || _viewport.isEmpty) return;
    const side = 16.0;
    const bottomReserve = 54.0;
    final availableW = math.max(40.0, _viewport.width - side * 2);
    final availableH =
        math.max(40.0, _viewport.height - side * 2 - bottomReserve);
    final sx = availableW / _content.width;
    final sy = availableH / _content.height;
    final rawScale = math.min(1.0, math.min(sx, sy));
    // Initial/resize view keeps labels readable and lets a large graph pan. The
    // explicit “适应全部” button may shrink further to show the whole graph.
    final scale = rawScale.clamp(readable ? 0.55 : 0.25, 1.6);
    final center = Offset(_content.width / 2, _content.height / 2);
    final tx = _viewport.width / 2 - center.dx * scale;
    final ty = (availableH / 2) - center.dy * scale + side;
    _applyView(_viewMatrix(scale, tx, ty), animate: animate);
  }

  void _applyView(Matrix4 target, {bool animate = true}) {
    if (!animate) {
      _anim.stop();
      _matrixAnim = null;
      _transform.value = target;
      // The fit runs from a post-frame callback; schedule one more frame so the
      // zoom-percent ValueListenableBuilder reflects the matrix immediately.
      if (mounted) setState(() {});
      return;
    }
    _animateTo(target);
  }

  /// Builds the InteractiveViewer matrix explicitly.
  /// (Matrix4.translate/scale are deprecated; setting the entries keeps the same
  /// semantics without deprecation noise.)
  static Matrix4 _viewMatrix(double scale, double tx, double ty) {
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, tx);
    m.setEntry(1, 3, ty);
    return m;
  }

  /// 2D scale only. `getMaxScaleOnAxis` includes the identity Z axis (1.0), so it
  /// reports 100% for a 0.58 graph and hides the real zoom level.
  static double _scaleOf(Matrix4 m) => m.getRow(0)[0].abs();

  /// Scrolls the minimum amount needed to bring [id] into view.
  ///
  /// Deliberately NOT centering: centering the target used to shove the whole graph
  /// sideways (selecting the middle task made the graph look centred instead of
  /// left-aligned). A small margin keeps the node away from the pane edge.
  void _reveal(String id) {
    final pos = _positions[id];
    if (pos == null) return;
    final scale = _scaleOf(_transform.value).clamp(0.25, 1.6);
    const margin = 16.0;
    const headerPad = 8.0;
    final current = _transform.value;
    var tx = current.getRow(0)[3];
    var ty = current.getRow(1)[3];

    final left = pos.dx * scale + tx;
    final top = pos.dy * scale + ty;
    final right = left + nodeWidth * scale;
    final bottom = top + nodeHeight * scale;
    final vw = _viewport.width;
    final vh = _viewport.height;

    // Horizontal: only move when the node is outside the comfortable band.
    if (left < margin) {
      tx += margin - left;
    } else if (right > vw - margin) {
      tx -= right - (vw - margin);
    }
    // Vertical: same idea, leaving room for the pane header above.
    if (top < margin + headerPad) {
      ty += margin + headerPad - top;
    } else if (bottom > vh - margin) {
      ty -= bottom - (vh - margin);
    }
    if (tx == current.getRow(0)[3] && ty == current.getRow(1)[3]) return;
    _animateTo(_viewMatrix(scale, tx, ty));
    _anchorTimers.add(Timer(const Duration(milliseconds: 320), () {
      _captureAnchor(id);
    }));
  }

  void _captureAnchor(String id) {
    if (!mounted) return;
    final box = _nodeKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.interaction.setAnchor(
      id,
      box.localToGlobal(Offset.zero) & box.size,
      view: 'dag',
    );
  }

  void _animateTo(Matrix4 target) {
    _matrixAnim = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.snapshot;
    if (snap.tasks.isEmpty) {
      return const Center(child: Text('还没有任务'));
    }
    _layout();

    final selected = widget.interaction.selectedTaskId;
    final highlighted = <String>{};
    if (selected != null) {
      highlighted.add(selected);
      final t = snap.byId(selected);
      if (t != null) {
        for (final p in t.predecessors) {
          highlighted.add(p.id);
        }
        for (final u in t.unlocks) {
          highlighted.add(u.id);
        }
      }
    }

    return LayoutBuilder(builder: (context, constraints) {
      _viewport = Size(constraints.maxWidth, constraints.maxHeight);
      _scheduleInitialView();
      return Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transform,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(240),
              minScale: 0.25,
              maxScale: 1.8,
              child: SizedBox(
                width: math.max(_content.width, constraints.maxWidth),
                height: math.max(_content.height, constraints.maxHeight),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _EdgePainter(
                          snapshot: snap,
                          positions: _positions,
                          nodeWidth: nodeWidth,
                          nodeHeight: nodeHeight,
                          highlighted: highlighted,
                        ),
                      ),
                    ),
                    for (final task in snap.tasks)
                      if (_positions[task.id] != null)
                        Positioned(
                          left: _positions[task.id]!.dx,
                          top: _positions[task.id]!.dy,
                          width: nodeWidth,
                          height: nodeHeight,
                          child: KeyedSubtree(
                            key: _nodeKeyFor(task.id),
                            child: _TaskNode(
                              key: ValueKey('dag-node-${task.id}'),
                              task: task,
                              snapshot: snap,
                              interaction: widget.interaction,
                              selected: selected == task.id,
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: ValueListenableBuilder<Matrix4>(
              valueListenable: _transform,
              builder: (context, matrix, _) {
                final percent =
                    ( _scaleOf(matrix) * 100).round().clamp(25, 180);
                return Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: bezierDecoration(
                        color: TsColors.surface,
                        radius: 7,
                        border: Border.all(color: TsColors.border),
                      ),
                      child: Text('$percent%',
                          key: const Key('dag-zoom-percent'),
                          style: TextStyle(
                              fontSize: 11, color: TsColors.textSecondary)),
                    ),
                    const SizedBox(width: 6),
                    _ZoomButton(
                      icon: Icons.center_focus_strong_outlined,
                      tooltip: '定位当前任务',
                      onTap: selected == null
                          ? null
                          : () => _reveal(selected),
                    ),
                    const SizedBox(width: 6),
                    _ZoomButton(
                      icon: Icons.crop_free,
                      tooltip: '实际大小（100%）',
                      onTap: _actualSize,
                    ),
                    const SizedBox(width: 6),
                    _ZoomButton(
                      icon: Icons.fit_screen_outlined,
                      tooltip: '适应全部',
                      onTap: () => _fitAll(),
                    ),
                    const SizedBox(width: 6),
                    _ZoomButton(
                      icon: Icons.add,
                      tooltip: '放大',
                      onTap: () => _zoomBy(1.2),
                    ),
                    const SizedBox(width: 6),
                    _ZoomButton(
                      icon: Icons.remove,
                      tooltip: '缩小',
                      onTap: () => _zoomBy(1 / 1.2),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    });
  }

  void _actualSize() {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final scene = _transform.toScene(center);
    _animateTo(_viewMatrix(1.0, center.dx - scene.dx, center.dy - scene.dy));
  }

  void _zoomBy(double factor) {
    final current = _scaleOf(_transform.value);
    final next = (current * factor).clamp(0.25, 1.8);
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final scene = _transform.toScene(center);
    _animateTo(_viewMatrix(
      next,
      center.dx - scene.dx * next,
      center.dy - scene.dy * next,
    ));
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _ZoomButton({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: TsColors.surface,
        elevation: 1,
        shape: const BezierRoundedRectangleBorder(radius: 8),
        child: InkWell(
          customBorder: const BezierRoundedRectangleBorder(radius: 8),
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(icon,
                size: 17,
                color: onTap == null
                    ? TsColors.textFaint
                    : TsColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _TaskNode extends StatelessWidget {
  final DisplayTask task;
  final DisplaySnapshot snapshot;
  final TaskInteraction interaction;
  final bool selected;

  const _TaskNode({
    super.key,
    required this.task,
    required this.snapshot,
    required this.interaction,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final palette = StatusPalette.of(task.status);
    final order = snapshot.orderIndex(task.id);
    return MouseRegion(
      onEnter: (_) {
        final box = context.findRenderObject() as RenderBox?;
        Rect? rect;
        if (box != null && box.hasSize) {
          rect = box.localToGlobal(Offset.zero) & box.size;
        }
        interaction.enterTask(task.id, anchor: rect, view: 'dag');
      },
      onExit: (_) => interaction.leaveTask(),
      child: GestureDetector(
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          final rect = box == null || !box.hasSize
              ? null
              : box.localToGlobal(Offset.zero) & box.size;
          interaction.selectAndReveal(task.id, anchor: rect, view: 'dag');
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: bezierDecoration(
            color: TsColors.surface,
            radius: 10,
            border: Border.all(
              color: selected ? TsColors.accent : TsColors.border,
              width: selected ? 1.8 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.10 : 0.04),
                blurRadius: selected ? 10 : 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Pinned to the top two lines; the status row below always gets its space.
              SizedBox(
                height: 32,
                child: Text(
                  task.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
              Row(
                children: [
                  if (order > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: bezierDecoration(
                        color: TsColors.accentSoft,
                        radius: 4,
                      ),
                      child: Text(
                        '$order',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: TsColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(color: palette.foreground, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    task.statusText,
                    style: TextStyle(fontSize: 10.5, color: palette.foreground),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.estimateLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 10.5, color: TsColors.textFaint),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final DisplaySnapshot snapshot;
  final Map<String, Offset> positions;
  final double nodeWidth;
  final double nodeHeight;
  final Set<String> highlighted;

  _EdgePainter({
    required this.snapshot,
    required this.positions,
    required this.nodeWidth,
    required this.nodeHeight,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final faint = Paint()
      ..color = TsColors.textFaint
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final strong = Paint()
      ..color = TsColors.accent
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;

    for (final task in snapshot.tasks) {
      final to = positions[task.id];
      if (to == null) continue;
      for (final pred in task.predecessors) {
        final from = positions[pred.id];
        if (from == null) continue;
        final hot = highlighted.contains(task.id) && highlighted.contains(pred.id);
        /*
         * Vertical layout: edges leave the parent's BOTTOM edge and enter the child's
         * TOP edge, so reading the graph top-down matches the execution order.
         */
        final start = Offset(from.dx + nodeWidth / 2, from.dy + nodeHeight);
        final end = Offset(to.dx + nodeWidth / 2, to.dy);
        final dy = math.max(24.0, (end.dy - start.dy) * 0.45);
        final path = Path()
          ..moveTo(start.dx, start.dy)
          ..cubicTo(start.dx, start.dy + dy, end.dx, end.dy - dy, end.dx, end.dy);
        canvas.drawPath(path, hot ? strong : faint);
        // Arrow head pointing down into the child node.
        final arrow = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(end.dx - 4, end.dy - 7)
          ..lineTo(end.dx + 4, end.dy - 7)
          ..close();
        canvas.drawPath(arrow,
            hot ? (Paint()..color = TsColors.accent) : (Paint()..color = TsColors.textFaint));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) =>
      old.positions != positions ||
      old.highlighted != highlighted ||
      old.snapshot != snapshot;
}

