/// The locked weekly operating plan for a restaurant.
///
/// One active snapshot exists per restaurant per business week.
/// Auto-generated at week start from the current [TargetCycle] + rolling
/// [DemandForecastContext], then locked for the duration of the week.
///
/// Variance, History, and later Learn compare against this locked plan,
/// not a forecast that kept moving after the week started.
///
/// Phase 7.55l.6a: contract only — persistence added in 7.55l.6b+.
library;

import 'schedule_forecast_demand.dart';

/// Immutable day-level row within a [WeeklyPlanSnapshot].
class WeeklyPlanSnapshotDay {
  final String day;
  final String businessDate;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const WeeklyPlanSnapshotDay({
    required this.day,
    required this.businessDate,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });

  Map<String, dynamic> toMap() => {
        'day': day,
        'business_date': businessDate,
        'forecast_covers': forecastCovers,
        'forecast_sales': forecastSales,
        'required_foh_hours': requiredFohHours,
        'required_boh_hours': requiredBohHours,
      };

  factory WeeklyPlanSnapshotDay.fromMap(Map<String, dynamic> m) =>
      WeeklyPlanSnapshotDay(
        day: m['day'] as String,
        businessDate: m['business_date'] as String,
        forecastCovers: m['forecast_covers'] as int,
        forecastSales: (m['forecast_sales'] as num).toDouble(),
        requiredFohHours: m['required_foh_hours'] as int,
        requiredBohHours: m['required_boh_hours'] as int,
      );
}

/// Weekly-level locked plan snapshot.
class WeeklyPlanSnapshot {
  final String snapshotId;
  final String restaurantId;

  // ── App-owned week identity ──────────────────────────────────────────────
  /// Deterministic key derived from `{weekStartDate}_{weekEndDate}`.
  /// Always computed — never stored independently.
  String get weekKey => '${weekStartDate}_$weekEndDate';
  final String weekStartDate;
  final String weekEndDate;

  // ── Target cycle linkage ─────────────────────────────────────────────────
  final String targetCycleId;

  // ── Locked weekly values ─────────────────────────────────────────────────
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  // Plan-derived labor dollars remain on the locked snapshot because they are
  // part of the locked week package. Benchmark-owned total labor % and blended
  // wage are no longer carried as public snapshot fields; non-closed surfaces
  // must read those from the active benchmark seam instead.
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final ForecastDemandSource coversSource;
  final ForecastDemandSource salesSource;

  // ── Locked day rows ──────────────────────────────────────────────────────
  final List<WeeklyPlanSnapshotDay> dayRows;

  // ── Metadata ─────────────────────────────────────────────────────────────
  final String generatedAt;
  final String lockedAt;

  WeeklyPlanSnapshot({
    required this.snapshotId,
    required this.restaurantId,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.targetCycleId,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.coversSource,
    required this.salesSource,
    required this.generatedAt,
    required this.lockedAt,
    List<WeeklyPlanSnapshotDay> dayRows = const [],
  }) : dayRows = List.unmodifiable(dayRows);

  // ── Derived ──────────────────────────────────────────────────────────────

  double get theoreticalTotalLaborDollars =>
      theoreticalFohLaborDollars + theoreticalBohLaborDollars;

  int get totalRequiredHours => requiredFohHours + requiredBohHours;

  // ── Serialization ────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
        'snapshot_id': snapshotId,
        'restaurant_id': restaurantId,
        'week_key': weekKey,
        'week_start_date': weekStartDate,
        'week_end_date': weekEndDate,
        'target_cycle_id': targetCycleId,
        'forecast_covers': forecastCovers,
        'forecast_sales': forecastSales,
        'required_foh_hours': requiredFohHours,
        'required_boh_hours': requiredBohHours,
        'theoretical_foh_labor_dollars': theoreticalFohLaborDollars,
        'theoretical_boh_labor_dollars': theoreticalBohLaborDollars,
        // Compatibility persistence copies retained in SQLite so old rows and
        // bridge-era tooling still round-trip, but no longer exposed as
        // canonical fields on the public snapshot model.
        'theoretical_labor_pct': forecastSales > 0
            ? theoreticalTotalLaborDollars / forecastSales * 100
            : 0.0,
        'target_blended_wage': totalRequiredHours > 0
            ? theoreticalTotalLaborDollars / totalRequiredHours
            : 0.0,
        'covers_source': coversSource.name,
        'sales_source': salesSource.name,
        'generated_at': generatedAt,
        'locked_at': lockedAt,
        'day_rows': dayRows.map((d) => d.toMap()).toList(),
      };

  factory WeeklyPlanSnapshot.fromMap(Map<String, dynamic> m) {
    final weekStartDate = m['week_start_date'] as String;
    final weekEndDate = m['week_end_date'] as String;
    final expectedKey = '${weekStartDate}_$weekEndDate';

    final storedKey = m['week_key'] as String?;
    if (storedKey != null && storedKey != expectedKey) {
      throw ArgumentError(
        'WeeklyPlanSnapshot.fromMap: stored week_key "$storedKey" does not '
        'match derived key "$expectedKey". Inconsistent week identity.',
      );
    }

    final rawRows = m['day_rows'] as List<dynamic>?;
    final dayRowsList = rawRows
            ?.map((d) =>
                WeeklyPlanSnapshotDay.fromMap(d as Map<String, dynamic>))
            .toList() ??
        [];

    return WeeklyPlanSnapshot(
      snapshotId: m['snapshot_id'] as String,
      restaurantId: m['restaurant_id'] as String,
      weekStartDate: weekStartDate,
      weekEndDate: weekEndDate,
      targetCycleId: m['target_cycle_id'] as String,
      forecastCovers: m['forecast_covers'] as int,
      forecastSales: (m['forecast_sales'] as num).toDouble(),
      requiredFohHours: m['required_foh_hours'] as int,
      requiredBohHours: m['required_boh_hours'] as int,
      theoreticalFohLaborDollars:
          (m['theoretical_foh_labor_dollars'] as num).toDouble(),
      theoreticalBohLaborDollars:
          (m['theoretical_boh_labor_dollars'] as num).toDouble(),
      coversSource:
          ForecastDemandSource.values.byName(m['covers_source'] as String),
      salesSource:
          ForecastDemandSource.values.byName(m['sales_source'] as String),
      generatedAt: m['generated_at'] as String,
      lockedAt: m['locked_at'] as String,
      dayRows: dayRowsList,
    );
  }
}
