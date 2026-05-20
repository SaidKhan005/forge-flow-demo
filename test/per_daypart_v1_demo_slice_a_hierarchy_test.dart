// Per-Daypart Targets V1 — Demo data Slice A regression test.
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md
//            (§1.6, §1.7, §2c, "Slice A" in §5); CLAUDE.md HP #2 + #11.
//
// What this guards: the demo used to seed ONE `restaurant_locations`
// row ("Barrio Legado", demo_restaurant_001) with no org hierarchy,
// so the scope drawer was a one-item list and every HP #11
// scope/inherited/effective surface was trivial. Slice A seeds the
// full §2c hierarchy:
//
//   Barrio Hospitality Group            (corp, operator-web fixture)
//   ├── East Region                     (region)
//   │   ├── Barrio Legado — Downtown     (demo_restaurant_001)
//   │   └── Metro District               (district)
//   │       └── Barrio Legado — North Loop
//   └── West Region                     (region)
//       ├── Barrio Legado — Riverside
//       └── Barrio Legado — Harbour
//
// HP #2: same `restaurant_locations` table, no `demo_*` table, no new
// `kDemoMode` reader branch. The mobile app has no SQLite `org_units`
// table — multi-location scope is multiple `restaurant_locations`
// rows + `BusinessScope`; the org tree lives in the operator-web
// fixture. Determinism: reseed yields the same rows.
//
// 2026-05-19 update: R6 ("Choose Star Shifts: 4-period demo operator",
// PR #929) added a 5th `restaurant_locations` row —
// `demo_restaurant_four_period`, the "Barrio Legado: Four-Period"
// proof restaurant. It is intentionally NOT a `DemoScope.locations`
// member (per-location replay/operational loops iterate
// `DemoScope.locations` and skip it), but the SQLite
// `restaurant_locations` table now seeds 4 §2c locations + 1 proof
// location = 5 rows. The org-tree fixture (operator-web side) is
// unchanged at 4 — four_period has no entry in
// `kDemoTeamLocationsFixture` because it lives outside the §2c
// hierarchy. Tests that count rows in `restaurant_locations` (or
// query the scope-drawer that reads that table) must include
// `demo_restaurant_four_period`; tests that count `DemoScope.locations`
// stay at 4.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';

