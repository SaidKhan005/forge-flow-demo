// ignore_for_file: file_names
//
// Filename intentionally mirrors the migration filename
// (`db/migrations/202605241600_plans_and_limits_phase4_operator_trial_mode.sql`)
// so a reviewer can correlate test <-> migration at a glance. The Dart
// `file_names` lint rejects digit-leading filenames; ignoring it here is
// the project convention for test/migrations/<timestamp>_test.dart.
//
// Plans & Limits V1 Phase 4a — Pilot free-trial flag migration shape.
//
// Local-framework slice — same posture as
// `test/migrations/202605021500_rls_depth_test.dart`: asserts the on-disk
// migration declares the expected DDL (additive + idempotent column adds,
// TIMESTAMPTZ on the expiry, the trial/expiry consistency CHECK, bounded
// lock/statement timeouts) and — per HP #2 — that it introduces NO
// `demo_*` table and creates NO new RLS policy on the tenant-root
// `operators` table. Live apply behavior is gated under Phase 9.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // CRLF -> LF on read so multi-line `contains(...)` assertions are
  // platform-independent. Windows checkouts deliver CRLF by default
  // (`.gitattributes` only forces eol=lf for *.sh), so the .sql is CRLF
  // on disk here; normalize before matching.
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202605241600_plans_and_limits_phase4_operator_trial_mode.sql',
  );

  group('Plans & Limits Phase 4a operator trial-mode migration', () {
    test('adds trial_mode as a NOT NULL boolean defaulting false', () {
      expect(
        migrationSql,
        contains(
          'add column if not exists trial_mode boolean not null default false',
        ),
        reason:
            'trial_mode must be additive (if not exists), non-null, and '
            'default false so every existing/omitted-tier row is a '
            'non-trial operator',
      );
    });

    test('adds trial_expires_at as a TIMESTAMPTZ (Time Guardrails)', () {
      expect(
        migrationSql,
        contains('add column if not exists trial_expires_at timestamptz'),
        reason:
            'trial_expires_at must be TIMESTAMPTZ (UTC) per CLAUDE.md '
            '"Time Guardrails"; nullable when not on a trial',
      );
      // Belt-and-braces: the banned naive type must not appear on the
      // expiry column.
      expect(
        migrationSql.contains('trial_expires_at timestamp without time zone'),
        isFalse,
        reason: 'TIMESTAMP WITHOUT TIME ZONE is banned on operator-scoped '
            'temporal columns',
      );
    });

    test('both column adds are idempotent (if not exists)', () {
      // Two additive column statements, each guarded by `if not exists`
      // and naming its column. Match the full statement form so the
      // explanatory header comment (which also uses the phrase "add
      // column if not exists") is not counted.
      expect(
        'add column if not exists trial_mode'.allMatches(migrationSql).length,
        equals(1),
      );
      expect(
        'add column if not exists trial_expires_at'
            .allMatches(migrationSql)
            .length,
        equals(1),
      );
    });

    test('declares the trial/expiry consistency CHECK (drop-if-exists '
        'first for re-apply)', () {
      expect(
        migrationSql,
        contains(
          'drop constraint if exists '
          'operators_trial_expiry_consistency_check',
        ),
        reason: 'CHECK is dropped-if-exists first so a re-apply is a no-op',
      );
      expect(
        migrationSql,
        contains('add constraint operators_trial_expiry_consistency_check'),
        reason: 'the consistency CHECK must be (re)added',
      );
      // The predicate: expiry present iff trial_mode is true.
      expect(
        migrationSql,
        contains('(trial_mode = true and trial_expires_at is not null)'),
      );
      expect(
        migrationSql,
        contains('(trial_mode = false and trial_expires_at is null)'),
      );
    });

    test('bounds statement_timeout + lock_timeout like the Phase 3 '
        'migration', () {
      expect(migrationSql, contains("set local statement_timeout = '30s'"));
      expect(migrationSql, contains("set local lock_timeout = '5s'"));
    });

    test('targets only public.operators (no other table touched)', () {
      // Every `alter table` in this migration must be on public.operators.
      final alterTargets = RegExp(r'alter table (\S+)')
          .allMatches(migrationSql)
          .map((m) => m.group(1))
          .toSet();
      expect(
        alterTargets,
        equals(<String>{'public.operators'}),
        reason: 'Phase 4a only adds per-operator attributes to the '
            'tenant-root operators table',
      );
    });

    test('HP #2 — introduces NO demo_* table', () {
      // The migration PROSE legitimately references "demo_* table" /
      // "second demo mode" to explain the HP #2 rationale — both in `--`
      // line comments AND inside `comment on ... is '...'` string
      // literals. Checking the raw substring would false-positive on
      // that honest documentation. Strip `--` lines and every
      // single-quoted string literal (which covers the comment bodies +
      // the interval literal), then assert the remaining executable DDL
      // skeleton names neither a `demo_` object nor any CREATE TABLE.
      final withoutLineComments = migrationSql
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');
      final ddlSkeleton = withoutLineComments
          .replaceAll(RegExp(r"'[^']*'"), "''")
          .toLowerCase();
      expect(
        ddlSkeleton.contains('demo_'),
        isFalse,
        reason: 'Pilot is a trial FLAG on a real operator; the executable '
            'DDL skeleton must not name any demo_* object (HP #2)',
      );
      expect(
        ddlSkeleton.contains('create table'),
        isFalse,
        reason: 'Phase 4a is an ALTER-only migration; it creates no table',
      );
    });

    test('adds NO new RLS policy + does NOT re-enable RLS (operators '
        'already has both)', () {
      // operators already carries RLS + a policy from the cloud
      // foundation migration; Phase 4a inherits that posture and must
      // not declare its own policy or RLS enable.
      expect(
        migrationSql.toLowerCase().contains('create policy'),
        isFalse,
        reason: 'no new RLS policy: trial columns inherit the existing '
            'operators RLS (operators_service_role_all)',
      );
      expect(
        migrationSql.toLowerCase().contains('enable row level security'),
        isFalse,
        reason: 'operators RLS is already enabled in 202604250005; Phase '
            '4a does not touch it',
      );
    });

    test('wraps the DDL in a single begin/commit transaction', () {
      expect('begin;'.allMatches(migrationSql).length, equals(1));
      expect('commit;'.allMatches(migrationSql).length, equals(1));
    });
  });
}

String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
