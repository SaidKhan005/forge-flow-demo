// Phase 7.55e.5 — MockIntegrationReplaySeed unit tests.
//
// Validates that the deterministic mock POS/labor replay generator produces
// operationally coherent data suitable for SQLite bootstrap:
// - 8 historical weeks with 14-shift operating pattern
// - Day/daypart variation (Saturday dinner > Monday lunch)
// - WeekRecords derived from shift-level sums
// - Distribution weights availability
// - SQLite seed integration

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/services/distribution_weight_builder.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  // ── A. Generator output structure ───────────────────────────────────────

  group('A — generator output structure', () {
    test('produces 8 historical weeks with 14 shifts each', () {
      final output = MockIntegrationReplaySeed.output;

      expect(output.weekRecords.length, 8);
      expect(output.historicalClosedShifts.length, 112); // 8 × 14

      for (final weekId in MockIntegrationReplaySeed.historicalWeekIds) {
        final weekShifts = output.historicalClosedShifts
            .where((s) => s.weekId == weekId)
            .toList();
        expect(weekShifts.length, 14, reason: '$weekId should have 14 shifts');
        expect(weekShifts.every((s) => s.isClosed), isTrue,
            reason: '$weekId historical shifts should all be closed');
      }
    });

    test('current week has 9 closed + 5 projected shifts', () {
      final output = MockIntegrationReplaySeed.output;
      final current = output.currentWeekShifts;

      expect(current.length, 14);
      expect(current.where((s) => s.isClosed).length, 9);
      expect(current.where((s) => s.isProjected).length, 5);
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
        expect(week.shiftsCompleted, 14,
            reason: '${week.weekId} should have 14 completed shifts');
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
      // 8 weeks × 7 days = 56 distinct business days (>= 14 threshold)
      expect(weights.closedBusinessDayCount, 56);
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
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
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

      final rows = await db.query('open_shift_snapshots',
          where: "day_label = 'Fri' AND daypart = 'dinner' AND status = 'open'");
      expect(rows.length, 1);

      final snap = rows.first;

      // Provenance: source_system must be mock replay
      expect(snap['source_system'], MockIntegrationReplaySeed.sourceSystem);
      expect(snap['source_shift_id'],
          MockIntegrationReplaySeed.openShiftSourceShiftId);

      // Values coherently derive from mock replay Friday dinner plan
      final friDinnerPlan = MockIntegrationReplaySeed.output.currentWeekShifts
          .firstWhere(
              (s) => s.dayLabel == 'Fri' && s.daypart == 'dinner');

      // Forecast and scheduled hours match the replay projected row
      expect(snap['forecast_covers'], friDinnerPlan.forecastCovers);
      expect(snap['scheduled_foh_hours'], friDinnerPlan.fohHours);
      expect(snap['scheduled_boh_hours'], friDinnerPlan.bohHours);

      // Current covers are a deterministic fraction of forecast
      final expectedCovers = (friDinnerPlan.forecastCovers *
              MockIntegrationReplaySeed.openProgressFraction)
          .round();
      expect(snap['current_covers'], expectedCovers);

      // Time labels come from mock replay constants
      expect(snap['time_label'], MockIntegrationReplaySeed.openShiftTimeLabel);
      expect(snap['service_elapsed_label'],
          MockIntegrationReplaySeed.openShiftServiceElapsedLabel);

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
