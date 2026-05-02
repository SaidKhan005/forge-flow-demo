// L5 — MFA recovery-request attempt + gateway unit coverage.
//
// Two surfaces, one file:
//
//   1. `RepositoryMfaRecoveryRequestGateway`
//      - email normalization (trim + lowercase),
//      - 400 invalid_email rejection on malformed input,
//      - 429 rate-limit translation with retryAfter preserved,
//      - silent (queued=false) responses when the user does not exist
//        or has no admin recipients, so the endpoint cannot enumerate
//        accounts,
//      - happy path: outbox enqueue includes admin user/email lists
//        and the configured reason code.
//
//   2. `InMemoryMfaRecoveryRequestRateLimiter` extra coverage:
//      - per-IP cooldown rolls off across the configured window,
//      - blank IPs collapse onto a single `unknown` bucket so they
//        cannot bypass per-IP throttles,
//      - email cooldown decision carries the right `retryAfter`.
//
// The Postgres-side limiter has its own integration test in
// `test/mfa_recovery_request_rate_limiter_test.dart`; this file covers
// the parts the gateway composes around it.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_rate_limiter.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';
const String _adminId = '44444444-4444-4444-8444-444444444444';

MfaRecoveryTargetRow _target({
  String? locationId = _locationId,
  String email = 'mfa@example.test',
  List<MfaRecoveryAdminRecipientRow> admins = const <MfaRecoveryAdminRecipientRow>[
    MfaRecoveryAdminRecipientRow(
      userId: _adminId,
      email: 'admin@example.test',
      scopeType: 'operator_owner',
      isSuperAdmin: false,
    ),
  ],
}) {
  return MfaRecoveryTargetRow(
    userId: _userId,
    operatorId: _operatorId,
    locationId: locationId,
    email: email,
    admins: admins,
  );
}

