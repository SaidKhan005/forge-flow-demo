-- P1a — advisor_conversation_log: proxy_requests correlation key +
-- real 30-day retention (Support logs telemetry groundwork).
--
-- Plan: docs/archive/_execution/admin_support_logs_redesign/
--       01_lens_audit_and_implementation_plan.md (phase P1a).
--
-- Origin table: 202604280007_phase_9_0sigma_h_advisor_conversation_log.sql
-- (Phase 9.0Σ.h, item 5). That migration already ships every per-turn
-- telemetry column the Support logs redesign needs (provider / model_id /
-- prompt_token_count / completion_token_count / cost_usd / latency_ms /
-- user_id / operator_id / location_id / usage_class / created_at), plus
-- tiered `retention_class` / `legal_hold` and a per-operator batched purge
-- function `public.advisor_conversation_log_purge(operator_id, before_ts,
-- batch_size)`. A prior audit found two gaps this migration closes:
--
--   GAP 1 — No correlation key to public.proxy_requests. The conversation
--           log's only trace key is its own `id`; the support-log
--           projection cannot join a conversation turn back to the
--           idempotency / proxy-request row that produced it. This
--           migration adds a NULLABLE `request_id uuid` plus an operator-
--           leading join index.
--
--   GAP 2 — The retention purge is a FUNCTION ONLY; nothing schedules it,
--           so rows accumulate forever. Operator decision: 30-day retention
--           for support-log telemetry. This migration ships a cluster-wide
--           batched purge function + a pg_cron schedule consistent with the
--           existing 202604280010_c topology, NEVER touching legal-hold or
--           permanent-retention rows.
--
-- Hard rules carried from CLAUDE.md / the 2026-04-27 Phase 9 lock and the
-- 9.0Σ.h migration this extends:
--   * RLS performance discipline — every B-tree index leads with
--     `operator_id`; the new join index is `(operator_id, location_id,
--     request_id)`. Verified by tool/index_leading_column_lint.dart.
--   * RLS policy bodies read tenant context only through the STABLE
--     LEAKPROOF wrapper functions (`public.app_current_operator()`); bare
--     `current_setting('app.*')` is forbidden by tool/rls_policy_lint.dart.
--     This migration adds NO new CREATE POLICY DDL — the table's existing
--     wrapper-based per-tenant policies (declared in 9.0Σ.h) stay intact
--     and continue to cover the new column unchanged.
--   * Storage rule — `TIMESTAMPTZ` everywhere; no `business_date` column is
--     added (the support UI buckets by relative time/date, not restaurant
--     business day, so the operator-scoped business_date denormalization
--     rule does not apply to this read surface).
--   * NEVER delete a row under legal_hold or in the 'permanent' retention
--     class. The scheduled purge predicate mirrors the existing
--     advisor_conversation_log_purge() function exactly.
--
-- Schema-touching + RLS-adjacent: build-only groundwork. MUST NOT be
-- applied to staging/Production1 without explicit operator approval.

begin;

