import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/models/shift_record.dart';
import 'package:forge_flow_demo/services/history_pattern_builder.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

ShiftRecord _shift({
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
}) {
  return ShiftRecord(
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
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('HistoryPatternBuilder.fromClosedShifts', () {
    group('filtering — status', () {
      test('projected shifts are skipped', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'projected',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
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
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, hasLength(1));
      });
    });

    group('filtering — ON_MODEL', () {
      test('ON_MODEL shifts are skipped', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'ON_MODEL',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, isEmpty);
      });

      test('on_model (already lowercase) is also skipped', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'on_model',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, isEmpty);
      });
    });

    group('filtering — unknown lever ids', () {
      test('unknown lever id is skipped', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'UNKNOWN_LEVER',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, isEmpty);
      });

      test('empty primaryLever string is skipped', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Mon',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: '',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, isEmpty);
      });
    });

    group('normalization — uppercase to lowercase', () {
      test('CPLH_DOWN normalizes to cplh_down', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.leverId, 'cplh_down');
      });

      test('SPLH_DOWN normalizes to splh_down', () {
        final shifts = [
          _shift(
            weekId: '2026-W10',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.leverId, 'splh_down');
      });

      test('FOH_WAGE_UP normalizes to foh_wage_up', () {
        final shifts = [
          _shift(
            weekId: '2026-W04',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'FOH_WAGE_UP',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.leverId, 'foh_wage_up');
      });
    });

    group('isBenchmark', () {
      test('favorable lever (CPLH_UP) becomes isBenchmark == true', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Wed',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_UP',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.isBenchmark, isTrue);
      });

      test('favorable lever (PPA_UP) becomes isBenchmark == true', () {
        final shifts = [
          _shift(
            weekId: '2026-W01',
            dayLabel: 'Thu',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'PPA_UP',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.isBenchmark, isTrue);
      });

      test('unfavorable lever (CPLH_DOWN) becomes isBenchmark == false', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.isBenchmark, isFalse);
      });

      test('unfavorable lever (SPLH_DOWN) becomes isBenchmark == false', () {
        final shifts = [
          _shift(
            weekId: '2026-W07',
            dayLabel: 'Fri',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'SPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.isBenchmark, isFalse);
      });
    });

    group('weekLabel resolution', () {
      test('weekLabel comes from weekLabelsById when key is present', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(
            shifts, {'2026-W12': 'Mar 17'});
        expect(result.first.weekLabel, 'Mar 17');
      });

      test('weekLabel falls back to weekId when key is absent', () {
        final shifts = [
          _shift(
            weekId: '2026-W12',
            dayLabel: 'Tue',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.weekLabel, '2026-W12');
      });
    });

    group('passthrough fields', () {
      test('weekId, dayLabel, daypart are preserved verbatim', () {
        final shifts = [
          _shift(
            weekId: '2026-W09',
            dayLabel: 'Thu',
            daypart: 'dinner',
            status: 'closed',
            primaryLever: 'CPLH_DOWN',
          ),
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result.first.weekId, '2026-W09');
        expect(result.first.dayLabel, 'Thu');
        expect(result.first.daypart, 'dinner');
      });
    });

    group('empty and mixed input', () {
      test('empty input returns empty list', () {
        final result = HistoryPatternBuilder.fromClosedShifts([], {});
        expect(result, isEmpty);
      });

      test('mix of eligible and ineligible shifts filters correctly', () {
        final shifts = [
          _shift(weekId: '2026-W12', dayLabel: 'Tue', daypart: 'dinner',
              status: 'closed',    primaryLever: 'CPLH_DOWN'),   // ✓ eligible
          _shift(weekId: '2026-W12', dayLabel: 'Wed', daypart: 'dinner',
              status: 'projected', primaryLever: 'CPLH_UP'),    // ✗ not closed
          _shift(weekId: '2026-W12', dayLabel: 'Thu', daypart: 'dinner',
              status: 'closed',    primaryLever: 'ON_MODEL'),    // ✗ on_model
          _shift(weekId: '2026-W12', dayLabel: 'Fri', daypart: 'dinner',
              status: 'closed',    primaryLever: 'UNKNOWN'),     // ✗ unknown id
          _shift(weekId: '2026-W12', dayLabel: 'Sat', daypart: 'dinner',
              status: 'closed',    primaryLever: 'SPLH_DOWN'),   // ✓ eligible
        ];
        final result = HistoryPatternBuilder.fromClosedShifts(shifts, {});
        expect(result, hasLength(2));
        expect(result.map((r) => r.leverId).toList(),
            containsAll(['cplh_down', 'splh_down']));
      });
    });
  });
}
