/// Dev-only diagnostic check that compares two values that should be equal
/// across authority surfaces per a q-lane conformance rule.
///
/// Used by [DataAlignmentAuditReadService] to produce regression-detector
/// signals for the audit panel. A drift check is considered `drifted` when
/// both values are available and differ by more than [tolerance].
///
/// Phase 7.55r item 4, Tier 2 (scope expanded 2026-04-24):
///   - Rule 2: Shift reads benchmark targets from [ActiveTargetProfile]
///     (CPLH, PPA, labor %).
///   - Rule 3: non-closed Variance WTD reads benchmark targets from
///     [ActiveTargetProfile] (CPLH, PPA, labor %, blended wage).
///   - Wage authority: the resolved wage path should equal the profile's
///     wages (one wage truth).
///
/// Provenance-tagged drift (right number, wrong pathway) is explicitly
/// out of scope for this slice — this is value-comparison only.
library;

/// Status of a single drift check.
enum DriftCheckStatus {
  /// Both values available and within tolerance.
  aligned,

  /// Both values available but differ by more than tolerance.
  drifted,

  /// One or both values unavailable (e.g. no open shift, no locked plan);
  /// no judgment rendered.
  unavailable,
}

class DataAlignmentDriftCheck {
  /// Human-readable label for the check (e.g. "Shift Target CPLH").
  final String label;

  /// Canonical source path (e.g. "ActiveTargetProfile.targetCPLH").
  final String expectedSource;

  /// Compared source path (e.g. "ShiftDashboardReadModel.targetCPLH").
  final String comparedSource;

  /// Canonical value. Null when unavailable.
  final double? expectedValue;

  /// Compared value. Null when unavailable.
  final double? comparedValue;

  /// Absolute tolerance for equality. Chosen per metric family:
  ///   - 0.005 for rates (CPLH / SPLH at 2 decimal places)
  ///   - 0.01  for percentages (stored as 20.5 etc.)
  ///   - 0.01  for dollars
  final double tolerance;

  /// The q-lane conformance rule reference this check enforces
  /// (e.g. "Rule 2", "Rule 3", "Wage authority").
  final String ruleReference;

  const DataAlignmentDriftCheck({
    required this.label,
    required this.expectedSource,
    required this.comparedSource,
    required this.expectedValue,
    required this.comparedValue,
    required this.tolerance,
    required this.ruleReference,
  });

  /// Current drift status derived from the two values.
  DriftCheckStatus get status {
    final e = expectedValue;
    final c = comparedValue;
    if (e == null || c == null) return DriftCheckStatus.unavailable;
    return (e - c).abs() <= tolerance
        ? DriftCheckStatus.aligned
        : DriftCheckStatus.drifted;
  }

  /// Signed delta (expected - compared) when both values are present.
  double? get delta {
    final e = expectedValue;
    final c = comparedValue;
    if (e == null || c == null) return null;
    return e - c;
  }
}
