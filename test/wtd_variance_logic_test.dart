// ——— WTD Variance Logic Tests ———————————————————————————————————————————————
// Verifies that WeekData computed getters follow the Jim Taylor Ch. 10 model:
//   • WTD totals = closed shifts only (never projected)
//   • Model hours = formula applied to actual volume (never proration)
//   • Targets flow from explicitly injected values (not current globals)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/labor_model.dart';

// ——— Helpers ————————————————————————————————————————————————————————————————

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

// ——— Tests ——————————————————————————————————————————————————————————————————

void main() {
  final derivedCPLH = _testCPLH;
  final derivedSPLH = _testSPLH;
  final derivedTotal = _testTheoTotal;
  final derivedFoh  = _testTheoFoh;
  final derivedBoh  = _testTheoBoh;

  group('BaselineData derived targets', () {
    test('derived targets are positive, close to config, and decompose correctly', () {
      expect(derivedCPLH, greaterThan(0));
      expect(derivedSPLH, greaterThan(0));
      expect(derivedCPLH, closeTo(MeridianConfig.targetCPLH, 0.5));
      expect(derivedTotal, closeTo(20.5, 0.5));
      expect(derivedFoh + derivedBoh, closeTo(derivedTotal, 0.01));
    });
  });

  group('WeekData target getters use explicit injected fields', () {
    test('default and custom target fields are used exactly as injected', () {
      final data = _makeWeekData(totalCovers: 100, totalSales: 4179);
      expect(data.targetCPLH, derivedCPLH);
      expect(data.targetSPLH, derivedSPLH);
      expect(data.targetPPA, _testPPA);
      expect(data.theoreticalLaborPct, derivedTotal);

      final custom = _makeWeekData(
        totalCovers: 100, totalSales: 4179,
        totalFohHours: 20, totalBohHours: 25,
        targetCPLH: 5.0, targetSPLH: 200.0,
        targetPPA: 45.0, theoreticalLaborPct: 19.0,
      );
      expect(custom.targetCPLH, 5.0);
      expect(custom.targetSPLH, 200.0);
      expect(custom.targetPPA, 45.0);
      expect(custom.theoreticalLaborPct, 19.0);
    });
  });

  group('WeekData model hours use injected targets', () {
    test('FOH and BOH model hours use injected targets, not globals', () {
      const covers = 1140;
      const sales = 47838.0;
      final data = _makeWeekData(
        totalCovers: covers, totalSales: sales,
        totalFohHours: 280, totalBohHours: 290,
      );
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(covers, derivedCPLH));
      final avgPPA = sales / covers;
      expect(data.modelBohHoursWtd, LaborModel.modelBohHours(covers, avgPPA, derivedSPLH));
    });
  });

  group('WeekData partial-week rule — WTD never includes projected shifts', () {
    test('Monday only: WTD = that shift; remaining covers computed', () {
      final data = _makeWeekData(
        totalCovers: 130, totalSales: 130 * 41.79,
        totalFohHours: 28, totalBohHours: 29,
        shiftsCompleted: 1,
        wtdForecastCovers: 180, totalWeekForecastCovers: 2760,
      );
      expect(data.totalCovers, 130);
      expect(data.wtdForecastCovers, 180);
      expect(data.remainingForecastCovers, 2760 - 180);
      expect(data.modelFohHoursWtd, LaborModel.modelFohHours(130, derivedCPLH));
    });

    test('midweek uses actual closed-shift covers; full week has 0 remaining', () {
      final mid = _makeWeekData(
        totalCovers: 520, totalSales: 520 * 41.79,
        totalFohHours: 112, totalBohHours: 118,
        shiftsCompleted: 4,
        wtdForecastCovers: 720, totalWeekForecastCovers: 2760,
      );
      expect(mid.modelFohHoursWtd, LaborModel.modelFohHours(520, derivedCPLH));
      expect(mid.modelFohHoursWtd, isNot(LaborModel.modelFohHours(2760, derivedCPLH)));

      final full = _makeWeekData(
        totalCovers: 1200, totalSales: 1200 * 41.79,
        shiftsCompleted: 14,
        wtdForecastCovers: 1200, totalWeekForecastCovers: 1200,
      );
      expect(full.remainingForecastCovers, 0);

      // Never negative
      final over = _makeWeekData(wtdForecastCovers: 1210, totalWeekForecastCovers: 1200);
      expect(over.remainingForecastCovers, 0);
    });
  });

  group('WeekData BOH model hours use actual sales, not target PPA (7.55d.3a)', () {
    test('modelBohHoursWtd is derived from actual sales, not target PPA', () {
      final data = _makeWeekData(
        totalCovers: 100, totalSales: 4000.0,
        totalFohHours: 20, totalBohHours: 20,
        targetPPA: 50.0, targetSPLH: 200.0,
      );
      expect(data.modelBohHoursWtd, LaborModel.modelBohHoursFromSales(4000.0, 200.0));
      expect(data.modelBohHoursWtd, isNot(LaborModel.modelBohHours(100, 50.0, 200.0)));
    });

    test('changing target PPA does not change modelBohHoursWtd when sales unchanged', () {
      final lowPPA = _makeWeekData(
        totalCovers: 100, totalSales: 4000.0,
        totalFohHours: 20, totalBohHours: 20,
        targetPPA: 35.0, targetSPLH: 200.0,
      );
      final highPPA = _makeWeekData(
        totalCovers: 100, totalSales: 4000.0,
        totalFohHours: 20, totalBohHours: 20,
        targetPPA: 55.0, targetSPLH: 200.0,
      );
      expect(lowPPA.modelBohHoursWtd, highPPA.modelBohHoursWtd);
    });
  });

  group('WeekData zero-safety', () {
    test('zero inputs produce safe defaults, not NaN or division errors', () {
      final noSales = _makeWeekData(totalCovers: 0, totalSales: 0);
      expect(noSales.actualLaborPct, 0.0);
      expect(noSales.theoreticalBlendedWage, 0.0);

      final withHours = _makeWeekData(
        totalCovers: 0, totalSales: 0,
        totalFohHours: 10, totalBohHours: 10,
      );
      expect(withHours.dollarGap, greaterThanOrEqualTo(0.0));

      expect(_makeWeekData(totalCovers: 100, totalFohHours: 0).avgCPLH, 0.0);
      expect(_makeWeekData(totalCovers: 100, totalSales: 4179, totalBohHours: 0).avgSPLH, 0.0);
    });
  });

  group('WeekRecord — model formula replaces naive proration', () {
    final record = WeekRecord(
      weekId: 'test-W12', weekLabel: 'Test',
      totalCovers: 1140, forecastCovers: 1200,
      totalFohHours: 280, totalBohHours: 290,
      avgPPA: 41.79, avgCPLH: 4.07,
      theoreticalLaborPct: 20.48, actualLaborPct: 22.6,
      dollarGap: 958.0, primaryLeverId: 'covers_down',
      shiftsCompleted: 9,
      targetCPLH: derivedCPLH, targetSPLH: derivedSPLH,
      targetPPA: _testPPA,
      targetFohWage: _testFohWage, targetBohWage: _testBohWage,
    );

    test('target hours use model formula, not proration; variance/gap correct', () {
      expect(record.targetFohHours, LaborModel.modelFohHours(1140, derivedCPLH));
      expect(record.targetFohHours, isNot(MeridianConfig.requiredFohHours * 9 ~/ 14));
      expect(record.targetBohHours, LaborModel.modelBohHours(1140, 41.79, derivedSPLH));
      expect(record.targetBohHours, isNot(MeridianConfig.requiredBohHours * 9 ~/ 14));
      expect(record.laborPctVariance, greaterThan(0));
      expect(record.dollarGapAnnualized, record.dollarGap.abs() * 52);
      expect(record.isOverModel, isTrue);
    });

    test('full week: targetFohHours = modelFohHours(totalCovers)', () {
      final fullWeek = WeekRecord(
        weekId: 'full', weekLabel: 'Full',
        totalCovers: 1200, forecastCovers: 1200,
        totalFohHours: 262, totalBohHours: 278,
        avgPPA: 41.79, avgCPLH: 4.58,
        theoreticalLaborPct: 20.48, actualLaborPct: 20.1,
        dollarGap: -200.0, primaryLeverId: 'covers_up',
        shiftsCompleted: 14,
        targetCPLH: derivedCPLH, targetSPLH: derivedSPLH,
        targetPPA: _testPPA,
        targetFohWage: _testFohWage, targetBohWage: _testBohWage,
      );
      expect(fullWeek.targetFohHours, LaborModel.modelFohHours(1200, derivedCPLH));
    });
  });

  group('dollarGap uses injected targets', () {
    test('dollarGap and annualized match manual computation', () {
      const covers = 1140;
      const sales  = 47838.0;
      const fohHrs = 280;
      const bohHrs = 290;
      final data = _makeWeekData(
        totalCovers: covers, totalSales: sales,
        totalFohHours: fohHrs, totalBohHours: bohHrs,
      );
      final manualGap = LaborModel.dollarGap(
        fohHrs * _testFohWage + bohHrs * _testBohWage,
        covers, sales / covers,
        targetCPLH: derivedCPLH, targetSPLH: derivedSPLH,
        fohWage: _testFohWage, bohWage: _testBohWage,
      );
      expect(data.dollarGap, closeTo(manualGap, 0.01));
      expect(data.dollarGapAnnualized, closeTo(data.dollarGap * 52, 0.01));
    });
  });

  // ── ShiftRecord actual-volume model hours (Phase 7.55d.3b) ──────────────

  group('ShiftRecord model-hour getters use actual volume, not forecast/target PPA', () {
    test('modelFohHours uses actual covers; modelBohHours uses actual sales; target PPA irrelevant', () {
      final s = ShiftRecord(
        weekId: 'test', dayLabel: 'Mon', daypart: 'lunch',
        status: 'closed',
        covers: 100, forecastCovers: 120,
        ppa: 40.0, cplh: 5.0, splh: 200.0,
        fohHours: 22, bohHours: 22,
        primaryLever: 'COVERS_DOWN',
        targetCPLH: 5.0, targetSPLH: 200.0, targetPPA: 50.0,
        targetFohWage: 16.50, targetBohWage: 21.35,
        theoreticalFohLaborPct: 10.0, theoreticalBohLaborPct: 10.0,
      );
      // FOH: actual-volume 100/5=20, not forecast 120/5=24
      expect(s.modelFohHours, 20);
      expect(s.modelFohHours, isNot(LaborModel.modelFohHours(120, 5.0)));
      // BOH: actual-sales 4000/200=20, not forecast×targetPPA 120×50/200=30
      expect(s.modelBohHours, 20);
      expect(s.modelBohHours, isNot(LaborModel.modelBohHours(120, 50.0, 200.0)));

      // Changing target PPA doesn't change BOH model hours
      ShiftRecord makeWithPPA(double tPPA) => ShiftRecord(
        weekId: 'test', dayLabel: 'Mon', daypart: 'lunch', status: 'closed',
        covers: 100, forecastCovers: 120,
        ppa: 40.0, cplh: 5.0, splh: 200.0,
        fohHours: 22, bohHours: 22,
        primaryLever: 'COVERS_DOWN',
        targetCPLH: 5.0, targetSPLH: 200.0, targetPPA: tPPA,
        targetFohWage: 16.50, targetBohWage: 21.35,
        theoreticalFohLaborPct: 10.0, theoreticalBohLaborPct: 10.0,
      );
      expect(makeWithPPA(35.0).modelBohHours, makeWithPPA(55.0).modelBohHours);
    });
  });

  // ── StaticShiftDataSource locked-target backfill (Phase 7.55d.3c) ────────

  group('StaticShiftDataSource locked-target backfill', () {
    test('closed shifts have readable locked target getters and model hours', () async {
      final shifts = await const StaticShiftDataSource().getFullWeekShifts('2026-W13');
      final closed = shifts.where((s) => s.isClosed).toList();
      expect(closed, isNotEmpty);

      for (final s in closed) {
        expect(s.lockedTargetCPLH, greaterThan(0));
        expect(s.lockedTargetSPLH, greaterThan(0));
        expect(s.lockedTargetPPA, greaterThan(0));
        expect(s.lockedTargetFohWage, greaterThan(0));
        expect(s.lockedTargetBohWage, greaterThan(0));
        expect(s.modelFohHours, greaterThanOrEqualTo(0));
        expect(s.modelBohHours, greaterThanOrEqualTo(0));
      }
    });

    test('backfill uses MeridianConfig, not mutable BaselineData derived targets', () async {
      final shifts = await const StaticShiftDataSource().getFullWeekShifts('2026-W13');
      final closed = shifts.firstWhere((s) => s.isClosed);

      final preCPLH = closed.lockedTargetCPLH;
      final preSPLH = closed.lockedTargetSPLH;
      final prePPA = closed.lockedTargetPPA;

      BaselineData.applyManagerOverride([
        DaypartBaseline(daypart: 'lunch', cplh: 99.0, splh: 999.0, ppa: 999.0, covers: 1),
        DaypartBaseline(daypart: 'dinner', cplh: 99.0, splh: 999.0, ppa: 999.0, covers: 1),
      ]);

      try {
        final after = await const StaticShiftDataSource().getFullWeekShifts('2026-W13');
        final closedAfter = after.firstWhere(
            (s) => s.isClosed && s.dayLabel == closed.dayLabel && s.daypart == closed.daypart);

        expect(closedAfter.lockedTargetCPLH, preCPLH);
        expect(closedAfter.lockedTargetSPLH, preSPLH);
        expect(closedAfter.lockedTargetPPA, prePPA);
        expect(closedAfter.lockedTargetCPLH, MeridianConfig.targetCPLH);
        expect(closedAfter.lockedTargetSPLH, MeridianConfig.targetSPLH);
        expect(closedAfter.lockedTargetPPA, MeridianConfig.targetPPA);
      } finally {
        BaselineData.clearManagerOverride();
      }
    });
  });
}
