// 日程之间的时间重叠检测（任务 11）。
//
// 产品规则：
//   * 开始/结束或“占用排程时间”变化后，用**全部有效占用**做重叠检测，
//     列表的搜索/分类/会话筛选只影响展示，不减少这里看到的冲突；
//   * 只比较真正占用排程的定时实例；全天日程按日期展示，不折算成分钟占用；
//   * 编辑自身时排除原记录：系列编辑排除整个系列，单次编辑只排除本次实例；
//   * 刚好首尾相接（end == start）重叠为 0 分钟，不列为冲突；
//   * 结果按重叠起点、稳定 key 排序，供界面逐条展示“相交对象 + 实际重叠分钟”。

import 'schedule_expander.dart';

/// 一次实际重叠：相交的实例、重叠区间与分钟数。
class ScheduleOverlap {
  const ScheduleOverlap({
    required this.occurrence,
    required this.overlapStartUtc,
    required this.overlapEndUtc,
    required this.overlapMinutes,
  });

  final ScheduleOccurrence occurrence;
  final DateTime overlapStartUtc;
  final DateTime overlapEndUtc;

  /// 向下取整的分钟数；首尾相接时为 0（不会出现在结果里）。
  final int overlapMinutes;

  String get eventId => occurrence.eventId;
  String get occurrenceKey => occurrence.occurrenceKey;
  String get title => occurrence.title;
}

/// 找出 [startUtc, endUtc) 与 [candidates] 中实例的实际重叠。
///
/// [candidates] 必须是**未过滤**的展开结果（只加载当前可见范围即可）。
/// [blocksScheduling] 为 false 时本日程不占用排程，自然没有排程冲突。
List<ScheduleOverlap> findScheduleOverlaps({
  required DateTime startUtc,
  required DateTime endUtc,
  required List<ScheduleOccurrence> candidates,
  bool blocksScheduling = true,
  String? excludeEventId,
  String? excludeOccurrenceKey,
}) {
  if (!blocksScheduling) return const <ScheduleOverlap>[];
  final start = startUtc.toUtc();
  final end = endUtc.toUtc();
  if (!end.isAfter(start)) return const <ScheduleOverlap>[];

  final out = <ScheduleOverlap>[];
  for (final other in candidates) {
    if (other.allDay || !other.blocksScheduling) continue;
    if (excludeEventId != null && other.eventId == excludeEventId) continue;
    if (excludeOccurrenceKey != null &&
        other.occurrenceKey == excludeOccurrenceKey) {
      continue;
    }
    final otherStart = other.startUtc;
    final otherEnd = other.endUtc;
    if (otherStart == null || otherEnd == null) continue;
    final overlapStart = otherStart.isAfter(start) ? otherStart : start;
    final overlapEnd = otherEnd.isBefore(end) ? otherEnd : end;
    // 首尾相接或完全不在同一区间：重叠分钟为 0，不算冲突。
    if (!overlapEnd.isAfter(overlapStart)) continue;
    out.add(ScheduleOverlap(
      occurrence: other,
      overlapStartUtc: overlapStart.toUtc(),
      overlapEndUtc: overlapEnd.toUtc(),
      overlapMinutes: overlapEnd.difference(overlapStart).inMinutes,
    ));
  }
  out.sort((a, b) {
    final byStart = a.overlapStartUtc.compareTo(b.overlapStartUtc);
    if (byStart != 0) return byStart;
    return a.occurrenceKey.compareTo(b.occurrenceKey);
  });
  return List<ScheduleOverlap>.unmodifiable(out);
}

/// 把重叠按“对方实例”合并分钟数，供详情/编辑器用一行展示。
///
/// 同一实例跨半夜可能被拆成两段（不同 day 列），合并后仍是同一条冲突。
List<ScheduleOverlap> mergeOverlapsByOccurrence(
  List<ScheduleOverlap> overlaps,
) {
  final byKey = <String, ScheduleOverlap>{};
  for (final overlap in overlaps) {
    final existing = byKey[overlap.occurrenceKey];
    if (existing == null) {
      byKey[overlap.occurrenceKey] = overlap;
      continue;
    }
    byKey[overlap.occurrenceKey] = ScheduleOverlap(
      occurrence: existing.occurrence,
      overlapStartUtc: existing.overlapStartUtc.isBefore(overlap.overlapStartUtc)
          ? existing.overlapStartUtc
          : overlap.overlapStartUtc,
      overlapEndUtc: existing.overlapEndUtc.isAfter(overlap.overlapEndUtc)
          ? existing.overlapEndUtc
          : overlap.overlapEndUtc,
      overlapMinutes: existing.overlapMinutes + overlap.overlapMinutes,
    );
  }
  final merged = byKey.values.toList(growable: false)
    ..sort((a, b) {
      final byStart = a.overlapStartUtc.compareTo(b.overlapStartUtc);
      if (byStart != 0) return byStart;
      return a.occurrenceKey.compareTo(b.occurrenceKey);
    });
  return List<ScheduleOverlap>.unmodifiable(merged);
}
