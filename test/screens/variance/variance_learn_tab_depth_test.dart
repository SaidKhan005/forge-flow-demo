// 7.58.UX.7+9 - Variance > Learn depth surfaces (Wave B).
//
// Pins the two depth additions the slice owns inside
// `lib/screens/variance/variance_learn_tab.dart`:
//
//   * 7.58.UX.7 - the leak-snapshot card appends a coverage
//     denominator caption to the lever metric of the form
//     "Repeated <count> of last <coverageCount> <pluralized daypart>"
//     when `coverageCount > 0`, and omits the caption otherwise so
//     the copy stays honest when the denominator is unknown.
//
//   * 7.58.UX.9 - the Recurring Leak carousel swaps its data source
//     from `LeverCards` to `CrossAxisPairs` when the cross-axis
//     analyzer surfaces a recurring pair pattern with
//     `crossAxisPairs.first.count >= 3 AND > primaryLeakCount`.
//     The carousel structure stays 4 cards in both branches; only
//     the input changes.
//
// Authority:
//   * `docs/contracts/phase_7_58_primary_driver_contract.md` "Depth
//     Surfaces" addendum.
//   * `docs/phases/phase_7_58/phase_7_58_depth_wave_plan.md` Wave B
//     row + hard gates 4 (no em dashes in operator-facing copy) and
//     6 (honest fallback when inputs are insufficient).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/cross_axis_pair_catalog.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/screens/variance/variance_learn_tab.dart';
import 'package:forge_and_flow/services/learn_benchmark_context_service.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:provider/provider.dart';

// --- Fixtures --------------------------------------------------------------

const _ctx = LearnBenchmarkContext(
  benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
  selectedShiftCount: 14,
  targetCPLH: 4.5,
  targetSPLH: 180.0,
  targetPPA: 42.0,
  rangeQualityLabel: 'GOOD OPZ RANGE',
  rangeQualityMessage: 'Range is adequate.',
);

WeekRecord _stubWeek(String id) => WeekRecord(
      weekId: id,
      weekLabel: id,
      totalCovers: 1000,
      forecastCovers: 1000,
      totalFohHours: 200,
      totalBohHours: 200,
      avgPPA: 42,
      avgCPLH: 4.5,
      theoreticalLaborPct: 20.0,
      actualLaborPct: 20.0,
      dollarGap: 0,
      primaryLeverId: 'on_model',
    );

HistoryPatternRecord _r({
  required String week,
  required String day,
  required String daypart,
  required String leverId,
  bool isBenchmark = false,
}) =>
    HistoryPatternRecord(
      weekId: week,
      weekLabel: week,
      dayLabel: day,
      daypart: daypart,
      leverId: leverId,
      isBenchmark: isBenchmark,
    );

// Builds a closed-shift fixture of [n] rows. Only `isClosed` and the
// list length matter for the LearnTab loader (the closed-shift list
// is the coverage denominator). `daypart` is set to 'lunch' for shape
// parity with the patterns; per-row metric values are placeholders.
List<ShiftRecord> _stubClosedShifts(int n) => List.generate(
      n,
      (i) => ShiftRecord(
        weekId: 'W${(i ~/ 4) + 1}',
        dayLabel: 'D$i',
        daypart: 'lunch',
        status: 'closed',
        covers: 100,
        forecastCovers: 100,
        ppa: 42,
        cplh: 4.5,
        splh: 180,
        fohHours: 10,
        bohHours: 10,
        primaryLever: 'on_model',
        businessDate: '2026-03-${(10 + i).toString().padLeft(2, '0')}',
      ),
    );

class _FakeShiftDataSource implements ShiftDataSource {
  final List<HistoryPatternRecord> patterns;
  final List<ShiftRecord> closedShifts;
  final List<WeekRecord> weeks;
  const _FakeShiftDataSource({
    this.patterns = const [],
    this.closedShifts = const [],
    this.weeks = const [],
  });

  @override
  Future<WeekData?> getWeekToDate() async => null;

