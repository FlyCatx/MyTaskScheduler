import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/storage_migration.dart';
import 'package:taskscheduler_flutter/src/state/storage_root.dart';

import 'support/test_support.dart';

void main() {
  test('migration copies and verifies without deleting the source', () async {
    final base = createTempDataDir('migration');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    final source = Directory('${base.path}/source')..createSync(recursive: true);
    final target = Directory('${base.path}/target');
    File('${source.path}/index.json').writeAsStringSync('{"a":1}');
    Directory('${source.path}/conversations').createSync();
    File('${source.path}/conversations/c1.json').writeAsStringSync('{"id":"c1"}');
    final env = <String, String>{'LOCALAPPDATA': '${base.path}/local'};

    final result = await StorageMigrationService.migrate(
      sourcePath: source.path,
      targetPath: target.path,
      environment: env,
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.files, 2);
    expect(result.requiresRestart, isTrue);
    expect(File('${target.path}/index.json').readAsStringSync(), '{"a":1}');
    expect(File('${target.path}/conversations/c1.json').existsSync(), isTrue);
    expect(File('${source.path}/index.json').existsSync(), isTrue,
        reason: '迁移不得删除原数据');
    expect(Directory('${target.path}/.ts-migration').existsSync(), isFalse);

    final pointer = jsonDecode(
        File('${base.path}/local/TaskSchedulerFlutter/location.json')
            .readAsStringSync()) as Map<String, dynamic>;
    expect(pointer['dataDir'], target.path);
    expect(await StorageMigrationService.readChosenRoot(env), target.path);

    final root = await resolveStorageRoot(
        environment: env, exeDirectory: '${base.path}/exe');
    expect(root.directory?.path, target.path);
    expect(root.source, 'chosen');
  });

  test('non-empty target is rejected and source stays intact', () async {
    final base = createTempDataDir('migration2');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    final source = Directory('${base.path}/source')..createSync(recursive: true);
    final target = Directory('${base.path}/target')..createSync(recursive: true);
    File('${source.path}/a.json').writeAsStringSync('A');
    File('${target.path}/existing.json').writeAsStringSync('keep');

    final result = await StorageMigrationService.migrate(
      sourcePath: source.path,
      targetPath: target.path,
      environment: <String, String>{'LOCALAPPDATA': '${base.path}/local'},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('空目录'));
    expect(File('${target.path}/existing.json').readAsStringSync(), 'keep');
    expect(File('${source.path}/a.json').readAsStringSync(), 'A');
  });

  test('nested target is rejected', () async {
    final base = createTempDataDir('migration3');
    addTearDown(() {
      if (base.existsSync()) base.deleteSync(recursive: true);
    });
    final source = Directory('${base.path}/source')..createSync(recursive: true);
    final result = await StorageMigrationService.migrate(
      sourcePath: source.path,
      targetPath: '${source.path}/inside',
      environment: <String, String>{'LOCALAPPDATA': '${base.path}/local'},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('内部'));
  });
}

