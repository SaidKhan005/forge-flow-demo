// Target state alignment tests.
//
// Current contract (7.55l+ profile persistence, 7.55q.5 week preservation):
// the persisted ActiveTargetProfile is the propagation authority; closed
// shift and week truth do not drift when the active profile changes.
//
// Validates:
// A. Active target profile persists current effective baseline state
// B. Manager override refreshes active target profile state
// C. Close shift locks a target profile version
// D. Historical shift truth does not drift after active target changes
// E. Historical week truth does not drift after active target changes
//
// Historical origin: Phase 7.5b.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/business_date_authority_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';

// â”€â”€ Shared close inputs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

ClosedShiftInput _friDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 27),
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'dinner',
      covers: 304,
      forecastCovers: 310,
      actualSales: 12768.0,
      actualFohHours: 71,
      actualBohHours: 73,
      scheduledFohHours: 69,
      scheduledBohHours: 72,
      actualFohLaborDollars: 1246.25,
      actualBohLaborDollars: 1627.75,
      sourceSystem: 'demo_pos',
      sourceShiftId: 'w13-fri-dinner-close',
    );

ClosedShiftInput _friLateNight() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 27),
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'late_night',
      covers: 84,
      forecastCovers: 90,
      actualSales: 3528.0,
      actualFohHours: 21,
      actualBohHours: 22,
      scheduledFohHours: 20,
      scheduledBohHours: 21,
      actualFohLaborDollars: 372.0,
      actualBohLaborDollars: 478.5,
    );

ClosedShiftInput _satDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 28),
      weekId: '2026-W13',
      dayLabel: 'Sat',
      daypart: 'dinner',
      covers: 298,
      forecastCovers: 310,
      actualSales: 12665.0,
      actualFohHours: 70,
      actualBohHours: 72,
      actualFohLaborDollars: 1228.5,
      actualBohLaborDollars: 1606.0,
    );

ClosedShiftInput _satLateNight() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 28),
      weekId: '2026-W13',
      dayLabel: 'Sat',
      daypart: 'late_night',
      covers: 88,
      forecastCovers: 90,
      actualSales: 3740.0,
      actualFohHours: 21,
      actualBohHours: 22,
      actualFohLaborDollars: 365.5,
      actualBohLaborDollars: 481.0,
    );

ClosedShiftInput _sunDinner() => ClosedShiftInput(
      businessDate: DateTime(2026, 3, 29),
      weekId: '2026-W13',
      dayLabel: 'Sun',
      daypart: 'dinner',
      covers: 176,
      forecastCovers: 180,
      actualSales: 7436.0,
      actualFohHours: 41,
      actualBohHours: 43,
      actualFohLaborDollars: 714.0,
      actualBohLaborDollars: 936.5,
    );

