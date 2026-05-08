-- Code-Health Lane M3 — audit anchor advisory lock + Azure blob columns.
--
-- CODE_HEALTH references:
--   * "Audit anchor sweep has no advisory-lock guard"
--     (`tool/audit_anchor/audit_anchor.dart:1101` — verify path reads
--     the current anchor row but nothing serializes concurrent sweeps;
--     two pods firing the daily cadence at the same time can race the
--     read-then-write of the audit_chain_anchors row).
--   * "Audit-anchor cadence is paused"
--     (`db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
--     — the in-DB pg_cron tick is NOTIFY-only and the Cloud Scheduler
--     trigger `forge-flow-audit-anchor-daily` is paused; resuming +
--     wiring the Cloud Run binary to the daily Azure Blob write is
--     code-lane L9 work).
--   * "Audit anchor verify can't recover from crashed-write state"
--     (the verifier currently has no notion of a half-written anchor;
--     L9 adds a roll-forward path that needs the new
--     last_anchor_blob_url / last_anchor_blob_at columns to know
--     whether the previous run wrote the Blob before crashing).
--
-- Scope of THIS migration: schema infrastructure ONLY.
--   1. Constants table `audit_anchor_advisory_locks` carrying the
--      stable INTEGER lock id used by `pg_advisory_lock(...)` to
--      serialize the daily anchor sweep across pods/regions.
--   2. Two new columns on the existing `public.audit_chain_anchors`
--      table tracking the most-recent daily Azure Blob write:
--        - `last_anchor_blob_url  TEXT`
--        - `last_anchor_blob_at   TIMESTAMPTZ`
--      These columns are crash-recovery breadcrumbs the verifier
--      reads to roll a half-written sweep forward instead of
--      reporting `anchorMissing`.
--
-- NOTE: Cron unpause + the daily Azure Blob write are wired in code lane L9, not in this migration.
--
-- Scope (operator) — this migration is **global / cluster-wide**
-- infrastructure, not operator-scoped. The advisory-lock id table
-- holds one constant row shared by every operator's sweep; the new
-- columns hang off `public.audit_chain_anchors`, which is already
-- operator-scoped at row level (PRIMARY KEY (operator_id, chain_date)).
-- No new RLS surface is created here, so the tenant-leading-index
-- rule from the hardening RLS contract does not bind to this slice.
--
-- Authority:
--   * `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`
--     (Audit Anchor section — advisory lock, paused cadence,
--     crash-recovery rollforward).
--   * `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
--     (original `audit_chain_anchors` CREATE TABLE — append-only
--     grant shape preserved; this slice only ALTERs to add columns).
--   * `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
--     (in-DB NOTIFY-only cadence the L9 lane will graduate to
--     resumed Cloud Scheduler / wired Azure Blob writes).
--   * `tool/audit_anchor/audit_anchor.dart`
--     (the Cloud Run binary that L9 will wrap with
--     `pg_advisory_lock(audit_anchor_sweep)`).
--
-- Replay-safe: every DDL statement uses IF NOT EXISTS / ON CONFLICT
-- DO NOTHING so re-running this migration on a host where it has
-- already applied is a clean no-op.

begin;

-- ─── Constants table: advisory-lock id registry ────────────────────
--
-- A single-row-per-kind constants table makes the lock id read-able
-- from SQL (the L9 sweep guard executes
--   `select lock_id from public.audit_anchor_advisory_locks
--      where lock_kind = 'audit_anchor_sweep';`
-- and then `pg_advisory_lock(lock_id)`), which keeps the id out of
-- application config and lets DBAs audit the live id without
-- redeploying the binary.
--
-- `lock_kind` is the natural key — adding a future second sweep
-- (e.g. a weekly compaction job) just inserts a new row with its
-- own `lock_id`. `lock_id INTEGER UNIQUE` matches `pg_advisory_lock`'s
-- single-int-arg signature and prevents two kinds colliding on the
-- same id.
--
-- Lock id `8472001` is a deliberately-distinctive integer in the
-- low-8-digit range. As of this migration there are no
-- `pg_advisory_lock(<numeric>)` call sites in the codebase
-- (existing usage is hashtext()-derived per-(operator, vendor)
-- keys for OAuth refresh and per-shard sink writes), so collision
-- with a hashtext() value is astronomically unlikely.

create table if not exists public.audit_anchor_advisory_locks (
  lock_kind text primary key,
  lock_id   integer not null unique
);

comment on table public.audit_anchor_advisory_locks is
  'Code-Health Lane M3 — registry of stable advisory-lock ids used '
  'to serialize singleton background sweeps. Append-only by '
  'convention: rows may be added for future sweep kinds, but '
  'existing rows MUST NOT have their lock_id mutated (a live '
  'lock holder would silently lose its guarantee). Lane L9 reads '
  'the audit_anchor_sweep row to wrap the daily Cloud Run sweep '
  'in pg_advisory_lock(lock_id).';

comment on column public.audit_anchor_advisory_locks.lock_kind is
  'Natural key — human-readable name of the sweep this lock '
  'guards (e.g. ''audit_anchor_sweep''). One row per sweep kind.';

comment on column public.audit_anchor_advisory_locks.lock_id is
  'Single-int argument passed to pg_advisory_lock(...). UNIQUE '
  'across kinds so two sweeps never collide on the same lock. '
  'Treat as immutable once seeded — see table comment.';

insert into public.audit_anchor_advisory_locks (lock_kind, lock_id)
  values ('audit_anchor_sweep', 8472001)
on conflict (lock_kind) do nothing;

-- ─── audit_chain_anchors: crash-recovery breadcrumbs ───────────────
--
-- The verifier (`tool/audit_anchor/audit_anchor.dart`, runVerify)
-- currently reads the `audit_chain_anchors` row and the immutable
-- Azure Blob, then compares ETags / hashes / row counts. If a
-- previous sweep crashed AFTER writing the Blob but BEFORE inserting
-- the anchor row, the verifier reports `anchorMissing` and there is
-- no record of the half-completed work.
--
-- These two columns let the L9 sweep stamp "I wrote the Blob at
-- <url>, last persisted at <ts>" before inserting the anchor row,
-- so a crash-recovery roll-forward can detect the orphan Blob and
-- backfill the anchor row deterministically instead of producing a
-- duplicate Blob.
--
-- Columns are NULLABLE so existing anchor rows do not need
-- backfill; the L9 sweep populates them on first write.

alter table public.audit_chain_anchors
  add column if not exists last_anchor_blob_url text,
  add column if not exists last_anchor_blob_at  timestamptz;

comment on column public.audit_chain_anchors.last_anchor_blob_url is
  'Code-Health Lane M3 — Blob URL the L9 sweep stamps before '
  'inserting/updating this anchor row. Lets the verifier detect '
  'a half-written sweep (Blob exists, anchor missing or stale) '
  'and roll forward instead of producing a duplicate Blob. '
  'NULL on rows written before lane L9 ships.';

comment on column public.audit_chain_anchors.last_anchor_blob_at is
  'Code-Health Lane M3 — timestamptz the Blob URL was last '
  'persisted. Paired with last_anchor_blob_url for crash-recovery '
  'roll-forward. NULL on rows written before lane L9 ships.';

commit;
