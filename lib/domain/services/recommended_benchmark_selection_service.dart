// Phase 7.55p.5g — Recommended Benchmark Selection Service.
//
// Implements the 7.55p.5f statistics contract. Pure, deterministic,
// no DB access — callers pass a candidate list and receive a
// RecommendedBenchmarkSelection. The service does NOT persist fake
// manager-override keys to make the recommended path work; it produces
// an app-owned source of truth that the TargetCycleService consumes
// alongside (never instead of) an explicit manager override.
//
// Pipeline:
//   Phase 1 — Eligibility gates      → drops non-closed/thin/incomplete
//   Phase 2 — Daypart stratification → groups by daypart, drops thin dayparts
//   Phase 3 — MAD outlier labeling   → robust k=3σ filter on CPLH per daypart
//   Phase 4 — CPLH-first top-N       → top 50% (min 3, max 10) per daypart
//   Phase 5 — Trimmed-mean center    → 10% trim, median fallback for n<5
//   Phase 6 — OPZ output             → per-daypart bands + union legacy band
//
// Spread quality checks use full-width (max − min) selected-range,
// matching the existing repo `baselineRangeValidation` semantics. IQR
// is reported on the filtered daypart cohort for observability but is
// not thresholded here (see 7.55p.5f contract).

import 'dart:math' as math;

import '../models/recommended_benchmark_selection.dart';
import '../../models/baseline_candidate_shift.dart';

/// Configurable thresholds — defaults match the 7.55p.5f contract.
class RecommendedSelectionConfig {
  /// Phase 1: eligibility gates.
  final int minCoversPerShift;
  final double minHoursPerShift;

  /// Phase 2: daypart stratification gate.
  final int minDaypartCohort;

  /// Phase 3: MAD multiplier.
  final double madK;

  /// Phase 4: top-N selection bounds.
  final double topFraction;
  final int topMin;
  final int topMax;

  /// Phase 5: trimmed-mean trim fraction.
  final double trimFraction;

  /// Degenerate-prevention width thresholds (full-width selected range).
  final double perDaypartTooWideCPLH;
  final double perDaypartTooNarrowCPLH;

  /// Union (pooled) width cap that caps `overallQuality` at 'adequate'.
  final double unionAdequateCap;

  /// Overall-quality strong gate.
  final int strongMinSelectedTotal;
  final int strongMinQualifyingDayparts;

  /// Diagnostic thresholds for the "notably below / above" quality
  /// flags on the selected cohort. Chosen per 7.55p.5g — a conservative
  /// 10% relative gap against the daypart-wide median:
  ///   - PPA:        cohort median < daypart median × (1 − relative) → weak
  ///   - labor %:    cohort median > daypart median × (1 + relative) → weak
  /// 10% is a standard "notable difference" threshold in operations
  /// dashboards and is strong enough to flag CPLH-high-but-PPA-poor or
  /// CPLH-high-but-labor-%-poor cohorts without false-positive-firing
  /// on normal cohort-to-population variation.
  final double notablePpaRelativeGap;
  final double notableLaborPctRelativeGap;

  const RecommendedSelectionConfig({
    this.minCoversPerShift = 20,
    this.minHoursPerShift = 2,
    this.minDaypartCohort = 3,
    this.madK = 3.0,
    this.topFraction = 0.50,
    this.topMin = 3,
    this.topMax = 10,
    this.trimFraction = 0.10,
    this.perDaypartTooWideCPLH = 1.25,
    this.perDaypartTooNarrowCPLH = 0.15,
    this.unionAdequateCap = 1.25,
    this.strongMinSelectedTotal = 8,
    this.strongMinQualifyingDayparts = 2,
    this.notablePpaRelativeGap = 0.10,
    this.notableLaborPctRelativeGap = 0.10,
  });
}

class RecommendedBenchmarkSelectionService {
  RecommendedBenchmarkSelectionService._();
  static final RecommendedBenchmarkSelectionService instance =
      RecommendedBenchmarkSelectionService._();

