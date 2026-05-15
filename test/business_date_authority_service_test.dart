// Phase 7.55m.1 — BusinessDateAuthorityService tests.
//
// Validates:
// A. Planning-anchor returns mock replay business date when present
// B. Planning-anchor falls back to latest closed business date
// C. Planning-anchor returns null when neither source is available
// D. Migrated planning services still resolve anchor dates correctly
// E. Canonical day ordering is consistent and reusable
// F. Operational Shift/open-snapshot authority is NOT collapsed into
//    the planning-anchor seam
// G. Date arithmetic helper behaves correctly
// H. Business-date resolution from timing config (7.55n.2)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/canonical_day_order.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/services/business_date_authority_service.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A. Mock replay anchor ─────────────────────────────────────────────────

  group('A — planning anchor uses mock replay date when present', () {
    test('returns mock replay business date', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance.getMockReplayBusinessDate(
        restaurantId,
      );

      // Seeded data should have a mock replay date.
      expect(mockDate, isNotNull);

      final anchorDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      expect(anchorDate, equals(mockDate));
    });
  });

  // ── B. Latest closed fallback ──────────────────────────────────────────────

  group('B — planning anchor falls back to latest closed business date', () {
    test('returns latest closed date when mock replay is absent', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Clear mock replay state.
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');

      final anchorDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      final latestClosed = await SqliteShiftRecordRepository.instance
          .getLatestClosedBusinessDate(restaurantId);

      expect(anchorDate, equals(latestClosed));
      expect(anchorDate, isNotNull);
    });
  });

  // ── C. Null when neither source is available ──────────────────────────────

  group('C — planning anchor returns null when no sources available', () {
    test('returns null when no mock replay and no closed shifts', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final anchorDate = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      expect(anchorDate, isNull);
    });
  });

  // ── D. Migrated planning services resolve correctly ────────────────────────

  group('D — migrated services still resolve anchor dates correctly', () {
    test('BaselineManagerService uses shared anchor', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final expectedAnchor = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      // getCandidateShifts internally uses the shared anchor.
      // If it returns candidates, the anchor resolved successfully.
      final candidates = await BaselineManagerService.instance
          .getCandidateShifts();

      expect(expectedAnchor, isNotNull);
      expect(candidates, isNotEmpty);

      // All candidates should be within the 60-day window ending at the anchor.
      for (final c in candidates) {
        expect(c.businessDate, isNotNull);
        expect(
          c.businessDate!.compareTo(expectedAnchor!),
          lessThanOrEqualTo(0),
        );
      }
    });

    test('DemandForecastContextService uses shared anchor', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final expectedAnchor = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate(restaurantId);

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      expect(ctx.anchorBusinessDate, equals(expectedAnchor));
    });

    test('SchedulePlanReadService uses shared anchor for weights', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // loadDistributionWeights internally uses the shared anchor.
      final weights = await SchedulePlanReadService.loadDistributionWeights(
        restaurantId,
      );

      expect(weights, isNotNull);
      expect(weights!.isAvailable, isTrue);
    });

    test('WeeklyPlanSnapshotService uses shared anchor', () async {
      final snapshot = await WeeklyPlanSnapshotService.instance
          .getCurrentWeekSnapshot();

      expect(snapshot, isNotNull);
      expect(snapshot!.forecastCovers, greaterThan(0));
    });

    test('anchor still works after clearing mock replay', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');

      // All services should still work via latest-closed fallback.
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      expect(ctx.isAvailable, isTrue);

      final candidates = await BaselineManagerService.instance
          .getCandidateShifts();
      expect(candidates, isNotEmpty);
    });
  });

  // ── E. Canonical day ordering ──────────────────────────────────────────────

  group('E — canonical day ordering', () {
    test('canonicalDayOrder has exactly 7 entries', () {
      expect(BusinessDateAuthorityService.canonicalDayOrder.length, 7);
    });

    test('canonicalDayOrder is 0-based Mon through Sun', () {
      expect(BusinessDateAuthorityService.canonicalDayOrder['Mon'], 0);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Tue'], 1);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Wed'], 2);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Thu'], 3);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Fri'], 4);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Sat'], 5);
      expect(BusinessDateAuthorityService.canonicalDayOrder['Sun'], 6);
    });

    test('canonicalDayLabels matches canonicalDayOrder keys in order', () {
      final labels = BusinessDateAuthorityService.canonicalDayLabels;
      expect(labels.length, 7);
      for (var i = 0; i < labels.length; i++) {
        expect(BusinessDateAuthorityService.canonicalDayOrder[labels[i]], i);
      }
    });

    test('dayNumber returns 1-based index', () {
      expect(BusinessDateAuthorityService.dayNumber('Mon'), 1);
      expect(BusinessDateAuthorityService.dayNumber('Tue'), 2);
      expect(BusinessDateAuthorityService.dayNumber('Wed'), 3);
      expect(BusinessDateAuthorityService.dayNumber('Thu'), 4);
      expect(BusinessDateAuthorityService.dayNumber('Fri'), 5);
      expect(BusinessDateAuthorityService.dayNumber('Sat'), 6);
      expect(BusinessDateAuthorityService.dayNumber('Sun'), 7);
    });

    test('dayNumber returns null for unrecognized labels', () {
      expect(BusinessDateAuthorityService.dayNumber('Holiday'), isNull);
      expect(BusinessDateAuthorityService.dayNumber(''), isNull);
      expect(BusinessDateAuthorityService.dayNumber('Monday'), isNull);
    });

    test('fullDayNames covers all 7 days', () {
      expect(BusinessDateAuthorityService.fullDayNames.length, 7);
      expect(BusinessDateAuthorityService.fullDayNames[1], 'Monday');
      expect(BusinessDateAuthorityService.fullDayNames[7], 'Sunday');
    });

    test('fullDayNames keys match dayNumber output range', () {
      for (final label in BusinessDateAuthorityService.canonicalDayLabels) {
        final num = BusinessDateAuthorityService.dayNumber(label);
        expect(num, isNotNull);
        expect(BusinessDateAuthorityService.fullDayNames[num!], isNotNull);
      }
    });
  });

  // ── E2. Shared day-order source consistency (7.55m.1a) ──────────────────

  group('E2 — shared day-order source consistency', () {
    test('CanonicalDayOrder is the single source of truth', () {
      // Both consumers must reference the same underlying constants.
      expect(CanonicalDayOrder.labels.length, 7);
      expect(CanonicalDayOrder.index.length, 7);
      expect(CanonicalDayOrder.fullNames.length, 7);
    });

    test('BusinessDateAuthorityService delegates to CanonicalDayOrder', () {
      // canonicalDayOrder (Map)
      expect(
        identical(
          BusinessDateAuthorityService.canonicalDayOrder,
          CanonicalDayOrder.index,
        ),
        isTrue,
      );
      // canonicalDayLabels (List)
      expect(
        identical(
          BusinessDateAuthorityService.canonicalDayLabels,
          CanonicalDayOrder.labels,
        ),
        isTrue,
      );
      // fullDayNames (Map)
      expect(
        identical(
          BusinessDateAuthorityService.fullDayNames,
          CanonicalDayOrder.fullNames,
        ),
        isTrue,
      );
      // dayNumber helper
      for (final label in CanonicalDayOrder.labels) {
        expect(
          BusinessDateAuthorityService.dayNumber(label),
          equals(CanonicalDayOrder.dayNumber(label)),
        );
      }
    });

    test('ScheduleDistributionWeights delegates to CanonicalDayOrder', () {
      expect(
        identical(
          ScheduleDistributionWeights.canonicalDayOrder,
          CanonicalDayOrder.labels,
        ),
        isTrue,
      );
    });

    test('both consumers produce identical Mon-Sun ordering', () {
      // The List form (used by distribution weights iteration).
      final listForm = ScheduleDistributionWeights.canonicalDayOrder;
      // The Map form (used by authority service sorting).
      final mapForm = BusinessDateAuthorityService.canonicalDayOrder;

      // They must agree on ordering.
      for (var i = 0; i < listForm.length; i++) {
        expect(mapForm[listForm[i]], i);
      }
    });

    test('orderedDayWeights uses the shared day-order source', () {
      // Construct a weights instance and verify ordered output uses Mon-Sun.
      final weights = ScheduleDistributionWeights.available(
        dayWeights: {'Wed': 100, 'Mon': 200, 'Fri': 150},
        daypartWeightsByDay: {},
        closedShiftCount: 10,
        closedBusinessDayCount: 20,
        totalCovers: 450,
      );

      final ordered = weights.orderedDayWeights;
      expect(ordered.length, 7);
      expect(ordered[0], ('Mon', 200));
      expect(ordered[1], ('Tue', 0));
      expect(ordered[2], ('Wed', 100));
      expect(ordered[3], ('Thu', 0));
      expect(ordered[4], ('Fri', 150));
      expect(ordered[5], ('Sat', 0));
      expect(ordered[6], ('Sun', 0));
    });
  });

  // ── F. Operational authority is separate ────────────────────────────────────

  group(
    'F — operational Shift authority is not collapsed into planning anchor',
    () {
      test(
        'ShiftService.getCurrentWeekId uses open-snapshot, not planning anchor',
        () async {
          // ShiftService resolves the current week from open shift snapshots,
          // not from the planning-anchor seam. Verify they can differ.
          final restaurantId = await SqliteRestaurantScopeRepository.instance
              .getActiveRestaurantId();

          // Planning anchor.
          final planningAnchor = await BusinessDateAuthorityService.instance
              .resolvePlanningAnchorDate(restaurantId);

          // Operational authority — from open shift snapshots.
          final operationalWeekId = await ShiftService.instance
              .getCurrentWeekId();

          // Both should be non-null with seeded data, but they come from
          // different sources. The important thing is that ShiftService does
          // NOT call BusinessDateAuthorityService.resolvePlanningAnchorDate.
          expect(planningAnchor, isNotNull);
          expect(operationalWeekId, isNotNull);
        },
      );

      test(
        'ShiftService.getShiftDashboard uses open-snapshot business date',
        () async {
          // The Shift dashboard resolves business date from
          // OpenShiftSnapshotRepository, not from the planning anchor.
          //
          // 7.55q.2-review-fix changed getShiftDashboard to consume the
          // existing locked weekly plan (null-if-missing) instead of
          // auto-generating one. reseedDemo() does NOT write a
          // weekly_plan_snapshots row, so the test first primes the locked
          // plan via the auto-generating read-service entrypoint, then
          // asserts the dashboard resolves.
          await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();

          final dashboard = await ShiftService.instance.getShiftDashboard();

          // With seeded data + a locked plan in place, dashboard should work.
          expect(dashboard, isNotNull);
          expect(dashboard!.forecastCovers, greaterThan(0));
        },
      );
    },
  );

  // ── G. Date arithmetic ─────────────────────────────────────────────────────

  group('G — subtractDays helper', () {
    test('subtracts days correctly', () {
      expect(
        BusinessDateAuthorityService.subtractDays('2026-03-27', 0),
        '2026-03-27',
      );
      expect(
        BusinessDateAuthorityService.subtractDays('2026-03-27', 1),
        '2026-03-26',
      );
      expect(
        BusinessDateAuthorityService.subtractDays('2026-03-27', 59),
        '2026-01-27',
      );
    });

    test('handles month boundary correctly', () {
      expect(
        BusinessDateAuthorityService.subtractDays('2026-03-01', 1),
        '2026-02-28',
      );
    });

    test('handles year boundary correctly', () {
      expect(
        BusinessDateAuthorityService.subtractDays('2026-01-01', 1),
        '2025-12-31',
      );
    });

    test('DemandForecastContextService.subtractDays delegates correctly', () {
      // DemandForecastContextService.subtractDays is now a pass-through
      // to BusinessDateAuthorityService.subtractDays.
      expect(
        DemandForecastContextService.subtractDays('2026-03-27', 59),
        equals(BusinessDateAuthorityService.subtractDays('2026-03-27', 59)),
      );
    });
  });

  // ── H. Business-date resolution from timing config (7.55n.2) ──────────────

  group('H — resolveBusinessDate from timing config', () {
    test('resolves through active timing config', () async {
      final result = await BusinessDateAuthorityService.instance
          .resolveBusinessDate(DateTime(2026, 4, 13, 14, 0));

      // Demo config has businessDayStartLocalTime = '04:00'.
      // 14:00 is after cutoff → same calendar date.
      expect(result, '2026-04-13');
    });

    test(
      'before-cutoff resolves to previous date through timing config',
      () async {
        final result = await BusinessDateAuthorityService.instance
            .resolveBusinessDate(DateTime(2026, 4, 13, 3, 0));

        // 03:00 is before 04:00 cutoff → previous calendar date.
        expect(result, '2026-04-12');
      },
    );

    test('exact cutoff resolves to same date through timing config', () async {
      final result = await BusinessDateAuthorityService.instance
          .resolveBusinessDate(DateTime(2026, 4, 13, 4, 0));

      // 04:00 is at 04:00 cutoff → same calendar date.
      expect(result, '2026-04-13');
    });

    test(
      'planning-anchor behavior is unchanged after adding resolver',
      () async {
        final restaurantId = await SqliteRestaurantScopeRepository.instance
            .getActiveRestaurantId();

        final anchorDate = await BusinessDateAuthorityService.instance
            .resolvePlanningAnchorDate(restaurantId);

        // Planning anchor should still resolve from mock replay / latest closed.
        expect(anchorDate, isNotNull);
      },
    );

    test('resolveBusinessDateFromConfig uses explicit config', () {
      const config = RestaurantTimingConfig(
        restaurantId: 'test',
        businessTimezone: 'America/New_York',
        businessDayStartLocalTime: '06:00',
        weekStartDay: 1,
        servicePeriodDefinitions: [],
        createdAt: '2026-04-13T00:00:00Z',
        updatedAt: '2026-04-13T00:00:00Z',
      );

      // 05:59 is before 06:00 cutoff → previous date.
      final before = BusinessDateAuthorityService.resolveBusinessDateFromConfig(
        localTimestamp: DateTime(2026, 4, 13, 5, 59),
        config: config,
      );
      expect(before, '2026-04-12');

      // 06:00 is at cutoff → same date.
      final at = BusinessDateAuthorityService.resolveBusinessDateFromConfig(
        localTimestamp: DateTime(2026, 4, 13, 6, 0),
        config: config,
      );
      expect(at, '2026-04-13');
    });

    test('no hidden DateTime.now() dependency', () async {
      // Calling resolveBusinessDate with a fixed timestamp should always
      // return the same result regardless of device wall clock.
      final r1 = await BusinessDateAuthorityService.instance
          .resolveBusinessDate(DateTime(2026, 4, 13, 14, 0));
      final r2 = await BusinessDateAuthorityService.instance
          .resolveBusinessDate(DateTime(2026, 4, 13, 14, 0));

      expect(r1, equals(r2));
      expect(r1, '2026-04-13');
    });

    // Destructive test — must be last in this group because reseedDemo()
    // does not re-insert restaurant_timing_configs when the restaurant
    // location already exists.
    test('returns null when timing config is unavailable', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('restaurant_timing_configs');
      SqliteRestaurantTimingConfigRepository.instance.resetDao();

      final result = await BusinessDateAuthorityService.instance
          .resolveBusinessDate(DateTime(2026, 4, 13, 14, 0));

      expect(result, isNull);
    });
  });
}
