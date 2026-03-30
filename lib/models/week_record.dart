// A completed week stored in SQLite. Used for History tab.

import '../data/meridian_data.dart';
import '../services/labor_model.dart';

class WeekRecord {
  final int? id;
  final String weekId;       // 'week_2026_W12'
  final String weekLabel;    // 'Week of Mar 24'
  final int totalCovers;
  final int forecastCovers;
  final int totalFohHours;
  final int totalBohHours;
  final double avgPPA;
  final double avgCPLH;
  final double theoreticalLaborPct;
  final double actualLaborPct;
  final double dollarGap;          // positive = over model, negative = under
  final String primaryLeverId;     // matches LeverCardData.id
  final int shiftsCompleted;       // how many shifts closed in this week
  final double blendedFohWage;     // actual FOH blended wage for the week
  final double blendedBohWage;     // actual BOH blended wage for the week

  const WeekRecord({
    this.id,
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
  });

  double get laborPctVariance => actualLaborPct - theoreticalLaborPct;
  bool get isOverModel => dollarGap > 0;

  // avgSPLH = total sales ÷ BOH hours  (totalSales not stored; derived from avgPPA × covers)
  double get avgSPLH =>
      totalBohHours > 0 ? (avgPPA * totalCovers) / totalBohHours : 0;

  // ── Annualized gap — weekly × 52 ─────────────────────────────────────────
  double get dollarGapAnnualized => dollarGap.abs() * 52;

  // ── Targets — model hours for actual volume (Jim Taylor Ch. 10) ─────────
  // Answers: given the covers that actually came in, how many hours did the
  // model say were needed? Never prorated — partial weeks are fully correct.
  int get targetCovers =>
      (forecastCovers * shiftsCompleted / 14).round();
  int get targetFohHours =>
      LaborModel.modelFohHours(totalCovers, BaselineData.derivedTargetCPLH);
  int get targetBohHours =>
      LaborModel.modelBohHours(totalCovers, avgPPA, BaselineData.derivedTargetSPLH);

  Map<String, dynamic> toMap() => {
        'id': id,
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
      };

  factory WeekRecord.fromMap(Map<String, dynamic> m) => WeekRecord(
        id: m['id'] as int?,
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
      );
}
