// BoundaryMonitorSupervisor unit tests.
//
// Validates:
// A. Spawn / teardown reconciliation on `syncTo` calls
// B. Lifecycle: start/stop honor membership changes
// C. Timezone change replaces the existing monitor
// D. dispose tears everything down and refuses further calls
// E. Per-location monitors run independently — one location\'s rollover
//    does not invalidate another\'s.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/services/current_state_boundary_monitor.dart';
import 'package:forge_and_flow/state/boundary_monitor_supervisor.dart';

const _alpha = RestaurantLocation(
  restaurantId: 'alpha',
  displayName: 'Alpha',
  businessTimezone: 'UTC',
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);
const _beta = RestaurantLocation(
  restaurantId: 'beta',
  displayName: 'Beta',
  businessTimezone: 'UTC',
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);
const _gamma = RestaurantLocation(
  restaurantId: 'gamma',
  displayName: 'Gamma',
  businessTimezone: 'UTC',
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);

/// Builds a per-location resolver from a shared mutable map keyed by
/// `restaurantId`. The factory we hand the supervisor injects this
/// resolver into every spawned monitor along with a deterministic
/// fixed clock so tests stay device-tz-independent.
({
  BoundaryMonitorFactory factory,
  Map<String, String?> dates,
  Map<String, int> spawnCount,
  Map<String, int> stopCount,
}) _harness() {
  final dates = <String, String?>{};
  final spawnCount = <String, int>{};
  final stopCount = <String, int>{};

  CurrentStateBoundaryMonitor build({
    required RestaurantLocation location,
    required Future<String?> Function(DateTime) resolveBusinessDate,
    required void Function() onBoundaryChanged,
    BoundaryWillFireHook? onBoundaryWillFire,
    BoundaryFiredHook? onBoundaryFired,
  }) {
    spawnCount[location.restaurantId] =
        (spawnCount[location.restaurantId] ?? 0) + 1;
    return _CountingMonitor(
      delegate: CurrentStateBoundaryMonitor(
        location: location,
        resolveBusinessDate: (_) async => dates[location.restaurantId],
        onBoundaryChanged: onBoundaryChanged,
        onBoundaryWillFire: onBoundaryWillFire,
        onBoundaryFired: onBoundaryFired,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      ),
      onStop: () =>
          stopCount[location.restaurantId] =
              (stopCount[location.restaurantId] ?? 0) + 1,
    );
  }

  return (
    factory: build,
    dates: dates,
    spawnCount: spawnCount,
    stopCount: stopCount,
  );
}

