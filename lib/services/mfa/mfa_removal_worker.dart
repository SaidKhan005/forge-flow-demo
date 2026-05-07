// Phase 9.UX.1a - scheduled MFA removal completion worker.
//
// User and admin actions only initiate the 24-hour removal window. This worker
// is the backend-owned completion pass that Cloud Scheduler / Cloud Run Jobs
// can run every 5-15 minutes. It is idempotent: rows are claimed with
// SKIP LOCKED, completion updates guard on pending state, and failures release
// the claim for a later retry.
//
// L7 hardening (CODE_HEALTH wave):
//   * Retry cap + DLQ — every failure increments the per-row
//     `attempt_count` (M4 schema). When the post-increment count reaches
//     [_maxAttempts] the row is dead-lettered (`markDeadLettered`) and a
//     human-triage event is emitted (structured stderr log + outbox
//     event when an outbox repo is wired). Dead-lettered rows are
//     excluded from the partial indexes powering `claimDuePending`, so
//     they stop being retried automatically.
//   * Cooperative shutdown — the worker accepts an optional
//     [shouldStop] predicate. The Cloud Run Job entrypoint hands in a
//     SIGTERM/SIGINT-driven flag; the per-row loop short-circuits
//     between rows so an in-flight claim still finishes its
//     transaction but the next row is left for the replacement
//     instance.
//   * Atomic completion ordering — the three terminal writes
//     (markCompleted → audit insert → outbox enqueue) run inside a
//     single tenant transaction via
//     `MfaFactorRemovalRequestsRepository.withTenant`. The body issues
//     `markCompletedInTransaction` (parallel-writer race returns 0,
//     short-circuits without bumping `completed`),
//     `AuthEventsAuditRepository.insertSystemEventOn`, and
//     `EventOutboxRepository.enqueueInTransaction` against the same
//     `PostgresExecutor`. If any of the three throws, the surrounding
//     `runInTenantContext` rolls the whole transaction back — the row
//     stays in its pre-attempt state and the failure arm
//     (incrementAttemptCount + markFailed) opens its own transaction
//     to release the claim for the next tick. The ordering pin
//     (audit before outbox) is still enforced inside the body so a
//     partial-commit hazard from a future split would default to the
//     recoverable shape (audit row written, outbox row missing).

import 'dart:convert';
import 'dart:io';

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../auth/firebase_admin_auth_client.dart';

class MfaRemovalWorkerResult {
  const MfaRemovalWorkerResult({
    required this.claimed,
    required this.completed,
    required this.failed,
    this.deadLettered = 0,
  });

  final int claimed;
  final int completed;
  final int failed;

  /// Subset of [failed] that crossed [MfaRemovalWorker._maxAttempts] on
  /// this tick and were stamped `dead_lettered_at`. Surfaced for
  /// observability so deploy verification can grep for non-zero
  /// dead-letter counts.
  final int deadLettered;
}

class MfaRemovalWorker {
  MfaRemovalWorker({
    required MfaFactorRemovalRequestsRepository removalRequestsRepository,
    required MfaFactorsRepository mfaFactorsRepository,
    required UsersRepository usersRepository,
    required AuthEventsAuditRepository auditRepository,
    required FirebaseAdminAuthClient firebaseAdmin,
    EventOutboxRepository? eventOutboxRepository,
    DateTime Function()? now,
    bool Function()? shouldStop,
    this.workerOwner = 'mfa-removal-worker',
  }) : _removalRequestsRepository = removalRequestsRepository,
       _mfaFactorsRepository = mfaFactorsRepository,
       _usersRepository = usersRepository,
       _auditRepository = auditRepository,
       _firebaseAdmin = firebaseAdmin,
       _eventOutboxRepository = eventOutboxRepository,
       _now = now ?? DateTime.now,
       _shouldStop = shouldStop ?? _defaultShouldStop;

