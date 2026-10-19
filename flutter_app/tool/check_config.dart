// Prints the *non-secret* runtime configuration the native bridge resolved.
//
// Why this exists: after packaging it is useful to prove that the shipped
// config.json is parsed and that the API key was found — WITHOUT every printing the
// key itself. Only booleans and the sanitized endpoint are shown.
//
// Usage (run from the package folder so ts_bridge.dll + libcurl-x64.dll are found):
//   dart run tool/check_config.dart "<path to config.json>" "<folder with ts_bridge.dll>"

import 'dart:io';

import 'package:taskscheduler_flutter/src/ffi/native_gateway.dart';

Future<void> main(List<String> args) async {
  final configPath = args.isNotEmpty ? args[0] : 'config.json';
  final dllDir = args.length > 1 ? args[1] : null;

  if (!File(configPath).existsSync()) {
    stderr.writeln('config not found: $configPath');
    exitCode = 2;
    return;
  }

  NativeGateway gateway;
  try {
    gateway = NativeGateway.open(
      configPath: configPath,
      dllDirectories: dllDir == null ? null : [dllDir],
    );
  } catch (e) {
    stderr.writeln('failed to open bridge: $e');
    exitCode = 1;
    return;
  }

  final info = gateway.info();
  stdout.writeln('configPath      = ${info.configPath}');
  stdout.writeln('model           = ${info.model}');
  stdout.writeln('endpoint        = ${info.endpoint}');
  stdout.writeln('mockMode        = ${info.mockMode}');
  stdout.writeln('requiresAuth    = ${info.requiresAuth}');
  stdout.writeln('hasApiKey       = ${info.hasApiKey}');
  stdout.writeln('httpAvailable   = ${info.httpAvailable}');
  stdout.writeln('waitPromptMs    = ${info.waitPromptMs}');
  stdout.writeln('maxInputBytes   = ${info.maxInputBytes}');

  await gateway.close();

  if (!info.mockMode && info.requiresAuth && !info.hasApiKey) {
    stderr.writeln('ERROR: config requires auth but no usable API key was resolved.');
    exitCode = 3;
  }
}

