// Phase 7.14 — Learn Teaching Analyzer
// Combines History pattern analysis with benchmark context to produce
// deterministic coaching guidance grounded in Jim Taylor Chapters 9–12.
//
// Phase 7.55l.8a: migrated off direct BaselineData reads. Benchmark
// source label and target metrics now come from injected
// LearnBenchmarkContext, resolved by LearnBenchmarkContextService.

import '../models/cross_axis_pair_record.dart';
import '../models/history_pattern_record.dart';
import '../models/learn_benchmark_context.dart';
import '../models/learn_teaching_summary.dart';
import 'history_teaching_analyzer.dart';

class LearnTeachingAnalyzer {
  LearnTeachingAnalyzer._();

  static LearnTeachingSummary summarize({
    required List<HistoryPatternRecord> patternRecords,
    required int weekCount,
    required LearnBenchmarkContext benchmarkContext,
    // 7.58.3 — denominator for the repeat counter. Production callers
    // pass `closedShifts.length` (the same closed `shift_records`
    // population `HistoryPatternBuilder` consumes), so coverage and
    // repeats read from the same source. Null = unspecified; falls
    // back to `patternRecords.length`, which is itself >=
    // primaryLeakCount, so the documented invariant
    // `coverageCount >= primaryLeakCount` always holds for the
    // returned summary. See Sub-Slice Family `.3` row in
    // `docs/contracts/phase_7_58_primary_driver_contract.md`.
    int? coverageCount,
  }) {
    // 7.58.3 — fallback satisfies the invariant trivially:
    // patternRecords ⊇ leakRecords ⊇ records with the dominant
    // leak id, so patternRecords.length >= primaryLeakCount.
    final effectiveCoverageCount = coverageCount ?? patternRecords.length;
    final historySummary = patternRecords.isEmpty
        ? null
        : HistoryTeachingAnalyzer.summarize(patternRecords);

    final selectedShiftCount = benchmarkContext.selectedShiftCount;
    final targetCPLH = benchmarkContext.targetCPLH;
    final targetSPLH = benchmarkContext.targetSPLH;
    final targetPPA = benchmarkContext.targetPPA;
    final rangeQualityLabel = benchmarkContext.rangeQualityLabel;
    final rangeQualityMessage = benchmarkContext.rangeQualityMessage;
    final benchmarkSourceLabel = benchmarkContext.benchmarkSourceLabel;

    String primaryLeakId;
    String primaryLeakSideLabel;
    int primaryLeakCount;
    List<String> topLeakDayparts;
    List<String> benchmarkDayparts;
    String primaryFixLine;
    String studyLine;
    String primaryBenchmarkId;
    String primaryBenchmarkSideLabel;
    int primaryBenchmarkCount;
    bool hasBenchmarkPatterns;
    List<CrossAxisPairRecord> crossAxisPairs;

    if (historySummary == null) {
      primaryLeakId = '';
      primaryLeakSideLabel = 'No recurring leak yet';
      primaryLeakCount = 0;
      topLeakDayparts = const [];
      benchmarkDayparts = const [];
      primaryFixLine =
          'Keep closing shifts so Learn can detect repeating leaks.';
      studyLine = 'No benchmark dayparts recorded yet.';
      primaryBenchmarkId = '';
      primaryBenchmarkSideLabel = 'No benchmark pattern yet';
      primaryBenchmarkCount = 0;
      hasBenchmarkPatterns = false;
      crossAxisPairs = const [];
    } else {
      primaryLeakId = historySummary.mostCommonLeakId;
      primaryLeakSideLabel = historySummary.mostCommonLeakSideLabel;
      primaryLeakCount = historySummary.mostCommonLeakCount;
      topLeakDayparts = historySummary.topLeakDayparts;
      benchmarkDayparts = historySummary.benchmarkDayparts;
      primaryBenchmarkId = historySummary.mostCommonBenchmarkId;
      primaryBenchmarkSideLabel = historySummary.mostCommonBenchmarkSideLabel;
      primaryBenchmarkCount = historySummary.mostCommonBenchmarkCount;
      hasBenchmarkPatterns = historySummary.mostCommonBenchmarkCount > 0;
      crossAxisPairs = historySummary.crossAxisPairs;

      if (topLeakDayparts.isEmpty) {
        primaryFixLine =
            'Fix ${primaryLeakSideLabel.toLowerCase()} first.';
      } else {
        primaryFixLine =
            'Fix ${primaryLeakSideLabel.toLowerCase()} first in ${topLeakDayparts.join(' / ')}.';
      }

      if (benchmarkDayparts.isEmpty) {
        studyLine = 'No benchmark dayparts recorded yet.';
      } else {
        studyLine =
            'Study benchmark dayparts: ${benchmarkDayparts.join(' / ')}.';
      }
    }

    final coachToLine =
        'Coach to ${targetCPLH.toStringAsFixed(1)} CPLH / '
        '${targetSPLH.toStringAsFixed(0)} SPLH / '
        '${targetPPA.toStringAsFixed(0)} PPA.';

    // 7.58.3 — debug-mode invariant guard. Catches a caller passing
    // an explicit `coverageCount` smaller than the leak count it is
    // supposed to be the denominator for. The fallback path can't
    // trip this; only an explicit too-small value can.
    assert(
      effectiveCoverageCount >= primaryLeakCount,
      '7.58.3 invariant: coverageCount ($effectiveCoverageCount) must '
      'be >= primaryLeakCount ($primaryLeakCount).',
    );

    return LearnTeachingSummary(
      weekCount: weekCount,
      benchmarkSourceLabel: benchmarkSourceLabel,
      selectedShiftCount: selectedShiftCount,
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      targetPPA: targetPPA,
      rangeQualityLabel: rangeQualityLabel,
      rangeQualityMessage: rangeQualityMessage,
      primaryLeakId: primaryLeakId,
      primaryLeakSideLabel: primaryLeakSideLabel,
      primaryLeakCount: primaryLeakCount,
      coverageCount: effectiveCoverageCount,
      topLeakDayparts: topLeakDayparts,
      benchmarkDayparts: benchmarkDayparts,
      primaryFixLine: primaryFixLine,
      studyLine: studyLine,
      coachToLine: coachToLine,
      hasHistoryPatterns: patternRecords.isNotEmpty,
      primaryBenchmarkId: primaryBenchmarkId,
      primaryBenchmarkSideLabel: primaryBenchmarkSideLabel,
      primaryBenchmarkCount: primaryBenchmarkCount,
      hasBenchmarkPatterns: hasBenchmarkPatterns,
      crossAxisPairs: crossAxisPairs,
    );
  }
}