const String _kDemoFourPeriodRestaurantId = 'demo_restaurant_four_period';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  group('Slice A — mobile multi-location seed (restaurant_locations)', () {
    test(
        'seeds the 4 §2c locations incl. demo_restaurant_001 + the R6 '
        'four-period proof location',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations');
      final byId = {
        for (final r in rows) r['restaurant_id'] as String: r,
      };

      expect(rows.length, 5,
          reason: '§2c demo hierarchy seeds 4 locations '
              '(Downtown/North Loop/Riverside/Harbour) plus the R6 '
              'four-period proof restaurant (not a DemoScope.locations '
              'member, but seeded into the same table)');
      expect(
        byId.keys.toSet(),
        {
          DemoScope.downtownRestaurantId,
          DemoScope.northLoopRestaurantId,
          DemoScope.riversideRestaurantId,
          DemoScope.harbourRestaurantId,
          _kDemoFourPeriodRestaurantId,
        },
      );

      // Backward compat: Downtown stays demo_restaurant_001 with the
      // exact 'Barrio Legado' display name every existing
      // test/DemoScope assertion depends on.
      expect(DemoScope.downtownRestaurantId, 'demo_restaurant_001');
      expect(
        byId[DemoScope.restaurantId]!['display_name'],
        'Barrio Legado',
      );
      expect(
        byId[DemoScope.restaurantId]!['business_timezone'],
        'America/St_Johns',
      );
    });

    test('reseed is deterministic — same 5 rows, no duplicates', () async {
      await SqliteDatabase.instance.reseedDemo();
      await SqliteDatabase.instance.reseedDemo();
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations');
      expect(rows.length, 5,
          reason: 'ConflictAlgorithm.ignore keeps the seed idempotent '
              '(4 §2c locations + four-period proof)');
    });

    // Regression (orchestrator audit fix): a demo DB that predates the
    // multi-location build has ONLY Downtown in `restaurant_locations`.
    // The old `if (existing.isEmpty)` guard (Downtown-keyed) was FALSE in
    // that state, so North Loop / Riverside / Harbour were never
    // backfilled and the scope drawer stayed a 1-item list forever.
    // The guard is now removed; `_seedDemoRestaurant` is idempotent, so
    // the ensure path must backfill the 3 missing rows on next reseed.
    test(
        'upgrade path: Downtown-only DB backfills all 4 §2c locations + '
        'the four-period proof', () async {
      final db = await SqliteDatabase.instance.database;
      // Simulate the stale pre-multi-location state.
      await db.delete(
        'restaurant_locations',
        where: 'restaurant_id != ?',
        whereArgs: [DemoScope.downtownRestaurantId],
      );
      expect(
        (await db.query('restaurant_locations')).length,
        1,
        reason: 'precondition: only Downtown present (upgrade state)',
      );

      // Routes through the now-unconditional `_seedDemoRestaurant`
      // (the guard site that previously skipped backfill).
      await SqliteDatabase.instance
          .reseedMockReplayForBusinessDate('2026-05-15');

      final rows = await db.query('restaurant_locations');
      final ids = {for (final r in rows) r['restaurant_id'] as String};
      expect(
        ids,
        {
          DemoScope.downtownRestaurantId,
          DemoScope.northLoopRestaurantId,
          DemoScope.riversideRestaurantId,
          DemoScope.harbourRestaurantId,
          _kDemoFourPeriodRestaurantId,
        },
        reason: 'all 4 §2c locations + the four-period proof location '
            'restored for an existing demo user',
      );
    });
  });

  group('Slice A — scope drawer becomes a real switcher', () {
    test(
        'RestaurantScopeNotifier.availableScopes surfaces all 5 seeded '
        'locations with Downtown still the default active scope',
        () async {
      final notifier = RestaurantScopeNotifier();
      addTearDown(notifier.dispose);
      await notifier.refresh();

      final scopes = notifier.availableScopes;
      expect(scopes.length, 5,
          reason: 'drawer must list every seeded location so it is a '
              'true switcher (§1.6) — includes the four-period proof '
              'restaurant alongside the 4 §2c locations');
      expect(
        scopes.map((s) => s.locationId).toSet(),
        {
          DemoScope.downtownRestaurantId,
          DemoScope.northLoopRestaurantId,
          DemoScope.riversideRestaurantId,
          DemoScope.harbourRestaurantId,
          _kDemoFourPeriodRestaurantId,
        },
      );
      expect(scopes.every((s) => s.isLocationScope), isTrue);

      // Downtown remains the resolved active location (backward
      // compat: getOrCreateActiveRestaurant defaults to
      // DemoScope.restaurantId).
      expect(notifier.activeLocationId, DemoScope.restaurantId);
    });
  });

  group('Slice A — operator-web org tree matches §2c', () {
    test('corp root + 2 regions + 1 district, 4 locations, aligned tree',
        () {
      final orgById = {
        for (final o in kDemoTeamOrgUnitsFixture) o.orgUnitId: o,
      };
      // corp → 2 regions → 1 district = 4 org units.
      expect(kDemoTeamOrgUnitsFixture.length, 4);
      expect(
        orgById.values.where((o) => o.unitType == 'corp').length,
        1,
      );
      expect(
        orgById.values.where((o) => o.unitType == 'region').length,
        2,
      );
      final districts =
          orgById.values.where((o) => o.unitType == 'district').toList();
      expect(districts.length, 1);

      // Metro District nests under East Region (depth-3 path for §1.7
      // inheritance demonstrability).
      final metro = districts.single;
      expect(metro.orgUnitId, 'demo-org-metro');
      expect(metro.parentOrgUnitId, 'demo-org-east');
      expect(metro.path, 'demo_bistro.east_region.metro_district');

      // 4 locations aligned with the mobile DemoScope.locations count.
      expect(kDemoTeamLocationsFixture.length, 4);
      expect(kDemoTeamLocationsFixture.length, DemoScope.locations.length);
      final locByName = {
        for (final l in kDemoTeamLocationsFixture) l.name: l,
      };
      expect(
        locByName.keys.toSet(),
        {'Downtown', 'North Loop', 'Riverside', 'Harbour'},
      );

      // North Loop sits under Metro District; Harbour rolls straight
      // up to West Region (the no-district inheritance path).
      expect(locByName['North Loop']!.orgUnitId, 'demo-org-metro');
      expect(locByName['Harbour']!.orgUnitId, 'demo-org-west');
      expect(locByName['Downtown']!.orgUnitId, 'demo-org-east');
      expect(locByName['Riverside']!.orgUnitId, 'demo-org-west');
    });
  });
}
