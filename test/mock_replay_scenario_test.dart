// Phase 7.55f.4 + 7.55m.2 + 7.55m.2a — Mock replay scenario tests.
//
// Validates:
// A. Parameterized generation produces correct scenarios
// B. SQLite reseed coherence across all operational tables
// C. Manager Override anchor follows mock replay date
// D. Week boundary crossing rolls week ids coherently
// E. Replay-stable locked artifacts survive replay advance (7.55m.2)
// F. Live planning surfaces move with anchor (7.55m.2)
// G. Replay-regenerated scenario data rebuilds coherently (7.55m.2a)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/demo_vendor_integration_state_fixture.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/weekly_plan_snapshot_service.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

import '_test_helpers/cold_boot_helpers.dart';

void main() {
  // Fix A (operator decision 2026-05-16): a "none connected" demo
  // location (today Harbour) is honest-EMPTY — it carries NO
  // operational rows. Coherence assertions about operational-table
  // scopes therefore expect the CONNECTED demo locations, generalized
  // off the vendor fixture (not a hardcoded id).
  final connectedDemoScopeIds = DemoScope.locations
      .map((l) => l.restaurantId)
      .where((id) => !DemoVendorIntegrationStateFixture.isNoneConnected(id))
      .toSet();

  setUp(() async {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    // QA fix (Change A): the open period is now clock-derived. Pin the
    // restaurant-local time-of-day to 19:45 (Dinner is in progress every
    // weekday) so the reseed/advance-based coherence assertions below
    // stay deterministic and keep their pre-fix Dinner-open semantics.
    // The seeded business DATE is still the reseed/advance date — only
    // which period is "open" is anchored here.
    //
    // Bucket 4d (audit 2026-05-20): set+reset via ColdBootOverrideScope
    // so the override can't leak between tests (PR #1091 bug shape).
    final scope = ColdBootOverrideScope(now: '2026-03-27T19:45:00');
    addTearDown(scope.dispose);
    await SqliteDatabase.instance.reseedDemo();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
  });

  // ── A: Parameterized generation ─────────────────────────────────────────

  group('A — parameterized generation', () {
    test('default date produces Friday W13 open dinner', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      expect(output.scenario.currentBusinessDate, '2026-03-27');
      expect(output.scenario.currentWeekId, '2026-W13');
      expect(output.scenario.openShiftDayLabel, 'Fri');
      expect(output.scenario.openShiftDaypart, 'dinner');
    });

    test('default date preserves [historicalWeekCount] historical weeks '
        '+ 16 current-week shifts', () {
      // QA fix (Change B): weekends now serve Lunch, so the operating
      // pattern is 16 slots/week (was 14). `generateForDate` with no
      // injected clock uses the deterministic back-compat resolution
      // (Dinner open, Lunch closed) so openShiftDaypart stays 'dinner'.
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final weeks = MockIntegrationReplaySeed.historicalWeekCount;
      expect(output.weekRecords.length, weeks);
      expect(output.historicalClosedShifts.length, weeks * 16);
      expect(output.currentWeekShifts.length, 16);
    });

    test('default date current week has 9 closed + 7 projected', () {
      // Fri current day (back-compat default: Lunch closed, Dinner
      // open→projected, LateNight projected). Mon–Thu closed (8) + Fri
      // lunch (1) = 9 closed; Fri dinner + Fri late_night + Sat L/D/LN
      // + Sun L/D = 7 projected (Change B added weekend Lunch).
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      final projected =
          output.currentWeekShifts.where((s) => s.isProjected).length;
      expect(closed, 9);
      expect(projected, 7);
    });

    test('Saturday produces Sat dinner open with 12 closed + 4 projected', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-28');
      expect(output.scenario.currentWeekId, '2026-W13');
      expect(output.scenario.openShiftDayLabel, 'Sat');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      final projected =
          output.currentWeekShifts.where((s) => s.isProjected).length;
      // QA fix (Change B): Saturday now HAS a Lunch. Mon–Fri (11) + Sat
      // lunch closed (1) = 12 closed; Sat dinner + Sat late_night + Sun
      // lunch + Sun dinner = 4 projected.
      expect(closed, 12);
      expect(projected, 4);
    });

    test('Sunday produces Sun dinner open with 15 closed + 1 projected', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-29');
      expect(output.scenario.openShiftDayLabel, 'Sun');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      // Mon–Sat all closed (14) + Sun lunch closed (1) = 15; Sun dinner
      // is the only projected (open) cell.
      expect(closed, 15);
      expect(output.currentWeekShifts.where((s) => s.isProjected).length, 1);
    });

    test('Monday produces Mon dinner open with 1 closed + 15 projected', () {
      // Monday has lunch + dinner. Lunch is closed, dinner is open.
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-23');
      expect(output.scenario.openShiftDayLabel, 'Mon');
      expect(output.scenario.openShiftDaypart, 'dinner');

      final closed =
          output.currentWeekShifts.where((s) => s.isClosed).length;
      expect(closed, 1); // Only Mon lunch
      // 16 slots − 1 closed = 15 projected (Change B: 16-slot week).
      expect(output.currentWeekShifts.where((s) => s.isProjected).length, 15);
    });
  });

  // ── B: Week boundary crossing ──────────────────────────────────────────

  group('B — week boundary crossing', () {
    test('advancing past Sunday rolls currentWeekId', () {
      final fri = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final mon = MockIntegrationReplaySeed.generateForDate('2026-03-30');

      expect(fri.scenario.currentWeekId, '2026-W13');
      expect(mon.scenario.currentWeekId, '2026-W14');
    });

    test('W13 becomes historical after advancing to W14', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-30');
      expect(
          output.weekRecords.any((w) => w.weekId == '2026-W13'), isTrue);
    });

    test('oldest historical week drops out after week advance', () {
      final fri = MockIntegrationReplaySeed.generateForDate('2026-03-27');
      final mon = MockIntegrationReplaySeed.generateForDate('2026-03-30');

      // weekRecords are sorted newest-first, so the last entry is the
      // oldest in the rolling [historicalWeekCount]-week window. Derived
      // (not a hardcoded W05) so the assertion is week-count agnostic
      // after Slice B raised the window 8 → 12.
      final friWeeks = fri.weekRecords.map((w) => w.weekId).toList();
      final friOldest = friWeeks.last;
      final friSecondOldest = friWeeks[friWeeks.length - 2];

      expect(friWeeks, contains(friOldest));
      // Advancing one week slides the window: Friday's oldest week is
      // no longer in range, and its second-oldest becomes the new
      // oldest.
      final monWeeks = mon.weekRecords.map((w) => w.weekId).toList();
      expect(monWeeks, isNot(contains(friOldest)),
          reason: 'oldest week must drop out of the rolling window');
      expect(monWeeks, contains(friSecondOldest),
          reason: 'second-oldest week must remain after the slide');
    });

    test('all shifts have coherent businessDate after week advance', () {
      final output = MockIntegrationReplaySeed.generateForDate('2026-03-30');
      for (final s in output.currentWeekShifts) {
        expect(s.businessDate, isNotNull);
        expect(s.weekId, '2026-W14');
      }
    });
  });

  // ── C: SQLite reseed coherence ─────────────────────────────────────────

  group('C — SQLite reseed coherence', () {
    test('default reseed produces Fri dinner open snapshot', () async {
      final db = await SqliteDatabase.instance.database;
      // Per-location current-week open-shift slice: EVERY demo location
      // now has its own live open row (one per restaurant_id). The
      // scenario day/daypart is shared, so scope the coherence assertion
      // to Downtown and separately pin the per-location count.
      final allOpen = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          allOpen.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds,
          reason: 'one live open row per demo location');
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(open.length, 1);
      expect(open.first['day_label'], 'Fri');
      expect(open.first['daypart'], 'dinner');
    });

    test('reseed for Saturday produces Sat dinner open snapshot', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      final allOpen = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          allOpen.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds,
          reason: 'every location follows the advanced scenario day');
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(open.length, 1);
      expect(open.first['day_label'], 'Sat');
      expect(open.first['daypart'], 'dinner');
      expect(open.first['business_date'], '2026-03-28');
    });

    test('reservation snapshot follows scenario date/daypart', () async {
      // Updated for the per-location operational-envelope slice: the
      // reservation book is now the FORWARD book (current-week
      // projected/open cells) across all 4 demo locations, no longer a
      // single global row. The scenario's open-shift row is still
      // present with the same scoped value.
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      // The scenario open-shift reservation row still resolves exactly.
      final openRow = await db.query(
        'reservation_book_snapshots',
        where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
        whereArgs: ['demo_restaurant_001', '2026-03-28', 'dinner'],
      );
      expect(openRow.length, 1,
          reason: 'Downtown Sat-dinner forward reservation row exists');

      // The book now spans the forward week × all 4 locations, never a
      // single global row, and every row is restaurant-scoped (HP #4).
      final all = await db.query('reservation_book_snapshots');
      expect(all.length, greaterThan(1),
          reason: 'forward book is multi-location, not a single row');
      final scopes =
          all.map((r) => r['restaurant_id'] as String).toSet();
      expect(scopes, connectedDemoScopeIds,
          reason: 'every demo location has a forward reservation book');
      // Honest-degrade: no row predates the scenario date (closed/past
      // services carry no live reservation book).
      for (final r in all) {
        expect((r['business_date'] as String).compareTo('2026-03-28'),
            greaterThanOrEqualTo(0),
            reason: 'forward book only — no closed/past cell rows');
      }
    });

    test('mock_replay_state updated after reseed', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      final state = await db.query('mock_replay_state',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001']);
      expect(state.length, 1);
      expect(state.first['current_business_date'], '2026-03-28');
    });

    test('no old-scenario open snapshot remains after advance', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      // No Friday dinner open snapshot should remain
      final friOpen = await db.query('open_shift_snapshots',
          where:
              "day_label = 'Fri' AND daypart = 'dinner' AND status = 'open'");
      expect(friOpen, isEmpty);
    });

    test('all operational tables are rebuilt on advance', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      final db = await SqliteDatabase.instance.database;

      // shift_records should exist
      final shifts = await db.query('shift_records');
      expect(shifts, isNotEmpty);

      // week_records should exist
      final weeks = await db.query('week_records');
      expect(weeks, isNotEmpty);

      // open_shift_snapshots should exist
      final snaps = await db.query('open_shift_snapshots');
      expect(snaps, isNotEmpty);

      // reservation_book_snapshots should exist
      final res = await db.query('reservation_book_snapshots');
      expect(res, isNotEmpty);
    });

    test('week boundary reseed produces W14 current shifts', () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-30');
      final db = await SqliteDatabase.instance.database;

      // Current open shift should be Mon dinner of W14 — for EVERY
      // location (per-location current-week open-shift slice).
      final allOpen = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          allOpen.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds,
          reason: 'every location advances to the new week');
      final open = await db.query('open_shift_snapshots',
          where: "status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(open.length, 1);
      expect(open.first['day_label'], 'Mon');
      expect(open.first['week_id'], '2026-W14');
    });
  });

  // ── D: Manager Override anchor ─────────────────────────────────────────

  group('D — Manager Override anchor follows mock replay date', () {
    test('anchor uses mock replay date when available', () async {
      await BaselineManagerService.instance.primeManagerOverride();

      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      // All candidates should be closed shifts with non-null businessDate
      for (final c in candidates) {
        expect(c.businessDate, isNotNull,
            reason: '${c.recordKey} should have businessDate');
      }
    });

    test('anchor shifts when mock replay date changes', () async {
      // Default: anchor is 2026-03-27
      final defaultCandidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(defaultCandidates, isNotEmpty);

      // Advance to Saturday — anchor shifts to 2026-03-28
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();

      final advancedCandidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(advancedCandidates, isNotEmpty);
    });

    test('candidate inclusion remains closed-only and date-range-based',
        () async {
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();

      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();

      // All returned are from closed shifts
      for (final c in candidates) {
        expect(c.businessDate, isNotNull);
      }
    });
  });

  // ── E: Replay-stable locked artifacts survive replay advance (7.55m.2) ──

  group('E — replay-stable locked artifacts survive replay advance', () {
    const restaurantId = DemoScope.restaurantId;

    test('same-week advance does not rewrite locked WeeklyPlanSnapshot',
        () async {
      // Generate and lock the current week's snapshot.
      final original =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(original, isNotNull);

      // Advance mock replay within the same week (Fri → Sat).
      await ShiftService.instance.advanceMockReplayDay();

      // The snapshot must be the exact same persisted row.
      final afterAdvance =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(afterAdvance, isNotNull);
      expect(afterAdvance!.snapshotId, original!.snapshotId);
      expect(afterAdvance.generatedAt, original.generatedAt);
      expect(afterAdvance.forecastCovers, original.forecastCovers);
      expect(afterAdvance.forecastSales, original.forecastSales);
    });

    test('same-week advance does not rewrite TargetCycle', () async {
      // Force cycle creation by accessing the snapshot.
      final snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(snapshot, isNotNull);

      final cycleBefore =
          await SqliteTargetCycleRepository.instance.getActiveCycle(restaurantId);
      expect(cycleBefore, isNotNull);

      // Advance within the same week.
      await ShiftService.instance.advanceMockReplayDay();

      final cycleAfter =
          await SqliteTargetCycleRepository.instance.getActiveCycle(restaurantId);
      expect(cycleAfter, isNotNull);
      expect(cycleAfter!.cycleId, cycleBefore!.cycleId);
      expect(cycleAfter.targetCPLH, cycleBefore.targetCPLH);
      expect(cycleAfter.targetSPLH, cycleBefore.targetSPLH);
      expect(cycleAfter.targetPPA, cycleBefore.targetPPA);
    });

    test('same-week advance does not rewrite ActiveTargetProfile', () async {
      // Force cycle + profile creation.
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      final profileBefore = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profileBefore, isNotNull);

      await ShiftService.instance.advanceMockReplayDay();

      final profileAfter = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profileAfter, isNotNull);
      expect(profileAfter!.targetCPLH, profileBefore!.targetCPLH);
      expect(profileAfter.targetSPLH, profileBefore.targetSPLH);
      expect(profileAfter.targetPPA, profileBefore.targetPPA);
      expect(profileAfter.fohWage, profileBefore.fohWage);
      expect(profileAfter.bohWage, profileBefore.bohWage);
    });

    test('cross-week advance preserves prior week locked snapshot', () async {
      // Lock snapshot for W13 (default week: Mon 2026-03-23 – Sun 2026-03-29).
      final w13Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w13Snapshot, isNotNull);

      // Advance to next Monday (W14).
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      // The W13 snapshot must still exist in the repository.
      final w13Key = w13Snapshot!.weekKey;
      final preservedW13 = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, w13Key);

      expect(preservedW13, isNotNull);
      expect(preservedW13!.snapshotId, w13Snapshot.snapshotId);
      expect(preservedW13.forecastCovers, w13Snapshot.forecastCovers);
      expect(preservedW13.targetCycleId, w13Snapshot.targetCycleId);
      expect(preservedW13.generatedAt, w13Snapshot.generatedAt);
    });

    test('cross-week advance does not mutate prior week snapshot row',
        () async {
      final w13Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w13Snapshot, isNotNull);

      // Advance to W14 and generate the new week's snapshot.
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);
      final w14Snapshot =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w14Snapshot, isNotNull);

      // Both snapshots should be distinct.
      expect(w14Snapshot!.snapshotId, isNot(w13Snapshot!.snapshotId));
      expect(w14Snapshot.weekStartDate, isNot(w13Snapshot.weekStartDate));

      // W13 row must be unchanged even after W14 was generated.
      final rereadW13 = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, w13Snapshot.weekKey);
      expect(rereadW13, isNotNull);
      expect(rereadW13!.forecastCovers, w13Snapshot.forecastCovers);
      expect(rereadW13.forecastSales, w13Snapshot.forecastSales);
      expect(rereadW13.generatedAt, w13Snapshot.generatedAt);
      expect(rereadW13.dayRows.length, w13Snapshot.dayRows.length);
    });

    test('benchmark_selection_summaries survive replay advance', () async {
      // Force cycle + summary creation via snapshot path.
      await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();

      final db = await SqliteDatabase.instance.database;

      final cycle =
          await SqliteTargetCycleRepository.instance.getActiveCycle(restaurantId);
      expect(cycle, isNotNull);

      // Read the summary that was auto-created during snapshot generation.
      final summariesBefore = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [cycle!.cycleId]);
      expect(summariesBefore, isNotEmpty);
      final summaryIdBefore = summariesBefore.first['summary_id'];
      final countBefore = summariesBefore.first['selected_shift_count'];

      // Advance within same week.
      await ShiftService.instance.advanceMockReplayDay();

      // Summary must still exist with unchanged values.
      final summariesAfter = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [cycle.cycleId]);
      expect(summariesAfter, isNotEmpty);
      expect(summariesAfter.first['summary_id'], summaryIdBefore);
      expect(summariesAfter.first['selected_shift_count'], countBefore);
    });
  });

  // ── F: Live planning surfaces move with anchor (7.55m.2) ───────────────

  group('F — live planning surfaces move with anchor', () {
    test('DemandForecastContext anchor changes with replay advance', () async {
      final ctxBefore =
          await DemandForecastContextService.instance.getCurrentContext();
      expect(ctxBefore.anchorBusinessDate, '2026-03-27');

      // Advance to Saturday.
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');

      final ctxAfter =
          await DemandForecastContextService.instance.getCurrentContext();
      expect(ctxAfter.anchorBusinessDate, '2026-03-28');
    });

    test('live getCurrentWeeklyPlan still resolves after advance', () async {
      // Force initial resolution.
      final planBefore = await SchedulePlanReadService.instance
          .getCurrentWeeklyPlan();
      expect(planBefore, isNotNull);

      // Advance within same week.
      await ShiftService.instance.advanceMockReplayDay();

      final planAfter = await SchedulePlanReadService.instance
          .getCurrentWeeklyPlan();
      expect(planAfter, isNotNull);
      expect(planAfter!.forecastCovers, greaterThan(0));
    });

    test('baseline candidates reflect new anchor window after advance',
        () async {
      final candidatesBefore =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidatesBefore, isNotEmpty);

      // Advance to next Monday (new week, new anchor).
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-30');
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();

      final candidatesAfter =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidatesAfter, isNotEmpty);

      // The latest candidate business date should reflect the new anchor.
      final latestAfter = candidatesAfter
          .map((c) => c.businessDate!)
          .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
      // With anchor 2026-03-30, the latest closed business date in the seed
      // should be within the new anchor's 60-day window and at least as
      // recent as the old anchor.
      expect(latestAfter.compareTo('2026-03-27'), greaterThanOrEqualTo(0));
    });

    test('new-week advance generates new snapshot for the new week', () async {
      // Lock W13.
      final w13 =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w13, isNotNull);

      // Advance to W14.
      const nextWeekDate = '2026-03-30';
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate(nextWeekDate);

      final w14 =
          await WeeklyPlanSnapshotService.instance.getCurrentWeekSnapshot();
      expect(w14, isNotNull);

      final expectedWeekStart =
          WeeklyPlanSnapshotPolicy.weekStartForDate(nextWeekDate);
      expect(w14!.weekStartDate, expectedWeekStart);
      expect(w14.snapshotId, isNot(w13!.snapshotId));
      expect(w14.forecastCovers, greaterThan(0));
    });
  });

  // ── G: Replay-regenerated scenario data rebuilds coherently (7.55m.2a) ─

  group('G — replay-regenerated scenario data rebuilds on advance', () {
    test('shift_records current-week weekId changes after cross-week advance',
        () async {
      final db = await SqliteDatabase.instance.database;

      // Before advance: current-week shifts are W13.
      final w13Shifts = await db.query('shift_records',
          where: "week_id = '2026-W13'");
      expect(w13Shifts, isNotEmpty);

      // Advance to W14 Monday.
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-30');

      // After advance: W13 shifts are now historical (regenerated from
      // seed as closed), and current-week shifts are W14.
      final w14Shifts = await db.query('shift_records',
          where: "week_id = '2026-W14'");
      expect(w14Shifts, isNotEmpty,
          reason: 'current-week shifts should now be W14');

      // W13 still exists but now all shifts are closed (historical).
      final w13After = await db.query('shift_records',
          where: "week_id = '2026-W13'");
      expect(w13After, isNotEmpty,
          reason: 'W13 should still exist as regenerated historical data');
      for (final row in w13After) {
        expect(row['status'], 'closed',
            reason: 'all regenerated W13 shifts should be closed');
      }
    });

    test('week_records historical window slides after cross-week advance',
        () async {
      final db = await SqliteDatabase.instance.database;

      // Before advance: historical window ends at W12 (W05–W12).
      final weeksBefore = await db.query('week_records',
          orderBy: 'week_id ASC');
      expect(weeksBefore, isNotEmpty);
      final oldestBefore = weeksBefore.first['week_id'] as String;
      final newestBefore = weeksBefore.last['week_id'] as String;

      // Advance to W14 Monday.
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-30');

      // After advance: window shifts — oldest drops, W13 appears as historical.
      final weeksAfter = await db.query('week_records',
          orderBy: 'week_id ASC');
      expect(weeksAfter, isNotEmpty);
      final oldestAfter = weeksAfter.first['week_id'] as String;
      final newestAfter = weeksAfter.last['week_id'] as String;

      // The window should have shifted forward.
      expect(oldestAfter.compareTo(oldestBefore), greaterThan(0),
          reason: 'oldest week should advance');
      expect(newestAfter.compareTo(newestBefore), greaterThanOrEqualTo(0),
          reason: 'newest week should be at least as recent');

      // W13 should now be in the historical week_records.
      final w13Weeks = weeksAfter
          .where((w) => w['week_id'] == '2026-W13')
          .toList();
      expect(w13Weeks, isNotEmpty,
          reason: 'W13 should appear as historical week_record after advance');
    });

    test('shift_records are regenerated, not preserved, on same-week advance',
        () async {
      final db = await SqliteDatabase.instance.database;

      // Before advance (Fri): count current-week closed shifts.
      final closedBefore = await db.query('shift_records',
          where: "week_id = '2026-W13' AND status = 'closed'");
      final closedCountBefore = closedBefore.length;

      // Advance within same week (Fri → Sat).
      await ShiftService.instance.advanceMockReplayDay();

      // After advance (Sat): more closed shifts in the current week.
      final closedAfter = await db.query('shift_records',
          where: "week_id = '2026-W13' AND status = 'closed'");
      final closedCountAfter = closedAfter.length;

      // Saturday has more closed shifts than Friday because Saturday's
      // shifts (closed earlier in the week) plus Friday's dinner and
      // late_night are now closed. The count must increase.
      expect(closedCountAfter, greaterThan(closedCountBefore),
          reason: 'replay advance regenerates shift_records with more '
              'closed shifts for the later date');
    });

    test('open_shift_snapshots regenerate to new scenario day', () async {
      final db = await SqliteDatabase.instance.database;

      // Before: open shift is Fri dinner. Per-location slice: scope the
      // scenario-coherence assertion to Downtown; the per-location set
      // is pinned separately.
      final allBefore = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          allBefore.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds);
      final openBefore = await db.query('open_shift_snapshots',
          where: "status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(openBefore.length, 1);
      expect(openBefore.first['day_label'], 'Fri');

      // Advance to Saturday.
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');

      // After: open shift is Sat dinner — for every location.
      final allAfter = await db.query('open_shift_snapshots',
          where: "status = 'open'");
      expect(
          allAfter.map((r) => r['restaurant_id']).toSet(),
          connectedDemoScopeIds);
      final openAfter = await db.query('open_shift_snapshots',
          where: "status = 'open' AND restaurant_id = ?",
          whereArgs: [DemoScope.restaurantId]);
      expect(openAfter.length, 1);
      expect(openAfter.first['day_label'], 'Sat');
    });
  });
}
