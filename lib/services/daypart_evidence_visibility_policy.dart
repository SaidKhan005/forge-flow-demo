/// Interim visibility/confidence policy for closed-daypart evidence.
///
/// Defines when History benchmark dayparts and Learn repeatable wins
/// should render as strong evidence vs early signals vs hidden.
///
/// This is an app-side interim policy, not final live-integration behavior.
/// `7.55n` owns timing/service-period runtime; `10.5` owns live daypart truth.
///
/// See phase_7_55k_7_interim_visibility_rules.md.
library;

/// Evidence confidence tier for a single daypart evidence bucket.
enum EvidenceTier {
  /// Strong evidence: enough closed-shift depth to trust the pattern.
  strong,

  /// Early signal: favorable evidence exists but sample depth is thin.
  earlySignal,

  /// Hidden: not enough evidence to surface at all.
  hidden,
}

class DaypartEvidenceVisibilityPolicy {
  const DaypartEvidenceVisibilityPolicy._();

  /// Minimum total closed shifts in a bucket for strong benchmark evidence.
  static const strongBenchmarkMinSample = 3;

  /// Minimum favorable-lever shifts in a bucket for a repeatable win.
  /// A single favorable shift is not a repeatable pattern.
  static const repeatableWinMinFavorable = 2;

  /// Classifies a History benchmark daypart bucket.
  ///
  /// - `strong`: closedShiftCount >= [strongBenchmarkMinSample]
  /// - `earlySignal`: has favorable evidence but below threshold
  /// - `hidden`: no favorable evidence (should not reach this — filtered upstream)
  static EvidenceTier classifyBenchmark({
    required int benchmarkCount,
    required int closedShiftCount,
  }) {
    if (benchmarkCount <= 0) return EvidenceTier.hidden;
    if (closedShiftCount >= strongBenchmarkMinSample) {
      return EvidenceTier.strong;
    }
    return EvidenceTier.earlySignal;
  }

  /// Classifies a Learn repeatable-win bucket.
  ///
  /// - `strong`: benchmarkCount >= [repeatableWinMinFavorable]
  /// - `hidden`: fewer than 2 favorable shifts — not a repeatable pattern
  ///
  /// There is no `earlySignal` tier for wins: either the pattern repeats
  /// or it does not belong in Repeatable Wins.
  static EvidenceTier classifyRepeatableWin({
    required int benchmarkCount,
  }) {
    if (benchmarkCount >= repeatableWinMinFavorable) {
      return EvidenceTier.strong;
    }
    return EvidenceTier.hidden;
  }
}
