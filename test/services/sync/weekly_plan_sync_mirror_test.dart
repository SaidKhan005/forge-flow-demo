import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/services/sync/weekly_plan_sync_resources.dart';

const String _opId = '00000000-0000-4000-8000-000000000a01';
const String _locId = '00000000-0000-4000-8000-0000000000b1';

void main() {
  late ImportTrackingDao watermarkDao;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
  });

  test('pulls weekly plan snapshots into the existing SQLite cache', () async {
    const rid = 'weekly_rest_A';
    final db = await SqliteDatabase.instance.database;
    await db.delete(
      'weekly_plan_snapshots',
      where: 'restaurant_id = ?',
      whereArgs: [rid],
    );
    final client = _FakeWeeklyPlanClient()
      ..scriptWeeklyPages(<_WeeklyPage>[
        _WeeklyPage(
          rows: <WeeklyPlanSnapshotSyncRow>[
            WeeklyPlanSnapshotSyncRow(
              operatorId: _opId,
              locationId: _locId,
              snapshot: _snapshot(rid, forecastCovers: 148),
            ),
          ],
          nextCursor: 'weekly-cursor-1',
        ),
        const _WeeklyPage(
          rows: <WeeklyPlanSnapshotSyncRow>[],
          nextCursor: null,
        ),
      ])
      ..scriptForecastPages(<_ForecastPage>[
        _ForecastPage(
          rows: <ForecastContextSyncRow>[
            ForecastContextSyncRow(
              operatorId: _opId,
              locationId: _locId,
              context: _forecastContext(rid),
            ),
          ],
          nextCursor: 'forecast-cursor-1',
        ),
        const _ForecastPage(rows: <ForecastContextSyncRow>[], nextCursor: null),
      ]);

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
    );
    final result = await sync.sync(
      operatorId: _opId,
      locationId: _locId,
      restaurantId: rid,
    );

    final stored = await SqliteWeeklyPlanSnapshotRepository.instance
        .getSnapshotForWeekKey(rid, '2026-05-04_2026-05-10');
    expect(stored, isNotNull);
    expect(stored!.forecastCovers, 148);
    expect(stored.dayRows.single.businessDate, '2026-05-04');
    expect(result.weeklyPlanMirrors.weeklyPlanSnapshots.rowsWritten, 1);
    expect(
      result.weeklyPlanMirrors.weeklyPlanSnapshots.finalCursor,
      'weekly-cursor-1',
    );
    expect(
      result.weeklyPlanMirrors.forecastContexts.unavailableReason,
      'forecast_context_sqlite_cache_unavailable_memory_only',
    );
    expect(
      result.weeklyPlanMirrors.forecastContexts.durableCacheAvailable,
      isFalse,
    );
    expect(
      sync.latestForecastContexts.single.context.baselineTotalCovers,
      1200,
    );

    final weeklyWatermark = await watermarkDao.getWatermark(
      rid,
      'pg_weekly_plan_snapshot_sync:$_opId:$_locId',
      'cursor',
    );
    final forecastWatermark = await watermarkDao.getWatermark(
      rid,
      'pg_forecast_context_sync:$_opId:$_locId',
      'cursor',
    );
    expect(weeklyWatermark!.watermarkValue, 'weekly-cursor-1');
    expect(forecastWatermark!.watermarkValue, 'forecast-cursor-1');
    expect(client.weeklyCursorsObserved, <String?>[null, 'weekly-cursor-1']);
    expect(client.forecastCursorsObserved, <String?>[
      null,
      'forecast-cursor-1',
    ]);
  });

  test(
    'legacy weekly-plan routes report unavailable and leave cache alone',
    () async {
      const rid = 'weekly_rest_legacy';
      final seeded = _snapshot(rid, snapshotId: 'seeded', forecastCovers: 99);
      await SqliteWeeklyPlanSnapshotRepository.instance.upsertSnapshot(seeded);
      final client = _FakeWeeklyPlanClient()
        ..weeklyUnavailableReason = 'weekly_plan_proxy_route_not_found'
        ..forecastUnavailableReason = 'weekly_plan_proxy_route_not_found';

      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: SqliteShiftRecordRepository.instance,
        watermarkDao: watermarkDao,
      );
      final result = await sync.sync(
        operatorId: _opId,
        locationId: _locId,
        restaurantId: rid,
      );

      final stored = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(rid, seeded.weekKey);
      expect(
        result.weeklyPlanMirrors.weeklyPlanSnapshots.state,
        WeeklyPlanResourceSyncState.unavailable,
      );
      expect(result.weeklyPlanMirrors.weeklyPlanSnapshots.rowsWritten, 0);
      expect(stored!.snapshotId, 'seeded');
      expect(stored.forecastCovers, 99);
    },
  );

  test(
    'rejects weekly plan rows that cross operator or location scope',
    () async {
      const rid = 'weekly_rest_scope';
      final db = await SqliteDatabase.instance.database;
      await db.delete(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [rid],
      );
      final client = _FakeWeeklyPlanClient()
        ..scriptWeeklyPages(<_WeeklyPage>[
          _WeeklyPage(
            rows: <WeeklyPlanSnapshotSyncRow>[
              WeeklyPlanSnapshotSyncRow(
                operatorId: 'other-op',
                locationId: _locId,
                snapshot: _snapshot(rid, snapshotId: 'bad-scope'),
              ),
            ],
            nextCursor: null,
          ),
        ]);

      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: SqliteShiftRecordRepository.instance,
        watermarkDao: watermarkDao,
      );

      await expectLater(
        sync.sync(operatorId: _opId, locationId: _locId, restaurantId: rid),
        throwsStateError,
      );
      final rows = await db.query(
        'weekly_plan_snapshots',
        where: 'restaurant_id = ?',
        whereArgs: [rid],
      );
      expect(rows, isEmpty);
    },
  );
}

