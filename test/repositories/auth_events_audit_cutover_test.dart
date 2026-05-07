// Phase 9.0Σ.f B.2 — feature-flag cutover test for the
// AuthEventsAuditRepository fan-out into public.audit_logs.
//
// Acceptance:
//   * Flag true (the default seeded by the migration): every insertEvent
//     writes BOTH the legacy `auth_events_audit` row AND the
//     hash-chained `audit_logs` row inside the same transaction.
//   * Flag false (rollback path): only the legacy `auth_events_audit`
//     row is written; the audit_logs fan-out is skipped. Control flow
//     and error handling are unchanged on either side of the flag.
//
// The fake PostgresPool watches both INSERT shapes and asserts on
// the recorded SQL count.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  group('AuthEventsAuditRepository audit_logs cutover flag', () {
    test(
      'flag=true (default): insertEvent writes auth_events_audit AND '
      'audit_logs in the same transaction',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertEvent(
          operatorId: _opA,
          locationId: _locA,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userA,
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into auth_events_audit'),
          ),
          hasLength(1),
        );
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          hasLength(1),
          reason: 'flag-true must fan out into the hash-chained audit_logs',
        );
      },
    );

    test(
      'flag=false (rollback path): insertEvent writes auth_events_audit '
      'ONLY; audit_logs fan-out is skipped',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(
          TenantTransactionWrapper(pool),
          cutoverFlag: const FixedAuditLogsCutoverFlag(false),
        );
        final eventId = await repo.insertEvent(
          operatorId: _opA,
          locationId: _locA,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userA,
        );
        expect(
          eventId,
          equals('event-id-1'),
          reason: 'control-flow / return value must be unchanged',
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into auth_events_audit'),
          ),
          hasLength(1),
          reason:
              'legacy writer always runs so the audit posture has no '
              'gap on either side of the flag',
        );
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          isEmpty,
          reason: 'flag-false must NOT fan out into audit_logs',
        );
      },
    );

    test(
      'flag=true with system event (insertSystemEvent) and operator_id '
      'set: fan-out happens because system writes still need a chain',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertSystemEvent(
          eventType: 'auth.system.event',
          operatorId: _opA,
          locationId: _locA,
          actorKind: 'service',
          actorServicePrincipalId: '99999999-9999-9999-9999-999999999999',
          adminReason: 'cutover-test',
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'flag=true with system event (insertSystemEvent) and operator_id '
      'NULL: fan-out is SKIPPED — audit_logs requires operator_id NOT '
      'NULL because the chain is scoped per (operator_id, chain_date)',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertSystemEvent(
          eventType: 'admin.cross_operator_event',
          actorKind: 'system',
          adminReason: 'cross-tenant admin path',
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          isEmpty,
          reason:
              'audit_logs.operator_id is NOT NULL; the fan-out must skip '
              'system events that have no operator scope',
        );
      },
    );

    test(
      "actorKind='system' (legacy worker / reset paths) skips the "
      'fan-out — audit_logs.actor_kind CHECK only allows '
      "('user','service'). The legacy auth_events_audit write still "
      'happens so the gateway control flow is preserved.',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        // Mirror MfaRemovalWorker / RepositoryPasswordResetRequestGateway:
        // operator-scoped row with actorKind='system' (no human / SP
        // actor). Fan-out must skip; legacy write must succeed.
        final eventId = await repo.insertSystemEvent(
          eventType: 'mfa_factor_revocation_completed',
          operatorId: _opA,
          locationId: _locA,
          actorKind: 'system',
          targetUserId: _userA,
          adminReason: 'mfa-removal-worker',
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into auth_events_audit'),
          ),
          hasLength(1),
        );
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          isEmpty,
          reason:
              "actor_kind='system' is not in audit_logs CHECK; skipping "
              'preserves the gateway control flow',
        );
      },
    );

    test(
      "actorKind='user' with no actorUserId (system-scoped reset / "
      'probe paths) skips the fan-out — audit_logs_actor_shape_check '
      'requires actor_user_id when actor_kind=user',
      () async {
        final pool = _CutoverPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final eventId = await repo.insertSystemEvent(
          eventType: 'auth.password_reset_requested',
          operatorId: _opA,
          locationId: _locA,
          actorKind: 'user',
          targetUserId: _userA,
          // actorUserId omitted intentionally — caller has no actor
          // attribution but still wants the legacy row recorded.
          adminReason: 'password-reset-request',
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          isEmpty,
          reason:
              "audit_logs_actor_shape_check requires actor_user_id "
              "when actor_kind='user' — skip rather than fail the gateway",
        );
      },
    );

    test(
      'live-wired flag — FeatureFlagsTableAuditLogsCutoverFlag reads '
      "feature_flags.enabled='false' and routes the write back to the "
      'legacy auth_events_audit-only path, proving the seeded migration '
      "row is the production rollback knob (not a constructor bool)",
      () async {
        final pool = _FeatureFlagDrivenPool(featureFlagEnabled: false);
        final repo = AuthEventsAuditRepository(
          TenantTransactionWrapper(pool),
          cutoverFlag: const FeatureFlagsTableAuditLogsCutoverFlag(),
        );
        final eventId = await repo.insertEvent(
          operatorId: _opA,
          locationId: _locA,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userA,
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('from public.feature_flags'),
          ),
          hasLength(1),
          reason:
              'production resolver must consult feature_flags every '
              'write so a DB flip rolls back without redeploying',
        );
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into auth_events_audit'),
          ),
          hasLength(1),
        );
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          isEmpty,
          reason: 'DB-driven flag=false routes back to the legacy path',
        );
      },
    );

    test(
      'live-wired flag — FeatureFlagsTableAuditLogsCutoverFlag reads '
      "feature_flags.enabled='true' and emits the audit_logs fan-out",
      () async {
        final pool = _FeatureFlagDrivenPool(featureFlagEnabled: true);
        final repo = AuthEventsAuditRepository(
          TenantTransactionWrapper(pool),
          cutoverFlag: const FeatureFlagsTableAuditLogsCutoverFlag(),
        );
        final eventId = await repo.insertEvent(
          operatorId: _opA,
          locationId: _locA,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userA,
        );
        expect(eventId, equals('event-id-1'));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'live-wired flag — missing feature_flags row defaults ON so a '
      'fresh DB without the seed migration still emits the fan-out',
      () async {
        final pool = _FeatureFlagDrivenPool(featureFlagEnabled: null);
        final repo = AuthEventsAuditRepository(
          TenantTransactionWrapper(pool),
          cutoverFlag: const FeatureFlagsTableAuditLogsCutoverFlag(),
        );
        await repo.insertEvent(
          operatorId: _opA,
          locationId: _locA,
          eventType: 'auth.user.signed_in',
          actorKind: 'user',
          actorUserId: _userA,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.where(
            (sql) => sql.contains('insert into public.audit_logs'),
          ),
          hasLength(1),
          reason:
              'default-on when row missing keeps the production posture '
              'intact during a partial migration apply',
        );
      },
    );
  });
}

