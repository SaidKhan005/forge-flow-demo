// Phase 8.0 — Scenarios A-F binding tests for the IANA timezone
// converter at the adapter boundary.
//
// Per `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`,
// these six scenarios are HARD acceptance gates. The slice cannot
// ship without all six green. Each scenario asserts the canonical
// adapter-side projection of `(restaurantTimezone, businessDayRollover,
// vendorInstant)` to `businessDate`.
//
// Each per-vendor adapter that lands in subsequent slices re-runs
// the same six scenarios with vendor-shape inputs (timestamp string
// formats specific to that vendor). The framework-side bindings here
// prove the converter itself works correctly; vendor-shape rebinding
// proves each adapter's parser correctly hands the converter a
// well-formed UTC instant.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
  });

  final converter = IanaTimezoneConverter();

  group('IANA Scenarios A-F', () {
    test('Scenario A — Pacific restaurant, 4 AM business-day cutoff', () {
      // Vendor emits 2025-01-01T10:30:00Z. Restaurant tz America/Los_Angeles,
      // business-day start 04:00. Expected businessDate = 2024-12-31.
      // 10:30 UTC = 02:30 PST = before 04:00 cutoff = prior business date.
      final instant = DateTime.utc(2025, 1, 1, 10, 30);
      final businessDate = converter.toBusinessDate(
        restaurantTimezone: 'America/Los_Angeles',
        businessDayRolloverHour: 4,
        instant: instant,
      );
      expect(businessDate, DateTime.utc(2024, 12, 31));
    });

    test('Scenario B — late-night ticket spanning midnight (both prior)', () {
      // Dinner ticket opens 23:55 ET, closes 00:15 ET. Both events
      // belong to the prior business date with 04:00 local cutoff.
      // 23:55 ET on 2025-08-15 in summer (EDT, UTC-4) = 03:55 UTC
      // on 2025-08-16 — both events must bucket to 2025-08-15.
      final opens = DateTime.utc(2025, 8, 16, 3, 55);
      final closes = DateTime.utc(2025, 8, 16, 4, 15);
      final opensBd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: opens,
      );
      final closesBd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: closes,
      );
      expect(opensBd, DateTime.utc(2025, 8, 15));
      expect(closesBd, DateTime.utc(2025, 8, 15));
    });

    test('Scenario C — DST fall-back ambiguity', () {
      // 2025-11-02T05:30:00Z and 2025-11-02T06:30:00Z both convert
      // to 01:30 local in America/New_York (DST fall-back). IANA
      // library disambiguates correctly; fixed-offset would not.
      // Both with 04:00 rollover bucket to 2025-11-01 (prior
      // business date because 01:30 < 04:00).
      final firstInstant = DateTime.utc(2025, 11, 2, 5, 30);
      final secondInstant = DateTime.utc(2025, 11, 2, 6, 30);
      final firstLocal = converter.toBusinessLocal(
        restaurantTimezone: 'America/New_York',
        instant: firstInstant,
      );
      final secondLocal = converter.toBusinessLocal(
        restaurantTimezone: 'America/New_York',
        instant: secondInstant,
      );
      // Both project to 01:30 local.
      expect(firstLocal.hour, 1);
      expect(firstLocal.minute, 30);
      expect(secondLocal.hour, 1);
      expect(secondLocal.minute, 30);
      // Business date for both is 2025-11-01 (before 04:00 cutoff).
      final firstBd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: firstInstant,
      );
      final secondBd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: secondInstant,
      );
      expect(firstBd, DateTime.utc(2025, 11, 1));
      expect(secondBd, DateTime.utc(2025, 11, 1));
    });

    test('Scenario D — multi-location chain (Toronto + Vancouver)', () {
      // Two locations on the same operator with different timezones.
      // "Today's covers" for each resolves against the location's
      // own timezone, not the operator's device clock.
      // Same UTC instant: 2025-06-15T22:00:00Z (a single moment).
      final instant = DateTime.utc(2025, 6, 15, 22);
      // Toronto (EDT, UTC-4) -> 18:00 local -> business date 2025-06-15.
      final torontoBd = converter.toBusinessDate(
        restaurantTimezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        instant: instant,
      );
      expect(torontoBd, DateTime.utc(2025, 6, 15));
      // Vancouver (PDT, UTC-7) -> 15:00 local -> business date 2025-06-15.
      final vancouverBd = converter.toBusinessDate(
        restaurantTimezone: 'America/Vancouver',
        businessDayRolloverHour: 4,
        instant: instant,
      );
      expect(vancouverBd, DateTime.utc(2025, 6, 15));
      // Same instant near midnight: 2025-06-16T07:00:00Z.
      // Toronto -> 03:00 local -> still 2025-06-15 (before 04:00 cutoff).
      // Vancouver -> 00:00 local -> still 2025-06-15 (before 04:00 cutoff).
      final lateInstant = DateTime.utc(2025, 6, 16, 7);
      final torontoLate = converter.toBusinessDate(
        restaurantTimezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        instant: lateInstant,
      );
      final vancouverLate = converter.toBusinessDate(
        restaurantTimezone: 'America/Vancouver',
        businessDayRolloverHour: 4,
        instant: lateInstant,
      );
      expect(torontoLate, DateTime.utc(2025, 6, 15));
      expect(vancouverLate, DateTime.utc(2025, 6, 15));
    });

    test('Scenario E — ambiguous vendor timestamp policy declared', () {
      // Vendor emits 2025-01-01T02:30:00 with no Z suffix and no
      // offset. The adapter's [TimestampPolicy] declares the
      // convention ("treat as UTC", "treat as location-local",
      // or "refuse"). The converter itself takes a UTC instant —
      // proving the policy at the adapter parser layer is the
      // companion test (vendor-shape rebinding); here we verify
      // both path projections produce the expected business dates.
      // Treat-as-UTC: 02:30 UTC -> 02:30 in UTC tz -> 2024-12-31.
      final asUtcInstant = DateTime.utc(2025, 1, 1, 2, 30);
      final asUtcBd = converter.toBusinessDate(
        restaurantTimezone: 'UTC',
        businessDayRolloverHour: 4,
        instant: asUtcInstant,
      );
      expect(asUtcBd, DateTime.utc(2024, 12, 31));
      // Treat-as-location-local: 02:30 local in America/New_York is
      // 07:30 UTC; the projection back to 02:30 local with 04:00
      // cutoff -> business date 2024-12-31.
      final asLocalInstant = DateTime.utc(2025, 1, 1, 7, 30);
      final asLocalBd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: asLocalInstant,
      );
      expect(asLocalBd, DateTime.utc(2024, 12, 31));
    });

    test('Scenario F — historical replay / pre-DST-policy-change', () {
      // Replay data from a year when DST rules differed. IANA's
      // historical offset database is the authority. Here we test
      // a 2007-03-11 instant in America/New_York — before the 2007
      // DST policy change shifted the spring-forward date earlier.
      // 2007-03-11T08:00:00Z under post-2007 rules = 04:00 local
      // (after spring-forward); under pre-2007 rules = 03:00 local
      // (still standard time). The IANA db carries both rule sets
      // and selects 04:00 EDT correctly.
      final instant = DateTime.utc(2007, 3, 11, 8);
      final local = converter.toBusinessLocal(
        restaurantTimezone: 'America/New_York',
        instant: instant,
      );
      // After spring-forward the local clock shows 04:00.
      expect(local.hour, 4);
      // Business date with 04:00 rollover: 04:00 local is exactly
      // at the rollover, which counts as the new business date.
      // 2007-03-11.
      final bd = converter.toBusinessDate(
        restaurantTimezone: 'America/New_York',
        businessDayRolloverHour: 4,
        instant: instant,
      );
      expect(bd, DateTime.utc(2007, 3, 11));
    });
  });

  group('IanaTimezoneConverter — guardrails', () {
    test('rejects unknown timezone', () {
      expect(
        () => converter.toBusinessLocal(
          restaurantTimezone: 'Mars/Olympus',
          instant: DateTime.utc(2025, 1, 1),
        ),
        throwsA(isA<IanaTimezoneConverterError>()),
      );
    });

    test('rejects out-of-range rollover hour', () {
      expect(
        () => converter.toBusinessDate(
          restaurantTimezone: 'America/Toronto',
          businessDayRolloverHour: 24,
          instant: DateTime.utc(2025, 1, 1),
        ),
        throwsA(isA<IanaTimezoneConverterError>()),
      );
      expect(
        () => converter.toBusinessDate(
          restaurantTimezone: 'America/Toronto',
          businessDayRolloverHour: -1,
          instant: DateTime.utc(2025, 1, 1),
        ),
        throwsA(isA<IanaTimezoneConverterError>()),
      );
    });
  });
}
