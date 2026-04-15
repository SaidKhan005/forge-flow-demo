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
  double ppa = 43.50,
  int fohHours = 22,
  int bohHours = 9,
  double? snapshotBlendedWage,
}) =>
    ShiftRecord(
      weekId: '2026-W13',
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'open',
      covers: covers,
      forecastCovers: forecastCovers,
      ppa: ppa,
      cplh: 2.86,
      splh: 130.0,
      fohHours: fohHours,
      bohHours: bohHours,
      primaryLever: 'ON_MODEL',
      businessDate: '2026-03-28',
      targetCPLH: 4.58,
      targetSPLH: 180.0,
      targetPPA: 41.50,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.63,
      theoreticalBohLaborPct: 11.86,
      snapshotBlendedWage: snapshotBlendedWage,
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
      expect(day.statusSummary, contains('Closed'));
      expect(day.statusSummary, contains('Open'));
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

  // ── I: Driver carry-forward for open/projected rows ────────────────────

  group('I — driver carry-forward', () {
    test('projected row carries forward closed lever from same daypart', () {
      final shifts = [
        _closedShift(dayLabel: 'Mon', daypart: 'dinner', primaryLever: 'CPLH_DOWN'),
        _projectedShift(dayLabel: 'Tue', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final tue = projection.dayRows.firstWhere((d) => d.dayLabel == 'Tue');
      expect(tue.children.first.driverLabel, 'CPLH DOWN');
    });

    test('open row carries forward closed lever from same daypart', () {
      final shifts = [
        _closedShift(dayLabel: 'Mon', daypart: 'dinner', primaryLever: 'SPLH_DOWN'),
        _openShift(dayLabel: 'Fri', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final fri = projection.dayRows.firstWhere((d) => d.dayLabel == 'Fri');
      expect(fri.children.first.driverLabel, 'SPLH DOWN');
    });

    test('no carry-forward across different dayparts', () {
      final shifts = [
        _closedShift(dayLabel: 'Mon', daypart: 'lunch', primaryLever: 'PPA_DOWN'),
        _projectedShift(dayLabel: 'Tue', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final tue = projection.dayRows.firstWhere((d) => d.dayLabel == 'Tue');
      expect(tue.children.first.driverLabel, 'Not yet available');
    });

    test('most recent closed lever wins carry-forward', () {
      final shifts = [
        _closedShift(dayLabel: 'Mon', daypart: 'dinner', primaryLever: 'CPLH_DOWN'),
        _closedShift(dayLabel: 'Tue', daypart: 'dinner', primaryLever: 'PPA_DOWN'),
        _projectedShift(dayLabel: 'Wed', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final wed = projection.dayRows.firstWhere((d) => d.dayLabel == 'Wed');
      expect(wed.children.first.driverLabel, 'PPA DOWN');
    });

    test('no prior closed shift means Not yet available', () {
      final shifts = [
        _projectedShift(dayLabel: 'Mon', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      expect(projection.dayRows.first.children.first.driverLabel,
          'Not yet available');
    });
  });

  // ── J: Status summary capitalization ───────────────────────────────────

  group('J — status summary capitalization', () {
    test('status summary uses capitalized labels', () {
      final shifts = [
        _closedShift(dayLabel: 'Fri', daypart: 'lunch'),
        _openShift(dayLabel: 'Fri', daypart: 'dinner'),
      ];
      final projection = service.build(shifts);
      final day = projection.dayRows.first;
      expect(day.statusSummary, '1 Closed, 1 Open');
    });
  });

  // ── K: Snapshot blended wage preservation (7.55p.2a) ──────────────────

  group('K — snapshot blended wage preservation', () {
    test('shiftRecordFromSnapshot preserves snapshot blendedWage', () {
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
      expect(record.snapshotBlendedWage, 18.0);
    });

    test('open snapshot preserves blendedWage through shiftRecordFromSnapshot', () {
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
        blendedWage: 18.50,
        updatedAt: '2026-03-27T19:42:00',
      );

      final record =
          CurrentWeekState.shiftRecordFromSnapshot(snapshot, profile);
      expect(record.snapshotBlendedWage, 18.50);
      // Scheduled hours are preserved as plan context
      expect(record.fohHours, 22);
      expect(record.bohHours, 9);
      expect(record.forecastCovers, 100);
    });

    test('closed shift has null snapshotBlendedWage', () {
      final shift = _closedShift();
      expect(shift.snapshotBlendedWage, isNull);
    });
  });

  // ── L: 7.55q.4 — currentTargetProfile rewires non-closed theoretical %
  //
  // Drift 5 fix from 7.55q.1: non-closed Variance Full Week rows must
  // read Benchmark-owned target metrics from the current shared
  // ActiveTargetProfile (Rule 3). Closed rows continue to use their
  // locked shift.theoreticalLaborPct (Rule 4 exception).
  //
  //   L1. Closed children continue to use shift.theoreticalLaborPct
  //       even when a current profile is passed (Rule 4 preserved).
  //   L2. Non-closed children use currentTargetProfile.theoreticalLaborPct
  //       when passed (Rule 3 enforced).
  //   L3. Mixed-status days produce a sales-weighted blend of locked
  //       (closed) + current-Benchmark (non-closed) contributions.
  //   L4. Omitting currentTargetProfile preserves the legacy per-shift
  //       behaviour (backward compatibility for pure-data tests).

  group('L — 7.55q.4 currentTargetProfile rewires non-closed '
      'theoretical %', () {
    ActiveTargetProfile makeProfile({double theoreticalLaborPct = 18.0}) {
      return ActiveTargetProfile(
        targetProfileId: 'q4-test',
        restaurantId: 'demo_restaurant_001',
        sourceType: 'system_baseline',
        targetCPLH: 4.58,
        targetSPLH: 180.0,
        targetPPA: 41.50,
        fohWage: 16.50,
        bohWage: 21.35,
        opzFloorCPLH: 3.50,
        opzCeilingCPLH: 5.80,
        theoreticalFohLaborPct: 8.0,
        theoreticalBohLaborPct: 10.0,
        theoreticalLaborPct: theoreticalLaborPct,
        builtAt: '2026-04-14T00:00:00Z',
      );
    }

    test('L1: closed children use locked shift.theoreticalLaborPct '
        'even when a current profile is passed (Rule 4 preserved)', () {
      final shift = _closedShift(dayLabel: 'Mon', daypart: 'lunch');
      // Locked closed shifts have theoreticalLaborPct =
      // MeridianConfig.totalTheoreticalLaborPct (default; ≈ 20.48).
      final lockedTheoPct = shift.theoreticalLaborPct;

      final profile = makeProfile(theoreticalLaborPct: 30.0);
      final projection =
          service.build([shift], currentTargetProfile: profile);
      final day = projection.dayRows.first;

      // Day-row aggregate equals the closed locked value, NOT the
      // current profile's value — Rule 4 closed-truth exception.
      expect(day.theoreticalLaborPct, closeTo(lockedTheoPct, 0.001));
      expect(day.theoreticalLaborPct, isNot(closeTo(30.0, 0.001)));
    });

    test('L2: non-closed (open/projected) children use '
        'currentTargetProfile.theoreticalLaborPct when passed '
        '(Rule 3 enforced)', () {
      final open = _openShift(dayLabel: 'Fri', daypart: 'dinner');
      // Open shifts default to theoreticalLaborPct =
      // MeridianConfig.totalTheoreticalLaborPct (≈ 20.48).
      // We pass a profile with a clearly different theoretical %.
      final profile = makeProfile(theoreticalLaborPct: 25.5);

      final projection =
          service.build([open], currentTargetProfile: profile);
      final day = projection.dayRows.first;

      // Day-row aggregate must equal the CURRENT profile's value,
      // NOT the open shift's locked-at-write value.
      expect(day.theoreticalLaborPct, closeTo(25.5, 0.001));
      expect(day.theoreticalLaborPct,
          isNot(closeTo(open.theoreticalLaborPct, 0.001)));
    });

    test('L3: mixed-status days produce a sales-weighted blend of '
        'closed-locked + non-closed-current contributions', () {
      // Closed shift: 100 covers × $42 = $4200 sales, locked theo ≈ 20.48
      final closed = _closedShift(
          dayLabel: 'Fri',
          daypart: 'lunch',
          covers: 100,
          ppa: 42.0);
      // Open shift: 100 covers × $43.50 = $4350 sales, profile theo = 30.0
      final open = _openShift(
          dayLabel: 'Fri',
          daypart: 'dinner',
          covers: 100,
          forecastCovers: 100);
      // _openShift uses ppa: 43.50 by default; sales = 100 × 43.50 = $4350.

      final closedTheo = closed.theoreticalLaborPct; // ≈ 20.48
      const profileTheo = 30.0;
      final profile = makeProfile(theoreticalLaborPct: profileTheo);

      final projection = service.build(
        [closed, open],
        currentTargetProfile: profile,
      );
      final day = projection.dayRows.first;

      // Expected aggregate = (closedTheo × closedSales +
      //                       profileTheo × openSales) / totalSales
      final closedSales = 100 * 42.0;
      final openSales = 100 * 43.50;
      final totalSales = closedSales + openSales;
      final expected =
          (closedTheo * closedSales + profileTheo * openSales) / totalSales;

      expect(day.theoreticalLaborPct, closeTo(expected, 0.001));
      // Sanity: the blend must lie strictly between the two values
      // (since both contribute meaningfully and they differ).
      expect(day.theoreticalLaborPct,
          greaterThan([closedTheo, profileTheo].reduce((a, b) => a < b ? a : b)));
      expect(day.theoreticalLaborPct,
          lessThan([closedTheo, profileTheo].reduce((a, b) => a > b ? a : b)));
    });

    test('L4: omitting currentTargetProfile preserves the legacy '
        'per-shift behaviour (backward compat)', () {
      final open = _openShift(dayLabel: 'Fri', daypart: 'dinner');
      final projection = service.build([open]); // no profile passed
      final day = projection.dayRows.first;
      expect(day.theoreticalLaborPct,
          closeTo(open.theoreticalLaborPct, 0.001));
    });
  });

  group('M â€” non-closed day-row labor uses snapshot blended wage when present',
      () {
    test('collapsed day-row labor % uses snapshotBlendedWage dollars for '
        'open/projected rows', () {
      final open = _openShift(
        dayLabel: 'Fri',
        daypart: 'dinner',
        covers: 100,
        forecastCovers: 100,
        ppa: 40.0,
        fohHours: 10,
        bohHours: 10,
        snapshotBlendedWage: 20.0,
      );

      final projection = service.build([open]);
      final day = projection.dayRows.first;

      expect(day.laborPct, closeTo(10.0, 0.001),
          reason:
              '20 hours × \$20.00 snapshot blended wage = \$400 labor on \$4,000 sales => 10.0%');

      final legacyPct = open.totalLaborDollar / open.actualSales * 100;
      expect(day.laborPct, isNot(closeTo(legacyPct, 0.001)),
          reason:
              'Collapsed day-row labor % must not fall back to config-wage-derived dollars when snapshot blended wage is present');
    });
  });
}
