// FFI bindings for ts_bridge.dll — the only native surface the Flutter UI uses.
//
// Design notes:
//   * Every C function here is a SHORT call. Model calls, file reads, JSON parsing
//     and scheduling all happen on the DLL's own worker thread, so the Flutter UI
//     isolate is never blocked on network I/O.
//   * C never calls back into Dart. Progress is pulled with `ts_bridge_poll`, which
//     removes the whole class of "native worker calls a freed isolate" crashes.
//   * Buffers returned by the DLL are owned by the DLL; they are released only
//     through `ts_bridge_free`.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../model/abi.dart';

export '../model/abi.dart' show kExpectedAbiVersion;


final class TsBridgeBuffer extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int length;
}

typedef _CreateNative = Int32 Function(
    Pointer<Utf8>, Pointer<Pointer<Void>>, Pointer<TsBridgeBuffer>);
typedef _CreateDart = int Function(
    Pointer<Utf8>, Pointer<Pointer<Void>>, Pointer<TsBridgeBuffer>);

/// `ts_bridge_create_ex(config_path, data_dir, out_bridge, out_error)` (ABI 2).
typedef _CreateExNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Pointer<Void>>, Pointer<TsBridgeBuffer>);
typedef _CreateExDart = int Function(Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Pointer<Void>>, Pointer<TsBridgeBuffer>);

/// `ts_bridge_credential_delete(bridge, profile_id, out_error)` (ABI 2).
typedef _ProfileNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<TsBridgeBuffer>);
typedef _ProfileDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<TsBridgeBuffer>);

/// `ts_bridge_credential_set(bridge, profile_id, key, key_len, out_error)` (ABI 2).
typedef _CredentialSetNative = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Size, Pointer<TsBridgeBuffer>);
typedef _CredentialSetDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, int, Pointer<TsBridgeBuffer>);

typedef _InfoNative = Int32 Function(Pointer<Void>, Pointer<TsBridgeBuffer>);
typedef _InfoDart = int Function(Pointer<Void>, Pointer<TsBridgeBuffer>);

typedef _AnalyzeNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Size,
    Pointer<Uint64>, Pointer<TsBridgeBuffer>);
typedef _AnalyzeDart = int Function(Pointer<Void>, Pointer<Utf8>, int,
    Pointer<Uint64>, Pointer<TsBridgeBuffer>);

typedef _PollNative = Int32 Function(
    Pointer<Void>, Uint64, Pointer<TsBridgeBuffer>);
typedef _PollDart = int Function(Pointer<Void>, int, Pointer<TsBridgeBuffer>);

typedef _CancelNative = Int32 Function(Pointer<Void>, Uint64);
typedef _CancelDart = int Function(Pointer<Void>, int);

typedef _ReleaseNative = Int32 Function(Pointer<Void>, Uint64);
typedef _ReleaseDart = int Function(Pointer<Void>, int);

typedef _EditNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Size, Pointer<TsBridgeBuffer>);
typedef _EditDart = int Function(
    Pointer<Void>, Pointer<Utf8>, int, Pointer<TsBridgeBuffer>);

typedef _FreeNative = Void Function(Pointer<TsBridgeBuffer>);
typedef _FreeDart = void Function(Pointer<TsBridgeBuffer>);

typedef _ShutdownBeginNative = Int32 Function(Pointer<Void>);
typedef _ShutdownBeginDart = int Function(Pointer<Void>);

typedef _PickFileNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<TsBridgeBuffer>, Pointer<TsBridgeBuffer>);
typedef _PickFileDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<TsBridgeBuffer>, Pointer<TsBridgeBuffer>);

typedef _ShutdownReadyNative = Int32 Function(Pointer<Void>);
typedef _ShutdownReadyDart = int Function(Pointer<Void>);

typedef _NotifyNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NotifyDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _NotifyClickedNative = Int32 Function(Pointer<Void>);
typedef _NotifyClickedDart = int Function(Pointer<Void>);

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

/// Result of a short native call that may carry a JSON payload or an error.
class RawCallResult {
  final bool ok;
  final String? json;
  final String? error;

  const RawCallResult.success(this.json)
      : ok = true,
        error = null;

  const RawCallResult.failure(this.error)
      : ok = false,
        json = null;
}

