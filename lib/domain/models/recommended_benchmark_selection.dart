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
  final double unionOpzFloorCPLH;
  final double unionOpzCeilingCPLH;

  /// Cover-weighted means across qualifying dayparts. Legacy consumer
  /// fields. Not a substitute for `perDaypartStats[d].recommendedTarget*`.
  final double pooledRecommendedTargetCPLH;
  final double pooledRecommendedTargetSPLH;
  final double pooledRecommendedTargetPPA;

  final String overallQuality;
  final String explanationMetadata;

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
