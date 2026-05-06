// Phase 8 Wave B `8.spine-bridge.3` server -> mobile ShiftRecord sync.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) Stages 11-13 of the canonical chain. Pulls aggregated
// `ShiftRecord` rows from server-side Postgres via the proxy, persists
// them to the mobile SQLite `shift_records` table through the existing
// `SqliteShiftRecordRepository.replaceShiftForSlot`, and fires
// `AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted` per write so
// the dashboard / variance / history / learn surfaces refresh. The
// contract names `notifyRuntimeWriteCompleted` explicitly (Stage 13 +
// Lane `.3` bindings); both bus entrypoints fire the same downstream
// signal.
//
// Aux pulls in the same sweep (`demo_mode_state`,
// `data_accuracy_settings`, `forge_flow_polling_tier_assignment`)
// surface the operator-app banner + accuracy chrome without a
// redeploy. Mobile SQLite vendor-column parity is deferred per the
// spine-bridge.3 prompt: the orchestrator holds the latest aux
// snapshots in process so downstream consumers can read them via
// getters; no SQLite tables are added by this lane.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//   * HP #1 (pure transport swap): writes flow into the existing
//     mobile `shift_records` table via the existing repository; no
//     formula change.
//   * HP #4 (per-operator isolation): the proxy enforces RLS via
//     `OperatorScopedRepository.withTenant`; the watermark row is
//     keyed on `(operator_id, location_id)` so a multi-tenant mobile
//     client can resume each tenant's stream independently. The
//     mobile-side V1 is single-tenant; the schema reservation lets
//     post-V1 multi-tenant land without a migration.
//   * HP #2 (demo mode persists post-launch): aux-pull surfaces the
//     server-side `demo_mode_state` flip on the next sweep.
//
// Hardening alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no encryption-rotation surface declared here, no malformed-payload
// sidecar columns, no advisory-lock primitives, no graceful-shutdown
// hook, no dead-letter UI surface, no raw-payload sibling-table
// writers. The hardening doctrine is enforced by the per-file source
// grep in `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`.

import 'dart:convert';

import '../../domain/models/import_run.dart';
import '../../domain/models/sync_watermark.dart';
import '../../domain/repositories/open_shift_snapshot_repository.dart';
import '../../domain/repositories/restaurant_timing_config_repository.dart';
import '../../domain/repositories/shift_record_repository.dart';
import '../../infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import '../../state/app_runtime_invalidation_bus.dart';
import '../integration/demo_mode_state.dart';
import 'sync_proxy_client.dart';

/// Outcome of one [PostgresShiftRecordToMobileSync.sync] sweep.
class SyncResult {
  const SyncResult({
    required this.recordsWritten,
    required this.openSnapshotsWritten,
    required this.pagesPulled,
    required this.openSnapshotPagesPulled,
    required this.finalCursor,
    required this.finalOpenSnapshotCursor,
    required this.timingConfigSynced,
    required this.demoModeStates,
    required this.dataAccuracySettings,
    required this.pollingTierAssignment,
    required this.firstBackfillStatus,
  });

  /// Total `ShiftRecord` rows persisted via
  /// `SqliteShiftRecordRepository.replaceShiftForSlot` during this
  /// sweep. Equal to the number of `AppRuntimeInvalidationBus` fires
  /// emitted (one per write, per the contract).
  final int recordsWritten;

  /// Total provisional `OpenShiftSnapshot` rows persisted during this
  /// sweep. These rows drive live/current Shift surfaces and never
  /// replace closed historical `ShiftRecord` truth.
  final int openSnapshotsWritten;

  /// Number of pages fetched (>= 1, since the loop always runs at
  /// least one fetch per sweep).
  final int pagesPulled;

  /// Number of open-snapshot pages fetched. Equals 0 only when the
  /// proxy/client implementation throws before the live-snapshot leg
  /// starts.
  final int openSnapshotPagesPulled;

  /// Last cursor in effect at the end of the sweep. Equals the
  /// persisted watermark when any non-null cursor advanced; equals
  /// the input watermark otherwise.
  final String? finalCursor;

  /// Last open-snapshot cursor in effect at the end of the sweep.
  final String? finalOpenSnapshotCursor;

