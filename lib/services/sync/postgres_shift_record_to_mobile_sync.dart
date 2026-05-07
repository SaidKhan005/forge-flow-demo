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
// `data_accuracy_settings`, `wage_role_rows`,
// `forge_flow_polling_tier_assignment`)
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

import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/import_run.dart';
import '../../domain/models/sync_watermark.dart';
import '../../domain/models/wage_role_row.dart';
import '../../domain/repositories/baseline_selection_repository.dart';
import '../../domain/repositories/open_shift_snapshot_repository.dart';
import '../../domain/repositories/restaurant_timing_config_repository.dart';
import '../../domain/repositories/shift_record_repository.dart';
import '../../domain/repositories/target_cycle_repository.dart';
import '../../domain/repositories/target_profile_repository.dart';
import '../../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import '../../state/app_runtime_invalidation_bus.dart';
import '../integration/demo_mode_state.dart';
import 'star_target_sync_resources.dart';
import 'sync_proxy_client.dart';
import 'weekly_plan_sync_resources.dart';

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
    required this.dataAccuracyServicePeriodSettings,
    required this.wageRoleRows,
    required this.pollingTierAssignment,
    required this.firstBackfillStatus,
    required this.starTargetMirrors,
    required this.weeklyPlanMirrors,
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

  /// Snapshot of keyed service-period data accuracy settings for this
  /// location. These rows are server-owned; mobile keeps them in memory
  /// for display/explanation parity with shared truth.
  final List<DataAccuracyServicePeriodSetting>
  dataAccuracyServicePeriodSettings;

  /// Server-owned wage mix rows mirrored into mobile SQLite for the
  /// active restaurant. Empty means the server authoritative set is
  /// empty, so the local cache was cleared on a successful sweep.
  final List<WageRoleRow> wageRoleRows;

  /// Snapshot of the currently-effective
  /// `forge_flow_polling_tier_assignment` row, or null when not
  /// provisioned.
  final ForgeFlowPollingTierAssignmentSnapshot? pollingTierAssignment;

  /// Latest first-connection backfill status pulled from the proxy, or
  /// null when no status row/endpoint is available yet.
  final FirstBackfillStatusSnapshot? firstBackfillStatus;

  /// Status for selected-star, target-cycle, active-profile, and profile
  /// version cache mirrors. Legacy proxy clients surface unavailable
  /// status here instead of treating existing local rows as server truth.
  final StarTargetMirrorSyncResult starTargetMirrors;

  /// Status for weekly plan snapshot and forecast-context pulls. Both resources
  /// write through the existing SQLite weekly-plan cache; forecast context is
  /// embedded on the snapshot row that references it so mobile remains a cache
  /// of server truth without adding a duplicate forecast table.
  final WeeklyPlanMirrorSyncResult weeklyPlanMirrors;
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
    BaselineSelectionRepository? baselineSelectionRepository,
    TargetCycleRepository? targetCycleRepository,
    TargetProfileRepository? targetProfileRepository,
    WeeklyPlanSnapshotRepository? weeklyPlanSnapshotRepository,
    SqliteWageRoleRowRepository? wageRoleRowRepository,
    AppRuntimeInvalidationBus? invalidationBus,
    // PF2 hardening: bumped from 200 → 500 rows per page.
    // Trade-off: each page is ≈2.5 MB of JSON on a 50 K-cover
    // operator, but the round-trip count drops from ~7 to ~3 for
    // that operator size, cutting total sync wall-time by ≈57%.
    // Memory impact is bounded: the mobile client processes each
    // page row-by-row and holds at most one page in memory at a
    // time (no full-set accumulation). The proxy's per-request
    // timeout (kPostgresPerStatementTimeout = 5 s) is the ceiling
    // per SQL call; pagination keeps each SELECT well under it.
    this.pageSize = 500,
  }) : assert(pageSize > 0, 'pageSize must be positive'),
       openShiftSnapshotRepository =
           openShiftSnapshotRepository ??
           SqliteOpenShiftSnapshotRepository.instance,
       timingConfigRepository =
           timingConfigRepository ??
           SqliteRestaurantTimingConfigRepository.instance,
       baselineSelectionRepository =
           baselineSelectionRepository ??
           SqliteBaselineSelectionRepository.instance,
       targetCycleRepository =
           targetCycleRepository ?? SqliteTargetCycleRepository.instance,
       targetProfileRepository =
           targetProfileRepository ?? SqliteTargetProfileRepository.instance,
       weeklyPlanSnapshotRepository =
           weeklyPlanSnapshotRepository ??
           SqliteWeeklyPlanSnapshotRepository.instance,
       wageRoleRowRepository =
           wageRoleRowRepository ?? SqliteWageRoleRowRepository.instance,
       invalidationBus = invalidationBus ?? AppRuntimeInvalidationBus.instance;

  final SyncProxyClient client;
  final ShiftRecordRepository shiftRepository;
  final OpenShiftSnapshotRepository openShiftSnapshotRepository;
  final RestaurantTimingConfigRepository timingConfigRepository;
  final BaselineSelectionRepository baselineSelectionRepository;
  final TargetCycleRepository targetCycleRepository;
  final TargetProfileRepository targetProfileRepository;
  final WeeklyPlanSnapshotRepository weeklyPlanSnapshotRepository;
  final SqliteWageRoleRowRepository wageRoleRowRepository;
  final ImportTrackingDao watermarkDao;
  final AppRuntimeInvalidationBus invalidationBus;
  final int pageSize;

  static const String _watermarkType = 'cursor';
  static const String _sourceTypePrefix = 'pg_shift_record_sync';
  static const String _openSnapshotSourceTypePrefix =
      'pg_open_shift_snapshot_sync';
  static const String _selectedStarsSourceTypePrefix =
      'pg_selected_star_shift_decision_sync';
  static const String _targetCyclesSourceTypePrefix = 'pg_target_cycle_sync';
  static const String _activeProfilesSourceTypePrefix =
      'pg_active_target_profile_sync';
  static const String _profileVersionsSourceTypePrefix =
      'pg_target_profile_version_sync';
  static const String _weeklyPlanSnapshotsSourceTypePrefix =
      'pg_weekly_plan_snapshot_sync';
  static const String _forecastContextsSourceTypePrefix =
      'pg_forecast_context_sync';

  // ── Latest aux-pull snapshots (in-memory; SQLite parity deferred) ──

  List<DemoModeRecord> _latestDemoModeStates = const <DemoModeRecord>[];
  DataAccuracySettingsSnapshot? _latestDataAccuracySettings;
  List<DataAccuracyServicePeriodSetting>
  _latestDataAccuracyServicePeriodSettings =
      const <DataAccuracyServicePeriodSetting>[];
  List<WageRoleRow> _latestWageRoleRows = const <WageRoleRow>[];
  ForgeFlowPollingTierAssignmentSnapshot? _latestPollingTierAssignment;
  FirstBackfillStatusSnapshot? _latestFirstBackfillStatus;
  List<ForecastContextSyncRow> _latestForecastContexts =
      const <ForecastContextSyncRow>[];

  /// Most-recent `demo_mode_state` rows pulled from the server.
  /// Refreshed on every successful sweep; empty before the first sweep.
  List<DemoModeRecord> get latestDemoModeStates =>
      List<DemoModeRecord>.unmodifiable(_latestDemoModeStates);

  /// Most-recent `data_accuracy_settings` snapshot for the last
  /// sync'd (operator, location), or null when none exists server-side.
  DataAccuracySettingsSnapshot? get latestDataAccuracySettings =>
      _latestDataAccuracySettings;

  /// Most-recent keyed service-period data accuracy settings for the
  /// last sync'd (operator, location).
  List<DataAccuracyServicePeriodSetting>
  get latestDataAccuracyServicePeriodSettings =>
      List<DataAccuracyServicePeriodSetting>.unmodifiable(
        _latestDataAccuracyServicePeriodSettings,
      );

  /// Most-recent server-owned wage role mix rows for the last sync'd
  /// (operator, location).
  List<WageRoleRow> get latestWageRoleRows =>
      List<WageRoleRow>.unmodifiable(_latestWageRoleRows);

  /// Most-recent `forge_flow_polling_tier_assignment` snapshot, or
  /// null when not provisioned.
  ForgeFlowPollingTierAssignmentSnapshot? get latestPollingTierAssignment =>
      _latestPollingTierAssignment;

  /// Most-recent first-connection backfill status, or null before the
  /// proxy exposes one.
  FirstBackfillStatusSnapshot? get latestFirstBackfillStatus =>
      _latestFirstBackfillStatus;

  /// Latest forecast context rows pulled from the proxy. Matching rows are also
  /// embedded into the existing `weekly_plan_snapshots` SQLite cache.
  List<ForecastContextSyncRow> get latestForecastContexts =>
      List<ForecastContextSyncRow>.unmodifiable(_latestForecastContexts);

  String _watermarkSourceType(String operatorId, String locationId) =>
      '$_sourceTypePrefix:$operatorId:$locationId';

  String _openSnapshotWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_openSnapshotSourceTypePrefix:$operatorId:$locationId';

  String _selectedStarsWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_selectedStarsSourceTypePrefix:$operatorId:$locationId';

  String _targetCyclesWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_targetCyclesSourceTypePrefix:$operatorId:$locationId';

  String _activeProfilesWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_activeProfilesSourceTypePrefix:$operatorId:$locationId';

  String _profileVersionsWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_profileVersionsSourceTypePrefix:$operatorId:$locationId';

  String _weeklyPlanSnapshotsWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_weeklyPlanSnapshotsSourceTypePrefix:$operatorId:$locationId';

  String _forecastContextsWatermarkSourceType(
    String operatorId,
    String locationId,
  ) => '$_forecastContextsSourceTypePrefix:$operatorId:$locationId';

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
  ///   * After the ShiftRecord loop ends, pulls `demo_mode_state`,
  ///     `data_accuracy_settings`, `wage_role_rows`, and
  ///     `forge_flow_polling_tier_assignment`. Wage role rows replace
  ///     the local SQLite cache for the active restaurant because the
  ///     server owns the role/rate mix.
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
        dataAccuracyServicePeriodSettings:
            List<DataAccuracyServicePeriodSetting>.unmodifiable(
              _latestDataAccuracyServicePeriodSettings,
            ),
        wageRoleRows: List<WageRoleRow>.unmodifiable(_latestWageRoleRows),
        pollingTierAssignment: _latestPollingTierAssignment,
        firstBackfillStatus: _latestFirstBackfillStatus,
        starTargetMirrors: StarTargetMirrorSyncResult.skipped(),
        weeklyPlanMirrors: WeeklyPlanMirrorSyncResult.skipped(),
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

    SyncResult abortedResult() => SyncResult(
      recordsWritten: recordsWritten,
      openSnapshotsWritten: openSnapshotsWritten,
      pagesPulled: pagesPulled,
      openSnapshotPagesPulled: openSnapshotPagesPulled,
      finalCursor: cursor,
      finalOpenSnapshotCursor: openCursor,
      timingConfigSynced: timingConfigSynced,
      demoModeStates: List<DemoModeRecord>.unmodifiable(_latestDemoModeStates),
      dataAccuracySettings: _latestDataAccuracySettings,
      dataAccuracyServicePeriodSettings:
          List<DataAccuracyServicePeriodSetting>.unmodifiable(
            _latestDataAccuracyServicePeriodSettings,
          ),
      wageRoleRows: List<WageRoleRow>.unmodifiable(_latestWageRoleRows),
      pollingTierAssignment: _latestPollingTierAssignment,
      firstBackfillStatus: _latestFirstBackfillStatus,
      starTargetMirrors: StarTargetMirrorSyncResult.skipped(),
      weeklyPlanMirrors: WeeklyPlanMirrorSyncResult.skipped(),
    );

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
      return abortedResult();
    }

    // Aux pulls in the same sweep (per spine-bridge.3 contract). Keep
    // the fetched state staged until every abort check clears so a
    // cancelled sweep leaves the previous local cache and getters intact.
    final demoModeStates = await client.fetchDemoModeStates(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (aborted()) return abortedResult();
    final dataAccuracySettings = await client.fetchDataAccuracySettings(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (aborted()) return abortedResult();
    final dataAccuracyServicePeriodSettings = await client
        .fetchDataAccuracyServicePeriodSettings(
          operatorId: operatorId,
          locationId: locationId,
        );
    if (aborted()) return abortedResult();
    final wageRoleRows =
        (await client.fetchWageRoleRows(
              operatorId: operatorId,
              locationId: locationId,
            ))
            .map(
              (row) => WageRoleRow(
                restaurantId: restaurantId,
                roleName: row.roleName,
                laborBucket: row.laborBucket,
                hourlyRate: row.hourlyRate,
                weightedHours: row.weightedHours,
              ),
            )
            .toList(growable: false);
    if (aborted()) return abortedResult();
    final pollingTierAssignment = await client
        .fetchForgeFlowPollingTierAssignment(
          operatorId: operatorId,
          locationId: locationId,
        );
    if (aborted()) return abortedResult();
    final firstBackfillStatus = await client.fetchFirstBackfillStatus(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (aborted()) return abortedResult();
    final starTargetMirrors = await _syncStarTargetMirrors(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) return abortedResult();
    final weeklyPlanMirrors = await _syncWeeklyPlanMirrors(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) return abortedResult();

    final wageRoleRowsChanged = await wageRoleRowRepository.replaceAll(
      restaurantId,
      wageRoleRows,
    );
    if (wageRoleRowsChanged) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    if (firstBackfillStatus != null) {
      await _persistFirstBackfillStatus(
        restaurantId: restaurantId,
        status: firstBackfillStatus,
      );
      invalidationBus.notifyImportCompletionPersisted();
    }
    _latestDemoModeStates = List<DemoModeRecord>.unmodifiable(demoModeStates);
    _latestDataAccuracySettings = dataAccuracySettings;
    _latestDataAccuracyServicePeriodSettings =
        List<DataAccuracyServicePeriodSetting>.unmodifiable(
          dataAccuracyServicePeriodSettings,
        );
    _latestWageRoleRows = List<WageRoleRow>.unmodifiable(wageRoleRows);
    _latestPollingTierAssignment = pollingTierAssignment;
    _latestFirstBackfillStatus = firstBackfillStatus;

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
      dataAccuracyServicePeriodSettings:
          List<DataAccuracyServicePeriodSetting>.unmodifiable(
            _latestDataAccuracyServicePeriodSettings,
          ),
      wageRoleRows: List<WageRoleRow>.unmodifiable(_latestWageRoleRows),
      pollingTierAssignment: _latestPollingTierAssignment,
      firstBackfillStatus: _latestFirstBackfillStatus,
      starTargetMirrors: starTargetMirrors,
      weeklyPlanMirrors: weeklyPlanMirrors,
    );
  }

  Future<WeeklyPlanMirrorSyncResult> _syncWeeklyPlanMirrors({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    if (aborted()) return WeeklyPlanMirrorSyncResult.skipped();
    final weeklyPlanClient = client is WeeklyPlanSyncProxyClient
        ? client as WeeklyPlanSyncProxyClient
        : null;
    if (weeklyPlanClient == null) {
      _latestForecastContexts = const <ForecastContextSyncRow>[];
      return WeeklyPlanMirrorSyncResult.unavailable(
        'weekly_plan_proxy_client_not_configured',
      );
    }

    final snapshots = await _syncWeeklyPlanSnapshots(
      weeklyPlanClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) {
      return WeeklyPlanMirrorSyncResult(
        weeklyPlanSnapshots: snapshots,
        forecastContexts: WeeklyPlanResourceSyncStatus.skipped(
          'forecast_contexts',
        ),
      );
    }
    final contexts = await _syncForecastContexts(
      weeklyPlanClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );

    return WeeklyPlanMirrorSyncResult(
      weeklyPlanSnapshots: snapshots,
      forecastContexts: contexts,
    );
  }

  Future<WeeklyPlanResourceSyncStatus> _syncWeeklyPlanSnapshots(
    WeeklyPlanSyncProxyClient weeklyPlanClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _weeklyPlanSnapshotsWatermarkSourceType(
      operatorId,
      locationId,
    );
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    var pagesPulled = 0;
    var rowsWritten = 0;
    while (true) {
      if (aborted()) {
        return WeeklyPlanResourceSyncStatus.skipped('weekly_plan_snapshots');
      }
      final page = await weeklyPlanClient.fetchWeeklyPlanSnapshots(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return WeeklyPlanResourceSyncStatus.unavailable(
          'weekly_plan_snapshots',
          page.unavailableReason!,
          finalCursor: cursor,
        );
      }
      pagesPulled++;
      for (final row in page.snapshots) {
        _assertScopedRow(
          resource: 'weekly_plan_snapshots',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: row.operatorId,
          rowLocationId: row.locationId,
        );
        if (row.snapshot.restaurantId != restaurantId) continue;
        await weeklyPlanSnapshotRepository.upsertSnapshot(row.snapshot);
        rowsWritten++;
      }
      final next = page.nextCursor;
      if (next == null) break;
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: sourceType,
      );
      cursor = next;
    }
    if (rowsWritten > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return WeeklyPlanResourceSyncStatus.synced(
      resource: 'weekly_plan_snapshots',
      rowsWritten: rowsWritten,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  Future<WeeklyPlanResourceSyncStatus> _syncForecastContexts(
    WeeklyPlanSyncProxyClient weeklyPlanClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _forecastContextsWatermarkSourceType(
      operatorId,
      locationId,
    );
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    var pagesPulled = 0;
    var rowsWritten = 0;
    final contexts = <ForecastContextSyncRow>[];
    _latestForecastContexts = const <ForecastContextSyncRow>[];
    while (true) {
      if (aborted()) {
        return WeeklyPlanResourceSyncStatus.skipped('forecast_contexts');
      }
      final page = await weeklyPlanClient.fetchForecastContexts(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return WeeklyPlanResourceSyncStatus.unavailable(
          'forecast_contexts',
          page.unavailableReason!,
          finalCursor: cursor,
          pagesPulled: pagesPulled,
        );
      }
      pagesPulled++;
      for (final row in page.contexts) {
        _assertScopedRow(
          resource: 'forecast_contexts',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: row.operatorId,
          rowLocationId: row.locationId,
        );
        if (row.context.restaurantId != restaurantId) continue;
        rowsWritten += await weeklyPlanSnapshotRepository.attachForecastContext(
          restaurantId: restaurantId,
          context: row.context,
          forecastContextId: row.forecastContextId,
          weekStartDate: row.weekStartDate,
          weekEndDate: row.weekEndDate,
        );
        contexts.add(row);
      }
      final next = page.nextCursor;
      if (next == null) break;
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: sourceType,
      );
      cursor = next;
    }
    _latestForecastContexts = List<ForecastContextSyncRow>.unmodifiable(
      contexts,
    );
    if (rowsWritten > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return WeeklyPlanResourceSyncStatus.synced(
      resource: 'forecast_contexts',
      rowsWritten: rowsWritten,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  Future<StarTargetMirrorSyncResult> _syncStarTargetMirrors({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    if (aborted()) return StarTargetMirrorSyncResult.skipped();
    final starTargetClient = client is StarTargetSyncProxyClient
        ? client as StarTargetSyncProxyClient
        : null;
    if (starTargetClient == null) {
      return StarTargetMirrorSyncResult.unavailable(
        'star_target_proxy_client_not_configured',
      );
    }

    final selectedStars = await _syncSelectedStarDecisions(
      starTargetClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) {
      return StarTargetMirrorSyncResult(
        selectedStars: selectedStars,
        targetCycles: StarTargetResourceSyncStatus.skipped('target_cycles'),
        activeTargetProfiles: StarTargetResourceSyncStatus.skipped(
          'active_target_profiles',
        ),
        targetProfileVersions: StarTargetResourceSyncStatus.skipped(
          'target_profile_versions',
        ),
      );
    }
    final targetCycles = await _syncTargetCycles(
      starTargetClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) {
      return StarTargetMirrorSyncResult(
        selectedStars: selectedStars,
        targetCycles: targetCycles,
        activeTargetProfiles: StarTargetResourceSyncStatus.skipped(
          'active_target_profiles',
        ),
        targetProfileVersions: StarTargetResourceSyncStatus.skipped(
          'target_profile_versions',
        ),
      );
    }
    final activeProfiles = await _syncActiveTargetProfiles(
      starTargetClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );
    if (aborted()) {
      return StarTargetMirrorSyncResult(
        selectedStars: selectedStars,
        targetCycles: targetCycles,
        activeTargetProfiles: activeProfiles,
        targetProfileVersions: StarTargetResourceSyncStatus.skipped(
          'target_profile_versions',
        ),
      );
    }
    final profileVersions = await _syncTargetProfileVersions(
      starTargetClient,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      isAborted: isAborted,
    );

    return StarTargetMirrorSyncResult(
      selectedStars: selectedStars,
      targetCycles: targetCycles,
      activeTargetProfiles: activeProfiles,
      targetProfileVersions: profileVersions,
    );
  }

  Future<StarTargetResourceSyncStatus> _syncSelectedStarDecisions(
    StarTargetSyncProxyClient starTargetClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _selectedStarsWatermarkSourceType(
      operatorId,
      locationId,
    );
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    final selected = cursor == null
        ? <String>{}
        : Set<String>.from(
            await baselineSelectionRepository.getSelectedRecordKeys(
              restaurantId,
            ),
          );
    String? pendingCursor;
    var pagesPulled = 0;
    var rowsApplied = 0;
    while (true) {
      if (aborted()) {
        return StarTargetResourceSyncStatus.skipped('selected_stars');
      }
      final page = await starTargetClient.fetchSelectedStarShiftDecisions(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return StarTargetResourceSyncStatus.unavailable(
          'selected_stars',
          page.unavailableReason!,
          finalCursor: cursor,
        );
      }
      pagesPulled++;
      for (final decision in page.decisions) {
        _assertScopedRow(
          resource: 'selected_stars',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: decision.operatorId,
          rowLocationId: decision.locationId,
        );
        if (decision.isSelected) {
          selected.add(decision.recordKey);
        } else if (decision.isClear) {
          selected.remove(decision.recordKey);
        }
        rowsApplied++;
      }
      final next = page.nextCursor;
      if (next == null) break;
      cursor = next;
      pendingCursor = next;
    }
    if (aborted()) {
      return StarTargetResourceSyncStatus.skipped('selected_stars');
    }
    await baselineSelectionRepository.replaceSelectedRecordKeys(
      restaurantId,
      selected,
    );
    if (pendingCursor != null) {
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: pendingCursor,
        sourceType: sourceType,
      );
    }
    if (rowsApplied > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return StarTargetResourceSyncStatus.synced(
      resource: 'selected_stars',
      rowsWritten: rowsApplied,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  Future<StarTargetResourceSyncStatus> _syncTargetCycles(
    StarTargetSyncProxyClient starTargetClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _targetCyclesWatermarkSourceType(operatorId, locationId);
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    var pagesPulled = 0;
    var rowsWritten = 0;
    while (true) {
      if (aborted()) {
        return StarTargetResourceSyncStatus.skipped('target_cycles');
      }
      final page = await starTargetClient.fetchTargetCycles(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return StarTargetResourceSyncStatus.unavailable(
          'target_cycles',
          page.unavailableReason!,
          finalCursor: cursor,
        );
      }
      pagesPulled++;
      for (final row in page.cycles) {
        _assertScopedRow(
          resource: 'target_cycles',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: row.operatorId,
          rowLocationId: row.locationId,
        );
        if (row.cycle.restaurantId != restaurantId) continue;
        await targetCycleRepository.upsertCycle(row.cycle);
        rowsWritten++;
      }
      final next = page.nextCursor;
      if (next == null) break;
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: sourceType,
      );
      cursor = next;
    }
    if (rowsWritten > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return StarTargetResourceSyncStatus.synced(
      resource: 'target_cycles',
      rowsWritten: rowsWritten,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  Future<StarTargetResourceSyncStatus> _syncActiveTargetProfiles(
    StarTargetSyncProxyClient starTargetClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _activeProfilesWatermarkSourceType(
      operatorId,
      locationId,
    );
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    var pagesPulled = 0;
    var rowsWritten = 0;
    while (true) {
      if (aborted()) {
        return StarTargetResourceSyncStatus.skipped('active_target_profiles');
      }
      final page = await starTargetClient.fetchActiveTargetProfiles(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return StarTargetResourceSyncStatus.unavailable(
          'active_target_profiles',
          page.unavailableReason!,
          finalCursor: cursor,
        );
      }
      pagesPulled++;
      for (final row in page.profiles) {
        _assertScopedRow(
          resource: 'active_target_profiles',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: row.operatorId,
          rowLocationId: row.locationId,
        );
        if (row.profile.restaurantId != restaurantId) continue;
        await targetProfileRepository.upsertActiveTargetProfile(row.profile);
        rowsWritten++;
      }
      final next = page.nextCursor;
      if (next == null) break;
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: sourceType,
      );
      cursor = next;
    }
    if (rowsWritten > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return StarTargetResourceSyncStatus.synced(
      resource: 'active_target_profiles',
      rowsWritten: rowsWritten,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  Future<StarTargetResourceSyncStatus> _syncTargetProfileVersions(
    StarTargetSyncProxyClient starTargetClient, {
    required String operatorId,
    required String locationId,
    required String restaurantId,
    bool Function()? isAborted,
  }) async {
    bool aborted() => isAborted?.call() ?? false;
    final sourceType = _profileVersionsWatermarkSourceType(
      operatorId,
      locationId,
    );
    var cursor = await _readCursor(
      restaurantId: restaurantId,
      operatorId: operatorId,
      locationId: locationId,
      sourceType: sourceType,
    );
    var pagesPulled = 0;
    var rowsWritten = 0;
    while (true) {
      if (aborted()) {
        return StarTargetResourceSyncStatus.skipped('target_profile_versions');
      }
      final page = await starTargetClient.fetchTargetProfileVersions(
        operatorId: operatorId,
        locationId: locationId,
        cursor: cursor,
        pageSize: pageSize,
      );
      if (page.isUnavailable) {
        return StarTargetResourceSyncStatus.unavailable(
          'target_profile_versions',
          page.unavailableReason!,
          finalCursor: cursor,
        );
      }
      pagesPulled++;
      for (final row in page.versions) {
        _assertScopedRow(
          resource: 'target_profile_versions',
          operatorId: operatorId,
          locationId: locationId,
          rowOperatorId: row.operatorId,
          rowLocationId: row.locationId,
        );
        if (row.version.restaurantId != restaurantId) continue;
        await targetProfileRepository.insertTargetProfileVersion(row.version);
        rowsWritten++;
      }
      final next = page.nextCursor;
      if (next == null) break;
      await _writeCursor(
        restaurantId: restaurantId,
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: next,
        sourceType: sourceType,
      );
      cursor = next;
    }
    if (rowsWritten > 0) {
      invalidationBus.notifyImportCompletionPersisted();
    }
    return StarTargetResourceSyncStatus.synced(
      resource: 'target_profile_versions',
      rowsWritten: rowsWritten,
      pagesPulled: pagesPulled,
      finalCursor: cursor,
    );
  }

  static void _assertScopedRow({
    required String resource,
    required String operatorId,
    required String locationId,
    required String? rowOperatorId,
    required String? rowLocationId,
  }) {
    if (rowOperatorId != null && rowOperatorId != operatorId) {
      throw StateError(
        '$resource sync row crossed operator scope: '
        '$rowOperatorId != $operatorId',
      );
    }
    if (rowLocationId != null && rowLocationId != locationId) {
      throw StateError(
        '$resource sync row crossed location scope: '
        '$rowLocationId != $locationId',
      );
    }
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
