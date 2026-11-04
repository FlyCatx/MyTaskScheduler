// 时间表的“编辑事务 + 撤销/重做历史”。
//
// 设计要点：
//   * 一次用户操作 = 一笔 [TimetableTransaction]，before/after 都是完整的
//     [Timetable] 快照，因此撤销/重做恢复的是完整业务数据（日期规则、周规则、
//     state、taskId、reservationId、coverage、revision 等），不是只恢复颜色；
//   * 业务数据相同（只差 revision 等非编辑内容）时 [TimetableHistory.record]
//     返回 false，不入栈、也不清空 redo；
//   * 有真实变化才清空 redo：undo 之后产生新编辑，旧的 redo 分支必须失效；
//   * 容量上限 [defaultCapacity]，超出后丢弃最旧的一笔，内存不会无限增长。
//
// 纯 Dart：不依赖 Flutter Widget，可在 `flutter test` 里直接构造断言。

import 'dart:convert';

import 'timetable.dart';

/// 一次编辑事务：before/after 都是完整 Timetable 快照。
///
/// [label] 是中文动作名（例如 `绘制任务 10:00-11:00`、`复制到 3 天`），
/// 供撤销/重做菜单与提示显示；[affectedDates] 标记这笔事务影响到的日期
/// （yyyy-MM-dd），批量操作时用于界面提示。
class TimetableTransaction {
  const TimetableTransaction({
    required this.label,
    required this.before,
    required this.after,
    this.affectedDates = const <String>{},
  });

  final String label;
  final Timetable before;
  final Timetable after;
  final Set<String> affectedDates;
}

/// past / present / future 三态历史。
///
/// * [record] 记录一笔事务并把 present 更新为 after；
/// * [undo] 返回撤销后的时间表并把当前事务压入 future；
/// * [redo] 从 future 恢复一笔；
/// * [markApplied] 把已提交的时间表设为新基线并清空两栈。
class TimetableHistory {
  TimetableHistory({Timetable? initial, int capacity = defaultCapacity})
      : assert(capacity > 0),
        capacity = capacity,
        _present = initial;

  /// 默认容量上限：200 笔事务。
  static const int defaultCapacity = 200;

  /// 容量上限（构造时固定，> 0）。
  final int capacity;

  Timetable? _present;
  final List<TimetableTransaction> _past = <TimetableTransaction>[];
  final List<TimetableTransaction> _future = <TimetableTransaction>[];

  /// 当前时间表；尚未给 initial 时为 null。
  Timetable? get timetable => _present;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  int get undoDepth => _past.length;
  int get redoDepth => _future.length;

  /// 下一次撤销/重做的动作名；没有时返回 null。
  String? get undoLabel => _past.isEmpty ? null : _past.last.label;
  String? get redoLabel => _future.isEmpty ? null : _future.last.label;

  /// 记录一次事务。
  ///
  /// before/after 的业务数据相同（忽略 revision）时不入栈并返回 false，
  /// 也不会清空 redo；有真实变化时清空 redo（分叉后旧的重做路径失效）。
  bool record(TimetableTransaction transaction) {
    if (timetableEquals(transaction.before, transaction.after)) return false;
    _past.add(transaction);
    if (_past.length > capacity) _past.removeAt(0);
    _future.clear();
    _present = transaction.after;
    return true;
  }

  /// 撤销一笔；返回撤销后的时间表，无历史返回 null。
  Timetable? undo() {
    if (_past.isEmpty) return null;
    final transaction = _past.removeLast();
    _future.add(transaction);
    if (_future.length > capacity) _future.removeAt(0);
    _present = transaction.before;
    return _present;
  }

  /// 重做一笔；返回重做后的时间表，无历史返回 null。
  Timetable? redo() {
    if (_future.isEmpty) return null;
    final transaction = _future.removeLast();
    _past.add(transaction);
    if (_past.length > capacity) _past.removeAt(0);
    _present = transaction.after;
    return _present;
  }

  /// 应用成功后的新基线：present 换成 [baseline]，清空 past/future。
  void markApplied(Timetable baseline) {
    _present = baseline;
    _past.clear();
    _future.clear();
  }

  /// 仅供 [TimetableDraft] 的“进行中笔画”更新当前快照：不产生历史、
  /// 不动两栈。笔画提交时由 `record` 一次性记一笔完整事务。
  void setPresent(Timetable next) {
    _present = next;
  }

  /// 只清空两栈，保留当前时间表（例如界面重建但数据未提交时的重置）。
  void clear() {
    _past.clear();
    _future.clear();
  }
}

/// 业务数据等价判断：忽略 revision（版本号不是用户编辑的内容）。
///
/// 画布颜色、日期规则、周规则、state、taskId、reservationId、coverage 等
/// 全部参与比较，因此“无变化不入历史”不会漏掉绑定关系的变化。
bool timetableEquals(Timetable a, Timetable b) {
  if (identical(a, b)) return true;
  final left = a.toJson()..remove('revision');
  final right = b.toJson()..remove('revision');
  return jsonEncode(left) == jsonEncode(right);
}
