// Per-Daypart Targets V1 (Slice 5) — shared locked-snapshot per-period
// integer-hours reconciliation.
//
// The locked `WeeklyPlanSnapshot` persists per-(business_date,
// service_period) sub-rows whose `requiredFohHours` / `requiredBohHours`
// are DOUBLES (Design Rule 5 — period hours × whole-day wage). Several
// presentation surfaces need INTEGER per-period hours:
//
//   - Variance Full Week non-closed rows (`ShiftService.getFullWeekShifts`
//     via `_resolvePlanDaypartOverrides` → `DaypartAllocation`/
//     `ShiftRecord`, which are int), and
//   - the Shift per-period card (`ShiftServicePeriodNotifier`
//     `_resolveDaypartTargets`, surfaced to the operator as
//     `requiredHours.round()`).
//
// Independently rounding each period's double (naive per-cell
// `.round()`) re-introduces the Σ(per-period) ≠ day-row drift that
// #917 / #941 just eliminated, and lets the same (day, period) show a
// different whole-hour figure on the Variance row vs the Shift card.
//
// Option B (operator decision): convert ONCE, here, via the shared
// largest-remainder helper so per-period whole hours sum EXACTLY to the
// locked day-level INTEGER hours and BOTH surfaces read the identical
// integers for the same (day, period). No formula change — this only
// reconciles already-persisted locked values into integers; the doubles
// remain the canonical persisted truth.
//
// Pure: no I/O, no globals, deterministic.
library;

import '../models/weekly_plan_snapshot.dart';
import 'proportional_allocation.dart' as shared;
import 'service_period_definition_resolver.dart';
import '../models/service_period_definition.dart';

/// One locked per-period sub-row with FOH/BOH hours reconciled to
/// integers that sum exactly to the locked day-level integer hours.
///
/// `forecastCovers` (int) and `forecastSales` (double) carry straight
/// from the persisted sub-row unchanged. Only the hour doubles are
/// converted.
class LockedDaypartIntHours {
  final String servicePeriodId;
  final String label;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const LockedDaypartIntHours({
    required this.servicePeriodId,
    required this.label,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}

/// Reconciles the locked per-period sub-rows for [businessDate] into
/// integer FOH/BOH hours.
///
/// The day-level integer totals are the locked whole-day
/// [WeeklyPlanSnapshotDay] row's `requiredFohHours` / `requiredBohHours`
/// for [businessDate]. The per-period shares are that day's persisted
/// sub-row `requiredFohHours` / `requiredBohHours` doubles, in canonical
/// service-period order (sortOrder, then id) — the exact ordering the
/// Plan tab and the prior allocator presented.
///
/// Result per-period integers satisfy
/// `Σ(requiredFohHours) == dayRow.requiredFohHours` and likewise for
/// BOH, by largest-remainder construction
/// ([shared.allocateLargestRemainderByDouble]) — the same single source
/// of truth #917 / #941 use, so there is no independent rounding drift.
///
/// Returns an empty list when [snapshot] has no persisted sub-rows for
/// [businessDate] (legacy snapshot / Gap 42 fallback) — callers must
/// then take their existing allocator fallback path. Returns an empty
/// list (rather than fabricating) when no whole-day row matches
/// [businessDate].
List<LockedDaypartIntHours> reconcileLockedDaypartIntHours({
  required WeeklyPlanSnapshot snapshot,
  required String businessDate,
  required List<ServicePeriodDefinition> definitions,
}) {
  final periodRows = snapshot.dayDayparts
      .where((d) => d.businessDate == businessDate)
      .toList()
    ..sort((a, b) => ServicePeriodDefinitionResolver.sortKey(
            definitions, a.servicePeriodId)
        .compareTo(ServicePeriodDefinitionResolver.sortKey(
            definitions, b.servicePeriodId)));
  if (periodRows.isEmpty) return const [];

  WeeklyPlanSnapshotDay? dayRow;
  for (final dr in snapshot.dayRows) {
    if (dr.businessDate == businessDate) {
      dayRow = dr;
      break;
    }
  }
  if (dayRow == null) return const [];

  final fohShares =
      periodRows.map((r) => r.requiredFohHours).toList(growable: false);
  final bohShares =
      periodRows.map((r) => r.requiredBohHours).toList(growable: false);

  // Single shared largest-remainder conversion: per-period integers sum
  // EXACTLY to the locked day-level integer (Option B, not naive
  // per-cell round).
  final fohInts = shared.allocateLargestRemainderByDouble(
      dayRow.requiredFohHours, fohShares);
  final bohInts = shared.allocateLargestRemainderByDouble(
      dayRow.requiredBohHours, bohShares);

  return List.generate(periodRows.length, (i) {
    final r = periodRows[i];
    return LockedDaypartIntHours(
      servicePeriodId: r.servicePeriodId,
      label: ServicePeriodDefinitionResolver.labelForId(
          definitions, r.servicePeriodId),
      forecastCovers: r.forecastCovers,
      forecastSales: r.forecastSales,
      requiredFohHours: fohInts[i],
      requiredBohHours: bohInts[i],
    );
  });
}

/// Convenience: the reconciled integer FOH/BOH hours for a single
/// `(businessDate, servicePeriodId)`, or null when the period is not
/// present in the locked sub-rows for that date (legacy / Gap 42).
///
/// Used by the Shift per-period card so it surfaces the SAME integer
/// hours the Variance Full Week row shows for the same (day, period)
/// (parity is pinned by test).
LockedDaypartIntHours? reconciledLockedDaypartFor({
  required WeeklyPlanSnapshot snapshot,
  required String businessDate,
  required String servicePeriodId,
  required List<ServicePeriodDefinition> definitions,
}) {
  final rows = reconcileLockedDaypartIntHours(
    snapshot: snapshot,
    businessDate: businessDate,
    definitions: definitions,
  );
  for (final r in rows) {
    if (r.servicePeriodId == servicePeriodId) return r;
  }
  return null;
}
