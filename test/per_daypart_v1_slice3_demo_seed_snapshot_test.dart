// Per-Daypart Targets V1 — Slice 3 demo-seed regression test.
//
// Authority: docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
//            Slice 3 + Design Rule 4 (pool-consistency) + Design Rule 8
//            (wage-at-lock-time stamp); CLAUDE.md HP #2.
//
// The bug this guards: `_seedWeeklyPlanSnapshotFromReplay` built the
// demo locked `WeeklyPlanSnapshot` omitting `dayDayparts:` and
// `wageAtLockTime:`, so the demo-seeded snapshot was structurally a
// pre-Slice-1 "legacy" snapshot. `ScheduleForecastNotifier
// .adjustedDayViews` then saw `snapshot.dayDayparts.isEmpty == true`
// and silently fell back to the live `DaypartPlanAllocator` — Slice 3's
// persistence read-swap was dead in demo and the Gap-12 1:1 allocator
// trap was never actually closed for the shipped demo.
//
// After the fix the demo seed builds the per-(business_date,
// service_period) sub-rows + the wage stamp exactly the way the runtime
// lock path does, persists them to `weekly_plan_snapshot_day_dayparts`
// + `wage_at_lock_time_json`, and the Plan-tab reader consumes the
// locked rows (NOT the allocator) in demo.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/screens/schedule/schedule_forecast_notifier.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = demoRestaurantId;

  // Default seeded business date: 2026-03-27 (Friday).
  // Monday-start week: 2026-03-23 to 2026-03-29.
  const businessDate = '2026-03-27';
  final weekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(businessDate);
  final weekEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(businessDate);
  final weekKey =
      WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

  // Bootstrap profile for the locked-authority notifier. Per-period
  // sub-rows are read from the injected snapshot, not this profile, so
  // its scalar fields are immaterial to the reader-swap proof.
  ActiveTargetProfile makeProfile() => const ActiveTargetProfile(
        targetProfileId: 's3-demo-test',
        restaurantId: restaurantId,
        sourceType: 'system_baseline',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        fohWage: 16.5,
        bohWage: 21.35,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 5.8,
        theoreticalFohLaborPct: 8.7,
        theoreticalBohLaborPct: 11.9,
        theoreticalLaborPct: 20.6,
        builtAt: '',
      );

  setUp(setUpSqliteDemo);

  group('Slice 3 demo-seed — locked snapshot per-period + wage stamp', () {
    test(
        'demo-seeded snapshot carries non-empty dayDayparts AND a '
        'populated wageAtLockTime (no longer a pre-Slice-1 legacy '
        'snapshot)', () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);

      expect(snapshot, isNotNull,
          reason: 'demo seed must persist a locked snapshot for the '
              'in-force week');
      expect(snapshot!.dayDayparts, isNotEmpty,
          reason: 'demo seed must stamp per-(business_date, '
              'service_period) sub-rows so the Plan-tab read-swap is '
              'exercised in demo (Gap-12 / Gap-6)');
      expect(snapshot.wageAtLockTime, isNotNull,
          reason: 'Design Rule 8 — the locked-plan wage stamp must be '
              'populated at lock time');

      // Design Rule 8 — the stamp is the cycle-in-force wages, and the
      // blended wage is the canonical cover-independent formula (so it
      // can't drift from the runtime seam).
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(snapshot.wageAtLockTime!.fohWage, cycle!.fohWage);
      expect(snapshot.wageAtLockTime!.bohWage, cycle.bohWage);
      expect(
        snapshot.wageAtLockTime!.blendedWage,
        closeTo(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: cycle.targetCPLH,
            targetSPLH: cycle.targetSPLH,
            targetPPA: cycle.targetPPA,
            fohWage: cycle.fohWage,
            bohWage: cycle.bohWage,
          ),
          1e-9,
        ),
      );
    });

    test(
        'persisted sub-rows derive from the cycle per-period rows '
        '(differentiated, not one pooled number)', () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      final periodIds =
          snapshot!.dayDayparts.map((d) => d.servicePeriodId).toSet();
      expect(periodIds, {'lunch', 'dinner', 'late_night'},
          reason: 'one sub-row per configured service period');

      // The whole point of the per-daypart demo: the locked sub-rows
      // are visibly differentiated, not one repeated pooled figure.
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      final lunch = cycle!.daypartFor('lunch')!;
      final dinner = cycle.daypartFor('dinner')!;
      expect(lunch.targetCPLH, isNot(equals(dinner.targetCPLH)));

      // A day with non-zero demand must produce per-period FOH hours
      // that are not all identical (would only coincide if every period
      // shared CPLH + covers, which the differentiated cycle forbids).
      final byDay = <String, List<double>>{};
      for (final d in snapshot.dayDayparts) {
        (byDay[d.businessDate] ??= <double>[]).add(d.requiredFohHours);
      }
      final aBusyDay = byDay.entries.firstWhere(
        (e) => e.value.any((h) => h > 0),
        orElse: () => byDay.entries.first,
      );
      expect(aBusyDay.value.toSet().length, greaterThan(1),
          reason: 'per-period locked hours must be differentiated');
    });

    test(
        'pool-consistency (Design Rule 4): cycle whole-day scalars == '
        'cover-weighted Σ of per-period rows; Σ(period covers) ≈ day '
        'forecast covers', () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      // Canonical pool path — exact (Design Rule 4 invariant the
      // Slice 6 audit check enforces).
      final pool = TargetCycleDaypartPool.fromDayparts(cycle!.dayparts);
      expect(cycle.targetCPLH, closeTo(pool.targetCPLH, 1e-9));
      expect(cycle.targetSPLH, closeTo(pool.targetSPLH, 1e-9));
      expect(cycle.targetPPA, closeTo(pool.targetPPA, 1e-9));

      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      // Per-day: Σ(period covers) reconciles to the day forecast covers
      // within plain-rounding tolerance (the runtime lock path uses the
      // same per-period round — no largest-remainder reconciliation, so
      // the seeded shape stays byte-equivalent to the live generator).
      final periodCount =
          snapshot!.dayDayparts.map((d) => d.servicePeriodId).toSet().length;
      for (final dr in snapshot.dayRows) {
        final sumCovers = snapshot.dayDayparts
            .where((d) => d.businessDate == dr.businessDate)
            .fold<int>(0, (a, d) => a + d.forecastCovers);
        expect(
          (sumCovers - dr.forecastCovers).abs(),
          lessThanOrEqualTo(periodCount),
          reason: 'Σ(period covers) must reconcile to the day pooled '
              'figure within per-period rounding',
        );
      }
    });

    test(
        'Plan-tab reader consumes the locked persisted sub-rows in demo '
        '(NOT the DaypartPlanAllocator fallback) — Gap-12 closed',
        () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);

      final notifier =
          ScheduleForecastNotifier.lockedAuthority(profile: makeProfile());
      notifier.setLockedSnapshotForTest(snapshot);

      // The exact gate `adjustedDayViews` branches on
      // (schedule_forecast_notifier.dart:519-520).
      expect(snapshot!.dayDayparts.isNotEmpty, isTrue,
          reason: 'the persisted-subrow branch is taken, not the '
              'allocator fallback');

      final businessDateByDay = <String, String>{
        for (final dr in snapshot.dayRows) dr.day: dr.businessDate,
      };

      for (final view in notifier.adjustedDayViews) {
        final bd = businessDateByDay[view.day];
        if (bd == null) continue;
        final persisted = snapshot.dayDayparts
            .where((d) => d.businessDate == bd)
            .toList();
        // Reader renders exactly one sub-row per persisted period row.
        expect(view.subrows.length, persisted.length,
            reason: 'rendered sub-rows must mirror the persisted rows '
                'for $bd, not a regenerated allocator split');
        // The rendered per-period covers/sales are the persisted set
        // (allocator output uses fixed 0.45/0.40/0.15 weights and would
        // not match the cover-weighted persisted values).
        final renderedCovers =
            view.subrows.map((s) => s.forecastCovers).toList()..sort();
        final persistedCovers =
            persisted.map((d) => d.forecastCovers).toList()..sort();
        expect(renderedCovers, persistedCovers,
            reason: 'Plan tab must read the lock-time-stamped persisted '
                'rows, not regenerate via the retired allocator');
      }

      notifier.dispose();
    });

    test(
        'determinism / HP #2: two reseeds yield byte-identical locked '
        'snapshot + child rows (no demo_* table, same tables)', () async {
      final first = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      final firstChildren = first!.dayDayparts
          .map((d) => d.toMap().toString())
          .toList()
        ..sort();
      final firstWage = first.wageAtLockTime!.toJson().toString();

      await SqliteDatabase.instance.reseedDemo();

      final second = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      final secondChildren = second!.dayDayparts
          .map((d) => d.toMap().toString())
          .toList()
        ..sort();
      final secondWage = second.wageAtLockTime!.toJson().toString();

      expect(second.snapshotId, first.snapshotId,
          reason: 'deterministic snapshot id across reseeds');
      expect(secondChildren, firstChildren,
          reason: 'per-period child rows are byte-identical across '
              'reseeds (no RNG; derived from the deterministic cycle)');
      expect(secondWage, firstWage,
          reason: 'wage stamp is deterministic across reseeds');
      expect(second.dayDayparts.length, first.dayDayparts.length);
    });
  });
}
