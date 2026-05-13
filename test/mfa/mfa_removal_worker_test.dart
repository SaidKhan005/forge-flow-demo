// L5/L7 — MfaRemovalWorker unit coverage.
//
// `mfa_operations_gateway_test.dart` exercises one happy-path tick.
// This file pins the boundary contract:
//
//   * empty due batch → MfaRemovalWorkerResult(0, 0, 0).
//   * multiple due requests are processed in a single tick and counted.
//   * Firebase Admin failure inside `clearMfaEnrollments` falls into the
//     catch arm: incrementAttemptCount + markFailed run, audit + outbox
//     are NOT written, and other queued requests in the same tick still
//     complete.
//   * `markCompleted` returning zero (raced by another worker) skips
//     the audit + outbox without bumping `completed` — the second
//     worker stays idempotent rather than double-counting.
//   * Configurable `workerOwner` flows into the audit payload and the
//     `claimDuePending` call so observability sees who claimed the row.
//   * `eventOutboxRepository` is optional — the worker still completes
//     when no outbox is wired (degraded-but-launchable mode).
//
// L7 retry-cap + DLQ pinned coverage:
//
//   * 9 sequential failures bump `attempt_count` to 9 without
//     dead-lettering. The 10th failure dead-letters the row, emits
//     exactly one outbox event for human triage, and counts the row
//     as `failed` + `deadLettered` in the result.
//   * Atomic-completion rollback — when audit insert raises inside the
//     completion transaction, the wrapper rolls back so the
//     `markCompletedInTransaction` UPDATE is discarded. The row stays
//     in pending state with `attempt_count` bumped by the failure arm
//     (which opens its own transaction); the next tick reclaims it
//     cleanly and (with audit healed) completes the row.
//   * `shouldStop` predicate breaks the per-row loop between rows so
//     SIGTERM-driven cooperative shutdown leaves the next row for the
//     replacement instance.
//
// The worker is composed of small repository fakes that mirror the
// shape used by `mfa_operations_gateway_test.dart`. The retry-cap +
// DLQ surface is exercised through new fake methods backed by M4's
// `incrementAttemptCount` / `markDeadLettered`.
//
// Atomic-completion fakes:
//
//   * `_RemovalRequestsFake.withTenant` is overridden to short-circuit
//     `_NoopPool` and run the body with a `_FakeExecutor`. The fake
//     simulates transaction commit/rollback by buffering the
//     `markCompletedInTransaction` mutation in `_pendingCompletions`
//     and either committing it to `completedRequestIds` (body returns
//     normally) or discarding it (body throws). This is what lets the
//     "audit-failure rolls markCompleted back" assertion hold without
//     a live Postgres.
//   * `_AuditFake.insertSystemEventOn` is the on-executor variant the
//     atomic completion path calls; it shares the `events` recorder
//     with the legacy `insertSystemEvent`.
//   * `_EventOutboxFake.enqueueInTransaction` is the on-executor
//     variant; it shares the `enqueued` recorder with the legacy
//     `enqueue` (so DLQ-channel events still surface).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_factor_changed_notice_dispatcher.dart';
import 'package:forge_and_flow/services/mfa/mfa_removal_worker.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';
const String _factorIdA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _factorIdB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _requestIdA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _requestIdB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

MfaFactorRemovalRequestRecord _due({
  required String requestId,
  required String factorId,
  String stepUpProofId = 'step-up',
  DateTime? executeAfter,
  DateTime? completedAt,
  DateTime? deadLetteredAt,
}) {
  return MfaFactorRemovalRequestRecord(
    requestId: requestId,
    operatorId: _operatorId,
    locationId: _locationId,
    userId: _userId,
    factorId: factorId,
    requestedByUserId: _userId,
    stepUpProofId: stepUpProofId,
    requestedAt: DateTime.utc(2026, 4, 30, 12),
    executeAfter: executeAfter ?? DateTime.utc(2026, 5, 1, 12),
    completedAt: completedAt,
    deadLetteredAt: deadLetteredAt,
  );
}

