-- Canonical fact projection retry jobs.
--
-- Why this exists
-- ---------------
-- Canonical fact writes must stay successful even when the downstream
-- projection layer fails. The in-memory projection buffer is not durable,
-- so a projector failure needs a tenant-scoped retry row that can be
-- claimed and replayed later without asking the vendor to re-send data.
--
-- Schema notes
-- ------------
-- * One row stores the exact post-commit projector input that failed.
-- * `attempt_count` is incremented by the replay dispatcher when it claims.
-- * `dead_lettered_at` is set after the bounded retry budget is exhausted.
-- * Operator-leading indexes and RLS mirror the integration fact tables.
--
-- Operator approval gate
-- ----------------------
-- This is schema-touching. Per CLAUDE.md, it requires explicit operator
-- approval before merge regardless of audit verdict.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

create table if not exists public.canonical_fact_projection_retry_jobs (
  job_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  restaurant_id text not null,
  connection_id uuid not null
    references public.connector_connection(connection_id)
    on delete cascade,
  vendor_id text not null,
  category text not null
    check (category in ('pos', 'labor', 'reservation')),
  status text not null default 'pending'
    check (status in ('pending', 'running', 'succeeded', 'dead_lettered')),
  changed_periods jsonb not null
    check (jsonb_typeof(changed_periods) = 'array'),
  open_current_fact_maps jsonb not null default '[]'::jsonb
    check (jsonb_typeof(open_current_fact_maps) = 'array'),
  input_hash text not null
    check (input_hash ~ '^[0-9a-f]{64}$'),
  fact_count integer not null default 0
    check (fact_count >= 0),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  worker_id text null,
  claimed_at timestamptz null,
  next_attempt_at timestamptz not null default now(),
  last_error_class text not null,
  last_error_message text not null,
  stack_first_frame text null,
  user_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz null,
  dead_lettered_at timestamptz null,
  constraint canonical_fact_projection_retry_jobs_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.canonical_fact_projection_retry_jobs is
  'Durable retry ledger for canonical fact post-commit projector failures. '
  'Rows preserve the failed projector input so saved vendor facts can be '
  'replayed without re-running vendor writes.';

comment on column public.canonical_fact_projection_retry_jobs.changed_periods is
  'JSON array of CanonicalFactCommittedPeriod payloads supplied to the '
  'post-commit projector when the failure occurred.';

comment on column public.canonical_fact_projection_retry_jobs.open_current_fact_maps is
  'JSON array of open/current canonical fact maps needed by the open-shift '
  'snapshot projector replay path.';

comment on column public.canonical_fact_projection_retry_jobs.input_hash is
  'SHA-256 hash of the projector input. Used for audit and future '
  'dedupe/replay tooling.';

create index if not exists canonical_fact_projection_retry_jobs_due_idx
  on public.canonical_fact_projection_retry_jobs
  (operator_id, location_id, status, next_attempt_at, created_at);

create index if not exists canonical_fact_projection_retry_jobs_connection_idx
  on public.canonical_fact_projection_retry_jobs
  (operator_id, connection_id, created_at desc);

create index if not exists canonical_fact_projection_retry_jobs_input_hash_idx
  on public.canonical_fact_projection_retry_jobs
  (operator_id, input_hash);

alter table public.canonical_fact_projection_retry_jobs
  enable row level security;

drop policy if exists "canonical_fact_projection_retry_jobs_per_tenant"
  on public.canonical_fact_projection_retry_jobs;
create policy "canonical_fact_projection_retry_jobs_per_tenant"
  on public.canonical_fact_projection_retry_jobs for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.canonical_fact_projection_retry_jobs from public;
grant select, insert, update, delete
  on public.canonical_fact_projection_retry_jobs to service_role;
grant select, insert, update, delete
  on public.canonical_fact_projection_retry_jobs to forge_admin;

commit;
