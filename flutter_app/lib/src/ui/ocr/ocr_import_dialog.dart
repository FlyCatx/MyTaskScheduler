// R3-O OCR import / review dialog.
//
// The complete user-facing flow:
//   选择文件（PDF / PNG / JPEG）→ 自动检测哪些页需要 OCR（显示原因）→
//   调整页范围 / DPI / 可选密码 → 本地识别（页级进度、可取消）→
//   逐页预览与人工校对（低置信日期/数字标记）→ 确认加入材料。
//
// Boundaries made explicit in the UI:
//   * local OCR is fully offline (no upload, no Python/PATH dependency);
//   * confirming adds *text* material; when the user later asks the configured
//     model to analyse it, that text leaves the machine over the user's own
//     connection — "local OCR" does not mean "the analysis is offline".
//
// A partially failed job is never presented as complete: failed pages are listed
// with their reasons, and confirming a partial material requires an explicit
// second confirmation that names the missing pages.
//
// File selection is an injectable hook (like ExternalCalendarFilePicker), so
// widget tests do not need a native dialog; production wires it in bootstrap:
//   OcrFilePicker.defaultPick = () => gateway.pickTextFiles(
//       title: '选择扫描件或图片（PDF / PNG / JPEG）');

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/ocr/ocr_material.dart';
import '../../state/ocr/ocr_page_detection.dart';
import '../../state/ocr/ocr_service.dart';
import '../../state/ocr/ocr_types.dart';
import '../theme.dart';
import '../widgets/bezier_ui.dart';

/// Opens the system "choose file" dialog and returns absolute paths. An empty
/// list means the user cancelled.
typedef OcrPickFiles = Future<List<String>> Function();

/// Production file-picker hook, registered once during app bootstrap.
class OcrFilePicker {
  OcrFilePicker._();

  /// `null` until the app registers it; the dialog then explains that file
  /// selection is unavailable instead of pretending nothing was chosen.
  static OcrPickFiles? defaultPick;
}

/// Opens the OCR import wizard.
///
/// [onConfirm] is called with the confirmed material; it returns whether the
/// material was actually added (e.g. persistence succeeded). The dialog only
/// closes with `true` after that callback succeeded.
Future<bool> showOcrImportDialog(
  BuildContext context, {
  required OcrService service,
  required Future<bool> Function(OcrMaterial material) onConfirm,
  OcrPickFiles? pickFiles,
  String? initialFilePath,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _OcrImportDialog(
      service: service,
      onConfirm: onConfirm,
      pickFiles: pickFiles,
      initialFilePath: initialFilePath,
    ),
  );
  return result ?? false;
}

enum _Phase { loading, select, detecting, configure, running, review, unavailable }

class _OcrImportDialog extends StatefulWidget {
  const _OcrImportDialog({
    required this.service,
    required this.onConfirm,
    this.pickFiles,
    this.initialFilePath,
  });

  final OcrService service;
  final Future<bool> Function(OcrMaterial material) onConfirm;
  final OcrPickFiles? pickFiles;
  final String? initialFilePath;

  @override
  State<_OcrImportDialog> createState() => _OcrImportDialogState();
}

