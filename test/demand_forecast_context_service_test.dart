// Phase 7.55i.1 — Demand Forecast Context Service Tests
//
// Validates:
// A. Context uses mock replay current business date when available
// B. Context falls back to latest closed business date
// C. Context sums closed-shift covers in the inclusive 60-day window
// D. Weekly avg covers preserves contract: round(total / (60/7))
// E. resolveFromContext produces same result as resolve with matching inputs
// F. Schedule demand resolves same covers/sales from context + target PPA

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/demand_forecast_context_service.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A. Mock replay anchor ─────────────────────────────────────────────────

  group('A — mock replay anchor', () {
    test('uses mock replay current business date when available', () async {
      final restaurantId =
          await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
      final mockDate = await SqliteDatabase.instance
          .getMockReplayBusinessDate(restaurantId);

      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();

      if (mockDate != null) {
        expect(ctx.anchorBusinessDate, equals(mockDate));
      } else {
        // No mock date — should use latest closed
        final latestClosed = await SqliteShiftRecordRepository.instance
            .getLatestClosedBusinessDate(restaurantId);
        expect(ctx.anchorBusinessDate, equals(latestClosed));
      }
      expect(ctx.restaurantId, equals(restaurantId));
    });
  });

  // ── B. Latest closed fallback ──────────────────────────────────────────────

  group('B — latest closed business date fallback', () {
    test('falls back to latest closed when mock replay date is unavailable',
        () async {
      final restaurantId =
          await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();

      // Clear mock replay state
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');

      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();
      final latestClosed = await SqliteShiftRecordRepository.instance
          .getLatestClosedBusinessDate(restaurantId);

      expect(ctx.anchorBusinessDate, equals(latestClosed));
    });

    test('returns unavailable when no closed shifts exist', () async {
      final db = await SqliteDatabase.instance.database;
      await db.delete('mock_replay_state');
      await db.delete('shift_records');

      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();

      expect(ctx.anchorBusinessDate, isNull);
      expect(ctx.historicalWeeklyAvgCovers, isNull);
      expect(ctx.isAvailable, isFalse);
      expect(ctx.coversSource, ForecastDemandSource.unavailable);
    });
  });

  // ── C. Covers sum ─────────────────────────────────────────────────────────

  group('C — covers sum from closed shifts', () {
    test('sums closed-shift covers in the inclusive 60-day window', () async {
      final restaurantId =
          await SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();

      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();

      if (ctx.anchorBusinessDate == null) {
        // No data — skip
        return;
      }

      // Independently query shifts in the same window
      final startDate = _subtractDays(ctx.anchorBusinessDate!, 59);
      final shifts = await SqliteShiftRecordRepository.instance
          .getClosedShiftsInDateRange(restaurantId, startDate, ctx.anchorBusinessDate!);

      final expectedTotal = shifts.fold<int>(0, (s, r) => s + r.covers);
      expect(ctx.historicalTotalCovers, equals(expectedTotal));
      expect(ctx.historicalTotalCovers, greaterThan(0));
    });
  });

  // ── D. Weekly avg contract ────────────────────────────────────────────────

  group('D — weekly avg covers contract', () {
    test('weekly avg = round(total / (60/7))', () async {
      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();

      if (ctx.historicalTotalCovers == null || ctx.historicalTotalCovers == 0) {
        return;
      }

      final expected = (ctx.historicalTotalCovers! / (60 / 7)).round();
      expect(ctx.historicalWeeklyAvgCovers, equals(expected));
    });

    test('weeksRepresented equals 60/7', () async {
      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();

      if (ctx.isAvailable) {
        expect(ctx.weeksRepresented, closeTo(60 / 7, 0.001));
      }
    });
  });

  // ── E. resolveFromContext equivalence ──────────────────────────────────────

  group('E — resolveFromContext matches resolve', () {
    test('produces same result as resolve with matching inputs', () async {
      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();
      const testPPA = 42.0;

      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: ctx,
      );
      final direct = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        historicalWeeklyAvgCovers: ctx.historicalWeeklyAvgCovers,
      );

      expect(fromContext.forecastCovers, equals(direct.forecastCovers));
      expect(fromContext.forecastSales, equals(direct.forecastSales));
      expect(fromContext.coversSource, equals(direct.coversSource));
      expect(fromContext.salesSource, equals(direct.salesSource));
    });
  });

  // ── F. Schedule demand from context ────────────────────────────────────────

  group('F — Schedule demand from context + target PPA', () {
    test('covers and sales resolve correctly from context', () async {
      final ctx =
          await DemandForecastContextService.instance.getCurrentContext();
      const testPPA = 42.0;

      final demand = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: ctx,
      );

      if (ctx.isAvailable) {
        expect(demand.forecastCovers, equals(ctx.historicalWeeklyAvgCovers));
        expect(
          demand.forecastSales,
          closeTo(ctx.historicalWeeklyAvgCovers! * testPPA, 0.01),
        );
        expect(demand.coversSource,
            ForecastDemandSource.appDerivedFromHistoricalAverage);
        expect(demand.salesSource,
            ForecastDemandSource.appDerivedFromCoversAndPpa);
      } else {
        expect(demand.isAvailable, isFalse);
      }
    });
  });
}

/// Test-only date helper for independent verification.
String _subtractDays(String isoDate, int days) {
  final parts = isoDate.split('-');
  final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  final result = dt.subtract(Duration(days: days));
  return '${result.year}-${result.month.toString().padLeft(2, '0')}'
      '-${result.day.toString().padLeft(2, '0')}';
}