  final MfaFactorRemovalRequestsRepository _removalRequestsRepository;
  final MfaFactorsRepository _mfaFactorsRepository;
  final UsersRepository _usersRepository;
  final AuthEventsAuditRepository _auditRepository;
  final FirebaseAdminAuthClient _firebaseAdmin;
  final EventOutboxRepository? _eventOutboxRepository;
  final DateTime Function() _now;
  final bool Function() _shouldStop;
  final String workerOwner;

  /// App-level retry cap (the schema CHECK at 100 is the defensive
  /// backstop; a tighter app cap keeps human-triage actionable). Once
  /// the post-increment `attempt_count` reaches this value the row is
  /// dead-lettered and dropped from the active claim set.
  static const int _maxAttempts = 10;

  static bool _defaultShouldStop() => false;

  Future<MfaRemovalWorkerResult> processDue({int batchSize = 50}) async {
    final now = _now().toUtc();
    final due = await _removalRequestsRepository.claimDuePending(
      now: now,
      workerOwner: workerOwner,
      limit: batchSize,
    );
    var completed = 0;
    var failed = 0;
    var deadLettered = 0;
    for (final request in due) {
      if (_shouldStop()) {
        // Cooperative shutdown: an in-flight claim that has not yet
        // started its tenant transaction is left in the claimed-but-
        // unprocessed state. The per-row claim has a stale-after window
        // (15 min default) on the repository side, so the next worker
        // instance reclaims it cleanly.
        break;
      }
      final outcome = await _processRequest(request, now: now);
      switch (outcome) {
        case _RowOutcome.completed:
          completed += 1;
        case _RowOutcome.raceLost:
          // Another worker beat us to markCompleted. Idempotent skip.
          break;
        case _RowOutcome.failedRetryable:
          failed += 1;
        case _RowOutcome.failedDeadLettered:
          failed += 1;
          deadLettered += 1;
      }
    }
    return MfaRemovalWorkerResult(
      claimed: due.length,
      completed: completed,
      failed: failed,
      deadLettered: deadLettered,
    );
  }

