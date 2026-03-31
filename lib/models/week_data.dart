// ─── WeekData — WTD aggregation layer ────────────────────────────────────────
// In-memory aggregation of closed shift records for one calendar week.
// Created by ShiftService.getWeekToDate(). Consumed by VarianceReport.
//
// All computed getters derive from raw fields — no business logic in the UI.
// Target/theoretical fields are explicitly injected by the caller.

import '../services/labor_model.dart';

class WeekData {
  // ── Raw fields (aggregated from closed ShiftRecords) ─────────────────────
  final String weekId;
  final String weekLabel;
  final int totalCovers;
  final double totalSales;
  final int totalFohHours;
  final int totalBohHours;
  final int shiftsCompleted;
  final int shiftsTotal;
  final int wtdForecastCovers;
  final int totalWeekForecastCovers;
  final String primaryLeverId;
  final String lastClosedDay;
  final int closedDayNumber;

  // ── Stored aggregate labor dollars (Phase 3 addition) ────────────────────
  final double? storedTotalFohLaborDollar;
  final double? storedTotalBohLaborDollar;

  // ── Explicit active target fields (required) ─────────────────────────────
  final double _targetCPLH;
  final double _targetSPLH;
  final double _targetPPA;
  final double _targetFohWage;
  final double _targetBohWage;
  final double _theoreticalFohLaborPct;
  final double _theoreticalBohLaborPct;
  final double _theoreticalLaborPct;

  WeekData({
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
    this.lastClosedDay = 'Monday',
    this.closedDayNumber = 1,
    this.storedTotalFohLaborDollar,
    this.storedTotalBohLaborDollar,
    required double targetCPLH,
    required double targetSPLH,
    required double targetPPA,
    required double targetFohWage,
    required double targetBohWage,
    required double theoreticalFohLaborPct,
    required double theoreticalBohLaborPct,
    required double theoreticalLaborPct,
  })  : _targetCPLH = targetCPLH,
        _targetSPLH = targetSPLH,
        _targetPPA = targetPPA,
        _targetFohWage = targetFohWage,
        _targetBohWage = targetBohWage,
        _theoreticalFohLaborPct = theoreticalFohLaborPct,
        _theoreticalBohLaborPct = theoreticalBohLaborPct,
        _theoreticalLaborPct = theoreticalLaborPct;

  // ── Aggregate labor dollars ───────────────────────────────────────────────
  double get totalFohLaborDollar =>
      storedTotalFohLaborDollar ?? totalFohHours * _targetFohWage;

  double get totalBohLaborDollar =>
      storedTotalBohLaborDollar ?? totalBohHours * _targetBohWage;

  double get totalLaborDollar => totalFohLaborDollar + totalBohLaborDollar;

  // ── Rate metrics ──────────────────────────────────────────────────────────
  double get avgPPA => totalCovers > 0 ? totalSales / totalCovers : 0;
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

  // ── Target getters ────────────────────────────────────────────────────────
  double get targetPPA => _targetPPA;
  double get targetCPLH => _targetCPLH;
  double get targetSPLH => _targetSPLH;

  // ── Labor % — theoretical ─────────────────────────────────────────────────
  double get theoreticalLaborPct => _theoreticalLaborPct;
  double get theoreticalFohLaborPct => _theoreticalFohLaborPct;
  double get theoreticalBohLaborPct => _theoreticalBohLaborPct;
  double get variancePts => actualLaborPct - theoreticalLaborPct;

  // ── Model hours for actual volume (Jim Taylor Ch. 10) ─────────────────────
  int get modelFohHoursWtd =>
      LaborModel.modelFohHours(totalCovers, _targetCPLH);
  int get modelBohHoursWtd =>
      LaborModel.modelBohHours(totalCovers, avgPPA, _targetSPLH);

  // ── Dollar gap ────────────────────────────────────────────────────────────
  double get dollarGap => LaborModel.dollarGap(
        totalLaborDollar,
        totalCovers,
        avgPPA,
        targetCPLH: _targetCPLH,
        targetSPLH: _targetSPLH,
        fohWage: _targetFohWage,
        bohWage: _targetBohWage,
      );

  double get dollarGapAnnualized => dollarGap * 52;

  // ── Projected end-of-week ─────────────────────────────────────────────────
  int get remainingForecastCovers {
    final r = totalWeekForecastCovers - wtdForecastCovers;
    return r < 0 ? 0 : r;
  }

  double get projectedRemainingShiftSales =>
      remainingForecastCovers * _targetPPA;
  double get projTotalSales => totalSales + projectedRemainingShiftSales;
  int get projTotalCovers => totalCovers + remainingForecastCovers;
  double get projRemainingLaborDollar =>
      projectedRemainingShiftSales * theoreticalLaborPct / 100;
  double get projTotalLaborDollar =>
      totalLaborDollar + projRemainingLaborDollar;
  double get projActualLaborPct =>
      projTotalSales > 0 ? projTotalLaborDollar / projTotalSales * 100 : 0;
  double get projTargetLaborPct => theoreticalLaborPct;
  double get projVariancePts => projActualLaborPct - projTargetLaborPct;

  double get projDollarGapWeekly {
    final blendedPPA = projTotalCovers > 0
        ? projTotalSales / projTotalCovers
        : _targetPPA;
    return LaborModel.dollarGap(
      projTotalLaborDollar,
      projTotalCovers,
      blendedPPA,
      targetCPLH: _targetCPLH,
      targetSPLH: _targetSPLH,
      fohWage: _targetFohWage,
      bohWage: _targetBohWage,
    );
  }

  // ── Theoretical blended wage ──────────────────────────────────────────────
  double get theoreticalBlendedWage {
    final theoFoh = modelFohHoursWtd;
    final theoBoh = modelBohHoursWtd;
    final totalModelHours = theoFoh + theoBoh;
    if (totalModelHours == 0) return 0;
    return (theoFoh * _targetFohWage + theoBoh * _targetBohWage) /
        totalModelHours;
  }
}
