// 模型输出严格解析器 — 分块抽取结果与归并结果都必须先过这里。
//
// 约定（写入分块请求的 `chunkInstruction`，见 chunked_coordinator.dart）：
//
// 抽取输出 JSON：
//   {
//     "facts": [
//       {
//         "kind": "task|constraint|date|hours|dependency|negation",
//         "taskHint": "任务线索（task/date/hours/dependency 必填）",
//         "object": "同名不同对象时的区分（可选）",
//         "sourceIds": ["<docHash>:<page>:<index>"],      // 必填，至少一个
//         "quote": "来源原文短句（constraint/negation 必填）",
//         "dueDate": "2026-11-10 或相对日期（按作业固定基准解析）",
//         "hours": 2, "minimum": true,
//         "dependsOn": ["另一个任务线索"],
//         "constraint": "否定/约束原文",
//         "confidence": 0.0-1.0
//       }
//     ],
//     "notes": ["需要用户确认的问题/假设（可选）"],
//     "summary": "摘要（仅上下文辅助，不能替代事实）"
//   }
//
// 归并输出 JSON：
//   {
//     "duplicates": [{"factIds": ["f1","f2"], "reason": "同一任务"}],
//     "contradictions": [{"factIds": ["f3","f4"], "reason": "日期不一致"}],
//     "notes": []
//   }
//
// 结构不符（不是 JSON、缺来源 ID、缺任务线索、否定事实缺原文引文）→ 抛
// [ParseFailure]，由协调器把该块判为失败并保留原因；**不猜、不补 0、不编日期**。

import 'dart:convert';

import 'fact_ledger.dart';

/// 结构解析失败。协调器保存 [code]/[message]，用于恢复与诊断（不含全文）。
class ParseFailure implements Exception {
  const ParseFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ParseFailure($code): $message';
}

/// 解析上下文：固定作业基准（asOf/时区）用于相对日期，所有块共用同一基准。
class ChunkParseContext {
  const ChunkParseContext({
    required this.jobId,
    required this.chunkId,
    required this.asOf,
    required this.timeZoneId,
    this.knownSegmentIds = const <String>{},
  });

  final String jobId;
  final String chunkId;
  final DateTime asOf;
  final String timeZoneId;

  /// 本块材料包含的片段 ID（用于提前提示越界引用；权威校验在 FactLedger）。
  final Set<String> knownSegmentIds;

  AnalysisDateResolver get dateResolver =>
      AnalysisDateResolver(asOf: asOf, timeZoneId: timeZoneId);
}

/// 单个块的抽取输出（只含通过结构校验的内容）。
class ParsedChunkOutput {
  const ParsedChunkOutput({
    required this.facts,
    this.notes = const <String>[],
    this.warnings = const <String>[],
    this.summary,
  });

  final List<FactCandidate> facts;
  final List<String> notes;
  final List<String> warnings;

