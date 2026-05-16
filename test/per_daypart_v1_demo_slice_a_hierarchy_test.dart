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

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  group('Slice A — mobile multi-location seed (restaurant_locations)', () {
    test('seeds exactly the 4 §2c locations incl. demo_restaurant_001',
        () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations');
      final byId = {
        for (final r in rows) r['restaurant_id'] as String: r,
      };

      expect(rows.length, 4,
          reason: '§2c demo hierarchy seeds 4 locations '
              '(Downtown/North Loop/Riverside/Harbour)');
      expect(
        byId.keys.toSet(),
        {
          DemoScope.downtownRestaurantId,
          DemoScope.northLoopRestaurantId,
          DemoScope.riversideRestaurantId,
          DemoScope.harbourRestaurantId,
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

    test('reseed is deterministic — same 4 rows, no duplicates', () async {
      await SqliteDatabase.instance.reseedDemo();
      await SqliteDatabase.instance.reseedDemo();
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_locations');
      expect(rows.length, 4,
          reason: 'ConflictAlgorithm.ignore keeps the seed idempotent');
    });

    // Regression (orchestrator audit fix): a demo DB that predates the
    // multi-location build has ONLY Downtown in `restaurant_locations`.
    // The old `if (existing.isEmpty)` guard (Downtown-keyed) was FALSE in
    // that state, so North Loop / Riverside / Harbour were never
    // backfilled and the scope drawer stayed a 1-item list forever.
    // The guard is now removed; `_seedDemoRestaurant` is idempotent, so
    // the ensure path must backfill the 3 missing rows on next reseed.
    test('upgrade path: Downtown-only DB backfills all 4 locations',
        () async {
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
        },
        reason: 'all 4 §2c locations restored for an existing demo user',
      );
    });
  });

  group('Slice A — scope drawer becomes a real switcher', () {
    test(
        'RestaurantScopeNotifier.availableScopes surfaces all 4 locations '
        'with Downtown still the default active scope', () async {
      final notifier = RestaurantScopeNotifier();
      addTearDown(notifier.dispose);
      await notifier.refresh();

      final scopes = notifier.availableScopes;
      expect(scopes.length, 4,
          reason: 'drawer must list every seeded location so it is a '
              'true switcher (§1.6)');
      expect(
        scopes.map((s) => s.locationId).toSet(),
        {
          DemoScope.downtownRestaurantId,
          DemoScope.northLoopRestaurantId,
          DemoScope.riversideRestaurantId,
          DemoScope.harbourRestaurantId,
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
