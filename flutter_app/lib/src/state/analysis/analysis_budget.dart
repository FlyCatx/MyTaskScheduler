// 分块分析预算 — 把原先“文件字节 / 抽取文本 / 单次请求”共用的
// `maxInputBytes` 拆成互相独立、各自可解释的限额。
//
// 设计约束：
//   * 原文件字节、本地解压/渲染/OCR 资源、提取文本、单请求 UTF-8 字节、
//     模型上下文 token、总作业预算、最大请求数、最大归并层数必须分开；
//   * token 采用*保守估算*（CJK 与拉丁分别计），明确“估算非精确”；
//   * 请求序列化后再次复核字节与 token；超限只能重新拆分，**绝不截去尾部**；
//   * 时间表 busy 区间不得为了塞入材料而被省略或缩短——由
//     [BudgetCheck.checkRequest] 的 timetable 完整性校验强制执行。
//
// 这里只有纯 Dart 计算：不联网、不读文件、不依赖 Flutter。

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// 本地解压 / PDF 渲染 / OCR 的资源上限。与原文件字节、请求字节完全分开。
class LocalProcessingLimits {
  const LocalProcessingLimits({
    this.maxDecompressedBytes = 96 * 1024 * 1024,
    this.maxPdfPages = 400,
    this.maxRenderedPixels = 40 * 1000 * 1000,
    this.maxOcrPages = 120,
    this.maxOcrPagePixels = 4 * 1000 * 1000,
    this.maxConcurrentLocalJobs = 2,
  });

  /// 解压后的容器总字节（DOCX/PPTX/ZIP 炸弹边界）。
  final int maxDecompressedBytes;

  /// 单份 PDF 允许渲染/解析的最大页数。
  final int maxPdfPages;

  /// 单页渲染像素上限（宽×高），防止一次把超大页放进内存。
  final int maxRenderedPixels;

  /// 单个作业允许 OCR 的最大页数。
  final int maxOcrPages;

  /// 单页 OCR 输入像素上限。
  final int maxOcrPagePixels;

  /// 本地解析/OCR 并发进程序列上限。
  final int maxConcurrentLocalJobs;
}

/// 分析作业的全部限额。字段分成“本地资源”“单请求”“整作业”三组。
class AnalysisLimits {
  const AnalysisLimits({
    this.maxSourceFileBytes = 32 * 1024 * 1024,
    this.local = const LocalProcessingLimits(),
    this.maxExtractedTextUtf8Bytes = 8 * 1024 * 1024,
    this.maxRequestUtf8Bytes = 262144,
    this.maxRequestTokens = 48000,
    this.contextTokens = 128000,
    this.reservedOutputTokens = 8192,
    this.maxJobTotalTokens = 1200000,
    this.maxJobTotalRequests = 40,
    this.maxMergeLayers = 3,
    this.mergeInputTokens = 24000,
    this.maxConcurrentRequests = 2,
    this.maxAttemptsPerChunk = 2,
    this.maxFailedChunks = 1,
    this.overlapUtf8Bytes = 640,
    this.retryBackoffBaseMs = 400,
    this.retryBackoffMaxMs = 8000,
    this.retryParseFailures = 1,
  });

  /// 单个原文件允许的字节数（添加材料/送入本地处理之前的硬边界）。
  final int maxSourceFileBytes;

  /// 本地解压/渲染/OCR 资源边界。
  final LocalProcessingLimits local;

  /// 整个作业的“提取文本”UTF-8 字节上限（多份材料合计）。
  /// 它不是单次请求上限：超限意味着材料本身过大，必须显式失败或缩小范围。
  final int maxExtractedTextUtf8Bytes;

  /// 单次模型请求正文（材料片段 + 固定信封）的 UTF-8 字节上限。
  final int maxRequestUtf8Bytes;

  /// 单次模型请求的估算输入 token 上限。
  final int maxRequestTokens;

  /// 模型上下文窗口容量（输入 + 输出）。
  final int contextTokens;

