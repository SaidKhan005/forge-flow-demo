/// Immutable snapshot of the full cross-surface diagnostic view consumed
/// by [DataAlignmentAuditPanel].
///
/// Assembled by [DataAlignmentAuditReadService] so the widget does not
/// need to touch repositories or services directly.
///
/// Phase 7.55r item 4, Tier 1 (boundary hygiene).
library;

import '../domain/models/active_target_profile.dart';
import '../domain/models/demand_forecast_context.dart';
import '../domain/models/schedule_plan.dart';
import '../domain/models/wage_standard_context.dart';
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

  const DataAlignmentAuditSnapshot({
    required this.profile,
    required this.demandContext,
    required this.plan,
    required this.shiftReadModel,
    required this.weekData,
    required this.wageContext,
    required this.driftChecks,
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
}
