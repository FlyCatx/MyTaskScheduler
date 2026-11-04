// On-disk cache for per-page OCR results.
//
// Key:  documentSHA256 | engine identity (engine + version + host build) |
//       languages | DPI | page number
// Root: <data root>/ocr_cache/
//
// Consequences (all covered by tests):
//   * editing/replacing the source file changes its SHA-256, so every cached
//     page misses automatically; nothing has to be invalidated by hand,
//   * moving/renaming the file keeps the cache (the path is not part of the key),
//   * changing engine version/languages/DPI creates separate entries,
//   * no password, API key or document text beyond the recognised result is
//     stored, and no other application data is read or written.
//
// The cache is an optimisation only: a corrupt or missing entry is treated as a
// miss and re-recognised, never as a failed page.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'ocr_types.dart';

/// Identity of one cached page. Immutable and comparable by [canonical].
class OcrCacheKey {
  const OcrCacheKey({
    required this.documentSha256,
    required this.engineIdentity,
    required this.languages,
    required this.dpi,
    required this.page,
  });

  /// Lower-case hex SHA-256 of the source file bytes.
  final String documentSha256;

  /// `ocrEngineIdentity()` from ocr_host.dart.
  final String engineIdentity;

  /// Requested language tags. Order is normalised (sorted, lower-case) so the
  /// same request expressed in a different order hits the same entry.
  final List<String> languages;

  final int dpi;
  final int page;

  List<String> get normalisedLanguages {
    final values = <String>{
      for (final tag in languages)
        if (tag.trim().isNotEmpty) tag.trim().toLowerCase(),
    };
    final sorted = values.toList(growable: false)..sort();
    return sorted;
  }

  /// Canonical, human-readable key string. This is what gets hashed into the
  /// file name and stored in the entry for verification.
  String get canonical {
    final tags = normalisedLanguages.isEmpty ? 'default' : normalisedLanguages.join('+');
    return '$documentSha256|$engineIdentity|$tags|$dpi|$page';
  }

  /// Stable file-name component (never contains path separators).
  String get fileStem => sha256.convert(utf8.encode(canonical)).toString().substring(0, 32);

  bool get isValid =>
      documentSha256.length == 64 && engineIdentity.isNotEmpty && dpi > 0 && page > 0;

  @override
  String toString() => 'OcrCacheKey(${documentSha256.substring(0, 12)}…, '
      'engine=$engineIdentity, dpi=$dpi, page=$page)';

  @override
  bool operator ==(Object other) =>
      other is OcrCacheKey && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}

/// JSON schema version of cache entries; bump to invalidate old layouts.
const int ocrCacheSchemaVersion = 1;

/// The page cache.
class OcrCache {
  OcrCache({
    required Directory root,
    required this.engineIdentity,
  }) : _root = root;

  /// Data root (e.g. `<dataRoot>/`); the cache lives in `<root>/ocr_cache/`.
  final Directory _root;
  final String engineIdentity;

  String get directoryPath =>
      '${_root.path}${Platform.pathSeparator}ocr_cache';

  Directory get _cacheDirectory =>
      Directory(directoryPath);

  /// Hashes the file contents with SHA-256 (streamed, no full read into memory).
  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Builds the key for one page of [file] (hashing the file on every call would
  /// be wasteful; callers hash once and reuse [documentSha]).
  OcrCacheKey keyFor({
    required String documentSha,
    required int page,
    required int dpi,
    List<String> languages = const <String>[],
  }) =>
      OcrCacheKey(
        documentSha256: documentSha,
        engineIdentity: engineIdentity,
        languages: languages,
        dpi: dpi,
        page: page,
      );

  File _entryFile(OcrCacheKey key) => File(
      '$directoryPath${Platform.pathSeparator}${key.documentSha256}'
      '${Platform.pathSeparator}${key.fileStem}.json');

  /// Returns the cached page or `null` on miss/corruption/invalid entry.
  ///
  /// A corrupted entry is deleted best-effort and treated as a miss: cache
  /// problems must never fail a job.
  Future<OcrPageResult?> load(OcrCacheKey key) async {
    if (!key.isValid) return null;
    final file = _entryFile(key);
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if ((map['schemaVersion'] as num?)?.toInt() != ocrCacheSchemaVersion) {
        return null;
      }
      final storedKey = map['key'];
      if (storedKey is! Map) return null;
      final storedCanonical = (storedKey['canonical'] as String?) ?? '';
      if (storedCanonical != key.canonical) return null;
      final result = OcrPageResult.fromJson(map['result']);
      if (result == null || result.page != key.page) return null;
      return result.copyWith(fromCache: true);
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Ignore: a cache cleanup failure is not an OCR failure.
      }
      return null;
    }
  }

  /// Writes one page result. Cache write failures are swallowed: the freshly
  /// recognised result is still returned to the caller.
  Future<bool> store(OcrCacheKey key, OcrPageResult result) async {
    if (!key.isValid || result.page != key.page) return false;
    try {
      await _cacheDirectory.create(recursive: true);
      final file = _entryFile(key);
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        'schemaVersion': ocrCacheSchemaVersion,
        'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'key': <String, dynamic>{
          'canonical': key.canonical,
          'documentSha256': key.documentSha256,
          'engineIdentity': key.engineIdentity,
          'languages': key.normalisedLanguages,
          'dpi': key.dpi,
          'page': key.page,
        },
        'result': result.toJson(),
      };
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Removes every cached page of one document (used when the user clears
  /// OCR data; normal invalidation is automatic through the content hash).
  Future<int> clearDocument(String documentSha) async {
    if (documentSha.length != 64) return 0;
    final dir = Directory('$directoryPath${Platform.pathSeparator}$documentSha');
    try {
      if (!await dir.exists()) return 0;
      var removed = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          await entity.delete();
          removed++;
        }
      }
      if (await dir.exists()) await dir.delete();
      return removed;
    } catch (_) {
      return 0;
    }
  }

  /// Removes the whole cache. Returns the number of removed entries (best-effort).
  Future<int> clearAll() async {
    final dir = _cacheDirectory;
    var removed = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(followLinks: false)) {
        try {
          if (entity is File) {
            await entity.delete();
            removed++;
          } else if (entity is Directory) {
            await for (final child in entity.list(followLinks: false)) {
              if (child is File) {
                await child.delete();
                removed++;
              }
            }
            await entity.delete();
          }
        } catch (_) {
          // Keep clearing the rest.
        }
      }
      return removed;
    } catch (_) {
      return removed;
    }
  }

  /// Total size of cached entries in bytes (0 when the cache is empty/missing).
  Future<int> sizeBytes() async {
    final dir = _cacheDirectory;
    var total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // Deleted concurrently.
          }
        }
      }
    } catch (_) {
      return total;
    }
    return total;
  }
}