/// A UTF-8 encoded copy of [text] plus its **byte** length.
///
/// `String.length` counts UTF-16 code units, so passing it for a UTF-8 buffer would
/// truncate every non-ASCII payload (e.g. any Chinese request) and the native side
/// would fail with "JSON 解析失败". The length must always be the UTF-8 byte count.
class _NativeUtf8 {
  final Pointer<Uint8> pointer;
  final int byteLength;

  _NativeUtf8._(this.pointer, this.byteLength);

  factory _NativeUtf8.of(String text) {
    final bytes = utf8.encode(text);
    final pointer = malloc<Uint8>(bytes.length + 1);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    pointer[bytes.length] = 0;
    return _NativeUtf8._(pointer, bytes.length);
  }

  void free() => malloc.free(pointer);
}

/// Low-level binding object. Prefer [NativeGateway] over using this directly.
class BridgeBindings {
  final DynamicLibrary library;

  late final _CreateDart _create =
      library.lookupFunction<_CreateNative, _CreateDart>('ts_bridge_create');
  late final _InfoDart _info =
      library.lookupFunction<_InfoNative, _InfoDart>('ts_bridge_info');
  late final _AnalyzeDart _analyze = library
      .lookupFunction<_AnalyzeNative, _AnalyzeDart>('ts_bridge_analyze_async');
  late final _PollDart _poll =
      library.lookupFunction<_PollNative, _PollDart>('ts_bridge_poll');
  late final _CancelDart _cancel =
      library.lookupFunction<_CancelNative, _CancelDart>('ts_bridge_cancel');
  late final _PollDart _result =
      library.lookupFunction<_PollNative, _PollDart>('ts_bridge_result');
  late final _ReleaseDart _release =
      library.lookupFunction<_ReleaseNative, _ReleaseDart>(
          'ts_bridge_release_job');
  late final _EditDart _edit =
      library.lookupFunction<_EditNative, _EditDart>('ts_bridge_edit');
  late final _EditDart _export =
      library.lookupFunction<_EditNative, _EditDart>('ts_bridge_export');
  late final _FreeDart _free =
      library.lookupFunction<_FreeNative, _FreeDart>('ts_bridge_free');
  late final _ShutdownBeginDart _shutdownBegin = library
      .lookupFunction<_ShutdownBeginNative, _ShutdownBeginDart>(
          'ts_bridge_shutdown_begin');
  late final _ShutdownReadyDart _shutdownReady = library
      .lookupFunction<_ShutdownReadyNative, _ShutdownReadyDart>(
          'ts_bridge_shutdown_ready');
  late final _DestroyDart _destroy =
      library.lookupFunction<_DestroyNative, _DestroyDart>('ts_bridge_destroy');
  late final _PickFileDart _pickFile = library
      .lookupFunction<_PickFileNative, _PickFileDart>('ts_bridge_pick_file');
  late final _NotifyDart _notify = library
      .lookupFunction<_NotifyNative, _NotifyDart>(
          'ts_bridge_show_notification');
  late final _NotifyClickedDart _notifyClicked = library
      .lookupFunction<_NotifyClickedNative, _NotifyClickedDart>(
          'ts_bridge_notification_clicked');

  // ---- ABI 2 surface. Resolved lazily so an old DLL yields a precise message
  //      ("ts_bridge_settings_get 不存在…") instead of a bare ArgumentError.

  late final _CreateExDart _createEx = _lookupCreateEx();
  late final _InfoDart _settingsGet = _lookupSettingsGet();
  late final _EditDart _settingsSave = _lookupSettingsSave();
  late final _CredentialSetDart _credentialSet = _lookupCredentialSet();
  late final _ProfileDart _credentialDelete = _lookupCredentialDelete();
  late final _AnalyzeDart _probe = _lookupProbe();
  late final _AnalyzeDart _constraints = _lookupConstraints();

  BridgeBindings(this.library);

  /// Converts "symbol not exported" into an actionable message that mentions the
  /// expected ABI. `lookupFunction` needs a concrete native signature, so the ABI 2
  /// lookups are written out instead of going through one generic helper.
  BridgeUnavailableException _missing(String symbol) => BridgeUnavailableException(
      'ts_bridge.dll 不提供 $symbol（界面需要 ABI $kExpectedAbiVersion，'
      '请用 scripts/build_flutter_bridge.ps1 重新构建内核）');

