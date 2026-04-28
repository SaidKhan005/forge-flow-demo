// Phase 9.0Σ.k — rollups foundation tests.
//
// Local framework slice (no live database). Five groups:
//
//   1. Migration files exist with the pre-assigned 202604280010_a/b/c
//      slot names so the rerun-safe contract holds.
//
//   2. aggregation_state migration shape — composite PK
//      (rollup_table, grain), watermark, lease, retry, status,
//      observability columns, locked grain CHECK, no
//      TIMESTAMP WITHOUT TIME ZONE.
//
//   3. Physical rollup tables migration shape — all seven grains
//      exist as `create table` (NOT materialized views), wrapper-
//      based RLS, tenant-leading indexes, freshness/status fields,
//      deterministic UPSERT keys with NULLS NOT DISTINCT, no
//      TIMESTAMP WITHOUT TIME ZONE, partition hooks, grants.
//
//   4. pg_cron migration shape — extension creation,
//      hot/cold-path SQL functions, idempotent unschedule-then-
//      schedule pattern, 60s/300s cadence.
//
//   5. RollupWorker fake-Postgres tests — claim bounded work, success
//      advances watermark, failure does NOT advance and records
//      reason, stale sweep flips status, ON CONFLICT shape matches
//      migration unique index.
//
//   6. RLS lint against the two new operator-scoped migrations
//      (aggregation_state has no RLS; rollup_tables has seven
//      policies that must all pass the wrapper-only lint).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/rollups/rollup_models.dart';
import 'package:forge_and_flow/services/rollups/rollup_worker.dart';

import '../tool/rls_policy_lint.dart';

const String _operatorAId = '11111111-1111-1111-1111-111111111111';
const String _orgUnitId = '22222222-2222-2222-2222-222222222222';
const String _locationId = '33333333-3333-3333-3333-333333333333';

