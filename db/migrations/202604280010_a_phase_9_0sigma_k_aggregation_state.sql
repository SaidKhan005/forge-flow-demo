-- Phase 9.0Σ.k — aggregation_state foundation (item 32 of
-- `phase_9_scalability_decisions_2026-04-27.md`; B32 in
-- `phase_9_execution_backlog.md`).
--
-- Locks the per-rollup-table watermark / lease / retry / observability
-- table that every Q3.1 incremental refresh job updates atomically.
-- The table is the single source of truth for "where is each rollup
-- caught up to" — pg_cron jobs (202604280010_c) read
-- `last_processed_seq`, claim a lease, batch-process raw facts up to
-- the new high watermark, and advance `last_processed_seq` only after
-- the batch commits. Q3.6 idempotency follows: re-running a window
-- never advances past a previously-failed batch and never double-
-- counts because UPSERT semantics on the rollup tables collapse
-- repeated rows to the same key.
--
-- Design source — Q3.1 + Q3.6 + Q3.9 + Q3.10:
--
--   Q3.1 (Refresh Strategy)   sequence-watermarked
--                             aggregation_state(rollup_table, grain,
--                             last_processed_seq).
--   Q3.6 (Idempotency)        deterministic keys on rollup tables
--                             (202604280010_b); this table records
--                             how far the worker advanced the
--                             watermark for each (table, grain).
--   Q3.9 (Error Handling)     `last_run_status` lets the freshness UI
--                             distinguish ok / stale / failed; failures
--                             keep `last_processed_seq` pinned so the
--                             next run retries the same window.
--   Q3.10 (Observability)     surfaces last-success/failure timing,
--                             attempt count, lease owner, and rebuild
--                             progress to the F&F Dev/Admin Health
--                             dashboard.
--
-- Hard rules carried from CLAUDE.md:
--   1. RLS performance discipline does not apply to this table —
--      `aggregation_state` is internal infrastructure (no operator_id
--      column, not operator-scoped). Direct DDL/DML lives behind
--      `forge_admin` BYPASSRLS; the worker never reads or writes it
--      from a tenant transaction. RLS is therefore not enabled.
--   2. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
--      banned in operator-scoped tables and matched here for
--      consistency (the worker compares lease/run timestamps across
--      regions in a future multi-region world).
--   3. The locked grain set (Q3.3 — daypart, business_day, week,
--      accounting_period, month, quarter, year) is enforced at the
--      DB layer via CHECK so a typo in the worker cannot silently
--      create a phantom grain row.
--   4. Idempotent / rerun-safe — every DDL uses
--      `if not exists` / `create or replace`. No data backfill on
--      first apply (the worker bootstraps a row on its first poll for
--      each (rollup_table, grain) it owns, with `last_processed_seq
--      = 0`).
--
-- This migration is local framework only — no live database mutation.
-- Live apply on staging + Production1 is queued under the Phase 9
-- live-mutation gate and runs together with 202604280010_b/c.

begin;

-- ─── aggregation_state ──────────────────────────────────────────────
--
-- Composite PK is `(rollup_table, grain)` per Q3.1. One row per
-- rollup-table-and-grain pair; the worker upserts on advance and
-- never deletes (the rollup history is what gets rebuilt, not the
-- watermark row).
--
-- Status field rationale: the freshness UI (Q3.7) needs to tell the
-- difference between "running on time", "stale because the worker
-- has not progressed in N minutes", "failed because the last attempt
-- threw", and "rebuilding". A free-form text column with a CHECK
-- constraint is enough; a Postgres ENUM type would force a follow-up
-- migration every time a status is added.
--
-- Lease fields (`lease_owner`, `leased_until`) gate the at-most-one
-- worker invariant per (rollup_table, grain). The pg_cron functions
-- (202604280010_c) take a lease before walking facts; if another
-- worker has the lease and it has not expired, the cron call exits
-- silently. This is the "worker leasing" gate from the conditional-
-- pass note in the scalability audit.
--
-- Rebuild fields (`rebuild_in_progress`, `rebuild_started_at`,
-- `rebuild_target_rule_version`, `rebuild_scope`) feed the Q3.8
-- bounded-rebuild path. The runbook
-- (`docs/phases/phase_9/phase_9_rollups_rebuild_runbook.md`)
-- documents how the values flow through staging → validate → promote.
create table if not exists public.aggregation_state (
  rollup_table text not null,
  grain text not null,
  last_processed_seq bigint not null default 0
    check (last_processed_seq >= 0),
  -- Q3.10 observability: when the watermark last moved.
  updated_at timestamptz not null default now(),
  -- Q3.10 observability: when the most recent run started + finished.
  last_run_started_at timestamptz null,
  last_run_completed_at timestamptz null,
  -- Q3.7 + Q3.9 — freshness/status contract used by the dashboard.
  -- `idle` = no run in progress and no recent failure; `leased` = a
  -- worker is actively processing; `succeeded` = last run finished
  -- without error; `failed` = last run threw; `stale` = no run in
  -- the freshness window (set by the freshness sweep); `rebuilding`
  -- = a Q3.8 rebuild is touching this (table, grain).
  last_run_status text not null default 'idle'
    check (last_run_status in (
      'idle', 'leased', 'succeeded', 'failed', 'stale', 'rebuilding'
    )),
  -- Retry ledger. `attempt_count` resets to zero on `succeeded`;
  -- a non-zero value on `idle` means the previous run failed and the
  -- next poll will retry the same window.
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  last_error_at timestamptz null,
  last_error text null,
  -- Lease (worker leasing — scalability audit Rollups conditional-
  -- pass gate). NULL means no current claim. `lease_owner` is a
  -- free-form identifier the worker chooses (hostname:pid, container
  -- id, etc.) so an operator looking at Dev/Admin Health can see
  -- which worker is stuck if a lease never releases.
  lease_owner text null,
  leased_until timestamptz null,
  -- Rebuild bookkeeping (Q3.8). When `rebuild_in_progress` is true
  -- the freshness UI (Q3.7) shows "Rebuilding…" instead of the
  -- normal staleness label.
  rebuild_in_progress boolean not null default false,
  rebuild_started_at timestamptz null,
  -- The `rule_version` the rebuild is targeting (e.g. `v3` after a
  -- target/labor rule change). Lets the dashboard show "rebuilding
  -- to v3" so operators understand why old rows are being replaced.
  rebuild_target_rule_version text null,
  -- Free-form scope description for audit attribution — e.g.
  -- `'operator=…/grain=daypart/dates=2026-04-01..2026-04-28'`.
  rebuild_scope text null,
  primary key (rollup_table, grain),
  -- Q3.3 grain set lock. Hourly/minute summaries are explicitly
  -- excluded from the launch rollup architecture; if a future slice
  -- needs them, the CHECK gets relaxed at the same time the rollup
  -- table for that grain ships.
  constraint aggregation_state_grain_check
    check (grain in (
      'daypart', 'business_day', 'week',
      'accounting_period', 'month', 'quarter', 'year'
    ))
);

