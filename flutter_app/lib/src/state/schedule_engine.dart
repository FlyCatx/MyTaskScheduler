// ScheduleEngine — the seam between the UI and the C core.
//
// Why an interface: widget tests must never require the real DLL or a network. The
// native implementation is a thin wrapper around `ts_bridge_edit`; tests use a fake
// that returns canned display snapshots.

import '../ffi/native_gateway.dart';
import '../model/display.dart';
import '../model/plan.dart';

class ScheduleException implements Exception {
  final String message;
  ScheduleException(this.message);
  @override
  String toString() => message;
}

abstract class ScheduleEngine {
  BridgeInfo get info;

  /// Validates + reschedules the plan and returns the display snapshot.
  /// Throws [ScheduleException] when the plan is invalid; callers must keep the
  /// previous snapshot untouched in that case.
  DisplaySnapshot compute(LocalPlan plan);
}

class NativeScheduleEngine implements ScheduleEngine {
  final NativeGateway gateway;
  NativeScheduleEngine(this.gateway);

  @override
  BridgeInfo get info => gateway.cachedInfo;

  @override
  DisplaySnapshot compute(LocalPlan plan) {
    try {
      return DisplaySnapshot.fromJson(gateway.edit(plan.toLocalJson()));
    } on NativeCallException catch (e) {
      throw ScheduleException(e.message);
    }
  }
}

