/// Audit-only provenance shape describing the locked-week snapshot and
/// linked target cycle behind the current diagnostic read path.
///
/// Dev-only: assembled by [DataAlignmentAuditReadService] and consumed by
/// [DataAlignmentAuditPanel] so a developer can answer "which locked
/// week / which target cycle produced the values on this panel?" without
/// dropping to SQLite inspection.
///
/// Nested nullables express honest degradation. When no current-week
/// snapshot is persisted, [DataAlignmentAuditProvenance.lockedWeek] is
/// null and the panel renders "Not resolved" rows instead of a fabricated
/// locked-week identity. When the snapshot's target cycle has been
/// replaced or deleted between reads, [DataAlignmentAuditProvenance.targetCycle]
/// is null while [lockedWeek] still carries the snapshot metadata.
///
/// Phase 7.55r item 4, Tier 3 (cycle/week provenance visibility).
library;

/// Locked-week identity the audit panel is inspecting.
///
/// Sourced from the persisted [WeeklyPlanSnapshot] for the current
/// business week (read via
/// [WeeklyPlanSnapshotService.getExistingCurrentWeekSnapshot], which is
/// side-effect-free per 7.55q.2-review-fix).
class DataAlignmentLockedWeekProvenance {
  final String snapshotId;
  final String weekKey;
  final String weekStartDate;
  final String weekEndDate;
  final String targetCycleId;
  final String generatedAt;
  final String lockedAt;

  const DataAlignmentLockedWeekProvenance({
    required this.snapshotId,
    required this.weekKey,
    required this.weekStartDate,
    required this.weekEndDate,
    required this.targetCycleId,
    required this.generatedAt,
    required this.lockedAt,
  });
}

/// Target-cycle linkage for the locked week the audit panel is inspecting.
///
/// Sourced from the [TargetCycle] referenced by
/// [DataAlignmentLockedWeekProvenance.targetCycleId]. When the cycle row
/// is missing at read time, the whole shape is null rather than partially
/// populated so the panel degrades honestly.
class DataAlignmentTargetCycleProvenance {
  final String cycleId;
  final String sourceLabel;
  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;

  const DataAlignmentTargetCycleProvenance({
    required this.cycleId,
    required this.sourceLabel,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
  });
}

/// Diagnostic provenance readout for the audit panel.
///
/// Holds the nullable locked-week + target-cycle pair so the panel can
/// render either resolved provenance rows or honest "Not resolved"
/// rows without the rest of the panel going dark.
class DataAlignmentAuditProvenance {
  final DataAlignmentLockedWeekProvenance? lockedWeek;
  final DataAlignmentTargetCycleProvenance? targetCycle;

  const DataAlignmentAuditProvenance({
    required this.lockedWeek,
    required this.targetCycle,
  });

  /// True when no locked-week snapshot was resolved for the current
  /// business week. The panel should render unavailable copy in this
  /// state rather than empty rows.
  bool get lockedWeekUnavailable => lockedWeek == null;

  /// True when the locked week resolved but its linked target cycle
  /// could not be loaded (missing or deactivated row).
  bool get targetCycleUnavailable =>
      lockedWeek != null && targetCycle == null;
}