  /// Runs the full pipeline against [candidates]. Pure and deterministic
  /// given the same input.
  ///
  /// The caller is responsible for passing candidates already filtered
  /// to the 60-day window and restaurant scope.
  RecommendedBenchmarkSelection select(
    List<BaselineCandidateShift> candidates, {
    RecommendedSelectionConfig config = const RecommendedSelectionConfig(),
  }) {
    // ── Phase 1: Eligibility gates ──────────────────────────────────
    final excludedByGate = <String>{};
    final eligible = <BaselineCandidateShift>[];
    for (final c in candidates) {
      if (!_passesGates(c, config)) {
        excludedByGate.add(c.recordKey);
        continue;
      }
      eligible.add(c);
    }

    if (eligible.isEmpty) {
      return RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: excludedByGate,
        reason: 'No candidate shifts passed eligibility gates.',
      );
    }

    // ── Phase 2: Daypart stratification ──────────────────────────────
    final byDaypart = <String, List<BaselineCandidateShift>>{};
    for (final c in eligible) {
      (byDaypart[c.daypart] ??= <BaselineCandidateShift>[]).add(c);
    }

    final perDaypartStats = <String, DaypartCohortStats>{};
    final selectedIds = <String>{};
    final outlierIds = <String>{};

    for (final entry in byDaypart.entries) {
      final daypart = entry.key;
      final cohort = entry.value;

      if (cohort.length < config.minDaypartCohort) {
        // Daypart does not have enough evidence to recommend.
        continue;
      }

      // ── Phase 3: MAD outlier detection ──────────────────────────
      final cplhValues = cohort.map((c) => c.cplh).toList()..sort();
      final median = _median(cplhValues);
      final mad = _mad(cplhValues, median);
      final adjustedMad = mad * 1.4826;
      final madThreshold = config.madK * adjustedMad;

      final kept = <BaselineCandidateShift>[];
      final outlierForThisDaypart = <String>[];
      for (final c in cohort) {
        // When MAD is 0 (all values identical) no record can be an
        // outlier — keep the full cohort.
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
        // Nothing teachable left after outlier removal.
        continue;
      }

      // IQR reported on the filtered CPLH pool (Phase 3).
      final filteredCplh = kept.map((c) => c.cplh).toList()..sort();
      final iqr = _iqr(filteredCplh);

      // Diagnostic medians from the full filtered cohort, used to
      // decide "notably below/above" flags.
      final daypartMedianPPA = _median(
        kept.map((c) => c.ppa).toList()..sort(),
      );
      final keptKnownLaborPct = kept
          .where((c) => c.hasActualLaborPctTruth)
          .map((c) => c.actualLaborPct)
          .toList()
        ..sort();
      final double? daypartMedianLaborPct = keptKnownLaborPct.isEmpty
          ? null
          : _median(keptKnownLaborPct);

      // ── Phase 4: CPLH-first top-N selection ─────────────────────
      final ranked = [...kept]..sort((a, b) => b.cplh.compareTo(a.cplh));
      final desired = (ranked.length * config.topFraction).ceil();
      final bounded = desired
          .clamp(config.topMin, config.topMax)
          .clamp(0, ranked.length);
      final selected = ranked.take(bounded).toList();

      if (selected.length < config.minDaypartCohort) {
        // Not enough teachable shifts remain.
        continue;
      }

      for (final s in selected) {
        selectedIds.add(s.recordKey);
      }

      // ── Phase 5: Robust center — trimmed mean or median ────────
      final selectedCplh = selected.map((c) => c.cplh).toList()..sort();
      final selectedSplh = selected.map((c) => c.splh).toList()..sort();
      final selectedPpa = selected.map((c) => c.ppa).toList()..sort();
      final selectedKnownLaborPct = selected
          .where((c) => c.hasActualLaborPctTruth)
          .map((c) => c.actualLaborPct)
          .toList()
        ..sort();

      final trimmedCplh =
          _robustCenter(selectedCplh, config.trimFraction);
      final trimmedSplh =
          _robustCenter(selectedSplh, config.trimFraction);
      final trimmedPpa = _robustCenter(selectedPpa, config.trimFraction);

      // ── Phase 6: Per-daypart OPZ band ──────────────────────────
      final opzFloor = selectedCplh.first;
      final opzCeiling = selectedCplh.last;

      // Diagnostic medians on the selected cohort.
      final cohortMedianPpa = _median(selectedPpa);
      final double? cohortMedianLaborPct = selectedKnownLaborPct.isEmpty
          ? null
          : _median(selectedKnownLaborPct);

      // ── Cohort quality tier (contract degenerate-prevention) ───
      final selectedWidth = opzCeiling - opzFloor;
      final flags = <String>[];
      String tier = 'strong';

      if (selectedWidth > config.perDaypartTooWideCPLH) {
        tier = 'weak';
        flags.add('CPLH range too wide (${selectedWidth.toStringAsFixed(2)})');
      } else if (selectedWidth < config.perDaypartTooNarrowCPLH) {
        tier = 'weak';
        flags.add(
            'CPLH range too narrow (${selectedWidth.toStringAsFixed(2)})');
      }

      // PPA notably-below diagnostic.
      final ppaFloor =
          daypartMedianPPA * (1 - config.notablePpaRelativeGap);
      if (cohortMedianPpa < ppaFloor && daypartMedianPPA > 0) {
        tier = 'weak';
        flags.add('PPA notably below daypart median');
      }

      // Labor-% notably-above diagnostic.
      final laborCeiling = daypartMedianLaborPct == null
          ? null
          : daypartMedianLaborPct * (1 + config.notableLaborPctRelativeGap);
      if (cohortMedianLaborPct != null &&
          laborCeiling != null &&
          daypartMedianLaborPct != null &&
          cohortMedianLaborPct > laborCeiling &&
          daypartMedianLaborPct > 0) {
        tier = 'weak';
        flags.add('Labor % notably above daypart median');
      }

      // Soft tier: if no flags fired but selection is lean, call it
      // 'adequate' rather than 'strong'.
      if (tier == 'strong' && selected.length < 5) {
        tier = 'adequate';
        flags.add('Cohort size small');
      }

      final explanation = flags.isEmpty
          ? 'Robust cohort of ${selected.length} shifts '
              'covering CPLH ${opzFloor.toStringAsFixed(2)} – '
              '${opzCeiling.toStringAsFixed(2)}.'
          : flags.join('; ');

      perDaypartStats[daypart] = DaypartCohortStats(
        daypart: daypart,
        eligibleCount: cohort.length,
        outlierCount: outlierForThisDaypart.length,
        selectedCount: selected.length,
        medianCPLH: median,
        madCPLH: mad,
        iqrCPLH: iqr,
        medianPPA: cohortMedianPpa,
        medianLaborPct: cohortMedianLaborPct,
        opzFloorCPLH: opzFloor,
        opzCeilingCPLH: opzCeiling,
        recommendedTargetCPLH: trimmedCplh,
        recommendedTargetSPLH: trimmedSplh,
        recommendedTargetPPA: trimmedPpa,
        cohortQuality: tier,
        cohortExplanation: explanation,
      );
    }