void main() {
  final profileRepo = SqliteTargetProfileRepository.instance;

  setUp(() async {
    BaselineData.clearManagerOverride();
    await SqliteDatabase.instance.reseedDemo();
  });

  // â”€â”€ A: Active target profile persists current effective baseline state â”€â”€â”€â”€

  group('A â€” active target profile persistence', () {
    test('initial profile matches the seeded active cycle projection',
        () async {
      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle('demo_restaurant_001');
      expect(profile, isNotNull);
      expect(cycle, isNotNull);
      expect(profile!.targetCPLH, closeTo(cycle!.targetCPLH, 0.001));
      expect(profile.targetSPLH, closeTo(cycle.targetSPLH, 0.001));
      expect(profile.targetPPA, closeTo(cycle.targetPPA, 0.001));
      expect(profile.fohWage, closeTo(cycle.fohWage, 0.001));
      expect(profile.bohWage, closeTo(cycle.bohWage, 0.001));
      expect(profile.sourceType, 'cycle_recommended');
    });
  });

  // â”€â”€ B: Manager override refreshes active target profile state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” override refreshes profile', () {
    test('sourceType becomes cycle_manager_override after selection (7.55q.9)',
        () async {
      // 7.55q.9: saveSelection now routes through
      // TargetCycleService.applyManagerOverrideCycle, so the active
      // profile is produced by TargetCycleActiveTargetProfileProjector
      // and carries the cycle-era source label, not the legacy bridge
      // 'manager_override' value.
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profile, isNotNull);
      expect(profile!.sourceType, 'cycle_manager_override');
      expect(profile.targetCPLH,
          closeTo(BaselineData.derivedTargetCPLH, 0.001));
    });

    test('clearing override restores cycle_recommended', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      await BaselineManagerService.instance.saveSelection({});

      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profile!.sourceType, 'cycle_recommended');
    });

    test('clearing override restores recommended authority without '
        'resetting once-per-cycle usage', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      await BaselineManagerService.instance.saveSelection({});

      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle('demo_restaurant_001');
      expect(cycle, isNotNull);
      expect(cycle!.source, TargetCycleSource.recommended);
      expect(cycle.managerOverrideUsed, isTrue);

      expect(
        () => BaselineManagerService.instance
            .saveSelection({candidates[1].recordKey}),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });
  });

  // â”€â”€ C: Close shift locks a target profile version â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” close shift locks target version', () {
    test('stored ShiftRecord has non-empty targetProfileVersionId', () async {
      final record =
          await ShiftService.instance.closeShift(_friDinner());
      expect(record.targetProfileVersionId, isNotNull);
      expect(record.targetProfileVersionId, isNotEmpty);
    });

    test('stored ShiftRecord locked targets match active profile', () async {
      final profileBefore =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');

      final record =
          await ShiftService.instance.closeShift(_friDinner());

      expect(record.targetCPLH, closeTo(profileBefore!.targetCPLH, 0.001));
      expect(record.targetSPLH, closeTo(profileBefore.targetSPLH, 0.001));
      expect(record.targetPPA, closeTo(profileBefore.targetPPA, 0.001));
      expect(record.targetFohWage, profileBefore.fohWage);
      expect(record.targetBohWage, profileBefore.bohWage);
      expect(record.targetSourceType, profileBefore.sourceType);
    });

    test('target profile version is persisted and retrievable', () async {
      final record =
          await ShiftService.instance.closeShift(_friDinner());

      final version = await profileRepo.getTargetProfileVersion(
        'demo_restaurant_001',
        record.targetProfileVersionId!,
      );
      expect(version, isNotNull);
      expect(version!.targetCPLH, record.targetCPLH);
    });
  });

  // â”€â”€ D: Historical shift truth does not drift â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” shift truth stability', () {
    test('locked targets do not change when active profile changes', () async {
      // Close shift under profile A (system_baseline)
      final recordA =
          await ShiftService.instance.closeShift(_friDinner());
      final lockedCPLH = recordA.targetCPLH;

      // Change the active profile by applying override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      // The shift is persisted in shift_records, re-read it
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where:
              "restaurant_id = ? AND week_id = ? AND day_label = ? AND daypart = ?",
          whereArgs: ['demo_restaurant_001', '2026-W13', 'Fri', 'dinner']);
      expect(rows, isNotEmpty);
      final storedCPLH = (rows.first['target_cplh'] as num?)?.toDouble();
      expect(storedCPLH, closeTo(lockedCPLH!, 0.001));
    });
  });

  // â”€â”€ D2: Migrated historical records have non-null locked targets â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D2 â€” locked target fields are non-null after reseed', () {
    test('seeded shift records have non-null locked target fields and provenance', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where: "restaurant_id = ? AND status = 'closed'",
          whereArgs: ['demo_restaurant_001'],
          limit: 5);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['target_cplh'], isNotNull,
            reason: 'target_cplh must be backfilled');
        expect(row['target_splh'], isNotNull);
        expect(row['target_ppa'], isNotNull);
        expect(row['target_foh_wage'], isNotNull);
        expect(row['target_boh_wage'], isNotNull);
        expect(row['target_profile_id'], isNotNull,
            reason: 'target_profile_id must be backfilled');
        expect(row['target_profile_version_id'], isNotNull,
            reason: 'target_profile_version_id must be backfilled');
        expect((row['target_profile_version_id'] as String), isNotEmpty);
      }
    });

    test('compat version row exists for backfilled provenance', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('target_profile_versions',
          where: 'target_profile_version_id = ?',
          whereArgs: ['compat_demo_restaurant_001_v8_backfill']);
      expect(rows, isNotEmpty,
          reason: 'compat version row must exist for backfilled shifts');
      expect(rows.first['restaurant_id'], 'demo_restaurant_001');
      expect((rows.first['target_cplh'] as num).toDouble(), greaterThan(0));
    });

    test('seeded week records have non-null locked target fields', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('week_records',
          where: 'restaurant_id = ?',
          whereArgs: ['demo_restaurant_001'],
          limit: 5);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['target_cplh'], isNotNull,
            reason: 'target_cplh must be backfilled');
        expect(row['target_splh'], isNotNull);
        expect(row['target_ppa'], isNotNull);
        expect(row['target_foh_wage'], isNotNull);
        expect(row['target_boh_wage'], isNotNull);
      }
    });

    test('WeekRecord storedTargetCPLH does not throw after reseed', () async {
      final weeks = await ShiftService.instance.getWeekHistory();
      expect(weeks, isNotEmpty);
      // This would throw StateError if locked fields were null
      for (final w in weeks) {
        expect(w.storedTargetCPLH, isA<double>());
        expect(w.storedTargetSPLH, isA<double>());
        expect(w.storedTargetPPA, isA<double>());
      }
    });
  });

  // â”€â”€ E: Historical week truth does not drift â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” week truth stability', () {
    test('stored week target fields do not change after profile change',
        () async {
      // Close all 5 remaining shifts to create a full week
      await ShiftService.instance.closeShift(_friDinner());
      await ShiftService.instance.closeShift(_friLateNight());
      await ShiftService.instance.closeShift(_satDinner());
      await ShiftService.instance.closeShift(_satLateNight());
      await ShiftService.instance.closeShift(_sunDinner());

      // Read the stored week
      final weeks = await ShiftService.instance.getWeekHistory();
      final w13 = weeks.firstWhere((w) => w.weekId == '2026-W13');
      final originalTargetCPLH = w13.targetCPLH;
      // 7.55q.5: compare the nullable preserved locked plan hours
      // directly. A null value here just means the snapshot was not
      // persisted before close (honest legacy). The stability
      // property the test asserts is "closed truth doesn't drift
      // after profile change" â€” still demonstrated either way.
      final originalLockedFohHours = w13.lockedRequiredFohHours;
      final originalLockedBohHours = w13.lockedRequiredBohHours;

      // Change active targets
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey, candidates[1].recordKey});

      // Re-read the stored week from DB
      final weeksAfter = await ShiftService.instance.getWeekHistory();
      final w13After = weeksAfter.firstWhere((w) => w.weekId == '2026-W13');

      expect(w13After.targetCPLH, closeTo(originalTargetCPLH!, 0.001));
      expect(w13After.lockedRequiredFohHours, originalLockedFohHours);
      expect(w13After.lockedRequiredBohHours, originalLockedBohHours);
    });
  });

  // â”€â”€ F: Closed-shift Full Week detail truth does not drift â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” closed shift Full Week locked truth', () {
    test('override does not rewrite closed shift locked target fields',
        () async {
      // Close a shift under the current profile (system_baseline)
      final record =
          await ShiftService.instance.closeShift(_friDinner());

      // Capture all locked values
      final origPPA = record.lockedTargetPPA;
      final origCPLH = record.lockedTargetCPLH;
      final origSPLH = record.lockedTargetSPLH;
      final origFohWage = record.lockedTargetFohWage;
      final origBohWage = record.lockedTargetBohWage;
      final origFohPct = record.lockedTheoreticalFohLaborPct;
      final origBohPct = record.lockedTheoreticalBohLaborPct;
      final origTotalPct = record.theoreticalLaborPct;

      // Change active targets through manager override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey, candidates[1].recordKey});

      // Re-read the closed shift from DB
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('shift_records',
          where:
              "restaurant_id = ? AND week_id = ? AND day_label = ? AND daypart = ?",
          whereArgs: ['demo_restaurant_001', '2026-W13', 'Fri', 'dinner']);
      expect(rows, isNotEmpty);
      final reloaded =
          ShiftRecord.fromMap(rows.first);

      // All locked fields must be unchanged
      expect(reloaded.lockedTargetPPA, closeTo(origPPA, 0.001));
      expect(reloaded.lockedTargetCPLH, closeTo(origCPLH, 0.001));
      expect(reloaded.lockedTargetSPLH, closeTo(origSPLH, 0.001));
      expect(reloaded.lockedTargetFohWage, origFohWage);
      expect(reloaded.lockedTargetBohWage, origBohWage);
      expect(reloaded.lockedTheoreticalFohLaborPct, closeTo(origFohPct, 0.001));
      expect(reloaded.lockedTheoreticalBohLaborPct, closeTo(origBohPct, 0.001));
      expect(reloaded.theoreticalLaborPct, closeTo(origTotalPct, 0.001));
    });
  });

  // â”€â”€ G: Active-target authority propagates without BaselineData.revision â”€â”€â”€â”€

  group('G â€” active-target authority propagation', () {
    test('persisted active profile changes propagate independently of BaselineData.revision',
        () async {
      // Read initial persisted profile. The seeded demo path is now
      // cycle-backed, so fresh state should already carry the
      // projected recommended-cycle source label.
      final profileBefore =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profileBefore, isNotNull);
      expect(profileBefore!.sourceType, 'cycle_recommended');

      // Apply override through service path (which now routes through
      // TargetCycleService.applyManagerOverrideCycle per 7.55q.9).
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      // Re-read persisted profile â€” should reflect cycle-era override.
      final profileAfter =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profileAfter!.sourceType, 'cycle_manager_override');

      // The persisted state changed without needing BaselineData.revision
      // as the propagation authority
      expect(profileAfter.targetCPLH, isNot(equals(0)));
    });
  });

  // â”€â”€ H: 7.55q.9 â€” Baseline Manager Done writes cycle + profile together â”€â”€
  //
  // Closes the divergence the 7.55q deep-check surfaced: saveSelection
  // now routes through TargetCycleService.applyManagerOverrideCycle, so
  // after Done the active target_cycle row and the active_target_profiles
  // row MUST carry the same targetCPLH. The once-per-60-day
  // managerOverrideUsed rule is now actually enforced â€” a second save
  // in the same cycle throws ManagerOverrideDeniedException. The new
  // BaselineManagerService.resetForAdminTest affordance clears the flag
  // so manual validation can loop.

  group('H â€” 7.55q.9 cycle <-> profile lockstep + once-per-cycle', () {
    Future<String> activeBusinessDate() async {
      final date = await BusinessDateAuthorityService.instance
          .resolvePlanningAnchorDate('demo_restaurant_001');
      expect(date, isNotNull,
          reason: 'replay seed must yield a planning anchor date');
      return date!;
    }

    test('after Done with a selection, cycle.targetCPLH == profile.targetCPLH',
        () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance.saveSelection({
        candidates[0].recordKey,
        candidates[1].recordKey,
      });

      final cycle = await SqliteTargetCycleRepository.instance
          .getActiveCycle('demo_restaurant_001');
      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');

      expect(cycle, isNotNull);
      expect(profile, isNotNull);
      expect(cycle!.targetCPLH, closeTo(profile!.targetCPLH, 0.001),
          reason: 'cycle and profile must carry the same targetCPLH');
      expect(cycle.managerOverrideUsed, isTrue,
          reason: 'saveSelection now consumes the once-per-cycle rule');
      // `TargetCycleSource.managerOverride.label == 'manager_override'`.
      // The 'cycle_manager_override' string is the projected
      // ActiveTargetProfile.sourceType (see projector), NOT the cycle's
      // own enum label.
      expect(cycle.source, TargetCycleSource.managerOverride);
      expect(profile.sourceType, 'cycle_manager_override');
    });

    test('second saveSelection in the same cycle throws '
        'ManagerOverrideDeniedException', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      expect(
        () => BaselineManagerService.instance
            .saveSelection({candidates[1].recordKey}),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });

    test('resetForAdminTest clears the override flag + lets manager '
        'override again', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();

      // First override consumes the cycle's once-per-cycle allowance.
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});
      final cycleBefore = await SqliteTargetCycleRepository.instance
          .getActiveCycle('demo_restaurant_001');
      expect(cycleBefore!.managerOverrideUsed, isTrue);

      // Admin reset deactivates the cycle + clears the selection.
      await BaselineManagerService.instance.resetForAdminTest();

      final cycleAfterReset = await SqliteTargetCycleRepository.instance
          .getActiveCycle('demo_restaurant_001');
      expect(cycleAfterReset, isNotNull);
      expect(cycleAfterReset!.managerOverrideUsed, isFalse,
          reason: 'reset must rebuild a fresh cycle with the override '
              'flag cleared');
      expect(cycleAfterReset.cycleId, isNot(equals(cycleBefore.cycleId)),
          reason: 'a new cycle row must be written');

      // Manager can now override again without exception.
      await BaselineManagerService.instance
          .saveSelection({candidates[1].recordKey});
      final cycleAfterSecondOverride = await SqliteTargetCycleRepository
          .instance
          .getActiveCycle('demo_restaurant_001');
      expect(cycleAfterSecondOverride!.managerOverrideUsed, isTrue);
    });

    test('applyManagerOverrideCycle directly uses the same wire as '
        'saveSelection (contract check)', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      // Direct call should also hit the denial path.
      final businessDate = await activeBusinessDate();
      expect(
        () => TargetCycleService.instance
            .applyManagerOverrideCycle('demo_restaurant_001', businessDate),
        throwsA(isA<ManagerOverrideDeniedException>()),
      );
    });
  });
}
