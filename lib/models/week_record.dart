// A completed week stored in SQLite. Used for History tab.

import '../domain/constants/app_defaults.dart';

class WeekRecord {
  final int? id;
  final String restaurantId;
  final String weekId;
  final String weekLabel;
  final int totalCovers;
  final int forecastCovers;
  final int totalFohHours;
  final int totalBohHours;
  final double avgPPA;
  final double avgCPLH;
  final double theoreticalLaborPct;
  final double actualLaborPct;
  final double dollarGap;
  final String primaryLeverId;
  final int shiftsCompleted;
  final double blendedFohWage;
  final double blendedBohWage;
  final bool hasStoredBlendedWageTruth;

  // ── Locked target fields (Phase 7.5b) ──────────────────────────────────
  final String? targetSourceType;
  final double? targetCPLH;
  final double? targetSPLH;
  final double? targetPPA;
  final double? targetFohWage;
  final double? targetBohWage;
  final double? theoreticalFohLaborPct;
  final double? theoreticalBohLaborPct;

  // ── Preserved locked plan hours (Phase 7.55q.5) ────────────────────────
  // Captured at week close from the WeeklyPlanSnapshot in force for the
  // week's business-date span. When null, the week was closed before this
  // field existed (legacy) or without a persisted snapshot (honest gap);
  // Week Detail renders "—" for those rows rather than re-modeling from
  // actuals.
  final int? lockedRequiredFohHours;
  final int? lockedRequiredBohHours;

  // ── Frozen Dollar Impact windows (Phase 7.55q.10) ──────────────────────
  // Captured at week close from the same closed-truth date-range queries
  // the current-week Variance card was reading. Locks the 4-row Dollar
  // Impact view (Week / Month / 60-day / Annualized) at the close moment
  // so Week Detail mirrors what was on screen the instant the 14th shift
  // closed. When null, the week was closed before this field existed
  // (legacy); the UI falls back to the legacy 2-row + boilerplate footer.
  final double? monthDollarImpact;
  final double? sixtyDayDollarImpact;
  final String? closedAt; // 'YYYY-MM-DD' — last shift's businessDate
  final String? targetCalibrationWindowStart;
  final String? targetCalibrationWindowEnd;

  const WeekRecord({
    this.id,
    this.restaurantId = 'demo_restaurant_001',
    required this.weekId,
    required this.weekLabel,
    required this.totalCovers,
    required this.forecastCovers,
    required this.totalFohHours,
    required this.totalBohHours,
    required this.avgPPA,
    required this.avgCPLH,
    required this.theoreticalLaborPct,
    required this.actualLaborPct,
    required this.dollarGap,
    required this.primaryLeverId,
    this.shiftsCompleted = 14,
    this.blendedFohWage = MeridianConfig.fohWage,
    this.blendedBohWage = MeridianConfig.bohWage,
    this.hasStoredBlendedWageTruth = true,
    this.targetSourceType,
    this.targetCPLH,
    this.targetSPLH,
    this.targetPPA,
    this.targetFohWage,
    this.targetBohWage,
    this.theoreticalFohLaborPct,
    this.theoreticalBohLaborPct,
    this.lockedRequiredFohHours,
    this.lockedRequiredBohHours,
    this.monthDollarImpact,
    this.sixtyDayDollarImpact,
    this.closedAt,
    this.targetCalibrationWindowStart,
    this.targetCalibrationWindowEnd,
  });

  double get laborPctVariance => actualLaborPct - theoreticalLaborPct;
  bool get isOverModel => dollarGap > 0;

  double get avgSPLH =>
      totalBohHours > 0 ? (avgPPA * totalCovers) / totalBohHours : 0;

  double get dollarGapAnnualized => dollarGap.abs() * 52;
  bool get hasActualBlendedWageTruth => hasStoredBlendedWageTruth;

  // ── Frozen annualized from 60-day window (Phase 7.55q.10) ──────────────
  // Mirrors `WeekData.annualizedDollarImpact` so the number on Week Detail
  // equals the number that was on the live Variance card the moment the
  // 14th shift closed. Null when no 60-day window was captured at close
  // (legacy rows) — caller falls back to `dollarGapAnnualized` (×52).
  double? get frozenAnnualizedImpact =>
      sixtyDayDollarImpact != null
          ? sixtyDayDollarImpact! * (365.0 / 60)
          : null;

  // ── Target provenance — readable label from stored source type ──────────
  // Handles both legacy pre-cycle and cycle-era source types.
  String get provenanceLabel {
    switch (targetSourceType) {
      case 'system_baseline':
      case 'cycle_recommended':
        return '60-Day Benchmark';
      case 'manager_override':
      case 'cycle_manager_override':
        return 'Manager Override';
      case 'admin_replacement':
      case 'cycle_admin_replacement':
        return 'Admin Override';
      default:
        return 'Baseline';
    }
  }

  // ── Locked target getters — strict, no current-global fallback ─────────
  double get storedTargetCPLH => _requireLocked(targetCPLH, 'targetCPLH');
  double get storedTargetSPLH => _requireLocked(targetSPLH, 'targetSPLH');
  double get storedTargetPPA => _requireLocked(targetPPA, 'targetPPA');
  double get storedTargetFohWage => _requireLocked(targetFohWage, 'targetFohWage');
  double get storedTargetBohWage => _requireLocked(targetBohWage, 'targetBohWage');

  static double _requireLocked(double? value, String field) {
    if (value == null) {
      throw StateError(
        'WeekRecord.$field is null — historical target field must be '
        'backfilled before reading. This indicates a migration gap.',
      );
    }
    return value;
  }

