// Lane C C-7a — migration shape test for mfa_factors.recovery_codes_viewed_at.
//
// Pins the persistence-shape contract for the new column. The test reads
// the raw SQL and asserts the presence (or absence) of structural markers
// without running Postgres; the migration body is the source of truth.
//
// What the C-7 "Adaptive 2FA button" gateway depends on:
//   * column `recovery_codes_viewed_at timestamptz` exists on public.mfa_factors
//   * column is NULLABLE (NULL = never viewed; only state pre-launch + the
//     fallback for any future row inserted before the user clicks "View
//     recovery codes")
//   * RLS posture on mfa_factors is unchanged (no new policy added)
//   * no new GRANT or REVOKE
//   * pure additive expand — no DROP / DELETE / ALTER COLUMN TYPE

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql';

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

  group('C-7a mfa_factors.recovery_codes_viewed_at migration', () {
    test('adds recovery_codes_viewed_at column to mfa_factors (idempotent)',
        () {
      expect(
        compact,
        contains(
          'alter table public.mfa_factors '
          'add column if not exists recovery_codes_viewed_at timestamptz',
        ),
      );
    });

    test('recovery_codes_viewed_at column is NULLABLE (no NOT NULL)', () {
      // NULL = "never viewed" is the load-bearing default state. A NOT NULL
      // with a default would force every historic / future row to claim a
      // viewed timestamp it never had. Pin the shape so a future edit
      // cannot silently tighten it.
      final addColumnPattern = RegExp(
        r'add\s+column\s+if\s+not\s+exists\s+recovery_codes_viewed_at\s+'
        r'timestamptz\s*(?:;|--|/\*)',
        caseSensitive: false,
      );
      final match = addColumnPattern.firstMatch(normalized);
      expect(
        match,
        isNotNull,
        reason:
            'ADD COLUMN statement must terminate at recovery_codes_viewed_at '
            'timestamptz with no NOT NULL / DEFAULT clause.',
      );
    });

    test('column type is timestamptz (not timestamp without time zone)', () {
      // CLAUDE.md "Time Guardrails": TIMESTAMP WITHOUT TIME ZONE is banned
      // in operator-scoped tables. mfa_factors is auth-scope identity (keyed
      // by user_id) rather than strictly operator-scoped, but the project-
      // wide convention is timestamptz for any audit timestamp.
      expect(normalized, contains('recovery_codes_viewed_at timestamptz'));
      // Reject the banned variant in case a future edit substitutes it.
      final bannedPattern = RegExp(
        r'recovery_codes_viewed_at\s+timestamp\s+without\s+time\s+zone',
        caseSensitive: false,
      );
      expect(bannedPattern.hasMatch(normalized), isFalse);
    });

    test('does NOT add a new RLS policy on mfa_factors', () {
      // mfa_factors already has its existing per-user RLS regime. This
      // migration does NOT touch the RLS regime — adding a new policy
      // would be a schema-bleed and must be a separate, reviewed migration.
      // Check statement-only view so comment prose does not match.
      expect(
        statements,
        isNot(contains('create policy')),
      );
      expect(
        statements,
        isNot(contains(
          'alter table public.mfa_factors enable row level security',
        )),
      );
      expect(
        statements,
        isNot(contains(
          'alter table public.mfa_factors disable row level security',
        )),
      );
    });

    test('does NOT grant new privileges on mfa_factors', () {
      // GRANTs on mfa_factors already exist from prior migrations.
      // Postgres table-level grants cover the new column under default
      // privilege semantics, so no new GRANT is needed and adding one
      // would muddy provenance. Check statement-only view so the
      // rationale comment that discusses existing grants does not trip
      // the match.
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
      // No DROP, no DELETE, no ALTER COLUMN TYPE. C-7a is an additive
      // expand that ships in front of the C-7 receiver. Use the
      // statement-only view so the rationale that discusses "no drop,
      // no delete, no alter column type" in the header does not match.
      final dropPattern = RegExp(
        r'\bdrop\s+(?:table|column|index|constraint|policy)\b',
        caseSensitive: false,
      );
      expect(dropPattern.hasMatch(statements), isFalse);
      expect(
        statements,
        isNot(contains('delete from')),
      );
      expect(
        statements,
        isNot(contains('alter column')),
      );
      expect(
        statements,
        isNot(contains('truncate')),
      );
    });

    test('respects time + lock guardrails (statement + lock timeout)', () {
      // CLAUDE.md migration hygiene: bound the lock window so a hot
      // session-validate path does not stall behind us.
      expect(normalized, contains('set local statement_timeout'));
      expect(normalized, contains('set local lock_timeout'));
    });

    test('migration is wrapped in a transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('uses idempotent DDL (if not exists on ADD COLUMN)', () {
      expect(normalized, contains('add column if not exists'));
    });

    test('adds a column comment documenting the C-7 origin', () {
      expect(
        normalized,
        contains(
          'comment on column public.mfa_factors.recovery_codes_viewed_at is',
        ),
      );
      // Comment names the slice + button so future readers can trace
      // ownership without spelunking the ledger.
      expect(normalized, contains('c-7'));
      expect(normalized, contains('recovery codes'));
    });

    test('header cites every authority doc the slice depends on', () {
      expect(normalized, contains('claude.md'));
      expect(normalized, contains('"rls-ready schema"'));
      expect(normalized, contains('wave_execution_ledger.md'));
      expect(normalized, contains('lane_c_parity/03_execution_slices.md'));
      expect(
        normalized,
        contains('202604250008_auth_schema_foundation.sql'),
      );
      expect(
        normalized,
        contains('202605131700_c_1a_email_event_provider_id.sql'),
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

    test('does NOT add a new index (point-lookup covered by existing idx)',
        () {
      // The Adaptive 2FA button reads the column on a per-user point
      // lookup already covered by mfa_factors_user_active_idx. Adding
      // a new index on recovery_codes_viewed_at would be load-bearing
      // wrong (the column is not part of any predicate / sort order
      // beyond IS NULL discrimination on a single-user fetch). Pin the
      // shape so a well-meaning future edit can't drift it.
      expect(statements, isNot(contains('create index')));
      expect(statements, isNot(contains('create unique index')));
    });
  });
}
