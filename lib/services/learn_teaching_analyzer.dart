// Phase 7.14 — Learn Teaching Analyzer
// Combines History pattern analysis with benchmark context to produce
// deterministic coaching guidance grounded in Jim Taylor Chapters 9–12.
//
// Phase 7.55l.8a: migrated off direct BaselineData reads. Benchmark
// source label and target metrics now come from injected
// LearnBenchmarkContext, resolved by LearnBenchmarkContextService.

import '../domain/constants/app_defaults.dart';
import '../models/cross_axis_pair_record.dart';
import '../models/history_pattern_record.dart';
import '../models/learn_benchmark_context.dart';
import '../models/learn_teaching_summary.dart';
import 'history_teaching_analyzer.dart';

class LearnTeachingAnalyzer {
  LearnTeachingAnalyzer._();

  /// Per-Daypart V1 (Slice D, Gap 39) — one training-grade sentence on
  /// how a per-period target is derived and how it relates to the
  /// whole-day number. Decision 13: copy-only narration sharpening, no
  /// UX overhaul. Plain English, reads as operator training, no
  /// engineering jargon (UX Writing Standard). It states how the feature
  /// works, not a recurring pattern, so it is honest in every state
  /// (Metric Honesty) and rides the existing `coachToLine` copy slot.
  static const String _perPeriodDerivationLine =
      'These are your whole-day numbers. Each service period now carries '
      "its own target, set from that period's own benchmark shifts; the "
      'whole-day figure blends those period targets by how busy each '
      'period runs, so one period can leak while the day still looks on '
      'plan.';

  // Plain-English direction for a leak lever, taken from the lever id's
  // own suffix — the same direction the engine already classified. No
  // magnitude is asserted (the analyzer has no per-shift deviation), so
  // the narration stays honest about what the data supports.
  static String _leakDirectionPhrase(String leverId) {
    if (leverId.endsWith('_down')) return 'running low';
    if (leverId.endsWith('_up')) return 'running high';
    if (leverId.endsWith('_over')) return 'running over plan';
    if (leverId.endsWith('_under')) return 'running lean';
    return 'off target';
  }

  // Real seeded recurrence, phrased for an operator. `count` is the
  // number of times the dominant leak repeated in `period`; `weekCount`
  // is the tracked-week denominator. Both come from the analyzer data
  // path — nothing is hardcoded.
  static String _recurrencePhrase(int count, int weekCount) {
    if (weekCount > 0 && count >= weekCount) {
      return 'every one of the last $weekCount tracked weeks';
    }
    if (weekCount > 0) {
      return '$count of the last $weekCount tracked weeks';
    }
    return '$count weeks running';
  }

  static String? _servicePeriodIdForTopLeak({
    required List<HistoryPatternRecord> patternRecords,
    required String leakId,
    required String fullLabel,
  }) {
    if (leakId.isEmpty || fullLabel.isEmpty) return null;
    for (final record in patternRecords) {
      if (!record.isBenchmark &&
          record.leverId == leakId &&
          record.fullLabel == fullLabel) {
        return record.daypart;
      }
    }
    return null;
  }

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
    String? primaryLeakServicePeriodId;
    String? primaryLeakPeriodLabel;

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
      primaryLeakServicePeriodId = null;
      primaryLeakPeriodLabel = null;
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
      primaryLeakPeriodLabel = historySummary.topLeakDaypartLabel.isEmpty
          ? null
          : historySummary.topLeakDaypartLabel;
      primaryLeakServicePeriodId = _servicePeriodIdForTopLeak(
        patternRecords: patternRecords,
        leakId: primaryLeakId,
        fullLabel: historySummary.topLeakDaypartLabel,
      );

      // Per-Daypart V1 (Slice D, Gap 39) — resolve the fix line to the
      // service period the leak actually lives in, with its real seeded
      // recurrence and (when a same-day benchmark exists) the period
      // contrast Decision 13 calls for. Falls back to the existing
      // general copy whenever the period / lever cannot be resolved, so
      // no period is named that the data does not support.
      final periodLabel = historySummary.topLeakDaypartLabel;
      final leakCard = LeverCards.lookup(primaryLeakId);
      if (periodLabel.isNotEmpty && leakCard != null) {
        final direction = _leakDirectionPhrase(primaryLeakId);
        final recurrence = _recurrencePhrase(
          historySummary.topLeakDaypartCount,
          weekCount,
        );
        final contrast = historySummary.contrastBenchmarkDaypartLabel;
        final contrastClause = contrast == null
            ? ''
            : ', while $contrast holds on plan';
        primaryFixLine =
            '${leakCard.shortLabel} is $direction at $periodLabel: it has '
            'leaked $recurrence$contrastClause. Tighten $periodLabel first.';
      } else if (topLeakDayparts.isEmpty) {
        primaryFixLine = 'Fix ${primaryLeakSideLabel.toLowerCase()} first.';
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

    // Per-Daypart V1 (Slice D, Gap 39) — the whole-day coach numbers
    // keep their existing slot; the per-period derivation training line
    // rides the same slot so the operator learns how the targets are
    // built without a new card/section (Decision 13 — no UX overhaul).
    final primaryLeakDaypart = primaryLeakServicePeriodId == null
        ? null
        : benchmarkContext.daypartFor(primaryLeakServicePeriodId);
    final coachTargetCPLH = primaryLeakDaypart?.daypartTargetCPLH ?? targetCPLH;
    final coachTargetSPLH = primaryLeakDaypart?.daypartTargetSPLH ?? targetSPLH;
    final coachTargetPPA = primaryLeakDaypart?.daypartTargetPPA ?? targetPPA;
    final periodName = primaryLeakDaypart == null
        ? null
        : primaryLeakPeriodLabel;
    final coachScope = periodName == null ? '' : ' $periodName';
    final derivationLine = periodName == null
        ? _perPeriodDerivationLine
        : 'These are your $periodName numbers. Each service '
              'period carries its own target, set from that period\'s own '
              'benchmark shifts; the whole-day figure blends those period '
              'targets by how busy each period runs, so one period can leak '
              'while the day still looks on plan.';

    final coachToLine =
        'Coach$coachScope to ${coachTargetCPLH.toStringAsFixed(1)} CPLH / '
        '${coachTargetSPLH.toStringAsFixed(0)} SPLH / '
        '${coachTargetPPA.toStringAsFixed(0)} PPA. '
        '$derivationLine';

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
      dayparts: benchmarkContext.dayparts,
    );
  }
}
