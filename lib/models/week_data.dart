// ─── WeekData — WTD aggregation layer ────────────────────────────────────────
// In-memory aggregation of closed shift records for one calendar week.
// Created by ShiftService.getWeekToDate(). Consumed by VarianceReport.
//
// All computed getters derive from raw fields — no business logic in the UI.
// Replaces WeekToDate static constants in VarianceReport._ThisWeekTab.

import '../data/meridian_data.dart';
import '../services/labor_model.dart';

class WeekData {
  // ── Raw fields (aggregated from closed ShiftRecords) ─────────────────────
  final String weekId;
  final String weekLabel;
  final int totalCovers;
  final double totalSales;
  final int totalFohHours;
  final int totalBohHours;
  final int shiftsCompleted;         // closed shifts so far
  final int shiftsTotal;             // total shifts in a full week
  final int wtdForecastCovers;       // sum of forecastCovers for closed shifts
  final int totalWeekForecastCovers; // sum of forecastCovers for ALL shifts in week
  final String primaryLeverId;       // from LaborModel.determineLever
  final String lastClosedDay;        // full day name, e.g. 'Friday'
  final int    closedDayNumber;      // Mon=1, Tue=2, …, Fri=5, Sat=6, Sun=7

  // ── Stored aggregate labor dollars (Phase 3 addition) ────────────────────
  // Summed from closed ShiftRecord.fohLaborDollar / bohLaborDollar.
  // When absent, getters fall back to hours × config wage.
  final double? storedTotalFohLaborDollar;
  final double? storedTotalBohLaborDollar;

  const WeekData({
    required this.weekId,
    required this.weekLabel,
    required this.totalCovers,
    required this.totalSales,
    required this.totalFohHours,
    required this.totalBohHours,
    required this.shiftsCompleted,
    required this.shiftsTotal,
    required this.wtdForecastCovers,
    required this.totalWeekForecastCovers,
    required this.primaryLeverId,
    this.lastClosedDay   = 'Monday',
    this.closedDayNumber = 1,
    this.storedTotalFohLaborDollar,
    this.storedTotalBohLaborDollar,
  });

  // ── Aggregate labor dollars — stored source facts with config-wage fallback
  double get totalFohLaborDollar =>
      storedTotalFohLaborDollar ?? totalFohHours * MeridianConfig.fohWage;

  double get totalBohLaborDollar =>
      storedTotalBohLaborDollar ?? totalBohHours * MeridianConfig.bohWage;

  double get totalLaborDollar => totalFohLaborDollar + totalBohLaborDollar;

  // ── Rate metrics ──────────────────────────────────────────────────────────
  double get avgPPA  => totalCovers > 0 ? totalSales / totalCovers : 0;
  double get avgCPLH => totalFohHours > 0 ? totalCovers / totalFohHours : 0;
  double get avgSPLH => totalBohHours > 0 ? totalSales / totalBohHours : 0;

  double get avgBlendedWage {
    final totalHours = totalFohHours + totalBohHours;
    return totalHours > 0 ? totalLaborDollar / totalHours : 0;
  }

  // ── Labor % — actual ─────────────────────────────────────────────────────
  double get actualLaborPct =>
      totalSales > 0 ? totalLaborDollar / totalSales * 100 : 0;

  double get actualFohLaborPct =>
      totalSales > 0 ? totalFohLaborDollar / totalSales * 100 : 0;

  double get actualBohLaborPct =>
      totalSales > 0 ? totalBohLaborDollar / totalSales * 100 : 0;

  // ── Passthrough targets — callers never import BaselineData or MeridianConfig
  double get targetPPA  => BaselineData.derivedTargetPPA;
  double get targetCPLH => BaselineData.derivedTargetCPLH;
  double get targetSPLH => BaselineData.derivedTargetSPLH;

  // ── Labor % — theoretical ─────────────────────────────────────────────────
  double get theoreticalLaborPct    => BaselineData.derivedTheoreticalLaborPct;
  double get theoreticalFohLaborPct => BaselineData.derivedFohTheoreticalLaborPct;
  double get theoreticalBohLaborPct => BaselineData.derivedBohTheoreticalLaborPct;
  double get variancePts => actualLaborPct - theoreticalLaborPct;

  // ── Model hours for actual volume (Jim Taylor Ch. 10) ─────────────────────
  int get modelFohHoursWtd =>
      LaborModel.modelFohHours(totalCovers, BaselineData.derivedTargetCPLH);

  int get modelBohHoursWtd =>
      LaborModel.modelBohHours(totalCovers, avgPPA, BaselineData.derivedTargetSPLH);

  // ── Dollar gap ────────────────────────────────────────────────────────────
  double get dollarGap => LaborModel.dollarGap(
    totalLaborDollar,
    totalCovers,
    avgPPA,
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetSPLH: BaselineData.derivedTargetSPLH,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
  );

  double get dollarGapAnnualized => dollarGap * 52;

  // ── Projected end-of-week ─────────────────────────────────────────────────
  // Remaining shifts are assumed to run at theoretical labor %.
  // This gives managers a realistic full-week projection from mid-week.

  int get remainingForecastCovers {
    final r = totalWeekForecastCovers - wtdForecastCovers;
    return r < 0 ? 0 : r;
  }

  double get projectedRemainingShiftSales =>
      remainingForecastCovers * BaselineData.derivedTargetPPA;

  double get projTotalSales => totalSales + projectedRemainingShiftSales;

  int get projTotalCovers => totalCovers + remainingForecastCovers;

  double get projRemainingLaborDollar =>
      projectedRemainingShiftSales * theoreticalLaborPct / 100;

  double get projTotalLaborDollar => totalLaborDollar + projRemainingLaborDollar;

  double get projActualLaborPct =>
      projTotalSales > 0 ? projTotalLaborDollar / projTotalSales * 100 : 0;

  double get projTargetLaborPct => theoreticalLaborPct;

  double get projVariancePts => projActualLaborPct - projTargetLaborPct;

  double get projDollarGapWeekly {
    final blendedPPA = projTotalCovers > 0
        ? projTotalSales / projTotalCovers
        : BaselineData.derivedTargetPPA;
    return LaborModel.dollarGap(
      projTotalLaborDollar,
      projTotalCovers,
      blendedPPA,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
    );
  }

  // ── Theoretical blended wage ──────────────────────────────────────────────
  // Model labor $ / model total hours for actual volume.
  double get theoreticalBlendedWage {
    final theoFoh = modelFohHoursWtd;
    final theoBoh = modelBohHoursWtd;
    final totalModelHours = theoFoh + theoBoh;
    if (totalModelHours == 0) return 0;
    return (theoFoh * MeridianConfig.fohWage +
            theoBoh * MeridianConfig.bohWage) /
        totalModelHours;
  }
}
