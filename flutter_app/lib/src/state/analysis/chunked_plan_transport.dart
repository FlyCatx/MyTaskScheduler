// 把现有原生“计划分析”通道适配成分块分析协调器的 transport。
//
// 背景：ts_bridge 的 analyze 通道返回**归一化计划**（tasks/notes），不提供模型
// 原文。C 侧按发送顺序把材料标成“文段K”，并按空行把每段切成“段落M”，模型返回的
// tasks[].sourceRefs 形如 `文段1:段落2`。本适配层据此建立显式来源映射：
//   * 只有能映射到本次请求真实片段的引用才进入 sourceIds；
//   * 原始引用（段落级精度）通过 `sourceRefBySegment` 原样保留，不降级成“某一段”；
//   * 不生成 quote：本通道拿不到模型给的引句，片段原文不是模型证据，不能冒充；
//   * 无法映射/缺失引用的任务不生成事实，改写为 notes 交给用户确认，绝不用
//     “按顺序轮询分配片段”之类的办法伪造来源。
//
// 归并阶段：本通道拿不到模型原文，不做模型级语义归并；返回结构合法的空归并结果，
// 等价/矛盾由本地事实账本（fact_ledger）按来源身份与事实等价完成。

import 'dart:convert';

import 'chunked_coordinator.dart';

/// 发送一块“计划分析”请求，返回原生归一化计划（null = 没有可用结果）。
typedef ChunkPlanSender = Future<Map<String, dynamic>?> Function(
    ChunkRequest request);

/// 一个块可引用的真实片段（顺序与 C 侧“文段1..N”一致）。
typedef ChunkSlice = ({String segmentId, String text});

class PlanChunkTransport {
  const PlanChunkTransport({required this.sendPlan});

  final ChunkPlanSender sendPlan;

  Future<ChunkResponse> call(ChunkRequest request) async {
    final isMerge = request.payload['analysisPhase']?.toString() == 'merge';
    if (isMerge) {
      return ChunkResponse.ok(jsonEncode(<String, dynamic>{
        'duplicates': <dynamic>[],
        'contradictions': <dynamic>[],
        'notes': <String>[
          '本构建未启用模型原文通道：归并阶段不请求模型，等价合并由本地事实账本完成',
        ],
      }));
    }
    try {
      final plan = await sendPlan(request);
      if (plan == null) {
        return const ChunkResponse.failure(
          errorKind: 'empty_output',
          error: '模型没有返回可解析的计划',
          retryable: true,
        );
      }
      final slices = _slicesOf(request);
      if (slices.isEmpty) {
        // 没有片段来源就无法给出可信引用：宁可判失败，也不编造来源。
        return const ChunkResponse.failure(
          errorKind: 'missing_segments',
          error: '该块没有片段来源 ID，拒绝生成无来源事实',
          retryable: false,
        );
      }
      return ChunkResponse.ok(planToFactJson(plan, slices));
    } catch (e) {
      return ChunkResponse.failure(
        errorKind: 'transport',
        error: '分块请求失败：$e',
        retryable: true,
      );
    }
  }

  /// 取本块的（片段 ID, 片段原文）对：两者都来自请求本身的真实材料。
  List<ChunkSlice> _slicesOf(ChunkRequest request) {
    final rawIds = request.payload['segmentIds'];
    final ids = rawIds is List
        ? rawIds
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    if (ids.isEmpty) return const <ChunkSlice>[];
    final rawSources = request.payload['sources'];
    final sources = rawSources is List
        ? rawSources.whereType<Map>().toList(growable: false)
        : const <Map>[];
    return <ChunkSlice>[
      for (var i = 0; i < ids.length; i++)
        (
          segmentId: ids[i],
          text: i < sources.length ? (sources[i]['text']?.toString() ?? '') : '',
        ),
    ];
  }
}

