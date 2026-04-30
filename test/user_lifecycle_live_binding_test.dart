// Phase 9 live-closeout B20 tests + B21 runbook checks.
//
// Covers the new lifecycle-persistence repositories + verifies the
// GDPR runbook stays aligned with the redaction template contract.
//
// Repositories (B20):
//   * UsersRepository: status / login / soft-delete / redactPii /
//     bumpRolesVersion via withSystem audit reasons.
//   * AuthInvitesRepository: insert + accept + revoke.
//   * AuthEventsAuditRepository: insertEvent + redactForUser.
//
// Runbook (B21):
//   * runbooks/gdpr_erasure_runbook.md exists and references every
//     field in the locked redaction template.
//   * Runbook documents the paired-approval / soft-delete /
//     no-self-approval / Art. 17(3) preserved-fields rules.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/gdpr_erasure_service.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validInviteId = '44444444-4444-4444-4444-444444444444';
const String _validEventId = '55555555-5555-5555-5555-555555555555';

void main() {
  group('UsersRepository (B20 — fake Postgres)', () {
    test(
      'updateStatus uses withSystem with the supplied audit reason',
      () async {
        final pool = _LifecyclePool();
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        await repo.updateStatus(
          userId: _validUserId,
          newStatus: 'suspended',
          adminReason: 'admin.users.suspend',
        );
        final tx = pool.transactions.single;
        expect(tx.parameters[0]['value'], equals('system:admin.users.suspend'));
        expect(tx.executedSql[1], equals('set local role forge_admin'));
        expect(tx.executedSql.last, contains('update users'));
        expect(tx.executedSql.last, contains('set status = @status'));
      },
    );

    test(
      'markLoggedIn uses withTenant + bumps last_login_at + last_active_at',
      () async {
        final pool = _LifecyclePool();
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        await repo.markLoggedIn(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: _validUserId,
        );
        final tx = pool.transactions.single;
        // SET LOCAL app.operator_id ran first (tenant path).
        expect(tx.executedSql.first, contains("'app.operator_id'"));
        expect(tx.executedSql.last, contains('last_login_at = now()'));
        expect(tx.executedSql.last, contains('last_active_at = now()'));
      },
    );

    test('softDelete is idempotent (filters deleted_at is null)', () async {
      final pool = _LifecyclePool();
      final repo = UsersRepository(TenantTransactionWrapper(pool));
      await repo.softDelete(
        userId: _validUserId,
        adminReason: 'admin.users.soft_delete',
      );
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('deleted_at = now()'));
      expect(sql, contains("status = 'deleted'"));
      expect(sql, contains('deleted_at is null'));
    });

    test(
      'redactPii overwrites email + nulls profile fields per template',
      () async {
        final pool = _LifecyclePool();
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        await repo.redactPii(
          userId: _validUserId,
          adminReason: 'gdpr.erasure_executed',
        );
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('update users'));
        expect(
          sql,
          contains(
            "set email = 'redacted-' || user_id::text || '@deleted.local'",
          ),
        );
        expect(sql, contains('first_name = null'));
        expect(sql, contains('last_name = null'));
        expect(sql, contains('display_name = null'));
      },
    );

    test('bumpRolesVersion increments via SQL expression', () async {
      final pool = _LifecyclePool();
      final repo = UsersRepository(TenantTransactionWrapper(pool));
      await repo.bumpRolesVersion(
        userId: _validUserId,
        adminReason: 'admin.users.roles_changed',
      );
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('roles_version = roles_version + 1'));
    });

    test(
      'MFA recovery admin lookup trusts explicit operator_admins assignment',
      () async {
        const adminUserId = '66666666-6666-6666-6666-666666666666';
        final pool = _LifecyclePool(
          mfaRecoveryTargetRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _validUserId,
              'operator_id': _validOpId,
              'location_id': _validLocId,
              'email': 'newoundlandlimited@gmail.com',
            },
          ],
          mfaRecoveryAdminRows: <PostgresRow>[
            <String, Object?>{
              'user_id': adminUserId,
              'email': 'saidumarkhan005@gmail.com',
              'scope_type': 'super_admin',
              'is_super_admin': true,
            },
          ],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        final target = await repo.findMfaRecoveryTargetByEmail(
          email: 'newoundlandlimited@gmail.com',
          adminReason: 'mfa_recovery_request_lookup',
        );

        expect(target, isNotNull);
        expect(target!.admins, hasLength(1));
        expect(target.admins.single.email, equals('saidumarkhan005@gmail.com'));
        final adminLookupSql = pool.transactions.single.executedSql.last;
        expect(
          adminLookupSql,
          contains('join users admin on admin.user_id = oa.user_id'),
        );
        expect(
          adminLookupSql,
          isNot(contains('admin.operator_id = oa.operator_id')),
        );
      },
    );
  });

  group('AuthInvitesRepository (B20 — fake Postgres)', () {
    test(
      'insertInvite writes the bound fields + RETURNING invite_id',
      () async {
        final pool = _LifecyclePool(returningInviteId: _validInviteId);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));
        final id = await repo.insertInvite(
          operatorId: _validOpId,
          locationId: _validLocId,
          email: 'new@example.test',
          roleId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          scopeType: 'operator_wide',
          invitedByUserId: _validUserId,
          expiresAt: DateTime.utc(2026, 5, 4, 12),
          tokenHash: 'hash-abc',
        );
        expect(id, equals(_validInviteId));
        final tx = pool.transactions.single;
        final params = tx.parameters.last;
        expect(params['email'], equals('new@example.test'));
        expect(params['scope_type'], equals('operator_wide'));
        expect(params['token_hash'], equals('hash-abc'));
      },
    );

    test('markAccepted filters by accepted_at is null + revoked_at is null + '
        'expires_at > now()', () async {
      final pool = _LifecyclePool(returningInviteId: _validInviteId);
      final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));
      await repo.markAccepted(
        operatorId: _validOpId,
        locationId: _validLocId,
        inviteId: _validInviteId,
        acceptingUserId: _validUserId,
      );
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains('set accepted_at = now()'));
      expect(sql, contains('accepted_at is null'));
      expect(sql, contains('revoked_at is null'));
      expect(sql, contains('expires_at > now()'));
    });

    test(
      'revokeInvite is idempotent (skips already-revoked / accepted)',
      () async {
        final pool = _LifecyclePool(returningInviteId: _validInviteId);
        final repo = AuthInvitesRepository(TenantTransactionWrapper(pool));
        await repo.revokeInvite(
          operatorId: _validOpId,
          locationId: _validLocId,
          inviteId: _validInviteId,
          actorUserId: _validUserId,
        );
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('set revoked_at = now()'));
        expect(sql, contains('accepted_at is null'));
        expect(sql, contains('revoked_at is null'));
      },
    );
  });

  group('AuthEventsAuditRepository (B20 — fake Postgres)', () {
    test('insertEvent writes the bound payload + RETURNING event_id', () async {
      final pool = _LifecyclePool(returningEventId: _validEventId);
      final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
      final id = await repo.insertEvent(
        operatorId: _validOpId,
        locationId: _validLocId,
        eventType: 'auth.login_succeeded',
        actorUserId: _validUserId,
        targetUserId: _validUserId,
        payload: const <String, Object?>{'method': 'email_password'},
        ip: '1.2.3.4',
        userAgent: 'test-ua',
      );
      expect(id, equals(_validEventId));
      final tx = pool.transactions.single;
      final params = tx.parameters.last;
      expect(params['event_type'], equals('auth.login_succeeded'));
      expect(params['ip'], equals('1.2.3.4'));
      expect(params['payload'], equals('{"method":"email_password"}'));
    });

    test('redactForUser FAILS CLOSED with a runbook pointer — append-only '
        'audit posture stays intact at runtime '
        '(audit-fix 2026-04-27)', () async {
      final pool = _LifecyclePool(returningEventId: _validEventId);
      final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.redactForUser(
          userId: _validUserId,
          adminReason: 'gdpr.erasure_executed',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('append-only'),
              contains('runbooks/gdpr_erasure_runbook.md'),
            ),
          ),
        ),
      );
      // Acceptance: NO transaction was opened — the throw happens
      // synchronously before any SQL runs, so the proxy cannot
      // accidentally hold an open Postgres transaction.
      expect(pool.transactions, isEmpty);
    });

    test('breakGlassRedactionSql exposes the exact SQL the DBA runs so '
        'the runbook + code stay byte-identical', () {
      // Single-source-of-truth check: the runbook test below asserts
      // the runbook quotes this exact statement.
      expect(
        AuthEventsAuditRepository.breakGlassRedactionSql,
        contains('update auth_events_audit'),
      );
      expect(
        AuthEventsAuditRepository.breakGlassRedactionSql,
        contains('ip = null, user_agent = null'),
      );
      expect(
        AuthEventsAuditRepository.breakGlassRedactionSql,
        contains("'email'"),
      );
      expect(
        AuthEventsAuditRepository.breakGlassRedactionSql,
        contains('target_user_id = @user_id::uuid'),
      );
    });
  });

  group('GDPR runbook (B21)', () {
    final runbook = File('runbooks/gdpr_erasure_runbook.md');

    setUpAll(() {
      expect(
        runbook.existsSync(),
        isTrue,
        reason: 'GDPR erasure runbook must exist alongside the framework code',
      );
    });

    String runbookText() => runbook.readAsStringSync();

    test('references every field in the redaction template', () {
      final body = runbookText();
      final template = ErasureRedactionTemplate.payloadFor(
        userId: _validUserId,
        runbookVersion: '1.0',
      );
      // Every redaction key in the template must appear by name in
      // the runbook (the executor can match the SQL queries to the
      // table.column targets).
      final redactions = template['redactions'] as Map<String, Object?>;
      for (final key in redactions.keys) {
        // Skip directive sentinels that aren't actual table.column.
        if (key.endsWith('_retain') || key.endsWith('.cleared')) continue;
        expect(
          body,
          contains(key),
          reason: 'runbook must mention $key from the redaction template',
        );
      }
    });

    test(
      'documents paired-approval + soft-delete + no-self-approval rules',
      () {
        final body = runbookText();
        expect(body, contains('paired-approval'));
        expect(body, contains('no-self-approval'));
        expect(body, contains('soft-delete'));
        expect(body, contains('super_admin'));
      },
    );

    test('documents Art. 17(3) preserved fields by name', () {
      final body = runbookText();
      expect(body, contains('Art. 17(3)'));
      expect(body, contains('event_id'));
      expect(body, contains('actor_user_id'));
      expect(body, contains('event_type'));
      expect(body, contains('occurred_at'));
    });

    test('documents that erasure is irreversible', () {
      final body = runbookText();
      expect(body.toLowerCase(), contains('irreversible'));
    });

    test('documents the audit-log break-glass DBA path with the exact SQL '
        'the runtime exposes via breakGlassRedactionSql '
        '(audit-fix 2026-04-27)', () {
      final body = runbookText();
      // Header section + posture explanation present.
      expect(body, contains('Break-glass: redacting audit log fields'));
      expect(body, contains('append-only at the grant shape'));
      // GRANT/REVOKE wrapper present so DBA cannot accidentally
      // leave broader UPDATE in place.
      expect(
        body,
        contains('grant update on public.auth_events_audit to forge_admin'),
      );
      expect(
        body,
        contains('revoke update on public.auth_events_audit from forge_admin'),
      );
      // Core redaction SQL fragments appear verbatim in the runbook
      // so the DBA copy-paste matches what the code constant
      // documents. The runbook uses '<user_id>'::uuid for the DBA's
      // literal substitution, while the code constant uses
      // @user_id::uuid for Postgres parameter binding — the SET
      // clauses are byte-identical between the two.
      const sharedFragments = <String>[
        'update auth_events_audit',
        'set ip = null, user_agent = null',
        "event_payload - 'email' - 'first_name'",
        "- 'last_name' - 'display_name' - 'avatar_url'",
      ];
      for (final fragment in sharedFragments) {
        expect(
          body,
          contains(fragment),
          reason:
              'runbook break-glass section must contain SQL fragment '
              '"$fragment" so code + runbook stay byte-identical',
        );
        // Same fragment must appear in the code constant, proving
        // the runbook is not lying about what the runtime exports.
        expect(
          AuthEventsAuditRepository.breakGlassRedactionSql,
          contains(fragment),
          reason:
              'breakGlassRedactionSql must contain "$fragment" so the '
              'runbook + code stay byte-identical',
        );
      }
      // Break-glass run records itself via an INSERT-only audit row
      // so the redaction event itself is auditable.
      expect(body, contains('gdpr.audit_log_redacted_break_glass'));
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

class _LifecyclePool implements PostgresPool {
  _LifecyclePool({
    this.returningInviteId,
    this.returningEventId,
    this.mfaRecoveryTargetRows = const <PostgresRow>[],
    this.mfaRecoveryAdminRows = const <PostgresRow>[],
  });

  final String? returningInviteId;
  final String? returningEventId;
  final List<PostgresRow> mfaRecoveryTargetRows;
  final List<PostgresRow> mfaRecoveryAdminRows;

  final List<_LifecycleTransaction> transactions = <_LifecycleTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _LifecycleTransaction(
      returningInviteId: returningInviteId,
      returningEventId: returningEventId,
      mfaRecoveryTargetRows: mfaRecoveryTargetRows,
      mfaRecoveryAdminRows: mfaRecoveryAdminRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _LifecycleTransaction extends PostgresTransaction {
  _LifecycleTransaction({
    required this.returningInviteId,
    required this.returningEventId,
    required this.mfaRecoveryTargetRows,
    required this.mfaRecoveryAdminRows,
  });

  final String? returningInviteId;
  final String? returningEventId;
  final List<PostgresRow> mfaRecoveryTargetRows;
  final List<PostgresRow> mfaRecoveryAdminRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into auth_invites') &&
        sql.contains('returning invite_id')) {
      final id = returningInviteId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'invite_id': id},
      ];
    }
    if (sql.contains('insert into auth_events_audit') &&
        sql.contains('returning event_id')) {
      final id = returningEventId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'event_id': id},
      ];
    }
    if (sql.contains('from users u') &&
        sql.contains('where lower(u.email) = lower(@email)')) {
      return mfaRecoveryTargetRows;
    }
    if (sql.contains('from operator_admins oa')) {
      return mfaRecoveryAdminRows;
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
