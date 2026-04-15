// Phase 7.55n.10 — Foreground-only business-date boundary monitor.
//
// Detects restaurant-local business-date changes while the app remains
// foregrounded. When a boundary is crossed, triggers the shared
// current-state refresh seam (AppRefreshCoordinator).
//
// Design decisions:
// - Foreground-only: Timer runs only while the app is foregrounded.
//   Stopped on paused, restarted (with re-seed) on resumed.
// - Business date is the master boundary signal. Week and 60-day cycle
//   rollovers are handled downstream by the existing refresh path
//   (WeeklyPlanSnapshotService.getCurrentWeekSnapshot() and
//   TargetCycleService.getOrCreateActiveCycle() already resolve
//   rollover on refresh).
// - Initial seed does NOT fire the callback — notifiers already load
//   in their constructors.
// - Injectable clock and resolver for deterministic testing.
// - try/catch around resolver calls so the monitor is resilient to
//   resolver failures (e.g., no timing config, no DB in tests).
//
// Important honesty note:
//   BusinessDateAuthorityService.resolveBusinessDate() expects a
//   restaurant-local timestamp. Full timezone-conversion support is
//   not yet landed in the repo. The production wiring passes
//   DateTime.now() which is correct only when the device timezone
//   matches the restaurant timezone. This limitation is documented
//   in the phase doc and will be resolved when full timezone
//   conversion lands.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

class CurrentStateBoundaryMonitor {
  final Future<String?> Function(DateTime) _resolveBusinessDate;
  final void Function() _onBoundaryChanged;
  final DateTime Function() _clock;
  final Duration _checkInterval;

  Timer? _timer;
  String? _lastKnownBusinessDate;
  bool _seeded = false;

  CurrentStateBoundaryMonitor({
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    DateTime Function()? clock,
    Duration checkInterval = const Duration(minutes: 1),
  })  : _resolveBusinessDate = resolveBusinessDate,
        _onBoundaryChanged = onBoundaryChanged,
        _clock = clock ?? DateTime.now,
        _checkInterval = checkInterval;

  /// Whether the monitor has completed its initial seed.
  @visibleForTesting
  bool get seeded => _seeded;

  /// The last known business date, or null if not yet seeded or resolver
  /// returned null.
  @visibleForTesting
  String? get lastKnownBusinessDate => _lastKnownBusinessDate;

  /// Whether the periodic timer is currently active.
  bool get isRunning => _timer?.isActive ?? false;

  /// Starts the monitor: seeds the current business date and begins
  /// periodic checking. Safe to call multiple times — cancels any
  /// existing timer first.
  ///
  /// The initial seed does NOT fire the boundary-changed callback.
  void start() {
    stop();
    _seed(); // async, fire-and-forget — _check guards on _seeded
    _timer = Timer.periodic(_checkInterval, (_) => _check());
  }

  /// Stops the monitor and cancels the periodic timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Manually trigger a boundary check. Exposed for testing —
  /// production usage relies on the periodic timer.
  @visibleForTesting
  Future<void> check() => _check();

  // ── Internal ────────────────────────────────────────────────────────

  Future<void> _seed() async {
    try {
      final date = await _resolveBusinessDate(_clock());
      _lastKnownBusinessDate = date;
    } catch (_) {
      // Resolver unavailable (e.g., no timing config, no DB).
      // Leave _lastKnownBusinessDate as null — boundary checking
      // will attempt to seed on the next periodic check.
    }
    _seeded = true;
  }

  Future<void> _check() async {
    if (!_seeded) return;
    try {
      final current = await _resolveBusinessDate(_clock());
      if (current == null) return;
      if (_lastKnownBusinessDate == null) {
        // First successful resolve after null seed — treat as initial
        // seed, not a boundary change.
        _lastKnownBusinessDate = current;
        return;
      }
      if (current != _lastKnownBusinessDate) {
        _lastKnownBusinessDate = current;
        _onBoundaryChanged();
      }
    } catch (_) {
      // Resolver unavailable — skip this check cycle.
    }
  }
}
