// One normalized closed-daypart fact.
//
// Built from a ClosedShiftInput + a TargetSnapshot by ShiftFactBuilder.
// Every rate metric (ppa, cplh, splh, labor %) is a computed getter derived
// from raw source facts — nothing derived is stored as a field.
//
// No widget code. No database code.

import '../../services/labor_model.dart';
import 'target_snapshot.dart';

class ShiftFact {
  // ── Scope ────────────────────────────────────────────────────────────────

  final String restaurantId;

  // ── Identity ──────────────────────────────────────────────────────────────

  final DateTime businessDate;
  final String weekId;
  final String dayLabel;

  /// Service period: "lunch" | "dinner" | "late_night".
  final String daypart;

  // ── Volume source facts ───────────────────────────────────────────────────

  final int covers;
  final int forecastCovers;
  final double actualSales;

  // ── Hours source facts ────────────────────────────────────────────────────

  final int actualFohHours;
  final int actualBohHours;
  final int? scheduledFohHours;
  final int? scheduledBohHours;

  // ── Labor dollar source facts ─────────────────────────────────────────────
  // Always populated by ShiftFactBuilder (falls back to hours × wage when the
  // originating system does not supply dollar amounts directly).

  final double actualFohLaborDollars;
  final double actualBohLaborDollars;

  // ── Locked targets ────────────────────────────────────────────────────────

  final TargetSnapshot targetSnapshot;

  // ── Lever ─────────────────────────────────────────────────────────────────

  /// Normalized lowercase lever id returned by LaborModel.determineLever.
  /// Examples: "covers_down", "cplh_up", "ppa_down".
  final String primaryLeverId;

  // ── Provenance ────────────────────────────────────────────────────────────

  final String? sourceSystem;
  final String? sourceShiftId;

  const ShiftFact({
    this.restaurantId = 'demo_restaurant_001',
    required this.businessDate,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.covers,
    required this.forecastCovers,
    required this.actualSales,
    required this.actualFohHours,
    required this.actualBohHours,
    this.scheduledFohHours,
    this.scheduledBohHours,
    required this.actualFohLaborDollars,
    required this.actualBohLaborDollars,
    required this.targetSnapshot,
    required this.primaryLeverId,
    this.sourceSystem,
    this.sourceShiftId,
  });

  // ── Rate metrics — always derived from raw source facts ───────────────────

  /// Price per cover = actualSales ÷ covers (Jim Taylor Ch. 5).
  double get ppa => covers > 0 ? actualSales / covers : 0;

  /// Covers per FOH labor hour (Jim Taylor Ch. 5).
  double get cplh => actualFohHours > 0 ? covers / actualFohHours : 0;

  /// Sales per BOH labor hour (Jim Taylor Ch. 5).
  double get splh => actualBohHours > 0 ? actualSales / actualBohHours : 0;

  // ── Labor dollars ─────────────────────────────────────────────────────────

  double get totalLaborDollars => actualFohLaborDollars + actualBohLaborDollars;

  // ── Labor % — actual ──────────────────────────────────────────────────────

  double get actualFohLaborPct =>
      actualSales > 0 ? actualFohLaborDollars / actualSales * 100 : 0;

  double get actualBohLaborPct =>
      actualSales > 0 ? actualBohLaborDollars / actualSales * 100 : 0;

  double get actualLaborPct =>
      actualSales > 0 ? totalLaborDollars / actualSales * 100 : 0;

  // ── Model hours — what the labor model says you should have used ──────────

  int get modelFohHours =>
      LaborModel.modelFohHours(covers, targetSnapshot.targetCPLH);

  int get modelBohHours =>
      LaborModel.modelBohHours(covers, ppa, targetSnapshot.targetSPLH);

  // ── Dollar gap (Jim Taylor Ch. 10) ───────────────────────────────────────
  // Positive = over model (unfavorable). Negative = under model (favorable).

  double get dollarGap => LaborModel.dollarGap(
        totalLaborDollars,
        covers,
        ppa,
        targetCPLH: targetSnapshot.targetCPLH,
        targetSPLH: targetSnapshot.targetSPLH,
        fohWage: targetSnapshot.fohWage,
        bohWage: targetSnapshot.bohWage,
      );

  // ── Schedule variance hours ───────────────────────────────────────────────

  /// Actual FOH hours minus scheduled FOH hours. Null when schedule is absent.
  int? get fohScheduledVarianceHours =>
      scheduledFohHours != null ? actualFohHours - scheduledFohHours! : null;

  /// Actual BOH hours minus scheduled BOH hours. Null when schedule is absent.
  int? get bohScheduledVarianceHours =>
      scheduledBohHours != null ? actualBohHours - scheduledBohHours! : null;
}
