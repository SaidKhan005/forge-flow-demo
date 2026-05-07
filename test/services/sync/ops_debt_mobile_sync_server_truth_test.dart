// Theme H — mobile-sync server-truth lane.
//
// Verifies the dropped-server-fields fixes:
//   * H#4 / H#5 — wage_role_rows now consume server_id + 8 vendor /
//     audit columns the proxy already emits.
//   * H#6 — weekly_plan_snapshots payload preserves the 5 lifecycle
//     fields (is_active, supersedes_snapshot_id, lock_reason, metadata,
//     locked_by_user_id) the snapshot model previously dropped.
//   * H#7 — DAS service-period settings persistent SQLite cache.
//   * H#9 — `isBusinessScopeInvalidationEvent` flags the explicit
//     restaurant_users insert / update / delete signal.
//
// These tests do not exercise the proxy; they read fixture JSON in the
// shape the proxy emits today and assert the mobile parsers + caches
// hold every field.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/data_accuracy_service_period_settings_cache_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/wage_role_row_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/scope/business_scope_repository.dart';
import 'package:forge_and_flow/services/sync/weekly_plan_sync_resources.dart';

void main() {
  group('Theme H#5 — wage_role_rows DAO server_id roundtrip', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
      final db = await SqliteDatabase.instance.database;
      await db.delete('wage_role_rows', where: '1 = 1');
    });

    test('upsertRow with server_id mirrors the UUID into SQLite', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = WageRoleRowDao(db);
      final row = WageRoleRow(
        serverId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
        restaurantId: 'rest-h5',
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 18.25,
        weightedHours: 40.0,
        jobCode: 'JC-LINE',
        vendorId: 'seven_shifts',
        vendorRoleId: 'vendor-line-1',
        source: 'vendor_seven_shifts',
        isActive: true,
        effectiveAt: '2026-05-04T00:00:00.000Z',
        metadata: const <String, Object?>{'origin': 'mock'},
        updatedBy: 'admin-1',
      );

      await dao.upsertRow(row);
      final fetched = await dao.getRows('rest-h5');

      expect(fetched, hasLength(1));
      final stored = fetched.single;
      expect(stored.serverId, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1');
      expect(stored.jobCode, 'JC-LINE');
      expect(stored.vendorId, 'seven_shifts');
      expect(stored.vendorRoleId, 'vendor-line-1');
      expect(stored.source, 'vendor_seven_shifts');
      expect(stored.isActive, isTrue);
      expect(stored.effectiveAt, '2026-05-04T00:00:00.000Z');
      expect(stored.updatedBy, 'admin-1');
      expect(stored.metadata, isNotNull);
      expect(stored.metadata!['origin'], 'mock');
    });

    test(
      'upsertRow re-resolves on server_id when role_name changes',
      () async {
        final db = await SqliteDatabase.instance.database;
        final dao = WageRoleRowDao(db);
        const serverId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb2';
        await dao.upsertRow(
          const WageRoleRow(
            serverId: serverId,
            restaurantId: 'rest-h5',
            roleName: 'Server',
            laborBucket: 'foh',
            hourlyRate: 16.5,
            weightedHours: 30.0,
          ),
        );
        // Same server row, role_name renamed by an operator. Without
        // server_id matching, this would insert a duplicate.
        await dao.upsertRow(
          const WageRoleRow(
            serverId: serverId,
            restaurantId: 'rest-h5',
            roleName: 'Server (FOH)',
            laborBucket: 'foh',
            hourlyRate: 17.0,
            weightedHours: 30.0,
          ),
        );

        final fetched = await dao.getRows('rest-h5');
        expect(fetched, hasLength(1));
        expect(fetched.single.roleName, 'Server (FOH)');
        expect(fetched.single.hourlyRate, 17.0);
      },
    );
  });

  group('Theme H#6 — weekly_plan snapshot lifecycle fields', () {
    test(
      'WeeklyPlanSnapshotSyncRow.fromJson preserves the 5 server fields',
      () {
        final json = <String, dynamic>{
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'updated_at': '2026-05-06T12:00:00Z',
          'snapshot_id': 'wps-1',
          'restaurant_id': 'rest-h6',
          'week_start_date': '2026-05-04',
          'week_end_date': '2026-05-10',
          'target_cycle_id': 'cycle-1',
          'forecast_context_id': 'fc-1',
          'forecast_covers': 800,
          'forecast_sales': 33000.0,
          'required_foh_hours': 80,
          'required_boh_hours': 60,
          'theoretical_foh_labor_dollars': 1440.0,
          'theoretical_boh_labor_dollars': 1200.0,
          'covers_source': 'appDerivedFromHistoricalAverage',
          'sales_source': 'appDerivedFromCoversAndPpa',
          'generated_at': '2026-05-06T12:00:00Z',
          'locked_at': '2026-05-06T12:01:00Z',
          'day_rows': <Map<String, Object?>>[],
          // Theme H#6 — the 5 fields we are now consuming.
          'is_active': true,
          'supersedes_snapshot_id': 'wps-prev',
          'lock_reason': 'manager_locked_current_week',
          'locked_by_user_id': 'user-mgr-1',
          'metadata': <String, Object?>{'device_id': 'ipad-1'},
        };

        final row = WeeklyPlanSnapshotSyncRow.fromJson(json);

        expect(row.snapshot.isActive, isTrue);
        expect(row.snapshot.supersedesSnapshotId, 'wps-prev');
        expect(row.snapshot.lockReason, 'manager_locked_current_week');
        expect(row.snapshot.lockedByUserId, 'user-mgr-1');
        expect(row.snapshot.metadata, isNotNull);
        expect(row.snapshot.metadata!['device_id'], 'ipad-1');
      },
    );

    test('WeeklyPlanSnapshot.toMap roundtrips lifecycle fields', () {
      final snapshot = WeeklyPlanSnapshot(
        snapshotId: 'wps-2',
        restaurantId: 'rest-h6',
        weekStartDate: '2026-05-04',
        weekEndDate: '2026-05-10',
        targetCycleId: 'cycle-1',
        forecastContextId: 'fc-1',
        forecastCovers: 800,
        forecastSales: 33000.0,
        requiredFohHours: 80,
        requiredBohHours: 60,
        theoreticalFohLaborDollars: 1440.0,
        theoreticalBohLaborDollars: 1200.0,
        coversSource:
            ForecastDemandSource.appDerivedFromHistoricalAverage,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        generatedAt: '2026-05-06T12:00:00.000Z',
        lockedAt: '2026-05-06T12:01:00.000Z',
        dayRows: const <WeeklyPlanSnapshotDay>[],
        isActive: true,
        supersedesSnapshotId: 'wps-prev',
        lockReason: 'manager_locked_current_week',
        lockedByUserId: 'user-mgr-1',
        metadata: const <String, Object?>{'device_id': 'ipad-1'},
      );

      final round = WeeklyPlanSnapshot.fromMap(snapshot.toMap());
      expect(round.isActive, isTrue);
      expect(round.supersedesSnapshotId, 'wps-prev');
      expect(round.lockReason, 'manager_locked_current_week');
      expect(round.lockedByUserId, 'user-mgr-1');
      expect(round.metadata, isNotNull);
      expect(round.metadata!['device_id'], 'ipad-1');
    });
  });

  group('Theme H#7 — DAS service-period settings persistent cache', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('replaceAll persists keyed rows for app-start rehydrate', () async {
      final db = await SqliteDatabase.instance.database;
      final dao = DataAccuracyServicePeriodSettingsCacheDao(db);
      final rows = <DataAccuracyServicePeriodSetting>[
        DataAccuracyServicePeriodSetting(
          id: 'das-1',
          operatorId: 'op-1',
          locationId: 'loc-1',
          servicePeriodKey: 'lunch',
          coversSource: ServicePeriodCoversSource.vendor,
          wageSource: ServicePeriodWageSource.vendorPerEmployee,
          effectiveAtBusinessDate: '2026-05-04',
          createdAt: DateTime.utc(2026, 5, 6, 12),
          updatedAt: DateTime.utc(2026, 5, 6, 12, 1),
          updatedBy: 'admin-1',
        ),
        DataAccuracyServicePeriodSetting(
          id: 'das-2',
          operatorId: 'op-1',
          locationId: 'loc-1',
          servicePeriodKey: 'dinner',
          coversSource:
              ServicePeriodCoversSource.reservationPlusWalkin,
          wageSource: ServicePeriodWageSource.manualMix,
          effectiveAtBusinessDate: '2026-05-04',
          createdAt: DateTime.utc(2026, 5, 6, 12),
          updatedAt: DateTime.utc(2026, 5, 6, 12, 2),
          updatedBy: 'admin-1',
        ),
      ];

      final changed = await dao.replaceAll('rest-h7', rows);
      expect(changed, isTrue);

      final fetched = await dao.getRows('rest-h7');
      expect(fetched, hasLength(2));
      final dinner = fetched.firstWhere(
        (row) => row.servicePeriodKey == 'dinner',
      );
      expect(
        dinner.coversSource,
        ServicePeriodCoversSource.reservationPlusWalkin,
      );
      expect(dinner.wageSource, ServicePeriodWageSource.manualMix);
      expect(dinner.effectiveAtBusinessDate, '2026-05-04');
    });
  });

  group('Theme H#9 — restaurant_users scope invalidation', () {
    test('insert op on restaurant_users invalidates business scope', () {
      final event = RealtimeEvent(
        eventId: 'evt-1',
        topic: 'shared_state.op-1.restaurant_users',
        operatorId: 'op-1',
        occurredAt: DateTime.utc(2026, 5, 7, 12),
        payload: const <String, Object?>{
          'table': 'restaurant_users',
          'op': 'insert',
        },
      );
      expect(isBusinessScopeInvalidationEvent(event), isTrue);
    });

    test('delete op on restaurant_users invalidates business scope', () {
      final event = RealtimeEvent(
        eventId: 'evt-2',
        topic: 'shared_state.op-1.other',
        operatorId: 'op-1',
        occurredAt: DateTime.utc(2026, 5, 7, 12),
        payload: const <String, Object?>{
          'table': 'restaurant_users',
          'op': 'delete',
        },
      );
      expect(isBusinessScopeInvalidationEvent(event), isTrue);
    });
  });
}