  /// True when a resolved effective timing config was fetched and
  /// persisted to mobile SQLite.
  final bool timingConfigSynced;

  /// Snapshot of `demo_mode_state` rows for this (operator, location).
  /// Snapshot of three at most (one per `IntegrationCategory`).
  final List<DemoModeRecord> demoModeStates;

  /// Snapshot of the current `data_accuracy_settings` row, or null
  /// when the operator has not customized.
  final DataAccuracySettingsSnapshot? dataAccuracySettings;

  /// Snapshot of the currently-effective
  /// `forge_flow_polling_tier_assignment` row, or null when not
  /// provisioned.
  final ForgeFlowPollingTierAssignmentSnapshot? pollingTierAssignment;

  /// Latest first-connection backfill status pulled from the proxy, or
  /// null when no status row/endpoint is available yet.
  final FirstBackfillStatusSnapshot? firstBackfillStatus;
}

/// Pulls aggregated `ShiftRecord` rows from server-side Postgres into
/// mobile SQLite via the proxy, fires `AppRuntimeInvalidationBus` per
/// write, and refreshes the demo-mode + data-accuracy + polling-tier
/// snapshots in the same sweep.
class PostgresShiftRecordToMobileSync {
  PostgresShiftRecordToMobileSync({
    required this.client,
    required this.shiftRepository,
    required this.watermarkDao,
    OpenShiftSnapshotRepository? openShiftSnapshotRepository,
    RestaurantTimingConfigRepository? timingConfigRepository,
    AppRuntimeInvalidationBus? invalidationBus,
    this.pageSize = 200,
  }) : assert(pageSize > 0, 'pageSize must be positive'),
       openShiftSnapshotRepository =
           openShiftSnapshotRepository ??
           SqliteOpenShiftSnapshotRepository.instance,
       timingConfigRepository =
           timingConfigRepository ??
           SqliteRestaurantTimingConfigRepository.instance,
       invalidationBus = invalidationBus ?? AppRuntimeInvalidationBus.instance;

  final SyncProxyClient client;
  final ShiftRecordRepository shiftRepository;
  final OpenShiftSnapshotRepository openShiftSnapshotRepository;
  final RestaurantTimingConfigRepository timingConfigRepository;
  final ImportTrackingDao watermarkDao;
  final AppRuntimeInvalidationBus invalidationBus;
  final int pageSize;

  static const String _watermarkType = 'cursor';
  static const String _sourceTypePrefix = 'pg_shift_record_sync';
  static const String _openSnapshotSourceTypePrefix =
      'pg_open_shift_snapshot_sync';

  // ── Latest aux-pull snapshots (in-memory; SQLite parity deferred) ──

  List<DemoModeRecord> _latestDemoModeStates = const <DemoModeRecord>[];
  DataAccuracySettingsSnapshot? _latestDataAccuracySettings;
  ForgeFlowPollingTierAssignmentSnapshot? _latestPollingTierAssignment;
  FirstBackfillStatusSnapshot? _latestFirstBackfillStatus;

  /// Most-recent `demo_mode_state` rows pulled from the server.
  /// Refreshed on every successful sweep; empty before the first sweep.
  List<DemoModeRecord> get latestDemoModeStates =>
      List<DemoModeRecord>.unmodifiable(_latestDemoModeStates);

  /// Most-recent `data_accuracy_settings` snapshot for the last
  /// sync'd (operator, location), or null when none exists server-side.
  DataAccuracySettingsSnapshot? get latestDataAccuracySettings =>
      _latestDataAccuracySettings;

  /// Most-recent `forge_flow_polling_tier_assignment` snapshot, or
  /// null when not provisioned.
  ForgeFlowPollingTierAssignmentSnapshot? get latestPollingTierAssignment =>
      _latestPollingTierAssignment;

  /// Most-recent first-connection backfill status, or null before the
  /// proxy exposes one.
  FirstBackfillStatusSnapshot? get latestFirstBackfillStatus =>
      _latestFirstBackfillStatus;

  String _watermarkSourceType(String operatorId, String locationId) =>
      '$_sourceTypePrefix:$operatorId:$locationId';

  String _openSnapshotWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_openSnapshotSourceTypePrefix:$operatorId:$locationId';