class _WeeklyPage {
  const _WeeklyPage({required this.rows, required this.nextCursor});
  final List<WeeklyPlanSnapshotSyncRow> rows;
  final String? nextCursor;
}

class _ForecastPage {
  const _ForecastPage({required this.rows, required this.nextCursor});
  final List<ForecastContextSyncRow> rows;
  final String? nextCursor;
}

class _FakeWeeklyPlanClient
    implements SyncProxyClient, WeeklyPlanSyncProxyClient {
  final List<_WeeklyPage> _weeklyPages = <_WeeklyPage>[];
  final List<_ForecastPage> _forecastPages = <_ForecastPage>[];
  final List<String?> weeklyCursorsObserved = <String?>[];
  final List<String?> forecastCursorsObserved = <String?>[];
  String? weeklyUnavailableReason;
  String? forecastUnavailableReason;

  void scriptWeeklyPages(List<_WeeklyPage> pages) {
    _weeklyPages
      ..clear()
      ..addAll(pages);
  }

  void scriptForecastPages(List<_ForecastPage> pages) {
    _forecastPages
      ..clear()
      ..addAll(pages);
  }

  @override
  Future<WeeklyPlanSnapshotSyncPage> fetchWeeklyPlanSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    weeklyCursorsObserved.add(cursor);
    final reason = weeklyUnavailableReason;
    if (reason != null) return WeeklyPlanSnapshotSyncPage.unavailable(reason);
    if (_weeklyPages.isEmpty) {
      return const WeeklyPlanSnapshotSyncPage(
        snapshots: <WeeklyPlanSnapshotSyncRow>[],
        nextCursor: null,
      );
    }
    final page = _weeklyPages.removeAt(0);
    return WeeklyPlanSnapshotSyncPage(
      snapshots: page.rows,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<ForecastContextSyncPage> fetchForecastContexts({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    forecastCursorsObserved.add(cursor);
    final reason = forecastUnavailableReason;
    if (reason != null) return ForecastContextSyncPage.unavailable(reason);
    if (_forecastPages.isEmpty) {
      return const ForecastContextSyncPage(
        contexts: <ForecastContextSyncRow>[],
        nextCursor: null,
      );
    }
    final page = _forecastPages.removeAt(0);
    return ForecastContextSyncPage(
      contexts: page.rows,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async => const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async => const OpenShiftSnapshotPage(
    snapshots: <OpenShiftSnapshot>[],
    nextCursor: null,
  );

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async => null;

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async => const <DemoModeRecord>[];

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async => null;

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async => const <DataAccuracyServicePeriodSetting>[];

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) async => const <WageRoleRow>[];

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async => null;

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async => null;
}

WeeklyPlanSnapshot _snapshot(
  String restaurantId, {
  String snapshotId = 'wps-1',
  int forecastCovers = 148,
}) => WeeklyPlanSnapshot(
  snapshotId: snapshotId,
  restaurantId: restaurantId,
  weekStartDate: '2026-05-04',
  weekEndDate: '2026-05-10',
  targetCycleId: 'cycle-1',
  forecastCovers: forecastCovers,
  forecastSales: 6512,
  requiredFohHours: 32,
  requiredBohHours: 28,
  theoreticalFohLaborDollars: 576,
  theoreticalBohLaborDollars: 644,
  coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
  salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
  generatedAt: '2026-05-06T12:00:00.000Z',
  lockedAt: '2026-05-06T12:01:00.000Z',
  dayRows: const <WeeklyPlanSnapshotDay>[
    WeeklyPlanSnapshotDay(
      day: 'Mon',
      businessDate: '2026-05-04',
      forecastCovers: 22,
      forecastSales: 968,
      requiredFohHours: 5,
      requiredBohHours: 4,
    ),
  ],
);

DemandForecastContext _forecastContext(String restaurantId) =>
    DemandForecastContext(
      restaurantId: restaurantId,
      anchorBusinessDate: '2026-05-04',
      baselineTotalCovers: 1200,
      baselineWeeklyAvgCovers: 140,
      baselineWeeksRepresented: 8.571,
      recentThreeWeekTotalCovers: 468,
      recentThreeWeekWeeklyAvgCovers: 156,
      recentTrendDeltaCovers: 16,
      resolvedWeeklyForecastCovers: 148,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      builtAt: '2026-05-06T12:00:00.000Z',
    );
