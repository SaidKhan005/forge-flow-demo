-- Phase 10a.3 — event_outbox retention sweep.
--
-- Closes the only "delivered rows accumulate forever" gap in the
-- Phase 10a bridge worker pipeline. Once Pub/Sub acks a publish, the
-- bridge stamps `delivered_at = now()` and the row drops out of the
-- claim predicate (Phase 9.0Σ.e migration / contract). But the row
-- itself stays in `public.event_outbox` indefinitely, so a busy
-- operator's outbox would grow unboundedly even though nothing reads
-- delivered rows.
--
-- This slice adds:
--
--   * A daily SQL function `public.event_outbox_retention_sweep()`
--     that DELETEs rows whose `delivered_at IS NOT NULL AND
--     delivered_at < now() - INTERVAL '7 days'`. The sweep runs in
--     `forge_admin BYPASSRLS` scope (cron context has no tenant) so
--     the per-tenant policies do not block the cross-operator delete.
--
--   * A `pg_cron` schedule that fires the function once a day at
--     03:00 UTC. The schedule registration is idempotent
--     (unschedule-then-reschedule, mirroring the rollups + email
--     dispatcher migrations from Phase 9.0Σ.k / 9.8 — `cron.schedule`
--     raises `unique_violation` on a second call with the same
--     `jobname`, so the DO block removes any prior entry first).
--
--   * A partial index on `delivered_at WHERE delivered_at IS NOT
--     NULL` so the sweep walks delivered rows by date without sharing
--     the tenant-leading claim index. The contract
--     (`docs/contracts/event_outbox_contract.md` "Retention" section)
--     names this index explicitly: "the delivered_at column lets the
--     sweep walk by date without a separate index — a partial index
--     (WHERE delivered_at IS NOT NULL) lands alongside the sweep".
--
-- Hard rules carried from CLAUDE.md and the contract:
--
--   1. The sweep MUST NOT touch un-delivered rows (`delivered_at IS
--      NULL`). The contract is explicit: "Un-delivered rows: never
--      auto-deleted. The yellow/red tripwires alert before the table
--      grows past safe size; an operator-specific runbook walks
--      through manual claim or producer pause if needed." The
--      retention test (`test/services/realtime/event_outbox_retention_sweep_test.dart`)
--      pins this invariant against the literal SQL predicate.
--
--   2. The 7-day window is the contract value. Changing it requires a
--      paired update to `docs/contracts/event_outbox_contract.md`
--      "Retention" section.
--
--   3. The partial index MUST be tenant-leading per CLAUDE.md "RLS
--      performance discipline" — operator-scoped fact-table indexes
--      lead with `operator_id`. The sweep itself runs cross-operator
--      (forge_admin BYPASSRLS), but per-operator triage queries that
--      filter on `delivered_at` need the operator-leading shape so
--      the per-tenant RLS policy folds into the index probe.
--
--   4. The cron job uses the same NOTIFY-only / forge_admin pattern as
--      the rollups + email dispatcher cron jobs. The retention
--      function differs from those in that it ALSO does the work
--      itself — there is no separate Dart worker that needs the
--      lease to advance. A cross-tenant DELETE is purely a database
--      operation; no producer state to keep in lockstep.
--
--   5. RLS uses the wrapper function `public.app_current_operator()`
--      from 9.0Σ.b only where it appears (the function does not need
--      to set a tenant context because it runs as `forge_admin`).
--
--   6. `TIMESTAMPTZ` everywhere — the existing `delivered_at` column
--      is `timestamptz` per Phase 9.0Σ.e.
--
-- Live apply status: lands on staging first; production cutover after
-- the staging tick fires once and the proxy `/health`
-- `event_outbox_retention_backlog` metric reports green.
--
-- Authority:
--   * `docs/contracts/event_outbox_contract.md` — "Retention" section
--     locks the 7-day window + un-delivered-rows-stay invariant.
--   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
--     scope "Retention sweep" subsection: "Cloud Run scheduled job
--     (or `pg_cron`) deletes rows where `delivered_at IS NOT NULL
--     AND delivered_at < now() - INTERVAL '7 days'`. Un-delivered
--     rows are never auto-deleted".

begin;

