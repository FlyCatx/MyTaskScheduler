// Hover-preview / click-to-pin task interaction.
//
// Adapted from the reference interaction model, with the important host contract
// made explicit: revealing a task must actually scroll the list, pan the graph and
// scroll the timeline. Changing only an internal "selected" variable would look
// like the jump worked while the user still cannot see the target.

import 'dart:async';

import 'package:flutter/widgets.dart';

typedef TaskRevealer = void Function(String taskId);

/// A trigger rectangle plus the view that produced it. Keeping the view in the anchor
/// prevents a Gantt interaction from reusing a stale dependency-graph rectangle.
class TaskAnchor {
  final Rect rect;
  final String view;
  const TaskAnchor(this.rect, this.view);
}

class TaskInteraction extends ChangeNotifier {
  static const Duration hoverOpenDelay = Duration(milliseconds: 300);
  static const Duration hoverCloseDelay = Duration(milliseconds: 180);

  String? selectedTaskId;
  String? detailTaskId;
  bool pinned = false;

  /// Global rect of the widget currently hovered, per task id, with its source view.
  final Map<String, TaskAnchor> anchors = {};

  Timer? _openTimer;
  Timer? _closeTimer;
  final List<TaskRevealer> _revealers = [];

  void registerRevealer(TaskRevealer revealer) => _revealers.add(revealer);

  void unregisterRevealer(TaskRevealer revealer) => _revealers.remove(revealer);

  void setAnchor(String id, Rect rect, {required String view}) {
    final old = anchors[id];
    if (old != null && old.rect == rect && old.view == view) return;
    anchors[id] = TaskAnchor(rect, view);
    notifyListeners();
  }

  bool anchorBelongsTo(String id, String view) =>
      anchors[id]?.view == view;

  /// Called when the pointer enters a task node/row. Ignored while pinned.
  void enterTask(String id, {Rect? anchor, String view = 'unknown'}) {
    _closeTimer?.cancel();
    _openTimer?.cancel();
    if (anchor != null) anchors[id] = TaskAnchor(anchor, view);
    if (pinned) return;
    _openTimer = Timer(hoverOpenDelay, () {
      detailTaskId = id;
      notifyListeners();
    });
  }

  void leaveTask() {
    _openTimer?.cancel();
    _scheduleClose();
  }

  void enterDetail() => _closeTimer?.cancel();

  void leaveDetail() => _scheduleClose();

  /// Single entry point for list rows, graph nodes, gantt bars and relation chips.
  /// Selects, pins the detail card and asks every view to bring the task on screen.
  void selectAndReveal(
    String id, {
    Rect? anchor,
    String view = 'unknown',
  }) {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (anchor != null) anchors[id] = TaskAnchor(anchor, view);
    selectedTaskId = id;
    detailTaskId = id;
    pinned = true;
    notifyListeners();
    for (final r in List<TaskRevealer>.from(_revealers)) {
      r(id);
    }
  }

  /// Selects without opening the detail card (plain row click).
  void selectOnly(String id) {
    selectedTaskId = id;
    notifyListeners();
  }

  void closeDetail() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    detailTaskId = null;
    pinned = false;
    notifyListeners();
  }

  /// Called before switching conversation or plan version.
  void reset() {
    selectedTaskId = null;
    anchors.clear();
    closeDetail();
  }

  /// Chart/version switch: cancel hover, close the old popup and forget old anchors
  /// before the new view gets a chance to open its own.
  void switchView() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    detailTaskId = null;
    pinned = false;
    anchors.clear();
    notifyListeners();
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    if (pinned) return;
    _closeTimer = Timer(hoverCloseDelay, closeDetail);
  }

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _revealers.clear();
    super.dispose();
  }
}

