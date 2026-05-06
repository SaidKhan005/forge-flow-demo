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

  // V1.F NEW coverage. Existing tests already pin the table shape,
  // bounded window, active-job uniqueness, hot-path indexes, RLS,
  // and lean-cut bans. The tests below close P2 gaps the parent test
  // file explicitly leaves uncovered: foreign-key posture (cascade
  // semantics on connection delete and on tenant delete), the per
  // -column CHECK invariants the contract pins (vendor_id, mode,
  // attempt_count, last_error length cap), and the partial-index
  // status filter that keeps history rows from blocking re-enqueue.
  group('Phase 8 first connection backfill jobs migration (NEW)', () {
    test(
      'cascades the connection FK so a deleted connector_connection '
      'row tears down its history of backfill jobs',
      () {
        expect(
          compact,
          contains(
            'connection_id uuid not null references public.connector_connection(connection_id) on delete cascade',
          ),
        );
      },
    );

    test(
      'composite tenant FK to (operator_id, location_id) -> public.locations '
      'cascades on delete so closing a location does not leave orphan jobs',
      () {
        expect(
          compact,
          contains('foreign key (operator_id, location_id)'),
        );
        expect(
          compact,
          contains('references public.locations(operator_id, location_id)'),
        );
        // Tenant FK cascades on delete; the active-job + history rows
        // travel with the location they belong to.
        final tenantFkSlice = compact.substring(
          compact.indexOf('connector_backfill_jobs_operator_location_fk'),
        );
        expect(tenantFkSlice, contains('on delete cascade'));
      },
    );

    test(
      'pins per-column CHECK invariants the contract calls out so a '
      'silent schema drift is caught in CI',
      () {
        expect(
          normalized,
          contains("char_length(vendor_id) between 1 and 64"),
        );
        expect(
          normalized,
          contains("vendor_id = btrim(vendor_id)"),
        );
        expect(normalized, contains("mode = 'first_backfill'"));
        expect(normalized, contains('attempt_count >= 0'));
        expect(
          normalized,
          contains('char_length(last_error) <= 4096'),
        );
      },
    );

    test(
      'active-job uniqueness index uses a partial WHERE clause on the '
      'pending/running statuses so terminal history rows do not block '
      'a future explicit replay row from being enqueued',
      () {
        // The unique index on (operator_id, connection_id, category,
        // window_start, window_end) is partial: it only applies to
        // active rows. Without the partial filter, a single failed
        // job would forever block the connection from re-enqueueing.
        final indexSlice = compact.substring(
          compact.indexOf('connector_backfill_jobs_active_uq'),
        );
        expect(
          indexSlice.toLowerCase(),
          contains("where status in ('pending', 'running')"),
        );
      },
    );

    test(
      'grants are restricted to service_role and forge_admin and the '
      'public role is revoked, so a future role-leak in the proxy does '
      'not silently pick up backfill-job access',
      () {
        expect(
          normalized,
          contains('revoke all on public.connector_backfill_jobs from public'),
        );
        // No DELETE grant - history rows are never erased; cleanup
        // happens by tenant FK cascade only.
        expect(
          normalized,
          isNot(
            contains(
              'grant delete\n  on public.connector_backfill_jobs',
            ),
          ),
        );
      },
    );
  });
}

String _join(String left, String right) => '$left$right';
