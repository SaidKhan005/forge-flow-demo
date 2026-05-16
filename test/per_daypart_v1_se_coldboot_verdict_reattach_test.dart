// Per-Daypart Targets V1 — follow-up SE regression test.
//
// Authority: this slice's prompt (SE — Benchmark per-period verdict chip
// blank on the very first cold boot after a fresh install); CLAUDE.md
// HP #2 (writer-side switch, no kDemoMode reader branch, no demo_*
// table), Metric Honesty Doctrine (a per-period verdict that exists on
// the locked cycle must not silently vanish on the read path).
//
// Operator-reproduced defect this guards: on the very first cold boot
// after a fresh install, the Benchmark per-period verdict CHIP rendered
// blank (it fell back to the whole-day badge) and only self-healed after
// a normal cycle refresh.
//
// Verified root cause: the cold-boot READ path
// `WageStandardContextService._reattachCycleDayparts` rebuilt
// `ActiveTargetProfileDaypart` from `cycle.dayparts` but OMITTED
// `verdict` / `verdictReason`, so `profile.daypartFor(period).verdict`
// was null on cold boot even though the seeded `target_cycle_dayparts`
// rows carry a verdict (and the refresh path
// `TargetCycleService._syncActiveTargetProfile` already mapped them).
//
// This test cold-boots a fresh DB exactly the way
// `per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart`
// does, then asserts that for EVERY seeded service period on the active
// cycle the reattached profile row is non-null, its verdict is non-null,
// equals the corresponding `target_cycle_dayparts.verdict`, and is
// `BenchmarkVerdict.teachable` (post-SA.1 the default demo is teachable
// end-to-end).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/services/wage_standard_context_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('se_coldboot_verdict_');
  });

  tearDown(() async {
    SqliteDatabase.debugColdBootTodayOverride = null;
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // True cold boot: a fresh DB file path means `openDatabase` runs
  // `_onCreate` (version 0 -> schemaVersion), which runs the
  // today-anchored demo seed end-to-end — the exact first-install path.
  Future<void> coldBoot(String injectedToday) async {
    SqliteDatabase.debugColdBootTodayOverride = injectedToday;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cold_$injectedToday.db'),
    );
    await SqliteDatabase.instance.database; // first access -> _onCreate
  }

  test(
      'cold boot (first install) — every seeded service period verdict '
      'survives the profile reattach (not blank, matches the cycle)',
      () async {
    // Deterministic "today"; matching the sibling test's far-from-default
    // anchor so the cold-boot seed is unambiguous regardless of wall
    // clock.
    const injectedToday = '2026-09-04';

    await coldBoot(injectedToday);

    // The active cycle is the source of truth for the locked per-period
    // verdicts (the `target_cycle_dayparts` child rows the seed wrote).
    final cycle = await TargetCycleService.instance
        .getOrCreateActiveCycle(DemoScope.restaurantId, injectedToday);
    expect(cycle.dayparts, isNotEmpty,
        reason: 'cold-boot demo seed must lock per-period rows on the '
            'active cycle (else there is nothing for the chip to read)');

    // The exact read seam the Benchmark per-period chip consumes.
    final profile = await WageStandardContextService.instance
        .loadOrBootstrapProfile(DemoScope.restaurantId);

    for (final cd in cycle.dayparts) {
      final periodId = cd.servicePeriodId;

      // The cycle row itself carries a verdict (seed invariant — proves
      // the test is asserting against a real signal, not vacuously).
      expect(cd.verdict, isNotNull,
          reason: '$periodId: seeded target_cycle_dayparts row must '
              'carry a verdict');

      final pd = profile.daypartFor(periodId);
      expect(pd, isNotNull,
          reason: '$periodId: profile.daypartFor must be non-null on '
              'cold boot (reattach must project the locked period row)');

      // The SE fix: verdict must survive the cold-boot reattach, not
      // drop to null and force the whole-day badge fallback.
      expect(pd!.verdict, isNotNull,
          reason: '$periodId: per-period verdict must be non-null on '
              'cold boot (SE: reattach must carry verdict through)');
      expect(pd.verdict, cd.verdict,
          reason: '$periodId: reattached verdict must equal the locked '
              'cycle verdict (pure passthrough, no mutation)');
      expect(pd.verdict, BenchmarkVerdict.teachable,
          reason: '$periodId: the default demo is teachable end-to-end '
              'post-SA.1 — the chip must read teachable on first boot');

      // verdictReason is the companion field reattached by the same
      // 2-line fix; assert it likewise survives (matches the cycle).
      expect(pd.verdictReason, cd.verdictReason,
          reason: '$periodId: reattached verdictReason must equal the '
              'locked cycle verdictReason (pure passthrough)');
    }
  });
}
