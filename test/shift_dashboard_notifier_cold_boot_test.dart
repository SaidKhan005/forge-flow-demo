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
      // Cold-boot seed established Friday's snapshot. Advance one day
      // (same week — Sat) and confirm the locked snapshot is NOT
      // re-generated for the in-force week. The seeder's same-week
      // no-op preserves the locked truth contract (7.55l.6b1).
      final db = await SqliteDatabase.instance.database;

      final beforeRows = await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [DemoScope.restaurantId],
      );
      expect(beforeRows.length, 1,
          reason: 'cold-boot seed must produce exactly one snapshot row.');
      final beforeGeneratedAt = beforeRows.first['generated_at'] as String;

      // Advance one day within the same week (Fri -> Sat).
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-03-28');

      final afterRows = await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [DemoScope.restaurantId],
      );
      expect(afterRows.length, 1,
          reason: 'same-week advance must not insert a duplicate snapshot.');
      final afterGeneratedAt = afterRows.first['generated_at'] as String;
      expect(
        afterGeneratedAt,
        beforeGeneratedAt,
        reason: 'locked snapshot survives same-week advance unchanged.',
      );
    });
  });
}
