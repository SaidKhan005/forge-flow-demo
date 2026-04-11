// ─── Schedule Forecast Demand Resolver Tests ─────────────────────────────────
// Phase 7.55c verification:
//   - Resolver waterfall: POS 60-day historical avg → demo fallback → unavailable
//   - Covers always from POS history; sales always derived as covers × PPA
//   - ScheduleForecastNotifier initializes from historical context, not hardcoded 1200

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/services/schedule_forecast_demand_resolver.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

void main() {
  const testPPA = 42.0;

  // ── A. Resolver waterfall ──────────────────────────────────────────────────

  group('A. Resolver waterfall', () {
    test('historical weekly average covers → derives covers and sales', () {
      final d = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        historicalWeeklyAvgCovers: 1200,
      );
      expect(d.forecastCovers, 1200);
      expect(d.forecastSales, 1200 * testPPA);
      expect(d.coversSource, ForecastDemandSource.appDerivedFromHistoricalAverage);
      expect(d.salesSource, ForecastDemandSource.appDerivedFromCoversAndPpa);
      expect(d.isAvailable, isTrue);
    });

    test('no historical — returns unavailable when demoMode false', () {
      final d = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        demoMode: false,
      );
      expect(d.forecastCovers, isNull);
      expect(d.forecastSales, isNull);
      expect(d.isAvailable, isFalse);
      expect(d.coversSource, ForecastDemandSource.unavailable);
      expect(d.salesSource, ForecastDemandSource.unavailable);
    });

    test('no historical — uses demo fallback when demoMode true', () {
      final d = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        demoMode: true,
        demoFallbackCovers: 1200,
      );
      expect(d.forecastCovers, 1200);
      expect(d.forecastSales, 1200 * testPPA);
      expect(d.coversSource, ForecastDemandSource.demoFallback);
      expect(d.isAvailable, isTrue);
    });

    test('zero historical covers — falls through to demo or unavailable', () {
      final d = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        historicalWeeklyAvgCovers: 0,
        demoMode: false,
      );
      expect(d.isAvailable, isFalse);
      expect(d.coversSource, ForecastDemandSource.unavailable);
    });

    test('sales is always covers × PPA (never independent)', () {
      final d = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        historicalWeeklyAvgCovers: 1066,
      );
      expect(d.forecastSales, 1066 * testPPA);
      expect(d.salesSource, ForecastDemandSource.appDerivedFromCoversAndPpa);
    });
  });

  // ── B. ScheduleForecastNotifier initialization ─────────────────────────────

  group('B. ScheduleForecastNotifier initialization', () {
    test('initializes from historical weekly average, not unexplained 1200', () {
      final histCovers = BaselineData.historicalWeeklyAvgCovers;
      expect(histCovers, isNot(equals(1200)));

      final notifier = ScheduleForecastNotifier(
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        targetSPLH: BaselineData.derivedTargetSPLH,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
        historicalWeeklyAvgCovers: histCovers,
      );
      expect(notifier.weeklyCovers, histCovers);
      expect(notifier.coversSource,
          ForecastDemandSource.appDerivedFromHistoricalAverage);
      expect(notifier.forecastSourceLabel, '60-day weekly average');
      notifier.dispose();
    });

  });

  // ── B2. resolveFromContext ─────────────────────────────────────────────────

  group('B2. resolveFromContext delegates to resolve correctly', () {
    test('available context produces same result as direct resolve', () {
      const ctx = DemandForecastContext(
        restaurantId: 'test',
        anchorBusinessDate: '2026-03-15',
        historicalTotalCovers: 9000,
        historicalWeeklyAvgCovers: 1050,
        weeksRepresented: 60 / 7,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: '2026-03-15T12:00:00',
      );

      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: ctx,
      );
      final direct = ScheduleForecastDemandResolver.resolve(
        targetPPA: testPPA,
        historicalWeeklyAvgCovers: 1050,
      );

      expect(fromContext.forecastCovers, equals(direct.forecastCovers));
      expect(fromContext.forecastSales, equals(direct.forecastSales));
      expect(fromContext.coversSource, equals(direct.coversSource));
    });

    test('unavailable context produces unavailable demand', () {
      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: DemandForecastContext.unavailable,
      );
      expect(fromContext.isAvailable, isFalse);
      expect(fromContext.coversSource, ForecastDemandSource.unavailable);
    });

    test('unavailable context with demoMode uses demo fallback', () {
      final fromContext = ScheduleForecastDemandResolver.resolveFromContext(
        targetPPA: testPPA,
        context: DemandForecastContext.unavailable,
        demoMode: true,
      );
      expect(fromContext.isAvailable, isTrue);
      expect(fromContext.coversSource, ForecastDemandSource.demoFallback);
      expect(fromContext.forecastCovers, 1200);
    });
  });

  // ── B3. updateDemandCovers — Schedule rebuild on demand changes ────────────

  group('B3. ScheduleForecastNotifier.updateDemandCovers', () {
    test('updates covers when demand context changes', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: testPPA,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        historicalWeeklyAvgCovers: 1000,
      );
      expect(notifier.weeklyCovers, 1000);

      notifier.updateDemandCovers(1200);
      expect(notifier.weeklyCovers, 1200);
      expect(notifier.forecastedSales, closeTo(1200 * testPPA, 0.01));
      notifier.dispose();
    });

    test('skips rebuild when covers unchanged', () {
      int changeCount = 0;
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: testPPA,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        historicalWeeklyAvgCovers: 1000,
      );
      notifier.addListener(() => changeCount++);

      notifier.updateDemandCovers(1000);
      expect(changeCount, 0); // no notification — same value
      notifier.dispose();
    });

    test('target updates still work alongside demand updates', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: testPPA,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        historicalWeeklyAvgCovers: null,
      );

      // Demand becomes available
      notifier.updateDemandCovers(1000);
      final fohBefore = notifier.requiredFohHours;

      // Target update changes FOH hours
      notifier.updateTargets(const ActiveTargetProfile(
        targetProfileId: 'test',
        restaurantId: 'test',
        sourceType: 'test',
        targetCPLH: 5.0,
        targetSPLH: 180.0,
        targetPPA: testPPA,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 5.5,
        theoreticalFohLaborPct: 12.0,
        theoreticalBohLaborPct: 9.0,
        theoreticalLaborPct: 21.0,
        builtAt: '2026-01-01',
      ));
      expect(notifier.requiredFohHours, isNot(equals(fohBefore)));
      notifier.dispose();
    });
  });

  // ── C. Source label rendering ──────────────────────────────────────────────

  group('C. ScheduleForecastDemand coversSourceLabel', () {
    test('all source labels are non-empty', () {
      for (final source in ForecastDemandSource.values) {
        final demand = ScheduleForecastDemand(
          forecastSales: null,
          forecastCovers: null,
          salesSource: source,
          coversSource: source,
        );
        expect(demand.coversSourceLabel, isNotEmpty);
      }
    });
  });
}
