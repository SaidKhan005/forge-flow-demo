// Tests for ShiftService.closeShift.
//
// Current contract (7.55q.5): closing the 14th shift builds a WeekRecord
// whose `lockedRequiredFohHours` / `lockedRequiredBohHours` come from the
// `WeeklyPlanSnapshot` in force (read-only lookup by business date). No
// snapshot => fields stay null => Week Detail renders "-" honestly.
//
// These tests use the real SQLite database (sqflite_common_ffi on desktop)
// and call reseedDemo() before each test to ensure a clean, reproducible state.
//
// Historical origin: Phase 3 close-ingest path.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';

// â”€â”€ Shared close inputs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

ClosedShiftInput _friDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 27),
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'dinner',
      covers: 304,
      forecastCovers: 310,
      actualSales: 12768.0,
      actualFohHours: 71,
      actualBohHours: 73,
      scheduledFohHours: 69,
      scheduledBohHours: 72,
      actualFohLaborDollars: 1246.25,
      actualBohLaborDollars: 1627.75,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-fri-dinner-close',
    );

ClosedShiftInput _friLateNight() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 27),
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'late_night',
      covers: 84,
      forecastCovers: 90,
      actualSales: 3528.0,
      actualFohHours: 21,
      actualBohHours: 22,
      scheduledFohHours: 20,
      scheduledBohHours: 21,
      actualFohLaborDollars: 372.0,
      actualBohLaborDollars: 478.5,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-fri-late-close',
    );

ClosedShiftInput _satDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 28),
      weekId: '2026-W13',
      dayLabel: 'Sat',
      daypart: 'dinner',
      covers: 298,
      forecastCovers: 310,
      actualSales: 12665.0,
      actualFohHours: 70,
      actualBohHours: 72,
      scheduledFohHours: 69,
      scheduledBohHours: 72,
      actualFohLaborDollars: 1228.5,
      actualBohLaborDollars: 1606.0,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-sat-dinner-close',
    );

ClosedShiftInput _satLateNight() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 28),
      weekId: '2026-W13',
      dayLabel: 'Sat',
      daypart: 'late_night',
      covers: 88,
      forecastCovers: 90,
      actualSales: 3740.0,
      actualFohHours: 21,
      actualBohHours: 22,
      scheduledFohHours: 20,
      scheduledBohHours: 21,
      actualFohLaborDollars: 365.5,
      actualBohLaborDollars: 481.0,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-sat-late-close',
    );

ClosedShiftInput _sunDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 29),
      weekId: '2026-W13',
      dayLabel: 'Sun',
      daypart: 'dinner',
      covers: 176,
      forecastCovers: 180,
      actualSales: 7436.0,
      actualFohHours: 41,
      actualBohHours: 43,
      scheduledFohHours: 40,
      scheduledBohHours: 42,
      actualFohLaborDollars: 714.0,
      actualBohLaborDollars: 936.5,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-sun-dinner-close',
    );

// â”€â”€ Tests â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