class _OcrImportDialogState extends State<_OcrImportDialog> {
  _Phase _phase = _Phase.loading;
  OcrAvailability? _availability;
  String? _filePath;
  OcrPageDetection? _detection;
  final TextEditingController _pageSpecController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final Map<int, TextEditingController> _reviewControllers =
      <int, TextEditingController>{};
  int _dpi = OcrLimits.standard.defaultDpi;
  OcrCancellation? _cancellation;
  OcrProgress? _progress;
  OcrJobResult? _job;
  OcrMaterial? _material;
  bool _busy = false;
  String? _error;
  String? _notice;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _pageSpecController.dispose();
    _passwordController.dispose();
    for (final controller in _reviewControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _fileName {
    final path = _filePath;
    if (path == null) return '';
    final index = math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
    return index < 0 ? path : path.substring(index + 1);
  }


  String? get _password {
    final value = _passwordController.text.trim();
    return value.isEmpty ? null : value;
  }

  bool get _running => _phase == _Phase.running;

  // ---------------------------------------------------------------- lifecycle

  Future<void> _bootstrap() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    OcrAvailability availability;
    try {
      availability = await widget.service.availability();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unavailable;
        _availability = null;
        _error = '本地 OCR 组件检查失败：$error';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _availability = availability;
      if (!availability.available) {
        _phase = _Phase.unavailable;
        _error = availability.problem;
      } else if (widget.initialFilePath != null) {
        _phase = _Phase.detecting;
      } else {
        _phase = _Phase.select;
      }
    });
    final initial = widget.initialFilePath;
    if (availability.available && initial != null) {
      await _detect(initial);
    }
  }

  Future<void> _retryAvailability() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final availability = await widget.service.availability(refresh: true);
      if (!mounted) return;
      setState(() {
        _availability = availability;
        _phase = availability.available ? _Phase.select : _Phase.unavailable;
        _error = availability.available ? null : availability.problem;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unavailable;
        _error = '本地 OCR 组件检查失败：$error';
      });
    }
  }

  // ---------------------------------------------------------------- detection

  Future<void> _pickFile() async {
    if (_running) return;
    final pick = widget.pickFiles ?? OcrFilePicker.defaultPick;
    if (pick == null) {
      setState(() {
        _error = '文件选择不可用：应用启动时没有注册文件选择器。'
            '请改用“添加材料”选择文件，或重启应用后重试。';
      });
      return;
    }
    setState(() => _error = null);
    List<String> paths;
    try {
      paths = await pick();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '打开文件对话框失败：$error');
      return;
    }
    if (paths.isEmpty || !mounted) return;
    await _detect(paths.first);
  }

  Future<void> _detect(String path) async {
    final kind = OcrSourceKind.fromPath(path);
    if (kind == OcrSourceKind.unsupported) {
      setState(() {
        _phase = _Phase.select;
        _error = '不支持的文件类型。本地 OCR 支持 PDF、PNG、JPEG 图片。';
      });
      return;
    }
    setState(() {
      _filePath = path;
      _phase = _Phase.detecting;
      _busy = true;
      _error = null;
      _notice = null;
      _detection = null;
      _job = null;
      _material = null;
      _progress = null;
      _clearReviewControllers();
    });
    try {
      final detection = await widget.service.detectPages(
        path,
        password: _password,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _Phase.configure;
        _detection = detection;
        if (detection.detectionFailed) {
          _error = detection.error!.message;
          _pageSpecController.text = '';
        } else {
          _pageSpecController.text = formatOcrPageSpec(detection.pagesToOcr);
          if (detection.pagesToOcr.isEmpty) _pageSpecController.text = '';
        }
        _notice = detection.warning;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _Phase.select;
        _error = '检测需要 OCR 的页失败：$error';
      });
    }
  }

  // -------------------------------------------------------------- recognition

  Future<void> _startRecognition({List<int>? overridePages}) async {
    final path = _filePath;
    if (path == null) return;
    final pages = overridePages ?? _parsePages();
    if (pages == null) return; // parse error already shown
    // Re-recognition of missing pages is a *merge*: the existing material (and
    // the user's reviews) must be kept, only the re-run pages are replaced.
    final previousMaterial = overridePages == null ? null : _material;
    final cancellation = OcrCancellation();
    setState(() {
      _phase = _Phase.running;
      _busy = true;
      _error = null;
      _notice = null;
      _cancellation = cancellation;
      _progress = OcrProgress(
        phase: OcrPhase.preparing,
        totalPages: pages.isEmpty ? 0 : pages.length,
        message: '正在准备本地识别',
      );
      _job = null;
      _material = null;
      _clearReviewControllers();
    });
    OcrJobResult result;
    try {
      result = await widget.service.recognize(
        filePath: path,
        pages: pages,
        password: _password,
        dpi: _dpi,
        cancellation: cancellation,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = previousMaterial == null ? _Phase.configure : _Phase.review;
        _cancellation = null;
        _material = previousMaterial;
        _error = '本地识别失败：$error';
      });
      return;
    }
    if (!mounted) return;
    var material = OcrMaterial.fromJob(
      job: result,
      fileLabel: _fileName,
      documentSha256: result.sourceSha256,
    );
    if (previousMaterial != null && previousMaterial.pages.isNotEmpty) {
      material = previousMaterial.rerun(result);
    }
    setState(() {
      _busy = false;
      _cancellation = null;
      _phase = _Phase.review;
      _job = result;
      _material = material;
      _error = result.jobError?.message;
      _notice = result.warning;
      _syncReviewControllers();
    });
  }

  /// Parses the page range field. Returns `null` (and shows an error) when the
  /// text cannot be used, so the user never starts a job on a guessed range.
  List<int>? _parsePages() {
    final raw = _pageSpecController.text.trim();
    if (raw.isEmpty) return const <int>[];
    try {
      final pages = parseOcrPageSpec(raw);
      if (pages.isEmpty) return const <int>[];
      final detection = _detection;
      if (detection != null && !detection.detectionFailed) {
        final outOfRange = pages.where((page) => page > detection.pageCount);
        if (outOfRange.isNotEmpty) {
          setState(() {
            _error = '页范围超出文档页数：第 ${outOfRange.join('、')} 页'
                '（共 ${detection.pageCount} 页）。';
          });
          return null;
        }
      }
      return pages;
    } on FormatException catch (error) {
      setState(() => _error = '页范围格式不正确：${error.message}。示例：1-3,5');
      return null;
    }
  }

  void _reapplySuggestedRange() {
    final detection = _detection;
    if (detection == null || detection.detectionFailed) return;
    setState(() {
      _pageSpecController.text = formatOcrPageSpec(detection.pagesToOcr);
      _error = null;
    });
  }

  void _cancelRecognition() {
    _cancellation?.cancel();
    setState(() => _notice = '正在取消本地识别…');
  }

  Future<void> _rerunMissingPages() async {
    final material = _material;
    if (material == null) return;
    final missing = <int>{
      ...?_job?.missingPages,
      ...material.rerunFailures,
    }.toList()
      ..sort();
    await _startRecognition(overridePages: missing.isEmpty ? null : missing);
  }

  // ------------------------------------------------------------------ review

  void _clearReviewControllers() {
    for (final controller in _reviewControllers.values) {
      controller.dispose();
    }
    _reviewControllers.clear();
  }

  void _syncReviewControllers() {
    final material = _material;
    if (material == null) return;
    final pages = material.pages.map((page) => page.page).toSet();
    final stale = _reviewControllers.keys.where((page) => !pages.contains(page)).toList();
    for (final page in stale) {
      _reviewControllers.remove(page)?.dispose();
    }
    for (final page in material.pages) {
      final controller = _reviewControllers[page.page];
      if (controller == null) {
        _reviewControllers[page.page] =
            TextEditingController(text: page.effectiveText);
      }
    }
  }

  void _onReviewChanged(int page) {
    final material = _material;
    final controller = _reviewControllers[page];
    if (material == null || controller == null) return;
    setState(() {
      _material = material.applyReview(page, controller.text);
    });
  }

  void _resetPageReview(int page) {
    final material = _material;
    final controller = _reviewControllers[page];
    if (material == null || controller == null) return;
    final pageMaterial = material.pages.firstWhere((entry) => entry.page == page);
    controller.text = pageMaterial.originalText;
    setState(() {
      _material = material.applyReview(page, '');
    });
  }

  // ----------------------------------------------------------------- confirm

  Future<void> _confirm() async {
    final material = _material;
    if (material == null || material.pages.isEmpty) {
      setState(() => _error = '没有可加入材料的识别结果。');
      return;
    }
    final missing = <int>{
      ...?_job?.missingPages,
      ...material.rerunFailures,
    }.toList()
      ..sort();
    final unreviewed = material.unreviewedPageCount;
    if (missing.isNotEmpty || unreviewed > 0) {
      final proceed = await _confirmPartial(material, missing, unreviewed);
      if (proceed != true || !mounted) return;
    }
    setState(() {
      _confirming = true;
      _error = null;
    });
    bool ok = false;
    try {
      ok = await widget.onConfirm(material);
    } catch (error) {
      ok = false;
      if (mounted) setState(() => _error = '加入材料失败：$error');
    }
    if (!mounted) return;
    setState(() => _confirming = false);
    if (ok) {
      Navigator.of(context).pop(true);
    } else if (_error == null) {
      setState(() => _error = '加入材料失败：材料没有被保存。');
    }
  }

  Future<bool?> _confirmPartial(
    OcrMaterial material,
    List<int> missingPages,
    int unreviewed,
  ) {
    final lines = <String>[
      if (missingPages.isNotEmpty)
        '· ${missingPages.length} 页未识别成功：第 ${missingPages.join('、')} 页。'
            '这些页不会加入材料。',
      if (unreviewed > 0) '· $unreviewed 页尚未人工校对（将按原识别文字加入）。',
      '· 已识别 ${material.pages.length} 页将加入材料。',
    ];
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('ocr-partial-confirm-dialog'),
        backgroundColor: TsColors.surface,
        title: const Text('按当前结果加入材料？', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: Text(
            '${lines.join('\n')}\n\n'
            '本次 OCR 结果不完整或未全部校对。确认后只会加入上面列出的已识别页；'
            '后续可以用“重新识别失败页”补齐。',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: TsColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('ocr-partial-confirm-back'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回检查'),
          ),
          TextButton(
            key: const Key('ocr-partial-confirm-accept'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TsButtons.filled(radius: 8),
            child: const Text('确认加入已识别页'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = math.min(860.0, math.max(360.0, media.size.width - 64));
    final height = math.min(760.0, math.max(360.0, media.size.height - 64));
    return Dialog(
      key: const Key('ocr-import-dialog'),
      backgroundColor: TsColors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: const BezierRoundedRectangleBorder(radius: 16),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(),
            Divider(height: 1, color: TsColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _boundaryNotice(),
                    const SizedBox(height: 10),
                    ..._phaseBody(),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: TsColors.border),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _titleRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 8),
      child: Row(
        children: [
          Icon(Icons.document_scanner_outlined, size: 17, color: TsColors.accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '本地 OCR：扫描件 / 图片转文字',
              style: TextStyle(fontSize: 15),
            ),
          ),
          IconButton(
            key: const Key('ocr-dialog-close'),
            tooltip: '关闭',
            onPressed: _running ? null : () => Navigator.of(context).pop(false),
            style: TsButtons.closeIcon(size: 28),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _boundaryNotice() {
    return Container(
      key: const Key('ocr-boundary-notice'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TsColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TsColors.border),
      ),
      child: Text(
        '本地离线：识别在你自己的电脑上完成，不上传扫描页，也不需要安装 Python 或配置 PATH。\n'
        '联网边界：确认加入材料后，这些文字会成为材料；当你让已配置的模型分析材料时，'
        '文字会通过你的模型连接联网发送。本地识别这一步本身不联网。',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.55,
          color: TsColors.textSecondary,
        ),
      ),
    );
  }

  List<Widget> _phaseBody() {
    switch (_phase) {
      case _Phase.loading:
        return <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在检查本地 OCR 组件与识别语言…',
                  key: const Key('ocr-loading-status'),
                  style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
                ),
              ],
            ),
          ),
        ];
      case _Phase.unavailable:
        return <Widget>[
          _errorBox(),
          const SizedBox(height: 8),
          if (_availability != null && _availability!.languages.isNotEmpty)
            Text(
              '已安装的识别语言：'
              '${_availability!.languages.map((language) => language.displayName).join('、')}',
              style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
            ),
          const SizedBox(height: 8),
          Text(
            '本地 OCR 使用 Windows 自带的识别组件，不需要联网；缺少语言包时可在 '
            'Windows 设置 → 时间和语言 → 语言 中安装对应语言的“光学字符识别”组件。',
            style: TextStyle(
                fontSize: 11.5, height: 1.5, color: TsColors.textFaint),
          ),
        ];
      case _Phase.select:
        return <Widget>[
          _fileRow(),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _errorBox(),
          ],
          const SizedBox(height: 10),
          Text(
            '支持扫描型 PDF、混合文字/扫描 PDF，以及 PNG / JPEG 图片。'
            '文本型 PDF 优先使用原有文字层，不会重复识别。',
            style: TextStyle(
                fontSize: 11.5, height: 1.5, color: TsColors.textFaint),
          ),
        ];
      case _Phase.detecting:
        return <Widget>[
          _fileRow(),
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 8),
              Text(
                '正在检查文字层并判断哪些页需要 OCR…',
                key: const Key('ocr-detect-status'),
                style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
              ),
            ],
          ),
        ];
      case _Phase.configure:
        return _configureBody();
      case _Phase.running:
        return _runningBody();
      case _Phase.review:
        return _reviewBody();
    }
  }

  Widget _fileRow() {
    return Row(
      children: [
        OutlinedButton(
          key: const Key('ocr-pick-file'),
          onPressed: _running || _busy ? null : _pickFile,
          style: TsButtons.outline(fontSize: 12),
          child: const Text('选择文件'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _filePath == null ? '尚未选择文件（PDF / PNG / JPEG）' : '已选择：$_fileName',
            key: const Key('ocr-file-name'),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: _filePath == null ? TsColors.textFaint : TsColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _configureBody() {
    final detection = _detection;
    return <Widget>[
      _fileRow(),
      const SizedBox(height: 10),
      if (detection != null) _detectionSummary(detection),
      if (detection != null && detection.pages.isNotEmpty) ...[
        const SizedBox(height: 8),
        _pagePlanList(detection),
      ],
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: const Key('ocr-page-spec'),
              controller: _pageSpecController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '页范围（留空 = 全部页）',
                hintText: '例如 1-3,5',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<int>(
              key: const Key('ocr-dpi'),
              initialValue: _dpi,
              decoration: const InputDecoration(
                labelText: '渲染 DPI',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 100, child: Text('100（更快）')),
                DropdownMenuItem<int>(value: 150, child: Text('150（默认）')),
                DropdownMenuItem<int>(value: 200, child: Text('200（更清晰）')),
                DropdownMenuItem<int>(value: 300, child: Text('300（最慢）')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _dpi = value);
                    },
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('ocr-password'),
              controller: _passwordController,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'PDF 密码（可选，仅加密文档需要）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            key: const Key('ocr-apply-suggested-pages'),
            onPressed: _busy ? null : _reapplySuggestedRange,
            style: TsButtons.inline(fontSize: 11.5),
            child: const Text('使用建议页范围'),
          ),
        ],
      ),
      if (_availability != null) ...[
        const SizedBox(height: 8),
        Text(
          '识别语言：'
          '${_availability!.languages.map((language) => language.displayName).join('、')}'
          '（每页自动选择最合适的一种）',
          key: const Key('ocr-languages'),
          style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
        ),
      ],
      if (_notice != null) ...[
        const SizedBox(height: 8),
        Text(
          _notice!,
          key: const Key('ocr-notice'),
          style: TextStyle(fontSize: 11.5, color: TsColors.waiting),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 8),
        _errorBox(),
      ],
    ];
  }

  Widget _detectionSummary(OcrPageDetection detection) {
    return Text(
      detection.summary,
      key: const Key('ocr-detection-summary'),
      style: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: detection.detectionFailed ? TsColors.blocked : TsColors.textPrimary,
      ),
    );
  }

  Widget _pagePlanList(OcrPageDetection detection) {
    final visible = detection.pages;
    return Container(
      key: const Key('ocr-page-plan'),
      constraints: const BoxConstraints(maxHeight: 168),
      decoration: BoxDecoration(
        border: Border.all(color: TsColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 2),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final plan = visible[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  plan.needsOcr ? Icons.auto_awesome_outlined : Icons.notes_outlined,
                  size: 14,
                  color: plan.needsOcr ? TsColors.accent : TsColors.textFaint,
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 52,
                  child: Text(
                    '第 ${plan.page} 页',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    plan.reason.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: plan.needsOcr ? TsColors.accent : TsColors.textSecondary,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    plan.explanation,
                    style: TextStyle(
                        fontSize: 11, height: 1.35, color: TsColors.textFaint),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _runningBody() {
    final progress = _progress;
    return <Widget>[
      _fileRow(),
      const SizedBox(height: 12),
      if (progress != null) ...[
        LinearProgressIndicator(
          key: const Key('ocr-progress-bar'),
          value: progress.fraction,
          minHeight: 4,
          backgroundColor: TsColors.track,
        ),
        const SizedBox(height: 8),
        Text(
          '当前第 ${progress.currentPage <= 0 ? '—' : progress.currentPage} 页 / 共 '
          '${progress.totalPages} 页；成功 ${progress.completed}，失败 ${progress.failed}',
          key: const Key('ocr-progress'),
          style: TextStyle(fontSize: 12, color: TsColors.textSecondary),
        ),
        if (progress.message != null) ...[
          const SizedBox(height: 4),
          Text(
            progress.message!,
            style: TextStyle(fontSize: 11, color: TsColors.textFaint),
          ),
        ],
      ],
      const SizedBox(height: 10),
      Text(
        '识别完全在本地进行。取消会终止本地 OCR 子进程；已完成的页会保留结果，'
        '但不会自动加入材料。',
        style: TextStyle(fontSize: 11.5, height: 1.5, color: TsColors.textFaint),
      ),
      if (_notice != null) ...[
        const SizedBox(height: 8),
        Text(_notice!,
            style: TextStyle(fontSize: 11.5, color: TsColors.waiting)),
      ],
      if (_error != null) ...[
        const SizedBox(height: 8),
        _errorBox(),
      ],
    ];
  }

  List<Widget> _reviewBody() {
    final material = _material;
    final job = _job;
    return <Widget>[
      _fileRow(),
      const SizedBox(height: 8),
      if (job != null)
        Text(
          '${job.coverageLabel}　${job.engineVersion}　${job.dpi} DPI　'
          '用时 ${(job.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} 秒'
          '${job.cachedPages.isEmpty ? '' : '（缓存 ${job.cachedPages.length} 页）'}',
          key: const Key('ocr-review-summary'),
          style: TextStyle(fontSize: 11.5, color: TsColors.textSecondary),
        ),
      if (job?.jobError != null) ...[
        const SizedBox(height: 8),
        _errorBox(text: job!.jobError!.message),
      ],
      if (job != null && job.failures.isNotEmpty) ...[
        const SizedBox(height: 8),
        _failureList(job),
      ],
      if (_notice != null) ...[
        const SizedBox(height: 8),
        Text(
          _notice!,
          key: const Key('ocr-review-notice'),
          style: TextStyle(fontSize: 11.5, color: TsColors.waiting),
        ),
      ],
      if (material != null) ...[
        const SizedBox(height: 8),
        Text(
          '逐页校对：识别原文与你的修改分开保存，下次重新识别不会覆盖你的校对。',
          style: TextStyle(fontSize: 11.5, color: TsColors.textFaint),
        ),
        if (material.reviewHint != null) ...[
          const SizedBox(height: 4),
          Text(
            material.reviewHint!,
            key: const Key('ocr-review-hint'),
            style: TextStyle(fontSize: 11.5, color: TsColors.waiting),
          ),
        ],
        const SizedBox(height: 8),
        ...material.pages.map(_reviewPageCard),
      ],
      if (_error != null && job?.jobError == null) ...[
        const SizedBox(height: 8),
        _errorBox(),
      ],
    ];
  }

  Widget _failureList(OcrJobResult job) {
    return Container(
      key: const Key('ocr-failure-list'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: TsColors.blockedSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '未识别成功的页（不会加入材料，可重试）：',
            style: TextStyle(fontSize: 11.5, color: TsColors.blocked),
          ),
          const SizedBox(height: 4),
          ...job.failures.map((failure) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '第 ${failure.page} 页：${failure.code.wire} — ${failure.message}',
                  style: TextStyle(
                      fontSize: 11, height: 1.35, color: TsColors.textSecondary),
                ),
              )),
        ],
      ),
    );
  }

  Widget _reviewPageCard(OcrMaterialPage page) {
    final controller = _reviewControllers[page.page];
    final flags = _material?.flaggedFields
            .where((flag) => flag.page == page.page)
            .toList(growable: false) ??
        const <OcrFlaggedField>[];
    return Container(
      key: Key('ocr-review-page-${page.page}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TsColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '第 ${page.page} 页',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(width: 8),
              Text(
                page.result.method == OcrMethod.text ? '文字层' : '本地 OCR',
                style: TextStyle(fontSize: 11, color: TsColors.textFaint),
              ),
              const SizedBox(width: 8),
              Text(
                '${page.result.width}x${page.result.height} @ ${page.result.dpi} DPI',
                style: TextStyle(fontSize: 11, color: TsColors.textFaint),
              ),
              const Spacer(),
              if (page.isReviewed)
                Text(
                  '已校对',
                  style: TextStyle(fontSize: 11, color: TsColors.ready),
                ),
              TextButton(
                key: Key('ocr-reset-review-${page.page}'),
                onPressed: _running ? null : () => _resetPageReview(page.page),
                style: TsButtons.inline(fontSize: 11),
                child: const Text('恢复识别原文'),
              ),
            ],
          ),
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                for (final flag in flags)
                  Tooltip(
                    message: flag.reason,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TsColors.waitingSoft,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '待确认 ${flag.kind.label}：${flag.text}',
                        style: TextStyle(fontSize: 10.5, color: TsColors.waiting),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          TextField(
            key: Key('ocr-review-text-${page.page}'),
            controller: controller,
            enabled: !_running && !_confirming,
            minLines: 3,
            maxLines: 8,
            onChanged: (_) => _onReviewChanged(page.page),
            style: const TextStyle(fontSize: 12.5, height: 1.5),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (page.reviewDiff() != null) ...[
            const SizedBox(height: 4),
            Text(
              page.reviewDiff()!,
              style: TextStyle(fontSize: 10.5, color: TsColors.textFaint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorBox({String? text}) {
    return Container(
      key: const Key('ocr-error'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: TsColors.blockedSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text ?? _error ?? '未知错误',
        style: TextStyle(fontSize: 11.5, height: 1.45, color: TsColors.blocked),
      ),
    );
  }

  Widget _footer() {
    final buttons = <Widget>[];
    switch (_phase) {
      case _Phase.loading:
      case _Phase.detecting:
        buttons.add(TextButton(
          key: const Key('ocr-footer-close'),
          onPressed: () => Navigator.of(context).pop(false),
          style: TsButtons.outline(),
          child: const Text('关闭'),
        ));
        break;
      case _Phase.unavailable:
        buttons.add(TextButton(
          key: const Key('ocr-retry-availability'),
          onPressed: _retryAvailability,
          style: TsButtons.outline(),
          child: const Text('重新检查'),
        ));
        buttons.add(const SizedBox(width: 8));
        buttons.add(TextButton(
          key: const Key('ocr-footer-close'),
          onPressed: () => Navigator.of(context).pop(false),
          style: TsButtons.outline(),
          child: const Text('关闭'),
        ));
        break;
      case _Phase.select:
        buttons.add(TextButton(
          key: const Key('ocr-footer-close'),
          onPressed: () => Navigator.of(context).pop(false),
          style: TsButtons.outline(),
          child: const Text('取消'),
        ));
        break;
      case _Phase.configure:
        buttons.add(TextButton(
          key: const Key('ocr-footer-close'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          style: TsButtons.outline(),
          child: const Text('取消'),
        ));
        buttons.add(const SizedBox(width: 8));
        buttons.add(TextButton(
          key: const Key('ocr-start'),
          onPressed: _busy ? null : () => _startRecognition(),
          style: TsButtons.filled(radius: 8),
          child: const Text('开始本地识别'),
        ));
        break;
      case _Phase.running:
        buttons.add(TextButton(
          key: const Key('ocr-cancel'),
          onPressed: _cancellation == null ? null : _cancelRecognition,
          style: TsButtons.outline(),
          child: const Text('取消识别'),
        ));
        break;
      case _Phase.review:
        final hasMissing = (_job?.missingPages.isNotEmpty ?? false) ||
            (_material?.rerunFailures.isNotEmpty ?? false);
        buttons.add(TextButton(
          key: const Key('ocr-footer-close'),
          onPressed: () => Navigator.of(context).pop(false),
          style: TsButtons.outline(),
          child: const Text('关闭'),
        ));
        if (hasMissing) {
          buttons.add(const SizedBox(width: 8));
          buttons.add(TextButton(
            key: const Key('ocr-rerun-missing'),
            onPressed: _confirming ? null : _rerunMissingPages,
            style: TsButtons.outline(),
            child: const Text('重新识别失败页'),
          ));
        }
        buttons.add(const SizedBox(width: 8));
        buttons.add(TextButton(
          key: const Key('ocr-confirm'),
          onPressed: _confirming || (_material?.pages.isEmpty ?? true)
              ? null
              : _confirm,
          style: TsButtons.filled(radius: 8),
          child: Text(_confirming ? '正在加入…' : '确认加入材料'),
        ));
        break;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: buttons,
      ),
    );
  }
}
