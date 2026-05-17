// Variance Coaching V2 (Lane F) - Variance > Learn 3-frame depth surfaces.
//
// Re-pinned from the 7.58.UX.7+9 snapshot/cross-axis-swap shape to the
// V2-5 3-frame Learn structure. Authority:
//
//   * docs/contracts/phase_7_58_primary_driver_contract.md V2-5
//     (3-frame Learn structure, tab-ownership reaffirmed) and the
//     binding mockup docs/f&f Coaching/variance_tab_v2_mockup.html
//     (#rail + the 3-frame / 4-pair Learn tracks).
//
// What this pins:
//
//   * V2-5 - the rail keeps all three sections (Recurring Leak /
//     Repeatable Wins / Cross-Axis), in mockup order. None is dropped.
//   * V2-5 - Recurring Leak renders a 3-frame story (WHAT HAPPENED ->
//     WHY IT MATTERS -> WHAT TO DO + THE PLAY) sourced from the merged
//     LeverCards catalog; the leak frame-1 heading is the V2-1
//     sentence-case `LeverCardData.metric`, joined with no uppercase.
//   * V2-5 - the frame-1 leak caption ("Repeated <n> of last
//     <coverageCount> <pluralized daypart>") renders when the
//     denominator is known and is omitted (honest fallback) when
//     coverage is 0.
//   * V2-5 - Cross-Axis is its own rail section: a 4-pair swipe, one
//     card per CrossAxisPairs entry, with the WHAT TO STUDY field
//     (`teachingNote`) present on the Learn surface (tab-ownership:
//     WHAT TO DO / WHAT TO STUDY live on Learn, never This Week).
//   * Hard gate #4 - no em dash (U+2014) in operator-facing string
//     literals in lib/screens/variance/variance_learn_tab.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/constants/cross_axis_pair_catalog.dart';
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
// is the coverage denominator).
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

// Single-axis recurring leak fixture: covers_down recurring across 6
// weeks in Tue Lunch. `summary.hasHistoryPatterns` is true so the
// Recurring Leak section renders its 3-frame story.
List<HistoryPatternRecord> _recurringLeakPatterns() => <HistoryPatternRecord>[
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
    LearnBenchmarkContextService.testCanonicalOverride = () async => _ctx;
  });

  tearDown(() {
    LearnBenchmarkContextService.testCanonicalOverride = null;
  });

  group('V2-5 - the Learn rail keeps all three sections', () {
    testWidgets('Recurring Leak / Repeatable Wins / Cross-Axis all render',
        (tester) async {
      final source = _FakeShiftDataSource(
        patterns: _recurringLeakPatterns(),
        closedShifts: _stubClosedShifts(12),
        weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
      );

      await tester.pumpWidget(_harness(source));
      await tester.pumpAndSettle();

      // The rail preserves all three buttons in mockup order; none is
      // dropped or conditionally swapped out.
      expect(find.text('Recurring Leak'), findsOneWidget);
      expect(find.text('Repeatable Wins'), findsOneWidget);
      expect(find.text('Cross-Axis'), findsOneWidget);
    });
  });

  group('V2-5 - Recurring Leak renders a 3-frame story', () {
    testWidgets(
      'frame 1 = WHAT HAPPENED with the V2-1 sentence-case metric heading '
      'plus the coverage caption',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _recurringLeakPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        // Frame 1 step label.
        expect(find.text('FRAME 1 · WHAT HAPPENED'), findsOneWidget);
        // Heading is the V2-1 sentence-case LeverCardData.metric for
        // `covers_down` - NOT uppercased.
        expect(
          find.text(LeverCards.coversDown.metric),
          findsOneWidget,
        );
        expect(LeverCards.coversDown.metric, 'Covers came in light');
        // Frame-1 caption: count = 6, coverage = 12, 'Tue Lunch' ->
        // 'Tue Lunches'.
        expect(
          find.text('Repeated 6 of last 12 Tue Lunches'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'frames 2 and 3 carry WHY IT MATTERS and WHAT TO DO + THE PLAY',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _recurringLeakPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        // Swipe to frame 2.
        await tester.drag(
          find.byType(PageView),
          const Offset(-400, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('FRAME 2 · WHY IT MATTERS'), findsOneWidget);

        // Swipe to frame 3 (the action / THE PLAY frame).
        await tester.drag(
          find.byType(PageView),
          const Offset(-400, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('FRAME 3 · WHAT TO DO'), findsOneWidget);
        expect(find.text('THE PLAY'), findsOneWidget);
      },
    );

    testWidgets(
      'leak caption omitted (honest fallback) when coverage is 0',
      (tester) async {
        // No recurring patterns AND no closed shifts: the Recurring
        // Leak section falls back to the honest "Leaks will surface
        // here" card and the coverage caption never renders.
        final source = _FakeShiftDataSource(
          patterns: const [],
          closedShifts: const [],
          weeks: const [],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        expect(find.textContaining('Repeated'), findsNothing);
        expect(find.text('Leaks will surface here'), findsOneWidget);
      },
    );
  });

  group('V2-5 - Cross-Axis is its own 4-pair section', () {
    testWidgets(
      'tapping the Cross-Axis rail button renders all 4 CrossAxisPairs '
      'with the WHAT TO STUDY field on the Learn surface',
      (tester) async {
        final source = _FakeShiftDataSource(
          patterns: _recurringLeakPatterns(),
          closedShifts: _stubClosedShifts(12),
          weeks: [_stubWeek('W1'), _stubWeek('W2'), _stubWeek('W3')],
        );

        await tester.pumpWidget(_harness(source));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cross-Axis'));
        await tester.pumpAndSettle();

        // First pair card: metric heading + axis badge + the three
        // labelled blocks (What happened / What to do / What to study).
        expect(
          find.text(CrossAxisPairs.cplhBelowSplhAbove.metric),
          findsOneWidget,
        );
        expect(find.text('CPLH ↓ · SPLH ↑'), findsOneWidget);
        // Tab-ownership: WHAT TO STUDY (teachingNote) is a Learn-surface
        // field and is present here.
        expect(find.text('What to study.'), findsWidgets);
        expect(find.text('What to do.'), findsWidgets);

        // The carousel is a 4-pair walk (one card per CrossAxisPairs
        // entry). Position indicator names the total.
        expect(find.text('1 of 4'), findsOneWidget);
        expect(CrossAxisPairs.all.length, 4);
      },
    );
  });

  group(
      'Hard gate #4 - em-dash hygiene on '
      '`lib/screens/variance/variance_learn_tab.dart`', () {
    test(
      'no em dash (U+2014) in operator-facing string literals',
      () {
        final source = File(
          'lib/screens/variance/variance_learn_tab.dart',
        ).readAsStringSync();
        // Strip single-line comments: the hard gate bans em dashes in
        // OPERATOR-FACING COPY (string literals), not documentation.
        final withoutLineComments = source
            .split('\n')
            .map((line) {
              final idx = line.indexOf('//');
              return idx >= 0 ? line.substring(0, idx) : line;
            })
            .join('\n');
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
