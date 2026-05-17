// Per-Daypart Targets V1 — shared bottom-up reconciliation for the
// locked weekly-plan snapshot.
//
// PR #917 made the RUNTIME locked snapshot bottom-up by construction:
// day rows = Σ(per-period rows), week totals = Σ(day rows), week
// theoretical FOH/BOH labor $ = Σ(per-period $), while per-period rows
// keep per-period rate fidelity. The demo seed used to build the
// snapshot through a separate parallel path that never reconciled, so
// demo data drifted (Σ(per-period) ≠ day ≠ week).
//
// This is the SINGLE shared reconciliation entrypoint. The runtime lock
// path (`WeeklyPlanSnapshotService._generateAndPersistSnapshot`) AND the
// demo seed (`SqliteDatabaseSeed` snapshot builders) both call
// [WeeklyPlanSnapshotBottomUpReconciler.reconcile]. There is exactly one
// implementation of the math so the three writers cannot drift.
//
// Pure: no persistence, no side effects, no I/O. Behaviour is
// byte-identical to PR #917's private `_reconcileBottomUp`.

library;

import '../models/schedule_plan.dart';
import '../models/weekly_plan_snapshot.dart';

/// Result of recomputing the locked snapshot's day rows + week totals as
/// the SUM of the per-period rows.
class WeeklyPlanSnapshotBottomUpReconcileResult {
  final List<WeeklyPlanSnapshotDay> dayRows;
  final int weekCovers;
  final double weekSales;
  final int weekFohHours;
  final int weekBohHours;
  final double weekFohDollars;
  final double weekBohDollars;

  const WeeklyPlanSnapshotBottomUpReconcileResult({
    required this.dayRows,
    required this.weekCovers,
    required this.weekSales,
    required this.weekFohHours,
    required this.weekBohHours,
    required this.weekFohDollars,
    required this.weekBohDollars,
  });
}

class WeeklyPlanSnapshotBottomUpReconciler {
  const WeeklyPlanSnapshotBottomUpReconciler._();

  /// Recompute the locked snapshot's day rows + week totals bottom-up
  /// from the per-period ([WeeklyPlanSnapshotDayDaypart]) rows.
  ///
  /// Rules (byte-identical to PR #917's runtime `_reconcileBottomUp`):
  ///   - A day WITH per-period rows: its `forecastCovers`,
  ///     `forecastSales`, `requiredFohHours`, `requiredBohHours` become
  ///     the sum of that day's per-period rows. Model field types are
  ///     honoured — `requiredFohHours`/`requiredBohHours` are `int`
  ///     (the summed per-period doubles are rounded), `forecastCovers`
  ///     is `int` (already an exact LR sum), `forecastSales` is
  ///     `double`.
  ///   - A day WITHOUT per-period rows (Gap 42 empty cycle dayparts on
  ///     a per-day basis): keep the original pooled `plan.dayPlans`
  ///     whole-day values verbatim (honest fallback — never zeroed).
  ///   - Week totals: covers/sales/FOH/BOH = SUM of the recomputed day
  ///     rows; theoretical FOH/BOH labor $ = SUM of per-period
  ///     `theoreticalFohDollars`/`theoreticalBohDollars`.
  ///   - When the cycle has NO per-period rows at all (`dayDayparts`
  ///     entirely empty), fall back to the original `plan.*` pooled
  ///     totals so a legacy / Gap-42 snapshot is unchanged.
  static WeeklyPlanSnapshotBottomUpReconcileResult reconcile({
    required SchedulePlan plan,
    required List<WeeklyPlanSnapshotDay> dayRows,
    required List<WeeklyPlanSnapshotDayDaypart> dayDayparts,
  }) {
    if (dayDayparts.isEmpty) {
      // No per-period rows anywhere — keep the pooled plan totals and
      // the original day rows verbatim (legacy / Gap-42 whole-cycle
      // fallback). Honest: nothing is zeroed.
      return WeeklyPlanSnapshotBottomUpReconcileResult(
        dayRows: dayRows,
        weekCovers: plan.forecastCovers,
        weekSales: plan.forecastSales,
        weekFohHours: plan.requiredFohHours,
        weekBohHours: plan.requiredBohHours,
        weekFohDollars: plan.theoreticalFohLaborDollars,
        weekBohDollars: plan.theoreticalBohLaborDollars,
      );
    }

    // Bucket per-period rows by business date.
    final byDate = <String, List<WeeklyPlanSnapshotDayDaypart>>{};
    for (final dp in dayDayparts) {
      (byDate[dp.businessDate] ??= <WeeklyPlanSnapshotDayDaypart>[]).add(dp);
    }

    final recomputedDayRows = <WeeklyPlanSnapshotDay>[];
    var weekCovers = 0;
    var weekSales = 0.0;
    var weekFohHours = 0;
    var weekBohHours = 0;
    for (final row in dayRows) {
      final periods = byDate[row.businessDate];
      if (periods == null || periods.isEmpty) {
        // Gap 42 per-day fallback: this day has no per-period rows —
        // keep its pooled whole-day values verbatim (never zero them).
        recomputedDayRows.add(row);
        weekCovers += row.forecastCovers;
        weekSales += row.forecastSales;
        weekFohHours += row.requiredFohHours;
        weekBohHours += row.requiredBohHours;
        continue;
      }
      final dayCovers = periods.fold<int>(0, (s, p) => s + p.forecastCovers);
      final daySales =
          periods.fold<double>(0, (s, p) => s + p.forecastSales);
      final dayFohHours = periods
          .fold<double>(0, (s, p) => s + p.requiredFohHours)
          .round();
      final dayBohHours = periods
          .fold<double>(0, (s, p) => s + p.requiredBohHours)
          .round();
      recomputedDayRows.add(WeeklyPlanSnapshotDay(
        day: row.day,
        businessDate: row.businessDate,
        forecastCovers: dayCovers,
        forecastSales: daySales,
        requiredFohHours: dayFohHours,
        requiredBohHours: dayBohHours,
      ));
      weekCovers += dayCovers;
      weekSales += daySales;
      weekFohHours += dayFohHours;
      weekBohHours += dayBohHours;
    }

    // Week labor dollars = SUM of per-period theoretical dollars
    // (per-period rate fidelity preserved end-to-end).
    final weekFohDollars =
        dayDayparts.fold<double>(0, (s, p) => s + p.theoreticalFohDollars);
    final weekBohDollars =
        dayDayparts.fold<double>(0, (s, p) => s + p.theoreticalBohDollars);

    return WeeklyPlanSnapshotBottomUpReconcileResult(
      dayRows: recomputedDayRows,
      weekCovers: weekCovers,
      weekSales: weekSales,
      weekFohHours: weekFohHours,
      weekBohHours: weekBohHours,
      weekFohDollars: weekFohDollars,
      weekBohDollars: weekBohDollars,
    );
  }
}
