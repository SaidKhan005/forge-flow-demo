/// Dev-only diagnostic check shape used by the expanded
/// [DataAlignmentAuditPanel] (Phase 7.56c.1).
///
/// The original numeric-only [DataAlignmentDriftCheck] in
/// `data_alignment_drift_check.dart` is unchanged — the existing 9
/// q-lane drift checks still flow through it. This new check covers the
/// expanded audit surface the 7.56c.1 phase doc calls for:
///
///   1. Where did the live / actual value come from?
///   2. Where did the target / comparison value come from?
///
/// The shape is flexible enough to express both numeric value-vs-value
/// checks (`numeric` factory) and presence / source-label checks
/// (`presence` factory) so the panel can answer both questions with one
/// diagnostic vocabulary.
///
/// Status semantics mirror [DriftCheckStatus]:
///   - aligned     = both sides resolve and match
///   - drifted     = both sides resolve and differ
///   - unavailable = at least one side is missing (honest degradation)
library;

import 'data_alignment_drift_check.dart';

/// Stable group ids the panel uses to render section headers with
/// aligned / drifted / unavailable counts. Names are part of the audit
/// vocabulary — changing them invalidates downstream tests.
enum DataAlignmentAuditGroup {
  /// Where did the live / actual value come from?
  liveActuals,

  /// TargetCycle ↔ ActiveTargetProfile authority alignment plus the
  /// profile's own theoretical formula invariants and the active
  /// cycle's benchmark-selection summary presence.
  benchmarkAuthority,

  /// ActiveTargetProfile ↔ Shift / WTD runtime surface alignment.
  benchmarkRuntime,

  /// WeeklyPlanSnapshot ↔ projected SchedulePlan alignment plus
  /// snapshot weekly / day-row reconciliation and plan-formula
  /// invariants against the active profile.
  planLockedProjection,

  /// Locked plan ↔ Shift / WTD / Variance Full Week daypart runtime
  /// surfaces.
  planRuntime,
}

extension DataAlignmentAuditGroupTitle on DataAlignmentAuditGroup {
  /// Human-readable title rendered as the section header.
  String get title {
    switch (this) {
      case DataAlignmentAuditGroup.liveActuals:
        return 'LIVE / ACTUAL PROVENANCE';
      case DataAlignmentAuditGroup.benchmarkAuthority:
        return 'BENCHMARK AUTHORITY';
      case DataAlignmentAuditGroup.benchmarkRuntime:
        return 'BENCHMARK -> RUNTIME';
      case DataAlignmentAuditGroup.planLockedProjection:
        return 'LOCKED PLAN <-> PROJECTION';
      case DataAlignmentAuditGroup.planRuntime:
        return 'PLAN -> RUNTIME';
    }
  }
}

/// One diagnostic row rendered inside an audit-panel group.
class DataAlignmentAuditCheck {
  /// The group this check belongs to.
  final DataAlignmentAuditGroup groupId;

  /// Human-readable label (e.g. "TargetCycle CPLH -> Profile CPLH").
  final String label;

  /// Resolved alignment status. Decided at construction time so the
  /// widget does not duplicate decision logic.
  final DriftCheckStatus status;

  /// Free-form detail rendered next to the status. Examples:
  ///   - numeric: "2.50 / 2.50"
  ///   - label  : "ShiftRecord/OpenShiftSnapshot"
  ///   - missing: "—"
  final String detail;

  const DataAlignmentAuditCheck({
    required this.groupId,
    required this.label,
    required this.status,
    required this.detail,
  });

  /// Builds a numeric value-vs-value check.
  ///
  /// Aligned when both sides are non-null and within [tolerance].
  /// Drifted when both are non-null but outside tolerance.
  /// Unavailable when either side is null.
  factory DataAlignmentAuditCheck.numeric({
    required DataAlignmentAuditGroup groupId,
    required String label,
    required double? expectedValue,
    required double? comparedValue,
    required double tolerance,
    int decimals = 2,
  }) {
    final status = _numericStatus(expectedValue, comparedValue, tolerance);
    final detail = _numericDetail(expectedValue, comparedValue, decimals);
    return DataAlignmentAuditCheck(
      groupId: groupId,
      label: label,
      status: status,
      detail: detail,
    );
  }