void main() {
  group('MfaRemovalWorker.processDue', () {
    test('empty due batch → result(0, 0, 0)', () async {
      final removalRepo = _RemovalRequestsFake();
      final auditRepo = _AuditFake();
      final outbox = _EventOutboxFake();
      final worker = MfaRemovalWorker(
        removalRequestsRepository: removalRepo,
        mfaFactorsRepository: _MfaFactorsFake(),
        usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
        auditRepository: auditRepo,
        firebaseAdmin: _FirebaseAdminFake(),
        eventOutboxRepository: outbox,
        now: () => DateTime.utc(2026, 5, 1, 12),
      );

      final result = await worker.processDue();

      expect(result.claimed, equals(0));
      expect(result.completed, equals(0));
      expect(result.failed, equals(0));
      expect(result.deadLettered, equals(0));
      expect(auditRepo.events, isEmpty);
      expect(outbox.enqueued, isEmpty);
    });

    test('multiple due requests are processed in a single tick', () async {
      final removalRepo = _RemovalRequestsFake(
        records: <MfaFactorRemovalRequestRecord>[
          _due(requestId: _requestIdA, factorId: _factorIdA),
          _due(requestId: _requestIdB, factorId: _factorIdB),
        ],
      );
      final auditRepo = _AuditFake();
      final outbox = _EventOutboxFake();
      final mfaRepo = _MfaFactorsFake();
      final firebase = _FirebaseAdminFake();
      final worker = MfaRemovalWorker(
        removalRequestsRepository: removalRepo,
        mfaFactorsRepository: mfaRepo,
        usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
        auditRepository: auditRepo,
        firebaseAdmin: firebase,
        eventOutboxRepository: outbox,
        now: () => DateTime.utc(2026, 5, 1, 13),
      );

      final result = await worker.processDue();

      expect(result.claimed, equals(2));
      expect(result.completed, equals(2));
      expect(result.failed, equals(0));
      expect(result.deadLettered, equals(0));
      expect(firebase.clearedMfaUids, equals(<String>['fb-uid', 'fb-uid']));
      expect(
        mfaRepo.revokedTotpFactors,
        equals(<String>[_factorIdA, _factorIdB]),
      );
      // 2 calls to revokeActiveRecoveryCodeFactorsForUser (one per due row).
      expect(mfaRepo.revokedRecoveryCodeCalls, equals(2));
      expect(auditRepo.events, hasLength(2));
      expect(
        auditRepo.events.first.eventType,
        equals('mfa_factor_revocation_completed'),
      );
      // ops-debt.actor-kind-audit: the 24-hour MFA removal worker runs
      // outside any HTTP / SP context and must tag the completion row
      // 'system' so audit_logs.actor_kind reflects the absence of a
      // human / SP actor.
      for (final event in auditRepo.events) {
        expect(
          event.actorKind,
          equals('system'),
          reason:
              'MfaRemovalWorker is a legacy worker boundary with no '
              "actor — every completion row must tag actor_kind='system'",
        );
      }
      expect(outbox.enqueued, hasLength(2));
      expect(
        outbox.enqueued.first.topic,
        equals('auth.user.mfa_factor_removed'),
      );
    });

    test(
      'Firebase Admin failure → incrementAttemptCount + markFailed; '
      'no audit + no outbox; siblings still complete',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
            _due(requestId: _requestIdB, factorId: _factorIdB),
          ],
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        final mfaRepo = _MfaFactorsFake();
        // Throw on the FIRST clearMfaEnrollments call only; second succeeds.
        final firebase = _FirebaseAdminFake(failOnCall: <int>{1});
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: mfaRepo,
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: firebase,
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        expect(result.claimed, equals(2));
        expect(result.completed, equals(1));
        expect(result.failed, equals(1));
        expect(result.deadLettered, equals(0));
        // Only the second request's TOTP factor was revoked locally.
        expect(mfaRepo.revokedTotpFactors, equals(<String>[_factorIdB]));
        // incrementAttemptCount fired once (for the failing request)
        // ahead of markFailed.
        expect(removalRepo.incrementAttemptCalls, hasLength(1));
        expect(
          removalRepo.incrementAttemptCalls.single,
          equals(_requestIdA),
        );
        // Only one markFailed call (for the first / failing request).
        expect(removalRepo.markFailedCalls, hasLength(1));
        expect(removalRepo.markFailedCalls.single.requestId, equals(_requestIdA));
        // Only one audit event + outbox enqueue (for the success).
        expect(auditRepo.events, hasLength(1));
        expect(
          auditRepo.events.single.payload['request_id'],
          equals(_requestIdB),
        );
        expect(outbox.enqueued, hasLength(1));
        expect(
          outbox.enqueued.single.payload['event_id'],
          equals(_requestIdB),
        );
      },
    );

    test(
      'markCompleted returning 0 (race) → skip audit + outbox + completed',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
          markCompletedReturns: 0,
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        // The row was claimed but a parallel writer beat us to
        // markCompleted; we don't double-count, don't audit, don't outbox.
        expect(result.claimed, equals(1));
        expect(result.completed, equals(0));
        expect(result.failed, equals(0));
        expect(result.deadLettered, equals(0));
        expect(auditRepo.events, isEmpty);
        expect(outbox.enqueued, isEmpty);
      },
    );

    test('workerOwner flows into the claim + the audit payload', () async {
      final removalRepo = _RemovalRequestsFake(
        records: <MfaFactorRemovalRequestRecord>[
          _due(requestId: _requestIdA, factorId: _factorIdA),
        ],
      );
      final auditRepo = _AuditFake();
      final worker = MfaRemovalWorker(
        removalRequestsRepository: removalRepo,
        mfaFactorsRepository: _MfaFactorsFake(),
        usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
        auditRepository: auditRepo,
        firebaseAdmin: _FirebaseAdminFake(),
        eventOutboxRepository: _EventOutboxFake(),
        now: () => DateTime.utc(2026, 5, 1, 13),
        workerOwner: 'cron-job-canary',
      );

      await worker.processDue();

      expect(removalRepo.lastClaimOwner, equals('cron-job-canary'));
      expect(
        auditRepo.events.single.payload['worker_owner'],
        equals('cron-job-canary'),
      );
      expect(
        auditRepo.events.single.payload['completed_at'],
        equals('2026-05-01T13:00:00.000Z'),
      );
    });

    test(
      'completes without an outbox repository (degraded-but-launchable mode)',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        final auditRepo = _AuditFake();
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          // eventOutboxRepository intentionally omitted.
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        expect(result.completed, equals(1));
        expect(auditRepo.events, hasLength(1));
      },
    );

    test('respects batchSize when claiming due rows', () async {
      final removalRepo = _RemovalRequestsFake();
      final worker = MfaRemovalWorker(
        removalRequestsRepository: removalRepo,
        mfaFactorsRepository: _MfaFactorsFake(),
        usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
        auditRepository: _AuditFake(),
        firebaseAdmin: _FirebaseAdminFake(),
        now: () => DateTime.utc(2026, 5, 1, 13),
      );

      await worker.processDue(batchSize: 7);

      expect(removalRepo.lastClaimLimit, equals(7));
    });
  });

  group('MfaRemovalWorker.processDue — L7 retry cap + DLQ', () {
    test(
      'sequential failures bump attempt_count without dead-lettering '
      'until the 10th failure',
      () async {
        // Drive 10 sequential ticks. Each tick claims the same row
        // and Firebase fails on every tick, so the worker's failure
        // arm runs once per tick.
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        // Fail every clearMfaEnrollments call.
        final firebase = _FirebaseAdminFake(failEveryCall: true);
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: firebase,
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        // First 9 ticks: each bumps attempt_count by 1, no DLQ.
        for (var i = 1; i <= 9; i += 1) {
          final result = await worker.processDue();
          expect(result.failed, equals(1));
          expect(
            result.deadLettered,
            equals(0),
            reason: 'tick $i should not dead-letter (count=$i, cap=10)',
          );
        }
        expect(removalRepo.attemptCount(_requestIdA), equals(9));
        expect(removalRepo.deadLetteredCount(_requestIdA), equals(0));
        // No outbox events yet — DLQ is the only path that enqueues
        // through `_eventOutboxRepository.enqueue` for a failed row.
        expect(outbox.enqueued, isEmpty);

        // 10th tick: post-increment count == 10, DLQ fires.
        final tenthResult = await worker.processDue();
        expect(tenthResult.failed, equals(1));
        expect(tenthResult.deadLettered, equals(1));
        expect(removalRepo.attemptCount(_requestIdA), equals(10));
        expect(removalRepo.deadLetteredCount(_requestIdA), equals(1));
        expect(outbox.enqueued, hasLength(1));
        expect(
          outbox.enqueued.single.topic,
          equals('auth.user.mfa_factor_removal_dead_lettered'),
        );
        expect(
          outbox.enqueued.single.payload['request_id'],
          equals(_requestIdA),
        );
        expect(
          outbox.enqueued.single.payload['attempt_count'],
          equals(10),
        );
        expect(
          outbox.enqueued.single.payload['max_attempts'],
          equals(10),
        );
      },
    );

    test(
      'audit insert failure rolls back markCompletedInTransaction; row '
      'stays in pending state with attempt_count bumped; next tick '
      'completes cleanly',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        // Audit fake throws on insertSystemEventOn — simulates a
        // Postgres failure on the audit-row INSERT inside the
        // single-tx atomic completion body. The wrapper must roll the
        // whole transaction back so markCompletedInTransaction is
        // discarded and the row stays claimable. The worker's catch
        // arm then routes through `_onFailure` which opens its own tx
        // for incrementAttemptCount + markFailed.
        final auditRepo = _ThrowingAuditFake();
        final outbox = _EventOutboxFake();
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        // Tick 1 — markCompletedInTransaction's UPDATE matched 1
        // (row was pending), audit throws inside the body, the
        // surrounding transaction rolls back. The fake's
        // `completedRequestIds` MUST stay empty: that is the
        // observable proof that markCompleted was rolled back.
        final result1 = await worker.processDue();
        expect(result1.claimed, equals(1));
        expect(result1.completed, equals(0));
        expect(result1.failed, equals(1));
        expect(result1.deadLettered, equals(0));
        // markCompletedInTransaction was attempted but rolled back.
        expect(removalRepo.markCompletedAttempts, equals(1));
        expect(
          removalRepo.completedRequestIds,
          isEmpty,
          reason: 'audit failure must roll markCompleted back; with '
              'single-tx atomicity the row stays pending',
        );
        // No success-path outbox enqueue happened (rolled back).
        expect(outbox.enqueued, isEmpty);
        // Failure arm fired in its own transaction: increment +
        // markFailed (both run outside the rolled-back atomic body).
        expect(removalRepo.incrementAttemptCalls, hasLength(1));
        expect(removalRepo.markFailedCalls, hasLength(1));
        expect(removalRepo.attemptCount(_requestIdA), equals(1));

        // Tick 2 — audit healed; the row is reclaimed and completes
        // cleanly with no double-emission (audit + outbox each fire
        // exactly once, as they would for a fresh first-try success).
        final retryAudit = _AuditFake();
        final retryWorker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: retryAudit,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );
        final result2 = await retryWorker.processDue();
        expect(result2.claimed, equals(1));
        expect(result2.completed, equals(1));
        expect(result2.failed, equals(0));
        expect(result2.deadLettered, equals(0));
        expect(retryAudit.events, hasLength(1));
        expect(outbox.enqueued, hasLength(1));
        expect(
          outbox.enqueued.single.topic,
          equals('auth.user.mfa_factor_removed'),
        );
        // The success-path completed flag is now committed.
        expect(removalRepo.completedRequestIds, equals(<String>[_requestIdA]));
      },
    );

    test(
      'race-loss inside atomic body (markCompleted UPDATE returns 0) '
      'commits the empty transaction without audit/outbox writes',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
          markCompletedReturns: 0,
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        // Race-lost: markCompleted UPDATE matched 0 (parallel writer
        // already finalised). Body returns _RowOutcome.raceLost without
        // throwing, so the transaction commits cleanly with no audit /
        // outbox writes.
        expect(result.claimed, equals(1));
        expect(result.completed, equals(0));
        expect(result.failed, equals(0));
        expect(result.deadLettered, equals(0));
        expect(auditRepo.events, isEmpty);
        expect(outbox.enqueued, isEmpty);
        // markCompletedInTransaction was attempted but matched 0 —
        // not a rollback, just a no-op commit.
        expect(removalRepo.markCompletedAttempts, equals(1));
        expect(removalRepo.atomicTransactionsCommitted, equals(1));
        expect(removalRepo.atomicTransactionsRolledBack, equals(0));
      },
    );

    test(
      'C-2-C wire — dispatcher is invoked inside the atomic completion '
      'transaction when bound and the user contact resolves',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        final dispatcherCalls = <_DispatcherCall>[];
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: (
            exec, {
            required String operatorId,
            required String userId,
            required String recipientEmail,
            required String? recipientDisplayName,
            required String templateId,
            required Map<String, String> templateData,
          }) async {
            dispatcherCalls.add(_DispatcherCall(
              recipientEmail: recipientEmail,
              templateId: templateId,
              templateData: templateData,
            ));
          },
          auditEmit: (
            exec, {
            required String operatorId,
            required String locationId,
            required String userId,
            required String eventType,
            required Map<String, Object?> payload,
          }) async {
            // The dispatcher emits its own audit row via this seam.
            // Append it onto the shared audit recorder so the
            // existing "events list" assertions still hold.
            auditRepo.events.add(_AuditEvent(
              eventType: eventType,
              actorKind: 'system',
              payload: payload,
            ));
          },
          accountSecurityUrl:
              'https://app.forgeflow.app/account/security',
          now: () => DateTime.utc(2026, 5, 1, 13, 30),
        );

        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(
            firebaseUid: 'fb-uid',
            contact: const UserContactProjection(
              userId: _userId,
              email: 'pat@acme.test',
              displayName: 'Pat GM',
            ),
          ),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          factorChangedNoticeDispatcher: dispatcher,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        expect(result.completed, equals(1));
        expect(result.failed, equals(0));
        expect(dispatcherCalls, hasLength(1));
        expect(dispatcherCalls.single.recipientEmail, equals('pat@acme.test'));
        expect(
          dispatcherCalls.single.templateId,
          equals('mfa_factor_changed_notice'),
        );
        expect(
          dispatcherCalls.single.templateData['recipientName'],
          equals('Pat GM'),
        );
        // Two audit rows in total: the existing
        // `mfa_factor_revocation_completed` event AND the
        // dispatcher's `mfa_factor_changed_email_enqueued` event.
        expect(auditRepo.events, hasLength(2));
        expect(
          auditRepo.events.map((e) => e.eventType).toSet(),
          equals(<String>{
            'mfa_factor_revocation_completed',
            'mfa_factor_changed_email_enqueued',
          }),
        );
        // The legacy `auth.user.mfa_factor_removed` event_outbox row
        // is still written (the dispatcher does not replace it).
        expect(outbox.enqueued, hasLength(1));
        expect(
          outbox.enqueued.single.topic,
          equals('auth.user.mfa_factor_removed'),
        );
      },
    );

    test(
      'C-2-C wire — dispatcher short-circuits when the user contact '
      'lookup returns null (no email row, no dispatcher invocation)',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        final auditRepo = _AuditFake();
        final outbox = _EventOutboxFake();
        final dispatcherCalls = <_DispatcherCall>[];
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: (
            exec, {
            required String operatorId,
            required String userId,
            required String recipientEmail,
            required String? recipientDisplayName,
            required String templateId,
            required Map<String, String> templateData,
          }) async {
            dispatcherCalls.add(_DispatcherCall(
              recipientEmail: recipientEmail,
              templateId: templateId,
              templateData: templateData,
            ));
          },
          auditEmit: (
            exec, {
            required String operatorId,
            required String locationId,
            required String userId,
            required String eventType,
            required Map<String, Object?> payload,
          }) async {},
          accountSecurityUrl:
              'https://app.forgeflow.app/account/security',
          now: () => DateTime.utc(2026, 5, 1, 13, 30),
        );

        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          // No contact row available (redacted user, missing row, etc.)
          usersRepository: _UsersFake(
            firebaseUid: 'fb-uid',
            contact: null,
          ),
          auditRepository: auditRepo,
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: outbox,
          factorChangedNoticeDispatcher: dispatcher,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        // Removal still completes; only the email enqueue is skipped.
        expect(result.completed, equals(1));
        expect(dispatcherCalls, isEmpty);
        // Just the legacy revocation audit, no dispatcher audit.
        expect(auditRepo.events, hasLength(1));
        expect(
          auditRepo.events.single.eventType,
          equals('mfa_factor_revocation_completed'),
        );
      },
    );

    test(
      'shouldStop predicate breaks the per-row loop between rows',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
            _due(requestId: _requestIdB, factorId: _factorIdB),
          ],
        );
        // shouldStop returns false on the first check (so the first
        // row is processed) and true thereafter — emulates a SIGTERM
        // landing while row A is mid-flight.
        var checks = 0;
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: _MfaFactorsFake(),
          usersRepository: _UsersFake(firebaseUid: 'fb-uid'),
          auditRepository: _AuditFake(),
          firebaseAdmin: _FirebaseAdminFake(),
          eventOutboxRepository: _EventOutboxFake(),
          now: () => DateTime.utc(2026, 5, 1, 13),
          shouldStop: () {
            checks += 1;
            return checks > 1;
          },
        );

        final result = await worker.processDue();

        // Both rows were claimed by claimDuePending (the claim is a
        // single SQL statement; we don't tear it apart on shutdown).
        // Only the first row's per-row pipeline ran; the second was
        // skipped without a markCompleted/markFailed write.
        expect(result.claimed, equals(2));
        expect(result.completed, equals(1));
        expect(result.failed, equals(0));
        expect(result.deadLettered, equals(0));
      },
    );
  });
}

