// P1a — migration shape test for advisor_conversation_log request
// correlation + 30-day retention (Support logs telemetry groundwork).
//
// Pins the persistence-shape contract for the additive request_id
// correlation column, the operator-leading join index, the cluster-wide
// retention purge function + its pg_cron schedule, and the unchanged RLS
// posture. The test reads the raw SQL and asserts structural markers
// without running Postgres; the migration body is the source of truth.
//
// Mirrors test/db/migrations/c_2_d_vendor_sync_outage_state_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/'
    '202605241000_advisor_conversation_log_request_correlation_and_retention.sql';

/// Strip SQL line comments (`-- …`) so structural assertions that look
/// for statement keywords (CREATE POLICY, current_setting, DELETE, etc.)
/// do not match prose in the migration's header / inline rationale.
String _stripSqlLineComments(String sql) {
  final buffer = StringBuffer();
  for (final line in sql.split('\n')) {
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

  group('P1a advisor_conversation_log correlation + retention migration', () {
    test('GAP 1 — adds NULLABLE request_id correlation column (idempotent)',
        () {
      expect(
        compact,
        contains(
          'alter table public.advisor_conversation_log '
          'add column if not exists request_id uuid null',
        ),
      );
    });

    test('GAP 1 — request_id has no cross-table FOREIGN KEY', () {
      // Decoupled-by-design: a FK would couple proxy_requests cleanup to
      // legal-hold retention. Assert no FK / REFERENCES is attached to the
      // request_id column anywhere in the executable SQL.
      expect(
        statementsCompact,
        isNot(contains('request_id uuid null references')),
      );
      expect(
        statementsCompact,
        isNot(contains('foreign key (request_id)')),
      );
      // No REFERENCES targeting proxy_requests at all.
      expect(
        statementsCompact,
        isNot(contains('references public.proxy_requests')),
      );
    });

    test('GAP 1 — request_id joins the service_role column allowlist', () {
      expect(
        compact,
        contains(
          'grant select (request_id) '
          'on public.advisor_conversation_log to service_role',
        ),
      );
      expect(
        compact,
        contains(
          'grant select (request_id) '
          'on public.advisor_conversation_log_default to service_role',
        ),
      );
    });

    test('GAP 1 — join index is operator-leading (RLS perf discipline)', () {
      // tool/index_leading_column_lint.dart requires operator_id first.
      expect(
        compact,
        contains(
          'create index if not exists '
          'advisor_conversation_log_op_loc_request_idx '
          'on public.advisor_conversation_log '
          '(operator_id, location_id, request_id)',
        ),
      );
    });

    test('GAP 2 — cluster-wide purge function defined SECURITY DEFINER', () {
      expect(
        compact,
        contains(
          'create or replace function '
          'public.advisor_conversation_log_purge_expired(',
        ),
      );
      expect(compact, contains('security definer'));
      // Default retention window is 30 days (operator decision).
      expect(compact, contains('retention_days integer default 30'));
    });

    test('GAP 2 — purge predicate NEVER deletes legal_hold or permanent rows',
        () {
      // The DELETE selection must exclude both protected classes. Assert
      // against comment-stripped SQL so the rationale prose is not what
      // satisfies the check.
      expect(statements, contains('legal_hold = false'));
      expect(statements, contains("retention_class <> 'permanent'"));
      // The window predicate compares created_at against the cutoff.
      expect(statements, contains('created_at < v_cutoff'));
    });

    test('GAP 2 — purge batches with FOR UPDATE SKIP LOCKED', () {
      // CLAUDE.md proxy convention: no pgmq — use FOR UPDATE SKIP LOCKED.
      expect(compact, contains('for update skip locked'));
    });

    test('GAP 2 — purge EXECUTE revoked from public, granted forge_admin only',
        () {
      expect(
        compact,
        contains(
          'revoke execute on function '
          'public.advisor_conversation_log_purge_expired(integer, integer) '
          'from public',
        ),
      );
      expect(
        compact,
        contains(
          'grant execute on function '
          'public.advisor_conversation_log_purge_expired(integer, integer) '
          'to forge_admin',
        ),
      );
      // The runtime service_role connection must NOT gain EXECUTE.
      expect(
        statementsCompact,
        isNot(
          contains(
            'grant execute on function '
            'public.advisor_conversation_log_purge_expired(integer, integer) '
            'to service_role',
          ),
        ),
      );
    });

    test('GAP 2 — pg_cron retention job registered, daily, idempotent', () {
      // Mirrors 202604280010_c topology: unschedule-then-reschedule guarded
      // by a cron-metadata presence check.
      expect(
        compact,
        contains("jobname = 'forge_advisor_conversation_log_retention'"),
      );
      expect(compact, contains('perform cron.unschedule(v_jobid)'));
      expect(compact, contains('perform cron.schedule('));
      // Daily at 03:15 UTC.
      expect(compact, contains("'15 3 * * *'"));
      expect(
        compact,
        contains('select public.advisor_conversation_log_purge_expired(30);'),
      );
      // Graceful no-op + cross-DB scheduling notice when cron metadata is
      // absent in the application database (Azure split-DB topology).
      expect(compact, contains("to_regnamespace('cron') is null"));
      expect(compact, contains('cron.schedule_in_database'));
    });

    test('RLS posture intact — adds NO new CREATE POLICY DDL', () {
      // This slice only ALTERs/indexes/schedules; the table's existing
      // 9.0Σ.h per-tenant policies stay in force and cover the new column.
      // Re-declaring a policy here risks regressing it, so assert none.
      final createPolicyPattern = RegExp(
        r'\bcreate\s+policy\b',
        caseSensitive: false,
      );
      expect(createPolicyPattern.hasMatch(statements), isFalse);
    });

    test('RLS posture intact — no bare current_setting(app.*) introduced', () {
      // tool/rls_policy_lint.dart only scans CREATE POLICY bodies, but pin
      // the absence anywhere in executable SQL as belt-and-braces.
      expect(statements, isNot(contains("current_setting('app.")));
      expect(statements, isNot(contains('current_setting ( \'app.')));
    });

    test('time guardrail — TIMESTAMPTZ only, no business_date added', () {
      // Support UI buckets by relative time/date, not restaurant business
      // day, so no business_date denormalization on this read surface.
      expect(normalized, isNot(contains('timestamp without time zone')));
      final addBusinessDate = RegExp(
        r'\badd\s+column\s+(?:if\s+not\s+exists\s+)?business_date\b',
        caseSensitive: false,
      );
      expect(addBusinessDate.hasMatch(statements), isFalse);
    });

    test('additive only — no destructive ops on the existing table', () {
      // No DROP / DELETE FROM / ALTER COLUMN. The purge function body
      // legitimately contains DELETE FROM, so check only the top-level
      // statement stream excludes a bare table-level destructive op
      // outside the function. We assert the migration drops nothing.
      final dropPattern = RegExp(
        r'\bdrop\s+(?:table|column|index|policy|constraint)\b',
        caseSensitive: false,
      );
      expect(dropPattern.hasMatch(statements), isFalse);
    });

    test('migration is wrapped in a transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('uses idempotent DDL (if not exists column + index)', () {
      expect(normalized, contains('add column if not exists'));
      expect(normalized, contains('create index if not exists'));
    });

    test('header cites authority + origin migration', () {
      expect(normalized, contains('claude.md'));
      expect(
        normalized,
        contains(
          '202604280007_phase_9_0sigma_h_advisor_conversation_log.sql',
        ),
      );
      // Cites the Support logs redesign plan home (phase P1a).
      expect(normalized, contains('admin_support_logs_redesign'));
    });

    test('column + function comments document the contract', () {
      // Use the whitespace-collapsed form: these COMMENT statements span
      // multiple lines in the migration body.
      expect(
        compact,
        contains(
          'comment on column public.advisor_conversation_log.request_id',
        ),
      );
      expect(
        compact,
        contains(
          'comment on function '
          'public.advisor_conversation_log_purge_expired(integer, integer)',
        ),
      );
    });

    test('does NOT UPDATE audit_logs (append-only invariant)', () {
      final updatePattern = RegExp(
        r'\bupdate\s+(?:only\s+)?(?:public\s*\.\s*)?audit_logs\b',
        caseSensitive: false,
      );
      expect(updatePattern.hasMatch(statements), isFalse);
    });
  });
}
