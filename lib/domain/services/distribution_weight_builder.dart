// Phase 7.55e.1 + 7.55l.5d — Builds ScheduleDistributionWeights from closed
// ShiftRecords.
//
// Pure domain service. No UI, no BaselineData, no schedule_builder dependency.
//
// Two builder paths:
//   - fromClosedShifts(): legacy weekId-based builder (compatibility)
//   - fromDateWindowShifts(): date-anchored 60-day + 21-day smoothed builder
//
// The date-window builder computes day-of-week shares from both windows
// and applies half-adjustment smoothing:
//   resolvedShare = baselineShare + ((recentShare - baselineShare) / 2)

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

  /// Build distribution weights from date-windowed closed shifts with
  /// day-of-week smoothing.
  ///
  /// [baselineShifts] — closed shifts from the 60-day baseline window.
  /// [recentShifts] — closed shifts from the 21-day recent window.
  ///
  /// Day-of-week smoothing rule:
  ///   - Compute baseline share per day from 60-day positive-cover shifts.
  ///   - Compute recent share per day from 21-day positive-cover shifts.
  ///   - When recent window has positive-cover shifts:
  ///       resolvedShare = baselineShare + ((recentShare - baselineShare) / 2)
  ///   - Otherwise: resolvedShare = baselineShare.
  ///   - Convert shares to integer weights: (resolvedShare * 1000).round()
  ///
  /// Daypart subrow weights come from the 60-day baseline only (transitional).
  ///
  /// Returns unavailable when:
  ///   - fewer than [minClosedBusinessDays] distinct closed business days, or
  ///   - no positive covers in baseline window.
  static ScheduleDistributionWeights fromDateWindowShifts({
    required List<ShiftRecord> baselineShifts,
    required List<ShiftRecord> recentShifts,
    int minClosedBusinessDays = 14,
  }) {
    // ── Count closed shifts and distinct business days ────────────────────
    final allClosed = <ShiftRecord>[
      ...baselineShifts.where((s) => s.isClosed),
    ];
    final closedShiftCount = allClosed.length;

    final businessDateKeys = <String>{};
    for (final s in allClosed) {
      final key = s.businessDate ?? '${s.weekId}|${s.dayLabel}';
      businessDateKeys.add(key);
    }
    final closedBusinessDayCount = businessDateKeys.length;

    // ── Baseline day-of-week totals (60-day) ─────────────────────────────
    final baselineDayTotals = <String, int>{};
    var baselineTotalCovers = 0;
    final daypartWeightsByDay = <String, Map<String, int>>{};

    for (final s in allClosed) {
      if (s.covers <= 0) continue;
      baselineTotalCovers += s.covers;
      baselineDayTotals[s.dayLabel] =
          (baselineDayTotals[s.dayLabel] ?? 0) + s.covers;

      // Daypart subrow weights: 60-day baseline only (transitional).
      final dayparts = daypartWeightsByDay.putIfAbsent(
        s.dayLabel,
        () => <String, int>{},
      );
      dayparts[s.daypart] = (dayparts[s.daypart] ?? 0) + s.covers;
    }

    // ── Availability check ───────────────────────────────────────────────
    if (closedBusinessDayCount < minClosedBusinessDays ||
        baselineTotalCovers <= 0 ||
        baselineDayTotals.isEmpty) {
      return ScheduleDistributionWeights.unavailable(
        closedShiftCount: closedShiftCount,
        closedBusinessDayCount: closedBusinessDayCount,
        totalCovers: baselineTotalCovers,
      );
    }

    // ── Baseline day shares ──────────────────────────────────────────────
    final baselineShares = <String, double>{};
    for (final entry in baselineDayTotals.entries) {
      baselineShares[entry.key] = entry.value / baselineTotalCovers;
    }

    // ── Recent day-of-week totals (21-day) ───────────────────────────────
    final recentClosed = recentShifts.where((s) => s.isClosed).toList();
    final recentDayTotals = <String, int>{};
    var recentTotalCovers = 0;

    for (final s in recentClosed) {
      if (s.covers <= 0) continue;
      recentTotalCovers += s.covers;
      recentDayTotals[s.dayLabel] =
          (recentDayTotals[s.dayLabel] ?? 0) + s.covers;
    }

    // ── Resolve day weights with smoothing ───────────────────────────────
    final resolvedDayWeights = <String, int>{};
    final hasRecentData = recentTotalCovers > 0 && recentDayTotals.isNotEmpty;

    for (final day in ScheduleDistributionWeights.canonicalDayOrder) {
      final baselineShare = baselineShares[day] ?? 0.0;

      double resolvedShare;
      if (hasRecentData) {
        final recentShare = recentTotalCovers > 0
            ? (recentDayTotals[day] ?? 0) / recentTotalCovers
            : 0.0;
        resolvedShare =
            baselineShare + ((recentShare - baselineShare) / 2);
      } else {
        resolvedShare = baselineShare;
      }

      // Convert to integer weight: multiply by 1000 for precision.
      final weight = (resolvedShare * 1000).round();
      if (weight > 0) {
        resolvedDayWeights[day] = weight;
      }
    }

    return ScheduleDistributionWeights.available(
      dayWeights: resolvedDayWeights,
      daypartWeightsByDay: daypartWeightsByDay,
      closedShiftCount: closedShiftCount,
      closedBusinessDayCount: closedBusinessDayCount,
      totalCovers: baselineTotalCovers,
    );
  }
}