void main() {
  setUp(() async {
    await DatabaseHelper.instance.reseedDemo();
  });

  // â”€â”€ Test 1: projected slot is replaced cleanly â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  test('projected Fri dinner slot is replaced cleanly', () async {
    // Before: one projected Fri/dinner row
    final before = await DatabaseHelper.instance.getShiftsForWeek('2026-W13');
    final friDinnerBefore = before.where(
      (s) => s.dayLabel == 'Fri' && s.daypart == 'dinner',
    ).toList();
    expect(friDinnerBefore.length, 1);
    expect(friDinnerBefore.first.status, 'projected');

    // Close the shift
    await ShiftService.instance.closeShift(_friDinner());

    // After: still 14 total rows
    final after = await DatabaseHelper.instance.getShiftsForWeek('2026-W13');
    expect(after.length, 14);

    // Exactly one Fri/dinner row
    final friDinnerAfter = after.where(
      (s) => s.dayLabel == 'Fri' && s.daypart == 'dinner',
    ).toList();
    expect(friDinnerAfter.length, 1);

    final closed = friDinnerAfter.first;

    // Status and source facts round-trip
    expect(closed.status, 'closed');
    expect(closed.scheduledFohHours, 69);
    expect(closed.scheduledBohHours, 72);
    expect(closed.storedFohLaborDollar, 1246.25);
    expect(closed.storedBohLaborDollar, 1627.75);
    expect(closed.sourceSystem, 'demo_pos');
    expect(closed.sourceShiftId, 'w13-fri-dinner-close');

    // primaryLever: uppercase underscore, not ON_MODEL
    expect(closed.primaryLever, equals(closed.primaryLever.toUpperCase()));
    expect(closed.primaryLever, isNot('ON_MODEL'));

    // Labor dollars come from stored source facts
    expect(closed.fohLaborDollar, closeTo(1246.25, 0.001));
    expect(closed.bohLaborDollar, closeTo(1627.75, 0.001));

    // WTD reflects the new closed shift
    final wtd = await ShiftService.instance.getWeekToDate('2026-W13', 'Mar 24');
    expect(wtd, isNotNull);
    expect(wtd!.totalCovers, 989); // 685 mock-replay closed + 304
    expect(wtd.shiftsCompleted, 10);

    // â”€â”€ WTD uses stored actual labor dollars, not config-wage fallback â”€â”€â”€â”€â”€â”€

    final closedShifts = after.where((s) => s.isClosed).toList();

    final expectedFohLaborDollar =
        closedShifts.fold<double>(0, (s, r) => s + r.fohLaborDollar);
    final expectedBohLaborDollar =
        closedShifts.fold<double>(0, (s, r) => s + r.bohLaborDollar);
    final expectedTotalLaborDollar =
        expectedFohLaborDollar + expectedBohLaborDollar;

    // Config-wage fallback total (what the old code would have returned)
    final configFallbackLaborDollar = closedShifts.fold<double>(
      0,
      (s, r) => s + (r.fohHours * 16.50) + (r.bohHours * 21.35),
    );

    expect(wtd.totalFohLaborDollar,
        closeTo(expectedFohLaborDollar, 0.001));
    expect(wtd.totalBohLaborDollar,
        closeTo(expectedBohLaborDollar, 0.001));
    expect(wtd.totalLaborDollar,
        closeTo(expectedTotalLaborDollar, 0.001));
    expect(wtd.actualLaborPct,
        closeTo(expectedTotalLaborDollar / wtd.totalSales * 100, 0.001));

    // Stored dollars differ from config-wage fallback once actual dollars exist
    expect(wtd.totalLaborDollar,
        isNot(closeTo(configFallbackLaborDollar, 0.001)));
  });

  // â”€â”€ Test 2: completed week creates a WeekRecord â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  test('closing all 14 shifts creates a WeekRecord for the week', () async {
    // Close the 5 remaining projected slots
    await ShiftService.instance.closeShift(_friDinner());
    await ShiftService.instance.closeShift(_friLateNight());
    await ShiftService.instance.closeShift(_satDinner());
    await ShiftService.instance.closeShift(_satLateNight());
    await ShiftService.instance.closeShift(_sunDinner());

    // Week history should now include 2026-W13
    final history = await ShiftService.instance.getWeekHistory();
    final w13 = history.where((w) => w.weekId == '2026-W13').toList();
    expect(w13.length, 1);

    final record = w13.first;
    expect(record.weekLabel, 'Mar 24');
    expect(record.shiftsCompleted, 14);
    expect(record.forecastCovers, 1721);
    expect(record.primaryLeverId, isNotEmpty);
    expect(record.blendedFohWage, greaterThan(0));
    expect(record.blendedBohWage, greaterThan(0));
  });

  // â”€â”€ Test 3: incomplete week does not create a WeekRecord â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  test('partial week (13 closed) does not create a WeekRecord', () async {
    // Close only one of the five projected shifts
    await ShiftService.instance.closeShift(_friDinner());

    final history = await ShiftService.instance.getWeekHistory();
    final w13 = history.where((w) => w.weekId == '2026-W13').toList();
    expect(w13, isEmpty);
  });

  // â”€â”€ 7.55q.5: preserved locked plan hours from snapshot â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  test('7.55q.5: closing all 14 shifts preserves locked plan FOH/BOH hours from the snapshot in force',
      () async {
    // Ensure a WeeklyPlanSnapshot is persisted for the current week.
    // This path auto-generates from the live plan when none is
    // persisted â€” acceptable for tests since we're just guaranteeing
    // the read-only lookup in _buildWeekRecord finds a snapshot.
    final snapshot = await WeeklyPlanSnapshotService.instance
        .getCurrentWeekSnapshot();
    expect(snapshot, isNotNull,
        reason:
            'current-week snapshot should be generable from the live plan');

    // Close the 5 remaining projected slots to complete the week.
    await ShiftService.instance.closeShift(_friDinner());
    await ShiftService.instance.closeShift(_friLateNight());
    await ShiftService.instance.closeShift(_satDinner());
    await ShiftService.instance.closeShift(_satLateNight());
    await ShiftService.instance.closeShift(_sunDinner());

    // The WeekRecord should carry the snapshot's locked plan hours.
    final history = await ShiftService.instance.getWeekHistory();
    final w13 = history.firstWhere((w) => w.weekId == '2026-W13');
    expect(w13.lockedRequiredFohHours, snapshot!.requiredFohHours);
    expect(w13.lockedRequiredBohHours, snapshot.requiredBohHours);

    // Strict getters now return the preserved values (no throw).
    expect(w13.targetFohHours, snapshot.requiredFohHours);
    expect(w13.targetBohHours, snapshot.requiredBohHours);
  });

  test('7.55q.5: closing all 14 shifts without a snapshot leaves preserved plan hours null (honest legacy)',
      () async {
    // Explicitly remove any snapshot that exists for the current week
    // so the close-time lookup finds nothing. Honest legacy path: the
    // preserved plan-hour fields stay null; Week Detail renders "â€”"
    // for those cells rather than re-modeling from actuals.
    final db = await SqliteDatabase.instance.database;
    await db.delete('weekly_plan_snapshots');

    await ShiftService.instance.closeShift(_friDinner());
    await ShiftService.instance.closeShift(_friLateNight());
    await ShiftService.instance.closeShift(_satDinner());
    await ShiftService.instance.closeShift(_satLateNight());
    await ShiftService.instance.closeShift(_sunDinner());

    final history = await ShiftService.instance.getWeekHistory();
    final w13 = history.firstWhere((w) => w.weekId == '2026-W13');
    expect(w13.lockedRequiredFohHours, isNull);
    expect(w13.lockedRequiredBohHours, isNull);
    expect(w13.preservedTargetFohHours, isNull);
    expect(w13.preservedTargetBohHours, isNull);

    // Strict getters must throw rather than silently re-model from actuals.
    expect(() => w13.targetFohHours, throwsA(isA<StateError>()));
    expect(() => w13.targetBohHours, throwsA(isA<StateError>()));
  });

  // â”€â”€ Test 4: WeekData fallback to config-wage when stored totals absent â”€

  test('WeekData degrades honestly to 0 labor dollars when stored totals are absent',
      () {
    final wtd = WeekData(
      weekId: 'test',
      weekLabel: 'Test',
      totalCovers: 100,
      totalSales: 4200,
      totalFohHours: 10,
      totalBohHours: 20,
      shiftsCompleted: 2,
      shiftsTotal: 14,
      wtdForecastCovers: 110,
      totalWeekForecastCovers: 700,
      primaryLeverId: 'covers_down',
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      targetFohWage: 16.50,
      targetBohWage: 21.35,
      theoreticalFohLaborPct: 8.7,
      theoreticalBohLaborPct: 11.9,
      theoreticalLaborPct: 20.6,
      // storedTotalFohLaborDollar and storedTotalBohLaborDollar intentionally omitted
    );

    expect(wtd.totalFohLaborDollar, closeTo(0.0, 0.001));
    expect(wtd.totalBohLaborDollar, closeTo(0.0, 0.001));
    expect(wtd.totalLaborDollar, closeTo(0.0, 0.001));
  });

  // -- 7.55q.10: frozen Dollar Impact windows at close ----------------------
  //
  // Closing the 14th shift must capture month + 60-day dollar impact and
  // a closedAt timestamp on the WeekRecord, so Week Detail can render the
  // same 4 rows the live Variance card was showing the moment the close
  // happened. Annualized must use the same (365/60) trend formula that
  // WeekData.annualizedDollarImpact uses, frozen to the snapshot value.
  //
  // Honest legacy: rows that pre-date V22 (or that have no usable shift
  // businessDate) leave all three fields null; Week Detail then renders
  // the historical 2-row + boilerplate-footer view.

  group('7.55q.10: frozen dollar impact windows at close', () {
    test('all 14 closed -> WeekRecord carries month + 60-day + closedAt',
        () async {
      final snapshot = await WeeklyPlanSnapshotService.instance
          .getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);
      final cycle = await SqliteTargetCycleRepository.instance
          .getCycleById(snapshot!.targetCycleId);
      expect(cycle, isNotNull);

      await ShiftService.instance.closeShift(_friDinner());
      await ShiftService.instance.closeShift(_friLateNight());
      await ShiftService.instance.closeShift(_satDinner());
      await ShiftService.instance.closeShift(_satLateNight());
      await ShiftService.instance.closeShift(_sunDinner());

      final history = await ShiftService.instance.getWeekHistory();
      final w13 = history.firstWhere((w) => w.weekId == '2026-W13');

      // closedAt is the latest business date among the 14 closed shifts.
      // Sunday dinner is 2026-03-29 (the last day of 2026-W13).
      expect(w13.closedAt, '2026-03-29');
      expect(w13.targetCalibrationWindowStart, cycle!.calibrationWindowStart);
      expect(w13.targetCalibrationWindowEnd, cycle.calibrationWindowEnd);

      // Both windows captured (non-null). Sign comes from
      // _accumulateDollarImpact = actualLabor - theoreticalLabor.
      expect(w13.monthDollarImpact, isNotNull);
      expect(w13.sixtyDayDollarImpact, isNotNull);
    });

    test('frozenAnnualizedImpact uses the (365/60) trend formula', () async {
      await ShiftService.instance.closeShift(_friDinner());
      await ShiftService.instance.closeShift(_friLateNight());
      await ShiftService.instance.closeShift(_satDinner());
      await ShiftService.instance.closeShift(_satLateNight());
      await ShiftService.instance.closeShift(_sunDinner());

      final history = await ShiftService.instance.getWeekHistory();
      final w13 = history.firstWhere((w) => w.weekId == '2026-W13');

      expect(w13.frozenAnnualizedImpact, isNotNull);
      expect(
        w13.frozenAnnualizedImpact!,
        closeTo(w13.sixtyDayDollarImpact! * (365.0 / 60), 0.001),
      );
    });

    test('legacy null path: frozenAnnualizedImpact null; dollarGapAnnualized still computes',
        () {
      // Simulate a pre-V22 row by constructing a WeekRecord without the
      // new fields — they default to null per the additive constructor.
      const legacy = WeekRecord(
        weekId: '2025-W42',
        weekLabel: 'Oct 13',
        totalCovers: 1000,
        forecastCovers: 1000,
        totalFohHours: 200,
        totalBohHours: 220,
        avgPPA: 42.0,
        avgCPLH: 5.0,
        theoreticalLaborPct: 20.6,
        actualLaborPct: 21.0,
        dollarGap: 200.0,
        primaryLeverId: 'covers_down',
      );

      expect(legacy.monthDollarImpact, isNull);
      expect(legacy.sixtyDayDollarImpact, isNull);
      expect(legacy.closedAt, isNull);
      expect(legacy.frozenAnnualizedImpact, isNull);

      // Legacy ×52 fallback still works: dollarGap.abs() * 52 = 200 * 52
      expect(legacy.dollarGapAnnualized, closeTo(200.0 * 52, 0.001));
    });
  });
}
