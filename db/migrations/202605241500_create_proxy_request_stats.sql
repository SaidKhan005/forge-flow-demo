-- P1a' — public.proxy_request_stats: stats-only per-AI-request telemetry
-- with 30-day retention (Support logs redesign storage).
--
-- Plan: docs/_execution/admin_support_logs_redesign/
--       01_lens_audit_and_implementation_plan.md (§12). This migration
--       SUPERSEDES the earlier B1 write-path idea (telemetry columns on
--       proxy_requests) and the content-bearing advisor_conversation_log
--       path for the Support logs surface.
--
-- WHY A DEDICATED STATS TABLE (operator decision: STATS ONLY, NO message
-- content, 30-day history):
--   * advisor_conversation_log (202604280007_phase_9_0sigma_h_...) mandates
--     encrypted message CONTENT columns; the Support logs surface must never
--     store content, so reusing it is wrong.
--   * Extending public.proxy_requests
--     (202604250005_advisor_cloud_foundation.sql) retention to 30 days would
--     also retain its `response_payload`
--     (the AI response body) for 30 days — the proxy_requests row is pruned
--     at 48h precisely so that content does not linger. Adding 30-day stats
--     columns there would violate the no-content choice.
--   * This table therefore holds ONLY measured request statistics (tokens,
--     cost, latency, outcome, provider/model identifiers) + a correlation
--     key, with a self-contained 30-day purge. NO content, NO encrypted
--     columns, NO business_date.
--
-- TENANCY (mirrors public.proxy_requests exactly):
--   * operator_id uuid NOT NULL, location_id uuid NOT NULL — proxy_requests
--     declares location_id NOT NULL (the proxy injects both the app.operator_id
--     and app.location_id GUCs on every call), so this table mirrors that
--     non-nullability rather than the prompt's hedged "if nullable" wording.
--   * Composite FK (operator_id, location_id) -> public.locations(operator_id,
--     location_id) ON DELETE CASCADE — identical to proxy_requests. Rejects
--     the (operator_a, location_b) cross-tenant mismatch at the database layer
--     even before RLS, and an operator/location delete cascades these rows
--     away (PIPEDA right-to-erasure chain).
--
-- CORRELATION KEY (request_id) — DELIBERATELY NOT A FOREIGN KEY, mirroring the
-- P1a advisor_conversation_log.request_id rationale
-- (202605241000_advisor_conversation_log_request_correlation_and_retention.sql):
--   * Lifecycle mismatch — public.proxy_requests is a SHORT-LIVED idempotency
--     ledger pruned at 48 hours; proxy_request_stats is a 30-day retention
--     surface. A FK with ON DELETE CASCADE would let the 48h proxy_requests
--     prune cascade-delete these 30-day stats rows (data loss). ON DELETE SET
--     NULL would silently sever the correlation key the Support UI joins on.
--     NO ACTION / RESTRICT would block the 48h proxy_requests prune whenever a
--     correlated stats row still exists. A plain nullable-free column keeps the
--     two lifecycles fully decoupled.
--   * Semantics — the correlation is advisory (join-for-display in the Support
--     logs projection), not a referential-integrity invariant.
--   * NB: public.proxy_requests' PK is the COMPOSITE
--     (operator_id, location_id, request_id) after the 11a.11c.6 index
--     hardening (202604250007_advisor_rls_index_hardening.sql); request_id is a
--     trace uuid, unique within a tenant, not a bare single-column PK. The
--     correlation column carries operator_id + location_id alongside request_id
--     so a join resolves on the same tenant-leading key.
--
-- ATTRIBUTION (audit_attribution_contract.md): actor_user_id stores the acting
-- user's UUID ONLY — never a name/email. Display names are resolved at render
-- time. NULLABLE because system-issued / scheduled turns have no acting user.
--
-- MEASURED METRICS: prompt/completion token counts, cost_usd, latency_ms are
-- MEASURED at request time and populated by a LATER proxy slice; they are
-- nullable here (this slice is storage-only, no writer).
--
-- RLS: per-tenant isolation through the STABLE LEAKPROOF wrapper functions
-- (app_current_operator() / app_current_location() from
-- 202604280000_phase_9_0sigma_b_rls_wrappers.sql), mirroring the
-- proxy_requests_tenant_isolation policy shape from
-- 202605021500_phase_9_0sigma_l_rls_depth.sql. NO bare current_setting()
-- (tool/rls_policy_lint.dart). Application-layer OperatorScopedRepository
-- remains the primary defense; this policy is the database-side backup
-- (CLAUDE.md "RLS-Ready Schema").
--
-- INDEXES (tool/index_leading_column_lint.dart — every B-tree index leads with
-- operator_id): (operator_id, location_id, request_id) for the Support-log
-- correlation join; (operator_id, location_id, created_at) for time-ordered
-- tenant reads.
--
-- 30-DAY RETENTION: a cluster-wide batched purge function
-- public.proxy_request_stats_purge_expired(retention_days default 30,
-- batch_size default 1000) modeled on advisor_conversation_log_purge_expired
-- (SECURITY DEFINER, FOR UPDATE SKIP LOCKED, EXECUTE forge_admin only, REVOKE
-- from public). No legal_hold / permanent class here — every row is plain
-- 30-day telemetry. Scheduled daily via pg_cron at 03:30 UTC (off the 03:15
-- advisor_conversation_log sweep so the two do not pile up), idempotent
-- unschedule-then-reschedule, with the Azure split-DB cross-DB NOTICE fallback.
--
-- Schema-touching + RLS-touching: build-only storage groundwork. MUST NOT be
-- applied to staging / Production1 without explicit operator approval.

