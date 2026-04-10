// ─── Schedule Forecast Demand Resolver Tests ─────────────────────────────────
// Phase 7.55c verification:
//   - Resolver waterfall: POS 60-day historical avg → demo fallback → unavailable
//   - Covers always from POS history; sales always derived as covers × PPA
//   - ScheduleForecastNotifier initializes from historical context, not hardcoded 1200

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
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
        theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
        initialCovers: histCovers,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      );
      expect(notifier.weeklyCovers, histCovers);
      expect(notifier.coversSource,
          ForecastDemandSource.appDerivedFromHistoricalAverage);
      expect(notifier.forecastSourceLabel, '60-day weekly average');
      notifier.dispose();
    });

    test('forecastSourceLabel reflects demo fallback when used', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.5,
        targetPPA: testPPA,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
        theoreticalLaborPct: 20.6,
        coversSource: ForecastDemandSource.demoFallback,
      );
      expect(notifier.forecastSourceLabel, 'Demo fallback');
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