  /// Builds an integer count-vs-count check (covers, hours, etc.).
  factory DataAlignmentAuditCheck.intCount({
    required DataAlignmentAuditGroup groupId,
    required String label,
    required int? expectedValue,
    required int? comparedValue,
  }) {
    final DriftCheckStatus status;
    final String detail;
    if (expectedValue == null || comparedValue == null) {
      status = DriftCheckStatus.unavailable;
      detail = '${expectedValue ?? '—'} / ${comparedValue ?? '—'}';
    } else {
      status = expectedValue == comparedValue
          ? DriftCheckStatus.aligned
          : DriftCheckStatus.drifted;
      detail = '$expectedValue / $comparedValue';
    }
    return DataAlignmentAuditCheck(
      groupId: groupId,
      label: label,
      status: status,
      detail: detail,
    );
  }

  /// Builds a presence / source-label check.
  ///
  /// Aligned when [actualLabel] is non-null AND, when [expectedLabel]
  /// is provided, matches it. Drifted when both are provided but
  /// disagree. Unavailable when [actualLabel] is null.
  factory DataAlignmentAuditCheck.presence({
    required DataAlignmentAuditGroup groupId,
    required String label,
    required String? actualLabel,
    String? expectedLabel,
  }) {
    final DriftCheckStatus status;
    final String detail;
    if (actualLabel == null) {
      status = DriftCheckStatus.unavailable;
      detail = '—';
    } else if (expectedLabel != null && actualLabel != expectedLabel) {
      status = DriftCheckStatus.drifted;
      detail = '$actualLabel (expected $expectedLabel)';
    } else {
      status = DriftCheckStatus.aligned;
      detail = actualLabel;
    }
    return DataAlignmentAuditCheck(
      groupId: groupId,
      label: label,
      status: status,
      detail: detail,
    );
  }

  /// Builds an aggregate match-count check (e.g. "5/7 day rows aligned").
  ///
  /// Aligned when every compared cell aligns. Drifted when any cell
  /// differs. Unavailable when [total] is 0 (no cells were available
  /// to compare).
  factory DataAlignmentAuditCheck.aggregate({
    required DataAlignmentAuditGroup groupId,
    required String label,
    required int alignedCount,
    required int total,
  }) {
    final DriftCheckStatus status;
    if (total == 0) {
      status = DriftCheckStatus.unavailable;
    } else if (alignedCount == total) {
      status = DriftCheckStatus.aligned;
    } else {
      status = DriftCheckStatus.drifted;
    }
    return DataAlignmentAuditCheck(
      groupId: groupId,
      label: label,
      status: status,
      detail: total == 0 ? '—' : '$alignedCount/$total aligned',
    );
  }

  static DriftCheckStatus _numericStatus(
    double? expected,
    double? compared,
    double tolerance,
  ) {
    if (expected == null || compared == null) {
      return DriftCheckStatus.unavailable;
    }
    return (expected - compared).abs() <= tolerance
        ? DriftCheckStatus.aligned
        : DriftCheckStatus.drifted;
  }

  static String _numericDetail(double? a, double? b, int decimals) {
    final left = a == null ? '—' : a.toStringAsFixed(decimals);
    final right = b == null ? '—' : b.toStringAsFixed(decimals);
    return '$left / $right';
  }
}

/// Aggregate counts for one audit-check group, used as the section
/// header in the panel.
class DataAlignmentAuditGroupSummary {
  final DataAlignmentAuditGroup groupId;
  final int alignedCount;
  final int driftedCount;
  final int unavailableCount;

  const DataAlignmentAuditGroupSummary({
    required this.groupId,
    required this.alignedCount,
    required this.driftedCount,
    required this.unavailableCount,
  });

  int get total => alignedCount + driftedCount + unavailableCount;

  /// Compact "X aligned, Y drifted, Z unavailable" summary line.
  String get summaryLine {
    final parts = <String>[
      if (alignedCount > 0) '$alignedCount aligned',
      if (driftedCount > 0) '$driftedCount drifted',
      if (unavailableCount > 0) '$unavailableCount unavailable',
    ];
    return parts.isEmpty ? '0 checks' : parts.join(', ');
  }
}
