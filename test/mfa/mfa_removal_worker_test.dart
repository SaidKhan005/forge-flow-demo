// L5 — MfaRemovalWorker unit coverage.
//
// `mfa_operations_gateway_test.dart` exercises one happy-path tick.
// This file pins the boundary contract:
//
//   * empty due batch → MfaRemovalWorkerResult(0, 0, 0).
//   * multiple due requests are processed in a single tick and counted.
//   * Firebase Admin failure inside `clearMfaEnrollments` falls into the
//     catch arm: mark_failed runs, audit + outbox are NOT written, and
//     other queued requests in the same tick still complete.
//   * `markCompleted` returning zero (raced by another worker) skips
//     the audit + outbox without bumping `completed` — the second
//     worker stays idempotent rather than double-counting.
//   * Configurable `workerOwner` flows into the audit payload and the
//     `claimDuePending` call so observability sees who claimed the row.
//   * `eventOutboxRepository` is optional — the worker still completes
//     when no outbox is wired (degraded-but-launchable mode).
//
// The worker is composed of small repository fakes that mirror the
// shape used by `mfa_operations_gateway_test.dart`, with two
// extensions: a `_throwOnClear` flag on the Firebase Admin fake and a
// "racing" mode for the removal-requests fake that returns 0 from
// `markCompleted` to simulate an already-finalized row.

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
      'Firebase Admin failure → markFailed + no audit + no outbox; siblings '
      'still complete',
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
        // Only the second request's TOTP factor was revoked locally.
        expect(mfaRepo.revokedTotpFactors, equals(<String>[_factorIdB]));
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
        // Outbox payload uses `event_id` (not `request_id`) — the
        // worker reuses the removal request id as the outbox event id
        // so downstream subscribers can correlate without an extra
        // join.
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
    this.markCompletedReturns = 1,
  })  : records = <MfaFactorRemovalRequestRecord>[...records],
        super(TenantTransactionWrapper(_NoopPool()));

  final List<MfaFactorRemovalRequestRecord> records;
  final int markCompletedReturns;
  final markFailedCalls = <_MarkFailedCall>[];
  String? lastClaimOwner;
  int? lastClaimLimit;

  @override
  Future<List<MfaFactorRemovalRequestRecord>> claimDuePending({
    required DateTime now,
    required String workerOwner,
    int limit = 50,
    Duration staleAfter = const Duration(minutes: 15),
  }) async {
    lastClaimOwner = workerOwner;
    lastClaimLimit = limit;
    return records;
  }

  @override
  Future<int> markCompleted({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
    return markCompletedReturns;
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
  _FirebaseAdminFake({Set<int>? failOnCall})
      : _failOnCall = failOnCall ?? const <int>{};

  final Set<int> _failOnCall;
  final clearedMfaUids = <String>[];
  int _calls = 0;

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {
    _calls += 1;
    if (_failOnCall.contains(_calls)) {
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
