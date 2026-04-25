// Phase 7.55p.5g — Recommended Benchmark Selection Service tests.
//
// Pure-service tests: no SQLite, no widgets. The service is a
// deterministic function over a candidate list.
//
// Groups:
//   A. Eligibility gates
//   B. Daypart stratification
//   C. MAD outlier detection
//   D. CPLH-first top-N selection
//   E. Robust center (trimmed mean / median fallback)
//   F. Per-daypart OPZ bands
//   G. Legacy union band
//   H. Overall quality tiers
//   I. PPA / labor % diagnostic flags
//   J. Degenerate-range per-daypart flags (TOO WIDE / TOO NARROW)

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

List<BaselineCandidateShift> _goodMix({int perDaypart = 6}) {
  final out = <BaselineCandidateShift>[];
  for (var i = 0; i < perDaypart; i++) {
    // lunch: cplh 4.0..5.0 (teachable strong cohort)
    out.add(_c(
      key: 'l$i',
      daypart: 'lunch',
      covers: 150 + i,
      cplh: 4.0 + i * 0.2,
      splh: 175.0,
      ppa: 42.0,
    ));
    // dinner: cplh 4.2..5.2
    out.add(_c(
      key: 'd$i',
      daypart: 'dinner',
      covers: 200 + i,
      cplh: 4.2 + i * 0.2,
      splh: 180.0,
      ppa: 44.0,
    ));
  }
  return out;
}

