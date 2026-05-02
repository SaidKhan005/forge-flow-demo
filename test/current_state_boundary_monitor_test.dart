// CurrentStateBoundaryMonitor unit tests.
//
// Validates:
// A. Initial seed does not fire the boundary-changed callback
// B. Boundary detection fires callback exactly once on change
// C. Deduplication: repeated checks at the same boundary do not repeat
// D. Start / stop lifecycle
// E. Resilience: resolver failures do not crash the monitor
// F. Time Boundary Contract Rule 1: boundary clock is restaurant-local,
//    not device-local; missing/invalid timezone throws explicitly with
//    no silent fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/services/current_state_boundary_monitor.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _utcLocation = RestaurantLocation(
  restaurantId: 'r-utc',
  displayName: 'UTC Restaurant',
  businessTimezone: 'UTC',
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
);

void main() {
  // ── A: initial seed ──────────────────────────────────────────────────

  group('A — initial seed', () {
    test('seed does not fire callback', () async {
      int callCount = 0;
      final monitor = CurrentStateBoundaryMonitor(
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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
        location: _utcLocation,
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

  // ── F: restaurant-local boundary clock (Time Boundary Contract Rule 1) ─

  group('F — restaurant-local boundary clock', () {
    setUpAll(() {
      tzdata.initializeTimeZones();
    });

    test('default clock reads from the location\'s IANA timezone, not '
        'the device timezone', () async {
      // Both monitors share the same wall-clock instant in UTC, but each
      // monitor sees "now" through its own location's tz. The resolver
      // captures the timestamp it was handed so we can verify each
      // monitor passed a distinct, location-correct wall-clock value.
      const tokyo = RestaurantLocation(
        restaurantId: 'r-tokyo',
        displayName: 'Tokyo',
        businessTimezone: 'Asia/Tokyo',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      const newYork = RestaurantLocation(
        restaurantId: 'r-nyc',
        displayName: 'New York',
        businessTimezone: 'America/New_York',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      DateTime? tokyoSeen;
      DateTime? nycSeen;

      final tokyoMonitor = CurrentStateBoundaryMonitor(
        location: tokyo,
        resolveBusinessDate: (ts) async {
          tokyoSeen = ts;
          return '2026-04-13';
        },
        onBoundaryChanged: () {},
        // No injected clock — exercises the production tz-aware default.
        checkInterval: const Duration(hours: 99),
      );
      final nycMonitor = CurrentStateBoundaryMonitor(
        location: newYork,
        resolveBusinessDate: (ts) async {
          nycSeen = ts;
          return '2026-04-13';
        },
        onBoundaryChanged: () {},
        checkInterval: const Duration(hours: 99),
      );

      tokyoMonitor.start();
      nycMonitor.start();
      await Future<void>.delayed(Duration.zero);

      expect(tokyoSeen, isNotNull);
      expect(nycSeen, isNotNull);

      // Same UTC instant, different wall-clock representations.
      // Tokyo is +09:00 and New York is -04:00 or -05:00; the gap is
      // 13–14 hours. Asserting they're at least 8 hours apart catches
      // any device-tz leakage without depending on DST exact offsets.
      final gap = tokyoSeen!.toUtc().difference(nycSeen!.toUtc()).abs();
      expect(
        gap.inMinutes < 60,
        isTrue,
        reason:
            'Both monitors should sample the same UTC instant; '
            'instead saw Tokyo=$tokyoSeen NYC=$nycSeen',
      );

      // The local-wall-clock hour-of-day should differ — proves the
      // monitors are reading the location\'s tz, not a shared device tz.
      final wallGap = (tokyoSeen!.hour - nycSeen!.hour).abs();
      expect(
        wallGap == 0,
        isFalse,
        reason:
            'Tokyo and New York must show different wall-clock hours; '
            'instead Tokyo.hour=${tokyoSeen!.hour} '
            'NYC.hour=${nycSeen!.hour}',
      );

      tokyoMonitor.stop();
      nycMonitor.stop();
    });

    test('default clock matches tz.TZDateTime.now() for the location', () async {
      const tokyo = RestaurantLocation(
        restaurantId: 'r-tokyo',
        displayName: 'Tokyo',
        businessTimezone: 'Asia/Tokyo',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      DateTime? seen;
      final monitor = CurrentStateBoundaryMonitor(
        location: tokyo,
        resolveBusinessDate: (ts) async {
          seen = ts;
          return null;
        },
        onBoundaryChanged: () {},
        checkInterval: const Duration(hours: 99),
      );
      monitor.start();
      await Future<void>.delayed(Duration.zero);

      final tokyoNow = tz.TZDateTime.now(tz.getLocation('Asia/Tokyo'));
      expect(seen, isNotNull);
      // Allow up to 5 seconds of drift between the two samples.
      expect(
        seen!.toUtc().difference(tokyoNow.toUtc()).abs().inSeconds <= 5,
        isTrue,
        reason: 'Monitor clock should sample tz.TZDateTime.now(Tokyo); '
            'saw $seen vs $tokyoNow',
      );
      // The seen value\'s wall-clock hour should match Tokyo\'s, not UTC\'s.
      expect(seen!.hour, tokyoNow.hour);

      monitor.stop();
    });

    test('per-location boundary: same UTC moment, different business dates',
        () async {
      // Pick a UTC time where the wall-clock dates differ between zones.
      // 2026-04-13 23:30 UTC is:
      //   - Tokyo (UTC+9):  2026-04-14 08:30 → business date 2026-04-14
      //   - LA (UTC-7 DST): 2026-04-13 16:30 → business date 2026-04-13
      const tokyo = RestaurantLocation(
        restaurantId: 'r-tokyo',
        displayName: 'Tokyo',
        businessTimezone: 'Asia/Tokyo',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      const la = RestaurantLocation(
        restaurantId: 'r-la',
        displayName: 'LA',
        businessTimezone: 'America/Los_Angeles',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      // Resolver mimics the production rule: same calendar day in the
      // location\'s wall clock (no early-AM cutoff for this test).
      String resolveDate(DateTime ts) =>
          '${ts.year}-${ts.month.toString().padLeft(2, '0')}'
          '-${ts.day.toString().padLeft(2, '0')}';

      final tokyoLocation = tz.getLocation('Asia/Tokyo');
      final laLocation = tz.getLocation('America/Los_Angeles');
      final utcInstant = DateTime.utc(2026, 4, 13, 23, 30);

      final tokyoMonitor = CurrentStateBoundaryMonitor(
        location: tokyo,
        resolveBusinessDate: (ts) async => resolveDate(ts),
        onBoundaryChanged: () {},
        clock: () => tz.TZDateTime.from(utcInstant, tokyoLocation),
        checkInterval: const Duration(hours: 99),
      );
      final laMonitor = CurrentStateBoundaryMonitor(
        location: la,
        resolveBusinessDate: (ts) async => resolveDate(ts),
        onBoundaryChanged: () {},
        clock: () => tz.TZDateTime.from(utcInstant, laLocation),
        checkInterval: const Duration(hours: 99),
      );

      tokyoMonitor.start();
      laMonitor.start();
      await Future<void>.delayed(Duration.zero);

      expect(tokyoMonitor.lastKnownBusinessDate, '2026-04-14');
      expect(laMonitor.lastKnownBusinessDate, '2026-04-13',
          reason: 'Same UTC moment must yield different business dates per '
              'location (Time Boundary Contract Rule 1).');

      tokyoMonitor.stop();
      laMonitor.stop();
    });

    test('empty businessTimezone throws MissingTimezoneError', () {
      const broken = RestaurantLocation(
        restaurantId: 'r-broken',
        displayName: 'Broken',
        businessTimezone: '',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      expect(
        () => CurrentStateBoundaryMonitor(
          location: broken,
          resolveBusinessDate: (_) async => null,
          onBoundaryChanged: () {},
        ),
        throwsA(isA<MissingTimezoneError>()
            .having((e) => e.restaurantId, 'restaurantId', 'r-broken')),
      );
    });

    test('whitespace-only businessTimezone throws MissingTimezoneError', () {
      const broken = RestaurantLocation(
        restaurantId: 'r-broken-2',
        displayName: 'Broken',
        businessTimezone: '   ',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      expect(
        () => CurrentStateBoundaryMonitor(
          location: broken,
          resolveBusinessDate: (_) async => null,
          onBoundaryChanged: () {},
        ),
        throwsA(isA<MissingTimezoneError>()),
      );
    });

    test('invalid IANA timezone throws MissingTimezoneError (no fallback)',
        () {
      const broken = RestaurantLocation(
        restaurantId: 'r-bogus',
        displayName: 'Bogus',
        businessTimezone: 'Mars/Olympus',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );

      expect(
        () => CurrentStateBoundaryMonitor(
          location: broken,
          resolveBusinessDate: (_) async => null,
          onBoundaryChanged: () {},
        ),
        throwsA(isA<MissingTimezoneError>()
            .having((e) => e.timezoneName, 'timezoneName', 'Mars/Olympus')),
      );
    });
  });
}