void main() {
  group('RepositoryMfaRecoveryRequestGateway', () {
    test('normalizes email to lowercase + trim before lookup', () async {
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'mfa@example.test': _target(),
        },
      );
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: outbox,
        idFactory: () => 'request-1',
        now: () => DateTime.utc(2026, 4, 30, 12),
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: '  MFA@Example.Test  '),
      );

      expect(result.queued, isTrue);
      expect(result.requestId, equals('request-1'));
      expect(users.lookupCalls.single, equals('mfa@example.test'));
    });

    test('rejects blank or @-less email with invalid_email + 400', () async {
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: _RecordingUsersRepository(),
        eventOutboxRepository: _RecordingEventOutboxRepository(),
      );

      // The gateway's check is `email.isEmpty || !email.contains('@')`, so
      // the truly malformed inputs are: empty, whitespace-only (trim →
      // empty), and strings without an `@` at all. `@`-only / `a@` /
      // `a@b` all pass this loose check and fall through to the lookup,
      // where the lookup-not-found path returns `queued: false`.
      for (final email in const <String>['', '   ', 'not-an-email']) {
        await expectLater(
          gateway.requestRecovery(MfaRecoveryRequestCommand(email: email)),
          throwsA(
            isA<MfaRecoveryRequestRejected>()
                .having((e) => e.code, 'code', 'invalid_email')
                .having((e) => e.statusCode, 'statusCode', 400),
          ),
        );
      }
    });

    test('rate limiter blocked → throws 429 with retryAfter preserved',
        () async {
      final retryAt = DateTime.utc(2026, 4, 30, 12, 15);
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: _RecordingUsersRepository(),
        eventOutboxRepository: _RecordingEventOutboxRepository(),
        rateLimiter: _StaticRateLimiter(
          decision: MfaRecoveryRateLimitDecision.blocked(retryAfter: retryAt),
        ),
      );

      await expectLater(
        gateway.requestRecovery(
          const MfaRecoveryRequestCommand(
            email: 'mfa@example.test',
            clientIp: '203.0.113.10',
          ),
        ),
        throwsA(
          isA<MfaRecoveryRequestRejected>()
              .having((e) => e.code, 'code',
                  'mfa_recovery_request_rate_limited')
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.retryAfter, 'retryAfter', retryAt),
        ),
      );
    });

    test('silent accepted (queued=false) when target email is unknown',
        () async {
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: _RecordingUsersRepository(),
        eventOutboxRepository: outbox,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'ghost@example.test'),
      );

      expect(result.queued, isFalse);
      expect(result.requestId, isNull);
      expect(outbox.enqueued, isEmpty);
    });

    test('silent accepted when the operator has no admin recipients',
        () async {
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'orphan@example.test': _target(
            email: 'orphan@example.test',
            admins: const <MfaRecoveryAdminRecipientRow>[],
          ),
        },
      );
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: outbox,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'orphan@example.test'),
      );

      expect(result.queued, isFalse);
      expect(outbox.enqueued, isEmpty);
    });

    test('silent accepted when the target has no resolvable location_id',
        () async {
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'noloc@example.test': _target(
            email: 'noloc@example.test',
            locationId: null,
          ),
        },
      );
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: outbox,
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'noloc@example.test'),
      );
      expect(result.queued, isFalse);
      expect(outbox.enqueued, isEmpty);
    });

    test('happy path enqueues outbox event with admin lists + reason',
        () async {
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'mfa@example.test': _target(
            admins: const <MfaRecoveryAdminRecipientRow>[
              MfaRecoveryAdminRecipientRow(
                userId: 'admin-1',
                email: 'admin1@example.test',
                scopeType: 'operator_owner',
                isSuperAdmin: false,
              ),
              MfaRecoveryAdminRecipientRow(
                userId: 'admin-2',
                email: 'admin2@example.test',
                scopeType: 'operator_owner',
                isSuperAdmin: true,
              ),
            ],
          ),
        },
      );
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: outbox,
        idFactory: () => 'request-α',
        now: () => DateTime.utc(2026, 4, 30, 12),
      );

      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(
          email: 'mfa@example.test',
          reason: 'mfa_challenge_no_factor_access',
        ),
      );
      expect(result.queued, isTrue);
      expect(result.requestId, equals('request-α'));
      final enqueued = outbox.enqueued.single;
      expect(enqueued.operatorId, equals(_operatorId));
      expect(enqueued.locationId, equals(_locationId));
      expect(enqueued.userId, equals(_userId));
      expect(enqueued.topic, equals('auth.user.mfa_recovery_requested'));
      expect(enqueued.payload['event_id'], equals('request-α'));
      expect(enqueued.payload['user_id'], equals(_userId));
      expect(enqueued.payload['user_email'], equals('mfa@example.test'));
      expect(
        enqueued.payload['reason'],
        equals('mfa_challenge_no_factor_access'),
      );
      expect(
        enqueued.payload['admin_user_ids'],
        equals(<String>['admin-1', 'admin-2']),
      );
      expect(
        enqueued.payload['admin_emails'],
        equals(<String>['admin1@example.test', 'admin2@example.test']),
      );
      expect(
        enqueued.payload['occurred_at'],
        equals('2026-04-30T12:00:00.000Z'),
      );
    });

    test('uses default reason code when caller omits one', () async {
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'mfa@example.test': _target(),
        },
      );
      final outbox = _RecordingEventOutboxRepository();
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: outbox,
        idFactory: () => 'request-2',
        now: () => DateTime.utc(2026, 4, 30, 12),
      );
      await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'mfa@example.test'),
      );
      expect(
        outbox.enqueued.single.payload['reason'],
        equals('mfa_challenge_no_factor_access'),
      );
    });

    test('default uuid v4 factory produces 36-char rfc4122 strings', () async {
      // The gateway exposes a fallback uuid factory when no `idFactory`
      // is injected. Build one without the override and exercise the
      // happy path so the default factory is hit.
      final users = _RecordingUsersRepository(
        targetByEmail: <String, MfaRecoveryTargetRow>{
          'mfa@example.test': _target(),
        },
      );
      final gateway = RepositoryMfaRecoveryRequestGateway(
        usersRepository: users,
        eventOutboxRepository: _RecordingEventOutboxRepository(),
        now: () => DateTime.utc(2026, 4, 30, 12),
      );
      final result = await gateway.requestRecovery(
        const MfaRecoveryRequestCommand(email: 'mfa@example.test'),
      );
      expect(result.queued, isTrue);
      expect(result.requestId, isNotNull);
      // RFC 4122 v4 — 8-4-4-4-12 lowercase hex.
      expect(
        RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}'
                r'-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(result.requestId!),
        isTrue,
        reason: 'expected RFC4122 v4, got: ${result.requestId}',
      );
    });
  });

  group('ScaffoldFailingMfaRecoveryRequestGateway', () {
    test('refuses to queue with a 503 rejected error', () {
      const gateway = ScaffoldFailingMfaRecoveryRequestGateway();
      // The scaffold throws synchronously (not from inside a Future), so
      // wrap the call in a closure for `throwsA` to capture the throw
      // before it escapes to the test runner.
      expect(
        () => gateway.requestRecovery(
          const MfaRecoveryRequestCommand(email: 'a@b.c'),
        ),
        throwsA(
          isA<MfaRecoveryRequestRejected>()
              .having((e) => e.code, 'code',
                  'mfa_recovery_request_not_configured')
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });
  });

  group('InMemoryMfaRecoveryRequestRateLimiter (extra coverage)', () {
    test('per-IP rolling window allows fresh requests after rolloff',
        () async {
      var now = DateTime.utc(2026, 4, 30, 12);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        now: () => now,
        ipWindow: const Duration(minutes: 5),
        maxRequestsPerIpWindow: 2,
        emailCooldown: const Duration(seconds: 0),
      );

      // Two attempts inside the IP window — both allowed.
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'a@example.test',
          clientIp: '203.0.113.7',
        ))
            .isAllowed,
        isTrue,
      );
      now = now.add(const Duration(minutes: 1));
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'b@example.test',
          clientIp: '203.0.113.7',
        ))
            .isAllowed,
        isTrue,
      );
      // Third lands inside the window — blocked.
      now = now.add(const Duration(minutes: 1));
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'c@example.test',
          clientIp: '203.0.113.7',
        ))
            .isAllowed,
        isFalse,
      );
      // Roll past the 5-minute window and try again — allowed.
      now = now.add(const Duration(minutes: 5));
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'd@example.test',
          clientIp: '203.0.113.7',
        ))
            .isAllowed,
        isTrue,
      );
    });

    test('blank IPs share a single bucket so they cannot bypass throttles',
        () async {
      var now = DateTime.utc(2026, 4, 30, 12);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        now: () => now,
        emailCooldown: const Duration(seconds: 0),
        maxRequestsPerIpWindow: 1,
        ipWindow: const Duration(minutes: 10),
      );
      expect(
        (await limiter.checkAndRecord(
          normalizedEmail: 'a@example.test',
          clientIp: '   ',
        ))
            .isAllowed,
        isTrue,
      );
      now = now.add(const Duration(seconds: 1));
      // Same `unknown` bucket — blocked.
      final second = await limiter.checkAndRecord(
        normalizedEmail: 'b@example.test',
        clientIp: '',
      );
      expect(second.isAllowed, isFalse);
    });

    test('email cooldown carries retryAfter = lastAttempt + cooldown',
        () async {
      var now = DateTime.utc(2026, 4, 30, 12);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        now: () => now,
        emailCooldown: const Duration(minutes: 15),
      );
      await limiter.checkAndRecord(
        normalizedEmail: 'mfa@example.test',
        clientIp: '203.0.113.10',
      );
      now = now.add(const Duration(minutes: 5));
      final second = await limiter.checkAndRecord(
        normalizedEmail: 'MFA@example.test',
        clientIp: '203.0.113.99',
      );
      expect(second.isAllowed, isFalse);
      expect(
        second.retryAfter,
        equals(DateTime.utc(2026, 4, 30, 12, 15)),
      );
    });
  });
}

