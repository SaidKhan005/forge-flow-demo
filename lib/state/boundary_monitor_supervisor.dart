// Supervises one CurrentStateBoundaryMonitor per accessible
// `RestaurantLocation`. Each monitor reads its own restaurant-local
// wall clock (Time Boundary Contract Rule 1), so a multi-location
// operator whose locations span timezones gets independent boundary
// clocks instead of a single device-tz monitor.
//
// Wiring contract:
// - The owner (e.g. ForgeFlowApp shell) is responsible for connecting
//   this to whatever source of "currently accessible locations" the
//   runtime exposes (today: `RestaurantScopeNotifier`'s single active
//   restaurant; later: a multi-location notifier). Calling code invokes
//   [syncTo] each time the accessible-locations list changes.
// - [start] / [stop] mirror foreground/background lifecycle. Once
//   started, newly added monitors come up running; once stopped, newly
//   added monitors stay quiescent until the next start.
//
// Reconciliation rule:
// - Locations are keyed by `restaurantId`.
// - A new id spawns a fresh monitor (and starts it if currently running).
// - An id whose `businessTimezone` changed is replaced (old monitor
//   stopped, new monitor spawned with the new tz; started if running).
// - An id no longer in the input list has its monitor stopped and
//   removed.
//
// HARD-H — durable backlog:
// - The supervisor takes an optional [BoundaryEventOutbox]. When
//   wired, every fire persists a row BEFORE the in-process callback
//   runs and stamps it delivered AFTER the callback succeeds. A crash
//   mid-fire leaves an undelivered row that the next supervisor
//   `start()` replays via [drainBacklog].
// - Two adapters ship today:
//     * `SqliteBoundaryEventOutbox` — Flutter app shell (per-device
//       backlog; the app cannot hold Postgres credentials per Hard
//       Promise #7).
//     * `PostgresBoundaryEventOutbox` — server-side / live-binding
//       tests (wraps the canonical `event_outbox` table).

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/models/restaurant_location.dart';
import '../services/boundary_event_outbox.dart';
import '../services/current_state_boundary_monitor.dart';

// Re-export the boundary topic constant from the Postgres adapter so
// existing imports in tests + docs continue to resolve.
export '../services/postgres_boundary_event_outbox.dart' show boundaryRolloverEventTopic;

typedef BoundaryMonitorFactory = CurrentStateBoundaryMonitor Function({
  required RestaurantLocation location,
  required Future<String?> Function(DateTime) resolveBusinessDate,
  required void Function() onBoundaryChanged,
  BoundaryWillFireHook? onBoundaryWillFire,
  BoundaryFiredHook? onBoundaryFired,
});

class BoundaryMonitorSupervisor {
  BoundaryMonitorSupervisor({
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    BoundaryMonitorFactory? monitorFactory,
    BoundaryEventOutbox? eventOutbox,
  })  : _resolveBusinessDate = resolveBusinessDate,
        _onBoundaryChanged = onBoundaryChanged,
        _monitorFactory = monitorFactory ?? _defaultFactory,
        _eventOutbox = eventOutbox;

  static CurrentStateBoundaryMonitor _defaultFactory({
    required RestaurantLocation location,
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    BoundaryWillFireHook? onBoundaryWillFire,
    BoundaryFiredHook? onBoundaryFired,
  }) {
    return CurrentStateBoundaryMonitor(
      location: location,
      resolveBusinessDate: resolveBusinessDate,
      onBoundaryChanged: onBoundaryChanged,
      onBoundaryWillFire: onBoundaryWillFire,
      onBoundaryFired: onBoundaryFired,
    );
  }

  final Future<String?> Function(DateTime) _resolveBusinessDate;
  final void Function() _onBoundaryChanged;
  final BoundaryMonitorFactory _monitorFactory;
  final BoundaryEventOutbox? _eventOutbox;

  final Map<String, CurrentStateBoundaryMonitor> _monitors =
      <String, CurrentStateBoundaryMonitor>{};

  bool _isRunning = false;
  bool _disposed = false;

  /// Snapshot view of the currently supervised monitors keyed by
  /// `restaurantId`. Exposed for tests and diagnostics.
  @visibleForTesting
  Map<String, CurrentStateBoundaryMonitor> get monitors =>
      Map<String, CurrentStateBoundaryMonitor>.unmodifiable(_monitors);

  /// True between `start()` and `stop()` / `dispose()`.
  bool get isRunning => _isRunning;

