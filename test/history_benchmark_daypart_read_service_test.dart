// Phase 7.55k.5 — History Benchmark Daypart Read Service Tests
//
// Verifies:
// A. Closed-only input — open/projected rows excluded
// B. Benchmark ranking is deterministic
// C. Sample counts and metric proofs are computed correctly
// D. Empty / no-benchmark edge cases
// E. Canonical fixture seed produces expected benchmark evidence
// F. Max results limit

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/closed_timing_label_resolver.dart';
import 'package:forge_and_flow/services/history_benchmark_daypart_read_service.dart';

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
  const service = HistoryBenchmarkDaypartReadService();

  // ── A: Closed-only input ────────────────────────────────────────────────

  group('A — closed-only input', () {
    test('open and projected shifts are excluded from benchmark evidence', () {
      final shifts = [
        _shift(status: 'closed', primaryLever: 'PPA_UP'),
        _shift(status: 'open', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(status: 'projected', dayLabel: 'Tue', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      // Only the closed shift should contribute.
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
        // Sat Dinner: 3 favorable
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
        // Mon Lunch: 1 favorable
        _shift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.first.label, 'Sat Dinner');
    });

    test('same benchmarkCount ties broken by closedShiftCount', () {
      final shifts = [
        // Wed Lunch: 1 favorable, 2 total
        _shift(dayLabel: 'Wed', daypart: 'lunch', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Wed',
          daypart: 'lunch',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-12',
        ),
        // Mon Lunch: 1 favorable, 1 total
        _shift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.first.label, 'Wed Lunch');
      expect(results.first.closedShiftCount, 2);
    });

    test('same inputs always produce same output order', () {
      final shifts = [
        _shift(dayLabel: 'Thu', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(dayLabel: 'Wed', daypart: 'dinner', primaryLever: 'PPA_UP'),
      ];
      final r1 = service.build(shifts);
      final r2 = service.build(shifts);
      expect(r1.map((s) => s.label).toList(), r2.map((s) => s.label).toList());
    });

    test('exact ties fall back to canonical day then daypart order', () {
      // All buckets: 1 favorable, 1 total — identical primary/secondary keys.
      // Canonical order should be: Thu Lunch (day 3), Fri Dinner (day 4),
      // Sat Dinner (day 5).
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
      // Fri Lunch and Fri Dinner: 1 favorable, 1 total each.
      // lunch (order 1) should rank before dinner (order 2).
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
        _shift(primaryLever: 'PPA_UP'), // favorable
        _shift(primaryLever: 'CPLH_DOWN', businessDate: '2026-03-08'), // leak
        _shift(
          primaryLever: 'CPLH_UP',
          businessDate: '2026-03-15',
        ), // favorable
      ];
      final results = service.build(shifts);
      expect(results.length, 1);
      expect(results.first.benchmarkCount, 2);
      expect(results.first.closedShiftCount, 3);
    });

    test(
      'avgCPLH and avgSPLH are computed from all closed shifts in bucket',
      () {
        final shifts = [
          _shift(cplh: 4.0, splh: 160.0, primaryLever: 'PPA_UP'),
          _shift(
            cplh: 5.0,
            splh: 200.0,
            primaryLever: 'PPA_UP',
            businessDate: '2026-03-08',
          ),
        ];
        final results = service.build(shifts);
        expect(results.first.avgCPLH, closeTo(4.5, 0.01));
        expect(results.first.avgSPLH, closeTo(180.0, 0.01));
      },
    );
  });

  // ── D: Edge cases ──────────────────────────────────────────────────────

  group('D — edge cases', () {
    test('bucket with only leak levers produces no benchmark', () {
      final shifts = [
        _shift(primaryLever: 'CPLH_DOWN'),
        _shift(primaryLever: 'CPLH_DOWN', businessDate: '2026-03-08'),
      ];
      expect(service.build(shifts), isEmpty);
    });

    test('ON_MODEL shifts do not contribute to benchmark evidence', () {
      final shifts = [
        _shift(primaryLever: 'ON_MODEL'),
        _shift(primaryLever: 'ON_MODEL', businessDate: '2026-03-08'),
      ];
      expect(service.build(shifts), isEmpty);
    });
  });

  // ── E: Canonical fixture seed ───────────────────────────────────────────

  group('E — canonical fixture seed', () {
    test('mock replay historical closed shifts produce benchmark evidence', () {
      final replay = MockIntegrationReplaySeed.output;
      final results = service.build(replay.historicalClosedShifts);
      expect(
        results,
        isNotEmpty,
        reason: 'historical shifts should have at least one benchmark bucket',
      );
      for (final b in results) {
        expect(b.benchmarkCount, greaterThan(0));
        expect(b.closedShiftCount, greaterThanOrEqualTo(b.benchmarkCount));
        expect(b.avgCPLH, greaterThan(0));
        expect(b.avgSPLH, greaterThan(0));
      }
    });

    test('benchmark labels are human-readable recurring buckets', () {
      final replay = MockIntegrationReplaySeed.output;
      final results = service.build(replay.historicalClosedShifts);
      for (final b in results) {
        expect(b.label, contains(' '));
        // Should be "DayLabel DaypartLabel" form.
        expect(b.label.split(' ').length, greaterThanOrEqualTo(2));
      }
    });
  });

  // ── F: Tier-aware truncation (7.55k.7a) ─────────────────────────────────

  group('F — tier-aware truncation', () {
    test('strong benchmark is not displaced by higher-ranked early signal', () {
      // Create a scenario where a thin bucket (2/2) has more benchmarkCount
      // than a strong bucket (1/3) — the strong bucket must still appear.
      final shifts = [
        // Wed Lunch: 2 favorable, 2 total → earlySignal (closedShiftCount < 3)
        _shift(dayLabel: 'Wed', daypart: 'lunch', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Wed',
          daypart: 'lunch',
          primaryLever: 'PPA_UP',
          businessDate: '2026-03-12',
        ),
        // Sat Dinner: 1 favorable, 3 total → strong (closedShiftCount >= 3)
        _shift(dayLabel: 'Sat', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Sat',
          daypart: 'dinner',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-08',
        ),
        _shift(
          dayLabel: 'Sat',
          daypart: 'dinner',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-15',
        ),
      ];
      final results = service.build(shifts);
      // Sat Dinner (strong) must appear before Wed Lunch (earlySignal)
      // even though Wed Lunch has higher benchmarkCount.
      expect(results.isNotEmpty, isTrue);
      expect(results.first.label, 'Sat Dinner');
    });

    test('strong buckets fill first when total exceeds maxResults', () {
      // Create 4 strong buckets — only maxResults (3) should be returned,
      // all strong, none displaced by early signals.
      final shifts = [
        for (final d in ['Mon', 'Tue', 'Wed', 'Thu']) ...[
          _shift(dayLabel: d, daypart: 'lunch', primaryLever: 'PPA_UP'),
          _shift(
            dayLabel: d,
            daypart: 'lunch',
            primaryLever: 'CPLH_DOWN',
            businessDate: '2026-03-08',
          ),
          _shift(
            dayLabel: d,
            daypart: 'lunch',
            primaryLever: 'CPLH_UP',
            businessDate: '2026-03-15',
          ),
        ],
        // One early-signal bucket that ranks high by benchmarkCount alone
        _shift(dayLabel: 'Fri', daypart: 'dinner', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Fri',
          daypart: 'dinner',
          primaryLever: 'PPA_UP',
          businessDate: '2026-03-22',
        ),
      ];
      final results = service.build(shifts);
      expect(results.length, HistoryBenchmarkDaypartReadService.maxResults);
      // All returned results should be strong (closedShiftCount >= 3).
      for (final b in results) {
        expect(
          b.closedShiftCount,
          greaterThanOrEqualTo(3),
          reason: '${b.label} should be strong tier',
        );
      }
    });

    test('early signals fill remaining slots after strong', () {
      // 1 strong + 1 early signal → both should appear (total < maxResults).
      final shifts = [
        // Mon Lunch: 1 favorable, 3 total → strong
        _shift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_UP'),
        _shift(
          dayLabel: 'Mon',
          daypart: 'lunch',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-08',
        ),
        _shift(
          dayLabel: 'Mon',
          daypart: 'lunch',
          primaryLever: 'CPLH_DOWN',
          businessDate: '2026-03-15',
        ),
        // Wed Dinner: 1 favorable, 1 total → earlySignal
        _shift(dayLabel: 'Wed', daypart: 'dinner', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, 2);
      // Strong first, then early signal
      expect(results[0].label, 'Mon Lunch');
      expect(results[0].closedShiftCount, 3);
      expect(results[1].label, 'Wed Dinner');
      expect(results[1].closedShiftCount, 1);
    });
  });

  // ── G: Max results limit ────────────────────────────────────────────────

  group('G — max results limit', () {
    test('returns at most maxResults entries', () {
      // Create 5 distinct day+daypart buckets with benchmark evidence.
      final shifts = [
        for (final d in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'])
          _shift(dayLabel: d, daypart: 'lunch', primaryLever: 'PPA_UP'),
      ];
      final results = service.build(shifts);
      expect(results.length, HistoryBenchmarkDaypartReadService.maxResults);
    });
  });

  group('H - closed timing label provenance', () {
    test('saved timing identity resolves the History label', () {
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
