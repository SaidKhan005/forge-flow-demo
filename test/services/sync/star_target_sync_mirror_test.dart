import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/domain/models/target_profile_version.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/star_target_sync_resources.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';

const String _opId = '00000000-0000-4000-8000-000000000a03';
const String _locId = '00000000-0000-4000-8000-0000000000b3';

void main() {
  late ImportTrackingDao watermarkDao;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
  });

  test('mirrors selected stars, target cycles, profiles, and versions into '
      'existing SQLite caches with scoped cursors', () async {
    const rid = 'rest_star_target_cache';
    await _clearStarTargetRows(rid);
    await SqliteBaselineSelectionRepository.instance.replaceSelectedRecordKeys(
      rid,
      {'local_only_stale'},
    );

    final client = _StarTargetSyncClient()
      ..selectedPages.addAll(<SelectedStarShiftDecisionPage>[
        SelectedStarShiftDecisionPage(
          decisions: const <SelectedStarShiftDecisionSyncRow>[
            SelectedStarShiftDecisionSyncRow(
              operatorId: _opId,
              locationId: _locId,
              restaurantId: rid,
              recordKey: '2026-W18|Mon|lunch',
              isSelected: true,
              isClear: false,
              decisionType: 'manager_selected',
            ),
            SelectedStarShiftDecisionSyncRow(
              operatorId: _opId,
              locationId: _locId,
              restaurantId: rid,
              recordKey: '2026-W18|Tue|dinner',
              isSelected: true,
              isClear: false,
              decisionType: 'manager_selected',
            ),
          ],
          nextCursor: 'selected-cursor-1',
        ),
        SelectedStarShiftDecisionPage(
          decisions: const <SelectedStarShiftDecisionSyncRow>[
            SelectedStarShiftDecisionSyncRow(
              operatorId: _opId,
              locationId: _locId,
              restaurantId: rid,
              recordKey: '2026-W18|Mon|lunch',
              isSelected: false,
              isClear: true,
              decisionType: 'manager_cleared',
            ),
          ],
          nextCursor: null,
        ),
      ])
      ..cyclePages.addAll(<TargetCycleSyncPage>[
        TargetCycleSyncPage(
          cycles: <TargetCycleSyncRow>[
            TargetCycleSyncRow(
              operatorId: _opId,
              locationId: _locId,
              cycle: _cycle(rid),
            ),
          ],
          nextCursor: 'cycle-cursor-1',
        ),
        const TargetCycleSyncPage(
          cycles: <TargetCycleSyncRow>[],
          nextCursor: null,
        ),
      ])
      ..profilePages.addAll(<ActiveTargetProfileSyncPage>[
        ActiveTargetProfileSyncPage(
          profiles: <ActiveTargetProfileSyncRow>[
            ActiveTargetProfileSyncRow(
              operatorId: _opId,
              locationId: _locId,
              targetCycleId: 'cycle-sync-1',
              targetProfileVersionId: 'tpv-sync-1',
              profile: _profile(rid),
            ),
          ],
          nextCursor: 'profile-cursor-1',
        ),
        const ActiveTargetProfileSyncPage(
          profiles: <ActiveTargetProfileSyncRow>[],
          nextCursor: null,
        ),
      ])
      ..versionPages.addAll(<TargetProfileVersionSyncPage>[
        TargetProfileVersionSyncPage(
          versions: <TargetProfileVersionSyncRow>[
            TargetProfileVersionSyncRow(
              operatorId: _opId,
              locationId: _locId,
              targetCycleId: 'cycle-sync-1',
              version: _version(rid),
            ),
          ],
          nextCursor: 'version-cursor-1',
        ),
        const TargetProfileVersionSyncPage(
          versions: <TargetProfileVersionSyncRow>[],
          nextCursor: null,
        ),
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

    expect(result.starTargetMirrors.allAvailable, isTrue);
    expect(result.starTargetMirrors.selectedStars.rowsWritten, 3);
    expect(result.starTargetMirrors.targetCycles.rowsWritten, 1);
    expect(result.starTargetMirrors.activeTargetProfiles.rowsWritten, 1);
    expect(result.starTargetMirrors.targetProfileVersions.rowsWritten, 1);

    final selected = await SqliteBaselineSelectionRepository.instance
        .getSelectedRecordKeys(rid);
    expect(selected, {'2026-W18|Tue|dinner'});

    final cycle = await SqliteTargetCycleRepository.instance.getActiveCycle(
      rid,
    );
    expect(cycle!.cycleId, 'cycle-sync-1');
    expect(cycle.source, TargetCycleSource.managerOverride);
    expect(cycle.managerOverrideUsed, isTrue);

    final profile = await SqliteTargetProfileRepository.instance
        .getActiveTargetProfile(rid);
    expect(profile!.targetProfileId, 'profile-sync-1');
    expect(profile.sourceType, 'cycle_manager_override');

    final version = await SqliteTargetProfileRepository.instance
        .getTargetProfileVersion(rid, 'tpv-sync-1');
    expect(version, isNotNull);
    expect(version!.targetProfileId, 'profile-sync-1');

    expect(client.selectedCursors, <String?>[null, 'selected-cursor-1']);
    expect(client.cycleCursors, <String?>[null, 'cycle-cursor-1']);
    expect(client.profileCursors, <String?>[null, 'profile-cursor-1']);
    expect(client.versionCursors, <String?>[null, 'version-cursor-1']);

    final selectedCursor = await watermarkDao.getWatermark(
      rid,
      'pg_selected_star_shift_decision_sync:$_opId:$_locId',
      'cursor',
    );
    final cycleCursor = await watermarkDao.getWatermark(
      rid,
      'pg_target_cycle_sync:$_opId:$_locId',
      'cursor',
    );
    expect(selectedCursor!.watermarkValue, 'selected-cursor-1');
    expect(cycleCursor!.watermarkValue, 'cycle-cursor-1');
  });

  test(
    'legacy client without star-target routes reports unavailable and leaves '
    'local cache untouched',
    () async {
      const rid = 'rest_star_target_legacy';
      await _clearStarTargetRows(rid);
      await SqliteBaselineSelectionRepository.instance
          .replaceSelectedRecordKeys(rid, {'local-only-key'});

      final sync = PostgresShiftRecordToMobileSync(
        client: _LegacySyncProxyClient(),
        shiftRepository: SqliteShiftRecordRepository.instance,
        watermarkDao: watermarkDao,
      );
      final result = await sync.sync(
        operatorId: _opId,
        locationId: _locId,
        restaurantId: rid,
      );

      expect(
        result.starTargetMirrors.selectedStars.state,
        StarTargetResourceSyncState.unavailable,
      );
      expect(
        result.starTargetMirrors.selectedStars.unavailableReason,
        'star_target_proxy_client_not_configured',
      );
      expect(
        await SqliteBaselineSelectionRepository.instance.getSelectedRecordKeys(
          rid,
        ),
        {'local-only-key'},
      );
    },
  );

  test('scoped row mismatch is rejected before cache write', () async {
    const rid = 'rest_star_target_scope_mismatch';
    await _clearStarTargetRows(rid);
    final client = _StarTargetSyncClient()
      ..selectedPages.add(
        const SelectedStarShiftDecisionPage(
          decisions: <SelectedStarShiftDecisionSyncRow>[
            SelectedStarShiftDecisionSyncRow(
              operatorId: 'wrong-op',
              locationId: _locId,
              restaurantId: rid,
              recordKey: '2026-W18|Wed|lunch',
              isSelected: true,
              isClear: false,
            ),
          ],
          nextCursor: null,
        ),
      );

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
    );

    await expectLater(
      sync.sync(operatorId: _opId, locationId: _locId, restaurantId: rid),
      throwsA(isA<StateError>()),
    );
    expect(
      await SqliteBaselineSelectionRepository.instance.getSelectedRecordKeys(
        rid,
      ),
      isEmpty,
    );
  });
}

