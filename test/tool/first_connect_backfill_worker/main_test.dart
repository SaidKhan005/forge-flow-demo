// Phase 8 gap-2 — first_connect_backfill_worker tests.
//
// Covers the four scenarios called out in the slice prompt, against
// in-memory fakes (no live Postgres):
//
//   * happy path — claim → dispatch → mark succeeded → demo flip +
//     watermark advance + sync log on the canonical sink.
//   * SKIP LOCKED contention — two parallel runs against a single
//     available job; only one claims it (the fake job store mirrors
//     the migration's `FOR UPDATE SKIP LOCKED` semantics).
//   * cap-and-dead-letter — a job that fails 11 times ends terminal
//     `failed` with `last_error` prefixed `dead_lettered:cap_reached`
//     AND a single audit row with `action='backfill_dead_lettered'`.
//   * SIGTERM mid-tick — in-flight scope dispatch is allowed to
//     finish, but the loop exits before the next scope.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart'
    show
        LaborAdapterFactory,
        PosAdapterFactory,
        ReservationAdapterFactory,
        VendorWebhookSignatureVerifier;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/advisor_proxy/phase_8_vendor_integration_factories.dart'
    show Phase8VendorIntegrationFactories;
import '../../../tool/first_connect_backfill_worker/main.dart';
import '../../../tool/integration_sync_worker/backfill_dispatch.dart';

const String _opIdA = '11111111-1111-4111-8111-111111111111';
const String _locIdA = '22222222-2222-4222-8222-222222222222';
const String _opIdB = '33333333-3333-4333-8333-333333333333';
const String _locIdB = '44444444-4444-4444-8444-444444444444';
const String _connIdA = '55555555-5555-4555-8555-555555555555';
const String _jobIdA = '66666666-6666-4666-8666-666666666666';
const String _vendorId = 'lightspeed_lsk';
final DateTime _connectedAt = DateTime.utc(2026, 5, 6, 12);

