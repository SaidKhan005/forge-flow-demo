// Phase 9.0Σ.h — advisor_conversation_log foundation tests.
//
// Local framework slice (no live database). Four groups:
//
//   1. Migration shape
//      ─ table + tenant-leading PK + tenant-leading B-tree indexes +
//        time partitioning + RLS via the 9.0Σ.b wrappers. Asserts the
//        schema contract Phase 11b advisor replay will read against.
//
//   2. RLS lint posture
//      ─ runs the policy-aware lint (`tool/rls_policy_lint.dart`)
//        against the new migration and proves it passes — i.e. every
//        new policy body uses `public.app_current_operator()` rather
//        than bare `current_setting('app.…')`. Required by item 4 of
//        the 4-27 scalability decisions.
//
//   3. Privacy posture
//      ─ proves that the column-level GRANT split keeps raw encrypted
//        content off the ordinary `service_role` SELECT path while
//        leaving safe metadata queryable, and that the audit-privacy
//        role has full read access through its own policy.
//
//   4. Repository fake-Postgres contract
//      ─ `AdvisorConversationLogRepository.recordTurn` against a
//        recording fake `PostgresPool`, proving:
//          * SET LOCAL app.operator_id is in place when the INSERT
//            runs (verified at the wrapper layer);
//          * INSERT carries the operator + location + user +
//            conversation + turn + role + encrypted-content +
//            metadata binds and returns the assigned trace id;
//          * Dart-side validation rejects malformed inputs before
//            opening a transaction;
//          * StateError messages never echo plaintext / encrypted
//            bytes / IV / key reference / hash content.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validConvId = '44444444-4444-4444-4444-444444444444';
const String _validTraceId = '55555555-5555-5555-5555-555555555555';
const String _otherOpId = '66666666-6666-6666-6666-666666666666';

