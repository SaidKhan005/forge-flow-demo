// Phase 7.14 — Learn Teaching Analyzer
// Combines History pattern analysis with active Baseline truth to produce
// deterministic coaching guidance grounded in Jim Taylor Chapters 9–12.
//
// Compatibility bridge: still reads BaselineData for benchmark context
// (selectedRecordCount, rangeValidation, hasManagerOverride, derived targets).
// Not canonical authority — persisted ActiveTargetProfile is canonical.
// Pending later retirement when Learn migrates to repository-backed state.

import '../data/legacy_fixture_data.dart';
import '../models/history_pattern_record.dart';
import '../models/learn_teaching_summary.dart';
import 'history_teaching_analyzer.dart';

class LearnTeachingAnalyzer {
  LearnTeachingAnalyzer._();

  static LearnTeachingSummary summarize({
    required List<HistoryPatternRecord> patternRecords,
    required int weekCount,
  }) {
    final historySummary = patternRecords.isEmpty
        ? null
        : HistoryTeachingAnalyzer.summarize(patternRecords);

    final selectedShiftCount = BaselineData.selectedRecordCount;
    final targetCPLH = BaselineData.derivedTargetCPLH;
    final targetSPLH = BaselineData.derivedTargetSPLH;
    final targetPPA = BaselineData.derivedTargetPPA;
    final rangeQualityLabel =
        BaselineData.baselineRangeValidation.statusLabel;
    final rangeQualityMessage =
        BaselineData.baselineRangeValidation.message;
    final benchmarkSourceLabel = BaselineData.hasManagerOverride
        ? 'MANAGER STAR SHIFTS'
        : 'SYSTEM BENCHMARK SET';

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
    );
  }
}
