// Tests for ShiftService.closeShift â€” the Phase 3 ingest path.
//
// These tests use the real SQLite database (sqflite_common_ffi on desktop)
// and call reseedDemo() before each test to ensure a clean, reproducible state.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/database_helper.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/models/week_data.dart';

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

  // â”€â”€ Test 4: WeekData fallback to config-wage when stored totals absent â”€

  test('WeekData falls back to config-wage labor dollars when stored totals are absent',
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

    expect(wtd.totalFohLaborDollar, closeTo(165.0, 0.001));  // 10 Ã— 16.50
    expect(wtd.totalBohLaborDollar, closeTo(427.0, 0.001));  // 20 Ã— 21.35
    expect(wtd.totalLaborDollar,    closeTo(592.0, 0.001));  // 165 + 427
  });
}
