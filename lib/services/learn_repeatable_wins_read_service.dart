/// Read service for Learn repeatable win evidence.
///
/// Derives evidence-backed repeatable win summaries from closed shifts
/// via [DaypartPatternSummaryBuilder]. Replaces the frequency-only
/// benchmark-daypart label path for the Repeatable Wins card.
///
/// See phase_7_55k_6_learn_repeatable_wins_upgrade.md.
library;

import '../domain/canonical_day_order.dart';
import '../domain/models/service_period_definition.dart';
import '../models/daypart_pattern_summary.dart';
import '../models/learn_repeatable_win_summary.dart';
import '../models/shift_record.dart';
import '../services/closed_timing_label_resolver.dart';
import '../services/daypart_pattern_summary_builder.dart';

class LearnRepeatableWinsReadService {
  const LearnRepeatableWinsReadService();

  /// Maximum repeatable win entries returned.
  static const maxResults = 3;

  // Canonical service-period sort order for explicit tie-breaking.
  static const _servicePeriodOrder = <String, int>{
    'morning': 0,
    'lunch': 1,
    'dinner': 2,
    'late_night': 3,
  };

  /// Builds ranked repeatable win summaries from historical closed shifts.
  ///
  /// Only buckets with at least one favorable-lever shift AND a non-null
  /// dominant benchmark lever are included.
  /// Ranking: benchmarkCount descending, then closedShiftCount descending,
  /// then canonical day order (Mon-Sun), then service-period order.
  List<LearnRepeatableWinSummary> build(
    List<ShiftRecord> closedShifts, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
    String? currentOperationalBusinessDate,
    DaypartPatternShiftCloseAuthorityResolver? shiftCloseAuthorityForRow,
  }) {
    final summaries = DaypartPatternSummaryBuilder.fromClosedShifts(
      closedShifts,
      timingLabelResolver: timingLabelResolver,
      servicePeriodDefinitions: servicePeriodDefinitions,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
      shiftCloseAuthorityForRow: shiftCloseAuthorityForRow,
    );

    // Filter to buckets with benchmark evidence and a known dominant lever.
    final winBuckets = summaries
        .where(
          (s) => s.benchmarkCount > 0 && s.dominantBenchmarkLeverId != null,
        )
        .toList();

    // Rank: benchmarkCount desc, closedShiftCount desc, then explicit
    // canonical day/daypart order for deterministic tie-breaking.
    winBuckets.sort((a, b) {
      final cmp = b.benchmarkCount.compareTo(a.benchmarkCount);
      if (cmp != 0) return cmp;
      final cmp2 = b.closedShiftCount.compareTo(a.closedShiftCount);
      if (cmp2 != 0) return cmp2;
      final dayA = CanonicalDayOrder.index[a.dayLabel] ?? 99;
      final dayB = CanonicalDayOrder.index[b.dayLabel] ?? 99;
      if (dayA != dayB) return dayA.compareTo(dayB);
      final dpA =
          a.servicePeriodSortOrder ?? _servicePeriodOrder[a.daypart] ?? 99;
      final dpB =
          b.servicePeriodSortOrder ?? _servicePeriodOrder[b.daypart] ?? 99;
      return dpA.compareTo(dpB);
    });

    return winBuckets.take(maxResults).map((s) => _toReadModel(s)).toList();
  }

  static LearnRepeatableWinSummary _toReadModel(DaypartPatternSummary s) {
    return LearnRepeatableWinSummary(
      label: s.fullLabel,
      dominantLeverId: s.dominantBenchmarkLeverId!,
      benchmarkCount: s.benchmarkCount,
      closedShiftCount: s.closedShiftCount,
      avgCPLH: s.avgCPLH,
      avgSPLH: s.avgSPLH,
      avgPPA: s.avgPPA,
      exemplarSourceShiftIds: s.exemplarSourceShiftIds,
    );
  }
}
