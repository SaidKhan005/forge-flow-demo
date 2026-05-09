// Worker-layer audit emission for first-connect backfill terminal /
// transition events.
//
// PR #457 (`test(phase-6): extend connector_backfill_job_repository
// test ...`) surfaced two CONTRACT GAP markers when adding real-DB
// repository tests:
//
//   1. "Audit row for the demo-flip event is emitted exactly once" —
//      the repo doesn't write `audit_logs`; the emission must live
//      where the worker dispatch sees the demo→live transition.
//   2. "Audit row for the re-claim event captures the prior worker_id"
//      — the repo's claim CTE overwrites `worker_id` at the row level,
//      so even at the DB layer the prior pod's id is lost the moment
//      pod B's claim lands.
//
// This file wires the missing emission AT THE WORKER LAYER so neither
// gap survives. Five [BackfillJobStore] terminal / transition events
// emit one `audit_logs` row each:
//
//   * `backfill_job.claimed` — fresh claim landed
//   * `backfill_job.reclaimed` — stale-window re-claim landed
//   * `backfill_job.succeeded` — terminal success
//   * `backfill_job.failed` — terminal failure
//   * `backfill_job.demo_flipped` — see
//     `audit_emitting_canonical_sink.dart` (sibling file); that file
//     wires the demo-flip emission as a [CanonicalSink] decorator
//     since the dispatch calls `evaluateDemoFlip` through the sink,
//     not the job store.
//
// Each emission uses the existing [AuditLogsRepository.writeRow]
// surface (no new audit-log columns; everything structured rides in
// `payload_jsonb`). Audit rows go through their OWN tenant-scoped
// transaction immediately after the delegate's state-change
// transaction commits — the audit_logs writer's
// `_assertTenantContextMatches` GUC probe (PR #424 Lane A) fails
// closed if the tenant context drifts, so a forged operator id would
// abort before any insert SQL runs. Audit emission failures are
// logged but never rolled back into the state-change outcome — the
// row's terminal state is the single source of truth, the audit
// chain is the observability anchor.
//
// Service-principal attribution: the worker is a non-human actor,
// so audit rows carry `actor_kind = 'service'` and
// `actor_principal_id = 'sp:backfill_worker'` (matching the catalog
// in CLAUDE.md "Service principals"). `actor_user_id` is null on
// every row (the audit_logs CHECK constraint requires exactly one
// of `actor_user_id` / `actor_principal_id` for service rows).

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/observability/log.dart';

import 'backfill_dispatch.dart';

/// Service-principal id every backfill audit row carries in its
/// `actor_principal_id` column. Mirrors the per-worker SP ids elsewhere
/// (`sp:first_connect_backfill_worker`, `sp:oauth_refresh_worker`,
/// `sp:pii-erasure-worker`). The string MUST stay stable — the audit
/// chain's `target_kind = 'connector_backfill_job'` rows are filtered
/// by this id in support / RCA queries.
const String kBackfillWorkerServicePrincipalId = 'sp:backfill_worker';

/// `audit_logs.action` values the dispatch-layer emitter uses for the
/// five backfill events. Keep stable — these are the strings RCA
/// queries / dashboards filter on.
abstract class BackfillAuditAction {
  static const String claimed = 'backfill_job.claimed';
  static const String reclaimed = 'backfill_job.reclaimed';
  static const String succeeded = 'backfill_job.succeeded';
  static const String failed = 'backfill_job.failed';
  static const String demoFlipped = 'backfill_job.demo_flipped';
}

/// Cap the `error_message_truncated` field at this length before it
/// enters `payload_jsonb`. Defense-in-depth against the same class of
/// issue PR #456 fixed (full stack traces leaking into
/// observability sinks). The cap is well under the
/// `connector_backfill_jobs.last_error` 4096-char check so the
/// payload mirror stays consistent with the row.
const int kBackfillAuditErrorMessageCap = 1024;

/// `BackfillJobStore` decorator that emits one `audit_logs` row per
/// terminal / transition state change on the wrapped delegate.
/// Failures of the audit emission are logged at warning severity but
/// never rolled back into the state change outcome — the row's
/// terminal state is the single source of truth.
class AuditEmittingBackfillJobStore implements BackfillJobStore {
  AuditEmittingBackfillJobStore({
    required this.delegate,
    required this.tenantWrapper,
    required this.repository,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    DateTime Function()? clock,
    String servicePrincipalId = kBackfillWorkerServicePrincipalId,
  }) : _audit = auditLogsRepository,
       _clock = clock ?? _defaultUtcClock,
       _servicePrincipalId = servicePrincipalId;

  final BackfillJobStore delegate;
  final TenantTransactionWrapper tenantWrapper;

  /// Repository the audit emitter uses for the prior-worker_id surface
  /// (`claimNextWithPriorClaim`). The decorator falls back to the
  /// delegate's `claimNext` for the actual claim semantics; the
  /// repository call is read-after-claim only when the delegate IS
  /// the [ConnectorBackfillJobStore] thin wrapper around this same
  /// repository (the production wiring). For non-production
  /// `BackfillJobStore` impls (tests, harnesses), the audit row's
  /// `prior_worker_id` is sourced from the row state the delegate
  /// already returned plus the worker_id the delegate had captured.
  final ConnectorBackfillJobRepository repository;

  final AuditLogsRepository _audit;
  final DateTime Function() _clock;
  final String _servicePrincipalId;

  static DateTime _defaultUtcClock() => DateTime.now().toUtc();