void main() {
  group('buildWorkerRuntime', () {
    test('wires projection taps for backfill commits', () {
      final runtime = buildWorkerRuntime(
        config: WorkerRuntimeConfig(
          postgresUrl: 'postgres://test',
          pgcryptoEnvelopeKey: 'test-pgcrypto-key',
          webhookPublicBaseUri: Uri.parse('https://api.forgeflow.app'),
          maxAttempts: 10,
          maxJobsPerTick: 5,
          pollInterval: const Duration(seconds: 30),
          claimStaleAfter: const Duration(minutes: 15),
          workerIdPrefix: 'first-connect-backfill-test',
          loadedSecretNames: const <String>[],
          environment: const <String, String>{},
        ),
        poolFactory: (_) => _NeverPostgresPool(),
      );

      final drainer = runtime.projectionCommitDrainer;
      expect(drainer, isNotNull);
      expect(drainer!.tapCount, greaterThan(0));
      expect(drainer.hasTapForVendor('toast'), isTrue);
      expect(drainer.hasTapForVendor('adp'), isTrue);
      expect(drainer.hasTapForVendor('opentable'), isTrue);
    });
  });

  group('WorkerCanonicalSink', () {
    test('demo flip writes canonical demo_mode_state is_demo shape', () async {
      final wrapper = _FakeTenantWrapper();
      final sink = WorkerCanonicalSink(
        tenantWrapper: wrapper,
        clock: () => _connectedAt,
      );

      await sink.evaluateDemoFlip(
        operatorId: _opIdA,
        locationId: _locIdA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 1,
        connectionId: _connIdA,
      );

      expect(wrapper.executedSql, hasLength(1));
      final sql = wrapper.executedSql.single;
      expect(sql, contains('insert into public.demo_mode_state'));
      expect(sql, contains('category, is_demo'));
      expect(sql, contains('is_demo = false'));
      expect(sql, isNot(contains('public.demo_mode_states')));
      expect(sql, isNot(contains(' mode')));
    });
  });

  group('runWorkerTick', () {
    test(
      'happy path: claim → dispatch → mark succeeded → watermark + sync log + demo flip',
      () async {
        final scope = WorkerJobScope(operatorId: _opIdA, locationId: _locIdA);
        final scopeReader = _FakeScopeReader([scope]);
        final job = _job(jobId: _jobIdA, attemptCount: 1);
        final jobStore = _FakeBackfillJobStore()..addClaimable(scope, job);
        final canonicalSink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter()
          ..backfillResult = BackfillResult(
            batchesCommitted: 1,
            recordsWritten: 4,
            cursorToken: 'cursor-final',
            lastModifiedSeen: DateTime.utc(2026, 5, 6, 12, 30),
          );

        final result = await runWorkerTick(
          scopeReader: scopeReader,
          jobStore: jobStore,
          canonicalSink: canonicalSink,
          adapterFactory: (_) => adapter,
          workerId: 'worker-test',
          maxJobsPerTick: 5,
          claimStaleAfter: const Duration(minutes: 15),
        );

        expect(result.scopesEnumerated, 1);
        expect(result.attempted, 1);
        expect(result.succeeded, 1);
        expect(result.failed, 0);
        expect(jobStore.succeededJobIds, <String>[_jobIdA]);
        expect(canonicalSink.watermarkAdvances, hasLength(1));
        expect(
          canonicalSink.watermarkAdvances.single.cursorToken,
          'cursor-final',
        );
        expect(canonicalSink.syncLogs, hasLength(1));
        expect(canonicalSink.syncLogs.single.eventKind, 'backfill_success');
        expect(canonicalSink.demoFlips, hasLength(1));
        expect(canonicalSink.demoFlips.single.connectionId, job.connectionId);
      },
    );

    test(
      'SKIP LOCKED: only one of two parallel runs claims a single job',
      () async {
        // The fake store models `FOR UPDATE SKIP LOCKED` by handing out
        // each enqueued job exactly once across all concurrent claimers.
        // Two parallel runWorkerTick calls against a one-job scope must
        // result in exactly one dispatch.
        final scope = WorkerJobScope(operatorId: _opIdA, locationId: _locIdA);
        final scopeReader = _FakeScopeReader([scope]);
        final jobStore = _FakeBackfillJobStore()
          ..addClaimable(scope, _job(jobId: _jobIdA));
        final canonicalSink = _RecordingCanonicalSink();
        final adapterA = _RecordingPosAdapter();
        final adapterB = _RecordingPosAdapter();

        final futures = <Future<WorkerTickResult>>[
          runWorkerTick(
            scopeReader: scopeReader,
            jobStore: jobStore,
            canonicalSink: canonicalSink,
            adapterFactory: (_) => adapterA,
            workerId: 'worker-A',
            maxJobsPerTick: 5,
            claimStaleAfter: const Duration(minutes: 15),
          ),
          runWorkerTick(
            scopeReader: scopeReader,
            jobStore: jobStore,
            canonicalSink: canonicalSink,
            adapterFactory: (_) => adapterB,
            workerId: 'worker-B',
            maxJobsPerTick: 5,
            claimStaleAfter: const Duration(minutes: 15),
          ),
        ];
        final results = await Future.wait(futures);

        final totalAttempted = results.fold<int>(
          0,
          (acc, r) => acc + r.attempted,
        );
        expect(
          totalAttempted,
          1,
          reason:
              'SKIP LOCKED: a single available job must be claimed exactly once '
              'across two concurrent workers',
        );
        expect(adapterA.backfillCalls + adapterB.backfillCalls, 1);
        expect(jobStore.claimAttempts, greaterThanOrEqualTo(1));
      },
    );
  });

  group('RetryCappingBackfillJobStore', () {
    test(
      'after MAX_ATTEMPTS failures the job is dead-lettered with audit row',
      () async {
        final tenantWrapper = _FakeTenantWrapper();
        final delegate = _StubMarkFailedDelegate();
        final clock = DateTime.utc(2026, 5, 6, 13);
        final cappingStore = RetryCappingBackfillJobStore(
          delegate: delegate,
          maxAttempts: 10,
          tenantWrapper: tenantWrapper,
          clock: () => clock,
        );

        // Simulate 9 sub-cap failures (attempt 1..9): no marker, no
        // audit row.
        for (var i = 1; i <= 9; i += 1) {
          delegate.nextAttemptCount = i;
          await cappingStore.markFailed(
            operatorId: _opIdA,
            locationId: _locIdA,
            jobId: _jobIdA,
            errorMessage: 'transient-$i',
          );
        }
        expect(delegate.markFailedCalls, 9);
        expect(tenantWrapper.auditRows, isEmpty);

        // 10th failure trips the cap (attempt_count == maxAttempts).
        delegate.nextAttemptCount = 10;
        final result = await cappingStore.markFailed(
          operatorId: _opIdA,
          locationId: _locIdA,
          jobId: _jobIdA,
          errorMessage: 'transient-10',
        );

        expect(
          delegate.markFailedCalls,
          11,
          reason:
              'cap path performs a second markFailed for the dead-letter marker',
        );
        expect(
          delegate.lastErrorMessages.last,
          startsWith(RetryCappingBackfillJobStore.deadLetterErrorPrefix),
        );
        expect(delegate.lastErrorMessages.last, contains('transient-10'));
        expect(result, isNotNull);
        expect(tenantWrapper.auditRows, hasLength(1));
        final audit = tenantWrapper.auditRows.single;
        expect(audit.operatorId, _opIdA);
        expect(
          audit.action,
          RetryCappingBackfillJobStore.deadLetterAuditAction,
        );
        expect(audit.targetId, _jobIdA);
        expect(audit.payload['vendor_id'], _vendorId);
        expect(audit.payload['attempt_count'], 10);
      },
    );
  });

  group('BackfillWorkerLoop', () {
    test(
      'requestStop drains in-flight scope and exits before the next tick',
      () async {
        final scopes = <WorkerJobScope>[
          WorkerJobScope(operatorId: _opIdA, locationId: _locIdA),
          WorkerJobScope(operatorId: _opIdB, locationId: _locIdB),
        ];
        final scopeReader = _FakeScopeReader(scopes);
        final canonicalSink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter()
          ..backfillResult = BackfillResult(
            batchesCommitted: 1,
            recordsWritten: 1,
            cursorToken: 'cursor',
            lastModifiedSeen: DateTime.utc(2026, 5, 6),
          );
        final jobStore = _FakeBackfillJobStore()
          ..addClaimable(scopes[0], _job(jobId: _jobIdA))
          ..addClaimable(
            scopes[1],
            _job(jobId: '77777777-7777-4777-8777-777777777777'),
          );

        final loop = BackfillWorkerLoop(
          scopeReader: scopeReader,
          jobStore: jobStore,
          canonicalSink: canonicalSink,
          adapterFactory: (_) => adapter,
          workerId: 'worker-test',
          config: WorkerRuntimeConfig(
            postgresUrl: 'test://override',
            pgcryptoEnvelopeKey: 'test-pgcrypto-key',
            webhookPublicBaseUri: Uri.parse('https://api.forgeflow.app'),
            maxAttempts: 10,
            maxJobsPerTick: 1,
            pollInterval: const Duration(milliseconds: 50),
            claimStaleAfter: const Duration(minutes: 15),
            workerIdPrefix: 'first-connect-backfill',
            loadedSecretNames: const <String>[],
            environment: const <String, String>{},
          ),
        );

        // Fire the stop request after scope discovery finishes,
        // before any per-scope dispatch starts. The loop must exit
        // before scope B is dispatched.
        scopeReader.afterListClaimableScopes = () {
          loop.requestStop();
        };

        await loop.run().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            loop.requestStop();
            fail('loop did not exit after requestStop');
          },
        );

        // The shouldStop hook is checked between scopes inside
        // runWorkerTick; with the stop firing right after enumeration
        // finishes, no scope should have been dispatched in this tick.
        // Either way, scope B (the second one) must not have been
        // touched.
        expect(
          adapter.backfillCalls,
          lessThanOrEqualTo(1),
          reason:
              'requestStop after enumeration must prevent dispatch of the '
              'second scope',
        );
        expect(loop.isStopRequested, isTrue);
      },
    );
  });

  group('BinderBackedAdapterFactory', () {
    test(
      'looks up active POS factory and returns the per-tenant adapter',
      () async {
        final adapter = _RecordingPosAdapter();
        final factories = Phase8VendorIntegrationFactories(
          posAdapterFactories: <String, PosAdapterFactory>{
            _vendorId:
                ({
                  required String operatorId,
                  required String locationId,
                }) async => adapter,
          },
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          disabledVendors: const <String, String>{},
        );
        final factory = BinderBackedAdapterFactory(factories: factories);

        final result = factory.call(_job(jobId: _jobIdA));

        // Amendment A made adapter factories async. The
        // BinderBackedAdapterFactory.call returns Future<Object> so the
        // dispatcher can `await` the per-tenant construction; the test
        // unwraps the Future before identity-checking against the
        // recorded adapter instance.
        final resolved = await result;
        expect(identical(resolved, adapter), isTrue);
      },
    );

    test(
      'disabled vendor → BackfillVendorDisabledException with reason',
      () async {
        final factories = Phase8VendorIntegrationFactories(
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          disabledVendors: const <String, String>{
            'aloha_ncr_voyix': 'aloha_ncr_voyix_credentials_missing',
          },
        );
        final factory = BinderBackedAdapterFactory(factories: factories);

        expect(
          () => factory.call(
            _job(
              jobId: _jobIdA,
              vendorId: 'aloha_ncr_voyix',
              category: IntegrationCategory.pos,
            ),
          ),
          throwsA(
            isA<BackfillVendorDisabledException>()
                .having((e) => e.vendorId, 'vendorId', 'aloha_ncr_voyix')
                .having(
                  (e) => e.reason,
                  'reason',
                  'aloha_ncr_voyix_credentials_missing',
                )
                .having(
                  (e) => e.toString(),
                  'toString',
                  contains('not active in binder'),
                ),
          ),
        );
      },
    );

    test(
      'vendor not wired anywhere → BackfillVendorNotWiredException',
      () async {
        final factories = Phase8VendorIntegrationFactories(
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          disabledVendors: const <String, String>{},
        );
        final factory = BinderBackedAdapterFactory(factories: factories);

        expect(
          () => factory.call(
            _job(
              jobId: _jobIdA,
              vendorId: 'nonexistent_vendor',
              category: IntegrationCategory.labor,
            ),
          ),
          throwsA(
            isA<BackfillVendorNotWiredException>()
                .having((e) => e.vendorId, 'vendorId', 'nonexistent_vendor')
                .having(
                  (e) => e.category,
                  'category',
                  IntegrationCategory.labor,
                )
                .having(
                  (e) => e.toString(),
                  'toString',
                  contains('not wired in the Phase 8 binder builder'),
                ),
          ),
        );
      },
    );

    test(
      'disabled vendor surfaced through dispatcher → markFailed + clean reason',
      () async {
        // End-to-end through runWorkerTick: factory throws
        // BackfillVendorDisabledException, dispatcher records the
        // failure, and the job ends marked failed with a clean message
        // instead of a stack trace. Vendor must exist in the
        // dispatcher's category registry; we use an existing POS
        // vendor id (lightspeed_lsk is in the registry but disabled in
        // the binder per the async-location-config branch).
        final scope = WorkerJobScope(operatorId: _opIdA, locationId: _locIdA);
        final scopeReader = _FakeScopeReader([scope]);
        final job = _job(jobId: _jobIdA, attemptCount: 1);
        final jobStore = _FakeBackfillJobStore()..addClaimable(scope, job);
        final canonicalSink = _RecordingCanonicalSink();
        final factories = Phase8VendorIntegrationFactories(
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          disabledVendors: const <String, String>{
            _vendorId: 'lightspeed_lsk_async_location_config_required',
          },
        );
        final adapterFactory = BinderBackedAdapterFactory(factories: factories);

        final result = await runWorkerTick(
          scopeReader: scopeReader,
          jobStore: jobStore,
          canonicalSink: canonicalSink,
          adapterFactory: adapterFactory.call,
          workerId: 'worker-test',
          maxJobsPerTick: 5,
          claimStaleAfter: const Duration(minutes: 15),
        );

        expect(result.attempted, 1);
        expect(result.failed, 1);
        expect(jobStore.failedJobIds, <String>[_jobIdA]);
        expect(canonicalSink.syncLogs, hasLength(1));
        expect(canonicalSink.syncLogs.single.eventKind, 'backfill_error');
      },
    );
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _FakeScopeReader implements WorkerScopeReader {
  _FakeScopeReader(this._scopes);

  final List<WorkerJobScope> _scopes;
  void Function()? afterListClaimableScopes;

  @override
  Future<List<WorkerJobScope>> listClaimableScopes({
    required Duration claimStaleAfter,
  }) async {
    final scopes = List<WorkerJobScope>.unmodifiable(_scopes);
    afterListClaimableScopes?.call();
    return scopes;
  }
}

class _FakeBackfillJobStore implements BackfillJobStore {
  // Per-scope claim queues. Mirrors `FOR UPDATE SKIP LOCKED`: a job
  // is removed atomically on the first successful claimNext, so a
  // concurrent claimer sees it as already taken.
  final Map<String, List<FirstConnectionBackfillJob>> _claimQueues =
      <String, List<FirstConnectionBackfillJob>>{};
  final List<String> succeededJobIds = <String>[];
  final List<String> failedJobIds = <String>[];
  final List<String> resumedJobIds = <String>[];
  int claimAttempts = 0;

  void addClaimable(WorkerJobScope scope, FirstConnectionBackfillJob job) {
    final key = '${scope.operatorId}:${scope.locationId}';
    _claimQueues
        .putIfAbsent(key, () => <FirstConnectionBackfillJob>[])
        .add(job);
  }

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) async {
    claimAttempts += 1;
    final key = '$operatorId:$locationId';
    final queue = _claimQueues[key];
    if (queue == null || queue.isEmpty) return null;
    return queue.removeAt(0);
  }

  @override
  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) async {
    succeededJobIds.add(jobId);
    return null;
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async {
    failedJobIds.add(jobId);
    return null;
  }

  @override
  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) async {
    resumedJobIds.add(jobId);
    return null;
  }
}

