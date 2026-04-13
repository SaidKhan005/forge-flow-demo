/// Read service for Variance Full Week Projection.
///
/// Owns row provenance, day-total reconciliation, and driver-label
/// honesty. The screen should render the [VarianceWeekProjection] read
/// model returned by [build] — it should not decide source truth itself.
///
/// See phase_7_55k_4_variance_full_week_projection_semantics.md.
library;

import '../data/legacy_fixture_data.dart';
import '../models/shift_record.dart';
import '../models/variance_week_projection_row.dart';

class VarianceWeekProjectionReadService {
  const VarianceWeekProjectionReadService();

  /// Builds the Full Week Projection read model from a merged shift list
  /// (closed + open + projected).
  VarianceWeekProjection build(List<ShiftRecord> shifts) {
    final dayRows = <ProjectionDayRow>[];

    for (final day in WeekDayOrder.dayLabels) {
      final order = WeekDayOrder.daypartsFor(day);
      final dayShifts = shifts.where((s) => s.dayLabel == day).toList()
        ..sort((a, b) =>
            order.indexOf(a.daypart).compareTo(order.indexOf(b.daypart)));

      if (dayShifts.isEmpty) continue;

      final children = dayShifts.map((s) => _buildDaypartRow(s)).toList();
      dayRows.add(_buildDayRow(day, children));
    }

    return VarianceWeekProjection(dayRows: dayRows);
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  ProjectionDaypartRow _buildDaypartRow(ShiftRecord s) {
    final status = _statusFromShift(s);
    return ProjectionDaypartRow(
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      daypartLabel: s.daypartLabel,
      status: status,
      shift: s,
      driverLabel: _driverLabel(s, status),
    );
  }

  ProjectionDayRow _buildDayRow(
      String dayLabel, List<ProjectionDaypartRow> children) {
    final status = _resolveDayStatus(children);
    final summary = _statusSummary(children);

    // Day-row totals reconcile to expanded child rows.
    final totalCovers =
        children.fold<int>(0, (s, r) => s + r.shift.covers);

    final totalSales =
        children.fold<double>(0, (s, r) => s + r.shift.actualSales);
    final totalLabor =
        children.fold<double>(0, (s, r) => s + r.shift.totalLaborDollar);
    final laborPct = totalSales > 0 ? totalLabor / totalSales * 100 : _meanTheoreticalPct(children);

    final theoPct = _weightedTheoreticalPct(children, totalSales);
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

  static String _driverLabel(ShiftRecord s, RowStatus status) {
    if (status == RowStatus.closed) {
      return s.primaryLever.replaceAll('_', ' ');
    }
    // Open and projected rows: ON_MODEL is a placeholder, not truth.
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
        parts.add('$n ${status.name}');
      }
    }
    return parts.join(', ');
  }

  static double _weightedTheoreticalPct(
      List<ProjectionDaypartRow> children, double totalSales) {
    if (totalSales > 0) {
      final weighted = children.fold<double>(
          0, (s, r) => s + r.shift.theoreticalLaborPct * r.shift.actualSales);
      return weighted / totalSales;
    }
    return _meanTheoreticalPct(children);
  }

  static double _meanTheoreticalPct(List<ProjectionDaypartRow> children) {
    if (children.isEmpty) return 0.0;
    return children.fold<double>(
            0, (s, r) => s + r.shift.theoreticalLaborPct) /
        children.length;
  }
}
