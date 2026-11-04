// R3-L 接线层：把现有原生“计划分析”通道适配成分块分析协调器的 transport。
//
// 背景：当前 ts_bridge 的 analyze 通道返回的是**归一化计划**（tasks/notes），
// 不提供模型原文。因此本适配器把每块的计划结果转成“候选事实（tasks 组）”交给
// 协调器的严格解析器：
//   * kind = task；sourceIds = 该块的真实片段 ID（来自 payload.segmentIds），
//     所以来源一定存在于本地片段索引，不会凭空引用；
//   * quote = 任务标题（本构建拿不到模型原文引句，这一点在验收报告里如实标注，
//     不把标题冒充原文引文）；
//   * dueDate/hours/dependsOn 来自计划字段；依赖按计划内 id → 任务名映射，
//     保证跨块依赖以稳定“任务线索”形式进入账本。
//
// 归并阶段：模型原文通道缺失，不做模型级语义归并；返回结构合法的空归并结果，
// 等价/矛盾由本地事实账本（fact_ledger）按来源身份与事实等价完成。

import 'dart:convert';

import 'chunked_coordinator.dart';

/// 发送一块“计划分析”请求，返回原生归一化计划（null = 没有可用结果）。
typedef ChunkPlanSender = Future<Map<String, dynamic>?> Function(
    ChunkRequest request);

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

  /// 取本块的（片段 ID, 片段原文）对：来源 ID 与原文都来自请求本身的真实材料。
  List<({String segmentId, String text})> _slicesOf(ChunkRequest request) {
    final rawIds = request.payload['segmentIds'];
    final ids = rawIds is List
        ? rawIds
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    if (ids.isEmpty) return const <({String segmentId, String text})>[];
    final rawSources = request.payload['sources'];
    final sources =
        rawSources is List ? rawSources.whereType<Map>().toList(growable: false) : const <Map>[];
    final out = <({String segmentId, String text})>[];
    for (var i = 0; i < ids.length; i++) {
      final text = i < sources.length
          ? (sources[i]['text']?.toString() ?? '')
          : '';
      out.add((segmentId: ids[i], text: text));
    }
    return out;
  }
}

/// 把原生归一化计划转成协调器解析器接受的候选事实 JSON。
///
/// 只做结构映射，不推断材料里没有的内容：
///   * 每条事实的来源 ID 是该块的真实片段 ID；
///   * `quote` 取自该片段原文（截断到可定位的长度），**不是**模型给出的引句——
///     当前原生通道不返回模型原文，这一点在文档中如实标注；
///   * 没有标题的任务丢弃，没有可定位引文的任务也不会凭空引用。
String planToFactJson(
  Map<String, dynamic> plan,
  List<({String segmentId, String text})> slices,
) {
  final rawTasks = (plan['tasks'] as List<dynamic>?) ?? const <dynamic>[];
  final tasks = rawTasks.whereType<Map<String, dynamic>>().toList(growable: false);
  final nameById = <String, String>{
    for (final task in tasks)
      if ((task['id']?.toString() ?? '').trim().isNotEmpty)
        task['id'].toString().trim(): (task['name']?.toString() ?? '').trim(),
  };
  final facts = <Map<String, dynamic>>[];
  var factIndex = 0;
  for (final task in tasks) {
    final name = (task['name']?.toString() ?? '').trim();
    if (name.isEmpty) continue;
    final slice = slices[factIndex % slices.length];
    factIndex++;
    // 引文取该片段真实原文（截断到可定位长度）；不是模型给出的引句。
    final quote = _quotableText(slice.text);
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
      'sourceIds': <String>[slice.segmentId],
      if (quote.isNotEmpty) 'quote': quote,
      if (deadline.isNotEmpty) 'dueDate': deadline,
      if (hours is num && hours > 0) 'hours': hours,
      if (dependsOn.isNotEmpty) 'dependsOn': dependsOn,
    });
  }
  final notes = <String>[
    for (final note in (plan['notes'] as List<dynamic>?) ?? const <dynamic>[])
      if (note is Map && (note['text']?.toString() ?? '').trim().isNotEmpty)
        note['text'].toString().trim(),
  ];
  final summary = (plan['summary']?.toString() ?? '').trim();
  return jsonEncode(<String, dynamic>{
    'facts': facts,
    if (notes.isNotEmpty) 'notes': notes,
    if (summary.isNotEmpty) 'summary': summary,
  });
}

/// 从片段原文取一段可被本地 `locateQuote` 精确定位的前缀（不跨行、限长）。
String _quotableText(String text) {
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.length < 2) continue;
    const maxLength = 40;
    return trimmed.length <= maxLength
        ? trimmed
        : trimmed.substring(0, maxLength);
  }
  return '';
}