-- ─── GAP 1: request_id correlation column ──────────────────────────
--
-- `request_id` is the join key onto `public.proxy_requests.request_id`
-- (which is that table's single-column PK, type uuid — see
-- 202604250005_advisor_cloud_foundation.sql). NULLABLE because:
--   * pre-P1a rows have no correlation value (backfill is out of scope);
--   * a system-issued / scheduled advisor turn may write a conversation
--     row without ever minting a proxy_requests idempotency record;
--   * the partitioned table's DEFAULT and child partitions all inherit
--     the new column with NULL for existing rows (no rewrite, no default).
--
-- DELIBERATELY NOT a cross-table FOREIGN KEY. Justification:
--   * Lifecycle mismatch — advisor_conversation_log carries tiered
--     retention ('legal' / 'permanent') and a per-row `legal_hold` freeze
--     that intentionally outlive normal data; proxy_requests is a short-
--     lived idempotency ledger with its own cleanup cadence. A FK with
--     ON DELETE CASCADE would let a proxy_requests cleanup delete a
--     legal-hold conversation row, violating the never-purge-legal-hold
--     invariant. ON DELETE SET NULL would silently sever the correlation
--     key the Support UI needs. NO ACTION / RESTRICT would block
--     proxy_requests cleanup whenever a correlated log row exists.
--   * Partitioning overhead — advisor_conversation_log is RANGE-
--     partitioned on created_at; an outbound FK from a partitioned table
--     adds per-partition enforcement cost for no integrity benefit here.
--   * Semantics — the correlation is advisory (join-for-display in the
--     Support logs projection), not a referential-integrity invariant. A
--     plain nullable column keeps the two lifecycles fully decoupled.
--
-- ALTER ... ADD COLUMN IF NOT EXISTS on the parent partitioned table
-- propagates to every existing and future partition automatically.

alter table public.advisor_conversation_log
  add column if not exists request_id uuid null;

comment on column public.advisor_conversation_log.request_id is
  'P1a (Support logs telemetry groundwork) — advisory correlation key to '
  'public.proxy_requests.request_id (uuid). NULLABLE: pre-P1a rows and '
  'system-issued turns have no proxy-request record. Intentionally NOT a '
  'FOREIGN KEY — proxy_requests has a short idempotency lifecycle while '
  'this table holds tiered/legal-hold retention; a cross-table FK would '
  'either purge legal-hold rows (CASCADE), sever the key (SET NULL), or '
  'block proxy cleanup (RESTRICT). Used join-for-display by the Support '
  'logs projection, not as a referential-integrity invariant.';

-- service_role reads the conversation log through a column-level GRANT
-- SELECT allowlist (the 9.0Σ.h audit-privacy split). A new column is
-- unreadable to service_role until explicitly added to that allowlist;
-- request_id is non-sensitive correlation metadata, so it joins the
-- allowlist on both the parent and the DEFAULT partition. Encrypted
-- content columns remain omitted from the service_role allowlist.

grant select (request_id)
  on public.advisor_conversation_log to service_role;
grant select (request_id)
  on public.advisor_conversation_log_default to service_role;

-- ─── GAP 1: operator-leading join index ────────────────────────────
--
-- Hot read path 4 (Support logs): correlate a conversation turn to its
-- proxy_requests row within a tenant. `operator_id` LEADS so the per-
-- tenant RLS policy folds into the index probe (RLS performance
-- discipline); `location_id` narrows to the scope band the Support UI
-- filters on; `request_id` resolves the join. Satisfies
-- tool/index_leading_column_lint.dart (leading column = operator_id).

create index if not exists advisor_conversation_log_op_loc_request_idx
  on public.advisor_conversation_log
  (operator_id, location_id, request_id);

