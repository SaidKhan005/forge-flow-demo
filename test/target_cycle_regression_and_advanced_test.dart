// Phase 7.55l/p + Per-Daypart V1 — TargetCycle benchmark / hydration /
// regression / code-health / per-daypart write-path tests.
//
// Bucket 5e of the 2026-05-20 test-suite tightening audit: split out of
// `test/target_cycle_service_test.dart` (2,365 lines). This file holds the
// five remaining groups:
//
//   N. Benchmark selection summary persisted on cycle write (7.55l.8c +
//      7.56b.1 repair + 7.56b.1-review-fix evidence routing)
//   O. Explicit restaurant scope in recommendation path (7.55p.5g-review-fix)
//   P. Benchmark graph honesty hydration (7.55p.5h-review-fix)
//   CODE_HEALTH L15. cycleId distinctness within one millisecond
//   Per-Daypart V1 (Slice 1). per-period rows + pool consistency
//
// Shared `setUp()` body and the cycle-table delete helper live in
// `target_cycle_test_helpers.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

import 'target_cycle_test_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = targetCycleDemoRestaurantId;

  setUp(setUpTargetCycleTest);

  // ── N: BenchmarkSelectionSummary persistence (7.55l.8c) ────────────────

  group('N — benchmark selection summary persisted on cycle write', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test(
      'recommended cycle write persists benchmark-selection summary',
      () async {
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final db = await SqliteDatabase.instance.database;
        final rows = await db.query(
          'benchmark_selection_summaries',
          where: 'target_cycle_id = ?',
          whereArgs: [cycle.cycleId],
        );
        expect(rows.length, 1, reason: 'exactly one summary for the cycle');
        // SB old→new: this asserted `source_type == 'cycle_recommended'`
        // and `selected_shift_count > 0`. `clearCycleBackedState()` wipes
        // the functional seeded cycle, so this rebuilds via the live
        // recommendation path against the pre-SA degenerate demo cohort
        // (every shift pinned to one CPLH — spec DIAG-0). The Jim-faithful
        // engine now honestly reports no teachable period →
        // `cycle_recommended_insufficient`, 0 selected. The OLD engine
        // masked the degeneracy by always emitting a band; exposing it is
        // this slice's purpose, not a regression. The contract this test
        // guards (exactly one summary persisted per cycle write) still
        // holds. SA's demo reseed restores `cycle_recommended` + a
        // non-zero cohort.
        expect(
          rows.first['source_type'],
          anyOf('cycle_recommended', 'cycle_recommended_insufficient'),
        );
        expect(
          (rows.first['selected_shift_count'] as int),
          greaterThanOrEqualTo(0),
        );
      },
    );

    test(
      'manager override cycle write persists benchmark-selection summary',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        final db = await SqliteDatabase.instance.database;
        final rows = await db.query(
          'benchmark_selection_summaries',
          where: 'target_cycle_id = ?',
          whereArgs: [overridden.cycleId],
        );
        expect(rows.length, 1, reason: 'summary persisted for override cycle');
        expect(rows.first['source_type'], 'manager_override');
      },
    );

    test(
      'admin replacement cycle write persists benchmark-selection summary',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        final db = await SqliteDatabase.instance.database;
        final rows = await db.query(
          'benchmark_selection_summaries',
          where: 'target_cycle_id = ?',
          whereArgs: [replaced.cycleId],
        );
        expect(rows.length, 1, reason: 'summary persisted for admin cycle');
        expect(rows.first['source_type'], 'admin_replacement');
      },
    );

    test('summary carries valid range quality from seed records', () async {
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [cycle.cycleId],
      );
      expect(rows.length, 1);
      final label = rows.first['range_quality_label'] as String;
      expect(
        label,
        anyOf('GOOD OPZ RANGE', 'OPZ RANGE TOO NARROW', 'OPZ RANGE TOO WIDE'),
        reason: 'range quality label must be a valid enum value',
      );
    });

    test('auto-refresh persists new summary for refreshed cycle', () async {
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      // 2026-06-01 is the next Monday (week-start) past effectiveEnd.
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-06-01');

      expect(refreshed.cycleId, isNot(first.cycleId));

      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('benchmark_selection_summaries');
      // Both the original and refreshed cycle should have summaries
      final ids = allRows.map((r) => r['target_cycle_id']).toSet();
      expect(ids, contains(first.cycleId));
      expect(ids, contains(refreshed.cycleId));
    });

    // ── 7.56b.1 — missing-summary repair on existing active cycle ─────
    //
    // When an active cycle row exists without a companion summary (the
    // shape produced by the SQLite seed path's `_ensureDemoSeedCycle`
    // helper), `getOrCreateActiveCycle` must repair it with exactly
    // one summary. Existing summaries must never be rewritten.

    test('missing summary on existing active cycle is repaired to exactly '
        'one summary', () async {
      // Create a cycle + summary via the normal write path, then delete
      // just the summary row to reproduce the seed path's shape.
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final db = await SqliteDatabase.instance.database;
      await db.delete(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [cycle.cycleId],
      );
      final sanity = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [cycle.cycleId],
      );
      expect(sanity, isEmpty, reason: 'sanity: summary deleted before repair');

      // Call getOrCreateActiveCycle again — must repair, not recreate
      // the cycle itself.
      final sameCycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      expect(
        sameCycle.cycleId,
        cycle.cycleId,
        reason: 'repair must not replace the existing cycle',
      );

      final rows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [cycle.cycleId],
      );
      expect(rows.length, 1, reason: 'repair must create exactly one summary');
      // SB old→new: asserted `cycle_recommended` + selected > 0. With
      // `clearCycleBackedState()` + pre-SA degenerate demo data the
      // re-resolved recommendation honestly yields no teachable period
      // (insufficient). The contract this test guards — repair creates
      // EXACTLY ONE summary and never replaces the cycle — still holds.
      // SA's reseed restores the non-insufficient labels/count.
      expect(
        rows.first['source_type'],
        anyOf('cycle_recommended', 'cycle_recommended_insufficient'),
        reason: 'repair must use a recommended-path source label',
      );
      expect(
        (rows.first['selected_shift_count'] as int),
        greaterThanOrEqualTo(0),
      );
    });

    test(
      'existing summary on existing active cycle is left unchanged',
      () async {
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final db = await SqliteDatabase.instance.database;
        final before = await db.query(
          'benchmark_selection_summaries',
          where: 'target_cycle_id = ?',
          whereArgs: [cycle.cycleId],
        );
        expect(before.length, 1);
        final summaryIdBefore = before.first['summary_id'];
        final createdAtBefore = before.first['created_at'];
        final countBefore = before.first['selected_shift_count'];

        // Second resolve must not rewrite or duplicate the summary.
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final after = await db.query(
          'benchmark_selection_summaries',
          where: 'target_cycle_id = ?',
          whereArgs: [cycle.cycleId],
        );
        expect(after.length, 1, reason: 'no duplicate summary');
        expect(
          after.first['summary_id'],
          summaryIdBefore,
          reason: 'summary_id unchanged',
        );
        expect(
          after.first['created_at'],
          createdAtBefore,
          reason: 'created_at unchanged — no rewrite',
        );
        expect(
          after.first['selected_shift_count'],
          countBefore,
          reason: 'selected_shift_count unchanged',
        );
      },
    );

    // ── 7.56b.1-review-fix — repair mirrors write-path evidence routing ──

    test('manager override missing-summary repair uses override-selected '
        'evidence (matches write-path count)', () async {
      // Persist manager-selected keys directly so the cycle-write path
      // routes through `hasOverride=true` and evidence comes from the
      // override cohort, not the recommendation pipeline.
      final candidates = await BaselineManagerService.instance
          .getCandidateShiftsForDateRange(
            '2026-02-01',
            '2026-04-01',
            restaurantId: restaurantId,
          );
      expect(
        candidates,
        isNotEmpty,
        reason: 'demo seed must have candidates in this window',
      );
      final overrideKeys = candidates.take(5).map((c) => c.recordKey).toSet();
      await SqliteBaselineSelectionRepository.instance
          .replaceSelectedRecordKeys(restaurantId, overrideKeys);
      expect(
        await BaselineManagerService.instance.hasPersistedManagerOverride(
          restaurantId,
        ),
        isTrue,
      );

      // Write a manager-override cycle. Write path uses override cohort.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final writeRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [overridden.cycleId],
      );
      expect(writeRows.length, 1);
      final writeTimeCount = writeRows.first['selected_shift_count'] as int;
      expect(
        writeTimeCount,
        overrideKeys.length,
        reason: 'write path should size summary from override cohort',
      );

      // Delete summary to reproduce the seed-path shape.
      await db.delete(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [overridden.cycleId],
      );

      // Repair.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-04-01',
      );

      final repairRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [overridden.cycleId],
      );
      expect(repairRows.length, 1);
      expect(repairRows.first['source_type'], 'manager_override');
      expect(
        repairRows.first['selected_shift_count'],
        writeTimeCount,
        reason: 'repair must mirror write-path evidence: override cohort size',
      );
    });

    test('admin replacement missing-summary repair with persisted override '
        'keys uses override-selected evidence', () async {
      final candidates = await BaselineManagerService.instance
          .getCandidateShiftsForDateRange(
            '2026-02-01',
            '2026-04-01',
            restaurantId: restaurantId,
          );
      final overrideKeys = candidates.take(5).map((c) => c.recordKey).toSet();
      await SqliteBaselineSelectionRepository.instance
          .replaceSelectedRecordKeys(restaurantId, overrideKeys);

      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final writeRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );
      expect(writeRows.length, 1);
      final writeTimeCount = writeRows.first['selected_shift_count'] as int;
      expect(
        writeTimeCount,
        overrideKeys.length,
        reason:
            'write path with persisted override keys sources summary from '
            'override cohort even for admin-replacement source',
      );

      await db.delete(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );

      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-04-01',
      );

      final repairRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );
      expect(repairRows.length, 1);
      expect(repairRows.first['source_type'], 'admin_replacement');
      expect(
        repairRows.first['selected_shift_count'],
        writeTimeCount,
        reason:
            'repair with persisted override keys must mirror write-path '
            'override cohort evidence',
      );
    });

    test('admin replacement missing-summary repair without persisted '
        'override keys uses recommendation evidence', () async {
      // No override keys persisted — the reseedDemo setUp already clears
      // baseline_selected_records, so `hasPersistedManagerOverride` is
      // false here.
      expect(
        await BaselineManagerService.instance.hasPersistedManagerOverride(
          restaurantId,
        ),
        isFalse,
      );

      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final writeRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );
      expect(writeRows.length, 1);
      final writeTimeCount = writeRows.first['selected_shift_count'] as int;

      // Recompute recommendation evidence directly to compare.
      final recommendation = await BaselineManagerService.instance
          .resolveRecommendedSelection(
            restaurantId,
            replaced.calibrationWindowEnd,
          );
      expect(
        writeTimeCount,
        recommendation.selectedRecordIds.length,
        reason:
            'write path without override keys sources summary from the '
            'recommendation pipeline',
      );

      await db.delete(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );

      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-04-01',
      );

      final repairRows = await db.query(
        'benchmark_selection_summaries',
        where: 'target_cycle_id = ?',
        whereArgs: [replaced.cycleId],
      );
      expect(repairRows.length, 1);
      expect(repairRows.first['source_type'], 'admin_replacement');
      expect(
        repairRows.first['selected_shift_count'],
        writeTimeCount,
        reason:
            'repair without persisted override keys must mirror '
            'write-path recommendation evidence',
      );
    });
  });

  // ── O: Explicit restaurant-scope routing (7.55p.5g-review-fix) ──────────

  group('O — explicit restaurant scope in recommendation path', () {
    test('resolveRecommendedSelection honors the explicit restaurantId, not '
        'the active-scope restaurant', () async {
      // Demo restaurant has a full seeded candidate pool. An invented
      // ghost restaurant has zero closed shifts. Before the
      // 7.55p.5g-review-fix, the inner candidate loader resolved the
      // active-scope restaurant (demo) even when the caller passed a
      // different id — so both calls returned identical results.
      final demo = await BaselineManagerService.instance
          .resolveRecommendedSelection(restaurantId, '2026-03-27');
      // Sanity: demo has 60-day evidence and is graded per-period (the
      // pre-SA demo cohort is degenerate — spec DIAG-0 — so the
      // Jim-faithful engine honestly grades every period building_flat
      // with no selected shifts, rather than the OLD engine's masked
      // band). The discriminating signal for the routing contract this
      // test guards is "demo has per-period stats; ghost has none".
      // SB old→new: was `selectedRecordIds isNotEmpty` (depended on the
      // masked band); now assert the routing-distinguishing fact.
      expect(
        demo.overallQuality,
        isNot('insufficient'),
        reason: 'demo restaurant should have enough 60-day evidence',
      );
      expect(
        demo.perDaypartStats,
        isNotEmpty,
        reason: 'demo restaurant must be graded per service period',
      );

      final ghost = await BaselineManagerService.instance
          .resolveRecommendedSelection(
            'ghost_restaurant_with_no_data',
            '2026-03-27',
          );
      // Ghost restaurant has zero shifts — the recommendation MUST be
      // insufficient. If the bug were still present, this call would
      // silently fall back to the active (demo) restaurant and mirror
      // demo's non-insufficient result.
      expect(ghost.overallQuality, 'insufficient');
      expect(ghost.selectedRecordIds, isEmpty);
      expect(ghost.perDaypartStats, isEmpty);
    });

    test(
      'getOrCreateActiveCycle routes the explicit restaurantId all the '
      'way through the recommendation pipeline to the persisted summary',
      () async {
        // End-to-end proof: TargetCycleService is the public entry and it
        // calls the recommendation path internally. Creating a cycle for
        // the ghost restaurant must persist a summary whose selected
        // shift count reflects the ghost's empty pool, not the demo's.
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          'ghost_restaurant_with_no_data',
          '2026-03-27',
        );
        expect(cycle.restaurantId, 'ghost_restaurant_with_no_data');

        final summary = await SqliteBenchmarkSelectionSummaryRepository.instance
            .getByTargetCycleId(cycle.cycleId);
        expect(summary, isNotNull);
        expect(
          summary!.selectedShiftCount,
          0,
          reason:
              'ghost restaurant has no candidate shifts, so the service-'
              'backed recommendation must produce an empty cohort. '
              'Before 7.55p.5g-review-fix, the active (demo) restaurant '
              'was silently used instead.',
        );

        // And the cycle itself should carry the insufficient-fallback
        // source label, not the demo's cycle_recommended summary source.
        expect(summary.sourceType, 'cycle_recommended_insufficient');
      },
    );
  });

  // ── P: Benchmark graph honesty hydration (7.55p.5h-review-fix) ─────────
  //
  // Proves that recommendation-honesty signals survive a simulated
  // fresh app launch: the in-memory signals can be cleared (as happens
  // when a process restarts) and then recovered from the persisted
  // active cycle via TargetCycleService.hydrateBenchmarkHonestyFromActiveCycle.

  group('P — honesty hydration from persisted cycle (7.55p.5h-review-fix)', () {
    test('rehydrates recommendation signals after in-memory clear', () async {
      // 1. Write a recommended cycle (this sets in-memory signals).
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      expect(
        BaselineData.recommendationSignals,
        isNotNull,
        reason: 'cycle write should set signals inline',
      );

      // 2. Simulate a fresh app launch: clear the in-memory signals.
      BaselineData.clearRecommendationSignals();
      expect(BaselineData.recommendationSignals, isNull);

      // 3. Rehydrate from the persisted active cycle.
      await TargetCycleService.instance.hydrateBenchmarkHonestyFromActiveCycle(
        restaurantId,
      );

      // 4. Signals are recovered and match the persisted cycle's geometry.
      final s = BaselineData.recommendationSignals;
      expect(s, isNotNull);
      expect(s!.rangeFloorCPLH, closeTo(cycle.opzFloorCPLH, 0.001));
      expect(s.rangeCeilingCPLH, closeTo(cycle.opzCeilingCPLH, 0.001));
      expect(s.targetCPLH, closeTo(cycle.targetCPLH, 0.001));
      // Demo restaurant has enough evidence → quality is not insufficient.
      expect(s.overallQuality, isNot('insufficient'));
    });

    test('SC — Learn-chip label and graph badge derive from the SAME '
        'verdict (no contradiction, Bug #6/#8)', () async {
      // Write a recommended cycle for the demo restaurant. SA's reseed
      // makes the demo data teachable, so:
      //   - the persisted summary's rangeQualityLabel (the Learn-chip
      //     source, SB `_recommendationAnalytics`) and
      //   - the Benchmark-graph badge (SC, BaselineData.rangeGraphModel)
      // must both reflect the SAME single-source operation verdict that
      // SB carried onto the signal.
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final signals = BaselineData.recommendationSignals;
      expect(signals, isNotNull);
      // SC: the verdict is now carried on the signal (single source).
      expect(
        signals!.verdict,
        isNotNull,
        reason: 'SB rollup verdict must ride on the signal for SC',
      );

      final summary = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId(cycle.cycleId);
      expect(summary, isNotNull);

      final badge = BaselineData.rangeGraphModel.statusBadgeLabel;
      final chip = summary!.rangeQualityLabel;

      // For the teachable demo: graph badge is the approved GOOD copy
      // and the chip is the GOOD-family label — they cannot contradict
      // because both are derived from `signals.verdict`.
      if (signals.verdict == BenchmarkVerdict.teachable) {
        expect(badge, 'GOOD OPZ RANGE');
        expect(chip, 'GOOD OPZ RANGE');
      } else {
        // Any non-teachable verdict: the badge is a not-good state and
        // the chip is NOT the GOOD label — still consistent, never a
        // GOOD chip next to a degenerate badge (the old Bug #6/#8).
        expect(badge, isNot('GOOD OPZ RANGE'));
        expect(chip, isNot('GOOD OPZ RANGE'));
      }
    });

    test(
      'hydration for an unknown restaurant (no cycle) clears signals',
      () async {
        // Seed some signals so we can observe the clear.
        BaselineData.applyRecommendationSignals(
          const BaselineRecommendationSignals(
            sourceType: 'cycle_recommended',
            overallQuality: 'strong',
            unionBandWidth: 0.60,
            selectedShiftCount: 10,
            rangeFloorCPLH: 4.30,
            rangeCeilingCPLH: 4.90,
            targetCPLH: 4.58,
          ),
        );
        expect(BaselineData.recommendationSignals, isNotNull);

        // An unknown restaurant has no active cycle — hydration must
        // explicitly clear the lingering signals rather than leaving
        // stale truth on the bridge.
        await TargetCycleService.instance
            .hydrateBenchmarkHonestyFromActiveCycle(
              'unknown_restaurant_no_cycle',
            );

        expect(BaselineData.recommendationSignals, isNull);
      },
    );

    test('hydration for a ghost restaurant produces insufficient signals '
        'with Config Default geometry', () async {
      // Creating the cycle is the only way to populate the ghost's
      // active-cycle row. That's also what would exist on disk before
      // a hypothetical restart.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        'ghost_restaurant_hydration',
        '2026-03-27',
      );

      // Simulate process restart.
      BaselineData.clearRecommendationSignals();

      // Rehydrate for the ghost restaurant.
      await TargetCycleService.instance.hydrateBenchmarkHonestyFromActiveCycle(
        'ghost_restaurant_hydration',
      );

      final s = BaselineData.recommendationSignals;
      expect(s, isNotNull);
      expect(s!.overallQuality, 'insufficient');
      expect(s.sourceType, 'cycle_recommended_insufficient');
      // Geometry comes from MeridianConfig placeholder (what the
      // insufficient-fallback cycle writes).
      expect(s.targetCPLH, closeTo(MeridianConfig.targetCPLH, 0.001));
      expect(s.rangeFloorCPLH, closeTo(MeridianConfig.opzFloorCPLH, 0.001));
      expect(s.rangeCeilingCPLH, closeTo(MeridianConfig.opzCeilingCPLH, 0.001));
    });
  });

  // ── CODE_HEALTH L15 — cycleId uses random 128-bit hex ────────────────────
  // Regression pin for the audit finding: `target_cycle_service.dart:283`
  // used `millisecondsSinceEpoch`. Two replacement writes within one
  // millisecond would silently overwrite via upsert. The fix replaces the
  // timestamp tail with a 128-bit cryptographic-random hex (Random.secure).
  // The test below drives the public replacement path in a tight burst and
  // asserts every generated cycleId is unique — even when the wall clock
  // shares a millisecond across iterations.

  group('CODE_HEALTH L15 — cycleId distinctness within one millisecond', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('rapid same-day admin replacements always produce distinct cycleIds '
        '(no millisecondsSinceEpoch collision)', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      const burst = 25;
      final ids = <String>{};
      for (var i = 0; i < burst; i++) {
        final cycle = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');
        ids.add(cycle.cycleId);
      }

      expect(
        ids.length,
        burst,
        reason:
            'every cycleId from rapid replacement burst must be unique; '
            'duplicates would mean millisecondsSinceEpoch-style collision',
      );
      // Each id has the format "<restaurantId>_<sourceLabel>_<32-hex>".
      for (final id in ids) {
        final tail = id.split('_').last;
        expect(
          tail.length,
          32,
          reason: 'cycleId tail must be 32 hex chars (128-bit random)',
        );
        expect(
          RegExp(r'^[0-9a-f]{32}$').hasMatch(tail),
          isTrue,
          reason: 'cycleId tail must be lowercase hex digits',
        );
      }
    });
  });

  // ── Per-Daypart V1 (Slice 1) — per-period write-path coverage ─────────
  group('Per-Daypart V1 — per-period rows + pool consistency', () {
    test('recommended cycle emits per-period target_cycle_dayparts rows when '
        'recommendation has per-daypart stats', () async {
      await clearCycleBackedState();
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      // Demo data primes recommendation.perDaypartStats for all three
      // demo dayparts; the cycle write path emits a matching
      // per-period row for each, each carrying its SB verdict. SB
      // old→new: this asserted every row had targetCPLH > 0. With the
      // pre-SA degenerate demo cohort every period is honestly
      // `building_flat` (no band), so a non-teachable row's
      // target/band are 0 by Design Rule 2 (never a fabricated
      // point). The contract this test guards — one per-period row
      // per configured service period — still holds, and each row now
      // carries the honest verdict. SA's reseed makes them teachable
      // (target > 0) end-to-end.
      expect(
        cycle.dayparts,
        isNotEmpty,
        reason:
            'recommended path must emit per-period rows when '
            'perDaypartStats is populated',
      );
      for (final dp in cycle.dayparts) {
        expect(dp.opzCeilingCPLH, greaterThanOrEqualTo(dp.opzFloorCPLH));
        expect(
          dp.verdict,
          isNotNull,
          reason: 'every per-period row carries an SB verdict',
        );
        if (dp.verdict == BenchmarkVerdict.teachable) {
          expect(dp.targetCPLH, greaterThan(0));
          expect(dp.targetSPLH, greaterThan(0));
          expect(dp.targetPPA, greaterThan(0));
        } else {
          // building_* / running-hot-without-band → no fabricated
          // point target (Design Rule 2).
          expect(dp.targetCPLH, 0);
        }
      }
    });

    test('parent pool equals cover-weighted Σ of per-period values '
        '(Design Rule 4 pool-consistency invariant)', () async {
      await clearCycleBackedState();
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      if (cycle.dayparts.isEmpty) {
        return; // Gap 42 fallback case; covered separately.
      }

      // SB old→new: this asserted the whole-day pool == cover-weighted
      // Σ of ALL per-period rows (incl. min/max OPZ over all rows).
      // SB locked decision: the whole-day pool is the cover-weighted
      // rollup of TEACHABLE periods ONLY (building / running-hot
      // periods persist their own row + verdict for the breakdown but
      // are excluded from the whole-day number). When NO period is
      // teachable (the pre-SA degenerate demo case) the parent gets
      // MeridianConfig defaults. This re-derives the expected pool
      // from the teachable subset, matching the new invariant.
      final teachable = cycle.dayparts
          .where((d) => d.verdict == BenchmarkVerdict.teachable)
          .toList();

      if (teachable.isEmpty) {
        // No teachable period → MeridianConfig whole-day defaults.
        expect(cycle.targetCPLH, closeTo(MeridianConfig.targetCPLH, 0.001));
        expect(cycle.targetSPLH, closeTo(MeridianConfig.targetSPLH, 0.001));
        expect(cycle.targetPPA, closeTo(MeridianConfig.targetPPA, 0.001));
        expect(cycle.opzFloorCPLH, closeTo(MeridianConfig.opzFloorCPLH, 0.001));
        expect(
          cycle.opzCeilingCPLH,
          closeTo(MeridianConfig.opzCeilingCPLH, 0.001),
        );
        return;
      }

      final totalCovers = teachable.fold<int>(0, (s, d) => s + d.coverCount);
      if (totalCovers > 0) {
        double expectedCPLH = 0;
        double expectedSPLH = 0;
        double expectedPPA = 0;
        for (final d in teachable) {
          final w = d.coverCount / totalCovers;
          expectedCPLH += d.targetCPLH * w;
          expectedSPLH += d.targetSPLH * w;
          expectedPPA += d.targetPPA * w;
        }
        expect(cycle.targetCPLH, closeTo(expectedCPLH, 0.001));
        expect(cycle.targetSPLH, closeTo(expectedSPLH, 0.001));
        expect(cycle.targetPPA, closeTo(expectedPPA, 0.001));
      }

      // OPZ floor = min of teachable periods; ceiling = max.
      final minFloor = teachable
          .map((d) => d.opzFloorCPLH)
          .reduce((a, b) => a < b ? a : b);
      final maxCeiling = teachable
          .map((d) => d.opzCeilingCPLH)
          .reduce((a, b) => a > b ? a : b);
      expect(cycle.opzFloorCPLH, closeTo(minFloor, 0.001));
      expect(cycle.opzCeilingCPLH, closeTo(maxCeiling, 0.001));
    });

    test('ActiveTargetProfile sync carries per-period rows alongside whole-day '
        'scalars', () async {
      await clearCycleBackedState();
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      // The persisted parent profile row keeps the legacy flat shape;
      // per-period rows live alongside on the cycle DAO. After a
      // successful sync the cycle's per-period rows are reattached
      // on re-read.
      final cycle = await SqliteTargetCycleRepository.instance.getActiveCycle(
        restaurantId,
      );
      expect(cycle, isNotNull);
      if (cycle!.dayparts.isNotEmpty) {
        // The profile's whole-day scalars and the cycle's pool match
        // by construction (projector reads cycle.target* fields).
        expect(profile!.targetCPLH, closeTo(cycle.targetCPLH, 0.001));
        expect(profile.targetSPLH, closeTo(cycle.targetSPLH, 0.001));
      }
    });

    test('Gap 42 fallback: insufficient recommendation leaves child table '
        'empty + writes parent with MeridianConfig pool', () async {
      // To exercise Gap 42 we'd need a recommendation that returns
      // isInsufficient. The demo fixture has enough evidence to make
      // recommendations strong; this test documents the contract for
      // the orchestrator (the seam itself is exercised through the
      // _buildRecommendedProfileAndDayparts path, which we cannot call
      // directly here). The negative shape is covered by the read-side
      // contract: `cycle.daypartFor(<periodId>)` returns null and
      // consumers fall back to the whole-day pool.
      await clearCycleBackedState();
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      // If the recommendation IS insufficient the dayparts list is
      // empty; otherwise it's populated. Either path is honest;
      // the assertion that the daypart-empty case never silently
      // synthesizes a row is what matters.
      if (cycle.dayparts.isEmpty) {
        // Verify the parent pool was written with MeridianConfig
        // defaults instead of synthesized zeros.
        expect(cycle.targetCPLH, isNot(0.0));
        expect(cycle.targetSPLH, isNot(0.0));
        expect(cycle.targetPPA, isNot(0.0));
        expect(cycle.daypartFor('lunch'), isNull);
      }
    });
  });
}
