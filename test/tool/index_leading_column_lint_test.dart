// Tests for `tool/index_leading_column_lint.dart`. Behaviours covered:
//
//   1. Real on-disk migrations — current repo passes (zero errors,
//      zero warnings post-slice-B.4 cleanup).
//   2. Fixture with a non-operator-leading B-tree index on an
//      operator-scoped table → ERROR.
//   3. Fixture with an operator-leading composite → PASS.
//   4. Pre-cutoff migration → not scanned (errors inside it ignored).
//   5. GIST/GIN/HASH indexes are out of scope (not flagged).
//   6. Partial index `WHERE operator_id IS NULL` is exempt.
//   7. Hardcoded exemptions are honoured.
//   8. role_audit_log with operator_id added → indexes that don't
//      lead with operator_id ERROR (no warn-only carve-out).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/index_leading_column_lint.dart';

void main() {
  group('index_leading_column_lint', () {
    test('clean against the real on-disk migrations '
        '(no errors, no warnings post-slice-B.4)', () {
      final files = _readMigrationsDir();
      expect(
        files.isNotEmpty,
        isTrue,
        reason: 'tests must run from repository root',
      );
      final result = IndexLeadingColumnLintRunner(files: files).run();
      expect(
        result.hasErrors,
        isFalse,
        reason: 'real tree should not produce errors. '
            'errors: ${result.errors.toList()}',
      );
      // Slice B.4 added operator_id to role_audit_log and dropped the
      // legacy non-leading indexes. No warning carve-out remains.
      expect(
        result.warnings,
        isEmpty,
        reason: 'real tree should not produce warnings. '
            'warnings: ${result.warnings.toList()}',
      );
    });

    test('flags a non-operator-leading B-tree index on an '
        'operator-scoped table as ERROR', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null,
  business_date date not null
);

create index if not exists fact_thing_business_date_idx
  on public.fact_thing (business_date, id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290000_new_index.sql': sql,
        },
      ).run();
      expect(result.hasErrors, isTrue);
      final errs = result.errors.toList();
      expect(errs, hasLength(1));
      expect(errs.single.tableName, 'fact_thing');
      expect(errs.single.indexName, 'fact_thing_business_date_idx');
      expect(errs.single.leadingColumn, 'business_date');
    });

    test('detects operator_id added by ALTER TABLE in a later '
        'migration and flags non-leading indexes anywhere', () {
      // Two-file fixture: the original migration defines `fact_thing`
      // without operator_id (no flagging at that time); a later
      // migration adds operator_id via ALTER TABLE; a third migration
      // creates a non-leading B-tree index. The lint must scan all
      // three and ERROR on the index — even the index in the original
      // file (had it existed) would now be in scope.
      const tableSql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  business_date date not null
);

create index if not exists fact_thing_legacy_business_date_idx
  on public.fact_thing (business_date, id);
''';
      const alterSql = '''
alter table public.fact_thing
  add column if not exists operator_id uuid null;
''';
      const newIndexSql = '''
create index if not exists fact_thing_new_business_date_idx
  on public.fact_thing (business_date desc);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290020_table.sql': tableSql,
          '202604290021_add_operator_id.sql': alterSql,
          '202604290022_new_index.sql': newIndexSql,
        },
      ).run();
      expect(result.hasErrors, isTrue);
      final flagged =
          result.errors.map((e) => e.indexName).toSet();
      expect(flagged, contains('fact_thing_legacy_business_date_idx'));
      expect(flagged, contains('fact_thing_new_business_date_idx'));
      expect(result.operatorScopedTableCount, 1);
    });

    test('post-B.4 role_audit_log has operator_id; non-leading indexes '
        'on it ERROR (no warn-only carve-out)', () {
      const sql = '''
create table if not exists public.role_audit_log (
  entry_id uuid primary key,
  role_id uuid null,
  user_role_id uuid null,
  operator_id uuid null,
  changed_at timestamptz not null
);

create index if not exists role_audit_log_role_idx
  on public.role_audit_log (role_id, changed_at desc);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202605010001_role_audit.sql': sql,
        },
      ).run();
      expect(result.warnings, isEmpty);
      expect(result.hasErrors, isTrue);
      expect(result.errors.single.tableName, 'role_audit_log');
      expect(result.errors.single.indexName, 'role_audit_log_role_idx');
      expect(result.errors.single.leadingColumn, 'role_id');
    });

    test('passes an index that leads with operator_id', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null,
  location_id uuid null
);

create index if not exists fact_thing_tenant_idx
  on public.fact_thing (operator_id, location_id, id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290002_clean_index.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('passes an index that leads with operator_id when the table '
        'is declared in a different (in-scope) file', () {
      const tableSql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null
);
''';
      const indexSql = '''
create index if not exists fact_thing_tenant_idx
  on public.fact_thing (operator_id, id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290003_table.sql': tableSql,
          '202604290004_index.sql': indexSql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('skips pre-cutoff migrations entirely', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null
);

create index if not exists fact_thing_bad_idx
  on public.fact_thing (id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          // One year before cutoff — must be skipped.
          '202504250000_legacy.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
      expect(result.skippedPreCutoffCount, 1);
      expect(result.scannedFileCount, 0);
    });

    test('skips non-btree indexes (USING gist / gin / hash)', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null,
  path ltree not null
);

create index if not exists fact_thing_path_gist_idx
  on public.fact_thing using gist (path);

create index if not exists fact_thing_tags_gin_idx
  on public.fact_thing using gin (id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290005_non_btree.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('exempts an index whose WHERE predicate restricts '
        'operator_id IS NULL', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid null,
  occurred_at timestamptz not null
);

create index if not exists fact_thing_global_occurred_idx
  on public.fact_thing (occurred_at desc)
  where operator_id is null;
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290006_partial_null.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('exempts an operator_id IS NULL conjunct that is one term of '
        'an AND chain', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid null,
  archived_at timestamptz null,
  occurred_at timestamptz not null
);

create index if not exists fact_thing_partial_idx
  on public.fact_thing (occurred_at desc)
  where operator_id is null and archived_at is null;
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290009_and_chain.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('does NOT exempt a predicate that mentions operator_id IS NULL '
        'inside an OR — index still covers tenant rows', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid null,
  archived_at timestamptz null
);

create index if not exists fact_thing_loose_or_idx
  on public.fact_thing (id)
  where operator_id is null or archived_at is null;
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290010_loose_or.sql': sql,
        },
      ).run();
      expect(result.hasErrors, isTrue);
      expect(result.errors.single.indexName, 'fact_thing_loose_or_idx');
    });

    test('does NOT exempt a predicate that negates operator_id IS NULL',
        () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid null
);

create index if not exists fact_thing_negated_idx
  on public.fact_thing (id)
  where not (operator_id is null);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290011_negated.sql': sql,
        },
      ).run();
      expect(result.hasErrors, isTrue);
      expect(result.errors.single.indexName, 'fact_thing_negated_idx');
    });

    test('exempts a wrapped (operator_id IS NULL) inside an AND chain', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid null,
  foo text null
);

create index if not exists fact_thing_wrapped_idx
  on public.fact_thing (foo)
  where (operator_id is null) and foo is not null;
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290012_wrapped.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('honours the hardcoded exempt set passed to the runner', () {
      const sql = '''
create table if not exists public.fact_thing (
  id uuid primary key,
  operator_id uuid not null
);

create index if not exists fact_thing_bad_idx
  on public.fact_thing (id);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290007_exempt.sql': sql,
        },
        exemptions: const <String>{
          '202604290007_exempt.sql:fact_thing_bad_idx',
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('skips a CREATE INDEX on a table without operator_id', () {
      const sql = '''
create table if not exists public.config (
  key text primary key,
  value text not null
);

create index if not exists config_value_idx
  on public.config (value);
''';
      final result = IndexLeadingColumnLintRunner(
        files: <String, String>{
          '202604290008_global_table.sql': sql,
        },
      ).run();
      expect(result.isClean, isTrue);
      expect(result.operatorScopedTableCount, 0);
    });
  });
}

Map<String, String> _readMigrationsDir() {
  final dir = Directory('db/migrations');
  expect(
    dir.existsSync(),
    isTrue,
    reason: 'tests must run from repository root',
  );
  final out = <String, String>{};
  for (final entity in dir.listSync()) {
    if (entity is File && entity.path.toLowerCase().endsWith('.sql')) {
      final name = entity.uri.pathSegments.last;
      out[name] = entity.readAsStringSync().replaceAll('\r\n', '\n');
    }
  }
  return out;
}
