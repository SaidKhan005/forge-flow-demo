// A completed week stored in SQLite. Used for History tab.

import '../data/legacy_fixture_data.dart';
import '../services/labor_model.dart';

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

  // ── Locked target fields (Phase 7.5b) ──────────────────────────────────
  final String? targetSourceType;
  final double? targetCPLH;
  final double? targetSPLH;
  final double? targetPPA;
  final double? targetFohWage;
  final double? targetBohWage;
  final double? theoreticalFohLaborPct;
  final double? theoreticalBohLaborPct;

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
    this.targetSourceType,
    this.targetCPLH,
    this.targetSPLH,
    this.targetPPA,
    this.targetFohWage,
    this.targetBohWage,
    this.theoreticalFohLaborPct,
    this.theoreticalBohLaborPct,
  });

  double get laborPctVariance => actualLaborPct - theoreticalLaborPct;
  bool get isOverModel => dollarGap > 0;

  double get avgSPLH =>
      totalBohHours > 0 ? (avgPPA * totalCovers) / totalBohHours : 0;

  double get dollarGapAnnualized => dollarGap.abs() * 52;

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

  // ── Targets — model hours for actual volume (Jim Taylor Ch. 10) ─────────
  int get targetCovers =>
      (forecastCovers * shiftsCompleted / 14).round();
  int get targetFohHours =>
      LaborModel.modelFohHours(totalCovers, storedTargetCPLH);
  int get targetBohHours =>
      LaborModel.modelBohHours(totalCovers, avgPPA, storedTargetSPLH);

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
        blendedFohWage: (m['blended_foh_wage'] as num?)?.toDouble() ??
            MeridianConfig.fohWage,
        blendedBohWage: (m['blended_boh_wage'] as num?)?.toDouble() ??
            MeridianConfig.bohWage,
        targetSourceType: m['target_source_type'] as String?,
        targetCPLH: (m['target_cplh'] as num?)?.toDouble(),
        targetSPLH: (m['target_splh'] as num?)?.toDouble(),
        targetPPA: (m['target_ppa'] as num?)?.toDouble(),
        targetFohWage: (m['target_foh_wage'] as num?)?.toDouble(),
        targetBohWage: (m['target_boh_wage'] as num?)?.toDouble(),
        theoreticalFohLaborPct: (m['theoretical_foh_labor_pct'] as num?)?.toDouble(),
        theoreticalBohLaborPct: (m['theoretical_boh_labor_pct'] as num?)?.toDouble(),
      );
}
