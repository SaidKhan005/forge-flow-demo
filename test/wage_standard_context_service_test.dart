// Phase 7.55i.3 — Wage Standard Context Service tests.
//
// Validates:
// A. Resolve returns configFallback when no wage rows exist
// B. Resolve returns appConfiguredGenerator when wage rows exist
// C. FOH wage is weighted average of FOH rows only
// D. BOH wage is weighted average of BOH rows only
// E. Manager rows contribute to blended wage but not FOH/BOH
// F. Sync updates active profile wages and recomputes labor %
// G. Empty generator rows after delete → config fallback

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/wage_standard_context_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  // ── A: Config fallback when no rows ─────────────────────────────────────

  group('A — config fallback', () {
    test('resolve returns configFallback when no wage rows exist', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      // Ensure no wage rows
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);
      expect(ctx.fohWage, isNotNull);
      expect(ctx.bohWage, isNotNull);
      expect(ctx.referenceBlendedWage, isNull);
      expect(ctx.isAvailable, isTrue);
    });
  });

  // ── B: App configured generator ─────────────────────────────────────────

  group('B — app configured generator', () {
    test('resolve returns appConfiguredGenerator when rows exist', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 15.00,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 20.00,
        weightedHours: 35,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);
      expect(ctx.source, WageStandardSource.appConfiguredGenerator);
      expect(ctx.fohWage, closeTo(15.00, 0.01));
      expect(ctx.bohWage, closeTo(20.00, 0.01));
      expect(ctx.referenceBlendedWage, isNotNull);
    });
  });

  // ── C: FOH wage is weighted average of FOH rows ─────────────────────────

  group('C — FOH weighted average', () {
    test('FOH wage from multiple FOH rows', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 14.00,
        weightedHours: 40,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Bartender',
        laborBucket: 'foh',
        hourlyRate: 18.00,
        weightedHours: 20,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 20.00,
        weightedHours: 35,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);

      // FOH weighted avg = (14*40 + 18*20) / (40+20) = (560+360)/60 = 15.33
      expect(ctx.fohWage, closeTo(15.33, 0.01));
      expect(ctx.bohWage, closeTo(20.00, 0.01));
    });
  });

  // ── D: BOH wage is weighted average of BOH rows ─────────────────────────

  group('D — BOH weighted average', () {
    test('BOH wage from multiple BOH rows', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 16.00,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 19.00,
        weightedHours: 35,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Prep Cook',
        laborBucket: 'boh',
        hourlyRate: 17.00,
        weightedHours: 20,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);

      // BOH weighted avg = (19*35 + 17*20) / (35+20) = (665+340)/55 = 18.27
      expect(ctx.bohWage, closeTo(18.27, 0.01));
      expect(ctx.fohWage, closeTo(16.00, 0.01));
    });
  });

  // ── E: Manager rows contribute to blended only ──────────────────────────

  group('E — manager handling', () {
    test('manager rows in blended but not FOH/BOH', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 15.00,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 20.00,
        weightedHours: 35,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Kitchen Manager',
        laborBucket: 'manager',
        hourlyRate: 28.00,
        weightedHours: 45,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);

      // FOH = 15.00 (only Server)
      expect(ctx.fohWage, closeTo(15.00, 0.01));
      // BOH = 20.00 (only Line Cook)
      expect(ctx.bohWage, closeTo(20.00, 0.01));

      // Blended = (15*30 + 20*35 + 28*45) / (30+35+45)
      //         = (450 + 700 + 1260) / 110 = 2410 / 110 = 21.91
      expect(ctx.referenceBlendedWage, closeTo(21.91, 0.01));
    });

    test('manager-only rows: degrades to configFallback', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'GM',
        laborBucket: 'manager',
        hourlyRate: 30.00,
        weightedHours: 45,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);

      // Incomplete generator (no FOH or BOH rows) degrades to
      // configFallback so provenance and in-force standards stay honest.
      expect(ctx.source, WageStandardSource.configFallback);
      expect(ctx.fohWage, isNotNull);
      expect(ctx.bohWage, isNotNull);
    });

    test('single-bucket (FOH only) degrades to configFallback', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 15.00,
        weightedHours: 30,
      ));

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);

      // Only FOH rows — incomplete generator degrades to configFallback.
      expect(ctx.source, WageStandardSource.configFallback);
      expect(ctx.fohWage, isNotNull);
      expect(ctx.bohWage, isNotNull);
    });
  });

  // ── F: Sync updates active profile ─────────────────────────────────────

  group('F — sync to active profile', () {
    test('sync updates profile wages and recomputes theoretical labor %',
        () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Get profile before sync
      final before = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(before, isNotNull);

      // Add generator rows with different wages
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18.00, // Higher than MeridianConfig.fohWage (16.50)
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 23.00, // Higher than MeridianConfig.bohWage (21.35)
        weightedHours: 35,
      ));

      // Sync
      await WageStandardContextService.instance.syncWagesToActiveProfile();

      // Verify profile updated
      final after = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(after, isNotNull);
      expect(after!.fohWage, closeTo(18.00, 0.01));
      expect(after.bohWage, closeTo(23.00, 0.01));

      // Theoretical labor % should be higher with higher wages
      expect(after.theoreticalLaborPct,
          greaterThan(before!.theoreticalLaborPct));

      // FOH theoretical = fohWage / (CPLH * PPA) * 100
      final expectedFohPct =
          18.00 / (after.targetCPLH * after.targetPPA) * 100;
      expect(after.theoreticalFohLaborPct, closeTo(expectedFohPct, 0.01));

      // BOH theoretical = bohWage / SPLH * 100
      final expectedBohPct = 23.00 / after.targetSPLH * 100;
      expect(after.theoreticalBohLaborPct, closeTo(expectedBohPct, 0.01));
    });

    test('sync skips when wages match', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      // Clear any leftover generator rows so reseed uses config defaults
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
      // Reseed to guarantee a clean profile with config-fallback wages
      await SqliteDatabase.instance.reseedDemo();

      // No rows → config fallback → wages match initial profile
      // Sync should be a no-op
      final before = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      await WageStandardContextService.instance.syncWagesToActiveProfile();
      final after = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);

      expect(after!.fohWage, equals(before!.fohWage));
      expect(after.bohWage, equals(before.bohWage));
      expect(after.theoreticalLaborPct, equals(before.theoreticalLaborPct));
    });
  });

  // ── G: Delete rows returns to config fallback ──────────────────────────

  group('G — delete returns to fallback', () {
    test('deleting all rows returns to configFallback', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      // Add complete generator (FOH + BOH) then delete
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 15.00,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 20.00,
        weightedHours: 35,
      ));
      var ctx =
          await WageStandardContextService.instance.resolve(restaurantId);
      expect(ctx.source, WageStandardSource.appConfiguredGenerator);

      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
      ctx = await WageStandardContextService.instance.resolve(restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);
    });
  });

  // ── H: Provenance enum semantics ────────────────────────────────────────

  group('H — provenance semantics', () {
    test('displayLabel returns correct labels', () {
      expect(WageStandardSource.laborDerivedFromActualDollars.displayLabel,
          contains('Actual'));
      expect(WageStandardSource.appConfiguredGenerator.displayLabel,
          equals('App Configured'));
      expect(WageStandardSource.configFallback.displayLabel,
          equals('Config Default'));
      expect(WageStandardSource.unavailable.displayLabel,
          equals('Unavailable'));
    });

    test('isAvailable and isLaborDerived', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      final ctx =
          await WageStandardContextService.instance.resolve(restaurantId);
      expect(ctx.isAvailable, isTrue);
      expect(ctx.isLaborDerived, isFalse);
    });
  });

  // ── I: Bootstrap uses wage authority ─────────────────────────────────────

  group('I — bootstrap uses wage authority', () {
    test('loadOrBootstrapProfile prefers the active cycle projection when a cycle exists',
        () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final seeded = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(seeded, isNotNull);

      // Add generator rows with different wages. These should not
      // override the active cycle when the cycle already exists.
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18.50,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 22.00,
        weightedHours: 35,
      ));

      // Delete the persisted profile row to force a bootstrap read.
      final db = await SqliteDatabase.instance.database;
      await db.delete('active_target_profiles');

      final profile = await WageStandardContextService.instance
          .loadOrBootstrapProfile(restaurantId);

      expect(profile.sourceType, equals(seeded!.sourceType));
      expect(profile.fohWage, closeTo(seeded.fohWage, 0.01));
      expect(profile.bohWage, closeTo(seeded.bohWage, 0.01));
    });

    test('loadOrBootstrapProfile returns existing profile when available',
        () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Profile already seeded by reseedDemo
      final profile = await WageStandardContextService.instance
          .loadOrBootstrapProfile(restaurantId);
      expect(profile, isNotNull);
      expect(profile.restaurantId, restaurantId);
    });
  });

  // ── J: Reseed preserves wage authority ──────────────────────────────────

  group('J — reseed preserves wage authority', () {
    test('reseedDemo preserves generator rows and uses them in profile',
        () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();

      // Add generator rows BEFORE reseed
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 19.00,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 24.00,
        weightedHours: 35,
      ));

      // Reseed — should NOT delete wage_role_rows and SHOULD use them
      await SqliteDatabase.instance.reseedDemo();

      // Verify rows survived
      final rows =
          await SqliteWageRoleRowRepository.instance.getRows(restaurantId);
      expect(rows.length, 2);

      // Verify the reseeded profile uses generator wages
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, closeTo(19.00, 0.01));
      expect(profile.bohWage, closeTo(24.00, 0.01));
    });
  });

  // ── K: WageMixSetupSummary — whole-mix setup helper (7.55p.5f1) ────────

  group('K — summarizeMix (whole-mix setup helper)', () {
    test('empty rows → isEmpty true, hasCompleteFohBoh false, zero totals', () {
      final summary = WageStandardContextService.summarizeMix(const []);
      expect(summary.isEmpty, isTrue);
      expect(summary.hasCompleteFohBoh, isFalse);
      expect(summary.fohRows, isEmpty);
      expect(summary.bohRows, isEmpty);
      expect(summary.managerRows, isEmpty);
      expect(summary.totalWeightedHours, 0);
      expect(summary.totalHourlyCost, 0);
    });

    test('FOH + BOH rows → hasCompleteFohBoh true', () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.00,
          weightedHours: 30,
        ),
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.hasCompleteFohBoh, isTrue);
      expect(summary.fohRows.length, 1);
      expect(summary.bohRows.length, 1);
      expect(summary.managerRows, isEmpty);
      // totalCost = 16*30 + 20*35 = 480 + 700 = 1180
      expect(summary.totalHourlyCost, closeTo(1180.0, 0.01));
      // totalHours = 30 + 35 = 65
      expect(summary.totalWeightedHours, closeTo(65.0, 0.01));
    });

    test('FOH only → hasCompleteFohBoh false (mirrors resolve rule)', () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.00,
          weightedHours: 30,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.hasCompleteFohBoh, isFalse);
      expect(summary.isEmpty, isFalse);
    });

    test('BOH only → hasCompleteFohBoh false (mirrors resolve rule)', () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.hasCompleteFohBoh, isFalse);
      expect(summary.isEmpty, isFalse);
    });

    test('manager-only → hasCompleteFohBoh false, counted in totals', () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Manager',
          laborBucket: 'manager',
          hourlyRate: 28.00,
          weightedHours: 45,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.hasCompleteFohBoh, isFalse);
      expect(summary.fohRows, isEmpty);
      expect(summary.bohRows, isEmpty);
      expect(summary.managerRows.length, 1);
      // Manager rows still count toward total cost and hours.
      expect(summary.totalHourlyCost, closeTo(1260.0, 0.01));
      expect(summary.totalWeightedHours, closeTo(45.0, 0.01));
    });

    test('mixed FOH + BOH + manager → complete, manager included in totals',
        () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 15.00,
          weightedHours: 30,
        ),
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ),
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Kitchen Manager',
          laborBucket: 'manager',
          hourlyRate: 28.00,
          weightedHours: 45,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.hasCompleteFohBoh, isTrue);
      expect(summary.fohRows.length, 1);
      expect(summary.bohRows.length, 1);
      expect(summary.managerRows.length, 1);
      // totalCost = 15*30 + 20*35 + 28*45 = 450 + 700 + 1260 = 2410
      expect(summary.totalHourlyCost, closeTo(2410.0, 0.01));
      // totalHours = 30 + 35 + 45 = 110
      expect(summary.totalWeightedHours, closeTo(110.0, 0.01));
    });

    test('grouping maps rows to the correct bucket list', () {
      final rows = [
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.00,
          weightedHours: 30,
        ),
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Bartender',
          laborBucket: 'foh',
          hourlyRate: 18.00,
          weightedHours: 20,
        ),
        const WageRoleRow(
          restaurantId: 'r1',
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ),
      ];
      final summary = WageStandardContextService.summarizeMix(rows);
      expect(summary.fohRows.map((r) => r.roleName),
          containsAll(['Server', 'Bartender']));
      expect(summary.bohRows.map((r) => r.roleName), contains('Line Cook'));
      expect(summary.managerRows, isEmpty);
    });
  });

  // ── L: Override trickle — app-configured wages reach the profile (7.55p.5f1)

  group('L — override trickle to downstream consumers', () {
    test('complete FOH + BOH setup reaches ActiveTargetProfile with the '
        'same wages downstream consumers will read', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      // Persist a complete mix (FOH + BOH).
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 17.25,
        weightedHours: 30,
      ));
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 22.40,
        weightedHours: 35,
      ));

      // Resolve — same authority path the Settings UX uses.
      final ctx = await WageStandardContextService.instance
          .resolve(restaurantId);
      expect(ctx.source, WageStandardSource.appConfiguredGenerator);
      expect(ctx.fohWage, closeTo(17.25, 0.01));
      expect(ctx.bohWage, closeTo(22.40, 0.01));

      // Sync — same downstream push the Settings UX triggers.
      await WageStandardContextService.instance.syncWagesToActiveProfile();

      // Downstream profile that Benchmark, Variance, and Shift read.
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, closeTo(17.25, 0.01));
      expect(profile.bohWage, closeTo(22.40, 0.01));

      // Theoretical labor % on the profile is derived from the same
      // wages — this is the exact field Benchmark's TOTAL THEORETICAL %
      // and Variance's theoreticalLaborPct render.
      final expectedFoh =
          17.25 / (profile.targetCPLH * profile.targetPPA) * 100;
      final expectedBoh = 22.40 / profile.targetSPLH * 100;
      expect(profile.theoreticalFohLaborPct, closeTo(expectedFoh, 0.01));
      expect(profile.theoreticalBohLaborPct, closeTo(expectedBoh, 0.01));
      expect(profile.theoreticalLaborPct,
          closeTo(expectedFoh + expectedBoh, 0.01));
    });

    test('incomplete setup (manager only) does not override the profile '
        'with generator wages — authority falls back to config', () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);

      // Only a manager row — incomplete mix.
      await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
        restaurantId: restaurantId,
        roleName: 'GM',
        laborBucket: 'manager',
        hourlyRate: 30.00,
        weightedHours: 40,
      ));

      final ctx = await WageStandardContextService.instance
          .resolve(restaurantId);
      // Honesty rule: manager-only does not claim a full override.
      expect(ctx.source, WageStandardSource.configFallback);

      // Sync pushes config-default wages (not $30). The incomplete
      // setup cannot masquerade as an app-configured override.
      await WageStandardContextService.instance.syncWagesToActiveProfile();
      final profile = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(profile, isNotNull);
      // Wages must NOT be the $30 manager rate.
      expect(profile!.fohWage, lessThan(30.0));
      expect(profile.bohWage, lessThan(30.0));
    });
  });

  group('M — cycle-backed profile repair', () {
    test('loadOrBootstrapProfile repairs a stale persisted row from the cycle',
        () async {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      final seeded = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      expect(seeded, isNotNull);

      final stale = ActiveTargetProfile.build(
        restaurantId: restaurantId,
        sourceType: 'manager_override',
        targetCPLH: seeded!.targetCPLH + 1.25,
        targetSPLH: seeded.targetSPLH + 10,
        targetPPA: seeded.targetPPA + 3,
        fohWage: seeded.fohWage + 2,
        bohWage: seeded.bohWage + 2,
        opzFloorCPLH: seeded.opzFloorCPLH + 0.2,
        opzCeilingCPLH: seeded.opzCeilingCPLH + 0.2,
      );
      await SqliteTargetProfileRepository.instance
          .upsertActiveTargetProfile(stale);

      final repaired = await WageStandardContextService.instance
          .loadOrBootstrapProfile(restaurantId);

      expect(repaired.sourceType, equals(seeded.sourceType));
      expect(repaired.targetCPLH, closeTo(seeded.targetCPLH, 0.001));
      expect(repaired.targetSPLH, closeTo(seeded.targetSPLH, 0.001));
      expect(repaired.targetPPA, closeTo(seeded.targetPPA, 0.001));
      expect(repaired.fohWage, closeTo(seeded.fohWage, 0.001));
      expect(repaired.bohWage, closeTo(seeded.bohWage, 0.001));
    });
  });
}
