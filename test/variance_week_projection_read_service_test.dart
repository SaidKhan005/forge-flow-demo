// Phase 7.55k.4 — Variance Week Projection Read Service Tests
//
// Verifies:
// A. Row status semantics: closed, open, projected are distinguishable
// B. Day-row totals reconcile to child rows
// C. Projected-row copy no longer claims 60-day baseline authority
// D. Open/projected rows do not overclaim row-scope driver truth
// E. Mixed-status day rows carry honest status summary
// F. businessDate propagation from shiftRecordFromSnapshot

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/models/current_week_state.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/variance_week_projection_row.dart';
import 'package:forge_and_flow/services/variance_week_projection_read_service.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

ShiftRecord _closedShift({
  String dayLabel = 'Mon',
  String daypart = 'lunch',
  int covers = 120,
  int forecastCovers = 130,
  double ppa = 42.0,
  double cplh = 4.5,
  double splh = 180.0,
  int fohHours = 28,
  int bohHours = 29,
  String primaryLever = 'COVERS_DOWN',
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'closed',
      covers: covers,
      forecastCovers: forecastCovers,
      ppa: ppa,
      cplh: cplh,
      splh: splh,
      fohHours: fohHours,
      bohHours: bohHours,
      primaryLever: primaryLever,
      businessDate: '2026-03-24',
      targetCPLH: 4.58,
      targetSPLH: 180.0,
      targetPPA: 41.50,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
    );

ShiftRecord _openShift({
  String dayLabel = 'Fri',
  String daypart = 'dinner',
  int covers = 63,
  int forecastCovers = 100,
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'open',
      covers: covers,
      forecastCovers: forecastCovers,
      ppa: 43.50,
      cplh: 2.86,
      splh: 130.0,
      fohHours: 22,
      bohHours: 9,
      primaryLever: 'ON_MODEL',
      businessDate: '2026-03-28',
      targetCPLH: 4.58,
      targetSPLH: 180.0,
      targetPPA: 41.50,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
    );

ShiftRecord _projectedShift({
  String dayLabel = 'Sat',
  String daypart = 'dinner',
  int forecastCovers = 110,
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'projected',
      covers: forecastCovers,
      forecastCovers: forecastCovers,
      ppa: 0,
      cplh: 0,
      splh: 0,
      fohHours: 24,
      bohHours: 10,
      primaryLever: 'ON_MODEL',
      businessDate: '2026-03-29',
      targetCPLH: 4.58,
      targetSPLH: 180.0,
      targetPPA: 41.50,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
    );

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  const service = VarianceWeekProjectionReadService();

  // ── A: Row status semantics ─────────────────────────────────────────────

  group('A — row status semantics', () {
    test('closed shift produces RowStatus.closed', () {
      final projection = service.build([_closedShift()]);
      expect(projection.dayRows.length, 1);
      final dayRow = projection.dayRows.first;
      expect(dayRow.status, RowStatus.closed);
      expect(dayRow.children.first.status, RowStatus.closed);
    });

    test('open shift produces RowStatus.open', () {
      final projection = service.build([_openShift()]);
      final dayRow = projection.dayRows.first;
      expect(dayRow.status, RowStatus.open);
      expect(dayRow.children.first.status, RowStatus.open);
    });

    test('projected shift produces RowStatus.projected', () {
      final projection = service.build([_projectedShift()]);
      final dayRow = projection.dayRows.first;
      expect(dayRow.status, RowStatus.projected);
      expect(dayRow.children.first.status, RowStatus.projected);
    });

    test('all three statuses are distinguishable', () {
      final projection = service.build([
        _closedShift(dayLabel: 'Mon', daypart: 'lunch'),
        _openShift(dayLabel: 'Fri', daypart: 'dinner'),
        _projectedShift(dayLabel: 'Sat', daypart: 'dinner'),
      ]);
      final statuses =
          projection.dayRows.map((d) => d.status).toSet();
      expect(statuses, containsAll([RowStatus.closed, RowStatus.open, RowStatus.projected]));
    });
  });

  // ── B: Day-row totals reconcile to child rows ───────────────────────────

  group('B — day-row total reconciliation', () {
    test('day covers equal sum of child covers', () {
      final lunch = _closedShift(dayLabel: 'Mon', daypart: 'lunch', covers: 60);
      final dinner = _closedShift(dayLabel: 'Mon', daypart: 'dinner', covers: 80);
      final projection = service.build([lunch, dinner]);
      final day = projection.dayRows.first;
      expect(day.totalCovers, 60 + 80);
    });

    test('mixed-status day covers reconcile', () {
      final closed = _closedShift(dayLabel: 'Fri', daypart: 'lunch', covers: 70);
      final open = _openShift(dayLabel: 'Fri', daypart: 'dinner');
      final projection = service.build([closed, open]);
      final day = projection.dayRows.first;
      expect(day.totalCovers, 70 + open.covers);
    });

    test('day variance pts = laborPct - theoreticalLaborPct', () {
      final shift = _closedShift(dayLabel: 'Mon', daypart: 'lunch');
      final projection = service.build([shift]);
      final day = projection.dayRows.first;
      expect(day.variancePts, closeTo(day.laborPct - day.theoreticalLaborPct, 0.01));
    });
  });

  // ── C: Projected-row copy honesty ───────────────────────────────────────

  group('C — projected-row copy', () {
    test('projected row driverLabel is Not yet available, not ON_MODEL', () {
      final projection = service.build([_projectedShift()]);
      final child = projection.dayRows.first.children.first;
      expect(child.driverLabel, 'Not yet available');
      expect(child.driverLabel, isNot(contains('ON_MODEL')));
    });

    test('open row driverLabel is Not yet available', () {
      final projection = service.build([_openShift()]);
      final child = projection.dayRows.first.children.first;
      expect(child.driverLabel, 'Not yet available');
    });

    test('closed row driverLabel is the actual detected lever', () {
      final projection = service.build([
        _closedShift(primaryLever: 'CPLH_DOWN'),
      ]);
      final child = projection.dayRows.first.children.first;
      expect(child.driverLabel, 'CPLH DOWN');
    });
  });

  // ── D: Open/projected rows do not overclaim driver truth ─────────────

  group('D — no driver overclaim', () {
    test('ON_MODEL shifts get honest driver label', () {
      final shifts = [
        _openShift(),
        _projectedShift(),
      ];
      final projection = service.build(shifts);
      for (final day in projection.dayRows) {
        for (final child in day.children) {
          if (child.status != RowStatus.closed) {
            expect(child.driverLabel, 'Not yet available');
          }
        }
      }
    });
  });

  // ── E: Mixed-status day rows ────────────────────────────────────────────

  group('E — mixed-status day rows', () {
    test('mixed day has RowStatus.mixed', () {
      final closed = _closedShift(dayLabel: 'Fri', daypart: 'lunch');
      final open = _openShift(dayLabel: 'Fri', daypart: 'dinner');
      final projection = service.build([closed, open]);
      final day = projection.dayRows.first;
      expect(day.status, RowStatus.mixed);
    });

    test('mixed day carries compact status summary', () {
      final closed = _closedShift(dayLabel: 'Fri', daypart: 'lunch');
      final open = _openShift(dayLabel: 'Fri', daypart: 'dinner');
      final projection = service.build([closed, open]);
      final day = projection.dayRows.first;
      expect(day.statusSummary, contains('closed'));
      expect(day.statusSummary, contains('open'));
    });

    test('uniform-status day has empty statusSummary', () {
      final projection = service.build([
        _closedShift(dayLabel: 'Mon', daypart: 'lunch'),
        _closedShift(dayLabel: 'Mon', daypart: 'dinner'),
      ]);
      final day = projection.dayRows.first;
      expect(day.status, RowStatus.closed);
      expect(day.statusSummary, isEmpty);
    });

    test('allClosed and allProjected flags', () {
      final closedOnly = service.build([
        _closedShift(dayLabel: 'Mon', daypart: 'lunch'),
        _closedShift(dayLabel: 'Mon', daypart: 'dinner'),
      ]);
      expect(closedOnly.dayRows.first.allClosed, isTrue);
      expect(closedOnly.dayRows.first.allProjected, isFalse);

      final projOnly = service.build([
        _projectedShift(dayLabel: 'Sat', daypart: 'dinner'),
        _projectedShift(dayLabel: 'Sat', daypart: 'late_night'),
      ]);
      expect(projOnly.dayRows.first.allProjected, isTrue);
      expect(projOnly.dayRows.first.allClosed, isFalse);
    });
  });

  // ── F: businessDate propagation ─────────────────────────────────────────

  group('F — businessDate propagation', () {
    test('shiftRecordFromSnapshot propagates businessDate', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: 4.58,
        targetSPLH: 180.0,
        targetPPA: 41.50,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.50,
        opzCeilingCPLH: 5.80,
        theoreticalFohLaborPct: 8.63,
        theoreticalBohLaborPct: 11.86,
        theoreticalLaborPct: 20.48,
        builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Sat',
        daypart: 'dinner',
        status: 'projected',
        businessDate: '2026-03-28',
        forecastCovers: 110,
        currentCovers: 0,
        scheduledFohHours: 24,
        scheduledBohHours: 10,
        currentPPA: 0,
        currentCPLH: 0,
        currentSPLH: 0,
        blendedWage: 18.0,
        updatedAt: '2026-03-27T19:42:00',
      );

      final record =
          CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);
      expect(record.businessDate, '2026-03-28');
    });

    test('shiftRecordFromSnapshot for open row also propagates businessDate', () {
      final profile = ActiveTargetProfile(
        targetProfileId: 'test_active',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: 4.58,
        targetSPLH: 180.0,
        targetPPA: 41.50,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.50,
        opzCeilingCPLH: 5.80,
        theoreticalFohLaborPct: 8.63,
        theoreticalBohLaborPct: 11.86,
        theoreticalLaborPct: 20.48,
        builtAt: '2026-03-27T19:42:00',
      );
      final snapshot = OpenShiftSnapshot(
        restaurantId: 'demo_restaurant_001',
        weekId: '2026-W13',
        dayLabel: 'Fri',
        daypart: 'dinner',
        status: 'open',
        businessDate: '2026-03-27',
        forecastCovers: 100,
        currentCovers: 63,
        scheduledFohHours: 22,
        scheduledBohHours: 9,
        currentPPA: 43.50,
        currentCPLH: 2.86,
        currentSPLH: 130.0,
        blendedWage: 18.0,
        updatedAt: '2026-03-27T19:42:00',
      );

      final record =
          CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);
      expect(record.businessDate, '2026-03-27');
    });
  });

  // ── G: Day ordering follows canonical Mon-Sun ───────────────────────────

  group('G — day ordering', () {
    test('days appear in Mon-Sun canonical order', () {
      final shifts = [
        _projectedShift(dayLabel: 'Sun', daypart: 'dinner'),
        _closedShift(dayLabel: 'Mon', daypart: 'lunch'),
        _closedShift(dayLabel: 'Wed', daypart: 'lunch'),
      ];
      final projection = service.build(shifts);
      final labels = projection.dayRows.map((d) => d.dayLabel).toList();
      expect(labels, ['Mon', 'Wed', 'Sun']);
    });
  });

  // ── H: Daypart ordering within a day ────────────────────────────────────

  group('H — daypart ordering within a day', () {
    test('children are ordered lunch, dinner, late_night', () {
      final shifts = [
        _closedShift(dayLabel: 'Fri', daypart: 'late_night'),
        _closedShift(dayLabel: 'Fri', daypart: 'lunch'),
        _closedShift(dayLabel: 'Fri', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final dayparts =
          projection.dayRows.first.children.map((c) => c.daypart).toList();
      expect(dayparts, ['lunch', 'dinner', 'late_night']);
    });
  });
}