class _StubMarkFailedDelegate implements BackfillJobStore {
  int markFailedCalls = 0;
  final List<String> lastErrorMessages = <String>[];
  int nextAttemptCount = 1;

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async {
    markFailedCalls += 1;
    lastErrorMessages.add(errorMessage);
    return _job(jobId: jobId, attemptCount: nextAttemptCount);
  }

  @override
  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) {
    throw UnimplementedError();
  }
}

class _RecordingCanonicalSink implements CanonicalSink {
  final List<_WatermarkAdvance> watermarkAdvances = <_WatermarkAdvance>[];
  final List<_SyncLogEntry> syncLogs = <_SyncLogEntry>[];
  final List<_DemoFlip> demoFlips = <_DemoFlip>[];

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async => true;

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async => true;

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async => true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarkAdvances.add(
      _WatermarkAdvance(connectionId: connectionId, cursorToken: cursorToken),
    );
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    syncLogs.add(
      _SyncLogEntry(eventKind: eventKind, recordsCount: recordsCount ?? 0),
    );
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    if (connectionStatus == ConnectionStatus.connected &&
        firstBackfillCommitted &&
        backfillRecordsWritten > 0) {
      demoFlips.add(_DemoFlip(connectionId: connectionId, category: category));
    }
  }
}

class _WatermarkAdvance {
  _WatermarkAdvance({required this.connectionId, required this.cursorToken});
  final String connectionId;
  final String cursorToken;
}

