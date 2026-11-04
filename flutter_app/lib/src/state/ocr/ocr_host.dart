// Locates the local OCR helper (`ocr_host.exe`) and reads its build metadata.
//
// The helper is a normal executable inside the app package, not a Dart plugin:
//   * packaged build: <exeDir>\data\ocr\ocr_host.exe
//   * explicit override: TASKSCHEDULER_OCR_HOST environment variable
//   * development checkout: <cwd or ancestor>\tools\ocr_host\bin\ocr_host.exe
//
// Nothing here runs a process (testable on any platform) and nothing downloads
// or extracts anything: if the executable is missing we report exactly which
// paths were tried instead of silently falling back to "no OCR".

import 'dart:convert';
import 'dart:io';

import 'ocr_types.dart';

/// One candidate location and where it came from ("packaged", "env", "dev").
class OcrHostCandidate {
  const OcrHostCandidate({required this.path, required this.source});

  final String path;
  final String source;

  @override
  String toString() => '$source: $path';
}

/// Result of the search: either a location or the full list of failed attempts.
class OcrHostDiscovery {
  const OcrHostDiscovery({this.location, required this.attempted});

  final OcrHostLocation? location;
  final List<OcrHostCandidate> attempted;

  bool get found => location != null;

  /// Detailed diagnostic (Chinese) listing where the executable was expected.
  String get diagnostic {
    if (found) return '已找到本地 OCR 组件：${location!.path}';
    final lines = attempted.map((c) => '  - ${c.source}：${c.path}').join('\n');
    return '找不到本地 OCR 组件 ocr_host.exe。已查找以下位置：\n$lines\n'
        '请确认安装包完整（应包含 data\\ocr\\ocr_host.exe），'
        '或设置环境变量 TASKSCHEDULER_OCR_HOST 指向该文件。';
  }
}

/// A resolved helper executable.
class OcrHostLocation {
  const OcrHostLocation({required this.path, required this.source});

  final String path;

  /// "packaged" | "env" | "dev" | "explicit".
  final String source;

  String get directory {
    final normalized = path.replaceAll('/', Platform.pathSeparator);
    final index = normalized.lastIndexOf(Platform.pathSeparator);
    if (index <= 0) return normalized;
    return normalized.substring(0, index);
  }

  @override
  String toString() => 'OcrHostLocation($source, $path)';
}

/// Candidate list in priority order. Pure function, fully unit-testable.
///
/// [exeDir] is the directory of the running application (empty when unknown,
/// e.g. in tests); [env] is the process environment; [workingDirectory] is used
/// to discover a development checkout.
List<OcrHostCandidate> ocrHostCandidates({
  required String exeDir,
  required Map<String, String> env,
  required String workingDirectory,
  String separator = '\\',
}) {
  final candidates = <OcrHostCandidate>[];
  final seen = <String>{};

  void add(String rawPath, String source) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.replaceAll('/', separator).replaceAll('\\', separator);
    if (!seen.add(normalized.toLowerCase())) return;
    candidates.add(OcrHostCandidate(path: normalized, source: source));
  }

  final override = (env['TASKSCHEDULER_OCR_HOST'] ?? '').trim();
  if (override.isNotEmpty) {
    add(override, 'env');
  }

  if (exeDir.trim().isNotEmpty) {
    add('$exeDir${separator}data${separator}ocr${separator}ocr_host.exe', 'packaged');
  }

  // Development fallback: walk up from the working directory looking for
  // tools/ocr_host/bin/ocr_host.exe (works for `flutter test` and `flutter run`
  // from either flutter_app/ or the repository root).
  var dir = workingDirectory.trim();
  if (dir.isNotEmpty) {
    for (var depth = 0; depth < 6; depth++) {
      add('$dir${separator}tools${separator}ocr_host${separator}bin${separator}ocr_host.exe',
          'dev');
      final parent = _parentOf(dir, separator);
      if (parent == null) break;
      dir = parent;
    }
  }

  return candidates;
}

