/// Read service for History benchmark daypart evidence.
///
/// Derives evidence-backed benchmark daypart summaries from closed shifts
/// via [DaypartPatternSummaryBuilder]. Replaces the frequency-only label
/// path for the History teaching card's benchmark section.
///
/// See phase_7_55k_5_history_benchmark_dayparts_upgrade.md.
library;

import '../domain/canonical_day_order.dart';
import '../models/daypart_pattern_summary.dart';
import '../models/history_benchmark_daypart_summary.dart';
import '../models/shift_record.dart';
import '../services/closed_timing_label_resolver.dart';
import '../services/daypart_evidence_visibility_policy.dart';
import '../services/daypart_pattern_summary_builder.dart';

class HistoryBenchmarkDaypartReadService {
  const HistoryBenchmarkDaypartReadService();

  /// Maximum benchmark daypart entries returned.
  static const maxResults = 3;

  // Canonical service-period sort order for explicit tie-breaking.
  // Matches DaypartPatternSummaryBuilder's ordering so ties resolve
  // to the same canonical day/daypart sequence.
  static const _servicePeriodOrder = <String, int>{
    'morning': 0,
    'lunch': 1,
    'dinner': 2,
    'late_night': 3,
  };

  /// Builds ranked benchmark daypart summaries from historical closed shifts.
  ///
  /// Only buckets with at least one favorable-lever shift are included.
  /// Ranking: benchmarkCount descending, then closedShiftCount descending,
  /// then canonical day order (Mon–Sun), then service-period order.
  List<HistoryBenchmarkDaypartSummary> build(
    List<ShiftRecord> closedShifts, {
    ClosedTimingLabelResolver? timingLabelResolver,
    String? currentOperationalBusinessDate,
    DaypartPatternShiftCloseAuthorityResolver? shiftCloseAuthorityForRow,
  }) {
    final summaries = DaypartPatternSummaryBuilder.fromClosedShifts(
      closedShifts,
      timingLabelResolver: timingLabelResolver,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
      shiftCloseAuthorityForRow: shiftCloseAuthorityForRow,
    );

    // Filter to buckets with benchmark evidence.
    final benchmarkBuckets = summaries
        .where((s) => s.benchmarkCount > 0)
        .toList();

    // Rank: benchmarkCount desc, closedShiftCount desc, then explicit
    // canonical day/daypart order for deterministic tie-breaking.
    benchmarkBuckets.sort((a, b) {
      final cmp = b.benchmarkCount.compareTo(a.benchmarkCount);
      if (cmp != 0) return cmp;
      final cmp2 = b.closedShiftCount.compareTo(a.closedShiftCount);
      if (cmp2 != 0) return cmp2;
      // Explicit canonical tie-break: day order (Mon–Sun).
      final dayA = CanonicalDayOrder.index[a.dayLabel] ?? 99;
      final dayB = CanonicalDayOrder.index[b.dayLabel] ?? 99;
      if (dayA != dayB) return dayA.compareTo(dayB);
      // Then service-period order.
      final dpA = _servicePeriodOrder[a.daypart] ?? 99;
      final dpB = _servicePeriodOrder[b.daypart] ?? 99;
      return dpA.compareTo(dpB);
    });

    // Classify tiers before truncation so strong benchmark evidence is
    // not displaced by higher-ranked thin-sample buckets (7.55k.7a).
    final strong = <DaypartPatternSummary>[];
    final earlySignal = <DaypartPatternSummary>[];
    for (final b in benchmarkBuckets) {
      final tier = DaypartEvidenceVisibilityPolicy.classifyBenchmark(
        benchmarkCount: b.benchmarkCount,
        closedShiftCount: b.closedShiftCount,
      );
      if (tier == EvidenceTier.strong) {
        strong.add(b);
      } else if (tier == EvidenceTier.earlySignal) {
        earlySignal.add(b);
      }
    }

    // Strong first, then fill remaining slots with early signals.
    final prioritized = [...strong, ...earlySignal];
    return prioritized.take(maxResults).map((s) => _toReadModel(s)).toList();
  }

  static HistoryBenchmarkDaypartSummary _toReadModel(DaypartPatternSummary s) {
    return HistoryBenchmarkDaypartSummary(
      label: s.fullLabel,
      benchmarkCount: s.benchmarkCount,
      closedShiftCount: s.closedShiftCount,
      avgCPLH: s.avgCPLH,
      avgSPLH: s.avgSPLH,
      exemplarSourceShiftIds: s.exemplarSourceShiftIds,
    );
  }
}
