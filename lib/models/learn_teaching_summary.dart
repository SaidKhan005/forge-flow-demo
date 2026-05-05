// Phase 7.14 — Learn Teaching Summary
// Immutable model combining History pattern analysis with active Baseline truth.

import 'cross_axis_pair_record.dart';

class LearnTeachingSummary {
  final int weekCount;
  final String benchmarkSourceLabel;
  final int selectedShiftCount;
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final String rangeQualityLabel;
  final String rangeQualityMessage;
  final String primaryLeakId;
  final String primaryLeakSideLabel;
  final int primaryLeakCount;

  /// 7.58.3 — denominator for [primaryLeakCount].
  ///
  /// Total count of closed `shift_records` rows in the same retention
  /// window the repeat-counter scopes to (restaurant + daypart +
  /// day-of-week universe). Adds the missing "out of how many" so a
  /// claim like "leak repeated 6 times" can be read against the
  /// population it was drawn from.
  ///
  /// Invariant (enforced by [LearnTeachingAnalyzer.summarize]):
  /// `coverageCount >= primaryLeakCount`. See Sub-Slice Family `.3`
  /// row in `docs/contracts/phase_7_58_primary_driver_contract.md`.
  final int coverageCount;
  final List<String> topLeakDayparts;
  final List<String> benchmarkDayparts;
  final String primaryFixLine;
  final String studyLine;
  final String coachToLine;
  final bool hasHistoryPatterns;
  final String primaryBenchmarkId;
  final String primaryBenchmarkSideLabel;
  final int primaryBenchmarkCount;
  final bool hasBenchmarkPatterns;

  /// 7.58.cross-axis.0 — recurring CPLH x SPLH pair patterns observed
  /// across the closed-shift history window. Sorted by `count`
  /// descending. Empty when no (week, daypart) bucket fired both axes.
  /// Wave B (`7.58.UX.7+9`) consumes this to swap the Learn carousel
  /// data source from `LeverCards` to `CrossAxisPairs` when a recurring
  /// pair pattern is present.
  final List<CrossAxisPairRecord> crossAxisPairs;

  const LearnTeachingSummary({
    required this.weekCount,
    required this.benchmarkSourceLabel,
    required this.selectedShiftCount,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.rangeQualityLabel,
    required this.rangeQualityMessage,
    required this.primaryLeakId,
    required this.primaryLeakSideLabel,
    required this.primaryLeakCount,
    required this.coverageCount,
    required this.topLeakDayparts,
    required this.benchmarkDayparts,
    required this.primaryFixLine,
    required this.studyLine,
    required this.coachToLine,
    required this.hasHistoryPatterns,
    required this.primaryBenchmarkId,
    required this.primaryBenchmarkSideLabel,
    required this.primaryBenchmarkCount,
    required this.hasBenchmarkPatterns,
    this.crossAxisPairs = const [],
  });
}
