// Phase 7.14 — Learn Teaching Analyzer Tests
//
// Deterministic tests covering the LearnTeachingAnalyzer which combines
// History pattern analysis with benchmark context.
//
// Phase 7.55l.8a: migrated to use LearnBenchmarkContext instead of
// direct BaselineData reads. Source label and target metrics now come
// from injected context.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/history_pattern_builder.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';
import 'package:forge_and_flow/services/learn_benchmark_context_service.dart';
import 'package:forge_and_flow/services/learn_teaching_analyzer.dart';

/// Builds a LearnBenchmarkContext from current BaselineData state.
/// Used to keep existing tests compatible while proving the analyzer
/// no longer reads BaselineData directly.
LearnBenchmarkContext _contextFromBaseline() => LearnBenchmarkContext(
      benchmarkSourceLabel: BaselineData.hasManagerOverride
          ? 'MANAGER STAR SHIFTS'
          : 'SYSTEM BENCHMARK SET',
      selectedShiftCount: BaselineData.selectedRecordCount,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      rangeQualityLabel: BaselineData.baselineRangeValidation.statusLabel,
      rangeQualityMessage: BaselineData.baselineRangeValidation.message,
    );

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
      final ctx = _contextFromBaseline();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
        benchmarkContext: ctx,
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
    test('override context shows MANAGER STAR SHIFTS', () {
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228,
            isSelected: true),
      ]);

      final ctx = _contextFromBaseline();
      final records = _buildPatternRecords();

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
        benchmarkContext: ctx,
      );

      expect(summary.benchmarkSourceLabel, equals('MANAGER STAR SHIFTS'));
      expect(summary.selectedShiftCount, equals(ctx.selectedShiftCount));
    });
  });

  // ── C: analyzer uses injected benchmark targets ─────────────────────────

  group('C — benchmark targets from context', () {
    test('targets match injected context values', () {
      final ctx = _contextFromBaseline();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _buildPatternRecords(),
        weekCount: 3,
        benchmarkContext: ctx,
      );

      expect(summary.targetCPLH, equals(ctx.targetCPLH));
      expect(summary.targetSPLH, equals(ctx.targetSPLH));
      expect(summary.targetPPA, equals(ctx.targetPPA));
    });

    test('custom injected targets override BaselineData values', () {
      final ctx = const LearnBenchmarkContext(
        benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
        selectedShiftCount: 10,
        targetCPLH: 5.0,
        targetSPLH: 200.0,
        targetPPA: 50.0,
        rangeQualityLabel: 'Good',
        rangeQualityMessage: 'Range is adequate.',
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _buildPatternRecords(),
        weekCount: 3,
        benchmarkContext: ctx,
      );

      expect(summary.targetCPLH, equals(5.0));
      expect(summary.targetSPLH, equals(200.0));
      expect(summary.targetPPA, equals(50.0));
      expect(summary.coachToLine, contains('5.0 CPLH'));
      expect(summary.coachToLine, contains('200 SPLH'));
      expect(summary.coachToLine, contains('50 PPA'));
    });
  });

  // ── D: analyzer reuses HistoryTeachingAnalyzer output ────────────────────

  group('D — history reuse', () {
    test('leak id/count/dayparts match HistoryTeachingAnalyzer output', () {
      final records = _buildPatternRecords();
      final ctx = _contextFromBaseline();

      final historySummary = HistoryTeachingAnalyzer.summarize(records);
      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
        benchmarkContext: ctx,
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
      final ctx = _contextFromBaseline();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: _buildPatternRecords(),
        weekCount: 3,
        benchmarkContext: ctx,
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
      final ctx = _contextFromBaseline();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
        benchmarkContext: ctx,
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
      final ctx = _contextFromBaseline();

      final historySummary = HistoryTeachingAnalyzer.summarize(records);
      final learnSummary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
        benchmarkContext: ctx,
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
      final ctx = _contextFromBaseline();
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 3,
        benchmarkContext: ctx,
      );

      expect(summary.hasBenchmarkPatterns, isTrue);
    });
  });

  // ── I: source label mapping — recommended ──────────────────────────────

  group('I — source label mapping', () {
    test('recommended source produces SYSTEM BENCHMARK SET', () {
      final ctx = const LearnBenchmarkContext(
        benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
        selectedShiftCount: 14,
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        rangeQualityLabel: 'Good',
        rangeQualityMessage: 'Range is adequate.',
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
        benchmarkContext: ctx,
      );

      expect(summary.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
    });

    test('manager override source produces MANAGER STAR SHIFTS', () {
      final ctx = const LearnBenchmarkContext(
        benchmarkSourceLabel: 'MANAGER STAR SHIFTS',
        selectedShiftCount: 10,
        targetCPLH: 5.0,
        targetSPLH: 200.0,
        targetPPA: 50.0,
        rangeQualityLabel: 'Good',
        rangeQualityMessage: 'Range is adequate.',
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
        benchmarkContext: ctx,
      );

      expect(summary.benchmarkSourceLabel, equals('MANAGER STAR SHIFTS'));
    });

    test('admin replacement source produces ADMIN REPLACEMENT', () {
      final ctx = const LearnBenchmarkContext(
        benchmarkSourceLabel: 'ADMIN REPLACEMENT',
        selectedShiftCount: 12,
        targetCPLH: 4.8,
        targetSPLH: 190.0,
        targetPPA: 45.0,
        rangeQualityLabel: 'Good',
        rangeQualityMessage: 'Range is adequate.',
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 0,
        benchmarkContext: ctx,
      );

      expect(summary.benchmarkSourceLabel, equals('ADMIN REPLACEMENT'));
    });
  });

  // ── J: service source label mapping ──────────────────────────────────────

  group('J — service source label mapping', () {
    test('system_baseline maps to SYSTEM BENCHMARK SET', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'system_baseline'),
        equals('SYSTEM BENCHMARK SET'),
      );
    });

    test('cycle_recommended maps to SYSTEM BENCHMARK SET', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'cycle_recommended'),
        equals('SYSTEM BENCHMARK SET'),
      );
    });

    test('manager_override maps to MANAGER STAR SHIFTS', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'manager_override'),
        equals('MANAGER STAR SHIFTS'),
      );
    });

    test('cycle_manager_override maps to MANAGER STAR SHIFTS', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'cycle_manager_override'),
        equals('MANAGER STAR SHIFTS'),
      );
    });

    test('admin_replacement maps to ADMIN REPLACEMENT', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'admin_replacement'),
        equals('ADMIN REPLACEMENT'),
      );
    });

    test('cycle_admin_replacement maps to ADMIN REPLACEMENT', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'cycle_admin_replacement'),
        equals('ADMIN REPLACEMENT'),
      );
    });

    test('unknown source type falls back to SYSTEM BENCHMARK SET', () {
      expect(
        LearnBenchmarkContextService.sourceLabelFromProfileType(
            'something_unknown'),
        equals('SYSTEM BENCHMARK SET'),
      );
    });
  });

  // ── K: service fallback semantics (7.55l.8a1) ────────────────────────────

  group('K — service fallback semantics', () {
    tearDown(() {
      LearnBenchmarkContextService.testCanonicalOverride = null;
      LearnBenchmarkContextService.disableBridgeOnly();
    });

    test('bridge-only mode returns bridge context cleanly', () async {
      LearnBenchmarkContextService.enableBridgeOnly();
      final ctx =
          await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
    });

    test('null profile bootstrap returns bridge context', () async {
      LearnBenchmarkContextService.testCanonicalOverride =
          () async => null;
      final ctx =
          await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
    });

    test('canonical override returns injected context', () async {
      LearnBenchmarkContextService.testCanonicalOverride =
          () async => const LearnBenchmarkContext(
                benchmarkSourceLabel: 'ADMIN REPLACEMENT',
                selectedShiftCount: 5,
                targetCPLH: 9.9,
                targetSPLH: 300.0,
                targetPPA: 60.0,
                rangeQualityLabel: 'Test',
                rangeQualityMessage: 'Test message.',
              );
      final ctx =
          await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('ADMIN REPLACEMENT'));
      expect(ctx.targetCPLH, equals(9.9));
    });

    test('repository error propagates instead of silent fallback', () async {
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        throw StateError('simulated repository failure');
      };
      expect(
        () => LearnBenchmarkContextService.instance.resolve(),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── L: analyzer does not import BaselineData ────────────────────────────

  group('L — BaselineData independence', () {
    test('analyzer produces valid output with fully synthetic context', () {
      // This test proves the analyzer works with a completely synthetic
      // LearnBenchmarkContext — no BaselineData state needed at all.
      final ctx = const LearnBenchmarkContext(
        benchmarkSourceLabel: 'ADMIN REPLACEMENT',
        selectedShiftCount: 7,
        targetCPLH: 6.0,
        targetSPLH: 250.0,
        targetPPA: 55.0,
        rangeQualityLabel: 'Excellent',
        rangeQualityMessage: 'Wide stable range.',
      );

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: [],
        weekCount: 5,
        benchmarkContext: ctx,
      );

      expect(summary.weekCount, equals(5));
      expect(summary.benchmarkSourceLabel, equals('ADMIN REPLACEMENT'));
      expect(summary.selectedShiftCount, equals(7));
      expect(summary.targetCPLH, equals(6.0));
      expect(summary.targetSPLH, equals(250.0));
      expect(summary.targetPPA, equals(55.0));
      expect(summary.rangeQualityLabel, equals('Excellent'));
      expect(summary.rangeQualityMessage, equals('Wide stable range.'));
      expect(summary.coachToLine, contains('6.0 CPLH'));
      expect(summary.coachToLine, contains('250 SPLH'));
      expect(summary.coachToLine, contains('55 PPA'));
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
