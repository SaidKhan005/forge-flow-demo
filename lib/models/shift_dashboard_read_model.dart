/// Everything the Shift dashboard screen needs to render, built from
/// persisted current-state + active target profile.

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

  // ── Current shift actuals ───────────────────────────────────────────────
  final int actualCovers;
  final int forecastCovers;
  final int scheduledFohHours;
  final int scheduledBohHours;
  final double actualPPA;
  final double actualCPLH;
  final double actualSPLH;
  final double blendedWage;

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

  const ShiftDashboardReadModel({
    required this.daypart,
    required this.day,
    required this.timeLabel,
    required this.serviceElapsedLabel,
    required this.actualCovers,
    required this.forecastCovers,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.actualPPA,
    required this.actualCPLH,
    required this.actualSPLH,
    required this.blendedWage,
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
  });

  /// Builds the read model from persisted snapshot + active target profile.
  factory ShiftDashboardReadModel.build(
    OpenShiftSnapshot snapshot,
    ActiveTargetProfile profile,
  ) {
    // Day label to full name
    const dayFull = {
      'Mon': 'Monday', 'Tue': 'Tuesday', 'Wed': 'Wednesday',
      'Thu': 'Thursday', 'Fri': 'Friday', 'Sat': 'Saturday', 'Sun': 'Sunday',
    };
    final dayName = dayFull[snapshot.dayLabel] ?? snapshot.dayLabel;

    // Daypart display label
    String daypartLabel;
    switch (snapshot.daypart) {
      case 'lunch':      daypartLabel = 'Lunch'; break;
      case 'dinner':     daypartLabel = 'Dinner'; break;
      case 'late_night': daypartLabel = 'Late Night'; break;
      default:           daypartLabel = snapshot.daypart;
    }

    // Primary lever
    final leverId = LaborModel.determineLever(
      actualCovers: snapshot.currentCovers,
      forecastCovers: snapshot.forecastCovers,
      avgCPLH: snapshot.currentCPLH,
      avgPPA: snapshot.currentPPA,
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      avgSPLH: snapshot.currentSPLH,
      targetSPLH: profile.targetSPLH,
    );
    final leverCard = LeverCards.all.firstWhere(
      (l) => l.id == leverId,
      orElse: () => LeverCards.coversDown,
    );

    // OPZ status
    final opzStatus = _computeOpzStatus(
        snapshot.currentCPLH, profile.opzFloorCPLH, profile.opzCeilingCPLH);
    final opzLabel = _computeOpzLabel(opzStatus);
    final opzSubLabel = _computeOpzSubLabel(opzStatus);

    // Metric cards
    final cards = _buildMetricCards(
      snapshot: snapshot,
      profile: profile,
      leverId: leverId,
      opzStatus: opzStatus,
      opzLabel: opzLabel,
    );

    return ShiftDashboardReadModel(
      daypart: daypartLabel,
      day: dayName,
      timeLabel: snapshot.timeLabel,
      serviceElapsedLabel: snapshot.serviceElapsedLabel,
      actualCovers: snapshot.currentCovers,
      forecastCovers: snapshot.forecastCovers,
      scheduledFohHours: snapshot.scheduledFohHours,
      scheduledBohHours: snapshot.scheduledBohHours,
      actualPPA: snapshot.currentPPA,
      actualCPLH: snapshot.currentCPLH,
      actualSPLH: snapshot.currentSPLH,
      blendedWage: snapshot.blendedWage,
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
    );
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
    required OpenShiftSnapshot snapshot,
    required ActiveTargetProfile profile,
    required String leverId,
    required String opzStatus,
    required String opzLabel,
  }) {
    final heroName = _heroMetricNameForLever(leverId);

    final coversDelta = snapshot.currentCovers - snapshot.forecastCovers;
    final coversUnfavorable = snapshot.currentCovers < snapshot.forecastCovers;
    final coversStatus = coversUnfavorable
        ? 'Light'
        : (snapshot.currentCovers > snapshot.forecastCovers ? 'Heavy' : 'On pace');

    final ppaDelta = snapshot.currentPPA - profile.targetPPA;
    final ppaUnfavorable = snapshot.currentPPA < profile.targetPPA;
    final ppaStatus = ppaUnfavorable
        ? 'Watch'
        : (snapshot.currentPPA > profile.targetPPA ? 'Ahead' : 'On target');

    final cplhDelta = snapshot.currentCPLH - profile.targetCPLH;
    final cplhUnfavorable = snapshot.currentCPLH < profile.targetCPLH;
    String cplhStatus;
    switch (opzLabel) {
      case 'BELOW OPZ': cplhStatus = 'Below OPZ'; break;
      case 'IN OPZ':    cplhStatus = 'In OPZ'; break;
      case 'ABOVE OPZ': cplhStatus = 'Above OPZ'; break;
      default:          cplhStatus = 'In OPZ';
    }
    final cplhStatusFavorable = opzStatus == 'in';

    final splhDelta = snapshot.currentSPLH - profile.targetSPLH;
    final splhUnfavorable = snapshot.currentSPLH < profile.targetSPLH;
    final splhStatus = splhUnfavorable
        ? 'Below target'
        : (snapshot.currentSPLH > profile.targetSPLH ? 'Above target' : 'On target');

    return [
      InputMetric(
        name: 'COVERS',
        currentFormatted: '${snapshot.currentCovers}',
        targetFormatted: 'Forecast ${snapshot.forecastCovers}',
        deltaFormatted: '${coversDelta >= 0 ? '+' : ''}$coversDelta',
        deltaUnfavorable: coversUnfavorable,
        isHero: heroName == 'COVERS',
        statusLine: coversStatus,
      ),
      InputMetric(
        name: 'PPA',
        currentFormatted: '\$${snapshot.currentPPA.toStringAsFixed(2)}',
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
        currentFormatted: snapshot.currentCPLH.toStringAsFixed(1),
        targetFormatted: 'Target ${profile.targetCPLH.toStringAsFixed(1)}',
        deltaFormatted: '${cplhDelta >= 0 ? '+' : ''}${cplhDelta.toStringAsFixed(1)}',
        deltaUnfavorable: cplhUnfavorable,
        statusFavorable: cplhStatusFavorable,
        isHero: heroName == 'CPLH',
        statusLine: cplhStatus,
      ),
      InputMetric(
        name: 'SPLH',
        currentFormatted: '\$${snapshot.currentSPLH.toStringAsFixed(0)}',
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
        currentFormatted: '\$${snapshot.blendedWage.toStringAsFixed(2)}',
        targetFormatted: 'Model \$${snapshot.blendedWage.toStringAsFixed(2)}',
        deltaFormatted: '\u2014',
        deltaUnfavorable: false,
        isHero: heroName == 'BLENDED WAGE',
        statusLine: 'On model',
        fullWidth: true,
      ),
    ];
  }
}
