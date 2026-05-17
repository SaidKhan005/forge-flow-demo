// Per-Daypart Targets V1 — Slice SB. Jim-faithful benchmark selection.
//
// Pure-service tests: no SQLite, no widgets. The service is a
// deterministic function over a candidate *set* (output invariant under
// any input permutation).
//
// This suite replaces the Phase-7.55p.5g suite that pinned the OLD
// "rank by CPLH desc, take top-N, then PPA-veto, min/max band,
// TOO NARROW / TOO WIDE" behavior. SB intentionally changes that
// behavior to Jim Taylor's actual method (joint CPLH∧SPLH∧PPA
// selection, robust P25–P75 band, median target, per-period verdict).
// Each rewritten assertion's old→new delta is documented in the PR
// Pattern-B table; the comments below state why the new behavior is the
// intended Jim-faithful behavior, not a regression.
//
// Groups:
//   A. Eligibility gates + crash-safety   (kept; gates unchanged)
//   B. Daypart stratification → building_early (was: skip/insufficient)
//   C. MAD outlier removal                (kept; robust filter unchanged)
//   D. Joint CPLH∧SPLH∧PPA selection      (was: CPLH-first top-N)
//   E. Robust band: P25/P75 + median tgt  (was: min/max + trimmed mean)
//   F. Verdict emission per period
//   G. Operation rollup (no poisoning)
//   H. Determinism under input shuffle
//   I. High-CPLH/low-PPA cluster excluded (Jim self-defeat eliminated)
//   J. Per-daypart independence
//   K. Flat / degenerate → building_flat (never a fake point)
//   L. running_hot two-signal guardrail
//   M. Insufficient factory

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';

BaselineCandidateShift _c({
  required String key,
  required String daypart,
  required int covers,
  required double cplh,
  required double splh,
  required double ppa,
  double actualLaborPct = 22.0,
  bool hasActualLaborPctTruth = true,
  bool isSelected = false,
}) {
  return BaselineCandidateShift(
    recordKey: key,
    weekId: 'W',
    weekLabel: 'W',
    dayLabel: 'D',
    daypart: daypart,
    covers: covers,
    cplh: cplh,
    splh: splh,
    ppa: ppa,
    primaryLeverId: 'cplh_up',
    isSelected: isSelected,
    businessDate: '2026-03-01',
    actualLaborPct: actualLaborPct,
    hasActualLaborPctTruth: hasActualLaborPctTruth,
  );
}

/// A cohort with genuine, correlated spread where CPLH/SPLH/PPA rise
/// together — the shape Jim's method calls teachable. 12 lunch shifts,
/// CPLH 4.0..5.1 with SPLH/PPA tracking up alongside CPLH so the
/// at/above-all-three-medians filter keeps the upper half.
List<BaselineCandidateShift> _teachableLunch({int n = 12}) {
  return [
    for (var i = 0; i < n; i++)
      _c(
        key: 'l${i.toString().padLeft(2, '0')}',
        daypart: 'lunch',
        covers: 150 + i,
        cplh: 4.0 + i * 0.1,
        splh: 170.0 + i * 1.5,
        ppa: 40.0 + i * 0.4,
      ),
  ];
}

