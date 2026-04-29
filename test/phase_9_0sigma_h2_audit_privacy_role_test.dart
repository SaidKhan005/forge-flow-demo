// Phase 9.0Σ.h2 — advisor-conversation audit-privacy permission gate
// (parcel B46 in `phase_9_execution_backlog.md`, extends item 5 of
// `phase_9_scalability_decisions_2026-04-27.md`).
//
// This slice closes the missing app-layer half of the audit-privacy
// gate that 9.0Σ.h opened at the database layer. Six groups of tests:
//
//   1. h2 migration shape
//      ─ additive-only seed of `admin.audit_privacy.read`, MFA-required,
//        idempotent (`on conflict do nothing`), default-grant only to
//        `super_admin` and `ff_support`, and the `audit_privacy` ←
//        `service_role` role-membership grant guarded by a
//        `pg_auth_members` lookup so re-runs are no-ops.
//
//   2. PermissionKeys catalog sync
//      ─ the new constant lives under `admin.*`, is part of
//        `PermissionKeys.all`, and is part of `PermissionKeys.requiresMfa`.
//        The total count moves from 93 (9.0a) to 94 (9.0a + h2).
//
//   3. Catalog contract doc sync
//      ─ the row appears in `docs/contracts/auth_permission_key_catalog.md`
//        under the `admin.*` section with MFA = yes, and the count moves
//        from 25 to 26 admin keys.
//
//   4. Repository SQL ordering + forensic SELECT shape
//      ─ AdvisorConversationLogRepository.auditReadConversation runs
//        SET LOCAL ROLE audit_privacy → SELECT (forensic column list
//        including content_encrypted / content_iv / content_key_ref /
//        content_hash) → RESET ROLE → INSERT INTO audit_logs, in that
//        order, in the same transaction. The forensic surface is the
//        whole point of the role assumption — the runtime
//        service_role connection has no GRANT to those columns.
//
//   5. Fail-closed permission validation
//      ─ A caller without `admin.audit_privacy.read` is rejected
//        BEFORE the tenant transaction opens. A blank reason is also
//        rejected before the transaction.
//
//   6. Audit row payload + value-object disclosure surface
//      ─ The paired audit_logs row carries action,
//        target_kind = 'advisor_conversation_log', target_id =
//        conversationId, payload.reason, payload.records_read_count.
//        AuditPrivacyConversationRow exposes the encrypted bytes /
//        IV / key reference / hash via explicit named accessors a
//        forensic decrypt pipeline reads; its `toString()`
//        deliberately omits all of them so accidental log-line
//        interpolation cannot leak the secret-shaped fields.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validReaderId = '33333333-3333-3333-3333-333333333333';
const String _validConvId = '44444444-4444-4444-4444-444444444444';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202604280014_phase_9_0sigma_h2_audit_privacy_role.sql',
  );
  final foundationSql = _readSqlNormalized(
    'db/migrations/202604250008_auth_schema_foundation.sql',
  );
  final hMigrationSql = _readSqlNormalized(
    'db/migrations/'
    '202604280007_phase_9_0sigma_h_advisor_conversation_log.sql',
  );
  final catalogContract = File(
    'docs/contracts/auth_permission_key_catalog.md',
  ).readAsStringSync();
  final advisorContract = File(
    'docs/contracts/advisor_conversation_log_contract.md',
  ).readAsStringSync();

  group('Phase 9.0Σ.h2 migration shape', () {
    test('runs in a single transaction (begin/commit pair)', () {
      expect(migrationSql, contains('begin;'));
      expect(migrationSql, contains('commit;'));
    });

    test('does not duplicate or rewrite the h migration content', () {
      // The h2 migration is additive only. It must not redeclare the
      // table, the audit_privacy role, the column-level GRANTs, the
      // RLS policies, or any other 9.0Σ.h surface. Listing each
      // forbidden statement individually so a future rewrite cannot
      // sneak in a duplicate that the partial-merge might not catch.
      const forbiddenFragments = <String>[
        'create table if not exists public.advisor_conversation_log',
        'partition by range (created_at)',
        'create role audit_privacy nologin',
        'create policy "advisor_conversation_log_per_tenant_select"',
        'create policy "advisor_conversation_log_per_tenant_insert"',
        'create policy "advisor_conversation_log_audit_privacy_select"',
        'grant select on public.advisor_conversation_log to audit_privacy',
      ];
      for (final fragment in forbiddenFragments) {
        expect(
          migrationSql,
          isNot(contains(fragment)),
          reason:
              'h2 must remain additive — fragment must live only in '
              'the h migration: $fragment',
        );
      }
    });

    test('seeds admin.audit_privacy.read with category=admin, '
        'requires_mfa=true, frozen=true, idempotent', () {
      expect(migrationSql, contains('insert into public.permission_keys'));
      // Tail of the values tuple: (..., requires_mfa, frozen).
      // requires_mfa = true and frozen = true.
      final pattern = RegExp(
        r"'admin\.audit_privacy\.read',\s*\n?\s*'admin'[\s\S]*?true,\s*\n?\s*true",
      );
      expect(
        pattern.hasMatch(migrationSql),
        isTrue,
        reason:
            'admin.audit_privacy.read must seed with category=admin, '
            'requires_mfa=true, frozen=true',
      );
      expect(migrationSql, contains('on conflict (key) do nothing'));
    });

    test('default grants the new key only to super_admin and ff_support', () {
      // The grant block uses an `IN ('super_admin', 'ff_support')`
      // filter, not a category-wide cross-join, so operator-tier
      // roles do not silently inherit the key.
      expect(migrationSql, contains("'admin.audit_privacy.read'"));
      expect(
        migrationSql,
        contains("r.role_key in ('super_admin', 'ff_support')"),
      );
      expect(
        migrationSql,
        contains('on conflict (role_id, permission_key) do nothing'),
      );
    });

    test('does NOT grant the new key to the four operator-tier roles '
        'by default (parse the audit_privacy.read grant block)', () {
      // Parse the migration body into the block(s) of SQL that
      // actually grant `admin.audit_privacy.read`, then assert no
      // operator-tier role key appears anywhere in those blocks.
      // This catches:
      //   - reordered IN tuples,
      //   - multi-line / continuation IN lists,
      //   - separate INSERT blocks per role,
      //   - OR-joined role filters,
      //   - any other shape that grants the key to an operator role.
      const operatorTierRoles = <String>[
        'operator_owner',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ];
      final grantBlocks = _extractAuditPrivacyReadGrantBlocks(migrationSql);
      expect(
        grantBlocks,
        isNotEmpty,
        reason:
            'h2 migration must contain at least one INSERT INTO '
            'public.role_permissions block that grants '
            'admin.audit_privacy.read',
      );
      for (final block in grantBlocks) {
        for (final roleKey in operatorTierRoles) {
          expect(
            block,
            isNot(contains("'$roleKey'")),
            reason:
                'admin.audit_privacy.read grant block names the '
                'operator-tier role $roleKey — raw advisor content '
                'is F&F-internal at launch and must not be '
                'default-granted to operator roles. Block:\n$block',
          );
        }
      }
    });

    test('grants audit_privacy role membership to service_role with '
        'pg_auth_members idempotency guard', () {
      // The grant is wrapped in a do $$ ... $$ block that checks
      // pg_auth_members so re-runs are no-ops (PG raises an error
      // on duplicate role-membership grant otherwise).
      expect(migrationSql, contains('pg_catalog.pg_auth_members'));
      expect(migrationSql, contains("rolname = 'audit_privacy'"));
      expect(migrationSql, contains("rolname = 'service_role'"));
      expect(migrationSql, contains('grant audit_privacy to service_role'));
    });

    test('does not introduce timestamp without time zone (storage rule)', () {
      final lower = migrationSql.toLowerCase();
      expect(lower, isNot(contains('timestamp without time zone')));
      expect(lower, isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)(?!tz)'))));
    });

    test('does not introduce live database calls / provider URLs', () {
      final lower = migrationSql.toLowerCase();
      expect(lower, isNot(contains('http://')));
      expect(lower, isNot(contains('https://')));
      expect(lower, isNot(contains('pgmq')));
    });
  });

  group('Phase 9.0Σ.h2 PermissionKeys catalog sync', () {
    test('PermissionKeys.adminAuditPrivacyRead is the new constant', () {
      expect(
        PermissionKeys.adminAuditPrivacyRead,
        equals('admin.audit_privacy.read'),
      );
    });

    test('PermissionKeys.all contains admin.audit_privacy.read', () {
      expect(PermissionKeys.all, contains('admin.audit_privacy.read'));
    });

    test('PermissionKeys.requiresMfa contains admin.audit_privacy.read '
        '(MFA-required gate)', () {
      expect(PermissionKeys.requiresMfa, contains('admin.audit_privacy.read'));
    });

    test('PermissionKeys.all has 95 entries (81 baseline + 12 team.* + '
        '2 later admin keys)', () {
      expect(PermissionKeys.all.length, equals(95));
    });

    test('the new key is NOT in the 9.0 foundation seed (it lives in '
        'the h2 migration alone)', () {
      // Sanity: the h2 migration is the source of truth for this key.
      // A future edit that re-seeds the key in the foundation
      // migration would be redundant and confusing — keep them split.
      expect(foundationSql, isNot(contains("'admin.audit_privacy.read'")));
      expect(migrationSql, contains("'admin.audit_privacy.read'"));
    });
  });

  group('Phase 9.0Σ.h2 catalog contract doc sync', () {
    test('admin section is now (27) — 25 original + 2 later admin keys', () {
      expect(catalogContract, contains('### `admin.*` (27)'));
    });

    test('admin.audit_privacy.read row is documented with MFA = yes', () {
      // The catalog doc is a markdown table; the row format is
      // `| <key> | <description> | yes |`.
      expect(catalogContract, contains('`admin.audit_privacy.read`'));
      // The MFA column must read "yes" for this key. Match
      // permissively across whitespace so a future format tweak
      // (extra spaces, etc.) still passes.
      expect(
        catalogContract,
        matches(
          RegExp(r'`admin\.audit_privacy\.read`[^|]*\|[^|]*\|\s*yes\s*\|'),
        ),
        reason: 'catalog doc must mark admin.audit_privacy.read as MFA = yes',
      );
    });
  });

  group('Phase 9.0Σ.h2 advisor_conversation_log contract doc', () {
    test('contract names the CMK reference / encryption posture', () {
      expect(advisorContract, contains('content_encrypted'));
      expect(advisorContract, contains('content_iv'));
      expect(advisorContract, contains('content_key_ref'));
      // CMK pairing with cutover.0a is the at-rest encryption story.
      expect(advisorContract.toLowerCase(), contains('cmk'));
      expect(advisorContract, contains('cutover.0a'));
    });

    test('contract names the audit-privacy permission gate + paired '
        'audit row + records-read count', () {
      expect(advisorContract, contains('admin.audit_privacy.read'));
      expect(
        advisorContract,
        contains('advisor_conversation_log.audit_privacy_read'),
      );
      expect(advisorContract, contains('records_read_count'));
      expect(advisorContract, contains('reason'));
      // The contract must call out the F&F-internal-by-default
      // policy for raw conversation reads.
      expect(advisorContract, contains('operator_owner'));
      expect(advisorContract, contains('F&F-internal'));
    });

    test('contract documents retention / legal-hold / redaction ledger '
        'rules', () {
      expect(advisorContract, contains('retention_class'));
      expect(advisorContract, contains('legal_hold'));
      expect(advisorContract, contains('Redaction ledger'));
      expect(advisorContract, contains('paired-super-admin'));
      // The retention purge function name must match what the h
      // migration declares (single-source-of-truth between the
      // contract and the migration).
      expect(advisorContract, contains('advisor_conversation_log_purge'));
      // Sanity: the same function name is in the h migration the
      // contract references.
      expect(hMigrationSql, contains('advisor_conversation_log_purge'));
    });
  });

  group('AdvisorConversationLogRepository.auditReadConversation '
      '(B46 — fake Postgres)', () {
    test('runs SET LOCAL ROLE → SELECT (forensic columns) → RESET '
        'ROLE → INSERT audit_logs in that order, in one transaction', () async {
      final pool = _AuditReadPool(
        rows: <PostgresRow>[_fakeForensicRow(turnIndex: 0)],
      );
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      final auth = AuditPrivacyAuthorization(
        permissions: <String>{'admin.audit_privacy.read'},
      );

      final results = await repo.auditReadConversation(
        authorization: auth,
        operatorId: _validOpId,
        locationId: _validLocId,
        readerUserId: _validReaderId,
        conversationId: _validConvId,
        reason: 'incident #42 forensic review',
      );

      expect(results, hasLength(1));
      expect(results.single.conversationId, equals(_validConvId));
      expect(results.single.role, equals('user'));

      // Single transaction.
      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      expect(tx.commitCount, equals(1));
      expect(tx.rollbackCount, equals(0));

      // Order check: drop the SET LOCAL set_config preamble (operator,
      // location, user_id, bypass_rls_audit) and inspect the
      // audit-read sequence.
      final auditOrder = tx.executedSql
          .where((sql) => !sql.contains("set_config('app."))
          .toList();
      expect(auditOrder.length, greaterThanOrEqualTo(4));
      // 1. SET LOCAL ROLE audit_privacy.
      expect(auditOrder[0], equals('set local role audit_privacy'));
      // 2. SELECT under the audit_privacy role — column list
      //    includes the encrypted payload (asserted in detail in
      //    the forensic-columns test below).
      expect(auditOrder[1], contains('select id::text'));
      expect(auditOrder[1], contains('from advisor_conversation_log'));
      expect(auditOrder[1], contains('order by turn_index'));
      // 3. RESET ROLE.
      expect(auditOrder[2], equals('reset role'));
      // 4. INSERT into audit_logs.
      expect(auditOrder[3], contains('insert into audit_logs'));
    });

    test('SELECT column list INCLUDES the encrypted payload columns '
        '(forensic decrypt path) plus metadata', () async {
      // The audit-privacy role assumption exists specifically to
      // authorize SELECTs on `content_encrypted`, `content_iv`, and
      // `content_key_ref` — those are the columns the column-level
      // GRANT in the h migration omits from `service_role`'s
      // allowlist. A SELECT that did NOT touch them would render the
      // role flip theatrical. The forensic surface returns these
      // bytes alongside the metadata so a forensic investigator can
      // drive CMK lookup → AEAD decrypt; the value object's
      // `toString()` keeps them off accidental log lines (asserted
      // separately below).
      final pool = _AuditReadPool(rows: <PostgresRow>[]);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      final auth = AuditPrivacyAuthorization(
        permissions: <String>{'admin.audit_privacy.read'},
      );

      await repo.auditReadConversation(
        authorization: auth,
        operatorId: _validOpId,
        locationId: _validLocId,
        readerUserId: _validReaderId,
        conversationId: _validConvId,
        reason: 'incident #42',
      );

      final selectSql = pool.transactions.single.executedSql.firstWhere(
        (sql) => sql.contains('from advisor_conversation_log'),
      );
      // Required encrypted-payload columns ARE present — the role
      // assumption exists to authorize them.
      expect(selectSql, contains('content_encrypted'));
      expect(selectSql, contains('content_iv'));
      expect(selectSql, contains('content_key_ref'));
      expect(selectSql, contains('content_hash'));
      // Required metadata columns ARE present.
      expect(selectSql, contains('turn_index'));
      expect(selectSql, contains('role'));
      expect(selectSql, contains('surface'));
      expect(selectSql, contains('legal_hold'));
      expect(selectSql, contains('retention_class'));
    });

    test('writes paired audit_logs row with reader, reason, target, '
        'records_read_count', () async {
      final pool = _AuditReadPool(
        rows: <PostgresRow>[
          _fakeForensicRow(turnIndex: 0, role: 'user'),
          _fakeForensicRow(
            turnIndex: 1,
            role: 'assistant',
            id: '00000000-0000-0000-0000-0000000000bb',
            createdAt: DateTime.utc(2026, 4, 28, 12, 0, 5),
          ),
        ],
      );
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.auditReadConversation(
        authorization: AuditPrivacyAuthorization(
          permissions: <String>{'admin.audit_privacy.read'},
        ),
        operatorId: _validOpId,
        locationId: _validLocId,
        readerUserId: _validReaderId,
        conversationId: _validConvId,
        reason: '  incident #42 forensic review  ',
      );

      final tx = pool.transactions.single;
      // Find the audit_logs INSERT.
      final auditIdx = tx.executedSql.indexWhere(
        (sql) => sql.contains('insert into audit_logs'),
      );
      expect(auditIdx, greaterThan(-1));
      final params = tx.parameters[auditIdx];
      expect(params['operator_id'], equals(_validOpId));
      expect(params['location_id'], equals(_validLocId));
      expect(params['actor_user_id'], equals(_validReaderId));
      expect(params['target_id'], equals(_validConvId));
      expect(
        params['action'],
        equals('advisor_conversation_log.audit_privacy_read'),
      );
      // The SQL hard-codes the action key, target_kind, actor_kind so
      // no producer can override them.
      final auditSql = tx.executedSql[auditIdx];
      expect(auditSql, contains("'advisor_conversation_log'"));
      expect(auditSql, contains("'user'"));
      // Payload is a jsonb-encoded object with reason + records-read.
      // The reason is trimmed (whitespace stripped) before serialization.
      final payloadJson =
          jsonDecode(params['payload'] as String) as Map<String, Object?>;
      expect(payloadJson['reason'], equals('incident #42 forensic review'));
      expect(payloadJson['records_read_count'], equals(2));
    });

    test('rejects a caller without admin.audit_privacy.read BEFORE the '
        'tenant transaction opens (fail-closed)', () async {
      final pool = _AuditReadPool(rows: <PostgresRow>[]);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      Object? thrown;
      try {
        await repo.auditReadConversation(
          authorization: AuditPrivacyAuthorization(
            // Permissions that look adjacent but are NOT the right
            // key — proves the contains-check is exact.
            permissions: <String>{'admin.audit_log.view', 'admin.users.view'},
          ),
          operatorId: _validOpId,
          locationId: _validLocId,
          readerUserId: _validReaderId,
          conversationId: _validConvId,
          reason: 'incident #42',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<AuditPrivacyPermissionDenied>());
      // No transaction was opened — the wrapper never saw the call.
      expect(pool.transactions, isEmpty);
    });

    test(
      'rejects a blank reason BEFORE the tenant transaction opens',
      () async {
        final pool = _AuditReadPool(rows: <PostgresRow>[]);
        final repo = AdvisorConversationLogRepository(
          TenantTransactionWrapper(pool),
        );
        ArgumentError? thrown;
        try {
          await repo.auditReadConversation(
            authorization: AuditPrivacyAuthorization(
              permissions: <String>{'admin.audit_privacy.read'},
            ),
            operatorId: _validOpId,
            locationId: _validLocId,
            readerUserId: _validReaderId,
            conversationId: _validConvId,
            reason: '   ',
          );
        } on ArgumentError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ArgumentError>());
        expect(thrown!.name, equals('reason'));
        // No transaction was opened.
        expect(pool.transactions, isEmpty);
      },
    );

    test('rolls back the transaction (and never writes audit row) when '
        'the SELECT fails — RESET ROLE still runs', () async {
      final pool = _AuditReadPool.failingSelect();
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      Object? thrown;
      try {
        await repo.auditReadConversation(
          authorization: AuditPrivacyAuthorization(
            permissions: <String>{'admin.audit_privacy.read'},
          ),
          operatorId: _validOpId,
          locationId: _validLocId,
          readerUserId: _validReaderId,
          conversationId: _validConvId,
          reason: 'incident #42',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      final tx = pool.transactions.single;
      // Rollback path runs (commit did NOT).
      expect(tx.commitCount, equals(0));
      expect(tx.rollbackCount, equals(1));
      // RESET ROLE still ran (in `finally` after the SELECT throws).
      expect(tx.executedSql.where((sql) => sql == 'reset role'), hasLength(1));
      // No audit_logs INSERT (the SELECT failed before reaching it).
      expect(
        tx.executedSql.where((sql) => sql.contains('insert into audit_logs')),
        isEmpty,
      );
    });

    test('value object exposes the encrypted payload via named '
        'accessors but `toString()` never leaks ciphertext / IV / '
        'key reference / hash content', () async {
      final pool = _AuditReadPool(rows: <PostgresRow>[]);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      // Permission-denied error message stays metadata-only.
      const permissionError = AuditPrivacyPermissionDenied();
      final permissionMessage = permissionError.toString();
      expect(permissionMessage, contains('admin.audit_privacy.read'));
      expect(permissionMessage, isNot(contains('kv://secret')));
      // The forensic value object: payload IS reachable through
      // explicit named accessors (the forensic decrypt pipeline
      // reads them) but `toString()` deliberately omits them.
      const secretKeyRef = 'kv://secret-do-not-leak/v9';
      const secretHash =
          'deadbeef00000000000000000000000000000000000000000000000000000000';
      final row = AuditPrivacyConversationRow(
        id: '00000000-0000-0000-0000-0000000000aa',
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validReaderId,
        conversationId: _validConvId,
        turnIndex: 0,
        role: 'user',
        contentEncrypted: <int>[0xDE, 0xAD, 0xBE, 0xEF],
        contentIv: <int>[0xCA, 0xFE],
        contentKeyRef: secretKeyRef,
        contentHash: secretHash,
        surface: 'advisor.phone',
        queryClass: 'sql',
        usageClass: 'advisor.turn',
        provider: 'anthropic',
        modelId: 'claude-sonnet-4-6',
        modelVersion: '20260101',
        promptTokenCount: 1024,
        completionTokenCount: 256,
        costUsd: 0.0125,
        latencyMs: 850,
        legalHold: false,
        retentionClass: 'standard',
        createdAt: DateTime.utc(2026, 4, 28, 12, 0, 0),
      );
      // Forensic read path WORKS — accessors return the bytes a
      // CMK-driven decrypt pipeline needs.
      expect(row.contentEncrypted, equals(<int>[0xDE, 0xAD, 0xBE, 0xEF]));
      expect(row.contentIv, equals(<int>[0xCA, 0xFE]));
      expect(row.contentKeyRef, equals(secretKeyRef));
      expect(row.contentHash, equals(secretHash));
      // The accessor-returned lists are unmodifiable so a downstream
      // consumer cannot mutate the underlying buffer.
      expect(() => row.contentEncrypted.add(0xFF), throwsUnsupportedError);
      expect(() => row.contentIv.add(0xFF), throwsUnsupportedError);
      // toString deliberately surfaces metadata only — no ciphertext
      // / IV / key reference / hash content leaks through accidental
      // log-line interpolation.
      final asString = row.toString();
      expect(asString, contains('AuditPrivacyConversationRow'));
      expect(asString, contains('conversationId'));
      expect(asString, isNot(contains(secretKeyRef)));
      expect(asString, isNot(contains(secretHash)));
      expect(asString, isNot(contains('kv://')));
      expect(asString, isNot(contains('DEAD')));
      expect(asString, isNot(contains('CAFE')));
      expect(asString, isNot(contains('content_encrypted')));
      expect(asString, isNot(contains('content_iv')));
      expect(asString, isNot(contains('contentEncrypted')));
      expect(asString, isNot(contains('contentIv')));
      expect(asString, isNot(contains('contentKeyRef')));
      expect(asString, isNot(contains('contentHash')));
      // Repository toString — no fields hold any of the above.
      final repoString = repo.toString();
      expect(repoString, isNot(contains('kv://')));
      expect(repoString, isNot(contains('DEAD')));
      expect(repoString, isNot(contains('CAFE')));
    });
  });

  group('AdvisorConversationLogRepository.auditPrivacyReadAction '
      '(constant pinned to contract / runbook)', () {
    test('matches the action key the contract documents', () {
      expect(
        AdvisorConversationLogRepository.auditPrivacyReadAction,
        equals('advisor_conversation_log.audit_privacy_read'),
      );
      expect(
        advisorContract,
        contains(AdvisorConversationLogRepository.auditPrivacyReadAction),
      );
    });
  });
}

/// Reads [path] and collapses CRLF → LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

/// Builds a synthetic `_AuditReadPool` SELECT-result row with all the
/// columns the audit-read forensic SELECT projects. Defaults give a
/// turn-0 user row at the canonical fixtures (operator/location/user/
/// conversation IDs); callers override per-test fields like
/// `turnIndex`, `role`, `id`, and `createdAt`. The encrypted-payload
/// columns are non-empty so the fake exercises the value object's
/// secret-shaped fields the same way a live SELECT would.
PostgresRow _fakeForensicRow({
  required int turnIndex,
  String role = 'user',
  String id = '00000000-0000-0000-0000-0000000000aa',
  DateTime? createdAt,
}) {
  return <String, Object?>{
    'id': id,
    'operator_id': _validOpId,
    'location_id': _validLocId,
    'user_id': _validReaderId,
    'conversation_id': _validConvId,
    'turn_index': turnIndex,
    'role': role,
    'content_encrypted': <int>[0x01, 0x02, 0x03, 0x04],
    'content_iv': <int>[0x10, 0x11, 0x12, 0x13],
    'content_key_ref': 'kv://forge-flow/cmk/v1',
    'content_hash':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'surface': 'advisor.phone',
    'query_class': 'sql',
    'usage_class': 'advisor.turn',
    'provider': 'anthropic',
    'model_id': 'claude-sonnet-4-6',
    'model_version': '20260101',
    'prompt_token_count': 1024,
    'completion_token_count': 256,
    'cost_usd': 0.0125,
    'latency_ms': 850,
    'legal_hold': false,
    'retention_class': 'standard',
    'created_at': createdAt ?? DateTime.utc(2026, 4, 28, 12, 0, 0),
  };
}

/// Returns each `INSERT INTO public.role_permissions` block in
/// [migrationSql] that grants `'admin.audit_privacy.read'`. A "block"
/// is the run of SQL from the opening `insert into` through the
/// terminating `;` (inclusive) — the trailing `on conflict do nothing`
/// clause and the surrounding role-key filter ride along with the
/// block, so a downstream test can assert "no operator-tier role key
/// appears anywhere in this block".
///
/// The matcher ignores leading whitespace + comments to the next
/// `insert into` so multi-block grant migrations parse cleanly. It
/// returns an empty list if there is no audit_privacy.read grant —
/// the caller's `expect(..., isNotEmpty)` catches that case.
List<String> _extractAuditPrivacyReadGrantBlocks(String migrationSql) {
  final blocks = <String>[];
  final insertPattern = RegExp(
    r'insert\s+into\s+public\.role_permissions\b[\s\S]*?;\s*\n',
    caseSensitive: false,
  );
  for (final match in insertPattern.allMatches(migrationSql)) {
    final block = match.group(0)!;
    if (block.contains("'admin.audit_privacy.read'")) {
      blocks.add(block);
    }
  }
  return blocks;
}

/// Recording fake `PostgresPool` for the audit-read path. Mirrors the
/// `_AdvisorPool` in `phase_9_0sigma_h_advisor_conversation_log_test.dart`
/// but returns an arbitrary [rows] payload from the SELECT step so the
/// audit-read test can assert what the forensic value object looks
/// like (encrypted payload included; surfaces accessible via named
/// accessors but elided from `toString()`).
class _AuditReadPool implements PostgresPool {
  _AuditReadPool({this.rows = const <PostgresRow>[]}) : _selectFails = false;

  _AuditReadPool.failingSelect()
    : rows = const <PostgresRow>[],
      _selectFails = true;

  final List<PostgresRow> rows;
  final bool _selectFails;

  final List<_AuditReadTransaction> transactions = <_AuditReadTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AuditReadTransaction(rows: rows, selectFails: _selectFails);
    transactions.add(tx);
    return tx;
  }
}

class _AuditReadTransaction extends PostgresTransaction {
  _AuditReadTransaction({required this.rows, required this.selectFails});

  final List<PostgresRow> rows;
  final bool selectFails;
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
    if (sql.contains('from advisor_conversation_log')) {
      if (selectFails) {
        throw StateError('simulated SELECT failure');
      }
      return rows;
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