-- ─── GAP 2: cluster-wide 30-day retention purge function ───────────
--
-- The existing public.advisor_conversation_log_purge(operator_id,
-- before_ts, batch_size) drains ONE operator at a time, so it cannot be
-- the body of a single cluster-wide cron job. This function wraps the
-- same purge predicate in an all-operators batched loop suitable for a
-- single scheduled call.
--
-- Predicate (mirrors advisor_conversation_log_purge EXACTLY — NEVER
-- deletes any of these):
--   * legal_hold = true            — litigation / regulator hold
--   * retention_class = 'permanent'— never-purge bucket
--   * created_at >= cutoff         — inside the 30-day window
--
-- The cutoff is computed inside the function as now() - 30 days so the
-- schedule string carries no date math and the retention window is a
-- single source of truth in code. Batched with FOR UPDATE SKIP LOCKED so
-- a long sweep never blocks concurrent writers and two overlapping cron
-- firings cannot fight over the same rows. Loops until a batch deletes
-- fewer than batch_size rows (drained).
--
-- SECURITY DEFINER carries the migration owner's (forge_admin) privileges
-- regardless of caller, and EXECUTE is granted ONLY to forge_admin — the
-- runtime service_role connection has no DELETE surface (consistent with
-- the per-operator function's posture). The DELETE uses the PK tuple
-- (operator_id, created_at, id) so it resolves correctly across the
-- parent partitioned table and its child partitions.

create or replace function public.advisor_conversation_log_purge_expired(
  retention_days integer default 30,
  batch_size integer default 1000
) returns integer
language plpgsql
security definer
as $$
declare
  v_cutoff timestamptz;
  v_batch_deleted integer := 0;
  v_total_deleted integer := 0;
begin
  if retention_days <= 0 then
    raise exception
      'advisor_conversation_log_purge_expired: retention_days must be '
      'positive (got %)',
      retention_days;
  end if;
  if batch_size <= 0 then
    raise exception
      'advisor_conversation_log_purge_expired: batch_size must be '
      'positive (got %)',
      batch_size;
  end if;

  v_cutoff := now() - make_interval(days => retention_days);

  loop
    delete from public.advisor_conversation_log
     where (operator_id, created_at, id) in (
       select operator_id, created_at, id
         from public.advisor_conversation_log
        where created_at < v_cutoff
          and legal_hold = false
          and retention_class <> 'permanent'
        order by created_at
        limit batch_size
        for update skip locked
     );
    get diagnostics v_batch_deleted = row_count;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    exit when v_batch_deleted < batch_size;
  end loop;

  return v_total_deleted;
end;
$$;

revoke execute on function
  public.advisor_conversation_log_purge_expired(integer, integer)
  from public;

grant execute on function
  public.advisor_conversation_log_purge_expired(integer, integer)
  to forge_admin;

comment on function
  public.advisor_conversation_log_purge_expired(integer, integer) is
  'P1a (Support logs 30-day retention). Cluster-wide batched DELETE of '
  'advisor_conversation_log rows older than retention_days (default 30) '
  'across ALL operators. NEVER deletes rows where legal_hold = true or '
  'retention_class = ''permanent'' (predicate mirrors '
  'advisor_conversation_log_purge). FOR UPDATE SKIP LOCKED batches so a '
  'sweep never blocks writers. SECURITY DEFINER + EXECUTE to forge_admin '
  'only — the runtime service_role path cannot call it. Scheduled daily '
  'via pg_cron (forge_advisor_conversation_log_retention).';

-- ─── GAP 2: pg_cron schedule (idempotent) ──────────────────────────
--
-- Topology mirrors 202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql:
-- Azure DB Flexible Server keeps pg_cron metadata in the database named
-- by `cron.database_name` (currently `postgres`), while this migration is
-- applied to the application database (`forgeflow`). When the cron
-- metadata is not present in the current DB, the DO block emits a NOTICE
-- telling the operator to schedule from the maintenance database with:
--
--   cron.schedule_in_database(
--     'forge_advisor_conversation_log_retention',
--     '15 3 * * *',
--     'select public.advisor_conversation_log_purge_expired(30);',
--     'forgeflow'
--   )
--
-- The schedule runs once daily at 03:15 UTC — off the audit-anchor 02:00
-- and rollup minute/5-minute ticks so the sweeps do not pile up. Daily
-- (not minutely) because 30-day retention is not latency-sensitive.
-- cron.schedule raises unique_violation on a duplicate jobname, so the
-- DO block unschedules-then-reschedules for idempotent re-apply, matching
-- the 9.0Σ.k pattern exactly.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(''forge_advisor_conversation_log_retention'', ''15 3 * * *'', ''select public.advisor_conversation_log_purge_expired(30);'', ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job
     where jobname = 'forge_advisor_conversation_log_retention'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_advisor_conversation_log_retention',
    '15 3 * * *',
    'select public.advisor_conversation_log_purge_expired(30);'
  );
end$$;

commit;
