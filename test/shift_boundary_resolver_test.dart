// Shift boundary resolver focused tests.
//
// Validates:
// A. servicePeriodHasEnded() — same-day period before/at/after cutoff
// B. servicePeriodHasEnded() — rollover period (late_night)
// C. isEligibleForClosedTruth() — appLocalCutoffFallback excludes same-date
// D. isEligibleForClosedTruth() — appLocalCutoffFallback includes prior-date
// E. isEligibleForClosedTruth() — vendorFinalization treats closed as finalized
// F. Locked WTD finalization gate — same-business-date row excluded
// G. Locked WTD — Sunday/Wednesday-start still works for finalized rows
// H. Locked WTD uses locked snapshot forecast truth + current active-profile targets

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/wage_standard_context_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/shift_boundary_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = demoRestaurantId;

  // ── Demo service-period definitions used in tests ───────────────────────

  const lunch = ServicePeriodDefinition(
    id: 'lunch',
    label: 'Lunch',
    shortLabel: 'L',
    sortOrder: 1,
    startLocalTime: '11:00',
    endLocalTime: '15:00',
    rollsPastMidnight: false,
    applicableDays: [1, 2, 3, 4, 5],
  );

  const dinner = ServicePeriodDefinition(
    id: 'dinner',
    label: 'Dinner',
    shortLabel: 'D',
    sortOrder: 2,
    startLocalTime: '17:00',
    endLocalTime: '23:00',
    rollsPastMidnight: false,
    applicableDays: [1, 2, 3, 4, 5, 6, 7],
  );

  const lateNight = ServicePeriodDefinition(
    id: 'late_night',
    label: 'Late Night',
    shortLabel: 'LN',
    sortOrder: 3,
    startLocalTime: '23:00',
    endLocalTime: '02:00',
    rollsPastMidnight: true,
    applicableDays: [5, 6],
  );

  // ── A: servicePeriodHasEnded — same-day period ──────────────────────────

  group('A — servicePeriodHasEnded same-day period', () {
    test('before cutoff → not ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 27, 14, 30), // 14:30
        servicePeriod: lunch, // ends 15:00
      );
      expect(result, isFalse);
    });

    test('at cutoff → ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 27, 15, 0), // 15:00
        servicePeriod: lunch, // ends 15:00
      );
      expect(result, isTrue);
    });

    test('after cutoff → ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 27, 16, 0), // 16:00
        servicePeriod: lunch, // ends 15:00
      );
      expect(result, isTrue);
    });

    test('dinner: before 23:00 → not ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 27, 22, 45), // 22:45
        servicePeriod: dinner, // ends 23:00
      );
      expect(result, isFalse);
    });

    test('dinner: at 23:00 → ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 27, 23, 0), // 23:00
        servicePeriod: dinner, // ends 23:00
      );
      expect(result, isTrue);
    });
  });

  // ── B: servicePeriodHasEnded — rollover period ──────────────────────────

  group('B — servicePeriodHasEnded rollover period (late_night)', () {
    test('during active window (23:30) → not ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 28, 23, 30), // 23:30
        servicePeriod: lateNight, // 23:00–02:00 rolls
      );
      expect(result, isFalse);
    });

    test('during active window past midnight (01:30) → not ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 29, 1, 30), // 01:30
        servicePeriod: lateNight, // 23:00–02:00 rolls
      );
      expect(result, isFalse);
    });

    test('after end (02:30 next day) → ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 29, 2, 30), // 02:30
        servicePeriod: lateNight, // 23:00–02:00 rolls
      );
      expect(result, isTrue);
    });

    test('at end boundary (02:00) → in the gap, ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 29, 2, 0), // 02:00
        servicePeriod: lateNight, // 23:00–02:00 rolls
      );
      expect(result, isTrue);
    });

    test('daytime (14:00) → in the gap, ended', () {
      final result = ShiftBoundaryResolver.servicePeriodHasEnded(
        localTimestamp: DateTime(2026, 3, 29, 14, 0), // 14:00
        servicePeriod: lateNight, // 23:00–02:00 rolls
      );
      expect(result, isTrue);
    });
  });

  // ── C: isEligibleForClosedTruth — appLocalCutoffFallback excludes same-date

  group('C — appLocalCutoffFallback excludes same-business-date', () {
    test('same-business-date closed row → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-27',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isFalse,
          reason: 'Same-date row should not be finalized under app-local');
    });

    test('projected row → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'projected',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-26',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isFalse);
    });

    test('open row → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'open',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-27',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isFalse);
    });

    test('null business date → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: null,
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isFalse);
    });

    test('null operational date → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-26',
        currentOperationalBusinessDate: null,
      );
      expect(result, isFalse);
    });
  });

  // ── D: isEligibleForClosedTruth — appLocalCutoffFallback includes prior-date

  group('D — appLocalCutoffFallback includes prior-business-date', () {
    test('prior-business-date closed row → eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-26',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isTrue);
    });

    test('two days prior → eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
        rowBusinessDate: '2026-03-25',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isTrue);
    });
  });

  // ── E: isEligibleForClosedTruth — vendorFinalization ────────────────────

  group('E — vendorFinalization treats vendor-closed as finalized', () {
    test('closed row under vendorFinalization → eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.vendorFinalization,
        rowBusinessDate: '2026-03-27',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isTrue,
          reason: 'Vendor says closed → finalized, regardless of date');
    });

    test('same-date closed row under vendorFinalization → eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'closed',
        shiftCloseAuthority: ShiftCloseAuthority.vendorFinalization,
        rowBusinessDate: '2026-03-27',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isTrue);
    });

    test('projected row under vendorFinalization → not eligible', () {
      final result = ShiftBoundaryResolver.isEligibleForClosedTruth(
        rowStatus: 'projected',
        shiftCloseAuthority: ShiftCloseAuthority.vendorFinalization,
        rowBusinessDate: '2026-03-26',
        currentOperationalBusinessDate: '2026-03-27',
      );
      expect(result, isFalse);
    });
  });

  // ── F–H: Integration tests using live SQLite DB ─────────────────────────

  setUp(() async {
    await setUpSqliteDemo();
    // Restore Monday-default demo config.
    //
    // Per-Daypart V1 Slice 1.5: `shift_close_authority` /
    // `local_close_fallback` were dropped from this row. The
    // per-row close authority is auto-derived from each shift's
    // `sourceSystem` POS vendor id via
    // `lib/services/integration/close_authority_capability.dart`.
    final db = await SqliteDatabase.instance.database;
    await db.delete('restaurant_timing_configs');
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('restaurant_timing_configs', {
      'restaurant_id': restaurantId,
      'business_day_start_local_time': '04:00',
      'week_start_day': DateTime.monday,
      'service_period_definitions_json': jsonEncode([
        {'id': 'lunch', 'label': 'Lunch', 'short_label': 'L', 'sort_order': 1, 'start_local_time': '11:00', 'end_local_time': '15:00', 'rolls_past_midnight': false, 'applicable_days': [1, 2, 3, 4, 5]},
        {'id': 'dinner', 'label': 'Dinner', 'short_label': 'D', 'sort_order': 2, 'start_local_time': '17:00', 'end_local_time': '23:00', 'rolls_past_midnight': false, 'applicable_days': [1, 2, 3, 4, 5, 6, 7]},
        {'id': 'late_night', 'label': 'Late Night', 'short_label': 'LN', 'sort_order': 3, 'start_local_time': '23:00', 'end_local_time': '02:00', 'rolls_past_midnight': true, 'applicable_days': [5, 6]},
      ]),
      'created_at': now,
      'updated_at': now,
    });
    SqliteRestaurantTimingConfigRepository.instance.resetDao();
  });

  // ── F: Locked WTD finalization gate ─────────────────────────────────────

  group('F — locked WTD finalization gate', () {
    test(
        'Monday-default: same-business-date lunch row excluded from locked WTD',
        () async {
      // Seeded demo has current operational business date = 2026-03-27 (Fri).
      // Seeded data includes closed rows for 2026-03-27 (same day).
      // Under appLocalCutoffFallback, same-date rows should be excluded.
      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);

      // In the seeded demo, shifts through Thu (2026-03-26) are prior-date.
      // Fri (2026-03-27) shifts are same-date → should be excluded.
      // Mon–Thu have 2 shifts each (lunch+dinner) = 8 shifts.
      // Fri lunch is same-date closed → excluded.
      // So finalized shifts = prior-date only = Mon–Thu = 8 shifts.
      expect(wtd!.shiftsCompleted, 8,
          reason: 'Same-business-date rows should be excluded from '
              'finalized WTD under appLocalCutoffFallback');

      // closedDayNumber should reflect the last finalized date (Thu = Day 4)
      expect(wtd.closedDayNumber, 4,
          reason: 'Last finalized date is Thursday = Day 4');
      expect(wtd.lastClosedDay, 'Thursday');
      expect(wtd.lastClosedBusinessDate, '2026-03-26');
    });

    test('vendorFinalization: same-business-date rows are included', () async {
      // Per-Daypart V1 Slice 1.5: close-authority is auto-derived per
      // shift from `sourceSystem`. Re-stamp every seeded closed row's
      // `source_system` to `toast` (a reliable POS vendor per
      // `close_authority_capability.dart`) so the boundary resolver
      // classifies every closed row as `vendorFinalization` and lets
      // the same-business-date Fri lunch row count as finalized.
      final db = await SqliteDatabase.instance.database;
      await db.update(
        'shift_records',
        {'source_system': 'toast'},
        where: 'restaurant_id = ? AND status = ?',
        whereArgs: [restaurantId, 'closed'],
      );
      SqliteRestaurantTimingConfigRepository.instance.resetDao();

      // Clear snapshot to regenerate.
      await db.delete('weekly_plan_snapshots');

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);

      // Under vendorFinalization, all closed rows count as finalized.
      // Mon–Thu = 8 + Fri lunch = 9 shifts.
      expect(wtd!.shiftsCompleted, 9,
          reason: 'Under vendorFinalization, all closed rows are finalized');
      expect(wtd.closedDayNumber, 5,
          reason: 'Fri is Day 5 and its lunch row is finalized');
      expect(wtd.lastClosedBusinessDate, '2026-03-27');
    });
  });

  // ── G: Week-start behavior still works for finalized rows ───────────────

  group('G — week-start wiring with finalization', () {
    test('Sunday-start locked WTD still includes prior-date finalized rows',
        () async {
      // Switch to Sunday start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final sundayConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.sunday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(sundayConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('shift_records');

      // Sunday-start week for 2026-03-27: Sun 2026-03-22 to Sat 2026-03-28.
      // Insert closed shifts on Sun 2026-03-22 and Mon 2026-03-23 (both
      // prior to operational date 2026-03-27).
      for (final entry in [
        {'date': '2026-03-22', 'day': 'Sun', 'id': 'test_g_sun'},
        {'date': '2026-03-23', 'day': 'Mon', 'id': 'test_g_mon'},
      ]) {
        final rec = ShiftRecord(
          restaurantId: restaurantId,
          status: 'closed',
          weekId: '2026-W12',
          dayLabel: entry['day']!,
          daypart: 'dinner',
          businessDate: entry['date'],
          covers: 80,
          forecastCovers: 90,
          ppa: 25.0,
          cplh: 20.0,
          splh: 60.0,
          fohHours: 4,
          bohHours: 3,
          theoreticalLaborPct: 28.0,
          primaryLever: 'CPLH',
          scheduledFohHours: 5,
          scheduledBohHours: 4,
          storedFohLaborDollar: 60.0,
          storedBohLaborDollar: 45.0,
          targetProfileId: 'tp_demo',
          targetProfileVersionId: 'tpv_demo',
          targetSourceType: 'benchmark_recommended',
          targetCPLH: 22.0,
          targetSPLH: 65.0,
          targetPPA: 26.0,
          targetFohWage: 15.0,
          targetBohWage: 14.0,
          opzFloorCPLH: 18.0,
          opzCeilingCPLH: 30.0,
          theoreticalFohLaborPct: 16.0,
          theoreticalBohLaborPct: 12.0,
          sourceSystem: 'mock_replay',
          sourceShiftId: entry['id'],
        );
        await db.insert('shift_records', rec.toMap()..remove('id'));
      }

      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);

      // Both shifts are prior-date (2026-03-22 and 2026-03-23 < 2026-03-27).
      // Both should be finalized under appLocalCutoffFallback.
      expect(weekData!.shiftsCompleted, 2);
      expect(weekData.closedDayNumber, 2,
          reason: 'Monday is Day 2 in a Sunday-start week');
      expect(weekData.lastClosedDay, 'Monday');
    });

    test('Wednesday-start locked WTD excludes same-date finalized row',
        () async {
      // Switch to Wednesday start.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(restaurantId);
      final wedConfig = RestaurantTimingConfig(
        restaurantId: restaurantId,
        businessTimezone: config!.businessTimezone,
        businessDayStartLocalTime: config.businessDayStartLocalTime,
        weekStartDay: DateTime.wednesday,
        servicePeriodDefinitions: config.servicePeriodDefinitions,
        createdAt: config.createdAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.saveTimingConfig(wedConfig);
      repo.resetDao();

      final db = await SqliteDatabase.instance.database;
      await db.delete('weekly_plan_snapshots');
      await db.delete('shift_records');

      // Wednesday-start week for 2026-03-27: Wed 2026-03-25 to Tue 2026-03-31.
      // Insert one prior-date and one same-date closed shift.
      // Operational business date = 2026-03-27 (Fri).
      for (final entry in [
        {'date': '2026-03-25', 'day': 'Wed', 'id': 'test_g2_wed'},
        {'date': '2026-03-27', 'day': 'Fri', 'id': 'test_g2_fri'},
      ]) {
        final rec = ShiftRecord(
          restaurantId: restaurantId,
          status: 'closed',
          weekId: '2026-W13',
          dayLabel: entry['day']!,
          daypart: 'dinner',
          businessDate: entry['date'],
          covers: 70,
          forecastCovers: 80,
          ppa: 24.0,
          cplh: 19.0,
          splh: 58.0,
          fohHours: 4,
          bohHours: 3,
          theoreticalLaborPct: 27.0,
          primaryLever: 'CPLH',
          scheduledFohHours: 5,
          scheduledBohHours: 4,
          storedFohLaborDollar: 60.0,
          storedBohLaborDollar: 42.0,
          targetProfileId: 'tp_demo',
          targetProfileVersionId: 'tpv_demo',
          targetSourceType: 'benchmark_recommended',
          targetCPLH: 22.0,
          targetSPLH: 65.0,
          targetPPA: 26.0,
          targetFohWage: 15.0,
          targetBohWage: 14.0,
          opzFloorCPLH: 18.0,
          opzCeilingCPLH: 30.0,
          theoreticalFohLaborPct: 16.0,
          theoreticalBohLaborPct: 12.0,
          sourceSystem: 'mock_replay',
          sourceShiftId: entry['id'],
        );
        await db.insert('shift_records', rec.toMap()..remove('id'));
      }

      final weekData = await ShiftService.instance.getLiveWeekToDate();
      expect(weekData, isNotNull);

      // Wed is prior-date → finalized. Fri is same-date → excluded.
      expect(weekData!.shiftsCompleted, 1,
          reason: 'Only prior-date Wed shift is finalized');
      expect(weekData.closedDayNumber, 1,
          reason: 'Wednesday is Day 1 in a Wednesday-start week');
      expect(weekData.lastClosedDay, 'Wednesday');
    });
  });

  // ── H: Locked WTD uses locked snapshot forecast truth + current active profile ──

  group('H — locked WTD uses snapshot forecast and current active profile targets', () {
    test('getLiveWeekToDate uses locked snapshot forecast covers', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.totalWeekForecastCovers, equals(snapshot!.forecastCovers),
          reason: 'Weekly forecast must come from locked snapshot');
    });

    test('getLiveWeekToDate uses current active profile for targets', () async {
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final profile = await WageStandardContextService.instance
          .loadOrBootstrapProfile(restaurantId);

      final wtd = await ShiftService.instance.getLiveWeekToDate();
      expect(wtd, isNotNull);
      expect(wtd!.targetCPLH, equals(profile.targetCPLH),
          reason: 'WTD target CPLH must come from the current active profile');
      expect(wtd.targetPPA, equals(profile.targetPPA),
          reason: 'WTD target PPA must come from the current active profile');
    });
  });
}