Future<void> _clearStarTargetRows(String restaurantId) async {
  final db = await SqliteDatabase.instance.database;
  for (final table in const <String>[
    'baseline_selected_records',
    'target_cycles',
    'active_target_profiles',
    'target_profile_versions',
    'sync_watermarks',
  ]) {
    await db.delete(
      table,
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
  }
}

TargetCycle _cycle(String restaurantId) => TargetCycle(
  cycleId: 'cycle-sync-1',
  restaurantId: restaurantId,
  source: TargetCycleSource.managerOverride,
  effectiveStart: '2026-05-01',
  effectiveEnd: '2026-06-30',
  calibrationWindowStart: '2026-03-01',
  calibrationWindowEnd: '2026-04-30',
  targetCPLH: 5.2,
  targetSPLH: 181,
  targetPPA: 44,
  fohWage: 18,
  bohWage: 23,
  opzFloorCPLH: 3.5,
  opzCeilingCPLH: 7,
  managerOverrideUsed: true,
  managerOverrideAt: '2026-05-06T12:00:00Z',
  createdAt: '2026-05-06T12:00:00Z',
);

ActiveTargetProfile _profile(String restaurantId) => ActiveTargetProfile(
  targetProfileId: 'profile-sync-1',
  restaurantId: restaurantId,
  sourceType: 'cycle_manager_override',
  targetCPLH: 5.2,
  targetSPLH: 181,
  targetPPA: 44,
  fohWage: 18,
  bohWage: 23,
  opzFloorCPLH: 3.5,
  opzCeilingCPLH: 7,
  theoreticalFohLaborPct: 7.87,
  theoreticalBohLaborPct: 12.7,
  theoreticalLaborPct: 20.57,
  builtAt: '2026-05-06T12:01:00Z',
);

TargetProfileVersion _version(String restaurantId) => TargetProfileVersion(
  targetProfileVersionId: 'tpv-sync-1',
  targetProfileId: 'profile-sync-1',
  restaurantId: restaurantId,
  sourceType: 'cycle_manager_override',
  targetCPLH: 5.2,
  targetSPLH: 181,
  targetPPA: 44,
  fohWage: 18,
  bohWage: 23,
  opzFloorCPLH: 3.5,
  opzCeilingCPLH: 7,
  theoreticalFohLaborPct: 7.87,
  theoreticalBohLaborPct: 12.7,
  theoreticalLaborPct: 20.57,
  createdAt: '2026-05-06T12:01:00Z',
);

class _StarTargetSyncClient
    implements SyncProxyClient, StarTargetSyncProxyClient {
  final List<SelectedStarShiftDecisionPage> selectedPages =
      <SelectedStarShiftDecisionPage>[];
  final List<TargetCycleSyncPage> cyclePages = <TargetCycleSyncPage>[];
  final List<ActiveTargetProfileSyncPage> profilePages =
      <ActiveTargetProfileSyncPage>[];
  final List<TargetProfileVersionSyncPage> versionPages =
      <TargetProfileVersionSyncPage>[];

  final List<String?> selectedCursors = <String?>[];
  final List<String?> cycleCursors = <String?>[];
  final List<String?> profileCursors = <String?>[];
  final List<String?> versionCursors = <String?>[];

  @override
  Future<SelectedStarShiftDecisionPage> fetchSelectedStarShiftDecisions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    selectedCursors.add(cursor);
    if (selectedPages.isEmpty) {
      return const SelectedStarShiftDecisionPage(
        decisions: <SelectedStarShiftDecisionSyncRow>[],
        nextCursor: null,
      );
    }
    return selectedPages.removeAt(0);
  }

  @override
  Future<TargetCycleSyncPage> fetchTargetCycles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    cycleCursors.add(cursor);
    if (cyclePages.isEmpty) {
      return const TargetCycleSyncPage(
        cycles: <TargetCycleSyncRow>[],
        nextCursor: null,
      );
    }
    return cyclePages.removeAt(0);
  }

  @override
  Future<ActiveTargetProfileSyncPage> fetchActiveTargetProfiles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    profileCursors.add(cursor);
    if (profilePages.isEmpty) {
      return const ActiveTargetProfileSyncPage(
        profiles: <ActiveTargetProfileSyncRow>[],
        nextCursor: null,
      );
    }
    return profilePages.removeAt(0);
  }

  @override
  Future<TargetProfileVersionSyncPage> fetchTargetProfileVersions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    versionCursors.add(cursor);
    if (versionPages.isEmpty) {
      return const TargetProfileVersionSyncPage(
        versions: <TargetProfileVersionSyncRow>[],
        nextCursor: null,
      );
    }
    return versionPages.removeAt(0);
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    return const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    return const OpenShiftSnapshotPage(
      snapshots: <OpenShiftSnapshot>[],
      nextCursor: null,
    );
  }

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async {
    return null;
  }

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    return const <DemoModeRecord>[];
  }

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async {
    return const <DataAccuracyServicePeriodSetting>[];
  }

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }
}

class _LegacySyncProxyClient implements SyncProxyClient {
  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    return const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    return const OpenShiftSnapshotPage(
      snapshots: <OpenShiftSnapshot>[],
      nextCursor: null,
    );
  }

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async {
    return null;
  }

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    return const <DemoModeRecord>[];
  }

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async {
    return const <DataAccuracyServicePeriodSetting>[];
  }

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async {
    return null;
  }
}
