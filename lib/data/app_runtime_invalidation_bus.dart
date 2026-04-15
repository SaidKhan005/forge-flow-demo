// ─── AppRuntimeInvalidationBus — shared current-state propagation contract ───
// Phase 7.55p.4b + 7.55n.11
//
// Tiny ChangeNotifier singleton that signals "current-state operational data
// changed in persistence." Two explicit producer entrypoints converge on the
// same downstream signal:
//
// 1. notifyRuntimeWriteCompleted()
//    Called after app/runtime writes that change current-state:
//    - ShiftService.closeShift()
//    - ShiftService.reseedDemo()
//    - ShiftService.clearAllData()
//    - ShiftService.advanceMockReplayDay()
//
// 2. notifyImportCompletionPersisted()
//    Called after a connector/import writer finishes persisting fresher
//    current-state operational data. No live connector implementation
//    exists yet — this entrypoint is the explicit contract that future
//    Phase 8 adapters and import writers will call.
//
// Both entrypoints fire the same ChangeNotifier signal. ForgeFlowScope
// wires this bus into the coordinator's ProxyProvider2 so that
// current-state surfaces (week, shift) refresh through the same
// refreshCurrentStateSurfaces() rule used by the active-target cascade,
// app resume (7.55n.9), and boundary invalidation (7.55n.10).
//
// Not a timer. Not a poller. Not a socket. Just a ChangeNotifier that
// fires when operational data has been persisted — regardless of whether
// the producer is an app/runtime write or a connector/import completion.

import 'package:flutter/foundation.dart';

class AppRuntimeInvalidationBus extends ChangeNotifier {
  AppRuntimeInvalidationBus._();
  static final AppRuntimeInvalidationBus instance =
      AppRuntimeInvalidationBus._();

  // ── Producer entrypoints ──────────────────────────────────────────────

  /// Call after any app/runtime write that changes current-state
  /// operational data (e.g., closeShift, reseedDemo, clearAllData,
  /// advanceMockReplayDay).
  ///
  /// Fires listeners synchronously; the Provider framework schedules
  /// downstream rebuilds on the next build frame.
  void notifyRuntimeWriteCompleted() {
    notifyListeners();
  }

  /// Call after a connector or import writer finishes persisting fresher
  /// current-state operational data.
  ///
  /// No live connector implementation exists yet. This entrypoint is the
  /// explicit propagation contract that future Phase 8 adapters and
  /// import writers will call after persisting canonical operational
  /// facts.
  ///
  /// Fires the same downstream signal as [notifyRuntimeWriteCompleted] —
  /// both routes converge on the shared current-state refresh path
  /// through ForgeFlowScope's ProxyProvider2.
  void notifyImportCompletionPersisted() {
    notifyListeners();
  }

  // ── Backward compatibility ────────────────────────────────────────────

  /// Fires the shared current-state invalidation signal.
  ///
  /// Prefer [notifyRuntimeWriteCompleted] or
  /// [notifyImportCompletionPersisted] for new call sites — they make
  /// the producer path explicit. This method is kept for backward
  /// compatibility and for the test wiring in app_boundary_refresh_test
  /// where the producer path is not the thing being tested.
  void notifyCurrentStateChanged() {
    notifyListeners();
  }
}
