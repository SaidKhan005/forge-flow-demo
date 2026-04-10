// Builds a ShiftFact from a ClosedShiftInput + a TargetSnapshot.
//
// Pure and deterministic — no I/O, no side effects.
// The close-shift ingest path (Phase 3) will call this after assembling a
// ClosedShiftInput and locking a TargetSnapshot at shift-close time.

import '../../services/labor_model.dart';
import '../models/closed_shift_input.dart';
import '../models/shift_fact.dart';
import '../models/target_snapshot.dart';

class ShiftFactBuilder {
  ShiftFactBuilder._();

  /// Builds a [ShiftFact] from raw [input] and locked [targetSnapshot].
  ///
  /// Labor dollar resolution:
  /// - Uses [input.actualFohLaborDollars] when provided by the labor system.
  /// - Falls back to [input.actualFohHours] × [targetSnapshot.fohWage] when absent.
  /// Same rule applies for BOH.
  static ShiftFact fromClosedShiftInput(
    ClosedShiftInput input,
    TargetSnapshot targetSnapshot,
  ) {
    // ── Resolve labor dollars ─────────────────────────────────────────────
    final resolvedFohLaborDollars = input.actualFohLaborDollars ??
        input.actualFohHours * targetSnapshot.fohWage;

    final resolvedBohLaborDollars = input.actualBohLaborDollars ??
        input.actualBohHours * targetSnapshot.bohWage;

    // ── Derive rate metrics needed for lever detection ────────────────────
    final totalHoursFoh = input.actualFohHours;
    final totalHoursBoh = input.actualBohHours;

    final ppa = input.covers > 0 ? input.actualSales / input.covers : 0.0;
    final cplh = totalHoursFoh > 0 ? input.covers / totalHoursFoh : 0.0;
    final splh = totalHoursBoh > 0 ? input.actualSales / totalHoursBoh : 0.0;

    // Blended wages for lever detection (null when hours are zero to skip
    // the wage-lever family rather than produce a meaningless ratio).
    final avgFohBlendedWage = totalHoursFoh > 0
        ? resolvedFohLaborDollars / totalHoursFoh
        : null;
    final avgBohBlendedWage = totalHoursBoh > 0
        ? resolvedBohLaborDollars / totalHoursBoh
        : null;

    // ── Determine primary lever ───────────────────────────────────────────
    final modelFoh = LaborModel.modelFohHours(input.covers, targetSnapshot.targetCPLH);
    final modelBoh = LaborModel.modelBohHoursFromSales(input.actualSales, targetSnapshot.targetSPLH);

    final primaryLeverId = LaborModel.determineLever(
      actualCovers: input.covers,
      forecastCovers: input.forecastCovers,
      avgCPLH: cplh,
      avgPPA: ppa,
      targetCPLH: targetSnapshot.targetCPLH,
      targetPPA: targetSnapshot.targetPPA,
      avgSPLH: splh,
      targetSPLH: targetSnapshot.targetSPLH,
      avgFohBlendedWage: avgFohBlendedWage,
      targetFohWage: targetSnapshot.fohWage,
      avgBohBlendedWage: avgBohBlendedWage,
      targetBohWage: targetSnapshot.bohWage,
      scheduledFohHours: input.scheduledFohHours,
      modelFohHours: modelFoh,
      scheduledBohHours: input.scheduledBohHours,
      modelBohHours: modelBoh,
    );

    return ShiftFact(
      restaurantId: input.restaurantId,
      businessDate: input.businessDate,
      weekId: input.weekId,
      dayLabel: input.dayLabel,
      daypart: input.daypart,
      covers: input.covers,
      forecastCovers: input.forecastCovers,
      actualSales: input.actualSales,
      actualFohHours: input.actualFohHours,
      actualBohHours: input.actualBohHours,
      scheduledFohHours: input.scheduledFohHours,
      scheduledBohHours: input.scheduledBohHours,
      actualFohLaborDollars: resolvedFohLaborDollars,
      actualBohLaborDollars: resolvedBohLaborDollars,
      targetSnapshot: targetSnapshot,
      primaryLeverId: primaryLeverId,
      sourceSystem: input.sourceSystem,
      sourceShiftId: input.sourceShiftId,
    );
  }
}
