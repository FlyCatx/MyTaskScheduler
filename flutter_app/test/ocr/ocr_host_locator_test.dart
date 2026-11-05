import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_host.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

void main() {
  group('ocrHostCandidates', () {
    test('env override comes first, then the packaged location', () {
      final candidates = ocrHostCandidates(
        exeDir: r'C:\Apps\TaskScheduler',
        env: <String, String>{'TASKSCHEDULER_OCR_HOST': r'D:\tools\ocr_host.exe'},
        workingDirectory: r'C:\dev\TaskScheduler\flutter_app',
      );
      expect(candidates.first.source, 'env');
      expect(candidates.first.path, r'D:\tools\ocr_host.exe');
      expect(candidates[1].source, 'packaged');
      expect(candidates[1].path, r'C:\Apps\TaskScheduler\data\ocr\ocr_host.exe');
    });

    test('walks up from the working directory to find the dev checkout', () {
      final candidates = ocrHostCandidates(
        exeDir: '',
        env: const <String, String>{},
        workingDirectory: r'C:\dev\TaskScheduler\flutter_app',
      );
      final dev = candidates.where((candidate) => candidate.source == 'dev').toList();
      expect(dev, isNotEmpty);
      expect(dev.first.path, contains(r'flutter_app\tools\ocr_host\bin\ocr_host.exe'));
      expect(
        dev.map((candidate) => candidate.path),
        contains(r'C:\dev\TaskScheduler\tools\ocr_host\bin\ocr_host.exe'),
      );
    });

    test('deduplicates identical paths', () {
      final candidates = ocrHostCandidates(
        exeDir: r'C:\repo',
        env: <String, String>{'TASKSCHEDULER_OCR_HOST': r'C:\repo\data\ocr\ocr_host.exe'},
        workingDirectory: r'C:\repo',
      );
      final packagedPaths = candidates
          .where((candidate) => candidate.path == r'C:\repo\data\ocr\ocr_host.exe')
          .length;
      expect(packagedPaths, 1);
    });
  });

  group('discoverOcrHost', () {
    test('returns the first existing candidate and its source', () async {
      final discovery = await discoverOcrHost(
        exeDirectory: r'C:\Apps\TaskScheduler',
        environment: const <String, String>{},
        workingDirectory: r'C:\dev\TaskScheduler\flutter_app',
        fileExists: (path) => path == r'C:\Apps\TaskScheduler\data\ocr\ocr_host.exe',
      );
      expect(discovery.found, isTrue);
      expect(discovery.location!.source, 'packaged');
      expect(discovery.location!.path, r'C:\Apps\TaskScheduler\data\ocr\ocr_host.exe');
      expect(discovery.diagnostic, contains('已找到'));
    });

    test('missing host reports every attempted path and the env override', () async {
      final discovery = await discoverOcrHost(
        exeDirectory: r'C:\Apps\TaskScheduler',
        environment: const <String, String>{},
        workingDirectory: r'C:\dev\TaskScheduler\flutter_app',
        fileExists: (_) => false,
      );
      expect(discovery.found, isFalse);
      expect(discovery.attempted, isNotEmpty);
      expect(discovery.diagnostic, contains('data\\ocr\\ocr_host.exe'));
      expect(discovery.diagnostic, contains('TASKSCHEDULER_OCR_HOST'));
    });

    test('explicit path discovery only accepts that path', () async {
      final missing = await discoverOcrHostAt(
        r'C:\nowhere\ocr_host.exe',
        fileExists: (_) => false,
      );
      expect(missing.found, isFalse);
      expect(missing.attempted.single.source, 'explicit');

      final found = await discoverOcrHostAt(
        r'C:\tools\ocr_host.exe',
        fileExists: (path) => path == r'C:\tools\ocr_host.exe',
      );
      expect(found.found, isTrue);
      expect(found.location!.source, 'explicit');
    });
  });

  group('build info and engine identity', () {
    test('reads build-info.json next to the executable', () async {
      final dir = await Directory.systemTemp.createTemp('ocr_buildinfo_test_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final host = File('${dir.path}${Platform.pathSeparator}ocr_host.exe');
      await host.writeAsBytes(const <int>[1, 2, 3]);
      final buildInfo = File('${dir.path}${Platform.pathSeparator}build-info.json');
      await buildInfo.writeAsString(jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'hostVersion': '1.0.0',
        'engine': 'Windows.Media.Ocr',
        'engineVersion': 'Windows.Media.Ocr/10.0.19045.0',
        'compiler': <String, Object?>{'kind': 'roslyn'},
        'windowsSdk': <String, Object?>{'unionMetadata': '10.0.26100.0'},
        'output': <String, Object?>{'sha256': 'a' * 64},
      }));
      final info = await readOcrHostBuildInfo(host.path);
      expect(info, isNotNull);
      expect(info!.hostVersion, '1.0.0');
      expect(info.sha256, 'a' * 64);
      expect(info.windowsSdk, '10.0.26100.0');
      expect(info.compilerKind, 'roslyn');
    });

    test('missing build-info returns null instead of throwing', () async {
      final dir = await Directory.systemTemp.createTemp('ocr_no_buildinfo_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final host = File('${dir.path}${Platform.pathSeparator}ocr_host.exe');
      await host.writeAsBytes(const <int>[1]);
      expect(await readOcrHostBuildInfo(host.path), isNull);
      expect(await readOcrHostBuildInfo('${dir.path}\\nope.exe'), isNull);
    });

    test('engine identity is stable and includes the host build', () {
      const availability = OcrAvailability(
        available: true,
        hostVersion: '1.0.0',
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/10.0.19045.0',
        languages: <OcrLanguage>[OcrLanguage(tag: 'en-US', displayName: 'English')],
      );
      final buildInfo = OcrHostBuildInfo(
        hostVersion: '1.0.0',
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/10.0.19045.0',
        sha256: 'b' * 64,
      );
      final identity = ocrEngineIdentity(
        availability: availability,
        buildInfo: buildInfo,
      );
      expect(identity, startsWith('Windows.Media.Ocr/Windows.Media.Ocr/10.0.19045.0'));
      expect(identity, contains('host1.0.0'));
      expect(identity, contains('b' * 64));
      // Same inputs -> same identity (cache keys must be reproducible).
      expect(
        ocrEngineIdentity(availability: availability, buildInfo: buildInfo),
        identity,
      );
    });

    test('engine identity includes the post-processing pipeline version', () {
      const oldPipe = OcrAvailability(
        available: true,
        hostVersion: '1.1.0',
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/10.0.19045.0',
        pipelineVersion: 'heuristic-1',
      );
      const newPipe = OcrAvailability(
        available: true,
        hostVersion: '1.1.0',
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/10.0.19045.0',
        pipelineVersion: 'heuristic-2+rows-1+enhance-1',
      );
      final oldIdentity = ocrEngineIdentity(availability: oldPipe);
      final newIdentity = ocrEngineIdentity(availability: newPipe);
      expect(oldIdentity, contains('pipelineheuristic-1'));
      expect(newIdentity, contains('pipelineheuristic-2+rows-1+enhance-1'));
      // A pipeline change must produce a different cache identity even when the
      // engine version and host version are identical.
      expect(oldIdentity, isNot(newIdentity));
      // A host that predates pipelineVersion stays compatible (shorter identity).
      const legacy = OcrAvailability(
        available: true,
        hostVersion: '1.0.0',
        engine: 'Windows.Media.Ocr',
        engineVersion: 'Windows.Media.Ocr/10.0.19045.0',
      );
      expect(ocrEngineIdentity(availability: legacy), isNot(contains('pipeline')));
    });
  });
}
