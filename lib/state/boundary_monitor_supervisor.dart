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

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../domain/models/restaurant_location.dart';
import '../services/current_state_boundary_monitor.dart';

typedef BoundaryMonitorFactory = CurrentStateBoundaryMonitor Function({
  required RestaurantLocation location,
  required Future<String?> Function(DateTime) resolveBusinessDate,
  required void Function() onBoundaryChanged,
});

class BoundaryMonitorSupervisor {
  BoundaryMonitorSupervisor({
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    BoundaryMonitorFactory? monitorFactory,
  })  : _resolveBusinessDate = resolveBusinessDate,
        _onBoundaryChanged = onBoundaryChanged,
        _monitorFactory = monitorFactory ?? _defaultFactory;

  static CurrentStateBoundaryMonitor _defaultFactory({
    required RestaurantLocation location,
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
  }) {
    return CurrentStateBoundaryMonitor(
      location: location,
      resolveBusinessDate: resolveBusinessDate,
      onBoundaryChanged: onBoundaryChanged,
    );
  }

  final Future<String?> Function(DateTime) _resolveBusinessDate;
  final void Function() _onBoundaryChanged;
  final BoundaryMonitorFactory _monitorFactory;

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

  // ── Internal ────────────────────────────────────────────────────────

  void _spawn(RestaurantLocation location) {
    final monitor = _monitorFactory(
      location: location,
      resolveBusinessDate: _resolveBusinessDate,
      onBoundaryChanged: _onBoundaryChanged,
    );
    _monitors[location.restaurantId] = monitor;
    if (_isRunning) {
      monitor.start();
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError(
        'BoundaryMonitorSupervisor has been disposed and cannot be reused.',
      );
    }
  }
}
