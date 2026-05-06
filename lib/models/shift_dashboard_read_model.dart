/// Everything the Shift dashboard screen needs to render, built from
/// persisted current-state + active target profile + whole-day SchedulePlan.
library;

import 'package:flutter/foundation.dart';

import '../data/app_defaults.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/metric_provenance.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../services/labor_model.dart';

class ShiftDashboardReadModel {
  // ── Header context ──────────────────────────────────────────────────────
  final String daypart;
  final String day;
  final String businessDate;

  // Phase 7.55m.3: timeLabel and serviceElapsedLabel are no longer the
  // primary header time source. The Shift header now uses a live wall-clock
  // widget. These fields remain on the model to avoid broad churn across
  // test fixtures and the read-model builder. They may be removed when the
  // snapshot/read-model shape is next revised.
  final String timeLabel;
  final String serviceElapsedLabel;

  // ── Current shift actuals (closed + open running totals) ─────────────────
  final int actualCovers;
  final double actualSales;
  final double actualPPA;
  final int actualFohHours;
  final int actualBohHours;
  final double actualCPLH;
  final double actualSPLH;
  final double blendedWage;

  // ── Full-day scheduled hours (closed + open + projected staffing) ───────
  final int scheduledFohHours;
  final int scheduledBohHours;

  // ── Plan values from SchedulePlan day row ───────────────────────────────
  final int forecastCovers;
  final double forecastSales;
  final int planFohHours;
  final int planBohHours;

  // ── Active target profile ───────────────────────────────────────────────
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double fohWage;
  final double bohWage;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;

  // ── Computed ────────────────────────────────────────────────────────────
  final String primaryLeverId;
  final LeverCardData primaryLeverCard;
  final List<InputMetric> metricCards;
  final String opzStatus;
  final String opzLabel;
  final String opzSubLabel;

  // ── 7.58 depth wave (slice 10.5.6): cross-axis SPLH state ───────────────
  // [splhState] is `'below'` / `'on'` / `'above'` when BOH minutes are
  // logged, and null when BOH is not yet punched in. The `_OpzMatrixGrid`
  // widget renders 9 dim cells in the null case; the cross-axis sub-label
  // resolver falls back to the single-axis CPLH sentence when null.
  //
  // [currentSplh] / [targetSplh] mirror `actualSPLH` and `targetSPLH` as
  // standalone fields to keep the matrix widget input shape narrow and
  // honest about its derivation.
  final double currentSplh;
  final double targetSplh;
  final String? splhState;

  // ── Whole-day labor % ───────────────────────────────────────────────────
  // Planned labor package removed.
  // - `targetLaborPct` now sources from `profile.theoreticalLaborPct`
  //   (the current Benchmark target) via the constructor inputs below,
  //   not from a planned-package formula.
  // - `targetLaborDollars` was removed entirely — there is no honest
  //   theoretical dollar form at whole-day scope, and no consumer
  //   required it after `targetLaborPct` repointed to theoretical truth.
  final double actualLaborDollars;
  final double actualLaborPct;
  final double targetLaborPct;
  final double laborVariancePts;

  // ── Reservation book signal ─────────────────────────────────────────────
  final int? inTheBooksCovers;

  // ── Phase 8.0 V1 lean cut 2 — Vendor source provenance fields ───────────
  // Optional fields populated by Phase 8 read-model builders to name
  // the connected vendor in provenance strings. Demo paths leave
  // these null; the read-model getters fall through to
  // `MetricCardNotYetAvailable` when null.
  final String? _posSourceVendorId;
  final String? _laborSourceVendorId;
  final bool _laborDollarsFromVendor;

  // ── Derived ─────────────────────────────────────────────────────────────
  double get currentSales => actualSales;

  // ── Phase 8.0 V1 lean cut 2 — MetricProvenance accessors ────────────────
  //
  // Per docs/contracts/metric_card_honesty_contract.md. The renderer
  // (`shift_dashboard.dart` + variance tabs) consults state +
  // provenance for every load-bearing metric and renders
  // `MetricCardNotYetAvailable` when state == unavailable. The
  // existing numeric fields stay as the value carrier; these
  // getters expose state.

