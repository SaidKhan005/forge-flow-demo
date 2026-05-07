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
//     (markCompleted → audit insert → outbox enqueue) are reordered so
//     a parallel-writer race (markCompleted UPDATE returns 0) skips
//     the audit + outbox without bumping `completed`, and any failure
//     in the audit + outbox path runs through the same failure arm
//     (incrementAttemptCount + markFailed) as a Firebase / repository
//     failure earlier in the pipeline. True single-transaction
//     atomicity (markCompleted + audit + outbox committing as one
//     PostgreSQL transaction) is a follow-up tracked in
//     `docs/POST_HARDENING_FOLLOWUPS.md` — wiring it requires an
//     on-executor variant of `EventOutboxRepository.enqueue`, which
//     the L7 prompt explicitly excludes from this lane's surface.

import 'dart:convert';
import 'dart:io';

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
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
  ///   4. `markCompleted` (returns 0 if a parallel writer beat us).
  ///   5. Audit row append + outbox enqueue.
  ///
  /// Steps 1-3 are external side-effects (Firebase, then per-table
  /// repository writes). They are idempotent on retry: Firebase
  /// `clearMfaEnrollments` is idempotent per UID, and the local
  /// revoke* methods are guarded by the row's pending state.
  ///
  /// Step 4's UPDATE-with-WHERE-`completed_at is null` returns 0 when
  /// a parallel worker has already finalised the row, in which case
  /// step 5 is intentionally skipped (`_RowOutcome.raceLost`).
  ///
  /// Step 5's failure path is the L7 hardening hook: any error after
  /// `markCompleted` runs through [_onFailure] which increments
  /// `attempt_count`, calls `markFailed` (releasing the claim for a
  /// later tick), and dead-letters when the cap is reached. The
  /// `markCompleted` WHERE-clause guard means a re-attempt sees
  /// `completed_at IS NOT NULL` and returns 0, so the audit + outbox
  /// writes do not run twice on retry.
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
      final changed = await _removalRequestsRepository.markCompleted(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
        requestId: request.requestId,
        completedAt: now,
      );
      if (changed == 0) {
        // Race: another worker already marked the row completed.
        // Skip audit + outbox so we don't double-emit lifecycle
        // events.
        return _RowOutcome.raceLost;
      }
      // Audit-row first, then outbox enqueue. Order matters: the
      // audit row is the SOC-2 chain anchor (hash-chained per
      // operator/day in `audit_logs`), so a partial commit that
      // chains audit but skips outbox is recoverable from the
      // audit log + a backfill, while the inverse (outbox event
      // for a row that has no audit anchor) leaves a published
      // event with no internal record. Re-attempts after a step-5
      // failure will see markCompleted return 0 and short-circuit
      // via [_RowOutcome.raceLost].
      await _auditRepository.insertSystemEvent(
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
        adminReason: 'system.mfa_factor_removal_worker_complete',
      );
      await _eventOutboxRepository?.enqueue(
        operatorId: request.operatorId,
        locationId: request.locationId,
        userId: request.userId,
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
