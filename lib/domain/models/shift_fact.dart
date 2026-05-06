// One normalized closed-daypart fact.
//
// Built from a ClosedShiftInput + a TargetSnapshot by ShiftFactBuilder.
// Every rate metric (ppa, cplh, splh, labor %) is a computed getter derived
// from raw source facts — nothing derived is stored as a field.
//
// Phase 8.0 (V1 lean cut 2): MetricProvenance getters added per
// `docs/contracts/metric_card_honesty_contract.md`. The numeric
// fields stay; the new getters expose state + provenance so the
// renderer never produces a phantom zero.
//
// No widget code. No database code.

import '../../services/labor_model.dart';
import 'metric_provenance.dart';
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

  /// Timing profile used to bucket this closed row. Nullable for legacy rows.
  final String? businessTimingProfileId;

  /// Stable timing version key. Lane 0 maps this to the profile id for now.
  final String? businessTimingProfileVersionId;

  /// Stable service-period key captured at bucket time. Mutable labels are
  /// display only.
  final String? servicePeriodKey;

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

  /// V1 lean cut 2 (metric honesty). True when the vendor supplied
  /// actual labor dollars directly (e.g., POS export, scheduling
  /// vendor timecard); false when the builder fell back to
  /// `actualFohHours × targetSnapshot.fohWage` because the input
  /// did not provide direct dollars. Drives the `cplhProvenance` /
  /// `blendedWageProvenance` state per
  /// `docs/contracts/metric_card_honesty_contract.md`.
  final bool laborDollarsFromVendor;

  const ShiftFact({
    this.restaurantId = 'demo_restaurant_001',
    required this.businessDate,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    this.businessTimingProfileId,
    this.businessTimingProfileVersionId,
    this.servicePeriodKey,
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
    this.laborDollarsFromVendor = true,
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

  // ── MetricProvenance accessors (Phase 8.0 V1 lean cut 2) ─────────────────
  //
  // Per docs/contracts/metric_card_honesty_contract.md the renderer
  // consults `state` + `provenance` for every load-bearing metric
  // and renders `MetricCardNotYetAvailable` when `state ==
  // unavailable`. The contract forbids phantom zeroes — when an
  // input is missing the metric MUST resolve to `unavailable`,
  // never `0.0`.

  String get _vendorProvenance =>
      sourceSystem == null || sourceSystem!.trim().isEmpty
      ? 'vendor_unknown'
      : 'vendor_$sourceSystem';

  /// Covers state. `unavailable` when covers is zero AND the input
  /// did not declare a vendor (no source system) — that combination
  /// is the operator-invisible "no data" case. With a vendor declared
  /// and zero covers, treat as `live` (a real measured zero is honest).
  MetricProvenance get coversProvenance {
    if (covers <= 0 && (sourceSystem == null || sourceSystem!.trim().isEmpty)) {
      return const MetricProvenance.unavailable();
    }
    return MetricProvenance.live(value: covers, provenance: _vendorProvenance);
  }

  MetricProvenance get salesProvenance {
    if (actualSales <= 0 &&
        (sourceSystem == null || sourceSystem!.trim().isEmpty)) {
      return const MetricProvenance.unavailable();
    }
    return MetricProvenance.live(
      value: actualSales,
      provenance: _vendorProvenance,
    );
  }

  /// PPA = sales / covers. `unavailable` when covers is missing.
  MetricProvenance get ppaProvenance {
    if (covers <= 0) return const MetricProvenance.unavailable();
    return MetricProvenance.live(value: ppa, provenance: _vendorProvenance);
  }

  /// CPLH = covers / FOH hours. `unavailable` when FOH hours are
  /// missing OR labor dollars came from the wage*hours fallback
  /// (then the metric reflects the target wage, not real labor —
  /// see contract).
  MetricProvenance get cplhProvenance {
    if (actualFohHours <= 0) return const MetricProvenance.unavailable();
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: cplh,
        provenance: '${_vendorProvenance}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(value: cplh, provenance: _vendorProvenance);
  }

  /// SPLH = sales / BOH hours. Same `unavailable` pattern as CPLH.
  MetricProvenance get splhProvenance {
    if (actualBohHours <= 0) return const MetricProvenance.unavailable();
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: splh,
        provenance: '${_vendorProvenance}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(value: splh, provenance: _vendorProvenance);
  }

  /// Blended wage. `unavailable` when total hours are zero;
  /// `fallback` when labor dollars came from wage*hours; else
  /// `live`.
  MetricProvenance get blendedWageProvenance {
    final totalHours = actualFohHours + actualBohHours;
    if (totalHours <= 0) return const MetricProvenance.unavailable();
    final blended = totalLaborDollars / totalHours;
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: blended,
        provenance: '${_vendorProvenance}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(value: blended, provenance: _vendorProvenance);
  }
}
