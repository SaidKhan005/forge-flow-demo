// Shift per-daypart targets/benchmarks — root-cause regression test.
//
// Authority: docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md;
//            CLAUDE.md Promise/Layer 9 + Metric Honesty Doctrine.
//
// The bug this guards: `WageStandardContextService.loadOrBootstrapProfile`
// (the seam the Shift daypart lens reads via
// `ShiftServicePeriodNotifier._safeLoadActiveTargetProfile`) returned a
// profile whose `dayparts` list was empty — it called the bare
// `TargetCycleActiveTargetProfileProjector.project(cycle)` (projection
// only, drops per-period rows) and, on the cache-hit branch, returned the
// persisted flat profile (`ActiveTargetProfile.fromMap` does not rehydrate
// per-period rows). So `profile.daypartFor(period)` was null for every
// period → `DaypartTargetContext` was `none` → the Shift daypart tiles
// showed no per-daypart target/benchmark and the daypart breakdown fell
// back to the pooled "whole-day est." stand-in.
//
// After the fix `loadOrBootstrapProfile` reattaches the active cycle's
// locked per-period rows (mirroring `TargetCycleService.
// _syncActiveTargetProfile`) on BOTH the projected and the cache-hit
// branch, so the seeded demo's differentiated lunch/dinner/late_night
// targets reach the Shift daypart lens. This file fails if the seam
// regresses to one pooled number.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/wage_standard_context_service.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  group('loadOrBootstrapProfile — per-daypart passthrough', () {
    test(
        'returned profile carries differentiated per-period rows for the '
        'seeded demo (daypartFor non-null + not one pooled number)',
        () async {
      final profile = await WageStandardContextService.instance
          .loadOrBootstrapProfile(DemoScope.restaurantId);

      final lunch = profile.daypartFor('lunch');
      final dinner = profile.daypartFor('dinner');
      final lateNight = profile.daypartFor('late_night');

      expect(lunch, isNotNull,
          reason: 'demo seed writes a lunch per-period row; the Shift '
              'daypart lens must read it, not the Gap-42 pool');
      expect(dinner, isNotNull);
      expect(lateNight, isNotNull);

      // The whole point of per-daypart: every period is visibly
      // different — never one pooled "whole-day est." number.
      expect(
        lunch!.daypartTargetCPLH,
        isNot(equals(dinner!.daypartTargetCPLH)),
      );
      expect(
        dinner.daypartTargetCPLH,
        isNot(equals(lateNight!.daypartTargetCPLH)),
      );
      expect(
        lunch.daypartTargetPPA,
        isNot(equals(dinner.daypartTargetPPA)),
      );
    });

    test(
        'second call (profile-cache-hit branch) still carries per-period '
        'rows — the cache-hit path is not daypart-blind', () async {
      // First call may upsert the projected profile; the second call
      // exercises the `_matchesCycleProjection` cache-hit branch that
      // previously returned the flat persisted profile with empty
      // dayparts.
      await WageStandardContextService.instance
          .loadOrBootstrapProfile(DemoScope.restaurantId);
      final profile = await WageStandardContextService.instance
          .loadOrBootstrapProfile(DemoScope.restaurantId);

      expect(profile.daypartFor('lunch'), isNotNull);
      expect(profile.daypartFor('dinner'), isNotNull);
      expect(
        profile.daypartFor('lunch')!.daypartTargetCPLH,
        isNot(equals(profile.daypartFor('dinner')!.daypartTargetCPLH)),
        reason: 'cache-hit branch must reattach the cycle per-period '
            'rows too (ActiveTargetProfile.fromMap drops them)',
      );
    });
  });
}
