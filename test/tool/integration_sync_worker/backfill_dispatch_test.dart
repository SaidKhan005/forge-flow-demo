// Phase 8 first-connect backfill worker dispatch tests.
//
// Exercises only the worker-side claim/dispatch/persist bridge. The durable
// repository and vendor adapters are faked so the poll path and writer
// internals stay outside this lane.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/integration_sync_worker/backfill_dispatch.dart';
import '../../../tool/integration_sync_worker/dispatch.dart'
    show kSyncWorkerServicePrincipalId;

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';
const String _jobId = '00000000-0000-4000-8000-0000000000b1';
const String _connId = '00000000-0000-4000-8000-0000000000c1';
const String _workerId = 'worker-lane-2';
const String _vendorId = 'lightspeed_lsk';

void main() {
  group('IntegrationSyncWorkerBackfillDispatch.dispatchNext', () {
    late IntegrationSyncWorkerBackfillDispatch dispatcher;
    late _FakeBackfillJobStore jobStore;
    late _RecordingCanonicalSink sink;
    late _RecordingPosAdapter adapter;

    setUp(() {
      dispatcher = const IntegrationSyncWorkerBackfillDispatch();
      jobStore = _FakeBackfillJobStore();
      sink = _RecordingCanonicalSink();
      adapter = _RecordingPosAdapter();
    });

    test(
      'happy path calls adapter.backfill once with bounded 60-day window',
      () async {
        adapter.backfillResult = BackfillResult(
          batchesCommitted: 2,
          recordsWritten: 7,
          cursorToken: 'cursor-done',
          lastModifiedSeen: DateTime.utc(2026, 5, 6, 13),
        );
        jobStore.enqueueClaim(_job(cursorToken: 'cursor-start'));

        final result = await dispatcher.dispatchNext(
          operatorId: _opId,
          locationId: _locId,
          workerId: _workerId,
          jobStore: jobStore,
          adapterFactory: (_) => adapter,
          canonicalSink: sink,
        );

        expect(result.outcome, BackfillDispatchOutcome.succeeded);
        expect(adapter.backfillCalls, 1);
        expect(adapter.lastBackfillCommand, isNotNull);
        expect(adapter.lastBackfillCommand!.operatorId, _opId);
        expect(adapter.lastBackfillCommand!.locationId, _locId);
        expect(
          adapter.lastBackfillCommand!.actorUserId,
          kSyncWorkerServicePrincipalId,
        );
        expect(adapter.lastBackfillCommand!.vendorId, _vendorId);
        expect(adapter.lastBackfillCommand!.resumeFromCursor, 'cursor-start');
        expect(
          adapter.lastBackfillCommand!.windowEnd.difference(
            adapter.lastBackfillCommand!.windowStart,
          ),
          const Duration(days: 60),
        );

        expect(jobStore.succeeded, hasLength(1));
        expect(jobStore.succeeded.single.cursorToken, 'cursor-done');
        expect(jobStore.releasedForResume, isEmpty);
        expect(jobStore.failed, isEmpty);

        expect(sink.watermarkAdvances, hasLength(1));
        expect(sink.watermarkAdvances.single.cursorToken, 'cursor-done');
        expect(sink.syncLogs, hasLength(1));
        expect(sink.syncLogs.single.eventKind, 'backfill_success');
        expect(sink.syncLogs.single.recordsCount, 7);
        expect(sink.demoFlips, hasLength(1));
        expect(sink.demoFlips.single.backfillRecordsWritten, 7);
      },
    );

    test('sanity hook is forced to isDeliberateBackfill true', () async {
      final seenFlags = <bool>[];
      adapter.invokeSanityHookDuringBackfill = true;
      jobStore.enqueueClaim(_job());

      await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
        sanityHook:
            ({
              required String vendorEventId,
              required Map<String, Object?> payload,
              required bool isDeliberateBackfill,
            }) async {
              seenFlags.add(isDeliberateBackfill);
              return true;
            },
      );

      expect(seenFlags, <bool>[true]);
    });

    test('partial result persists cursor and leaves job resumable', () async {
      adapter.backfillResult = BackfillResult(
        batchesCommitted: 1,
        recordsWritten: 3,
        cursorToken: 'cursor-page-2',
        lastModifiedSeen: DateTime.utc(2026, 5, 5, 9),
        completed: false,
      );
      jobStore.enqueueClaim(_job(cursorToken: 'cursor-page-1'));

      final result = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(result.outcome, BackfillDispatchOutcome.resumable);
      expect(jobStore.releasedForResume, hasLength(1));
      expect(jobStore.releasedForResume.single.cursorToken, 'cursor-page-2');
      expect(jobStore.succeeded, isEmpty);
      expect(jobStore.failed, isEmpty);
      expect(sink.watermarkAdvances.single.cursorToken, 'cursor-page-2');
      expect(sink.syncLogs.single.eventKind, 'backfill_partial');
      expect(
        sink.demoFlips,
        hasLength(1),
        reason:
            'first committed backfill rows still leave demo mode even '
            'when the job remains resumable',
      );
    });

    test('zero-row completion succeeds without flipping demo', () async {
      adapter.backfillResult = BackfillResult(
        batchesCommitted: 0,
        recordsWritten: 0,
        cursorToken: 'cursor-empty',
        lastModifiedSeen: DateTime.utc(2026, 5, 6, 13),
      );
      jobStore.enqueueClaim(_job());

      final result = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(result.outcome, BackfillDispatchOutcome.succeeded);
      expect(jobStore.succeeded, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'backfill_success');
      expect(sink.syncLogs.single.recordsCount, 0);
      expect(sink.demoFlips, isEmpty);
    });

    test('adapter throw records failure and preserves resume state', () async {
      adapter.throwOnBackfill = StateError('vendor 503');
      jobStore.enqueueClaim(_job(cursorToken: 'cursor-before-error'));

      final result = await dispatcher.dispatchNext(
        operatorId: _opId,
        locationId: _locId,
        workerId: _workerId,
        jobStore: jobStore,
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(result.outcome, BackfillDispatchOutcome.failed);
      expect(jobStore.failed, hasLength(1));
      expect(jobStore.failed.single.errorMessage, contains('vendor 503'));
      expect(jobStore.succeeded, isEmpty);
      expect(jobStore.releasedForResume, isEmpty);
      expect(sink.watermarkAdvances, isEmpty);
      expect(sink.demoFlips, isEmpty);
      expect(sink.syncLogs.single.eventKind, 'backfill_error');
    });

    test(
      'wrong category adapter is marked failed without calling backfill',
      () async {
        final laborAdapter = _RecordingLaborAdapter();
        jobStore.enqueueClaim(_job());

        final result = await dispatcher.dispatchNext(
          operatorId: _opId,
          locationId: _locId,
          workerId: _workerId,
          jobStore: jobStore,
          adapterFactory: (_) => laborAdapter,
          canonicalSink: sink,
        );

        expect(result.outcome, BackfillDispatchOutcome.failed);
        expect(adapter.backfillCalls, 0);
        expect(laborAdapter.backfillCalls, 0);
        expect(jobStore.failed.single.errorMessage, contains('PosAdapter'));
        expect(sink.syncLogs.single.eventKind, 'backfill_error');
      },
    );
  });
}

