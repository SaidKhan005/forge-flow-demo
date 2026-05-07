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
//   * Failure AFTER markCompleted (e.g. audit insert raises) — the
//     worker treats it as a row failure: incrementAttemptCount +
//     markFailed run; on the retry, markCompleted's WHERE-clause
//     guard short-circuits to a race-lost outcome so audit/outbox are
//     not double-emitted.
//   * `shouldStop` predicate breaks the per-row loop between rows so
//     SIGTERM-driven cooperative shutdown leaves the next row for the
//     replacement instance.
//
// The worker is composed of small repository fakes that mirror the
// shape used by `mfa_operations_gateway_test.dart`. The retry-cap +
// DLQ surface is exercised through new fake methods backed by M4's
// `incrementAttemptCount` / `markDeadLettered`.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
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
      'failure after markCompleted (audit insert raises) → '
      'incrementAttemptCount + markFailed; row stays claimable; on retry '
      'markCompleted returns 0 so audit + outbox are not double-emitted',
      () async {
        final removalRepo = _RemovalRequestsFake(
          records: <MfaFactorRemovalRequestRecord>[
            _due(requestId: _requestIdA, factorId: _factorIdA),
          ],
        );
        // Audit fake throws on insertSystemEvent — simulates a
        // Postgres failure on the audit-row INSERT (post markCompleted).
        // The L7 worker treats that as a row-level failure: the row
        // is left in a state where the next tick reclaims it, sees
        // `markCompleted` return 0 (the WHERE clause excludes
        // already-completed rows), and short-circuits via raceLost.
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

        // Tick 1 — markCompleted succeeds (returns 1), audit throws,
        // failure arm runs.
        final result1 = await worker.processDue();
        expect(result1.claimed, equals(1));
        expect(result1.completed, equals(0));
        expect(result1.failed, equals(1));
        expect(result1.deadLettered, equals(0));
        // No success-path outbox enqueue happened because the audit
        // INSERT raised before the outbox call.
        expect(outbox.enqueued, isEmpty);
        // Failure arm fired: increment + markFailed.
        expect(removalRepo.incrementAttemptCalls, hasLength(1));
        expect(removalRepo.markFailedCalls, hasLength(1));
        expect(removalRepo.attemptCount(_requestIdA), equals(1));

        // Simulate the next polling tick after the row has been
        // re-marked completed by a parallel worker (or simply remains
        // completed from tick 1 since markCompleted ran before audit
        // failed). Force markCompleted to return 0 so the WHERE-
        // clause guard short-circuits the worker to raceLost.
        removalRepo.forceMarkCompletedReturns(0);
        // Use a non-throwing audit fake so we'd see the event if it
        // fired.
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
        // Tick 2 — markCompleted returns 0 (the row is already
        // completed). The worker short-circuits to raceLost: not
        // counted as completed, not audited, not enqueued.
        expect(result2.claimed, equals(1));
        expect(result2.completed, equals(0));
        expect(result2.failed, equals(0));
        expect(result2.deadLettered, equals(0));
        expect(retryAudit.events, isEmpty);
        // The DLQ-channel outbox was not touched on either tick (one
        // failure is far below the retry cap).
        expect(outbox.enqueued, isEmpty);
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

  int attemptCount(String requestId) => _attemptCounts[requestId] ?? 0;
  int deadLetteredCount(String requestId) =>
      _deadLetterStamps[requestId] ?? 0;

  /// Test seam — flips [_markCompletedReturns] mid-test so the second
  /// tick of the audit-failure scenario can simulate a "row already
  /// completed" race.
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
    // Filter dead-lettered rows out so subsequent ticks of the
    // retry-cap test see an empty claim batch (matches the M4 partial
    // index shape).
    return records
        .where((r) => deadLetteredCount(r.requestId) == 0)
        .toList();
  }

  @override
  Future<int> markCompleted({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
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
  _UsersFake({required this.firebaseUid})
      : super(TenantTransactionWrapper(_NoopPool()));

  final String firebaseUid;

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
}

class _AuditEvent {
  const _AuditEvent({required this.eventType, required this.payload});

  final String eventType;
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
    String? actorUserId,
    String actorKind = 'user',
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    events.add(_AuditEvent(eventType: eventType, payload: payload));
    return 'event-${events.length}';
  }

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String actorKind = 'user',
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(_AuditEvent(eventType: eventType, payload: payload));
    return 'event-${events.length}';
  }
}

/// Variant audit fake whose `insertSystemEvent` always throws —
/// pins the failure-after-markCompleted test.
class _ThrowingAuditFake extends _AuditFake {
  @override
  Future<String> insertSystemEvent({
    required String eventType,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String actorKind = 'user',
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
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
