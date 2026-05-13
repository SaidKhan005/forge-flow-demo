// 7.58.cross-axis.0 — recurring CPLH x SPLH pair pattern detector.
//
// Pins:
//   * Single-axis-only fixtures produce an empty `crossAxisPairs`
//     list (the existing single-axis path continues to fire). The
//     pre-7.58.cross-axis.0 analyzer had no cross-axis field at all,
//     so any non-empty `crossAxisPairs` here also proves the new
//     field is wired without disturbing the single-axis path.
//   * A bucket where both `cplh_*` and `splh_*` lever ids fire is
//     classified into the matching cell from
//     `lib/domain/constants/cross_axis_pair_catalog.dart`. Records contributed
//     by the bucket roll into the cell's `count` and `topDayparts`.
//   * Tie-break ordering on the returned list is deterministic
//     (`count` desc, `pairId` asc).
//   * The new catalog file contains zero em dashes anywhere
//     (operator-facing copy honors the depth-wave em-dash ban).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/cross_axis_pair_catalog.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/services/history_teaching_analyzer.dart';
import 'package:forge_and_flow/services/learn_teaching_analyzer.dart';

HistoryPatternRecord _r({
  required String week,
  required String day,
  required String daypart,
  required String leverId,
  bool isBenchmark = false,
}) {
  return HistoryPatternRecord(
    weekId: week,
    weekLabel: week,
    dayLabel: day,
    daypart: daypart,
    leverId: leverId,
    isBenchmark: isBenchmark,
  );
}

