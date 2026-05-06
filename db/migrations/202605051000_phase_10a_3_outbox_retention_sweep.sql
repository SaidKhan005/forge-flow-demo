-- Phase 10a.3 — bounded retention sweep + sweep-history log.
--
-- Layered slice on top of the existing 10a.3 retention work
-- (`db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`).
-- The earlier migration shipped an unbounded `event_outbox_retention_sweep()`
-- function and a daily 09:00 UTC pg_cron schedule. Two operational gaps
-- remained that this slice closes:
--
--   1. **Unbounded DELETE locks.** A single sweep call does the entire
--      DELETE in one statement. On a busy operator the row count past
--      the 7-day window can climb into the millions during a Pub/Sub
--      regional outage; one statement holding a row-level lock on
--      every match starves the bridge claim path. This slice adds
--      `public.run_event_outbox_retention_sweep()` which caps the
--      DELETE at 10000 rows per call. Multiple cron passes drain the
--      backlog without long locks; the cap_hit signal in the log
--      table tells operators when extra passes are pending.
--
--   2. **No sweep-history evidence.** With nothing recorded across
--      sweep runs, the proxy `/health` envelope had no way to tell
--      "sweep is healthy and just ran" from "sweep has been broken
--      for a week". The existing `event_outbox_retention_backlog`
--      producer counts delivered rows past the 7-day window, but it
--      cannot distinguish "1000 rows that just landed past the window
--      because operator volume spiked" from "1000 rows because the
--      sweep stopped firing three days ago". The new
--      `event_outbox_retention_sweep_log` table records one row per
--      cron pass; the new `event_outbox_retention_lag_hours`
--      producer reads `now() - max(swept_at)` so a stale lag is
--      visible immediately.
--
-- The earlier `event_outbox_retention_sweep()` function and its
-- 09:00 UTC schedule are intentionally NOT removed. The new
-- `run_event_outbox_retention_sweep()` runs at 03:00 UTC and is
-- the bounded path; the older function stays as the legacy
-- belt-and-braces sweep for one release cycle so the 03:00 cron
-- failing does not silently strand delivered rows. The legacy job
-- retires in a follow-up migration after operators confirm the
-- bounded sweep is keeping the table drained.
--
-- Authority:
--   * `docs/contracts/event_outbox_contract.md` — "Retention sweep"
--     sub-bullet locks the 7-day delivered-rows window and the
--     un-delivered-rows-stay invariant. The bounded-DELETE shape is
--     an implementation detail that respects both invariants.
--   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
--     Scope "Retention sweep" subsection.
--   * `docs/contracts/phase_7_55_time_boundary_contract.md` —
--     TIMESTAMPTZ everywhere; the new log table follows the rule.
--
-- Hard rules carried from CLAUDE.md and the contract:
--
--   1. The bounded sweep MUST NOT touch un-delivered rows
--      (`delivered_at IS NULL`). The sub-select that picks LIMIT
--      10000 victims pins both predicates from the contract:
--      `delivered_at IS NOT NULL AND delivered_at < now() -
--      INTERVAL '7 days'`.
--
--   2. The 7-day window stays the contract literal. Changing it
--      requires a paired update to
--      `docs/contracts/event_outbox_contract.md` "Retention".
--
--   3. The new log table carries an always-NULL `operator_id`
--      column so the tenant-leading index discipline lands cleanly
--      even though the sweep is platform-wide. Per CLAUDE.md "RLS
--      performance discipline" + `tool/index_leading_column_lint.dart`
--      every B-tree index on a table that declares `operator_id`
--      MUST lead with it. The column is documented as never-written
--      so a future "wait, why is this NULL?" reviewer has the
--      answer in the schema.
--
--   4. The log table sets RLS off (no per-tenant rows to gate);
--      access is gated entirely through grants. Same posture as
--      `event_outbox_publish_metrics` (10a.4). The proxy `/health`
--      producer reads through the admin pool; F&F engineers triage
--      via `forge_admin` BYPASSRLS SQL.
--
--   5. SECURITY DEFINER + forge_admin owner so the cross-operator
--      DELETE runs without a tenant context. `set search_path =
--      public, pg_catalog` locks the function against schema
--      injection.
--
--   6. The pg_cron registration is idempotent (unschedule-then-
--      reschedule). `cron.schedule(jobname, …)` raises
--      `unique_violation` on a duplicate jobname; the DO block
--      removes any prior entry by jobid first. The same NOTICE-and-
--      return guard from the rollups + email-dispatcher migrations
--      handles the Azure split-database case where pg_cron metadata
--      lives in `cron.database_name`.
--
-- Live apply status: lands on staging first; production cutover after
-- the staging tick fires once and the `event_outbox_retention_lag_hours`
-- metric flips from `unknown` (sweep_never_ran sentinel) to a
-- numeric value below 24 hours.