  /// Vendor identifier used in provenance strings. Resolves from
  /// the read model's wired data sources; defaults to
  /// `vendor_unknown` when the demo seed has no source declared.
  /// Production read-model builders should override via
  /// [posSourceVendorId] / [laborSourceVendorId] when wiring real
  /// adapters.
  String get _posVendor => posSourceVendorId ?? 'unknown';
  String get _laborVendor => laborSourceVendorId ?? 'unknown';

  /// Optional injection points so a wired Phase 8 adapter can name
  /// itself in provenance without changing the read-model
  /// constructor for legacy callers.
  String? get posSourceVendorId => _posSourceVendorId;
  String? get laborSourceVendorId => _laborSourceVendorId;

  /// Whether the labor read came from a connected vendor source
  /// (true) or from the wage*hours fallback (false). Defaults to
  /// `true` for backward compatibility with demo paths; production
  /// read-model builders can pass `false` when actuals are missing.
  bool get laborDollarsFromVendor => _laborDollarsFromVendor;

  /// Covers state — `unavailable` when neither actual covers nor a
  /// vendor source is wired. Renderer switches to
  /// `MetricCardNotYetAvailable` for unavailable.
  MetricProvenance get coversProvenance {
    if (actualCovers <= 0 && posSourceVendorId == null) {
      return const MetricProvenance.unavailable();
    }
    return MetricProvenance.live(
      value: actualCovers,
      provenance: 'vendor_$_posVendor',
    );
  }

  MetricProvenance get salesProvenance {
    if (actualSales <= 0 && posSourceVendorId == null) {
      return const MetricProvenance.unavailable();
    }
    return MetricProvenance.live(
      value: actualSales,
      provenance: 'vendor_$_posVendor',
    );
  }

  /// PPA — `unavailable` when covers are zero (no honest divisor).
  MetricProvenance get ppaProvenance {
    if (actualCovers <= 0) return const MetricProvenance.unavailable();
    return MetricProvenance.live(
      value: actualPPA,
      provenance: 'vendor_$_posVendor',
    );
  }