void main() {
  // ─── 1. Migration files exist with the pre-assigned slot names ────

  group('Phase 9.0Σ.k migration files', () {
    test('aggregation_state migration uses the pre-assigned 202604280010_a '
        'slot', () {
      expect(
        File(
          'db/migrations/'
          '202604280010_a_phase_9_0sigma_k_aggregation_state.sql',
        ).existsSync(),
        isTrue,
      );
    });

    test('rollup_tables migration uses the pre-assigned 202604280010_b '
        'slot', () {
      expect(
        File(
          'db/migrations/'
          '202604280010_b_phase_9_0sigma_k_rollup_tables.sql',
        ).existsSync(),
        isTrue,
      );
    });

    test('pg_cron_jobs migration uses the pre-assigned 202604280010_c '
        'slot', () {
      expect(
        File(
          'db/migrations/'
          '202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql',
        ).existsSync(),
        isTrue,
      );
    });
  });

  // ─── 2. aggregation_state migration shape ─────────────────────────

  group('Phase 9.0Σ.k aggregation_state migration shape', () {
    final sql = _readSqlNormalized(
      'db/migrations/'
      '202604280010_a_phase_9_0sigma_k_aggregation_state.sql',
    );

    test('runs in a single transaction (begin/commit pair) — rerun-safe',
        () {
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });

    test('declares aggregation_state with the locked column shape', () {
      expect(
        sql,
        contains('create table if not exists public.aggregation_state'),
      );
      expect(sql, contains('rollup_table text not null'));
      expect(sql, contains('grain text not null'));
      expect(sql, contains('last_processed_seq bigint not null default 0'));
      expect(sql, contains('updated_at timestamptz not null default now()'));
    });

    test('composite PK is exactly (rollup_table, grain) per Q3.1', () {
      expect(sql, contains('primary key (rollup_table, grain)'));
    });

    test('grain CHECK enforces the Q3.3 locked set (and only that set)', () {
      expect(sql, contains('aggregation_state_grain_check'));
      // Each grain literal MUST be present.
      for (final grain in const <String>[
        "'daypart'",
        "'business_day'",
        "'week'",
        "'accounting_period'",
        "'month'",
        "'quarter'",
        "'year'",
      ]) {
        expect(
          sql,
          contains(grain),
          reason: 'aggregation_state grain CHECK must include $grain',
        );
      }
      // Hourly/minute summaries are explicitly excluded by Q3.3 — a
      // typo that snuck in `'hour'` would slip past the column-shape
      // test above, so guard the negative case directly.
      expect(sql, isNot(contains("'hour'")));
      expect(sql, isNot(contains("'minute'")));
    });

    test('lease + retry + status + rebuild observability columns exist '
        '(Q3.9 + Q3.10 + Rollups conditional-pass leasing gate)', () {
      expect(sql, contains('lease_owner text null'));
      expect(sql, contains('leased_until timestamptz null'));
      expect(sql, contains('attempt_count integer not null default 0'));
      expect(sql, contains('last_error_at timestamptz null'));
      expect(sql, contains('last_error text null'));
      expect(sql, contains('last_run_started_at timestamptz null'));
      expect(sql, contains('last_run_completed_at timestamptz null'));
      expect(sql, contains("last_run_status text not null default 'idle'"));
      // Rebuild bookkeeping per Q3.8.
      expect(sql, contains('rebuild_in_progress boolean not null default false'));
      expect(sql, contains('rebuild_started_at timestamptz null'));
      expect(sql, contains('rebuild_target_rule_version text null'));
      expect(sql, contains('rebuild_scope text null'));
    });

    test('last_run_status CHECK lists every Q3.7/Q3.9 transition state', () {
      for (final status in const <String>[
        "'idle'",
        "'leased'",
        "'succeeded'",
        "'failed'",
        "'stale'",
        "'rebuilding'",
      ]) {
        expect(sql, contains(status));
      }
    });

    test('TIMESTAMP WITHOUT TIME ZONE is forbidden in operator-scoped '
        'tables (CLAUDE.md storage rule). aggregation_state is internal '
        'infrastructure but follows the same rule for cross-region '
        'consistency.', () {
      expect(sql, isNot(contains('timestamp without time zone')));
    });

    test('forge_admin holds the DML grant (worker runs through '
        'BYPASSRLS — internal infra, not operator-scoped)', () {
      expect(
        sql,
        contains(
          'grant select, insert, update, delete on public.aggregation_state '
          'to forge_admin',
        ),
      );
    });
  });

  // ─── 3. Physical rollup tables migration shape ────────────────────

  group('Phase 9.0Σ.k rollup_tables migration shape', () {
    final sql = _readSqlNormalized(
      'db/migrations/'
      '202604280010_b_phase_9_0sigma_k_rollup_tables.sql',
    );

    test('runs in a single transaction (begin/commit pair) — rerun-safe',
        () {
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });

    test('declares all seven Q3.3 grain tables AS PHYSICAL TABLES, '
        'NOT materialized views (Q3.2 lock — operator-facing truth '
        'must be a real table)', () {
      for (final grain in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        expect(
          sql,
          contains('create table if not exists public.$grain'),
          reason: '$grain must be a physical table per Q3.2',
        );
      }
      // Materialized views are allowed only for internal/admin
      // helper analytics per Q3.2 — none of the operator-facing
      // grains may be exposed as materialized views.
      expect(sql, isNot(contains('create materialized view')));
    });

    test('every grain table carries the Q3.2 column contract '
        '(operator_id + scoped_org_unit_id + optional location_id + '
        'period/business-date + metric_family + dimensions + metrics + '
        'source watermark + rule_version + computed_at + freshness)', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        // Tenant scope.
        expect(
          sql,
          contains('create table if not exists public.$tbl (\n'
              '  operator_id uuid not null references public.operators('
              'operator_id)\n'
              '    on delete cascade,\n'
              '  scoped_org_unit_id uuid not null,\n'
              '  location_id uuid null,'),
          reason: '$tbl must declare the locked tenant-scope columns',
        );
        // Period.
        expect(
          sql,
          contains('  period_start timestamptz not null,\n'
              '  period_end timestamptz not null,\n'
              '  business_date date not null,'),
          reason: '$tbl must carry period_start/period_end/business_date',
        );
        // Metric family + dimensions + metrics + source watermark +
        // rule_version + computed_at + freshness.
        expect(sql, contains('  metric_family text not null'));
        expect(sql, contains("  dimensions jsonb not null default '{}'::jsonb"));
        expect(sql, contains("  metrics jsonb not null default '{}'::jsonb"));
        expect(
          sql,
          contains('  source_watermark_seq bigint not null default 0'),
        );
        expect(sql, contains('  source_watermark_at timestamptz null'));
        expect(
          sql,
          contains("  rule_version text not null default 'v1'"),
        );
        expect(
          sql,
          contains('  computed_at timestamptz not null default now()'),
        );
        expect(
          sql,
          contains("  freshness_status text not null default 'fresh'"),
        );
        expect(sql, contains('  last_failure_at timestamptz null'));
        expect(sql, contains('  last_failure_reason text null'));
      }
    });

    test('only the daypart grain carries the daypart column (fineest '
        'sub-day grain is daypart per Q3.3)', () {
      expect(sql, contains('  daypart text not null'));
      // Spot-check: the daypart column appears inside the
      // rollup_daypart block, not inside any of the others.
      final dayPartTblIdx = sql.indexOf('public.rollup_daypart');
      final dayPartColIdx = sql.indexOf('  daypart text not null');
      expect(
        dayPartColIdx,
        greaterThan(dayPartTblIdx),
        reason: 'daypart column must live on rollup_daypart',
      );
    });

    test('every grain table is partitioned by range(period_start) with a '
        'default partition (scalability-audit Rollups conditional-pass '
        'gate — partition hook in place)', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        expect(
          sql,
          contains(') partition by range (period_start);'),
          reason: 'partition-by-range hook is required for rollup tables',
        );
        expect(
          sql,
          contains('create table if not exists public.${tbl}_default\n'
              '  partition of public.$tbl default;'),
          reason: '$tbl must have a default partition that catches all '
              'rows until per-period partitions are carved out',
        );
      }
    });

    test('deterministic UPSERT key uses NULLS NOT DISTINCT (Q3.6 + null '
        'location_id collapse)', () {
      // Each grain table needs its own unique index; assert all
      // seven name-collisions because the conflict-resolution
      // contract depends on the index being present and named
      // <table>_uq.
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        expect(
          sql,
          contains('create unique index if not exists ${tbl}_uq'),
          reason: '$tbl needs a uniquely-named UPSERT key index',
        );
      }
      // Every unique index uses NULLS NOT DISTINCT.
      expect(
        RegExp(r'\)\s*nulls not distinct;').allMatches(sql).length,
        equals(7),
        reason: 'every grain unique index must use NULLS NOT DISTINCT '
            'so location_id NULL collapses to one conflict target',
      );
    });

    test('every B-tree index leads with operator_id (CLAUDE.md RLS '
        'performance discipline)', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        // Tenant-leading hot-read index.
        expect(
          sql,
          contains('create index if not exists ${tbl}_tenant_period_idx\n'
              '  on public.$tbl (\n'
              '    operator_id, scoped_org_unit_id, location_id, '
              'business_date desc\n'
              '  );'),
          reason: '$tbl tenant_period index must lead with operator_id',
        );
      }
    });

    test('TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped tables '
        '(CLAUDE.md storage rule)', () {
      expect(sql, isNot(contains('timestamp without time zone')));
    });

    test('every grain table has composite FKs binding scoped_org_unit_id '
        'and location_id back to the same operator_id (P2-1 fix from '
        'the Codex review — without these a row could carry an '
        'operator_id pointing at one tenant while scoped_org_unit_id / '
        'location_id belongs to another)', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        // Each constraint name is table-prefixed so PG accepts all
        // 14 constraints in the same schema.
        expect(
          sql,
          contains('constraint ${tbl}_scope_org_unit_fk\n'
              '    foreign key (operator_id, scoped_org_unit_id)\n'
              '    references public.org_units(operator_id, id)\n'
              '    on delete cascade'),
          reason: '$tbl must bind (operator_id, scoped_org_unit_id) to '
              'org_units(operator_id, id) so cross-tenant org_unit '
              'pointers are rejected at the database layer',
        );
        expect(
          sql,
          contains('constraint ${tbl}_scope_location_fk\n'
              '    foreign key (operator_id, location_id)\n'
              '    references public.locations(operator_id, location_id)\n'
              '    on delete cascade'),
          reason: '$tbl must bind (operator_id, location_id) to '
              'locations(operator_id, location_id) — MATCH SIMPLE '
              '(default) keeps NULL location_id allowed for hierarchy '
              'aggregates while still rejecting cross-tenant '
              '(operator_a, location_b) mismatches',
        );
      }
    });

    test('every grain table has RLS enabled with a wrapper-using policy '
        '(item 4 / 9.0Σ.b)', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        expect(
          sql,
          contains('alter table public.$tbl enable row level security'),
        );
        expect(
          sql,
          contains('create policy "${tbl}_per_tenant"'),
        );
      }
      // Predicate must use the wrapper, not bare current_setting.
      expect(
        sql,
        contains('operator_id = public.app_current_operator()'),
      );
      expect(
        sql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('grants follow the locked posture — service_role SELECT only, '
        'forge_admin full DML', () {
      for (final tbl in const <String>[
        'rollup_daypart',
        'rollup_business_day',
        'rollup_week',
        'rollup_accounting_period',
        'rollup_month',
        'rollup_quarter',
        'rollup_year',
      ]) {
        expect(
          sql,
          contains('grant select on public.$tbl to service_role'),
          reason: 'service_role reads dashboards — SELECT only',
        );
        expect(
          sql,
          contains(
            'grant select, insert, update, delete on public.$tbl '
            'to forge_admin',
          ),
          reason: 'forge_admin runs the worker + admin paths',
        );
      }
    });
  });

  // ─── 4. pg_cron migration shape ───────────────────────────────────

  group('Phase 9.0Σ.k pg_cron_jobs migration shape', () {
    final sql = _readSqlNormalized(
      'db/migrations/'
      '202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql',
    );

    test('creates the pg_cron extension idempotently', () {
      expect(sql, contains('create extension if not exists pg_cron'));
    });

    test('hot-path kickoff function emits pg_notify ONLY (P1-1 fix — '
        'taking the lease here would starve the Dart worker) and names '
        'the locked grain set (daypart + business_day) in the envelope',
        () {
      expect(
        sql,
        contains(
          'create or replace function public.rollup_run_hot_path()',
        ),
      );
      // Wake-up signal must be NOTIFY-only.
      expect(
        sql,
        contains("perform pg_notify(\n    'rollups_tick',"),
      );
      expect(sql, contains("'path', 'hot'"));
      expect(
        sql,
        contains("json_build_array('daypart', 'business_day')"),
      );
      // P1-1 negative guard: the cron path MUST NOT call the lease
      // primitive itself. Match a complete-token regex so a future
      // helper named e.g. `rollup_acquire_lease_v2` does not slip
      // past — the test only flags the exact 4-arg primitive that
      // owns the lease state machine.
      final hotPathBody = _extractFunctionBody(sql, 'rollup_run_hot_path');
      expect(
        hotPathBody.contains('rollup_acquire_lease'),
        isFalse,
        reason: 'P1-1: hot-path cron MUST NOT take the lease — only '
            'the Dart worker may. Found: $hotPathBody',
      );
    });

    test('cold-path kickoff function emits pg_notify ONLY (P1-1) and '
        'names the locked cold grain set (week + accounting_period + '
        'month + quarter + year)', () {
      expect(
        sql,
        contains(
          'create or replace function public.rollup_run_cold_path()',
        ),
      );
      expect(sql, contains("'path', 'cold'"));
      expect(
        sql,
        contains(
          "json_build_array(\n"
          "        'week', 'accounting_period', 'month', 'quarter', 'year'\n"
          "      )",
        ),
      );
      final coldPathBody = _extractFunctionBody(sql, 'rollup_run_cold_path');
      expect(
        coldPathBody.contains('rollup_acquire_lease'),
        isFalse,
        reason: 'P1-1: cold-path cron MUST NOT take the lease — only '
            'the Dart worker may. Found: $coldPathBody',
      );
    });

    test('declares the rollup_acquire_lease primitive (worker leasing '
        'gate from the scalability audit)', () {
      expect(
        sql,
        contains('create or replace function public.rollup_acquire_lease'),
      );
      // Lease take must be conditional — a still-valid lease is
      // never re-claimed.
      expect(sql, contains('leased_until is null or leased_until < v_now'));
      // P1-3 fix: rebuild guards prevent normal incremental advances
      // from overwriting a Q3.8 rebuild row.
      expect(
        sql,
        contains('and rebuild_in_progress = false'),
      );
      expect(
        sql,
        contains("and last_run_status <> 'rebuilding'"),
      );
      // Bootstrap row on first call so the worker doesn't need a
      // separate seed migration.
      expect(
        sql,
        contains(
          'insert into public.aggregation_state (rollup_table, grain)\n'
          '  values (p_rollup_table, p_grain)\n'
          '  on conflict (rollup_table, grain) do nothing;',
        ),
      );
    });

    test('schedule registration is idempotent — unschedule any existing '
        'job with the same name BEFORE schedule(...) so a re-run does '
        'not raise a unique_violation', () {
      // The hot-path schedule.
      expect(
        sql,
        contains(
          "select jobid from cron.job where jobname = 'forge_rollup_hot_path'",
        ),
      );
      expect(sql, contains('perform cron.unschedule(v_jobid)'));
      expect(
        sql,
        contains(
          "perform cron.schedule(\n"
          "    'forge_rollup_hot_path',\n"
          "    '60 seconds',\n"
          "    'select public.rollup_run_hot_path();'\n"
          "  );",
        ),
        reason: 'hot path must be scheduled at the Q3.1-locked 60s '
            'cadence calling the hot-path kickoff function',
      );
      // The cold-path schedule.
      expect(
        sql,
        contains(
          "select jobid from cron.job where jobname = 'forge_rollup_cold_path'",
        ),
      );
      expect(
        sql,
        contains(
          "perform cron.schedule(\n"
          "    'forge_rollup_cold_path',\n"
          "    '300 seconds',\n"
          "    'select public.rollup_run_cold_path();'\n"
          "  );",
        ),
        reason: 'cold path must be scheduled at the Q3.1-locked 300s '
            'cadence calling the cold-path kickoff function',
      );
    });

    test('grants execute on the kickoff functions to forge_admin '
        '(pg_cron runs as the database owner; forge_admin executes the '
        'lease/upsert primitives)', () {
      for (final fn in const <String>[
        'public.rollup_acquire_lease(text, text, text, integer)',
        'public.rollup_run_hot_path()',
        'public.rollup_run_cold_path()',
      ]) {
        expect(
          sql,
          contains('grant execute on function $fn'),
          reason: '$fn must be executable by forge_admin',
        );
      }
    });
  });

  // ─── 5. RollupWorker fake-Postgres tests ─────────────────────────

  group('RollupWorker (fake Postgres)', () {
    test('grain enum has the seven locked Q3.3 names + correct sqlNames + '
        'hot/cold split', () {
      expect(RollupGrain.values, hasLength(7));
      expect(RollupGrain.daypart.sqlName, equals('daypart'));
      expect(RollupGrain.businessDay.sqlName, equals('business_day'));
      expect(RollupGrain.week.sqlName, equals('week'));
      expect(
        RollupGrain.accountingPeriod.sqlName,
        equals('accounting_period'),
      );
      expect(RollupGrain.month.sqlName, equals('month'));
      expect(RollupGrain.quarter.sqlName, equals('quarter'));
      expect(RollupGrain.year.sqlName, equals('year'));

      // Hot-path = daypart + business_day; everything else is cold.
      expect(RollupGrain.daypart.isHotPath, isTrue);
      expect(RollupGrain.businessDay.isHotPath, isTrue);
      expect(RollupGrain.week.isHotPath, isFalse);
      expect(RollupGrain.accountingPeriod.isHotPath, isFalse);
      expect(RollupGrain.month.isHotPath, isFalse);
      expect(RollupGrain.quarter.isHotPath, isFalse);
      expect(RollupGrain.year.isHotPath, isFalse);

      // fromSqlName round-trips every grain.
      for (final grain in RollupGrain.values) {
        expect(RollupGrain.fromSqlName(grain.sqlName), equals(grain));
      }
      // Unknown literal returns null (worker treats as unrecoverable).
      expect(RollupGrain.fromSqlName('hour'), isNull);
    });

    test('claimBatch calls rollup_acquire_lease + reads aggregation_state '
        'and projects the snapshot', () async {
      final fake = _FakeSystemRunner(
        canned: <_CannedResponse>[
          // First call — acquire lease returns true.
          _CannedResponse(rows: <PostgresRow>[
            <String, Object?>{'acquired': true},
          ]),
          // Second call — read aggregation_state row.
          _CannedResponse(rows: <PostgresRow>[
            <String, Object?>{
              'rollup_table': 'rollup_daypart',
              'grain': 'daypart',
              'last_processed_seq': 1042,
              'last_run_status': 'leased',
              'attempt_count': 0,
              'lease_owner': 'host:1',
              'leased_until': DateTime.utc(2026, 4, 28, 12, 5),
            },
          ]),
        ],
      );
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final snapshot = await worker.claimBatch(grain: RollupGrain.daypart);

      expect(snapshot, isNotNull);
      expect(snapshot!.rollupTable, equals('rollup_daypart'));
      expect(snapshot.grain, equals(RollupGrain.daypart));
      expect(snapshot.lastProcessedSeq, equals(1042));

      // Two SQL calls in one runAsSystem.
      expect(fake.calls, hasLength(1));
      final call = fake.calls.single;
      expect(call.reason, equals('rollups.daypart.claim'));
      expect(call.queries, hasLength(2));
      expect(call.queries[0], contains('rollup_acquire_lease'));
      expect(call.queryParams[0]['rollup_table'], equals('rollup_daypart'));
      expect(call.queryParams[0]['grain'], equals('daypart'));
      expect(call.queryParams[0]['lease_owner'], equals('host:1'));
      expect(call.queryParams[0]['lease_seconds'], equals(300));
      expect(call.queries[1], contains('from public.aggregation_state'));
    });

    test('claimBatch returns null when another worker holds the lease',
        () async {
      final fake = _FakeSystemRunner(
        canned: <_CannedResponse>[
          _CannedResponse(rows: <PostgresRow>[
            <String, Object?>{'acquired': false},
          ]),
        ],
      );
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final snapshot = await worker.claimBatch(
        grain: RollupGrain.businessDay,
      );
      expect(snapshot, isNull);
      // Only the lease-take query ran; the state read was skipped.
      expect(fake.calls.single.queries, hasLength(1));
    });

    test('flushBatch UPSERTs each row and advances last_processed_seq '
        'after success — Q3.6 idempotency', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_daypart',
          grain: RollupGrain.daypart,
          lastProcessedSeq: 1000,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 1000,
        toSeqInclusive: 1050,
        maxRows: 5000,
      );
      final row = RollupUpsertRow(
        grain: RollupGrain.daypart,
        operatorId: _operatorAId,
        scopedOrgUnitId: _orgUnitId,
        locationId: _locationId,
        periodStart: DateTime.utc(2026, 4, 28, 16),
        periodEnd: DateTime.utc(2026, 4, 28, 22),
        businessDate: '2026-04-28',
        metricFamily: 'sales',
        dimensions: const <String, Object?>{'channel': 'in_house'},
        metrics: const <String, Object?>{
          'sum_sales': 12345.67,
          'orders': 89,
        },
        sourceWatermarkSeq: 1050,
        sourceWatermarkAt: DateTime.utc(2026, 4, 28, 23),
        ruleVersion: 'v1',
        daypart: 'dinner',
      );
      final result = await worker.flushBatch(
        batch: batch,
        rows: <RollupUpsertRow>[row],
      );

      expect(result.success, isTrue);
      expect(result.rowsUpserted, equals(1));
      expect(result.failureReason, isNull);

      final call = fake.calls.single;
      expect(call.reason, equals('rollups.daypart.flush'));
      // INSERT … ON CONFLICT shape.
      expect(call.executes, hasLength(2));
      final upsertSql = call.executes.first;
      expect(upsertSql, contains('insert into public.rollup_daypart'));
      expect(
        upsertSql,
        contains(
          'on conflict (operator_id, scoped_org_unit_id, location_id, '
          'period_start, daypart, metric_family, dimensions_fingerprint)',
        ),
        reason: 'daypart UPSERT conflict target must include daypart '
            'because the unique index in 202604280010_b includes it',
      );
      // Watermark advance must come AFTER the UPSERT and pin the new
      // high water value.
      final advanceSql = call.executes.last;
      expect(advanceSql, contains('update public.aggregation_state'));
      expect(advanceSql, contains('set last_processed_seq      = @new_seq'));
      expect(advanceSql, contains("last_run_status         = 'succeeded'"));
      expect(call.executeParams.last['new_seq'], equals(1050));
      expect(
        call.executeParams.last['rollup_table'],
        equals('rollup_daypart'),
      );
      // P1-2 CAS guards: watermark advance MUST filter on lease_owner,
      // expected prior watermark, and rebuild_in_progress = false so a
      // stale worker (whose lease expired mid-flight) cannot
      // overwrite progress made by the worker that took over.
      expect(advanceSql, contains('and lease_owner = @worker_owner'));
      expect(
        advanceSql,
        contains('and last_processed_seq = @expected_prior_seq'),
      );
      expect(advanceSql, contains('and rebuild_in_progress = false'));
      expect(call.executeParams.last['worker_owner'], equals('host:1'));
      expect(call.executeParams.last['expected_prior_seq'], equals(1000));

      // Dimensions / metrics flow through as serialized JSON (matches
      // event_outbox repository pattern; SQL casts back via ::jsonb).
      expect(call.executeParams.first['dimensions'], isA<String>());
      final decoded = jsonDecode(
        call.executeParams.first['dimensions'] as String,
      ) as Map<String, Object?>;
      expect(decoded['channel'], equals('in_house'));
    });

    test('flushBatch throws RollupLeaseLostException when the watermark '
        'UPDATE matches zero rows (P1-2 — stale worker whose lease '
        'expired mid-flight). The throw aborts the outer transaction '
        'so any UPSERTs the stale worker wrote roll back.', () async {
      final fake = _FakeSystemRunner(
        // Simulate the lease being lost: every execute returns 1
        // EXCEPT the watermark UPDATE on aggregation_state, which
        // returns 0 to mimic the CAS predicate not matching.
        executeAffectedRows: (sql) {
          if (sql.contains('update public.aggregation_state')) {
            return 0;
          }
          return 1;
        },
      );
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_daypart',
          grain: RollupGrain.daypart,
          lastProcessedSeq: 1000,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 1000,
        toSeqInclusive: 1050,
        maxRows: 5000,
      );
      final row = RollupUpsertRow(
        grain: RollupGrain.daypart,
        operatorId: _operatorAId,
        scopedOrgUnitId: _orgUnitId,
        locationId: _locationId,
        periodStart: DateTime.utc(2026, 4, 28, 16),
        periodEnd: DateTime.utc(2026, 4, 28, 22),
        businessDate: '2026-04-28',
        metricFamily: 'sales',
        dimensions: const <String, Object?>{},
        metrics: const <String, Object?>{'sum_sales': 1.0},
        sourceWatermarkSeq: 1050,
        sourceWatermarkAt: DateTime.utc(2026, 4, 28, 23),
        ruleVersion: 'v1',
        daypart: 'dinner',
      );
      Object? thrown;
      try {
        await worker.flushBatch(
          batch: batch,
          rows: <RollupUpsertRow>[row],
        );
      } catch (error) {
        thrown = error;
      }
      expect(
        thrown,
        isA<RollupLeaseLostException>(),
        reason: 'lease-lost must surface as RollupLeaseLostException, '
            'not a silent success',
      );
      // Acceptance: the exception carries enough context for the
      // caller to log which grain / worker / watermark was lost.
      final ex = thrown as RollupLeaseLostException;
      expect(ex.grain, equals(RollupGrain.daypart));
      expect(ex.workerOwner, equals('host:1'));
      expect(ex.expectedPriorSeq, equals(1000));
    });

    test('flushBatch on a non-daypart grain omits the daypart column from '
        'the conflict target', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_business_day',
          grain: RollupGrain.businessDay,
          lastProcessedSeq: 0,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 0,
        toSeqInclusive: 100,
        maxRows: 5000,
      );
      final row = RollupUpsertRow(
        grain: RollupGrain.businessDay,
        operatorId: _operatorAId,
        scopedOrgUnitId: _orgUnitId,
        // location_id NULL — hierarchy aggregate. NULLS NOT DISTINCT
        // on the unique index makes the UPSERT conflict-target match.
        periodStart: DateTime.utc(2026, 4, 28),
        periodEnd: DateTime.utc(2026, 4, 29),
        businessDate: '2026-04-28',
        metricFamily: 'labor',
        dimensions: const <String, Object?>{},
        metrics: const <String, Object?>{'labor_pct': 0.27},
        sourceWatermarkSeq: 100,
        sourceWatermarkAt: DateTime.utc(2026, 4, 28, 23),
        ruleVersion: 'v1',
      );
      await worker.flushBatch(batch: batch, rows: <RollupUpsertRow>[row]);

      final upsertSql = fake.calls.single.executes.first;
      expect(upsertSql, contains('insert into public.rollup_business_day'));
      expect(
        upsertSql,
        contains(
          'on conflict (operator_id, scoped_org_unit_id, location_id, '
          'period_start, metric_family, dimensions_fingerprint)',
        ),
      );
      expect(
        upsertSql,
        isNot(contains('daypart')),
        reason: 'non-daypart grains must NOT mention daypart in their '
            'INSERT or conflict target',
      );
    });

    test('flushBatch rejects mixed grains before opening a transaction',
        () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_daypart',
          grain: RollupGrain.daypart,
          lastProcessedSeq: 0,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 0,
        toSeqInclusive: 1,
        maxRows: 100,
      );
      final wrongGrainRow = RollupUpsertRow(
        grain: RollupGrain.week,
        operatorId: _operatorAId,
        scopedOrgUnitId: _orgUnitId,
        periodStart: DateTime.utc(2026, 4, 27),
        periodEnd: DateTime.utc(2026, 5, 4),
        businessDate: '2026-04-27',
        metricFamily: 'sales',
        dimensions: const <String, Object?>{},
        metrics: const <String, Object?>{},
        sourceWatermarkSeq: 1,
        sourceWatermarkAt: DateTime.utc(2026, 4, 28),
        ruleVersion: 'v1',
      );
      await expectLater(
        worker.flushBatch(
          batch: batch,
          rows: <RollupUpsertRow>[wrongGrainRow],
        ),
        throwsArgumentError,
      );
      // No transaction was opened — the guard fires before runAsSystem.
      expect(fake.calls, isEmpty);
    });

    test('flushBatch rejects rows.length > batch.maxRows before opening '
        'a transaction', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_business_day',
          grain: RollupGrain.businessDay,
          lastProcessedSeq: 0,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 0,
        toSeqInclusive: 1,
        maxRows: 1,
      );
      final twoRows = <RollupUpsertRow>[
        RollupUpsertRow(
          grain: RollupGrain.businessDay,
          operatorId: _operatorAId,
          scopedOrgUnitId: _orgUnitId,
          periodStart: DateTime.utc(2026, 4, 28),
          periodEnd: DateTime.utc(2026, 4, 29),
          businessDate: '2026-04-28',
          metricFamily: 'labor',
          dimensions: const <String, Object?>{},
          metrics: const <String, Object?>{},
          sourceWatermarkSeq: 1,
          sourceWatermarkAt: DateTime.utc(2026, 4, 28),
          ruleVersion: 'v1',
        ),
        RollupUpsertRow(
          grain: RollupGrain.businessDay,
          operatorId: _operatorAId,
          scopedOrgUnitId: _orgUnitId,
          periodStart: DateTime.utc(2026, 4, 27),
          periodEnd: DateTime.utc(2026, 4, 28),
          businessDate: '2026-04-27',
          metricFamily: 'labor',
          dimensions: const <String, Object?>{},
          metrics: const <String, Object?>{},
          sourceWatermarkSeq: 1,
          sourceWatermarkAt: DateTime.utc(2026, 4, 28),
          ruleVersion: 'v1',
        ),
      ];
      await expectLater(
        worker.flushBatch(batch: batch, rows: twoRows),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
    });

    test('recordFailure stamps last_error/last_run_status WITHOUT '
        'advancing last_processed_seq (Q3.6 retry semantics)', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_business_day',
          grain: RollupGrain.businessDay,
          lastProcessedSeq: 1000,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 1000,
        toSeqInclusive: 2000,
        maxRows: 100,
      );
      final result = await worker.recordFailure(
        batch: batch,
        reason: 'aggregator threw: bad row at seq 1500',
      );
      expect(result.success, isFalse);
      expect(result.rowsUpserted, equals(0));
      expect(result.failureReason, contains('bad row at seq 1500'));

      final call = fake.calls.single;
      expect(call.reason, equals('rollups.business_day.fail'));
      final failSql = call.executes.single;
      expect(failSql, contains('update public.aggregation_state'));
      expect(failSql, contains("last_run_status       = 'failed'"));
      expect(failSql, contains('attempt_count         = attempt_count + 1'));
      expect(
        failSql,
        isNot(contains('set last_processed_seq')),
        reason: 'failure must NOT advance the watermark — re-run picks '
            'up the same window per Q3.6',
      );
      // P1-2 CAS guards: lease_owner + rebuild_in_progress predicates
      // so a stale worker cannot record a failure on a row that
      // another worker has taken over or that a rebuild now owns.
      expect(failSql, contains('and lease_owner = @worker_owner'));
      expect(failSql, contains('and rebuild_in_progress = false'));
      expect(call.executeParams.single['worker_owner'], equals('host:1'));
      expect(
        call.executeParams.single['reason'],
        equals('aggregator threw: bad row at seq 1500'),
      );
    });

    test('recordFailure throws RollupLeaseLostException when the failure '
        'UPDATE matches zero rows (P1-2 — stale worker after lease '
        'expiry / rebuild took over)', () async {
      final fake = _FakeSystemRunner(
        executeAffectedRows: (sql) =>
            sql.contains('update public.aggregation_state') ? 0 : 1,
      );
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_business_day',
          grain: RollupGrain.businessDay,
          lastProcessedSeq: 1000,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 1000,
        toSeqInclusive: 2000,
        maxRows: 100,
      );
      Object? thrown;
      try {
        await worker.recordFailure(
          batch: batch,
          reason: 'aggregator threw',
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<RollupLeaseLostException>());
      final ex = thrown as RollupLeaseLostException;
      expect(ex.grain, equals(RollupGrain.businessDay));
      expect(ex.workerOwner, equals('host:1'));
      expect(ex.expectedPriorSeq, equals(1000));
    });

    test('recordFailure rejects an empty reason', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      final batch = RollupBatchClaim(
        state: const AggregationStateSnapshot(
          rollupTable: 'rollup_week',
          grain: RollupGrain.week,
          lastProcessedSeq: 0,
          lastRunStatus: 'leased',
          attemptCount: 0,
        ),
        fromSeqExclusive: 0,
        toSeqInclusive: 1,
        maxRows: 1,
      );
      await expectLater(
        worker.recordFailure(batch: batch, reason: '   '),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
    });

    test('markStale flips last_run_status to stale only for rows past the '
        'staleness window AND not currently leased/rebuilding (Q3.7)',
        () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      await worker.markStale(
        grain: RollupGrain.daypart,
        staleAfter: const Duration(seconds: 600),
      );
      final call = fake.calls.single;
      final staleSql = call.executes.single;
      expect(staleSql, contains('update public.aggregation_state'));
      expect(staleSql, contains("set last_run_status = 'stale'"));
      expect(
        staleSql,
        contains("last_run_status not in ('leased', 'rebuilding')"),
      );
      expect(
        staleSql,
        contains("updated_at < now() - (@stale_seconds * interval '1 second')"),
      );
      expect(call.executeParams.single['stale_seconds'], equals(600));
    });

    test('markStale rejects a non-positive staleAfter', () async {
      final fake = _FakeSystemRunner();
      final worker = RollupWorker(
        runAsSystem: fake.run,
        workerOwner: 'host:1',
      );
      await expectLater(
        worker.markStale(
          grain: RollupGrain.daypart,
          staleAfter: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
    });

    test('RollupUpsertRow asserts daypart grain rows carry a daypart '
        'value', () {
      expect(
        () => RollupUpsertRow(
          grain: RollupGrain.daypart,
          operatorId: _operatorAId,
          scopedOrgUnitId: _orgUnitId,
          periodStart: DateTime.utc(2026, 4, 28, 16),
          periodEnd: DateTime.utc(2026, 4, 28, 22),
          businessDate: '2026-04-28',
          metricFamily: 'sales',
          dimensions: const <String, Object?>{},
          metrics: const <String, Object?>{},
          sourceWatermarkSeq: 1,
          sourceWatermarkAt: DateTime.utc(2026, 4, 28),
          ruleVersion: 'v1',
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ─── 6. RLS lint against the rollup migrations ────────────────────

  group('Phase 9.0Σ.k RLS lint', () {
    test('rollup_tables migration passes the policy-aware lint '
        '(every per_tenant policy reads through the wrapper)', () {
      final body = _readSqlNormalized(
        'db/migrations/'
        '202604280010_b_phase_9_0sigma_k_rollup_tables.sql',
      );
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280010_b_phase_9_0sigma_k_rollup_tables.sql': body,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'every rollup_<grain>_per_tenant policy MUST read GUCs '
            'through the 9.0Σ.b wrappers; violations: '
            '${result.violations}',
      );
    });

    test('aggregation_state migration has no CREATE POLICY (internal '
        'infra, not operator-scoped) so the lint passes trivially', () {
      final body = _readSqlNormalized(
        'db/migrations/'
        '202604280010_a_phase_9_0sigma_k_aggregation_state.sql',
      );
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280010_a_phase_9_0sigma_k_aggregation_state.sql': body,
        },
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isTrue);
      expect(body, isNot(contains('create policy')));
      expect(body, isNot(contains('enable row level security')));
    });
  });

  // ─── 7. Rebuild runbook contract ─────────────────────────────────

  group('Phase 9.0Σ.k rebuild runbook', () {
    final runbook = File(
      'docs/phases/phase_9/phase_9_rollups_rebuild_runbook.md',
    );

    setUpAll(() {
      expect(
        runbook.existsSync(),
        isTrue,
        reason: 'rebuild runbook must accompany the worker + migrations',
      );
    });

    test('documents the bounded rebuild scope axes (Q3.8)', () {
      final body = runbook.readAsStringSync();
      // Q3.8: bounded scope = operator + org_unit/location + metric
      // family + date range + grain + rule_version.
      for (final axis in const <String>[
        'operator',
        'org unit',
        'location',
        'metric family',
        'date range',
        'grain',
        'rule_version',
      ]) {
        expect(
          body.toLowerCase(),
          contains(axis.toLowerCase()),
          reason: 'runbook must list rebuild scope axis: $axis',
        );
      }
    });

    test('documents staging → validate → promote sequence (Q3.8) and '
        'failure / freshness behaviour (Q3.9)', () {
      final body = runbook.readAsStringSync().toLowerCase();
      expect(body, contains('staging'));
      expect(body, contains('validate'));
      expect(body, contains('promote'));
      // Q3.9 failure / Q3.7 freshness behaviour.
      expect(body, contains('last known good'));
      expect(body, contains('stale'));
    });
  });
}

/// Read the SQL file and collapse CRLF → LF so multi-line
/// `contains(...)` assertions work on Windows checkouts.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

/// Extract the body of a CREATE OR REPLACE FUNCTION block by name —
/// returns the substring between the `as $$` opener and the
/// matching `$$;` closer. Used by the P1-1 negative guards to scope
/// "must not contain" assertions to a single function body so an
/// unrelated mention elsewhere in the same migration (e.g. the
/// rollup_acquire_lease declaration block) does not produce a
/// false negative.
String _extractFunctionBody(String sql, String functionName) {
  final start = sql.indexOf(
    'create or replace function public.$functionName(',
  );
  if (start < 0) {
    throw StateError(
      'function public.$functionName not found in migration body',
    );
  }
  final asMarker = sql.indexOf('as \$\$', start);
  if (asMarker < 0) {
    throw StateError(
      'function public.$functionName has no `as \$\$` body opener',
    );
  }
  final end = sql.indexOf('\$\$;', asMarker + 5);
  if (end < 0) {
    throw StateError(
      'function public.$functionName has no `\$\$;` body closer',
    );
  }
  return sql.substring(asMarker + 5, end);
}

// ─── Fake runAsSystem implementation for unit tests ────────────────

class _CannedResponse {
  const _CannedResponse({this.rows = const <PostgresRow>[]});
  final List<PostgresRow> rows;
}

class _SystemCall {
  _SystemCall(this.reason);
  final String reason;
  final List<String> queries = <String>[];
  final List<PostgresParameters> queryParams = <PostgresParameters>[];
  final List<String> executes = <String>[];
  final List<PostgresParameters> executeParams = <PostgresParameters>[];
}

class _FakeSystemRunner {
  _FakeSystemRunner({
    this.canned = const <_CannedResponse>[],
    this.executeAffectedRows,
  });

  final List<_CannedResponse> canned;
  int _cannedIdx = 0;

  /// Optional override that returns the affected-row count for a
  /// given execute SQL. The CAS guard tests use this to simulate a
  /// lease-lost watermark UPDATE (returns 0) so the worker's
  /// rollback path runs. When null, every execute returns 1 (the
  /// happy-path default — every UPSERT and the watermark advance
  /// match exactly one row).
  final int Function(String sql)? executeAffectedRows;

  final List<_SystemCall> calls = <_SystemCall>[];

  Future<R> run<R>(
    Future<R> Function(PostgresExecutor exec) body, {
    required String reason,
  }) async {
    final call = _SystemCall(reason);
    calls.add(call);
    final exec = _FakeExecutor(
      onQuery: (sql, params) {
        call.queries.add(sql);
        call.queryParams.add(params);
        if (_cannedIdx >= canned.length) {
          return <PostgresRow>[];
        }
        return canned[_cannedIdx++].rows;
      },
      onExecute: (sql, params) {
        call.executes.add(sql);
        call.executeParams.add(params);
      },
      executeAffectedRows: executeAffectedRows,
    );
    return body(exec);
  }
}

class _FakeExecutor implements PostgresExecutor {
  _FakeExecutor({
    required this.onQuery,
    required this.onExecute,
    this.executeAffectedRows,
  });

  final List<PostgresRow> Function(String sql, PostgresParameters params)
      onQuery;
  final void Function(String sql, PostgresParameters params) onExecute;
  final int Function(String sql)? executeAffectedRows;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    return onQuery(sql, parameters);
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    onExecute(sql, parameters);
    return executeAffectedRows?.call(sql) ?? 1;
  }
}