  /// Reconcile the supervised monitor set to [accessibleLocations].
  ///
  /// Adds monitors for new ids, replaces monitors whose timezone changed,
  /// and tears down monitors whose ids dropped out of the list. Newly
  /// spawned monitors are started immediately if the supervisor is
  /// currently running.
  void syncTo(List<RestaurantLocation> accessibleLocations) {
    _ensureNotDisposed();

    final desiredIds = <String>{
      for (final loc in accessibleLocations) loc.restaurantId,
    };

    // Tear down monitors no longer accessible.
    final removedIds = _monitors.keys
        .where((id) => !desiredIds.contains(id))
        .toList(growable: false);
    for (final id in removedIds) {
      _monitors.remove(id)?.stop();
    }

    // Add new monitors and replace those whose timezone changed.
    for (final loc in accessibleLocations) {
      final existing = _monitors[loc.restaurantId];
      if (existing == null) {
        _spawn(loc);
      } else if (existing.location.businessTimezone != loc.businessTimezone) {
        existing.stop();
        _monitors.remove(loc.restaurantId);
        _spawn(loc);
      }
    }
  }

  /// Start every supervised monitor and remember the running state so
  /// monitors added later via [syncTo] also start automatically.
  void start() {
    _ensureNotDisposed();
    _isRunning = true;
    for (final monitor in _monitors.values) {
      monitor.start();
    }
  }

  /// Stop every supervised monitor and remember the stopped state so
  /// monitors added later via [syncTo] stay quiescent until the next
  /// [start] call.
  void stop() {
    _isRunning = false;
    for (final monitor in _monitors.values) {
      monitor.stop();
    }
  }

  /// Permanently shut down the supervisor. Stops and forgets every
  /// monitor; subsequent calls to [syncTo] / [start] throw.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isRunning = false;
    for (final monitor in _monitors.values) {
      monitor.stop();
    }
    _monitors.clear();
  }

  /// HARD-H — drain any rollover events that were persisted but not
  /// marked delivered (e.g. the previous supervisor instance crashed
  /// after persisting + before the callback completed). For each
  /// pending row, fire `onBoundaryChanged` once and stamp the row
  /// delivered so subsequent drains pass it over.
  ///
  /// No-op when the supervisor is constructed without a
  /// [BoundaryEventOutbox]. Safe to call any time after [start];
  /// production wiring should invoke this once at app launch /
  /// supervisor restart, before the first periodic check fires.
  Future<void> drainBacklog({int batchSize = 100}) async {
    _ensureNotDisposed();
    final outbox = _eventOutbox;
    if (outbox == null) return;

    final claimed = await outbox.claimPending(batchSize: batchSize);
    for (final row in claimed) {
      try {
        _onBoundaryChanged();
      } catch (_) {
        // Callback failed AGAIN — leave the row claimed (the adapter
        // either holds the lock until the reclaim window passes
        // (Postgres) or simply leaves `delivered_at IS NULL` so the
        // next session's drain re-tries (SQLite)). The HARD-H
        // contract asks for "exactly once" on the SUCCESS path;
        // repeated callback failures fall back to the at-least-once
        // safety net.
        continue;
      }
      try {
        await outbox.markDelivered(row.eventId);
      } catch (_) {
        // markDelivered failed — the next drain will re-claim and
        // re-fire. The boundary callback is idempotent because the
        // monitor's `lastKnownBusinessDate` dedups within a process.
      }
    }
  }

  // ── Internal ────────────────────────────────────────────────────────

  void _spawn(RestaurantLocation location) {
    final monitor = _monitorFactory(
      location: location,
      resolveBusinessDate: _resolveBusinessDate,
      onBoundaryChanged: _onBoundaryChanged,
      onBoundaryWillFire: _eventOutbox == null
          ? null
          : (businessDate) => _persistBoundaryEvent(location, businessDate),
      onBoundaryFired: _eventOutbox == null
          ? null
          : (eventId) => _markBoundaryEventDelivered(eventId),
    );
    _monitors[location.restaurantId] = monitor;
    if (_isRunning) {
      monitor.start();
    }
  }

  Future<String?> _persistBoundaryEvent(
    RestaurantLocation location,
    String businessDate,
  ) async {
    final outbox = _eventOutbox;
    if (outbox == null) return null;
    return outbox.persist(
      restaurantId: location.restaurantId,
      businessDate: businessDate,
    );
  }

  Future<void> _markBoundaryEventDelivered(String eventId) async {
    final outbox = _eventOutbox;
    if (outbox == null) return;
    await outbox.markDelivered(eventId);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError(
        'BoundaryMonitorSupervisor has been disposed and cannot be reused.',
      );
    }
  }
}