begin;

-- ─── event_outbox_retention_sweep_log ──────────────────────────────
--
-- One row per cron pass. The bounded sweep function INSERTs after
-- each DELETE (whether or not anything was deleted), so a healthy
-- sweep that runs daily produces ~1 row/day. Even a 10-year retention
-- of the log table is < 4000 rows; we do not partition or apply a
-- secondary retention sweep.
--
-- Columns:
--   * `swept_at TIMESTAMPTZ` — when the sweep call returned. Set
--     server-side via `now()` so a writer with a skewed clock does
--     not pollute the history.
--   * `deleted_count BIGINT` — rows the sweep removed. Zero is a
--     valid value (no rows past the 7-day window — steady state).
--   * `cap_hit BOOLEAN` — true when the bounded DELETE deleted the
--     full 10000-row cap. A run of `cap_hit = true` rows means the
--     backlog is bigger than the daily drain budget; operators
--     either bump the sweep cadence or raise the per-call cap.
--   * `operator_id UUID` — always NULL. Present so the tenant-leading
--     index discipline lands; the table itself is platform-wide.
--
-- The PK is a synthetic bigserial (`id`) because composite uniqueness
-- on `(swept_at)` would block the unlikely case of two cron passes
-- firing inside the same microsecond (PG `now()` is microsecond-
-- resolution). The `(operator_id, swept_at desc)` index keeps the
-- producer's `MAX(swept_at)` lookup on a single index probe.

create table if not exists public.event_outbox_retention_sweep_log (
  id bigserial primary key,
  -- Always NULL. Present so `event_outbox_retention_sweep_log_recent_idx`
  -- can lead with `operator_id` and clear the index-leading-column lint
  -- (CLAUDE.md "RLS performance discipline"). The sweep runs cross-
  -- operator under `forge_admin BYPASSRLS`; there is no per-tenant
  -- column to record because the function aggregates platform-wide.
  -- Future per-operator rollup of sweep work would write a real value.
  operator_id uuid null,
  swept_at timestamptz not null default now(),
  deleted_count bigint not null
    check (deleted_count >= 0),
  cap_hit boolean not null default false
);

comment on table public.event_outbox_retention_sweep_log is
  'Phase 10a.3 — sweep-history log. One row per '
  'run_event_outbox_retention_sweep() call (cron-driven, daily at '
  '03:00 UTC). Backs the proxy /health '
  'event_outbox_retention_lag_hours producer. Platform-wide '
  'bookkeeping; RLS off; forge_admin BYPASSRLS reads only. '
  'operator_id column is always NULL — present so the tenant-leading '
  'index discipline (CLAUDE.md RLS performance) lands cleanly.';

comment on column public.event_outbox_retention_sweep_log.operator_id is
  'Always NULL. The sweep aggregates platform-wide; the column exists '
  'so event_outbox_retention_sweep_log_recent_idx leads with '
  'operator_id and clears tool/index_leading_column_lint.dart.';

comment on column public.event_outbox_retention_sweep_log.swept_at is
  'Server-set wall-clock at sweep return. The proxy /health '
  'event_outbox_retention_lag_hours producer reads MAX(swept_at) and '
  'reports hours since the last successful pass.';

comment on column public.event_outbox_retention_sweep_log.deleted_count is
  'Rows DELETED from public.event_outbox by this sweep call. Zero is '
  'valid (steady state — no delivered rows past the 7-day window).';

comment on column public.event_outbox_retention_sweep_log.cap_hit is
  'True when deleted_count = 10000 (the bounded-sweep cap). A run of '
  'cap_hit=true rows means the backlog exceeds the daily drain budget '
  'and operators should either bump cron cadence or raise the cap.';

