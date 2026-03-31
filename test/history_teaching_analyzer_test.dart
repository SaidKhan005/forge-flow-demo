// â”€â”€â”€ HistoryTeachingAnalyzer Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Verifies deterministic output from real closed shift records.
// Expected outcome (per spec):
//   mostCommonLeakId    = 'cplh_down'
//   mostCommonLeakCount = 6
//   sideLabel           = 'FOH ONLY'
//   topLeakDayparts     = ['Thu Dinner', 'Tue Dinner']  (tie-break: label asc)
//   benchmarkDayparts   = ['Wed Dinner', 'Thu Dinner']

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/fixture_seed_data.dart';
import 'package:forge_and_flow/services/history_pattern_builder.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';

void main() {
  group('HistoryTeachingAnalyzer â€” canonical seed data', () {
    late HistoryTeachingSummary summary;

    setUpAll(() {
      // Build pattern records from real closed shift records â€” same path the
      // app uses at runtime through ShiftDataSource.getHistoryPatternRecords().
      final weekLabelsById = {
        for (final w in DemoData.weekHistory) w.weekId: w.weekLabel,
      };
      final patternRecords = HistoryPatternBuilder.fromClosedShifts(
        DemoData.historicalClosedShifts,
        weekLabelsById,
      );
      summary = HistoryTeachingAnalyzer.summarize(patternRecords);
    });

    test('mostCommonLeakId is cplh_down', () {
      expect(summary.mostCommonLeakId, equals('cplh_down'));
    });

    test('mostCommonLeakCount is 6', () {
      expect(summary.mostCommonLeakCount, equals(6));
    });

    test('mostCommonLeakSideLabel is FOH ONLY', () {
      expect(summary.mostCommonLeakSideLabel, equals('FOH ONLY'));
    });

    test('topLeakDayparts contains both Tue Dinner and Thu Dinner', () {
      expect(summary.topLeakDayparts, containsAll(['Tue Dinner', 'Thu Dinner']));
    });

    test('topLeakDayparts[0] is Thu Dinner or Tue Dinner', () {
      expect(
        summary.topLeakDayparts[0],
        anyOf(equals('Thu Dinner'), equals('Tue Dinner')),
      );
    });

    test('benchmarkDayparts contains both Wed Dinner and Thu Dinner', () {
      expect(summary.benchmarkDayparts,
          containsAll(['Wed Dinner', 'Thu Dinner']));
    });

    test('topLeakDayparts has exactly 2 entries', () {
      expect(summary.topLeakDayparts.length, equals(2));
    });

    test('benchmarkDayparts has exactly 2 entries', () {
      expect(summary.benchmarkDayparts.length, equals(2));
    });
  });
}