void main() {
  // ── A: reconciliation ──────────────────────────────────────────────

  group('A — reconciliation via syncTo', () {
    test('spawns one monitor per new accessible location', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);

      expect(supervisor.monitors.keys.toSet(), {'alpha', 'beta'});
      expect(h.spawnCount, {'alpha': 1, 'beta': 1});
    });

    test('removes monitors that drop out of the accessible list', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.syncTo(<RestaurantLocation>[_alpha]);

      expect(supervisor.monitors.keys.toSet(), {'alpha'});
      // Removed monitor was stopped before being forgotten.
      expect(h.stopCount['beta'], 1);
    });

    test('idempotent: re-syncing the same list does not respawn monitors',
        () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);

      expect(h.spawnCount, {'alpha': 1, 'beta': 1});
    });

    test('empty list tears down every monitor', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta, _gamma]);
      supervisor.syncTo(const <RestaurantLocation>[]);

      expect(supervisor.monitors, isEmpty);
      expect(h.stopCount, {'alpha': 1, 'beta': 1, 'gamma': 1});
    });
  });

  // ── B: lifecycle integration ────────────────────────────────────────

  group('B — start/stop honor membership', () {
    test('start() runs every supervised monitor', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      // Monitors created before start() are quiescent until start().
      expect(supervisor.monitors['alpha']!.isRunning, false);

      supervisor.start();

      expect(supervisor.isRunning, true);
      expect(supervisor.monitors['alpha']!.isRunning, true);
      expect(supervisor.monitors['beta']!.isRunning, true);

      supervisor.stop();
    });

    test('monitors added after start() come up running', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.start();
      supervisor.syncTo(<RestaurantLocation>[_alpha]);

      expect(supervisor.monitors['alpha']!.isRunning, true);

      supervisor.stop();
    });

    test('monitors added after stop() stay quiescent', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.start();
      supervisor.stop();
      supervisor.syncTo(<RestaurantLocation>[_alpha]);

      expect(supervisor.isRunning, false);
      expect(supervisor.monitors['alpha']!.isRunning, false);
    });

    test('stop() halts every supervised monitor', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.start();
      supervisor.stop();

      expect(supervisor.monitors['alpha']!.isRunning, false);
      expect(supervisor.monitors['beta']!.isRunning, false);
    });
  });

  // ── C: timezone change replaces monitor ─────────────────────────────

  group('C — tz change replaces monitor', () {
    test(
      'same restaurantId with different timezone replaces the monitor',
      () {
        final h = _harness();
        final supervisor = BoundaryMonitorSupervisor(
          resolveBusinessDate: (_) async => null,
          onBoundaryChanged: () {},
          monitorFactory: h.factory,
        );

        supervisor.syncTo(<RestaurantLocation>[_alpha]);
        final original = supervisor.monitors['alpha'];

        const alphaMoved = RestaurantLocation(
          restaurantId: 'alpha',
          displayName: 'Alpha',
          businessTimezone: 'America/New_York',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
        );
        supervisor.syncTo(<RestaurantLocation>[alphaMoved]);

        final replacement = supervisor.monitors['alpha'];
        expect(identical(replacement, original), false,
            reason: 'tz change should replace the monitor');
        expect(h.spawnCount['alpha'], 2);
        expect(h.stopCount['alpha'], 1);
      },
    );

    test('same restaurantId with same timezone does not respawn', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha]);
      final original = supervisor.monitors['alpha'];

      // A new RestaurantLocation instance with identical fields.
      const alphaCopy = RestaurantLocation(
        restaurantId: 'alpha',
        displayName: 'Alpha (renamed)',
        businessTimezone: 'UTC',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-04-13T00:00:00Z',
      );
      supervisor.syncTo(<RestaurantLocation>[alphaCopy]);

      expect(identical(supervisor.monitors['alpha'], original), true);
      expect(h.spawnCount['alpha'], 1);
    });
  });

  // ── D: dispose ──────────────────────────────────────────────────────

  group('D — dispose', () {
    test('dispose tears down every monitor and clears the map', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );

      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.start();
      supervisor.dispose();

      expect(supervisor.isRunning, false);
      expect(supervisor.monitors, isEmpty);
      expect(h.stopCount, {'alpha': 1, 'beta': 1});
    });

    test('syncTo after dispose throws StateError', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );
      supervisor.dispose();

      expect(
        () => supervisor.syncTo(<RestaurantLocation>[_alpha]),
        throwsA(isA<StateError>()),
      );
    });

    test('dispose is idempotent', () {
      final h = _harness();
      final supervisor = BoundaryMonitorSupervisor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: h.factory,
      );
      supervisor.syncTo(<RestaurantLocation>[_alpha]);
      supervisor.dispose();
      // Second dispose must not throw, must not re-stop the monitor.
      supervisor.dispose();
      expect(h.stopCount['alpha'], 1);
    });
  });

  // ── E: per-location independence ────────────────────────────────────

  group('E — per-location independence', () {
    test('rollover on one location fires only that location\'s callback',
        () async {
      final dates = <String, String?>{
        'alpha': '2026-04-13',
        'beta': '2026-04-13',
      };
      final fired = <String, int>{};

      CurrentStateBoundaryMonitor build({
        required RestaurantLocation location,
        required Future<String?> Function(DateTime) resolveBusinessDate,
        required void Function() onBoundaryChanged,
        BoundaryWillFireHook? onBoundaryWillFire,
        BoundaryFiredHook? onBoundaryFired,
      }) {
        return CurrentStateBoundaryMonitor(
          location: location,
          resolveBusinessDate: (_) async => dates[location.restaurantId],
          onBoundaryChanged: () {
            fired[location.restaurantId] =
                (fired[location.restaurantId] ?? 0) + 1;
          },
          onBoundaryWillFire: onBoundaryWillFire,
          onBoundaryFired: onBoundaryFired,
          clock: () => DateTime(2026, 4, 13, 10, 0),
          checkInterval: const Duration(hours: 99),
        );
      }

      final supervisor = BoundaryMonitorSupervisor(
        // Per-location resolver injected via the factory above; the
        // shared resolver here is unused.
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () {},
        monitorFactory: build,
      );
      supervisor.syncTo(<RestaurantLocation>[_alpha, _beta]);
      supervisor.start();
      await Future<void>.delayed(Duration.zero);

      // Only alpha rolls over.
      dates['alpha'] = '2026-04-14';
      await supervisor.monitors['alpha']!.check();
      await supervisor.monitors['beta']!.check();

      expect(fired['alpha'], 1);
      expect(fired['beta'], isNull,
          reason: 'beta did not roll over — its callback must not fire');

      supervisor.stop();
    });
  });
}

/// Wraps a real monitor so the supervisor test can observe `stop()`
/// invocations without poking at private state. Delegates every other
/// method to the underlying monitor.
class _CountingMonitor implements CurrentStateBoundaryMonitor {
  _CountingMonitor({required this.delegate, required this.onStop});

  final CurrentStateBoundaryMonitor delegate;
  final void Function() onStop;

  @override
  RestaurantLocation get location => delegate.location;
  @override
  String get locationId => delegate.locationId;
  @override
  String get timezoneName => delegate.timezoneName;
  @override
  bool get seeded => delegate.seeded;
  @override
  String? get lastKnownBusinessDate => delegate.lastKnownBusinessDate;
  @override
  bool get isRunning => delegate.isRunning;

  @override
  void start() => delegate.start();
  @override
  void stop() {
    delegate.stop();
    onStop();
  }

  @override
  Future<void> check() => delegate.check();
}