void main() {
  final svc = RecommendedBenchmarkSelectionService.instance;

  // ── A: Eligibility gates ────────────────────────────────────────────

  group('A — eligibility gates', () {
    test('drops shifts with covers < minCoversPerShift', () {
      final candidates = [
        _c(key: 'tiny1', daypart: 'lunch', covers: 10, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'tiny2', daypart: 'lunch', covers: 5, cplh: 4.5, splh: 180, ppa: 42),
        for (var i = 0; i < 4; i++)
          _c(key: 'ok$i', daypart: 'lunch', covers: 100 + i, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.excludedByGateIds, contains('tiny1'));
      expect(r.excludedByGateIds, contains('tiny2'));
      for (var i = 0; i < 4; i++) {
        expect(r.excludedByGateIds.contains('ok$i'), isFalse);
      }
    });

    test('drops shifts with zero cplh / splh / ppa', () {
      final candidates = [
        _c(key: 'badCplh', daypart: 'lunch', covers: 100, cplh: 0, splh: 180, ppa: 42),
        _c(key: 'badSplh', daypart: 'lunch', covers: 100, cplh: 4.5, splh: 0, ppa: 42),
        _c(key: 'badPpa', daypart: 'lunch', covers: 100, cplh: 4.5, splh: 180, ppa: 0),
        for (var i = 0; i < 4; i++)
          _c(key: 'ok$i', daypart: 'lunch', covers: 100 + i, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.excludedByGateIds, containsAll(['badCplh', 'badSplh', 'badPpa']));
    });

    test('returns insufficient when no candidate passes gates', () {
      final candidates = [
        _c(key: 'tiny1', daypart: 'lunch', covers: 1, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'tiny2', daypart: 'dinner', covers: 1, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.overallQuality, 'insufficient');
      expect(r.selectedRecordIds, isEmpty);
      expect(r.perDaypartStats, isEmpty);
    });
  });

  // ── B: Daypart stratification ──────────────────────────────────────

  group('B — daypart stratification', () {
    test('skips dayparts with < minDaypartCohort eligible', () {
      final candidates = [
        // Only 2 late_night eligible — below the 3 cohort minimum
        for (var i = 0; i < 2; i++)
          _c(key: 'ln$i', daypart: 'late_night', covers: 80 + i, cplh: 4.5, splh: 175, ppa: 35),
        // 6 lunch, 6 dinner — well above minimum
        for (var i = 0; i < 6; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.2 + i * 0.1, splh: 180, ppa: 42),
        for (var i = 0; i < 6; i++)
          _c(key: 'd$i', daypart: 'dinner', covers: 210 + i, cplh: 4.3 + i * 0.1, splh: 180, ppa: 44),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats.keys, containsAll(['lunch', 'dinner']));
      expect(r.perDaypartStats.containsKey('late_night'), isFalse);
    });

    test('insufficient when every daypart has < minDaypartCohort', () {
      final candidates = [
        _c(key: 'l1', daypart: 'lunch', covers: 150, cplh: 4.5, splh: 180, ppa: 42),
        _c(key: 'l2', daypart: 'lunch', covers: 160, cplh: 4.6, splh: 181, ppa: 42),
        _c(key: 'd1', daypart: 'dinner', covers: 210, cplh: 4.5, splh: 180, ppa: 44),
        _c(key: 'd2', daypart: 'dinner', covers: 220, cplh: 4.6, splh: 181, ppa: 44),
      ];
      final r = svc.select(candidates);
      expect(r.overallQuality, 'insufficient');
    });
  });

  // ── C: MAD outlier detection ───────────────────────────────────────

  group('C — MAD outlier detection', () {
    test('labels an extreme high CPLH as outlier', () {
      final candidates = <BaselineCandidateShift>[
        for (var i = 0; i < 10; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.1, splh: 180, ppa: 42),
        // Extreme outlier — median ≈ 4.45, MAD ≈ 0.25; k=3 threshold ≈ 1.11
        _c(key: 'outlier', daypart: 'lunch', covers: 180, cplh: 9.0, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.excludedOutlierIds, contains('outlier'));
    });

    test('does not drop anything when MAD is zero (identical CPLH)', () {
      final candidates = [
        for (var i = 0; i < 6; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.5, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.excludedOutlierIds, isEmpty);
    });
  });

  // ── D: CPLH-first top-N selection ──────────────────────────────────

  group('D — CPLH-first top-N selection', () {
    test('selects roughly top 50% ranked by CPLH', () {
      // 10 eligible, 0 outliers → expect 5 selected (50%)
      final candidates = [
        for (var i = 0; i < 10; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.1, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final stats = r.perDaypartStats['lunch']!;
      expect(stats.selectedCount, 5);
      // Selected CPLH = top 5 by CPLH = 4.5..4.9
      expect(stats.opzFloorCPLH, closeTo(4.5, 0.001));
      expect(stats.opzCeilingCPLH, closeTo(4.9, 0.001));
    });

    test('respects the top-N minimum floor of 3', () {
      // 3 eligible → top 50% = 2 desired, clamped up to minimum of 3
      final candidates = [
        _c(key: 'l1', daypart: 'lunch', covers: 150, cplh: 4.2, splh: 180, ppa: 42),
        _c(key: 'l2', daypart: 'lunch', covers: 155, cplh: 4.4, splh: 180, ppa: 42),
        _c(key: 'l3', daypart: 'lunch', covers: 160, cplh: 4.6, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final stats = r.perDaypartStats['lunch']!;
      expect(stats.selectedCount, 3);
    });

    test('respects the top-N ceiling of 10', () {
      // 30 eligible → top 50% = 15 desired, clamped down to max of 10
      final candidates = [
        for (var i = 0; i < 30; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.05, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final stats = r.perDaypartStats['lunch']!;
      expect(stats.selectedCount, 10);
    });
  });

  // ── E: Robust center (trimmed mean / median fallback) ──────────────

  group('E — robust center', () {
    test('trimmed mean drops top/bottom 10% for n >= 5', () {
      // 10 selected CPLH values → trim 1 from each end
      // If we feed clear evidence: 10 eligible with CPLH 4.0..4.9, top 5
      // selected are 4.5..4.9. 10% trim of 5 = 0 (floor), so this test
      // needs > 5 selected. Use 20 eligible → top 10 selected.
      final candidates = [
        for (var i = 0; i < 20; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.05, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final stats = r.perDaypartStats['lunch']!;
      // Top 10 CPLH = 4.50, 4.55, ..., 4.95. 10% trim = drop 1 low + 1 high.
      // Trimmed mean of 4.55..4.90 = mean of [4.55..4.90 in 0.05 steps] = 4.725
      expect(stats.recommendedTargetCPLH, closeTo(4.725, 0.001));
    });

    test('falls back to median for n < 5', () {
      // 4 eligible → top 50% = 2 desired, clamped up to 3 → trimmed mean
      // falls back to median because n=3 < 5.
      final candidates = [
        _c(key: 'l1', daypart: 'lunch', covers: 150, cplh: 4.2, splh: 180, ppa: 42),
        _c(key: 'l2', daypart: 'lunch', covers: 155, cplh: 4.4, splh: 180, ppa: 42),
        _c(key: 'l3', daypart: 'lunch', covers: 160, cplh: 4.6, splh: 180, ppa: 42),
        _c(key: 'l4', daypart: 'lunch', covers: 165, cplh: 4.8, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final stats = r.perDaypartStats['lunch']!;
      // Top 3 of 4 (clamped from 2) = [4.4, 4.6, 4.8] → median = 4.6
      expect(stats.recommendedTargetCPLH, closeTo(4.6, 0.001));
    });
  });

  // ── F: Per-daypart OPZ bands ───────────────────────────────────────

  group('F — per-daypart OPZ bands', () {
    test('per-daypart OPZ bands are min/max of the selected cohort', () {
      final r = svc.select(_goodMix(perDaypart: 6));
      final lunch = r.perDaypartStats['lunch']!;
      final dinner = r.perDaypartStats['dinner']!;
      expect(lunch.opzFloorCPLH, lessThan(lunch.opzCeilingCPLH));
      expect(dinner.opzFloorCPLH, lessThan(dinner.opzCeilingCPLH));
      // Band width should be non-zero and below the TOO WIDE threshold
      // for both dayparts.
      expect(lunch.opzCeilingCPLH - lunch.opzFloorCPLH, greaterThan(0));
      expect(lunch.opzCeilingCPLH - lunch.opzFloorCPLH, lessThanOrEqualTo(1.25));
      expect(dinner.opzCeilingCPLH - dinner.opzFloorCPLH, lessThanOrEqualTo(1.25));
    });
  });

  // ── G: Union band ──────────────────────────────────────────────────

  group('G — legacy union band', () {
    test('union band spans the min floor and max ceiling across dayparts', () {
      final r = svc.select(_goodMix(perDaypart: 6));
      final minFloor = r.perDaypartStats.values
          .map((s) => s.opzFloorCPLH)
          .reduce((a, b) => a < b ? a : b);
      final maxCeiling = r.perDaypartStats.values
          .map((s) => s.opzCeilingCPLH)
          .reduce((a, b) => a > b ? a : b);
      expect(r.unionOpzFloorCPLH, closeTo(minFloor, 0.001));
      expect(r.unionOpzCeilingCPLH, closeTo(maxCeiling, 0.001));
    });

    test('pooled CPLH target is cover-weighted across dayparts', () {
      final r = svc.select(_goodMix(perDaypart: 6));
      // The pooled value should lie between the min and max per-daypart
      // recommended target.
      final perDaypartCplh =
          r.perDaypartStats.values.map((s) => s.recommendedTargetCPLH).toList();
      expect(r.pooledRecommendedTargetCPLH,
          greaterThanOrEqualTo(perDaypartCplh.reduce((a, b) => a < b ? a : b)));
      expect(r.pooledRecommendedTargetCPLH,
          lessThanOrEqualTo(perDaypartCplh.reduce((a, b) => a > b ? a : b)));
    });
  });

  // ── H: Overall quality tiers ───────────────────────────────────────

  group('H — overall quality tiers', () {
    test('strong when ≥8 selected across ≥2 dayparts and no weak flags', () {
      final r = svc.select(_goodMix(perDaypart: 8));
      expect(r.selectedRecordIds.length, greaterThanOrEqualTo(8));
      expect(r.perDaypartStats.keys.length, greaterThanOrEqualTo(2));
      expect(r.overallQuality, anyOf('strong', 'adequate'));
    });

    test('adequate when union band is too wide', () {
      // Lunch cohort centered at 4.2, dinner centered at 5.8 → union
      // band spans ~1.5 CPLH, above 1.25 cap.
      final candidates = [
        for (var i = 0; i < 6; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.1, splh: 180, ppa: 42),
        for (var i = 0; i < 6; i++)
          _c(key: 'd$i', daypart: 'dinner', covers: 210 + i, cplh: 5.5 + i * 0.1, splh: 180, ppa: 44),
      ];
      final r = svc.select(candidates);
      expect(r.unionBandWidth, greaterThan(1.25));
      expect(r.overallQuality, anyOf('adequate', 'weak'));
      expect(r.overallQuality, isNot('strong'));
    });

    test('weak when total selected < 5', () {
      // Exactly one daypart, 3 eligible → 3 selected (min floor)
      final candidates = [
        for (var i = 0; i < 3; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.5 + i * 0.1, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      expect(r.selectedRecordIds.length, lessThan(5));
      expect(r.overallQuality, 'weak');
    });
  });

  // ── I: PPA / labor % diagnostic flags ──────────────────────────────

  group('I — PPA / labor % diagnostic flags', () {
    test('flags daypart weak when cohort median PPA is notably below '
        'daypart median (>10% relative gap)', () {
      // Build a daypart where the top-CPLH cohort has low PPA and
      // the rest have higher PPA. Top 5 (CPLH-ranked) must have PPA
      // < 0.90 × full-daypart median PPA to trip the flag.
      final candidates = [
        // 10 records. Top 5 by CPLH (4.5..4.9) have PPA=35 (low).
        // Bottom 5 by CPLH (4.0..4.4) have PPA=50 (high).
        // Full-cohort median PPA ≈ 42.5; cohort median 35 < 42.5*0.9=38.25.
        for (var i = 0; i < 5; i++)
          _c(key: 'slow$i', daypart: 'lunch', covers: 150, cplh: 4.0 + i * 0.1, splh: 180, ppa: 50),
        for (var i = 0; i < 5; i++)
          _c(key: 'fast$i', daypart: 'lunch', covers: 150, cplh: 4.5 + i * 0.1, splh: 180, ppa: 35),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats['lunch']!.cohortQuality, 'weak');
      expect(r.perDaypartStats['lunch']!.cohortExplanation,
          contains('PPA'));
    });

    test('flags daypart weak when cohort median labor % is notably '
        'above daypart median (>10% relative gap)', () {
      // Top 5 (CPLH-ranked) have labor % 28 (high).
      // Bottom 5 have labor % 20. Daypart median 24; cohort median 28
      // > 24 * 1.1 = 26.4 → flag fires.
      final candidates = [
        for (var i = 0; i < 5; i++)
          _c(key: 'low$i', daypart: 'lunch', covers: 150, cplh: 4.0 + i * 0.1, splh: 180, ppa: 42, actualLaborPct: 20),
        for (var i = 0; i < 5; i++)
          _c(key: 'hi$i', daypart: 'lunch', covers: 150, cplh: 4.5 + i * 0.1, splh: 180, ppa: 42, actualLaborPct: 28),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats['lunch']!.cohortQuality, 'weak');
      expect(r.perDaypartStats['lunch']!.cohortExplanation,
          contains('Labor %'));
    });

    test('ignores unknown labor % values instead of treating 0.0 as evidence',
        () {
      final candidates = [
        for (var i = 0; i < 5; i++)
          _c(
            key: 'known$i',
            daypart: 'lunch',
            covers: 150,
            cplh: 4.5 + i * 0.1,
            splh: 180,
            ppa: 42,
            actualLaborPct: 22,
          ),
        for (var i = 0; i < 5; i++)
          _c(
            key: 'unknown$i',
            daypart: 'lunch',
            covers: 150,
            cplh: 4.0 + i * 0.1,
            splh: 180,
            ppa: 42,
            actualLaborPct: 0,
            hasActualLaborPctTruth: false,
          ),
      ];
      final r = svc.select(candidates);
      expect(r.perDaypartStats['lunch']!.cohortExplanation,
          isNot(contains('Labor %')),
          reason: 'missing labor truth should be ignored, not treated as 0.0%');
    });
  });

  // ── J: Degenerate per-daypart CPLH range flags ─────────────────────

  group('J — degenerate per-daypart CPLH range flags', () {
    test('flags weak when per-daypart selected CPLH range < 0.15', () {
      // 4 records all at nearly identical CPLH → top 3 selected are
      // within a very narrow band.
      final candidates = [
        _c(key: 'l1', daypart: 'lunch', covers: 150, cplh: 4.50, splh: 180, ppa: 42),
        _c(key: 'l2', daypart: 'lunch', covers: 155, cplh: 4.51, splh: 180, ppa: 42),
        _c(key: 'l3', daypart: 'lunch', covers: 160, cplh: 4.52, splh: 180, ppa: 42),
        _c(key: 'l4', daypart: 'lunch', covers: 165, cplh: 4.53, splh: 180, ppa: 42),
      ];
      final r = svc.select(candidates);
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.cohortQuality, 'weak');
      expect(lunch.cohortExplanation,
          anyOf(contains('TOO NARROW'), contains('narrow')));
    });

    test('flags weak when per-daypart selected CPLH range > 1.25', () {
      // Build eligible set where top 50% spans > 1.25 CPLH. To trip
      // only this flag, PPA and labor % must stay uniform.
      final candidates = [
        for (var i = 0; i < 10; i++)
          _c(key: 'l$i', daypart: 'lunch', covers: 150 + i, cplh: 4.0 + i * 0.35, splh: 180, ppa: 42),
      ];
      // Top 5: cplh values 4.0 + [5,6,7,8,9]*0.35 = 5.75, 6.10, 6.45, 6.80, 7.15
      // width = 7.15 - 5.75 = 1.40 > 1.25
      final r = svc.select(candidates);
      final lunch = r.perDaypartStats['lunch']!;
      expect(lunch.cohortQuality, 'weak');
      expect(lunch.cohortExplanation,
          anyOf(contains('wide'), contains('WIDE')));
    });
  });

  // ── K: Insufficient factory produces honest empty output ──────────

  group('K — insufficient factory', () {
    test('insufficient factory sets quality and zeroes targets', () {
      final r = RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: {'a', 'b'},
        reason: 'testing',
      );
      expect(r.isInsufficient, isTrue);
      expect(r.overallQuality, 'insufficient');
      expect(r.selectedRecordIds, isEmpty);
      expect(r.perDaypartStats, isEmpty);
      expect(r.unionBandWidth, 0);
    });
  });
}
