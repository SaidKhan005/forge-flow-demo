// ─── WeekData — WTD aggregation layer ────────────────────────────────────────
// In-memory aggregation of closed shift records for one calendar week.
// Created by ShiftService.getWeekToDate(). Consumed by VarianceReport.
//
// All computed getters derive from raw fields — no business logic in the UI.
// Target/theoretical fields are explicitly injected by the caller.
//
// Phase 7.55q.3: `theoreticalBlendedWage` no longer derives a separate
// hour-weighted value from `targetFohHoursWtd` / `targetBohHoursWtd` —
// it now reads from the shared
// `ActiveTargetProfile.computeTargetBlendedWage(...)` seam so WTD and
// Benchmark cannot drift on the same active target state.

import '../domain/models/active_target_profile.dart';
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
  final String? lastClosedBusinessDate;

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

  // ── Plan-to-date hours (locked snapshot truth when available) ──────────
  final int? planFohHoursWtd;
  final int? planBohHoursWtd;

  // ── Dollar Impact accumulation windows (7.55p.3) ─────────────────────
  // Closed-truth accumulation through the latest closed business date.
  // Populated by ShiftService from date-range queries; null when
  // unavailable (non-locked path or insufficient history).
  final double? monthDollarImpact;
  final double? sixtyDayDollarImpact;

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
    this.lastClosedBusinessDate,
    this.storedTotalFohLaborDollar,
    this.storedTotalBohLaborDollar,
    this.planFohHoursWtd,
    this.planBohHoursWtd,
    this.monthDollarImpact,
    this.sixtyDayDollarImpact,
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
  double get totalFohLaborDollar => storedTotalFohLaborDollar ?? 0;

  double get totalBohLaborDollar => storedTotalBohLaborDollar ?? 0;

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

  // ── Target hours for WTD variance (plan-aligned) ─────────────────────────
  // 7.55q follow-up: for current-week Variance, FOH/BOH target hours must
  // come from the locked weekly plan only. When plan hours are absent, WTD
  // should degrade honestly rather than silently falling back to model hours.
  int? get targetFohHoursWtd => planFohHoursWtd;
  int? get targetBohHoursWtd => planBohHoursWtd;

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

  // ── Annualized dollar impact from 60-day accumulation (7.55p.3) ──────
  // Formula: (60-day impact / 60) × 365.
  // Null when 60-day data is unavailable — no fallback to weekly × 52.
  double? get annualizedDollarImpact =>
      sixtyDayDollarImpact != null
          ? sixtyDayDollarImpact! * (365.0 / 60)
          : null;

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
  // 7.55q.3: reads from the shared
  // `ActiveTargetProfile.computeTargetBlendedWage(...)` seam — the same
  // formula Benchmark consumes via `profile.targetBlendedWage`. WTD and
  // Benchmark therefore produce the identical blended-wage number for
  // the same active target state; per-surface drift is impossible by
  // construction.
  //
  // The previous plan-hour-weighted derivation (using `targetFohHoursWtd`
  // / `targetBohHoursWtd`) violated `7.55q.1` Rule 2: blended wage is a
  // Benchmark-owned target metric, not a plan-execution metric.
  double get theoreticalBlendedWage =>
      ActiveTargetProfile.computeTargetBlendedWage(
        targetCPLH: _targetCPLH,
        targetSPLH: _targetSPLH,
        targetPPA: _targetPPA,
        fohWage: _targetFohWage,
        bohWage: _targetBohWage,
      );
}