  // ── Preserved locked plan hours — null-safe accessors (Phase 7.55q.5) ──
  // UI callers (e.g. Week Detail) use these and render "—" when null,
  // instead of silently re-modeling from actuals (Drift 6).
  int? get preservedTargetFohHours => lockedRequiredFohHours;
  int? get preservedTargetBohHours => lockedRequiredBohHours;

  // ── Targets — preserved locked plan hours (Phase 7.55q.5) ──────────────
  // These are the week's locked plan hours captured at close time from
  // the WeeklyPlanSnapshot in force. Throws StateError when the preserved
  // field is null — strict consumers must either go through the null-safe
  // `preservedTargetFohHours` / `preservedTargetBohHours` accessors or
  // display "—".
  //
  // Prior to 7.55q.5 these getters re-modeled target hours from the
  // post-close totalCovers + locked target rates (Jim Taylor Ch. 10),
  // which was actuals-anchored and violated the Rule 5 "History must
  // preserve closed truth" conformance rule.
  int get targetCovers =>
      (forecastCovers * shiftsCompleted / 14).round();
  int get targetFohHours =>
      _requireLockedInt(lockedRequiredFohHours, 'lockedRequiredFohHours');
  int get targetBohHours =>
      _requireLockedInt(lockedRequiredBohHours, 'lockedRequiredBohHours');

  static int _requireLockedInt(int? value, String field) {
    if (value == null) {
      throw StateError(
        'WeekRecord.$field is null — preserved locked plan hours were not '
        'captured at week close. Legacy rows without this field must '
        'display "—" instead of re-modeling from actuals.',
      );
    }
    return value;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'restaurant_id': restaurantId,
        'week_id': weekId,
        'week_label': weekLabel,
        'total_covers': totalCovers,
        'forecast_covers': forecastCovers,
        'total_foh_hours': totalFohHours,
        'total_boh_hours': totalBohHours,
        'avg_ppa': avgPPA,
        'avg_cplh': avgCPLH,
        'theoretical_labor_pct': theoreticalLaborPct,
        'actual_labor_pct': actualLaborPct,
        'dollar_gap': dollarGap,
        'primary_lever_id': primaryLeverId,
        'shifts_completed': shiftsCompleted,
        'blended_foh_wage': blendedFohWage,
        'blended_boh_wage': blendedBohWage,
        'target_source_type': targetSourceType,
        'target_cplh': targetCPLH,
        'target_splh': targetSPLH,
        'target_ppa': targetPPA,
        'target_foh_wage': targetFohWage,
        'target_boh_wage': targetBohWage,
        'theoretical_foh_labor_pct': theoreticalFohLaborPct,
        'theoretical_boh_labor_pct': theoreticalBohLaborPct,
        'locked_required_foh_hours': lockedRequiredFohHours,
        'locked_required_boh_hours': lockedRequiredBohHours,
        'month_dollar_impact': monthDollarImpact,
        'sixty_day_dollar_impact': sixtyDayDollarImpact,
        'closed_at': closedAt,
        'target_calibration_window_start': targetCalibrationWindowStart,
        'target_calibration_window_end': targetCalibrationWindowEnd,
      };

  factory WeekRecord.fromMap(Map<String, dynamic> m) => WeekRecord(
        id: m['id'] as int?,
        restaurantId: (m['restaurant_id'] as String?) ?? 'demo_restaurant_001',
        weekId: m['week_id'] as String,
        weekLabel: m['week_label'] as String,
        totalCovers: m['total_covers'] as int,
        forecastCovers: m['forecast_covers'] as int,
        totalFohHours: m['total_foh_hours'] as int,
        totalBohHours: m['total_boh_hours'] as int,
        avgPPA: (m['avg_ppa'] as num).toDouble(),
        avgCPLH: (m['avg_cplh'] as num).toDouble(),
        theoreticalLaborPct: (m['theoretical_labor_pct'] as num).toDouble(),
        actualLaborPct: (m['actual_labor_pct'] as num).toDouble(),
        dollarGap: (m['dollar_gap'] as num).toDouble(),
        primaryLeverId: m['primary_lever_id'] as String,
        shiftsCompleted: (m['shifts_completed'] as int?) ?? 14,
        blendedFohWage:
            (m['blended_foh_wage'] as num?)?.toDouble() ?? 0.0,
        blendedBohWage:
            (m['blended_boh_wage'] as num?)?.toDouble() ?? 0.0,
        hasStoredBlendedWageTruth:
            m['blended_foh_wage'] != null && m['blended_boh_wage'] != null,
        targetSourceType: m['target_source_type'] as String?,
        targetCPLH: (m['target_cplh'] as num?)?.toDouble(),
        targetSPLH: (m['target_splh'] as num?)?.toDouble(),
        targetPPA: (m['target_ppa'] as num?)?.toDouble(),
        targetFohWage: (m['target_foh_wage'] as num?)?.toDouble(),
        targetBohWage: (m['target_boh_wage'] as num?)?.toDouble(),
        theoreticalFohLaborPct: (m['theoretical_foh_labor_pct'] as num?)?.toDouble(),
        theoreticalBohLaborPct: (m['theoretical_boh_labor_pct'] as num?)?.toDouble(),
        lockedRequiredFohHours: (m['locked_required_foh_hours'] as num?)?.toInt(),
        lockedRequiredBohHours: (m['locked_required_boh_hours'] as num?)?.toInt(),
        monthDollarImpact: (m['month_dollar_impact'] as num?)?.toDouble(),
        sixtyDayDollarImpact: (m['sixty_day_dollar_impact'] as num?)?.toDouble(),
        closedAt: m['closed_at'] as String?,
        targetCalibrationWindowStart:
            m['target_calibration_window_start'] as String?,
        targetCalibrationWindowEnd:
            m['target_calibration_window_end'] as String?,
      );
}