  Future<String?> _readCursor({
    required String restaurantId,
    required String operatorId,
    required String locationId,
    String? sourceType,
  }) async {
    final wm = await watermarkDao.getWatermark(
      restaurantId,
      sourceType ?? _watermarkSourceType(operatorId, locationId),
      _watermarkType,
    );
    final value = wm?.watermarkValue;
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> _writeCursor({
    required String restaurantId,
    required String operatorId,
    required String locationId,
    required String cursorToken,
    String? sourceType,
  }) async {
    await watermarkDao.upsertWatermark(
      SyncWatermark(
        restaurantId: restaurantId,
        sourceType: sourceType ?? _watermarkSourceType(operatorId, locationId),
        watermarkType: _watermarkType,
        watermarkValue: cursorToken,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// Run one sync sweep for the (operator, location).
  ///
  /// Pull semantics:
  ///   * Reads the resumable cursor from `sync_watermarks`
  ///     (key = `(restaurantId, "pg_shift_record_sync:OP:LOC",
  ///     "cursor")` where `OP` / `LOC` are the operator + location
  ///     ids).
  ///   * Calls [SyncProxyClient.fetchShiftRecords] in a loop. For
  ///     every record returned, calls
  ///     `shiftRepository.replaceShiftForSlot` AND fires
  ///     `invalidationBus.notifyRuntimeWriteCompleted()` (one fire
  ///     per write, per the spine contract).
  ///   * After each page with a non-null `nextCursor`, persists the
  ///     cursor as the watermark (resilience to mid-sweep crashes).
  ///   * Loop terminates when the server returns `nextCursor == null`.
  ///
  /// Aux semantics:
  ///   * After the ShiftRecord loop ends, pulls `demo_mode_state` +
  ///     `data_accuracy_settings` + `forge_flow_polling_tier_assignment`
  ///     in that order. Updates the in-memory snapshots so the
  ///     operator app sees the demo flip / accuracy settings / polling
  ///     tier without a redeploy.
  Future<SyncResult> sync({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    if (aborted()) {
      // BUG 2 (HIGH): the auth context flipped before the sweep even
      // started; bail without touching the proxy or local SQLite.
      return SyncResult(
        recordsWritten: 0,
        openSnapshotsWritten: 0,
        pagesPulled: 0,
        openSnapshotPagesPulled: 0,
        finalCursor: null,
        finalOpenSnapshotCursor: null,
        timingConfigSynced: false,
        demoModeStates: List<DemoModeRecord>.unmodifiable(
          _latestDemoModeStates,
        ),
        dataAccuracySettings: _latestDataAccuracySettings,
        pollingTierAssignment: _latestPollingTierAssignment,
        firstBackfillStatus: _latestFirstBackfillStatus,
      );
    }
    final initialCursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
    );
    final openSnapshotSourceType = _openSnapshotWatermarkSourceType(
      operatorId,
      locationId,
    );
    final initialOpenCursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: openSnapshotSourceType,
    );

    var cursor = initialCursor;
    var openCursor = initialOpenCursor;
    var recordsWritten = 0;
    var pagesPulled = 0;
    var openSnapshotsWritten = 0;
    var openSnapshotPagesPulled = 0;
    var timingConfigSynced = false;

    final timingConfig = await client.fetchResolvedTimingConfig(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
    );
    if (timingConfig != null) {
      await timingConfigRepository.saveTimingConfig(timingConfig);
      timingConfigSynced = true;
      invalidationBus.notifyImportCompletionPersisted();
    }

    while (true) {
      // BUG 2 (HIGH): re-check the auth context before each page
      // request so a sign-out / scope flip mid-sweep stops further
      // proxy calls and SQLite writes.
      if (aborted()) break;
      final page = await client.fetchShiftRecords(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (aborted()) break;
      pagesPulled++;

      for (final record in page.records) {
        await shiftRepository.replaceShiftForSlot(record);
        invalidationBus.notifyRuntimeWriteCompleted();
        recordsWritten++;
      }

      final next = page.nextCursor;
      if (next == null) {
        break;
      }
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
      );
      cursor = next;
    }

    while (true) {
      if (aborted()) break;
      final page = await client.fetchOpenShiftSnapshots(
        operatorId: operatorId,
        locationId: locationId,
        cursor: openCursor,
        pageSize: pageSize,
      );
      if (aborted()) break;
      openSnapshotPagesPulled++;

      for (final snapshot in page.snapshots) {
        await openShiftSnapshotRepository.replaceOpenShiftSnapshot(snapshot);
        invalidationBus.notifyImportCompletionPersisted();
        openSnapshotsWritten++;
      }

      final next = page.nextCursor;
      if (next == null) {
        break;
      }
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: openSnapshotSourceType,
      );
      openCursor = next;
    }

    if (aborted()) {
      return SyncResult(
        recordsWritten: recordsWritten,
        openSnapshotsWritten: openSnapshotsWritten,
        pagesPulled: pagesPulled,
        openSnapshotPagesPulled: openSnapshotPagesPulled,
        finalCursor: cursor,
        finalOpenSnapshotCursor: openCursor,
        timingConfigSynced: timingConfigSynced,
        demoModeStates: List<DemoModeRecord>.unmodifiable(
          _latestDemoModeStates,
        ),
        dataAccuracySettings: _latestDataAccuracySettings,
        pollingTierAssignment: _latestPollingTierAssignment,
        firstBackfillStatus: _latestFirstBackfillStatus,
      );
    }

    // Aux pulls in the same sweep (per spine-bridge.3 contract).
    _latestDemoModeStates = await client.fetchDemoModeStates(
      operatorId: operatorId,
      locationId: locationId,
    );
    _latestDataAccuracySettings = await client.fetchDataAccuracySettings(
      operatorId: operatorId,
      locationId: locationId,
    );
    _latestPollingTierAssignment = await client
        .fetchForgeFlowPollingTierAssignment(
          operatorId: operatorId,
          locationId: locationId,
        );
    _latestFirstBackfillStatus = await client.fetchFirstBackfillStatus(
      operatorId: operatorId,
      locationId: locationId,
    );
    final backfillStatus = _latestFirstBackfillStatus;
    if (backfillStatus != null) {
      await _persistFirstBackfillStatus(
        restaurantId: restaurantId,
        status: backfillStatus,
      );
      invalidationBus.notifyImportCompletionPersisted();
    }

    return SyncResult(
      recordsWritten: recordsWritten,
      openSnapshotsWritten: openSnapshotsWritten,
      pagesPulled: pagesPulled,
      openSnapshotPagesPulled: openSnapshotPagesPulled,
      finalCursor: cursor,
      finalOpenSnapshotCursor: openCursor,
      timingConfigSynced: timingConfigSynced,
      demoModeStates: List<DemoModeRecord>.unmodifiable(_latestDemoModeStates),
      dataAccuracySettings: _latestDataAccuracySettings,
      pollingTierAssignment: _latestPollingTierAssignment,
      firstBackfillStatus: _latestFirstBackfillStatus,
    );
  }

  Future<void> _persistFirstBackfillStatus({
    required String restaurantId,
    required FirstBackfillStatusSnapshot status,
  }) async {
    await watermarkDao.createOrReplaceImportRun(
      ImportRun(
        importRunId: 'first_backfill:${status.jobId}',
        restaurantId: restaurantId,
        mode: 'first_backfill',
        startedAt: status.startedAt.toUtc().toIso8601String(),
        completedAt: status.isPending || status.isRunning
            ? null
            : (status.completedAt ?? status.updatedAt)
                  .toUtc()
                  .toIso8601String(),
        status: _importRunStatus(status.status),
        cursorJson: jsonEncode(<String, Object?>{
          'operator_id': status.operatorId,
          'location_id': status.locationId,
          'connection_id': status.connectionId,
          'vendor_id': status.vendorId,
          'category': status.category,
          'window_start': status.windowStart?.toUtc().toIso8601String(),
          'window_end': status.windowEnd?.toUtc().toIso8601String(),
          'updated_at': status.updatedAt.toUtc().toIso8601String(),
        }),
        errorSummary: status.isFailed ? status.lastError : null,
      ),
    );
  }

  static String _importRunStatus(String status) {
    switch (status) {
      case 'queued':
      case 'pending':
      case 'started':
        return 'pending';
      case 'running':
      case 'in_progress':
        return 'running';
      case 'succeeded':
      case 'completed':
        return 'completed';
      case 'failed':
        return 'failed';
      default:
        return status;
    }
  }
}
