// A9.SY2 — Cursor stability tests.
//
// Validates the monotonicity enforcement added to
// [PostgresShiftRecordToMobileSync]:
//   1. A page response with nextCursor < inputCursor triggers a
//      cursor_violation event and the revised cursor is used.
//   2. A monotone nextCursor passes through unchanged.
//   3. When inputCursor is null (first sweep), no violation is fired
//      even if nextCursor is any value.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/sync_watermark.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';

const String _opId = '00000000-0000-4000-8000-000000000a99';
const String _locId = '00000000-0000-4000-8000-0000000000c9';

void main() {
  late ImportTrackingDao watermarkDao;
  late AppRuntimeInvalidationBus bus;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
    bus = AppRuntimeInvalidationBus.instance;
  });

  test(
    'SY2-a: page with nextCursor < inputCursor triggers cursor_violation and re-pull cursor',
    () async {
      const rid = 'rest_sy2_a';
      final violations = <CursorViolationEvent>[];

      // Seed a watermark so the first fetch uses a known inputCursor.
      const inputCursor = '2026-01-10T12:00:00.000Z';
      // The server returns a cursor that has regressed (earlier timestamp).
      const violatingCursor = '2026-01-10T11:59:59.000Z';

      final client = _FakeSyncProxyClient()
        ..scriptShiftPages([
          // First page: non-null cursor that violates monotonicity.
          _ShiftPage(records: [], nextCursor: violatingCursor),
          // Second page (re-pull): no more pages.
          _ShiftPage(records: [], nextCursor: null),
        ]);

      // Prime the watermark so the sync sees inputCursor.
      await watermarkDao.upsertWatermark(
        _watermark(rid, _opId, _locId, inputCursor),
      );

      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: _NullShiftRepo(),
        watermarkDao: watermarkDao,
        invalidationBus: bus,
        onCursorViolation: violations.add,
      );

      await sync.sync(
        operatorId: _opId,
        locationId: _locId,
        restaurantId: rid,
      );

      // Exactly one violation should have been emitted.
      expect(violations, hasLength(1));
      final v = violations.first;
      expect(v.resource, 'shift_records');
      expect(v.inputCursor, inputCursor);
      expect(v.nextCursor, violatingCursor);
      // revisedCursor should be 1ms before violatingCursor.
      expect(v.revisedCursor, isNotNull);
      final revisedDt = DateTime.parse(v.revisedCursor!);
      final violatingDt = DateTime.parse(violatingCursor);
      expect(revisedDt, violatingDt.subtract(const Duration(milliseconds: 1)));
    },
  );

  test(
    'SY2-b: monotone nextCursor emits no violation',
    () async {
      const rid = 'rest_sy2_b';
      final violations = <CursorViolationEvent>[];

      const inputCursor = '2026-01-10T12:00:00.000Z';
      const laterCursor = '2026-01-10T13:00:00.000Z';

      final client = _FakeSyncProxyClient()
        ..scriptShiftPages([
          _ShiftPage(records: [], nextCursor: laterCursor),
          _ShiftPage(records: [], nextCursor: null),
        ]);

      await watermarkDao.upsertWatermark(
        _watermark(rid, _opId, _locId, inputCursor),
      );

      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: _NullShiftRepo(),
        watermarkDao: watermarkDao,
        invalidationBus: bus,
        onCursorViolation: violations.add,
      );

      await sync.sync(
        operatorId: _opId,
        locationId: _locId,
        restaurantId: rid,
      );

      expect(violations, isEmpty);
    },
  );

  test(
    'SY2-c: null inputCursor (first sweep) never triggers violation',
    () async {
      const rid = 'rest_sy2_c';
      final violations = <CursorViolationEvent>[];

      // No watermark primed → inputCursor is null.
      const anyCursor = '2026-01-10T12:00:00.000Z';

      final client = _FakeSyncProxyClient()
        ..scriptShiftPages([
          _ShiftPage(records: [], nextCursor: anyCursor),
          _ShiftPage(records: [], nextCursor: null),
        ]);

      final sync = PostgresShiftRecordToMobileSync(
        client: client,
        shiftRepository: _NullShiftRepo(),
        watermarkDao: watermarkDao,
        invalidationBus: bus,
        onCursorViolation: violations.add,
      );

      await sync.sync(
        operatorId: _opId,
        locationId: _locId,
        restaurantId: rid,
      );

      expect(violations, isEmpty);
    },
  );
}

// ── Helpers ────────────────────────────────────────────────────────────────

SyncWatermark _watermark(
  String restaurantId,
  String operatorId,
  String locationId,
  String value,
) {
  return SyncWatermark(
    restaurantId: restaurantId,
    sourceType: 'pg_shift_record_sync:$operatorId:$locationId',
    watermarkType: 'cursor',
    watermarkValue: value,
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );
}

class _ShiftPage {
  const _ShiftPage({required this.records, required this.nextCursor});
  final List<ShiftRecord> records;
  final String? nextCursor;
}

class _FakeSyncProxyClient implements SyncProxyClient {
  final List<_ShiftPage> _shiftPages = [];
  int _shiftPageIndex = 0;

  void scriptShiftPages(List<_ShiftPage> pages) {
    _shiftPages.addAll(pages);
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    String? cursor,
    int pageSize = 200,
  }) async {
    if (_shiftPageIndex >= _shiftPages.length) {
      return const ShiftRecordPage(records: [], nextCursor: null);
    }
    final page = _shiftPages[_shiftPageIndex++];
    return ShiftRecordPage(records: page.records, nextCursor: page.nextCursor);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    String? cursor,
    int pageSize = 200,
  }) async =>
      const OpenShiftSnapshotPage(snapshots: [], nextCursor: null);

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async =>
      const <DemoModeRecord>[];

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async =>
      null;

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async =>
      const <DataAccuracyServicePeriodSetting>[];

  @override
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) async =>
      const <WageRoleRow>[];

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async =>
      null;

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async =>
      null;

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async =>
      null;
}

/// No-op shift repository for tests that don't need actual SQLite writes.
class _NullShiftRepo implements ShiftRecordRepository {
  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 0;

  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
    String restaurantId,
    String weekId,
  ) async =>
      const <ShiftRecord>[];

  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
    String restaurantId,
    List<String> weekIds,
  ) async =>
      const <ShiftRecord>[];

  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
    String restaurantId,
    String startDate,
    String endDate,
  ) async =>
      const <ShiftRecord>[];

  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      null;
}
