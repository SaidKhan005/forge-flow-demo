import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/202605191830_canonical_fact_projection_retry_jobs.sql',
  );

  group('canonical_fact_projection_retry_jobs migration', () {
    test('declares the durable retry ledger table and payload columns', () {
      expect(
        migrationSql,
        contains(
          'create table if not exists public.canonical_fact_projection_retry_jobs',
        ),
      );
      for (final column in const <String>[
        'job_id uuid primary key default gen_random_uuid()',
        'operator_id uuid not null',
        'location_id uuid not null',
        'restaurant_id text not null',
        'connection_id uuid not null',
        'changed_periods jsonb not null',
        'open_current_fact_maps jsonb not null default',
        'input_hash text not null',
        'fact_count integer not null default 0',
        'attempt_count integer not null default 0',
        'next_attempt_at timestamptz not null default now()',
        'last_error_class text not null',
        'last_error_message text not null',
        'dead_lettered_at timestamptz null',
      ]) {
        expect(migrationSql, contains(column));
      }
    });

    test('pins retry status, category, json, hash, and count checks', () {
      for (final fragment in const <String>[
        "check (category in ('pos', 'labor', 'reservation'))",
        "check (status in ('pending', 'running', 'succeeded', 'dead_lettered'))",
        "check (jsonb_typeof(changed_periods) = 'array')",
        "check (jsonb_typeof(open_current_fact_maps) = 'array')",
        "check (input_hash ~ '^[0-9a-f]{64}\$')",
        'check (fact_count >= 0)',
        'check (attempt_count >= 0)',
      ]) {
        expect(migrationSql, contains(fragment));
      }
    });

    test('uses tenant RLS and operator-leading indexes', () {
      expect(
        migrationSql,
        contains(
          'alter table public.canonical_fact_projection_retry_jobs enable row level security',
        ),
      );
      expect(
        migrationSql,
        contains(
          'operator_id = public.app_current_operator() and location_id = public.app_current_location()',
        ),
      );
      for (final index in const <String>[
        'on public.canonical_fact_projection_retry_jobs (operator_id, location_id, status, next_attempt_at, created_at)',
        'on public.canonical_fact_projection_retry_jobs (operator_id, connection_id, created_at desc)',
        'on public.canonical_fact_projection_retry_jobs (operator_id, input_hash)',
      ]) {
        expect(migrationSql, contains(index));
      }
    });
  });
}

String _readSqlNormalized(String path) {
  return File(
    path,
  ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}
