/// Pure rule helper for [WeeklyPlanSnapshot] contract-level questions.
///
/// Covers week-span derivation, deterministic week identity, active-window
/// detection, and generation eligibility. No persistence, no side effects.
///
/// Phase 7.55l.6a: contract only.
library;

import '../models/weekly_plan_snapshot.dart';

class WeeklyPlanSnapshotPolicy {
  const WeeklyPlanSnapshotPolicy._();

  /// Derives the business-week start date for [businessDate].
  ///
  /// [weekStartDay] is a [DateTime] weekday constant (1 = Monday, 7 = Sunday).
  /// Defaults to [DateTime.monday].
  static String weekStartForDate(
    String businessDate, {
    int weekStartDay = DateTime.monday,
  }) {
    final date = _parseDate(businessDate);
    final daysBack = (date.weekday - weekStartDay) % 7;
    return _formatDate(date.subtract(Duration(days: daysBack)));
  }

  /// Derives the business-week end date for [businessDate].
  ///
  /// Always 6 days after the week start (7-day span inclusive).
  static String weekEndForDate(
    String businessDate, {
    int weekStartDay = DateTime.monday,
  }) {
    final start =
        _parseDate(weekStartForDate(businessDate, weekStartDay: weekStartDay));
    return _formatDate(start.add(const Duration(days: 6)));
  }

  /// Derives a deterministic week key from a week span.
  ///
  /// Format: `{weekStartDate}_{weekEndDate}`.
  static String weekKeyFromSpan(String weekStart, String weekEnd) {
    return '${weekStart}_$weekEnd';
  }

  /// Derives a deterministic week key for [businessDate].
  ///
  /// Convenience method combining [weekStartForDate], [weekEndForDate],
  /// and [weekKeyFromSpan].
  static String weekKeyForDate(
    String businessDate, {
    int weekStartDay = DateTime.monday,
  }) {
    return weekKeyFromSpan(
      weekStartForDate(businessDate, weekStartDay: weekStartDay),
      weekEndForDate(businessDate, weekStartDay: weekStartDay),
    );
  }

  /// Whether [snapshot] is the active plan for [businessDate].
  ///
  /// A snapshot is active when the business date falls within
  /// [weekStartDate, weekEndDate] inclusive.
  static bool isActiveForDate(
    WeeklyPlanSnapshot snapshot,
    String businessDate,
  ) {
    return businessDate.compareTo(snapshot.weekStartDate) >= 0 &&
        businessDate.compareTo(snapshot.weekEndDate) <= 0;
  }

  /// Whether the app should generate a snapshot for [businessDate].
  ///
  /// Returns true when no snapshot covers the current business week:
  /// - [existingSnapshot] is null, or
  /// - [existingSnapshot] belongs to a different week than [businessDate]
  static bool shouldGenerate({
    required String businessDate,
    required WeeklyPlanSnapshot? existingSnapshot,
    int weekStartDay = DateTime.monday,
  }) {
    if (existingSnapshot == null) return true;
    final currentWeekKey =
        weekKeyForDate(businessDate, weekStartDay: weekStartDay);
    return existingSnapshot.weekKey != currentWeekKey;
  }

  /// Whether an existing [snapshot] remains valid for [businessDate]
  /// even if the target cycle refreshes midweek.
  ///
  /// The locked weekly plan does not rewrite midweek. If the 60-day
  /// target cycle refreshes during a week, the new cycle affects the
  /// next generated week, not the already locked week in force.
  static bool snapshotRemainsValidDespiteCycleRefresh({
    required WeeklyPlanSnapshot snapshot,
    required String businessDate,
  }) {
    return isActiveForDate(snapshot, businessDate);
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  static DateTime _parseDate(String isoDate) {
    final parts = isoDate.split('-');
    return DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