FirstConnectionBackfillJob _job({String? cursorToken}) {
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
    cursorToken: cursorToken,
    attemptCount: 1,
    workerId: _workerId,
    claimedAt: DateTime.utc(2026, 5, 6, 12, 1),
    createdAt: DateTime.utc(2026, 5, 6, 12),
    updatedAt: DateTime.utc(2026, 5, 6, 12, 1),
  );
}

class _FakeBackfillJobStore implements BackfillJobStore {
  final List<FirstConnectionBackfillJob> _claims =
      <FirstConnectionBackfillJob>[];
  final List<_SuccessRecord> succeeded = <_SuccessRecord>[];
  final List<_FailureRecord> failed = <_FailureRecord>[];
  final List<_ResumeRecord> releasedForResume = <_ResumeRecord>[];

  void enqueueClaim(FirstConnectionBackfillJob job) {
    _claims.add(job);
  }

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
  }) async {
    succeeded.add(
      _SuccessRecord(
        jobId: jobId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        actorUserId: actorUserId,
      ),
    );
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
    failed.add(
      _FailureRecord(
        jobId: jobId,
        errorMessage: errorMessage,
        actorUserId: actorUserId,
      ),
    );
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
    releasedForResume.add(
      _ResumeRecord(
        jobId: jobId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        errorMessage: errorMessage,
        actorUserId: actorUserId,
      ),
    );
    return null;
  }
}

