-- Phase 9.0Σ.k — pg_cron schedules for the rollup hot/cold paths
-- (item 32 / Q3.1 of `phase_9_scalability_decisions_2026-04-27.md`;
-- B32 in `phase_9_execution_backlog.md`).
--
-- Q3.1 Locked: incremental batch via pg_cron, NOT synchronous write
-- triggers. Refresh interval is 60s for hot grains (today/this week
-- = `daypart` + `business_day`) and 300s for colder grains (`week`,
-- `accounting_period`, `month`, `quarter`, `year`). The split keeps
-- the high-volume / latency-sensitive grains close to real time
-- without burning cycles on `quarter` / `year` rollups that can
-- safely lag five minutes.
--
-- Schedule shape:
--   * Hot path  → `'60 seconds'` interval, calls
--                 `public.rollup_run_hot_path()`.
--   * Cold path → `'300 seconds'` interval, calls
--                 `public.rollup_run_cold_path()`.
--
-- Both functions are SQL-callable, idempotent stubs that take a
-- transaction-scoped lease on each `(rollup_table, grain)` row in
-- `aggregation_state`, mark `last_run_status = 'leased'`, and exit.
-- The Dart worker (`lib/services/rollups/rollup_worker.dart`)
-- performs the actual fact-walking + UPSERT + watermark advance
-- through the same primitives so the two paths stay in lockstep.
--
-- Why a SQL stub and not the worker directly: pg_cron jobs can only
-- call SQL inside the database; calling out to a Dart service would
-- require a wrapper Cloud Run service that the database posts to.
-- The SQL function is the lightweight kickoff — its job is to take
-- the lease and stamp `last_run_started_at` / `last_run_status` so
-- the worker (driven by the lease event or by its own poll) sees
-- the new lease and processes the window. This keeps the database
-- side simple and auditable without forcing the worker to also
-- poll on a tight timer.
--
-- Idempotency on rerun (B32 gate "rollups idempotent across
-- retried runs"):
--
--   * `cron.schedule(jobname, …)` is NOT idempotent on its own — a
--     second call with the same `jobname` raises a duplicate-job
--     error. The DO block below removes any existing schedule with
--     the same name first using `cron.unschedule(jobname)`, then
--     reschedules. Wrapped in a transaction so a partial failure
--     leaves the prior schedule intact.
--
--   * The functions themselves use `create or replace function` so
--     re-running this migration after a function-body fix does not
--     drop / recreate dependent triggers (there are none today, but
--     the principle stands).
--
--   * Lease acquisition uses `update … where leased_until is null
--     or leased_until < now()` so two simultaneous cron firings on
--     a misconfigured host do not both win the lease.
--
-- This migration is local framework only — no live database
-- mutation. Live apply is queued behind 202604280010_a/b under the
-- Phase 9 live-mutation gate.

begin;

-- ─── pg_cron topology ─────────────────────────────────────────────
--
-- Azure DB Flexible Server keeps pg_cron metadata in the database named by
-- the server parameter `cron.database_name` (currently `postgres` on staging
-- and Production1). This migration is applied to the application database
-- (`forgeflow`), so it creates the SQL functions the jobs will call but does
-- not attempt `create extension pg_cron` here. The live apply runbook schedules
-- from the `postgres` maintenance database with:
--
--   cron.schedule_in_database(
--     job_name, schedule, command, 'forgeflow'
--   )
--
-- Keeping function creation and schedule registration split avoids changing
-- `cron.database_name`, which is restart-bound on Azure.

-- ─── Function: rollup_acquire_lease ────────────────────────────────
--
-- Single-row claim helper. The Dart worker (rollup_worker.dart) is
-- the SOLE caller; the cron kickoffs below NOTIFY-only and never
-- take the lease themselves. P1-1 fix from the Codex review: if a
-- cron tick took the lease, the worker's next claim would block
-- until the cron-held lease expired (Q3.1 incremental-batch
-- contract requires the worker to do the aggregation, not the cron
-- stub). The split keeps cron as a pure wake-up signal and the
-- worker as the only state mutator that runs the actual fact walk
-- + UPSERT + watermark advance.
--
-- Returns TRUE on a successful claim, FALSE when another worker
-- already holds an unexpired lease OR a Q3.8 rebuild is in
-- progress. The rebuild guards (`rebuild_in_progress = false` and
-- `last_run_status <> 'rebuilding'`) are belt-and-braces — both
-- columns flip together when a rebuild starts/ends, but checking
-- both here means a partial rebuild-bookkeeping update cannot
-- accidentally re-allow normal incremental advances over a
-- rebuilding row. P1-3 fix from the Codex review: prior version
-- omitted both guards, so a worker poll could overwrite a
-- rebuilding row's status and start writing alongside the rebuild
-- writer.
--
-- Lease window is fixed at 5 minutes — long enough for a slow
-- batch to complete, short enough that a crashed worker's lease
-- expires before the next-but-one worker poll picks the orphan up.
-- The Dart worker re-takes the lease on every batch advance using
-- the same primitive, so a healthy worker continually refreshes
-- the lease without ever letting it expire.
--
-- The function bootstraps the aggregation_state row on first call
-- (worker has not run yet for this rollup_table/grain) so a fresh
-- database does not require a separate seed migration.

create or replace function public.rollup_acquire_lease(
  p_rollup_table text,
  p_grain text,
  p_lease_owner text,
  p_lease_seconds integer default 300
)
returns boolean
language plpgsql
as $$
declare
  v_now timestamptz := now();
  v_lease_until timestamptz := v_now + (p_lease_seconds * interval '1 second');
  v_acquired boolean := false;
begin
  -- Bootstrap row if missing — first poll for this (rollup_table, grain).
  insert into public.aggregation_state (rollup_table, grain)
  values (p_rollup_table, p_grain)
  on conflict (rollup_table, grain) do nothing;

  -- Single-row lease take: only succeeds if the lease is unset or
  -- expired AND no Q3.8 rebuild owns the row. Re-running the same
  -- (rollup_table, grain) under contention picks at most one winner.
  update public.aggregation_state
     set lease_owner          = p_lease_owner,
         leased_until         = v_lease_until,
         last_run_started_at  = v_now,
         last_run_status      = 'leased',
         updated_at           = v_now
   where rollup_table = p_rollup_table
     and grain = p_grain
     and (leased_until is null or leased_until < v_now)
     and rebuild_in_progress = false
     and last_run_status <> 'rebuilding';

  get diagnostics v_acquired = row_count;
  return v_acquired;
end;
$$;

comment on function public.rollup_acquire_lease(text, text, text, integer) is
  'Phase 9.0Σ.k (Q3.1 / Rollups conditional-pass leasing gate) — '
  'transaction-scoped lease take for one (rollup_table, grain). '
  'Returns TRUE on a successful claim, FALSE if another worker '
  'holds the lease OR a Q3.8 rebuild is in progress. Bootstraps the '
  'aggregation_state row on first call so a fresh database does not '
  'need a seed migration. The Dart worker is the SOLE caller — the '
  'cron kickoffs only NOTIFY.';

grant execute on function public.rollup_acquire_lease(text, text, text, integer)
  to forge_admin;

-- ─── Function: rollup_run_hot_path ─────────────────────────────────
--
-- Cron-callable kickoff for the hot path (daypart + business_day).
-- P1-1 fix from the Codex review: this function NEVER takes a
-- lease. It only emits a `pg_notify('rollups_tick', …)` envelope
-- so any subscribed Dart worker wakes up and does its own
-- `rollup_acquire_lease` + fact-walk + UPSERT + watermark advance.
--
-- Earlier design called `rollup_acquire_lease` directly from the
-- cron path; that turned every cron tick into a lease take that
-- the worker then could not get past until expiry, starving the
-- aggregator and missing Q3.1's "incremental batch via pg_cron …
-- sequence-watermarked aggregation_state" contract. NOTIFY-only
-- keeps cron purely as a wake-up signal and the worker as the
-- only state mutator.
--
-- The envelope keys (`path`, `grains`, `fired_at`) match the
-- contract the Dart worker poller subscribes to. Adding new keys
-- is non-breaking; renaming or removing them needs a paired
-- worker update.
--
-- Idempotent: re-firing only emits another notification; NOTIFY
-- is best-effort and dropping duplicates is the worker's job.

create or replace function public.rollup_run_hot_path()
returns void
language plpgsql
as $$
begin
  perform pg_notify(
    'rollups_tick',
    json_build_object(
      'path', 'hot',
      'grains', json_build_array('daypart', 'business_day'),
      'fired_at', now()
    )::text
  );
end;
$$;

comment on function public.rollup_run_hot_path() is
  'Phase 9.0Σ.k (Q3.1 hot path) — cron-callable wake-up signal for '
  'the 60s hot grains (daypart + business_day). Emits '
  'pg_notify(''rollups_tick'', …) only; the Dart worker takes the '
  'lease via rollup_acquire_lease and does the aggregation. P1-1: '
  'this function MUST NOT call rollup_acquire_lease itself — doing '
  'so would starve the worker by holding the lease until expiry.';

grant execute on function public.rollup_run_hot_path() to forge_admin;

-- ─── Function: rollup_run_cold_path ────────────────────────────────
--
-- Cron-callable kickoff for the cold path (week, accounting_period,
-- month, quarter, year). Same NOTIFY-only shape as the hot path —
-- see P1-1 comment above for why this function does not take the
-- lease itself.

create or replace function public.rollup_run_cold_path()
returns void
language plpgsql
as $$
begin
  perform pg_notify(
    'rollups_tick',
    json_build_object(
      'path', 'cold',
      'grains', json_build_array(
        'week', 'accounting_period', 'month', 'quarter', 'year'
      ),
      'fired_at', now()
    )::text
  );
end;
$$;

comment on function public.rollup_run_cold_path() is
  'Phase 9.0Σ.k (Q3.1 cold path) — cron-callable wake-up signal '
  'for the 300s cold grains (week + accounting_period + month + '
  'quarter + year). Emits pg_notify(''rollups_tick'', …) only; the '
  'Dart worker does the aggregation. P1-1: this function MUST NOT '
  'call rollup_acquire_lease itself.';

grant execute on function public.rollup_run_cold_path() to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- `cron.schedule(jobname, schedule, command)` raises
-- `unique_violation` on a second call with the same jobname. The DO
-- block below unschedules-then-reschedules so re-running this
-- migration on a host where the schedule already exists is a clean
-- no-op rather than a hard error.
--
-- Azure Flexible Server rejected pg_cron's seconds-interval literals during
-- live apply, so the schedule uses standard cron equivalents: every minute
-- for the hot path and every five minutes for the cold path. The command
-- string ends in `;` because pg_cron concatenates a wrapper around the
-- supplied SQL and the trailing semicolon makes the final form a complete
-- statement.

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

  -- Hot path — daypart + business_day every 60s.
  for v_jobid in
    select jobid from cron.job where jobname = 'forge_rollup_hot_path'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_rollup_hot_path',
    '* * * * *',
    'select public.rollup_run_hot_path();'
  );

  -- Cold path — week + accounting_period + month + quarter + year every 300s.
  for v_jobid in
    select jobid from cron.job where jobname = 'forge_rollup_cold_path'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_rollup_cold_path',
    '*/5 * * * *',
    'select public.rollup_run_cold_path();'
  );
end$$;

commit;