comment on table public.aggregation_state is
  'Phase 9.0Σ.k (item 32 / Q3.1 / Q3.6 / Q3.9 / Q3.10) — per-rollup-'
  'table watermark, lease, retry, and observability. pg_cron jobs '
  '(202604280010_c) read last_processed_seq, claim a lease, batch-'
  'aggregate raw facts up to the new high watermark, and advance '
  'last_processed_seq only after the batch commits. Q3.6 idempotency '
  'is enforced by the deterministic UPSERT keys on the rollup tables '
  'in 202604280010_b — re-runs collapse to the same row.';

comment on column public.aggregation_state.last_processed_seq is
  'Q3.1 sequence watermark. The worker advances this only after a '
  'successful batch commit. Failed batches keep the value pinned so '
  'the next run retries the same window. Default 0 lets the worker '
  'bootstrap a fresh (rollup_table, grain) without a separate seed.';

comment on column public.aggregation_state.last_run_status is
  'Q3.7 + Q3.9 freshness label. `idle` / `leased` / `succeeded` / '
  '`failed` / `stale` / `rebuilding`. The dashboard maps these to '
  'the operator-facing copy ("Updated just now", "Data delayed", '
  '"Rebuilding…") per Q3.7. Anything not in the CHECK list is a '
  'worker bug.';

comment on column public.aggregation_state.lease_owner is
  'Free-form worker identifier (hostname:pid, container id) that '
  'currently holds the lease. NULL when no run is in progress. Used '
  'by Dev/Admin Health to show which worker is stuck if a lease '
  'never releases.';

comment on column public.aggregation_state.rebuild_in_progress is
  'Q3.8 rebuild bookkeeping. When true, the Q3.7 freshness UI shows '
  '"Rebuilding…" and the worker pauses normal incremental advances '
  'for this (rollup_table, grain) until the rebuild completes or is '
  'cancelled.';

-- ─── Index — leased / idle scan ─────────────────────────────────────
--
-- The Dev/Admin Health dashboard (Q3.10) needs a fast "show me every
-- (rollup_table, grain) whose lease has expired or whose status is
-- failed/stale" probe. The composite (last_run_status, leased_until)
-- index handles both predicates without a table scan; the row count
-- is tiny (one row per rollup-table × grain combination, bounded by
-- the locked grain set × per-metric rollup table count) so the index
-- is effectively a no-op cost-wise.
create index if not exists aggregation_state_status_idx
  on public.aggregation_state (last_run_status, leased_until);

-- ─── Grants ─────────────────────────────────────────────────────────
--
-- Internal infrastructure — no service_role access. The worker runs
-- under `forge_admin` BYPASSRLS via `runAsSystem` so that pg_cron-
-- triggered claim/advance happens without a tenant context (the
-- aggregation watermark is cross-tenant by construction; one row
-- summarises every operator's state for that (rollup_table, grain)
-- pair). PUBLIC stays revoked.

grant select, insert, update, delete on public.aggregation_state to forge_admin;

commit;