class _CutoverPool implements PostgresPool {
  final List<_CutoverTransaction> transactions = <_CutoverTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _CutoverTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _FeatureFlagDrivenPool implements PostgresPool {
  _FeatureFlagDrivenPool({required this.featureFlagEnabled});

  /// `null` simulates a missing seed row.
  final bool? featureFlagEnabled;
  final List<_FeatureFlagDrivenTransaction> transactions =
      <_FeatureFlagDrivenTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FeatureFlagDrivenTransaction(
      featureFlagEnabled: featureFlagEnabled,
    );
    transactions.add(tx);
    return tx;
  }
}

class _FeatureFlagDrivenTransaction extends PostgresTransaction {
  _FeatureFlagDrivenTransaction({required this.featureFlagEnabled});

  final bool? featureFlagEnabled;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.feature_flags')) {
      if (featureFlagEnabled == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'enabled': featureFlagEnabled},
      ];
    }
    if (sql.contains('insert into auth_events_audit') &&
        sql.contains('returning event_id')) {
      return const <PostgresRow>[
        <String, Object?>{'event_id': 'event-id-1'},
      ];
    }
    if (sql.contains('insert into public.audit_logs')) {
      return const <PostgresRow>[
        <String, Object?>{'id': '1'},
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
    executedSql.add(sql);
    this.parameters.add(parameters);
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

class _CutoverTransaction extends PostgresTransaction {
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into auth_events_audit') &&
        sql.contains('returning event_id')) {
      return const <PostgresRow>[
        <String, Object?>{'event_id': 'event-id-1'},
      ];
    }
    if (sql.contains('insert into public.audit_logs')) {
      return const <PostgresRow>[
        <String, Object?>{'id': '1'},
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
    executedSql.add(sql);
    this.parameters.add(parameters);
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
