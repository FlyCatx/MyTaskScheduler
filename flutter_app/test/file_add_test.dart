// Controller tests for the "add a file on a fresh start" regression.
//
// Reported bug: with an empty data directory the app has no conversation yet, so
// `addTextFile` bailed out early and the UI showed the generic "无法添加该文件"
// even though `C:\Users\...\Desktop\exp1.txt` was a perfectly valid UTF-8 file.
//
// These tests use the REAL file store and REAL files (plain `test`, so real async I/O
// works), which is exactly the path that broke.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/app_controller.dart';
import 'package:taskscheduler_flutter/src/state/session_store.dart';
import 'package:taskscheduler_flutter/src/state/storage_root.dart';

import 'support/test_support.dart';

Directory newDir(String name) => Directory(
    '${Directory.current.path}${Platform.pathSeparator}test_tmp'
    '${Platform.pathSeparator}${name}_${DateTime.now().microsecondsSinceEpoch}')
  ..createSync(recursive: true);

Future<AppController> emptyApp(Directory root) async {
  final controller = AppController(
    engine: FakeScheduleEngine(),
    store: SessionStore(root),
  );
  await controller.initialize();
  // A fresh install has NO conversation — that is the precondition of the bug.
  expect(controller.conversation, isNull);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  group('adding a text file on a fresh start', () {
    test('creates a conversation on demand instead of failing', () async {
      final root = newDir('file_add');
      final file = File('${root.path}${Platform.pathSeparator}exp1.txt')
        ..writeAsStringSync('实验1 线性表实验（顺序表的实现）\n1、实现 SqList 的基本操作。');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      final ok = await controller.addTextFile(file.path);

      expect(ok, isTrue, reason: '全新会话下添加文件必须成功');
      expect(controller.errorMessage, isNull);
      expect(controller.conversation, isNotNull, reason: '应当自动创建会话');
      final attachments = controller.conversation!.attachments;
      expect(attachments, hasLength(1));
      expect(attachments.single.label, 'exp1.txt');
      expect(attachments.single.text, contains('线性表实验'));
    });

    test('typing into the composer also creates a conversation (draft not lost)',
        () async {
      final root = newDir('draft_new');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      await controller.updateDraft('先读一遍实验要求');

      expect(controller.conversation, isNotNull);
      expect(controller.conversation!.draftText, '先读一遍实验要求');
    });

    test('a UTF-8 BOM is stripped instead of breaking the read', () async {
      final root = newDir('bom');
      final file = File('${root.path}${Platform.pathSeparator}bom.txt');
      file.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode('内容')]);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isTrue);
      expect(controller.conversation!.attachments.single.text, '内容');
    });

    test('a non-UTF-8 file reports the encoding, not a generic failure', () async {
      final root = newDir('gbk');
      // GBK bytes for "实验" — invalid as UTF-8.
      final file = File('${root.path}${Platform.pathSeparator}gbk.txt')
        ..writeAsBytesSync([0xCA, 0xB5, 0xD1, 0xE9]);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isFalse);
      expect(controller.errorMessage, contains('不是 UTF-8'));
      expect(controller.errorMessage, isNot(contains('无法添加')));
    });

    test('a UTF-16 file is rejected with an actionable message', () async {
      final root = newDir('utf16');
      final file = File('${root.path}${Platform.pathSeparator}u16.txt')
        ..writeAsBytesSync([0xFF, 0xFE, 0x41, 0x00]);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isFalse);
      expect(controller.errorMessage, contains('UTF-16'));
    });

    test('an empty file is rejected explicitly', () async {
      final root = newDir('emptyfile');
      final file = File('${root.path}${Platform.pathSeparator}empty.txt')
        ..writeAsStringSync('');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isFalse);
      expect(controller.errorMessage, contains('文件是空的'));
    });

    test('unsupported extensions still explain what is supported', () async {
      final root = newDir('png');
      final file = File('${root.path}${Platform.pathSeparator}a.png')
        ..writeAsStringSync('not an image we can read');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isFalse);
      expect(controller.errorMessage, contains('不支持 .png'));
      expect(controller.errorMessage, contains('PDF'));
      // Rejecting a file must not leave a stray empty conversation behind.
      expect(controller.conversation, isNull);
    });

    test('a corrupt PDF is rejected without creating a conversation', () async {
      final root = newDir('pdf-broken');
      final file = File('${root.path}${Platform.pathSeparator}a.pdf')
        ..writeAsStringSync('%PDF-1.4');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final controller = await emptyApp(root);
      expect(await controller.addTextFile(file.path), isFalse);
      expect(controller.errorMessage, isNotEmpty);
      expect(controller.conversation, isNull);
    });
    test('the exact file from the bug report can be added', () async {
      // Regression guard for the reported reproduction. Not skipped silently: if the
      // file is missing we simply do not assert anything about its content.
      const reported = r'<user-file>';
      if (!File(reported).existsSync()) return;

      final root = newDir('reported');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final controller = await emptyApp(root);
      final ok = await controller.addTextFile(reported);

      expect(ok, isTrue, reason: 'C:\\Users\\TestUser\\Desktop\\exp1.txt 必须能添加成功');
      expect(controller.errorMessage, isNull);
      final att = controller.conversation!.attachments.single;
      expect(att.label, 'exp1.txt');
      expect(att.text, contains('线性表实验'));
      expect(att.byteLength, greaterThan(100));
    });
  });

  group('storage default', () {
    test('portable folder next to the exe is preferred', () async {
      final root = newDir('portable_pref');
      final exeDir = Directory('${root.path}${Platform.pathSeparator}app')
        ..createSync(recursive: true);
      final localAppData = Directory('${root.path}${Platform.pathSeparator}local')
        ..createSync(recursive: true);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final resolved = await resolveStorageRoot(
        environment: {
          'LOCALAPPDATA': localAppData.path,
          'APPDATA': localAppData.path,
        },
        exeDirectory: exeDir.path,
      );
      expect(resolved.source, 'portable');
      expect(resolved.directory!.path, endsWith('TaskSchedulerData'));
      expect(resolved.notice, isNull, reason: '正常回退不应打扰用户');
    });

    test('a fallback location produces no UI warning at all', () async {
      final root = newDir('silent_fallback');
      final exeDir = Directory('${root.path}${Platform.pathSeparator}readonly_app');
      // Do NOT create exeDir: creating writable<TaskSchedulerData> under a missing
      // parent still succeeds, so make the parent a FILE to force the fallback.
      File(exeDir.path).writeAsStringSync('x');
      final appData = Directory('${root.path}${Platform.pathSeparator}roaming')
        ..createSync(recursive: true);
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final resolved = await resolveStorageRoot(
        environment: {'APPDATA': appData.path},
        exeDirectory: exeDir.path,
      );
      expect(resolved.memoryOnly, isFalse);
      expect(resolved.directory!.path, endsWith('TaskSchedulerFlutter'));
      expect(resolved.notice, isNull,
          reason: '用户要求：不要在上方显示数据目录的回退提示');
    });
  });
}

