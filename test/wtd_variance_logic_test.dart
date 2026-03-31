// â”€â”€â”€ WTD Variance Logic Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Verifies that WeekData computed getters follow the Jim Taylor Ch. 10 model:
//   â€¢ WTD totals = closed shifts only (never projected)
//   â€¢ Model hours = formula applied to actual volume (never proration)
//   â€¢ Targets flow from explicitly injected values (not current globals)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// â”€â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

// Capture current BaselineData values once for use as explicit test inputs.
final _testCPLH = BaselineData.derivedTargetCPLH;
final _testSPLH = BaselineData.derivedTargetSPLH;
final _testPPA = BaselineData.derivedTargetPPA;
final _testFohWage = MeridianConfig.fohWage;
final _testBohWage = MeridianConfig.bohWage;
final _testTheoFoh = BaselineData.derivedFohTheoreticalLaborPct;
final _testTheoBoh = BaselineData.derivedBohTheoreticalLaborPct;
final _testTheoTotal = BaselineData.derivedTheoreticalLaborPct;

WeekData _makeWeekData({
  int totalCovers     = 0,
  double totalSales   = 0,
  int totalFohHours   = 0,
  int totalBohHours   = 0,
  int shiftsCompleted = 0,
  int wtdForecastCovers      = 0,
  int totalWeekForecastCovers = 0,
  String primaryLeverId = 'covers_down',
  double? targetCPLH,
  double? targetSPLH,
  double? targetPPA,
  double? targetFohWage,
  double? targetBohWage,
  double? theoreticalFohLaborPct,
  double? theoreticalBohLaborPct,
  double? theoreticalLaborPct,
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
      targetCPLH:              targetCPLH ?? _testCPLH,
      targetSPLH:              targetSPLH ?? _testSPLH,
      targetPPA:               targetPPA ?? _testPPA,
      targetFohWage:           targetFohWage ?? _testFohWage,
      targetBohWage:           targetBohWage ?? _testBohWage,
      theoreticalFohLaborPct:  theoreticalFohLaborPct ?? _testTheoFoh,
      theoreticalBohLaborPct:  theoreticalBohLaborPct ?? _testTheoBoh,
      theoreticalLaborPct:     theoreticalLaborPct ?? _testTheoTotal,
    );

// â”€â”€â”€ Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

void main() {
  final derivedCPLH = _testCPLH;
  final derivedSPLH = _testSPLH;
  final derivedPPA  = _testPPA;
  final derivedTotal = _testTheoTotal;
  final derivedFoh  = _testTheoFoh;
  final derivedBoh  = _testTheoBoh;

  group('BaselineData derived targets', () {
    test('derivedTargetCPLH is close to MeridianConfig baseline (Â±0.5)', () {
      expect(derivedCPLH, closeTo(MeridianConfig.targetCPLH, 0.5));
    });

    test('derivedFohTheoreticalLaborPct + derivedBohTheoreticalLaborPct = derivedTheoreticalLaborPct', () {
      expect(derivedFoh + derivedBoh, closeTo(derivedTotal, 0.01));
    });

    test('derivedTheoreticalLaborPct â‰ˆ 20.5% (less than hardcoded 20.6%)', () {
      expect(derivedTotal, closeTo(20.5, 0.5));
    });

    test('derivedTargetCPLH is positive', () {
      expect(derivedCPLH, greaterThan(0));
    });

    test('derivedTargetSPLH is positive', () {
      expect(derivedSPLH, greaterThan(0));
    });
  });

  group('WeekData target getters use explicit injected fields', () {
    final data = _makeWeekData(totalCovers: 100, totalSales: 4179);

    test('targetCPLH matches explicitly supplied value', () {
      expect(data.targetCPLH, derivedCPLH);
    });

    test('targetSPLH matches explicitly supplied value', () {
      expect(data.targetSPLH, derivedSPLH);
    });

    test('targetPPA matches explicitly supplied value', () {
      expect(data.targetPPA, derivedPPA);
    });

    test('theoreticalLaborPct matches explicitly supplied value', () {
      expect(data.theoreticalLaborPct, derivedTotal);
    });

    test('explicit target fields are used exactly', () {
      final custom = _makeWeekData(
        totalCovers: 100, totalSales: 4179,
        totalFohHours: 20, totalBohHours: 25,
        targetCPLH: 5.0,
        targetSPLH: 200.0,
        targetPPA: 45.0,
        theoreticalLaborPct: 19.0,
      );
      expect(custom.targetCPLH, 5.0);
      expect(custom.targetSPLH, 200.0);
      expect(custom.targetPPA, 45.0);
      expect(custom.theoreticalLaborPct, 19.0);
    });
  });

  group('WeekData model hours use injected targets', () {
    test('modelFohHoursWtd = covers Ã· injected targetCPLH', () {
      const covers = 1140;
      final data = _makeWeekData(
        totalCovers: covers,
        totalSales: covers * 41.96,
        totalFohHours: 280,
        totalBohHours: 290,
      );
      final expected = LaborModel.modelFohHours(covers, derivedCPLH);
      expect(data.modelFohHoursWtd, expected);
    });

    test('modelBohHoursWtd = coversÃ—avgPPA Ã· injected targetSPLH', () {
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

  group('WeekData partial-week rule â€” WTD never includes projected shifts', () {
    test('Monday only (1 closed shift): WTD covers = that shift only', () {
      final data = _makeWeekData(
        totalCovers: 130, totalSales: 130 * 41.79,
        totalFohHours: 28, totalBohHours: 29,
        shiftsCompleted: 1,
        wtdForecastCovers: 180, totalWeekForecastCovers: 2760,
      );
      expect(data.totalCovers, 130);
      expect(data.wtdForecastCovers, 180);
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(130, derivedCPLH));
    });

    test('Remaining covers = totalWeekForecast âˆ’ wtdForecast', () {
      final data = _makeWeekData(
        totalCovers: 130, totalSales: 130 * 41.79,
        shiftsCompleted: 1,
        wtdForecastCovers: 180, totalWeekForecastCovers: 2760,
      );
      expect(data.remainingForecastCovers, 2760 - 180);
    });

    test('Midweek: model hours computed from actual closed-shift covers only', () {
      final data = _makeWeekData(
        totalCovers: 520, totalSales: 520 * 41.79,
        totalFohHours: 112, totalBohHours: 118,
        shiftsCompleted: 4,
        wtdForecastCovers: 720, totalWeekForecastCovers: 2760,
      );
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(520, derivedCPLH));
      final fullWeekModel = LaborModel.modelFohHours(2760, derivedCPLH);
      expect(data.modelFohHoursWtd, isNot(fullWeekModel));
    });

    test('Full week closed (14 shifts): remainingForecastCovers = 0', () {
      final data = _makeWeekData(
        totalCovers: 1200, totalSales: 1200 * 41.79,
        totalFohHours: 262, totalBohHours: 278,
        shiftsCompleted: 14,
        wtdForecastCovers: 1200, totalWeekForecastCovers: 1200,
      );
      expect(data.remainingForecastCovers, 0);
    });

    test('remainingForecastCovers never goes negative', () {
      final data = _makeWeekData(
        wtdForecastCovers: 1210, totalWeekForecastCovers: 1200,
      );
      expect(data.remainingForecastCovers, 0);
    });
  });

  group('WeekData zero-safety', () {
    test('Zero sales: actualLaborPct = 0', () {
      final data = _makeWeekData(totalCovers: 0, totalSales: 0);
      expect(data.actualLaborPct, 0.0);
    });

    test('Zero sales: dollarGap = non-negative (labor cost with no sales)', () {
      final data = _makeWeekData(totalCovers: 0, totalSales: 0, totalFohHours: 10, totalBohHours: 10);
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

  group('WeekRecord â€” model formula replaces naive proration', () {
    final record = WeekRecord(
      weekId: 'test-W12', weekLabel: 'Test',
      totalCovers: 1140, forecastCovers: 1200,
      totalFohHours: 280, totalBohHours: 290,
      avgPPA: 41.79, avgCPLH: 4.07,
      theoreticalLaborPct: 20.48, actualLaborPct: 22.6,
      dollarGap: 958.0, primaryLeverId: 'covers_down',
      shiftsCompleted: 9,
      targetCPLH: derivedCPLH,
      targetSPLH: derivedSPLH,
      targetPPA: derivedPPA,
      targetFohWage: _testFohWage,
      targetBohWage: _testBohWage,
    );

    test('targetFohHours uses model formula not proration', () {
      final expected = LaborModel.modelFohHours(1140, derivedCPLH);
      expect(record.targetFohHours, expected);
      final naiveProration = (MeridianConfig.requiredFohHours * 9 ~/ 14);
      expect(record.targetFohHours, isNot(naiveProration));
    });

    test('targetBohHours uses model formula not proration', () {
      final expected = LaborModel.modelBohHours(1140, 41.79, derivedSPLH);
      expect(record.targetBohHours, expected);
      final naiveProration = (MeridianConfig.requiredBohHours * 9 ~/ 14);
      expect(record.targetBohHours, isNot(naiveProration));
    });

    test('laborPctVariance: over model is positive', () {
      expect(record.laborPctVariance, greaterThan(0));
    });

    test('dollarGapAnnualized is always positive (magnitude Ã— 52)', () {
      expect(record.dollarGapAnnualized, record.dollarGap.abs() * 52);
    });

    test('isOverModel true when dollarGap > 0', () {
      expect(record.isOverModel, isTrue);
    });

    test('full week (14 shifts): targetFohHours = modelFohHours(totalCovers)', () {
      final fullWeek = WeekRecord(
        weekId: 'full', weekLabel: 'Full',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 278,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.1,
        dollarGap: -200.0, primaryLeverId: 'covers_up',
        shiftsCompleted: 14,
        targetCPLH: derivedCPLH,
        targetSPLH: derivedSPLH,
        targetPPA: derivedPPA,
        targetFohWage: _testFohWage,
        targetBohWage: _testBohWage,
      );
      final expected = LaborModel.modelFohHours(1200, derivedCPLH);
      expect(fullWeek.targetFohHours, expected);
    });
  });

  group('dollarGap uses injected targets', () {
    test('dollarGap with known inputs matches manual computation', () {
      const covers = 1140;
      const sales  = 47838.0;
      const fohHrs = 280;
      const bohHrs = 290;
      final data = _makeWeekData(
        totalCovers: covers, totalSales: sales,
        totalFohHours: fohHrs, totalBohHours: bohHrs,
      );
      final avgPPA = sales / covers;
      final manualGap = LaborModel.dollarGap(
        fohHrs * _testFohWage + bohHrs * _testBohWage,
        covers, avgPPA,
        targetCPLH: derivedCPLH,
        targetSPLH: derivedSPLH,
        fohWage: _testFohWage,
        bohWage: _testBohWage,
      );
      expect(data.dollarGap, closeTo(manualGap, 0.01));
    });

    test('dollarGapAnnualized = dollarGap Ã— 52', () {
      final data = _makeWeekData(
        totalCovers: 1140, totalSales: 47838.0,
        totalFohHours: 280, totalBohHours: 290,
      );
      expect(data.dollarGapAnnualized, closeTo(data.dollarGap * 52, 0.01));
    });
  });
}