  /// CPLH — `unavailable` when no labor vendor connected OR actual
  /// FOH hours are zero. `fallback` when labor dollars came via
  /// wage*hours instead of vendor data.
  MetricProvenance get cplhProvenance {
    if (laborSourceVendorId == null || actualFohHours <= 0) {
      return const MetricProvenance.unavailable();
    }
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: actualCPLH,
        provenance: 'vendor_${_laborVendor}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(
      value: actualCPLH,
      provenance: 'vendor_$_laborVendor',
    );
  }

  /// SPLH — same `unavailable` / `fallback` rules as CPLH.
  MetricProvenance get splhProvenance {
    if (laborSourceVendorId == null || actualBohHours <= 0) {
      return const MetricProvenance.unavailable();
    }
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: actualSPLH,
        provenance: 'vendor_${_laborVendor}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(
      value: actualSPLH,
      provenance: 'vendor_$_laborVendor',
    );
  }

  /// Blended wage — `unavailable` when no labor vendor connected OR
  /// total hours are zero.
  MetricProvenance get blendedWageProvenance {
    if (laborSourceVendorId == null) {
      return const MetricProvenance.unavailable();
    }
    final totalHours = actualFohHours + actualBohHours;
    if (totalHours <= 0) return const MetricProvenance.unavailable();
    if (!laborDollarsFromVendor) {
      return MetricProvenance.fallback(
        value: blendedWage,
        provenance: 'vendor_${_laborVendor}_with_fallback_labor_dollars',
      );
    }
    return MetricProvenance.live(
      value: blendedWage,
      provenance: 'vendor_$_laborVendor',
    );
  }

  const ShiftDashboardReadModel({
    required this.daypart,
    required this.day,
    required this.businessDate,
    required this.timeLabel,
    required this.serviceElapsedLabel,
    required this.actualCovers,
    required this.actualSales,
    required this.actualPPA,
    required this.actualFohHours,
    required this.actualBohHours,
    required this.actualCPLH,
    required this.actualSPLH,
    required this.blendedWage,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.forecastCovers,
    required this.forecastSales,
    required this.planFohHours,
    required this.planBohHours,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.primaryLeverId,
    required this.primaryLeverCard,
    required this.metricCards,
    required this.opzStatus,
    required this.opzLabel,
    required this.opzSubLabel,
    required this.currentSplh,
    required this.targetSplh,
    this.splhState,
    required this.actualLaborDollars,
    required this.actualLaborPct,
    required this.targetLaborPct,
    required this.laborVariancePts,
    this.inTheBooksCovers,
    String? posSourceVendorId,
    String? laborSourceVendorId,
    bool laborDollarsFromVendor = true,
  }) : _posSourceVendorId = posSourceVendorId,
       _laborSourceVendorId = laborSourceVendorId,
       _laborDollarsFromVendor = laborDollarsFromVendor;

  /// Builds the read model from a single snapshot + active target profile.
  /// Used by tests and legacy paths. Plan values are derived from the snapshot.
  factory ShiftDashboardReadModel.build(
    OpenShiftSnapshot snapshot,
    ActiveTargetProfile profile, {
    int? inTheBooksCovers,
    String? posSourceVendorId,
    String? laborSourceVendorId,
    bool laborDollarsFromVendor = true,
  }) {
    final sales = snapshot.currentCovers * snapshot.currentPPA;
    return ShiftDashboardReadModel.buildWholeDay(
      snapshots: [snapshot],
      profile: profile,
      forecastCovers: snapshot.forecastCovers,
      forecastSales: snapshot.forecastCovers * profile.targetPPA,
      planFohHours: LaborModel.modelFohHours(
        snapshot.forecastCovers,
        profile.targetCPLH,
      ),
      planBohHours: LaborModel.modelBohHours(
        snapshot.forecastCovers,
        profile.targetPPA,
        profile.targetSPLH,
      ),
      inTheBooksCovers: inTheBooksCovers,
      actualCoversOverride: snapshot.currentCovers,
      actualSalesOverride: sales,
      posSourceVendorId: posSourceVendorId,
      laborSourceVendorId: laborSourceVendorId,
      laborDollarsFromVendor: laborDollarsFromVendor,
    );
  }

  /// Builds from whole-day aggregated snapshots + SchedulePlan day row.
  ///
  /// Plan-side values (forecastCovers, forecastSales, planFohHours, planBohHours)
  /// come from the SchedulePlan day row. Actual-side values are aggregated
  /// from closed + open snapshots (projected dayparts excluded from covers/sales).
  factory ShiftDashboardReadModel.buildWholeDay({
    required List<OpenShiftSnapshot> snapshots,
    required ActiveTargetProfile profile,
    required int forecastCovers,
    required double forecastSales,
    required int planFohHours,
    required int planBohHours,
    int? inTheBooksCovers,
    int? actualCoversOverride,
    double? actualSalesOverride,
    // Phase 8.0 V1 lean cut 2 — vendor source provenance.
    // Demo paths leave these null; production wiring populates
    // them from connector_connection.metadata.
    String? posSourceVendorId,
    String? laborSourceVendorId,
    bool laborDollarsFromVendor = true,
  }) {
    // Day label to full name
    const dayFull = {
      'Mon': 'Monday',
      'Tue': 'Tuesday',
      'Wed': 'Wednesday',
      'Thu': 'Thursday',
      'Fri': 'Friday',
      'Sat': 'Saturday',
      'Sun': 'Sunday',
    };

    // Use the open snapshot for time context, fall back to first
    final openSnap =
        snapshots.where((s) => s.status == 'open').firstOrNull ??
        snapshots.first;
    final dayName = dayFull[openSnap.dayLabel] ?? openSnap.dayLabel;

    // Aggregate actuals from closed + open snapshots (not projected)
    final actualSnapshots = snapshots
        .where((s) => s.status == 'closed' || s.status == 'open')
        .toList();

    final totalCovers =
        actualCoversOverride ??
        actualSnapshots.fold<int>(0, (s, r) => s + r.currentCovers);
    final totalSales =
        actualSalesOverride ??
        actualSnapshots.fold<double>(
          0,
          (s, r) => s + r.currentCovers * r.currentPPA,
        );
    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;

    // Actual-to-date hours: closed + open only (not projected future labor)
    final actFoh = actualSnapshots.fold<int>(
      0,
      (s, r) => s + r.scheduledFohHours,
    );
    final actBoh = actualSnapshots.fold<int>(
      0,
      (s, r) => s + r.scheduledBohHours,
    );

    // Full-day scheduled hours: closed + open + projected (staffing decisions)
    final totalFoh = snapshots.fold<int>(0, (s, r) => s + r.scheduledFohHours);
    final totalBoh = snapshots.fold<int>(0, (s, r) => s + r.scheduledBohHours);

    // Live productivity: actual covers/sales ÷ actual-to-date hours only
    final avgCPLH = actFoh > 0 ? totalCovers / actFoh : 0.0;
    final avgSPLH = actBoh > 0 ? totalSales / actBoh : 0.0;

    // Blended wage: weighted by actual-to-date hours (closed + open)
    final actualWageDollars = actualSnapshots.fold<double>(
      0,
      (s, r) => s + r.blendedWage * (r.scheduledFohHours + r.scheduledBohHours),
    );
    final actualTotalHours = actFoh + actBoh;
    final avgBlendedWage = actualTotalHours > 0
        ? actualWageDollars / actualTotalHours
        : 0.0;

    // Whole-day labor %.
    //
    // The target side is now THEORETICAL labor % from the
    // current Benchmark target object (profile.theoreticalLaborPct) —
    // the same value Benchmark/Variance non-closed surfaces show.
    // Previously this was a planned-package formula
    // `(planFohHours × fohWage + planBohHours × bohWage) / forecastSales`,
    // which we have killed (planned labor package is dead).
    //
    // The actual side stays as before: closed+open hours × blended wage
    // ÷ closed+open sales × 100.
    final computedActualLaborDollars =
        actualWageDollars; // already weighted sum of wage × hours
    final computedActualLaborPct = totalSales > 0
        ? computedActualLaborDollars / totalSales * 100
        : 0.0;
    final computedTargetLaborPct = profile.theoreticalLaborPct;
    final computedLaborVariancePts =
        computedActualLaborPct - computedTargetLaborPct;

    // Primary lever — whole-day current-state scope.
    // Uses actual-to-date productivity from closed + open snapshots, and
    // full-day scheduled hours vs plan hours. This can legitimately differ
    // from the Variance WTD lever (different aggregation window).
    // See phase_7_55m_4 audit doc.
    final leverId = LaborModel.determineLever(
      actualCovers: totalCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: profile.targetSPLH,
      scheduledFohHours: totalFoh,
      modelFohHours: planFohHours,
      scheduledBohHours: totalBoh,
      modelBohHours: planBohHours,
    );
    // 7.58.UX.5 (F-1): explicit lookup. The engine guarantees one of the
    // 16 known ids per R6 (`determineLever` never returns `on_model`), so
    // `lookup` is non-null in practice; the bang asserts that contract.
    // The previous silent `orElse: coversDown` would have hidden a
    // hypothetical R6 violation rather than surfacing it.
    final leverCard = LeverCards.lookup(leverId)!;

    // OPZ status
    final opzStatus = _computeOpzStatus(
      avgCPLH,
      profile.opzFloorCPLH,
      profile.opzCeilingCPLH,
    );
    final opzLabel = _computeOpzLabel(opzStatus);
    // 7.58 depth wave (slice 10.5.6): cross-axis SPLH state + sub-label.
    final splhState = _computeSplhState(
      actualBohHours: actBoh,
      actualSplh: avgSPLH,
      targetSplh: profile.targetSPLH,
    );
    final opzSubLabel = _computeOpzSubLabel(opzStatus, splhState);

    // Metric cards
    final cards = _buildMetricCards(
      actualCovers: totalCovers,
      actualSales: totalSales,
      actualPPA: avgPPA,
      actualCPLH: avgCPLH,
      actualSPLH: avgSPLH,
      blendedWage: avgBlendedWage,
      scheduledFohHours: totalFoh,
      scheduledBohHours: totalBoh,
      forecastCovers: forecastCovers,
      forecastSales: forecastSales,
      planFohHours: planFohHours,
      planBohHours: planBohHours,
      profile: profile,
      leverId: leverId,
      opzStatus: opzStatus,
      opzLabel: opzLabel,
      inTheBooksCovers: inTheBooksCovers,
    );

    return ShiftDashboardReadModel(
      daypart: snapshots.length > 1 ? '' : _daypartLabel(openSnap.daypart),
      day: dayName,
      businessDate: openSnap.businessDate,
      timeLabel: openSnap.timeLabel,
      serviceElapsedLabel: openSnap.serviceElapsedLabel,
      actualCovers: totalCovers,
      actualSales: totalSales,
      actualPPA: avgPPA,
      actualFohHours: actFoh,
      actualBohHours: actBoh,
      actualCPLH: avgCPLH,
      actualSPLH: avgSPLH,
      blendedWage: avgBlendedWage,
      scheduledFohHours: totalFoh,
      scheduledBohHours: totalBoh,
      forecastCovers: forecastCovers,
      forecastSales: forecastSales,
      planFohHours: planFohHours,
      planBohHours: planBohHours,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      primaryLeverId: leverId,
      primaryLeverCard: leverCard,
      metricCards: cards,
      opzStatus: opzStatus,
      opzLabel: opzLabel,
      opzSubLabel: opzSubLabel,
      currentSplh: avgSPLH,
      targetSplh: profile.targetSPLH,
      splhState: splhState,
      actualLaborDollars: computedActualLaborDollars,
      actualLaborPct: computedActualLaborPct,
      targetLaborPct: computedTargetLaborPct,
      laborVariancePts: computedLaborVariancePts,
      inTheBooksCovers: inTheBooksCovers,
      posSourceVendorId: posSourceVendorId,
      laborSourceVendorId: laborSourceVendorId,
      laborDollarsFromVendor: laborDollarsFromVendor,
    );
  }

  static String _daypartLabel(String daypart) {
    switch (daypart) {
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      case 'late_night':
        return 'Late Night';
      default:
        return daypart;
    }
  }

  // ── OPZ helpers ─────────────────────────────────────────────────────────

  static String _computeOpzStatus(
    double currentCplh,
    double floor,
    double ceiling,
  ) {
    if (currentCplh < floor) return 'below';
    if (currentCplh > ceiling) return 'above';
    return 'in';
  }

  static String _computeOpzLabel(String status) {
    switch (status) {
      case 'below':
        return 'BELOW OPZ';
      case 'above':
        return 'ABOVE OPZ';
      default:
        return 'IN OPZ';
    }
  }

  // 7.58 depth wave (slice 10.5.6): cross-axis SPLH state.
  //
  // BOH minutes that resolve to zero hours (or no BOH labor read at all)
  // mean the kitchen has not punched in yet, so this returns null. The
  // matrix grid then renders without an active marker and the sub-label
  // resolver falls back to the single-axis CPLH sentence. The +/- 5
  // percent tolerance mirrors the per-period driver threshold so the
  // two surfaces stay consistent.
  static const double _splhTolerance = 0.05;

  static String? _computeSplhState({
    required int actualBohHours,
    required double actualSplh,
    required double targetSplh,
  }) {
    if (actualBohHours <= 0) return null;
    if (targetSplh <= 0) return null;
    final double ratio = actualSplh / targetSplh;
    if (ratio < 1.0 - _splhTolerance) return 'below';
    if (ratio > 1.0 + _splhTolerance) return 'above';
    return 'on';
  }

  // 7.58 depth wave (slice 10.5.6): cross-axis sub-label resolver.
  //
  // Single-axis copy is preserved unchanged for the three cases where
  // SPLH state is absent or agrees with CPLH on the on-target reading.
  // Four cross-axis sentences swap in for the cells where the two axes
  // disagree, sourced from Jim Taylor labor-model deep dive ch. 7.
  static String _computeOpzSubLabel(String cplhStatus, [String? splhState]) {
    if (splhState != null) {
      if (cplhStatus == 'below' && splhState == 'above') {
        return 'Below OPZ floor. Team executed. Volume problem, not '
            'staffing. Fix the forecast.';
      }
      if (cplhStatus == 'above' && splhState == 'below') {
        return 'Above OPZ ceiling AND kitchen slowed. Pull ticket times '
            'before adding hours.';
      }
      if (cplhStatus == 'in' && splhState == 'below') {
        return 'In OPZ. PPA dropped. Watch upselling.';
      }
      if (cplhStatus == 'in' && splhState == 'above') {
        return 'In OPZ. Kitchen running strong. Document this shift.';
      }
    }
    switch (cplhStatus) {
      case 'below':
        return 'Productivity is below the OPZ floor. Too many labor '
            'hours for the volume.';
      case 'above':
        return 'Productivity is above the OPZ ceiling. Service quality '
            'may suffer.';
      default:
        return 'Team is producing. Watch covers.';
    }
  }

  /// Test-only accessor so the slice can pin every cell of the
  /// (cplhStatus, splhState) input space without relying on the full
  /// `buildWholeDay` path.
  @visibleForTesting
  static String computeOpzSubLabelForTest(
    String cplhStatus,
    String? splhState,
  ) => _computeOpzSubLabel(cplhStatus, splhState);

  /// Test-only accessor for the SPLH band classifier.
  @visibleForTesting
  static String? computeSplhStateForTest({
    required int actualBohHours,
    required double actualSplh,
    required double targetSplh,
  }) => _computeSplhState(
    actualBohHours: actualBohHours,
    actualSplh: actualSplh,
    targetSplh: targetSplh,
  );

  // ── Metric card builder ─────────────────────────────────────────────────

  static String _heroMetricNameForLever(String leverId) {
    if (leverId.startsWith('covers_')) return 'COVERS';
    if (leverId.startsWith('ppa_')) return 'PPA';
    if (leverId.startsWith('cplh_')) return 'CPLH';
    if (leverId.startsWith('splh_')) return 'SPLH';
    if (leverId.startsWith('foh_wage_') || leverId.startsWith('boh_wage_')) {
      return 'BLENDED WAGE';
    }
    return 'COVERS';
  }

  static List<InputMetric> _buildMetricCards({
    required int actualCovers,
    required double actualSales,
    required double actualPPA,
    required double actualCPLH,
    required double actualSPLH,
    required double blendedWage,
    required int scheduledFohHours,
    required int scheduledBohHours,
    required int forecastCovers,
    required double forecastSales,
    required int planFohHours,
    required int planBohHours,
    required ActiveTargetProfile profile,
    required String leverId,
    required String opzStatus,
    required String opzLabel,
    int? inTheBooksCovers,
  }) {
    final heroName = _heroMetricNameForLever(leverId);

    final coversDelta = actualCovers - forecastCovers;
    final coversUnfavorable = actualCovers < forecastCovers;
    final coversStatus = coversUnfavorable
        ? 'Light'
        : (actualCovers > forecastCovers ? 'Heavy' : 'On pace');

    final ppaDelta = actualPPA - profile.targetPPA;
    final ppaUnfavorable = actualPPA < profile.targetPPA;
    final ppaStatus = ppaUnfavorable
        ? 'Watch'
        : (actualPPA > profile.targetPPA ? 'Ahead' : 'On target');

    final cplhDelta = actualCPLH - profile.targetCPLH;
    final cplhUnfavorable = actualCPLH < profile.targetCPLH;
    String cplhStatus;
    switch (opzLabel) {
      case 'BELOW OPZ':
        cplhStatus = 'Below OPZ';
        break;
      case 'IN OPZ':
        cplhStatus = 'In OPZ';
        break;
      case 'ABOVE OPZ':
        cplhStatus = 'Above OPZ';
        break;
      default:
        cplhStatus = 'In OPZ';
    }
    final cplhStatusFavorable = opzStatus == 'in';

    final splhDelta = actualSPLH - profile.targetSPLH;
    final splhUnfavorable = actualSPLH < profile.targetSPLH;
    final splhStatus = splhUnfavorable
        ? 'Below target'
        : (actualSPLH > profile.targetSPLH ? 'Above target' : 'On target');

    // Target blended wage now sources from the shared benchmark seam
    // benchmark seam (profile.targetBlendedWage) — the same value
    // Benchmark and Variance show. The old planned-package-style
    // derivation (`(planFohHours × fohWage + planBohHours × bohWage) /
    // (planFohHours + planBohHours)`) is gone.
    final targetBlendedWage = profile.targetBlendedWage;
    final wageDelta = blendedWage - targetBlendedWage;
    final wageUnfavorable = blendedWage > targetBlendedWage;
    final wageStatus = wageUnfavorable ? 'Watch for Overtime' : 'No Overtime';

    return [
      InputMetric(
        name: 'COVERS',
        currentFormatted: '$actualCovers',
        targetFormatted: 'Forecast $forecastCovers',
        targetSupportFormatted: inTheBooksCovers != null
            ? 'In the books $inTheBooksCovers'
            : null,
        deltaFormatted: '${coversDelta >= 0 ? '+' : ''}$coversDelta',
        deltaUnfavorable: coversUnfavorable,
        isHero: heroName == 'COVERS',
        statusLine: coversStatus,
      ),
      InputMetric(
        name: 'PPA',
        currentFormatted: '\$${actualPPA.toStringAsFixed(2)}',
        targetFormatted: 'Target \$${profile.targetPPA.toStringAsFixed(2)}',
        deltaFormatted: ppaDelta >= 0
            ? '+\$${ppaDelta.toStringAsFixed(2)}'
            : '-\$${ppaDelta.abs().toStringAsFixed(2)}',
        deltaUnfavorable: ppaUnfavorable,
        isHero: heroName == 'PPA',
        statusLine: ppaStatus,
      ),
      InputMetric(
        name: 'CPLH',
        currentFormatted: actualCPLH.toStringAsFixed(2),
        targetFormatted: 'Target ${profile.targetCPLH.toStringAsFixed(2)}',
        deltaFormatted:
            '${cplhDelta >= 0 ? '+' : ''}${cplhDelta.toStringAsFixed(2)}',
        deltaUnfavorable: cplhUnfavorable,
        statusFavorable: cplhStatusFavorable,
        isHero: heroName == 'CPLH',
        statusLine: cplhStatus,
      ),
      InputMetric(
        name: 'SPLH',
        currentFormatted: '\$${actualSPLH.toStringAsFixed(0)}',
        targetFormatted: 'Target \$${profile.targetSPLH.toStringAsFixed(0)}',
        deltaFormatted: splhDelta >= 0
            ? '+\$${splhDelta.toStringAsFixed(0)}'
            : '-\$${splhDelta.abs().toStringAsFixed(0)}',
        deltaUnfavorable: splhUnfavorable,
        isHero: heroName == 'SPLH',
        statusLine: splhStatus,
      ),
      InputMetric(
        name: 'BLENDED WAGE',
        currentFormatted: '\$${blendedWage.toStringAsFixed(2)}',
        targetFormatted: 'Target \$${targetBlendedWage.toStringAsFixed(2)}',
        deltaFormatted: wageDelta >= 0
            ? '+\$${wageDelta.toStringAsFixed(2)}'
            : '-\$${wageDelta.abs().toStringAsFixed(2)}',
        deltaUnfavorable: wageUnfavorable,
        isHero: heroName == 'BLENDED WAGE',
        statusLine: wageStatus,
        fullWidth: true,
      ),
    ];
  }
}
