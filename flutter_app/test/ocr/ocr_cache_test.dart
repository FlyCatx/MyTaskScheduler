import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_cache.dart';
import 'package:taskscheduler_flutter/src/state/ocr/ocr_types.dart';

OcrPageResult pageResult(int page, {String text = '第 1 页文字'}) => OcrPageResult(
      page: page,
      text: text,
      lines: <OcrLine>[
        const OcrLine(text: '第 1 页文字', bbox: OcrRect(1, 2, 30, 10)),
      ],
      width: 1240,
      height: 1754,
      dpi: 150,
      engine: 'Windows.Media.Ocr',
      engineVersion: 'Windows.Media.Ocr/test',
      language: 'zh-Hans-CN',
    );

void main() {
  late Directory root;
  late OcrCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ocr_cache_test_');
    cache = OcrCache(root: root, engineIdentity: 'engine|v1|host1.0.0');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('cache key', () {
    test('canonical string contains every invalidation dimension', () {
      final key = OcrCacheKey(
        documentSha256: 'a' * 64,
        engineIdentity: 'engine|v1',
        languages: <String>['zh-Hans-CN', 'en-US'],
        dpi: 150,
        page: 3,
      );
      expect(key.canonical, contains('a' * 64));
      expect(key.canonical, contains('engine|v1'));
      expect(key.canonical, contains('150'));
      expect(key.canonical, endsWith('|3'));
      expect(key.canonical, isNot(contains(r'C:\')));
    });

    test('language order does not change the key', () {
      final a = OcrCacheKey(
        documentSha256: 'a' * 64,
        engineIdentity: 'e',
        languages: <String>['zh-Hans-CN', 'en-US'],
        dpi: 150,
        page: 1,
      );
      final b = OcrCacheKey(
        documentSha256: 'a' * 64,
        engineIdentity: 'e',
        languages: <String>['EN-US', ' zh-hans-cn '],
        dpi: 150,
        page: 1,
      );
      expect(a.canonical, b.canonical);
      expect(a, b);
    });

    test('changing page, DPI, engine or document changes the key', () {
      final base = OcrCacheKey(
        documentSha256: 'a' * 64,
        engineIdentity: 'engine|v1',
        languages: <String>['en-US'],
        dpi: 150,
        page: 1,
      );
      expect(
        base.canonical,
        isNot(OcrCacheKey(
          documentSha256: 'a' * 64,
          engineIdentity: 'engine|v1',
          languages: <String>['en-US'],
          dpi: 150,
          page: 2,
        ).canonical),
      );
      expect(
        base.canonical,
        isNot(OcrCacheKey(
          documentSha256: 'a' * 64,
          engineIdentity: 'engine|v1',
          languages: <String>['en-US'],
          dpi: 200,
          page: 1,
        ).canonical),
      );
      expect(
        base.canonical,
        isNot(OcrCacheKey(
          documentSha256: 'a' * 64,
          engineIdentity: 'engine|v2',
          languages: <String>['en-US'],
          dpi: 150,
          page: 1,
        ).canonical),
      );
      expect(
        base.canonical,
        isNot(OcrCacheKey(
          documentSha256: 'b' * 64,
          engineIdentity: 'engine|v1',
          languages: <String>['en-US'],
          dpi: 150,
          page: 1,
        ).canonical),
      );
    });

    test('invalid keys are rejected', () {
      const invalid = OcrCacheKey(
        documentSha256: 'short',
        engineIdentity: '',
        languages: <String>[],
        dpi: 0,
        page: 0,
      );
      expect(invalid.isValid, isFalse);
    });
  });

  group('hashing', () {
    test('sha256OfFile matches crypto sha256 of the bytes', () async {
      final file = File('${root.path}${Platform.pathSeparator}doc.bin');
      await file.writeAsBytes(utf8.encode('会议纪要 2026-11-04'));
      final expected = sha256.convert(utf8.encode('会议纪要 2026-11-04')).toString();
      expect(await OcrCache.sha256OfFile(file), expected);
    });
  });

  group('store and load', () {
    test('round-trips a page result and marks it as cached', () async {
      final sha = await sha256OfFileForTest(root);
      final key = cache.keyFor(documentSha: sha, page: 2, dpi: 150, languages: <String>['zh-Hans-CN']);
      expect(await cache.store(key, pageResult(2)), isTrue);
      final loaded = await cache.load(key);
      expect(loaded, isNotNull);
      expect(loaded!.page, 2);
      expect(loaded.text, '第 1 页文字');
      expect(loaded.fromCache, isTrue);
      expect(loaded.lineCount, 1);
    });

    test('a different DPI or language misses', () async {
      final sha = await sha256OfFileForTest(root);
      final key = cache.keyFor(documentSha: sha, page: 1, dpi: 150, languages: <String>['zh-Hans-CN']);
      await cache.store(key, pageResult(1));
      expect(
        await cache.load(cache.keyFor(
            documentSha: sha, page: 1, dpi: 200, languages: <String>['zh-Hans-CN'])),
        isNull,
      );
      expect(
        await cache.load(cache.keyFor(
            documentSha: sha, page: 1, dpi: 150, languages: <String>['en-US'])),
        isNull,
      );
    });

    test('changed document content invalidates via the hash', () async {
      final file = File('${root.path}${Platform.pathSeparator}doc.pdf');
      await file.writeAsString('version 1');
      final sha1 = await OcrCache.sha256OfFile(file);
      final key1 = cache.keyFor(documentSha: sha1, page: 1, dpi: 150);
      await cache.store(key1, pageResult(1, text: '旧内容'));
      expect(await cache.load(key1), isNotNull);

      await file.writeAsString('version 2');
      final sha2 = await OcrCache.sha256OfFile(file);
      expect(sha2, isNot(sha1));
      final key2 = cache.keyFor(documentSha: sha2, page: 1, dpi: 150);
      expect(await cache.load(key2), isNull);
    });

    test('corrupted entries are treated as a miss and removed', () async {
      final sha = await sha256OfFileForTest(root);
      final key = cache.keyFor(documentSha: sha, page: 1, dpi: 150);
      await cache.store(key, pageResult(1));
      final dir = Directory('${cache.directoryPath}${Platform.pathSeparator}$sha');
      final entries = dir.listSync().whereType<File>().toList();
      expect(entries, hasLength(1));
      await entries.first.writeAsString('{not json');
      expect(await cache.load(key), isNull);
      // The corrupt entry is cleaned up.
      expect(await cache.load(key), isNull);
      expect(entries.first.existsSync(), isFalse);
    });

    test('entry file contains no password or source path', () async {
      final sha = await sha256OfFileForTest(root);
      final key = cache.keyFor(documentSha: sha, page: 1, dpi: 150);
      await cache.store(key, pageResult(1));
      final dir = Directory('${cache.directoryPath}${Platform.pathSeparator}$sha');
      final content = await dir.listSync().whereType<File>().first.readAsString();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded.containsKey('password'), isFalse);
      final keys = jsonEncode(decoded);
      expect(keys.contains('password'), isFalse);
      expect(keys.contains('ocr_cache_test_'), isFalse);
    });

    test('store refuses a result for the wrong page', () async {
      final sha = await sha256OfFileForTest(root);
      final key = cache.keyFor(documentSha: sha, page: 2, dpi: 150);
      expect(await cache.store(key, pageResult(1)), isFalse);
    });
  });

  group('maintenance', () {
    test('clearDocument removes only that document', () async {
      final shaA = 'a' * 64;
      final shaB = 'b' * 64;
      await cache.store(cache.keyFor(documentSha: shaA, page: 1, dpi: 150), pageResult(1));
      await cache.store(cache.keyFor(documentSha: shaB, page: 1, dpi: 150), pageResult(1));
      expect(await cache.load(cache.keyFor(documentSha: shaA, page: 1, dpi: 150)), isNotNull);
      expect(await cache.clearDocument(shaA), 1);
      expect(await cache.load(cache.keyFor(documentSha: shaA, page: 1, dpi: 150)), isNull);
      expect(await cache.load(cache.keyFor(documentSha: shaB, page: 1, dpi: 150)), isNotNull);
    });

    test('clearAll empties the cache and sizeBytes reports 0', () async {
      for (var page = 1; page <= 3; page++) {
        await cache.store(
          cache.keyFor(documentSha: 'c' * 64, page: page, dpi: 150),
          pageResult(page),
        );
      }
      expect(await cache.sizeBytes(), greaterThan(0));
      expect(await cache.clearAll(), 3);
      expect(await cache.sizeBytes(), 0);
    });

    test('missing cache directory is not an error', () async {
      final empty = OcrCache(
        root: Directory('${root.path}${Platform.pathSeparator}missing'),
        engineIdentity: 'e',
      );
      expect(await empty.sizeBytes(), 0);
      expect(await empty.clearAll(), 0);
    });
  });
}

Future<String> sha256OfFileForTest(Directory root) async {
  final file = File('${root.path}${Platform.pathSeparator}hash-source.bin');
  await file.writeAsBytes(utf8.encode('content-${DateTime.now().microsecondsSinceEpoch}'));
  return OcrCache.sha256OfFile(file);
}