  /// Truncates [message] to [kBackfillAuditErrorMessageCap] and never
  /// returns null. Single private helper so `failed` and the
  /// dead-letter wrapper share the same cap behavior.
  static String truncateErrorMessageForAudit(String message) {
    if (message.length <= kBackfillAuditErrorMessageCap) return message;
    return message.substring(0, kBackfillAuditErrorMessageCap);
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
    // Use the prior-claim-aware surface so the audit row can
    // distinguish a fresh claim (`backfill_job.claimed`) from a stale-
    // window re-claim (`backfill_job.reclaimed`) AND capture the prior
    // pod's identifier on the re-claim path. The repository call
    // honors the same SKIP LOCKED + stale-recovery contract as
    // `claimNext` — see [ConnectorBackfillJobRepository.claimNextWithPriorClaim].
    final details = await repository.claimNextWithPriorClaim(
      operatorId: operatorId,
      locationId: locationId,
      workerId: workerId,
      actorUserId: actorUserId,
      claimStaleAfter: claimStaleAfter,
    );
    if (details == null) return null;
    final job = details.job;
    final isReclaim = details.priorWorkerId != null &&
        details.priorWorkerId != workerId;
    if (isReclaim) {
      await _emit(
        operatorId: operatorId,
        locationId: locationId,
        action: BackfillAuditAction.reclaimed,
        targetId: job.jobId,
        payload: <String, Object?>{
          'job_id': job.jobId,
          'vendor_id': job.vendorId,
          'prior_worker_id': details.priorWorkerId,
          'new_worker_id': workerId,
          'prior_claim_count': details.priorAttemptCount,
          'new_claim_count': job.attemptCount,
        },
      );
    } else {
      await _emit(
        operatorId: operatorId,
        locationId: locationId,
        action: BackfillAuditAction.claimed,
        targetId: job.jobId,
        payload: <String, Object?>{
          'job_id': job.jobId,
          'vendor_id': job.vendorId,
          'worker_id': workerId,
          'claim_count': job.attemptCount,
        },
      );
    }
    return job;
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
    final claimedAt = _clock();
    final updated = await delegate.markSucceeded(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      actorUserId: actorUserId,
    );
    if (updated == null) return null;
    final completedAt = updated.completedAt ?? _clock();
    final elapsedMs = completedAt.difference(claimedAt).inMilliseconds.abs();
    await _emit(
      operatorId: operatorId,
      locationId: locationId,
      action: BackfillAuditAction.succeeded,
      targetId: updated.jobId,
      payload: <String, Object?>{
        'job_id': updated.jobId,
        'vendor_id': updated.vendorId,
        'worker_id': updated.workerId,
        // The dispatcher does not feed the records-processed count
        // into `markSucceeded`; the row carries the cursor + last-
        // modified watermark only. We surface the watermark instant
        // for RCA traceability and fall back to `null` for
        // records_processed when the delegate did not stamp it.
        'records_processed': null,
        'elapsed_ms': elapsedMs,
      },
    );
    return updated;
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async {
    final updated = await delegate.markFailed(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
    if (updated == null) return null;
    await _emit(
      operatorId: operatorId,
      locationId: locationId,
      action: BackfillAuditAction.failed,
      targetId: updated.jobId,
      payload: <String, Object?>{
        'job_id': updated.jobId,
        'vendor_id': updated.vendorId,
        'worker_id': updated.workerId,
        'error_class': _classifyError(errorMessage),
        'error_message_truncated': truncateErrorMessageForAudit(errorMessage),
      },
    );
    return updated;
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
    // releaseForResume is non-terminal — the job goes back to
    // `pending`, available for the next claim. No audit emission;
    // the next claim will emit a `backfill_job.reclaimed` row.
    return delegate.releaseForResume(
      operatorId: operatorId,
      locationId: locationId,
      jobId: jobId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      errorMessage: errorMessage,
      actorUserId: actorUserId,
    );
  }

  /// Cheap class label so RCA queries can `group by error_class`
  /// without parsing the truncated message. The classification is
  /// best-effort heuristic over the message prefix.
  String _classifyError(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('vendor_not_registered')) return 'vendor_not_registered';
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return 'timeout';
    }
    if (lower.contains('rate limit') || lower.contains('429')) {
      return 'rate_limited';
    }
    if (lower.contains('unauthorized') || lower.contains('401')) {
      return 'unauthorized';
    }
    if (lower.contains('forbidden') || lower.contains('403')) {
      return 'forbidden';
    }
    if (lower.contains('not found') || lower.contains('404')) {
      return 'not_found';
    }
    if (lower.contains('500') || lower.contains('server')) {
      return 'server_error';
    }
    return 'other';
  }

  Future<void> _emit({
    required String operatorId,
    required String locationId,
    required String action,
    required String targetId,
    required Map<String, Object?> payload,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      // Service principal — `userId` MUST be null so the audit_logs
      // CHECK constraint passes (`actor_kind = 'service'` requires
      // `actor_user_id IS NULL` and `actor_principal_id IS NOT NULL`).
      userId: null,
    );
    try {
      await tenantWrapper.runInTenantContext<void>(ctx, (exec) async {
        await _audit.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: _clock(),
          actorKind: 'service',
          actorPrincipalId: _servicePrincipalId,
          targetKind: 'connector_backfill_job',
          targetId: targetId,
          action: action,
          payload: payload,
        );
      });
    } catch (error, stackTrace) {
      // Best-effort — the row's terminal state already committed.
      // Logging at warning so SREs see audit-emission gaps without
      // letting an audit-side failure (e.g. transient Postgres) roll
      // back the backfill outcome.
      log(
        LogSeverity.warning,
        'backfill_audit_emission.failed',
        fields: <String, Object?>{
          'action': action,
          'target_id': targetId,
          'error': error.toString(),
          'stack_first_frame': firstStackFrame(stackTrace),
        },
      );
    }
  }
}