  @override
  Future<List<WeekRecord>> getWeekHistory() async => weeks;

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async =>
      patterns;

  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => const [];

  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => closedShifts;
}

Widget _harness(_FakeShiftDataSource source) => MaterialApp(
      home: Scaffold(
        body: Provider<ShiftDataSource>(
          create: (_) => source,
          child: const LearnTab(),
        ),
      ),
    );

// 7.58.cross-axis.0 fixture: 3 weeks each with one cplh_down + one
// splh_up record in the (week, lunch) bucket. Pair count = 6,
// primaryLeakCount = 3 (cplh_down across 3 weeks), so the swap
// predicate (count >= 3 AND > primaryLeakCount) fires.
List<HistoryPatternRecord> _crossAxisFiringPatterns() => <HistoryPatternRecord>[
      _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
      _r(
        week: 'W1',
        day: 'Tue',
        daypart: 'lunch',
        leverId: 'splh_up',
        isBenchmark: true,
      ),
      _r(week: 'W2', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
      _r(
        week: 'W2',
        day: 'Tue',
        daypart: 'lunch',
        leverId: 'splh_up',
        isBenchmark: true,
      ),
      _r(week: 'W3', day: 'Tue', daypart: 'lunch', leverId: 'cplh_down'),
      _r(
        week: 'W3',
        day: 'Tue',
        daypart: 'lunch',
        leverId: 'splh_up',
        isBenchmark: true,
      ),
    ];

// Single-axis-only fixture: covers_down recurring across 3 weeks in
// Tue Lunch. No CPLH-or-SPLH pair fires, so crossAxisPairs is empty
// and the carousel renders the single-axis 4-card walk.
List<HistoryPatternRecord> _singleAxisOnlyPatterns() => <HistoryPatternRecord>[
      _r(week: 'W1', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
      _r(week: 'W2', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
      _r(week: 'W3', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
      _r(week: 'W4', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
      _r(week: 'W5', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
      _r(week: 'W6', day: 'Tue', daypart: 'lunch', leverId: 'covers_down'),
    ];

// --- Tests -----------------------------------------------------------------

void main() {
  setUp(() {
    LearnBenchmarkContextService.testCanonicalOverride =
        () async => _ctx;
  });

  tearDown(() {
    LearnBenchmarkContextService.testCanonicalOverride = null;
  });

  group('7.58.UX.7 - coverage caption on the leak snapshot card', () {
    testWidgets(
      'caption renders when coverageCount > 0 and a top daypart exists',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _singleAxisOnlyPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        // Lever metric for `covers_down` is 'COVERS CAME IN LIGHT' per
        // `lib/data/app_defaults.dart`; the caption joins via middot
        // (U+00B7) and pluralizes 'Tue Lunch' -> 'Tue Lunches'.
        expect(
          find.text(
            'COVERS CAME IN LIGHT · Repeated 6 of last 12 Tue Lunches',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('caption omitted when coverage is 0 (honest fallback)',
        (tester) async {
      // Production callers pass `closedShifts.length` to the analyzer
      // and `HistoryPatternBuilder` consumes the same closed-shift
      // population, so coverageCount=0 implies patternRecords.isEmpty.
      // In that branch `summary.hasHistoryPatterns` is false, the
      // snapshot card does not render, and the carousel falls back to
      // the existing "Leaks will surface here" card. The coverage
      // caption never renders - which is exactly the honest fallback.
      final source = _FakeShiftDataSource(
        patterns: const [], // <- no recurring leak yet
        closedShifts: const [], // <- coverageCount == 0
        weeks: const [],
      );

      await tester.pumpWidget(_harness(source));
      await tester.pumpAndSettle();

      // The caption never appears (suppressed at the source).
      expect(find.textContaining('Repeated'), findsNothing);
      expect(find.textContaining('of last'), findsNothing);
      // The honest-fallback "no patterns yet" branch renders.
      expect(find.text('Leaks will surface here'), findsOneWidget);
    });
  });

  group('7.58.UX.9 - cross-axis swap predicate fires the pair carousel', () {
    testWidgets(
      'crossAxisPairs.first.count >= 3 AND > primaryLeakCount swaps the '
      'carousel data source to CrossAxisPairs',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _crossAxisFiringPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        // Cross-axis snapshot title comes from CrossAxisPairData.metric.
        expect(
          find.text(CrossAxisPairs.cplhBelowSplhAbove.metric),
          findsOneWidget,
        );
        // Cross-axis badge replaces the 'LEAK' badge on the snapshot.
        expect(find.text('CROSS AXIS LEAK'), findsOneWidget);
        // Single-axis 'LEAK' badge does not render in this branch.
        expect(find.text('LEAK'), findsNothing);
      },
    );

    testWidgets(
      'carousel renders single-axis copy when crossAxisPairs is empty',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _singleAxisOnlyPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        // Single-axis branch: 'LEAK' badge renders, cross-axis badge
        // does not. Snapshot title = LeverCards.coversDown.metric.
        expect(find.text('LEAK'), findsOneWidget);
        expect(find.text('CROSS AXIS LEAK'), findsNothing);
        expect(
          find.textContaining('COVERS CAME IN LIGHT'),
          findsOneWidget,
        );
      },
    );
  });

  group('7.58.UX.7+9 - carousel structure stays 4 cards in both branches', () {
    testWidgets('single-axis branch wires a 4-card carousel',
        (tester) async {
      final source = _FakeShiftDataSource(
        patterns: _singleAxisOnlyPatterns(),
        closedShifts: _stubClosedShifts(12),
        weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
      );

      await tester.pumpWidget(_harness(source));
      await tester.pumpAndSettle();

      // Carousel position indicator names total card count -
      // stable across PageView lazy-build behaviour because the
      // text reads `<currentPage + 1> of <count>` directly off the
      // builder input. See `lib/widgets/learn/learn_carousel.dart`
      // _CarouselPositionIndicator.
      expect(find.text('1 of 4'), findsOneWidget);
      // Snapshot card (page 0) carries the 'LEAK' badge.
      expect(find.text('LEAK'), findsOneWidget);
      // No cross-axis chrome on the single-axis branch.
      expect(find.text('CROSS AXIS LEAK'), findsNothing);
    });

    testWidgets('cross-axis branch wires a 4-card carousel',
        (tester) async {
      final source = _FakeShiftDataSource(
        patterns: _crossAxisFiringPatterns(),
        closedShifts: _stubClosedShifts(12),
        weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
      );

      await tester.pumpWidget(_harness(source));
      await tester.pumpAndSettle();

      expect(find.text('1 of 4'), findsOneWidget);
      // Snapshot card (page 0) carries the 'CROSS AXIS LEAK' badge.
      expect(find.text('CROSS AXIS LEAK'), findsOneWidget);
      expect(find.text('LEAK'), findsNothing);
    });
  });

  group(
      '7.58.UX.7+9 - em-dash hygiene on `lib/screens/variance/variance_learn_tab.dart`',
      () {
    test(
      'no em dash (U+2014) in operator-facing string literals',
      () {
        final source = File(
          'lib/screens/variance/variance_learn_tab.dart',
        ).readAsStringSync();
        // Strip out single-line comments. The Phase 7.58 hard gate #4
        // bans em dashes in OPERATOR-FACING COPY (string literals);
        // documentation comments may legitimately use em dashes.
        // Pattern mirrors `test/widgets/dollar_impact_card_depth_test.dart`.
        final withoutLineComments = source
            .split('\n')
            .map((line) {
              final idx = line.indexOf('//');
              return idx >= 0 ? line.substring(0, idx) : line;
            })
            .join('\n');
        // Match content inside single-quoted Dart string literals.
        final stringLiteralRe = RegExp(r"'([^'\\]*(?:\\.[^'\\]*)*)'");
        for (final m in stringLiteralRe.allMatches(withoutLineComments)) {
          final body = m.group(1) ?? '';
          expect(
            body.contains('—'),
            isFalse,
            reason:
                'Em dash (U+2014) leaked into a string literal: \'$body\'. '
                'Use period, colon, or middot instead.',
          );
        }
      },
    );
  });
}
