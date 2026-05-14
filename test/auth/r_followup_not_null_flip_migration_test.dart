// Wave 2 R-1L-FU + R-2L-FU — permission_keys NOT NULL flip migration
// shape tests.
//
// Pins the shape of
// `db/migrations/202605150100_phase_r_followup_not_null_flip.sql` so
// the implementation cannot silently drift away from the slice
// contract recorded in the R-1L (`202605142100_…`) and R-2L
// (`202605150000_…`) terminal comments that explicitly park their
// NOT-NULL flip in this follow-up.
//
// Coverage:
//   1. The migration file exists and lex-orders after R-2L.
//   2. Defensive pre-flight DO block counts NULL rows across all five
//      guarded columns (product_label / category_label / scope_kind /
//      human_label / implies) and raises loudly with the offending
//      row count before the structural flip runs.
//   3. The migration flips all four R-1L + R-2L text columns
//      (product_label / category_label / scope_kind / human_label) to
//      NOT NULL via a single ALTER TABLE statement.
//   4. The `implies text[]` column has its safe default `'{}'::text[]`
//      reasserted, any stray NULL rows are backfilled to `'{}'`, and
//      the column is set NOT NULL.
//   5. The migration carries the standard local statement / lock
//      timeouts (`30s` / `5s`).
//   6. The migration adds no new columns (this is the **contract**
//      half of the R-1L + R-2L expand-contract pair).
//   7. The migration does not widen any constraint nor mutate any data
//      shape — only the defensive `implies` safety-net UPDATE is
//      allowed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wave 2 R-1L-FU + R-2L-FU NOT NULL flip migration shape', () {
    late String migration;
    // SQL body with `-- ...` line comments stripped so prose in
    // doc-headers (which legitimately contains words like
    // "add column" and "update") cannot trip the assertions that
    // scan executable SQL.
    late String executableSql;

    setUpAll(() {
      migration = File(
        'db/migrations/202605150100_phase_r_followup_not_null_flip.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      executableSql = migration
          .split('\n')
          .map((line) {
            final commentIdx = line.indexOf('--');
            return commentIdx == -1 ? line : line.substring(0, commentIdx);
          })
          .join('\n');
    });

    test('migration file exists with the slice-named timestamp slot', () {
      final names = Directory('db/migrations')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.sql'))
          .toList()
        ..sort();
      expect(
        names,
        contains('202605150100_phase_r_followup_not_null_flip.sql'),
      );
      // Lex-orders after R-2L (which lex-orders after R-1L).
      final idx = names.indexOf(
        '202605150100_phase_r_followup_not_null_flip.sql',
      );
      final r2lIdx = names.indexOf(
        '202605150000_phase_r2l_default_role_catalog_v2.sql',
      );
      final r1lIdx = names.indexOf(
        '202605142100_phase_R_1L_roles_schema_rewrite.sql',
      );
      expect(idx, greaterThan(r2lIdx));
      expect(r2lIdx, greaterThan(r1lIdx));
    });

    test(
      'pre-flight DO block counts NULL rows across all 4 text columns',
      () {
        // The pre-flight MUST cover product_label, category_label,
        // scope_kind, AND human_label so the migration fails loudly
        // rather than silently flipping a column whose backfill
        // regressed.
        expect(migration, contains('product_label is null'));
        expect(migration, contains('category_label is null'));
        expect(migration, contains('scope_kind is null'));
        expect(migration, contains('human_label is null'));
      },
    );

    test('pre-flight raises with the offending row count', () {
      // Compact-whitespace match so multi-line formatting does not
      // break the assertion against the raise body.
      final compact = migration.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact,
        contains(
          'Cannot flip permission_keys.{product_label,category_label,'
          'scope_kind,human_label} to NOT NULL',
        ),
      );
      expect(
        compact,
        contains('rows still NULL'),
      );
      expect(
        compact,
        contains('Investigate R-1L + R-2L backfills before re-running'),
      );
    });

    test('flips all four R-1L + R-2L text columns to NOT NULL', () {
      // A single ALTER TABLE clause with all four ALTER COLUMN ... SET
      // NOT NULL legs takes one ACCESS EXCLUSIVE lock for the cutover.
      final compact = migration.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact,
        contains('alter table public.permission_keys'),
      );
      expect(
        compact,
        contains('alter column product_label set not null'),
      );
      expect(
        compact,
        contains('alter column category_label set not null'),
      );
      expect(
        compact,
        contains('alter column scope_kind set not null'),
      );
      expect(
        compact,
        contains('alter column human_label set not null'),
      );
    });

    test('reasserts implies default of empty array and flips NOT NULL', () {
      final compact = migration.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact,
        contains("alter column implies set default '{}'::text[]"),
      );
      // Safety-net backfill: any stray NULL `implies` row becomes
      // `'{}'::text[]` before the subsequent SET NOT NULL.
      expect(
        compact,
        contains("set implies = '{}'::text[] where implies is null"),
      );
      expect(
        compact,
        contains('alter column implies set not null'),
      );
    });

    test('carries the standard local statement / lock timeouts', () {
      expect(migration, contains("set local statement_timeout = '30s'"));
      expect(migration, contains("set local lock_timeout = '5s'"));
    });

    test('is the contract half — adds no new columns', () {
      // The R-1L + R-2L expand half already added every column; the
      // contract migration MUST NOT introduce any new column.
      // Check against the comment-stripped body — comments may
      // legitimately reference "add column" while describing R-1L/R-2L.
      expect(
        executableSql,
        isNot(contains(RegExp(r'\badd\s+column\b', caseSensitive: false))),
      );
    });

    test(
      'does not widen scope_kind CHECK or drop any constraint',
      () {
        // The R-1L scope_kind CHECK (`org_wide` / `location_scoped` /
        // `either`) is the only constraint on the flipped columns and
        // must not change in this slice. Check against the
        // comment-stripped body so prose references in the header
        // do not trip the assertions.
        expect(
          executableSql,
          isNot(contains(RegExp(r'\bdrop\s+constraint\b',
              caseSensitive: false))),
        );
        // Defensive: no DROP COLUMN / DROP TABLE either — this is a
        // pure tightening migration.
        expect(
          executableSql,
          isNot(contains(RegExp(r'\bdrop\s+column\b',
              caseSensitive: false))),
        );
        expect(
          executableSql,
          isNot(contains(RegExp(r'\bdrop\s+table\b', caseSensitive: false))),
        );
      },
    );

    test(
      'only data mutation is the implies NULL -> empty-array safety net',
      () {
        // The contract migration should not run any other UPDATE / DML.
        // Spot-check that there is exactly one UPDATE statement and it
        // is the `implies` safety net. Counted against the
        // comment-stripped body so the prose "UPDATE ... CASE"
        // references in the doc-header do not inflate the count.
        final updateMatches = RegExp(r'\bupdate\s+', caseSensitive: false)
            .allMatches(executableSql);
        expect(
          updateMatches.length,
          1,
          reason: 'expected exactly one UPDATE statement '
              '(the implies safety net)',
        );
      },
    );

    test('runs inside a single transaction', () {
      // begin / commit pair must wrap the whole migration so a failed
      // pre-flight raise rolls back any prior ALTER TABLE side effects.
      expect(migration, contains(RegExp(r'^begin;\s*$', multiLine: true)));
      expect(migration, contains(RegExp(r'^commit;\s*$', multiLine: true)));
    });
  });
}