// ─── Fakes ─────────────────────────────────────────────────────────────

class _MarkFailedCall {
  const _MarkFailedCall({
    required this.requestId,
    required this.error,
  });

  final String requestId;
  final String error;
}

class _RemovalRequestsFake extends MfaFactorRemovalRequestsRepository {
  _RemovalRequestsFake({
    List<MfaFactorRemovalRequestRecord> records =
        const <MfaFactorRemovalRequestRecord>[],
    int markCompletedReturns = 1,
  })  : records = <MfaFactorRemovalRequestRecord>[...records],
        _markCompletedReturns = markCompletedReturns,
        super(TenantTransactionWrapper(_NoopPool()));

  final List<MfaFactorRemovalRequestRecord> records;
  int _markCompletedReturns;
  final markFailedCalls = <_MarkFailedCall>[];
  final incrementAttemptCalls = <String>[];
  final markDeadLetteredCalls = <String>[];
  String? lastClaimOwner;
  int? lastClaimLimit;

  /// Per-request running counts. The schema CHECK caps `attempt_count`
  /// at 100 and `dead_lettered_at` is a single timestamp; the in-memory
  /// fake mirrors both as plain counters keyed by `request_id`.
  final _attemptCounts = <String, int>{};
  final _deadLetterStamps = <String, int>{};