  /// Runs the per-row pipeline:
  ///
  ///   1. Resolve the Firebase UID for the tenant user (admin pool).
  ///   2. Clear MFA enrollments at Firebase.
  ///   3. Revoke the local TOTP factor + recovery code factors.
  ///   4. Atomic-completion transaction:
  ///        a. `markCompletedInTransaction` (returns 0 if a parallel
  ///           writer beat us — short-circuits without committing
  ///           audit / outbox writes).
  ///        b. `insertSystemEventOn` — audit row append.
  ///        c. `enqueueInTransaction` — outbox row append.
  ///      All three writes commit (or roll back) as one PostgreSQL
  ///      transaction.
  ///
  /// Steps 1-3 are external side-effects (Firebase, then per-table
  /// repository writes). They are idempotent on retry: Firebase
  /// `clearMfaEnrollments` is idempotent per UID, and the local
  /// revoke* methods are guarded by the row's pending state.
  ///
  /// Step 4 runs inside `MfaFactorRemovalRequestsRepository.withTenant`
  /// so a single `runInTenantContext` boundary covers all three
  /// writes. The race-loss branch (markCompleted UPDATE returns 0)
  /// returns `_RowOutcome.raceLost` from inside the body so audit +
  /// outbox are not written; the surrounding transaction still
  /// commits cleanly because no error propagates. Any error from
  /// audit or outbox propagates out of the body, the wrapper rolls
  /// the whole transaction back, the row is left in its pre-attempt
  /// state, and the catch arm below routes through [_onFailure] which
  /// increments `attempt_count` and calls `markFailed` to release
  /// the claim for a later tick. The original ordering pin
  /// (audit before outbox) is preserved inside the body for the
  /// recoverable-failure shape — though with single-tx atomicity, a
  /// partial commit is no longer possible.
  Future<_RowOutcome> _processRequest(
    MfaFactorRemovalRequestRecord request, {
    required DateTime now,
  }) async {
    try {
      final firebaseUid = await _usersRepository.firebaseUidForUserSystem(
        userId: request.userId,
        requireOperatorId: request.operatorId,
        adminReason: 'system.mfa_factor_removal_worker_firebase_uid',
      );
      await _firebaseAdmin.clearMfaEnrollments(uid: firebaseUid);
      await _mfaFactorsRepository.revokeTotpFactor(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
        factorId: request.factorId,
      );
      await _mfaFactorsRepository.revokeActiveRecoveryCodeFactorsForUser(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
      );
      final ctx = TenantContext(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
      );
      // Single tenant transaction wraps markCompleted + audit + outbox.
      // The body returns `_RowOutcome.raceLost` for the parallel-writer
      // shortcut (markCompleted UPDATE returned 0); any error
      // propagating out of the body rolls the whole transaction back
      // so a half-completed row is impossible.
      return await _removalRequestsRepository.withTenant<_RowOutcome>(
        ctx,
        (exec) async {
          final changed =
              await _removalRequestsRepository.markCompletedInTransaction(
            exec,
            operatorId: request.operatorId,
            locationId: request.locationId,
            userId: request.userId,
            requestId: request.requestId,
            completedAt: now,
          );
          if (changed == 0) {
            // Race: another worker already marked the row completed.
            // Skip audit + outbox so we don't double-emit lifecycle
            // events. The transaction commits with no writes (the
            // markCompleted UPDATE matched zero rows, audit + outbox
            // never ran), which is fine — the row's terminal state was
            // already established by the winning worker.
            return _RowOutcome.raceLost;
          }
          // Audit-row first, then outbox enqueue. Order matters as a
          // defense-in-depth even with single-tx atomicity: the audit
          // row is the SOC-2 chain anchor (hash-chained per
          // operator/day in `audit_logs`), so any future split that
          // turns this body into two transactions would default to
          // the recoverable shape (audit row written, outbox row
          // missing) rather than the unrecoverable inverse (outbox
          // event with no audit anchor).
          await _auditRepository.insertSystemEventOn(
            exec,
            operatorId: request.operatorId,
            locationId: request.locationId,
            actorKind: 'system',
            targetUserId: request.userId,
            eventType: 'mfa_factor_revocation_completed',
            payload: <String, Object?>{
              'factor_id': request.factorId,
              'request_id': request.requestId,
              'requested_by_user_id': request.requestedByUserId,
              'completed_at': now.toUtc().toIso8601String(),
              'worker_owner': workerOwner,
            },
          );
          await _eventOutboxRepository?.enqueueInTransaction(
            exec,
            operatorId: request.operatorId,
            topic: 'auth.user.mfa_factor_removed',
            payload: <String, Object?>{
              'event_id': request.requestId,
              'event_type': 'auth.user.mfa_factor_removed',
              'occurred_at': now.toUtc().toIso8601String(),
              'operator_id': request.operatorId,
              'location_id': request.locationId,
              'user_id': request.userId,
              'factor_id': request.factorId,
            },
          );
          return _RowOutcome.completed;
        },
      );
    } catch (error) {
      return _onFailure(request, error: error, now: now);
    }
  }

  /// Failure arm. Increments `attempt_count` first so the post-
  /// increment value drives the DLQ decision. The increment + the
  /// `markFailed` write together release the claim (`markFailed`
  /// clears `processing_started_at` / `processing_owner`) so the next
  /// polling tick can reclaim the row when it is still under the cap.
  ///
  /// Once the post-increment count reaches [_maxAttempts] the row is
  /// dead-lettered (drops out of the partial indexes powering
  /// `claimDuePending`) and a human-triage event is emitted.
  Future<_RowOutcome> _onFailure(
    MfaFactorRemovalRequestRecord request, {
    required Object error,
    required DateTime now,
  }) async {
    final errorLabel = _stringifyError(error);
    int newCount;
    try {
      newCount = await _removalRequestsRepository.incrementAttemptCount(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
        requestId: request.requestId,
      );
    } on StateError {
      // Row missing or already terminal (cancelled / dead-lettered /
      // completed by a parallel writer between claim and failure).
      // Treat as a no-op failure: we do not want to mark a terminal
      // row failed.
      return _RowOutcome.failedRetryable;
    }
    await _removalRequestsRepository.markFailed(
      operatorId: request.operatorId,
      locationId: request.locationId,
      userId: request.userId,
      requestId: request.requestId,
      error: errorLabel,
    );
    if (newCount >= _maxAttempts) {
      final dlqAffected = await _removalRequestsRepository.markDeadLettered(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
        requestId: request.requestId,
        reason: errorLabel,
      );
      if (dlqAffected > 0) {
        await _emitDeadLetterAlert(
          request,
          attemptCount: newCount,
          error: errorLabel,
          now: now,
        );
      }
      return _RowOutcome.failedDeadLettered;
    }
    return _RowOutcome.failedRetryable;
  }

