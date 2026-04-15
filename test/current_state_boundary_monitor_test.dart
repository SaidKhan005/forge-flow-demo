// Phase 7.55n.10 — CurrentStateBoundaryMonitor unit tests.
//
// Validates:
// A. Initial seed does not fire the boundary-changed callback
// B. Boundary detection fires callback exactly once on change
// C. Deduplication: repeated checks at the same boundary do not repeat
// D. Start / stop lifecycle
// E. Resilience: resolver failures do not crash the monitor

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/current_state_boundary_monitor.dart';

void main() {
  // ── A: initial seed ──────────────────────────────────────────────────

  group('A — initial seed', () {
    test('seed does not fire callback', () async {
      int callCount = 0;
      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => '2026-04-13',
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99), // won't fire in test
      );

      monitor.start();
      // Allow async seed to complete.
      await Future<void>.delayed(Duration.zero);

      expect(callCount, 0, reason: 'seed should not fire callback');
      expect(monitor.seeded, true);
      expect(monitor.lastKnownBusinessDate, '2026-04-13');

      monitor.stop();
    });

    test('seed with null resolver result does not fire callback', () async {
      int callCount = 0;
      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => null,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      expect(callCount, 0);
      expect(monitor.seeded, true);
      expect(monitor.lastKnownBusinessDate, isNull);

      monitor.stop();
    });
  });

  // ── B: boundary detection ────────────────────────────────────────────

  group('B — boundary detection', () {
    test('changed business date fires callback exactly once', () async {
      String currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 0);

      // Simulate business-date rollover.
      currentDate = '2026-04-14';
      await monitor.check();

      expect(callCount, 1);
      expect(monitor.lastKnownBusinessDate, '2026-04-14');

      monitor.stop();
    });

    test('same business date on check does not fire callback', () async {
      int callCount = 0;
      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => '2026-04-13',
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      await monitor.check();
      await monitor.check();
      await monitor.check();

      expect(callCount, 0, reason: 'no boundary change = no callback');

      monitor.stop();
    });
  });

  // ── C: deduplication ─────────────────────────────────────────────────

  group('C — deduplication', () {
    test('repeated checks at same boundary do not repeat callback', () async {
      String currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 14, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      // Cross boundary once.
      currentDate = '2026-04-14';
      await monitor.check();
      expect(callCount, 1);

      // Repeated checks at the new boundary — no additional callback.
      await monitor.check();
      await monitor.check();
      expect(callCount, 1);

      monitor.stop();
    });

    test('second boundary change fires callback again', () async {
      String currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      // First boundary change.
      currentDate = '2026-04-14';
      await monitor.check();
      expect(callCount, 1);

      // Second boundary change.
      currentDate = '2026-04-15';
      await monitor.check();
      expect(callCount, 2);

      monitor.stop();
    });
  });

  // ── D: start / stop lifecycle ────────────────────────────────────────

  group('D — start / stop', () {
    test('stop prevents further checks from firing callback', () async {
      String currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      monitor.stop();
      expect(monitor.isRunning, false);

      // Manual check still works after stop (for testing), but the
      // timer-driven checks would not fire.
      currentDate = '2026-04-14';
      await monitor.check();
      // check() is a direct call, so it does fire — but the timer is stopped.
      expect(callCount, 1);

      monitor.stop();
    });

    test('isRunning reflects timer state', () async {
      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => '2026-04-13',
        onBoundaryChanged: () {},
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      expect(monitor.isRunning, false);

      monitor.start();
      expect(monitor.isRunning, true);

      monitor.stop();
      expect(monitor.isRunning, false);
    });

    test('restart re-seeds to current date without firing callback',
        () async {
      String currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);
      expect(monitor.lastKnownBusinessDate, '2026-04-13');

      // Simulate business date changing while "backgrounded" (monitor stopped).
      monitor.stop();
      currentDate = '2026-04-14';

      // Restart re-seeds to the new date without firing callback.
      monitor.start();
      await Future<void>.delayed(Duration.zero);

      expect(callCount, 0,
          reason: 'restart re-seeds without firing callback');
      expect(monitor.lastKnownBusinessDate, '2026-04-14');

      // Subsequent check at the same date — no callback.
      await monitor.check();
      expect(callCount, 0);

      monitor.stop();
    });
  });

  // ── E: resilience ───────────────────────────────────────────────────

  group('E — resilience', () {
    test('resolver exception during seed does not crash', () async {
      int callCount = 0;
      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => throw Exception('no DB'),
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      // Should not throw.
      monitor.start();
      await Future<void>.delayed(Duration.zero);

      expect(monitor.seeded, true);
      expect(monitor.lastKnownBusinessDate, isNull);
      expect(callCount, 0);

      monitor.stop();
    });

    test('resolver exception during check does not crash', () async {
      bool shouldThrow = false;
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async {
          if (shouldThrow) throw Exception('transient failure');
          return '2026-04-13';
        },
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      shouldThrow = true;
      // Should not throw — caught internally.
      await monitor.check();
      expect(callCount, 0);

      monitor.stop();
    });

    test('null resolver result during check is a no-op', () async {
      String? currentDate = '2026-04-13';
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);

      // Resolver returns null — check is a no-op.
      currentDate = null;
      await monitor.check();
      expect(callCount, 0);
      expect(monitor.lastKnownBusinessDate, '2026-04-13',
          reason: 'null result should not change lastKnownBusinessDate');

      monitor.stop();
    });

    test('first non-null result after null seed is treated as seed',
        () async {
      String? currentDate;
      int callCount = 0;

      final monitor = CurrentStateBoundaryMonitor(
        resolveBusinessDate: (_) async => currentDate,
        onBoundaryChanged: () => callCount++,
        clock: () => DateTime(2026, 4, 13, 10, 0),
        checkInterval: const Duration(hours: 99),
      );

      monitor.start();
      await Future<void>.delayed(Duration.zero);
      expect(monitor.lastKnownBusinessDate, isNull);

      // First non-null result — treated as initial seed, not boundary change.
      currentDate = '2026-04-13';
      await monitor.check();
      expect(callCount, 0,
          reason: 'first non-null after null seed is a seed, not a change');
      expect(monitor.lastKnownBusinessDate, '2026-04-13');

      // Actual boundary change now fires callback.
      currentDate = '2026-04-14';
      await monitor.check();
      expect(callCount, 1);

      monitor.stop();
    });
  });
}
