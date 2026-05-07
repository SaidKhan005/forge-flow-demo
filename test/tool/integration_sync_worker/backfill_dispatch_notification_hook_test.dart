// Phase 8 W2.B - notification terminal-hook wiring test.
//
// Asserts that IntegrationSyncWorkerBackfillDispatch fires the
// onTerminalOutcome hook on succeeded + failed paths. The hook is
// the seam the production binder threads to
// `notification_event_hooks.emitBackfillComplete` /
// `emitBackfillFailed`; verifying it fires here keeps the trigger
// site contract pinned without requiring a full fanout integration
// test.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/integration_sync_worker/backfill_dispatch.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _jobId = '00000000-0000-4000-8000-0000000000b1';
const String _connId = '00000000-0000-4000-8000-0000000000c1';
const String _workerId = 'worker-hooks';
const String _vendorId = 'lightspeed_lsk';

void main() {
  group('IntegrationSyncWorkerBackfillDispatch onTerminalOutcome hook', () {
    test('hook fires on succeeded path', () async {
      final calls = <_HookCall>[];
      final dispatcher = IntegrationSyncWorkerBackfillDispatch(
        onTerminalOutcome: ({
          required FirstConnectionBackfillJob job,
          required BackfillDispatchOutcome outcome,
          String? errorMessage,
        }) async {
          calls.add(_HookCall(
            job: job,
            outcome: outcome,
            errorMessage: errorMessage,
          ));
        },
      );
      final jobStore = _StubJobStore()..enqueueClaim(_buildJob());
      final adapter = _StubAdapter(
        result: BackfillResult(
          batchesCommitted: 1,
          recordsWritten: 1,
          cursorToken: 'cursor-done',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 13),
        ),
      );

      final outcome = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: _NoopSink(),
      );

      expect(outcome.outcome, BackfillDispatchOutcome.succeeded);
      expect(calls, hasLength(1));
      expect(calls.single.outcome, BackfillDispatchOutcome.succeeded);
      expect(calls.single.job.jobId, _jobId);
      expect(calls.single.errorMessage, isNull);
    });

    test('hook fires on failed (adapter throws) path', () async {
      final calls = <_HookCall>[];
      final dispatcher = IntegrationSyncWorkerBackfillDispatch(
        onTerminalOutcome: ({
          required FirstConnectionBackfillJob job,
          required BackfillDispatchOutcome outcome,
          String? errorMessage,
        }) async {
          calls.add(_HookCall(
            job: job,
            outcome: outcome,
            errorMessage: errorMessage,
          ));
        },
      );
      final jobStore = _StubJobStore()..enqueueClaim(_buildJob());
      final adapter = _StubAdapter(error: StateError('boom'));

      final outcome = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: _NoopSink(),
      );

      expect(outcome.outcome, BackfillDispatchOutcome.failed);
      expect(calls, hasLength(1));
      expect(calls.single.outcome, BackfillDispatchOutcome.failed);
      expect(calls.single.errorMessage, contains('boom'));
    });

    test('hook does not fire on resumable path', () async {
      final calls = <_HookCall>[];
      final dispatcher = IntegrationSyncWorkerBackfillDispatch(
        onTerminalOutcome: ({
          required FirstConnectionBackfillJob job,
          required BackfillDispatchOutcome outcome,
          String? errorMessage,
        }) async {
          calls.add(_HookCall(
            job: job,
            outcome: outcome,
            errorMessage: errorMessage,
          ));
        },
      );
      final jobStore = _StubJobStore()..enqueueClaim(_buildJob());
      final adapter = _StubAdapter(
        result: BackfillResult(
          batchesCommitted: 1,
          recordsWritten: 1,
          cursorToken: 'cursor-mid',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 13),
          completed: false,
        ),
      );

      final outcome = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: _NoopSink(),
      );

      expect(outcome.outcome, BackfillDispatchOutcome.resumable);
      expect(calls, isEmpty);
    });

    test('hook exception is swallowed (no throw escapes dispatcher)',
        () async {
      final dispatcher = IntegrationSyncWorkerBackfillDispatch(
        onTerminalOutcome: ({
          required FirstConnectionBackfillJob job,
          required BackfillDispatchOutcome outcome,
          String? errorMessage,
        }) async {
          throw StateError('hook boom');
        },
      );
      final jobStore = _StubJobStore()..enqueueClaim(_buildJob());
      final adapter = _StubAdapter(
        result: BackfillResult(
          batchesCommitted: 1,
          recordsWritten: 1,
          cursorToken: 'cursor-done',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 13),
        ),
      );

      final outcome = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: _NoopSink(),
      );
      expect(outcome.outcome, BackfillDispatchOutcome.succeeded);
    });
  });
}

class _HookCall {
  _HookCall({
    required this.job,
    required this.outcome,
    required this.errorMessage,
  });
  final FirstConnectionBackfillJob job;
  final BackfillDispatchOutcome outcome;
  final String? errorMessage;
}

FirstConnectionBackfillJob _buildJob() {
  final windowEnd = DateTime.utc(2026, 5, 6, 12);
  return FirstConnectionBackfillJob(
    jobId: _jobId,
    operatorId: _opId,
    locationId: _locId,
    connectionId: _connId,
    vendorId: _vendorId,
    category: IntegrationCategory.pos,
    windowStart: windowEnd.subtract(const Duration(days: 60)),
    windowEnd: windowEnd,
    status: FirstConnectionBackfillJobStatus.running,
    attemptCount: 1,
    workerId: _workerId,
    claimedAt: DateTime.utc(2026, 5, 6, 12, 1),
    createdAt: DateTime.utc(2026, 5, 6, 12),
    updatedAt: DateTime.utc(2026, 5, 6, 12, 1),
  );
}

class _StubJobStore implements BackfillJobStore {
  final List<FirstConnectionBackfillJob> _claims = [];
  void enqueueClaim(FirstConnectionBackfillJob job) => _claims.add(job);

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async {
    if (_claims.isEmpty) return null;
    return _claims.removeAt(0);
  }

  @override
  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) async => null;

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async => null;

  @override
  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) async => null;
}

class _NoopSink implements CanonicalSink {
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
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {}
}

class _StubAdapter implements PosAdapter {
  _StubAdapter({this.result, this.error});

  final BackfillResult? result;
  final Object? error;

  @override
  String get vendorId => _vendorId;

  @override
  String get displayName => 'Stub POS';

  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: _vendorId,
        displayName: 'Stub POS',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
      );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    if (error != null) throw error!;
    return result!;
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
