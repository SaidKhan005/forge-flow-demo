/// Read service for Variance Full Week Projection.
///
/// Owns row provenance, day-total reconciliation, and driver-label
/// honesty. The screen should render the [VarianceWeekProjection] read
/// model returned by [build] — it should not decide source truth itself.
///
/// See phase_7_55k_4_variance_full_week_projection_semantics.md.
///
/// 7.55q.4: [build] now accepts an optional [ActiveTargetProfile] so
/// non-closed children's theoretical-% contribution to day-row
/// aggregates reads from the CURRENT shared Benchmark target object,
/// per `7.55q.1` Rule 3. Closed children's contribution stays on
/// their locked `shift.theoreticalLaborPct` (Rule 4 exception).
///
/// 7.55r item 1: [build] now also accepts an optional
/// [servicePeriodDefinitions] list so the day/daypart sort order can
/// come from the restaurant's persisted `RestaurantTimingConfig`
/// instead of the fixture-era `WeekDayOrder.daypartsFor(...)` helper.
/// Defaults to [ServicePeriodDefinitionResolver.demoDefinitions] for
/// backward compatibility with pure-data tests that don't have a
/// persisted config.
library;

import '../data/legacy_fixture_data.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../models/shift_record.dart';
import '../models/variance_week_projection_row.dart';

class VarianceWeekProjectionReadService {
  const VarianceWeekProjectionReadService();