  _CreateExDart _lookupCreateEx() {
    try {
      return library.lookupFunction<_CreateExNative, _CreateExDart>(
          'ts_bridge_create_ex');
    } catch (_) {
      throw _missing('ts_bridge_create_ex');
    }
  }

  _InfoDart _lookupSettingsGet() {
    try {
      return library.lookupFunction<_InfoNative, _InfoDart>(
          'ts_bridge_settings_get');
    } catch (_) {
      throw _missing('ts_bridge_settings_get');
    }
  }

  _EditDart _lookupSettingsSave() {
    try {
      return library.lookupFunction<_EditNative, _EditDart>(
          'ts_bridge_settings_save');
    } catch (_) {
      throw _missing('ts_bridge_settings_save');
    }
  }

  _CredentialSetDart _lookupCredentialSet() {
    try {
      return library.lookupFunction<_CredentialSetNative, _CredentialSetDart>(
          'ts_bridge_credential_set');
    } catch (_) {
      throw _missing('ts_bridge_credential_set');
    }
  }

  _ProfileDart _lookupCredentialDelete() {
    try {
      return library.lookupFunction<_ProfileNative, _ProfileDart>(
          'ts_bridge_credential_delete');
    } catch (_) {
      throw _missing('ts_bridge_credential_delete');
    }
  }

  _AnalyzeDart _lookupProbe() {
    try {
      return library.lookupFunction<_AnalyzeNative, _AnalyzeDart>(
          'ts_bridge_probe_async');
    } catch (_) {
      throw _missing('ts_bridge_probe_async');
    }
  }

  /// 0.07: calendar-constraint extraction. Same native signature as analyze.
  _AnalyzeDart _lookupConstraints() {
    try {
      return library.lookupFunction<_AnalyzeNative, _AnalyzeDart>(
          'ts_bridge_constraints_async');
    } catch (_) {
      throw _missing('ts_bridge_constraints_async');
    }
  }

  /// True when the loaded DLL exports the ABI 2 settings API.
  bool get supportsSettings {
    try {
      // A method call (not a bare field read) keeps this an intentional probe.
      _lookupSettingsGet();
      return true;
    } on BridgeUnavailableException {
      return false;
    }
  }

  static BridgeBindings open({List<String>? extraDirectories}) {
    final candidates = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir${Platform.pathSeparator}ts_bridge.dll');
    if (extraDirectories != null) {
      for (final d in extraDirectories) {
        candidates.add('$d${Platform.pathSeparator}ts_bridge.dll');
      }
    }
    candidates.add('ts_bridge.dll');

    Object? lastError;
    for (final path in candidates) {
      try {
        return BridgeBindings(DynamicLibrary.open(path));
      } catch (e) {
        lastError = e;
      }
    }
    throw BridgeUnavailableException(
        '无法加载 ts_bridge.dll（已尝试：${candidates.join(", ")}）：$lastError');
  }

  /// Reads and clears a DLL-owned buffer. Always frees, even on error paths.
  RawCallResult _consume(int rc, Pointer<TsBridgeBuffer> buf) {
    try {
      if (buf.ref.data == nullptr || buf.ref.length == 0) {
        return rc == 0
            ? const RawCallResult.success('{}')
            : RawCallResult.failure('原生调用失败（rc=$rc，无错误详情）');
      }
      final text = buf.ref.data.cast<Utf8>().toDartString(length: buf.ref.length);
      return rc == 0
          ? RawCallResult.success(text)
          : RawCallResult.failure(text);
    } finally {
      _free(buf);
    }
  }

  Pointer<Void> create(String configPath, {required void Function(String) onError}) {
    final pathPtr = configPath.toNativeUtf8();
    final outBridge = calloc<Pointer<Void>>();
    final errBuf = calloc<TsBridgeBuffer>();
    try {
      final rc = _create(pathPtr, outBridge, errBuf);
      if (rc != 0) {
        onError(_readErrorBuffer(errBuf));
        return nullptr;
      }
      return outBridge.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(outBridge);
      calloc.free(errBuf);
    }
  }