  /// Emit the human-triage signal when a row exceeds [_maxAttempts]:
  ///
  ///   * always — a structured `severity=alert` line on stderr (the
  ///     codebase pattern for worker alerts that have no first-class
  ///     metrics surface). Cloud Run logging promotes stderr lines so
  ///     log-based alerting can match on
  ///     `event_type=mfa_factor_removal_dead_lettered`.
  ///   * when an outbox repo is wired — one `event_outbox` row on the
  ///     `auth.user.mfa_factor_removal_dead_lettered` topic so the
  ///     Phase 10a bridge eventually fans the event out to the same
  ///     consumers as the success topic.
  ///
  /// The two emissions are independent: a Postgres failure inside the
  /// outbox enqueue does NOT swallow the stderr line.
  Future<void> _emitDeadLetterAlert(
    MfaFactorRemovalRequestRecord request, {
    required int attemptCount,
    required String error,
    required DateTime now,
  }) async {
    final fields = <String, Object?>{
      'event_type': 'mfa_factor_removal_dead_lettered',
      'severity': 'alert',
      'request_id': request.requestId,
      'operator_id': request.operatorId,
      'location_id': request.locationId,
      'user_id': request.userId,
      'factor_id': request.factorId,
      'attempt_count': attemptCount,
      'max_attempts': _maxAttempts,
      'error': error,
      'occurred_at': now.toUtc().toIso8601String(),
      'worker_owner': workerOwner,
    };
    stderr.writeln(jsonEncode(fields));
    final outbox = _eventOutboxRepository;
    if (outbox != null) {
      try {
        await outbox.enqueue(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
          topic: 'auth.user.mfa_factor_removal_dead_lettered',
          payload: <String, Object?>{
            'event_id': request.requestId,
            'event_type': 'auth.user.mfa_factor_removal_dead_lettered',
            'occurred_at': now.toUtc().toIso8601String(),
            'operator_id': request.operatorId,
            'location_id': request.locationId,
            'user_id': request.userId,
            'factor_id': request.factorId,
            'attempt_count': attemptCount,
            'max_attempts': _maxAttempts,
            'error': error,
          },
        );
      } catch (outboxError) {
        // Outbox failure must not mask the original failure path. The
        // stderr alert above is the authoritative human-triage signal;
        // the outbox enqueue is best-effort. Surface the secondary
        // failure on stderr so it shows up in log-based alerting too.
        stderr.writeln(jsonEncode(<String, Object?>{
          'event_type': 'mfa_factor_removal_dead_letter_outbox_failed',
          'severity': 'alert',
          'request_id': request.requestId,
          'error': outboxError.runtimeType.toString(),
        }));
      }
    }
  }

  /// Map an arbitrary failure object to a stable, low-cardinality
  /// label suitable for `last_error` / DLQ `reason`. Mirrors the
  /// previous worker's `error.runtimeType.toString()` shape so
  /// downstream consumers (the audit log, the existing dashboards) do
  /// not see a label-format change.
  static String _stringifyError(Object error) {
    return error.runtimeType.toString();
  }
}

/// Per-row outcome surfaced from [MfaRemovalWorker._processRequest] so
/// the batch loop's counter increments are unambiguous in code review.
enum _RowOutcome {
  completed,
  raceLost,
  failedRetryable,
  failedDeadLettered,
}
