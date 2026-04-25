/// Immutable snapshot of the full cross-surface diagnostic view consumed
/// by [DataAlignmentAuditPanel].
///
/// Assembled by [DataAlignmentAuditReadService] so the widget does not
/// need to touch repositories or services directly.
///
/// Phase 7.55r item 4, Tier 1 (boundary hygiene).
/// Phase 7.56c.1: extended with [auditChecks] / [auditGroups] so the
/// panel can render Plan + Benchmark coverage and live / actual
/// provenance grouped sections alongside the existing 9 q-lane drift
/// checks.
library;

import '../domain/models/active_target_profile.dart';
import '../domain/models/demand_forecast_context.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/wage_standard_context.dart';
import 'data_alignment_audit_check.dart';
import 'data_alignment_audit_provenance.dart';
import 'data_alignment_drift_check.dart';
import 'shift_dashboard_read_model.dart';
import 'week_data.dart';

class DataAlignmentAuditSnapshot {
  /// Raw persisted [ActiveTargetProfile] for the active restaurant.
  /// Null when no profile is persisted.
  final ActiveTargetProfile? profile;

  /// Current resolved demand-forecast context.
  final DemandForecastContext? demandContext;

  /// Existing locked weekly plan for the in-force week. Null when the
  /// current-week snapshot is not persisted (honest "Not resolved" view).
  final SchedulePlan? plan;

  /// Shift dashboard read model, if an open shift exists.
  final ShiftDashboardReadModel? shiftReadModel;

  /// Variance WTD week data, read only when [plan] is non-null (matches
  /// the panel's "strict authority" rule — no live fallback).
  final WeekData? weekData;

  /// Resolved wage-standard context.
  final WageStandardContext? wageContext;

  /// Cross-section drift checks comparing conceptually-equal metrics
  /// across authority surfaces. Ordered for stable display.
  final List<DataAlignmentDriftCheck> driftChecks;

  /// Locked-week + target-cycle provenance describing which snapshot /
  /// cycle produced the plan values rendered in this panel.
  /// Phase 7.55r item 4, Tier 3.
  final DataAlignmentAuditProvenance provenance;

  /// Phase 7.56c.1: grouped audit checks covering live / actual
  /// provenance plus full Plan + Benchmark target authority alignment.
  ///
  /// The original 9 q-lane numeric drift checks remain in [driftChecks]
  /// — the audit panel renders both lists side by side so the existing
  /// q-lane regressions stay visible while the new full-coverage audit
  /// is exposed in grouped sections.
  final List<DataAlignmentAuditCheck> auditChecks;

  const DataAlignmentAuditSnapshot({
    required this.profile,
    required this.demandContext,
    required this.plan,
    required this.shiftReadModel,
    required this.weekData,
    required this.wageContext,
    required this.driftChecks,
    required this.provenance,
    this.auditChecks = const [],
  });

  /// True when any drift check is in the `drifted` state.
  bool get hasAnyDrift =>
      driftChecks.any((c) => c.status == DriftCheckStatus.drifted);

  /// Count of drifted checks.
  int get driftedCount =>
      driftChecks.where((c) => c.status == DriftCheckStatus.drifted).length;

  /// Count of aligned checks.
  int get alignedCount =>
      driftChecks.where((c) => c.status == DriftCheckStatus.aligned).length;

  // ── 7.56c.1 audit-check counters ──────────────────────────────────────────

  /// Count of audit checks (across all groups) in the aligned state.
  int get auditAlignedCount =>
      auditChecks.where((c) => c.status == DriftCheckStatus.aligned).length;

  /// Count of audit checks (across all groups) in the drifted state.
  int get auditDriftedCount =>
      auditChecks.where((c) => c.status == DriftCheckStatus.drifted).length;

  /// Count of audit checks (across all groups) in the unavailable state.
  int get auditUnavailableCount => auditChecks
      .where((c) => c.status == DriftCheckStatus.unavailable)
      .length;

  /// True when any audit check is in the drifted state.
  bool get hasAnyAuditDrift =>
      auditChecks.any((c) => c.status == DriftCheckStatus.drifted);

  /// Per-group aligned / drifted / unavailable totals, ordered by the
  /// canonical [DataAlignmentAuditGroup] enum order. Groups with no
  /// checks are omitted so the panel does not render empty sections.
  List<DataAlignmentAuditGroupSummary> get auditGroups {
    final byGroup = <DataAlignmentAuditGroup, List<DataAlignmentAuditCheck>>{};
    for (final c in auditChecks) {
      byGroup.putIfAbsent(c.groupId, () => []).add(c);
    }
    return DataAlignmentAuditGroup.values
        .where(byGroup.containsKey)
        .map((g) {
      final cs = byGroup[g]!;
      var aligned = 0, drifted = 0, unavailable = 0;
      for (final c in cs) {
        switch (c.status) {
          case DriftCheckStatus.aligned:
            aligned++;
            break;
          case DriftCheckStatus.drifted:
            drifted++;
            break;
          case DriftCheckStatus.unavailable:
            unavailable++;
            break;
        }
      }
      return DataAlignmentAuditGroupSummary(
        groupId: g,
        alignedCount: aligned,
        driftedCount: drifted,
        unavailableCount: unavailable,
      );
    }).toList();
  }

  /// Returns the audit checks belonging to [group], in insertion order.
  List<DataAlignmentAuditCheck> auditChecksFor(
          DataAlignmentAuditGroup group) =>
      auditChecks.where((c) => c.groupId == group).toList();
}
