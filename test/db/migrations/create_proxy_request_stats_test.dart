// P1a' — migration shape test for public.proxy_request_stats
// (Support logs redesign storage: stats-only per-AI-request telemetry,
// 30-day retention).
//
// Pins the persistence-shape contract for the new operator-scoped fact
// table: every column + its nullability, the result_status CHECK, the
// ABSENCE of any content/encrypted column, the ABSENCE of a FK on
// request_id, the composite locations FK, operator-leading indexes, a
// wrapper-based per-tenant RLS policy (no bare current_setting),
// TIMESTAMPTZ + no business_date, the cluster-wide retention purge
// function (SECURITY DEFINER + forge_admin-only EXECUTE + SKIP LOCKED +
// 30-day default), the pg_cron schedule, the GRANT posture, and that the
// migration is transaction-wrapped and additive.
//
// The test reads the raw SQL and asserts structural markers without
// running Postgres; the migration body is the source of truth.
//
// Mirrors
// test/db/migrations/advisor_conversation_log_request_correlation_and_retention_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605241500_create_proxy_request_stats.sql';

/// Strip SQL comments so structural assertions that look for statement
/// keywords or column tokens (content, encrypted, business_date, DELETE,
/// current_setting, etc.) do not match PROSE in the migration's header
/// (`-- …` lines) OR in `COMMENT ON … IS '…';` statements (whose text
/// legitimately mentions "no message content / no encrypted columns / no
/// business_date" — those words must not satisfy a "no such column" check).
///
/// `COMMENT ON` statements are removed first via a non-greedy match to the
/// next `;` — the comment string literals in this migration contain no
/// embedded `;`, so this cleanly drops each whole statement. Then `-- …`
/// line comments are trimmed.
String _stripSqlLineComments(String sql) {
  final withoutCommentOn = sql.replaceAll(
    RegExp(r'comment\s+on[\s\S]*?;', caseSensitive: false),
    '',
  );
  final buffer = StringBuffer();
  for (final line in withoutCommentOn.split('\n')) {
    final idx = line.indexOf('--');
    if (idx < 0) {
      buffer.writeln(line);
    } else {
      buffer.writeln(line.substring(0, idx));
    }
  }
  return buffer.toString();
}