begin;

-- ─── Table ─────────────────────────────────────────────────────────

create table if not exists public.proxy_request_stats (
  -- Tenancy — mirrors public.proxy_requests (location_id NOT NULL).
  operator_id uuid not null,
  location_id uuid not null,
  -- Advisory correlation key to public.proxy_requests.request_id (uuid).
  -- NOT a FOREIGN KEY — see header (48h proxy prune must not cascade-delete
  -- these 30-day stats; lifecycles are decoupled by design).
  request_id uuid not null,
  -- AI cost class (mirrors proxy_requests.usage_class). Drives the cost-by-
  -- class metering surface; not null because every request carries a class.
  usage_class text not null,
  -- Acting user's UUID ONLY (never name/email — resolved at render per
  -- audit_attribution_contract.md). NULLABLE: system / scheduled turns have
  -- no acting user.
  actor_user_id uuid null,
  -- Provider / model identifiers — nullable (populated by the later proxy
  -- writer slice; a failed pre-dispatch turn may have no resolved model).
  provider text null,
  model_id text null,
  model_version text null,
  -- MEASURED metrics — populated at request time by the later proxy slice;
  -- nullable in this storage-only migration. Non-negative where present.
  prompt_token_count integer null
    check (prompt_token_count is null or prompt_token_count >= 0),
  completion_token_count integer null
    check (completion_token_count is null or completion_token_count >= 0),
  cost_usd numeric null
    check (cost_usd is null or cost_usd >= 0),
  latency_ms integer null
    check (latency_ms is null or latency_ms >= 0),
  -- Real per-request outcome. The proxy / usage layer names outcomes
  -- 'success' / 'error' / 'timeout' (the three terminal states a metered
  -- provider call can land in). NULLABLE: an in-flight / not-yet-resolved
  -- stats row may be written before the outcome is known.
  result_status text null
    check (result_status is null
           or result_status in ('success', 'error', 'timeout')),
  created_at timestamptz not null default now(),
  -- NO content / encrypted columns. NO business_date (the Support UI buckets
  -- by relative time/date, not restaurant business day, so the operator-
  -- scoped business_date denormalization rule does not apply here).
  --
  -- Composite FK rejects (operator_a, location_b) mismatches and cascades on
  -- operator/location delete — identical to public.proxy_requests.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.proxy_request_stats is
  'P1a'' (Support logs redesign, plan §12). Stats-only per-AI-request '
  'telemetry: tokens / cost / latency / outcome / provider+model ids + an '
  'advisory request_id correlation to public.proxy_requests. 30-day retention '
  'via proxy_request_stats_purge_expired. NO message content, NO encrypted '
  'columns, NO business_date. Operator-scoped fact table: '
  '(operator_id, location_id) composite FK to locations; per-tenant RLS via '
  'wrapper functions; OperatorScopedRepository is the primary defense, RLS is '
  'the backup. Supersedes the B1 telemetry-on-proxy_requests write path.';