-- ─── Tenant-leading index ──────────────────────────────────────────
--
-- The producer's hot query is `select max(swept_at) from
-- event_outbox_retention_sweep_log`. With operator_id always NULL and
-- swept_at descending, the index head holds the most recent pass; a
-- single index probe answers MAX. Lint discipline (CLAUDE.md "RLS
-- performance") requires every B-tree on an operator-scoped table to
-- lead with operator_id even when the column is unused for queries —
-- this index honors the rule.

create index if not exists event_outbox_retention_sweep_log_recent_idx
  on public.event_outbox_retention_sweep_log (operator_id, swept_at desc);

comment on index public.event_outbox_retention_sweep_log_recent_idx is
  'Phase 10a.3 — tenant-leading recent-pass index. operator_id is the '
  'leading column per CLAUDE.md RLS performance discipline even though '
  'the column is always NULL (platform-wide aggregate). swept_at desc '
  'puts the most recent pass at the index head so MAX(swept_at) is a '
  'single probe.';

-- ─── Function: run_event_outbox_retention_sweep ────────────────────
--
-- Bounded retention worker. The DELETE is capped at 10000 rows per
-- call so a backlogged sweep does not hold a long row-level lock on
-- the live table. PG does not support `LIMIT` directly on a DELETE,
-- so the function pre-selects victim ids inside a CTE and DELETEs by
-- the resulting id set. The contract predicate
-- `delivered_at IS NOT NULL AND delivered_at < now() - INTERVAL '7
-- days'` is pinned in the CTE (the "victims" CTE is the one place
-- the predicate appears, so a future contract drift edits exactly
-- one statement).
--
-- After the DELETE the function INSERTs one row into
-- `event_outbox_retention_sweep_log` with the deleted-row count and
-- a `cap_hit` flag (true when the count equals the cap). The INSERT
-- is unconditional — even a zero-delete pass logs a row so operators
-- can see the sweep is running.
--
-- Returns the deleted-row count so the cron run-history line surfaces
-- real work and so manual `SELECT public.run_event_outbox_retention_sweep();`
-- calls (e.g. the walkthrough's step 2) print the result.
--
-- SECURITY DEFINER + owner forge_admin: the sweep crosses operator
-- boundaries; running as the BYPASSRLS owner avoids tenant-context
-- gymnastics inside the cron caller. `set search_path = public,
-- pg_catalog` is the standard SECURITY DEFINER hardening so a
-- session-injected schema cannot hijack a same-named object.

create or replace function public.run_event_outbox_retention_sweep()
returns bigint
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_deleted bigint;
  v_cap constant integer := 10000;
begin
  with victims as (
    select id
      from public.event_outbox
     where delivered_at is not null
       and delivered_at < now() - interval '7 days'
     order by delivered_at
     limit v_cap
  )
  delete from public.event_outbox
   where id in (select id from victims);
  get diagnostics v_deleted = row_count;

  insert into public.event_outbox_retention_sweep_log
    (swept_at, deleted_count, cap_hit)
  values
    (now(), v_deleted, v_deleted >= v_cap);

  return v_deleted;
end;
$$;

comment on function public.run_event_outbox_retention_sweep() is
  'Phase 10a.3 — bounded daily retention sweep. DELETEs up to 10000 '
  'event_outbox rows where delivered_at IS NOT NULL AND delivered_at '
  '< now() - INTERVAL ''7 days'', then logs the run into '
  'event_outbox_retention_sweep_log (always — zero-delete passes '
  'still write a row so the lag metric stays fresh). Un-delivered '
  'rows (delivered_at IS NULL) are NEVER touched. SECURITY DEFINER + '
  'forge_admin owner so the cross-operator DELETE runs without a '
  'tenant context. Returns the deleted-row count.';

alter function public.run_event_outbox_retention_sweep() owner to forge_admin;

revoke execute on function public.run_event_outbox_retention_sweep()
  from public;
grant execute on function public.run_event_outbox_retention_sweep()
  to forge_admin;

-- ─── Grants ────────────────────────────────────────────────────────
--
-- forge_admin owns the write surface (sweep function + manual triage)
-- and the read surface (proxy /health admin pool + admin SQL).
-- service_role is intentionally NOT granted: tenants have no business
-- reading platform-wide sweep history, and the producer reads through
-- the admin pool.

revoke all on public.event_outbox_retention_sweep_log from public;

grant select, insert, update, delete on public.event_outbox_retention_sweep_log
  to forge_admin;

grant usage, select on sequence public.event_outbox_retention_sweep_log_id_seq
  to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- Daily at 03:00 UTC (22:00 ET / 19:00 PT prior calendar day —
-- restaurants closed across NA so the cross-operator DELETE does not
-- contend with peak producer enqueues). Six hours ahead of the
-- legacy 09:00 UTC sweep gives the bounded path the first crack at
-- the backlog; the legacy unbounded sweep then drains anything the
-- bounded cap missed (one release cycle of overlap before the
-- legacy job retires).
--
-- The DO block matches the rollups + email-dispatcher idempotency
-- pattern: unschedule any prior `event_outbox_retention_sweep_daily`
-- entry by jobid first, then reschedule. `cron.schedule(jobname, …)`
-- raises `unique_violation` on a duplicate jobname.
--
-- Azure DB Flexible Server keeps pg_cron metadata in the database
-- named by `cron.database_name`. When pg_cron is in a different
-- database, the runbook schedules from the maintenance database via
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
    select jobid from cron.job
     where jobname = 'event_outbox_retention_sweep_daily'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'event_outbox_retention_sweep_daily',
    '0 3 * * *',
    'select public.run_event_outbox_retention_sweep();'
  );
end$$;

commit;