  /// Atomic-completion fake state.
  ///
  /// `markCompletedAttempts` counts every call to
  /// [markCompletedInTransaction] regardless of commit/rollback so
  /// tests can pin the worker's per-row retry shape. Pending
  /// completions are buffered in [_pendingCompletions] and either
  /// drained into [completedRequestIds] when [withTenant]'s body
  /// returns normally, or discarded when it throws — that's the
  /// observable "rollback" behavior.
  int markCompletedAttempts = 0;
  int atomicTransactionsCommitted = 0;
  int atomicTransactionsRolledBack = 0;
  final List<String> _pendingCompletions = <String>[];
  final List<String> completedRequestIds = <String>[];

  int attemptCount(String requestId) => _attemptCounts[requestId] ?? 0;
  int deadLetteredCount(String requestId) =>
      _deadLetterStamps[requestId] ?? 0;

  /// Whether [requestId] is currently in the committed-completed set.
  /// `claimDuePending` consults this so a row that has been fully
  /// completed in a prior tick is excluded from the next tick's claim
  /// batch (mirroring the partial-index shape on the real schema).
  bool isCommittedCompleted(String requestId) =>
      completedRequestIds.contains(requestId);

  /// Test seam — flips [_markCompletedReturns] mid-test. Retained for
  /// parity with the legacy fake API; the new atomicity tests prefer
  /// to model the post-rollback "row stays pending" shape directly via
  /// the [completedRequestIds] / [_pendingCompletions] buffers, so
  /// most tests no longer need to flip this manually.
  void forceMarkCompletedReturns(int value) {
    _markCompletedReturns = value;
  }

