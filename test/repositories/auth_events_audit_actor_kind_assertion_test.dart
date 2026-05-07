// ops-debt.actor-kind-audit M2 — actor_kind shape-assertion tests.
//
// CLAUDE.md hard promise: `audit_logs.actor_kind never NULL`. Until
// this lane, AuthEventsAuditRepository.insertEvent / insertSystemEvent
// silently defaulted [actorKind] to `'user'`, which let SP-driven
// gateway paths land under the wrong actor tag if a caller forgot to
// pass the kind. The lane makes [actorKind] required and adds an
// internal `_assertActorKindShape` invariant that pairs the kind with
// `actorServicePrincipalId`:
//
//   * non-null SP id requires `actorKind == 'service_principal'` (or
//     the chain-format alias `'service'`).
//   * `actorKind == 'service_principal'` / `'service'` requires a
//     non-null SP id.
//   * `actorKind` itself must be one of
//     `'user' / 'service_principal' / 'service' / 'system'`.
//
// These tests exercise the invariant through the public `insertEvent`
// and `insertSystemEvent` APIs — the helper is intentionally private
// so tests cannot couple to its signature. Each test asserts an
// `ArgumentError` is thrown synchronously (before any `auth_events_audit`
// row is written) so a mis-tagged caller fails closed before the
// hash-chained `audit_logs` mirror row could ever land.
//
// The five WIP-classified call sites (mfa_operations_gateway × 3,
// repository_password_change_gateway × 1, repository_auth_operations_
// gateway × 1) all pass `actorKind: 'user'` with no SP id, so they
// route through the happy path. The `mfa_removal_worker` worker passes
// `actorKind: 'system'` (no actor), which is also accepted.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opId = '11111111-1111-1111-1111-111111111111';
const String _locId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _spId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('AuthEventsAuditRepository._assertActorKindShape (insertEvent)', () {
    test(
      'actorServicePrincipalId set + actorKind=user throws — SP-driven '
      "rows must not silently inherit the legacy 'user' default",
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertEvent(
            operatorId: _opId,
            locationId: _locId,
            eventType: 'auth.user.signed_in',
            actorKind: 'user',
            actorServicePrincipalId: _spId,
            actorUserId: _userId,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('service_principal'),
            ),
          ),
          reason:
              'a non-null actorServicePrincipalId requires '
              "actorKind: 'service_principal' — silent 'user' tag "
              'is the exact bug the lane removes',
        );
        expect(
          pool.transactions,
          isEmpty,
          reason: 'shape check fires BEFORE the transaction opens',
        );
      },
    );

    test(
      "actorKind='service_principal' with no SP id throws — the SP "
      'kind requires the SP JWT id to be plumbed through',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertEvent(
            operatorId: _opId,
            locationId: _locId,
            eventType: 'auth.user.signed_in',
            actorKind: 'service_principal',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('actorServicePrincipalId'),
            ),
          ),
          reason:
              'service-principal-driven rows must carry the SP id from '
              'the SP JWT context so audit_logs.actor_principal_id is '
              'never null when actor_kind=service',
        );
      },
    );

    test(
      'invalid actorKind throws — guards against typos / future kinds '
      'that have not been wired through the audit_logs CHECK',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertEvent(
            operatorId: _opId,
            locationId: _locId,
            eventType: 'auth.user.signed_in',
            actorKind: 'admin',
            actorUserId: _userId,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('actor_kind must be one of'),
            ),
          ),
        );
      },
    );

    test(
      "actorKind='user' with actorUserId and NO SP id is the happy "
      'path — five WIP call sites + every HTTP gateway pass through here',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertEvent(
          operatorId: _opId,
          locationId: _locId,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userId,
        );
        expect(eventId, equals('event-id-1'));
        expect(pool.transactions, hasLength(1));
      },
    );

    test(
      "actorKind='service_principal' WITH actorServicePrincipalId is "
      'the happy path — worker / SP-JWT call sites map here',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertEvent(
          operatorId: _opId,
          locationId: _locId,
          eventType: 'auth.sp.event',
          actorKind: 'service_principal',
          actorServicePrincipalId: _spId,
        );
        expect(eventId, equals('event-id-1'));
      },
    );

    test(
      "actorKind='system' (no human / SP) with no SP id is the happy "
      'path — MfaRemovalWorker / password-reset paths route here',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertEvent(
          operatorId: _opId,
          locationId: _locId,
          eventType: 'mfa_factor_revocation_completed',
          actorKind: 'system',
          targetUserId: _userId,
        );
        expect(eventId, equals('event-id-1'));
      },
    );
  });

  group('AuthEventsAuditRepository._assertActorKindShape (insertSystemEvent)', () {
    test(
      'insertSystemEvent fires the same shape check before opening the '
      'admin transaction — admin paths cannot bypass the invariant',
      () async {
        final pool = _ShapePool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.insertSystemEvent(
            eventType: 'admin.x',
            actorKind: 'user',
            actorServicePrincipalId: _spId,
            adminReason: 'shape-check',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          pool.transactions,
          isEmpty,
          reason: 'admin transaction never opens when shape is invalid',
        );
      },
    );
  });
}

/// Minimal Postgres pool that returns a synthetic event id so the
/// happy-path tests can confirm the shape check let the call through.
/// The shape-failure tests assert `transactions` stays empty so the
/// invariant short-circuits before any work hits the wire.
class _ShapePool implements PostgresPool {
  final List<_ShapeTransaction> transactions = <_ShapeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ShapeTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _ShapeTransaction extends PostgresTransaction {
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    if (sql.contains('insert into auth_events_audit') &&
        sql.contains('returning event_id')) {
      return const <PostgresRow>[
        <String, Object?>{'event_id': 'event-id-1'},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