  /// 为模型输出预留的 token 余量，绝不用于塞材料。
  final int reservedOutputTokens;

  /// 整个作业累计估算 token 预算。
  final int maxJobTotalTokens;

  /// 整个作业最多发起的模型请求数（含重试与归并）。
  final int maxJobTotalRequests;

  /// 抽取结果仍需跨块归并时允许的最大归并层数。
  final int maxMergeLayers;

  /// 单次归并请求可装入的“事实索引”估算 token 上限。
  final int mergeInputTokens;

  /// 同时进行中的模型请求上限（默认低并发，尊重连接限流）。
  final int maxConcurrentRequests;

  /// 单个材料块最多尝试次数（含首次）。
  final int maxAttemptsPerChunk;

  /// 允许的失败块数阈值；超过即停止继续请求（保留已有进度）。
  /// 注意：无论阈值多少，只要有块未成功就不可能产出“正式计划”。
  final int maxFailedChunks;

  /// 相邻块之间的上下文重叠字节上限（带稳定片段 ID，便于去重）。
  final int overlapUtf8Bytes;

  final int retryBackoffBaseMs;
  final int retryBackoffMaxMs;

  /// 结构合法但内容解析失败（坏 JSON）时允许的重试次数（0 = 不重试）。
  final int retryParseFailures;

  /// 单请求可用的输入 token：取单请求上限与“上下文 − 输出余量”的较小值。
  int get availableInputTokens =>
      math.min(maxRequestTokens, contextTokens - reservedOutputTokens);

  /// 单次归并请求可用的事实索引 token。
  int get mergeBudgetTokens => math.min(mergeInputTokens, availableInputTokens);

  /// 人类可读的限额摘要（用于“分块分析”确认界面，不虚构费用）。
  Map<String, Object> toDisplayJson() => <String, Object>{
        'maxSourceFileBytes': maxSourceFileBytes,
        'maxExtractedTextUtf8Bytes': maxExtractedTextUtf8Bytes,
        'maxRequestUtf8Bytes': maxRequestUtf8Bytes,
        'maxRequestTokens': maxRequestTokens,
        'contextTokens': contextTokens,
        'reservedOutputTokens': reservedOutputTokens,
        'maxJobTotalTokens': maxJobTotalTokens,
        'maxJobTotalRequests': maxJobTotalRequests,
        'maxMergeLayers': maxMergeLayers,
        'maxConcurrentRequests': maxConcurrentRequests,
        'maxOcrPages': local.maxOcrPages,
      };
}

/// 保守 token 估算器。
///
/// **估算非精确**：没有 tokenizer 时不能把字符数当成所有模型的 token 数。
/// 这里故意*高估*：CJK 字符按 1.5 token / 字，拉丁字符按 2 字符 / token，
/// 其他字符按 1 token / 字符。真实模型可能更省，也可能按不同 tokenizer 划分，
/// 因此该值只用于预算保护，不能作为计费依据或“不会超限”的证明。
class TokenEstimator {
  const TokenEstimator({
    this.cjkTokensPerChar = 1.5,
    this.latinCharsPerToken = 2.0,
    this.otherTokensPerChar = 1.0,
  });

  /// 面向用户的免责声明（UI 可直接展示）。
  static const String disclaimer = 'token 为保守估算值，非精确 tokenizer 计量，不能作为计费依据';

  final double cjkTokensPerChar;
  final double latinCharsPerToken;
  final double otherTokensPerChar;

