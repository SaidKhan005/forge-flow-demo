/// Phase 7.55p.5g — Recommended benchmark selection output.
///
/// Produced by `RecommendedBenchmarkSelectionService` per the 7.55p.5f
/// statistics contract. Carries per-daypart cohort stats (the primary
/// output) plus legacy pooled/union fields for the current cross-daypart
/// Benchmark graph consumer.
///
/// Quality labels follow the contract vocabulary:
///   - 'strong'       — robust cohort, teachable OPZ range
///   - 'adequate'     — usable but not optimal (e.g. wide union band)
///   - 'weak'         — degenerate selected range, poor PPA diagnostic,
///                      labor % diagnostic, or low sample
///   - 'insufficient' — not enough eligible evidence to make any
///                      recommendation
library;

/// Stats for a single daypart's recommended cohort.
///
/// All CPLH/SPLH/PPA numbers come from the same selection pass:
/// eligibility-gated, MAD-outlier-filtered, CPLH-first top-N.
class DaypartCohortStats {
  final String daypart;
  final int eligibleCount;
  final int outlierCount;
  final int selectedCount;

  final double medianCPLH;
  final double madCPLH;

  /// IQR of the daypart's MAD-filtered CPLH values. Reported statistic
  /// only — this contract does not threshold IQR. See 7.55p.5f note.
  final double iqrCPLH;

  /// Diagnostic medians over the selected cohort. Used by the
  /// notably-below / notably-above flags. [medianLaborPct] is null
  /// when the cohort lacks source-backed labor truth.
  final double medianPPA;
  final double? medianLaborPct;

  /// Per-daypart OPZ band — primary output of the contract.
  final double opzFloorCPLH;
  final double opzCeilingCPLH;

  /// Trimmed-mean recommended targets for this daypart.
  final double recommendedTargetCPLH;
  final double recommendedTargetSPLH;
  final double recommendedTargetPPA;

  /// 'strong' | 'adequate' | 'weak' | 'insufficient'.
  final String cohortQuality;

  /// Human-readable one-line explanation of what drove the tier.
  final String cohortExplanation;

  const DaypartCohortStats({
    required this.daypart,
    required this.eligibleCount,
    required this.outlierCount,
    required this.selectedCount,
    required this.medianCPLH,
    required this.madCPLH,
    required this.iqrCPLH,
    required this.medianPPA,
    required this.medianLaborPct,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.recommendedTargetCPLH,
    required this.recommendedTargetSPLH,
    required this.recommendedTargetPPA,
    required this.cohortQuality,
    required this.cohortExplanation,
  });
}

/// Service output model.
///
/// `perDaypartStats` is the **primary** output. `unionOpz*` and
/// `pooledRecommendedTarget*` are explicit legacy fields for the
/// current cross-daypart graph/profile consumers and must be treated
/// as less precise.
class RecommendedBenchmarkSelection {
  final Set<String> selectedRecordIds;
  final Set<String> excludedOutlierIds;
  final Set<String> excludedByGateIds;

  final Map<String, DaypartCohortStats> perDaypartStats;

  /// Union of per-daypart OPZ floors / ceilings. Legacy consumer field.
  ///
  /// Per-Daypart Targets V1 (Slice 1): the cycle write path now reads
  /// per-period OPZ bands directly from [perDaypartStats] and recomputes
  /// the union inside the write path. This pooled-union field is kept
  /// for backward compatibility with legacy callers but is no longer
  /// the persistence target.
  @Deprecated(
    'Per-period OPZ bands are computed inside the cycle write path '
    'from perDaypartStats post-Slice-1. Use '
    'perDaypartStats[periodId].opzFloorCPLH / opzCeilingCPLH directly.',
  )
  final double unionOpzFloorCPLH;
  @Deprecated(
    'Per-period OPZ bands are computed inside the cycle write path '
    'from perDaypartStats post-Slice-1. Use '
    'perDaypartStats[periodId].opzFloorCPLH / opzCeilingCPLH directly.',
  )
  final double unionOpzCeilingCPLH;

  /// Cover-weighted means across qualifying dayparts. Legacy consumer
  /// fields. Not a substitute for `perDaypartStats[d].recommendedTarget*`.
  ///
  /// Per-Daypart Targets V1 (Slice 1): pool is now computed inside the
  /// cycle write path as a cover-weighted rollup of per-period rows
  /// (Design Rule 4). These fields are retained for callers that have
  /// not yet migrated to `perDaypartStats[periodId].recommendedTarget*`.
  @Deprecated(
    'Pool computed inside cycle write path post-Slice-1; use '
    'perDaypartStats[periodId].recommendedTargetCPLH directly.',
  )
  final double pooledRecommendedTargetCPLH;
  @Deprecated(
    'Pool computed inside cycle write path post-Slice-1; use '
    'perDaypartStats[periodId].recommendedTargetSPLH directly.',
  )
  final double pooledRecommendedTargetSPLH;
  @Deprecated(
    'Pool computed inside cycle write path post-Slice-1; use '
    'perDaypartStats[periodId].recommendedTargetPPA directly.',
  )
  final double pooledRecommendedTargetPPA;

  final String overallQuality;
  final String explanationMetadata;

  // ignore_for_file: deprecated_member_use_from_same_package
  const RecommendedBenchmarkSelection({
    required this.selectedRecordIds,
    required this.excludedOutlierIds,
    required this.excludedByGateIds,
    required this.perDaypartStats,
    required this.unionOpzFloorCPLH,
    required this.unionOpzCeilingCPLH,
    required this.pooledRecommendedTargetCPLH,
    required this.pooledRecommendedTargetSPLH,
    required this.pooledRecommendedTargetPPA,
    required this.overallQuality,
    required this.explanationMetadata,
  });

  bool get isInsufficient => overallQuality == 'insufficient';

  /// Returns the min/max span of the selected CPLH values used by
  /// legacy consumers (equivalent to the union band width).
  double get unionBandWidth =>
      unionOpzCeilingCPLH - unionOpzFloorCPLH;

  /// Empty "no recommendation possible" result. Used as an explicit
  /// honest fallback when the candidate pool yields nothing teachable.
  factory RecommendedBenchmarkSelection.insufficient({
    required Set<String> excludedByGateIds,
    required String reason,
  }) {
    return RecommendedBenchmarkSelection(
      selectedRecordIds: const <String>{},
      excludedOutlierIds: const <String>{},
      excludedByGateIds: excludedByGateIds,
      perDaypartStats: const <String, DaypartCohortStats>{},
      unionOpzFloorCPLH: 0,
      unionOpzCeilingCPLH: 0,
      pooledRecommendedTargetCPLH: 0,
      pooledRecommendedTargetSPLH: 0,
      pooledRecommendedTargetPPA: 0,
      overallQuality: 'insufficient',
      explanationMetadata: reason,
    );
  }
}