// ─── Fakes ─────────────────────────────────────────────────────────────

class _StaticRateLimiter implements MfaRecoveryRequestRateLimiter {
  _StaticRateLimiter({required this.decision});

  final MfaRecoveryRateLimitDecision decision;

  @override
  Future<MfaRecoveryRateLimitDecision> checkAndRecord({
    required String normalizedEmail,
    required String clientIp,
  }) async {
    return decision;
  }
}

class _RecordingUsersRepository extends UsersRepository {
  _RecordingUsersRepository({
    Map<String, MfaRecoveryTargetRow>? targetByEmail,
  })  : _targetByEmail = targetByEmail ?? <String, MfaRecoveryTargetRow>{},
        super(TenantTransactionWrapper(_NoopPool()));

  final Map<String, MfaRecoveryTargetRow> _targetByEmail;
  final lookupCalls = <String>[];

  @override
  Future<MfaRecoveryTargetRow?> findMfaRecoveryTargetByEmail({
    required String email,
    required String adminReason,
  }) async {
    lookupCalls.add(email);
    return _targetByEmail[email];
  }

  @override
  Future<UserAuthLookupRow?> findActiveAuthUserByEmail({
    required String email,
    required String adminReason,
  }) async {
    return null;
  }
}

class _RecordingOutboxEvent {
  const _RecordingOutboxEvent({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.topic,
    required this.payload,
  });

  final String operatorId;
  final String locationId;
  final String? userId;
  final String topic;
  final Map<String, Object?> payload;
}

class _RecordingEventOutboxRepository extends EventOutboxRepository {
  _RecordingEventOutboxRepository()
      : super(TenantTransactionWrapper(_NoopPool()));

  final enqueued = <_RecordingOutboxEvent>[];

  @override
  Future<String> enqueue({
    required String operatorId,
    required String locationId,
    required String topic,
    required Map<String, Object?> payload,
    String? userId,
  }) async {
    enqueued.add(_RecordingOutboxEvent(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      topic: topic,
      payload: payload,
    ));
    return 'outbox-${enqueued.length}';
  }
}

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError();
  }
}
