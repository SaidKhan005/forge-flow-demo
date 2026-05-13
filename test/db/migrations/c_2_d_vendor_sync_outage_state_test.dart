// Lane C C-2-D — migration shape test for vendor_sync_outage_state.
//
// Pins the persistence-shape contract for the new outage-state table
// + RLS posture + operator-leading index. The test reads the raw SQL
// and asserts the presence (or absence) of structural markers without
// running Postgres; the migration body is the source of truth.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql';

/// Strip SQL line comments (`-- …`) so structural assertions that look
/// for statement keywords (GRANT, DROP, etc.) do not match prose in
/// the migration's header / inline rationale comments.
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
  final sql =
      File(_migrationPath).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = sql.toLowerCase();
  final compact = sql.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  final statements = _stripSqlLineComments(sql).toLowerCase();

  group('C-2-D vendor_sync_outage_state migration', () {
    test('creates vendor_sync_outage_state table (idempotent)', () {
      expect(
        compact,
        contains(
          'create table if not exists public.vendor_sync_outage_state',
        ),
      );
    });

    test('table is operator-scoped (operator_id + location_id NOT NULL)', () {
      expect(compact, contains('operator_id uuid not null'));
      expect(compact, contains('location_id uuid not null'));
    });

    test('connection_id is primary key (one outage per connection)', () {
      expect(compact, contains('primary key (connection_id)'));
    });

    test('outage_started_at is TIMESTAMPTZ (CLAUDE.md time guardrail)', () {
      expect(compact, contains('outage_started_at timestamptz not null'));
    });

    test('notified_at is nullable TIMESTAMPTZ (load-bearing dedupe flag)',
        () {
      // notified_at IS NOT NULL is the load-bearing predicate the
      // detector uses for "email already landed for this outage". A
      // NOT NULL DEFAULT now() would break the detection state
      // machine; pin the shape.
      expect(compact, contains('notified_at timestamptz null'));
    });

    test('consecutive_failure_count is smallint with CHECK >= 0', () {
      expect(compact, contains('consecutive_failure_count smallint not null'));
      expect(compact, contains('check (consecutive_failure_count >= 0)'));
    });

    test('connection_id FK CASCADEs on connector_connection delete', () {
      expect(
        compact,
        contains(
          'connection_id uuid not null '
          'references public.connector_connection(connection_id) '
          'on delete cascade',
        ),
      );
    });

    test('operator + location FK matches sibling fact-table pattern', () {
      expect(
        compact,
        contains(
          'foreign key (operator_id, location_id) '
          'references public.locations(operator_id, location_id) '
          'on delete cascade',
        ),
      );
    });

    test('B-tree index leads with operator_id (RLS perf discipline)', () {
      // CLAUDE.md "Every fact-table B-tree index leads with operator_id".
      expect(
        compact,
        contains(
          'create index if not exists vendor_sync_outage_state_operator_idx '
          'on public.vendor_sync_outage_state (operator_id, connection_id)',
        ),
      );
    });

    test('row-level security is enabled', () {
      expect(
        compact,
        contains(
          'alter table public.vendor_sync_outage_state '
          'enable row level security',
        ),
      );
    });

    test('per-tenant RLS policy with USING + WITH CHECK', () {
      // Mirror sibling pattern (connector_sync_log etc.): operator_id +
      // location_id clamp under app_current_operator/location wrappers.
      expect(
        compact,
        contains('drop policy if exists "vendor_sync_outage_state_per_tenant"'),
      );
      expect(
        compact,
        contains(
          'create policy "vendor_sync_outage_state_per_tenant" '
          'on public.vendor_sync_outage_state for all to service_role',
        ),
      );
      expect(compact, contains('public.app_current_operator()'));
      expect(compact, contains('public.app_current_location()'));
    });

    test('GRANT revokes default public + grants service_role + forge_admin',
        () {
      expect(
        compact,
        contains('revoke all on public.vendor_sync_outage_state from public'),
      );
      expect(
        compact,
        contains(
          'grant select, insert, update, delete on '
          'public.vendor_sync_outage_state to service_role',
        ),
      );
      expect(
        compact,
        contains(
          'grant select, insert, update, delete on '
          'public.vendor_sync_outage_state to forge_admin',
        ),
      );
    });

    test('migration is pure additive expand (no destructive ops)', () {
      // No DROP TABLE / DROP COLUMN / DELETE / ALTER COLUMN TYPE.
      // DROP POLICY IF EXISTS is permitted (sibling pattern) before
      // CREATE POLICY for idempotency.
      final dropTablePattern = RegExp(
        r'\bdrop\s+(?:table|column|index|constraint)\b',
        caseSensitive: false,
      );
      expect(dropTablePattern.hasMatch(statements), isFalse);
      expect(statements, isNot(contains('delete from')));
      expect(statements, isNot(contains('alter column')));
    });

    test('respects time + lock guardrails', () {
      expect(normalized, contains('set local statement_timeout'));
      expect(normalized, contains('set local lock_timeout'));
    });

    test('migration is wrapped in a transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('uses idempotent DDL (if not exists on table + index)', () {
      expect(normalized, contains('create table if not exists'));
      expect(normalized, contains('create index if not exists'));
    });

    test('header cites authority docs', () {
      expect(normalized, contains('claude.md'));
      expect(normalized, contains('wave_execution_ledger.md'));
      expect(
        normalized,
        contains('c_2_email_template_wire_or_delete_decisions.md'),
      );
      expect(
        normalized,
        contains('202605131700_c_1a_email_event_provider_id.sql'),
      );
      expect(
        normalized,
        contains('202605040000_phase_8_0_integration_framework.sql'),
      );
    });

    test('does NOT UPDATE audit_logs (append-only invariant)', () {
      final updatePattern = RegExp(
        r'\bupdate\s+(?:only\s+)?(?:public\s*\.\s*)?audit_logs\b',
        caseSensitive: false,
      );
      expect(updatePattern.hasMatch(statements), isFalse);
    });

    test('column comments document the contract', () {
      expect(
        normalized,
        contains('comment on table public.vendor_sync_outage_state'),
      );
      expect(
        normalized,
        contains(
          'comment on column public.vendor_sync_outage_state.outage_started_at',
        ),
      );
      expect(
        normalized,
        contains(
          'comment on column public.vendor_sync_outage_state.notified_at',
        ),
      );
    });

    test('does NOT touch existing tables (additive expand only)', () {
      // No ALTER TABLE on existing tables — only the CREATE TABLE for
      // the new relation. The sibling tables (connector_sync_log,
      // connector_connection, etc.) stay untouched.
      final alterPattern = RegExp(
        r'\balter\s+table\s+public\.(connector_sync_log|connector_connection|'
        r'connector_sync_watermark|email_outbox|email_event|locations)\b',
        caseSensitive: false,
      );
      expect(alterPattern.hasMatch(statements), isFalse);
    });
  });
}
