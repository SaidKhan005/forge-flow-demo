// Per-Daypart Targets V1 — demo-fidelity regression test.
//
// Authority: docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
//            (Slice 1 + Gap 42 + Decision 4); CLAUDE.md HP #2.
//
// The bug this guards: the demo seed used to build the demo TargetCycle
// with whole-day scalars only and persist it through a raw single-table
// `db.insert('target_cycles', ...)`, so `target_cycle_dayparts` stayed
// empty. Every per-period read then hit the Gap-42 whole-day fallback
// and the demo showed one identical number for lunch, dinner, and late
// night — defeating the entire point of a per-daypart demo.
//
// After the fix the demo seed writes differentiated per-period
// `TargetCycleDaypart` rows through Slice 1's canonical cycle write
// path (`TargetCycleDao.upsertCycle`, parent + child in one txn) and
// the parent whole-day scalars are the cover-weighted rollup of those
// rows (Design Rule 4). This file fails if the demo regresses to a
// single pooled number.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/services/target_cycle_active_target_profile_projector.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  setUp(setUpSqliteDemo);

  group('Per-Daypart V1 demo fidelity — demo seed per-period cycle rows', () {
    test(
        'demo active cycle carries differentiated lunch/dinner/late_night '
        'per-period rows persisted to target_cycle_dayparts', () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);

      expect(cycle, isNotNull,
          reason: 'demo seed must leave an active cycle for the demo '
              'restaurant');
      final dayparts = cycle!.dayparts;

      // Hydrated from the child table by TargetCycleDao — non-empty
      // proves `target_cycle_dayparts` was actually written (the raw
      // single-table insert never wrote it).
      expect(
        dayparts.map((d) => d.servicePeriodId).toSet(),
        {'lunch', 'dinner', 'late_night'},
        reason: 'demo seed must write one per-period row per configured '
            'service period through the canonical cycle write path',
      );

      final lunch = cycle.daypartFor('lunch')!;
      final dinner = cycle.daypartFor('dinner')!;
      final lateNight = cycle.daypartFor('late_night')!;

      // The whole point of the demo: every period is visibly different.
      expect(lunch.targetCPLH, isNot(equals(dinner.targetCPLH)));
      expect(dinner.targetCPLH, isNot(equals(lateNight.targetCPLH)));
      expect(lunch.targetCPLH, isNot(equals(lateNight.targetCPLH)));
      expect(lunch.targetSPLH, isNot(equals(dinner.targetSPLH)));
      expect(lunch.targetPPA, isNot(equals(dinner.targetPPA)));
      expect(lunch.opzFloorCPLH, isNot(equals(dinner.opzFloorCPLH)));
      expect(lunch.opzCeilingCPLH, isNot(equals(dinner.opzCeilingCPLH)));
    });

    test(
        'parent whole-day scalars are the cover-weighted rollup of the '
        'per-period rows (Design Rule 4 — no deprecated pooled accessor)',
        () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);
      final pool = TargetCycleDaypartPool.fromDayparts(cycle!.dayparts);

      expect(cycle.targetCPLH, closeTo(pool.targetCPLH, 1e-9));
      expect(cycle.targetSPLH, closeTo(pool.targetSPLH, 1e-9));
      expect(cycle.targetPPA, closeTo(pool.targetPPA, 1e-9));
      expect(cycle.opzFloorCPLH, closeTo(pool.opzFloorCPLH, 1e-9));
      expect(cycle.opzCeilingCPLH, closeTo(pool.opzCeilingCPLH, 1e-9));

      // A genuine rollup must differ from any single period's scalar
      // (would only coincide if every period were identical — which the
      // first test already proves they are not).
      final cplhValues =
          cycle.dayparts.map((d) => d.targetCPLH).toSet();
      expect(cplhValues.length, greaterThan(1));
    });

    test(
        'projected ActiveTargetProfile differentiates daypartFor() across '
        'service periods', () async {
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle(DemoScope.restaurantId);

      // Mirror the runtime read seam (TargetCycleService
      // ._syncActiveTargetProfile): project the cycle then reattach the
      // per-period rows. With an empty cycle.dayparts (the old bug) this
      // profile would have no daypart rows and daypartFor() would return
      // null for every period.
      final profile = TargetCycleActiveTargetProfileProjector.project(cycle!)
          .withDayparts(
        cycle.dayparts
            .map((d) => ActiveTargetProfileDaypart(
                  servicePeriodId: d.servicePeriodId,
                  daypartTargetCPLH: d.targetCPLH,
                  daypartTargetSPLH: d.targetSPLH,
                  daypartTargetPPA: d.targetPPA,
                  daypartOpzFloorCPLH: d.opzFloorCPLH,
                  daypartOpzCeilingCPLH: d.opzCeilingCPLH,
                ))
            .toList(),
      );

      final lunch = profile.daypartFor('lunch');
      final dinner = profile.daypartFor('dinner');
      final lateNight = profile.daypartFor('late_night');

      expect(lunch, isNotNull);
      expect(dinner, isNotNull);
      expect(lateNight, isNotNull);
      expect(
        lunch!.daypartTargetCPLH,
        isNot(equals(dinner!.daypartTargetCPLH)),
        reason: 'demo profile must surface a different CPLH per service '
            'period — not one pooled number',
      );
      expect(
        dinner.daypartTargetCPLH,
        isNot(equals(lateNight!.daypartTargetCPLH)),
      );
    });
  });
}
