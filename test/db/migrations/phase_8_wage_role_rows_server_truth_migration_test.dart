import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql';

String _stripLineComments(String input) {
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(input)) {
    if (line.trimLeft().startsWith('--')) continue;
    buffer.writeln(line);
  }
  return buffer.toString();
}

void main() {
  final rawMigration = File(_migrationPath).readAsStringSync();
  final migration = _stripLineComments(rawMigration);
  final normalized = migration.toLowerCase();
  final compact = normalized.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 wage role rows server truth migration', () {
    test('creates the additive server truth table in one transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
      expect(
        normalized,
        contains('create table if not exists public.wage_role_rows'),
      );
      expect(normalized, contains('create extension if not exists pgcrypto'));
    });

    test(
      'stores tenant scope, wage role fields, mapping metadata, and audit',
      () {
        for (final fragment in <String>[
          'wage_role_row_id uuid primary key default gen_random_uuid()',
          'operator_id uuid not null',
          'location_id uuid not null',
          'restaurant_id text not null',
          'role_name text not null',
          'labor_bucket text not null',
          "labor_bucket in ('foh', 'boh', 'manager')",
          'hourly_rate numeric(12, 4) not null',
          'weighted_hours numeric(12, 4) not null',
          'job_code text',
          'vendor_id text',
          'vendor_role_id text',
          "source text not null default 'operator_manual'",
          'is_active boolean not null default true',
          'effective_at timestamptz not null default now()',
          "metadata jsonb not null default '{}'::jsonb",
          'created_at timestamptz not null default now()',
          'updated_at timestamptz not null default now()',
          'updated_by text',
        ]) {
          expect(normalized, contains(fragment));
        }
      },
    );

    test('uses composite tenant FK and tenant-leading indexes', () {
      expect(compact, contains('foreign key (operator_id, location_id)'));
      expect(
        compact,
        contains('references public.locations(operator_id, location_id)'),
      );
      expect(compact, contains('on delete cascade'));

      for (final indexShape in <String>[
        'on public.wage_role_rows ( operator_id, location_id, restaurant_id, role_name )',
        'on public.wage_role_rows ( operator_id, location_id, labor_bucket, role_name )',
        'on public.wage_role_rows ( operator_id, location_id, updated_at desc, wage_role_row_id )',
        'on public.wage_role_rows ( operator_id, location_id, vendor_id, job_code )',
      ]) {
        expect(compact, contains(indexShape));
      }
    });

    test('uses wrapper-only RLS and scoped grants', () {
      expect(
        normalized,
        contains('alter table public.wage_role_rows enable row level security'),
      );
      expect(
        normalized,
        contains('drop policy if exists "wage_role_rows_per_tenant"'),
      );
      expect(normalized, contains('create policy "wage_role_rows_per_tenant"'));
      expect(
        normalized,
        contains('operator_id = public.app_current_operator()'),
      );
      expect(
        normalized,
        contains('location_id = public.app_current_location()'),
      );
      expect(normalized, isNot(contains('current_setting(')));
      expect(
        normalized,
        contains('revoke all on public.wage_role_rows from public'),
      );
      expect(
        normalized,
        contains(
          'grant select, insert, update on public.wage_role_rows to service_role',
        ),
      );
      expect(
        normalized,
        contains(
          'grant select, insert, update on public.wage_role_rows to forge_admin',
        ),
      );
      expect(normalized, isNot(contains('grant delete')));
    });

    test('is idempotent and avoids timezone-naive columns', () {
      expect(normalized, contains('create table if not exists'));
      expect(normalized, contains('create unique index if not exists'));
      expect(normalized, contains('create index if not exists'));
      expect(normalized, contains('drop policy if exists'));
      expect(normalized, isNot(contains('timestamp without time zone')));
    });

    test('keeps server UUID separate from mobile SQLite integer ids', () {
      expect(normalized, contains('wage_role_row_id uuid primary key'));
      expect(normalized, isNot(contains(' id uuid primary key')));
      expect(rawMigration, contains('Mobile must not treat this as its'));
      expect(rawMigration, contains('SQLite integer id.'));
    });
  });
}