class _SyncLogEntry {
  _SyncLogEntry({required this.eventKind, required this.recordsCount});
  final String eventKind;
  final int recordsCount;
}

class _DemoFlip {
  _DemoFlip({required this.connectionId, required this.category});
  final String connectionId;
  final IntegrationCategory category;
}

class _RecordingPosAdapter implements PosAdapter {
  int backfillCalls = 0;
  BackfillResult backfillResult = BackfillResult(
    batchesCommitted: 1,
    recordsWritten: 1,
    cursorToken: 'cursor-default',
    lastModifiedSeen: DateTime.utc(2026, 5, 6),
  );

  @override
  String get vendorId => _vendorId;

  @override
  String get displayName => 'Recording POS';

  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: _vendorId,
        displayName: 'Recording POS',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
      );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    backfillCalls += 1;
    return backfillResult;
  }

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) => throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) =>
      throw UnimplementedError();

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();
}

class _NeverPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError('test must not touch Postgres');
  }
}

class _AuditRowCapture {
  _AuditRowCapture({
    required this.operatorId,
    this.locationId,
    required this.action,
    this.targetId,
    required this.payload,
  });

  final String operatorId;
  final String? locationId;
  final String action;
  final String? targetId;
  final Map<String, Object?> payload;
}

class _FakeTenantWrapper implements TenantTransactionWrapper {
  final List<_AuditRowCapture> auditRows = <_AuditRowCapture>[];
  final List<String> executedSql = <String>[];

