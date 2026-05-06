// Hardening / Wave B3 — daily audit-anchor pg_cron schedule shape tests.
//
// Local framework slice (no live database). Pins the migration's
// idempotent schedule registration so a future drift (e.g. someone
// dropping the unschedule-then-reschedule guard, renaming the
// jobname, or moving the schedule off the daily cadence) shows up
// before it lands on staging.
//
// The pattern mirrors:
//   * `test/services/realtime/event_outbox_retention_sweep_test.dart`
//     ('pg_cron schedule registration is idempotent' group)
//   * `test/phase_9_0sigma_k_rollups_test.dart`
//     (forge_rollup_hot_path / forge_rollup_cold_path schedule shape)
//
// The tests do NOT exercise the function — that requires a live
// Postgres + pg_cron in the maintenance database, which lives in the
// runbook's verification SQL block. The migration comment block
// records the operator-runnable verification SQL.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202605061700_hardening_audit_anchor_daily_schedule.sql',
  );

  group('Hardening Wave B3 audit-anchor cron migration shape', () {
    test('declares the NOTIFY-only kickoff function with the contract '
        'envelope shape', () {
      expect(
        migrationSql,
        contains(
          'create or replace function public.audit_anchor_run_daily()',
        ),
      );
      // The kickoff MUST emit NOTIFY on channel `audit_anchor_tick`
      // with the contract envelope keys (`source`, `fired_at`) so a
      // future Dart subscriber can listen and trigger the Cloud Run
      // anchor sweep without a parallel contract update.
      expect(
        migrationSql,
        contains("perform pg_notify(\n"
            "    'audit_anchor_tick',"),
      );
      expect(migrationSql, contains("'source', 'pg_cron'"));
      expect(migrationSql, contains("'fired_at', now()"));
    });

    test('function is restricted to forge_admin so runtime service_role '
        'has no business firing the audit-anchor cadence', () {
      expect(
        migrationSql,
        contains(
          'revoke execute on function public.audit_anchor_run_daily() '
          'from public',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant execute on function public.audit_anchor_run_daily() '
          'to forge_admin',
        ),
      );
    });

    test('pg_cron schedule registration is idempotent so re-applying '
        'the migration on a host where the schedule already exists is '
        'a no-op', () {
      // Idempotency pattern matches phase_9_0sigma_k_pg_cron_jobs +
      // phase_9_8_email_provider + phase_10a_3_outbox_retention_sweep:
      // unschedule any prior entry by jobid first, then reschedule.
      // cron.schedule() raises a unique_violation on a duplicate
      // jobname.
      expect(
        migrationSql,
        contains(
          "select jobid from cron.job\n"
          "     where jobname = 'forge_audit_anchor_daily'",
        ),
      );
      expect(migrationSql, contains('perform cron.unschedule(v_jobid);'));
      // Daily at 02:00 UTC. Two hours past the chain_date roll
      // (00:00 UTC) gives the previous-UTC-day chain a settled
      // buffer, and the schedule is staggered well clear of the
      // 23:55 UTC Cloud Scheduler trigger so the two cadences do
      // not collide.
      expect(
        migrationSql,
        contains(
          "perform cron.schedule(\n"
          "    'forge_audit_anchor_daily',\n"
          "    '0 2 * * *',\n"
          "    'select public.audit_anchor_run_daily();'\n"
          "  );",
        ),
      );
    });

    test('NOTICE-and-return guard for the Azure pg_cron split-DB case '
        'so the live apply log captures the schedule_in_database '
        'manual step', () {
      // Azure DB Flexible Server keeps pg_cron metadata in the
      // database named by `cron.database_name`. When pg_cron is
      // not in this database, the DO block must emit a NOTICE and
      // return so the operator can run
      // `cron.schedule_in_database(..., 'forgeflow')` from the
      // maintenance database.
      expect(
        migrationSql,
        contains("if to_regnamespace('cron') is null"),
      );
      expect(
        migrationSql,
        contains("or to_regclass('cron.job') is null then"),
      );
      expect(
        migrationSql,
        contains(
          "schedule from cron.database_name with cron.schedule_in_database",
        ),
      );
    });

    test('migration is wrapped in a single transaction so a partial '
        'failure leaves the prior schedule intact', () {
      final executableLines = migrationSql
          .split('\n')
          .where((line) => !RegExp(r'^\s*--').hasMatch(line))
          .map((line) => line.trim().toLowerCase())
          .toList();
      expect(
        executableLines.where((line) => line == 'begin;').length,
        equals(1),
        reason: 'migration must open with exactly one BEGIN',
      );
      expect(
        executableLines.where((line) => line == 'commit;').length,
        equals(1),
        reason: 'migration must close with exactly one COMMIT',
      );
    });

    test('migration introduces no new operator-scoped tables, indexes, '
        'or RLS policies (pure schedule registration)', () {
      // The slice is a NOTIFY-only kickoff + cron schedule. Any
      // CREATE TABLE / CREATE INDEX / CREATE POLICY would suggest
      // unrelated work has crept in.
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('create table')),
        reason: 'no new tables in this slice',
      );
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('create index')),
        reason: 'no new indexes in this slice',
      );
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('create policy')),
        reason: 'no new RLS policies in this slice',
      );
    });
  });
}

/// Reads [path] and collapses CRLF -> LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
