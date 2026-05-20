// Phase 7.55l.2a+2b — TargetCycle lifecycle persistence + auto-refresh tests.
//
// Bucket 5e of the 2026-05-20 test-suite tightening audit: split out of
// `test/target_cycle_service_test.dart` (2,365 lines). This file holds the
// six lifecycle groups (A-F):
//
//   A. Initial recommended cycle creation
//   B. Active cycle returned unchanged when still in window
//   C. Auto-refresh to new recommended cycle after cycle end
//   D. Previous cycle becomes inactive/historical after refresh
//   E. Locked standards persist correctly through DAO/repository
//   F. Refresh derives fresh recommendation (not stale persisted profile)
//
// Shared `setUp()` body and the cycle-table delete helper live in
// `target_cycle_test_helpers.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
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

  // ── A: Initial recommended cycle creation ───────────────────────────────

  group('A — initial recommended cycle creation', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test('creates recommended cycle when none exists', () async {
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      expect(cycle.source, TargetCycleSource.recommended);
      expect(cycle.restaurantId, restaurantId);
      expect(cycle.effectiveStart, '2026-03-27');
    });

    test('created cycle has 60-day effective window', () async {
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      // March 27 + 59 days = May 25
      expect(cycle.effectiveEnd, '2026-05-25');
    });

    test(
      'created cycle has calibration window ending at effective start',
      () async {
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        expect(cycle.calibrationWindowEnd, '2026-03-27');
        // March 27 - 59 = January 27
        expect(cycle.calibrationWindowStart, '2026-01-27');
      },
    );

    test('created cycle inherits standards from active profile', () async {
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      expect(cycle.targetCPLH, greaterThan(0));
      expect(cycle.targetSPLH, greaterThan(0));
      expect(cycle.targetPPA, greaterThan(0));
      expect(cycle.fohWage, greaterThan(0));
      expect(cycle.bohWage, greaterThan(0));
      expect(cycle.opzFloorCPLH, greaterThan(0));
      expect(cycle.opzCeilingCPLH, greaterThan(0));
    });

    test('created cycle has manager override not used', () async {
      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      expect(cycle.managerOverrideUsed, isFalse);
      expect(cycle.managerOverrideAt, isNull);
      expect(cycle.adminReplacedAt, isNull);
    });

    test(
      'persisted manager-selected keys do not taint recommended-cycle provenance',
      () async {
        final candidates = await BaselineManagerService.instance
            .getCandidateShifts();
        expect(candidates, isNotEmpty);

        final db = await SqliteDatabase.instance.database;
        await db.insert('baseline_selected_records', {
          'restaurant_id': restaurantId,
          'record_key': candidates.first.recordKey,
        });

        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );
        expect(cycle.source, TargetCycleSource.recommended);

        final profile = await SqliteTargetProfileRepository.instance
            .getActiveTargetProfile(restaurantId);
        expect(profile, isNotNull);
        // SB old→new: this asserted `profile.sourceType ==
        // 'cycle_recommended'`. The pre-SA demo seeder is degenerate
        // (every period's covers-per-hour barely varies — spec DIAG-0),
        // so the Jim-faithful engine now honestly returns no teachable
        // period and the recommended path takes the Gap-42 fallback
        // (`*_insufficient`). The OLD engine masked the degenerate data
        // by never gating on dispersion; surfacing it is the entire point
        // of this slice, not a regression. The provenance contract this
        // test guards (manager-selected keys must NOT taint the
        // recommended path) still holds: the source is still the
        // recommended pipeline, just honestly insufficient on this data.
        // SA's demo reseed restores `cycle_recommended`.
        expect(
          profile!.sourceType,
          anyOf('cycle_recommended', 'system_baseline_insufficient'),
        );

        final summary = await SqliteBenchmarkSelectionSummaryRepository.instance
            .getByTargetCycleId(cycle.cycleId);
        expect(summary, isNotNull);
        expect(
          summary!.sourceType,
          anyOf('cycle_recommended', 'cycle_recommended_insufficient'),
        );
      },
    );

    test('cycle is persisted to repository', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final loaded = await SqliteTargetCycleRepository.instance.getActiveCycle(
        restaurantId,
      );
      expect(loaded, isNotNull);
      expect(loaded!.effectiveStart, '2026-03-27');
    });
  });

  // ── B: Active cycle returned unchanged ─────────────────────────────────

  group('B — active cycle returned unchanged when in window', () {
    test('returns same cycle for midpoint date', () async {
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final second = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-04-15',
      );

      expect(second.cycleId, first.cycleId);
    });

    test('returns same cycle on effective end date', () async {
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final onEnd = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        first.effectiveEnd,
      );

      expect(onEnd.cycleId, first.cycleId);
    });

    test('returns same cycle on effective start date', () async {
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      final onStart = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      expect(onStart.cycleId, first.cycleId);
    });
  });

  // ── C: Auto-refresh after cycle end ────────────────────────────────────

  group('C — auto-refresh after cycle end', () {
    test(
      'creates new cycle on first week-start day past effective end',
      () async {
        // Per-daypart V1 (Slice 0): auto-refresh gates to the operator's
        // configured `week_start_day`. The demo seed sets weekStartDay = Monday.
        // effectiveEnd = 2026-05-25 (Monday). The next Monday strictly past
        // effective end is 2026-06-01.
        final first = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-06-01');

        expect(refreshed.cycleId, isNot(first.cycleId));
        expect(refreshed.source, TargetCycleSource.recommended);
        expect(refreshed.effectiveStart, '2026-06-01');
      },
    );

    test('refreshed cycle has fresh 60-day window', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-06-01');

      // June 1 + 59 = July 30
      expect(refreshed.effectiveEnd, '2026-07-30');
    });

    test(
      'creates new cycle when well past effective end on a week-start day',
      () async {
        // 2026-08-17 is a Monday (the configured week-start). The cycle
        // boundary lapsed long ago; refresh fires on the first week-start
        // day the operator opens the app.
        final first = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-08-17');

        expect(refreshed.cycleId, isNot(first.cycleId));
        expect(refreshed.effectiveStart, '2026-08-17');
      },
    );

    test('defers refresh until the next configured week-start day', () async {
      // Slice 0: cycle past effective end but business date is mid-week —
      // existing cycle returned unchanged. Demo seed weekStartDay = Monday.
      // effectiveEnd = 2026-05-25 (Mon); 2026-05-26 (Tue) is mid-week.
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final deferred = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-05-26',
      );

      expect(
        deferred.cycleId,
        first.cycleId,
        reason: 'mid-week defer keeps the active cycle',
      );
      expect(
        deferred.effectiveEnd,
        '2026-05-25',
        reason: 'cycle window is unchanged during the deferral period',
      );
    });
  });

  // ── D: Previous cycle becomes inactive after refresh ───────────────────

  group('D — previous cycle becomes inactive after refresh', () {
    test('old cycle is not returned as active after refresh', () async {
      final first = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      // 2026-06-01 is the next Monday (week-start) past effectiveEnd.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-06-01',
      );

      final active = await SqliteTargetCycleRepository.instance.getActiveCycle(
        restaurantId,
      );
      expect(active, isNotNull);
      expect(active!.cycleId, isNot(first.cycleId));
    });

    test('old cycle row is preserved (not deleted)', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-06-01',
      );

      // Verify old row still exists in the database with deactivated_at set
      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query(
        'target_cycles',
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId],
      );
      expect(allRows.length, 2, reason: 'both old and new cycle rows exist');

      final deactivated = allRows
          .where((r) => r['deactivated_at'] != null)
          .toList();
      expect(deactivated.length, 1, reason: 'exactly one deactivated cycle');
    });
  });

  // ── E: Locked standards persist correctly ──────────────────────────────

  group('E — locked standards persist correctly', () {
    test('all standard fields round-trip through persistence', () async {
      final created = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final loaded = await SqliteTargetCycleRepository.instance.getActiveCycle(
        restaurantId,
      );

      expect(loaded, isNotNull);
      expect(loaded!.cycleId, created.cycleId);
      expect(loaded.targetCPLH, created.targetCPLH);
      expect(loaded.targetSPLH, created.targetSPLH);
      expect(loaded.targetPPA, created.targetPPA);
      expect(loaded.fohWage, created.fohWage);
      expect(loaded.bohWage, created.bohWage);
      expect(loaded.opzFloorCPLH, created.opzFloorCPLH);
      expect(loaded.opzCeilingCPLH, created.opzCeilingCPLH);
      expect(loaded.source, created.source);
      expect(loaded.effectiveStart, created.effectiveStart);
      expect(loaded.effectiveEnd, created.effectiveEnd);
      expect(loaded.calibrationWindowStart, created.calibrationWindowStart);
      expect(loaded.calibrationWindowEnd, created.calibrationWindowEnd);
      expect(loaded.managerOverrideUsed, created.managerOverrideUsed);
      expect(loaded.createdAt, created.createdAt);
    });

    test(
      'standards survive deactivation of old cycle and creation of new',
      () async {
        final first = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );
        // 2026-06-01 is the next Monday (week-start) past effectiveEnd.
        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-06-01');

        // New cycle should also have valid standards
        expect(refreshed.targetCPLH, greaterThan(0));
        expect(refreshed.targetSPLH, greaterThan(0));
        expect(refreshed.targetPPA, greaterThan(0));

        // Old cycle's standards are still in the database
        final db = await SqliteDatabase.instance.database;
        final oldRow = await db.query(
          'target_cycles',
          where: 'cycle_id = ?',
          whereArgs: [first.cycleId],
        );
        expect(oldRow.length, 1);
        expect(
          (oldRow.first['target_cplh'] as num).toDouble(),
          first.targetCPLH,
        );
      },
    );
  });

  // ── F: Refresh derives fresh recommendation ────────────────────────────

  group('F — refresh derives fresh recommendation, not stale profile', () {
    test(
      'refreshed cycle uses explicit authority inputs, not persisted profile',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Mutate the persisted ActiveTargetProfile to a sentinel value.
        // If the service were still reading the persisted profile, the
        // refreshed cycle would inherit this sentinel.
        final staleProfile = ActiveTargetProfile(
          targetProfileId: '${restaurantId}_active',
          restaurantId: restaurantId,
          sourceType: 'system_baseline',
          targetCPLH: 999.0,
          targetSPLH: 999.0,
          targetPPA: 999.0,
          fohWage: 999.0,
          bohWage: 999.0,
          opzFloorCPLH: 999.0,
          opzCeilingCPLH: 999.0,
          theoreticalFohLaborPct: 0.0,
          theoreticalBohLaborPct: 0.0,
          theoreticalLaborPct: 0.0,
          builtAt: DateTime.now().toIso8601String(),
        );
        await SqliteTargetProfileRepository.instance.upsertActiveTargetProfile(
          staleProfile,
        );

        // Trigger auto-refresh (effectiveEnd = 2026-05-25). Slice 0 gates
        // refresh to the configured week-start day (Monday); 2026-06-01 is
        // the first Monday strictly past effective end.
        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-06-01');

        // The refreshed cycle must NOT have the sentinel value.
        // It should have rebuilt from explicit recommendation inputs
        // plus resolved wage authority.
        expect(
          refreshed.targetCPLH,
          isNot(999.0),
          reason: 'refreshed cycle must not clone stale persisted profile',
        );
        expect(refreshed.targetSPLH, isNot(999.0));
        expect(refreshed.targetPPA, isNot(999.0));

        // And it should have real positive values from the rebuilt authority path.
        expect(refreshed.targetCPLH, greaterThan(0));
        expect(refreshed.targetSPLH, greaterThan(0));
        expect(refreshed.targetPPA, greaterThan(0));
      },
    );

    test('initial creation also uses explicit authority inputs', () async {
      // Mutate persisted profile before any cycle exists
      final staleProfile = ActiveTargetProfile(
        targetProfileId: '${restaurantId}_active',
        restaurantId: restaurantId,
        sourceType: 'system_baseline',
        targetCPLH: 888.0,
        targetSPLH: 888.0,
        targetPPA: 888.0,
        fohWage: 888.0,
        bohWage: 888.0,
        opzFloorCPLH: 888.0,
        opzCeilingCPLH: 888.0,
        theoreticalFohLaborPct: 0.0,
        theoreticalBohLaborPct: 0.0,
        theoreticalLaborPct: 0.0,
        builtAt: DateTime.now().toIso8601String(),
      );
      await SqliteTargetProfileRepository.instance.upsertActiveTargetProfile(
        staleProfile,
      );

      final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      expect(
        cycle.targetCPLH,
        isNot(888.0),
        reason: 'initial cycle must not clone stale persisted profile',
      );
      expect(cycle.targetCPLH, greaterThan(0));
    });
  });
}
