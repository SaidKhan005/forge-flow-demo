// Lane C C-1a — migration shape test for email_event.provider_event_id.
//
// Pins the persistence-shape contract for the new column + the partial
// UNIQUE INDEX. The test reads the raw SQL and asserts the presence
// (or absence) of structural markers without running Postgres; the
// migration body is the source of truth.
//
// What the C-1 webhook receiver depends on:
//   * column `provider_event_id text` exists on public.email_event
//   * column is NULLABLE (back-compat for historic rows + non-SendGrid
//     events that never carry a per-event id)
//   * partial UNIQUE INDEX
//     email_event_provider_event_id_unique
//       ON public.email_event (provider_event_id)
//       WHERE provider_event_id IS NOT NULL
//   * RLS posture on email_event is unchanged (no new policy added)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605131700_c_1a_email_event_provider_id.sql';

/// Strip SQL line comments (`-- …`) so structural assertions that look for
/// statement keywords (GRANT, DROP, ALTER COLUMN, etc.) do not match prose
/// in the migration's header / inline rationale comments.
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
  // Statement-only view: comment text removed. Use for assertions that
  // look for SQL keywords (GRANT, DROP, ALTER COLUMN, …) which legitimately
  // appear in the prose header but must not appear in executed DDL.
  final statements = _stripSqlLineComments(sql).toLowerCase();

  group('C-1a email_event.provider_event_id migration', () {
    test('adds provider_event_id column to email_event (idempotent)', () {
      expect(
        compact,
        contains(
          'alter table public.email_event '
          'add column if not exists provider_event_id text',
        ),
      );
    });

    test('provider_event_id column is NULLABLE (no NOT NULL)', () {
      // Back-compat: historic rows + non-SendGrid events must coexist
      // with new SendGrid rows. A NOT NULL on the new column would
      // reject all existing rows on apply. Pin the shape so a future
      // edit cannot silently tighten it.
      final addColumnPattern = RegExp(
        r'add\s+column\s+if\s+not\s+exists\s+provider_event_id\s+text\s*'
        r'(?:;|--|/\*)',
        caseSensitive: false,
      );
      final match = addColumnPattern.firstMatch(normalized);
      expect(
        match,
        isNotNull,
        reason:
            'ADD COLUMN statement must terminate at provider_event_id text '
            'with no NOT NULL / DEFAULT clause.',
      );
    });

    test('partial UNIQUE INDEX enforces dedupe on populated rows', () {
      expect(
        normalized,
        contains(
          'create unique index if not exists '
          'email_event_provider_event_id_unique',
        ),
      );
      expect(
        compact,
        contains(
          'on public.email_event (provider_event_id) '
          'where provider_event_id is not null',
        ),
      );
    });

    test('partial UNIQUE INDEX predicate is load-bearing (not a full UNIQUE)',
        () {
      // A full UNIQUE INDEX (or UNIQUE constraint) on provider_event_id
      // without the WHERE clause would forbid multiple NULL rows under
      // strict NULLS NOT DISTINCT semantics. The partial predicate is
      // the contract. If anyone strips it, this test fails.
      final partialIndexPattern = RegExp(
        r'create\s+unique\s+index\s+if\s+not\s+exists\s+'
        r'email_event_provider_event_id_unique[\s\S]*?'
        r'where\s+provider_event_id\s+is\s+not\s+null',
        caseSensitive: false,
      );
      expect(partialIndexPattern.hasMatch(normalized), isTrue);
    });

    test('does NOT add a new RLS policy on email_event', () {
      // email_event already has email_event_per_tenant_select from
      // 202605040200_phase_9_8_email_provider.sql. This migration does
      // NOT touch the RLS regime — adding a new policy would be a
      // schema-bleed and must be a separate, reviewed migration.
      // Check statement-only view so comment prose does not match.
      expect(
        statements,
        isNot(contains('create policy')),
      );
      expect(
        statements,
        isNot(contains(
          'alter table public.email_event enable row level security',
        )),
      );
      expect(
        statements,
        isNot(contains(
          'alter table public.email_event disable row level security',
        )),
      );
    });

    test('does NOT grant new privileges on email_event', () {
      // GRANT SELECT, INSERT on email_event to service_role / forge_admin
      // already exists from 202605040200. Postgres table-level grants
      // cover the new column under default privilege semantics, so no
      // new GRANT is needed and adding one would muddy provenance.
      // Check statement-only view so the rationale comment that
      // discusses existing grants does not trip the match.
      expect(
        statements,
        isNot(contains('grant ')),
      );
      expect(
        statements,
        isNot(contains('revoke ')),
      );
    });

    test('migration is pure additive expand (no destructive ops)', () {
      // No DROP, no DELETE, no ALTER COLUMN TYPE. C-1a is an additive
      // expand that ships in front of the C-1 receiver. Use the
      // statement-only view so the rationale that discusses "no drop,
      // no delete, no alter column type" in the header does not match.
      final dropTablePattern = RegExp(
        r'\bdrop\s+(?:table|column|index|constraint|policy)\b',
        caseSensitive: false,
      );
      expect(dropTablePattern.hasMatch(statements), isFalse);
      expect(
        statements,
        isNot(contains('delete from')),
      );
      expect(
        statements,
        isNot(contains('alter column')),
      );
    });

    test('respects time + lock guardrails (statement + lock timeout)', () {
      // CLAUDE.md migration hygiene: bound the lock window so a hot
      // table does not stall behind us.
      expect(normalized, contains('set local statement_timeout'));
      expect(normalized, contains('set local lock_timeout'));
    });

    test('migration is wrapped in a transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('uses idempotent DDL (if not exists on every CREATE / ADD)', () {
      expect(normalized, contains('add column if not exists'));
      expect(normalized, contains('create unique index if not exists'));
    });

    test('adds a column comment documenting the SendGrid origin', () {
      expect(
        normalized,
        contains(
          'comment on column public.email_event.provider_event_id is',
        ),
      );
      expect(normalized, contains('sg_event_id'));
    });

    test('header cites every authority doc the slice depends on', () {
      expect(normalized, contains('claude.md'));
      expect(normalized, contains('"rls-ready schema"'));
      expect(normalized, contains('wave_execution_ledger.md'));
      expect(normalized, contains('lane_c_parity/03_execution_slices.md'));
      expect(
        normalized,
        contains('202605040200_phase_9_8_email_provider.sql'),
      );
    });

    test('does NOT UPDATE audit_logs (append-only invariant)', () {
      // The audit_logs_update_lint enforces this in CI; the test pins
      // the local file so a regression is caught even if the lint runs
      // separately. Statement-only view so rationale comments cannot
      // accidentally match.
      final updatePattern = RegExp(
        r'\bupdate\s+(?:only\s+)?(?:public\s*\.\s*)?audit_logs\b',
        caseSensitive: false,
      );
      expect(updatePattern.hasMatch(statements), isFalse);
    });

    test('does NOT use pg_advisory_lock (banned per V1 lean cut)', () {
      // Statement-only view — the banned-token check must not match
      // prose explaining why pg_advisory_lock is banned.
      expect(statements, isNot(contains('pg_advisory_lock')));
    });
  });
}