  /// 仅上下文辅助；正式计划的事实不以它为依据。
  final String? summary;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'facts': facts.map(_candidateToJson).toList(growable: false),
        'notes': notes,
        'warnings': warnings,
        'summary': summary,
      };

  factory ParsedChunkOutput.fromJson(Map<String, dynamic> j) => ParsedChunkOutput(
        facts: ((j['facts'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(_candidateFromJson)
            .toList(growable: false),
        notes: ((j['notes'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        warnings: ((j['warnings'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        summary: j['summary'] as String?,
      );

  static Map<String, dynamic> _candidateToJson(FactCandidate c) =>
      <String, dynamic>{
        'kind': c.kind.name,
        'sourceIds': c.sourceIds,
        'taskHint': c.taskHint,
        'objectKey': c.objectKey,
        'quote': c.quote,
        'dueDate': c.dueDate,
        'dueDateRaw': c.dueDateRaw,
        'hours': c.hours,
        'hoursIsMinimum': c.hoursIsMinimum,
        'dependsOnHints': c.dependsOnHints,
        'confidence': c.confidence,
        'constraintText': c.constraintText,
        if (c.sourceRefBySegment.isNotEmpty)
          'sourceRefBySegment': c.sourceRefBySegment,
      };

  static FactCandidate _candidateFromJson(Map<String, dynamic> j) => FactCandidate(
        kind: FactKind.parse(j['kind']) ?? FactKind.task,
        sourceIds: ((j['sourceIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        taskHint: (j['taskHint'] as String?) ?? '',
        objectKey: j['objectKey'] as String?,
        quote: j['quote'] as String?,
        dueDate: j['dueDate'] as String?,
        dueDateRaw: j['dueDateRaw'] as String?,
        hours: (j['hours'] as num?)?.toDouble(),
        hoursIsMinimum: j['hoursIsMinimum'] == true,
        dependsOnHints: ((j['dependsOnHints'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        confidence: (j['confidence'] as num?)?.toDouble(),
        constraintText: j['constraintText'] as String?,
        sourceRefBySegment: _sourceRefMap(j['sourceRefBySegment']),
      );

}

/// 归并结果中的一个“同事实”组。
class MergeGroup {
  const MergeGroup({required this.factIds, required this.reason});

  final List<String> factIds;
  final String reason;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'factIds': factIds, 'reason': reason};

  factory MergeGroup.fromJson(Map<String, dynamic> j) => MergeGroup(
        factIds: ((j['factIds'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        reason: (j['reason'] as String?) ?? '',
      );
}

/// 归并输出解析结果。
class MergeParseResult {
  const MergeParseResult({
    required this.duplicates,
    required this.contradictions,
    required this.unresolvedFactIds,
    this.notes = const <String>[],
    this.warnings = const <String>[],
  });

  final List<MergeGroup> duplicates;
  final List<MergeGroup> contradictions;

  /// 模型引用了已知事实列表之外的 factId（保留原事实，不合并）。
  final List<String> unresolvedFactIds;

  final List<String> notes;
  final List<String> warnings;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'duplicates': duplicates.map((g) => g.toJson()).toList(growable: false),
        'contradictions':
            contradictions.map((g) => g.toJson()).toList(growable: false),
        'unresolvedFactIds': unresolvedFactIds,
        'notes': notes,
        'warnings': warnings,
      };

  factory MergeParseResult.fromJson(Map<String, dynamic> j) => MergeParseResult(
        duplicates: ((j['duplicates'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MergeGroup.fromJson)
            .toList(growable: false),
        contradictions: ((j['contradictions'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MergeGroup.fromJson)
            .toList(growable: false),
        unresolvedFactIds:
            ((j['unresolvedFactIds'] as List<dynamic>?) ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
        notes: ((j['notes'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        warnings: ((j['warnings'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
      );
}

/// 严格解析器（纯 Dart，无 IO）。
class ModelOutputParser {
  const ModelOutputParser();

  static const String extractionInstruction = '''
你是材料事实抽取器。只依据本次给出的材料片段抽取事实，输出严格 JSON：
{"facts":[{"kind":"task|constraint|date|hours|dependency|negation","taskHint":"任务线索","object":"同名不同对象的区分（可选）","sourceIds":["片段ID"],"quote":"来源原文短句","dueDate":"YYYY-MM-DD","hours":2,"minimum":false,"dependsOn":["任务线索"],"constraint":"否定/约束原文","confidence":0.0}],"notes":[]}
要求：
1) 每条事实必须带 sourceIds（只能引用本次材料给出的片段 ID），不得凭空编造；
2) 否定（如“不能在周二”）、范围（“至少两小时”）、依赖（“必须先完成 A”）必须保留，
   分别用 negation/hours(minimum=true)/dependency 事实表达，并附原文 quote；
3) 相对日期（明天/下周一）按本次请求给出的基准日期解析成 YYYY-MM-DD；
4) 无法确定的日期/工时不要补 0，留空并在 notes 说明；
5) 只输出 JSON，不要解释文字。''';

  static const String mergeInstruction = '''
你是事实归并器。输入是事实索引（含 factId 与来源），只做等价判定，不新增事实。
输出严格 JSON：
{"duplicates":[{"factIds":["f1","f2"],"reason":"同一任务"}],
 "contradictions":[{"factIds":["f3","f4"],"reason":"日期/工时矛盾"}],
 "notes":[]}
要求：factIds 只能引用输入中出现的 factId；不确定就不要合并；只输出 JSON。''';

  /// 解析一个块的抽取输出。结构不符一律抛 [ParseFailure]。
  ParsedChunkOutput parseChunk(
    String raw, {
    required ChunkParseContext context,
  }) {
    final map = _decodeObject(raw);
    final warnings = <String>[];
    final items = <Map<String, dynamic>>[];
    final rawFacts = map['facts'];
    if (rawFacts != null) {
      if (rawFacts is! List) {
        throw const ParseFailure('invalid_facts', 'facts 必须是数组');
      }
      for (final item in rawFacts) {
        if (item is! Map<String, dynamic>) {
          throw const ParseFailure('invalid_fact_item', 'facts 的元素必须是对象');
        }
        items.add(item);
      }
    } else {
      // 兼容“任务/约束”分组输出（两者都没有则视为结构不符）。
      var inferred = false;
      for (final entry in <String, FactKind>{
        'tasks': FactKind.task,
        'constraints': FactKind.constraint,
      }.entries) {
        final rawList = map[entry.key];
        if (rawList == null) continue;
        if (rawList is! List) {
          throw ParseFailure('invalid_facts', '${entry.key} 必须是数组');
        }
        inferred = true;
        for (final item in rawList) {
          if (item is! Map<String, dynamic>) {
            throw ParseFailure(
                'invalid_fact_item', '${entry.key} 的元素必须是对象');
          }
          items.add(<String, dynamic>{
            ...item,
            if (FactKind.parse(item['kind']) == null) 'kind': entry.value.name,
          });
        }
      }
      if (!inferred) {
        throw const ParseFailure('missing_facts', '输出缺少 facts / tasks / constraints');
      }
    }

    final facts = <FactCandidate>[];
    for (var i = 0; i < items.length; i++) {
      facts.add(_parseFact(items[i], context, warnings, index: i));
    }

    final notes = <String>[];
    final rawNotes = map['notes'];
    if (rawNotes is List) {
      for (final note in rawNotes) {
        if (note is String && note.trim().isNotEmpty) {
          notes.add(note.trim());
        } else if (note is Map<String, dynamic>) {
          final text = (note['text'] ?? note['question'] ?? '').toString().trim();
          if (text.isNotEmpty) notes.add(text);
        }
      }
    }
    final summary = (map['summary'] as String?)?.trim();
    return ParsedChunkOutput(
      facts: facts,
      notes: List<String>.unmodifiable(notes),
      warnings: List<String>.unmodifiable(warnings),
      summary: summary == null || summary.isEmpty ? null : summary,
    );
  }

  FactCandidate _parseFact(
    Map<String, dynamic> item,
    ChunkParseContext context,
    List<String> warnings, {
    required int index,
  }) {
    final kindText = item['kind'];
    FactKind? kind;
    if (kindText != null) {
      kind = FactKind.parse(kindText);
      if (kind == null) {
        throw ParseFailure(
            'invalid_kind', '第 ${index + 1} 条事实的 kind 非法：$kindText');
      }
    }
    kind ??= FactKind.task;

    final sourceIds = <String>[
      for (final raw in (item['sourceIds'] as List<dynamic>?) ?? const [])
        if (raw is String && raw.trim().isNotEmpty) raw.trim(),
    ];
    if (sourceIds.isEmpty) {
      throw ParseFailure('missing_source_ids',
          '第 ${index + 1} 条事实缺少来源 ID（sourceIds 必填，不能凭空引用）');
    }
    if (context.knownSegmentIds.isNotEmpty) {
      final unknown =
          sourceIds.where((id) => !context.knownSegmentIds.contains(id)).toList();
      if (unknown.isNotEmpty) {
        warnings.add('第 ${index + 1} 条事实引用本块之外的来源：${unknown.join('、')}');
      }
    }

    final taskHint =
        _firstString(item, const ['taskHint', 'task', 'title', 'name']);
    final constraintText =
        _firstString(item, const ['constraint', 'constraintText', 'text']);
    if ((kind == FactKind.task ||
            kind == FactKind.date ||
            kind == FactKind.hours ||
            kind == FactKind.dependency) &&
        taskHint.isEmpty) {
      throw ParseFailure('missing_task_hint',
          '第 ${index + 1} 条 ${kind.name} 事实缺少任务线索（taskHint 必填）');
    }
    if ((kind == FactKind.constraint || kind == FactKind.negation) &&
        taskHint.isEmpty &&
        constraintText.isEmpty) {
      throw ParseFailure('missing_task_hint',
          '第 ${index + 1} 条 ${kind.name} 事实缺少任务线索或约束原文');
    }

    final quote = _firstString(item, const ['quote', 'evidence', 'sourceQuote']);
    if ((kind == FactKind.constraint || kind == FactKind.negation) &&
        quote.isEmpty) {
      throw ParseFailure('missing_quote',
          '第 ${index + 1} 条 ${kind.name} 事实必须附原文 quote（否定/约束不能无出处）');
    }

    final dueDateRaw = _firstString(item, const ['dueDate', 'deadline', 'date']);
    String? dueDate;
    if (dueDateRaw.isNotEmpty) {
      dueDate = context.dateResolver.resolve(dueDateRaw);
      if (dueDate == null) {
        warnings.add('第 ${index + 1} 条事实的日期「$dueDateRaw」无法本地解析；'
            '保持待确认，不编造日期');
      }
    }

    double? hours;
    final rawHours = item['hours'] ?? item['estimatedHours'];
    if (rawHours is num) {
      final value = rawHours.toDouble();
      if (value <= 0 || value > 24 * 365) {
        warnings.add('第 ${index + 1} 条事实的工时 $value 不合理，已忽略数值（不补 0）');
      } else {
        hours = value;
      }
    } else if (rawHours != null) {
      warnings.add('第 ${index + 1} 条事实的工时不是数字，已忽略（不补 0）');
    }
    final minimum = item['minimum'] == true ||
        item['atLeast'] == true ||
        (quote.isNotEmpty && quote.contains('至少')) ||
        (constraintText.isNotEmpty && constraintText.contains('至少'));

    final dependsOn = <String>[
      for (final raw in (item['dependsOn'] as List<dynamic>?) ?? const [])
        if (raw is String && raw.trim().isNotEmpty) raw.trim(),
    ];

    double? confidence;
    final rawConfidence = item['confidence'];
    if (rawConfidence is num) {
      if (rawConfidence < 0 || rawConfidence > 1) {
        warnings.add('第 ${index + 1} 条事实的 confidence 越界，已忽略');
      } else {
        confidence = rawConfidence.toDouble();
      }
    }

    final objectKey = _firstString(item, const ['object', 'objectKey', 'scope']);

    return FactCandidate(
      kind: kind,
      sourceIds: List<String>.unmodifiable(sourceIds),
      taskHint: taskHint,
      objectKey: objectKey.isEmpty ? null : objectKey,
      quote: quote.isEmpty ? null : quote,
      dueDate: dueDate,
      dueDateRaw: dueDateRaw.isEmpty ? null : dueDateRaw,
      hours: hours,
      hoursIsMinimum: minimum,
      dependsOnHints: List<String>.unmodifiable(dependsOn),
      confidence: confidence,
      constraintText: constraintText.isEmpty ? null : constraintText,
      sourceRefBySegment: _sourceRefMap(item['sourceRefBySegment']),
    );
  }

  /// 解析归并输出。未知 factId 折入 [MergeParseResult.unresolvedFactIds]，
  /// 对应事实保持未合并（不丢、不误合并）。
  MergeParseResult parseMerge(
    String raw, {
    required Set<String> knownFactIds,
  }) {
    final map = _decodeObject(raw);
    final warnings = <String>[];
    final duplicates = <MergeGroup>[];
    final contradictions = <MergeGroup>[];
    final unresolved = <String>[];
    var sawField = false;

    void readGroups(String field, List<MergeGroup> target) {
      final rawList = map[field];
      if (rawList == null) return;
      sawField = true;
      if (rawList is! List) {
        throw ParseFailure('invalid_merge', '$field 必须是数组');
      }
      for (final item in rawList) {
        if (item is! Map<String, dynamic>) {
          throw ParseFailure('invalid_merge_item', '$field 的元素必须是对象');
        }
        final ids = <String>[
          for (final rawId in (item['factIds'] as List<dynamic>?) ?? const [])
            if (rawId is String && rawId.trim().isNotEmpty) rawId.trim(),
        ];
        if (ids.isEmpty) {
          throw ParseFailure('missing_fact_ids', '$field 的条目缺少 factIds');
        }
        final known = <String>[];
        for (final id in ids) {
          if (knownFactIds.contains(id)) {
            known.add(id);
          } else {
            unresolved.add(id);
            warnings.add('模型引用了未知 factId：$id（保留原事实，不合并）');
          }
        }
        final reason = (item['reason'] as String?)?.trim() ?? '';
        if (known.length >= 2) {
          target.add(MergeGroup(
            factIds: List<String>.unmodifiable(known),
            reason: reason.isEmpty ? '模型判定为同一事实' : reason,
          ));
        } else if (known.isNotEmpty) {
          warnings.add('$field 条目无法构成合并组（有效 factId 不足 2 个）');
        }
      }
    }

    readGroups('duplicates', duplicates);
    readGroups('contradictions', contradictions);
    if (!sawField) {
      throw const ParseFailure(
          'missing_merge_fields', '归并输出缺少 duplicates / contradictions');
    }
    final notes = <String>[
      for (final note in (map['notes'] as List<dynamic>?) ?? const [])
        if (note is String && note.trim().isNotEmpty) note.trim(),
    ];
    return MergeParseResult(
      duplicates: duplicates,
      contradictions: contradictions,
      unresolvedFactIds: List<String>.unmodifiable(unresolved),
      notes: List<String>.unmodifiable(notes),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  static Map<String, dynamic> _decodeObject(String raw) {
    final text = _stripCodeFence(raw);
    if (text.isEmpty) {
      throw const ParseFailure('empty_output', '模型输出为空');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw ParseFailure('invalid_json', '模型输出不是合法 JSON：${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ParseFailure('invalid_json_structure', '模型输出 JSON 顶层必须是对象');
    }
    return decoded;
  }

  /// 允许模型包一层 ```json 代码块（常见但非 JSON 本身），其余原样解析。
  static String _stripCodeFence(String raw) {
    var text = raw.trim();
    if (!text.startsWith('```')) return text;
    final firstLineEnd = text.indexOf('\n');
    if (firstLineEnd < 0) return text;
    text = text.substring(firstLineEnd + 1);
    final fenceEnd = text.lastIndexOf('```');
    if (fenceEnd >= 0) text = text.substring(0, fenceEnd);
    return text.trim();
  }

  static String _firstString(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }
}

/// 把 `{segmentId: 原始引用}` 形式的 JSON 读成 Map，忽略空键/空值。
Map<String, String> _sourceRefMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final out = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key.toString().trim();
    final value = entry.value?.toString().trim() ?? '';
    if (key.isNotEmpty && value.isNotEmpty) out[key] = value;
  }
  return out;
}

/// 便于测试/日志的候选事实摘要（不含全文）。
String candidateSummary(FactCandidate fact) =>
    '${fact.kind.name}「${fact.taskHint}」'
    '${fact.dueDate == null ? '' : ' 截止 ${fact.dueDate}'}'
    '${fact.hours == null ? '' : ' 工时 ${fact.hours}'}'
    '${fact.sourceIds.isEmpty ? '' : ' 来源 ${fact.sourceIds.join(',')}'}';
