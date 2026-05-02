// Foreground-only business-date boundary monitor (per-location).
//
// Detects restaurant-local business-date changes while the app remains
// foregrounded. When a boundary is crossed, triggers the shared
// current-state refresh seam (AppRefreshCoordinator).
//
// Time authority:
//   The monitor reads "now" through `tz.TZDateTime.now(location.timezone)`
//   so the boundary clock matches the restaurant wall clock regardless of
//   device timezone. This satisfies Time Boundary Contract Rule 1
//   (`docs/contracts/phase_7_55_time_boundary_contract.md`): the device
//   timezone must not be the truth source for business boundaries.
//
//   Each instance is bound to one `RestaurantLocation`. Multi-location
//   operators run one instance per accessible location via
//   `BoundaryMonitorSupervisor`.
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

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models/restaurant_location.dart';

/// Thrown when a [RestaurantLocation] passed to
/// [CurrentStateBoundaryMonitor] has no usable IANA timezone. The monitor
/// refuses to fall back to the device clock, so callers must repair the
/// location's `businessTimezone` before retrying.
class MissingTimezoneError extends StateError {
  MissingTimezoneError({required this.restaurantId, required this.timezoneName})
      : super(
          'RestaurantLocation "$restaurantId" has no usable IANA timezone '
          '(got "$timezoneName"). The boundary monitor refuses to fall back '
          'to the device clock — repair location.businessTimezone first.',
        );

  final String restaurantId;
  final String timezoneName;
}

bool _tzInitialized = false;

tz.Location _resolveTzLocation({
  required String restaurantId,
  required String timezoneName,
}) {
  final trimmed = timezoneName.trim();
  if (trimmed.isEmpty) {
    throw MissingTimezoneError(
      restaurantId: restaurantId,
      timezoneName: timezoneName,
    );
  }
  if (!_tzInitialized) {
    tzdata.initializeTimeZones();
    _tzInitialized = true;
  }
  try {
    return tz.getLocation(trimmed);
  } on tz.LocationNotFoundException {
    throw MissingTimezoneError(
      restaurantId: restaurantId,
      timezoneName: timezoneName,
    );
  }
}

/// Pre-fire hook called BEFORE the synchronous `onBoundaryChanged`
/// callback. The hook persists a row to a durable backlog (e.g.
/// `event_outbox`) so that a callback that crashes before recording
/// the boundary can be replayed on the next supervisor restart. The
/// hook returns the persisted event id (rendered as a string to match
/// the `event_outbox` `bigserial` projection); a null return signals
/// "persistence failed but proceed anyway" — the supervisor should
/// log the error and skip the post-fire mark-delivered call.
typedef BoundaryWillFireHook = Future<String?> Function(String businessDate);

/// Post-fire hook called AFTER the synchronous `onBoundaryChanged`
/// callback returns successfully. The hook stamps the persisted row
/// (identified by [eventId] from [BoundaryWillFireHook]) as delivered
/// so a subsequent backlog drain does not re-fire it.
typedef BoundaryFiredHook = Future<void> Function(String eventId);

class CurrentStateBoundaryMonitor {
  final RestaurantLocation _location;
  final tz.Location _tzLocation;
  final Future<String?> Function(DateTime) _resolveBusinessDate;
  final void Function() _onBoundaryChanged;
  final BoundaryWillFireHook? _onBoundaryWillFire;
  final BoundaryFiredHook? _onBoundaryFired;
  final DateTime Function() _clock;
  final Duration _checkInterval;

  Timer? _timer;
  String? _lastKnownBusinessDate;
  bool _seeded = false;

  factory CurrentStateBoundaryMonitor({
    required RestaurantLocation location,
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    BoundaryWillFireHook? onBoundaryWillFire,
    BoundaryFiredHook? onBoundaryFired,
    DateTime Function()? clock,
    Duration checkInterval = const Duration(minutes: 1),
  }) {
    final tzLocation = _resolveTzLocation(
      restaurantId: location.restaurantId,
      timezoneName: location.businessTimezone,
    );
    return CurrentStateBoundaryMonitor._(
      location: location,
      tzLocation: tzLocation,
      resolveBusinessDate: resolveBusinessDate,
      onBoundaryChanged: onBoundaryChanged,
      onBoundaryWillFire: onBoundaryWillFire,
      onBoundaryFired: onBoundaryFired,
      clock: clock ?? (() => tz.TZDateTime.now(tzLocation)),
      checkInterval: checkInterval,
    );
  }

  CurrentStateBoundaryMonitor._({
    required RestaurantLocation location,
    required tz.Location tzLocation,
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    required DateTime Function() clock,
    required Duration checkInterval,
    BoundaryWillFireHook? onBoundaryWillFire,
    BoundaryFiredHook? onBoundaryFired,
  })  : _location = location,
        _tzLocation = tzLocation,
        _resolveBusinessDate = resolveBusinessDate,
        _onBoundaryChanged = onBoundaryChanged,
        _onBoundaryWillFire = onBoundaryWillFire,
        _onBoundaryFired = onBoundaryFired,
        _clock = clock,
        _checkInterval = checkInterval;

  /// The location this monitor is bound to. Used by the supervisor for
  /// keying and reconciliation; tests use it to assert wiring.
  RestaurantLocation get location => _location;

  /// Convenience for callers that only need the id.
  String get locationId => _location.restaurantId;

  /// The IANA timezone the boundary clock reads through.
  String get timezoneName => _tzLocation.name;

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
    String current;
    try {
      final resolved = await _resolveBusinessDate(_clock());
      if (resolved == null) return;
      current = resolved;
    } catch (_) {
      // Resolver unavailable — skip this check cycle.
      return;
    }
    if (_lastKnownBusinessDate == null) {
      // First successful resolve after null seed — treat as initial
      // seed, not a boundary change.
      _lastKnownBusinessDate = current;
      return;
    }
    if (current == _lastKnownBusinessDate) return;

    _lastKnownBusinessDate = current;

    // HARD-H persist-before-fire: if a backlog hook is wired, persist
    // the boundary event before firing the user's callback so a
    // crashing callback leaves an undelivered row that the next
    // supervisor restart can drain via [BoundaryMonitorSupervisor.drainBacklog].
    String? persistedEventId;
    final willFire = _onBoundaryWillFire;
    if (willFire != null) {
      try {
        persistedEventId = await willFire(current);
      } catch (_) {
        // Persistence failed — still fire callback so foreground UX
        // does not stall. The monitor cannot replay this boundary
        // later because nothing got persisted; the next genuine
        // boundary will reach drainBacklog normally.
        persistedEventId = null;
      }
    }

    _onBoundaryChanged();

    final fired = _onBoundaryFired;
    if (persistedEventId != null && fired != null) {
      try {
        await fired(persistedEventId);
      } catch (_) {
        // Mark-delivered failed — drainBacklog dedups via the same
        // (operator_id, business_date) pair so an extra in-flight row
        // does not produce a duplicate fire.
      }
    }
  }
}
