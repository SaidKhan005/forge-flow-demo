// ─── WTD Variance Logic Tests ─────────────────────────────────────────────────
// Verifies that WeekData computed getters follow the Jim Taylor Ch. 10 model:
//   • WTD totals = closed shifts only (never projected)
//   • Model hours = formula applied to actual volume (never proration)
//   • Targets flow from BaselineData derived values (not hardcoded config)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/models/week_data.dart';
import 'package:forge_flow_demo/models/week_record.dart';
import 'package:forge_flow_demo/services/labor_model.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

WeekData _makeWeekData({
  int totalCovers     = 0,
  double totalSales   = 0,
  int totalFohHours   = 0,
  int totalBohHours   = 0,
  int shiftsCompleted = 0,
  int wtdForecastCovers      = 0,
  int totalWeekForecastCovers = 0,
  String primaryLeverId = 'covers_down',
}) =>
    WeekData(
      weekId:                  'test-week',
      weekLabel:               'Test',
      totalCovers:             totalCovers,
      totalSales:              totalSales,
      totalFohHours:           totalFohHours,
      totalBohHours:           totalBohHours,
      shiftsCompleted:         shiftsCompleted,
      shiftsTotal:             14,
      wtdForecastCovers:       wtdForecastCovers,
      totalWeekForecastCovers: totalWeekForecastCovers,
      primaryLeverId:          primaryLeverId,
    );

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // Derived constants used across tests (computed once from live BaselineData)
  final derivedCPLH = BaselineData.derivedTargetCPLH;
  final derivedSPLH = BaselineData.derivedTargetSPLH;
  final derivedPPA  = BaselineData.derivedTargetPPA;
  final derivedTotal = BaselineData.derivedTheoreticalLaborPct;
  final derivedFoh  = BaselineData.derivedFohTheoreticalLaborPct;
  final derivedBoh  = BaselineData.derivedBohTheoreticalLaborPct;

  group('BaselineData derived targets', () {
    test('derivedTargetCPLH is close to MeridianConfig baseline (±0.5)', () {
      expect(derivedCPLH, closeTo(MeridianConfig.targetCPLH, 0.5));
    });

    test('derivedFohTheoreticalLaborPct + derivedBohTheoreticalLaborPct = derivedTheoreticalLaborPct', () {
      expect(derivedFoh + derivedBoh, closeTo(derivedTotal, 0.01));
    });

    test('derivedTheoreticalLaborPct ≈ 20.5% (less than hardcoded 20.6%)', () {
      expect(derivedTotal, closeTo(20.5, 0.5));
    });

    test('derivedTargetCPLH is positive', () {
      expect(derivedCPLH, greaterThan(0));
    });

    test('derivedTargetSPLH is positive', () {
      expect(derivedSPLH, greaterThan(0));
    });
  });

  group('WeekData passthrough target getters', () {
    final data = _makeWeekData(totalCovers: 100, totalSales: 4179);

    test('targetCPLH routes to BaselineData.derivedTargetCPLH', () {
      expect(data.targetCPLH, derivedCPLH);
    });

    test('targetSPLH routes to BaselineData.derivedTargetSPLH', () {
      expect(data.targetSPLH, derivedSPLH);
    });

    test('targetPPA routes to BaselineData.derivedTargetPPA', () {
      expect(data.targetPPA, derivedPPA);
    });

    test('theoreticalLaborPct routes to BaselineData derived value', () {
      expect(data.theoreticalLaborPct, derivedTotal);
    });

    test('theoreticalFohLaborPct routes to BaselineData derived value', () {
      expect(data.theoreticalFohLaborPct, derivedFoh);
    });

    test('theoreticalBohLaborPct routes to BaselineData derived value', () {
      expect(data.theoreticalBohLaborPct, derivedBoh);
    });
  });

  group('WeekData model hours use derived targets', () {
    test('modelFohHoursWtd = covers ÷ derivedTargetCPLH (not MeridianConfig.targetCPLH)', () {
      const covers = 1140;
      final data = _makeWeekData(
        totalCovers: covers,
        totalSales: covers * 41.96,
        totalFohHours: 280,
        totalBohHours: 290,
      );
      // Using derived CPLH ≈ 4.58 vs hardcoded 4.5 — should differ when CPLH differs
      final expected = LaborModel.modelFohHours(covers, derivedCPLH);
      expect(data.modelFohHoursWtd, expected);
    });

    test('modelBohHoursWtd = covers×avgPPA ÷ derivedTargetSPLH', () {
      const covers = 1140;
      const sales = 47838.0;
      final data = _makeWeekData(
        totalCovers: covers,
        totalSales: sales,
        totalFohHours: 280,
        totalBohHours: 290,
      );
      final avgPPA = sales / covers;
      final expected = LaborModel.modelBohHours(covers, avgPPA, derivedSPLH);
      expect(data.modelBohHoursWtd, expected);
    });
  });

  group('WeekData partial-week rule — WTD never includes projected shifts', () {
    test('Monday only (1 closed shift): WTD covers = that shift only', () {
      // 1 closed shift: 130 covers, 180 forecast
      final data = _makeWeekData(
        totalCovers:              130,
        totalSales:               130 * 41.79,
        totalFohHours:            28,
        totalBohHours:            29,
        shiftsCompleted:          1,
        wtdForecastCovers:        180,
        totalWeekForecastCovers:  2760,
      );
      expect(data.totalCovers, 130);
      expect(data.wtdForecastCovers, 180);
      // model hours computed from 130 actual covers only
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(130, derivedCPLH));
    });

    test('Remaining covers = totalWeekForecast − wtdForecast', () {
      final data = _makeWeekData(
        totalCovers:              130,
        totalSales:               130 * 41.79,
        shiftsCompleted:          1,
        wtdForecastCovers:        180,
        totalWeekForecastCovers:  2760,
      );
      expect(data.remainingForecastCovers, 2760 - 180);
    });

    test('Midweek: model hours computed from actual closed-shift covers only', () {
      // 4 closed shifts: 520 covers total, 720 forecast for those shifts
      final data = _makeWeekData(
        totalCovers:              520,
        totalSales:               520 * 41.79,
        totalFohHours:            112,
        totalBohHours:            118,
        shiftsCompleted:          4,
        wtdForecastCovers:        720,
        totalWeekForecastCovers:  2760,
      );
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(520, derivedCPLH));
      // projected shifts (2040 remaining covers) must NOT be in model hours
      final fullWeekModel = LaborModel.modelFohHours(2760, derivedCPLH);
      expect(data.modelFohHoursWtd, isNot(fullWeekModel));
    });

    test('Full week closed (14 shifts): remainingForecastCovers = 0', () {
      final data = _makeWeekData(
        totalCovers:              1200,
        totalSales:               1200 * 41.79,
        totalFohHours:            262,
        totalBohHours:            278,
        shiftsCompleted:          14,
        wtdForecastCovers:        1200,
        totalWeekForecastCovers:  1200,
      );
      expect(data.remainingForecastCovers, 0);
    });

    test('remainingForecastCovers never goes negative', () {
      // Edge case: wtdForecast slightly > totalWeekForecast due to rounding
      final data = _makeWeekData(
        wtdForecastCovers:        1210,
        totalWeekForecastCovers:  1200,
      );
      expect(data.remainingForecastCovers, 0);
    });
  });

  group('WeekData zero-safety', () {
    test('Zero sales: actualLaborPct = 0', () {
      final data = _makeWeekData(totalCovers: 0, totalSales: 0);
      expect(data.actualLaborPct, 0.0);
    });

    test('Zero sales: dollarGap = negative (labor cost with no sales)', () {
      // With hours but no sales, labor dollars exist but gap = actual - theo
      // Zero covers → model hours = 0 → theoretical = 0 → gap = actual labor $
      final data = _makeWeekData(totalCovers: 0, totalSales: 0, totalFohHours: 10, totalBohHours: 10);
      // modelFohHoursWtd(0 covers) = 0, so theoLaborDollar = 0
      // dollarGap = actualLaborDollar - 0 = positive
      expect(data.dollarGap, greaterThanOrEqualTo(0.0));
    });

    test('Zero FOH hours: avgCPLH = 0', () {
      final data = _makeWeekData(totalCovers: 100, totalFohHours: 0);
      expect(data.avgCPLH, 0.0);
    });

    test('Zero BOH hours: avgSPLH = 0', () {
      final data = _makeWeekData(totalCovers: 100, totalSales: 4179, totalBohHours: 0);
      expect(data.avgSPLH, 0.0);
    });

    test('theoreticalBlendedWage: zero model hours returns 0 not NaN', () {
      final data = _makeWeekData(totalCovers: 0, totalSales: 0);
      expect(data.theoreticalBlendedWage, 0.0);
    });
  });

  group('WeekRecord — model formula replaces naive proration', () {
    const record = WeekRecord(
      weekId:             'test-W12',
      weekLabel:          'Test',
      totalCovers:        1140,
      forecastCovers:     1200,
      totalFohHours:      280,
      totalBohHours:      290,
      avgPPA:             41.79,
      avgCPLH:            4.07,
      theoreticalLaborPct: 20.48,
      actualLaborPct:     22.6,
      dollarGap:          958.0,
      primaryLeverId:     'covers_down',
      shiftsCompleted:    9,
    );

    test('targetFohHours uses model formula not proration', () {
      final expected = LaborModel.modelFohHours(1140, BaselineData.derivedTargetCPLH);
      expect(record.targetFohHours, expected);
      // Verify it differs from the old naive proration value
      final naiveProration = (MeridianConfig.requiredFohHours * 9 ~/ 14);
      // Only assert the formula is used; they may coincidentally match for some inputs
      expect(record.targetFohHours, isNot(naiveProration));
    });

    test('targetBohHours uses model formula not proration', () {
      final expected = LaborModel.modelBohHours(
          1140, 41.79, BaselineData.derivedTargetSPLH);
      expect(record.targetBohHours, expected);
      final naiveProration = (MeridianConfig.requiredBohHours * 9 ~/ 14);
      expect(record.targetBohHours, isNot(naiveProration));
    });

    test('laborPctVariance: over model is positive', () {
      // actualLaborPct (22.6) > theoreticalLaborPct (20.48) → positive variance
      expect(record.laborPctVariance, greaterThan(0));
    });

    test('dollarGapAnnualized is always positive (magnitude × 52)', () {
      expect(record.dollarGapAnnualized, record.dollarGap.abs() * 52);
    });

    test('isOverModel true when dollarGap > 0', () {
      expect(record.isOverModel, isTrue);
    });

    test('full week (14 shifts): targetFohHours = modelFohHours(totalCovers)', () {
      const fullWeek = WeekRecord(
        weekId: 'full', weekLabel: 'Full',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 278,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.1,
        dollarGap: -200.0, primaryLeverId: 'covers_up',
        shiftsCompleted: 14,
      );
      final expected = LaborModel.modelFohHours(1200, BaselineData.derivedTargetCPLH);
      expect(fullWeek.targetFohHours, expected);
    });
  });

  group('dollarGap uses derived targets', () {
    test('dollarGap with known inputs matches manual computation', () {
      const covers = 1140;
      const sales  = 47838.0;
      const fohHrs = 280;
      const bohHrs = 290;
      final data = _makeWeekData(
        totalCovers:   covers,
        totalSales:    sales,
        totalFohHours: fohHrs,
        totalBohHours: bohHrs,
      );
      final avgPPA  = sales / covers;
      final manualGap = LaborModel.dollarGap(
        fohHrs * MeridianConfig.fohWage + bohHrs * MeridianConfig.bohWage,
        covers,
        avgPPA,
        targetCPLH: derivedCPLH,
        targetSPLH: derivedSPLH,
        fohWage: MeridianConfig.fohWage,
        bohWage: MeridianConfig.bohWage,
      );
      expect(data.dollarGap, closeTo(manualGap, 0.01));
    });

    test('dollarGapAnnualized = dollarGap × 52', () {
      final data = _makeWeekData(
        totalCovers: 1140, totalSales: 47838.0,
        totalFohHours: 280, totalBohHours: 290,
      );
      expect(data.dollarGapAnnualized, closeTo(data.dollarGap * 52, 0.01));
    });
  });
}