  /// Builds the Full Week Projection read model from a merged shift list
  /// (closed + open + projected).
  ///
  /// 7.55q.4: when [currentTargetProfile] is provided, day-row aggregates
  /// substitute `currentTargetProfile.theoreticalLaborPct` for non-closed
  /// children's contribution (Rule 3). Closed children always contribute
  /// their own `shift.theoreticalLaborPct` (Rule 4 exception). When
  /// [currentTargetProfile] is null the previous per-shift behaviour is
  /// preserved (backward compatibility for pure-data tests).
  ///
  /// 7.55r item 1: [servicePeriodDefinitions] overrides the fixture-era
  /// demo definitions used for intra-day daypart sort ordering. When
  /// null (default), falls back to
  /// [ServicePeriodDefinitionResolver.demoDefinitions] so existing tests
  /// and code paths continue to work. Widget callers should load the
  /// active restaurant's timing config at build time and inject it.
  VarianceWeekProjection build(
    List<ShiftRecord> shifts, {
    ActiveTargetProfile? currentTargetProfile,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    // 7.55r item 1: prefer persisted config; fall back to demo.
    final defs = servicePeriodDefinitions ??
        ServicePeriodDefinitionResolver.demoDefinitions;

    // Build a daypart → most-recent closed lever index for carry-forward.
    // Key: daypart string. Value: last closed lever label seen so far.
    final lastClosedLever = <String, String>{};
    final dayRows = <ProjectionDayRow>[];

    for (final day in WeekDayOrder.dayLabels) {
      final order = ServicePeriodDefinitionResolver.idsForDayLabel(defs, day);
      final dayShifts = shifts.where((s) => s.dayLabel == day).toList()
        ..sort((a, b) =>
            order.indexOf(a.daypart).compareTo(order.indexOf(b.daypart)));

      if (dayShifts.isEmpty) continue;

      // Update carry-forward map from closed shifts in this day, then
      // build rows with the map available for open/projected resolution.
      for (final s in dayShifts) {
        if (s.isClosed) {
          lastClosedLever[s.daypart] =
              s.primaryLever.replaceAll('_', ' ');
        }
      }

      final children = dayShifts
          .map((s) => _buildDaypartRow(s, lastClosedLever))
          .toList();
      dayRows.add(_buildDayRow(day, children,
          currentTargetProfile: currentTargetProfile));
    }

    return VarianceWeekProjection(dayRows: dayRows);
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  ProjectionDaypartRow _buildDaypartRow(
      ShiftRecord s, Map<String, String> lastClosedLever) {
    final status = _statusFromShift(s);
    return ProjectionDaypartRow(
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      daypartLabel: s.daypartLabel,
      status: status,
      shift: s,
      driverLabel: _driverLabel(s, status, lastClosedLever),
    );
  }

  ProjectionDayRow _buildDayRow(
      String dayLabel, List<ProjectionDaypartRow> children,
      {ActiveTargetProfile? currentTargetProfile}) {
    final status = _resolveDayStatus(children);
    final summary = _statusSummary(children);

    // Day-row totals reconcile to expanded child rows.
    final totalCovers =
        children.fold<int>(0, (s, r) => s + r.shift.covers);

    final totalSales =
        children.fold<double>(0, (s, r) => s + _salesForRow(r));
    final totalLabor = children.fold<double>(
        0, (s, r) => s + _laborDollarsForRow(r, currentTargetProfile));
    final laborPct = totalSales > 0
        ? totalLabor / totalSales * 100
        : _meanTheoreticalPct(children,
            currentTargetProfile: currentTargetProfile);

    final theoPct = _weightedTheoreticalPct(children, totalSales,
        currentTargetProfile: currentTargetProfile);
    final variancePts = laborPct - theoPct;

    return ProjectionDayRow(
      dayLabel: dayLabel,
      children: children,
      status: status,
      statusSummary: summary,
      totalCovers: totalCovers,
      laborPct: laborPct,
      theoreticalLaborPct: theoPct,
      variancePts: variancePts,
    );
  }

  static RowStatus _statusFromShift(ShiftRecord s) {
    if (s.isClosed) return RowStatus.closed;
    if (s.isOpen) return RowStatus.open;
    return RowStatus.projected;
  }

  static String _driverLabel(
      ShiftRecord s, RowStatus status, Map<String, String> lastClosedLever) {
    if (status == RowStatus.closed) {
      return s.primaryLever.replaceAll('_', ' ');
    }
    // Carry forward the most recent closed lever from the same daypart.
    final carried = lastClosedLever[s.daypart];
    if (carried != null) return carried;
    return 'Not yet available';
  }

  static RowStatus _resolveDayStatus(List<ProjectionDaypartRow> children) {
    if (children.isEmpty) return RowStatus.projected;
    final first = children.first.status;
    if (children.every((c) => c.status == first)) return first;
    return RowStatus.mixed;
  }

  static String _statusSummary(List<ProjectionDaypartRow> children) {
    final counts = <RowStatus, int>{};
    for (final c in children) {
      counts[c.status] = (counts[c.status] ?? 0) + 1;
    }
    if (counts.length <= 1) return '';

    final parts = <String>[];
    for (final status in [RowStatus.closed, RowStatus.open, RowStatus.projected]) {
      final n = counts[status];
      if (n != null && n > 0) {
        final label = status.name[0].toUpperCase() + status.name.substring(1);
        parts.add('$n $label');
      }
    }
    return parts.join(', ');
  }

  /// 7.55q.4: per-row theoretical % source.
  /// - Closed rows: locked `shift.theoreticalLaborPct` (Rule 4).
  /// - Non-closed rows: `currentTargetProfile.theoreticalLaborPct`
  ///   when provided (Rule 3). Falls back to `shift.theoreticalLaborPct`
  ///   when no current profile is passed (backward-compatible).
  static double _theoreticalPctForRow(
      ProjectionDaypartRow row, ActiveTargetProfile? currentTargetProfile) {
    if (row.status == RowStatus.closed || currentTargetProfile == null) {
      return row.shift.theoreticalLaborPct;
    }
    return currentTargetProfile.theoreticalLaborPct;
  }

  static double _weightedTheoreticalPct(
      List<ProjectionDaypartRow> children, double totalSales,
      {ActiveTargetProfile? currentTargetProfile}) {
    if (totalSales > 0) {
      final weighted = children.fold<double>(
          0,
          (s, r) =>
              s +
              _theoreticalPctForRow(r, currentTargetProfile) *
                  _salesForRow(r));
      return weighted / totalSales;
    }
    return _meanTheoreticalPct(children,
        currentTargetProfile: currentTargetProfile);
  }

  static double _meanTheoreticalPct(List<ProjectionDaypartRow> children,
      {ActiveTargetProfile? currentTargetProfile}) {
    if (children.isEmpty) return 0.0;
    return children.fold<double>(
            0,
            (s, r) =>
                s + _theoreticalPctForRow(r, currentTargetProfile)) /
        children.length;
  }

  /// Sales basis for collapsed Full Week projection math.
  ///
  /// Closed rows stay on actual closed-shift sales. Non-closed rows may
  /// carry a Plan-owned forecast sales target from the locked weekly plan
  /// daypart allocation; when present, use that target sales basis for
  /// projection weighting without rewriting the row's actual/current sales.
  static double _salesForRow(ProjectionDaypartRow row) {
    if (row.status != RowStatus.closed) {
      final planSales = row.shift.planForecastSales;
      if (planSales != null) return planSales;
    }
    return row.shift.actualSales;
  }

  /// 7.55q follow-up: open/projected rows built from [OpenShiftSnapshot]
  /// carry `snapshotBlendedWage`, not stored source labor dollars. When
  /// that snapshot wage is present and positive, use it for the collapsed
  /// day-row labor aggregate so the collapsed path stays consistent with
  /// the expanded projected detail. Closed rows continue to use persisted
  /// actual labor dollars.
  ///
  /// 7.56c.0: a `snapshotBlendedWage` of `0.00` is treated as absent
  /// rather than authoritative. Without this, a seeded zero wage can
  /// render `0.0%` collapsed labor even though the expanded detail and
  /// the rest of the app price labor at the active Benchmark blended
  /// wage. When [currentTargetProfile] is provided, fall back to
  /// `currentTargetProfile.targetBlendedWage`. When no profile is
  /// available, fall back to the shift's own labor dollars (legacy
  /// behaviour).
  static double _laborDollarsForRow(
      ProjectionDaypartRow row, ActiveTargetProfile? currentTargetProfile) {
    final shift = row.shift;
    final totalHours = shift.fohHours + shift.bohHours;
    if (row.status != RowStatus.closed && totalHours > 0) {
      final snapshotWage = shift.snapshotBlendedWage;
      if (snapshotWage != null && snapshotWage > 0) {
        return snapshotWage * totalHours;
      }
      if (currentTargetProfile != null) {
        return currentTargetProfile.targetBlendedWage * totalHours;
      }
    }
    return shift.totalLaborDollar;
  }
}
