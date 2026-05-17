// Per-Daypart Targets V1 — Slice SB. Jim-faithful benchmark selection.
//
// Replaces the Phase-7.55p.5g "rank shifts by CPLH desc, take top-N,
// then penalise the same cohort for low PPA" pipeline (which was
// self-defeating, used an unstable sort, let one weak daypart poison
// all, and carried a dead `qualifyingDayparts` check) with Jim
// Taylor's actual method (deep-dive Ch.09 / Ch.11 / Ch.12):
//
//   Phase 1 — Eligibility gates       → crash-safe; drop non-finite /
//                                       non-positive / thin shifts
//   Phase 2 — Daypart stratification  → group by daypart independently
//   Phase 3 — MAD outlier removal     → robust k=3σ filter on CPLH
//   Phase 4 — Joint selection         → benchmark set = shifts AT/ABOVE
//                                       the kept-cohort median on CPLH
//                                       AND SPLH AND PPA *simultaneously*
//                                       (Ch.09 "all three high together"),
//                                       NOT a CPLH ranking
//   Phase 5 — Robust band             → floor=P25, ceiling=P75, target=
//                                       median of the benchmark-set CPLH
//                                       (Decision 3 locked: median)
//   Phase 6 — Verdict                 → teachable / building_early /
//                                       building_flat / building_few_strong
//                                       / running_hot, per daypart, no
//                                       cross-daypart poisoning
//
// Every daypart is graded on its own (Ch.09 "lunch and dinner are
// different businesses"). The operation verdict is a rollup, never a
// poisoner: teachable if any period teachable; else running_hot if any
// running_hot; else the most-informative building_*.
//
// Determinism: a stable compound order `(cplh desc, recordKey asc)` is
// used everywhere and the output map is daypart-key-ascending so the
// selected set, band, and verdicts are byte-identical under any input
// permutation (kills the tied-CPLH instability the old `List.sort` had).
//
// Pure, no I/O. The caller passes a candidate list already filtered to
// the 60-day window + restaurant scope and receives a
// `RecommendedBenchmarkSelection`. Back-compat fields (`overallQuality`,
// `cohortQuality`, `unionOpz*`, `pooled*`) are still populated for
// legacy consumers; `overallQuality` is derived consistently from the
// new verdict so the Benchmark-graph signal stays non-contradictory.

import 'dart:math' as math;

import '../models/recommended_benchmark_selection.dart';
import '../../models/baseline_candidate_shift.dart';

/// Configurable thresholds — defaults match the validated SB prototype
/// (`_JimFaithfulSelector`, 23 tests + 800-dataset fuzz, 0 self-defeat)
/// and the locked operator decisions (spec §8).
class RecommendedSelectionConfig {
  /// Phase 1: eligibility gates.
  final int minCoversPerShift;
  final double minHoursPerShift;

  /// Phase 2: daypart stratification gate (also the "early/thin cohort"
  /// floor: a cohort below this after gates+MAD → `building_early`).
  final int minDaypartCohort;

  /// Phase 3: MAD multiplier.
  final double madK;

  /// Phase 4: minimum number of all-three-strong shifts before a band
  /// is teachable. Below this → `building_few_strong` (Ch.09 "a target
  /// built from too few good shifts is your best Wednesday disguised as
  /// a standard").
  final int minBenchmark;

  /// Dispersion floor (Ch.09 "a spike is not a range"). If the kept
  /// cohort's CPLH barely varies OR the benchmark band collapses, there
  /// is no usable range → `building_flat` (never a fake point, never
  /// "too narrow").
  final double minKeptStdevCPLH;
  final double minTeachableWidthCPLH;

  /// Absolute running-hot guardrail (Decision 5 locked, two-signal).
  /// Both must hold: (a) benchmark-cohort median PPA is > this fraction
  /// below the daypart-wide median PPA, AND (b) benchmark-cohort median
  /// actual labor-% exceeds the daypart-wide median labor-% by > this
  /// fraction relative.
  final double runningHotPpaRelativeGap;
  final double runningHotLaborPctRelativeGap;

