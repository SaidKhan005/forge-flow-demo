-- Lane: code-health.M4
--
-- Reason: unblocks code-health.L7 (CODE_HEALTH "MFA removal worker has
-- no retry cap, no DLQ" — see lib/services/admin/mfa_removal_worker.dart
-- around line 123). The worker needs a durable per-row attempt counter
-- and a dead-letter sentinel so a poison row stops being re-claimed
-- after exceeding the configured retry budget.
--
-- Schema deltas to public.mfa_factor_removal_requests:
--
--   1. attempt_count    integer not null default 0
--      Per-row retry counter. Bumped by the worker via
--      MfaFactorRemovalRequestsRepository.incrementAttemptCount in the
--      same tenant transaction that records markFailed/markCompleted.
--      Defensive CHECK caps at 100 — app-level enforcement (L7) is the
--      tighter gate at 10; the schema cap is only there to prevent a
--      runaway counter in a buggy retry loop.
--
--   2. dead_lettered_at timestamptz null
--      DLQ sentinel. Once set, the row is excluded from the partial
--      indexes that drive worker claim / due-pending listings, so a
--      poison row stops being re-tried and instead waits for operator
--      review. Setting dead_lettered_at is the worker's choice (L7),
--      not an automatic trigger; this migration only provides the
--      column and the index posture.
--
-- Index reshape:
--
--   The three partial indexes that filter `WHERE completed_at IS NULL
--   AND cancelled_at IS NULL` are dropped and recreated with an
--   additional `AND dead_lettered_at IS NULL` predicate. After this
--   migration, dead-lettered rows naturally fall out of the
--   active/due/processing index sets, so claimDuePending and friends
--   stop seeing them with no app-layer changes. Index leading-column
--   shapes are preserved verbatim from the original migration so this
--   change is a pure predicate-narrowing.
--
-- RLS policy untouched: the existing `mfa_factor_removal_requests_per_user`
-- policy filters by operator/location/user only — it does not reference
-- completed_at/cancelled_at, so adding dead_lettered_at to the table has
-- no policy implications.
--
-- Apply posture:
--
--   - Column adds use IF NOT EXISTS for idempotency on partial replay.
--   - The CHECK constraint is added NOT VALID then VALIDATEd to avoid
--     holding ACCESS EXCLUSIVE during the row-walk.
--   - Indexes are dropped + recreated (no CONCURRENTLY because this
--     migration runs inside a transaction by convention; partial index
--     rebuilds are fast on a table whose hot working set is the small
--     pending sliver).

alter table public.mfa_factor_removal_requests
  add column if not exists attempt_count integer not null default 0,
  add column if not exists dead_lettered_at timestamptz null;

alter table public.mfa_factor_removal_requests
  add constraint mfa_factor_removal_requests_attempt_count_chk
  check (attempt_count >= 0 and attempt_count <= 100) not valid;

alter table public.mfa_factor_removal_requests
  validate constraint mfa_factor_removal_requests_attempt_count_chk;

-- Re-shape the three pending-only partial indexes so dead-lettered
-- rows are excluded from the active working set.

drop index if exists public.mfa_factor_removal_active_idx;

create unique index if not exists mfa_factor_removal_active_idx
  on public.mfa_factor_removal_requests (operator_id, user_id, factor_id)
  where completed_at is null
    and cancelled_at is null
    and dead_lettered_at is null;

drop index if exists public.mfa_factor_removal_due_idx;

create index if not exists mfa_factor_removal_due_idx
  on public.mfa_factor_removal_requests (
    execute_after,
    request_id
  )
  where completed_at is null
    and cancelled_at is null
    and dead_lettered_at is null;

drop index if exists public.mfa_factor_removal_processing_idx;

create index if not exists mfa_factor_removal_processing_idx
  on public.mfa_factor_removal_requests (
    processing_started_at,
    request_id
  )
  where completed_at is null
    and cancelled_at is null
    and dead_lettered_at is null;

comment on column public.mfa_factor_removal_requests.attempt_count is
  'Per-row retry counter incremented by the MFA removal worker on each '
  'transient failure. Capped at 100 in schema; app-level cap (L7) is 10.';

comment on column public.mfa_factor_removal_requests.dead_lettered_at is
  'DLQ sentinel. Set when the worker decides a row has exceeded its retry '
  'budget. Dead-lettered rows are excluded from the active partial indexes '
  'so they leave the worker claim / due-pending listings without code '
  'changes. Operator review path is owned by L7.';
