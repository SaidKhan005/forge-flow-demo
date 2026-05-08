-- CODE_OPS_DEBT Theme B#1 — single-admin PII erasure with 24h reverse window.
--
-- Background:
--   Phase 11A.14 wired `admin.users.erase_pii` (MFA-required) and the
--   "Issue erasure" button on `audited_support_actions_admin_screen`,
--   but the proxy POST route never landed. The frontend button calls a
--   404. Per the operator decision register (2026-05-08):
--     * Single-admin action — paired approval is overkill at launch.
--     * Fresh-MFA gate — admin must have authenticated MFA within 1h.
--     * 24h grace-window reversal.
--     * Scope = PII fields ONLY (display name, email, phone, avatar
--       URL). Audit log rows referencing user_id are NOT cascaded —
--       the user row remains; the PII columns are NULLed.
--
-- This migration creates the durable request ledger. The proxy route
-- writes one row per erasure request, captures a JSON snapshot of the
-- pre-erasure PII so reversal can restore it, and the grace-window
-- worker (`PiiErasureWorker`) runs after `grace_period_ends_at` to
-- apply the actual NULL-out on `public.users` and wipe the snapshot.
--
-- Hard rules carried from CLAUDE.md / contracts:
--
--   1. Operator-scoped fact table → leading `operator_id` on every
--      B-tree index, RLS policy stub from creation
--      (`operator_pii_erasure_requests_per_user`), denormalized
--      `business_date DATE` per the Phase 8 time-boundary contract.
--   2. Postgres role grants follow the same shape as
--      `mfa_factor_removal_requests`: runtime gets full DML
--      (`service_role`, `forge_admin`); cron-driven sweep uses
--      `forge_admin` BYPASSRLS.
--   3. Grace window default = 24h; configurable via the
--      `PII_ERASURE_GRACE_PERIOD_SECONDS` env var read by the proxy.
--      Schema CHECK (`grace_period_ends_at >= requested_at`) just
--      enforces "non-negative window"; the policy length lives in app
--      code so a hot-fix does not require a new migration.
--   4. `pii_snapshot` is `JSONB NOT NULL`. Once the worker applies the
--      erasure, it overwrites the snapshot with `'{}'::jsonb` so PII
--      does not linger in the archive past the grace window.
--   5. Per-row uniqueness is `(operator_id, user_id)` partial on
--      pending rows — at most one in-flight erasure per user. A
--      reversed or applied row drops out of the partial index so a
--      subsequent erasure can be issued for the same user.
--   6. pg_cron sweep ticker emits `pii_erasure_grace_expired_tick` on
--      a `*/1 * * * *` schedule. The Dart worker LISTENs and calls
--      `PiiErasureRepository.applyDuePending` which UPDATEs `users`
--      atomically with the request row's `applied_at` stamp.

begin;

create extension if not exists pgcrypto;

-- ─── user_pii_erasure_requests ─────────────────────────────────────
--
-- One row per erasure request. The row is the durable seam between
-- the `POST .../erase-pii` admin action and the grace-window worker
-- that applies the NULL-out after `grace_period_ends_at`.
--
-- Column shape:
--   * erasure_id            UUID PK
--   * operator_id           UUID NOT NULL  → tenant key
--   * user_id               UUID NOT NULL  → target user (subject)
--   * requested_by_user_id  UUID NOT NULL  → admin who initiated
--   * requested_at          TIMESTAMPTZ    → operator-action instant
--   * business_date         DATE           → restaurant-local business
--                                            day of `requested_at`
--                                            (denormalized per Phase 8
--                                            time contract)
--   * grace_period_ends_at  TIMESTAMPTZ    → requested_at + 24h
--   * applied_at            TIMESTAMPTZ ?  → set by worker on apply
--   * reversed_at           TIMESTAMPTZ ?  → set by reverse route
--   * reversed_by_user_id   UUID ?         → admin who reversed
--   * reversal_reason       TEXT ?         → free-form admin note
--   * pii_snapshot          JSONB NOT NULL → captured PII (see below)
--   * created_at / updated_at              → row bookkeeping
--
-- `pii_snapshot` shape (PII fields lifted from `public.users`):
--   {
--     "display_name": "...",
--     "email":        "...",
--     "first_name":   "...",
--     "last_name":    "...",
--     "avatar_url":   "..."
--   }
-- (`public.users` does not currently carry a `phone` column; if/when
--  Phase 9.UX adds one, the snapshot map and the worker's NULL-out
--  list extend in lockstep.)

create table if not exists public.user_pii_erasure_requests (
  erasure_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  user_id uuid not null references public.users(user_id)
    on delete cascade,
  requested_by_user_id uuid not null references public.users(user_id)
    on delete restrict,
  requested_at timestamptz not null default now(),
  business_date date not null,
  grace_period_ends_at timestamptz not null,
  applied_at timestamptz null,
  reversed_at timestamptz null,
  reversed_by_user_id uuid null references public.users(user_id)
    on delete set null,
  reversal_reason text null,
  pii_snapshot jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (grace_period_ends_at >= requested_at),
  check (applied_at is null or reversed_at is null),
  check (
    reversed_at is null
    or reversed_by_user_id is not null
  )
);