  @override
  Future<List<MfaFactorRemovalRequestRecord>> claimDuePending({
    required DateTime now,
    required String workerOwner,
    int limit = 50,
    Duration staleAfter = const Duration(minutes: 15),
  }) async {
    lastClaimOwner = workerOwner;
    lastClaimLimit = limit;
    // Filter dead-lettered AND committed-completed rows out so
    // subsequent ticks see an empty claim batch (mirrors the M4
    // partial-index shape on the real schema).
    return records
        .where((r) =>
            deadLetteredCount(r.requestId) == 0 &&
            !isCommittedCompleted(r.requestId))
        .toList();
  }

  /// Override the inherited `withTenant` so the fake can run the body
  /// without a live Postgres pool AND simulate transaction
  /// commit/rollback. The body sees a [_FakeExecutor] that the
  /// downstream fakes (audit + outbox) ignore — they record their
  /// effects directly. This fake is the source-of-truth for
  /// markCompleted's commit semantics: writes buffered in
  /// [_pendingCompletions] either move to [completedRequestIds] on a
  /// clean body return or are dropped on a body throw.
  @override
  Future<R> withTenant<R>(
    TenantContext context,
    Future<R> Function(PostgresExecutor exec) body,
  ) async {
    final exec = _FakeExecutor();
    _pendingCompletions.clear();
    try {
      final result = await body(exec);
      // Commit: drain pending completions into the committed set.
      completedRequestIds.addAll(_pendingCompletions);
      _pendingCompletions.clear();
      atomicTransactionsCommitted += 1;
      return result;
    } catch (_) {
      // Rollback: drop pending completions. Tests assert on
      // [completedRequestIds] to verify the rollback held.
      _pendingCompletions.clear();
      atomicTransactionsRolledBack += 1;
      rethrow;
    }
  }

