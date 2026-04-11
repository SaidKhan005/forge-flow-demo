/// Everything the Shift dashboard screen needs to render, built from
/// persisted current-state + active target profile + whole-day SchedulePlan.
library;

import '../data/legacy_fixture_data.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../services/labor_model.dart';

class ShiftDashboardReadModel {
  // ── Header context ──────────────────────────────────────────────────────
  final String daypart;
  final String day;
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

  // ── Whole-day labor % ───────────────────────────────────────────────────
  final double actualLaborDollars;
  final double targetLaborDollars;
  final double actualLaborPct;
  final double targetLaborPct;
  final double laborVariancePts;

  // ── Reservation book signal ─────────────────────────────────────────────
  final int? inTheBooksCovers;

  // ── Derived ─────────────────────────────────────────────────────────────
  double get currentSales => actualSales;

  const ShiftDashboardReadModel({
    required this.daypart,
    required this.day,
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
    required this.actualLaborDollars,
    required this.targetLaborDollars,
    required this.actualLaborPct,
    required this.targetLaborPct,
    required this.laborVariancePts,
    this.inTheBooksCovers,
  });

  /// Builds the read model from a single snapshot + active target profile.
  /// Used by tests and legacy paths. Plan values are derived from the snapshot.
  factory ShiftDashboardReadModel.build(
    OpenShiftSnapshot snapshot,
    ActiveTargetProfile profile, {
    int? inTheBooksCovers,
  }) {
    final sales = snapshot.currentCovers * snapshot.currentPPA;
    return ShiftDashboardReadModel.buildWholeDay(
      snapshots: [snapshot],
      profile: profile,
      forecastCovers: snapshot.forecastCovers,
      forecastSales: snapshot.forecastCovers * profile.targetPPA,
      planFohHours: LaborModel.modelFohHours(
          snapshot.forecastCovers, profile.targetCPLH),
      planBohHours: LaborModel.modelBohHours(
          snapshot.forecastCovers, profile.targetPPA, profile.targetSPLH),
      inTheBooksCovers: inTheBooksCovers,
      actualCoversOverride: snapshot.currentCovers,
      actualSalesOverride: sales,
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
  }) {
    // Day label to full name
    const dayFull = {
      'Mon': 'Monday', 'Tue': 'Tuesday', 'Wed': 'Wednesday',
      'Thu': 'Thursday', 'Fri': 'Friday', 'Sat': 'Saturday', 'Sun': 'Sunday',
    };

    // Use the open snapshot for time context, fall back to first
    final openSnap = snapshots.where((s) => s.status == 'open').firstOrNull
        ?? snapshots.first;
    final dayName = dayFull[openSnap.dayLabel] ?? openSnap.dayLabel;

    // Aggregate actuals from closed + open snapshots (not projected)
    final actualSnapshots = snapshots
        .where((s) => s.status == 'closed' || s.status == 'open')
        .toList();

    final totalCovers = actualCoversOverride ??
        actualSnapshots.fold<int>(0, (s, r) => s + r.currentCovers);
    final totalSales = actualSalesOverride ??
        actualSnapshots.fold<double>(
            0, (s, r) => s + r.currentCovers * r.currentPPA);
    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;

    // Actual-to-date hours: closed + open only (not projected future labor)
    final actFoh = actualSnapshots.fold<int>(0, (s, r) => s + r.scheduledFohHours);
    final actBoh = actualSnapshots.fold<int>(0, (s, r) => s + r.scheduledBohHours);

    // Full-day scheduled hours: closed + open + projected (staffing decisions)
    final totalFoh = snapshots.fold<int>(0, (s, r) => s + r.scheduledFohHours);
    final totalBoh = snapshots.fold<int>(0, (s, r) => s + r.scheduledBohHours);

    // Live productivity: actual covers/sales ÷ actual-to-date hours only
    final avgCPLH = actFoh > 0 ? totalCovers / actFoh : 0.0;
    final avgSPLH = actBoh > 0 ? totalSales / actBoh : 0.0;

    // Blended wage: weighted by actual-to-date hours (closed + open)
    final actualWageDollars = actualSnapshots.fold<double>(
        0, (s, r) => s + r.blendedWage * (r.scheduledFohHours + r.scheduledBohHours));
    final actualTotalHours = actFoh + actBoh;
    final avgBlendedWage = actualTotalHours > 0 ? actualWageDollars / actualTotalHours : 0.0;

    // Whole-day labor %: actual from closed+open hours × blended wage,
    // target from SchedulePlan plan hours × profile wages.
    final computedActualLaborDollars = actualWageDollars; // already weighted sum of wage × hours
    final computedTargetLaborDollars =
        planFohHours * profile.fohWage + planBohHours * profile.bohWage;
    final computedActualLaborPct =
        totalSales > 0 ? computedActualLaborDollars / totalSales * 100 : 0.0;
    final computedTargetLaborPct =
        forecastSales > 0 ? computedTargetLaborDollars / forecastSales * 100 : 0.0;
    final computedLaborVariancePts = computedActualLaborPct - computedTargetLaborPct;

    // Primary lever — uses actual-to-date productivity, full-day staffing
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
    final leverCard = LeverCards.all.firstWhere(
      (l) => l.id == leverId,
      orElse: () => LeverCards.coversDown,
    );

    // OPZ status
    final opzStatus = _computeOpzStatus(
        avgCPLH, profile.opzFloorCPLH, profile.opzCeilingCPLH);
    final opzLabel = _computeOpzLabel(opzStatus);
    final opzSubLabel = _computeOpzSubLabel(opzStatus);

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
      actualLaborDollars: computedActualLaborDollars,
      targetLaborDollars: computedTargetLaborDollars,
      actualLaborPct: computedActualLaborPct,
      targetLaborPct: computedTargetLaborPct,
      laborVariancePts: computedLaborVariancePts,
      inTheBooksCovers: inTheBooksCovers,
    );
  }

  static String _daypartLabel(String daypart) {
    switch (daypart) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return daypart;
    }
  }

  // ── OPZ helpers ─────────────────────────────────────────────────────────

  static String _computeOpzStatus(
      double currentCplh, double floor, double ceiling) {
    if (currentCplh < floor) return 'below';
    if (currentCplh > ceiling) return 'above';
    return 'in';
  }

  static String _computeOpzLabel(String status) {
    switch (status) {
      case 'below': return 'BELOW OPZ';
      case 'above': return 'ABOVE OPZ';
      default:      return 'IN OPZ';
    }
  }

  static String _computeOpzSubLabel(String status) {
    switch (status) {
      case 'below':
        return 'Productivity is below the OPZ floor. Too many labor hours for the volume.';
      case 'above':
        return 'Productivity is above the OPZ ceiling. Service quality may suffer.';
      default:
        return 'Team is producing. Watch covers.';
    }
  }

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
      case 'BELOW OPZ': cplhStatus = 'Below OPZ'; break;
      case 'IN OPZ':    cplhStatus = 'In OPZ'; break;
      case 'ABOVE OPZ': cplhStatus = 'Above OPZ'; break;
      default:          cplhStatus = 'In OPZ';
    }
    final cplhStatusFavorable = opzStatus == 'in';

    final splhDelta = actualSPLH - profile.targetSPLH;
    final splhUnfavorable = actualSPLH < profile.targetSPLH;
    final splhStatus = splhUnfavorable
        ? 'Below target'
        : (actualSPLH > profile.targetSPLH ? 'Above target' : 'On target');

    // Blended wage target: from plan hour mix weighted by FOH/BOH wages
    final wageTotalModelHours = planFohHours + planBohHours;
    final targetBlendedWage = wageTotalModelHours > 0
        ? (planFohHours * profile.fohWage + planBohHours * profile.bohWage) /
            wageTotalModelHours
        : 0.0;
    final wageDelta = blendedWage - targetBlendedWage;
    final wageUnfavorable = blendedWage > targetBlendedWage;
    final wageStatus = wageUnfavorable
        ? 'Watch for Overtime'
        : 'No Overtime';

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
        deltaFormatted: '${cplhDelta >= 0 ? '+' : ''}${cplhDelta.toStringAsFixed(2)}',
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