void main() {
  final sql = File(_migrationPath).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = sql.toLowerCase();
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  final statements = _stripSqlLineComments(sql).toLowerCase();
  final statementsCompact =
      _stripSqlLineComments(sql).replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  group('P1a\' create proxy_request_stats migration', () {
    test('creates public.proxy_request_stats idempotently', () {
      expect(
        compact,
        contains('create table if not exists public.proxy_request_stats'),
      );
    });

    // ─── Columns + nullability ──────────────────────────────────────

    test('tenancy columns mirror proxy_requests (both NOT NULL)', () {
      expect(statementsCompact, contains('operator_id uuid not null'));
      expect(statementsCompact, contains('location_id uuid not null'));
    });

    test('request_id correlation column is NOT NULL (uuid)', () {
      expect(statementsCompact, contains('request_id uuid not null'));
    });

    test('usage_class is NOT NULL text', () {
      expect(statementsCompact, contains('usage_class text not null'));
    });

    test('actor_user_id is a NULLABLE uuid (never name/email)', () {
      expect(statementsCompact, contains('actor_user_id uuid null'));
      // Belt-and-braces: no name/email columns anywhere in the table.
      expect(statementsCompact, isNot(contains('actor_name')));
      expect(statementsCompact, isNot(contains('actor_email')));
      expect(statementsCompact, isNot(contains('user_email')));
      expect(statementsCompact, isNot(contains('user_name')));
    });

    test('provider / model identifiers are NULLABLE text', () {
      expect(statementsCompact, contains('provider text null'));
      expect(statementsCompact, contains('model_id text null'));
      expect(statementsCompact, contains('model_version text null'));
    });

    test('measured metric columns are NULLABLE (populated by later proxy slice)',
        () {
      expect(statementsCompact, contains('prompt_token_count integer null'));
      expect(
        statementsCompact,
        contains('completion_token_count integer null'),
      );
      expect(statementsCompact, contains('cost_usd numeric null'));
      expect(statementsCompact, contains('latency_ms integer null'));
    });

    test('created_at is TIMESTAMPTZ NOT NULL default now()', () {
      expect(
        statementsCompact,
        contains('created_at timestamptz not null default now()'),
      );
    });

    // ─── result_status CHECK ────────────────────────────────────────

    test('result_status has a CHECK limiting to real outcomes', () {
      expect(statementsCompact, contains('result_status text null'));
      // The three terminal outcomes a metered provider call lands in.
      expect(
        statementsCompact,
        contains("result_status in ('success', 'error', 'timeout')"),
      );
    });

    // ─── No content / no business_date ──────────────────────────────

    test('NO content / encrypted columns', () {
      expect(statementsCompact, isNot(contains('content')));
      expect(statementsCompact, isNot(contains('encrypted')));
      expect(statementsCompact, isNot(contains('ciphertext')));
      expect(statementsCompact, isNot(contains('plaintext')));
      expect(statementsCompact, isNot(contains('message_body')));
      expect(statementsCompact, isNot(contains('response_payload')));
    });

    test('time guardrail — TIMESTAMPTZ only, NO business_date', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
      expect(statementsCompact, isNot(contains('business_date')));
    });

    // ─── FK discipline ──────────────────────────────────────────────

    test('request_id has NO cross-table FOREIGN KEY to proxy_requests', () {
      // A FK would couple the 48h proxy_requests prune to these 30-day stats.
      expect(
        statementsCompact,
        isNot(contains('request_id uuid not null references')),
      );
      expect(statementsCompact, isNot(contains('foreign key (request_id)')));
      expect(
        statementsCompact,
        isNot(contains('references public.proxy_requests')),
      );
    });

    test('composite (operator_id, location_id) FK to locations, ON DELETE CASCADE',
        () {
      expect(
        statementsCompact,
        contains(
          'foreign key (operator_id, location_id) '
          'references public.locations(operator_id, location_id) '
          'on delete cascade',
        ),
      );
    });

    // ─── Indexes (operator-leading) ─────────────────────────────────

    test('correlation-join index is operator-leading', () {
      expect(
        compact,
        contains(
          'create index if not exists proxy_request_stats_op_loc_request_idx '
          'on public.proxy_request_stats '
          '(operator_id, location_id, request_id)',
        ),
      );
    });

    test('time-ordered tenant-read index is operator-leading', () {
      expect(
        compact,
        contains(
          'create index if not exists proxy_request_stats_op_loc_created_idx '
          'on public.proxy_request_stats '
          '(operator_id, location_id, created_at)',
        ),
      );
    });

    // ─── RLS via wrapper functions ──────────────────────────────────

    test('RLS enabled + per-tenant policy via wrapper functions', () {
      expect(
        compact,
        contains(
          'alter table public.proxy_request_stats enable row level security',
        ),
      );
      expect(
        compact,
        contains(
          'create policy "proxy_request_stats_tenant_isolation" '
          'on public.proxy_request_stats for all to service_role',
        ),
      );
      // USING + WITH CHECK both read tenant context through the wrappers.
      expect(compact, contains('operator_id = public.app_current_operator()'));
      expect(compact, contains('location_id = public.app_current_location()'));
    });

    test('RLS policy uses NO bare current_setting(app.*)', () {
      // tool/rls_policy_lint.dart forbids bare GUC reads in policy bodies.
      expect(statements, isNot(contains("current_setting('app.")));
      expect(statements, isNot(contains('current_setting ( \'app.')));
    });

    // ─── GRANT posture ──────────────────────────────────────────────

    test('service_role gets full DML; forge_admin gets SELECT', () {
      expect(
        compact,
        contains(
          'grant select, insert, update, delete '
          'on public.proxy_request_stats to service_role',
        ),
      );
      expect(
        compact,
        contains('grant select on public.proxy_request_stats to forge_admin'),
      );
    });

    // ─── Retention purge function ───────────────────────────────────

    test('cluster-wide purge function defined SECURITY DEFINER, 30-day default',
        () {
      expect(
        compact,
        contains(
          'create or replace function '
          'public.proxy_request_stats_purge_expired(',
        ),
      );
      expect(compact, contains('security definer'));
      expect(compact, contains('retention_days integer default 30'));
      expect(compact, contains('batch_size integer default 1000'));
    });

    test('purge batches with FOR UPDATE SKIP LOCKED on the age cutoff', () {
      // CLAUDE.md proxy convention: no pgmq — use FOR UPDATE SKIP LOCKED.
      expect(compact, contains('for update skip locked'));
      expect(statements, contains('created_at < v_cutoff'));
    });

    test('purge has NO legal_hold / permanent-retention concept', () {
      // This table is plain 30-day telemetry; the predicate is purely the
      // age cutoff (unlike advisor_conversation_log).
      expect(statements, isNot(contains('legal_hold')));
      expect(statements, isNot(contains("retention_class <> 'permanent'")));
    });

    test('purge EXECUTE revoked from public, granted forge_admin only', () {
      expect(
        compact,
        contains(
          'revoke execute on function '
          'public.proxy_request_stats_purge_expired(integer, integer) '
          'from public',
        ),
      );
      expect(
        compact,
        contains(
          'grant execute on function '
          'public.proxy_request_stats_purge_expired(integer, integer) '
          'to forge_admin',
        ),
      );
      // The runtime service_role connection must NOT gain EXECUTE on the purge.
      expect(
        statementsCompact,
        isNot(
          contains(
            'grant execute on function '
            'public.proxy_request_stats_purge_expired(integer, integer) '
            'to service_role',
          ),
        ),
      );
    });

    // ─── pg_cron schedule ───────────────────────────────────────────

    test('pg_cron retention job registered, daily 03:30, idempotent', () {
      expect(
        compact,
        contains("jobname = 'forge_proxy_request_stats_retention'"),
      );
      expect(compact, contains('perform cron.unschedule(v_jobid)'));
      expect(compact, contains('perform cron.schedule('));
      // Daily at 03:30 UTC — off the 03:15 advisor_conversation_log sweep.
      expect(compact, contains("'30 3 * * *'"));
      expect(
        compact,
        contains('select public.proxy_request_stats_purge_expired(30);'),
      );
      // Graceful no-op + cross-DB scheduling notice when cron metadata is
      // absent in the application database (Azure split-DB topology).
      expect(compact, contains("to_regnamespace('cron') is null"));
      expect(compact, contains('cron.schedule_in_database'));
    });

    // ─── Migration discipline ───────────────────────────────────────

    test('migration is wrapped in a transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('uses idempotent DDL (create table/index if not exists, or replace)',
        () {
      expect(normalized, contains('create table if not exists'));
      expect(normalized, contains('create index if not exists'));
      expect(normalized, contains('create or replace function'));
    });

    test('additive only — drops nothing except the (re-)created policy', () {
      // The only DROP allowed is the idempotent `drop policy if exists` guard
      // immediately before the CREATE POLICY. No DROP TABLE / COLUMN / INDEX /
      // CONSTRAINT.
      final dropPattern = RegExp(
        r'\bdrop\s+(?:table|column|index|constraint)\b',
        caseSensitive: false,
      );
      expect(dropPattern.hasMatch(statements), isFalse);
    });

    test('header cites authority + the Support logs redesign plan', () {
      expect(normalized, contains('admin_support_logs_redesign'));
      // Cites the P1a origin migration it mirrors for retention.
      expect(
        normalized,
        contains(
          '202605241000_advisor_conversation_log_request_correlation_and_retention.sql',
        ),
      );
      // Cites the proxy_requests model it mirrors for tenancy.
      expect(
        normalized,
        contains('202604250005_advisor_cloud_foundation.sql'),
      );
    });

    test('table + key column + function comments document the contract', () {
      expect(
        compact,
        contains('comment on table public.proxy_request_stats'),
      );
      expect(
        compact,
        contains('comment on column public.proxy_request_stats.request_id'),
      );
      expect(
        compact,
        contains('comment on column public.proxy_request_stats.actor_user_id'),
      );
      expect(
        compact,
        contains(
          'comment on function '
          'public.proxy_request_stats_purge_expired(integer, integer)',
        ),
      );
    });
  });
}