  @override
  Future<int> markCompletedInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
    markCompletedAttempts += 1;
    if (_markCompletedReturns == 0) {
      // Race-loss UPDATE: matched 0 rows. Don't buffer the completion.
      return 0;
    }
    _pendingCompletions.add(requestId);
    return _markCompletedReturns;
  }

  @override
  Future<int> markCompleted({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
    // Legacy callers still hit this seam. Mirror the in-tx variant for
    // parity but commit immediately (the legacy method opens its own
    // tx). Not used by the post-atomic-completion worker.
    markCompletedAttempts += 1;
    if (_markCompletedReturns == 0) return 0;
    completedRequestIds.add(requestId);
    return _markCompletedReturns;
  }

  @override
  Future<int> markFailed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required String error,
  }) async {
    markFailedCalls.add(_MarkFailedCall(requestId: requestId, error: error));
    return 1;
  }

  @override
  Future<int> incrementAttemptCount({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
  }) async {
    incrementAttemptCalls.add(requestId);
    final next = (_attemptCounts[requestId] ?? 0) + 1;
    _attemptCounts[requestId] = next;
    return next;
  }

  @override
  Future<int> markDeadLettered({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required String reason,
  }) async {
    markDeadLetteredCalls.add(requestId);
    final stamps = (_deadLetterStamps[requestId] ?? 0) + 1;
    _deadLetterStamps[requestId] = stamps;
    return 1;
  }
}