  /// 估算一段文本的输入 token（向上取整，只用于预算保护）。
  int estimate(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var latin = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else if (_isLatinLike(rune)) {
        latin++;
      } else {
        other++;
      }
    }
    final tokens = cjk * cjkTokensPerChar +
        latin / latinCharsPerToken +
        other * otherTokensPerChar;
    // 结构开销（角色/分隔/换行）按 1 个 token 计，宁多勿少。
    return tokens.ceil() + 1;
  }

  /// 估算一个 JSON 可序列化对象的 token（按序列化文本估算）。
  int estimateJson(Object? value) => estimate(jsonEncode(value));

  static bool _isCjk(int rune) {
    // CJK 统一表意文字（含扩展 A）、CJK 标点、假名、谚文、全角符号。
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x3000 && rune <= 0x303F) ||
        (rune >= 0xFF00 && rune <= 0xFFEF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF);
  }

  static bool _isLatinLike(int rune) {
    // ASCII 可见字符与空白、拉丁扩展：按 2 字符 / token 高估。
    return rune <= 0x7F || (rune >= 0x00A0 && rune <= 0x024F);
  }
}

/// 一次请求预算复核的结论。
class BudgetVerdict {
  const BudgetVerdict({
    required this.ok,
    required this.utf8Bytes,
    required this.estimatedTokens,
    this.reason,
    this.violation,
    this.needsResplit = false,
  });

  const BudgetVerdict.fit({
    required this.utf8Bytes,
    required this.estimatedTokens,
  })  : ok = true,
        reason = null,
        violation = null,
        needsResplit = false;

  factory BudgetVerdict.over({
    required int utf8Bytes,
    required int estimatedTokens,
    required String reason,
    bool needsResplit = true,
  }) =>
      BudgetVerdict(
        ok: false,
        utf8Bytes: utf8Bytes,
        estimatedTokens: estimatedTokens,
        reason: reason,
        needsResplit: needsResplit,
      );

  factory BudgetVerdict.violation(String message) => BudgetVerdict(
        ok: false,
        utf8Bytes: 0,
        estimatedTokens: 0,
        violation: message,
        reason: message,
      );

  final bool ok;
  final int utf8Bytes;
  final int estimatedTokens;
  final String? reason;

  /// 结构性违规（例如缺少时间表）：不是“拆小一点”能解决的。
  final String? violation;

  /// 超限且可通过重新拆分解决；调用方**不得**改用截去尾部来“变绿”。
  final bool needsResplit;

  bool get isViolation => violation != null;
}

/// 单次请求的固定信封（系统提示词、上下文、用户要求、时间表、已知任务），
/// 在装入材料片段之前先扣掉它，得到真正可用于材料的剩余预算。
class RequestBudget {
  RequestBudget({
    required this.limits,
    required this.estimator,
    required this.envelopeUtf8Bytes,
    required this.envelopeTokens,
    this.safetyBytes = 4096,
    this.safetyTokens = 1024,
  });

  final AnalysisLimits limits;
  final TokenEstimator estimator;

  /// 不含材料正文的信封序列化字节数（实测值）。
  final int envelopeUtf8Bytes;

  /// 不含材料正文的信封估算 token。
  final int envelopeTokens;

  final int safetyBytes;
  final int safetyTokens;

  /// 可装入材料的 UTF-8 字节。（>0 才可发起请求；不足时明确失败，不截断材料。）
  int get remainingUtf8Bytes {
    final left = limits.maxRequestUtf8Bytes - envelopeUtf8Bytes - safetyBytes;
    return left < 0 ? 0 : left;
  }

  /// 可装入材料的估算 token。
  int get remainingTokens {
    final left = limits.availableInputTokens - envelopeTokens - safetyTokens;
    return left < 0 ? 0 : left;
  }

  bool get usable => remainingUtf8Bytes > 256 && remainingTokens > 64;