  /// ABI 2 variant of [create]: also tells the DLL where user data lives, so the
  /// native layer can keep `settings.json` next to the sessions.
  Pointer<Void> createEx(
    String configPath,
    String dataDir, {
    required void Function(String) onError,
  }) {
    final pathPtr = configPath.toNativeUtf8();
    final dirPtr = dataDir.toNativeUtf8();
    final outBridge = calloc<Pointer<Void>>();
    final errBuf = calloc<TsBridgeBuffer>();
    try {
      final rc = _createEx(pathPtr, dirPtr, outBridge, errBuf);
      if (rc != 0) {
        onError(_readErrorBuffer(errBuf));
        return nullptr;
      }
      return outBridge.value;
    } finally {
      calloc.free(pathPtr);
      calloc.free(dirPtr);
      calloc.free(outBridge);
      calloc.free(errBuf);
    }
  }

  /// Reads the native settings JSON (profiles + defaults, never a key).
  RawCallResult settingsGet(Pointer<Void> bridge) {
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(_settingsGet(bridge, buf), buf);
    } finally {
      calloc.free(buf);
    }
  }

  /// Writes the whole settings document; the native side applies optimistic revision
  /// checks and returns the stored document (or a `conflict` error).
  RawCallResult settingsSave(Pointer<Void> bridge, String settingsJson) {
    final encoded = _NativeUtf8.of(settingsJson);
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(
          _settingsSave(bridge, encoded.pointer.cast<Utf8>(), encoded.byteLength, buf),
          buf);
    } finally {
      encoded.free();
      calloc.free(buf);
    }
  }

  /// Stores an API key in Windows Credential Manager. The key is only ever handed to
  /// the native layer here; it is never logged, echoed back or written to disk.
  RawCallResult credentialSet(
      Pointer<Void> bridge, String profileId, String key) {
    final idPtr = profileId.toNativeUtf8();
    final keyPtr = _NativeUtf8.of(key);
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(
          _credentialSet(bridge, idPtr, keyPtr.pointer.cast<Utf8>(),
              keyPtr.byteLength, buf),
          buf);
    } finally {
      calloc.free(idPtr);
      keyPtr.free();
      calloc.free(buf);
    }
  }

  RawCallResult credentialDelete(Pointer<Void> bridge, String profileId) {
    final idPtr = profileId.toNativeUtf8();
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(_credentialDelete(bridge, idPtr, buf), buf);
    } finally {
      calloc.free(idPtr);
      calloc.free(buf);
    }
  }

  /// Starts a connectivity probe job and returns its id (as analyze does).
  RawCallResult probe(Pointer<Void> bridge, String requestJson) {
    final encoded = _NativeUtf8.of(requestJson);
    final jobPtr = calloc<Uint64>();
    final buf = calloc<TsBridgeBuffer>();
    try {
      final rc = _probe(bridge, encoded.pointer.cast<Utf8>(), encoded.byteLength,
          jobPtr, buf);
      if (rc != 0) {
        return RawCallResult.failure(_readErrorBuffer(buf));
      }
      return RawCallResult.success(jobPtr.value.toString());
    } finally {
      encoded.free();
      calloc.free(jobPtr);
      calloc.free(buf);
    }
  }

  String _readErrorBuffer(Pointer<TsBridgeBuffer> buf) {
    try {
      if (buf.ref.data == nullptr || buf.ref.length == 0) return '未知错误';
      final text =
          buf.ref.data.cast<Utf8>().toDartString(length: buf.ref.length);
      return text;
    } finally {
      _free(buf);
    }
  }

  RawCallResult info(Pointer<Void> bridge) {
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(_info(bridge, buf), buf);
    } finally {
      // _consume already freed; calloc.free only releases the struct header.
      calloc.free(buf);
    }
  }

  RawCallResult analyze(Pointer<Void> bridge, String requestJson) {
    final encoded = _NativeUtf8.of(requestJson);
    final jobPtr = calloc<Uint64>();
    final buf = calloc<TsBridgeBuffer>();
    try {
      final rc =
          _analyze(bridge, encoded.pointer.cast<Utf8>(), encoded.byteLength, jobPtr, buf);
      if (rc != 0) {
        return RawCallResult.failure(_readErrorBuffer(buf));
      }
      return RawCallResult.success(jobPtr.value.toString());
    } finally {
      encoded.free();
      calloc.free(jobPtr);
      calloc.free(buf);
    }
  }

  /// Starts a calendar-constraint extraction job; returns its id.
  RawCallResult constraints(Pointer<Void> bridge, String requestJson) {
    final encoded = _NativeUtf8.of(requestJson);
    final jobPtr = calloc<Uint64>();
    final buf = calloc<TsBridgeBuffer>();
    try {
      final rc = _constraints(bridge, encoded.pointer.cast<Utf8>(),
          encoded.byteLength, jobPtr, buf);
      if (rc != 0) {
        return RawCallResult.failure(_readErrorBuffer(buf));
      }
      return RawCallResult.success(jobPtr.value.toString());
    } finally {
      encoded.free();
      calloc.free(jobPtr);
      calloc.free(buf);
    }
  }

  RawCallResult poll(Pointer<Void> bridge, int job) {
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(_poll(bridge, job, buf), buf);
    } finally {
      calloc.free(buf);
    }
  }

  bool cancel(Pointer<Void> bridge, int job) => _cancel(bridge, job) == 0;

  RawCallResult result(Pointer<Void> bridge, int job) {
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(_result(bridge, job, buf), buf);
    } finally {
      calloc.free(buf);
    }
  }

  bool release(Pointer<Void> bridge, int job) => _release(bridge, job) == 0;

  RawCallResult edit(Pointer<Void> bridge, String commandJson) {
    final encoded = _NativeUtf8.of(commandJson);
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(
          _edit(bridge, encoded.pointer.cast<Utf8>(), encoded.byteLength, buf), buf);
    } finally {
      encoded.free();
      calloc.free(buf);
    }
  }

  RawCallResult export(Pointer<Void> bridge, String commandJson) {
    final encoded = _NativeUtf8.of(commandJson);
    final buf = calloc<TsBridgeBuffer>();
    try {
      return _consume(
          _export(bridge, encoded.pointer.cast<Utf8>(), encoded.byteLength, buf), buf);
    } finally {
      encoded.free();
      calloc.free(buf);
    }
  }

  void shutdownBegin(Pointer<Void> bridge) => _shutdownBegin(bridge);

  /// Shows the native Windows "open file" dialog (multi-selection allowed).
  ///
  /// Returns `(paths: [...], error: null)` with one entry per selected file,
  /// `(paths: [], error: null)` when the user cancelled, or `(paths: [], error: msg)`
  /// on failure. The DLL returns the selection newline-separated.
  bool showNotification(Pointer<Void> bridge, String title, String body) {
    final t = title.toNativeUtf8();
    final b = body.toNativeUtf8();
    try {
      return _notify(bridge, t, b) == 1;
    } finally {
      calloc.free(t);
      calloc.free(b);
    }
  }

  bool takeNotificationClick(Pointer<Void> bridge) =>
      _notifyClicked(bridge) == 1;

  ({List<String> paths, String? error}) pickFiles(Pointer<Void> bridge,
      {String? title}) {
    final titlePtr = (title ?? '').toNativeUtf8();
    final outPath = calloc<TsBridgeBuffer>();
    final outErr = calloc<TsBridgeBuffer>();
    try {
      final rc = _pickFile(bridge, titlePtr, outPath, outErr);
      if (rc != 0) {
        return (
          paths: const <String>[],
          error: _tryRead(outErr) ?? '无法打开文件对话框',
        );
      }
      final raw = _tryRead(outPath);
      if (raw == null || raw.isEmpty) {
        return (paths: const <String>[], error: null);
      }
      return (
        paths: raw
            .split('\n')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList(growable: false),
        error: null,
      );
    } finally {
      calloc.free(titlePtr);
      calloc.free(outPath);
      calloc.free(outErr);
    }
  }

  /// Reads a buffer without failing when it is empty, then frees it.
  String? _tryRead(Pointer<TsBridgeBuffer> buf) {
    try {
      if (buf.ref.data == nullptr || buf.ref.length == 0) return null;
      return buf.ref.data.cast<Utf8>().toDartString(length: buf.ref.length);
    } finally {
      _free(buf);
    }
  }

  bool shutdownReady(Pointer<Void> bridge) => _shutdownReady(bridge) != 0;

  void destroy(Pointer<Void> bridge) => _destroy(bridge);
}

class BridgeUnavailableException implements Exception {
  final String message;
  BridgeUnavailableException(this.message);
  @override
  String toString() => 'BridgeUnavailableException: $message';
}