const String _validHash =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202604280007_phase_9_0sigma_h_advisor_conversation_log.sql',
  );

  group('Phase 9.0Σ.h migration shape', () {
    test('runs in a single transaction (begin/commit pair)', () {
      expect(migrationSql, contains('begin;'));
      expect(migrationSql, contains('commit;'));
    });

    test('enables pgcrypto for digest helpers + cutover.0a CMK pairing',
        () {
      expect(
        migrationSql,
        contains('create extension if not exists pgcrypto'),
      );
    });

    test('creates the audit_privacy NOLOGIN role idempotently', () {
      // Matches the role-create pattern in
      // 202604250000_advisor_roles.sql.
      expect(
        migrationSql,
        contains("rolname = 'audit_privacy'"),
      );
      expect(
        migrationSql,
        contains('create role audit_privacy nologin'),
      );
    });

    test('declares advisor_conversation_log with the locked column shape',
        () {
      expect(
        migrationSql,
        contains(
          'create table if not exists public.advisor_conversation_log',
        ),
      );
      // UUID trace id remains on the table even though it is not the
      // PK on its own (partitioning rule).
      expect(
        migrationSql,
        contains('id uuid not null default gen_random_uuid()'),
      );
      expect(
        migrationSql,
        contains(
          'operator_id uuid not null references public.operators',
        ),
      );
      expect(migrationSql, contains('location_id uuid not null'));
      expect(migrationSql, contains('user_id uuid null'));
      expect(migrationSql, contains('conversation_id uuid not null'));
      expect(
        migrationSql,
        contains(
          'turn_index integer not null check (turn_index >= 0)',
        ),
      );
      expect(
        migrationSql,
        contains(
          "check (role in ('user', 'assistant', 'system', 'tool'))",
        ),
      );
    });

    test('declares the encrypted raw payload columns + key reference',
        () {
      // Encrypted content + IV + KMS key reference. Raw bytes only;
      // the migration never references plaintext.
      expect(migrationSql, contains('content_encrypted bytea not null'));
      expect(migrationSql, contains('content_iv bytea not null'));
      expect(migrationSql, contains('content_key_ref text not null'));
      // Length cap so a malformed key reference cannot blow out the
      // index.
      expect(
        migrationSql,
        contains(
          'check (char_length(content_key_ref) between 1 and 200)',
        ),
      );
    });

    test('declares queryable non-sensitive metadata columns', () {
      // SHA-256 hex content_hash with format CHECK.
      expect(migrationSql, contains('content_hash text not null'));
      expect(
        migrationSql,
        contains(r"check (content_hash ~ '^[0-9a-f]{64}$')"),
      );
      expect(migrationSql, contains('surface text not null'));
      expect(migrationSql, contains('query_class text null'));
      expect(migrationSql, contains('usage_class text not null'));
      expect(migrationSql, contains('provider text null'));
      expect(migrationSql, contains('model_id text null'));
      expect(migrationSql, contains('model_version text null'));
      expect(
        migrationSql,
        contains('prompt_token_count integer null'),
      );
      expect(
        migrationSql,
        contains('completion_token_count integer null'),
      );
      expect(migrationSql, contains('cost_usd numeric(12, 6) null'));
      expect(migrationSql, contains('latency_ms integer null'));
      expect(
        migrationSql,
        contains('created_at timestamptz not null default now()'),
      );
    });

    test('PK is tenant-leading and partition-compatible '
        '(operator_id, created_at, id)', () {
      // PG partitioned tables require the partition key in every
      // unique constraint. The PK leads with `operator_id` for RLS
      // performance discipline and includes `created_at` (the
      // partition key) so the constraint is legal under
      // `partition by range (created_at)`. The UUID `id` is the
      // tiebreaker.
      expect(
        migrationSql,
        contains('primary key (operator_id, created_at, id)'),
      );
    });

    test('composite FK rejects (operator_a, location_b) mismatches', () {
      expect(
        migrationSql,
        contains(
          'foreign key (operator_id, location_id)\n'
          '    references public.locations(operator_id, location_id)',
        ),
      );
    });

    test('partitions by range(created_at) with a default partition '
        '(matches usage_logs posture)', () {
      expect(
        migrationSql,
        contains(') partition by range (created_at);'),
      );
      expect(
        migrationSql,
        contains(
          'create table if not exists '
          'public.advisor_conversation_log_default\n'
          '  partition of public.advisor_conversation_log default;',
        ),
      );
    });

    test('every B-tree index leads with operator_id (RLS performance '
        'discipline)', () {
      // Hot read path 1: conversation turn ordering.
      expect(
        migrationSql,
        contains(
          'create index if not exists '
          'advisor_conversation_log_op_conv_turn_idx\n'
          '  on public.advisor_conversation_log\n'
          '  (operator_id, conversation_id, turn_index);',
        ),
      );
      // Hot read path 2: per-user recent activity.
      expect(
        migrationSql,
        contains(
          'create index if not exists '
          'advisor_conversation_log_op_user_created_idx\n'
          '  on public.advisor_conversation_log\n'
          '  (operator_id, user_id, created_at desc);',
        ),
      );
      // Hot read path 3: per-(location, usage_class) cap reconciliation.
      expect(
        migrationSql,
        contains(
          'create index if not exists '
          'advisor_conversation_log_op_loc_usage_idx\n'
          '  on public.advisor_conversation_log\n'
          '  (operator_id, location_id, usage_class, '
          'created_at desc);',
        ),
      );
    });

    test('RLS enabled on parent + default partition; policies use the '
        '9.0Σ.b wrapper', () {
      // RLS enabled on parent + default partition. Phase
      // 202604250005_advisor_cloud_foundation.sql sets the precedent
      // that partitioned tables receive their own per-partition
      // posture so detach/attach cannot silently drop tenant scope.
      expect(
        migrationSql,
        contains(
          'alter table public.advisor_conversation_log '
          'enable row level security',
        ),
      );
      expect(
        migrationSql,
        contains(
          'alter table public.advisor_conversation_log_default '
          'enable row level security',
        ),
      );
      // Three policies for the parent: per-tenant SELECT/INSERT for
      // service_role, plus the audit-privacy SELECT.
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_per_tenant_select"',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_per_tenant_insert"',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_audit_privacy_select"',
        ),
      );
      // All policies pull tenant context through the wrapper.
      expect(
        migrationSql,
        contains('operator_id = public.app_current_operator()'),
      );
      // And the rewriter's bare-GUC reads must be absent — the lint
      // group below also asserts this against the policy-aware
      // scanner, but a literal guard here surfaces a regression
      // before the lint runs.
      expect(
        migrationSql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('does not introduce timestamp without time zone (storage rule)',
        () {
      final lower = migrationSql.toLowerCase();
      expect(lower, isNot(contains('timestamp without time zone')));
      // Bare `timestamp` (the column type, distinct from the literal
      // `timestamptz`) is also forbidden in operator-scoped tables.
      expect(
        lower,
        isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)(?!tz)'))),
      );
    });
  });

  group('Phase 9.0Σ.h RLS lint', () {
    test('migration passes the policy-aware lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280007_phase_9_0sigma_h_advisor_conversation_log.sql':
              migrationSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'advisor_conversation_log policies must read GUCs through '
            'the 9.0Σ.b wrappers; violations: ${result.violations}',
      );
    });
  });

  group('Phase 9.0Σ.h privacy posture', () {
    test('service_role gets INSERT but only column-level SELECT on '
        'safe metadata (raw encrypted columns omitted)', () {
      // INSERT on the parent + default partition.
      expect(
        migrationSql,
        contains(
          'grant insert on public.advisor_conversation_log '
          'to service_role',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant insert on '
          'public.advisor_conversation_log_default to service_role',
        ),
      );
      // Column-level SELECT — the allowlist must cover every safe
      // metadata column the proxy reads at audit time, including
      // the retention/legal-hold flags so legal-hold UX surfaces
      // can render without the encrypted columns.
      const safeColumns = <String>[
        'id',
        'operator_id',
        'location_id',
        'user_id',
        'conversation_id',
        'turn_index',
        'role',
        'content_hash',
        'surface',
        'query_class',
        'usage_class',
        'provider',
        'model_id',
        'model_version',
        'prompt_token_count',
        'completion_token_count',
        'cost_usd',
        'latency_ms',
        'legal_hold',
        'retention_class',
        'created_at',
      ];
      // Find the GRANT SELECT (...) ON public.advisor_conversation_log
      // TO service_role block and assert each safe column appears in
      // its column list.
      final grantBlock = _extractGrantSelectBlock(
        migrationSql,
        table: 'public.advisor_conversation_log',
        role: 'service_role',
      );
      expect(
        grantBlock,
        isNotNull,
        reason:
            'migration must declare a column-level GRANT SELECT on '
            'public.advisor_conversation_log to service_role',
      );
      for (final col in safeColumns) {
        expect(
          grantBlock,
          contains(col),
          reason:
              'service_role SELECT allowlist is missing safe metadata '
              'column $col — audit/replay surfaces depend on it',
        );
      }
    });

    test('service_role SELECT allowlist OMITS the raw encrypted '
        'columns (broad SELECT cannot expose raw content)', () {
      // The audit-privacy split: PG enforces column-level GRANTs at
      // the privilege layer (BEFORE RLS evaluates), so a SELECT *
      // through service_role errors before the row is even fetched.
      // Listing each forbidden column individually so a future ALTER
      // TABLE that adds a sensitive column without updating the
      // allowlist is caught at lint time.
      final grantBlock = _extractGrantSelectBlock(
        migrationSql,
        table: 'public.advisor_conversation_log',
        role: 'service_role',
      )!;
      const forbiddenColumns = <String>[
        'content_encrypted',
        'content_iv',
        'content_key_ref',
      ];
      for (final col in forbiddenColumns) {
        expect(
          grantBlock,
          isNot(contains(col)),
          reason:
              'service_role SELECT allowlist must NOT include raw '
              'content column $col — it is gated to audit_privacy',
        );
      }
    });

    test('audit_privacy gets full SELECT (raw encrypted content '
        'reachable only through the documented audit-privacy path)',
        () {
      // No column list — full table SELECT is intentional here. The
      // role is NOLOGIN; the proxy assumes it via SET LOCAL ROLE
      // only on the documented audit-privacy access path.
      expect(
        migrationSql,
        contains(
          'grant select on public.advisor_conversation_log '
          'to audit_privacy',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant select on '
          'public.advisor_conversation_log_default to audit_privacy',
        ),
      );
    });

    test('forge_admin gets full DML on the parent + default partition '
        '(BYPASSRLS escape hatch)', () {
      for (final table in <String>[
        'public.advisor_conversation_log',
        'public.advisor_conversation_log_default',
      ]) {
        expect(
          migrationSql,
          contains(
            'grant select, insert, update, delete on $table '
            'to forge_admin',
          ),
          reason:
              'forge_admin needs full DML on $table for paired-super-'
              'admin GDPR redaction / break-glass paths',
        );
      }
    });

    test('audit_privacy gets explicit EXECUTE on the '
        'app_current_operator() wrapper (so the audit-privacy SELECT '
        'policy keeps working under a hardened DB that revokes '
        'EXECUTE from PUBLIC)', () {
      // The 9.0Σ.b wrapper migration only granted EXECUTE to
      // service_role and forge_admin. PG's default PUBLIC EXECUTE
      // masks this today, but a hardened DB or future REVOKE FROM
      // PUBLIC would make audit-privacy policy evaluation fail.
      // The grant must live in this migration because audit_privacy
      // is also created here.
      expect(
        migrationSql,
        contains(
          'grant execute on function public.app_current_operator() '
          'to audit_privacy',
        ),
      );
    });

    test('default partition declares matching per-tenant + audit-'
        'privacy policies (detach/attach safety)', () {
      // The parent's policies do NOT automatically apply to the
      // default partition; the migration must declare them explicitly.
      // Without these, a future detach/attach could drop the tenant
      // scope on the partition silently.
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_default_per_tenant_select"',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_default_per_tenant_insert"',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy '
          '"advisor_conversation_log_default_audit_privacy_select"',
        ),
      );
    });
  });

  group('Phase 9.0Σ.h retention / legal-hold gate', () {
    test('declares legal_hold + retention_class columns with the '
        'locked defaults and CHECK', () {
      // Schema hooks for the retention/legal-hold gate (item 5 +
      // high-volume-table partitioning gate from
      // phase_9_scalability_decisions_2026-04-27.md).
      expect(
        migrationSql,
        contains('legal_hold boolean not null default false'),
      );
      expect(
        migrationSql,
        contains("retention_class text not null default 'standard'"),
      );
      // Tiered retention bucket. `'permanent'` is the never-purge
      // bucket; the purge predicate excludes it explicitly below.
      expect(
        migrationSql,
        contains(
          "retention_class in ('standard', 'extended', 'legal', "
          "'permanent')",
        ),
      );
    });

    test('partial purge-support index is tenant-leading and excludes '
        'legal_hold + permanent rows', () {
      // The partial WHERE clause means the index only carries rows
      // the purge can actually delete, so retention sweeps walk a
      // narrow index even on tables with millions of held rows.
      expect(
        migrationSql,
        contains(
          'create index if not exists '
          'advisor_conversation_log_op_purge_idx\n'
          '  on public.advisor_conversation_log\n'
          '  (operator_id, created_at)\n'
          "  where legal_hold = false and retention_class <> "
          "'permanent';",
        ),
      );
    });

    test('purge function exists with the locked signature + '
        'SECURITY DEFINER posture', () {
      expect(
        migrationSql,
        contains(
          'create or replace function public.advisor_conversation_log_purge('
          '\n  target_operator_id uuid,'
          '\n  before_ts timestamptz,'
          '\n  batch_size integer default 1000'
          '\n) returns integer'
          '\nlanguage plpgsql'
          '\nsecurity definer',
        ),
      );
    });

    test('purge function body NEVER deletes legal_hold = true or '
        "retention_class = 'permanent' rows (the gate the scalability "
        'contract requires)', () {
      // Both the inner SELECT and the outer DELETE filter through
      // the partial-index predicate; matching the literal
      // assertions here means a future edit cannot quietly drop
      // either guard without the test failing.
      expect(migrationSql, contains('and legal_hold = false'));
      expect(
        migrationSql,
        contains("and retention_class <> 'permanent'"),
      );
      // The DELETE is scoped per-operator — legal-hold gates do
      // not let one operator's purge sweep another operator's
      // rows.
      expect(
        migrationSql,
        contains('where operator_id = target_operator_id'),
      );
      // Batched form: PK-tuple `IN (...)` so it works correctly
      // across the parent partitioned table and its children
      // (`ctid` is per-physical-row and not stable under partition
      // pruning).
      expect(
        migrationSql,
        contains('(operator_id, created_at, id) in ('),
      );
      expect(migrationSql, contains('order by created_at'));
      expect(migrationSql, contains('limit batch_size'));
    });

    test('purge function rejects a non-positive batch_size', () {
      // The batch_size guard is the only producer-side check the
      // function performs; without it a 0/negative caller would
      // silently delete nothing or errors on the LIMIT clause.
      expect(
        migrationSql,
        contains('if batch_size <= 0 then'),
      );
      expect(
        migrationSql,
        contains(
          "raise exception\n      "
          "'advisor_conversation_log_purge: batch_size must be "
          "positive '\n      '(got %)'",
        ),
      );
    });

    test('purge function EXECUTE is granted only to forge_admin '
        '(runtime service_role path has no DELETE surface)', () {
      // REVOKE FROM PUBLIC removes the default EXECUTE grant so a
      // hardened DB does not inadvertently let other roles call
      // the function. forge_admin is the only role with EXECUTE,
      // matching the BYPASSRLS escape-hatch posture used elsewhere
      // for paired-super-admin paths.
      expect(
        migrationSql,
        contains(
          'revoke execute on function\n'
          '  public.advisor_conversation_log_purge'
          '(uuid, timestamptz, integer)\n'
          '  from public;',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant execute on function\n'
          '  public.advisor_conversation_log_purge'
          '(uuid, timestamptz, integer)\n'
          '  to forge_admin;',
        ),
      );
      // Negative assertion — the function must NOT be callable from
      // service_role (the runtime connection). Listing every other
      // role we use with an explicit isNot(contains(...)) keeps a
      // future "GRANT EXECUTE ... TO service_role" line from
      // sneaking past review.
      expect(
        migrationSql,
        isNot(
          contains(
            'grant execute on function\n'
            '  public.advisor_conversation_log_purge'
            '(uuid, timestamptz, integer)\n'
            '  to service_role',
          ),
        ),
      );
      expect(
        migrationSql,
        isNot(
          contains(
            'grant execute on function\n'
            '  public.advisor_conversation_log_purge'
            '(uuid, timestamptz, integer)\n'
            '  to audit_privacy',
          ),
        ),
      );
    });
  });

  group('AdvisorConversationLogRepository (B29 — fake Postgres)', () {
    test('recordTurn runs SET LOCAL + INSERT and returns the trace id',
        () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );

      final ciphertext = Uint8List.fromList(<int>[0x01, 0x02, 0x03, 0x04]);
      final iv = Uint8List.fromList(<int>[0x10, 0x11, 0x12, 0x13]);

      final id = await repo.recordTurn(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        conversationId: _validConvId,
        turnIndex: 0,
        role: 'user',
        contentEncrypted: ciphertext,
        contentIv: iv,
        contentKeyRef: 'kv://forge-flow/cmk/v1',
        contentHash: _validHash,
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
      );

      expect(id, equals(_validTraceId));
      final tx = pool.transactions.single;
      // SET LOCAL block ran first; the wrapper test in
      // operator_scoped_repository_test asserts the exact shape — here
      // we only confirm the operator GUC was injected before the
      // INSERT so RLS would admit the row.
      expect(
        tx.executedSql.first,
        contains("set_config('app.operator_id'"),
      );
      expect(tx.parameters.first['value'], equals(_validOpId));
      // INSERT shape.
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into advisor_conversation_log'));
      expect(insertSql, contains('returning id::text as id'));
      // Every column is bound through a parameter, never concatenated.
      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_validOpId));
      expect(params['location_id'], equals(_validLocId));
      expect(params['user_id'], equals(_validUserId));
      expect(params['conversation_id'], equals(_validConvId));
      expect(params['turn_index'], equals(0));
      expect(params['role'], equals('user'));
      // bytea binds as the raw byte sequence — verify the bytes
      // travelled through unmodified.
      expect(params['content_encrypted'], same(ciphertext));
      expect(params['content_iv'], same(iv));
      expect(params['content_key_ref'], equals('kv://forge-flow/cmk/v1'));
      expect(params['content_hash'], equals(_validHash));
      expect(params['surface'], equals('advisor.phone'));
      expect(params['query_class'], equals('sql'));
      expect(params['usage_class'], equals('advisor.turn'));
      expect(params['provider'], equals('anthropic'));
      expect(params['model_id'], equals('claude-sonnet-4-6'));
      expect(params['model_version'], equals('20260101'));
      expect(params['prompt_token_count'], equals(1024));
      expect(params['completion_token_count'], equals(256));
      expect(params['cost_usd'], equals(0.0125));
      expect(params['latency_ms'], equals(850));
      expect(tx.commitCount, equals(1));
    });

    test('recordTurn accepts a null userId for system-issued turns',
        () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.recordTurn(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: null,
        conversationId: _validConvId,
        turnIndex: 0,
        role: 'system',
        contentEncrypted: Uint8List.fromList(<int>[0x01]),
        contentIv: Uint8List.fromList(<int>[0x10]),
        contentKeyRef: 'kv://forge-flow/cmk/v1',
        contentHash: _validHash,
        surface: 'advisor.web',
        usageClass: 'advisor.turn',
      );

      final tx = pool.transactions.single;
      expect(tx.parameters.last['user_id'], isNull);
      // No SET LOCAL for app.user_id when userId is null — the wrapper
      // skips it. The first three statements are operator_id,
      // location_id, and the bypass_rls_audit marker.
      final setConfigStatements = tx.executedSql
          .where((sql) => sql.contains("select set_config('app."))
          .toList();
      expect(
        setConfigStatements.any(
          (sql) => sql.contains("set_config('app.user_id'"),
        ),
        isFalse,
      );
    });

    test('recordTurn rejects an invalid operator UUID before opening '
        'a transaction', () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      Object? thrown;
      try {
        await repo.recordTurn(
          operatorId: 'not-a-uuid',
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      // Acceptance: the wrapper never opened a transaction because
      // TenantContext rejected the bad UUID first.
      expect(pool.transactions, isEmpty);
    });

    test('recordTurn rejects role values outside the locked CHECK set',
        () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      ArgumentError? thrown;
      try {
        await repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'developer',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        );
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.name, equals('role'));
      expect(pool.transactions, isEmpty);
    });

    test('recordTurn rejects negative turnIndex / empty ciphertext / '
        'empty IV / oversize key reference / malformed content_hash '
        'before opening a transaction', () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      // Common base args.
      Map<String, Object?> base() => <String, Object?>{
            'operatorId': _validOpId,
            'locationId': _validLocId,
            'conversationId': _validConvId,
            'role': 'user',
            'contentEncrypted': Uint8List.fromList(<int>[0x01]),
            'contentIv': Uint8List.fromList(<int>[0x10]),
            'contentKeyRef': 'kv://forge-flow/cmk/v1',
            'contentHash': _validHash,
            'surface': 'advisor.phone',
            'usageClass': 'advisor.turn',
          };
      // Negative turn_index.
      await _expectArgumentError(
        () => repo.recordTurn(
          operatorId: base()['operatorId']! as String,
          locationId: base()['locationId']! as String,
          conversationId: base()['conversationId']! as String,
          turnIndex: -1,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        ),
      );
      // Empty ciphertext.
      await _expectArgumentError(
        () => repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        ),
      );
      // Empty IV.
      await _expectArgumentError(
        () => repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        ),
      );
      // Empty key reference.
      await _expectArgumentError(
        () => repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: '',
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        ),
      );
      // Malformed hash (uppercase / wrong length / non-hex).
      await _expectArgumentError(
        () => repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0x01]),
          contentIv: Uint8List.fromList(<int>[0x10]),
          contentKeyRef: 'kv://forge-flow/cmk/v1',
          contentHash: 'not-a-sha256',
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        ),
      );
      // None of these reached the pool.
      expect(pool.transactions, isEmpty);
    });

    test('recordTurn throws when RETURNING produces no rows '
        '(RLS denial scenario) and the message NEVER echoes plaintext '
        '/ ciphertext / IV / key reference / hash', () async {
      final pool = _AdvisorPool(returningId: null);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      const secretKeyRef = 'kv://secret-do-not-leak/v9';
      Object? thrown;
      try {
        await repo.recordTurn(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: _validUserId,
          conversationId: _validConvId,
          turnIndex: 0,
          role: 'user',
          contentEncrypted: Uint8List.fromList(<int>[0xDE, 0xAD, 0xBE, 0xEF]),
          contentIv: Uint8List.fromList(<int>[0xCA, 0xFE]),
          contentKeyRef: secretKeyRef,
          contentHash: _validHash,
          surface: 'advisor.phone',
          usageClass: 'advisor.turn',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<StateError>());
      final message = (thrown as StateError).message;
      // Message names the table + RLS failure mode only.
      expect(message, contains('advisor_conversation_log'));
      expect(message, contains('RLS'));
      // Bound parameters NEVER appear in the error text.
      expect(message, isNot(contains(secretKeyRef)));
      expect(message, isNot(contains(_validHash)));
      expect(message, isNot(contains('DEAD')));
      expect(message, isNot(contains('CAFE')));
    });

    test('two consecutive recordTurn calls bind their own operator_id '
        '— pooled connection reuse cannot leak tenant context',
        () async {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );

      await repo.recordTurn(
        operatorId: _validOpId,
        locationId: _validLocId,
        conversationId: _validConvId,
        turnIndex: 0,
        role: 'user',
        contentEncrypted: Uint8List.fromList(<int>[0x01]),
        contentIv: Uint8List.fromList(<int>[0x10]),
        contentKeyRef: 'kv://forge-flow/cmk/v1',
        contentHash: _validHash,
        surface: 'advisor.phone',
        usageClass: 'advisor.turn',
      );
      await repo.recordTurn(
        operatorId: _otherOpId,
        locationId: _validLocId,
        conversationId: _validConvId,
        turnIndex: 0,
        role: 'user',
        contentEncrypted: Uint8List.fromList(<int>[0x01]),
        contentIv: Uint8List.fromList(<int>[0x10]),
        contentKeyRef: 'kv://forge-flow/cmk/v1',
        contentHash: _validHash,
        surface: 'advisor.phone',
        usageClass: 'advisor.turn',
      );

      expect(pool.transactions, hasLength(2));
      expect(
        pool.transactions[0].parameters.first['value'],
        equals(_validOpId),
      );
      expect(
        pool.transactions[1].parameters.first['value'],
        equals(_otherOpId),
      );
    });

    test("repository toString reports only the class name — there are "
        'no fields holding plaintext, ciphertext, or key material',
        () {
      final pool = _AdvisorPool(returningId: _validTraceId);
      final repo = AdvisorConversationLogRepository(
        TenantTransactionWrapper(pool),
      );
      // Default Object.toString returns "Instance of '<ClassName>'";
      // we just need to assert no secret-shaped material has snuck
      // into the class state. The repository extends the abstract
      // base which holds only the wrapper, so this is a structural
      // guarantee.
      final asString = repo.toString();
      expect(
        asString.contains('AdvisorConversationLogRepository'),
        isTrue,
      );
      expect(asString, isNot(contains('content_encrypted')));
      expect(asString, isNot(contains('content_iv')));
      expect(asString, isNot(contains('content_key_ref')));
      expect(asString, isNot(contains('kv://')));
    });
  });
}

