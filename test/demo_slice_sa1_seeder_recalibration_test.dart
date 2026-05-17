// Demo-data Slice SA.1 — seeder variance recalibration proof.
//
// Authority: per_daypart_targets_v1 plan (Slice SA.1, follow-up to SA);
//            the SD acceptance gate finding (closes SD §5.7); CLAUDE.md
//            HP #2 (demo writes the same tables as production — this only
//            changes the deterministic SHAPE of the seeded numbers); the
//            SB engine is the unchanged authority on the gates/floors.
//
// Guards the operator-visible defect SA.1 fixes: SA's original ±2–5%
// per-shift perturbation passed SA's own UNFILTERED dispersion test but,
// after SB's Phase-1 eligibility gates + Phase-3 MAD outlier filter + the
// joint at/above-kept-median selection, the kept-cohort all-three-strong
// CPLH band collapsed below SB's principled `minTeachableWidthCPLH`
// (`building_flat` for lunch) and late_night had only 4 all-three-strong
// shifts (< `minBenchmark`=5 → `building_few_strong`). The demo was
// therefore NOT teachable end-to-end through the REAL engine over the
// REAL `_seedRecommendationCandidates`-equivalent cohort.
//
// This test runs the REAL `RecommendedBenchmarkSelectionService` over a
// candidate cohort built the same way `_seedRecommendationCandidates`
// builds it (the exact cohort the demo cycle consumes) and asserts:
//   1. EVERY service period → verdict `teachable`, operationVerdict
//      `teachable`.
//   2. Post-gate/MAD kept-cohort `stdev(CPLH) > minKeptStdevCPLH` per
//      period (SB's floor is honored, NOT changed).
//   3. The all-three-strong benchmark set is ≥ `minBenchmark` with a
//      P25–P75 width > `minTeachableWidthCPLH` per period.
//   4. Determinism — two `generateForDate` calls are byte-identical
//      (the file-header no-RNG invariant).
//
// The per-shift lever / 8-family / week-aggregate invariants SA.1 must
// NOT break are pinned by `demo_slice_b_driver_variance_test` and
// `replay_week_driver_rotation_test` (both still green post-SA.1).

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';

