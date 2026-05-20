// Phase 7.55e.5 — MockIntegrationReplaySeed unit tests.
//
// Validates that the deterministic mock POS/labor replay generator produces
// operationally coherent data suitable for SQLite bootstrap:
// - [historicalWeekCount] historical weeks with 16-shift operating
//   pattern (Slice B raised weeks 8 → 12; QA fix Change B raised
//   slots/week 14 → 16 — weekends now serve Lunch)
// - Day/daypart variation (Saturday dinner > Monday lunch)
// - WeekRecords derived from shift-level sums
// - Distribution weights availability
// - SQLite seed integration

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/services/distribution_weight_builder.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

import '_test_helpers/cold_boot_helpers.dart';
import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  // Fix A (operator decision 2026-05-16): the "none connected" demo
  // location (today Harbour) is honest-EMPTY; per-location open-shift
  // fan-out covers the CONNECTED demo locations only.
  final connectedDemoScopeIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toSet();
  // ── A. Generator output structure ───────────────────────────────────────

  group('A — generator output structure', () {
    test('produces [historicalWeekCount] historical weeks with 16 shifts '
        'each', () {
      // QA fix (Change B): weekends now serve Lunch → 16 slots/week.
      final output = MockIntegrationReplaySeed.output;
      final weeks = MockIntegrationReplaySeed.historicalWeekCount;

      expect(output.weekRecords.length, weeks);
      expect(output.historicalClosedShifts.length, weeks * 16);

      for (final weekId in MockIntegrationReplaySeed.historicalWeekIds) {
        final weekShifts = output.historicalClosedShifts
            .where((s) => s.weekId == weekId)
            .toList();
        expect(weekShifts.length, 16, reason: '$weekId should have 16 shifts');
        expect(weekShifts.every((s) => s.isClosed), isTrue,
            reason: '$weekId historical shifts should all be closed');
      }
    });

    test('current week has 9 closed + 7 projected shifts', () {
      // Static `output` = back-compat default (Fri, Dinner open). Change
      // B added weekend Lunch → 16-slot week: 9 closed, 7 projected.
      final output = MockIntegrationReplaySeed.output;
      final current = output.currentWeekShifts;

      expect(current.length, 16);
      expect(current.where((s) => s.isClosed).length, 9);
      expect(current.where((s) => s.isProjected).length, 7);
      expect(current.every((s) => s.weekId == '2026-W13'), isTrue);
    });
  });

  // ── B. Day and daypart variation ────────────────────────────────────────

  group('B — day and daypart variation', () {
    test('Saturday dinner covers exceed Monday lunch covers', () {
      final shifts = MockIntegrationReplaySeed.output.historicalClosedShifts;

      final satDinners = shifts
          .where((s) => s.dayLabel == 'Sat' && s.daypart == 'dinner');
      final monLunches = shifts
          .where((s) => s.dayLabel == 'Mon' && s.daypart == 'lunch');

      final avgSatDinner =
          satDinners.fold<double>(0, (s, r) => s + r.covers) /
              satDinners.length;
      final avgMonLunch =
          monLunches.fold<double>(0, (s, r) => s + r.covers) /
              monLunches.length;

      expect(avgSatDinner, greaterThan(avgMonLunch),
          reason: 'Saturday dinner should be busier than Monday lunch');
    });

    test('late night covers smaller than dinner covers on same day', () {
      final shifts = MockIntegrationReplaySeed.output.historicalClosedShifts;

      final friDinners = shifts
          .where((s) => s.dayLabel == 'Fri' && s.daypart == 'dinner');
      final friLateNights = shifts
          .where((s) => s.dayLabel == 'Fri' && s.daypart == 'late_night');

      final avgDinner =
          friDinners.fold<double>(0, (s, r) => s + r.covers) /
              friDinners.length;
      final avgLateNight =
          friLateNights.fold<double>(0, (s, r) => s + r.covers) /
              friLateNights.length;

      expect(avgDinner, greaterThan(avgLateNight));
    });
  });

  // ── C. WeekRecord reconciliation ────────────────────────────────────────

  group('C — WeekRecords reconcile to generated shifts', () {
    test('covers, FOH hours, and BOH hours match shift sums', () {
      final output = MockIntegrationReplaySeed.output;

      for (final week in output.weekRecords) {
        final shifts = output.historicalClosedShifts
            .where((s) => s.weekId == week.weekId)
            .toList();

        final shiftCovers = shifts.fold<int>(0, (s, r) => s + r.covers);
        final shiftFoh = shifts.fold<int>(0, (s, r) => s + r.fohHours);
        final shiftBoh = shifts.fold<int>(0, (s, r) => s + r.bohHours);

        expect(week.totalCovers, shiftCovers,
            reason: '${week.weekId} covers mismatch');
        expect(week.totalFohHours, shiftFoh,
            reason: '${week.weekId} FOH hours mismatch');
        expect(week.totalBohHours, shiftBoh,
            reason: '${week.weekId} BOH hours mismatch');
        expect(week.shiftsCompleted, 16,
            reason: '${week.weekId} should have 16 completed shifts '
                '(QA fix Change B: weekends serve Lunch)');
      }
    });
  });

  // ── D. Distribution weight availability ─────────────────────────────────

  group('D — distribution weights from generated shifts', () {
    test('distribution weights are available with day x daypart coverage', () {
      final output = MockIntegrationReplaySeed.output;
      final weights = DistributionWeightBuilder.fromClosedShifts(
          output.historicalClosedShifts);

      expect(weights.isAvailable, isTrue);
      // historicalWeekCount weeks × 7 days distinct business days
      // (>= 14 threshold).
      expect(weights.closedBusinessDayCount,
          MockIntegrationReplaySeed.historicalWeekCount * 7);
      expect(weights.dayWeights, isNotEmpty);
      expect(weights.dayWeights.length, 7);
      expect(weights.daypartWeightsByDay, isNotEmpty);

      // Day x daypart weights exist for key days
      expect(weights.daypartWeightsFor('Sat'), isNotEmpty);
      expect(weights.daypartWeightsFor('Mon'), isNotEmpty);
      expect(weights.daypartWeightsFor('Fri').containsKey('late_night'), isTrue);
    });
  });

  // ── E. SQLite seed integration ──────────────────────────────────────────

  group('E — SQLite seed uses mock replay', () {
    // QA fix (Change A): the open period is clock-derived. Pin the
    // restaurant-local now to a fixed instant so the open snapshot is
    // deterministic; assertions derive expected values from the SAME
    // resolver (`resolveDemoOpenPeriod`) instead of the old fabricated
    // 0.63 / 7:45 PM / 3h 15m constants.
    const pinnedNow = '2026-03-27T19:45:00'; // Fri, Dinner in progress

    setUp(() async {
      // Bucket 4d (audit 2026-05-20): set+reset via ColdBootOverrideScope
      // so the override can't leak between tests (PR #1091 bug shape).
      // Bucket 4b Category C (audit 2026-05-20): reseed delegated to
      // `setUpSqliteDemo`. Order matters — scope is constructed FIRST so
      // the override is live when reseedDemo runs.
      final scope = ColdBootOverrideScope(now: pinnedNow);
      addTearDown(scope.dispose);
      await setUpSqliteDemo();
    });

    test('seeded shifts carry mock replay source system', () async {
      final db = await SqliteDatabase.instance.database;

      final shifts = await db.query('shift_records',
          where: 'source_system = ?',
          whereArgs: ['mock_pos_labor_replay']);
      expect(shifts, isNotEmpty,
          reason: 'shift_records should come from mock_pos_labor_replay');

      // Import run uses the new mode
      final runs = await db.query('import_runs',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(runs, isNotEmpty);
      expect(runs.first['mode'], 'mock_pos_labor_replay');
    });

    test('current-week open/projected snapshots exist from mock replay', () async {
      final db = await SqliteDatabase.instance.database;

      // Current week shifts exist
      final shifts = await db.query('shift_records',
          where: 'week_id = ?', whereArgs: ['2026-W13']);
      expect(shifts, isNotEmpty);

      // Open shift snapshots exist
      final snapshots = await db.query('open_shift_snapshots');
      expect(snapshots, isNotEmpty);

      // At least one projected and one open snapshot
      final projected =
          snapshots.where((s) => s['status'] == 'projected').toList();
      final open = snapshots.where((s) => s['status'] == 'open').toList();
      expect(projected, isNotEmpty);
      expect(open, isNotEmpty);
    });

    test('open Friday dinner snapshot derives from mock replay, not legacy ShiftSnapshot', () async {
      final db = await SqliteDatabase.instance.database;

      // Per-location current-week open-shift slice: every demo location
      // now has its own Fri-dinner live open row. This test pins
      // Downtown's byte-for-byte derivation from the BASE replay plan, so
      // scope to Downtown; the per-location fan-out is asserted in
      // per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart.
      final allFriOpen = await db.query('open_shift_snapshots',
          where: "day_label = 'Fri' AND daypart = 'dinner' "
              "AND status = 'open'");
      expect(
          allFriOpen.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds,
          reason: 'every CONNECTED location has its own Fri-dinner live '
              'open row (the none-connected location is honest-empty)');
      final rows = await db.query('open_shift_snapshots',
          where: "day_label = 'Fri' AND daypart = 'dinner' "
              "AND status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(rows.length, 1);

      final snap = rows.first;

      // Provenance: source_system must be mock replay
      expect(snap['source_system'], MockIntegrationReplaySeed.sourceSystem);
      expect(snap['source_shift_id'],
          MockIntegrationReplaySeed.openShiftSourceShiftId);

      // QA fix (Change A): values derive from the clock-derived
      // resolution for the pinned now, NOT the old fixed fabrication.
      final resolution = resolveDemoOpenPeriod(
        localNow: DateTime.parse(pinnedNow),
      );
      expect(resolution.openDaypart, 'dinner',
          reason: 'Fri 19:45 → Dinner in progress');

      // The seed regenerates with the same clock anchor; read the Fri
      // dinner plan from a matching generate call.
      final friDinnerPlan = MockIntegrationReplaySeed.generateForDate(
        '2026-03-27',
        open: resolution,
      ).currentWeekShifts.firstWhere(
            (s) => s.dayLabel == 'Fri' && s.daypart == 'dinner',
          );

      // Forecast and scheduled hours match the replay projected row
      expect(snap['forecast_covers'], friDinnerPlan.forecastCovers);
      expect(snap['scheduled_foh_hours'], friDinnerPlan.fohHours);
      expect(snap['scheduled_boh_hours'], friDinnerPlan.bohHours);

      // Current covers are the clock-derived fraction of forecast
      // (honest live progress, not a hardcoded 0.63).
      final expectedCovers = (friDinnerPlan.forecastCovers *
              resolution.openProgressFraction!)
          .round();
      expect(snap['current_covers'], expectedCovers);

      // Time labels are clock-derived from the pinned now
      expect(snap['time_label'], resolution.openTimeLabel);
      expect(snap['service_elapsed_label'],
          resolution.openServiceElapsedLabel);

      // Current metrics are positive and coherent
      expect((snap['current_ppa'] as num).toDouble(), greaterThan(0));
      expect((snap['current_cplh'] as num).toDouble(), greaterThan(0));
      expect((snap['current_splh'] as num).toDouble(), greaterThan(0));
    });
  });

  // ── F. businessDate on generated ShiftRecords ──────────────────────────

  group('F — generated ShiftRecords carry valid businessDate', () {
    test('all historical shifts have non-null businessDate', () {
      for (final s in MockIntegrationReplaySeed.output.historicalClosedShifts) {
        expect(s.businessDate, isNotNull,
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} should have businessDate');
      }
    });

    test('all current week shifts have non-null businessDate', () {
      for (final s in MockIntegrationReplaySeed.output.currentWeekShifts) {
        expect(s.businessDate, isNotNull,
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} should have businessDate');
      }
    });

    test('no generated ShiftRecord has 1970-01-01 as businessDate', () {
      final all = [
        ...MockIntegrationReplaySeed.output.historicalClosedShifts,
        ...MockIntegrationReplaySeed.output.currentWeekShifts,
      ];
      for (final s in all) {
        expect(s.businessDate, isNot('1970-01-01'),
            reason: '${s.weekId}/${s.dayLabel}/${s.daypart} must not have sentinel date');
      }
    });
  });

  // ── G. snapshotSourceShiftId helper ────────────────────────────────────

  group('G — snapshotSourceShiftId deterministic ids', () {
    test('produces stable human-readable ids', () {
      expect(
        MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: '2026-W13',
          dayLabel: 'Fri',
          daypart: 'late_night',
          status: 'projected',
        ),
        'w13-fri-late_night-projected',
      );
      expect(
        MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: '2026-W13',
          dayLabel: 'Fri',
          daypart: 'lunch',
          status: 'closed',
        ),
        'w13-fri-lunch-closed',
      );
      expect(
        MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: '2026-W13',
          dayLabel: 'Sat',
          daypart: 'dinner',
          status: 'projected',
        ),
        'w13-sat-dinner-projected',
      );
    });
  });
}
