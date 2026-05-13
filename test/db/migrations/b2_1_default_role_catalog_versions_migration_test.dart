// Lane B B2.1 — migration shape test for default_role_catalog_versions.
//
// Pins the persistence-shape contract for the catalog table + the
// operators FK column. The test reads the raw SQL and asserts the
// presence (or absence) of structural markers without running Postgres;
// the migration body is the source of truth.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605131600_b2_1_default_role_catalog_versions.sql';

void main() {
  final sql = File(_migrationPath).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = sql.toLowerCase();
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  group('B2.1 default_role_catalog_versions migration', () {
    test('creates default_role_catalog_versions table', () {
      expect(
        compact,
        contains('create table if not exists '
            'public.default_role_catalog_versions'),
      );
    });

    test('has the eight expected columns with correct shapes', () {
      expect(compact, contains('version_id uuid primary key'));
      expect(compact, contains('version_number integer not null'));
      expect(compact, contains('published_at timestamptz not null'));
      expect(compact, contains('published_by_user_id uuid not null'));
      expect(compact, contains('payload jsonb not null'));
      expect(compact, contains('payload_sha256 text not null'));
      expect(
        compact,
        contains('is_current boolean not null default false'),
      );
      expect(compact, contains('superseded_at timestamptz'));
      expect(compact, contains('notes text'));
    });

    test('payload CHECK enforces jsonb array shape', () {
      expect(
        compact,
        contains("check (jsonb_typeof(payload) = 'array')"),
      );
    });

    test('payload_sha256 CHECK enforces 64-char lowercase hex', () {
      expect(
        compact,
        contains(r"check (payload_sha256 ~ '^[0-9a-f]{64}$')"),
      );
    });

    test('partial UNIQUE INDEX enforces at-most-one current row', () {
      expect(
        normalized,
        contains('create unique index if not exists '
            'default_role_catalog_versions_current_unique'),
      );
      expect(compact, contains('where is_current = true'));
    });

    test('indexes version_number desc for latest-lookup', () {
      expect(
        normalized,
        contains(
          'default_role_catalog_versions_version_number_desc_idx',
        ),
      );
      expect(compact, contains('on public.default_role_catalog_versions '
          '(version_number desc)'));
    });

    test('does NOT declare an RLS policy on the catalog table', () {
      // The migration MUST document why no RLS exists (global catalog,
      // admin-pool BYPASSRLS); CLAUDE.md "RLS-Ready Schema" only
      // requires RLS on operator-scoped fact tables.
      expect(
        normalized,
        isNot(contains('create policy '
            '"default_role_catalog_versions_per_operator"')),
      );
      expect(
        normalized,
        isNot(contains(
          'alter table public.default_role_catalog_versions enable '
          'row level security',
        )),
      );
      // The "why no RLS" rationale must appear in the migration prelude
      // so future readers see the deliberate choice.
      expect(normalized, contains('why no rls'));
    });

    test('adds operators.default_role_catalog_version_id column', () {
      expect(
        compact,
        contains('alter table public.operators '
            'add column if not exists default_role_catalog_version_id uuid'),
      );
    });

    test('operators FK references catalog with ON DELETE SET NULL', () {
      expect(
        compact,
        contains('foreign key (default_role_catalog_version_id) '
            'references public.default_role_catalog_versions(version_id) '
            'on delete set null'),
      );
    });

    test('FK is added idempotently (skip when already present)', () {
      // The FK ADD uses a DO block guarded by pg_constraint lookup so
      // re-running the migration does not crash on the existing FK.
      expect(
        normalized,
        contains('from pg_constraint'),
      );
      expect(
        normalized,
        contains('operators_default_role_catalog_version_id_fkey'),
      );
    });

    test('grants forge_admin full DML + service_role read-only', () {
      expect(
        compact,
        contains(
          'grant select on public.default_role_catalog_versions '
          'to service_role',
        ),
      );
      expect(
        compact,
        contains(
          'grant select, insert, update, delete on '
          'public.default_role_catalog_versions to forge_admin',
        ),
      );
      expect(
        compact,
        contains(
          'revoke all on public.default_role_catalog_versions from public',
        ),
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

    test('uses idempotent DDL (if not exists on every CREATE)', () {
      expect(
        normalized,
        contains('create table if not exists public.default_role_catalog'),
      );
      expect(normalized, contains('add column if not exists'));
      expect(
        normalized,
        contains('create unique index if not exists'),
      );
      expect(
        normalized,
        contains('create index if not exists default_role_catalog'),
      );
    });

    test('header cites every authority doc the slice depends on', () {
      // CLAUDE.md authority ordering — every migration must cite the
      // authorities it derives from so future readers see the chain.
      expect(normalized, contains('claude.md'));
      expect(normalized, contains('"rls-ready schema"'));
      expect(normalized, contains('"time guardrails"'));
      expect(
        normalized,
        contains('hardening_rls_and_repository_pattern_contract.md'),
      );
      expect(
        normalized,
        contains('lane_b_features/03_execution_slices.md'),
      );
    });

    test('does NOT UPDATE audit_logs (append-only invariant)', () {
      // The audit_logs_update_lint enforces this in CI; the test pins
      // the local file so a regression is caught even if the lint runs
      // separately.
      final updatePattern = RegExp(
        r'\bupdate\s+(?:only\s+)?(?:public\s*\.\s*)?audit_logs\b',
        caseSensitive: false,
      );
      expect(updatePattern.hasMatch(normalized), isFalse);
    });

    test('does NOT use pg_advisory_lock (banned per V1 lean cut)', () {
      expect(normalized, isNot(contains('pg_advisory_lock')));
    });
  });
}