/// Stand-in for a real `PostgresExecutor` inside the atomic-completion
/// body. The downstream fakes (audit + outbox) ignore the executor
/// argument and record effects on themselves; the fake's only job is
/// to satisfy the type system. Any unexpected SQL would surface as a
/// hard StateError so a test that drifts from the contract fails
/// loudly.
class _FakeExecutor implements PostgresExecutor {
  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError(
      'unexpected query in atomic-completion body: $sql — '
      'fakes record on their own state, not via the executor',
    );
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError(
      'unexpected execute in atomic-completion body: $sql — '
      'fakes record on their own state, not via the executor',
    );
  }
}

class _MfaFactorsFake extends MfaFactorsRepository {
  _MfaFactorsFake() : super(TenantTransactionWrapper(_NoopPool()));

  final revokedTotpFactors = <String>[];
  int revokedRecoveryCodeCalls = 0;

  @override
  Future<int> revokeTotpFactor({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
  }) async {
    revokedTotpFactors.add(factorId);
    return 1;
  }

  @override
  Future<int> revokeActiveRecoveryCodeFactorsForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    revokedRecoveryCodeCalls += 1;
    return 0;
  }
}

class _UsersFake extends UsersRepository {
  _UsersFake({required this.firebaseUid, this.contact})
      : super(TenantTransactionWrapper(_NoopPool()));

