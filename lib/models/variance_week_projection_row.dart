/// Read model for Variance Full Week Projection rows.
///
/// Each row carries explicit provenance so the UI cannot silently
/// overstate finality. Day rows describe the mix of their children.
/// See phase_7_55k_4_variance_full_week_projection_semantics.md.
library;

import 'shift_record.dart';

/// Row-level status in the Full Week projection.
enum RowStatus {
  /// Locked closed truth — finalized shift facts.
  closed,

  /// Live in-progress snapshot — not final truth.
  open,

  /// Planned / forecast placeholder — not actual performance.
  projected,

  /// Day aggregate containing children with different statuses.
  mixed,
}

// ---------------------------------------------------------------------------
// Daypart (child) row
// ---------------------------------------------------------------------------

/// One daypart row inside a day group.
class ProjectionDaypartRow {
  final String dayLabel;
  final String daypart;
  final String daypartLabel;
  final RowStatus status;

  /// The underlying shift record for metric access.
  final ShiftRecord shift;

  /// Product-facing driver label.
  /// Closed rows use the detected lever; open/projected rows show
  /// "Not yet available" instead of the ON_MODEL placeholder.
  final String driverLabel;

  const ProjectionDaypartRow({
    required this.dayLabel,
    required this.daypart,
    required this.daypartLabel,
    required this.status,
    required this.shift,
    required this.driverLabel,
  });
}

// ---------------------------------------------------------------------------
// Day (parent) row
// ---------------------------------------------------------------------------

/// Aggregated day row for the Full Week projection.
class ProjectionDayRow {
  final String dayLabel;
  final List<ProjectionDaypartRow> children;

  /// Resolved status: [RowStatus.mixed] when children have different statuses.
  final RowStatus status;

  /// Short human-readable summary when [status] is mixed.
  /// e.g. "1 closed, 1 open" or "2 closed, 1 projected".
  /// Empty string for uniform-status days.
  final String statusSummary;

  // ── Aggregate metrics (reconcile to children) ──────────────────────────

  final int totalCovers;
  final double laborPct;
  final double theoreticalLaborPct;
  final double variancePts;

  const ProjectionDayRow({
    required this.dayLabel,
    required this.children,
    required this.status,
    required this.statusSummary,
    required this.totalCovers,
    required this.laborPct,
    required this.theoreticalLaborPct,
    required this.variancePts,
  });

  bool get allClosed => status == RowStatus.closed;
  bool get allProjected => status == RowStatus.projected;
  bool get hasOpen =>
      children.any((c) => c.status == RowStatus.open);
}

// ---------------------------------------------------------------------------
// Full projection result
// ---------------------------------------------------------------------------

/// The complete Full Week Projection read model.
class VarianceWeekProjection {
  final List<ProjectionDayRow> dayRows;

  const VarianceWeekProjection({required this.dayRows});
}
