// 7.58.3 — Learn history coverage denominator
//
// Pins the new `coverageCount` field on `LearnTeachingSummary`: the
// denominator the Learn tab needs to read its leak repeat counter
// honestly ("6 repeats out of how many?"). Coverage = total closed
// `shift_records` rows in the same retention window
// `HistoryPatternBuilder` consumes — same source as the repeat
// counter, by design.
//
// See Sub-Slice Family `.3` row in
// `docs/contracts/phase_7_58_primary_driver_contract.md`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/history_pattern_builder.dart';
import 'package:forge_and_flow/services/learn_teaching_analyzer.dart';

const _ctx = LearnBenchmarkContext(
  benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
  selectedShiftCount: 14,
  targetCPLH: 4.5,
  targetSPLH: 180.0,
  targetPPA: 42.0,
  rangeQualityLabel: 'Good',
  rangeQualityMessage: 'Range is adequate.',
);

void main() {
  group('7.58.3 — coverageCount denominator', () {
    test('zero closed rows → coverageCount is 0 and ≥ primaryLeakCount', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: const [],
        weekCount: 0,
        benchmarkContext: _ctx,
        coverageCount: 0,
      );

      expect(summary.coverageCount, equals(0));
      expect(summary.primaryLeakCount, equals(0));
      expect(
        summary.coverageCount,
        greaterThanOrEqualTo(summary.primaryLeakCount),
      );
    });

    test(
      'positive closed rows → coverageCount equals closed-shift population size',
      () {
        final closedShifts = DemoData.historicalClosedShifts;
        final weekLabelsById = {
          for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
        };
        final patternRecords = HistoryPatternBuilder.fromClosedShifts(
          closedShifts,
          weekLabelsById,
        );

        final summary = LearnTeachingAnalyzer.summarize(
          patternRecords: patternRecords,
          weekCount: DemoData.weekHistory.length,
          benchmarkContext: _ctx,
          coverageCount: closedShifts.length,
        );

        expect(closedShifts, isNotEmpty);
        expect(summary.coverageCount, equals(closedShifts.length));
        expect(summary.coverageCount, greaterThan(0));
      },
    );

    test('coverageCount ≥ primaryLeakCount for the canonical seed scope', () {
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: patternRecords,
        weekCount: DemoData.weekHistory.length,
        benchmarkContext: _ctx,
        coverageCount: closedShifts.length,
      );

      // Pre-fix the Learn tab read "6 repeats" with no denominator.
      // The post-fix invariant guarantees the denominator never falls
      // below the numerator — the population is always at least as
      // large as the count drawn from it.
      expect(summary.primaryLeakCount, greaterThan(0));
      expect(
        summary.coverageCount,
        greaterThanOrEqualTo(summary.primaryLeakCount),
      );
    });

    test('omitted coverageCount falls back to a value that holds the invariant', () {
      // When the caller does not pass coverageCount, the analyzer
      // falls back to patternRecords.length so the documented
      // invariant `coverageCount >= primaryLeakCount` holds without
      // forcing every legacy call site to plumb a coverage value.
      final closedShifts = DemoData.historicalClosedShifts;
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        closedShifts,
        weekLabelsById,
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: patternRecords,
        weekCount: DemoData.weekHistory.length,
        benchmarkContext: _ctx,
        // No coverageCount passed.
      );

      expect(summary.primaryLeakCount, greaterThan(0));
      expect(
        summary.coverageCount,
        greaterThanOrEqualTo(summary.primaryLeakCount),
      );
      // Fallback equals patternRecords.length by construction.
      expect(summary.coverageCount, equals(patternRecords.length));
    });

    test(
      'coverage drawn from same population the repeat counter reads',
      () {
        // The repeat counter (HistoryPatternBuilder → analyzer) and
        // the coverage count both come from the same closed-shift
        // query path. Pattern records are a filtered subset of closed
        // shifts (HistoryPatternBuilder drops on_model + unknown lever
        // rows), so coverageCount must be ≥ patternRecords.length —
        // and patternRecords.length is itself ≥ primaryLeakCount.
        final closedShifts = DemoData.historicalClosedShifts;
        final weekLabelsById = {
          for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
        };
        final patternRecords = HistoryPatternBuilder.fromClosedShifts(
          closedShifts,
          weekLabelsById,
        );

        final summary = LearnTeachingAnalyzer.summarize(
          patternRecords: patternRecords,
          weekCount: DemoData.weekHistory.length,
          benchmarkContext: _ctx,
          coverageCount: closedShifts.length,
        );

        expect(
          summary.coverageCount,
          greaterThanOrEqualTo(patternRecords.length),
        );
        expect(
          patternRecords.length,
          greaterThanOrEqualTo(summary.primaryLeakCount),
        );
      },
    );
  });
}