  /// 复核一次完整请求（序列化后）：
  /// * 时间表必须存在且与作业基线**逐字节一致**（禁止省略或缩短 busy 区间）；
  /// * UTF-8 字节、估算 token 均不得超过限额。
  BudgetVerdict checkRequest(
    Map<String, dynamic> request, {
    required bool expectTimetable,
    String? expectedTimetableSignature,
  }) {
    if (expectTimetable) {
      final timetable = request['timetable'];
      final effective = request['effectiveTimetable'];
      if (timetable is! Map || effective is! Map) {
        return BudgetVerdict.violation(
            '时间表 busy 区间必须随每个请求发送；不能为了塞入材料而省略时间表');
      }
      if (expectedTimetableSignature != null) {
        final actual = hashJson(timetable);
        if (actual != expectedTimetableSignature) {
          return BudgetVerdict.violation(
              '请求中的时间表与作业基线不一致（可能被缩短/改写）；已拒绝');
        }
      }
    }
    final bytes = utf8BytesOfJson(request);
    final tokens = estimator.estimateJson(request);
    if (bytes > limits.maxRequestUtf8Bytes) {
      return BudgetVerdict.over(
        utf8Bytes: bytes,
        estimatedTokens: tokens,
        reason: '序列化后 $bytes 字节 > 单请求上限 ${limits.maxRequestUtf8Bytes}；'
            '必须重新拆分，禁止截去尾部',
      );
    }
    if (tokens > limits.availableInputTokens) {
      return BudgetVerdict.over(
        utf8Bytes: bytes,
        estimatedTokens: tokens,
        reason: '估算 $tokens token > 可用输入 ${limits.availableInputTokens} '
            '（上下文 ${limits.contextTokens} − 输出余量 ${limits.reservedOutputTokens}）；'
            '必须重新拆分，禁止截去尾部',
      );
    }
    return BudgetVerdict.fit(utf8Bytes: bytes, estimatedTokens: tokens);
  }
}

/// 整作业预算消耗（可持久化；恢复作业时继续累计，不重置）。
class JobBudget {
  JobBudget({required this.limits});

  final AnalysisLimits limits;
  int requestsUsed = 0;
  int tokensUsed = 0;
  int bytesUsed = 0;

  bool get exhausted =>
      requestsUsed >= limits.maxJobTotalRequests ||
      tokensUsed >= limits.maxJobTotalTokens;

  int get requestsRemaining =>
      limits.maxJobTotalRequests - requestsUsed < 0
          ? 0
          : limits.maxJobTotalRequests - requestsUsed;

  String? get exhaustedReason {
    if (requestsUsed >= limits.maxJobTotalRequests) {
      return '总请求数已达上限（${limits.maxJobTotalRequests}）';
    }
    if (tokensUsed >= limits.maxJobTotalTokens) {
      return '总 token 预算已耗尽（估算 ${limits.maxJobTotalTokens}）';
    }
    return null;
  }

  /// 在发出请求前判断是否还负担得起（保守：按估算输入计）。
  bool canStartRequest({int estimatedTokens = 0}) {
    if (exhausted) return false;
    if (tokensUsed + estimatedTokens > limits.maxJobTotalTokens) return false;
    return requestsUsed + 1 <= limits.maxJobTotalRequests;
  }

  void record({required int tokens, required int bytes}) {
    requestsUsed++;
    tokensUsed += tokens < 0 ? 0 : tokens;
    bytesUsed += bytes < 0 ? 0 : bytes;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'requestsUsed': requestsUsed,
        'tokensUsed': tokensUsed,
        'bytesUsed': bytesUsed,
      };

  static JobBudget fromJson(Map<String, dynamic> json,
      {required AnalysisLimits limits}) {
    return JobBudget(limits: limits)
      ..requestsUsed = (json['requestsUsed'] as num?)?.toInt() ?? 0
      ..tokensUsed = (json['tokensUsed'] as num?)?.toInt() ?? 0
      ..bytesUsed = (json['bytesUsed'] as num?)?.toInt() ?? 0;
  }
}

/// 序列化后的 UTF-8 字节数。
int utf8BytesOfJson(Object? value) => utf8.encode(jsonEncode(value)).length;

/// JSON 的稳定 SHA-256（用于时间表/基线一致性校验，不用于安全用途）。
String hashJson(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// 摘要短 ID（前 16 个十六进制字符），用于稳定作业/块 ID。
String shortHash(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);
