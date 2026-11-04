// Real-machine integration test for the local OCR host.
//
// This test is skipped automatically when the helper executable or the
// synthetic samples are missing (e.g. a clean checkout without build output or
// a non-Windows machine). It exercises the actual Windows.Media.Ocr /
// Windows.Data.Pdf pipeline through OcrService:
//   * availability/language probe,
//   * image OCR,
//   * mixed PDF page detection (text-layer page must not be re-OCR'd),
//   * local page cache reuse,
//   * encrypted-document error mapping.
//
// The synthetic samples live in docs/r3/ocr/samples and their ground truth in
// truth.json; they are evidence artefacts, not part of the release package.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_client.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_material.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_page_detection.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_service.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

String? _findSamplesDir() {
  var dir = Directory.current.path;
  for (var depth = 0; depth < 6; depth++) {
    final candidate = Directory('$dir${Platform.pathSeparator}docs${Platform.pathSeparator}r3${Platform.pathSeparator}ocr${Platform.pathSeparator}samples');
    if (candidate.existsSync()) return candidate.path;
    final parent = Directory(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}

OcrHostDiscovery _discoverHostSync() {
  final candidates = ocrHostCandidates(
    exeDir: '',
    env: Platform.environment,
    workingDirectory: Directory.current.path,
  );
  for (final candidate in candidates) {
    if (File(candidate.path).existsSync()) {
      return OcrHostDiscovery(
        location: OcrHostLocation(path: candidate.path, source: candidate.source),
        attempted: candidates,
      );
    }
  }
  return OcrHostDiscovery(attempted: candidates);
}

void main() {
  final samplesDir = _findSamplesDir();
  final discovery = _discoverHostSync();
  final skipReason = !Platform.isWindows
      ? 'Windows-only OCR engine'
      : discovery.location == null
          ? 'ocr_host.exe 未构建（运行 scripts/build_ocr_host.ps1）'
          : samplesDir == null
              ? '缺少 docs/r3/ocr/samples（运行 scripts/ocr_samples/make_samples.py）'
              : null;

  late Directory dataRoot;
  OcrService? service;

  setUp(() {
    if (skipReason != null) return;
    dataRoot = Directory.systemTemp.createTempSync('ocr_integration_');
    service = OcrService(
      dataRoot: dataRoot,
      discovery: discovery,
      limits: const OcrLimits(
        pageTimeout: Duration(minutes: 2),
        jobTimeout: Duration(minutes: 10),
      ),
    );
  });

  tearDown(() {
    final root = dataRoot;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('availability reports the packaged host and installed OCR languages',
      () async {
    final availability = await service!.availability();
    expect(availability.available, isTrue,
        reason: availability.problem ?? 'OCR host not available');
    expect(availability.languages, isNotEmpty);
    expect(availability.engineVersion, startsWith('Windows.Media.Ocr/'));
    expect(availability.hostVersion, isNotEmpty);
  }, skip: skipReason);

  test('image OCR recognises Chinese text from the synthetic scan', () async {
    final availability = await service!.availability();
    if (availability.languages.any((language) => language.tag.startsWith('zh'))) {
      final job = await service!.recognize(
        filePath: '$samplesDir${Platform.pathSeparator}scan_zh.png',
        pages: const <int>[1],
        dpi: 150,
      );
      expect(job.isComplete, isTrue,
          reason: '${job.coverageLabel} ${job.jobError?.message ?? ''}');
      // The engine inserts spaces between Chinese glyphs; the material layer
      // removes them. Assert on the normalised material, not the raw stream.
      final material = OcrMaterial.fromJob(
        job: job,
        fileLabel: 'scan_zh.png',
        documentSha256: job.sourceSha256,
      );
      final text = material.pages.single.originalText;
      expect(text, contains('项目周会纪要'));
      expect(text, contains('2026年11月4日'));
      expect(text, contains('TS-2026-1104'));
      expect(material.flaggedFields, isNotEmpty);
      expect(job.results.single.width, greaterThan(1000));
      expect(job.results.single.lines, isNotEmpty);
      expect(job.results.single.lines.first.bbox, isNotNull);
    }
  }, skip: skipReason);

  test('mixed PDF detection skips the text page and selects only the scan page',
      () async {
    final detection = await service!.detectPages(
      '$samplesDir${Platform.pathSeparator}mixed_text_scan.pdf',
    );
    expect(detection.detectionFailed, isFalse,
        reason: detection.error?.message ?? '');
    expect(detection.pageCount, 2);
    expect(detection.pagesToOcr, <int>[2]);
    expect(detection.pages.first.reason, OcrPageReason.textLayerSufficient);
  }, skip: skipReason);

  test('local page cache is reused across identical jobs', () async {
    final filePath = '$samplesDir${Platform.pathSeparator}scan_en.jpg';
    final first = await service!.recognize(filePath: filePath, pages: const <int>[1]);
    expect(first.isComplete, isTrue, reason: first.coverageLabel);
    expect(first.cachedPages, isEmpty);
    final second = await service!.recognize(filePath: filePath, pages: const <int>[1]);
    expect(second.isComplete, isTrue);
    expect(second.cachedPages, <int>[1]);
    expect(second.results.single.fromCache, isTrue);
  }, skip: skipReason);

  test('an encrypted PDF maps to the encrypted error, not a fake success',
      () async {
    try {
      await service!.documentInfo(
        '$samplesDir${Platform.pathSeparator}fake_encrypted.pdf',
      );
      fail('encrypted PDF must not be readable');
    } on OcrClientException catch (error) {
      expect(error.error.code, OcrErrorCode.encrypted);
    }
  }, skip: skipReason);
}
