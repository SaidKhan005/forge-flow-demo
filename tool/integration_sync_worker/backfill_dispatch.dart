// Phase 8 first-connect backfill worker dispatch.
//
// Claims durable first-backfill jobs, resolves the category/vendor adapter,
// calls `adapter.backfill`, and persists completion/resume/failure through the
// Lane 0 job repository plus the existing CanonicalSink observability seams.

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../advisor_proxy/labor_adapter_registry.dart';
import '../advisor_proxy/pos_adapter_registry.dart';
import '../advisor_proxy/reservation_adapter_registry.dart';
import 'dispatch.dart' show kSyncWorkerServicePrincipalId;

typedef BackfillAdapterFactory =
    Object Function(FirstConnectionBackfillJob job);

abstract class BackfillJobStore {
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  });

  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  });

  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  });

  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  });
}

class ConnectorBackfillJobStore implements BackfillJobStore {
  ConnectorBackfillJobStore(this.repository);

  final ConnectorBackfillJobRepository repository;

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) {
    return repository.claimNext(
      operatorId: operatorId,
      locationId: locationId,
      workerId: workerId,
      actorUserId: actorUserId,
      claimStaleAfter: claimStaleAfter,
    );
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
    return repository.markSucceeded(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      actorUserId: actorUserId,
    );
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) {
    return repository.markFailed(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
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
    return repository.releaseForResume(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
  }
}

enum BackfillDispatchOutcome { noJob, succeeded, resumable, failed }

class BackfillDispatchResult {
  const BackfillDispatchResult({
    required this.outcome,
    this.job,
    this.backfillResult,
    this.errorMessage,
  });

  final BackfillDispatchOutcome outcome;
  final FirstConnectionBackfillJob? job;
  final BackfillResult? backfillResult;
  final String? errorMessage;
}

class BackfillBatchDispatchResult {
  const BackfillBatchDispatchResult({
    required this.attempted,
    required this.succeeded,
    required this.resumable,
    required this.failed,
  });

  final int attempted;
  final int succeeded;
  final int resumable;
  final int failed;
}

/// Optional hook fired when a backfill job reaches a terminal
/// outcome. Phase 8 W2.B wires this to the notification fanout so
/// `notif.backfill.complete` / `notif.backfill.failed` events fire
/// at the moment the job repository transitions the row.
///
/// Hooks are best-effort -- the dispatcher swallows exceptions from
/// the hook so a notification-side failure never strands a
/// backfill outcome.
typedef BackfillTerminalHook = Future<void> Function({
  required FirstConnectionBackfillJob job,
  required BackfillDispatchOutcome outcome,
  String? errorMessage,
});

class IntegrationSyncWorkerBackfillDispatch {
  const IntegrationSyncWorkerBackfillDispatch({
    this.onTerminalOutcome,
  });

  /// Optional hook fired AFTER `markSucceeded` / `markFailed` lands
  /// the row's terminal state. Production binds this to the
  /// notification fanout's `emitBackfillComplete` /
  /// `emitBackfillFailed` helpers in
  /// `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`.
  /// Tests pass a recording closure to assert the trigger fired.
  ///
  /// The hook is NOT called for `BackfillDispatchOutcome.resumable`
  /// -- only succeeded and failed are terminal for notification
  /// purposes; resumable just releases the row for the next claim.
  final BackfillTerminalHook? onTerminalOutcome;

  Future<BackfillDispatchResult> dispatchNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    required BackfillJobStore jobStore,
    required BackfillAdapterFactory adapterFactory,
    required CanonicalSink canonicalSink,
    VendorSanityHook? sanityHook,
    String? actorUserId,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) async {
    final effectiveActorUserId = actorUserId ?? kSyncWorkerServicePrincipalId;
    final job = await jobStore.claimNext(
      operatorId: operatorId,
      locationId: locationId,
      workerId: workerId,
      actorUserId: effectiveActorUserId,
      claimStaleAfter: claimStaleAfter,
    );
    if (job == null) {
      return const BackfillDispatchResult(
        outcome: BackfillDispatchOutcome.noJob,
      );
    }

    if (!_isVendorRegistered(job.vendorId, job.category)) {
      final message =
          'vendor "${job.vendorId}" is not registered in the '
          '${job.category.name} adapter registry; backfill job '
          '${job.jobId} cannot be dispatched';
      await _recordFailure(
        jobStore: jobStore,
        canonicalSink: canonicalSink,
        job: job,
        errorMessage: message,
        actorUserId: effectiveActorUserId,
        eventKind: 'vendor_not_registered',
      );
      await _fireTerminalHook(
        job: job,
        outcome: BackfillDispatchOutcome.failed,
        errorMessage: message,
      );
      return BackfillDispatchResult(
        outcome: BackfillDispatchOutcome.failed,
        job: job,
        errorMessage: message,
      );
    }

    try {
      final command = _buildCommand(
        job,
        actorUserId: effectiveActorUserId,
        sanityHook: sanityHook,
      );
      final result = await _startBackfill(job, adapterFactory, command);

      await canonicalSink.advanceWatermark(
        operatorId: job.operatorId,
        locationId: job.locationId,
        connectionId: job.connectionId,
        cursorToken: result.cursorToken,
        lastModifiedSeen: result.lastModifiedSeen,
      );

      if (result.recordsWritten > 0) {
        await canonicalSink.evaluateDemoFlip(
          operatorId: job.operatorId,
          locationId: job.locationId,
          category: job.category,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: result.recordsWritten,
          connectionId: job.connectionId,
        );
      }

      if (result.completed) {
        await jobStore.markSucceeded(
          operatorId: job.operatorId,
          locationId: job.locationId,
          jobId: job.jobId,
          cursorToken: result.cursorToken,
          lastModifiedSeen: result.lastModifiedSeen,
          actorUserId: effectiveActorUserId,
        );
        await canonicalSink.appendSyncLog(
          operatorId: job.operatorId,
          locationId: job.locationId,
          connectionId: job.connectionId,
          eventKind: 'backfill_success',
          recordsCount: result.recordsWritten,
        );
        await _fireTerminalHook(
          job: job,
          outcome: BackfillDispatchOutcome.succeeded,
        );
        return BackfillDispatchResult(
          outcome: BackfillDispatchOutcome.succeeded,
          job: job,
          backfillResult: result,
        );
      }

      await jobStore.releaseForResume(
        operatorId: job.operatorId,
        locationId: job.locationId,
        jobId: job.jobId,
        cursorToken: result.cursorToken,
        lastModifiedSeen: result.lastModifiedSeen,
        actorUserId: effectiveActorUserId,
      );
      await canonicalSink.appendSyncLog(
        operatorId: job.operatorId,
        locationId: job.locationId,
        connectionId: job.connectionId,
        eventKind: 'backfill_partial',
        recordsCount: result.recordsWritten,
      );
      return BackfillDispatchResult(
        outcome: BackfillDispatchOutcome.resumable,
        job: job,
        backfillResult: result,
      );
    } catch (error) {
      final message = error.toString();
      await _recordFailure(
        jobStore: jobStore,
        canonicalSink: canonicalSink,
        job: job,
        errorMessage: message,
        actorUserId: effectiveActorUserId,
        eventKind: 'backfill_error',
      );
      await _fireTerminalHook(
        job: job,
        outcome: BackfillDispatchOutcome.failed,
        errorMessage: message,
      );
      return BackfillDispatchResult(
        outcome: BackfillDispatchOutcome.failed,
        job: job,
        errorMessage: message,
      );
    }
  }

  /// Best-effort terminal hook. Catches any exception so a
  /// notification-side failure (Postgres outage, fanout bug) never
  /// rolls back the backfill outcome.
  Future<void> _fireTerminalHook({
    required FirstConnectionBackfillJob job,
    required BackfillDispatchOutcome outcome,
    String? errorMessage,
  }) async {
    final hook = onTerminalOutcome;
    if (hook == null) return;
    try {
      await hook(
        job: job,
        outcome: outcome,
        errorMessage: errorMessage,
      );
    } catch (_) {
      // Swallow -- the row is already in its terminal state and the
      // CanonicalSink sync log captured the primary outcome.
    }
  }

  Future<BackfillBatchDispatchResult> dispatchAvailable({
    required String operatorId,
    required String locationId,
    required String workerId,
    required BackfillJobStore jobStore,
    required BackfillAdapterFactory adapterFactory,
    required CanonicalSink canonicalSink,
    VendorSanityHook? sanityHook,
    String? actorUserId,
    int maxJobs = 10,
    Duration claimStaleAfter =
        ConnectorBackfillJobRepository.defaultClaimStaleAfter,
  }) async {
    if (maxJobs <= 0) {
      throw ArgumentError.value(maxJobs, 'maxJobs', 'must be positive');
    }

    var attempted = 0;
    var succeeded = 0;
    var resumable = 0;
    var failed = 0;

    while (attempted < maxJobs) {
      final result = await dispatchNext(
        operatorId: operatorId,
        locationId: locationId,
        workerId: workerId,
        jobStore: jobStore,
        adapterFactory: adapterFactory,
        canonicalSink: canonicalSink,
        sanityHook: sanityHook,
        actorUserId: actorUserId,
        claimStaleAfter: claimStaleAfter,
      );
      if (result.outcome == BackfillDispatchOutcome.noJob) break;
      attempted += 1;
      switch (result.outcome) {
        case BackfillDispatchOutcome.noJob:
          break;
        case BackfillDispatchOutcome.succeeded:
          succeeded += 1;
        case BackfillDispatchOutcome.resumable:
          resumable += 1;
        case BackfillDispatchOutcome.failed:
          failed += 1;
      }
    }

    return BackfillBatchDispatchResult(
      attempted: attempted,
      succeeded: succeeded,
      resumable: resumable,
      failed: failed,
    );
  }

  Future<void> _recordFailure({
    required BackfillJobStore jobStore,
    required CanonicalSink canonicalSink,
    required FirstConnectionBackfillJob job,
    required String errorMessage,
    required String actorUserId,
    required String eventKind,
  }) async {
    await jobStore.markFailed(
      operatorId: job.operatorId,
      locationId: job.locationId,
      jobId: job.jobId,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
    await canonicalSink.appendSyncLog(
      operatorId: job.operatorId,
      locationId: job.locationId,
      connectionId: job.connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
    );
  }

  BackfillCommand _buildCommand(
    FirstConnectionBackfillJob job, {
    required String actorUserId,
    required VendorSanityHook? sanityHook,
  }) {
    final window = FirstConnectionBackfillWindow(
      windowStart: job.windowStart,
      windowEnd: job.windowEnd,
    );
    final hook = sanityHook ?? _allowSanityEvent;
    return BackfillCommand(
      operatorId: job.operatorId,
      locationId: job.locationId,
      actorUserId: actorUserId,
      vendorId: job.vendorId,
      windowStart: window.windowStart,
      windowEnd: window.windowEnd,
      resumeFromCursor: job.cursorToken,
      sanityHook:
          ({
            required String vendorEventId,
            required Map<String, Object?> payload,
            required bool isDeliberateBackfill,
          }) {
            return hook(
              vendorEventId: vendorEventId,
              payload: payload,
              isDeliberateBackfill: true,
            );
          },
    );
  }

  Future<BackfillResult> _startBackfill(
    FirstConnectionBackfillJob job,
    BackfillAdapterFactory adapterFactory,
    BackfillCommand command,
  ) {
    final adapter = adapterFactory(job);
    switch (job.category) {
      case IntegrationCategory.pos:
        if (adapter is! PosAdapter) {
          throw StateError(
            'adapterFactory for pos vendor "${job.vendorId}" returned '
            '${adapter.runtimeType}; expected PosAdapter',
          );
        }
        return adapter.backfill(command);
      case IntegrationCategory.labor:
        if (adapter is! LaborAdapter) {
          throw StateError(
            'adapterFactory for labor vendor "${job.vendorId}" returned '
            '${adapter.runtimeType}; expected LaborAdapter',
          );
        }
        return adapter.backfill(command);
      case IntegrationCategory.reservation:
        if (adapter is! ReservationAdapter) {
          throw StateError(
            'adapterFactory for reservation vendor "${job.vendorId}" returned '
            '${adapter.runtimeType}; expected ReservationAdapter',
          );
        }
        return adapter.backfill(command);
    }
  }

  bool _isVendorRegistered(String vendorId, IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return registeredPosVendorIds.contains(vendorId);
      case IntegrationCategory.labor:
        return registeredLaborVendorIds.contains(vendorId);
      case IntegrationCategory.reservation:
        return registeredReservationVendorIds.contains(vendorId);
    }
  }

  Future<bool> _allowSanityEvent({
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    return true;
  }
}