    if (perDaypartStats.isEmpty) {
      return RecommendedBenchmarkSelection.insufficient(
        excludedByGateIds: excludedByGate,
        reason:
            'No daypart had enough teachable evidence after stratification.',
      );
    }

    // ── Union band (legacy cross-daypart consumer) ──────────────────
    final unionFloor = perDaypartStats.values
        .map((s) => s.opzFloorCPLH)
        .reduce(math.min);
    final unionCeiling = perDaypartStats.values
        .map((s) => s.opzCeilingCPLH)
        .reduce(math.max);

    // Cover-weighted pooled targets for legacy consumers. Weight each
    // daypart's recommended target by its selected-cover mass rather
    // than raw-averaging percentages/rates.
    final coverByDaypart = <String, int>{};
    for (final sel in selectedIds) {
      final c = candidates.firstWhere((x) => x.recordKey == sel);
      coverByDaypart[c.daypart] =
          (coverByDaypart[c.daypart] ?? 0) + c.covers;
    }
    final totalCovers =
        coverByDaypart.values.fold<int>(0, (a, b) => a + b);
    double pooledCPLH = 0;
    double pooledSPLH = 0;
    double pooledPPA = 0;
    for (final e in perDaypartStats.entries) {
      final w = (coverByDaypart[e.key] ?? 0) / (totalCovers == 0 ? 1 : totalCovers);
      pooledCPLH += e.value.recommendedTargetCPLH * w;
      pooledSPLH += e.value.recommendedTargetSPLH * w;
      pooledPPA += e.value.recommendedTargetPPA * w;
    }