  final String firebaseUid;
  final UserContactProjection? contact;

  @override
  Future<String> firebaseUidForUserSystem({
    required String userId,
    required String adminReason,
    String? requireOperatorId,
  }) async {
    return firebaseUid;
  }

  @override
  Future<UserAuthLookupRow?> findActiveAuthUserByEmail({
    required String email,
    required String adminReason,
  }) async {
    return null;
  }

  @override
  Future<UserContactProjection?> findUserContactSystem({
    required String userId,
    required String adminReason,
    String? requireOperatorId,
  }) async {
    return contact;
  }
}

class _AuditEvent {
  const _AuditEvent({
    required this.eventType,
    required this.actorKind,
    required this.payload,
  });

  final String eventType;
  final String actorKind;
  final Map<String, Object?> payload;
}

class _AuditFake extends AuthEventsAuditRepository {
  _AuditFake() : super(TenantTransactionWrapper(_NoopPool()));

  final events = <_AuditEvent>[];

  @override
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    required String actorKind,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-${events.length}';
  }

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-${events.length}';
  }

  /// On-executor variant the atomic-completion body calls. The fake
  /// ignores [exec] and records on the same `events` list as the
  /// other helpers so existing assertions still hold.
  @override
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-${events.length}';
  }
}

/// Variant audit fake whose `insertSystemEventOn` always throws —
/// pins the atomic-completion rollback test. The on-executor variant
/// is the one the post-atomic worker calls; the legacy
/// `insertSystemEvent` is kept throwing for parity should other
/// callers regress.
class _ThrowingAuditFake extends _AuditFake {
  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    throw const _FakeAuditError('audit_insert_failed');
  }

  @override
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    throw const _FakeAuditError('audit_insert_failed');
  }
}

class _FakeAuditError implements Exception {
  const _FakeAuditError(this.message);
  final String message;
  @override
  String toString() => 'FakeAuditError($message)';
}

class _OutboxEvent {
  const _OutboxEvent({required this.topic, required this.payload});

  final String topic;
  final Map<String, Object?> payload;
}

class _EventOutboxFake extends EventOutboxRepository {
  _EventOutboxFake() : super(TenantTransactionWrapper(_NoopPool()));

  final enqueued = <_OutboxEvent>[];

  @override
  Future<String> enqueue({
    required String operatorId,
    required String locationId,
    required String topic,
    required Map<String, Object?> payload,
    String? userId,
  }) async {
    enqueued.add(_OutboxEvent(topic: topic, payload: payload));
    return 'outbox-${enqueued.length}';
  }

  /// On-executor variant the atomic-completion body calls. The fake
  /// ignores [exec] and records on the same `enqueued` list as the
  /// legacy [enqueue] so existing assertions still hold.
  @override
  Future<String> enqueueInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String topic,
    required Map<String, Object?> payload,
  }) async {
    enqueued.add(_OutboxEvent(topic: topic, payload: payload));
    return 'outbox-${enqueued.length}';
  }
}

class _FirebaseAdminFake implements FirebaseAdminAuthClient {
  _FirebaseAdminFake({Set<int>? failOnCall, this.failEveryCall = false})
      : _failOnCall = failOnCall ?? const <int>{};

  final Set<int> _failOnCall;
  final bool failEveryCall;
  final clearedMfaUids = <String>[];
  int _calls = 0;

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {
    _calls += 1;
    if (failEveryCall || _failOnCall.contains(_calls)) {
      throw const FirebaseAdminAuthError('clear_mfa_failed');
    }
    clearedMfaUids.add(uid);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError();
  }
}

class _DispatcherCall {
  const _DispatcherCall({
    required this.recipientEmail,
    required this.templateId,
    required this.templateData,
  });

  final String recipientEmail;
  final String templateId;
  final Map<String, String> templateData;
}