void main() {
  final svc = RecommendedBenchmarkSelectionService.instance;

  // ── A: Eligibility gates + crash-safety ────────────────────────────

  group('A — eligibility gates + crash-safety', () {
    test('drops shifts with covers < minCoversPerShift', () {
      final candidates = [
        _c(key: 'tiny1', daypart: 'lunch', covers: 10, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'tiny2', daypart: 'lunch', covers: 5, cplh: 4.5, splh: 180, ppa: 42),
        ..._teachableLunch(),
      ];
      final r = svc.select(candidates);
      expect(r.excludedByGateIds, containsAll(['tiny1', 'tiny2']));
    });

    test('drops shifts with zero/negative cplh / splh / ppa', () {
      final candidates = [
        _c(key: 'badCplh', daypart: 'lunch', covers: 100, cplh: 0, splh: 180, ppa: 42),
        _c(key: 'badSplh', daypart: 'lunch', covers: 100, cplh: 4.5, splh: 0, ppa: 42),
        _c(key: 'badPpa', daypart: 'lunch', covers: 100, cplh: 4.5, splh: 180, ppa: 0),
        _c(key: 'negCplh', daypart: 'lunch', covers: 100, cplh: -1, splh: 180, ppa: 42),
        ..._teachableLunch(),
      ];
      final r = svc.select(candidates);
      expect(r.excludedByGateIds,
          containsAll(['badCplh', 'badSplh', 'badPpa', 'negCplh']));
    });

    test('gates out non-finite (NaN / Infinity) before any stats', () {
      final candidates = [
        _c(key: 'nan', daypart: 'lunch', covers: 100, cplh: double.nan, splh: 180, ppa: 42),
        _c(key: 'inf', daypart: 'lunch', covers: 100, cplh: double.infinity, splh: 180, ppa: 42),
        ..._teachableLunch(),
      ];
      // Must not throw, and must drop the poisoned rows.
      final r = svc.select(candidates);
      expect(r.excludedByGateIds, containsAll(['nan', 'inf']));
    });

    test('returns insufficient when no candidate passes gates', () {
      final candidates = [
        _c(key: 'tiny1', daypart: 'lunch', covers: 1, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'tiny2', daypart: 'dinner', covers: 1, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.overallQuality, 'insufficient');
      expect(r.operationVerdict, isNull);
      expect(r.selectedRecordIds, isEmpty);
      expect(r.perDaypartStats, isEmpty);
    });

    test('does not crash on empty / single input', () {
      expect(svc.select(const []).isInsufficient, isTrue);
      final one = svc.select(
          [_c(key: 's', daypart: 'lunch', covers: 100, cplh: 4.5, splh: 180, ppa: 42)]);
      // Single eligible shift in one daypart → cohort < minDaypartCohort
      // → building_early, never a crash.
      expect(one.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.buildingEarly);
    });
  });

  // ── B: Daypart stratification → building_early ─────────────────────
  //
  // OLD: a daypart below minDaypartCohort was silently *skipped*
  //      (omitted from perDaypartStats), and an all-thin input returned
  //      `insufficient`.
  // NEW: the period is graded `building_early` and DOES appear in
  //      perDaypartStats so the per-period breakdown can render an
  //      honest "not enough shifts yet" badge (spec §9 building-early).
  //      This is the intended Jim-faithful behavior: every period is
  //      graded on its own, never silently dropped.

  group('B — daypart stratification → building_early', () {
    test('thin daypart is graded building_early, not dropped', () {
      final candidates = [
        for (var i = 0; i < 2; i++)
          _c(key: 'ln$i', daypart: 'late_night', covers: 80 + i, cplh: 4.5, splh: 175, ppa: 35),
        ..._teachableLunch(),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats.containsKey('late_night'), isTrue);
      expect(r.perDaypartStats['late_night']!.verdict,
          BenchmarkVerdict.buildingEarly);
      expect(r.perDaypartStats['late_night']!.opzFloorCPLH, 0,
          reason: 'building_* never fabricates a band (Design Rule 2)');
    });

    test('all-thin input → every period building_early, operation '
        'building_early (no insufficient)', () {
      final candidates = [
        _c(key: 'l1', daypart: 'lunch', covers: 150, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'l2', daypart: 'lunch', covers: 160, cplh: 4.6, splh: 181, ppa: 42),
        _c(key: 'd1', daypart: 'dinner', covers: 210, cplh: 4.5, splh: 180, ppa: 44),
        _c(key: 'd2', daypart: 'dinner', covers: 220, cplh: 4.6, splh: 181, ppa: 44),
      ];
      final r = svc.select(candidates);
      expect(r.operationVerdict, BenchmarkVerdict.buildingEarly);
      expect(r.overallQuality, 'weak');
      for (final s in r.perDaypartStats.values) {
        expect(s.verdict, BenchmarkVerdict.buildingEarly);
      }
    });
  });

  // ── C: MAD outlier removal ─────────────────────────────────────────

  group('C — MAD outlier removal', () {
    test('an extreme high CPLH is dropped and never widens the band', () {
      final base = _teachableLunch(n: 12);
      final ceilingNoOutlier =
          svc.select(base).perDaypartStats['lunch']!.opzCeilingCPLH;
      final withOutlier = [
        ...base,
        _c(key: 'outlier', daypart: 'lunch', covers: 180, cplh: 999.0, splh: 999, ppa: 999),
      ];
      final r = svc.select(withOutlier);
      expect(r.excludedOutlierIds, contains('outlier'));
      expect(r.perDaypartStats['lunch']!.opzCeilingCPLH,
          closeTo(ceilingNoOutlier, 1e-9),
          reason: 'MAD must strip the spike so it never drags the ceiling');
    });

    test('does not drop anything when MAD is zero (identical CPLH)', () {
      final candidates = [
        for (var i = 0; i < 6; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.excludedOutlierIds, isEmpty);
      // …and the flat cohort is honestly building_flat (see group K).
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.buildingFlat);
    });
  });

  // ── D: Joint CPLH∧SPLH∧PPA selection ───────────────────────────────
  //
  // OLD: selected = top-N ranked by CPLH descending (a CPLH ranking).
  // NEW: benchmark set = shifts at/above the kept-cohort median on CPLH
  //      AND SPLH AND PPA simultaneously (Jim Ch.09 "all three high
  //      together"). This is the literal Jim method, not a ranking;
  //      the change is the entire point of the slice.

  group('D — joint CPLH∧SPLH∧PPA selection', () {
    test('benchmark set = at/above-median on all three metrics', () {
      final r = svc.select(_teachableLunch(n: 12));
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.verdict, BenchmarkVerdict.teachable);
      // 12 shifts, all three metrics rise together → kept medians sit at
      // the mid-point; the upper half (6) is the benchmark set.
      expect(lunch.selectedCount, 6);
      // selectedCoverSum is the SUM of real covers of those 6 shifts
      // (covers 156..161 for i=6..11), not the shift count.
      final expectedCoverSum =
          [156, 157, 158, 159, 160, 161].reduce((a, b) => a + b);
      expect(lunch.selectedCoverSum, expectedCoverSum);
    });

    test('a shift strong on CPLH but weak on PPA is NOT selected', () {
      // 11 well-correlated shifts + 1 with the highest CPLH but a PPA
      // far below the cohort median. The old engine ranked it IN by
      // CPLH; the Jim method excludes it (PPA < median).
      final cohort = [
        for (var i = 0; i < 11; i++)
          _c(key: 'g${i.toString().padLeft(2, '0')}', daypart: 'lunch', covers: 150 + i,
              cplh: 4.0 + i * 0.1, splh: 170.0 + i * 1.5, ppa: 40.0 + i * 0.4),
        _c(key: 'zStretch', daypart: 'lunch', covers: 200, cplh: 5.4, splh: 250, ppa: 28),
      ];
      final r = svc.select(cohort);
      expect(r.selectedRecordIds, isNot(contains('zStretch')),
          reason: 'high-CPLH/low-PPA shift fails the all-three-high gate');
    });
  });

  // ── E: Robust band — P25/P75 floor/ceiling + median target ─────────
  //
  // OLD: floor/ceiling = min/max of the selected slice; target =
  //      10% trimmed mean (median fallback for n<5).
  // NEW: floor = P25, ceiling = P75 of the benchmark-set CPLH; target =
  //      MEDIAN of the benchmark-set CPLH (Decision 3 locked: median).
  //      The robust inner band + median keeps the target strictly
  //      inside the band with headroom by construction.

  group('E — robust P25/P75 band + median target', () {
    test('target is the median of the benchmark-set CPLH, inside the band',
        () {
      final r = svc.select(_teachableLunch(n: 12));
      final lunch = r.perDaypartStats['lunch']!;
      // Benchmark set CPLH = 4.6,4.7,4.8,4.9,5.0,5.1.
      final benchCplh = [4.6, 4.7, 4.8, 4.9, 5.0, 5.1];
      final mid = (benchCplh[2] + benchCplh[3]) / 2; // even n median
      expect(lunch.recommendedTargetCPLH, closeTo(mid, 1e-9));
      // P25/P75 strictly inside min/max; target strictly inside band.
      expect(lunch.opzFloorCPLH, greaterThan(benchCplh.first));
      expect(lunch.opzCeilingCPLH, lessThan(benchCplh.last));
      expect(lunch.recommendedTargetCPLH,
          greaterThan(lunch.opzFloorCPLH));
      expect(lunch.recommendedTargetCPLH,
          lessThan(lunch.opzCeilingCPLH));
    });
  });

  // ── F: Verdict emission per period ─────────────────────────────────

  group('F — verdict emission', () {
    test('teachable cohort emits teachable verdict + non-empty reason '
        'with no em-dashes', () {
      final r = svc.select(_teachableLunch(n: 12));
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.verdict, BenchmarkVerdict.teachable);
      expect(lunch.verdictReason, isNotEmpty);
      expect(lunch.verdictReason, isNot(contains('—')));
      expect(BenchmarkVerdict.all, contains(lunch.verdict));
    });

    test('few-strong cohort emits building_few_strong', () {
      // 6 eligible, correlated, but only ~3 land at/above all three
      // medians → below minBenchmark (5) → building_few_strong.
      final cohort = [
        _c(key: 'a', daypart: 'lunch', covers: 150, cplh: 4.0, splh: 170, ppa: 40),
        _c(key: 'b', daypart: 'lunch', covers: 151, cplh: 4.2, splh: 172, ppa: 41),
        _c(key: 'c', daypart: 'lunch', covers: 152, cplh: 4.4, splh: 174, ppa: 42),
        _c(key: 'd', daypart: 'lunch', covers: 153, cplh: 4.6, splh: 176, ppa: 43),
        _c(key: 'e', daypart: 'lunch', covers: 154, cplh: 4.8, splh: 178, ppa: 44),
        _c(key: 'f', daypart: 'lunch', covers: 155, cplh: 5.0, splh: 180, ppa: 45),
      ];
      final r = svc.select(cohort);
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.buildingFewStrong);
      expect(r.perDaypartStats['lunch']!.opzFloorCPLH, 0);
    });
  });

  // ── G: Operation rollup (no poisoning) ─────────────────────────────
  //
  // OLD: "any daypart weak → overall weak" (one weak period poisoned
  //      the whole operation) + a dead `qualifyingDayparts !=
  //      'insufficient'` condition.
  // NEW: teachable if ANY period teachable; else running_hot if ANY
  //      running_hot; else the most-informative building_*. One weak
  //      period never poisons a teachable one (Ch.09 independence).

  group('G — operation rollup never poisons', () {
    test('one teachable + one thin period → operation teachable', () {
      final candidates = [
        ..._teachableLunch(n: 12),
        for (var i = 0; i < 2; i++)
          _c(key: 'ln$i', daypart: 'late_night', covers: 80 + i, cplh: 4.5, splh: 175, ppa: 35),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.teachable);
      expect(r.perDaypartStats['late_night']!.verdict,
          BenchmarkVerdict.buildingEarly);
      expect(r.operationVerdict, BenchmarkVerdict.teachable,
          reason: 'a teachable period must not be poisoned by a thin one');
      expect(r.overallQuality, 'strong');
    });
  });

  // ── H: Determinism under input shuffle ─────────────────────────────

  group('H — determinism', () {
    test('≥100 shuffles → identical selected set, verdicts, and band', () {
      // Include duplicate-tied CPLH (the exact instability the old
      // List.sort had) so the stable compound sort is exercised.
      final base = <BaselineCandidateShift>[
        for (var i = 0; i < 16; i++)
          _c(
            key: 'k${i.toString().padLeft(2, '0')}',
            daypart: i.isEven ? 'lunch' : 'dinner',
            covers: 150 + i,
            cplh: 4.5 + (i % 4) * 0.1, // ties on CPLH across records
            splh: 170.0 + (i % 5) * 2.0,
            ppa: 40.0 + (i % 3) * 0.7,
          ),
      ];
      String sig(RecommendedBenchmarkSelection r) {
        final sel = r.selectedRecordIds.toList()..sort();
        final per = r.perDaypartStats.entries
            .map((e) =>
                '${e.key}|${e.value.verdict}|${e.value.opzFloorCPLH}|'
                '${e.value.opzCeilingCPLH}|${e.value.recommendedTargetCPLH}|'
                '${e.value.selectedCoverSum}')
            .toList()
          ..sort();
        return '${r.operationVerdict}::${sel.join(",")}::${per.join(";")}';
      }

      final golden = sig(svc.select(base));
      final rng = math.Random(20260516);
      final sigs = <String>{golden};
      for (var t = 0; t < 120; t++) {
        final shuffled = [...base]..shuffle(rng);
        sigs.add(sig(svc.select(shuffled)));
      }
      expect(sigs.length, 1,
          reason: 'output must be byte-identical under any input order');
    });
  });

  // ── I: High-CPLH/low-PPA cluster excluded (self-defeat eliminated) ──
  //
  // The adversarial shape that breaks the OLD engine: a cluster with
  // the highest CPLH but collapsed PPA. The old engine ranked it IN by
  // CPLH (raising the ceiling) then flagged the cohort `weak` for low
  // PPA. The Jim method excludes it from the benchmark set entirely, so
  // it never raises the ceiling and never self-defeats.

  group('I — adversarial high-CPLH/low-PPA cluster', () {
    test('stretched cluster excluded, ceiling not dragged up, '
        'teachable band still forms', () {
      final good = [
        for (var i = 0; i < 14; i++)
          _c(key: 'g${i.toString().padLeft(2, '0')}', daypart: 'lunch', covers: 150 + i,
              cplh: 4.6 + i * 0.02, splh: 175.0 + i * 1.0, ppa: 41.0 + i * 0.2),
      ];
      final stretched = [
        for (var i = 0; i < 6; i++)
          _c(key: 's$i', daypart: 'lunch', covers: 220 + i, cplh: 6.0 + i * 0.1, splh: 300, ppa: 26),
      ];
      final r = svc.select([...good, ...stretched]);
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.verdict, BenchmarkVerdict.teachable);
      for (var i = 0; i < 6; i++) {
        expect(r.selectedRecordIds, isNot(contains('s$i')));
      }
      expect(lunch.opzCeilingCPLH, lessThan(6.0),
          reason: 'the stretched cluster must not raise the ceiling');
    });
  });

  // ── J: Per-daypart independence ────────────────────────────────────

  group('J — per-daypart independence', () {
    test('dropping one daypart shifts does not change another verdict/band',
        () {
      final lunch = _teachableLunch(n: 12);
      final dinner = [
        for (var i = 0; i < 12; i++)
          _c(key: 'd${i.toString().padLeft(2, '0')}', daypart: 'dinner', covers: 200 + i,
              cplh: 5.0 + i * 0.1, splh: 200.0 + i * 1.5, ppa: 46.0 + i * 0.4),
      ];
      final both = svc.select([...lunch, ...dinner]).perDaypartStats['lunch']!;
      final lunchOnly = svc.select(lunch).perDaypartStats['lunch']!;
      expect(both.verdict, lunchOnly.verdict);
      expect(both.opzFloorCPLH, closeTo(lunchOnly.opzFloorCPLH, 1e-12));
      expect(both.opzCeilingCPLH, closeTo(lunchOnly.opzCeilingCPLH, 1e-12));
      expect(both.recommendedTargetCPLH,
          closeTo(lunchOnly.recommendedTargetCPLH, 1e-12));
      expect(both.selectedCoverSum, lunchOnly.selectedCoverSum);
    });
  });

  // ── K: Flat / degenerate → building_flat (never a fake point) ──────
  //
  // OLD: a near-flat selected slice was flagged `weak` with a
  //      "TOO NARROW" message and STILL emitted a (near-zero-width)
  //      band + point target.
  // NEW: a cohort whose CPLH barely varies is `building_flat` with NO
  //      band and NO target (zeros). Honest "no range yet", never a
  //      fake point, never "too narrow" (spec §6b/§9 building-flat).

  group('K — flat / degenerate → building_flat', () {
    test('all-identical CPLH → building_flat, no band, no point target',
        () {
      final candidates = [
        for (var i = 0; i < 8; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.50, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.verdict, BenchmarkVerdict.buildingFlat);
      expect(lunch.opzFloorCPLH, 0);
      expect(lunch.opzCeilingCPLH, 0);
      expect(lunch.recommendedTargetCPLH, 0);
      expect(lunch.cohortExplanation, isNot(contains('narrow')));
      expect(lunch.cohortExplanation, isNot(contains('NARROW')));
      expect(lunch.verdictReason, isNot(contains('—')));
    });

    test('near-flat (sub-dispersion-floor) CPLH → building_flat', () {
      final candidates = [
        for (var i = 0; i < 8; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.50 + i * 0.002, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.buildingFlat);
    });
  });

  // ── L: running_hot two-signal guardrail (Decision 5 locked) ────────
  //
  // running_hot fires ONLY when BOTH: (a) benchmark-cohort median PPA
  // is below daypart-wide median PPA by the configured relative gap,
  // AND (b) benchmark-cohort median actual labor-% is above the
  // daypart-wide median labor-% by the configured relative gap. Labor
  // truth absent → signal (b) unconfirmable → never flag (fall through
  // to teachable). running_hot still reports a real band.
  //
  // FINDING (surfaced for orchestrator audit): the all-three-strong
  // selection gate (benchmark set = shifts at/above the kept-cohort
  // median on CPLH ∧ SPLH ∧ PPA) guarantees the benchmark set's median
  // PPA is >= the kept-cohort PPA median *by construction*. So under
  // the default 10% gap a *uniformly stretched* operation does NOT trip
  // signal (a) — its whole PPA distribution is low, so the benchmark
  // median is not 10% below the daypart-wide median. This matches spec
  // §6b limitation 1 verbatim ("a uniformly stretched operation still
  // returns teachable … this is not a regression"). running_hot is
  // therefore a guardrail for the genuine trade-off shape (benchmark
  // PPA materially below the broader-daypart norm), exercised here via
  // the explicit, documented-as-uncalibrated thresholds (spec §6b #4)
  // so the two-signal AND logic + labor-truth suppression are proven
  // deterministically. The default-threshold uniformly-stretched
  // fall-through is asserted separately as the intended behavior.

  group('L — running_hot two-signal guardrail', () {
    // A genuine throughput/spend trade-off cohort: the all-three-strong
    // benchmark set runs lower spend + higher labor-% than the rest of
    // the daypart. `lo*` shifts fail the CPLH/SPLH gate (excluded from
    // the benchmark) but carry high spend + low labor-%, establishing
    // the daypart-wide norm the benchmark set is measured against.
    List<BaselineCandidateShift> tradeoffCohort({required bool laborTruth}) {
      return [
        // Excluded-by-CPLH/SPLH, high-PPA, low-labor norm (8).
        for (var i = 0; i < 8; i++)
          _c(key: 'lo${i.toString().padLeft(2, '0')}', daypart: 'lunch',
              covers: 150 + i, cplh: 4.0 + i * 0.02, splh: 150.0 + i.toDouble(),
              ppa: 55.0, actualLaborPct: 18.0,
              hasActualLaborPctTruth: laborTruth),
        // The all-three-strong benchmark set: high CPLH+SPLH together,
        // depressed PPA, elevated labor-% (8).
        for (var i = 0; i < 8; i++)
          _c(key: 'hi${i.toString().padLeft(2, '0')}', daypart: 'lunch',
              covers: 150 + i, cplh: 4.6 + i * 0.05, splh: 220.0 + i * 2.0,
              ppa: 41.0, actualLaborPct: 30.0,
              hasActualLaborPctTruth: laborTruth),
      ];
    }

    // Thresholds explicitly documented as defaults-not-calibrated
    // (spec §6b #4): a small relative gap makes the genuine trade-off
    // shape trip the two-signal guard deterministically.
    const sensitive = RecommendedSelectionConfig(
      runningHotPpaRelativeGap: 0.05,
      runningHotLaborPctRelativeGap: 0.05,
    );

    test('both signals hold → running_hot with a real band', () {
      final r = svc.select(tradeoffCohort(laborTruth: true),
          config: sensitive);
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.verdict, BenchmarkVerdict.runningHot);
      // running_hot is real: it still reports a band + target.
      expect(lunch.opzCeilingCPLH, greaterThan(lunch.opzFloorCPLH));
      expect(lunch.recommendedTargetCPLH, greaterThan(0));
      expect(r.operationVerdict, BenchmarkVerdict.runningHot);
    });

    test('labor truth absent → signal (b) unconfirmable → NOT running_hot',
        () {
      final r = svc.select(tradeoffCohort(laborTruth: false),
          config: sensitive);
      // Without labor truth signal (b) cannot be confirmed → running_hot
      // is suppressed and the cohort falls through to the all-three
      // strong path. The trade-off shape's throughput-strong shifts have
      // below-median spend, so the all-three-strong set is too small →
      // honest building_few_strong (NOT a fabricated running_hot).
      expect(r.perDaypartStats['lunch']!.verdict,
          isNot(BenchmarkVerdict.runningHot),
          reason: 'without labor truth signal (b) cannot be confirmed');
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.buildingFewStrong);
    });

    test('only PPA signal (labor not elevated) → NOT running_hot', () {
      final cohort = [
        for (var i = 0; i < 8; i++)
          _c(key: 'lo${i.toString().padLeft(2, '0')}', daypart: 'lunch',
              covers: 150 + i, cplh: 4.0 + i * 0.02, splh: 150.0 + i.toDouble(),
              ppa: 55.0, actualLaborPct: 22.0),
        for (var i = 0; i < 8; i++)
          _c(key: 'hi${i.toString().padLeft(2, '0')}', daypart: 'lunch',
              covers: 150 + i, cplh: 4.6 + i * 0.05, splh: 220.0 + i * 2.0,
              ppa: 41.0, actualLaborPct: 22.0), // labor NOT elevated
      ];
      final r = svc.select(cohort, config: sensitive);
      expect(r.perDaypartStats['lunch']!.verdict,
          isNot(BenchmarkVerdict.runningHot),
          reason: 'PPA signal alone is insufficient (two-signal AND)');
    });

    test('uniformly stretched op at default thresholds → teachable, '
        'NOT running_hot (spec §6b limitation 1 — not a regression)', () {
      // Every shift high-CPLH/low-PPA: the whole PPA distribution is
      // low, so the benchmark median is not 10% below the daypart-wide
      // median. Correctly teaches to the restaurant's own best band.
      final cohort = [
        for (var i = 0; i < 16; i++)
          _c(key: 'u${i.toString().padLeft(2, '0')}', daypart: 'lunch',
              covers: 150 + i, cplh: 4.6 + i * 0.05, splh: 200.0 + i * 2.0,
              ppa: 33.0 + (i % 3) * 0.4, actualLaborPct: 32.0),
      ];
      final r = svc.select(cohort); // default thresholds
      expect(r.perDaypartStats['lunch']!.verdict,
          BenchmarkVerdict.teachable);
    });
  });

  // ── M: Insufficient factory ────────────────────────────────────────

  group('M — insufficient factory', () {
    test('insufficient factory sets quality and zeroes targets', () {
      final r = RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: {'a', 'b'},
        reason: 'testing',
      );
      expect(r.isInsufficient, isTrue);
      expect(r.overallQuality, 'insufficient');
      expect(r.operationVerdict, isNull);
      expect(r.selectedRecordIds, isEmpty);
      expect(r.perDaypartStats, isEmpty);
    });
  });
}