void main() {
  group('7.58.cross-axis.0 — detector returns empty for single-axis-only sets',
      () {
    test('all cplh_down, no splh axis → no pair patterns', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W2', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W2', day: 'Tue', daypart: 'dinner', leverId: 'cplh_down'),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);

      expect(summary.crossAxisPairs, isEmpty);
      // Single-axis path still fires.
      expect(summary.mostCommonLeakId, equals('cplh_down'));
    });

    test('non-CPLH non-SPLH levers (covers/ppa/wage) → no pair patterns', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'covers_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'ppa_down'),
        _r(week: 'W1', day: 'Wed', daypart: 'lunch', leverId: 'foh_wage_up'),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);
      expect(summary.crossAxisPairs, isEmpty);
    });

    test('single bucket with only cplh_* records → no pair pattern', () {
      // Even though Mon and Tue both fire CPLH-axis, no SPLH lever
      // appears in the (W1, lunch) bucket — pair rule does not fire.
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_up'),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);
      expect(summary.crossAxisPairs, isEmpty);
    });

    test(
        'cplh and splh in DIFFERENT (week, daypart) buckets → no pair pattern',
        () {
      // CPLH fires in (W1, lunch); SPLH fires in (W1, dinner). They
      // do not share a (week, daypart) bucket, so no pair forms.
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W1',
          day: 'Tue',
          daypart: 'dinner',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);
      expect(summary.crossAxisPairs, isEmpty);
    });
  });

  group('7.58.cross-axis.0 — CPLH-below + SPLH-above pair counted across week',
      () {
    test(
        'one bucket with 3 cplh_down + 2 splh_up → 5 contributing records, '
        'cell = cplh_below_splh_above', () {
      // Bucket (W1, lunch). 3 dayLabels fire cplh_down, 2 fire splh_up.
      // Total contributing records = 5.
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Wed', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W1',
          day: 'Thu',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
        _r(
          week: 'W1',
          day: 'Fri',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);

      expect(summary.crossAxisPairs.length, equals(1));
      final pair = summary.crossAxisPairs.first;
      expect(pair.pairId, equals(CrossAxisPairs.cplhBelowSplhAbove.id));
      expect(pair.count, equals(5));
      // topDayparts populated; the bucket is all-Lunch so labels share
      // the daypart suffix.
      for (final label in pair.topDayparts) {
        expect(label.endsWith('Lunch'), isTrue,
            reason: 'topDaypart "$label" should end in "Lunch"');
      }
    });

    test('multiple weeks contribute to the same cell, count aggregates', () {
      final records = <HistoryPatternRecord>[
        // W1 lunch: cplh_down + splh_up.
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W1',
          day: 'Wed',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
        // W2 lunch: cplh_down + splh_up.
        _r(week: 'W2', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W2',
          day: 'Wed',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);

      expect(summary.crossAxisPairs.length, equals(1));
      final pair = summary.crossAxisPairs.first;
      expect(pair.pairId, equals(CrossAxisPairs.cplhBelowSplhAbove.id));
      expect(pair.count, equals(4));
      // Tue Lunch and Wed Lunch each repeat across weeks; both should
      // show up in the top 2.
      expect(pair.topDayparts, containsAll(['Tue Lunch', 'Wed Lunch']));
    });
  });

  group('7.58.cross-axis.0 — additional cells fire under their combinations',
      () {
    test('cplh_up + splh_down → cplh_above_splh_below cell', () {
      final records = <HistoryPatternRecord>[
        _r(
          week: 'W1',
          day: 'Mon',
          daypart: 'dinner',
          leverId: 'cplh_up',
          isBenchmark: true,
        ),
        _r(week: 'W1', day: 'Tue', daypart: 'dinner', leverId: 'splh_down'),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);

      expect(summary.crossAxisPairs.length, equals(1));
      expect(
        summary.crossAxisPairs.first.pairId,
        equals(CrossAxisPairs.cplhAboveSplhBelow.id),
      );
    });

    test('cplh_down + splh_down → both_below cell', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'dinner', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'dinner', leverId: 'splh_down'),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);

      expect(summary.crossAxisPairs.length, equals(1));
      expect(
        summary.crossAxisPairs.first.pairId,
        equals(CrossAxisPairs.bothBelow.id),
      );
    });

    test(
        'cplh_up + splh_up → no record (combination outside locked V1 catalog)',
        () {
      final records = <HistoryPatternRecord>[
        _r(
          week: 'W1',
          day: 'Mon',
          daypart: 'dinner',
          leverId: 'cplh_up',
          isBenchmark: true,
        ),
        _r(
          week: 'W1',
          day: 'Tue',
          daypart: 'dinner',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);
      expect(summary.crossAxisPairs, isEmpty);
    });
  });

  group('7.58.cross-axis.0 — return list ordering is deterministic', () {
    test('multiple cells: sorted by count desc, then pairId asc', () {
      // both_below cell will have 4 records, cplh_above_splh_below
      // will have 2 records, cplh_below_splh_above will have 2.
      final records = <HistoryPatternRecord>[
        // Bucket A: (W1, lunch) → both_below, 4 records.
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Wed', daypart: 'lunch', leverId: 'splh_down'),
        _r(week: 'W1', day: 'Thu', daypart: 'lunch', leverId: 'splh_down'),
        // Bucket B: (W2, dinner) → cplh_above_splh_below, 2 records.
        _r(
          week: 'W2',
          day: 'Mon',
          daypart: 'dinner',
          leverId: 'cplh_up',
          isBenchmark: true,
        ),
        _r(week: 'W2', day: 'Tue', daypart: 'dinner', leverId: 'splh_down'),
        // Bucket C: (W3, lunch) → cplh_below_splh_above, 2 records.
        _r(week: 'W3', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W3',
          day: 'Tue',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final summary = HistoryTeachingAnalyzer.summarize(records);
      final ids = summary.crossAxisPairs.map((p) => p.pairId).toList();
      final counts = summary.crossAxisPairs.map((p) => p.count).toList();

      expect(summary.crossAxisPairs.length, equals(3));
      // both_below has the highest count (4).
      expect(ids.first, equals(CrossAxisPairs.bothBelow.id));
      expect(counts.first, equals(4));
      // The two ties at count=2 sort by pairId asc:
      // 'cplh_above_splh_below' < 'cplh_below_splh_above'.
      expect(ids[1], equals(CrossAxisPairs.cplhAboveSplhBelow.id));
      expect(ids[2], equals(CrossAxisPairs.cplhBelowSplhAbove.id));
      expect(counts[1], equals(2));
      expect(counts[2], equals(2));
    });

    test('idempotent: same input → same output (no hidden randomness)', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W1',
          day: 'Wed',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
        _r(
          week: 'W1',
          day: 'Thu',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final a = HistoryTeachingAnalyzer.summarize(records);
      final b = HistoryTeachingAnalyzer.summarize(records);
      expect(a.crossAxisPairs.length, equals(b.crossAxisPairs.length));
      for (var i = 0; i < a.crossAxisPairs.length; i++) {
        expect(a.crossAxisPairs[i].pairId, equals(b.crossAxisPairs[i].pairId));
        expect(a.crossAxisPairs[i].count, equals(b.crossAxisPairs[i].count));
        expect(
          a.crossAxisPairs[i].topDayparts,
          equals(b.crossAxisPairs[i].topDayparts),
        );
      }
    });
  });

  group(
      '7.58.cross-axis.0 — LearnTeachingSummary threads crossAxisPairs from '
      'the analyzer (Wave B consumer dependency)', () {
    const ctx = LearnBenchmarkContext(
      benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
      selectedShiftCount: 14,
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      rangeQualityLabel: 'Good',
      rangeQualityMessage: 'Range is adequate.',
    );

    test('empty patternRecords → empty crossAxisPairs', () {
      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: const [],
        weekCount: 0,
        benchmarkContext: ctx,
        coverageCount: 0,
      );
      expect(summary.crossAxisPairs, isEmpty);
    });

    test(
        'non-empty patternRecords with pair pattern → crossAxisPairs populated '
        'and matches HistoryTeachingAnalyzer output', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
        _r(
          week: 'W1',
          day: 'Wed',
          daypart: 'lunch',
          leverId: 'splh_up',
          isBenchmark: true,
        ),
      ];

      final history = HistoryTeachingAnalyzer.summarize(records);
      final learn = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 1,
        benchmarkContext: ctx,
        coverageCount: records.length,
      );

      expect(learn.crossAxisPairs.length, equals(history.crossAxisPairs.length));
      expect(learn.crossAxisPairs, isNotEmpty);
      expect(
        learn.crossAxisPairs.first.pairId,
        equals(history.crossAxisPairs.first.pairId),
      );
      expect(
        learn.crossAxisPairs.first.count,
        equals(history.crossAxisPairs.first.count),
      );
      expect(
        learn.crossAxisPairs.first.pairId,
        equals(CrossAxisPairs.cplhBelowSplhAbove.id),
      );
    });

    test(
        'non-empty patternRecords WITHOUT pair pattern → empty crossAxisPairs '
        '(single-axis path stays unaffected)', () {
      final records = <HistoryPatternRecord>[
        _r(week: 'W1', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
        _r(week: 'W2', day: 'Mon', daypart: 'lunch', leverId: 'cplh_down'),
      ];

      final summary = LearnTeachingAnalyzer.summarize(
        patternRecords: records,
        weekCount: 2,
        benchmarkContext: ctx,
        coverageCount: records.length,
      );
      expect(summary.crossAxisPairs, isEmpty);
      // Single-axis path still observes the leak.
      expect(summary.primaryLeakId, equals('cplh_down'));
    });
  });

  group('7.58.cross-axis.0 — locked catalog shape and copy hygiene', () {
    test('CrossAxisPairs.all has exactly 4 entries (locked V1 size)', () {
      expect(CrossAxisPairs.all.length, equals(4));
    });

    test('catalog ids match the contract addendum', () {
      final ids = CrossAxisPairs.all.map((p) => p.id).toSet();
      expect(
        ids,
        equals({
          'cplh_below_splh_above',
          'cplh_on_splh_below',
          'cplh_above_splh_below',
          'both_below',
        }),
      );
    });

    test(
        'catalog headlines match the depth-wave addendum (locked metric copy)',
        () {
      expect(CrossAxisPairs.cplhBelowSplhAbove.metric,
          equals('FORECAST WAS LOW. TEAM EXECUTED.'));
      expect(CrossAxisPairs.cplhOnSplhBelow.metric,
          equals('KITCHEN SLOWED. DINING ROOM HELD.'));
      expect(CrossAxisPairs.cplhAboveSplhBelow.metric,
          equals('TEAM RAN LEAN. KITCHEN SLOWED.'));
      expect(CrossAxisPairs.bothBelow.metric, equals('DEMAND WAS SOFT.'));
    });

    test(
        'lookup is case-insensitive and returns null for empty / unknown ids',
        () {
      expect(
        CrossAxisPairs.lookup('CPLH_BELOW_SPLH_ABOVE'),
        same(CrossAxisPairs.cplhBelowSplhAbove),
      );
      expect(CrossAxisPairs.lookup(''), isNull);
      expect(CrossAxisPairs.lookup(null), isNull);
      expect(CrossAxisPairs.lookup('not_a_real_pair'), isNull);
    });

    test('cross_axis_pair_catalog.dart contains zero em dashes (U+2014)', () {
      // Em-dash ban — depth-wave addendum, depth_wave_plan hard gate #4.
      final file = File('lib/domain/constants/cross_axis_pair_catalog.dart');
      expect(file.existsSync(), isTrue,
          reason: 'cross_axis_pair_catalog.dart must exist at expected path');
      final bytes = file.readAsBytesSync();
      final source = utf8.decode(bytes);
      expect(source.contains('—'), isFalse,
          reason: 'em dash (U+2014) found in cross_axis_pair_catalog.dart');
    });
  });
}