  /// Retained for legacy `RecommendedSelectionConfig` callers / tests.
  /// SB no longer thresholds a cross-daypart union width (the vestigial
  /// "RANGE TOO WIDE TO TEACH" state was removed per spec §6c / §8); the
  /// field is kept so existing construction sites still compile.
  final double unionAdequateCap;

  const RecommendedSelectionConfig({
    this.minCoversPerShift = 20,
    this.minHoursPerShift = 2,
    this.minDaypartCohort = 3,
    this.madK = 3.0,
    this.minBenchmark = 5,
    this.minKeptStdevCPLH = 0.05,
    this.minTeachableWidthCPLH = 0.03,
    this.runningHotPpaRelativeGap = 0.10,
    this.runningHotLaborPctRelativeGap = 0.10,
    this.unionAdequateCap = 1.25,
  });
}

class RecommendedBenchmarkSelectionService {
  RecommendedBenchmarkSelectionService._();
  static final RecommendedBenchmarkSelectionService instance =
      RecommendedBenchmarkSelectionService._();

  /// Runs the full Jim-faithful pipeline against [candidates]. Pure and
  /// deterministic given the same input *set* — output is invariant
  /// under any permutation of [candidates].
  ///
  /// The caller is responsible for passing candidates already filtered
  /// to the 60-day window and restaurant scope.
  RecommendedBenchmarkSelection select(
    List<BaselineCandidateShift> candidates, {
    RecommendedSelectionConfig config = const RecommendedSelectionConfig(),
  }) {
    // ── Phase 1: Eligibility gates (crash-safe) ─────────────────────
    final excludedByGate = <String>{};
    final byDaypart = <String, List<BaselineCandidateShift>>{};
    for (final c in candidates) {
      if (!_passesGates(c, config)) {
        excludedByGate.add(c.recordKey);
        continue;
      }
      (byDaypart[c.daypart] ??= <BaselineCandidateShift>[]).add(c);
    }

    if (byDaypart.isEmpty) {
      return RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: excludedByGate,
        reason: 'No candidate shifts passed eligibility gates.',
      );
    }

    final perDaypartStats = <String, DaypartCohortStats>{};
    final selectedIds = <String>{};
    final outlierIds = <String>{};

    // Deterministic daypart iteration (key asc) so map ordering and any
    // downstream "first" reads never depend on input order.
    final orderedDaypartKeys = byDaypart.keys.toList()..sort();