  @override
  Future<R> runInTenantContext<R>(
    TenantContext context,
    Future<R> Function(PostgresExecutor exec) body,
  ) {
    final exec = _CapturingExecutor(_onAuditInsert, executedSql.add);
    return body(exec);
  }

  @override
  Future<R> runInUserContext<R>(
    String userId,
    Future<R> Function(PostgresExecutor exec) body,
  ) {
    final exec = _CapturingExecutor(_onAuditInsert, executedSql.add);
    return body(exec);
  }

  @override
  Future<R> runAsSystem<R>(
    Future<R> Function(PostgresExecutor exec) body, {
    required String reason,
  }) {
    final exec = _CapturingExecutor(_onAuditInsert, executedSql.add);
    return body(exec);
  }

  void _onAuditInsert(_AuditRowCapture row) {
    auditRows.add(row);
  }
}

class _CapturingExecutor implements PostgresExecutor {
  _CapturingExecutor(this._onAuditInsert, this._onExecute);

  final void Function(_AuditRowCapture) _onAuditInsert;
  final void Function(String sql) _onExecute;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('insert into public.audit_logs')) {
      _onAuditInsert(
        _AuditRowCapture(
          operatorId: parameters['operator_id']! as String,
          locationId: parameters['location_id'] as String?,
          action: parameters['action']! as String,
          targetId: parameters['target_id'] as String?,
          payload: _decodePayload(parameters['payload']),
        ),
      );
      return <PostgresRow>[
        <String, Object?>{'id': 1},
      ];
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    _onExecute(sql);
    return 0;
  }

  Map<String, Object?> _decodePayload(Object? raw) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return <String, Object?>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
      }
    }
    return const <String, Object?>{};
  }
}

// ─── Test fixture helpers ───────────────────────────────────────────

FirstConnectionBackfillJob _job({
  required String jobId,
  int attemptCount = 0,
  IntegrationCategory category = IntegrationCategory.pos,
  String? cursorToken,
  String vendorId = _vendorId,
}) {
  final window = FirstConnectionBackfillWindow.lastSixtyDays(_connectedAt);
  return FirstConnectionBackfillJob(
    jobId: jobId,
    operatorId: _opIdA,
    locationId: _locIdA,
    connectionId: _connIdA,
    vendorId: vendorId,
    category: category,
    windowStart: window.windowStart,
    windowEnd: window.windowEnd,
    status: FirstConnectionBackfillJobStatus.running,
    attemptCount: attemptCount,
    cursorToken: cursorToken,
    workerId: 'worker-test',
    claimedAt: _connectedAt,
    createdAt: _connectedAt,
    updatedAt: _connectedAt,
  );
}
