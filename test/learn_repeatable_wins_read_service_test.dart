// Phase 7.55k.6 — Learn Repeatable Wins Read Service Tests
//
// Verifies:
// A. Closed-only input — open/projected rows excluded
// B. Deterministic ranking with explicit tie-breaking
// C. Sample counts and metric proofs are computed correctly
// D. Dominant favorable lever is explicit
// E. Edge cases — no benchmark evidence, ON_MODEL only
// F. Canonical fixture seed produces expected win evidence
// G. Max results limit

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/closed_timing_label_resolver.dart';
import 'package:forge_and_flow/services/learn_repeatable_wins_read_service.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

ShiftRecord _shift({
  String dayLabel = 'Mon',
  String daypart = 'lunch',
  String status = 'closed',
  int covers = 120,
  double ppa = 42.0,
  double cplh = 4.5,
  double splh = 180.0,
  int fohHours = 28,
  int bohHours = 29,
  String primaryLever = 'PPA_UP',
  String? businessDate,
  String? businessTimingProfileId,
  String? businessTimingProfileVersionId,
  String? servicePeriodKey,
}) => ShiftRecord(
  weekId: '2026-W10',
  dayLabel: dayLabel,
  daypart: daypart,
  status: status,
  covers: covers,
  forecastCovers: covers,
  ppa: ppa,
  cplh: cplh,
  splh: splh,
  fohHours: fohHours,
  bohHours: bohHours,
  primaryLever: primaryLever,
  businessDate: businessDate,
  businessTimingProfileId: businessTimingProfileId,
  businessTimingProfileVersionId: businessTimingProfileVersionId,
  servicePeriodKey: servicePeriodKey,
);

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  const service = LearnRepeatableWinsReadService();

  // ── A: Closed-only input ────────────────────────────────────────────────

  group('A — closed-only input', () {
    test('open and projected shifts are excluded from win evidence', () {
      final shifts = [
        _shift(status: 'closed', primaryLever: 'PPA_UP'),
        _shift(status: 'open', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(status: 'projected', dayLabel: 'Tue', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, 1);
      expect(results.first.closedShiftCount, 1);
    });

    test('empty input returns empty results', () {
      expect(service.build([]), isEmpty);
    });
  });

  // ── B: Deterministic ranking ────────────────────────────────────────────

  group('B — deterministic ranking', () {
    test('higher benchmarkCount ranks first', () {
      final shifts = [
        _shift(dayLabel: 'Sat', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Sat',
          daypart: 'dinner',
          primaryLever: 'PPA_UP',
          businessDate: '2026-03-08',
        ),
        _shift(
          dayLabel: 'Sat',
          daypart: 'dinner',
          primaryLever: 'PPA_UP',
          businessDate: '2026-03-15',
        ),
        _shift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.first.label, 'Sat Dinner');
    });

    test('same benchmarkCount ties broken by closedShiftCount', () {
      final shifts = [
        _shift(dayLabel: 'Wed', daypart: 'lunch', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Wed',
          daypart: 'lunch',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-12',
        ),
        _shift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.first.label, 'Wed Lunch');
      expect(results.first.closedShiftCount, 2);
    });

    test('exact ties fall back to canonical day then daypart order', () {
      final shifts = [
        _shift(dayLabel: 'Sat', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(dayLabel: 'Fri', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(dayLabel: 'Thu', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, 3);
      expect(results[0].label, 'Thu Lunch');
      expect(results[1].label, 'Fri Dinner');
      expect(results[2].label, 'Sat Dinner');
    });

    test('exact ties with same day fall back to service-period order', () {
      final shifts = [
        _shift(dayLabel: 'Fri', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(dayLabel: 'Fri', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, 2);
      expect(results[0].label, 'Fri Lunch');
      expect(results[1].label, 'Fri Dinner');
    });
  });

  // ── C: Sample counts and metric proofs ──────────────────────────────────

  group('C — sample counts and metric proofs', () {
    test('benchmarkCount reflects favorable shifts only', () {
      final shifts = [
        _shift(primaryLever: 'PPA_UP'),
        _shift(primaryLever: 'CPLH_DOWN', businessDate: '2026-03-08'),
        _shift(primaryLever: 'CPLH_UP', businessDate: '2026-03-15'),
      ];
      final results = service.build(shifts);
      expect(results.length, 1);
      expect(results.first.benchmarkCount, 2);
      expect(results.first.closedShiftCount, 3);
    });

    test('avgCPLH, avgSPLH, avgPPA are computed from all closed shifts', () {
      final shifts = [
        _shift(cplh: 4.0, splh: 160.0, ppa: 40.0, primaryLever: 'PPA_UP'),
        _shift(
          cplh: 5.0,
          splh: 200.0,
          ppa: 44.0,
          primaryLever: 'PPA_UP',
          businessDate: '2026-03-08',
        ),
      ];
      final results = service.build(shifts);
      expect(results.first.avgCPLH, closeTo(4.5, 0.01));
      expect(results.first.avgSPLH, closeTo(180.0, 0.01));
      expect(results.first.avgPPA, closeTo(42.0, 0.01));
    });
  });

  // ── D: Dominant favorable lever ─────────────────────────────────────────

  group('D — dominant favorable lever', () {
    test('dominant lever is the most common favorable lever in bucket', () {
      final shifts = [
        _shift(primaryLever: 'PPA_UP'),
        _shift(primaryLever: 'PPA_UP', businessDate: '2026-03-08'),
        _shift(primaryLever: 'CPLH_UP', businessDate: '2026-03-15'),
      ];
      final results = service.build(shifts);
      expect(results.first.dominantLeverId, 'ppa_up');
    });

    test('buckets without a dominant lever are excluded', () {
      // ON_MODEL shifts have no lever evidence, so no dominant lever.
      final shifts = [
        _shift(primaryLever: 'ON_MODEL'),
        _shift(primaryLever: 'ON_MODEL', businessDate: '2026-03-08'),
      ];
      expect(service.build(shifts), isEmpty);
    });
  });

  // ── E: Edge cases ────────────────────────────────────���─────────────────

  group('E — edge cases', () {
    test('bucket with only leak levers produces no win', () {
      final shifts = [
        _shift(primaryLever: 'CPLH_DOWN'),
        _shift(primaryLever: 'CPLH_DOWN', businessDate: '2026-03-08'),
      ];
      expect(service.build(shifts), isEmpty);
    });

    test('ON_MODEL-only shifts produce no wins', () {
      final shifts = [
        _shift(primaryLever: 'ON_MODEL'),
        _shift(primaryLever: 'ON_MODEL', businessDate: '2026-03-08'),
      ];
      expect(service.build(shifts), isEmpty);
    });
  });

  // ── F: Canonical fixture seed ───────────────────────────────────────────

  group('F — canonical fixture seed', () {
    test('mock replay historical closed shifts produce win evidence', () {
      final replay = MockIntegrationReplaySeed.output;
      final results = service.build(replay.historicalClosedShifts);
      expect(
        results,
        isNotEmpty,
        reason: 'historical shifts should have at least one win bucket',
      );
      for (final w in results) {
        expect(w.benchmarkCount, greaterThan(0));
        expect(w.closedShiftCount, greaterThanOrEqualTo(w.benchmarkCount));
        expect(w.dominantLeverId, isNotEmpty);
        expect(w.avgCPLH, greaterThan(0));
        expect(w.avgSPLH, greaterThan(0));
        expect(w.avgPPA, greaterThan(0));
      }
    });

    test('win labels are human-readable recurring buckets', () {
      final replay = MockIntegrationReplaySeed.output;
      final results = service.build(replay.historicalClosedShifts);
      for (final w in results) {
        expect(w.label, contains(' '));
        expect(w.label.split(' ').length, greaterThanOrEqualTo(2));
      }
    });
  });

  // ── G: Max results limit ────────────────────────────────────────────────

  group('G — max results limit', () {
    test('returns at most maxResults entries', () {
      final shifts = [
        for (final d in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'])
          _shift(dayLabel: d, daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, LearnRepeatableWinsReadService.maxResults);
    });
  });

  group('H - closed timing label provenance', () {
    test('saved timing identity resolves the Learn label', () {
      final resolver = ClosedTimingLabelResolver(const [
        ClosedTimingLabelSnapshot(
          businessTimingProfileVersionId: 'profile-v1',
          servicePeriodKey: 'dinner',
          label: 'Supper',
        ),
      ]);
      final results = service.build([
        _shift(
          dayLabel: 'Sat',
          daypart: 'dinner',
          businessTimingProfileId: 'profile-v1',
          businessTimingProfileVersionId: 'profile-v1',
          servicePeriodKey: 'dinner',
        ),
      ], timingLabelResolver: resolver);

      expect(results.single.label, 'Sat Supper');
    });

    test('legacy rows keep the daypart fallback label', () {
      final resolver = ClosedTimingLabelResolver(const [
        ClosedTimingLabelSnapshot(
          businessTimingProfileVersionId: 'profile-v1',
          servicePeriodKey: 'lunch',
          label: 'Brunch',
        ),
      ]);

      final results = service.build([
        _shift(dayLabel: 'Mon', daypart: 'lunch'),
      ], timingLabelResolver: resolver);

      expect(results.single.label, 'Mon Lunch');
    });
  });
}
