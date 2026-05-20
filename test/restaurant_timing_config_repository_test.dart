// Phase 7.55n.1 — Restaurant timing config persistence seam tests.
//
// Covers:
// A. Demo restaurant timing config exists after reseed
// B. Service-period definitions round-trip with stable order and weekday applicability
// C. Business timezone is composed from RestaurantLocation
// D. Active-restaurant timing config can be read through the runtime seam
// E. No current week / business-date behavior changes introduced
// F. ShiftCloseAuthority enum round-trips
// G. ServicePeriodDefinition model round-trips
// H. Schema table exists and is queryable

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/restaurant_timing_config_read_service.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';

void main() {
  setUp(() async {
    // Several tests below mutate the demo restaurant's timing config
    // (lunch/dinner/late_night.applicableDays, rollsPastMidnight) and
    // call `saveTimingConfig` to persist the mutation. `reseedDemo()`
    // uses `ConflictAlgorithm.ignore`, so once the row is overwritten
    // by a sibling test the reseed does NOT restore the original
    // applicableDays / rollsPastMidnight values. Under randomized test
    // ordering this surfaces as "lunch applies to all days 1-7"
    // returning `[1,2,3,4,5]` (a sibling test's weekday-only fixture).
    // Delete the timing-config rows first so `reseedDemo()` actually
    // re-inserts the canonical demo values for every test.
    final db = await SqliteDatabase.instance.database;
    await db.delete('restaurant_timing_configs');
    await SqliteDatabase.instance.reseedDemo();
    SqliteRestaurantTimingConfigRepository.instance.resetDao();
  });

  // ── A: Demo timing config exists after reseed ─────────────────────────────

  group('A — demo timing config exists', () {
    test('demo restaurant has a timing config after reseed', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig('demo_restaurant_001');
      expect(config, isNotNull);
      expect(config!.restaurantId, 'demo_restaurant_001');
      expect(config.businessDayStartLocalTime, '04:00');
      expect(config.weekStartDay, DateTime.monday);
      // Per-Daypart V1 Slice 1.5: `shiftCloseAuthority` /
      // `localCloseFallback` were dropped from RestaurantTimingConfig.
      // Close-authority is auto-derived per shift from
      // `lib/services/integration/close_authority_capability.dart`.
    });

    test('restaurant_timing_configs table is queryable', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query('restaurant_timing_configs');
      expect(rows, isNotEmpty);
    });

    test('unknown restaurant returns null', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig('nonexistent_restaurant');
      expect(config, isNull);
    });
  });

  // ── B: Service-period definitions round-trip ──────────────────────────────

  group('B — service-period definitions round-trip', () {
    test('three service periods seeded in correct sort order', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig('demo_restaurant_001');
      expect(config, isNotNull);

      final defs = config!.servicePeriodDefinitions;
      expect(defs.length, 3);
      expect(defs[0].id, 'lunch');
      expect(defs[1].id, 'dinner');
      expect(defs[2].id, 'late_night');

      // Sort order is monotonically increasing
      for (var i = 1; i < defs.length; i++) {
        expect(defs[i].sortOrder, greaterThan(defs[i - 1].sortOrder));
      }
    });

    test('lunch applies to all days 1-7', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig('demo_restaurant_001');
      final lunch = config!.servicePeriodDefinitions.firstWhere(
        (d) => d.id == 'lunch',
      );
      expect(lunch.applicableDays, [1, 2, 3, 4, 5, 6, 7]);
      expect(lunch.rollsPastMidnight, isFalse);
    });

    test('dinner applies to all days 1-7', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig('demo_restaurant_001');
      final dinner = config!.servicePeriodDefinitions.firstWhere(
        (d) => d.id == 'dinner',
      );
      expect(dinner.applicableDays, [1, 2, 3, 4, 5, 6, 7]);
      expect(dinner.rollsPastMidnight, isFalse);
    });

    test(
      'late_night applies to Fri-Sat (5-6) and rolls past midnight',
      () async {
        final repo = SqliteRestaurantTimingConfigRepository.instance;
        final config = await repo.getTimingConfig('demo_restaurant_001');
        final lateNight = config!.servicePeriodDefinitions.firstWhere(
          (d) => d.id == 'late_night',
        );
        expect(lateNight.applicableDays, [5, 6]);
        expect(lateNight.rollsPastMidnight, isTrue);
        expect(lateNight.startLocalTime, '23:00');
        expect(lateNight.endLocalTime, '02:00');
      },
    );

    test('save and re-read preserves all definition fields', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final original = await repo.getTimingConfig('demo_restaurant_001');
      expect(original, isNotNull);

      // Re-save the same config
      await repo.saveTimingConfig(original!);
      SqliteRestaurantTimingConfigRepository.instance.resetDao();
      final reread = await repo.getTimingConfig('demo_restaurant_001');

      expect(reread, isNotNull);
      expect(
        reread!.servicePeriodDefinitions.length,
        original.servicePeriodDefinitions.length,
      );
      for (var i = 0; i < original.servicePeriodDefinitions.length; i++) {
        expect(
          reread.servicePeriodDefinitions[i],
          original.servicePeriodDefinitions[i],
        );
      }
    });

    test('save and re-read preserves timing source provenance', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final original = await repo.getTimingConfig('demo_restaurant_001');
      expect(original, isNotNull);

      await repo.saveTimingConfig(
        RestaurantTimingConfig(
          restaurantId: 'demo_restaurant_001',
          businessTimezone: original!.businessTimezone,
          businessDayStartLocalTime: original.businessDayStartLocalTime,
          weekStartDay: original.weekStartDay,
          servicePeriodDefinitions: original.servicePeriodDefinitions,
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
          selectedScopeType: 'location',
          selectedScopeId: 'demo_restaurant_001',
          sourceScopeType: 'org_unit',
          sourceScopeId: 'district-1',
          sourceScopeLabel: 'Metro District',
          inheritedFromAncestor: true,
        ),
      );
      SqliteRestaurantTimingConfigRepository.instance.resetDao();
      final reread = await repo.getTimingConfig('demo_restaurant_001');

      expect(reread, isNotNull);
      expect(reread!.selectedScopeType, 'location');
      expect(reread.selectedScopeId, 'demo_restaurant_001');
      expect(reread.sourceScopeType, 'org_unit');
      expect(reread.sourceScopeId, 'district-1');
      expect(reread.sourceScopeLabel, 'Metro District');
      expect(reread.inheritedFromAncestor, isTrue);
    });
  });

  // ── C: Business timezone composed from RestaurantLocation ─────────────────

  group('C — timezone composition', () {
    test(
      'businessTimezone comes from RestaurantLocation, not timing table',
      () async {
        final repo = SqliteRestaurantTimingConfigRepository.instance;
        final config = await repo.getTimingConfig('demo_restaurant_001');
        expect(config, isNotNull);
        // America/St_Johns is the demo restaurant's timezone on RestaurantLocation
        expect(config!.businessTimezone, 'America/St_Johns');
      },
    );

    test(
      'timing config table row does not contain a timezone column',
      () async {
        final db = await SqliteDatabase.instance.database;
        final columns = await db.rawQuery(
          'PRAGMA table_info(restaurant_timing_configs)',
        );
        final colNames = columns.map((c) => c['name'] as String).toList();
        expect(colNames, isNot(contains('business_timezone')));
      },
    );

    test(
      'save hydrates RestaurantLocation timezone from server config',
      () async {
        final repo = SqliteRestaurantTimingConfigRepository.instance;
        final original = await repo.getTimingConfig('demo_restaurant_001');
        expect(original, isNotNull);

        await repo.saveTimingConfig(
          RestaurantTimingConfig(
            restaurantId: 'live-location-1',
            businessTimezone: 'America/Toronto',
            businessDayStartLocalTime: original!.businessDayStartLocalTime,
            weekStartDay: original.weekStartDay,
            servicePeriodDefinitions: original.servicePeriodDefinitions,
            createdAt: '2026-05-07T00:00:00.000Z',
            updatedAt: '2026-05-07T00:00:00.000Z',
          ),
        );

        SqliteRestaurantTimingConfigRepository.instance.resetDao();
        final saved = await repo.getTimingConfig('live-location-1');

        expect(saved, isNotNull);
        expect(saved!.businessTimezone, 'America/Toronto');
      },
    );
  });

  // ── D: Runtime read seam works ────────────────────────────────────────────

  group('D — runtime read seam', () {
    test('RestaurantTimingConfigReadService returns active config', () async {
      final service = RestaurantTimingConfigReadService.instance;
      final config = await service.getActiveTimingConfig();
      expect(config, isNotNull);
      expect(config!.restaurantId, 'demo_restaurant_001');
      expect(config.businessDayStartLocalTime, '04:00');
      expect(config.weekStartDay, DateTime.monday);
      expect(config.servicePeriodDefinitions, isNotEmpty);
    });

    test('getTimingConfig by explicit restaurantId works', () async {
      final service = RestaurantTimingConfigReadService.instance;
      final config = await service.getTimingConfig('demo_restaurant_001');
      expect(config, isNotNull);
      expect(config!.businessTimezone, 'America/St_Johns');
    });
  });

  // ── E: No business-date or week-start behavior changes ────────────────────

  group('E — no behavior changes', () {
    test('WeeklyPlanSnapshotPolicy still defaults to Monday', () {
      // This proves the persistence seam did not rewire the policy.
      // 2026-04-08 is a Wednesday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate('2026-04-08'),
        '2026-04-06', // Monday
      );
    });

    test('week-start derivation unchanged for Sunday-start', () {
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate(
          '2026-04-08',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-05',
      );
    });
  });

  // ── F: ShiftCloseAuthority enum round-trips ───────────────────────────────

  group('F — ShiftCloseAuthority enum', () {
    test('vendor_finalization round-trips', () {
      expect(
        ShiftCloseAuthority.fromValue('vendor_finalization'),
        ShiftCloseAuthority.vendorFinalization,
      );
      expect(
        ShiftCloseAuthority.vendorFinalization.value,
        'vendor_finalization',
      );
    });

    test('app_local_cutoff_fallback round-trips', () {
      expect(
        ShiftCloseAuthority.fromValue('app_local_cutoff_fallback'),
        ShiftCloseAuthority.appLocalCutoffFallback,
      );
      expect(
        ShiftCloseAuthority.appLocalCutoffFallback.value,
        'app_local_cutoff_fallback',
      );
    });

    test('unknown value throws ArgumentError', () {
      expect(
        () => ShiftCloseAuthority.fromValue('unknown'),
        throwsArgumentError,
      );
    });
  });

  // ── G: ServicePeriodDefinition model round-trips ──────────────────────────

  group('G — ServicePeriodDefinition model', () {
    test('toMap/fromMap round-trip preserves all fields', () {
      const original = ServicePeriodDefinition(
        id: 'brunch',
        label: 'Brunch',
        shortLabel: 'BR',
        sortOrder: 0,
        startLocalTime: '09:00',
        endLocalTime: '14:00',
        rollsPastMidnight: false,
        applicableDays: [6, 7],
      );
      final map = original.toMap();
      final restored = ServicePeriodDefinition.fromMap(map);
      expect(restored, original);
    });

    test('equality considers all fields', () {
      const a = ServicePeriodDefinition(
        id: 'test',
        label: 'Test',
        shortLabel: 'T',
        sortOrder: 1,
        startLocalTime: '10:00',
        endLocalTime: '14:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3],
      );
      const b = ServicePeriodDefinition(
        id: 'test',
        label: 'Test',
        shortLabel: 'T',
        sortOrder: 1,
        startLocalTime: '10:00',
        endLocalTime: '14:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2, 3],
      );
      const c = ServicePeriodDefinition(
        id: 'test',
        label: 'Test',
        shortLabel: 'T',
        sortOrder: 1,
        startLocalTime: '10:00',
        endLocalTime: '14:00',
        rollsPastMidnight: false,
        applicableDays: [1, 2], // different
      );
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  // ── H: Schema table exists ────────────────────────────────────────────────

  group('H — schema validation', () {
    test('restaurant_timing_configs table has expected columns', () async {
      final db = await SqliteDatabase.instance.database;
      final columns = await db.rawQuery(
        'PRAGMA table_info(restaurant_timing_configs)',
      );
      final colNames = columns.map((c) => c['name'] as String).toSet();
      expect(
        colNames,
        containsAll([
          'restaurant_id',
          'business_day_start_local_time',
          'week_start_day',
          'service_period_definitions_json',
          'created_at',
          'updated_at',
        ]),
      );
      // Per-Daypart V1 Slice 1.5: `shift_close_authority` +
      // `local_close_fallback` dropped (operator decision 2026-05-15).
      expect(colNames, isNot(contains('shift_close_authority')));
      expect(colNames, isNot(contains('local_close_fallback')));
    });
  });

  // ── I: No demo-timezone fallback ─────────────────────────────────────────

  group('I — no demo-timezone fallback', () {
    test(
      'returns null when timing row exists but restaurant location is missing',
      () async {
        final db = await SqliteDatabase.instance.database;

        // Insert a timing-config row for a restaurant that has no location row.
        await db.insert('restaurant_timing_configs', {
          'restaurant_id': 'orphan_restaurant',
          'business_day_start_local_time': '04:00',
          'week_start_day': 1,
          'service_period_definitions_json': '[]',
          'created_at': '2026-04-13T00:00:00Z',
          'updated_at': '2026-04-13T00:00:00Z',
        });

        final repo = SqliteRestaurantTimingConfigRepository.instance;
        repo.resetDao();
        final config = await repo.getTimingConfig('orphan_restaurant');

        // Must return null — no demo-timezone fallback.
        expect(config, isNull);
      },
    );

    test(
      'demo restaurant still resolves because its location row exists',
      () async {
        final repo = SqliteRestaurantTimingConfigRepository.instance;
        final config = await repo.getTimingConfig('demo_restaurant_001');
        expect(config, isNotNull);
        expect(config!.businessTimezone, 'America/St_Johns');
      },
    );
  });

  // ── J: Service-period canonicalization ────────────────────────────────────

  group('J — service-period canonicalization', () {
    test(
      'unordered definitions are persisted in canonical sortOrder/id order',
      () async {
        final repo = SqliteRestaurantTimingConfigRepository.instance;

        // Build definitions deliberately out of canonical order.
        const defs = [
          ServicePeriodDefinition(
            id: 'dinner',
            label: 'Dinner',
            shortLabel: 'D',
            sortOrder: 1,
            startLocalTime: '17:00',
            endLocalTime: '23:00',
            rollsPastMidnight: false,
            applicableDays: [1, 2, 3, 4, 5, 6, 7],
          ),
          ServicePeriodDefinition(
            id: 'lunch',
            label: 'Lunch',
            shortLabel: 'L',
            sortOrder: 0,
            startLocalTime: '11:00',
            endLocalTime: '15:00',
            rollsPastMidnight: false,
            applicableDays: [1, 2, 3, 4, 5],
          ),
          ServicePeriodDefinition(
            id: 'late_night',
            label: 'Late Night',
            shortLabel: 'LN',
            sortOrder: 2,
            startLocalTime: '23:00',
            endLocalTime: '02:00',
            rollsPastMidnight: true,
            applicableDays: [5, 6],
          ),
        ];

        // Save with dinner first (out of order).
        final config = RestaurantTimingConfig(
          restaurantId: 'demo_restaurant_001',
          businessTimezone: 'America/St_Johns',
          businessDayStartLocalTime: '04:00',
          weekStartDay: 1,
          servicePeriodDefinitions: defs,
          createdAt: '2026-04-13T00:00:00Z',
          updatedAt: '2026-04-13T00:00:00Z',
        );
        await repo.saveTimingConfig(config);
        repo.resetDao();

        final reread = await repo.getTimingConfig('demo_restaurant_001');
        expect(reread, isNotNull);

        // Canonical order: lunch (sort 0), dinner (sort 1), late_night (sort 2).
        expect(reread!.servicePeriodDefinitions[0].id, 'lunch');
        expect(reread.servicePeriodDefinitions[1].id, 'dinner');
        expect(reread.servicePeriodDefinitions[2].id, 'late_night');
      },
    );

    test('same-sortOrder definitions break tie by id alphabetically', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;

      // Two definitions with the same sortOrder, out of alphabetical order.
      const defs = [
        ServicePeriodDefinition(
          id: 'brunch',
          label: 'Brunch',
          shortLabel: 'BR',
          sortOrder: 0,
          startLocalTime: '09:00',
          endLocalTime: '14:00',
          rollsPastMidnight: false,
          applicableDays: [6, 7],
        ),
        ServicePeriodDefinition(
          id: 'breakfast',
          label: 'Breakfast',
          shortLabel: 'BK',
          sortOrder: 0,
          startLocalTime: '07:00',
          endLocalTime: '10:00',
          rollsPastMidnight: false,
          applicableDays: [1, 2, 3, 4, 5],
        ),
      ];

      final config = RestaurantTimingConfig(
        restaurantId: 'demo_restaurant_001',
        businessTimezone: 'America/St_Johns',
        businessDayStartLocalTime: '04:00',
        weekStartDay: 1,
        servicePeriodDefinitions: defs,
        createdAt: '2026-04-13T00:00:00Z',
        updatedAt: '2026-04-13T00:00:00Z',
      );
      await repo.saveTimingConfig(config);
      repo.resetDao();

      final reread = await repo.getTimingConfig('demo_restaurant_001');
      expect(reread, isNotNull);

      // breakfast < brunch alphabetically, both sortOrder 0.
      expect(reread!.servicePeriodDefinitions[0].id, 'breakfast');
      expect(reread.servicePeriodDefinitions[1].id, 'brunch');
    });

    test('existing round-trip still holds after canonicalization', () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final original = await repo.getTimingConfig('demo_restaurant_001');
      expect(original, isNotNull);

      await repo.saveTimingConfig(original!);
      repo.resetDao();
      final reread = await repo.getTimingConfig('demo_restaurant_001');

      expect(reread, isNotNull);
      expect(
        reread!.servicePeriodDefinitions.length,
        original.servicePeriodDefinitions.length,
      );
      for (var i = 0; i < original.servicePeriodDefinitions.length; i++) {
        expect(
          reread.servicePeriodDefinitions[i],
          original.servicePeriodDefinitions[i],
        );
      }
    });
  });
}