comment on column public.proxy_request_stats.request_id is
  'Advisory correlation key to public.proxy_requests.request_id (uuid). '
  'Intentionally NOT a FOREIGN KEY: proxy_requests is pruned at 48h while '
  'these stats retain 30 days, so a CASCADE would delete live stats, SET NULL '
  'would sever the join key, and RESTRICT would block the proxy prune. Joined '
  'for-display by the Support logs projection, not a referential invariant.';

comment on column public.proxy_request_stats.actor_user_id is
  'Acting user UUID only (never name/email — resolved at render time per '
  'audit_attribution_contract.md). NULLABLE: system / scheduled turns have no '
  'acting user.';

comment on column public.proxy_request_stats.result_status is
  'Terminal request outcome: success / error / timeout (CHECK-constrained). '
  'NULLABLE for an in-flight stats row written before the outcome resolves.';

-- ─── Indexes (operator-leading — RLS performance discipline) ───────
--
-- Support-log correlation join, scoped within a tenant. operator_id LEADS so
-- the per-tenant RLS policy folds into the index probe; location_id narrows
-- to the scope band; request_id resolves the join onto proxy_requests.
create index if not exists proxy_request_stats_op_loc_request_idx
  on public.proxy_request_stats
  (operator_id, location_id, request_id);

-- Time-ordered tenant reads (the Support UI lists recent requests newest-
-- first within a tenant). operator_id LEADS; created_at trails for the ORDER
-- BY / range scan.
create index if not exists proxy_request_stats_op_loc_created_idx
  on public.proxy_request_stats
  (operator_id, location_id, created_at);

-- ─── RLS: per-tenant isolation via wrapper functions ───────────────
--
-- Mirrors public.proxy_requests' proxy_requests_tenant_isolation policy
-- (202605021500_phase_9_0sigma_l_rls_depth.sql): location-scoped, reads
-- operator + location context through the STABLE LEAKPROOF wrappers so the
-- planner folds the predicate into the tenant-leading index. location_id is
-- NOT NULL on this table (as on proxy_requests), so the policy uses a hard
-- equality on both columns. NO bare current_setting (tool/rls_policy_lint.dart).

alter table public.proxy_request_stats enable row level security;

drop policy if exists "proxy_request_stats_tenant_isolation"
  on public.proxy_request_stats;

create policy "proxy_request_stats_tenant_isolation"
  on public.proxy_request_stats for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

comment on policy "proxy_request_stats_tenant_isolation"
  on public.proxy_request_stats is
  'P1a'' — per-tenant isolation, mirrors proxy_requests_tenant_isolation. '
  'Reads operator + location context via app_current_operator() / '
  'app_current_location() wrappers so the planner folds the predicate into '
  'the tenant-leading index. Application-layer OperatorScopedRepository is the '
  'primary defense; this policy is the database-side backup.';

