// Phase 7.55l.2c+3a+3b+4a — TargetCycle override write paths + projection sync.
//
// Bucket 5e of the 2026-05-20 test-suite tightening audit: split out of
// `test/target_cycle_service_test.dart` (2,365 lines). This file holds the
// seven override/projection groups (G-M):
//
//   G. One-active-cycle determinism and enforcement
//   H. Benchmark context re-anchoring for requested business date (7.55l.2c)
//   I. Manager override write path (7.55l.3a)
//   J. Admin replacement write path (7.55l.3a)
//   K. Replacement standards from current app truth (7.55l.3a)
//   L. Replacement provenance + history preservation (7.55l.3b)
//   M. ActiveTargetProfile projection sync (7.55l.4a)
//
// Shared `setUp()` body and the cycle-table delete helper live in
// `target_cycle_test_helpers.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

import 'target_cycle_test_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = targetCycleDemoRestaurantId;

  setUp(setUpTargetCycleTest);

  // ── G: One-active-cycle determinism and enforcement ────────────────────

  group('G — one-active-cycle determinism and enforcement', () {
    test('only one active row exists after initial creation', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query(
        'target_cycles',
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [restaurantId],
      );
      expect(activeRows.length, 1);
    });

    test('only one active row exists after auto-refresh', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      // 2026-06-01 is the next Monday (week-start) past effectiveEnd.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-06-01',
      );

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query(
        'target_cycles',
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [restaurantId],
      );
      expect(
        activeRows.length,
        1,
        reason: 'exactly one active cycle after refresh',
      );
    });

    test('read returns latest cycle when multiple active rows exist', () async {
      await clearCycleBackedState();

      // Manually insert two active rows to simulate a race/corruption scenario
      final db = await SqliteDatabase.instance.database;

      await db.insert('target_cycles', {
        'cycle_id': 'older_cycle',
        'restaurant_id': restaurantId,
        'source': 'recommended',
        'effective_start': '2026-01-01',
        'effective_end': '2026-03-01',
        'calibration_window_start': '2025-11-03',
        'calibration_window_end': '2026-01-01',
        'target_cplh': 4.0,
        'target_splh': 170.0,
        'target_ppa': 40.0,
        'foh_wage': 16.0,
        'boh_wage': 20.0,
        'opz_floor_cplh': 3.0,
        'opz_ceiling_cplh': 6.0,
        'manager_override_used': 0,
        'created_at': '2026-01-01T00:00:00Z',
      });
      await db.insert('target_cycles', {
        'cycle_id': 'newer_cycle',
        'restaurant_id': restaurantId,
        'source': 'recommended',
        'effective_start': '2026-03-01',
        'effective_end': '2026-04-29',
        'calibration_window_start': '2026-01-01',
        'calibration_window_end': '2026-03-01',
        'target_cplh': 5.0,
        'target_splh': 180.0,
        'target_ppa': 45.0,
        'foh_wage': 17.0,
        'boh_wage': 22.0,
        'opz_floor_cplh': 3.0,
        'opz_ceiling_cplh': 6.0,
        'manager_override_used': 0,
        'created_at': '2026-03-01T00:00:00Z',
      });

      final active = await SqliteTargetCycleRepository.instance.getActiveCycle(
        restaurantId,
      );
      expect(active, isNotNull);
      expect(
        active!.cycleId,
        'newer_cycle',
        reason: 'deterministic read returns latest created_at',
      );
    });

    test('creating a new cycle deactivates all prior active rows', () async {
      await clearCycleBackedState();

      // Manually insert two active rows
      final db = await SqliteDatabase.instance.database;
      await db.insert('target_cycles', {
        'cycle_id': 'stale_a',
        'restaurant_id': restaurantId,
        'source': 'recommended',
        'effective_start': '2026-01-01',
        'effective_end': '2026-03-01',
        'calibration_window_start': '2025-11-03',
        'calibration_window_end': '2026-01-01',
        'target_cplh': 4.0,
        'target_splh': 170.0,
        'target_ppa': 40.0,
        'foh_wage': 16.0,
        'boh_wage': 20.0,
        'opz_floor_cplh': 3.0,
        'opz_ceiling_cplh': 6.0,
        'manager_override_used': 0,
        'created_at': '2026-01-01T00:00:00Z',
      });
      await db.insert('target_cycles', {
        'cycle_id': 'stale_b',
        'restaurant_id': restaurantId,
        'source': 'recommended',
        'effective_start': '2026-03-01',
        'effective_end': '2026-04-29',
        'calibration_window_start': '2026-01-01',
        'calibration_window_end': '2026-03-01',
        'target_cplh': 5.0,
        'target_splh': 180.0,
        'target_ppa': 45.0,
        'foh_wage': 17.0,
        'boh_wage': 22.0,
        'opz_floor_cplh': 3.0,
        'opz_ceiling_cplh': 6.0,
        'manager_override_used': 0,
        'created_at': '2026-03-01T00:00:00Z',
      });

      // Now create a proper cycle via the service. Slice 0 gates refresh
      // to the operator's configured week-start day (Monday in the demo
      // seed); 2026-05-04 is the next Monday past both stale rows'
      // effective_end values.
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-05-04',
      );

      final activeRows = await db.query(
        'target_cycles',
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [restaurantId],
      );
      expect(
        activeRows.length,
        1,
        reason: 'both stale rows must be deactivated',
      );
      expect(activeRows.first['cycle_id'], isNot(anyOf('stale_a', 'stale_b')));
    });
  });

  // ── H: Benchmark context re-anchoring (7.55l.2c) ─────────────────────────

  group('H — benchmark context re-anchored to requested business date', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test(
      'cycle creation re-primes BaselineData from DB, not stale in-memory state',
      () async {
        // Poison BaselineData with extreme sentinel values. If the service
        // does not re-prime from DB, buildActiveTargetProfileFromBaseline
        // would read these sentinels.
        BaselineData.applyManagerOverride([
          const DaypartBaseline(
            daypart: 'lunch',
            cplh: 999.0,
            splh: 999.0,
            ppa: 999.0,
            covers: 1,
            isSelected: true,
          ),
        ]);
        expect(
          BaselineData.derivedTargetCPLH,
          999.0,
          reason: 'sentinel must be in effect before service call',
        );

        // Create cycle — service must re-prime from DB first
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        expect(
          cycle.targetCPLH,
          isNot(999.0),
          reason: 'cycle must not carry poisoned in-memory value',
        );
        expect(cycle.targetCPLH, greaterThan(0));
        expect(cycle.targetSPLH, isNot(999.0));
        expect(cycle.targetPPA, isNot(999.0));
      },
    );

    test(
      'auto-refresh re-primes from DB for new date, not stale state',
      () async {
        // Create the initial cycle cleanly
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Poison BaselineData after initial creation
        BaselineData.applyManagerOverride([
          const DaypartBaseline(
            daypart: 'dinner',
            cplh: 777.0,
            splh: 777.0,
            ppa: 777.0,
            covers: 1,
            isSelected: true,
          ),
        ]);
        expect(
          BaselineData.derivedTargetCPLH,
          777.0,
          reason: 'sentinel must be in effect before refresh',
        );

        // Auto-refresh past effective end on the next configured week-start
        // day (Monday 2026-06-01). Slice 0 gates refresh to week-start.
        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-06-01');

        expect(
          refreshed.targetCPLH,
          isNot(777.0),
          reason: 'refreshed cycle must not carry poisoned in-memory value',
        );
        expect(refreshed.targetCPLH, greaterThan(0));
        expect(refreshed.targetSPLH, isNot(777.0));
        expect(refreshed.targetPPA, isNot(777.0));
      },
    );

    test(
      'BaselineData state reflects requested date window after cycle creation',
      () async {
        // Poison BaselineData
        BaselineData.applyManagerOverride([
          const DaypartBaseline(
            daypart: 'lunch',
            cplh: 555.0,
            splh: 555.0,
            ppa: 555.0,
            covers: 1,
            isSelected: true,
          ),
        ]);

        // Create cycle — should re-prime BaselineData from DB
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // After creation, BaselineData must no longer carry the sentinel
        expect(
          BaselineData.derivedTargetCPLH,
          isNot(555.0),
          reason: 'BaselineData must have been re-primed from DB',
        );
        expect(
          BaselineData.historicalContextRecords,
          isNotEmpty,
          reason: 'historical context should be populated from DB',
        );
      },
    );
  });

  // ── I: Manager override write path (7.55l.3a) ────────────────────────

  group('I — manager override write path', () {
    test(
      'preserves effective window but recalibrates provenance window',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');

        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        expect(overridden.source, TargetCycleSource.managerOverride);
        expect(overridden.cycleId, isNot(original.cycleId));
        // Effective window preserved from prior cycle
        expect(overridden.effectiveStart, original.effectiveStart);
        expect(overridden.effectiveEnd, original.effectiveEnd);
        // Calibration window matches actual rebuild date, not prior cycle
        expect(overridden.calibrationWindowEnd, '2026-04-01');
        // April 1 - 59 = February 1
        expect(overridden.calibrationWindowStart, '2026-02-01');
      },
    );

    test('sets manager override metadata correctly', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      expect(overridden.managerOverrideUsed, isTrue);
      expect(overridden.managerOverrideAt, isNotNull);
      expect(overridden.adminReplacedAt, isNull);
    });

    test(
      'denied when manager override already used (once-per-cycle)',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // First override succeeds
        await TargetCycleService.instance.applyManagerOverrideCycle(
          restaurantId,
          '2026-04-01',
        );

        // Second override denied
        await expectLater(
          TargetCycleService.instance.applyManagerOverrideCycle(
            restaurantId,
            '2026-04-05',
          ),
          throwsA(isA<ManagerOverrideDeniedException>()),
        );
      },
    );

    test('denied when business date outside active window', () async {
      // Create cycle starting 2026-03-27
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      // Override on date before cycle start — getOrCreateActiveCycle returns
      // the existing cycle (not past end, so no auto-refresh), but
      // isActiveForDate fails for 2026-03-26
      await expectLater(
        TargetCycleService.instance.applyManagerOverrideCycle(
          restaurantId,
          '2026-03-26',
        ),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });

    test(
      'old cycle row preserved as historical/inactive after override',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');

        await TargetCycleService.instance.applyManagerOverrideCycle(
          restaurantId,
          '2026-04-01',
        );

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
        expect(deactivated.first['cycle_id'], original.cycleId);
      },
    );
  });

  // ── J: Admin replacement write path (7.55l.3a) ───────────────────────

  group('J — admin replacement write path', () {
    test(
      'preserves effective window but recalibrates provenance window',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');

        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        expect(replaced.source, TargetCycleSource.adminReplacement);
        expect(replaced.cycleId, isNot(original.cycleId));
        // Effective window preserved from prior cycle
        expect(replaced.effectiveStart, original.effectiveStart);
        expect(replaced.effectiveEnd, original.effectiveEnd);
        // Calibration window matches actual rebuild date, not prior cycle
        expect(replaced.calibrationWindowEnd, '2026-04-01');
        expect(replaced.calibrationWindowStart, '2026-02-01');
      },
    );

    test('succeeds even after manager override already used', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      // Manager override consumes the once-per-cycle allowance
      await TargetCycleService.instance.applyManagerOverrideCycle(
        restaurantId,
        '2026-04-01',
      );

      // Admin replacement still succeeds
      final adminCycle = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-05');

      expect(adminCycle.source, TargetCycleSource.adminReplacement);
      expect(adminCycle.adminReplacedAt, isNotNull);
    });

    test('sets admin replacement metadata correctly', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );

      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      expect(replaced.source, TargetCycleSource.adminReplacement);
      expect(replaced.adminReplacedAt, isNotNull);
    });

    test(
      'preserves prior manager override metadata from replaced cycle',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Apply manager override first
        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        // Admin replacement should carry forward the override metadata
        final adminCycle = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-05');

        expect(
          adminCycle.managerOverrideUsed,
          isTrue,
          reason: 'prior manager override status preserved',
        );
        expect(
          adminCycle.managerOverrideAt,
          overridden.managerOverrideAt,
          reason: 'prior manager override timestamp preserved',
        );
        expect(adminCycle.adminReplacedAt, isNotNull);
      },
    );

    test(
      'old cycle row preserved as historical/inactive after replacement',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        await TargetCycleService.instance.applyAdminReplacementCycle(
          restaurantId,
          '2026-04-01',
        );

        final db = await SqliteDatabase.instance.database;
        final activeRows = await db.query(
          'target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId],
        );
        expect(
          activeRows.length,
          1,
          reason: 'exactly one active cycle after admin replacement',
        );
        expect(activeRows.first['source'], 'admin_replacement');
      },
    );
  });

  // ── K: Replacement standards from current app truth (7.55l.3a) ───────

  group('K — replacement standards from current app truth', () {
    test(
      'manager override standards come from baseline truth, not stale prior cycle',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Poison BaselineData with sentinel values
        BaselineData.applyManagerOverride([
          const DaypartBaseline(
            daypart: 'lunch',
            cplh: 999.0,
            splh: 999.0,
            ppa: 999.0,
            covers: 1,
            isSelected: true,
          ),
        ]);
        expect(
          BaselineData.derivedTargetCPLH,
          999.0,
          reason: 'sentinel must be in effect before override',
        );

        // Apply manager override — should re-prime from DB first
        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        expect(
          overridden.targetCPLH,
          isNot(999.0),
          reason: 'override must not carry poisoned in-memory value',
        );
        expect(overridden.targetCPLH, greaterThan(0));
        expect(overridden.targetSPLH, isNot(999.0));
        expect(overridden.targetPPA, isNot(999.0));
      },
    );

    test(
      'admin replacement standards come from baseline truth, not stale prior cycle',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Poison BaselineData with sentinel values
        BaselineData.applyManagerOverride([
          const DaypartBaseline(
            daypart: 'dinner',
            cplh: 888.0,
            splh: 888.0,
            ppa: 888.0,
            covers: 1,
            isSelected: true,
          ),
        ]);
        expect(
          BaselineData.derivedTargetCPLH,
          888.0,
          reason: 'sentinel must be in effect before replacement',
        );

        // Apply admin replacement — should re-prime from DB first
        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        expect(
          replaced.targetCPLH,
          isNot(888.0),
          reason: 'replacement must not carry poisoned in-memory value',
        );
        expect(replaced.targetCPLH, greaterThan(0));
        expect(replaced.targetSPLH, isNot(888.0));
        expect(replaced.targetPPA, isNot(888.0));
      },
    );
  });

  // ── L: Replacement provenance + history preservation (7.55l.3b) ──────

  group('L — replacement provenance and history preservation', () {
    test(
      'mid-cycle manager override recalibrates provenance to actual rebuild window',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');
        // Original calibration: [2026-01-27, 2026-03-27]

        // Override mid-cycle on April 15
        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-15');

        // Effective window unchanged
        expect(overridden.effectiveStart, original.effectiveStart);
        expect(overridden.effectiveEnd, original.effectiveEnd);
        // Calibration window recalibrated to the rebuild date
        expect(overridden.calibrationWindowEnd, '2026-04-15');
        // April 15 - 59 = February 15
        expect(overridden.calibrationWindowStart, '2026-02-15');
        // Must NOT carry the original cycle's calibration window
        expect(
          overridden.calibrationWindowStart,
          isNot(original.calibrationWindowStart),
        );
        expect(
          overridden.calibrationWindowEnd,
          isNot(original.calibrationWindowEnd),
        );
      },
    );

    test(
      'mid-cycle admin replacement recalibrates provenance to actual rebuild window',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');

        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-20');

        // Effective window unchanged
        expect(replaced.effectiveStart, original.effectiveStart);
        expect(replaced.effectiveEnd, original.effectiveEnd);
        // Calibration window recalibrated to the rebuild date
        expect(replaced.calibrationWindowEnd, '2026-04-20');
        // April 20 - 59 = February 20
        expect(replaced.calibrationWindowStart, '2026-02-20');
      },
    );

    test(
      'two same-day admin replacements produce distinct historical rows',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final first = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');
        final second = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        expect(
          second.cycleId,
          isNot(first.cycleId),
          reason: 'same-day replacements must have distinct IDs',
        );

        final db = await SqliteDatabase.instance.database;
        final allRows = await db.query(
          'target_cycles',
          where: 'restaurant_id = ?',
          whereArgs: [restaurantId],
        );
        // Original recommended + first admin (deactivated) + second admin (active)
        expect(
          allRows.length,
          3,
          reason: 'all three cycle rows must be preserved',
        );
      },
    );

    test('only one row active after repeated same-day replacements', () async {
      await TargetCycleService.instance.getOrCreateActiveCycle(
        restaurantId,
        '2026-03-27',
      );
      await TargetCycleService.instance.applyAdminReplacementCycle(
        restaurantId,
        '2026-04-01',
      );
      await TargetCycleService.instance.applyAdminReplacementCycle(
        restaurantId,
        '2026-04-01',
      );

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query(
        'target_cycles',
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [restaurantId],
      );
      expect(
        activeRows.length,
        1,
        reason: 'exactly one active cycle after repeated replacements',
      );
    });

    test(
      'old rows remain historical/inactive after chain of replacements',
      () async {
        final original = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-03-27');

        final override = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        final adminReplace = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-05');

        final db = await SqliteDatabase.instance.database;
        final allRows = await db.query(
          'target_cycles',
          where: 'restaurant_id = ?',
          whereArgs: [restaurantId],
        );
        expect(
          allRows.length,
          3,
          reason: 'recommended + override + admin = 3 rows',
        );

        final deactivated = allRows
            .where((r) => r['deactivated_at'] != null)
            .toList();
        expect(
          deactivated.length,
          2,
          reason: 'original and override both deactivated',
        );

        final deactivatedIds = deactivated.map((r) => r['cycle_id']).toSet();
        expect(deactivatedIds, contains(original.cycleId));
        expect(deactivatedIds, contains(override.cycleId));

        final activeRows = allRows
            .where((r) => r['deactivated_at'] == null)
            .toList();
        expect(activeRows.length, 1);
        expect(activeRows.first['cycle_id'], adminReplace.cycleId);
      },
    );
  });

  // ── M: ActiveTargetProfile projection sync (7.55l.4a) ─────────────────

  group('M — ActiveTargetProfile projection sync from TargetCycle', () {
    Future<ActiveTargetProfile?> readProfile() => SqliteTargetProfileRepository
        .instance
        .getActiveTargetProfile(restaurantId);

    test(
      'initial cycle creation writes projected active profile matching cycle',
      () async {
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final profile = await readProfile();
        expect(profile, isNotNull);
        expect(profile!.targetProfileId, '${restaurantId}_active');
        expect(profile.restaurantId, restaurantId);
        expect(profile.targetCycleId, cycle.cycleId);
        expect(profile.targetProfileVersionId, isNotNull);
        expect(profile.targetProfileVersionId, isNotEmpty);
        expect(profile.sourceType, 'cycle_recommended');
        expect(profile.targetCPLH, cycle.targetCPLH);
        expect(profile.targetSPLH, cycle.targetSPLH);
        expect(profile.targetPPA, cycle.targetPPA);
        expect(profile.fohWage, cycle.fohWage);
        expect(profile.bohWage, cycle.bohWage);
        expect(profile.opzFloorCPLH, cycle.opzFloorCPLH);
        expect(profile.opzCeilingCPLH, cycle.opzCeilingCPLH);

        final version = await SqliteTargetProfileRepository.instance
            .getTargetProfileVersion(
              restaurantId,
              profile.targetProfileVersionId!,
            );
        expect(version, isNotNull);
        expect(version!.targetCycleId, cycle.cycleId);
        expect(version.targetProfileId, profile.targetProfileId);
      },
    );

    test(
      'auto-refresh updates persisted active profile to match refreshed cycle',
      () async {
        // Create initial cycle
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final profileBefore = await readProfile();
        expect(profileBefore, isNotNull);

        // Auto-refresh past effective end on the next configured week-start
        // day (Monday 2026-06-01). Slice 0 gates refresh to week-start.
        final refreshed = await TargetCycleService.instance
            .getOrCreateActiveCycle(restaurantId, '2026-06-01');

        final profileAfter = await readProfile();
        expect(profileAfter, isNotNull);
        expect(profileAfter!.sourceType, 'cycle_recommended');
        expect(profileAfter.targetCPLH, refreshed.targetCPLH);
        expect(profileAfter.targetSPLH, refreshed.targetSPLH);
        expect(profileAfter.targetPPA, refreshed.targetPPA);
        expect(profileAfter.fohWage, refreshed.fohWage);
        expect(profileAfter.bohWage, refreshed.bohWage);
      },
    );

    test(
      'manager override updates persisted active profile with override source',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final overridden = await TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-01');

        final profile = await readProfile();
        expect(profile, isNotNull);
        expect(profile!.sourceType, 'cycle_manager_override');
        expect(profile.targetCPLH, overridden.targetCPLH);
        expect(profile.targetSPLH, overridden.targetSPLH);
        expect(profile.targetPPA, overridden.targetPPA);
        expect(profile.fohWage, overridden.fohWage);
        expect(profile.bohWage, overridden.bohWage);
        expect(profile.opzFloorCPLH, overridden.opzFloorCPLH);
        expect(profile.opzCeilingCPLH, overridden.opzCeilingCPLH);
      },
    );

    test(
      'admin replacement updates persisted active profile with admin source',
      () async {
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        final profile = await readProfile();
        expect(profile, isNotNull);
        expect(profile!.sourceType, 'cycle_admin_replacement');
        expect(profile.targetCPLH, replaced.targetCPLH);
        expect(profile.targetSPLH, replaced.targetSPLH);
        expect(profile.targetPPA, replaced.targetPPA);
        expect(profile.fohWage, replaced.fohWage);
        expect(profile.bohWage, replaced.bohWage);
      },
    );

    test(
      'profile values come from cycle, not stale previously persisted profile',
      () async {
        // Create initial cycle — writes projected profile
        await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        // Manually overwrite the persisted profile with sentinel values
        final db = await SqliteDatabase.instance.database;
        await db.update(
          'active_target_profiles',
          {
            'target_cplh': 999.0,
            'target_splh': 999.0,
            'target_ppa': 999.0,
            'source_type': 'stale_garbage',
          },
          where: 'restaurant_id = ?',
          whereArgs: [restaurantId],
        );

        // Verify sentinel is in place
        final stale = await readProfile();
        expect(
          stale!.targetCPLH,
          999.0,
          reason: 'sentinel must be in place before replacement',
        );

        // Admin replacement triggers a fresh projection from the new cycle
        final replaced = await TargetCycleService.instance
            .applyAdminReplacementCycle(restaurantId, '2026-04-01');

        final fresh = await readProfile();
        expect(fresh, isNotNull);
        expect(
          fresh!.targetCPLH,
          isNot(999.0),
          reason: 'profile must come from fresh cycle, not stale row',
        );
        expect(fresh.targetCPLH, replaced.targetCPLH);
        expect(fresh.sourceType, 'cycle_admin_replacement');
      },
    );

    test(
      'projected profile computes theoretical labor percentages from cycle',
      () async {
        final cycle = await TargetCycleService.instance.getOrCreateActiveCycle(
          restaurantId,
          '2026-03-27',
        );

        final profile = await readProfile();
        expect(profile, isNotNull);

        // Expected: fohPct = fohWage / (CPLH * PPA) * 100
        final expectedFoh = (cycle.targetCPLH > 0 && cycle.targetPPA > 0)
            ? cycle.fohWage / (cycle.targetCPLH * cycle.targetPPA) * 100
            : 0.0;
        // Expected: bohPct = bohWage / SPLH * 100
        final expectedBoh = cycle.targetSPLH > 0
            ? cycle.bohWage / cycle.targetSPLH * 100
            : 0.0;

        expect(profile!.theoreticalFohLaborPct, closeTo(expectedFoh, 0.001));
        expect(profile.theoreticalBohLaborPct, closeTo(expectedBoh, 0.001));
        expect(
          profile.theoreticalLaborPct,
          closeTo(expectedFoh + expectedBoh, 0.001),
        );
      },
    );
  });
}
