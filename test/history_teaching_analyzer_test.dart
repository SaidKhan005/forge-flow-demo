// â”€â”€â”€ HistoryTeachingAnalyzer Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Verifies deterministic output from real closed shift records.
// Expected outcome (per spec):
//   mostCommonLeakId    = 'cplh_down'
//   mostCommonLeakCount = 18
//   sideLabel           = 'FOH ONLY'
//   topLeakDayparts     = ['Thu Dinner', 'Tue Dinner']  (tie-break: label asc)
//   benchmarkDayparts   = ['Wed Dinner', 'Fri Late Night']
//
// Pinning history:
//   pre-7.58.4 (fill shifts hard-coded as `ON_MODEL`):
//     mostCommonLeakCount = 6, benchmarkDayparts = [Wed Dinner, Thu Dinner]
//   post-7.58.4 (fill shifts round-trip through `LaborModel.determineLever`):
//     fill rows now classify into real lever ids when their rounded
//     CPLH/SPLH/PPA cross the engine's variance thresholds. Across the
//     60-day window this surfaces 18 `cplh_down` records (was 6) and a
//     seven-way tie at 5 for the runner-up benchmark daypart, where
//     `Fri Late Night` wins on alphabetical tie-break.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
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

    test('mostCommonLeakCount is 18', () {
      expect(summary.mostCommonLeakCount, equals(18));
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

    test('benchmarkDayparts contains both Wed Dinner and Fri Late Night', () {
      expect(summary.benchmarkDayparts,
          containsAll(['Wed Dinner', 'Fri Late Night']));
    });

    test('topLeakDayparts has exactly 2 entries', () {
      expect(summary.topLeakDayparts.length, equals(2));
    });

    test('benchmarkDayparts has exactly 2 entries', () {
      expect(summary.benchmarkDayparts.length, equals(2));
    });
  });
}
