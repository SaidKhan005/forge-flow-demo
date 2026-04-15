// Phase 7.55l.7a — Pure projector from WeeklyPlanSnapshot to SchedulePlan.
//
// Maps locked weekly snapshot values directly to SchedulePlan shape
// for downstream consumers that need SchedulePlan API but should read
// from the locked weekly truth instead of live-resolving from demand +
// profile + weights.
//
// No persistence, no side effects — pure projection only.

import '../models/schedule_plan.dart';
import '../models/weekly_plan_snapshot.dart';

class WeeklyPlanSnapshotSchedulePlanProjector {
  WeeklyPlanSnapshotSchedulePlanProjector._();

  /// Projects a [WeeklyPlanSnapshot] to a [SchedulePlan].
  ///
  /// Weekly totals are mapped directly. Day rows are mapped from
  /// [WeeklyPlanSnapshotDay] to [ScheduleDayPlan].
  static SchedulePlan project(WeeklyPlanSnapshot snapshot) {
    final theoreticalTotalLaborDollars = snapshot.theoreticalFohLaborDollars +
        snapshot.theoreticalBohLaborDollars;
    final theoreticalLaborPct = snapshot.forecastSales > 0
        ? theoreticalTotalLaborDollars / snapshot.forecastSales * 100
        : 0.0;
    final targetBlendedWage = snapshot.totalRequiredHours > 0
        ? theoreticalTotalLaborDollars / snapshot.totalRequiredHours
        : 0.0;

    return SchedulePlan(
      forecastCovers: snapshot.forecastCovers,
      forecastSales: snapshot.forecastSales,
      requiredFohHours: snapshot.requiredFohHours,
      requiredBohHours: snapshot.requiredBohHours,
      theoreticalFohLaborDollars: snapshot.theoreticalFohLaborDollars,
      theoreticalBohLaborDollars: snapshot.theoreticalBohLaborDollars,
      theoreticalLaborPct: theoreticalLaborPct,
      targetBlendedWage: targetBlendedWage,
      coversSource: snapshot.coversSource,
      salesSource: snapshot.salesSource,
      dayPlans: snapshot.dayRows
          .map((d) => ScheduleDayPlan(
                day: d.day,
                forecastCovers: d.forecastCovers,
                forecastSales: d.forecastSales,
                requiredFohHours: d.requiredFohHours,
                requiredBohHours: d.requiredBohHours,
              ))
          .toList(),
    );
  }
}