double _stdev(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = xs.reduce((a, b) => a + b) / xs.length;
  final v =
      xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / xs.length;
  return math.sqrt(v);
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _mad(List<double> sorted, double med) {
  final dev = sorted.map((v) => (v - med).abs()).toList()..sort();
  return _median(dev);
}

double _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  if (sorted.length == 1) return sorted.first;
  final pos = (sorted.length - 1) * q;
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

String _addIsoDays(String isoDate, int days) {
  final r = DateTime.parse(isoDate).add(Duration(days: days));
  return '${r.year}-${r.month.toString().padLeft(2, '0')}'
      '-${r.day.toString().padLeft(2, '0')}';
}

/// Mirrors `_seedRecommendationCandidates` in
/// `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`
/// EXACTLY: historical closed + current-week closed shifts whose
/// `businessDate` is inside the cycle's 60-day calibration window
/// `[businessDate-59 .. businessDate]` — the EXACT cohort the demo
/// `TargetCycle` build consumes through the real
/// `RecommendedBenchmarkSelectionService`. The 60-day window is
/// load-bearing: the engine only ever sees a CONTIGUOUS ~8-week slice
/// of the 12 historical weeks, which is what SA.1 must make teachable.
List<BaselineCandidateShift> _seedEquivalentCohort(MockReplayOutput replay) {
  final businessDate = MockIntegrationReplaySeed.defaultBusinessDate;
  final startDate = _addIsoDays(businessDate, -59);
  final closed = <ShiftRecord>[
    ...replay.historicalClosedShifts,
    ...replay.currentWeekShifts.where((s) => s.status == 'closed'),
  ];
  return closed
      .where((s) =>
          s.businessDate != null &&
          s.businessDate!.compareTo(startDate) >= 0 &&
          s.businessDate!.compareTo(businessDate) <= 0)
      .map((s) => BaselineCandidateShift(
            recordKey: '${s.weekId}|${s.dayLabel}|${s.daypart}',
            weekId: s.weekId,
            weekLabel: s.weekId,
            dayLabel: s.dayLabel,
            daypart: s.daypart,
            covers: s.covers,
            cplh: s.cplh,
            splh: s.splh,
            ppa: s.ppa,
            primaryLeverId: s.normalizedLeverId,
            isSelected: false,
            businessDate: s.businessDate,
            actualLaborPct: s.totalLaborPct,
            hasActualLaborPctTruth: s.hasSourceBackedTotalLaborPct,
          ))
      .toList();
}

void main() {
  const cfg = RecommendedSelectionConfig();
  final svc = RecommendedBenchmarkSelectionService.instance;

  group('Slice SA.1 — real engine returns teachable for every period', () {
    final cohort =
        _seedEquivalentCohort(MockIntegrationReplaySeed.output);
    final selection = svc.select(cohort);

    test('operationVerdict is teachable', () {
      expect(selection.operationVerdict, BenchmarkVerdict.teachable,
          reason: 'the demo must be teachable end-to-end through the '
              'REAL engine (SD §5.7)');
    });

    for (final period in MockIntegrationReplaySeed.demoServicePeriodIds) {
      test('$period → teachable with a real band over SB gates+MAD', () {
        final stats = selection.perDaypartStats[period];
        expect(stats, isNotNull, reason: '$period must have stats');
        expect(stats!.verdict, BenchmarkVerdict.teachable,
            reason: '$period must be teachable (was building_flat / '
                'building_few_strong before SA.1)');

        // Re-derive SB's kept cohort (Phase-1 gates → Phase-3 MAD) to
        // assert the dispersion floor is honored — NOT lowered — and the
        // all-three-strong band clears `minTeachableWidthCPLH`.
        final all =
            cohort.where((c) => c.daypart == period).toList();
        final elig = all.where((c) {
          if (!c.cplh.isFinite || !c.splh.isFinite || !c.ppa.isFinite) {
            return false;
          }
          if (c.covers < cfg.minCoversPerShift) return false;
          if (c.cplh <= 0 || c.splh <= 0 || c.ppa <= 0) return false;
          final foh = c.covers / c.cplh;
          final boh = (c.covers * c.ppa) / c.splh;
          if (foh + boh < cfg.minHoursPerShift) return false;
          return true;
        }).toList();
        final cplhSorted = elig.map((c) => c.cplh).toList()..sort();
        final med = _median(cplhSorted);
        final adjMad = _mad(cplhSorted, med) * 1.4826;
        final thr = cfg.madK * adjMad;
        final kept = elig
            .where((c) => !(adjMad > 0 && (c.cplh - med).abs() > thr))
            .toList();

        final keptStdev = _stdev(kept.map((c) => c.cplh).toList());
        expect(keptStdev, greaterThan(cfg.minKeptStdevCPLH),
            reason: '$period post-gate/MAD kept CPLH stdev '
                '($keptStdev) must clear SB\'s UNCHANGED '
                'minKeptStdevCPLH (${cfg.minKeptStdevCPLH})');

        final keptMedC = _median(kept.map((c) => c.cplh).toList());
        final keptMedS = _median(kept.map((c) => c.splh).toList());
        final keptMedP = _median(kept.map((c) => c.ppa).toList());
        final bench = kept
            .where((c) =>
                c.cplh >= keptMedC &&
                c.splh >= keptMedS &&
                c.ppa >= keptMedP)
            .toList();
        expect(bench.length, greaterThanOrEqualTo(cfg.minBenchmark),
            reason: '$period must have ≥ minBenchmark '
                '(${cfg.minBenchmark}) all-three-strong shifts; '
                'got ${bench.length}');

        final benchC = bench.map((c) => c.cplh).toList()..sort();
        final width =
            _quantile(benchC, 0.75) - _quantile(benchC, 0.25);
        expect(width, greaterThan(cfg.minTeachableWidthCPLH),
            reason: '$period all-three-strong P25–P75 width ($width) '
                'must exceed SB\'s minTeachableWidthCPLH '
                '(${cfg.minTeachableWidthCPLH}) — this is the band '
                'collapse SA.1 fixes');

        // The engine produced a real, drawable band for the period.
        expect(stats.opzFloorCPLH, greaterThan(0));
        expect(stats.opzCeilingCPLH, greaterThan(stats.opzFloorCPLH));
      });
    }
  });

  group('Slice SA.1 — determinism (hard invariant: no RNG)', () {
    test('two generateForDate calls are byte-identical', () {
      final a = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);
      final b = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);

      String key(ShiftRecord s) => s.toMap().toString();

      expect(a.historicalClosedShifts.length,
          b.historicalClosedShifts.length);
      for (var i = 0; i < a.historicalClosedShifts.length; i++) {
        expect(key(a.historicalClosedShifts[i]),
            key(b.historicalClosedShifts[i]),
            reason: 'closed shift #$i must be byte-identical (no RNG)');
      }
      expect(a.currentWeekShifts.length, b.currentWeekShifts.length);
      for (var i = 0; i < a.currentWeekShifts.length; i++) {
        expect(key(a.currentWeekShifts[i]), key(b.currentWeekShifts[i]),
            reason: 'current-week shift #$i must be byte-identical');
      }
      for (var i = 0; i < a.weekRecords.length; i++) {
        expect(a.weekRecords[i].toMap().toString(),
            b.weekRecords[i].toMap().toString(),
            reason: 'week record #$i must be byte-identical');
      }
    });
  });
}