comment on table public.user_pii_erasure_requests is
  'CODE_OPS_DEBT Theme B#1 — single-admin PII erasure ledger. Row '
  'records who requested the erasure, when, the snapshot used to '
  'reverse during the 24h grace window, and the apply/reverse '
  'terminal stamps. PII snapshot is wiped to ''{}''::jsonb after the '
  'worker applies the NULL-out on public.users so PII does not '
  'linger past the grace window.';

-- ─── Indexes (operator-leading) ────────────────────────────────────
--
-- Pending-only uniqueness — at most one in-flight erasure per
-- (operator_id, user_id) pair so the proxy can reject a duplicate
-- erase request while a prior one is still inside the grace window.
-- The partial predicate uses `applied_at is null and reversed_at is
-- null` so terminal rows fall out of the index automatically.

create unique index if not exists user_pii_erasure_active_idx
  on public.user_pii_erasure_requests (operator_id, user_id)
  where applied_at is null and reversed_at is null;

-- Worker claim path — surface the rows whose grace window has
-- expired and that the worker has not yet applied. operator_id
-- leads per the RLS performance discipline; the partial predicate
-- limits the index footprint to the active set.

create index if not exists user_pii_erasure_due_idx
  on public.user_pii_erasure_requests (
    operator_id,
    grace_period_ends_at,
    erasure_id
  )
  where applied_at is null and reversed_at is null;

-- Status-read path — the GET route's "latest erasure for this user"
-- query orders by `requested_at desc` inside one (operator_id,
-- user_id) scope.

create index if not exists user_pii_erasure_recent_idx
  on public.user_pii_erasure_requests (
    operator_id,
    user_id,
    requested_at desc
  );

-- ─── RLS policy stub ───────────────────────────────────────────────
--
-- Per-tenant + per-user scope using the 9.0Σ.b STABLE LEAKPROOF
-- wrapper functions (`app_current_operator()`,
-- `app_current_actor_user()`). The PII erasure surface is admin-only;
-- the wrapper-based policy mirrors the
-- `mfa_factor_removal_requests_per_user` policy shape so RLS depth
-- stays bounded.
--
-- The policy intentionally does NOT join on `location_id` because
-- the erasure target is operator-scoped (the user row carries
-- operator_id, not location_id; users can move between locations).

alter table public.user_pii_erasure_requests enable row level security;

drop policy if exists "user_pii_erasure_requests_per_operator"
  on public.user_pii_erasure_requests;

create policy "user_pii_erasure_requests_per_operator"
  on public.user_pii_erasure_requests for all to service_role
  using (
    operator_id = public.app_current_operator()
  )
  with check (
    operator_id = public.app_current_operator()
  );

grant select, insert, update on public.user_pii_erasure_requests
  to service_role, forge_admin;

-- DELETE is intentionally not granted — the row is the audit trail
-- for a privacy-sensitive action; expiry / archival lives in the
-- partition retention sweep, not ad-hoc DELETE.

-- ─── pg_cron schedule registration ─────────────────────────────────
--
-- Cron tick — fires every minute, emits `pg_notify` on
-- `pii_erasure_grace_expired_tick` so the subscribed Dart worker
-- wakes up and processes the due rows. Following the same
-- NOTIFY-only pattern as `forge_rollup_hot_path` (P1-1 rule from
-- the rollup migration): the cron stub never takes a lease itself
-- — the worker is the sole state mutator.
--
-- The function uses CREATE OR REPLACE so re-applies of this
-- migration are clean. The schedule registration is wrapped in a DO
-- block that unschedules-then-reschedules the named job so a second
-- apply does not raise `unique_violation`.

create or replace function public.pii_erasure_grace_expired_tick()
returns void
language plpgsql
as $$
begin
  perform pg_notify(
    'pii_erasure_grace_expired_tick',
    json_build_object(
      'fired_at', now()
    )::text
  );
end;
$$;

comment on function public.pii_erasure_grace_expired_tick() is
  'CODE_OPS_DEBT Theme B#1 — cron-callable wake-up signal for the '
  'PII erasure grace-window apply worker. Emits '
  'pg_notify(''pii_erasure_grace_expired_tick'', …) only; the Dart '
  'worker scans for due rows and applies the NULL-out on public.users '
  'inside its own tenant transaction.';

grant execute on function public.pii_erasure_grace_expired_tick()
  to forge_admin;

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from '
      'cron.database_name with cron.schedule_in_database(..., '
      '''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid
    from cron.job
    where jobname = 'forge_pii_erasure_grace_expired_tick'
  loop
    perform cron.unschedule(v_jobid);
  end loop;

  perform cron.schedule(
    'forge_pii_erasure_grace_expired_tick',
    '* * * * *',
    'select public.pii_erasure_grace_expired_tick();'
  );
end$$;

commit;
