// Tests for the data-directory resolver.
//
// Regression context: the first 0.0.2 build hard-coded
// %LOCALAPPDATA%\TaskSchedulerFlutter and refused to start with
// "PathAccessException: Creation failed ... OS Error 5" when that folder was not
// writable. The resolver must therefore *probe* candidates and fall back instead of
// dying.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/storage_root.dart';

Directory newTempDir(String name) => Directory(
        '${Directory.current.path}${Platform.pathSeparator}test_tmp'
        '${Platform.pathSeparator}${name}_${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);

void main() {
  group('candidate ordering', () {
    test('env override comes first, then the portable folder, then appData', () {
      final list = storageCandidates(
        env: {
          'TASKSCHEDULER_DATA_DIR': r'D:\data',
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        exeDir: r'C:\app',
      );
      expect(list.map((e) => e.label).toList(),
          ['env', 'portable', 'localAppData', 'appData']);
      expect(list.first.path, r'D:\data');
    });

    test('the software-folder TaskSchedulerData is the default location', () {
      final list = storageCandidates(
        env: {
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        exeDir: r'C:\app',
      );
      expect(list.first.label, 'portable');
      expect(list.first.path, r'C:\app\TaskSchedulerData');
      // AppData remains as a fallback for read-only installs (e.g. Program Files).
      expect(list.map((e) => e.label).toList(),
          ['portable', 'localAppData', 'appData']);
    });

    test('temp is the last resort before memory-only', () {
      final list = storageCandidates(
        env: {'TEMP': r'C:\Temp'},
        exeDir: '',
      );
      expect(list.map((e) => e.label).toList(), ['temp']);
    });
  });

  group('probing', () {
    test('a writable directory is accepted', () async {
      final dir = newTempDir('probewritable');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final result = await probeWritable(Directory('${dir.path}${Platform.pathSeparator}nested'));
      expect(result.ok, isTrue);
    });

    test('falls back silently when the program folder is read-only', () async {
      final dir = newTempDir('fallback');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // The program "folder" is actually a file, so <exe>\TaskSchedulerData cannot be
      // created -> the portable candidate is rejected.
      final blockingExe = File('${dir.path}${Platform.pathSeparator}app.exe')
        ..writeAsStringSync('x');
      final appDataDir = Directory('${dir.path}${Platform.pathSeparator}roaming')
        ..createSync(recursive: true);

      final root = await resolveStorageRoot(
        environment: {'APPDATA': appDataDir.path},
        exeDirectory: blockingExe.path,
      );

      expect(root.memoryOnly, isFalse);
      expect(root.source, 'appData');
      expect(root.rejected, isNotEmpty);
      expect(root.rejected.first.label, 'portable');
      // Falling back must NOT produce a banner any more (explicit user request).
      expect(root.notice, isNull);
    });

    test('memory-only when nothing is writable, with an actionable notice',
        () async {
      final dir = newTempDir('nowrite');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final blockingFile = File('${dir.path}${Platform.pathSeparator}blocked')
        ..writeAsStringSync('x');

      final root = await resolveStorageRoot(
        environment: {
          'TASKSCHEDULER_DATA_DIR': blockingFile.path,
          'LOCALAPPDATA': blockingFile.path,
          'APPDATA': blockingFile.path,
          'TEMP': blockingFile.path,
        },
        exeDirectory: blockingFile.path,
      );

      expect(root.memoryOnly, isTrue);
      expect(root.directory, isNull);
      expect(root.notice, contains('TASKSCHEDULER_DATA_DIR'));
    });

    test('the environment override is honoured when writable', () async {
      final dir = newTempDir('override');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final custom = Directory('${dir.path}${Platform.pathSeparator}custom')
        ..createSync(recursive: true);

      final root = await resolveStorageRoot(
        environment: {'TASKSCHEDULER_DATA_DIR': custom.path},
        exeDirectory: dir.path,
      );
      expect(root.source, 'env');
      expect(root.directory!.path, custom.path);
      expect(root.notice, isNull, reason: '显式指定且可写时不应该打扰用户');
    });
  });
}

