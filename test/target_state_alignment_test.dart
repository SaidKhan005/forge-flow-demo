// Phase 7.5b â€” Target state alignment tests.
//
// Validates:
// A. Active target profile persists current effective baseline state
// B. Manager override refreshes active target profile state
// C. Close shift locks a target profile version
// D. Historical shift truth does not drift after active target changes
// E. Historical week truth does not drift after active target changes

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/data/shift_service.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
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
    test('initial profile matches current BaselineData + MeridianConfig',
        () async {
      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profile, isNotNull);
      expect(profile!.targetCPLH,
          closeTo(BaselineData.derivedTargetCPLH, 0.001));
      expect(profile.targetSPLH,
          closeTo(BaselineData.derivedTargetSPLH, 0.001));
      expect(profile.targetPPA,
          closeTo(BaselineData.derivedTargetPPA, 0.001));
      expect(profile.fohWage, MeridianConfig.fohWage);
      expect(profile.bohWage, MeridianConfig.bohWage);
      expect(profile.sourceType, 'system_baseline');
    });
  });

  // â”€â”€ B: Manager override refreshes active target profile state â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” override refreshes profile', () {
    test('sourceType becomes manager_override after selection', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profile, isNotNull);
      expect(profile!.sourceType, 'manager_override');
      expect(profile.targetCPLH,
          closeTo(BaselineData.derivedTargetCPLH, 0.001));
    });

    test('clearing override restores system_baseline', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      await BaselineManagerService.instance.saveSelection({});

      final profile =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profile!.sourceType, 'system_baseline');
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
      final originalTargetFohHours = w13.targetFohHours;

      // Change active targets
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey, candidates[1].recordKey});

      // Re-read the stored week from DB
      final weeksAfter = await ShiftService.instance.getWeekHistory();
      final w13After = weeksAfter.firstWhere((w) => w.weekId == '2026-W13');

      expect(w13After.targetCPLH, closeTo(originalTargetCPLH!, 0.001));
      expect(w13After.targetFohHours, originalTargetFohHours);
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
      // Read initial persisted profile
      final profileBefore =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profileBefore!.sourceType, 'system_baseline');

      // Apply override through service path (which persists the profile)
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      // Re-read persisted profile â€” should reflect override
      final profileAfter =
          await profileRepo.getActiveTargetProfile('demo_restaurant_001');
      expect(profileAfter!.sourceType, 'manager_override');

      // The persisted state changed without needing BaselineData.revision
      // as the propagation authority
      expect(profileAfter.targetCPLH, isNot(equals(0)));
    });
  });
}
