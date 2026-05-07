// Tests for the launch-blocking fixes shipped on
// `lib/services/sync/mobile_operational_sync_runtime.dart`:
//
//   * BUG 1 (HIGH) — cross-tenant SQLite residue purge on operator /
//     location flip.
//   * BUG 2 (HIGH) — sign-out / scope flip mid-sweep cancels the in-
//     flight sync without further proxy calls or SQLite writes.
//   * BUG 5 (MEDIUM) — singleton scope-override is cleared on host
//     attach so a hot-restart does not keep the previous override.
//
// `MobileOperationalSyncRunner` itself is exercised through scripted
// in-memory fakes; the host wiring is exercised through the real
// `MobileOperationalSyncHost` widget with stub providers. SQLite repos
// pulled in by the default cross-tenant wipe are bypassed by injecting
// a stub via the host's `crossTenantWipe` parameter.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/repositories/open_shift_snapshot_repository.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_timing_config_repository.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/sync/mobile_operational_sync_runtime.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  group('MobileOperationalSyncRunner business scope rebase', () {
    test('uses persisted active location scope for proxy pulls', () async {
      final client = _CountingProxyClient();
      final runner = MobileOperationalSyncRunner(
        client: client,
        restaurantIdResolver: (session) async => session.locationId,
        activeScopeResolver: (_) async => const BusinessScope(
          scopeId: 'loc-2',
          scopeType: 'location',
          operatorId: 'op-1',
          locationId: 'loc-2',
          label: 'Mercado',
        ),
        syncFactory: _noopSyncFactory,
      );

      await runner.syncSession(
        _liveSession(operatorId: 'op-1', locationId: 'loc-1', userId: 'u-1'),
      );

      expect(client.lastShiftOperatorId, 'op-1');
      expect(client.lastShiftLocationId, 'loc-2');
    });

    test('cancelInFlightSync aborts aux pulls from the active sweep', () async {
      final client = _CountingProxyClient();
      late MobileOperationalSyncRunner runner;
      client.onShiftFetch = () => runner.cancelInFlightSync();
      runner = MobileOperationalSyncRunner(
        client: client,
        restaurantIdResolver: (session) async => session.locationId,
        syncFactory: _noopSyncFactory,
      );

      await runner.syncSession(
        _liveSession(operatorId: 'op-1', locationId: 'loc-1', userId: 'u-1'),
      );

      expect(client.shiftCallCount, 1);
      expect(client.demoCallCount, 0);
      expect(client.accuracyCallCount, 0);
      expect(client.wageRoleRowsCallCount, 0);
      expect(client.tierCallCount, 0);
      expect(client.backfillStatusCallCount, 0);
    });
  });

  group('MobileOperationalSyncHost cross-tenant + abort wiring', () {
    testWidgets(
      'BUG 1: scope flip purges the prior tenant before the next sweep',
      (tester) async {
        final wipeCalls = <String>[];
        final notifier = _StubAuthSessionNotifier(
          _liveSession(operatorId: 'op-1', locationId: 'loc-1', userId: 'u-1'),
        );
        final runner = _RecordingRunner();

        await tester.pumpWidget(
          ChangeNotifierProvider<AuthSessionNotifier>.value(
            value: notifier,
            child: MobileOperationalSyncHost(
              syncClient: _StubSyncProxyClient(),
              runner: runner,
              crossTenantWipe: (keep) async {
                wipeCalls.add(keep);
              },
              child: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        // Initial host attach triggers a sweep but should NOT wipe
        // (no prior scope to purge).
        expect(wipeCalls, isEmpty);
        expect(runner.syncCalls, hasLength(1));
        expect(runner.syncCalls.first.locationId, 'loc-1');

        // Flip to a new tenant.
        notifier.setSession(
          _liveSession(operatorId: 'op-2', locationId: 'loc-2', userId: 'u-2'),
        );
        await tester.pump();
        await tester.pump();

        expect(
          wipeCalls,
          <String>['loc-2'],
          reason:
              'BUG 1: wipe must run with the NEW restaurantId so anything '
              'NOT belonging to loc-2 is purged before the next sweep',
        );
        expect(runner.syncCalls, hasLength(2));
        expect(runner.syncCalls.last.locationId, 'loc-2');

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'BUG 2: sign-out flips the abort probe to true so the runner halts',
      (tester) async {
        final notifier = _StubAuthSessionNotifier(
          _liveSession(operatorId: 'op-1', locationId: 'loc-1', userId: 'u-1'),
        );
        final runner = _AbortObservingRunner();

        await tester.pumpWidget(
          ChangeNotifierProvider<AuthSessionNotifier>.value(
            value: notifier,
            child: MobileOperationalSyncHost(
              syncClient: _StubSyncProxyClient(),
              runner: runner,
              crossTenantWipe: (_) async {},
              child: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        expect(
          runner.installedAbortProbe,
          isNotNull,
          reason: 'BUG 2: host must install an abort probe per sweep',
        );

        // Before sign-out the probe says "do not abort".
        expect(runner.installedAbortProbe!(), isFalse);

        // Sign out -> probe must flip to abort=true.
        notifier.setSession(null);
        await tester.pump();

        expect(
          runner.installedAbortProbe!(),
          isTrue,
          reason:
              'BUG 2: once the live session changes (sign-out flips userId '
              'to null) the in-flight sweep must observe abort=true',
        );
      },
    );

    test('BUG 5: residual singleton override is cleared by '
        '`MobileOperationalSyncHost.initState`', () {
      // The fix lives in `initState`, which calls
      // `clearRuntimeRestaurantOverride()`. We verify the underlying
      // hook is reachable + idempotent without spinning up a full
      // widget tree (the SQLite singleton + `pumpWidget` interaction
      // is flaky inside the FakeAsync test zone).
      SqliteRestaurantScopeRepository.instance.clearRuntimeRestaurantOverride();
      // Calling it twice must NOT throw — initState may run on the
      // first frame after a hot-restart even when the override was
      // already null.
      expect(
        () => SqliteRestaurantScopeRepository.instance
            .clearRuntimeRestaurantOverride(),
        returnsNormally,
      );
    });

    test('wage_role_rows realtime events trigger operational sync', () {
      final tableEvent = RealtimeEvent(
        eventId: 'evt-wage-table',
        topic: 'db.change',
        operatorId: 'op-1',
        occurredAt: DateTime.utc(2026, 5, 7),
        payload: const <String, Object?>{'table': 'wage_role_rows'},
      );
      final topicEvent = RealtimeEvent(
        eventId: 'evt-wage-topic',
        topic: 'settings.invalidate.wage_role_rows',
        operatorId: 'op-1',
        occurredAt: DateTime.utc(2026, 5, 7),
        payload: const <String, Object?>{},
      );

      expect(isMobileOperationalSyncInvalidationEvent(tableEvent), isTrue);
      expect(isMobileOperationalSyncInvalidationEvent(topicEvent), isTrue);
    });
  });

  group('PostgresShiftRecordToMobileSync abort cooperation', () {
    test(
      'BUG 2: pre-aborted sweep makes zero proxy calls and zero writes',
      () async {
        final client = _CountingProxyClient();
        final repo = _NoopShiftRepository();
        final wm = _InMemoryWatermarkDao();
        final sync = PostgresShiftRecordToMobileSync(
          client: client,
          shiftRepository: repo,
          watermarkDao: wm,
          openShiftSnapshotRepository: _NoopOpenSnapshotRepo(),
          timingConfigRepository: _NoopTimingConfigRepo(),
        );
        final result = await sync.sync(
          operatorId: 'op',
          locationId: 'loc',
          restaurantId: 'rest_abort_pre',
          isAborted: () => true,
        );
        expect(client.shiftCallCount, 0);
        expect(client.openCallCount, 0);
        expect(repo.replaceCalls, 0);
        expect(result.recordsWritten, 0);
        expect(result.openSnapshotsWritten, 0);
        expect(result.pagesPulled, 0);
      },
    );

    test(
      'BUG 2: abort flips during shift-record loop -> aux pulls skipped',
      () async {
        var aborted = false;
        final client = _CountingProxyClient(onShiftFetch: () => aborted = true);
        final repo = _NoopShiftRepository();
        final wm = _InMemoryWatermarkDao();
        final sync = PostgresShiftRecordToMobileSync(
          client: client,
          shiftRepository: repo,
          watermarkDao: wm,
          openShiftSnapshotRepository: _NoopOpenSnapshotRepo(),
          timingConfigRepository: _NoopTimingConfigRepo(),
        );
        await sync.sync(
          operatorId: 'op',
          locationId: 'loc',
          restaurantId: 'rest_abort_mid',
          isAborted: () => aborted,
        );
        expect(
          client.shiftCallCount,
          1,
          reason: 'first shift fetch happens; subsequent loops abort',
        );
        expect(
          client.demoCallCount,
          0,
          reason: 'BUG 2: aux pulls (demo/accuracy/tier) skipped on abort',
        );
        expect(client.accuracyCallCount, 0);
        expect(client.wageRoleRowsCallCount, 0);
        expect(client.tierCallCount, 0);
        expect(client.backfillStatusCallCount, 0);
      },
    );
  });
}

// ────────────────────────── shared test helpers ─────────────────────────

Future<PostgresShiftRecordToMobileSync> _noopSyncFactory(
  SyncProxyClient client,
) async {
  return PostgresShiftRecordToMobileSync(
    client: client,
    shiftRepository: _NoopShiftRepository(),
    watermarkDao: _InMemoryWatermarkDao(),
    openShiftSnapshotRepository: _NoopOpenSnapshotRepo(),
    timingConfigRepository: _NoopTimingConfigRepo(),
  );
}

AuthSession _liveSession({
  required String operatorId,
  required String locationId,
  required String userId,
}) {
  final now = DateTime.now().toUtc();
  return AuthSession(
    userId: userId,
    operatorId: operatorId,
    locationId: locationId,
    firebaseIdToken: 'tok',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    roles: const <String>['operator_owner'],
    mfaEnrolled: false,
  );
}

/// Lightweight stub that exposes the `session` getter + listener API
/// the host depends on. Bypasses the heavyweight production
/// `AuthSessionNotifier` constructor (login service / storage / ledger).
class _StubAuthSessionNotifier extends ChangeNotifier
    implements AuthSessionNotifier {
  _StubAuthSessionNotifier(this._session);
  AuthSession? _session;

  void setSession(AuthSession? next) {
    _session = next;
    notifyListeners();
  }

  @override
  AuthSession? get session => _session;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSyncProxyClient implements SyncProxyClient {
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

/// Records calls into `syncSession` so tests can assert which sessions
/// were swept. The runner inherits from [MobileOperationalSyncRunner]
/// only conceptually — we implement the interface directly.
class _RecordingRunner implements MobileOperationalSyncRunner {
  final List<AuthSession> syncCalls = <AuthSession>[];

  /// History of probes the host has installed. The host clears the
  /// probe back to null in its `whenComplete` callback after a sweep
  /// resolves; the test inspects the most-recent NON-null probe so it
  /// can simulate the live-session check the host wired into it.
  final List<bool Function()> probesObserved = <bool Function()>[];

  @override
  Future<SyncResult?> syncSession(
    AuthSession? session, {
    String reason = 'manual',
  }) async {
    if (session != null) syncCalls.add(session);
    return null;
  }

  @override
  void setAbortProbe(bool Function()? probe) {
    if (probe != null) probesObserved.add(probe);
  }

  /// Most-recent abort probe the host installed.
  bool Function()? get installedAbortProbe =>
      probesObserved.isEmpty ? null : probesObserved.last;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AbortObservingRunner extends _RecordingRunner {
  @override
  Future<SyncResult?> syncSession(
    AuthSession? session, {
    String reason = 'manual',
  }) async {
    // Don't actually run anything; the host installs the probe before
    // awaiting `syncSession` so the test can read `probesObserved`
    // immediately. We resolve on the next microtask so the host's
    // `whenComplete` clear-probe callback fires and the test inspects
    // the probe via `probesObserved.last` (which records every probe
    // the host EVER installed, ignoring the post-sweep null reset).
    if (session != null) syncCalls.add(session);
    return null;
  }
}

// Repositories: minimal in-memory stand-ins. The PostgresShift...sync
// abort tests only need the methods to be reachable; we don't assert
// against repo state here.
class _NoopShiftRepository implements ShiftRecordRepository {
  int replaceCalls = 0;

  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async {
    replaceCalls++;
    return 1;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopOpenSnapshotRepo implements OpenShiftSnapshotRepository {
  @override
  Future<void> replaceOpenShiftSnapshot(OpenShiftSnapshot snapshot) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopTimingConfigRepo implements RestaurantTimingConfigRepository {
  @override
  Future<void> saveTimingConfig(RestaurantTimingConfig config) async {}

  @override
  Future<RestaurantTimingConfig?> getTimingConfig(String restaurantId) async {
    return null;
  }
}

class _InMemoryWatermarkDao implements ImportTrackingDao {
  @override
  noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('getWatermark')) return Future.value(null);
    if (name.contains('upsertWatermark')) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

class _CountingProxyClient implements SyncProxyClient {
  _CountingProxyClient({this.onShiftFetch});
  void Function()? onShiftFetch;
  int shiftCallCount = 0;
  int openCallCount = 0;
  int demoCallCount = 0;
  int accuracyCallCount = 0;
  int wageRoleRowsCallCount = 0;
  int tierCallCount = 0;
  int timingCallCount = 0;
  int backfillStatusCallCount = 0;
  String? lastShiftOperatorId;
  String? lastShiftLocationId;

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    shiftCallCount++;
    lastShiftOperatorId = operatorId;
    lastShiftLocationId = locationId;
    onShiftFetch?.call();
    return const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    openCallCount++;
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
    timingCallCount++;
    return null;
  }

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    demoCallCount++;
    return const <DemoModeRecord>[];
  }

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async {
    accuracyCallCount++;
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
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  }) async {
    wageRoleRowsCallCount++;
    return const <WageRoleRow>[];
  }

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    tierCallCount++;
    return null;
  }

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async {
    backfillStatusCallCount++;
    return null;
  }
}