class _RecordingPosAdapter implements PosAdapter {
  int backfillCalls = 0;
  bool invokeSanityHookDuringBackfill = false;
  BackfillCommand? lastBackfillCommand;
  Object? throwOnBackfill;
  BackfillResult backfillResult = BackfillResult(
    batchesCommitted: 1,
    recordsWritten: 1,
    cursorToken: 'cursor',
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
    lastBackfillCommand = command;
    if (throwOnBackfill != null) throw throwOnBackfill!;
    if (invokeSanityHookDuringBackfill) {
      await command.sanityHook(
        vendorEventId: 'vendor-event-1',
        payload: const <String, Object?>{},
        isDeliberateBackfill: false,
      );
    }
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

class _RecordingLaborAdapter implements LaborAdapter {
  int backfillCalls = 0;

  @override
  String get vendorId => 'seven_shifts';

  @override
  String get displayName => 'Recording Labor';

  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: 'seven_shifts',
        displayName: 'Recording Labor',
        category: IntegrationCategory.labor,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.operatorWide,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
      );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    backfillCalls += 1;
    return BackfillResult(
      batchesCommitted: 1,
      recordsWritten: 1,
      cursorToken: 'labor-cursor',
      lastModifiedSeen: DateTime.utc(2026, 5, 6),
    );
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
      _WatermarkAdvance(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
      ),
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
      _SyncLogEntry(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        eventKind: eventKind,
        errorMessage: errorMessage,
        recordsCount: recordsCount,
      ),
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
    demoFlips.add(
      _DemoFlip(
        operatorId: operatorId,
        locationId: locationId,
        category: category,
        connectionStatus: connectionStatus,
        firstBackfillCommitted: firstBackfillCommitted,
        backfillRecordsWritten: backfillRecordsWritten,
        connectionId: connectionId,
      ),
    );
  }
}

class _SuccessRecord {
  const _SuccessRecord({
    required this.jobId,
    required this.cursorToken,
    required this.lastModifiedSeen,
    required this.actorUserId,
  });

  final String jobId;
  final String cursorToken;
  final DateTime lastModifiedSeen;
  final String? actorUserId;
}

class _FailureRecord {
  const _FailureRecord({
    required this.jobId,
    required this.errorMessage,
    required this.actorUserId,
  });

  final String jobId;
  final String errorMessage;
  final String? actorUserId;
}

class _ResumeRecord {
  const _ResumeRecord({
    required this.jobId,
    required this.cursorToken,
    required this.lastModifiedSeen,
    required this.errorMessage,
    required this.actorUserId,
  });

  final String jobId;
  final String cursorToken;
  final DateTime lastModifiedSeen;
  final String? errorMessage;
  final String? actorUserId;
}

class _WatermarkAdvance {
  const _WatermarkAdvance({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String cursorToken;
  final DateTime lastModifiedSeen;
}

class _SyncLogEntry {
  const _SyncLogEntry({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.eventKind,
    this.errorMessage,
    this.recordsCount,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String eventKind;
  final String? errorMessage;
  final int? recordsCount;
}

class _DemoFlip {
  const _DemoFlip({
    required this.operatorId,
    required this.locationId,
    required this.category,
    required this.connectionStatus,
    required this.firstBackfillCommitted,
    required this.backfillRecordsWritten,
    required this.connectionId,
  });

  final String operatorId;
  final String locationId;
  final IntegrationCategory category;
  final ConnectionStatus connectionStatus;
  final bool firstBackfillCommitted;
  final int backfillRecordsWritten;
  final String connectionId;
}
