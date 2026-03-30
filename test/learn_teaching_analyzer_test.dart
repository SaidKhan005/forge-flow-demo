// Phase 7.14 — Learn Teaching Analyzer Tests
//
// Deterministic tests covering the LearnTeachingAnalyzer which combines
// History pattern analysis with active Baseline truth.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/data/demo_data.dart';
import 'package:forge_flow_demo/data/meridian_data.dart';
import 'package:forge_flow_demo/models/history_pattern_record.dart';
import 'package:forge_flow_demo/services/history_pattern_builder.dart';
import 'package:forge_flow_demo/services/history_teaching_analyzer.dart';
import 'package:forge_flow_demo/services/learn_teaching_analyzer.dart';

void main() {
  setUp(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  // ── A: no history patterns fallback ──────────────────────────────────────

  group('A — no history patterns', () {
    test('empty patterns produce correct fallback values', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
      );

      expect(summary.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(summary.hasHistoryPatterns, isFalse);
      expect(summary.primaryLeakCount, equals(0));
      expect(summary.topLeakDayparts, isEmpty);
      expect(summary.benchmarkDayparts, isEmpty);
      expect(summary.primaryFixLine,
          equals('Keep closing shifts so Learn can detect repeating leaks.'));
      expect(summary.studyLine,
          equals('No benchmark dayparts recorded yet.'));
    });
  });

  // ── B: manager override changes benchmark source label ───────────────────

  group('B — manager override', () {
    test('override active shows MANAGER STAR SHIFTS', () {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228,
            isSelected: true),
      ]);

      final records = _buildPatternRecords();

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
      );

      expect(summary.benchmarkSourceLabel, equals('MANAGER STAR SHIFTS'));
      expect(summary.selectedShiftCount,
          equals(BaselineData.selectedRecordCount));
    });
  });

  // ── C: analyzer uses current baseline targets ────────────────────────────

  group('C — baseline targets', () {
    test('targets match current BaselineData derived values', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _buildPatternRecords(),
        weekCount: 3,
      );

      expect(summary.targetCPLH, equals(BaselineData.derivedTargetCPLH));
      expect(summary.targetSPLH, equals(BaselineData.derivedTargetSPLH));
      expect(summary.targetPPA, equals(BaselineData.derivedTargetPPA));
    });
  });

  // ── D: analyzer reuses HistoryTeachingAnalyzer output ────────────────────

  group('D — history reuse', () {
    test('leak id/count/dayparts match HistoryTeachingAnalyzer output', () {
      final records = _buildPatternRecords();

      final historySummary = HistoryTeachingAnalyzer.summarize(records);
      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
      );

      expect(learnSummary.primaryLeakId,
          equals(historySummary.mostCommonLeakId));
      expect(learnSummary.primaryLeakCount,
          equals(historySummary.mostCommonLeakCount));
      expect(learnSummary.topLeakDayparts,
          equals(historySummary.topLeakDayparts));
      expect(learnSummary.benchmarkDayparts,
          equals(historySummary.benchmarkDayparts));
    });
  });

  // ── E: coach lines are deterministic ─────────────────────────────────────

  group('E — coach lines', () {
    test('non-empty patterns produce non-empty coach lines', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _buildPatternRecords(),
        weekCount: 3,
      );

      expect(summary.primaryFixLine, isNotEmpty);
      expect(summary.studyLine, isNotEmpty);
      expect(summary.coachToLine, isNotEmpty);
      expect(summary.coachToLine, contains('CPLH'));
      expect(summary.coachToLine, contains('SPLH'));
      expect(summary.coachToLine, contains('PPA'));
    });
  });

  // ── F: no benchmark patterns fallback ───────────────────────────────────

  group('F — no benchmark patterns', () {
    test('empty patterns produce correct benchmark fallback values', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
      );

      expect(summary.primaryBenchmarkId, equals(''));
      expect(summary.primaryBenchmarkCount, equals(0));
      expect(summary.hasBenchmarkPatterns, isFalse);
    });
  });

  // ── G: benchmark pattern identity reuses HistoryTeachingAnalyzer ────────

  group('G — benchmark pattern reuse', () {
    test('benchmark id/count/side match HistoryTeachingAnalyzer output', () {
      final records = _buildPatternRecords();

      final historySummary = HistoryTeachingAnalyzer.summarize(records);
      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
      );

      expect(learnSummary.primaryBenchmarkId,
          equals(historySummary.mostCommonBenchmarkId));
      expect(learnSummary.primaryBenchmarkCount,
          equals(historySummary.mostCommonBenchmarkCount));
      expect(learnSummary.primaryBenchmarkSideLabel,
          equals(historySummary.mostCommonBenchmarkSideLabel));
    });
  });

  // ── H: benchmark-pattern flag turns true when benchmark records exist ───

  group('H — benchmark pattern flag', () {
    test('hasBenchmarkPatterns is true when benchmark records exist', () {
      final records = _buildPatternRecords();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
      );

      expect(summary.hasBenchmarkPatterns, isTrue);
    });
  });
}

/// Builds pattern records from the canonical demo seed data.
List<HistoryPatternRecord> _buildPatternRecords() {
  final weekLabelsById = {
    for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
  };
  return HistoryPatternBuilder.fromClosedShifts(
    DemoData.historicalClosedShifts,
    weekLabelsById,
  );
}
