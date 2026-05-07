// Phase 7.55l.5a — DemandForecastContext v2 Service Tests
//
// Validates:
// A. Anchor: mock replay current business date when available
// B. Anchor: falls back to latest closed business date
// C. 60-day baseline totals and weekly avg compute correctly
// D. Weekly avg contract: round(total / (60/7))
// E. 3-week recent trend totals and weekly avg compute correctly
// F. Resolved weekly forecast covers follows the smoothing rule
// G. Unavailable behavior works cleanly
// H. Compatibility accessors behave as documented
// I. resolveFromContext uses v2 rolling demand

import 'dart:math' show max;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A. Mock replay anchor ─────────────────────────────────────────────────

  group('A — mock replay anchor', () {
    test('uses mock replay current business date when available', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance.getMockReplayBusinessDate(
        restaurantId,
      );

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (mockDate != null) {
        expect(ctx.anchorBusinessDate, equals(mockDate));
      } else {
        final latestClosed = await SqliteShiftRecordRepository.instance
            .getLatestClosedBusinessDate(restaurantId);
        expect(ctx.anchorBusinessDate, equals(latestClosed));
      }
      expect(ctx.restaurantId, equals(restaurantId));
    });

    test('prefers embedded server context from locked weekly cache', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      const serverContext = DemandForecastContext(
        restaurantId: DemoScope.restaurantId,
        anchorBusinessDate: '2026-03-27',
        baselineTotalCovers: 9900,
        baselineWeeklyAvgCovers: 1155,
        baselineWeeksRepresented: 8.571,
        recentThreeWeekTotalCovers: 3300,
        recentThreeWeekWeeklyAvgCovers: 1100,
        recentTrendDeltaCovers: -55,
        resolvedWeeklyForecastCovers: 1128,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: '2026-05-06T12:00:00.000Z',
      );
      await SqliteWeeklyPlanSnapshotRepository.instance.upsertSnapshot(
        WeeklyPlanSnapshot(
          snapshotId: 'server-context-snapshot',
          restaurantId: restaurantId,
          weekStartDate: '2026-03-23',
          weekEndDate: '2026-03-29',
          targetCycleId: 'cycle-server-context',
          forecastContextId: 'fc-server-context',
          forecastCovers: 1128,
          forecastSales: 49632,
          requiredFohHours: 120,
          requiredBohHours: 96,
          theoreticalFohLaborDollars: 2160,
          theoreticalBohLaborDollars: 2208,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
          generatedAt: '2026-05-06T12:00:00.000Z',
          lockedAt: '2026-05-06T12:01:00.000Z',
          forecastContext: serverContext,
        ),
      );

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      expect(ctx.baselineTotalCovers, 9900);
      expect(ctx.resolvedWeeklyForecastCovers, 1128);
      expect(ctx.builtAt, '2026-05-06T12:00:00.000Z');
    });
  });

  // ── B. Latest closed fallback ──────────────────────────────────────────────

  group('B — latest closed business date fallback', () {
    test(
      'falls back to latest closed when mock replay date is unavailable',
      () async {
        final restaurantId = await SqliteRestaurantScopeRepository.instance
            .getActiveRestaurantId();

        final db = await SqliteDatabase.instance.database;
        await db.delete('mock_replay_state');

        final ctx = await DemandForecastContextService.instance
            .getCurrentContext();
        final latestClosed = await SqliteShiftRecordRepository.instance
            .getLatestClosedBusinessDate(restaurantId);

        expect(ctx.anchorBusinessDate, equals(latestClosed));
      },
    );

    test('returns unavailable when no closed shifts exist', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      expect(ctx.anchorBusinessDate, isNull);
      expect(ctx.resolvedWeeklyForecastCovers, isNull);
      expect(ctx.isAvailable, isFalse);
      expect(ctx.coversSource, ForecastDemandSource.unavailable);
    });
  });

  // ── C. 60-day baseline totals ──────────────────────────────────────────────

  group('C — 60-day baseline covers from closed shifts', () {
    test('sums closed-shift covers in the inclusive 60-day window', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.anchorBusinessDate == null) return;

      final startDate = _subtractDays(ctx.anchorBusinessDate!, 59);
      final shifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(
            restaurantId,
            startDate,
            ctx.anchorBusinessDate!,
          );

      final expectedTotal = shifts.fold<int>(0, (s, r) => s + r.covers);
      expect(ctx.baselineTotalCovers, equals(expectedTotal));
      expect(ctx.baselineTotalCovers, greaterThan(0));
    });
  });

  // ── D. Baseline weekly avg contract ─────────────────────────────────────────

  group('D — baseline weekly avg covers contract', () {
    test('baseline weekly avg = round(total / (60/7))', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.baselineTotalCovers == null || ctx.baselineTotalCovers == 0) {
        return;
      }

      final expected = (ctx.baselineTotalCovers! / (60 / 7)).round();
      expect(ctx.baselineWeeklyAvgCovers, equals(expected));
    });

    test('baselineWeeksRepresented equals 60/7', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.isAvailable) {
        expect(ctx.baselineWeeksRepresented, closeTo(60 / 7, 0.001));
      }
    });
  });

  // ── E. 3-week recent trend ────────────────────────────────────────────────

  group('E — 3-week recent trend from closed shifts', () {
    test('sums closed-shift covers in the inclusive 21-day window', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.anchorBusinessDate == null) return;

      final startDate = _subtractDays(ctx.anchorBusinessDate!, 20);
      final shifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(
            restaurantId,
            startDate,
            ctx.anchorBusinessDate!,
          );

      final expectedTotal = shifts.fold<int>(0, (s, r) => s + r.covers);
      expect(ctx.recentThreeWeekTotalCovers, equals(expectedTotal));
    });

    test('3-week weekly avg = round(total / 3)', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.recentThreeWeekTotalCovers == null ||
          ctx.recentThreeWeekTotalCovers == 0) {
        return;
      }

      final expected = (ctx.recentThreeWeekTotalCovers! / 3).round();
      expect(ctx.recentThreeWeekWeeklyAvgCovers, equals(expected));
    });
  });

  // ── F. Resolved weekly forecast covers — smoothing rule ───────────────────

  group('F — resolved weekly forecast covers smoothing rule', () {
    test(
      'when both layers available: resolved = max(0, baseline + delta/2)',
      () async {
        final ctx = await DemandForecastContextService.instance
            .getCurrentContext();

        if (!ctx.isAvailable) return;
        if (ctx.recentThreeWeekTotalCovers == null ||
            ctx.recentThreeWeekTotalCovers == 0) {
          return;
        }

        final delta =
            ctx.recentThreeWeekWeeklyAvgCovers! - ctx.baselineWeeklyAvgCovers!;
        expect(ctx.recentTrendDeltaCovers, equals(delta));

        final expected = max(
          0,
          ctx.baselineWeeklyAvgCovers! + (delta / 2).round(),
        );
        expect(ctx.resolvedWeeklyForecastCovers, equals(expected));
      },
    );

    test('resolved weekly forecast is non-negative', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();

      if (ctx.resolvedWeeklyForecastCovers != null) {
        expect(ctx.resolvedWeeklyForecastCovers, greaterThanOrEqualTo(0));
      }
    });

    test('when only baseline available: resolved = baseline weekly avg', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Use an anchor date far enough back that the 21-day window has no data
      // but the 60-day window does.
      final ctx = await DemandForecastContextService.instance
          .getContextForAnchorDate(restaurantId, '2025-12-01');

      // If the 60-day window has data but 21-day does not, resolved = baseline.
      if (ctx.baselineTotalCovers != null &&
          ctx.baselineTotalCovers! > 0 &&
          (ctx.recentThreeWeekTotalCovers == null ||
              ctx.recentThreeWeekTotalCovers == 0)) {
        expect(
          ctx.resolvedWeeklyForecastCovers,
          equals(ctx.baselineWeeklyAvgCovers),
        );
        expect(ctx.recentTrendDeltaCovers, isNull);
      }
      // If both have data or neither does, this test is not applicable — pass.
    });
  });

  // ── G. Unavailable behavior ───────────────────────────────────────────────

  group('G — unavailable behavior', () {
    test('unavailable sentinel has correct field values', () {
      final ctx = DemandForecastContext.unavailable;
      expect(ctx.isAvailable, isFalse);
      expect(ctx.resolvedWeeklyForecastCovers, isNull);
      expect(ctx.baselineTotalCovers, isNull);
      expect(ctx.baselineWeeklyAvgCovers, isNull);
      expect(ctx.recentThreeWeekTotalCovers, isNull);
      expect(ctx.recentThreeWeekWeeklyAvgCovers, isNull);
      expect(ctx.recentTrendDeltaCovers, isNull);
      expect(ctx.coversSource, ForecastDemandSource.unavailable);
    });

    test('context with no closed shifts is unavailable', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      expect(ctx.isAvailable, isFalse);
    });
  });

  // ── H. Compatibility accessors ─────────────────────────────────────────────

  group('H — compatibility accessors', () {
    test('historicalTotalCovers aliases baselineTotalCovers', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      expect(ctx.historicalTotalCovers, equals(ctx.baselineTotalCovers));
    });

    test(
      'historicalWeeklyAvgCovers aliases resolvedWeeklyForecastCovers',
      () async {
        final ctx = await DemandForecastContextService.instance
            .getCurrentContext();
        expect(
          ctx.historicalWeeklyAvgCovers,
          equals(ctx.resolvedWeeklyForecastCovers),
        );
      },
    );

    test('weeksRepresented aliases baselineWeeksRepresented', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      expect(ctx.weeksRepresented, equals(ctx.baselineWeeksRepresented));
    });
  });

  // ── J. Zero-cover window correctness ────────────────────────────────────────

  group('J — zero-cover window correctness', () {
    test('zero-cover baseline window is available, not unavailable', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      // Insert a closed shift with zero covers in the 60-day window.
      const anchorDate = '2026-03-15';
      await _insertZeroCoverShift(db, restaurantId, '2026-03-10');

      final ctx = await DemandForecastContextService.instance
          .getContextForAnchorDate(restaurantId, anchorDate);

      // The window has a real closed shift — this is valid demand, not missing.
      expect(ctx.isAvailable, isTrue);
      expect(ctx.baselineTotalCovers, equals(0));
      expect(ctx.baselineWeeklyAvgCovers, equals(0));
      expect(ctx.resolvedWeeklyForecastCovers, equals(0));
      expect(
        ctx.coversSource,
        equals(ForecastDemandSource.appDerivedFromHistoricalAverage),
      );
      expect(ctx.coversSource, isNot(ForecastDemandSource.unavailable));
    });

    test('zero-cover in both windows applies smoothing correctly', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      // Insert zero-cover closed shifts in both windows.
      const anchorDate = '2026-03-15';
      await _insertZeroCoverShift(db, restaurantId, '2026-03-10'); // 21-day
      await _insertZeroCoverShift(
        db,
        restaurantId,
        '2026-02-01',
      ); // 60-day only

      final ctx = await DemandForecastContextService.instance
          .getContextForAnchorDate(restaurantId, anchorDate);

      expect(ctx.isAvailable, isTrue);
      expect(ctx.baselineTotalCovers, equals(0));
      expect(ctx.baselineWeeklyAvgCovers, equals(0));
      expect(ctx.recentThreeWeekTotalCovers, equals(0));
      expect(ctx.recentThreeWeekWeeklyAvgCovers, equals(0));
      expect(ctx.recentTrendDeltaCovers, equals(0));
      expect(ctx.resolvedWeeklyForecastCovers, equals(0));
      expect(
        ctx.coversSource,
        equals(ForecastDemandSource.appDerivedFromHistoricalAverage),
      );
    });

    test(
      'truly unavailable means no eligible closed shifts, not zero covers',
      () async {
        final restaurantId = await SqliteRestaurantScopeRepository.instance
            .getActiveRestaurantId();

        final db = await SqliteDatabase.instance.database;
        await db.delete('mock_replay_state');
        await db.delete('shift_records');

        // No shifts at all — this is genuinely unavailable.
        final ctx = await DemandForecastContextService.instance
            .getContextForAnchorDate(restaurantId, '2026-03-15');

        expect(ctx.baselineTotalCovers, isNull);
        expect(ctx.baselineWeeklyAvgCovers, isNull);
        expect(ctx.resolvedWeeklyForecastCovers, isNull);
        expect(ctx.coversSource, equals(ForecastDemandSource.unavailable));
      },
    );

    test(
      'zero-cover baseline with no recent shifts uses baseline directly',
      () async {
        final restaurantId = await SqliteRestaurantScopeRepository.instance
            .getActiveRestaurantId();

        final db = await SqliteDatabase.instance.database;
        await db.delete('mock_replay_state');
        await db.delete('shift_records');

        // Insert a zero-cover shift only in the 60-day range, outside 21-day.
        const anchorDate = '2026-03-15';
        await _insertZeroCoverShift(db, restaurantId, '2026-02-01');

        final ctx = await DemandForecastContextService.instance
            .getContextForAnchorDate(restaurantId, anchorDate);

        expect(ctx.isAvailable, isTrue);
        expect(ctx.baselineTotalCovers, equals(0));
        expect(ctx.baselineWeeklyAvgCovers, equals(0));
        expect(ctx.recentThreeWeekTotalCovers, isNull);
        expect(ctx.recentThreeWeekWeeklyAvgCovers, isNull);
        expect(ctx.recentTrendDeltaCovers, isNull);
        expect(ctx.resolvedWeeklyForecastCovers, equals(0));
        expect(
          ctx.coversSource,
          equals(ForecastDemandSource.appDerivedFromHistoricalAverage),
        );
      },
    );
  });

  // ── I. resolveFromContext uses v2 rolling demand ────────────────────────────

  group('I — resolveFromContext uses v2 rolling demand', () {
    test('resolveFromContext uses resolved weekly forecast covers', () async {
      final ctx = await DemandForecastContextService.instance
          .getCurrentContext();
      const testPPA = 42.0;

      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: ctx,
      );

      if (ctx.isAvailable) {
        expect(
          fromContext.forecastCovers,
          equals(ctx.resolvedWeeklyForecastCovers),
        );
        expect(
          fromContext.forecastSales,
          closeTo(ctx.resolvedWeeklyForecastCovers! * testPPA, 0.01),
        );
      } else {
        expect(fromContext.isAvailable, isFalse);
      }
    });

    test('demo fallback still works when context is unavailable', () {
      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: 42.0,
        context: DemandForecastContext.unavailable,
        demoMode: true,
      );
      expect(fromContext.isAvailable, isTrue);
      expect(fromContext.coversSource, ForecastDemandSource.demoFallback);
      expect(fromContext.forecastCovers, 1200);
    });
  });
}

/// Test-only date helper for independent verification.
String _subtractDays(String isoDate, int days) {
  final parts = isoDate.split('-');
  final dt = DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final result = dt.subtract(Duration(days: days));
  return '${result.year}-${result.month.toString().padLeft(2, '0')}'
      '-${result.day.toString().padLeft(2, '0')}';
}

/// Inserts a minimal closed shift record with zero covers for testing.
Future<void> _insertZeroCoverShift(
  dynamic db,
  String restaurantId,
  String businessDate,
) async {
  await db.insert('shift_records', {
    'restaurant_id': restaurantId,
    'week_id': 'W-test',
    'day_label': 'Monday',
    'daypart': 'all_day',
    'status': 'closed',
    'covers': 0,
    'forecast_covers': 0,
    'ppa': 0.0,
    'cplh': 0.0,
    'splh': 0.0,
    'blended_wage': 0.0,
    'foh_hours': 0,
    'boh_hours': 0,
    'foh_labor_pct': 0.0,
    'boh_labor_pct': 0.0,
    'total_labor_pct': 0.0,
    'variance_pts': 0.0,
    'primary_lever': 'none',
    'business_date': businessDate,
  });
}