-- ─── Partial index on delivered_at ─────────────────────────────────
--
-- The sweep's hot query is:
--
--   delete from public.event_outbox
--    where delivered_at is not null
--      and delivered_at < now() - interval '7 days';
--
-- The full-table claim index `(operator_id, picked_up_at NULLS FIRST,
-- id)` does not help — it leads with `operator_id` and the sweep
-- doesn't filter on it. A partial index on `delivered_at` keyed only
-- on `WHERE delivered_at IS NOT NULL` keeps the index small (it
-- excludes the un-delivered head of the queue, which is exactly the
-- region the claim index already covers) and lets the planner
-- range-scan delivered rows by date.
--
-- Per-operator triage queries (operator asks "what did we send last
-- week?") fold operator_id into the leading column so the per-tenant
-- RLS policy fast-paths through the index probe. The trailing
-- `delivered_at desc` keeps "last N delivered rows" queries on the
-- same index.

create index if not exists event_outbox_delivered_idx
  on public.event_outbox (operator_id, delivered_at desc, id)
  where delivered_at is not null;

comment on index public.event_outbox_delivered_idx is
  'Phase 10a.3 — partial index on delivered rows. Tenant-leading per '
  'CLAUDE.md RLS performance discipline so per-operator triage queries '
  'fold the per-tenant policy into the index probe. The retention '
  'sweep range-scans by delivered_at; the partial WHERE clause keeps '
  'the index off the un-delivered head of the queue (covered by '
  'event_outbox_claim_idx).';

-- ─── Function: event_outbox_retention_sweep ────────────────────────
--
-- Cron-callable retention worker. Unlike the rollups / email
-- dispatcher cron stubs (which NOTIFY a Dart worker), this function
-- does the DELETE itself — there is no producer state to keep in
-- lockstep, so a cross-tenant DELETE inside the cron context is the
-- whole job.
--
-- Predicate is the contract literal:
--
--   delivered_at IS NOT NULL AND delivered_at < now() - INTERVAL '7 days'
--
-- Both predicates are required. `delivered_at IS NULL` rows MUST stay
-- (un-delivered rows are NEVER auto-deleted; the yellow/red tripwires
-- alarm before the table grows past safe size). The strict `<`
-- comparison matches the "older than 7 days" wording — a row whose
-- `delivered_at` is exactly 7 days old to the second is not yet past
-- the window.
--
-- The function returns the number of rows deleted so operator
-- run-history can confirm the sweep is doing real work (and so the
-- proxy `/health` retention-backlog metric can correlate with the
-- last sweep run).
--
-- SECURITY DEFINER + BYPASSRLS: the function runs as `forge_admin`
-- (which carries the BYPASSRLS attribute via 9.0Σ.b) so the sweep
-- can DELETE across operators in one statement. The function body is
-- intentionally a single statement so a misconfigured tenant context
-- in the cron caller cannot leak into a wider scope.

create or replace function public.event_outbox_retention_sweep()
returns bigint
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_deleted bigint;
begin
  delete from public.event_outbox
   where delivered_at is not null
     and delivered_at < now() - interval '7 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function public.event_outbox_retention_sweep() is
  'Phase 10a.3 — daily retention sweep. DELETEs event_outbox rows '
  'where delivered_at IS NOT NULL AND delivered_at < now() - '
  'INTERVAL ''7 days''. Un-delivered rows (delivered_at IS NULL) are '
  'NEVER touched — the yellow/red tripwires alarm before the table '
  'grows past safe size. SECURITY DEFINER so the cross-operator '
  'DELETE runs without a tenant context. Returns the deleted-row '
  'count so the cron run-history surfaces real work.';

-- The function is owned by forge_admin so SECURITY DEFINER inherits
-- the BYPASSRLS attribute. Without this an `alter function … owner
-- to forge_admin` migration would have to land separately. We do it
-- inline so the function lands fully wired in one apply.
alter function public.event_outbox_retention_sweep() owner to forge_admin;

-- Restrict EXECUTE so the runtime service_role cannot trigger the
-- sweep on its own — only forge_admin (cron context, admin pool
-- via runAsSystem) is authorized. Defense-in-depth against a
-- compromised proxy connection deleting delivered audit history.
revoke execute on function public.event_outbox_retention_sweep()
  from public;
grant execute on function public.event_outbox_retention_sweep()
  to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- `cron.schedule(jobname, schedule, command)` raises
-- `unique_violation` on a second call with the same `jobname`. The DO
-- block below unschedules-then-reschedules so re-running this
-- migration on a host where the schedule already exists is a clean
-- no-op rather than a hard error (matches the rollups +
-- email-dispatcher pattern from `phase_9_0sigma_k_pg_cron_jobs.sql`
-- and `phase_9_8_email_provider.sql`).
--
-- Daily at 09:00 UTC. The contract calls for "deletes delivered rows
-- older than the retention window (target: 7 days) via pg_cron or a
-- Cloud Run scheduled job"; a daily cadence is the documented
-- interval that keeps the table from creeping past 8 days of
-- delivered history without burning extra cycles. 09:00 UTC =
-- 04:00 Eastern / 01:00 Pacific — restaurants closed across North
-- America, so the cross-operator DELETE doesn't contend with
-- producer enqueues. Earlier choices (e.g., 03:00 UTC) sit at the
-- back end of NA dinner service (22:00 ET / 19:00 PT) and would
-- compete with peak event volume.
--
-- Azure DB Flexible Server keeps pg_cron metadata in the database
-- named by `cron.database_name` (currently `postgres` on staging /
-- Production1). This migration applies to the application database
-- (`forgeflow`); when pg_cron metadata is in a different database,
-- the runbook schedules from the maintenance database via
-- `cron.schedule_in_database(..., 'forgeflow')`. The DO block raises
-- a NOTICE in that case so the live-apply log captures the manual
-- step.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(..., ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job where jobname = 'forge_event_outbox_retention_sweep'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_event_outbox_retention_sweep',
    '0 9 * * *',
    'select public.event_outbox_retention_sweep();'
  );
end$$;

commit;