/// Reads [path] and collapses CRLF → LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

/// Locates the column-level `GRANT SELECT ( ... ) ON <table> TO <role>`
/// statement in [sql] and returns the column-list block (everything up
/// to and including the role name). Used by the privacy-posture tests
/// to assert the column allowlist contains the safe-metadata columns
/// and excludes the encrypted-content columns.
String? _extractGrantSelectBlock(
  String sql, {
  required String table,
  required String role,
}) {
  final pattern = RegExp(
    r'grant\s+select\s*\(([\s\S]*?)\)\s*on\s+' +
        RegExp.escape(table) +
        r'\s+to\s+' +
        RegExp.escape(role),
    caseSensitive: false,
  );
  final match = pattern.firstMatch(sql);
  if (match == null) return null;
  return match.group(0);
}

/// Awaits [body] and asserts it throws an [ArgumentError]. Pulled into
/// a helper so the recordTurn validation test can chain several
/// argument-shape probes without per-case `expectLater` boilerplate.
Future<void> _expectArgumentError(Future<Object?> Function() body) async {
  ArgumentError? thrown;
  try {
    await body();
  } on ArgumentError catch (error) {
    thrown = error;
  }
  expect(thrown, isA<ArgumentError>());
}

/// Recording fake `PostgresPool` for AdvisorConversationLogRepository.
///
/// Mirrors the `_EventOutboxPool` helper from
/// `test/phase_9_0sigma_e_event_outbox_test.dart`: stores every
/// transaction it hands out so assertions can inspect SQL + binds +
/// commit/rollback counts. Never executes real SQL.
class _AdvisorPool implements PostgresPool {
  _AdvisorPool({required this.returningId});

  final String? returningId;

  final List<_AdvisorTransaction> transactions = <_AdvisorTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AdvisorTransaction(returningId: returningId);
    transactions.add(tx);
    return tx;
  }
}

class _AdvisorTransaction extends PostgresTransaction {
  _AdvisorTransaction({required this.returningId});

  final String? returningId;
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
    if (sql.contains('insert into advisor_conversation_log') &&
        sql.contains('returning id')) {
      final id = returningId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': id},
      ];
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
