// Phase 7.55e.1 — Builds ScheduleDistributionWeights from closed ShiftRecords.
//
// Pure domain service. No UI, no BaselineData, no schedule_builder dependency.
// Uses weekId + dayLabel as temporary business-day key until 7.55f adds
// business_date.

import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/models/shift_record.dart';

class DistributionWeightBuilder {
  /// Build distribution weights from a list of ShiftRecords.
  ///
  /// Only closed shifts contribute. Covers <= 0 are excluded from weight
  /// totals but the shift still counts toward closedShiftCount and distinct
  /// business-day count.
  ///
  /// Returns an unavailable result (with diagnostic counts preserved) when
  /// fewer than [minClosedBusinessDays] distinct closed business days exist,
  /// or when no positive covers are found.
  static ScheduleDistributionWeights fromClosedShifts(
    List<ShiftRecord> shifts, {
    int minClosedBusinessDays = 14,
  }) {
    // 1. Filter to closed shifts only.
    final closed = shifts.where((s) => s.isClosed).toList();
    final closedShiftCount = closed.length;

    // 2. Count distinct business days (weekId|dayLabel).
    final businessDayKeys = <String>{};
    for (final s in closed) {
      businessDayKeys.add('${s.weekId}|${s.dayLabel}');
    }
    final closedBusinessDayCount = businessDayKeys.length;

    // 3. Accumulate cover weights from positive-cover closed shifts.
    final dayWeights = <String, int>{};
    final daypartWeightsByDay = <String, Map<String, int>>{};
    var totalCovers = 0;

    for (final s in closed) {
      if (s.covers <= 0) continue;

      totalCovers += s.covers;

      // Day-level weight.
      dayWeights[s.dayLabel] = (dayWeights[s.dayLabel] ?? 0) + s.covers;

      // Daypart-level weight within the day.
      final dayparts = daypartWeightsByDay.putIfAbsent(
        s.dayLabel,
        () => <String, int>{},
      );
      dayparts[s.daypart] = (dayparts[s.daypart] ?? 0) + s.covers;
    }

    // 4. Determine availability.
    final isAvailable = closedBusinessDayCount >= minClosedBusinessDays &&
        totalCovers > 0 &&
        dayWeights.isNotEmpty;

    if (!isAvailable) {
      return ScheduleDistributionWeights.unavailable(
        closedShiftCount: closedShiftCount,
        closedBusinessDayCount: closedBusinessDayCount,
        totalCovers: totalCovers,
      );
    }

    return ScheduleDistributionWeights.available(
      dayWeights: dayWeights,
      daypartWeightsByDay: daypartWeightsByDay,
      closedShiftCount: closedShiftCount,
      closedBusinessDayCount: closedBusinessDayCount,
      totalCovers: totalCovers,
    );
  }
}