/// 把原生归一化计划转成协调器解析器接受的候选事实 JSON。
///
/// 只做结构映射，不推断材料里没有的内容：
///   * 每条事实的来源 ID 是该块的真实片段 ID，通过任务的 sourceRefs 反查得到；
///   * 引文（quote）留空：本通道没有模型原文，也不把片段前缀当引文；
///   * 无法映射的引用与无来源任务不会变成事实，统一写进 notes 供人工确认。
String planToFactJson(Map<String, dynamic> plan, List<ChunkSlice> slices) {
  final rawTasks = (plan['tasks'] as List<dynamic>?) ?? const <dynamic>[];
  final tasks =
      rawTasks.whereType<Map<String, dynamic>>().toList(growable: false);
  final nameById = <String, String>{
    for (final task in tasks)
      if ((task['id']?.toString() ?? '').trim().isNotEmpty)
        task['id'].toString().trim(): (task['name']?.toString() ?? '').trim(),
  };
  final facts = <Map<String, dynamic>>[];
  final notes = <String>[];
  for (final task in tasks) {
    final name = (task['name']?.toString() ?? '').trim();
    if (name.isEmpty) continue;
    final rawRefs = <String>[
      for (final raw in (task['sourceRefs'] as List<dynamic>?) ?? const [])
        if (raw is String && raw.trim().isNotEmpty) raw.trim(),
    ];
    final sourceIds = <String>[];
    final refBySegment = <String, String>{};
    final unmappedRefs = <String>[];
    for (final rawRef in rawRefs) {
      final resolved = _resolveSourceRef(rawRef, slices);
      if (resolved == null) {
        unmappedRefs.add(rawRef);
        continue;
      }
      if (!sourceIds.contains(resolved.segmentId)) {
        sourceIds.add(resolved.segmentId);
      }
      refBySegment.putIfAbsent(resolved.segmentId, () => rawRef);
    }
    if (sourceIds.isEmpty) {
      // 没有可核验来源的任务不生成事实；保留原始线索与原因，交给用户确认。
      notes.add(unmappedRefs.isEmpty
          ? '任务「$name」没有来源引用，未自动生成；请核对材料后人工确认'
          : '任务「$name」的来源引用（${unmappedRefs.join('、')}）无法定位到本次材料，'
              '未自动生成；请人工核对');
      continue;
    }
    if (unmappedRefs.isNotEmpty) {
      notes.add('任务「$name」的部分来源引用无法定位（${unmappedRefs.join('、')}），'
          '仅保留可核验的来源');
    }
    final dependsOn = <String>[
      for (final raw in (task['dependsOn'] as List<dynamic>?) ?? const <dynamic>[])
        if (raw is String && raw.trim().isNotEmpty)
          (nameById[raw.trim()] ?? raw.trim()),
    ];
    final deadline = (task['deadline']?.toString() ?? '').trim();
    final hours = task['estimatedHours'];
    facts.add(<String, dynamic>{
      'kind': 'task',
      'taskHint': name,
      // object 让“同名不同对象”可按对象区分；本通道没有对象字段时用任务名，
      // 是否等价由账本再做去重判定（同名不同日期不会无条件合并）。
      'object': name,
      'sourceIds': sourceIds,
      if (refBySegment.isNotEmpty) 'sourceRefBySegment': refBySegment,
      if (deadline.isNotEmpty) 'dueDate': deadline,
      if (hours is num && hours > 0) 'hours': hours,
      if (dependsOn.isNotEmpty) 'dependsOn': dependsOn,
    });
  }
  final planNotes = <String>[
    for (final note in (plan['notes'] as List<dynamic>?) ?? const <dynamic>[])
      if (note is Map && (note['text']?.toString() ?? '').trim().isNotEmpty)
        note['text'].toString().trim(),
  ];
  final summary = (plan['summary']?.toString() ?? '').trim();
  return jsonEncode(<String, dynamic>{
    'facts': facts,
    if (planNotes.isNotEmpty || notes.isNotEmpty) 'notes': <String>[...planNotes, ...notes],
    if (summary.isNotEmpty) 'summary': summary,
  });
}

final RegExp _sourceRefPattern =
    RegExp(r'^(?:文段|文件)\s*(\d+)\s*[:：]\s*段落\s*(\d+)$');

/// 解析 C 侧来源引用（`文段K:段落M` / `文件K:段落M`），返回本次请求真实存在的
/// 片段；越界或格式不符返回 null（交给调用方记为不可核验，不猜）。
({String segmentId, int paragraph})? _resolveSourceRef(
  String rawRef,
  List<ChunkSlice> slices,
) {
  final match = _sourceRefPattern.firstMatch(rawRef);
  if (match == null) return null;
  final sourceIndex = int.tryParse(match.group(1) ?? '');
  final paragraph = int.tryParse(match.group(2) ?? '');
  if (sourceIndex == null || paragraph == null) return null;
  if (sourceIndex < 1 || sourceIndex > slices.length || paragraph < 1) {
    return null;
  }
  return (segmentId: slices[sourceIndex - 1].segmentId, paragraph: paragraph);
}