    for (final daypart in orderedDaypartKeys) {
      final cohort = byDaypart[daypart]!;

      // ── Phase 2: thin cohort → building_early ──────────────────────
      if (cohort.length < config.minDaypartCohort) {
        perDaypartStats[daypart] = _building(
          daypart: daypart,
          verdict: BenchmarkVerdict.buildingEarly,
          eligibleCount: cohort.length,
          reason:
              'Only ${cohort.length} eligible shifts so far. We need at '
              'least ${config.minDaypartCohort} before we can read a range.',
        );
        continue;
      }

      // ── Phase 3: MAD outlier removal on CPLH ──────────────────────
      final cplhSorted = cohort.map((c) => c.cplh).toList()..sort();
      final median = _median(cplhSorted);
      final adjustedMad = _mad(cplhSorted, median) * 1.4826;
      final madThreshold = config.madK * adjustedMad;

      final kept = <BaselineCandidateShift>[];
      final outlierForThisDaypart = <String>[];
      for (final c in cohort) {
        final isOutlier =
            adjustedMad > 0 && (c.cplh - median).abs() > madThreshold;
        if (isOutlier) {
          outlierForThisDaypart.add(c.recordKey);
        } else {
          kept.add(c);
        }
      }
      outlierIds.addAll(outlierForThisDaypart);

      if (kept.length < config.minDaypartCohort) {
        perDaypartStats[daypart] = _building(
          daypart: daypart,
          verdict: BenchmarkVerdict.buildingEarly,
          eligibleCount: cohort.length,
          outlierCount: outlierForThisDaypart.length,
          reason:
              'Too few clean shifts left after dropping unusual ones. '
              'We need more closed shifts before we can read a range.',
        );
        continue;
      }

      // Reported / diagnostic stats over the kept cohort.
      final keptCplh = kept.map((c) => c.cplh).toList()..sort();
      final keptMedianCplh = _median(keptCplh);
      final keptMad = _mad(keptCplh, keptMedianCplh);
      final iqr = _iqr(keptCplh);

      // Selection-gate medians: computed over the KEPT cohort (the
      // joint at/above-all-three-medians filter uses these).
      final keptMedianPpa =
          _median(kept.map((c) => c.ppa).toList()..sort());

      // Running-hot signals compare the benchmark set against the
      // DAYPART-WIDE distribution (every eligible shift in the daypart,
      // pre-MAD, pre-selection). This is distinct from the kept-cohort
      // medians used for selection: the all-three-strong filter
      // guarantees the benchmark median PPA is >= the *kept* median by
      // construction, so signal (a) is only meaningful against the
      // broader daypart norm. When CPLH and PPA trade off (the team
      // bought throughput by sacrificing spend), the high-CPLH
      // benchmark set's median PPA sits well below the daypart-wide
      // median even though each member cleared the kept median —
      // exactly the "running hot" condition (Decision 5).
      final daypartMedianPpa =
          _median(cohort.map((c) => c.ppa).toList()..sort());
      final daypartKnownLaborPct = cohort
          .where((c) => c.hasActualLaborPctTruth)
          .map((c) => c.actualLaborPct)
          .toList()
        ..sort();
      final double? daypartMedianLaborPct = daypartKnownLaborPct.isEmpty
          ? null
          : _median(daypartKnownLaborPct);

      // ── Dispersion floor (Ch.09 "a spike is not a range") ─────────
      final keptStdevCplh = _stdev(kept.map((c) => c.cplh).toList());
      if (keptStdevCplh < config.minKeptStdevCPLH) {
        perDaypartStats[daypart] = _building(
          daypart: daypart,
          verdict: BenchmarkVerdict.buildingFlat,
          eligibleCount: cohort.length,
          outlierCount: outlierForThisDaypart.length,
          medianCPLH: keptMedianCplh,
          madCPLH: keptMad,
          iqrCPLH: iqr,
          medianPPA: daypartMedianPpa,
          medianLaborPct: daypartMedianLaborPct,
          reason:
              'Covers per hour barely changes across these shifts. There '
              'is no real operating range yet, only a single value.',
        );
        continue;
      }

      // ── Selection sub-medians (kept cohort) ───────────────────────
      final medC = keptMedianCplh;
      final medS = _median(kept.map((c) => c.splh).toList()..sort());
      final medP = keptMedianPpa;

      // ── Absolute running-hot guardrail (Decision 5, two-signal) ───
      // Evaluated FIRST, before the all-three-strong band, because Jim's
      // running-hot concept is a health verdict on the THROUGHPUT-strong
      // shifts, and those shifts (low spend / high labor) cannot survive
      // the all-three-strong PPA sub-gate — see the interpretation note
      // below. BOTH required: (a) the throughput-strong cohort's median
      // PPA is below the daypart-wide median PPA by the configured
      // relative gap; AND (b) its median actual labor-% is above the
      // daypart-wide median labor-% by the configured relative gap.
      // Labor truth absent → signal (b) cannot be confirmed → do NOT
      // flag (fall through to the all-three-strong teachable/building
      // path). running_hot still reports a real band+target (it is
      // real, just not healthy) — built from the throughput-strong
      // cohort's CPLH.
      //
      // FAITHFUL-INTERPRETATION NOTE (surfaced for orchestrator audit):
      // the spec scopes the benchmark set as shifts at/above the
      // kept-cohort median on CPLH AND SPLH AND PPA simultaneously. That
      // PPA sub-gate guarantees the benchmark set's median PPA is >= the
      // kept-cohort PPA median *by construction*, so a "benchmark-cohort
      // median PPA > 10% below the daypart-wide median PPA" signal
      // computed on the all-three-strong set is mathematically
      // unreachable (proved with the L-group fixtures: any below-norm
      // PPA throughput shift fails the PPA selection gate, yielding
      // building_few_strong, never running_hot). Jim's actual
      // running-hot concept (deep-dive Ch.09 / Decision 5: "your best
      // shifts ran hot — high covers, weaker spend and labor") is about
      // the THROUGHPUT-strong shifts (strong on covers-per-hour AND
      // sales-per-hour) having sacrificed spend + labor. The two
      // running-hot signals are therefore evaluated on the
      // throughput-strong cohort (CPLH AND SPLH at/above the kept
      // median), which is NOT PPA-bounded and so makes the guardrail
      // genuinely reachable. A healthy operation's teachable BAND is
      // still the all-three-strong set exactly as scoped (below); only
      // the unhealthy running-hot verdict + its band derive from the
      // throughput-strong cohort. This is the single interpretation
      // that honors BOTH scoped rules.
      final throughputStrong = kept
          .where((c) => c.cplh >= medC && c.splh >= medS)
          .toList();
      final tsMedianPpa = throughputStrong.isEmpty
          ? medP
          : _median(throughputStrong.map((c) => c.ppa).toList()..sort());
      final tsKnownLaborPct = throughputStrong
          .where((c) => c.hasActualLaborPctTruth)
          .map((c) => c.actualLaborPct)
          .toList()
        ..sort();
      final double? tsMedianLaborPct =
          tsKnownLaborPct.isEmpty ? null : _median(tsKnownLaborPct);

      final ppaSignal = daypartMedianPpa > 0 &&
          tsMedianPpa <
              daypartMedianPpa * (1 - config.runningHotPpaRelativeGap);
      final laborSignal = daypartMedianLaborPct != null &&
          daypartMedianLaborPct > 0 &&
          tsMedianLaborPct != null &&
          tsMedianLaborPct >
              daypartMedianLaborPct *
                  (1 + config.runningHotLaborPctRelativeGap);

      if (ppaSignal &&
          laborSignal &&
          throughputStrong.length >= config.minBenchmark) {
        // running_hot is real: report a band+target from the
        // throughput-strong cohort's CPLH (genuine productivity, just
        // not healthy spend/labor).
        final tsCplh = throughputStrong.map((c) => c.cplh).toList()
          ..sort();
        final tsFloor = _quantile(tsCplh, 0.25);
        final tsCeiling = _quantile(tsCplh, 0.75);
        final tsTarget = _median(tsCplh);
        for (final s in throughputStrong) {
          selectedIds.add(s.recordKey);
        }
        perDaypartStats[daypart] = DaypartCohortStats(
          daypart: daypart,
          eligibleCount: cohort.length,
          outlierCount: outlierForThisDaypart.length,
          selectedCount: throughputStrong.length,
          selectedCoverSum:
              throughputStrong.fold<int>(0, (s, c) => s + c.covers),
          medianCPLH: keptMedianCplh,
          madCPLH: keptMad,
          iqrCPLH: iqr,
          medianPPA: tsMedianPpa,
          medianLaborPct: tsMedianLaborPct,
          opzFloorCPLH: tsFloor,
          opzCeilingCPLH: tsCeiling,
          recommendedTargetCPLH: tsTarget,
          recommendedTargetSPLH: _median(
              throughputStrong.map((c) => c.splh).toList()..sort()),
          recommendedTargetPPA: tsMedianPpa,
          cohortQuality: _qualityForVerdict(BenchmarkVerdict.runningHot),
          cohortExplanation:
              '${throughputStrong.length} high-throughput shifts with '
              'spend below and labor above the rest of this period.',
          verdict: BenchmarkVerdict.runningHot,
          verdictReason:
              'Your strongest shifts ran hot: spend is down and labor '
              'is up versus the rest of this period. Fix the staffing '
              'pressure before holding the team to this.',
        );
        continue;
      }

      // ── Phase 4: joint CPLH AND SPLH AND PPA selection ────────────
      // Ch.09 core rule: a benchmark shift is one where covers per hour,
      // sales per hour AND spend are each at/above the kept-cohort
      // median — all three high together. NOT a CPLH ranking.
      final bench = kept
          .where((c) => c.cplh >= medC && c.splh >= medS && c.ppa >= medP)
          .toList()
        ..sort(_byCplhDescStable);

      // ── Minimum evidence → building_few_strong ────────────────────
      if (bench.length < config.minBenchmark) {
        perDaypartStats[daypart] = _building(
          daypart: daypart,
          verdict: BenchmarkVerdict.buildingFewStrong,
          eligibleCount: cohort.length,
          outlierCount: outlierForThisDaypart.length,
          medianCPLH: keptMedianCplh,
          madCPLH: keptMad,
          iqrCPLH: iqr,
          medianPPA: daypartMedianPpa,
          medianLaborPct: daypartMedianLaborPct,
          reason:
              'Only ${bench.length} shifts had covers, sales per hour and '
              'spend all strong together. We need at least '
              '${config.minBenchmark} before we can coach to a number.',
        );
        continue;
      }

      // ── Phase 5: robust band (Ch.11) ──────────────────────────────
      // Floor = P25, ceiling = P75, target = median of the
      // benchmark-set CPLH (Decision 3 locked: median, sits inside the
      // band with headroom by construction).
      final benchCplh = bench.map((c) => c.cplh).toList()..sort();
      final floor = _quantile(benchCplh, 0.25);
      final ceiling = _quantile(benchCplh, 0.75);
      final targetCplh = _median(benchCplh);
      final width = ceiling - floor;

      final targetSplh = _median(bench.map((c) => c.splh).toList()..sort());
      final targetPpa = _median(bench.map((c) => c.ppa).toList()..sort());
      final benchKnownLaborPct = bench
          .where((c) => c.hasActualLaborPctTruth)
          .map((c) => c.actualLaborPct)
          .toList()
        ..sort();
      final double? benchMedianLaborPct =
          benchKnownLaborPct.isEmpty ? null : _median(benchKnownLaborPct);
      final benchMedianPpa =
          _median(bench.map((c) => c.ppa).toList()..sort());
      final benchCoverSum = bench.fold<int>(0, (s, c) => s + c.covers);

      // ── Dispersion floor #2: collapsed band → building_flat ───────
      if (width < config.minTeachableWidthCPLH) {
        perDaypartStats[daypart] = DaypartCohortStats(
          daypart: daypart,
          eligibleCount: cohort.length,
          outlierCount: outlierForThisDaypart.length,
          selectedCount: bench.length,
          selectedCoverSum: 0,
          medianCPLH: keptMedianCplh,
          madCPLH: keptMad,
          iqrCPLH: iqr,
          medianPPA: benchMedianPpa,
          medianLaborPct: benchMedianLaborPct,
          opzFloorCPLH: 0,
          opzCeilingCPLH: 0,
          recommendedTargetCPLH: 0,
          recommendedTargetSPLH: 0,
          recommendedTargetPPA: 0,
          cohortQuality: _qualityForVerdict(BenchmarkVerdict.buildingFlat),
          cohortExplanation:
              'The strong shifts collapse to a single value. Not enough '
              'real spread to teach a band yet.',
          verdict: BenchmarkVerdict.buildingFlat,
          verdictReason:
              'The strong shifts land on one covers-per-hour value, so '
              'there is no band to coach to yet.',
        );
        continue;
      }

      final verdict = BenchmarkVerdict.teachable;
      final verdictReason =
          'Covers, sales per hour and spend were all strong together '
          'across ${bench.length} shifts. Coach the team to this number.';

      for (final s in bench) {
        selectedIds.add(s.recordKey);
      }

      perDaypartStats[daypart] = DaypartCohortStats(
        daypart: daypart,
        eligibleCount: cohort.length,
        outlierCount: outlierForThisDaypart.length,
        selectedCount: bench.length,
        selectedCoverSum: benchCoverSum,
        medianCPLH: keptMedianCplh,
        madCPLH: keptMad,
        iqrCPLH: iqr,
        medianPPA: benchMedianPpa,
        medianLaborPct: benchMedianLaborPct,
        opzFloorCPLH: floor,
        opzCeilingCPLH: ceiling,
        recommendedTargetCPLH: targetCplh,
        recommendedTargetSPLH: targetSplh,
        recommendedTargetPPA: targetPpa,
        cohortQuality: _qualityForVerdict(verdict),
        cohortExplanation:
            '${bench.length} shifts strong together; robust band '
            '${floor.toStringAsFixed(2)} to ${ceiling.toStringAsFixed(2)} '
            'CPLH, target ${targetCplh.toStringAsFixed(2)}.',
        verdict: verdict,
        verdictReason: verdictReason,
      );
    }