    // ── Overall quality tier ────────────────────────────────────────
    final allTiers = perDaypartStats.values.map((s) => s.cohortQuality).toList();
    final qualifyingDayparts = allTiers.where((t) => t != 'insufficient').length;
    String overall;
    final totalSelected = selectedIds.length;
    final unionWidth = unionCeiling - unionFloor;

    if (totalSelected < 5) {
      overall = 'weak';
    } else if (allTiers.any((t) => t == 'weak')) {
      overall = 'weak';
    } else if (unionWidth > config.unionAdequateCap) {
      overall = 'adequate';
    } else if (totalSelected >= config.strongMinSelectedTotal &&
        qualifyingDayparts >= config.strongMinQualifyingDayparts &&
        allTiers.every((t) => t == 'strong' || t == 'adequate')) {
      overall = 'strong';
    } else {
      overall = 'adequate';
    }

    final explanation = _overallExplanation(
      perDaypartStats: perDaypartStats,
      totalSelected: totalSelected,
      unionWidth: unionWidth,
      overall: overall,
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
    );
  }

  // ── Private helpers ────────────────────────────────────────────────

  static bool _passesGates(
      BaselineCandidateShift c, RecommendedSelectionConfig config) {
    if (c.covers < config.minCoversPerShift) return false;
    if (c.cplh <= 0 || c.splh <= 0 || c.ppa <= 0) return false;

    // Derived FOH+BOH hours check: fohHours = covers/cplh,
    // bohHours ≈ (covers × ppa) / splh.
    final fohHours = c.covers / c.cplh;
    final bohHours = (c.covers * c.ppa) / c.splh;
    if (fohHours + bohHours < config.minHoursPerShift) return false;

    return true;
  }

  /// Sorted-input median. Caller must sort beforehand.
  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return 0;
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2];
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  }

  /// Median absolute deviation — not yet multiplied by the 1.4826
  /// consistency constant.
  static double _mad(List<double> sorted, double median) {
    final deviations = sorted.map((v) => (v - median).abs()).toList()
      ..sort();
    return _median(deviations);
  }

  /// Interquartile range on a sorted list. Q1/Q3 via linear
  /// interpolation between neighbours (Excel/Dart-friendly).
  static double _iqr(List<double> sorted) {
    if (sorted.length < 2) return 0;
    double quantile(double q) {
      final pos = (sorted.length - 1) * q;
      final lower = pos.floor();
      final upper = pos.ceil();
      if (lower == upper) return sorted[lower];
      final frac = pos - lower;
      return sorted[lower] + (sorted[upper] - sorted[lower]) * frac;
    }
    return quantile(0.75) - quantile(0.25);
  }

  /// 10% trimmed mean when n ≥ 5; median fallback otherwise.
  static double _robustCenter(List<double> sorted, double trim) {
    if (sorted.isEmpty) return 0;
    if (sorted.length < 5) return _median(sorted);
    final trimCount = (sorted.length * trim).floor();
    if (trimCount == 0) {
      final sum = sorted.fold<double>(0, (a, b) => a + b);
      return sum / sorted.length;
    }
    final trimmed = sorted.sublist(trimCount, sorted.length - trimCount);
    if (trimmed.isEmpty) return _median(sorted);
    final sum = trimmed.fold<double>(0, (a, b) => a + b);
    return sum / trimmed.length;
  }

  static String _overallExplanation({
    required Map<String, DaypartCohortStats> perDaypartStats,
    required int totalSelected,
    required double unionWidth,
    required String overall,
  }) {
    final parts = perDaypartStats.entries
        .map((e) =>
            '${e.key}:${e.value.selectedCount}(${e.value.cohortQuality})')
        .join(', ');
    return 'overall=$overall; selected=$totalSelected; '
        'unionWidth=${unionWidth.toStringAsFixed(2)}; dayparts=[$parts]';
  }
}
