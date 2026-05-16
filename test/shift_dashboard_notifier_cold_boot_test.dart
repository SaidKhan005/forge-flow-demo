// FU-mobile-cold-boot-shift-stale-state regression test.
//
// Reproduces the Phase 2 walkthrough finding: after `adb shell pm clear`
// + relaunch, the Shift dashboard rendered "LOCKED PLAN UNAVAILABLE"
// even though the SQLite DB had all the inputs. Root cause: cold-boot
// `_onCreate` did not seed `weekly_plan_snapshots`. The ShiftDashboardNotifier
// constructor fired before any runtime auto-generator wrote one, so its
// first `_load()` cached `lockedPlanUnavailable = true`. Tapping
// "Move demo date forward" was the only way to break the stale state
// because that path (eventually) caused the runtime auto-generator to
// run and the invalidation bus to re-trigger the notifier.
//
// The fix seeds `weekly_plan_snapshots` synchronously during `_onCreate`
// (and during `reseedMockReplayForBusinessDate`) via
// `_seedWeeklyPlanSnapshotFromReplay`. This test exercises the cold-boot
// path WITHOUT the existing workaround (`getCurrentLockedWeeklyPlan()`)
// the other shift_dashboard_notifier_test uses, so the failure surfaces
// against master-as-of-now and passes after the fix.
//
// HP #2 compliance: this is a writer-side bootstrap fix. The notifier
// reader path is unchanged and does not branch on kDemoMode.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';

void main() {
  group('FU-mobile-cold-boot-shift-stale-state', () {
    setUp(() async {
      // Force a fully fresh cold-boot path: close any open db handle,
      // wipe any prior demo state by running reseedDemo (which clears
      // weekly_plan_snapshots), then exercise the exact runtime
      // sequence — no manual auto-generator call.
      await SqliteDatabase.instance.reseedDemo();
    });

    test(
        'cold-boot ShiftDashboardNotifier renders the locked plan without '
        'a runtime auto-generate workaround',
        () async {
      // Construct the notifier the same way the runtime Provider tree
      // does. No call to SchedulePlanReadService.getCurrentLockedWeeklyPlan()
      // — that's the workaround the existing test file relies on, and
      // exactly the seam the cold-boot bootstrap must close.
      final notifier = ShiftDashboardNotifier();

      // Allow _load() to complete (matches the timing the existing
      // shift_dashboard_notifier_test uses).
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Empty-state must be false: a snapshot was seeded during _onCreate /
      // reseedDemo's downstream reseed path, so getExistingCurrentLockedWeeklyPlan
      // returns a non-null SchedulePlan with the matching day row.
      expect(
        notifier.lockedPlanUnavailable,
        isFalse,
        reason: 'cold-boot must produce a populated dashboard — the '
            'weekly_plan_snapshots row must exist before the notifier '
            'first reads it.',
      );
      expect(
        notifier.readModel,
        isNotNull,
        reason: 'cold-boot dashboard must build a real ShiftDashboardReadModel '
            'from the seeded locked plan.',
      );

      // Forecast values must be > 0 and match the seeded scenario shape:
      // forecastCovers > 0 confirms the day row was found and the
      // projector wired Plan-owned forecast through.
      expect(
        notifier.readModel!.forecastCovers,
        greaterThan(0),
        reason: 'seeded snapshot must carry forecastCovers > 0 for the '
            'open shift day (Friday in the default scenario).',
      );
      expect(
        notifier.readModel!.forecastSales,
        greaterThan(0),
        reason: 'seeded snapshot must carry forecastSales > 0.',
      );

      notifier.dispose();
    });

    test(
        'cold-boot snapshot survives the same-week replay-advance contract',
        () async {
      // Cold-boot seed established Friday's IN-FORCE snapshot. Advance
      // one day (same week — Sat) and confirm the locked in-force
      // snapshot is NOT re-generated. The seeder's same-week no-op
      // preserves the locked truth contract (7.55l.6b1).
      //
      // Updated for the per-location operational-envelope slice: the
      // demo now also seeds a locked plan for every HISTORICAL week
      // (gap 3), so Downtown has a deep snapshot history rather than a
      // single row. This test's real contract is the IN-FORCE
      // snapshot's same-week immutability, so it now asserts that
      // specifically (by week_key) instead of a global row count.
      final db = await SqliteDatabase.instance.database;
      final inForceWeekKey =
          WeeklyPlanSnapshotPolicy.weekKeyForDate('2026-03-27');

      final beforeInForce = await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ? AND week_key = ?',
        whereArgs: [DemoScope.restaurantId, inForceWeekKey],
      );
      expect(beforeInForce.length, 1,
          reason: 'exactly one in-force snapshot for the week-in-force.');
      final beforeGeneratedAt =
          beforeInForce.first['generated_at'] as String;
      final beforeTotal = (await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [DemoScope.restaurantId],
      ))
          .length;
      expect(beforeTotal, greaterThan(1),
          reason: 'historical weekly plans are seeded (gap 3).');

      // Advance one day within the same week (Fri -> Sat).
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');

      final afterInForce = await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ? AND week_key = ?',
        whereArgs: [DemoScope.restaurantId, inForceWeekKey],
      );
      expect(afterInForce.length, 1,
          reason: 'same-week advance must not insert a duplicate '
              'in-force snapshot.');
      expect(
        afterInForce.first['generated_at'] as String,
        beforeGeneratedAt,
        reason: 'locked in-force snapshot survives same-week advance '
            'unchanged.',
      );
      final afterTotal = (await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [DemoScope.restaurantId],
      ))
          .length;
      expect(afterTotal, beforeTotal,
          reason: 'same-week advance rewrites no locked snapshot '
              '(historical truth preserved, Promise 2).');
    });
  });
}