String? _parentOf(String path, String separator) {
  final normalized = path.replaceAll('/', separator).replaceAll('\\', separator);
  var trimmed = normalized;
  while (trimmed.length > 1 && trimmed.endsWith(separator)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.length <= 1) return null;
  final index = trimmed.lastIndexOf(separator);
  if (index < 0) return null;
  if (index == 0) return trimmed.substring(0, 1);
  if (index == 2 && trimmed.length > 2 && trimmed[1] == ':') {
    return trimmed.substring(0, 3);
  }
  return trimmed.substring(0, index);
}

/// Resolves the helper. [fileExists] is injectable for unit tests.
Future<OcrHostDiscovery> discoverOcrHost({
  String? exeDirectory,
  Map<String, String>? environment,
  String? workingDirectory,
  bool Function(String path)? fileExists,
}) async {
  final env = environment ?? Platform.environment;
  final cwd = workingDirectory ?? Directory.current.path;
  final exeDir = exeDirectory ??
      (Platform.isWindows ? File(Platform.resolvedExecutable).parent.path : '');
  final exists = fileExists ?? (path) => File(path).existsSync();
  final candidates = ocrHostCandidates(
    exeDir: exeDir,
    env: env,
    workingDirectory: cwd,
    separator: Platform.pathSeparator,
  );
  for (final candidate in candidates) {
    if (exists(candidate.path)) {
      return OcrHostDiscovery(
        location: OcrHostLocation(path: candidate.path, source: candidate.source),
        attempted: candidates,
      );
    }
  }
  return OcrHostDiscovery(attempted: candidates);
}

/// Resolves the helper from an explicit path (used by tests and by the
/// TASKSCHEDULER_OCR_HOST override when it is deliberately chosen).
Future<OcrHostDiscovery> discoverOcrHostAt(String path,
    {bool Function(String path)? fileExists}) async {
  final exists = fileExists ?? (candidate) => File(candidate).existsSync();
  final candidates = <OcrHostCandidate>[
    OcrHostCandidate(path: path, source: 'explicit'),
  ];
  if (exists(path)) {
    return OcrHostDiscovery(
      location: OcrHostLocation(path: path, source: 'explicit'),
      attempted: candidates,
    );
  }
  return OcrHostDiscovery(attempted: candidates);
}

/// Reads `<host dir>/build-info.json` written by scripts/build_ocr_host.ps1.
///
/// Returns `null` when the file is absent or unreadable: a helper without build
/// metadata still works, it just cannot contribute a binary hash to the cache
/// key / provenance report.
Future<OcrHostBuildInfo?> readOcrHostBuildInfo(String hostPath) async {
  try {
    final file = File('${File(hostPath).parent.path}${Platform.pathSeparator}build-info.json');
    // Synchronous on purpose: this is a small file next to the host executable,
    // read once per process. It also keeps the availability check free of async
    // file I/O so the startup path and widget tests stay deterministic.
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    return OcrHostBuildInfo.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

/// Stable value used inside OCR cache keys to identify the engine build.
///
/// Prefers the probed engine version, then build-info, then the host file's
/// own size/mtime. Never includes anything secret.
String ocrEngineIdentity({
  OcrAvailability? availability,
  OcrHostBuildInfo? buildInfo,
  OcrHostLocation? location,
  FileStat? hostStat,
}) {
  final engine = (availability?.engine.isNotEmpty ?? false)
      ? availability!.engine
      : (buildInfo?.engine.isNotEmpty ?? false)
          ? buildInfo!.engine
          : 'Windows.Media.Ocr';
  final version = (availability?.engineVersion.isNotEmpty ?? false)
      ? availability!.engineVersion
      : (buildInfo?.engineVersion.isNotEmpty ?? false)
          ? buildInfo!.engineVersion
          : 'unknown';
  final binary = buildInfo?.sha256 ??
      (hostStat != null ? '${hostStat.size}-${hostStat.modified.millisecondsSinceEpoch}' : '');
  final hostVersion = availability?.hostVersion.isNotEmpty == true
      ? availability!.hostVersion
      : (buildInfo?.hostVersion ?? '');
  final parts = <String>[engine, version];
  if (hostVersion.isNotEmpty) parts.add('host$hostVersion');
  if (binary.isNotEmpty) parts.add(binary);
  return parts.join('/');
}