    if (perDaypartStats.isEmpty) {
      return RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: excludedByGate,
        reason:
            'No daypart had enough teachable evidence after stratification.',
      );
    }

    // ── Operation verdict rollup (no poisoning) ─────────────────────
    // teachable if ANY period teachable; else running_hot if ANY
    // running_hot; else the most-informative building_* across periods.
    final verdicts =
        perDaypartStats.values.map((s) => s.verdict ?? '').toList();
    final String operationVerdict;
    if (verdicts.contains(BenchmarkVerdict.teachable)) {
      operationVerdict = BenchmarkVerdict.teachable;
    } else if (verdicts.contains(BenchmarkVerdict.runningHot)) {
      operationVerdict = BenchmarkVerdict.runningHot;
    } else {
      // Most-informative building_*: few_strong > flat > early. A
      // period with strong shifts that just need more (few_strong) is
      // closer to teachable than a flat or barely-started one.
      if (verdicts.contains(BenchmarkVerdict.buildingFewStrong)) {
        operationVerdict = BenchmarkVerdict.buildingFewStrong;
      } else if (verdicts.contains(BenchmarkVerdict.buildingFlat)) {
        operationVerdict = BenchmarkVerdict.buildingFlat;
      } else {
        operationVerdict = BenchmarkVerdict.buildingEarly;
      }
    }
    final overall = _qualityForVerdict(operationVerdict);

    // ── Legacy union / pooled fields (back-compat consumers) ────────
    // Built only from periods that produced a real band (teachable /
    // running_hot). When none did, mirror the per-period zeros so the
    // union does not synthesize a phantom range.
    final banded = perDaypartStats.values
        .where((s) => s.opzFloorCPLH > 0 || s.opzCeilingCPLH > 0)
        .toList();
    final double unionFloor;
    final double unionCeiling;
    double pooledCPLH = 0;
    double pooledSPLH = 0;
    double pooledPPA = 0;
    if (banded.isEmpty) {
      unionFloor = 0;
      unionCeiling = 0;
    } else {
      unionFloor =
          banded.map((s) => s.opzFloorCPLH).reduce(math.min);
      unionCeiling =
          banded.map((s) => s.opzCeilingCPLH).reduce(math.max);
      final totalCovers =
          banded.fold<int>(0, (a, s) => a + s.selectedCoverSum);
      if (totalCovers > 0) {
        for (final s in banded) {
          final w = s.selectedCoverSum / totalCovers;
          pooledCPLH += s.recommendedTargetCPLH * w;
          pooledSPLH += s.recommendedTargetSPLH * w;
          pooledPPA += s.recommendedTargetPPA * w;
        }
      } else {
        for (final s in banded) {
          pooledCPLH += s.recommendedTargetCPLH;
          pooledSPLH += s.recommendedTargetSPLH;
          pooledPPA += s.recommendedTargetPPA;
        }
        pooledCPLH /= banded.length;
        pooledSPLH /= banded.length;
        pooledPPA /= banded.length;
      }
    }

    final explanation = _operationExplanation(
      perDaypartStats: perDaypartStats,
      operationVerdict: operationVerdict,
      selectedTotal: selectedIds.length,
    );

    return RecommendedBenchmarkSelection(
      selectedRecordIds: selectedIds,
      excludedOutlierIds: outlierIds,
      excludedByGateIds: excludedByGate,
      perDaypartStats: perDaypartStats,
      unionOpzFloorCPLH: unionFloor,
      unionOpzCeilingCPLH: unionCeiling,
      pooledRecommendedTargetCPLH: pooledCPLH,
      pooledRecommendedTargetSPLH: pooledSPLH,
      pooledRecommendedTargetPPA: pooledPPA,
      overallQuality: overall,
      explanationMetadata: explanation,
      operationVerdict: operationVerdict,
    );
  }

  // ── Private helpers ────────────────────────────────────────────────

  /// Builds a no-band `DaypartCohortStats` for a `building_*` verdict.
  /// Targets/band are zeroed (Design Rule 2: never a fake point).
  static DaypartCohortStats _building({
    required String daypart,
    required String verdict,
    required int eligibleCount,
    int outlierCount = 0,
    double medianCPLH = 0,
    double madCPLH = 0,
    double iqrCPLH = 0,
    double medianPPA = 0,
    double? medianLaborPct,
    required String reason,
  }) {
    return DaypartCohortStats(
      daypart: daypart,
      eligibleCount: eligibleCount,
      outlierCount: outlierCount,
      selectedCount: 0,
      selectedCoverSum: 0,
      medianCPLH: medianCPLH,
      madCPLH: madCPLH,
      iqrCPLH: iqrCPLH,
      medianPPA: medianPPA,
      medianLaborPct: medianLaborPct,
      opzFloorCPLH: 0,
      opzCeilingCPLH: 0,
      recommendedTargetCPLH: 0,
      recommendedTargetSPLH: 0,
      recommendedTargetPPA: 0,
      cohortQuality: _qualityForVerdict(verdict),
      cohortExplanation: reason,
      verdict: verdict,
      verdictReason: reason,
    );
  }

  /// Maps a per-period verdict onto the legacy `cohortQuality` /
  /// `overallQuality` vocabulary so back-compat consumers
  /// (Benchmark-graph signal etc.) stay consistent with the verdict and
  /// never read a contradictory label.
  static String _qualityForVerdict(String verdict) {
    switch (verdict) {
      case BenchmarkVerdict.teachable:
        return 'strong';
      case BenchmarkVerdict.runningHot:
        // A real, drawable band but not a healthy one — 'adequate'
        // keeps the graph out of the degenerate/insufficient branch
        // while signalling it is not 'strong'.
        return 'adequate';
      case BenchmarkVerdict.buildingEarly:
      case BenchmarkVerdict.buildingFlat:
      case BenchmarkVerdict.buildingFewStrong:
      default:
        return 'weak';
    }
  }

  static bool _passesGates(
      BaselineCandidateShift c, RecommendedSelectionConfig config) {
    // Crash-safety: gate out non-finite / non-positive before any stats.
    if (!c.cplh.isFinite || !c.splh.isFinite || !c.ppa.isFinite) {
      return false;
    }
    if (c.covers < config.minCoversPerShift) return false;
    if (c.cplh <= 0 || c.splh <= 0 || c.ppa <= 0) return false;

    final fohHours = c.covers / c.cplh;
    final bohHours = (c.covers * c.ppa) / c.splh;
    if (!fohHours.isFinite || !bohHours.isFinite) return false;
    if (fohHours + bohHours < config.minHoursPerShift) return false;

    return true;
  }

  /// Deterministic compound order: CPLH desc, then recordKey asc. Kills
  /// the tied-CPLH instability the old `List.sort` had (Dart's sort is
  /// not stable).
  static int _byCplhDescStable(
      BaselineCandidateShift a, BaselineCandidateShift b) {
    final c = b.cplh.compareTo(a.cplh);
    return c != 0 ? c : a.recordKey.compareTo(b.recordKey);
  }

  /// Sorted-input median. Caller must sort beforehand.
  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return 0;
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2];
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  /// Population standard deviation. 0 for n < 2.
  static double _stdev(List<double> xs) {
    if (xs.length < 2) return 0;
    final m = xs.reduce((a, b) => a + b) / xs.length;
    final v = xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) /
        xs.length;
    return math.sqrt(v);
  }

  /// Median absolute deviation — not yet × the 1.4826 consistency
  /// constant.
  static double _mad(List<double> sorted, double median) {
    final deviations = sorted.map((v) => (v - median).abs()).toList()
      ..sort();
    return _median(deviations);
  }

  /// Linear-interpolated quantile on a sorted list.
  static double _quantile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final pos = (sorted.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) return sorted[lo];
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  /// Interquartile range on a sorted list (reported statistic only).
  static double _iqr(List<double> sorted) {
    if (sorted.length < 2) return 0;
    return _quantile(sorted, 0.75) - _quantile(sorted, 0.25);
  }

  static String _operationExplanation({
    required Map<String, DaypartCohortStats> perDaypartStats,
    required String operationVerdict,
    required int selectedTotal,
  }) {
    final parts = perDaypartStats.entries
        .map((e) =>
            '${e.key}:${e.value.selectedCount}(${e.value.verdict})')
        .join(', ');
    return 'operation=$operationVerdict; selected=$selectedTotal; '
        'dayparts=[$parts]';
  }
}
