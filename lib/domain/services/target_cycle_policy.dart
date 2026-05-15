/// Pure rule helper for [TargetCycle] contract-level questions.
///
/// No persistence, no side effects, no weekly-plan logic.
/// Phase 7.55l.1: contract only.
library;

import '../models/target_cycle.dart';

class TargetCyclePolicy {
  const TargetCyclePolicy._();

  /// Whether [cycle] is active for the given [businessDate].
  ///
  /// A cycle is active when the business date falls within
  /// [effectiveStart, effectiveEnd] inclusive.
  static bool isActiveForDate(TargetCycle cycle, String businessDate) {
    return businessDate.compareTo(cycle.effectiveStart) >= 0 &&
        businessDate.compareTo(cycle.effectiveEnd) <= 0;
  }

  /// Whether the manager can override this cycle on [businessDate].
  ///
  /// Both conditions must hold:
  /// 1. The cycle is active for the given business date.
  /// 2. The once-per-cycle override has not been used yet.
  ///
  /// After the manager overrides, only admin can change the target
  /// before cycle end.
  static bool canManagerOverride(TargetCycle cycle, String businessDate) {
    return isActiveForDate(cycle, businessDate) && !cycle.managerOverrideUsed;
  }

  /// Whether the [businessDate] is past the cycle end AND today is the
  /// operator's configured business-week start day, meaning the app should
  /// auto-switch to the next recommended cycle.
  ///
  /// Per-daypart-targets V1 (Slice 0): cycle rollover gates to the
  /// operator-configured `week_start_day` so cycles cannot refresh mid-week.
  /// Cycle length becomes 60–66 days per operator depending on where the
  /// 60-day boundary falls relative to the week-start. Jim Taylor's
  /// "minimum 60 days" promise is preserved by the past-effective-end
  /// precondition.
  ///
  /// [weekStartDay] follows the `DateTime` weekday convention
  /// (1 = Monday, …, 7 = Sunday). Mirrors
  /// [WeeklyPlanSnapshotPolicy.weekStartForDate] / `weekKeyForDate` so the
  /// cycle-rollover boundary aligns with the weekly-plan-lock boundary.
  /// Defaults to [DateTime.monday] for callers that have not yet wired
  /// the operator's timing config.
  static bool needsAutoRefresh(
    TargetCycle cycle,
    String businessDate, {
    int weekStartDay = DateTime.monday,
  }) {
    if (businessDate.compareTo(cycle.effectiveEnd) <= 0) return false;
    return _parseDate(businessDate).weekday == weekStartDay;
  }

  /// Calendar days from [businessDate] to the cycle's effective end.
  ///
  /// Returns 0 if [businessDate] is on or after the effective end.
  static int daysRemainingInCycle(TargetCycle cycle, String businessDate) {
    final end = _parseDate(cycle.effectiveEnd);
    final current = _parseDate(businessDate);
    final diff = end.difference(current).inDays;
    return diff > 0 ? diff : 0;
  }

  static DateTime _parseDate(String isoDate) {
    final parts = isoDate.split('-');
    return DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
