import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql';

void main() {
  final sql = File(_migrationPath).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = sql.toLowerCase();
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 first connection backfill jobs migration', () {
    test('creates only the durable server-side backfill job table', () {
      expect(
        normalized,
        contains('create table if not exists public.connector_backfill_jobs'),
      );
      expect(
        normalized,
        isNot(contains(_join('open_shift_snapshots_', 'cache'))),
      );
      expect(normalized, isNot(contains('mobile_backfill')));
    });

    test('stores operator, location, connection, category, status, cursor, '
        'attempt, lease, and timestamps', () {
      for (final fragment in <String>[
        'operator_id uuid not null',
        'location_id uuid not null',
        'connection_id uuid not null',
        'vendor_id text not null',
        "category in ('pos', 'labor', 'reservation')",
        "mode text not null default 'first_backfill'",
        "status text not null default 'pending'",
        "status in ('pending', 'running', 'succeeded', 'failed')",
        'cursor_token text',
        'char_length(cursor_token) between 1 and 2048',
        'last_modified_seen timestamptz',
        'attempt_count integer not null default 0',
        'worker_id text',
        'char_length(worker_id) between 1 and 128',
        'claimed_at timestamptz',
        'completed_at timestamptz',
        'created_at timestamptz not null default now()',
        'updated_at timestamptz not null default now()',
      ]) {
        expect(normalized, contains(fragment));
      }
    });

    test('bounds the first-backfill window to 60 days', () {
      expect(compact, contains('window_end > window_start'));
      expect(
        compact,
        contains("window_end <= window_start + interval '60 days'"),
      );
    });

    test('enforces one active job per connection/category/window', () {
      expect(
        compact,
        contains(
          'create unique index if not exists connector_backfill_jobs_active_uq',
        ),
      );
      expect(
        compact,
        contains(
          'on public.connector_backfill_jobs ( operator_id, connection_id, category, window_start, window_end )',
        ),
      );
      expect(compact, contains("where status in ('pending', 'running')"));
    });

    test('keeps hot-path indexes operator leading', () {
      expect(
        compact,
        contains(
          'on public.connector_backfill_jobs ( operator_id, location_id, status, claimed_at, created_at )',
        ),
      );
      expect(
        compact,
        contains(
          'on public.connector_backfill_jobs ( operator_id, connection_id, category, status, updated_at desc )',
        ),
      );
    });

    test('uses wrapper-only tenant RLS and scoped grants', () {
      expect(
        normalized,
        contains(
          'alter table public.connector_backfill_jobs enable row level security',
        ),
      );
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
        contains(
          'grant select, insert, update\n  on public.connector_backfill_jobs to service_role',
        ),
      );
      expect(
        normalized,
        contains(
          'grant select, insert, update\n  on public.connector_backfill_jobs to forge_admin',
        ),
      );
    });

    test('does not introduce timezone-naive timestamps or banned lean-cut '
        'surfaces', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
      for (final banned in <String>[
        _join('k', 'ms'),
        _join('parse_', 'warnings'),
        _join('parse_', 'partial'),
        _join('kstrictreplay', 'fiveminute'),
        _join('pg_', 'advisory_lock'),
        _join('sigterm', 'drainhandler'),
        _join('inboundwebhook', 'dlqtile'),
        _join('raw_payload_', 'partition'),
        _join('pg_', 'partman_raw'),
      ]) {
        expect(normalized, isNot(contains(banned)));
      }
    });
  });
}

String _join(String left, String right) => '$left$right';
