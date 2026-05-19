// Phase 7.55k.3 — DaypartPatternSummaryBuilder tests.
//
// Covers: closed-only filtering, recurring-bucket grouping, metric
// averages, benchmark/leak counts, dominant levers, exemplar IDs,
// ordering, sample-threshold filtering, and a fixture-seed scenario.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/fixture_seed_data.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/daypart_pattern_summary_builder.dart';

// ── Helpers ─────────────────────────────────────────────────────────────────

ShiftRecord _shift({
  String restaurantId = 'demo_restaurant_001',
  required String weekId,
  required String dayLabel,
  required String daypart,
  required String status,
  required String primaryLever,
  int covers = 180,
  int forecastCovers = 200,
  double ppa = 42.0,
  double cplh = 4.5,
  double splh = 180.0,
  int fohHours = 40,
  int bohHours = 42,
  String? businessDate,
  String? sourceShiftId,
  String? sourceSystem,
}) {
  return ShiftRecord(
    restaurantId: restaurantId,
    weekId: weekId,
    dayLabel: dayLabel,
    daypart: daypart,
    status: status,
    covers: covers,
    forecastCovers: forecastCovers,
    ppa: ppa,
    cplh: cplh,
    splh: splh,
    fohHours: fohHours,
    bohHours: bohHours,
    primaryLever: primaryLever,
    businessDate: businessDate,
    sourceShiftId: sourceShiftId,
    sourceSystem: sourceSystem,
  );
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('DaypartPatternSummaryBuilder.fromClosedShifts', () {
    // ── A: closed-only filtering ──────────────────────────────────────────

    group('A — closed-only filtering', () {
      test('projected shifts are excluded', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'projected',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, isEmpty);
      });

      test('open shifts are excluded', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'open',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, isEmpty);
      });

      test('closed shifts are included', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, hasLength(1));
        expect(result.first.closedShiftCount, 1);
      });

      test('mixed status: only closed count toward summary', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W13',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'projected',
            primaryLever: 'CPLH_UP',
          ),
          _shift(
            weekId: '2026-W14',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'open',
            primaryLever: 'PPA_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, hasLength(1));
        expect(result.first.closedShiftCount, 1);
      });

      test('app-local same-day closed rows are excluded from summaries', () {
        final shifts = [
          _shift(
            weekId: '2026-W20',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            businessDate: '2026-05-18',
          ),
          _shift(
            weekId: '2026-W20',
            dayLabel: 'Tue',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_UP',
            businessDate: '2026-05-19',
          ),
        ];

        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          shifts,
          currentOperationalBusinessDate: '2026-05-19',
          shiftCloseAuthorityForRow: (_) =>
              ShiftCloseAuthority.appLocalCutoffFallback,
        );

        expect(result, hasLength(1));
        expect(result.single.dayLabel, 'Mon');
        expect(result.single.closedShiftCount, 1);
      });

      test('vendor-finalized same-day closed rows are included', () {
        final shifts = [
          _shift(
            weekId: '2026-W20',
            dayLabel: 'Tue',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_UP',
            businessDate: '2026-05-19',
          ),
        ];

        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          shifts,
          currentOperationalBusinessDate: '2026-05-19',
          shiftCloseAuthorityForRow: (_) =>
              ShiftCloseAuthority.vendorFinalization,
        );

        expect(result, hasLength(1));
        expect(result.single.dayLabel, 'Tue');
        expect(result.single.benchmarkCount, 1);
      });

      test('empty input returns empty list', () {
        final result = DaypartPatternSummaryBuilder.fromClosedShifts([]);
        expect(result, isEmpty);
      });
    });

    // ── B: recurring-bucket grouping ──────────────────────────────────────

    group('B — recurring-bucket grouping', () {
      test('same dayLabel + daypart from different weeks group together', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
            businessDate: '2026-03-07',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_UP',
            businessDate: '2026-03-14',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
            businessDate: '2026-03-21',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, hasLength(1));
        expect(result.first.dayLabel, 'Sat');
        expect(result.first.daypart, 'dinner');
        expect(result.first.closedShiftCount, 3);
      });

      test('different dayparts on same day produce separate summaries', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'late_night',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, hasLength(3));
        expect(result.map((s) => s.daypart).toList(), [
          'lunch',
          'dinner',
          'late_night',
        ]);
      });

      test('different restaurants produce separate summaries', () {
        final shifts = [
          _shift(
            restaurantId: 'rest_A',
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            restaurantId: 'rest_B',
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result, hasLength(2));
        expect(result.map((s) => s.restaurantId).toSet(), {'rest_A', 'rest_B'});
      });
    });

    // ── C: metric averages ────────────────────────────────────────────────

    group('C — metric averages', () {
      test('averages are computed correctly across shifts', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            covers: 200,
            ppa: 40.0,
            cplh: 4.0,
            splh: 160.0,
            fohHours: 50,
            bohHours: 50,
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            covers: 100,
            ppa: 50.0,
            cplh: 5.0,
            splh: 200.0,
            fohHours: 20,
            bohHours: 25,
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.avgCovers, 150.0);
        expect(s.avgPPA, 45.0);
        expect(s.avgCPLH, 4.5);
        expect(s.avgSPLH, 180.0);
        expect(s.avgFohHours, 35.0);
        expect(s.avgBohHours, 37.5);
        // avgSales: (200*40 + 100*50) / 2 = (8000 + 5000) / 2 = 6500
        expect(s.avgSales, 6500.0);
      });

      test('avgLaborPct ignores shifts without source-backed labor truth', () {
        final shifts = [
          ShiftRecord(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            covers: 200,
            forecastCovers: 200,
            ppa: 40.0,
            cplh: 4.0,
            splh: 160.0,
            fohHours: 50,
            bohHours: 50,
            primaryLever: 'CPLH_DOWN',
            storedTotalLaborPct: 24.0,
          ),
          ShiftRecord(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            covers: 100,
            forecastCovers: 100,
            ppa: 50.0,
            cplh: 5.0,
            splh: 200.0,
            fohHours: 20,
            bohHours: 25,
            primaryLever: 'CPLH_DOWN',
          ),
        ];

        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.avgLaborSampleCount, 1);
        expect(s.avgLaborPct, 24.0);
      });
    });

    // ── D: benchmark / leak counts and dominant levers ────────────────────

    group('D — benchmark and leak counts', () {
      test('favorable levers count as benchmark, unfavorable as leak', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Thu',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP', // favorable
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Thu',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_UP', // favorable
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Thu',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN', // unfavorable
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.benchmarkCount, 2);
        expect(s.leakCount, 1);
      });

      test('ON_MODEL does not count as benchmark or leak', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'ON_MODEL',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_UP',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.closedShiftCount, 2); // ON_MODEL still counted in total
        expect(s.benchmarkCount, 1);
        expect(s.leakCount, 0);
      });

      test('all ON_MODEL produces null dominant levers', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'ON_MODEL',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'ON_MODEL',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.dominantBenchmarkLeverId, isNull);
        expect(s.dominantLeakLeverId, isNull);
        expect(s.benchmarkCount, 0);
        expect(s.leakCount, 0);
      });
    });

    group('D2 — dominant lever tie-breaking', () {
      test('benchmark tie: ppa_up wins over cplh_up', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Wed',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_UP',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Wed',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        // Both appear once — tie-break order: ppa_up first.
        expect(result.first.dominantBenchmarkLeverId, 'ppa_up');
      });

      test('leak tie: cplh_down wins over ppa_down', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Wed',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Wed',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result.first.dominantLeakLeverId, 'cplh_down');
      });

      test('higher frequency wins over tie-break order', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        // splh_down appears 2x, cplh_down 1x — frequency wins.
        expect(result.first.dominantLeakLeverId, 'splh_down');
      });
    });

    // ── E: exemplar / source IDs ──────────────────────────────────────────

    group('E — exemplar source shift IDs', () {
      test('sourceShiftId is used when present', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            sourceShiftId: 'toast-shift-001',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result.first.exemplarSourceShiftIds, ['toast-shift-001']);
      });

      test('synthetic fallback when sourceShiftId is absent', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        // Fallback uses weekId as suffix when businessDate is absent.
        expect(
          result.first.exemplarSourceShiftIds.first,
          '2026-W12:Mon:dinner:2026-W12',
        );
      });

      test('synthetic fallback uses businessDate when present', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            businessDate: '2026-03-23',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(
          result.first.exemplarSourceShiftIds.first,
          '2026-W12:Mon:dinner:2026-03-23',
        );
      });

      test('limited to 5 exemplar IDs', () {
        final shifts = List.generate(
          8,
          (i) => _shift(
            weekId: '2026-W${(i + 5).toString().padLeft(2, '0')}',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
            sourceShiftId: 'shift-$i',
          ),
        );
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result.first.exemplarSourceShiftIds, hasLength(5));
        expect(result.first.exemplarSourceShiftIds.first, 'shift-0');
        expect(result.first.exemplarSourceShiftIds.last, 'shift-4');
      });
    });

    // ── F: ordering ───────────────────────────────────────────────────────

    group('F — deterministic ordering', () {
      test('output is sorted by day order then service-period order', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'late_night',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final labels = result.map((s) => '${s.dayLabel} ${s.daypart}').toList();

        expect(labels, [
          'Mon lunch',
          'Mon dinner',
          'Fri lunch',
          'Fri late_night',
          'Sat dinner',
        ]);
      });
    });

    // ── G: sample-threshold filtering ─────────────────────────────────────

    group('G — minSampleThreshold', () {
      test('threshold of 1 includes single-shift buckets', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          shifts,
          minSampleThreshold: 1,
        );
        expect(result, hasLength(1));
      });

      test('threshold of 3 excludes buckets with fewer shifts', () {
        final shifts = [
          // Mon lunch: 2 shifts — below threshold
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
          // Tue dinner: 3 shifts — meets threshold
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          shifts,
          minSampleThreshold: 3,
        );
        expect(result, hasLength(1));
        expect(result.first.dayLabel, 'Tue');
        expect(result.first.closedShiftCount, 3);
      });

      test('high threshold excludes all buckets', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          shifts,
          minSampleThreshold: 10,
        );
        expect(result, isEmpty);
      });
    });

    // ── H: display helpers ────────────────────────────────────────────────

    group('H — model display helpers', () {
      test('fullLabel combines dayLabel and daypartLabel', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result.first.fullLabel, 'Sat Dinner');
      });

      test('daypartLabel maps known IDs', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'late_night',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        expect(result.first.daypartLabel, 'Late Night');
      });

      test('meetsThreshold returns correct boolean', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;
        expect(s.meetsThreshold(2), isTrue);
        expect(s.meetsThreshold(3), isFalse);
      });
    });

    // ── J: unknown lever IDs (7.55k.3a) ────────────────────────────────────

    group('J — unknown lever IDs excluded from lever evidence', () {
      test('unknown lever id does not count as benchmark or leak', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'UNKNOWN_LEVER',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.closedShiftCount, 2); // unknown still counted in total
        expect(s.leakCount, 1); // only the valid cplh_down
        expect(s.benchmarkCount, 0);
      });

      test('unknown lever id still contributes to metric averages', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Tue',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'TOTALLY_BOGUS',
            covers: 200,
            ppa: 40.0,
            cplh: 4.0,
            splh: 160.0,
            fohHours: 50,
            bohHours: 50,
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Tue',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: 'PPA_UP',
            covers: 100,
            ppa: 50.0,
            cplh: 5.0,
            splh: 200.0,
            fohHours: 20,
            bohHours: 25,
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.closedShiftCount, 2);
        expect(s.avgCovers, 150.0);
        expect(s.avgPPA, 45.0);
        expect(s.benchmarkCount, 1);
        expect(s.leakCount, 0); // TOTALLY_BOGUS not counted as leak
      });

      test('all unknown levers produce null dominant levers', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Wed',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'FAKE_UP',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Wed',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'FAKE_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.closedShiftCount, 2);
        expect(s.benchmarkCount, 0);
        expect(s.leakCount, 0);
        expect(s.dominantBenchmarkLeverId, isNull);
        expect(s.dominantLeakLeverId, isNull);
      });

      test('empty primaryLever string does not count as lever evidence', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Thu',
            daypart: 'lunch',
            status: 'closed',
            primaryLever: '',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        expect(s.closedShiftCount, 1);
        expect(s.benchmarkCount, 0);
        expect(s.leakCount, 0);
      });

      test('dominant lever only from valid known IDs', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'UNKNOWN_LEAK',
          ),
          _shift(
            weekId: '2026-W11',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'UNKNOWN_LEAK',
          ),
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(shifts);
        final s = result.first;

        // UNKNOWN_LEAK appears 2x but is invalid — only cplh_down counts.
        expect(s.leakCount, 1);
        expect(s.dominantLeakLeverId, 'cplh_down');
      });
    });

    // ── K: exemplar stability (7.55k.3a) ─────────────────────────────────

    group('K — exemplar fallback IDs are deterministic across input order', () {
      test('reordered input produces same exemplar list', () {
        final a = _shift(
          weekId: '2026-W10',
          dayLabel: 'Mon',
          daypart: 'dinner',
          status: 'closed',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-02',
        );
        final b = _shift(
          weekId: '2026-W11',
          dayLabel: 'Mon',
          daypart: 'dinner',
          status: 'closed',
          primaryLever: 'PPA_DOWN',
          businessDate: '2026-03-09',
        );
        final c = _shift(
          weekId: '2026-W12',
          dayLabel: 'Mon',
          daypart: 'dinner',
          status: 'closed',
          primaryLever: 'SPLH_DOWN',
          businessDate: '2026-03-16',
        );

        final forward = DaypartPatternSummaryBuilder.fromClosedShifts([
          a,
          b,
          c,
        ]);
        final reverse = DaypartPatternSummaryBuilder.fromClosedShifts([
          c,
          b,
          a,
        ]);
        final shuffled = DaypartPatternSummaryBuilder.fromClosedShifts([
          b,
          c,
          a,
        ]);

        expect(
          forward.first.exemplarSourceShiftIds,
          reverse.first.exemplarSourceShiftIds,
        );
        expect(
          forward.first.exemplarSourceShiftIds,
          shuffled.first.exemplarSourceShiftIds,
        );
      });

      test(
        'reordered input with sourceShiftId produces same exemplar list',
        () {
          final a = _shift(
            weekId: '2026-W10',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
            sourceShiftId: 'toast-001',
          );
          final b = _shift(
            weekId: '2026-W11',
            dayLabel: 'Sat',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_UP',
            sourceShiftId: 'toast-002',
          );

          final forward = DaypartPatternSummaryBuilder.fromClosedShifts([a, b]);
          final reverse = DaypartPatternSummaryBuilder.fromClosedShifts([b, a]);

          expect(
            forward.first.exemplarSourceShiftIds,
            reverse.first.exemplarSourceShiftIds,
          );
        },
      );

      test('reordered input without businessDate still deterministic', () {
        final a = _shift(
          weekId: '2026-W08',
          dayLabel: 'Tue',
          daypart: 'lunch',
          status: 'closed',
          primaryLever: 'CPLH_DOWN',
        );
        final b = _shift(
          weekId: '2026-W09',
          dayLabel: 'Tue',
          daypart: 'lunch',
          status: 'closed',
          primaryLever: 'PPA_DOWN',
        );

        final forward = DaypartPatternSummaryBuilder.fromClosedShifts([a, b]);
        final reverse = DaypartPatternSummaryBuilder.fromClosedShifts([b, a]);

        expect(
          forward.first.exemplarSourceShiftIds,
          reverse.first.exemplarSourceShiftIds,
        );
        // weekId-based fallback: sorted ascending.
        expect(
          forward.first.exemplarSourceShiftIds.first,
          '2026-W08:Tue:lunch:2026-W08',
        );
      });
    });

    // ── I: fixture-seed scenario ──────────────────────────────────────────

    group('I — fixture seed scenario', () {
      test('historical closed shifts produce sensible summaries', () {
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          DemoData.historicalClosedShifts,
        );

        // Should produce at least one summary.
        expect(result, isNotEmpty);

        // Every summary should have positive closed shift count.
        for (final s in result) {
          expect(s.closedShiftCount, greaterThan(0));
          expect(s.avgCovers, greaterThan(0));
          expect(s.avgSales, greaterThan(0));
          expect(s.avgCPLH, greaterThan(0));
          expect(s.avgSPLH, greaterThan(0));
          expect(s.exemplarSourceShiftIds, isNotEmpty);
          expect(
            s.exemplarSourceShiftIds.length,
            lessThanOrEqualTo(DaypartPatternSummaryBuilder.maxExemplarCount),
          );
        }

        // Should be sorted: day order then service-period order.
        for (var i = 1; i < result.length; i++) {
          final prev = result[i - 1];
          final curr = result[i];

          final prevDay = _dayIndex(prev.dayLabel);
          final currDay = _dayIndex(curr.dayLabel);

          if (prevDay == currDay) {
            expect(
              _dpIndex(prev.daypart),
              lessThanOrEqualTo(_dpIndex(curr.daypart)),
            );
          } else {
            expect(prevDay, lessThan(currDay));
          }
        }
      });

      test('benchmark + leak counts are consistent with closedShiftCount', () {
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          DemoData.historicalClosedShifts,
        );

        for (final s in result) {
          // benchmark + leak + on_model = closedShiftCount
          // (on_model count is implied: total - benchmark - leak)
          expect(
            s.benchmarkCount + s.leakCount,
            lessThanOrEqualTo(s.closedShiftCount),
          );
        }
      });

      test('with minSampleThreshold = 3, only dense buckets survive', () {
        final result = DaypartPatternSummaryBuilder.fromClosedShifts(
          DemoData.historicalClosedShifts,
          minSampleThreshold: 3,
        );

        for (final s in result) {
          expect(s.closedShiftCount, greaterThanOrEqualTo(3));
        }
      });
    });
  });
}

int _dayIndex(String dayLabel) {
  const order = {
    'Mon': 0,
    'Tue': 1,
    'Wed': 2,
    'Thu': 3,
    'Fri': 4,
    'Sat': 5,
    'Sun': 6,
  };
  return order[dayLabel] ?? 99;
}

int _dpIndex(String daypart) {
  const order = {'morning': 0, 'lunch': 1, 'dinner': 2, 'late_night': 3};
  return order[daypart] ?? 99;
}
