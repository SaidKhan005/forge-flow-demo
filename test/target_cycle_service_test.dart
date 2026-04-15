// Phase 7.55l.2a+2b+2c+3a+3b+4a — TargetCycle persistence, auto-refresh,
// override write path, and ActiveTargetProfile projection tests.
//
// Covers:
// A. Initial recommended cycle creation
// B. Active cycle returned unchanged when still in window
// C. Auto-refresh to new recommended cycle after cycle end
// D. Previous cycle becomes inactive/historical after refresh
// E. Locked standards persist correctly through DAO/repository
// F. Refresh derives fresh recommendation (not stale persisted profile)
// G. One-active-cycle determinism and enforcement
// H. Benchmark context re-anchoring for requested business date (7.55l.2c)
// I. Manager override write path (7.55l.3a)
// J. Admin replacement write path (7.55l.3a)
// K. Replacement standards from current app truth (7.55l.3a)
// L. Replacement provenance + history preservation (7.55l.3b)
// M. ActiveTargetProfile projection sync (7.55l.4a)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/target_cycle_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_benchmark_selection_summary_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = DemoScope.restaurantId;

  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  Future<void> clearCycleBackedState() async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('benchmark_selection_summaries');
    await db.delete('active_target_profiles');
    await db.delete('target_cycles');
  }

  // ── A: Initial recommended cycle creation ───────────────────────────────

  group('A — initial recommended cycle creation', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test('creates recommended cycle when none exists', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.source, TargetCycleSource.recommended);
      expect(cycle.restaurantId, restaurantId);
      expect(cycle.effectiveStart, '2026-03-27');
    });

    test('created cycle has 60-day effective window', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // March 27 + 59 days = May 25
      expect(cycle.effectiveEnd, '2026-05-25');
    });

    test('created cycle has calibration window ending at effective start', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.calibrationWindowEnd, '2026-03-27');
      // March 27 - 59 = January 27
      expect(cycle.calibrationWindowStart, '2026-01-27');
    });

    test('created cycle inherits standards from active profile', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.targetCPLH, greaterThan(0));
      expect(cycle.targetSPLH, greaterThan(0));
      expect(cycle.targetPPA, greaterThan(0));
      expect(cycle.fohWage, greaterThan(0));
      expect(cycle.bohWage, greaterThan(0));
      expect(cycle.opzFloorCPLH, greaterThan(0));
      expect(cycle.opzCeilingCPLH, greaterThan(0));
    });

    test('created cycle has manager override not used', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.managerOverrideUsed, isFalse);
      expect(cycle.managerOverrideAt, isNull);
      expect(cycle.adminReplacedAt, isNull);
    });

    test(
        'persisted manager-selected keys do not taint recommended-cycle provenance',
        () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      final db = await SqliteDatabase.instance.database;
      await db.insert('baseline_selected_records', {
        'restaurant_id': restaurantId,
        'record_key': candidates.first.recordKey,
      });

      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      expect(cycle.source, TargetCycleSource.recommended);

      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      expect(profile!.sourceType, 'cycle_recommended');

      final summary = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId(cycle.cycleId);
      expect(summary, isNotNull);
      expect(summary!.sourceType, 'cycle_recommended');
    });

    test('cycle is persisted to repository', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final loaded = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(loaded, isNotNull);
      expect(loaded!.effectiveStart, '2026-03-27');
    });
  });

  // ── B: Active cycle returned unchanged ─────────────────────────────────

  group('B — active cycle returned unchanged when in window', () {
    test('returns same cycle for midpoint date', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      final second = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-04-15');

      expect(second.cycleId, first.cycleId);
    });

    test('returns same cycle on effective end date', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      final onEnd = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, first.effectiveEnd);

      expect(onEnd.cycleId, first.cycleId);
    });

    test('returns same cycle on effective start date', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      final onStart = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(onStart.cycleId, first.cycleId);
    });
  });

  // ── C: Auto-refresh after cycle end ────────────────────────────────────

  group('C — auto-refresh after cycle end', () {
    test('creates new cycle when one day past effective end', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // effectiveEnd = 2026-05-25, so day after = 2026-05-26
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      expect(refreshed.cycleId, isNot(first.cycleId));
      expect(refreshed.source, TargetCycleSource.recommended);
      expect(refreshed.effectiveStart, '2026-05-26');
    });

    test('refreshed cycle has fresh 60-day window', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      // May 26 + 59 = July 24
      expect(refreshed.effectiveEnd, '2026-07-24');
    });

    test('creates new cycle when well past effective end', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-08-15');

      expect(refreshed.cycleId, isNot(first.cycleId));
      expect(refreshed.effectiveStart, '2026-08-15');
    });
  });

  // ── D: Previous cycle becomes inactive after refresh ───────────────────

  group('D — previous cycle becomes inactive after refresh', () {
    test('old cycle is not returned as active after refresh', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      final active = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(active, isNotNull);
      expect(active!.cycleId, isNot(first.cycleId));
    });

    test('old cycle row is preserved (not deleted)', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      // Verify old row still exists in the database with deactivated_at set
      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('target_cycles',
          where: 'restaurant_id = ?', whereArgs: [restaurantId]);
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
      final created = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final loaded = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);

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

    test('standards survive deactivation of old cycle and creation of new', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      // New cycle should also have valid standards
      expect(refreshed.targetCPLH, greaterThan(0));
      expect(refreshed.targetSPLH, greaterThan(0));
      expect(refreshed.targetPPA, greaterThan(0));

      // Old cycle's standards are still in the database
      final db = await SqliteDatabase.instance.database;
      final oldRow = await db.query('target_cycles',
          where: 'cycle_id = ?', whereArgs: [first.cycleId]);
      expect(oldRow.length, 1);
      expect((oldRow.first['target_cplh'] as num).toDouble(), first.targetCPLH);
    });
  });

  // ── F: Refresh derives fresh recommendation ────────────────────────────

  group('F — refresh derives fresh recommendation, not stale profile', () {
    test('refreshed cycle uses explicit authority inputs, not persisted profile', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

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
      await SqliteTargetProfileRepository.instance
          .upsertActiveTargetProfile(staleProfile);

      // Trigger auto-refresh (effectiveEnd = 2026-05-25)
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      // The refreshed cycle must NOT have the sentinel value.
      // It should have rebuilt from explicit recommendation inputs
      // plus resolved wage authority.
      expect(refreshed.targetCPLH, isNot(999.0),
          reason: 'refreshed cycle must not clone stale persisted profile');
      expect(refreshed.targetSPLH, isNot(999.0));
      expect(refreshed.targetPPA, isNot(999.0));

      // And it should have real positive values from the rebuilt authority path.
      expect(refreshed.targetCPLH, greaterThan(0));
      expect(refreshed.targetSPLH, greaterThan(0));
      expect(refreshed.targetPPA, greaterThan(0));
    });

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
      await SqliteTargetProfileRepository.instance
          .upsertActiveTargetProfile(staleProfile);

      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.targetCPLH, isNot(888.0),
          reason: 'initial cycle must not clone stale persisted profile');
      expect(cycle.targetCPLH, greaterThan(0));
    });
  });

  // ── G: One-active-cycle determinism and enforcement ────────────────────

  group('G — one-active-cycle determinism and enforcement', () {
    test('only one active row exists after initial creation', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query('target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId]);
      expect(activeRows.length, 1);
    });

    test('only one active row exists after auto-refresh', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query('target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId]);
      expect(activeRows.length, 1,
          reason: 'exactly one active cycle after refresh');
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

      final active = await SqliteTargetCycleRepository.instance
          .getActiveCycle(restaurantId);
      expect(active, isNotNull);
      expect(active!.cycleId, 'newer_cycle',
          reason: 'deterministic read returns latest created_at');
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

      // Now create a proper cycle via the service
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-01');

      final activeRows = await db.query('target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId]);
      expect(activeRows.length, 1,
          reason: 'both stale rows must be deactivated');
      expect(activeRows.first['cycle_id'],
          isNot(anyOf('stale_a', 'stale_b')));
    });
  });

  // ── H: Benchmark context re-anchoring (7.55l.2c) ─────────────────────────

  group('H — benchmark context re-anchored to requested business date', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test('cycle creation re-primes BaselineData from DB, not stale in-memory state', () async {
      // Poison BaselineData with extreme sentinel values. If the service
      // does not re-prime from DB, buildActiveTargetProfileFromBaseline
      // would read these sentinels.
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 999.0, splh: 999.0, ppa: 999.0,
            covers: 1, isSelected: true),
      ]);
      expect(BaselineData.derivedTargetCPLH, 999.0,
          reason: 'sentinel must be in effect before service call');

      // Create cycle — service must re-prime from DB first
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      expect(cycle.targetCPLH, isNot(999.0),
          reason: 'cycle must not carry poisoned in-memory value');
      expect(cycle.targetCPLH, greaterThan(0));
      expect(cycle.targetSPLH, isNot(999.0));
      expect(cycle.targetPPA, isNot(999.0));
    });

    test('auto-refresh re-primes from DB for new date, not stale state', () async {
      // Create the initial cycle cleanly
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Poison BaselineData after initial creation
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'dinner', cplh: 777.0, splh: 777.0, ppa: 777.0,
            covers: 1, isSelected: true),
      ]);
      expect(BaselineData.derivedTargetCPLH, 777.0,
          reason: 'sentinel must be in effect before refresh');

      // Auto-refresh past effective end (2026-05-25 + 1 day)
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      expect(refreshed.targetCPLH, isNot(777.0),
          reason: 'refreshed cycle must not carry poisoned in-memory value');
      expect(refreshed.targetCPLH, greaterThan(0));
      expect(refreshed.targetSPLH, isNot(777.0));
      expect(refreshed.targetPPA, isNot(777.0));
    });

    test('BaselineData state reflects requested date window after cycle creation', () async {
      // Poison BaselineData
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 555.0, splh: 555.0, ppa: 555.0,
            covers: 1, isSelected: true),
      ]);

      // Create cycle — should re-prime BaselineData from DB
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // After creation, BaselineData must no longer carry the sentinel
      expect(BaselineData.derivedTargetCPLH, isNot(555.0),
          reason: 'BaselineData must have been re-primed from DB');
      expect(BaselineData.historicalContextRecords, isNotEmpty,
          reason: 'historical context should be populated from DB');
    });
  });

  // ── I: Manager override write path (7.55l.3a) ────────────────────────

  group('I — manager override write path', () {
    test('preserves effective window but recalibrates provenance window', () async {
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
    });

    test('sets manager override metadata correctly', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      expect(overridden.managerOverrideUsed, isTrue);
      expect(overridden.managerOverrideAt, isNotNull);
      expect(overridden.adminReplacedAt, isNull);
    });

    test('denied when manager override already used (once-per-cycle)', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // First override succeeds
      await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      // Second override denied
      await expectLater(
        TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-04-05'),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });

    test('denied when business date outside active window', () async {
      // Create cycle starting 2026-03-27
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Override on date before cycle start — getOrCreateActiveCycle returns
      // the existing cycle (not past end, so no auto-refresh), but
      // isActiveForDate fails for 2026-03-26
      await expectLater(
        TargetCycleService.instance
            .applyManagerOverrideCycle(restaurantId, '2026-03-26'),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });

    test('old cycle row preserved as historical/inactive after override', () async {
      final original = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('target_cycles',
          where: 'restaurant_id = ?', whereArgs: [restaurantId]);
      expect(allRows.length, 2, reason: 'both old and new cycle rows exist');

      final deactivated = allRows
          .where((r) => r['deactivated_at'] != null)
          .toList();
      expect(deactivated.length, 1, reason: 'exactly one deactivated cycle');
      expect(deactivated.first['cycle_id'], original.cycleId);
    });
  });

  // ── J: Admin replacement write path (7.55l.3a) ───────────────────────

  group('J — admin replacement write path', () {
    test('preserves effective window but recalibrates provenance window', () async {
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
    });

    test('succeeds even after manager override already used', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Manager override consumes the once-per-cycle allowance
      await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      // Admin replacement still succeeds
      final adminCycle = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-05');

      expect(adminCycle.source, TargetCycleSource.adminReplacement);
      expect(adminCycle.adminReplacedAt, isNotNull);
    });

    test('sets admin replacement metadata correctly', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      expect(replaced.source, TargetCycleSource.adminReplacement);
      expect(replaced.adminReplacedAt, isNotNull);
    });

    test('preserves prior manager override metadata from replaced cycle', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Apply manager override first
      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      // Admin replacement should carry forward the override metadata
      final adminCycle = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-05');

      expect(adminCycle.managerOverrideUsed, isTrue,
          reason: 'prior manager override status preserved');
      expect(adminCycle.managerOverrideAt, overridden.managerOverrideAt,
          reason: 'prior manager override timestamp preserved');
      expect(adminCycle.adminReplacedAt, isNotNull);
    });

    test('old cycle row preserved as historical/inactive after replacement', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query('target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId]);
      expect(activeRows.length, 1,
          reason: 'exactly one active cycle after admin replacement');
      expect(activeRows.first['source'], 'admin_replacement');
    });
  });

  // ── K: Replacement standards from current app truth (7.55l.3a) ───────

  group('K — replacement standards from current app truth', () {
    test('manager override standards come from baseline truth, not stale prior cycle', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Poison BaselineData with sentinel values
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 999.0, splh: 999.0, ppa: 999.0,
            covers: 1, isSelected: true),
      ]);
      expect(BaselineData.derivedTargetCPLH, 999.0,
          reason: 'sentinel must be in effect before override');

      // Apply manager override — should re-prime from DB first
      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      expect(overridden.targetCPLH, isNot(999.0),
          reason: 'override must not carry poisoned in-memory value');
      expect(overridden.targetCPLH, greaterThan(0));
      expect(overridden.targetSPLH, isNot(999.0));
      expect(overridden.targetPPA, isNot(999.0));
    });

    test('admin replacement standards come from baseline truth, not stale prior cycle', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      // Poison BaselineData with sentinel values
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'dinner', cplh: 888.0, splh: 888.0, ppa: 888.0,
            covers: 1, isSelected: true),
      ]);
      expect(BaselineData.derivedTargetCPLH, 888.0,
          reason: 'sentinel must be in effect before replacement');

      // Apply admin replacement — should re-prime from DB first
      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      expect(replaced.targetCPLH, isNot(888.0),
          reason: 'replacement must not carry poisoned in-memory value');
      expect(replaced.targetCPLH, greaterThan(0));
      expect(replaced.targetSPLH, isNot(888.0));
      expect(replaced.targetPPA, isNot(888.0));
    });
  });

  // ── L: Replacement provenance + history preservation (7.55l.3b) ──────

  group('L — replacement provenance and history preservation', () {
    test('mid-cycle manager override recalibrates provenance to actual rebuild window', () async {
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
      expect(overridden.calibrationWindowStart,
          isNot(original.calibrationWindowStart));
      expect(overridden.calibrationWindowEnd,
          isNot(original.calibrationWindowEnd));
    });

    test('mid-cycle admin replacement recalibrates provenance to actual rebuild window', () async {
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
    });

    test('two same-day admin replacements produce distinct historical rows', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final first = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');
      final second = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      expect(second.cycleId, isNot(first.cycleId),
          reason: 'same-day replacements must have distinct IDs');

      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('target_cycles',
          where: 'restaurant_id = ?', whereArgs: [restaurantId]);
      // Original recommended + first admin (deactivated) + second admin (active)
      expect(allRows.length, 3,
          reason: 'all three cycle rows must be preserved');
    });

    test('only one row active after repeated same-day replacements', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');
      await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final activeRows = await db.query('target_cycles',
          where: 'restaurant_id = ? AND deactivated_at IS NULL',
          whereArgs: [restaurantId]);
      expect(activeRows.length, 1,
          reason: 'exactly one active cycle after repeated replacements');
    });

    test('old rows remain historical/inactive after chain of replacements', () async {
      final original = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final override = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      final adminReplace = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-05');

      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('target_cycles',
          where: 'restaurant_id = ?', whereArgs: [restaurantId]);
      expect(allRows.length, 3,
          reason: 'recommended + override + admin = 3 rows');

      final deactivated = allRows
          .where((r) => r['deactivated_at'] != null)
          .toList();
      expect(deactivated.length, 2,
          reason: 'original and override both deactivated');

      final deactivatedIds =
          deactivated.map((r) => r['cycle_id']).toSet();
      expect(deactivatedIds, contains(original.cycleId));
      expect(deactivatedIds, contains(override.cycleId));

      final activeRows = allRows
          .where((r) => r['deactivated_at'] == null)
          .toList();
      expect(activeRows.length, 1);
      expect(activeRows.first['cycle_id'], adminReplace.cycleId);
    });
  });

  // ── M: ActiveTargetProfile projection sync (7.55l.4a) ─────────────────

  group('M — ActiveTargetProfile projection sync from TargetCycle', () {
    Future<ActiveTargetProfile?> readProfile() =>
        SqliteTargetProfileRepository.instance
            .getActiveTargetProfile(restaurantId);

    test('initial cycle creation writes projected active profile matching cycle', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final profile = await readProfile();
      expect(profile, isNotNull);
      expect(profile!.targetProfileId, '${restaurantId}_active');
      expect(profile.restaurantId, restaurantId);
      expect(profile.sourceType, 'cycle_recommended');
      expect(profile.targetCPLH, cycle.targetCPLH);
      expect(profile.targetSPLH, cycle.targetSPLH);
      expect(profile.targetPPA, cycle.targetPPA);
      expect(profile.fohWage, cycle.fohWage);
      expect(profile.bohWage, cycle.bohWage);
      expect(profile.opzFloorCPLH, cycle.opzFloorCPLH);
      expect(profile.opzCeilingCPLH, cycle.opzCeilingCPLH);
    });

    test('auto-refresh updates persisted active profile to match refreshed cycle', () async {
      // Create initial cycle
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final profileBefore = await readProfile();
      expect(profileBefore, isNotNull);

      // Auto-refresh past effective end (2026-05-25 + 1 day)
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      final profileAfter = await readProfile();
      expect(profileAfter, isNotNull);
      expect(profileAfter!.sourceType, 'cycle_recommended');
      expect(profileAfter.targetCPLH, refreshed.targetCPLH);
      expect(profileAfter.targetSPLH, refreshed.targetSPLH);
      expect(profileAfter.targetPPA, refreshed.targetPPA);
      expect(profileAfter.fohWage, refreshed.fohWage);
      expect(profileAfter.bohWage, refreshed.bohWage);
    });

    test('manager override updates persisted active profile with override source', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

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
    });

    test('admin replacement updates persisted active profile with admin source', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

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
    });

    test('profile values come from cycle, not stale previously persisted profile', () async {
      // Create initial cycle — writes projected profile
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

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
      expect(stale!.targetCPLH, 999.0,
          reason: 'sentinel must be in place before replacement');

      // Admin replacement triggers a fresh projection from the new cycle
      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final fresh = await readProfile();
      expect(fresh, isNotNull);
      expect(fresh!.targetCPLH, isNot(999.0),
          reason: 'profile must come from fresh cycle, not stale row');
      expect(fresh.targetCPLH, replaced.targetCPLH);
      expect(fresh.sourceType, 'cycle_admin_replacement');
    });

    test('projected profile computes theoretical labor percentages from cycle', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final profile = await readProfile();
      expect(profile, isNotNull);

      // Expected: fohPct = fohWage / (CPLH * PPA) * 100
      final expectedFoh = (cycle.targetCPLH > 0 && cycle.targetPPA > 0)
          ? cycle.fohWage / (cycle.targetCPLH * cycle.targetPPA) * 100
          : 0.0;
      // Expected: bohPct = bohWage / SPLH * 100
      final expectedBoh =
          cycle.targetSPLH > 0 ? cycle.bohWage / cycle.targetSPLH * 100 : 0.0;

      expect(profile!.theoreticalFohLaborPct, closeTo(expectedFoh, 0.001));
      expect(profile.theoreticalBohLaborPct, closeTo(expectedBoh, 0.001));
      expect(profile.theoreticalLaborPct,
          closeTo(expectedFoh + expectedBoh, 0.001));
    });
  });

  // ── N: BenchmarkSelectionSummary persistence (7.55l.8c) ────────────────

  group('N — benchmark selection summary persisted on cycle write', () {
    setUp(() async {
      await clearCycleBackedState();
    });

    test('recommended cycle write persists benchmark-selection summary', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [cycle.cycleId]);
      expect(rows.length, 1, reason: 'exactly one summary for the cycle');
      expect(rows.first['source_type'], 'cycle_recommended');
      expect((rows.first['selected_shift_count'] as int), greaterThan(0),
          reason: 'seed records have selected shifts');
    });

    test('manager override cycle write persists benchmark-selection summary', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final overridden = await TargetCycleService.instance
          .applyManagerOverrideCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [overridden.cycleId]);
      expect(rows.length, 1, reason: 'summary persisted for override cycle');
      expect(rows.first['source_type'], 'manager_override');
    });

    test('admin replacement cycle write persists benchmark-selection summary', () async {
      await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final replaced = await TargetCycleService.instance
          .applyAdminReplacementCycle(restaurantId, '2026-04-01');

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [replaced.cycleId]);
      expect(rows.length, 1, reason: 'summary persisted for admin cycle');
      expect(rows.first['source_type'], 'admin_replacement');
    });

    test('summary carries valid range quality from seed records', () async {
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');

      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('benchmark_selection_summaries',
          where: 'target_cycle_id = ?', whereArgs: [cycle.cycleId]);
      expect(rows.length, 1);
      final label = rows.first['range_quality_label'] as String;
      expect(label, anyOf('GOOD OPZ RANGE', 'OPZ RANGE TOO NARROW', 'OPZ RANGE TOO WIDE'),
          reason: 'range quality label must be a valid enum value');
    });

    test('auto-refresh persists new summary for refreshed cycle', () async {
      final first = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      final refreshed = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-05-26');

      expect(refreshed.cycleId, isNot(first.cycleId));

      final db = await SqliteDatabase.instance.database;
      final allRows = await db.query('benchmark_selection_summaries');
      // Both the original and refreshed cycle should have summaries
      final ids = allRows.map((r) => r['target_cycle_id']).toSet();
      expect(ids, contains(first.cycleId));
      expect(ids, contains(refreshed.cycleId));
    });
  });

  // ── O: Explicit restaurant-scope routing (7.55p.5g-review-fix) ──────────

  group('O — explicit restaurant scope in recommendation path', () {
    test(
        'resolveRecommendedSelection honors the explicit restaurantId, not '
        'the active-scope restaurant', () async {
      // Demo restaurant has a full seeded candidate pool. An invented
      // ghost restaurant has zero closed shifts. Before the
      // 7.55p.5g-review-fix, the inner candidate loader resolved the
      // active-scope restaurant (demo) even when the caller passed a
      // different id — so both calls returned identical results.
      final demo = await BaselineManagerService.instance
          .resolveRecommendedSelection(restaurantId, '2026-03-27');
      // Sanity: demo has enough evidence for a non-insufficient result.
      expect(demo.overallQuality, isNot('insufficient'),
          reason: 'demo restaurant should have enough 60-day evidence');
      expect(demo.selectedRecordIds, isNotEmpty);

      final ghost = await BaselineManagerService.instance
          .resolveRecommendedSelection(
              'ghost_restaurant_with_no_data', '2026-03-27');
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
          'ghost_restaurant_with_no_data', '2026-03-27');
      expect(cycle.restaurantId, 'ghost_restaurant_with_no_data');

      final summary = await SqliteBenchmarkSelectionSummaryRepository.instance
          .getByTargetCycleId(cycle.cycleId);
      expect(summary, isNotNull);
      expect(summary!.selectedShiftCount, 0,
          reason:
              'ghost restaurant has no candidate shifts, so the service-'
              'backed recommendation must produce an empty cohort. '
              'Before 7.55p.5g-review-fix, the active (demo) restaurant '
              'was silently used instead.');

      // And the cycle itself should carry the insufficient-fallback
      // source label, not the demo's cycle_recommended summary source.
      expect(summary.sourceType, 'cycle_recommended_insufficient');
    });
  });

  // ── P: Benchmark graph honesty hydration (7.55p.5h-review-fix) ─────────
  //
  // Proves that recommendation-honesty signals survive a simulated
  // fresh app launch: the in-memory signals can be cleared (as happens
  // when a process restarts) and then recovered from the persisted
  // active cycle via TargetCycleService.hydrateBenchmarkHonestyFromActiveCycle.

  group('P — honesty hydration from persisted cycle (7.55p.5h-review-fix)',
      () {
    test('rehydrates recommendation signals after in-memory clear',
        () async {
      // 1. Write a recommended cycle (this sets in-memory signals).
      final cycle = await TargetCycleService.instance
          .getOrCreateActiveCycle(restaurantId, '2026-03-27');
      expect(BaselineData.recommendationSignals, isNotNull,
          reason: 'cycle write should set signals inline');

      // 2. Simulate a fresh app launch: clear the in-memory signals.
      BaselineData.clearRecommendationSignals();
      expect(BaselineData.recommendationSignals, isNull);

      // 3. Rehydrate from the persisted active cycle.
      await TargetCycleService.instance
          .hydrateBenchmarkHonestyFromActiveCycle(restaurantId);

      // 4. Signals are recovered and match the persisted cycle's geometry.
      final s = BaselineData.recommendationSignals;
      expect(s, isNotNull);
      expect(s!.rangeFloorCPLH, closeTo(cycle.opzFloorCPLH, 0.001));
      expect(s.rangeCeilingCPLH, closeTo(cycle.opzCeilingCPLH, 0.001));
      expect(s.targetCPLH, closeTo(cycle.targetCPLH, 0.001));
      // Demo restaurant has enough evidence → quality is not insufficient.
      expect(s.overallQuality, isNot('insufficient'));
    });

    test('hydration for an unknown restaurant (no cycle) clears signals',
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
              'unknown_restaurant_no_cycle');

      expect(BaselineData.recommendationSignals, isNull);
    });

    test('hydration for a ghost restaurant produces insufficient signals '
        'with Config Default geometry', () async {
      // Creating the cycle is the only way to populate the ghost's
      // active-cycle row. That's also what would exist on disk before
      // a hypothetical restart.
      await TargetCycleService.instance.getOrCreateActiveCycle(
          'ghost_restaurant_hydration', '2026-03-27');

      // Simulate process restart.
      BaselineData.clearRecommendationSignals();

      // Rehydrate for the ghost restaurant.
      await TargetCycleService.instance
          .hydrateBenchmarkHonestyFromActiveCycle(
              'ghost_restaurant_hydration');

      final s = BaselineData.recommendationSignals;
      expect(s, isNotNull);
      expect(s!.overallQuality, 'insufficient');
      expect(s.sourceType, 'cycle_recommended_insufficient');
      // Geometry comes from MeridianConfig placeholder (what the
      // insufficient-fallback cycle writes).
      expect(s.targetCPLH, closeTo(MeridianConfig.targetCPLH, 0.001));
      expect(s.rangeFloorCPLH, closeTo(MeridianConfig.opzFloorCPLH, 0.001));
      expect(s.rangeCeilingCPLH,
          closeTo(MeridianConfig.opzCeilingCPLH, 0.001));
    });
  });
}