-- ─── Privileges (mirror proxy_requests' service_role DML posture) ──
--
-- The proxy writes these stats and the Support-log projection reads them under
-- service_role RLS, so service_role needs full DML (matching the standard
-- operator-scoped fact-table grant set used for usage_caps / usage_logs and
-- the auth tables). forge_admin (BYPASSRLS) gets SELECT so the admin Support
-- logs read path can inspect cross-tenant under runAsSystem — the same posture
-- public.proxy_requests carries (202605031430 debug-console grant). Privileges
-- are checked BEFORE RLS, so without these GRANTs the policy never evaluates.
-- DELETE for the runtime path is intentionally part of service_role's grant
-- (parity with proxy_requests); the retention sweep itself runs as forge_admin
-- via the SECURITY DEFINER purge function below, never as service_role.

grant select, insert, update, delete on public.proxy_request_stats to service_role;
grant select on public.proxy_request_stats to forge_admin;

-- ─── 30-day retention purge function (cluster-wide, batched) ───────
--
-- Modeled on public.advisor_conversation_log_purge_expired
-- (202605241000_advisor_conversation_log_request_correlation_and_retention.sql).
-- Deletes rows older than retention_days (default 30) across ALL operators in
-- batches with FOR UPDATE SKIP LOCKED so a long sweep never blocks writers and
-- two overlapping cron firings cannot fight over the same rows. There is NO
-- legal_hold / permanent-retention concept here — every row is plain 30-day
-- telemetry, so the predicate is purely the age cutoff. The cutoff is computed
-- inside the function (now() - retention_days) so the schedule string carries
-- no date math and the window is a single source of truth in code.
--
-- SECURITY DEFINER carries the migration owner's (forge_admin) privileges
-- regardless of caller; EXECUTE is granted ONLY to forge_admin so the runtime
-- service_role path has no bulk-DELETE surface. The DELETE targets the
-- correlation/time tuple so it resolves across the whole table.

create or replace function public.proxy_request_stats_purge_expired(
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
      'proxy_request_stats_purge_expired: retention_days must be '
      'positive (got %)',
      retention_days;
  end if;
  if batch_size <= 0 then
    raise exception
      'proxy_request_stats_purge_expired: batch_size must be '
      'positive (got %)',
      batch_size;
  end if;

  v_cutoff := now() - make_interval(days => retention_days);

  loop
    delete from public.proxy_request_stats
     where (operator_id, location_id, request_id, created_at) in (
       select operator_id, location_id, request_id, created_at
         from public.proxy_request_stats
        where created_at < v_cutoff
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
  public.proxy_request_stats_purge_expired(integer, integer)
  from public;

grant execute on function
  public.proxy_request_stats_purge_expired(integer, integer)
  to forge_admin;

comment on function
  public.proxy_request_stats_purge_expired(integer, integer) is
  'P1a'' (Support logs 30-day retention). Cluster-wide batched DELETE of '
  'proxy_request_stats rows older than retention_days (default 30) across ALL '
  'operators. No legal_hold / permanent class — every row is plain telemetry, '
  'so the predicate is purely the age cutoff. FOR UPDATE SKIP LOCKED batches '
  'so a sweep never blocks writers. SECURITY DEFINER + EXECUTE to forge_admin '
  'only — the runtime service_role path cannot call it. Scheduled daily via '
  'pg_cron (forge_proxy_request_stats_retention).';

-- ─── pg_cron schedule (idempotent) ─────────────────────────────────
--
-- Topology mirrors
-- 202605241000_advisor_conversation_log_request_correlation_and_retention.sql
-- and 202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql: Azure DB Flexible
-- Server keeps pg_cron metadata in the database named by `cron.database_name`
-- (currently `postgres`), while this migration is applied to the application
-- database (`forgeflow`). When the cron metadata is not present in the current
-- DB, the DO block emits a NOTICE telling the operator to schedule from the
-- maintenance database with:
--
--   cron.schedule_in_database(
--     'forge_proxy_request_stats_retention',
--     '30 3 * * *',
--     'select public.proxy_request_stats_purge_expired(30);',
--     'forgeflow'
--   )
--
-- The schedule runs once daily at 03:30 UTC — off the 03:15 advisor_
-- conversation_log retention sweep, the 02:00 audit anchor, and the rollup
-- minute/5-minute ticks so the daily sweeps do not pile up. Daily (not
-- minutely) because 30-day retention is not latency-sensitive.
-- cron.schedule raises unique_violation on a duplicate jobname, so the DO block
-- unschedules-then-reschedules for idempotent re-apply, matching the existing
-- pattern exactly.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(''forge_proxy_request_stats_retention'', ''30 3 * * *'', ''select public.proxy_request_stats_purge_expired(30);'', ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job
     where jobname = 'forge_proxy_request_stats_retention'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_proxy_request_stats_retention',
    '30 3 * * *',
    'select public.proxy_request_stats_purge_expired(30);'
  );
end$$;

commit;
